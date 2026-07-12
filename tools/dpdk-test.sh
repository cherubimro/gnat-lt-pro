#!/usr/bin/env bash
# End-to-end test of the DPDK *code path*, with NO root, NO hugepages and NO NIC.
#
# READ THIS BEFORE QUOTING THE RESULT
# -----------------------------------
# The two ends are joined by DPDK's memif PMD: a SHARED-MEMORY PIPE between two
# processes on ONE machine.  It is a real ethdev port, so this genuinely
# exercises EAL bring-up, the C shim, rte_eth_rx_burst / rte_eth_tx_burst, the
# mbuf discipline and the raw-Ethernet framing -- and it proves the core and the
# checksum gate behave identically to the kernel path.
#
# But memif IS NOT KERNEL BYPASS and does not cross a wire.  It needs no root
# precisely BECAUSE it bypasses nothing.  This test says nothing about NIC-level
# bypass, line rate, or two-machine operation.
#
# Real bypass (vfio-pci) needs root once for setup: an IOMMU, hugepages, and a
# SPARE NIC bound away from the kernel.  It also needs a DPDK built with your
# NIC's PMD -- the vendored one in ../dpdk/deps has none (vdev PMDs only), so it
# cannot do real bypass at all.  See docs/ASSURANCE.md §5.1.
#
#   ./tools/dpdk-test.sh
#
# Needs a DPDK build:  WITH_DPDK=yes ./tools/build.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

SOCK=/tmp/lt-diode-memif.sock
TMP="$(mktemp -d)"
RX=""
cleanup () { [ -n "$RX" ] && kill "$RX" 2>/dev/null; rm -rf "$TMP" "$SOCK"; }
trap cleanup EXIT

SPOOL="$TMP/spool"; mkdir -p "$SPOOL"
SEED=1234; FAILS=0
pass () { echo "  PASS  $1"; }
fail () { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }

# NB: grep -c, not grep -q.  Under `set -o pipefail`, grep -q exits at the first
# match, nm takes a SIGPIPE, and the pipeline reports 141 -- so the check would
# "fail" precisely when DPDK *is* linked.  grep -c drains its input instead.
HAVE_DPDK="$(nm bin/receiver_stream 2>/dev/null | grep -c ' T rte_eal_init' || true)"
if [ "$HAVE_DPDK" = "0" ]; then
    echo "receiver_stream has no DPDK linked in."
    echo "  build it first:  WITH_DPDK=yes ./tools/build.sh"
    exit 1
fi

rm -f "$SOCK"

# memif: one side is the server (creates the socket), the other the client.  A
# memif client does NOT retry at start-up -- if the server is not listening yet
# its rte_eth_dev_start() simply fails -- so the receiver (server) goes first
# and the sender waits for the socket file to appear.  socket-abstract=no is
# what makes it appear on disk at all (the default is an abstract socket).
EAL_RX="--no-huge --file-prefix=ltrx -l 0 \
--vdev=net_memif0,role=server,socket=$SOCK,socket-abstract=no"
EAL_TX="--no-huge --file-prefix=lttx -l 1 \
--vdev=net_memif0,role=client,socket=$SOCK,socket-abstract=no"

echo "== 1. receiver comes up on a DPDK port (memif server) =="
./bin/receiver_stream --with-dpdk --eal "$EAL_RX" \
    --max-inflight 4 --evict-timeout 15 \
    0 "$SPOOL" "$SEED" 0 >"$TMP/rx.log" 2>&1 &
RX=$!

# Wait for the daemon to say it is listening, not merely for the socket to
# exist: memif creates the socket inside rte_eth_dev_start(), i.e. before the
# receiver has finished coming up.
for _ in $(seq 1 60); do
    grep -q 'kernel bypass' "$TMP/rx.log" 2>/dev/null && break
    sleep 0.25
done
if [ -S "$SOCK" ] && kill -0 "$RX" 2>/dev/null; then
    pass "receiver up, memif socket listening"
else
    fail "receiver did not come up"; sed -n '1,25p' "$TMP/rx.log"; exit 1
fi
if grep -q 'kernel bypass' "$TMP/rx.log" 2>/dev/null; then
    pass "receiver selected the DPDK transport"
else
    fail "receiver did not select DPDK"
fi

echo "== 2. transfer a 3 MB file over the DPDK path =="
head -c 3000000 /dev/urandom > "$TMP/a.bin"
./bin/sender_stream --with-dpdk --eal "$EAL_TX" --pace-us 20 \
    0 0 "$SEED" alpha 0 < "$TMP/a.bin" >"$TMP/tx.log" 2>&1
TXRC=$?
[ "$TXRC" = 0 ] && pass "sender ran clean" || { fail "sender exited $TXRC"; sed -n '1,25p' "$TMP/tx.log"; }

for _ in $(seq 1 60); do [ -f "$SPOOL/alpha.finished" ] && break; sleep 0.5; done
if [ -f "$SPOOL/alpha.finished" ] && cmp -s "$TMP/a.bin" "$SPOOL/alpha"; then
    pass "3 MB decoded BYTE-EXACT over DPDK (checksum gate: .finished)"
else
    fail "transfer did not complete byte-exact"
    ls -la "$SPOOL"; sed -n '1,30p' "$TMP/rx.log"
fi

echo "== 3. a second transfer on the same live port =="
head -c 1500000 /dev/urandom > "$TMP/b.bin"
./bin/sender_stream --with-dpdk --eal "$EAL_TX" --pace-us 20 \
    0 0 "$SEED" beta 0 < "$TMP/b.bin" >>"$TMP/tx.log" 2>&1
for _ in $(seq 1 60); do [ -f "$SPOOL/beta.finished" ] && break; sleep 0.5; done
if [ -f "$SPOOL/beta.finished" ] && cmp -s "$TMP/b.bin" "$SPOOL/beta"; then
    pass "second transfer decoded byte-exact (port stays serving)"
else
    fail "second transfer failed"
fi

echo "== 4. the checksum gate is still the gate =="
grep -q 'verdict=ok' "$SPOOL/verify.log" 2>/dev/null \
    && pass "verify.log records ok verdicts on the DPDK path" \
    || fail "no ok verdict in verify.log"

kill "$RX" 2>/dev/null; wait "$RX" 2>/dev/null; RX=""
echo
if [ "$FAILS" = 0 ]; then
    echo ">>> DPDK CODE PATH TEST PASSED"
    echo "    (over memif: shared memory, one machine.  NOT kernel bypass, and"
    echo "     not across a wire -- see the header of this script and"
    echo "     docs/ASSURANCE.md 5.1 before quoting this as a bypass result.)"
else
    echo ">>> $FAILS CHECK(S) FAILED"; exit 1
fi
