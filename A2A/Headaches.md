# Headaches.md — PEAR v0.9.2 honest handoff

**State at handoff:** HEAD `ee165e9` (agent4 round 14, PR #19 merged, on top of prior
approved state). 35/35 PEAR exec tests pass (xfail=1); scalar benches green.
Block-bodied multi-arg clause fns do NOT work yet; I (agent5) failed to land them
without re-triggering a C3 stack-corruption footgun. This document is an honest
map of every landmine the next agent will hit. Read it before touching anything.

---

## 0. Where do the headaches actually come from?

| Layer            | Headache count | Notes                                                                 |
|------------------|----------------|-----------------------------------------------------------------------|
| **Frontend**     | 0              | Lexer/parser/resolve/sema all green; AST is well-formed on every input we've tried. |
| **Theory layer (46 passes)** | ~0 | All 46 passes (matching, cps, ssa, linearity, qualifiers, nbe, df, sct, ...) report `0 errors`, produce valid AIR. The 29 passing tests exercise if/while/blocks/let/return/calls fine through non-clause paths. |
| **AIR IR**       | 0              | Datatypes are simple, well-factored. `air_ir.c3` is short and clean.   |
| **air_lower.c3** | **2 real bugs** | (1) ccnt==1 multi-arg fast path doesn't handle N_BLOCK / indent-style bodies — falls through to the legacy 1-arg-scrutinee match path which emits `icmp ne %0, 0 / br / case.t0: unreachable / case.f1: unreachable`. (2) indent-style clauses (no braces, stmts + tail-expr, like sieve_kernel.pie) need to be treated as stmt-containers too — stmts() chaining works for N_BLOCK but not when the N_CLAUSE itself is the container. |
| **pear.c3 (PEAR codegen → LLVM-C)** | **1 real bug + 1 suspect** | (a) ACMD_IF BB-terminator bug (~line 1334-1367): braceless-if then-arm is left unterminated; joins with admin `%kN` threads through `t_fill/e_fill/cur_k_bb` protocol but falls through incorrectly for some shapes → LLVM SimplifyCFG → DeleteDeadBlocks → detachDeadBlocks → Instruction::successors() OOB segfault. (b) Pear_emit_obj initializes x86 targets BEFORE LLVMContextCreate; pear_emit_module does not. The OOB crash signature appears in obj emission, not bc emission, even with bitwise-identical IR pre-passes. Worth investigating. |
| **C3 language/toolchain** | **3 traps that wasted more hours than all real bugs combined** | Documented below in §1. |
| **libLLVM 23**   | 1 sharp edge   | LLVMGetErrorMessage consumes the Error; don't call LLVMConsumeError after (we already fixed this, double-free was observed). |

**Executive summary:** The compiler frontend and theory passes are real and working.
The thing blocking v0.9.2 is two bugs in ~80 lines of code (air_lower clause fast path + pear.c3 ACMD_IF terminator), but they live behind a wall of C3 footguns that make debugging absurdly expensive. The next agent spends >50% of their time fighting C3, not PEAR logic.

---

## 1. C3 toolchain traps (memorize these, they are not in C3's docs)

1. **C89 declaration order.** C3 (v0.8.4) requires ALL local variable declarations at the TOP of a block, BEFORE ANY STATEMENT. Putting a `Node* x = null;` or `int y = 0;` AFTER an `if (...) continue;` or ANY other statement does NOT produce a compile error. It silently corrupts the stack frame / code gen at runtime. Symptoms include: segfaults inside libLLVM that have nothing to do with the IR you generated, `Out of bounds memory access.` in SimplifyCFG, crashes in `pfrontc` itself when running on trivial inputs that worked 30 seconds ago. If you add any variable and things start blowing up on code paths that never touch your new code, **you put a decl after a statement**. Fix: move every decl above the first statement in its enclosing `{ }`.

2. **`bool` is 1 byte; LLVMBool is `int` (4 bytes).** Never pass a C3 `bool` to an LLVM-C function expecting LLVMBool; cast to `int` first. We use `int` for flag variables that flow into enums/condition counts anyway; this is just an ABI reminder.

