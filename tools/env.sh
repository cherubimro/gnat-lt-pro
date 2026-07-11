# Source this to put the GNAT 14.2.0 + gprbuild + gnatprove toolchain on PATH.
#   . tools/env.sh
# Discovered on this host at 2026-07-11; adjust if the toolchain moves.
export GNAT_ROOT="/home/bu/Downloads/gnat-x86_64-linux-14.2.0-1"
export GPRBUILD_ROOT="/home/bu/Downloads/opt/gprbuild"
export GNATPROVE_ROOT="/home/bu/Downloads/opt/gnatprove"
export PATH="$GNAT_ROOT/bin:$GPRBUILD_ROOT/bin:$GNATPROVE_ROOT/bin:$PATH"
