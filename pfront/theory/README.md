# pfront — Pride untyped AST front end

`pfront` is Pride's parser/resolver/semantic checker and **theory layer**, all
operating on an untyped AST. The front end produces a single PNode tree per
compilation unit; the theory layer walks it with a zoo of paper-accurate
analyses — semantic subtyping, CMTT/contextual modal TT, IRDL-SSA dialect
verification, delimited continuations, sized types, abstract interpretation,
SSA construction, size-change termination, session types, defunctionalization,
symbolic execution, NbE, hereditary substitution, CRDT/CALM, effects-and-handlers,
and many more.

## Directory layout

```
pfront/
├── pfront_*.c3           — passes + utilities over PNode
│                           lex/parse/sema/resolve/cfg/infer/...
│                           plus some legacy dead passes kept compiling.
└── theory/               — the theory layer (wired through theory_check.c3)
    ├── theory_check.c3   — TheoryPipeline driver that wires every submodule
    ├── types/            — TYPE SYSTEMS
    │   ├── setops, mu (recursive μ-types), {subtype,subtype_full} (FCB sem. subtyping)
    │   ├── records (ICFP'23 record lattice), rowinfer (row types)
    │   ├── bidi (bidirectional typing), stratified (Kernel F<:)
    │   ├── session (Honda/Gay&Hole session types + duality), sct (Lee/Jones/Ben-Amram)
    ├── meta/             — META-THEORY / BINDING
    │   ├── term (hash-consed λ-calc core), cmtt, cmtt_meta (Nanevski/Pfenning/Pientka)
    │   ├── hered (hereditary substitution, de Bruijn), nbe (normalization-by-eval)
    │   ├── modal (contextual modal logic), msp (multi-stage programming / Taha&Sheard)
    │   ├── stage (staging / partial evaluation), poly (polymorphism)
    │   └── quals (Foster/Terauchi/Aiken type qualifiers: const/pure/throws/send/...)
    ├── effects/          — EFFECTS, HANDLERS, RESOURCES
    │   ├── effects (row-based effect inference), effcont (delimited continuations)
    │   ├── effects_full (deep/shallow handlers; Kammar et al.), cps (CPS counting/contification)
    │   ├── ub (explicit UB lattice: def/poison/ub), linearity (affine/linear use counting)
    ├── rewrite/          — EQUALITY / REWRITING / SATURATION
    │   ├── trs (term rewriting + critical pairs), egraph (egg-style saturation)
    │   ├── eclass (e-class analyses: const/fv/cost), opt (fixpoint optimizer)
    │   └── crdt (CALM theorem analysis; CRDT class lattice)
    ├── lower/            — IR LOWERING / MATCH / DATAFLOW
    │   ├── irdl, irdlssa, irdlverify (MLIR-style dialect verification)
    │   ├── pglcert (PGL decision-tree certifier), matching (Maranget decision trees)
    │   ├── ssa (Cooper/Harvey/Kennedy SSA + dom frontier), defun (Reynolds defunctionalization)
    │   ├── dataflow (monotone bitvector dataflow framework), live (liveness / SP-ERM-e-SSI)
    └── analysis/         — WHOLE-PROGRAM ANALYSES
        ├── absint (interval/sign/nullness abstract interpretation w/ widening)
        ├── bridge (feature scan / convention audit)
        ├── verify (snapshot diff verifier for pass soundness)
        └── symexe (bounded symbolic execution / King-KLEE-style path forking)
```

## Entry points

- `theory_check::TheoryPipeline` — constructed once per file in
  `pfront_main.c3:compile_one()`. Call `.init/run/report/destroy` in order.
- All submodules expose a uniform lifecycle: `init`, (per-run methods),
  `report`, `destroy`. The pipeline wires them in dependency order so passes
  that depend on the output of earlier ones see populated state.

## Design notes

- **Untyped, advisory**: no theory pass rejects a program. They report. Pride
  is a gradually-typed systems language; hard errors come only from the
  sort-level checker in `theory_check.c3` PART A.
- **Fast by default**: the whole layer is O(N) per walk with tight allocation
  budgets; a file the size of `c89c/lex.pie` (~900 LOC) processes in ~50ms.
- **Paper-accurate**: each submodule's header cites the originating paper(s)
  and implements the core algorithms — semantic subtyping's DNF emptiness,
  CMTT's hereditary substitution, IRDL-SSA's union-find over constraint
  variables, Maranget's pattern-matrix compiler, Cooper-Harvey-Kennedy SSA,
  size-change closure, Gay/Hole coinductive session subtyping, etc.

## Building / testing

```
c3c compile pfront/*.c3 pfront/theory/*.c3 \
            pfront/theory/{types,meta,effects,rewrite,lower,analysis}/*.c3 \
            -o pfrontc

bash /tmp/quick_regress.sh     # rebuilds + runs c89c modules (0 errors each) +
                               # asserts every theory subsystem reports
```

---

*Writing code in Pride is a piece of cake... well, a piece of `.pie`.*
