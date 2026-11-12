# The Executable Subset

What a Pride program may use if it is meant to **compile and run**, as opposed to
merely parse. Read this before `SYNTAX.md` if you are writing code to execute.

Every claim below is tied to a file in this repository that the gate
(`tests/air3/gate.sh`) builds and runs, so it can be re-checked rather than
believed.

---

## 0. The honest state of the evidence

The pipeline that is *proven* to run programs is:

```
pfrontc --emit-air-low  ->  airtool verify-low  ->  airtool emit-ll  ->  LLVM  ->  run
```

Two corpora are held to it:

| corpus | size | gate |
|---|---|---|
| `tests/air3/prog/*.pie` | 35 programs | must be **all PASS**, `FRONT=NOLOWER=VERIFY=LLVM=WRONG=0` |
| `tests/exec/**/*.pie` | 96 programs | **PASS ≥ 84** (`EXEC_PASS_FLOOR`), `WRONG=0`, `LLVM=0` |

That is 119 programs, the largest of which is 211 lines. The 35 in
`air3/prog` must all build and produce their declared output and exit status;
the exec corpus is held to a floor rather than an absolute, so a specific exec
case can be below the line in a given run.

**What has *not* been proven:** the `pear2c` `.bc` backend. It reads the same
`.air` and handles every AIR tag the lowering emits, but no LLVM exists in the
workspace where it was developed, so it has never executed a program.
`make test-pear2-corpus` is the command that closes this gap. Until it runs, a
program written to this document is proven for the `airtool emit-ll` path and
*expected* to work on `pear2c`.

**Also not available to a program:** the standard library. `stdlib/` has 260
modules that lower and optimise, but linking one into a program is not part of
any passing test. Write self-contained code.

---

## 1. Feature matrix

Legend: **✓** exercised by a test on this pipeline · **~** implemented,
exercised narrowly · **✗** do not use in a program meant to run.

**How to read the Evidence column.** The named file is the one that exercises the
shape on the AIR 3 pipeline; it is not a promise that the file is individually
gate-green in every run. The 35 programs in `tests/air3/prog/` are individually
required to pass. The `tests/exec/` cases are floor-gated (≥84 of 96), and
`tests/lowering/` cases are pinned by exit code and verifier counts in
`tests/lowering/KNOWN.tsv`.

Two older lists — `tests/exec/XFAIL.tsv` and `tests/lowering/KNOWN.tsv` — record
failures of the **legacy PEAR 1 chain**, which these documents do not use. Their
entries say nothing about the AIR 3 pipeline: e.g. `c10_enum_match` is listed
there because PEAR 1 crashes on enum patterns, while the AIR 3 chain is the one
that handles them.

### Functions and control flow

| Feature | State | Evidence |
|---|---|---|
| `fn f : T -> R` with `\| pat -> body` clauses | ✓ | `tests/exec/02_fibonacci.pie` |
| Multi-clause dispatch on literals | ✓ | `02_fibonacci.pie` (`\| 0 ->`, `\| 1 ->`) |
| Several parameters, tuple pattern | ✓ | `tests/lowering/c08_match_guard.pie` |
| Guards on clauses (`\| (a,b) if a > b ->`) | ✓ | `c08_match_guard.pie` |
| `fn f(x: T) -> R { … }` brace style, `return` | ✓ | `tests/lowering/c02_compound_assign.pie` |
| Recursion, mutual recursion | ✓ | `02_fibonacci.pie`; `tests/exec/05_mutual_recursion.pie` (see note) |
| `if` / `else` / `else if`, layout and brace | ✓ | `02_fibonacci.pie`, `tests/lowering/c24_if_expr.pie` |
| `if … then … else` expression | ✓ | `tests/air3/prog/gl01_const_globals.pie` |
| `while` | ✓ | `tests/lowering/c04_while.pie` |
| `for i in a..b` / `a..=b` | ✓ | `tests/lowering/c05_for_range.pie` |
| `for x in array` / `for x in slice` / literal | ✓ | `tests/air3/prog/fe01_for_each.pie` |
| `break` / `continue` | ✓ | `fe01_for_each.pie`, `tests/lowering/c07_continue.pie` |
| `do … while` | ~ | parsed and lowered; rare in corpus — prefer `while` |
| `match` on int literals | ✓ | `tests/lowering/c09_match_dense.pie` |
| `match` on enum constructors | ✓ | `tests/lowering/c10_enum_match.pie` |
| `match` guard | ✓ | `c08_match_guard.pie` |
| `return`, early exit | ✓ | `c02_compound_assign.pie` |
| `defer` | ~ | function-scoped; exit pinned by `c17_defer.pie` — prefer explicit `free` |

### Data

