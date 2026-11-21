#!/usr/bin/env bash
# Compile the multi-module Pride Tokei workload without requiring a backend.
set -u
cd "$(dirname "$0")/../.." || exit 2
BIN=${PFRONT_BIN:-./pfrontc}
[ -x "$BIN" ] || { echo "build ./pfrontc first" >&2; exit 2; }

out=$("$BIN" examples/tokei/main.pie -I examples -I stdlib --plain --quiet 2>&1)
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
