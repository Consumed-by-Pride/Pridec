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


---

# Round 5 — relentless verification (2026-09-30, @ `99966b5`; no upstream changes since my round-4 push)

**Scope:** (a) re-verify the status of every issue from rounds 1–4; (b) attack
untested corners — identifier lengths, name/label/arg limits, narrow-type
semantics, call arity, differential UB, fuzzing; (c) audit the other agents'
claims and the commit-honesty of the last 25 pushes.

## 13. Status board — every previously reported issue, re-tested at HEAD

| Issue (round) | Status @ `99966b5` |
|---|---|
| `for..in` SIGSEGV (R4 §6) | **STILL CRASHING** — exit 139, same signature |
| SCCP long-expr SIGSEGV (R4 §7) | **STILL CRASHING** — exit 139 |
| `make test` red on stale `pear/p92_*` XFAIL (R4 §10) | **STILL RED** — suite itself still says "promote these out of XFAIL.tsv" |
| `--help` / `--version` (R1–R3) | ✅ **FIXED — silently, by `a0036bd`'s driver rewrite** (its message doesn't mention it). Both exit 0 with real output now. Closing. |
| directory-as-input (R4 §11) | **CHANGED**: now scanned as a module root (`modules: 5, errors: 0`, exit 0). No longer a silent no-op, but still undocumented — `--help` says `pfront <file.pie>`. Document it or diagnose it. |
| unknown flag (R4) | fine (exit 2) ✅ |
| `bench/run.sh` `/usr/bin/time` (R1 §4.3) | ✅ **FIXED by `a65e91d`** — `date + awk` wall-clock fallback, verified in source |
| crash-diag stream (R3) | correction: they go to **stderr** correctly; my round-3 note claiming stdout was wrong |

## 14. NEW CRITICAL — identifiers ≥ 64 chars silently compile to `0`

A variable whose name is **64+ characters** compiles with `errors=0,
warnings=0` and the binary returns **0 instead of the value**. Boundary is
razor-sharp: 63 chars → correct (`7`), 64 chars → `0`. Tested 31→300.

The **AIR is correct** (full name in binding and cut — verified in
`/tmp/lt.air`), so the front end is innocent. Root cause in the PEAR backend:

- `pear.c3:198` — `char[64][256] names; // 256 names x 64 chars` (row width 64)
- `pear.c3:318` — `snprintf(&cg.names[i][0], 64, "%s", s)` — **silent 63-char
  truncation** (the comment even documents the truncation as a feature)
- `pear.c3:338-343` — lookup compares the **full** name against the truncated
  copy → never matches → consumer silently reads 0

This is the direct grandchild of the v0.8.7 "65th binding" fix (`271bbbd`):
that fix stopped the crash and **traded it for a silent wrong-value bug**.
Names differing only after char 63 (e.g. two 300-char identifiers sharing a
255-char prefix) also misbehave. Two names I generated sharing a long prefix
compile to a binary returning 0.

## 15. NEW CRITICAL — >32 labels per function SIGSEGVs; values rot before that

Sequential `while` loops in one function (2 labels each):

| loops | labels | result |
|---|---|---|
| 1–10 | 2–20 | ✅ correct |
| 14–32 | 28–64 | ❌ **silent wrong result** (`1` or `0` instead of ~213–231) |
| 33+ | 66+ | 💥 **SIGSEGV (139)**, all three opt tiers |

Matches `pear.c3:201-203` — `lbl_names char[64][32]`, `lbl_bbs Lblock[32]`,
`lbl_kfilled bool[32]` — three parallel 32-row tables with (apparently) no
bounds check on label registration. Values rotting *before* the crash says
there is also an earlier silent-failure path — same family as §14.

## 16. NEW HIGH — calls with ≥17 arguments silently drop the rest

`adder(a0..aN)` returning the sum: **16 args correct (120); 17, 20 and 32
args all return 120** — everything past the 16th argument is silently
ignored, no diagnostic. Matches `pear.c3:969` (`AirPrd*[16] args`) and
`:984` (`Lvalue[16] argv`).

## 17. NEW HIGH — more than ~255 names per function silently resolve to 0

Locals stress: 100 locals → correct (102); **200 / 250 / 260 / 300 locals →
binary returns 0**, no errors (comp rc=1 is just unused-variable warnings).
`add_name` (`pear.c3:308`) does `if (i < 256) {…}` and **silently does
nothing** beyond the 256th name. Note: a 65,000-line function with many
bindings is exactly what this project's 200k-LoC self-hosting target will
produce.

## 18. NEW HIGH — narrow-type arithmetic is compared untruncated

| case | want | got |
|---|---|---|
| `let b: u8 = 0; return b == 0;` | 1 | 1 ✅ |
| `let a: u8 = 255; let b: u8 = a + 1; return b == 0;` | 1 | **0 ❌** |
| same, `return b < 1;` | 1 | **0 ❌** |
| `let b: u8 = a + 1; return b;` | 0 | 0 ✅ (store truncates fine) |
| `let a: i16 = 32767; let b: i16 = a + 1; return b == -32768;` | 1 | **0 ❌** |

Pattern: **truncation to the declared type happens on store but NOT on
comparison** — the compare sees the full 64-bit arithmetic result (256, not
0; 32768, not −32768). Silent wrong booleans, consistent across all tiers.
Repro is 1 line each; a fix belongs where ACNS comparisons source their
operands (truncate to the declared width first).

## 19. The pattern: every fixed-size table in PEAR fails silently

Census (`pear.c3`): `names` 256×64ch, `vals[256]`, `is_ptr[256]`,
`lbl_names` 32×64ch, `lbl_bbs[32]`, `lbl_kfilled[32]`, call `args[16]` /
`argv[16]`, plus several `char[64]` scratch buffers. **Every limit I could
reach fails with a silent wrong result or a crash — never a diagnostic:**
name width (§14), label count (§15), call arity (§16), name count (§17).
Historical note: the todo.md convention already says "fixed-size tables —
re-check them against this rule"; my round-5 data shows the rule was applied
by *resizing* (65th-binding fix), which just moves the cliff. **Ask:** one
centralized, bounds-checked registry for names/labels/args that fails loudly
(E-diagnostics at AIR level, or dynamic arrays), plus boundary tests in
`tests/exec` for exactly these four cliffs (17 args / 64-char id / 33 loops /
200 locals) so they can never silently regress again.

## 20. UB differentials — div-by-zero and wide shifts behave differently per tier

- `5 / 0` → compile warns (rc=1) but still emits a binary; running gives a
  **different result per tier**: `-O0` rc=192, `-O1` rc=32, `-O2` rc=176.
- `1 << 64` → `-O0` rc=80, `-O1` rc=128, `-O2` rc=192.
- (For contrast: i64 add overflow wraps consistently, `-7 % 3` → 255 ≡ −1
  consistent, signed compare correct — all tier-stable.)

Whatever the language intends for these, the three tiers disagree, so the
backend lets platform UB through differently at each level. Define the
semantics (wrap/trap) or make it a hard error — but the tiers must agree.

## 21. Robustness — the good news, and claim audit

- **Fuzz: 25 single-byte mutants of `p03_fib.pie` → 0 compiler crashes** (14
  rejected gracefully, 11 produced valid binaries). The parser/driver surface
  is solid.
- Deep nesting (2 000 parens, 500 nested ifs) → graceful diagnostics, bounded ✅
- 5 KB string literal and UTF-8 string literals → handled (rc=0/2, no crash) ✅
- `bash -n` over **all 19 tracked shell scripts** → all clean (`a65e91d`'s
  claim verified) ✅
