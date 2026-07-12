#!/usr/bin/env bash
# bypass.sh -- the whole kernel-bypass flow, one command, on a machine with an
# Intel NIC.  Run it on BOTH machines: one as receiver, one as sender.
#
#   ./tools/bypass.sh doctor                     # check everything, change nothing
#
#   sudo ./tools/bypass.sh receiver eno2                       # on machine A
#   sudo ./tools/bypass.sh sender   eno2 /path/to/bigfile      # on machine B
#
#   sudo ./tools/bypass.sh teardown eno2         # give the NIC back to the kernel
#
# It does, in order, skipping whatever is already done:
#
#   1. build a DPDK that has the PCI bus + Intel PMDs   (tools/dpdk-build-nic.sh)
#   2. build sender_stream / receiver_stream against it (WITH_DPDK=yes)
#   3. verify the binary really has VFIO and your card's PMD linked in
#   4. allocate hugepages
#   5. bind the NIC to vfio-pci                         (tools/vfio-setup.sh)
#   6. run the daemon / the transfer, on the bypassed port
#
# THE SEED MUST MATCH ON BOTH MACHINES.  It selects the fountain-code sampling.
# Default 1234; override with SEED=... in the environment.
#
# A NIC bound to vfio-pci DISAPPEARS FROM THE KERNEL.  Never point this at the
# card carrying your SSH session -- vfio-setup.sh will refuse, and you should let
# it.  Read KERNEL-BYPASS.TXT.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here/.."

NIC_PREFIX="${DPDK_NIC_PREFIX:-$(cd "$here/../../dpdk/deps" 2>/dev/null && pwd)/dpdk-install-nic}"
SEED="${SEED:-1234}"
SPOOL="${SPOOL:-/var/spool/lt-diode}"
LCORE="${LCORE:-0}"
HUGE="${HUGE:-512}"
TEARDOWN=0

say  () { echo; echo "=== $* ==="; }
ok   () { echo "  ok   $*"; }
warn () { echo "  !!   $*" >&2; }
die  () { echo; echo "bypass: $*" >&2; exit 1; }

need_root () { [ "$(id -u)" = 0 ] || die "run as root (sudo), it must bind the NIC"; }

# --------------------------------------------------------------------------
# Resolve the NIC to a PCI address BEFORE binding -- once it is on vfio-pci the
# interface name is gone, so the name is only usable up front.
# --------------------------------------------------------------------------
resolve_pci () {
    local t="$1"
    if [ -e "/sys/bus/pci/devices/$t" ]; then echo "$t"; return; fi
    if [ -e "/sys/class/net/$t/device" ]; then
        basename "$(readlink -f "/sys/class/net/$t/device")"; return
    fi
    die "no such interface or PCI device: $t
     (already bound?  pass the PCI address instead:  ./tools/bypass.sh $ROLE 0000:03:00.0 ...)"
}

pci_driver () {
    local d; d="$(readlink -f "/sys/bus/pci/devices/$1/driver" 2>/dev/null)"
    [ -n "$d" ] && basename "$d" || echo "-"
}

# Which PMD does this card need?  From tools/pmd-ids.txt, generated out of DPDK's
# own id tables (tools/gen-pmd-ids.sh) -- a plain file, so this still works on a
# machine that has only the copied binaries: no DPDK source, no toolchain.
pmd_for () {
    local ven dev p hit src="$here/../../dpdk/deps/dpdk-stable-22.11.9"
    ven="$(cat "/sys/bus/pci/devices/$1/vendor" 2>/dev/null)"; ven="${ven#0x}"
    dev="$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null)"; dev="${dev#0x}"

    if [ -r "$here/pmd-ids.txt" ]; then
        hit="$(awk -v k="$ven:$dev" '$1==k {print $2; exit}' "$here/pmd-ids.txt")"
        [ -n "$hit" ] && { echo "$hit"; return; }
    fi
    if [ -d "$src/drivers/net" ]; then
        for p in ixgbe i40e ice e1000; do
            if [ -n "$(grep -rlis "0x$dev" "$src/drivers/net/$p/" 2>/dev/null | head -1)" ]; then
                echo "$p"; return
            fi
        done
    fi
    echo "?"
}

# nm | grep -c, never grep -q: under pipefail, grep -q exits early, nm takes a
# SIGPIPE, the pipeline returns 141, and the check reports ABSENT exactly when
# the symbol IS present.  (This bit us twice.)
sym_count () { nm "$1" 2>/dev/null | grep -cis "$2" || true; }

