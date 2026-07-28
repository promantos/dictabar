import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var window: NSWindow?
    private var host: NSHostingController<RecordingOverlay>?
    private var hideTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    /// Last message shown for .recording — timer ticks must not overwrite L10n.
    private var recordingMessage = ""

    func show(
        kind: RecordingOverlay.Kind,
        message: String,
        settings: SettingsStore.OverlayPresentation,
        autoHide: Bool = false
    ) {
        if kind == .recording {
            recordingStartedAt = settings.recordingStartedAt ?? Date()
            recordingMessage = message
        } else {
            timerTask?.cancel()
            timerTask = nil
        }

        render(kind: kind, message: message, settings: settings, elapsed: elapsedString(settings: settings))

        if kind == .recording, settings.showTimer {
            startTimer(settings: settings)
        }

        if autoHide {
            self.autoHide()
        } else {
            hideTask?.cancel()
            hideTask = nil
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        timerTask?.cancel()
        timerTask = nil
        recordingStartedAt = nil
        recordingMessage = ""
        window?.orderOut(nil)
    }

    private func startTimer(settings: SettingsStore.OverlayPresentation) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.recordingStartedAt != nil else { return }
                    self.render(
                        kind: .recording,
                        message: self.recordingMessage,
                        settings: settings,
                        elapsed: self.elapsedString(settings: settings)
                    )
                }
            }
        }
    }

    private func elapsedString(settings: SettingsStore.OverlayPresentation) -> String? {
        guard settings.showTimer, let start = recordingStartedAt else { return nil }
        let sec = Int(Date().timeIntervalSince(start))
        return String(format: "%d:%02d", sec / 60, sec % 60)
    }

    private func render(
        kind: RecordingOverlay.Kind,
        message: String,
        settings: SettingsStore.OverlayPresentation,
        elapsed: String?
    ) {
        let view = RecordingOverlay(kind: kind, message: message, settings: settings, elapsed: elapsed)
        if window == nil {
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.borderless]
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.hasShadow = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.host = host
            self.window = window
        } else {
            host?.rootView = view
        }

        var width: CGFloat = 200
        if message.count > 40 { width = 320 }
        if settings.showProvider || settings.showMicrophone || elapsed != nil { width = max(width, 240) }
        positionWindow(settings.position, preferredWidth: width)
        window?.orderFrontRegardless()
    }

    private func autoHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            await MainActor.run { self?.hide() }
        }
    }

    private func positionWindow(_ position: OverlayPosition, preferredWidth: CGFloat) {
        guard let window else { return }
        let height: CGFloat = 56
        let width = max(180, preferredWidth)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let margin: CGFloat = 18
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topCenter:
            x = visible.midX - width / 2
            y = visible.maxY - height - margin
        case .topLeft:
            x = visible.minX + margin
            y = visible.maxY - height - margin
        case .topRight:
            x = visible.maxX - width - margin
            y = visible.maxY - height - margin
        case .bottomCenter:
            x = visible.midX - width / 2
            y = visible.minY + margin
        case .bottomLeft:
            x = visible.minX + margin
            y = visible.minY + margin
        case .bottomRight:
            x = visible.maxX - width - margin
            y = visible.minY + margin
        }
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

struct RecordingOverlay: View {
    enum Kind {
        case recording, processing, success, error
    }

    let kind: Kind
    let message: String
    let settings: SettingsStore.OverlayPresentation
    var elapsed: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                    if let elapsed {
                        Text(elapsed)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                metaLine
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: Capsule())
        .padding(4)
    }

    @ViewBuilder
    private var metaLine: some View {
        let parts: [String] = {
            var p: [String] = []
            if settings.showProvider, let name = settings.providerName { p.append(name) }
            if settings.showMicrophone, let mic = settings.microphoneName { p.append(mic) }
            return p
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .recording:
            Circle().fill(Color.red).frame(width: 10, height: 10)
        case .processing:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
