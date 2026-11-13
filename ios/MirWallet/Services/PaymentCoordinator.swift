//
//  PaymentCoordinator.swift
//  MirWallet
//
//  Drives the full mock transaction flow:
//      check-card -> link-and-provision -> (build ARQC) -> verify-cryptogram
//
//  Every step goes through the configured TSP, so the whole protocol can be
//  exercised on a physical iPhone with no Apple entitlement and no network
//  beyond the machine running mock_tsp.py.
//

import Foundation
import UIKit
import Combine

@MainActor
final class PaymentCoordinator: ObservableObject {

    enum Stage: String {
        case idle
        case checking
        case provisioning
        case authorizing
        case approved
        case declined
        case failed

        var title: String {
            switch self {
            case .idle: return "Готов"
            case .checking: return "Проверка карты"
            case .provisioning: return "Выпуск токена"
            case .authorizing: return "Авторизация"
            case .approved: return "Оплата одобрена"
            case .declined: return "Отклонено"
            case .failed: return "Ошибка"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var journal: [String] = []
    @Published private(set) var tokenId: String?
    @Published private(set) var dpan: String?
    @Published private(set) var last4: String?
    @Published private(set) var atc = 0
    @Published private(set) var keysExpireAt: Date?
    @Published private(set) var isBusy = false

    @Published var amountMinor: String = "1990"
    @Published var currency: String = "RUB"
    @Published var pan: String = "2200123456789019"
    @Published var cvv: String = "123"
    @Published var expiry: String = "12/29"

    private let tsp = TspClient.shared
    private let keychain = KeychainStore()
    private var sessionKey: Data?

    var deviceUDID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }

    var keysRemainingDescription: String {
        guard let expiry = keysExpireAt else { return "—" }
        let seconds = Int(expiry.timeIntervalSinceNow)
        guard seconds > 0 else { return "истекли" }
        return "\(seconds) с"
    }

    // MARK: - Lifecycle

    init() {
        restoreSession()
    }

    /// Reloads the provisioned session from the Keychain so the app can keep
    /// transacting offline across launches.
    func restoreSession() {
        do {
            sessionKey = try keychain.data(for: KeychainStore.Key.sessionKey)
            tokenId = try keychain.string(for: KeychainStore.Key.tokenId)
            dpan = try keychain.string(for: KeychainStore.Key.dpan)
            last4 = try keychain.string(for: KeychainStore.Key.last4)
            if let atcString = try keychain.string(for: KeychainStore.Key.atc),
               let value = Int(atcString) {
                atc = value
            }
            if let expiryString = try keychain.string(for: KeychainStore.Key.keysExpireAt),
               let value = Double(expiryString) {
                keysExpireAt = Date(timeIntervalSince1970: value)
            }
        } catch {
            appendLog("Не удалось восстановить сессию: \(error.localizedDescription)")
        }
    }

    /// Drops the provisioned session and its keys.
    func clearSession() {
        for key in [KeychainStore.Key.sessionKey, KeychainStore.Key.tokenId,
                    KeychainStore.Key.dpan, KeychainStore.Key.atc,
                    KeychainStore.Key.keysExpireAt, KeychainStore.Key.last4] {
            try? keychain.remove(key)
        }
        sessionKey = nil
        tokenId = nil
        dpan = nil
        last4 = nil
        atc = 0
        keysExpireAt = nil
        appendLog("Сессия очищена")
    }

    // MARK: - Flow

    /// Runs a complete transaction.
    func runTransaction() async {
        guard !isBusy else { return }
        isBusy = true
        journal.removeAll()
        stage = .checking
        defer { isBusy = false }

        do {
            // 1. Check card
            let check = try await tsp.checkCard(pan: pan, cvv: cvv, expiry: expiry)
            guard check.approved else {
                stage = .declined
                appendLog("Карта отклонена: \(check.reason ?? "unknown")")
                return
            }
            last4 = check.last4
            try? keychain.setString(check.last4 ?? "", for: KeychainStore.Key.last4)
            appendLog("Карта проверена: \(check.scheme ?? "?") ***\(last4 ?? "")")

            // 2. Provision
            stage = .provisioning
            let provisioning = try await tsp.linkAndProvision(pan: pan, deviceUDID: deviceUDID)
            tokenId = provisioning.tokenId
            dpan = provisioning.dpan
            atc = provisioning.atc
            keysExpireAt = Date(timeIntervalSince1970: provisioning.keysExpireAt)
            guard let key = Data(base64Encoded: provisioning.sessionKey) else {
                stage = .failed
                appendLog("Не удалось декодировать session key")
                return
            }
            sessionKey = key
            try? keychain.set(key, for: KeychainStore.Key.sessionKey)
            try? keychain.setString(provisioning.tokenId, for: KeychainStore.Key.tokenId)
            try? keychain.setString(provisioning.dpan, for: KeychainStore.Key.dpan)
            try? keychain.setString(String(provisioning.atc), for: KeychainStore.Key.atc)
            try? keychain.setString(String(provisioning.keysExpireAt), for: KeychainStore.Key.keysExpireAt)
            appendLog("Токен выпущен: \(provisioning.tokenId), DPAN \(provisioning.dpan)")
            appendLog("Ключи действительны \(keysRemainingDescription)")

            // 3. Authorize
            stage = .authorizing
            atc += 1
            try? keychain.setString(String(atc), for: KeychainStore.Key.atc)
            let un = EmvCrypto.randomBytes(count: 8)
            let arqc = EmvCrypto.computeARQC(
                sessionKey: key,
                atc: atc,
                amountMinor: amountMinor,
                currency: currency,
                unpredictableNumber: un,
                tvr: "0000000000",
                transactionType: "00")

            let verification = try await tsp.verifyCryptogram(
                tokenId: provisioning.tokenId,
                atc: atc,
                amountMinor: amountMinor,
                currency: currency,
                unpredictableNumber: un,
                tvr: "0000000000",
                transactionType: "00",
                arqc: arqc)

            if verification.approved {
                stage = .approved
                appendLog("Криптограмма принята. ATC=\(atc), ARQC=\(arqc.hexString)")
            } else {
                stage = .declined
                appendLog("Отклонено: \(verification.reason ?? "unknown")")
                if verification.reconnectRequired == true {
                    appendLog("Нужно переподключиться к TSP для обновления ключей")
                }
            }
        } catch {
            stage = .failed
            appendLog("Ошибка: \(error.localizedDescription)")
        }
    }

    /// Proves the anti-replay property: replays the last ATC and expects a decline.
    func runReplayAttack() async {
        guard let tokenId, let key = sessionKey else {
            appendLog("Сначала выполните обычную транзакцию")
            return
        }
        appendLog("--- попытка replay того же ATC ---")
        let un = EmvCrypto.randomBytes(count: 8)
        let arqc = EmvCrypto.computeARQC(
            sessionKey: key, atc: atc, amountMinor: amountMinor, currency: currency,
            unpredictableNumber: un, tvr: "0000000000", transactionType: "00")
        do {
            let result = try await tsp.verifyCryptogram(
                tokenId: tokenId, atc: atc, amountMinor: amountMinor, currency: currency,
                unpredictableNumber: un, tvr: "0000000000", transactionType: "00", arqc: arqc)
            appendLog(result.approved ? "ОШИБКА: replay принят" : "Replay отклонён: \(result.reason ?? "")")
        } catch {
            appendLog("Ошибка: \(error.localizedDescription)")
        }
    }

    /// Proves the amount-binding property: signs for one amount, claims another.
    func runTamperTest() async {
        guard let tokenId, let key = sessionKey else {
            appendLog("Сначала выполните обычную транзакцию")
            return
        }
        appendLog("--- подмена суммы после подписи ---")
        let signedAmount = amountMinor
        let claimedAmount = "1"
        let un = EmvCrypto.randomBytes(count: 8)
        let arqc = EmvCrypto.computeARQC(
            sessionKey: key, atc: atc + 1, amountMinor: signedAmount, currency: currency,
            unpredictableNumber: un, tvr: "0000000000", transactionType: "00")
        do {
            let result = try await tsp.verifyCryptogram(
                tokenId: tokenId, atc: atc + 1, amountMinor: claimedAmount, currency: currency,
                unpredictableNumber: un, tvr: "0000000000", transactionType: "00", arqc: arqc)
            appendLog(result.approved ? "ОШИБКА: подмена принята" : "Подмена отклонена: \(result.reason ?? "")")
        } catch {
            appendLog("Ошибка: \(error.localizedDescription)")
        }
    }

    func appendLog(_ message: String) {
        journal.append(message)
    }
}
