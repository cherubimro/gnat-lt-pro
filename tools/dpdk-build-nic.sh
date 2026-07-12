#!/usr/bin/env bash
# Build a DPDK that can actually do KERNEL BYPASS on a real NIC.
#
# WHY THIS EXISTS
# ---------------
# The DPDK vendored next door in ../dpdk/deps was built with virtual drivers
# only (vdev: memif, af_packet, tap, null, ring).  Those are enough for the
# memif code-path test, and af_packet, but they contain NO PCI NIC driver -- so
# vfio-pci kernel bypass is simply impossible with it.  You would bind the card,
# start the daemon, and get "no ethdev port available".
#
# This script rebuilds DPDK 22.11 LTS from the same vendored source, with the
# PCI bus and the Intel PMDs enabled, into a SEPARATE prefix so the original
# install stays intact:
#
#     ../dpdk/deps/dpdk-install       <- vdev only     (unchanged)
#     ../dpdk/deps/dpdk-install-nic   <- + PCI + Intel (built here)
#
# Drivers enabled:
#     ixgbe   82599 / X520 / X540 / X550          Intel 10G (the common case)
#     i40e    X710 / XL710 / X722                 Intel 10/40G
#     ice     E810                                Intel 25/100G (if it builds)
#     e1000   82540..82576 / igb                  Intel 1G
#     + the vdev drivers, so tools/dpdk-test.sh (memif) still works.
#
# USAGE
#     ./tools/dpdk-build-nic.sh                 # build DPDK with NIC PMDs
#     DPDK_PREFIX=$PWD/../dpdk/deps/dpdk-install-nic \
#         WITH_DPDK=yes ./tools/build.sh        # build us against it
#
# Then see KERNEL-BYPASS.TXT for the IOMMU / hugepages / vfio-pci steps.
#
# NOTE: on Debian/Ubuntu you do not need any of this -- `apt install libdpdk-dev`
# ships all these PMDs.  Just leave DPDK_PREFIX unset so pkg-config finds the
# system libdpdk.pc.  This script is for boxes with no DPDK packages (SUSE).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC="${DPDK_SRC:-$here/../../dpdk/deps/dpdk-stable-22.11.9}"
PREFIX="${DPDK_NIC_PREFIX:-$here/../../dpdk/deps/dpdk-install-nic}"

[ -d "$SRC" ] || { echo "no DPDK source at $SRC (set DPDK_SRC=...)" >&2; exit 1; }

# meson's helper scripts need python >= 3.7; the vendored tree keeps a shim.
export PATH="$SRC/../bin:$HOME/.local/bin:$PATH"

# DPDK 22.11 builds fine with the system GCC, but this box's is 7.5 and we
# already have a modern one from the GNAT bundle -- and using the SAME compiler
# that links our binary avoids any ABI surprises across the C boundary.
if [ -z "${CC:-}" ] && [ -x "$HOME/Downloads/gnat-x86_64-linux-14.2.0-1/bin/gcc" ]; then
    export CC="$HOME/Downloads/gnat-x86_64-linux-14.2.0-1/bin/gcc"
fi
echo "dpdk-build-nic: CC=${CC:-cc}  ($(${CC:-cc} --version | head -1))"

DRIVERS=bus/pci,bus/vdev,mempool/ring
DRIVERS=$DRIVERS,net/ixgbe,net/i40e,net/ice,net/e1000       # the NIC PMDs
DRIVERS=$DRIVERS,net/af_packet,net/memif,net/null,net/ring  # keep the vdev ones

cd "$SRC"
rm -rf build-nic
meson setup build-nic \
    --prefix="$PREFIX" -Dlibdir=lib \
    -Ddefault_library=static -Dcpu_instruction_set=generic \
    -Denable_drivers="$DRIVERS" \
    -Ddisable_apps='*' -Dtests=false >/dev/null

ninja -C build-nic >/dev/null
meson install -C build-nic >/dev/null

echo
echo "dpdk-build-nic: installed to $PREFIX"
echo "PMDs built:"
for f in "$PREFIX"/lib/librte_net_*.a "$PREFIX"/lib/librte_bus_pci.a; do
    [ -e "$f" ] && echo "    $(basename "$f")"
done

# The point of the whole exercise: does it have VFIO?
#
# grep -c, not grep -q: under `set -o pipefail`, grep -q exits at the first match,
# nm takes a SIGPIPE, and the pipeline returns 141 -- so the check would report
# "MISSING" precisely when VFIO *is* there.  grep -c drains its input instead.
VFIO_N="$(nm "$PREFIX/lib/librte_eal.a" 2>/dev/null | grep -c 'T rte_vfio_enable' || true)"
if [ "${VFIO_N:-0}" != "0" ]; then
    echo "    VFIO: present  -> kernel bypass is possible with this build"
else
    echo "    VFIO: MISSING  -> this build still cannot do kernel bypass" >&2
    exit 1
fi

cat <<EOF

Next:
    DPDK_PREFIX=$PREFIX WITH_DPDK=yes ./tools/build.sh
    ./tools/dpdk-test.sh          # memif sanity check (not bypass)
    # then follow KERNEL-BYPASS.TXT on each machine with the Intel NIC
EOF
