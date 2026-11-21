#!/usr/bin/env bash
# Hardening tests for the pfront compiler: failure paths that must produce a
# diagnostic instead of a crash, a silent success, or a truncated program.
#
# Each test drives a real failure through the real binary. None of them needs a
# large input or a machine with little memory: AIR_TEST_SLABS lowers the AIR
# arena ceiling so exhaustion happens in milliseconds on a small file.
#
# Run with `bash tests/pfront/hardening.sh` (needs ./pfrontc built).
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=./pfrontc
[ -x "$BIN" ] || { echo "build ./pfront first"; exit 2; }

W=tmp/pfront-hardening
rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

# 200 small functions: enough nodes to overflow one 1 MiB slab, small enough
# that a correct run finishes instantly and writes a .air.
big="$W/many.pie"
: > "$big"
for i in $(seq 1 200); do printf 'fn f%s : i64 -> i64\n  | x -> x + %s\n' "$i" "$i" >> "$big"; done

# ── 1. Arena exhaustion is a diagnostic, not a crash ──────────────────────────
# The arena is 256 slabs of 1 MiB and every allocator returns null once it is
# exhausted. Call sites write into the result immediately, so the compiler used
# to segfault (exit 139) instead of reporting anything.
for n in 1 2; do
    rm -f "$W/many.low.air"
    out=$(AIR_TEST_SLABS=$n timeout 120 "$BIN" "$big" --emit-air-low --quiet 2>&1); rc=$?
    if [ "$rc" -ge 128 ]; then
        bad "arena exhaustion at ${n} slab(s) crashed the compiler (rc=$rc)"
    elif [ "$rc" -eq 0 ]; then
        bad "arena exhaustion at ${n} slab(s) reported success"
    elif [ -f "$W/many.low.air" ]; then
        bad "arena exhaustion at ${n} slab(s) still wrote a .air from a truncated tree"
    elif ! printf '%s' "$out" | grep -q "exhausted"; then
        bad "arena exhaustion at ${n} slab(s) gave no explanation: $out"
    else
        ok "arena exhaustion at ${n} slab(s) is diagnosed and writes nothing"
    fi
done

# The same input with a normal ceiling must still compile: the test above only
# means something if the program is otherwise valid.
rm -f "$W/many.low.air"
if timeout 120 "$BIN" "$big" --emit-air-low --quiet >/dev/null 2>&1 && [ -f "$W/many.low.air" ]; then
    ok "the same input lowers cleanly with the normal arena ceiling"
else
    bad "the input used for the exhaustion test does not lower at all"
fi

# ── 2. A lowering failure is reported as an error, not a warning ──────────────
# The lowerer counts its own errors (`lw.errors`) and prints them; the summary
# line used to be derived only from the DiagBag, which never saw them, so a
# refused file summarized as "errors: 0". A harness reading the summary called
# that a pass.
arms="$W/arms.pie"
{ echo 'fn pick : i64 -> i64'
  for i in $(seq 1 300); do printf '  | %s -> %s\n' "$i" "$i"; done; } > "$arms"
out=$("$BIN" "$arms" --emit-air-low --quiet 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
    bad "a file the lowerer refused exited 0"
elif ! printf '%s' "$out" | grep -qE "errors=[1-9]"; then
    bad "a refused file summarized as zero errors: $(printf '%s' "$out" | tail -1)"
else
    ok "a refused lowering shows a non-zero error count in the summary"
fi

# ── 3. Compiler failures are not silently counted as clean ───────────────────
# Covered in depth by tests/pfront/selftest.sh; this is the single check that the
# harness hooks are present, so a future edit to run.sh cannot quietly drop them.
if grep -q 'crashed?' tests/pfront/run.sh && grep -q 'did not finish' tests/pfront/run.sh; then
    ok "the regression harness still checks exit status and the summary line"
else
    bad "tests/pfront/run.sh lost its crash detection"
fi

rm -rf "$W"
echo "---"
printf 'pfront hardening: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
