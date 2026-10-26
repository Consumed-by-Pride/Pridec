"""Regression tests for the differential exec harness, not for the backends.

`scripts/pie-diff.sh` compiles a matrix and `scripts/pie-diff-report.py` turns
the per-cell records into the ledger and the gate. These tests drive the report
engine directly with synthetic records, because the property that matters is
that the gate *cannot* be satisfied by silence:

  * an empty matrix must not pass;
  * a divergence must change the verdict;
  * a divergence that disappears must fail the gate (a fix has to be promoted,
    not left to rot in the baseline);
  * a backend that exits 0 without publishing an executable must never read as
    a pass;
  * both backends agreeing on a wrong answer must be visible (the `spec`
    column), because a purely differential comparison calls that `match`.
"""
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "pie_diff_report", ROOT / "scripts/pie-diff-report.py")
pdr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pdr)


def rec(fixture, opt, backend, *, compile_rc="0", artifact="yes", run_rc="0",
        stdout_hash="-", stdout_bytes="0", want_exit="42", subset="yes", diag=""):
    return {
        "fixture": fixture, "opt": opt, "backend": backend, "subset": subset,
        "want_exit": want_exit, "compile_rc": compile_rc, "artifact": artifact,
        "run_rc": run_rc, "stdout_hash": stdout_hash, "stdout_bytes": stdout_bytes,
        "diag": diag,
    }


class CellVerdictTests(unittest.TestCase):
    """The verdict vocabulary, one case each."""

    def v(self, a, b):
        return pdr.cell_verdict(a, b)

    def test_identical_runs_match(self):
        self.assertEqual("match", self.v(
            rec("f", "-O0", "pear1c", run_rc="42"),
            rec("f", "-O0", "pear2c", run_rc="42")))

    def test_different_exit_status_diverges(self):
        self.assertEqual("diverge-exit", self.v(
            rec("f", "-O0", "pear1c", run_rc="42"),
            rec("f", "-O0", "pear2c", run_rc="7")))

    def test_same_exit_different_stdout_diverges(self):
        self.assertEqual("diverge-stdout", self.v(
            rec("f", "-O0", "pear1c", run_rc="0", stdout_hash="aaaa"),
            rec("f", "-O0", "pear2c", run_rc="0", stdout_hash="bbbb")))

    def test_subset_rejection_is_expected_not_fail(self):
        self.assertEqual("expected-reject", self.v(
            rec("f", "-O0", "pear1c", run_rc="42"),
            rec("f", "-O0", "pear2c", compile_rc="3", artifact="no",
                diag="prog.air:4:3: unsupported form `handle` in main")))

    def test_reference_rejection_is_named_as_such(self):
        self.assertEqual("pear1-reject", self.v(
            rec("f", "-O0", "pear1c", compile_rc="3", artifact="no"),
            rec("f", "-O0", "pear2c", run_rc="42")))

    def test_both_reject(self):
        self.assertEqual("both-reject", self.v(
            rec("f", "-O0", "pear1c", compile_rc="3", artifact="no"),
            rec("f", "-O0", "pear2c", compile_rc="3", artifact="no")))

    def test_front_end_failure_is_not_a_backend_verdict(self):
        for kind in ("front-error", "front-noartifact"):
            self.assertEqual(kind, self.v(
                rec("f", "-O0", "pear1c", compile_rc=kind, artifact="no"),
                rec("f", "-O0", "pear2c", compile_rc=kind, artifact="no")))


