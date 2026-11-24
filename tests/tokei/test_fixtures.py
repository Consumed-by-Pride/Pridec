#!/usr/bin/env python3
"""Sanity checks for the generated multi-language lexer workload.

These guard the WORKLOAD, not the compiler -- tests/tokei/run.sh does that.
The distinction matters: everything here runs without a built pfrontc, so it
must not claim anything about compilation.

The previous version asserted `program_lines >= 5000`. That is a line-count
target dressed up as a test: it cannot fail for a good reason, it passes by
adding filler, and it was satisfied by 3.2k lines of near-duplicate generated
code. Replaced with checks that fail when the workload stops being what it is
supposed to be.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "examples" / "tokei"


class TokeiCorpusTests(unittest.TestCase):
    def test_catalogue_matches_fixture_count(self):
        """LANGUAGE_COUNT must equal the number of fixture files.

        This is the one place the program's own idea of the corpus and the
        corpus on disk are compared. It is a tautology only if both sides are
        generated from each other; they are not -- languages.pie is
        hand-structured and fixtures/ are separate files.
        """
        source = (APP / "languages.pie").read_text(encoding="utf-8")
        match = re.search(r"const LANGUAGE_COUNT\s*:\s*i64\s*=\s*(\d+)i64", source)
        self.assertIsNotNone(match)
        expected = int(match.group(1))
        fixtures = sorted((APP / "fixtures").iterdir())
        self.assertEqual(expected, len(fixtures))
        self.assertEqual(
            expected,
            len({path.suffix.lower() for path in fixtures}),
            "fixtures must have distinct extensions or the catalogue double-counts",
        )

    def test_every_fixture_is_a_stable_thirty_two_line_input(self):
        """Each fixture is exactly 32 lines.

        The scanner's self-test asserts exact line/code/comment/blank counts, so
        a fixture whose length drifts would make those assertions wrong rather
        than making them fail.
        """
        for path in sorted((APP / "fixtures").iterdir()):
            with self.subTest(path=path.name):
                self.assertEqual(32, len(path.read_text(encoding="utf-8").splitlines()))

    def test_stress_workload_is_current(self):
        """stress.pie must match what its generator produces.

        The workload's value is the number of functions it puts through the
        front end. A hand-edited or stale copy can silently shrink it -- fewer
        cases, a dropped batch, a checksum that no longer covers every batch --
        without any test noticing, because nothing asserts the count.
        """
        src = APP / "stress.pie"
        self.assertTrue(src.exists(), "examples/tokei/stress.pie is missing")
        text = src.read_text(encoding="utf-8")

        cases = re.findall(r"^fn stress_case_(\d{3}) : i64 -> i64$", text, re.M)
        self.assertGreaterEqual(
            len(cases), 300, "the stress workload must keep at least 300 distinct cases"
        )
        self.assertEqual(
            sorted(cases), [f"{i:03d}" for i in range(len(cases))],
            "stress cases must be numbered contiguously from 000",
        )

        # Every batch must be called by the checksum, and the checksum must
        # cover every batch -- otherwise part of the workload is dead code that
        # still costs compile time while proving nothing.
        batches = re.findall(r"^fn stress_batch_(\d{2}) : i64 -> i64$", text, re.M)
        self.assertGreaterEqual(len(batches), 1)
        checksum = text.split("fn stress_checksum", 1)[-1]
        for b in batches:
            self.assertIn(
                f"stress_batch_{b}(", checksum, f"batch {b} is never called by the checksum"
            )

        # Prove the file is what the generator says, not merely plausible.
        gen = ROOT / "tools" / "gen_tokei_stress.py"
        self.assertTrue(gen.exists(), "tools/gen_tokei_stress.py is missing")
        before = src.read_bytes()
        try:
            __import__("subprocess").run(
                ["python3", str(gen)], check=True, capture_output=True
            )
            self.assertEqual(
                before, src.read_bytes(),
                "examples/tokei/stress.pie is stale: regenerate with "
                "`make gen-tokei-stress` and commit the result",
            )
        finally:
            src.write_bytes(before)

    def test_workload_is_not_mostly_generated(self):
        """Hand-written logic must stay a real share of the program.

        stress.pie and languages.pie are mechanical. If they grow to dominate,
        the "large program" claim is really a claim about a code generator, and
        the hand-written part -- the part that finds real parser bugs -- shrinks
        quietly.
        """
        total = sum(len(p.read_text(encoding="utf-8").splitlines()) for p in APP.glob("*.pie"))
        generated = sum(
            len((APP / name).read_text(encoding="utf-8").splitlines())
            for name in ("stress.pie", "languages.pie")
        )
        self.assertLess(
            generated / total, 0.85,
            f"generated code is {generated}/{total} lines ({generated*100//total}%) "
            "-- the hand-written workload is being crowded out",
        )


if __name__ == "__main__":
    unittest.main()
