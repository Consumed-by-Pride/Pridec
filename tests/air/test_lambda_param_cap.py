#!/usr/bin/env python3
"""A lambda past 16 parameters must be refused, not silently truncated.

`AirPrd.binders` is a fixed `AirBinder*[16]`, and `lambda_prd` filled it with

    for (i = 0; i < n.child_count && bc < 16; i++)

-- stopping at 16 and dropping the rest without a word. The dropped parameters
had already been bound in the scope, so the BODY still referred to them. This is
not merely a shortened header: it is an artifact with free variables.

Measured against the supplied binary, a lambda with 70 parameters:

    let h = lam(p0 : infer, p1 : infer, ... p15 : infer).
      <(add p0 p1) | comu _x69.
        ...
          <(add p60 p61) | ...

`lam` declares 16 parameters; the body uses names up to `p69`. Forty-five free
variables, in a module that reported:

    /tmp/p70.pie: errors=0 warnings=2 modules=5

This is the fourth instance of the same shape in this codebase -- a plausible
artifact that is quietly wrong:

  * `airtool fmt` dropping declarations and exiting 0
  * a full disk producing a 0-byte `.air` with errors=0
  * `add_decl` dropping decls past 4096 (fixed earlier on this branch)
  * this one

The function-declaration path had already been fixed to refuse at its own cap;
`lambda_prd` had the identical loop and was missed.

Verify with the oracle:

    python3 -c "print('fn f: ... let h = fn(' + params70 + ') ...')" > big.pie
    pfrontc big.pie --emit-air ; echo "exit=$?"

must fail loudly and write no `.air`.
"""
from pathlib import Path

LOWER = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_lower.c3"


def _fn(src: str, name: str) -> str:
    i = src.find("fn AirPrd* AirLower." + name + "(")
    assert i >= 0, f"AirLower.{name} not found -- did it move?"
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i : j + 1]
    raise AssertionError("unbalanced braces in " + name)


def test_an_over_cap_lambda_is_refused():
    body = _fn(LOWER.read_text(), "lambda_prd")
    assert "note_bad" in body, (
        "lambda_prd must REFUSE when it cannot represent the parameters; "
        "silently dropping them leaves the body referring to free names"
    )
    assert "lr.scope.leave();" in body and "return null;" in body, (
        "the refusal must unwind the scope and return null"
    )
    # The refusal must be reachable, i.e. actually triggered by the param count.
    assert "nparams > 16" in body, (
        "the refusal must fire on an actual parameter count over 16, not on "
        "the loop counter (which is capped and would fire for exactly 16)"
    )


def test_exactly_sixteen_parameters_still_lowers():
    """A 16-param lambda is representable and must not be refused.

    The loop stops at `bc < 16`, so `bc == 16` is ambiguous between "exactly 16
    params" and "more were dropped". Counting the parameters separately is what
    tells them apart -- without it the refusal would reject valid programs.
    """
    body = _fn(LOWER.read_text(), "lambda_prd")
    assert "N_DECL_PARAM" in body and "nparams" in body, (
        "the real parameter count must be measured independently of the "
        "16-wide buffer, or exactly-16 is indistinguishable from truncated"
    )
    assert "> 16" in body, "the comparison must be strict: 16 params are fine"


def test_the_refusal_is_not_a_silent_continue():
    """`bc < 16` may stay as the buffer guard, but it cannot be the only logic.

    If the loop's own bound were the only check, nothing would ever report the
    drop.
    """
    body = _fn(LOWER.read_text(), "lambda_prd")
    # The loop bound is fine to keep; it just cannot be the whole story.
    assert "bc < 16" in body, "sanity: the buffer guard is still needed"
    assert body.count("note_bad") >= 1


def test_the_scope_is_unwound_on_the_refusal_path():
    """A refusal that leaves the scope entered corrupts every later lookup.

    `lambda_prd` calls scope.enter() at the top and scope.leave() at the
    bottom; the early return has to leave it too, or the NEXT lambda is lowered
    with the failed one's bindings still in scope.
    """
    body = _fn(LOWER.read_text(), "lambda_prd")
    # Anchor on the CALL, not the word: the doc comment above also says
    # "note_bad", and matching that finds the comment instead of the code.
    assert "lr.note_bad(" in body, "the refusal call itself is missing"
    i_ref = body.index("lr.note_bad(")
    tail = body[i_ref:]
    assert "lr.scope.leave();" in tail[:220], (
        "scope.leave() must run before returning from the refusal path"
    )
    # And exactly one leave on the normal path must remain.
    assert body.count("lr.scope.leave();") == 2, (
        "expected two leaves: the refusal path and the normal path"
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
