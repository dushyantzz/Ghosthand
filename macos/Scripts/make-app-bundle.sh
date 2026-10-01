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

# Signing.
#
# Prefer a stable local identity. macOS keys Accessibility / Screen Recording / Input Monitoring
# grants to the code signature, and an ad-hoc signature changes on every rebuild — which silently
# invalidates those grants. A self-signed certificate gives a constant identity, so grants survive
# rebuilds. Create one with: Scripts/create-signing-identity.sh
LOCAL_IDENTITY="${GHOSTHAND_SIGNING_IDENTITY:-GhostHand Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
  SIGN_ID="$LOCAL_IDENTITY"
  echo "==> Signing with '$LOCAL_IDENTITY' (stable identity — permissions survive rebuilds)"
else
  SIGN_ID="-"
  echo "==> Signing ad-hoc (permissions must be re-granted after every rebuild)"
  echo "    Run Scripts/create-signing-identity.sh once to stop that."
fi

# --deep also signs the nested CLI binary and the bundled launcher script, which codesign treats
# as nested code. (For distribution, sign nested code explicitly instead — see RELEASING.md.)
sign_bundle() {
  codesign --force --deep --sign "$SIGN_ID" "$APP"
}

if ! sign_bundle 2>/tmp/ghosthand-codesign.log; then
  echo "warning: signing with '$SIGN_ID' failed"
  sed 's/^/    /' /tmp/ghosthand-codesign.log | head -5
  if [ "$SIGN_ID" != "-" ]; then
    echo "==> Falling back to an ad-hoc signature so the bundle is never left unsigned"
    if ! codesign --force --deep --sign - "$APP" 2>>/tmp/ghosthand-codesign.log; then
      echo "warning: ad-hoc codesign also failed; the app may not launch"
    fi
  fi
fi

echo "==> Built $APP"
echo "    Run:      open \"$APP\""
echo "    CLI:      \"$APP/Contents/MacOS/ghosthand\" check"
echo ""
echo "Grant Accessibility permission on first use:"
echo "  System Settings > Privacy & Security > Accessibility > GhostHand"
echo ""
echo "Note: this rebuild changed the code signature, so any previous Accessibility /"
echo "      Screen Recording grant no longer applies to this binary. Re-grant it, or run"
echo "      Scripts/reset-permissions.sh first to clear the stale entry."
