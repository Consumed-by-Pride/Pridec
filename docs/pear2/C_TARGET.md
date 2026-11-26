# C as the transpilation target

Why C beats C3 for this job, the mapping from the AIR 3.0 low profile to C11, the
control-flow strategy, and what is verified versus what is still a claim.

**Status: the emitted C is executed; the emitter itself is not built.** This
environment has `gcc` and no `c3c`, so two different things were verified:

* the **runtime prelude is extracted from `air_c.c3`'s own string literals**, compiled
  at `-Wall -Wextra -Werror` and run (its `syscall` path executes);
* the **C text for every awkward AIR form** is compiled and executed
  (`tests/air3/c/shape_test.c`, 9 checks, clean at `-Werror`, under ASan and under
  UBSan);

while the *emitter source* — C3, like the rest of the compiler — has never been
compiled. That distinction is kept honest throughout and summarised in §8.

Supersedes `docs/pear2/C3_TARGET.md`, which remains as the record of the C3
investigation and the argument that was overturned. §1 explains what changed.

---

## 1. Why C, and what the C3 investigation established

The request was AIR → middle layers → a transpilation target, with C3 chosen over
C/C++ because "C3 is cleaner and easier and has macros". Building the C3 consumer
(`pfront/pear_ir/air_c3.c3`, committed `feb34aa`) produced one finding that
outweighs the ergonomics argument:

> **AIR 3.0 is a control-flow graph with label-parameter (phi) joins. C3 removed
> `goto`.** A CFG can be printed in C with one label and one `goto` per block. In
> C3 the same CFG has to be recovered as structured control flow — a relooper — or
> driven by `while (true) { switch (__pc) { … nextcase } }`.

So the language chosen for cleanliness is the one where the hardest part of the
job becomes a research problem. C's `goto` does not merely make this *easier*, it
makes the output **exactly shaped like the input**: one AIR label is one C label,
one AIR `jump` is one `goto`. There is no structuring step to get wrong, and a
disagreement between the AIR and the C can be read off line by line.

That is worth more than the five C3 advantages, because the four of them are
recoverable in C and the fifth is not:

| C3 advantage | what C does instead |
|---|---|
| Sized integer types matching AIR's | `stdint.h` is exactly this: `int8_t…int64_t`, `uint8_t…uint64_t`, `intptr_t`/`uintptr_t` for `isz`/`usz` |
| Real modules, no name mangling | one `.c` per AIR module, emitted into its own directory, with a `pear_out_` symbol prefix for globals; no linker-level namespace needed |
| Macros that are typed compile-time functions | the places the emitter would use one (`alloca`/`load`/`store`/`gep`) are **already C expressions** — `T v`, `*p`, `*p = v`, `&p->f` — so there is nothing to abstract over. The macros that remain are the attribute ones (§4.5) |
| `defer` | AIR's low profile has no `ACMD_DEFER`; `air_low` has already lowered it |
| No `goto` | *this is the one thing C3 actually gave up*, and it is the whole job |

What C3 would still buy is readability of the emitted text, which is real but
second-order: the emitted C is a faithful transcription of the AIR, and the AIR is
what a person reads when the compiler is wrong.

**And the C target is verifiable here.** `gcc` is present in this environment and
`c3c` is not, so for the first time in this line of work the *output* can be
executed rather than reasoned about. §8 lists exactly what that does and does not
cover.

## 2. The seam: AIR 3.0 directly

Same decision as the C3 target, for the same measured reason. PIR
(`pear2/pear2_cfg.c3`) is integer-scalar only — `PParam[16]`, `ret_width`, no
float type, no aggregates, `int[6] args` — so routing a C target through it would
inherit that narrowness, and the 30-field and 200-element fixtures in
`tests/air3/prog/` would fail for a reason belonging to a different backend.

```
pfront/pear_ir/air_c.c3            ← new: AirModule -> C11 source (AIR_USE side)
tools/air/airtool.c3               ← `emit-c` beside `emit-ll` and `emit-c3`
tests/air3/c/__pride_rt.h          ← the generated runtime prelude
tests/air3/c/shape_test.c          ← executed proof of every template shape
tests/air3/c/run.sh                ← `make test-c-target`
```

`air_c` imports `air_ir`, `air_text`, `air_util` — the shared floor, nothing else.
`tests/air/boundary.sh` enforces that.

## 3. Control flow: labels and `goto`, and the one thing that is subtle

