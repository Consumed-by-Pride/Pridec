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
| `tests/exec` (84 programs) | 72 PASS, 12 are rejected by the front end itself (`XFAIL.tsv`); 0 NOLOWER / VERIFY / LLVM / WRONG |
| the same `.ll` built for `wasm32-wasi` (LLVM wasm backend → zig `wasm-ld` + wasi-libc + `runtime/wasi/pride_rt.c`) and **run under wasmtime** (`low_corpus.sh --wasm`, in the gate) | 14/14 prog and 72/72 exec programs produce the same exit status and stdout as native. Externs keep their Pride-declared signatures, so `ll-exe.py` renames each external `F` to `pride_rt_F` and the shim adapts the 32-bit libc ABI (`malloc(i64)` vs wasm32 `malloc(i32)` trapped before this); only `malloc/free/write/syscall/labs/abs/…` exist so far |
| `stdlib/**` (260 modules, library mode) | 260/260 lower, verify-low, and compile to an `-O2` LLVM object |

"Library mode": a module with no `main` lowers every non-generic function it defines.

## 2 Defects found and fixed on the way (they were silent before)

* parser: an `else` on its own line at a shallower indent bound to the *inner* `if` (PEAR 1 miscompiled it too);
* SCCP evaluated `()` as the integer `0` and materialised it, changing the type of an `if` arm;
* `AirTyp.args` held 8 entries and `air_mk_typ_tuple`/`add_arg` dropped the rest: a 9-parameter function lost a parameter;
* front-end passes (theory residualisation, constant folding) dropped literal width suffixes (`1i32 - 1023i32` became an untyped `i64`);
* emitter-made block names collided with lowering labels (58 stdlib modules produced invalid LLVM);
* stdlib type errors that PEAR 1 let through (see the `stdlib lowers completely` commit).

## 3 What is still not at LLVM level (honest list)

* generics: ≤ 4 type parameters, instantiated at call sites only. Interfaces: `impl I for T` methods are called as `v.m(..)` and resolved statically (a generic bounded by an interface is monomorphised, so one target per instance; `Self` works inside an impl; `if01`). Not done: bare `area(x)` / `Shape.area(x)` (the front end reports the name unresolved), generic impls, default methods, **dynamic dispatch** — the language has no `dyn` syntax, but AIR 3 can already express a vtable (a record of function values), so PEAR2 is not blocked;
* closures: an environment is heap-allocated unless the lambda is written directly as a call argument (`cl01`: returned adder, returned counter, closure in a struct; on the stack it segfaulted). An escaping closure owns a heap copy of a captured `mut` variable (move semantics: the creator's variable is no longer shared). A stack closure passed to a callee that stores it still dangles (trusted callee, no lifetime check). Nothing is ever freed (no GC / drop yet);
* effects: tail-resumptive and aborting arms only; non-tail-resumptive (multi-shot, `resume` inside a nested continuation) is rejected;
* MSP is thunk-based (no staging optimisation), `poison` is arbitrary, `offsetof` lowers to `sizeof usize`;
* `*|` (saturating) is unsupported; plain `+ - *` wrap;
* `[v; n]` by value with `n > 64` is rejected; global `[v; n]` is constant only for a zero fill; constant globals ≤ 16 fields/elements per aggregate;
* structs by value ≤ 16 fields, ≤ 16 defers per function, unions ≤ 8 members, handlers ≤ 8 operations;
* open-ended slice ranges `a[..n]`/`a[n..]` (the parser rejects them: E1050), bare enum constructor identifiers, `Rewrite` rules, `const fn K : u64 = e`: partial;
* `static mut` has storage (a `global mut`) but no AIR-H counterpart;
* `air_verify` rule V5 (low-profile conformance inside the verifier, no LLVM) is done (spec "Verifier rule V5"); `air_emit.c3` cases for the 3.0 forms are not done — `verify-low` is the type checker;
* `__pride_*` runtime symbols declared in stdlib have no implementation (declared only);
* `tests/exec/27_effect_poly_forward` fails (known).

## 4 Order of work

1. (done) static interface methods `obj.method()`, heap environments for escaping closures, `for x in slice/array`, `x[lo..hi]` / `x[lo..=hi]` sub-slices (bounds-checked, alias the source; `fe01`, `sl01`, `if01`, `cl01`);
3. (done) volatile accesses, atomics (`atomic_*`, 14 ops, orders), fences, GCC-style inline asm with one output (`at01`, `asm01`; AIR3.md "Systems primitives"). Also done: declaration attributes `section/align/packed/thread_local/naked/noinline/inline/cold` (`attr` modifier, AIR3.md "Declaration attributes") and a freestanding mode (`--syscall=x86_64-linux`, `ll-exe.py --freestanding`, own `_start`; `fs01`, `fs02`). Then (OS-first round; later `callconv` incl. `x86_intr` handlers, verifier V5): target-width `usz`/`isz` (`--target=`), `#export`/`#used`/`#noredzone`/`#no_builtins`, multi-output and `+r` asm, a bare-metal kernel image check (`bare.sh`), own-runtime freestanding program (`fs03`), 32-bit x86 native runs, cross objects for aarch64/riscv/arm. Still missing for an OS: interrupt/other calling conventions, booting the kernel image (no QEMU here), `usz` for the language-level `.len`/indexes, per-target `syscall` numbering outside x86-64 Linux, internal linkage / dead-stripping of non-exported definitions;
4. multi-shot/non-tail effects (one-shot continuations via stack copying, or CPS in the producer);
5. `air_verify` V5 and spec text in `docs/specs/AIR.md`; 6. WASM: `air_ll` output already goes through LLVM's wasm32 backend (objects, gated). Still to do: link with `wasm-ld`, supply a libc/WASI shim for `malloc`/`write`/`syscall`, run under node/wasmtime and compare exit codes. Note `usz`/`isz` are `i64` in AIR 3 (legal on wasm32, just wider than native index math); `sizeof` is computed by LLVM for the target.
