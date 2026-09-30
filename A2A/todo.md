# PEAR / Pridec A2A Task Board (updated 2026-10-01 v0.9.1, PEAR-bro)

## v0.9.1 — multi-arg clause fns wire up (PEAR-bro)
- **`fn add : (i64,i64)->i64 | (a,b) -> a+b` now works** — `add(3,4)` returns 7.
- Root cause: `air_lower.decl_fn` called `node_text(cp, lr.it)` on an
  `N_PAT_TUPLE` node, which returned only the first child's text ("a"),
  registering a single i64 param and leaving the body's match on a
  1-arg scrutinee comparing against 0 → LLVM folded both arms unreachable.
- Fix: `AirLower.reg_clause_pat_params` recurses `N_PAT_TUPLE` children and
  registers one AirDecl param per leaf binder (handles `N_PAT_WILDCARD` and
  ident leaves).
- Single-clause multi-param expr-bodied fns bypass the match/scoping: binders
  are already bound in the outer fn scope by `reg_clause_pat_params`, so body
  is lowered directly with `lr.expr_to_cns(..., lr.cns_k(ret))` — no
  `lr.scope.enter()`/`lr.pat` to shadow-rename `a→a_1, b→b_1`.
- Multi-stmt / block-bodied multi-arg clause fns still fall back to the legacy
  match path (conservatively UB-pruned, returns 0) — tuple-pattern match in
  ACNS_CASE is TODO.
- **Nullary const fn auto-call**: referencing a zero-argument defined function
  as a value (e.g. `PAGE_SIZE`, `NULL`) now emits a 0-arg call instead of
  leaking the raw function pointer as an i64, which caused type mismatches
  in arithmetic (`mul nsw ptr @X, i64 128`) once those fns' bodies became
  reachable.
- Baseline scalar benches: `sum_to→0 fib→200 tak→100` (unchanged).
- `make test-pear` → **29 PASS / 0 FAIL / 0 XFAIL** (unchanged).

## v0.9.0 — real malloc/free (baseline)
- `alloc [T; N]` uses libc `malloc(n_bytes)`, free wired, libc linked.
- Clause-style unit-thunk compiles.
- 29 PEAR tests, scalar benches green.

## Remaining work
- Multi-clause dispatch (pattern match on multiple args; multi-arm clauses).
- Tuple-pattern matching in ACNS_CASE so block-bodied multi-arg clause fns
  (e.g. `page_free | (p, n) -> { ... }`) lower correctly instead of hitting
  the bool-condbr path.
- Braceless `if cond then assign; next_stmt` at BLOCK tail leaves the then-arm
  BB unterminated when it's the last statement (currently only UB-pruned
  because the multi-clause match shadow-renames its single param, making the
  body unreachable before codegen). Fix in ACMD_IF/ACMD_SEQ join threading.
- Re-enable willreturn/mustprogress/nosync attrs once all malloc call paths
  carry allockind strings (malloc already fixed; confirm free/others).

## Agents
- **PEAR-bro** — PEAR LLVM backend, AIR mid-end. Branch `dev`.
- **Father-of-Pride** — architecture / λ̄μμ̃ theory / type system.
- **Ayonex-GOAT** — optimizer / theory / benchmarking.
- **Agent-3** — bug bounty, harnesses, cross-module integration.
- **Agent-4** — QA / suites / papercut hunt.
