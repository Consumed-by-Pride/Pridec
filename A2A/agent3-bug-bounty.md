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
| **D** | `while` + `return` inside the body → SIGTRAP at every tier | `while (i < 100) { if (i == 5) { return i; } i = i + 1; }` → 133 | **FIXED** (49190cb) |
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


---

## 8. UPDATE — bug D and bug N fixed (commits 49190cb, 271bbbd, pushed to `dev`)

| id | status | commit | evidence |
|---|---|---|---|
| **D** — `while` + inner `return`/`break` → SIGTRAP | **FIXED** | `49190cb` | exit **5** at -O0/-O1/-O2 (was 133/133/133); new tests `p96_while_return.pie`, `p97_while_break.pie` |
| **N** — 65th binding in a function aborts the compiler | **FIXED** | `271bbbd` | 40/60/120 locals compile at -O0 **and** -O2 (was abort at -O0/-O1); `p98_many_bindings.pie` (exit 119) |

### Bug D — three violations of the admin-join protocol (codegen)

The lowerer threads a fall-through statement's continuation through a fresh administrative
continuation `%kN`; the backend's covar handler implements that as a JOIN (emit the branch, mark the
block filled, move the builder into it, report "not terminated" so the caller's sequence is emitted
there). Three places broke the contract:

1. `ACMD_IF`: both arms' "not terminated" answer was an `unreachable` in the **current** block —
   which after a join fill *is* the join block — and the command then reported "terminated", so the
   enclosing sequence dropped everything after the `if`.
2. `ACNS_CASE` (the two-arm boolean form used by `if`/`while`/`for`): identical bug.
3. `ACNS_COMU`'s "tail-comu" shortcut returned "not terminated" **without emitting any branch**, on
   the assumption that an earlier cut had already branched into `%kN`. For the common shape
   `if (c) { return x; } i = i + 1;` that COMU tail is the only cut to the join, so nothing branched
   at all.

LLVM IR evidence (dumped from the codegen entry through the LLVM C API — the `--emit-air` text is
identical to what codegen consumes, so the fault was purely in the backend):

```
before:  if.else3:  ... i = i + 1 ...  unreachable     k1: (no terminator, back-edge lost)
after:   if.else3:  ... i = i + 1 ...  br label %k1    k1: br label %loop2
```

### Bug N — `char[256][64]` is 64 rows of 256, not the other way round

C3's array dimensions read right-to-left: `T[E][N]` is *N rows of E elements*. The backend declared
its name table `char[256][64]` intending "256 names of 64 chars"; it actually got **64 slots of 256
chars**, and `add_name()` indexes up to 255 — so the 65th binding aborted the compiler:

```
ERROR: 'Array index out of bounds (array had size 64, index was 64)'
  in pear.PearCg.add_name (pear.c3:242) [inline] ... in pear_emit_fn
```

That is why the threshold tracked the number of *bindings* (~40 `let`s + temporaries + params ≈ 65
names) and why `-O2` survived (fewer names minted). Verified the dialect with the toolchain before
patching: `char[256][64]` rejects `a[200][x]` with *"An index of '200' is out of range, a value
between 0 and 63 was expected"*, while `char[64][256]` accepts rows up to 255. Both tables (names and
labels) were declared backwards; both are fixed, the rule is documented in the struct, and
`add_name` now copies with `snprintf` instead of a hand-rolled bounded loop.

The old comment in the struct asserted the wrong rule ("C3: outer-dim first"), which is presumably
how the mistake was made — worth knowing for everyone else's fixed-size tables.

### Verification after both fixes (LLVM 23, `dev` @ 271bbbd)

| suite | value |
|---|---|
| exec | **pass=18 fail=0 xfail=49 xpass=0** (cases 64) — was 11/0/50 at the start of the bounty |
| subtype self-test | 47/47 |
| conformance | 218/44 |
| pfront | 158/5 (+ stdlib 260/260) |
| emit matrix | fib(10)=55, tak(1,2,3)=3, sum_to(10)=55 at -O0/-O1/-O2 |
| bounty battery | 28/33 behaviour probes correct; **robustness crashes 0** at -O0 and -O2 |

Superseded by §9.6: of that list, C, E, F and H are now fixed (L was fixed by PEAR-bro's 1-index GEP
patch and b30 went with it). Still open: B, I, J, K, M.

---

