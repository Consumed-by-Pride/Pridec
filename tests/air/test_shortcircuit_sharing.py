#!/usr/bin/env python3
"""Guard against the short-circuit continuation being duplicated.

BACKGROUND -- the 20.6 GB `--emit-air` blowup
---------------------------------------------
`examples/tokei/main.pie` produced a 20.6 GB `.air` file. The trigger was not
module count, not stdlib size, and not `mul64_hi` (that function is a constant
5,785 lines at every probe depth). It is this, in `examples/tokei/languages.pie`:

    fn extension_matches_0 : ptr -> bool
      | extension ->
          os.linux.strcmp(extension, "c" as ptr) == 0i32 ||
          os.linux.strcmp(extension, "h" as ptr) == 0i32 ||
          ... 97 terms ...

The old `shortcircuit_or` / `shortcircuit_and` passed the SAME consumer `k`
into both arms of the generated `if`:

    if a then <true | k>  else <b | k>

`k` is a shared node in the AIR graph. The AIR text format has no way to
express sharing, so `air_write` inlines the node into every position that
references it. With a chained operator the tail under `k` is itself another
short-circuit, so the inlining doubles at every level.

Measured with the supplied `pfrontc` (built from 4550225, i.e. BEFORE the fix),
for `x == 1 || x == 2 || ... || x == n`:

    n    :  2    3    4    5     6     7     8
    lines: 10   18   34   66   130   258   514        =  2^(n+1) + 2

and at n = 8 the ONE source term `x == 8` was printed **64 times**. Extrapolated
to the 97-term chains in `languages.pie` this is the 1.43 GB measured for that
module alone. The 3.0 lowerer never had the bug: `Low.shortcircuit` routes both
sides through a join label, so each side is emitted once.

THE FIX
-------
`AirLower.shortcircuit_join` mirrors `Low.shortcircuit`: branch, send both arms
to a join label carrying the bool as a *parameter*, and run the consumer once
inside the label body. The tail under `k` is then referenced exactly once.

WHAT THIS FILE CHECKS
---------------------
These are textual invariants over the lowerer source, because this repository
cannot build the compiler (see the standing "no local build" constraint). They
are chosen so that reverting the fix fails at least one of them.

If you are changing the short-circuit path, verify against the oracle:

    pfrontc x.pie --emit-air --quiet && grep -c '<(eq x 8 ' x.air

For an 8-term `||` chain that count must be 1 (it was 64 before the fix).
"""
from pathlib import Path

LOWER = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_lower.c3"
LOW = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_low.c3"


def _fn_body(src: str, name: str) -> str:
    """Return the source of `fn <...> <name>(...)` through its balanced brace."""
    if not isinstance(src, str):
        src = src.read_text()
    start = None
    for i, line in enumerate(src.splitlines()):
        if line.startswith("fn ") and f"AirLower.{name}(" in line:
            start = i
            break
    assert start is not None, f"AirLower.{name} not found in {LOWER}"
    lines = src.splitlines()
    depth = 0
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if i > start and depth <= 0:
            return "\n".join(lines[start : i + 1])
    raise AssertionError(f"unbalanced braces in AirLower.{name}")


def test_both_shortcircuit_operators_route_through_the_join_helper():
    """`&&` and `||` must share one implementation, so a fix cannot miss one.

    Before the fix these were two near-identical copies of the buggy code; only
    fixing the `||` copy would have left `&&` exponential.
    """
    src = LOWER.read_text()
    for name, is_and in (("shortcircuit_and", "true"), ("shortcircuit_or", "false")):
        body = _fn_body(src, name)
        assert "shortcircuit_join" in body, (
            f"{name} no longer delegates to shortcircuit_join -- the duplicated-"
            "continuation bug can come back through this function"
        )
        assert f", {is_and})" in body, f"{name} passes the wrong is_and flag"


