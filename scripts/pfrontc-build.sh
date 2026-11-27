#!/usr/bin/env bash
# Build ./pfrontc with c3c 0.8.6.
#
# The compiler is written in C3, so the toolchain is a hard prerequisite. Point
# C3C at the compiler and C3C_LIB at its stdlib; both are required, because a
# mismatched pair fails deep inside the compile with a message that names
# neither path.
#
#   C3C=/path/to/c3c C3C_LIB=/path/to/c3/lib bash scripts/pfrontc-build.sh
#
# The source list is not duplicated here: it is read from the Makefile's own
# `pfrontc` target, so this script cannot drift from the build it reproduces.
set -eu -o pipefail

C3C=${C3C:-/tmp/c3static/c3/c3c}
C3C_LIB=${C3C_LIB:-/tmp/c3static/c3/lib}
OUT=${OUT:-pfrontc}

[ -x "$C3C" ] || { echo "c3c not found at $C3C -- set C3C to a c3c 0.8.6 binary" >&2; exit 2; }
[ -d "$C3C_LIB" ] || { echo "c3c stdlib not found at $C3C_LIB -- set C3C_LIB" >&2; exit 2; }

ver=$("$C3C" --version 2>&1 | sed -n 's/^C3 Compiler Version:[[:space:]]*//p')
echo "c3c ${ver:-?} ($C3C)"

# `make -n pfrontc` prints the compile line without running it; take the source
# list from it. A missing target is a real error, not an empty build.
SRC=$(make -Bn pfrontc 2>/dev/null | grep -m1 'compile --stdlib' \
      | sed -e 's/.*compile --stdlib [^ ]* //' -e 's/ --max-stack-object-size.*//')
if [ -z "$SRC" ]; then
    echo "could not read the source list from \`make -n pfrontc\`" >&2
    exit 2
fi
echo "sources: $(printf '%s\n' $SRC | wc -l) files"

# c3c resolves a relative -o against its own working directory, so make it absolute.
# shellcheck disable=SC2086
"$C3C" compile --stdlib "$C3C_LIB" $SRC \
    --max-stack-object-size 262144 \
    -o "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

echo "built $OUT"
