#!/bin/bash
# AIR 3.0 (low profile) reference-consumer tests: docs/specs/AIR3.md.
#   good/*.air : `// EXIT: N` first line. verify-low must pass, airtool emit-ll + scripts/ll-exe.py
#                must build it, and the executable must exit with N (low 8 bits).
#   bad/*.air  : `// ERROR: text` first line. verify-low (or the reader) must FAIL and mention the text.
#   lowered/   : (generated) every program of the working corpus that pfrontc --emit-air-low compiles
#                is built and run the same way; the expected exit code comes from the program's own
#                `-- EXIT:`/`-- EXPECT:` header and the list of known gaps is tests/air3/KNOWN.tsv.
set -u
cd "$(dirname "$0")/../.."
AT="${1:-tmp/airtool}"
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
W=tmp/air3-test; rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
for f in tests/air3/good/*.air; do
    n=$(basename "$f" .air); want=$(head -1 "$f" | sed 's#^// EXIT: ##')
    "$AT" verify-low "$f" >"$W/$n.vlog" 2>&1 || { bad "good/$n: verify-low: $(head -1 "$W/$n.vlog")"; continue; }
    "$AT" emit-ll "$f" -o "$W/$n.ll" >"$W/$n.log" 2>&1 || { bad "good/$n: emit-ll: $(head -1 "$W/$n.log")"; continue; }
    python3 scripts/ll-exe.py "$W/$n.ll" -o "$W/$n.exe" >"$W/$n.blog" 2>&1 || { bad "good/$n: ll-exe: $(head -1 "$W/$n.blog")"; continue; }
    "$W/$n.exe" >/dev/null 2>&1; got=$?
    [ "$got" = "$((want & 255))" ] || { bad "good/$n: exit $got, expected $want"; continue; }
    ok
done
for f in tests/air3/bad/*.air; do
    n=$(basename "$f" .air); want=$(head -1 "$f" | sed 's#^// ERROR: ##')
    if "$AT" verify-low "$f" >"$W/$n.log" 2>&1; then bad "bad/$n: accepted"; continue; fi
    grep -qF -- "$want" "$W/$n.log" || { bad "bad/$n: error does not mention '$want': $(head -1 "$W/$n.log")"; continue; }
    ok
done
# bad_verify/*.air: `airtool verify` (the AIR-level V5 rules, no LLVM) must fail and mention the text
for f in tests/air3/bad_verify/*.air; do
    n=$(basename "$f" .air); want=$(head -1 "$f" | sed 's#^// ERROR: ##')
    if "$AT" verify "$f" >"$W/v_$n.log" 2>&1; then bad "bad_verify/$n: accepted"; continue; fi
    grep -qF -- "$want" "$W/v_$n.log" || { bad "bad_verify/$n: error does not mention '$want': $(head -1 "$W/v_$n.log")"; continue; }
    ok
done
# every good/*.air must also pass the AIR-level verifier and the lint
for f in tests/air3/good/*.air; do
    n=$(basename "$f" .air)
    "$AT" verify "$f" >"$W/gv_$n.log" 2>&1 || { bad "good/$n: verify: $(head -1 "$W/gv_$n.log")"; continue; }
    "$AT" lint "$f" >"$W/gl_$n.log" 2>&1 || { bad "good/$n: lint: $(head -c 100 "$W/gl_$n.log")"; continue; }
    ok
done
echo "air3 tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
