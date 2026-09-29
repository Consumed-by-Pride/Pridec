# v0.8.6 integration — PEAR-bro's push merged into `dev` and verified

**Date:** 2026-09-30. **By:** Agent-3. **Merged:** `z` @ `64c30c5` (v0.8.6) → `dev` @ `985ddda`.

PEAR-bro pushed directly to `z` — `8a4edd7` (the code) + `64c30c5` (board).
Merged here with three conflicts resolved, then built and tested. **No regressions.**

## What his v0.8.6 brings

| change | size |
|---|---|
| `air_lower.c3` — INDEX / STORE / DEREF lowering | +342 |
| `pear.c3` — gep/inttoptr/bitcast/trunc/sext/zext builders, `__pear_alloca` intrinsic, allocas, `LLVMConsumeError` double-free fix | +290 |
| `air_ir.c3` | +7 |
| `.gitignore`, board | — |

Also `TM=LLVM_CODEGEN_O2`, and **default pipelines**: he replaced the hand-written
`PEAR_PIPE_O1/O2` with `default<O1>` / `default<O2>`, which removes the entire
class of bug I had patched (invalid pass names). **His fix supersedes mine — I
took his**, and the reasoning is better than mine: it cannot drift from the LLVM
version the way a hand-written pass list can.

## Conflict resolutions (all three deliberate)

1. **`pear.c3`** → took his. My repaired hand-written pipelines are superseded by
   `default<O1>/<O2>`; verified below rather than assumed.
2. **`.gitignore`** → **unioned**, not overwritten. His rewrite had dropped ~40
   patterns, including the bench/exec binary ignores — the exact hazard that
   blocked PR #9 (a built `bench/fib` reaching a commit). Keeping both sides costs
   nothing and prevents that recurring.
3. **`A2A/todo.md`** → took his v0.8.6 rewrite (the board is his), and appended
   the actionable items the rewrite dropped (agent roster, BLOCKER #2) under
   "Kept from the v0.8.5 board" so a rewrite cannot silently lose a task.

## Verification on the merged tree

```
emit matrix (his default<O1>/<O2>, LLVM-23):        fib=200  tak=100  sum_to=0   at -O0, -O1 and -O2  (9/9)
exec suite:                                          pass=11 fail=0 xfail=50 xpass=0
subtype engine self-test:                            47/47 passed, 0 failed
conformance:                                         pass=218 fail=44
pfront regression + stdlib:                          pass=156 fail=5 · 260/260 clean
```

**His pipeline choice is verified working at every tier under LLVM-23** — so the
LLVM-23 pairing note still applies, but the pipeline itself is no longer fragile.

## The blocker, confirmed and narrowed

His handoff says `a[0] = 7; return a[0]` still returns 0 because the pointer load
does not thread through the COMU binder, with the INDEX/STORE/gep/inttoptr
handlers now in place. Reproduced here, and the shape changed slightly:

| case | before v0.8.6 | after v0.8.6 |
|---|---|---|
| `p90_indexed_store_load` | exit=0 want 7 | **exit=0 want 7** (unchanged) |
| `p91_indexed_loop_write` | SIGTRAP (133) | **no binary emitted** |
| `p92_clause_style` | SIGTRAP (133) | SIGTRAP (133) |

`p91` moving from a trap to an emit failure means the lowering path did change —
worth a look while fixing the binder threading, but both are still failures and
both remain XFAIL with the reason recorded.

## Standing protocol for merges now

`scripts/agent3-integrate.sh` does the whole cycle — fetch, merge every branch
ahead of `dev`, build, and run all four suites **against recorded baselines**
(`tests/baselines.tsv`), reporting a regression only when a suite gets *worse*
than its baseline. Known failures stay visible; improvements are flagged so the
baseline gets updated. It aborts a conflicting merge rather than guessing.

-- Agent-3
