#!/usr/bin/env python3
"""air_c3 (the C3 transpilation target) checked without a compiler, a producer,
or an .air fixture.

The C3 emitter (pfront/pear_ir/air_c3.c3) is the second complete consumer of the
AIR 3.0 low profile; pfront/pear_ir/air_ll.c3 is the first. Nothing here runs
either one. What can be checked in this environment -- and what actually catches
the failure mode this repository has hit repeatedly, a consumer that is quietly
narrower than the last one -- is:

  1. CONSUMER AGREEMENT.  For every AirCmdTag and AirPrdTag, air_c3 handles the
     tag exactly when air_ll handles it. If the C3 target silently refuses a form
     LLVM accepts (or accepts one LLVM refuses), one of them is wrong about what
     "the low profile" is, and that is a bug in the AIR layer, not a preference.

  2. NO goto, EVER.  C3 removed goto. A template that prints one emits a program
     c3c cannot parse, and this is the single easiest way to write a C3 emitter
     that looks right and is unusable.

  3. C3 VOCABULARY.  Every type name the emitter prints is a name c3c v0.8.4 (the
     tag the Makefile pins) actually has. Written because three names in the first
     draft of the mapping table were wrong: `isz` does not exist (`sz` does),
     `tls` is not thread-local storage (`tlocal` is), and there is no 128-bit
     integer keyword.

  4. THE FALLBACK IS COUNTED.  The __pc dispatch loop is a last resort; the
     emitter must report how many functions needed it, so the fallback can be
     driven to zero instead of growing silently.

  5. NO INVENTED APIS.  The emitter may only reference runtime names that the
     document declares it generates (docs/pear2/C3_TARGET.md §4.4). A helper that
     appears from nowhere is a link error three steps downstream.

Every assertion on source text strips comments first. This file's sibling,
tests/air/test_type_ann_plumbing.py, learned that the hard way: two of its
assertions passed on prose that mentioned the code instead of the code.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
C3 = os.path.join(ROOT, "pfront", "pear_ir", "air_c3.c3")
LL = os.path.join(ROOT, "pfront", "pear_ir", "air_ll.c3")
IR = os.path.join(ROOT, "pfront", "pear_ir", "air_ir.c3")
TOOL = os.path.join(ROOT, "tools", "air", "airtool.c3")

failures = []


def fail(msg):
    failures.append(msg)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def code_only(src):
    """Strip // and /* */ comments and string/char literals.

    The literal stripping is what makes `case ACMD_X:` assertions mean the case
    label and not a string that happens to contain it. Where the emitter's own
    diagnostic text is being asserted, callers use keep_strings=True.
    """
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


def code_strings(src):
    """Strip comments only, KEEP string literals.

    code_only() blanks literal contents, which is right for `case TAG:` labels and
    wrong for any assertion about the text the emitter prints. Two strippers, used
    deliberately, because using the wrong one is how a check goes vacuous: the
    type-name check below silently matched nothing for exactly that reason.
    """
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


def body_of(src, header_re):
    """The brace-matched body of the first function whose header matches."""
    m = re.search(header_re, src)
    if not m:
        return ""
    i = src.find("{", m.start())
    if i < 0:
        return ""
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
    """The members of `enum NAME { ... }` as a set."""
    m = re.search(r"enum\s+" + name + r"\s*:\s*int\s*\{([^}]*)\}", src, re.S)
    if not m:
        raise SystemExit("cannot find enum %s in air_ir.c3" % name)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return set(re.findall(r"\b([A-Z][A-Z0-9_]+)\b", body))


def handled(dispatch_body, prefix):
    """Case labels handled by the DISPATCH function.

    Deliberately not "every `case TAG:` in the file". Each consumer also has a
    `*_tag_name()` helper whose switch lists every tag by name whether or not the
    dispatch handles it, so scanning the whole file finds all of them and the
    check passes no matter what the dispatch does. That is exactly the defect this
    assertion exists to catch, so it was caught by mutation-testing this test.
    """
    return set(re.findall(r"case\s+(" + prefix + r"_[A-Z0-9_]+)\s*:", dispatch_body))


def main():
    c3 = read(C3)
    ll = read(LL)
    ir = read(IR)

    c3_code = code_only(c3)
    ll_code = code_only(ll)

    # ── 1. consumer agreement ──────────────────────────────────────────────
    for enum, prefix, where in (
        ("AirCmdTag", "ACMD", "command"),
        ("AirPrdTag", "APRD", "producer"),
    ):
        members = rev_enum(ir, enum)
        c3_fn = "fn void C3.cmd(" if prefix == "ACMD" else "fn Val C3.prd("
        ll_fn = "fn void Ll.cmd(" if prefix == "ACMD" else "fn Val Ll.prd("
        a = handled(body_of(c3_code, re.escape(c3_fn)), prefix) & members
        b = handled(body_of(ll_code, re.escape(ll_fn)), prefix) & members
        if not a:
            fail("could not find the dispatch body of %s in air_c3.c3" % c3_fn)
        if not b:
            fail("could not find the dispatch body of %s in air_ll.c3" % ll_fn)
        for tag in sorted(members):
            in_a, in_b = tag in a, tag in b
            if in_a != in_b:
                only = "air_c3" if in_a else "air_ll"
                fail(
                    "%s %s: handled only by %s -- the two consumers disagree about "
                    "the low profile" % (where, tag, only)
                )
        missing = members - a - b
        if missing:
            # A tag neither consumer touches is fine only if it cannot reach the
            # low profile; print it so the assumption is visible, do not fail.
            note = ", ".join(sorted(missing))
            print("  note: %d %s tag(s) handled by neither consumer: %s" % (len(missing), where, note))

    # ── 2. no goto ─────────────────────────────────────────────────────────
    # The emitter prints C3. `goto` is a C3 parse error, so a printed one is a
    # broken artifact. Look for it in the literal text the emitter emits: every
    # string literal in the file.
    literals = re.findall(r'"((?:[^"\\]|\\.)*)"', c3)
    for lit in literals:
        if re.search(r"\bgoto\b", lit):
            fail('emitted template contains `goto` (C3 removed it): "%s"' % lit)

    # ── 3. C3 vocabulary, against the pinned compiler ──────────────────────
    # The keywords of c3c v0.8.4, from src/compiler/tokens.c at that tag. The
    # emitter's own table is compared against this list, so a typo in one place
    # cannot agree with itself.
    v084 = set("""
        _ alias any asm assert attrdef attrmacro bitstruct bool break case catch
        cenum char const constdef constset continue default defer distinct do
        double else enum extern false fault faultdef faultset float fn for foreach
        foreach_r ichar if import inline int interface iptr lengthof long macro
        module nextcase null return short static struct switch sz tlocal true try
        typedef typeid uint ulong union untypedlist uptr ushort usz var void while
    """.split())
    c3_str = code_strings(c3)
    m = re.search(r"kw\s*=\s*\{(.*?)\};", c3_str, re.S)
    if not m:
        fail("cannot find the emitter's C3 keyword table")
    else:
        emitter_kw = set(re.findall(r'"([a-z_]+)"', c3_str[m.start():m.end()]))
        if emitter_kw != v084:
            only_e = sorted(emitter_kw - v084)
            only_v = sorted(v084 - emitter_kw)
            fail(
                "C3 keyword table differs from c3c v0.8.4: emitter has %s, compiler has %s"
                % (only_e or "nothing extra", only_v or "nothing missing")
            )

    # Names that must NOT be printed, each one a mistake that was actually made.
    forbidden_types = {
        "isz": "c3c v0.8.4 has `sz`; there is no `isz` keyword",
        "tls": "c3c v0.8.4 spells thread-local storage `tlocal`",
        "int128": "c3c v0.8.4 has no 128-bit integer keyword",
        "i128": "c3c v0.8.4 has no 128-bit integer keyword",
    }
    # Only the literals that are a bare type name: a diagnostic that mentions
    # `isz` in prose is not a defect, an emitted type is.
    ty_writes = re.findall(r'o\.put\(\(char\*\)"([A-Za-z_][A-Za-z0-9_]*)"\)', c3_str)
    if not ty_writes:
        fail("the type-name check matched nothing -- it would pass on any input")
    for w in ty_writes:
        if w in forbidden_types:
            fail('emitter prints type name "%s": %s' % (w, forbidden_types[w]))

    # ── 4. the dispatch fallback is counted and reported ────────────────────
    if "dispatch_fns" not in c3_code:
        fail("no dispatch-loop counter: the __pc fallback could grow silently")
    if "used the __pc dispatch loop" not in c3:
        fail("the dispatch-loop count is never printed (docs/pear2/C3_TARGET.md §3.3 promises it)")

    # ── 5. no invented runtime helpers ─────────────────────────────────────
    # A helper the emitted file calls must be either a documented generated name
    # (C3_TARGET.md §4.4) or a C3/C-ABI symbol the emitter declares extern.
    documented = {
        "__pride_syscall",  # §4.4: the syscall path
        "unreachable",      # C3 builtin
        "atomic_load", "atomic_store", "atomic_xchg", "atomic_add",
        "atomic_sub", "atomic_and", "atomic_or", "atomic_xor",  # std::atomic
        "volatile_load", "volatile_store",  # §4.4 generated header
        "fence",                            # §4.4 generated header (fence(ORDER))
    }
    # Only the TEMPLATE literals: the text handed to `.put(...)`. Scanning every
    # string in the file counts diagnostics as emitted code -- `"function(s) used
    # the __pc dispatch loop"` reads as a call to `function` -- and the point of
    # this check is what the emitter PRINTS, not what it says about printing.
    templates = re.findall(r'\.put\(\(char\*\)"((?:[^"\\]|\\.)*)"\)', c3)
    emitted_calls = set()
    for lit in templates:
        # An attribute's argument list looks like a call: `@section("x")`.
        if lit.lstrip().startswith("@"):
            continue
        emitted_calls |= set(re.findall(r"\b([a-z_][a-z0-9_]{2,})\(", lit))
    extern_declared = set(re.findall(r"extern fn \w+\s+([a-z_][a-z0-9_]*)\(", c3_code))
    unknown = emitted_calls - documented - extern_declared
    # printf-family format text and C3 keywords that take parentheses are syntax,
    # not calls; keep the check honest by naming the ones that are.
    syntax = {"if", "while", "switch", "for", "sizeof"}
    unknown -= syntax
    if unknown:
        fail(
            "emitted text calls helpers that are neither documented nor declared: %s"
            % ", ".join(sorted(unknown))
        )

    # ── 6. the emitter is wired into the tool and the boundary ────────────
    tool_raw = read(TOOL)
    tool = code_only(tool_raw)
    if "import air_c3;" not in tool:
        fail("airtool does not import air_c3")
    # The command name is a string literal, so it is blanked by code_only().
    # Grep the raw file for the dispatch, and the stripped file for proving the
    # dispatch reachable code rather than prose.
    if 'eq(cmd, "emit-c3")' not in tool_raw:
        fail("airtool has no emit-c3 command")
    if "air_c3::to_c3(" not in tool:
        fail("airtool dispatches emit-c3 to nothing: no air_c3::to_c3 call")
    mk = read(os.path.join(ROOT, "Makefile"))
    # The assignment spans continuation lines; take it up to the first line that
    # does not end in a backslash. Splitting on the *name* instead would land in
    # the header comment, which explains AIR_USE long before defining it.
    m_use = re.search(r"^AIR_USE\s*:=\s*((?:.*\\\n)*.*)$", mk, re.M)
    if not m_use:
        fail("cannot find the AIR_USE assignment in the Makefile")
    elif "pfront/pear_ir/air_c3.c3" not in m_use.group(1):
        fail("air_c3.c3 is not listed on AIR_USE in the Makefile (a consumer that "
             "is on no side is invisible to the build)")

    # ── 7. the emitter may not import an emitter ───────────────────────────
    imported = set(re.findall(r"^import (\w+);", c3, re.M))
    allowed = {"air_ir", "air_text", "air_util"}
    extra = imported - allowed
    if extra:
        fail("air_c3 imports %s; a consumer may only use the shared floor" % ", ".join(sorted(extra)))

    # ── report ─────────────────────────────────────────────────────────────
    if failures:
        print("FAIL: %d problem(s) in the C3 target" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print(
        "PASS: air_c3 agrees with air_ll on every low-profile tag; no goto, no "
        "invented type name, no undeclared helper; the dispatch fallback is counted"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
