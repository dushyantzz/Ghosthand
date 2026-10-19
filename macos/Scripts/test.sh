#!/usr/bin/env bash
# Run the GhostHand unit tests.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftpm-env.sh"
swift test "${SWIFT_FLAGS[@]}" "$@"
