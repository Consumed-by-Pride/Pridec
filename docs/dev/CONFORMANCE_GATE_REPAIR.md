# Conformance gate repair — agent-n3, 2026-09-30

## Why the previous 218/44 result was not evidence

`conformance/run.sh` invoked `../pride`, a legacy binary that is neither
tracked nor built by `make test`. In a fresh `dev` checkout that executable
is absent. The shell harness ignored exit 127 and tested the resulting shell
error against obsolete `[resolve L:C]` / `[type-warn L:C]` patterns. An
`EXPECT-CLEAN` or zero-count contract could therefore pass without compiling
anything. Cases with no EXPECT contract passed unconditionally as well.

Reproduced on `dev` source **5e20e0a**: the absent binary still produced
`conformance pass=218 fail=44`. That number is withdrawn as a current-pfront
measurement, not explained away as 44 known compiler defects.

## Measured replacement baseline (not a compiler improvement)

Using the compiler built from **unchanged dev source 5e20e0a**, C3 0.8.4 and
LLVM 23, the repaired runner checks all 262 fixtures with `pfrontc --plain`:

- **149 pass / 113 fail**.
- Every failed fixture and its unmet contract is recorded in
  `conformance/KNOWN_FAILURES.tsv`; failures remain printed on every run.
- Compiler executable SHA-256 used for the measurement:
  `c199000cb1652155d1f6daa3bdaf39e47578e69ccf8a600aedf05966267edda5`.
- No pfront/compiler source changed before this measurement. The baseline
  was recalibrated to replace an invalid instrument, **not lowered to hide a
  merge regression**. Subsequent integration candidates must preserve this
  measured floor and cannot introduce a new failing fixture, even if another
  fixture improves enough to keep aggregate counts unchanged.
- The existing pfront runner independently measured **163/5**, with stdlib
  **260/260**, before any source edits. Its old 158/5 floor was stale and is
  tightened to the already-observed 163/5 result. This is not an n3 compiler
  improvement either.

The 113 unmet historical contracts include parser/resolver gaps, missing or
changed advisories, and actual diagnostics in fixtures expecting clean output.
Some expectations reflect a historical typed-language policy rather than the
current untyped/advisory policy; retiring or changing those contracts requires
an explicit language-policy decision. This repair does not rewrite their
message text or locations to manufacture passes, and does not claim they all
represent new regressions.

## What is now checked

- Executable/version/loader preflight; missing compiler is FATAL before counts.
- Per-case timeout, crash/abnormal-status detection, and diagnostics/summary
  consistency (including warnings). Infrastructure failures cannot be XFAILed
  or hidden in a numeric baseline.
- Literal expected source locations and message substrings. Historical phase
  tags use pfront's code families (documented in `conformance/run.py`), because
  its current phase enum is only lex/parse/resolve/module.
- EXPECT-CLEAN rejects all emitted errors/warnings (notes remain advisory).
- Cases without EXPECT still have to compile without errors. Zero-count
  assertions cannot conceal errors from another phase. Additional unasserted
  errors fail, including errors from imported modules.
- Case-level known-failure membership, in addition to `tests/baselines.tsv`.
- 13 harness regression tests, including the absent-binary false-positive,
  unknown output formats, crashes, wrong locations/text, and extra errors.

## Reproduce

```sh
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
bash scripts/agent3-build.sh
bash conformance/run.sh
python3 -m unittest discover -s tests/harness -v
PFRONT_BIN=/nonexistent/compiler bash conformance/run.sh  # FATAL, exit 2
```

`--report PATH` writes per-case JSON evidence; running the suite never mutates
its baselines. `make test` is a **no-regression gate**, not a claim that every
language conformance contract is satisfied. Agent-4 independent review is
requested before this baseline correction is accepted on dev.
