# Agent-3 verification report

**Verifier:** Pride-Agent-3 (3rd agent)
**Date:** 2026-09-29
**Base:** `verify/agent3` = `origin/test/harness-path` (390fd7c) + cherry-pick of `origin/build/makefile-llvm-link` (7cf2571), both on top of `e3a31cd` (pear v0.8.1)
**Method:** clean toolchain wipe → `make c3c && make` → full suite runs → independent native-code testing. Nothing below is inferred from reading diffs.

---

## 0. BLOCKER — indexed store is silently dropped; indexed load is miscompiled

**Severity: highest.** The compiler accepts array code with **0 errors** and emits a native binary that computes the wrong answer, hangs, or traps. This is a *silent miscompile*, not a diagnostic gap.

### Minimal repro (5 lines, no stdlib)

```pie
fn main(_) -> i64 ! [Alloc] {
  let a : *u8 = alloc [u8; 16];
  a[0] = 7;
  return a[0];
}
```

| Build | Result |
|---|---|
| `./pfrontc /tmp/sl.pie --emit-exe -O2` | `errors=0` → **binary emitted** |
| run it | **exit 0** (expected 7) |
| `--emit-exe -O0` | **exit 0** as well (not an optimizer bug) |

### Root cause is in the front end, not PEAR

`--emit-air` for the program above:

```
fn main(_) -> i64 {
  μ̃%ret_2. let _x1 = alloc;
  let a = _x1;
  let _ = 7; <()|%ret_2>;      <-- the STORE: RHS bound to `_`, never written to memory
  <a|[0]·%ret_2>               <-- the LOAD: emitted as a *projection on the pointer value*
}
```

Two distinct defects:

1. **Indexed store `a[i] = v` lowers to `let _ = v;`** — the store is discarded. It also emits a spurious `<()|%ret_2>` cut. No diagnostic, no "unsupported" counter.
2. **Indexed load `a[i]` lowers to an index-projection consumer** (`[0]·`) on the pointer *value*, i.e. it is treated like tuple/struct projection rather than a memory dereference.

So `pear` is fed IR that contains no memory operations at all. **A perfect backend cannot fix this** — look at `pfront/pear_ir/air_lower.c3` (index / `N_EXPR_INDEX` handling and the assignment path).

### Blast radius

Everything array-shaped. Evidence:

| Program | Expected | Observed |
|---|---|---|
| `a[0]=7; return a[0]` | 7 | **0** |
| `while i<1000 { a[i]=1; i=i+1; }` | terminates | **hangs** (no timeout) |
| `bench/sieve_kernel.pie` replicated in a driver, `--emit-exe -O2`, 0 errors | exit 162 (π(10⁶)=78498) | **SIGTRAP, exit 133** |
| gcc -O2 reference of the same sieve | exit 162 | exit 162 ✔ |

Consequence: **all four `bench/*_kernel.pie` benchmarks are unverified/unusable** — `fib`, `tak`, `sum_to` pass only because they are pure scalar code with no arrays.

### Why no test caught it

`--emit-exe` is exercised only by `bench/bench.sh` + `bench/run.sh`, which cover `fib`, `sum_to`, `tak` (scalars). `tests/run_exec.sh` is the old harness: it drives the **legacy** `./pride` binary and `runtime/*.o`, and it is **not wired into `make test`** (`test: test-pfront test-conform`). There is no execution-level test for the new PEAR path, so a wrong-answer regression has nowhere to fail.

**Recommended fix order:** (a) make `air_lower` emit real store/load for indexed access, (b) add `tests/run_exec.sh` cases that run the binary and check the *exit code / stdout*, (c) wire it into `make test`.

---

## 1. Verification verdicts on the two pending branches

Both are **correct and should be merged**. Verified by wiping the toolchain and rebuilding from scratch.

### `origin/build/makefile-llvm-link` (7cf2571) — ✅ VERIFIED

Claim: bootstrap layout fix + link libLLVM-19.
- Wiped `~/c3bin` + `~/c3lib` entirely → `make c3c` re-fetched c3c 0.8.4.
- `~/c3lib` is now a **real directory** containing `std` (previously a self-referential symlink `c3lib -> /home/user`, which made `--stdlib` walk `c3lib/c3lib/c3lib/…` and abort). No `std/std` link. ✔
- `make` then compiled **all 114 `.c3` files and linked** with `-L /usr/lib/x86_64-linux-gnu -l LLVM-19` → 3.87 MB `pfrontc`. ✔

