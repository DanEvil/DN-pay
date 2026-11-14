//
//  MockTspCore.swift
//  MirWallet
//
//  In-process mirror of server/mock_tsp.py.
//
//  Every route, every rejection reason and every byte of crypto here matches
//  the Python server exactly, so the same client code works against either
//  one. The Python server stays the reference implementation (CI runs the
//  cross-language parity check); this copy lets the app run standalone on the
//  phone with no companion machine on the network.
//
//  IMPORTANT: this is a *mock*. Tokens minted here are not accepted by real
//  acquirers — the real cryptogram key is provisioned into the Secure Element
//  by the issuer's TSP after the network performs its own card checks.
//

import Foundation

final class MockTspCore {

    static let scheme = "MOCK-MIR-1"

    // MARK: - State

    struct Token {
        let dpan: String
        let sessionKey: Data
        var atc: Int
        var lastAtc: Int
        let panLast4: String
        let brand: String
        let deviceUDID: String
        let issuedAt: Double
        let keysExpireAt: Double
    }

    private let lock = NSLock()
    private let masterKey: Data
    private let keyTTL: TimeInterval
    private var tokens: [String: Token] = [:]
    private var audit: [[String: Any]] = []

    init(masterKey: Data, keyTTL: TimeInterval = 3600) {
        self.masterKey = masterKey
        self.keyTTL = keyTTL
    }

