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

## 2026-09-30 (later) — PR #11 updated to theory/nbe-real @ e262441 — four more passes real
- **CPS** `theory_cps.c3` (~1900): continuation IR, tail verdicts (`NF_TAIL`), η/β contraction, contification, `--emit-cps`. W4200/N4201/N4203. test 90.
- **Match compiler** `theory_matching.c3` (~1300): Maranget decision DAGs, verified against first-match semantics, `NF_DENSE_SWITCH`, `--emit-dtree`. N4210. test 91.
- **Qualifiers** `theory_quals.c3` (~940): whole-program purity fixpoint + per-parameter write/escape. W4220 discarded pure call, W4221, N4222/N4223. test 92.
- **Commutativity** `theory_crdt.c3` (~1070): statement dependence DAGs, loop reductions, CRDT accumulator classes. N4230/N4231. test 93.

### For PEAR-bro (backend contract — new flags, all visible in `--emit-ast`)
| flag | on | meaning |
|---|---|---|
| `NF_PURE_FN` (`pure`) | `N_DECL_FN` | no writes outside its frame, no effects, no unknown calls → LLVM `readnone`/`readonly` (it may still allocate: check the report class) |
| `NF_READONLY_PARAM` (`readonly`) | param binder (every clause) | never written through nor retained → `noalias readonly` |
| `NF_REDUCTION` (`reduction`) | `while`/`for`/`loop` | every written local is a commutative accumulator (+/−, *, \|, &, ^, max/min) in ONE monoid, induction vars step by a constant, no heap/world write → iterations commute: split / vectorise freely |
| `NF_INDEPENDENT` (`indep`) | block statement | no RAW/WAR/WAW conflict with the previous statement → may be swapped/hoisted |
| `NF_DENSE_SWITCH` (`dense-switch`) | fn / match | decision tree is one switch over a dense key set → jump table |
| `NF_TAIL` (`tail`) | call | call in tail position (CPS-verified) |

- `theory_check.c3`: pass states were malloc'd with hard-coded byte counts (QualAnalysis got 256 bytes for a much bigger struct) — now `Type::size`. If you add a pass, don't add a `const usz X_SZ`.
- Stdlib touch: `stdlib/effect_async/uring_handler.pie:87` — `native_uring_submit(&h.uring)` was a pure stub whose result was thrown away (W4220 found it); bound to `let _submitted`.

### Next on my list
theory_stratified (249, types/), theory_ssa (347), theory_dataflow (438), theory_records (443), theory_verify (461). Shout in todo.md if you want one of these first, or if a flag above needs different semantics.
