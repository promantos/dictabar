#!/bin/sh
set -eu

fail() {
  echo "check_hardening: $1" >&2
  exit 1
}

providers="FlowDictate/TranscriptionProviders.swift"
models="FlowDictate/Models.swift"

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

grep -q 'AVAudioRecorder(url:' FlowDictate/AudioRecorder.swift \
  || fail "proven AVAudioRecorder capture path missing"
grep -q 'recoverInputDeviceIfNeeded' FlowDictate/AudioRecorder.swift \
  || fail "input-device crash recovery missing"
grep -q 'restoreDefaultInputIfNeeded' FlowDictate/AudioRecorder.swift \
  || fail "selected input is not restored"
grep -q 'size > 4_096, frames > 0' FlowDictate/AudioRecorder.swift \
  || fail "empty WAV regression guard missing"
grep -q 'Retry last dictation' FlowDictate/L10n.swift \
  || fail "failed-dictation recovery action missing"
grep -q 'maxFileBytes' FlowDictate/DiagnosticsLogger.swift \
  || fail "diagnostics rotation missing"

grep -q 'Developer ID Application' scripts/release.sh \
  || fail "release does not require Developer ID"
grep -q 'notarytool submit' scripts/release.sh \
  || fail "release does not notarize"
grep -q 'stapler validate' scripts/release.sh \
  || fail "release does not validate staple"
grep -q 'spctl --assess' scripts/release.sh \
  || fail "release does not run Gatekeeper assessment"

echo "check_hardening: ok"
