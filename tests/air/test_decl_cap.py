#!/usr/bin/env python3
"""The 4096-decl cap must not silently truncate an artifact.

`AirModule.decls` is a fixed `AirDecl*[4096]`. `add_decl` returned `false` once
the array was full and **every** caller ignored the return value, so a module
that ever exceeded the cap would be written short while the compiler still
reported `errors=0`.

Today nothing reaches it -- the largest measured module is 2,430 decls for the
implicit `prelude -> mem -> os.linux -> syscalls` chain. That is precisely the
danger: an unreachable-today silent truncation goes unnoticed until the day a
program does reach it, and then it produces a plausible-looking artifact that is
missing declarations. This project has already been bitten twice by the same
shape (`airtool fmt` dropping decls, and a full disk producing 0-byte `.air`
files with `errors=0`), so this one is closed before it fires.

Two halves:
  1. `add_decl` records the drop on a sticky flag instead of failing silently.
  2. `write_module` refuses to emit a module whose flag is set.

These are textual invariants over the source, since the repository cannot build
the compiler (standing "no local build" constraint). If you are changing the
decl array, verify with the oracle:

    pfrontc big.pie --emit-air --quiet ; echo "exit=$?"

and confirm the run fails loudly rather than emitting a short file.
"""
from pathlib import Path

IR = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_ir.c3"
WRITE = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_write.c3"
EMIT = Path(__file__).resolve().parents[2] / "pfront" / "pear_ir" / "air_emit.c3"


def test_add_decl_records_overflow_on_a_sticky_flag():
    src = IR.read_text()
    i = src.find("fn bool AirModule.add_decl(")
    assert i >= 0, "AirModule.add_decl not found -- did it move or change shape?"
    body = src[i : src.find("\n}", i) + 2]
    assert "4096" in body, "the 4096 cap must still be visible where it is enforced"
    assert "decl_overflow" in body, (
        "add_decl must record the drop; returning false into a void context is "
        "what made the truncation silent"
    )
    assert "m.decl_overflow = true" in body, "the flag must be SET on overflow, not just declared"


def test_the_overflow_flag_is_initialised():
    """`AirModule` lives on the stack, so an unset flag reads as garbage.

    Every construction path goes through `AirModule.init`, which is why the flag
    is cleared there rather than at each of the four `AirModule mod;` sites.
    """
    src = IR.read_text()
    i = src.find("fn bool AirModule.init(")
    assert i >= 0, "AirModule.init not found"
    body = src[i : src.find("\n}", i) + 2]
    assert "decl_overflow=false" in body or "decl_overflow = false" in body, (
        "AirModule.init must clear decl_overflow; the struct is stack-allocated"
    )
    assert "decl_count=0" in body.replace(" ", ""), (
        "sanity: init still resets decl_count, so this is the right function"
    )


def test_BOTH_writers_refuse_an_overflowed_module():
    """There are two writers, and the obvious one to guard is the wrong one.

    `--emit-air` (the path that produced the 20.6 GB) goes through
    `air_emit::emit_module`, NOT `air_write::write_module`. Guarding only the
    latter would have left the main path publishing short artifacts, so both
    are checked here.
    """
    emit = EMIT.read_text()
    i = emit.find("fn int emit_module(")
    assert i >= 0, "emit_module not found"
    body = emit[i : i + 1200]
    assert "mod.decl_overflow" in body, (
        "air_emit::emit_module is what --emit-air uses; it must check the flag"
    )
    head = body[: body.find("void* std_out =")]
    assert "return 1;" in head, "emit_module must return non-zero on overflow"
    assert "refusing to write" in head, "the refusal must say so on stderr"

    write = WRITE.read_text()
    i = write.find("fn int write_module(")
    assert i >= 0, "write_module not found"
    body = write[i : i + 1400]
    assert "m.decl_overflow" in body, (
        "air_write::write_module serves the reader/round-trip paths; it must check too"
    )
    head = body[: body.find("void* f =")]
    assert "return 1;" in head, "write_module must return non-zero on overflow"
    assert "refusing to write" in head, "the refusal must say so on stderr"


def test_the_cap_is_still_4096_so_the_fix_matches_the_array():
    """The bound in add_decl must agree with the declared array size.

    If someone widens the array without touching the guard (or vice versa) the
    guard stops protecting the array, and the memcpy-equivalent overruns.
    """
    src = IR.read_text()
    assert "AirDecl*[4096] decls;" in src, "the decls array is no longer [4096]"
    i = src.find("fn bool AirModule.add_decl(")
    body = src[i : src.find("\n}", i) + 2]
    assert "decl_count >= 4096" in body, (
        "add_decl's bound no longer matches the [4096] array width"
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
