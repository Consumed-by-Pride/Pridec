# C3 as a transpilation target

Why PEAR emits C3 instead of C or C++, what "the middle layers" means concretely,
where the emitter sits in the tree, and the exact form-for-form mapping from the
AIR 3.0 low profile to C3 text.

This is a **design and mapping** document. It describes a fourth consumer of AIR,
next to `air_ll` (LLVM text), `pear2_cfg` (PIR → x86-64), and the wasm path. C3 is
the **output language** here; the fact that this repository's compiler is itself
written in C3 is a coincidence of implementation, not part of the argument. Nothing
in this document asks anyone to write software *in* C3 by hand.

**Status: designed, not implemented.** No emitter has been written or built yet. The
mapping below is derived from, and checked against, the two files that actually
define the interface: `docs/specs/AIR3.md` (what a producer guarantees) and
`pfront/pear_ir/air_ll.c3` (the only complete consumer, 1,211 lines). Where this
document says "refuse", it means the C3 emitter must report a diagnostic and stop,
exactly as `air_ll` does — never approximate.

---

## 1. Why C3 over C or C++

Five reasons, in the order that they actually matter for a transpiler.

**1. No `goto` is a feature, not a bug.** This is the one place where C3 is *worse*
for us, and it is worth stating first because it is the largest single piece of work.
C3 removed `goto`; it has labelled `break`/`continue`, `defer`, `nextcase <expr>`,
and `@jump` switch tables. AIR 3.0 is a control-flow graph with label-parameter
(phi) joins. In C, a CFG is emitted with one label and one `goto` per block, and the
job is finished in an afternoon. In C3 the same CFG must be recovered as structured
control flow. We have already solved this problem once, in this repository, and the
solution is reusable — see §3.

**2. The output is readable, and that is a correctness property.** A C3 program that
a person can read is a program that can be diffed against the source `.pie` file when
the compiler is wrong. C output with `goto` spaghetti, `union`-of-everything slots,
and hand-rolled unwinding is not reviewable. For a compiler under active repair,
"the emitted text explains itself" is worth more than any single optimisation.

**3. Modules and namespacing, not the preprocessor.** A C target forces every AIR
symbol into one flat global namespace and every emitted file to fight over `#define`
prefixes. C3 has real modules (`module pear_out::f;`), so a `.pie` module maps to a
C3 module and there is no name mangling scheme to design, document, and get wrong.

**4. Typed declarations with real integers.** C3 has `ichar/char/short/int/long/
int128` and `ichar`-style sized types in the stdlib, `usz`/`isz`, and — decisively —
`int[<N>]` slices and arrays as first-class types with `len`. AIR 3.0 spells
`i8…i64`, `u8…u64`, `usz`, `isz`, `bool`, `char`, `ptr(T)`, `T[n]`, tuples. C3 spells
those same distinctions directly. C needs `typedef`s and a partner header to keep
`u8` and `i8` distinct across a translation unit boundary.

**5. Macros that are functions.** The requested advantage, stated precisely: C3's
`macro` is a typed, hygienic, compile-time function that can take a *type* parameter.
That is the natural way to emit `alloca(T)`, `load(p)`, `gep[T]`, and
`record(...)` — a small number of typed macros plus ordinary functions — where a C
target needs either duplicated generated code per type or `void*` and casts that
throw away exactly the type information the AIR low profile went to the trouble of
computing.

**Why not C++:** exceptions and RTTI are unwanted in a compiler's own output (the
emitter must be able to say `-fno-exceptions` and mean it), templates instantiate at
a call site that the emitter would have to predict, name mangling is unspecified
across compilers, and the compile time for generated code is materially worse. C++
would buy us `std::variant` and structured bindings; C3's `match` and its variant
support buy the same thing without the rest.

**Why not plain C:** everything in 1–5, and one more — see §4. A C target would be
*tempting* to write CFG-shaped, which would hide the structured-control-flow work
behind `goto` and leave the artifact every person reads unreviewable.

---

## 2. "The middle layers", concretely

The request was AIR → middle layers → C3, not one opaque AIR → text pass. The
existing tree already has the pieces, and naming them fixes the seam:

