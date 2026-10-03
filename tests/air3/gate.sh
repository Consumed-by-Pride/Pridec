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
out=$(bash tests/air3/low_corpus.sh 2>&1 | tail -1); echo "exec:   $out"
pass=$(echo "$out" | sed -n 's/.*PASS=\([0-9]*\).*/\1/p')
case "$out" in *"NOLOWER=0 VERIFY=0 LLVM=0 WRONG=0"*) ;; *) echo "FAIL: exec corpus has lowering/verify/LLVM/wrong results"; fail=1;; esac
[ "${pass:-0}" -ge "$EXEC_PASS_FLOOR" ] || { echo "FAIL: exec PASS $pass < floor $EXEC_PASS_FLOOR"; fail=1; }
out=$(bash tests/air3/stdlib_stat.sh 2>&1 | grep -E '^ +[0-9]+ OK$' | tr -s ' ' | cut -d' ' -f2); echo "stdlib: $out OK"
[ "${out:-0}" -ge "$STDLIB_OK_FLOOR" ] || { echo "FAIL: stdlib OK $out < floor $STDLIB_OK_FLOOR"; fail=1; }
[ "$fail" = 0 ] && echo "air3 lowering gate: PASS"
[ "$fail" = 0 ]
