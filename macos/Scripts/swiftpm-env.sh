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

# Optional architectures for distribution builds. Defaults to the host arch; set
# GHOSTHAND_ARCHS="x86_64 arm64" to produce a universal binary, e.g.
#   GHOSTHAND_ARCHS="x86_64 arm64" Scripts/make-app-bundle.sh -c release
if [ -n "${GHOSTHAND_ARCHS:-}" ]; then
  for arch in $GHOSTHAND_ARCHS; do
    SWIFT_FLAGS+=(--arch "$arch")
  done
fi

# Resolve a built product path, preferring the requested configuration:
#   print_product_path <name> [debug|release]
print_product_path() {
  local name="$1" config="${2:-debug}" found
  # A multi-arch build (GHOSTHAND_ARCHS) puts the universal product under
  # .build/scratch/apple/Products/<Config>/. Prefer it, otherwise the per-arch copy under
  # .build/scratch/<triple>/<config>/ would win and ship a single-architecture bundle.
  if [ -n "${GHOSTHAND_ARCHS:-}" ] && [ -d "$MACOS_DIR/.build/scratch/apple/Products" ]; then
    found="$(find "$MACOS_DIR/.build/scratch/apple/Products" -type f -name "$name" -perm -111 2>/dev/null | head -1)"
    if [ -n "$found" ]; then printf '%s' "$found"; return; fi
  fi
  found="$(find "$MACOS_DIR/.build" -type f -name "$name" -perm -111 -path "*/$config/*" \
    -not -path "*/Intermediates*" 2>/dev/null \
    | while IFS= read -r candidate; do
        printf '%s\t%s\n' "$(stat -f '%m' "$candidate")" "$candidate"
      done \
    | sort -rn | head -1 | cut -f2-)"
  printf '%s' "$found"
}
