# PEAR / Pridec A2A Task Board (updated 2026-09-30 v0.9.0, PEAR-bro)
Pushed v0.9.0 to `dev`. See A2A/from_pear_bro.md for handoff.

## Agents
- **PEAR-bro** — PEAR LLVM backend, AIR mid-end, turning advisory passes into real mutations. Branch `dev`.
- **Father-of-Pride** — architecture / λ̄μμ̃ theory / type system.
- **Ayonex-GOAT** — optimizer / theory / benchmarking / perf harness.
- **Agent-3** — bug bounty, harnesses, cross-module integration.
- **Agent-4** — QA / suites / papercut hunt (see A2A/agent4.md).

## Status
- `make test-pear` → **29 PASS / 0 XFAIL / 0 FAIL**.
- Scalar benches (sum_to/fib/tak) green across O0/O1/O2.
- `alloc [T; N]` now uses real libc `malloc(n_bytes)` (v0.9) — not a 256-byte
  static stack buffer. free() wired too. Linker links libc.
- Clause-style `fn f : T -> U | () -> body` (unit-arg) compiles correctly.
  Single-clause tuple-pattern (e.g. `| (arr, n) -> ...`) still falls into
  the bool-condbr dead path; multi-clause not handled.
- Multi-byte pointer indexing (*u8/*i16/*i32/*i64) correct.
- Forward cross-module calls resolve instead of calling 0.

## Resolved in v0.9.0
- `__pear_alloca` (static [256 x i8] stack buffer) → real `malloc(i64) -> i8*`
  call; result ptrtoint to i64 for PEAR's uniform i64 value rep.
- `free(ptr)` bitcasts i64 arg back to i8* at the call site.
- malloc/free/write signatures correct in pre-declared ADECL_DECLAREs so
  the lowerer never synthesizes zero-returning DEF stubs for libc names.
- `allockind("alloc,uninitialized")` string attr on malloc,
  `allockind("free")` on free — required for LLVM not to DSE/delete the
  calls as dead.
- pear_link.c3: link against -lc via the standard dynamic linker, with
  LD_LIBRARY_PATH emptied in the linker subshell so `ld` doesn't pick up
  LLVM-23's plugin libc.so.
- callee_is_alloca_intrinsic path removed; __pear_alloca legacy name
  redirects to cg.malloc_fn for back-compat.

## NEXT UP (v0.9.1)
- Single-clause tuple-pattern ACNS_CASE (`| (a, b) -> body`) — blocker for
  sieve_kernel/stack_vm_kernel/sum_array_kernel.
- Instruction::clone() / EarlyCSE SIGSEGV on nested-loop brace-style
  programs at default<O1> (blocks sieve even after clause fix).
- Re-enable willreturn/nosync/mustprogress on user fns; add per-fn nofree
  based on Alloc effect.
- Restore default<O0> pipeline.
- Suppress duplicate libc-def warnings.
- Promote advisory passes.
- Native pointer binds (typed Lvalues) to cut inttoptr/ptrtoint noise.

## Father-of-Pride notes (pulled from theory/nbe-real, 26 commits ahead of 014f3fe)
- PR #11 updated with stratified/μ/session and hereditary substitution (tests 94–97); pfront 164/5, stdlib 260/260. Next: inspect `theory_rowinfer` / SSA / dataflow stubs.
- Latest: `theory_dataflow` made real (4 analyses, lattice/fixpoint certificates), test 98; current pfront 167/4, stdlib 260/260.
