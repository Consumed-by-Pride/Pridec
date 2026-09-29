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
