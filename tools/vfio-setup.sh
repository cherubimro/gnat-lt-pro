#!/usr/bin/env bash
# vfio-setup.sh -- bind an Intel NIC to vfio-pci for DPDK kernel bypass, safely.
#
#   sudo ./tools/vfio-setup.sh status            # what NICs exist, which are safe
#   sudo ./tools/vfio-setup.sh check             # IOMMU / hugepages / vfio preflight
#   sudo ./tools/vfio-setup.sh hugepages [N]     # allocate N x 2MB pages (default 512)
#   sudo ./tools/vfio-setup.sh bind   eth1       # take it from the kernel, give to DPDK
#   sudo ./tools/vfio-setup.sh unbind 0000:03:00.0   # give it back to the kernel
#
# `bind` accepts an interface name OR a PCI address.  It REFUSES to bind a card
# that carries your default route or your SSH session, because a bound NIC
# DISAPPEARS FROM THE KERNEL -- no IP, no ifconfig, no SSH.  Getting that wrong
# on a remote box means you have lost the machine.  --force overrides, and you
# should not use it over SSH on the card you are sitting on.
#
# Read KERNEL-BYPASS.TXT first.  Nothing here is needed for the default (kernel
# transport) build of this project.
set -uo pipefail

STATE=/var/lib/lt-diode/vfio.state
DPDK_SRC="${DPDK_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../dpdk/deps" 2>/dev/null && pwd)/dpdk-stable-22.11.9}"

die  () { echo "vfio-setup: $*" >&2; exit 1; }
warn () { echo "  !! $*" >&2; }
ok   () { echo "  ok  $*"; }

need_root () { [ "$(id -u)" = 0 ] || die "must run as root (use sudo)"; }

# ---------------------------------------------------------------- helpers ----

# accept "eth1" or "0000:03:00.0" -> canonical PCI address
resolve_pci () {
    local t="$1"
    if [ -e "/sys/bus/pci/devices/$t" ]; then echo "$t"; return 0; fi
    if [ -e "/sys/class/net/$t/device" ]; then
        basename "$(readlink -f "/sys/class/net/$t/device")"; return 0
    fi
    die "no such interface or PCI device: $t"
}

pci_attr () { cat "/sys/bus/pci/devices/$1/$2" 2>/dev/null; }

pci_driver () {
    local d
    d="$(readlink -f "/sys/bus/pci/devices/$1/driver" 2>/dev/null)"
    [ -n "$d" ] && basename "$d" || echo "-"
}

pci_iface () { ls "/sys/bus/pci/devices/$1/net/" 2>/dev/null | head -1; }

pci_group () {
    local g
    g="$(readlink -f "/sys/bus/pci/devices/$1/iommu_group" 2>/dev/null)"
    [ -n "$g" ] && basename "$g" || echo "-"
}

# Which DPDK PMD claims this device?  Never guess -- a wrong answer here means
# binding a card DPDK cannot drive.
#
# Primary source is tools/pmd-ids.txt, generated from DPDK's own id tables by
# tools/gen-pmd-ids.sh.  It is a plain file precisely so this works on a machine
# that has the pre-built binaries but no DPDK source and no toolchain.  If the
# source tree IS present we fall back to grepping it directly.
IDS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pmd-ids.txt"

which_pmd () {
    local ven="${1#0x}" dev="${2#0x}" p hit
    if [ -r "$IDS" ]; then
        hit="$(awk -v k="$ven:$dev" '$1==k {print $2; exit}' "$IDS")"
        [ -n "$hit" ] && { echo "$hit"; return; }
    fi
    if [ -d "$DPDK_SRC/drivers/net" ]; then
        for p in ixgbe i40e ice e1000; do
            if [ -n "$(grep -rlis "0x$dev" "$DPDK_SRC/drivers/net/$p/" 2>/dev/null | head -1)" ]; then
                echo "$p"; return
            fi
        done
    fi
    echo "?"
}

