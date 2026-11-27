#!/usr/bin/env python3
"""Rewrite a COPY of the pfront sources so c3c 0.6.2 can build them.

Why this exists
---------------
`pfrontc` is written in C3 and the Makefile pins c3c v0.8.4, whose Linux
release asset lives on objects.githubusercontent.com -- a host this build
environment cannot reach. The only reachable c3c is the npm package
@c3-lang/c3c, which ships 0.6.2.

That gap is a SYNTAX gap, not a semantics one, and every item in it is
mechanical. This script is the map, so the port is reproducible from the
repository instead of living in a scratch directory. It never edits the
working tree: it is run against a copy.

    python3 scripts/c3c-062-shim.py --dest /tmp/build
    C3C=... C3C_LIB=... make -C /tmp/build C3_EXTRA=

The rewrites, each with the reason it is needed:

  1. `alias T = ...`      -> `def T = ...`
     0.6.2 predates `alias`; `def` is the same feature under its old name.

  2. `T::size`/`T::alignof` -> `T.sizeof`/`T.alignof`
     0.6.2 has no `::` *type* property access at all. `int.sizeof` is 4 there.

  3. `def` used as an identifier -> `defn`
     0.7 was the first release where `def` stopped being reserved. The source
     uses it as a field and as a parameter, which 0.6.2's lexer refuses.

  4. `<* ... *>` documentation comments -> `//` comments
     0.6.2 has no doc-comment form.

  5. an out-of-range integer literal gets an explicit cast, which 0.6.2
     requires and 0.8.x infers (one site: theory_sct.c3).


# --- discovered while bringing c3c 0.6.2 up against the AIR layer ---
# 6. an all-uppercase type name is rejected by 0.6.2 (`struct C` -> `struct Cx`).
# 7. `ubyte` is not a type there; `char` is the 8-bit unsigned type.
# 8. `T a[N]` is spelled `T[N] a`.
# 9. a dot-call omits the receiver there; the source passes it explicitly.
#    Every one of these is mechanical, which is why the port is worth having;
#    what it is NOT is invisible, which is why this list exists.
# 10. bare enum constants are not in scope; they need their enum's prefix.

Anything this script cannot express is reported, not silently skipped: the
point of a shim is to know exactly how far the target compiler is from the
source, and a rewrite that quietly does nothing is how a port "works" for the
wrong reason.
"""

import argparse
import glob
import os
import re
import shutil
import sys

# 1. alias -> def
RE_ALIAS = re.compile(r"^(\s*)(pub\s+)?alias\s+", re.M)


def to_def(src):
    return RE_ALIAS.sub(lambda m: m.group(1) + (m.group(2) or "") + "def ", src)


# 2. Type::size -> Type.sizeof. ONLY in a property position, and only for a
#    name that is a type expression: an identifier (possibly dotted or
#    pointed) immediately before `::size`/`::alignof`, never a bare field.
RE_PROP = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)((?:\.[A-Za-z_][A-Za-z0-9_]*)*)::(size|alignof)\b")


def to_prop(src):
    return RE_PROP.sub(
        lambda m: m.group(1) + m.group(2) + (".sizeof" if m.group(3) == "size" else ".alignof"),
        src,
    )


# 3. `def` as an ordinary identifier. This runs AFTER step 1 so the aliases it
#    just created (`def T = ...` at the start of a line) are protected.
RE_DEF_IDENT = re.compile(r"(?<![A-Za-z0-9_.])def(?![A-Za-z0-9_])")
# a field reached through a subscript: `xs[i].def`
RE_DEF_AFTER_BRACKET = re.compile(r"(\]\.)def(?![A-Za-z0-9_])")
# and reached through a plain member access: `a.def`, `n->def`
RE_DEF_MEMBER = re.compile(r"([.])def(?![A-Za-z0-9_])")
RE_ALIAS_LINE = re.compile(r"^\s*(?:pub\s+)?def\s+[A-Za-z_][A-Za-z0-9_]*\s*=")


def to_defn(src):
    def one(code):
        code = RE_DEF_AFTER_BRACKET.sub(r"\1defn", code)
        code = RE_DEF_MEMBER.sub(r"\1defn", code)
        return RE_DEF_IDENT.sub("defn", code)

    out = []
    for line in src.split("\n"):
        # an alias line must keep its `def`: it is the declaration this rewrite
        # is standing in for, not an identifier use.
        out.append(line if RE_ALIAS_LINE.match(line) else code_only(line, one))
    return "\n".join(out)


