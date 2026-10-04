# AIR 3.x upgrade pass — agent5 reboot
Branch policy: format EVOLVES, no freeze yet.

## Pass 1: Cap audit (land first, no semantics changes)

Fixed-size arrays in air_ir.c3 / air_low.c3 that silently truncate.
Target: replace with `realloc`-backed dynamic arrays (or bump-alloc against
the arena) so limits become "bounded by memory", not "silent truncation at N".

### Cap inventory (from grep)

**air_ir.c3 (AIR 2.x — still used by --emit-air):**
| cap | where | meaning |
|---|---|---|
| 256 | AIR_MAX_SLABS | arena slab count |
| 16 | AirCoBranch.binders[16] | cobranch binders |
| 64 | AirCtorDecl.fields[64] | record constructor fields |
| 64 | AirDtorDecl.params[64] | dtor parameters |
| 64 | AirTyp.args[64] | type args / tuple arity |
| 64 | AirCns.rec_fields[64] | record literal fields |
| 64 | AirPat.sub[64] | sub-patterns |
| 64 | AirPat.fields[64] | record pattern fields |
| 16 | AirCmd.binders[16] | μ̃/let binders |
| 64 | AirCmd.branches[64] | match branches |
| 64 | AirCmd.cobranches[64] | cocase branches |
| 16 | AirCmd.label_args[16] | label phi args |
| 16 | AirCmd.subst_vars[16] / subst_prds[16] | substitutions |
| 64 | AirCmd.prds[64] | stack-call operands |
| 16 | AirCmd.mbinders[16] | mutilde binders |
| 64 | AirDecl.ctors[64]/dtors[64]/params[64] | decl items |
| 16 | AirEffectDecl.ops[16] | operations per effect |
| 8 | AirDecl.attrs (8) | attributes |

**air_low.c3 (AIR 3.0 low profile — the hot path):**
| cap | where | meaning | priority |
|---|---|---|---|
| 4096 | MAXFN | functions per module | bump to 65536, easy |
| 1024 | MAXST/MAXGL | structs/globals | bump |
| 8192 | MAXBLK/MAXVAR | blocks/vars per fn | bump |
| 8 | FnInfo.pnames[8]/ptys[8] | fn params → **MUST lift** (64 already declared as MAXA but struct still uses 8) |
| 8 | FnInfo.jargs[8] | jump/phi args → **MUST lift** |
| 8 | UniI.fnames[8]/ft[8] | struct/union fields |
| 32 | Enm.v[32] | enum variants (currently 32, bump to 256) |
| 8 | HndI.g[8]/hty[8]/cty[8] | handler ops (MAXA=64 but struct 8) → **MUST lift** |
| 16 | HndI.f_arg[8]/f_rv[8] | fiber frame arg/rvalue slots → **MUST lift** for multishot |
| 64 | LowCx.loops[64] | nested loops (64 is plenty, bump to 256) |
| 16 | LowCx.defers[16] | nested defers (bump) |
| 64 | LowCx.hopn[64]/hopt[64] | handler op table (bump to MAXA) |
| 256 | LowCx.hnds[256] | handler instances (bump) |
| 64 | LowCx.litd[64]/litt[64] | literals (bump) |
| 256 | Node*[256] arms | pattern arms (line 5383, match lowering) → lift |

The existing MAXA=64 constant sets the target for params/args/tuples, but
the structs still hard-code [8]. The pattern is: declare MAXA=64 as
today but struct fields should use `[MAXA]` consistently; then raise
MAXA to 256 and make the few arrays that need more dynamic.

### Order of work
1. Add a `Dyn(T)` helper in C3 (realloc-backed) for cases where static
   caps are wrong (variant ctors, match arms, handler ops, closure caps).
2. Replace FnInfo/UniI/Enm/HndI fixed [8]/[32] with MAXA/MXC/MXO defines.
3. Bump MAXA 64→256, MAXTP 8→16, add MAXOPS=256 for handlers.
4. Make arrays (literal, init) dynamic: ar03 already allows >64 in memory
   but the literal_vec is Vx[64] — bump to 256.
5. Add diagnostic "count N exceeds cap" BEFORE the silent truncation
   everywhere (today `if (n >= cap) continue;` silently drops).
6. Run `make test-air3`; floors must not decrease.

## Pass 1: Cap audit (DONE — commit 7ada155)

Landed. All previously-[8] phi/handler/struct/enum arrays bumped to MAXA/MAXOPS.
Diagnostic added for jump-arg overrun (was silent truncation). Gate green.

