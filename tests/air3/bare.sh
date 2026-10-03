#!/bin/bash
# Bare-metal check: tests/air3/prog_bare/kernel.pie -> AIR 3 -> LLVM (x86_64-unknown-none-elf, kernel code model, no SSE) -> ld with kernel.ld.
# Not run (it needs a machine), so the image is inspected instead: entry point, section placement, no undefined symbol (no libc, no crt),
# packed + aligned GDT bytes, no SSE register in the code.
set -u
cd "$(dirname "$0")/../.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
W=tmp/bare; rm -rf "$W"; mkdir -p "$W"
fail=0; bad() { echo "FAIL: $*"; fail=1; }
PFRONT_LOW_OUT=$W/k.low.air ./pfrontc tests/air3/prog_bare/kernel.pie --emit-air-low --quiet >/dev/null 2>&1; [ -f $W/k.low.air ] || bad "pfrontc: no .air"
tmp/airtool verify-low $W/k.low.air >/dev/null 2>&1 || bad "verify-low"
tmp/airtool emit-ll $W/k.low.air -o $W/k.ll --target=x86_64-unknown-none-elf --syscall=x86_64-linux >$W/e.log 2>&1 || bad "emit-ll: $(head -1 $W/e.log)"
python3 scripts/ll-exe.py $W/k.ll -o $W/kernel.elf -O2 --features=-sse,-sse2,-mmx,+soft-float --reloc static --code-model kernel \
    --ld-script tests/air3/prog_bare/kernel.ld >$W/b.log 2>&1 || bad "ll-exe: $(head -2 $W/b.log | tr '\n' ' ')"
if [ -f $W/kernel.elf ]; then
    [ "$(readelf -h $W/kernel.elf | awk '/Entry point/{print $4}')" = 0x100000 ] || bad "entry point is not 0x100000"
    [ "$(nm $W/kernel.elf | awk '$3=="_start"{print $1}')" = 0000000000100000 ] || bad "_start is not first in .text.boot"
    [ -z "$(nm -u $W/kernel.elf)" ] || bad "undefined symbols: $(nm -u $W/kernel.elf | tr '\n' ' ')"
    gdt=$(nm $W/kernel.elf | awk '$3=="GDT"{print $1}'); [ -n "$gdt" ] && [ $((16#$gdt % 16)) = 0 ] || bad "GDT is not 16-byte aligned"
    readelf -S $W/kernel.elf | grep -q '\.gdt ' || bad "no .gdt section"
    # 3 packed 8-byte descriptors: null, code (access 9a, flags af), data (access 92, flags cf)
    hex=$(readelf -x .gdt $W/kernel.elf | awk '/0x/{for(i=2;i<=5;i++)printf "%s",$i}')
    [ "${hex:0:48}" = "0000000000000000ffff0000009aaf00ffff00000092cf00" ] || bad "GDT bytes: $hex"
    [ "$(objdump -d $W/kernel.elf | grep -c xmm)" = 0 ] || bad "SSE registers in kernel code"
    grep -q 'noredzone' $W/k.ll || bad "no noredzone attribute in the IR"
    objdump -d $W/kernel.elf | awk '/<timer_isr>:/,/ret/' | grep -q -- '-0x[0-9a-f]*(%rsp)' && bad "red zone used in timer_isr"
fi
[ $fail = 0 ] && echo "bare-metal kernel image: PASS"
[ $fail = 0 ]
