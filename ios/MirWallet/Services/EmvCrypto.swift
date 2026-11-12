//
//  EmvCrypto.swift
//  MirWallet
//
//  Cryptography for the mock Mir payment stack.
//
//  IMPORTANT — scope of this file:
//  These primitives reproduce the *shape* of the EMV/Apple Pay flow so the
//  full protocol can be exercised on real iOS hardware against the local mock
//  TSP (mock_tsp.py). The key derivation below (HKDF-SHA256) and the ARQC
//  computation (HMAC-SHA256 truncated to 8 bytes) are a MOCK scheme defined
//  by this project, not Mir's production scheme and not Apple's.
//
//  A cryptogram produced here is accepted only by mock_tsp.py. Real acquirers
//  validate against keys provisioned by the issuer's Token Service Provider
//  into the Secure Element, which no third-party app can write to.
//

import Foundation
import CryptoKit
import Security

enum EmvCrypto {

    // MARK: - Key derivation (mock)

    /// RFC 5869 HKDF-SHA256. Must match hkdf() in server/mock_tsp.py byte for byte.
    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        let prk = hmac(key: salt, data: ikm)
        var okm = Data()
        var t = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            var input = t
            input.append(info)
            input.append(counter)
            t = hmac(key: prk, data: input)
            okm.append(t)
            counter += 1
        }
        return Data(okm.prefix(length))
    }

    static func hmac(key: Data, data: Data) -> Data {
        let sym = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: sym))
    }

    /// Derives the device session key exactly as the mock TSP does.
    static func deriveSessionKey(masterKey: Data, deviceUDID: String, tokenId: String) -> Data {
        hkdf(ikm: masterKey,
             salt: Data(deviceUDID.utf8),
             info: Data(("mir-mock-sk|\(tokenId)").utf8))
    }

    // MARK: - Application cryptogram (mock)

    static let arqcLength = 8

    /// Computes the application cryptogram.
    /// Must stay byte-identical to compute_arqc() in server/mock_tsp.py.
    static func computeARQC(sessionKey: Data,
                            atc: Int,
                            amountMinor: String,
                            currency: String,
                            unpredictableNumber: Data,
                            tvr: String,
                            transactionType: String) -> Data {
        let message = String(
            format: "ARQC|%d|%@|%@|%@|%@|%@",
            atc, amountMinor, currency, unpredictableNumber.hexString,
            tvr, transactionType)
        let mac = hmac(key: sessionKey, data: Data(message.utf8))
        return Data(mac.prefix(arqcLength))
    }

    // MARK: - Key material helpers

    /// Random bytes for the unpredictable number.
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            return Data((0..<count).map { _ in UInt8.random(in: 0...255) })
        }
        return Data(bytes)
    }
}

// MARK: - Hex

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0, let data = Data(hexString: cleaned) else { return nil }
        self = data
    }
}
