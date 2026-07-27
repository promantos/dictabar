import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var microphone: PermissionAuthStatus = .notDetermined
    @Published private(set) var accessibility: PermissionAuthStatus = .denied
    @Published private(set) var inputMonitoring: PermissionAuthStatus = .denied
    @Published private(set) var isBusy = false
    @Published var lastMessage: String = ""

    private var observers: [NSObjectProtocol] = []
    private var pollTask: Task<Void, Never>?

    private init() {
        refresh()
        startObserving()
    }

    func refresh() {
        microphone = PermissionManager.microphoneStatus()
        accessibility = PermissionManager.hasAccessibilityAccess() ? .authorized : .denied
        inputMonitoring = PermissionManager.hasInputMonitoringAccess() ? .authorized : .denied
    }

    var requiredReady: Bool { isReady(needsAccessibility: true) }

    func isReady(needsAccessibility: Bool) -> Bool {
        microphone.isGranted && (!needsAccessibility || accessibility.isGranted)
    }

    func enableMicrophone() async {
        isBusy = true
        defer { isBusy = false; refresh() }
        refresh()
        if microphone.isGranted {
            lastMessage = "Microphone is already allowed."
            return
        }
        if microphone == .denied || microphone == .restricted {
            lastMessage = "Enable FlowDictate in System Settings → Microphone."
            PermissionManager.openMicrophoneSettings()
            startPollingWhileAway()
            return
        }
        lastMessage = "Requesting Microphone…"
        let granted = await PermissionManager.requestMicrophoneAccess()
        refresh()
        lastMessage = granted ? "Microphone allowed." : "Microphone not allowed. Use System Settings → Microphone."
        if !granted && microphone == .denied {
            PermissionManager.openMicrophoneSettings()
            startPollingWhileAway()
        }
    }

    func enableAccessibility() async {
        isBusy = true
        defer { isBusy = false; refresh() }
        refresh()
        if accessibility.isGranted {
            lastMessage = "Accessibility is already allowed."
            return
        }
        lastMessage = "Requesting Accessibility…"
        let granted = await PermissionManager.requestAccessibilityAccessAsync()
        refresh()
        if granted {
            lastMessage = "Accessibility allowed."
            return
        }
        lastMessage = "Enable FlowDictate in System Settings → Accessibility."
        PermissionManager.openAccessibilitySettings()
        startPollingWhileAway()
    }

    func enableInputMonitoring() async {
        isBusy = true
        defer { isBusy = false; refresh() }
        refresh()
        if inputMonitoring.isGranted {
            lastMessage = "Input Monitoring is already allowed."
            return
        }
        lastMessage = "Registering FlowDictate for Input Monitoring…"
        _ = PermissionManager.requestInputMonitoringAccess()
        try? await Task.sleep(for: .milliseconds(800))
        refresh()
        if inputMonitoring.isGranted {
            lastMessage = "Input Monitoring allowed."
            return
        }
        lastMessage = "Open Input Monitoring and enable FlowDictate (it should be in the list)."
        PermissionManager.openInputMonitoringSettings()
        startPollingWhileAway()
    }

    /// Mic always required. Accessibility only when inserting text. IM is NOT required to record.
    func ensureForDictation(needsInputMonitoring: Bool, needsAccessibility: Bool = true) async -> (ok: Bool, message: String?) {
        refresh()
        DiagnosticsLogger.shared.log(
            "ensureForDictation mic=\(microphone) ax=\(accessibility) needAX=\(needsAccessibility) needIM=\(needsInputMonitoring)"
        )

        if !microphone.isGranted {
            if microphone == .notDetermined {
                let granted = await PermissionManager.requestMicrophoneAccess()
                refresh()
                if !granted {
                    return (false, "Allow Microphone in the system dialog or System Settings → Microphone.")
                }
            } else {
                return (false, "Microphone blocked. System Settings → Microphone → FlowDictate.")
            }
        }

        if needsAccessibility && !accessibility.isGranted {
            let granted = await PermissionManager.requestAccessibilityAccessAsync()
            refresh()
            if !granted {
                return (false, "Enable Accessibility for FlowDictate to insert text.")
            }
        }

        if needsInputMonitoring && !inputMonitoring.isGranted {
            PermissionManager.ensureInputMonitoringListEntry()
        }
        return (true, nil)
    }

    private func startObserving() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    private func startPollingWhileAway() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.refresh() }
        }
    }
}
