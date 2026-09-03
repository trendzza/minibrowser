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

Requires Xcode command-line tools (Swift 5.7+ / Xcode 14+), macOS 12+.

```bash
./build.sh          # produces MiniBrowser.app
./make_dmg.sh       # produces a distributable MiniBrowser-1.0.dmg
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
