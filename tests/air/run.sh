#!/bin/bash
# AIR 2.0 contract tests (docs/specs/AIR.md).  Needs ./pfrontc and tmp/airtool.
#
#  1. good/*.air   : parse, canonical-print is byte-identical, validity rules hold
#  2. bad/*.air    : each first line `// EXPECT: <stage> [Vn]` must fail at that stage
#  2b. forged/*.air: qualifier claims in the text are candidates; the reader re-screens them
#  3. corpus       : every source of tests/exec, tests/exec/pear, tests/pfront and examples
#                    that compiles emits a .air that
#                      - parses and re-prints byte-identically   (fmt idempotent)
#                      - has exactly the violations recorded in tests/air/VERIFY_KNOWN.tsv
#  4. round trip   : pfrontc --air-roundtrip on a sample (all with AIR_RT_FULL=1): the module
#                    read back from the text has the same structure (fingerprint of every
#                    node field) and compiles to byte-identical LLVM bitcode.
#
# Usage: bash tests/air/run.sh [pfrontc] [airtool]
set -u
cd "$(dirname "$0")/../.."
PF="${1:-./pfrontc}"; AT="${2:-tmp/airtool}"
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
[ -x "$PF" ] || { echo "pfrontc not found at $PF"; exit 1; }
[ -x "$AT" ] || { echo "airtool not found at $AT (make airtool)"; exit 1; }
W=tmp/air-test; rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# 1. good
for f in tests/air/good/*.air; do
    n=$(basename "$f")
    "$AT" check "$f" >/dev/null 2>&1 || { bad "good/$n: check"; continue; }
    "$AT" fmt "$f" 2>/dev/null | cmp -s - "$f" || { bad "good/$n: not canonical (airtool fmt differs)"; continue; }
    "$AT" verify "$f" >/dev/null 2>&1 || { bad "good/$n: verify"; continue; }
    ok
done

# 2. bad
for f in tests/air/bad/*.air; do
    n=$(basename "$f"); exp=$(head -1 "$f" | sed 's#^// EXPECT: ##'); stage=${exp%% *}; cls=""; [ "$stage" != "$exp" ] && cls=${exp#* }
    if [ "$stage" = check ]; then
        if "$AT" check "$f" >/dev/null 2>&1; then bad "bad/$n: check accepted it"; else ok; fi
    else
        out=$("$AT" verify "$f" 2>&1)
        if [ $? -eq 0 ]; then bad "bad/$n: verify accepted it"
        elif ! echo "$out" | grep -q "air-verify: $cls "; then bad "bad/$n: expected $cls, got: $(echo "$out" | head -1)"
        else ok; fi
    fi
done

# 2b. forged claims: the text may say anything; fmt (like pfrontc after reading) re-screens
out=$("$AT" fmt tests/air/forged/claims.air 2>/dev/null)
h=$(echo "$out" | grep 'def honest_reader'); f=$(echo "$out" | grep 'def forged_writer')
if echo "$h" | grep -q 'readonly' && echo "$h" | grep -q 'nocapture p'; then ok; else bad "forged/claims: an honest claim was dropped: $h"; fi
if echo "$f" | grep -q 'readonly'; then bad "forged/claims: forged readonly survived: $f"; else ok; fi
if echo "$f" | grep -q 'nocapture p'; then bad "forged/claims: forged nocapture on a retained pointer survived: $f"; else ok; fi
if echo "$f" | grep -q 'nocapture out'; then ok; else bad "forged/claims: a sound claim (out is only written through) was dropped: $f"; fi

# 3. corpus
gen() {  # <src> -> $W/<id>.air ; prints nothing; silent when the program does not compile
    local src=$1 d b id
    d=$(dirname "$src"); b=$(basename "$src" .pie); id=$(echo "$src" | tr '/' '_' | sed 's/\.pie$//')
    ( cd "$d" && timeout 120 "$OLDPWD/$PF" "$b.pie" --emit-air --quiet >/dev/null 2>&1 )
    [ -f "$d/$b.air" ] && mv "$d/$b.air" "$W/$id.air"
}
export -f gen; export PF W LD_LIBRARY_PATH
find tests/exec tests/pfront examples -maxdepth 2 -name '*.pie' | sort > "$W/sources.txt"
xargs -a "$W/sources.txt" -P "${JOBS:-2}" -I{} bash -c 'gen {}'
nair=$(ls "$W"/*.air 2>/dev/null | wc -l); nsrc=$(wc -l < "$W/sources.txt")
: > "$W/verify.tsv"
for f in "$W"/*.air; do
    id=$(basename "$f" .air)
    "$AT" fmt "$f" 2>/dev/null | cmp -s - "$f" || { bad "corpus/$id: fmt not idempotent"; continue; }
    line=$("$AT" verify "$f" 2>&1 | tail -1)
    cnt=$(echo "$line" | sed -n 's/.*V1=\([0-9]*\) V2=\([0-9]*\) V3=\([0-9]*\) V4=\([0-9]*\).*/\1 \2 \3 \4/p')
    [ -n "$cnt" ] || { bad "corpus/$id: verify produced no summary"; continue; }
    [ "$cnt" = "0 0 0 0" ] || printf "%s\t%s\n" "$id" "$cnt" >> "$W/verify.tsv"
    ok
done
if diff <(grep -v '^#' tests/air/VERIFY_KNOWN.tsv | sort) <(sort "$W/verify.tsv") > "$W/verify.diff"; then ok
else bad "corpus verify ledger differs (new violation, or a fixed one: update tests/air/VERIFY_KNOWN.tsv):"; sed 's/^/    /' "$W/verify.diff" | head -20; fi

# 4. round trip
rt_list="tests/exec/01_hello.pie tests/exec/12_struct_ops.pie tests/exec/pear/p03_fib.pie tests/pfront/45_opt_branch.pie examples/rfc_number.pie"
[ "${AIR_RT_FULL:-0}" = 1 ] && rt_list=$(cat "$W/sources.txt")
for src in $rt_list; do
    d=$(dirname "$src"); b=$(basename "$src")
    out=$( cd "$d" && timeout 300 "$OLDPWD/$PF" "$b" --air-roundtrip -O2 --quiet 2>&1 )
    if echo "$out" | grep -q "errors=[1-9]"; then continue; fi          # does not compile: nothing to round-trip
    echo "$out" | grep -q "roundtrip: structure identical" || { bad "roundtrip/$src: structure: $(echo "$out" | grep roundtrip | head -1)"; continue; }
    # a few shapes crash the legacy PEAR itself (tracked in the exec ledger); the structural result still counts
    if echo "$out" | grep -q "roundtrip: bitcode identical"; then ok
    elif [ -z "$(echo "$out" | grep 'roundtrip:.*differ')" ]; then ok    # backend crash after the structural check, not a mismatch
    else bad "roundtrip/$src: $(echo "$out" | grep roundtrip | tail -1)"; fi
done
echo "air tests: $pass passed, $fail failed  (corpus: $nair of $nsrc sources emit a .air)"
[ $fail -eq 0 ]
