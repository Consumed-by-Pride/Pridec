# PEAR 2 implementation plan

## Objective

Build a separate backend that reads the canonical, **untyped AIR 2.x text** emitted by `pfrontc --emit-air` and emits LLVM bitcode (`.bc`). PEAR 2 is not `air_ll`, not PEAR 1, and not part of `pfrontc`. It must operate solely on the AIR file and its own documented runtime/target inputs.

Pride is untyped by design. AIR may carry optional type hints, but PEAR 2 must not require complete source type inference. Where machine representation is needed, PEAR 2 must infer it from AIR operations, ABI declarations, and optional hints under explicit rules; ambiguity must be diagnosed rather than silently guessed. Default scalar and ABI rules must be specified in the AIR/PEAR contract, not invented ad hoc in the backend.

## Non-goals

- Do not make AIR 3's typed low profile the PEAR 2 input contract.
- Do not consume PNode, compiler internals, or side-channel metadata from `pfrontc`.
- Do not reuse PEAR 1 as PEAR 2's implementation. PEAR 1 may be used as a differential oracle on cases it handles.
- Do not claim language support because the parser accepts a form or the emitter prints it.

## Architecture

`pfrontc` → canonical `.air` → PEAR 2 reader/validator → AIR semantic analysis and representation inference → PEAR IR → optimization/lowering → LLVM module → verified `.bc`.

The PEAR 2 executable must:

1. Read only `.air`; reject malformed/unsupported versions and invalid AIR.
2. Re-check all backend-relevant invariants, including name binding, control-flow targets, ABI, and machine representation. AIR claims are untrusted input.
3. Fail closed: unsupported or ambiguous constructs produce a diagnostic, nonzero exit, and no output artifact. A stale artifact must not survive failure.
4. Write LLVM bitcode atomically. Verify the LLVM module before publication.
5. Be deterministic for a fixed AIR file, target, and optimization level unless the contract explicitly permits nondeterminism.

Shared AIR reader/verifier code may be linked as a library. The backend itself remains a separate executable and process.

## Milestones

### M0 — Contract and executable boundary (bootstrap slice implemented)

- Record the target architecture, file format, constraints, and acceptance gates.
- Add a standalone `pear2c` command and an independently runnable test target.
- Initial vertical slice: zero-argument `main` returning an integer literal, with a verified LLVM bitcode artifact.
- This slice is a bootstrap probe, not a claim that AIR or PEAR 2 is complete.

### M1 — Scalar lambda-bar/mu-mu-tilde fragment (in progress)

Implemented scalar slice: i8/i16/i32/i64/i128, char, f32/f64, bool, opaque pointers, and unit returns; integer/floating arithmetic and comparisons; integer, float, bool, and pointer coercions; `mu~`, `comu`, `let`, direct calls, returns, and source-order evaluation. Unannotated internal definitions now infer simple return representations from direct returns, `if`/`match` branches with a common result, and annotated parameters; untyped integer expressions use the function's default integer width. If this limited analysis cannot establish a result, it falls back to signed i64. An omitted/infer parameter uses an explicit integer result type when available, otherwise signed i64. External declarations still require explicit scalar ABI types. Narrow i8/i16 ABI values use signext/zeroext; unsigned operations select unsigned LLVM opcodes. Remaining work includes body-driven inference/overflow/division rules, target-specific ABI verification, and differential runtime tests.

### M2 — Control flow (partial; in progress)

Implemented subset: local nested tuple/fixed-array construction, constant aggregate projection, recursive bind/wild/trailing-rest aggregate patterns, scalar literal or-patterns and aliases plus one-arm aggregate aliases, and fixed-byte literals; internal direct-call tuple/array arguments and returns; aggregate label/jump parameters; terminal `if`/`else`; integer/boolean/char `match` lowered to LLVM `switch` with a required final default arm; f32/f64 matches use ordered equality tests; scalar guarded matches route boolean guard commands through the implicit `%guard` continuation, preserving ordered tests and guard-false fallthrough for the command forms PEAR2 lowers; tuple/array bind/wild destructuring arms can use guards with ordered fallthrough; structured `while` loops with header, body, exit, and backedge blocks; and bounded `for` iteration over fixed arrays, including nested loops, with stack save/restore around temporary aggregate copies. Label arguments use typed entry-block allocas and loads rather than SSA phi nodes. Jumps reject changed captured bindings that were not passed explicitly. Outstanding: whole-CFG reachability/termination validation, phi promotion, literal/nested aggregate guards and constructor patterns, and broader loop/control-flow coverage; `break`/`continue` transfers are currently limited to captured zero-parameter labels.

