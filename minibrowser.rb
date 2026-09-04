# Homebrew Cask for MiniBrowser
#
# MiniBrowser — the browser for people tired of slow, RAM-hungry browsers.
# (c) 2026 Trendzza. All rights reserved.
# Free forever · Non-commercial · Open source — see LICENSE.
#
# Install with one command (no Developer ID / notarization required):
#   brew install --cask minibrowser
#
# Homebrew clears the Gatekeeper quarantine flag automatically, so this is the
# smoothest install path for the ad-hoc-signed build.

cask "minibrowser" do
  version "1.0"
  sha256 "c1569048c96436b688dec4545edeb5a3fed66368712395044e3168114efc75fd"

  url "https://github.com/trendzza/minibrowser/releases/download/v#{version}/MiniBrowser-#{version}.dmg",
      verified: "github.com/trendzza/minibrowser/releases/download/"

  name "MiniBrowser"
  desc "Ultra-low RAM, privacy-first native macOS browser (c) 2026 Trendzza"
  homepage "https://github.com/trendzza/minibrowser"

  # Ad-hoc signed (no Developer ID). Gatekeeper may still warn once on very
  # strict systems; right-click > Open clears it (see install.sh).

  app "MiniBrowser.app"

  caveats <<~EOS
    MiniBrowser is ad-hoc signed and not notarized (no paid Apple Developer ID).
    On most systems Homebrew already clears quarantine, but if macOS shows a
    "developer cannot be verified" dialog, run:
      xattr -dr com.apple.quarantine "#{appdir}/MiniBrowser.app"
    or right-click the app > Open > Open.

    Contribution and source: https://github.com/trendzza/minibrowser
  EOS
end
