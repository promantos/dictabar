import AppKit
import Combine
import SwiftUI

@main
struct FlowDictateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let appState = AppState()
    private let settingsStore = SettingsStore()
    private let microphoneManager = MicrophoneDeviceManager()
    private let permissionCenter = PermissionCenter.shared
    private lazy var dictationController = DictationController(appState: appState, settingsStore: settingsStore)
    private lazy var shortcutManager = GlobalShortcutManager(
        onPressed: { [weak self] in Task { @MainActor in self?.dictationController.shortcutPressed() } },
        onReleased: { [weak self] in Task { @MainActor in self?.dictationController.shortcutReleased() } },
        onError: { [weak self] message in
            Task { @MainActor in
                self?.appState.lastError = message
                DiagnosticsLogger.shared.log("shortcut: \(message)")
            }
        }
    )
    private var statusItem: NSStatusItem?
    private var startStopMenuItem: NSMenuItem?
    private var cancelMenuItem: NSMenuItem?
    private var providerMenuItem: NSMenuItem?
    private var permissionsMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var updatesMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var settingsChromeCounted = false
    private var onboardingChromeCounted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as accessory (menu bar). Elevate to regular while any chrome window is open
        // so system permission sheets attach to a real activation context.
        NSApp.setActivationPolicy(.accessory)
        permissionCenter.refresh()

        // Recover from crash mid-recording: stale audio files + stuck system mute.
        AudioRecorder.cleanupStaleTempRecordings()
        SystemAudioMuteService.recoverIfNeeded()

        shortcutManager.start(preset: settingsStore.shortcutPreset, customShortcut: settingsStore.shortcut)
        observeSettings()
        applyMenuBarIconVisibility()
        applyAppearance(settingsStore.appearanceMode)

        // Launch quietly as a menu-bar app. Permission prompts are shown only after
        // an explicit user action (starting dictation or opening Permissions).
        if permissionCenter.requiredReady {
            appState.completePermissionsOnboarding()
        }

        if settingsStore.automaticallyCheckUpdates {
            Task {
                await UpdateManager.shared.check(
                    includePrereleases: settingsStore.includePrereleases,
                    openWhenAvailable: false
                )
            }
        }

        DiagnosticsLogger.shared.log(
            "FlowDictate launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") mic=\(permissionCenter.microphone) ax=\(permissionCenter.accessibility) input=\(permissionCenter.inputMonitoring)"
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: - Observations

    private func observeSettings() {
        settingsStore.$shortcutPreset
            .combineLatest(settingsStore.$shortcut)
            .dropFirst()
            .sink { [weak self] preset, shortcut in
                if preset.needsInputMonitoring {
                    PermissionManager.ensureInputMonitoringListEntry()
                }
                self?.shortcutManager.update(preset: preset, customShortcut: shortcut)
            }
            .store(in: &cancellables)

        settingsStore.$provider
            .combineLatest(settingsStore.$uiLanguage)
            .sink { [weak self] _, _ in
                self?.refreshMenuTitles()
            }
            .store(in: &cancellables)

        settingsStore.$showMenuBarIcon
            .sink { [weak self] _ in
                self?.applyMenuBarIconVisibility()
            }
            .store(in: &cancellables)

        settingsStore.$appearanceMode
            .sink { [weak self] mode in
                self?.applyAppearance(mode)
            }
            .store(in: &cancellables)

        appState.$dictationState
            .sink { [weak self] state in
                self?.updateStatusItem(for: state)
            }
            .store(in: &cancellables)

        appState.$showPermissionsOnboarding
            .sink { [weak self] show in
                // Only surface the permissions sheet when still incomplete.
                guard let self, show, !self.permissionCenter.requiredReady else { return }
                self.showPermissionsOnboarding()
            }
            .store(in: &cancellables)

        // Auto-dismiss permissions window once mic + accessibility are granted.
        permissionCenter.$microphone
            .combineLatest(permissionCenter.$accessibility)
            .sink { [weak self] mic, ax in
                guard let self else { return }
                if mic.isGranted && ax.isGranted {
                    self.appState.completePermissionsOnboarding()
                    if self.onboardingWindow?.isVisible == true {
                        self.onboardingWindow?.close()
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu bar

    private func applyMenuBarIconVisibility() {
        if settingsStore.showMenuBarIcon {
            if statusItem == nil { setupMenuBar() }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    private func applyAppearance(_ mode: AppAppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func refreshMenuTitles() {
        startStopMenuItem?.title = L10n.t("menu.startStop")
        cancelMenuItem?.title = L10n.t("menu.cancel")
        providerMenuItem?.title = "\(L10n.t("menu.provider")): \(settingsStore.provider.rawValue)"
        permissionsMenuItem?.title = L10n.t("section.permissions") + "…"
        settingsMenuItem?.title = L10n.t("menu.settings")
        updatesMenuItem?.title = L10n.t("menu.updates")
        quitMenuItem?.title = L10n.t("menu.quit")
    }

    private func setupMenuBar() {
        // NSStatusItem owns remote AppKit scenes on newer macOS versions. Keep one
        // instance for the process lifetime; replacing it while its menu is tracked
        // can abort inside NSSceneStatusItem/NSRemoteView.
        guard statusItem == nil else {
            refreshMenuTitles()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "FlowDictate")

        let menu = NSMenu()
        startStopMenuItem = menuItem(L10n.t("menu.startStop"), action: #selector(toggleDictation), keyEquivalent: "")
        cancelMenuItem = menuItem(L10n.t("menu.cancel"), action: #selector(cancelDictation), keyEquivalent: "")
        menu.addItem(startStopMenuItem!)
        menu.addItem(cancelMenuItem!)
        menu.addItem(.separator())
        let providerItem = NSMenuItem(
            title: "\(L10n.t("menu.provider")): \(settingsStore.provider.rawValue)",
            action: nil,
            keyEquivalent: ""
        )
        providerMenuItem = providerItem
        menu.addItem(providerItem)
        permissionsMenuItem = menuItem(L10n.t("section.permissions") + "…", action: #selector(showPermissions), keyEquivalent: "")
        settingsMenuItem = menuItem(L10n.t("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
        updatesMenuItem = menuItem(L10n.t("menu.updates"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(permissionsMenuItem!)
        menu.addItem(settingsMenuItem!)
        menu.addItem(updatesMenuItem!)
        menu.addItem(.separator())
        quitMenuItem = menuItem(L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitMenuItem!)
        item.menu = menu
        statusItem = item
    }

    private func updateStatusItem(for state: AppState.DictationState) {
        let symbol: String
        switch state {
        case .recording: symbol = "mic.circle.fill"
        case .transcribing, .starting: symbol = "waveform.circle.fill"
        case .failed, .needsMicrophonePermission, .needsAccessibilityPermission:
            symbol = "exclamationmark.circle.fill"
        default: symbol = "mic.circle.fill"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FlowDictate")
        statusItem?.button?.toolTip = appState.statusTitle
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return item
    }

    // MARK: - Actions

    @objc private func toggleDictation() {
        dictationController.toggle()
    }

    @objc private func cancelDictation() {
        dictationController.cancel()
    }

    @objc private func checkForUpdates() {
        Task {
            await UpdateManager.shared.check(
                includePrereleases: settingsStore.includePrereleases,
                openWhenAvailable: true
            )
        }
    }

    @objc private func showPermissions() {
        appState.selectedSettingsSection = SettingsSection.permissions.rawValue
        showSettings()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            microphoneManager.refresh()
            let host = NSHostingController(
                rootView: SettingsView(
                    appState: appState,
                    settingsStore: settingsStore,
                    microphones: microphoneManager
                )
                .environment(\.locale, Locale(identifier: settingsStore.uiLanguage.resolvedCode))
            )
            let window = NSWindow(contentViewController: host)
            window.title = "FlowDictate Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }

        if !settingsChromeCounted {
            settingsChromeCounted = true
            elevateActivationPolicy()
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionCenter.refresh()
    }

    private func showPermissionsOnboarding() {
        if onboardingWindow == nil {
            let root = PermissionsOnboardingView(
                center: permissionCenter,
                needsInputMonitoring: settingsStore.shortcutPreset.needsInputMonitoring,
                onContinue: { [weak self] in
                    // Close only — do not open Settings.
                    self?.appState.completePermissionsOnboarding()
                    self?.onboardingWindow?.close()
                },
                onOpenFullSettings: { [weak self] in
                    // Optional: user asked for settings explicitly from the sheet.
                    self?.appState.selectedSettingsSection = SettingsSection.permissions.rawValue
                    self?.showSettings()
                }
            )
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.title = "FlowDictate Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            onboardingWindow = window
        }
        if !onboardingChromeCounted {
            onboardingChromeCounted = true
            elevateActivationPolicy()
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionCenter.refresh()
    }

    // MARK: - Activation policy (permission sheets need a regular app context)

    private func elevateActivationPolicy() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func maybeReturnToAccessory() {
        let settingsVisible = settingsWindow?.isVisible == true
        let onboardingVisible = onboardingWindow?.isVisible == true
        if !settingsVisible && !onboardingVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsChromeCounted = false
        }
        if window === onboardingWindow {
            onboardingChromeCounted = false
            appState.completePermissionsOnboarding()
        }
        // Defer until after close so isVisible is accurate.
        DispatchQueue.main.async { [weak self] in
            self?.maybeReturnToAccessory()
        }
    }
}

/// Shared with SettingsView sidebar tags.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case dictation = "Dictation"
    case providers = "Providers"
    case permissions = "Permissions"
    case updates = "Updates"
    case advanced = "Advanced"

    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .general: L10n.t("section.general")
        case .dictation: L10n.t("section.dictation")
        case .providers: L10n.t("section.providers")
        case .permissions: L10n.t("section.permissions")
        case .updates: L10n.t("section.updates")
        case .advanced: L10n.t("section.advanced")
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .providers: "network"
        case .permissions: "lock.shield"
        case .updates: "arrow.clockwise"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
