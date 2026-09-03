# MiniBrowser

**The web browser for people who are tired of slow, RAM-hungry browsers — built by developers, for developers.**

> "Why is Chrome eating 8 GB of RAM and my MacBook Air sounding like a jet engine?"
> MiniBrowser is the answer. A natively compiled macOS browser that stays fast
> and feather-light even with dozens of tabs open — and its source is open for
> anyone to read, improve, and contribute to.

[Built by **Trendzza**](LICENSE) · Free forever · Non-commercial · Open source

---

## For people who just want it to be fast

If you're here because your browser is slow, this is what MiniBrowser does about it — out of the box:

- **Ultra-low RAM footprint** — tab hibernation, background-tab freezing, live RAM HUD, and cache eviction keep memory in check where Chrome/Brave/Edge balloon.
- **Warmed-up WebKit** — the first site you open after launching isn't a cold start; the browser pre-spawns its rendering/network processes before you even type a URL.
- **No focus-loss cache nuking** — returning to a page doesn't force a re-download of every script and image.
- **Network-layer ad/tracker blocking** — content is blocked at the network layer (WebKit Content Rule Lists), so pages load *with less* junk instead of downloading it all and hiding it.
- **Low Memory Mode** — suppresses silent autoplaying media previews that quietly burn RAM on sites like YouTube.
- **Session restore** — pick up exactly where you left off.

Fast to build, fast to load, fast to switch tabs.

## For developers

MiniBrowser is a **single-file Swift WebKit browser** — one source file, no UI framework, no build system magic. It's an unusually approachable macOS codebase to read, extend, and learn from.

- **100% native** — Swift + WebKit + AppKit. No Electron, no Chromium fork, no JavaScript shell.
- **One-file core** — `Browser/main.swift` (~4,600 lines) holds the entire browser: UI, tabs, networking, memory tooling. Press `⌘⇧I` for Web Inspector.
- **Low-level memory tooling** — process-tree RSS accounting, Live RAM HUD, `proc_listallpids`-based WebKit process tracking, memory-pressure handling.
- **Universal binary** — compiles for `arm64` (every M-series MacBook) *and* `x86_64`, with a **macOS 11.0** floor.
- **WebKit Content Rule Lists** — the ad/tracker blocker is a data-driven rule set you can tune.
- **WebExtensions-style extension points** — user scripts, message handlers, and a command palette (`⌘K`).

### Developer features built in

- **Web Inspector** (external inspector via `developerExtrasEnabled`)
- **User-Agent switching** (Chrome, Safari, Firefox, Android, Googlebot)
- **Localhost dev-server auto-discovery** (3000, 5173, 8080, … — jumps to your running dev server)
- **JSON formatter** for API responses
- **A/B performance probe** (`Browser/probe.swift`) — Turbo on/off page-load comparison
- **RAM tooling** — purge & freeze tabs, inspect live process tree

---

## Features

- Privacy-first: network-layer ad/tracker blocker, aggressive shields, hardened runtime, ATS locked down (localhost-only HTTP exceptions)
- Safe Browsing: offline phishing/typosquat/impersonation blocking with a warning page + override
- Session restore, tab hibernation, per-tab mute/audio indicators
- Reader mode (scoring-based extraction), Picture-in-Picture video
- Find in page, page zoom, command palette (`⌘K`)
- Bookmarks bar + 1-click import from Chrome/Brave
- History, recent downloads, per-site cookie/site-data panel
- Auto-fill — local-only form profile (never leaves your Mac)
- Page translation (Google Translate)

---

## Build

Requires Xcode command-line tools (Swift 5.7+ / Xcode 14+).

```bash
./build.sh          # produces MiniBrowser.app (ad-hoc signed, local dev)
./make_dmg.sh       # produces a distributable MiniBrowser-1.0.dmg
```

Universal by default — one build runs on every M-series MacBook *and* Intel Mac:

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

---

## Project layout

```
Browser/main.swift        # the entire browser (UI, tabs, networking, memory tooling)
Browser/probe.swift       # A/B perf probe (Turbo on/off)
Browser/renderIcon.swift  # app icon renderer
build.sh                  # compile + codesign + package app bundle
make_dmg.sh               # build distributable DMG
minibrowser.rb            # Homebrew cask template
notarize.sh               # Developer ID signing + Apple notarization + stapling
```

---

## Contributing

Contributions are **welcome and encouraged** — bug fixes, performance
optimizations, translations, documentation, features. This project stays free
*because* the community keeps improving it.

How to contribute:

1. Fork the repo (`https://github.com/trendzza/minibrowser`).
2. Create a branch for your change.
3. Build and test locally (`bash build.sh`).
4. Open a pull request describing what you changed and why.

By submitting a contribution you agree it's released under the
[MiniBrowser License](LICENSE).

Before big changes, prefer opening an issue to discuss the direction — the
core is a single file, so a little coordination goes a long way.

---

## Distribution & notarization (for Gatekeeper-clean installs)

Ad-hoc builds run on your Mac but show Gatekeeper's "unidentified developer"
warning on other Macs. Removing it requires Apple notarization (a paid
Apple Developer account, $99/yr). When you have one:

```bash
bash build.sh SIGN_MODE=devid SIGN_IDENTITY="Developer ID Application: Trendzza (TEAMID)"

# with an App Store Connect API key:
API_KEY_PATH=~/path/AuthKey.p8 API_KEY_ID=XXXXXXXXXX API_ISSUER=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX \
  bash notarize.sh

# or with Apple ID + app-specific password:
AC_USERNAME=you@example.com AC_PASSWORD=xxxx-xxxx-xxxx-xxxx TEAM_ID=XXXXXXXXXX \
  bash notarize.sh
```

`notarize.sh` signs the DMG, submits it to Apple, and staples the ticket; when
done `spctl -a -vv <dmg>` reports **accepted** and installs are quiet.

---

## License

MiniBrowser is **free software**. **You may not sell it.** You are free to use
it, modify it, and contribute to it, and improvements stay free forever.

See the full [MiniBrowser License](LICENSE) for the complete terms. Highlights:

- **No commercial sale** — you can't sell MiniBrowser or bundle it into a paid product.
- **Contributions welcome** — patches are encouraged and merged into the shared free project.
- **Free forever** — nobody can relicense it to a proprietary/thirsty license.
- **Attribution to Trendzza** retained on redistribution.

© 2026 Trendzza. All rights reserved under the [MiniBrowser License](LICENSE).
