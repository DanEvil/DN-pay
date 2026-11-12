#!/usr/bin/env python3
"""End-to-end test of the mock TSP / issuer simulator.

Runs the exact same sequence the iOS client performs:
  required-fields -> check-card -> link-and-provision -> verify-cryptogram
and asserts the security properties that matter:
  * a valid transaction is approved
  * the same ARQC replayed with a stale ATC is rejected
  * a tampered amount invalidates the cryptogram
  * an unknown token is rejected
  * keys expire after the configured TTL

Run:  python3 test_mock_tsp.py
"""
from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mock_tsp import Handler, Store, compute_arqc  # noqa: E402

BASE = ""
PASS, FAIL = [], []


def check(name: str, cond: bool, detail: str = ""):
    (PASS if cond else FAIL).append(name)
    print("  %s %s%s" % ("PASS" if cond else "FAIL", name,
                         ("  -- " + detail) if detail and not cond else ""))


def post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode())


def get(path: str) -> dict:
    with urllib.request.urlopen(BASE + path, timeout=10) as resp:
        return json.loads(resp.read().decode())


def main() -> int:
    global BASE
    import secrets
    from http.server import ThreadingHTTPServer

    Handler.store = Store(secrets.token_bytes(32), key_ttl=2)
    Handler.verbose = False
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    BASE = "http://127.0.0.1:%d" % port
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    time.sleep(0.2)

    try:
        print("\n[1] health")
        h = get("/tsp/health")
        check("health returns ok", h.get("ok") is True)

        print("\n[2] required-fields")
        rf = post("/tsp/required-fields", {})
        check("required fields listed", "pan" in rf.get("fields", []))

        print("\n[3] check-card")
        pan = "2200123456789019"   # mock test PAN, Luhn-valid (Mir-style 2200 prefix)
        bad = post("/tsp/check-card", {"pan": pan, "cvv": "123", "expiry": "12/29"})
        check("valid card approved", bad.get("approved") is True, str(bad))
        check("brand detected as mir", bad.get("scheme") == "mir", str(bad))
        luhn_bad = post("/tsp/check-card", {"pan": "2200123456789018", "cvv": "123", "expiry": "12/29"})
        check("luhn failure rejected", luhn_bad.get("approved") is False)

        print("\n[4] link-and-provision")
        udid = "TESTUDID0001"
        prov = post("/tsp/link-and-provision", {"pan": pan, "device": {"udid": udid}})
        token_id = prov.get("tokenId")
        sk = base64.b64decode(prov["sessionKey"])
        check("token issued", bool(token_id))
        check("dpan issued", prov.get("dpan", "").startswith("555555"))
        check("session key is 32 bytes", len(sk) == 32)

        print("\n[5] verify-cryptogram - valid transaction")
        atc = 1
        amount = "4990"
        un = bytes.fromhex("1122334455667788")
        tvr = "0000000000"
        txn_type = "00"
        arqc = compute_arqc(sk, atc, amount, "RUB", un, tvr, txn_type)
        ok = post("/tsp/verify-cryptogram", {
            "tokenId": token_id, "atc": atc, "amountMinor": amount,
            "currency": "RUB", "un": un.hex(), "tvr": tvr, "txnType": txn_type,
            "arqc": base64.b64encode(arqc).decode()})
        check("valid cryptogram approved", ok.get("approved") is True, str(ok))

        print("\n[6] anti-replay - same ATC again")
        replay = post("/tsp/verify-cryptogram", {
            "tokenId": token_id, "atc": atc, "amountMinor": amount,
            "currency": "RUB", "un": un.hex(), "tvr": tvr, "txnType": txn_type,
            "arqc": base64.b64encode(arqc).decode()})
        check("replayed ATC rejected", replay.get("approved") is False, str(replay))
        check("replay reason is atc_replay", replay.get("reason") == "atc_replay", str(replay))

        print("\n[7] tampering - amount changed after signing")
        atc2 = 2
        arqc2 = compute_arqc(sk, atc2, amount, "RUB", un, tvr, txn_type)
        tampered = post("/tsp/verify-cryptogram", {
            "tokenId": token_id, "atc": atc2, "amountMinor": "999999",
            "currency": "RUB", "un": un.hex(), "tvr": tvr, "txnType": txn_type,
            "arqc": base64.b64encode(arqc2).decode()})
        check("tampered amount rejected", tampered.get("approved") is False, str(tampered))
        check("mismatch reason reported",
              tampered.get("reason") == "cryptogram_mismatch", str(tampered))

        print("\n[8] unknown token")
        unk = post("/tsp/verify-cryptogram", {
            "tokenId": "tok_doesnotexist", "atc": 3, "amountMinor": amount,
            "currency": "RUB", "un": un.hex(), "tvr": tvr, "txnType": txn_type,
            "arqc": base64.b64encode(arqc).decode()})
        check("unknown token rejected", unk.get("approved") is False, str(unk))

        print("\n[9] key expiry")
        print("  waiting for key TTL (2s)...")
        time.sleep(2.2)
        atc3 = 3
        arqc3 = compute_arqc(sk, atc3, amount, "RUB", un, tvr, txn_type)
        expired = post("/tsp/verify-cryptogram", {
            "tokenId": token_id, "atc": atc3, "amountMinor": amount,
            "currency": "RUB", "un": un.hex(), "tvr": tvr, "txnType": txn_type,
            "arqc": base64.b64encode(arqc3).decode()})
        check("expired keys rejected", expired.get("approved") is False, str(expired))
        check("reconnect flag returned", expired.get("reconnectRequired") is True, str(expired))
    finally:
        srv.shutdown()

    print("\n%s\n%d passed, %d failed" % ("=" * 50, len(PASS), len(FAIL)))
    if FAIL:
        for f in FAIL:
            print("  FAILED: " + f)
        return 1
    print("all green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
