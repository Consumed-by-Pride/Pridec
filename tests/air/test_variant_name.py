#!/usr/bin/env python3
"""An enum variant with a payload must keep its own name.

`node_text` decides what a declaration is called. For `N_DECL_VARIANT` it fell
into the generic decl branch, which scans CHILDREN for the first ident/ty-name.
But a variant's own name is not a child at all -- the parser stores it in
`name_id` (pfront_parse.c3:5128) -- and a variant's children are its PAYLOAD
TYPES. So the function returned the first payload type as the constructor's
name.

Measured against the supplied binary:

    enum E
      | Point(i64, i64)

    data E {
      ctor `i64`(_0 : i64, _1 : i64) : nominal E;
    }

while the match arm in the same file still emitted `Point`:

    $ grep -c Point artifact.air
    1

So the artifact declared a constructor named `i64` and matched on one named
`Point`. The type's own declaration disagreed with every use of it, and the
compiler reported `errors=0`.

A bare variant (`| B`) was correct, which is why this survived: it only appears
when a variant carries a payload. The same payload-name confusion for struct
fields is why `N_DECL_FIELD` is covered too -- a field's name is likewise in
`name_id`, not in its children.

Verify with the oracle:

    printf 'enum E\\n  | Point(i64, i64)\\n' > e.pie
    pfrontc e.pie --emit-air && grep 'ctor' e.air      # must say `Point`
"""
from pathlib import Path

LOWER = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_lower.c3"


def _node_text(src: str) -> str:
    i = src.find("fn char* node_text(")
    assert i >= 0, "node_text not found -- did it move?"
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise AssertionError("unbalanced braces in node_text")


def test_a_variant_name_comes_from_name_id_not_from_its_children():
    body = _node_text(LOWER.read_text())
    assert "N_DECL_VARIANT" in body, "node_text must special-case variants"
    # Find the variant branch and confirm it reads name_id rather than scanning.
    i = body.find("N_DECL_VARIANT")
    window = body[i : i + 400]
    assert "name_id" in window, (
        "a variant's name lives in name_id; scanning children returns the "
        "first payload type (Point(i64) was named `i64`)"
    )
    assert "N_TY_NAME" not in window[: window.find("name_id")], (
        "the variant branch must not accept a child TY_NAME as the name -- "
        "that is exactly the payload type that hijacked it"
    )


def test_the_variant_branch_precedes_the_generic_child_scan():
    """Order matters: the generic decl scan below would still win otherwise."""
    body = _node_text(LOWER.read_text())
    i_special = body.find("N_DECL_VARIANT")
    i_generic = body.find("pfront_core::is_decl(n.kind)")
    assert i_special != -1 and i_generic != -1
    assert i_special < i_generic, (
        "the variant check must come before the generic decl branch, or the "
        "child scan runs first and the bug returns"
    )


def test_struct_fields_are_covered_by_the_same_rule():
    """A field's own name is also in name_id, not a child.

    Fields happened to come out right because their name is a child ident, but
    relying on child order is what broke variants. Pinning both makes the rule
    uniform.
    """
    body = _node_text(LOWER.read_text())
    i = body.find("N_DECL_VARIANT")
    window = body[i : i + 400]
    assert "N_DECL_FIELD" in window, (
        "fields carry name_id too; covering both keeps one rule for "
        "'declaration whose children are types'"
    )


def test_the_guard_requires_a_resolvable_name():
    """If name_id is unset, fall through rather than returning garbage."""
    body = _node_text(LOWER.read_text())
    i = body.find("N_DECL_VARIANT")
    window = body[i : i + 500]
    assert "name_id != 0" in window, (
        "an absent name_id must fall through to the existing paths, not be "
        "dereferenced"
    )
    assert "vname" in window and "return vname" in window


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
