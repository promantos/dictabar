#!/bin/sh
set -eu

app="${1:-/Applications/Dictabar.app}"
binary="$app/Contents/MacOS/Dictabar"

if [ ! -x "$binary" ]; then
  echo "Dictabar binary not found: $binary" >&2
  exit 1
fi

result=$("$binary" --local-inference-bridge-smoke-test)
if [ "$result" != "local-inference-bridge-check: ok" ]; then
  echo "$result" >&2
  echo "Local inference worker bridge check failed." >&2
  exit 1
fi

echo "$result"
