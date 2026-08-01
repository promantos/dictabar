import AppKit
import Carbon
import Foundation

@MainActor
final class DictationController {
    private let appState: AppState
    private let settingsStore: SettingsStore
    private let recorder = AudioRecorder()
    private let overlay = OverlayWindowController()

    private var recordingURL: URL?
    private var activeAudioURL: URL?
    private var startedAt: Date?
    private var maxRecordTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var sessionID = UUID()
    private var stopWhenReady = false
    private var isMutedByUs = false
    private var globalCancelMonitor: Any?
    private var localCancelMonitor: Any?
    private var lastStartAttempt = Date.distantPast
    private var isRetryingRecovery = false

    init(appState: AppState, settingsStore: SettingsStore) {
        self.appState = appState
        self.settingsStore = settingsStore
        FailedDictationStore.prune()
        DebugRecordingStore.prune()
        appState.hasRetryableDictation = FailedDictationStore.exists
    }

    // MARK: - Public API

    func shortcutPressed() {
        switch settingsStore.shortcutMode {
        case .toggle: toggle()
        case .hold:
            if case .transcribing = appState.dictationState {
                cancel()
                return
            }
            stopWhenReady = false
            beginStart()
        }
    }

    func shortcutReleased() {
        guard settingsStore.shortcutMode == .hold else { return }
        if case .starting = appState.dictationState {
            stopWhenReady = true
            return
        }
        stopAndTranscribe()
    }

    func toggle() {
        switch appState.dictationState {
        case .recording:
            stopAndTranscribe()
        case .starting:
            if settingsStore.shortcutMode == .toggle {
                cancel()
            } else {
                stopWhenReady = true
            }
        case .transcribing:
            cancel()
        case .idle, .failed, .needsMicrophonePermission, .needsAccessibilityPermission:
            beginStart()
        }
    }

    func cancel() {
        let old = sessionID
        sessionID = UUID()
        stopWhenReady = false
        maxRecordTask?.cancel()
        maxRecordTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        // Restore previous clipboard if cancel hits during paste wait.
        TextInsertionService.restoreClipboardIfNeeded()
        recorder.cancel()
        endMuteIfNeeded()
        removeCancelMonitor()
        overlay.hide()
        cleanup(recordingURL)
        if !isRetryingRecovery { cleanup(activeAudioURL) }
        recordingURL = nil
        activeAudioURL = nil
        isRetryingRecovery = false
        startedAt = nil
        appState.dictationState = .idle
        DiagnosticsLogger.shared.log("dictation cancelled session=\(old)")
    }

