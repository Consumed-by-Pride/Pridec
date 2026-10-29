# PEAR 2 codata semantics — struct-as-codata slice and the object gate

Codata declarations are coinductive *interfaces*: a codata value is known only
by what you can destruct from it. This document fixes how much of that reaches
the backend today, how the surface `struct` form maps onto it, and which codata
forms are deliberately rejected with positioned diagnostics until a real
object/closure semantics is decided. It is the semantic contract that the
codata record slice in `pear2/pear2c_main.c3` implements and that
`tests/pear2/run.sh` pins.

## 1. The slice that exists today (the floor)

A **plain nullary-dtor codata declaration** is accepted and lowered as a
product record, ABI-identical to a single-constructor `data` record:

```
codata Vec2 {
  op x() : i64;
  op y() : i64;
};
```

Accepted iff every destructor is nullary (`op name() : ty`) — exactly the
record field shape. This is what pfront emits for a surface `struct`
declaration (`decl_struct` → `ADECL_CODATA` with one nullary destructor per
field, in field order; `#i` indices are by declaration order).

- Values are LLVM struct aggregates `{field...}` in declaration order, passed
  and returned **by value** across internal calls, same as `data` records.
- Type emission (`emit_data_types`) spans DATA and CODATA record decls;
  duplicate names fail closed.

### 1.1 Construction: the `_f0` marker idiom and explicit ascription

pfront represents `Vec2{x = a, y = b}` as:

```
record{_f0 = Vec2, x = a, y = b}
```

- `_f0 = T` is the pfront **owner marker**: the producer resolves the record
  declaration from the marker, types the aggregate as `nominal T`, and the
  marker itself contributes no storage.
- The same producer accepts the explicit ascription form
  `record{x = y0, y = x0} : nominal Vec2` (e.g. hand-written AIR, or forms
  where the owner is already known).
- Field initializers must match the declaration positionally/by name with
  value-compatible types; the count must equal the declared field count.

### 1.2 Projection: `field name #i` and `infer` parameters

pfront erases struct parameter annotations to `: infer`, so the canonical
projection shape is:

```
<v | field x #0 · comu x0. ...>
```

Resolution discipline (both at consume time and at return-type inference):

1. If the projected value has a nominal ascription, the owner is that nominal
   (a record declaration is required).
2. Otherwise (the erased `infer` case) the owner is resolved by declaration:
   exactly one record declaration (single-constructor DATA or plain CODATA)
   with field `name` at index `#i` must exist. Zero matches reject; two or
   more distinct declarations reject with
   `ambiguous record field projection: more than one record declares this
   field at this index; ascribe the owner type` — positioned at the
   projection.
3. Function-return inference walks projection chains
   (`field`/`proj`/`fst`/`snd`/ascription/`comu` binds) to the covariable
   return so a function whose last act is returning a projected or rebuilt
   record infers `nominal T`, not the integer default.

To keep signatures sound, a module pre-pass
(`m1_infer_record_params_walk`, run right after `air_facts::validate_module`)
walks every definition: a direct `cut(<var | field name #i · ...>)` on an
`infer`/unannotated parameter pins that parameter to the unique record
declaration matching `(name, idx)`. No match leaves the parameter untouched
(fails later, positioned, at the projection); an ambiguous match leaves it
`infer` so the projection itself rejects — inference never picks a type the
rest of the pipeline would not accept.

### 1.3 Interop

Codatat records participate in the same external C ABI as `data` records
(layout identical), and globals/constants of codata-record type follow the
record rules (`emit_constant`, `record_global_cells`, pattern binding).

## 2. Rejected forms — the object gate

Everything beyond the nullary-projection shape is a true object (a codata
value whose destructor carries hidden state — i.e. a closure). No closure
encoding for codata has been decided, so these fail closed at validation with
a source position rather than being miscompiled:

- **Parameterized destructors** (`op next(x : i64) : state`) — a method table
  needs a decided representation (records-of-closures vs defunctionalization),
  plus boxing decisions for recursive types.
- **Type parameters, multiplicities, and attributes on codata declarations.**
- **`cocase`/`cometa` construction forms** — defining a codata value by
  copattern matching is definitionally closure construction and waits on the
  same encoding decision.
- **`comu`-mediated codata self-application / co-recursive observation**
  whose typing would require the erased owner information we do not keep.

Diagnostic, positioned at the declaration:

```
unsupported codata declaration `Counter`: PEAR2 lowers codata whose
destructors are all nullary projections as product records; parameterized
destructors (methods), type parameters, multiplicities, and attributes fail
closed
```

AIR 3.0 (low profile) rejects codata entirely — unchanged; lifting that is
the same object-semantics decision, not this slice.

## 3. What a later M4+ object tier would be buying

If codata beyond projections is ever wanted, the missing decisions are (a) the
closure representation for parameterized destructors, (b) how codata values
with hidden state cross the aggregate ABI, (c) whether `cocase` builds stack
or heap objects, and (d) how co-termination/observation depth is checked.
None of these are needed for the struct slice; do not re-open them inside
record work.

## 4. Pinned surface

- `tests/pear2/codata_struct_main.air` — construct (marker + ascription),
  project through `infer` params, pass/return by value across `make`/`flip`/
  `dot`; exit 42 at -O0..-O3.
- `tests/pear2/reject_codata_method_main.air` — parameterized destructor
  positioned reject.
- `tests/pear2/reject_codata_ambiguous_main.air` — ambiguous owner
  positioned reject.
- Real-file target `tests/exec/12_struct_ops.pie` passes validation and lowers
  structs end-to-end; its remaining blocker is the pfront stdlib body of
  `print_i64_nl` (pointer/allocation substrate), an orthogonal gap tracked
  on the roadmap — not codata semantics.
