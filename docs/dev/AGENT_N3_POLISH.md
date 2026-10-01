# Agent-n3 polish dispositions — 2026-10-01

These changes are on `n3/*` review candidates, not yet accepted on dev.
Compiler defect fixes are **not** inferred from a passing no-regression gate.

| Handoff item | Disposition |
|---|---|
| stale p92 XFAIL | Deleted; case now contributes a real PASS instead of XPASS. |
| broken HOSE checker | Uses `pfront/pear_ir/pear.c3` + `pear_link.c3`, real compiled C exports (`nm`) and stdlib extern bindings. Checks libc malloc/free/write; reports missing sources as failures rather than crashing. |
| experiments absent from make test | Integrated by the regression-gate merge; all 14 expected-diagnostic contracts pass. |
| capability checklist archaeology | Historical banner + references to current numeric and case-level baselines. |
| help / module roots / -o | Filename-based resolution documented and tested. Unknown flags (including unsupported -o) now fail immediately with their name. Missing -I/--context arguments and invalid context integers fail clearly. |
| --dead-code appears inert | Rechecked: it already emits W4020 for an unreachable function when main is present. Added the function name as the stable diagnostic hint, documented library/root semantics, and tested opt-in, public roots and library suppression. |
| script modes | Suite/experiment and bench run entry points consistently executable; all touched shell files pass bash -n. |
| 3 legacy hangs + mutable-global crash | Reproduced each fixture independently at O0/O1/O2/O3, added specific XFAIL reasons ahead of the broad legacy glob. Added a small runtime regression for the compound-assignment hang. No claim that the remaining crashes/hangs are fixed. |

## Two context corrections that must not become false documentation

1. Positional directories are **not** scanned as module roots by the current
   loader. They were opened like input files and could silently look empty.
   This is now a clear error: supply a source file and `-I dir`. Adding a new
   recursive directory compilation feature is outside the integration mandate.
2. The old conformance result was not measuring pfront at all. The honest
   replacement baseline (149/113 on unmodified dev) and individual unmet
   contracts are in `CONFORMANCE_GATE_REPAIR.md` / `conformance/KNOWN_FAILURES.tsv`.

## Additional gate/reporting repairs

- Default native canary matrix covers all four supported optimization tiers;
  exec summaries now count canaries as well as file cases and driver checks.
  The new O3 canary contributes one real check, not a synthetic counter.
- PEAR runner accepts PEAR_OPT, time-bounds binaries and rejects unexpected
  XFAIL passes. Its temporary logs are process-specific for parallel isolated
  tier runs.
- Literal backticks in two double-quoted pfront harness labels executed a
  nonexistent `n` command. Labels are now single-quoted; no compiler capability
  is claimed for that cleanup.
- The 47-case semantic subtype specification is part of default `make test`.
- README now describes the shipped LLVM-23 native path, not an AIR-only future
  backend. The C-runtime README labels its obsolete LLVM-22 build commands and
  makes clear that current PEAR does not automatically link compiler_rt/HOSE.

## Legacy investigation limits

Full fixtures `04_dynamic_alloc`, `11_step_ranges`, `23_array_rebind_loop`
compile but run longer than 2 s at every tier; `39_mutable_globals` fails
compilation with rc 139 and no binary at every tier. They were copied into an
isolated directory so artifacts could not affect the measurement.

Removing printing/I/O from the allocation-index loop returns **42**; the
scalar step-loop kernel returns **2450 mod 256 = 146**. Those kernels work,
so it would be dishonest to attribute the first two full-fixture hangs to
simple loop-counter rebinding. Their full root causes remain open.

The array-rebind fixture uses `i += 1`, which is independently reduced to
`tests/exec/n3_compound_loop.pie`: ordinary `i = i + 1` terminates, but `+=`
keeps the value at 1 and hangs at all tiers (the known Agent-4 §49 defect).
Fixing that later may still leave its array/I/O defects. The full mutable-
globals compiler crash is explicitly recorded but has not been minimized.

## Measured polish gate

Build + full make test exit 0: pfront 163/5, stdlib 260/260, current conformance
149/113 (no new failing fixture), PEAR 29/0, exec 37/0 with 48 XFAIL and zero
XPASS, harness tests 26/26, experiments 14/14, subtype spec 47/47.

The HOSE checker compiles the real C runtime with cc / -std=gnu18 here, checks
its exported symbols, and exits 0; it explicitly says this is inventory, **not
native HOSE runtime coverage**. Agent-4 review is requested for these changes,
particularly the conformance instrumentation and baseline correction.


## Expanded PEAR review checkpoint (2026-10-01)

At the owner's request, merged pinned PEAR dd6dcc3 (including unit-thunk fix,
excluding reverted nullary auto-call). Three native contract fixtures pass;
block-bodied tuple clauses remain explicit XFAIL. A further integration gap
was repaired: memory/captures helpers used ignored custom strings instead of
semantic LLVM attrs. Direct LLVM-API tests fail 0/2 before and pass 2/2 after
the named enum/integer-attribute correction. Full gate and all four requested
driver-flag matrices pass with PEAR 34/0 (+1 XFAIL), exec 42/0 (+49 XFAIL).
The preexisting O0 backend route uses LLVM O1; we do not claim four distinct
LLVM optimization pipelines. Independent Agent-4 verification remains required.
