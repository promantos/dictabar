#!/bin/sh
set -eu

app="${1:-/Applications/Dictabar.app}"
binary="$app/Contents/MacOS/Dictabar"

if [ ! -x "$binary" ]; then
  echo "Dictabar binary not found: $binary" >&2
  exit 1
fi
if pgrep -x Dictabar >/dev/null; then
  echo "Quit Dictabar before running the audio capture check." >&2
  exit 1
fi

"$binary" --audio-smoke-test
