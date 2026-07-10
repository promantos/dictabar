import Foundation

final class DiagnosticsLogger: @unchecked Sendable {
    static let shared = DiagnosticsLogger()

    private let queue = DispatchQueue(label: "app.flowdictate.diagnostics")
    private let url: URL
    private let alsoStdout = true

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowDictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("diagnostics.log")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        // Bootstrap line so the file always exists after first launch.
        log("logger ready path=\(url.path)")
    }

    func log(_ message: String) {
        let redacted = message.replacingOccurrences(
            of: #"Bearer\s+\S+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(redacted)\n"
        if alsoStdout {
            fputs(line, stderr)
        }
        queue.sync {
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: self.url.path),
               let handle = try? FileHandle(forWritingTo: self.url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.url, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: self.url.path
                )
            }
        }
    }

    func exportURL() -> URL { url }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: self.url)
        }
    }

    func readTail(maxBytes: Int = 32_000) -> String {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return "(no log file)" }
            if data.count <= maxBytes {
                return String(decoding: data, as: UTF8.self)
            }
            return String(decoding: data.suffix(maxBytes), as: UTF8.self)
        }
    }
}
