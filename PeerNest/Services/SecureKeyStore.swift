//
//  SecureKeyStore.swift
//  PeerNest
//

import Foundation
import Security

nonisolated protocol SecureKeyStore: Sendable {
    func data(for account: String) throws -> Data?
    func save(_ data: Data, for account: String) throws
    func removeData(for account: String) throws
}

nonisolated enum SecureKeyStoreError: LocalizedError, Equatable, Sendable {
    case keychain(OSStatus)

    var errorDescription: String? {
        "PeerNest could not access its secure device identity in Keychain."
    }
}

nonisolated final class KeychainSecureKeyStore: SecureKeyStore, @unchecked Sendable {
    private let service: String

    init(service: String = "com.mustafayurtoglu.PeerNest.device-identity") {
        self.service = service
    }

    func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecureKeyStoreError.keychain(status) }
        return result as? Data
    }

    func save(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SecureKeyStoreError.keychain(updateStatus) }

        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SecureKeyStoreError.keychain(addStatus) }
    }

    func removeData(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureKeyStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

/// Deterministic, process-only storage for tests. It never touches UserDefaults.
nonisolated final class InMemorySecureKeyStore: SecureKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for account: String) throws -> Data? {
        lock.withLock { values[account] }
    }

    func save(_ data: Data, for account: String) throws {
        lock.withLock { values[account] = data }
    }

    func removeData(for account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

