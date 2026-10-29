# PEAR 2 effect semantics — design gate for anything beyond escape-only

Status: **normative gate** (Linear AYO-10). No lowering work past the current
escape-only subset (M10) may land until this spec is ratified. Everything here
is written against the shipped implementation so the cost of conformance is
known, not guessed.

## 1. What exists today (the floor)

M10 lowers exactly one effect shape, the **one-shot escape handler**:

- `handle { body } { (op v %r -> arm) }` where `%r` (the resumption binder) is
  used at most once, in tail position, with no surrounding binders that would
  extend its lifetime. Lowering: the active handler owns a **payload slot**
  (register `fx_` prefixed value); `perform op arg` rewrites to a direct jump
  into the handler's arm block with the argument stored in the slot; the arm
  runs as the direct successor; control never resumes the performer. The
  join is a plain block merge — the handler behaves like an early-exit branch.
- Anything else **fails closed with file:line:col** (asserted by nine M10
  reject fixtures in run.sh): multi-shot use of `%r`, `resume` as a command or
  producer, cc-pinned `main` carrying effects, handlers nested inside handler
  arms, effect operations with un-inferrable payload types, wasm32-freestanding
  + any effect form, carried-binding captures crossing the handler boundary.

Properties of the floor that every extension must preserve:

1. **Escape-only code is allocation-free.** No stack frames, no CPS closure
   chain, no runtime handle table. The payload slot is an `alloca` that
   mem2reg promotes away whenever it can.
2. **Handlers are lexically scoped.** Dynamic extent === textual nesting; an
   effect can never be handled outside its enclosing `handle`.
3. **Zero-cost when unused.** Modules without `handle`/`perform` emit
   byte-identical IR to what they emitted before M10 (x86_64 default output
   layout is unchanged — regression-locked by the 108-fixture suite).
4. **wasm32-freestanding accepts zero effect forms.** This is deliberate: a
   freestanding wasm target has no host stack to unwind/probe, and no runtime
   so far; keeping it closed is cheaper than two half-implementations.

## 2. The resumption contract (what M4+ would be buying)

### 2.1 One-shot vs multi-shot

A resumption is **one-shot**: `%r` invoked at most once, on exactly one
dynamic path out of the handler. It is **multi-shot** if invoked more than
once (any path, any nesting). The current floor handles *zero*-shot (escape
to handler without resumption). Stepping stones, in order of difficulty:

| tier | meaning | implementation cost | runtime cost |
|---|---|---|---|
| **T1 escape-only** (DONE) | handler returns, performer abandoned | jump + merge | free |
| **T2 one-shot, same-stack** | `%r` invoked once, tail-position, from the arm's dynamic extent | linearize the continuation region as a tail-called block chain; `%r` = jump-with-value | 1 extra jump |
| **T3 one-shot, arbitrary position** | `%r` stored in locals/aggregates, invoked once anywhere | delimited continuation = explicit CPS slice per handled region, heap-allocated continuation record | alloca+heap per `handle` |
| **T4 multi-shot** | `%r` invokable N times (requires copyable continuations or abort-on-second-call) | CPS + copyable stack segments (segmented stacks) or fork-per-resume | per-shoot copy; correctness cliff on aliased mutation |

**Decision this doc proposes: implement T2 next, keep T3 behind a runtime
spec, forbid T4 entirely until a memory model for continuation capture
exists.**

Rationale: T2 covers the code people actually write (event streams, optional
short-circuits, generators without back-pressure) at integer-additional cost.
T3/T4 costs follow you on every function frame, not just effectful ones, in a
delimited-CPS world; that violates the spec's "zero-cost when unused" law
unless the CPS transform is *local* to the handled region — which is exactly
what makes it T3-class difficult.

### 2.2 What `%r` captures (per tier)

- T1: nothing. The binders in scope at `perform` are dead; aliasing is
  impossible; current provenance model suffices.
- T2: `%r` = the *lexical remainder* of the handled body after the perform
  point, as a block chain. Captures: all live covars at the perform site.
  Constraint validated by the existing M9 machinery: any covar that would be
  captured by `%r` AND by a heap-allocated closure (M8 lambda lift) crossing
  the same perform boundary is a **compile error, positioned** — the
  phi-promotion lattice already computes the live sets, this is a re-check,
  not new analysis.
- T3: `%r` = heap record `{ regs*, relo }`; pointer-carrying covars need
  lifetime rules per the provenance model; mutation of a captured cell after
  `%r` becomes visible to the resumed body — document as *observable* and
  fixture-lock the behavior so it can't drift silently.
- T4: block until T3 semantics written + aliasing decided.

### 2.3 Continuation binder typing

`%r : (payload_t) -> ret_t`. Escaping form only: today's rewrite discards the
type because `%r` never materializes; T2 materializes as block-chain entry
taking one LLVM phi-parameter; T3 materializes as a fat closure `{code, env}`
sharing representation with M8 closures — the tests for call/apply and the
pair-ABI plumbing are reused verbatim (this is the strongest argument that
closure+effect share one calling convention; keep it).

### 2.4 Nesting rules

- Inner handlers may install inside outer `handle` bodies: allowed in T2 as
  long as resumption never crosses an inner-arm boundary upward (the return
  continuation passes under an outer arm's dynamic extent = reject,
  positioned).
- `main` never carries effects; compositional (non-`main`) functions with
  effects must declare them. Effect-inference for internal calls exists in
  pfront (`pfront_effectinfer.c3`); PEAR 2 consumes the declared AIR effects
  verbatim, and AIR3's effect annotations map to the `cc`/`attr` channel.

## 3. Interaction with the two in-flight optimizations (must not re-decide)

1. **Phi promotion (M9).** Label/jump CFG with promoted allocas runs BEFORE
   handler lowering; a `perform` never crosses a region boundary in T2 — the
   label a perform jumps to is always the handler's own arm label. Encode:
   air-verify checker that `perform` sites name only lexically enclosing
   handler arms.
2. **Closure lifting (M8/M10 coexistence).** A lambda lifted through a handled
   region must not capture `%r` (it would become a heap cell with
   continuation semantics — whatever T4 decides, M8's escape-analysis phase
   must treat `%r` as *always-escaping* so the attempt fails closed today).
   Add a positioned reject fixture for lambda-mentions-`%r` (M10 r5 already
   rejects *some* of this; check vs. full closure capture lattice).

## 4. Target profiles

- **x86_64 (default):** T2/T3 implementable; T4 = segmented stacks or
  copyable CPS slices — revisit only with real benchmarks.
- **wasm32-freestanding:** keep reject-all until a host environment exists
  (MVP has no stack unwinding; `wasm-ld` link gate exists since AYO-9 and
  would catch a broken emission immediately).

## 5. The gate

A PR-sized slice extending effects past T1 must:

1. Amended version of this document with concrete IR examples committed
   alongside (the examples become fixtures).
2. At least one positioned-reject fixture for every *remaining* unsupported
   shape (so the reject set shrinks, never silently changes).
3. Suite evidence: 108+ PASS/0 FAIL incl. `-O0..-O3` sweeps of handler
   fixtures; bitcode+executables byte-deterministic (6.2/6.3 checklist).
4. Zero regression on non-effect modules (IR byte-diff identical).
5. Linear: AYO-10 comment + project update; checklist §5.18 row re-scored.

Today's floor (M10) is the regression baseline for all of the above.
