# PEAR 2 — start here

PEAR 2 is the planned separate backend: **untyped AIR 2.x text in, LLVM bitcode out**. It starts at a `.air` file and nowhere else. It is not `air_ll` (the AIR 3 low-profile reference consumer) and does not share `pfrontc`'s AST.

Implementation is a bootstrap backend with a fixture-covered subset of M1–M3: i8/i16/i32/i64/i128 plus unannotated internal scalar definitions under documented defaults, Unicode scalar `char`, f32/f64, bool/pointer/unit; integer/float arithmetic and conversions; direct internal aggregate calls/returns for tuples and fixed arrays up to 1,024 elements; local tuple/array construction and destructuring; pointer indexing, dereference, and stores for supported 1/2/4/8-byte elements, with integer values converted to the stored width; scalar/array size and scalar alignment queries; terminal branches, integer/boolean/char switch matches, f32/f64 matches, scalar and tuple/array bind/wild guards, structured `while` loops, fixed-array `for` loops, zero-parameter `break`/`continue` label transfers, label/jump edges, assertions, assumptions, and traps. String/byte literals are supported as explicitly typed fixed i8 arrays, not C strings or heap strings. External C ABIs remain scalar-only; aggregate function ABIs are restricted to internal definitions. `pear2/pear2c_main.c3` consumes canonical AIR 2.x text and emits verified LLVM bitcode; unsupported forms fail closed. This is not a complete or production-ready backend: whole-CFG checks, broad data/ABI coverage, a full optimization pipeline, and LLVM-backed execution coverage remain outstanding. A first conservative AIR optimizer removes same-representation integer, bool, and float coercions, folds checked integer coercions and i64-range constants; lowers typed multiplication by a power of two on either operand side to a same-width left shift, unsigned division by a power of two to a logical right shift, and unsigned remainder by a power of two to a bit mask; rewrites remainder by one and multiplication by zero to zero-mask `AND` operations that retain the input; composes nested same-kind shifts when their combined count stays in range; folds in-range shifts and comparisons; folds selected integer unary operations and boolean-not, and cancels representation-compatible double-not operations. Representation-matched integer identities include all-ones `AND`, integer `XOR`-to-bit-not, multiply-by-all-ones to negation, and zero-valued `OR`/`XOR` in either operand order; boolean `XOR true` becomes `NOT`; equality and inequality against literal booleans reduce to the value or `NOT`. The optimizer also specializes immediate pure `if` conditions from folded boolean lets and pure return/cut expressions from integer lets, retaining bindings for other uses, and reduces literal boolean branches. `-O1` runs one pass, `-O2` iterates up to four times, and `-O3` up to eight times until a pass makes no rewrites; `-O0` disables AIR optimization. `--stats` reports the pass count, total rewrites, and fold, operand, strength-reduction, shift-combination, branch, and let-specialization counts. The pass is re-verified by the shared AIR verifier. `make check-pear2` runs C3 check-only compilation for the backend and structural harness without LLVM; `make test-pear2` adds executable optimizer and LLVM bitcode regression tests and therefore requires an LLVM-enabled C3 build. See [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for exact limits and exit criteria.

The front end (`pfrontc`) ends at `.air` and links no LLVM. PEAR 1 lives frozen in `legacy/pear1/`; it is a regression reference, not PEAR 2's implementation.

| you need | where |
|---|---|
| the file format (grammar, scope, meaning of every form, conventions) | [`docs/specs/AIR.md`](../specs/AIR.md) |
| the backend's obligations and CLI | [`CONTRACT.md`](CONTRACT.md) |
| which forms real programs use, how often | [`COVERAGE.md`](COVERAGE.md) (generated; `python3 scripts/air-coverage.py`) |
| the expected behaviour of ~80 programs | `tests/exec/*.pie`, `tests/exec/pear/*.pie` (`-- EXPECT:` / `-- EXIT:` markers), `tests/exec/XFAIL.tsv` |
| a parser/printer you can reuse or test against | `pfront/pear_ir/air_read.c3`, `air_write.c3`; `airtool check|fmt|verify` |
| the old backend as a worked example | `legacy/pear1/pear.c3` (2200 lines, name-pattern based — a reference, not a model) |

## Five-minute start

```sh
make                       # pfrontc  (no LLVM needed)
make airtool               # tmp/airtool
make legacy-pear           # legacy/pear1/pear1c  (needs LLVM 23: ~/.cache/llvm23)
make pear2c                # pear2/pear2c bootstrap subset (needs LLVM C API)
make test-pear2            # fixture checks + fail-closed tests

./pfrontc tests/exec/pear/p03_fib.pie --emit-air     # writes tests/exec/pear/p03_fib.air  (whole program, ~270 KB)
tmp/airtool verify tests/exec/pear/p03_fib.air       # validity rules, conventions counted
legacy/pear1/pear1c tests/exec/pear/p03_fib.air --emit-exe -O2 && tests/exec/pear/p03_fib; echo $?    # 55
```

## Plugging PEAR 2 into the suites

Any program with the CLI of [`CONTRACT.md`](CONTRACT.md) §1 runs the whole existing gate:

```sh
BACKEND=/path/to/pear2c XFAIL_FILE=tests/exec/XFAIL.pear2.tsv bash tests/exec/run.sh        # exec suite
BACKEND=/path/to/pear2c bash tests/exec/pear/run.sh                                          # PEAR smoke suite
PEAR_OPT=-O0 BACKEND=... bash tests/exec/run.sh                                              # tiers: -O0..-O3
```

`XFAIL_FILE` is *your* list of known failures (copy `tests/exec/XFAIL.tsv` and edit). A case that starts passing
is reported XPASS and fails the run, so the list can only shrink honestly.

## Suggested order (from COVERAGE.md; each step is testable on real output)

1. Scalar functions: `def`, `mu~ %ret`, cuts, `(op a b)`, `if`, direct `call`, `let`, `comu`, `seq` → `p01`–`p04`, `p05`.
2. Control flow: `label`/`jump`, the `%kN` joins (J1), mutable rebinding (A1) → loops and `p`-suite.
3. Memory/data next: general bounds/layout policy, `field`, heap allocation and ownership, and external string/aggregate ABIs. The current subset covers typed pointer index/load/store and local fixed arrays, but not allocator/runtime integration or records.
4. Data next: constructor-tagged `data`/`codata`, guarded matches, records, and broader aggregate ABI rules. Local tuples/fixed arrays and recursive bind/wild/rest patterns are currently supported.
5. `syscall` — **blocked on the front end**: the lowering currently drops its operands (AIR.md §11.1); fix that first.
6. Effects and staging: front end emits them, nobody executes them yet (ledger P04–P06).

Rule of the road: **a form you do not implement must produce a diagnostic and a non-zero exit, never a binary that
quietly does something else.** The old backend's silent fall-backs (a call to address 0, an ignored `syscall`) are
exactly the bugs this rule prevents.
