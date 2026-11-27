# pfront bugs — reduced test cases

This directory is reserved for MINIMAL repro cases of unresolved pfront bugs;
not every open issue has a repro checked in yet. Any repro placed here is
expected to fail until its corresponding bug is fixed. The current regression
runner enumerates numbered cases in `tests/pfront/` (not this directory), so
promote a fix by moving the repro to `bug/fixed/` and adding a numbered case
under `tests/pfront/`.

Status in this page is the current triage; older planning snapshots are in
`docs/dev/pfront_TODO.md` and may be stale.

Fix a bug by:
  1. Move the file out of `known/` (typically to `bug/fixed/`) and add a
     numbered regression test under `tests/pfront/`.
  2. Fix the bug in pfront/*.c3.
  3. Rebuild and confirm the new test passes AND all prior tests still pass.

## Current open bugs

### (none at the layout/parser level that block c89c growth — see below for
###  two parser defects fixed in 4550225, and the AIR defects still open)

The previously-open `layout_elseif_nest.pie` (nested `if/then/else-if/then`
chains swallowing sibling declarations) is now fixed in `Parser.parse_if()` —
see `tests/pfront/bug/fixed/layout_elseif_nest.pie` for the repro and a note
on the root cause. The `bug/min/` directory contains additional regression
cases (char-classify chains, deep-nest, let-init with inline if) that now
parse with all fns at top level.

## Open bugs found while running the first real binary

### Multi-continuation DEDENT ejects the following statement from its function

Repro: `tests/pfront/bug/known/multi_continuation_eject.pie`.

```
fn t : i64 -> i64
  | a ->
      let s = a
        + 1i64
        + 2i64
      s
```

`--emit-sexp` shows the body's block closed after the `let`, with `(ident s)`
sitting at top level beside `(fn t ...)`. The checker then reports
`error[E3005]: unresolved name` at the use site — the binder is inside the
function and the use is not.

The trigger is the DEDENT back to the enclosing block's indent, and it needs
TWO OR MORE continuation lines:

| continuation lines | closing stmt indent | result |
| --- | --- | --- |
| 1 | statement column | OK |
| 2+ | statement column | **BROKEN** |
| 2+ | continuation column | OK (lexer emits no layout token at all) |

Operator kind is irrelevant — `+`, `||`, and `as` all reproduce.

The `settle_continuation` / `end_stmt` / `skip_continuation_layout` trio
balances `cont_indents` one-for-one against absorbed INDENTs, which is correct
for a single continuation. With two or more, the `cont_indents` the block
parser later drains is what closes the block early, so the balance is
one DEDENT short. Reading the token stream is the next step; `pfrontc` has no
`--dump-tokens`, so a small lexer driver is needed first.

Not currently miscompiling anything: no file under `examples/tokei` uses this
shape (checked mechanically), and `x10_contextual_keywords.pie` was written to
avoid it. It is a trap for the next author, not a live regression.

Severity: silent tree corruption, but loud downstream (the ejected statement
almost always references a function-local name, so the checker fires). A
top-level-independent statement would be silently miscompiled.

## Open bugs in the AIR 2.2 artifact

### `airtool fmt` silently drops declarations and still exits 0

Severity: highest of anything found so far. `fmt` is documented and tested as a
fixed point ("parses and re-prints byte-identically"), and `tests/air/run.sh`
relies on it to canonicalise before `verify`. It is **lossy on large inputs and
reports success**.

Reproduction, from `examples/`:

    ../pfrontc tokei/languages.pie --emit-air --quiet   # 1.43 GB, 2516 defs
    ../tmp/airtool check tokei/languages.air            # rc=0
    ../tmp/airtool fmt   tokei/languages.air | grep -c '^def '   # 3

    8-def prefix of the same file: 8 in, 3 out, rc=0, no diagnostic.

`check` also returns 0 on the file it will truncate, so nothing in the pipeline
notices. `read_file` slurps the whole file (`fseek`/`ftell`/`fread(got)`), so
this is not a short read: the reader reaches a point where it stops emitting
decls while reporting no failure. Prime suspect is `AirModule.add_decl`, which
is a hard `AirDecl*[4096]` array that returns `false` past 4096 — but the 8-def
repro is far under that, so the drop is happening earlier, in the decl loop.

Not fixed yet: the toolchain to rebuild `pfrontc`/`airtool` is not available in
the current sandbox (see the note at the end of this file), so the fix could not
be written against a running binary.

### `--emit-air` wildcards struct patterns, leaving both arms and free variables

`x05_lowlevel_ub.pie` has the canonical struct pattern:

```
match p
  | { x: 0i64, y } -> y
  | { x, y } -> x + y
```

`--emit-air` on it (any build to `1c29d65`) writes:

```
match p {
  bind p ->
    <p | case {
      _ ->            <y | %ret_2>;          <- was `{ x: 0i64, y }`
      _ ->            <(add x y) | %ret_2>;  <- was `{ x, y }`
    }>;
};
```

Both arms became `_`, so the FIRST arm matches everything, and the bodies
reference `y`, `x`, `y` — names the pattern never bound. This is worse than
the or-pattern case: there the wildcard was at least the last-resort arm and
the bodies were self-contained; here the miscompile also drops the binders, so
the emitted function is not merely wrong but unverifiable — `air_verify` binds
nothing for `APAT_WILD`, so the uses are free variables.

The front end is innocent. `--emit-sexp` shows the correct tree,
`(pat-struct (pat-field x (pat-literal (int 0))) (pat-field y (pat-ident y)))`,
so the source binds `x` and `y` properly. The defect is `air_lower.c3`'s
`pat_node` only; `air_low.c3`'s `Low.pat` handles `N_PAT_STRUCT` correctly
(lines ~3920-3931: it resolves each field against the struct decl and recurses
into the field's sub-pattern). So `--emit-air` and `--emit-air-low` disagree
about the same program, and the high lowerer is the wrong one.

`pat_node` now REFUSES `N_PAT_STRUCT` (as of `4889f55`) rather than wildcarding
it, so no wrong `.air` is written. That is the right stopgap but it leaves the
2.2 path unable to express a construct the 3.0 path already lowers. The fix is
to port `Low.pat`'s struct case into `pat_node`.

Not expressible as `APAT_RECORD`: that constructor is name-only (`air_write.c3`
even flags a field with a payload as an error — `"record-pattern field with a
payload"`), so it cannot carry `x: 0i64`. A faithful `pat_node` has to test
each field with `APAT_INT`-style sub-patterns, exactly as `Low` does, or the IR
needs a record pattern that can hold sub-patterns.

None of the five files in the tree that use a struct pattern is consumed as
`.air` — they are all checked for *compile* success only — so refusing
regresses no gate.

### `--emit-air` loses parameter *names* and result types for non-binder clauses

CORRECTION. An earlier revision of this section claimed the 2.2 artifact emitted
"no parameters at all", which would have been an arity mismatch against a caller
passing one argument. That was wrong — it was a misread of `(_ : infer)`, which
is ONE parameter named `_`. The arity is correct. `(_, b) ->` likewise keeps two.

What is actually lost is narrower and much less severe:

| source | 2.2 emits | problem |
| --- | --- | --- |
| `\| x ->` | `(x : infer)` | none |
| `\| (a, b) ->` | `(a : infer, b : infer)` | none |
| `\| 0i64 ->` | `(_ : infer)` | name dropped, arity kept |
| `\| (0i64, b) ->` | `(_, b : infer)` | first name dropped |

The name is recovered by `node_text(p)` on the pattern; a literal head has no
text, so it falls back to `_`. Losing a parameter *name* in AIR is a readability
and debuggability loss, not a correctness one — AIR has no notion of parameter
names mattering to a caller.

The real defect in this area is the **result type**. `fn by_literal : i64 -> bool`
emits `: infer`, and so does `fn f : ptr -> (meta.Metadata, i64)`. That one is
deliberate and documented at the assignment site in `decl_fn`:

```
// Only the 64-bit integer results are adopted: PEAR 1 represents every value as
// i64, and giving it a narrower/ptr/bool/unit return type for a clause fn
// produces `ret i64` in an `i1`/`void` function. Other results stay `infer`
// until PEAR 2.
```

So `bool`→`infer` is a PEAR 1 limitation with a stated reason, not a bug, and
`infer` is a legal AIR type that `air_verify` accepts on purpose. Whether it
should be *silent* is a separate question; changing it needs a rebuild to verify
and risks the exact miscompile the comment warns about (`ret i64` in an `i1`
function), so it is left alone.

Net: no open correctness defect here. The 3.0 path additionally preserves names
and exact types (`pub def by_literal(a2 : i64) : bool`), so the two artifacts
still differ — but only in precision, not in meaning.

### `--emit-air` silently truncates a match at 64 arms

Found by running `--air-audit` over the checked-in corpus after fixing the
instrument's mark-unmark problem. `x09_torture_scale.pie` contains a 300-arm
function; the audit reported **437 of its 439 arms UNLOWERED**. The artifact
carries 64 arms and then the match simply ends:

```
def many_clauses(_ : infer) : i64 =   <- source: 300 arms
  mu~ %ret_2.
    match _ {
      0 -> <0 | %ret_2>;
      ...
      63 -> <63 | %ret_2>;
    };
```

There is no wildcard fallthrough, so `many_clauses(65)` matches nothing at all.
The floor is exact — 63 and 64 arms are fine, 65 loses one, 70 loses six:

| source arms | emitted |
| --- | --- |
| 63 | 63 |
| 64 | 64 |
| 65 | **64** |
| 70 | **64** |

Three arm loops had the shape `for (...; i < n.child_count && bc < 64; i++)`,
writing into `AirBranch bs[64]`. Arm 65 onwards was dropped in silence — no
diagnostic, no wildcard, no poison `ub`. Fixed by removing the cap from the loop
guard and refusing through `AirLower.too_many_arms` when a 65th alternative
arrives, using a named `AIR_ARM_CAP` so the limit appears once instead of as a
bare 64 in three places.

The same file has other `i < 64` loops (pattern sub-arrays, struct-literal field
inits, call arguments). Those are not reachable: the front end refuses a tuple or
struct literal past 64 elements first (`E1052: expected '}' to close struct
literal`), and a 65-element tuple *pattern* falls back to an explicit
`ub "multi-parameter clause requires tuple pattern matching..."` rather than
dropping elements. Only the arm arrays were both capped and reachable.

### `--emit-air` on a short-circuit chain: exponential in the chain length

> **CORRECTION.** This section used to say the 20.6 GB came from
> `--emit-air` writing the entire loaded stdlib. That was wrong. The stdlib
> baseline is a *flat* 551 KB / 16,410 lines, identical for every program.
> The growth was a continuation-sharing defect in the short-circuit lowering.
> The stdlib-scope issue is real but separate and is now described after this
> one. Both are measured; see the numbers below.

The trigger is `||` / `&&` chains. `examples/tokei/languages.pie` builds its
extension matcher exactly that way:

    fn extension_matches_0 : ptr -> bool
      | extension ->
          os.linux.strcmp(extension, "c" as ptr) == 0i32 ||
          os.linux.strcmp(extension, "h" as ptr) == 0i32 ||
          ... 97 terms ...

The old `shortcircuit_or` / `shortcircuit_and` passed the **same consumer `k`**
into both arms of the generated `if`:

    if a then <true | k>  else <b | k>

`k` is a shared node in the AIR graph. The AIR text format cannot express
sharing, so `air_write` inlines the node at every position that references it.
Because a chained operator's tail is itself another short-circuit, the tail is
printed once per path and the duplication doubles per level.

Measured with the supplied `pfrontc` (built from `4550225`, i.e. *before* the
fix) on `x == 1 || x == 2 || ... || x == n`:

| n | emitted lines in `f` |
|---|---|
| 2 | 10 |
| 3 | 18 |
| 4 | 34 |
| 5 | 66 |
| 6 | 130 |
| 7 | 258 |
| 8 | 514 |

That is `2^(n+1) + 2`. At n = 8 the single source term `x == 8` was printed
**64 times** in the artifact. Measured module sizes for the same construct:
`tokei.languages` alone emits **1,434,649,249 bytes** (12 modules); the whole of
`tokei/main.pie` is the 20.6 GB figure.

Things this is **not** — all checked and ruled out before the cause was found:
`mul64_hi` (constant 5,785 lines at every depth; a legitimate linear staircase),
the number of loaded modules, the number of `def`s (constant 60 on the synthetic
probe), and `if_`/`else if` chains themselves (a proper `else if` chain is
*linear*: 62 lines at depth 8, 230 at depth 32). Only the short-circuit
continuation duplicates.

#### Fixed

`AirLower.shortcircuit_join` mirrors the 3.0 reference, `Low.shortcircuit`, which
never had this bug: branch, send **both** arms to a join label carrying the bool
as a parameter, and run the consumer once inside the label body.

    label sc.join7(_b8 : bool).
      <_b8 | k>;
    seq {
      if a then  let _v1 = true  in jump sc.join7(_v1)
      else       <b | μ̃_x. jump sc.join7(_x)>
    }

Jump arguments are variable *names* (`air_mk_jump` takes `char**`), so the
constant is let-bound first — the 3.0 lowerer does the same. Each operand is now
lowered exactly once, which is what bounds the output.

`tests/air/test_shortcircuit_sharing.py` pins this: it asserts both operators
route through the helper, that the consumer is cut exactly once, that both arms
jump to the join, and that the label is sequenced *after* the branch. Two
mutations were used to confirm the test bites — restoring the old "cut `k` in the
short arm" shape fails 2 of 5 assertions; making `&&` skip the helper fails 1.

### `--emit-air` writes the entire loaded stdlib (separate, flat cost)

Independent of the above: `write_module` writes every decl in the module, and
`emit_air_program` lowers every loaded root. The implicit chain
`prelude -> mem -> os.linux -> os.linux.syscalls` is loaded for every program,
so even

    fn main : () -> i64 | () -> 0i64

emits 16,410 lines / 2,430 defs (`os.linux` 1786, syscalls 438, mem 168,
prelude 23) — 551 KB for a three-line program. This cost is **flat**: it does not
grow with the program, and it is not what produced 20.6 GB. Import isolation
confirms each module simply drags its own dependency closure: `os.linux` 551,683
bytes / 5 modules, `str.string` 620,529 / 9, `fs.file` 646,822 / 11.

`--emit-air-low` is reachability-filtered and emits 18 lines / 1 def for the same
program, so the filter exists — the 2.2 writer just does not apply it.

This also makes `make test-air` fail on `examples_tokei_languages` and
`examples_tokei_scanner`, because the large file is what trips the `fmt` bug
above.

#### The ENOSPC trap

Writing gigabytes **filled the sandbox disk**, and once full every subsequent
`--emit-air` produced a **0-byte `.air` while still reporting `errors=0`** — the
same "reports success, artifact is empty" shape as the `fmt` truncation. A write
that fails part-way is not distinguished from one that succeeded. Measured on a
disk with 845 MB free after cleanup: a 6-line input wrote 551 KB and reported
`errors=0`; with the disk full the same command wrote 0 bytes and still reported
`errors=0`.

So there are two defects in this section, not one:
1. unbounded whole-program output relative to the input (flat 551 KB baseline
   plus, before the fix above, exponential short-circuit expansion);
2. a failed/ENOSPC write is not reported, and leaves a partial or empty `.air`
   that the caller is told is fine.

A reachability filter, or at minimum a size guard that refuses rather than
writing gigabytes, is still needed.

## Fixed (this cycle)

Two parser defects, both found through `examples/tokei` and both silent — the
program still compiled, it just built the wrong tree:

1. **Metaprogramming keywords as names.** `quote`/`splice`/`unquote`/`reify`/
   `eval` were unconditional prefix operators in `parse_primary`. They are also
   in the contextual-name range, so `let quote = f(...)` bound and
   `quote.code` failed at the `.` with "expected an expression". Guarded with
   `pfront_meta_is_name` — same rule and reasoning as the existing `tail`
   disambiguation.
2. **Continuation INDENTs never balanced.** A line-continuation absorbed an
   `INDENT` without counting it, so the matching `DEDENT` was read by the block
   parser as end-of-block. Statements after a deeper-indented continuation were
   ejected from the function — visible in `--emit-sexp` as a top-level
   `(ident d)` beside `(fn f ...)`. Counted into `cont_indents`.

   **Partially fixed only.** The single-continuation case is fixed and is
   covered by `syntax_continuation_scope`. The same ejection still happens
   with two or more continuation lines — see
   `multi_continuation_eject.pie` above.

Regression: `tests/pfront/syntax/x10_contextual_keywords.pie` plus
`syntax_continuation_scope` in `tests/pfront/run.sh`, which asserts the tree
shape rather than the exit status (both defects parse "cleanly").

## Fixed (AIR 2.2 lowerer)

**5. Enum variants took their payload type's name.** `node_text` routed
`N_DECL_VARIANT` through the generic decl branch, which scans children for the
first ident/ty-name. A variant's own name is in `name_id`, not a child, and its
children are the payload types, so

    enum E
      | Point(i64, i64)

emitted `ctor \`i64\`(_0 : i64, _1 : i64)` while the match arm in the same file
still said `Point` — the type's declaration disagreeing with every use of it,
with `errors=0`. Bare variants (`| B`) were fine, which is why it survived.
Fixed by reading `name_id`; `N_DECL_FIELD` is covered by the same rule.

**6. Four hard caps dropped elements silently.** All four are fixed arrays whose
append helper returns `void` and just stops:

| construct | cap | what was lost |
|---|---|---|
| lambda parameters (`AirPrd.binders`) | 16 | the header, while the body kept the names — 45 free variables on a 70-param lambda |
| struct fields (`AirDecl.dtors`) | 64 | an 80-field struct emitted `op f0`..`op f63` |
| enum variants (`AirDecl.ctors`) | 64 | variants past the 64th |
| variant payload fields (`AirCtorDecl.fields`) | 64 | fields past the 64th |

Each now refuses via `note_bad`, so no `.air` is written. The function-declaration
parameter cap had already been fixed this way; `lambda_prd` had the identical
loop and was missed.

Worth noting the asymmetry that let these live: the AIR *reader* fails loudly on
every one of these caps ("more than 64 type arguments", …) while the *builder*
dropped silently.

**7. `type_ann` is not a child, and two readers forgot.** `fn`, `let`,
`type Name = T` and parameters store the annotation in `Node.type_ann`.

* `dump_sexp` printed `name_id` and children only, so **every type annotation in
  the program was invisible in `--emit-sexp`**: `fn f : i64 -> bool` printed as
  `(fn f (clause ...))`, and `type Age = i64` printed as `(type Age)`. The tree
  dump (`--emit-ast`) printed it correctly the whole time — that disagreement
  between the two dumps is what hid the bug. It misled me during this session: I
  read `(type Age)` as the parser dropping the alias target.
* `decl_type` read the alias target from `children[0]`, which is empty for an
  alias, so every `type Age = i64` emitted `declare Age() : infer;` with the
  target discarded and `errors=0`.

**8. The parser depth guard was unbalanced and reported a limit as a syntax
error.** On hitting `MAX_DEPTH` (400), `enter` returned without undoing its own
increment, and the follow-on diagnostic was

    error[E1001]: expression nests too deeply
    error[E1041]: expected ')' after expression

— the second sending the reader to look for a missing paren that is not missing.
The failure path now balances and enters the parser's existing panic state, so
only the real cause is reported. The limit itself was left alone: no file in
`examples/` or `stdlib/` comes near it. The neighbouring `DUMP_MAX_DEPTH` (200)
was checked too and prints an explicit `... (depth limit)` marker rather than
truncating silently.

**A note on test quality.** Writing the tests for the above exposed a hole in my
own method: assertions matched the fixes' explanatory *comments* as readily as
their code, so a mutation that deleted the code still passed. Tests now strip
comments before asserting, and the five earlier test files on this branch were
re-checked the same way (all pass with comments stripped, so they were checking
code).


**4. `add_decl` silently dropped declarations past a hard cap of 4096.** The
decl array is a fixed `AirDecl*[4096]`; `add_decl` returned `false` when full and
every caller ignored it, so a module over the cap would have been written short
while still reporting `errors=0` — the same shape as the `fmt` and ENOSPC bugs.
Nothing reaches the cap today (2,430 decls), which is exactly why it would have
gone unnoticed. The drop is now recorded on a sticky `AirModule.decl_overflow`
flag (cleared in `init`, since the struct is stack-allocated) and `write_module`
refuses to emit an overflowed module instead of publishing a body missing
declarations. Pinned by `tests/air/test_decl_cap.py` (4 assertions, both halves
mutation-checked).

**3. Short-circuit continuation was duplicated into both arms.** `&&` and `||`
passed the same consumer `k` to the then- and else-arm of the generated `if`.
The AIR text writer cannot express sharing, so the shared tail was inlined once
per path and the output grew as `2^(n+1) + 2` in the number of chained terms —
which is what turned 187 lines of `examples/tokei` into 20.6 GB. Fixed by
`AirLower.shortcircuit_join`, which routes both arms to a join label and runs the
consumer once, mirroring `Low.shortcircuit` in the 3.0 lowerer. Pinned by
`tests/air/test_shortcircuit_sharing.py` (5 assertions, mutation-checked). Full
measurements and the constructs that were ruled out first are in the section
above.

## Soft issues / warnings (not errors, workarounds exist)

* **`examples/effect_demo.pie` no longer compiles** (3 errors: two unknown type
  names, and `ub!` outside an `unsafe` block). The other two effect examples
  (`02_algebraic_effects_state_logger`, `03_hose_prompt_dynamic_wind`) compile
  clean and their handler lowering is compact (49 and 34 lines), so this is a
  stale example rather than a front-end defect. Left in place because deciding
  whether to fix or retire an example is not the front end's call.



1. `if cond then a; b` single-line multi-stmt then-branch misparse.
   Workaround: use indented block.
2. `let mut a=x; mut b=y` multi-let on one line.
   Workaround: one `let` per line.
3. W4120 "condition contradicts known" false positives on cascading
   else-if char comparisons (~60 warnings on lex.pie).
4. N3050 "cross-module use of non-pub" notes fire for every cross-module
   stdlib use (spam, not errors).
5. Megaload (import all 255 stdlib modules at once) still shows 14 errors
   — pre-existing, unrelated to the layout fix.

## Fixed bugs (repros in bug/fixed/)

- **layout_elseif_nest.pie** — fixed in pfront_parse.c3 parse_if().
  Root cause: two bugs in the `has_then` (inline-`then`) path:
    1. `p.eat_layout_run()` consumed a NEWLINE/INDENT/DEDENT run looking
       for `else` WITHOUT checking column boundaries, so after two
       adjacent outer else-if branches whose bodies were themselves
       inline `if/then/else-if/then` chains, the DEDENT that closed the
       enclosing block was eaten and the following top-level `fn` was
       absorbed as a nested child.
    2. `p.deferred_dedents = before_then;` clobbered deferred-D counts
       that inner recursive `parse_if` calls had legitimately recorded
       via `parse_indented_block`'s deferred_dedents path for inline-else.
  Fix: column-sensitive else-scan in the has_then branch that stops at
  DEDENTs landing at or above the `if`'s own column (unless immediately
  followed by `else`, which is the deferred-D signal); and removed the
  deferred_dedents clobber.

### cross-module resolution (no standalone repro yet)

Initially thought functions calling vec/stdlib helpers failed cross-module;
turned out to be the layout bug above causing functions to be nested-locals
(not exported). Once the layout bug is worked around, cross-module resolution
works. Keep this in mind if a "cross-module unresolved" bug reappears — first
check that the target function is a **top-level** decl via `--dump-ast | grep "^  fn '"`.
