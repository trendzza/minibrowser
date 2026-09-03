# Homebrew Cask for MiniBrowser
#
# Once the code is signed & notarized and hosted at the URL below, this cask
# can be installed with:
#   brew install --cask minibrowser
#
# Publish the built .dmg somewhere reachable and update 'url' (and sha256).
cask "minibrowser" do
  version "1.0"
  sha256 "REPLACE_WITH_REAL_SHA256"

  url "https://REPLACE.example.com/minibrowser/MiniBrowser-#{version}.dmg"
  name "MiniBrowser"
  desc "Ultra-low RAM, privacy-first native macOS browser"
  homepage "https://REPLACE.example.com"

  auto_updates true

  app "MiniBrowser.app"
end
