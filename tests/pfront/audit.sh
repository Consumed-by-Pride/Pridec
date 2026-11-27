#!/usr/bin/env bash
# Lowering-coverage audit: does every source construct reach the .air?
#
# The live lowerer (air_low) marks each PNode it consumes when --air-audit is on.
# This runner compiles every fixture with the audit enabled and reports, per file,
# how many semantic constructs were examined and how many were never looked at.
#
# "Unlowered" is not automatically a bug: a declaration nothing calls is not part
# of the program, so its body is never lowered. The number that matters is the
# one on files that LOWERED -- those produced a .air, and any unlowered node in
# them is either dead code (after `ub!`), a name consumed outside expr() (a
# marker gap in the audit itself), or a genuine drop.
#
# Known-good results are recorded in LOWERING_BASELINE.tsv; `--update` rewrites it.
# A file whose unlowered count goes UP without that file changing is a regression.
#
# Usage: tests/pfront/audit.sh [--update] [--verbose]
set -u
cd "$(dirname "$0")/../.." || exit 1
BIN=./pfrontc
[ -x "$BIN" ] || { echo "build ./pfront first"; exit 2; }

BASE=tests/pfront/LOWERING_BASELINE.tsv
W=tmp/pfront-audit
rm -rf "$W"; mkdir -p "$W"
update=0; verbose=0
for a in "$@"; do
    case "$a" in
        --update) update=1 ;;
        --verbose) verbose=1 ;;
    esac
done

examined_total=0; unlowered_total=0; files=0; clean=0
: > "$W/now.tsv"
for f in tests/pfront/*.pie; do
    name=$(basename "$f" .pie)
    out=$(timeout 120 "$BIN" "$f" --emit-air-low --air-audit --quiet 2>&1)
    e=$(printf '%s' "$out" | grep -oE "examined=[0-9]+" | head -1 | cut -d= -f2)
    u=$(printf '%s' "$out" | grep -oE "unlowered=[0-9]+" | head -1 | cut -d= -f2)
    [ -n "$e" ] || continue            # did not reach the lowerer
    lowered=0
    printf '%s' "$out" | grep -q "function(s) lowered" && lowered=1
    files=$((files+1))
    examined_total=$((examined_total + e))
    unlowered_total=$((unlowered_total + u))
    [ "$u" = "0" ] && clean=$((clean+1))
    printf '%s\t%s\t%s\t%s\n' "$name" "$e" "$u" "$lowered" >> "$W/now.tsv"
    if [ "$verbose" = "1" ] && [ "$u" != "0" ] && [ "$lowered" = "1" ]; then
        printf '%s\n' "$out" | grep "UNLOWERED" | sed "s/^/  $name: /"
    fi
done

echo "lowering audit: $files files, $examined_total constructs examined, $unlowered_total never lowered, $clean clean"

# On files that produced a .air, report what is still unlowered -- that is the
# number a reader should judge, because those files are supposed to be complete.
printf '%s\n' "--- unlowered nodes in files that DID lower:"
awk -F'\t' '$4==1 && $3>0 {printf "  %-28s %s\n", $1, $3}' "$W/now.tsv" | sort

if [ "$update" = "1" ]; then
    cp "$W/now.tsv" "$BASE"
    echo "updated $BASE"
    exit 0
fi

if [ ! -f "$BASE" ]; then
    echo "no baseline yet; run with --update to record one"
    exit 0
fi

# Compare only the files present in both, and only in the direction that matters:
# more unlowered nodes than recorded is a regression.
bad=0
while IFS=$'\t' read -r name e u lowered; do
    was=$(awk -F'\t' -v n="$name" '$1==n {print $3}' "$BASE")
    [ -n "$was" ] || continue
    if [ "$u" -gt "$was" ]; then
        printf 'FAIL %s: unlowered went from %s to %s\n' "$name" "$was" "$u"
        bad=$((bad+1))
    fi
done < "$W/now.tsv"

if [ "$bad" -eq 0 ]; then echo "lowering audit: PASS (no file got worse)"; else echo "lowering audit: FAIL ($bad files worse)"; fi
[ "$bad" -eq 0 ]
