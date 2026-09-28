# Pridec — the Pride compiler

> *"The over-engineered systems language. Computation is a cut."*

Pride is a gradually-sorted systems language built on the **classical sequent calculus λ̄μμ̃** (Curien–Herbelin 2000): every term is a producer, every evaluation context a consumer, and computation is a *cut* between them. Multi-stage programming, algebraic effects & handlers, semantic subtyping, IRDL dialects (a là MLIR), and PGL decision-tree pattern matching are all built in rather than bolted on.

This repository is **pfrontc** — the current Pride front-end and AIR
emitter. It takes `.pie` source and produces **AIR 1.0**
(Abstractive Intermediate Representation), a stable human-readable
λ̄μμ̃ text format intended for downstream backends (LLVM, C, WASM, a native
codegen, etc.).

---

## Quick start

### Prerequisites

* **c3c 0.8.2** — the C3 compiler (Pridec is implemented in C3).
  `make c3c` will fetch a static build to `~/c3bin/c3c` for you.
* LLVM 22 is *not* required to build `pfrontc` itself. (The legacy backend
  under `legacy/pride1/` targets LLVM 22 directly; it is retained for
  archaeology but not built by default.)

### Build the compiler

```bash
make c3c        # one-time: fetch c3c if missing
make            # builds ./pfrontc
```

### Run

```bash
./pfrontc path/to/file.pie --emit-air     # writes file.air next to the source
./pfrontc path/to/file.pie --dump-ast     # print the resolved, post-theory AST
./pfrontc path/to/file.pie --strict-types # turn sort/type advice into errors
./pfrontc --help                          # full flag list
```

### Run the test suites

```bash
make test                  # all suites
make test-pfront           # pfront regression suite under tests/pfront/
make test-conform          # semantic conformance under conformance/
bash scripts/c89c_pfront_regress.sh   # rebuild + known-good workloads
```

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
air_emit   →  AIR 1.0 text  (.air file)
```

## Status

* Front-end (lex → parse → resolve → sema → theory): stable on the
  c89c/pfront/conformance suites.
* AIR emitter: stubless — no `*k*`, no `*dummy*`, no `<()|·>` admin nops,
  no source-span leakage, no duplicated code after returns.
* Backend: in progress. Currently the end of the pipeline is AIR text; a
  native/LLVM/C backend is next.

## Contributing

Pridec is written in C3; see `pfront/pear_ir/README.md` for the C3-specific
gotchas (reserved words, mandatory braces, no multi-pointer decls,
no forward declarations, `.` for methods).

For bug reports, push a reduced `.pie` case under `tests/pfront/bug/` with
a short comment at the top describing the expected vs actual behavior.

## License

See [LICENSE](LICENSE).
