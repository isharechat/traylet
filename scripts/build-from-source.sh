#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Builds a runnable Traylet.app directly from source for contributors and
# users who cannot obtain a Developer ID certificate. The app is ad-hoc
# signed: the resource seal is valid, so the app launches normally when it is
# built locally. Gatekeeper only rejects apps that arrive over the network
# with an untrusted signature.

app="${TRAYLET_APP_OUTPUT:-$PWD/build/source/Traylet.app}"
if [[ "$app" != "$PWD/build/"* || "$app" != *.app ]]; then
  print -u2 "App output must be an .app inside the project's build directory"
  exit 1
fi

scripts/swift-local.sh build
binary_dir=$(scripts/swift-local.sh build --show-bin-path)
scripts/assemble-app.sh --app "$app" --binary-dir "$binary_dir" --sign -

print -r -- "Source build ready: $app"
print -r -- "Move it to /Applications to install, or run the binary directly."
