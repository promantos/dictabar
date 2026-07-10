import Foundation
import Security

/// Stores all provider API keys in a **single** Keychain item (JSON blob).
///
/// One item ⇒ at most one Keychain authorization dialog ever (usually none once
/// the app is consistently code-signed with the same Team ID). Keys are cached
/// in memory after the first successful read so transcription never re-hits
/// the Keychain on every keystroke.
enum LocalSecretStore {
    private static let service = "app.flowdictate.FlowDictate"
    private static let account = "api-keys"
    private static let legacyFileName = "secrets.json"

    private static let lock = NSLock()
    // Protected by `lock`.
    nonisolated(unsafe) private static var cache: [String: String]?

    // MARK: - Public API

    static func save(_ value: String, provider: SpeechProvider) {
        lock.lock()
        defer { lock.unlock() }
        var values = loadUnlocked()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.removeValue(forKey: provider.rawValue)
        } else {
            values[provider.rawValue] = trimmed
        }
        cache = values
        persistUnlocked(values)
    }

    static func read(provider: SpeechProvider) -> String {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()[provider.rawValue] ?? ""
    }

    static func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        cache = [:]
        deleteKeychainItem()
        deleteLegacyFile()
    }

    /// Prefetch into memory (call once at launch). Safe if Keychain is empty.
    static func warmCache() {
        lock.lock()
        defer { lock.unlock() }
        _ = loadUnlocked()
    }

    // MARK: - Load / migrate

    private static func loadUnlocked() -> [String: String] {
        if let cache { return cache }

        if let keychain = readKeychain(),
           let decoded = try? JSONDecoder().decode([String: String].self, from: keychain) {
            cache = decoded
            return decoded
        }

        // One-time migration from the old plaintext Application Support file.
        if let legacy = readLegacyFile() {
            cache = legacy
            persistUnlocked(legacy)
            deleteLegacyFile()
            DiagnosticsLogger.shared.log("keychain: migrated legacy secrets.json")
            return legacy
        }

        cache = [:]
        return [:]
    }

    private static func persistUnlocked(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        if values.isEmpty {
            deleteKeychainItem()
            return
        }
        writeKeychain(data)
    }

    // MARK: - Keychain (single item)

    /// Shared query attributes for the one secrets item.
    /// No custom ACL / SecAccessControl → same signed app reads silently.
    private static func baseQuery(includeDataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Prefer data-protection keychain (modern, fewer ACL prompts) when available.
        if includeDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func readKeychain() -> Data? {
        // Try data-protection keychain first, then legacy login keychain.
        for useDP in [true, false] {
            var query = baseQuery(includeDataProtection: useDP)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
            if status != errSecItemNotFound && status != errSecParam {
                DiagnosticsLogger.shared.log("keychain read status=\(status) dp=\(useDP)")
            }
        }
        return nil
    }

    private static func writeKeychain(_ data: Data) {
        // Prefer update of existing item (either store).
        for useDP in [true, false] {
            let base = baseQuery(includeDataProtection: useDP)
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrLabel as String: "FlowDictate API Keys"
            ]
            let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if status == errSecSuccess {
                return
            }
            if status != errSecItemNotFound && status != errSecParam {
                DiagnosticsLogger.shared.log("keychain update status=\(status) dp=\(useDP)")
            }
        }

        // Create new item in data-protection keychain.
        var add = baseQuery(includeDataProtection: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "FlowDictate API Keys"
        add[kSecAttrDescription as String] = "Speech provider API keys for FlowDictate"

        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Race / stale: force update.
            let base = baseQuery(includeDataProtection: true)
            status = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        if status != errSecSuccess {
            // Fallback without data-protection flag (older keychain path).
            var fallback: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrLabel as String: "FlowDictate API Keys"
            ]
            status = SecItemAdd(fallback as CFDictionary, nil)
            if status == errSecDuplicateItem {
                fallback.removeValue(forKey: kSecValueData as String)
                status = SecItemUpdate(
                    fallback as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
            }
        }
        if status != errSecSuccess {
            DiagnosticsLogger.shared.log("keychain add failed: \(status)")
        }
    }

    private static func deleteKeychainItem() {
        for useDP in [true, false] {
            SecItemDelete(baseQuery(includeDataProtection: useDP) as CFDictionary)
        }
        // Also delete any pre-migration plain query without flags.
        let plain: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(plain as CFDictionary)
    }

    // MARK: - Legacy file migration

    private static var legacyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowDictate", isDirectory: true)
        return base.appendingPathComponent(legacyFileName)
    }

    private static func readLegacyFile() -> [String: String]? {
        guard let data = try? Data(contentsOf: legacyFileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              !values.isEmpty else {
            return nil
        }
        return values
    }

    private static func deleteLegacyFile() {
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
