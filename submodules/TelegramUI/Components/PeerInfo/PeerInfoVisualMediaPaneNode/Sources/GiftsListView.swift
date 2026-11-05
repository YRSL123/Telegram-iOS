import LottieSettings
import AsyncDisplayKit
import UIKit
import Display
import ComponentFlow
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import ContextUI
import PhotoResources
import TelegramUIPreferences
import TelegramStringFormatting
import ItemListPeerItem
import ItemListPeerActionItem
import MergeLists
import ItemListUI
import MultilineTextComponent
import BalancedTextComponent
import Markdown
import PeerInfoPaneNode
import GiftItemComponent
import PlainButtonComponent
import GiftViewScreen
import SolidRoundedButtonNode
import UndoUI
import LottieComponent
import ButtonComponent
import ContextUI

// The local showcase has its own ledger. It never changes StarsContext, sends
// Telegram payment forms or fabricates a server-owned StarGiftReference.
private struct YRSLDemoGiftWallet: Codable {
    var balance: Int64 = 1_000_000
    var purchasePrices: [String: Int64] = [:]
    var resalePrices: [String: Int64] = [:]
    var pinnedGiftIds: [Int64] = []
    var catalog: [StarGift.UniqueGift] = []
    var history: [String] = []
}

final class GiftsListView: UIView {
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    let profileGifts: ProfileGiftsContext
    private let giftsCollections: ProfileGiftsCollectionsContext?
    
    private let canSelect: Bool
    private let ignoreCollection: Int32?
    private let remainingSelectionCount: Int32
    
    private var dataDisposable: Disposable?
        
    weak var parentController: ViewController?
        
    private var footerText: ComponentView<Empty>?
    
    private let emptyResultsClippingView = UIView()
    private let emptyResultsAnimation = ComponentView<Empty>()
    private let emptyResultsTitle = ComponentView<Empty>()
    private let emptyResultsText = ComponentView<Empty>()
    private let emptyResultsAction = ComponentView<Empty>()
    
    private var currentParams: (size: CGSize, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, presentationData: PresentationData)?
    private var visibleBounds: CGRect?
    private var topInset: CGFloat?
    
    private var theme: PresentationTheme?
    private let presentationDataPromise = Promise<PresentationData>()
    
    private let ready = Promise<Bool>()
    private var didSetReady: Bool = false
    var isReady: Signal<Bool, NoError> {
        return self.ready.get()
    }

    private let statusPromise = Promise<PeerInfoStatusData?>(nil)
    var status: Signal<PeerInfoStatusData?, NoError> {
        self.statusPromise.get()
    }
            
    private var starsProducts: [ProfileGiftsContext.State.StarGift]?
    private var starsItems: [AnyHashable: (StarGiftReference?, ComponentView<Empty>)] = [:]

    // Visual-only gifts. These never enter ProfileGiftsContext or Telegram's
    // Postbox cache, and no purchase/transfer request is made for them.
    private var localDemoGifts: [StarGift.UniqueGift] = []
    private var localDemoWallet = YRSLDemoGiftWallet()
    private var localGiftRequestDisposable: Disposable?
    private let localGiftButton = UIButton(type: .system)

    private(set) var resultsAreEmpty = false
    private var filteredResultsAreEmpty = false
    
    var onContentUpdated: () -> Void = { }
    
    private(set) var selectedItemIds = Set<AnyHashable>()
    private var selectedItemsMap: [AnyHashable: ProfileGiftsContext.State.StarGift] = [:]
    var selectionUpdated: () -> Void = { }
    
    var displayUnpinScreen: ((ProfileGiftsContext.State.StarGift, (() -> Void)?) -> Void)?
    
    var selectedItems: [ProfileGiftsContext.State.StarGift] {
        var gifts: [ProfileGiftsContext.State.StarGift] = []
        var existingIds = Set<AnyHashable>()
        if let currentGifts = self.profileGifts.currentState?.gifts {
            for gift in currentGifts {
                if let itemId = gift.reference?.stringValue {
                    if self.selectedItemIds.contains(itemId) {
                        gifts.append(gift)
                        existingIds.insert(itemId)
                    }
                }
            }
        }
        for itemId in self.selectedItemIds {
            if !existingIds.contains(itemId), let item = self.selectedItemsMap[itemId] {
                gifts.append(item)
            }
        }
        return gifts
    }
    
    private(set) var pinnedReferences: [StarGiftReference] = []
    private var isReordering: Bool = false
    private var reorderingItem: (id: AnyHashable, initialPosition: CGPoint, position: CGPoint)?
    private var reorderedReferences: [StarGiftReference]? {
        didSet {
            self.reorderedReferencesPromise.set(self.reorderedReferences)
        }
    }
    private var reorderedReferencesPromise = ValuePromise<[StarGiftReference]?>(nil)
    
    private var reorderedPinnedReferences: Set<StarGiftReference>? {
        didSet {
            self.reorderedPinnedReferencesPromise.set(self.reorderedPinnedReferences)
        }
    }
    private var reorderedPinnedReferencesPromise = ValuePromise<Set<StarGiftReference>?>(nil)
    
    private var reorderRecognizer: ReorderGestureRecognizer?
    
    let maxPinnedCount: Int
    
    var contextAction: ((ProfileGiftsContext.State.StarGift, UIView, ContextGesture) -> Void)?
    var addToCollection: (() -> Void)?
    