# ---------------------------------------------------------------- 1. DPDK ----

step_dpdk () {
    say "1/6  DPDK with PCI + Intel PMDs"
    if [ -e "$NIC_PREFIX/lib/librte_net_ixgbe.a" ]; then
        ok "already built ($NIC_PREFIX)"
        return
    fi
    if pkg-config --exists libdpdk 2>/dev/null && \
       [ "$(pkg-config --static --libs libdpdk | grep -c 'librte_net_ixgbe')" -gt 0 ]; then
        ok "system libdpdk already carries the NIC PMDs -- using it"
        NIC_PREFIX=""                       # leave DPDK_PREFIX unset downstream
        return
    fi
    echo "  building (2-4 min, once) ..."
    "$here/dpdk-build-nic.sh" >/dev/null 2>&1 || die "tools/dpdk-build-nic.sh failed -- run it directly to see why"
    [ -e "$NIC_PREFIX/lib/librte_net_ixgbe.a" ] || die "DPDK built but has no ixgbe -- see tools/dpdk-build-nic.sh"
    ok "built $NIC_PREFIX"
}

# ----------------------------------------------------------------- 2. app ----

step_app () {
    say "2/6  build sender/receiver with WITH_DPDK=yes"
    if [ "$(sym_count bin/receiver_stream ' rte_vfio_enable')" -gt 0 ] && \
       [ "$(sym_count bin/receiver_stream "$PMD")" -gt 0 ]; then
        ok "binaries already have VFIO + $PMD"
        return
    fi
    if [ -n "$NIC_PREFIX" ]; then
        DPDK_PREFIX="$NIC_PREFIX" WITH_DPDK=yes ./tools/build.sh >/dev/null 2>&1 \
            || die "build failed -- run:  DPDK_PREFIX=$NIC_PREFIX WITH_DPDK=yes ./tools/build.sh"
    else
        env -u DPDK_PREFIX WITH_DPDK=yes ./tools/build.sh >/dev/null 2>&1 \
            || die "build failed -- run:  WITH_DPDK=yes ./tools/build.sh"
    fi
    ok "built"
}

# -------------------------------------------------------------- 3. verify ----

step_verify () {
    say "3/6  verify the binary can actually drive this card"
    local v p
    v="$(sym_count bin/receiver_stream ' rte_vfio_enable')"
    p="$(sym_count bin/receiver_stream "$PMD")"
    [ "$v" -gt 0 ] || die "no VFIO in the binary -- it cannot do kernel bypass.
     The DPDK you linked has no PCI support.  Run ./tools/dpdk-build-nic.sh"
    [ "$p" -gt 0 ] || die "no '$PMD' PMD in the binary -- it cannot drive $PCI.
     Rebuild DPDK including net/$PMD (see tools/dpdk-build-nic.sh)"
    ok "VFIO: $v symbols,  $PMD: $p symbols"
}

# ----------------------------------------------------------- 4. hugepages ----

step_hugepages () {
    say "4/6  hugepages"
    local n; n="$(awk '/^HugePages_Total/{print $2}' /proc/meminfo)"
    if [ "${n:-0}" -ge 64 ]; then
        ok "$n pages already allocated"
    else
        echo "$HUGE" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages \
            || die "cannot allocate hugepages"
        [ -d /dev/hugepages ] || { mkdir -p /dev/hugepages; mount -t hugetlbfs none /dev/hugepages 2>/dev/null; }
        ok "allocated $(awk '/^HugePages_Total/{print $2}' /proc/meminfo) x 2MB"
    fi
}

# ---------------------------------------------------------------- 5. bind ----

step_bind () {
    say "5/6  bind $PCI to vfio-pci"
    if [ "$(pci_driver "$PCI")" = "vfio-pci" ]; then
        ok "already bound"
        return
    fi
    "$here/vfio-setup.sh" bind "$PCI" || die "bind refused (that is the guard doing its job -- read it)"
    [ "$(pci_driver "$PCI")" = "vfio-pci" ] || die "bind did not take"
}

# ----------------------------------------------------------------- 6. run ----

# -a $PCI allowlists exactly this card, so DPDK cannot pick up some other bound
# device.  No --no-huge: we allocated real hugepages in step 4.
eal_args () { echo "-l $LCORE -a $PCI --file-prefix=ltd$$"; }

