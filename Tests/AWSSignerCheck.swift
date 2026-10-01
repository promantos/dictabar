import Foundation
import AVFoundation

// Compile-only stand-in; the app target supplies the native implementation.
struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Local runtime is tested by the app build.")
    }
}

@main
enum AWSSignerCheck {
    static func main() async throws {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!)
        request.httpMethod = "GET"

        let signer = AWSSigner(
            accessKey: "AKIAIOSFODNN7EXAMPLE",
            secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1"
        )
        signer.sign(
            &request,
            service: "s3",
            body: Data(),
            now: Date(timeIntervalSince1970: 1_369_353_600)
        )

        let expected = "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix(expected) == true)
        precondition(LocalSpeechModel.parakeet.languageCodes.count == 25)
        precondition(LocalSpeechModel.nemotron.languageCodes.count == 35)
        precondition(LocalSpeechModel.qwen.languageCodes.count == 30)
        precondition(LocalSpeechModel.moss.languageCodes.isEmpty)
        precondition(LocalSpeechModel.moss.reportedLanguageCount == "50+")
        precondition(SpeechProvider.assemblyAI.resolvedModel("universal-3-pro") == "universal-3-5-pro")
        precondition(SpeechProvider.mistral.resolvedModel("voxtral-mini-latest") == "voxtral-mini-2602")
        precondition(SpeechProvider.azureSpeech.resolvedModel("mai-transcribe-1") == "mai-transcribe-2")
        precondition(SpeechProvider.googleCloud.resolvedModel("chirp_2") == "latest_long")
        precondition(SpeechProvider.gemini.modelInfos[0].languageCodes.contains("ru"))
        precondition(Set(ProviderGroup.allCases.flatMap(SpeechProvider.providers)).count == SpeechProvider.allCases.count)
        for provider in SpeechProvider.allCases where provider != .custom {
            precondition(provider.sanitizedBaseURL("https://malicious.example") == provider.defaultBaseURL)
        }
        print("AWS SigV4 official test vector and saved model migrations OK.")
        try NewProviderFixtures.check()
        try checkGeminiProviderFixtures()
        try checkNariState()
        try checkPCM()
        if CommandLine.arguments.count > 1 {
            try await checkNariSocket(port: CommandLine.arguments[1])
        }
    }

    static let nariSettings = ProviderSettings(
        provider: .nariLabs, model: "qwen3-asr-fast:free", baseURL: SpeechProvider.nariLabs.defaultBaseURL,
        language: .auto, deepgramSmartFormat: true, deepgramNumerals: true,
        deepgramPunctuation: true, gladiaCodeSwitching: false, punctuation: true
    )

    static func checkNariState() throws {
        precondition(SpeechProvider.nariLabs.models.count == 4)
        precondition(SpeechProvider.nariLabs.modelInfos.allSatisfy { $0.languageCodes.contains("ru") })
        precondition(SpeechProvider.providers(in: .freeEasy).contains(.nariLabs))
        precondition(SpeechProvider.nariLabs.sanitizedBaseURL("https://api.narilabs.com.evil.test/v1") == SpeechProvider.nariLabs.defaultBaseURL)
        var state = NariTranscriptState()
        try state.consume(["type": "input_audio_buffer.committed", "item_id": "one"])
        try state.consume(["type": "transcript.partial", "item_id": "one", "transcript": "wrong"])
        try state.consume(["type": "input_audio_buffer.committed", "item_id": "two"])
        try state.consume(["type": "transcript.completed", "item_id": "two", "transcript": "мир", "language": "ru"])
        try state.consume(["type": "input_audio_buffer.commit_empty", "client_event_id": NariTranscriptState.endEventID])
        precondition(!state.isComplete) // end acknowledgement must not truncate pending text
        try state.consume(["type": "transcript.completed", "item_id": "one", "transcript": "Привет", "language": "ru", "usage": ["input_audio_seconds": 36.0]])
        try state.consume(["type": "transcript.completed", "item_id": "one", "transcript": "Привет", "language": "ru", "usage": ["input_audio_seconds": 36.0]])
        precondition(state.isComplete)
        let result = try state.result(settings: nariSettings)
        precondition(result.text == "Привет мир" && result.detectedLanguage == "ru" && result.duration == 36)
        var silence = NariTranscriptState()
        try silence.consume(["type": "input_audio_buffer.committed", "item_id": "s", "client_event_id": NariTranscriptState.endEventID])
        try silence.consume(["type": "transcript.completed", "item_id": "s", "transcript": ""])
        do { _ = try silence.result(settings: nariSettings); preconditionFailure("Silence must not insert text") }
        catch ProviderError.noTranscript {}
        let credits = NariTranscriptState.providerError(["error": ["code": "INSUFFICIENT_CREDITS"]])
        precondition(!credits.isRetryable && credits.localizedDescription.contains("credits"))
        let partner = NariTranscriptState.providerError(["error": ["code": "PARTNER_ACCESS_REQUIRED"]])
        precondition(partner.localizedDescription.contains(":free"))
        print("Nari catalog, ordered final transcripts, duration boundaries, silence and errors OK.")
    }

    static func makeWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dictabar-test-\(UUID()).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
        buffer.frameLength = 3_200
        for i in 0..<3_200 { buffer.int16ChannelData![0][i] = Int16(i % 100) }
        try file.write(from: buffer)
        file.close()
        return url
    }

    static func checkPCM() throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let pcm = try linear16PCM(fromWAV: url)
        precondition(pcm.count == 6_400)
        precondition(Array(pcm.prefix(6)) == [0, 0, 1, 0, 2, 0])
        try Data("invalid WAV".utf8).write(to: url)
        do { _ = try linear16PCM(fromWAV: url); preconditionFailure("Invalid WAV accepted") }
        catch {}
        print("PCM decoding preserves samples, removes WAV metadata and rejects malformed files.")
    }

    static func checkNariSocket(port: String) async throws {
        let url = try makeWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for scenario in ["success", "credits", "cancel", "credits-final", "cancel-final"] {
            let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/\(scenario)")!)
            let task = Task {
                try await NariLabsTranscriptionProvider().transcribe(audioURL: url, settings: nariSettings, socket: socket)
            }
            if scenario.hasPrefix("cancel") {
                try await Task.sleep(for: .milliseconds(200))
                task.cancel()
            }
            do {
                let result = try await task.value
                precondition(scenario == "success" && result.text == "Привет мир")
            } catch is CancellationError {
                precondition(scenario.hasPrefix("cancel"))
            } catch ProviderError.http(let status, _) {
                precondition(scenario.hasPrefix("credits") && status == 402)
            }
        }
        print("Real WebSocket configure/upload/commit, provider rejection and cancellation OK.")
    }

}
