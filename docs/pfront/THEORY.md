# `pfront/theory` — the analysis layer

**Verified 2026-07-31** · c3c 0.8.1 · LLVM 22.1.8 · Debian 13 trixie x86-64

**16,066 LoC across 21 modules.** Every one is wired into the pipeline, runs
on real input, and is covered by the regression suite. Nothing here is
unreachable.

---

## 0. What this layer is FOR

Read this before adding a pass.

**Pride is untyped. No analysis in this directory may reject a program.**

That is not a style preference — it changes what an analysis is *for*. A
conventional compiler computes facts in order to refuse bad programs. Pride
computes the same facts in order to **optimize good ones**:

| Fact an analysis proves | Conventional compiler | Pride |
|---|---|---|
| index out of bounds on every path | error, build fails | mark path unreachable → **delete it** |
| condition always false | warning | **fold the branch away** |
| index provably in range | nothing | **elide the bounds check** |
| pointer provably non-null | nothing | **elide the null check** |
| variable never live across an edge | nothing | **no φ needed** (semi-pruned) |
| type mismatch | error | advisory under `--lint`, nothing by default |

The enforcement point is a single function pair in `pfront_core.c3` —
`DiagBag.advisory` / `advisory_hint`. Advisories are off unless `--lint` is
passed, and are always warnings. To add a type-policing *error* you would have
to call `.error()` directly, which is visible in review.

**There is no borrow checker, no lifetime checker, and no ownership analysis.
None is planned.** One was on an early roadmap; it was never written and the
item is withdrawn.

---

## 1. Module list

| Module | LoC | Contents |
|---|---:|---|
| `theory_opt.c3` | 1,663 | **The optimizer.** Const folding, algebraic identities, branch folding, 3-way DCE, copy propagation, CSE, block flattening |
| `theory_live.c3` | 1,029 | **CFG + liveness + semi-pruned classification.** The `SP` of SP-ERM-e-SSI |
| `theory_poly.c3` | 804 | **Polymorphism: constraint solving + real instantiation.** Unifies declared parameter types against call arguments to produce a substitution θ, checks bounds, applies θ to build a monomorphic signature per instance |
| `theory_absint.c3` | ~1150 | Abstract interpretation: sign, interval (threshold widening), nullness; branch narrowing; loop fixpoint with `break`/`continue` states |
| `theory_mu.c3` | ~830 | Iso-recursive μ-types built from the declarations (struct/enum/newtype → μ; `*T` → option); contractivity, least-fixpoint inhabitation W4250, coinductive shape equality between nominal recursive types N4251 |
| `theory_stratified.c3` | ~680 | Type-definition strata: dependency graph (value/guarded/alias edges, polarity), Tarjan SCCs + levels, NF_RECURSIVE_TY; alias cycles E4240, by-value recursion via variant N4241, non-positive N4242, non-regular generic recursion W4243 |
| `theory_crdt.c3` | ~900 | Commutativity (CALM/CRDT): per-statement read/write location sets, block dependence DAG + critical path, NF_INDEPENDENT; loop accumulators classified counter/product/join/max-min/register/mixed, commutative reductions flagged NF_REDUCTION; N4230/N4231 |
| `theory_quals.c3` | ~750 | Whole-program qualifier fixpoint: purity classes with reasons, parameter write/escape via callees, NF_PURE_FN / NF_READONLY_PARAM; W4220 discarded pure result, W4221 never-written mutable param, N4222/N4223 |
| `theory_matching.c3` | ~1000 | Maranget decision DAGs for every `match` and clause set: f/b/a heuristics, enum signatures, or-rows, guards, hash-consed sharing, tree-vs-first-match verification, NF_DENSE_SWITCH; `--emit-dtree`; N4210 |
| `theory_cps.c3` | ~1300 | Danvy–Filinski one-pass CPS into a continuation IR; tail verdicts (NF_TAIL), join/loop continuations, η/β contraction, contification; `--emit-cps`; W4200/N4201/N4203 |
| `theory_defun.c3` | ~600 | Closure analysis: free vars by binder identity, escape classification (NF_NOESCAPE), mutable captures of escaping closures marked NF_ADDR_TAKEN for boxing; W4190/N4191/N4192/W4193/W4194 |
| `theory_effcont.c3` | ~800 | Handler discipline: lexical prompt stack, W4180 undeclared perform, W4181 call leaks an effect, N4182 multi-shot, W4183 stray / W4184 escaping resume, N4185 dead arm, W4186 arm arity, N4187 tail-resumptive (sets NF_TAIL) |
| `theory_linearity.c3` | ~900 | Ownership of `alloc`: flow-sensitive LIVE/FREED/MAYBE/ESCAPED per resource with aliases, defer, loops; W4160 double free, W4161 use-after-free, W4162 leak, W4166 overwritten while owned, N4163–N4165 path-dependent |
| `theory_sct.c3` | ~900 | Size-change termination (Lee/Jones/Ben-Amram): structural descent through patterns, integer descent only under a guard bound, closure over mutual recursion; W4150 proved loop, N4152 not proved (why), N4151 proved (`--lint`) |
| `theory_ub.c3` | ~520 | UB lattice (Lee et al.): poison flows through bindings/arithmetic; the USE is the diagnostic (W4140 with origin + binding), poison shifts (W4141), dead code after `ub!` (N4142) |
| `theory_nbe.c3` | ~900 | Normalisation by evaluation over the AST: closures/neutrals, β with fresh binders and capture check, effect-safe argument `let`s, δ on β-created redexes, η, dead-lambda sweep |
| `theory_symexe.c3` | ~1000 | Bounded symbolic execution: per-function path sets, interval + disequality decision procedure, witnessed diagnostics |
| `theory_check.c3` | 907 | Pipeline driver, gradual sort checking, per-pass timing |
| `theory_rowinfer.c3` | 834 | Principal-type effect-row inference |
| `theory_pglcert.c3` | 791 | PGL certificates: exhaustiveness with a named counter-example |
| `theory_stage.c3` | 783 | Staged partial evaluation, binding-time analysis, loop unrolling |
| `theory_modal.c3` | 764 | Scoped effects, continuation trees, UB tracking |
| `theory_bidi.c3` | 748 | Bidirectional CMTT: box types become inferrable |
| `theory_egraph.c3` | ~830 | E-graphs: union-find + congruence closure, equality saturation from the ORIGINAL subject (TRS answer joins the root class), cost extraction |
| `theory_eclass.c3` | ~260 | E-class constant analysis (egg §4) on the real graph: make/join/modify hooks, δ inside classes, literal materialisation, contradiction → W4034 |
| `theory_subtype.c3` | 726 | Set-theoretic subtyping by reduction to DNF emptiness |
| `theory_irdlverify.c3` | 725 | IRDL verification traits: SSA form, dominance, purity, termination |
| `theory_effects.c3` | 722 | Handler coverage, linearity, effect rows |
| `theory_irdl.c3` | 688 | Dialect/opcode registry and lowering |
| `theory_cmtt.c3` | 616 | Modal judgment `Γ ⊢^E e : □_{Γ'}^{L'} τ at L` |
| `theory_msp.c3` | 602 | Stage lattice, cross-stage escape, quote hash-consing |
| `theory_trs.c3` | ~1100 | Term rewriting engine: discrimination tree, guards + builtins, structural memo, fuel/node budgets |
| `theory_trs_proof.c3` | ~600 | LPO termination proof, unification-based critical pairs, joinability, confluence verdict |
| `theory_rwsite.c3` | ~400 | Rewrite values: scoped `rewrite`/`rule`/`++` evaluation, application at `|>` / `|>*` |
| `theory_bridge.c3` | 525 | Parser↔theory bridge, feature scan, convention audit |
| `theory_verify.c3` | 461 | AST integrity: 8 invariants, transform snapshot diff |
| `theory_term.c3` | 387 | Structural hashing, hash-consing, substitution |

