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

## Systems primitives (OS / concurrency)

| AIR 3 text | LLVM | notes |
|---|---|---|
| `load volatile(p)`, `store volatile(p, v)` | `load volatile`, `store volatile` | Pride: `volatile *p`, `volatile *p = v` (also `+=`) |
| `atomic OP ORDER(p, v…) · comu r.` with OP ∈ `load store xchg add sub and or xor nand max min umax umin cmpxchg` and ORDER ∈ `relaxed acquire release acq_rel seq_cst` | `load atomic`, `store atomic`, `atomicrmw`, `cmpxchg` | `p : ptr(iN)`, N ≤ 64, operands have the pointee type; the result is the OLD value (`store`: unit); `cmpxchg(p, expected, new)` returns the old value; a load may not be release/acq_rel, a store not acquire/acq_rel. Pride: `atomic_add(p, v)`, …, optional trailing order string: `atomic_add(p, 1, "acq_rel")`, default `seq_cst` |
| `fence ORDER` | `fence` | acquire … seq_cst; Pride: `fence("release")`, `fence()` = seq_cst |
| `asm [intel] "template" "constraints" : [T] (operands) · comu r.` | `call T asm sideeffect [inteldialect] "template", "constraints"(operands)` | the template and constraints are LLVM's (`$0`, `=r,r,~{memory}`); the Pride front end takes GCC-style `asm { "leaq 2(%1), %0" : "=r"(out) : "r"(in) : "memory" }` (`%N` → `$N`, `%%` → `%`, literal `$` escaped), at most one output (an lvalue, which receives the result), no `+` operands yet. `T` is the output type or `unit`. Always `sideeffect` |

Everything above is gated by `tests/air3/prog/at01_atomics.pie` (native and wasm32) and `tests/air3/prog_x86/asm01_inline.pie`
(x86-64 hosts only).

## Declaration attributes

A declaration may carry up to 8 attributes, written before its modifiers: `attr NAME [STRING | INT]`.
The low profile defines these (anything else is dropped by the producer, never invented):

| attr | on | LLVM | Pride source |
|---|---|---|---|
| `attr section "x"` | `def`, `global` | `section "x"` | `#section(".text.boot")` |
| `attr align N` (power of two) | `def`, `global` | `align N` | `#align(64)` |
| `attr packed` | `data` | `type <{ … }>` (also for constant initialisers) | `#packed` |
| `attr naked` | `def` | `naked`: no prologue/epilogue; the body must be inline asm plus a non-returning end | `#naked` |
| `attr noinline` / `attr inline` / `attr cold` | `def` | `noinline` / `alwaysinline` / `cold` | `#noinline`, `#inline`, `#cold` |

Pride writes them as `#name`, `#name(arg)` or `#[a, b(1)]` on the lines before a declaration. `section`/`align` on a `data` type
or `packed` on a function are errors in `air_ll` (they have no meaning there). Known limit: trailing attributes of a function nested in an `impl` attach to the impl.
Gated by `tests/air3/prog/at02_decl_attrs.pie`, `tests/air3/good/attrs_packed_section.air` and, for a `#naked` `_start`, `tests/air3/prog_fs/fs02_naked_start.pie`.

## Freestanding

`airtool emit-ll X.air --syscall=x86_64-linux` lowers `syscall(n, …)` (≤ 7 operands) to the x86-64 `syscall` instruction instead of a libc call;
`scripts/ll-exe.py --freestanding` links with `-nostdlib -static -Wl,-e,_start`. A program supplying its own `_start` (naked, asm that aligns the stack
and calls a Pride function, see `fs02`) then runs with no libc and no crt. Gated (x86-64 hosts) by `tests/air3/prog_fs/`.

## Consumer limits (air_ll)

16384 names, 4096 blocks, 16384 phi edges and 8192 strings per function/module; aggregates ≤ 64 parts;
calls ≤ 16 arguments; types: tuples and arrow domains ≤ 16 elements. A violation is a *diagnostic*, never a
silent truncation.

## Not lowered (producer reports a diagnostic instead of a file)

See `docs/pear2/AIR3_PLAN.md` §3 for the current list.
