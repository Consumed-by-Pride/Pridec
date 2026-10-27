# PEAR 2 — what is still missing

An inventory of the AIR forms PEAR 2 refuses to lower and the optimizations it
does not perform, with the evidence for each. It exists so that "PEAR 2 does not
support X" is a fact with a location rather than a guess, and so the next piece
of work can be picked by impact instead of by whatever is nearest.

Scope note: this is about `pear2/pear2c_main.c3` and `pear2/pear2_opt.c3`. The
front end, the AIR reader/verifier, and `airtool` are separate.

Each item is tagged with a rough size: **S** (a focused change, one file),
**M** (needs a new analysis or a new lowering table), **L** (needs a design
decision or a new IR shape).

---

## 1. Lowering — AIR forms that fail closed

Every one of these produces a positioned diagnostic and exit 3 rather than a
guess, which is the correct default; the point of the list is that the set is
larger than the language implies.

| form | what happens today | why it is hard | size |
|---|---|---|---|
| `letrec` — local recursive bindings | rejected outright (`m1_contains_letrec`, `unsupported AIR construct 'letrec' in function ...`) | a non-capturing recursive lambda can be lifted to an `internal` function like any other lambda; a capturing one needs a self-referential environment slot, which the current closure conversion does not build | M |
| AIR 3 dynamic pointer offsets | `dynamic pointer offsets are unsupported without a static provenance bound` | the typed-memory slice tracks provenance, and an unprovable index has no tracked base; the honest fix is a bounds model, not a lowering tweak | L |
| constructor payload layouts outside the supported sum slice | `unsupported constructor payload layout`, `unsupported or ambiguous constructor value` | the payload packing rules are fixed by the supported slice; general layout needs the AIR-side layout contract finished first | M |
| record GEP layouts with padding the backend does not model | `unsupported GEP field layout`, `unsupported GEP record layout` | needs the record layout to be authoritative rather than recomputed | M |
| unusual `alloca` shapes (oversized or non-statically-sized) | `unsupported alloca type/size` | bounded allocation is a deliberate guard (1 MiB, static) | S |
| globals with non-constant initialisers | `unsupported global initializer` | would need a static initialiser graph and an init function | M |
| effect declarations whose operations are not `name + lowerable payload` | `unsupported effect declaration` | effects currently lower only in the supported handler shapes | L |
| declaration attributes beyond the seven handled | `unsupported function attribute (supported: callconv, noinline, alwaysinline, cold, naked, section, export)` | each new attribute needs a meaning, not just a spelling | S each |
| generic / packed / attributed records, signatures the emitter cannot type | `unsupported signature for function`, `unsupported data form in declaration` | representation inference for generics is unstarted | L |
| external aggregates that are not C-compatible | `unsupported external aggregate form in definition` | by design: the C ABI subset is conservative | S |
| `atomic` on pointer, float, bool, or 128-bit pointees | `atomic pointee must be an 8/16/32/64-bit integer` | AIR3.md restricts atomics to integer pointees ≤ 64 bits, so this is spec-aligned, not a backend shortcut | — |
| `asm` with bool or aggregate operands | `asm operands must be typed integers, floats, or pointers` | the template/constraint form cannot express an aggregate register class | M |
| `syscall` with float or aggregate arguments | `syscall arguments must be integers, bools, or pointers` | the register ABI carries words; floats would need a documented bit-pattern convention | S |
| `--target=wasm32-freestanding` producing object/binary | rejected: IR or bitcode only | needs a wasm linker path and a runtime | L |

Not a gap, worth stating because it looks like one: `relaxed` fences and
`release`/`acq_rel` atomic loads are rejected by the *AIR verifier*, not by
PEAR 2, because those orderings have no C11 meaning.

## 2. Optimizer — what the AIR level does not do

`pear2_opt` is two passes: a bottom-up, expression-local rewrite (pass 1) and a
lexical dead-binding sweep (pass 2). Everything that needs a control-flow graph
is simply absent.

