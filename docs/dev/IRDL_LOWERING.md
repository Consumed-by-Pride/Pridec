# IRDL dialect lowering (P03)

Status: implemented for a deliberately small, checked fragment. Anything outside
it is an **error**, never a placeholder value.

## What was wrong (audit, `docs/audits/theory-2026-10-01/REPORT.md`)

`DialectTable.add_lowering` had no caller. Dialects/opcodes were registered and
names validated, but no `irdl` rule was ever registered, so `D.add(20, 22)`
compiled and returned **0**. The `irdl` block itself was also mis-registered as
an unnamed dialect, and literal operand patterns (`[a, 0]`) and `_` did not parse.

## What happens now

`DialectTable.elaborate` (pfront/theory/lower/theory_irdl.c3) runs
register dialects → collect module top-level names → register `irdl` rules →
validate uses → lower to a fixpoint → refuse what is left. It is **mandatory
semantics**: `theory_check` calls it first, and the driver calls the same function
when the theory layer is off (`--no-theory`) or did not initialise. Lowered code
then flows through the optional analyses as ordinary source.

Rule form: `Dialect.op [pat, ...] ↦ template`. Operand patterns: a name, `_`, or an
integer/bool/char literal (matches only that literal at the use site). Rules are
tried in order; first match wins.

### Accepted templates
Names, literals, arithmetic, casts, field/index/tuple, and calls. Binding forms
(`let`, lambdas), control flow, allocation, IO, assignment are outside the fragment
because textual substitution could capture or duplicate effects.

### Diagnostics (codes in the conformance irdl family 3400-3499)
| code | meaning |
|---|---|
| E3412 | use of a declared opcode with no rule for these operands (no executable meaning) |
| E3413 | rule names an undeclared dialect/opcode, or a malformed head |
| E3414 | bad operand pattern, or an operand name bound twice |
| E3415 | template outside the substitutable fragment, or no `↦ action` |
| E3416 | operand count differs from the opcode's earlier rules / too many rules |
| E3417 | lowering would duplicate, drop or reorder an operand that may have effects |
| E3418 | lowering did not reach a fixpoint within fuel/depth |
| E3419 / W3419 | `emit_asm(...)` template: declarable (warning) but any use is an error; no native inline-asm lowering exists |
| E3420 | template names something that is neither an operand nor a top-level declaration of this module |
| E3421 | a template name is shadowed by a local binder in the using item (would capture) |
| E3422 | guards (`, cond`) and variadic operands (`..rest`) are not supported |
| E3210/E3211 | unknown opcode / wrong operand count at a use (pre-existing) |

Every rejection is an error, so the compile fails; a rejected rule can never cause a
later rule to fire silently in its place.

### Operand-effect guard
Substitution evaluates operands where the template mentions them. An operand is
*pure* if it is a name/literal/arithmetic over those. A non-pure operand (e.g. a
call) must be read **exactly once**, in source order, with no template call
completing before it; otherwise E3417. (Division traps are not modelled.)

## Limits (stated, not hidden)
- Operand type annotations (`a : i64`) are parsed and kept but **not checked**.
- Guards and variadic operands are unsupported (diagnosed).
- Template free names must be top-level declarations of the *same module*; prelude
  or imported functions are rejected (E3420). Dialects declared in another module
  are not seen.
- Name hygiene is flow-insensitive: any binder of that name anywhere in the item
  counts as shadowing.
- No native inline assembly: `emit_asm` templates are diagnosed, not compiled.
- Checked by a finite test set (`tests/harness/test_irdl_lowering.py`, O0-O3 x
  theory on/off), not proved.

## Fixture changes (honest record)
- `tests/pfront/32_irdl_dialect`: now expected to **fail** (exit 1, E3412): a dialect
  use with no rule used to compile silently to a placeholder. `32b_irdl_lowering`
  is the same dialect with a rule and expects exit 0.
- `tests/pfront/syntax/x10_graph_compiler.pie`: `add/mul/fma` rules now lower to
  arithmetic (they are used by functions in the file); `splat` keeps its
  `emit_asm` form but is never used. The file previously *claimed* an emit_asm
  lowering that never ran.
- Baselines raised, not lowered: pfront 172/5 → 173/5; conformance 150/112 →
  151/111 (`76_irdl_multirule` now clean). `examples/irdl_showcase.pie` error floor
  7 → 3 (guard + variadic + the use that depends on them).
