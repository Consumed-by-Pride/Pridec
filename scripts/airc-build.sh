#!/bin/bash
# Build `airc` (the C-target driver) with the only c3c reachable in this
# environment, and run it over the AIR 3.0 corpus. Every failure is reported
# with the input that caused it, because the point of this script is to find
# out what the C backend does NOT handle, not to print a green line.
#
#   C3C=/path/to/c3c C3C_LIB=/path/to/lib bash scripts/airc-build.sh [indir]
set -u
cd "$(dirname "$0")/.." || exit 2

C3C=${C3C:-/tmp/c3npm/node_modules/@c3-lang/c3c-linux-x64/c3c}
C3C_LIB=${C3C_LIB:-/tmp/c3npm/node_modules/@c3-lang/c3c-linux-x64/lib}
W=${W:-tmp/airc}
CORPUS=${1:-tests/air3/good}

[ -x "$C3C" ] || { echo "airc-build: no c3c at $C3C" >&2; exit 2; }

rm -rf "$W"; mkdir -p "$W"
W=$(cd "$W" && pwd)   # absolute: the build runs from $W/src and c3c resolves -o there
echo "== shim: pfront + tools/air for c3c 0.6.x =="
python3 scripts/c3c-062-shim.py --dest "$W/src" || exit 1

# The rewrites below are compiler-specific and are the ones the shim cannot
# express safely as text (a struct rename, a keyword whose literal spelling
# matters). They are applied here, visibly, rather than buried.
python3 - "$W/src" <<'PY'
import re, sys
root = sys.argv[1]
p = root + "/pfront/pear_ir/air_c.c3"
s = open(p).read()
# 0.6.2 rejects an all-uppercase type name
# every receiver of a C method, not just the ones written `c.x(...)`
s = re.sub(r"\bstruct C\b", "struct Cx", s)
s = re.sub(r"\bC\s*\*", "Cx*", s)
s = re.sub(r"\bC\.", "Cx.", s)
s = re.sub(r"\bC\*", "Cx*", s)
# `ubyte` does not exist there
s = s.replace("ubyte b = (ubyte)p.bytes[i];", "uint b = (uint)(char)p.bytes[i];")
# `fn` is a keyword there, so the local cannot be called that
s = s.replace("char* fn = rmw_c(op);", "char* rmwf = rmw_c(op);")
s = s.replace("if (fn == null)", "if (rmwf == null)").replace("s.put(fn);", "s.put(rmwf);")
# the keyword table: one more entry than its own loop bound
s = s.replace("static char*[44] kw = {", "static char*[45] kw = {")
s = s.replace("for (usz i = 0; i < 43; i++)", "for (usz ki = 0; ki < 45; ki++)")
s = s.replace("kw[i], s)", "kw[ki], s)")
# r_asm_unit is defined nowhere (a real defect, fixed in the source too)
s = s.replace('r_asm_unit(c)', '(char*)"((pride_unit){0})"')
open(p, "w").write(s)

p = root + "/pfront/pear_ir/air_facts.c3"
s = open(p).read()
# 0.6.2 will not implicitly convert an int to bool for `|=`
s = re.sub(r"changed \|= ([^;]+);", lambda m: "if (%s) { changed = true; }" % m.group(1).strip(), s)
open(p, "w").write(s)
PY

SRC="pfront/pfront_core.c3 pfront/pfront_lex.c3 pfront/pear_ir/air_ir.c3 pfront/pear_ir/air_text.c3 \
pfront/pear_ir/air_util.c3 pfront/pear_ir/air_read.c3 pfront/pear_ir/air_facts.c3 \
pfront/pear_ir/air_c.c3 tools/air/airc.c3"
echo "== build =="
( cd "$W/src" && "$C3C" compile --stdlib "$C3C_LIB" $SRC -o "$W/airc" ) || {
    echo "airc-build: build failed" >&2; exit 1; }
echo "   built $W/airc"

echo "== emit C from every .air in $CORPUS =="
pass=0; fail=0
for f in "$CORPUS"/*.air; do
    [ -e "$f" ] || continue
    n=$(basename "$f" .air)
    if ! "$W/airc" "$f" "$W/$n.c" >"$W/$n.log" 2>&1; then
        fail=$((fail+1)); echo "   EMIT FAIL $n: $(head -1 "$W/$n.log")"; continue
    fi
    if gcc -std=c11 -O0 -w -fsyntax-only "$W/$n.c" 2>"$W/$n.gcc"; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); echo "   C FAIL   $n: $(head -1 "$W/$n.gcc")"
    fi
done
echo "   emitted+compiled: $pass  failed: $fail"
[ "$fail" -eq 0 ]