## Pass 2: Multi-shot continuations (DESIGN, not yet coded)

Current state (from reading runtime/compiler_rt.c §4 fibers):
- One-shot fiber resume works. `PrideHandlerFrame.resume_used` flag traps on double resume.
- Snapshot buffers (`f->saved/saved_size`) already exist for the prompt-snapshot mechanism
  (used by split_cont / fuse_cont for delimited control).
- PrideFiber has ucontext_t + 128KB stack + caller pointer. swapcontext is the
  transfer primitive.

To make multi-shot work:

### Runtime additions (compiler_rt.c):
1. `PrideFiber* __pride_fiber_dup(PrideFiber* src)`:
   - Allocate new PrideFiber + new 128KB stack (or use a size stored on the fiber).
   - memcpy the stack contents from src->stack to new stack.
   - getcontext on new uc, set uc_stack to new stack; then we need to relocate the
     ucontext's registers (RSP/RBP) by the delta between new stack and src stack.
     Trickier than a flat memcpy because of absolute pointer-to-stack values in
     callee-saved registers and in frames that took addresses of locals. Safer
     approach: use the existing `saved/saved_size` snapshot mechanism (which already
     memcpy's the portion of stack between prompt marker and current RSP) and
     restore into a FIBER DUPLICATE rather than always in-place.
   - Simpler alternative that works with the current snapshot design: multi-shot
     handlers DO NOT use the fiber path (which is for non-tail resume). For
     multi-shot TAIL resume (the common backtracking/`choose` case), we don't need
     fibers at all — a tail resume returns to the perform site and continues.
     Multi-shot TAIL resume is just "save continuation state as a thunk that can
     be invoked multiple times" — thunks are heap-allocated closures over the
     saved snapshot, and invoking the thunk memcpy's the snapshot back and jumps.
   - For non-tail multi-shot (less common, e.g. backtracking that produces a list
     of results and then continues iterating), need fiber dup with stack relocation.
     Postpone this; get tail multi-shot working first.

2. Per-handler-instance `shots` counter (i64, -1 = infinite):
   - Set up by the handler prologue (air_low emits a store to a frame slot).
   - `__pride_resume` checks shots; if shots > 1, dup the current fiber/snapshot
     before swapping, decrement counter on the copy, let the copy run, then
     continue the arm on the original.
   - If shots == 1 (one-shot, default), fall through to existing code.
   - If shots == 0, trap (resumed more times than allowed).

### AIR/air_low additions:
- New attribute on `handle`: `handle/shots(N)` (N = integer literal, -1 for ∞).
  Without `/shots`, one-shot as today. Default stays one-shot (so no perf
  regression for existing code).
- If a `resume` appears in tail position inside an arm of a multi-shot handler,
  emit the thunk-based path (snapshot closure); the arm's continuation ends with
  a call of the thunk which re-runs the body; after body returns, next call
  runs the next arm (like `amb`/`choose`).
- If a `resume` appears in non-tail position in a multi-shot handler, lower to
  fiber_dup + fiber_resume; error out on non-native targets (wasm/freestanding).
- Add `choose` and amb operators as syntax sugar over multi-shot perform (separate
  PR after the runtime change lands).

### Tests to add:
- `ms01_choose_backtrack`: `choose(1,2,3)` produces three answers; handler collects
  into a list (tests multi-shot tail).
- `ms02_double_resume_trap`: one-shot handler resumed twice panics (already covered
  by ef07 but add an explicit test).
- `ms03_nested_multishot`: nested `handle` with inner multi-shot / outer one-shot.
- `ms04_fib_multishot`: fib via ambiguous `choose` backtracking enumerates
  solutions, terminates.

### Order of implementation:
1. Add `__pride_fiber_dup` to compiler_rt.c (simple mmap + memcpy version first;
   may have register-relocation bugs but good enough for bring-up).
2. Add shots counter and snapshot-based multi-shot in `__pride_resume`.
3. Extend AIR3 syntax: `handle/shots(N)` modifier.
4. Extend air_low.c3 HndI with `shots` field; emit the counter init in the
   handler prologue; pass shots flag to runtime calls.
5. Add ms01_ms04 tests.
6. Run gate; floors must only increase.

Do NOT start multi-shot until a test exists that exercises the snapshot dup
cleanly — fiber stack pointer relocation is the hard part and writing tests
first saves days.
