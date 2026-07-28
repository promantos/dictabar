import Carbon
import Foundation

enum SpeechProvider: String, CaseIterable, Identifiable {
    case local = "Local Models"
    case openAI = "OpenAI"
    case groq = "Groq"
    case deepgram = "Deepgram"
    case mistral = "Mistral"
    case soniox = "Soniox"
    case gladia = "Gladia"
    case speechmatics = "Speechmatics"
    case elevenLabs = "ElevenLabs"
    case assemblyAI = "AssemblyAI"
    case openRouter = "OpenRouter"
    case azureSpeech = "Azure Speech"
    case googleCloud = "Google Cloud STT"
    case fireworks = "Fireworks"
    case together = "Together"
    case smallestAI = "Smallest AI"
    case alibaba = "Alibaba Model Studio"
    case xAI = "xAI"
    case amazonTranscribe = "Amazon Transcribe"
    case inworld = "Inworld"
    case cartesia = "Cartesia"
    case gradium = "Gradium"
    case modulate = "Modulate"
    case cohere = "Cohere"
    case cloudflare = "Cloudflare Workers AI"
    case custom = "Custom OpenAI-compatible"

    var id: String { rawValue }
    var requiresAPIKey: Bool { self != .local }

    /// Quick Start only: free/easy providers with a normal API key.
    static let onboarding: [SpeechProvider] = [
        .groq, .deepgram, .mistral, .elevenLabs, .gladia, .assemblyAI
    ]

    var models: [String] {
        modelInfos.map(\.id)
    }

    /// JSON-only audio APIs require base64 and therefore an unavoidable memory copy.
    /// Bound those requests; file/multipart providers retain their normal 25 MB ceiling.
    var maximumUploadBytes: Int {
        switch self {
        case .googleCloud, .alibaba, .inworld, .cloudflare:
            12 * 1024 * 1024
        default:
            25 * 1024 * 1024
        }
    }

