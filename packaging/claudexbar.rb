# Homebrew cask for ClaudexBar (l0bz1k patched fork).
#
# This is the source of truth for the cask. To publish it, copy it into a
# Homebrew tap repository (e.g. github.com/l0bz1k/homebrew-tap) at
# Casks/claudexbar.rb, then users can install with:
#
#   brew install --cask l0bz1k/tap/claudexbar
#
# Update `version` and `sha256` for each release. The release publishes
# ClaudexBar.zip and ClaudexBar.zip.sha256 as assets, so the sha256 is the
# value in ClaudexBar.zip.sha256.

cask "claudexbar" do
  version "0.2.0"
  sha256 "REPLACE_WITH_RELEASE_SHA256"

  url "https://github.com/l0bz1k/claudexbar/releases/download/v#{version}/ClaudexBar.zip"
  name "ClaudexBar"
  desc "Menu-bar app showing Codex and Claude Code usage limits (patched fork)"
  homepage "https://github.com/l0bz1k/claudexbar"

  depends_on macos: :ventura

  app "ClaudexBar.app"

  zap trash: [
    "~/Library/Logs/ClaudexBar",
    "~/Library/LaunchAgents/com.ipang.claudexbar.plist",
  ]
end
