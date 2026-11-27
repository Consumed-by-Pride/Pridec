#!/usr/bin/env bash
# ============================================================================
# tests/lair/bc-ab.sh -- LAIR bitcode A/B against pear2c (docs/pear2/LAIR.md §6
# step 3).
#
# For every slice fixture:
#   * lairc  --emit-ll -> scripts/ll-bc.py  -> lair.bc
#   * pear2c --emit-bc -O0                  -> pear.bc
# then, for each side: clang <x>.bc -> exe -> run -> exit status.
#
# The comparison is *behavioral* first (exit status, signal-adjusted so a trap
# counts as 134 on both sides). Byte-identity is reported only where it holds;
# the two emitters are different code paths, so differing bytes are expected
# and are not a failure.
#
# pear2c is driven at -O0 because lairc emits unoptimized IR: that is the only
# level where the two are semantically comparable. (At -O2 pear2c's pipeline
# folds some phi fixtures to a constant -- see LAIR.md.)
#
# Exit: 0 if every fixture's behavior matches, 1 otherwise.
# ============================================================================
set -u
cd "$(dirname "$0")/../.."

LAIRC=${LAIRC:-./lair/lairc}
PEAR2C=${PEAR2C:-./pear2/pear2c}
LL_BC=${LL_BC:-python3 scripts/ll-bc.py}

LLVM_DIR=${LLVM23_DIR:-$HOME/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64}
export LD_LIBRARY_PATH="$LLVM_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$LLVM_DIR/bin:$PATH"

# fixture:expected exit status (same table as gate.sh)
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

[ -x "$LAIRC" ]  || { echo "bc-ab: $LAIRC missing (run make lairc)";  exit 1; }
[ -x "$PEAR2C" ] || { echo "bc-ab: $PEAR2C missing (run make pear2c)"; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "bc-ab: clang not found under $LLVM_DIR/bin"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0
same_bytes=0
behave=0

# signal-adjusted exit status: a process killed by signal s reports 128+s so a
# trap (assert_trap_main) compares as 134 on both sides.
run_status() { # run_status <exe>
    local rc
    timeout 5 "$1" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -gt 128 ]; then :; else rc=$rc; fi
    printf '%d' "$rc"
}

for fx in $FIXTURES; do
    name=${fx%%:*}
    want=${fx##*:}
    cp "tests/pear2/$name.air" "$WORK/" || { echo "bc-ab: $name: no fixture"; fail=1; continue; }

    # ---- lairc side: .air -> .ll -> .bc ----
    if ! "$LAIRC" "$WORK/$name.air" --emit-ll >/dev/null 2>"$WORK/$name.llerr"; then
        echo "bc-ab: $name: lairc --emit-ll: $(head -1 "$WORK/$name.llerr")"; fail=1; continue
    fi
    if ! $LL_BC "$WORK/$name.ll" -o "$WORK/lair.bc" --quiet >/dev/null 2>"$WORK/$name.bcerr"; then
        echo "bc-ab: $name: ll-bc: $(head -1 "$WORK/$name.bcerr")"; fail=1; continue
    fi

    # ---- pear2c side: .air -> .bc (-O0) ----
    if ! "$PEAR2C" "$WORK/$name.air" --emit-bc -O0 >/dev/null 2>"$WORK/$name.pearerr"; then
        echo "bc-ab: $name: pear2c --emit-bc: $(head -1 "$WORK/$name.pearerr")"; fail=1; continue
    fi
    cp "$WORK/$name.bc" "$WORK/pear.bc"

    # ---- build + run both ----
    if ! clang "$WORK/lair.bc" -o "$WORK/lair.exe" >/dev/null 2>&1; then
        echo "bc-ab: $name: clang lair.bc failed"; fail=1; continue
    fi
    if ! clang "$WORK/pear.bc" -o "$WORK/pear.exe" >/dev/null 2>&1; then
        echo "bc-ab: $name: clang pear.bc failed"; fail=1; continue
    fi
    ls_lair=$(run_status "$WORK/lair.exe")
    ls_pear=$(run_status "$WORK/pear.exe")

    if [ "$ls_lair" != "$ls_pear" ]; then
        echo "bc-ab: $name: BEHAVIOR MISMATCH lair=$ls_lair pear=$ls_pear (want $want)"; fail=1
    else
        behave=$((behave + 1))
        if [ "$ls_lair" != "$want" ]; then
            echo "bc-ab: $name: both exit $ls_lair, want $want (shared expectation)"; fail=1
        fi
    fi

    if cmp -s "$WORK/lair.bc" "$WORK/pear.bc"; then
        same_bytes=$((same_bytes + 1))
    fi
done

total=$(printf %s "$FIXTURES" | grep -c .)
if [ "$fail" = 0 ]; then
    echo "bc-ab: OK ($behave/$total behavior-matched, $same_bytes/$total byte-identical at -O0)"
else
    echo "bc-ab: FAILED"
fi
exit "$fail"
