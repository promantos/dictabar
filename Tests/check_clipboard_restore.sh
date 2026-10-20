#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/dictabar-clipboard-check.XXXXXX)"
trap 'rm -rf "$check_dir"' EXIT
CLANG_MODULE_CACHE_PATH="$check_dir/clang" SWIFT_MODULECACHE_PATH="$check_dir/swift" xcrun swiftc \
  "$root/Dictabar/TextInsertionService.swift" "$root/Tests/ClipboardRestoreCheck.swift" \
  -o "$check_dir/clipboard-check"
"$check_dir/clipboard-check"
