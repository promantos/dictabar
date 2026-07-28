import AppKit
import SwiftUI

struct PermissionsPanel: View {
    @ObservedObject var center: PermissionCenter
    var needsInputMonitoring: Bool
    var needsAccessibility: Bool = true
    var compact: Bool = false
    var onAllRequiredReady: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header

            permissionRow(
                icon: "mic.fill",
                tint: .pink,
                title: L10n.t("perm.mic"),
                subtitle: L10n.t("perm.micDesc"),
                status: center.microphone,
                required: true,
                actionTitle: actionTitle(for: center.microphone, name: L10n.t("perm.mic")),
                action: { Task { await center.enableMicrophone() } }
            )

            permissionRow(
                icon: "accessibility",
                tint: .blue,
                title: L10n.t("perm.ax"),
                subtitle: L10n.t("perm.axDesc"),
                status: center.accessibility,
                required: needsAccessibility,
                actionTitle: actionTitle(for: center.accessibility, name: L10n.t("perm.ax")),
                action: { Task { await center.enableAccessibility() } }
            )

            if needsInputMonitoring {
                permissionRow(
                    icon: "keyboard",
                    tint: .purple,
                    title: L10n.t("perm.im"),
                    subtitle: L10n.t("perm.imDesc"),
                    status: center.inputMonitoring,
                    required: true,
                    showsAppDragSource: !center.inputMonitoring.isGranted,
                    actionTitle: actionTitle(for: center.inputMonitoring, name: L10n.t("perm.im")),
                    action: { Task { await center.enableInputMonitoring() } }
                )
            }

            if !center.lastMessage.isEmpty {
                Text(center.lastMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }

            footerHints
        }
        .onChange(of: isReady) { _, ready in
            if ready { onAllRequiredReady?() }
        }
        .onAppear { center.refresh() }
    }

    private var isReady: Bool {
        center.isReady(needsAccessibility: needsAccessibility)
            && (!needsInputMonitoring || center.inputMonitoring.isGranted)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                Text(L10n.t("perm.title")).font(.title2.bold())
            }
            HStack(spacing: 8) {
                statusPill(
                    ready: isReady,
                    text: isReady ? L10n.t("perm.ready") : L10n.t("perm.setup")
                )
                Text(progressLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.t("perm.intro"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var progressLabel: String {
        let requiredDone = (center.microphone.isGranted ? 1 : 0)
            + (needsAccessibility && center.accessibility.isGranted ? 1 : 0)
        let requiredTotal = needsAccessibility ? 2 : 1
        if needsInputMonitoring {
            let optional = center.inputMonitoring.isGranted ? 1 : 0
            return L10n.tf("perm.progress", requiredDone + optional, requiredTotal + 1)
        }
        return L10n.tf("perm.progress", requiredDone, requiredTotal)
    }

    private var footerHints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.t("perm.hint1"), systemImage: "arrow.triangle.2.circlepath")
            Label(L10n.t("perm.hint2"), systemImage: "gearshape")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func actionTitle(for status: PermissionAuthStatus, name: String) -> String {
        switch status {
        case .authorized: L10n.t("perm.allowed")
        case .notDetermined: L10n.tf("perm.enable", name)
        case .denied, .restricted: L10n.t("perm.openSettings")
        }
    }

    private func permissionRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        status: PermissionAuthStatus,
        required: Bool,
        showsAppDragSource: Bool = false,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(required ? L10n.t("perm.required") : L10n.t("perm.optional"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer(minLength: 8)
                    statusPill(ready: status.isGranted, text: status.localizedTitle)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: action) {
                        if center.isBusy {
                            ProgressView().controlSize(.small)
                        }
                        Text(actionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(status.isGranted ? .green : tint)
                    .disabled(status.isGranted || center.isBusy)

                    if showsAppDragSource {
                        InputMonitoringDragControl()
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(status.isGranted ? Color.green.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    private func statusPill(ready: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((ready ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }
}

struct PermissionsOnboardingView: View {
    @ObservedObject var center: PermissionCenter
    var needsInputMonitoring: Bool
    var needsAccessibility: Bool
    var onContinue: () -> Void

    private var isReady: Bool {
        center.isReady(needsAccessibility: needsAccessibility)
            && (!needsInputMonitoring || center.inputMonitoring.isGranted)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                Text(L10n.t("perm.welcome"))
                    .font(.largeTitle.bold())
                Text(L10n.t("perm.welcomeBody"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(.top, 28)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)

            ScrollView {
                PermissionsPanel(
                    center: center,
                    needsInputMonitoring: needsInputMonitoring,
                    needsAccessibility: needsAccessibility,
                    compact: true
                )
                .padding(.horizontal, 28)
            }

            HStack {
                Spacer()
                Button(isReady ? L10n.t("perm.done") : L10n.t("perm.later")) {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(width: 560, height: 640)
        .task {
            center.refresh()
        }
    }
}

private struct InputMonitoringDragControl: View {
    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 24, height: 24)
            Text(L10n.t("perm.imDragAction"))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "hand.draw")
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.purple.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay(AppBundleDragSource())
        .help(L10n.t("perm.imDragHint"))
        .accessibilityLabel(L10n.t("perm.imDragTitle"))
    }
}

private struct AppBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragSourceView {
        AppBundleDragSourceView()
    }

    func updateNSView(_ nsView: AppBundleDragSourceView, context: Context) {}
}

private final class AppBundleDragSourceView: NSView, NSDraggingSource {
    private var initialEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        initialEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let initialEvent else { return }
        self.initialEvent = nil

        let writer = AppBundlePasteboardWriter(url: Bundle.main.bundleURL)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = (NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 64, height: 64)
        let point = convert(initialEvent.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(x: point.x - 32, y: point.y - 32, width: 64, height: 64),
            contents: icon
        )
        beginDraggingSession(with: [item], event: initialEvent, source: self)
        DiagnosticsLogger.shared.log("Input Monitoring app-bundle drag started")
    }

    override func mouseUp(with event: NSEvent) {
        initialEvent = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        DiagnosticsLogger.shared.log("Input Monitoring app-bundle drag ended operation=\(operation.rawValue)")
    }
}

private final class AppBundlePasteboardWriter: NSObject, NSPasteboardWriting {
    private let url: URL
    private static let legacyFileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    init(url: URL) {
        self.url = url
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, Self.legacyFileNames]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL:
            url.absoluteString
        case Self.legacyFileNames:
            [url.path]
        default:
            nil
        }
    }
}

extension PermissionAuthStatus {
    var localizedTitle: String {
        switch self {
        case .notDetermined: L10n.t("perm.notEnabled")
        case .denied: L10n.t("perm.denied")
        case .authorized: L10n.t("perm.allowed")
        case .restricted: L10n.t("perm.denied")
        }
    }
}
