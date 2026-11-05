#!/usr/bin/env python3
"""Refresh expired self-signed *build-only* profiles. Not Apple provisioning.

The resulting IPA must be re-signed by AltStore with the user's own
Apple account. These temporary profiles never confer Apple entitlements.
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
CERTS = SIGNING / "certs"


def run(*args, capture=False):
    return subprocess.run(
        list(map(str, args)),
        check=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    ).stdout


def main():
    profile_files = sorted(PROFILES.glob("*.mobileprovision"))
    if not profile_files:
        raise RuntimeError("No existing template provisioning profiles")

    with tempfile.TemporaryDirectory(prefix="yrsl-demo-signing-") as folder:
        tmp = pathlib.Path(folder)
        key = tmp / "demo.key"
        cert = tmp / "demo.pem"
        cert_der_path = tmp / "demo.der"
        # This identity is for unsigned-IPA build tooling only.
        run(
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-days", "365", "-subj",
            "/C=FR/O=YRSL Demo/OU=C67CF9S4VU/CN=Apple Development: YRSL Demo",
            "-keyout", key, "-out", cert,
        )
        run(
            "openssl", "pkcs12", "-export", "-in", cert, "-inkey", key,
            "-passout", "pass:", "-out", CERTS / "SelfSigned.p12",
        )
        run("openssl", "x509", "-in", cert, "-outform", "DER", "-out", cert_der_path)
        cert_der = cert_der_path.read_bytes()
        (CERTS / "Public.cer").write_bytes(cert_der)

        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        for path in profile_files:
            try:
                payload = run("security", "cms", "-D", "-i", path, capture=True)
            except subprocess.CalledProcessError:
                payload = run(
                    "openssl", "cms", "-verify", "-noverify", "-inform", "DER",
                    "-in", path, capture=True,
                )
            profile = plistlib.loads(payload)
            profile["CreationDate"] = now
            profile["ExpirationDate"] = now + datetime.timedelta(days=180)
            profile["TimeToLive"] = 180
            profile["UUID"] = str(uuid.uuid4()).upper()
            profile["DeveloperCertificates"] = [cert_der]
            profile.pop("DER-Encoded-Profile", None)
            xml = tmp / "profile.plist"
            xml.write_bytes(plistlib.dumps(profile, fmt=plistlib.FMT_XML))
            run(
                "openssl", "cms", "-sign", "-binary", "-nodetach",
                "-in", xml, "-signer", cert, "-inkey", key,
                "-outform", "DER", "-out", path,
            )
            result = plistlib.loads(run("security", "cms", "-D", "-i", path, capture=True))
            assert result["ExpirationDate"] > now
            assert result["DeveloperCertificates"][0] == cert_der
            print(f"Refreshed local build profile: {path.name}")


if __name__ == "__main__":
    main()
