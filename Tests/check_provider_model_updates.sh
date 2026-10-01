#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/dictabar-model-update-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
CLANG_MODULE_CACHE_PATH="$check_dir/clang" \
SWIFT_MODULECACHE_PATH="$check_dir/swift" \
xcrun swiftc \
  "$root/Dictabar/L10n.swift" \
  "$root/Dictabar/Models.swift" \
  "$root/Dictabar/MultipartFormData.swift" \
  "$root/Dictabar/DiagnosticsLogger.swift" \
  "$root/Dictabar/TranscriptionProviders.swift" \
  "$root/Dictabar/NewTranscriptionProviders.swift" \
  "$root/Dictabar/GeminiTranscriptionProvider.swift" \
  "$root/Tests/ProviderModelUpdatesCheck.swift" \
  -o "$check_dir/provider-model-updates"
"$check_dir/provider-model-updates"
