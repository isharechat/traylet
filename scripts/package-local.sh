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
# Assemble and sign through the shared script so the local candidate and the
# CI package apply the same resource-seal fix.
identity="Traylet Local Signing"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  sign_argument="$identity"
else
  print -u2 "Required signing identity '$identity' unavailable; candidate not signed or released."
  exit 1
fi
scripts/assemble-app.sh --app "$app" --binary-dir "$binary_dir" --sign "$sign_argument"
print -r -- "Internal candidate: $app"
print -r -- "After verification run scripts/install-local.sh; user entry stays /Applications/Traylet.app"
