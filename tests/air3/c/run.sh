#!/bin/bash
# The C target's OUTPUT is compiled and executed. No c3c, no pfrontc, no .air
# fixture: gcc is the only requirement, so this runs on any machine with a C
# compiler -- which is the whole point of choosing C as the target.
#
#   1. the generated runtime prelude, EXTRACTED FROM air_c.c3's OWN STRING
#      LITERALS (not a hand-written copy), is compiled at -Werror and its syscall
#      path is executed. This is the strongest check available while the emitter
#      itself cannot be built: it tests the exact text air_c prints.
#   2. tests/air3/c/shape_test.c -- the C text for every awkward AIR form, in the
#      shape the emitter prints, with executed checks: -Werror, then ASan+UBSan.
#   3. two mutations of shape_test.c are REQUIRED to fail. A test whose mutations
#      survive is not a test; this repository has learned that twice.
#   4. a char literal must carry the width its AIR type declares, and that width
#      is read out of air_c.c3 -- so the check tracks the emitter instead of
#      restating what the emitter is supposed to do.
#
# Usage: bash tests/air3/c/run.sh
set -u
cd "$(dirname "$0")/../../.." || exit 1
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "test-c-target: no C compiler ($CC)" >&2; exit 1; }

W=tmp/c-target
rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL $*"; }

# ── 1. the prelude, extracted from the emitter's literals ────────────────────
if ! python3 - "$W/prelude.c" <<'PY'
import re, sys
out = sys.argv[1]
src = open("pfront/pear_ir/air_c.c3", encoding="utf-8").read()
# A function DEFINITION, not a prefix of a longer name: `C.preludeX` must not
# satisfy this (mutation-testing this file caught exactly that).
m = re.search(r"^fn void C\.prelude\(C\* c, Sb\* o\)$", src, re.M)
if not m:
    sys.exit("C.prelude is gone: the generated file would not be self-contained")
i = m.start()
# the function body runs to the first line that is exactly "}" at column 0
if "\n}\n" not in src[i:]:
    sys.exit("C.prelude has no end -- the extractor is broken")
j = i + src[i:].index("\n}\n")
lits = re.findall(r'\.put\(\(char\*\)"((?:[^"\\]|\\.)*)"\)', src[i:j])
if not lits:
    sys.exit("no literals found in C.prelude -- the extraction is broken")
text = "".join(lits)
# The prelude must actually define what it is supposed to define, or the check
# below compiles a stub and proves nothing.
for need in ("__pride_syscall1", "__pride_syscall7", "__pride_trap", "pride_usz"):
    if need not in text:
        sys.exit("the extracted prelude does not define %s" % need)
text = re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1), m.group(1)), text)
open(out, "w").write(text + r'''
int main(void)
{
    /* execute the syscall path for real: getpid(39) on x86-64 Linux */
    volatile int64_t pid = __pride_syscall1(39);
    if (!(pid > 0)) return 1;
    volatile int64_t w = __pride_syscall2(39, 0);   /* arity 2 still compiles */
    (void)w;
    if (0) { __pride_trap("x"); }
    if (0) { __pride_ub("y"); }
    return 0;
}
''')
PY
then
    bad "the prelude could not be extracted from air_c.c3 (see above)"
fi
[ -s "$W/prelude.c" ] || bad "prelude extraction produced nothing"
if "$CC" -std=c11 -Wall -Wextra -Werror -O2 "$W/prelude.c" -o "$W/prelude" 2>"$W/prelude.log"; then
    if "$W/prelude"; then ok; else bad "the extracted prelude built but did not run"; fi
else
    bad "the emitted prelude does not compile: $(head -5 "$W/prelude.log" | tr '\n' ' ')"
fi

# ── 2. the shapes, at -Werror and under sanitizers ───────────────────────────
if "$CC" -std=c11 -Wall -Wextra -Werror -O2 -I tests/air3/c tests/air3/c/shape_test.c -o "$W/shape" 2>"$W/shape.log"; then
    if "$W/shape" >"$W/shape.out" 2>&1; then ok; else bad "shape_test failed: $(cat "$W/shape.out")"; fi
else
    bad "shape_test does not compile at -Werror: $(head -5 "$W/shape.log" | tr '\n' ' ')"
fi
if "$CC" -std=c11 -O1 -fsanitize=undefined,address -fno-omit-frame-pointer -I tests/air3/c tests/air3/c/shape_test.c -o "$W/shape_san" 2>"$W/san.log"; then
    if "$W/shape_san" >"$W/san.out" 2>&1; then ok; else bad "shape_test under ASan/UBSan: $(head -5 "$W/san.out" | tr '\n' ' ')"; fi
else
    bad "shape_test does not build with sanitizers: $(head -3 "$W/san.log" | tr '\n' ' ')"
fi

