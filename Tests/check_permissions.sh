#!/bin/sh
set -eu

plist="FlowDictate/Info.plist"
plutil -lint "$plist" >/dev/null

plutil -extract NSMicrophoneUsageDescription raw "$plist" >/dev/null

if plutil -extract NSCameraUsageDescription raw "$plist" >/dev/null 2>&1; then
  echo "unexpected camera permission"
  exit 1
fi

if rg -q "ScreenCapture|NSCameraUsageDescription" FlowDictate; then
  echo "unexpected extra privacy permission"
  exit 1
fi

rg -q "AVCaptureDevice.requestAccess\\(for: \\.audio\\)" FlowDictate/PermissionManager.swift
rg -q "AXIsProcessTrustedWithOptions" FlowDictate/PermissionManager.swift
rg -q "CGRequestListenEventAccess" FlowDictate/PermissionManager.swift
rg -q "CGEvent.tapCreate" FlowDictate/GlobalShortcutManager.swift
rg -q "TranscriptionProvider" FlowDictate
rg -q "provider.transcribe" FlowDictate/DictationController.swift
rg -q "TextInsertionService.insert" FlowDictate/DictationController.swift
rg -q "guard case \\.recording = appState.dictationState else \\{ return \\}" FlowDictate/DictationController.swift
rg -q "apiKeyForTranscription" FlowDictate/SettingsStore.swift
rg -q "LocalSecretStore" FlowDictate/SettingsStore.swift
# Keychain (SecItem) is expected via LocalSecretStore. Block only unsafe pasteboard API calls.
if rg -q "\.writeObjects\(" FlowDictate --glob '*.swift'; then
  echo "unexpected unsafe pasteboard API (.writeObjects)"
  exit 1
fi
# Security hardening regressions
rg -q "blocked redirect" FlowDictate/TranscriptionProviders.swift
rg -q "restoreClipboardIfNeeded" FlowDictate/TextInsertionService.swift
rg -q "cleanupStaleTempRecordings" FlowDictate/AudioRecorder.swift
rg -q "recoverIfNeeded" FlowDictate/SystemAudioMuteService.swift
rg -q "isAllowedHTTPS" FlowDictate/UpdateManager.swift
rg -q "sanitizedBaseURL" FlowDictate/Models.swift
echo "check_permissions: ok"
