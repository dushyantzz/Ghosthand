#!/usr/bin/env bash
# Clear GhostHand's stale TCC decisions and open the right settings pane.
#
# macOS keys Accessibility / Screen Recording / Input Monitoring grants to the app's *code
# signature*. The local build is ad-hoc signed, so every rebuild changes that signature and the
# existing switch silently stops applying — it still looks enabled, but the running app is a
# different identity. Toggling it does nothing; the stale entry has to be cleared first.
#
# Usage: Scripts/reset-permissions.sh [service ...]
#        Scripts/reset-permissions.sh                 # Accessibility + Screen Recording
#        Scripts/reset-permissions.sh ListenEvent     # also reset the hotkey grant
set -euo pipefail

BUNDLE_ID="com.ghosthand.macos"
MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

services=("$@")
if [ ${#services[@]} -eq 0 ]; then
  services=(Accessibility ScreenCapture)
fi

for service in "${services[@]}"; do
  if tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "reset $service"
  else
    echo "reset $service (nothing to clear, or unsupported)"
  fi
done

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

echo ""
echo "Now enable GhostHand in System Settings > Privacy & Security > Accessibility."
echo "If it is not listed, click '+' and add:"
echo "  $MACOS_DIR/dist/GhostHand.app"
echo ""
echo "No restart is needed — GhostHand re-checks every 3s and installs the hotkey on grant."
