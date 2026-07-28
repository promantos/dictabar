import CryptoKit
import Foundation

enum ProviderError: LocalizedError {
    case missingAPIKey
    case badURL
    case unsupported(String)
    case http(Int, String)
    case network(String)
    case timedOut
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an API key in Settings."
        case .badURL: return "Bad provider URL."
        case let .unsupported(message): return message
        case let .http(status, body):
            let lower = body.lowercased()
            if lower.contains("balance") || lower.contains("billing")
                || lower.contains("credit") || lower.contains("quota exceeded") {
                return "The provider reports insufficient balance, credits, or quota."
            }
            if lower.contains("deprecated") || lower.contains("model") && lower.contains("not found") {
                return "The selected provider model is no longer available. Choose a current model in Settings."
            }
            switch status {
            case 401, 403:
                return "The provider rejected the API key. Check that the key belongs to this provider and region."
            case 402:
                return "The provider reports insufficient balance or credits."
            case 408:
                return "The provider timed out. The recording was kept so you can retry."
            case 429:
                return "The provider rate limit or quota was reached. Dictabar retried automatically; try again shortly."
            case 500...599:
                return "The provider is temporarily unavailable (HTTP \(status)). The recording was kept so you can retry."
            default:
                return "Provider error \(status): \(body)"
            }
        case let .network(message):
            return "Network error after automatic retries: \(message). The recording was kept so you can retry."
        case .timedOut:
            return "Transcription timed out after automatic retries. The recording was kept so you can retry."
        case .noTranscript:
            return "No speech was detected in the recording."
        }
    }

    var isRetryable: Bool {
        switch self {
        case let .http(status, _):
            [408, 425, 429, 500, 502, 503, 504].contains(status)
        case .network, .timedOut:
            true
        default:
            false
        }
    }
}

enum ProviderRegistry {
    static func provider(for provider: SpeechProvider) -> TranscriptionProvider {
        switch provider {
        case .local: LocalTranscriptionProvider()
        case .openAI: OpenAITranscriptionProvider()
        case .groq: GroqTranscriptionProvider()
        case .mistral: MistralTranscriptionProvider()
        case .custom: CustomOpenAICompatibleProvider()
        case .deepgram: DeepgramTranscriptionProvider()
        case .soniox: SonioxTranscriptionProvider()
        case .gladia: GladiaTranscriptionProvider()
        case .speechmatics: SpeechmaticsTranscriptionProvider()
        case .elevenLabs: ElevenLabsTranscriptionProvider()
        case .assemblyAI: AssemblyAITranscriptionProvider()
        case .openRouter: OpenRouterTranscriptionProvider()
        case .azureSpeech: AzureSpeechTranscriptionProvider()
        case .googleCloud: GoogleCloudSTTTranscriptionProvider()
        case .fireworks: FireworksTranscriptionProvider()
        case .together: TogetherTranscriptionProvider()
        case .smallestAI: SmallestAITranscriptionProvider()
        case .alibaba: AlibabaTranscriptionProvider()
        case .xAI: XAITranscriptionProvider()
        case .amazonTranscribe: AmazonTranscribeProvider()
        case .inworld: InworldTranscriptionProvider()
        case .cartesia: CartesiaTranscriptionProvider()
        case .gradium: GradiumTranscriptionProvider()
        case .modulate: ModulateTranscriptionProvider()
        case .cohere: CohereTranscriptionProvider()
        case .cloudflare: CloudflareTranscriptionProvider()
        }
    }
}

struct OpenAITranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        try await OpenAICompatibleTranscriptionProvider().transcribe(audioURL: audioURL, settings: settings, apiKey: apiKey)
    }
}

struct GroqTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        try await OpenAICompatibleTranscriptionProvider().transcribe(audioURL: audioURL, settings: settings, apiKey: apiKey)
    }
}

struct MistralTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        try await OpenAICompatibleTranscriptionProvider().transcribe(audioURL: audioURL, settings: settings, apiKey: apiKey)
    }
}

struct CustomOpenAICompatibleProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        try await OpenAICompatibleTranscriptionProvider().transcribe(audioURL: audioURL, settings: settings, apiKey: apiKey)
    }
}

private struct OpenAICompatibleTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/audio/transcriptions") else {
            throw ProviderError.badURL
        }

        let form = try MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.addField("model", settings.model)
        if let language = settings.language.apiCode { try form.addField("language", language) }
        try form.addField("response_format", "json")
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)

        let json = try await send(request, bodyFile: form.fileURL)
        let text = json["text"] as? String
        guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(text: text, detectedLanguage: json["language"] as? String, duration: json["duration"] as? TimeInterval, providerName: settings.provider.rawValue, modelName: settings.model)
    }
}

