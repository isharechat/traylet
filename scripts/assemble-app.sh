#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Assembles Traylet.app from a built SwiftPM product and signs the completed
# bundle. Signing must happen after Info.plist and resources are in place:
# the Swift linker signs the executable ad hoc, and an unsigned resource
# seal makes macOS report the app as damaged.

usage() {
  print -u2 "Usage: scripts/assemble-app.sh --app <path> [--binary-dir <dir>] [--version <version>] [--build <number>] [--sign <identity>|-]"
  exit 2
}

app=""
binary_dir=""
version=$(<VERSION)
build_number=$(<BUILD_NUMBER)
identity=""

while (( $# > 0 )); do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --binary-dir) binary_dir="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --build) build_number="$2"; shift 2 ;;
    --sign) identity="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$app" && "$app" == *.app ]] || usage
if [[ -z "$binary_dir" ]]; then
  binary_dir=$(scripts/swift-local.sh build --show-bin-path)
fi

marketing_version="${version%%-beta.*}"
if [[ ( "$version" != <->.<->.<-> && "$version" != <->.<->.<->-beta.<-> ) || "$build_number" != <-> ]]; then
  print -u2 "VERSION or build number is invalid"
  exit 2
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

if [[ -n "$identity" ]]; then
  if [[ "$identity" == "-" ]]; then
    # Ad-hoc signing for locally built apps. Gatekeeper still rejects these,
    # but the resource seal is valid so the app launches without being
    # reported as damaged.
    codesign --force --deep --sign - --timestamp=none "$app"
  else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
  fi
fi
codesign --verify --deep --strict --verbose=2 "$app"
print -r -- "Assembled: $app"