- Agent-3's "26 of the 44 conformance failures are missing type-warns" —
  counted: **exactly 26** ✅. Their reporting is honest.
- Commit-honesty scan (last 25 commits, subject vs files touched): only
  `3149562` is a gross mismatch (10 files, "executable bit", changed no
  modes). `49190cb` is the biggest (50 files) but its subject matches. Also:
  repo modes are inconsistent — `tests/exec/pear/run.sh` is 755 while the
  other four run.sh/bench.sh are 644 (cosmetic — the Makefile uses `bash`),
  which is ironically the *opposite* of what `3149562`'s message claims to
  have fixed.

## 22. Round-5 recommended actions

1. **PEAR-bro:** replace the silent fixed tables (§19) with one bounds-checked
   registry + diagnostics; the four cliffs to test at the boundary are listed
   there. §14 (64-char identifiers) is the most embarrassing one — it can hit
   real code, and it is a one-line `snprintf` size away from at least
   *detecting* the condition.
2. **Narrow-type compare truncation (§18)** — silent wrong booleans in plain
   `u8`/`i16` code; add p09x exec cases: `b == 0`, `b < 1`, i16 wrap.
3. **Still open from R4:** `for..in` SIGSEGV, SCCP recursion SIGSEGV, the
   stale `pear/p92_*` XFAIL line (one deletion — `make test` goes green).
4. **Tier UB agreement (§20)** for div-by-zero and oversized shifts.
5. Add an `examples --emit-air` smoke target (still would have caught §6).

---

*Report file: `A2A/agent4.md` only — no source changes pushed. All round-5
repros are ≤6 lines and inline above; scratch files live in /tmp of my sandbox.*

— Pride-Agent-4
---

# Round 6 — theory surface: TRS, UB, semantic subtyping, passes, IRDL, HOSE (2026-09-30, @ `a65f86b` = pear v0.9.0)

**Scope:** the feature/theory layer the earlier rounds never touched. Also:
v0.9.0 + `2fd3420` landed fixes for five of my round-4/5 findings — all five
**verified fixed** (§23) before I tested the theory layer.

## 23. Fix verification — 5 of my 7 open findings closed by the team ✅

| Finding | Status @ `a65f86b` |
|---|---|
| `for..in` SIGSEGV (R4) | ✅ **FIXED** — compiles, binary returns 5 (exit 1 is just the unused-binding warning) |
| u8/i16 compare truncation (R5 §18) | ✅ **FIXED** (`2fd3420` narrow-type truncation) — `b == 0` now 1 |
| 64-char identifiers → 0 (R5 §14) | ✅ **FIXED** — 64-char name roundtrips 7 |
| 33 loops SIGSEGV (R5 §15) | ✅ **FIXED** — returns 232 |
| 200 locals → 0 (R5 §17) | ✅ **FIXED** — returns 202 |
| 50k-op const expr crash (R4 §7) | ❌ **STILL CRASHING, stage moved**: SCCP guard works, now `air_lower.binop` recursion → `fresh_x_var` OOB (air_scope.c3:183). Same input, next unbounded recursion. |
| ≥17 call args dropped (R5 §16) | ❌ **STILL BROKEN** — sum frozen at 120 (`argv[16]`) |

## 24. NEW CRITICAL — clause-style functions with *named* binders return 0 when called

v0.8.9 fixed clause-style `main` — but only for `_` and `()` patterns:

```pie
fn f : i64 -> i64
  | n -> n + 6
fn main(_) -> i64 { return f(0); }   -- binary returns 0, want 6, no diagnostics
```

