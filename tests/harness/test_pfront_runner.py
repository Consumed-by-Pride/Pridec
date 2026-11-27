"""The pfront shell harness must never count a crashed compiler as a clean case."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tests/harness/pfront_case.sh"


class PfrontRunnerTests(unittest.TestCase):
    def check(self, rc, output):
        script = (
            f"source {str(HELPER)!r}; "
            "if pfront_check_case_result \"$CASE_OUTPUT\" \"$CASE_RC\" tests/pfront/example.pie; then "
            "printf 'ok:%s' \"$PFRONT_CASE_ERRORS\"; "
            "else printf 'bad:%s' \"$PFRONT_CASE_FAILURE\"; fi"
        )
        return subprocess.run(
            ["bash", "-c", script],
            env={**os.environ, "CASE_OUTPUT": output, "CASE_RC": str(rc)},
            text=True, capture_output=True, check=True,
        ).stdout

    def test_crash_with_empty_output_is_rejected(self):
        self.assertIn("bad:compiler exited abnormally (rc=139)", self.check(139, ""))

    def test_missing_summary_is_rejected(self):
        self.assertIn("bad:missing or malformed compiler summary", self.check(0, ""))

    def test_valid_clean_result_is_counted(self):
        out = "=== summary ===\n  modules   : 1\n  errors    : 0\n  warnings  : 0\n"
        self.assertEqual("ok:0", self.check(0, out))

    def test_valid_error_result_is_counted_for_source(self):
        out = ("tests/pfront/example.pie:1:1: error[E1/parse] expected expression\n"
               "=== summary ===\n  modules   : 1\n  errors    : 1\n  warnings  : 0\n")
        self.assertEqual("ok:1", self.check(2, out))


if __name__ == "__main__":
    unittest.main()
