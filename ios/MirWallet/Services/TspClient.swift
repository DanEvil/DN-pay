//
//  TspClient.swift
//  MirWallet
//
//  Client for a Token Service Provider.
//
//  Mirrors the three server-side calls Apple Pay uses against an issuer's TSP
//  (Required Fields / Check Card / Link and Provision) plus an issuer-side
//  cryptogram verification endpoint.
//
//  The default target is the local mock TSP (server/mock_tsp.py). Point it at
//  a real TSP only if your bank actually runs one for Apple Pay — no Russian
//  issuer currently does.
//

import Foundation
import Combine

// MARK: - Wire types

struct ProvisioningResult: Decodable {
    let tokenId: String
    let dpan: String
    let sessionKey: String      // base64
    let atc: Int
    let keysExpireAt: Double
    let scheme: String
}

struct CardCheckResult: Decodable {
    let approved: Bool
    let reason: String?
    let scheme: String?
    let last4: String?
}

struct VerificationResult: Decodable {
    let approved: Bool
    let reason: String?
    let reconnectRequired: Bool?
    let lastAtc: Int?
}

struct ProvisioningError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

final class TspClient: ObservableObject {

    /// Where the mock TSP lives.
    ///
    /// - `embedded`: the server runs inside the app on 127.0.0.1. The phone is
    ///   fully self-contained: no laptop, no network, no background process.
    /// - `external`: the Python `server/mock_tsp.py` on the local network.
    enum Mode: String, CaseIterable, Identifiable {
        case embedded
        case external

        var id: String { rawValue }

        var title: String {
            switch self {
            case .embedded: return "Встроенный (в приложении)"
            case .external: return "Внешний (в сети)"
            }
        }

        var detail: String {
            switch self {
            case .embedded:
                return "Сервер работает внутри приложения на 127.0.0.1:\(LocalTspServer.defaultPort). Телефон работает автономно — компьютер и сеть не нужны."
            case .external:
                return "Python-сервер server/mock_tsp.py на компьютере в той же сети. Требует запущенного процесса и доступности по Wi-Fi."
            }
        }
    }

    static let shared = TspClient()

    /// Base URL of the TSP. Defaults to the mock server on the local network.
    /// Override in the app UI or via UserDefaults key "tsp.baseURL".
    @Published var baseURL: URL

    /// Which TSP the client talks to.
    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "tsp.mode") }
    }

    /// The embedded server, started once and shared.
    private(set) var embeddedServer: LocalTspServer?

    @Published private(set) var embeddedError: String?

    private let session: URLSession

    init(baseURL: URL? = nil) {
        let stored = UserDefaults.standard.string(forKey: "tsp.baseURL")
        let fallback = URL(string: "http://127.0.0.1:8787")!
        self.baseURL = baseURL
            ?? (stored.flatMap { URL(string: $0) } ?? fallback)

        let modeRaw = UserDefaults.standard.string(forKey: "tsp.mode")
        self.mode = Mode(rawValue: modeRaw ?? "embedded") ?? .embedded

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    /// Starts the in-app TSP and points the client at it.
    ///
    /// The master key is persisted in the Keychain so tokens issued by a
    /// previous launch stay verifiable across restarts.
    @discardableResult
    func startEmbeddedServer() -> Bool {
        if let embeddedServer, embeddedServer.running { return true }

        let server = LocalTspServer(core: MockTspCore(masterKey: Self.loadOrCreateMasterKey()))
        do {
            try server.start()
            embeddedServer = server
            embeddedError = nil
            return true
        } catch {
            embeddedError = error.localizedDescription
            return false
        }
    }

    func updateBaseURL(_ string: String) {
        guard let url = URL(string: string), url.scheme != nil else { return }
        baseURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: "tsp.baseURL")
    }

    /// Loads the persisted master key, creating one on first launch.
    ///
    /// The key has to survive relaunches, otherwise session keys derived
    /// from it would stop verifying after the app restarts.
    private static func loadOrCreateMasterKey() -> Data {
        let keychain = KeychainStore()
        if let stored = try? keychain.data(for: KeychainStore.Key.masterKey),
           stored.count == 32 {
            return stored
        }
        let fresh = EmvCrypto.randomBytes(count: 32)
        try? keychain.set(fresh, for: KeychainStore.Key.masterKey)
        return fresh
    }

    /// Switches between the in-app TSP and an external one.
    func setMode(_ newMode: Mode) {
        mode = newMode
        if newMode == .embedded {
            _ = startEmbeddedServer()
        }
    }

    // MARK: Required Fields

    func requiredFields() async throws -> [String] {
        struct Response: Decodable { let fields: [String] }
        let response: Response = try await post("/tsp/required-fields", body: [:])
        return response.fields
    }

    // MARK: Check Card

    func checkCard(pan: String, cvv: String, expiry: String) async throws -> CardCheckResult {
        try await post("/tsp/check-card",
                       body: ["pan": pan, "cvv": cvv, "expiry": expiry])
    }

    // MARK: Link and Provision

    func linkAndProvision(pan: String, deviceUDID: String) async throws -> ProvisioningResult {
        try await post("/tsp/link-and-provision",
                       body: ["pan": pan, "device": ["udid": deviceUDID]])
    }

    // MARK: Verify Cryptogram

    func verifyCryptogram(tokenId: String,
                          atc: Int,
                          amountMinor: String,
                          currency: String,
                          unpredictableNumber: Data,
                          tvr: String,
                          transactionType: String,
                          arqc: Data) async throws -> VerificationResult {
        try await post("/tsp/verify-cryptogram", body: [
            "tokenId": tokenId,
            "atc": atc,
            "amountMinor": amountMinor,
            "currency": currency,
            "un": unpredictableNumber.hexString,
            "tvr": tvr,
            "txnType": transactionType,
            "arqc": arqc.base64EncodedString(),
        ])
    }

    // MARK: - Transport

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProvisioningError(message: "TSP недоступен по адресу \(baseURL.absoluteString): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ProvisioningError(message: "TSP вернул HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ProvisioningError(message: "Некорректный ответ TSP: \(bodyText.prefix(200))")
        }
    }
}
