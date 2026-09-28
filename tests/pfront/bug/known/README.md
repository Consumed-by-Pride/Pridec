# pfront bugs — reduced test cases

Files here are MINIMAL repro cases for pfront bugs. They're expected to fail
until the corresponding parser/resolver bug is fixed. Fix a bug by:
  1. Move the file out of `known/` (typically to `bug/fixed/` and add a
     numbered regression test like `70_xxx.pie` in `pfront_tests/`).
  2. Fix the bug in pfront/*.c3.
  3. Rebuild and confirm the new test passes AND all prior tests still pass.

## Current open bugs

### (none at the layout/parser level that block c89c growth)

The previously-open `layout_elseif_nest.pie` (nested `if/then/else-if/then`
chains swallowing sibling declarations) is now fixed in `Parser.parse_if()` —
see `pfront_tests/bug/fixed/layout_elseif_nest.pie` for the repro and a note
on the root cause. The `bug/min/` directory contains additional regression
cases (char-classify chains, deep-nest, let-init with inline if) that now
parse with all fns at top level.

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