struct SonioxTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let uploadURL = URL(string: base + "/files") else { throw ProviderError.badURL }

        let form = try MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.close()

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &upload)

        let uploaded = try await send(upload, bodyFile: form.fileURL)
        guard let fileID = uploaded["id"] as? String else { throw ProviderError.noTranscript }
        guard let createURL = URL(string: base + "/transcriptions") else { throw ProviderError.badURL }
        var body: [String: Any] = [
            "model": settings.model,
            "file_id": fileID,
            "enable_language_identification": true
        ]
        if let language = settings.language.apiCode {
            body["language_hints"] = [language]
            body["language_hints_strict"] = true
        }

        var create = URLRequest(url: createURL)
        create.httpMethod = "POST"
        create.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = try await send(create)
        guard let transcriptionID = started["id"] as? String else { throw ProviderError.noTranscript }
        guard let statusURL = URL(string: base + "/transcriptions/\(transcriptionID)") else { throw ProviderError.badURL }
        guard let transcriptURL = URL(string: base + "/transcriptions/\(transcriptionID)/transcript") else { throw ProviderError.badURL }

        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            var poll = URLRequest(url: statusURL)
            poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let statusJSON = try await send(poll)
            let status = statusJSON["status"] as? String
            if status == "completed" {
                var transcript = URLRequest(url: transcriptURL)
                transcript.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let transcriptJSON = try await send(transcript)
                guard let text = transcriptJSON["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
                let duration = (statusJSON["audio_duration_ms"] as? Double).map { $0 / 1000 }
                return TranscriptionResult(text: text, detectedLanguage: settings.language.apiCode, duration: duration, providerName: settings.provider.rawValue, modelName: settings.model)
            }
            if status == "error" {
                throw ProviderError.http(422, statusJSON["error_message"] as? String ?? "Soniox transcription failed.")
            }
        }
        throw ProviderError.http(408, "Soniox transcription timed out.")
    }
}

struct GladiaTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let uploadURL = URL(string: base + "/upload") else { throw ProviderError.badURL }

        let form = try MultipartFormData()
        try form.addFile("audio", url: audioURL, mimeType: "audio/wav")
        try form.close()

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        try form.apply(to: &upload)

        let uploaded = try await send(upload, bodyFile: form.fileURL)
        guard let audioURLString = uploaded["audio_url"] as? String else { throw ProviderError.noTranscript }
        guard let initURL = URL(string: base + "/pre-recorded") else { throw ProviderError.badURL }

        var body: [String: Any] = [
            "audio_url": audioURLString,
            "model": settings.model,
            "punctuation_enhanced": settings.punctuation,
            "language_config": [
                "languages": settings.language.apiCode.map { [$0] } ?? [],
                "code_switching": settings.gladiaCodeSwitching
            ]
        ]
        if settings.language == .auto { body["language_config"] = ["languages": [], "code_switching": settings.gladiaCodeSwitching] }

        var start = URLRequest(url: initURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: body)

        let job = try await send(start)
        guard let resultURL = (job["result_url"] as? String).flatMap(URL.init(string:)),
              Network.isTrustedResultURL(resultURL, for: settings.provider, baseURL: base) else {
            throw ProviderError.badURL
        }
        // Align with pipeline timeout (~70s headroom under 75s resource limit).
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            var poll = URLRequest(url: resultURL)
            poll.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
            let result = try await send(poll)
            if let status = result["status"] as? String {
                if status == "done" {
                    let text = (((result["result"] as? [String: Any])?["transcription"] as? [String: Any])?["full_transcript"] as? String)
                    guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
                    return TranscriptionResult(text: text, detectedLanguage: nil, duration: nil, providerName: settings.provider.rawValue, modelName: settings.model)
                }
                if status == "error" || status == "failed" {
                    let msg = (result["error"] as? [String: Any])?["message"] as? String
                        ?? result["error_code"] as? String
                        ?? "Gladia transcription failed."
                    throw ProviderError.http(422, msg)
                }
            }
        }
        throw ProviderError.http(408, "Gladia transcription timed out.")
    }
}

struct SpeechmaticsTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let speechmaticsBase = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: speechmaticsBase + "/jobs") else { throw ProviderError.badURL }

        let config: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "language": settings.language.apiCode ?? "auto",
                "operating_point": settings.model
            ]
        ]

        let form = try MultipartFormData()
        try form.addField("config", String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8) ?? "{}")
        try form.addFile("data_file", url: audioURL, mimeType: "audio/wav")
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)

        let job = try await send(request, bodyFile: form.fileURL)
        guard let id = job["id"] as? String else { throw ProviderError.noTranscript }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let transcriptURL = URL(string: base + "/jobs/\(id)/transcript?format=txt") else { throw ProviderError.badURL }
        for _ in 0..<55 {
            try await Task.sleep(for: .seconds(1))
            var poll = URLRequest(url: transcriptURL)
            poll.timeoutInterval = 60
            poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            try Task.checkCancellation()
            let result = try await fetch(poll, bodyFile: nil)
            try Task.checkCancellation()
            let data = result.data
            let status = result.response.statusCode
            if status == 200 {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ProviderError.noTranscript }
                return TranscriptionResult(text: text, detectedLanguage: settings.language.apiCode, duration: nil, providerName: settings.provider.rawValue, modelName: settings.model)
            }
            if (500...599).contains(status) {
                continue
            }
            if status != 202 && status != 404 {
                throw ProviderError.http(status, DiagnosticsLogger.safeErrorBody(data))
            }
        }
        throw ProviderError.http(408, "Speechmatics transcription timed out.")
    }
}

