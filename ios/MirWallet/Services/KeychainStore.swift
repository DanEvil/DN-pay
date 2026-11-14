//
//  KeychainStore.swift
//  MirWallet
//
//  Keychain-backed storage for the session key and the provisioning state.
//  The session key never touches UserDefaults or the file system.
//

import Foundation
import Security

struct KeychainStore {

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case notFound

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain: \(message) (\(status))"
            case .notFound:
                return "Keychain: запись не найдена"
            }
        }
    }

    private let service: String

    init(service: String = "com.dnpay.mirwallet") {
        self.service = service
    }

    // MARK: - Data

    func set(_ data: Data, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func data(for key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return item as? Data
    }

    func setString(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    func string(for key: String) throws -> String? {
        guard let data = try data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Named keys

    enum Key {
        static let masterKey = "tsp.masterKey"
        static let sessionKey = "tsp.sessionKey"
        static let tokenId = "tsp.tokenId"
        static let dpan = "tsp.dpan"
        static let atc = "tsp.atc"
        static let keysExpireAt = "tsp.keysExpireAt"
        static let last4 = "card.last4"
    }
}