### 3.1 The translation

| AIR 3.0 | C11 |
|---|---|
| a def body's label spine `seq { label A c ; …. entry }` | `A: { … }` in the same order |
| `jump L(a, b)` | `p0 = a; p1 = b; goto L;` |
| label parameters | locals of the function, declared once at the top |
| `if c then X else Y` | `if (c) { X } else { Y }` — or the two `goto`s, when X/Y are labels |
| `match` on int/bool/char | `switch`, with a `goto` per arm |
| `ret v` | `return v;` |
| `cut` with no consumer | `goto` to the label the spine continues at |

Because every label parameter is a function-scope local and every `jump` assigns
them, the translation is correct without any dominance reasoning. This is PIR's
argument (`pear2_cfg.c3`: *"a slot is always correct"*) and it costs one store per
jump argument, which any C compiler promotes in a register.

### 3.2 The parallel copy — the one real hazard

`jump L(x, y)` assigns `L`'s parameters from values that may themselves be `L`'s
parameters. This is a **parallel copy**, and emitting the assignments one at a
time in declaration order is wrong (the classic lost-copy problem).

Worked example, from the `air_fib` case in `tests/air3/c/shape_test.c`:

```c
/* jump F0(i+1, a+b, a) -- three simultaneous updates */
```

Emitted naively in declaration order (`i`, `a`, `b`):

```c
i = ni;  a = nt;  b = a;      /* reads the NEW a: b becomes a+b, not a */
```

which computes `fib(10) = 512` instead of `55`. This is not hypothetical: that
mutation is in the test suite and it fails there.

The emitter therefore emits a **vertex** whenever a jump has more than one
argument:

```c
int64_t v0 = nt, v1 = ni, v2 = a;   /* all reads of the old values */
a = v0; i = v1; b = v2;
```

One extra copy per argument per jump. It is not minimised (a real parallel-copy
sequencer emits a cycle-free assignment order and breaks cycles with a single
temp); it is made unconditionally correct. Optimising it is a later pass with a
number attached, not a special case to reason about now. The same conservative
choice is what PIR's header argues for.

### 3.3 `asm` — where C is *better* than C3, again

AIR's inline asm carries LLVM constraint syntax (`: [T] (operands) · comu r.`,
and `Acmd.asm_cons`). That is **GCC/Clang extended-asm syntax**, which C compilers
accept essentially verbatim and C3 does not (`air_c3` refuses it). So the C target
does not refuse `ACMD_ASM`; it emits

```c
__asm__ volatile ("template" : "constraints" (operands));
```

### 3.4 What C adds that the emitter must not emit

`goto` into a scope that skips a declaration-with-initialiser is legal in C but a
warning (`-Wjump-misses-init`) and a sure sign of a mis-shaped copy. The emitter
never does it: **all** declarations that a label can jump over are hoisted to the
top of the function, exactly like the label parameters. That is why §3.1 is safe
and why the emitted C is clean under `-Werror`.

## 4. The mapping table

### 4.1 Types

| AIR 3.0 | C11 | note |
|---|---|---|
| `i8 i16 i32 i64` | `int8_t int16_t int32_t int64_t` | `stdint.h` |
| `u8 u16 u32 u64` | `uint8_t uint16_t uint32_t uint64_t` | |
| `usz isz` | `uintptr_t intptr_t` | pointer-width; `intptr_t` is signed, which `isz` is |
| `f32 f64` | `float double` | |
| `bool` | `bool` | `stdbool.h` |
| `char` (AIR) | `uint32_t` | **watch this row.** `air_util::ty_is_int` counts `ATYP_CHAR` as an integer and `air_ll` prints it `i32`: it is a code point, not a byte. C's `char` would truncate |
| `unit` | `void` in return position; `pride_unit` as a value | a unit *value* only appears as an aggregate part |
| `ptr(T)` | `T *` | |
| `T[n]` | `T[n]` | |
| `{A, B}` tuple | `struct __tup_A_B { A _0; B _1; }` | generated per shape, named from the shape |
| `%"Name"` single-ctor | `struct Name { … }` | >1 constructor is refused (§4.6) |
| `arrow` | `R (*)(P…)` | plus a `typedef` when it is a struct field |

### 4.2 Producers

`air_ll` handles 19 producer tags; the C target handles the same 19 (asserted by
`tests/air3/test_c_target.py`). The ones with a decision in them:

