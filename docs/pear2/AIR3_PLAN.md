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
| the same `.ll` through LLVM's WebAssembly backend (`ll-exe.py --triple wasm32-unknown-unknown`) | 13/13 prog programs produce a wasm object (not linked or run: no `wasm-ld` in this sandbox) |
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

* generics: ≤ 4 type parameters, instantiated at call sites only; interfaces/impls are not instantiated (no dictionaries, no `obj.method()`);
* closures: the environment lives on the stack — an escaping closure dangles (needs heap environments);
* effects: tail-resumptive and aborting arms only; non-tail-resumptive (multi-shot, `resume` inside a nested continuation) is rejected;
* MSP is thunk-based (no staging optimisation), `poison` is arbitrary, `offsetof` lowers to `sizeof usize`;
* `*|` (saturating) is unsupported; plain `+ - *` wrap;
* `[v; n]` by value with `n > 64` is rejected; global `[v; n]` is constant only for a zero fill; constant globals ≤ 16 fields/elements per aggregate;
* structs by value ≤ 16 fields, ≤ 16 defers per function, unions ≤ 8 members, handlers ≤ 8 operations;
* slices `a[lo..hi]`, `for x in slice`, bare enum constructor identifiers, `Rewrite` rules, `const fn K : u64 = e`: partial;
* `static mut` has storage (a `global mut`) but no AIR-H counterpart;
* `air_verify` rule V5 (low-profile conformance inside the verifier) and `air_emit.c3` cases for the 3.0 forms are not done — `verify-low` is the checker;
* `__pride_*` runtime symbols declared in stdlib have no implementation (declared only);
* `tests/exec/27_effect_poly_forward` fails (known).

## 4 Order of work

1. interfaces via dictionaries and `obj.method()`; 2. heap environments for escaping closures; 3. slices and ranges;
4. multi-shot/non-tail effects (one-shot continuations via stack copying, or CPS in the producer);
5. `air_verify` V5 and spec text in `docs/specs/AIR.md`; 6. WASM: `air_ll` output already goes through LLVM's wasm32 backend (objects, gated). Still to do: link with `wasm-ld`, supply a libc/WASI shim for `malloc`/`write`/`syscall`, run under node/wasmtime and compare exit codes. Note `usz`/`isz` are `i64` in AIR 3 (legal on wasm32, just wider than native index math); `sizeof` is computed by LLVM for the target.
