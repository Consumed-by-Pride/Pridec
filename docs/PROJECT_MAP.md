# Where the project is — measured, not remembered

Everything here was produced by running commands against this checkout
(`af8894d` + the step-A split), not by reading the docs. Where a number is a count of code it is a
line count of the files named; where it is a claim about behaviour the evidence
is named, and the absence of evidence is stated as absence.

---

## 0. What changed since this map was written (step A, the AIR split)

The AIR layer is now cut in two and the cut is enforced by a test, not by
convention. The front end and every consumer are separate builds of separate
halves:

| side | lines | contents | linked by |
|---|---|---|---|
| `AIR_CORE` | 1,045 | `AirTyp`/`AirPrd` types, text helpers, `ty_*`, `Sb`, `cc_*` | everyone |
| `AIR_EMIT` | 13,623 | `air_low`, `air_lower`, scope/types/audit, the writer, `air_fold` | `pfrontc` |
| `AIR_MID` | 629 | `air_pass` (228), `air_facts` (323), `air_roundtrip` (78) | tools |
| `AIR_USE` | 3,241 | reader (1,412), verifier (384), linter (238), LLVM printer (1,207) | `pear2c`, `airtool` |

`make air-boundary` fails if a module on one side imports a module on the other.
`nm ./pfrontc` now contains **zero** symbols from `air_read`, `air_verify`,
`air_ll` or LLVM's C API; it used to link all of them through a wildcard.

Two modules had to be reclassified because the guard caught them: `air_facts`
is an analysis that *writes* facts into the module (MID), and `air_roundtrip`
lowers a program before it can round-trip it (MID, single named exemption).
`--air-roundtrip` left the compiler for `airtool`.

Measured E2E after the split: `hello.pie` → `pfrontc --emit-air-low` →
`airtool verify-low` (0 errors) → `pear2c --emit-exe` → exit 5. And
`tests/pear2/run.sh` reaches 25 PASS and stops at the same `typed_memory_main`
failure as before the split, so the split caused no regression.

## 1. The one-page answer

You wanted: **`pfront` emits a rich AIR, then that AIR is optimised over and over
until it is tight, and only then do backends look at it.**

What exists: `pfront` **translates** the AST to AIR once and writes it out. There
is **no AIR-to-AIR optimisation anywhere in `pfront`**. The optimising that does
happen is on the *AST* (three pass families, ~2.4 kLoC of real rewriting) and in
the *backend* (`pear2_opt`, 2.1 kLoC) and in *LLVM* (which does the heavy lifting
today).

Around that thin middle end sits a large amount of code that never runs:

| | | |
|---|---|---|
| **44** pfront modules | **11,517 LoC** | optimisation/analysis passes with **no importer anywhere** |
| those 44 modules | **0** tests | no test script mentions any of them |
| those 44 modules | **0** tree mutations | every one is read-only: it counts, it reports, it changes nothing |
| **47** theory modules | **42,804 LoC** | ~40 analyses that run per compile and mostly *report* |
| **3** ways to lower a program | | `air_lower` → AIR 2.0, `air_low` → AIR 3.0, and both straight from the AST |
| **2** state-of-the-docs sets | 3,885 + 2,548 lines | describing a pipeline that has never been executed in this sandbox |

So the answer to "where did the hundreds-of-times improvement go" is: **it was
never built as a transformation.** It was built as *analysis* — 11.5 kLoC of
passes that look at the CFG and print how much *could* be optimised, wired to
nothing.

---

## 2. What actually runs, in order

`make pfrontc` compiles 122 pfront modules; `pfront_main` reaches 76 of them.
The pipeline, in execution order:

