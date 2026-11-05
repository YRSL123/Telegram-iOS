# YRSL Telegram: local gift marketplace demo (source prototype)

This change is applied to the official Telegram-iOS source tree. It keeps the
Telegram account, messages, and existing server-backed gifts intact. It does
not create or transfer a Telegram collectible or modify ownership on Telegram's
servers.

## Use

1. Sign in to the modified client only after building and verifying your own
   source and IPA.
2. Open **your own profile → Gifts**, with the **All** or **Unique** gift filter.
3. Scroll below the collection and tap **🎁 Демо-маркет · ⭐ …**.
4. Open **Маркет коллекционных подарков → Поиск по ссылке**. Paste a link
   to an existing collectible, e.g. `https://t.me/nft/PlushPepe-1234`.
   Optionally enter a display number. The client reads that existing gift's
   artwork and attributes from Telegram; this is a lookup, **not a purchase**.
5. Choose to preview it in Telegram's native gift viewer, buy for yourself
   with **demo-Stars**, or **simulate sending** it to a friend. The last
   choice records an outgoing entry in local history; the recipient does not
   receive an actual gift.
6. Tap an owned demo gift to open its actions: preview, pin/unpin, change its
   displayed number, transfer (simulated), list/delist on the local market,
   simulate a completed sale, convert to local Stars, or delete.
7. In the demo market menu, top up the fake Stars balance, simulate gifting
   Stars, and browse up to 100 recent local actions. A previously looked-up
   gift remains in the short local catalog for re-use.

Local entries and the **separate local Stars wallet** are saved in `UserDefaults`
under keys containing the Telegram account ID, not in Telegram's Postbox gift
cache or real Telegram StarsContext. They are visible **only in this modified
app on this device**. Native previews are opened with no transaction callbacks;
local gifts have no server gift reference. The client does not call real
`buyStarGift`, `transferStarGift`, `updateStarGiftResalePrice`, or Stars payment
methods for its demo actions. Regular server-backed gifts retain the standard
Telegram actions.

Prices, balance, recipient names, listings, transfers, sales, conversions,
gifted Stars and history are **fictional**. No Telegram user other than the
local viewer can see these records; the app does not inject fake payment
messages into actual chats. The demo market uses source links and a locally
cached catalog of previously previewed NFTs, **not the live marketplace search
or checkout**, so its surrounding UI is not yet a pixel-perfect reproduction
of all native Telegram marketplace screens.

### Local economy rules

- First launch: 1,000,000 demo-Stars, stored per logged-in Telegram account.
- Top-up: +1,000 / +10,000 / +100,000 / +1,000,000 to a maximum of 100 million.
- Demo purchase: subtract local Stars; add a local gift to the collection if
  buying for yourself, or just add a local history entry if sending directly.
- Demo transfer: remove local gift, append a local history entry.
- Listing: store a local price and show a green price ribbon. Simulating a sale
  removes the gift and credits that price to the demo balance.
- Conversion: remove local gift and credit half its simulated original price.
  Original gifts imported by earlier versions use a 1,000 Stars reference price.
- Pinning: local pinned gifts are moved first in the profile's visible grid,
  with the normal pinned-gift count limit respected.

## Build and verification status

- Source base: `TelegramMessenger/Telegram-iOS` at commit
  `279f89e4d4f63f17227bf877dc3d8990f22ecd58`.
- Demo source is edited and `git diff --check` has been run.
- **Not yet compiled or tested on a Mac, simulator, or iPhone.** The Telegram
  project builds the entire app with Bazel/Xcode; a successful device IPA build
  and simulator visual test are still required.
- Use a *different bundle ID* from the App Store Telegram before signing an
  AltStore build, so the official installation remains untouched.
- Build only from a reviewed fork with your own signing certificate. Do not
  enter a Telegram login code into an unverified third-party IPA.

The optional `yrsl-telegram-ipa.yml` GitHub Actions workflow requests the
`xcode-27` runner, adjusts the bundle ID, builds an unsigned IPA, and uploads
it as a private workflow artifact for seven days. Before running, set your
own `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` repository secrets; obtain them
from `my.telegram.org` yourself. Never put these values in a public commit.
This CI configuration has not been run and may need changes after examining
the actual Xcode/Bazel output. The IPA will still need to be signed by AltStore.

This is intentionally a UI-only demo; it cannot obtain real Telegram gifts,
prove ownership, transfer real gifts or Stars, or affect another account.

## Device acceptance checklist (not yet performed)

- Open the official Telegram app and the separately signed demo build side by
  side; the official app must have no fake gifts or fake Stars.
- Open the demo app, top up Stars, relaunch and check the balance persisted.
- Lookup a public NFT link; preview the actual artwork, then use **Buy for me**.
  Check the local balance decreases and the gift appears in the profile.
- Pin the gift, edit its number, list it for sale, cancel the listing, list
  again, simulate a sale. Check the history and balance after each action.
- Buy a second gift and simulate sending to a friend; check the recipient's
  *real* Telegram account receives nothing.
- Convert a demo gift to demo Stars. Confirm that real Telegram balances,
  gift ownership, chats, and marketplace listings remain unchanged.
- Repeat with a second Telegram account on the modified client. Each account
  should keep its own demo data without cross-account leakage.
- Inspect a genuine owned gift and verify the normal Telegram actions still
  function. Never trigger an actual purchase merely to test the demo feature.
- Inspect recorded iPhone simulator frames for market menus, gift preview,
  profile grid, sheet presentation, and dark/light themes before accepting
  the visual design.
