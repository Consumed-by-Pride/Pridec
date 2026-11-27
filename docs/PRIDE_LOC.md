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
