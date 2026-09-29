#!/bin/bash
set -e
cd "$(dirname "$0")/.."

PRIDEC="./pfrontc"
GCC="gcc"
RUNS=5
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
export TIMEFORMAT='%3R'

min_time() {
  local bin="$1"
  local best=""
  for i in $(seq 1 $RUNS); do
    local t=$( { time "$bin" > /dev/null; } 2>&1 )
    if [ -z "$best" ]; then best=$t; fi
    best=$(awk -v a="$best" -v b="$t" 'BEGIN{print (a<b)?a:b}')
  done
  echo $best
}

bench() {
  local name="$1" pie="$2" c="$3"
  local pride_bin="/tmp/b_pride_$name"
  local c_bin="/tmp/b_c_$name"

  echo "── $name ──"
  $PRIDEC "$pie" --emit-exe 2>&1 | tail -2
  mv "${pie%.pie}" "$pride_bin"
  $GCC -O2 "$c" -o "$c_bin"
  local tp=$(min_time "$pride_bin")
  local tc=$(min_time "$c_bin")
  local ratio=$(awk -v a="$tp" -v b="$tc" 'BEGIN{printf "%.2f", a/b}')
  local pct=$(awk -v a="$tp" -v b="$tc" 'BEGIN{printf "%+.1f", (a-b)/b*100}')
  echo "  PEAR  : ${tp}s"
  echo "  gcc-O2: ${tc}s"
  echo "  ratio : ${ratio}x   (${pct}%)"
  echo ""
}

bench fib     bench/fib.pie     bench/fib.c
bench sum_to  bench/sum_to.pie  bench/sum_to.c
bench tak     bench/tak.pie     bench/tak.c
