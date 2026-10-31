#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/cache/clang"
mkdir -p "$CLANG_MODULE_CACHE_PATH" .build/cache/swiftpm .build/config .build/security
# The outer execution sandbox remains active. Disable only SwiftPM's nested
# manifest sandbox, which sandbox-exec cannot create in this execution host.
sdk_path="${TRAYLET_SDK_PATH:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
arguments=("$@")
if [[ "${1:-}" == "package" && "${2:-}" == "describe" ]]; then
  shift 2
  exec swift package --disable-sandbox --cache-path "$PWD/.build/cache/swiftpm" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --manifest-cache local describe "$@"
fi
if [[ "${1:-}" == "test" ]]; then
  arguments+=(--disable-xctest -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib)
fi
exec swift "${arguments[@]}" --sdk "$sdk_path" --disable-sandbox --cache-path "$PWD/.build/cache/swiftpm" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" --manifest-cache local
