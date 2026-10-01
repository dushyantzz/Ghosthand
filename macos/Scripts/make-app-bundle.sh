#!/usr/bin/env bash
# Build GhostHand.app — a menu-bar application bundle.
#
# SwiftPM produces a bare executable; macOS needs a bundle for a stable bundle id,
# the LSUIElement (menu-bar-only) flag, and the microphone/speech permission prompts.
#
# Usage: Scripts/make-app-bundle.sh [-c release|debug]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swiftpm-env.sh"

CONFIG="debug"
if [ "${1:-}" = "-c" ] && [ -n "${2:-}" ]; then CONFIG="$2"; fi

echo "==> Building GhostHandApp + ghosthand ($CONFIG)"
swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG"

APP_BIN="$(print_product_path GhostHandApp "$CONFIG")"
[ -n "$APP_BIN" ] || { echo "error: GhostHandApp binary not found" >&2; exit 1; }

DIST="$MACOS_DIR/dist"
APP="$DIST/GhostHand.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$APP_BIN" "$APP/Contents/MacOS/GhostHandApp"
cp "$MACOS_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

# The Laya launcher must live beside the executables as well as in Resources, so the
# bundle works even when it is moved away from the SwiftPM build directory.
SRC_SCRIPT="$MACOS_DIR/Scripts/laya_serve.py"
cp "$SRC_SCRIPT" "$APP/Contents/Resources/laya_serve.py"

# Bundle the CLI too, so `GhostHand.app/Contents/MacOS/ghosthand` works for diagnostics.
CLI_BIN="$(print_product_path ghosthand "$CONFIG")"
if [ -n "$CLI_BIN" ]; then cp "$CLI_BIN" "$APP/Contents/MacOS/ghosthand"; fi
cp "$SRC_SCRIPT" "$APP/Contents/MacOS/laya_serve.py"

# Normalise modes so the launcher is readable and the executables are runnable.
chmod 644 "$APP/Contents/Resources/laya_serve.py" "$APP/Contents/MacOS/laya_serve.py"
chmod 755 "$APP/Contents/MacOS/GhostHandApp"
[ -f "$APP/Contents/MacOS/ghosthand" ] && chmod 755 "$APP/Contents/MacOS/ghosthand"

# Ad-hoc signature.
# Re-sign with a Developer ID for distribution.
if ! codesign --force --deep --sign - "$APP" 2>/tmp/ghosthand-codesign.log; then
  echo "warning: ad-hoc codesign failed; the app still runs but permissions may need re-granting"
  sed 's/^/    /' /tmp/ghosthand-codesign.log | head -5
fi

echo "==> Built $APP"
echo "    Run:      open \"$APP\""
echo "    CLI:      \"$APP/Contents/MacOS/ghosthand\" check"
echo ""
echo "Grant Accessibility permission on first use:"
echo "  System Settings > Privacy & Security > Accessibility > GhostHand"