    init(context: AccountContext, peerId: EnginePeer.Id, profileGifts: ProfileGiftsContext, giftsCollections: ProfileGiftsCollectionsContext?, canSelect: Bool, ignoreCollection: Int32? = nil, remainingSelectionCount: Int32 = 0) {
        self.context = context
        self.peerId = peerId
        self.profileGifts = profileGifts
        self.giftsCollections = giftsCollections
        self.canSelect = canSelect
        self.ignoreCollection = ignoreCollection
        self.remainingSelectionCount = remainingSelectionCount
                
        if let value = context.currentAppConfiguration.with({ $0 }).data?["stargifts_pinned_to_top_limit"] as? Double {
            self.maxPinnedCount = Int(value)
        } else {
            self.maxPinnedCount = 6
        }
        
        super.init(frame: .zero)

        if peerId == context.account.peerId && !canSelect && profileGifts.collectionId == nil {
            self.loadLocalDemoGifts()
            self.loadLocalDemoWallet()
            self.updateLocalDemoButtonTitle()
            self.localGiftButton.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
            self.localGiftButton.layer.cornerRadius = 12.0
            self.localGiftButton.addTarget(self, action: #selector(self.showLocalDemoMarket), for: .touchUpInside)
            self.addSubview(self.localGiftButton)
        }
                                        
        self.dataDisposable = combineLatest(
            queue: Queue.mainQueue(),
            profileGifts.state,
            self.reorderedReferencesPromise.get()
        ).startStrict(next: { [weak self] state, reorderedReferences in
            guard let self else {
                return
            }
            let isFirstTime = self.starsProducts == nil
            let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
            let localCount = self.canDisplayLocalDemoGifts(filter: state.filter) ? Int32(self.localDemoGifts.count) : 0
            self.statusPromise.set(.single(PeerInfoStatusData(text: presentationData.strings.SharedMedia_GiftCount((state.count ?? 0) + localCount), isActivity: true, key: .gifts)))
            
            if self.isReordering {
                var stateItems: [ProfileGiftsContext.State.StarGift] = state.gifts
                if let reorderedReferences {
                    var fixedStateItems: [ProfileGiftsContext.State.StarGift] = []
                    
                    var seenIds = Set<StarGiftReference>()
                    for reference in reorderedReferences {
                        if let index = stateItems.firstIndex(where: { $0.reference == reference }) {
                            seenIds.insert(reference)
                            var item = stateItems[index]
                            if self.reorderedPinnedReferences?.contains(reference) == true, !item.pinnedToTop {
                                item = item.withPinnedToTop(true)
                            }
                            fixedStateItems.append(item)
                        }
                    }
                    
                    for item in stateItems {
                        if let reference = item.reference, !seenIds.contains(reference) {
                            var item = item
                            if self.reorderedPinnedReferences?.contains(reference) == true, !item.pinnedToTop {
                                item = item.withPinnedToTop(true)
                            }
                            fixedStateItems.append(item)
                        }
                    }
                    stateItems = fixedStateItems
                }
                self.starsProducts = stateItems
                self.pinnedReferences = Array(stateItems.filter { $0.pinnedToTop }.compactMap { $0.reference })
            } else {
                self.starsProducts = self.localDemoProfileGifts(filter: state.filter) + state.filteredGifts
                self.pinnedReferences = Array(state.gifts.filter { $0.pinnedToTop }.compactMap { $0.reference })
            }
            
            self.resultsAreEmpty = state.filter == .All && state.gifts.isEmpty && self.localDemoGifts.isEmpty && state.dataState != .loading
            self.filteredResultsAreEmpty = state.filter != .All && state.filteredGifts.isEmpty && self.localDemoProfileGifts(filter: state.filter).isEmpty
        
            if !self.didSetReady {
                self.didSetReady = true
                self.ready.set(.single(true))
            }
            
            let _ = self.updateScrolling(transition: isFirstTime ? .immediate : .easeInOut(duration: 0.25))
            
            Queue.mainQueue().justDispatch {
                self.onContentUpdated()
            }
        })
        
        self.emptyResultsClippingView.clipsToBounds = true
        self.emptyResultsClippingView.isHidden = true
        self.addSubview(self.emptyResultsClippingView)
        
        let reorderRecognizer = ReorderGestureRecognizer(
            shouldBegin: { [weak self] point in
                guard let self, let (id, item) = self.item(at: point) else {
                    return (allowed: false, requiresLongPress: false, id: nil, item: nil)
                }
                return (allowed: true, requiresLongPress: false, id: id, item: item)
            },
            willBegin: { point in
            },
            began: { [weak self] item in
                guard let self else {
                    return
                }
                self.setReorderingItem(item: item)
            },
            ended: { [weak self] in
                guard let self else {
                    return
                }
                self.setReorderingItem(item: nil)
            },
            moved: { [weak self] distance in
                guard let self else {
                    return
                }
                self.moveReorderingItem(distance: distance)
            },
            isActiveUpdated: { _ in
            }
        )
        self.reorderRecognizer = reorderRecognizer
        self.addGestureRecognizer(reorderRecognizer)
        reorderRecognizer.isEnabled = false
    }
    
    required init?(coder: NSCoder) {
        preconditionFailure()
    }
    
    deinit {
        self.dataDisposable?.dispose()
        self.localGiftRequestDisposable?.dispose()
    }

    private var localDemoStorageKey: String {
        return "YRSL.LocalGiftDisplay.\(self.context.account.peerId.toInt64())"
    }

    private var localDemoWalletKey: String {
        return "YRSL.LocalGiftWallet.v1.\(self.context.account.peerId.toInt64())"
    }

    private func loadLocalDemoWallet() {
        guard let data = UserDefaults.standard.data(forKey: self.localDemoWalletKey),
              let wallet = try? JSONDecoder().decode(YRSLDemoGiftWallet.self, from: data) else {
            return
        }
        self.localDemoWallet = wallet
        self.localDemoWallet.balance = min(100_000_000, max(0, wallet.balance))
    }

    private func saveLocalDemoWallet() {
        self.localDemoWallet.history = Array(self.localDemoWallet.history.prefix(100))
        self.localDemoWallet.catalog = Array(self.localDemoWallet.catalog.prefix(30))
        if let data = try? JSONEncoder().encode(self.localDemoWallet) {
            UserDefaults.standard.set(data, forKey: self.localDemoWalletKey)
        }
        self.updateLocalDemoButtonTitle()
    }

    private func updateLocalDemoButtonTitle() {
        self.localGiftButton.setTitle("🎁 Демо-маркет   ⭐ \(self.localDemoWallet.balance)", for: .normal)
    }

    private func recordLocalDemoEvent(_ text: String) {
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        self.localDemoWallet.history.insert("\(date) · \(text)", at: 0)
        self.saveLocalDemoWallet()
    }

    private func demoGiftKey(_ id: Int64) -> String {
        return String(id)
    }

    private func loadLocalDemoGifts() {
        guard let data = UserDefaults.standard.data(forKey: self.localDemoStorageKey),
              let gifts = try? JSONDecoder().decode([StarGift.UniqueGift].self, from: data) else {
            return
        }
        self.localDemoGifts = Array(gifts.prefix(100))
    }

    private func saveLocalDemoGifts() {
        if let data = try? JSONEncoder().encode(self.localDemoGifts) {
            UserDefaults.standard.set(data, forKey: self.localDemoStorageKey)
        }
    }

    private func canDisplayLocalDemoGifts(filter: ProfileGiftsContext.Filters) -> Bool {
        return self.peerId == self.context.account.peerId
            && !self.canSelect
            && self.profileGifts.collectionId == nil
            && filter.contains(.unique)
    }

    private func localDemoProfileGifts(filter: ProfileGiftsContext.Filters) -> [ProfileGiftsContext.State.StarGift] {
        guard self.canDisplayLocalDemoGifts(filter: filter) else {
            return []
        }
        let orderedGifts = self.localDemoGifts.sorted { lhs, rhs in
            let lhsPinned = self.localDemoWallet.pinnedGiftIds.contains(lhs.id)
            let rhsPinned = self.localDemoWallet.pinnedGiftIds.contains(rhs.id)
            return lhsPinned && !rhsPinned
        }
        return orderedGifts.map { gift in
            ProfileGiftsContext.State.StarGift(
                gift: .unique(gift),
                reference: nil,
                fromPeer: nil,
                date: Int32(Date().timeIntervalSince1970),
                text: nil,
                entities: nil,
                nameHidden: true,
                savedToProfile: true,
                pinnedToTop: self.localDemoWallet.pinnedGiftIds.contains(gift.id),
                convertStars: nil,
                canUpgrade: false,
                canExportDate: nil,
                upgradeStars: nil,
                transferStars: nil,
                canTransferDate: nil,
                canResaleDate: nil,
                collectionIds: nil,
                prepaidUpgradeHash: nil,
                upgradeSeparate: false,
                dropOriginalDetailsStars: nil,
                number: nil,
                isRefunded: false,
                canCraftAt: nil
            )
        }
    }

    private func isLocalDemoGift(_ product: ProfileGiftsContext.State.StarGift) -> Bool {
        guard case let .unique(gift) = product.gift else {
            return false
        }
        return self.localDemoGifts.contains(where: { $0.id == gift.id })
    }

    private func refreshLocalDemoGifts() {
        guard let state = self.profileGifts.currentState else {
            return
        }
        let localIds = Set(self.localDemoGifts.map { $0.id })
        let realProducts = (self.starsProducts ?? []).filter { product in
            if case let .unique(gift) = product.gift {
                return gift.id >= 0 && !localIds.contains(gift.id)
            }
            return true
        }
        self.starsProducts = self.localDemoProfileGifts(filter: state.filter) + realProducts
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let localCount = self.canDisplayLocalDemoGifts(filter: state.filter) ? Int32(self.localDemoGifts.count) : 0
        self.statusPromise.set(.single(PeerInfoStatusData(text: presentationData.strings.SharedMedia_GiftCount((state.count ?? 0) + localCount), isActivity: true, key: .gifts)))
        self.resultsAreEmpty = state.filter == .All && state.gifts.isEmpty && self.localDemoGifts.isEmpty && state.dataState != .loading
        self.filteredResultsAreEmpty = state.filter != .All && state.filteredGifts.isEmpty && self.localDemoProfileGifts(filter: state.filter).isEmpty
        self.updateScrolling(transition: .easeInOut(duration: 0.25))
        self.onContentUpdated()
    }

    private func showLocalGiftMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.parentController?.present(alert, animated: true)
    }

