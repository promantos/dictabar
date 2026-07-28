import Foundation

// Compile-only stand-in; the app target supplies the native implementation.
struct LocalTranscriptionProvider: TranscriptionProvider {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        throw ProviderError.unsupported("Local runtime is tested by the app build.")
    }
}

@main
enum AWSSignerCheck {
    static func main() {
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
        print("AWS SigV4 official test vector OK.")
    }
}
