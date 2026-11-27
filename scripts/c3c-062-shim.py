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
    out = []
    for line in src.split("\n"):
        if RE_ALIAS_LINE.match(line):
            out.append(line)
        else:
            line = RE_DEF_AFTER_BRACKET.sub(r"\1defn", line)
            line = RE_DEF_MEMBER.sub(r"\1defn", line)
            out.append(RE_DEF_IDENT.sub("defn", line))
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


STEPS = [
    ("alias -> def", to_def),
    ("Type::size -> Type.sizeof", to_prop),
    ("def identifier -> defn", to_defn),
    ("<* *> -> //", to_line_comments),
    ("negated long limit", to_cast_big),
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
    for name in ("pfront", "Makefile"):
        s = os.path.join(src, name)
        d = os.path.join(dest, name)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        elif os.path.isfile(s):
            shutil.copy2(s, d)

    files = sorted(glob.glob(os.path.join(dest, "pfront", "**", "*.c3"), recursive=True))
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