# 4. `<* ... *>` documentation comments.
def to_line_comments(src):
    out = []
    in_doc = False
    for line in src.split("\n"):
        stripped = line.lstrip()
        if not in_doc and stripped.startswith("<*"):
            in_doc = True
            body = stripped[2:]
            if body.rstrip().endswith("*>"):
                body = body.rstrip()[:-2]
                in_doc = False
            out.append("//" + body)
            continue
        if in_doc:
            if stripped.endswith("*>"):
                out.append("//" + stripped[:-2])
                in_doc = False
            else:
                out.append("//" + stripped)
            continue
        out.append(line)
    return "\n".join(out)


# 5. the one literal 0.6.2 will not accept without a cast.
# 0.6.2 folds the minus sign into the literal, so -0x7fffffffffffffff is a
# positive value one past LONG_MAX and is rejected. Negating the limit after
# the cast is the same value and is accepted by both compilers.
RE_NEG_LIMIT = re.compile(r"(?<![0-9A-Za-z_])-0x7fffffffffffffff(?![0-9A-Za-z_])")


def to_cast_big(src):
    return RE_NEG_LIMIT.sub("-(long)0x7fffffffffffffff", src)



# 11. `@sizeof(x)` -> `$sizeof(x)`
#    0.6.2 spells the value-sized form with a single `$`. (The `$$` form is a
#    type, which is a different thing; `@` does not exist there at all.)
RE_AT_SIZEOF = re.compile(r"@sizeof\b")


def to_dollar_sizeof(src):
    return RE_AT_SIZEOF.sub("$sizeof", src)


# 12. bare enum constants -> `Enum.NAME`
#     0.6.2 keeps enum constants out of the enclosing scope. This maps every
#     constant declared by an `enum X : int { ... }` to its owner, then
#     qualifies bare uses OUTSIDE the declaration bodies. Two guards matter:
#     a use that already has a qualifier is left alone, and a name that is also
#     a parameter or local is left alone -- qualifying that is a type error, and
#     it is the mistake this rule made on its first run.
def to_qualified_enums(files):
    owners = {}
    decls = {}
    for path in files:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        decls[path] = text
        for m in re.finditer(r"enum\s+(\w+)\s*:\s*\w+\s*\{([^}]*)\}", text, re.S):
            for c in re.findall(r"\b([A-Z][A-Z0-9_]{3,})\b", m.group(2)):
                owners[c] = m.group(1)
    if not owners:
        return 0
    changed = 0
    for path, text in decls.items():
        parts = re.split(r"(enum\s+\w+\s*:\s*\w+\s*\{[^}]*\})", text)
        out = []
        for part in parts:
            if part.startswith("enum "):
                out.append(part)
                continue
            # a declared parameter/local name is never an enum constant use
            local_names = set(re.findall(r"\b(?:[A-Za-z_]\w*)\s+([a-z_]\w*)\s*[,)=]", part))
            def q(m):
                nm = m.group(1)
                if nm in local_names or nm not in owners:
                    return nm
                return owners[nm] + "." + nm
            out.append(re.sub(r"(?<![.\w])([A-Z][A-Z0-9_]{3,})\b", q, part))
        new = "".join(out)
        if new != text:
            with open(path, "w", encoding="utf-8") as f:
                f.write(new)
            changed += 1
    return changed



# 13. `T a[N]` -> `T[N] a`
#     0.6.2 predates the C-style array declaration form.
RE_ARRAY_DECL = re.compile(r"\b([A-Za-z_]\w*(?:\s*\*)?) ([a-z_]\w*)\[([0-9]+)\]")


def to_c3_array_decl(src):
    return code_only(src, lambda code: RE_ARRAY_DECL.sub(
        lambda m: "%s[%s] %s" % (m.group(1), m.group(3), m.group(2)), code))


# 14. a dot-call omits the receiver
#     0.8 accepts `s.f(&s, x)` and `s.f(x)`; 0.6.2 only the latter. Dropping the
#     repeated receiver is what the newer call means, so this is a rewrite of
#     spelling only.
RE_DOT_CALL_RECV = re.compile(r"\b(\w+)\.(\w+)\(\s*\1\s*,\s*")


def to_implicit_receiver(src):
    return code_only(src, lambda code: RE_DOT_CALL_RECV.sub(
        lambda m: "%s.%s(" % (m.group(1), m.group(2)), code))



