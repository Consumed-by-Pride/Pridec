# Pridec — the Pride compiler

> *"The over-engineered systems language. Computation is a cut."*

Pride is a gradually-sorted systems language built on the **classical sequent calculus λ̄μμ̃** (Curien–Herbelin 2000): every term is a producer, every evaluation context a consumer, and computation is a *cut* between them. Multi-stage programming, algebraic effects & handlers, semantic subtyping, IRDL dialects (a là MLIR), and PGL decision-tree pattern matching are all built in rather than bolted on.

This repository ships **pfrontc** — the Pride front end, **AIR 1.0**
(Abstractive Intermediate Representation) emitter, and **PEAR LLVM backend**.
The current pipeline can emit AIR text, LLVM bitcode, or a native x86-64 Linux
ELF executable from `.pie` source. Backend coverage is partial; emitting a
binary is not proof that every language feature works at runtime.

---

## Quick start

### Prerequisites

* **c3c 0.8.4** — the C3 compiler (Pridec is implemented in C3).
  `make c3c` will fetch a static build to `~/c3bin/c3c` for you.
* **libLLVM 23** — PEAR uses the LLVM-C API and LLVM-23 attribute IDs. LLVM 19
  is not a supported substitute for optimized native-code testing.
* Linux x86-64, `ld`, a C compiler, Python 3, and `nm` for the runtime inventory.
  The preserved `legacy/pride1/` LLVM-22 path is not the default compiler.

### Build the compiler

```bash
bash scripts/agent3-env.sh    # restore c3c 0.8.4 + C3 stdlib + libLLVM 23
make                         # builds ./pfrontc
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
```

### Run

```bash
./pfrontc path/to/file.pie --emit-air     # writes file.air next to the source
./pfrontc path/to/file.pie --emit-exe -O2 # writes a native executable next to the source
./pfrontc path/to/file.pie --dump-ast     # print the resolved, post-theory AST
./pfrontc path/to/file.pie --strict-types # turn sort/type advice into errors
./pfrontc --help                          # full flag list
```

### Run the test suites

```bash
make test                  # current no-regression gate (known failures stay visible)
make test-pfront           # pfront regression suite under tests/pfront/
make test-conform          # semantic conformance under conformance/
bash scripts/c89c_pfront_regress.sh   # rebuild + known-good workloads
```

A green gate means **no regression against recorded contracts**, not full
language conformance. See `tests/baselines.tsv` and the per-case
`conformance/KNOWN_FAILURES.tsv`. The old conformance harness could report
passes without a compiler; its correction and the measured replacement
baseline are documented in `docs/dev/CONFORMANCE_GATE_REPAIR.md`.

Directory module roots are passed with `-I dir`; positional directory inputs
are rejected. Modules resolve by file name (`use mm` looks for `mm.pie` or
`mm/mm.pie`), not by a `mod` declaration in an arbitrarily named file.
`--dead-code` is opt-in: main/pub/extern functions are roots; units with no
roots are treated as libraries and do not get dead-function warnings.

---

## Repository layout

