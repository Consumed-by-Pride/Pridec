# PEAR 2 — start here

PEAR 2 is the separate backend: **untyped AIR 2.x text in, native executable by default, or LLVM bitcode with `--emit-bc`**. It starts at a `.air` file and nowhere else; `pfrontc` remains LLVM-free. It is not `air_ll` (the AIR 3 low-profile reference consumer) and does not share `pfrontc`'s AST.

Implementation is a bootstrap backend with a fixture-covered subset of M1–M3 + machine forms: i8/i16/i32/i64/i128 plus unannotated internal scalar definitions under documented defaults, Unicode scalar `char`, f32/f64, bool/pointer/unit; integer/float arithmetic and conversions; direct internal aggregate calls/returns for tuples and fixed arrays up to 1,024 elements (including empty tuples and unit fields/parameters); nested local tuple/array construction, destructuring, and projection (including direct-return projections); pointer indexing, dereference, and stores for supported 1/2/4/8-byte elements, with integer values converted to the stored width; scalar/array size and scalar alignment queries; terminal branches, integer/boolean/char switch matches, f32/f64 matches, scalar and tuple/array bind/wild guards, structured `while` loops, fixed-array `for` loops, zero-parameter `break`/`continue` label transfers, label/jump edges with mutable captured locals stored across backedges, assertions, assumptions, and traps. String/byte literals are supported as explicitly typed fixed i8 arrays, not C strings or heap strings. Tagged sums lower end-to-end: nullary enums and payload-bearing multi-constructor data build via `con`, discriminate through `match` with `ctor` patterns and payload binding (a final wildcard arm is required today pending exhaustiveness proofs), and cross internal calls by value (sum_option64, sum_twofield, sum_enum_default fixtures execute 42 across -O0..-O3); sums reject with a source position at external C boundaries. External C ABIs carry scalars plus by-value non-empty tuples and plain product records with C-compatible field layouts; unsupported shapes fail closed with positioned diagnostics. AIR machine forms lower too: `fence` (acquire and stronger; `relaxed` fences are rejected by the AIR verifier), `atomic` read-modify-write/load/store and `cmpxchg` over AIR 3 typed integer pointees (8/16/32/64-bit; cmpxchg's single AIR ORDER supplies the success ordering and is weakened to the strongest legal failure ordering, so a `release` or `acq_rel` compare degrades to `monotonic`/`acquire` on the failure path, and its result is the old value), raw x86-64 Linux `syscall` through pinned-register inline asm (rejected under the freestanding wasm32 profile), and inline `asm` with the AIR 3.0 template/constraints/result ascription over integer/float/pointer operands and scalar-or-unit results (bool results rejected). The machine-form fixtures (atomic_fence_main, atomic_cmpxchg_main, syscall_main, asm_main) emit, verify, and execute at 42 across -O0..-O3. `pear2/pear2c_main.c3` consumes canonical AIR 2.x text, builds and verifies an LLVM module, and generates machine code with LLVM's own backend in process; the default mode links that object with `ld` into a native executable, `--emit-obj` publishes the object, `--emit-bc` the verified `.bc`, and `--emit-ll` the textual IR the code was produced from. `clang` is not needed to compile; `PEAR2_LINK=clang` only swaps the linker driver; unsupported forms fail closed. This is not a complete or production-ready backend: whole-CFG checks, broad data/ABI coverage, a full optimization pipeline and LLVM-backed execution coverage beyond the fixture-tested subset remain outstanding. A first conservative AIR optimizer removes same-representation integer, bool, and float coercions, folds checked integer and boolean/integer constant coercions plus i64-range constants; lowers typed multiplication by a power of two on either operand side to a same-width left shift, unsigned division by a power of two to a logical right shift, signed division by a positive power of two to an arithmetic shift with a truncation bias for SSA-variable dividends, signed remainder for SSA-variable dividends by a positive power of two via `x - (trunc(x / d) * d)`, and unsigned remainder by a power of two to a bit mask; rewrites remainder by one and multiplication by zero to zero-mask `AND` operations that retain the input; composes nested same-kind shifts when their combined count stays in range; folds in-range shifts and comparisons; folds selected integer unary operations and boolean-not, and cancels representation-compatible double-not operations. Representation-matched integer identities include all-ones `AND`, integer `XOR`-to-bit-not, multiply-by-all-ones to negation, and zero-valued `OR`/`XOR` in either operand order; boolean `XOR true` becomes `NOT`, and logical `LAND true`/`LOR false` identities retain the other operand; equality and inequality against literal booleans reduce to the value or `NOT`. The optimizer also specializes immediate pure `if` conditions from folded boolean lets, propagates integer constants through one immediate nested pure integer-let initializer and into pure return/cut expressions, retaining bindings for other uses, and reduces literal boolean branches. `-O1` runs one pass of expression folding only, `-O2` adds pass 2 and iterates up to four times, and `-O3` iterates up to eight times until a pass makes no rewrites; `-O0` disables AIR optimization. Pass 2 deletes dead `let` bindings whose value is inert (a literal or a variable) and whose name occurs nowhere else in the body. It refuses whenever the name also appears as a binder, match-pattern binder, covariable, jump argument, label, or substitution entry, or as the name of a non-variable producer — the test is name-absence-elsewhere rather than a use count, so shadowing cannot fool it. Copy propagation is deliberately not done: PEAR 2 lowers mutable locals to allocas, so `let x = y` is a snapshot of a load and renaming the uses would observe later writes, and an alias costs no instructions anyway because the emitter binds AIR names to SSA values. `--stats` reports the pass count, total rewrites, the fold, operand, strength-reduction, shift-combination, branch, and let-specialization counts, and the pass-2 `dead` count. The AIR pass is re-verified by the shared AIR verifier after optimization, and the optimized module is verified again as LLVM IR before it is written. On top of the AIR passes, `-O1`/`-O2`/`-O3` also run in-process LLVM IR optimization (`default<O1|O2|O3>`, inliner threshold 250) through `LLVMRunPasses`, so mem2reg/SROA slot promotion, instcombine, GVN, inlining, loop optimisation, and IR-level dead-code elimination all happen in the producer; at `-O0` neither layer runs and the emitted bitcode is exactly what PEAR 2 lowered. `make check-pear2` runs C3 check-only compilation for the backend and structural harness plus an LLVM-independent arithmetic model test; `make test-pear2` adds executable optimizer and LLVM bitcode regression tests and therefore requires an LLVM-enabled C3 build. See [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for exact limits and exit criteria.

The front end (`pfrontc`) ends at `.air` and links no LLVM. PEAR 1 lives frozen in `legacy/pear1/`; it is a regression reference, not PEAR 2's implementation.

| you need | where |
|---|---|
| the file format (grammar, scope, meaning of every form, conventions) | [`docs/specs/AIR.md`](../specs/AIR.md) |
| the backend's obligations and CLI | [`CONTRACT.md`](CONTRACT.md) |
| which forms real programs use, how often | [`COVERAGE.md`](COVERAGE.md) (generated; `python3 scripts/air-coverage.py`) |
| what is still refused, and what the optimizer cannot do | [`GAPS.md`](GAPS.md) |
| the expected behaviour of ~80 programs | `tests/exec/*.pie`, `tests/exec/pear/*.pie` (`-- EXPECT:` / `-- EXIT:` markers), `tests/exec/XFAIL.tsv`; PEAR2-supported subset in `tests/exec/pear2_cases.txt` |
| a parser/printer you can reuse or test against | `pfront/pear_ir/air_read.c3`, `air_write.c3`; `airtool check|fmt|verify` |
| the old backend as a worked example | `legacy/pear1/pear.c3` (2200 lines, name-pattern based — a reference, not a model) |

## Five-minute start

```sh
make                       # pfrontc  (no LLVM needed)
make airtool               # tmp/airtool
make legacy-pear           # legacy/pear1/pear1c  (needs LLVM 23: ~/.cache/llvm23)
make pear2c                # ./pear2c -> pear2/pear2c (needs LLVM 23 C API + clang)
make test-pear2            # requires C3/LLVM 23; parses, verifies, links, and runs fixtures
make test-pear2-exec       # required supported scalar/control/call cases through both exec runners

./pfrontc tests/exec/pear/p03_fib.pie --emit-air     # writes tests/exec/pear/p03_fib.air
./pear2c tests/exec/pear/p03_fib.air --emit-exe -O2 # writes an executable (default mode)
tests/exec/pear/p03_fib; echo $?                     # 55
./pear2c tests/exec/pear/p03_fib.air --emit-bc -O2  # writes tests/exec/pear/p03_fib.bc
```

## Plugging PEAR 2 into the suites

Any program with the CLI of [`CONTRACT.md`](CONTRACT.md) §1 runs the whole existing gate:

```sh
BACKEND=./pear2c bash tests/exec/run.sh       # config matrix + PEAR2-supported scalar/control/call cases
BACKEND=./pear2c bash tests/exec/pear/run.sh  # same expected-value cases through the PEAR runner
PEAR_OPT=-O0 BACKEND=... bash tests/exec/run.sh                                              # tiers: -O0..-O3
```

`XFAIL_FILE` is *your* list of known failures (copy `tests/exec/XFAIL.tsv` and edit). A case that starts passing
is reported XPASS and fails the run, so the list can only shrink honestly.

## Suggested order (from COVERAGE.md; each step is testable on real output)

1. Scalar functions: `def`, `mu~ %ret`, cuts, `(op a b)`, `if`, direct `call`, `let`, `comu`, `seq` → `p01`–`p04`, `p05`.
2. Control flow: `label`/`jump`, the `%kN` joins and mutable rebinding (J1/A1; `p04` and `p07` now run) → broader CFG validation and loop coverage.
3. Memory/data next: general bounds/layout policy, `field`, heap allocation and ownership, and external string/aggregate ABIs. The current subset covers typed pointer index/load/store and local fixed arrays, but not allocator/runtime integration or records.
4. Data next: constructor-tagged `data`/`codata`, guarded matches, records, and broader aggregate ABI rules. Local tuples/fixed arrays and recursive bind/wild/rest patterns are currently supported.
5. `syscall` — **blocked on the front end**: the lowering currently drops its operands (AIR.md §11.1); fix that first.
6. Effects and staging: front end emits them, nobody executes them yet (ledger P04–P06).

Rule of the road: **a form you do not implement must produce a diagnostic and a non-zero exit, never a binary that
quietly does something else.** The old backend's silent fall-backs (a call to address 0, an ignored `syscall`) are
exactly the bugs this rule prevents.

### Phi and closure fixtures

`phi_*` fixtures assert multi-block SSA promotion at joins and loop headers
(phi presence, alloca caps, `-O0..-O3` exit-code equality, a positioned 16-edge
overflow rejection). `closure_*` fixtures exercise M8 first-class closures:
scalar capture, multi-variable capture, nested closure invocation through the
`{ code, env }` fat-pointer ABI, and positioned fail-closed rejections for
loop-body creation and capturing label-carried bindings.

## M10: target profiles and escape-only effects

- `--target=x86_64` (default) / `--target=wasm32-freestanding` select the
  emitted module's datalayout/triple and the `isz`/`usz`/pointer widths.
- `fastcc`, `attr callconv`, `attr export`, `attr section`, and the
  optimization hint attributes (`noinline`, `alwaysinline`, `cold`, `naked`)
  are preserved on definitions and their call sites; unsupported combinations
  are positioned errors, never silent drops.
- Linkage follows the same visibility rule: a definition or global that is
  not `pub`, is not `main`/`pride_main`/`_start`, and carries no `export` or
  `section` attribute can only be named from inside this module, so it gets
  `internal` linkage and LLVM may inline it everywhere and drop it when
  unused. `--emit-exe` (where PEAR 2 links the whole program itself) does
  this by default, `--internalize`/`--no-internalize` override it either way,
  and `--emit-bc`/`--emit-obj`/`--emit-ll` stay external by default because
  the object is handed to a linker that may resolve any symbol. A symbol
  that only inline-asm text names must be `pub` or `#export`ed. `--stats`
  reports the effective policy as `linkage=internal|external`.
  Fixture: `linkage_internal_main.air`.
- One-shot (escape-only) effect handlers lower to payload slots plus
  branch-to-arm control flow; anything resuming or multi-shot, handler-less
  performs, and all effect forms under wasm32-freestanding reject with; object/link end-to-end is gate-checked in run.sh (`PASS: wasm32-freestanding bitcode compiled and linked by pinned toolchain`)
  file:line:col diagnostics. Fixtures: `fx_escape_main.air`,
  `fx_join_fallthrough_main.air`, `abi_callconv_export_main.air`,
  `target_profile_main.air`, and `reject_{fx,abi,wasm32}_*_main.air`.
