@preconcurrency import ApplicationServices
import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

enum PermissionAuthStatus: Equatable {
    case notDetermined, denied, authorized, restricted
    var isGranted: Bool { self == .authorized }
    var title: String {
        switch self {
        case .notDetermined: "Not enabled"
        case .denied: "Denied"
        case .authorized: "Allowed"
        case .restricted: "Restricted"
        }
    }
}

enum PermissionManager {
    // MARK: - Microphone

    static func microphoneStatus() -> PermissionAuthStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func hasMicrophoneAccess() -> Bool { microphoneStatus().isGranted }

    @MainActor
    static func requestMicrophoneAccess() async -> Bool {
        let current = microphoneStatus()
        DiagnosticsLogger.shared.log("microphone status before request=\(current)")
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }

        // Activate only — no custom windows.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(80))

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        DiagnosticsLogger.shared.log("microphone: requestAccess=\(granted)")
        if NSApp.windows.allSatisfy({ !$0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
        return granted
    }

    // MARK: - Accessibility

    static func hasAccessibilityAccess() -> Bool { AXIsProcessTrusted() }

    @MainActor
    static func requestAccessibilityAccessAsync() async -> Bool {
        if AXIsProcessTrusted() { return true }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        DiagnosticsLogger.shared.log("accessibility trusted=\(trusted)")
        if !trusted {
            let systemWide = AXUIElementCreateSystemWide()
            var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)
        }
        return AXIsProcessTrusted()
    }

    // MARK: - Input Monitoring

    static func hasInputMonitoringAccess() -> Bool {
        // Both probes — CG is what event taps care about.
        if CGPreflightListenEventAccess() { return true }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Force FlowDictate into the Input Monitoring apps list.
    ///
    /// macOS only lists apps that requested privileged event access. `listenOnly`
    /// taps can succeed without listing the app — so registration uses **defaultTap**
    /// (which fails without permission and creates the list entry).
    ///
    /// User must still flip the toggle (cannot be automated by any app, signed or not).
    /// Signing helps stable identity; it is NOT required for the list entry itself.
    @MainActor
    static func ensureInputMonitoringListEntry() {
        if hasInputMonitoringAccess() {
            DiagnosticsLogger.shared.log("input monitoring: already authorized")
            return
        }
        DiagnosticsLogger.shared.log("input monitoring: force list registration")

        // 1) Official request — may show a system alert and/or create the list row.
        let iohid = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        DiagnosticsLogger.shared.log("input monitoring: IOHIDRequestAccess=\(iohid)")

        // 2) Secondary CG request.
        let cg = CGRequestListenEventAccess()
        DiagnosticsLogger.shared.log("input monitoring: CGRequestListenEventAccess=\(cg)")

        // 3) defaultTap attempts — failure is expected and is what registers the binary.
        forceListEntryViaFailedDefaultTaps()
    }

    @MainActor
    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        ensureInputMonitoringListEntry()
        return hasInputMonitoringAccess()
    }

    /// Create default (non-listenOnly) taps. Without IM permission these return nil
    /// and TCC adds the app path to Privacy → Input Monitoring.
    @MainActor
    private static func forceListEntryViaFailedDefaultTaps() {
        let mask =
            CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)

        let attempts: [(CGEventTapLocation, String)] = [
            (.cgSessionEventTap, "session"),
            (.cghidEventTap, "hid"),
            (.cgAnnotatedSessionEventTap, "annotated")
        ]

        for (location, label) in attempts {
            // defaultTap (rawValue 0) requires Input Monitoring — fails → list entry.
            let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            )
            if let tap {
                // Unexpected success without preflight — tear down immediately.
                DiagnosticsLogger.shared.log("input monitoring: defaultTap unexpectedly live (\(label))")
                CFMachPortInvalidate(tap)
            } else {
                DiagnosticsLogger.shared.log("input monitoring: defaultTap failed as expected (\(label)) → should list app")
            }
        }
    }

    // MARK: - Settings

    static func openMicrophoneSettings() { openPane("Privacy_Microphone") }
    static func openAccessibilitySettings() { openPane("Privacy_Accessibility") }
    static func openInputMonitoringSettings() { openPane("Privacy_ListenEvent") }

    private static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
            DiagnosticsLogger.shared.log("open settings \(anchor)")
        }
    }
}
