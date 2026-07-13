import Foundation

enum ProviderError: LocalizedError {
    case missingAPIKey
    case badURL
    case unsupported(String)
    case http(Int, String)
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add an API key in Settings."
        case .badURL: "Bad provider URL."
        case let .unsupported(message): message
        case let .http(status, body): "Provider error \(status): \(body)"
        case .noTranscript: "Provider returned no transcript."
        }
    }
}

enum ProviderRegistry {
    static func provider(for provider: SpeechProvider) -> TranscriptionProvider {
        switch provider {
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

        var form = MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        form.addField("model", settings.model)
        if let language = settings.language.apiCode { form.addField("language", language) }
        form.addField("response_format", "json")
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data

        let json = try await send(request)
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

        var form = MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        form.close()

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        upload.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = form.data

        let uploaded = try await send(upload)
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

        var form = MultipartFormData()
        try form.addFile("audio", url: audioURL, mimeType: "audio/wav")
        form.close()

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        upload.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        upload.httpBody = form.data

        let uploaded = try await send(upload)
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

        var form = MultipartFormData()
        form.addField("config", String(data: try JSONSerialization.data(withJSONObject: config), encoding: .utf8) ?? "{}")
        try form.addFile("data_file", url: audioURL, mimeType: "audio/wav")
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data

        let job = try await send(request)
        guard let id = job["id"] as? String else { throw ProviderError.noTranscript }
        let base = settings.provider.sanitizedBaseURL(settings.baseURL)
        guard let transcriptURL = URL(string: base + "/jobs/\(id)/transcript?format=txt") else { throw ProviderError.badURL }
        for _ in 0..<55 {
            try await Task.sleep(for: .seconds(1))
            var poll = URLRequest(url: transcriptURL)
            poll.timeoutInterval = 60
            poll.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            try Task.checkCancellation()
            let (data, response) = try await Network.session.data(for: poll)
            try Task.checkCancellation()
            if data.count > Network.maxResponseBytes {
                throw ProviderError.http(413, "Provider response too large.")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ProviderError.noTranscript }
                return TranscriptionResult(text: text, detectedLanguage: settings.language.apiCode, duration: nil, providerName: settings.provider.rawValue, modelName: settings.model)
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
        request.httpBody = try Data(contentsOf: audioURL)

        let json = try await send(request)
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

        var form = MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        form.addField("model_id", settings.model)
        if let language = settings.language.apiCode { form.addField("language_code", language) }
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data

        let json = try await send(request)
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
        upload.httpBody = try Data(contentsOf: audioURL)
        upload.timeoutInterval = 90

        let uploadJSON = try await send(upload)
        guard let remoteURL = uploadJSON["upload_url"] as? String else {
            throw ProviderError.noTranscript
        }

        guard let transcriptURL = URL(string: base + "/v2/transcript") else { throw ProviderError.badURL }
        var body: [String: Any] = [
            "audio_url": remoteURL,
            "speech_model": settings.model
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

        var form = MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        form.addField("model", settings.model)
        if let language = settings.language.apiCode { form.addField("language", language) }
        form.addField("response_format", "json")
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        // Optional but recommended by OpenRouter.
        request.setValue("FlowDictate", forHTTPHeaderField: "X-Title")
        request.httpBody = form.data

        let json = try await send(request)
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
        guard let url = URL(string: base + "/speechtotext/transcriptions:transcribe?api-version=2024-11-15") else {
            throw ProviderError.badURL
        }

        let locale = settings.language == .auto ? "en-US" : settings.language.bcp47
        let definition: [String: Any] = [
            "locales": [locale]
        ]
        let definitionJSON = String(data: try JSONSerialization.data(withJSONObject: definition), encoding: .utf8) ?? "{\"locales\":[\"en-US\"]}"

        var form = MultipartFormData()
        try form.addFile("audio", url: audioURL, mimeType: "audio/wav")
        form.addField("definition", definitionJSON)
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data
        request.timeoutInterval = 90

        let json = try await send(request)
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
/// Expects LINEAR16 WAV @ 16 kHz (matches FlowDictate recorder).
struct GoogleCloudSTTTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/speech:recognize") else { throw ProviderError.badURL }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw ProviderError.badURL }

        let audioData = try Data(contentsOf: audioURL)
        let b64 = audioData.base64EncodedString()
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
        let base = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/audio/transcriptions") else { throw ProviderError.badURL }

        // Fireworks model ids are often "whisper-v3" — pass through as selected.
        var form = MultipartFormData()
        try form.addFile("file", url: audioURL, mimeType: "audio/wav")
        form.addField("model", settings.model)
        if let language = settings.language.apiCode { form.addField("language", language) }
        form.addField("response_format", "json")
        form.close()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.data

        let json = try await send(request)
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
        try await OpenAICompatibleTranscriptionProvider().transcribe(
            audioURL: audioURL,
            settings: settings,
            apiKey: apiKey
        )
    }
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
        config.timeoutIntervalForResource = 75
        config.waitsForConnectivity = false
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

private func send(_ request: URLRequest) async throws -> [String: Any] {
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
    try Task.checkCancellation()
    let (data, response) = try await Network.session.data(for: request)
    try Task.checkCancellation()
    if data.count > Network.maxResponseBytes {
        throw ProviderError.http(413, "Provider response too large (\(data.count) bytes).")
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw ProviderError.http(status, DiagnosticsLogger.safeErrorBody(data))
    }
    let object = try JSONSerialization.jsonObject(with: data)
    return object as? [String: Any] ?? [:]
}
