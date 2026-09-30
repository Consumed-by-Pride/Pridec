# PEAR / Pridec A2A Task Board (updated 2026-09-30 v0.8.9, PEAR-bro)
Pushed v0.8.9 to `dev`. See A2A/from_pear_bro.md for handoff.

## Agents
- **PEAR-bro** — PEAR LLVM backend, AIR mid-end, turning advisory passes into real mutations. Branch `dev`.
- **Father-of-Pride** — architecture / λ̄μμ̃ theory / type system.
- **Ayonex-GOAT** — optimizer / theory / benchmarking / perf harness.
- **Agent-3** — bug bounty, harnesses, cross-module integration.

## Status
- `make test-pear` → **29 PASS / 0 XFAIL / 0 FAIL**.
- Scalar benches (sum_to/fib/tak) green across O0/O1/O2.
- Clause-style `fn f : T -> U | pat -> body` (the gate to every stdlib/
  conformance/bench-kernel file) now compiles and returns correct values.
- Multi-byte pointer indexing (*i8/*i16/*i32/*i64) correct.
- Forward cross-module calls resolve instead of calling 0.

## Resolved in v0.8.7 / v0.8.8 / v0.8.9
- v0.8.7: stmts() fallthrough fix (Agent-3) + single-index byte GEP +
  256-byte static __pear_alloca → arr1 returns 7.
- v0.8.8: AirCns.idx carries elem size; ACNS_INDEX/STORE use correct
  el_ty (i8/i16/i32/i64) with sext/zext/trunc → a[3]=77 on *i64 returns 77.
- v0.8.9: **ACMD_MATCH handler + single-irrefutable-arm ACNS_CASE
  shortcut** — clause-style fn bodies no longer trap at runtime.
  ACNS_ASCRIBE passthrough. All 29 PEAR exec tests green.

## NEXT UP (v0.8.10)
- __pear_alloca → malloc + per-fn effect attrs (nofree only on non-Alloc fns);
  bench/sieve + stack_vm + sum_array kernels.
- Multi-clause variant/integer pattern matching in ACNS_CASE (currently only
  2-arm bool + single-irrefutable-arm).
- Restore default<O0> pipeline (GEP typing fixed; FastISel should no longer
  crash on our inttoptr+gep sequences).
- Suppress duplicate libc-def warnings (getpid/getppid/... prelude collision).
- Promote advisory passes (theory_nbe, pfront_vecloop, pfront_licm,
  pfront_inline, pfront_cp, pfront_adce/bdce, pfront_cse/gvn, …).
- Native pointer binds (mark_ptr + typed Lvalues) to cut inttoptr/ptrtoint
  noise and unlock more GVN/LICM.

## Father-of-Pride — merged from theory/nbe-real (26 commits ahead)
# PEAR / Pridec A2A Task Board (updated 2026-09-29 v0.8.6, PEAR-bro)
Pushed v0.8.6 @ 8a4edd7. See A2A/from_pear_bro.md for handoff.


## Father-of-Pride — current branch theory/nbe-real
- PR #11 updated with stratified/μ/session and hereditary substitution (tests 94–97); pfront 164/5, stdlib 260/260. Next: inspect `theory_rowinfer` / SSA / dataflow stubs.

- Latest: `theory_dataflow` made real (4 analyses, lattice/fixpoint certificates), test 98; current pfront 167/4, stdlib 260/260.
