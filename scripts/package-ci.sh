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
sign_identity="${TRAYLET_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  # Manual CI artifacts are for contributor inspection only. They carry a valid
  # resource seal but are never trusted by Gatekeeper and are never releases.
  sign_identity="-"
fi
scripts/assemble-app.sh --app "$app" --binary-dir "$binary_dir" --version "$version" --build "$build_number" --sign "$sign_identity"
# The assembled bundle is already signed with the Developer ID identity and
# hardened runtime. Public releases additionally require Apple notarization.
if [[ -n "${TRAYLET_SIGN_IDENTITY:-}" ]]; then
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
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(cd "$output" && shasum -a 256 "${archive:t}" > "${archive:t}.sha256")

if [[ -n "${TRAYLET_SIGN_IDENTITY:-}" ]]; then
  print -r -- "Developer ID signed and notarized CI package: $archive"
else
  print -r -- "Ad-hoc signed CI inspection package (not trusted by Gatekeeper): $archive"
fi
print -r -- "SHA-256: $archive.sha256"
