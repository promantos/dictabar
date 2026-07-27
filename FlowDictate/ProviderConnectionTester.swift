import Foundation

/// Sends a tiny silent WAV to the selected provider so users can verify key + model.
enum ProviderConnectionTester {
    /// ~0.35s mono 16 kHz 16-bit LE silence (matches FlowDictate recorder format).
    static func run(settings: ProviderSettings, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.missingAPIKey
        }
        let url = try writeSilentWAV(durationSeconds: 0.35)
        defer { try? FileManager.default.removeItem(at: url) }

        let provider = ProviderRegistry.provider(for: settings.provider)
        let result: TranscriptionResult
        do {
            result = try await withTimeout(seconds: 45) {
                try await provider.transcribe(audioURL: url, settings: settings, apiKey: apiKey)
            }
        } catch ProviderError.noTranscript {
            // Authentication, upload and model selection all succeeded; silence is
            // expected to have no transcript and therefore proves connectivity.
            return L10n.t("prov.testEmptyOK")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return L10n.t("prov.testEmptyOK")
        }
        return text
    }

    private static func writeSilentWAV(durationSeconds: Double) throws -> URL {
        let sampleRate = 16_000
        let channels = 1
        let bitsPerSample = 16
        let frameCount = max(1, Int(durationSeconds * Double(sampleRate)))
        let dataSize = frameCount * channels * bitsPerSample / 8
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32(16) // PCM chunk size
        appendUInt16(1) // PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * bitsPerSample / 8))
        appendUInt16(UInt16(channels * bitsPerSample / 8))
        appendUInt16(UInt16(bitsPerSample))
        data.append(contentsOf: "data".utf8)
        appendUInt32(UInt32(dataSize))
        data.append(Data(count: dataSize))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowDictate-test-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProviderError.http(408, "Connection test timed out after \(Int(seconds))s.")
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}
