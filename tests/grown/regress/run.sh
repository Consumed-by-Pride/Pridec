#!/usr/bin/env bash
# tests/grown/regress/run.sh -- the grown regression corpus runner.
#
# Every case is a self-contained Pride program whose main() returns 0 exactly
# when the pinned behaviour held; the `-- EXIT:` line in the header records the
# expected exit status (usually 0, occasionally a documented failure code).
#
# The pipeline exercised here is the one that needs no LLVM:
#
#   pfrontc case.pie --emit-c    # front end -> LOW AIR -> C (air_c)
#   gcc case.c -o case           # the C target is plain C11
#   ./case                       # exit status is the assertion
#
# A case can fail at three distinct stages, and the runner keeps them apart:
#   FRONT  -- pfrontc reported errors (front end or lowering)
#   CC     -- gcc refused the generated C (C-target emitter bug)
#   WRONG  -- the program ran but exited with the wrong status (miscompile)
#
# Usage: bash tests/grown/regress/run.sh [case ...]   (default: all cases)
set -u
cd "$(dirname "$0")/../../.." || exit 2
BIN="${PFRONT_BIN:-./pfrontc}"
BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
GROWN=$(cd tests/grown && pwd)
W=tmp/grown-regress
rm -rf "$W"; mkdir -p "$W"

pass=0; front=0; cc=0; wrong=0
failed=""

run_one() {
    local f="$1"
    local n
    n=$(basename "$f" .pie)
    local want
    want=$(head -1 "$f" | sed 's/^-- EXIT: //')
    "$BIN_ABS" "$f" --emit-c --plain >"$W/$n.front.log" 2>&1
    local rc=$?
    if [ $rc -gt 1 ] || ! [ -f "$GROWN/regress/$n.c" ]; then
        printf '  FRONT  %-24s (pfrontc rc=%s)\n' "$n" "$rc"
        front=$((front+1)); failed="$failed $n"
        return
    fi
    if ! gcc "$GROWN/regress/$n.c" -o "$W/$n" >"$W/$n.cc.log" 2>&1; then
        printf '  CC     %-24s (gcc refused the generated C)\n' "$n"
        cc=$((cc+1)); failed="$failed $n"
        return
    fi
    "$W/$n" >"$W/$n.out" 2>&1
    local got=$?
    if [ "$got" != "$want" ]; then
        printf '  WRONG  %-24s exit=%s want=%s\n' "$n" "$got" "$want"
        wrong=$((wrong+1)); failed="$failed $n"
        return
    fi
    printf '  ok     %-24s (exit %s)\n' "$n" "$got"
    pass=$((pass+1))
}

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
    cases=(tests/grown/regress/*.pie)
fi

for f in "${cases[@]}"; do
    run_one "$f"
done

echo "---"
echo "grown regress: pass=$pass front=$front cc=$cc wrong=$wrong"
# keep the tree clean: the generated .c/.air artifacts are scratch
rm -f tests/grown/regress/*.c tests/grown/regress/*.air
if [ $((front+cc+wrong)) -gt 0 ]; then
    echo "failed:$failed"
    exit 1
fi
exit 0
