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
    case deviceUnsupported
    case entitlementMissing
    case notEligible
    case simulator

    var title: String {
        switch self {
        case .ready: return "HCE доступен"
        case .deviceUnsupported: return "Устройство не поддерживает NFC"
        case .entitlementMissing: return "Нет энтитлмента com.apple.developer.nfc.hce"
        case .notEligible: return "Не выполняются условия ЕЭЗ"
        case .simulator: return "Симулятор: NFC недоступен"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            return "CardSession доступен, можно эмулировать карту."
        case .deviceUnsupported:
            return "NFCReaderSession.readingAvailable == false. Нужен iPhone XS или новее."
        case .entitlementMissing:
            return "Apple выдаёт этот энтитлмент только организациям из ЕЭЗ с лицензией на платёжные услуги. Sideloadly/AltStore его не дают — профиль не содержит capability, поэтому CardSession.init() завершит приложение fatalError."
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

    @Published private(set) var gate: HceGate = .deviceUnsupported
    @Published private(set) var isEmulating = false
    @Published private(set) var lastLog: [String] = []
    @Published private(set) var lastTerminalResponse: Data?

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
    func evaluateGate() async -> HceGate {
        #if targetEnvironment(simulator)
        gate = .simulator
        #else
        guard NFCReaderSession.readingAvailable else {
            gate = .deviceUnsupported
            return gate
        }
        guard CardSession.isSupported else {
            gate = .deviceUnsupported
            return gate
        }
        // The entitlement check happens inside CardSession.init(); creating a
        // session without it traps. We only reach this branch when the
        // entitlement is genuinely present in the provisioning profile.
        let eligible = await CardSession.isEligible
        gate = eligible ? .ready : .notEligible
        #endif
        return gate
    }

    // MARK: Session lifecycle

    /// Starts card emulation.
    /// Returns false and populates `gate` when Apple blocks the session.
    @discardableResult
    func startEmulation(aids: [String]) async -> Bool {
        await evaluateGate()

        #if targetEnvironment(simulator)
        log("Симулятор: CardSession недоступен")
        return false
        #else
        guard gate == .ready else {
            log("Сессия не запущена: \(gate.title)")
            return false
        }
        do {
            let session = try await CardSession()
            self.session = session
            isEmulating = true
            log("CardSession запущена. AID: \(aids.joined(separator: ", "))")
            eventTask = Task { [weak self] in
                await self?.consume(session: session, aids: aids)
            }
            return true
        } catch {
            // An entitlement-less build lands here (or traps before it).
            gate = .entitlementMissing
            log("CardSession недоступна: \(error.localizedDescription)")
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
        log("Эмуляция остановлена")
    }

    private func consume(session: CardSession, aids: [String]) async {
        do {
            for try await event in session.eventStream {
                switch event {
                case .sessionStarted:
                    log("Сессия активна, ресурс NFC получен")

                case .readerDetected:
                    log("Обнаружен считыватель")
                    try? await session.startEmulation()

                case .received(let apdu):
                    let response = handle(apdu: apdu.payload, aids: aids)
                    lastTerminalResponse = response
                    log("APDU \(apdu.payload.hexString) -> \(response.hexString)")
                    do {
                        try await apdu.respond(response: response)
                    } catch {
                        log("Ошибка ответа: \(error.localizedDescription)")
                    }

                case .readerDeselected:
                    log("Считыватель отключён")
                    await session.stopEmulation(status: .success)

                case .sessionInvalidated(let reason):
                    log("Сессия инвалидирована: \(reason)")
                    isEmulating = false
                }
            }
        } catch {
            log("Поток событий прерван: \(error.localizedDescription)")
            isEmulating = false
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
        let p2 = apdu[3]
        let payload = apdu.count > 4 ? apdu[5...(apdu.count - 1)] : Data()

        // SELECT (00 A4 04 00 Lc <AID>)
        if cla == 0x00 && ins == 0xA4 && p1 == 0x04 {
            let requested = payload.hexString.uppercased()
            let match = aids.first { requested.hasPrefix($0) }
            guard let aid = match else { return status(Self.swFileNotFound) }
            // Minimal FCI: 6F 06 84 <len> <AID>
            let aidBytes = Data(hexString: aid) ?? Data()
            var body = Data([0x84, aidBytes.count]) + aidBytes
            var fci = Data([0x6F, body.count]) + body
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
        Data([UInt8(sw >> 8), UInt8(sw & 0xFF)])
    }

    private func log(_ message: String) {
        lastLog.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
        if lastLog.count > 200 { lastLog.removeFirst(lastLog.count - 200) }
    }
}
