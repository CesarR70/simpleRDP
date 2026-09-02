//
// KeychainHelper.swift — minimal wrapper over Security.framework for storing
// RDP passwords keyed by host+username.
//
// Design notes (from RDP-Swift-Client-Plan.md §10):
//   - Favorites store host/username/label only.
//   - Passwords live in the Keychain; we fetch them at connect time.
//   - The system handles auth prompts where required (kSecAttrAccessible
//     afterFirstUnlock keeps the entry available for our unsandboxed CLI-style
//     invocation without forcing an interactive prompt every time).
//
// We deliberately do NOT touch Keychain Sharing, iCloud sync, or access groups
// — they're out of scope for the local-dev v1.
//

import Foundation
import Security

enum KeychainError: Error {
    case unhandled(OSStatus)
    case noPassword
}

struct KeychainHelper {
    /// Service identifier used as kSecAttrService for all our entries.
    static let service = "com.example.simpleRDP.password"

    /// Save (or replace) a password for the given host+username.
    static func savePassword(_ password: String, host: String, username: String) throws {
        let account = accountName(host: host, username: username)
        guard let data = password.data(using: .utf8) else { return }

        // Try update first; fall back to add if it doesn't exist.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unhandled(status)
        }
    }

    /// Read the password for host+username. Returns nil if not stored.
    static func loadPassword(host: String, username: String) throws -> String? {
        let account = accountName(host: host, username: username)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = item as? Data, let pw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pw
    }

    /// Delete the password for host+username. No-op if not present.
    static func deletePassword(host: String, username: String) throws {
        let account = accountName(host: host, username: username)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Composes a stable account key from host+username so multiple users against
    /// the same host don't collide, and the same user against different hosts
    /// doesn't collide either.
    private static func accountName(host: String, username: String) -> String {
        return "\(host)::\(username)"
    }
}