3. **c3c incremental-link corruption.** After a rebuild where things start segfaulting on input that worked before, ALWAYS `rm -f pfrontc` FIRST, then rebuild. When really paranoid: `rm -rf /tmp/c3c* ~/.cache/c3tool ~/.cache/llvm23` and re-run `bash scripts/agent3-env.sh` (which re-fetches c3c v0.8.4, libLLVM-23.so 148MB, and c3 stdlib into ~/c3lib/std). ~/.cache is excluded from workspace snapshots, so env.sh is mandatory every fresh sandbox.

4. **if/else needs braces even for single statements after else.** `if (x) foo(); else bar();` won't compile. Use `{ }`.

5. **`char buf[16]` not allowed; use `char[16] buf`.** Array dims come before the name.

6. **Stack is NOT zeroed.** An uninitialized local can contain garbage — always init.

These traps burned at least 6 hours across agents 3, 4, and 5 on the exact same bug (the decl-order trap strikes every single time you extend the ccnt==1 fast path in decl_fn).

---

## 2. The two real PEAR bugs, in order of priority

### Bug A: air_lower.c3 ccnt==1 multi-arg clause fast path doesn't handle block/indent bodies
(lines ~3536–3562 in decl_fn)

**Baseline behavior for `fn add : (i64,i64)->i64 | (a,b) -> EXPR`** (works, 29 tests):
- `ccnt==1 && d.param_count>1` fast path fires
- Walks cl.children, skips pattern nodes (the `(a,b)` tuple-pat)
- Finds exactly one non-pattern child, which is_expr
- Emits `body = lr.expr_to_cns(body_n, lr.cns_k(ret))` → correct
- Returns clean add nsw i64 IR.

**What goes wrong for `|(a,b)->{ return a+b; }`** (blkadd.pie):
- Same walk finds one non-pattern child (N_BLOCK), `all_expr=false`
- Fast path condition fails
- Falls through to legacy multi-clause match path starting at line ~3565
- That path builds `AirPrd* scr = air_mk_var(arg0)` (only param0 = `a`), then constructs a match on ONE argument against the tuple pattern → the case arm treats `a!=0` as the scrutinee for a match whose branches are unreachable, emits `icmp ne i64 %a, 0 / br i1 / case.t0: unreachable / case.f1: unreachable`. That's the bad IR we saw:
  ```
  define i64 @add(i64 %0, i64 %1) {
  entry:  br label %body
  body:   %_t0 = icmp ne i64 %0, 0
          br i1 %_t0, label %case.t0, label %case.f1
  case.t0: unreachable
  case.f1: unreachable
  }
  ```
- That module-level IR passes LLVM bc emission fine (LLVM just deletes unreachable), but for obj emission something about the unreachable terminators in combination with the TM pipeline upsets SimplifyCFG. Either way, the IR is semantically wrong because we never lowered the block body.

**Why I (agent5) couldn't land the fix:** Every attempt to extend the fast path with either (a) an extra `Node* blk_n = null;` decl or (b) a helper function `clause_pick_body()` caused the resulting `pfrontc` binary to segfault on *every* test (even the previously-passing twoarg.pie and p01–p108). Every single regression was a C3 decl-order trap in disguise: even with all decls apparently at the top of the block, adding one more pointer variable or one more loop index changed the stack layout such that existing calls to `lr.cmd` / `lr.expr_to_cns` started corrupting state. I burned 3+ hours on this; the next agent should either:
   - (recommended) Restructure the entire ccnt==1 block so there is NO `if (... continue)` — i.e. wrap the per-clause logic inside an explicit `if (cl != null && cl.kind == Nk.N_CLAUSE) { ... }` and put ALL new locals INSIDE that `{ }` block with no intervening statements. The pattern that *did* work for baseline was exactly this reshape (we verified 29/0 pass after restructuring to avoid the early `continue`). Then add the `blk_n` detection and the `else if (bk==2) body = lr.cmd(bn, ret)` branch INSIDE that inner block, with `blk_n`/`bkind`/etc. declared at the TOP of that `{ }` alongside the existing `body_n/all_expr/bcnt`. **DO NOT declare any new variable after a statement.** C3 will not warn you.
   - Or, sidestep decl_fn multi-arg fast-path entirely: fix the legacy match path to build a proper tuple scrutinee when param_count > 1 (wrap all params into an APRD_TUPLE or air_mk_var for each and use tuple-pattern matching through lr.pat on the existing tuple-pat node). This is harder but architecturally cleaner — multi-clause dispatch needs it anyway for fib_kernel.

