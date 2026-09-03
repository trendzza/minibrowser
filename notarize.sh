#!/bin/bash
# ----------------------------------------------------------------------------
# notarize.sh — Developer ID signing + Apple notarization + stapling
#
# Purpose: make MiniBrowser install cleanly on other Macs WITHOUT the
# Gatekeeper "cannot be opened because the developer cannot be verified"
# warning. That warning is Apple's security gate; the ONLY way past it is
# Apple notarization, which requires a PAID Apple Developer account.
#
# Prerequisites (you must provide these — they cannot be created locally):
#   1. A paid Apple Developer account (https://developer.apple.com)
#   2. A "Developer ID Application" certificate installed in your Keychain,
#      whose common name looks like:  Developer ID Application: Trendzza (TEAMID)
#   3. A notarization credential, EITHER:
#        a) App Store Connect API key (recommended), OR
#        b) your Apple ID + an app-specific password
#
# Usage:
#   bash build.sh SIGN_MODE=devid SIGN_IDENTITY="Developer ID Application: Trendzza (XXXXXXXXXX)"
#   bash notarize.sh         # uses the same env vars
#
# Environment variables:
#   SIGN_IDENTITY   Developer ID cert name (default: "Developer ID Application: Trendzza")
#   AC_USERNAME     Apple ID email (only for AppleID-based notarization)
#   AC_PASSWORD     App-specific password (only for AppleID-based notarization)
#   API_KEY_PATH    path to App Store Connect API .p8 key (recommended, mutually exclusive with AC_*)
#   API_KEY_ID      App Store Connect API key id (the 10-char id)
#   API_ISSUER      App Store Connect API issuer id
# ----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/MiniBrowser.app"
DMG="$ROOT/MiniBrowser-1.0.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Trendzza}"

if [[ ! -d "$APP" ]]; then
  echo "ERROR: $APP not found. Run: bash build.sh SIGN_MODE=devid SIGN_IDENTITY=\"$SIGN_IDENTITY\""
  exit 1
fi

[ -f "$DMG" ] && rm -f "$DMG"
hdiutil create -volname "MiniBrowser" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "=== 1. Sign DMG with Developer ID ==="
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

echo "=== 2. Submit for notarization ==="
if [[ -n "${API_KEY_PATH:-}" ]]; then
  echo "Using App Store Connect API key..."
  xcrun notarytool submit "$DMG" \
    --key "$API_KEY_PATH" \
    --key-id "$API_KEY_ID" \
    --issuer "$API_ISSUER" \
    --wait
elif [[ -n "${AC_USERNAME:-}" && -n "${AC_PASSWORD:-}" ]]; then
  echo "Using Apple ID / app-specific password..."
  xcrun notarytool submit "$DMG" \
    --apple-id "$AC_USERNAME" \
    --password "$AC_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
else
  echo "ERROR: No notarization credential provided."
  echo "Set either API_KEY_PATH/API_KEY_ID/API_ISSUER (App Store Connect API key)"
  echo "or AC_USERNAME/AC_PASSWORD (Apple ID + app-specific password)."
  exit 1
fi

echo "=== 3. Staple ticket so it works offline ==="
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

echo "=== 4. Verify ==="
spctl -a -vv --type open --context context:primary-signature "$DMG"
echo "Notarization complete. $DMG is now Gatekeeper-clean."