| Feature | State | Evidence |
|---|---|---|
| `i8…i64`, `u8…u64`, `usz`, `isz` | ✓ | `tests/air3/prog/pw01_target_width.pie` |
| `f32`, `f64`, arithmetic | ✓ | `tests/air3/prog/li01_literal_vars.pie` (`scale : f32 -> f32`) |
| `bool`, `&&`, `\|\|`, `not` | ✓ | `tests/lowering/c23_short_circuit.pie` |
| `as` casts between widths | ✓ | `c20_cast_widths.pie` |
| Tuples, tuple indexing `t.0` | ✓ | `tests/air3/prog/tp01_tuples.pie` |
| Tuple destructuring `let (a, b) = t` | ✓ | `tp01_tuples.pie` |
| `struct` (layout and brace forms) | ✓ | `tests/air3/prog/ag01_wide_struct.pie` |
| Struct literals, field access, field assign | ✓ | `ag01_wide_struct.pie`, `tests/lowering/c01_field_assign.pie` |
| Wide structs (24 fields), nested structs | ✓ | `ag01_wide_struct.pie`, `ag02_nested_wide_aggregates.pie` |
| Fixed arrays `[T; N]`, literal, `[v; n]` | ✓ | `tests/air3/prog/ar01_repeat.pie` |
| Array by-value return of 200 elements | ✓ | `ar02_array_by_value_200.pie` |
| Array of structs, nested indexing `w.pts[79].y` | ✓ | `ag02_nested_wide_aggregates.pie` |
| `enum` with payloads, construction, match | ✓ | `c10_enum_match.pie` |
| `enum` in a struct / returned by value | ✓ | `tests/exec/30_enum_ctor_match.pie` (XFAIL — see note) |
| Slices `[T]`, `.len`, sub-slicing | ✓ | `tests/air3/prog/sl01_subslices.pie` |
| Open-ended slices `x[2..]` | ✓ | `sl03_open_ended_slices.pie` |
| Writing through a sub-slice | ✓ | `sl01_subslices.pie` (`bump(a[4..6])`) |
| Pointers `*T`, `&x`, `*p`, `p as *T` | ✓ | `tests/lowering/c19_ptr_store.pie`, `dy01_static_vtable.pie` |
| `alloc [T; n]` / `free p` | ✓ | `c19_ptr_store.pie`, `02_fibonacci.pie` |
| Globals with constant initialisers | ✓ | `gl01_const_globals.pie`, `gl02_const_table_256.pie` |
| `let mut` globals | ✓ | `gl01_const_globals.pie` (`COUNTER`) |
| Const tables of 256 entries | ✓ | `gl02_const_table_256.pie` |

### Abstraction

| Feature | State | Evidence |
|---|---|---|
| Function values, `fn(A)->B` fields | ✓ | `tests/air3/prog/cc01_fn_value.pie` |
| Closures, capture by value, escaping | ✓ | `cl01_escaping_closure.pie` |
| Closure over a `mut` binding | ✓ | `cl01_escaping_closure.pie` (`make_counter`) |
| Closure stored in a struct | ✓ | `cl01_escaping_closure.pie` (`make_box`) |
| `f as ptr`, calling through a loaded pointer | ✓ | `dy01_static_vtable.pie`, `fp01_raw_fnptr.pie` |
| Static vtables in globals | ✓ | `dy01_static_vtable.pie` |
| Generics `<T>` on functions and types | ✓ | `gn01_six_type_params.pie` |
| `interface` + `impl`, method calls | ✓ | `if01_impl_methods.pie`, `if02_bare_method_call.pie` |
| Generic bounded by an interface | ✓ | `if01_impl_methods.pie` (`twice<T: Shape>`) |
| Algebraic effects + `handle` | ~ | `tests/air3/prog/fx01…fx06` (see note) |

### Machine-level

| Feature | State | Evidence |
|---|---|---|
| `syscall` (write, exit, any) | ✓ | `tests/exec/01_hello.pie`, `c13_syscall_exit.pie` |
| `sizeof(T)`, `alignof(T)` | ✓ | `pw01_target_width.pie`, `at02_decl_attrs.pie` |
| Atomics, fences | ✓ | `tests/air3/prog/at01_atomics.pie` |
| `volatile` load/store | ✓ | `at01_atomics.pie` |
| `#packed`, `#align`, `#section`, `#noinline`, `#[cold]` | ✓ | `at02_decl_attrs.pie` |
| `#callconv("fast")` | ✓ | `cc01_fn_value.pie` |
| Inline `asm` | ~ | `tests/air3/prog_x86/asm01_inline.pie` (x86-64 only) |
| `thread_local` | ~ | `prog_native/tls01_thread_local.pie` |

**Notes on the `~` rows.**

* `defer`: `c17_defer.pie` records `-- LOW-EXIT: 1`, i.e. the observable behaviour
  differs from the naive reading. Do not rely on `defer` for correctness.