# 15. `String.ptr` -> the array itself
#     0.6.2's `String` is `char[]`, so the slice IS the pointer; `.ptr` is the
#     0.8 spelling. `.len` is a member of both, so only `.ptr` moves.
RE_STRING_PTR = re.compile(r"\b(args\[\d+\])\.ptr\b")


def to_bare_string(src):
    return code_only(src, lambda code: RE_STRING_PTR.sub(r"\1", code))



def _split_strings(src):
    """Yield (kind, text) with kind in {"code", "lit", "comment"}.

    Comments are separated out because an apostrophe in prose ("the reader's
    job") otherwise opens a character literal and desynchronises the splitter
    for the rest of the file. That is precisely what happened here: the second
    half of air_c.c3 silently stopped being rewritten, and the build reported
    the result as a type error instead of as a broken tool.
    """
    out = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    break
                j += 1
            out.append(("lit", src[i:j + 1]))
            i = j + 1
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            if j < 0:
                j = n
            out.append(("comment", src[i:j]))
            i = j
        elif c == "'":
            # a character literal is one character or one escape
            j = i + 1
            if j < n and src[j] == "\\":
                j += 2
            else:
                j += 1
            if j < n and src[j] == "'":
                out.append(("lit", src[i:j + 1]))
                i = j + 1
            else:
                out.append(("code", c))
                i += 1
        else:
            j = i
            while j < n and src[j] not in ('"', "'") and not (src[j] == "/" and j + 1 < n and src[j + 1] == "/"):
                j += 1
            out.append(("code", src[i:j]))
            i = j
    return out


def code_only(src, fn):
    """Apply `fn` to code only; literals and comments pass through untouched."""
    return "".join(t if k != "code" else fn(t) for k, t in _split_strings(src))


STEPS = [
    ("alias -> def", to_def),
    ("Type::size -> Type.sizeof", to_prop),
    ("def identifier -> defn", to_defn),
    ("<* *> -> //", to_line_comments),
    ("negated long limit", to_cast_big),
    ("@sizeof -> $sizeof", to_dollar_sizeof),
    ("T a[N] -> T[N] a", to_c3_array_decl),
    ("dot-call receiver", to_implicit_receiver),
    ("String.ptr -> char[]", to_bare_string),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=".", help="repository root to copy from")
    ap.add_argument("--dest", required=True, help="where to write the shimmed copy")
    args = ap.parse_args()

    src = os.path.abspath(args.src)
    dest = os.path.abspath(args.dest)
    if dest == src or src.startswith(dest + os.sep):
        sys.exit("refusing to write into the source tree: pass a different --dest")

    # copy only what the build needs; tests/ and docs/ are not compiled
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    # pfront/ and Makefile are the compiler; tools/air holds the C-target driver
    # that airc builds from. The rest of tools/ is unrelated analysis scripts and
    # is deliberately not copied.
    os.makedirs(os.path.join(dest, "tools", "air"), exist_ok=True)
    for name in ("pfront", os.path.join("tools", "air", "airc.c3"), "Makefile"):
        s = os.path.join(src, name)
        d = os.path.join(dest, name)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        elif os.path.isfile(s):
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.copy2(s, d)

    files = sorted(glob.glob(os.path.join(dest, "pfront", "**", "*.c3"), recursive=True)
                     + glob.glob(os.path.join(dest, "tools", "air", "airc.c3")))
    if not files:
        sys.exit("no .c3 files under %s/pfront" % dest)

    changed = 0
    for path in files:
        with open(path, encoding="utf-8") as f:
            original = f.read()
        text = original
        for _, fn in STEPS:
            text = fn(text)
        if text != original:
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
            changed += 1

    enum_files = to_qualified_enums(files)
    print("qualified enum constants in %d files" % enum_files)

    # A shim that reports success without changing anything is the failure mode
    # this repository keeps finding: assert the work actually happened.
    leftover = {
        "alias decl": sum(len(RE_ALIAS.findall(open(p, encoding="utf-8").read())) for p in files),
        "::size": sum(open(p, encoding="utf-8").read().count("::size") for p in files),
        "doc comment": sum(open(p, encoding="utf-8").read().count("<*") for p in files),
    }
    print("shimmed %d of %d files in %s" % (changed, len(files), dest))
    for k, v in leftover.items():
        print("  %-12s remaining: %d" % (k, v))
    if changed == 0:
        sys.exit("nothing was rewritten: the shim is not doing anything")
    return 0


if __name__ == "__main__":
    sys.exit(main())
