#!/usr/bin/env bash
# ============================================================================
# tests/lair/gate.sh [--check] -- the LAIR slice gate (docs/pear2/LAIR.md §6).
#
#   --check    parse -> lower -> verify only: survives a machine with no LLVM
#              at all (lairc links none).
#   (default)  the above plus: emit .lair/.ll, build the .ll to an executable
#              with scripts/ll-exe.py, run it and compare the exit status,
#              then produce .bc with scripts/ll-bc.py.
#
# Exit: 0 all green, 1 otherwise. Every failure line names the fixture.
#
# Excluded on purpose: opt_while_false_main.air -- the AIR reader rejects its
# `while (false : bool)` form ("unknown operator name"), and pear2c/airtool
# reject it too; that is a reader bug outside this slice, tracked as a note in
# LAIR.md. assert_trap_main is INCLUDED (assert lowers to br+trap).
# ============================================================================
set -u
cd "$(dirname "$0")/../.."

LAIRC=${LAIRC:-./lair/lairc}
LL_EXE=${LL_EXE:-python3 scripts/ll-exe.py}
LL_BC=${LL_BC:-python3 scripts/ll-bc.py}
MODE=all
if [ "${1:-}" = "--check" ]; then MODE=check; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; fail=1; }

# libLLVM for ll-exe/ll-bc (ctypes dlopens by name). --check never needs it.
LLVM23_LIB=${LLVM23_LIB:-${LLVM23_DIR:-$HOME/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64}/lib}
if [ -d "$LLVM23_LIB" ]; then
    export LD_LIBRARY_PATH="$LLVM23_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# fixture:expected exit status of the built executable
FIXTURES="
arithmetic_main:42
bindings_main:42
integer_let_chain:44
if_compare_main:42
direct_call:42
bool_function_main:42
while_main:9
char_main:42
coerce_integer_main:0
assert_trap_main:42
label_main:42
label_arg_main:42
label_bool_main:42
label_loop_main:3
break_main:42
phi_while_carried_main:42
phi_nested_while_main:42
phi_label_ladder_main:20
phi_diamond_join_main:42
"

[ -x "$LAIRC" ] || { echo "gate: $LAIRC missing (run make lairc)"; exit 1; }

# ── 1. every slice fixture parses, lowers and verifies ──────────────────────
for fx in $FIXTURES; do
    name=${fx%%:*}
    cp "tests/pear2/$name.air" "$WORK/" || { bad "$name: no fixture"; continue; }
    if ! "$LAIRC" "$WORK/$name.air" --check >"$WORK/$name.check" 2>&1; then
        bad "$name: --check failed: $(head -1 "$WORK/$name.check")"
    fi
done

# ── 2. fail-closed: unsupported AIR fails with a source position ────────────
#      (docs/pear2/CONTRACT.md §2: exit 3 + file:line:col on stderr)
expect_rc() { # expect_rc <rc-wanted> <label> <cmd...>
    local want=$1 label=$2; shift 2
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" != "$want" ]; then
        bad "$label: exit $rc, wanted $want: $(printf '%s' "$out" | head -1)"
        return
    fi
    printf '%s' "$out" | grep -qE ':[0-9]+:[0-9]+:' || bad "$label: no source position in: $(printf '%s' "$out" | head -1)"
}
expect_rc 3 "closures (slice)"       "$LAIRC" tests/pear2/closure_scalar_capture_main.air --check
expect_rc 3 "pointer edge values"    "$LAIRC" tests/pear2/label_pointer_main.air --check
expect_rc 3 "for/arrays (slice)"     "$LAIRC" tests/pear2/phi_for_index_main.air --check
expect_rc 1 "invalid AIR (read)"     "$LAIRC" tests/air/bad/missing_semicolon.air --check

# ── 3. shape of the emitted forms (one fixture, cheap and strict) ───────────
cp tests/pear2/arithmetic_main.air "$WORK/"
if ! "$LAIRC" "$WORK/arithmetic_main.air" --emit-lair >/dev/null 2>&1; then
    bad "emit-lair failed"
else
    grep -q '^lair 0.1 ' "$WORK/arithmetic_main.lair" || bad ".lair: missing header"
    grep -q 'cut add(40' "$WORK/arithmetic_main.lair" || bad ".lair: missing cut add"
    grep -q 'ret ' "$WORK/arithmetic_main.lair" || bad ".lair: missing ret"
fi
if ! "$LAIRC" "$WORK/arithmetic_main.air" --emit-ll >/dev/null 2>&1; then
    bad "emit-ll failed"
else
    grep -q 'define i64 @main()' "$WORK/arithmetic_main.ll" || bad ".ll: missing define i64 @main"
    grep -q 'add i64 40' "$WORK/arithmetic_main.ll" || bad ".ll: missing add i64"
    grep -q 'ret i64' "$WORK/arithmetic_main.ll" || bad ".ll: missing ret i64"
fi

[ "$MODE" = check ] && { [ "$fail" = 0 ] && echo "gate --check: OK" || echo "gate --check: FAILED"; exit "$fail"; }

# ── 4. execution: .ll -> exe -> exit status, then .bc ───────────────────────
for fx in $FIXTURES; do
    name=${fx%%:*}
    want=${fx##*:}
    if ! "$LAIRC" "$WORK/$name.air" --emit-ll >/dev/null 2>"$WORK/$name.llerr"; then
        bad "$name: emit-ll: $(head -1 "$WORK/$name.llerr")"; continue
    fi
    if ! $LL_EXE "$WORK/$name.ll" -o "$WORK/$name.exe" -O1 >/dev/null 2>"$WORK/$name.exeerr"; then
        bad "$name: build: $(head -1 "$WORK/$name.exeerr")"; continue
    fi
    timeout 5 "$WORK/$name.exe" >/dev/null 2>&1
    rc=$?
    if [ "$rc" != "$want" ]; then
        bad "$name: exit $rc, wanted $want"
        continue
    fi
    if ! $LL_BC "$WORK/$name.ll" -o "$WORK/$name.bc" --quiet >/dev/null 2>"$WORK/$name.bcerr"; then
        bad "$name: bitcode: $(head -1 "$WORK/$name.bcerr")"
        continue
    fi
    [ -s "$WORK/$name.bc" ] || bad "$name: empty .bc"
done

if [ "$fail" = 0 ]; then
    echo "gate: OK ($(printf %s "$FIXTURES" | grep -c .) fixtures: check + .ll execution + .bc, negatives fail closed)"
else
    echo "gate: FAILED"
fi
exit "$fail"