struct DeepgramTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        var components = URLComponents(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/listen")
        components?.queryItems = [
            URLQueryItem(name: "model", value: settings.model),
            URLQueryItem(name: "language", value: settings.language.apiCode ?? "multi"),
            URLQueryItem(name: "smart_format", value: String(settings.deepgramSmartFormat)),
            URLQueryItem(name: "numerals", value: String(settings.deepgramNumerals)),
            URLQueryItem(name: "punctuate", value: String(settings.deepgramPunctuation))
        ]
        guard let url = components?.url else { throw ProviderError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(
            String((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            forHTTPHeaderField: "Content-Length"
        )

        let json = try await send(request, bodyFile: audioURL)
        let channel = ((json["results"] as? [String: Any])?["channels"] as? [[String: Any]])?.first
        let alternative = (channel?["alternatives"] as? [[String: Any]])?.first
        guard let text = alternative?["transcript"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(text: text, detectedLanguage: settings.language.apiCode, duration: (json["metadata"] as? [String: Any])?["duration"] as? TimeInterval, providerName: settings.provider.rawValue, modelName: settings.model)
    }
}

struct ElevenLabsTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let url = URL(string: settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/speech-to-text") else {
            throw ProviderError.badURL
        }

        let form = try MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.addField("model_id", settings.model)
        if let language = settings.language.apiCode { try form.addField("language_code", language) }
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        try form.apply(to: &request)

        let json = try await send(request, bodyFile: form.fileURL)
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(text: text, detectedLanguage: json["language_code"] as? String, duration: nil, providerName: settings.provider.rawValue, modelName: settings.model)
    }
}

// MARK: - AssemblyAI

/// Upload → create transcript → poll until completed.
/// Docs: https://www.assemblyai.com/docs
struct AssemblyAITranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let uploadURL = URL(string: base + "/v2/upload") else { throw ProviderError.badURL }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(apiKey, forHTTPHeaderField: "authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upload.setValue(
            String((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            forHTTPHeaderField: "Content-Length"
        )
        upload.timeoutInterval = 90

        let uploadJSON = try await send(upload, bodyFile: audioURL)
        guard let remoteURL = uploadJSON["upload_url"] as? String else {
            throw ProviderError.noTranscript
        }

        guard let transcriptURL = URL(string: base + "/v2/transcript") else { throw ProviderError.badURL }
        var body: [String: Any] = [
            "audio_url": remoteURL,
            "speech_models": [settings.model]
        ]
        if let code = settings.language.apiCode {
            body["language_code"] = code
        } else {
            body["language_detection"] = true
        }

        var create = URLRequest(url: transcriptURL)
        create.httpMethod = "POST"
        create.setValue(apiKey, forHTTPHeaderField: "authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: body)

        let created = try await send(create)
        guard let id = created["id"] as? String else { throw ProviderError.noTranscript }
        guard let pollURL = URL(string: base + "/v2/transcript/\(id)") else { throw ProviderError.badURL }

        // Keep under pipeline 75s + session resource timeout.
        for _ in 0..<55 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            var poll = URLRequest(url: pollURL)
            poll.setValue(apiKey, forHTTPHeaderField: "authorization")
            let statusJSON = try await send(poll)
            let status = statusJSON["status"] as? String
            if status == "completed" {
                guard let text = statusJSON["text"] as? String, !text.isEmpty else {
                    throw ProviderError.noTranscript
                }
                let duration = statusJSON["audio_duration"] as? TimeInterval
                return TranscriptionResult(
                    text: text,
                    detectedLanguage: statusJSON["language_code"] as? String,
                    duration: duration,
                    providerName: settings.provider.rawValue,
                    modelName: settings.model
                )
            }
            if status == "error" {
                throw ProviderError.http(422, statusJSON["error"] as? String ?? "AssemblyAI failed.")
            }
        }
        throw ProviderError.http(408, "AssemblyAI transcription timed out.")
    }
}

// MARK: - OpenRouter (OpenAI-compatible multipart STT)

struct OpenRouterTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/audio/transcriptions") else { throw ProviderError.badURL }

        let form = try MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.addField("model", settings.model)
        if let language = settings.language.apiCode { try form.addField("language", language) }
        try form.addField("response_format", "json")
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)
        // Optional but recommended by OpenRouter.
        request.setValue("Dictabar", forHTTPHeaderField: "X-Title")

        let json = try await send(request, bodyFile: form.fileURL)
        let text = json["text"] as? String
        guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(
            text: text,
            detectedLanguage: json["language"] as? String,
            duration: json["duration"] as? TimeInterval,
            providerName: settings.provider.rawValue,
            modelName: settings.model
        )
    }
}

