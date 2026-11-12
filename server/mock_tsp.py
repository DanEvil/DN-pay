#!/usr/bin/env python3
"""Mock TSP + issuer simulator for the MirWallet iOS prototype.

Implements the same three server-side calls Apple Pay uses against a card
issuer's Token Service Provider, plus an issuer-side cryptogram verifier:

    POST /tsp/required-fields      -> which fields the issuer needs
    POST /tsp/check-card           -> eligibility check for the card
    POST /tsp/link-and-provision   -> issues DPAN + device session key
    POST /tsp/verify-cryptogram    -> validates ARQC, anti-replay on ATC
    GET  /tsp/health               -> liveness

IMPORTANT: this is a *mock*. The session key scheme below is HMAC-SHA256 based
and exists so that the iOS client and this server agree, so the full protocol
stack can be exercised on real hardware without any real payment network.
Tokens minted here are NOT accepted by real acquirers: the real cryptogram key
is provisioned into the Secure Element by the issuer's TSP after the network
performs its own card checks.

Zero third-party dependencies (stdlib only).
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCHEME = "MOCK-MIR-1"
ARQC_LEN = 8


# --------------------------------------------------------------------------- crypto

def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 HKDF (extract + expand)."""
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        okm += t
        i += 1
    return okm[:length]


def compute_arqc(sk: bytes, atc: int, amount_minor: str, currency: str,
                 un: bytes, tvr: str, txn_type: str) -> bytes:
    """Application cryptogram. Must stay byte-identical to EmvCrypto.swift."""
    msg = ("ARQC|%d|%s|%s|%s|%s|%s" % (
        atc, amount_minor, currency, un.hex(), tvr, txn_type)).encode()
    return hmac.new(sk, msg, hashlib.sha256).digest()[:ARQC_LEN]


def luhn_ok(pan: str) -> bool:
    digits = [int(c) for c in pan if c.isdigit()]
    if len(digits) < 12:
        return False
    checksum, parity = 0, len(digits) % 2
    for i, d in enumerate(digits):
        if i % 2 == parity:
            d *= 2
            if d > 9:
                d -= 9
        checksum += d
    return checksum % 10 == 0


def detect_scheme(pan: str) -> str:
    """Best-effort brand guess. Mock only."""
    if pan.startswith("2200") or pan.startswith("2201") or pan.startswith("2202"):
        return "mir"
    if pan[0] == "4":
        return "visa"
    if pan[0] == "5":
        return "mastercard"
    if pan.startswith("34") or pan.startswith("37"):
        return "amex"
    return "unknown"


# --------------------------------------------------------------------------- state

class Store:
    def __init__(self, master_key: bytes, key_ttl: int):
        self.lock = threading.Lock()
        self.master_key = master_key
        self.key_ttl = key_ttl
        self.tokens: dict[str, dict] = {}
        self.audit: list[dict] = []

    def issue(self, token_id: str, device_udid: str) -> tuple[str, bytes]:
        dpan = "555555%012d" % secrets.randbelow(10 ** 12)
        info = ("mir-mock-sk|%s" % token_id).encode()
        sk = hkdf(self.master_key, device_udid.encode(), info, 32)
        return dpan, sk

    def log(self, event: str, **fields):
        entry = {"ts": round(time.time(), 3), "event": event}
        entry.update(fields)
        with self.lock:
            self.audit.append(entry)
            del self.audit[:-500]


