# Theory integration audit (2026-09-30)

## Scope and standard

This audit asks whether each theory subsystem is (a) reachable from the compiler driver, (b) operating on real source ASTs, and (c) connected to an appropriate consumer. A proof/analysis is meaningfully integrated when its conclusions affect a justified diagnostic, transformation, lowering decision, or a checked report; it does **not** need to invent a runtime effect. Conversely, a pass being constructed, run, or printed is not by itself evidence that it changes language/compiler behavior.

Current source of truth audited: `dev` at `5e20e0a` (the latest commits are A2A audit/mission notes; the `pfront/**/*.c3` tree is unchanged from `d2548f8`). Main orchestration is `pfront/pfront_main.c3` plus `pfront/theory/theory_check.c3`. The driver's order is: parse/resolve and ordinary semantic/type checks; const-fold; theory registration/analysis and rewrites; SCCP/const-fold; optional AIR lowering. Type inference currently precedes the theory mutations, so metadata carried by every transformed AST node is a correctness requirement.

## Confirmed integration paths

| Producer / subsystem | Consumer or observable effect | Assessment |
|---|---|---|
| `theory_trs` + `theory_rwsite` | Rewrites only explicit `expr |> rules` / `expr |> rules*` sites; rules are scoped values, analyzed for termination/confluence, and the subject AST is replaced. | Real AST mutation, demonstrated by `tests/pfront/35_egraph_rewrite.pie` (`n * 2` normalizes to `n << 1`). Not a general-purpose optimizer over arbitrary expressions. |
| `theory_egraph` + `theory_eclass` | Equality saturation and constant analysis are attached to the same explicit fixpoint rewrite sites; extraction chooses a representative which replaces the subject. | Real work, verified by 35 and 84; only enters through those explicit sites. |
| `theory_term` | Shared deep-clone/substitution support used by rewrite and staging-related passes. | Correctness-critical infrastructure; it must carry semantic/type/resolution metadata, not just syntax. |
| `theory_comptime` + `theory_peval` | Run on the source AST and return transformed ASTs before lowering. | Real compile-time evaluation/specialization. Require effect/termination safety and preservation of typed/resolved metadata. |
| `theory_irdl` | Registered dialect operations are validated against source uses, then `lower_tree` replaces recognized operations. | Real lowering for represented/registered dialect constructs; not a universal IR replacement. |
| `theory_opt` | Runs on the AST after analyses. It consumes `theory_live`'s dead-definition facts and performs fixpoint simplification/DCE. | Real AST mutation and a concrete analysis-to-optimizer edge. |
| `theory_quals` → `theory_crdt` / `AirLower` / PEAR | Qualifier analysis writes `NF_PURE_FN`; CRDT/CALM classification reads it, and AIR carries the proven no-write fact to PEAR. | Real analysis-to-codegen edge: PEAR applies LLVM `memory(read)` (not `memory(none)` or `willreturn`) to proven no-write functions, plus `captures(none)` to explicitly typed pointer/reference params proven not retained. The function fact allows reads and divergence; the parameter fact does not imply `readonly` or `noalias`. |
| `theory_poly` | Solves generic substitutions and writes instantiated call metadata before lowering. | Real semantic metadata production; continue validating consumers in AIR and tests. |
| `theory_verify` | Checks tree integrity after the transformations and compares before/after snapshots. | Real safety net for transformations, although its current invariant set does not check type preservation. |
| `theory_symexe`, `theory_absint`, termination, effect/session analyses | Produce path-sensitive findings, proofs, and advisories. | Properly analysis-only unless a result is connected to a sound optimization or an explicit language policy. Do not convert every abstract fact into runtime behavior. |
| `theory_subtype` / `MatchRefiner` + `theory_subtype_engine` | Checks typed match-arm overlap and queries the shared three-valued engine for supported set-algebra aliases and let/const/static annotations; definite emptiness proofs emit W3291/W3292 under `--lint`. | The 47-case engine now has production source-site consumers. Unknown/nominal/refinement forms widen conservatively; default compilation remains permissive. |
| `theory_matching` → `NF_DENSE_SWITCH` → `AirLower` / PEAR | Marks certified dense integer/character match sites; AIR carries the hint to PEAR, which emits LLVM `switch` dispatch for distinct unguarded scalar literals and an optional final wildcard/binder. | First matcher-analysis-to-runtime-lowering edge. Scope is intentionally narrow; the general decision DAG and enum/payload matching remain separate. |
| `theory_pglcert` | Exhaustiveness certificates now recognize an unguarded all-wildcard row before searching for missing constructors in infinite scalar domains. | Removes a false W4090 report for integer/character matches with a catch-all; protected by the p110 certificate regression. |

