#!/bin/bash
# PEAR (pfrontc) execution test runner.
#
# For each tests/exec/pear/p*.pie:
#   - reads -- EXIT: N  as the expected exit code
#   - reads -- BLOCKER (XFAIL): ... markers; XFAIL cases that pass are UNXPASS
#   - compiles with pfrontc --emit-exe at PEAR_OPT (default -O2), runs, checks exit code
#
# Usage (from repo root): bash tests/exec/pear/run.sh [pfrontc path]
set -u
cd "$(dirname "$0")/../../.."
ROOT="$PWD"
PF="${1:-./pfrontc}"
PEAR_OPT=${PEAR_OPT:--O2}
TIMEOUT=${TIMEOUT:-5}
case "$PEAR_OPT" in -O0|-O1|-O2|-O3) ;; *) echo "invalid PEAR_OPT: $PEAR_OPT"; exit 2 ;; esac
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"

if [ ! -x "$PF" ]; then
    echo "pfrontc not found at $PF (build with 'make' first)"
    exit 1
fi

pass=0; fail=0; xfail=0; xpass=0
TDIR="tests/exec/pear"
# Clean stale binaries from prior runs.
find "$TDIR" -maxdepth 1 -type f -executable -not -name '*.pie' -not -name '*.sh' -not -name '*.txt' -delete 2>/dev/null
# Also clean the common case where pfrontc writes the binary next to the
# .pie WITHOUT +x (--emit-exe with warnings returns rc=1, binary still produced).
for f in "$TDIR"/p*.pie; do
    b="${f%.pie}"
    if [ -f "$b" ] && [ ! -x "$b" ]; then rm -f "$b"; fi
done

for src in "$TDIR"/p*.pie; do
    [ -f "$src" ] || continue
    name=$(basename "$src" .pie)
    expect=$(grep '^-- EXIT:' "$src" | head -1 | awk '{print $3}')
    if [ -z "$expect" ]; then
        echo "SKIP $name (no -- EXIT: marker)"
        continue
    fi
    is_xfail=0
    if grep -q 'BLOCKER (XFAIL)' "$src"; then is_xfail=1; fi
    bin="${src%.pie}"
    errlog="/tmp/pear_${name}_$$.err"
    "$PF" "$src" --emit-exe "$PEAR_OPT" --quiet >"$errlog" 2>&1
    compile_rc=$?
    # pfrontc returns 0 on clean compile, 1 if warnings only, 2+ on errors.
    if [ $compile_rc -ge 2 ] || [ ! -x "$bin" ]; then
        if [ $is_xfail -eq 1 ]; then
            echo "XFAIL $name (compile-err/no-binary, as expected)"
            xfail=$((xfail+1))
        else
            echo "FAIL $name (compile err rc=$compile_rc)"
            grep -E 'error|ERROR' "$errlog" | head -3
            fail=$((fail+1))
        fi
        continue
    fi
    timeout "$TIMEOUT" "$bin" >/dev/null 2>&1; got=$?
    rm -f "$bin" "$errlog"
    if [ "$got" = "$expect" ]; then
        if [ $is_xfail -eq 1 ]; then
            echo "UNXPASS $name (expect=$expect got=$got, was XFAIL — promote!)"
            xpass=$((xpass+1))
        else
            echo "PASS $name"
            pass=$((pass+1))
        fi
    else
        if [ $is_xfail -eq 1 ]; then
            echo "XFAIL $name (expect=$expect got=$got, as expected)"
            xfail=$((xfail+1))
        else
            echo "FAIL $name (expect=$expect got=$got)"
            fail=$((fail+1))
        fi
    fi
done

echo ""
echo "=== PEAR exec: pass=$pass fail=$fail xfail=$xfail unxpass=$xpass ==="
if [ $fail -gt 0 ] || [ $xpass -gt 0 ]; then exit 1; fi
exit 0