    var modelInfos: [SpeechModelInfo] {
        switch self {
        case .local:
            LocalSpeechModel.allCases.map {
                SpeechModelInfo(
                    id: $0.rawValue,
                    languageCodes: $0.languageCodes,
                    reportedLanguageCount: $0.reportedLanguageCount
                )
            }
        case .openAI:
            modelList(["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"], LanguageCatalog.whisper)
        case .groq:
            modelList(["whisper-large-v3-turbo", "whisper-large-v3"], LanguageCatalog.whisper)
        case .deepgram:
            // Flux is realtime-only; Dictabar intentionally exposes file-capable Nova.
            modelList(["nova-3"], LanguageCatalog.deepgram)
        case .mistral:
            modelList(["voxtral-mini-latest", "voxtral-small-latest"], LanguageCatalog.voxtral)
        case .soniox:
            modelList(["stt-async-v5"], LanguageCatalog.soniox)
        case .gladia:
            modelList(["solaria-1"], LanguageCatalog.whisper)
        case .speechmatics:
            modelList(["enhanced", "standard"], LanguageCatalog.speechmatics)
        case .elevenLabs:
            modelList(["scribe_v2", "scribe_v1"], LanguageCatalog.whisper)
        case .assemblyAI:
            modelList(["universal-3-pro", "universal-2"], LanguageCatalog.assembly)
        case .openRouter:
            [
                SpeechModelInfo(id: "openai/whisper-large-v3", languageCodes: LanguageCatalog.whisper),
                SpeechModelInfo(id: "openai/whisper-large-v3-turbo", languageCodes: LanguageCatalog.whisper),
                SpeechModelInfo(id: "openai/gpt-4o-mini-transcribe", languageCodes: LanguageCatalog.whisper),
                SpeechModelInfo(id: "nvidia/parakeet-tdt-0.6b-v3", languageCodes: LanguageCatalog.parakeetEU),
                SpeechModelInfo(id: "qwen/qwen3-asr-flash-2026-02-10", languageCodes: LanguageCatalog.qwenOpenRouter),
                SpeechModelInfo(id: "x-ai/grok-stt-1.0", languageCodes: LanguageCatalog.xAI),
                SpeechModelInfo(id: "deepgram/nova-3", languageCodes: LanguageCatalog.deepgram),
                SpeechModelInfo(id: "google/chirp-3", languageCodes: LanguageCatalog.google),
                SpeechModelInfo(id: "openai/whisper-1", languageCodes: LanguageCatalog.whisper),
                SpeechModelInfo(id: "mistralai/voxtral-mini-transcribe", languageCodes: LanguageCatalog.voxtral),
                SpeechModelInfo(id: "openai/gpt-4o-transcribe", languageCodes: LanguageCatalog.whisper),
                SpeechModelInfo(id: "microsoft/mai-transcribe-1.5", languageCodes: LanguageCatalog.azureMAI15)
            ]
        case .azureSpeech:
            [
                SpeechModelInfo(id: "mai-transcribe-1.5", languageCodes: LanguageCatalog.azureMAI15, note: "Public preview"),
                SpeechModelInfo(id: "mai-transcribe-1", languageCodes: LanguageCatalog.azureMAI1, note: "Public preview"),
                SpeechModelInfo(id: "fast-transcription", languageCodes: LanguageCatalog.azureFast)
            ]
        case .googleCloud:
            modelList(["latest_long", "latest_short", "chirp_2"], LanguageCatalog.google)
        case .fireworks:
            modelList(["whisper-v3", "whisper-v3-turbo"], LanguageCatalog.whisper)
        case .together:
            modelList(["openai/whisper-large-v3"], LanguageCatalog.whisper)
        case .smallestAI:
            [
                SpeechModelInfo(id: "pulse-pro", languageCodes: ["en"], note: "Best accuracy; English only"),
                SpeechModelInfo(id: "pulse", languageCodes: LanguageCatalog.smallestPulse)
            ]
        case .alibaba:
            modelList(["qwen3-asr-flash"], LanguageCatalog.qwenASR)
        case .xAI:
            modelList(["grok-stt"], LanguageCatalog.xAI)
        case .amazonTranscribe:
            modelList(["standard-batch"], LanguageCatalog.amazon)
        case .inworld:
            modelList(["inworld/inworld-stt-1"], LanguageCatalog.inworld)
        case .cartesia:
            modelList(["ink-whisper"], LanguageCatalog.whisper)
        case .gradium:
            modelList(["default"], ["en", "fr", "de", "es", "pt"])
        case .modulate:
            modelList(["velma-2-stt-batch"], LanguageCatalog.modulate)
        case .cohere:
            modelList(["cohere-transcribe-03-2026"], ["en", "de", "fr", "it", "es", "pt", "el", "nl", "pl", "vi", "zh", "ar", "ja", "ko"])
        case .cloudflare:
            modelList(["@cf/openai/whisper-large-v3-turbo", "@cf/openai/whisper"], LanguageCatalog.whisper)
        case .custom:
            modelList(["whisper-1"], LanguageCatalog.whisper)
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .local: "https://localhost"
        case .openAI: "https://api.openai.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .deepgram: "https://api.deepgram.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .soniox: "https://api.soniox.com/v1"
        case .gladia: "https://api.gladia.io/v2"
        case .speechmatics: "https://asr.api.speechmatics.com/v2"
        case .elevenLabs: "https://api.elevenlabs.io/v1"
        case .assemblyAI: "https://api.assemblyai.com"
        case .openRouter: "https://openrouter.ai/api/v1"
        // Region is part of host — change to your Speech resource region.
        case .azureSpeech: "https://eastus.api.cognitive.microsoft.com"
        case .googleCloud: "https://speech.googleapis.com/v1"
        case .fireworks: "https://audio-prod.api.fireworks.ai/v1"
        case .together: "https://api.together.xyz/v1"
        case .smallestAI: "https://api.smallest.ai/waves/v1"
        case .alibaba: "https://dashscope-intl.aliyuncs.com"
        case .xAI: "https://api.x.ai/v1"
        // Put the S3 bucket in the path, e.g. ...amazonaws.com/my-bucket.
        case .amazonTranscribe: "https://transcribe.us-east-1.amazonaws.com/your-s3-bucket"
        case .inworld: "https://api.inworld.ai"
        case .cartesia: "https://api.cartesia.ai"
        case .gradium: "https://api.gradium.ai/api"
        case .modulate: "https://modulate-developer-apis.com/api"
        case .cohere: "https://api.cohere.com/v2"
        // Replace ACCOUNT_ID in Settings.
        case .cloudflare: "https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/ai/run"
        case .custom: "https://api.openai.com/v1"
        }
    }