// MARK: - Azure Speech (Fast Transcription)

/// Uses Speech Fast Transcription REST API.
/// Base URL must be the regional host, e.g. https://eastus.api.cognitive.microsoft.com
/// API key = Speech resource key.
struct AzureSpeechTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/speechtotext/transcriptions:transcribe?api-version=2025-10-15") else {
            throw ProviderError.badURL
        }

        let locale = settings.language == .auto ? "en-US" : settings.language.bcp47
        let definition: [String: Any] = settings.model.hasPrefix("mai-transcribe")
            ? ["enhancedMode": ["enabled": true, "model": settings.model]]
            : ["locales": [locale]]
        let definitionJSON = String(data: try JSONSerialization.data(withJSONObject: definition), encoding: .utf8) ?? "{\"locales\":[\"en-US\"]}"

        let form = try MultipartFormData()
        try form.addFile("audio", url: audioURL, mimeType: "audio/wav")
        try form.addField("definition", definitionJSON)
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        try form.apply(to: &request)
        request.timeoutInterval = 90

        let json = try await send(request, bodyFile: form.fileURL)
        // Response: { "combinedPhrases": [ { "text": "..." } ], "durationMilliseconds": ... }
        let phrases = json["combinedPhrases"] as? [[String: Any]]
        let text = phrases?
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else {
            // Fallback: phrases array
            if let phrases2 = json["phrases"] as? [[String: Any]] {
                let joined = phrases2.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !joined.isEmpty {
                    return TranscriptionResult(
                        text: joined,
                        detectedLanguage: locale,
                        duration: (json["durationMilliseconds"] as? Double).map { $0 / 1000 },
                        providerName: settings.provider.rawValue,
                        modelName: settings.model
                    )
                }
            }
            throw ProviderError.noTranscript
        }
        return TranscriptionResult(
            text: text,
            detectedLanguage: locale,
            duration: (json["durationMilliseconds"] as? Double).map { $0 / 1000 },
            providerName: settings.provider.rawValue,
            modelName: settings.model
        )
    }
}

// MARK: - Google Cloud Speech-to-Text (sync recognize + API key)

/// Uses API key as query parameter (simple for desktop apps).
/// Expects LINEAR16 WAV @ 16 kHz (matches Dictabar recorder).
struct GoogleCloudSTTTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/speech:recognize") else { throw ProviderError.badURL }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ProviderError.badURL }

        // Recorder writes WAV; Google wants raw LINEAR16 PCM (no RIFF header).
        let b64 = try linear16PCM(fromWAV: audioURL).base64EncodedString()
        let languageCode = settings.language == .auto ? "en-US" : settings.language.bcp47

        var config: [String: Any] = [
            "encoding": "LINEAR16",
            "sampleRateHertz": 16_000,
            "languageCode": languageCode,
            "enableAutomaticPunctuation": true,
            "model": settings.model
        ]
        if settings.language == .auto {
            config["alternativeLanguageCodes"] = ["en-US", "ru-RU", "es-ES", "de-DE", "fr-FR"]
        }

        let body: [String: Any] = [
            "config": config,
            "audio": ["content": b64]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let json = try await send(request)
        let results = json["results"] as? [[String: Any]] ?? []
        let text = results
            .compactMap { ($0["alternatives"] as? [[String: Any]])?.first?["transcript"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(
            text: text,
            detectedLanguage: languageCode,
            duration: nil,
            providerName: settings.provider.rawValue,
            modelName: settings.model
        )
    }
}

// MARK: - Fireworks (OpenAI-compatible audio transcriptions)

struct FireworksTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let configured = settings.provider.sanitizedBaseURL(settings.baseURL)
        let standardHosts = [
            "https://api.fireworks.ai/inference/v1",
            "https://audio-prod.api.fireworks.ai/v1",
            "https://audio-turbo.api.fireworks.ai/v1"
        ]
        let base: String
        if standardHosts.contains(configured) {
            base = settings.model == "whisper-v3-turbo"
                ? "https://audio-turbo.api.fireworks.ai/v1"
                : "https://audio-prod.api.fireworks.ai/v1"
        } else {
            base = configured
        }
        guard let url = URL(string: base + "/audio/transcriptions") else { throw ProviderError.badURL }

        // Fireworks model ids are often "whisper-v3" — pass through as selected.
        let form = try MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.addField("model", settings.model)
        if let language = settings.language.apiCode { try form.addField("language", language) }
        try form.addField("response_format", "json")
        try form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)

        let json: [String: Any]
        do {
            json = try await send(request, bodyFile: form.fileURL)
        } catch ProviderError.http(401, _) {
            throw ProviderError.unsupported(
                "Fireworks rejected this API key. Create an inference API key from the Fireworks dashboard and save it for the Fireworks provider."
            )
        }
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return TranscriptionResult(
            text: text,
            detectedLanguage: json["language"] as? String,
            duration: json["duration"] as? TimeInterval,
            providerName: settings.provider.rawValue,
            modelName: settings.model
        )
    }
}

