# Roadmap — the AIR middle end

The goal, in your words: **`pfront` emits a rich AIR, that AIR is optimised over
and over, and only then does a backend see it.**

Today that middle end does not exist (see `PROJECT_MAP.md`). This is the ordered
path to it. Each phase has a **gate** that is a command producing a number, so
progress is visible without an LLVM build and without trusting a doc.

Rule that applies to every phase: **a pass is not done until it has a test that
fails when the pass is disabled, and a number that moved.** No new pass without
both. That rule is the direct answer to the 44 modules in §3 of the map.

---

## Phase 0 — a baseline you can see

**Problem.** Nobody can say how much the AIR improves, because nothing measures
it.

**Do.** `scripts/air-stats.py` (or a `airtool stats` mode, already present in
`airtool`) over the corpus, recording per program:

```
producers   commands   allocas   loads   stores   blocks   instrs/function
```

and `scripts/air-baseline.tsv` checked in. `make air-baseline` regenerates it and
fails if any count *rises* for a program that has not changed.

**Gate.** `make air-baseline` prints a table for all 84 exec programs and the 35
air3 programs. No LLVM needed: `pfrontc --emit-air-low` is enough.

---

## Phase 1 — the pass manager (the missing engine)

**Problem.** There is nowhere to put a pass. `pfront` writes AIR and exits; the
only AIR optimiser lives inside one backend (`pear2_opt`), so a second backend
cannot use it.

**Do.** `airtool opt FILE.low.air`:

* `--passes=mem2reg,dce,gvn` — a pipeline string, run in order;
* each pass is `bool Pass.run(AirModule*)` returning "changed", and the driver
  iterates the whole list to a fixpoint with a round cap (the `theory_opt` driver
  already shows the shape);
* **`verify` after every pass** — a pass that produces an invalid module names
  itself instead of corrupting a downstream file;
* `--print-after=<pass>` writes `FILE.<pass>.air` so a diff is the review;
* `airtool opt` writes `FILE.opt.air`; the input is never touched.

**Gate.** `airtool opt --passes=nop` reproduces every corpus `.low.air`
byte-identically (round-trip through the reader/writer is lossless at this
stage), and the corpus still builds and runs. That is the harness P2 rides on.

**Effort.** ~400 LoC for the driver + registry; the reader/writer already exist
(1,412 + 867 LoC).

---

## Phase 2 — mem2reg: the pass that makes the AIR worth optimising

**Problem.** Every `let mut` is `alloca` + `load` + `store`. Nothing else can
work well on that shape: GVN sees stores, LICM sees memory, and LLVM's mem2reg is
what turns it back into SSA today. The front end is emitting the *output* of a
bad interpreter rather than an IR.

**Do.** Promote non-escaping allocas to SSA:

1. an `alloca` is promotable when its address never leaves the function (no
   `store` of it, no `gep` out of it, no call argument, no return);
2. place block parameters (AIR already has jump arguments = φ) at the iterated
   dominance frontier of every def;
3. rename: each load becomes the reaching value; each store's value becomes the
   definition.

`theory_ssa` already implements exactly this computation over a CFG — dominators,
DF, phi placement, renaming, plus a self-audit. Port it to work on the AIR block
graph instead of the AST, or lift the algorithm and reuse `air`'s block list.
`air_facts` (323 LoC) can carry the "address collected" bit.

**Gate.** `allocas == 0` for every program in the 84 + 35 corpora, **and** the
output is unchanged. This one pass typically removes 40–60 % of the AIR
instructions for straight-line code, and it is the prerequisite for P3–P5.

---

## Phase 3 — a real InstCombine

**Problem.** `pear2_opt` has the folding (`fold_binary`, `fold_coerce`,
strength reduction, reassociation, 2,097 LoC) but it is *in the backend*, so the
AIR that comes out of `pfront` is unoptimised, and a second backend duplicates
it.

**Do.** Move the expression-level rewriting to `pfront`, phase by phase, gated by
the existing `tests/pear2/opt_*_main.air` fixtures translated to the new driver.
Then delete the copies in `pear2_opt` so there is one implementation.

**Gate.** For every fixture in `tests/pear2/opt_*`, the AIR after `airtool opt`
contains the folded form; `pear2_opt` shrinks by the moved LoC.

---

## Phase 4 — the passes that were analysed but never written