    private func presentLocalDemoMenu(_ alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = self.localGiftButton
            popover.sourceRect = self.localGiftButton.bounds
        }
        self.parentController?.present(alert, animated: true)
    }

    @objc private func showLocalDemoMarket() {
        let alert = UIAlertController(
            title: "Подарки · демо",
            message: "⭐ \(self.localDemoWallet.balance) · Все покупки и отправки существуют только на этом iPhone.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Маркет коллекционных подарков", style: .default, handler: { [weak self] _ in
            self?.showLocalCatalog()
        }))
        alert.addAction(UIAlertAction(title: "Пополнить демо-Stars", style: .default, handler: { [weak self] _ in
            self?.showLocalDemoTopUp()
        }))
        alert.addAction(UIAlertAction(title: "Подарить демо-Stars", style: .default, handler: { [weak self] _ in
            self?.promptLocalDemoStarsGift()
        }))
        alert.addAction(UIAlertAction(title: "История операций", style: .default, handler: { [weak self] _ in
            self?.showLocalDemoHistory()
        }))
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.presentLocalDemoMenu(alert)
    }

    private func showLocalCatalog() {
        let alert = UIAlertController(
            title: "Маркет NFT · демо",
            message: "Выбери просмотренный подарок или найди настоящий NFT по ссылке t.me/nft/…",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Поиск подарка по ссылке", style: .default, handler: { [weak self] _ in
            self?.addLocalGiftPressed()
        }))
        for source in self.localDemoWallet.catalog.prefix(12) {
            alert.addAction(UIAlertAction(title: "\(source.title) #\(source.number)", style: .default, handler: { [weak self] _ in
                self?.showLocalGiftOffer(source, number: source.number, price: self?.localDemoPrice(for: source) ?? 1_000)
            }))
        }
        alert.addAction(UIAlertAction(title: "Назад", style: .cancel))
        self.presentLocalDemoMenu(alert)
    }

    private func localDemoPrice(for source: StarGift.UniqueGift) -> Int64 {
        return max(1, source.resellAmounts?.first(where: { $0.currency == .stars })?.amount.value ?? 1_000)
    }

    private func showLocalGiftOffer(_ source: StarGift.UniqueGift, number: Int32, price: Int64) {
        let alert = UIAlertController(
            title: "\(source.title) #\(number)",
            message: "Цена: ⭐ \(price) · Баланс: ⭐ \(self.localDemoWallet.balance)\nДемо-покупка: реальные Stars не списываются.",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "Посмотреть подарок", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            // The preview has no marketplace owner or server reference.
            let preview = self.copyLocalGift(source, id: -9_999_999_999, number: number)
            self.parentController?.push(GiftViewScreen(context: self.context, subject: .uniqueGift(preview, self.peerId)))
        }))
        alert.addAction(UIAlertAction(title: "Купить себе · ⭐ \(price)", style: .default, handler: { [weak self] _ in
            self?.confirmLocalDemoPurchase(source, number: number, price: price, recipient: nil)
        }))
        alert.addAction(UIAlertAction(title: "Отправить другу · ⭐ \(price)", style: .default, handler: { [weak self] _ in
            self?.promptLocalDemoRecipient(title: "Отправить \(source.title)", message: "Введи имя или @username. Друг ничего не получит: это локальная демонстрация.") { [weak self] recipient in
                self?.confirmLocalDemoPurchase(source, number: number, price: price, recipient: recipient)
            }
        }))
        alert.addAction(UIAlertAction(title: "Изменить демо-цену", style: .default, handler: { [weak self] _ in
            self?.promptLocalDemoAmount(title: "Цена NFT", initial: price) { [weak self] amount in
                self?.showLocalGiftOffer(source, number: number, price: amount)
            }
        }))
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.presentLocalDemoMenu(alert)
    }

    private func confirmLocalDemoPurchase(_ source: StarGift.UniqueGift, number: Int32, price: Int64, recipient: String?) {
        guard price > 0, self.localDemoWallet.balance >= price else {
            self.showLocalGiftMessage("Недостаточно демо-Stars", "Пополнить локальный баланс можно в меню подарков.")
            return
        }
        let target = recipient.map { "для \($0)" } ?? "для себя"
        let alert = UIAlertController(title: "Покупка \(target)", message: "\(source.title) #\(number) за ⭐ \(price)\nЭто только демонстрация на твоём устройстве.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Подтвердить", style: .default, handler: { [weak self] _ in
            guard let self, self.localDemoWallet.balance >= price else { return }
            self.localDemoWallet.balance -= price
            if let recipient {
                self.recordLocalDemoEvent("Подарок \(source.title) #\(number) → \(recipient): −⭐\(price) (демо)")
                self.showLocalGiftMessage("Подарок отправлен · демо", "Отправка отображается в истории этого приложения. У получателя в Telegram ничего не появилось.")
            } else {
                var id = -Int64(Date().timeIntervalSince1970 * 1000.0)
                while self.localDemoGifts.contains(where: { $0.id == id }) { id -= 1 }
                let gift = self.copyLocalGift(source, id: id, number: number)
                self.localDemoGifts.insert(gift, at: 0)
                self.localDemoGifts = Array(self.localDemoGifts.prefix(100))
                self.localDemoWallet.purchasePrices[self.demoGiftKey(id)] = price
                self.saveLocalDemoGifts()
                self.recordLocalDemoEvent("Куплен \(source.title) #\(number): −⭐\(price) (демо)")
                self.refreshLocalDemoGifts()
                self.showLocalGiftMessage("Подарок в коллекции", "Он появился в твоём профиле только в модифицированном Telegram.")
            }
        }))
        self.parentController?.present(alert, animated: true)
    }

    private func promptLocalDemoAmount(title: String, initial: Int64, completion: @escaping (Int64) -> Void) {
        let alert = UIAlertController(title: title, message: "Укажи положительное количество демо-Stars (до 100 миллионов).", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = String(initial)
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Далее", style: .default, handler: { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text,
                  let amount = Int64(value), (1...100_000_000).contains(amount) else {
                self?.showLocalGiftMessage("Неверное количество", "Укажи число от 1 до 100 000 000.")
                return
            }
            completion(amount)
        }))
        self.parentController?.present(alert, animated: true)
    }

    private func promptLocalDemoRecipient(title: String, message: String, completion: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "@username"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Далее", style: .default, handler: { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty && name.count <= 64 && !name.contains("\n") else {
                self?.showLocalGiftMessage("Укажи получателя", "Введи имя или @username длиной до 64 символов.")
                return
            }
            completion(name)
        }))
        self.parentController?.present(alert, animated: true)
    }

    private func showLocalDemoTopUp() {
        let alert = UIAlertController(title: "Пополнить демо-Stars", message: "Баланс: ⭐ \(self.localDemoWallet.balance). Настоящие Stars не начисляются.", preferredStyle: .actionSheet)
        for amount in [Int64(1_000), 10_000, 100_000, 1_000_000] {
            alert.addAction(UIAlertAction(title: "+ ⭐ \(amount)", style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.localDemoWallet.balance = min(100_000_000, self.localDemoWallet.balance + amount)
                self.recordLocalDemoEvent("Пополнение демо-баланса: +⭐\(amount)")
                self.showLocalGiftMessage("Баланс обновлён", "Доступно ⭐ \(self.localDemoWallet.balance) только в локальном демо.")
            }))
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.presentLocalDemoMenu(alert)
    }

    private func promptLocalDemoStarsGift() {
        self.promptLocalDemoAmount(title: "Подарить демо-Stars", initial: 1_000) { [weak self] amount in
            guard let self else { return }
            self.promptLocalDemoRecipient(title: "Кому подарить ⭐ \(amount)?", message: "Получатель увидит это только в истории на твоём iPhone.") { [weak self] recipient in
                guard let self else { return }
                guard self.localDemoWallet.balance >= amount else {
                    self.showLocalGiftMessage("Недостаточно демо-Stars", "Пополнить баланс можно в меню подарков.")
                    return
                }
                self.localDemoWallet.balance -= amount
                self.recordLocalDemoEvent("Демо-Stars → \(recipient): −⭐\(amount)")
                self.showLocalGiftMessage("Stars подарены · демо", "Запись добавлена в локальную историю. Настоящие звёзды не передавались.")
            }
        }
    }

    private func showLocalDemoHistory() {
        let history = self.localDemoWallet.history.prefix(12).joined(separator: "\n\n")
        self.showLocalGiftMessage("История · демо", history.isEmpty ? "Операций пока нет." : history)
    }

    @objc private func addLocalGiftPressed() {
        let alert = UIAlertController(
            title: "Найти NFT на маркете",
            message: "Вставь ссылку настоящего коллекционного подарка. Затем выбери демо-покупку себе или другу.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "https://t.me/nft/PlushPepe-1234"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Номер (необязательно)"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Найти", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields,
                  let raw = fields.first?.text,
                  let slug = self.localGiftSlug(from: raw) else {
                self?.showLocalGiftMessage("Неверная ссылка", "Вставь адрес вида t.me/nft/PlushPepe-1234")
                return
            }
            let desiredNumber: Int32?
            if let entered = fields.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !entered.isEmpty {
                guard let number = Int32(entered), number > 0 else {
                    self.showLocalGiftMessage("Неверный номер", "Укажи положительное целое число.")
                    return
                }
                desiredNumber = number
            } else {
                desiredNumber = nil
            }
            self.localGiftRequestDisposable?.dispose()
            self.localGiftRequestDisposable = (self.context.engine.payments.getUniqueStarGift(slug: slug)
            |> deliverOnMainQueue).start(next: { [weak self] source in
                guard let self else { return }
                let number = desiredNumber ?? source.number
                self.localDemoWallet.catalog.removeAll(where: { $0.slug == source.slug })
                self.localDemoWallet.catalog.insert(source, at: 0)
                self.saveLocalDemoWallet()
                self.showLocalGiftOffer(source, number: number, price: self.localDemoPrice(for: source))
            }, error: { [weak self] _ in
                self?.showLocalGiftMessage("Не удалось загрузить", "Telegram не нашёл такой NFT. Проверь ссылку и подключение к сети.")
            })
        }))
        self.parentController?.present(alert, animated: true)
    }

    private func localGiftSlug(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("/") {
            guard let url = URL(string: text.hasPrefix("http") ? text : "https://\(text)"),
                  let host = url.host?.lowercased(),
                  ["t.me", "www.t.me", "telegram.me", "www.telegram.me"].contains(host) else {
                return nil
            }
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, parts[0].lowercased() == "nft" else { return nil }
            return parts[1]
        }
        return text.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? text : nil
    }

    private func copyLocalGift(_ source: StarGift.UniqueGift, id: Int64, number: Int32) -> StarGift.UniqueGift {
        let attributes = source.attributes.filter { attribute in
            if case .originalInfo = attribute { return false }
            return true
        }
        return StarGift.UniqueGift(
            id: id,
            giftId: source.giftId,
            title: source.title,
            number: number,
            slug: source.slug,
            owner: .peerId(self.context.account.peerId),
            attributes: attributes,
            availability: source.availability,
            giftAddress: nil,
            resellAmounts: nil,
            resellForTonOnly: false,
            releasedBy: source.releasedBy,
            valueAmount: nil,
            valueCurrency: nil,
            valueUsdAmount: nil,
            flags: [],
            themePeerId: nil,
            peerColor: nil,
            hostPeerId: nil,
            minOfferStars: nil,
            craftChancePermille: nil
        )
    }

    private func showLocalGiftOptions(_ product: ProfileGiftsContext.State.StarGift) {
        guard case let .unique(gift) = product.gift else { return }
        let key = self.demoGiftKey(gift.id)
        let salePrice = self.localDemoWallet.resalePrices[key]
        let isPinned = self.localDemoWallet.pinnedGiftIds.contains(gift.id)
        let alert = UIAlertController(title: "\(gift.title) #\(gift.number)", message: "Коллекционный подарок · локальное демо", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Посмотреть подарок", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            self.parentController?.push(GiftViewScreen(context: self.context, subject: .uniqueGift(gift, self.peerId)))
        }))
        alert.addAction(UIAlertAction(title: isPinned ? "Открепить от профиля" : "Закрепить в профиле", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            if isPinned {
                self.localDemoWallet.pinnedGiftIds.removeAll(where: { $0 == gift.id })
            } else {
                if self.localDemoWallet.pinnedGiftIds.count + self.pinnedReferences.count >= self.maxPinnedCount {
                    self.showLocalGiftMessage("Достигнут лимит", "Можно закрепить максимум \(self.maxPinnedCount) подарков.")
                    return
                }
                self.localDemoWallet.pinnedGiftIds.append(gift.id)
            }
            self.saveLocalDemoWallet()
            self.refreshLocalDemoGifts()
        }))
        alert.addAction(UIAlertAction(title: "Передать подарок", style: .default, handler: { [weak self] _ in
            self?.promptLocalDemoRecipient(title: "Передать \(gift.title)", message: "Подарок исчезнет из твоей локальной коллекции, но другой пользователь его не получит.") { [weak self] recipient in
                guard let self else { return }
                self.removeLocalDemoGift(gift.id)
                self.recordLocalDemoEvent("Передан \(gift.title) #\(gift.number) → \(recipient) (демо)")
                self.showLocalGiftMessage("Подарок передан · демо", "Передача записана в истории только на этом iPhone.")
            }
        }))
        if let salePrice {
            alert.addAction(UIAlertAction(title: "Снять с продажи · ⭐ \(salePrice)", style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.localDemoWallet.resalePrices.removeValue(forKey: key)
                self.recordLocalDemoEvent("Снят с продажи \(gift.title) #\(gift.number)")
                self.refreshLocalDemoGifts()
            }))
            alert.addAction(UIAlertAction(title: "Симулировать продажу · ⭐ \(salePrice)", style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.removeLocalDemoGift(gift.id)
                self.localDemoWallet.balance = min(100_000_000, self.localDemoWallet.balance + salePrice)
                self.recordLocalDemoEvent("Продан \(gift.title) #\(gift.number): +⭐\(salePrice) (демо)")
                self.showLocalGiftMessage("Подарок продан · демо", "Демо-Stars начислены локально. На настоящем маркете ничего не продавалось.")
            }))
        } else {
            alert.addAction(UIAlertAction(title: "Выставить на продажу", style: .default, handler: { [weak self] _ in
                guard let self else { return }
                let suggested = self.localDemoWallet.purchasePrices[key] ?? 1_000
                self.promptLocalDemoAmount(title: "Цена перепродажи", initial: suggested) { [weak self] price in
                    guard let self else { return }
                    self.localDemoWallet.resalePrices[key] = price
                    self.recordLocalDemoEvent("Выставлен \(gift.title) #\(gift.number) за ⭐\(price) (демо)")
                    self.refreshLocalDemoGifts()
                }
            }))
        }
        let convertAmount = max(1, (self.localDemoWallet.purchasePrices[key] ?? 1_000) / 2)
        alert.addAction(UIAlertAction(title: "Обменять на ⭐ \(convertAmount)", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            let confirm = UIAlertController(title: "Обменять на Stars?", message: "Подарок будет удалён из демо-коллекции, а ⭐\(convertAmount) появятся в демо-кошельке.", preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            confirm.addAction(UIAlertAction(title: "Обменять", style: .destructive, handler: { [weak self] _ in
                guard let self else { return }
                self.removeLocalDemoGift(gift.id)
                self.localDemoWallet.balance = min(100_000_000, self.localDemoWallet.balance + convertAmount)
                self.recordLocalDemoEvent("Обменян \(gift.title) #\(gift.number): +⭐\(convertAmount) (демо)")
            }))
            self.parentController?.present(confirm, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Изменить номер", style: .default, handler: { [weak self] _ in
            guard let self else { return }
            let edit = UIAlertController(title: "Номер подарка", message: nil, preferredStyle: .alert)
            edit.addTextField { field in
                field.text = "\(gift.number)"
                field.keyboardType = .numberPad
            }
            edit.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            edit.addAction(UIAlertAction(title: "Сохранить", style: .default, handler: { [weak self, weak edit] _ in
                guard let self, let text = edit?.textFields?.first?.text,
                      let number = Int32(text), number > 0,
                      let index = self.localDemoGifts.firstIndex(where: { $0.id == gift.id }) else { return }
                self.localDemoGifts[index] = self.copyLocalGift(self.localDemoGifts[index], id: gift.id, number: number)
                self.saveLocalDemoGifts()
                self.refreshLocalDemoGifts()
            }))
            self.parentController?.present(edit, animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Удалить из демонстрации", style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            self.removeLocalDemoGift(gift.id)
            self.recordLocalDemoEvent("Удалён \(gift.title) #\(gift.number) из демо-коллекции")
        }))
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        self.presentLocalDemoMenu(alert)
    }

    private func removeLocalDemoGift(_ id: Int64) {
        self.localDemoGifts.removeAll(where: { $0.id == id })
        self.localDemoWallet.purchasePrices.removeValue(forKey: self.demoGiftKey(id))
        self.localDemoWallet.resalePrices.removeValue(forKey: self.demoGiftKey(id))
        self.localDemoWallet.pinnedGiftIds.removeAll(where: { $0 == id })
        self.saveLocalDemoGifts()
        self.saveLocalDemoWallet()
        self.refreshLocalDemoGifts()
    }
        
    func item(at point: CGPoint) -> (AnyHashable, ComponentView<Empty>)? {
        for (id, visibleItem) in self.starsItems {
            if let view = visibleItem.1.view, view.frame.contains(point), let reference = visibleItem.0, self.isCollection || self.pinnedReferences.contains(reference) {
                return (id, visibleItem.1)
            }
        }
        return nil
    }
        
    func beginReordering() {
        self.profileGifts.updateFilter(.All)
        self.profileGifts.updateSorting(.date)
        
        if let parentController = self.parentController as? PeerInfoScreen {
            parentController.togglePaneIsReordering(isReordering: true)
        } else {
            self.updateIsReordering(isReordering: true, animated: true)
        }
    }
    
    func endReordering() {
        if let parentController = self.parentController as? PeerInfoScreen {
            parentController.togglePaneIsReordering(isReordering: false)
        } else {
            self.updateIsReordering(isReordering: false, animated: true)
        }
    }
    
    func updateIsReordering(isReordering: Bool, animated: Bool) {
        if self.isReordering != isReordering {
            self.isReordering = isReordering
            
            self.reorderRecognizer?.isEnabled = isReordering
            
            if !isReordering, let _ = self.reorderedReferences, let starsProducts = self.starsProducts {
                if let collectionId = self.profileGifts.collectionId {
                    var orderedReferences: [StarGiftReference] = []
                    for gift in starsProducts {
                        if let reference = gift.reference {
                            orderedReferences.append(reference)
                        }
                    }
                    let _ = self.giftsCollections?.reorderGifts(id: collectionId, gifts: orderedReferences).start()
                } else {
                    var pinnedReferences: [StarGiftReference] = []
                    for gift in starsProducts.prefix(self.maxPinnedCount) {
                        if gift.pinnedToTop, let reference = gift.reference {
                            pinnedReferences.append(reference)
                        }
                    }
                    self.profileGifts.updatePinnedToTopStarGifts(references: pinnedReferences)
                }
                
                Queue.mainQueue().after(1.0) {
                    self.reorderedReferences = nil
                    self.reorderedPinnedReferences = nil
                }
            }
            
            self.updateScrolling(transition: animated ? .spring(duration: 0.4) : .immediate)
        }
    }
    
    func setReorderingItem(item: AnyHashable?) {
        var mappedItem: (AnyHashable, ComponentView<Empty>)?
        for (id, visibleItem) in self.starsItems {
            if id == item {
                mappedItem = (id, visibleItem.1)
                break
            }
        }
        
        if self.reorderingItem?.id != mappedItem?.0 {
            if let (id, visibleItem) = mappedItem, let view = visibleItem.view {
                self.addSubview(view)
                self.reorderingItem = (id, view.center, view.center)
            } else {
                self.reorderingItem = nil
            }
            self.updateScrolling(transition: item == nil ? .spring(duration: 0.3) : .immediate)
        }
    }
    
    func moveReorderingItem(distance: CGPoint) {
        if let (id, initialPosition, _) = self.reorderingItem {
            let targetPosition = CGPoint(x: initialPosition.x + distance.x, y: initialPosition.y + distance.y)
            self.reorderingItem = (id, initialPosition, targetPosition)
            self.updateScrolling(transition: .immediate)
            
            if let starsProducts = self.starsProducts, let visibleReorderingItem = self.starsItems[id] {
                for (_, visibleItem) in self.starsItems {
                    if visibleItem.1 === visibleReorderingItem.1 {
                        continue
                    }
                    if let view = visibleItem.1.view, view.frame.contains(targetPosition), let reorderItemReference = self.starsItems[id]?.0 {
                        if let targetIndex = starsProducts.firstIndex(where: { $0.reference == visibleItem.0 }) {
                            self.reorderIfPossible(reference: reorderItemReference, toIndex: targetIndex)
                        }
                        break
                    }
                }
            }
        }
    }
    
    private var isCollection: Bool {
        return self.profileGifts.collectionId != nil
    }
    
    private func reorderIfPossible(reference: StarGiftReference, toIndex: Int) {
        if let items = self.starsProducts {
            var toIndex = toIndex
            
            let maxPinnedIndex: Int?
            if self.isCollection {
                maxPinnedIndex = items.count - 1
            } else {
                maxPinnedIndex = items.lastIndex(where: { $0.pinnedToTop })
            }
            if let maxPinnedIndex {
                toIndex = min(toIndex, maxPinnedIndex)
            } else {
                return
            }
            
            var ids = items.compactMap { item -> StarGiftReference? in
                return item.reference
            }
            
            if let fromIndex = ids.firstIndex(of: reference) {
                if fromIndex < toIndex {
                    ids.insert(reference, at: toIndex + 1)
                    ids.remove(at: fromIndex)
                } else if fromIndex > toIndex {
                    ids.remove(at: fromIndex)
                    ids.insert(reference, at: toIndex)
                }
            }
            if self.reorderedReferences != ids {
                self.reorderedReferences = ids
                
                HapticFeedback().tap()
            }
        }
    }
                    
    func loadMore() {
        self.profileGifts.loadMore()
    }
    
    @discardableResult
    private func updateScrolling(interactive: Bool = false, transition: ComponentTransition) -> CGFloat {
        guard let topInset = self.topInset, let visibleBounds = self.visibleBounds else {
            return 0.0
        }
        return self.updateScrolling(interactive: interactive, topInset: topInset, visibleBounds: visibleBounds, transition: transition)
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let topInset = self.topInset, point.y < topInset {
            return false
        }
        return super.point(inside: point, with: event)
    }
        
    func updateScrolling(interactive: Bool = false, topInset: CGFloat, visibleBounds: CGRect, transition: ComponentTransition) -> CGFloat {
        self.topInset = topInset
        self.visibleBounds = visibleBounds
        
        guard let starsProducts = self.starsProducts, let params = self.currentParams else {
            return 0.0
        }
        
        let optionSpacing: CGFloat = 10.0
        let itemsSideInset = params.sideInset + 16.0
        
        let defaultItemsInRow: Int
        if params.size.width > params.size.height || params.size.width > 480.0 {
            if case .tablet = params.deviceMetrics.type {
                defaultItemsInRow = 4
            } else {
                defaultItemsInRow = 5
            }
        } else {
            defaultItemsInRow = 3
        }
        let itemsInRow = max(1, min(starsProducts.count, defaultItemsInRow))
        let defaultOptionWidth = (params.size.width - itemsSideInset * 2.0 - optionSpacing * CGFloat(defaultItemsInRow - 1)) / CGFloat(defaultItemsInRow)
        let optionWidth = (params.size.width - itemsSideInset * 2.0 - optionSpacing * CGFloat(itemsInRow - 1)) / CGFloat(itemsInRow)
        
        let starsOptionSize = CGSize(width: optionWidth, height: defaultOptionWidth)
                    
        var validIds: [AnyHashable] = []
        var itemFrame = CGRect(origin: CGPoint(x: itemsSideInset, y: topInset), size: starsOptionSize)
        
        var index: Int32 = 0
        for product in starsProducts {
            var isVisible = false
            if visibleBounds.intersects(itemFrame) {
                isVisible = true
            }
            
            if isVisible {
                let info: String
                switch product.gift {
                case let .generic(gift):
                    info = "g_\(gift.id)"
                case let .unique(gift):
                    info = "u_\(gift.id)"
                }
                let stableId = product.reference?.stringValue ?? "\(index)"
                let id = "\(stableId)_\(info)"
                let itemId = AnyHashable(id)
                validIds.append(itemId)
                
                var itemTransition = transition
                let visibleItem: ComponentView<Empty>
                if let (_, current) = self.starsItems[itemId] {
                    visibleItem = current
                } else {
                    visibleItem = ComponentView()
                    self.starsItems[itemId] = (product.reference, visibleItem)
                    itemTransition = .immediate
                }
                
                var ribbonText: String?
                var ribbonColor: GiftItemComponent.Ribbon.Color = .blue
                var ribbonFont: GiftItemComponent.Ribbon.Font = .generic
                var ribbonOutline: UIColor?
                
                let peer: GiftItemComponent.Peer?
                let subject: GiftItemComponent.Subject
                var resellAmount: CurrencyAmount?
                
                switch product.gift {
                case let .generic(gift):
                    subject = .starGift(gift: gift, price: "# \(gift.price)")
                    peer = product.fromPeer.flatMap { .peer($0) } ?? .anonymous
                    
                    if let availability = gift.availability {
                        ribbonText = params.presentationData.strings.PeerInfo_Gifts_OneOf(compactNumericCountString(Int(availability.total), decimalSeparator: params.presentationData.dateTimeFormat.decimalSeparator)).string
                    } else {
                        ribbonText = nil
                    }
                case let .unique(gift):
                    subject = .uniqueGift(gift: gift, price: nil)
                    if !(product.text ?? "").isEmpty && !product.nameHidden {
                        peer = product.fromPeer.flatMap { .peer($0) }
                    } else {
                        peer = nil
                    }
                    resellAmount = gift.resellAmounts?.first(where: { $0.currency == .stars })
                    
                    if self.isLocalDemoGift(product), let demoResalePrice = self.localDemoWallet.resalePrices[self.demoGiftKey(gift.id)] {
                        ribbonText = "⭐\(demoResalePrice)"
                        ribbonFont = .larger
                        ribbonColor = .green
                    } else if !(gift.resellAmounts ?? []).isEmpty {
                        ribbonText = params.presentationData.strings.PeerInfo_Gifts_Sale
                        ribbonFont = .larger
                        ribbonColor = .green
                        ribbonOutline =  params.presentationData.theme.list.blocksBackgroundColor
                    } else {
                        ribbonFont = .monospaced
                        ribbonText = "#\(gift.number)"
                        for attribute in gift.attributes {
                            if case let .backdrop(_, _, innerColor, outerColor, _, _, _) = attribute {
                                ribbonColor = .custom(outerColor, innerColor)
                                break
                            }
                        }
                    }
                }
                
                let itemReferenceId = product.reference?.stringValue ?? ""
                
                var isAdded = false
                if let ignoreCollection = self.ignoreCollection, let collectionIds = product.collectionIds, collectionIds.contains(ignoreCollection) {
                    isAdded = true
                }
                
                var itemAlpha: CGFloat = 1.0
                if isAdded {
                    itemAlpha = 0.3
                }
                
                let _ = visibleItem.update(
                    transition: itemTransition,
                    component: AnyComponent(
                        GiftItemComponent(
                            context: self.context,
                            style: .glass,
                            theme: params.presentationData.theme,
                            strings: params.presentationData.strings,
                            peer: peer,
                            subject: subject,
                            ribbon: ribbonText.flatMap { GiftItemComponent.Ribbon(text: $0, font: ribbonFont, color: ribbonColor, outline: ribbonOutline) },
                            resellPrice: resellAmount?.amount.value,
                            isHidden: !product.savedToProfile,
                            isSelected: self.selectedItemIds.contains(itemReferenceId),
                            isPinned: !self.canSelect && product.pinnedToTop,
                            isEditing: self.isReordering && !self.isCollection,
                            mode: self.canSelect && !isAdded ? .select : .profile,
                            action: { [weak self] in
                                guard let self, !isAdded, let presentationData = self.currentParams?.presentationData else {
                                    return
                                }
                                if self.isLocalDemoGift(product) {
                                    self.showLocalGiftOptions(product)
                                } else if self.canSelect {
                                    if self.selectedItemIds.contains(itemReferenceId) {
                                        self.selectedItemIds.remove(itemReferenceId)
                                    } else {
                                        if self.selectedItemIds.count < self.remainingSelectionCount {
                                            self.selectedItemIds.insert(itemReferenceId)
                                            self.selectedItemsMap[itemReferenceId] = product
                                        }
                                    }
                                    self.selectionUpdated()
                                    self.updateScrolling(transition: .easeInOut(duration: 0.25))
                                } else if self.isReordering {
                                    if case .unique = product.gift, !product.pinnedToTop, let reference = product.reference, let items = self.starsProducts {
                                        if self.pinnedReferences.count >= self.maxPinnedCount {
                                            self.parentController?.present(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: presentationData.strings.PeerInfo_Gifts_ToastPinLimit_Text(Int32(self.maxPinnedCount)), timeout: nil, customUndoText: nil), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                                            return
                                        }
                                        
                                        var reorderedPinnedReferences = Set<StarGiftReference>()
                                        if let current = self.reorderedPinnedReferences {
                                            reorderedPinnedReferences = current
                                        }
                                        reorderedPinnedReferences.insert(reference)
                                        self.reorderedPinnedReferences = reorderedPinnedReferences
                                                                                    
                                        if let maxPinnedIndex = items.lastIndex(where: { $0.pinnedToTop }) {
                                            var reorderedReferences: [StarGiftReference]
                                            if let current = self.reorderedReferences {
                                                reorderedReferences = current
                                            } else {
                                                let ids = items.compactMap { item -> StarGiftReference? in
                                                    return item.reference
                                                }
                                                reorderedReferences = ids
                                            }
                                            reorderedReferences.removeAll(where: { $0 == reference })
                                            reorderedReferences.insert(reference, at: maxPinnedIndex + 1)
                                            self.reorderedReferences = reorderedReferences
                                        }
                                    }
                                } else {
                                    let realProducts = (self.starsProducts ?? []).filter { !self.isLocalDemoGift($0) }
                                    let allSubjects: [GiftViewScreen.Subject] = realProducts.map { .profileGift(self.peerId, $0) }
                                    let index = realProducts.firstIndex(where: { $0 == product }) ?? 0
                                    
                                    var dismissImpl: (() -> Void)?
                                    let controller = GiftViewScreen(
                                        context: self.context,
                                        subject: .profileGift(self.peerId, product),
                                        allSubjects: allSubjects,
                                        index: index,
                                        profileGiftsContext: self.profileGifts,
                                        updateSavedToProfile: { [weak self] reference, added in
                                            guard let self else {
                                                return
                                            }
                                            self.profileGifts.updateStarGiftAddedToProfile(reference: reference, added: added)
                                        },
                                        convertToStars: { [weak self] reference in
                                            guard let self else {
                                                return
                                            }
                                            self.profileGifts.convertStarGift(reference: reference)
                                        },
                                        dropOriginalDetails: { [weak self] reference in
                                            guard let self else {
                                                return .complete()
                                            }
                                            return self.profileGifts.dropOriginalDetails(reference: reference)
                                        },
                                        transferGift: { [weak self] prepaid, reference, peerId in
                                            guard let self else {
                                                return .complete()
                                            }
                                            return self.profileGifts.transferStarGift(prepaid: prepaid, reference: reference, peerId: peerId)
                                        },
                                        upgradeGift: { [weak self] formId, reference, keepOriginalInfo in
                                            guard let self else {
                                                return .never()
                                            }
                                            return self.profileGifts.upgradeStarGift(formId: formId, reference: reference, keepOriginalInfo: keepOriginalInfo)
                                        },
                                        buyGift: { [weak self] slug, peerId, price, hideName, text, entities in
                                            guard let self else {
                                                return .never()
                                            }
                                            return self.profileGifts.buyStarGift(slug: slug, peerId: peerId, price: price, hideName: hideName, text: text, entities: entities)
                                        },
                                        updateResellStars: { [weak self] reference, price in
                                            guard let self else {
                                                return .never()
                                            }
                                            return self.profileGifts.updateStarGiftResellPrice(reference: reference, price: price)
                                        },
                                        togglePinnedToTop: { [weak self] reference, pinnedToTop in
                                            guard let self else {
                                                return false
                                            }
                                            if pinnedToTop && self.pinnedReferences.count >= self.maxPinnedCount {
                                                self.displayUnpinScreen?(product, {
                                                    dismissImpl?()
                                                })
                                                return false
                                            }
                                            self.profileGifts.updateStarGiftPinnedToTop(reference: reference, pinnedToTop: pinnedToTop)
                                            
                                            var title = ""
                                            if case let .unique(uniqueGift) = product.gift {
                                                title = "\(uniqueGift.title) #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: params.presentationData.dateTimeFormat))"
                                            }
                                            
                                            if pinnedToTop {
                                                Queue.mainQueue().after(0.35) {
                                                    let toastTitle = params.presentationData.strings.PeerInfo_Gifts_ToastPinned_TitleNew(title).string
                                                    let toastText = params.presentationData.strings.PeerInfo_Gifts_ToastPinned_Text
                                                    self.parentController?.present(UndoOverlayController(presentationData: params.presentationData, content: .universal(animation: "anim_toastpin", scale: 0.06, colors: [:], title: toastTitle, text: toastText, customUndoText: nil, timeout: 5), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                                                }
                                            }
                                            return true
                                        },
                                        shareStory: { [weak self] uniqueGift in
                                            guard let self, let parentController = self.parentController else {
                                                return
                                            }
                                            Queue.mainQueue().after(0.15) {
                                                let controller = self.context.sharedContext.makeStorySharingScreen(context: self.context, subject: .gift(uniqueGift), parentController: parentController)
                                                parentController.push(controller)
                                            }
                                        }
                                    )
                                    dismissImpl = { [weak controller] in
                                        controller?.dismissAnimated()
                                    }
                                    self.parentController?.push(controller)
                                }
                            },
                            contextAction: self.isReordering || self.canSelect ? nil : { [weak self] view, gesture in
                                guard let self else {
                                    return
                                }
                                if self.isLocalDemoGift(product) {
                                    self.showLocalGiftOptions(product)
                                } else {
                                    self.contextAction?(product, view, gesture)
                                }
                            }
                        )
                    ),
                    environment: {},
                    containerSize: starsOptionSize
                )
                if let itemView = visibleItem.view {
                    if itemView.superview == nil {
                        self.addSubview(itemView)
                        
                        if !transition.animation.isImmediate {
                            itemView.layer.animateScale(from: 0.01, to: 1.0, duration: 0.25)
                            itemView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                        }
                    }
                    var itemFrame = itemFrame
                    var isReordering = false
                    if let reorderingItem = self.reorderingItem, itemId == reorderingItem.id {
                        itemFrame = itemFrame.size.centered(around: reorderingItem.position)
                        isReordering = true
                    }
                    if self.isReordering, itemView.layer.animation(forKey: "position") != nil && !isReordering {
                    } else {
                        itemTransition.setFrame(view: itemView, frame: itemFrame)
                    }
                    
                    itemTransition.setAlpha(view: itemView, alpha: itemAlpha)
                    if itemAlpha < 1.0 {
                        itemView.layer.allowsGroupOpacity = true
                    }
                    
                    if self.isReordering && (product.pinnedToTop || self.isCollection) {
                        if itemView.layer.animation(forKey: "shaking_position") == nil {
                            itemView.layer.addReorderingShaking()
                        }
                    } else {
                        if itemView.layer.animation(forKey: "shaking_position") != nil {
                            itemView.layer.removeAnimation(forKey: "shaking_position")
                            itemView.layer.removeAnimation(forKey: "shaking_rotation")
                        }
                    }
                }
            }
            itemFrame.origin.x += itemFrame.width + optionSpacing
            if itemFrame.maxX > params.size.width {
                itemFrame.origin.x = itemsSideInset
                itemFrame.origin.y += starsOptionSize.height + optionSpacing
            }
            index += 1
        }
        
        var removeIds: [AnyHashable] = []
        for (id, item) in self.starsItems {
            if !validIds.contains(id) {
                removeIds.append(id)
                if let itemView = item.1.view {
                    if !transition.animation.isImmediate {
                        itemView.layer.animateScale(from: 1.0, to: 0.01, duration: 0.25, removeOnCompletion: false)
                        itemView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, removeOnCompletion: false, completion: { _ in
                            itemView.removeFromSuperview()
                        })
                    } else {
                        itemView.removeFromSuperview()
                    }
                }
            }
        }
        for id in removeIds {
            self.starsItems.removeValue(forKey: id)
        }
        
        var contentHeight = ceil(CGFloat(starsProducts.count) / CGFloat(defaultItemsInRow)) * (starsOptionSize.height + optionSpacing) - optionSpacing + topInset + 16.0
        
        let size = params.size
        let sideInset = params.sideInset
        let bottomInset = params.bottomInset
        let presentationData = params.presentationData
      
        self.theme = presentationData.theme
        
        let textFont = Font.regular(13.0)
        let boldTextFont = Font.semibold(13.0)
        let textColor = presentationData.theme.list.itemSecondaryTextColor
        let linkColor = presentationData.theme.list.itemAccentColor
        let markdownAttributes = MarkdownAttributes(body: MarkdownAttributeSet(font: textFont, textColor: textColor), bold: MarkdownAttributeSet(font: boldTextFont, textColor: textColor), link: MarkdownAttributeSet(font: boldTextFont, textColor: linkColor), linkAttribute: { _ in
            return nil
        })
        
        let buttonSideInset = sideInset + 16.0
        let buttonSize = CGSize(width: size.width - buttonSideInset * 2.0, height: 50.0)
        let effectiveBottomInset = max(8.0, bottomInset)
        let bottomPanelHeight = effectiveBottomInset + buttonSize.height + 8.0
        let visibleHeight = params.visibleHeight

        let showLocalGiftButton = self.canDisplayLocalDemoGifts(filter: self.profileGifts.currentState?.filter ?? .All) && !self.isReordering
        self.localGiftButton.isHidden = !showLocalGiftButton
        if showLocalGiftButton {
            self.localGiftButton.backgroundColor = presentationData.theme.list.blocksBackgroundColor
            self.localGiftButton.setTitleColor(presentationData.theme.list.itemAccentColor, for: .normal)
            self.localGiftButton.frame = CGRect(
                x: buttonSideInset,
                y: contentHeight + 10.0,
                width: buttonSize.width,
                height: 44.0
            )
            contentHeight += 64.0
        }
        
        let panelTransition = ComponentTransition.immediate
        let fadeTransition = ComponentTransition.easeInOut(duration: 0.25)
        let contentTopInset = topInset
        var emptyResultsMinY: CGFloat = 0.0
        if self.resultsAreEmpty && self.isCollection {
            let sideInset: CGFloat = 44.0
            let topInset: CGFloat = contentTopInset
            let emptyTextSpacing: CGFloat = 18.0
            
            self.emptyResultsClippingView.isHidden = false
            
            panelTransition.setFrame(view: self.emptyResultsClippingView, frame: CGRect(origin: CGPoint(x: 0.0, y: 48.0), size: params.size))
            panelTransition.setBounds(view: self.emptyResultsClippingView, bounds: CGRect(origin: CGPoint(x: 0.0, y: 48.0), size: params.size))
            
            let emptyResultsTitleSize = self.emptyResultsTitle.update(
                transition: .immediate,
                component: AnyComponent(
                    MultilineTextComponent(
                        text: .plain(NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_EmptyCollection_Title, font: Font.semibold(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor)),
                        horizontalAlignment: .center
                    )
                ),
                environment: {},
                containerSize: CGSize(width: params.size.width - sideInset * 2.0, height: params.size.height)
            )
            let emptyResultsTextSize = self.emptyResultsText.update(
                transition: .immediate,
                component: AnyComponent(
                    MultilineTextComponent(
                        text: .plain(NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_EmptyCollection_Text, font: Font.regular(15.0), textColor: presentationData.theme.list.itemSecondaryTextColor)),
                        horizontalAlignment: .center
                    )
                ),
                environment: {},
                containerSize: CGSize(width: params.size.width - sideInset * 2.0, height: params.size.height)
            )
            let buttonAttributedString = NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_EmptyCollection_Action, font: Font.semibold(17.0), textColor: presentationData.theme.list.itemCheckColors.foregroundColor, paragraphAlignment: .center)
            let emptyResultsActionSize = self.emptyResultsAction.update(
                transition: .immediate,
                component: AnyComponent(
                    ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: presentationData.theme.list.itemCheckColors.fillColor,
                            foreground: presentationData.theme.list.itemCheckColors.foregroundColor,
                            pressedColor: presentationData.theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.8)
                        ),
                        content: AnyComponentWithIdentity(
                            id: AnyHashable(buttonAttributedString.string),
                            component: AnyComponent(MultilineTextComponent(text: .plain(buttonAttributedString)))
                        ),
                        isEnabled: true,
                        action: { [weak self] in
                            self?.addToCollection?()
                        }
                    )
                ),
                environment: {},
                containerSize: CGSize(width: 240.0, height: 52.0)
            )
  
            let emptyTotalHeight = emptyResultsTitleSize.height + emptyTextSpacing + emptyResultsTextSize.height + emptyTextSpacing + emptyResultsActionSize.height
            let emptyTitleY = topInset + floorToScreenPixels((visibleHeight - topInset - bottomInset - emptyTotalHeight) / 2.0)
            
            emptyResultsMinY = emptyTitleY
            let emptyResultsTitleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsTitleSize.width) / 2.0), y: emptyTitleY), size: emptyResultsTitleSize)
            let emptyResultsTextFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsTextSize.width) / 2.0), y: emptyResultsTitleFrame.maxY + emptyTextSpacing), size: emptyResultsTextSize)
            let emptyResultsActionFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsActionSize.width) / 2.0), y: emptyResultsTextFrame.maxY + emptyTextSpacing), size: emptyResultsActionSize)
            
            if let view = self.emptyResultsTitle.view {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsTitleFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsTitleFrame.center)
            }
            if let view = self.emptyResultsText.view {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsTextFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsTextFrame.center)
            }
            if let view = self.emptyResultsAction.view {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsActionFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsActionFrame.center)
            }
        } else if self.filteredResultsAreEmpty {
            let sideInset: CGFloat = 44.0
            let emptyAnimationHeight = 148.0
            let topInset: CGFloat = contentTopInset
            let bottomInset: CGFloat = bottomPanelHeight
            let emptyAnimationSpacing: CGFloat = 20.0
            let emptyTextSpacing: CGFloat = 18.0
            
            self.emptyResultsClippingView.isHidden = false
                            
            panelTransition.setFrame(view: self.emptyResultsClippingView, frame: CGRect(origin: CGPoint(x: 0.0, y: 48.0), size: params.size))
            panelTransition.setBounds(view: self.emptyResultsClippingView, bounds: CGRect(origin: CGPoint(x: 0.0, y: 48.0), size: params.size))
            
            let emptyResultsTitleSize = self.emptyResultsTitle.update(
                transition: .immediate,
                component: AnyComponent(
                    MultilineTextComponent(
                        text: .plain(NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_NoResults, font: Font.semibold(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor)),
                        horizontalAlignment: .center
                    )
                ),
                environment: {},
                containerSize: params.size
            )
            let emptyResultsActionSize = self.emptyResultsAction.update(
                transition: .immediate,
                component: AnyComponent(
                    PlainButtonComponent(
                        content: AnyComponent(
                            MultilineTextComponent(
                                text: .plain(NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_NoResults_ViewAll, font: Font.regular(17.0), textColor: presentationData.theme.list.itemAccentColor)),
                                horizontalAlignment: .center,
                                maximumNumberOfLines: 0
                            )
                        ),
                        effectAlignment: .center,
                        action: { [weak self] in
                            guard let self else {
                                return
                            }
                            self.profileGifts.updateFilter(.All)
                        },
                        animateScale: false
                    )
                ),
                environment: {},
                containerSize: CGSize(width: params.size.width - sideInset * 2.0, height: visibleHeight)
            )
            let emptyResultsAnimationSize = self.emptyResultsAnimation.update(
                transition: .immediate,
                component: AnyComponent(LottieComponent(
                    content: LottieComponent.AppBundleContent(name: "ChatListNoResults"),
                    lottieSettings: self.context.lottieRenderingSettings
                )),
                environment: {},
                containerSize: CGSize(width: emptyAnimationHeight, height: emptyAnimationHeight)
            )
  
            let emptyTotalHeight = emptyAnimationHeight + emptyAnimationSpacing + emptyResultsTitleSize.height + emptyResultsActionSize.height + emptyTextSpacing
            let emptyAnimationY = topInset + floorToScreenPixels((visibleHeight - topInset - bottomInset - emptyTotalHeight) / 2.0)
            
            emptyResultsMinY = emptyAnimationY
            let emptyResultsAnimationFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsAnimationSize.width) / 2.0), y: emptyAnimationY), size: emptyResultsAnimationSize)
            
            let emptyResultsTitleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsTitleSize.width) / 2.0), y: emptyResultsAnimationFrame.maxY + emptyAnimationSpacing), size: emptyResultsTitleSize)
            
            let emptyResultsActionFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.size.width - emptyResultsActionSize.width) / 2.0), y: emptyResultsTitleFrame.maxY + emptyTextSpacing), size: emptyResultsActionSize)
            
            if let view = self.emptyResultsAnimation.view as? LottieComponent.View {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                    view.playOnce()
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsAnimationFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsAnimationFrame.center)
            }
            if let view = self.emptyResultsTitle.view {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsTitleFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsTitleFrame.center)
            }
            if let view = self.emptyResultsAction.view {
                if view.superview == nil {
                    view.alpha = 0.0
                    fadeTransition.setAlpha(view: view, alpha: 1.0)
                    self.emptyResultsClippingView.addSubview(view)
                }
                view.bounds = CGRect(origin: .zero, size: emptyResultsActionFrame.size)
                panelTransition.setPosition(view: view, position: emptyResultsActionFrame.center)
            }
        } else {
            if let view = self.emptyResultsAnimation.view {
                fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                    view.removeFromSuperview()
                })
            }
            if let view = self.emptyResultsTitle.view {
                fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                    self.emptyResultsClippingView.isHidden = true
                    view.removeFromSuperview()
                })
            }
            if let view = self.emptyResultsText.view {
                fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                    view.removeFromSuperview()
                })
            }
            if let view = self.emptyResultsAction.view {
                fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                    view.removeFromSuperview()
                })
            }
        }
        
        fadeTransition.setAlpha(view: self.emptyResultsClippingView, alpha: emptyResultsMinY < contentTopInset ? 0.0 : 1.0)
        
        if self.peerId == self.context.account.peerId, !self.canSelect && !self.filteredResultsAreEmpty && self.profileGifts.collectionId == nil && self.emptyResultsClippingView.isHidden {
            let footerText: ComponentView<Empty>
            if let current = self.footerText {
                footerText = current
            } else {
                footerText = ComponentView<Empty>()
                self.footerText = footerText
            }
            let footerTextSize = footerText.update(
                transition: .immediate,
                component: AnyComponent(
                    BalancedTextComponent(
                        text: .markdown(text: presentationData.strings.PeerInfo_Gifts_Info, attributes: markdownAttributes),
                        horizontalAlignment: .center,
                        maximumNumberOfLines: 0,
                        lineSpacing: 0.2
                    )
                ),
                environment: {},
                containerSize: CGSize(width: size.width - 32.0, height: 200.0)
            )
            if let view = footerText.view {
                if view.superview == nil {
                    self.addSubview(view)
                }
                transition.setFrame(view: view, frame: CGRect(origin: CGPoint(x: floor((size.width - footerTextSize.width) / 2.0), y: contentHeight), size: footerTextSize))
            }
            contentHeight += footerTextSize.height
        } else if let footerText = self.footerText {
            self.footerText = nil
            if let view = footerText.view {
                fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                    view.removeFromSuperview()
                })
            }
        }
                        
        return contentHeight
    }
        
    func update(size: CGSize, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, presentationData: PresentationData, synchronous: Bool, visibleBounds: CGRect, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.currentParams = (size, sideInset, bottomInset, deviceMetrics, visibleHeight, isScrollingLockedAtTop, expandProgress, presentationData)
        self.presentationDataPromise.set(.single(presentationData))
        
        return self.updateScrolling(topInset: self.topInset ?? 0.0, visibleBounds: visibleBounds, transition: ComponentTransition(transition))
    }
}

