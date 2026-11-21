#!/bin/bash
# PEAR 2 corpus: real .pie programs through the *pear2c* backend, i.e.
#
#   pfrontc --emit-air-low -> pear2c --emit-ll -> LLVM -> link -> run
#
# This is the twin of tests/air3/low_corpus.sh, which drives the same corpus
# through `airtool emit-ll` (the reference consumer, air_ll). The two must agree
# program by program: every PASS here should also be a PASS there, and a program
# that builds under air_ll but not under pear2c is a pear2c gap, not a language
# limitation. That comparison is the point -- it is the measurement that says
# whether this backend can compile real Pride, as opposed to the hand-written
# .air fixtures it is developed against.
#
# Statuses:
#   PASS      built by pear2c from the lowered .air and behaved as the header says
#   OK        (--lib only) the module lowered and pear2c produced a module for it
#   FRONT     the front end itself rejects the program         (not a backend matter)
#   NOLOWER   pfrontc --emit-air-low refused a construct       (not a backend matter)
#   PEAR2     pear2c refused to lower the .air                 (a BACKEND gap: the list to work from)
#   VERIFY    the lowered .air fails verify-low                (a LOWERING bug, not pear2c's)
#   LLVM      pear2c's output, or the build/link of it, failed  (a BACKEND BUG, must be 0)
#   WRONG     built, ran, behaved differently                  (a BACKEND BUG, must be 0)
#
# Usage: tests/pear2/corpus.sh [-v] [--tsv OUT] [--probe] [--lib] [files...]
#        default files: tests/exec/*.pie tests/exec/pear/*.pie  (--lib: stdlib/*.pie)
#   --probe   stop after "did pear2c lower it" (pear2c --probe; no LLVM context)
#   --lib     sweep libraries: no main, so nothing is linked or run
set -u
cd "$(dirname "$0")/../.." || exit 1
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
V=0; TSV=""; PROBE=0; LIB=0; files=()
while [ $# -gt 0 ]; do
    case "$1" in
        -v) V=1 ;;
        --probe) PROBE=1 ;;
        --lib) LIB=1 ;;
        --tsv) TSV="$2"; shift ;;
        *) files+=("$1") ;;
    esac
    shift
