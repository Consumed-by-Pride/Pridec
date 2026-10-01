"""Negative tests for source-inventory failures (C exports are checked separately)."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hose_checker", ROOT / "scripts/check_hose_consistency.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class HoseInventoryTests(unittest.TestCase):
    def test_current_sources_agree_with_required_exports(self):
        with patch.object(checker, "build_runtime_exports", return_value=(set(checker.HOSE_SYMBOLS), [])):
            self.assertEqual([], checker.check_runtime_symbols())

    def test_missing_c_definition_cannot_pass_on_a_comment(self):
        exports = set(checker.HOSE_SYMBOLS) - {"__pride_fiber_spawn"}
        with patch.object(checker, "build_runtime_exports", return_value=(exports, [])):
            errors = checker.check_runtime_symbols()
        self.assertIn("Symbol __pride_fiber_spawn missing from compiled C runtime exports", errors)

    def test_missing_source_files_are_reported_not_crashed(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(checker, "REPO_ROOT", Path(directory)), \
                 patch.object(checker, "build_runtime_exports", return_value=(set(checker.HOSE_SYMBOLS), [])):
                errors = checker.check_runtime_symbols()
        self.assertTrue(any("Cannot read pfront/pear_ir/pear.c3" in error for error in errors))
        self.assertTrue(any("Cannot read stdlib/pride/effects.pie" in error for error in errors))

    def test_comment_only_externs_are_not_bindings(self):
        original = checker.read_source
        def commented(relative, errors):
            text = original(relative, errors)
            return "\n".join("-- " + line for line in text.splitlines()) if relative.endswith("effects.pie") else text
        with patch.object(checker, "build_runtime_exports", return_value=(set(checker.HOSE_SYMBOLS), [])), \
             patch.object(checker, "read_source", side_effect=commented):
            errors = checker.check_runtime_symbols()
        self.assertTrue(any("extern bindings" in error for error in errors))

    def test_libc_allocation_declaration_is_checked(self):
        original = checker.read_source
        def no_malloc(relative, errors):
            text = original(relative, errors)
            return text.replace('ll_add_fn(m, (char*)"malloc",', 'll_add_fn(m, (char*)"not_malloc",')
        with patch.object(checker, "build_runtime_exports", return_value=(set(checker.HOSE_SYMBOLS), [])), \
             patch.object(checker, "read_source", side_effect=no_malloc):
            errors = checker.check_runtime_symbols()
        self.assertIn("Current PEAR declaration for libc malloc is missing", errors)


if __name__ == "__main__":
    unittest.main()
