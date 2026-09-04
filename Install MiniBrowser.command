#!/bin/bash
# "Install MiniBrowser.command" — double-click me to install MiniBrowser.
#
# How to use (no coding, no Terminal typing):
#   1. Double-click this file in the MiniBrowser disk image.
#   2. Click "Open" if macOS asks to confirm this script itself.
#   3. It copies MiniBrowser to Applications and opens it.
#   4. If macOS then shows "Apple could not verify MiniBrowser…" (the standard
#      warning for free, un-notarized apps), right-click MiniBrowser in
#      /Applications -> Open -> Open. macOS remembers your choice for good.
#
# Note: this script clears the quarantine flag (which helps) but cannot fully
# remove Apple's unverified-developer warning on a fresh Mac. That is expected
# for any free app without a paid Apple Developer ID. Get past it once.
#
# MiniBrowser (c) 2026 Trendzza. All rights reserved.
# Free forever · Non-commercial · Open source — see LICENSE.

cd "$(dirname "$0")"

echo "======================================================"
echo "           MiniBrowser Installer"
echo "   No coding needed — just follow the prompts."
echo "======================================================"
echo ""

# Locate the app — here (in the DMG) or already in /Applications.
if [ -d "MiniBrowser.app" ]; then
  SRC="$(pwd)/MiniBrowser.app"
  DEST="/Applications/MiniBrowser.app"
elif [ -d "/Applications/MiniBrowser.app" ]; then
  SRC=""
  DEST="/Applications/MiniBrowser.app"
else
  osascript -e 'display alert "MiniBrowser.app not found" message "Please run this installer from inside the MiniBrowser disk image (MiniBrowser dmg), or drag MiniBrowser.app into /Applications first."' 2>/dev/null || {
    echo "error: MiniBrowser.app not found here or in /Applications" >&2
    echo "Please re-open the MiniBrowser DMG and run this file from there." >&2
  }
  echo ""
  read -n1 -s -r -p "Press any key to close..."
  exit 1
fi

# 1. Copy to /Applications if needed.
if [ -n "$SRC" ]; then
  echo ">> Copying MiniBrowser to your Applications folder..."
  if [ -d "$DEST" ]; then rm -rf "$DEST"; fi
  cp -R "$SRC" "$DEST"
fi

# 2. Clear the Gatekeeper quarantine flag (reduces the chance of the warning).
echo ">> Clearing the quarantine flag..."
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# 3. Make sure the ad-hoc signature is valid.
echo ">> Verifying the app signature..."
codesign --verify --deep --strict "$DEST" >/dev/null 2>&1 \
  && echo "   signature OK" \
  || { echo "   re-signing (ad-hoc)..."; codesign --force --deep --sign - "$DEST"; }

# 4. Register + open.
echo ">> Opening MiniBrowser..."
open "$DEST"
echo ""
echo "   MiniBrowser is being opened. If macOS shows"
echo "   \"Apple could not verify MiniBrowser is free of malware\", that's the"
echo "   normal caution for a free, un-notarized app - it is safe to open."
echo "   In Finder, RIGHT-CLICK MiniBrowser (in /Applications) -> Open -> Open."
echo "   Then it always opens normally. Drag it to your Dock to keep it handy."
echo ""
read -n1 -s -r -p "Press any key to close this window..."
