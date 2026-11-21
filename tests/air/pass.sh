#!/bin/bash
# AIR middle end: the pass driver and the first pass (air_pass.c3, air_fold.c3).
#
# Needs no LLVM: `airtool` reads and writes AIR text, and this script only asks
# whether text goes in and the right text comes out. The corpus run that proves
# the passes preserve behaviour is tests/pear2/corpus.sh (needs LLVM).
#
#   --passes=nop        must reproduce the canonical printer exactly
#   --passes=fold       must fold what is provably constant and refuse the rest
#   --passes=nop,fold   unnamed/typo'd pass must be an error, not a silent subset
set -u
cd "$(dirname "$0")/../.." || exit 1
AIRTOOL=${AIRTOOL:-tmp/airtool}
W=tmp/air-pass
rm -rf "$W"; mkdir -p "$W"
fail() { echo "FAIL: $*"; exit 1; }
[ -x "$AIRTOOL" ] || { echo "pass: cannot run -- $AIRTOOL is missing (make airtool)"; exit 2; }

# 1. The identity pipeline. `fmt` and `opt --passes=nop` must agree byte for byte;
#    if they do not, the driver is losing information before any pass runs.
"$AIRTOOL" fmt tests/air/fold_main.air -o "$W/fmt.air" || fail "fmt failed"
"$AIRTOOL" opt tests/air/fold_main.air --passes=nop -o "$W/nop.air" || fail "opt --passes=nop failed"
cmp -s "$W/fmt.air" "$W/nop.air" || { diff -u "$W/fmt.air" "$W/nop.air" | head -20; fail "--passes=nop changed the module"; }

# 2. Folding.
"$AIRTOOL" opt tests/air/fold_main.air --passes=fold -o "$W/fold.air" || fail "opt --passes=fold failed"
grep -qE '^    <5 : i64 \| %ret>;' "$W/fold.air"    || fail "2 + 3 did not fold to 5"
grep -qE '^    <40 : i64 \| %ret>;' "$W/fold.air"   || fail "(7 * 6) - 2 did not fold to 40"
grep -q '(add 2 3 : i64)' "$W/fold.air"             && fail "the folded add is still in the module"
grep -q '(mul 7 6 : i64)' "$W/fold.air"             && fail "the folded mul is still in the module"

# 3. The refusals. Each of these would be a wrong program if folded.
grep -q '(add x 100 : i8)' "$W/fold.air"  || fail "an i8 add was folded outside its range"
grep -q '(div x 0 : i64)'  "$W/fold.air"  || fail "a division by zero was folded"
grep -q '(shl x 64 : i64)' "$W/fold.air"  || fail "a shift by the full width was folded"

# 4. The identity rewrite needs no literal operand.
grep -q '(mul x 1 : i64)' "$W/fold.air" && fail "x * 1 was not rewritten to x"

# 5. Folding is a fixpoint: a second run changes nothing.
"$AIRTOOL" opt "$W/fold.air" --passes=fold -o "$W/fold2.air" || fail "second fold run failed"
cmp -s "$W/fold.air" "$W/fold2.air" || fail "folding is not idempotent"

# 6. A typo is an error. Running a subset silently is how a build "succeeds"
#    with none of its optimisations applied.
"$AIRTOOL" opt tests/air/fold_main.air --passes=fol -o "$W/typo.air" >/dev/null 2>&1
[ $? = 2 ] || fail "an unknown pass name was not rejected"

# 7. Every pass must leave a module the verifier accepts: --print-after writes
#    one file per pass, and each is checked.
mkdir -p "$W/after"
"$AIRTOOL" opt tests/air/fold_main.air --passes=fold --print-after="$W/after" -o "$W/dumped.air" || fail "opt with --print-after failed"
n=$(ls "$W/after" | wc -l)
[ "$n" -ge 1 ] || fail "--print-after wrote no files"
for f in "$W"/after/*.air; do
    "$AIRTOOL" verify "$f" >/dev/null || fail "a dumped module does not verify: $f"
done

echo "PASS: AIR pass driver (nop identity, fold, refusals, fixpoint, bad name, dumps)"