private extension StarGiftReference {
    var stringValue: String {
        switch self {
        case let .message(messageId):
            return "m_\(messageId.id)"
        case let .peer(peerId, id):
            return "p_\(peerId.toInt64())_\(id)"
        case let .slug(slug):
            return "s_\(slug)"
        }
    }
}


private final class ReorderGestureRecognizer: UIGestureRecognizer {
    private let shouldBegin: (CGPoint) -> (allowed: Bool, requiresLongPress: Bool, id: AnyHashable?, item: ComponentView<Empty>?)
    private let willBegin: (CGPoint) -> Void
    private let began: (AnyHashable) -> Void
    private let ended: () -> Void
    private let moved: (CGPoint) -> Void
    private let isActiveUpdated: (Bool) -> Void
    
    private var initialLocation: CGPoint?
    private var longTapTimer: SwiftSignalKit.Timer?
    private var longPressTimer: SwiftSignalKit.Timer?
    
    private var id: AnyHashable?
    private var itemView: ComponentView<Empty>?
    
    init(shouldBegin: @escaping (CGPoint) -> (allowed: Bool, requiresLongPress: Bool, id: AnyHashable?, item: ComponentView<Empty>?), willBegin: @escaping (CGPoint) -> Void, began: @escaping (AnyHashable) -> Void, ended: @escaping () -> Void, moved: @escaping (CGPoint) -> Void, isActiveUpdated: @escaping (Bool) -> Void) {
        self.shouldBegin = shouldBegin
        self.willBegin = willBegin
        self.began = began
        self.ended = ended
        self.moved = moved
        self.isActiveUpdated = isActiveUpdated
        
        super.init(target: nil, action: nil)
    }
    
