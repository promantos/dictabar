#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
models="$root/FlowDictate/Models.swift"
providers="$root/FlowDictate/TranscriptionProviders.swift"
check_dir="$(mktemp -d /tmp/flowdictate-provider-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT

expected=(
  openAI groq deepgram mistral soniox gladia speechmatics elevenLabs assemblyAI
  openRouter azureSpeech googleCloud fireworks together smallestAI alibaba xAI
  amazonTranscribe inworld cartesia gradium modulate cohere cloudflare custom
)

for provider in "${expected[@]}"; do
  grep -q "case \\.$provider:" "$providers" || {
    echo "Missing ProviderRegistry adapter: $provider" >&2
    exit 1
  }
done

[[ "$(grep -c 'case .* = "' "$models" | head -1)" -ge 25 ]]
grep -q 'stt-async-v5' "$models"
grep -q 'mai-transcribe-1.5' "$models"
grep -q 'scribe_v2' "$models"

# FlowDictate sends complete WAV files; realtime-only model IDs must stay out.
! grep -q 'flux-general-multi' "$models"
! grep -q '"ink-2"' "$models"
! grep -q 'stt-rt-' "$models"

key_links="$(grep -c 'case .*value = "https://' "$models")"
[[ "$key_links" -eq 25 ]] || {
  echo "Expected 25 API-key links, found $key_links" >&2
  exit 1
}

CLANG_MODULE_CACHE_PATH="$check_dir/clang" \
SWIFT_MODULECACHE_PATH="$check_dir/swift" \
xcrun swiftc \
  "$root/FlowDictate/L10n.swift" \
  "$root/FlowDictate/Models.swift" \
  "$root/FlowDictate/MultipartFormData.swift" \
  "$root/FlowDictate/DiagnosticsLogger.swift" \
  "$providers" \
  "$root/Tests/AWSSignerCheck.swift" \
  -o "$check_dir/aws-signer-check"
"$check_dir/aws-signer-check"

echo "Provider catalog OK: 25 providers, batch/file adapters, key links, and no realtime-only models."
