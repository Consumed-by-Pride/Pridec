#!/usr/bin/env python3
"""Report NodeKind coverage in the AIR lowerers.

The acceptance criterion is "every construct lowers to .air". You cannot make
that claim from the fixture count: a construct with no `case` in either lowerer
falls to a `default:` arm, and whether that refuses loudly or does something
quiet depends on the arm. This walks the enum and the dispatch tables so the
gap list is a fact rather than an impression.

Usage:
    python3 tools/air_kind_coverage.py            # summary
    python3 tools/air_kind_coverage.py --list     # every undispatched kind

Exit code is 0 always: this reports, it does not gate. Gating on a raw count
would be wrong -- most of the remaining kinds are structural nodes (types,
paths, declaration parts) that are consumed by their parent's case rather than
dispatched themselves.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Kinds with no `case` of their own that are nonetheless fully consumed by a
# parent case. Listed explicitly so that adding one is a decision, not an
# accident, and so that a kind moving OUT of this list shows up as a change.
CONSUMED_BY_PARENT = {
    "N_MODULE_PATH": "read by the path helpers (dname/path_name), never a value",
    "N_PATH_SEG": "ditto: a segment of a resolved path",
    "N_EXPR_FIELD_INIT": "fields of a record literal, read by Low.struct_lit",
    "N_PAT_FIELD": "fields of a struct pattern, read by the struct-pattern case",
    "N_PAT_REST": "`..` in a struct pattern: means 'ignore the rest', which the "
                  "struct-pattern loop already does by only reading N_PAT_FIELD",
}

# Kinds that are genuinely unimplemented, with the reason.
KNOWN_GAPS = {
    "N_PAT_REF": "`&pat` in pattern position. The parser produces it, neither "
                 "lowerer handles it, and it appears nowhere in the spec or the "
                 "stdlib. Left refused rather than given invented semantics.",
}

# Pattern kinds air_lower.c3 does not model. It used to turn all of these into a
# WILDCARD -- which always matches, so the arm body ran for inputs it was
# written to exclude, and the .air was published looking well-formed. It now
# latches a refusal (note_bad) and no .air is written. Refusing is the honest
# failure; the construct is still unimplemented, and that is recorded here
# rather than hidden behind a default.
PATTERN_GAPS_AIR_LOWER = {
    "N_PAT_STRUCT": "struct and enum struct-patterns. air_low.c3 lowers these correctly "
                    "(Low.pat resolves each field against the struct decl and recurses into "
                    "the field's sub-pattern); air_lower.c3's pat_node wildcarded them, leaving "
                    "both arms `_` and every field name unbound. pat_node now refuses instead. "
                    "Five files in the tree use the syntax: tests/exec/32_enum_clauses.pie "
                    "(XFAIL for an unrelated PEAR1 reason), tests/pfront/syntax/x05_lowlevel_ub.pie "
                    "(a PASSING test whose .air was silently wrong), "
                    "conformance/cases/253_enum_clause_patterns.pie, "
                    "conformance/cases/63_union_exhaustive_clean.pie and "
                    "tests/pfront/stress/s03_effects_data.pie. None of them is consumed as .air, "
                    "so the refusal regresses no gate.",
    "N_PAT_RANGE": "range patterns (`1..=9`). air_low.c3 lowers these; "
                   "air_lower.c3 does not.",
}
# NOTE: N_EXPR_PIPELINE used to be listed here. pfront_core.c3 documents that
# `|>` lowers as an N_EXPR_BINARY with TOKEN_PIPELINE, and that the dedicated
# enum member "existed with no producer and no consumer" -- it has since been
# removed from the enum, so listing it here made the report stale rather than
# informative. The script flags stale entries for exactly this reason.

# Structurally not values: these never reach a lowerer because they are part of
# a declaration's shape, consumed while lowering the declaration that owns them.
CONSUMED_BY_PARENT.update({
    "N_INVALID": "the parser's error node; a program containing one has already "
                 "failed, so no .air is written",
    "N_USE_ITEM": "imports: module loading, not code generation",
    "N_DOC": "doc comments: carried on the AST, never lowered",
    "N_DECL_FIELD": "a struct/data field: read while lowering the owner's layout",
    "N_DECL_VARIANT": "an enum variant: read by variant_index, not a value",
    "N_DECL_EFFECT_OP": "an effect operation: part of the effect row, not runtime code",
    "N_DECL_PARAM": "a parameter: read by the function-lowering case",
    "N_DECL_TYPEPARAM": "a type parameter: erased before code generation",
    "N_CLAUSE": "a function clause: the function case iterates clauses directly",
    "N_MATCH_ARM": "a match arm: the match case iterates arms directly",
    "N_HANDLER_ARM": "a handler arm: the handler case iterates arms directly",
    "N_GUARD": "`if g` on an arm: the match case reads it off the arm",
})
# Types are erased or resolved before lowering; they are read through Low.ty,
# which is not a `case` dispatch.
TYPE_KINDS = {
    "N_TY_REF", "N_TY_NEGATION", "N_TY_SELF", "N_TY_INFER", "N_TY_EFFECT_ROW",
    "N_TY_EFFECT_ELEM", "N_TY_FORALL", "N_TY_EXISTS", "N_TY_TYPEOF", "N_TY_REFINE",
}
CONSUMED_BY_PARENT.update({
    k: "type syntax, resolved before lowering; Low.ty reads it, not a case dispatch"
    for k in TYPE_KINDS
})
_TAIL = {
}


def nodekinds() -> list[str]:
    src = (ROOT / "pfront" / "pfront_core.c3").read_text(encoding="utf-8")
    m = re.search(r"enum NodeKind : int\s*\{(.*?)\n\}", src, re.S)
    if not m:
        sys.exit("could not find enum NodeKind in pfront_core.c3")
    out: list[str] = []
    body = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S)
    for line in body.split("\n"):
        line = re.sub(r"//.*", "", line)
        for k in re.findall(r"\bN_[A-Z_0-9]+\b", line):
            if k not in out:
                out.append(k)
    return [k for k in out if k != "N_KIND_COUNT"]


def dispatched() -> set[str]:
    got: set[str] = set()
    for rel in ("pfront/pear_ir/air_low.c3", "pfront/pear_ir/air_lower.c3"):
        src = (ROOT / rel).read_text(encoding="utf-8")
        got |= set(re.findall(r"case\s+(?:Nk\.)?(N_[A-Z_0-9]+)\s*:", src))
    return got


def main() -> None:
    kinds = nodekinds()
    cov = dispatched()
    missing = [k for k in kinds if k not in cov]

    explained = CONSUMED_BY_PARENT | KNOWN_GAPS
    unexplained = [k for k in missing if k not in explained]
    stale = [k for k in explained if k not in missing]

    print(f"NodeKind members   : {len(kinds)}")
    print(f"dispatched in a lowerer: {len(kinds) - len(missing)}")
    print(f"undispatched       : {len(missing)}")
    print(f"  consumed by a parent case : {len([k for k in missing if k in CONSUMED_BY_PARENT])}")
    print(f"  known gap, documented     : {len([k for k in missing if k in KNOWN_GAPS])}")
    print(f"  UNEXPLAINED               : {len(unexplained)}")

    if unexplained:
        print("\nUnexplained — a construct with no case and no note. Add a case,")
        print("or record why a parent consumes it in CONSUMED_BY_PARENT:")
        for k in unexplained:
            print(f"   {k}")

    if stale:
        print("\nStale entries — listed as a gap/parent-consumed but now dispatched.")
        print("Remove them so the file keeps meaning something:")
        for k in stale:
            print(f"   {k}")

    if "--list" in sys.argv:
        print("\nAll undispatched:")
        for k in missing:
            note = explained.get(k, "*** UNEXPLAINED ***")
            print(f"   {k:22s} {note}")


if __name__ == "__main__":
    main()
