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

## Open bugs found via examples/tokei

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

### `--emit-air` writes the entire loaded stdlib

`write_module` writes every decl in the module, and `emit_air_program` lowers
every loaded root. The implicit chain `prelude -> mem -> os.linux ->
os.linux.syscalls` is loaded for every program, so:

    fn main : () -> i64 | () -> 0i64
      -> 16410 lines, 2413 defs (os.linux 1786, syscalls 438, mem 168)

For `tokei/scanner.pie` (187 source lines) that is 1.1 GB; `languages.pie` is
1.43 GB. `--emit-air-low` is reachability-filtered and emits 18 lines for the
same program, so the filter exists — the 2.2 writer just does not apply it.
This also makes `make test-air` fail on `examples_tokei_languages` and
`examples_tokei_scanner`, because the huge file is what trips the `fmt` bug
above.

The whole-program scope is a deliberate choice (the comment in
`pfront_main.c3` argues the backend should see everything the native path
compiled) — but a 7-million-fold blowup on a 187-line input is not a scope
decision, it is an unbounded output. Reachability filtering, or at minimum a
size guard that refuses rather than writing gigabytes, is needed.

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

Regression: `tests/pfront/syntax/x10_contextual_keywords.pie` plus
`syntax_continuation_scope` in `tests/pfront/run.sh`, which asserts the tree
shape rather than the exit status (both defects parse "cleanly").

## Soft issues / warnings (not errors, workarounds exist)

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
