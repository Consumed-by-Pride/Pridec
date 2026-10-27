#!/usr/bin/env python3
"""Assemble and gate the PEAR differential execution ledger.

Reads the per-cell records written by ``scripts/pie-diff.sh`` (one small text
file per fixture x opt x backend cell) and produces:

  * a deterministic CSV ledger  — the machine-readable artifact and the gate
    input. No timestamps, no PIDs, no absolute paths, no durations: the same
    tree and the same compilers must produce byte-identical output.
  * a deterministic Markdown report — the human-readable view, including the
    first-divergence table the CSV does not repeat.

Gate semantics (``--gate``): fail only on rows that are NOT in the checked-in
baseline. That covers both directions a ledger can drift:

  * a new divergence appeared (backend regressed)            -> must be triaged
  * a recorded divergence/expected-reject went away (a fix)  -> must be promoted

Silently matching a stale baseline is the failure mode this refuses to have, so
either direction is a hard failure until the baseline is deliberately updated
with ``--bless``.

Verdict vocabulary (one per fixture x opt):

  match            both backends compiled and ran; exit status and stdout agree
  diverge-exit     both ran; exit status differs
  diverge-stdout   both ran; same exit status, stdout differs
  expected-reject  pear1c built and ran, pear2c refused to build it. Correct for
                   an out-of-subset fixture; a defect for one that pear2_cases.txt
                   claims as supported.
  pear1-reject     pear2c built and ran, pear1c did not (legacy backend gap)
  both-reject      neither backend produced a runnable binary
  pear1-noartifact / pear2-noartifact
                   a backend exited 0 (or warned) but published no executable.
                   Never a pass: CONTRACT.md section 1 forbids it.
  front-error      the front end refused the fixture, so there was nothing to
                   compare at this tier
  front-noartifact the front end returned < 2 but wrote no .air
  skipped          the fixture declares no ``-- EXIT:`` marker

A `run_rc` of `nondeterministic` means the executable did not repeat its own
result on a second run, so no single value could be baselined honestly. That is
a defect in the program the backend produced, not a harness artefact.
"""

import argparse
import csv
import hashlib
import io
import os
import sys

# ── record file vocabulary ────────────────────────────────────────────────────
# Each cell file is `key=value` lines, NUL-free, written by pie-diff.sh.
RECORD_KEYS = (
    "fixture", "opt", "backend", "subset", "want_exit",
    "compile_rc", "artifact", "run_rc", "stdout_hash", "stdout_bytes", "diag",
)

BACKENDS = ("pear1c", "pear2c")
OPTS = ("-O0", "-O1", "-O2", "-O3")

# A backend that exits 0 but leaves no executable violated CONTRACT.md section 1.
NO_ARTIFACT_RC = "noartifact"

# The program did not repeat itself; see the second-run check in pie-diff.sh.
NONDET_RC = "nondeterministic"


def read_record(path):
    rec = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            rec[key] = value
    return rec


def sha16(text):
    if text == "":
        return "-"
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()[:16]


def cell_verdict(a, b):
    """Verdict for one fixture x opt, from the pear1c and pear2c cells.

    `a` is the reference (legacy pear1c, the full-language oracle), `b` the
    backend under test (pear2c, a documented subset).
    """
    if a["compile_rc"] == "front-error" or a["compile_rc"] == "front-noartifact":
        return a["compile_rc"]
    if a["artifact"] != "yes":
        if b["artifact"] != "yes":
            return "both-reject"
        return "pear1-reject"
    if b["artifact"] != "yes":
        # pear1c built and ran it; pear2c refused. Expected for an
        # out-of-subset fixture, a defect for a declared-supported one.
        return "expected-reject"
    if a["run_rc"] != b["run_rc"]:
        return "diverge-exit"
    if a["stdout_hash"] != b["stdout_hash"]:
        return "diverge-stdout"
    return "match"


def load_cells(cell_dir):
    """Return {fixture: {opt: {backend: record}}} built from the record files."""
    cells = {}
    if not os.path.isdir(cell_dir):
        return cells
    for name in sorted(os.listdir(cell_dir)):
        if not name.endswith(".rec"):
            continue
        rec = read_record(os.path.join(cell_dir, name))
        missing = [k for k in RECORD_KEYS if k not in rec]
        if missing:
            raise SystemExit("pie-diff-report: %s is missing %s" % (name, ",".join(missing)))
        cells.setdefault(rec["fixture"], {}).setdefault(rec["opt"], {})[rec["backend"]] = rec
    return cells