## 9. UPDATE — bug C (forward calls) and bug H (nested functions) fixed (commits 7561d76 → 046a93a, pushed)

### 9.1 Bug C — a call to a function defined LATER crashed the compiled program

```pride
fn main(_) -> i64 { return g(41); }
fn g(x: i64) -> i64 { return x + 1; }
```

compiled and linked fine, then died with SIGSEGV (exit 139). Self-recursion and calls to
already-defined functions were fine.

**Cause.** `ACNS_CALL` resolves the callee *by name* (`prd_i64` → `ll_get_named_fn`) against
symbols that only existed once a body had been emitted, and `pear_setup` pre-created only the
externs from `ADECL_DECLARE`. A forward callee therefore resolved to null, and the call site fell
back to

```c
callee = ll_const_int(cg.i64ty, 0, 0);   // …a call to address 0
```

**Fix.** One shared `pear_fn_type` + `pear_fn_get_or_create`; `pear_setup` pre-creates every
`ADECL_DEF` before any body is emitted; `pear_emit_fn` reuses the pre-created symbol.

Evidence: before, `c5` (backward) = 42 but `c6` (forward) = 139; after, `c1=3 c2=1 c3=1 c5=42 c6=42`.
Test `tests/exec/pear/p99_forward_call.pie` (42).

### 9.2 Bug H — a nested `fn` produced a call to address 0

Nested function definitions lowered to a **nop**, so

```
<inner|call(3; %ret_2)>        ; AIR: a call, but no definition anywhere
```

became a call to address 0 → SIGSEGV.

**Fix.** Hoisting in `air_lower.c3` (record nested `fn`s in a pre-pass, emit them as top-level
definitions, rewrite the call) plus `AirScope.bind_as` — the scope's lookup key must be the
**source** name while the emitted Air name may be mangled (`inner$1`; `$` is not legal in a C3
identifier, so the mangled name can never be written in source). The first attempt bound the
mangled name as the key and the call still resolved to nothing.

Evidence (all at -O0 and -O2): two local `inner`s in different scopes 22 → **31**; a local `inner`
shadowing a global 200 → **106**. Tests `p100` (3), `p101` (12), `p102` (31).

### 9.3 Bug E — struct field sums read 0 (commit 771ed80, pushed)

```pride
struct P { x: i64; y: i64; }
let p: P = P { x: 40, y: 2 };  return p.x + p.y;      // was 0, want 42
```

Field access was never implemented: `prd_i64` had no `APRD_RECORD` case (a record literal fell
through to `default: return 0`) and `ACNS_FIELD` was an explicit bootstrap pass-through
("Projection not yet implemented. Pass v through unchanged"). Records now have a real layout — a
stack buffer with one i64 slot per field in **declaration** order, carried as an address — and the
lowerer supplies each field's slot index from the resolver's link (`p.x` → field declaration →
parent struct → ordinal). `struct_lit` reorders inits into declaration order, so
`P { y = 2, x = 40 }` and `P { x = 40, y = 2 }` lay out identically. A negative index (unresolvable
field) keeps the old pass-through rather than dereferencing an address we cannot vouch for.

**The GEP trap, third time in this stretch — now written down in the code.** A two-index GEP
indexes an *aggregate*, so its type argument must be the **array type the pointer refers to**
(passing the element type, or `i8` as the old INDEX code did, hands LLVM an ill-formed instruction
and it aborts inside its own optimiser). A one-index GEP is an element-offset GEP and needs an
*element* pointer. Producer: `gep [N x i64], ptr %buf, i64 0, i64 slot`; consumer:
`gep i64, ptr %base_i64, i64 idx`.

Evidence: field sum **42**; three fields 42; nested records `o.i.v + o.k` 42; record passed to a
function 42; record built inside a loop 6 (at -O0 and -O2).

Deliberate limitation, not papered over: the buffer is allocated once per record *literal* in the
entry block, so a record that **escapes** its iteration (stored into an array, returned, captured)
would alias. Escaping records need heap or per-iteration allocation.

### 9.4 Bug F — nested loops aborted the compiler (commit 311cc9f, pushed)

```pride
fn main(_) -> i64 {
    let mut t: i64 = 0; let mut i: i64 = 0;
    while (i < 3) { let mut j: i64 = 0; while (j < 2) { t = t + 1; j = j + 1; } i = i + 1; }
    return t;
}
```

