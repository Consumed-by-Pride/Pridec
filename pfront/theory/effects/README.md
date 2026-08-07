# theory/effects — Effects, handlers, continuations, resources

Algebraic effects and handlers (Plotkin/Power, Kammar et al.), delimited
continuations, CPS conversion, explicit UB tracking, and linear/affine
resource accounting.

| File                    | Paper / topic                                                                  |
|-------------------------|--------------------------------------------------------------------------------|
| `theory_effects.c3`     | Algebraic effects: row-based effect inference and handler coverage             |
| `theory_effcont.c3`     | Delimited continuations (prompt/control): ContTree normalisation, functorial   |
| `theory_effects_full.c3`| Deep vs shallow handlers (Kammar/Lindley/Oury): resume/forward/abort counts     |
| `theory_cps.c3`         | CPS counting + administrative-redex avoidance; contification candidates        |
| `theory_ub.c3`          | Explicit-UB 3-point lattice (def → poison → ub): freeze, div0, branch-on-poison|
| `theory_linearity.c3`   | Linear/affine use counting: move heuristics, double-use / use-after-move       |

## Central ideas

- **Handlers** (`theory_effects_full.c3`): deep handlers reinstall themselves
  in the continuation; shallow handlers do not. `forward` relays to an outer
  handler; `abort` discards the continuation. Counts of these are tracked per
  handler arm.
- **CPS counting** (`theory_cps.c3`): every call is classified tail/non-tail;
  candidate contification sites (callee is a direct lambda) are flagged so the
  middle-end can replace a jump through a closure with a direct block transfer.
- **UB lattice** (`theory_ub.c3`): expressions are tagged UB_DEF (known defined),
  UB_POISON (undef or from-poison), or UB_UB (real undefined behavior). Branching
  on poison or dereferencing poison promotes to UB.
- **Linearity** (`theory_linearity.c3`): each scope tracks UseCount; functions
  with `free_`, `close_`, `drop_`, `move_`, `take_` prefixes are treated as
  affine sinks for their receiver.
