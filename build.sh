#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Browser/main.swift"
APP="$ROOT/MiniBrowser.app"
BIN="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$BIN" "$RES"

mkdir -p "$ROOT/.cache"
xcrun swiftc -module-cache-path "$ROOT/.cache" -O -whole-module-optimization \
  -framework AppKit -framework WebKit \
  "$SRC" -o "$BIN/MiniBrowser"

ICON_RENDER="$ROOT/.cache/icon_render"
rm -rf "$ICON_RENDER"
mkdir -p "$ICON_RENDER"
xcrun swiftc -module-cache-path "$ROOT/.cache" -O -framework AppKit \
  "$ROOT/Browser/renderIcon.swift" -o "$ICON_RENDER/render"
"$ICON_RENDER/render" "$ICON_RENDER/base.png"

ICONSET="$ICON_RENDER/AppIcon.iconset"
mkdir -p "$ICONSET"
make_icon() { sips -z "$1" "$1" "$ICON_RENDER/base.png" --out "$ICONSET/$2" >/dev/null 2>&1; }
make_icon 16  icon_16x16.png
make_icon 32  icon_16x16@2x.png
make_icon 32  icon_32x32.png
make_icon 64  icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
rm -rf "$ICON_RENDER"
mkdir -p "$APP/Contents/Resources/en.lproj"
if command -v genstrings >/dev/null 2>&1; then
  genstrings -o "$APP/Contents/Resources/en.lproj" "$SRC" 2>/dev/null || true
fi

if [ ! -f "$RES/AppIcon.icns" ]; then echo "ICON BUILD FAILED"; exit 1; fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>MiniBrowser</string>
	<key>CFBundleIdentifier</key>
	<string>com.trendzza.minibrowser</string>
	<key>CFBundleName</key>
	<string>MiniBrowser</string>
	<key>CFBundleDisplayName</key>
	<string>MiniBrowser</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Trendzza. All rights reserved.</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleAllowMixedLocalizations</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<false/>
		<key>NSExceptionDomains</key>
		<dict>
			<key>localhost</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
				<key>NSIncludesSubdomains</key>
				<true/>
			</dict>
			<key>127.0.0.1</key>
			<dict>
				<key>NSExceptionAllowsInsecureHTTPLoads</key>
				<true/>
			</dict>
		</dict>
	</dict>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Trendzza. All rights reserved.</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSDocumentsFolderUsageDescription</key>
	<string>Downloads are saved to your Downloads folder.</string>
	<key>NSDownloadsFolderUsageDescription</key>
	<string>Downloads are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
cat > "$ROOT/.cache/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
	<true/>
	<key>com.apple.security.cs.disable-library-validation</key>
	<true/>
</dict>
</plist>
PLIST
codesign --force --deep --options runtime --entitlements "$ROOT/.cache/entitlements.plist" --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built: $APP"