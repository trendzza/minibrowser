# Contributing to MiniBrowser

Thanks for contributing! MiniBrowser stays free and fast because of people
like you. By contributing you agree to release your work under the
[MiniBrowser License](LICENSE): the project is **non-commercial** and **free
forever**.

## What we love

- Performance fixes (it's a browser — speed is the whole point)
- Memory-usage improvements
- Bug fixes and crash reports
- Security hardening
- Documentation and code comments
- Translations and accessibility
- New privacy features

## Getting started

The whole browser lives in **one file**: `Browser/main.swift`. That keeps the
project easy to read, but it means changes can ripple — so please be thoughtful.

```bash
git clone https://github.com/trendzza/minibrowser.git
cd minibrowser
bash build.sh      # compile + codesign + package MiniBrowser.app
open MiniBrowser.app
```

Build a universal binary by default (arm64 + x86_64, min macOS 11.0).

## Before you submit

1. **Open an issue first** for anything non-trivial so we can agree on the
   approach before you write a lot of code.
2. Build cleanly: `bash build.sh` with **zero errors and zero warnings**.
3. Smoke-test your change: launch the app, load a page, switch tabs, cycle the
   app (quit + reopen, verify session restore).
4. Keep the diff focused — one logical change per pull request.

## Pull request checklist

- [ ] Forked and branched
- [ ] Builds with no errors/warnings
- [ ] Tested the happy path (launch → navigate → tabs → quit)
- [ ] Optional, appreciated: added/updated comments or docs

## Style

- Match the existing Swift style (this is a single-file codebase; keep it
  consistent rather than "pretty").
- Avoid pulling in new dependencies — MiniBrowser is deliberately dependency-free.
- Prefer small, well-named changes over big refactors.

## Code of conduct

Be kind and constructive. Disagreement is fine; disrespect is not. MiniBrowser
is a community project — treat contributors the way you'd want to be treated.

© 2026 Trendzza. All rights reserved under the [MiniBrowser License](LICENSE).
