#!/usr/bin/env python3
"""Gate on the AST->AIR dispatch audit.

The acceptance criterion is "every construct lowers to .air". That cannot be
checked by counting fixtures: a construct with no `case` in either lowerer falls
through to a `default:` arm, and whether that arm refuses loudly or returns a
plausible value quietly decides whether the gap is visible at all.

`or`-patterns sat in exactly that hole -- the IR could already express them
(APAT_OR), the parser produced them, and the lowerer refused them with a message
that made it sound like a backend limitation rather than missing front-end work.

This runs tools/air_kind_coverage.py, which walks the enum against the dispatch
tables. It fails when a kind is undispatched AND has no recorded reason, and
also when a recorded reason goes stale (so the list keeps meaning something).

Runs without a built compiler by design: it reads source.
"""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "tools" / "air_kind_coverage.py"


class KindCoverageTests(unittest.TestCase):
    def run_tool(self) -> str:
        proc = subprocess.run(
            [sys.executable, str(TOOL)], capture_output=True, text=True, timeout=120
        )
        self.assertEqual(proc.returncode, 0, proc.stderr[:2000])
        return proc.stdout

    def test_every_undispatched_kind_has_a_recorded_reason(self):
        out = self.run_tool()
        self.assertIn("UNEXPLAINED", out)
        # The summary line is "  UNEXPLAINED               : N".
        line = [l for l in out.splitlines() if "UNEXPLAINED" in l][0]
        n = int(line.rsplit(":", 1)[1].strip())
        self.assertEqual(
            0, n,
            "a NodeKind has no `case` in either lowerer and no recorded reason. "
            "Either lower it, or add it to CONSUMED_BY_PARENT/KNOWN_GAPS in "
            "tools/air_kind_coverage.py with why it never reaches a dispatch.\n\n"
            + out,
        )

    def test_no_stale_entries(self):
        """A recorded reason for a kind that IS dispatched is now a lie."""
        out = self.run_tool()
        self.assertNotIn("Stale entries", out, out)

    def test_or_patterns_are_dispatched(self):
        """Regression: or-patterns were refused with "pattern (not lowered yet)".

        AIR already had APAT_OR; only the producer was missing.
        """
        # N_PAT_OR is dispatched, so it must appear in NEITHER the unexplained
        # list nor the known-gap list -- the audit seeing it at all is what
        # matters, and it does not need a reason once it has a case.
        out = self.run_tool()
        self.assertNotIn("N_PAT_OR", out)

        low = (ROOT / "pfront" / "pear_ir" / "air_low.c3").read_text(encoding="utf-8")
        self.assertIn(
            "case Nk.N_PAT_OR:",
            low,
            "the or-pattern lowering was removed; it is what makes "
            "tests/pfront/syntax/x11_or_patterns.pie lower",
        )


if __name__ == "__main__":
    unittest.main()
