# AIR 3.0 — the low profile (what PEAR 2 consumes)

AIR 3.0 is AIR 2.x restricted to a **low profile** and extended with explicit memory, so that a consumer can
translate it to LLVM IR (or any SSA/CFG machine IR) *one form at a time, with no type inference and no
evaluation*. It is the level of LLVM's `.ll`: typed values, explicit `alloca`/`load`/`store`/`gep`, basic-block
structure, calls through pointers, `syscall`, atomics.

Producer: `pfrontc FILE.pie --emit-air-low` → `FILE.low.air` (pfront/pear_ir/air_low.c3).
Reference consumer: `tmp/airtool verify-low F.low.air` (validity) → `tmp/airtool emit-ll F.low.air -o F.ll`
(pfront/pear_ir/air_ll.c3) → `python3 scripts/ll-exe.py F.ll -o F` (LLVM 23).
A consumer is correct when it agrees with that chain on `tests/air3/` and `tests/exec/`.

Header: `air 3.0 Main "src";`. A file is a list of declarations; the syntax is that of `docs/specs/AIR.md` plus:

| form | meaning |
|---|---|
| `alloca(T) : ptr(T)` | one stack slot of type `T` for the activation |
| `load(p) : T` | read through `p : ptr(T)` |
| `store(p, v)` | write `v : T` through `p : ptr(T)` |
| `gep[T](p, i, …) : ptr(U)` | address arithmetic over `T` (struct field index / array index) |
| `[pub] [extern] global [mut] NAME : T [= c];` | module storage; `c` is a constant tree: int/float/bool/char/null, string, record, tuple, array, zero-array |
| `declare` / `extern declare f(..) : R` | an external symbol (a name `llvm.*` is an LLVM intrinsic) |

## What is guaranteed in the low profile

* every `def` parameter, `let`, block parameter and result has a **concrete low type**: the machine integers
  (`i8…i64,isz,u8…u64,usz`), `f32,f64,bool,char,unit,!`, `ptr(T)`, `T[n]`, tuples, arrows, and `nominal` data;
* **no** `infer`, `con`, `lam`, `mu`, `cometa`, `reify`, `eval`, `quote`, `splice`, `offsetof`, `alignof` (the
  producer has evaluated them: quote/splice/eval become thunks, `sizeof` is a constant, effects are ordinary
  code — see below);
* control flow is `label`-spine blocks with `jump` arguments (phis), `if`, `match` on int/bool/char, `ret`,
  `trap`, `ub`, `cut`;
* aggregates are built by `record`/`tuple`/`array` and read by field/projection/`gep`;
* **function values** are closure records `{fn: arrow(ptr(u8), ps…) -> r, env: ptr(u8)}` (nominal `Fn.<sig>`);
  plain functions get a `.clo` adapter, raw code pointers and externs an `ind.<clo>` adapter;
* **algebraic effects** are lowered: one global `hop.E.op` cell per operation holding the innermost handler
  closure, a `Frame.N` per `handle`, and an unwinding flag `@__unw` checked after calls (tail-resumptive and
  aborting arms);
* variadic C calls: `declare … varargs`; `syscall` is the `syscall` command (≤ 7 operands).

## Consumer limits (air_ll)

16384 names, 4096 blocks, 16384 phi edges and 8192 strings per function/module; aggregates ≤ 64 parts;
calls ≤ 16 arguments; types: tuples and arrow domains ≤ 16 elements. A violation is a *diagnostic*, never a
silent truncation.

## Not lowered (producer reports a diagnostic instead of a file)

See `docs/pear2/AIR3_PLAN.md` §3 for the current list.
