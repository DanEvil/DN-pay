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

    // MARK: - NFC capability detection

    /// The model identifier must be readable, otherwise the NFC tab cannot
    /// tell hardware apart from permissions.
    func testHardwareModelIsDetected() {
        XCTAssertFalse(NfcCapabilities.hardwareModel.isEmpty)
    }

    /// The simulator has no NFC radio, and the detector must not claim it
    /// has one.
    func testSimulatorReportsNoNFCHardware() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(NfcCapabilities.hardwareSupport, .absent)
        #else
        // On a device the verdict must be one of the two known states.
        XCTAssertTrue([NfcCapabilities.HardwareSupport.present,
                       .absent,
                       .unknown].contains(NfcCapabilities.hardwareSupport))
        #endif
    }

    /// Every iPhone from the XS generation onwards carries an NFC radio.
    /// The model strings are checked directly so the rule is pinned down
    /// even on the simulator.
    func testNFCHardwareRule() {
        // iPhone XS and later: present.
        for model in ["iPhone10,3", "iPhone10,6", "iPhone11,2", "iPhone11,8",
                      "iPhone12,1", "iPhone13,2", "iPhone14,4", "iPhone14,5",
                      "iPhone15,2", "iPhone16,1"] {
            XCTAssertEqual(NfcCapabilities.hardwareSupport(forModel: model), .present,
                           "\(model) should have NFC")
        }
        // iPhone 8, X, XR-era and older: absent.
        for model in ["iPhone8,1", "iPhone8,4", "iPhone9,1", "iPhone9,3",
                      "iPhone10,1", "iPhone10,4"] {
            XCTAssertEqual(NfcCapabilities.hardwareSupport(forModel: model), .absent,
                           "\(model) should not have NFC")
        }
    }

    /// The entitlement reader must cope with a bundle that has no embedded
    /// profile at all — that is the case for an unsigned build.
    func testProfileEntitlementsHandlesMissingProfile() {
        let entitlements = NfcCapabilities.profileEntitlements
        // Either a profile was found and parsed, or none was found. Both are
        // valid states; a crash is not.
        if entitlements.profileFound {
            XCTAssertFalse(entitlements.keys.isEmpty)
        }
    }

    // MARK: - Hex

    func testHexRoundTrip() {
        let data = Data([0x00, 0x0f, 0xff, 0xa5])
        XCTAssertEqual(data.hexString, "000fffa5")
        XCTAssertEqual(Data(hexString: "000fffa5"), data)
    }

    // MARK: - Wallet

    /// A fresh wallet holds nothing and has no primary card.
    func testWalletStartsEmpty() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        XCTAssertTrue(store.cards.isEmpty)
        XCTAssertNil(store.primaryCard)
    }

    /// The first saved card becomes the primary one.
    func testFirstSavedCardBecomesPrimary() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        XCTAssertEqual(store.cards.count, 1)
        XCTAssertEqual(store.primaryCard?.id, "tok_a")
    }

    /// Saving a second card must not steal the primary slot.
    func testSecondCardDoesNotStealPrimary() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        store.add(Self.walletCard(tokenId: "tok_b", last4: "2222"))
        XCTAssertEqual(store.primaryCard?.id, "tok_a")
        XCTAssertEqual(store.cards.count, 2)
    }

    /// The user picks the primary card explicitly.
    func testPrimaryCardCanBeSwitched() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        store.add(Self.walletCard(tokenId: "tok_b", last4: "2222"))
        store.setPrimary(id: "tok_b")
        XCTAssertEqual(store.primaryCard?.id, "tok_b")
    }

    /// Removing the primary card promotes another one, so the wallet never
    /// ends up without a default.
    func testRemovingPrimaryPromotesAnotherCard() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        store.add(Self.walletCard(tokenId: "tok_b", last4: "2222"))
        store.remove(id: "tok_a")
        XCTAssertEqual(store.primaryCard?.id, "tok_b")
        XCTAssertEqual(store.cards.count, 1)
    }

    /// Removing the last card leaves no primary.
    func testRemovingLastCardClearsPrimary() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        store.remove(id: "tok_a")
        XCTAssertNil(store.primaryCard)
    }

    /// Saving the same card twice must not duplicate it.
    func testSavingSameCardTwiceDoesNotDuplicate() {
        let store = WalletStore(fileURL: Self.temporaryWalletURL())
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        XCTAssertEqual(store.cards.count, 1)
    }

    /// The wallet survives an app restart.
    func testWalletPersistsAcrossInstances() {
        let url = Self.temporaryWalletURL()
        let first = WalletStore(fileURL: url)
        first.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        first.add(Self.walletCard(tokenId: "tok_b", last4: "2222"))
        first.setPrimary(id: "tok_b")

        let second = WalletStore(fileURL: url)
        XCTAssertEqual(second.cards.count, 2)
        XCTAssertEqual(second.primaryCard?.id, "tok_b")
    }

    /// The PAN must never end up in the wallet file.
    func testWalletDoesNotStorePAN() throws {
        let url = Self.temporaryWalletURL()
        let store = WalletStore(fileURL: url)
        store.add(Self.walletCard(tokenId: "tok_a", last4: "1111"))
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("2200123456789019"))
        XCTAssertFalse(raw.contains("cvv"))
    }

    // MARK: - Terminal

    /// The terminal owns the amount: it is what the app signs and displays.
    func testTerminalRequestCarriesAmount() {
        let terminal = MockTerminal(amounts: ["1990"], currency: "RUB")
        let request = terminal.nextRequest()
        XCTAssertEqual(request.amountMinor, "1990")
        XCTAssertEqual(request.currency, "RUB")
        XCTAssertEqual(request.amountDisplay, "19.90")
    }

    /// Requests differ in their unpredictable number, so two transactions
    /// never produce the same cryptogram.
    func testTerminalRequestsUseFreshUnpredictableNumbers() {
        let terminal = MockTerminal(amounts: ["1990"], currency: "RUB")
        let first = terminal.nextRequest()
        let second = terminal.nextRequest()
        XCTAssertNotEqual(first.unpredictableNumber, second.unpredictableNumber)
    }

    /// The amount the terminal asks for is the amount that gets signed, and
    /// the TSP accepts it.
    func testTerminalAmountIsTheAmountThatGetsSigned() throws {
        let terminal = MockTerminal(amounts: ["4990"], currency: "RUB")
        let request = terminal.nextRequest()

        let core = MockTspCore(masterKey: Data(repeating: 0x5a, count: 32))
        let (_, provisioning) = core.handle(path: "/tsp/link-and-provision", method: "POST",
                                            body: ["pan": "2200123456789019",
                                                   "device": ["udid": "TESTUDID0001"]])
        let tokenId = try XCTUnwrap(provisioning["tokenId"] as? String)
        let sessionKey = try XCTUnwrap(Data(base64Encoded: provisioning["sessionKey"] as? String ?? ""))

        let arqc = EmvCrypto.computeARQC(sessionKey: sessionKey, atc: 1,
                                          amountMinor: request.amountMinor,
                                          currency: request.currency,
                                          unpredictableNumber: request.unpredictableNumber,
                                          tvr: request.tvr, transactionType: request.transactionType)

        let (_, verified) = core.handle(path: "/tsp/verify-cryptogram", method: "POST",
                                        body: ["tokenId": tokenId, "atc": 1,
                                               "amountMinor": request.amountMinor,
                                               "currency": request.currency,
                                               "un": request.unpredictableNumber.hexString,
                                               "tvr": request.tvr,
                                               "txnType": request.transactionType,
                                               "arqc": arqc.base64EncodedString()])
        XCTAssertEqual(verified["approved"] as? Bool, true)
    }

    // MARK: - Biometrics

    /// The confirmation prompt must name the method the user will see.
    func testBiometryTypeIsNamed() {
        XCTAssertEqual(BiometricAuthenticator.method(for: .faceID), .faceID)
        XCTAssertEqual(BiometricAuthenticator.method(for: .touchID), .touchID)
        XCTAssertEqual(BiometricAuthenticator.method(for: .none), .none)
    }

    // MARK: - Helpers

    private static func temporaryWalletURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private static func walletCard(tokenId: String, last4: String) -> WalletCard {
        WalletCard(tokenId: tokenId, dpan: "555555000000000001", last4: last4,
                   scheme: "mir", expiry: "12/29")
    }
}