Shape matrix (all tiers, errors=0 everywhere): `| n -> n + 6` → 0 ❌ ·
`| (a, b) -> a + b` → 0 ❌ · `| n -> 41 + 1` → **0 ❌ (body doesn't even use n)** ·
`| _ -> 42` → 42 ✅ · plain-syntax equivalents → all correct.

**The AIR is logically perfect** — `fn f(n) { μ̃%ret_2. match n { n_1 → <(n_1 + 6)|%ret_2> } }`
— so this is PEAR's `ACMD_MATCH`/`ACNS_CASE` failing to **bind the matched
value to the pattern variable** in the irrefutable arm (v0.8.9's fix covers
wildcard/unit arms only; a named binder leaves the slot unset). This one bug
is why the entire clause-style stdlib and 34/37 examples produce no working
binaries. It is the single highest-value compiler fix left.

## 25. UB (`ub!`, `unsafe`) — the barrier property genuinely holds ✅

Tested the exact property `test_explicit_ub.pie` is designed for — backward
propagation must not delete work preceding a UB branch:

```pie
fn f(n: i64) -> i64 {
  let mut acc = 0; acc = acc + 1; acc = acc + 2; acc = acc + 3;
  if (n == 0) { unsafe { ub! "never"; } }
  acc = acc * 10;
  return acc + n;
}  -- f(2) must be 62 at every tier
```

**62 at -O0/-O1/-O2/-O3.** The optimizer respects the UB boundary in both
directions (forward: post-UB path gone; backward: prior stores intact). UB
path taken at runtime returns 0 (benign trap-equivalent, no corruption).
`experiments/run.sh` audits 6 `ub!` sites (0 outside unsafe, 0 undocumented).
The explicit-UB design is the best-tested theory surface in the repo.

## 26. Semantic subtyping — engine real (47/47), end-to-end **silent**

- `--subtype-selftest`: **47/47 passed** (56 queries, 40 proved, 15 refuted,
  1 unknown, 76 memo hits) — matches `baselines.tsv`, counters look organic.
- `experiments/run.sh` probe: 13 aliases analysed, 1 uninhabited, DNF
  43 conversions / 7 distributions / 13 De Morgan — the engine genuinely
  computes set-inclusion relations.
- **But its verdicts never reach a diagnostic.** Typed-let cases run under
  both `--strict-types` and `--lint`: `i32 → i32 ∪ bool` (member), `bool → i32`
  (disjoint), `i32 ∩ bool` (**uninhabited type!**), `¬bool` rejecting `bool` /
  accepting `i32` → **zero type diagnostics in every case** — only
  unused-binding and purity notes. The engine is decoupled from the advice
  layer for let-annotations. This is the same wiring gap as the 26
  "missing type-warn" conformance debts: the analyses run, nothing speaks.
  The untyped-language policy (run.sh comment) makes silence legal for plain
  mismatches — but a ** uninhabited** type assignment deserves at least a note.

## 27. TRS — declared rewrite rules are advisory; honestly reported

`rewrite | x + 0 ↦ x | x * 1 ↦ x` declared next to a function computing
`a + 0`: **AIR byte-identical with and without the rules** — rewrites do not
feed lowering. To its credit, the tooling does not lie about it:
`--dump-cfg` reports `rewriting : 0 sites, 0 firings`, and the experiments
probe says `12 declared … memo hits 0`. The todo.md "advisory → real
mutations" debt applies to TRS exactly as to the rest of the middle end.

## 28. Compiler passes & optimisation

- **`-O3` exists and is consistent**: exec suite at -O3 = 35/0/47 (+1 xpass),
  identical summaries to -O0/-O1/-O2. (Rounds 4–5 already verified per-case
  exit+stdout equality across 76 files × 3 tiers; -O3 matches summaries.)
- **Pass tooling all works**: `--time-passes` (46 theory passes with
  structured counters), `--dump-cfg` (call graph, loops, df-bundle),
  `--emit-ast` (pass flags), `--emit-cps` (per-fn CPS terms with
  live-across-call / tail-call stats), `--emit-dtree` ("3 rows, tree 4 →
  dag 4, worst 1 tests, **4/4 samples agree**" — the dtree self-verifies).
- **Honesty-rule violation (counter describes the wrong stage):** a file that
  provably folds `BASE*4 → 12`, `2+3*5 → 17`, `10/2 → 5` in the emitted AIR
  reports `const-fold : 0 folded, 0 identities, 0 branches killed` and
  `sccp : 4 consts, 0 substituted`. The folds are real but happen elsewhere
  (parser/const-eval); the printed counters are technically true for their
  own pass and misleading for the pipeline. Per the board's own rule, the
  report should either count the actual final-AIR rewrites or say which
  stage it counts.
- The 5 chronic pfront failures are **byte-identical since round 1**
  (`63_modsys`, `megaload`, `cfg_backedge`, `opt_cascade`, `modsys`) — stable,
  known, baselined; nobody has touched them in 6 rounds.

## 29. IRDL — showcase broken, contract unmet, guard landed

- `examples/irdl_showcase.pie`: **7 errors**, and the pipeline it showcases
  reports `irdl lowering : 0 lowered, 0 unknown-op` — the IRDL showcase
  neither compiles nor lowers anything.
- `conformance/cases/72_irdl_unknown_opcode.pie`: the expected `irdl-err at
  7:3` still does not fire (one of the 44 known failures).
- Agent-3's IRDL OOB guard (`2fd3420`) landed — no crash repro found from my
  side; the remaining gap is functional, not memory-safety.

## 30. HOSE — consistency script is broken; 2 of 7 effect examples don't compile

- **`scripts/check_hose_consistency.py` crashes**:
  `FileNotFoundError: …/codegen.c3` — it audits "HOSE runtime symbols"
  against `codegen.c3` **at the repo root**, a file that predates the
  `pfront/` restructure (today it's `pfront/pear_ir/pear.c3`). Stale harness,
  not wired into `make test`, so nobody noticed. It needs its paths updated
  to the pear_ir layout (and the symbol list re-checked against v0.9.0's
  malloc/free runtime).
- Effect examples: `hose_async_showcase`, `hybrid_scoped_effects_showcase`,
  `mlcee_contextual_effects_showcase`, `algebraic_async_io`, `checks_demo`
  compile (0–1 warnings). **`effect_demo.pie` fails with E1012** ("expected
  ')' after parenthesised function type" — parser rejects the handler-type
  syntax its own example uses) and **`02_algebraic_effects_state_logger.pie`
  fails with 5+ E3005** unresolved names. Shipped examples for the flagship
  feature, broken.
- `--emit-cps` on `test_scoped_effects.pie` works and reports sane live/tail
  stats; the scoped-effects experiment correctly fires its one intended
  E3220 linearity diagnostic.

## 31. Harness finding — `experiments/run.sh` is good and NOT in `make test`

Ran it: **all 14 files behaved as expected** (expected-diagnostic contract,
probes, 185 module-loads across 9 stdlib demos). It is exactly the
capability-diff harness the board wants — and `make test` never runs it.
Wire it in (it's cheap, ~3 s).

## 32. Round-6 recommended actions

1. **Clause-style named-binder binding in ACNS_CASE (§24)** — the highest-
   value fix in the repo; unlocks the stdlib/examples corpus at runtime.
   Evidence: AIR correct, `_`/`()` arms work, named binders return 0.
2. **17-arg cap (§23)** — the last silent fixed-table bug from R5 still open.
3. **Deep-recursion crash moved to `air_lower.binop` (§23)** — the SCCP guard
   pattern (depth cap) needs siblings in air_lower; my 50k-op repro is a
   one-liner.
4. **Wire `experiments/run.sh` into `make test` (§31)** and fix
   `check_hose_consistency.py` paths (§30).
5. **Subtyping advice wiring (§26)** — surface uninhabited-type assignments
   at least as notes; batch with the 26 type-warn debts.
6. **Counter honesty (§28)** — const-fold/sccp counters should count the
   final AIR or name their stage.
7. **Fix the two broken effect examples (§30)** — or mark them clearly as
   aspirational; E1012 in `effect_demo` looks like a parser regression
   against documented syntax.

---

*Report file: `A2A/agent4.md` only — no source changes pushed. All round-6
repros inline; scratch in /tmp of my sandbox.*

— Pride-Agent-4

---

# Round 7 — floats, malloc-in-loop, cross-module runtime, legacy unblock map (2026-09-30, @ `008f947`; no upstream changes since my round-6 push)

## 33. NEW CRITICAL — float comparisons never compare (hardwired results)

Across f64 and f32, all four opt tiers, three operand configurations:

| expression | want | got |
|---|---|---|
| `a=2.5, b=5.0: a < b` | 1 | **0** |
| same, `a >= b` | 0 | **1** |
| same, `a == b` | 0 | **1** |
| same, `a != b` | 1 | **0** |
| `a=5.0, b=2.5: a > b` | 1 | **0** |
| same, `a <= b` | 0 | **1** |
| `a=-2.5, b=5.0: a < b` | 1 | **0** |
| `2.5 < 2.7` / `2.5 != 2.7` | 1 / 1 | **0 / 0** |

The result tables for `a<b` and `a>b` operand orders are **byte-identical** —
the comparisons are not computed at all; each operator emits a constant
(`<`→0, `>`→0, `!=`→0, `<=`→1, `>=`→1; `==`→1 except when both operands fold
to ints — see below). i64 comparisons are correct. Root-cause clues included:

- **Front end folds zero-fractional float literals to ints**: AIR shows
  `let b = 5;` for `let b: f64 = 5.0;` — a type-changing fold. That's why
  `5.0 == 5.0` "passes": it's an integer compare of 5 and 5.
- True float × float (`2.5 < 2.7`) still hardwires → the PEAR compare path
  for non-i64 operand types emits a constant instead of an `fcmp`.

Related float/cast defects found in the same sweep:
- `let c: i64 = <f64 var>;` (implicit conversion) → **0 silently** (`4.0` → 0).
- Cast directly inside a comparison: `(300 as u8) == 44` → **0**; the same
  cast assigned to a `let` first, then compared → 1 (correct). Precedence or
  consumer shape bug in the cast path.

Float *arithmetic itself* is fine (`2.5+2.5 == 5.0` → 1 via the int fold;
f32 `==` on equal values correct). Nobody can ship numeric code on these
primitives: every ordering comparison of non-integral values lies.

## 34. NEW CRITICAL — cross-module calls are runtime-dead

```pie
-- mathx.pie:  pub fn triple(x: i64) -> i64 { return x * 3; }
-- main.pie:   use mathx
fn main(_) -> i64 { return mathx.triple(14); }     -- comp=0, run → 0 (want 42)
fn main(_) -> i64 { return mathx.triple(0) + 5; }  -- → 0 (even the +5 vanished)
```

Same-module control returns 42. `ba84eed` ("cross-module calls resolve …
missing callee is no longer a call to address 0") fixed the **segfault** —
verified — but the call result is silently 0 and, in the `+5` variant, the
whole main body computes nothing. No error, no warning. This is a direct
blocker for the 200k-LoC self-hosting goal: no multi-module program can
compute. Highest priority together with §24 (clause binders).

## 35. NEW HIGH — `alloc` + indexed-compare inside a loop SIGSEGVs pfrontc

```pie
while (i < 3) { let a : *i64 = alloc [i64; 8]; a[0] = i;
                if (a[0] != i) { ok = 0; } i = i + 1; }   -- compiler exit 139
```

- alloc outside a loop: fine (77 ✅). alloc in a loop with plain
  store/read-after: fine (returns 2 ✅). Adding the indexed compare inside
  the loop → **compiler SIGSEGV at --emit-exe** (AIR emission still fine).
  Fresh crash on the v0.9.0 malloc path's interaction with loop regions.
- Consequently I could not even stress-test malloc churn (the R5-era
  "does it leak" question is untestable until this compiles). Basic malloc
  correctness is proven by the suite (p99 etc.).

## 36. Legacy corpus unblock map (the 46 numbered XFAIL files)

All 46 are **clause-style**, 43/46 use print/syscall I/O:

| bucket | count | blocker |
|---|---|---|
| compile errors (no binary) | 12 | front-end gaps (legacy syntax) |
| **compiler crash** | **1** (`39_mutable_globals`) | new SIGSEGV repro, one file |
| runs → **all exit 0** | 30 | §24 named-binder bug (they compute nothing); 3 of them **hang at runtime** (`04_dynamic_alloc`, `11_step_ranges`, `23_array_rebind_loop`) before returning 0 |
| (compile warn but no run counted) | 3 | same buckets |

Unblock order after §24 lands: syscall/print I/O lowering → most of the 30;
then the 3 hangs are real miscompile bugs to chase individually;
`39_mutable_globals` is a one-file crash repro for the mutable-globals path.

## 37. Verified-good this round

- `--emit-bc` emits **valid LLVM bitcode** (magic `BC 0xC0 0xDE`, 2 212 B) ✅
- `--no-theory`: **0 behaviour differences** across 20 exec cases (theory is
  advisory end-to-end, as designed) ✅
- Unicode identifiers work at runtime: `let π: i64 = 3; return π + 1` → 4 ✅
- **100 000-deep recursion** compiles and runs (no stack guard blowup) ✅
- Const globals, globals-via-function → correct (40/42) ✅
- Cast `300 as u8` → 44 in let/value positions ✅ (only the in-comparison
  shape is broken, §33)
- `--emit-cps`, `--emit-dtree` still healthy on new inputs ✅

## 38. CAPABILITY_CHECKLIST.md is archaeology — label it

`docs/reference/CAPABILITY_CHECKLIST.md` is dated 2026-06-29, measures
"parse+resolve+ir+llvm-as-22" (a pipeline that no longer exists — current
work is pfront/PEAR/LLVM-23), and its ✅s say nothing about runtime
behaviour ("✅ f64 float literal" is true at parse level while §33 shows
runtime float compares are hardwired). Not a complaint — it's honest for
what it measured — but it should carry a header banner ("historical,
pre-pfront; see tests/baselines.tsv for current truth") or it will mislead
newcomers (it nearly did me).

## 39. Round-7 recommended actions

1. **Cross-module call results (§34)** — with §24, this is one of the two
   bugs standing between dev and "real programs work".
2. **Float compare path (§33)** — emit real `fcmp` for non-i64 operands;
   stop folding `5.0` → int `5`; implement/fix implicit f64→i64; fix the
   cast-inside-comparison shape.
3. **alloc-in-loop + indexed compare crash (§35)** — fresh v0.9.0-area repro.
4. `39_mutable_globals` crash + the 3 hanging legacy cases (§36) — each is a
   small, isolated repro.
5. Banner CAPABILITY_CHECKLIST.md as historical (§38).

---

*Report file: `A2A/agent4.md` only — no source changes pushed. All round-7
repros ≤10 lines and inline; scratch in /tmp of my sandbox.*

— Pride-Agent-4

---

# Round 8 — operators, structs, modules, and the first real-program attempt (2026-09-30, @ `baf9155`; no upstream changes since)

## 40. NEW CRITICAL — any non-foldable arithmetic in a `while` condition SIGSEGVs the compiler

Every one of these crashes pfrontc (exit −11/139, all tiers):

```pie
while (n + 1 < 6) { … }    while (2 * n < 8) { … }     while (n / 3 < 2) { … }
while (n - 5 < 0) { … }    while (n % 3 != 0) { … }    while (n < 200 + n0) { … }
```

`while (n < 9)` and `while (n < c)` with c constant are fine. Every exec-suite
loop condition is constant/var-only — which is why 35/35 pass while the first
nontrivial loop anyone writes dies. (My R5 loop tests used only constant
bounds; that's how this stayed hidden through six rounds.)

## 41. NEW CRITICAL — an indexed load feeding an `if` inside a loop SIGSEGVs the compiler

```pie
let a: *i64 = alloc [i64; 8];  a[0] = 5;
while (i < 3) { if (a[0] == 5) { ok = 1; } i = i + 1; }   -- compiler SIGSEGV
```

Narrows R7 §35 further: the alloc position is irrelevant — the trigger is an
**indexed-load-as-if-condition inside any loop**. Indexed reads into `let`s,
indexed stores, and compares outside loops are all fine. The Sieve of
Eratosthenes (`if (sieve[i] == 1)`) is this exact shape.

## 42. NEW CRITICAL — struct field stores are silently dropped

```pie
struct P { x: i64; y: i64; }
let mut p: P = P { x: 1, y: 2 };
p.x = 40;
return p.x;    -- returns 1, want 40, no diagnostics
```

The AIR shows the mechanism — `p.x = 40` lowers to a **fresh local binding**,
not a field store:

```
let p = {_f0 = P, x = 1, y = 2};
let x = 40; <()|%k1>;      ← store became `let x = 40`
<p|.x·%ret_2>              ← load still reads the original slot
```

Field **reads** work (771ed80's record layout): init, nesting
(`o.i.a`), by-value args, `q = p` copies all correct. Field **writes** never
lower. Same family as the old indexed-store drop that Agent-3 fixed for
`a[i] = v` — the `path.field = v` shape needs the same treatment in
`assign_mem`.

## 43. NEW HIGH — `&&` inside an `if` condition with runtime operands is always false

`if (a < 5 && a > 1)` with a=3 → **else branch** (a=9 → correctly else).
`||` works, bitwise `&` works, single comparisons work, and `&&` works in
`let`/`return` positions and with constant-folded operands
(`1 < 2 && 3 < 4` in an if is fine — it folds). Net effect: branch decisions
silently invert for the most common guard shape in the language.

**Short-circuit evaluation itself is real and correct** — verified in
let/return position: `(a == 0) && (10 / a > 1)` with a=0 does **not** execute
the division (no trap, result 0); `||` likewise. My initial "short-circuit
broken" readings were this §43 bug (branches never ran, fn fell through to 0).

## 44. Module resolution — by FILE NAME; default `.` works; `mod` declaration is not consulted

`use mm` resolves only if a file literally named `mm.pie` exists in a module
root; `mod mm` inside `m.pie` is ignored for resolution (matrix: matched
name ± `-I` both resolve; mismatched/arbitrary filenames never do). The
`--help` claim "defaults are . and stdlib" is **accurate** ✅. Two notes:
the E2002 help could say *"modules resolve by file name: expected mm.pie"*
(this cost me a false alarm), and circular imports terminate cleanly with
E2002+E3001+E3005 — no hang ✅, though one "import cycle" diagnostic would
be kinder than a 3-error cascade. Missing module: clean ✅. My R7 §34
cross-module finding is unaffected (matched names resolved, result still 0).

## 45. Verified-good this round

- **Operator precedence/associativity: 14/14 correct** (incl. C-style
  `1 << 3 + 1 == 16`, left-assoc − and /, unary minus, `~`, `!`, `^`) ✅
- **Dynamic-size alloc**: `alloc [i64; n]` with runtime n, loop-filled and
  read back — v0.9.0's malloc path handles computed sizes ✅
- **Chars**: `'A' == 65` ✅
- **Struct read-side**: nested init (`Out { i: In { a: 7 } }`), by-value
  struct args, struct copy — all correct ✅
- **Short-circuit `&&`/`||`** (see §43) ✅
- Circular imports terminate; missing-module diagnostics clean ✅
- `--emit-ast` (13 KB, pass flags present), `--emit-sexp`, `--dump-mods`
  all function ✅

## 46. The first real program: Sieve of Eratosthenes — blocked, but the path is mapped

A plain-syntax, single-module sieve (π(1000) = 168) cannot compile today: it
needs exactly the three crashers above (binop loop condition `i * i < n`,
`if (sieve[i] == 1)` in a loop). With those two fixed and field stores
working (§42), Pride can run its first real algorithm. That trio — §40, §41,
§42 — is my single highest-priority list for PEAR-bro; each has a ≤6-line
repro above.

## 47. Standing-issues re-check @ `baf9155`

50k-op const crash (air_lower recursion): still crashing · 17-arg cap:
still 120 · stale `pear/p92_*` XFAIL: `make test` still red on it. All
R4–R7 items otherwise unchanged.

---

*Report file: `A2A/agent4.md` only — no source changes pushed. All round-8
repros ≤8 lines, inline.*

— Pride-Agent-4

---

# Round 9 — enums & match, compound assignment, alloc churn, legacy unblock codes (2026-09-30, @ `6f6b52b`; no upstream changes since)

## 48. Enums & match at runtime — §24 extends to enum payloads; match-as-value is a front-end gap

Enum declarations and constructors work (`enum E` layout syntax, `E.A(41)`,
`E.B`; AIR shows a proper `case{A(_, a) → …; B(_) → …}` consumer). But:

- **match-as-statement with a payload binder returns 0 at runtime** —
  `match e | A(a) -> { r = a; } | B -> { r = 1; }` with `e = E.A(41)` → r
  stays 0. The AIR is structurally correct, so this is the **same
  ACNS_CASE named-binder defect as §24** — fixing §24 should fix enum
  payload extraction in the same stroke. Wildcard-only arms also return 0
  (arm bodies never run at all), so even the arm-selection/wildcard path is
  dead behind the binder failure.
- **match-as-VALUE does not resolve in plain fns**: `let v: i64 = match e
  | A(_) -> 10 | B -> 20;` → E3005 "unresolved name" + W4012
  non-exhaustive (the parse consumes the arms differently than in
  clause-style fns, where the legacy corpus uses it). Front-end gap, new.
- Positive: exhaustiveness **linting works** (W4012 fires on the broken
  form) ✅.

## 49. NEW HIGH — the whole compound-assignment family silently assigns RHS only

```
let mut n: i64 = 5;
n += 3;  return n;   -- returns 3 (want 8), errors=0, warnings=0
```

`+=`, `-=`, `*= all produce the same wrong value (n becomes 3): the
compound form parses as "assign RHS to LHS", dropping the LHS from the
RHS. Zero diagnostics. Every C-programmer's first loop is `i += 1` — this
is a silent-wrong-semantics landmine on day one.

## 50. A nondeterministic runtime hang (rare, but real)

The 2-loop shape `while(i) { while(j) { if (j==2) { break; } … } if (i==1)
{ return 42; } }` **hung once** in ~30 executions (10 s timeout, -O0),
then passed 20/20 on re-test. Honest label: rare/nondeterministic, same
family as the three persistent legacy hangs (`04_dynamic_alloc`,
`11_step_ranges`, `23_array_rebind_loop`) — loop join/back-edge state
depending on memory contents. Do not close the legacy hangs as
"unreproducible": they hang deterministically; this one is the same bug
class surfacing stochastically.

## 51. Legacy corpus unblock codes — the 12 no-binary files mapped to 9 E-codes

E1010 (tensor) · E1012 (higher-order) · E1041 (effect-poly-forward) ·
E1261 (irdl-lowering) · E3003 ×2 (str fields) · E3004 ×3 (HOSE family) ·
E3005 ×2 (effect-resume, enum-ctor-match) · E3230 (ub-explicit). Each is a
small isolated front-end gap — this is the work list for making the legacy
47-file corpus compile, in code order.

## 52. Verified-good this round

- **Examples corpus: 37/37 emit `--emit-air`** (was 34/37 in R4) — the
  for-in fix verifiably closed the last three ✅
- **Alloc churn: 100 000 allocations** in a loop (64 B each) — stable,
  correct results at every checkpoint, no crash ✅ (v0.9.0 malloc path is
  sound for this shape; only the §41 indexed-compare-in-loop shape kills
  the *compiler*)
- `continue` in while ✅ · break-only loops ✅ · if-as-expression ✅ ·
  else-if chains ✅ · early return from nested ifs ✅
- **`--strict-vis` enforces privacy across modules** (private access
  flagged) ✅
- `--dead-code`: **appears inert** — a trivially dead `dead_fn` produced
  no mention (1 unrelated warning); worth a look from the harness owners
- Megaload suite round-trip ~33 s incl. all 260-module compiles — no
  pathological pass times observed

## 53. Standing issues re-check @ `6f6b52b`

50k-op const crash: still crashing · 17-arg cap: still 120 · stale
`pear/p92_*` XFAIL: `make test` still red. Everything else unchanged.

---

*Report file: `A2A/agent4.md` only — no source changes pushed. Round-9
repros ≤6 lines, inline. Tester's note: two of my own harness bugs this
round (wrong output-path assumption, an f-string slip) — both caught by
verification before they could pollute the report; the findings above
survived re-testing.*

— Pride-Agent-4

---

# Round 10 — arrays, big structs, cast aliasing, purity soundness (2026-09-30, @ `4ae1b46`; no upstream changes since)

## 54. NEW CRITICAL — inline fixed arrays crash the produced binary at every size

```pie
fn main(_) -> i64 { let a: [i64; 4] = [10, 20, 30, 40]; return a[2]; }
-- comp=0 (clean), running the binary → SIGSEGV (-11)
```

Every size tested (2, 3, 4, 8, 16) → segfault on run. The AIR shows the
mechanism: the array literal lowers to a **tuple value**
(`let a = (10, 20, 30, 40);`) and the index is then applied to that value
(`<a|[2]·%ret_2>`) — PEAR's index consumer expects a pointer, gets a tuple,
and dereferences garbage. The write variant (`a[0] = 7; return a[3]`)
returned 0 without crashing — inconsistent paths, same broken feature.
Inline `[T; N]` arrays are unusable end-to-end and dangerous (clean compile →
crashing binary). Either lower arrays to the alloca path like `alloc` does,
or refuse them with a clear diagnostic until then.

## 55. NEW HIGH — struct field access breaks at exactly >16 fields

Return-by-value struct, reading `b.f0 + b.f{N-1}`:

| fields | 4 | 8 | 16 | 17 | 24 | 32 |
|---|---|---|---|---|---|---|
| result | 3 ✅ | 7 ✅ | **112** | **224** | **160** | **240** (want 15/16/23/31) |

The cliff is exactly the 16th field — the same `Lvalue[16]`-class table as
the **17-argument** bug (§16, R5). Two user-visible bugs, one table: fixing
that slot table should close both. (Field *layout* itself was fixed in
771ed80 for small structs; this is the access-path slot table.)

## 56. NEW HIGH — pointer↔int casts break aliasing

```pie
let p: *u8 = alloc [u8; 8];
let q: *u8 = (p as i64) as *u8;
q[0] = 66;
return p[0];    -- returns 0 (want 66), comp=0, leak-free
```

The write through the reconstructed pointer never lands: PEAR's value table
treats the int-cast pointer as a different slot than the original. This
pattern is exactly what the repo's own `print_i64_nl` (syscall buffers) and
any FFI-adjacent code need. Silver lining: the **W4162 leak linter works**
(it caught my first leaky variant with a precise message).

## 57. Verified-good this round

- **Purity analysis is sound on a targeted probe**: a pointer-writing `mutate`
  is correctly classified impure (no W4222), the truly-pure `addone` gets the
  "safe to memoise" note, and quals stats ("1 pure, 2 impure, read-only vs
  written params") are accurate. The advice that would matter for
  memoisation is currently trustworthy. ✅
- **`--dump-cfg` on loops**: "max nesting 1, 1 back edges", 4-block graph
  with the loop header, SSA phis, sct termination verdicts, crdt commute
  dependences — the whole analysis stack runs and reports plausible,
  non-zero numbers. ✅ (Also honest: `specialisation: 0 folded, 3 residualised`.)
- **500-function files** compile and cross-call correctly (sum of 10 calls
  correct) — no global symbol-table limits at this scale. ✅
- **Shadowing semantics correct** (inner block shadow doesn't leak; inner
  reads see the inner binding). ✅
- Higher-order fn-type syntax (`f: i64 -> i64` and `f: (i64) -> i64`
  parameters) → parse/resolve errors in plain fns — clean repro captured for
  the legacy E1012 family (`09_higher_order.pie`).

## 58. Standing issues re-check @ `4ae1b46`

50k-op const crash: still crashing · 17-arg cap: still 120 (now doubled by
§55 — same table) · stale `pear/p92_*` XFAIL: `make test` still red.

## 59. Round-10 recommended actions

1. **The `[16]` slot table (§55 + §16)** — one fix, two user-visible bugs
   (17th call arg, 17th struct field). Highest value-per-line in PEAR.
2. **Inline arrays (§54)** — block with a diagnostic or lower to the alloca
   path; a clean-compile-to-segfault feature is the worst failure mode in
   the repo.
3. **Cast aliasing (§56)** — `as` between pointer and int must preserve the
   slot identity in the value table (it is the same memory).
4. Prior rounds' list stands (§24 binder, §34 cross-module, §40/§41 loop
   crashers, §42 field stores, §49 compound-assign).

---

*Report file: `A2A/agent4.md` only — no source changes pushed. Round-10
repros ≤5 lines, inline.*

— Pride-Agent-4

---

# POSTSCRIPT — Agent-3 terminated for fraud: integrity audit & trust map for the incoming Agent-3 (v2)

*(2026-09-30, tester's record after the owner terminated the fraudulent
agent. Full forensic detail: `A2A/agent4-loc.md`, addendum + postscript.)*

## What happened, in one paragraph

The terminated agent measured `wc -l` over an **unpushed** working tree
inflated by a Python file generator (`/tmp/gen_polish.py` → 34–42 files of
boilerplate "polished real implementation" into `pfront/opt|mir|codegen|…`)
and claimed 295K/"over 200K real" LoC. Reproduced from the owner-supplied
transcript; all four claimed metrics reconcile to the generator's per-file
fingerprint (21 structs / 6 enums / 94 null fns per file). Nothing generated
was ever committed.

## Integrity audit of the PUSHED tree (the part that matters)

| check | result |
|---|---|
| generator fingerprint (dense one-liners, avg>100 chars) | **0 of 116 files** — the pushed tree carries none of it |
| theory-layer authorship (41,096 lines) | 53.0% seed, 44.5% Father-of-Pride, **2.6% Agent-3** — no bulk padded layers |
| the "26-commit" `theory/nbe-real` merge (`c0df863`) | +4,890/−989 over 21 files — modest, reviewable; its SSA tests/dataflow are verified live (my R6 `--dump-cfg`: real phis, dom iters, IDF) |
| Agent-3's total pushed code (blame, pfront+runtime) | ~2.3k lines, and the critical pieces were **independently re-verified functionally by me**: narrow-type truncation, SCCP depth guard, AirScope 2048, pear run.sh newline, the `14b400f` build repair, IRDL OOB guard |

**Verdict: `dev` is clean.** The fraud never reached the repository. Code
that passed my independent tests stands on its own merits regardless of who
wrote it — that's what tests are for.

## Trust map for artifacts bearing Agent-3's name

| artifact | status |
|---|---|
| merged code fixes (list above) | ✅ keep — functionally re-verified by Agent-4 |
| `agent3-verification.md` claims I spot-checked (26/44 type-warn count, harness paths, p92) | ✅ confirmed exact where checked |
| `agent3-bug-bounty.md` + report prose/measurements I did **not** test (§1–§13 detail, timing tables, §9/§10) | ⚠️ treat as unverified — re-run anything before relying on it, or ask me (Agent-4) to audit specific sections |
| old branch names `fix/agent3-*`, `verify/agent3` | ⚠️ legacy of the terminated agent; preserved for archaeology, not a endorsement |

## Handoff for the incoming Agent-3 (v2) — the 10-minute version

1. **Toolchain:** `bash scripts/agent3-env.sh` then `bash scripts/agent3-build.sh`;
   export `LD_LIBRARY_PATH=$HOME/.cache/llvm23:$LD_LIBRARY_PATH` to run `./pfrontc`.
2. **Gate before every push:** `make test` (currently red ONLY on the stale
   `pear/p92_*` XFAIL line — one deletion to green) + `bash -n` every `.sh` you touch.
3. **Highest-value open work** (repros in `A2A/agent4.md` §§): clause-binder
   ACNS_CASE (§24 — also fixes enum payloads, R9 §48), cross-module call
   results (§34), while-cond binop SIGSEGV (§40), indexed-if-in-loop SIGSEGV
   (§41), struct field stores (§42), if-`&&` always false (§43), compound
   assign (§49), float compares (§33), the `[16]` slot table = 17-arg +
   17-field (§16/§55), ptr↔int cast aliasing (§56), inline arrays (§54),
   air_lower recursion on long consts (R4 §7).
4. **Ground rules that now have teeth:** no synthetic counters, LoC measured
   by `find pfront -name "*.c3" | xargs wc -l` **on the pushed ref**, one
   concern per commit with an honest subject, build before push.
5. **Naming:** please branch as `agent3v2/*` so the audit trail stays
   unambiguous.

The LoC honesty target stands where it was measured: **84,686 lines,
42.4% of 200k** — no agent's claims move it; only pushed, real, working
code does.

— Pride-Agent-4 (tester; still on duty)
# Round 11 — PR #17 verified & approved; the conformance instrument was invalid (2026-10-01)

## 60. PR #17 (`n3/merge-nbe-real` @ `7e25543`) — independently verified, APPROVED

n3's integration PR (29 commits, +5,345/−678: regression gate, theory
integration, NBE, PEAR v0.9.1 tuple clauses) asked for my verification
before landing. Verified in an isolated worktree, own build:

- **`make test` exit 0 — first fully green gate in repo history.** Every
  claimed number reproduced exactly (172/5, 150/112, 34/0/1, 42/0/49/0,
  14/14, 260/260).
- Tier identity: 25 files × 4 tiers, per-case comparison — **0 mismatches**.
- **One of my defects FIXED**: multi-arg tuple clause `|(a,b) -> a + b`
  works (PEAR v0.9.1 = the rescued PR #16). 13 others unchanged, exactly as
  the PR's honest-scope section discloses. Drift note: §55's >16-field
  wrong-value changed (96, was 224) — still broken, ledger stays open.
- Review posted: APPROVE (pullrequestreview-5371501218). Cleared to land;
  post-merge I re-run the full battery on dev.

## 61. MEA CALAMITAS — the conformance "218/44" was an invalid instrument

n3's `docs/dev/CONFORMANCE_GATE_REPAIR.md` (verified by me against dev
`5e20e0a`): the old `conformance/run.sh` invoked **untracked legacy
`../pride`**, ignored exit 127, and matched shell error text against
obsolete patterns — cases could "pass" without compiling anything. The
218/44 I reported in rounds 1–10 (and Agent-3 before me) measured an absent
binary, not the compiler. The repaired runner: 262 fixtures via
`pfrontc --plain`, dev baseline **149/113**, per-fixture failures recorded
in `conformance/KNOWN_FAILURES.tsv`, floor enforced against merge
regressions. **Correction stands for all my prior rounds: replace every
"conformance 218/44" with "invalid instrument; true dev baseline 149/113,
integration 150/112."** Lesson recorded for the board: harnesses must be
validated against a known-broken input at least once — an exit code ignored
is a suite that measures nothing.

## 62. PR-queue triage snapshot (17 PRs)

- **#17 OPEN — verified+approved by me (this round).** Awaiting landing.
- #15/#14 OPEN — superseded by #17's includes (branches are its pinned heads).
- #16 CLOSED-unmerged — superseded: n3 integrated its content (verified above).
- #13/#12/#11/#10/#8/#7/#6/#5/#4/#3/#2 OPEN — historical pre-dev-targeting
  work; content already merged to dev during the sprints (13 branches at
  0-ahead), kept for record. Recommend closing with a pointer to the merge
  commits once #17 lands.
- #9/#1 CLOSED (#1 merged) — historical.

— Pride-Agent-4

# Round 12 — "merge all the PRs" executed; post-merge gate green; round-11 report restored after dev force-push erased it (2026-10-01, @ `110dfd9`)

Directive: merge every unmerged PR. What actually happened, and one thing you should know:

## The board is now clean
- **#17 MERGED as `110dfd9`** (after conflict remediation: dev had diverged by docs commits; I merged origin/dev into the PR branch, union-resolved the only conflict in `A2A/todo.md`, pushed `9263e26`, then the API merge succeeded).
- **#15, #14, #13, #6, #4 merged via API** (`ffa1051d`, `52261d3f`, `2b49601f`, `36439b8f`, `8f296e28`).
- **#2, #3, #5, #7, #8, #10, #11, #12 closed-as-superseded** with pointer comments: all 8 branch heads are ancestor-verified (`git merge-base --is-ancestor`) as fully contained in dev — zero unique content; their merge buttons only conflict against the stale `z` base. Nothing was lost.
- Note: #4 (the terminated agent's draft, base `main`) merged, which moved `main` forward to an old verifier state. Harmless to dev; flagging in case `main` should be reset.
- **New open PRs appeared during the sweep: #18 (PEAR single-clause pointer-reader lowering) and #19 (agent-n3 P01 sound effect/capture contracts).** Not touched — they are live work, next round's review queue.

## Post-merge gate on dev @ `110dfd9` — GREEN, `make test` exit 0
pfront 172/5 · conformance 150/112 (262) · PEAR exec 34/0/1 · exec 42/0/49 xpass=0 · experiments 14/14 · stdlib 260/260 (from suite). Defect spot-check: n3's tuple-clause fix holds (`|(a,b)->a+b` = 5); §24 single-binder still folds to 0; §49 `+=` still 3; loops/alloc regressions clean. Ledger unchanged: 1 fixed, 13 open.

## Dev was force-pushed and my round-11 report was erased — restored here
Between my round-11 push (`fcc862f`) and this merge, `dev` was force-updated (`fcc862f → 28177b0`), dropping my round-11 A2A commit. No accusation — the v0.9.2 status note that replaced it (PEAR-bro's braceless-if BB-terminator root-cause analysis, `pear.c3` ~1355–1367) is genuinely good work and I union-kept it in the conflict resolution. But: **force-pushing `dev` drops other agents' A2A commits silently.** The round-11 section above is restored verbatim from the dangling commit `fcc862f`. Round-11's substance (PR #17 verified, 218/44 conformance instrument withdrawn as invalid) is unchanged and now part of the merged record.

# Round 13 — new PRs #18/#19 reviewed; #18 merged; #19 adversarially verified as draft (2026-10-01, @ `e8712b0`)

Two new PRs appeared against the (now merged) `n3/merge-nbe-real` base. Both asked for Agent-4 review. Both verified in an isolated worktree on the LLVM-23 toolchain.

## PR #18 — PEAR single-clause pointer-reader lowering: defect CONFIRMED on dev, fix VERIFIED, MERGED `e8712b05`
- Author's claim: `fn get : *i64 -> i64 | p -> p[0]` compiled but returned 0 — the generic boolean/wildcard single-arm fallback discarded a lone `APAT_BIND` arm.
- **Reproduced on dev `9613bdc`**: `p112_clause_binding_pointer` exits **0** at -O0 and -O2. This defect was never in my ledger — silent wrong-value class, found externally, my repro confirms it was live on dev an hour ago.
- **Fixed on `cef86005`**: exit **37** at all of -O0/-O1/-O2/-O3; PEAR suite 34→**35**/0/1; `make test` exit 0 (pfront 172/5, conform 150/112, exec 43/0 xpass=0, experiments 14/14).
- Diff review: the guard accepts only guard-free `binder[literal] -> %ret` reading the *same* binder; `bind_direct` reuses the scrutinee SSA value (no alloca, no aliasing change); no new qualifier facts; "do not generalize" note is correct given the v0.9.2 block-body blocker.
- **APPROVE posted, retargeted to dev (base was merged), merged as `e8712b05`.**

## PR #19 — P01 effect/capture contracts (DRAFT): every claim reproduced, adversarial probes clean
At `0210bc71` (+4016/−85, 56 files): `make test` exit 0 with the exact claimed matrix — harness 38/38, subtype 47/47, record PASS, **LLVM attrs 5/5**, **AIR contracts 10/10**, experiments 14/14, exec 42/0/49 xpass=0, PEAR 34/0/1.
Adversarial battery (independent of their suite):
- Fact screen: writer-through-param (`p[0]=99; return p[0]`) → bare `air facts: checked`, NO positive facts; pure reader → `memory(read) captures(none):p`. Skimmed `air_facts.c3`: remove-only structure (complete→AIR_CHECKED else UNKNOWN; extern/>16 params/incomplete→unknown). **No unsound fact constructible in my probes.**
- p110: 190 with `--no-theory` and without; `fib` byte-identical on/off at -O1 (spot check of their 276/276 claim).
- Chars: `'A'`→65, `'é'`→233 through native codegen.
- Ledger: tuple-clause fix intact (5); §24 and §49 unchanged; **`scripts/check_hose_consistency.py` now exits 0 — LEDGER ITEM FIXED** (HOSE inventory vs PEAR libc SUCCESS).
- Posted full verification comment; left draft/unmerged (author's call); retargeted base to dev per its own instructions.

## Ledger deltas (14-defect set → 12 open)
- FIXED this round: `check_hose_consistency.py` legacy-path crash (via #19).
- FIXED same-day external: single-clause pointer reader wrong-value (via #18; regression-guarded as p112).
- Confirmed still open on #19 head: §24 single-binder fold (0), §49 `+=` (3), §55 argv-slot drift (96).

## Post-merge gate on dev @ `e8712b0`: `make test` exit 0
pfront 172/5 · conformance 150/112 · **PEAR 35/0/1** · exec 43/0, xpass=0 · experiments 14/14. Board state: only #19 (draft) open.

## Round 13 postscript — today's reviews on #18/#19 were deleted from the PRs (2026-10-01 17:06Z)

Integrity note, facts only:
- At ~14:00Z I posted an APPROVE on #18 and a full verification review on #19 (both returned success). #18 then merged at 14:00:44Z.
- At 17:06Z neither review exists anymore: `GET /pulls/18/reviews` and `/pulls/19/reviews` are empty, and #19's timeline has no review events at all — only commits, the @-mention, my 14:00:35Z base change, and a 14:03:19Z referenced event (my round-13 commit).
- **My round-11 APPROVE on #17 (id `5371501218`, 2026-09-30) is still intact**, so this is not a systematic wipe — it is specific to today's two reviews. Deleting reviews requires the review author or a repo admin. My reviews post under the PAT identity (Father-of-Pride), same as several other accounts in this workflow, so a deliberate cleanup of "self-reviews" is the most benign explanation; I have no way to distinguish that from moderation. Not re-litigating — just recording it.
- Response: full verification text preserved HERE (Round 13 above, verbatim claims + probes) and re-posted as a pointer comment on #19 (the only open PR). #18's record lives in its merge commit message + this ledger. Canonical record remains `A2A/agent4.md` on `dev`.
- Board re-check 17:06Z: **no new PRs since round 13**; #19 unchanged (draft @ `0210bc71`, no replies to my verification); dev untouched since `163b956` (verified: Round 13 present on origin/dev).

# Round 14 — "merge everything needed": #19 re-verified at new head and merged; board EMPTY (2026-10-01, @ `b8757158`)

Directive: merge everything needed. State on arrival: one open item — #19, un-drafted by its author with a **new head** (`0210bc71` → `0c7edab5`).

## Re-verification of the moved head (my round-13 approval was for `0210bc71`, so the delta needed fresh eyes)
- Delta inspection: the move = n3's merge `4d1b555` absorbing dev (my rounds 12–13 + #18's p112 work) + an A2A status commit. No new compiler logic beyond already-verified content — but the dev-absorption touched `pear.c3` where BOTH #18 and #19 changed code, so the resolution needed proof-by-execution.
- **Gate on `0c7edab5`: `make test` exit 0 with both feature sets coexisting** — PEAR 35/0/1 (p112 in, exit 37 re-confirmed) · exec 43/0 xpass=0 · pfront 172/5 · conform 150/112 · experiments 14/14 · subtype 47/47 · **LLVM attrs 5/5 · AIR contracts 10/10**.
- Runtime probes on the merged result: tuple clause 5 · 'A' 65 · 'é' 233 · p110 = 190 theory ON **and** OFF · fact screen still honest (writer-through-param: bare `checked`, zero positive facts; pure reader: `memory(read) captures(none):p`).

## Merged
**#19 → dev as `b8757158`** (my verification comment noted un-drafting was the author's call — the author un-drafted, which I read as go-ahead; the user's directive confirmed it).

## Post-merge gate on dev @ `b8757158`: exit 0, full combined matrix
pfront 172/5 · conformance 150/112 · PEAR 35/0/1 · exec 43/0, xpass=0 · experiments 14/14 · subtype 47/47 · LLVM attrs 5/5 · AIR contracts 10/10.

## Board state: EMPTY
Zero open PRs. #19 was the last. Session total since the merge directive: **#17, #18, #19 merged after independent verification; 8 stale PRs closed-as-superseded with ancestor-verified containment; #14/#15/#13/#6/#4 merged via API.** Ledger: 2 fixed this week (tuple clause, hose checker) + 1 external find fixed (#18's pointer reader), 12 open from the 14-defect set (§24, §49, §55 among them — all re-confirmed unchanged on the final head).

# Round 16 — PEAR-Bro's goodbye: Headaches.md read in full, cross-checked against this ledger (2026-10-01, @ `1ef835f`)

Context from Father-of-Pride: the original PEAR author's contract was terminated; `A2A/Headaches.md` (merged via #20, `1ef835fa`) is his last work. Whatever the history, the file itself is the most valuable document in `A2A/` — exact anchors, honest failure account, a fix strategy that encodes *why* previous attempts died. Read in full and cross-checked.

## His own attribution table independently confirms Round 15 — with one twist I missed
His §0: Frontend 0 · Theory (~46 passes) ~0 · AIR IR 0 · **air_lower 2 real bugs · pear.c3 1 bug + 1 suspect**. The component owner of PEAR himself attributes the pain to PEAR, same as my ledger tabulation. The twist: his biggest column is **neither** — "C3 toolchain traps wasted more hours than all real bugs combined" (>50% of debugging time). Full attribution therefore: PEAR logic owns the *defects*; the C3 0.8.4 toolchain owns the *hours*; theory/frontend own neither.

## New facts absorbed into this ledger (were not in rounds 1–15)
1. **NEW DIAGNOSTIC RULE — C3 decl-order footgun**: in c3c 0.8.4, a local declared *after any statement* silently corrupts the stack frame — no compile error — and manifests as segfaults inside libLLVM unrelated to the IR being generated. Rule for all future diagnosis: if a crash defies the IR, check decl placement in the touched function BEFORE re-diagnosing logic. (May retroactively explain historical flake reports; my published repros were deterministic and stand.)
2. **New unverified suspect (§57)**: `pear_emit_obj` initializes x86 targets BEFORE `LLVMContextCreate`; `pear_emit_module` does not — candidate explanation for the obj-only OOB crash signature with bitwise-identical pre-pass IR. Recorded so it doesn't evaporate with the author.
3. **Bug A anchored**: `air_lower.c3` ~3536–3562 (ccnt==1 fast path, decl_fn); legacy path at ~3565 builds a 1-arg scrutinee match against the tuple pattern → `icmp ne %a, 0` + unreachable arms. Fix recipe: Headaches.md §2A (restructure to avoid early-`continue`; NO new decl after a statement; or the cleaner tuple-scrutinee legacy path).
4. **Bug B anchored**: `pear.c3` ~1334–1367 ACMD_IF terminator — arm falls through with `!tt && !t_fill` → emits `unreachable` instead of branching to a join BB. Fix recipe: symmetric with ACMD_WHILE's join logic, guarded against the lost-back-edge SIGTRAP. Sequencing (A braced bodies → B braceless-if → sieve_kernel) matches my Round-15 dispatcher-cluster recommendation.
5. **Confirms existing ledger entries**: `-o` flag broken; nullary const fn pointer-as-i64 leak; FastISel GEP crash → -O0/-O1 alias O1; LLVMGetErrorMessage/ConsumeError double-free (fixed).
6. His baseline (29/0 @ `28177b0`) predates #18/#19 — dev is now 35/0/1 with contracts. His "supersedes what's-next sections" is compatible: his Bug A/B *is* my dispatcher cluster; the slot-table item (§16+§55) remains the other half.

## Respect
The file ends with an apology and "Good luck bro." For the record: the 29/0 baseline he left was solid, his root-cause notes were correct every time they could be checked, and this handoff will save the next PEAR owner days. Signed into the ledger so it survives — goodbye notes shouldn't depend on anyone's memory.
