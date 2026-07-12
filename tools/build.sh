#!/usr/bin/env bash
# Build the project (and run the codec test driver by default).
#
#   ./tools/build.sh                  # default: kernel transport, no DPDK
#   WITH_DPDK=yes ./tools/build.sh    # + the DPDK poll-mode backend
#
# The DPDK build needs libdpdk via pkg-config.  DPDK_PREFIX points at a local
# install (the vendored one under ../dpdk/deps by default); on Debian/Ubuntu
# `apt install libdpdk-dev` provides the system libdpdk.pc and DPDK_PREFIX can
# be left unset.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

WITH_DPDK="${WITH_DPDK:-no}"

if [ "$WITH_DPDK" = "yes" ]; then
    DPDK_PREFIX="${DPDK_PREFIX:-$HOME/code/dpdk/deps/dpdk-install}"
    export PKG_CONFIG_PATH="$DPDK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    if ! pkg-config --exists libdpdk; then
        echo "build.sh: libdpdk not found via pkg-config." >&2
        echo "  looked in: $DPDK_PREFIX/lib/pkgconfig" >&2
        echo "  set DPDK_PREFIX=/path/to/dpdk-install, or install libdpdk-dev." >&2
        exit 1
    fi

    #  --static is load-bearing, not cosmetic: it emits --whole-archive, and
    #  without that the PMD constructors are never pulled out of the archives,
    #  nothing self-registers, and the binary starts with zero ports.
    DPDK_CFLAGS="$(pkg-config --cflags libdpdk)"
    DPDK_LIBS="$(pkg-config --static --libs libdpdk)"
    export DPDK_CFLAGS DPDK_LIBS

    echo "build.sh: DPDK backend ON (libdpdk $(pkg-config --modversion libdpdk), $DPDK_PREFIX)"
fi

#  gprbuild tracks Ada sources, NOT the value of an external.  Switching
#  DPDK_PREFIX (say, from the memif-only vendored build to one carrying the NIC
#  PMDs) changes only DPDK_LIBS -- so gprbuild sees nothing to do and happily
#  keeps the old link, leaving you with a binary that silently lacks the very
#  driver you just built.  Stamp the config and force a clean when it moves.
STAMP="obj/.dpdk-config"
WANT="$WITH_DPDK|${DPDK_PREFIX:-}|${DPDK_LIBS:-}"
if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
    [ -e "$STAMP" ] && echo "build.sh: DPDK config changed -> full rebuild"
    gprclean -q -P lt_diode.gpr -XWITH_DPDK="$WITH_DPDK" 2>/dev/null || true
    mkdir -p obj && printf '%s' "$WANT" > "$STAMP"
fi

gprbuild -P lt_diode.gpr -XWITH_DPDK="$WITH_DPDK" "$@"
