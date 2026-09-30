# Theory-integration audit — current dev pass

**Branch:** `dev`, source commit `d2548f8` (2026-09-30)
**Workspace:** `/home/user/pridec-theory-audit`

## Confirmed cross-pass defect and fix in this branch

The source type checker runs before `TheoryPipeline`. `theory_term.clone_term` and `EGraph.extract` were rebuilding ASTs without copying all type/resolution/effect metadata, while AIR lowering consumes `type_slot` in several paths. This is a real cross-pass correctness risk. Changes now:

- clone copies spans, `type_slot`/`type_id`/`type_ann`, effects, resolution, symbol/owner and payload fields;
- extraction copies those fields on rebuilt nodes and carries the original typed site onto the extracted root;
- `--theory-metadata-selftest` covers clone preservation and root metadata propagation; `tests/pfront/run.sh` executes it;
- absint's `NF_TYPED` misuse was separated into `NF_BOUNDS_PROVEN`, so a bounds fact cannot impersonate a type fact;
- the semantic-subtyping match refiner now checks set-theoretic annotations on let/const/static bindings and emits W3292 only under `--lint` when emptiness is proved. The same source compiles permissively without the warning by default.

`--theory-metadata-selftest` reports PASS (0 failures); `35_egraph_rewrite.pie` still rewrites to a shift; `tests/pfront/107_uninhabited_let.pie` exercises W3292.

## Wiring status to retain for follow-up

- E-graph + e-class constant analysis are real, but currently only enter at explicit fixpoint `|>` rewrite sites; they are not the general arithmetic optimizer.
- TRS scoped values and rewrites do replace AST subjects at those sites.
- liveness facts feed `theory_opt`; qualifier purity facts feed CRDT classification; polymorphism and dialect lowering have metadata/lowering paths.
- PGL/matcher, SSA/dataflow, CPS and defunctionalization representations are not currently the representation consumed by AIR lowering. Abstract bounds proofs are currently not consumed by AIR. Keep those analyses advisory until an equivalent lowering/check contract exists.
- Semantic subtyping has an executable decision engine, but its verdicts are not the production type checker's universal subtype rule. Agent-4's latest report still flags subtype advice for uninhabited annotations as silent.

See `docs/THEORY_INTEGRATION_AUDIT.md` for the full consumer/gap matrix and verification notes. The broad goal remains open; the current patch fixes metadata fidelity rather than claiming all analysis engines have become backend passes.

## Test result

`LD_LIBRARY_PATH=/home/user/.cache/llvm23 bash tests/pfront/run.sh`: pass=166, fail=5; the script's recorded baseline is pass≥160/fail≤5, so it returns 0. `bash conformance/run.sh`: pass=218, fail=44 (known baseline); `bash experiments/run.sh`: all 14 files behaved as expected. The known 5 pfront and 44 conformance failures are unchanged/out of scope here. The pfront script also prints two existing `n: command not found` messages around lines 1707/1709. Build in the restored workspace used C3 0.8.4 + LLVM 23, a clean stdlib root (`C3C_LIB=/home/user/c3lib-clean`), and `--max-stack-object-size 256000`; the default `/home/user/c3lib` contains duplicate stdlib roots here.
