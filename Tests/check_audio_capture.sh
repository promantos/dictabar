#!/bin/sh
set -eu

app="${1:-/Applications/FlowDictate.app}"
binary="$app/Contents/MacOS/FlowDictate"

if [ ! -x "$binary" ]; then
  echo "FlowDictate binary not found: $binary" >&2
  exit 1
fi
if pgrep -x FlowDictate >/dev/null; then
  echo "Quit FlowDictate before running the audio capture check." >&2
  exit 1
fi

"$binary" --audio-smoke-test
