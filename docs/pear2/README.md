# PEAR 2 — start here

PEAR 2 is the new backend: **AIR 2.0 text in, native code out**. It starts at a `.air` file and nowhere else.
The front end (`pfrontc`) ends at `.air` and links no LLVM; PEAR 1 (the old backend) lives frozen in
`legacy/pear1/` and is only the *reference* and the regression gate for the front end.

| you need | where |
|---|---|
| the file format (grammar, scope, meaning of every form, conventions) | [`docs/specs/AIR.md`](../specs/AIR.md) |
| the backend's obligations and CLI | [`CONTRACT.md`](CONTRACT.md) |
| which forms real programs use, how often | [`COVERAGE.md`](COVERAGE.md) (generated; `python3 scripts/air-coverage.py`) |
| the expected behaviour of ~80 programs | `tests/exec/*.pie`, `tests/exec/pear/*.pie` (`-- EXPECT:` / `-- EXIT:` markers), `tests/exec/XFAIL.tsv` |
| a parser/printer you can reuse or test against | `pfront/pear_ir/air_read.c3`, `air_write.c3`; `airtool check|fmt|verify` |
| the old backend as a worked example | `legacy/pear1/pear.c3` (2200 lines, name-pattern based — a reference, not a model) |

## Five-minute start

```sh
make                       # pfrontc  (no LLVM needed)
make airtool               # tmp/airtool
make legacy-pear           # legacy/pear1/pear1c  (needs LLVM 23: ~/.cache/llvm23)

./pfrontc tests/exec/pear/p03_fib.pie --emit-air     # writes tests/exec/pear/p03_fib.air  (whole program, ~270 KB)
tmp/airtool verify tests/exec/pear/p03_fib.air       # validity rules, conventions counted
legacy/pear1/pear1c tests/exec/pear/p03_fib.air --emit-exe -O2 && tests/exec/pear/p03_fib; echo $?    # 55
```

## Plugging PEAR 2 into the suites

Any program with the CLI of [`CONTRACT.md`](CONTRACT.md) §1 runs the whole existing gate:

```sh
BACKEND=/path/to/pear2c XFAIL_FILE=tests/exec/XFAIL.pear2.tsv bash tests/exec/run.sh        # exec suite
BACKEND=/path/to/pear2c bash tests/exec/pear/run.sh                                          # PEAR smoke suite
PEAR_OPT=-O0 BACKEND=... bash tests/exec/run.sh                                              # tiers: -O0..-O3
```

`XFAIL_FILE` is *your* list of known failures (copy `tests/exec/XFAIL.tsv` and edit). A case that starts passing
is reported XPASS and fails the run, so the list can only shrink honestly.

## Suggested order (from COVERAGE.md; each step is testable on real output)

1. Scalar functions: `def`, `mu~ %ret`, cuts, `(op a b)`, `if`, direct `call`, `let`, `comu`, `seq` → `p01`–`p04`, `p05`.
2. Control flow: `label`/`jump`, the `%kN` joins (J1), mutable rebinding (A1) → loops and `p`-suite.
3. Memory: `index`, `store`, `field`, `as`, strings, externs (`malloc/free/write`) → `04_dynamic_alloc`, `12_struct_ops`.
4. Data: `match`/`case` with tuple/ctor patterns, `data`/`codata` declarations.
5. `syscall` — **blocked on the front end**: the lowering currently drops its operands (AIR.md §11.1); fix that first.
6. Effects and staging: front end emits them, nobody executes them yet (ledger P04–P06).

Rule of the road: **a form you do not implement must produce a diagnostic and a non-zero exit, never a binary that
quietly does something else.** The old backend's silent fall-backs (a call to address 0, an ignored `syscall`) are
exactly the bugs this rule prevents.
