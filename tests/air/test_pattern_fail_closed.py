#!/usr/bin/env python3
"""air_lower.c3 must never turn an unmodelled pattern into a wildcard.

The two AIR lowerers disagreed, and the one that disagreed silently produced the
whole-program contract artifact:

  air_low.c3   : `default: lw.unsup(p, "pattern"); return false;`   -- refuses
  air_lower.c3 : `default: return lr.mod.pat_wild;`                 -- guesses

`_` always matches, so an arm whose pattern was not modelled ran for inputs it
was written to exclude. The .air was published looking perfectly well-formed and
nothing reported it. That is the same failure shape as the truncation bugs this
branch has been removing: the tool says yes while doing something else.

It now latches a refusal via AirLower.note_bad, which sets the same fatal flag as
an allocation failure, so emit_air_program returns -3 and writes nothing.

Source-level test: no built compiler required.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOWER = ROOT / "pfront" / "pear_ir" / "air_lower.c3"
LOW = ROOT / "pfront" / "pear_ir" / "air_low.c3"


class PatternFailClosedTests(unittest.TestCase):
    def test_pat_node_default_does_not_return_a_wildcard(self):
        src = LOWER.read_text(encoding="utf-8")
        m = re.search(r"fn AirPat\* AirLower\.pat_node\(.*?\n\}", src, re.S)
        self.assertIsNotNone(m, "could not find AirLower.pat_node")
        body = m.group(0)
        default = body[body.rindex("default:"):]
        self.assertNotIn(
            "default: return lr.mod.pat_wild;",
            default,
            "pat_node's default returns a wildcard again: an unmodelled pattern "
            "would silently match everything",
        )
        self.assertIn(
            "note_bad", default,
            "pat_node's default must latch a refusal so no .air is published",
        )

    def test_note_bad_latches_the_same_fatal_flag_as_oom(self):
        src = LOWER.read_text(encoding="utf-8")
        for fn in ("AirLower.note_oom", "AirLower.note_bad"):
            m = re.search(rf"fn void {re.escape(fn)}\(.*?\n\}}", src, re.S)
            self.assertIsNotNone(m, f"{fn} is missing")
            self.assertIn("fatal_errors = 1", m.group(0), f"{fn} must latch")

        # The latch is what makes emit_air_program return -3.
        main = (ROOT / "pfront" / "pear_ir" / "air.c3").read_text(encoding="utf-8")
        self.assertIn("lr.fatal_errors != 0", main)
        self.assertIn("return -3", main)

    def test_or_patterns_lower_in_both_lowerers(self):
        """Or-patterns must not be one of the kinds that reaches the default.

        air_low.c3 was the only one that ever handled them; the fix added the
        case to both. If either loses it, one backend refuses and the other
        silently drops the alternatives.
        """
        for path in (LOWER, LOW):
            src = path.read_text(encoding="utf-8")
            self.assertIn(
                "N_PAT_OR", src, f"{path.name} no longer dispatches or-patterns"
            )

    def test_binary_or_pattern_shape_matches_the_ir(self):
        """APAT_OR is binary (sub[0] + or_alt); the fold must match.

        air_write prints `or(a, b)` and air_read parses exactly two operands. A
        producer that stuffed every alternative into `sub[]` would round-trip
        into a different tree.
        """
        ir = (ROOT / "pfront" / "pear_ir" / "air_ir.c3").read_text(encoding="utf-8")
        self.assertIn("or_alt", ir)
        src = LOWER.read_text(encoding="utf-8")
        m = re.search(r"case Nk\.N_PAT_OR:(.*?)case Nk\.", src, re.S)
        self.assertIsNotNone(m)
        body = m.group(1)
        self.assertIn("or_alt", body, "the fold must set or_alt")
        self.assertIn("sub[0]", body, "the fold must set sub[0]")


class NoSilentDefaultTests(unittest.TestCase):
    """No `default:` in the lowerer may return a plausible value unattended.

    Two were found by hand: pat_node returned pat_wild, and control_expr
    returned unit (dropping the computation). Both published a well-formed .air
    for a program the lowerer had not actually modelled. This is the general
    form of that check, so the next one is caught by the suite rather than by
    someone reading the file.

    `default: return null` and delegation to another function are allowed: null
    is the "no decl here" answer for a decl dispatcher, and delegating keeps the
    real decision in the callee, which is checked on its own.
    """

    ALLOWED = (
        "return null",                 # decl dispatchers: no decl of this kind
        "return lr.prd_or_bind(n)",    # producer fallback: the callee decides
        "return lr.cut(lr.mod.p_unit, k);"  # only inside the handled reasons above
    )

    # Predicates and queries answer a yes/no question about AIR that has already
    # been built; `false` is a real answer there, not a lowering decision. Only
    # functions that PRODUCE AIR must refuse instead of guessing.
    PRODUCER_PREFIXES = (
        "AirCmd* AirLower.", "AirPrd* AirLower.", "AirPat* AirLower.",
        "AirDecl* AirLower.", "Vx AirLower.",
    )

    def test_no_bare_default_returns(self):
        """A block-form default must refuse, or delegate, before returning AIR.

        Heuristic and deliberately narrow: for each `default:` inside a producer
        function, scan to the end of its block and require that the block either
        latches a refusal (note_bad/unsup/fail) or returns something the block
        above already justified. The check is on the *whole* default block, not
        a fixed window -- the first version used 12 lines and flagged three
        defaults that were fine (one had a long comment, two delegate).
        """
        src = LOWER.read_text(encoding="utf-8")
        lines = src.splitlines()

        owning: list[str] = []
        cur = ""
        for line in lines:
            m = re.match(r"fn\s+([A-Za-z_][\w:*\[\]]*\s+[\w.]+)\(", line)
            if m:
                cur = m.group(1)
            owning.append(cur)

        offenders = []
        for i, line in enumerate(lines):
            if "default:" not in line:
                continue
            if not owning[i].startswith(self.PRODUCER_PREFIXES):
                continue
            if re.search(r"default:\s*return\s+", line):
                tail = line.split("default:", 1)[1].strip()
                if any(a in tail for a in ("return null", "return lr.prd_or_bind(n)")):
                    continue
                offenders.append((i + 1, line.strip()))
                continue
            # Block form: read until the braces balance out of the default arm.
            depth = 0
            block = []
            for j in range(i + 1, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                block.append(lines[j])
                if depth <= 0 and "{" in "".join(block):
                    break
            text = "\n".join(block)
            # A refusal latched in the block.
            if ("note_bad" in text or ".unsup(" in text or "fail(" in text):
                continue
            # An explicit poison marker: the .air is left obviously wrong rather
            # than silently wrong. That is the acceptable fallback for a kind the
            # lowerer cannot classify, and it is deliberately visible.
            if "air_mk_poison" in text:
                continue
            # A guarded delegation: the block classifies the node first
            # (is_expr / a kind range) and only substitutes unit for the residue.
            if re.search(r"if\s*\([^)]*(is_expr|Nk\.|kind)", text) and "return lr." in text:
                continue
            if re.search(r"\breturn\s+(lr\.|air_ir::)", text):
                offenders.append((i + 1, line.strip()))

        self.assertEqual(
            [], offenders,
            "a `default:` in a producer returns AIR without latching a refusal; "
            "an unmodelled construct would publish a wrong .air:\n"
            + "\n".join(f"  line {n}: {t}" for n, t in offenders),
        )


class LowererParityTests(unittest.TestCase):
    """Constructs one lowerer models and the other does not must not be guessed.

    `x05_lowlevel_ub.pie` is a PASSING test whose `.air` was silently wrong:
    `Low.pat` lowered `| { x: 0i64, y } -> y` correctly, while `pat_node` turned
    both arms into `_` and dropped every field binding. The 2.2 artifact and the
    3.0 artifact for the same program disagreed and nothing compared them.

    These tests pin the disagreement so it cannot silently widen: every kind the
    enumeration below names is handled by `Low.pat` and must be either handled by
    `pat_node` or explicitly refused there.
    """

    # Pattern kinds that `Low.pat` dispatches on. Not a wish list -- this is read
    # off air_low.c3 below and cross-checked, so adding a case to one lowerer
    # without deciding about the other fails here.
    PAT_CASES = ["N_PAT_WILDCARD", "N_PAT_IDENT", "N_PAT_LITERAL", "N_PAT_RANGE",
                 "N_PAT_TUPLE", "N_PAT_VARIANT", "N_PAT_STRUCT", "N_PAT_OR"]

    def _pat_cases(self, path, fn_name):
        src = path.read_text()
        # The body of the named fn, brace-balanced from its opening brace.
        m = re.search(r"^fn\s+[\w*][\w*\s]*\." + re.escape(fn_name) + r"\s*\(", src, re.M)
        self.assertIsNotNone(m, f"{fn_name} not found in {path.name}")
        i = src.index("{", m.end())
        depth, j = 0, i
        while j < len(src):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        body = src[i:j]
        return {k for k in self.PAT_CASES if re.search(r"case\s+Nk\." + k + r"\b", body)}, body

    def test_low_pat_handles_every_kind_in_the_vocabulary(self):
        cases, _ = self._pat_cases(LOW, "pat")
        self.assertEqual(set(self.PAT_CASES), cases,
                         "air_low.c3's Low.pat lost a pattern case; update the "
                         "vocabulary here and decide what pat_node must do")

    def test_pat_node_handles_or_refuses_every_kind_low_pat_handles(self):
        handled, body = self._pat_cases(LOWER, "pat_node")
        # Kinds pat_node genuinely lowers.
        missing = [k for k in self.PAT_CASES if k not in handled]
        # Each missing kind must be named in a refusal/comment inside pat_node,
        # so the next reader sees it is a known gap rather than an oversight.
        unrecorded = [k for k in missing if k not in body]
        self.assertEqual(
            [], unrecorded,
            "pat_node neither handles nor names these pattern kinds that Low.pat "
            "does handle; an unrecorded gap is how N_PAT_STRUCT stayed silent:\n"
            + "\n".join(f"  {k}" for k in unrecorded),
        )

    def test_pat_node_does_not_wildcard_a_struct_pattern(self):
        # The exact shape of the x05 miscompile: an N_PAT_STRUCT arm must not
        # come out as APAT_WILD.
        _, body = self._pat_cases(LOWER, "pat_node")
        self.assertNotRegex(
            body,
            r"N_PAT_STRUCT[^;]{0,400}?pat_wild",
            "pat_node maps N_PAT_STRUCT to a wildcard; that arm then matches "
            "every input and its field binders are lost (see x05_lowlevel_ub.pie)",
        )


if __name__ == "__main__":
    unittest.main()
