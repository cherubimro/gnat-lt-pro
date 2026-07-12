#!/usr/bin/env bash
# Trusted-boundary stress test.  The SPARK proof covers the codec core; this
# hammers the *trusted* I/O shell (routing, file open, writes, eviction) with
# adversarial and heavy inputs and asserts the daemon never crashes, never
# writes outside its spool, and gates/serves everything correctly.
set -uo pipefail                                   # not -e: run every check
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

gprbuild -q -P lt_diode.gpr receiver_stream.adb sender_stream.adb evil_send.adb

TMP="$(mktemp -d)"; trap 'kill $RX 2>/dev/null; rm -rf "$TMP"' EXIT
SPOOL="$TMP/spool"; mkdir -p "$SPOOL"
PORT=9990; SEED=1234; FAILS=0
pass () { echo "  PASS  $1"; }
fail () { echo "  FAIL  $1"; FAILS=$((FAILS+1)); }
alive () { kill -0 "$RX" 2>/dev/null; }

# One long-lived daemon takes everything we throw at it.
./bin/receiver_stream --max-inflight 8 --evict-timeout 3 \
    "$PORT" "$SPOOL" "$SEED" 0 2>"$TMP/rx.log" &
RX=$!; sleep 0.6

wait_marker () {  # $1=name $2=suffix $3=timeout-s
    for _ in $(seq 1 $(( $3 * 2 ))); do
        [ -f "$SPOOL/$1$2" ] && return 0; sleep 0.5; done; return 1
}
xfer () {  # $1=infile $2=name [pace]
    ./bin/sender_stream --pace-us "${3:-15}" 127.0.0.1 "$PORT" "$SEED" "$2" 0 \
        < "$1" 2>/dev/null
}

echo "== 1. path-traversal / hostile FILEIDs (must not write outside spool) =="
for bad in "../CANARY" "../../CANARY" ".." ".hidden" "a b" "x/y/z" "ok;rm -rf"; do
    ./bin/evil_send 127.0.0.1 "$PORT" "$bad" 0; sleep 0.15
done
sleep 0.5
OUT=$(find "$TMP" -mindepth 1 -maxdepth 1 -name 'CANARY*' 2>/dev/null)
[ -z "$OUT" ] && pass "nothing written outside the spool" \
              || fail "escaped spool: $OUT"
# every file that exists must be a plain file directly inside the spool
ESC=$(find "$SPOOL" -mindepth 2 2>/dev/null)
[ -z "$ESC" ] && pass "all output confined to spool root" || fail "subdir escape: $ESC"
alive && pass "daemon alive after hostile FILEIDs" || fail "daemon crashed"

echo "== 2. symlink attack (O_NOFOLLOW must refuse) =="
ln -s "$TMP/SYMTARGET" "$SPOOL/slink"
./bin/evil_send 127.0.0.1 "$PORT" "slink" 0; sleep 0.5
[ ! -e "$TMP/SYMTARGET" ] && pass "planted symlink not followed" \
                          || fail "FOLLOWED symlink -> $TMP/SYMTARGET written"

echo "== 3. malformed / garbage datagrams interleaved with a real transfer =="
python3 - "$PORT" <<'PY' &
import socket, os, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(2000):
    s.sendto(os.urandom(1472), ('127.0.0.1', int(sys.argv[1])))
PY
GARB=$!
head -c 3000000 /dev/urandom > "$TMP/valid.bin"
xfer "$TMP/valid.bin" valid
wait "$GARB" 2>/dev/null
if wait_marker valid .finished 8 && cmp -s "$TMP/valid.bin" "$SPOOL/valid"; then
    pass "valid transfer decoded byte-exact despite garbage flood"
else fail "valid transfer corrupted by garbage"; fi
alive && pass "daemon alive after garbage flood" || fail "daemon crashed on garbage"

echo "== 4. name collision (must not overwrite; numbered suffix) =="
xfer "$TMP/valid.bin" valid          # 'valid' already exists from step 3
wait_marker valid .1.finished 8 || wait_marker valid.1 .finished 8
if [ -f "$SPOOL/valid.1" ] && cmp -s "$TMP/valid.bin" "$SPOOL/valid.1"; then
    pass "collision -> wrote valid.1 without overwriting valid"
else fail "collision handling wrong"; fi

echo "== 5. large transfer (40 MB, ~4 groups) =="
head -c 40000000 /dev/urandom > "$TMP/big.bin"
xfer "$TMP/big.bin" bigxfer 12
if wait_marker bigxfer .finished 40 && cmp -s "$TMP/big.bin" "$SPOOL/bigxfer"; then
    pass "40 MB decoded byte-exact"
else fail "40 MB transfer failed"; fi

echo "== 6. concurrency + a stalled transfer (eviction, others unaffected) =="
for n in P Q R; do head -c 2000000 /dev/urandom > "$TMP/c$n.bin"; done
# establish a stalled transfer cleanly (into a quiet socket) then abandon it.
# Run the sender directly (not in a pipe) so its PID is the one we kill.
head -c 40000000 /dev/urandom > "$TMP/stall.bin"
./bin/sender_stream --pace-us 100 127.0.0.1 "$PORT" "$SEED" stalledx 0 \
    < "$TMP/stall.bin" 2>/dev/null & SP=$!
sleep 0.6; kill $SP 2>/dev/null; wait $SP 2>/dev/null
# now three healthy transfers concurrently while it stalls
CPIDS=""
for n in P Q R; do xfer "$TMP/c$n.bin" "conc$n" 30 & CPIDS="$CPIDS $!"; done
wait $CPIDS 2>/dev/null
OKC=0; for n in P Q R; do
    wait_marker "conc$n" .finished 8 && cmp -s "$TMP/c$n.bin" "$SPOOL/conc$n" && OKC=$((OKC+1)); done
[ "$OKC" = 3 ] && pass "all 3 concurrent transfers decoded" || fail "concurrent decode ($OKC/3)"
wait_marker stalledx .corrupt 12 && pass "stalled transfer evicted -> .corrupt" \
                                 || fail "stalled transfer not evicted"

echo "== 7. daemon still serving after all of the above =="
xfer "$TMP/valid.bin" final
if wait_marker final .finished 8 && cmp -s "$TMP/valid.bin" "$SPOOL/final"; then
    pass "daemon still serves a clean transfer"
else fail "daemon no longer serving"; fi

echo "== verify.log verdict lines =="
grep -qE 'verdict=ok'      "$SPOOL/verify.log" && pass "verify.log has ok verdicts" || fail "no ok in verify.log"
grep -qE 'reason=eviction' "$SPOOL/verify.log" && pass "verify.log recorded an eviction" || fail "no eviction in verify.log"

kill $RX 2>/dev/null; wait $RX 2>/dev/null
echo
if [ "$FAILS" = 0 ]; then echo ">>> STRESS TEST PASSED"; else echo ">>> $FAILS CHECK(S) FAILED"; exit 1; fi
