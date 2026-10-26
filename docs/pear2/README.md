# PEAR 2 — start here

PEAR 2 is the separate backend: **untyped AIR 2.x text in, native executable by default, or LLVM bitcode with `--emit-bc`**. It starts at a `.air` file and nowhere else; `pfrontc` remains LLVM-free. It is not `air_ll` (the AIR 3 low-profile reference consumer) and does not share `pfrontc`'s AST.

Implementation is a bootstrap backend with a fixture-covered subset of M1–M3: i8/i16/i32/i64/i128 plus unannotated internal scalar definitions under documented defaults, Unicode scalar `char`, f32/f64, bool/pointer/unit; integer/float arithmetic and conversions; direct internal aggregate calls/returns for tuples and fixed arrays up to 1,024 elements (including empty tuples and unit fields/parameters); nested local tuple/array construction, destructuring, and projection (including direct-return projections); pointer indexing, dereference, and stores for supported 1/2/4/8-byte elements, with integer values converted to the stored width; scalar/array size and scalar alignment queries; terminal branches, integer/boolean/char switch matches, f32/f64 matches, scalar and tuple/array bind/wild guards, structured `while` loops, fixed-array `for` loops, zero-parameter `break`/`continue` label transfers, label/jump edges with mutable captured locals stored across backedges, assertions, assumptions, and traps. String/byte literals are supported as explicitly typed fixed i8 arrays, not C strings or heap strings. External C ABIs remain scalar-only; aggregate function ABIs are restricted to internal definitions. `pear2/pear2c_main.c3` consumes canonical AIR 2.x text, verifies and serializes LLVM bitcode, then links a native executable by default through LLVM 23 `clang`; `--emit-bc` publishes only the verified `.bc`; unsupported forms fail closed. This is not a complete or production-ready backend: whole-CFG checks, broad data/ABI coverage, a full optimization pipeline and LLVM-backed execution coverage beyond the fixture-tested subset remain outstanding. A first conservative AIR optimizer removes same-representation integer, bool, and float coercions, folds checked integer and boolean/integer constant coercions plus i64-range constants; lowers typed multiplication by a power of two on either operand side to a same-width left shift, unsigned division by a power of two to a logical right shift, signed division by a positive power of two to an arithmetic shift with a truncation bias for SSA-variable dividends, signed remainder for SSA-variable dividends by a positive power of two via `x - (trunc(x / d) * d)`, and unsigned remainder by a power of two to a bit mask; rewrites remainder by one and multiplication by zero to zero-mask `AND` operations that retain the input; composes nested same-kind shifts when their combined count stays in range; folds in-range shifts and comparisons; folds selected integer unary operations and boolean-not, and cancels representation-compatible double-not operations. Representation-matched integer identities include all-ones `AND`, integer `XOR`-to-bit-not, multiply-by-all-ones to negation, and zero-valued `OR`/`XOR` in either operand order; boolean `XOR true` becomes `NOT`, and logical `LAND true`/`LOR false` identities retain the other operand; equality and inequality against literal booleans reduce to the value or `NOT`. The optimizer also specializes immediate pure `if` conditions from folded boolean lets, propagates integer constants through one immediate nested pure integer-let initializer and into pure return/cut expressions, retaining bindings for other uses, and reduces literal boolean branches. `-O1` runs one pass, `-O2` iterates up to four times, and `-O3` up to eight times until a pass makes no rewrites; `-O0` disables AIR optimization. `--stats` reports the pass count, total rewrites, and fold, operand, strength-reduction, shift-combination, branch, and let-specialization counts. The pass is re-verified by the shared AIR verifier. `make check-pear2` runs C3 check-only compilation for the backend and structural harness plus an LLVM-independent arithmetic model test; `make test-pear2` adds executable optimizer and LLVM bitcode regression tests and therefore requires an LLVM-enabled C3 build. See [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for exact limits and exit criteria.

The front end (`pfrontc`) ends at `.air` and links no LLVM. PEAR 1 lives frozen in `legacy/pear1/`; it is a regression reference, not PEAR 2's implementation.

| you need | where |
|---|---|
| the file format (grammar, scope, meaning of every form, conventions) | [`docs/specs/AIR.md`](../specs/AIR.md) |
| the backend's obligations and CLI | [`CONTRACT.md`](CONTRACT.md) |
| which forms real programs use, how often | [`COVERAGE.md`](COVERAGE.md) (generated; `python3 scripts/air-coverage.py`) |
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
- One-shot (escape-only) effect handlers lower to payload slots plus
  branch-to-arm control flow; anything resuming or multi-shot, handler-less
  performs, and all effect forms under wasm32-freestanding reject with; object/link end-to-end is gate-checked in run.sh (`PASS: wasm32-freestanding bitcode compiled and linked by pinned toolchain`)
  file:line:col diagnostics. Fixtures: `fx_escape_main.air`,
  `fx_join_fallthrough_main.air`, `abi_callconv_export_main.air`,
  `target_profile_main.air`, and `reject_{fx,abi,wasm32}_*_main.air`.