```
Pridec/
├── Makefile                     # build pfrontc (and optionally legacy/pride1)
├── README.md                    # this file
├── LICENSE
├── pfront/                      # ★ the current compiler ★
│   ├── pfront_main.c3           # driver (invoked by --emit-air)
│   ├── pfront_lex.c3            # lexer
│   ├── pfront_parse.c3          # recursive-descent parser → PNode tree
│   ├── pfront_resolve.c3        # module loader + name resolution
│   ├── pfront_sema.c3           # visibility, SCC, pattern analysis
│   ├── pfront_infer.c3          # HM type inference (off by default)
│   ├── pfront_check.c3          # trait/coercion/access checks
│   ├── pfront_flow.c3           # call graph, effects, reachability
│   ├── pfront_dump.c3           # AST / s-expr emitter
│   ├── pfront_ext.c3            # lints, exhaustiveness, effects
│   ├── pfront_source.c3         # source map for snippet diagnostics
│   ├── pfront_types.c3          # type table
│   ├── pfront_narrow.c3         # coercions
│   ├── pfront_*.c3              # middle-end analyses & opts (cfg, dom, sccp,
│   │                            #   licm, gvn, inline, adce, …)
│   ├── pear_ir/                 # AIR bridge: PNode → λ̄μμ̃ IR → AIR text
│   │   ├── air.c3               # public driver (air::emit_air)
│   │   ├── air_ir.c3            # IR types + 1 MiB slab arena + smart ctors
│   │   ├── air_scope.c3         # name/ret/loop stacks, α-renaming
│   │   ├── air_types.c3         # PNode type annotation → AirTyp
│   │   ├── air_lower.c3         # PNode → AirModule (λ̄μμ̃)
│   │   ├── air_emit.c3          # AirModule → AIR 1.0 text
│   │   └── README.md            # calculus, invariants, C3 gotchas
│   └── theory/                  # theory pipeline (~40 passes)
│       ├── theory_check.c3      # orchestrator (registration → opt → verify)
│       ├── types/               # μ-types, set-theoretic subtyping
│       ├── meta/                # CMTT contextual meta-theory
│       ├── effects/             # scoped handlers, effect rows, mono
│       ├── rewrite/             # TRS, PGL decision trees, e-graph saturation
│       ├── lower/               # IRDL dialect lowering, matching bounds
│       └── analysis/            # absint, liveness, verifier
├── stdlib/                      # Pride standard library (.pie sources)
├── runtime/                     # C runtime shims (compiler_rt.c, arch stubs)
├── tests/
│   ├── pfront/                  # pfront regression suite (.pie cases)
│   ├── legacy/c89c/             # C89-in-Pride cases (kept for parser regressions)
│   └── run_exec.sh              # harness for execution tests
├── conformance/                 # semantic conformance suite
├── examples/                    # example .pie programs
├── bench/                       # benchmarks (.pie kernels + C harnesses)
├── docs/
│   ├── specs/AIR.md             # AIR 1.0 specification
│   └── dev/                     # developer notes (HANDOFF, TODOs)
├── scripts/                     # build/regression/CI helpers
├── experiments/                 # research scratchpads (not built by default)
└── legacy/
    └── pride1/                  # previous monolithic compiler (pride → LLVM),
                                 # preserved for reference; not built by default
```

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for a pipeline walkthrough and
**[pfront/pear_ir/README.md](pfront/pear_ir/README.md)** for the AIR
bridge internals.

---

## Compilation pipeline

```
.pie source
   │
   ▼
pfront_lex ── tokens ──► pfront_parse ── PNode AST
   │
   ▼
pfront_resolve  (module loader + name resolution)
   │
   ▼
pfront_sema / pfront_infer / pfront_narrow / pfront_check / pfront_flow
   (SCC, visibility, exhaustiveness, HM inference, coercions, call graph)
   │
   ▼
theory pipeline  (~40 passes — see pfront/theory/theory_check.c3)
   0. scan + audit
   1. register dialects + effects
   2. stage check → μ-types/CMTT/effect rows/bidi/rowinfer/polymorphism
   3. PGL decision trees → TRS fixpoint → comptime/PE → e-graph saturation
   4. IRDL dialect lowering → conttree → UB → gradual sorts
   5. PGL certs → semantic subtyping + match refinement → absint
   6. liveness (SP-ERM-e-SSI) → optimizer (const-fold, DCE, branch-fold)
   7. handler linearity → tree verifier
   │
   ▼  post-theory PNode tree
air_lower  →  AirModule (λ̄μμ̃ IR in slab arena)
   │
   ▼
├─ air_emit  →  AIR 1.0 text  (.air file)
└─ PEAR      →  LLVM 23 bitcode / native ELF (--emit-bc / --emit-exe)
```

## Status

* Front-end and AIR emission: checked by pfront and current conformance
  contracts; their known unmet cases remain recorded, not hidden.
* PEAR native backend: exercised by `tests/exec/pear/` and `tests/exec/`;
  scalar fixtures pass, while broader language/runtime coverage remains
  incomplete. Known-broken execution cases are tracked in `tests/exec/XFAIL.tsv`.
* Examples: 21/37 are front-end error-free; the 16 preserved broken showcases
  are labeled in `examples/README.md` and `examples/STATUS.tsv`. AIR artifacts
  are diagnostic output, not proof of successful compilation or native behavior.
* Theory analyses and optimizations have differing consumer coverage; do not
  infer runtime support from an advisory counter or a historical checklist.

## Contributing

Pridec is written in C3; see `pfront/pear_ir/README.md` for the C3-specific
gotchas (reserved words, mandatory braces, no multi-pointer decls,
no forward declarations, `.` for methods).

For bug reports, push a reduced `.pie` case under `tests/pfront/bug/` with
a short comment at the top describing the expected vs actual behavior.

## License

See [LICENSE](LICENSE).
