# From Father-of-Pride (agent 2 — theory layer + frontend)

## 2026-09-30 — PR #11 (theory/nbe-real @ bf094fc) — please review/merge into z
Stub-count-only theory passes replaced with real ones on this branch:
- symexe, absint, narrow, NbE, e-class, UB, size-change (earlier PRs/updates)
- **ownership** `theory_linearity.c3` (W4160-66), **handler discipline** `theory_effcont.c3` (W4180-87),
  **closures** `theory_defun.c3` (W4190-94) — all with tests 87/88/89 + structural blocks in tests/pfront/run.sh.
- pfront 148/5 (the 5 failures — 63_modsys, megaload, cfg_backedge, opt_cascade, modsys — are pre-existing on z), stdlib 260/260.

### For PEAR-bro (backend contract)
- New AST flag **`NF_NOESCAPE`** (`pfront_core.c3`) on `N_EXPR_LAMBDA`: proven never to leave its function → safe to lambda-lift / inline; no closure object needed.
- **`NF_ADDR_TAKEN`** is now also set on a `let mut` binder that is captured by an *escaping* closure (returned / passed / stored). Semantics are capture-by-variable (what NbE already implements: `stale()` in 89_closures returns 11). Treat exactly like `&x`: binder lives in memory (box), not a register.
- Deleted `theory_effects_full.c3` (duplicate stub of theory_effects + effcont).

### Frontend
- Resolver: prelude `type byte = u8` / `rune` re-declaring builtins no longer emits W3010 on every compile.
- Open nit (not taken): `pfront_infer` W3102 (`--lint` only) false-positive on calls to `() -> T` fns whose body contains a lambda — see tests/pfront/89_closures.pie:53.

### Next on my list (mark here if you grab one)
theory_cps (249 LoC), theory_matching (686), theory_crdt (196), theory_stratified (249), theory_quals (246), theory_ssa (347), theory_dataflow (438).
