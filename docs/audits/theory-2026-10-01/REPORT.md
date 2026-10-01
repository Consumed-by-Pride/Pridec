# What the theory layer actually does
## Full module/integration audit — agent-n3, 2026-10-01

**Short answer: it does real work, but it is not the end-to-end “theory compiler” its names and some comments suggest.**

It contains functioning AST rewrites, limited lambda normalization, compile-time evaluation, source checks and mathematical models. Much of its SSA/CPS/type/effect infrastructure builds **auxiliary representations that the native emitter never consumes**. A smaller set of facts reaches code generation in PR #17. That integration is real, but this audit also finds an **unsound pointer-capture claim** in its producer analysis.

Do not interpret “many passes ran,” “soundness errors=0,” or a passing algebra self-test as “this program was formally verified.”

---

## 1. Exactly what was audited

| Target | Pinned source | Status when audited |
|---|---|---|
| Current `dev` | `fcc862f` | Contains PEAR v0.9.1 and Agent-4's review report; **does not contain PR #17** |
| Proposed integration / PR #17 | `7e25543` | The tested four-branch integration, independently approved but not yet landed |

The distinction matters. In particular, production set-engine advice and dense-switch/qualifier-to-LLVM wiring are present in the PR, not in the current dev emitter.

Coverage:

- All **47 theory source files / 46 C3 module namespaces**, their orchestrator entry paths, output fields/flags, direct consumers and registration routes. `theory_trs_proof.c3` shares the `theory_trs` namespace.
- **83 execution files × 4 requested flags × theory on/off = 664 compiler/native attempts**, using the unmodified PR compiler. These are file cases, not the additional canary/driver checks counted by the normal exec gate.
- **31 existing theory-oriented fixture pairs**: final AST, AIR and diagnostics compared on/off.
- **13 feature probes** on both targets, at O0/O2, default and strict/lint modes: 208 variants. Extra pointer/driver counterexamples and repeated dispatch tests.
- An audit-only raw-IR build to inspect consumers **before LLVM re-infers facts or optimizes them away**. It changes only the O0 LLVM pipeline string from `default<O1>` to `verify`; the instrumentation diff is included. It is not a shipping compiler or performance measurement.
- External timing/RSS measurements, 20 measured fresh-process runs per setting after warm-up, alternated on/off.

**Limits:** this is a full module/integration audit, not an exhaustive line-by-line proof of roughly tens of thousands of source lines, a mechanized metatheory, or exhaustive testing of all programs. Source reference scans are supporting evidence, not a magically resolved dynamic call graph. Algorithmic soundness beyond the tested fragments remains unestablished.

Compiler sources were not modified for the audit. Known failures were not removed or rebaselined. The ordinary PR regression gate was re-run and still exits 0 (172/5 pfront, 150/112 conformance, 34/0/1 PEAR, 42/0/49/0 exec, 47/47 subtype, 10/10 record construction, 2/2 attribute construction). Those passing construction tests are not substitutes for the new producer-soundness counterexamples.

## 2. The architecture, stripped of the marketing

```text
.pie
  -> parse + resolve + ordinary effect/type/flow analysis
  -> ordinary frontend constfold
  -> TheoryPipeline on the ENTRY AST
       checks / auxiliary graphs / selected AST rewrites / facts
  -> ordinary frontend SCCP + constfold
  -> post-transform AST
  -> AIR
  -> PEAR -> LLVM -> native ELF
```

The decisive boundary is simple:

> A theory result affects native code only if it changes the AST actually handed to AIR, changes a fact AIR/PEAR reads, or blocks compilation with a diagnostic. An internal graph or a printed certificate is not automatically compiler IR.

`--no-theory` skips `TheoryPipeline`, **not** parsing, resolution, primary type inference, primary effect/flow checks, ordinary constfold/SCCP, AIR or LLVM optimization. Therefore ordinary optimized arithmetic still works without it.

