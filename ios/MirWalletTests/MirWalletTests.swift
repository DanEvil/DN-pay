//
//  MirWalletTests.swift
//  MirWallet
//
//  Unit tests for the mock crypto layer. The Swift implementation must agree
//  byte-for-byte with the Python server (server/mock_tsp.py), otherwise the
//  transaction flow breaks on device.
//

import XCTest
@testable import MirWallet

final class MirWalletTests: XCTestCase {

    // MARK: - HKDF

    func testHKDFMatchesRFC5869Vector1() {
        // RFC 5869 A.1: IKM = 0x0b x 22, salt = 0x000102...0x0c, info = 0xf0..0xf9
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data((0...12).map { UInt8($0) })
        let info = Data((0xf0...0xf9).map { UInt8($0) })
        let okm = EmvCrypto.hkdf(ikm: ikm, salt: salt, info: info, length: 42)
        let expected = "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
        XCTAssertEqual(okm.hexString, expected)
    }

    func testHKDFLengthRespected() {
        let okm = EmvCrypto.hkdf(ikm: Data(repeating: 1, count: 16),
                                 salt: Data(repeating: 2, count: 8),
                                 info: Data("x".utf8),
                                 length: 32)
        XCTAssertEqual(okm.count, 32)
    }

    // MARK: - Shared Swift/Python vectors

    /// The three canonical vectors. If the Swift algorithm drifts from the
    /// Python server, these fail and the device transaction flow breaks.
    /// Values are produced by tools/parity_check.py --emit-vectors and
    /// re-verified on every CI run by tools/parity_check.py.
    func testSharedVectorsMatchServer() {
        struct Vector {
            let masterKey: String
            let udid: String
            let tokenId: String
            let sessionKey: String
            let atc: Int
            let amount: String
            let currency: String
            let un: String
            let tvr: String
            let txnType: String
            let arqc: String
        }

        let vectors = [
            Vector(masterKey: String(repeating: "5a", count: 32),
                   udid: "TESTUDID0001", tokenId: "tok_abc",
                   sessionKey: "ab8acea0a6648e765a08c00883dd669e130ecd52a0345f33cb7ae8a581156285",
                   atc: 1, amount: "4990", currency: "RUB",
                   un: "1122334455667788", tvr: "0000000000", txnType: "00",
                   arqc: "097a04ba116a6ebf"),
            Vector(masterKey: String(repeating: "00", count: 32),
                   udid: "DEVICE_A", tokenId: "tok_def456",
                   sessionKey: "a38159113af54d34e8ced98d62f5fa91fef2f481e185dd95dc120444c1189ff6",
                   atc: 7, amount: "100", currency: "RUB",
                   un: "0000000000000000", tvr: "0000000000", txnType: "00",
                   arqc: "28a2da3c31c936f8"),
            Vector(masterKey: String(repeating: "ff", count: 32),
                   udid: "DEVICE_B", tokenId: "tok_0000",
                   sessionKey: "8ca549547b01263ce63bd556e1c565848a068a3daec907702538bf2a4620b0c8",
                   atc: 65535, amount: "999999", currency: "RUB",
                   un: "aabbccddeeff0011", tvr: "1234567890", txnType: "01",
                   arqc: "72456692f24cf678"),
        ]

        for vector in vectors {
            guard let master = Data(hexString: vector.masterKey),
                  let un = Data(hexString: vector.un) else {
                XCTFail("bad hex in vector")
                continue
            }
            let sk = EmvCrypto.deriveSessionKey(masterKey: master,
                                                deviceUDID: vector.udid,
                                                tokenId: vector.tokenId)
            XCTAssertEqual(sk.hexString, vector.sessionKey,
                           "session key mismatch for \(vector.tokenId)")

            let arqc = EmvCrypto.computeARQC(sessionKey: sk,
                                             atc: vector.atc,
                                             amountMinor: vector.amount,
                                             currency: vector.currency,
                                             unpredictableNumber: un,
                                             tvr: vector.tvr,
                                             transactionType: vector.txnType)
            XCTAssertEqual(arqc.hexString, vector.arqc,
                           "ARQC mismatch for \(vector.tokenId)")
        }
    }

