# Theory-integration audit — current dev pass

**Target:** `dev` at source commit `d2548f8` (2026-09-30)
**Work branch:** `feat/theory-integration-dev`
**Workspace:** `/home/user/pridec-theory-pr`

## Confirmed cross-pass defect and fix in this branch

The source type checker runs before `TheoryPipeline`. `theory_term.clone_term` and `EGraph.extract` were rebuilding ASTs without copying all type/resolution/effect metadata, while AIR lowering consumes `type_slot` in several paths. This is a real cross-pass correctness risk. Changes now:

- clone copies spans, `type_slot`/`type_id`/`type_ann`, effects, resolution, symbol/owner and payload fields;
- extraction copies those fields on rebuilt nodes and carries the original typed site onto the extracted root;
- `--theory-metadata-selftest` covers clone preservation and root metadata propagation; `tests/pfront/run.sh` executes it;
- absint's `NF_TYPED` misuse was separated into `NF_BOUNDS_PROVEN`, so a bounds fact cannot impersonate a type fact;
- the production MatchRefiner now queries `theory_subtype_engine` over the pipeline's shared `TypeStore` for supported set-algebra aliases and let/const/static annotations. It emits W3291/W3292 only under `--lint` on definite empty-type proofs; unknown aliases widen conservatively (including beneath negation).

`--theory-metadata-selftest` reports PASS (0 failures); `--subtype-selftest` remains 47/47; the fixture exercises the real engine (4 queries: 2 emptiness proofs, 2 refutations) and verifies alias/binding warning opt-in; `35_egraph_rewrite.pie` still rewrites to a shift.

## Wiring status to retain for follow-up

- E-graph + e-class constant analysis are real, but currently only enter at explicit fixpoint `|>` rewrite sites; they are not the general arithmetic optimizer.
- TRS scoped values and rewrites do replace AST subjects at those sites.
- liveness facts feed `theory_opt`; qualifier purity facts feed CRDT classification; polymorphism and dialect lowering have metadata/lowering paths.
- The `theory_matching` pass sets `NF_DENSE_SWITCH`, but no consumer currently reads that bit; PEAR's `ACNS_CASE` still lowers Boolean cases only. This is a concrete lowering gap, but switch lowering must wait for correct payload/binder/fallthrough semantics and differential tests. SSA/dataflow, CPS and defunctionalization representations likewise are not currently AIR inputs. Abstract bounds proofs remain analysis-only because array/pointer checked-index semantics are not established.
- Semantic subtyping is not the production type checker's universal subtype rule, but the set-theoretic engine now has source-site consumers for supported alias/binding emptiness proofs (opt-in W3291/W3292). Agent-4's round-6 report identified the silent-advice gap; these changes close that limited edge. Unsupported aliases/refinements are deliberately widened.
- Correction from source cross-check: `theory_trs_proof.c3` declares the same `theory_trs` module, and `RwSites` calls `RuleSet.analyse`; its termination/confluence results already feed notes/counters. The previous audit's "no production call site" classification was wrong.

See `docs/THEORY_INTEGRATION_AUDIT.md` for the full consumer/gap matrix and verification notes. The broad goal remains open: the objective is not to make every proof a runtime effect, but to connect each sound result to an appropriate language policy, optimization, or checked compiler contract.

## Test result

`LD_LIBRARY_PATH=/home/user/.cache/llvm23 bash tests/pfront/run.sh`: pass=166, fail=5; the script's recorded baseline is pass≥160/fail≤5, so it returns 0. `bash conformance/run.sh`: pass=218, fail=44 (known baseline); `bash experiments/run.sh`: all 14 files behaved as expected. The known 5 pfront and 44 conformance failures are unchanged/out of scope here. The pfront script also prints two existing `n: command not found` messages around lines 1715/1717. Build in the restored workspace used C3 0.8.4 + LLVM 23, a clean stdlib root (`C3C_LIB=/home/user/c3lib-clean`), and `--max-stack-object-size 256000`; the default `/home/user/c3lib` contains duplicate stdlib roots here.