### M3 — Data and ABI (narrow scalar extern slice implemented)

Implemented narrow scalar C ABI support for i8/i16/i32/i64/i128, f32/f64, char, bool, opaque pointers, and unit/void returns. Internal definitions additionally support tuple/fixed-array aggregate parameters and returns; external declarations remain scalar-only and conflicting C symbol ABIs are rejected. Numeric coercions include integer width changes, signed/unsigned integer↔float conversion, f32/f64 widen/narrow, pointer↔integer conversion, and bool/integer conversion. Integer arithmetic uses width/signedness-selected LLVM operations; floating arithmetic/comparison has explicit opcodes. Pointer memory covers bool, integer, float, pointer, and small nested-array values with 1/2/4/8-byte AIR widths and `align 1`; integer stores explicitly truncate or extend to the destination width, while untyped integer constants must fit. Pointer indexing supports dynamic signed/unsigned indices with width conversion; fixed-array values are bounded to 1,024 elements. Scalar and fixed-array `sizeof`, supported scalar/empty-aggregate `alignof`, assertions, assumptions, and traps are lowered. Called varargs, fastcc, attributed, generic, and aggregate external declarations fail closed. Outstanding: pointer provenance/ownership policy, records, data/codata constructors, fields, globals, general target data layout, and broad C ABI interoperability. LLVM execution and ABI interoperability remain unverified in this environment.

### M4 — Closures, data types, effects, staging

Implement each feature only after its AIR representation and semantics are complete. For effects, specify continuation semantics and runtime requirements (one-shot/multi-shot, target support); for staging, specify residualization. Unsupported forms remain hard errors until implemented.

### M5 — Optimization (first conservative AIR pass integrated; validation incomplete)

`pear2/pear2_opt.c3` currently removes same-representation integer/bool/float coercions and folds checked integer and boolean/integer constant coercions plus add/subtract/multiply/divide/remainder, bitwise operations, and in-range shifts (arithmetic versus logical right shift follows signedness); rewrites typed multiplication by a positive power-of-two constant on either operand side to a same-width left shift, unsigned division by a power of two to a logical right shift, and unsigned remainder by a power of two to a bit mask, remainder by one and multiplication by zero to input-preserving zero-mask `AND` operations, using fresh AIR literals where needed; combines nested same-kind shifts when both counts and their sum remain below the resolved width; folds integer comparisons and unary signed negation/bitwise-not/boolean-not, and cancels double-not only when the inner and outer representations agree; applies representation-compatible integer identities including typed all-ones `AND`, multiply-by-all-ones to negation, integer `XOR`-to-bit-not rewrites, and zero-valued `OR`/`XOR` identities in either operand order; boolean `XOR true` becomes `NOT`, and equality/inequality with literal booleans reduces to the value or `NOT`; selects literal-boolean `if` branches, specializes a folded boolean `let` inside its immediate pure `if` condition and an integer `let` inside an immediate pure return/cut expression, retaining both bindings for any other uses. Rewrites preserve product identity/type metadata, respect signed/unsigned comparisons and narrow unsigned complement, reject host overflow, incompatible operand representations, out-of-range constants, divide-by-zero, signed minimum divided by negative one, and unrepresentable narrow results. After optimization, PEAR2 refreshes AIR facts and re-runs the AIR verifier; `-O1` runs one pass, `-O2` iterates up to four times, and `-O3` up to eight times until a pass reports no rewrites; `-O0` disables rewriting. `--stats` exposes passes, total rewrites, and categorized fold, operand, strength-reduction, shift-combination, branch, and let-specialization counts. A standalone structural harness covers same-representation integer/bool/float coercion elimination and signedness rejection, typed identities including boolean `XOR true` polarity and left/right zero-operand cases, multiply/divide/modulo power-of-two strength reduction, input-preserving remainder-by-one and multiply-by-zero, and signed/non-power-of-two rejection, signed/logical/left shifts, boolean and integer let specialization, comparison/branch choice, unary folds and double-not type mismatches, narrow overflow/division hazards, mixed widths, and out-of-range constants; backend fixtures check `-O0`, `-O1`..`-O3` output, stats, and fixed-point convergence. `make check-pear2` automates C3 check-only validation of the backend and structural harness without LLVM. In this environment that target passes, but LLVM-enabled harness execution, backend fixtures, and differential/end-to-end validation remain unrun. This is groundwork, not a completed optimizer: finish translation-validation or differential tests and a semantics audit before adding aggressive data-flow transformations. LLVM optimization remains optional downstream and must not conceal producer/backend miscompiles.

