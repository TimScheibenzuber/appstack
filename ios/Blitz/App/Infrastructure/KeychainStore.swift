import Foundation
import Security

struct KeychainError: Error, LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        switch status {
        case errSecInteractionNotAllowed:
            return "Der Schlüsselbund ist gesperrt. Entsperre das Gerät und versuche es erneut."
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unbekannter Fehler"
            return "Schlüsselbund-Fehler \(status): \(message)"
        }
    }
}

/// Stores one secret as a generic password item.
///
/// `WhenUnlockedThisDeviceOnly`: the key is only readable while the device is unlocked, is
/// never synced to iCloud Keychain and is excluded from backups/device migration.
struct KeychainStore: Sendable {
    let service: String
    let account: String

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var query = baseQuery
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// Keeps the key in memory after the first Keychain read so requests (and retries while the
/// device is locked in the background) never block on the Keychain.
actor APIKeyVault {
    private let keychain: KeychainStore
    private var cached: String?
    private var isLoaded = false

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func key() throws -> String? {
        if !isLoaded {
            cached = try keychain.read()
            isLoaded = true
        }
        return cached
    }

    func store(_ key: String) throws {
        try keychain.write(key)
        cached = key
        isLoaded = true
    }

    func remove() throws {
        try keychain.delete()
        cached = nil
        isLoaded = true
    }
}
