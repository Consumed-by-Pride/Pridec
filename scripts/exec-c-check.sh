#!/usr/bin/env bash
# Compile tests/exec through the C target, link, run, and check the result.
#
#   bash scripts/exec-c-check.sh [pattern]
#
# Each test declares its expectation in the source:
#   -- EXPECT: <text>     the exact stdout
#   -- BOUNTY: exit N     (tests/bounty) the exit code
#   neither               exit 0 means the test's own assertions held
#
# The C runtime is linked, not stubbed: runtime/compiler_rt.c already implements
# every `__pride_*` symbol air_low names (fibers, prompts, dynamic-wind, effect
# locals), and a target that invented empty stubs would "pass" while doing
# nothing.
set -u -o pipefail
cd "$(dirname "$0")/.." || exit 2

PFRONT=${PFRONT:-./pfrontc}
# Absolute, because the compile runs from the scratch directory and a relative
# $PFRONT there is a different path (or none at all).
PFRONT=$(cd "$(dirname "$PFRONT")" && pwd)/$(basename "$PFRONT")
W=${W:-tmp/exec-c}
PAT=${1:-}
CC=${CC:-gcc}
# -msse4.1: compiler_rt.c uses SSE4 intrinsics unconditionally. -pthread: the
# fiber runtime is thread-backed.
CRT_CFLAGS="-O2 -w -fPIC -pthread"
CRT_MSIMD="-msse4.1"

[ -x "$PFRONT" ] || { echo "build $PFRONT first (scripts/pfrontc-build.sh)" >&2; exit 2; }
mkdir -p "$W"

if [ ! -f "$W/crt.o" ] || [ runtime/compiler_rt.c -nt "$W/crt.o" ]; then
    $CC $CRT_CFLAGS $CRT_MSIMD -c runtime/compiler_rt.c -o "$W/crt.o" || exit 2
fi
if [ ! -f "$W/crt_arch.o" ] || [ runtime/compiler_rt_arch.c -nt "$W/crt_arch.o" ]; then
    $CC $CRT_CFLAGS -c runtime/compiler_rt_arch.c -o "$W/crt_arch.o" || exit 2
fi

pass=0 fail=0 skip=0
for pie in tests/exec/*.pie tests/bounty/b*.pie; do
    [ -e "$pie" ] || continue
    name=$(basename "$pie" .pie)
    case "$name" in *$PAT*) ;; *) continue ;; esac
    src=${pie%.pie}.c
    exe="$W/$name"

    # The compiler writes FILE.c next to FILE.pie; run it from a scratch copy so
    # the working tree stays clean.
    cp "$pie" "$W/$name.pie"
    # pfrontc exits 1 when the front end reported WARNINGS even though it
    # emitted everything asked for, and 2/3 when it genuinely refused. The
    # artifact is the evidence, not the exit code.
    ( cd "$W" && "$PFRONT" "$name.pie" --emit-c ) >"$W/$name.build" 2>&1
    rc_build=$?
    if [ "$rc_build" -ge 2 ] || [ ! -f "$W/$name.c" ]; then
        echo "FAIL [$name] pfrontc refused (rc=$rc_build)"
        grep -m2 -E 'air-low: error|air-c:|error\[' "$W/$name.build"
        fail=$((fail+1)); continue
    fi
    if grep -q '^air-c:' "$W/$name.build"; then
        echo "FAIL [$name] air_c refused:"; grep '^air-c:' "$W/$name.build" | head -2; fail=$((fail+1)); continue
    fi
    if ! $CC -std=c11 -O1 -w "$W/$name.c" "$W/crt.o" "$W/crt_arch.o" -o "$exe" -pthread 2>"$W/$name.cc"; then
        echo "FAIL [$name] gcc/link:"; grep -m2 -oE 'error: .*|undefined reference to .*' "$W/$name.cc"; fail=$((fail+1)); continue
    fi

    want=$(sed -n 's/^-- EXPECT: //p' "$pie" | head -1)
    wantb=$(sed -n 's/^-- BOUNTY: hand-computed exit \([-0-9]*\)/\1/p' "$pie" | head -1)
    out=$("$exe" 2>&1); rc=$?

    if [ -n "$wantb" ]; then
        if [ "$rc" -eq "$wantb" ]; then pass=$((pass+1)); else echo "FAIL [$name] exit $rc, want $wantb"; fail=$((fail+1)); fi
    elif [ -n "$want" ]; then
        # The header stores the text with escaped newlines.
        exp=$(printf '%b' "$want")
        if [ "$out" = "$exp" ]; then pass=$((pass+1)); else
            echo "FAIL [$name] stdout mismatch"; echo "  want: $(printf '%s' "$exp" | head -c 120)"; echo "  got : $(printf '%s' "$out" | head -c 120)"
            fail=$((fail+1))
        fi
    else
        if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else echo "FAIL [$name] exit $rc (test asserts success)"; fail=$((fail+1)); fi
    fi
done

echo "== exec-c: pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
