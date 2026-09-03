# MiniBrowser

**Ultra-low RAM · Apple Silicon 60 FPS · Privacy-first native macOS browser**

A privacy-focused, memory-lean macOS browser built natively with Swift, WebKit, and AppKit. Designed for people who run dozens of tabs on a MacBook Air without the RAM bloat of Chrome/Brave/Edge.

## Features

- **Ultra-low memory footprint** — tab hibernation, cache eviction, Low Memory Mode, live RAM HUD
- **Privacy-first** — network-layer ad/tracker blocker (WebKit Content Rule Lists), aggressive shields
- **Safe Browsing** — offline phishing/typosquat/impersonation URL blocking with warning page + override
- **Session restore** — open tabs persist to disk and restore on relaunch
- **Reader mode** — scoring-based article extraction
- **Picture-in-Picture** video
- **Find in page**, page zoom, per-tab mute/audio indicators
- **Command palette** (`⌘K`) — tab switching, dev servers, RAM tooling, search engines
- **Bookmarks** — bookmarks bar + 1-click import from Chrome/Brave
- **History**, recent downloads, per-site cookie/site-data panel
- **Auto-fill** — local-only form profile (never leaves your Mac)
- **Page translation** (Google Translate), JSON formatter
- **Developer tools** — user-agent switching, localhost dev-server auto-discovery, Web Inspector
- **Hardened runtime** signing, ATS locked down (localhost-only HTTP exceptions)

## Build

Requires Xcode command-line tools (Swift 5.7+ / Xcode 14+).

MiniBrowser compiles as a **universal binary (arm64 + x86_64)** with a
**macOS 11.0** deployment target, so one build runs on every M-series
MacBook *and* Intel Mac.

```bash
./build.sh          # produces MiniBrowser.app (ad-hoc signed, local dev)
./make_dmg.sh       # produces a distributable MiniBrowser-1.0.dmg
```

### Universal / architecture options

```bash
./build.sh ARCHS=arm64                # arm64 only (all M-series Macs)
./build.sh ARCHS=universal            # arm64 + x86_64 (all Macs, default)
./build.sh DEPLOY_TARGET=11.0         # oldest supported macOS (default)
```

## Install / Run

```bash
open MiniBrowser.app
# or
./Launch\ MiniBrowser.command
```

## Homebrew

```bash
brew install --cask minibrowser   # once published (see minibrowser.rb)
```

## Distribution & notarization (needed for Gatekeeper-clean installs)

Ad-hoc builds run on your Mac but will show Gatekeeper's
"unidentified developer" warning when copied to other Macs. Removing that
warning **requires Apple notarization**, which needs a **paid Apple Developer
account** ($99/yr). When you have one:

1. Install your **Developer ID Application** certificate in Keychain
   (name like `Developer ID Application: Trendzza (TEAMID)`).
2. Create an **App Store Connect API key** (or use Apple ID app-password).
3. Build with Developer ID and notarize:

```bash
bash build.sh SIGN_MODE=devid SIGN_IDENTITY="Developer ID Application: Trendzza (TEAMID)"

# with an App Store Connect API key:
API_KEY_PATH=~/path/AuthKey.p8 API_KEY_ID=XXXXXXXXXX API_ISSUER=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX \
  bash notarize.sh

# or with Apple ID + app-specific password:
AC_USERNAME=you@example.com AC_PASSWORD=xxxx-xxxx-xxxx-xxxx TEAM_ID=XXXXXXXXXX \
  bash notarize.sh
```

`notarize.sh` signs the DMG, submits it to Apple, and **staples** the ticket.
When it completes, `spctl -a -vv <dmg>` reports **accepted** and the app
installs quietly, same as Chrome/Brave/Firefox.

### Make the app look trusted between now and then
- Sign the `.app` (done) and ship the **DMG**, not a raw folder, so macOS
  doesn't strip attributes. Right-click → Open is the one-click override
  for the developer-not-verified dialog.

## Project layout

```
Browser/main.swift        # the entire browser (UI, tabs, networking, memory tooling)
Browser/probe.swift       # A/B perf probe (Turbo on/off)
Browser/renderIcon.swift  # app icon renderer
build.sh                  # compile + codesign + package app bundle
make_dmg.sh               # build distributable DMG
minibrowser.rb            # Homebrew cask template
```

## License

Copyright © 2026 Trendzza. All rights reserved.