class ArtifactHonestyTests(unittest.TestCase):
    """CONTRACT.md section 1: exit 0 with no artifact is a defect, not a pass."""

    def test_exit_zero_without_artifact_is_recorded_not_passed(self):
        cells = {
            "f": {"-O0": {
                "pear1c": rec("f", "-O0", "pear1c", run_rc="42"),
                "pear2c": rec("f", "-O0", "pear2c", compile_rc="0",
                              artifact="no", diag="exit 0 but no executable"),
            }}}
        rows = pdr.build_rows(cells)
        pear2 = [r for r in rows if r["backend"] == "pear2c"][0]
        self.assertEqual(pdr.NO_ARTIFACT_RC, pear2["run_rc"])
        self.assertEqual("expected-reject", pear2["verdict"])
        self.assertEqual("na", pear2["spec"])

    def test_never_a_match_when_one_side_produced_nothing(self):
        cells = {
            "f": {"-O0": {
                "pear1c": rec("f", "-O0", "pear1c", compile_rc="3", artifact="no"),
                "pear2c": rec("f", "-O0", "pear2c", compile_rc="3", artifact="no"),
            }}}
        for row in pdr.build_rows(cells):
            self.assertNotEqual("match", row["verdict"])


class SpecColumnTests(unittest.TestCase):
    """`match` means "the backends agree", never "the answer is right"."""

    def rows(self, run_rc):
        return pdr.build_rows({"f": {"-O0": {
            "pear1c": rec("f", "-O0", "pear1c", run_rc=run_rc, want_exit="42"),
            "pear2c": rec("f", "-O0", "pear2c", run_rc=run_rc, want_exit="42"),
        }}})

    def test_agreeing_but_wrong_is_visible(self):
        rows = self.rows("0")
        for row in rows:
            self.assertEqual("match", row["verdict"])
            self.assertEqual("exit-mismatch", row["spec"])
        md = pdr.render_md(rows, {})
        self.assertIn("Both backends agree and both miss the declared exit code", md)

    def test_agreeing_and_correct(self):
        for row in self.rows("42"):
            self.assertEqual("exit-ok", row["spec"])

    def test_no_run_is_not_judged(self):
        rows = pdr.build_rows({"f": {"-O0": {
            "pear1c": rec("f", "-O0", "pear1c", run_rc="42"),
            "pear2c": rec("f", "-O0", "pear2c", compile_rc="3", artifact="no"),
        }}})
        self.assertEqual("na", [r for r in rows if r["backend"] == "pear2c"][0]["spec"])


class NondeterminismTests(unittest.TestCase):
    """A program that does not repeat itself must not be frozen into a baseline."""

    def rows(self):
        return pdr.build_rows({"f": {"-O0": {
            "pear1c": rec("f", "-O0", "pear1c", run_rc=pdr.NONDET_RC,
                          stdout_hash=pdr.NONDET_RC, want_exit="4"),
            "pear2c": rec("f", "-O0", "pear2c", compile_rc="3", artifact="no"),
        }}})

    def test_nondeterministic_run_is_never_exit_ok(self):
        pear1 = [r for r in self.rows() if r["backend"] == "pear1c"][0]
        self.assertEqual("nondeterministic", pear1["spec"])
        self.assertEqual(pdr.NONDET_RC, pear1["run_rc"])

    def test_nondeterministic_does_not_match_a_rejecting_backend(self):
        self.assertEqual("expected-reject", self.rows()[0]["verdict"])

    def test_two_nondeterministic_runs_do_not_agree(self):
        rows = pdr.build_rows({"f": {"-O0": {
            "pear1c": rec("f", "-O0", "pear1c", run_rc=pdr.NONDET_RC),
            "pear2c": rec("f", "-O0", "pear2c", run_rc=pdr.NONDET_RC),
        }}})
        self.assertEqual("match", rows[0]["verdict"])   # both failed to repeat: same fact
        for row in rows:
            self.assertEqual("nondeterministic", row["spec"])

    def test_report_shows_the_nondet_column(self):
        self.assertIn("nondet", pdr.render_md(self.rows(), {}))


