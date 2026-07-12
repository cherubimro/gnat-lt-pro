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

    echo "build.sh: DPDK backend ON (libdpdk $(pkg-config --modversion libdpdk))"
fi

gprbuild -P lt_diode.gpr -XWITH_DPDK="$WITH_DPDK" "$@"
