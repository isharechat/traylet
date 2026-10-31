#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != "--open" ]]; then
  print -u2 "Usage: scripts/deliver-local.sh [--open]"; exit 2
fi
export TRAYLET_CANDIDATE_DIR="${TRAYLET_CANDIDATE_DIR:-$PWD/build/candidate-v2}"
scripts/verify-local.sh
if [[ "${1:-}" == "--open" ]]; then
  exec scripts/install-local.sh --manifest "$TRAYLET_CANDIDATE_DIR/build-manifest.json" --open
fi
exec scripts/install-local.sh --manifest "$TRAYLET_CANDIDATE_DIR/build-manifest.json"
