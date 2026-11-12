//
//  PaymentCoordinator.swift
//  MirWallet
//
//  Drives the full mock transaction flow:
//      check-card -> link-and-provision -> (build ARQC) -> verify-cryptogram
//
//  Every step goes through the mock TSP, so the whole protocol can be
//  exercised on a physical iPhone with no Apple entitlement and no network
//  beyond the local machine running mock_tsp.py.
//

import Foundation
import UIKit

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
    @Published private(set) var log: [String] = []
    @Published private(set) var tokenId: String?
    @Published private(set) var dpan: String?
    @Published private(set) var last4: String?
    @Published private(set) var atc = 0
    @Published private(set) var keysExpireAt: Date?
    @Published var amountMinor: String = "1990"
    @Published var currency: String = "RUB"
    @Published var pan: String = "2200123456789019"
    @Published var cvv: String = "123"
    @Published var expiry: String = "12/29"

    private let tsp = TspClient.shared
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

    // MARK: - Flow

    /// Runs a complete mock transaction.
    func runTransaction() async {
        log.removeAll()
        stage = .checking

        do {
            // 1. Check card
            let check = try await tsp.checkCard(pan: pan, cvv: cvv, expiry: expiry)
            guard check.approved else {
                stage = .declined
                log("Карта отклонена: \(check.reason ?? "unknown")")
                return
            }
            last4 = check.last4
            log("Карта проверена: \(check.scheme ?? "?") ***\(last4 ?? "")")

            // 2. Provision
            stage = .provisioning
            let provisioning = try await tsp.linkAndProvision(pan: pan, deviceUDID: deviceUDID)
            tokenId = provisioning.tokenId
            dpan = provisioning.dpan
            atc = provisioning.atc
            keysExpireAt = Date(timeIntervalSince1970: provisioning.keysExpireAt)
            guard let key = Data(base64Encoded: provisioning.sessionKey) else {
                stage = .failed
                log("Не удалось декодировать session key")
                return
            }
            sessionKey = key
            log("Токен выпущен: \(provisioning.tokenId), DPAN \(provisioning.dpan)")
            log("Ключи действительны \(keysRemainingDescription)")

            // 3. Authorize
            stage = .authorizing
            atc += 1
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
                log("Криптограмма принята. ATC=\(atc), ARQC=\(arqc.hexString)")
            } else {
                stage = .declined
                log("Отклонено: \(verification.reason ?? "unknown")")
                if verification.reconnectRequired == true {
                    log("Требуется переподключение к TSP для обновления ключей")
                }
            }
        } catch {
            stage = .failed
            log("Ошибка: \(error.localizedDescription)")
        }
    }

    /// Proves the anti-replay property: replays the last ATC and expects a decline.
    func runReplayAttack() async {
        guard let tokenId, let key = sessionKey else {
            log("Сначала выполните обычную транзакцию")
            return
        }
        log("--- попытка replay того же ATC ---")
        let un = EmvCrypto.randomBytes(count: 8)
        let arqc = EmvCrypto.computeARQC(
            sessionKey: key, atc: atc, amountMinor: amountMinor, currency: currency,
            unpredictableNumber: un, tvr: "0000000000", transactionType: "00")
        do {
            let result = try await tsp.verifyCryptogram(
                tokenId: tokenId, atc: atc, amountMinor: amountMinor, currency: currency,
                unpredictableNumber: un, tvr: "0000000000", transactionType: "00", arqc: arqc)
            log(result.approved ? "ОШИБКА: replay принят" : "Replay отклонён: \(result.reason ?? "")")
        } catch {
            log("Ошибка: \(error.localizedDescription)")
        }
    }

    /// Proves the amount-binding property: signs for one amount, claims another.
    func runTamperTest() async {
        guard let tokenId, let key = sessionKey else {
            log("Сначала выполните обычную транзакцию")
            return
        }
        log("--- подмена суммы после подписи ---")
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
            log(result.approved ? "ОШИБКА: подмена принята" : "Подмена отклонена: \(result.reason ?? "")")
        } catch {
            log("Ошибка: \(error.localizedDescription)")
        }
    }

    func appendLog(_ message: String) {
        log.append(message)
    }
}