Core, non-theory passes also perform real rewrites: `pfront_constfold`, `pfront_sccp`, and the ordinary optimizer. They are not evidence that the separate theory E-graph is globally integrated.

## Confirmed gaps / boundaries to keep visible

| Subsystem(s) | Current boundary found | Correct next integration target |
|---|---|---|
| `theory_pglcert`, `theory_matching` | PGL certificates still analyze/report exhaustiveness and redundancy; `theory_matching`'s dense scalar decision now propagates via `NF_DENSE_SWITCH` through AIR and becomes an LLVM switch for guarded-free integer/char literal arms. General decision DAGs are not yet AIR inputs; enum/payload/guard/fallthrough cases remain on the existing path. | Differentially test wider emitted match behavior against the certified tree, then consume the tree itself only after equivalence covers guards, payloads, binders, and fallthrough. Keep the scalar switch path limited to forms validated below. |
| `theory_ssa`, `theory_dataflow`, `theory_defun`, `theory_cps` | Construct/report SSA, dataflow, defunctionalization, or continuation representations; they are not the representation consumed by AIR lowering. `theory_live` is the exception because its dead-definition facts feed `theory_opt`. | Reuse representations only where semantics are proven and end-to-end tests demonstrate improved or safer lowering. |
| `theory_absint` | The interval analysis marks provably in-bounds index nodes, but AIR lowering does not currently consume that fact. | Define checked-index semantics first; then use the proof to elide a check (and test both in/out-of-bounds cases), or retain it as analysis-only. |
| `theory_quals` parameter facts | `NF_READONLY_PARAM` now maps only its no-retain component to LLVM `captures(none)` for explicit pointer/reference parameters. `readonly` is intentionally not attached: another aliased parameter could still write the same memory. Clause-pattern params and slices are not yet mapped. | Extend only after AIR carries reliable types for clause-pattern/slice parameters; retain the no-alias caveat and do not infer `noalias` or LLVM `readonly` from this flag. |
| `theory_bidi`, `theory_rowinfer`, `theory_mu`, `theory_records`, `theory_stratified`, `theory_session`, `theory_subtype*` | Distinct theoretical type engines run alongside the production `pfront_infer` / `pfront_check` implementation; their verdicts are not a blanket substitute for the compiler's primary type rules. Some are diagnostics/advisories or specialized declaration analyses. | Integrate narrow, explicitly specified judgments (e.g. inhabitedness or a supported subtype coercion) into the primary checker with soundness tests; avoid silently changing all type acceptance rules. |
| `theory_stage`, `theory_cmtt`, `theory_hered`, `theory_modal`, `theory_nbe` | Several are stage/context analyses or normalization engines; only the explicit compile-time/partial-evaluation paths mutate the production AST. | Keep proof-only passes diagnostic; test each mutating normalizer for effects, capture, and source metadata. |
| `theory_effects`, `theory_effcont`, `theory_linearity`, `theory_ub` | Effect rows, continuation/handler properties, linearity, and UB state are analyzed and reported; the PEAR runtime does not generally execute their intermediate representations. | Enforce only policy already represented in the source language (e.g. handler/linearity constraints); do not synthesize runtime handlers/UB behavior without a specified lowering. |
| `theory_bridge`, `theory_verify` | Cross-feature convention/integrity support. | Make reports actionable and run the relevant verifiers around every mutating pass. |

