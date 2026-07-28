#!/bin/sh
set -eu

app="${1:-/Applications/FlowDictate.app}"
binary="$app/Contents/MacOS/FlowDictate"
max_cpu_percent="${MAX_IDLE_CPU_PERCENT:-0.5}"
max_footprint_kb="${MAX_IDLE_FOOTPRINT_KB:-40960}"

if [ ! -x "$binary" ]; then
  echo "FlowDictate binary not found: $binary" >&2
  exit 1
fi
if pgrep -x FlowDictate >/dev/null; then
  echo "Quit FlowDictate before running the idle resource check." >&2
  exit 1
fi

"$binary" >/tmp/flowdictate-idle-check.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
  echo "FlowDictate exited during idle resource check." >&2
  exit 1
fi

cpu_seconds() {
  ps -p "$pid" -o cputime= | awk -F: '
    NF == 3 { print ($1 * 3600) + ($2 * 60) + $3; next }
    NF == 2 { print ($1 * 60) + $2 }
  '
}

cpu_start=$(cpu_seconds)
sleep 10
cpu_end=$(cpu_seconds)
footprint_kb=$(footprint -p "$pid" | awk '
  /phys_footprint:/ {
    value = $2
    if ($3 == "GB") value *= 1024 * 1024
    else if ($3 == "MB") value *= 1024
    else if ($3 == "KB") value *= 1
    else value /= 1024
    printf "%.0f", value
    exit
  }
')
cpu_percent=$(awk -v start="$cpu_start" -v end="$cpu_end" 'BEGIN { printf "%.2f", (end - start) * 10 }')

awk -v actual="$cpu_percent" -v limit="$max_cpu_percent" 'BEGIN { exit !(actual <= limit) }' \
  || {
    echo "Idle CPU ${cpu_percent}% exceeds ${max_cpu_percent}%." >&2
    exit 1
  }
if [ -z "$footprint_kb" ]; then
  echo "Could not read FlowDictate physical footprint." >&2
  exit 1
fi
if [ "$footprint_kb" -gt "$max_footprint_kb" ]; then
  echo "Idle footprint ${footprint_kb} KB exceeds ${max_footprint_kb} KB." >&2
  exit 1
fi

echo "idle-resource-check: ok cpu=${cpu_percent}% footprint=${footprint_kb}KB"
