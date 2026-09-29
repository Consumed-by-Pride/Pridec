#!/bin/bash
# Usage: bash bench/run.sh
# Runs the three benchmarks. PEAR via --emit-bc and gcc for .c; for sum_to we can
# use --emit-exe, but recursive programs crash in LLVM 19 codegen (DwarfEHPrepare).
# Until llvm-23 is installed, we only measure sum_to natively; fib/tak are measured
# by counting LLVM IR instruction count (a proxy for code quality).
set -e
cd "$(dirname "$0")/.."
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu

echo "=== PEAR v0.6 λ̄μμ̃-adaptor benchmark (gcc -O2 baseline) ==="

# sum_to: native
./pfrontc bench/sum_to.pie --emit-exe 2>/dev/null
gcc-14 -O2 bench/sum_to.c -o bench/sum_gcc

best_pear=100; best_gcc=100
for i in 1 2 3 4 5; do
  t=$({ time bench/sum_to >/dev/null; } 2>&1 | grep real | awk '{print $2}')
  s=$(echo $t | awk -Fm '{print $1*60 + $2}')
  best_pear=$(awk -v a=$best_pear -v b=$s 'BEGIN{print (a<b)?a:b}')
  t=$({ time bench/sum_gcc >/dev/null; } 2>&1 | grep real | awk '{print $2}')
  s=$(echo $t | awk -Fm '{print $1*60 + $2}')
  best_gcc=$(awk -v a=$best_gcc -v b=$s 'BEGIN{print (a<b)?a:b}')
done
echo "sum_to (2M iters): PEAR=${best_pear}s  gcc-O2=${best_gcc}s"

# Count LLVM IR instructions for fib/tak (proxy for code density after opts):
for t in fib tak; do
  ./pfrontc bench/$t.pie --emit-bc 2>/dev/null
  gcc-14 -O2 -S bench/$t.c -o /tmp/$t.s
  # Count instructions in .s file (gcc output):
  gcc_instrs=$(grep -cE "^\s+" /tmp/$t.s)
  # For PEAR .bc we don't have llvm-dis; count file size as proxy.
  pear_size=$(stat -c%s bench/$t.bc)
  echo "$t: gcc asm=${gcc_instrs} instr lines; pear .bc=${pear_size} bytes"
done