def fixture_sort_key(name):
    """Deterministic, human-sensible order: numeric part first, then the name.

    `p9` sorts before `p90`, and non-numeric fixtures sort after the numbered
    ones. Pure C-locale string sort would interleave them differently, which
    makes a ledger diff noisy for no reason.
    """
    digits = ""
    for ch in name:
        if ch.isdigit():
            digits += ch
        elif digits:
            break
    return (0 if digits else 1, int(digits) if digits else 0, name)


def build_rows(cells):
    """Ledger rows: one per fixture x opt x backend, plus the pairwise verdict."""
    rows = []
    for fixture in sorted(cells, key=fixture_sort_key):
        for opt in OPTS:
            by_backend = cells[fixture].get(opt)
            if not by_backend:
                continue
            if len(by_backend) != len(BACKENDS):
                raise SystemExit(
                    "pie-diff-report: %s @ %s has records for %s but not for all of %s"
                    % (fixture, opt, ",".join(sorted(by_backend)), ",".join(BACKENDS))
                )
            a, b = by_backend[BACKENDS[0]], by_backend[BACKENDS[1]]
            verdict = cell_verdict(a, b)
            for backend in BACKENDS:
                rec = by_backend[backend]
                rc = rec["run_rc"] if rec["artifact"] == "yes" else NO_ARTIFACT_RC
                rows.append({
                    "fixture": fixture,
                    "opt": opt,
                    "backend": backend,
                    "subset": rec["subset"],
                    "want_exit": rec["want_exit"],
                    "compile_rc": rec["compile_rc"],
                    "run_rc": rc,
                    "stdout_hash": rec["stdout_hash"],
                    "stdout_bytes": rec["stdout_bytes"],
                    "spec": spec_verdict(rec, rc),
                    "diag": rec["diag"],
                    "verdict": verdict,
                })
    return rows


def spec_verdict(rec, run_rc):
    """Did this backend's run satisfy the fixture's own `-- EXIT:` declaration?

    `na` when there was no run to judge. This is the column that catches the
    case a purely differential ledger is structurally blind to: both backends
    agreeing on a wrong answer is `verdict=match` and `spec=exit-mismatch`.
    """
    if rec["artifact"] != "yes" or run_rc == NO_ARTIFACT_RC:
        return "na"
    if run_rc == NONDET_RC:
        # A value that changes between runs cannot satisfy a declared one.
        return "nondeterministic"
    if rec["want_exit"] in ("none", ""):
        return "undeclared"
    return "exit-ok" if run_rc == rec["want_exit"] else "exit-mismatch"


def first_divergences(rows):
    """One row per fixture: the lowest opt level where the backends disagreed."""
    order = {opt: i for i, opt in enumerate(OPTS)}
    worst = {}
    for row in rows:
        if row["verdict"] == "match":
            continue
        key = row["fixture"]
        cur = worst.get(key)
        if cur is None or order[row["opt"]] < order[cur["opt"]]:
            worst[key] = row
    return [worst[k] for k in sorted(worst, key=fixture_sort_key)]


CSV_FIELDS = [
    "fixture", "opt", "backend", "subset", "want_exit",
    "compile_rc", "run_rc", "stdout_hash", "stdout_bytes", "spec", "verdict", "diag",
]


def render_csv(rows):
    buf = io.StringIO()
    buf.write(
        "# PEAR differential execution ledger — pear1c (reference) vs pear2c (backend under test).\n"
        "# Generated by scripts/pie-diff.sh; deterministic. Update with: scripts/pie-diff.sh --bless\n"
        "# verdict vocabulary: scripts/pie-diff-report.py module docstring\n"
    )
    writer = csv.DictWriter(buf, fieldnames=CSV_FIELDS, lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row[k] for k in CSV_FIELDS})
    return buf.getvalue()


