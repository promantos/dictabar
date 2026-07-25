import Foundation

@MainActor
final class AppState: ObservableObject {
    enum DictationState: Equatable {
        case idle
        case starting
        case recording
        case transcribing
        case needsMicrophonePermission
        case needsAccessibilityPermission
        case failed(String)
    }

    @Published var dictationState: DictationState = .idle
    @Published var lastTranscript = ""
    @Published var lastError = ""
    @Published var selectedSettingsSection: String {
        didSet { UserDefaults.standard.set(selectedSettingsSection, forKey: "selectedSettingsSection") }
    }
    @Published var recordingShortcut = false
    /// First-run / incomplete permissions setup.
    @Published var showPermissionsOnboarding: Bool
    /// First-run quick start (provider + key). Independent of permissions sheet.
    @Published var showQuickStart: Bool

    private static let onboardingCompletedKey = "permissionsOnboardingCompleted"
    private static let quickStartCompletedKey = "quickStartCompleted"

    init() {
        selectedSettingsSection = UserDefaults.standard.string(forKey: "selectedSettingsSection") ?? "General"
        // Menu-bar apps should never surface sheets on cold launch without a user action —
        // AppDelegate may open Quick Start once after launch if not completed.
        showPermissionsOnboarding = false
        showQuickStart = false
    }

    var quickStartCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.quickStartCompletedKey)
    }

    func completePermissionsOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        showPermissionsOnboarding = false
    }

    func reopenPermissionsOnboarding() {
        showPermissionsOnboarding = true
    }

    func completeQuickStart() {
        UserDefaults.standard.set(true, forKey: Self.quickStartCompletedKey)
        showQuickStart = false
    }

    func reopenQuickStart() {
        showQuickStart = true
    }

    var statusTitle: String {
        switch dictationState {
        case .idle: "FlowDictate"
        case .starting: "Starting..."
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .needsMicrophonePermission: "Allow Microphone"
        case .needsAccessibilityPermission: "Allow Accessibility"
        case let .failed(message): message
        }
    }

    var isDictationActive: Bool {
        switch dictationState {
        case .starting, .recording, .transcribing: true
        default: false
        }
    }
}