| absent | consequence | size |
|---|---|---|
| any CFG or dominance analysis | no constant propagation across branches, no loop-invariant motion, no dead-branch elimination on non-literal conditions, no SSA construction at the AIR level | L |
| common-subexpression elimination / GVN | pass 3 removes repeats only where both values are pure *and* the first is bound by an enclosing `let` in the same chain; anything across control flow, or involving memory, is still re-emitted and left to LLVM's GVN | M |
| inlining | AIR has no cost model and no call graph; LLVM inlines after lowering, which is cheaper and better informed | M |
| tail-call marking | calls in return position are emitted as plain `call`, with no `tail`/`musttail` marker. Self-recursion is handled anyway, because `default<O2>`/`default<O3>` include `tailcallelim`; what is left on the table is *mutual* recursion, which no LLVM pass can turn into a loop and which the backend has to hope x86-64's frame reuse notices | S |
| copy propagation | deliberately excluded: mutable locals are allocas, so `let x = y` snapshots a load, and renaming uses would observe later writes. Also worthless here, because the emitter binds names to SSA values, so an alias costs no instructions | — |
| alias / memory-dependence analysis | ordering of loads and stores is left entirely to LLVM | L |
| optimizer statistics from the LLVM layer | `--stats` reports AIR counters only, so the effect of `default<On>` is invisible | S |

`Arithmetic is emitted without nsw/nuw` (see `IMPLEMENTATION_PLAN.md`): the
integer contract does not yet say which AIR operations are unchecked, so the
flags cannot be attached soundly. That blocks a set of downstream comparisons,
range reasoning, and loop idioms.

## 3. Verification

- No execution, differential, or fuzzing gate can run in the sandbox this work
  was written in (no `c3c`, no `libLLVM-23`, no `clang`), so every change in the
  current branch is review-only until `make pear2c` runs somewhere real.
- `tests/exec/DIFF_BASELINE.csv` was recorded against the backend *before*
  in-process codegen and the LLVM IR passes. Semantics should not have moved,
  but a verdict change fails the gate by design; re-bless deliberately with
  `scripts/pie-diff.sh --bless`.
- There is no translation-validation or randomized differential test between the
  AIR optimizer's output and its input. The re-verification after optimization
  catches structural damage, not semantic damage.

## 4. Closed recently

- **`atomic cmpxchg`** now lowers. AIR carries one ORDER; the backend uses it as
  the success ordering and weakens it to the strongest legal failure ordering
  (release/acq_rel degrade to monotonic/acquire), which is the same mapping the
  AIR 3 reference consumer applies. The result is the old value, per AIR3.md.
  Fixture: `tests/pear2/atomic_cmpxchg_main.air`, executed at `-O0..-O3`.
- **`syscall` bool arguments** now lower as a `zext i1 -> i64`, the same way C
  passes a `_Bool` in a register.
- **Whole-body propagation (pass 3, `-O3` only)**: a name census over the
  entire function body replaces a literal at every use — not just the immediate
  initializer pass 1 reaches — and removes a binding whose initializer is pure
  rather than inert. That is also what makes `-O3` a different *set* of passes
  instead of the `-O2` set repeated more often, which was the last row this
  table had under "tier differentiation".
- **Linkage**: a non-`pub`, non-`extern` definition or global that is not an
  entry point and carries no `export`/`section` attribute is emitted
  `internal`, so LLVM can inline it and delete it when unused. On by default
  for `--emit-exe` (PEAR 2 owns that link), selectable elsewhere with
  `--internalize`/`--no-internalize`. Fixture:
  `tests/pear2/linkage_internal_main.air`, which also pins that `main` and
  `#export`ed symbols stay external.
- **Dead-binding elimination** (pass 2), **tiered AIR passes**, **in-process
  LLVM IR optimization**, **in-process object emission**, and the **`ld` link**
  are described in `IMPLEMENTATION_PLAN.md` M5.

## 5. Suggested order

1. **Tail-call marking** — small, and it is the only way to make mutual
   recursion (never self-recursion, which `tailcallelim` already covers) reuse
   frames, because marking requires knowing a call is in return position.
2. **`nsw`/`nuw` after the integer contract is written down** — unlocks more
   downstream reasoning than any single pass here.
3. **`letrec` for non-capturing recursive bindings** — the largest *language*
   gap that does not require a new design.
4. **CSE / constant propagation across branches** — the let-chain case is
   done in pass 3; what remains needs a CFG: merging equal values along
   two arms of a join, and hoisting a value out of a loop. Only worth doing
   with a differential test to prove it.
5. **Loop unrolling / rotation** — a `for` iterates an array value, so the
   literal-bounded shape an unroller wants is not what AIR carries today;
   this needs either a range producer in AIR or a bounds proof through the
   `for` lowering.

Anything in §1 marked **L** needs a design note before code; they are not
backlog items, they are open questions.