died at every tier, even with `--no-opt`:

```
ERROR: 'Out of bounds memory access.'
  in llvm::Instruction::clone() const [libLLVM.so.23.1]
```

Sequential loops were fine — only *nested* loops. LLVM was dying on our IR, not in our code:

```
exit3:  … i = i + 1 ; br label %k1
k1:                                    <- empty, NO terminator  (invalid IR)
body:   store … ; br label %loop2      <- and the outer back edge was nowhere
```

Two faults in one shape. The commands after the inner loop's label are

```
jump %loop4      ; inner loop entry/back edge — closes the current block
jump %loop2      ; outer loop back edge     — the content of join %k1
```

and the emitter mishandled both: (1) `ACMD_JUMP` always appended a branch, so a jump reaching a
closed block either added a **second terminator** to it or — by reporting "terminated" — made
`ACMD_SEQ` drop the rest of the sequence, which held the outer back edge inside a `μ̃` binder;
(2) the block a cut `<()|%kN>` redirects into is filled by "whatever follows in this sequence", and
when those commands arrived with the current block closed nothing moved the insert point into the
join, leaving it empty and unterminated.

Fix: `PearCg.bb_open` (ask LLVM whether the block still wants a terminator, via
`LLVMGetLastInstruction` + `LLVMIsATerminatorInst` — no bookkeeping to desync),
`PearCg.pending_open_join`, `PearCg.sync_pos` (called at the top of `cg.cmd`: if the current block
is closed and a join is open, continue in the join), and a `ACMD_JUMP` that never appends to a
closed block — it parks the branch in a fresh unreachable block, which is valid IR that LLVM
deletes, instead of losing the edge — and does not claim "terminated" while a join is still open.

Evidence: nested 3×2 = **6**, two-level = 2, three-level 2·3·4 = **24**, nested + records = **252**,
sequential loops unchanged (4), at -O0/-O1/-O2. Tests `p106`, `p107`, `p108`.

### 9.5 Maintenance repair: the pushed index work did not build (commit 14b400f, pushed)

Merging `3149562` (i64/i32 index tests, per-index element sizes) surfaced three compile errors in
the new `index_elem_size` helpers:

* `'NodeKind' has no enumeration value 'N_TY_REF_MUT'` (three places). The front-end models
  reference *types* with a single `N_TY_REF`; `&mut` is an expression-level distinction
  (`N_EXPR_REF`). The disjunct is dropped — a mutable reference is pointer-sized either way.
* `Node* bnd = lr.scope.lookup(base)` — `AirScope.lookup` takes a source **name** and returns the
  **Air name**, so it cannot be a declaration lookup. Added `AirScope.decl_for(src_nm)`
  (name → AST declaration, the inverse of `lookup_decl`) and used `node_text(base)`.

The element-size logic itself was left alone. **For PEAR-bro:** please push the enum accessor or the
enum itself rather than referencing a kind that is not in `pfront_core.c3`, so `dev` builds straight
off the branch.

### 9.6 State of the board after §8–§9 (LLVM 23, `dev` @ 14b400f)

| suite | value |
|---|---|
| exec | **pass=31 fail=0 xfail=48 xpass=0** (cases 76) — was 15/0/49 when the bounty started |
| subtype self-test | 47/47 |
| conformance | 218/44 |
| pfront | 158/5 (+ stdlib 260/260) |
| emit matrix | fib(10)=55, tak(1,2,3)=3, sum_to(10)=55 at -O0/-O1/-O2 |
| bounty battery | **33/33 behaviour probes correct — 0 failures — and 0 robustness crashes, at both -O2 and -O0** |

Fixed so far: **A, A2, A3, C, D, E, F, H, N**, plus **L** (p91) via PEAR-bro's 1-index GEP fix, plus
**b30** (indexed store) which the same fix cleared. Still open: **B** (phantom import errors outside
the repo root), **I** (comments-only file → `ld` undefined `main`), **J** (duplicate `fn` accepted
silently), **K** (warning flips exit status to 1), **M** (p92 clause-style SIGTRAP, still XFAIL).

Corrections published rather than silently edited: the `char[A][B]` dimension rule (§8), the
p105 expectation in my own test header (13 → 44), and this section's notes on PEAR-bro's build
break. Battery headers b05/b06/b08 were corrected earlier to 43/5/239.
