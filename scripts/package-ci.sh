#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

version=$(<VERSION)
marketing_version="${version%%-beta.*}"
build_number="${TRAYLET_BUILD_NUMBER:-$(<BUILD_NUMBER)}"
if [[ ( "$version" != <->.<->.<-> && "$version" != <->.<->.<->-beta.<-> ) || "$build_number" != <-> ]]; then
  print -u2 "VERSION or build number is invalid"
  exit 2
fi

artifact_root="${TRAYLET_CI_OUTPUT_DIR:-$PWD/build/ci-artifacts}"
if [[ "$artifact_root" != "$PWD/build/"* ]]; then
  print -u2 "CI output must be inside the project's build directory"
  exit 2
fi
output="$artifact_root/Traylet-macos-arm64-v${version}-build${build_number}"
app="$output/Traylet.app"
archive="$output/Traylet-macos-arm64-v${version}-build${build_number}.zip"
if [[ -e "$output" ]]; then
  print -u2 "Output already exists: $output"
  exit 1
fi

mkdir -p "$output"
swift build -c release --product Traylet
binary_dir=$(swift build -c release --show-bin-path)
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
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$output" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")

print -r -- "Unsigned CI package: $archive"
print -r -- "SHA-256: $archive.sha256"
