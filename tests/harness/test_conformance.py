"""Regression tests for the conformance harness, not compiler capabilities."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("conformance_run", ROOT / "conformance/run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ConformanceHarnessTests(unittest.TestCase):
    def evaluate(self, comments, output, rc):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "case.pie"
            source.write_text(comments + "\nfn main(_) -> i64 { return 0; }\n")
            return runner.evaluate(source, output, rc)

    def test_real_clean_summary(self):
        self.assertEqual([], self.evaluate("-- EXPECT-CLEAN", "=== summary ===\n  errors : 0\n  warnings : 0\n", 0))

    def test_missing_compiler_is_not_clean(self):
        self.assertTrue(self.evaluate("-- EXPECT-CLEAN", "./pride: No such file or directory", 127))

    def test_crash_is_not_clean(self):
        self.assertTrue(self.evaluate("-- EXPECT-CLEAN", "", -11))

    def test_changed_diagnostic_format_is_not_clean(self):
        self.assertTrue(self.evaluate("-- EXPECT-CLEAN", "error in unknown format\n  errors : 1\n  warnings : 0\n", 2))

    def test_warning_breaks_clean(self):
        out = "  case.pie:2:4: warning [W4001/resolve] unused binding\n  errors : 0\n  warnings : 1\n"
        self.assertTrue(self.evaluate("-- EXPECT-CLEAN", out, 1))

    def test_no_expectation_still_checks_compile_errors(self):
        out = "  case.pie:2:4: error [E1012/parse] expected expression\n  errors : 1\n  warnings : 0\n"
        self.assertTrue(self.evaluate("-- explanatory comment only", out, 2))

    def test_expected_error_checks_location_and_literal_text(self):
        out = "  case.pie:2:4: error [E3005/resolve] unresolved name\n  errors : 1\n  warnings : 0\n"
        self.assertEqual([], self.evaluate("-- EXPECT: resolve 2:4 unresolved name", out, 2))
        self.assertTrue(self.evaluate("-- EXPECT: resolve 2:5 unresolved name", out, 2))
        self.assertTrue(self.evaluate("-- EXPECT: resolve 2:4 undefined name", out, 2))

    def test_zero_count_does_not_hide_other_errors(self):
        out = "  case.pie:2:4: error [E1012/parse] expected expression\n  errors : 1\n  warnings : 0\n"
        self.assertTrue(self.evaluate("-- EXPECT-COUNT: type-err=0", out, 2))

    def test_count_for_parse_uses_real_diagnostics(self):
        out = "  case.pie:2:4: error [E1012/parse] expected expression\n  errors : 1\n  warnings : 0\n"
        self.assertEqual([], self.evaluate("-- EXPECT-COUNT: parse=1", out, 2))

    def test_imported_diagnostic_does_not_match_source_location(self):
        out = "  other.pie:2:4: error [E3005/resolve] unresolved name\n  errors : 1\n  warnings : 0\n"
        self.assertTrue(self.evaluate("-- EXPECT: resolve 2:4 unresolved name", out, 2))

    def test_unknown_warning_format_is_not_clean(self):
        self.assertTrue(self.evaluate("-- EXPECT-CLEAN", "unknown warning\n  errors : 0\n  warnings : 1\n", 1))

    def test_extra_same_phase_error_is_not_expected(self):
        out = ("  case.pie:2:4: error [E3005/resolve] unresolved name\n"
               "  case.pie:2:8: error [E3005/resolve] unresolved name\n"
               "  errors : 2\n  warnings : 0\n")
        self.assertTrue(self.evaluate("-- EXPECT: resolve 2:4 unresolved name", out, 2))

    def test_missing_binary_fails_before_case_counts(self):
        env = {**os.environ, "PFRONT_BIN": "/nonexistent/agent-n3/pfrontc"}
        result = subprocess.run(["bash", str(ROOT / "conformance/run.sh")],
                                env=env, capture_output=True, text=True)
        self.assertEqual(2, result.returncode)
        self.assertIn("FATAL", result.stderr)
        self.assertNotIn("conformance pass=", result.stdout)


if __name__ == "__main__":
    unittest.main()
