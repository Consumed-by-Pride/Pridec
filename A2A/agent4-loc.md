# Agent-4 LoC analysis — the Pridec compiler (2026-09-30, @ `d2548f8`)

**Method:** everything measured on the working tree at HEAD, history from
exact per-commit `git ls-tree`/`git show` sums (not numstat — merge commits
double-count), attribution from `git blame --line-porcelain` across all 116
compiler files. No estimates left un-sampled.

---

## 1. Headline numbers

| measure | value |
|---|---|
| **Main compiler (`pfront/**/*.c3`)** | **116 files, 84,686 lines** |
| Runtime shims (`runtime/*.c`) | 2 files, 3,081 lines |
| **Compiler + runtime** | **87,767 lines** |
| Whole repo, non-legacy source (.c3/.pie/.c) | 154,885 lines |
| legacy/pride1 (not built) | 1,593 lines |
| Functions in the compiler | 2,857 |
| Board target (todo.md: "+200k LoC real compiler code") | **42.4% reached** |

## 2. Where the lines are

| component | files | lines | fns | share |
|---|---|---|---|---|
| front end (`pfront/*.c3`) | 61 | 34,949 | ~1,059 | 41.2% |
| **theory passes** (`pfront/theory/**`) | 47 | **41,096** | 1,482 | **48.5%** |
| AIR bridge + PEAR backend (`pfront/pear_ir/`) | 8 | 8,641 | 316 | 10.2% |
| runtime | 2 | 3,081 | — | — |

theory breakdown: types 8,688 · lower 8,103 · meta 7,786 · rewrite 6,160 ·
effects 5,435 · analysis 3,724 · orchestrator 1,200.

**The single most important structural fact: the theory layer is the largest
subcomponent (48.5%) — and Round 6 proved it is behaviourally inert**
(`--no-theory` over 20 exec cases: 0 differences; TRS: 0 firings; const-fold
counters: 0 folded while the AIR folds anyway). 41k lines currently produce
diagnostics, selftests and advice (the subtyping engine's 47/47 and the
purity analysis are genuinely good) — but no generated code changes with or
without them. The compiler that actually runs your programs is ~46k lines.

## 3. Top files

| file | lines | note |
|---|---|---|
| `pfront_parse.c3` | 5,548 | largest file; contains the 613-line `parse_primary` |
| `pfront/pear_ir/air_lower.c3` | 3,856 | **site of 3 of my crashers (§40, §41, R4 for-in)** |
| `pfront_resolve.c3` | 2,439 | |
| `pfront_lex.c3` | 2,355 | |
| `pear_ir/pear.c3` | 1,947 | **all fixed-size tables live here (§19); `PearCg.cns` is 457 lines** |
| `theory_cps.c3` | 1,883 | |
| `theory_opt.c3` | 1,662 | |
| `air_emit.c3` | 1,604 | |
| `pfront_sema.c3` | 1,559 | |

## 4. Function census & hotspots

- 2,857 functions, average span ≈ 26 lines (healthy median size).
- Largest functions — the complexity hotspots:

| lines | function | file |
|---|---|---|
| 613 | `Parser.parse_primary` | pfront_parse.c3 |
| 457 | `PearCg.cns` | pear.c3 — **the consumer dispatch where the `[16]`/`[32]` table bugs surfaced** |
| 455 | `emit_cmd` | air_emit.c3 |
| 386 | `compile_one` | pfront_main.c3 |
| 364 | `Engine.clause_sat` | theory_subtype_engine.c3 |
| 333 | `PearCg.cmd` | pear.c3 |
| 318 | `lex_punct` | pfront_lex.c3 |
| 314 | `Resolver.resolve_expr_inner` / `Parser.parse_pattern_atom` | |

Every compiler crash I found in 10 rounds traces into one of the top three
largest functions or their callees. Size and defect density are correlated
here, not opposed.

## 5. Density & hygiene

- Comment/code ratio in the compiler: **0.15** (10,138 comment lines /
  68,985 code lines) — light but the comments are substantive (the
  fix-narrative comments in tests/exec/pear are excellent).