| layer | file | representation | how it is built |
|---|---|---|---|
| front end | `pfront/*.c3` | AST | parses `.pie` |
| AIR 2.2 | `pfront/pear_ir/air_emit.c3` | `AirModule`, untyped | `--emit-air` |
| AIR 3.0 low | `pfront/pear_ir/air_low.c3` | `AirModule`, typed, explicit memory | `--emit-air-low` |
| **PIR** | `pear2/pear2_cfg.c3` | CFG of three-address instructions + frame slots | `pear2_cfg` |
| LLVM text | `pfront/pear_ir/air_ll.c3` | `.ll` text | `airtool emit-ll` |
| x86-64 | `pear2/pear2_x64.c3` | machine code | `--emit-native` |

Two candidate seams, and the difference is not cosmetic:

**Seam A — AIR 3.0 → C3** (`AirModule` → C3 text). Reads the typed module directly.

**Seam B — AIR 3.0 → PIR → C3.** Routes through the middle representation.

**Decision: A for the first emitter, with PIR's structuring algorithm reused as a
library, and B as the stated follow-on.** The reason is PIR's actual coverage,
measured today:

```
struct PInst { ... }                  // 18 ops: const copy add sub mul divs divu
                                      // rems remu and or xor shl shr sar neg not
                                      // cmp cmpi load store slotaddr call jmp br ret
struct PFunc { ... PParam[16] params; int param_count; int ret_width; ... }
```

PIR is **integer-scalar only**. It has no float type, no line for `ATYP_F64` to map
to, and `ret_width`/`width` are bit-counts. It has no aggregates (no `PRD_TUPLE`,
`PRD_RECORD`, `PRD_ARRAY`), no pointers in the C sense — only 8-byte frame *slot
indices* — and it caps calls at 6 arguments (`int[6] args`). It is an excellent
x86-64 target and the wrong shape for a C3 target, which inherits a real type system
and can express `f64`, structs, and 200-field records.

Had we chosen B first, the C3 backend would have inherited scalar-only coverage and
the 30-wide aggregates in `tests/air3/prog/ag01_wide_struct.pie`, `ag02_nested_wide_aggregates.pie`,
`ar02_array_by_value_200.pie` would have failed for a reason belonging to a different
backend. That is the "silently narrower than the last one" failure this repository has
been fixing all week.

**What we take from PIR anyway** is its most valuable paragraph, quoted because it is
the whole structuring strategy:

> Why slots rather than phis, stated plainly: AIR is CPS-shaped. A mutable local is a
> label parameter, a `jump` passes it, and a `while` re-enters its header. Modelling
> that as a parallel copy into a block parameter is exactly a phi, but getting
> dominance right for every construct — labels that appear after their jumps,
> `break`/`continue` out of nested loops, MATCH arms that each return — is the kind of
> work that produces subtly wrong code. A slot is always correct, costs one store and
> one load, and can be promoted away by a later pass that has the dominance
> information PIR records.

The C3 emitter adopts the same answer for the same reason (§3.3).

**Later, if C3-targeted optimisation is wanted**, seam B becomes attractive for a
different reason: PIR is where passes live that LLVM cannot host, and a C3 emitter
sitting on PIR inherits them. That is a performance story, not a correctness one, and
it should be built on a first emitter that is known-correct.

---

## 3. The hard part: a CFG becomes structured control flow

### 3.1 What AIR 3.0 actually gives you

From `docs/specs/AIR3.md`:

> control flow is `label`-spine blocks with `jump` arguments (phis), `if`, `match` on
> int/bool/char, `ret`, `trap`, `ub`, `cut`

and `air_ll.c3`'s `Ll.function` shows the shape of a def body:

```
seq { label A. c ; seq { label B. c ; entry } }
```

Labels are on the spine of the body. Only 15 of the 34 command tags reach the low
profile at all; `air_ll.c3:217` refuses the rest with `default: l.err("command is not
part of the low profile")`. The ones a C3 emitter must handle:

```
NOP LET SEQ STORE FENCE RET TRAP UB JUMP IF MATCH CUT SYSCALL ATOMIC ASM
```

