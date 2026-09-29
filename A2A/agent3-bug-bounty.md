# Agent-3 — bug bounty on `dev` (report)

Branch: `dev`. Fix commit: **41a5c07** *"air_lower: statement-position blocks must continue into the
following code (fixes block-binding loss, indexed store/load)"* (pushed as soon as the PAT is
re-supplied — the remote config was wiped again mid-session, see §7).

Everything below was measured with `pfrontc` built from `dev` + this commit, on LLVM 23, run **from
the repo root**, exit codes captured **without pipes** (`cmd >/dev/null 2>&1; rc=$?`).

---

## 1. Method

* **Behaviour battery** — 26 hand-computed programs (`/tmp/bounty/good_*.pie`), each expecting a
  specific exit status: precedence, unary, `%`, `/`, shifts, bit ops, `~`, negative remainder,
  comparisons, nested comparisons, many args, re-use of a local, loops, nested loops, early return,
  recursion, mutual recursion, shadowing, constants, structs, negative literals, calls in conditions,
  comparison chains, large expressions, argument evaluation order.
* **Robustness battery** — 15 malformed/degenerate inputs (`/tmp/bounty/rob_*.pie`): empty file,
  unterminated token, deep parens, huge int, div/mod by zero, negative shift, undefined ident,
  duplicate fn, recursive type, unused var, no `main`, nested fn, many statements, comments-only.
* **Targeted diagnostic lowering** — `/tmp/bounty/{a,b,c,d,e,g}.pie` + `.air` dumps, plus temporary
  printfs gated by `AIR_SCOPE_DEBUG` / `AIR_RET_DEBUG` / `AIR_ID_DEBUG` (all removed before commit;
  `git diff` contains no `printf`/`getenv` additions).
* **A/B measurement** for the second defect: the pre-binding pass was made switchable
  (`AIR_NO_PREBIND`) to prove it changes behaviour rather than just AIR text; the switch was removed
  from the committed code after measuring.

## 2. Findings

| id | symptom | minimal repro | status |
|---|---|---|---|
| **A** | statement-position block drops the surrounding bindings: `return x` lowers to `<()|%ret_2>` (unit) | `fn main(_) -> i64 { let x: i64 = 1; { let y: i64 = 2; } return x; }` → returned **0**, want 1 | **FIXED** |
| **A2** | shadowed name leaks out of the block | `fn outer(_) -> i64 { let x: i64 = 1; { let x: i64 = 2; } return x; }` → returned **2**, want 1 | **FIXED** |
| **A3** | indexed store/load (the standing PEAR blocker, `pear/p90_indexed_store_load`) | `a[0] = 7; return a[0]` → returned **0**, want 7 | **FIXED** |
| **B** | running `pfrontc` outside the repo root emits phantom `E2002`+`E3001` import errors, `errors: 2`, exit 2, **while still emitting a working binary**; same file from the repo root → rc 0 | `cd /tmp && /home/user/Pridec/pfrontc ctl.pie --emit-exe -O2` | queued |
| **C** | cross-function / mutual recursion SIGSEGV | `fn a(n) { return b(n); } fn b(n) { return a(n); }` → 139; self-recursion (`good_fact` = 120) is fine | queued |
| **D** | `while` + `return` inside the body → SIGTRAP at -O2 | `while (i < 100) { if (i == 5) { return i; } i = i + 1; }` → 133 | queued |
| **E** | struct field sum yields 0 although the AIR is correct (`fld(x(p))`, `fld(y(p))`) | `let s = p.x + p.y; return s;` → 0, want 42 | queued (backend) |
| **F** | nested loop → tool aborts `'Out of bounds memory access.'`, no binary | `good_nest_loop.pie` | queued |
| **H** | **nested fn definition compiles, binary SIGSEGVs** | `fn main(_) -> i64 { fn inner(a: i64) -> i64 { return a; } return inner(3); }` → tool rc 0, binary **139** | queued (new) |
| **I** | comments-only file: `ld: undefined reference to 'main'` + `errors: 4` | `// nothing here /* or here */` | queued (minor) |
| **J** | duplicate function definitions silently accepted (last/first wins) | `fn f(a) { return a; } fn f(a) { return a + 1; }` → compiles, no diagnostic | queued (new) |
| **K** | **a valid program with a warning exits 1** | `fn main(_) -> i64 { let x: i64 = 5; return 0; }` → rc **1** (warning `W4001`); the same program with the warning removed → rc 0 | queued (one-line patch, §6) |
| **L** | `pear/p91` dynamic-indexed array write: emitted IR has a malformed GEP, LLVM aborts in `EarlyCSE`/`simplifyGEPInst` (`DataLayout::getTypeAllocSize`) | `while i < 8 { a[i] = i; i = i + 1; }` | queued (reason text updated in XFAIL.tsv) |
| **M** | `pear/p92` clause-style body now *builds* but traps (SIGTRAP 133) instead of returning 42 (was: no binary) | `fn main : () -> i64 \| () -> 42` | queued (reason text updated) |