    /// Host suffixes allowed for this provider's base URL (empty = any https host for custom).
    var allowedHostSuffixes: [String] {
        switch self {
        case .local: ["localhost"]
        case .openAI: ["openai.com"]
        case .groq: ["groq.com"]
        case .deepgram: ["deepgram.com"]
        case .mistral: ["mistral.ai"]
        case .soniox: ["soniox.com"]
        case .gladia: ["gladia.io"]
        case .speechmatics: ["speechmatics.com"]
        case .elevenLabs: ["elevenlabs.io"]
        case .assemblyAI: ["assemblyai.com"]
        case .openRouter: ["openrouter.ai"]
        // Azure regional hosts: *.api.cognitive.microsoft.com / *.cognitiveservices.azure.com
        case .azureSpeech: ["api.cognitive.microsoft.com", "cognitiveservices.azure.com"]
        case .googleCloud: ["googleapis.com"]
        case .fireworks: ["fireworks.ai"]
        case .together: ["together.xyz", "together.ai"]
        case .smallestAI: ["smallest.ai"]
        case .alibaba: ["aliyuncs.com"]
        case .xAI: ["x.ai"]
        case .amazonTranscribe: ["amazonaws.com"]
        case .inworld: ["inworld.ai"]
        case .cartesia: ["cartesia.ai"]
        case .gradium: ["gradium.ai"]
        case .modulate: ["modulate-developer-apis.com", "modulate.ai"]
        case .cohere: ["cohere.com", "cohere.ai"]
        case .cloudflare: ["cloudflare.com"]
        case .custom: [] // any https
        }
    }

