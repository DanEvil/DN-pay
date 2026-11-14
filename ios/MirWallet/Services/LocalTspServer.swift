//
//  LocalTspServer.swift
//  MirWallet
//
//  Serves the Mock TSP over HTTP on 127.0.0.1, inside the app.
//
//  Why this exists: the mock TSP used to run on a laptop and the iPhone
//  reached it over the Wi-Fi. That made the app unusable away from the desk,
//  and on iOS it cannot be replaced by running Python in a-Shell or iSH —
//  those get suspended the moment you switch to another app, so the server
//  dies exactly when you want to use it.
//
//  With the server embedded, the whole protocol stack (check-card ->
//  link-and-provision -> ARQC -> verify-cryptogram) runs on the phone with
//  no companion machine, no network and no background process.
//
//  The listener is bound to the loopback interface only, so nothing outside
//  the device can reach it.
//

import Foundation
import Network

final class LocalTspServer {

    // MARK: - Types

    struct Request {
        let method: String
        let path: String
        let body: [String: Any]
    }

    enum ServerError: LocalizedError {
        case alreadyRunning
        case bindFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "Встроенный TSP уже запущен"
            case .bindFailed(let reason):
                return "Не удалось занять порт: \(reason)"
            }
        }
    }

    // MARK: - State

    static let scheme = "MOCK-MIR-1"
    static let defaultPort: UInt16 = 8787

    private let core: MockTspCore
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.dnpay.mirwallet.tsp", qos: .utility)

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var isRunning = false

    init(core: MockTspCore, port: UInt16 = LocalTspServer.defaultPort) {
        self.core = core
        self.port = port
    }

    var baseURL: URL {
        // Loopback only: the server is not reachable from the local network.
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var running: Bool { isRunning }

    // MARK: - Lifecycle

    func start() throws {
        guard listener == nil else { throw ServerError.alreadyRunning }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to loopback only.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed(let error):
                self?.isRunning = false
                self?.listener = nil
                print("[local-tsp] listener failed: \(error.localizedDescription)")
            case .cancelled:
                self?.isRunning = false
                self?.listener = nil
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        buffers.removeAll()
        isRunning = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        buffers[key] = Data()

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(key) }
            if case .cancelled = state { self?.close(key) }
        }
        connection.start(queue: queue)
        receive(connection, key: key)
    }

    private func receive(_ connection: NWConnection, key: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                var buffer = self.buffers[key] ?? Data()
                buffer.append(data)
                self.buffers[key] = buffer
                self.process(connection, key: key)
            }

            if isComplete || error != nil {
                self.close(key)
                return
            }
            self.receive(connection, key: key)
        }
    }

    /// Parses one HTTP request out of the buffer and answers it.
    private func process(_ connection: NWConnection, key: ObjectIdentifier) {
        guard let buffer = buffers[key] else { return }
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        let headerData = buffer[..<separator.lowerBound]
        let bodyStart = separator.upperBound
        let bodyData = buffer[bodyStart...]

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            close(key)
            return
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            close(key)
            return
        }

        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else {
            close(key)
            return
        }
        let method = requestLine[0].uppercased()
        var path = requestLine[1]
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        // Content-Length tells us how much more body we need.
        var contentLength = 0
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? 0
            }
        }

        guard bodyData.count >= contentLength else { return }

        let bodyBytes = Data(bodyData.prefix(contentLength))
        var body: [String: Any] = [:]
        if !bodyBytes.isEmpty {
            body = (try? JSONSerialization.jsonObject(with: bodyBytes)) as? [String: Any] ?? [:]
        }

        let (status, payload) = core.handle(path: path, method: method, body: body)
        send(connection, key: key, status: status, payload: payload)
    }

    private func send(_ connection: NWConnection,
                      key: ObjectIdentifier,
                      status: Int,
                      payload: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = Self.reasonPhrase(status)
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.close(key)
        })
    }

    private func close(_ key: ObjectIdentifier) {
        connections[key]?.cancel()
        connections[key] = nil
        buffers[key] = nil
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