# --------------------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    store: Store = None  # type: ignore[assignment]
    verbose = False

    server_version = "MockTSP/1.0"

    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write("[mock-tsp] " + (fmt % args) + "\n")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _send(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") == "/tsp/health":
            self._send(200, {"ok": True, "scheme": SCHEME,
                             "tokens": len(self.store.tokens)})
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self):
        body = self._read_json()
        route = self.path.rstrip("/")
        handler = {
            "/tsp/required-fields": self.r_required_fields,
            "/tsp/check-card": self.r_check_card,
            "/tsp/link-and-provision": self.r_link_and_provision,
            "/tsp/verify-cryptogram": self.r_verify_cryptogram,
        }.get(route)
        if handler is None:
            self._send(404, {"error": "not_found"})
            return
        try:
            code, payload = handler(body)
        except Exception as exc:  # pragma: no cover
            self._send(500, {"error": type(exc).__name__, "message": str(exc)})
            return
        self._send(code, payload)

    # -- routes ----------------------------------------------------------

    def r_required_fields(self, body):
        return 200, {"fields": ["pan", "expiryMonth", "expiryYear", "cvv",
                                "deviceName", "deviceUDID"],
                     "scheme": SCHEME}

    def r_check_card(self, body):
        pan = str(body.get("pan") or "")
        cvv = str(body.get("cvv") or "")
        exp = str(body.get("expiry") or "")
        if not luhn_ok(pan):
            return 200, {"approved": False, "reason": "luhn_failed"}
        if len(cvv) not in (3, 4):
            return 200, {"approved": False, "reason": "cvv_length"}
        if not exp:
            return 200, {"approved": False, "reason": "expiry_missing"}
        brand = detect_scheme(pan)
        self.store.log("check-card", brand=brand, last4=pan[-4:])
        return 200, {"approved": True, "scheme": brand,
                     "last4": pan[-4:], "product": "debit"}

    def r_link_and_provision(self, body):
        pan = str(body.get("pan") or "")
        device = body.get("device") or {}
        udid = str(device.get("udid") or "")
        if not pan or not udid:
            return 400, {"error": "pan_and_device_udid_required"}
        token_id = "tok_" + secrets.token_hex(12)
        dpan, sk = self.store.issue(token_id, udid)
        now = time.time()
        with self.store.lock:
            self.store.tokens[token_id] = {
                "dpan": dpan,
                "sk": sk,
                "atc": 0,
                "last_atc": 0,
                "pan_last4": pan[-4:],
                "brand": detect_scheme(pan),
                "device_udid": udid,
                "issued_at": now,
                "keys_expire_at": now + self.store.key_ttl,
            }
        self.store.log("provision", token_id=token_id, brand=detect_scheme(pan))
        return 200, {
            "tokenId": token_id,
            "dpan": dpan,
            "sessionKey": base64.b64encode(sk).decode(),
            "atc": 0,
            "keysExpireAt": now + self.store.key_ttl,
            "scheme": SCHEME,
        }

    def r_verify_cryptogram(self, body):
        token_id = str(body.get("tokenId") or "")
        atc = int(body.get("atc") or 0)
        arqc_b64 = str(body.get("arqc") or "")
        amount = str(body.get("amountMinor") or "0")
        currency = str(body.get("currency") or "RUB")
        un_hex = str(body.get("un") or "")
        tvr = str(body.get("tvr") or "")
        txn_type = str(body.get("txnType") or "")
        try:
            arqc = base64.b64decode(arqc_b64)
            un = bytes.fromhex(un_hex)
        except Exception:
            return 200, {"approved": False, "reason": "malformed_payload"}
        with self.store.lock:
            token = self.store.tokens.get(token_id)
            if token is None:
                return 200, {"approved": False, "reason": "unknown_token"}
            if token["keys_expire_at"] < time.time():
                return 200, {"approved": False, "reason": "keys_expired",
                             "reconnectRequired": True}
            if atc <= token["last_atc"]:
                return 200, {"approved": False, "reason": "atc_replay",
                             "lastAtc": token["last_atc"]}
            expected = compute_arqc(token["sk"], atc, amount, currency, un, tvr, txn_type)
            if not hmac.compare_digest(expected, arqc):
                return 200, {"approved": False, "reason": "cryptogram_mismatch"}
            token["last_atc"] = atc
            token["atc"] = max(token["atc"], atc)
        self.store.log("authorize", token_id=token_id, atc=atc, amount=amount)
        return 200, {"approved": True, "reason": "approved", "atc": atc,
                     "scheme": SCHEME}


# --------------------------------------------------------------------------- main

def lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def main() -> int:
    ap = argparse.ArgumentParser(description="Mock TSP / issuer simulator")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--key-file", default=os.path.join(os.path.dirname(__file__), "master.key"))
    ap.add_argument("--key-ttl", type=int, default=3600,
                    help="seconds before offline session keys need refresh")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if os.path.exists(args.key_file):
        master = base64.b64decode(open(args.key_file, "rb").read())
    else:
        master = secrets.token_bytes(32)
        with open(args.key_file, "wb") as fh:
            fh.write(base64.b64encode(master))
        try:
            os.chmod(args.key_file, 0o600)
        except OSError:
            pass

    Handler.store = Store(master, args.key_ttl)
    Handler.verbose = args.verbose
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Mock TSP [%s] listening on http://%s:%d" % (SCHEME, args.host, args.port))
    print("  reachable from iPhone at: http://%s:%d" % (lan_ip(), args.port))
    print("  master key file: %s" % args.key_file)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
