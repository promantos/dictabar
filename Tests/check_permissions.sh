#!/bin/sh
set -eu

plist="Dictabar/Info.plist"
plutil -lint "$plist" >/dev/null

plutil -extract NSMicrophoneUsageDescription raw "$plist" >/dev/null

if plutil -extract NSCameraUsageDescription raw "$plist" >/dev/null 2>&1; then
  echo "unexpected camera permission"
  exit 1
fi

if rg -q "ScreenCapture|NSCameraUsageDescription" Dictabar; then
  echo "unexpected extra privacy permission"
  exit 1
fi

rg -q "AVCaptureDevice.requestAccess\\(for: \\.audio\\)" Dictabar/PermissionManager.swift
rg -q "AXIsProcessTrustedWithOptions" Dictabar/PermissionManager.swift
! rg -q "CGRequestListenEventAccess|IOHIDRequestAccess" Dictabar/PermissionManager.swift
rg -q "CGEvent.tapCreate" Dictabar/GlobalShortcutManager.swift
rg -Fq "#selector(NSApplication.terminate" Dictabar/DictabarApp.swift
rg -Fq "#selector(NSText.paste" Dictabar/DictabarApp.swift
! rg -q "center\\.microphone == \\.notDetermined" Dictabar/PermissionsUI.swift
rg -Fq "NSDraggingItem(pasteboardWriter: writer)" Dictabar/PermissionsUI.swift
rg -Fq "beginDraggingSession(with: [item]" Dictabar/PermissionsUI.swift
rg -Fq '.fileURL, .URL, Self.legacyFileNames' Dictabar/PermissionsUI.swift
! rg -q "ensureInputMonitoringListEntry|requestInputMonitoringAccess" Dictabar
! rg -q "Auto-dismiss permissions window" Dictabar/DictabarApp.swift
! rg -Fq 'Button(L10n.t("perm.openSettings")' Dictabar/PermissionsUI.swift
rg -q "TranscriptionProvider" Dictabar
rg -q "provider.transcribe" Dictabar/DictationController.swift
rg -q "TextInsertionService.insert" Dictabar/DictationController.swift
rg -q "guard case \\.recording = appState.dictationState else \\{ return \\}" Dictabar/DictationController.swift
rg -q "apiKeyForTranscription" Dictabar/SettingsStore.swift
rg -q "LocalSecretStore" Dictabar/SettingsStore.swift
# Launch must stay silent: no secret reads, permission requests, or onboarding windows.
! rg -q "LocalSecretStore\\.warmCache" Dictabar/DictabarApp.swift Dictabar/SettingsStore.swift
launch_block="$(sed -n '/func applicationDidFinishLaunching/,/func applicationShouldHandleReopen/p' Dictabar/DictabarApp.swift)"
! printf '%s\n' "$launch_block" | rg -q "showPermissionsOnboarding"
# macOS supplies glass to navigation and controls; never wrap settings cards in default glass capsules.
! rg -q "glassEffect\\(|Capsule\\(" Dictabar/SettingsView.swift
# Keep system UI stable: one persistent status item and no SwiftUI child-window popovers.
[ "$(rg -c "NSStatusBar\\.system\\.statusItem" Dictabar/DictabarApp.swift)" -eq 1 ]
! rg -q "\\.popover\\(" Dictabar/SettingsView.swift
# Disabled callbacks must self-heal without a permanent polling timer.
rg -q "tapDisabledByTimeout.*tapDisabledByUserInput" Dictabar/GlobalShortcutManager.swift
rg -q "CGEvent\\.tapEnable" Dictabar/GlobalShortcutManager.swift
! rg -q "watchdog" Dictabar/GlobalShortcutManager.swift
# Local secrets must avoid Keychain prompts and enforce private file permissions.
! rg -q "SecItem|kSecClass|import Security" Dictabar/LocalSecretStore.swift
rg -q "posixPermissions: 0o600" Dictabar/LocalSecretStore.swift
rg -q "posixPermissions: 0o700" Dictabar/LocalSecretStore.swift
# Block unsafe pasteboard API calls.
if rg -q "\.writeObjects\(" Dictabar --glob '*.swift'; then
  echo "unexpected unsafe pasteboard API (.writeObjects)"
  exit 1
fi
# Security hardening regressions
rg -q "blocked redirect" Dictabar/TranscriptionProviders.swift
rg -q "restoreClipboardIfNeeded" Dictabar/TextInsertionService.swift
rg -q "cleanupStaleTempRecordings" Dictabar/AudioRecorder.swift
rg -q "recoverIfNeeded" Dictabar/SystemAudioMuteService.swift
rg -q "SPUStandardUpdaterController" Dictabar/UpdateManager.swift
rg -q "sanitizedBaseURL" Dictabar/Models.swift
echo "check_permissions: ok"
