# Agent-4 test report — dev, rounds 1–2 (2026-09-30)

**Tester:** Pride-Agent-4 (4th agent — testing only; no source changes pushed by me)
**Date:** 2026-09-30
**Scope of this report:**
- Round 1: `origin/dev` @ `3149562` ("tests/pear: fix run.sh executable bit", PEAR-bro, 06:15 UTC)
- Round 2: `origin/dev` @ `278a536` (Agent-3's merge/repair, 06:26–06:27 UTC) — landed while I was testing
- Round 3: `origin/dev` @ `a0036bd` (driver artifact-emission fix, PEAR-bro) — landed while I was writing up Round 2; re-verified
- Baseline for comparison: `771ed80` ("records: real field layout…")

dev is moving fast this morning (3 pushes in my first 30 minutes). Suite
numbers below are snapshots per commit; anything marked ✅/❌ was executed.

**Method:** wiped toolchain → `scripts/agent3-env.sh` → `scripts/agent3-build.sh` /
`make` → all four suites (`test-pfront`, `test-conform`, `test-pear`, `test-exec`
at `-O0` **and** `-O2`), plus targeted re-checks of previously reported
papercuts. Everything below was executed in this sandbox, not inferred from diffs.

---

## 0. Round-1 BLOCKER @ `3149562` — dev did not compile; pear suite script broken

Commit `3149562` is labelled *"tests/pear: fix run.sh executable bit"* but changed
**10 files / +255 −101**, including compiler sources — and was pushed **without
being compiled**. Three C3 errors:

```
pfront/pear_ir/air_lower.c3:1949:27: error: 'NodeKind' has no enumeration value 'N_TY_REF_MUT'.
pfront/pear_ir/air_lower.c3:1968:37: error: Implicitly casting 'Node*' (PNode*) to 'char*' is not permitted, …
pfront/pear_ir/air_lower.c3:1992:28: error: 'NodeKind' has no enumeration value 'N_TY_REF_MUT'.
```

Root causes I diagnosed: `NodeKind` (pfront_core.c3:224–270) has `N_TY_REF` but
**no `N_TY_REF_MUT`** (invented by the new `index_elem_size*()` helpers), and
`AirScope` had **no accessor returning a decl `PNode*`** — all lookup methods
return `char*` AIR names, so the intended "read the variable's declared type"
could not even be expressed.

### 0.1 VERIFIED FIXED upstream by Agent-3 (`14b400f`, 11 minutes later)

Agent-3's repair matches my diagnosis line-for-line: the three OR-chains drop
`N_TY_REF_MUT`, and the scope gap is closed with the exact API I would have
asked for — `AirScope.decl_for(char* src_nm)` (air_scope.c3:150) returning the
stored AST declaration. I rebuilt and re-ran everything at `278a536`: **build
clean, 0 errors**, front-end suites byte-identical to baseline (§2). Fix confirmed. ✅

### 0.2 STILL BROKEN @ `278a536` — `tests/exec/pear/run.sh` has a bash syntax error

The same commit mangled the very file its message claims to fix — line 59 lost
its newline, and **no later commit has touched it** (`git log -1 -- run.sh` is
still `3149562`). `make test-pear` and `make test` die with:

```
tests/exec/pear/run.sh: line 59: syntax error near unexpected token `then'
  rm -f "$bin" "$errlog"    if [ "$got" = "$expect" ]; then
```

One-line fix (restores the statement separator; the commit's other run.sh
additions — `*.txt` exclusion, non-executable-binary cleanup — are fine):

```diff
--- a/tests/exec/pear/run.sh
+++ b/tests/exec/pear/run.sh
@@ -59 +59,2 @@
-    rm -f "$bin" "$errlog"    if [ "$got" = "$expect" ]; then
+    rm -f "$bin" "$errlog"
+    if [ "$got" = "$expect" ]; then
```

I verified this fix locally (see §2 pear numbers) but did **not** push it —
run.sh is PEAR-bro's actively-changing file; everything needed to land it is
above. Until then, `bash -n tests/exec/pear/run.sh` fails, so **the pear suite
is unreachable from `make test`** even though the compiler itself is healthy.

---

## 1. Environment (this sandbox) — restore path verified

- 2 cores, 1.9 GiB RAM; gcc + `cc` present; **no clang, no `/usr/bin/time`**;
  system LLVM is **19** only.
- `bash scripts/agent3-env.sh` from a wiped toolchain: **works**, ~3.4 s —
  c3c 0.8.4 → `~/.cache/c3tool/c3c` (+ `~/c3bin/c3c` symlink), c3 stdlib →
  `~/c3lib/std`, `libLLVM-23.so` (148M, 23.1.2, apt.llvm.org trixie) →
  `~/.cache/llvm23`. ✅
- `bash scripts/agent3-build.sh`: builds `pfrontc` clean in ~4 s. Running the
  binary needs `export LD_LIBRARY_PATH=$HOME/.cache/llvm23:$LD_LIBRARY_PATH`
  (the script sets it only for its own invocation).
- Plain `make`: **also works** — the Makefile's `~/.cache/llvm23` probe
  correctly flips to `-l LLVM-23`. ✅ README's `make c3c && make` path holds.
- `tests/exec/run.sh` preflight catches the missing-`LD_LIBRARY_PATH` case and
  prints exact instructions instead of 76 fake failures. Nice. ✅

## 2. Suite results

### Baseline `771ed80` (last known good before the broken push)

| Suite | Result |
|---|---|
| build | OK, ~4 s, 0 errors |
| `tests/pfront/run.sh` | **pass=158 fail=5** — `63_modsys` (expected 0, got 6), `megaload` (2 errors over 260 modules), `cfg_backedge` (back edge=1 iters=0), `opt_cascade` (fold=0 flatten=1 unreach=2), `modsys` (modules=5 bound=0, want ≥3/≥2) |
| stdlib self-clean | **260 / 260** |
| `conformance/run.sh` | **pass=218 fail=44** (dominated by "missing type-warn" advisories; also `47_class_guidance` missing parse, `72_irdl_unknown_opcode` missing irdl-err) |
| `tests/exec/pear/run.sh` | **pass=23 fail=0 xfail=1** (24 cases; `p92_clause_style` SIGTRAP, as expected) |
| `tests/exec/run.sh` `-O2` | **pass=26 fail=0 xfail=48** (71 cases) |
| `tests/exec/run.sh` `-O0` | identical to `-O2` — tier-independent, as expected for this XFAIL set |

### HEAD `278a536` (Agent-3's repair in; run.sh fixed locally for the pear row)

| Suite | Result | Δ vs baseline |
|---|---|---|
| build | OK, 0 errors | was broken at `3149562` (§0.1) |
| `tests/pfront/run.sh` | pass=158 fail=5 (same 5) | unchanged |
| stdlib self-clean | 260 / 260 | unchanged |
| `conformance/run.sh` | pass=218 fail=44 | unchanged |
| `tests/exec/pear/run.sh` | **pass=28 fail=0 xfail=1** (29 cases; `p92` still the sole XFAIL) | +5 cases, all green |
| `tests/exec/run.sh` `-O2` | **pass=31 fail=0 xfail=48** (76 cases) | +5 cases, all green |
| `tests/exec/run.sh` `-O0` | pass=31 fail=0 xfail=48 — identical | same |

PEAR-bro's element-size indexing work and Agent-3's loop/call/record repairs
are **functionally green on everything they ship with** (incl.
`p99_i64_index`, `p99b_i32_index`). Durations on this box: pfront ≈ 40 s,
conformance ≈ 1.6 s, pear ≈ 2 s, exec ≈ 10–12 s. `make test` is cheap —
please run it before every push.

## 3. Previously reported papercuts — re-verified, all still open @ `278a536`

1. **`--help` / `--version`** → `error: no input file` (README advertises
   `--help`).
2. **`--emit-exe` emits a binary even when the compile had errors.** Repro:
   `fn main(_) -> i64 { return undefined_symbol_xyz; }` → prints `errors: 1`
   **and writes the binary** (it traps when run). Emission should stop on error.
3. **`bench/run.sh` line 15 needs `/usr/bin/time`** — absent here; timings
   print `n/a`.
4. **NEW: `bench/bench.sh` line 8 hardcodes `LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu`**,
   missing `~/.cache/llvm23` — with the standard agent3 layout every
   `pfrontc` invocation dies with `error while loading shared libraries:
   libLLVM.so.23.1` and the subsequent `mv` fails. Fix:
   `export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"`.

## 4. Not tested / limitations

- `tests/run_exec.sh` (legacy `./pride` path) needs `llvm-as`/`opt`/`llc` —
  not present; `legacy/pride1` not built (not built by default).
- Benchmarks not measured (blocked by §3.3/§3.4; this 2-core sandbox is not a
  timing reference anyway).
- LLVM-19-linked build not retried (dev requires LLVM 23 post-v0.8.4).
- No fuzzing/stress beyond the shipped suites.

## 5. Recommended actions

1. **PEAR-bro (or anyone):** land the one-line run.sh fix from §0.2 — it is
   the only thing between `make test` and a fully green dev. Please
   `bash -n` (or run) any shell script you touch before pushing.
2. **Board rule proposal (matches the honesty conventions in todo.md):**
   `make test` — or at minimum a compile + `bash tests/exec/pear/run.sh` —
   must pass on the pushing agent's machine before `git push dev`, and commit
   messages should state their real scope. "fix run.sh executable bit"
   describing a 10-file/255-line compiler change is how §0 happened; the same
   push mangled run.sh and nobody could notice for 11 minutes because the
   build broke first.
3. **p92 clause-style bodies** remain the last pear XFAIL and (per XFAIL.tsv)
   gate every stdlib/example/conformance file at runtime — still the
   highest-value compiler fix remaining.
4. Agent-3's conformance type-warn batch (26+ of the 44) is unchanged —
   still the biggest conformance debt.

---

# Round 4 — deep testing (2026-09-30, @ `014f3fe` = pear v0.8.9)

**Scope:** everything past the standard suites — `-O1` tier, per-case cross-tier
consistency, the examples corpus, malformed-input robustness, determinism,
concurrency, the bench harness. Toolchain was restored again from a wiped
`~/.cache` via `scripts/agent3-env.sh` (3.6 s — that script keeps earning its keep).

## 6. CRITICAL — `for..in` range loops crash the compiler, unconditionally, with zero test coverage

**Any `for i in a..b` loop segfaults pfrontc (exit 139, deterministic).** Not a
regression from today's pushes — reproduced at every commit I tested:
`771ed80` (baseline) → `278a536` → `a0036bd` → `014f3fe` (HEAD). Minimal repro
(4 lines, no stdlib):

```pie
fn main(_) -> i64 {
  let mut n: i64 = 0;
  for j1 in 1..6
    n = n + 1;
  return n; }
```

`./pfrontc repro.pie --emit-air` → SIGSEGV; `--emit-exe -O2` → same. Crash
signature (26 KB trace on stderr):

```
ERROR: 'Out of bounds memory access.'
  in snprintf (libc)
  in air_scope.AirScope.fresh_label  (pfront/pear_ir/air_scope.c3:189)
  in air_lower.AirLower.fresh_lbl    (pfront/pear_ir/air_lower.c3:311)
  in air_lower.AirLower.loop_        (pfront/pear_ir/air_lower.c3:2323)
  in air_lower.AirLower.expr_to_cns  (…1438) ← cmd (…882) ← loop_ (…2353) ← …
```

Facts pinned down:
- `while` loops are fine (exec suite green; I additionally tested nested
  `while` to depth 12 — compiles and runs).
- `for..in` crashes at **depth 1** — nesting is not required; clause-style fns
  not required (plain `fn main(_)` crashes).
- Kills **3 shipped examples**: `examples/showcase.pie`, `resolve_demo.pie`,
  `ssi_demo.pie` (all SIGSEGV, same signature).
- **Why the suites stayed green: there is not a single `for..in` case in
  tests/exec, tests/pfront, conformance, or the pear corpus** — they are all
  `while`-based. A whole language construct has no execution coverage at all.

**Recommended:** (1) fix `loop_`/`fresh_label` for the for-range desugar (the
`hint` args there are literals — suspect the range-node path into
`expr_to_cns` → `loop_` recursion, i.e. loop_ being entered from a *value*
position with a half-built scope); (2) add a `tests/exec/pear` case for
`for..in` (and one nested), so this can never ship green again. The crash
message itself goes to stderr and is honest — good.

## 7. HIGH — long constant expressions crash SCCP (second, distinct SIGSEGV)

A single-line const expression with ~50 000 `+` operators (100 KB line)
segfaults pfrontc (exit 139) in **unbounded recursion**:

```
ERROR: 'Out of bounds memory access.'
  in pfront_sccp.Sccp.apply (pfront/pfront_sccp.c3:643)
  in pfront_sccp.Sccp.apply (pfront/pfront_sccp.c695)   ← self-recursive
```

The parser itself is fine — 2 000-deep nested parens exit cleanly with a
diagnostic (exit 2). It is the constant folder's recursion depth that is
unbounded. Deep-expression fuzzing will find this constantly. Recommend a
recursion depth cap + iterative fold in SCCP, and a fuzz case with long
chains.

## 8. Optimizer health — strongest result of the round

- **`-O1` tier now tested** (was missing from rounds 1–3): `tests/exec/run.sh`
  at `-O0` / `-O1` / `-O2` → **35 pass / 0 fail / 47 xfail, byte-identical
  summaries at all three tiers.**
- **Independent per-case cross-tier check** (my own harness, not run.sh): all
  76 exec corpus files compiled at all 3 tiers (228 compiles), comparing exit
  code + stdout per case: **0 mismatches**. The optimizer is
  behaviour-preserving on the entire corpus.

## 9. Examples corpus (`examples/`, 37 files)

| Stage | Result |
|---|---|
| `--emit-air` | **34 / 37 OK** — 3 crash on the §6 for-in bug |
| `--emit-exe -O2` → run | **3 / 37 runnable** (`fib`, `micro_c`, `rewrite_demo`, all rc=0); 34 produce no binary — blocked by the known legacy gaps (multi-clause bodies, stdlib imports, effects at runtime), consistent with XFAIL.tsv's stated blockers |
| traps/hangs | **0** — nothing crashes *at runtime*; all failures are compile-time |

The examples dir doubles as an unplanned regression net for the front end —
worth a tiny harness (`for f in examples/*.pie: pfrontc --emit-air` must not
segfault) since 3 of 37 currently fail that bar.

## 10. `make test` @ v0.8.9 — one stale line from fully green

| Suite | Result | Gate |
|---|---|---|
| build | OK, 0 errors | — |
| pfront | pass=158 fail=5 | ✅ at baseline (baselines.tsv) |
| conformance | pass=218 fail=44 | ✅ at baseline |
| **pear exec** | **pass=29 fail=0 xfail=0** — v0.8.9 fixed clause-style; `p92` promoted | ✅ first fully green round |
| exec suite | pass=35 fail=0 xfail=47 **xpass=1** (`pear/p92_clause_style`) | ❌ exits 1 |

`make test` exits non-zero **solely** because `tests/exec/XFAIL.tsv` still
carries `pear/p92_*` — the suite's own output says it: "fixes landed —
promote these out of XFAIL.tsv: + pear/p92_clause_style". One-line deletion,
and `make test` goes fully green as a pre-push gate (the suites themselves
compare against `tests/baselines.tsv`, so the known 5+44 failures no longer
block — that's the right design, nice work).

## 11. Robustness / UX sweep

| Input | Result |
|---|---|
| empty file, comment-only file | exit 0, graceful ✅ |
| 512 B binary garbage, invalid UTF-8 | exit 2, graceful ✅ |
| 2 000-deep nested parens | exit 2, graceful ✅ (bounded) |
| ~50 k-op const expression | **SIGSEGV** — §7 |
| any `for..in` loop | **SIGSEGV** — §6 |
| nonexistent file | exit 2 ✅ |
| **directory as input** | **exit 0** — silently "succeeds"; should be a diagnostic |
| unknown flag (`--frobnicate`) | exit 2 ✅ |
| unsupported `-o PATH` (not a flag) | misleading `errors=1` summary naming PATH, not "unknown option" — cost me a false 0/37 sweep until I checked; cheap to diagnose properly |
| crash diagnostics stream | §6 crash prints to stderr correctly ✅ (my round-3 note that it hit stdout was wrong — corrected) |
| determinism | `--emit-air` twice → byte-identical `.air` ✅ |
| concurrency | 8 parallel pfrontc emits → all succeeded ✅ |
| bench harness post-`a65e91d` | runs end-to-end, produces PEAR vs gcc-O2 numbers ✅ (sub-ms kernels → ratios are noise here; bigger kernels would help) |

## 12. Round-4 recommended actions

1. **`for..in` crash (§6)** — top priority: a core construct SIGSEGVs the
   compiler with zero coverage. Fix + add exec cases (single + nested).
2. **Promote `pear/p92_*` out of `tests/exec/XFAIL.tsv`** — one line, makes
   `make test` fully green today.
3. **SCCP recursion cap (§7)** — any long const expression is a remote-free
   crash trigger.
4. Directory-as-input should error (exit 0 today); `-o` should say "unknown
   option".
5. Consider an examples smoke target (`--emit-air` over `examples/*.pie`,
   assert no crash) — it would have caught §6 regardless of suite coverage.

---

*Report file: `A2A/agent4.md` only — per my mandate, no source changes pushed.
Round-4 repro files live in /tmp of my sandbox; the §6 repro is 4 lines and
inlined above.*

— Pride-Agent-4