Now the 44 modules become useful, in the order their payoff justifies the work:

| order | pass | source to port | why here |
|---|---|---|---|
| 1 | DCE / ADCE | `pfront_dfe`, `pfront_adce` | everything else creates dead code |
| 2 | GVN / CSE | `pfront_gvn`, `pfront_cse` (value numbering already written) | needs SSA from P2 |
| 3 | LICM | `pfront_licm` (loop tree already computed) | needs SSA + loop info |
| 4 | inlining | `pfront_inline` (heuristics written) | unlocks everything downstream |
| 5 | strength / VRP / range | `pfront_strength`, `pfront_vrp`, `pfront_range` | needs the folding from P3 |
| 6 | SCEV / indvars | `pfront_scev`, `pfront_indvar`, `pfront_induction` | loop exit tests, unrolling |
| 7 | jump threading / tailcall | `pfront_jumpthread`, `pfront_tailcall` | cheap, visible |

For each: the analysis half already exists and is correct enough to *report*; the
work is the rewrite half, which is the part that was never written. That is why
"convert 44 analyses" is not "44 × small" — it is 44 × (a rewrite + a test).

Anything not on this list gets **deleted or moved to `attic/`** with a line
explaining what it would have been. Keeping dead code is what made the project
look 11.5 kLoC further along than it was.

---

## Phase 5 — structured AIR, then lower

**Problem.** `air_low` goes from AST straight to machine shape: closures become
`{fn, env}` records, effects become fiber calls, `match` becomes a branch chain.
Every one of those is easier to optimise *before* the explosion, and today the
only IR above that explosion is the PNode AST — which has no SSA, no dominance
and no φ.

**Do.** Split the lowering in two:

```
PNode --lower--> AIR-high (closures, match, effects intact, SSA lets)
                      │  run phases 1–4 here, where the structure is rich
                      ▼
                AIR-low  (existing air_low profile: alloca/load/store/gep)
                      │  run phase 2/3 again (cheap, local)
                      ▼
                 backends: text translation only
```

AIR 2.0 already **is** a structured AIR (`air_lower`, 4,466 LoC, closures as
`{fn,env}`, match as `case/cocase`, effects as handler cells). The cheapest
version of this phase is: make AIR 2.0 the optimised middle, then emit AIR 3.0
from it instead of from the AST, and delete the second AST walk. That deletes a
4,466-line lowering or a 5,638-line one — pick after measuring which is closer to
what the backends actually consume.

**Gate.** One lowering, not two; the 84 + 35 corpora produce identical behaviour
through it; `air_low` and `air_lower` do not both walk the AST.

---

## Phase 6 — backends become dumb

The point of the whole exercise. When phases 1–5 are done:

* `pear2c` loses `pear2_opt` (moved to P3) and keeps only: AIR → LLVM IR, plus the
  memory-provenance checks that are its actual value.
* `airtool emit-ll` (the reference consumer) becomes the *check*: two independent
  AIR→LLVM translators agreeing on a corpus is what proves the AIR is well
  defined.
* the native `pear2_x64` stops needing its own peephole work.

**Gate.** `pear2c` and `airtool` produce the same exit codes and stdout for all
84 programs, from the same optimised AIR, with optimiser code in neither.

---

## What this does to the numbers

| | today | after P2 | after P4 |
|---|---|---|---|
| passes that mutate AIR | 0 | 1 | 7+ |
| `alloca` in the ARM of a 20-line program | 1 per mutable local | 0 | 0 |
| dead pass modules | 44 | 44 | 0 (converted or deleted) |
| AIR optimiser implementations | 1 (in a backend) | 1 (in pfront) | 1 (in pfront) |
| front-end lowerings | 2 | 2 | 1 |

That last row matters as much as the first: the project currently has two front
ends' worth of lowering to keep in sync, and no middle.

---

## Order of work, one line each

1. `scripts/air-stats` + baseline TSV — *see the AIR.*
2. `airtool opt` driver + verify-after-pass — *have somewhere to put a pass.*
3. mem2reg — *make the AIR worth optimising.*
4. move folding out of `pear2_opt` into `pfront` — *stop duplicating.*
5. DCE → GVN → LICM → inline → … — *start the hundreds of times.*
6. one lowering, structured AIR — *fix the layer that is missing.*
7. backends to text translation only — *finish what the plan promised.*
