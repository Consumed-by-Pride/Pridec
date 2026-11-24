#!/usr/bin/env python3
"""A failed write must not be reported as a successful one.

Every AIR artifact is produced by `fopen` + a long run of `fputs`-style writes +
`fclose`. stdio buffers, so the LAST flush happens inside `fclose` -- after every
individual write has already returned success. On a full disk `fclose` returns
EOF and the file on disk is short or empty.

Measured, not theorised: with the sandbox disk full, `pfrontc x.pie --emit-air`
wrote a **0-byte** `.air` and still printed `errors=0`, and
`--emit-air-low` behaved the same way. Three writers had the shape

    if (path != null) { fclose(f); } else { fflush(f); }

with no check of the return value, so the failure was invisible to the caller
and the artifact was published anyway. That is the same "the tool says yes while
doing something else" class as the `fmt` truncation and the wildcard patterns:
the consumer cannot tell a good artifact from a bad one.

Source-level test: no built compiler required.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
IR = ROOT / "pfront" / "pear_ir"

# Writers that own the artifact on disk. `slurp`/`read_file` are readers -- a
# failed fclose there can lose nothing, so they are out of scope.
WRITERS = ["air_write.c3", "air_ll.c3", "air_emit.c3"]


def _strip_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)


class WriteResultTests(unittest.TestCase):
    def test_no_writer_discards_its_close_result(self):
        offenders = []
        for name in WRITERS:
            path = IR / name
            if not path.exists():
                continue
            text = _strip_comments(path.read_text())
            for m in re.finditer(r"\b(fclose|fflush)\s*\(\s*(\w+)\s*\)", text):
                # Skip the extern declarations themselves.
                line_start = text.rfind("\n", 0, m.start()) + 1
                if text[line_start:m.start()].lstrip().startswith("extern"):
                    continue
                handle = m.group(2)
                # Only the ARTIFACT handle matters. stderr/stdout diagnostics
                # losing a line is not a corrupt artifact.
                if handle in ("se", "std_out", "stdout", "stderr"):
                    continue
                # A checked close captures the result in its own statement...
                start = text.rfind(";", 0, m.start()) + 1
                end = text.find(";", m.end())
                stmt = text[start:end + 1] if end != -1 else text[start:]
                if re.search(r"(=|return|if\s*\(|&&|\|\|)", stmt):
                    continue
                # ...an unchecked one is a bare call in statement position.
                offenders.append((name, text[:m.start()].count("\n") + 1,
                                  " ".join(stmt.split())))
        self.assertEqual(
            [], offenders,
            "a writer discards the result of close/flush; on a full disk the "
            "artifact is short or empty and the caller is told it succeeded:\n"
            + "\n".join(f"  {n}:{ln}: {s}" for n, ln, s in offenders),
        )

    def test_write_module_reports_a_failed_flush(self):
        # The primary writer: the close result must reach `w.errs`, which
        # write_module returns and emit_air_program turns into a refusal.
        text = (IR / "air_write.c3").read_text()
        m = re.search(r"fn int write_module\(.*?\n\}", text, re.S)
        self.assertIsNotNone(m, "write_module not found")
        body = m.group(0)
        self.assertRegex(
            body, r"close_rc|fclose\([^)]*\)\s*!=\s*0|if\s*\(\s*fclose",
            "write_module does not check its close; a full disk yields a "
            "0-byte .air reported as success",
        )
        self.assertRegex(
            body, r"w\.errs\s*=\s*w\.errs\s*\+\s*1|w\.errs\s*=\s*1",
            "write_module checks the close but does not count it as a writer "
            "error, so the caller still cannot tell",
        )

    def test_emit_module_can_fail(self):
        # `--emit-air-pretty` goes through air_emit::emit_module, which used to
        # return void and therefore could not report anything at all.
        text = (IR / "air_emit.c3").read_text()
        m = re.search(r"fn\s+(\w+)\s+emit_module\s*\(", text)
        self.assertIsNotNone(m, "emit_module not found")
        self.assertEqual(
            "int", m.group(1),
            "emit_module returns void, so a failed write cannot be reported",
        )


class StaleArtifactTests(unittest.TestCase):
    """Refusing to emit must not leave the previous artifact in place.

    A failed compile used to return before writing, leaving whatever `.air` was
    already on disk. Measured: a 551 KB artifact from an earlier good run
    survived a compile that reported an error, with the same path, the same size
    and nothing to distinguish it. Nothing downstream compares mtimes, so a
    consumer reads a program that does not match the source.

    The repository's own rule for the removed --emit-exe flag is that it "fails
    loudly instead of being ignored, so a stale script cannot believe it built
    something". A stale .air breaks the same rule quietly.
    """

    MAIN = ROOT / "pfront" / "pfront_main.c3"

    def test_refusal_removes_the_stale_artifact(self):
        text = self.MAIN.read_text()
        self.assertRegex(
            text, r"derive_air_path\([^)]*\)[\s\S]{0,400}?remove\(",
            "the refusal path does not remove the stale .air; a failed compile "
            "leaves the previous artifact looking current",
        )

    def test_stdout_target_is_not_removed(self):
        text = self.MAIN.read_text()
        # `-` means stdout: there is no file to remove, and calling remove("-")
        # must not run.
        self.assertRegex(
            text, r"path\[0\] == '-'",
            "the stale-artifact cleanup does not exclude the stdout target",
        )

if __name__ == "__main__":
    unittest.main()
