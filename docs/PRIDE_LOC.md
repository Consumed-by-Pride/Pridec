# Pride source, counted by Pride

Every number below was produced by `tokei`, the multi-module Pride workload in
`examples/tokei/` — compiled by this repository's own C backend. The provenance
matters: `main.pie` → AIR 3.0 low (1.8 MB) → `main.c` (852 KB) → `gcc -O1` →
a binary that walks a directory and classifies each line.

    $ bash scripts/pfrontc-build.sh          # c3c 0.8.6
    $ ./pfrontc examples/tokei/main.pie -I examples -I stdlib --emit-c
    $ gcc -std=c11 -O2 -w examples/tokei/main.c -o tokei
    $ ./tokei .

## Totals

| Language | Files | Lines | Code | Comments | Blanks | Bytes | TODO |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Pride** (`.pie`) | 1,182 | 76,304 | 63,795 | 4,975 | 7,534 | 2,518,317 | 5 |

Pride is the largest language in the repository by line count. For scale, the
same run counted:

| Language | Files | Lines |
|---|---:|---:|
| Pride | 1,182 | 76,304 |
| C (generated + vendored) | 29 | 52,743 |
| Markdown | 102 | 22,936 |
| Shell | 50 | 7,473 |
| Python | 36 | 5,592 |

## Where the Pride is

| Directory | Files | Lines | Code | Comments | Blanks | TODO |
|---|---:|---:|---:|---:|---:|---:|
| `stdlib/` | 260 | 33,224 | 26,544 | 2,254 | 4,426 | 3 |
| `tests/` | 573 | 28,368 | 25,469 | 1,457 | 1,442 | 0 |
| `examples/` | 47 | 7,875 | 6,650 | 322 | 903 | 2 |
| `docs/` | 16 | 284 | 246 | 24 | 14 | 0 |
| `pfront/`, `tools/` | 131 `.c3` | 103,471 | — | — | — | — |

The compiler itself is written in **C3**, so tokei does not count it as Pride
(`.c3` is not in its 189-extension table) — that last row is `find | wc -l`,
not tokei. Pride proper is the 1,182 `.pie` files; 28,368 lines of it are
tests and 33,224 are the standard library.

## The count checks out

tokei counts a file's final newline-terminated line; `wc -l` counts newlines.
The difference is bounded by the file count, per directory:

| Directory | tokei | `cat \| wc -l` | Δ |
|---|---:|---:|---:|
| `stdlib/` | 33,224 | 33,192 | 32 |
| `tests/` | 28,368 | 28,366 | 2 |
| `examples/` | 7,875 | 7,874 | 1 |
| `docs/` | 284 | 284 | 0 |

Whole repository: tokei 76,304, `find … -exec cat | wc -l` 76,269, Δ 35 over
1,182 files.

## What this run also proves

Getting a number out of tokei required the C backend to work end to end, and
each stage was checked rather than assumed:

* `pfrontc --emit-c` writes AIR 3.0 low, reads it back through `air_read`, and
  hands it to `air_c` — the same contract the standalone `airc` obeys, so a
  program that compiles here also compiles from the `.air` alone.
* gcc accepts the 852 KB translation unit with **0 errors**.
* The binary executes and produces the table above.

Two defects were found this way and fixed in `air_c`, not worked around:

* `gep[array#128(i64)](base, 0, i)` indexed the *pointer* (`(base+0)[i]`,
  stepping 128 elements per increment) instead of the array
  (`(*(base+0))[i]`). ASan reported it as a stack-buffer-overflow in
  `totals_new`; every loop in the program was writing past its object.
* arrays and tuples: C has no aggregate assignment, tuple types synthesized by
  `air_low` were never defined, and declarators were written in Pride order
  (`T[N] x`) rather than C's (`T x[N]`).

Reproduce with `bash scripts/pfrontc-build.sh` then the four commands at the top.

---

# `pfront/` — the compiler itself

Measured separately because it is **C3, not Pride**: 129 `.c3` files, and `.c3`
is not in tokei's 189-extension table, so tokei reports only the 8 Markdown
files under that directory. These are the counts a classifier over `//` and
`/* */` gives; `wc -l` agrees to within the final-line convention.

| | Files | Lines | Code | Comments | Blanks |
|---|---:|---:|---:|---:|---:|
| `pfront/` total | 129 | 103,277 | 84,262 | 13,149 | 5,866 |

| Directory | Files | Code | Comments | Blanks | Total |
|---|---:|---:|---:|---:|---:|
| `pfront/` (front end) | 61 | 28,802 | 5,226 | 2,369 | 36,397 |
| `pfront/pear_ir/` (AIR) | 21 | 19,508 | 2,720 | 636 | 22,864 |
| `pfront/theory/types/` | 11 | 8,874 | 1,180 | 657 | 10,711 |
| `pfront/theory/lower/` | 9 | 7,253 | 902 | 576 | 8,731 |
| `pfront/theory/meta/` | 10 | 6,215 | 1,145 | 565 | 7,925 |
| `pfront/theory/rewrite/` | 7 | 4,954 | 891 | 433 | 6,278 |
| `pfront/theory/effects/` | 5 | 4,603 | 518 | 314 | 5,435 |
| `pfront/theory/analysis/` | 4 | 3,107 | 377 | 240 | 3,724 |
| `pfront/theory/` (top) | 1 | 946 | 190 | 76 | 1,212 |

16% of it is commentary, which is the number that matters for a compiler that
has to be read before it can be changed.

## Largest single files, by code (not by raw lines)

| File | Code | Comments |
|---|---:|---:|
| `pear_ir/air_low.c3` | 5,475 | 345 |
| `pfront_parse.c3` | 4,201 | 1,491 |
| `pear_ir/air_lower.c3` | 3,528 | 1,154 |
| `pfront_resolve.c3` | 1,918 | 418 |
| `pfront_lex.c3` | 1,890 | 190 |
| `theory/effects/theory_cps.c3` | 1,651 | 147 |
| `pear_ir/air_c.c3` | 1,602 | 291 |

`air_low.c3` is the outlier: 5,475 code lines against 345 of commentary. It is
also where 14 of the compiler's 103 refusal sites live.

## Where "better" has room

The 103 sites that refuse (`not implemented`, `not yet`, `unsupported`,
`refus(e|ing)`) are the ceiling on what the compiler accepts:

| File | Refusal sites |
|---|---:|
| `pear_ir/air_lower.c3` | 22 |
| `pear_ir/air_low.c3` | 14 |
| `pear_ir/air_c.c3` | 10 |
| `theory/meta/theory_nbe.c3` | 9 |
| `pfront_main.c3` | 8 |

Measured against `tests/exec` (48 programs, compile to C, gcc, run): **41 now
compile**, up from 32 before this round. The 5 that `air_c` refuses and the 2
that fail to link are named in the commit; the 2 link failures want runtime
support (`__pride_fiber_yield`, `__pride_local_get`) that the C prelude does
not have.
