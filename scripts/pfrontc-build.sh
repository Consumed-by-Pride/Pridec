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
# With neither set, known install locations are probed (see below) and the
# version that was found is printed. `c3c --version` must say 0.8.x; that is the
# series this source is written against.
#
# The source list is not duplicated here: it is read from the Makefile's own
# `pfrontc` target, so this script cannot drift from the build it reproduces.
set -eu -o pipefail

# Find a toolchain rather than assuming one path. c3c's Linux release asset lives
# on release-assets.githubusercontent.com, which some sandboxes cannot reach, so a
# checked-out tree can easily have the compiler somewhere unexpected (a drive
# download, ~/c3bin from `make c3c`, a build under .cache). Probing the known spots
# turns "c3c not found" into a build, and the version is always reported.
# An EXPLICIT C3C is an instruction, not a hint: if it is not usable, say so and
# stop. Falling back to a probed compiler would silently build with a different
# toolchain than the caller asked for.
if [ -n "${C3C:-}" ]; then
    [ -x "$C3C" ] || { echo "C3C=$C3C is not an executable" >&2; exit 2; }
else
    for c in /tmp/c3static/c3/c3c /tmp/c3drive/c3/c3c \
             "$HOME/c3bin/c3c" "$HOME/.cache/c3tool/c3c" \
             "$HOME/.cache/c3src/build-llvm23-clang/c3c"; do
        [ -x "$c" ] && { C3C=$c; break; }
    done
    [ -n "${C3C:-}" ] || { echo "no c3c found -- set C3C to a c3c binary (0.8.x builds pfrontc)" >&2; exit 2; }
fi
if [ -z "${C3C_LIB:-}" ]; then
    # The stdlib ships beside the binary; fall back to the other known layouts.
    for l in "$(dirname "$C3C")/lib" "$(dirname "$(dirname "$C3C")")/lib" "$HOME/c3lib" "$HOME/.cache/c3src/src/lib"; do
        [ -d "$l/std" ] && { C3C_LIB=$l; break; }
    done
fi
OUT=${OUT:-pfrontc}

[ -n "${C3C_LIB:-}" ] && [ -d "$C3C_LIB" ] || { echo "c3c stdlib not found -- set C3C_LIB" >&2; exit 2; }

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
