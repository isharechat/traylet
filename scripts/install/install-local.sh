#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h:h}"
exec python3 scripts/install/install-local.py "$@"
