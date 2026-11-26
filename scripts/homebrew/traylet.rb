cask "traylet" do
  version "0.1.0-beta.1"
  sha256 "<REPLACE_WITH_ZIP_SHA256>"

  url "https://github.com/isharechat/traylet/releases/download/v#{version}-preview/Traylet-macos-arm64-v#{version}-build1.zip"
  name "Traylet"
  desc "Lightweight on-device macOS menu bar utility for capture, translation, and clipboard history"
  homepage "https://github.com/isharechat/traylet"

  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Traylet.app"

  caveats <<~EOS
    Traylet open-source preview builds are ad-hoc signed and not notarized by Apple.
    If macOS Gatekeeper blocks the first launch, Control-click Traylet.app and choose Open,
    or run:
      xattr -cr /Applications/Traylet.app
  EOS
end
