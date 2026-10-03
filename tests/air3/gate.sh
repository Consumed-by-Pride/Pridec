#!/bin/bash
# Regression gate for the AIR 3.0 lowering (pfrontc --emit-air-low -> verify-low -> LLVM -> run).
#   1. tests/air3/prog/*.pie   : every program must PASS
#   2. tests/exec corpus       : no VERIFY / LLVM / WRONG / NOLOWER, and PASS must not drop below the recorded floor
#   3. stdlib library sweep    : OK count must not drop below the recorded floor (and no VERIFY/LLVM failures)
# Floors only go up (tests/air3/GATE_FLOORS).
set -u
cd "$(dirname "$0")/../.."
. tests/air3/GATE_FLOORS
fail=0
out=$(bash tests/air3/low_corpus.sh tests/air3/prog/*.pie 2>&1 | tail -1); echo "prog:   $out"
case "$out" in *"FRONT=0 NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: air3 prog programs"; fail=1;; esac
# x86-64 only programs (inline asm): native run, on an x86-64 host
if [ "$(uname -m)" = x86_64 ]; then
    out=$(bash tests/air3/low_corpus.sh tests/air3/prog_x86/*.pie 2>&1 | tail -1); echo "x86:    $out"
    case "$out" in *"FRONT=0 NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: air3 x86 programs"; fail=1;; esac
fi
# the same .air, built for wasm32-wasi (LLVM wasm backend + zig's wasm-ld/wasi-libc + runtime/wasi/pride_rt.c) and RUN under wasmtime
export PATH="$PATH:$HOME/.local/bin"
if python3 -c "import ziglang, wasmtime" 2>/dev/null; then
    out=$(bash tests/air3/low_corpus.sh --wasm tests/air3/prog/*.pie 2>&1 | tail -1); echo "wasm prog: $out"
    case "$out" in *"FRONT=0 NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: wasm32 prog programs"; fail=1;; esac
    out=$(bash tests/air3/low_corpus.sh --wasm 2>&1 | tail -1); echo "wasm exec: $out"
    wpass=$(echo "$out" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
    case "$out" in *"NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: wasm32 exec corpus"; fail=1;; esac
    [ "${wpass:-0}" -ge "$WASM_EXEC_PASS_FLOOR" ] || { echo "FAIL: wasm exec PASS $wpass < floor $WASM_EXEC_PASS_FLOOR"; fail=1; }
else
    echo "wasm: SKIPPED (pip install --user ziglang wasmtime to enable the wasm32-wasi run)"
fi
out=$(bash tests/air3/low_corpus.sh 2>&1 | tail -1); echo "exec:   $out"
pass=$(echo "$out" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
case "$out" in *"NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: exec corpus has lowering/verify/LLVM/wrong results"; fail=1;; esac
[ "${pass:-0}" -ge "$EXEC_PASS_FLOOR" ] || { echo "FAIL: exec PASS $pass < floor $EXEC_PASS_FLOOR"; fail=1; }
out=$(bash tests/air3/stdlib_stat.sh 2>&1 | grep -E '^ +[0-9]+ OK$' | tr -s ' ' | cut -d' ' -f2); echo "stdlib: $out OK"
[ "${out:-0}" -ge "$STDLIB_OK_FLOOR" ] || { echo "FAIL: stdlib OK $out < floor $STDLIB_OK_FLOOR"; fail=1; }
[ "$fail" = 0 ] && echo "air3 lowering gate: PASS"
[ "$fail" = 0 ]
