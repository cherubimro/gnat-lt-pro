#!/usr/bin/env bash
# End-to-end through the real receiver: sender_stream -> receiver_stream.
#   tools/receiver-test.sh [size-bytes] [port] [seed]
# Runs both file mode (writes <spool>/transfer + .finished) and --pipe mode,
# and byte-compares each reconstruction against the input.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

SIZE="${1:-25000000}"
PORT="${2:-9400}"
SEED="${3:-7}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gprbuild -q -P lt_diode.gpr sender_stream.adb receiver_stream.adb
mkdir -p "$TMP/spool"
head -c "$SIZE" /dev/urandom > "$TMP/in.bin"
echo "input: $SIZE bytes"

run () {   # $1 = mode label, $2... = receiver flags
    local label="$1"; shift
    local p=$((PORT++))
    if [ "$label" = pipe ]; then
        timeout 60 ./bin/receiver_stream --pipe "$p" "$TMP/spool" "$SEED" 0 \
            > "$TMP/pipe.out" 2>"$TMP/r.log" &
    else
        timeout 60 ./bin/receiver_stream "$p" "$TMP/spool" "$SEED" 0 \
            2>"$TMP/r.log" &
    fi
    local rpid=$!
    sleep 0.5
    ./bin/sender_stream --pace-us 15 127.0.0.1 "$p" "$SEED" transfer 0 \
        < "$TMP/in.bin" 2>/dev/null
    wait "$rpid" || true
    grep -E 'transfer done|evict|CORRUPT' "$TMP/r.log" || true
    local out="$TMP/spool/transfer"
    [ "$label" = pipe ] && out="$TMP/pipe.out"
    if cmp -s "$TMP/in.bin" "$out"; then
        echo "  $label: PASS"
    else
        echo "  $label: FAIL"; exit 1
    fi
}

run file
rm -f "$TMP/spool/transfer" "$TMP/spool/transfer.finished"
run pipe
echo "RESULT: PASS"