def test_join_helper_does_not_pass_the_consumer_into_both_arms():
    """The defining property of the fix.

    The bug was structurally: the consumer `k` handed to BOTH the then-arm and
    the else-arm. After the fix the consumer appears in exactly one place -- the
    join label body -- and both arms jump to that label instead.
    """
    body = _fn_body(LOWER, "shortcircuit_join")

    # Exactly one cut against the incoming consumer: the join label body.
    assert body.count("lr.cut(") == 1, (
        "expected exactly one lr.cut( in shortcircuit_join (the join body); "
        "more than one means the consumer is being handed to several arms again"
    )
    assert "lr.cut(pvar, k)" in body, "the join label must cut the parameter to k"

    # Both arms must be jumps to the join label, not cuts to the consumer.
    assert body.count("air_mk_jump(") == 2, (
        "expected two jumps to the join label (short arm + long arm)"
    )
    assert body.count("join,") >= 2, "jumps must target the join label"

    # A label must actually be created, carrying the bool parameter.
    assert "air_mk_label(" in body, "the fix requires a join label"
    assert "lr.mod.t_bool" in body, "the join parameter must be typed bool"
    assert "air_mk_seq(lr.arena, join_lbl, iff)" in body, (
        "labels are declared before the code that jumps to them -- the emitted "
        "`while` shape sequences label %exit()/label %loop() ahead of the jump"
    )


def test_short_arm_materialises_the_constant_for_the_jump():
    """Jump arguments are variable names, not predicates.

    `air_mk_jump` takes `char**` of names, so `jump join(true)` is not
    expressible. The constant has to be let-bound first. The 3.0 lowerer does
    the same (`let _v10 = true : bool in jump sc.join7(_v10)`); emitting a bare
    `true` as a jump argument produces an artifact the verifier rejects.
    """
    body = _fn_body(LOWER, "shortcircuit_join")
    assert "air_mk_let(" in body, "the short-circuit constant must be let-bound"
    assert "is_and ? lr.mod.p_false : lr.mod.p_true" in body, (
        "&& short-circuits to false, || short-circuits to true"
    )


def test_each_operand_is_lowered_exactly_once():
    """The property that actually bounds the output.

    Duplication is not a property of the source tree -- the source has one node
    per operand. It appeared because `expr_to_cns(children[1], k)` was invoked
    with a consumer that was ALSO reachable from the sibling arm, so the single
    lowered subtree got printed down both paths. Lowering each operand exactly
    once, against a join, is what makes the emitted size linear in the source.
    """
    import re

    body = _fn_body(LOWER, "shortcircuit_join")
    rhs = re.findall(r"lr\.expr_to_cns\(n\.children\[1\]", body)
    lhs = re.findall(r"lr\.expr_to_cns\(n\.children\[0\]", body)
    assert len(rhs) == 1, f"right operand lowered {len(rhs)} times, expected 1"
    assert len(lhs) == 1, f"left operand lowered {len(lhs)} times, expected 1"


def test_the_3_0_reference_still_uses_a_join_label():
    """Pin the reference implementation the fix was modelled on.

    If `Low.shortcircuit` ever stops using a join block, the reasoning in the
    fix's comment (and this file) is stale and must be revisited.
    """
    src = LOW.read_text()
    i = src.find("fn Vx Low.shortcircuit(")
    assert i >= 0, "Low.shortcircuit not found -- the 3.0 reference moved"
    body = src[i : i + 2000]
    assert "sc.join" in body, "the 3.0 reference must still join both paths"
    assert "t_jump(join" in body, "the 3.0 reference must jump to the join"
    # The join is what stops the duplication: the value travels as a parameter.
    assert "lw.blks[join].np = 1;" in body, "the join must take the bool as a param"


if __name__ == "__main__":
    fails = 0
    for nm, fn in sorted(globals().items()):
        if nm.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok   {nm}")
            except AssertionError as e:
                fails += 1
                print(f"FAIL {nm}: {e}")
    print(f"\n{5 - fails}/5 passed")
    raise SystemExit(1 if fails else 0)
