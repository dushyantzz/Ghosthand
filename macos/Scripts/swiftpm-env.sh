#!/usr/bin/env bash
# Shared environment for building GhostHand on macOS with SwiftPM.
#
# Why this exists: SwiftPM by default writes its caches to ~/Library/org.swift.swiftpm,
# uses $TMPDIR (/var/folders/...), and wraps manifest compilation in `sandbox-exec`.
# In a restricted environment those paths are not writable and nested sandbox-exec is
# refused. We therefore keep every cache inside the package directory and pass
# --disable-sandbox to SwiftPM.
#
# Usage:  source "$(dirname "$0")/swiftpm-env.sh"

set -euo pipefail

MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$MACOS_DIR"

export TMPDIR="$MACOS_DIR/tmp"
export CLANG_MODULE_CACHE_PATH="$MACOS_DIR/.modulecache"
export SWIFT_MODULE_CACHE_PATH="$MACOS_DIR/.modulecache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

SWIFT_FLAGS=(
  --disable-sandbox
  --cache-path "$MACOS_DIR/.build/cache"
  --config-path "$MACOS_DIR/.build/config"
  --security-path "$MACOS_DIR/.build/security"
  --scratch-path "$MACOS_DIR/.build/scratch"
)

# Resolve a built product path, preferring the requested configuration:
#   print_product_path <name> [debug|release]
print_product_path() {
  local name="$1" config="${2:-debug}" found
  found="$(find "$MACOS_DIR/.build/scratch" -type f -path "*/$config/$name" -perm -111 2>/dev/null | head -1)"
  if [ -z "$found" ]; then
    found="$(find "$MACOS_DIR/.build/scratch" -type f -name "$name" -perm -111 2>/dev/null | head -1)"
  fi
  printf '%s' "$found"
}