    deinit {
        self.longTapTimer?.invalidate()
        self.longPressTimer?.invalidate()
    }
    
    private func startLongTapTimer() {
        self.longTapTimer?.invalidate()
        let longTapTimer = SwiftSignalKit.Timer(timeout: 0.25, repeat: false, completion: { [weak self] in
            self?.longTapTimerFired()
        }, queue: Queue.mainQueue())
        self.longTapTimer = longTapTimer
        longTapTimer.start()
    }
    
    private func stopLongTapTimer() {
        self.itemView = nil
        self.longTapTimer?.invalidate()
        self.longTapTimer = nil
    }
    
    private func startLongPressTimer() {
        self.longPressTimer?.invalidate()
        let longPressTimer = SwiftSignalKit.Timer(timeout: 0.6, repeat: false, completion: { [weak self] in
            self?.longPressTimerFired()
        }, queue: Queue.mainQueue())
        self.longPressTimer = longPressTimer
        longPressTimer.start()
    }
    
    private func stopLongPressTimer() {
        self.itemView = nil
        self.longPressTimer?.invalidate()
        self.longPressTimer = nil
    }
    
    override func reset() {
        super.reset()
        
        self.itemView = nil
        self.stopLongTapTimer()
        self.stopLongPressTimer()
        self.initialLocation = nil
        
        self.isActiveUpdated(false)
    }
    