def render_md(rows, meta):
    pair_rows = [r for r in rows if r["backend"] == BACKENDS[0]]
    counts = {}
    for row in pair_rows:
        counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1
    by_fixture = {}
    for row in pair_rows:
        by_fixture.setdefault(row["fixture"], []).append(row)

    out = io.StringIO()
    out.write("# PEAR differential execution ledger\n\n")
    out.write(
        "_Generated by `scripts/pie-diff.sh`. Every `tests/exec/pear/p*.pie` fixture "
        "through `legacy/pear1/pear1c` (reference) and `pear2/pear2c` (backend under "
        "test) at -O0..-O3, executed, compared on exit status and stdout. "
        "Deterministic: no timestamps, paths or timings._\n\n"
    )
    for key in ("fixtures", "cells", "opt_levels", "pear1c", "pear2c", "timeout", "subset_file"):
        if key in meta:
            out.write("* %s: `%s`\n" % (key.replace("_", " "), meta[key]))
    out.write("\n## Verdict totals (fixture x opt pairs)\n\n")
    out.write("| verdict | pairs |\n|---|---:|\n")
    for verdict in sorted(counts):
        out.write("| `%s` | %d |\n" % (verdict, counts[verdict]))
    out.write("\n## Per-fixture summary\n\n")
    out.write("| fixture | subset | -O0 | -O1 | -O2 | -O3 |\n|---|---|---|---|---|---|\n")
    for fixture in sorted(by_fixture, key=fixture_sort_key):
        per_opt = {r["opt"]: r["verdict"] for r in by_fixture[fixture]}
        subset = by_fixture[fixture][0]["subset"]
        out.write(
            "| `%s` | %s | %s |\n"
            % (
                fixture,
                subset,
                " | ".join("`%s`" % per_opt.get(o, "absent") for o in OPTS),
            )
        )
    out.write("\n## Spec conformance (each backend against the fixture's own `-- EXIT:`)\n\n")
    out.write("A differential ledger alone is blind to both backends miscompiling the same "
              "way: that reads as `match`. These counts compare each run against what the "
              "fixture declares, so an agreeing-but-wrong pair is visible.\n\n")
    out.write("| backend | exit-ok | exit-mismatch | nondet | na (no run) | undeclared |\n")
    out.write("|---|---:|---:|---:|---:|---:|\n")
    for backend in BACKENDS:
        sc = {}
        for row in rows:
            if row["backend"] != backend:
                continue
            key = row["spec"]
            sc[key] = sc.get(key, 0) + 1
        out.write("| `%s` | %d | %d | %d | %d | %d |\n"
                  % (backend, sc.get("exit-ok", 0), sc.get("exit-mismatch", 0),
                     sc.get("nondeterministic", 0), sc.get("na", 0), sc.get("undeclared", 0)))
    agreed_wrong = [r for r in rows
                    if r["backend"] == BACKENDS[0]
                    and r["verdict"] == "match" and r["spec"] == "exit-mismatch"]
    if agreed_wrong:
        out.write("\n**Both backends agree and both miss the declared exit code** "
                  "(a shared front-end defect, not a backend difference):\n\n")
        for row in agreed_wrong:
            out.write("* `%s` @ %s — want %s, both returned %s\n"
                      % (row["fixture"], row["opt"], row["want_exit"], row["run_rc"]))
    out.write("\n## First divergence per fixture\n\n")
    divs = first_divergences(rows)
    if not divs:
        out.write("_None: the two backends agree on every fixture at every tier._\n")
    else:
        out.write("| fixture | first tier | verdict | pear1c | pear2c | pear2c diagnostic |\n")
        out.write("|---|---|---|---|---|---|\n")
        for row in divs:
            cells = {r["backend"]: r for r in rows
                     if r["fixture"] == row["fixture"] and r["opt"] == row["opt"]}
            a, b = cells[BACKENDS[0]], cells[BACKENDS[1]]

            def brief(r):
                if r["compile_rc"] != "0":
                    return "compile rc=%s" % r["compile_rc"]
                if r["run_rc"] == NO_ARTIFACT_RC:
                    return "no artifact"
                return "rc=%s out=%s" % (r["run_rc"], r["stdout_hash"])

            out.write("| `%s` | %s | `%s` | %s | %s | `%s` |\n"
                      % (row["fixture"], row["opt"], row["verdict"],
                         brief(a), brief(b), b["diag"]))
    return out.getvalue()


