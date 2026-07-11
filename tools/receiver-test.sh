#!/usr/bin/env bash
# End-to-end through the real receiver daemon: sender_stream -> receiver_stream.
#   tools/receiver-test.sh [size-bytes] [port] [seed]
# Exercises file mode, --pipe, and 3 concurrent parallel transfers, byte-comparing
# each reconstruction.  Uses --pace-us 40: on loopback the OS socket buffer is
# small (net.core.rmem_max) and there is no network backpressure, so the sender
# is paced (a real diode is paced by the link; a real receiver raises rmem_max
# and/or uses recvmmsg batching).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

SIZE="${1:-25000000}"
PORT="${2:-9400}"
SEED="${3:-7}"
PACE=40
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gprbuild -q -P lt_diode.gpr sender_stream.adb receiver_stream.adb
mkdir -p "$TMP/spool"
head -c "$SIZE" /dev/urandom > "$TMP/in.bin"
echo "input: $SIZE bytes, pace ${PACE}us"

# file mode: daemon does not exit, so kill it after the transfer drains.
p=$((PORT++))
timeout 90 ./bin/receiver_stream "$p" "$TMP/spool" "$SEED" 0 2>>"$TMP/r.log" &
rpid=$!; sleep 0.5
./bin/sender_stream --pace-us "$PACE" 127.0.0.1 "$p" "$SEED" transfer 0 < "$TMP/in.bin" 2>/dev/null
sleep 2; kill "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
if [ -f "$TMP/spool/transfer.finished" ] && cmp -s "$TMP/in.bin" "$TMP/spool/transfer"; then
    echo "  file: PASS"
else
    echo "  file: FAIL"; exit 1
fi

# --pipe mode: single-shot, exits on its own.
p=$((PORT++))
timeout 90 ./bin/receiver_stream --pipe "$p" "$TMP/spool" "$SEED" 0 > "$TMP/pipe.out" 2>>"$TMP/r.log" &
rpid=$!; sleep 0.5
./bin/sender_stream --pace-us "$PACE" 127.0.0.1 "$p" "$SEED" pfile 0 < "$TMP/in.bin" 2>/dev/null
wait "$rpid" || true
cmp -s "$TMP/in.bin" "$TMP/pipe.out" && echo "  pipe: PASS" || { echo "  pipe: FAIL"; exit 1; }

# parallel: 3 concurrent transfers with distinct FILEIDs through one daemon.
p=$((PORT++))
for n in A B C; do head -c 2000000 /dev/urandom > "$TMP/p$n.bin"; done
timeout 90 ./bin/receiver_stream "$p" "$TMP/spool" "$SEED" 0 2>>"$TMP/r.log" &
rpid=$!; sleep 0.5
for n in A B C; do
    ./bin/sender_stream --pace-us "$PACE" 127.0.0.1 "$p" "$SEED" "par$n" 0 < "$TMP/p$n.bin" 2>/dev/null &
done
wait $(jobs -p | grep -v "$rpid") 2>/dev/null || true
sleep 2.5; kill "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
for n in A B C; do
    if [ -f "$TMP/spool/par$n.finished" ] && cmp -s "$TMP/p$n.bin" "$TMP/spool/par$n"; then
        echo "  parallel[$n]: PASS"
    else
        echo "  parallel[$n]: FAIL"; exit 1
    fi
done
echo "RESULT: PASS"
