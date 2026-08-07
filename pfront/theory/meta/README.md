# theory/meta — Meta-theory, binding structure, and normalization

Files in this directory deal with *variables*: how they are named (de Bruijn),
how substitutions propagate (hereditarily, through closures), how terms are
normalized (NbE, β-reduction), and how the meta-logical structure of contexts,
modal validity, and stage separation is enforced.

| File                  | Paper / topic                                                               |
|-----------------------|-----------------------------------------------------------------------------|
| `theory_term.c3`      | Hash-consed λ-term core; α-equivalence, sharing                            |
| `theory_cmtt.c3`      | Contextual Modal Type Theory judgments (Nanevski/Pfenning/Pientka TOCL'08)  |
| `theory_cmtt_meta.c3` | CMTT meta-variable contexts, simultaneous substitution stubs                |
| `theory_hered.c3`     | Hereditary substitution (Nanevski et al. §5.1): de Bruijn shift/subst, β-red|
| `theory_nbe.c3`       | Normalization by Evaluation; SKI combinator reducer demo                    |
| `theory_modal.c3`     | Modal validity / Kripke-style scoped registry for effect/type variables     |
| `theory_msp.c3`       | Multi-stage programming (Taha/Sheard): escape/run/quotation bracket levels  |
| `theory_stage.c3`     | Staging pass: `comptime` evaluation + partial specialization                |
| `theory_poly.c3`      | Polymorphism: instantiation census + unification of declared→actual types   |
| `theory_quals.c3`     | Type-qualifier inference (Foster/Terauchi/Aiken): const/pure/throws/owned/send/sync |

## Key concepts

- **Hereditary substitution** (`theory_hered.c3`): when substituting N for x
  in `(λy.M)`, you may produce a redex; hereditary substitution reduces it on
  the fly so that substitution always returns a normal-form term. Termination
  proof relies on a simple-type ordering.
- **CMTT contextual types** (`theory_cmtt.c3`): a term `u : [Ψ]T` is a meta-
  variable standing for a term of type T in context Ψ. The operation `[σ]N`
  (closure application) performs simultaneous substitution over meta-vars.
- **Staging** (`theory_msp.c3`, `theory_stage.c3`): bracket/escape/run
  annotations classify each term by its binding-time (0 = present, 1 = future).
  Cross-stage persistence keeps compile-time values live into later stages.
- **Qualifiers** (`theory_quals.c3`): each dimension (const/pure/throws/...) is
  a 3-point lattice (NO/MAYBE/YES). Function arguments propagate qualifiers
  via small built-in signatures.
