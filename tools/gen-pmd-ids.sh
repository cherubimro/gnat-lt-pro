#!/usr/bin/env bash
# Regenerate tools/pmd-ids.txt from the DPDK source's own PCI id tables.
#
# Why the table exists: vfio-setup.sh and bypass.sh must answer "which DPDK PMD
# drives this card?" before they bind anything.  Grepping the DPDK source works
# on a machine that HAS the DPDK source -- but the whole point is to be able to
# copy the pre-built binaries to the Intel machines and run there, with no
# toolchain and no DPDK tree.  So the answer is baked into a small text file.
#
# It is generated, never hand-written: hand-written PCI id lists rot, and a wrong
# entry here means binding a card DPDK cannot drive.
#
#   ./tools/gen-pmd-ids.sh                 # uses the vendored DPDK source
#   DPDK_SRC=/path/to/dpdk ./tools/gen-pmd-ids.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SRC="${DPDK_SRC:-$here/../../dpdk/deps/dpdk-stable-22.11.9}"
OUT="$here/pmd-ids.txt"

[ -d "$SRC/drivers/net" ] || { echo "no DPDK source at $SRC (set DPDK_SRC=...)" >&2; exit 1; }

{
    echo "# vendor:device  PMD   -- generated from DPDK 22.11 id tables by tools/gen-pmd-ids.sh"
    echo "# Lets vfio-setup.sh / bypass.sh identify a card's PMD WITHOUT the DPDK source tree,"
    echo "# so the pre-built binaries can just be copied to the Intel machines."
    echo "# Do not hand-edit: re-run tools/gen-pmd-ids.sh."
    for p in ixgbe i40e ice e1000; do
        grep -rhoiE '#define[[:space:]]+[A-Z0-9_]*DEV_ID[A-Z0-9_]*[[:space:]]+0x[0-9A-Fa-f]{4}' \
             "$SRC/drivers/net/$p/base/" 2>/dev/null \
          | grep -oiE '0x[0-9A-Fa-f]{4}$' | tr 'A-F' 'a-f' | sed 's/^0x//' | sort -u \
          | while read -r id; do echo "8086:$id $p"; done
    done
} > "$OUT"

echo "wrote $OUT  ($(grep -vc '^#' "$OUT") ids)"
grep -v '^#' "$OUT" | awk '{print $2}' | sort | uniq -c | sed 's/^/  /'
