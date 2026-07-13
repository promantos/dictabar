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
        let redacted = Self.redact(message)
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

    /// Strip secrets and truncate noisy payloads so logs never hold keys or clipboard text.
    static func redact(_ message: String) -> String {
        var s = message
        // Bearer / Token auth headers
        s = s.replacingOccurrences(
            of: #"Bearer\s+\S+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"Token\s+\S+"#,
            with: "Token [redacted]",
            options: .regularExpression
        )
        // Common API key header values if ever logged
        s = s.replacingOccurrences(
            of: #"(?i)(x-gladia-key|xi-api-key|ocp-apim-subscription-key|authorization)\s*[:=]\s*\S+"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        // sk-… style keys
        s = s.replacingOccurrences(
            of: #"\bsk-[A-Za-z0-9_\-]{8,}\b"#,
            with: "sk-[redacted]",
            options: .regularExpression
        )
        // Cap total line length (prevents huge provider bodies / log forging newlines)
        let maxLen = 500
        if s.count > maxLen {
            s = String(s.prefix(maxLen)) + "…[truncated]"
        }
        // Collapse newlines that could forge multi-line log entries
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        s = s.replacingOccurrences(of: "\r", with: "\\r")
        return s
    }

    /// Safe snippet of an HTTP error body for UI/logs (no full dump).
    static func safeErrorBody(_ data: Data, limit: Int = 200) -> String {
        let raw = String(decoding: data.prefix(limit * 2), as: UTF8.self)
        let compact = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = compact.count > limit ? String(compact.prefix(limit)) + "…" : compact
        return redact(clipped)
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