// MARK: - Together AI (OpenAI-compatible)

struct TogetherTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        do {
            return try await OpenAICompatibleTranscriptionProvider().transcribe(
                audioURL: audioURL,
                settings: settings,
                apiKey: apiKey
            )
        } catch ProviderError.http(401, _) {
            throw ProviderError.unsupported(
                "Together rejected this API key. Create a key at api.together.ai/settings/api-keys and save it for the Together provider."
            )
        }
    }
}

// MARK: - New file/batch providers

struct SmallestAITranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard var components = URLComponents(string: base + "/stt/") else { throw ProviderError.badURL }
        let language = settings.model == "pulse-pro" ? "en" : (settings.language.apiCode ?? "multi-eu")
        components.queryItems = [
            URLQueryItem(name: "model", value: settings.model),
            URLQueryItem(name: "language", value: language)
        ]
        guard let url = components.url else { throw ProviderError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(
            String((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            forHTTPHeaderField: "Content-Length"
        )
        let json = try await send(request, bodyFile: audioURL)
        guard let text = json["transcription"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: language)
    }
}

struct AlibabaTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        if apiKey.hasPrefix("sk-sp-") {
            throw ProviderError.unsupported(
                "Alibaba Coding Plan and Token Plan keys cannot call speech models. Use a pay-as-you-go Model Studio API key."
            )
        }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/api/v1/services/aigc/multimodal-generation/generation") else {
            throw ProviderError.badURL
        }
        let encoded = try Data(contentsOf: audioURL).base64EncodedString()
        var options: [String: Any] = ["enable_itn": true]
        if let language = settings.language.apiCode { options["language"] = language }
        let body: [String: Any] = [
            "model": settings.model,
            "input": ["messages": [[
                "role": "user",
                "content": [["audio": "data:audio/wav;base64,\(encoded)"]]
            ]]],
            "parameters": ["asr_options": options]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json: [String: Any]
        do {
            json = try await send(request)
        } catch ProviderError.http(401, _) {
            throw ProviderError.unsupported(
                "Alibaba rejected this API key. Use a pay-as-you-go Model Studio key from the same region as the Base URL: Singapore → dashscope-intl.aliyuncs.com, Beijing → dashscope.aliyuncs.com."
            )
        }
        let output = json["output"] as? [String: Any]
        let choices = output?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        let text = content?.compactMap { $0["text"] as? String }.joined(separator: " ")
            ?? output?["text"] as? String
        guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: settings.language.apiCode)
    }
}

struct XAITranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/stt") else { throw ProviderError.badURL }
        let form = try MultipartFormData()
        try form.addField("format", "true")
        if let language = settings.language.apiCode { try form.addField("language", language) }
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.close()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)
        let json = try await send(request, bodyFile: form.fileURL)
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: json["language"] as? String, duration: json["duration"] as? Double)
    }
}

struct InworldTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/stt/v1/transcribe") else { throw ProviderError.badURL }
        // Recorder writes WAV; Inworld expects raw LINEAR16 PCM payload.
        let audio = try linear16PCM(fromWAV: audioURL).base64EncodedString()
        var config: [String: Any] = [
            "modelId": settings.model,
            "audioEncoding": "LINEAR16",
            "sampleRateHertz": 16_000,
            "numberOfChannels": 1
        ]
        if settings.language != .auto { config["language"] = settings.language.bcp47 }
        let body: [String: Any] = [
            "transcribeConfig": config,
            "audioData": ["content": audio]
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        let text = (json["transcription"] as? [String: Any])?["transcript"] as? String
        guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: settings.language.apiCode)
    }
}

struct CartesiaTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/stt") else { throw ProviderError.badURL }
        let form = try MultipartFormData()
        try form.addField("model", settings.model)
        if let language = settings.language.apiCode { try form.addField("language", language) }
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.close()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-01", forHTTPHeaderField: "Cartesia-Version")
        try form.apply(to: &request)
        let json = try await send(request, bodyFile: form.fileURL)
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: json["language"] as? String, duration: json["duration"] as? Double)
    }
}

struct GradiumTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard var components = URLComponents(string: base + "/post/speech/asr") else { throw ProviderError.badURL }
        var query = [URLQueryItem(name: "model", value: settings.model)]
        if let language = settings.language.apiCode {
            let config = String(data: try JSONSerialization.data(withJSONObject: ["language": language]), encoding: .utf8)
            query.append(URLQueryItem(name: "json_config", value: config))
        }
        components.queryItems = query
        guard let url = components.url else { throw ProviderError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(
            String((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            forHTTPHeaderField: "Content-Length"
        )
        let data = try await sendData(request, bodyFile: audioURL)
        let text = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
        guard !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: settings.language.apiCode)
    }
}

