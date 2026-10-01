#!/bin/bash
# bench/run.sh — PEAR vs GCC -O2 benchmark harness. Run from project root:
#     cd <repo> && bash bench/run.sh
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu
PFRONTC=./pfrontc
BD=bench

time_min() {
    local prog="$1"
    local best=999999
    for i in 1 2 3 4 5; do
        local t
        # /usr/bin/time is not available in every sandbox (this one has neither
        # `time` nor `bc`); fall back to wall-clock arithmetic with date + awk so
        # the benchmark still reports a number instead of "n/a".
        if [ -x /usr/bin/time ]; then
            t=$({ /usr/bin/time -f '%e' "$prog" >/dev/null; } 2>&1 | tail -1)
        else
            t_ns_start=$(date +%s%N)
            "$prog" >/dev/null
            t_ns_end=$(date +%s%N)
            t=$(awk -v a="$t_ns_start" -v b="$t_ns_end" 'BEGIN { printf "%.3f", (b - a) / 1000000000 }')
        fi
        local cmp
        cmp=$(awk -v a="$t" -v b="$best" 'BEGIN{print (a+0 < b+0)?1:0}')
        if [ "$cmp" = "1" ]; then best="$t"; fi
    done
    echo "$best"
}

bench_one() {
    local stem="$1"
    echo "=== $stem ==="
    $PFRONTC "$BD/$stem.pie" --emit-exe >/tmp/pear_bench.log 2>&1
    if [ ! -x "$BD/$stem" ]; then
        echo "  PEAR: compile FAIL"; tail -5 /tmp/pear_bench.log; return
    fi
    local pt; pt=$(time_min "$BD/$stem")
    local psz; psz=$(stat -c%s "$BD/$stem" 2>/dev/null || echo 0)
    local gt; gt=$(time_min "$BD/${stem}_c")
    local gsz; gsz=$(stat -c%s "$BD/${stem}_c")
    local ratio
    ratio=$(awk -v p="$pt" -v g="$gt" 'BEGIN{ if(g+0>0) printf("%.2fx", p/g); else print "n/a"}')
    printf "  PEAR : %ss  (%d bytes)\n" "$pt" "$psz"
    printf "  GCC  : %ss  (%d bytes)\n" "$gt" "$gsz"
    printf "  ratio: %s  vs gcc-14 -O2\n" "$ratio"
}

if [ ! -x "$PFRONTC" ]; then
    echo "pfrontc not built."; exit 1
fi

for s in sum_to fib tak; do
    if [ ! -x "$BD/${s}_c" ]; then
        gcc-14 -O2 "$BD/$s.c" -o "$BD/${s}_c"
    fi
done

bench_one sum_to
