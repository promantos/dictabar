#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
models="$root/Dictabar/Models.swift"
providers="$root/Dictabar/TranscriptionProviders.swift"
check_dir="$(mktemp -d /tmp/dictabar-provider-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT

expected=(
  local openAI groq deepgram mistral soniox gladia speechmatics elevenLabs assemblyAI
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
[[ "$(sed -n '/case \\.openRouter:/,/case \\.azureSpeech:/p' "$models" | grep -c 'SpeechModelInfo(id:')" -eq 12 ]]
grep -q 'nvidia/parakeet-tdt-0.6b-v3' "$models"
grep -q 'qwen/qwen3-asr-flash-2026-02-10' "$models"
grep -q 'x-ai/grok-stt-1.0' "$models"
grep -q 'deepgram/nova-3' "$models"
grep -q 'google/chirp-3' "$models"
grep -q 'mistralai/voxtral-mini-transcribe' "$models"
grep -q 'audio-prod.api.fireworks.ai/v1' "$providers"
grep -q 'audio-turbo.api.fireworks.ai/v1' "$providers"

fireworks_block="$(sed -n '/struct FireworksTranscriptionProvider/,/\/\/ MARK: - Together AI/p' "$providers")"
grep -q 'request.setValue(apiKey, forHTTPHeaderField: "Authorization")' <<<"$fireworks_block"
if grep -q '"Bearer \\(apiKey\\)"' <<<"$fireworks_block"; then
  echo "Fireworks Audio API must receive the raw API key, not a Bearer token" >&2
  exit 1
fi

# Dictabar sends complete WAV files; realtime-only model IDs must stay out.
! grep -q 'flux-general-multi' "$models"
! grep -q '"ink-2"' "$models"
! grep -q 'stt-rt-' "$models"

key_links="$(grep -c 'case .*value = "https://' "$models")"
[[ "$key_links" -eq 26 ]] || {
  echo "Expected 26 provider links, found $key_links" >&2
  exit 1
}

# Local models stay in one catalog and one pinned native runtime.
local_models="$root/Dictabar/LocalModels.swift"
project="$root/Dictabar.xcodeproj/project.pbxproj"
for model in \
  'Parakeet TDT 0.6B v3' \
  'Nemotron 3.5 ASR' \
  'Qwen3-ASR 0.6B' \
  'MOSS-Transcribe-Diarize 0.9B (INT5)'; do
  grep -q "$model" "$models"
done
! grep -q 'CrisperWhisper\|case \.crisper' "$models" "$local_models" "$root/Dictabar/L10n.swift"
grep -q 'case \.local: LocalTranscriptionProvider()' "$providers"
grep -q 'LocalModelStorage.isInstalled' "$local_models"
grep -q 'func unloadAll()' "$local_models"
grep -q 'Memory.clearCache()' "$local_models"
grep -q 'LocalModelManager.shared.unload()' "$root/Dictabar/SettingsStore.swift"
grep -q 'local.unload' "$root/Dictabar/SettingsView.swift"
grep -q 'revision = 555bede026f6663cef998c2458af7daf04aa79f2' "$project"

CLANG_MODULE_CACHE_PATH="$check_dir/clang" \
SWIFT_MODULECACHE_PATH="$check_dir/swift" \
xcrun swiftc \
  "$root/Dictabar/L10n.swift" \
  "$root/Dictabar/Models.swift" \
  "$root/Dictabar/MultipartFormData.swift" \
  "$root/Dictabar/DiagnosticsLogger.swift" \
  "$providers" \
  "$root/Tests/AWSSignerCheck.swift" \
  -o "$check_dir/aws-signer-check"
"$check_dir/aws-signer-check"

ruby -e '
  languages = %w[en ru es de fr pt zh-Hans ja ko it tr]
  File.foreach(ARGV.fetch(0)).with_index(1) do |line, number|
    next unless line =~ /^\s*"([^"]+)": \[/
    key = $1
    missing = languages.reject { |language| line.include?("\"#{language}\":") }
    abort "Missing #{missing.join(", ")} localization for #{key} on line #{number}" unless missing.empty?
    values = line.scan(/"([^"]+)": "((?:\\.|[^"])*)"/).to_h
    placeholders = values.fetch("en").scan(/%(?:@|d)/)
    languages.each do |language|
      actual = values.fetch(language).scan(/%(?:@|d)/)
      abort "Placeholder mismatch for #{key} (#{language}) on line #{number}" unless actual == placeholders
    end
  end
' "$root/Dictabar/L10n.swift"

echo "Provider catalog OK: 26 providers, 4 local choices with verified language counts, complete localization, single-model runtime, batch/file adapters, links, and no realtime-only models."
