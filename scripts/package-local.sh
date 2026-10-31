#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version=$(<VERSION)
marketing_version="${version%%-beta.*}"
build_number=$(<BUILD_NUMBER)
if [[ ( "$version" != <->.<->.<-> && "$version" != <->.<->.<->-beta.<-> ) || "$build_number" != <-> ]]; then
  print -u2 "VERSION or BUILD_NUMBER is invalid"; exit 2
fi
scripts/swift-local.sh build
binary_dir=$(scripts/swift-local.sh build --show-bin-path)
# An explicit candidate path avoids replacing a bundle the user is currently running.
app="${TRAYLET_APP_OUTPUT:-$PWD/build/candidate/Traylet.app}"
if [[ "$app" != "$PWD/build/"* || "$app" != *.app ]]; then
  print -u2 "App output must be an .app inside the project's build directory"; exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Traylet" "$app/Contents/MacOS/Traylet"
cp assets/brand/Traylet.icns "$app/Contents/Resources/Traylet.icns"
cp -R "$binary_dir/Traylet_TrayletApp.bundle" "$app/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Traylet</string>
<key>CFBundleIdentifier</key><string>local.traylet.app</string>
<key>CFBundleName</key><string>Traylet</string>
<key>CFBundleDisplayName</key><string>Traylet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Traylet.icns</string>
<key>CFBundleShortVersionString</key><string>${marketing_version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>TrayletReleaseVersion</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>在你主动框选时捕获屏幕内容，用于截图和文字识别。</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
# Keep the existing local identity. Missing/unavailable identity is a stop condition,
# never permission to silently switch to ad-hoc or alter system trust.
identity="Traylet Local Signing"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --sign "$identity" "$app"
else
  print -u2 "Required signing identity '$identity' unavailable; candidate not signed or released."
  exit 1
fi
codesign --verify --strict "$app"
print -r -- "Internal candidate: $app"
print -r -- "After verification run scripts/install-local.sh; user entry stays /Applications/Traylet.app"
