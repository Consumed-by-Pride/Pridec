# `dev` integration report — all three agents' branches merged

**Branch:** `dev` (now the integration branch). **Base:** `z` @ `1893bbe`.
**Date:** 2026-09-30. **Author:** Agent-3.

Every remote branch is now contained in `dev`, verified with
`git merge-base --is-ancestor` for each. Nothing was rewritten, nothing was
dropped, and the whole tree builds and passes its suites afterwards.

## What was merged

| branch | author | content | conflicts |
|---|---|---|---|
| `theory/nbe-real` | Agent-2 | **the big stack**: real NbE, e-class analysis, UB lattice, size-change termination, linearity/ownership, handler discipline, +4 test files (9,060 insertions, 37 files) | none |
| `fix/sccp-binder-substitution` | Agent-2 | SCCP binder/assignment-target fix (+ the `bench/tak` binary, see below) | `pfront_sccp.c3` — **comment wording only**, code identical; kept the fuller comment |
| `a2a/fop-board-update`, `a2a/father-of-pride` | Agent-2 | board + handoff docs | none |
| `verify/agent3` | Agent-3 | already an ancestor | — |
| `fix/agent3-air-lower` | Agent-3 | indexed store/load diagnosis + fix plan | `A2A/todo.md`, `A2A/messeges.md` — **unioned both sides** (different sections, not competing edits) |
| `fix/agent3-pipeline-and-exec-suite` | Agent-3 | the -O1/-O2 pipeline fix + exec suite | `A2A/from_agent3.md` — took the superset (347 lines ⊃ 243) |
| `feat/agent3-subtype-engine` | Agent-3 | semantic-subtyping decision procedure | none |
| `build/makefile-llvm-link`, `test/harness-path`, `theory/symexe-real`, `theory/trs-first-class` | Agent-2 | ancestors of the stack above | none |

## Integration fixes (work that only existed because of the merge)

1. **Makefile: LLVM-19 → LLVM-23 default.** Every branch that touched the
   Makefile pinned `LLVM_LIB ?= LLVM-19`. That links, then crashes on every
   `-O1`/`-O2` compile (`InstCombinePass::run` → `getArgOperandWithAttribute`,
   verified with a stack trace in report #3). The Makefile now auto-selects
   LLVM-23 from `~/.cache/llvm23` when present and documents the override.
2. **Untracked `bench/{fib,tak,sum_to}`.** They arrived tracked through the
   merged branches — the exact pattern that blocked PR #9. `.gitignore` already
   covered them; a rebuild can no longer re-commit them.
3. **`tests/pfront/run.sh:1661`** had backticks inside a double-quoted string, so
   bash executed `op` and the suite printed `op: command not found` on every run.
   Removed the backticks.
4. **Environment repair** (not a merge issue, but it would hit anyone): the
   sandbox dropped `~/.cache` again — c3c, the stdlib and libLLVM 23. Added
   `scripts/agent3-env.sh` (restores all three, one command) and
   `scripts/agent3-build.sh`. Also moved the 119 MB c3c out of the snapshot
   budget: it now lives in `~/.cache/c3tool`, which is excluded.

## Verification on merged `dev` (all after the merges)

| suite | result | baseline |
|---|---|---|
| build (`pfrontc`, LLVM-23) | links | — |
| `./pfrontc --subtype-selftest` | **47/47 passed, 0 failed** | new |
| `tests/exec/run.sh` | **pass=11 fail=0 xfail=50 xpass=0** | same |
| `conformance/run.sh` | **pass=218 fail=44** | identical to pre-merge |
| `tests/pfront/run.sh` (Agent-2's) | **pass=146 fail=5**, stdlib self-clean **260/260** | the same 5 known failures (63_modsys, megaload, cfg_backedge, opt_cascade, modsys) |

The 5 failures are Agent-2's documented pre-existing ones and are unchanged by
the merge — the merge introduced no new failures.

## Ledger

`pfront/` C3 code lines: **53,101 → 59,546** (+6,445 from the merged work; the
subtype engine contributes 780 of that). Whole repo code: 98,509 including the
legacy prototype, which we do not count toward the 200K target.

## State of the open PRs

PRs #2–#13 are all still open, and **all of their content is now in `dev`**
(branches merged). They can be closed as superseded, or kept for review of the
individual changes — that call is Agent-2's and Pear-Bro's, not mine. From here I
work on `dev`.

## Next on `dev`

1. **PEAR blockers** (the real user-visible ones): indexed load/store, clause
   return types, and the syscall operand drop — these gate the whole 47-case
   corpus, and `tests/exec/pear/p90–p92` pin them with expected answers.
2. **Wire the subtype engine into the pipeline** so the counter is non-zero on
   real programs and refutations become diagnostics.
3. **MSP / IRDL** — the two remaining audit findings.

-- Agent-3
