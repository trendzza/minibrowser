#!/bin/bash
# install.sh — one-command installer for MiniBrowser (no Developer ID needed)
#
# MiniBrowser is ad-hoc signed (no paid Apple Developer ID / notarization).
# That means a downloaded copy carries a "quarantine" flag that Gatekeeper uses
# to block first launch with: "cannot be opened because the developer cannot be
# verified." This script clears that flag, ad-hoc re-signs the app for good
# measure, registers it with LaunchServices, and launches it.
#
# Usage:
#   bash install.sh                 # installs MiniBrowser.app from this folder
#   bash install.sh /path/to/moved/MiniBrowser.app
#
# (c) 2026 Trendzza. All rights reserved. Licensed under the MiniBrowser license.

set -euo pipefail

if [[ -d "$1" && "$1" == *.app ]]; then
  APP="$1"
elif [[ -d "MiniBrowser.app" ]]; then
  APP="$(pwd)/MiniBrowser.app"
else
  echo "error: could not find MiniBrowser.app" >&2
  echo "usage: bash install.sh [/path/to/MiniBrowser.app]" >&2
  exit 1
fi

APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

echo "==> MiniBrowser installer"
echo "    app: $APP"
[[ -x "$APP/Contents/MacOS/MiniBrowser" ]] || { echo "error: executable not found inside bundle" >&2; exit 1; }

# 1. Clear Gatekeeper quarantine so launch isn't blocked.
if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  echo "==> Clearing quarantine flag..."
  xattr -dr com.apple.quarantine "$APP"
else
  echo "==> No quarantine flag to clear."
fi

# 2. Ensure a valid ad-hoc signature (works even if transfer "broke" signature).
echo "==> Ad-hoc signing (identity: -) ..."
codesign --force --deep --sign - "$APP"

# 3. Register with LaunchServices so Finder/open resolve it correctly.
LSREG="$(xcrun --find lsregister 2>/dev/null || true)"
if [[ -n "$LSREG" && -x "$LSREG" ]]; then
  echo "==> Registering with LaunchServices..."
  "$LSREG" -f "$APP" || true
fi

# 4. Launch.
echo "==> Launching MiniBrowser..."
open "$APP" || { echo "error: 'open' failed; try: open \"$APP\"" >&2; exit 1; }

echo "==> Done. MiniBrowser should now be running."
echo "    (If macOS still shows a Gatekeeper dialog once, right-click > Open,"
echo "     then click Open — it will remember your choice.)"
