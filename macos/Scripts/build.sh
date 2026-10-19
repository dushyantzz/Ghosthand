#!/usr/bin/env bash
# Build GhostHand (debug by default). Pass -c release for a release build.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftpm-env.sh"
echo "==> swift build $* (cwd: $MACOS_DIR)"
swift build "${SWIFT_FLAGS[@]}" "$@"
echo "==> binaries:"
for p in ghosthand GhostHandApp; do
  path="$(print_product_path "$p")"
  [ -n "$path" ] && echo "    $p -> $path"
done