    /// Normalize and validate a user-supplied base URL. Returns default on failure.
    func sanitizedBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return defaultBaseURL
        }
        let suffixes = allowedHostSuffixes
        if !suffixes.isEmpty {
            let ok = suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            if !ok { return defaultBaseURL }
        }
        // Rebuild without userinfo/query/fragment to avoid odd embeddings.
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port
        components.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? ""
            : "/" + url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let rebuilt = components.url?.absoluteString {
            return rebuilt.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return defaultBaseURL
    }

    /// Shown under Base URL in Providers when non-empty.
    var baseURLHint: String? {
        switch self {
        case .local:
            nil
        case .azureSpeech:
            "Use your Speech resource host, e.g. https://westeurope.api.cognitive.microsoft.com"
        case .googleCloud:
            "API key goes in the key field (query param). Default host is fine for most users."
        case .amazonTranscribe:
            "Advanced: append your S3 bucket to the regional URL. Enter credentials as ACCESS_KEY_ID:SECRET_ACCESS_KEY."
        case .cloudflare:
            "Replace ACCOUNT_ID in the URL. The key field accepts a Workers AI API token."
        case .custom:
            "HTTPS only. API key and audio are sent to this host."
        case .fireworks:
            "Dictabar selects audio-prod for whisper-v3 and audio-turbo for whisper-v3-turbo."
        case .alibaba:
            "The Base URL and pay-as-you-go API key must use the same region: Singapore uses dashscope-intl; Beijing uses dashscope."
        case .openRouter, .together, .assemblyAI:
            nil
        default:
            nil
        }
    }

    var group: ProviderGroup {
        switch self {
        case .local:
            .local
        case .groq, .deepgram, .mistral, .elevenLabs, .gladia, .speechmatics,
                .assemblyAI, .soniox, .cartesia, .gradium, .modulate, .cohere,
                .smallestAI, .inworld:
            .freeEasy
        case .openAI, .xAI:
            .paidEasy
        case .openRouter, .fireworks, .together, .custom:
            .routers
        case .googleCloud, .azureSpeech, .amazonTranscribe, .alibaba, .cloudflare:
            .cloud
        }
    }

    /// Providers in picker order within each group (nicest first).
    static func providers(in group: ProviderGroup) -> [SpeechProvider] {
        let order: [SpeechProvider]
        switch group {
        case .local:
            order = [.local]
        case .freeEasy:
            order = [
                .groq, .deepgram, .mistral, .elevenLabs, .gladia, .speechmatics,
                .assemblyAI, .soniox, .cartesia, .gradium, .modulate, .cohere,
                .smallestAI, .inworld
            ]
        case .paidEasy:
            order = [.openAI, .xAI]
        case .routers:
            order = [.openRouter, .fireworks, .together, .custom]
        case .cloud:
            order = [.googleCloud, .azureSpeech, .cloudflare, .alibaba, .amazonTranscribe]
        }
        return order.filter { $0.group == group }
    }

    var freeTier: String {
        switch self {
        case .local: "No API key · audio stays on this Mac"
        case .groq: "Free limits"
        case .deepgram: "$200 trial credit"
        case .mistral: "Free experimental tier"
        case .soniox: "$10 trial credit"
        case .gladia: "10 h / month"
        case .speechmatics: "8 h / month"
        case .elevenLabs: "Free monthly credits"
        case .assemblyAI: "$50 trial credit"
        case .azureSpeech: "Azure free account credit"
        case .googleCloud: "60 min / month"
        case .fireworks: "Trial credit"
        case .together: "Trial credit"
        case .smallestAI: "$10 signup credit"
        case .alibaba: "10 h / model for 90 days"
        case .amazonTranscribe: "60 min / month for 12 months"
        case .inworld: "Starter allowance"
        case .cartesia: "20K credits / month"
        case .gradium: "45K credits / month"
        case .modulate: "Free credits"
        case .cohere: "Free trial key"
        case .cloudflare: "10K neurons / day"
        case .openAI, .xAI, .openRouter, .custom: "Paid"
        }
    }

    var setupLabel: String {
        switch self {
        case .local: "On-device"
        case .amazonTranscribe: "Advanced"
        case .azureSpeech, .googleCloud, .alibaba, .cloudflare: "Cloud setup"
        case .custom: "Custom"
        default: "Easy"
        }
    }

    var keyURL: URL {
        let value: String
        switch self {
        case .local: value = "https://github.com/soniqo/speech-swift"
        case .openAI: value = "https://platform.openai.com/api-keys"
        case .groq: value = "https://console.groq.com/keys"
        case .deepgram: value = "https://console.deepgram.com/"
        case .mistral: value = "https://console.mistral.ai/api-keys/"
        case .soniox: value = "https://console.soniox.com/"
        case .gladia: value = "https://app.gladia.io/"
        case .speechmatics: value = "https://portal.speechmatics.com/"
        case .elevenLabs: value = "https://elevenlabs.io/app/settings/api-keys"
        case .assemblyAI: value = "https://www.assemblyai.com/dashboard/"
        case .openRouter: value = "https://openrouter.ai/settings/keys"
        case .azureSpeech: value = "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices"
        case .googleCloud: value = "https://console.cloud.google.com/apis/credentials"
        case .fireworks: value = "https://fireworks.ai/account/api-keys"
        case .together: value = "https://api.together.ai/settings/api-keys"
        case .smallestAI: value = "https://waves.smallest.ai/"
        case .alibaba: value = "https://modelstudio.console.alibabacloud.com/"
        case .xAI: value = "https://console.x.ai/"
        case .amazonTranscribe: value = "https://console.aws.amazon.com/iam/home#/security_credentials"
        case .inworld: value = "https://platform.inworld.ai/"
        case .cartesia: value = "https://play.cartesia.ai/keys"
        case .gradium: value = "https://gradium.ai/"
        case .modulate: value = "https://platform.modulate.ai/"
        case .cohere: value = "https://dashboard.cohere.com/api-keys"
        case .cloudflare: value = "https://dash.cloudflare.com/profile/api-tokens"
        case .custom: value = "https://platform.openai.com/api-keys"
        }
        return URL(string: value)!
    }

    var summary: String {
        switch self {
        case .local: "On-device transcription. Audio is not uploaded."
        case .amazonTranscribe: "Reliable batch transcription through your S3 bucket."
        case .cloudflare: "Low-cost Whisper inference on Workers AI."
        case .smallestAI: "Fast file transcription; Pulse Pro is tuned for English."
        case .xAI: "Simple file STT with keyterm prompting."
        case .cohere: "New multilingual file transcription API."
        default: "File-based speech-to-text for completed dictation recordings."
        }
    }

    private func modelList(_ ids: [String], _ languages: [String]) -> [SpeechModelInfo] {
        ids.map { SpeechModelInfo(id: $0, languageCodes: languages) }
    }
}

