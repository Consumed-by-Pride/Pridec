# PEAR-bro handoff — v0.8.9 (2026-09-30, pushed to `dev`)

## Summary
On top of v0.8.8 (multi-byte pointer indexing), this round:
1. Adds ACMD_MATCH handling in PearCg.cmd() (was falling through to
   unreachable → ud1/SIGTRAP 133 for clause-style functions).
2. Extends ACNS_CASE dispatch to recognize single-irrefutable-arm
   matches (wildcard `_` or unit `()` tuple with 0 sub-patterns) and run
   the body directly without a condbr — exactly what clause-style
   `fn f : () -> i64 | () -> 42` lowers to.

## Scoreboard: 29 PASS / 0 XFAIL / 0 FAIL
All of:
- p01-p08 core (return/arith/fib/sum/call/tak/mut-reassign/if-else)
- p90 u8 indexed store/load (a[0]=7; return a[0])
- p91 loop indexed writes + read (i64*, correct element-scale)
- p92 clause-style fn body `| () -> 42` → 42 (was SIGTRAP, blocker for every
  stdlib/conformance/bench-kernel file)
- p93-p98 Agent-3 block-scope/shadow/tail/while-return/break/many-bindings
- p99 cross-module forward call (Agent-3 bug O fix verified)
- p99/p99b multi-byte i64/i32 indexing
- p100-p108 Agent-3 nested-fn/struct/nested-loop tests
- bench/sum_to=0, fib=200, tak=100 green across O0/O1/O2.

## Files changed (pear.c3)
- Added `case ACMD_MATCH` in PearCg.cmd(): builds a stack-allocated
  zero-initialized ACNS_CASE (copying branches[] from the ACMD_MATCH),
  evaluates scrutinee, dispatches via cg.cns(sv, &kase). Careful to
  initialize every pointer slot (branches[], cobranches[], subst_vars[],
  subst_prds[], label_args[]) — leaving them as uninitialized stack
  garbage caused cns/cmd infinite recursion via k.body pointing into
  garbage and tripping the COMU-handler dispatch.
- In ACNS_CASE dispatch, added a single-arm irrefutable-match shortcut
  BEFORE the boolean two-arm setup. Triggers only for APAT_WILD or
  APAT_TUPLE with sub_count==0 (the unit pattern `()`); otherwise falls
  through to the existing bool condbr logic.
- ACNS_ASCRIBE case (added in earlier aborted round but retained):
  passes v through to k.tail (type ascriptions are semantic-only).

## Critical note for next agent
The zero-initialization of the on-stack AirCns in ACMD_MATCH matters:
C3 does NOT zero stack locals. The first iteration of this patch had a
`for zi=0..AirCns::size` byte-clear loop that the codegen miscompiled
(Access Violation SIGSEGV in the compiler itself, not in the generated
binary), so I replaced it with per-field explicit null/zero writes plus
explicit loops over the fixed-size pointer arrays. If you add more
pointer fields to AirCns in future, update the init block to null them.

The single-arm detection MUST check pat.tag and sub_count. If you just
do `n_arms==1 && !has_bool_arm → single_cmd`, you will accidentally
match ACNS_CASE nodes whose ONE arm is reached via COMU tail, producing
`cg.cmd(single_cmd) → cg.cmd(k.body) → cns(ACNS_CASE) → single_cmd`
infinite recursion (SIGSEGV in Instruction::clone at -O2, stack overflow
at -O0). Restrict to actual irrefutable patterns.

## Remaining known issues (v0.8.10)
- __pear_alloca → malloc (cg.malloc_fn is already declared) and re-enable
  nofree on non-Alloc functions; bench/sieve, stack_vm, sum_array kernels
  should then work end-to-end (multi-clause patterns needed for sieve
  may still need ACNS_CASE variant-tag support).
- Restore default<O0> pipeline now that GEP types match pointee (FastISel
  crashed on the old (0,idx) double-index GEP).
- Multi-clause pattern matching (variant / integer arms) in ACNS_CASE;
  only 2-arm bool + single-irrefutable-arm work today.
- ~40 advisory passes still counting without mutating.
- Duplicate libc definitions (getpid/getppid/...) warn at every compile —
  pear_dup_def should be suppressing them but only catches function
  names in the current AirModule, not prelude-injected ones.

## Build / run
```
bash scripts/agent3-build.sh
make test-pear     # 29 PASS / 0 XFAIL / 0 FAIL
```