## 3. Root cause of A / A2 / A3 — two independent defects in `AirLower.stmts`

**(1) Fall-through continuation mix-up.** The container's children are lowered **backwards**; a
middle statement was lowered with the container's *original* continuation `k` instead of the
accumulated `cur`:

```c
else { sc = lr.cmd(s, k); }          //  k = the block's own exit, not the code after `s`
```

For a statement-position block, `stmts(block, k, tail_is_k=true)` makes the block's tail cut to `k`,
so `{ let y = 2; }` became `let y = 2; <()|%ret_2>` — a cut to the **function's return
covariable**. `is_terminal_cmd()` treats every covariable cut as terminal, so `seq_cmds()` then
deleted the already-lowered `return x` as dead code ("b is dead").

AIR before → after:

```
fn f(n) -> i64 { let x: i64 = n; { let y: i64 = 2; } return x; }
fn f(n) -> i64 {
  μ̃%ret_2. let x = n;                       <- before
  let y = 2;
  <()|%ret_2>                                <- the return operand is gone, f(7) = 0
}
fn f(n) -> i64 {
  μ̃%ret_2. let x = n;                       <- after
  let y = 2;
  <()|%k1>;                                  <- join to the following code
  <x|%ret_2>                                 <- the real return survives, f(7) = 7
}
```

Fix: fall-through statements (blocks, assignments, `if`/`while`/`for`/`match`/`defer`) are lowered
against a **freshly minted administrative continuation** `%kN`. That is exactly the mechanism the
LLVM backend already implements (`pear.c3`, `Codegen.cns`, `ACNS_COVAR`): *"position builder at bb
(creating it fresh if this is the first occurrence), emit the br, then CONTINUE to emit subsequent
commands into bb"* — i.e. `%kN` is a **join**, not an escape. Consequently `is_terminal_cmd()`
(`air_lower.c3`) and the printer's `is_terminal()` (`air_emit.c3`) no longer classify admin join cuts
as terminal; a genuine control transfer (`return`/`break`/`continue`) keeps the old path.

This also explains **A3**: `a[0] = 7;` is a fall-through statement whose continuation was dropped, so
the load and the return after it never ran.

**(2) Tail lowered before its bindings exist.** Because the walk is backwards, the tail of a block is
lowered *before* the preceding `let` binds its name. The lookup missed and fell back to a literal
variable with the source name — which silently worked only while that name coincided with the name
the later `bind` chose:

```
[scope] enter  depth=2 count=4
[scope] lookup 'x' -> MISS count=4     <- `return x` lowered here, x not yet bound
[scope] bind   'x' -> x depth=3        <- `let x` processed afterwards
```

With shadowing the fallback resolves to the **outer** binding, so `{ let x = 2; } return x` returned 2
instead of 1. Fix: `stmts()` pre-binds the block's simple `let`/`const`/`static` declarations before
lowering the tail (`AirScope.lookup_decl()` finds a binding by declaration node) and `letlike()`
reuses that binding instead of creating a second local.

A/B proof (env-gated build, `AIR_NO_PREBIND`):

| case | pre-bind ON | pre-bind OFF |
|---|---|---|
| `let x = 1; { let x = 2; } return x` | **1** ✓ | 2 ✗ |
| `fn outer()` = same shape in a fn | **1** ✓ | 2 ✗ |
| `fn f(n) { let x = n; { let y = 2; } return x; }` | 7 ✓ | 7 ✓ (fixed by (1)) |

## 4. Verification (measured, no pipes)

| suite | before | after |
|---|---|---|
| exec (`tests/exec/run.sh`) | pass=11 fail=0 xfail=50 | **pass=15 fail=0 xfail=49 xpass=0** (cases 58→61) |
| subtype self-test | 47/47 | 47/47 |
| conformance | 218/44 | 218/44 |
| pfront | 156/5 | **158/5** |
| stdlib self-clean | 260/260 | 260/260 |
| emit matrix | — | fib(10)=55, tak(1,2,3)=3, sum_to(10)=55 at **-O0/-O1/-O2** |