    func retryLastFailure() {
        guard canStart, let audioURL = FailedDictationStore.recordingURL else { return }
        let id = UUID()
        sessionID = id
        appState.dictationState = .transcribing
        isRetryingRecovery = true
        appState.lastError = ""
        installCancelMonitor()
        showOverlay(.processing, L10n.t("overlay.transcribing"))

        let providerKind = settingsStore.provider
        let apiKey = settingsStore.apiKeyForTranscription()
        let providerSettings = settingsStore.providerSettings
        let autoInsert = settingsStore.autoInsert
        let copyOnFail = settingsStore.copyOnInsertionFailure
        let showOverlayFlag = settingsStore.showRecordingOverlay
        let privatePreview = settingsStore.privatePreview
        let showPreview = settingsStore.showTranscriptPreview
        let insertedLabel = L10n.t("overlay.inserted")

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(
                sessionID: id,
                recordedURL: audioURL,
                finalizedAudioURL: audioURL,
                providerKind: providerKind,
                apiKey: apiKey,
                providerSettings: providerSettings,
                autoInsert: autoInsert,
                copyOnFail: copyOnFail,
                showOverlayFlag: showOverlayFlag,
                privatePreview: privatePreview,
                showPreview: showPreview,
                insertedLabel: insertedLabel
            )
        }
    }

    // MARK: - Start

    private func beginStart() {
        guard canStart else { return }
        // Debounce Right ⌘ flagsChanged spam (logs showed 10+ starts/sec).
        let now = Date()
        guard now.timeIntervalSince(lastStartAttempt) > 0.35 else {
            DiagnosticsLogger.shared.log("dictation start debounced")
            return
        }
        lastStartAttempt = now
        stopWhenReady = false
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            await self?.startRecording()
        }
    }

    private func startRecording() async {
        guard canStart else { return }
        let id = UUID()
        sessionID = id
        appState.dictationState = .starting
        appState.lastError = ""
        DiagnosticsLogger.shared.log("dictation start session=\(id)")

        guard await ensurePermissions() else {
            if case .starting = appState.dictationState { appState.dictationState = .idle }
            return
        }
        guard !Task.isCancelled, sessionID == id else { return }

        if stopWhenReady && settingsStore.shortcutMode == .hold {
            stopWhenReady = false
            appState.dictationState = .idle
            return
        }

        do {
            let url = try await recorder.start(deviceID: settingsStore.selectedMicrophoneID)
            guard !Task.isCancelled, sessionID == id else {
                recorder.cancel()
                cleanup(url)
                return
            }
            if stopWhenReady && settingsStore.shortcutMode == .hold {
                recorder.cancel()
                cleanup(url)
                stopWhenReady = false
                appState.dictationState = .idle
                return
            }

            recordingURL = url
            activeAudioURL = url
            startedAt = Date()
            appState.dictationState = .recording
            beginMuteIfNeeded()
            installCancelMonitor()
            FeedbackSound.playIfEnabled(settingsStore.playSounds, .start)
            showOverlay(.recording, L10n.t("overlay.recording"), recordingStartedAt: startedAt)

            maxRecordTask?.cancel()
            let maxSeconds = settingsStore.maximumRecordingDuration
            maxRecordTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(maxSeconds))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.stopAndTranscribe() }
            }
        } catch {
            endMuteIfNeeded()
            removeCancelMonitor()
            fail(error)
        }
    }

    // MARK: - Stop → transcribe → insert (linear, always recovers)

    private func stopAndTranscribe() {
        guard case .recording = appState.dictationState else { return }
        let id = sessionID
        maxRecordTask?.cancel()
        maxRecordTask = nil

        guard let recordedURL = recordingURL else {
            endMuteIfNeeded()
            removeCancelMonitor()
            appState.dictationState = .idle
            return
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingURL = nil
        startedAt = nil
        endMuteIfNeeded()
        FeedbackSound.playIfEnabled(settingsStore.playSounds, .stop)

        if duration < settingsStore.minimumRecordingDuration {
            recorder.cancel()
            cleanup(recordedURL)
            activeAudioURL = nil
            removeCancelMonitor()
            overlay.hide()
            appState.dictationState = .idle
            DiagnosticsLogger.shared.log("dictation discarded short recording \(duration)s")
            return
        }

        appState.dictationState = .transcribing
        installCancelMonitor()
        showOverlay(.processing, L10n.t("overlay.transcribing"))

        // Snapshot settings for the background network hop (values, not live store).
        let providerKind = settingsStore.provider
        let apiKey = settingsStore.apiKeyForTranscription()
        let providerSettings = settingsStore.providerSettings
        let autoInsert = settingsStore.autoInsert
        let copyOnFail = settingsStore.copyOnInsertionFailure
        let showOverlayFlag = settingsStore.showRecordingOverlay
        let privatePreview = settingsStore.privatePreview
        let showPreview = settingsStore.showTranscriptPreview
        let insertedLabel = L10n.t("overlay.inserted")

        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(
                sessionID: id,
                recordedURL: recordedURL,
                providerKind: providerKind,
                apiKey: apiKey,
                providerSettings: providerSettings,
                autoInsert: autoInsert,
                copyOnFail: copyOnFail,
                showOverlayFlag: showOverlayFlag,
                privatePreview: privatePreview,
                showPreview: showPreview,
                insertedLabel: insertedLabel
            )
        }
    }

    private func runPipeline(
        sessionID id: UUID,
        recordedURL: URL,
        finalizedAudioURL: URL? = nil,
        providerKind: SpeechProvider,
        apiKey: String,
        providerSettings: ProviderSettings,
        autoInsert: Bool,
        copyOnFail: Bool,
        showOverlayFlag: Bool,
        privatePreview: Bool,
        showPreview: Bool,
        insertedLabel: String
    ) async {
        let pipelineStartedAt = Date()
        var transcriptionCompleted = false
        defer {
            // Safety net: never leave UI stuck if something forgot to set state.
            if sessionID == id, appState.dictationState == .transcribing {
                DiagnosticsLogger.shared.log("pipeline: safety net reset stuck transcribing state")
                appState.dictationState = .idle
                removeCancelMonitor()
                overlay.hide()
            }
        }

        do {
            try Task.checkCancellation()
            guard sessionID == id else { return }

            // 1) Finalize audio (synchronous AVAudioRecorder.stop under the hood).
            let audioURL: URL
            if let finalizedAudioURL {
                audioURL = finalizedAudioURL
                DiagnosticsLogger.shared.log("pipeline: retry retained audio")
            } else {
                DiagnosticsLogger.shared.log("pipeline: stop recorder")
                audioURL = try await recorder.stop()
            }
            activeAudioURL = audioURL
            let size = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            DiagnosticsLogger.shared.log("pipeline: audio size=\(size)")
            guard size <= providerKind.maximumUploadBytes else {
                throw ProviderError.unsupported(
                    "This recording is too large for \(providerKind.rawValue). Maximum upload size is \(providerKind.maximumUploadBytes / 1_048_576) MB."
                )
            }

            try Task.checkCancellation()
            guard sessionID == id else {
                cleanup(audioURL)
                return
            }

            guard !providerKind.requiresAPIKey || !apiKey.isEmpty else {
                throw ProviderError.missingAPIKey
            }

            // 2) Network transcription with hard timeout (no nested MainActor tasks).
            showOverlay(.processing, "Transcribing…")
            DiagnosticsLogger.shared.log("pipeline: transcribe \(providerKind.rawValue) \(providerSettings.model)")
            let provider = ProviderRegistry.provider(for: providerKind)
            let result = try await withTimeout(seconds: 150) {
                try await provider.transcribe(
                    audioURL: audioURL,
                    settings: providerSettings,
                    apiKey: apiKey
                )
            }
            transcriptionCompleted = true

            try Task.checkCancellation()
            guard sessionID == id else {
                cleanup(audioURL)
                return
            }

            DiagnosticsLogger.shared.log("pipeline: text chars=\(result.text.count)")
            appState.lastTranscript = result.text
            if settingsStore.saveTranscriptHistory {
                TranscriptHistoryStore.shared.add(
                    text: result.text,
                    provider: result.providerName,
                    model: result.modelName
                )
            }

            // 3) Insert / copy
            if autoInsert {
                do {
                    // Use live store so clipboard/appearance toggles apply immediately.
                    try await TextInsertionService.insert(result.text, settings: settingsStore)
                } catch {
                    if copyOnFail { TextInsertionService.copy(result.text) }
                    throw error
                }
            } else {
                TextInsertionService.copy(result.text)
            }

            try Task.checkCancellation()
            guard sessionID == id else {
                cleanup(audioURL)
                return
            }

            // 4) Success
            if showOverlayFlag {
                let preview: String? = privatePreview ? nil : (showPreview ? String(result.text.prefix(48)) : nil)
                overlay.show(
                    kind: .success,
                    message: preview ?? insertedLabel,
                    settings: settingsStore.overlayPresentation(transcriptPreview: preview),
                    autoHide: true
                )
            } else {
                overlay.hide()
            }

            removeCancelMonitor()
            FailedDictationStore.clear()
            appState.hasRetryableDictation = false
            isRetryingRecovery = false
            cleanup(audioURL)
            activeAudioURL = nil
            appState.dictationState = .idle
            let elapsed = Date().timeIntervalSince(pipelineStartedAt)
            DiagnosticsLogger.shared.log(
                "metric: outcome=success provider=\(providerKind.rawValue) latency_ms=\(Int(elapsed * 1000))"
            )
        } catch is CancellationError {
            TextInsertionService.restoreClipboardIfNeeded()
            if finalizedAudioURL == nil {
                cleanup(activeAudioURL)
                cleanup(recordedURL)
            }
            activeAudioURL = nil
            isRetryingRecovery = false
            removeCancelMonitor()
            overlay.hide()
            if sessionID == id {
                appState.dictationState = .idle
            }
            DiagnosticsLogger.shared.log("pipeline: cancelled")
        } catch {
            TextInsertionService.restoreClipboardIfNeeded()
            let existingActiveAudioURL = activeAudioURL.flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
            if !transcriptionCompleted,
               let source = existingActiveAudioURL
                    ?? (FileManager.default.fileExists(atPath: recordedURL.path) ? recordedURL : nil) {
                do {
                    try FailedDictationStore.save(source)
                    appState.hasRetryableDictation = true
                } catch {
                    DiagnosticsLogger.shared.log("recovery: failed to retain audio \(error.localizedDescription)")
                    cleanup(source)
                }
            } else {
                cleanup(activeAudioURL)
                cleanup(recordedURL)
            }
            activeAudioURL = nil
            isRetryingRecovery = false
            removeCancelMonitor()
            if sessionID == id {
                if settingsStore.showRecordingOverlay {
                    overlay.show(
                        kind: .error,
                        message: error.localizedDescription,
                        settings: settingsStore.overlayPresentation(),
                        autoHide: true
                    )
                }
                fail(error)
            }
            let elapsed = Date().timeIntervalSince(pipelineStartedAt)
            DiagnosticsLogger.shared.log(
                "metric: outcome=failure provider=\(providerKind.rawValue) retryable=\((error as? ProviderError)?.isRetryable == true) latency_ms=\(Int(elapsed * 1000)) error=\(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private var canStart: Bool {
        switch appState.dictationState {
        case .idle, .failed, .needsMicrophonePermission, .needsAccessibilityPermission:
            true
        case .starting, .recording, .transcribing:
            false
        }
    }

    private func ensurePermissions() async -> Bool {
        // The global cancel monitor also needs Accessibility when the target app
        // owns focus, so cancellation must be permissioned consistently.
        let needsAX = true
        let result = await PermissionCenter.shared.ensureForDictation(
            needsInputMonitoring: settingsStore.shortcutPreset.needsInputMonitoring,
            needsAccessibility: needsAX
        )
        if result.ok {
            DiagnosticsLogger.shared.log("ensurePermissions ok")
            return true
        }
        // Keep dedicated permission states (do not overwrite with generic .failed).
        endMuteIfNeeded()
        removeCancelMonitor()
        let message = result.message ?? "Permissions are required before dictation."
        appState.lastError = message
        if !PermissionCenter.shared.microphone.isGranted {
            appState.dictationState = .needsMicrophonePermission
        } else if needsAX && !PermissionCenter.shared.accessibility.isGranted {
            appState.dictationState = .needsAccessibilityPermission
        } else {
            appState.dictationState = .failed(message)
        }
        // Re-show permissions sheet only when still-required perms are missing (never auto-open Settings).
        let micOK = PermissionCenter.shared.microphone.isGranted
        let axOK = !needsAX || PermissionCenter.shared.accessibility.isGranted
        if !(micOK && axOK) {
            appState.reopenPermissionsOnboarding()
        }
        DiagnosticsLogger.shared.log("ensurePermissions failed: \(message)")
        return false
    }

    private func beginMuteIfNeeded() {
        guard settingsStore.muteWhileRecording, !isMutedByUs else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        SystemAudioMuteService.beginMute()
        isMutedByUs = true
    }

    private func endMuteIfNeeded() {
        guard isMutedByUs else { return }
        SystemAudioMuteService.endMute()
        isMutedByUs = false
        ProcessInfo.processInfo.enableSuddenTermination()
    }

    private func showOverlay(_ kind: RecordingOverlay.Kind, _ message: String, recordingStartedAt: Date? = nil) {
        guard settingsStore.showRecordingOverlay else { return }
        overlay.show(
            kind: kind,
            message: message,
            settings: settingsStore.overlayPresentation(recordingStartedAt: recordingStartedAt),
            autoHide: false
        )
    }

    private func installCancelMonitor() {
        removeCancelMonitor()
        let keyCode = settingsStore.cancelShortcut.keyCode
        let carbonMods = settingsStore.cancelShortcut.carbonModifiers
        globalCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isCancelEvent(event, keyCode: keyCode, carbonModifiers: carbonMods) else { return }
            Task { @MainActor in self?.cancel() }
        }
        localCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isCancelEvent(event, keyCode: keyCode, carbonModifiers: carbonMods) else { return event }
            Task { @MainActor in self?.cancel() }
            return nil
        }
    }

    private static func isCancelEvent(_ event: NSEvent, keyCode: UInt32, carbonModifiers: UInt32 = 0) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Escape (53) and any cancel with no mods: bare key only.
        if carbonModifiers == 0 { return mods.isEmpty }
        var eventCarbon: UInt32 = 0
        if mods.contains(.command) { eventCarbon |= UInt32(cmdKey) }
        if mods.contains(.option) { eventCarbon |= UInt32(optionKey) }
        if mods.contains(.control) { eventCarbon |= UInt32(controlKey) }
        if mods.contains(.shift) { eventCarbon |= UInt32(shiftKey) }
        return eventCarbon == carbonModifiers
    }

    private func removeCancelMonitor() {
        if let globalCancelMonitor {
            NSEvent.removeMonitor(globalCancelMonitor)
            self.globalCancelMonitor = nil
        }
        if let localCancelMonitor {
            NSEvent.removeMonitor(localCancelMonitor)
            self.localCancelMonitor = nil
        }
    }

    private func fail(_ error: Error) {
        failMessage(error.localizedDescription)
    }

    private func failMessage(_ message: String) {
        endMuteIfNeeded()
        removeCancelMonitor()
        appState.lastError = message
        appState.dictationState = .failed(message)
        DiagnosticsLogger.shared.log("error: \(message)")
    }

    private func cleanup(_ url: URL?) {
        guard let url else { return }
        if settingsStore.debugMode {
            DebugRecordingStore.retain(url)
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}

private enum DebugRecordingStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictabar/DebugRecordings", isDirectory: true)
    }

    static func retain(_ source: URL) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let destination = directory
                .appendingPathComponent("Dictabar-\(UUID().uuidString)")
                .appendingPathExtension("wav")
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            prune()
        } catch {
            DiagnosticsLogger.shared.log("debug audio: retain failed \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: source)
        }
    }

    static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for file in sorted.dropFirst(10) {
            try? FileManager.default.removeItem(at: file)
        }
        for file in sorted.prefix(10) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if let modified, Date().timeIntervalSince(modified) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