# The interface(s) we must never touch.
default_iface () { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'; }

ssh_iface () {
    [ -n "${SSH_CONNECTION:-}" ] || return 0
    local srv; srv="$(echo "$SSH_CONNECTION" | awk '{print $3}')"
    [ -n "$srv" ] || return 0
    ip -o addr show 2>/dev/null | awk -v ip="$srv" '$4 ~ "^"ip"/" {print $2}'
}

has_ip () { [ -n "$(ip -o -4 addr show dev "$1" 2>/dev/null)" ]; }

# ----------------------------------------------------------------- status ----

cmd_status () {
    local danger d pci drv ifc grp ven dev pmd
    danger="$(default_iface) $(ssh_iface)"

    printf '%-14s %-9s %-9s %-6s %-11s %s\n' PCI IFACE DRIVER IOMMU "VENDOR:DEV" "DPDK PMD"
    for d in /sys/bus/pci/devices/*/; do
        [ "$(cat "$d/class" 2>/dev/null)" != "0x020000" ] && continue
        pci="$(basename "$d")"
        drv="$(pci_driver "$pci")"; ifc="$(pci_iface "$pci")"; grp="$(pci_group "$pci")"
        ven="$(pci_attr "$pci" vendor)"; dev="$(pci_attr "$pci" device)"
        pmd="$(which_pmd "$ven" "$dev")"
        printf '%-14s %-9s %-9s %-6s %-11s %s' \
            "$pci" "${ifc:--}" "$drv" "$grp" "${ven#0x}:${dev#0x}" "$pmd"
        case " $danger " in *" ${ifc:-__none__} "*) printf '   <-- DO NOT BIND (default route / SSH)';; esac
        [ "$drv" = vfio-pci ] && printf '   <-- bound to DPDK'
        echo
    done
    echo
    echo "  DPDK PMD '?' means no driver in DPDK 22.11 for that card (e.g. Realtek)."
    echo "  Bind only a card whose PMD is ixgbe / i40e / ice / e1000 -- and never one marked DO NOT BIND."
}

# ------------------------------------------------------------------ check ----

cmd_check () {
    local n rc=0
    echo "IOMMU"
    n="$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)"
    if [ "$n" -gt 0 ]; then ok "active ($n groups)"
    else
        warn "NO IOMMU.  Add intel_iommu=on iommu=pt (or amd_iommu=on) to the kernel"
        warn "cmdline, enable VT-d/AMD-Vi in the BIOS, and reboot."
        warn "Fallback (UNSAFE, lab only): $0 noiommu"
        rc=1
    fi

    echo "vfio-pci module"
    #  Do not rely on modinfo: it lives in /sbin, which is not on a normal
    #  user's PATH, so "modinfo failed" would read as "no vfio in this kernel".
    #  Look for the module file itself.
    if [ -d /sys/module/vfio_pci ]; then
        ok "loaded"
    elif [ -n "$(find "/lib/modules/$(uname -r)" -name 'vfio-pci.ko*' 2>/dev/null | head -1)" ] \
      || /sbin/modinfo vfio-pci >/dev/null 2>&1; then
        warn "available but not loaded  ->  modprobe vfio-pci   (bind does this for you)"
    else
        warn "vfio-pci not available in this kernel"; rc=1
    fi

    echo "hugepages"
    n="$(grep -E '^HugePages_Total' /proc/meminfo | awk '{print $2}')"
    if [ "${n:-0}" -gt 0 ]; then ok "$n pages"
    else warn "none allocated  ->  $0 hugepages 512"; fi

    echo "a usable NIC"
    if [ "$(cmd_status 2>/dev/null | grep -cE ' (ixgbe|i40e|ice|e1000)$')" -gt 0 ]; then
        ok "at least one card has a DPDK PMD"
    else
        warn "no card with a DPDK PMD (see: $0 status).  Bypass is impossible here."
        rc=1
    fi
    return $rc
}

# -------------------------------------------------------------- hugepages ----

cmd_hugepages () {
    need_root
    local n="${1:-512}"
    echo "$n" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages \
        || die "cannot set hugepages"
    grep -E 'HugePages_(Total|Free)' /proc/meminfo
    [ -d /dev/hugepages ] || { mkdir -p /dev/hugepages; mount -t hugetlbfs none /dev/hugepages; }
    echo "vfio-setup: to make it persist, add to /etc/sysctl.conf:  vm.nr_hugepages = $n"
}

# ---------------------------------------------------------------- noiommu ----

cmd_noiommu () {
    need_root
    cat >&2 <<'EOF'
  !! UNSAFE MODE.  Without an IOMMU the card can DMA to ANY physical address,
  !! with no hardware protection: a buggy or hostile PMD can scribble anywhere
  !! in RAM.  It also needs CAP_SYS_RAWIO, so you are effectively root anyway.
  !! Use this ONLY on a lab machine you do not care about.  The right fix is to
  !! enable VT-d / AMD-Vi in the BIOS and add intel_iommu=on to the cmdline.
EOF
    read -r -p "  type 'yes, I accept unrestricted DMA' to continue: " a
    [ "$a" = "yes, I accept unrestricted DMA" ] || die "aborted (good)"
    modprobe vfio 2>/dev/null
    echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode \
        || die "cannot enable noiommu"
    ok "noiommu enabled"
}

# ------------------------------------------------------------------- bind ----

cmd_bind () {
    need_root
    local target="${1:-}" force="${2:-}"
    [ -n "$target" ] || die "usage: $0 bind <iface|pci> [--force]"

    local pci; pci="$(resolve_pci "$target")" || exit 1
    local drv ifc grp ven dev pmd
    drv="$(pci_driver "$pci")"; ifc="$(pci_iface "$pci")"; grp="$(pci_group "$pci")"
    ven="$(pci_attr "$pci" vendor)"; dev="$(pci_attr "$pci" device)"

    echo "target: $pci  iface=${ifc:--}  driver=$drv  vendor:dev=${ven#0x}:${dev#0x}"

    [ "$(pci_attr "$pci" class)" = "0x020000" ] || die "$pci is not an Ethernet controller"
    [ "$drv" = "vfio-pci" ] && { ok "already bound to vfio-pci"; exit 0; }

    # ---- the checks that save your machine -------------------------------
    local danger; danger="$(default_iface) $(ssh_iface)"
    if [ -n "$ifc" ]; then
        case " $danger " in
            *" $ifc "*)
                echo >&2
                warn "$ifc carries your DEFAULT ROUTE and/or your SSH SESSION."
                warn "Binding it to vfio-pci REMOVES IT FROM THE KERNEL: no IP, no SSH."
                warn "If you are on this box remotely, you will lose it right now."
                [ "$force" = "--force" ] || die "refusing (use --force only from a console you can reach)"
                warn "--force given.  On your head be it."
                ;;
        esac
        if has_ip "$ifc" && [ "$force" != "--force" ]; then
            warn "$ifc has an IPv4 address configured."
            die "refusing (remove the address, or pass --force)"
        fi
    fi

    [ "${ven#0x}" = "8086" ] || warn "not an Intel card -- DPDK may have no PMD for it"
    pmd="$(which_pmd "$ven" "$dev")"
    if [ "$pmd" = "?" ]; then
        warn "no DPDK 22.11 PMD matches device ${ven#0x}:${dev#0x}."
        warn "Binding it will succeed and then DPDK will report 'no ethdev port available'."
        [ "$force" = "--force" ] || die "refusing (pointless without a PMD)"
    else
        ok "DPDK PMD: $pmd"
    fi

    # ---- IOMMU ------------------------------------------------------------
    local noiommu=0
    [ "$(cat /sys/module/vfio/parameters/enable_unsafe_noiommu_mode 2>/dev/null)" = "Y" ] && noiommu=1
    if [ "$grp" = "-" ] && [ "$noiommu" = 0 ]; then
        die "no IOMMU group for $pci -- enable VT-d/AMD-Vi (see: $0 check)"
    fi

    # Every device sharing the IOMMU group must come along; a kernel driver
    # still holding one of them makes the group non-viable and vfio will refuse.
    if [ "$grp" != "-" ]; then
        local other odrv ocls bad=0
        for other in /sys/kernel/iommu_groups/"$grp"/devices/*; do
            other="$(basename "$other")"
            [ "$other" = "$pci" ] && continue
            ocls="$(pci_attr "$other" class)"
            case "$ocls" in 0x0604*|0x0600*) continue;; esac   # bridges are fine
            odrv="$(pci_driver "$other")"
            if [ "$odrv" = "-" ] || [ "$odrv" = "vfio-pci" ]; then
                continue                       # free, or already ours
            fi
            warn "IOMMU group $grp also holds $other (driver $odrv)"
            bad=1
        done
        [ "$bad" = 1 ] && warn "group is not viable until those are unbound too"
        [ "$bad" = 1 ] && [ "$force" != "--force" ] && die "refusing"
    fi

    # ---- do it ------------------------------------------------------------
    modprobe vfio-pci || die "cannot load vfio-pci"

    mkdir -p "$(dirname "$STATE")"
    # remember the kernel driver so `unbind` can hand it back
    grep -v "^$pci " "$STATE" 2>/dev/null > "$STATE.tmp" || true
    echo "$pci $drv ${ifc:--}" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"

    [ -n "$ifc" ] && ip link set "$ifc" down 2>/dev/null

    if [ "$drv" != "-" ]; then
        echo "$pci" > "/sys/bus/pci/devices/$pci/driver/unbind" 2>/dev/null
    fi
    echo "vfio-pci" > "/sys/bus/pci/devices/$pci/driver_override"
    echo "$pci"     > /sys/bus/pci/drivers_probe

    [ "$(pci_driver "$pci")" = "vfio-pci" ] || die "bind failed (still on $(pci_driver "$pci"))"
    ok "bound $pci to vfio-pci (was: $drv)"

    # Let the invoking user drive it without root at run time.
    if [ -n "${SUDO_USER:-}" ] && [ "$grp" != "-" ] && [ -e "/dev/vfio/$grp" ]; then
        chown "$SUDO_USER" "/dev/vfio/$grp" /dev/vfio/vfio 2>/dev/null \
            && ok "/dev/vfio/$grp owned by $SUDO_USER (run-time needs no root)"
        echo "      also raise the locked-memory limit for $SUDO_USER:"
        echo "        /etc/security/limits.conf:  $SUDO_USER  -  memlock  unlimited"
    fi

    cat <<EOF

  The interface is now GONE from the kernel.  That is correct: that is bypass.
  Run it (no --vdev: the PCI port is probed; no --no-huge: use the hugepages):

      ./bin/receiver_stream --with-dpdk --eal "-l 0" 0 /var/spool/lt-diode 1234 0
      ./bin/sender_stream   --with-dpdk --eal "-l 1" 0 0 1234 myfile 0 < myfile

  Give it back with:   sudo $0 unbind $pci
EOF
}

# ----------------------------------------------------------------- unbind ----

cmd_unbind () {
    need_root
    local target="${1:-}"
    [ -n "$target" ] || die "usage: $0 unbind <iface|pci>"
    local pci; pci="$(resolve_pci "$target")" || exit 1

    local orig
    orig="$(awk -v p="$pci" '$1==p {print $2}' "$STATE" 2>/dev/null | head -1)"
    [ -n "$orig" ] && [ "$orig" != "-" ] || orig=""

    echo "$pci" > "/sys/bus/pci/drivers/vfio-pci/unbind" 2>/dev/null
    echo ""     > "/sys/bus/pci/devices/$pci/driver_override"
    echo "$pci" > /sys/bus/pci/drivers_probe

    local now; now="$(pci_driver "$pci")"
    if [ "$now" = "-" ] && [ -n "$orig" ]; then
        modprobe "$orig" 2>/dev/null
        echo "$pci" > "/sys/bus/pci/drivers/$orig/bind" 2>/dev/null
        now="$(pci_driver "$pci")"
    fi

    if [ "$now" = "-" ] || [ "$now" = "vfio-pci" ]; then
        warn "could not restore a kernel driver (now: $now)."
        warn "try: modprobe ${orig:-ixgbe} ; echo $pci > /sys/bus/pci/drivers/${orig:-ixgbe}/bind"
        exit 1
    fi
    ok "restored $pci to kernel driver: $now"
    local ifc; ifc="$(pci_iface "$pci")"
    [ -n "$ifc" ] && { ip link set "$ifc" up 2>/dev/null; ok "interface $ifc is back"; }
    grep -v "^$pci " "$STATE" 2>/dev/null > "$STATE.tmp" || true
    mv "$STATE.tmp" "$STATE" 2>/dev/null || true
}

# ------------------------------------------------------------------- main ----

case "${1:-help}" in
    status)    cmd_status ;;
    check)     cmd_check ;;
    hugepages) shift; cmd_hugepages "$@" ;;
    noiommu)   cmd_noiommu ;;
    bind)      shift; cmd_bind "$@" ;;
    unbind)    shift; cmd_unbind "$@" ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \?//' ;;
esac
