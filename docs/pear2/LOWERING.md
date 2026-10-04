# What is lowered to `.air`, and what is not

Status of every language feature on the path `pfrontc` → `.air`, measured on this branch, not claimed.
Three instruments back every line below; re-run them to check:

| instrument | what it answers | current result |
|---|---|---|
| `python3 scripts/air-audit.py` (`pfrontc --emit-air --air-audit`) | does every AST construct of an entry module produce AIR, or is it deliberately skipped? | 185 programs, ~13,165 constructs, **0 unlowered**; 30 skipped on purpose (compile-time-only rule clauses); 41 programs have front-end errors and emit no `.air` |
| `bash tests/lowering/run.sh` (`make test-lowering`) | one program per feature: does it lower, verify, and run to the expected exit code through `.air` → PEAR 1? | 35 programs: 20 ok, 15 recorded as known-failing in `tests/lowering/KNOWN.tsv` (exact match required both ways) |
| `bash tests/air/run.sh` | does the `.air` parse, re-print byte-identically, and verify? | 238 pass; 13 corpus programs carry V3 (unbound variable) violations recorded in `tests/air/VERIFY_KNOWN.tsv` |

"Lowered" here means: the construct is *present in the `.air`* and checks. It does **not** mean the legacy
backend (PEAR 1, frozen) can run it. Both columns are given.

## Per feature

| feature | in the `.air`? | PEAR 1 runs it? | notes |
|---|---|---|---|
| expressions, `let`, `if`, `match`, calls, casts, arrays, pointers, field read | yes | yes | the bulk of the exec suite |
| `while`, `for`, `loop`, `break`, `continue` | yes, as `label`/`jump` (the AIR `while`/`for`/`break` forms are never emitted) | yes, except `while`+`break` (c06: PEAR 1 crashes) | |
| field / compound / array / pointer store | yes (store convention of AIR §6.1) | yes | field assignment was a variable rebind before this work |
| `defer`, `comptime`, `unsafe` blocks | yes | yes | comptime usually folds to a constant before lowering (m01, m03) |
| destructuring `let (a, b) = t` | yes (fixed here; the names were unbound before) | no (tuple patterns) | c12 |
| clause-style `fn f \| pat -> e` | yes | partly | multi-parameter clause fns match **parameter 0 only** (known defect) |
| clause **guards** | yes (`guard { <c \| %guard> }`, AIR 2.1) | no (guarded branches) | c08 |
| `syscall` | yes, with a result continuation (AIR 2.1) | yes | |
| **effects: `perform`, `handle`, handler arms** | **yes** (AIR 2.2: `perform E.op(p) · k`; arms are `ctor E.op(bind x, bind k)`) | **no**: PEAR 1 has no handler runtime and prints `unsupported AIR form` | e01–e06; ledger P04–P06. Before this work the handler binders were unbound (V3) and the arm body was replaced by a placeholder |
| **MSP: `comptime`, const folding** | folded to constants; nothing remains | yes | stage 0 is decided before lowering |
| **MSP: `quote` / `splice` / `eval` / `reify`** | **as calls to the unbound name `quote`** (V3) | no | m02, s02, x07, x10, 97: this is *not* a faithful lowering. AIR has no staging form; a consumer must treat a free `quote` as **unsupported** |
| interfaces, `impl` | **no** (compile-time only; the call site is already resolved or goes through a dictionary the AIR does not contain) | no | c21 |
| generics | type parameters are carried, nothing is instantiated | no (c22 crashes) | PEAR 2 must monomorphise |
| rewrite rules, IRDL rule clauses | **no, on purpose** (30 clauses skipped, compile-time only; they used to be lowered as garbage) | n/a | |
| `static mut` | **no storage**: the global is a nullary `def`; assignment rebinds a local | WRONG result (c25: 37) | needs an AIR global declaration |
| `offsetof` | lowered as `sizeof usize` (wrong) | | known defect |
| nested items inside blocks (`stdlib/fmt.pie`) | not hoisted: 9 rows, only with `--all` | | |
| name collisions in the flat namespace (`os.linux.write` vs libc `write`) | one of the two is skipped (555 skips with `--all`) | | |

## AIR forms still never produced

command-level `mu`, `letrec`, `while`, `for`, `break/continue`, `ret`, `asm`, `atomic/fence`, `resume(p)` (the
resume convention is the covariable `%resume`, J2), `con`, `inl/inr`, `cometa`, `coerce/sizeof/alignof/offsetof`,
`deref/default/share/erase`, `cocase`, `defco`, `import`. See `docs/pear2/COVERAGE.md` (generated).

## Verifier violations that remain (13 programs, all V3)

| cause | programs |
|---|---|
| `quote` builtin (MSP) | s02_metaprog (21), x10_graph_compiler (7), x07_meta_attrs (3), 97_hered (2), 58_kw_stage_field (1), m02 |
| enum payload clauses, constructor names (`Cons`, `Builder`), a clause binder (`a`, `v`, `a19`) | 32_enum_clauses, 86_sct_termination, showcase (2), s03_effects_data, x13_wide_constructs |
| `sigils` | 31 unbound in `main` |
| middle-end optimizer defect, **not lowering** | 45_opt_branch: at -O2 with the theory layer on, the optimizer deletes a `let` and its loop but keeps the use (`1 declaration(s) vanished with no pass claiming them`); `-O0` and `--no-theory` are fine |

## Not claimed

* Nothing here is a proof that the lowering preserves meaning; the evidence is the exit-code comparison
  against the source semantics for the programs listed, and byte-identical executables across the split (#23).
* "0 unlowered" counts constructs of **entry modules** only; library modules are audited with `--all` (9 rows).
