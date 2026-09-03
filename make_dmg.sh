#!/bin/bash
# make_dmg.sh — Package MiniBrowser.app into a distributable universal DMG.
# Usage: bash make_dmg.sh [output-name]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/MiniBrowser.app"
VERSION="1.0"
STAGE="$ROOT/.cache/dmg-stage"
DMG_NAME="${1:-MiniBrowser-${VERSION}.dmg}"

if [ ! -d "$APP" ]; then
  echo "MiniBrowser.app not found. Run ./build.sh first."
  exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

# Add Applications symlink for drag-to-install
ln -s /Applications "$STAGE/Applications"

# Create the DMG with a viewable layout
hdiutil create -volname "MiniBrowser" -srcfolder "$STAGE" \
  -ov -format UDZO "$ROOT/$DMG_NAME" >/dev/null

rm -rf "$STAGE"
echo "Created: $ROOT/$DMG_NAME"
