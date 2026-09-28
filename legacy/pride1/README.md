# legacy/pride1 — the first Pride compiler

This directory archives the **monolithic `pride`** compiler that preceded
pfrontc. It is preserved for archaeology and reference; it is **not** built
by the top-level `Makefile`, and none of its sources are imported by the
current compiler.

## What it was

`pride` was a single-directory C3 codebase that went directly from Pride
source to **LLVM 22 IR text** — no AIR, no λ̄μμ̃ bridge, no theory layer in
its modern form. Pipeline:

```
lexer.c3 → ast.c3 → parser.c3 → cstats.c3 → resolve.c3
   → modal.c3 / msp.c3 / parse_modal.c3
   → typecheck.c3 → effectcheck.c3 → lint.c3 → integrity.c3
   → ssi.c3 → ssi_ir.c3 → sasi.c3 → sasi_opt.c3
   → rewrite.c3 → pgen.c3 → stage.c3 → irdl_msp.c3 → mono.c3
   → codegen.c3   (LLVM 22 .ll emission)
```

Key design decisions carried forward into pfrontc:
* SSI (Static Single Information) rather than pure SSA — σ-nodes on
  branches for fact-sensitive optimisation.
* IRDL dialect registration / validation / lowering (MLIR-style).
* Multi-stage programming via CMTT (Contextual Modal Type Theory).
* PGL (Pattern Generation Language) for decision trees.
* An opaque-pointers LLVM backend (`codegen.c3`).

Key pieces **superseded** by pfrontc:
* The hand-rolled SSI IR is replaced by post-theory PNode → λ̄μμ̃ AIR.
* The typechecker was HM-only; pfrontc has gradual sorts + set-theoretic
  subtyping + bidirectional modal typing + effect rows instead.
* The old lexer/parser/resolver lived as single files at the repo root;
  they are now `pfront/pfront_lex.c3` etc. with a proper module loader
  and source-map diagnostics.

## Why it is here

1. **Reference for the LLVM backend.** `codegen.c3` is the only existing
   Pride→LLVM emitter; when pfrontc grows a native backend it will likely
   borrow its ABI/linking/calling-convention logic.
2. **Regression corpus.** `c89c.pie`, `lexer.pie`, `piecc.pie` are
   non-trivial Pride programs (a C89 compiler, a self-hosting lexer, and a
   micro-C compiler, all written in Pride) that historically crashed the
   front end. They have been moved out of this directory to
   `tests/legacy/c89c/` and serve as parser/regression inputs for pfrontc.
3. **Historical record** of which passes got folded into the theory
   pipeline (TRS, stage, irdl, pgen, mono, …).

## Layout

| File | Role |
|------|------|
| `pride.c3` | Driver (`pride <file.pie>`) |
| `lexer.c3` / `parser.c3` / `ast.c3` | Lex, parse, AST dumper |
| `cstats.c3` | AST statistics |
| `resolve.c3` | Name resolution |
| `modal.c3` / `msp.c3` / `parse_modal.c3` | Modal type theory & MSP |
| `typecheck.c3` / `effectcheck.c3` / `lint.c3` | Type/effect/lint passes |
| `integrity.c3` | AST integrity checker |
| `ssi.c3` / `ssi_ir.c3` / `sasi.c3` / `sasi_opt.c3` | SSI/SASI IR + opts |
| `rewrite.c3` / `pgen.c3` / `stage.c3` / `irdl_msp.c3` / `mono.c3` | Term rewriting, PGL, staging, IRDL, monomorphisation |
| `codegen.c3` | LLVM 22 text emitter |
| `build.sh` | Legacy build script (outputs `./pride`) |
| `Makefile.old` | Snapshot of the old top-level Makefile |
| `lexer.pie` / `piecc.pie` / `c89c.pie` | Pride self-host demos (moved to tests/legacy/c89c/ except c89c.pie) |
| `test_lexer_main.c` | C harness for the lexer benchmark |

## Building it (unsupported)

`make legacy` from the repo root will attempt to invoke the old Makefile,
but the old build expected c3c v0.8.1 at `/tmp/c3/c3c` and an LLVM 22
toolchain on PATH. It is not expected to build out of the box; if you get
it working, please update this file.

## Do not import these modules from pfrontc

None of the `pride1` sources are compiled into `pfrontc`. Keeping them in
`legacy/` (rather than deleting them) means their lessons are greppable,
but new code must not `import` across the legacy boundary.
