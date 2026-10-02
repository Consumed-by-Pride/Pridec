# Agent-n3 — theory implementation + integration owner

Assignment changed by the owner on 2026-10-01: agent-n3 handles both integration
and the theory work previously assigned to Father-of-Pride. Father-of-Pride is
not on the active implementation queue. PEAR-bro remains a backend collaborator;
Agent-4 remains the independent verifier. This is a responsibility update, not
a claim that every outstanding theory task is finished.

## Delivery discipline

- Existing AIR is the canonical production boundary. Auxiliary representations
  do not become compiler features just because they exist or print counters.
- Unsupported/unknown judgments and exhausted budgets do not authorize LLVM
  assumptions. Preserve Pride's specified untyped/gradual policy; do not
  silently replace it with a different typed language.
- Define a supported fragment, a conservative analysis/model, an explicit AIR
  consumer, and adversarial source/IR/native tests for each vertical slice.
- One reviewable concern per commit; no generated compiler padding or synthetic
  counters. Independent Agent-4 verification before dev landing.

## P01 — conservative effects/capture contracts (implemented, review pending)

Branch `n3/theory-air-contracts`, based on audited integration source 7e25543.
Details: docs/dev/THEORY_AIR_CONTRACTS.md.

- Fix false capture-none producer claims from assignment/cast/alias/control
  exposure and unknown callees; treat untracked indirect writes conservatively.
- Recompute facts after the last AST rewrite; clear stale flags and withhold
  incomplete/over-budget summaries.
- Carry final candidates into AIR and independently screen lowered effects/
  dependencies. Only AIR_CHECKED claims reach LLVM.
- Preserve the mixed scalar-match fixture's semantics without a dense hint;
  hints select switch vs comparison-chain lowering, not correctness.
- Preserve character payload semantics through AIR/native without partial-eval
  dependence; resolve LLVM attribute selectors by name.
- Add producer and forged/stale AIR-contract tests. Keep normal baselines honest.

@agent4 please independently verify P01 before dev: stored/returned addresses, alias writes, rewrite-induced effects, unsupported/budget cases, dependency invalidation, LLVM attrs and theory-on/off native dispatch.

## P02 — mandatory semantic elaboration vs optional analyses

Move required supported lambda/comptime/scoped-rewrite semantics into an explicit
core-to-AIR elaboration contract. Optional analysis/debug flags must not silently
emit wrong programs when the backend cannot interpret an unlowered construct.
Unsupported native forms must diagnose, not become zero/unreachable artifacts
that look like successful compilation. Existing --no-verify driver coupling
also needs correction.

## P03 — real dialect lowering  (IMPLEMENTED on `n3/theory-irdl-lowering`; see docs/dev/IRDL_LOWERING.md)

Specify/reuse source grammar for opcode arity and lowering actions, register
those rules, check supported templates, and lower through AIR. Name registration
alone is not IRDL execution. Provide tests with real arithmetic/results, not only
registry counts; diagnose missing native implementations.

## P04 — coherent production type/effect judgments

Reconcile the primary inference table and theoretical stores. Use explicit
proved/refuted/unknown judgments and language-policy rules. Keep supported
emptiness advice and alias behavior clear; budgets/unsupported forms widen,
never prove safety. Do not mistake substituted signatures for monomorphized
bodies or wide-record analysis for working native layouts.

## P05 — actual control/closure/effect AIR consumers

Complete supported generic matching, explicit closure environments/capture
lifetimes, and real scoped-handler/perform/resume lowering/runtime. Decide
whether SSA/dataflow/CPS become production AIR transformations or remain
optional analyses; avoid maintaining multiple unrelated mandatory compiler IRs.
No full DAG/tail/session/deadlock guarantees without consumers and justified
preconditions.

## P06 — verifier/property depth and default cost

Separate algorithm calibration, source judgments, producer fact soundness, AIR
invariants and native semantics tests. Move disconnected/absent-feature models
and large built-in calibration matrices behind explicit analysis/self-test or
lazy initialization. Structural snapshots are not semantic equivalence proofs.
Mechanized proofs are a distinct later milestone, not a label on a passing suite.

Status updates will record measured behavior and exact pushed heads; P02–P06
are outstanding engineering work, not declared capabilities.
