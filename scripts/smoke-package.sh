#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Runtime smoke test for a packaged Traylet archive. Signature checks alone
# cannot tell whether the assembled bundle actually starts, so this script
# unpacks the archive, verifies the resource seal and launches the packaged
# binary in evidence mode.

usage() {
  print -u2 "Usage: scripts/smoke-package.sh <archive.zip>"
  exit 2
}

[[ $# -eq 1 && "$1" == *.zip ]] || usage
archive="$(cd "${1:A:h}" && pwd)/${1:t}"
[[ -f "$archive" ]] || usage

workdir="$(mktemp -d "${TMPDIR:-/tmp}/traylet-smoke.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

ditto -x -k "$archive" "$workdir"
app="$(find "$workdir" -maxdepth 2 -name 'Traylet.app' -print -quit)"
[[ -n "$app" ]] || { print -u2 "Traylet.app not found in archive"; exit 1; }

codesign --verify --deep --strict --verbose=2 "$app"

metadata_version=$(/usr/libexec/PlistBuddy -c 'Print :TrayletReleaseVersion' "$app/Contents/Info.plist")
expected_version=$(<VERSION)
if [[ "$metadata_version" != "$expected_version" ]]; then
  print -u2 "Packaged version $metadata_version does not match VERSION $expected_version"
  exit 1
fi

evidence_dir="$workdir/evidence"
mkdir -p "$evidence_dir"
"$app/Contents/MacOS/Traylet" --v2-native-evidence "$evidence_dir"
if [[ ! -f "$evidence_dir/evidence-report.json" ]]; then
  print -u2 "Packaged binary did not produce an evidence report"
  exit 1
fi

print -r -- "Smoke test passed: $app"
