//
//  CardSessionController.swift
//  MirWallet
//
//  Host Card Emulation controller using CoreNFC's CardSession (iOS 17.4+).
//
//  READ THIS BEFORE BUILDING
//  -------------------------
//  CardSession requires the entitlement `com.apple.developer.nfc.hce`, which
//  Apple grants only to applicants established in the EEA with a payments
//  licence. On top of that, `CardSession.isEligible` returns false unless the
//  device is signed into an EEA-based Apple Account AND the device is
//  physically inside the EEA. Apple states plainly: "Using a VPN or other
//  location spoofing techniques will not work. This is a hard requirement."
//
//  Sideloading this IPA through Sideloadly or AltStore does NOT grant the
//  entitlement. A free provisioning profile simply does not contain it, so
//  `CardSession.init()` raises fatalError and the app dies on launch.
//
//  The code below is therefore structured to:
//    1. report exactly which gate is blocking (entitlement vs eligibility),
//    2. keep the provisioning + cryptogram + verification flow fully working
//       against the mock TSP, so the protocol layer is testable on device
//       without any Apple grant,
//    3. activate the HCE path the moment a genuine entitlement is present.
//

import Foundation
import CoreNFC
import UIKit

// MARK: - Gate reporting

enum HceGate: String {
    case ready
    case hardwareMissing
    case entitlementMissing
    case notEligible
    case simulator

    var title: String {
        switch self {
        case .ready: return "HCE доступен"
        case .hardwareMissing: return "В этом устройстве нет NFC-модуля"
        case .entitlementMissing: return "Нет прав на HCE (энтитлмент Apple)"
        case .notEligible: return "Не выполняются условия ЕЭЗ"
        case .simulator: return "Симулятор: NFC недоступен"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "CardSession доступен, можно эмулировать карту."
        case .hardwareMissing:
            return "В этом iPhone нет NFC-модуля. Первый iPhone с NFC — XS."
        case .entitlementMissing:
            return "NFC-модуль в устройстве есть, но приложение не имеет права им пользоваться: в профиле подписи нет энтитлмента com.apple.developer.nfc.hce. Apple выдаёт его только организациям из ЕЭЗ с лицензией на платёжные услуги, поэтому Sideloadly и AltStore его не дают — бесплатный профиль просто не содержит capability. Без него CardSession.init() завершит приложение fatalError."
        case .notEligible:
            return "Требуется Apple ID из ЕЭЗ и физическое нахождение устройства в ЕЭЗ. VPN и подмена геолокации не помогают."
        case .simulator:
            return "Симулятор не эмулирует NFC. Проверяйте на физическом iPhone."
        }
    }
}

// MARK: - Controller

@MainActor
final class CardSessionController: NSObject, ObservableObject {

    @Published private(set) var gate: HceGate = .hardwareMissing
    @Published private(set) var isEmulating = false
    @Published private(set) var log: [String] = []
    @Published private(set) var lastTerminalResponse: Data?

    /// Raw NFC facts, shown in the NFC tab so the verdict is verifiable.
    @Published private(set) var capabilities: NfcCapabilities.Snapshot = NfcCapabilities.Snapshot()

    /// Emulator status words per ISO 7816-4.
    private static let swSuccess: UInt16 = 0x9000
    private static let swFileNotFound: UInt16 = 0x6A82
    private static let swWrongLength: UInt16 = 0x6700

    /// Mir application identifiers.
    static let mirCreditAID = "A0000006581010"
    static let mirDebitAID = "A0000006582010"

    private var session: CardSession?
    private var eventTask: Task<Void, Never>?

    // MARK: Gate evaluation

    /// Determines which Apple gate blocks HCE, if any.
    /// Must be called before any attempt to create a CardSession.
    ///
    /// The order matters. `NFCReaderSession.readingAvailable` and
    /// `CardSession.isSupported` both report false when the app lacks the NFC
    /// entitlements, so they cannot be used to decide that the hardware is
    /// missing NFC. The hardware verdict comes from the model identifier and
    /// the permission verdict from the entitlements in the signed profile.
    func evaluateGate() async -> HceGate {
        #if targetEnvironment(simulator)
        gate = .simulator
        #else
        capabilities = NfcCapabilities.snapshot()

        // 1. Hardware first: no point checking permissions on a phone
        //    without an NFC radio.
        if capabilities.hardware == .absent {
            gate = .hardwareMissing
            return gate
        }

        // 2. Does the signed profile actually grant card emulation?
        if capabilities.profileFound {
            if !capabilities.hasHCE {
                gate = .entitlementMissing
                return gate
            }
        } else if capabilities.cardSessionSupported == false {
            // No embedded profile to inspect — fall back to CoreNFC's own
            // answer, but report it as a permission problem rather than
            // claiming the hardware is at fault.
            gate = .entitlementMissing
            return gate
        }

        // 3. The entitlement is present; the remaining question is whether
        //    the current Apple Account and location allow card sessions.
        let eligible = await CardSession.isEligible
        capabilities.cardSessionEligible = eligible
        gate = eligible ? .ready : .notEligible
        #endif
        return gate
    }

