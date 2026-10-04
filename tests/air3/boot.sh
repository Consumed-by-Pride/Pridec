#!/bin/bash
# Boot check: tests/air3/prog_os/mini_os.pie (a 32-bit Multiboot kernel written in Pride) -> AIR 3 -> LLVM (i386-unknown-none-elf, no SSE) -> ld
# -> QEMU. The kernel prints on the serial port and leaves through isa-debug-exit (exit status (code << 1) | 1 = 33 for code 0x10).
# QEMU is looked up on PATH, then in ~/.local/qemu (scripts/get-qemu.sh installs it without root); without it the run is SKIPPED, not passed.
set -u
cd "$(dirname "$0")/../.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
W=tmp/boot; rm -rf "$W"; mkdir -p "$W"
fail=0; bad() { echo "FAIL: $*"; fail=1; }
PFRONT_LOW_OUT=$W/os.low.air ./pfrontc tests/air3/prog_os/mini_os.pie --emit-air-low --quiet >$W/f.log 2>&1; [ -f $W/os.low.air ] || { bad "pfrontc: no .air: $(grep -m2 'error' $W/f.log | tr '\n' ' ')"; exit 1; }
tmp/airtool verify-low $W/os.low.air >/dev/null 2>&1 || bad "verify-low"
tmp/airtool emit-ll $W/os.low.air -o $W/os.ll --target=i386-unknown-none-elf --syscall=i386-linux --internalize >$W/e.log 2>&1 || bad "emit-ll: $(head -1 $W/e.log)"
python3 scripts/ll-exe.py $W/os.ll -o $W/os.elf -O2 --cpu i686 --features=-sse,-sse2,-mmx,+soft-float --reloc static --ld-script tests/air3/prog_os/mini_os.ld >$W/b.log 2>&1 || bad "ll-exe: $(head -2 $W/b.log | tr '\n' ' ')"
[ -f $W/os.elf ] || exit 1
[ "$(readelf -h $W/os.elf | awk '/Class:/{print $2}')" = ELF32 ] || bad "not an ELF32 image"
[ -z "$(nm -u $W/os.elf)" ] || bad "undefined symbols: $(nm -u $W/os.elf | tr '\n' ' ')"
# the Multiboot header must sit in the first 8 KiB of the image
off=$(grep -abo $'\x02\xb0\xad\x1b' $W/os.elf | head -1 | cut -d: -f1); [ -n "$off" ] && [ "$off" -lt 8192 ] || bad "no Multiboot magic in the first 8 KiB"
Q=$(command -v qemu-system-i386 || ls "$HOME/.local/qemu/usr/bin/qemu-system-i386" 2>/dev/null)
if [ -z "$Q" ]; then echo "boot: image built and checked; SKIPPED the run (no qemu-system-i386; scripts/get-qemu.sh installs one)"; [ $fail = 0 ]; exit $?; fi
QL="$HOME/.local/qemu/usr/lib/x86_64-linux-gnu"; QS="$HOME/.local/qemu/usr/share"; QX=""; [ -d "$QS/qemu" ] && QX="-L $QS/seabios -L $QS/qemu"
LD_LIBRARY_PATH="$QL:$LD_LIBRARY_PATH" timeout 60 "$Q" $QX -kernel $W/os.elf -display none -serial file:$W/serial.txt -no-reboot \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -m 32 >$W/q.log 2>&1; rc=$?
[ "$rc" = 33 ] || bad "qemu exit status $rc (want 33 = debug-exit 0x10); $(head -3 $W/q.log | tr '\n' ' ')"
for want in "PRIDE-OS: booting" "PRIDE-OS: timer ticks=" "PRIDE-OS: software interrupts=2" "PRIDE-OS: drivers sum=" "PRIDE-OS: OK"; do
    grep -q "$want" $W/serial.txt 2>/dev/null || bad "serial output lacks '$want'"
done
# uart: probe 1016 + poke 1018; timer: probe 100 + poke 2*100 + ticks  =>  sum = 2334 + ticks (ticks >= 5)
tk=$(sed -n 's/.*timer ticks=\([0-9]*\).*/\1/p' $W/serial.txt | head -1); sm=$(sed -n 's/.*drivers sum=\([0-9]*\).*/\1/p' $W/serial.txt | head -1)
[ -n "$tk" ] && [ "$tk" -ge 5 ] || bad "timer ticks '$tk' (want >= 5)"
[ -n "$sm" ] && [ "$sm" = "$((2334 + ${tk:-0}))" ] || bad "drivers sum '$sm' is not 2334 + ticks ($tk)"
[ $fail = 0 ] && { echo "booted PRIDE-OS in QEMU: PASS"; sed 's/^/  | /' $W/serial.txt; }
[ $fail = 0 ]
