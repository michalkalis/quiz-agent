//
//  AdminKeyStore.swift
//  Hangs
//
//  Keychain-backed store for the quiz-pack-api admin key (issue #95). The key
//  is NEVER baked into the binary (so it also works in TestFlight) — the founder
//  pastes it once in Settings and it lives here, this-device-only. Mirrors
//  `KeychainTokenStore` (AuthService.swift) but stores a plain UTF-8 string under
//  the `admin_key` account.
//

import Foundation
import os

nonisolated struct AdminKeyStore: Sendable {
    private let service = "\(Bundle.main.bundleIdentifier ?? "com.missinghue.hangs").auth"
    private let account = "admin_key"

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Logger.network.warning("🔐 AdminKey load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func save(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }

        // Upsert: try update first, fall back to add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Logger.network.warning("🔐 AdminKey add failed: OSStatus \(addStatus, privacy: .public)")
            }
        } else if updateStatus != errSecSuccess {
            Logger.network.warning("🔐 AdminKey update failed: OSStatus \(updateStatus, privacy: .public)")
        }
    }

    func clear() {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Logger.network.warning("🔐 AdminKey delete failed: OSStatus \(status, privacy: .public)")
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