    // MARK: Background operation

    /// Whether the app should keep a card session open without the user
    /// opening it.
    ///
    /// This is what Apple calls a default contactless app: the system routes
    /// a terminal tap straight to the app, so the customer never has to
    /// launch it. It needs the entitlement
    /// `com.apple.developer.nfc.hce.default-contactless-app`, which Apple
    /// grants only to EEA-established applicants with a payments licence —
    /// so this stays off on a free provisioning profile.
    @Published private(set) var backgroundModeEnabled = false

    /// Brings the session up in the background, without any user interaction.
    ///
    /// Returns false when the entitlement is missing or the session cannot
    /// be created.
    @discardableResult
    func startBackgroundEmulation(aids: [String]) async -> Bool {
        guard capabilities.hasDefaultContactlessApp else {
            backgroundModeEnabled = false
            return false
        }
        let started = await startEmulation(aids: aids)
        backgroundModeEnabled = started
        if started {
            appendLog("Фоновый режим: сессия открыта, терминал найдёт приложение сам")
        }
        return started
    }

    // MARK: Session lifecycle

    /// Starts card emulation.
    /// Returns false and populates `gate` when Apple blocks the session.
    @discardableResult
    func startEmulation(aids: [String]) async -> Bool {
        _ = await evaluateGate()

        #if targetEnvironment(simulator)
        appendLog("Симулятор: CardSession недоступен")
        return false
        #else
        guard gate == .ready else {
            appendLog("Сессия не запущена: \(gate.title)")
            return false
        }
        do {
            let session = try await CardSession()
            self.session = session
            isEmulating = true
            appendLog("CardSession запущена. AID: \(aids.joined(separator: ", "))")
            eventTask = Task { [weak self] in
                await self?.consume(session: session, aids: aids)
            }
            return true
        } catch {
            // An entitlement-less build lands here (or traps before it).
            gate = .entitlementMissing
            appendLog("CardSession недоступна: \(error.localizedDescription)")
            return false
        }
        #endif
    }

    func stopEmulation() {
        eventTask?.cancel()
        eventTask = nil
        session?.invalidate()
        session = nil
        isEmulating = false
        appendLog("Эмуляция остановлена")
    }

    private func consume(session: CardSession, aids: [String]) async {
        do {
            for try await event in session.eventStream {
                switch event {
                case .sessionStarted:
                    appendLog("Сессия активна, ресурс NFC получен")

                case .readerDetected:
                    appendLog("Обнаружен считыватель")
                    try? await session.startEmulation()

                case .received(let apdu):
                    let response = handle(apdu: apdu.payload, aids: aids)
                    lastTerminalResponse = response
                    appendLog("APDU \(apdu.payload.hexString) -> \(response.hexString)")
                    do {
                        try await apdu.respond(response: response)
                    } catch {
                        appendLog("Ошибка ответа: \(error.localizedDescription)")
                    }

                case .readerDeselected:
                    appendLog("Считыватель отключён")
                    await session.stopEmulation(status: .success)

                case .sessionInvalidated(let reason):
                    appendLog("Сессия инвалидирована: \(reason)")
                    isEmulating = false

                @unknown default:
                    appendLog("Неизвестное событие сессии")
                }
            }
        } catch {
            appendLog("Поток событий прерван: \(error.localizedDescription)")
            isEmulating = false
        }
    }

    // MARK: - Terminal data

