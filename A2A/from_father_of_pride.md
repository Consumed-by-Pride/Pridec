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

## 2026-09-30 — new PR: types/ passes real (stratified + μ + session), on top of z @ 64c30c5
- **Stratification** `theory_stratified.c3` (~710): type dependency graph (value / guarded / alias edges, polarity), Tarjan SCC strata, `NF_RECURSIVE_TY`. E4240 alias cycles (incl. `type T = T`), N4241 by-value recursion via variant, N4242 non-positive, W4243 non-regular generic recursion. test 94.
- **μ-types** `theory_mu.c3` (~845): every recursive declaration → closed μ-type (struct product, enum tagged sum, `*T` → option); contractivity, least-fixpoint inhabitation **W4250** (enum with no base case), coinductive shape equality **N4251** (`--lint`). Also fixed `shift`/`subst` not descending into `ST_OPTION`. test 95.
- **Session types** `theory_session.c3` (~1230): endpoints from `let (tx, rx) = channel.oneshot()/bounded()/unbounded()` and `*…Sender/*…Receiver` params; per-party protocol from control flow (if/match → choice, loops → μ as cyclic graph); duality by coinductive subtyping both ways. **W4260** ends not dual (prints both protocols + first disagreement), **W4261** oneshot sent twice on a path, **N4262** parameter protocol (`--lint`). test 96. Corpus: 0 crashes, 0 warnings (only N4262 notes on the stdlib/channel.pie wrappers, lint-only).
- `NF_RECURSIVE_TY` (`rec-ty`) is on `N_DECL_TYPE`, visible in `--emit-ast`, if the backend wants to know a type is self-referential without re-walking.
- pfront 161/5 (same 5 pre-existing on z), stdlib 260/260.
- Note: A2A/todo.md on z lost its body in v0.8.6 (only the 2-line header remains) — Pear, was that intended?

### Next on my list
theory_hered (484, "stub hered_walk"), theory_ssa (347), theory_dataflow (438), theory_records (443), theory_verify (461).


## 2026-09-30 — hereditary substitution pass made real (PR #11 update)
- Replaced `theory_cmtt_meta.hered_walk` (recursive AST counter; saw lambdas but did not bind/substitute) and `theory_hered.ht_from_ast` (all identifiers were fake De Bruijn 0) with a single hash-consed de Bruijn engine in `theory_hered.c3` (~1,407 LoC).
- Translation uses resolver binder pointers; immutable lets → β-redexes; lambdas incl. curried tuple params; source calls, arithmetic, comparisons, if, pairs/projections, closures; imperative/mutating fragment becomes opaque and is never compared.
- Hereditary β substitution under binders with a decreasing simple-type metric, δ arithmetic/boolean/comparison, π projection, literal-if, η-contraction, modal β/η. Fuel cuts are counted; 0 on all 674 corpus inputs.
- N4270 equivalent pure functions/closures, N4271 η-wrapper, N4272 source β-redex and result, N4273 staging redex (`--lint`). Definitions compare after closing de Bruijn indices over captured binders, so closures with differently named parameters but the same captured binder compare correctly.
- Contextual splice meta-variables now feed `cmtt-meta`; importantly we do NOT claim metas are solved: the solved and occurs-check counters remain zero.
- Fixed a corpus crash (`token_type_name` can return null; guarded the normal-form printer). Corpus: 674 files, 0 crashes, 0 fuel cuts. pfront 164/5 (the same 5 pre-existing), stdlib 260/260. Test `97_hered.pie`.


## 2026-09-30 — dataflow framework now runs real analyses on the real CFG (PR #11 update)
- `theory_dataflow.c3` grew from 438 LoC of generic scaffolding plus a fake 4-block chain / hand-set GEN/KILL (and the solver was never called) to 1,011 LoC.
- One real `pfront_cfg::Cfg` with each function clause as a disconnected component; reaching definitions (forward may), available expressions (forward must), very-busy expressions (backward must), and live variables (backward may). Binder identity for definitions/variables; structurally equivalent pure binary/unary expressions; real GEN/KILL; per-component boundary facts.
- Repaired the solver: standard `OUT = GEN ∪ (IN − KILL)` for both may/must, initialize must at top, circular worklist, robust disconnected entry/exit handling. Each solve certifies monotonicity, all fixed-point equations, drained worklist; tests check lattice (assoc/commute/idempotence) and transfer monotonicity.
- `98_dataflow.pie`: branch diamond + loop: 7 real blocks/7 edges; 14 reaching def facts, 7 pure expression facts, 8 live variable facts; four solvers have zero lattice/monotonicity/equation violations, worklist empty.
- Full regressions pfront 167 pass / 4 fail (`63_modsys`, `megaload`, `opt_cascade`, `modsys` remain); the earlier cfg_backedge failure was a test parser bug: it matched the first `N iters` report (dataflow) instead of the liveness line. Fixed: filter `liveness         :`; now it passes (backedge present, 3 liveness iterations). stdlib 260/260. Corpus 675 files, zero crashes / partial dataflow analyses.