Note what is **absent** from that list: `WHILE`, `FOR`, `BREAK`, `CONTINUE`, `LABEL`
(handled structurally by `Ll.function`, not by `Ll.cmd`), and every effect command.
`air_low` has already lowered loops to label/jump form and effects to ordinary code.
**A C3 emitter never has to lower a `while`, a closure, or a `handle`** — that work
happens upstream. This is the single biggest reason the job is tractable.

### 3.2 The problem in one sentence

AIR's `jump` passes arguments to a label's parameters; C3 has no `goto`, no labels to
jump to, and no phi. Two `jump`s reaching one label with different values must become
either a variable written on both paths (a slot) or a structured construct that makes
the join implicit.

### 3.3 The decision: slots, and one decision per function

**Phase 1 — every label parameter becomes a C3 variable declared at the top of the
function.** A `jump L(a, b)` becomes two assignments, then the transfer of control.
This is PIR's argument applied to C3 and it is always correct. It costs one variable
per label parameter and, for a loop header, one assignment per iteration. The
declarations are hoisted rather than written at the label, because a `case` body in
C3 does not share scope with the next one and a phi written on one path is read on
another.

**Phase 2 — one classification per function, not per label.** The emitter scans the
whole function before printing anything and asks two questions:

```
any label with a back edge        -> the function is DRIVEN
any label with more than one in-edge, or none  -> the function is DRIVEN
otherwise                          -> the function is a STRAIGHT SPINE
```

A **straight spine** is printed as straight-line C3: each label's statements in
order, parameters declared at the top, and a `jump` to the next label printed as
nothing at all (the printer is already there). This is the common case, and it
produces text a person can read against the `.pie`.

Anything else is **driven**: the whole function becomes

```c3
sz __pc = 0;
while (true) {
    switch (__pc) {
        case 0: /* label A */ ... ; __pc = 1; nextcase;
        case 1: /* label B */ ...
        default: return;
    }
}
```

`nextcase <expr>` selects a case by run-time value — which is an indirect jump, and
it is the one C3 construct that makes this encoding possible at all.

**Why all-or-nothing rather than per-label structuring.** The obvious refinement is
to recognise an if/else chain or a `while` on a per-label basis and print only the
awkward remainder as a dispatch. That is a relooper, and getting dominance right for
every pairing of constructs is exactly the class of work that PIR's header warns
"produces subtly wrong code". Splitting a function into a structured half and a
driven half is *also* where the interesting bugs live: a `jump` out of the structured
part into the driven part has to materialise the same variable writes on both sides.

The first emitter therefore does the simple, provably-correct thing and **counts what
it costs**: every driven function is reported (`air-c3: N function(s) used the __pc
dispatch loop (target: 0)`). A count is a specification. If the number is not zero on
real programs, per-label structuring is the next task, and there will be a number to
show for it rather than an opinion.

**This is a deliberate narrowing, and it is honest about one thing:** the emitter
`air_ll` produces today emits every function as a label spine, and `air_low` is
expected to leave very few functions with a join. That expectation has not been
measured, because there is no producer here. When the fixtures exist, the first
number to look at is that count.

### 3.4 What we explicitly refuse

An `alloca` inside a loop body, where the pointer outlives the iteration, has a
lifetime AIR leaves implicit. C3's `defer` and block scoping make the correct answer
obvious in the common case and ambiguous in this one. **Refuse** with a diagnostic
naming the function and the `alloca`, rather than emit a program whose stack grows
per iteration. `air_ll` accepts these because LLVM's `alloca` semantics are defined;
C3's are not the same, and pretending otherwise would be the exact class of bug this
repository spent the week removing.

---

## 4. The mapping table

Every row is one form the low profile admits. "C3" is the exact text the emitter
prints, with `T` a C3 type, `$n` a fresh temporary, and `p`/`v` already-printed
operands. This table is the contract; the emitter is written from it and the tests
assert against it.

### 4.1 Types (`ATYP_*` → C3)