### File-by-file reachability inventory

This inventory distinguishes normal-pipeline code from a separately tested engine. “Analysis path” means the module is run on real ASTs and its decision is reported/advised; it does not imply AIR consumes the result.

| Area | Source modules | Reachability / current consumer class |
|---|---|---|
| Type algebra | `theory_setops`, `theory_subtype`, `theory_subtype_full`, `theory_mu`, `theory_records` | Production theory path: alias emptiness/match overlap; recursive-type translation and subtyping; record-lattice analysis. The new binding advisory is in `theory_subtype`. |
| Other type judgments | `theory_bidi`, `theory_rowinfer`, `theory_stratified`, `theory_session`, `theory_sct` | Invoked in normal pipeline for modal/bidirectional judgments, effect-row inference, bounded quantification, session duality, and size-change termination; currently proofs/diagnostics/reports rather than AIR inputs. |
| Set-theoretic subtype engine | `theory_subtype_engine` | The shared engine is initialized over the pipeline `TypeStore` and queried by `MatchRefiner` for supported set-algebra type aliases and binding annotations; `pfront_main --subtype-selftest` still exercises its 47-case decision-procedure spec. Unknown AST forms are widened conservatively rather than treated as nominally disjoint. |
| Meta/binding | `theory_term`, `theory_cmtt`, `theory_cmtt_meta`, `theory_hered`, `theory_modal`, `theory_msp`, `theory_nbe`, `theory_poly`, `theory_quals`, `theory_stage` | Called in normal pipeline for term utilities, contextual/stage judgments, handler/UB state, normalization/specialization, polymorphic metadata, and qualifier facts. `NF_PURE_FN` now reaches PEAR as function-level LLVM `memory(read)`, and typed pointer/reference params carry `NF_READONLY_PARAM` to LLVM `captures(none)`; other outputs are checks/advice or feed named analysis consumers. |
| Effects/resources | `theory_cps`, `theory_effcont`, `theory_effects`, `theory_linearity`, `theory_ub` | Called for continuation/effect/handler, linearity, and UB analyses. They do not define new runtime behavior unless a separate lowering path exists; CPS output is explicit opt-in. |
| Rewrite/optimization | `theory_crdt`, `theory_eclass`, `theory_egraph`, `theory_opt`, `theory_rwsite`, `theory_trs` | Normal-pipeline analysis/transformation. E-class facts attach to saturation; TRS/E-graph mutate explicit rewrite sites; liveness feeds optimizer DCE; qualifier purity feeds CRDT classification and PEAR's LLVM `memory(read)` / `captures(none)` attributes under separate function/parameter proof conditions. |
| Rewrite proof module | `theory_trs_proof` (same C3 module as `theory_trs`) | `RuleSet.analyse` is called by `RwSites` on first use of each source rewrite set. LPO termination and critical-pair/confluence results drive source-site notes/counters; rewrite execution remains fuel-bounded even when termination is proved. |
| Lowering/dataflow | `theory_dataflow`, `theory_defun`, `theory_irdl`, `theory_irdlssa`, `theory_irdlverify`, `theory_live`, `theory_matching`, `theory_pglcert`, `theory_ssa` | Normal-pipeline builders/checkers run. IRDL has a real AST-lowering call for registered opcodes; liveness facts feed `theory_opt`; `NF_DENSE_SWITCH` now selects a bounded scalar match-lowering path. The full SSA/CPS/matching DAGs remain distinct from the AIR representation. |
| Whole-program analysis/support | `theory_absint`, `theory_bridge`, `theory_symexe`, `theory_verify` | Feature/convention scanning, abstract interpretation, bounded symbolic execution, and post-transform integrity checks are run. Absint's in-bounds bit currently has no AIR consumer; symbolic/abstract facts are not silently treated as runtime effects. |

