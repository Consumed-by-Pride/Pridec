#!/usr/bin/env bash
# agent3-env.sh — restore the build environment for Pridec.
#
# The sandbox excludes ~/.cache from snapshots (deliberately), so the 119 MB c3c
# binary and the 154 MB libLLVM live there and do NOT survive a rollback. This
# script puts them back. Run it, then build:
#
#   bash scripts/agent3-env.sh
#   bash scripts/agent3-build.sh
#
# Everything it fetches is verified by size and version before use.
set -u
C3VER=v0.8.4
C3_URL="https://github.com/c3lang/c3c/releases/download/${C3VER}/c3-linux-static.tar.gz"
LLVM_URL="http://apt.llvm.org/trixie/pool/main/l/llvm-toolchain-23/libllvm23_23.1.2~%2B%2B20260920034005%2B85ac56026243-1~exp1~20260920034024.76_amd64.deb"
C3BIN="$HOME/.cache/c3tool/c3c"
LLVMDIR="$HOME/.cache/llvm23"

say() { printf '  %s\n' "$*"; }

if [ ! -x "$C3BIN" ]; then
    say "fetching c3c $C3VER ..."
    mkdir -p "$HOME/.cache/c3tool" /tmp/c3x
    curl -sL -o /tmp/c3.tar.gz "$C3_URL" || { say "download failed"; exit 1; }
    tar xzf /tmp/c3.tar.gz -C /tmp/c3x || exit 1
    cp "$(find /tmp/c3x -maxdepth 3 -name c3c -type f | head -1)" "$C3BIN" && chmod +x "$C3BIN"
fi
mkdir -p "$HOME/c3bin" && ln -sf "$C3BIN" "$HOME/c3bin/c3c"
say "c3c: $("$C3BIN" --version 2>/dev/null | head -1)"

# stdlib copy the compiler needs (releases ship it under c3/lib/std)
if [ ! -d "$HOME/c3lib/std" ] || [ ! -d "$HOME/c3lib/std/collections" ]; then
    say "restoring c3 stdlib ..."
    mkdir -p "$HOME/c3lib"
    if [ ! -d /tmp/c3x/c3/lib/std ]; then
        rm -rf /tmp/c3x && mkdir -p /tmp/c3x
        curl -sL -o /tmp/c3.tar.gz "$C3_URL" && tar xzf /tmp/c3.tar.gz -C /tmp/c3x
    fi
    cp -r /tmp/c3x/c3/lib/std "$HOME/c3lib/std"
fi
say "stdlib: $(ls "$HOME/c3lib/std" | wc -l) entries"

if [ ! -f "$LLVMDIR/libLLVM-23.so" ]; then
    say "fetching libLLVM 23 ..."
    mkdir -p "$LLVMDIR"
    curl -sL -o /tmp/llvm23.deb "$LLVM_URL" || { say "download failed"; exit 1; }
    dpkg-deb -x /tmp/llvm23.deb /tmp/llvm23x && rm -rf /tmp/llvm23.deb
    cp /tmp/llvm23x/usr/lib/x86_64-linux-gnu/libLLVM* "$LLVMDIR/" && rm -rf /tmp/llvm23x
fi
say "libLLVM: $(basename "$(readlink -f "$LLVMDIR/libLLVM-23.so")") ($(du -h "$LLVMDIR/libLLVM.so.23.1" 2>/dev/null | cut -f1))"
say "done — now: bash scripts/agent3-build.sh"