| AIR 3.0 | C3 | notes |
|---|---|---|
| `i8` `i16` `i32` `i64` | `ichar` `short` `int` `long` | C3 `ichar` is 8-bit signed; `short`/`int`/`long` are 16/32/64 signed. All four are keywords in v0.8.4 |
| `u8` `u16` `u32` `u64` | `char` `ushort` `uint` `ulong` | C3 `char` is 8-bit *unsigned* — the reverse of C's trap |
| `usz` `isz` | `usz` `sz` | pointer-width. **`isz` is not a C3 keyword in v0.8.4 — `sz` is the signed pointer-width type** (checked against `src/compiler/tokens.c` at the tag the Makefile pins) |
| `f32` `f64` | `float` `double` | |
| `bool` | `bool` | |
| `char` (AIR) | `uint` | **watch this row.** `air_util::ty_is_int` counts `ATYP_CHAR` as an integer and `air_ll` prints it `i32` — a *code point*, not a byte. Emitting C3's `char` (8-bit unsigned) would silently truncate. Emit `uint`. |
| `unit` | `void` in return position; a 0-field struct `struct __unit {}` as a value | a unit *value* never appears in the low profile except as an `insertvalue` part |
| `ptr(T)` | `T*` | C3 declarator syntax is C's: `int*`, `int**` |
| `T[n]` | `T[n]` | fixed array; C3 has `T[N]` as a real type |
| `{T, U}` (tuple) | `struct __tup_N { T _0; U _1; }` | generated, one per distinct shape |
| `%"Name"` (nominal, single ctor) | `struct Name { ... }` | `data` with exactly one constructor is a struct; more than one is refused by `air_ll` too |
| `arrow` / `fn` | `fn R(P*)` function pointer type, or the closure record `Fn.<sig>` | AIR 3.0 closures are `{fn: arrow, env: ptr(u8)}`; see 4.6 |

**Nominal types with more than one constructor are refused**, matching `air_ll`:
`"data with several constructors (enum layout) is not part of this profile yet"`. C3
has `fault`-based discriminated unions, but mapping AIR's variant layout onto C3's is
a separate design and must not be guessed at here.

Every C3 keyword and type name in this table was checked against
`src/compiler/tokens.c` **at `v0.8.4`**, the tag the Makefile pins (`C3C_VER := v0.8.4`),
not against the language as of today. Three of them would have been wrong had they
been written from memory or from the current docs: `sz` (not `isz`) is the signed
pointer-width type, `tlocal` (not `tls`) is thread-local storage, and `i128`/`int128`
is not available. This is worth stating because the emitter is written blind — there
is no `c3c` in the environment that can contradict it.

### 4.2 Producers (`APRD_*` → C3)

`air_ll` handles 19 of the 33 producer tags. The same 19, plus what each prints:

| AIR 3.0 | C3 |
|---|---|
| `APRD_VAR` (local) | `name` |
| `APRD_VAR` (global) | `pear_out::name` — C3 qualifies with `::`, not `.` |
| `APRD_INT` | `123` — **with the C3 suffix of its AIR type** (`123i8`, `123u64`); an unsuffixed literal is `int` and silently narrows |
| `APRD_FLOAT` | `1.5` for `f64`; `1.5f` for `f32`; `0x<16 hex>` bit-pattern form only where a value is unrepresentable |
| `APRD_BOOL` | `true` / `false` |
| `APRD_CHAR` | the quoted `'x'` where printable, else `(uint)0x<hex>` |
| `APRD_UNIT` | nothing; the surrounding form is elided |
| `APRD_NULL` | `null` |
| `APRD_STRING` | a `const char[] __s<N> = "…";` at module scope; the operand is `__s<N>` |
| `APRD_BYTES` | the same, emitted as a byte array with explicit length |
| `APRD_ALLOCA` | `T $n;` and the operand is `&$n` — see 3.4 for the loop refusal |
| `APRD_LOAD` | `*p` (`volatile` when `p.bval`: `volatile_load` from `std::atomic` — see 4.4) |
| `APRD_GEP` | `&p[i]` / `&p.field` / `&p._1`, decided by the same type walk `air_ll`'s `Ll.gep` does |
| `APRD_BINOP` | the infix operator; `land`/`lor` are **already** lowered to `and`/`or` on `i1` by `air_low`, so C3 sees `&&`/`\|\|` only where AIR says so |
| `APRD_UNOP` | `-a`, `!a`, `~a` |
| `APRD_COERCE` | a C3 cast `(T)a`, or nothing when `air_ll` prints nothing (same width, different signedness) |
| `APRD_TUPLE` / `APRD_RECORD` / `APRD_ARRAY` | a struct literal `Name { .f = v, }`; arrays as `{ v0, v1, }` |
| `APRD_SIZEOF` | `(usz)T.sizeof` — a constant, not the gep-null idiom |

