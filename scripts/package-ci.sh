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
# The Swift linker signs the executable ad hoc. Re-sign the completed app bundle
# after its Info.plist and resources are in place so its resource seal is valid.
if [[ -n "${TRAYLET_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$TRAYLET_SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  if [[ -z "${TRAYLET_NOTARY_KEY_PATH:-}" || -z "${TRAYLET_NOTARY_KEY_ID:-}" || -z "${TRAYLET_NOTARY_ISSUER_ID:-}" ]]; then
    print -u2 "Notarization credentials are required for Developer ID release packages"
    exit 2
  fi
  submission_archive="$output/.notarization-submission.zip"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$submission_archive"
  xcrun notarytool submit "$submission_archive" \
    --key "$TRAYLET_NOTARY_KEY_PATH" \
    --key-id "$TRAYLET_NOTARY_KEY_ID" \
    --issuer "$TRAYLET_NOTARY_ISSUER_ID" \
    --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  spctl --assess --type execute --verbose=2 "$app"
  python3 -c 'from pathlib import Path; import sys; Path(sys.argv[1]).unlink()' "$submission_archive"
else
  # Manual CI artifacts are useful for contributor inspection only. They are
  # structurally signed but remain untrusted by Gatekeeper and are never releases.
  codesign --force --deep --sign - --timestamp=none "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$output" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")

if [[ -n "${TRAYLET_SIGN_IDENTITY:-}" ]]; then
  print -r -- "Developer ID signed and notarized CI package: $archive"
else
  print -r -- "Ad-hoc signed CI inspection package (not trusted by Gatekeeper): $archive"
fi
print -r -- "SHA-256: $archive.sha256"
