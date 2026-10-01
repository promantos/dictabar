import Foundation

/// Reson8's prerecorded API consumes the recording directly, without multipart upload.
/// https://docs.reson8.dev/api/speech-to-text/prerecorded/
struct Reson8TranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        let request = try Self.request(settings: settings, apiKey: apiKey)
        let json = try await send(request, bodyFile: audioURL)
        return try Self.result(json, settings: settings)
    }

    static func request(settings: ProviderSettings, apiKey: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard var components = URLComponents(string: base + "/speech-to-text/prerecorded") else { throw ProviderError.badURL }
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "auto"),
            URLQueryItem(name: "include_language", value: "true"),
            URLQueryItem(name: "include_timestamps", value: "true")
        ]
        if let language = settings.language.apiCode {
            components.queryItems?.append(URLQueryItem(name: "language", value: language))
        }
        guard let url = components.url else { throw ProviderError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("ApiKey \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func result(_ json: [String: Any], settings: ProviderSettings) throws -> TranscriptionResult {
        guard let text = json["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.noTranscript
        }
        return TranscriptionResult(text: text, detectedLanguage: json["language"] as? String,
                                   duration: (json["duration_ms"] as? Double).map { $0 / 1000 },
                                   providerName: settings.provider.rawValue, modelName: settings.model)
    }
}

/// StepAudio ASR accepts a complete audio file and returns SSE, even for file transcription.
/// https://platform.stepfun.com/docs/zh/api-reference/audio/asr-sse
struct StepFunTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        let request = try Self.request(audioURL: audioURL, settings: settings, apiKey: apiKey)
        let data = try await sendData(request)
        let text = try Self.transcript(from: data)
        return TranscriptionResult(text: text, detectedLanguage: nil, duration: audioDuration(from: audioURL),
                                   providerName: settings.provider.rawValue, modelName: settings.model)
    }

    static func request(audioURL: URL, settings: ProviderSettings, apiKey: String) throws -> URLRequest {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/audio/asr/sse") else { throw ProviderError.badURL }
        let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= settings.provider.maximumUploadBytes else {
            throw ProviderError.unsupported("The recording is too large for StepFun. Use a shorter recording.")
        }
        var transcription: [String: Any] = ["model": settings.model, "enable_itn": true]
        // Omit language in Auto mode instead of pinning the model to Chinese.
        if let language = settings.language.apiCode { transcription["language"] = language }
        let body: [String: Any] = ["audio": [
            "data": try Data(contentsOf: audioURL).base64EncodedString(),
            "input": ["transcription": transcription, "format": ["type": "wav"]]
        ]]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func transcript(from data: Data) throws -> String {
        guard let response = String(data: data, encoding: .utf8) else {
            throw ProviderError.network("StepFun returned an invalid text response")
        }
        // SSE joins multiple data lines in one event with a newline. Delta text is deliberately
        // ignored: a disconnected stream must never insert an incomplete dictated sentence.
        let normalized = response.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var completedText: String?
        for event in normalized.components(separatedBy: "\n\n") {
            let payload = event.components(separatedBy: "\n").compactMap { line -> String? in
                guard line.hasPrefix("data:") else { return nil }
                let value = String(line.dropFirst(5))
                return value.hasPrefix(" ") ? String(value.dropFirst()) : value
            }.joined(separator: "\n")
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let eventData = payload.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                throw ProviderError.network("StepFun returned a malformed transcription event")
            }
            switch json["type"] as? String {
            case "transcript.text.done":
                completedText = json["text"] as? String
            case "error":
                throw ProviderError.unsupported("StepFun: \(json["message"] as? String ?? "Transcription failed")")
            default:
                continue
            }
        }
        guard let text = completedText else { throw ProviderError.network("StepFun closed the stream before completing transcription") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.noTranscript }
        return text
    }
}