### `origin/test/harness-path` (390fd7c) — ✅ VERIFIED

Claim: `run.sh` should point at `tests/pfront/`, not the pre-reorg `pfront_tests/`.
- Confirmed the repo has **no `pfront_tests/` anywhere**, yet run.sh referenced it 52 times; the 85 fixtures in `tests/pfront/` match the suite's `EXPECT` names 85/85.
- After the fix (no symlink hack): **pass=123, fail=5** (was **pass=11, fail=23** as shipped). ✔

### pear v0.8 / v0.8.1 (5767dc4, e3a31cd) — native backend is REAL

The headline claim reproduces exactly:

```
$ ./pfrontc bench/fib.pie --emit-exe -O2      # → statically-linked ELF x86-64
$ ./bench/fib ; echo $?
200
```

`5 × fib(30) = 4,160,200`; `4,160,200 mod 256 = 200` ✔

Exit codes vs. the C baselines (`bench/*.c` semantics), independently recomputed:

| Bench | C value | `& 255` | PEAR observed | |
|---|---|---|---|---|
| `fib` | 4,160,200 | 200 | **200** | ✔ |
| `tak` | 20×tak(18,10,4)=100 | 100 | **100** | ✔ |
| `sum_to` | 2×10⁶×500500 | 0 | **0** | ✔ |

`--emit-bc` emits valid LLVM bitcode (magic `BC C0 DE`, 1668 B for the sieve kernel). **PEAR is not a stub** — it is correct on scalar code and blocked only by the §0 front-end defect.

---

## 2. Other issues found

| # | Severity | Issue |
|---|---|---|
| 2.1 | **High** | `--emit-exe` writes an executable **even when `errors > 0`**. `/tmp/drv.pie` reported `error[E1050]` and still produced `/tmp/drv` (which traps). Errors should stop emission. |
| 2.2 | Medium | `--help` is broken: prints `error: no input file`. README advertises `./pfrontc --help  # full flag list`. Flag list is in `pfront_main.c3:597+`. |
| 2.3 | Medium | `bench/run.sh` uses `/usr/bin/time`, absent in a minimal container → every timing silently degrades to `"No such file or directory"` and the ratio prints `n/a`. `bench/bench.sh` does it right with bash `time`. Use the builtin or `date +%s%N`. |
| 2.4 | Low | Pipe-body `let` with an explicit *pointer* annotation and a non-`mut` binder parses as `error[E1050]: expected an expression`; the brace form of the same statement compiles. Also produced `arity errors : 1`. Worth isolating. |
| 2.5 | Info | `tests/run_exec.sh` is stale (drives legacy `./pride`) and not in `make test` — see §0. |

## 3. Suite state on `verify/agent3`

| Suite | Result |
|---|---|
| `tests/pfront/run.sh` | pass=**123** / fail=**5** |
| `conformance/run.sh` | pass=**218** / fail=**44** |
| stdlib self-clean | **260/260**, 0 errors |

Remaining pfront failures: `63_modsys` (expected 0, got 6), `megaload` (2 errors over 260 modules), `cfg_backedge` (back edge=1, iters=), `opt_cascade` (`fold=0` — constfold not firing here), `modsys` (bound=0, want ≥2).

Conformance: **26 of the 44 failures are missing `type-warn`s**. Spot-checked `36_deref_nonpointer`, `62_bool_order_warns`, `44_if_typed_branch_warns` — all emit **nothing** even with `--strict-types` **and** `--lint`. The diagnostic layer expected by the suite is not implemented for these. `63_modsys`'s 6 errors are unresolved imports of fixtures via `-I` (path/include handling).

---

## 4. Reproduce

```bash
git checkout verify/agent3
rm -rf ~/c3bin ~/c3lib && make c3c && make      # clean bootstrap + link
bash tests/pfront/run.sh                         # 123/5
bash conformance/run.sh                          # 218/44
./pfrontc bench/fib.pie --emit-exe -O2 && ./bench/fib; echo $?   # 200

# §0 repro:
printf 'fn main(_) -> i64 ! [Alloc] {\n  let a : *u8 = alloc [u8; 16];\n  a[0] = 7;\n  return a[0];\n}\n' > /tmp/sl.pie
./pfrontc /tmp/sl.pie --emit-exe -O2 && /tmp/sl; echo $?   # expect 7, get 0
./pfrontc /tmp/sl.pie --emit-air --quiet && cat /tmp/sl.air  # store is missing
```

— Agent-3
