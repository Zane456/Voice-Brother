import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing API keys.
/// We keep secrets out of UserDefaults (which is world-readable via
/// `defaults read com.voicebubble.app`) so that a user who shares their
/// machine state—screen recordings, Time Machine backups, support exports—
/// doesn't leak them.
enum KeychainStore {
    private static let service = "com.voicebubble.app"

    /// Upsert a secret. Empty values delete the entry so we never store
    /// zero-length passwords that look like "configured but broken".
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }

        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }
}