All 49 `pfront/theory/**/*.c3` modules are compiled into the driver. A source cross-check corrected an earlier false gap: `theory_trs_proof.c3` declares the `theory_trs` module and its `RuleSet.analyse` is reached through `RwSites` on rewrite-set use. Reachability is therefore not the same as integration: the matrices above record consumer paths rather than counting allocations or report calls as proof of integration.

## Changes in this audit branch

1. `theory_term.clone_term` now copies source spans, inferred type fields, effects, resolution/symbol/owner links, and the payload, in addition to syntax/flags.
2. `EGraph.extract` now copies those metadata fields to rebuilt nodes and preserves the original rewrite site's inferred type on a synthesized root. Equality-preserving rewrites must not erase type information needed later by AIR lowering.
3. Added `--theory-metadata-selftest`, which checks both deep cloning and extraction onto an otherwise-untyped synthesized root. It is run by `tests/pfront/run.sh`.
4. `NF_TYPED` means typed metadata; abstract bounds proofs were incorrectly writing that bit. They now use a distinct `NF_BOUNDS_PROVEN` fact bit. This avoids contaminating type-cache consumers with a non-type analysis fact.
5. The production `MatchRefiner` now queries the three-valued subtype engine over the pipeline's shared `TypeStore` for supported set-algebra type aliases and `let`/`const`/`static` annotations. Definite emptiness proofs produce opt-in W3291 (alias) or W3292 (binding). Resolved transparent aliases are followed; unsupported/nominal subexpressions remain an explicit unknown sentinel through compound types, and negation widens unknown to TOP rather than manufacturing an empty proof. The fixture covers primitive emptiness, a transparent `i32` alias and its complement, and an opaque pointer alias beneath negation.
6. `theory_matching`'s `NF_DENSE_SWITCH` result now travels through `AirCns`/`AirCmd` to PEAR. PEAR emits LLVM `switch` only for at least four distinct unguarded integer/character literals and an optional final wildcard or binder; duplicates, guards, branch-local bindings, and non-scalar patterns use the old path. `theory_pglcert` now recognizes an unguarded all-wildcard row as exhaustive before looking for gaps in infinite scalar domains, preventing false W4090 on these matches.

The metadata and advisory changes preserve existing runtime semantics. The dense-switch slice intentionally changes generated control flow while preserving match results; it is gated to the validated scalar shape and covered at runtime across optimization tiers. The qualifier slice changes optimizer knowledge only: a no-write proof maps to LLVM `memory(read)`, not `memory(none)` or `willreturn`; the regression checks a pointer-writing function remains writable and observes the mutation at all optimization tiers. No new source program is rejected.

## Verification performed

- Build: successful with C3 0.8.4 using the restored compiler, a clean stdlib root (`C3C_LIB=/home/user/c3lib-clean`), LLVM 23, and the large-stack-object option (`--max-stack-object-size 262144`). The plain Make invocation's `/home/user/c3lib` contained duplicate stdlib roots in this restored workspace; using a clean root avoided those environment conflicts.
- `--theory-metadata-selftest`: PASS (0 failures).
- `35_egraph_rewrite.pie`: PASS; final AST contains the expected shift rewrite.
- `tests/pfront/run.sh`: pass=167, fail=5; baseline recorded by the suite is pass≥160, fail≤5. The suite emitted two pre-existing shell `n: command not found` messages around lines 1715/1717, but completed successfully. Existing five known failures remain outside this change.
- `tests/exec/pear/run.sh`: pass=31, fail=0, xfail=0 at -O0/-O1/-O2/-O3 (O0/O1/O3 used a temporary runner substitution, removed afterward). `p110_dense_switch.pie` exercises dense integer and character expression matches, a clause-style match, and wildcard defaults; returns 190 at all four tiers, including a final catch-all binder. PGL emits no false W4090 for its wildcard-covered scalar domains. `p111_quals_memory_read.pie` asserts that exactly two qualifier-proven functions receive LLVM `memory(read)` (including a pointer-reading function), exactly two non-retained pointer parameters receive `captures(none)`, and a function writes through q while reading aliased p (guarding against unsound `readonly`). The pointer-writing callee gets neither no-write fact; the program returns 35 at -O0/-O1/-O2/-O3.
- `--subtype-selftest`: 47/47 PASS. `tests/pfront/107_uninhabited_let.pie`: the production engine reports 6 queries (3 proved empty, 3 refuted); the empty alias gets W3291 and the primitive-empty plus negated-known-alias bindings get W3292 only under `--lint`. Negated opaque-pointer aliases remain quiet directly and through a union, and the same source without `--lint` has no subtype warnings.
- `bash conformance/run.sh`: pass=218, fail=44 (same known baseline); `bash experiments/run.sh`: all 14 files behaved as expected.
- `84_eclass_analysis.pie`: expected unsound-rule warnings still occur; process exit 1 reflects warnings.
- Agent-4's current report was rechecked; it documents independent PEAR/runtime defects and theory gaps. The dense scalar switch path closes part of the match-analysis/lowering gap; general decision-DAG, payload/binder, guard, and fallthrough cases remain explicit follow-up items rather than being hidden by this patch.

