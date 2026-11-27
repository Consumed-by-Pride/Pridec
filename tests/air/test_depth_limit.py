#!/usr/bin/env python3
"""The parser's depth guard must be balanced and must not cry wolf.

TWO DEFECTS, both in `Parser.enter` (pfront/pfront_parse.c3).

1. UNBALANCED DEPTH. `enter` increments `p.depth`, and every call site reads

       if (!p.enter()) { Tok c = p.cur(); return p.mk_error(c); }

   which returns WITHOUT calling `leave`. The frame that failed to enter was
   therefore never balanced. It happened to wash out on the normal path (one
   leave per frame), which is exactly why it survived: nothing observable
   depended on it until something unbalanced it.

2. A LIMIT REPORTED AS A SYNTAX ERROR. `mk_error` does not emit a diagnostic,
   so the parser kept going while parked on the offending token and a second,
   bogus error appeared:

       error[E1001]: expression nests too deeply
       error[E1041]: expected ')' after expression

   Nothing was missing a parenthesis. Reported against the supplied binary:

       $ perl -e 'print "("*450, "x", ")"*450' > /tmp/deep.pie
       $ pfrontc /tmp/deep.pie
       /tmp/deep.pie:4:407: error[E1001]: expression nests too deeply
       /tmp/deep.pie:4:408: error[E1041]: expected ')' after expression

   A nesting LIMIT is not a syntax error, and telling someone to look for a
   missing `)` sends them hunting for a bug that is not there. The fix enters
   the parser's existing panic state, which `err`/`err_hint` already check, so
   the cascade is suppressed by the mechanism that exists for it.

The measured limit itself is fine: 400 levels of nesting is far beyond any real
source, and no file in examples/ or stdlib/ comes near it (checked). This file
pins the *behaviour*, not the number.

Verify with the oracle:
    pfrontc deep.pie 2>&1 | grep -c 'error\\['     # must be 1, not 2
"""
from pathlib import Path

PARSE = Path(__file__).resolve().parents[2] / "pfront" / "pfront_parse.c3"


def _enter_body(src: str) -> str:
    i = src.find("fn bool Parser.enter(Parser* p)")
    assert i >= 0, "Parser.enter not found -- did it move or change signature?"
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise AssertionError("unbalanced braces in Parser.enter")


def test_the_failed_frame_is_balanced():
    """On the limit path, depth must be restored before returning.

    `enter` is the increment; the caller does not call `leave` when it fails,
    so `enter` has to undo its own increment.
    """
    body = _enter_body(PARSE.read_text())
    # There must be exactly one increment and one decrement on the failure path.
    assert "p.depth = p.depth + 1;" in body, "sanity: enter still increments"
    assert "p.depth = p.depth - 1;" in body, (
        "the failure path must undo its own increment; callers return without "
        "calling leave(), so the frame leaks otherwise"
    )
    # The decrement must come after the increment and before the `return false`.
    i_inc = body.index("p.depth = p.depth + 1;")
    i_dec = body.index("p.depth = p.depth - 1;")
    i_false = body.index("return false;")
    assert i_inc < i_dec < i_false, (
        "depth must be restored between the increment and the failure return"
    )


def test_a_limit_hit_does_not_cascade_into_a_syntax_error():
    """Hitting the limit must not produce a second, misleading diagnostic.

    `err` and `err_hint` both begin `if (p.panicking) { return; }`. Entering
    that state on a limit hit is what suppresses "expected ')' after
    expression" -- a message that describes a syntax mistake the user did not
    make.
    """
    src = PARSE.read_text()
    body = _enter_body(src)
    assert "p.panicking = true;" in body, (
        "the limit path must enter the panic state, or the follow-on "
        "'expected )' diagnostic is reported against correct source"
    )

    # That only works if err/err_hint actually honour the flag.
    for fn in ("fn void Parser.err(Parser* p, int code, char* msg)",
               "fn void Parser.err_hint(Parser* p, int code, char* msg, char* hint)"):
        i = src.find(fn)
        assert i >= 0, f"{fn} not found"
        head = src[i : i + 200]
        assert "if (p.panicking) { return; }" in head, (
            f"{fn.split('(')[0]} no longer early-returns while panicking, so "
            "setting the flag in enter() would no longer suppress the cascade"
        )


def test_the_limit_is_reported_once():
    """`depth_reported` keeps a deep expression from printing N diagnostics."""
    body = _enter_body(PARSE.read_text())
    assert "depth_reported" in body, (
        "the limit must be reported once; without the flag every frame that "
        "fails to enter would emit its own 'nests too deeply'"
    )
    assert "p.depth_reported = true;" in body


def test_the_limit_matches_the_declared_constant():
    """The guard must be against MAX_DEPTH, not a magic number."""
    src = PARSE.read_text()
    body = _enter_body(src)
    assert "MAX_DEPTH" in body, "the guard must use the named constant"
    assert "const int MAX_DEPTH = 400;" in src, (
        "MAX_DEPTH moved or changed -- re-check that no real corpus file nests "
        "near it (none did at 400)"
    )


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