    var tokenCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tokens.count
    }

    var auditTrail: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return audit
    }

    // MARK: - Routing

    /// Handles one request. Returns the HTTP status code and the JSON body,
    /// mirroring the Python server's response codes exactly.
    func handle(path: String, method: String, body: [String: Any]) -> (status: Int, payload: [String: Any]) {
        switch (method, path) {
        case ("GET", "/tsp/health"):
            return (200, ["ok": true, "scheme": Self.scheme, "tokens": tokenCount])
        case ("POST", "/tsp/required-fields"):
            return requiredFields()
        case ("POST", "/tsp/check-card"):
            return checkCard(body)
        case ("POST", "/tsp/link-and-provision"):
            return linkAndProvision(body)
        case ("POST", "/tsp/verify-cryptogram"):
            return verifyCryptogram(body)
        default:
            return (404, ["error": "not_found"])
        }
    }

    private func requiredFields() -> (status: Int, payload: [String: Any]) {
        (200, [
            "fields": ["pan", "expiryMonth", "expiryYear", "cvv", "deviceName", "deviceUDID"],
            "scheme": Self.scheme,
        ])
    }

    // MARK: - Routes

    private func checkCard(_ body: [String: Any]) -> (status: Int, payload: [String: Any]) {
        let pan = Self.string(body["pan"])
        let cvv = Self.string(body["cvv"])
        let expiry = Self.string(body["expiry"])

        if !Self.luhnOK(pan) {
            return (200, ["approved": false, "reason": "luhn_failed"])
        }
        if cvv.count != 3 && cvv.count != 4 {
            return (200, ["approved": false, "reason": "cvv_length"])
        }
        if expiry.isEmpty {
            return (200, ["approved": false, "reason": "expiry_missing"])
        }

        let brand = Self.detectScheme(pan)
        log("check-card", ["brand": brand, "last4": String(pan.suffix(4))])
        return (200, [
            "approved": true,
            "scheme": brand,
            "last4": String(pan.suffix(4)),
            "product": "debit",
        ])
    }

    private func linkAndProvision(_ body: [String: Any]) -> (status: Int, payload: [String: Any]) {
        let pan = Self.string(body["pan"])
        let device = body["device"] as? [String: Any] ?? [:]
        let udid = Self.string(device["udid"])

        guard !pan.isEmpty, !udid.isEmpty else {
            return (400, ["error": "pan_and_device_udid_required"])
        }

        let tokenId = "tok_" + EmvCrypto.randomBytes(count: 12).hexString
        let dpan = String(format: "555555%012d", Int.random(in: 0..<1_000_000_000_000))
        let sessionKey = EmvCrypto.deriveSessionKey(masterKey: masterKey,
                                                    deviceUDID: udid,
                                                    tokenId: tokenId)
        let now = Date().timeIntervalSince1970

        lock.lock()
        tokens[tokenId] = Token(
            dpan: dpan,
            sessionKey: sessionKey,
            atc: 0,
            lastAtc: 0,
            panLast4: String(pan.suffix(4)),
            brand: Self.detectScheme(pan),
            deviceUDID: udid,
            issuedAt: now,
            keysExpireAt: now + keyTTL
        )
        lock.unlock()

        log("provision", ["tokenId": tokenId, "brand": Self.detectScheme(pan)])

        return (200, [
            "tokenId": tokenId,
            "dpan": dpan,
            "sessionKey": sessionKey.base64EncodedString(),
            "atc": 0,
            "keysExpireAt": now + keyTTL,
            "scheme": Self.scheme,
        ])
    }

    private func verifyCryptogram(_ body: [String: Any]) -> (status: Int, payload: [String: Any]) {
        let tokenId = Self.string(body["tokenId"])
        let atc = Int(Self.string(body["atc"])) ?? 0
        let arqcBase64 = Self.string(body["arqc"])
        let amount = Self.string(body["amountMinor"]).isEmpty ? "0" : Self.string(body["amountMinor"])
        let currency = Self.string(body["currency"]).isEmpty ? "RUB" : Self.string(body["currency"])
        let unHex = Self.string(body["un"])
        let tvr = Self.string(body["tvr"])
        let txnType = Self.string(body["txnType"])

        guard let arqc = Data(base64Encoded: arqcBase64),
              let un = Data(hexString: unHex) else {
            return (200, ["approved": false, "reason": "malformed_payload"])
        }

        lock.lock()
        guard let token = tokens[tokenId] else {
            lock.unlock()
            return (200, ["approved": false, "reason": "unknown_token"])
        }
        if token.keysExpireAt < Date().timeIntervalSince1970 {
            lock.unlock()
            return (200, [
                "approved": false,
                "reason": "keys_expired",
                "reconnectRequired": true,
            ])
        }
        if atc <= token.lastAtc {
            let lastAtc = token.lastAtc
            lock.unlock()
            return (200, [
                "approved": false,
                "reason": "atc_replay",
                "lastAtc": lastAtc,
            ])
        }

        let expected = EmvCrypto.computeARQC(sessionKey: token.sessionKey,
                                             atc: atc,
                                             amountMinor: amount,
                                             currency: currency,
                                             unpredictableNumber: un,
                                             tvr: tvr,
                                             transactionType: txnType)
        guard Self.constantTimeEquals(expected, arqc) else {
            lock.unlock()
            return (200, ["approved": false, "reason": "cryptogram_mismatch"])
        }

        tokens[tokenId]?.lastAtc = atc
        tokens[tokenId]?.atc = max(tokens[tokenId]?.atc ?? 0, atc)
        lock.unlock()

        log("authorize", ["tokenId": tokenId, "atc": atc, "amount": amount])

        return (200, [
            "approved": true,
            "reason": "approved",
            "atc": atc,
            "scheme": Self.scheme,
        ])
    }

    // MARK: - Helpers (mirrors of the Python module-level functions)

    static func luhnOK(_ pan: String) -> Bool {
        let digits = pan.compactMap { $0.wholeNumberValue }
        guard digits.count >= 12 else { return false }
        var checksum = 0
        let parity = digits.count % 2
        for (index, value) in digits.enumerated() {
            var digit = value
            if index % 2 == parity {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            checksum += digit
        }
        return checksum % 10 == 0
    }

    static func detectScheme(_ pan: String) -> String {
        if pan.hasPrefix("2200") || pan.hasPrefix("2201") || pan.hasPrefix("2202") {
            return "mir"
        }
        if pan.first == "4" { return "visa" }
        if pan.first == "5" { return "mastercard" }
        if pan.hasPrefix("34") || pan.hasPrefix("37") { return "amex" }
        return "unknown"
    }

    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let number as Int: return String(number)
        default: return ""
        }
    }

    /// Constant-time comparison, the equivalent of Python's hmac.compare_digest.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private func log(_ event: String, _ fields: [String: Any]) {
        var entry: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "event": event,
        ]
        for (key, value) in fields { entry[key] = value }
        lock.lock()
        audit.append(entry)
        if audit.count > 500 { audit.removeFirst(audit.count - 500) }
        lock.unlock()
    }
}