```
 file.pie
   │
   ├─ pfront_lex        2,371      tokens
   ├─ pfront_parse      5,832      PNode tree
   ├─ pfront_resolve    2,465      modules loaded, names bound
   │
   ├─ pfront_ext        1,240      effects, lints, exhaustiveness (report)
   ├─ pfront_sema       1,559      module graph, visibility, const eval
   ├─ pfront_types      1,153      type table
   ├─ pfront_infer      1,132      HM inference (opt-in; Pride is untyped by default)
   ├─ pfront_narrow       857      coercion insertion
   ├─ pfront_check      1,189      traits, coercions, access
   ├─ pfront_flow         770      call graph, reachability, effect fixpoint
   │
   ├─ pfront_constfold    983  ◀── TRANSFORM   (folds literals, kills branches)
   │
   ├─ TheoryPipeline   42,804  ◀── ~40 passes; three of them mutate the tree
   │     … absint, live, subtyping, PGL, IRDL, CMTT, NBE, symexe …
   │     └─ theory_opt  1,670  ◀── TRANSFORM   (fold, branch fold, DCE, copy prop)
   │
   ├─ pfront_sccp         799  ◀── TRANSFORM   (conditional constant propagation)
   ├─ pfront_constfold         ◀── TRANSFORM   (again, to clean up after SCCP)
   │
   ├─ air_lower         4,466      → AIR 2.0  (legacy: pear1c's input, --emit-air)
   └─ air_low           5,638      → AIR 3.0 low (--emit-air-low: the real one)
```

**Four things mutate a PNode tree**: `pfront_constfold`, `pfront_sccp`,
`theory_opt`, and a handful of rewrites inside the theory layer. Everything else
observes. That is the entire optimiser.

Then, downstream, the only AIR-level optimiser in the project is `pear2_opt`
(2,097 LoC, lives in the backend, runs inside `pear2c`), and after it LLVM's own
pipeline does the real work.

### 2.1 Where the cost actually is

`air_low` emits **memory form**: an immutable `let` becomes an SSA `let`, but any
**mutable** local becomes `alloca` + `load`/`store`, and every reassignment is a
store. That is exactly `clang -O0`'s shape. It is correct, and it is the single
biggest reason the AIR is not "highly complex": there is no SSA construction for
mutable variables in the front end at all — `mem2reg` is left to LLVM.

`theory_ssa` (1,393 LoC) *computes* an SSA plan — dominators, dominance
frontiers, phi placement, renaming — and explicitly "does not mutate the source
AST or pretend to emit an SSA IR". So the hardest part of a real middle end has
been worked out on paper, in code, and then not connected to anything.

---

## 3. The dead 11.5 kLoC, by name

None of these is imported by `pfront_main`, `airtool`, `pear2c`, or by each other
in a way that reaches a binary. None has a test.

| group | modules | LoC |
|---|---|---|
| scalar/expression opts | `cp` `cse` `gvn` `reassoc` `strength` `vrp` `range` `constfold`(dup) | ~1,900 |
| control-flow opts | `adce` `cse` `dfe` `jumpthread` `predicate` `tailcall` `codelayout` | ~1,600 |
| loop opts | `licm` `indvar` `induction` `scev` `vecloop` `loopheur` | ~1,500 |
| memory | `alias` `aliasdeep` `escape` `loadstore` `mallocopt` `nullchk` `defuse` `purity` `sideeffect` | ~2,800 |
| analyses | `pdom` `domfront` `callgraph` `branchprob` `critpath` `hotpath` `regpress` `spillcost` `stats` `arith` `effectinfer` `exhaust` `globals` `lint` `verifyfn` | ~3,700 |

`pfront_cfg` (1,098 LoC) — a real CFG with reverse postorder, Cooper-Harvey-
Kennedy dominators, dominance frontiers and a natural-loop tree — **is** live, so
these passes had a real graph to work on. Nobody wrote the loop that calls them.

And a sample of what they do, from `pfront_gvn.c3`: it assigns value numbers,
finds redundant expressions, increments `g.redundant`… and returns the *existing*
value number without replacing the node. It is an instrument, not an optimiser.
The same is true of `licm`, `strength`, `vrp`, `indvar`, `scev`, `inline`,
`tailcall` — zero mutations between them.

---

