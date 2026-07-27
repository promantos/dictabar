import AppKit
import Foundation

/// Local-only recent transcripts (opt-in via Settings). Never leaves the machine.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    static let shared = TranscriptHistoryStore()

    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        let date: Date
        let text: String
        let provider: String
        let model: String
    }

    @Published private(set) var items: [Item] = []

    private let maxItems = 30
    private let maxTextChars = 8_000
    private let fileURL: URL
    private let persistenceQueue = DispatchQueue(label: "app.flowdictate.transcript-history")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("transcript-history.json")
        load()
    }

    func add(text: String, provider: String, model: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clipped = trimmed.count > maxTextChars
            ? String(trimmed.prefix(maxTextChars)) + "…"
            : trimmed
        let item = Item(
            id: UUID(),
            date: Date(),
            text: clipped,
            provider: provider,
            model: model
        )
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    func copy(_ item: Item) {
        TextInsertionService.copy(item.text)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else {
            items = []
            return
        }
        items = Array(decoded.prefix(maxItems))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let fileURL = fileURL
        persistenceQueue.async {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }
    }
}
