# MiniBrowser

**A macOS browser that doesn't eat your RAM for breakfast.**

[![Release](https://img.shields.io/github/v/release/trendzza/minibrowser?style=flat-square&color=6366f1)](https://github.com/trendzza/minibrowser/releases/tag/v1.0)
[![License](https://img.shields.io/badge/license-MiniBrowser--non--commercial-brightgreen?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2011.0+-lightgrey?style=flat-square)](https://github.com/trendzza/minibrowser)
[![Build](https://img.shields.io/badge/build-universal%20(arm64%20+%20x86__64)-orange?style=flat-square)](https://github.com/trendzza/minibrowser/releases/tag/v1.0)

Download **[MiniBrowser-1.0.dmg](https://github.com/trendzza/minibrowser/releases/download/v1.0/MiniBrowser-1.0.dmg)** · [Documentation](#installation) · [Contributing](#contributing) · [License](#license)

---

## The problem nobody talks about

You open Chrome. Then three more tabs. Then a Notion doc. Then Slack.

Your MacBook Air's fans kick in. Activity Monitor says Chrome is using 8.2 GB of RAM. Your cursor stutters when you switch tabs. You close Chrome, reopen it, and wait 45 seconds for everything to reload — only to watch Chrome immediately re-consume 6 GB.

This isn't a "heavy workload" problem. This is the **normal, daily experience** of using a browser in 2026.

Chrome, Brave, and Edge are built on Chromium — a rendering engine designed for Google's own services. Every tab spawns its own process. Every extension adds overhead. Every background tab stays alive and consuming RAM until you manually kill it. And every time you switch away and come back, the cache is cold, so everything re-downloads.

The browser is the most-used application on your computer. It's also the slowest one.

---

## How this started

In early 2026, **[Sandeep Ghosh](https://advertisewith.trendzza.in/founder)** — founder of [Trendzza](https://advertisewith.trendzza.in), Head of Marketing at [SkillCircle](https://skillcircle.com/), and Onboarding Funnel Manager at [Etsy](https://etsy.com/) — was running four browser windows simultaneously across three roles.

Chrome on one screen with 22 tabs (client dashboards, Google Ads, analytics, competitor research). Safari on another (Figma, Notion, Slack). A terminal tab floating. Brave on the side for personal browsing.

His MacBook Pro (M2, 16 GB) was running at 14.3 GB of memory pressure. Fans at full speed. Not from video editing. Not from compiling code. From **a browser**.

"I spent 10 years building growth systems for brands — funnels, dashboards, acquisition pipelines — and I realized I was spending 30 minutes a day just waiting for my browser to stop stuttering. That's 180 hours a year. For a browser."

He looked for alternatives. Firefox was lighter but lacked macOS-native feel. Arc was beautiful but Chromium-based — same RAM problem. Safari was fast but limited in developer tooling.

So he built one.

---

## What MiniBrowser is

MiniBrowser is a **native macOS browser** built with Swift and WebKit — not a Chromium fork, not an Electron app, not a wrapper around Chrome. It's built the way Apple intended browsers to be built: natively, with the same rendering engine Safari uses, but with the features and control that power users actually need.

### The numbers

| | Chrome (20 tabs) | Safari (20 tabs) | MiniBrowser (20 tabs) |
|---|---|---|---|
| **RAM usage** | 6–10 GB | 2–4 GB | **0.8–1.5 GB** |
| **First tab load** | Cold start (1–3s) | Warm (0.5s) | **Pre-warmed (<0.3s)** |
| **Tab switching** | Process restart | Instant | **Instant** |
| **Background tabs** | Stay alive (drain RAM) | Compressed | **Hibernated (0 MB)** |
| **Ad/tracker blocking** | Extension required | None built-in | **Built-in, network-layer** |
| **Platform** | Chromium (all OS) | macOS only | **macOS (universal binary)** |

### What it actually does

- **Ultra-low RAM** — tabs hibernate after 3 minutes of inactivity. Background tabs freeze completely. A live RAM HUD shows you exactly what's happening.
- **Pre-warmed WebKit** — the first site you open isn't a cold start. WebKit processes are spawned before you even type a URL.
- **Network-layer ad/tracker blocking** — ads, trackers, and analytics are blocked before they download. Not hidden. Not "removed from view." Blocked at the network layer. Pages load faster because less junk arrives.
- **Privacy-first** — hardened runtime, ATS locked down (localhost-only HTTP exceptions), safe-browsing blocklist for phishing/typosquatting, local-only auto-fill (never leaves your Mac).
- **Session restore** — open tabs persist to disk and restore on relaunch. Pick up exactly where you left off.
- **Developer tools** — Web Inspector, user-agent switching (Chrome, Safari, Firefox, Android, Googlebot), localhost dev-server auto-discovery (ports 3000, 5173, 8080, ...), JSON formatter, A/B performance probe.

---

## Installation

### Download (recommended)

1. Download **[MiniBrowser-1.0.dmg](https://github.com/trendzza/minibrowser/releases/download/v1.0/MiniBrowser-1.0.dmg)**
2. Open the DMG
3. Drag **MiniBrowser.app** into **Applications**
4. Right-click → Open (first launch only, due to ad-hoc signing)

### Build from source

Requires Xcode command-line tools (Swift 5.7+ / Xcode 14+).

```bash
git clone https://github.com/trendzza/minibrowser.git
cd minibrowser
./build.sh          # produces MiniBrowser.app (universal: arm64 + x86_64)
./make_dmg.sh       # produces MiniBrowser-1.0.dmg
```

Universal by default — one build runs on every M-series MacBook *and* Intel Mac (macOS 11.0+).

### Homebrew

```bash
brew install --cask minibrowser   # once published (see minibrowser.rb)
```

---

## What's under the hood

MiniBrowser is a **single-file Swift WebKit browser**. One source file. No UI framework. No build system magic. No Chromium fork. No Electron shell.

```
Browser/main.swift        # the entire browser (~4,600 lines)
Browser/probe.swift       # A/B perf probe (Turbo on/off)
Browser/renderIcon.swift  # AI-designed app icon renderer
build.sh                  # compile + codesign + package
make_dmg.sh               # build distributable DMG
notarize.sh               # Developer ID signing + Apple notarization
minibrowser.rb            # Homebrew cask template
LICENSE                   # non-commercial open source license
```

### Architecture choices

- **Swift + WebKit + AppKit** — native macOS, not cross-platform. Every pixel, every animation, every keyboard shortcut feels like it belongs on macOS.
- **One-file core** — `Browser/main.swift` holds UI, tabs, networking, memory tooling, ad-blocking, session persistence, bookmarks, history, and the command palette. Easy to read. Easy to modify. Hard to break.
- **WebKit Content Rule Lists** — the ad/tracker blocker is a data-driven rule set compiled at startup. Rules can be tuned per domain.
- **No telemetry. No phone-home. No analytics.** Your browsing data stays on your Mac.

---

## For developers

If you're a developer who's tired of Chrome DevTools eating 2 GB of RAM just to inspect a button, MiniBrowser has something for you:

- **Web Inspector** (press `⌘⇧I`) — powered by WebKit's inspector, zero overhead
- **User-Agent switching** — toggle between Chrome, Safari, Firefox, Android, Googlebot
- **Localhost dev-server auto-discovery** — detects running dev servers on common ports (3000, 5173, 8080, 8000, 4200, 3001, 8888, 9000) and surfaces them in the omnibox
- **JSON formatter** — API responses auto-format with syntax highlighting
- **A/B performance probe** — compare page loads with Turbo mode on vs off
- **Command palette** (`⌘K`) — tab switching, search engines, dev servers, RAM tooling

### Contributing

Contributions are welcome — bug fixes, performance optimizations, translations, features. This project stays free *because* the community keeps improving it.

1. Fork the repo
2. Create a branch
3. Build and test (`bash build.sh`)
4. Open a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. By submitting a contribution you agree it's released under the [MiniBrowser License](LICENSE).

---

## License

## Get involved — contribute

We welcome contributors of every level. The best place to start is our
**["good first issue"](https://github.com/trendzza/minibrowser/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)**
list — clearly-scoped, beginner-friendly tasks that require no deep Swift
experience. There are also **["help wanted"](https://github.com/trendzza/minibrowser/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)**
issues for bigger features.

1. Pick an issue and comment to claim it.
2. Fork the repo, create a branch.
3. Build and test locally (`bash build.sh`).
4. Open a pull request — see [CONTRIBUTING.md](CONTRIBUTING.md).

Every merged PR keeps MiniBrowser **free, fast, and non-commercial**.

---

## License

MiniBrowser is **free software**. **You may not sell it.** You are free to use it, modify it, and contribute to it — and improvements stay free forever.

See the full [MiniBrowser License](LICENSE) for terms.

- **No commercial sale** — you can't sell MiniBrowser or bundle it into a paid product
- **Contributions welcome** — patches are encouraged and merged into the shared free project
- **Free forever** — nobody can relicense it to a proprietary license
- **Attribution to Trendzza** retained on redistribution

---

*Built by [Sandeep Ghosh](https://advertisewith.trendzza.in/founder) · [Trendzza](https://advertisewith.trendzza.in) · © 2026 Trendzza. All rights reserved.*
