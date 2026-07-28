import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var provider: SpeechProvider {
        didSet {
            saveProviderFields(for: oldValue)
            normalizeModelAndBaseURL()
            // Load key for the new provider without writing back on every switch.
            apiKey = LocalSecretStore.read(provider: provider)
            if provider != .local {
                LocalModelManager.shared.unload()
            }
            save()
        }
    }
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: Self.modelKey(provider))
            defaults.set(model, forKey: "model")
            if provider == .local, let localModel = LocalSpeechModel(rawValue: model) {
                LocalModelManager.shared.select(localModel)
            }
        }
    }
    @Published var baseURL: String {
        didSet {
            defaults.set(baseURL, forKey: Self.baseURLKey(provider))
            defaults.set(baseURL, forKey: "baseURL")
        }
    }
    @Published var language: OutputLanguage { didSet { save() } }
    @Published var launchAtLogin: Bool { didSet { save() } }
    @Published var showMenuBarIcon: Bool { didSet { save() } }
    @Published var playSounds: Bool { didSet { save() } }
    /// Keep last N transcripts on disk (local only).
    @Published var saveTranscriptHistory: Bool { didSet { save() } }
    @Published var showRecordingOverlay: Bool { didSet { save() } }
    @Published var privatePreview: Bool { didSet { save() } }
    @Published var muteWhileRecording: Bool { didSet { save() } }
    @Published var selectedMicrophoneID: String { didSet { save() } }
    @Published var shortcutPreset: ShortcutPreset { didSet { save() } }
    @Published var shortcutMode: ShortcutMode { didSet { save() } }
    @Published var shortcut: KeyboardShortcut { didSet { save() } }
    @Published var cancelShortcut: KeyboardShortcut { didSet { save() } }
    @Published var minimumRecordingDuration: Double { didSet { save() } }
    @Published var maximumRecordingDuration: Double { didSet { save() } }
    @Published var autoInsert: Bool { didSet { save() } }
    @Published var insertionMethod: InsertionMethod { didSet { save() } }
    @Published var preserveClipboard: Bool { didSet { save() } }
    @Published var addTrailingSpace: Bool { didSet { save() } }
    @Published var addTrailingNewline: Bool { didSet { save() } }
    @Published var copyOnInsertionFailure: Bool { didSet { save() } }
    @Published var appearanceMode: AppAppearanceMode { didSet { save() } }
    @Published var uiLanguage: AppUILanguage {
        didSet {
            L10n.code = uiLanguage.resolvedCode
            save()
        }
    }
    @Published var overlayPosition: OverlayPosition { didSet { save() } }
    @Published var showTimer: Bool { didSet { save() } }
    @Published var showProviderInOverlay: Bool { didSet { save() } }
    @Published var showMicrophoneInOverlay: Bool { didSet { save() } }
    @Published var showTranscriptPreview: Bool { didSet { save() } }
    @Published var automaticallyCheckUpdates: Bool { didSet { save() } }
    @Published var includePrereleases: Bool { didSet { save() } }
    @Published var debugMode: Bool { didSet { save() } }
    @Published var deepgramSmartFormat: Bool { didSet { save() } }
    @Published var deepgramNumerals: Bool { didSet { save() } }
    @Published var deepgramPunctuation: Bool { didSet { save() } }
    @Published var gladiaCodeSwitching: Bool { didSet { save() } }
    @Published var punctuation: Bool { didSet { save() } }
    /// Draft field for the SecureField. Persisted only via `saveAPIKey()` / Clear.
    @Published var apiKey: String = ""

    private let defaults = UserDefaults.standard
    private let keys = [
        "provider", "model", "baseURL", "language", "launchAtLogin", "showMenuBarIcon",
        "playSounds", "saveTranscriptHistory",
        "showRecordingOverlay", "privatePreview", "muteWhileRecording", "selectedMicrophoneID",
        "shortcutPreset", "shortcutKeyCode", "shortcutModifiers", "shortcutDisplay", "shortcutMode", "minimumRecordingDuration",
        "maximumRecordingDuration", "autoInsert", "insertionMethod", "preserveClipboard", "addTrailingSpace",
        "addTrailingNewline", "copyOnInsertionFailure", "appearanceMode", "uiLanguage", "overlayPosition", "showTimer",
        "showProviderInOverlay", "showMicrophoneInOverlay", "showTranscriptPreview", "automaticallyCheckUpdates",
        "includePrereleases", "debugMode", "deepgramSmartFormat",
        "deepgramNumerals", "deepgramPunctuation", "gladiaCodeSwitching", "punctuation",
        "cancelShortcutKeyCode", "cancelShortcutModifiers", "cancelShortcutDisplay"
    ]

    init() {
        let savedProvider = SpeechProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openAI
        if defaults.object(forKey: Self.modelKey(savedProvider)) == nil, let savedModel = defaults.string(forKey: "model") {
            defaults.set(savedModel, forKey: Self.modelKey(savedProvider))
        }
        if defaults.object(forKey: Self.baseURLKey(savedProvider)) == nil, let savedBaseURL = defaults.string(forKey: "baseURL") {
            defaults.set(savedBaseURL, forKey: Self.baseURLKey(savedProvider))
        }
        provider = savedProvider
        model = defaults.string(forKey: "model") ?? savedProvider.models[0]
        baseURL = defaults.string(forKey: "baseURL") ?? savedProvider.defaultBaseURL
        language = OutputLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        launchAtLogin = LaunchAtLoginService.isEnabled
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        playSounds = defaults.bool(forKey: "playSounds")
        saveTranscriptHistory = defaults.object(forKey: "saveTranscriptHistory") as? Bool ?? true
        showRecordingOverlay = defaults.object(forKey: "showRecordingOverlay") as? Bool ?? true
        privatePreview = defaults.object(forKey: "privatePreview") as? Bool ?? false
        muteWhileRecording = defaults.object(forKey: "muteWhileRecording") as? Bool ?? true
        selectedMicrophoneID = defaults.string(forKey: "selectedMicrophoneID") ?? ""
        let rawPreset = defaults.string(forKey: "shortcutPreset") ?? ""
        // Migrate removed left-side presets → Right Command.
        if rawPreset == "Left Option" || rawPreset == "Left Control" {
            shortcutPreset = .rightCommand
        } else {
            shortcutPreset = ShortcutPreset(rawValue: rawPreset) ?? .rightCommand
        }
        shortcutMode = ShortcutMode(rawValue: defaults.string(forKey: "shortcutMode") ?? "") ?? .toggle
        var savedShortcut = KeyboardShortcut(
            keyCode: UInt32(defaults.integer(forKey: "shortcutKeyCode")),
            carbonModifiers: UInt32(defaults.integer(forKey: "shortcutModifiers")),
            display: defaults.string(forKey: "shortcutDisplay") ?? KeyboardShortcut.defaultDictation.display
        )
        if savedShortcut.display == KeyboardShortcut.defaultDictation.display && savedShortcut.keyCode == 0 {
            savedShortcut = .defaultDictation
        }
        shortcut = savedShortcut
        if defaults.object(forKey: "cancelShortcutKeyCode") != nil {
            cancelShortcut = KeyboardShortcut(
                keyCode: UInt32(defaults.integer(forKey: "cancelShortcutKeyCode")),
                carbonModifiers: UInt32(defaults.integer(forKey: "cancelShortcutModifiers")),
                display: defaults.string(forKey: "cancelShortcutDisplay") ?? KeyboardShortcut.escape.display
            )
        } else {
            cancelShortcut = .escape
        }
        minimumRecordingDuration = defaults.object(forKey: "minimumRecordingDuration") as? Double ?? 0.2
        // Default 10 minutes for first-run; user choice is persisted afterwards.
        maximumRecordingDuration = defaults.object(forKey: "maximumRecordingDuration") as? Double ?? 600
        autoInsert = defaults.object(forKey: "autoInsert") as? Bool ?? true
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: "insertionMethod") ?? "") ?? .paste
        preserveClipboard = defaults.object(forKey: "preserveClipboard") as? Bool ?? true
        addTrailingSpace = defaults.object(forKey: "addTrailingSpace") as? Bool ?? true
        addTrailingNewline = defaults.bool(forKey: "addTrailingNewline")
        copyOnInsertionFailure = defaults.object(forKey: "copyOnInsertionFailure") as? Bool ?? false
        appearanceMode = AppAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        uiLanguage = AppUILanguage(rawValue: defaults.string(forKey: "uiLanguage") ?? "") ?? .system
        overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: "overlayPosition") ?? "") ?? .topCenter
        showTimer = defaults.object(forKey: "showTimer") as? Bool ?? true
        showProviderInOverlay = defaults.object(forKey: "showProviderInOverlay") as? Bool ?? true
        showMicrophoneInOverlay = defaults.object(forKey: "showMicrophoneInOverlay") as? Bool ?? true
        showTranscriptPreview = defaults.bool(forKey: "showTranscriptPreview")
        automaticallyCheckUpdates = defaults.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true
        includePrereleases = defaults.bool(forKey: "includePrereleases")
        debugMode = defaults.bool(forKey: "debugMode")
        deepgramSmartFormat = defaults.object(forKey: "deepgramSmartFormat") as? Bool ?? true
        deepgramNumerals = defaults.object(forKey: "deepgramNumerals") as? Bool ?? true
        deepgramPunctuation = defaults.object(forKey: "deepgramPunctuation") as? Bool ?? true
        gladiaCodeSwitching = defaults.object(forKey: "gladiaCodeSwitching") as? Bool ?? true
        punctuation = defaults.object(forKey: "punctuation") as? Bool ?? true
        // Load the local key only when the user opens Providers or starts transcription.
        apiKey = ""
        normalizeModelAndBaseURL()
        L10n.code = uiLanguage.resolvedCode
    }

    var providerSettings: ProviderSettings {
        providerSettings(for: provider)
    }

    func providerSettings(for provider: SpeechProvider) -> ProviderSettings {
        let savedModel = defaults.string(forKey: Self.modelKey(provider))
        let resolvedModel = savedModel.flatMap { provider.models.contains($0) ? $0 : nil }
            ?? provider.models[0]
        let savedBaseURL = defaults.string(forKey: Self.baseURLKey(provider))
            ?? provider.defaultBaseURL
        let providerDefaults = SpeechProvider.allCases.map(\.defaultBaseURL)
        let candidate = savedBaseURL.isEmpty
            || (providerDefaults.contains(savedBaseURL) && savedBaseURL != provider.defaultBaseURL)
            ? provider.defaultBaseURL
            : savedBaseURL

        return ProviderSettings(
            provider: provider,
            model: resolvedModel,
            // Always send a validated https URL to the network layer.
            baseURL: provider.sanitizedBaseURL(candidate),
            language: language,
            deepgramSmartFormat: deepgramSmartFormat,
            deepgramNumerals: deepgramNumerals,
            deepgramPunctuation: deepgramPunctuation,
            gladiaCodeSwitching: gladiaCodeSwitching,
            punctuation: punctuation
        )
    }

    func saveAPIKey() throws {
        try LocalSecretStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider)
    }

    func loadAPIKey() {
        apiKey = LocalSecretStore.read(provider: provider)
    }

    func apiKeyForTranscription() -> String {
        if !provider.requiresAPIKey { return "" }
        let current = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            // Persist a draft if the user typed it but forgot Save.
            if current != LocalSecretStore.read(provider: provider) {
                do {
                    try LocalSecretStore.save(current, provider: provider)
                } catch {
                    DiagnosticsLogger.shared.log("local secrets: autosave failed \(error.localizedDescription)")
                    // Keep the current in-memory key usable for this request; explicit Save still
                    // reports persistence failures to the user.
                    return current
                }
            }
            return current
        }
        let stored = LocalSecretStore.read(provider: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = stored
        return stored
    }

    func clearAPIKey() {
        apiKey = ""
        do {
            try LocalSecretStore.save("", provider: provider)
        } catch {
            DiagnosticsLogger.shared.log("local secrets: clear failed \(error.localizedDescription)")
        }
    }

    func resetAll() {
        keys.forEach(defaults.removeObject(forKey:))
        SpeechProvider.allCases.forEach {
            defaults.removeObject(forKey: Self.modelKey($0))
            defaults.removeObject(forKey: Self.baseURLKey($0))
        }
        LocalSecretStore.clearAll()
        // Re-apply factory defaults into live @Published fields (defaults alone leave UI stale).
        provider = .openAI
        model = SpeechProvider.openAI.models[0]
        baseURL = SpeechProvider.openAI.defaultBaseURL
        language = .auto
        // Keep OS launch-at-login state; only re-sync the toggle.
        launchAtLogin = LaunchAtLoginService.isEnabled
        showMenuBarIcon = true
        playSounds = false
        saveTranscriptHistory = true
        showRecordingOverlay = true
        privatePreview = false
        muteWhileRecording = true
        selectedMicrophoneID = ""
        shortcutPreset = .rightCommand
        shortcutMode = .toggle
        shortcut = .defaultDictation
        cancelShortcut = .escape
        minimumRecordingDuration = 0.2
        maximumRecordingDuration = 600
        autoInsert = true
        insertionMethod = .paste
        preserveClipboard = true
        addTrailingSpace = true
        addTrailingNewline = false
        copyOnInsertionFailure = false
        appearanceMode = .system
        uiLanguage = .system
        overlayPosition = .topCenter
        showTimer = true
        showProviderInOverlay = true
        showMicrophoneInOverlay = true
        showTranscriptPreview = false
        automaticallyCheckUpdates = true
        includePrereleases = false
        debugMode = false
        deepgramSmartFormat = true
        deepgramNumerals = true
        deepgramPunctuation = true
        gladiaCodeSwitching = true
        punctuation = true
        apiKey = ""
        normalizeModelAndBaseURL()
        L10n.code = uiLanguage.resolvedCode
        TranscriptHistoryStore.shared.clear()
    }

    private func normalizeModelAndBaseURL() {
        let savedModel = defaults.string(forKey: Self.modelKey(provider)) ?? model
        model = provider.models.contains(savedModel) ? savedModel : provider.models[0]
        let savedBaseURL = defaults.string(forKey: Self.baseURLKey(provider)) ?? provider.defaultBaseURL
        let providerDefaults = SpeechProvider.allCases.map(\.defaultBaseURL)
        let candidate = savedBaseURL.isEmpty || (providerDefaults.contains(savedBaseURL) && savedBaseURL != provider.defaultBaseURL)
            ? provider.defaultBaseURL
            : savedBaseURL
        baseURL = provider.sanitizedBaseURL(candidate)
        defaults.set(baseURL, forKey: Self.baseURLKey(provider))
    }

    private func saveProviderFields(for provider: SpeechProvider) {
        defaults.set(model, forKey: Self.modelKey(provider))
        defaults.set(baseURL, forKey: Self.baseURLKey(provider))
    }

    private static func modelKey(_ provider: SpeechProvider) -> String {
        "model.\(provider.rawValue)"
    }

    private static func baseURLKey(_ provider: SpeechProvider) -> String {
        "baseURL.\(provider.rawValue)"
    }

    private func save() {
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(model, forKey: "model")
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon")
        defaults.set(playSounds, forKey: "playSounds")
        defaults.set(saveTranscriptHistory, forKey: "saveTranscriptHistory")
        defaults.set(showRecordingOverlay, forKey: "showRecordingOverlay")
        defaults.set(privatePreview, forKey: "privatePreview")
        defaults.set(muteWhileRecording, forKey: "muteWhileRecording")
        defaults.set(selectedMicrophoneID, forKey: "selectedMicrophoneID")
        defaults.set(shortcutPreset.rawValue, forKey: "shortcutPreset")
        defaults.set(Int(shortcut.keyCode), forKey: "shortcutKeyCode")
        defaults.set(Int(shortcut.carbonModifiers), forKey: "shortcutModifiers")
        defaults.set(shortcut.display, forKey: "shortcutDisplay")
        defaults.set(shortcutMode.rawValue, forKey: "shortcutMode")
        defaults.set(Int(cancelShortcut.keyCode), forKey: "cancelShortcutKeyCode")
        defaults.set(Int(cancelShortcut.carbonModifiers), forKey: "cancelShortcutModifiers")
        defaults.set(cancelShortcut.display, forKey: "cancelShortcutDisplay")
        defaults.set(minimumRecordingDuration, forKey: "minimumRecordingDuration")
        defaults.set(maximumRecordingDuration, forKey: "maximumRecordingDuration")
        defaults.set(autoInsert, forKey: "autoInsert")
        defaults.set(insertionMethod.rawValue, forKey: "insertionMethod")
        defaults.set(preserveClipboard, forKey: "preserveClipboard")
        defaults.set(addTrailingSpace, forKey: "addTrailingSpace")
        defaults.set(addTrailingNewline, forKey: "addTrailingNewline")
        defaults.set(copyOnInsertionFailure, forKey: "copyOnInsertionFailure")
        defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
        defaults.set(uiLanguage.rawValue, forKey: "uiLanguage")
        defaults.set(overlayPosition.rawValue, forKey: "overlayPosition")
        defaults.set(showTimer, forKey: "showTimer")
        defaults.set(showProviderInOverlay, forKey: "showProviderInOverlay")
        defaults.set(showMicrophoneInOverlay, forKey: "showMicrophoneInOverlay")
        defaults.set(showTranscriptPreview, forKey: "showTranscriptPreview")
        defaults.set(automaticallyCheckUpdates, forKey: "automaticallyCheckUpdates")
        defaults.set(includePrereleases, forKey: "includePrereleases")
        defaults.set(debugMode, forKey: "debugMode")
        defaults.set(deepgramSmartFormat, forKey: "deepgramSmartFormat")
        defaults.set(deepgramNumerals, forKey: "deepgramNumerals")
        defaults.set(deepgramPunctuation, forKey: "deepgramPunctuation")
        defaults.set(gladiaCodeSwitching, forKey: "gladiaCodeSwitching")
        defaults.set(punctuation, forKey: "punctuation")
    }
}