**Every other producer is refused**: `APRD_INL`, `APRD_INR`, `APRD_LAMBDA`,
`APRD_MU`, `APRD_COMETA`, `APRD_REIFY`, `APRD_EVAL`, `APRD_QUOTE`, `APRD_SPLICE`,
`APRD_POISON`, `APRD_UNREACHABLE_VAL`, `APRD_ALIGNOF`, `APRD_OFFSETOF`. These are
outside the low profile; `air_low` has already evaluated or lowered them, so seeing
one is a producer bug and must be reported as such — not approximated.

### 4.3 Commands (`ACMD_*` → C3)

| AIR 3.0 | C3 |
|---|---|
| `NOP` | nothing |
| `LET x = p` | `T x = <p>;` (block-scoped; a `let` whose binder crosses a block boundary was already promoted to a label parameter by `air_low`) |
| `SEQ c; rest` | the statements, in order |
| `STORE(p, v)` | `*p = v;` |
| `FENCE order` | `@fence(order)` / `std::atomic::fence` |
| `RET p` | `return p;` |
| `TRAP` | `unreachable("")` — traps, does not return |
| `UB` | `unreachable("")` |
| `JUMP L(a,b)` | assignments to `L`'s parameter variables, then the control transfer for the structured shape (§3.3) |
| `IF prd then else` | `if (cond) { … } else { … }` |
| `MATCH prd branches` | `switch (scrutinee) { case <pat>: … }` on int/bool/char; a non-literal pattern is refused |
| `CUT` | `break` / `return` depending on the enclosing construct, decided by the matcher |
| `SYSCALL` | `asm` block with the platform's convention, or a call to `__pride_syscall` — see 4.4 |
| `ATOMIC op order(p, v…)` | `std::atomic::load/store/fetch_add/cmpxchg` with the ordering |
| `ASM text cons : T (operands)` | C3 `asm { "…" }` with `%N` → `$N` translated, exactly as `air_low` already does for the GCC form |
| `STORE volatile` | `std::atomic::load/store` volatile variants |

`WHILE`, `FOR`, `MATCH` with guards, `HANDLE`, `PERFORM`, `RESUME`, `DEFER`, `BREAK`,
`CONTINUE`, `LABEL`, `LETREC`, `BLOCK`, `UNSAFE`, `COMPTIME`, `ASSERT`, `ASSUME`,
`MU`, `MUTILDE` — refused, because they cannot reach the low profile. Both the
emitter and `air_ll` must agree on that list, and the test in §6 asserts they do.

### 4.4 The generated runtime

Three things C3 cannot express in the AIR vocabulary, so the emitter emits a small
header of its own, and this is where macros earn their place:

```c3
module pear_out;
// alloca(T) -> a real local; load/store/gep -> operator forms. Typed, so none of
// the AIR type information is lost at the boundary.
macro load(ptr) { ... }
macro store(ptr, val) { ... }
```

The syscall and atomic paths are emitted against `std::atomic` and the platform's
inline-asm convention. Every emitted file starts with a one-line provenance comment
naming the source `.pie`, the AIR profile version, and this document, so a C3 file
found on disk can be traced back.

### 4.5 Globals, declarations, attributes

| AIR 3.0 | C3 |
|---|---|
| `global NAME : T = c` | `T NAME = <c>;` at module scope |
| `global mut NAME : T` | `T NAME;` (C3 globals are mutable; a `const` AIR global maps to a C3 `const` initialiser) |
| `declare f(..) : R` | `extern fn R f(..);` |
| `attr section "x"` | `@section("x")` |
| `attr align N` | `@align(N)` |
| `attr packed` | `@packed` on the struct |
| `attr thread_local` | `tlocal T NAME;` — the keyword is `tlocal`, not `tls` |
| `attr noreturn` / `inline` / `noinline` / `cold` | `@noreturn` / `@inline` / `@noinline` / a comment (C3 has no `cold`) |
| `attr naked` | `@naked` |

Attributes C3 has no equivalent for (`noredzone`, `no_builtins`) are **emitted as a
leading comment** naming them, never dropped silently — a dropped `noredzone` is a
correctness bug on kernel code, and a comment is the honest record.

