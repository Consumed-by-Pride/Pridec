# theory/types — Type systems and subtyping

Implementations of type-system engines drawn from the literature.

| File                    | Paper / topic                                                                       |
|-------------------------|-------------------------------------------------------------------------------------|
| `theory_setops.c3`      | Type algebra core — DNF, union/intersection/negation nodes (Frisch/Castagna/Benzaken) |
| `theory_mu.c3`          | Recursive μ-types: shift/subst, contractivity, coinductive subtyping w/ memo        |
| `theory_subtype.c3`     | Semantic subtyping driver (Frisch/Castagna/Benzaken 2008 J.ACM)                     |
| `theory_subtype_full.c3`| Atom-level emptiness: FCB binary-arrow rule, record atoms, AST→TypeStore translation |
| `theory_records.c3`     | Record type lattice (Castagna et al. ICFP'23): width+depth subtyping, field inter.  |
| `theory_rowinfer.c3`    | Row types for effects/records — Wand/Rémy-style polymorphic rows                    |
| `theory_bidi.c3`        | Bidirectional typing (Pierce/Turner): check ↔ infer modes, modal box types          |
| `theory_stratified.c3`  | Kernel F<: bounded quantification (Cardelli/Mitchell/Pierce): refl/top/bot/fun/∀     |
| `theory_session.c3`     | Binary session types (Honda/Vasconcelos/Kubo; Gay & Hole): duality, coinductive sub.|
| `theory_sct.c3`         | Size-Change Termination (Lee/Jones/Ben-Amram POPL'01): SCG composition, idempotence |

## Central operations

- **Emptiness check** (`theory_subtype_full::is_empty`): a type T is empty iff
  its DNF has no satisfiable atom-clause. Arrow types use the FCB rule
  `(d→c) ∧ ¬(d'→c') ≃ ∅ ⇐ d' ≤ d ∧ c ≤ c'`.
- **Coinductive subtyping** (`theory_mu`, `theory_session`): memo table of
  pairs assumed true during the proof, plus depth budget, avoids infinite
  unfold on μ-types.
- **Duality** (`theory_session::sess_dual`): `!a.T ↔ ?a.dual(T)`, `+ ↔ &`,
  `μx ↔ μx.dual`, `end ↔ end`. Dual channels compose deadlock-free.
- **Size-change closure**: SCG compose→fixpoint; a program is SCT-terminating
  iff every idempotent SCG in the closure has a strict self-edge.
