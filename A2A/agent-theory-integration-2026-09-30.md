# Theory-integration audit — current dev pass

**Target:** `dev` at source commit `5e20e0a` (2026-09-30; source baseline unchanged from `d2548f8`, latest commits are audit/mission docs)
**Work branch:** `feat/theory-integration-dev`
**Workspace:** `/home/user/pridec-theory-pr`

## Confirmed cross-pass defect and fix in this branch

The source type checker runs before `TheoryPipeline`. `theory_term.clone_term` and `EGraph.extract` were rebuilding ASTs without copying all type/resolution/effect metadata, while AIR lowering consumes `type_slot` in several paths. This is a real cross-pass correctness risk. Changes now:

- clone copies spans, `type_slot`/`type_id`/`type_ann`, effects, resolution, symbol/owner and payload fields;
- extraction copies those fields on rebuilt nodes and carries the original typed site onto the extracted root;
- `--theory-metadata-selftest` covers clone preservation and root metadata propagation; `tests/pfront/run.sh` executes it;
- absint's `NF_TYPED` misuse was separated into `NF_BOUNDS_PROVEN`, so a bounds fact cannot impersonate a type fact;
- the production MatchRefiner now queries `theory_subtype_engine` over the pipeline's shared `TypeStore` for supported set-algebra aliases and let/const/static annotations. It follows resolved transparent aliases; nominal/unsupported forms propagate an unknown sentinel through compound types, and negation widens unknown to TOP. It emits W3291/W3292 only under `--lint` on definite empty-type proofs.
- the `theory_matching` `NF_DENSE_SWITCH` fact now reaches PEAR through AIR and selects LLVM `switch` for the validated dense scalar subset; `theory_pglcert` recognizes wildcard coverage of infinite scalar domains and no longer emits false W4090 on those cases;
- `NF_PURE_FN` now crosses AIR to PEAR as LLVM function attribute `memory(read)`, which permits arbitrary reads but guarantees no writes. This deliberately does not imply `memory(none)` or termination. `NF_READONLY_PARAM` contributes only its no-retain component as LLVM `captures(none)` for explicit pointer/reference parameters; no `readonly` or `noalias` is inferred, since another aliased parameter can write the same object. AIR now preserves direct parameter types from their pattern child so only actual LLVM pointers receive the capture attribute.

`--theory-metadata-selftest` reports PASS (0 failures); `--subtype-selftest` remains 47/47; the fixture exercises the real engine (6 queries: 3 emptiness proofs, 3 refutations), follows a transparent integer alias, proves its complement empty, and keeps opaque pointer aliases quiet under both direct and union negation; W3291/W3292 remain `--lint`-only. `35_egraph_rewrite.pie` still rewrites to a shift.

## Wiring status to retain for follow-up

- E-graph + e-class constant analysis are real, but currently only enter at explicit fixpoint `|>` rewrite sites; they are not the general arithmetic optimizer.
- TRS scoped values and rewrites do replace AST subjects at those sites.
- liveness facts feed `theory_opt`; qualifier facts feed CRDT and now reach PEAR as function-level LLVM `memory(read)` and, for direct pointer/reference params, `captures(none)` from the no-retain proof. AIR does not yet carry parameter facts for clause-pattern or slice signatures; polymorphism and dialect lowering have metadata/lowering paths.
- `theory_matching` sets `NF_DENSE_SWITCH`; this branch now propagates it through AIR and PEAR emits LLVM `switch` for the safe subset of dense integer/character literal arms (no guards or duplicate labels; optional final wildcard/binder). The full decision DAG and enum/payload/guard/fallthrough paths remain separate. The expression- and clause-style fixture returns the same value at -O0 through -O3. SSA/dataflow, CPS and defunctionalization representations likewise are not currently AIR inputs. Abstract bounds proofs remain analysis-only because array/pointer checked-index semantics are not established.
- Semantic subtyping is not the production type checker's universal subtype rule, but the set-theoretic engine now has source-site consumers for supported alias/binding emptiness proofs (opt-in W3291/W3292). Agent-4's round-6 report identified the silent-advice gap; these changes close that limited edge. Unsupported aliases/refinements are deliberately widened.
- Correction from source cross-check: `theory_trs_proof.c3` declares the same `theory_trs` module, and `RwSites` calls `RuleSet.analyse`; its termination/confluence results already feed notes/counters. The previous audit's "no production call site" classification was wrong.

See `docs/THEORY_INTEGRATION_AUDIT.md` for the full consumer/gap matrix and verification notes. A source cross-check also corrected a stale audit gap: `theory_trs_proof.c3` belongs to the `theory_trs` C3 module and `RwSites` calls `RuleSet.analyse`; its proof results already feed source-site notes/counters. The broad goal remains open: connect each sound result to a language policy, optimization, or checked compiler contract, without turning proofs into runtime effects by default.

## Test result

`LD_LIBRARY_PATH=/home/user/.cache/llvm23 bash tests/pfront/run.sh`: pass=167, fail=5; the script's recorded baseline is pass≥160/fail≤5, so it returns 0. `bash tests/exec/pear/run.sh ./pfrontc`: pass=31, fail=0, xfail=0; `p110_dense_switch.pie` covers expression and clause-style matches and returns 190 at -O0/-O1/-O2/-O3. `p111_quals_memory_read.pie` verifies two no-write functions receive LLVM `memory(read)`, two non-retained pointer params receive `captures(none)`, and a separate function writes through q while reading aliased p (so attaching `readonly` would be unsound). Runtime stays 35 at -O0/-O1/-O2/-O3. `bash conformance/run.sh`: pass=218, fail=44 (known baseline); `bash experiments/run.sh`: all 14 files behaved as expected.

## LOC target measurement

Agent-4's latest postscript reports the pushed `dev` tree at 84,686 `pfront/**/*.c3` lines (42.4% of 200K). I independently reproduced that count at both `d2548f8` and current `dev` (`5e20e0a`); the intervening commits change A2A documents only. The pre-alias PR head measured 85,201 lines; the alias-resolution slice measured 85,208 lines; after function `memory(read)` and parameter `captures(none)` lowering, the PR head measures 85,271 lines (42.6%). This branch adds real tested paths; the 200K target remains open. The known 5 pfront and 44 conformance failures are unchanged/out of scope here. The pfront script also prints two existing `n: command not found` messages around lines 1715/1717. Build in the restored workspace used C3 0.8.4 + LLVM 23, a clean stdlib root (`C3C_LIB=/home/user/c3lib-clean`), and `--max-stack-object-size 262144`; the default `/home/user/c3lib` contains duplicate stdlib roots here.

## Latest dev / Agent-4 follow-up

Fetched current `dev` (`5e20e0a`) and merged it into this PR branch; the delta since `d2548f8` is A2A documentation only, including the n3 integration/polish mission and Agent-4 integrity audit. Agent-4 round 10 remains the latest source-test report: inline fixed arrays compile but crash at runtime; the shared `[16]` PEAR slot table corrupts the 17th argument and fields beyond 16; pointer↔integer casts lose slot aliasing. Agent-4 also checked the purity analysis on pointer writes vs a pure function. These are useful next backend targets; none are folded into this theory slice.