---

## 2. Why each component earns its place

**Term rewriting (`theory_trs`, `theory_trs_proof`, `theory_rwsite`).**
Spec §16 makes rule sets *values*: built by `rewrite | l ↦ r` or
`rule name = l ↦ r`, composed with `++`, applied with `e |> r` (one
bottom-up pass) or `e |> r*` (to a normal form). `theory_rwsite` is the
evaluator for that language: it walks the tree with a scope of
rewrite-valued bindings and replaces each `|>` node by its rewritten
subject. Nothing outside a `|>` is ever touched — the earlier design pooled
every rule in the file and ran it over the whole module, which rewrote rule
definitions into themselves and fired inside unrelated functions.

Guards (`x * n, is_power_of_2(n) ↦ x << log2(n)`) are evaluated by a small
total interpreter over the matched literals (arithmetic, comparison,
`is_power_of_2`, `is_const`, `same(a,b)`, …); an undecided guard blocks the
rule. Builtins in the right-hand side (`log2`, `popcount`, …) are folded
after instantiation. The e-graph honours the same guards.

Before a set is first applied it is analysed once:

* **Termination** — every rule is checked for `l >lpo r` under a precedence
  induced by the rules themselves (root(l) above every other symbol of r,
  topologically ranked). LPO is a simplification order, so a fully oriented
  set terminates for any strategy. Unproven sets still rewrite, but under a
  small fuel *and* node budget; stalling is reported at the site (W4030) and
  the subject is handed back unrewritten.
* **Confluence** — proper critical pairs: rule j's lhs is unified (occurs
  check, two variable namespaces) with every non-variable subterm of rule
  i's lhs; each pair ⟨r_iσ, l_iσ[r_jσ]_p⟩ is normalised on both sides. All
  joinable + terminating ⇒ confluent (Newman). A non-joinable pair is
  printed as a witness (W4031, an error under `--strict-types`); overlaps
  involving guarded rules are counted as conditional and leave the verdict
  "undecided" (N4033).

**E-graphs (`theory_egraph`).** The destructive rewriter throws away `a + 0`
when it applies `a + 0 ↦ a`, so results depend on rule order. Given
`x*2 ↦ x<<1`, `x*1 ↦ x`, `(a*b)/b ↦ a`, the term `(a*2)/2` reaches `a` **only
if the shift rule fires last**. An e-graph keeps both forms, so extraction finds
`a` regardless of order. Congruence closure is maintained incrementally with a
dirty worklist; extraction is a fixpoint over a pluggable cost model where a
shift costs 2 and a multiply costs 5.

**μ-types (`theory_mu`).** The contractivity / De Bruijn shift‑subst /
coinductive‑subtyping machinery was real but ran on a hard‑coded demo
(`μX. unit ∨ int×X` and `μα.α`), and two of its parts were broken: `shift`
and `subst` never descended into `ST_OPTION`, so any recursion under a
pointer was never unfolded, and the structural comparison delegated
nominal atoms to the set‑theoretic layer, which compares them by node id
(so `Nil` ≠ `Nil`). Now every recursive declaration in the module is
translated to a closed μ‑type — struct → product, enum → sum of
constructor‑tagged tuples, newtype → body, `*T`/`&T` → `T?` (nullable: the
base case), aliases transparent, the binder on the stack → De Bruijn
variable — and three things are decided: contractivity; **inhabitation**
in the least‑fixpoint reading (μX.B has a finite value iff B[X:=∅] is
non‑empty, arrows erased since a closure can always be written) — an enum
whose every constructor embeds itself by value is **W4250**, the struct
case being already E3020; and **structural equality/subtyping** between
distinct recursive nominal types by the Brandt–Henglein algorithm
(assumption kept while the unfolding is examined, unions summand‑wise,
constructors componentwise, arrows contravariant) — two enums with the
same constructors, payload shapes and recursion are one type with two
names, **N4251** (`--lint`). Memo hits are now non‑zero on real input,
i.e. coinduction actually engages.

**Type strata (`theory_stratified`).** Was a Kernel‑F<: sketch that
compared every function type against itself (`predicative=N`); Pride's
corpus has no bounded quantification, so it had nothing to act on. Now it
does the stratification a compiler actually needs: one node per type
declaration (struct/union/enum/newtype/alias, generics included), an edge
for every mention in its body labelled *value* (field, tuple/array
element, variant payload, newtype body, generic argument), *guarded*
(`*T`, `&T`, `[T]`, `fn`) or *alias*, with the polarity of the occurrence
(function parameters flip it). Tarjan's SCCs give the recursive families —
every member is flagged **`NF_RECURSIVE_TY`** (forward‑declare / opaque
pointer) — and the condensation's longest path gives each type's level
(bottom‑up layout order). Per SCC: a cycle that runs only through aliases
is not a type at all (**E4240** — `type T = T` in the fuzz corpus had been
sailing through; `type A = B; type B = A` likewise); a by‑value cycle
through an enum variant, which the resolver's E3020 does not see, is
**N4241** (`--lint`); a recursive occurrence in negative position is
**N4242** (`--lint`: not strictly positive, so `theory_sct`'s structural
argument does not apply); a generic family that refers to itself at a
larger instance (`struct Nest<T> { inner : *Nest<Box<T>> }`) is
**W4243** — monomorphisation cannot terminate on it. Aliases of recursive
structs and regular generic recursion (`Link<T>` → `*Link<T>`) stay quiet.

