#!/bin/bash
# AIR lowering regression table (tests/lowering/*.pie, one feature per file).
#
# For every program:
#   1. pfrontc --emit-air --air-audit : no source construct of the ENTRY module is left unlowered
#   2. airtool verify                 : validity counts V1..V4 equal the ones recorded in KNOWN.tsv (default 0 0 0 0)
#   3. pie-exe.sh (pfrontc -> .air -> pear1c) -O0 : the native exit code equals the `-- EXIT: N` header,
#                                                  or, for a KNOWN.tsv case, exactly the recorded wrong code
# A case in KNOWN.tsv that now passes fails the run ("remove it"): the table is exact in both directions.
#
# Usage: bash tests/lowering/run.sh [pfrontc]
set -u
cd "$(dirname "$0")/../.."
PF="${1:-./pfrontc}"; AT=tmp/airtool
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu}"
[ -x "$PF" ] || { echo "pfrontc not found at $PF"; exit 1; }
[ -x "$AT" ] || { echo "airtool not found (make airtool)"; exit 1; }
W=tmp/lowering-test; rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0; known=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
for f in tests/lowering/*.pie; do
    n=$(basename "$f" .pie); cp "$f" "$W/$n.pie"
    row=$(grep -v '^#' tests/lowering/KNOWN.tsv | awk -F'\t' -v c="$n" '$1==c')
    k_rc=$(echo "$row" | cut -f2); k_v=$(echo "$row" | cut -f3); [ -z "$k_v" ] && k_v="0 0 0 0"
    exp=$(grep -m1 -o 'EXIT: *[0-9]*' "$f" | grep -o '[0-9]*$')
    "$PF" "$W/$n.pie" --emit-air --air-audit --quiet > "$W/$n.log" 2>&1
    unl=$(grep -c UNLOWERED "$W/$n.log")
    [ "$unl" = 0 ] || { bad "$n: $unl source constructs not lowered"; continue; }
    if [ -f "$W/$n.air" ]; then
        v=$("$AT" verify "$W/$n.air" 2>&1 | grep -o 'V1=[0-9]* V2=[0-9]* V3=[0-9]* V4=[0-9]*' | sed 's/V[1-4]=//g')
        [ "$v" = "$k_v" ] || { bad "$n: verify counts '$v', recorded '$k_v'"; continue; }
    elif [ "$k_rc" != NOBIN ]; then bad "$n: no .air emitted"; continue; fi
    bash scripts/pie-exe.sh "$W/$n.pie" -O0 >/dev/null 2>&1
    if [ -x "$W/$n" ]; then rc=$(bash -c 'timeout 5 "$1" >/dev/null 2>&1; echo $?' _ "$W/$n" 2>/dev/null); else rc=NOBIN; fi
    if [ -n "$row" ]; then
        if [ "$rc" = "$exp" ]; then bad "$n: now exits $rc as expected -- remove it from KNOWN.tsv"
        elif [ "$rc" = "$k_rc" ]; then known=$((known+1)); ok
        else bad "$n: exit $rc, recorded known $k_rc"; fi
    else
        if [ "$rc" = "$exp" ]; then ok; else bad "$n: exit $rc, expected $exp"; fi
    fi
done
echo "lowering table: $pass ok ($known known-failing, recorded exactly), $fail failed  ($(ls tests/lowering/*.pie | wc -l) programs)"
[ "$fail" = 0 ]
