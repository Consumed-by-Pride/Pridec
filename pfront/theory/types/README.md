# theory/types — Type systems and subtyping

Implementations of type-system engines drawn from the literature.

| File                    | Paper / topic                                                                       |
|-------------------------|-------------------------------------------------------------------------------------|
| `theory_setops.c3`      | Type algebra core — DNF, union/intersection/negation nodes (Frisch/Castagna/Benzaken) |
| `theory_mu.c3`          | Recursive μ-types: shift/subst, contractivity, coinductive subtyping w/ memo        |
| `theory_subtype.c3`     | Semantic DNF subtyping: absorption, bounded distribution, conservative fallbacks, match refinement |
| `theory_subtype_full.c3`| Bounded atom-level emptiness: products, rows, arrays, options, arrows, checked AST translation |
| `theory_records.c3`     | Record type lattice (Castagna et al. ICFP'23): width+depth subtyping, field inter.  |
| `theory_rowinfer.c3`    | Row types for effects/records — Wand/Rémy-style polymorphic rows                    |
| `theory_bidi.c3`        | Bidirectional typing (Pierce/Turner): check ↔ infer modes, modal box types          |
| `theory_stratified.c3`  | Kernel F<: bounded quantification (Cardelli/Mitchell/Pierce): refl/top/bot/fun/∀     |
| `theory_session.c3`     | Binary session types (Honda/Vasconcelos/Kubo; Gay & Hole): duality, coinductive sub.|
| `theory_sct.c3`         | Size-Change Termination (Lee/Jones/Ben-Amram POPL'01): SCG composition, idempotence |

## Central operations

- **Emptiness check** (`theory_subtype_full::is_empty`): a type is declared
  empty only when bounded atom-level reasoning proves every DNF clause
  inconsistent. Malformed references, allocation/atom-budget failures, and
  recursion cutoffs return “not proven empty” rather than a false proof.
  Supported clauses check primitive/nominal contradictions, product
  projections, record width/depth, array/option payloads, and arrow
  contra-/covariance. `verify_semantic_laws` runs a bounded matrix of Boolean,
  constructor-variance, record, and malformed-input regression checks.
- **DNF subtyping driver** (`theory_subtype::SemanticSubtyper`): subtyping is
  reduced to emptiness of `A ∩ ¬B`. DNF insertion removes duplicate and
  subsumed clauses before they consume the fixed clause budget; Cartesian
  distribution, De Morgan conversion, empty-former identities, malformed AST
  arities, and depth/clause overflow all have executable invariant checks.
  Failed audits disable DNF-based proof queries, so the driver fails
  conservatively rather than trusting a broken normalizer.
- **Coinductive subtyping** (`theory_mu`, `theory_session`): memo table of
  pairs assumed true during the proof, plus depth budget, avoids infinite
  unfold on μ-types.
- **Duality** (`theory_session::sess_dual`): `!a.T ↔ ?a.dual(T)`, `+ ↔ &`,
  `μx ↔ μx.dual`, `end ↔ end`. Dual channels compose deadlock-free.
- **Size-change closure**: SCG compose→fixpoint; a program is SCT-terminating
  iff every idempotent SCG in the closure has a strict self-edge.
