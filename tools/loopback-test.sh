#!/usr/bin/env bash
# End-to-end loopback check: sender_stream -> udp_decode_sink, byte-compared.
#   tools/loopback-test.sh [size-bytes] [port] [seed] [loss%]
# The sink accumulates packets per group (no decode during receive) and decodes
# after the trailer; the sender is paced so loopback does not overflow the socket.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

SIZE="${1:-25000000}"
PORT="${2:-9200}"
SEED="${3:-7}"
LOSS="${4:-0}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

gprbuild -q -P lt_diode.gpr sender_stream.adb udp_decode_sink.adb

head -c "$SIZE" /dev/urandom > "$TMP/in.bin"
echo "input: $SIZE bytes, port $PORT, seed $SEED, loss ${LOSS}%"

./bin/udp_decode_sink "$PORT" "$SEED" "$TMP/out.bin" 2>"$TMP/sink.log" &
SINK=$!
sleep 0.6
./bin/sender_stream --pace-us 15 127.0.0.1 "$PORT" "$SEED" transfer "$LOSS" \
    < "$TMP/in.bin" 2>"$TMP/sender.log"
wait "$SINK" || true

cat "$TMP/sink.log"
if cmp -s "$TMP/in.bin" "$TMP/out.bin"; then
    echo "RESULT: PASS (decoded == input)"
else
    echo "RESULT: FAIL"
    exit 1
fi
