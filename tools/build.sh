#!/usr/bin/env bash
# Build the project (and run the codec test driver by default).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."
gprbuild -P lt_diode.gpr "$@"
