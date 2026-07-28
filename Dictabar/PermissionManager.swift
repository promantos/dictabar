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
