#!/usr/bin/env bash
# agent3-build.sh — build pfrontc. Requires scripts/agent3-env.sh to have run.
set -eu
cd "$(dirname "$0")/.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
~/.cache/c3tool/c3c compile --stdlib "$HOME/c3lib" \
    pfront/*.c3 pfront/pear_ir/*.c3 pfront/theory/*.c3 \
    pfront/theory/types/*.c3 pfront/theory/meta/*.c3 pfront/theory/effects/*.c3 \
    pfront/theory/rewrite/*.c3 pfront/theory/lower/*.c3 pfront/theory/analysis/*.c3 \
    -L "$HOME/.cache/llvm23" -l LLVM-23 -o pfrontc
