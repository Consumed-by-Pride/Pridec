#!/bin/bash
# --internalize: linkage follows `pub`. Checked on the objects (nm): a library exports the top level of its module, a program exports `main`,
# `pub` and `#used` items, and everything else is local (lowercase nm letter).
cd "$(dirname "$0")/../.."; export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
W=tmp/internalize; rm -rf $W; mkdir -p $W; fail=0; bad() { echo "FAIL: $*"; fail=1; }
obj() {   # file flags... -> $W/x.o.o
    PFRONT_LOW_OUT=$W/x.low.air ./pfrontc "$1" --emit-air-low --quiet >/dev/null 2>&1 || { bad "lowering $1"; return 1; }
    tmp/airtool emit-ll $W/x.low.air -o $W/x.ll --internalize >/dev/null 2>&1 || { bad "emit-ll $1"; return 1; }
    python3 scripts/ll-exe.py $W/x.ll -o $W/x.o -O0 --emit-obj --triple x86_64-unknown-linux-gnu >/dev/null 2>&1 || { bad "codegen $1"; return 1; }
}
cat > $W/prog.pie <<'PIE'
fn helper : i64 -> i64
  | x -> x + 1

pub fn api : i64 -> i64
  | x -> helper(x) * 2

#used
fn kept : i64 -> i64
  | x -> x

fn main : () -> i64
  | () -> api(1) + kept(0) - 4
PIE
obj $W/prog.pie && {
    sym() { nm $W/x.o.o | awk -v n="$1" '$3==n{print $2}'; }
    [ "$(sym main)" = T ] || bad "main is not external: $(sym main)"
    [ "$(sym api)" = T ] || bad "pub fn is not external: $(sym api)"
    [ "$(sym kept)" = T ] || bad "#used fn is not external: $(sym kept)"
    [ "$(sym helper)" = t ] || bad "helper is not local: '$(sym helper)'"
}
obj stdlib/alloc.pie && {
    [ "$(nm $W/x.o.o | awk '$3=="arena_new"{print $2}')" = T ] || bad "library: top-level arena_new is not external"
    [ "$(nm $W/x.o.o | awk '$3=="bump_alloc"{print $2}')" = T ] || bad "library: top-level bump_alloc is not external"
    nm $W/x.o.o | awk '$2=="t"{f=1} END{exit !f}' || bad "library: no callee of another module became local"
}
[ $fail = 0 ] && echo "internalize linkage: PASS"
rm -rf $W; exit $fail