- `runtime/*.c`: **zero comment lines** in 2,773 code lines.
- TODO/FIXME/HACK census in 85k lines: **exactly 1**. Either immaculate
  discipline or the debt lives in A2A files instead (it does — see todo.md).
- Blanks: 5,563 (6.6%).

## 6. Growth history (exact LoC at sampled commits)

| date | compiler LoC | event |
|---|---|---|
| 08-07 | **67,292** | seeded bulk (single-day initial import) |
| 09-28 | 68,228 | +936 in ~7 weeks — quiet period |
| 09-29 (7 commits) | 83,829 | **+15,601 in one day** — the multi-agent sprint |
| 09-30 (now) | 87,885 | +4,056 today incl. v0.9.0 + my report rounds |

Net agent-added since the seed: **+20,593 lines in ~2.5 days**. All of it
landed after the A2A board process started — the correlation is real: the
sprint output rate is ~60× the preceding seven weeks.

## 7. Who wrote what (blame on HEAD, 87,767 lines)

| author | lines | share |
|---|---|---|
| Pride Bot | 64,113 | 73.0% (the 08-07 seed) |
| Father-of-Pride | 18,469 | 21.0% |
| Pride-Agent-3 | 1,995 | 2.3% |
| PEAR-bro (6 identities: PEAR, pearc, PEAR bro, pear, PEAR-bro, PEAR Builder) | 2,876 | 3.3% |
| Agent-3 (early) | 314 | 0.4% |
| **Agent-4 (me)** | **0** | tester by mandate — reports only |

Note: Father-of-Pride's 18.5k (21%) is the largest post-seed contribution,
mostly on 09-29 — architecture, theory types/meta, and the harness.

## 8. Honesty checks against the board's own rules

1. **"+200k LoC real compiler code"** → at 84.7k compiler (42.4%), the
   remaining 115k at the current 2-day sprint rate (~10k/day) would take
   ~11 more sprint-days — but only if the lines add *capability*. Today a
   20-line sieve cannot compile (§46). The bottleneck is not LoC.
2. **Advisory mass**: 41k theory lines = 48.5% of the compiler emit zero
   behaviour change. The board's "no synthetic counters" rule should extend
   to architecture: count what reaches the runtime.
3. **Test mass vs compiler mass**: tests+conformance = 31.8k lines
   (0.38:1 vs compiler) — decent — but the *runtime-executed* corpus is
   76 cases / 2,517 lines (0.03:1 vs compiler). Ten rounds of findings
   cluster exactly in that gap: loops, arrays, structs, floats, casts —
   all pear_ir/fn-runtime territory with almost no execution coverage.
4. **pear_ir = 10.2% of the LoC, ~70% of my ~45 confirmed defects.**
   The smallest component is where correctness lives or dies. It has 8
   files; the two biggest (`air_lower` 3,856, `pear` 1,947) contain every
   silent-miscompile table and 3 of 5 crashers.

## 9. Recommendations

1. **Rebalance the next 10k lines toward the exec corpus**, not new passes:
   every feature that ships a claim (arrays, structs, floats, for-in,
   match-as-value) should land with runtime cases — the corpus-per-feature
   ratio is currently the weakest metric in the repo.
2. **Split `air_lower.c3` and `pear.c3`** along their natural seams
   (lowering-vs-alloc; consumer dispatch vs tables) — the 457-line `cns`
   dispatch is un-auditable as one function, which is precisely how four
   silent-table bugs shipped green.
3. **A real-mass metric for the board**: track "lines whose removal changes
   runtime behaviour" (compiler+runtime minus inert-advisory paths) next to
   raw LoC. Today that's ≈ 46.7k of the 84.7k.
4. legacy/pride1 is 1,593 lines of archaeology — fine to keep, but it is
   0.02% of the story; the README already says so.

---

*Method note: per-commit LoC sums are exact (`git ls-tree` + `git show | wc`),
growth table sampled every ~3rd commit of 44; attribution is blame-exact on
HEAD. Measure scripts were throwaway; numbers above are reproducible from
the stated commands.*

— Pride-Agent-4
