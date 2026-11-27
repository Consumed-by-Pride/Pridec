#!/usr/bin/env bash
# Compile the multi-module Pride Tokei workload without requiring a backend.
set -u
cd "$(dirname "$0")/../.." || exit 2
BIN=${PFRONT_BIN:-./pfrontc}
[ -x "$BIN" ] || { echo "build ./pfrontc first" >&2; exit 2; }

# The modules declare themselves `mod tokei.*`, so the module ROOT is the
# directory that contains `tokei/` -- that is `examples/`, and the compiler is
# asked from inside it. Running from the repository root with `-I examples` makes
# `use tokei.model` look for `examples/tokei/model.pie` under a root that already
# ends in `examples`, so nothing resolves and the workload reports 26 errors that
# have nothing to do with the program.
BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")
STDLIB_ABS=$(cd stdlib && pwd)
out=$(cd examples && "$BIN_ABS" tokei/main.pie -I . -I "$STDLIB_ABS" --plain --quiet 2>&1)
rc=$?
printf '%s\n' "$out"
if [ "$rc" -gt 1 ]; then
    echo "Tokei-Pride failed front-end compilation (rc=$rc)" >&2
    exit 1
fi
if ! printf '%s\n' "$out" | grep -Eq 'errors=0([[:space:]]|$)'; then
    echo "Tokei-Pride did not compile cleanly" >&2
    exit 1
fi
echo "Tokei-Pride front-end contract: PASS"