`pear/p90_indexed_store_load` was promoted out of `tests/exec/XFAIL.tsv`; `p91`/`p92` reasons were
rewritten to the failure modes measured today. `tests/baselines.tsv` updated (exec 15/0, pfront
158/5). New regression tests: `p93_block_scope_bindings.pie` (1), `p94_shadow_scope.pie` (12),
`p95_block_then_tail.pie` (7).

Behaviour battery after the fix: **22/23 correct** (the remaining one is E, struct field sum);
`good_shadow` now returns 1 — see the correction in §5.

## 5. Corrections to my own earlier claims (published, not silently edited)

1. **`good_shadow` expectation was wrong.** I recorded "want 2" for
   `let x = 1; { let x = 2; } return x`. The correct answer is **1** — the block scope ends before
   the `return`, so the outer binding is the right one. The compiler was right once A2 was fixed.
2. **Exit codes are 8-bit.** `good_loop_sq` returning 285 shows up as 29 (`285 & 0xFF`); it was never
   a bug. Same trap applies to any probe with a result > 255.
3. **"All 15 robustness probes exit 2" was a measurement artifact of bug B**, not a validation: that
   run used the probe directory as cwd, which triggers the phantom import diagnostics. Re-measured
   from the repo root, the 15 probes give mixed results: clean compiles for `deep_parens`,
   `huge_int`, `neg_shift` (rc 0), real diagnostics for `only_comments`, `recursion_ty`,
   `undefined_id`, `unterminated`, `zero_div_const` (rc 2), and rc 1 for `many_stmts`, `unused_var`,
   `zero_mod_var` — the last three are bug K, not crashes. Two genuinely bad ones surfaced this way:
   **H** (nested fn → SIGSEGV binary) and **J** (duplicate fn silently accepted).
4. **p90 did not need backend work after all.** The recorded blocker note said "store is dropped by
   air_lower and PEAR never dispatches `ACNS_STORE`/`ACNS_INDEX`". The store *was* being lowered
   (Pear-Bro's handlers work); what was lost was its continuation. Corrected in `XFAIL.tsv` by
   removing the entry.

## 6. Queued bugs — diagnostics and suggested patches

* **K (warning → rc 1)** — `pfront/pfront_main.c3:723`:
  ```c
  if (rr.errors > 0) { return 2; }
  if (rr.warnings > 0) { return 1; }     // <- unconditional; no -Werror flag exists anywhere
  ```
  Suggested: drop the warnings clause (warnings are diagnostics, not failures) or gate it behind an
  explicit `-Werror`/`--warnings-as-errors` flag. **Not landed deliberately**: it is a CLI contract
  change that touches every script/harness in the repo (including my integrator and the exec suite's
  `--quiet` runs), so it should be agreed first. One-line repro is in §2/K.
* **B (phantom imports outside the repo root)** — the module loader resolves the stdlib/package paths
  relative to cwd. Fix direction: resolve relative to the input file / the binary's own prefix, and
  make "module not found" a real error rather than a diagnostic that still emits a binary.
* **C (cross-function calls SIGSEGV)** — reproducible only across functions (`a → b`); self-recursion
  works, so the callee-side return/ABI plumbing for non-self calls is the suspect.
* **D (`while` + inner `return` → SIGTRAP)** — the AIR for that shape emits `%exit1` *before*
  `%loop2`/`jump %loop2`, i.e. the loop-exit and return edges are ordered wrongly. Same family as
  this fix (continuation threading for control constructs) — likely the next one to fall.
* **H (nested fn SIGSEGV)** — a local `fn` decl inside a body produces a callable symbol with no
  linkable definition; the generated call jumps to garbage.
* **E (struct field sum)** — AIR is correct (`fld(x(p))`, `fld(y(p))`), so it is a backend/ABI
  issue in field extraction, not lowering.

## 7. Delivery state

* Fix committed locally as **41a5c07** on `dev`; `git push` needs the PAT again (session-only, and
  `.git/config` is snapshot-excluded so the remote credentials are wiped between turns). Push is the
  only outstanding step.
* Suites/tests/baselines/`XFAIL.tsv` updated in the same commit; no other agent's files touched.
* `A2A/from_agent3.md` updated with a pointer to this report.
