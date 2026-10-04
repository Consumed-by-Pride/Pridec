#!/bin/bash
# `syscall` lowers to the target's own instruction (emit-ll --syscall=...): the objects must contain that encoding
cd "$(dirname "$0")/../.."; export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
W=tmp/syscall-arch; rm -rf $W; mkdir -p $W; fail=0
F=tests/air3/prog_fs/fs01_start.pie
PFRONT_LOW_OUT=$W/fs.low.air ./pfrontc $F --emit-air-low >/dev/null 2>&1 || { echo "FAIL: lowering"; exit 1; }
while IFS=: read name triple sc pat; do
    tmp/airtool emit-ll $W/fs.low.air -o $W/$name.ll --target=$triple --syscall=$sc >/dev/null 2>&1 &&
    python3 scripts/ll-exe.py $W/$name.ll -o $W/$name --emit-obj >/dev/null 2>&1
    python3 - "$W/$name.o" "$pat" <<'PY' || { echo "FAIL: $name has no syscall instruction"; fail=1; }
import sys
d = open(sys.argv[1], "rb").read()
sys.exit(0 if bytes.fromhex(sys.argv[2]) in d else 1)
PY
done <<'LIST'
x86_64:x86_64-unknown-linux-gnu:x86_64-linux:0f05
i386:i686-unknown-linux-gnu:i386-linux:cd80
aarch64:aarch64-unknown-linux-gnu:aarch64-linux:010000d4
riscv64:riscv64-unknown-linux-gnu:riscv64-linux:73000000
LIST
[ $fail = 0 ] && echo "syscall per target (x86_64 i386 aarch64 riscv64): PASS"
rm -rf $W; exit $fail