enum ProviderGroup: String, CaseIterable, Identifiable {
    case local = "On-device"
    case freeEasy = "Free & trial · easy setup"
    case paidEasy = "Paid · simple API key"
    case routers = "Aggregators & custom"
    case cloud = "Cloud platforms · advanced"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .local: L10n.t("prov.group.local")
        case .freeEasy: L10n.t("prov.group.free")
        case .paidEasy: L10n.t("prov.group.paid")
        case .routers: L10n.t("prov.group.routers")
        case .cloud: L10n.t("prov.group.cloud")
        }
    }
}

struct SpeechModelInfo: Identifiable, Hashable {
    let id: String
    let languageCodes: [String]
    var note: String? = nil
    var reportedLanguageCount: String? = nil

    var languageCountText: String {
        reportedLanguageCount ?? String(languageCodes.count)
    }

    var languageNames: [String] {
        languageCodes.map { code in
            let normalized = code.split(separator: "-").first.map(String.init) ?? code
            let name = Locale.current.localizedString(forLanguageCode: normalized) ?? code
            return "\(name) · \(code)"
        }
    }
}

enum LocalSpeechModel: String, CaseIterable, Identifiable {
    case parakeet = "Parakeet TDT 0.6B v3"
    case nemotron = "Nemotron 3.5 ASR"
    case qwen = "Qwen3-ASR 0.6B"
    case moss = "MOSS-Transcribe-Diarize 0.9B (INT5)"

    var id: String { rawValue }

    var modelID: String {
        switch self {
        case .parakeet: "aufklarer/Parakeet-TDT-v3-CoreML-INT8-30s"
        case .nemotron: "aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8"
        case .qwen: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .moss: "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-5bit"
        }
    }

    var approximateSize: String {
        switch self {
        case .parakeet: "≈ 1.2 GB"
        case .nemotron: "≈ 0.8 GB"
        case .qwen: "≈ 0.7 GB"
        case .moss: "≈ 1.0 GB"
        }
    }

    var detail: String {
        switch self {
        case .parakeet: L10n.t("local.parakeet")
        case .nemotron: L10n.t("local.nemotron")
        case .qwen: L10n.t("local.qwen")
        case .moss: L10n.t("local.moss")
        }
    }

    var languageCodes: [String] {
        switch self {
        case .parakeet: LanguageCatalog.parakeetLocal
        case .nemotron: LanguageCatalog.nemotronLocal
        case .qwen: LanguageCatalog.qwenLocal
        case .moss: []
        }
    }

    var reportedLanguageCount: String? {
        self == .moss ? "50+" : nil
    }

    static func named(_ value: String) -> LocalSpeechModel {
        LocalSpeechModel(rawValue: value) ?? .parakeet
    }
}

