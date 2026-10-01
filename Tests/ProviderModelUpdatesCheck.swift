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
        print("Provider model update fixtures OK: GPT language schema, MAI model casing/locales, Melia multilingual config, Solaria language coverage, Sync routing/limits/fallback policy.")
    }
}