| AIR 3.0 | C11 |
|---|---|
| `APRD_INT` | `123` with the suffix of its AIR type: `INT64_C(123)`, `UINT8_C(12)`, `INT32_C(…)` |
| `APRD_FLOAT` | `0x1.5p3` hex-float form — the same value, no rounding through a decimal parser |
| `APRD_CHAR` | `((uint32_t)0x41)` |
| `APRD_STRING` | `static const char __sN[] = "…";` at file scope |
| `APRD_ALLOCA` | a local `T vN;`, operand `&vN` |
| `APRD_LOAD` | `*p` — `(*(volatile T *)p)` when `p.bval` |
| `APRD_GEP` | `&p[i]`, `&p->field`, `&p->_1`, by the same type walk `air_ll` does |
| `APRD_SIZEOF` | `((uintptr_t)sizeof(T))` |
| `APRD_RECORD`/`TUPLE`/`ARRAY` | `(struct Name){ .f = v, … }`, `(struct __tup_A_B){ ._0 = … }`, `(T[N]){ … }` |
| `APRD_COERCE` | `((T)x)`; C's own rules pick signed/unsigned, which is what AIR means |

Refused, exactly as `air_ll` refuses them: `APRD_INL IN R LAMBDA MU COMETA
REIFY EVAL QUOTE SPLICE POISON UNREACHABLE_VAL ALIGNOF OFFSETOF`. These cannot
reach the low profile; seeing one is a producer bug and must be reported, not
approximated.

### 4.3 Commands

`air_ll` handles 15 of 34 command tags; the C target handles the same 15.

| AIR 3.0 | C11 |
|---|---|
| `NOP` | nothing |
| `LET` | `T x = v;` |
| `SEQ` | statements in order |
| `STORE(p, v)` | `*p = v;` / `(*(volatile T *)p) = v;` |
| `FENCE` | `atomic_thread_fence(memory_order_*)` |
| `RET` | `return v;` |
| `TRAP` | `__pride_trap("…")` |
| `UB` | `__builtin_unreachable()` |
| `JUMP` | §3.1/§3.2 |
| `IF` | `if (c) { … } else { … }` |
| `MATCH` | `switch` |
| `CUT` | `goto` / assignment by consumer, as `air_ll` does |
| `SYSCALL` | `__pride_syscallN(n, …)` (§4.4) |
| `ATOMIC` | `<stdatomic.h>` (§4.4) |
| `ASM` | `__asm__ volatile` (§3.3) |

Refused: `WHILE FOR HANDLE PERFORM RESUME DEFER BREAK CONTINUE LABEL LETREC BLOCK
UNSAFE UNCHECKED COMPTIME ASSERT ASSUME MU MUTILDE` — none can reach the low
profile.

### 4.4 The runtime prelude

`tests/air3/c/__pride_rt.h`, included by every emitted file. It exists only for
forms C cannot express as an expression:

* **syscall** — x86-64 Linux, `rax` then `rdi rsi rdx r10 r8 r9`. Seven
  fixed-arity `static inline` functions, because a variadic-asm version cannot
  pin the register classes. The odd `r10`-before-`r8` order is the kernel ABI's.
* **`__pride_trap`** — `__builtin_trap()`, marked as an expression of type `void`.
* **attribute macros** — `PRIDE_SECTION/ALIGN/PACKED/TLOCAL/NORETURN/INLINE/NOINLINE`.
* Atomics need no entry: `<stdatomic.h>` provides them, and the emitter prints
  `atomic_load_explicit((_Atomic T *)p, memory_order_seq_cst)` directly.

### 4.5 Globals, declarations, attributes

| AIR 3.0 | C11 |
|---|---|
| `global NAME : T = c` | `T pear_out_NAME = c;` |
| `global mut NAME : T` | `T pear_out_NAME;` (zero-initialised by C) |
| `declare f(..) : R` | `extern R f(..);` |
| `attr section "x"` | `PRIDE_SECTION("x")` |
| `attr align N` | `PRIDE_ALIGN(N)` |
| `attr packed` | `PRIDE_PACKED` |
| `attr thread_local` | `PRIDE_TLOCAL` |
| `attr naked / noreturn / inline / noinline` | `PRIDE_*` macros |
| `attr noredzone / no_builtins` | emitted as a comment naming them — never silently dropped |

