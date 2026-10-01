import Foundation

enum NewProviderFixtures {
    static func check() throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("dictabar-step-fixture-\(UUID().uuidString).wav")
        let bytes = Data([0x52, 0x49, 0x46, 0x46])
        try bytes.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        let step = settings(.stepFun, model: "stepaudio-3-asr-max")
        let request = try StepFunTranscriptionProvider.request(audioURL: audio, settings: step, apiKey: "fixture-key")
        precondition(request.url?.absoluteString == "https://api.stepfun.com/v1/audio/asr/sse")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        precondition(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let audioBody = body["audio"] as! [String: Any]
        precondition(Data(base64Encoded: audioBody["data"] as! String) == bytes)
        let input = audioBody["input"] as! [String: Any]
        let transcription = input["transcription"] as! [String: Any]
        precondition(transcription["model"] as? String == "stepaudio-3-asr-max")
        precondition(transcription["language"] == nil)
        precondition(transcription["full_rerun_on_commit"] == nil)
        precondition((input["format"] as! [String: Any])["type"] as? String == "wav")
        var englishStep = step
        englishStep.language = .english
        let englishRequest = try StepFunTranscriptionProvider.request(audioURL: audio, settings: englishStep, apiKey: "fixture-key")
        let englishBody = try JSONSerialization.jsonObject(with: englishRequest.httpBody!) as! [String: Any]
        let englishInput = (englishBody["audio"] as! [String: Any])["input"] as! [String: Any]
        precondition((englishInput["transcription"] as! [String: Any])["language"] as? String == "en")

        let stream = ": keepalive\r\n\r\ndata: {\"type\":\"transcript.text.delta\",\"delta\":\"wrong draft\"}\r\n\r\nevent: transcription\r\ndata: {\"type\":\"transcript.text.done\",\r\ndata: \"text\":\"Hello 世界\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        let text = try StepFunTranscriptionProvider.transcript(from: Data(stream.utf8))
        precondition(text == "Hello 世界")
        try expectFailure { _ = try StepFunTranscriptionProvider.transcript(from: Data("data: {\"type\":\"transcript.text.delta\",\"delta\":\"partial\"}\n\n".utf8)) }
        try expectFailure { _ = try StepFunTranscriptionProvider.transcript(from: Data("data: {\"type\":\"error\",\"message\":\"invalid model\"}\n\n".utf8)) }
        try expectFailure { _ = try StepFunTranscriptionProvider.transcript(from: Data("data: invalid\n\n".utf8)) }
        try expectFailure { _ = try StepFunTranscriptionProvider.transcript(from: Data("data: {\"type\":\"transcript.text.done\",\"text\":\"  \"}\n\n".utf8)) }

        let reson = settings(.reson8, model: "resonant-1")
        let resonRequest = try Reson8TranscriptionProvider.request(settings: reson, apiKey: "fixture-key")
        precondition(resonRequest.url?.path == "/v1/speech-to-text/prerecorded")
        precondition(resonRequest.value(forHTTPHeaderField: "Authorization") == "ApiKey fixture-key")
        precondition(resonRequest.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let query = URLComponents(url: resonRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "include_language", value: "true")))
        precondition(!query.contains { $0.name == "model" || $0.name == "language" })
        var englishReson = reson
        englishReson.language = .english
        let englishResonRequest = try Reson8TranscriptionProvider.request(settings: englishReson, apiKey: "fixture-key")
        precondition(URLComponents(url: englishResonRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "language", value: "en")))
        let result = try Reson8TranscriptionProvider.result(["text": "Hello world", "language": "en", "duration_ms": 3200.0], settings: reson)
        precondition(result.text == "Hello world" && result.detectedLanguage == "en" && result.duration == 3.2)
        try expectFailure { _ = try Reson8TranscriptionProvider.result(["text": ""], settings: reson) }
        try expectFailure { _ = try Reson8TranscriptionProvider.request(settings: reson, apiKey: " ") }
        precondition(SpeechProvider.stepFun.sanitizedBaseURL("https://api.stepfun.com.evil.test/v1") == SpeechProvider.stepFun.defaultBaseURL)
        precondition(SpeechProvider.reson8.sanitizedBaseURL("https://api.reson8.dev.evil.test/v1") == SpeechProvider.reson8.defaultBaseURL)
        print("Reson8 raw-upload and StepFun SSE request/response fixtures OK.")
    }

    private static func settings(_ provider: SpeechProvider, model: String) -> ProviderSettings {
        ProviderSettings(provider: provider, model: model, baseURL: provider.defaultBaseURL, language: .auto,
                         deepgramSmartFormat: true, deepgramNumerals: true, deepgramPunctuation: true,
                         gladiaCodeSwitching: false, punctuation: true)
    }

    private static func expectFailure(_ work: () throws -> Void) throws {
        do { try work() } catch { return }
        fatalError("Expected the provider fixture to fail")
    }
}
