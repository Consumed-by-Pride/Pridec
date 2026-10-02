# Backend contract (PEAR 1 and PEAR 2)

Normative for any program that consumes `.air`. Format: [`docs/specs/AIR.md`](../specs/AIR.md).

## 1 Process interface

```
BACKEND FILE.air [--emit-exe | --emit-bc] [-O0 | -O1 | -O2 | -O3] [--quiet]
```

| | |
|---|---|
| `--emit-exe` (default) | write the executable `FILE` (the path with its last extension removed, next to the input) |
| `--emit-bc` | write LLVM bitcode `FILE.bc` — optional for a backend that does not use LLVM; then exit 2 with a message |
| `-On` | optimisation tier; default `-O2` |
| exit 0 | the artifact was written |
| exit 1 | the `.air` was rejected (syntax, version, limits) — message `file:line:col: …`, **no artifact** |
| exit 2 | usage error, or a requested mode this backend does not provide |
| exit 3 | the file was valid but the backend produced nothing (unsupported form, internal failure) — message names the form and the definition, **no artifact** |

A stale artifact from a previous run must not survive a failure: delete the output first or write atomically.
Warnings go to stdout/stderr and never change the exit status of a successful emit. The wrapper
`scripts/pie-exe.sh` forwards both stages' output; `BACKEND=… scripts/pie-exe.sh FILE.pie --emit-exe -O2` is the
whole chain.

## 2 Obligations

1. **Strict input.** Reject, do not recover from: unknown keywords, other versions, over-limit counts, trailing text.
   (`air_read.c3` is the reference; `airtool check` is the oracle — a file it rejects you must reject, and a file it
   accepts you must parse. `airtool fmt` of a valid file must equal what your printer would write, if you have one.)
2. **No silent miscompiles.** For every form in AIR.md §7 marked *emitted*, *never produced*, or *unsupported*, and for
   every V1–V3 violation (an unbound variable that is not an N1 module-path root), emit a diagnostic naming the form and
   the definition and exit 3. Reaching `main` through such a form must not produce a runnable program.
3. **Claims are candidates.** Re-screen `facts`/`readonly`/`nocapture` (AIR.md §9) or drop them. Never turn a text
   claim into an LLVM attribute or an optimisation without proving it yourself.
4. **Duplicates:** the first definition of a top-level name wins; report the later ones.
5. **Conventions:** implement R1, H1, J1, T1, L1, A1, N1, D1, E1 of AIR.md §8 (or refuse the file with exit 3 and say which).
6. **Determinism:** the same `.air` and `-On` give the same artifact bytes (the legacy backend does; tests rely on it).

## 3 Behavioural reference

* `tests/exec/*.pie` and `tests/exec/pear/*.pie` carry the expectation in the source: `-- EXPECT: <stdout>` and/or
  `-- EXIT: <code>`. `tests/exec/run.sh` compiles each through the chain, runs it, and compares.
* Today (legacy backend, `-O2`): exec suite **43 pass / 0 fail / 49 expected failures**; PEAR smoke **35 / 0 / 1**;
  identical at -O0..-O3. The 49 are mostly one front-end defect (`syscall` operands, AIR.md §11.1) and are listed with
  reasons in `tests/exec/XFAIL.tsv`.
* PEAR 2 need not reproduce PEAR 1's machine code. It must reproduce the **observable result** (exit status and stdout)
  on every case PEAR 1 passes, and may pass more.
* Differential check against PEAR 1: build both, run a case, compare exit status and stdout
  (`scripts/pie-exe.sh` with `BACKEND` unset vs set). Executables produced by the legacy path through `.air` are
  byte-identical to the old direct path (that is how the split was validated), so PEAR 1 is a stable oracle.

## 4 What PEAR 1 does (so you can tell a requirement from an accident)

Requirements — observable in the passing suites:

* a scalar is a 64-bit integer unless an annotation says `i8/i16/i32/u8/u16/u32`/`bool`/pointer; pointers are carried as
  64-bit integers and cast at use;
* `index(i; n)` reads element `i` of size `n` bytes (1/2/4/8), `store(v; n)` writes `n` bytes and delivers `0`;
* `field f #i` addresses the `i`-th 64-bit slot of a record (all fields are 8 bytes);
* `main`'s return value is the exit status; `extern declare malloc/free/write` bind to libc.

Accidents — do **not** copy:

* the clamping of element sizes above 8 to 8, the sign-extension of 2- and 4-byte loads and zero-extension of 1-byte loads
  (a front-end type should decide signedness);
* recognising `%kN`/`%ret`/`·`/`_xN` by spelling inside the code generator, and the "narrow recovery" special case for
  `binder[literal]` returned to `%ret`;
* continuing after a free variable or an `syscall` without operands.

## 5 Front-end follow-ups that unblock backend work

These are tracked in the ledger and are **not** backend problems: `syscall` operands (AIR.md §11.1), dropped statements
(§11.3), unbound variables (§11.2), resolved types instead of `infer` (§12.5), explicit joins (§12.2). Each is measured by
`tests/air/VERIFY_KNOWN.tsv` or the exec XFAIL list, so progress is visible without trusting a report.
