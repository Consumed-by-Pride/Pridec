#!/bin/bash
# The AIR boundary, checked instead of hoped for.
#
# `pfrontc` produces AIR and stops; every consumer of AIR lives outside it. That
# is the whole architecture claim, and for a long time it was false in a way no
# test could see: the Makefile swept `pfront/pear_ir/*.c3` into the compiler with
# a wildcard, so `pfrontc` linked `air_ll` (a 68 KB LLVM text printer it never
# calls) and nothing noticed. This script is what notices.
#
# Two rules, each one a bug that actually happened:
#
#   1. EMIT may not import USE. An emitter that can reach the verifier or the
#      printer will eventually call it, and then "the front end" needs the
#      backend's modules to build. `air_low` importing `air_ll` for `ty_bits` is
#      exactly this, and it is why the shared floor exists.
#
#   2. USE may not import EMIT. A consumer that reaches into a lowering has
#      started depending on how AIR was made rather than on AIR.
#
# AIR_CORE is the floor both sides may use.
set -u
cd "$(dirname "$0")/../.." || exit 1

# Sides are taken FROM THE MAKEFILE: if the lists and this script disagree, the
# lists are what builds, so they are the truth.
core=$(sed -n 's/^AIR_CORE  := //p' Makefile | tr -d '\\' | tr ' ' '\n' | grep -v '^$' | sed 's|.*/||;s|\.c3||')
emit=$(sed -n '/^AIR_EMIT  :=/,/[^\\]$/p' Makefile | tr -d '\\' | tr ' ' '\n' | grep -v '^$' | grep -v '^$' | sed 's|.*/||;s|\.c3||' | grep -v 'AIR_EMIT')
use=$(sed -n '/^AIR_USE   :=/,/[^\\]$/p' Makefile | tr -d '\\' | tr ' ' '\n' | grep -v '^$' | sed 's|.*/||;s|\.c3||' | grep -v 'AIR_USE')
# MID reads, rewrites and writes: it may import both sides. Only the tools link it.
mid=$(sed -n '/^AIR_MID   :=/,/[^\\]$/p' Makefile | tr -d '\\' | tr ' ' '\n' | grep -v '^$' | sed 's|.*/||;s|\.c3||' | grep -v 'AIR_MID')

fail=0
check() {   # check SIDE FILE IMPORTED_SIDE NAME
    side=$1; file=$2; other=$3; othername=$4
    for mod in $other; do
        if grep -qE "^import $mod;" "pfront/pear_ir/$file.c3" 2>/dev/null; then
            echo "FAIL: $file ($side) imports $mod ($othername)"
            fail=1
        fi
    done
}

for f in $emit; do check EMIT "$f" "$use" "USE"; done
for f in $use;  do check USE  "$f" "$emit" "EMIT"; done
# MID may import a lowering ONLY to produce a module it then reads back. There is
# exactly one such module today (the write/read fidelity proof, which has to lower
# a program before it has anything to round-trip) and it is named here rather than
# left to a blanket exemption. Everything else on MID works on AIR it was given:
# a pass that calls `air_low` is a lowering wearing a pass's name.
for f in $mid; do
    case "$f" in
        air_roundtrip) continue ;;
    esac
    check MID "$f" "air_low air_lower air_emit" "EMIT/lowering"
done

# Every file in the directory must be on exactly one side (or the floor). A file
# that is on none is invisible to the build until something references it, which
# is how a module can sit in the tree for a year without ever running.
for path in pfront/pear_ir/*.c3; do
    name=$(basename "$path" .c3)
    on=0
    for m in $core $emit $use $mid; do [ "$m" = "$name" ] && on=$((on+1)); done
    if [ "$on" = 0 ]; then echo "FAIL: $name is on neither side of the boundary"; fail=1; fi
    if [ "$on" -gt 1 ]; then echo "FAIL: $name is named on $on sides"; fail=1; fi
done

if [ $fail -ne 0 ]; then exit 1; fi
printf 'PASS: AIR boundary holds — %s emit, %s consume, %s shared\n' \
    "$(echo $emit | wc -w)" "$(echo $use | wc -w)" "$(echo $core | wc -w)"
