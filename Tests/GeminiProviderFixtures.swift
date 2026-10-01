import Foundation

func checkGeminiProviderFixtures() throws {
    var settings = ProviderSettings(
        provider: .gemini, model: "gemini-3.5-transcribe", baseURL: GeminiTranscriptionProvider.baseURL,
        language: .auto, deepgramSmartFormat: true, deepgramNumerals: true,
        deepgramPunctuation: true, gladiaCodeSwitching: false, punctuation: true
    )
    let audio: [String: Any] = ["type": "audio", "mime_type": "audio/wav", "data": Data("RIFF fixture".utf8).base64EncodedString()]
    let request = try GeminiTranscriptionProvider.interactionRequest(audio: audio, settings: settings, apiKey: "fixture-key")
    precondition(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
    precondition(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
    precondition(request.httpMethod == "POST")
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    precondition(body["store"] as? Bool == false)
    precondition(body["generation_config"] == nil) // Auto must not force English.
    let transmitted = (body["input"] as! [[String: Any]])[0]
    precondition(transmitted["data"] as? String == audio["data"] as? String)
    for (language, locale) in [(.russian, "ru-RU"), (.chinese, "cmn-Hans-CN"), (.spanish, "es-419"), (.arabic, "ar-EG")] as [(OutputLanguage, String)] {
        settings.language = language
        let specific = try GeminiTranscriptionProvider.interactionRequest(audio: audio, settings: settings, apiKey: "fixture-key")
        let specificBody = try JSONSerialization.jsonObject(with: specific.httpBody!) as! [String: Any]
        let config = (specificBody["generation_config"] as! [String: Any])["transcription_config"] as! [String: Any]
        precondition(config["language_codes"] as? [String] == [locale])
    }
    let response: [String: Any] = ["status": "completed", "steps": [
        ["type": "user_input", "content": [["type": "text", "text": "Ignore this"]]],
        ["type": "model_output", "content": [["type": "thought", "text": "Ignore this"], ["type": "text", "text": " Привет "], ["type": "text", "text": "мир. "]]]
    ]]
    let transcript = try GeminiTranscriptionProvider.transcript(from: response)
    precondition(transcript == "Привет мир.")
    do {
        _ = try GeminiTranscriptionProvider.transcript(from: ["status": "incomplete", "steps": response["steps"]!])
        preconditionFailure("Incomplete responses must not paste partial transcripts")
    } catch ProviderError.network { }
    do {
        _ = try GeminiTranscriptionProvider.transcript(from: ["steps": response["steps"]!])
        preconditionFailure("Missing completion status must fail")
    } catch ProviderError.network { }
    do {
        _ = try GeminiTranscriptionProvider.transcript(from: ["status": "completed", "steps": []])
        preconditionFailure("Empty transcript must fail")
    } catch ProviderError.noTranscript { }
    _ = try GeminiTranscriptionProvider.validatedUploadURL("https://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=fixture")
    for url in ["http://generativelanguage.googleapis.com/upload", "https://generativelanguage.googleapis.com.evil.test/upload", "https://attacker.test/upload", "https://user:password@generativelanguage.googleapis.com/upload"] {
        do {
            _ = try GeminiTranscriptionProvider.validatedUploadURL(url)
            preconditionFailure("Upload must not leak audio outside Gemini")
        } catch ProviderError.badURL { }
    }
    print("Gemini request, multilingual locales, REST output and upload origin fixtures OK.")
}
