#!/usr/bin/env python3
"""`type_ann` is not a child, and two places forgot that.

Carriers of a type annotation (`fn`, `let`, `type Name = T`, parameters) store
the annotation in `Node.type_ann`, NOT in `children`. Two readers got this
wrong in opposite ways.

1. THE SEXP DUMP DROPPED IT (`dump_sexp`, pfront/pfront_dump.c3). It printed
   `name_id` and children only. Measured on

       fn f : i64 -> bool
         | a -> a > 0i64

       --emit-ast     fn 'f'  : ty-fn -> ty-name 'i64', ty-name 'bool'
       --emit-sexp    (fn f (clause (pat-ident a) (block (binary > ...))))

   and `type Age = i64` printed as `(type Age)` with the target gone. The dump
   is the tool people reach for to answer "did this parse correctly?", so
   silently omitting every type annotation makes a correct tree look like a
   broken one. The tree dump already printed `type_ann`; the sexp dump did not,
   which is the inconsistency that hid this.

2. THE AIR LOWERER MISSED IT (`decl_type`, pfront/pear_ir/air_lower.c3). It read
   `n.children[0]` for the alias target, which is empty for an alias, so every

       type Age = i64

   emitted

       declare Age() : infer;

   with the target discarded and errors=0. Confirmed against the supplied
   binary; the tree dump shows the parser really did populate `type_ann`
   (`type 'Age' : ty-name 'i64'`), so this was purely a wrong read, not a
   parser gap.

Verify with the oracle:

    printf 'type Age = i64\\nfn f : Age -> Age\\n  | a -> a\\n' > t.pie
    pfrontc t.pie --emit-air && grep 'declare Age' t.air     # must not be `infer`
    pfrontc t.pie --emit-sexp | grep 'type Age'              # must show the target
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DUMP = ROOT / "pfront" / "pfront_dump.c3"
LOWER = ROOT / "pfront" / "pear_ir" / "air_lower.c3"


def _block(src: str, sig: str) -> str:
    i = src.find(sig)
    assert i >= 0, f"{sig!r} not found -- did it move?"
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise AssertionError(f"unbalanced braces in {sig}")


def _code_only(body: str, keep_strings: bool = False) -> str:
    """Strip comments and string literals.

    Every one of these fixes carries a long explanatory comment that names
    `type_ann`, `children[0]` and the rest. Checking the raw text means the
    comment satisfies the assertion and a mutation that removes the actual code
    still passes -- which is exactly what happened while writing this file.
    """
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)     # block comments
    body = re.sub(r"//[^\n]*", "", body)                    # line comments
    if not keep_strings:
        body = re.sub(r'"(?:[^"\\]|\\.)*"', '""', body)    # string literals
    return body


def test_the_sexp_dump_prints_type_ann():
    # Comments stripped, string literals KEPT: this test asserts on printf(" ")
    # and on the call itself, both of which need their literals intact.
    body = _code_only(_block(DUMP.read_text(), "fn void dump_sexp("), keep_strings=True)
    assert "type_ann" in body, (
        "dump_sexp must print type_ann; otherwise every type annotation in the "
        "program is invisible and a correct tree looks broken"
    )
    # It must be printed INSIDE the node's parentheses, next to the children.
    # Look at the code that actually uses type_ann, not the first printf in the
    # function (`:syn` also prints a leading space, which is what a naive
    # "first printf" check matches).
    i = body.find("n.type_ann != null")
    assert i >= 0, "the dump must branch on type_ann being present"
    window = body[i : i + 200]
    assert 'printf(" ")' in window, (
        "the annotation must be emitted with the same leading space as children"
    )
    assert "dump_sexp(n.type_ann" in window, (
        "the annotation must go through the same node printer"
    )
    assert body.find('printf(")")', i) > i, (
        "the annotation must be printed before the closing paren"
    )


def test_the_tree_dump_still_prints_type_ann():
    """The two dumps must agree; the tree dump was already correct and is the
    reference the sexp dump was made to match."""
    src = DUMP.read_text()
    body = _code_only(_block(src, "fn void dump_tree("))
    assert "type_ann" in body, (
        "dump_tree was the working reference (it showed ': ty-name i64' where "
        "the sexp dump showed nothing)"
    )


def test_decl_type_reads_type_ann_not_just_children():
    body = _code_only(_block(LOWER.read_text(), "fn AirDecl* AirLower.decl_type("))
    assert "type_ann" in body, (
        "an alias target lives in type_ann; reading only children[0] emitted "
        "`declare Age() : infer` for `type Age = i64`"
    )
    # The child read is kept as a fallback, not removed.
    assert "children[0]" in body, (
        "children[0] should remain as a fallback for nodes that carry the "
        "target as a child"
    )
    i_ann = body.find("type_ann")
    i_child = body.find("children[0]")
    assert i_ann < i_child, (
        "type_ann must be consulted FIRST: it is the parser's actual carrier"
    )


def test_the_alias_target_still_reaches_the_writer():
    """`ret_ty` is what the writer prints for ADECL_DECLARE; it must be set."""
    body = _code_only(_block(LOWER.read_text(), "fn AirDecl* AirLower.decl_type("))
    assert "ret_ty" in body, "decl_type must set ret_ty from the resolved target"
    assert "air_ty(" in body, "the target must go through the type mapper"


if __name__ == "__main__":
    fails = 0
    total = 0
    for nm, fn in sorted(globals().items()):
        if nm.startswith("test_") and callable(fn):
            total += 1
            try:
                fn()
                print(f"ok   {nm}")
            except AssertionError as e:
                fails += 1
                print(f"FAIL {nm}: {e}")
    print(f"\n{total - fails}/{total} passed")
    raise SystemExit(1 if fails else 0)
