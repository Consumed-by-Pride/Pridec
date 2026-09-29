#!/usr/bin/env bash
# Bounty battery — behaviour probes with hand-computed exit codes, plus robustness
# probes that must not crash the compiler. Run from the repo root:
#   bash tests/bounty/run.sh            # all
#   bash tests/bounty/run.sh -O2        # pick an optimisation tier (default -O2)
# Compares each b*.pie program's exit status against its "-- BOUNTY:" header and
# reports robustness tiers (compile rc / crash) separately. Exit code = #failures.
set -u
cd "$(dirname "$0")/../.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
BIN=./pfrontc
OPT="${1:--O2}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; rfails=0

echo "=== behaviour probes ($OPT) ==="
for f in tests/bounty/b*.pie; do
    name=$(basename "$f" .pie)
    want=$(grep -m1 -oE 'BOUNTY: hand-computed exit -?[0-9]+' "$f" | grep -oE '\-?[0-9]+$')
    [ -z "$want" ] && continue
    cp "$f" "$TMP/$name.pie"; rm -f "$TMP/$name"
    "$BIN" "$TMP/$name.pie" --emit-exe "$OPT" --quiet >/dev/null 2>&1
    if [ ! -x "$TMP/$name" ]; then got="NOBIN"; else timeout 10 "$TMP/$name" >/dev/null 2>&1; got=$?; fi
    if [ "$got" = "$want" ]; then pass=$((pass+1)); else
        fail=$((fail+1)); printf "  FAIL %-20s exit=%-6s want=%s\n" "$name" "$got" "$want"; fi
done
echo "  behaviour: pass=$pass fail=$fail"

echo "=== robustness probes (compile only; a crash or hang is a failure) ==="
for f in tests/bounty/r*.pie; do
    name=$(basename "$f" .pie)
    cp "$f" "$TMP/$name.pie"; timeout 60 "$BIN" "$TMP/$name.pie" --emit-exe "$OPT" --quiet >/dev/null 2>&1; rc=$?
    if [ "$rc" -ge 124 ]; then rfails=$((rfails+1)); printf "  FAIL %-20s hang/signal rc=%s\n" "$name" "$rc"; fi
    printf "    %-20s compile rc=%s\n" "$name" "$rc"
done
echo "  robustness: crashes=$rfails (a genuine diagnostic is rc=1/2, not a crash)"
echo "=== bounty summary: behaviour failures=$((fail)) robustness crashes=$rfails ==="
exit $((fail + rfails))