    /// Pulls the amount and currency out of the terminal's EMV tags.
    ///
    /// Tag 9F02 is the amount in minor units and 9F53 is the currency code.
    /// Both are BER-TLV encoded, so the value is read from the tag list the
    /// terminal sends.
    static func parseTerminalAmount(from data: Data) -> (amountMinor: String, currency: String)? {
        let tags: [String: String] = [
            "9F02": "amount",
            "9F53": "currency",
        ]

        var amount: String?
        var currency: String?

        var offset = 0
        while offset + 2 <= data.count {
            // EMV tags are 1, 2 or 3 bytes long.
            let tagLength = Self.tagLength(in: data, at: offset)
            guard tagLength > 0, offset + tagLength < data.count else { break }

            let tag = String(data[offset..<(offset + tagLength)].hexString.uppercased())
            let lengthOffset = offset + tagLength
            let lengthByte = data[lengthOffset]
            var valueStart = lengthOffset + 1
            var length = Int(lengthByte)

            if lengthByte & 0x80 != 0 {
                // Long form: the low nibble says how many length bytes follow.
                let lengthBytes = Int(lengthByte & 0x0F)
                guard lengthOffset + 1 + lengthBytes <= data.count else { break }
                var value = 0
                for i in 0..<lengthBytes {
                    value = (value << 8) | Int(data[lengthOffset + 1 + i])
                }
                length = value
                valueStart = lengthOffset + 1 + lengthBytes
            }

            guard valueStart + length <= data.count else { break }

            if tags[tag] == "amount" {
                amount = data[valueStart..<valueStart + length].hexString.uppercased()
            } else if tags[tag] == "currency" {
                // Currency is ISO 4217 numeric: 0643 for RUB.
                let numeric = data[valueStart..<valueStart + length].hexString.uppercased()
                currency = Self.currencyCode(for: numeric)
            }

            offset = valueStart + length
        }

        guard let amount, let currency else { return nil }
        return (amount, currency)
    }

    /// Length of the BER-TLV tag starting at the given offset: 1, 2 or 3
    /// bytes. Returns 0 when the data is too short to tell.
    static func tagLength(in data: Data, at offset: Int) -> Int {
        guard offset < data.count else { return 0 }
        let first = data[offset]
        // Low five bits all set means the tag continues in the next byte.
        guard first & 0x1F == 0x1F else { return 1 }
        guard offset + 1 < data.count else { return 0 }
        // High bit set in the second byte means a third byte follows.
        return data[offset + 1] & 0x80 == 0 ? 2 : 3
    }

    /// Maps an ISO 4217 numeric code onto the letters the TSP expects.
    static func currencyCode(for numeric: String) -> String {
        switch numeric {
        case "0643": return "RUB"
        case "0840": return "USD"
        case "0978": return "EUR"
        case "0756": return "CHF"
        case "0384": return "XCD"
        default: return numeric
        }
    }

    // MARK: - Minimal ISO 7816 handling

    /// Handles a raw command APDU and returns a response APDU.
    /// This is intentionally minimal: it proves the transport works and that
    /// the terminal can SELECT the Mir AIDs. Real EMV transaction processing
    /// (GPO, CDOL1, GENERATE AC) is the next layer on top.
    private func handle(apdu: Data, aids: [String]) -> Data {
        guard apdu.count >= 4 else {
            return status(Self.swWrongLength)
        }
        let cla = apdu[0]
        let ins = apdu[1]
        let p1 = apdu[2]
        let payload = apdu.count > 4 ? apdu[5...(apdu.count - 1)] : Data()

        // SELECT (00 A4 04 00 Lc <AID>)
        if cla == 0x00 && ins == 0xA4 && p1 == 0x04 {
            let requested = payload.hexString.uppercased()
            guard let aid = aids.first(where: { requested.hasPrefix($0) }) else {
                return status(Self.swFileNotFound)
            }
            let aidBytes = Data(hexString: aid) ?? Data()
            let body = Data([0x84, UInt8(aidBytes.count)]) + aidBytes
            var fci = Data([0x6F, UInt8(body.count)]) + body
            fci.append(contentsOf: status(Self.swSuccess))
            return fci
        }

        // GET PROCESSING OPTIONS (80 A8 00 00 04)
        if cla == 0x80 && ins == 0xA8 {
            return Data([0x83, 0x00]) + status(Self.swSuccess)
        }

        // Anything else: file not found / instruction not supported.
        return status(Self.swFileNotFound)
    }

    private func status(_ sw: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: sw >> 8), UInt8(truncatingIfNeeded: sw & 0xFF)])
    }

    private func appendLog(_ message: String) {
        log.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