### M6 — Release criteria

- Zero known AIR validity violations in the supported source corpus; exact fixture-ledger checks.
- AIR writer/reader structural round-trip across the corpus.
- Source → AIR → PEAR 2 → `.bc` → LLVM verify/run agrees with expected behavior for every supported case and optimization tier.
- Every unsupported source construct is rejected before a misleading `.air`/`.bc` artifact is published.
- Cross-target and ABI tests for every claimed target; determinism and stale-artifact tests.
- PEAR 1 differential results are supplemental; expected outputs and semantic tests are authoritative.

## Completion-size estimate

These are planning ranges, not a line-count acceptance gate. The current PEAR 2 driver is just over 2,000 lines and implements the narrow, fixture-backed scalar/control-flow/aggregate/memory subset described below. For the full AIR 2.x backend scope in M0–M6, a reasonable estimate is **18K–25K lines of production PEAR 2 code**, excluding the shared AIR reader/verifier and excluding tests. The approximate allocation is: representation inference and backend validation 2K–4K; LLVM module/CFG/SSA and scalar lowering 4K–6K; data layout, memory, and ABI 4K–6K; runtime/effects/staging support 3K–5K; optimizer and target/driver infrastructure 3K–4K. A meaningful fixture, differential, and end-to-end test suite could add another 8K–15K lines, depending on how much source corpus and generated test data is checked in. These ranges assume unsupported language/runtime semantics are specified rather than hidden behind a code-size target. A count above 15K alone would not mean the backend is complete.

## Current bootstrap boundaries

`pear2/pear2c_main.c3` supports signed/unsigned integer arithmetic through i128, f32/f64 arithmetic/comparison/conversions, Unicode scalar chars, bools, opaque pointers, and unit values. It lowers internal scalar and tuple/fixed-array function ABIs; tuple/array values can also cross label/jump edges. Local aggregates support nested tuple/array construction, tuple projections, array indexing/projection, recursive bind/wild patterns with trailing rest, and fixed i8 byte/string literals with optional NUL/zero fill. Fixed arrays are bounded to 1,024 elements (recursive patterns retain the parser's branch/element bounds). Pointer memory supports typed loads/stores for bool, integer widths through 64, f32/f64, pointers, and small nested arrays; integer stores truncate/extend to the requested pointee width, while untyped constants must fit. `index` width is limited to AIR's 1/2/4/8-byte forms. Dynamic indices are converted to i64 with signed/unsigned extension or truncation. Integer↔float, f32↔f64, pointer↔integer, and integer↔bool coercions are explicit; float↔bool remains unsupported. Scalar/fixed-array `sizeof`, supported scalar/empty-aggregate `alignof`, `assert`, `assume`, and `trap` lower to LLVM.

External C signatures remain scalar-only; aggregate ABI is allowed only for internal AIR definitions. Unsupported declaration forms, records/data constructors, indirect calls, unsupported pointer widths/layouts, guarded aggregate/constructor matches, parameterized `break`/`continue` targets, jumps/labels in functions that use `for` (to preserve stack restoration), transfers out of a `for` body, and incomplete CFG shapes fail closed. `main` must remain zero-argument i64. Arithmetic is emitted without `nsw`/`nuw`; the backend does not yet define a complete cross-target integer/layout contract. It invokes LLVM parse/verify/bitcode APIs in normal builds and publishes output atomically. In this environment only C3 `-C` compilation was available; LLVM-backed PEAR2 build, bitcode verification, runtime execution, and C ABI interoperability were not run. Existing regression fixtures are prepared for those gates.
