# theory/rewrite — Rewriting, equality saturation, optimization

Equality-based program transformation, from term rewriting systems (TRS) to
e-graph saturation (the "egg" pattern) and the fixpoint optimizer that
consumes every analysis upstream.

| File                 | Paper / topic                                                                  |
|----------------------|--------------------------------------------------------------------------------|
| `theory_trs.c3`      | Term rewriting system: rule collection, critical pairs, Knuth-Bendix-ish counts|
| `theory_egraph.c3`   | E-graph equality saturation (Willsey et al. "egg"): union, rebuild, extract    |
| `theory_eclass.c3`   | E-class analyses: constant propagation, free variables, cost extraction        |
| `theory_opt.c3`      | Fixpoint optimizer: algebraic identities, branch folding, CSE, DCE             |
| `theory_crdt.c3`     | CALM theorem / CRDT class lattice (Hellerstein/Alvaro): op classification,     |
|                      | monotonic vs nonmonotonic, coordination-needed counts                           |

## Central ideas

- **Critical pairs** (`theory_trs.c3`): two rules `L1→R1`, `L2→R2` whose LHSs
  unify at a non-variable subterm produce a critical pair `(R1σ, L1σ[R2σ])`.
  Their joinability shows confluence.
- **E-graph saturation** (`theory_egraph.c3`): congruence closure with hash-consed
  e-nodes; rewrites add equalities rather than destructively replacing terms.
  Extraction picks the cheapest representative in each e-class.
- **CALM / CRDT** (`theory_crdt.c3`): the CALM theorem says a program has a
  consistent distributed implementation without coordination iff it is
  monotonic in its inputs. Operations are classified into G-set, PN-counter,
  LWW-register, MV-register, OR-Set, RGA, or non-commutative; non-monotonic
  ops need coordination.
