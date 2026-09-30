# theory/lower — IR lowering, decision trees, dataflow

Passes that map the surface AST into lower-level forms: MLIR-style dialect
verification (IRDL), pattern-match compilation (PGL + Maranget), SSA
construction, defunctionalization, and bitvector dataflow + liveness.

| File                    | Paper / topic                                                                  |
|-------------------------|--------------------------------------------------------------------------------|
| `theory_irdl.c3`        | MLIR IRDL dialect registration and lowering (Fehr et al. 2022)                 |
| `theory_irdlssa.c3`     | IRDL-SSA constraint system: `is/any/any_of/all_of/parametric`, union-find      |
| `theory_irdlverify.c3`  | IRDL trait verification: SSA form, dominance, purity, termination              |
| `theory_pglcert.c3`     | PGL pattern-certificate compiler: exhaustiveness witnesses, redundant clauses  |
| `theory_matching.c3`    | Maranget (2008) decision-tree compiler: column scoring, specialization matrix  |
| `theory_ssa.c3`         | Real clause CFG dominators/frontiers, binder-aware IDF phis, value renaming, predecessor operands, CFG/DF/liveness/version certificates |
| `theory_defun.c3`       | Defunctionalization (Reynolds 1972; Danvy/Nielsen 2001): lambda census,       |
|                         | free-variable capture, escape analysis, inline-candidate classification        |
| `theory_dataflow.c3`    | Generic monotone bitvector dataflow framework (FORWARD/BACKWARD, OR/AND),      |
|                         | DfBundle with 3 pre-made analyses: reaching defs, available exprs, very-busy   |
| `theory_live.c3`        | Liveness analysis (backward, AND meet): SP-ERM-e-SSI classification for SSI    |

## Central ideas

- **IRDL-SSA** (`theory_irdlssa.c3`): constraint variables represent type sets;
  equality propagation through union-find collapses CVs known to be equal.
  `all_of(cv, cvs...)` unifies cv with each child; `any_of` introduces a union;
  `is` fixes to a single type; `parametric` carries arguments.
- **Maranget decision trees** (`theory_matching.c3`): a pattern matrix is
  scored by the "need" heuristic — columns with more constructor-headed
  patterns are switched on first; specialisation projects one column; the
  default matrix keeps wild-only rows; exhaustiveness leaves a non-empty
  default at a leaf.
- **Cytron SSA plan** (`theory_ssa.c3`): builds a dominator forest per real
  function-clause CFG, sparse dominance frontiers, and a source-definition
  table keyed by binder and assignment site. Iterated-frontier worklists place
  variable-specific phis; a dominator-tree traversal assigns versions, maps
  local uses, and resolves each phi operand from ordered predecessor exits.
  CFG reciprocity, liveness equations, small-graph dominators, full small-graph
  DF closure, IDF closure, version identity and operand dominance are checked.
  If CFG inline edge caps are reached, the report marks the analysis partial
  rather than certifying a silently truncated graph. This is an analysis plan,
  not an AST rewrite.
- **Defunctionalization** (`theory_defun.c3`): each lambda gets a tag + env
  record; `apply(fn, args)` dispatches. Census counts free variables per
  lambda, arity histogram, and escaping lambdas (passed/returned/stored);
  non-escaping single-use lambdas are flagged as inline candidates.