`main`: AIR's `main` is wrapped exactly as `air_ll` wraps it. `pride_main` holds
the AIR body; a generated `int main(void)` calls it and returns 0, or truncates the
AIR return to `int`. Unit-returning `main` becomes `fn void pride_main(void)`.

### 4.6 Closures and effects

Both are already lowered by `air_low` into records, `alloca`s, `load`s, `store`s,
`gep`s and indirect calls, so they arrive as the forms above. The closure record
`{fn, env}` is a `struct` with a function pointer and a `uint8_t *`; a call through
it is `f.fn(f.env, args…)`. No special case. This is the strongest argument for the
AIR 3.0 seam: the two hardest source-level features are gone before the target sees
the module.

Refused, as in `air_ll`: a module referencing `__pride_fiber_*` (the non-tail
resume path) — it would be emitted and then fail to link.

## 5. Placement and the boundary rule

`air_c.c3` is a consumer of AIR, so it sits on the **AIR_USE** side and may not
import an emitter (rule 1 of `tests/air/boundary.sh`). `airtool emit-c` sits beside
`emit-ll` and `emit-c3` and shares their parse walk.

## 6. Tests

**Executed (needs only `cc`)** — `make test-c-target`:

1. `tests/air3/c/shape_test.c` compiled at `-std=c11 -Wall -Wextra -Werror -O2`
   and run; the same file at `-fsanitize=undefined,address`. It contains the C text
   for every awkward AIR form, hand-written in the emitter's exact shape, and 9
   executed checks.
2. Two mutations are applied to a copy of that file and **required to fail**: the
   lost-copy order and a dropped `match` case. A test whose mutations survive is
   not a test — that lesson is why this check exists.

**Structural (no compiler, no producer)** — `tests/air3/test_c_target.py`:

3. For every `AirCmdTag`/`AirPrdTag`, `air_c` handles the tag exactly when
   `air_ll` does. The two consumers may not disagree about what the low profile is.
4. Every `__pride_*` name the emitter prints is **declared in the prelude the
   emitter prints** — the generated `.c` must be self-contained, so the check runs
   against the emitted text and not against a header in this repository. (It found
   a real defect on first run: the emitter printed `__pride_syscall<N>` while the
   prelude defined only `__pride_syscall1..7` as separately-named functions, so a
   prefix-match looked like an undeclared symbol; the check now resolves the arity
   family explicitly.)
5. `air_c` translates `ACMD_ASM` rather than refusing it, asserted positively so a
   future edit cannot quietly start refusing the one form where C beats C3.
6. The parallel-copy guard exists in `C.jump` (§3.2). Asserted by the presence of
   the multi-argument branch, because removing it is a silent miscompile, not a
   crash.
7. `air_c` imports only the shared floor, and is listed on `AIR_USE`.

**The tests were mutation-tested, and the first version of both was defective.**

* `test_c_target.py` used the comment-and-literal stripper for checks that look
  inside emitted literals, so every template assertion matched nothing and passed
  on any input. Fixed with the two strippers and a guard that fails when a pattern
  matches nothing.
* `c/run.sh` had no anchor guard on its prelude extraction: renaming `C.prelude`
  made the extractor crash, and the crash was counted as a pass. It then treated a
  mutation it could not *apply* as a mutation it had *caught* — the opposite of the
  truth. Both fixed; the runner now fails when its anchors move, and a
  prefix-match bug (`C.preludeX` satisfying `"C.prelude"`) was fixed the same way.

Four deliberate breakages are now each required to fail: a renamed prelude, an
undeclared syscall helper, a stale mutation anchor, and a wrong expected value.

## 7. Honest limits

* **The emitter has not been compiled.** It is C3, and there is no `c3c` here. What
  *is* proven is that the C it is written to produce compiles and runs correctly.
  The gap between those two statements is a transcription error in the printer, and
  the first `make check-c-target` on a machine with `c3c` closes it.
* **No `.low.air` fixture exists in the tree**, so `emit-c` has never seen a real
  module. The mapping comes from `docs/specs/AIR3.md` and `air_ll.c3`, the
  executable definition of the profile.
* **The parallel copy is correct but not minimal** (§3.2). Deliberate.
* **x86-64 Linux only** for `syscall`. `air_ll` supports four target conventions;
  `air_c`'s prelude has one, and the emitter refuses `syscall` when
  `air_util::g_triple` names another.
* **C is a second backend, not a replacement.** The LLVM path compiles real
  programs today.