## Acceptance and follow-up

This branch now has three additional producer-to-consumer edges beyond metadata preservation: the subtype engine drives opt-in alias/binding emptiness advice; dense scalar match classification selects real LLVM switch dispatch; and qualifier facts become LLVM `memory(read)` function and `captures(none)` parameter attributes under their respective proof conditions. It also fixes a false exhaustiveness witness for wildcard-covered infinite domains. It does **not** claim that every analysis is now a lowering input. Next slices should be independently semantics-reviewed and tested: (1) extend match-lowering handoff only after differential coverage for guards, payloads, binders, and fallthrough; (2) define checked-index semantics before consuming `NF_BOUNDS_PROVEN`; (3) identify additional clone/rebuild helpers that can drop metadata; and (4) extend `captures(none)` only for clause-pattern/slice parameters after AIR type mapping is reliable; do not infer `readonly`/`noalias` from the current fact. The broad goal remains open until every subsystem has an intended consumer and regression tests for that edge.


## Agent-n3 integration correction — semantic attributes (2026-10-01)

The original helpers attached custom LLVM string attributes named memory and
captures. Quoted `"memory"="read"` / `"captures"="none"` are not semantic LLVM
contracts, even when a stdout counter increments. N3 uses named attribute-kind
lookup plus LLVMCreateEnumAttribute with LLVM-23 parser-verified payloads:
memory(read)=1365, captures(none)=0. The direct C3 unit tests the actual helpers
on a body-less declaration, where optimization cannot infer either attribute.
It failed 0/2 before the correction and passes 2/2 after; make test runs it.
No readonly/noalias/termination strengthening is made. The four driver-flag
runtime matrices remain identical after activating these real contracts.

## Agent-4 review follow-up — narrow clause-pointer lowering

The follow-up branch from PR #17 head `7e25543` fixes one reproduced PEAR case:
a lone `APAT_BIND` clause whose body is exactly `binder[literal-index] -> %ret`.
PEAR binds that pattern name to the already-evaluated scrutinee, then lowers the
existing indexed reader. The guard and complete AirCmd/AirCns shape are checked
before taking this path. General binder bodies, guarded clauses, tuple/enum
payloads, and clause-parameter qualifier facts remain outside its scope.

The new `p112_clause_binding_pointer.pie` regression returns 37 under -O0/-O1/-O2/-O3,
and `tests/exec/pear/run.sh` runs those four checks. In this restored workspace,
that targeted regression passed all tiers after a successful C3 0.8.4 build with
LLVM 19. The full PEAR runner had 34 passes, one expected XFAIL, and one failure:
p111's LLVM-23 semantic-attribute assertion cannot pass against LLVM 19. The full
gate must be rerun with LLVM 23; do not treat the local full-suite result as green.