private enum LanguageCatalog {
    static let whisper = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
        "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht",
        "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt",
        "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl",
        "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw", "ta",
        "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh"
    ]
    static let deepgram = ["ar", "be", "bn", "bs", "bg", "ca", "yue", "zh", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "gu", "he", "hi", "hu", "id", "it", "ja", "kn", "ko", "lv", "lt", "mk", "ms", "mr", "no", "fa", "pl", "pt", "ro", "ru", "sr", "sk", "sl", "es", "sv", "tl", "ta", "te", "th", "tr", "uk", "ur", "vi"]
    static let voxtral = ["ar", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "he", "hi", "hu", "id", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sv", "ta", "tr", "uk", "vi", "zh"]
    static let soniox = whisper
    static let speechmatics = whisper
    static let assembly = ["en", "es", "fr", "de", "it", "pt", "nl", "hi", "ja", "zh", "fi", "ko", "pl", "ru", "tr", "uk", "vi"]
    static let azureMAI1 = ["ar", "zh", "cs", "da", "nl", "en", "fi", "fr", "de", "hi", "hu", "id", "it", "ja", "ko", "nb", "pl", "pt", "ro", "ru", "es", "sv", "th", "tr", "vi"]
    static let azureMAI15 = ["ar", "as", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "gu", "hi", "hu", "id", "it", "ja", "kn", "ko", "lt", "ml", "mr", "nb", "nl", "or", "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "ta", "te", "th", "tr", "uk", "vi", "zh"]
    static let azureFast = whisper
    static let google = whisper
    static let parakeetLocal = ["en", "es", "fr", "de", "bg", "hr", "cs", "da", "nl", "et", "fi", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "sv", "ru", "uk"]
    static let nemotronLocal = ["ar", "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "he", "hi", "hr", "hu", "it", "ja", "ko", "lt", "lv", "mt", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "th", "tr", "uk", "vi", "zh"]
    static let qwenLocal = ["zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "ro", "hu", "mk"]
    static let parakeetEU = parakeetLocal
    static let qwenOpenRouter = ["ar", "de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh"]
    static let smallestPulse = ["en", "hi", "de", "es", "ru", "it", "fr", "nl", "pt", "uk", "pl", "cs", "sk", "lv", "et", "ro", "fi", "sv", "bg", "hu", "da", "lt", "mt", "zh", "ja", "ko"]
    static let qwenASR = ["ar", "bn", "ca", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fr", "gu", "he", "hi", "hu", "id", "it", "ja", "ko", "lt", "ml", "mr", "nl", "no", "pa", "pl", "pt", "ro", "ru", "sk", "sv", "ta", "te", "th", "tr", "uk", "ur", "vi", "yue", "zh"]
    static let xAI = ["ar", "cs", "da", "de", "en", "es", "fi", "fr", "hi", "hu", "id", "it", "ja", "ko", "nl", "no", "pl", "pt", "ro", "ru", "sv", "th", "tr", "vi", "zh"]
    static let amazon = whisper
    static let inworld = ["ar", "de", "en", "es", "fr", "hi", "it", "ja", "ko", "nl", "pl", "pt", "ru", "tr", "uk", "vi", "zh"]
    static let modulate = ["af", "ar", "bg", "bn", "ca", "cs", "cy", "da", "de", "el", "en", "es", "et", "fa", "fi", "fr", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "ko", "lt", "lv", "mk", "ml", "mr", "ms", "nl", "no", "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur", "vi", "zh"]
}

/// Speech recognition language (sent to providers). Default is auto / same as spoken.
enum OutputLanguage: String, CaseIterable, Identifiable {
    case auto = "Same as spoken"
    case english = "English"
    case chinese = "Chinese (Simplified)"
    case spanish = "Spanish"
    case hindi = "Hindi"
    case arabic = "Arabic"
    case portuguese = "Portuguese"
    case bengali = "Bengali"
    case russian = "Russian"
    case japanese = "Japanese"
    case french = "French"
    case german = "German"
    case korean = "Korean"
    case italian = "Italian"
    case turkish = "Turkish"
    case vietnamese = "Vietnamese"
    case polish = "Polish"
    case ukrainian = "Ukrainian"
    case dutch = "Dutch"
    case indonesian = "Indonesian"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .auto: L10n.t("lang.auto")
        case .english: L10n.t("lang.en")
        case .chinese: L10n.t("lang.zh")
        case .spanish: L10n.t("lang.es")
        case .hindi: L10n.t("lang.hi")
        case .arabic: L10n.t("lang.ar")
        case .portuguese: L10n.t("lang.pt")
        case .bengali: L10n.t("lang.bn")
        case .russian: L10n.t("lang.ru")
        case .japanese: L10n.t("lang.ja")
        case .french: L10n.t("lang.fr")
        case .german: L10n.t("lang.de")
        case .korean: L10n.t("lang.ko")
        case .italian: L10n.t("lang.it")
        case .turkish: L10n.t("lang.tr")
        case .vietnamese: L10n.t("lang.vi")
        case .polish: L10n.t("lang.pl")
        case .ukrainian: L10n.t("lang.uk")
        case .dutch: L10n.t("lang.nl")
        case .indonesian: L10n.t("lang.id")
        }
    }

    /// ISO code for APIs; nil means let the provider detect.
    var apiCode: String? {
        switch self {
        case .auto: nil
        case .english: "en"
        case .chinese: "zh"
        case .spanish: "es"
        case .hindi: "hi"
        case .arabic: "ar"
        case .portuguese: "pt"
        case .bengali: "bn"
        case .russian: "ru"
        case .japanese: "ja"
        case .french: "fr"
        case .german: "de"
        case .korean: "ko"
        case .italian: "it"
        case .turkish: "tr"
        case .vietnamese: "vi"
        case .polish: "pl"
        case .ukrainian: "uk"
        case .dutch: "nl"
        case .indonesian: "id"
        }
    }

    /// BCP-47 style locale for Azure / Google when a specific language is chosen.
    var bcp47: String {
        switch self {
        case .auto: "en-US"
        case .english: "en-US"
        case .chinese: "zh-CN"
        case .spanish: "es-ES"
        case .hindi: "hi-IN"
        case .arabic: "ar-SA"
        case .portuguese: "pt-BR"
        case .bengali: "bn-IN"
        case .russian: "ru-RU"
        case .japanese: "ja-JP"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .korean: "ko-KR"
        case .italian: "it-IT"
        case .turkish: "tr-TR"
        case .vietnamese: "vi-VN"
        case .polish: "pl-PL"
        case .ukrainian: "uk-UA"
        case .dutch: "nl-NL"
        case .indonesian: "id-ID"
        }
    }
}

enum ShortcutMode: String, CaseIterable, Identifiable {
    case toggle = "Press once to start, press again to stop"
    case hold = "Hold to dictate"
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .toggle: L10n.t("mode.toggle")
        case .hold: L10n.t("mode.hold")
        }
    }
}