def gate(current_text, baseline_path):
    """Compare ledger rows against the baseline. Return (ok, messages).

    Rows are keyed by (fixture, opt, backend) and compared field by field, so a
    changed verdict, a changed exit status, a changed stdout hash or a vanished
    row all surface. The comparison ignores the generated header comment lines
    only.
    """
    msgs = []
    if not os.path.isfile(baseline_path):
        return False, [
            "no baseline ledger at %s" % baseline_path,
            "record the current matrix as the baseline with: scripts/pie-diff.sh --bless",
        ]

    def rows_of(text, origin):
        lines = [l for l in text.splitlines() if l and not l.startswith("#")]
        reader = csv.DictReader(lines)
        if reader.fieldnames != CSV_FIELDS:
            raise SystemExit(
                "pie-diff-report: %s has header %s, expected %s (regenerate the baseline)"
                % (origin, reader.fieldnames, CSV_FIELDS)
            )
        keyed = {}
        for row in reader:
            keyed[(row["fixture"], row["opt"], row["backend"])] = row
        return keyed

    base = rows_of(open(baseline_path, encoding="utf-8").read(), baseline_path)
    cur = rows_of(current_text, "current ledger")

    for key in sorted(set(cur) - set(base)):
        row = cur[key]
        msgs.append("NEW      %s %s %-7s %s"
                    % (key[0], key[1], key[2], summarise(row)))
    for key in sorted(set(base) - set(cur)):
        row = base[key]
        msgs.append("MISSING  %s %s %-7s baseline said %s, row is gone"
                    % (key[0], key[1], key[2], summarise(row)))
    for key in sorted(set(base) & set(cur)):
        if base[key] != cur[key]:
            changed = [f for f in CSV_FIELDS if base[key][f] != cur[key][f]]
            msgs.append("CHANGED  %s %s %-7s %s"
                        % (key[0], key[1], key[2],
                           "; ".join("%s: %s -> %s" % (f, base[key][f], cur[key][f])
                                     for f in changed)))
    return (not msgs), msgs


def summarise(row):
    return "compile_rc=%s run_rc=%s stdout=%s verdict=%s%s" % (
        row["compile_rc"], row["run_rc"], row["stdout_hash"], row["verdict"],
        (" diag=%r" % row["diag"]) if row["diag"] else "",
    )


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--cells", required=True, help="directory of per-cell .rec records")
    ap.add_argument("--csv-out", help="write the CSV ledger here (omit to skip)")
    ap.add_argument("--md-out", help="write the Markdown report here (omit to skip)")
    ap.add_argument("--gate", action="store_true",
                    help="exit 1 if the ledger differs from --baseline")
    ap.add_argument("--baseline", default="tests/exec/DIFF_BASELINE.csv")
    ap.add_argument("--bless", action="store_true",
                    help="write the ledger to --baseline (deliberate baseline update)")
    ap.add_argument("--meta", action="append", default=[],
                    help="key=value lines recorded verbatim in the Markdown header")
    args = ap.parse_args(argv)

    cells = load_cells(args.cells)
    if not cells:
        raise SystemExit("pie-diff-report: no cell records under %s — the matrix did not run"
                         % args.cells)
    rows = build_rows(cells)
    csv_text = render_csv(rows)

    meta = {}
    for item in args.meta:
        key, _, value = item.partition("=")
        meta[key] = value
    meta.setdefault("fixtures", str(len(cells)))
    meta.setdefault("cells", str(len(rows)))

    if args.csv_out:
        with open(args.csv_out, "w", encoding="utf-8") as fh:
            fh.write(csv_text)
    if args.md_out:
        with open(args.md_out, "w", encoding="utf-8") as fh:
            fh.write(render_md(rows, meta))
    if args.bless:
        with open(args.baseline, "w", encoding="utf-8") as fh:
            fh.write(csv_text)
        print("pie-diff: baseline updated: %s (%d rows)" % (args.baseline, len(rows)))
    # Print the ledger only when the caller asked for no artifact at all; a gate
    # run that also dumped the whole CSV would bury its own verdict.
    if not (args.csv_out or args.md_out or args.bless or args.gate):
        sys.stdout.write(csv_text)

    if args.gate:
        ok, msgs = gate(csv_text, args.baseline)
        pair_rows = [r for r in rows if r["backend"] == BACKENDS[0]]
        counts = {}
        for row in pair_rows:
            counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1
        print("pie-diff: %d fixture x opt pairs, %d ledger rows" % (len(pair_rows), len(rows)))
        for verdict in sorted(counts):
            print("  %-18s %d" % (verdict, counts[verdict]))
        if ok:
            print("pie-diff GATE: PASS — ledger matches %s" % args.baseline)
            return 0
        print("pie-diff GATE: FAIL — %d ledger row(s) differ from %s"
              % (len(msgs), args.baseline))
        for msg in msgs[:200]:
            print("  " + msg)
        if len(msgs) > 200:
            print("  ... %d more" % (len(msgs) - 200))
        print("  A NEW/CHANGED row is either a regression or a fix; triage it, then")
        print("  update the baseline deliberately: scripts/pie-diff.sh --bless")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
