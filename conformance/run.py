#!/usr/bin/env python3
"""Check the historical EXPECT contracts against the CURRENT pfront compiler.

Unlike the old shell harness, a missing/crashing compiler, unexpected compile
error, or changed diagnostic format cannot count as EXPECT-CLEAN. Historical
phase tags are mapped from pfront's diagnostic codes; message text and source
locations are still checked literally (no rewriting to make old tests pass).
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DIAG = re.compile(r"^\s*(.+):(\d+):(\d+): (error|warning|note) \[([EWN])(\d+)/([a-z]+)\] (.*)$")
SUMMARY = re.compile(r"^\s*(errors|warnings)\s*:\s*(\d+)\s*$", re.M)


def category(severity, code, phase):
    # pfront has only lex/parse/resolve/module phases; retain the old source
    # fixture vocabulary using the current code families, not legacy output.
    if phase in ("lex", "parse"):
        return "parse"
    suffix = "err" if severity == "error" else "warn"
    if 3100 <= code < 3200 or 3300 <= code < 3400 or code in (3291, 3292):
        return f"type-{suffix}"
    if 3200 <= code < 3291 or 4070 <= code <= 4072 or 4180 <= code <= 4186:
        return f"effect-{suffix}"
    if 3400 <= code < 3500:
        return f"irdl-{suffix}"
    if 4000 <= code < 4100:
        return f"lint-{suffix}"
    return "resolve"


def evaluate(source, output, rc):
    """Return unmet contracts; infrastructure failures are never conformance."""
    if rc not in (0, 1, 2):
        return [f"compiler failed (rc={rc})"]
    diagnostics = []
    for line in output.splitlines():
        match = DIAG.match(line)
        if match:
            path, row, col, severity, prefix, code, phase, text = match.groups()
            if severity != "note":
                diagnostics.append((category(severity, int(code), phase),
                                    f"{row}:{col}", text, severity, Path(path).name))
    summary = {name: int(count) for name, count in SUMMARY.findall(output)}
    error_count = sum(d[3] == "error" for d in diagnostics)
    warning_count = sum(d[3] == "warning" for d in diagnostics)
    if summary != {"errors": error_count, "warnings": warning_count}:
        return ["missing/inconsistent diagnostic summary (compiler/format failure)"]
    expected_rc = 2 if error_count else (1 if warning_count else 0)
    if rc != expected_rc:
        return [f"inconsistent compiler status rc={rc}, errors={error_count}, warnings={warning_count}"]

    reasons = []
    expected_errors = set()
    for line in source.read_text().splitlines():
        if line.startswith("-- EXPECT-CLEAN"):
            if diagnostics:
                reasons.append(f"expected CLEAN, got {len(diagnostics)} errors/warnings")
        elif line.startswith("-- EXPECT-COUNT:"):
            spec = line.split(":", 1)[1].strip()
            tag, want = spec.split("=", 1)
            want = int(want)
            got = sum(d[0] == tag for d in diagnostics)
            if got != want:
                reasons.append(f"count {tag} want={want} got={got}")
            if want > 0 and got == want:
                expected_errors.update(i for i, d in enumerate(diagnostics)
                                       if d[0] == tag and d[3] == "error")
        elif line.startswith("-- EXPECT:"):
            parts = line.split(":", 1)[1].strip().split(maxsplit=2)
            tag, loc = parts[:2]
            text = parts[2] if len(parts) > 2 else ""
            found = [d for d in diagnostics if d[0] == tag and d[1] == loc
                     and d[4] == source.name]
            if not found:
                reasons.append(f"missing {tag} at {loc}")
            elif not any(text in d[2] for d in found):
                reasons.append(f"{tag}@{loc} text!~{text!r}")
            expected_errors.update(i for i, d in enumerate(diagnostics)
                                   if d in found and d[3] == "error")
    # In particular, fixtures without EXPECT comments still have to compile;
    # zero-count assertions cannot conceal unrelated parse/resolve errors.
    unexpected = [d for i, d in enumerate(diagnostics)
                  if d[3] == "error" and i not in expected_errors]
    if unexpected:
        reasons.append(f"{len(unexpected)} unexpected compile errors")
    return reasons


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", default=os.environ.get("PFRONT_BIN", str(ROOT / "pfrontc")))
    parser.add_argument("--report", type=Path, help="write measured per-case JSON (never changes baselines)")
    args = parser.parse_args()
    binary = str(Path(args.bin).resolve())
    try:
        check = subprocess.run([binary, "--version"], cwd=ROOT, capture_output=True,
                               text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"FATAL: cannot run current compiler {binary}: {exc}", file=sys.stderr)
        return 2
    if check.returncode != 0 or "pfront" not in check.stdout:
        print(f"FATAL: current compiler preflight failed: {check.stdout}{check.stderr}", file=sys.stderr)
        return 2

    results = {}
    infrastructure_failure = False
    for source in sorted((ROOT / "conformance/cases").glob("*.pie")):
        try:
            run = subprocess.run([binary, str(source.relative_to(ROOT)), "--plain"],
                                 cwd=ROOT, capture_output=True, text=True, timeout=30)
            reasons = evaluate(source, run.stdout + run.stderr, run.returncode)
            if run.returncode not in (0, 1, 2) or any("compiler/format" in r for r in reasons):
                infrastructure_failure = True
        except (OSError, subprocess.TimeoutExpired) as exc:
            reasons = [f"compiler could not complete: {exc}"]
            infrastructure_failure = True
        results[source.name] = reasons
        if reasons:
            print(f"FAIL cases/{source.name}: {'; '.join(reasons)}")
    if not results:
        print("FATAL: no conformance cases discovered", file=sys.stderr)
        return 2
    failed = {name for name, reasons in results.items() if reasons}
    passed = len(results) - len(failed)
    print(f"----\nconformance pass={passed} fail={len(failed)} (current pfront, {len(results)} cases)")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(results, indent=2) + "\n")

    known_path = ROOT / "conformance/KNOWN_FAILURES.tsv"
    known = set()
    if known_path.exists():
        known = {line.split("\t", 1)[0] for line in known_path.read_text().splitlines()
                 if line and not line.startswith("#")}
        extra = failed - known
        if extra:
            print("REGRESSION: unexpected failures: " + ", ".join(sorted(extra)))
            return 1
        if known - failed:
            print("IMPROVED: update KNOWN_FAILURES.tsv: " + ", ".join(sorted(known - failed)))
    for line in (ROOT / "tests/baselines.tsv").read_text().splitlines():
        if line.startswith("conformance\t"):
            _, ep, ef, *_ = line.split("\t")
            if passed < int(ep) or len(failed) > int(ef):
                print(f"REGRESSION: measured {passed}/{len(failed)} vs recorded {ep}/{ef}")
                return 1
            if passed > int(ep) or len(failed) < int(ef):
                print("IMPROVED: update tests/baselines.tsv (conformance)")
            print(f"conformance: at or above baseline (pass>={ep}, fail<={ef}) — OK")
            return 2 if infrastructure_failure else 0
    print("FATAL: no conformance baseline", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
