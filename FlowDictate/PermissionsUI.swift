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
                action: { Task { await center.enableMicrophone() } },
                openSettings: PermissionManager.openMicrophoneSettings
            )

            permissionRow(
                icon: "accessibility",
                tint: .blue,
                title: L10n.t("perm.ax"),
                subtitle: L10n.t("perm.axDesc"),
                status: center.accessibility,
                required: needsAccessibility,
                actionTitle: actionTitle(for: center.accessibility, name: L10n.t("perm.ax")),
                action: { Task { await center.enableAccessibility() } },
                openSettings: PermissionManager.openAccessibilitySettings
            )

            if needsInputMonitoring {
                permissionRow(
                    icon: "keyboard",
                    tint: .purple,
                    title: L10n.t("perm.im"),
                    subtitle: L10n.t("perm.imDesc"),
                    status: center.inputMonitoring,
                    required: false,
                    actionTitle: actionTitle(for: center.inputMonitoring, name: L10n.t("perm.im")),
                    action: { Task { await center.enableInputMonitoring() } },
                    openSettings: PermissionManager.openInputMonitoringSettings
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
        .onChange(of: center.isReady(needsAccessibility: needsAccessibility)) { _, ready in
            if ready { onAllRequiredReady?() }
        }
        .onAppear { center.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                Text(L10n.t("perm.title")).font(.title2.bold())
            }
            HStack(spacing: 8) {
                statusPill(
                    ready: center.isReady(needsAccessibility: needsAccessibility),
                    text: center.isReady(needsAccessibility: needsAccessibility) ? L10n.t("perm.ready") : L10n.t("perm.setup")
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
        actionTitle: String,
        action: @escaping () -> Void,
        openSettings: @escaping () -> Void
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

                    if !status.isGranted {
                        Button(L10n.t("perm.openSettings"), action: openSettings)
                            .buttonStyle(.bordered)
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
    var onOpenFullSettings: () -> Void

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
                Button(L10n.t("perm.openFull")) { onOpenFullSettings() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(center.isReady(needsAccessibility: needsAccessibility) ? L10n.t("perm.done") : L10n.t("perm.later")) {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(width: 560, height: 640)
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
