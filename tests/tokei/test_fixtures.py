#!/usr/bin/env python3
"""Sanity checks for the generated multi-language lexer workload."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "examples" / "tokei"


class TokeiCorpusTests(unittest.TestCase):
    def test_catalogue_and_fixtures_have_one_file_per_language(self):
        source = (APP / "languages.pie").read_text(encoding="utf-8")
        match = re.search(r"const LANGUAGE_COUNT\s*:\s*i64\s*=\s*(\d+)i64", source)
        self.assertIsNotNone(match)
        expected = int(match.group(1))
        fixtures = sorted((APP / "fixtures").iterdir())
        self.assertEqual(expected, len(fixtures))
        self.assertEqual(expected, len({path.suffix.lower() for path in fixtures}))

    def test_each_fixture_is_a_stable_thirty_two_line_input(self):
        for path in sorted((APP / "fixtures").iterdir()):
            with self.subTest(path=path.name):
                self.assertEqual(32, len(path.read_text(encoding="utf-8").splitlines()))

    def test_pride_program_itself_reaches_large_program_scale(self):
        program_lines = sum(len(path.read_text(encoding="utf-8").splitlines())
                            for path in APP.glob("*.pie"))
        self.assertGreaterEqual(program_lines, 5000)


if __name__ == "__main__":
    unittest.main()
