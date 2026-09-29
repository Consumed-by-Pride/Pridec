# Agent-3 audit — the theory layer: what is claimed vs what runs

**Question being answered:** "MSP, IRDL, Semantic Subtyping all don't do anything, just meh."
**Method:** static wiring (is the subsystem invoked?) + runtime probe (does it react?) + reading the
decision procedures it claims to implement. Compiler built from `origin/z` @ `1893bbe`, LLVM-23.
**Date:** 2026-09-30.

Reproduce anything here with the commands inline. `./pfrontc <file> --emit-ast` prints the theory report.

---

## Verdict up front

Not empty and not dead — **wired, invoked, and shallow**. Every subsystem below runs and prints
numbers. What the numbers are *not* backed by is a decision procedure or a transformation. The
pattern is consistent enough that I'd call it the layer's defining property: **counters where the
headers promise decisions.**

---

## 1. Semantic subtyping — the engine is never called (and couldn't decide much if it were)

**Claim** (`theory_subtype.c3` header): implements set-theoretic semantic subtyping — distributivity,
contradiction, excluded middle, De Morgan.

**Finding A — it is never invoked.**

```
$ ./pfrontc /tmp/c.pie --emit-ast | grep 'semantic subtype'
    semantic subtype : 0 queries, 0 cached, 0 emptiness checks
```

`theory_check.c3` allocates it (`:600`), inits it (`:642`), reports it (`:1131`) — and **there is no
call to `tp.semsub.subtype(...)` or `.walk(...)` anywhere in the file.** The engine is a
well-dressed struct that gets printed once per compile. It has never seen a type.

**Finding B — the deeper engine is dead code.**

`theory_subtype_full.c3` (403 lines, "FCB semantic subtyping … Frisch/Castagna/Benzaken 2008 §4-6")
is `import`ed at `theory_check.c3:58` and **its functions are called from nowhere in the repository.**
The FCB emptiness procedure — the one file that really tries to decide things — is never executed.

**Finding C — the live decision procedure can't decide `int ∧ bool`.**

`theory_subtype.c3:460` is the emptiness test everything rests on:

```c3
fn bool Clause.is_empty(Clause* c)
{
    for (usz i = 0; i < c.count; i++) {
        Atom* a = &c.atoms[i];
        if (!a.negated && a.kind == AtomKind.AT_BOTTOM) { return true; }
        if ( a.negated && a.kind == AtomKind.AT_TOP)    { return true; }
    }
    return false;
}
```

That recognises literal `⊥` and `¬⊤` and nothing else. So `int ∧ bool` is **not** empty, `A ∧ ¬A` is
**not** empty unless the negated copy is syntactically the same node, and every headline example in
the file's own header — distributivity, contradiction, excluded middle, De Morgan — is undecidable.
The `subtype()` loop above it is a correct DNF skeleton (`A ≤ B` ⟺ `A ∧ ¬B` empty) whose atom-level
emptiness check is a stub-lite; the shape is right, the substance is missing.

## 2. MSP / staging — a counter, not a checker

**Claim** (`theory_msp.c3` header): CMTT with the modal judgment `Γ ⊢^E e : □` ; "a quote that escapes
its stage **is an error, not a warning**".

**Finding:** it is neither. I compiled a splice at stage 0 — a genuine level violation — and a quote
capturing a stage-0 binding:

```
$ cat /tmp/stage2.pie
fn main(_) -> i64 {
  let y: i64 = 5;
  splice { return y; }
  return 0;
}

$ ./pfrontc /tmp/stage2.pie --emit-ast | grep -E 'staging|soundness|checker'
    checker          : 2 decls, 9 exprs, 0 errors
    staging          : 0 quotes, 1 splices, 0 boxes (max stage 0)
    stage soundness  : 0 escapes, 1 splices at stage 0, 0 legal cross-stage
```

**`1 splices at stage 0` — counted, and `0 errors` — not reported.** The same run on the quote-capture
case reports `2 escapes, 0 splices at stage 0` and also compiles clean. The error path exists
(`sc.diags.error(... PH_RESOLVE, 3200/3201/3202/3203 ...)`) and is simply not reached from the
conditions that increment those counters. A checker that detects violations, records them as
statistics, and returns success is worse than no checker: it reports safety it doesn't provide.

## 3. IRDL — it parses dialects, it lowers nothing

**Claim** (`theory_irdl.c3` header): "two compilers that both turn declarative descriptions into
executable selection structures", with PGL pattern generation for lowering user-declared opcodes.

**Finding:** dialect and opcode declarations from real source are registered correctly:

```
$ cat /tmp/dial.pie
dialect GpuD
  opcode gadd
  opcode gmul
fn main(_) -> i64 { return 0; }

$ ./pfrontc /tmp/dial.pie --emit-ast | grep irdl
    irdl dialects    : 1 dialects, 2 opcodes, 0 uses validated
    irdl lowering    : 0 lowered, 0 unknown-op, 0 arity errors
```

The front half is real — it found my dialect and both opcodes. The back half is absent: **nothing
lowers a declared opcode to anything.** `0 uses validated` and `0 lowered` are not because my test
program has no uses (it doesn't — that's the honest reading); it's because there is no
declared-op → AIR/LLVM lowering path to call. A user can declare an opcode and never be able to use it.

## 4. The general shape of the layer

TheoryPipeline (`theory_check.c3`) declares **54 subsystem fields** and invokes all but a handful —
timing, liveness, egraph, abstract interpretation, the verifier, the SAT-ish refiner, 12 more. So the
honest description is *"46 passes, each walking the AST and reporting counters"*, with real logic in
some (liveness, abstract interpretation, the egraph machinery) and headline-shaped logic in the
files carrying the headline names.

---

## What I am going to do about it

Per instruction: **complete these, no stubs, verified.** Order, because correctness builds bottom-up:

1. **Semantic subtyping → a real decision procedure.** Atom-level emptiness with primitives, nominals,
   products, arrows (contravariant, with splitting), closed records; DNF + memo; `A ≤ B` ⟺ `A ∧ ¬B`
   empty. A **property suite** that must pass: De Morgan, distributivity, excluded middle,
   contradiction, transitivity, reflexivity, plus the FCB paper's examples — run as an executable test,
   not a claim. Then wire it into the pipeline so `semantic subtype: N queries` is non-zero on real
   programs and failures produce diagnostics.
2. **MSP → a real staging checker.** Reach the error path: level violations emit diagnostics; quote
   capture analysed per-rule with the CMTT judgment, not counted.
3. **IRDL → a real lowering path.** Declared opcodes get lowered through PGL patterns to AIR and
   executed.

Tracked in `A2A/todo.md`. Every slice lands as a branch + ready PR with the test output pasted in.

-- Agent-3
