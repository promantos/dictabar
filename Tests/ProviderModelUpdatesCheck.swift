import Foundation

struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Local runtime belongs to app build")
    }
}

@main
enum ProviderModelUpdatesCheck {
    static func settings(_ provider: SpeechProvider, _ model: String, _ language: OutputLanguage = .auto) -> ProviderSettings {
        ProviderSettings(provider: provider, model: model, baseURL: provider.defaultBaseURL,
                         language: language, deepgramSmartFormat: true, deepgramNumerals: true,
                         deepgramPunctuation: true, gladiaCodeSwitching: false, punctuation: true)
    }

    static func main() throws {
        precondition(OpenAITranscriptionProvider.languageField(model: "gpt-transcribe") == "languages[]")
        precondition(OpenAITranscriptionProvider.languageField(model: "whisper-1") == "language")
        precondition(OpenAITranscriptionProvider.detectedLanguage(["languages": [["code": "ru"]]]) == "ru")
        precondition(OpenAITranscriptionProvider.detectedLanguage(["languages": []]) == nil)
        precondition(OpenAITranscriptionProvider.detectedLanguage(["language": "fr"]) == "fr")

        let mistralModels = SpeechProvider.mistral.models
        precondition(mistralModels == ["voxtral-mini-transcribe-3", "voxtral-small-transcribe-3", "voxtral-mini-2602"])
        precondition(SpeechProvider.mistral.resolvedModel(nil) == mistralModels[0])
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-mini-2602") == "voxtral-mini-2602")
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-mini-latest") == "voxtral-mini-2602")
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-small-latest") == mistralModels[1])
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-small-transcribe-3-0") == mistralModels[1])
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-mini-transcribe-latest") == mistralModels[0])
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("mistral-fixture-\(UUID().uuidString).wav")
        try Data("RIFF-audio-fixture".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        for model in mistralModels {
            for language in [OutputLanguage.auto, .russian] {
                let config = settings(.mistral, model, language)
                let (request, form) = try MistralTranscriptionProvider.makeRequest(audioURL: audio, settings: config, apiKey: "fixture-key")
                precondition(request.url?.absoluteString == "https://api.mistral.ai/v1/audio/transcriptions")
                precondition(request.httpMethod == "POST")
                precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
                precondition(request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
                let body = try String(contentsOf: form.fileURL, encoding: .utf8)
                precondition(body.contains("name=\"file\";") && body.contains("audio/wav") && body.contains("RIFF-audio-fixture"))
                precondition(body.contains("name=\"model\"\r\n\r\n\(model)\r\n"))
                precondition(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
                precondition(body.contains("name=\"language\"\r\n\r\nru\r\n") == (language == .russian))
                precondition(body.contains("name=\"return_language\"\r\n\r\ntrue\r\n") == (language == .auto && model != "voxtral-mini-2602"))
                precondition(!body.contains("timestamp_granularities") && !body.contains("diarize"))
                let result = try MistralTranscriptionProvider.result(from: ["text": "Привет", "language": "ru", "usage": ["prompt_audio_seconds": 2.5]], settings: config)
                precondition(result.text == "Привет" && result.detectedLanguage == "ru" && result.duration == 2.5)
                let legacy = try MistralTranscriptionProvider.result(from: ["text": "Hello", "language": NSNull(), "duration": 1.0], settings: config)
                precondition(legacy.detectedLanguage == nil && legacy.duration == 1)
                do {
                    _ = try MistralTranscriptionProvider.result(from: ["text": ""], settings: config)
                    preconditionFailure("Empty transcript accepted")
                } catch ProviderError.noTranscript { }
            }
        }

        let melia = SpeechmaticsTranscriptionProvider.configuration(settings: settings(.speechmatics, "melia-1", .russian))["transcription_config"] as! [String: Any]
        precondition(melia["model"] as? String == "melia-1" && melia["language"] as? String == "multi")
        precondition(melia["operating_point"] == nil)
        let enhanced = SpeechmaticsTranscriptionProvider.configuration(settings: settings(.speechmatics, "enhanced"))["transcription_config"] as! [String: Any]
        precondition(enhanced["language"] as? String == "auto" && enhanced["operating_point"] as? String == "enhanced")

        let azureAuto = AzureSpeechTranscriptionProvider.definition(settings: settings(.azureSpeech, "mai-transcribe-2"))
        precondition(azureAuto["locales"] == nil)
        let mode = azureAuto["enhancedMode"] as! [String: Any]
        precondition(mode["model"] as? String == "MAI-Transcribe-2" && mode["enabled"] as? Bool == true)
        let azureRU = AzureSpeechTranscriptionProvider.definition(settings: settings(.azureSpeech, "mai-transcribe-2", .russian))
        precondition(azureRU["locales"] as? [String] == ["ru-RU"])
        let maiLanguages = SpeechProvider.azureSpeech.modelInfos.first { $0.id == "mai-transcribe-2" }!.languageCodes
        precondition(maiLanguages.count == 60 && Set(maiLanguages).count == 60)
        precondition(SpeechProvider.gladia.modelInfos.first { $0.id == "solaria-3" }?.languageCodes == ["en", "fr", "de", "es", "it"])
        precondition(SpeechProvider.gladia.modelInfos.first { $0.id == "solaria-1" }!.languageCodes.contains("ru"))

        func route(_ base: String, _ model: String = "universal-3-5-pro", _ duration: Double? = 10, _ bytes: Int = 320000) -> URL? {
            AssemblyAITranscriptionProvider.syncURL(baseURL: base, model: model, duration: duration, fileSize: bytes)
        }
        precondition(route("https://api.assemblyai.com")?.absoluteString == "https://sync.us.assemblyai.com/v1/transcribe")
        precondition(route("https://api.eu.assemblyai.com")?.host == "sync.eu.assemblyai.com")
        precondition(route("https://api.assemblyai.com", "universal-2") == nil)
        precondition(route("https://api.assemblyai.com", "universal-3-5-pro", 121) == nil)
        precondition(route("https://api.assemblyai.com", "universal-3-5-pro", 0.079) == nil)
        precondition(route("https://api.assemblyai.com", "universal-3-5-pro", nil) == nil)
        precondition(route("https://api.assemblyai.com", "universal-3-5-pro", 10, 40_000_001) == nil)
        precondition(route("https://api.assemblyai.com.evil.test") == nil)
        precondition(route("https://api.assemblyai.com/proxy") == nil)
        precondition(route("http://api.assemblyai.com") == nil)
        precondition(AssemblyAITranscriptionProvider.shouldFallBackFromSync(.http(415, "unsupported")))
        for code in [400, 401, 402, 403, 408, 429, 500, 504] {
            precondition(!AssemblyAITranscriptionProvider.shouldFallBackFromSync(.http(code, "error")))
        }
        precondition(!AssemblyAITranscriptionProvider.shouldFallBackFromSync(.noTranscript))
        print("Provider model update fixtures OK: Voxtral 3 catalog/migration/multipart/response, GPT language schema, MAI model casing/locales, Melia multilingual config, Solaria language coverage, Sync routing/limits/fallback policy.")
    }
}