### 4.6 Closures and effects

These are already lowered by `air_low` into ordinary records, `alloca`s, `load`s,
`store`s, `gep`s, and calls — the closure record `{fn, env}` and the effect cell
`hop.E.op` plus `Frame.N` and `@__unw` are *data*, not new forms. A C3 emitter
therefore receives them as the forms in 4.2–4.3 and needs no special case. That is
the strongest argument for the AIR 3.0 seam: the two hardest source-level features
are already gone by the time we see the module.

The one form that is not ordinary data is the **fiber-based non-tail resume**, which
`air_low` lowers through `__pride_fiber_yield`/`__pride_fiber_release` in
`runtime/compiler_rt.c` and is native-only. A C3 emitter **refuses** a module that
references those symbols, with a diagnostic saying so, rather than emitting a program
that fails to link.

---

## 5. Where it lives, and the gate that runs without a build

The seam follows the existing boundary rule in the Makefile: a consumer of AIR lives
on the USE side and may not import an emitter.

```
pfront/pear_ir/air_c3.c3     ← new, USE side, listed in AIR_USE
tools/air/airtool.c3         ← new command: `emit-c3 FILE.low.air [-o OUT.c3]`
```

`airtool emit-c3` sits beside `emit-ll` and shares its walk, so the two consumers
cannot disagree about what the low profile is. `air_c3` imports `air_ir`, `air_text`,
and `air_util` only — the same three modules `air_ll` imports.

**The gate.** `make check-pear2` already proves a C3 source tree type-checks with no
executable and no LLVM:

```
c3c compile -C --no-entry --stdlib $(C3C_LIB) ... --max-stack-object-size 262144
```

A companion `check-c3-target` target does the same over the AIR USE half plus
`air_c3.c3` and `tools/air/airtool.c3`. That is a real type-check of the emitter by the
reference C3 compiler, and it needs neither `pfrontc` nor an AIR fixture — which
matters, because the fixtures need a producer to make `.low.air` files.

---

## 6. Tests that do not need a producer

The corpus of `.low.air` fixtures does not exist in the tree yet (there is no
committed `.low.air` anywhere; `tests/air3/prog/*.pie` are sources that need `pfrontc`
to lower). So C3-target testing starts structural, in the style of `tests/air/`:

1. **Mapping completeness.** For every `AirPrdTag`, `AirCmdTag` and `AirTypTag`, assert
   `air_c3.c3` either handles it or refuses it, and that its handled/refused decision
   matches `air_ll.c3`'s for that tag. This catches the "silently narrower than the
   last consumer" class directly, and it is pure text analysis — no build, no binary.
2. **The comment trap, already learned.** Any assertion against C3 source text strips
   comments first (`_code_only()` in `tests/air/test_type_ann_plumbing.py`); string
   literals are kept only where a literal is the thing being asserted.
3. **No `goto`, ever.** Assert the string `goto` appears in no emitted-C3 template —
   C3 removed it, so a template that prints one emits unrunnable code.
4. **Dispatch-loop accounting.** Assert the "N function(s) used the dispatch loop"
   report exists and is printed on stderr, so the fallback can never grow silently.
5. **Hand-written fixtures, once a producer exists.** Author `.low.air` by hand from
   `docs/specs/AIR3.md` for the shapes in §3.3 and check the emitter's text against a
   golden `.c3` file. These are worth writing only after the emitter exists.

---

## 7. Honest limits

* **Nothing here has been compiled.** `c3c` is not available in this environment and
  this document does not claim a green build. The gate in §5 is defined, not run.
* **No `.low.air` fixture exists to read.** The mapping is derived from the spec and
  from `air_ll.c3`, which is the executable definition of the profile. The first
  emitter task is to make `airtool emit-c3` parse the same files `emit-ll` parses.
* **Closures, effects, fibers.** §4.6 argues the first two need no special case; that
  argument is from reading `air_low`'s output contract, not from running it on
  `examples/02_algebraic_effects_state_logger.pie`.
* **A C3 target is a second backend, not a replacement.** The LLVM path compiles real
  programs today. Like `pear2`, this path earns its place by being honest about
  coverage.
