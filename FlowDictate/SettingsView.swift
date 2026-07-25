import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var microphones: MicrophoneDeviceManager
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var permissionCenter = PermissionCenter.shared

    @State private var keySavedFlash = false
    @State private var showingLanguages = false
    @State private var languageSearch = ""
    /// Forces full tree refresh when UI language changes.
    @State private var langToken = UUID()

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding(
                get: {
                    let raw = appState.selectedSettingsSection
                    if raw == "Appearance" { return SettingsSection.general.rawValue }
                    return raw
                },
                set: { appState.selectedSettingsSection = $0 ?? SettingsSection.general.rawValue }
            )) { item in
                HStack {
                    Label(item.localizedTitle, systemImage: item.icon)
                    if item == .permissions, !permissionCenter.requiredReady {
                        Spacer(minLength: 4)
                        Circle().fill(.orange).frame(width: 8, height: 8)
                    }
                }
                .tag(item.rawValue)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if currentSection != .permissions {
                        Text(currentSection.localizedTitle).font(.largeTitle.bold())
                    }
                    content
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(width: 1020, height: 720)
        .id(langToken)
        .background(ShortcutCapture(isRecording: Binding(
            get: { appState.recordingShortcut },
            set: { appState.recordingShortcut = $0 }
        )) { shortcut in
            settingsStore.shortcut = shortcut
        })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionCenter.refresh()
        }
        .onChange(of: settingsStore.uiLanguage) { _, lang in
            L10n.code = lang.resolvedCode
            langToken = UUID()
        }
        .onChange(of: appState.selectedSettingsSection) { _, section in
            if section == SettingsSection.providers.rawValue {
                settingsStore.loadAPIKey()
            }
        }
        .onAppear {
            L10n.code = settingsStore.uiLanguage.resolvedCode
            permissionCenter.refresh()
            microphones.refresh()
            if appState.selectedSettingsSection == "Appearance" {
                appState.selectedSettingsSection = SettingsSection.general.rawValue
            }
            if currentSection == .providers {
                settingsStore.loadAPIKey()
            }
        }
    }

    private var currentSection: SettingsSection {
        SettingsSection(rawValue: appState.selectedSettingsSection) ?? .general
    }

    @ViewBuilder
    private var content: some View {
        switch currentSection {
        case .general: general
        case .dictation: dictation
        case .providers: providers
        case .permissions: permissions
        case .updates: updates
        case .advanced: advanced
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(L10n.t("general.app")) {
                Toggle(L10n.t("general.launchAtLogin"), isOn: Binding(
                    get: { settingsStore.launchAtLogin },
                    set: { value in
                        do {
                            try LaunchAtLoginService.setEnabled(value)
                            settingsStore.launchAtLogin = LaunchAtLoginService.isEnabled
                        } catch {
                            settingsStore.launchAtLogin = LaunchAtLoginService.isEnabled
                            appState.lastError = error.localizedDescription
                        }
                    }
                ))
                Toggle(L10n.t("general.menuBar"), isOn: $settingsStore.showMenuBarIcon)
                Toggle(L10n.t("general.sounds"), isOn: $settingsStore.playSounds)
                Picker(L10n.t("general.uiLanguage"), selection: $settingsStore.uiLanguage) {
                    ForEach(AppUILanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(L10n.t("general.appearance"), selection: $settingsStore.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases) { Text($0.localizedTitle).tag($0) }
                }
            }

            SettingsCard(L10n.t("general.overlay")) {
                Toggle(L10n.t("general.showOverlay"), isOn: $settingsStore.showRecordingOverlay)
                Picker(L10n.t("general.overlayPosition"), selection: $settingsStore.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.localizedTitle).tag($0) }
                }
                .disabled(!settingsStore.showRecordingOverlay)
                Toggle(L10n.t("general.showTimer"), isOn: $settingsStore.showTimer)
                    .disabled(!settingsStore.showRecordingOverlay)
                Toggle(L10n.t("general.showProvider"), isOn: $settingsStore.showProviderInOverlay)
                    .disabled(!settingsStore.showRecordingOverlay)
                Toggle(L10n.t("general.showMic"), isOn: $settingsStore.showMicrophoneInOverlay)
                    .disabled(!settingsStore.showRecordingOverlay)
                Toggle(L10n.t("general.showPreview"), isOn: $settingsStore.showTranscriptPreview)
                    .disabled(!settingsStore.showRecordingOverlay)
                Toggle(L10n.t("general.privatePreview"), isOn: $settingsStore.privatePreview)
                    .disabled(!settingsStore.showRecordingOverlay || !settingsStore.showTranscriptPreview)
            }
        }
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard(L10n.t("dict.mic")) {
                Picker(L10n.t("dict.input"), selection: $settingsStore.selectedMicrophoneID) {
                    Text(L10n.t("dict.defaultMic")).tag("")
                    ForEach(microphones.devices) { Text($0.name).tag($0.id) }
                }
                Button(L10n.t("dict.refreshMics")) { microphones.refresh() }
            }

            SettingsCard(L10n.t("dict.shortcut")) {
                Picker(L10n.t("dict.shortcutTrigger"), selection: $settingsStore.shortcutPreset) {
                    ForEach(ShortcutPreset.allCases) { Text($0.localizedTitle).tag($0) }
                }
                if settingsStore.shortcutPreset == .custom {
                    HStack {
                        Text(L10n.t("dict.customShortcut"))
                        Spacer()
                        Button(appState.recordingShortcut ? L10n.t("dict.pressShortcut") : settingsStore.shortcut.display) {
                            appState.recordingShortcut = true
                        }
                    }
                }
                if settingsStore.shortcutPreset.needsInputMonitoring {
                    Text(L10n.t("dict.needsIM"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Picker(L10n.t("dict.shortcutMode"), selection: $settingsStore.shortcutMode) {
                    ForEach(ShortcutMode.allCases) { Text($0.localizedTitle).tag($0) }
                }
                Text(settingsStore.shortcutMode == .hold
                    ? L10n.t("dict.modeHold")
                    : L10n.t("dict.modeToggle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(L10n.t("dict.cancelWhile"))
                    Spacer()
                    Text(settingsStore.cancelShortcut.display).foregroundStyle(.secondary)
                }
                Slider(value: $settingsStore.minimumRecordingDuration, in: 0.1...2, step: 0.1) {
                    Text(L10n.t("dict.minDuration"))
                }
                Text(L10n.tf("dict.minSec", settingsStore.minimumRecordingDuration))
                Slider(value: $settingsStore.maximumRecordingDuration, in: 10...600, step: 5) {
                    Text(L10n.t("dict.maxDuration"))
                }
                Text(L10n.tf("dict.maxSec", Int(settingsStore.maximumRecordingDuration)))
            }

            SettingsCard(L10n.t("dict.insertion")) {
                Toggle(L10n.t("dict.autoInsert"), isOn: $settingsStore.autoInsert)
                Picker(L10n.t("dict.insertMethod"), selection: $settingsStore.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { Text($0.localizedTitle).tag($0) }
                }
                .disabled(!settingsStore.autoInsert)
                Toggle(L10n.t("dict.clipboardRestore"), isOn: $settingsStore.preserveClipboard)
                    .disabled(!settingsStore.autoInsert || settingsStore.insertionMethod != .paste)
                Text(settingsStore.preserveClipboard
                    ? L10n.t("dict.clipboardRestoreHintOn")
                    : L10n.t("dict.clipboardRestoreHintOff"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle(L10n.t("dict.trailingSpace"), isOn: $settingsStore.addTrailingSpace)
                Toggle(L10n.t("dict.trailingNewline"), isOn: $settingsStore.addTrailingNewline)
                Toggle(L10n.t("dict.copyOnFail"), isOn: $settingsStore.copyOnInsertionFailure)
                Toggle(L10n.t("dict.mute"), isOn: $settingsStore.muteWhileRecording)
                if !settingsStore.autoInsert {
                    Text(L10n.t("dict.autoInsertOff"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(settingsStore.provider.rawValue)
                        .font(.title2.weight(.semibold))
                    Text(settingsStore.provider.summary)
                        .foregroundStyle(.secondary)
                    Text("\(settingsStore.provider.setupLabel)  •  \(settingsStore.provider.freeTier)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: settingsStore.provider.keyURL) {
                    Label(L10n.t("prov.getKey"), systemImage: "arrow.up.right.square")
                }
            }
            .padding(.horizontal, 2)

            SettingsCard(L10n.t("prov.connection")) {
                Picker(L10n.t("prov.provider"), selection: $settingsStore.provider) {
                    ForEach(ProviderGroup.allCases) { group in
                        Section(group.rawValue) {
                            ForEach(SpeechProvider.allCases.filter { $0.group == group }) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Picker(L10n.t("prov.model"), selection: $settingsStore.model) {
                        ForEach(settingsStore.provider.models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: .infinity)
                    Button {
                        languageSearch = ""
                        showingLanguages.toggle()
                    } label: {
                        Label(
                            L10n.tf("prov.languagesCount", selectedModelInfo.languageCodes.count),
                            systemImage: "globe"
                        )
                    }
                }
                if showingLanguages {
                    LanguagePanel(model: selectedModelInfo, search: $languageSearch)
                }
                if let note = selectedModelInfo.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                if let code = settingsStore.language.apiCode,
                   !selectedModelInfo.languageCodes.contains(code) {
                    Label(L10n.t("prov.languageWarning"), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Divider()
                TextField(L10n.t("prov.baseURL"), text: $settingsStore.baseURL)
                    .textFieldStyle(.roundedBorder)
                if let hint = settingsStore.provider.baseURLHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                SecureField(L10n.t("prov.apiKey"), text: $settingsStore.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }
                HStack {
                    Button(L10n.t("prov.save")) { saveKey() }
                        .keyboardShortcut(.defaultAction)
                    Button(L10n.t("prov.reload")) { settingsStore.loadAPIKey() }
                    Button(L10n.t("prov.clear"), role: .destructive) { settingsStore.clearAPIKey() }
                    Spacer()
                    Label(
                        settingsStore.apiKey.isEmpty
                            ? L10n.t("prov.notConfigured")
                            : (keySavedFlash ? L10n.t("prov.saved") : L10n.t("prov.ready")),
                        systemImage: settingsStore.apiKey.isEmpty ? "circle.dashed" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(settingsStore.apiKey.isEmpty ? .orange : .green)
                }
            }

            if settingsStore.provider == .deepgram {
                SettingsCard(L10n.t("prov.options")) {
                    Toggle(L10n.t("prov.smartFmt"), isOn: $settingsStore.deepgramSmartFormat)
                    Toggle(L10n.t("prov.numerals"), isOn: $settingsStore.deepgramNumerals)
                    Toggle(L10n.t("prov.punct"), isOn: $settingsStore.deepgramPunctuation)
                }
            }
            if settingsStore.provider == .gladia {
                SettingsCard(L10n.t("prov.options")) {
                    Toggle(L10n.t("prov.codeSwitch"), isOn: $settingsStore.gladiaCodeSwitching)
                    Toggle(L10n.t("prov.enhPunct"), isOn: $settingsStore.punctuation)
                }
            }
        }
    }

    private var selectedModelInfo: SpeechModelInfo {
        settingsStore.provider.modelInfos.first { $0.id == settingsStore.model }
            ?? settingsStore.provider.modelInfos[0]
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionsPanel(
                center: permissionCenter,
                needsInputMonitoring: settingsStore.shortcutPreset.needsInputMonitoring
            )
            Text(settingsStore.shortcutPreset.needsInputMonitoring
                ? L10n.t("perm.imNoteOn")
                : L10n.t("perm.imNoteOff"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var updates: some View {
        SettingsCard {
            Toggle(L10n.t("upd.checkOnLaunch"), isOn: $settingsStore.automaticallyCheckUpdates)
            Toggle(L10n.t("upd.prereleases"), isOn: $settingsStore.includePrereleases)
            Button(updateManager.isChecking ? L10n.t("upd.checking") : L10n.t("upd.check")) {
                Task {
                    await updateManager.check(
                        includePrereleases: settingsStore.includePrereleases,
                        openWhenAvailable: true
                    )
                }
            }
            .disabled(updateManager.isChecking)
            Text(updateManager.lastStatus)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if updateManager.downloadURL != nil {
                Button(L10n.t("upd.openDownload")) { updateManager.openDownloadIfAvailable() }
            }
        }
    }

    private var advanced: some View {
        SettingsCard {
            Toggle(L10n.t("adv.debug"), isOn: $settingsStore.debugMode)
            Text("\(L10n.t("adv.lastError")): \(appState.lastError.isEmpty ? L10n.t("adv.none") : appState.lastError)")
                .textSelection(.enabled)
            Button(L10n.t("adv.exportLog")) {
                NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsLogger.shared.exportURL()])
            }
            Button(L10n.t("adv.clearLog")) { DiagnosticsLogger.shared.clear() }
            Button(L10n.t("adv.clearKeys"), role: .destructive) {
                LocalSecretStore.clearAll()
                settingsStore.apiKey = ""
            }
            Button(L10n.t("adv.reset"), role: .destructive) {
                settingsStore.resetAll()
                appState.lastError = L10n.t("adv.resetDone")
            }
            Text(L10n.t("adv.privacy"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func saveKey() {
        settingsStore.saveAPIKey()
        keySavedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            keySavedFlash = false
        }
    }
}

private struct SettingsCard<Content: View>: View {
    private let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LanguagePanel: View {
    let model: SpeechModelInfo
    @Binding var search: String

    private var languages: [String] {
        guard !search.isEmpty else { return model.languageNames }
        return model.languageNames.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("prov.supportedLanguages"))
                    .font(.headline)
                Text(model.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(L10n.t("prov.searchLanguages"), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ], alignment: .leading, spacing: 8) {
                    ForEach(languages, id: \.self) { language in
                        Label(language, systemImage: "checkmark")
                            .font(.callout)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        }
    }
}
