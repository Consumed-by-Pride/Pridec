# PEAR-bro handoff — v0.9.1 (2026-10-01)

Bruh, multi-arg clause fns are wired for the simple expr-bodied case.

## What changed
1. `AirLower.reg_clause_pat_params` (file-scope helper, C3 disallows nested fns)
   recurses N_PAT_TUPLE and registers each leaf as an AirDecl param, fixing
   arity for `fn add : (i64,i64)->i64 | (a,b) -> a+b`.
2. The clause-param registration loop in `decl_fn` now uses it; thunk-wildcard
   detection is scoped to the clause (not per-pattern).
3. ccnt==1 multi-param fast path: body is a single expr child → emit directly
   via `lr.expr_to_cns(body, lr.cns_k(ret))` WITHOUT building a match and
   WITHOUT `lr.scope.enter()`/`lr.pat` (which would shadow-rename params).
4. Nullary (0-param) defined fns referenced as values are now emitted as
   0-arg calls (e.g. `PAGE_SIZE`, `NULL`) so arithmetic/args get an i64
   instead of the fn pointer. Fix uses `LLVMGlobalGetValueType` +
   `LLVMCountParamTypes` to detect 0-param fns; malloc/free/write are
   excluded from implicit 0-arg calls.

## Results
- `add(3,4)` returns 7 (exit code 7).
- `make test-pear`: 29/0/0 (unchanged).
- Scalar benches: sum_to→0, fib→200, tak→100 (unchanged).

## Known limitations / next
- Multi-arg clause fns with a BLOCK body (e.g. `page_free | (p,n) -> { ... }`)
  still fall back to the legacy match path which UB-prunes to unreachable.
  Those fns appear live now (since param_count is correct) but their bodies
  still hit the bool-condbr single-pattern path; real fix is tuple-pattern
  dispatch in ACNS_CASE (so a multi-pat branch destructures each param into
  its slot without entering a new scope).
- Braceless `if cond then assign;` as a block tail still leaves the then-arm
  BB unterminated (ACMD_IF doesn't always thread back to the join). Didn't
  bite this time because only expr-bodied multi-arg fns use the fast path.
- Don't forget `chmod +x pfrontc` after rebuild, and always `rm -f pfrontc`
  before rebuild to dodge c3c incremental-link corruption (crashes on
  trivial `return 42` input when a stale object is linked against libLLVM).
- GitHub PAT is in the remote URL; don't commit tokens.
- ld invocation must clear LD_LIBRARY_PATH (see `pear_link.c3`) or it picks
  up LLVM's plugin libc.so.

Build: `bash scripts/agent3-env.sh` (when ~/.cache cleared) then
`bash scripts/agent3-build.sh`.
Test: `bash tests/exec/pear/run.sh` expects 29/0/0.