run_receiver () {
    mkdir -p "$SPOOL"
    say "6/6  receiver on the bypassed port"
    echo "  spool  : $SPOOL"
    echo "  seed   : $SEED   <-- the sender MUST use the same"
    echo "  EAL    : $(eal_args)"
    echo "  (Ctrl-C to stop; the NIC stays bound -- 'bypass.sh teardown $PCI' returns it)"
    echo
    exec ./bin/receiver_stream --with-dpdk --eal "$(eal_args)" \
        0 "$SPOOL" "$SEED" 0
}

run_sender () {
    local f="$1"
    [ -r "$f" ] || die "cannot read $f"
    local name; name="$(basename "$f")"
    say "6/6  sending $name ($(stat -c %s "$f") bytes) on the bypassed port"
    echo "  seed   : $SEED   <-- the receiver MUST use the same"
    echo "  dst    : ${DST:-broadcast}"
    echo "  EAL    : $(eal_args)"
    echo
    if [ -n "${DST:-}" ]; then
        ./bin/sender_stream --with-dpdk --eal "$(eal_args)" --dst "$DST" \
            0 0 "$SEED" "$name" 0 < "$f"
    else
        ./bin/sender_stream --with-dpdk --eal "$(eal_args)" \
            0 0 "$SEED" "$name" 0 < "$f"
    fi
    local rc=$?
    echo
    [ "$rc" = 0 ] && ok "sent.  Check the receiver's spool for $name.finished" \
                  || warn "sender exited $rc"
    return $rc
}

# -------------------------------------------------------------- teardown -----

cmd_teardown () {
    need_root
    local t="${1:?usage: bypass.sh teardown <iface|pci>}"
    "$here/vfio-setup.sh" unbind "$t"
}

# ---------------------------------------------------------------- doctor -----

cmd_doctor () {
    say "cards"
    "$here/vfio-setup.sh" status
    say "environment"
    "$here/vfio-setup.sh" check
    say "binaries"
    if [ -e bin/receiver_stream ]; then
        printf '  vfio=%s ixgbe=%s i40e=%s e1000=%s\n' \
            "$(sym_count bin/receiver_stream ' rte_vfio_enable')" \
            "$(sym_count bin/receiver_stream ixgbe)" \
            "$(sym_count bin/receiver_stream i40e)" \
            "$(sym_count bin/receiver_stream e1000)"
        [ "$(sym_count bin/receiver_stream ' rte_vfio_enable')" -gt 0 ] \
            && ok "built for kernel bypass" \
            || warn "no VFIO: this binary cannot do bypass (bypass.sh will rebuild it)"
    else
        warn "not built yet (bypass.sh will build)"
    fi
    say "verdict"
    echo "  Run:  sudo ./tools/bypass.sh receiver <iface>        (machine A)"
    echo "        sudo ./tools/bypass.sh sender   <iface> FILE   (machine B)"
    echo "  Both machines must use the same SEED (now: $SEED) and share an L2 segment."
}

# ------------------------------------------------------------------ main -----

ROLE="${1:-help}"
case "$ROLE" in
    doctor)   cmd_doctor ;;
    teardown) shift; cmd_teardown "$@" ;;
    receiver|sender)
        shift
        TARGET="${1:-}"
        [ -n "$TARGET" ] || die "usage: bypass.sh $ROLE <iface|pci> $([ "$ROLE" = sender ] && echo '<file>')"
        shift
        #  Diagnose BEFORE demanding root: a user without sudo should still get
        #  the useful answer ("this card has no PMD"), not "run as root".
        PCI="$(resolve_pci "$TARGET")"
        PMD="$(pmd_for "$PCI")"
        [ "$PMD" != "?" ] || die "no DPDK PMD matches $PCI.
     DPDK 22.11 has no driver for this card, so kernel bypass is IMPOSSIBLE with it,
     no matter what you configure.  (This box's onboard Realtek is exactly that
     case -- you need the machine with the Intel card.)
     See:  ./tools/vfio-setup.sh status"
        echo "card: $PCI   PMD: $PMD"
        need_root

        step_dpdk
        step_app
        step_verify
        step_hugepages
        step_bind
        if [ "$ROLE" = receiver ]; then
            run_receiver
        else
            [ -n "${1:-}" ] || die "usage: bypass.sh sender <iface|pci> <file>"
            run_sender "$1"
        fi
        ;;
    *) sed -n '2,26p' "$0" | sed 's/^# \?//' ;;
esac
