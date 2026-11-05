#!/usr/bin/env python3
"""Refresh expired profiles with the project's original build-only test identity.

The output is not Apple provisioning. Any IPA must be re-signed by AltStore.
"""
import datetime
import pathlib
import plistlib
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
SIGNING = ROOT / "build-system/fake-codesigning"
PROFILES = SIGNING / "profiles"
P12 = SIGNING / "certs/SelfSigned.p12"


def run(*args, capture=False):
    return subprocess.run(list(map(str, args)), check=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None).stdout


def main():
    paths = sorted(PROFILES.glob("*.mobileprovision"))
    if not paths or not P12.is_file():
        raise RuntimeError("Missing original test identity or profiles")

    with tempfile.TemporaryDirectory(prefix="yrsl-demo-signing-") as d:
        tmp = pathlib.Path(d)
        cert = tmp / "cert.pem"
        key = tmp / "private.pem"
        der = tmp / "cert.der"

        # Preserve the original code-signing identity. A freshly minted
        # generic CA identity is not accepted by the macOS keychain.
        run("openssl", "pkcs12", "-in", P12, "-passin", "pass:",
            "-nokeys", "-legacy", "-out", cert)
        run("openssl", "pkcs12", "-in", P12, "-passin", "pass:",
            "-nocerts", "-nodes", "-legacy", "-out", key)
        run("openssl", "x509", "-in", cert, "-outform", "DER", "-out", der)
        # Check that the original signing certificate has not expired.
        run("openssl", "x509", "-in", cert, "-checkend", "86400", "-noout")
        cert_der = der.read_bytes()
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

        for path in paths:
            payload = run("security", "cms", "-D", "-i", path, capture=True)
            profile = plistlib.loads(payload)
            profile["CreationDate"] = now
            profile["ExpirationDate"] = now + datetime.timedelta(days=180)
            profile["TimeToLive"] = 180
            profile["UUID"] = str(uuid.uuid4()).upper()
            profile["DeveloperCertificates"] = [cert_der]
            profile.pop("DER-Encoded-Profile", None)
            xml = tmp / "profile.plist"
            xml.write_bytes(plistlib.dumps(profile, fmt=plistlib.FMT_XML))
            run("openssl", "cms", "-sign", "-binary", "-nodetach",
                "-in", xml, "-signer", cert, "-inkey", key,
                "-outform", "DER", "-out", path)
            verified = plistlib.loads(run("security", "cms", "-D", "-i", path, capture=True))
            assert verified["ExpirationDate"] > now
            assert verified["DeveloperCertificates"][0] == cert_der
            print(f"Refreshed build profile: {path.name}")


if __name__ == "__main__":
    main()