struct ModulateTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/velma-2-stt-batch") else { throw ProviderError.badURL }
        let form = try MultipartFormData()
        try form.addField("speaker_diarization", "false")
        try form.addFile("upload_file", url: audioURL, mimeType: "audio/wav")
        try form.close()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        try form.apply(to: &request)
        let json = try await send(request, bodyFile: form.fileURL)
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, duration: (json["duration_ms"] as? Double).map { $0 / 1000 })
    }
}

struct CohereTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let url = URL(string: base + "/audio/transcriptions") else { throw ProviderError.badURL }
        let form = try MultipartFormData()
        try form.addField("model", settings.model)
        // Cohere currently requires a language even though Dictabar can auto-detect elsewhere.
        try form.addField("language", settings.language.apiCode ?? "en")
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        try form.close()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        try form.apply(to: &request)
        let json = try await send(request, bodyFile: form.fileURL)
        guard let text = json["text"] as? String, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: settings.language.apiCode)
    }
}

struct CloudflareTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard !base.contains("ACCOUNT_ID"), let url = URL(string: base + "/\(settings.model)") else {
            throw ProviderError.unsupported("Replace ACCOUNT_ID in the Cloudflare Base URL.")
        }
        var body: [String: Any] = [
            "audio": try Data(contentsOf: audioURL).base64EncodedString(),
            "task": "transcribe"
        ]
        if let language = settings.language.apiCode { body["language"] = language }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await send(request)
        let payload = json["result"] as? [String: Any]
        let text = payload?["text"] as? String
            ?? (payload?["transcription_info"] as? [String: Any])?["text"] as? String
        guard let text, !text.isEmpty else { throw ProviderError.noTranscript }
        return result(text, settings, language: settings.language.apiCode)
    }
}

// MARK: - Amazon Transcribe batch (temporary S3 object + SigV4)

struct AmazonTranscribeProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        let credentials = apiKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard credentials.count == 2, !credentials[0].isEmpty, !credentials[1].isEmpty else {
            throw ProviderError.unsupported("Enter AWS credentials as ACCESS_KEY_ID:SECRET_ACCESS_KEY.")
        }
        guard let configured = URL(string: settings.provider.sanitizedBaseURL(settings.baseURL)),
              let host = configured.host,
              let region = host.split(separator: ".").dropFirst().first.map(String.init),
              region != "amazonaws",
              let bucket = configured.path.split(separator: "/").first.map(String.init),
              bucket != "your-s3-bucket" else {
            throw ProviderError.unsupported("Append your S3 bucket to the regional Amazon Transcribe Base URL.")
        }

        let objectKey = "dictabar/\(UUID().uuidString).wav"
        let s3Host = "s3.\(region).amazonaws.com"
        let s3Path = "/\(bucket)/\(objectKey)"
        guard let s3URL = URL(string: "https://\(s3Host)\(s3Path)"),
              let transcribeURL = URL(string: "https://transcribe.\(region).amazonaws.com/") else {
            throw ProviderError.badURL
        }
        let signer = AWSSigner(accessKey: credentials[0], secretKey: credentials[1], region: region)
        let audio = try Data(contentsOf: audioURL)

        var upload = URLRequest(url: s3URL)
        upload.httpMethod = "PUT"
        upload.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        upload.httpBody = audio
        signer.sign(&upload, service: "s3", body: audio)
        _ = try await sendData(upload)

        let jobName = "dictabar-\(UUID().uuidString.lowercased())"
        var startBody: [String: Any] = [
            "TranscriptionJobName": jobName,
            "Media": ["MediaFileUri": "s3://\(bucket)/\(objectKey)"],
            "MediaFormat": "wav"
        ]
        if settings.language == .auto {
            startBody["IdentifyLanguage"] = true
        } else {
            startBody["LanguageCode"] = settings.language.bcp47
        }
        let startData = try JSONSerialization.data(withJSONObject: startBody)
        var start = URLRequest(url: transcribeURL)
        start.httpMethod = "POST"
        start.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        start.setValue("Transcribe.StartTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
        start.httpBody = startData
        signer.sign(&start, service: "transcribe", body: startData)
        _ = try await send(start)

        defer {
            Task {
                var delete = URLRequest(url: s3URL)
                delete.httpMethod = "DELETE"
                signer.sign(&delete, service: "s3", body: Data())
                _ = try? await sendData(delete)
            }
        }

        for _ in 0..<55 {
            try await Task.sleep(for: .seconds(1))
            try Task.checkCancellation()
            let pollData = try JSONSerialization.data(withJSONObject: ["TranscriptionJobName": jobName])
            var poll = URLRequest(url: transcribeURL)
            poll.httpMethod = "POST"
            poll.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
            poll.setValue("Transcribe.GetTranscriptionJob", forHTTPHeaderField: "X-Amz-Target")
            poll.httpBody = pollData
            signer.sign(&poll, service: "transcribe", body: pollData)
            let statusJSON = try await send(poll)
            let job = statusJSON["TranscriptionJob"] as? [String: Any]
            switch job?["TranscriptionJobStatus"] as? String {
            case "COMPLETED":
                guard let uri = (job?["Transcript"] as? [String: Any])?["TranscriptFileUri"] as? String,
                      let url = URL(string: uri),
                      Network.isTrustedResultURL(url, for: settings.provider, baseURL: settings.baseURL) else {
                    throw ProviderError.badURL
                }
                let transcriptData = try await sendData(URLRequest(url: url))
                let transcriptJSON = try JSONSerialization.jsonObject(with: transcriptData) as? [String: Any]
                let transcripts = (transcriptJSON?["results"] as? [String: Any])?["transcripts"] as? [[String: Any]]
                guard let text = transcripts?.first?["transcript"] as? String, !text.isEmpty else {
                    throw ProviderError.noTranscript
                }
                return result(text, settings, language: job?["LanguageCode"] as? String)
            case "FAILED":
                throw ProviderError.http(422, job?["FailureReason"] as? String ?? "Amazon Transcribe failed.")
            default:
                continue
            }
        }
        throw ProviderError.http(408, "Amazon Transcribe timed out.")
    }
}

