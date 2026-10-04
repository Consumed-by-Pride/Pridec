#!/bin/bash
# Install binaryen (wasm-opt) under ~/.cache/binaryen without root: needed by scripts/wasm-fibers.py (Asyncify, fibers on wasm32).
set -e
V=${BINARYEN_VERSION:-version_133}
D="$HOME/.cache/binaryen"
if ls "$D"/*/bin/wasm-opt >/dev/null 2>&1; then echo "binaryen already installed: $(ls "$D"/*/bin/wasm-opt | tail -1)"; exit 0; fi
mkdir -p "$D"; cd "$D"
curl -fsSL -o b.tgz "https://github.com/WebAssembly/binaryen/releases/download/$V/binaryen-$V-x86_64-linux.tar.gz"
tar xzf b.tgz; rm -f b.tgz
ls "$D"/*/bin/wasm-opt