/// Only right-side modifiers (left ⌘/⌥ are common OS hotkeys) + custom.
enum ShortcutPreset: String, CaseIterable, Identifiable {
    case rightCommand = "Right Command"
    case rightOption = "Right Option"
    case custom = "Custom shortcut"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .rightCommand: L10n.t("preset.rightCommand")
        case .rightOption: L10n.t("preset.rightOption")
        case .custom: L10n.t("preset.custom")
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .custom: nil
        }
    }

    var needsInputMonitoring: Bool { self != .custom }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case paste = "Paste via clipboard"
    case typing = "Simulated typing (no clipboard)"
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .paste: L10n.t("insert.paste")
        case .typing: L10n.t("insert.typing")
        }
    }
}

enum OverlayPosition: String, CaseIterable, Identifiable {
    case topCenter = "Top center"
    case topLeft = "Top left"
    case topRight = "Top right"
    case bottomCenter = "Bottom center"
    case bottomLeft = "Bottom left"
    case bottomRight = "Bottom right"
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .topCenter: L10n.t("pos.topCenter")
        case .topLeft: L10n.t("pos.topLeft")
        case .topRight: L10n.t("pos.topRight")
        case .bottomCenter: L10n.t("pos.bottomCenter")
        case .bottomLeft: L10n.t("pos.bottomLeft")
        case .bottomRight: L10n.t("pos.bottomRight")
        }
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .system: L10n.t("appearance.system")
        case .light: L10n.t("appearance.light")
        case .dark: L10n.t("appearance.dark")
        }
    }
}

struct KeyboardShortcut: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let defaultDictation = KeyboardShortcut(keyCode: 2, carbonModifiers: UInt32(cmdKey | optionKey), display: "Option-Command-D")
    static let escape = KeyboardShortcut(keyCode: 53, carbonModifiers: 0, display: "Escape")
}

struct TranscriptionResult: Sendable {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval?
    let providerName: String
    let modelName: String
}

protocol TranscriptionProvider: Sendable {
    func transcribe(audioURL: URL, settings: ProviderSettings, apiKey: String) async throws -> TranscriptionResult
}

struct ProviderSettings: Sendable {
    var provider: SpeechProvider
    var model: String
    var baseURL: String
    var language: OutputLanguage
    var deepgramSmartFormat: Bool
    var deepgramNumerals: Bool
    var deepgramPunctuation: Bool
    var gladiaCodeSwitching: Bool
    var punctuation: Bool
}