## 4. Two front ends' worth of lowering

There are two independent lowerings, both reading the same PNode tree, both
live, both maintained:

| module | LoC | output | who consumes it |
|---|---|---|---|
| `air_lower` | 4,466 | AIR 2.0 (high: closures, effects, match preserved) | `pear1c` (frozen legacy), `--emit-air` |
| `air_low` | 5,638 | AIR 3.0 **low** (alloca/load/store/gep, blocks with params) | `pear2c`, `airtool emit-ll` |

AIR 3.0 being *low* is a design decision worth naming: the "high-level" AIR that
closures, effects and matches would live in is AIR 2.0, which the new backend
does not read. So the new path goes **straight from the AST to machine-shaped
IR**, skipping the level where the interesting optimisations are cheap. That is
the opposite of LLVM's layering (clang → LLVM IR with structure intact → SSA →
machine).

---

## 5. What "the project" is, in parts

| part | state | evidence |
|---|---|---|
| lexer / parser / resolver | solid, exercised | 84 exec programs + 260 stdlib modules parse |
| type checking | works, permissive by design | `pfront_check` / `pfront_infer` |
| theory layer | huge, runs, mostly reports | ~40 passes in `theory_check.run` |
| **middle end (AIR opt)** | **does not exist in `pfront`** | no importer of any AIR pass |
| AIR 3.0 low emitter | large, complete for its subset | 84 programs lower |
| backend `.bc` (pear2) | 19 kLoC, never executed here | needs `libLLVM-23`; no run in this sandbox |
| backend native (`pear2_x64`) | x64 + ELF, never executed here | built, no run recorded |
| stdlib `*.pie` | 260 modules / 18.6 kLoC, never lowered by the new backend | `make test-pear2-stdlib` has never printed a number |
| docs | 10,300 lines across 9 dirs, three overlapping generations | `docs/pride`, `docs/pear2`, `docs/reference` |

Two claims that keep recurring in the docs and are **not** true here:

* "84 programs pass end to end" — that was measured on another machine with LLVM.
  In this sandbox nothing above the type check has been executed.
* "the corpus is green" — the corpus runner refuses to start without
  `libLLVM-23.so` (it exits 2 by design). That is honest, but it means the
  number is a memory, not a measurement.

---

## 6. What is left, in the order that matches your goal

The goal — *rich AIR, optimised repeatedly, backends dumb* — implies four
concrete pieces. None exists today.

1. **An AIR pass manager.** A registry, a `-passes=` pipeline string, verification
   after every pass, `--print-after=<pass>`. This is the missing engine; the
   passes are the easy part once it exists.
2. **AIR passes that rewrite.** mem2reg first (it turns memory form into SSA and
   is the prerequisite for everything else), then instcombine/DCE/CSE/GVN/LICM,
   then the rest. Each needs a before/after test on AIR text.
3. **A structured (high) AIR** that keeps closures, effects and `match` intact,
   with opts running there, then a lowering step to the low profile. Today the
   AST jumps straight to machine shape.
4. **The 44 dead modules converted from analysis to transformation** — or deleted.
   They are the largest single block of unused code in the repo and they are
   currently a false signal of progress.

`docs/ROADMAP_AIR.md` is the ordered plan with a measurable gate per phase.

---

## 7. How to tell whether the project is getting better

Four numbers, all reproducible without LLVM:

| number | today | command |
|---|---|---|
| AIR emitted per function (producers+commands) | ~1 per AST node, 0 eliminated | `airtool stats F.low.air` |
| `alloca`/`load`/`store` in the AIR for a 20-line program | 1 slot per mutable local | `grep -c alloca F.low.air` |
| passes that mutate AIR | **0** | `grep -rn "AIR pass" pfront/` |
| dead pass modules | **44** (11,517 LoC) | the script in §3 |

The first two go *down* as the middle end improves, which is the opposite of how
"more code" feels. That is the point: the goal is fewer instructions in the AIR,
not more code in the repo.
