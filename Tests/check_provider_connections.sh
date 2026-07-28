#!/bin/sh
set -eu

app="${1:-/Applications/FlowDictate.app}"
binary="$app/Contents/MacOS/FlowDictate"

if [ ! -x "$binary" ]; then
  echo "FlowDictate binary not found: $binary" >&2
  exit 1
fi
if pgrep -x FlowDictate >/dev/null; then
  echo "Quit FlowDictate before running provider connection checks." >&2
  exit 1
fi

source_audio=$(mktemp /tmp/FlowDictate-provider-check.XXXXXX.aiff)
test_audio="${source_audio%.aiff}.wav"
trap 'rm -f "$source_audio" "$test_audio"' EXIT INT TERM

say -o "$source_audio" "Flow Dictate provider connection test."
afconvert "$source_audio" "$test_audio" -f WAVE -d LEI16@16000 -c 1
"$binary" --provider-smoke-test "$test_audio"
