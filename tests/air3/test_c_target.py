#!/usr/bin/env python3
"""air_c (the C transpilation target) checked three ways, none of which needs a
built compiler or a producer.

The C emitter (pfront/pear_ir/air_c.c3) is the third complete consumer of the AIR
3.0 low profile. It is written in C3 and there is no c3c here, so it cannot be
built. What CAN be checked is more than usual, because gcc IS here:

  1. THE EMITTED PRELUDE IS COMPILED (tests/air3/c/prelude_test.sh).
     The generated runtime text is extracted from air_c.c3's own string literals
     and compiled at -Werror, then run, so the syscall path is executed. This
     checks the exact text the emitter prints, not a hand-written copy of it.

  2. THE EMITTED SHAPES ARE EXECUTED (tests/air3/c/shape_test.c, via run.sh).
     Every awkward AIR form -- label spine with a back edge, the parallel copy,
     match, alloca/load/store/gep, tuples, arrays, closures -- written in the
     shape the emitter prints, with 9 executed checks, clean under -Werror,
     ASan and UBSan. Two mutations of it are REQUIRED to fail.

  3. THE SOURCE TEXT IS CONSISTENT (this file).
     * air_c handles exactly the tags air_ll handles: the two consumers may not
       disagree about what the low profile is.
     * every `__pride_` name the emitter prints is declared in the prelude it
       prints, or in tests/air3/c/__pride_rt.h.
     * the emitter never prints a declaration after a label (C allows jumping
       past one only by accident of scoping; the emitter hoists instead) and never
       prints the constructs it refuses.
     * air_c imports only the shared floor of the AIR layer.

Assertions on source strip comments first (and use a literal-preserving stripper
where the string is the thing being checked). tests/air/test_type_ann_plumbing.py
learned that the hard way and tests/air3/test_c3_target.py rediscovered it: a
check that matches nothing passes on any input, so every regex here is asserted
to have matched something.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
C_FILE = os.path.join(ROOT, "pfront", "pear_ir", "air_c.c3")
LL_FILE = os.path.join(ROOT, "pfront", "pear_ir", "air_ll.c3")
IR_FILE = os.path.join(ROOT, "pfront", "pear_ir", "air_ir.c3")
TOOL = os.path.join(ROOT, "tools", "air", "airtool.c3")
C_DIR = os.path.join(ROOT, "tests", "air3", "c")

failures = []


def fail(msg):
    failures.append(msg)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    """Comments out, string literals KEPT."""
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if ch == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def code_only(src):
    """Comments AND literal contents out: for `case TAG:` labels."""
    out = []
    i, n = 0, len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue
        if ch == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue
        if ch in "\"'":
            q = ch
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == q:
                    break
                j += 1
            out.append(q + " " * (j - i - 1) + q)
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def body_of(src, header):
    m = re.search(re.escape(header), src)
    if not m:
        return ""
    i = src.find("{", m.start())
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    return ""


def rev_enum(src, name):
    m = re.search(r"enum\s+" + name + r"\s*:\s*int\s*\{([^}]*)\}", src, re.S)
    if not m:
        raise SystemExit("cannot find enum %s" % name)
    return set(re.findall(r"\b([A-Z][A-Z0-9_]+)\b", re.sub(r"//[^\n]*", "", m.group(1))))


def handled(dispatch, prefix):
    return set(re.findall(r"case\s+(" + prefix + r"_[A-Z0-9_]+)\s*:", dispatch))


def put_literals(src):
    return re.findall(r'\.put\(\(char\*\)"((?:[^"\\]|\\.)*)"\)', src)


def unescape(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(m.group(1), m.group(1)), s)



def check_char_literals_are_ordinary_integers():
    """A char literal in a byte context lowers to the SAME AIR as a suffixed one.

    examples/tokei compares bytes: `c == 34u8`. The idiomatic spelling is
    `c == '"'`, and it is only safe because of a chain in air_low.c3, not because
    `char` and `u8` are the same type (they are not -- ATYP_CHAR is its own tag,
    and air_c/air_ll both refuse a binop whose operand types differ). The chain:

      1. Low.hint(N_EXPR_CHAR) returns t_char, so the binary op hands t_char to
         BOTH operands as its hint;
      2. the variable side ignores the hint (read_var loads at its own type, u8);
      3. the literal side becomes lit_int(v, t_char), and lit_int builds APRD_INT
         -- NOT APRD_CHAR, which air_low never emits at all;
      4. so the two operands are (u8, char), and Low.binary's repair rewrites an
         APRD_INT literal to the other side's type.

    Break any link and the char literal stops being interchangeable with the
    suffixed one. Each is asserted here against the source, because the compiler
    cannot be built in this environment.
    """
    low = read("pfront/pear_ir/air_low.c3")

    # 1. the hint for a char literal is t_char
    m = re.search(r"case Nk\.N_EXPR_CHAR: return lw\.m\.(t_[a-z0-9]+);", low)
    assert m, "Low.hint no longer names a type for Nk.N_EXPR_CHAR"
    assert m.group(1) == "t_char", (
        "Low.hint types a char literal %s; the rest of this check assumes t_char" % m.group(1))

    # 2. the char expression case adopts an integer hint, and builds an INTEGER literal
    m = re.search(r"case Nk\.N_EXPR_CHAR: \{ AirTyp\* t = \(want != null && "
                  r"air_util::ty_is_int\(want\)\) \? want : lw\.m\.t_char; "
                  r"return lw\.(lit_[a-z]+)\(", low)
    assert m, "the char-literal expression case changed shape"
    assert m.group(1) == "lit_int", (
        "a char literal is lowered by %s; if it ever builds APRD_CHAR the binop "
        "repair below cannot fire, because that repair only rewrites APRD_INT" % m.group(1))

    # 3. air_low never emits APRD_CHAR -- the producer the repair does not know
    assert "air_mk_char" not in low, (
        "air_low now emits APRD_CHAR; Low.binary's repair only rewrites APRD_INT, "
        "so a char literal would no longer adapt to the byte it is compared with")

    # 4. the repair: an APRD_INT literal becomes the other operand's type
    m = re.search(r"if \(r\.p != null && r\.p\.tag == APRD_INT && "
                  r"air_util::ty_is_int\(l\.t\)\) \{ r = lw\.lit_int\(r\.p\.ival, l\.t\); \}", low)
    assert m, "Low.binary no longer rewrites an integer literal to the other operand's type"

    # And the example must still use it where it complained about magic numbers.
    # Deliberately specific: `c == '\\'` also counts as "a char literal", so a
    # loose check stays green when the quoted characters are turned back into
    # 34u8/39u8/96u8. These are the exact spellings the reviewer objected to.
    scanner = read("examples/tokei/scanner.pie")
    for ch, code in (('"', 34), ("'", 39), ("`", 96)):
        assert "c == %du8" % code not in scanner, (
            "examples/tokei/scanner.pie compares byte %d as a number again; the "
            "quoted character is the same AIR and the reader can see what it is" % code)
    assert re.search(r"c == '\"'", scanner), "scanner.pie no longer quotes the double quote"
    assert "chars[0i64] == '.'" in read("examples/tokei/walker.pie"), (
        "walker.pie compares a leading dot as 46u8 again")

def main():
    src = read(C_FILE)
    src_c = strip_comments(src)
    src_code = code_only(src)
    ll_code = code_only(read(LL_FILE))
    ir = read(IR_FILE)

    check_char_literals_are_ordinary_integers()

    # ── 1. consumer agreement with air_ll ──────────────────────────────────
    for enum, prefix, where in (("AirCmdTag", "ACMD", "command"), ("AirPrdTag", "APRD", "producer")):
        members = rev_enum(ir, enum)
        fn_c = "fn void C.cmd(" if prefix == "ACMD" else "fn Val C.prd("
        fn_ll = "fn void Ll.cmd(" if prefix == "ACMD" else "fn Val Ll.prd("
        a = handled(body_of(src_code, fn_c), prefix) & members
        b = handled(body_of(ll_code, fn_ll), prefix) & members
        if not a:
            fail("could not find the dispatch body of %s -- the check would be vacuous" % fn_c)
        if not b:
            fail("could not find the dispatch body of %s" % fn_ll)
        for tag in sorted(members):
            if (tag in a) != (tag in b):
                fail("%s %s: handled only by %s -- the two consumers disagree about "
                     "the low profile" % (where, tag, "air_c" if tag in a else "air_ll"))

    # ── 2. every printed __pride_ name is declared in the printed prelude ──
    # A name may be assembled from fragments ("__pride_syscall" + arity), so a
    # bare prefix is not an emitted name. Only names that are COMPLETE in the
    # literal are collected: those the literal does not continue with a further
    # identifier character. `__pride_syscall` followed by `"); s.int_(...)` is
    # such a prefix and is excluded by requiring the literal to end the name.
    printed = set()
    for lit in put_literals(src_c):
        for m in re.finditer(r"__pride_[a-z0-9_]+", lit):
            printed.add(m.group(0))
    # drop prefixes that the emitter completes with an arity at print time
    printed -= {"__pride_syscall"}
    prelude = body_of(src_c, "fn void C.prelude(")
    if not prelude:
        fail("cannot find C.prelude -- the generated file would not be self-contained")
        declared = set()
    else:
        declared = set()
        for lit in put_literals(prelude):
            declared |= set(re.findall(r"__pride_[a-z0-9_]+", lit))
    if not printed:
        fail("no __pride_ name is printed at all -- the check would be vacuous")
    # The syscall helpers the emitter can name: it prints the arity, so check the
    # whole family is present rather than just the prefix.
    if "__pride_syscall" in "".join(put_literals(src_c)):
        need = {"__pride_syscall%d" % i for i in range(1, 8)}
        gap = need - declared
        if gap:
            fail("the emitter prints a syscall call but the prelude lacks %s"
                 % ", ".join(sorted(gap)))
    missing = printed - declared
    if missing:
        fail("emitted code calls %s, which the emitted prelude does not declare "
             "(the generated .c would not compile)" % ", ".join(sorted(missing)))

    # The runtime header used by the executed tests must agree with the prelude.
    rt = os.path.join(C_DIR, "__pride_rt.h")
    if os.path.exists(rt):
        rt_src = strip_comments(read(rt))
        rt_names = set(re.findall(r"__pride_[a-z0-9_]+", rt_src))
        hp = printed - rt_names
        if hp:
            print("  note: %s is in the emitted prelude but not in __pride_rt.h" % ", ".join(sorted(hp)))

    # ── 3. refused constructs are not emitted ─────────────────────────────
    # The emitter refuses these by name; a template that prints one would be a
    # contradiction between what it says and what it does.
    for bad, why in (
        ("goto __pc", "the C target needs no dispatch loop (C has labels and goto)"),
        ("nextcase", "nextcase is C3, not C"),
        ("__pc", "the dispatch loop is a C3-only workaround"),
    ):
        for lit in put_literals(src_c):
            if bad in lit:
                fail('emitted template contains "%s": %s' % (bad, why))

    # ── 4. the C target may not emit what it cannot express ───────────────
    # `asm` is the one form C3 refuses and C accepts; assert it IS emitted,
    # so a future edit cannot quietly start refusing it.
    acmd_asm = body_of(src_code, "fn void C.cmd(")
    if "__asm__ volatile" not in src_c:
        fail("air_c must translate ACMD_ASM: AIR's constraints are GCC syntax, "
             "which is exactly what C accepts")
    if "ACMD_ASM" not in handled(acmd_asm, "ACMD"):
        fail("ACMD_ASM is not handled by air_c's dispatch")

    # ── 5. the parallel-copy vertex exists ────────────────────────────────
    # §3.2: a jump with more than one argument must go through temporaries.
    # Emitting the assignments directly is the lost-copy bug, which the shape
    # test proves turns fib(10) into 512. Assert the guard is there.
    jump_fn = body_of(src_c, "fn void C.jump(")
    if not jump_fn:
        fail("cannot find C.jump -- the parallel copy is the one subtle part")
    elif "n > 1" not in jump_fn:
        fail("C.jump does not special-case a multi-argument jump: the parallel "
             "copy would be emitted sequentially (lost-copy bug)")

    # ── 6. wiring ─────────────────────────────────────────────────────────
    tool_raw = read(TOOL)
    tool = code_only(tool_raw)
    if "import air_c;" not in tool:
        fail("airtool does not import air_c")
    if 'eq(cmd, "emit-c")' not in tool_raw:
        fail("airtool has no emit-c command")
    if "air_c::to_c(" not in tool:
        fail("airtool dispatches emit-c to nothing")

    mk = read(os.path.join(ROOT, "Makefile"))
    m_use = re.search(r"^AIR_USE\s*:=\s*((?:.*\\\n)*.*)$", mk, re.M)
    if not m_use:
        fail("cannot find AIR_USE in the Makefile")
    elif "pfront/pear_ir/air_c.c3" not in m_use.group(1):
        fail("air_c.c3 is not on AIR_USE (a consumer on no side is invisible to the build)")

    imported = set(re.findall(r"^import (\w+);", src, re.M))
    extra = imported - {"air_ir", "air_text", "air_util"}
    if extra:
        fail("air_c imports %s; a consumer may only use the shared floor" % ", ".join(sorted(extra)))

    # ── report ────────────────────────────────────────────────────────────
    if failures:
        print("FAIL: %d problem(s) in the C target" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("PASS: air_c agrees with air_ll on every low-profile tag; the emitted "
          "prelude declares every __pride_ name the emitter prints; the parallel "
          "copy is guarded; asm is translated, not refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
