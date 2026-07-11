#!/usr/bin/env bash
# Run SPARK proof over the codec core.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."
gnatprove -P lt_diode.gpr -j0 "$@"
