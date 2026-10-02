#!/bin/bash
# Verify the single-clause pointer-binding regression across every PEAR tier.
set -u
cd "$(dirname "$0")/../../.."
PF="${1:-scripts/pie-exe.sh}"   # chain: pfrontc -> .air -> legacy pear1c
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
SRC="tests/exec/pear/p112_clause_binding_pointer.pie"
BIN="${SRC%.pie}"

for opt in -O0 -O1 -O2 -O3; do
    log="/tmp/pear_p112_${opt#-}.err"
    rm -f "$BIN"
    "$PF" "$SRC" --emit-exe "$opt" --quiet >"$log" 2>&1
    compile_rc=$?
    if [ "$compile_rc" -ge 2 ] || [ ! -x "$BIN" ]; then
        echo "FAIL p112 $opt (compile rc=$compile_rc or no executable)"
        grep -E 'error|ERROR|LLVM ERROR' "$log" | head -5 || true
        rm -f "$BIN" "$log"
        exit 1
    fi
    "$BIN" >/dev/null 2>&1
    got=$?
    rm -f "$BIN" "$log"
    if [ "$got" -ne 37 ]; then
        echo "FAIL p112 $opt (expected exit 37, got $got)"
        exit 1
    fi
    echo "PASS p112 $opt (exit 37)"
done
exit 0
