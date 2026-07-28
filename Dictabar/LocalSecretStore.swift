import Foundation

/// Stores provider API keys in a private local file so development builds never
/// trigger Keychain authorization dialogs.
enum LocalSecretStore {
    enum StoreError: LocalizedError {
        case encoding
        case writing(String)
        case verification

        var errorDescription: String? {
            switch self {
            case .encoding:
                "Could not encode API keys."
            case let .writing(message):
                "Could not save API keys locally: \(message)"
            case .verification:
                "Local storage did not return the API key after saving it."
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    static func save(_ value: String, provider: SpeechProvider) throws {
        lock.lock()
        defer { lock.unlock() }

        var values = loadUnlocked()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.removeValue(forKey: provider.rawValue)
        } else {
            values[provider.rawValue] = trimmed
        }
        try persistUnlocked(values)
        cache = nil
        guard loadUnlocked() == values else {
            cache = values
            throw StoreError.verification
        }
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
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static var directoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictabar", isDirectory: true)
    }

    private static var fileURL: URL {
        directoryURL.appendingPathComponent("secrets.json")
    }

    private static func loadUnlocked() -> [String: String] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = values
        return values
    }

    private static func persistUnlocked(_ values: [String: String]) throws {
        if values.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else {
            throw StoreError.encoding
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw StoreError.writing(error.localizedDescription)
        }
    }
}
