#!/usr/bin/env bash
# Full verification: build, SPARK proof (must be 0 unproved), and every
# functional test (in-memory matrix, end-to-end receiver, loopback sink).
# Exits non-zero on the first failure.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/env.sh"
cd "$here/.."

step () { printf '\n=== %s ===\n' "$1"; }

step "build"
gprbuild -q -P lt_diode.gpr
echo "ok"

step "SPARK proof (expect 0 unproved)"
gnatprove -P lt_diode.gpr -j0 --report=all > /tmp/lt_prove.$$ 2>&1 || true
if grep -qiE '(medium|high):' /tmp/lt_prove.$$; then
    echo "FAIL: unproved checks:"; grep -iE '(medium|high):' /tmp/lt_prove.$$
    rm -f /tmp/lt_prove.$$; exit 1
fi
grep -E '^Total' obj/gnatprove/gnatprove.out
rm -f /tmp/lt_prove.$$
echo "ok: all checks proved"

step "in-memory codec matrix"
./bin/test_codec | tail -1 | grep -q 'ALL TRIALS PASS' && echo "ok" || { echo FAIL; exit 1; }

step "end-to-end receiver (file / pipe / parallel)"
./tools/receiver-test.sh 20000000 9960 314 | grep -q 'RESULT: PASS' && echo "ok" || { echo FAIL; exit 1; }

step "loopback decode sink"
./tools/loopback-test.sh 12000000 9965 271 0 | grep -q 'RESULT: PASS' && echo "ok" || { echo FAIL; exit 1; }

printf '\n>>> ALL CHECKS PASSED\n'