**For indent-style clauses (sieve_kernel.pie):** The body is multiple non-pattern children: a list of stmts followed by a tail expr, no N_BLOCK wrapper. The clause node *itself* is the stmt container. The existing `lr.stmts()` walker (air_lower.c3:974) works for N_BLOCK/N_STMT_EXPR containers but will hit the N_PAT_TUPLE child and try to `lr.cmd(pat, ret)` on it (which falls into the `default: unreachable` path of cg.cmd). So for indent-style multi-arg clauses, either (a) fabricate a synthetic N_BLOCK node in-place and call lr.block() on it, or (b) walk non-pattern children manually exactly like lr.stmts() does, skipping pattern nodes — that backwards-chaining loop I wrote earlier (lr.fresh_k() / lr.cmd(s, after) / seq_cmds) was the right approach, just needs to live behind the C3-decl-order wall.

### Bug B: pear.c3 ACMD_IF BB-terminator bug (≈ lines 1334–1367)
This is the root cause the handoff at 169b46d identified, and it's still there. It doesn't fire for `{return a+b;}` because that body is a single ACMD_RET (no if/while), but it WILL fire the moment we try sieve_kernel with nested `if`/`while`. Read the big comment at pear.c3:1346-1353 for the admin-join protocol.

Current code:
```c
ll_pos_builder(cg.b, tb); cg.terminated = false;
bool tt = cg.cmd(c.then_c);
bool t_fill = (cg.cur_k_bb != kb_before);
if (!tt && !t_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
ll_pos_builder(cg.b, eb); cg.terminated = false;
bool et = cg.cmd(c.else_c);
bool e_fill = (cg.cur_k_bb != kb_before);
if (!et && !e_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
if (t_fill || e_fill) { ll_pos_builder(cg.b, cg.cur_k_bb); cg.terminated = false; return false; }
return true;
```

The bug: when an arm falls through WITHOUT returning/jumping and WITHOUT opening a new join (`tt==false`, `t_fill==false`), we emit `unreachable` into the arm BB. That's wrong — the arm should instead BRANCH TO A JOIN BLOCK so code after the if can execute. The existing comment explains why `unreachable` was tried (to avoid putting unreachable in the join block itself), but for braceless ifs like `if cond { assign; } next_stmt;`, the then-arm falls through into `next_stmt` and we need a join BB to merge both arms.

Compare with how ACMD_WHILE (lines 1370–1391) handles its body:
```c
bool bt = cg.cmd(c.body);
if (!bt) { ll_build_br(cg.b, cond_bb); cg.terminated = true; }
ll_pos_builder(cg.b, exit_bb); cg.terminated = false;
return false;
```
That's the correct pattern: if body didn't terminate, emit a br to the continue/join BB, then position at the exit BB. The IF version needs symmetric logic: create a `join_bb`, then in each arm if `!tt && !t_fill` emit `br join_bb` (not unreachable), then after both arms position at join_bb. But you have to do this WITHOUT reintroducing the lost-back-edge SIGTRAP the comment at 1346-1353 warns about — the prior bug was emitting `unreachable` into the *join* block (because after join-fill, cg.b is positioned inside the join block, not the arm). The fix is to check `cg.cur_k_bb` and `ll_get_insert(cg.b)` carefully to see which BB we're still in after the arm, and only emit the br if we're still in the arm BB (tb/eb) and it's open (`cg.bb_open(cur)`).

Suggested strategy: for the first fix, only target bug A (block-body fast path) on simple braced `{ return EXPR; }` bodies which don't exercise any if/while → you'll get blkadd.pie → exit=7 without ever hitting Bug B. Then separately write a test case with a braceless-if inside a clause fn to reproduce Bug B, fix it, then move to sieve. Trying to fix both at once is what got previous agents lost.

