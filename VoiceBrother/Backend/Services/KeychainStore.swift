import Darwin
import Foundation
import LocalAuthentication
import Security

/// Compatibility wrapper for API-key persistence.
///
/// This used to store secrets in the login keychain, but legacy keychain ACLs
/// bind access to the creating binary's cdhash. Release rebuilds therefore
/// triggered a password prompt even though the app's designated requirement
/// stayed stable. We now use a per-user credentials file with 0600 permissions;
/// this matches the accepted "any local process running as this user can read"
/// trade-off without cdhash-dependent ACL behavior.
enum KeychainStore {
    private static let service = "com.voicebrother.app"
    private static let lock = NSLock()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private static let credentialsURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("VoiceBrother", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }()

    /// Upsert a secret. Empty values delete the entry so we never store
    /// zero-length passwords that look like "configured but broken".
    static func set(_ value: String, for account: String) {
        lock.lock()
        defer { lock.unlock() }

        var credentials = loadCredentials()
        if value.isEmpty {
            credentials.removeValue(forKey: account)
        } else {
            credentials[account] = value
        }

        do {
            try writeCredentials(credentials)
            purgeLegacyKeychainCopies(account: account)
        } catch {
            DebugLog.write("[KeychainStore] credentials file write failed for \(account): \(error)")
        }
    }

    static func get(_ account: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        var credentials = loadCredentials()
        if let value = credentials[account] {
            return value
        }

        guard let migrated = readLegacyKeychainItemWithoutPrompt(account: account) else {
            return ""
        }

        credentials[account] = migrated
        do {
            try writeCredentials(credentials)
            purgeLegacyKeychainCopies(account: account)
        } catch {
            DebugLog.write("[KeychainStore] legacy migration write failed for \(account): \(error)")
        }
        return migrated
    }

    // MARK: - File backend

    private static func loadCredentials() -> [String: String] {
        let url = credentialsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            try enforceOwnerOnlyPermissions(at: url)
            let data = try Data(contentsOf: url)
            return try decoder.decode([String: String].self, from: data)
        } catch {
            DebugLog.write("[KeychainStore] credentials file read failed: \(error)")
            return [:]
        }
    }

    private static func writeCredentials(_ credentials: [String: String]) throws {
        let url = credentialsURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try enforceDirectoryPermissions(at: dir)

        let data = try encoder.encode(credentials)
        let tmpURL = dir.appendingPathComponent(".credentials.json.tmp")
        try? FileManager.default.removeItem(at: tmpURL)

        try data.withUnsafeBytes { rawBuffer in
            let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL | O_TRUNC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var shouldClose = true
            defer {
                if shouldClose {
                    close(fd)
                }
            }

            let baseAddress = rawBuffer.baseAddress ?? UnsafeRawPointer(bitPattern: 0x1)!
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
                guard result > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += result
            }
            guard fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard close(fd) == 0 else {
                shouldClose = false
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            shouldClose = false
        }

        guard rename(tmpURL.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }
        try enforceOwnerOnlyPermissions(at: url)
    }

    private static func enforceDirectoryPermissions(at url: URL) throws {
        try enforcePermissions(at: url, mode: S_IRWXU)
    }

    private static func enforceOwnerOnlyPermissions(at url: URL) throws {
        try enforcePermissions(at: url, mode: S_IRUSR | S_IWUSR)
    }

    private static func enforcePermissions(at url: URL, mode: mode_t) throws {
        guard chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // MARK: - One-time legacy keychain migration

    /// Read old login-keychain entries only if macOS can do so without UI.
    /// This avoids reintroducing the rebuild password prompt during migration.
    private static func readLegacyKeychainItemWithoutPrompt(account: String) -> String? {
        for useDataProtection in [nil, false] as [Bool?] {
            let context = LAContext()
            context.interactionNotAllowed = true

            var query = legacyKeychainQuery(account: account, useDataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            query[kSecUseAuthenticationContext as String] = context

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess,
               let data = result as? Data,
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                DebugLog.write("[KeychainStore] migrated legacy keychain item for \(account) to credentials file")
                return value
            }

            if status != errSecItemNotFound && status != errSecInteractionNotAllowed {
                DebugLog.write("[KeychainStore] legacy keychain read skipped for \(account): OSStatus \(status)")
            }
        }
        return nil
    }

    private static func purgeLegacyKeychainCopies(account: String) {
        SecItemDelete(legacyKeychainQuery(account: account, useDataProtection: nil) as CFDictionary)
        SecItemDelete(legacyKeychainQuery(account: account, useDataProtection: false) as CFDictionary)
        SecItemDelete(legacyKeychainQuery(account: account, useDataProtection: true) as CFDictionary)
    }

    private static func legacyKeychainQuery(account: String, useDataProtection: Bool?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = useDataProtection
        }
        return query
    }
}