    // MARK: - ARQC

    func testARQCIsDeterministic() {
        let key = Data(repeating: 0xAB, count: 32)
        let un = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        let first = EmvCrypto.computeARQC(sessionKey: key, atc: 1,
                                          amountMinor: "4990", currency: "RUB",
                                          unpredictableNumber: un,
                                          tvr: "0000000000", transactionType: "00")
        let second = EmvCrypto.computeARQC(sessionKey: key, atc: 1,
                                           amountMinor: "4990", currency: "RUB",
                                           unpredictableNumber: un,
                                           tvr: "0000000000", transactionType: "00")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, EmvCrypto.arqcLength)
    }

    func testARQCChangesWithAmount() {
        let key = Data(repeating: 0xAB, count: 32)
        let un = Data(repeating: 0x11, count: 8)
        let a = EmvCrypto.computeARQC(sessionKey: key, atc: 1, amountMinor: "1000",
                                      currency: "RUB", unpredictableNumber: un,
                                      tvr: "0000000000", transactionType: "00")
        let b = EmvCrypto.computeARQC(sessionKey: key, atc: 1, amountMinor: "2000",
                                      currency: "RUB", unpredictableNumber: un,
                                      tvr: "0000000000", transactionType: "00")
        XCTAssertNotEqual(a, b)
    }

    func testARQCChangesWithATC() {
        let key = Data(repeating: 0xAB, count: 32)
        let un = Data(repeating: 0x11, count: 8)
        let a = EmvCrypto.computeARQC(sessionKey: key, atc: 1, amountMinor: "1000",
                                      currency: "RUB", unpredictableNumber: un,
                                      tvr: "0000000000", transactionType: "00")
        let b = EmvCrypto.computeARQC(sessionKey: key, atc: 2, amountMinor: "1000",
                                      currency: "RUB", unpredictableNumber: un,
                                      tvr: "0000000000", transactionType: "00")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Session key derivation

    func testSessionKeyDerivationIsStable() {
        let master = Data(repeating: 0x5A, count: 32)
        let a = EmvCrypto.deriveSessionKey(masterKey: master,
                                           deviceUDID: "TESTUDID0001",
                                           tokenId: "tok_abc")
        let b = EmvCrypto.deriveSessionKey(masterKey: master,
                                           deviceUDID: "TESTUDID0001",
                                           tokenId: "tok_abc")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testSessionKeyDiffersPerDevice() {
        let master = Data(repeating: 0x5A, count: 32)
        let a = EmvCrypto.deriveSessionKey(masterKey: master,
                                           deviceUDID: "DEVICE_A", tokenId: "tok_abc")
        let b = EmvCrypto.deriveSessionKey(masterKey: master,
                                           deviceUDID: "DEVICE_B", tokenId: "tok_abc")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Embedded TSP

    /// The in-app TSP must agree with the Python server on the card checks.
    func testEmbeddedCoreMirrorsPythonCardChecks() {
        let core = MockTspCore(masterKey: Data(repeating: 0x5a, count: 32))

        let (status, ok) = core.handle(path: "/tsp/check-card", method: "POST",
                                       body: ["pan": "2200123456789019", "cvv": "123", "expiry": "12/29"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(ok["approved"] as? Bool, true)
        XCTAssertEqual(ok["scheme"] as? String, "mir")
        XCTAssertEqual(ok["last4"] as? String, "9019")

        let (_, luhnFailed) = core.handle(path: "/tsp/check-card", method: "POST",
                                          body: ["pan": "2200123456789018", "cvv": "123", "expiry": "12/29"])
        XCTAssertEqual(luhnFailed["approved"] as? Bool, false)
        XCTAssertEqual(luhnFailed["reason"] as? String, "luhn_failed")

        let (_, badCvv) = core.handle(path: "/tsp/check-card", method: "POST",
                                      body: ["pan": "2200123456789019", "cvv": "1", "expiry": "12/29"])
        XCTAssertEqual(badCvv["reason"] as? String, "cvv_length")
    }

    /// Full round trip through the embedded core: provision, sign, verify.
    func testEmbeddedCoreApprovesValidCryptogram() throws {
        let core = MockTspCore(masterKey: Data(repeating: 0x5a, count: 32))

        let (status, provisioning) = core.handle(path: "/tsp/link-and-provision", method: "POST",
                                                 body: ["pan": "2200123456789019",
                                                        "device": ["udid": "TESTUDID0001"]])
        XCTAssertEqual(status, 200)
        let tokenId = try XCTUnwrap(provisioning["tokenId"] as? String)
        let sessionKey = try XCTUnwrap(Data(base64Encoded: provisioning["sessionKey"] as? String ?? ""))

        let un = Data(repeating: 0x11, count: 8)
        let arqc = EmvCrypto.computeARQC(sessionKey: sessionKey, atc: 1,
                                          amountMinor: "4990", currency: "RUB",
                                          unpredictableNumber: un, tvr: "0000000000",
                                          transactionType: "00")

        let (_, verified) = core.handle(path: "/tsp/verify-cryptogram", method: "POST",
                                        body: ["tokenId": tokenId, "atc": 1,
                                               "amountMinor": "4990", "currency": "RUB",
                                               "un": un.hexString, "tvr": "0000000000",
                                               "txnType": "00",
                                               "arqc": arqc.base64EncodedString()])
        XCTAssertEqual(verified["approved"] as? Bool, true)
    }

    /// Replaying the same ATC must be refused, exactly like the Python server.
    func testEmbeddedCoreRejectsReplay() throws {
        let core = MockTspCore(masterKey: Data(repeating: 0x5a, count: 32))
        let (_, provisioning) = core.handle(path: "/tsp/link-and-provision", method: "POST",
                                            body: ["pan": "2200123456789019",
                                                   "device": ["udid": "TESTUDID0001"]])
        let tokenId = try XCTUnwrap(provisioning["tokenId"] as? String)
        let sessionKey = try XCTUnwrap(Data(base64Encoded: provisioning["sessionKey"] as? String ?? ""))

        let un = Data(repeating: 0x11, count: 8)
        let arqc = EmvCrypto.computeARQC(sessionKey: sessionKey, atc: 1,
                                          amountMinor: "4990", currency: "RUB",
                                          unpredictableNumber: un, tvr: "0000000000",
                                          transactionType: "00")
        let body: [String: Any] = ["tokenId": tokenId, "atc": 1, "amountMinor": "4990",
                                   "currency": "RUB", "un": un.hexString, "tvr": "0000000000",
                                   "txnType": "00", "arqc": arqc.base64EncodedString()]

        let (_, first) = core.handle(path: "/tsp/verify-cryptogram", method: "POST", body: body)
        XCTAssertEqual(first["approved"] as? Bool, true)

        let (_, replay) = core.handle(path: "/tsp/verify-cryptogram", method: "POST", body: body)
        XCTAssertEqual(replay["approved"] as? Bool, false)
        XCTAssertEqual(replay["reason"] as? String, "atc_replay")
    }

    /// The embedded server must bind to loopback, never to the LAN.
    func testEmbeddedServerBindsToLoopbackOnly() {
        let server = LocalTspServer(core: MockTspCore(masterKey: Data(repeating: 0x5a, count: 32)))
        XCTAssertEqual(server.baseURL.host, "127.0.0.1")
    }

    // MARK: - Hex

    func testHexRoundTrip() {
        let data = Data([0x00, 0x0f, 0xff, 0xa5])
        XCTAssertEqual(data.hexString, "000fffa5")
        XCTAssertEqual(Data(hexString: "000fffa5"), data)
    }
}
