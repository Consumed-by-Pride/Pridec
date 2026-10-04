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
* **no** `infer`, `con`, `lam`, `mu`, `cometa`, `reify`, `eval`, `quote`, `splice`, `alignof` (the
  producer has evaluated them: quote/splice/eval become thunks, `sizeof` is a constant, `offset_of` is a null-based `gep` + `ptrtoint`, effects are ordinary
  code — see below);
* control flow is `label`-spine blocks with `jump` arguments (phis), `if`, `match` on int/bool/char, `ret`,
  `trap`, `ub`, `cut`;
* aggregates are built by `record`/`tuple`/`array` and read by field/projection/`gep`;
* **function values** are closure records `{fn: arrow(ptr(u8), ps…) -> r, env: ptr(u8)}` (nominal `Fn.<sig>`);
  plain functions get a `.clo` adapter, raw code pointers and externs an `ind.<clo>` adapter;
* **algebraic effects** are lowered: one global `hop.E.op` cell per operation holding the innermost handler
  closure, a `Frame.N` per `handle`, and an unwinding flag `@__unw` checked after calls (tail-resumptive and
  aborting arms; a `return(x)` arm is applied to the body's value where the handle completes). When an arm
  resumes in NON-tail position the handle is lowered with a fiber: `Frame.N` also holds the fiber, a request
  record and the arm environments; the cell holds a *yielder* (`<fn>.yldN`: store the arguments + operation
  number, set `@__hreq` = handler id, call `__pride_fiber_yield`), the handled body is a thunk
  (`<fn>.bodyN`, the fiber entry) and a *driver* (`<fn>.driveN`) resumes the fiber, runs the arm on the handler's
  stack when it yields (`resume k v` = store v, call the driver again), forwards requests aimed at an outer
  handler by yielding its own fiber, and releases the fiber (`__pride_fiber_release`) when the body finishes or
  the arm does not resume. One-shot (a second resume traps); needs `runtime/compiler_rt.c` (native: ucontext, 1 MiB mmap stack + guard page) or, on wasm32, `runtime/wasi/pride_fiber.c` + `scripts/wasm-fibers.py` (binaryen Asyncify: each fiber owns an unwind buffer and a shadow stack; the entry is re-entered in rewind mode on every resume); not available on i386/freestanding;
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
| `attr thread_local` | `global mut` | `thread_local global` (a worker thread gets its own zero/initial copy; `tls01`, native only) | `#thread_local` |
| `attr callconv "NAME"` | `def`, `declare` | NAME ∈ `c fast preserve_most preserve_all x86_intr win64 sysv64 aapcs aapcs_vfp` → `fastcc` … `x86_intrcc`; calls to the function carry the same keyword (the `fastcc` modifier means `callconv "fast"`). `x86_intr`: `(ptr(Frame) [, error code]) : unit`, the frame parameter is emitted `byval(%Frame)` and the function returns with `iretq` | `#callconv("x86_intr")` |
| `attr naked` | `def` | `naked`: no prologue/epilogue; the body must be inline asm plus a non-returning end | `#naked` |
| `attr noinline` / `attr inline` / `attr cold` | `def` | `noinline` / `alwaysinline` / `cold` | `#noinline`, `#inline`, `#cold` |

Pride writes them as `#name`, `#name(arg)` or `#[a, b(1)]` on the lines before a declaration. `section`/`align` on a `data` type
or `packed` on a function are errors in `air_ll` (they have no meaning there). Known limit: trailing attributes of a function nested in an `impl` attach to the impl.
Gated by `tests/air3/prog/at02_decl_attrs.pie`, `tests/air3/good/attrs_packed_section.air` and, for a `#naked` `_start`, `tests/air3/prog_fs/fs02_naked_start.pie`.

## Freestanding

`airtool emit-ll X.air --syscall=T` with T ∈ `x86_64-linux`, `i386-linux` (`int $0x80`, operands truncated to i32, result sign-extended), `aarch64-linux` (`svc #0`, number in x8), `riscv64-linux` (`ecall`, number in a7) lowers `syscall(n, …)` (≤ 7 operands) to that target's instruction instead of a libc call (the number is the target's own: the program picks it; checked by `tests/air3/syscall_arch.sh` by the instruction bytes in the objects, and run for x86-64 and i386);
`scripts/ll-exe.py --freestanding` links with `-nostdlib -static -Wl,-e,_start`. A program supplying its own `_start` (naked, asm that aligns the stack
and calls a Pride function, see `fs02`) then runs with no libc and no crt. Gated (x86-64 hosts) by `tests/air3/prog_fs/`.

## Target

