#!/bin/bash
# pie-exe.sh — the whole chain in one command, with the old `pfrontc --emit-exe` CLI.
#
#     pie-exe.sh FILE.pie [--emit-exe | --emit-bc] [-O0..-O3] [pfrontc options...]
#
#   pfrontc FILE.pie --emit-air ...   ->  FILE.air        (front end; ends here)
#   pear1c  FILE.air --emit-exe -Ox   ->  FILE            (legacy PEAR 1 -> LLVM 23 -> ELF)
#                                         FILE.bc         with --emit-bc
#
# stdout/stderr of both stages are forwarded in order. Exit status is pfrontc's
# (0 clean, 1 warnings, 2 errors); if pfrontc accepted the program but the backend
# produced nothing it is 3. A stale FILE.air is removed first: a failed front end
# must never reach the backend through an old file.
#
# Env: PFRONTC=./pfrontc            front end (default: repo root)
#      BACKEND=legacy/pear1/pear1c  any program with the backend CLI contract (docs/pear2/CONTRACT.md):
#                                       BACKEND FILE.air --emit-exe|--emit-bc [-O0..-O3] --quiet
#                                   so PEAR 2 runs the whole exec suite with `BACKEND=path/to/pear2c make test-exec`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PFRONTC="${PFRONTC:-$ROOT/pfrontc}"
PEAR1C="${BACKEND:-${PEAR1C:-$ROOT/legacy/pear1/pear1c}}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu}"

src=""; mode="--emit-exe"; opt=""; front=()
for a in "$@"; do
    case "$a" in
        --emit-exe|--emit-bc) mode="$a" ;;
        -O0|-O1|-O2|-O3)      opt="$a"; front+=("$a") ;;
        --emit-air)           ;;
        -*)                   front+=("$a") ;;
        *)                    if [ -z "$src" ]; then src="$a"; else front+=("$a"); fi ;;
    esac
done
[ -n "$src" ] || { echo "usage: pie-exe.sh FILE.pie [--emit-exe|--emit-bc] [-O0..-O3] [options]" >&2; exit 2; }
[ -x "$PFRONTC" ] || { echo "pie-exe: $PFRONTC not built (make)" >&2; exit 2; }
[ -x "$PEAR1C" ]  || { echo "pie-exe: $PEAR1C not built (make legacy-pear)" >&2; exit 2; }

air="${src%.*}.air"
rm -f "$air"
"$PFRONTC" "$src" --emit-air "${front[@]}"
rc=$?
if [ $rc -ge 2 ] || [ ! -f "$air" ]; then exit $rc; fi
"$PEAR1C" "$air" "$mode" ${opt:+"$opt"} --quiet
brc=$?
if [ $brc -ne 0 ]; then
    [ $rc -ge 2 ] || rc=3
fi
exit $rc