private enum FailedDictationStore {
    private static let maxAge: TimeInterval = 24 * 60 * 60

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictabar/Recovery", isDirectory: true)
    }

    private static var storedURL: URL {
        directory.appendingPathComponent("last-failed.wav")
    }

    static var recordingURL: URL? {
        guard FileManager.default.fileExists(atPath: storedURL.path),
              ((try? storedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 4_096
        else { return nil }
        return storedURL
    }

    static var exists: Bool { recordingURL != nil }

    static func save(_ source: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = storedURL
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        DiagnosticsLogger.shared.log("recovery: retained failed recording")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: storedURL)
    }

    static func prune() {
        guard FileManager.default.fileExists(atPath: storedURL.path) else { return }
        let values = try? storedURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let isInvalid = (values?.fileSize ?? 0) <= 4_096
        let isExpired = values?.contentModificationDate
            .map { Date().timeIntervalSince($0) > maxAge } ?? true
        guard isInvalid || isExpired else { return }
        try? FileManager.default.removeItem(at: storedURL)
        DiagnosticsLogger.shared.log(isInvalid
            ? "recovery: removed invalid empty recording"
            : "recovery: expired failed recording")
    }
}

// MARK: - Timeout (no MainActor nesting)

private enum PipelineTimeoutError: LocalizedError {
    case timedOut(TimeInterval)
    var errorDescription: String? {
        switch self {
        case let .timedOut(s):
            "Transcription timed out after \(Int(s))s. Check network and API key, then try again."
        }
    }
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw PipelineTimeoutError.timedOut(seconds)
        }
        // First finished task wins (success or timeout error).
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