`usz` and `isz` are as wide as a pointer of the target. `airtool emit-ll X.air --target=TRIPLE` writes `target triple = "TRIPLE"` into the `.ll` and
prints them as `i32` for a 32-bit triple (wasm32, i386..i686, arm, thumb, riscv32, mips, powerpc, ...) and `i64` otherwise (no `--target`: `i64`).
`sizeof`/`alignof` yield `usz`; a slice's or `str`'s stored `len` is `usz` (the language-level `.len` reads as `i64`); the runtime entry points the lowering
calls keep the signatures Pride source declares for them (`malloc(i64) -> ptr`, `free(ptr)`); on 32-bit targets the C ABIs read the low word of that first `i64` argument (cdecl, EABI, RISC-V, the wasm shim), so it works, but a definition exported as `malloc` takes an `i64`. `ll-exe.py` honours the module's triple (cross targets give an object file) and takes
`--cpu`, `--features=-sse,+soft-float`, `--reloc static`, `--code-model kernel`, and `--ld-script FILE` (bare metal: `ld -nostdlib -static -T FILE`).
Verified: every `tests/air3/prog` program builds for i686, aarch64, riscv64, riscv32 and armv7; runs under wasmtime (wasm32) and natively as a 32-bit x86
musl executable (`low_corpus.sh --i386`). `-- WASM32-EXIT:` in a test header gives the expected status where the pointer width matters (wasm and i386).
Externs keep their Pride-declared signatures: a Pride `i64` is not a C `long` on a 32-bit target.

## OS-level definitions

| Pride | AIR 3 / LLVM |
|---|---|
| `#export("sym")` on a `fn` | the definition is named exactly `sym` (never suffixed); the runtime's `declare` of that name is dropped (`malloc`, `free`, `memcpy`, `syscall`, `_start`, ...) |
| `#used` on a global | kept although no Pride code names it (assembly does) |
| `#noredzone`, `#no_builtins` | `noredzone`, `"no-builtins"` (a body that is `memcpy` must not be turned into a call to `memcpy`) |
| `asm { "..." : "={eax}"(a), "={ebx}"(b) : "{eax}"(leaf) }` | several outputs: the call returns a tuple, each output is stored to its place; `+r`(x) is an output tied to an input holding x |

Bare metal (`tests/air3/bare.sh`): `tests/air3/prog_bare/kernel.pie` (naked `_start` in `.text.boot`, packed 16-aligned GDT in `.gdt`, port I/O and `cpuid`
through asm, volatile VGA MMIO, naked ISR stub, `#noredzone`) is built for `x86_64-unknown-none-elf` with `-sse +soft-float`, the kernel code model and
`kernel.ld`; the image is inspected (entry `0x100000`, no undefined symbol, GDT bytes, no SSE register), not run: there is no QEMU here.

## Linkage, extern and exported globals

* `pub` on a `def` / `global` marks it visible to the linker. The lowering sets `pub` for Pride `pub`, `main`, `_start`, `#export`, `#used`,
  `#section`, `#naked` and `#callconv` items; lambdas, adapters, handler arms and effect cells are not `pub`. By default `emit-ll` keeps every symbol external;
  `emit-ll --internalize` gives every non-`pub`, non-extern def and global (except `main`) `internal` linkage. A function that only assembly text names
  must therefore be `pub` or `#used` (the kernel image does this for `kmain`/`timer_isr`). Gated: corpus results are identical with and without it.
* `extern global [mut] NAME : T;` (no initialiser, V5 rejects one) declares storage defined elsewhere under exactly that symbol: libc's `environ`, a linker-script
  symbol (`__kernel_end`: only its address is meaningful), a symbol defined in assembly. Pride: `#extern("sym") let [mut] X : T`. A second declaration of the
  same symbol is the same storage. `#export("sym") let mut X : T = c` names a definition's symbol exactly.

* Library mode (a module without `main`): the top-level functions and globals of the entry module are `pub` (Pride has no private marker for them; the
  stdlib declares no `pub` at all); everything reached from other modules is not. Stdlib objects at -O2: 805,424 bytes plain, 543,528 with `--internalize`.
  Checked on the objects by `tests/air3/internalize.sh` (nm letters).
* A function with `#callconv` used as a function value is called through an adapter that uses its own convention (`cc01`); its address as a raw pointer
  (`f as ptr`: IDT / vector tables) is just the address — calling a raw pointer uses the C convention, so that is the caller's affair.

## Verifier rule V5 (AIR level)

`airtool verify` checks, for modules whose header says `air 3.0`, the low-profile rules that need no LLVM: attribute names, arguments and targets
(table above, none twice, `inline`/`noinline` not together), a `naked` def has no parameters and contains `asm`, an `x86_intr` signature, data is a
single-constructor non-generic struct (no enum layout, no codata), atomic/fence orders in range, an `asm` has template, constraints and result type.
For these modules V2 accepts a jump to any label of the same def (the labels of a body are one control-flow graph). `airtool lint` must report 0 for every
rule (a single-constructor `data` is the layout, not H8). Gated: `tests/air3/bad_verify/` (13 rejected files), every `good/*.air`, every program of the corpus
and every stdlib module go through `verify` and `lint` as well as `verify-low`.

## Consumer limits (air_ll)

16384 names, 4096 blocks, 16384 phi edges and 8192 strings per function/module; aggregates ≤ 64 parts;
calls ≤ 16 arguments; types: tuples and arrow domains ≤ 16 elements. A violation is a *diagnostic*, never a
silent truncation.

## Not lowered (producer reports a diagnostic instead of a file)

See `docs/pear2/AIR3_PLAN.md` §3 for the current list.
