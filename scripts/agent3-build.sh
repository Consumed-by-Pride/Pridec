#!/usr/bin/env bash
# agent3-build.sh — build pfrontc (no LLVM) and the legacy backend pear1c. Requires scripts/agent3-env.sh to have run.
set -eu
cd "$(dirname "$0")/.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
~/.cache/c3tool/c3c compile --stdlib "$HOME/c3lib" \
    pfront/*.c3 pfront/pear_ir/*.c3 pfront/theory/*.c3 \
    pfront/theory/types/*.c3 pfront/theory/meta/*.c3 pfront/theory/effects/*.c3 \
    pfront/theory/rewrite/*.c3 pfront/theory/lower/*.c3 pfront/theory/analysis/*.c3 \
    --max-stack-object-size 262144 -o pfrontc
~/.cache/c3tool/c3c compile --stdlib "$HOME/c3lib" \
    legacy/pear1/pear.c3 legacy/pear1/pear_link.c3 legacy/pear1/pear1c_main.c3 \
    pfront/pfront_core.c3 pfront/pear_ir/air_ir.c3 pfront/pear_ir/air_text.c3 \
    pfront/pear_ir/air_read.c3 pfront/pear_ir/air_facts.c3 \
    --max-stack-object-size 262144 \
    -L "$HOME/.cache/llvm23" -l LLVM-23 -o legacy/pear1/pear1c
