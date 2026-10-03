#!/bin/bash
# AIR 3.0 lowering corpus: every tests/exec case through
#   pfrontc --emit-air-low -> airtool verify-low -> airtool emit-ll -> scripts/ll-exe.py -> run
# and compared with the program's own `-- EXPECT:` / `-- EXIT:` header (same rules as tests/exec/run.sh).
#
# Statuses:  PASS      built from the low .air and behaved as the header says
#            FRONT     the front end itself rejects the program (not a lowering matter; tests/exec/XFAIL.tsv)
#            NOLOWER   pfrontc --emit-air-low reported a construct it does not lower yet (first diagnostic shown)
#            VERIFY    the lowering wrote a .air that verify-low rejected   (a LOWERING BUG, must be 0)
#            LLVM      emit-ll / LLVM verification / link failed            (a LOWERING or CONSUMER BUG, must be 0)
#            WRONG     built, ran, output/exit differs from the header       (a LOWERING BUG, must be 0)
#
# Usage: tests/air3/low_corpus.sh [-v] [--tsv OUT] [files...]   (default: tests/exec/*.pie tests/exec/pear/*.pie)
set -u
cd "$(dirname "$0")/../.."
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
V=0; TSV=""; files=(); WASM=0; FS=0; LLX=""; EXX=""
export PATH="$PATH:$HOME/.local/bin"
while [ $# -gt 0 ]; do case "$1" in -v) V=1;; --wasm) WASM=1; LLX="--target=wasm32-wasi";; --freestanding) FS=1; LLX="--syscall=x86_64-linux"; EXX="--freestanding";; --tsv) TSV="$2"; shift;; *) files+=("$1");; esac; shift; done
[ ${#files[@]} = 0 ] && files=(tests/exec/*.pie tests/exec/pear/*.pie)
W=tmp/low-corpus; rm -rf "$W"; mkdir -p "$W"
declare -A cnt; : > "$W/rows.tsv"
expect_of() { grep -m1 '^-- EXPECT:' "$1" | sed 's/^-- EXPECT: //'; }
exit_of()   { v=""; [ $WASM = 1 ] && v=$(grep -m1 '^-- WASM32-EXIT:' "$1" | sed 's/^-- WASM32-EXIT: *//'); [ -z "$v" ] && v=$(grep -m1 '^-- LOW-EXIT:' "$1" | sed 's/^-- LOW-EXIT: *//'); [ -z "$v" ] && v=$(grep -m1 '^-- EXIT:' "$1" | sed 's/^-- EXIT: *//'); printf '%s' "${v:-0}"; }   # WASM32-EXIT: (wasm only) where the result depends on the pointer width; LOW-EXIT: where PEAR1 deviates from the spec (defer is function-scoped)
for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    id=$(echo "${f#tests/exec/}" | sed 's/\.pie$//; s#/#_#g')
    low="$W/$id.low.air"; st=""; why=""
    out=$(PFRONT_LOW_OUT="$low" ./pfrontc "$f" --emit-air-low --quiet 2>&1); rc=$?
    if echo "$out" | grep -q 'errors=[1-9]'; then
        st=FRONT; why=$(PFRONT_LOW_OUT="$low" ./pfrontc "$f" --emit-air-low 2>&1 | grep -m1 -i 'error' | cut -c1-110)
    elif [ ! -f "$low" ]; then
        st=NOLOWER; why=$(echo "$out" | grep -m1 'air-low:\|error' | sed 's/^air-low: error: //' | cut -c1-110)
    elif ! tmp/airtool verify-low "$low" >"$W/$id.v" 2>&1; then st=VERIFY; why=$(head -1 "$W/$id.v" | cut -c1-110)
    elif ! tmp/airtool emit-ll "$low" -o "$W/$id.ll" $LLX >"$W/$id.e" 2>&1; then st=LLVM; why=$(head -1 "$W/$id.e" | cut -c1-110)
    elif [ $WASM = 0 ] && ! python3 scripts/ll-exe.py "$W/$id.ll" -o "$W/$id.exe" $EXX >"$W/$id.b" 2>&1; then st=LLVM; why=$(grep -m1 -i 'error\|invalid\|fail' "$W/$id.b" | cut -c1-110)
    elif [ $WASM = 1 ] && ! { python3 scripts/ll-exe.py "$W/$id.ll" -o "$W/$id" -O1 --triple wasm32-wasi && python3 -m ziglang cc -target wasm32-wasi "$W/$id.o" runtime/wasi/pride_rt.c -o "$W/$id.exe"; } >"$W/$id.b" 2>&1; then st=LLVM; why=$(grep -m1 -i 'error\|invalid\|fail\|undefined' "$W/$id.b" | cut -c1-110)
    else
        want=$(expect_of "$f"); wx=$(exit_of "$f")
        if [ $WASM = 1 ]; then got=$(timeout 20 python3 scripts/wasm-run.py "$W/$id.exe" 2>/dev/null; echo "rc=$?"); else got=$(timeout 5 "$W/$id.exe" 2>/dev/null; echo "rc=$?"); fi; grc=${got##*rc=}; got=${got%rc=*}
        got=${got%$'\n'}   # the header has no trailing newline
        wantd=$(printf '%b' "$want")
        if [ "$grc" = "$wx" ] && { [ -z "$want" ] || [ "$got" = "$wantd" ]; }; then st=PASS
        else st=WRONG; why="exit $grc (want $wx), stdout '$(printf '%s' "$got" | head -c 40)' (want '$(printf '%s' "$wantd" | head -c 40)')"; fi
    fi
    cnt[$st]=$(( ${cnt[$st]:-0} + 1 ))
    printf '%s\t%s\t%s\n' "$id" "$st" "$why" >> "$W/rows.tsv"
    [ "$st" != PASS ] && [ $V = 1 ] && printf '  %-8s %-34s %s\n' "$st" "$id" "$why"
    [ "$st" = PASS ] && [ $V = 1 ] && printf '  %-8s %s\n' PASS "$id"
done
[ -n "$TSV" ] && cp "$W/rows.tsv" "$TSV"
echo "low corpus$([ $FS = 1 ] && echo " (freestanding, no libc)")$([ $WASM = 1 ] && echo " (wasm32-wasi under wasmtime)"): PASS=${cnt[PASS]:-0} FRONT=${cnt[FRONT]:-0} NOLOWER=${cnt[NOLOWER]:-0} VERIFY=${cnt[VERIFY]:-0} LLVM=${cnt[LLVM]:-0} WRONG=${cnt[WRONG]:-0} of ${#files[@]}"
[ "${cnt[VERIFY]:-0}" = 0 ] && [ "${cnt[LLVM]:-0}" = 0 ] && [ "${cnt[WRONG]:-0}" = 0 ]