**Commutativity analysis (`theory_crdt`).** Was a token counter: every
`+` was a "counter CRDT", every assignment "LWW", every call whose name
began with `add`/`ins`/`pus` an "op-set", joined into one meaningless
"final class" per file. Now it asks the CALM question properly — *what is
order-insensitive?* — at two granularities. **Statements**: each gets a
set of locations it reads and writes (`VAR(b)`, `HEAP(b)` = memory
reachable through binder `b`, `WORLD`); calls consult `NF_PURE_FN` from
`theory_quals` (a pure call only reads its arguments, anything else
touches `WORLD`), `return`/`break`/`continue`/`perform`/`handle` are
barriers. Within a block the RAW/WAR/WAW relation gives a dependence DAG,
its longest chain the critical path; a statement that does not conflict
with its predecessor is flagged **`NF_INDEPENDENT`** (it may be swapped or
hoisted without re-deriving alias facts). **Loops**: every local written
in the body is classified by *how* — `x = x ± e`/`x += e` counter,
`x = x * e` product, `x |= e`/`x &= e` join, `if e > x then x = e` max/min
register, plain `x = e` last-writer-wins register — and by whether its
intermediate value is observed elsewhere (the condition included: an
accumulator steering the trip count is a dependence through control).
Updates of one variable must all lie in the *same* monoid: `h ^= b; h *= P`
(FNV) is *mixed*, not a fold. A loop whose written locals are all
commutative accumulators (plus induction variables stepping by a
constant) and whose body has no heap/world write or barrier is a
**commutative reduction**: flagged **`NF_REDUCTION`** for the backend and
reported under `--lint` as **N4230** with the accumulator list (26 real
ones in the stdlib: `stats.pie` sums/min/max, `blas.pie` dot products,
`subtle.pie` constant-time compare, …). **N4231** names the single plain
assignment that pins an otherwise commutative loop (`last = a[i]`). Order
of passes: after `theory_quals`.