done
if [ ${#files[@]} = 0 ]; then
    if [ $LIB = 1 ]; then files=($(find stdlib -name '*.pie' | sort)); else files=(tests/exec/*.pie tests/exec/pear/*.pie); fi
fi

# ── Preflight. A corpus run that silently degrades to "0 of 0" is worse than one
# that refuses to start, so say exactly what is missing.
PEAR2=./pear2/pear2c; PFRONT=./pfrontc; AIRTOOL=tmp/airtool
missing=""
[ -x "$PEAR2" ] || missing="$missing pear2c"
[ -x "$PFRONT" ] || missing="$missing pfrontc"
[ -x "$AIRTOOL" ] || missing="$missing airtool"
if [ -n "$missing" ]; then
    echo "pear2 corpus: cannot run -- missing:$missing"
    echo "  build:  make pear2c pfrontc airtool   (needs a c3c that links LLVM; this sandbox's is check-only)"
    echo "  LLVM:   export LD_LIBRARY_PATH=\$HOME/.cache/llvm23   (libLLVM-23.so)"
    echo "  probe:  tests/pear2/corpus.sh --probe   (no LLVM context; pear2c still needs the .so at load time)"
    exit 2
fi
# pear2c links LLVM, so even --probe needs the shared object loadable. Checked
# apart from the binaries so a failure names the right thing.
if ! python3 -c "import ctypes; ctypes.CDLL('libLLVM-23.so')" 2>/dev/null; then
    echo "pear2 corpus: libLLVM-23.so is not loadable -- set LD_LIBRARY_PATH (\$HOME/.cache/llvm23)"
    exit 2
fi

W=tmp/pear2-corpus; rm -rf "$W"; mkdir -p "$W"
declare -A cnt; : > "$W/rows.tsv"
# Decode \n and \t in an EXPECT line, exactly as tests/exec/run.sh does. The
# sed-based version this replaces dropped the escape *and* the trailing newline,
# so `-- EXPECT: HI\n` asked for `HI` and a correct program was reported WRONG.
# `$(...)` strips every trailing newline, so `printf '%b'` alone turns
# `-- EXPECT: HI\n` into `HI` and a correct program is reported WRONG. The
# sentinel keeps whatever trailing newlines the header asked for.
expect_of() { v=$(grep -m1 '^-- EXPECT:' "$1" | sed 's/^-- EXPECT: //' || true); [ -z "$v" ] && return 0; d=$(printf '%b' "$v"; printf X); printf '%s' "${d%X}"; }
exit_of() {
    v=$(grep -m1 '^-- LOW-EXIT:' "$1" | sed 's/^-- LOW-EXIT: *//')
    [ -z "$v" ] && v=$(grep -m1 '^-- EXIT:' "$1" | sed 's/^-- EXIT: *//')
    printf '%s' "${v:-0}"
}
# Programs that call the fiber/prompt runtime (`__pride_*` externs from
# stdlib/pride/effects.pie) link runtime/compiler_rt.c, exactly as the air_ll
# corpus does, so the comparison is about the backend and not about the runtime.
rt_args() {
    grep -q '__pride_' "$1" || return 0
    if [ ! -f "$W/rt_a.o" ]; then
        gcc -O2 -pthread -msse4.1 -fPIC -fno-strict-aliasing -w -c runtime/compiler_rt.c -o "$W/rt_a.o" &&
        gcc -O2 -pthread -msse4.1 -fPIC -w -c runtime/compiler_rt_arch.c -o "$W/rt_b.o" || return 0
    fi
    echo "--link $W/rt_a.o --link $W/rt_b.o --link -pthread --link -lm"
}

for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    if [ $LIB = 1 ]; then id=$(echo "${f#stdlib/}" | sed 's/\.pie$//; s#/#_#g')
    else id=$(echo "${f#tests/exec/}" | sed 's/\.pie$//; s#/#_#g'); fi
    low="$W/$id.low.air"; ll="$W/$id.low.ll"; st=""; why=""

    # 1. Front end and typed lowering. Identical to the air_ll path, so FRONT and
    #    NOLOWER are not this backend's business and are not counted against it.
    out=$(PFRONT_LOW_OUT="$low" "$PFRONT" "$f" --emit-air-low --quiet 2>&1)
    if echo "$out" | grep -q 'errors=[1-9]'; then
        st=FRONT; why=$(echo "$out" | grep -m1 -i 'error' | cut -c1-110)
    elif [ ! -f "$low" ]; then
        st=NOLOWER; why=$(echo "$out" | grep -m1 'air-low:\|error' | sed 's/^air-low: error: //' | cut -c1-110)
    elif ! "$AIRTOOL" verify-low "$low" >"$W/$id.v" 2>&1; then
        st=VERIFY; why=$(head -1 "$W/$id.v" | cut -c1-110)
    # 2. Ask the backend. In probe mode this is the whole question.
    elif [ $PROBE = 1 ]; then
        if "$PEAR2" "$low" --probe >"$W/$id.p" 2>&1; then
            st=PASS
        else
            st=PEAR2
            why=$(grep -m1 'cannot lower' "$W/$id.p" | sed 's/^.*cannot lower/cannot lower/' | cut -c1-110)
            [ -z "$why" ] && why=$(head -1 "$W/$id.p" | cut -c1-110)
        fi
    else
        # 3. The backend itself: .air -> .ll (pear2c derives the path; no -o).
        if ! "$PEAR2" "$low" --emit-ll --quiet >"$W/$id.e" 2>&1; then
            if grep -qi 'cannot lower\|unsupported\|not supported\|could not' "$W/$id.e"; then
                st=PEAR2; why=$(grep -m1 -i 'cannot lower\|unsupported\|not supported\|could not' "$W/$id.e" | cut -c1-110)
            else
                st=LLVM; why=$(head -1 "$W/$id.e" | cut -c1-110)
            fi
        elif [ $LIB = 1 ]; then
            # A library has no `main`, so there is nothing to link or run: the
            # claim being measured is "pear2c produced a module for it".
            st=OK
        elif [ ! -f "$ll" ]; then
            st=LLVM; why="pear2c reported success but wrote no $ll"
        elif ! python3 scripts/ll-exe.py "$ll" -o "$W/$id.exe" -O2 $(rt_args "$ll") >"$W/$id.b" 2>&1; then
            st=LLVM; why=$(grep -m1 -i 'error\|invalid\|verifier\|undefined' "$W/$id.b" | cut -c1-110)
        else
            # The sentinel has to be applied *here*: expect_of preserves a trailing
            # newline in its output, but this command substitution would strip it
            # straight back off.
            wantd=$(expect_of "$f"; printf X); wantd=${wantd%X}; wx=$(exit_of "$f")
            # The sentinel matters here too: `$(...)` strips trailing newlines, so
            # a program that prints `HI\n` and one that prints `HI` would look
            # identical, and a program that prints an extra blank line would pass.
            got=$(timeout 5 "$W/$id.exe" 2>/dev/null; x=$?; printf X; echo "rc=$x")
            grc=${got##*rc=}; got=${got%rc=*}; got=${got%X}
            if [ "$grc" = "$wx" ] && { [ -z "$wantd" ] || [ "$got" = "$wantd" ]; }; then
                st=PASS
            else
                st=WRONG; why="exit $grc (want $wx), stdout '$(printf '%s' "$got" | head -c 40)' (want '$(printf '%s' "$wantd" | head -c 40)')"
            fi
        fi
    fi

    cnt[$st]=$(( ${cnt[$st]:-0} + 1 ))
    printf '%s\t%s\t%s\n' "$id" "$st" "$why" >> "$W/rows.tsv"
    if [ $V = 1 ]; then
        if [ "$st" = PASS ] || [ "$st" = OK ]; then printf '  %-8s %s\n' "$st" "$id"
        else printf '  %-8s %-40s %s\n' "$st" "$id" "$why"; fi
    fi
done
[ -n "$TSV" ] && cp "$W/rows.tsv" "$TSV"

if [ $LIB = 1 ]; then
    echo "pear2 stdlib: OK=${cnt[OK]:-0} PEAR2=${cnt[PEAR2]:-0} FRONT=${cnt[FRONT]:-0} NOLOWER=${cnt[NOLOWER]:-0} VERIFY=${cnt[VERIFY]:-0} LLVM=${cnt[LLVM]:-0} of ${#files[@]}"
    [ "${cnt[VERIFY]:-0}" = 0 ] && [ "${cnt[LLVM]:-0}" = 0 ]
    exit $?
fi
if [ $PROBE = 1 ]; then
    # Only "does pear2c accept what the lowering produced" is being asked, so the
    # lower/refuse split is a measurement to report, not a pass/fail.
    echo "pear2 corpus (probe): LOWER=${cnt[PASS]:-0} PEAR2=${cnt[PEAR2]:-0} VERIFY=${cnt[VERIFY]:-0} FRONT=${cnt[FRONT]:-0} NOLOWER=${cnt[NOLOWER]:-0} of ${#files[@]}"
    exit 0
fi
echo "pear2 corpus: PASS=${cnt[PASS]:-0} PEAR2=${cnt[PEAR2]:-0} WRONG=${cnt[WRONG]:-0} LLVM=${cnt[LLVM]:-0} VERIFY=${cnt[VERIFY]:-0} FRONT=${cnt[FRONT]:-0} NOLOWER=${cnt[NOLOWER]:-0} of ${#files[@]}"
# A wrong answer, a module LLVM rejects, or a link failure is a bug in this
# backend. A refusal is a gap, which is what the corpus exists to list.
[ "${cnt[WRONG]:-0}" = 0 ] && [ "${cnt[LLVM]:-0}" = 0 ]