enum FeedbackSound {
    enum Kind { case start, stop }

    static func playIfEnabled(_ enabled: Bool, _ kind: Kind) {
        guard enabled else { return }
        let name: NSSound.Name = kind == .start ? NSSound.Name("Tink") : NSSound.Name("Pop")
        NSSound(named: name)?.play()
    }
}

extension SettingsStore {
    struct OverlayPresentation {
        var position: OverlayPosition
        var showTimer: Bool
        var showProvider: Bool
        var showMicrophone: Bool
        var providerName: String?
        var microphoneName: String?
        var transcriptPreview: String?
        var recordingStartedAt: Date?
    }

    func overlayPresentation(
        microphoneName: String? = nil,
        transcriptPreview: String? = nil,
        recordingStartedAt: Date? = nil
    ) -> OverlayPresentation {
        let micLabel: String? = {
            if !showMicrophoneInOverlay { return nil }
            if let microphoneName { return microphoneName }
            if selectedMicrophoneID.isEmpty { return "Default mic" }
            return "Microphone"
        }()
        return OverlayPresentation(
            position: overlayPosition,
            showTimer: showTimer,
            showProvider: showProviderInOverlay,
            showMicrophone: showMicrophoneInOverlay,
            providerName: showProviderInOverlay ? provider.rawValue : nil,
            microphoneName: micLabel,
            transcriptPreview: showTranscriptPreview ? transcriptPreview : nil,
            recordingStartedAt: recordingStartedAt
        )
    }
}