The pipeline is run on `entry.ast`; loaded library modules are later included in native emission without a corresponding per-module TheoryPipeline run. This is not a uniform whole-program theory analysis.

Another driver defect: the entire semantic/theory/optimization/emission block is inside `if (verify && entry.ast != null)`. Thus `--no-verify --emit-exe` returns success for a valid program but emits no executable. It disables much more than the advertised AST verifier.

Source: [driver routing](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/pfront_main.c3#L389), [TheoryPipeline initialization/run](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/theory_check.c3#L569).

## 3. What demonstrably changes real behavior

The table below uses the shipping compilers, not an isolated toy model. Both current dev and the PR reproduce the first five feature results.

| Probe | Theory enabled | `--no-theory` | What it establishes |
|---|---|---|---|
| Small immutable lambda application | exit **42** | native **SIGSEGV / 139** | NbE rewrites a supported lambda fragment into something the backend can execute |
| Higher-order “apply twice” | exit **42** | native **SIGSEGV / 139** | This is actual beta normalization, not just a counter |
| `comptime 6 * 7` | exit **42** | exit **0** | Forced compile-time evaluation replaces the production AST; without it, the marker has no proper native implementation |
| Explicit user rewrite `0 ↦ 42`, applied at `|>` | exit **42** | exit **32**, not 42 | Scoped rewrite application really changes the emitted program. Off is not meaningful semantics for a source feature whose implementation was disabled |
| Quote escape / splice at stage zero | hard **E3202 / E3201**, no executable | accepted/no corresponding theory error | Staging checks really enforce a supported source discipline |
| Alias cycle `type T = T` | hard **E4240** | accepted; main exits 42 | A real source rejection, not merely advisory output |
| Unknown registered-dialect opcode | hard **E3210** | accepted; main exits 0 | Name validation works, even though dialect lowering does not |

A first local-rewrite prototype was parsed with its following expression inside the rewrite definition rather than at an application site. It was discarded as a feature test and corrected to a top-level rule plus an explicit pipeline. The report uses only the corrected result; a zero “sites” count from a wrongly shaped input is not evidence that TRS is inert.

### Actual backend consumers in the PR

The raw-IR witness avoids the common mistake of crediting the theory layer for attributes LLVM independently inferred later:

- `NF_DENSE_SWITCH` -> AIR case/match hint -> **three real LLVM `switch` instructions**, versus **zero** with theory disabled, on the integer/character/clause fixture.
- `NF_PURE_FN` -> LLVM **`memory(read)`**, not `memory(none)` or a termination claim.
- `NF_READONLY_PARAM` for directly typed pointer/reference params -> LLVM **`captures(none)`**, deliberately not `readonly` or `noalias`.

These consumers are real in PR #17. They are absent from current dev's backend. Their **soundness depends on the producer**, which is not established just because the LLVM API accepts an attribute.

Source: [AIR facts](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/pear_ir/air_lower.c3#L3368), [semantic attribute helpers](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/pear_ir/pear.c3#L1827), [dense case lowering](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/pear_ir/pear.c3#L745).

## 4. How much difference does it make on the ordinary corpus?

PR #17, all four requested flags:

| Setting | File cases per flag |
|---|---|
| Theory on | **34 PASS / 0 FAIL / 49 XFAIL** |
| Theory off | **33 PASS / 1 FAIL / 49 XFAIL** |

Out of **332 paired runs**, both modes emitted binaries in **276** pairs. **272 / 276 were byte-identical.** The four nonidentical pairs are the same dense-dispatch fixture at the four flags.

Only two file cases differed in artifact/runtime observations:

1. `pear/p110_dense_switch`: **190 on / 0 off**, at every flag. Three repeated O2 runs reproduce each value. Isolating dispatch functions gives:
   - `choose(2)`: **32 on / 99 off**;
   - `choose(9)`: **99 on / 99 off**;
   - `choose_char('c')`: **33 on / 0 off**;
   - `choose_clause(9)`: **26 on / 0 off**.
   The theory-selected path works, while fallback match lowering is wrong. This is a backend correctness dependency on an analysis hint—not evidence of a general correct pattern compiler.
2. `15_ub_explicit`: theory rejects it before an artifact; off emits a binary that exits 0. It remains XFAIL under the file's original expectations in both settings. A stable XFAIL count can conceal a changed failure mechanism.

The other **81 file cases** had identical artifact/native-result observations at each flag. That does **not** prove the layer is useless: the ordinary corpus largely excludes the explicit lambda/comptime/rewrite feature probes above.

For 31 existing theory-family fixtures:

- raw final S-expressions differed in **27/31**;
- after removing only synthetic/effect annotations, structure/value/name/operator differences remain in **18/31**;
- AIR text differed in **17/31**.

These are whole-pipeline ablations, including downstream amplification by ordinary frontend passes. An AST annotation change is not a runtime improvement, and an AIR file may be diagnostic output for an erroneous program.

**O0 caveat:** the existing PEAR O0 route uses LLVM `default<O1>`. We tested four requested driver flags, not four independent LLVM optimization levels or a genuinely unoptimized shipping backend.

## 5. The large pieces that do not become a native compiler

### SSA and dataflow: real algorithms, disconnected results

`theory_ssa`, `theory_dataflow`, and `theory_irdlssa` construct real auxiliary graphs/constraints. The dataflow bundle solves four bitvector problems. But no AIR/PEAR consumer of those solved graphs/facts was found.

The native backend constructs its own LLVM representation from the AST, using allocas and LLVM optimization. It does not execute the reported theory SSA phis. `theory_live` is an exception: a limited dead-local consumer exists in `theory_opt`; this is not equivalent to consuming the separate DfBundle or SsaBuilder.

### CPS, continuations, closures and effects

CPS conversion, resume classification and continuation-tree normalization run. They can produce meaningful dumps and diagnostics. The native emitter does not consume those representations.

The valid Ask/handle/resume probe should produce **42**, compiles with no frontend errors, but exits **0** with theory either on or off. Its AIR contains `handle`/`perform`, while the native emitter has no handler/perform implementation and falls back to unsupported-command behavior. The preserved C HOSE runtime is not linked into ordinary PEAR native output.

`theory_defun` finds captures/escape hazards. `NF_ADDR_TAKEN` influences later NbE/CRDT analysis; `NF_NOESCAPE` has no operational reader beyond the writer/dump. There is no evidence that this pass generates general closure tags/dispatch, heap boxes or native captured-continuation support.

### IRDL lowering is structurally disconnected

This is stronger than “we did not see a useful example”:

- `add_opcode` initializes `rule_count = 0` and `arity_known = false`.
- Source registration adds opcode names, not lowering templates.
- `DialectTable.add_lowering` is the **only** code that increments rule count or fixes arity.
- It has **no caller** in the compiler.
- `lower_call` immediately returns null when rule count is zero.

Thus normal `lower_tree` calls cannot lower registered source opcodes; arity checks depending on that registration also remain dormant. Name validation does work. A registered `D.add(20, 22)` compiles and returns **0**, not a computed 42, in both targets. The existing audit's claim of a live source-to-AST dialect lowering path needs this qualification.

Source: [registration](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/lower/theory_irdl.c3#L163), [unused lowering registration](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/lower/theory_irdl.c3#L206), [zero-rule early return](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/lower/theory_irdl.c3#L320).

### CMTT meta-variable solver

The production `MetaCtx.scan` just recurses. `absorb` copies hereditary-step/meta-variable counts. The source explicitly says contextual meta-variable solving and the contextual occurs-check are not performed; their counters remain zero. Storage/substitution APIs existing in the file are not a working language-level solver.

`theory_hered` genuinely normalizes an auxiliary typed term representation and issues judgments, but does not reify those units onto the compiled AST. That is different from the real mutating `theory_nbe`.

### Types and polymorphism

There are several distinct engines/stores: primary `pfront_types`/`pfront_infer`, the 47-case subtype engine, a separate semantic-DNF model, the “full” semantic engine, modal/bidi stores, records, mu and session models.

In PR #17, set-algebra assignments/joins are actually implemented in the **primary frontend**, and remain present with `--no-theory`. The theory bridge additionally emits optional emptiness advice for supported shapes. It is not the universal production subtype rule.

An impossible annotation still compiles and runs under `--strict-types --lint`; it produces advice, not universal rejection. Direct `i32 ∩ bool` bindings produce W3292. A named `Empty` alias binding is skipped by the syntactic `has_set_operator` prefilter, although the alias declaration itself gets W3291.

`theory_poly` produces real substituted signatures, with a fallback into `call.type_slot` only when primary inference left it null. It does not generate specialized source bodies or general monomorphized LLVM functions. Signature statistics are not body specialization.

### Dormant AST facts

| Output | Operational state |
|---|---|
| `NF_BOUNDS_PROVEN` | Written; no AIR/PEAR consumer. No check-elision/range-attribute pipeline follows from it |
| `NF_INDEPENDENT`, `NF_REDUCTION` | No output-flag consumers. No reordering/parallel reduction codegen |
| `NF_RECURSIVE_TY` | Analysis/dump; no recursive native layout consumer |
| `NF_NOESCAPE` | Analysis/dump; not a backend closure-conversion hook |
| `NF_TAIL` | Auxiliary analysis/dump; not LLVM tail-call lowering |
| theory `NF_EXHAUSTIVE` | A flow reader exists, but flow runs **before** this theory flag is written. Static references alone do not establish causal use |

Source ordering matters. A field being referenced somewhere else in the repository is not sufficient evidence that the newly produced fact is used in this compilation.

## 6. Serious correctness findings

### H1 — unsafe `captures(none)` claim in the proposed integration

Minimal source:

```pie
fn retain(out: **i64, p: *i64) -> i64 {
  out[0] = p;
  return 0;
}
fn main(_) -> i64 { return 42; }
```

With theory, the PR emits:

```llvm
define i64 @retain(ptr %0, ptr captures(none) %1) {
  ...
  %address = ptrtoint ptr %1 to i64
  %byte = trunc i64 %address to i8
  store i8 %byte, ptr %0
  ...
}
```

Without theory, that `captures(none)` is absent for `%1`; LLVM's own later inference also leaves it capturable.

Even the backend's separate pointer-store width bug does not make this contract true: the function stores observable address information outside itself. `captures(none)` excludes address capture, not just saving a whole dereferenceable pointer. The LLVM reference distinguishes address and provenance components.

Cause: assignment processing scans RHS with `in_return=false` and does not mark storing a parameter through an external pointer as escape. The identifier handler only marks escape in return position. `verdicts` then turns “not recorded as written/escaped” into “never retained,” and AIR attaches the semantic contract.

**Severity: high optimizer-contract defect; fix/gate before landing those annotations.** This probe demonstrates invalid IR assumptions, not a claimed native miscompile in its unused `retain` call. A main returning 42 is a control, not proof the escaped-pointer program is correct.

I own the integration-side lesson: the previous n3 API tests correctly establish that LLVM receives semantic attributes. They do **not** establish that `theory_quals` correctly proves every producer fact. Those tests passed; this adversarial audit exposes the missing second layer of proof/testing.

Source: [assignment scan](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/meta/theory_quals.c3#L572), [escape/verdict](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/theory/meta/theory_quals.c3#L761), [consumer](https://github.com/Consumed-by-Pride/Pridec/blob/7e25543/pfront/pear_ir/air_lower.c3#L3427). Contract reference: [LLVM pointer-capture semantics](https://llvm.org/docs/LangRef.html#captures-attr). The downloaded reference is current documentation, not misrepresented as the exact installed-library source revision.

### H2 — “pure”/readonly advice is stronger than the analysis

`read_first(p)` is classified as “result depends only on arguments / safe to memoise,” but the same pointer argument produces **3 then 9** as the pointed memory changes (the probe totals 12). The classification is a no-write approximation, not mathematical purity. The PR's weaker `memory(read)` mapping is correct in that respect; `memory(none)` or memoizing by pointer value would not be.

A parameter-readonly note also literally says “noalias readonly,” while another aliased parameter can write the same memory. The current backend intentionally avoids those stronger attributes; the diagnostic should stop promising them.

### H3 — indirect-local alias writes can evade the qualifier proof

`local_holds_pointer` recognizes a selected initializer-kind list. A pointer selected through `if` is not on it; the `write_choice` probe is diagnosed as pure and side-effect-free despite writing through that selected pointer. Its existing backend also emits malformed bitcode in both modes and returns the unchanged value, so this audit **does not attribute a new native miscompile to the theory flag**. The source producer claim is nevertheless unjustified and unsafe to use when that backend shape is repaired.

The safe direction is conservative alias/escape analysis, not assuming an unrecognized pointer-producing expression is local-only.

### H4 — backend attribute IDs do not match the restored LLVM 23 ABI

The active `LLVM_ATTR_NOUNWIND = 42` maps to **`nosanitize_coverage`**, not nounwind; LLVM's named lookup returns nounwind kind **45**. Raw IR confirms the wrong attribute. Six of eleven configured named constants differ from the library lookup; most mismatched constants are currently dormant, so this is not a claim all six are actively corrupting code.

Malloc/free `allockind` are also emitted as quoted custom strings, not the semantic integer attribute. Their working allocator behavior must not be credited to a semantic annotation this code never emits. Proper libc symbols/signatures/linking and LLVM's own library analysis are separate.

Use named kind lookup and direct semantic-attribute checks throughout, not manually copied enum numbers. This is a backend-consumer audit finding, separate from the theory algorithms themselves.

### H5 — driver and reporting claims

- `--no-verify` silently skips emission and returns success; demonstrated on a valid return-42 program.
- “None of these analyses can reject a program because Pride is untyped” is false: stage, alias-cycle, dialect-name and structural checks do reject supported bad inputs.
- “Feature-absent passes are skipped” is overstated: the orchestrator allocates/initializes most models and calls their walkers based on nonnull objects, not feature predicates.
- Pass timing uses `clock()` (process CPU time), although comments call it wall time.
- A structural verifier and aggregate before/after counts are not a semantics-preservation proof or automatic fault localization to one pass.

## 7. What the impressive counters mean

The record layer runs a built-in semantic-law suite even with zero source structs. `SemanticSubtyper.verify_query_laws` runs during initialization. Other “DNF laws / soundness errors / certificate” rows mix internal calibration examples with source analyses.

On the minimal return-42 input, the report says **46 passes**, **0 source structs**, yet **386 record-semantic Boolean checks**, plus 38 DNF laws and 12 subtype-query laws. These can be useful regression tests of an implementation. They are not fake by definition. But:

> “386 Boolean checks, zero soundness errors” can describe a finite internal test matrix—not 386 statements in your program proved safe, and certainly not proof the emitted native code is correct.

The 47-case subtype self-test is similarly evidence for its supported decision-procedure examples, not evidence that every production type judgment, budget-overflow path, ABI layout or theory-to-LLVM contract is sound.

## 8. Measured cost

External measurements; whole frontend invocation with `--quiet -O2`, no native code emission, same input, three warm-ups then twenty measured fresh processes, order alternated. Medians, not universal claims:

| Target/input | Theory on wall | Off wall | Ratio | Median peak RSS on/off |
|---|---:|---:|---:|---:|
| PR / minimal return-42 | 40.00 ms | 27.64 ms | 1.45× | 71.47 / 59.99 MiB |
| PR / small higher-order lambda | 39.82 ms | 27.12 ms | 1.47× | 71.48 / 60.00 MiB |
| PR / wide-record source | 38.34 ms | 27.18 ms | 1.41× | 68.41 / 59.93 MiB |
| Dev / minimal | 36.03 ms | 26.95 ms | 1.34× | 70.02 / 59.86 MiB |
| Dev / lambda | 37.10 ms | 27.21 ms | 1.36× | 70.04 / 59.86 MiB |
| Dev / wide records | 34.84 ms | 28.47 ms | 1.22× | 66.61 / 59.86 MiB |

For a tiny ordinary source, the PR layer costs about **12 ms and 11.5 MiB** here. This includes startup/parse/front-end overhead in both modes. It is not isolated execution time for a single pass and says nothing about runtime speedups on large workloads.

## 9. What I would do next, in order

1. **Block or conservatively gate capture annotations until escape analysis handles assignment-RHS storage, address exposure and aliases.** Add producer counterexamples, not only attribute-construction tests. Repair the “pure/noalias” diagnostic claims too.
2. Replace copied LLVM attribute IDs/custom allocation strings with named semantic APIs and query-based regression checks.
3. Fix generic match lowering; it must not need a dense optimization hint to implement ordinary pattern semantics. Until then diagnose unsupported native shapes rather than returning plausible wrong values.
4. Either register and specify real IRDL lowering rules/arity, or explicitly advertise a dialect-name checker—not a functioning dialect compiler.
5. Keep the working NbE/comptime/scoped-rewrite paths and their capture/effect/metadata regression tests. They already enable useful behavior.
6. Move disconnected SSA/CPS/meta/session/large calibration models behind analysis/debug options or lazy feature activation until they have an actual specified consumer. Preserve useful diagnostics without pretending graphs are execution machinery.
7. Choose a coherent primary type/IR contract before wiring more engines into optimizer assumptions. Separate algorithm self-tests, source judgment tests, producer-fact soundness tests and native behavior tests.

More LoC is not the missing ingredient. **Consumers, supported-language boundaries and sound contracts are.**

## 10. Deliverables and reproduction

- `MODULE_MATRIX.md` / `module-matrix.tsv`: every one of the 47 files, actual outputs, consumers and limits.
- `corpus-results.tsv` / `corpus-summary.json`: all 664 production-mode attempts, original expectations preserved.
- `feature-results-pr.json` / `feature-results-dev.json`: both compiler targets and all feature variants.
- `frontend-results.json`: 31 AST/AIR/diagnostic pairs, with comparison recipe.
- `raw-ir/`, `raw-ir-results.json`, `raw-instrumentation.diff`: before-LLVM consumer witnesses.
- `priority/`, `binding-shapes/`, `repros/`: concrete adverse cases, diagnostics and LLVM.
- `benchmark-results.json`, `enum-attribute-audit.json`: measured cost and API compatibility.
- `source-inventory.json`, `flag-consumers.json`: supporting scans, explicitly not substituted for manual consumer tracing.

Typical production repro:

```sh
cd /home/user/Pridec
bash scripts/agent3-env.sh
bash scripts/agent3-build.sh
export LD_LIBRARY_PATH="$HOME/.cache/llvm23:/usr/lib/x86_64-linux-gnu"
./pfrontc /home/user/theory-audit/repros/nbe_lambda.pie --emit-exe -O2
# Execute the emitted sibling binary; expect 42.
./pfrontc /home/user/theory-audit/repros/nbe_lambda.pie --emit-exe -O2 --no-theory
# Its native lambda fallback fails; not a claim that --no-theory preserves this feature.
python3 /home/user/theory-audit/corpus_diff.py
```

Toolchain caches and audit-only worktrees do not survive snapshot resets; the source/scripts/results do. The raw-build patch is one audit-only pipeline-string change, not a proposed compiler fix.

**Bottom line:** this is a partially connected compiler with a large analysis/research layer. Some theory mechanisms really execute compiler transformations. Most of the grander models are not native implementations. The real integration points need better soundness testing before their reported “proofs” can safely drive optimizations.
