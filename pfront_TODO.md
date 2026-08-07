# pfront hardening plan — target: production-quality front-end for 30–50 KLoC inputs

The c89c compiler (in c89c/) is the stress workload. Every time c89c grows, pfront
must continue to (1) parse, (2) resolve, (3) typecheck, (4) DCE / optimize the
AST **without crashing or mis-compiling**.

## Current baseline (2026-08-05 post-fix)
- pfront parses all 258 stdlib modules + pfront_tests regression suite clean.
- pfront regression: 124/125 pass (1 pre-existing megaload failure unchanged).
- stdlib self-clean: 253/254 modules.
- c89c is at **~2.3 KLoC** with all modules clean:
  - ast.pie    (443 LoC, 31 fns, 0 errors) — types, nodes, arenas, Sym/SymTab, intern, diags
  - lex.pie    (631 LoC, 29 fns, 0 errors) — full C89 lexer (kw, punct, str, char, num, ws)
  - parse.pie  (708 LoC, 44 fns, 0 errors) — recursive-descent parser (decls, stmts, exprs)
  - sema.pie   (394 LoC, 19 fns, 0 errors) — name resolution, type checking, Sym interaction
  - driver.pie ( 39 LoC,  4 fns, 0 errors) — lex+parse+sema wrappers
  - main.pie   (120 LoC,  6 fns, 0 errors) — driver: read file, lex+parse+sema, print stats
  - test/hello.c — tiny smoke test
- All 133 functions across c89c are verified TOP-LEVEL (not accidentally nested
  by layout bugs) via the regression script.

## Bugs found and fixed in c89c source (workarounds for pfront bugs)
The "cross-module resolver bug" from earlier was NOT actually a resolver issue —
it was a **pfront layout/parser bug** where nested `if ... then X else if ... then Y`
chains caused subsequent top-level `fn` declarations to be parsed as nested locals
(swallowed into the previous fn body), making them invisible to cross-module
import. Repro in `pfront_tests/bug/known/layout_elseif_nest.pie`.

Workaround applied: avoid two consecutive outer `else if` branches whose bodies are
inner `if/then/else-if/then` chains. Use indented-block form, helper functions
(`kw_checkN`, `is_assign_op`, `bp`, `hex_digit_val`), or early returns instead.

## Known pfront bugs (open)
1. **Layout parser: nested `then` chains swallow siblings** — repro in bug/known/.
   Trigger: outer fn has ≥3 `if / else if` branches where first two contain inner
   `if cond then X else if cond then Y` (single-line `then` form). Suspect the
   `deferred_dedents` / `stmt_indent` / `init_block_level` logic in
   `Parser.parse_if()` lines ~3170–3230 of pfront/pfront_parse.c3.
2. `if cond then a; b` single-line multi-stmt then-branch misparse.
3. `let mut a=x; mut b=y` multi-let on one line doesn't parse.
4. W4120 "condition contradicts known" false positives on cascading else-if
   chains over character ranges (60 warnings on lex.pie).
5. N3050 "cross-module use of non-pub" notes fire for every stdlib use (spam).

## Stress-workload roadmap (c89c)

Current milestone checkboxes:
- [x] 0.5 KLoC : lexer + partial parser working
- [x] 1 KLoC   : full keyword/punctuator lex, partial decl/stmt/expr parser
- [x] 2 KLoC   : reached 2.3 KLoC — for/do-while/break/continue/goto/labels,
      arrays, sizeof (type+expr), casts, ternary, comma op, postfix ++/--,
      struct/union/enum body parsing, initializer lists, multi-decl with comma,
      typedef, extern/static, semantic name resolution + type checking basics
      (sema.pie), all modules cross-module clean.
- [ ] 4 KLoC : preprocessor (`#define` macros, `#include`, `#ifdef`), full
      declarator grammar (function pointers), const/volatile qualifiers,
      bitfields, octal/hex/float literals wired into parser values, typedef
      name resolution in the parser (so identifiers are types when appropriate).
- [ ] 6 KLoC : Name resolution + type checking — bind identifiers, arity checks,
      struct field access, lvalue checks.
- [ ] 10 KLoC: Code generation (C-emitter first, then LLVM IR) — c89c becomes a
      real compiler that can compile hello.c to an executable.
- [ ] 15 KLoC: Self-hosting lexer — c89c lexes its own source.
- [ ] 20 KLoC: Self-hosting parser — c89c parses its own source into AST.
- [ ] 30 KLoC: Self-host end-to-end (c89c compiles itself).
- [ ] 40–50 KLoC: Hardening passes — DCE, goto-label resolution, UB detection,
      const eval, optimization of the AST, crash-fuzz the frontend.

## Growth strategy
1. Write code; avoid the nested-`then` layout-bug pattern; keep each fn small.
2. After each addition, run `bash scripts/c89c_pfront_regress.sh`.
3. If a new function appears nested (AST fn indent > 2 spaces), restructure the
   caller(s) to avoid the trigger pattern.
4. When a pfront crash/miscompile is found, add a MINIMAL repro to
   pfront_tests/bug/known/ with a comment describing the trigger.
5. Periodically take a stab at fixing the actual pfront bug — fix in
   pfront/pfront_parse.c3, rebuild with `c3c compile pfront/*.c3 pfront/theory/*.c3 -o pfrontc`,
   rerun regression.
