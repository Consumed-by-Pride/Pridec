#!/usr/bin/env bash
# Self-test for the pfront regression harness.
#
# The harness compares "how many diagnostics did the compiler report for this
# file" against a per-case expectation, and most cases expect ZERO. That makes
# the harness fail-open by construction: a compiler that dies produces no
# diagnostics at all, so "expected 0, got 0" scores a crash as a pass. Before
# this self-test existed, replacing ./pfrontc with a stub that always exits 139
# still produced "pass=178 fail=0 — OK".
#
# So the harness must be tested against a compiler that is deliberately broken.
# Each case below wires up a stub with one specific failure mode and asserts
# that the harness notices. Run with `bash tests/pfront/selftest.sh`.
set -u
cd "$(dirname "$0")/../.." || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

W=tmp/pfront-selftest
rm -rf "$W"; mkdir -p "$W"

# Every stub answers with a chosen exit status and no output.
stub() {
    printf '#!/bin/sh\nexit %s\n' "$1" > "$W/stub"
    chmod +x "$W/stub"
}

# run_stub STATUS -> prints the harness's own verdict line
run_stub() {
    stub "$1"
    PF_BIN="$PWD/$W/stub" bash tests/pfront/run.sh 2>&1 | sed -n 's/^pfront regression: //p'
}

# 1. A compiler killed by SIGSEGV (128+11) must not be reported healthy.
v=$(run_stub 139)
case "$v" in
    *"fail=0"*) bad "a crashing compiler (exit 139) was reported healthy: $v" ;;
    *) ok "a crashing compiler is reported as failing: $v" ;;
esac

# 2. A compiler that exits 0 but prints nothing -- e.g. a stub, a wrapper that
#    silently swallowed the real compiler, or a build of the wrong binary -- must
#    also fail: it never reached the summary line, so it never checked anything.
v=$(run_stub 0)
case "$v" in
    *"fail=0"*) bad "a silent compiler (exit 0, no output) was reported healthy: $v" ;;
    *) ok "a silent compiler is reported as failing: $v" ;;
esac

# 3. A compiler that exits with a status outside the documented set
#    (0 clean, 1 warnings, 2 errors, 3 lowering refused) did not finish.
v=$(run_stub 77)
case "$v" in
    *"fail=0"*) bad "an undocumented exit status (77) was reported healthy: $v" ;;
    *) ok "an undocumented exit status is reported as failing: $v" ;;
esac

# 4. The opposite direction: the real compiler must still pass, or the guards
#    above are just failing everything.
if [ -x ./pfrontc ]; then
    v=$(bash tests/pfront/run.sh 2>&1 | sed -n 's/^pfront regression: //p')
    case "$v" in
        *"fail=0"*) ok "the real compiler still passes ($v)" ;;
        *) bad "the real compiler now fails ($v)" ;;
    esac
else
    printf '  SKIP  ./pfrontc is not built\n'
fi

rm -rf "$W"
echo "---"
printf 'pfront harness self-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
