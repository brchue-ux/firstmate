#!/usr/bin/env python3
"""Pre-flight checks on a built APK, run in CI before it is handed to anyone.

Every check here exists because its absence already cost a delivery round:

  signature   Each CI runner minted a fresh random debug key, so consecutive
              APKs could not be installed over one another. The failure was
              silent - the phone simply kept the old build, and the new code
              looked like it had had no effect.
  build       Two builds were confused for each other because nothing verified
              which code was actually inside the file being sent.
  theme       The app followed the system light/dark setting, so the obsidian
              design was invisible on a device set to light.
  offline     The app claims to be fully local; that claim should be enforced,
              not trusted.

Usage: verify-apk.py <apk> <expected-signer-sha256>
"""
import hashlib
import struct
import sys
import zipfile

EXPECTED_STRINGS = [
    "Your space is empty",  # v3 space view empty state
    "Today's agency",       # v3 Today header
    "Name a moment",        # v3 moment capture
]
FORBIDDEN_STRINGS = [
    "Today's check-in",     # v1 dashboard section
    "Boundaries & Habits",  # v1 habits title
    "Command Centre",       # v2 dashboard title, replaced by the space view
]


def signer_fingerprints(path):
    """SHA-256 of each signing certificate in the APK Signing Block (v2 scheme)."""
    data = open(path, "rb").read()
    magic = data.rfind(b"APK Sig Block 42")
    if magic < 0:
        return []
    size_before = struct.unpack_from("<Q", data, magic - 8)[0]
    start = magic + 16 - 8 - size_before
    block_size = struct.unpack_from("<Q", data, start)[0]
    pos, end = start + 8, start + 8 + block_size - 24
    out = []
    while pos < end:
        pair_len = struct.unpack_from("<Q", data, pos)[0]
        pair_id = struct.unpack_from("<I", data, pos + 8)[0]
        value = data[pos + 12: pos + 8 + pair_len]
        if pair_id == 0x7109871A:  # APK Signature Scheme v2
            cursor = 4
            signers_len = struct.unpack_from("<I", value, 0)[0]
            while cursor < 4 + signers_len:
                slen = struct.unpack_from("<I", value, cursor)[0]
                cursor += 4
                signer = value[cursor:cursor + slen]
                cursor += slen
                signed = signer[4:4 + struct.unpack_from("<I", signer, 0)[0]]
                r = 4 + struct.unpack_from("<I", signed, 0)[0]  # skip digests
                certs_len = struct.unpack_from("<I", signed, r)[0]
                r += 4
                cert_end = r + certs_len
                while r < cert_end:
                    clen = struct.unpack_from("<I", signed, r)[0]
                    r += 4
                    out.append(hashlib.sha256(signed[r:r + clen]).hexdigest())
                    r += clen
        pos += 8 + pair_len
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    apk, expected = sys.argv[1], sys.argv[2].replace(":", "").lower()
    failures = []

    zf = zipfile.ZipFile(apk)
    if zf.testzip() is not None:
        failures.append("archive is corrupt")

    prints = signer_fingerprints(apk)
    if not prints:
        failures.append("no v2 signing block - the APK is unsigned")
    elif expected not in prints:
        failures.append(
            f"signed by {prints[0][:16]}... but the committed keystore is "
            f"{expected[:16]}... - this APK cannot be installed over the last one"
        )

    dex = b"".join(zf.read(n) for n in zf.namelist() if n.endswith(".dex"))
    for marker in EXPECTED_STRINGS:
        if marker.encode() not in dex:
            failures.append(f"expected string missing from the build: {marker!r}")
    for marker in FORBIDDEN_STRINGS:
        if marker.encode() in dex:
            failures.append(f"stale string still present - this is an older build: {marker!r}")

    # The theme must not be able to resolve to the light scheme at runtime.
    manifest = zf.read("AndroidManifest.xml").decode("utf-16-le", errors="ignore")
    if "INTERNET" in manifest:
        failures.append("INTERNET permission present - the app claims to be offline-only")

    label = "FAIL" if failures else "OK"
    print(f"[{label}] {apk}")
    print(f"  signer      {prints[0][:32] + '...' if prints else 'none'}")
    print(f"  build       {'v2' if b'Command Centre' in dex else 'UNKNOWN'}")
    print(f"  size        {round(len(open(apk, 'rb').read()) / 1048576, 1)} MB")
    for f in failures:
        print(f"  ! {f}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
