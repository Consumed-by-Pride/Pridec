# theory/analysis — Whole-program analyses and cross-pass glue

| File                  | Paper / topic                                                                 |
|-----------------------|-------------------------------------------------------------------------------|
| `theory_absint.c3`    | Abstract interpretation (Cousot&Cousot): intervals / signs / nullness with    |
|                       | widening to a post-fixpoint. Feeds bounds elision.                            |
| `theory_bridge.c3`     | Feature scan + convention audit: a lightweight first pass recording which    |
|                       | language constructs are present, letting later passes skip empty trees.      |
| `theory_verify.c3`    | Snapshot-diff verifier: before/after tree fingerprints localise a bad rewrite |
|                       | to the pass that caused it.                                                   |
| `theory_symexe.c3`    | Bounded symbolic execution (King 1976; KLEE-style): SymVal/SymPath/PathCond,  |
|                       | path forking at branches, constant-folding feasibility, div0/null-deref bugs  |

## Notes

These are "end-of-pipeline" consumers: `absint` feeds the optimizer, `bridge`
drives pass skipping, `verify` validates that the earlier pipeline did not
corrupt the AST, and `symexe` produces bug-finding counterexamples.

The symbolic executor is bounded (max 256 paths, depth 64) and uses a simple
syntactic feasibility check rather than an external SMT solver — enough to
prune obviously contradictory paths (x == 3 ∧ x != 3) and flag obvious
divide-by-zero / null-deref on reachable paths.