    private func longTapTimerFired() {
        guard let location = self.initialLocation else {
            return
        }
        
        self.longTapTimer?.invalidate()
        self.longTapTimer = nil
        
        self.willBegin(location)
    }
    
    private func longPressTimerFired() {
        guard let _ = self.initialLocation else {
            return
        }
        
        self.isActiveUpdated(true)
        self.state = .began
        self.longPressTimer?.invalidate()
        self.longPressTimer = nil
        self.longTapTimer?.invalidate()
        self.longTapTimer = nil
        if let id = self.id {
            self.began(id)
        }
        self.isActiveUpdated(true)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        
        if self.numberOfTouches > 1 {
            self.isActiveUpdated(false)
            self.state = .failed
            self.ended()
            return
        }
        
        if self.state == .possible {
            if let location = touches.first?.location(in: self.view) {
                let (allowed, requiresLongPress, id, itemView) = self.shouldBegin(location)
                if allowed {
                    self.isActiveUpdated(true)
                    
                    self.id = id
                    self.itemView = itemView
                    self.initialLocation = location
                    if requiresLongPress {
                        self.startLongTapTimer()
                        self.startLongPressTimer()
                    } else {
                        self.state = .began
                        if let id = self.id {
                            self.began(id)
                        }
                    }
                } else {
                    self.isActiveUpdated(false)
                    self.state = .failed
                }
            } else {
                self.isActiveUpdated(false)
                self.state = .failed
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        
        self.initialLocation = nil
        
        self.stopLongTapTimer()
        if self.longPressTimer != nil {
            self.stopLongPressTimer()
            self.isActiveUpdated(false)
            self.state = .failed
        }
        if self.state == .began || self.state == .changed {
            self.isActiveUpdated(false)
            self.ended()
            self.state = .failed
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        
        self.initialLocation = nil
        
        self.stopLongTapTimer()
        if self.longPressTimer != nil {
            self.isActiveUpdated(false)
            self.stopLongPressTimer()
            self.state = .failed
        }
        if self.state == .began || self.state == .changed {
            self.isActiveUpdated(false)
            self.ended()
            self.state = .failed
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        
        if (self.state == .began || self.state == .changed), let initialLocation = self.initialLocation, let location = touches.first?.location(in: self.view) {
            self.state = .changed
            let offset = CGPoint(x: location.x - initialLocation.x, y: location.y - initialLocation.y)
            self.moved(offset)
        } else if let touch = touches.first, let initialTapLocation = self.initialLocation, self.longPressTimer != nil {
            let touchLocation = touch.location(in: self.view)
            let dX = touchLocation.x - initialTapLocation.x
            let dY = touchLocation.y - initialTapLocation.y
            
            if dX * dX + dY * dY > 3.0 * 3.0 {
                self.stopLongTapTimer()
                self.stopLongPressTimer()
                self.initialLocation = nil
                self.isActiveUpdated(false)
                self.state = .failed
            }
        }
    }
}