# ── 3. mutations must FAIL ───────────────────────────────────────────────────
# Each mutation is a mistake an emitter would plausibly make. If the check still
# passes, the test is not testing the thing it claims to.
mutate() {   # mutate NAME OLD NEW
    local name="$1" old="$2" new="$3"
    if ! python3 - tests/air3/c/shape_test.c "$W/mut_$name.c" "$old" "$new" <<'PY'

import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s = open(src).read()
if old not in s:
    sys.exit("mutation anchor not found: " + old[:40])
open(dst, "w").write(s.replace(old, new, 1))
PY
    then
        # The mutation could not be applied: the test no longer contains the code
        # this check is about, so it has stopped testing it. That is a failure of
        # the TEST, not a caught mutation. (Learned by mutation-testing this file:
        # the first version counted this as a pass.)
        bad "mutation '$name' could not be applied -- the shape test changed and the check is stale"
        return 0
    fi
    if ! "$CC" -std=c11 -O1 -I tests/air3/c "$W/mut_$name.c" -o "$W/mut_$name" 2>/dev/null; then
        ok; return 0                      # a compile error is also a caught mutation
    fi
    if "$W/mut_$name" >/dev/null 2>&1; then
        bad "mutation '$name' SURVIVED: the shape test does not check it"
    else
        ok
    fi
}

# the lost-copy bug: assign the parallel copy in declaration order
mutate lost_copy \
'    int64_t v0 = nt;      /* vertex: `jump F0(ni, nt, a)` */
    int64_t v1 = ni;
    int64_t v2 = a;
    a = v0; i = v1; b = v2;' \
'    i = ni;
    a = nt;
    b = a;'

# a dropped match case
mutate dropped_case \
'        case 7: y = 700; goto M2;' \
''

# ── 4. a char literal must carry the width its type says it has ──────────────
# air_ll types APRD_CHAR t_char -- i32 -- and prints the code point as a bare
# number, so the emitted value and the emitted type are the same width. air_c
# has to keep that agreement: if the cast on the literal and the C type printed
# for ATYP_CHAR ever diverge, every char comparison is decided by C's usual
# arithmetic conversions instead of by AIR's typing, and gcc will not say a word.
# So both are read out of air_c.c3 and compared to each other, not to a copy.
if ! python3 - "$W" <<'PY'
import re, sys
src = open("pfront/pear_ir/air_c.c3").read()

# what C.ty prints for ATYP_CHAR
m = re.search(r"case ATYP_CHAR: o\.put\(\(char\*\)\"([^\"]+)\"\);", src)
if not m: sys.exit("C.ty no longer prints a type for ATYP_CHAR")
char_c_ty = m.group(1)

# what the char-literal arm casts to, and what it keeps as its AIR type
m = re.search(r"case APRD_CHAR:\s*\{(.*?)\n        \}", src, re.S)
if not m: sys.exit("the APRD_CHAR arm is gone from air_c.c3")
arm = m.group(1)
cm = re.search(r"\(\(([A-Za-z_][A-Za-z0-9_]*)\)\"\); o\.int_\(p\.ival\)", arm)
if not cm: sys.exit("the char arm no longer prints a cast around the code point")
lit_cast = cm.group(1)

if lit_cast != char_c_ty:
    sys.exit("the char literal is cast to %s but its type prints as %s: the "
             "value and the type disagree in width" % (lit_cast, char_c_ty))

# and the producer must carry that type, or binop refuses the operand
if not re.search(r"case APRD_CHAR:\s*\{[^}]*v\.ty = c\.m\.t_char", src, re.S):
    sys.exit("C.prd leaves APRD_CHAR untyped: binop cannot see an operand type")
open(sys.argv[1] + "/char_arm.txt", "w").write(arm)
PY
then
    bad "the char literal and its AIR type no longer agree in width"
fi

# The C semantics that agreement buys: a code point compared at the type's own
# width answers correctly for both signednesses of the byte it meets.
cat > "$W/char_width.c" <<'CEOF'
#include <stdint.h>
int main(void)
{
    volatile int8_t  sb = (int8_t)0xC3;      /* AIR i8: -61 */
    volatile uint8_t ub = (uint8_t)0xC3;     /* AIR u8: 195 */
    /* the literal at the char type's width, then converted to the operand */
    if (!(sb == ((int8_t)((uint32_t)195))))  { return 1; }
    if (!(ub == ((uint8_t)((uint32_t)195)))) { return 2; }
    /* and the trap: the same number at a NARROWER type is a different value */
    if (((uint32_t)195) == ((uint8_t)195)) { } else { return 3; }
    return 0;
}
CEOF
if "$CC" -std=c11 -O2 -Wall -Wextra -Wtype-limits -Werror "$W/char_width.c" -o "$W/char_width" 2>"$W/char_width.log"; then
    if "$W/char_width"; then ok; else bad "a char literal at its type's width gave the wrong answer"; fi
else
    bad "the char-width shape does not compile: $(head -3 "$W/char_width.log" | tr '\n' ' ')"
fi

if [ $fail -ne 0 ]; then
    echo "test-c-target: $pass passed, $fail failed"
    exit 1
fi
echo "PASS: C target -- prelude compiled from the emitter's own literals and executed;"
echo "      10 shape checks at -Werror and under ASan/UBSan; 2 mutations caught;"
echo "      char literals carry the width their type declares"