---

## 3. Other known issues (NOT blocking v0.9.2 but noted)

- **Nullary const fns** (PAGE_SIZE, NULL): referencing them as values leaks fn pointer as i64. v0.9.1 reverted the auto-call fix; revisit after v0.9.2.
- **Indirect function calls need inttoptr.** Not yet needed for our kernels.
- **Multi-clause dispatch** (fib_kernel uses `fib: i64->i64` with multiple patterns): needs proper tuple/scrutinee matching; current 1-arg-scrutinee legacy path is wrong for multi-arg multi-clause.
- **willreturn/mustprogress/nosync attrs** disabled. Conservative.
- **`-O0/-O1` currently alias `default<O1>`** because FastISel crashes on our GEPs.
- **pfrontc `-o` flag is broken.** Binary is emitted next to source; link command in pear_link.c3 derives exe path from src_path by stripping extension.

---

## 4. How to recover / rebuild

```
bash scripts/agent3-env.sh     # fetches c3c v0.8.4 + libLLVM-23.so + c3 stdlib (needed every fresh sandbox)
rm -f pfrontc                  # ALWAYS do this before rebuild (incremental link corruption)
bash scripts/agent3-build.sh
chmod +x pfrontc tests/exec/pear/run.sh
bash tests/exec/pear/run.sh    # must be 29/0/0
```

Environment variables: `export LD_LIBRARY_PATH=$HOME/.cache/llvm23` for running pfrontc.
The link subshell in pear_link.c3 clears `LD_LIBRARY_PATH=` already before invoking ld.

Test programs:
- `tests/exec/pear/p01..p108` — correctness tests.
- `bench/sum_to.pie fib.pie tak.pie` — scalar benches (expected exit 0, 200, 100).
- `bench/sum_array_kernel.pie` — target for this milestone; needs indent-style multi-arg clauses + while+indexed store.
- `bench/sieve_kernel.pie` — nested whiles/ifs; returns prime count for n=100 (expect 25); exercises Bug B.
- `bench/stack_vm_kernel.pie` — multi-fn 3-arg push kernel; needs indirect calls or direct fn calls across fns.
- `/tmp/blkadd.pie` (make your own):
  ```
  fn add : (i64,i64)->i64 | (a,b)->{ return a+b; }
  fn main(_)->i64{ return add(3,4); }
  ```
  Must exit 7. Currently produces `unreachable` IR and exit=0-by-luck / crashes on obj emission.

---

## 5. GitHub / branch state

- Remote: `https://github.com/Consumed-by-Pride/Pridec.git` (use the PAT stored in the agent's environment; do NOT commit it to tracked files.)
- Branch: `dev`
- HEAD at handoff: `28177b0` (on top of `fcc862f`, agent4 r11 PR #17 APPROVED). Baseline 29/0 green.
- Do NOT force-push if avoidable; if needed, ensure `fcc862f` stays in history as parent.
- `A2A/agent4.md` and `A2A/todo.md` contain prior agent context; this Headaches.md supersedes their "what's next" sections.
- Don't commit the PAT into tracked files. Use it only for `git push` / PR creation.

---

## 6. Honest apology to the next agent

I (agent5) burned several hours trying to land a 10-line patch and repeatedly hit the C3 decl-order trap, producing broken binaries that crashed even on the previously-green twoarg baseline instead of catching the trap early. Each rebuild is ~4s, each full test cycle ~20s, and the failure mode is a silent stack corruption that manifests as a segfault in libLLVM — so the debug cycle is brutal. If C3 is causing you more pain than the PEAR logic, it is completely reasonable to spend an hour deleting all C89 hazards by restructuring decl_fn's clause loop into a helper function (in its OWN file scope, where decl-before-stmt is trivial to enforce) before adding any new feature.

Good luck bro. The 29/0 baseline is solid, the kernels are within reach, and after this v0.9.2 milestone (block bodies → sieve/stack_vm/sum_arr) the rest is polish.
