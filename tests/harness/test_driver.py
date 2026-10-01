"""CLI/reachability polish contracts, using the actual built compiler."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "pfrontc"


@unittest.skipUnless(BIN.is_file(), "build pfrontc first")
class DriverTests(unittest.TestCase):
    def run_compiler(self, *args):
        return subprocess.run([str(BIN), *map(str, args)], cwd=ROOT,
                              env={**os.environ, "LD_LIBRARY_PATH": str(Path.home() / ".cache/llvm23")
                                   + ":/usr/lib/x86_64-linux-gnu"},
                              capture_output=True, text=True, timeout=20)

    def test_help_documents_real_module_contract(self):
        result = self.run_compiler("--help")
        self.assertEqual(0, result.returncode)
        self.assertIn("directory module roots", result.stdout)
        self.assertIn("mm.pie", result.stdout)
        self.assertIn("no roots means a library", result.stdout)

    def test_unknown_options_are_not_silently_ignored(self):
        for option in ("-o", "--frobnicate"):
            with self.subTest(option=option):
                result = self.run_compiler("/dev/null", option, "/tmp/not-an-output")
                self.assertEqual(2, result.returncode)
                self.assertIn(f"unknown option '{option}'", result.stdout)
                self.assertNotIn("errors=", result.stdout)

    def test_option_arguments_are_validated(self):
        for args in (("-I",), ("--context",), ("--context", "nope"),
                     ("--context", "-1")):
            with self.subTest(args=args):
                result = self.run_compiler("/dev/null", *args)
                self.assertEqual(2, result.returncode)
                self.assertIn("requires", result.stdout)

    def test_help_after_input(self):
        self.assertEqual(0, self.run_compiler("/dev/null", "--help").returncode)

    def test_directory_input_is_not_false_success(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_compiler(directory)
            self.assertEqual(2, result.returncode)
            self.assertIn("input is a directory", result.stdout)
            self.assertIn("-I", result.stdout)

    def test_dead_code_is_opt_in_and_names_the_function(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "dead.pie"
            source.write_text("fn dead_fn(_) -> i64 { return 1; }\n"
                              "fn main(_) -> i64 { return 0; }\n")
            regular = self.run_compiler(source, "--plain")
            flagged = self.run_compiler(source, "--plain", "--dead-code")
            self.assertNotIn("W4020", regular.stdout)
            self.assertIn("W4020", flagged.stdout)
            self.assertIn("hint: dead_fn", flagged.stdout)

    def test_library_and_public_roots_are_not_called_dead(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "lib.pie"
            source.write_text("fn helper(_) -> i64 { return 1; }\n")
            self.assertNotIn("W4020", self.run_compiler(source, "--dead-code").stdout)
            source.write_text("pub fn exported(_) -> i64 { return 1; }\n"
                              "fn main(_) -> i64 { return 0; }\n")
            self.assertNotIn("W4020", self.run_compiler(source, "--dead-code").stdout)

    def test_modules_resolve_by_filename_with_directory_root(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / "entry.pie"
            source.write_text("use mm;\nfn main(_) -> i64 { return twice(21); }\n")
            module = folder / "mm.pie"
            module.write_text("mod mm\npub fn twice(x: i64) -> i64 { return x + x; }\n")
            result = self.run_compiler(source, "-I", folder, "--plain")
            self.assertNotEqual(2, result.returncode)
            self.assertNotIn("E2002", result.stdout)
            module.rename(folder / "different.pie")
            result = self.run_compiler(source, "-I", folder, "--plain")
            self.assertEqual(2, result.returncode)
            self.assertIn("E2002", result.stdout)


if __name__ == "__main__":
    unittest.main()