**Qualifier inference (`theory_quals`).** Carried a "qualifier word"
through a walk and cleared PURE on any assignment or call; every call was
opaque, parameters were never examined, nothing was reported. Now a
whole-program **greatest-fixpoint** over the call graph derives, per
function, the *reasons* it is not pure — writes outside its frame, reads
of a `static`, writes through a parameter (per parameter), effects/system
operations, allocation, unknown (extern/indirect) callee, impure callee,
loops, recursion — each remembered with the node that first caused it.
Callee facts flow to callers (a function that only calls `bump` inherits
`bump`'s write to the pointer it passes along); recursion does not break
purity (optimistic start, facts only grow). Parameters are tracked as
*written* (directly, through field/index/deref, `&mut`, or via a callee
that writes that position) and *escaping* (returned, stored, captured,
passed to an unknown callee). Classes: PURE (referentially transparent),
READONLY (reads statics), ALLOC, IMPURE, each ± may-diverge. Writeback:
**`NF_PURE_FN`** on PURE/READONLY functions and **`NF_READONLY_PARAM`** on
every binder of a parameter position that is neither written nor
retained — exactly LLVM's `readnone`/`readonly` and `noalias readonly`.
Diagnostics: **W4220** a statement-position call to a pure function (the
result is discarded, so the call does nothing — it found a real no-op in
`stdlib/effect_async/uring_handler.pie` and three in the test corpus),
**W4221** a `mut`/`&mut` parameter never written, **N4222**/**N4223**
(`--lint`) pure function / read-only pointer parameter. Bodiless
`#extern` declarations are foreign, never pure. Also fixed: the pipeline
allocated `QualAnalysis` (and SymState/SessionCheck/SctState) with
hard-coded byte counts; they now use the types' sizes.

**Match compilation (`theory_matching`).** Built a one-column matrix per
`match`, picked the first non-wildcard column, turned or-patterns into
wildcards, ignored guards, ranges, enum signatures and function clauses,
and called a tree "exhaustive" whenever its root was not a Fail node. Now
it is the match compiler: every `match` and every multi-clause function is
compiled to a Maranget decision DAG over *occurrences* (`x`, `x.0`,
`x.1.2`) with the f→b→a column heuristic, or-patterns expanded into rows,
guards as leaves with a fallthrough tree, and constructor signatures
(bool; enum variants looked up from the declarations, so a switch over
every variant has no default; tuple/struct as a single UNPACK step).
Nodes are hash-consed per site, so identical subtrees are emitted once
(the classic blow-up of decision trees becomes sharing). Each DAG is then
**verified**: a sample value per row (wildcards filled with a constructor
of the right type when the matrix reveals one) plus a "none of the above"
value are run through the DAG and through a naive first-match interpreter
over the original rows; disagreements are reported as compiler bugs. This
check caught two real defects during development (a 256-case cap that
silently dropped cases, and ill-typed samples). Writeback:
**`NF_DENSE_SWITCH`** (new flag) on a site whose root test is an int/enum
switch with ≥ 4 cases spanning ≤ 2× their count — emit a jump table;
**N4210** under `--lint`. `--emit-dtree` prints every DAG. Exhaustiveness
and unreachable arms stay with `theory_pglcert` (W4090/W4091).

**CPS translation (`theory_cps`).** Counted call sites and called the count
"administrative redexes avoided"; nothing was translated. Now every
function is translated by the Danvy–Filinski one-pass call-by-value CPS
into a small continuation IR (Kennedy's normal form: applications carry a
continuation variable or an inline `λx.`, `letk` for continuations, `letf`
for local functions, `if`/`case`). Branches in tail position go straight to
the current continuation; in value position they get a `letk` join point —
the one-pass discipline means no administrative redex is ever built. Loops
are continuations (`letk loop(_) = … loop(()) …`), `break`/`continue`/
`return` are jumps, `and`/`or` are branches, `perform`/`resume` are
applications of the operation with the current continuation. On the built
term: **tail-call verdicts** (a call is a tail call iff its CPS form passes
`k_ret`; each such `N_EXPR_CALL` gets `NF_TAIL` — the parser's bit for an
explicit `tail` — so the backend may release the frame), **W4200** an
explicit `tail` on a call whose value flows into an enclosing expression or
sits under a `handle` prompt (the flag is also cleared so the backend is
not lied to), **N4201** (`--lint`) unannotated self tail call, **η/β
contraction** of joins (single-use join inlined, `letk j(x) = k(x)`
eliminated, dead joins dropped — counted as term mutations), and
**contification**: a `letf` never used as a value and always called with
the same continuation variable becomes a jump target (`letj`, **N4203**
under `--lint`). Per function the largest continuation (values live across
a call) is measured. `--emit-cps` prints every term after contraction; the
pass runs before NbE so it sees source lambdas. Corpus: 0 W4200, no
crashes over stdlib/tests/conformance/examples.

**Closure analysis (`theory_defun`).** Compared free variables by *name*
(an inner `n` shadowing an outer `n` counted as a capture) and reported
"0 lambdas escape" for a lambda that was returned. Now free variables are
computed by binder identity, and every lambda is classified by where its
value goes — returned, passed to a call, stored into an aggregate or
through a pointer, captured by another closure (resolved transitively), or
only ever called directly; a `let f = fn …` inherits the fate of `f`'s
uses. Two facts are written back to the AST for the rest of the pipeline:
**`NF_NOESCAPE`** (new flag) on lambdas that never leave their function —
the ones NbE's β may inline and the backend may lambda-lift — and
**`NF_ADDR_TAKEN`** on a `let mut` captured by an *escaping* closure: the
variable is shared mutable state that outlives its frame (closures read
the variable, not a snapshot — that is the semantics NbE already
implements), so it must be boxed, and the flag is exactly what liveness,
dead-store elimination and alloca placement already honour for `&x`.
Diagnostics: **W4190** an escaping closure writes to a captured `let mut`
(note under `--lint` when it only reads it); **N4191** a captured variable
is reassigned after the closure is created and before it is used ("the
closure will see this new value"); **N4192** (`--lint`) non-escaping,
called once — inline candidate; **W4193** a let-bound or immediately
applied lambda called with the wrong number of arguments (both `fn (x: T)`
and clause-style `fn | (x, y) ->` forms); **W4194** a let-bound lambda
never used. The pass runs *before* NbE so it sees the source lambdas;
NbE then removes the non-escaping ones. Corpus: clean.

**Handler discipline (`theory_effcont`).** Counted "frames" and "fuses"
on a continuation stack that nothing consulted. `theory_effects` already
checks each handler's coverage (W4070–72); what was missing is the
perform and resume sites. The pass now walks each function with a lexical
model of the delimited-continuation stack: the computation of a `handle`
runs under a prompt naming the ops its arms catch; an arm's own body runs
*outside* that prompt (deep-handler semantics — only the continuation is
re-handled); a lambda body is a fresh frame. A `perform` not caught by an
enclosing prompt must be in the function's *written* row — **W4180**
"`Ask.ask` is performed here but … the row of `forgets` (`! [IO]`) does
not list `Ask`" — and a call carries its callee's row (**W4181**).
Unannotated functions are not nagged (rows are inferred elsewhere).
Inside arms `resume(v)` (or an explicit continuation binder `| E.op x k ->
k v`) is counted along every path: exactly once and in tail position on
every path is **tail-resumptive** (Leijen) — `NF_TAIL` is set on the arm
so the backend can run it as a plain function without capturing a
continuation (N4187 under `--lint`); ≥ 2 on a path or inside a loop is
**multi-shot** (N4182); no resume at all is an abort arm; `resume` outside
any arm is **W4183**, and inside a closure or the binder used as a value
is **W4184** (the continuation escapes). An arm for an effect the handled
computation provably cannot perform is dead (**N4185**), and an arm binding
the wrong number of payload values is **W4186**. This round also fixed the
parser: `op ask : …` produced a phantom operation named `op` in every
effect, which made every handler "incomplete" (W4072) and every second
effect a shadowing binding (W3010). The stdlib and corpus are clean; 27
tail-resumptive arms are proved across the corpus.

**Ownership / linearity (`theory_linearity`).** Counted identifier uses
by name and guessed "moves" from function-name prefixes (`take_`, `free_`),
which never matched anything. Pride has one resource that is linear by
construction — the block returned by `alloc` must be `free`d exactly once
on every path and never touched after — so the pass is now a flow-sensitive
ownership analysis, per function in statement order: every `alloc` is a
resource, `let q = p` / `p = q` alias it, states go LIVE → FREED / ESCAPED
(returned, stored into an aggregate, passed to a call, `&`-borrowed,
captured by a lambda), and paths that disagree join to MAYBE-FREED
remembering which branch freed it. `defer free p` releases at scope exit;
loop bodies are analysed twice so a `free` of an outer block is caught on
the second iteration. **W4160** double free ("already freed at 19:7", or
"and again by the `defer` at 63:7"), **W4161** use after free (through
aliases and for parameters too), **W4162** leak at scope end / `return`,
**W4166** an owning binder reassigned while it still owns, and notes
**N4163/N4164/N4165** for the path-dependent versions ("freed only when
the `if` at 33:7 takes its then branch"). Ownership through struct fields
and across calls is not claimed. The stdlib is clean; the two corpus hits
(`tests/exec/03_primes_sieve.pie`, `04_dynamic_alloc.pie`) are real leaks.
The multiplicity census (unused/once/multi) is kept for the optimiser.

**Size-change termination (`theory_sct`).** Matched arguments to
parameters *by position and name* and called `n - 1` a descent; it found 0
call graphs on any input. Now, per Lee/Jones/Ben-Amram: a call-site graph
relates each callee argument to the caller parameter it descends from, the
graphs are composed to a closure over the whole call graph (mutual
recursion included), and the function terminates iff every idempotent
self-loop has a strict self-edge. What counts as "smaller" is the honest
part: a binder bound *inside* a pattern that matched a parameter
(`Cons(_, t)`, a match arm, `let (a, b) = p`) is a well-founded structural
descent; an integer `n - k` is a descent **only under a lower bound** from
an enclosing guard (`if n <= 0 return …`, `while n > 0`, a literal arm),
`n / k` and `n >> k` need `n ≥ 1`, and an ascending `lo + 1` needs an upper
bound (`lo < hi` with `hi` passed on unchanged). Identifiers count only if
they *resolve* to the parameter's binder, and a binder that is assigned or
`&mut`-borrowed anywhere is never trusted. Verdicts: **W4150** a self-call
passing every parameter unchanged under no guard that could differ next
time ("once reached, the recursion never terminates"); **N4152** "not
proved terminating" with the reason — unbounded decrement (with the guard
to add), arguments rearranged but none decreasing, or nothing decreasing;
**N4151** the proof, under `--lint` only. `fact : | 0 -> 1 | n -> n *
fact(n - 1)` is correctly *not* proved: `fact(-1)` never returns.

**UB lattice (`theory_ub`).** Tagged every node DEF/POISON/UB and never
reported anything — and since identifiers were never tracked, poison could
not reach a use. Spec §14 says `poison` is a value that is UB *if used*, so
that is what the pass now checks, per function in statement order: `poison`
and shifts by ≥ the operand width (`1i8 << 8`) are sources; arithmetic,
casts and `let`/assignment carry it (mutable bindings are re-tagged by
later assignments, in order); the **use** — branch or loop condition, match
scrutinee, dereference, index, call argument, return value, divisor, value
stored to memory, assert/assume — is the diagnostic point: **W4140** "poison
is used here (as a branch condition): undefined behaviour; it came from
`poison` at 7:17 via `q`". **W4141** names the shift and the width, and
**N4142** counts the statements after `ub!`/`unreachable` (through `unsafe`)
that can never run. No interprocedural or memory tracking: a call result
and a load are DEF. Silent on the stdlib.

**E-class analyses (`theory_eclass`).** The file used to hash AST node
pointers into pretend classes and feed those to a lattice; it never touched
the e-graph. It is now egg §4 on the real graph: a constant lattice per
e-class, computed when an e-node is added (`make`: a literal, or an operator
whose child classes are all constant — δ inside the graph), joined when
classes merge (`join`), and re-propagated after congruence repair
(`modify`), which also *materialises* the literal e-node in every constant
class so extraction — which minimises cost — picks the literal. Two
different constants in one class is the graph proving `1 = 0`: it can only
come from an unsound rule set (`a * 0 ↦ a`), and it is reported at the
`|>*` site as **W4034** (error under `--strict-types`) with the two values;
the site then keeps the destructive result instead of extracting garbage.

The `|>*` site was also changed to saturate from the **original subject**,
with the TRS normal form added as one more member of the root class,
rather than from the TRS answer. That is what gives the graph something to
do: under `a + b ↦ b + a; (a + b) + c ↦ a + (b + c)` the TRS cannot
normalise `(x + 2) + 3`; saturation reaches `x + (2 + 3)`, the analysis
folds the inner class to 5, and extraction returns `x + 5` (cost 9 → 5).

**Normalisation by evaluation (`theory_nbe`).** The file used to say
"counting & demo only" in its header and ran an SKI toy on a private AST.
It is now a normaliser for the language's λ-fragment: `eval` maps syntax to
values — literals, closures ⟨λ, env⟩, and *neutrals* (syntax that cannot
reduce, normalised underneath) — and `reify` reads values back. A
`let f = fn (…) { … }` that is immutable, not `&`-taken and not recursive
puts a closure in the environment for the statements after it; every
application of a closure with matching arity is a β. Higher-order chains
reduce all the way (`add(inc(1), twice(inc)) + k` → `7 + k`), and
lambda-lets with no remaining uses are deleted.

Soundness is the whole point, and it is specific: (1) substitution is by
binder pointer, and the lambda body is cloned with **fresh binders** per β,
so two inlinings never share a `let`; (2) before a β, every free
identifier of every value that will land at the call site is checked
against the call site's scope — if a `let n` between definition and use
would capture the lambda's `n`, the β is **refused** and counted; (3) only
*values* (literals, lambdas, identifiers of immutable bindings) are
substituted for parameters; anything else — a call, a read of a `mut`
binding — becomes `let p = arg` in front of the body, evaluated once and in
argument order, so `dbl(read())` reads once and `sub(emit(1), emit(2))`
emits in order; (4) `mut` bindings are never values; (5) δ (literal
arithmetic, `if` on a literal) fires only on redexes that β *created* —
source-level `1 > 100` is left to constfold and the optimizer so their
counts stay honest; (6) fuel of 2048 β per function. On the stdlib, which
has almost no lambdas, it makes a handful of δ-steps and nothing else.

**Symbolic execution (`theory_symexe`).** Runs each function over symbolic
parameters, forking at `if`/`match`/`while` and carrying the path condition.
Every construct maps a *set* of live paths to a set (an `if` doubles it, a
returning arm removes members), so both sides of a branch continue to the
end of the function. Feasibility is decided by a small procedure that is
sound for pruning: per path, each variable has an interval and a set of
excluded constants, refined to a fixpoint from the atoms (`x > 5` raises
the low bound; `x != 0` excludes; `x + 2 < 7` shifts), then every atom is
re-evaluated under the facts and a FALSE one kills the path. Infinite
endpoints never decide anything, and constants beyond 2⁶² are treated as
unknown, so saturation cannot manufacture a contradiction. Loops run one
iteration under the guard, then havoc everything the body assigns and
assume `¬guard` only if the body has no `break`. Calls, field/index writes
and anything unmodelled are havoc: unknown never means zero.

It reports three things, all with the path condition printed as witness
and only when the path is feasible and the fact is definite: **W4055**
division/modulo by a divisor that is exactly 0 on that path (`a % z` after
`if a == 0 { return }` → "when a != 0"); **N4056** a branch condition
decided the same way on *every* path reaching it by the path facts (never
by constants alone — that is narrow's — and never inside a loop iteration,
where iteration-1 facts prove nothing); **W4057** an assertion that is
false on a feasible path. Bounds: 64 paths per function, depth 64, 64 atoms
per path; a bound ends a path, it never trades soundness for coverage. On
the 260-module stdlib it says nothing at all, which is the correct answer
for that corpus, and the noise-floor test pins that.

Writing this exposed the same class of bug in the two older flow analyses,
now fixed: `pfront_narrow` kept then-branch facts visible while deriving
the else branch (so `if x > 5 … else …` "contradicted" itself — ~750 false
W4120 on the stdlib), compacted its fact array on assignment kills (which
shifted facts under the scope marks of enclosing `if`s), and assumed
`¬guard` after every `while` regardless of `break`. `theory_absint` never
narrowed the state by a branch condition, joined a `return`ing branch as
if it fell through, dropped `break` states from the loop exit, decided
"always false" on iteration 1 before the fixpoint, widened straight to ±∞
(losing `x ≥ 1` in every Newton loop), and wrapped `-INT64_MIN` in
`iv_sub` so `top - top` became the point `[-∞, -∞]`. It now narrows on
`if`/`while` guards (`!= 0` goes through the sign lattice), treats
`return`/`break`/`continue` as unreachable-after with proper accumulators,
widens with thresholds {-1, 0, 1}, reports verdicts only in a final pass
from the fixpoint, and only calls a cast "may not fit" on a *finite*
out-of-range endpoint.

**Partial evaluation (`theory_stage`).** Staging is only useful if stage-0 code
actually runs. Binding-time analysis classifies each expression static or
dynamic — conservatively, since refusing to evaluate is always safe and the
reverse is not. Specialising `power(n,x)` at `n=3` unrolls to `x*(x*(x*1))`.
The interpreter is fuel-bounded, so a divergent stage-0 program is a diagnostic
rather than a hung compiler.

**Row inference (`theory_rowinfer`).** Effect signatures need not be written.
The (HANDLE) rule is what makes the system worth having: handling an effect
*removes* it from the row, so `main` can be pure though its callees perform
State and IO. Generalisation uses levels — quantifying a variable shared with
an enclosing scope is the classic unsoundness this prevents.

**Bidirectional CMTT (`theory_bidi`).** A quotation's type cannot be
synthesised in general: `<x + y>` could be `□(i64)` or `□(f64)`. Checking mode
pushes the expectation inward. (SUB) is the only non-syntax-directed rule,
which keeps everything else deterministic.

**IRDL traits (`theory_irdlverify`).** A dialect author writes
`opcode gadd : Pure, Commutative` and gets verification plus canonicalisation
opportunities. Dominance uses Cooper-Harvey-Kennedy over the region's block
graph — a use not dominated by its definition reads uninitialised memory on
some path.

**PGL certificates (`theory_pglcert`).** "Not exhaustive" sends the reader
hunting; "does not handle `Some(None)`" does not. The witness search is a
constructive reading of Maranget's usefulness algorithm. Proving a match
*is* exhaustive is recorded too, so the backend can omit the fallback branch.

**Semantic subtyping (`theory_subtype`).** `A <: B` iff `⟦A ∩ ¬B⟧ = ∅`, decided
on a DNF. That reduction makes distributivity, De Morgan, and `A ∩ ¬A <: ⊥`
fall out automatically instead of being special-cased. Arrows are handled
conservatively — a false negative rejects a valid program with a clear message,
a false positive miscompiles.

---

## 3. Verified behaviour

```
$ bash pfront_tests/run.sh
pfront regression: pass=100 fail=0
stdlib self-clean: 258 / 258   (baseline before rewrite: 4)
```

| Test | Asserts |
|---|---|
| `26_effects_perform` | effect decl + `perform E.op()` registers 2 ops |
| `27_ub_outside_unsafe` | `ub!` outside `unsafe` → E3230 |
| `28_stage_escape` | cross-stage reference → E3202 |
| `29_splice_stage0` | splice with no quotation → E3201 |
| `30_gradual_sort` | calling a non-function → W4060 |
| `31_trs_rule` | rewrite block collects and fires |
| `32_irdl_dialect` | dialect + opcode registers |
| `33_comptime_let` | `let x = comptime 3*4` evaluates *(found a real parser bug)* |
| `34_exhaustive_witness` | missing variant → warning naming the witness |
| `35_egraph_rewrite` | e-graph builds classes and saturates |
| `82_symexe_paths` + `symexe_paths` | W4055/W4057/N4056 with witnesses; silence on pruned paths, after `break` loops, after rejoins; narrow/absint no longer flag `if/else` or `10 / a` after `if a == 0 { return }` |
| `83_nbe_normalise` + `nbe_normalise` | β/δ/η shapes; `read()` bound once; `emit(1)` before `emit(2)`; capture refused (counted); `mut` never inlined; escaping closure materialised with its capture |
| `84_eclass_analysis` + `eclass_analysis` | `x + 5` from saturation + an analysis fold (not the TRS); unsound set → W4034 with both constants |
| `95_mu` + `mu` | IntList ≡ IntList2 (N4251) while BoolList / IntSeq are not; Stream W4250; Chain / Server quiet; memo hits > 0 |
| `94_strata` + `strata` | E4240 ×3 (self + mutual alias cycles, plus fuzz `type T = T`), NF_RECURSIVE_TY on Tree/Link, N4241 variant recursion, N4242 negative occurrence, W4243 `Nest<Box<T>>`; Box / TreeRef / Link quiet |
| `93_commute` + `commute` | sum+max loop flagged NF_REDUCTION + N4230, `last =` N4231, FNV mixed monoids, impure call / heap write / control-carried accumulator stay ordered, NF_INDEPENDENT on an independent `let` |
| `92_quals` + `quals` | interprocedural purity (bump → bump_twice), recursive fn pure, NF_PURE_FN / NF_READONLY_PARAM in the dump, W4220 ×2, N4223, externs/alloc/effects never pure |
| `91_matching` + `dtree` | complete enum switch (no default), two-column DAG sharing (16→13), dense jump table + N4210, or-expanded rows, guard fallthrough leaf, nested occurrence `x.0.0`, 0 tree/first-match disagreements |
| `90_cps` + `cps` | self tail → loop, W4200 misuse, contified join (`letj`), while as `letk`, inline continuation for a non-tail call, escaping lambda stays `letf`, contraction census |
| `89_closures` + `closures` | inline candidate, boxed mutable capture (returned), stale capture, lambda arity, escape/capture census; immutable-capture-as-argument and shadowing quiet |
| `88_handlers` + `handlers` | undeclared perform, call leak, tail-resumptive, multi-shot (sequential and loop), dead arm, stray and escaping resume, arm arity; declared/handled performs quiet |
| `87_ownership` + `ownership` | double free, UAF, one-path leak, full leak, alias, escape (quiet), defer+free, loop-carried double free, overwrite-while-owned, parameter UAF |
| `86_sct_termination` + `sct_termination`/`sct_quiet` | len/fib/ack/halve/ev-od proved; fact (unbounded) / swap (rotation) / shadow not proved; spin is a proved loop; proofs only under `--lint` |
| `85_ub_poison` + `ub_poison` | branch/call/store/lambda uses with origin + nearest binding; shift-by-width; re-tagged `mut` silent; arithmetic on poison silent; dead after `ub!` |
| `flow_noise_floor` | 0 × W4055/W4057/N4056/W4120 across the stdlib |

**A real parser bug fell out of this work.** `let x = comptime 3i64 * 4i64`
reported "not computable at compile time" while the same expression inline
succeeded. The cause was `parse_block_or_expr`'s virtual-block heuristic
absorbing the *following statement* into the comptime body. Inline `comptime`
now parses a single expression. Test 33 locks it in.

---
---


---

## 4. Pipeline order

24 passes. Order is load-bearing; the comments in `theory_check.c3` say why
each pass sits where it does. The shape:

```
 0  feature scan + convention audit     what constructs are even present
 1  register dialects / effects         must exist before any use is checked
 2  staging soundness                   BEFORE rewriting moves terms around
 2b CMTT judgment                       contexts, kinds, levels
 2c handler coverage + effect rows
 2d monomorphisation census
 2e bidirectional modal typing
 2f row inference
    ── snapshot taken here ──
 3  term rewriting to normal form
 3b comptime forcing + partial evaluation
 3c equality saturation                 order-independent, unlike 3
 4  dialect validation + lowering
 5  continuation-tree normalisation
 6  UB accounting
 7  gradual sort checking
 7b IRDL verification traits
 7c PGL certificates
 7d semantic subtyping / match refinement
 7e abstract interpretation             intervals, signs, nullness, branch narrowing
 7f normalisation by evaluation         β/δ/η on the λ-fragment (before the optimizer)
 7g symbolic execution                  feasible-path faults with witnesses
 7e′ LIVENESS + semi-pruned split       ← builds the CFG
 7f THE OPTIMIZER                       ← consumes everything above
 8  handler-arm linearity
 9  verify + snapshot diff              catches a bad rewrite at its source
```

Passes whose constructs are absent are skipped, so the report has no rows of
zeroes.

---
## 5. Parser integration

| Syntax | Node | Consumer |
|---|---|---|
| `quote e` / `~Tree e` | `N_EXPR_QUOTE` | msp, cmtt, bidi |
| `box[Γ] e at Stage L` | `N_EXPR_QUOTE` + env child + `p.aux` | cmtt, bidi |
| `splice e` | `N_EXPR_SPLICE` | msp, cmtt |
| `stage N { … }` | `N_EXPR_QUOTE` with level | msp, stage |
| `comptime e` | `N_EXPR_COMPTIME` | stage |
| `perform E.op(a)` | `N_EXPR_PERFORM` | modal, rowinfer |
| `resume(v)` | `N_EXPR_RESUME` | modal linearity |
| `rewrite name \| lhs -> rhs` | `N_DECL_FN` + clauses | trs, egraph |
| `pgen name where [p] ↦ a` | `N_DECL_FN` (`aux=2`) | irdl/PGL, pglcert |
| `dialect D / opcode o` | `N_DECL_INTERFACE` | irdl, irdlverify |
| `irdl D.op [a,b] ↦ act` | `N_DECL_INTERFACE` (`aux=3`) | irdl |
| `ub! "reason"` | `N_EXPR_UB` | modal UB |
| `A ∪ B`, `A ∩ B`, `¬A` | `N_TY_UNION/INTERSECT/NEGATION` | subtype |
| `! [IO, ..r]` | `N_TY_EFFECT_ROW` | rowinfer |

`perform` and `resume` are recognised **contextually**, so programs using
either as a variable still compile. Payload conventions (`p.aux` overloading)
are documented and enforced in `theory_bridge.c3`.

---

## 6. Honest limits

- **Symbolic execution is intra-procedural and linear-arithmetic only.**
  Calls, shifts, bit operations, fields and indexing are havoc; two
  variables are never related to each other (`x < y` is kept as an atom but
  only refines when one side has a known interval). It proves absence of
  nothing — it reports faults it can witness and stays silent otherwise.
- **Arrow subtyping is conservative.** The full set-theoretic decomposition is
  more involved; unproven cases answer "not a subtype", which rejects rather
  than miscompiles.
- **E-matching binds class representatives**, not full class enumeration. Some
  matches inside large classes are missed — sound, not complete.
- **Partial evaluation models no heap, pointers, or I/O.** Anything it cannot
  model stays dynamic.
- **Monomorphisation is a census**, not an instantiation: it records what the
  middle end will need without duplicating bodies.
- **Row inference does not yet feed the HM type inferencer**; the two run
  side by side rather than as one solver.
- **Liveness is intra-procedural.** A store to a variable captured by a
  closure, or reachable through a pointer, is conservatively kept.
- **CSE reports redundancy, it does not rewrite.** Introducing a temporary
  needs a scope to hold it; that is the middle end's job. The count is what
  the SSI builder will consume.
- **Block flattening never fires on the stdlib** (0 sites). It needs a folded
  branch to expose a spliceable block, and stdlib code has none. It fires on
  the regression cases, so it is tested, but its real-world value is unproven.
- **The optimizer removes ~0.3% of stdlib nodes.** Most stdlib code is
  declarations, and partial evaluation already folds static arithmetic before
  the optimizer sees it. On dynamic-value code the reduction is 50–96%.

---

## 7. Untyped-language policy — every demoted diagnostic

Section 0 states the rule. This is the complete list of what changed, so a
reviewer can check nothing was missed:

| Situation                                | Old behaviour        | Now                        |
|------------------------------------------|----------------------|----------------------------|
| assignment to a non-`mut` binding         | `E3330` hard error   | accepted; advisory only    |
| write through a non-`mut` pointer         | `E3332` hard error   | accepted; advisory only    |
| type mismatch                             | `E3100` under strict | advisory only              |
| wrong argument count                      | `E3102` under strict | advisory only              |
| unknown field                             | `E3104`/`E3353`      | advisory only              |
| index out of bounds on every path         | `E3360` hard error   | advisory + optimizer fact  |
| ambiguous overload / method               | `E3340`/`E3341`      | advisory; first match used |
| duplicate impl / missing interface method | `E3320`/`E3321`      | advisory only              |

Advisories are **off by default** and surface only under `--lint`, always as
warnings, never as errors. They route through a single chokepoint —
`DiagBag.advisory` / `DiagBag.advisory_hint` in `pfront_core.c3` — so it is
impossible to add a type-policing error by accident: you would have to call
`.error()` directly and the reviewer would see it.

**There is no borrow checker, no lifetime checker and no ownership analysis,
and none will be added.** A borrow/lifetime checker was on an earlier plan; it
was never written and the plan item has been withdrawn.

### So what are the analyses *for*?

Optimization. Every fact that used to justify a rejection now justifies a
transformation instead:

* interval analysis proves an index in range  → **bounds check elided**
* interval analysis proves it out of range    → **path marked unreachable**
* nullness proves a pointer non-null          → **null check elided**
* a decided condition                         → **branch folded away**

This is the same information with the opposite posture: the developer keeps
their program and the optimizer gets the benefit.

---

## 8. `theory_opt.c3` — the optimizer (1,663 LoC)

Runs as pass 7f, after every analysis (so it consumes their facts) and before
the verifier (so a bad rewrite is caught by the snapshot diff).

**Passes, each iterated to a fixpoint (max 8 rounds):**

1. **Constant folding** — integer/float arithmetic, comparison, logical,
   bitwise, and casts *with correct truncation* (`300 as u8` → `44`).
   Declines to fold `x/0` and `INT64_MIN / -1` rather than bake in a wrong
   value.
2. **Algebraic simplification** — `x+0`, `x*1`, `x*0`, `x-x`, `x^x`, `x&x`,
   `x|x`, `x&-1`, `x<<0`, `!!x`, `--x`, plus the comparison forms
   (`x==x` → `true`). Needs no constants, so it fires on dynamic values.
3. **Branch folding** — `if true`/`if false` collapse to the taken arm;
   `while false` is deleted entirely.
4. **Dead code elimination**, three distinct notions:
   * *unreachable* — statements after `return`/`break`/`ub!`/`trap`
   * *useless* — a pure expression in non-tail position whose value is dropped
   * *dead store* — a `let` nobody reads, **only if its initializer is pure**
5. **Copy propagation** — `let a = b` rewrites later `a` to `b`, killed
   correctly on any assignment to either side.
6. **CSE** — structural value numbering per block; reports redundancy for the
   SSI builder to consume.

### The purity interlock

`is_pure` answers *"definitely no side effects"* and is deliberately
conservative — calls, assignments, `perform`, asm, syscall, atomics, volatile,
alloc/free and deref all answer **false** and are never removed. Getting this
backwards would delete the user's I/O, which is the one unforgivable optimizer
bug.

Locked by test `44_opt_purity`, which asserts **exactly one** of two dead
stores is removed: the pure one goes, the one initialized by a function call
stays.

### Pass composition

Passes exist to feed each other; that is why the pipeline iterates to a
fixpoint (max 8 rounds). Test `48_opt_cascade` asserts the full chain:

```pride
fn f : i64 -> i64
  | n ->
      if 1i64 > 0i64      -- 1. condition folds to `true`
        return n          -- 2. branch folds to the then-arm
      let after = n * 2i64--    ...whose block is then FLATTENED into the parent
      after               -- 3. the spliced `return` makes these unreachable
```

Result: `(fn f (clause (pat-ident n) (block (return (ident n)))))` — 16 nodes
down to 7, **56%**, in three rounds. Asserting only the final node count would
pass even if one link in the chain broke, so the test checks each stage
individually.

### Measured on the real stdlib (253 files)

```
useless exprs   : 115      dead stores : 44
algebraic       :   9      const-fold  :  1 arith
branches folded :   1      unreachable :  0
blocks flattened:   0      files changed: 35 / 253
```

Total ≈170 transformations, 442 nodes removed of 125,481 (**0.3%**). That
number is unflattering and it is the honest one: most stdlib code is
declarations, and partial evaluation already folds static arithmetic before
this pass runs. On code with dynamic values the reduction is large — the
regression cases hit **50%**, **56%**, **61%**, and a 12,000-binding generated
file hits **96%**.

---

## 9. `theory_live.c3` — CFG, liveness, semi-pruned (1,029 LoC)

This is the **SP** of SP-ERM-e-SSI, and it is what makes the DCE above more
than a syntactic tidy-up.

### Why semi-pruned

Three classical φ-placement strategies:

| Strategy | φ count | Analysis cost |
|---|---|---|
| **Minimal** | φ at every iterated dominance frontier of every def | cheap, wasteful — most φs are for variables dead at the join |
| **Pruned** | φ only where the variable is live-in | minimal φs, but needs full liveness for every variable first |
| **Semi-pruned** | φ only for variables live **across a block boundary** | most of pruned's benefit, a fraction of the cost |

Briggs, Cooper, Harvey & Simpson (*Practical Improvements to the Construction
and Destruction of Static Single Assignment Form*, SP&E 1998) measured
semi-pruned as capturing most of the benefit for much less analysis. That is
the right trade for Pride: the front end runs on every keystroke in an editor;
the back end does not.

A variable used and killed inside one block can never need a φ, and
semi-pruned excludes it **without ever running full liveness**.

### What it computes

1. A **CFG** per function. Pride has no `goto`, so block structure is derived
   syntactically: `if` forks and rejoins, `while` gets a real back edge,
   `return`/`break`/`ub!`/`trap` terminate, `match` arms fan out to a join.
2. Per-block **GEN** (used before defined) and **KILL** (defined here) sets.
3. **LIVE-IN / LIVE-OUT** by backward iterative dataflow to a fixpoint:
   ```
   live_out[b] = ⋃ live_in[s]  for s ∈ succ(b)
   live_in[b]  = gen[b] ∪ (live_out[b] \ kill[b])
   ```
   Blocks are visited in reverse creation order — an approximation of reverse
   postorder, which converges in far fewer passes for a backward problem.
4. The **non-local set**: variables live across at least one edge. This is
   exactly the semi-pruned φ-placement set.
5. **Dead definitions**, fed to the optimizer.

Everything is a fixed-width bitset over a dense variable numbering, so the
dataflow inner loop is a word-at-a-time OR. `bs_count` uses Kernighan's
popcount (loops once per *set* bit).

### Correctness details that took care

- **Address-taken variables are conservatively non-local.** `&x` means the
  value can be read or written through the pointer anywhere, so it is
  recorded as both a use and a def.
- **`let x = <init>` records the init's uses BEFORE the binding exists.**
  Otherwise `let x = x` looks like a self-reference rather than a use of an
  outer `x`.
- **Compound assignment (`x += 1`) is a use *and* a def.**
- **`a.f = v` reads `a`** to find the location; only a bare identifier LHS is
  a pure def.

### Measured

On the real 253-module stdlib:

```
3,788 functions · 13,804 blocks
7,059 non-local (need φ) · 6,497 block-local
→ 47% of all variables need NO φ
0 capacity overflows
```

Contrast asserted by tests 46/47:

| Input | non-local | block-local | dataflow iters |
|---|---:|---:|---:|
| loop with carried `acc`, `i` | 3 | 1 | 3 |
| straight-line `a→b→c` | 0 | 4 | 1 |

`--dump-cfg` prints the graph:

```
b0 entry succ=[b1]      live_in=0 live_out=0
b1 block succ=[b2]      live_in=0 live_out=3
b2 loop  succ=[b3,b4]   live_in=3 live_out=3
b3 body  succ=[b2]      live_in=3 live_out=3   ← back edge
b4 join  succ=[]        live_in=2 live_out=0
```

### How the optimizer uses it

A store can be dead for two independent reasons. The **syntactic** one (no
identifier refers to the binder) is always available. The **liveness** one is
strictly stronger: a variable can be referenced textually and still be dead,
because every such reference is itself in dead code.

The optimizer only trusts liveness for variables classified **block-local** —
proving a non-local variable dead needs the interprocedural picture this pass
does not have. Liveness-driven removals are counted separately in the report.

---

## 10. `pfront_dump.c3` — final AST emitter (332 LoC)

`--dump-ast` shows the parse tree. `--emit-ast` / `--emit-sexp` show the
**final** tree, after rewriting, partial evaluation, e-graph extraction and
the optimizer — i.e. what the middle end will actually consume.

Annotations: resolution targets with node ids, effect rows, operator spelling,
literal values after folding, and a **`SYN` marker** distinguishing
compiler-synthesised nodes from source text.

`--emit-sexp` prints one S-expression per top-level declaration — stable and
diffable, which is what makes it usable as an optimization regression
baseline.
