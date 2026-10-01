"""Check example error floors, never infer success from an AIR artifact."""
import csv
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BIN = ROOT / "pfrontc"


@unittest.skipUnless(BIN.is_file(), "build pfrontc first")
class ExampleContracts(unittest.TestCase):
    def test_all_published_examples_match_the_recorded_error_floors(self):
        with (ROOT / "examples/STATUS.tsv").open() as file:
            rows = list(csv.DictReader(file, delimiter="\t"))
        self.assertEqual({row["file"] for row in rows},
                         {file.name for file in (ROOT / "examples").glob("*.pie")})
        for row in rows:
            with self.subTest(example=row["file"]):
                env = {**os.environ, "LD_LIBRARY_PATH": str(Path.home() / ".cache/llvm23")
                       + ":/usr/lib/x86_64-linux-gnu"}
                run = subprocess.run([str(BIN), "examples/" + row["file"], "--emit-air", "--quiet"],
                                     cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
                self.assertIn(run.returncode, (0, 1, 2), run.stderr)
                summary = re.search(r"errors=(\d+) warnings=(\d+) modules=(\d+)", run.stdout)
                self.assertIsNotNone(summary, run.stdout[-500:] + run.stderr[-500:])
                errors, warnings = int(summary[1]), int(summary[2])
                self.assertEqual(run.returncode, 2 if errors else (1 if warnings else 0))
                self.assertLessEqual(errors, int(row["errors"]),
                                     f"new compiler errors in {row['file']}: {run.stdout[-500:]}")
                if errors < int(row["errors"]):
                    print(f"IMPROVED example {row['file']}: update examples/STATUS.tsv")


if __name__ == "__main__":
    unittest.main()
