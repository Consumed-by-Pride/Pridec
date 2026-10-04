# AIR 3 — status and plan (measured)

Goal (owner's words): *everything lowered to a clean `.air`, as high/low level as LLVM's `.ll`, for PEAR 2 to
consume; Pride must be able to write an OS, a self-hosting compiler, a WASM backend (through LLVM), games,
browsers and search engines.*

## 1 What exists

`pfrontc --emit-air-low` (air_low.c3) → AIR 3.0 low profile (docs/specs/AIR3.md) → `airtool verify-low` →
`airtool emit-ll` (air_ll.c3, the reference consumer) → LLVM 23 → executable or object.

Gate (`make test-air3`, part of `make test`; `tests/air3/gate.sh`, floors in `tests/air3/GATE_FLOORS`):

| corpus | result |
|---|---|
| `tests/air3/prog/*.pie` (effects, closures, raw fn pointers, tuples, wide signatures, constant globals, offside `else`, quote/splice) | all pass: built from the low `.air`, executed, exit code/stdout as the header says |
| `tests/exec` (84 programs) | **84 PASS**; 0 FRONT / NOLOWER / VERIFY / LLVM / WRONG (the 12 front-end gaps of the previous round are closed: tuple-of-function types, `(a; b)` sequences, the stray DEDENT after `handle`/`match` arms, `Str`, `stage e`, `Tensor<T; d..>` / `[\| \|]` / `@`, the stdlib `ub.assume` family; see section 4) |
| the same `.ll` built for `wasm32-wasi` (LLVM wasm backend → zig `wasm-ld` + wasi-libc + `runtime/wasi/pride_rt.c`) and **run under wasmtime** (`low_corpus.sh --wasm`, in the gate) | 14/14 prog and 82/82 exec programs (2 more call the host fiber runtime and are reported NOTARGET) produce the same exit status and stdout as native. Externs keep their Pride-declared signatures, so `ll-exe.py` renames each external `F` to `pride_rt_F` and the shim adapts the 32-bit libc ABI (`malloc(i64)` vs wasm32 `malloc(i32)` trapped before this); only `malloc/free/write/syscall/labs/abs/…` exist so far |
| `stdlib/**` (260 modules, library mode) | 260/260 lower, verify-low, and compile to an `-O2` LLVM object |

"Library mode": a module with no `main` lowers every non-generic function it defines.

## 2 Defects found and fixed on the way (they were silent before)

* parser: an `else` on its own line at a shallower indent bound to the *inner* `if` (PEAR 1 miscompiled it too);
* SCCP evaluated `()` as the integer `0` and materialised it, changing the type of an `if` arm;
* `AirTyp.args` held 8 entries and `air_mk_typ_tuple`/`add_arg` dropped the rest: a 9-parameter function lost a parameter;
* front-end passes (theory residualisation, constant folding) dropped literal width suffixes (`1i32 - 1023i32` became an untyped `i64`);
* emitter-made block names collided with lowering labels (58 stdlib modules produced invalid LLVM);
* stdlib type errors that PEAR 1 let through (see the `stdlib lowers completely` commit).
* parser, found while closing the exec front-end gaps: a `|` arm line deeper than its statement opens an indentation level in the lexer *without* an INDENT token, but its DEDENT is emitted — so after any statement-level `match`/`handle` the rest of the block silently became top-level (`e` unresolved after the first `match e`). `parse_match`/`parse_handle` now consume that DEDENT;
* `(i64 -> i64, i64)` (a function type inside a tuple type) and `(a; b; c)` sequences did not parse; `Str` was not a type name (it is now the spelling of `str`); `stage y + 10` read `stage` as a variable (it is the bare expression now);
* `Tensor<T; d1, d2>` (nested fixed arrays), `[| a, b |]` literals and `a @ b` (vector·vector, matrix@vector, matrix@matrix; i/f element types; shapes checked while lowering) were not in the front end at all; `@` lowers to three counted loops over stack slots — no new AIR form;
* stdlib: `pride.ub` lacked the short names the tests call (`ub.assume`, …); `effect_async.nursery` stored 32-byte tasks in a 16-byte-element vec (heap overflow) and freed vec-interior pointers (double free);
* tests fixed because they were wrong, not the compiler: `15_ub_explicit` (`ub!` outside `unsafe` is E3230 by design), `44_hybrid_scoped_effects` (called an API with types the stdlib does not declare, resumed a fiber with a null entry; now a real raw C entry `fiber_entry as ptr`), `46_mlcee_contextual_effects` (inspected a box with no code and asserted it found one).

## 3 What is still not at LLVM level (honest list)

* generics: ≤ 8 type parameters (more is a lowering error; it was 4 and silently truncated — `gn01`), instantiated at call sites only. Interfaces: `impl I for T` methods are called as `v.m(..)` and resolved statically (a generic bounded by an interface is monomorphised, so one target per instance; `Self` works inside an impl; `if01`). Not done: bare `area(x)` / `Shape.area(x)` (the front end reports the name unresolved), generic impls, default methods, **`dyn I` sugar** — there is no `dyn` syntax, but dynamic dispatch is *expressible and tested* today: static vtables (`static VQ : VT = VT { area: sq_area as ptr, .. }`, a global initialiser holding code addresses), a `{data, vtable}` fat pointer, and a call through the loaded pointer (`dy01`; native, wasm32 and `--internalize`); `stdlib/dyn.pie` has the `DynPtr` type;
* closures: an environment is heap-allocated unless the lambda is written directly as a call argument (`cl01`: returned adder, returned counter, closure in a struct; on the stack it segfaulted). An escaping closure owns a heap copy of a captured `mut` variable (move semantics: the creator's variable is no longer shared). A stack closure passed to a callee that stores it still dangles (trusted callee, no lifetime check). Nothing is ever freed (no GC / drop yet);
* effects: tail-resumptive and aborting arms only; non-tail-resumptive (multi-shot, `resume` inside a nested continuation) is rejected;
* MSP is thunk-based (no staging optimisation), `poison` is arbitrary, `offsetof` lowers to `sizeof usize`;
* `*|` (saturating) is unsupported; plain `+ - *` wrap;
* global `[v; n]` is constant only for a zero fill; a constant global array has any number of elements (`gl02`: 256), a constant struct/tuple ≤ 16 fields; a constant may hold `f as ptr` (a code address) or the address of another global (`dy01`, an IDT-style handler table);
* aggregates by value: a struct literal has ≤ 64 fields (more than 16 are built in memory, `ag01`: 24 fields), an array literal ≤ 1024 elements (more than 64 in memory, `ar03`), `[v; n]` any `n` (`ag02`); ≤ 16 defers per function, unions ≤ 8 members, handlers ≤ 8 operations; **functions, function types and calls ≤ 16 parameters/arguments and tuple types ≤ 16 elements — more is now a clear lowering error** (it was a silent cut in the signature and a misleading "clause pattern shape" error); the cap lives in `AirTyp.args`/`AirCmd.prds` and the lowering's fixed arrays;
* open-ended slice ranges `a[..n]`, `a[n..]`, `a[..=n]`, `a[..]` work on arrays and slices (`sl03`; on a raw pointer `p[n..]` is an error: there is no length); bare enum constructor identifiers, `Rewrite` rules, `const fn K : u64 = e`: partial; a bare `area(x)` for an interface method is still unresolved by the front end (use `x.area()`);
* `static mut` has storage (a `global mut`) but no AIR-H counterpart;
* `air_verify` rule V5 (low-profile conformance inside the verifier, no LLVM) is done (spec "Verifier rule V5"); `air_emit.c3` cases for the 3.0 forms are not done — `verify-low` is the type checker;
* the `__pride_*` fiber/prompt/evidence symbols declared in `stdlib/pride/effects.pie` are implemented by `runtime/compiler_rt.c` (ucontext, host only): `low_corpus.sh` links it for native runs (`ll-exe.py --link`), a wasm/i386/freestanding build of a program that calls it is reported NOTARGET — PEAR2 needs its own stack-switching story for those targets;
* source `.len` and index arithmetic are `i64` even on 32-bit targets (correct, but wider than `usz`); a language-level `usz` for them is not done.

## 4 Order of work

1. (done) static interface methods `obj.method()`, heap environments for escaping closures, `for x in slice/array`, `x[lo..hi]` / `x[lo..=hi]` sub-slices (bounds-checked, alias the source; `fe01`, `sl01`, `if01`, `cl01`);
3. (done) volatile accesses, atomics (`atomic_*`, 14 ops, orders), fences, GCC-style inline asm with one output (`at01`, `asm01`; AIR3.md "Systems primitives"). Also done: declaration attributes `section/align/packed/thread_local/naked/noinline/inline/cold` (`attr` modifier, AIR3.md "Declaration attributes") and a freestanding mode (`--syscall=x86_64-linux`, `ll-exe.py --freestanding`, own `_start`; `fs01`, `fs02`). Then (OS-first round; later `callconv` incl. `x86_intr` handlers, verifier V5): target-width `usz`/`isz` (`--target=`), `#export`/`#used`/`#noredzone`/`#no_builtins`, multi-output and `+r` asm, a bare-metal kernel image check (`bare.sh`), own-runtime freestanding program (`fs03`), 32-bit x86 native runs, cross objects for aarch64/riscv/arm, `callconv` (incl. `x86_intr`), extern/exported globals and linker-script symbols, `--internalize` (linkage from `pub`), `syscall` as the instruction on x86-64/i386/aarch64/riscv64 (i386 runs freestanding: `fs32_01`). Still missing for an OS: booting the kernel image (no QEMU here), `usz` for the language-level `.len`/indexes, dead-stripping beyond what LLVM does with `--internalize` (only code reachable from `main`/roots is lowered anyway);
4. multi-shot/non-tail effects (one-shot continuations via stack copying, or CPS in the producer);
5. `air_verify` V5 and spec text in `docs/specs/AIR.md`; 6. WASM: `air_ll` output already goes through LLVM's wasm32 backend (objects, gated). Still to do: link with `wasm-ld`, supply a libc/WASI shim for `malloc`/`write`/`syscall`, run under node/wasmtime and compare exit codes. Note `usz`/`isz` are `i64` in AIR 3 (legal on wasm32, just wider than native index math); `sizeof` is computed by LLVM for the target.