class LedgerTests(unittest.TestCase):
    def matrix(self):
        cells = {}
        for opt in pdr.OPTS:
            cells.setdefault("p01", {})[opt] = {
                "pear1c": rec("p01", opt, "pear1c", run_rc="42"),
                "pear2c": rec("p01", opt, "pear2c", run_rc="42"),
            }
        cells["p01"]["-O2"]["pear2c"] = rec(
            "p01", "-O2", "pear2c", compile_rc="3", artifact="no",
            diag="prog.air:4:3: unsupported form `handle` in main")
        cells["p09"] = {"-O0": {
            "pear1c": rec("p09", "-O0", "pear1c", run_rc="9"),
            "pear2c": rec("p09", "-O0", "pear2c", run_rc="9"),
        }}
        return cells

    def test_row_count_is_fixture_x_opt_x_backend(self):
        rows = pdr.build_rows(self.matrix())
        self.assertEqual(4 * 2 + 1 * 2, len(rows))

    def test_first_divergence_is_the_lowest_tier(self):
        divs = pdr.first_divergences(pdr.build_rows(self.matrix()))
        self.assertEqual([("p01", "-O2")], [(d["fixture"], d["opt"]) for d in divs])

    def test_numeric_fixture_order_is_not_lexicographic(self):
        names = ["p100", "p9", "p90", "zebra"]
        self.assertEqual(["p9", "p90", "p100", "zebra"],
                         sorted(names, key=pdr.fixture_sort_key))
        self.assertNotEqual(["p9", "p90", "p100"], sorted(["p9", "p90", "p100"]))

    def test_ledger_is_deterministic_across_cell_insertion_order(self):
        cells = self.matrix()
        one = pdr.render_csv(pdr.build_rows(cells))
        other = {k: dict(reversed(list(v.items()))) for k, v in reversed(list(cells.items()))}
        self.assertEqual(one, pdr.render_csv(pdr.build_rows(other)))

    def test_ledger_carries_no_absolute_paths(self):
        text = pdr.render_csv(pdr.build_rows(self.matrix()))
        self.assertNotIn(str(ROOT), text)
        self.assertNotIn("/home/", text)

    def test_incomplete_cell_pair_is_a_hard_error(self):
        cells = {"p01": {"-O0": {"pear1c": rec("p01", "-O0", "pear1c")}}}
        with self.assertRaises(SystemExit):
            pdr.build_rows(cells)

    def test_record_missing_a_field_is_a_hard_error(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "p01|-O0|pear1c.rec").write_text("fixture=p01\nopt=-O0\n")
            with self.assertRaises(SystemExit):
                pdr.load_cells(d)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.rows = pdr.build_rows({
            "p01": {opt: {
                "pear1c": rec("p01", opt, "pear1c", run_rc="42"),
                "pear2c": rec("p01", opt, "pear2c", run_rc="42"),
            } for opt in pdr.OPTS}
        })
        self.text = pdr.render_csv(self.rows)

    def write_baseline(self, text):
        fh = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8")
        fh.write(text)
        fh.close()
        self.addCleanup(os.unlink, fh.name)
        return fh.name

    def test_identical_ledger_passes(self):
        ok, msgs = pdr.gate(self.text, self.write_baseline(self.text))
        self.assertTrue(ok, msgs)

    def test_missing_baseline_fails_closed(self):
        ok, msgs = pdr.gate(self.text, "/nonexistent/DIFF_BASELINE.csv")
        self.assertFalse(ok)
        self.assertIn("no baseline ledger", msgs[0])

    def test_new_divergence_fails(self):
        base = self.write_baseline(self.text)
        cur = pdr.build_rows({
            "p01": {opt: {
                "pear1c": rec("p01", opt, "pear1c", run_rc="42"),
                "pear2c": rec("p01", opt, "pear2c", run_rc="42" if opt != "-O3" else "11"),
            } for opt in pdr.OPTS}
        })
        ok, msgs = pdr.gate(pdr.render_csv(cur), base)
        self.assertFalse(ok)
        self.assertTrue(any(m.startswith("CHANGED  p01 -O3") for m in msgs), msgs)

    def test_a_fix_fails_until_the_baseline_is_promoted(self):
        # Baseline records an expected-reject; the backend now compiles the case.
        base_rows = pdr.build_rows({
            "p01": {opt: {
                "pear1c": rec("p01", opt, "pear1c", run_rc="42"),
                "pear2c": (rec("p01", opt, "pear2c", run_rc="42") if opt != "-O3"
                           else rec("p01", opt, "pear2c", compile_rc="3", artifact="no")),
            } for opt in pdr.OPTS}
        })
        base = self.write_baseline(pdr.render_csv(base_rows))
        ok, msgs = pdr.gate(self.text, base)
        self.assertFalse(ok, "a disappeared divergence must not pass silently")
        self.assertTrue(any(m.startswith("CHANGED  p01 -O3") for m in msgs), msgs)

    def test_a_vanished_fixture_fails(self):
        base = self.write_baseline(self.text)
        cur = pdr.build_rows({"p01": {"-O0": {
            "pear1c": rec("p01", "-O0", "pear1c", run_rc="42"),
            "pear2c": rec("p01", "-O0", "pear2c", run_rc="42"),
        }}})
        ok, msgs = pdr.gate(pdr.render_csv(cur), base)
        self.assertFalse(ok)
        self.assertEqual(len(pdr.OPTS * 2) - 2, len([m for m in msgs if m.startswith("MISSING")]))

    def test_a_new_fixture_fails_until_baselined(self):
        base = self.write_baseline(self.text)
        cells = {"p01": {opt: {
            "pear1c": rec("p01", opt, "pear1c", run_rc="42"),
            "pear2c": rec("p01", opt, "pear2c", run_rc="42"),
        } for opt in pdr.OPTS}}
        cells["p02"] = {"-O0": {
            "pear1c": rec("p02", "-O0", "pear1c", run_rc="7"),
            "pear2c": rec("p02", "-O0", "pear2c", run_rc="7"),
        }}
        ok, msgs = pdr.gate(pdr.render_csv(pdr.build_rows(cells)), base)
        self.assertFalse(ok)
        self.assertEqual(2, len([m for m in msgs if m.startswith("NEW")]))

    def test_stdout_hash_change_fails(self):
        base = self.write_baseline(self.text)
        cur = pdr.build_rows({"p01": {opt: {
            "pear1c": rec("p01", opt, "pear1c", run_rc="0", stdout_hash="deadbeef"),
            "pear2c": rec("p01", opt, "pear2c", run_rc="0", stdout_hash="feedface"),
        } for opt in pdr.OPTS}})
        ok, msgs = pdr.gate(pdr.render_csv(cur), base)
        self.assertFalse(ok)

    def test_empty_matrix_never_passes(self):
        base = self.write_baseline(self.text)
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit):
                pdr.main(["--cells", d, "--gate", "--baseline", base])

    def test_cli_reports_and_gates(self):
        with tempfile.TemporaryDirectory() as d:
            cells = Path(d, "cells")
            cells.mkdir()
            for row in self.rows:
                # Records hold the raw fields the shell writes (including
                # `artifact`); the ledger's `spec`/`verdict` are derived.
                r = rec(row["fixture"], row["opt"], row["backend"], run_rc="42")
                name = "%s|%s|%s.rec" % (row["fixture"], row["opt"], row["backend"])
                (cells / name).write_text(
                    "".join("%s=%s\n" % (k, r[k]) for k in pdr.RECORD_KEYS))
            base = Path(d, "base.csv")
            self.assertEqual(0, pdr.main([
                "--cells", str(cells), "--gate", "--baseline", str(base), "--bless"]))
            self.assertTrue(base.is_file())
            self.assertEqual(0, pdr.main([
                "--cells", str(cells), "--gate", "--baseline", str(base)]))


if __name__ == "__main__":
    unittest.main()
