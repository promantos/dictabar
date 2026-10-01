import Foundation

/// Dedicated ASR endpoint; this does not send audio to a general-purpose Gemini prompt.
struct GeminiTranscriptionProvider: TranscriptionProvider {
    static let origin = "https://generativelanguage.googleapis.com"
    static let baseURL = origin + "/v1beta"
    // Leave room for base64 expansion below the 20 MB inline request limit.
    static let inlineAudioLimit = 14 * 1024 * 1024

    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey }
        guard let duration = audioDuration(from: audioURL), duration <= 3_600 else {
            throw ProviderError.unsupported("Gemini Transcribe supports readable recordings up to one hour.")
        }
        let size = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let uploaded: [String: Any]?
        let audio: [String: Any]
        if size <= Self.inlineAudioLimit {
            uploaded = nil
            audio = ["type": "audio", "mime_type": "audio/wav", "data": try Data(contentsOf: audioURL).base64EncodedString()]
        } else {
            let file = try await upload(audioURL: audioURL, size: size, apiKey: apiKey)
            uploaded = file
            guard let uri = file["uri"] as? String else { throw ProviderError.network("Gemini did not return the uploaded audio URI") }
            audio = ["type": "audio", "mime_type": "audio/wav", "uri": uri]
        }
        do {
            let request = try Self.interactionRequest(audio: audio, settings: settings, apiKey: apiKey)
            let response = try await send(request)
            let text = try Self.transcript(from: response)
            await removeUploadedFile(uploaded, apiKey: apiKey)
            return result(text, settings, language: settings.language == .auto ? nil : settings.language.apiCode)
        } catch {
            await removeUploadedFile(uploaded, apiKey: apiKey)
            throw error
        }
    }

    static func interactionRequest(audio: [String: Any], settings: ProviderSettings, apiKey: String) throws -> URLRequest {
        var body: [String: Any] = ["model": settings.model, "input": [audio], "store": false]
        if settings.language != .auto {
            // Transcribe's locales differ from Cloud Speech's locales for these languages.
            let locale: String
            switch settings.language {
            case .chinese: locale = "cmn-Hans-CN"
            case .arabic: locale = "ar-EG"
            case .spanish: locale = "es-419"
            default: locale = settings.language.bcp47
            }
            body["generation_config"] = ["transcription_config": ["language_codes": [locale]]]
        }
        var request = URLRequest(url: URL(string: baseURL + "/interactions")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90
        return request
    }

    static func transcript(from response: [String: Any]) throws -> String {
        guard response["status"] as? String == "completed" else {
            throw ProviderError.network("Gemini transcription did not complete")
        }
        // output_text is an SDK convenience; REST returns model_output steps.
        let steps = response["steps"] as? [[String: Any]] ?? []
        let content = steps.filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
        let text = content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError.noTranscript }
        return text
    }

    static func validatedUploadURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https",
              url.host?.lowercased() == "generativelanguage.googleapis.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw ProviderError.badURL
        }
        return url
    }

    static func validFileName(_ name: String) -> Bool {
        name.range(of: "^files/[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private func upload(audioURL: URL, size: Int, apiKey: String) async throws -> [String: Any] {
        var start = URLRequest(url: URL(string: Self.origin + "/upload/v1beta/files")!)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("audio/wav", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "Dictabar recording"]])
        let initiated = try await fetch(start, bodyFile: nil)
        guard (200..<300).contains(initiated.response.statusCode) else {
            throw ProviderError.http(initiated.response.statusCode, DiagnosticsLogger.safeErrorBody(initiated.data))
        }
        guard let value = initiated.response.value(forHTTPHeaderField: "X-Goog-Upload-URL") else {
            throw ProviderError.network("Gemini did not return an upload URL")
        }
        var upload = URLRequest(url: try Self.validatedUploadURL(value))
        upload.httpMethod = "POST"
        upload.setValue(String(size), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let response = try await send(upload, bodyFile: audioURL)
        guard var file = response["file"] as? [String: Any], let name = file["name"] as? String,
              Self.validFileName(name) else {
            throw ProviderError.network("Gemini did not return uploaded file metadata")
        }
        do {
            let deadline = Date().addingTimeInterval(90)
            while file["state"] as? String == "PROCESSING" {
                guard Date() < deadline else { throw ProviderError.timedOut }
                try await Task.sleep(for: .seconds(1))
                var poll = URLRequest(url: URL(string: Self.baseURL + "/" + name)!)
                poll.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                file = try await send(poll)
            }
            if file["state"] as? String == "FAILED" { throw ProviderError.network("Gemini could not process the uploaded audio") }
            guard file["uri"] as? String != nil else { throw ProviderError.network("Gemini did not return the uploaded audio URI") }
            file["name"] = name
            return file
        } catch {
            await removeUploadedFile(["name": name], apiKey: apiKey)
            throw error
        }
    }

    private func removeUploadedFile(_ file: [String: Any]?, apiKey: String) async {
        guard let name = file?["name"] as? String,
              Self.validFileName(name),
              let url = URL(string: Self.baseURL + "/" + name) else { return }
        // Cleanup must still run if the recording task was cancelled.
        await Task.detached {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.timeoutInterval = 15
            do {
                let response = try await fetch(request, bodyFile: nil)
                if !(200..<300).contains(response.response.statusCode) {
                    DiagnosticsLogger.shared.log("gemini: uploaded audio cleanup failed")
                }
            }
            catch { DiagnosticsLogger.shared.log("gemini: uploaded audio cleanup failed") }
        }.value
    }
}