struct AWSSigner: Sendable {
    let accessKey: String
    let secretKey: String
    let region: String

    func sign(_ request: inout URLRequest, service: String, body: Data, now: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let date = Self.timestamp.string(from: now)
        let day = String(date.prefix(8))
        let payloadHash = SHA256.hash(data: body).hex
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(date, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")

        let allHeaders = request.allHTTPHeaderFields ?? [:]
        let headerNames = allHeaders.keys.map { $0.lowercased() }
        let signedNames = headerNames
            .filter { name in name == "content-type" || name == "host" || name.hasPrefix("x-amz-") }
            .sorted()
        let lowerHeaders = Dictionary(uniqueKeysWithValues: allHeaders.map { ($0.key.lowercased(), $0.value) })
        let canonicalHeaders = signedNames.map { "\($0):\(lowerHeaders[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")\n" }.joined()
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = Self.canonicalQuery(for: url)
        let canonicalRequest = [
            request.httpMethod ?? "GET", canonicalURI, canonicalQuery,
            canonicalHeaders, signedNames.joined(separator: ";"), payloadHash
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(date)\n\(scope)\n\(SHA256.hash(data: Data(canonicalRequest.utf8)).hex)"
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(day.utf8), using: SymmetricKey(data: Data(("AWS4" + secretKey).utf8)))
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: Data(kDate)))
        let kService = HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: Data(kRegion)))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: Data(kService)))
        let signatureCode = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(kSigning))
        )
        let signature = signatureCode.map { String(format: "%02x", $0) }.joined()
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedNames.joined(separator: ";")), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    private static func canonicalQuery(for url: URL) -> String {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
              !query.isEmpty else {
            return ""
        }
        return query.split(separator: "&", omittingEmptySubsequences: false)
            .map { pair -> String in
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(pieces[0]).removingPercentEncoding ?? String(pieces[0])
                let value = pieces.count == 2
                    ? (String(pieces[1]).removingPercentEncoding ?? String(pieces[1]))
                    : ""
                return "\(awsEncode(name))=\(awsEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
    }

    private static func awsEncode(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func result(
    _ text: String,
    _ settings: ProviderSettings,
    language: String? = nil,
    duration: Double? = nil
) -> TranscriptionResult {
    TranscriptionResult(
        text: text,
        detectedLanguage: language,
        duration: duration,
        providerName: settings.provider.rawValue,
        modelName: settings.model
    )
}

/// Strip RIFF/WAV container for APIs that want raw LINEAR16 PCM.
/// Dictabar records mono 16-bit LE PCM @ 16 kHz — standard 44-byte header, or "data" chunk.
private func linear16PCM(fromWAV url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard data.count > 44,
          data.starts(with: Data("RIFF".utf8)),
          data.count >= 12,
          data[8..<12] == Data("WAVE".utf8) else {
        return data
    }
    // Walk chunks after "WAVE" until "data".
    var offset = 12
    while offset + 8 <= data.count {
        let id = data[offset..<(offset + 4)]
        let size = Int(data[offset + 4])
            | (Int(data[offset + 5]) << 8)
            | (Int(data[offset + 6]) << 16)
            | (Int(data[offset + 7]) << 24)
        let payloadStart = offset + 8
        let payloadEnd = min(payloadStart + max(size, 0), data.count)
        if id == Data("data".utf8) {
            return data.subdata(in: payloadStart..<payloadEnd)
        }
        // Chunks are word-aligned.
        offset = payloadEnd + (size & 1)
    }
    // Fallback for our fixed recorder layout.
    return data.subdata(in: 44..<data.count)
}

/// Shared session with bounded timeouts, no cross-origin redirects, and response size caps.
private enum Network {
    /// Refuse redirects that change host (prevents leaking API keys + POST body to a 3rd party).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let original = task.originalRequest?.url,
                  let next = request.url,
                  let fromHost = original.host?.lowercased(),
                  let toHost = next.host?.lowercased(),
                  fromHost == toHost,
                  next.scheme?.lowercased() == "https" else {
                DiagnosticsLogger.shared.log(
                    "network: blocked redirect \(task.originalRequest?.url?.host ?? "?") → \(request.url?.host ?? "?")"
                )
                completionHandler(nil)
                return
            }
            // Strip non-standard auth headers on redirect within same host still OK;
            // cross-host already blocked. Keep Authorization only for same host.
            completionHandler(request)
        }
    }

    private static let redirectGuard = RedirectGuard()

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = true
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
    }()

    static let maxResponseBytes = 2 * 1024 * 1024

    /// Validate provider poll/result URLs stay on an allowed host for that provider.
    static func isTrustedResultURL(_ url: URL, for provider: SpeechProvider, baseURL: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }
        let suffixes = provider.allowedHostSuffixes
        if suffixes.isEmpty {
            // Custom: same host as configured base URL only.
            if let baseHost = URL(string: baseURL)?.host?.lowercased() {
                return host == baseHost
            }
            return false
        }
        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

