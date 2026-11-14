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
        case confirming
        case authorizing
        case approved
        case declined
        case failed

        var title: String {
            switch self {
            case .idle: return "Готов"
            case .checking: return "Проверка карты"
            case .provisioning: return "Выпуск токена"
            case .confirming: return "Подтверждение"
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

    /// The transaction request the terminal is waiting for, if any.
    /// The amount in it is the terminal's, not the user's.
    @Published private(set) var pendingRequest: TerminalRequest?

    /// Saved cards and the primary one.
    @Published private(set) var wallet: WalletStore

    private let tsp = TspClient.shared
    private let keychain = KeychainStore()
    private let authenticator = BiometricAuthenticator()
    private var terminal = MockTerminal()
    private var sessionKey: Data?

    /// The card that will be used for the next transaction.
    var activeCard: WalletCard? { wallet.primaryCard }

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
        self.wallet = WalletStore()
        restoreSession()
    }

    /// Reloads the provisioned session from the Keychain so the app can keep
    /// transacting offline across launches.
    func restoreSession() {
        do {
            tokenId = try keychain.string(for: KeychainStore.Key.tokenId)
            if let tokenId {
                sessionKey = try keychain.data(for: KeychainStore.Key.sessionKey(for: tokenId))
            }
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
        var keys = [KeychainStore.Key.sessionKey, KeychainStore.Key.tokenId,
                    KeychainStore.Key.dpan, KeychainStore.Key.atc,
                    KeychainStore.Key.keysExpireAt, KeychainStore.Key.last4]
        // Every saved card has its own session key.
        keys.append(contentsOf: wallet.cards.map { KeychainStore.Key.sessionKey(for: $0.tokenId) })
        for key in keys {
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

    // MARK: - Terminal

    /// Simulates the customer tapping the phone on a terminal.
    ///
    /// The terminal produces the amount; the app must show it and sign it
    /// as-is.
    func simulateTerminalTap() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let request = terminal.nextRequest()
        pendingRequest = request
        amountMinor = request.amountMinor
        currency = request.currency
        appendLog("Терминал запросил оплату: \(request.amountWithCurrency)")
    }

    /// Cancels the pending terminal request.
    func cancelTerminalRequest() {
        pendingRequest = nil
        appendLog("Запрос терминала отменён")
    }

    // MARK: - Wallet

    /// Saves the provisioned card into the wallet.
    private func saveToWallet(tokenId: String,
                              dpan: String,
                              last4: String,
                              scheme: String,
                              expiry: String) {
        let card = WalletCard(tokenId: tokenId, dpan: dpan, last4: last4,
                              scheme: scheme, expiry: expiry)
        wallet.add(card)
        appendLog("Карта ••••\(last4) сохранена в кошелёк")
    }

    /// Makes a saved card the primary one and loads its session key.
    func selectPrimaryCard(id: String) {
        guard let card = wallet.cards.first(where: { $0.id == id }) else { return }
        wallet.setPrimary(id: id)

        tokenId = card.tokenId
        dpan = card.dpan
        last4 = card.last4
        if let key = try? keychain.data(for: KeychainStore.Key.sessionKey(for: card.tokenId)),
           let key {
            sessionKey = key
            appendLog("Основная карта: ••••\(card.last4)")
        } else {
            sessionKey = nil
            appendLog("Основная карта: ••••\(card.last4), нужна повторная привязка")
        }
    }

    /// Removes a card from the wallet.
    func removeCard(id: String) {
        wallet.remove(id: id)
        try? keychain.remove(KeychainStore.Key.sessionKey(for: id))
        if tokenId == id {
            tokenId = wallet.primaryCard?.tokenId
            dpan = wallet.primaryCard?.dpan
            last4 = wallet.primaryCard?.last4
            sessionKey = nil
        }
        appendLog("Карта удалена из кошелька")
    }

    // MARK: - Biometrics

    /// Asks the user to confirm the payment with Face ID or Touch ID.
    private func confirmBiometrically(amount: String) async throws {
        let method = BiometricAuthenticator.availableMethod()
        let reason = "Оплата \(amount)"
        let used = try await authenticator.confirm(reason: reason)
        appendLog("Подтверждение: \(used == .none ? "пароль устройства" : used.rawValue)")
    }

    // MARK: - Flow

    /// Runs a complete transaction.
    func runTransaction() async {
        guard !isBusy else { return }
        isBusy = true
        journal.removeAll()
        stage = .checking
        defer { isBusy = false }

        // The terminal owns the amount. Without a terminal request there is
        // nothing to authorise, so the transaction is refused rather than
        // signed against a number the user typed.
        guard let request = pendingRequest else {
            stage = .failed
            appendLog("Нет запроса от терминала — сумма должна приходить от него")
            return
        }

        // The amount is taken from the terminal and cannot be edited.
        amountMinor = request.amountMinor
        currency = request.currency

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
            try? keychain.set(key, for: KeychainStore.Key.sessionKey(for: provisioning.tokenId))
            try? keychain.setString(provisioning.tokenId, for: KeychainStore.Key.tokenId)
            try? keychain.setString(provisioning.dpan, for: KeychainStore.Key.dpan)
            try? keychain.setString(String(provisioning.atc), for: KeychainStore.Key.atc)
            try? keychain.setString(String(provisioning.keysExpireAt), for: KeychainStore.Key.keysExpireAt)
            appendLog("Токен выпущен: \(provisioning.tokenId), DPAN \(provisioning.dpan)")
            appendLog("Ключи действительны \(keysRemainingDescription)")

            // 3. Confirm with Face ID / Touch ID before signing anything.
            stage = .confirming
            try await confirmBiometrically(amount: request.amountWithCurrency)

            // 4. Authorize
            stage = .authorizing
            atc += 1
            try? keychain.setString(String(atc), for: KeychainStore.Key.atc)
            let un = request.unpredictableNumber
            let arqc = EmvCrypto.computeARQC(
                sessionKey: key,
                atc: atc,
                amountMinor: request.amountMinor,
                currency: request.currency,
                unpredictableNumber: un,
                tvr: request.tvr,
                transactionType: request.transactionType)

            let verification = try await tsp.verifyCryptogram(
                tokenId: provisioning.tokenId,
                atc: atc,
                amountMinor: request.amountMinor,
                currency: request.currency,
                unpredictableNumber: un,
                tvr: request.tvr,
                transactionType: request.transactionType,
                arqc: arqc)

            if verification.approved {
                stage = .approved
                pendingRequest = nil
                appendLog("Криптограмма принята. ATC=\(atc), ARQC=\(arqc.hexString)")
                saveToWallet(tokenId: provisioning.tokenId,
                             dpan: provisioning.dpan,
                             last4: check.last4 ?? "",
                             scheme: check.scheme ?? "unknown",
                             expiry: expiry)
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
