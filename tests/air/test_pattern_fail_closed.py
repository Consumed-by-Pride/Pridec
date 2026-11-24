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


if __name__ == "__main__":
    unittest.main()