private func sendData(_ request: URLRequest, bodyFile: URL? = nil) async throws -> Data {
    var request = request
    if request.timeoutInterval <= 0 || request.timeoutInterval > 90 {
        request.timeoutInterval = 60
    }
    // Enforce https on every request URL.
    guard let url = request.url,
          url.scheme?.lowercased() == "https",
          url.host != nil else {
        throw ProviderError.badURL
    }
    let maxAttempts = 3
    for attempt in 0..<maxAttempts {
        do {
            try Task.checkCancellation()
            let result = try await fetch(request, bodyFile: bodyFile)
            try Task.checkCancellation()
            let status = result.response.statusCode
            if (200..<300).contains(status) {
                return result.data
            }
            let error = ProviderError.http(status, DiagnosticsLogger.safeErrorBody(result.data))
            guard error.isRetryable, attempt + 1 < maxAttempts else { throw error }
            let delay = retryDelay(response: result.response, attempt: attempt)
            DiagnosticsLogger.shared.log("network: retry status=\(status) attempt=\(attempt + 2) delay=\(delay)")
            try await Task.sleep(for: .seconds(delay))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            guard isTransient(error), attempt + 1 < maxAttempts else {
                if error.code == .timedOut { throw ProviderError.timedOut }
                throw ProviderError.network(error.localizedDescription)
            }
            let delay = backoff(attempt: attempt)
            DiagnosticsLogger.shared.log("network: retry transport=\(error.code.rawValue) attempt=\(attempt + 2) delay=\(delay)")
            try await Task.sleep(for: .seconds(delay))
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                let urlError = URLError(URLError.Code(rawValue: ns.code))
                guard isTransient(urlError), attempt + 1 < maxAttempts else {
                    throw ProviderError.network(error.localizedDescription)
                }
                try await Task.sleep(for: .seconds(backoff(attempt: attempt)))
                continue
            }
            throw error
        }
    }
    throw ProviderError.network("Request failed")
}

private func send(_ request: URLRequest, bodyFile: URL? = nil) async throws -> [String: Any] {
    let data = try await sendData(request, bodyFile: bodyFile)
    guard !data.isEmpty else { return [:] }
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}

private func fetch(_ request: URLRequest, bodyFile: URL?) async throws -> (data: Data, response: HTTPURLResponse) {
    if let bodyFile {
        let (data, response) = try await Network.session.upload(for: request, fromFile: bodyFile)
        guard data.count <= Network.maxResponseBytes else {
            throw ProviderError.http(413, "Provider response too large.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("Invalid HTTP response")
        }
        return (data, http)
    }

    let (bytes, response) = try await Network.session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw ProviderError.network("Invalid HTTP response")
    }
    var data = Data()
    let expected = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : 0
    data.reserveCapacity(min(Network.maxResponseBytes, expected))
    for try await byte in bytes {
        guard data.count < Network.maxResponseBytes else {
            throw ProviderError.http(413, "Provider response too large.")
        }
        data.append(byte)
    }
    return (data, http)
}

private func retryDelay(response: HTTPURLResponse, attempt: Int) -> Double {
    if let value = response.value(forHTTPHeaderField: "Retry-After") {
        if let seconds = Double(value), seconds >= 0 {
            return min(seconds, 15)
        }
        if let date = HTTPDateParser.parse(value) {
            return min(max(0, date.timeIntervalSinceNow), 15)
        }
    }
    return backoff(attempt: attempt)
}

private func backoff(attempt: Int) -> Double {
    min(pow(2, Double(attempt)) + Double.random(in: 0...0.35), 8)
}

private func isTransient(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
            .internationalRoamingOff, .callIsActive, .dataNotAllowed:
        true
    default:
        false
    }
}

private enum HTTPDateParser {
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: value)
    }
}