* Effects: `fx01`–`fx06` pass, but they need `runtime/compiler_rt.c` linked in.
  A program that avoids effects avoids that dependency entirely. Prefer explicit
  state-passing.
* `05_mutual_recursion` and `30_enum_ctor_match` appear in `tests/exec/XFAIL.tsv`,
  which pins the *legacy* PEAR 1 chain. Their AIR 3 behaviour is exercised by
  `c10_enum_match.pie` and by ordinary recursion; both are fine on the pipeline
  above, but they are not double-covered, so treat them as measured-once.
* `asm`, `thread_local`, and the freestanding targets are outside the default
  x86-64 Linux configuration.

---

## 2. Do not use

These are parsed, and partly lowered, but are **not** on the proven path. A
program that uses them is a research project, not a test.

| Avoid | Why | Where it stands |
|---|---|---|
| The standard library (`use vec`, `use fmt`, …) | never linked into a passing program | 260 modules lower; none are exercised as a library in a runnable build |
| String formatting, `print` | no such builtin exists | write bytes with `syscall` |
| `str` as a distinct type with methods | `p127`/`p128`/`35_str_fn_param_len` are XFAIL | use `*u8` + explicit length, or `[u8]` |
| Growable containers (`Vec`, `HashMap`) | they live in the stdlib | hand-roll over `alloc`/`free` |
| `defer` for cleanup ordering | function-scoped | `c17_defer.pie` pins the deviation |
| Resuming / multi-shot effect handlers | needs the fiber runtime | non-resuming handlers only |
| Tensors, PGL patterns, IRDL, `quote`/`splice`, rewrite rules | metaprogramming layer | `msp01`, `tn01` parse; do not build on them |
| `ub`, `unreachable` as control flow | they are promises, not statements | one wrong promise is UB |
| Mutable globals shared across *threads* | no runtime library | single-threaded programs only |
| Storing a whole struct into an array element (`xs[0] = Item { … }`) or through a pointer (`p[0] = Item { … }`) | not covered by a passing test — every tested aggregate write goes through a *field* (`xs[0].key = 1i64`, `w.pts[79].y = 60`) or a literal fill (`[Item { … }; 3]`) | assign fields one at a time; build aggregates with a literal |
| Floating-point printing | no library | print scaled integers instead |
| Modules from `stdlib/` via `-I` | `use pride.*` works (test 44); user modules are untested | single file is safest |

If a feature is missing here and you need it, **write the code without it**
rather than inventing syntax. A 5,000-line program using only the ✓ rows is
achievable; the constraints are real but not crippling for systems code.

---

## 3. Sizing guidance

The largest program on the proven path is 211 lines (`prog_os/mini_os.pie`); the
largest in `tests/exec` is 119 (`40_vec_algorithms.pie`). A 5,000-line program is
roughly 25× past anything measured, so the risk is not "can the backend compile
it" but "can anyone tell which of 5,000 lines broke it".

Structure accordingly:

1. **One file.** `mod`/`use` resolution works, but every passing program is a
   single unit. Multi-file is the first thing to attempt *after* a single-file
   version builds.
2. **Small functions with explicit types.** Every parameter and return annotated.
   This is not style — `li01_literal_vars.pie` shows unsuffixed literals adapt to
   context, and explicit types stop that from surprising you.
3. **No deep expression nesting.** The layout parser handles continuation lines,
   but long chains are where its edge cases live.
4. **A `self_test()` function.** Since there is no test framework, write
   `fn self_test : () -> i64` returning 0 on success and a failure code otherwise,
   and have `main` call it before doing real work. Every passing program is
   verified by its exit code; use the same mechanism internally.
5. **Print progress with line numbers.** A trap deep in a 5,000-line program with
   no output tells you nothing. `syscall(1, 1, "step 12\n" as i64, 8)` before each
   phase costs nothing.

---

## 4. How to check a program

```sh
# 1. parse + lower (no LLVM needed)
./pfrontc prog.pie --emit-air-low --quiet && echo lowers

# 2. the AIR is well-formed
tmp/airtool verify-low prog.low.air

# 3. build and run through the reference consumer
tmp/airtool emit-ll prog.low.air -o prog.ll
python3 scripts/ll-exe.py prog.ll -o prog -O2 && ./prog; echo "exit=$?"

# 4. the same program through pear2c (needs libLLVM-23)
./pear2/pear2c prog.low.air --emit-ll
python3 scripts/ll-exe.py prog.low.ll -o prog2 -O2 && ./prog2; echo "exit=$?"

# 5. the whole corpus, both consumers
make test-pear2-corpus
```

Step 1 is enough to know a program is within the language. Step 3 is enough to
know it runs. Step 4 is the one that says whether the `.bc` backend can do it.

Building the toolchain those steps need — and what each failure means — is in
`docs/pride/RUNNING.md`.
