#!/bin/sh
set -eu

fail() {
  echo "check_hardening: $1" >&2
  exit 1
}

providers="Dictabar/TranscriptionProviders.swift"
models="Dictabar/Models.swift"

grep -q '"speech_models": \[settings.model\]' "$providers" \
  || fail "AssemblyAI must use speech_models"
grep -q 'universal-3-pro' "$models" || fail "AssemblyAI current models missing"
! grep -q 'modelList(\["universal", "nano", "best"\]' "$models" \
  || fail "deprecated AssemblyAI models returned"

grep -q 'maxAttempts = 3' "$providers" || fail "bounded network retries missing"
grep -q 'waitsForConnectivity = true' "$providers" || fail "connectivity waiting missing"
! grep -q 'request.httpBody = form.data' "$providers" \
  || fail "multipart recording is buffered in memory"
grep -q 'fromFile: bodyFile' "$providers" || fail "file-backed uploads missing"

grep -q 'AVAudioRecorder(url:' Dictabar/AudioRecorder.swift \
  || fail "proven AVAudioRecorder capture path missing"
grep -q 'recoverInputDeviceIfNeeded' Dictabar/AudioRecorder.swift \
  || fail "input-device crash recovery missing"
grep -q 'restoreDefaultInputIfNeeded' Dictabar/AudioRecorder.swift \
  || fail "selected input is not restored"
grep -q 'size > 4_096, frames > 0' Dictabar/AudioRecorder.swift \
  || fail "empty WAV regression guard missing"
grep -q 'recovery: removed invalid empty recording' Dictabar/DictationController.swift \
  || fail "invalid failed-recording cleanup missing"
grep -q 'Retry last dictation' Dictabar/L10n.swift \
  || fail "failed-dictation recovery action missing"
grep -q 'maxFileBytes' Dictabar/DiagnosticsLogger.swift \
  || fail "diagnostics rotation missing"
! grep -q '\.toolTip' Dictabar/DictabarApp.swift \
  || fail "menu-bar tooltip reintroduces idle AppKit wakeups"
grep -q 'private var microphoneManager: MicrophoneDeviceManager?' Dictabar/DictabarApp.swift \
  || fail "microphone discovery is initialized while idle"
grep -q 'microphoneManager = nil' Dictabar/DictabarApp.swift \
  || fail "microphone discovery survives after Settings closes"
! grep -q 'struct DictabarApp: App' Dictabar/DictabarApp.swift \
  || fail "hidden SwiftUI scene is loaded while idle"
grep -q 'refreshMenuTitles(provider: provider)' Dictabar/DictabarApp.swift \
  || fail "menu bar provider can lag behind Settings"
grep -q 'statusMenu?.popUp' Dictabar/DictabarApp.swift \
  || fail "persistent status-item menu can keep AppKit tracking active"
grep -q 'NSStatusBar.system.removeStatusItem(item)' Dictabar/DictabarApp.swift \
  || fail "closed status menu does not return to cold idle"

settings="Dictabar/SettingsStore.swift"
grep -q 'saveTranscriptHistory = defaults.object(forKey: "saveTranscriptHistory") as? Bool ?? true' "$settings" \
  || fail "fresh installs do not inherit the release transcript-history setting"
grep -q 'privatePreview = defaults.object(forKey: "privatePreview") as? Bool ?? false' "$settings" \
  || fail "fresh installs do not inherit the release preview-privacy setting"
grep -q 'muteWhileRecording = defaults.object(forKey: "muteWhileRecording") as? Bool ?? true' "$settings" \
  || fail "fresh installs do not inherit the release audio-muting setting"
grep -q 'minimumRecordingDuration = defaults.object(forKey: "minimumRecordingDuration") as? Double ?? 0.2' "$settings" \
  || fail "fresh installs do not inherit the release minimum duration"
grep -q 'maximumRecordingDuration = defaults.object(forKey: "maximumRecordingDuration") as? Double ?? 600' "$settings" \
  || fail "fresh installs do not inherit the release maximum duration"
grep -q 'addTrailingSpace = defaults.object(forKey: "addTrailingSpace") as? Bool ?? true' "$settings" \
  || fail "fresh installs do not inherit the release trailing-space setting"
grep -q 'copyOnInsertionFailure = defaults.object(forKey: "copyOnInsertionFailure") as? Bool ?? false' "$settings" \
  || fail "fresh installs do not inherit the release insertion-failure setting"
grep -q 'showProviderInOverlay = defaults.object(forKey: "showProviderInOverlay") as? Bool ?? true' "$settings" \
  || fail "fresh installs do not inherit the release provider-overlay setting"
grep -q 'showMicrophoneInOverlay = defaults.object(forKey: "showMicrophoneInOverlay") as? Bool ?? true' "$settings" \
  || fail "fresh installs do not inherit the release microphone-overlay setting"
grep -q 'provider = \.openAI' "$settings" \
  || fail "reset must not copy the maintainer's selected provider"
grep -q 'selectedMicrophoneID = ""' "$settings" \
  || fail "factory defaults must not copy a machine-specific microphone"

grep -q 'Developer ID Application' scripts/release.sh \
  || fail "release does not require Developer ID"
grep -q 'notarytool submit' scripts/release.sh \
  || fail "release does not notarize"
grep -q 'stapler validate' scripts/release.sh \
  || fail "release does not validate staple"
grep -q 'spctl --assess' scripts/release.sh \
  || fail "release does not run Gatekeeper assessment"

echo "check_hardening: ok"
