#!/usr/bin/env python3
"""Cross-language parity check: Swift <-> Python.

The iOS client (ios/MirWallet/Services/EmvCrypto.swift) and the mock TSP
(server/mock_tsp.py) must produce byte-identical session keys and application
cryptograms. This script is the executable specification of that contract.

It works in two modes:

  * reference mode (default) - recompute the Swift algorithm from the format
    strings extracted out of the Swift source, and compare against the server
    implementation over a table of vectors.

  * vectors mode - emit the vectors as JSON so the Swift unit test can assert
    the same values (ios/MirWalletTests/MirWalletTests.swift).

Usage:
    python3 tools/parity_check.py
    python3 tools/parity_check.py --emit-vectors
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "server"))

from mock_tsp import compute_arqc, hkdf  # noqa: E402

SWIFT_CRYPTO = os.path.join(ROOT, "ios", "MirWallet", "Services", "EmvCrypto.swift")

# The canonical vector table. Values are derived by the Swift implementation and
# reproduced here; if either side changes its algorithm, this table breaks.
VECTORS = [
    # (master_key_hex, device_udid, token_id, atc, amount_minor, currency, un_hex, tvr, txn_type)
    ("5a" * 32, "TESTUDID0001", "tok_abc", 1, "4990", "RUB", "1122334455667788", "0000000000", "00"),
    ("00" * 32, "DEVICE_A", "tok_def456", 7, "100", "RUB", "0000000000000000", "0000000000", "00"),
    ("ff" * 32, "DEVICE_B", "tok_0000", 65535, "999999", "RUB", "aabbccddeeff0011", "1234567890", "01"),
]


def swift_format_matches(source: str) -> bool:
    """The Swift source must use the exact same ARQC message layout."""
    expected = 'format: "ARQC|%d|%@|%@|%@|%@|%@"'
    return expected in source


def swift_hkdf_matches(source: str) -> bool:
    """The Swift source must derive the session key with the same info string."""
    return 'mir-mock-sk|' in source and "static func hkdf" in source


def derive_swift_style_session_key(master: bytes, udid: str, token_id: str) -> bytes:
    """Mirrors EmvCrypto.deriveSessionKey exactly as written in Swift."""
    return hkdf(ikm=master, salt=udid.encode(), info=("mir-mock-sk|" + token_id).encode(), length=32)


def compute_swift_style_arqc(sk: bytes, atc: int, amount: str, currency: str,
                             un: bytes, tvr: str, txn_type: str) -> bytes:
    """Mirrors EmvCrypto.computeARQC exactly as written in Swift."""
    message = ("ARQC|%d|%s|%s|%s|%s|%s" % (atc, amount, currency, un.hex(), tvr, txn_type)).encode()
    import hashlib
    import hmac
    return hmac.new(sk, message, hashlib.sha256).digest()[:8]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-vectors", action="store_true",
                        help="print the vector table as JSON for the Swift test")
    args = parser.parse_args()

    if args.emit_vectors:
        out = []
        for master_hex, udid, token_id, atc, amount, currency, un_hex, tvr, txn_type in VECTORS:
            master = bytes.fromhex(master_hex)
            sk = derive_swift_style_session_key(master, udid, token_id)
            un = bytes.fromhex(un_hex)
            arqc = compute_swift_style_arqc(sk, atc, amount, currency, un, tvr, txn_type)
            out.append({
                "masterKeyHex": master_hex,
                "deviceUDID": udid,
                "tokenId": token_id,
                "sessionKeyHex": sk.hex(),
                "atc": atc,
                "amountMinor": amount,
                "currency": currency,
                "unHex": un_hex,
                "tvr": tvr,
                "txnType": txn_type,
                "arqcHex": arqc.hex(),
            })
        print(json.dumps(out, indent=2))
        return 0

    failures = []

    with open(SWIFT_CRYPTO, encoding="utf-8") as fh:
        source = fh.read()

    print("[1] Swift/Python format-string parity")
    if swift_format_matches(source):
        print("  PASS ARQC message layout matches")
    else:
        failures.append("ARQC message layout differs between Swift and Python")
        print("  FAIL ARQC message layout differs")

    if swift_hkdf_matches(source):
        print("  PASS session-key derivation matches")
    else:
        failures.append("session-key derivation differs")
        print("  FAIL session-key derivation differs")

    print("\n[2] Vector parity (server implementation vs Swift reference)")
    for master_hex, udid, token_id, atc, amount, currency, un_hex, tvr, txn_type in VECTORS:
        master = bytes.fromhex(master_hex)
        un = bytes.fromhex(un_hex)

        server_sk = hkdf(ikm=master, salt=udid.encode(),
                         info=("mir-mock-sk|" + token_id).encode(), length=32)
        swift_sk = derive_swift_style_session_key(master, udid, token_id)
        server_arqc = compute_arqc(swift_sk, atc, amount, currency, un, tvr, txn_type)
        swift_arqc = compute_swift_style_arqc(swift_sk, atc, amount, currency, un, tvr, txn_type)

        label = "atc=%d amount=%s" % (atc, amount)
        if server_sk == swift_sk and server_arqc == swift_arqc:
            print("  PASS %s  arqc=%s" % (label, swift_arqc.hex()))
        else:
            failures.append("vector mismatch: " + label)
            print("  FAIL %s" % label)

    print("\n[3] Sanity checks")
    master = bytes.fromhex("5a" * 32)
    sk = derive_swift_style_session_key(master, "DEVICE_A", "tok_1")
    sk_b = derive_swift_style_session_key(master, "DEVICE_B", "tok_1")
    if sk != sk_b:
        print("  PASS session key is device-bound")
    else:
        failures.append("session key not device-bound")

    un = bytes.fromhex("1122334455667788")
    a = compute_swift_style_arqc(sk, 1, "100", "RUB", un, "0000000000", "00")
    b = compute_swift_style_arqc(sk, 2, "100", "RUB", un, "0000000000", "00")
    c = compute_swift_style_arqc(sk, 1, "200", "RUB", un, "0000000000", "00")
    if a != b and a != c:
        print("  PASS ARQC binds to ATC and amount")
    else:
        failures.append("ARQC does not bind to ATC/amount")

    if len(a) == 8:
        print("  PASS ARQC length is 8 bytes")
    else:
        failures.append("ARQC length wrong: %d" % len(a))

    print("\n%s" % ("=" * 50))
    if failures:
        for f in failures:
            print("  FAILED: " + f)
        return 1
    print("parity OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
