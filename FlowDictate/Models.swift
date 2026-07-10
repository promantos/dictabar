import Carbon
import Foundation

enum SpeechProvider: String, CaseIterable, Identifiable {
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
    case custom = "Custom OpenAI-compatible"

    var id: String { rawValue }

    var models: [String] {
        switch self {
        case .openAI: ["gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1"]
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .deepgram: ["nova-3", "flux-general-multi"]
        case .mistral: ["voxtral-mini-latest", "voxtral-small-latest"]
        case .soniox: ["stt-async-preview"]
        case .gladia: ["solaria-1"]
        case .speechmatics: ["standard", "enhanced"]
        case .elevenLabs: ["scribe_v1", "scribe_v2"]
        case .assemblyAI: ["universal", "nano", "best"]
        case .openRouter: ["openai/whisper-large-v3", "openai/whisper-1", "openai/gpt-4o-mini-transcribe", "openai/gpt-4o-transcribe"]
        case .azureSpeech: ["fast-transcription"]
        case .googleCloud: ["latest_long", "latest_short", "chirp_2"]
        case .fireworks: ["whisper-v3", "whisper-v3-turbo"]
        case .together: ["openai/whisper-large-v3"]
        case .custom: ["whisper-1"]
        }
    }

    var defaultBaseURL: String {
        switch self {
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
        case .fireworks: "https://api.fireworks.ai/inference/v1"
        case .together: "https://api.together.xyz/v1"
        case .custom: "https://api.openai.com/v1"
        }
    }

    /// Shown under Base URL in Providers when non-empty.
    var baseURLHint: String? {
        switch self {
        case .azureSpeech:
            "Use your Speech resource host, e.g. https://westeurope.api.cognitive.microsoft.com"
        case .googleCloud:
            "API key goes in the key field (query param). Default host is fine for most users."
        case .openRouter, .fireworks, .together, .assemblyAI:
            nil
        default:
            nil
        }
    }
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
