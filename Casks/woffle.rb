# Homebrew Cask for Woffle.
#
# This lives here for convenience — to actually publish it, copy this file into a tap
# repo (e.g. github.com/treyhardin/homebrew-tap) under Casks/, so users can:
#
#   brew install --cask --no-quarantine treyhardin/tap/woffle
#
# On each release, bump `version` and `sha256` to match the uploaded .dmg
# (`shasum -a 256 Woffle-<version>.dmg`). Not yet updated for the first Woffle release.
cask "woffle" do
  version "1.5.0"
  sha256 :no_check

  url "https://github.com/treyhardin/woffle/releases/download/v#{version}/Woffle-#{version}.dmg"
  name "Woffle"
  desc "Font manager for macOS — organize, preview, activate, convert, and serve fonts to AI tools"
  homepage "https://woffle.io"

  app "Woffle.app"

  zap trash: [
    "~/Library/Application Support/Woffle",
    "~/Library/Preferences/co.trumancreative.Woffle.plist",
    "~/Library/Caches/co.trumancreative.Woffle",
  ]
end
