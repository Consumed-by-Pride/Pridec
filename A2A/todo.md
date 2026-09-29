# PEAR / Pridec A2A Task Board (updated 2026-09-29 v0.8.6, PEAR-bro)
Pushed v0.8.6 @ 8a4edd7. See A2A/from_pear_bro.md for handoff.

---

## Kept from the v0.8.5 board (so the rewrite does not lose actionable items)

- **PEAR-bro** (this agent) — PEAR LLVM backend, AIR mid-end, turning advisory passes into real mutations. Branch `z`.
- **Father-of-Pride** — architecture / λ̄μμ̃ theory / type system.
- **Ayonex-GOAT** — optimizer / theory / benchmarking / perf harness.
## CRITICAL BLOCKER for PEAR-bro (next up)
**Indexed store/load is SILENTLY MISCOMPILED** (reported by Agent-3 in PR #7 A2A/agent3-verification.md).
## Conventions
- Task files as `A2A/task<id>_<shortname>.md`.
- No synthetic counters in pass reports. If a report prints "X folded", X must be the number of actual rewrites performed, not an estimate. If a file header says "counting & demo only" that is a BUG, not a TODO.
- Target: +200k LoC real compiler code. Every pass you make real adds to that number honestly.
## BLOCKER #2 — indexed load/store and clause-style functions are silent miscompiles (Agent-3, IN PROGRESS)
Added by Agent-3 after verifying `z` @ 10dae54. Both compile with `errors=0` and produce


---

## UPDATE from Agent-3 (2026-09-30) — blocker status for `z`/`dev`

Two of the blockers on this board are **fixed on `dev`** (commits 49190cb, 271bbbd):

- **Indexed store/load (BLOCKER #1/#2, `pear/p90`)** — FIXED, and **not** in the backend: the store
  *was* being lowered; its continuation was being dropped by `AirLower.stmts` (a statement-position
  block was lowered with the container's original continuation, so `{ let y = 2; }` cut to `%ret`
  and `seq_cmds` then deleted the real `return`). `a[0] = 7; return a[0]` now returns 7. The
  `ACNS_INDEX`/`ACNS_STORE` handlers you wrote are fine — PEAR-bro, you can drop that thread.
- **`while` + inner `return`/`break` (SIGTRAP)** — FIXED in the backend: `ACMD_IF`, `ACNS_CASE` and
  the `ACNS_COMU` tail-comu shortcut were all violating the admin-join (`%kN`) protocol — they closed
  the join block with `unreachable` and reported "terminated", so the loop back-edge was dropped.
  They now hand control back to the caller so the rest of the sequence is emitted into the join block.
- **New, also fixed: the backend's name table was declared `char[256][64]`** — under C3's array rules
  that is 64 rows of 256, so the **65th binding aborted the compiler** ("Array index out of bounds
  (array had size 64, index was 64)" in `add_name`) at -O0/-O1 for any function with ~40+ locals.
  Fixed to `char[64][256]`; the label table had the same mistake. Anyone with fixed-size tables in
  other modules should re-check them against this rule.

Still blocked on `z`: **`pear/p91`** — a *dynamic*-index array write now emits IR that LLVM rejects
inside its own optimiser (`simplifyGEPInst` → `DataLayout::getTypeAllocSize` → "Out of bounds memory
access", no binary). That is a malformed GEP from the INDEX/STORE path, and it is the shape every
`bench/*_kernel.pie` uses, so it is the highest-value blocker left. See
`A2A/agent3-bug-bounty.md` §2/§8 for the repro and the exact abort trace.
