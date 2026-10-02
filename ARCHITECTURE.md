# Architecture

This document walks through Pridec's internals at the level a contributor
needs in order to add a language feature or fix a bug in a pass without
guessing where to hook in.

## End-to-end pipeline

Pridec is a **multi-pass compiler over a single tree type, `PNode`** (defined
in `pfront/pfront_core.c3`). Every pass takes a `PNode*` root and returns a
`PNode*` root (which may be the same pointer or a rewritten tree); all
passes share an `Arena` bump allocator and an `Interner` for strings. There
are no separate AST/HIR/MIR/SSA datatypes *before* AIR — the theory layer
does its work by mutating/rewriting the PNode tree in place. The first
time the tree is translated out of PNode form is at the very end, in the
AIR bridge.

```
  ┌─────────── file.pie bytes
  │
  ▼
pfront_lex.c3       token stream (line/col annotated)
  │
  ▼
pfront_parse.c3     naive PNode tree (kind/children/sptr/line/col)
  │
  ▼
pfront_resolve.c3   ModuleLoader + Resolver:
                    • follows `use`/`mod` declarations to load dependent files
                    • binds .resolved / .sym pointers on every identifier
                    • flags module-path prefix idents with NF_RESOLVED so they
                      don't count as "unresolved"
                    • attaches a SourceMap for snippet diagnostics
  │
  ▼
──────── front-end semantic analyses ────────
  pfront_ext        EffectPass, Linter, ExhaustCheck
  pfront_sema       ModuleGraph (SCC), VisibilityCheck, PatternAnalysis,
                    ConstEval, TypeCycleCheck
  pfront_types      TypeTable allocation
  pfront_infer      Hindley-Milner inference (opt-in; Pride is untyped by default)
  pfront_narrow     Coercion insertion
  pfront_check      Traits, access checks, coercion validation
  pfront_flow       CallGraph → reachability → recursion SCCs →
                    effect fixpoint → FlowAnalysis (intra-procedural CFG) →
                    dead-code detection
─────────────────────────────────────────────
  │
  ▼
theory_check.c3     TheoryPipeline (pfront/theory/), ~40 passes in a fixed
                    order over the PNode tree:
                      0.  feature scan + audit
                      1.  register IRDL dialects + effect ops; validate uses
                      2.  MSP stage check
                      2a. μ-types/coinductive subtyping, CMTT, IRDL-SSA,
                          effect continuations, e-classes, records, matching,
                          hereditary subs, UB, full effects, stratified types,
                          NBE, CRDTs, linearity, symbolic execution,
                          qualifiers, session types, size-change, defun
                          (lambda-lift), CPS
                      2b. CMTT contextual modal typing
                      2c. handler coverage + effect row inference
                      2d. monomorphisation census + polymorphism solving
                      2e. bidirectional modal typing (box types)
                      2f. principal-type effect rows
                      ── verifier snapshot ("before") ──
                      3.  PGL decision trees (BEFORE TRS touches patterns)
                      3a. rewrite VALUES (theory_rwsite): evaluate
                          rewrite/rule/++ bindings in scope; per set, once:
                          LPO termination + critical pairs → confluence
                          verdict; apply at `|>` (one pass) / `|>*` (normal
                          form, then e-graph extraction). Nothing else is
                          rewritten.
                      3b. comptime eval + partial evaluation/specialisation
                      4.  IRDL dialect lowering → core terms
                      5.  conttree build + normalise (scoped effects)
                      6.  explicit UB accounting
                      7.  gradual sort checking (Unknown/Scalar/Aggregate/
                          Pointer/Callable/Effectful/Never lattice)
                      7b. IRDL-SSA verification (dominance, purity, termination)
                      7c. PGL certificates (exhaustiveness w/ counterexample)
                      7d. set-theoretic subtyping (DNF emptiness) + match refine
                      7e. abstract interpretation (intervals/signs/nullness)
                      7e-bis. liveness (SP-ERM-e-SSI; phi-needed vs block-local)
                      7f. optimizer (constant fold, algebraic ids, branch
                          fold, three kinds of DCE) — fixpoint at opt level
                      8.  handler-arm linearity
                      9.  tree-shape verifier + "after" snapshot (diffs pin
                          corruption to the pass that caused it)
  │
  ▼  post-theory PNode* root  ← returned from tp.run(entry.ast)
  │
air_lower.c3        AirLower walks the tree and builds AirModule in AirArena:
                    • prd (producers): variables, literals, λ, μ, tuples, …
                    • cns (consumers): covariables, · (stack), fst/snd/[i]/.f,
                      case/cocase, μ̃, deref/store, ascription
                    • cmd (commands):  <p|e> cut, μα.c, μ̃x.c, SEQ, LET, IF,
                      MATCH, HANDLE, WHILE, FOR, BLOCK, JUMP, RET, BREAK,
                      CONTINUE, UB, TRAP, NOP, …
                    Key invariants:
                    • right-to-left μ̃ wrapping so subexpressions evaluate in
                      source order (no lr.nop() continuation-drop bug)
                    • return-covar stack: every fn/lambda/letconst pushes a
                      fresh %ret_N, return v cuts to current_ret()
                    • cmd_to_cns / block_to_cns bridge cmd-world (char* k)
                      to cns-world (AirCns* k) without inventing "*k*"
                    • seq_cmds drops nops and dead code after a terminal
                    • walk_decls/module_body drives the top-level walk;
                      N_USE→import, N_MODULE→module_decl, clause-syntax params
  │
  ▼
air_write.c3        THE `.air` printer (AIR 2.0, docs/specs/AIR.md): whole program,
                    canonical, lossless; air_text.c3 holds the shared vocabulary.
                    air_read.c3 is its strict parser (used by airtool, by
                    `--air-roundtrip`, and by every backend); air_verify.c3
                    checks the validity rules V1-V4. air_emit.c3 is the old
                    lossy pretty-printer kept as `--emit-air-pretty` (diagnostic).
  │
  ▼
  file.air  (AIR 2.0 text; THE interface; pfrontc ends here and links no LLVM)
  │
  ▼  a backend starts from the file and nowhere else
  ├─ legacy/pear1/pear1c   PEAR 1: .air → LLVM 23 → bitcode / native ELF (frozen;
  │                         the regression gate for the front end)
  └─ PEAR 2                 new backend, built against docs/pear2/ (contract, coverage)
```

## PNode, the universal tree

Every AST node is a `PNode` (see `pfront/pfront_core.c3`):

```c3
struct PNode {
    NodeKind kind;          // N_EXPR_INT, N_DECL_FN, N_STMT_RETURN, ...
    uint      name_id;      // interner id for the identifier/operator/type
    PNode*[]  children;     // variadic child array
    PNode*    parent;       // back-pointer
    PNode*    resolved;     // what an identifier resolves to
    void*     sym;          // symbol-table entry
    PNode*    type_ann;     // ascribed/inferred type (set by pfront_infer)
    NodePayload p;          // union: ival/sval/fval/sptr+slen/etc.
    ushort    line, col;    // 1-based source location
    ushort    flags;        // NF_PUB, NF_MUT, NF_RESOLVED, NF_TYPED, ...
}
```

Passes communicate by mutating `children`, `resolved`, `flags`, and
`type_ann`. There is no separate annotation side-table because the tree is
the IR all the way down to AIR.

## Arena + Interner

* `pfront_core::Arena` is a bump allocator (1 MiB slabs) with bulk destroy;
  all PNode storage lives here. It is *not* reset between passes — passes
  that rewrite the tree allocate new nodes alongside old ones.
* `pfront_core::Interner` is a global dedup table for all identifiers and
  string literals; `it.text(name_id)` returns a stable, NUL-terminated
  `char*` valid for the lifetime of the compilation. **Always prefer
  `it.text(n.name_id)` over `n.p.sptr`** — `sptr` points into the raw
  source buffer at a specific (slen) length and is not NUL-terminated;
  using it for composite nodes (arrows, clauses, generics) leaks source
  spans into identifiers.

## AirArena (AIR side)

The AIR bridge uses its own 1 MiB slab arena (`AirArena` in `air_ir.c3`),
separate from the PNode arena. After lowering, *all* IR nodes and their
string payloads live in this arena; freeing it frees the entire AIR
module. The IR never holds pointers back into the PNode tree or interner —
`air_node_text`/`air_types.c3` dups every string it needs.

## Adding a language feature

Roughly where to hook in:

* **New syntax** → `pfront_parse.c3` (add an `N_*` NodeKind if needed).
* **New name-binding form** → `pfront_resolve.c3`.
* **New type** → `pfront_types.c3`, `pfront_infer.c3`, plus a primitive
  sentinel in `AirModule.init` and a case in `air_typ`/`air_translate_typ`
  in `air_types.c3`.
* **New term-level construct** →
  1. Parser produces a node kind.
  2. Add a `case` in `AirLower.cmd` / `AirLower.prd` / `AirLower.expr_to_cns`
     depending on whether it's a statement, value, or evaluation-context
     form. Use `bind_x_then`/right-to-left μ̃ wrapping, not `lr.nop()`.
  3. If it introduces a binder, push/pop the scope and ret-stack as
     appropriate (see `decl_fn`/`lambda_prd`/`decl_letconst` for models).
  4. Add the printer case in `air_write.c3`, the parser case in `air_read.c3` (the round-trip test
     `pfrontc --air-roundtrip` fails until both carry every field), a row in `docs/specs/AIR.md`.
* **New analysis pass** → drop a new file under `pfront/` (pattern-match
  the NodeKind you care about; use `walk(n.children[i])` to recurse) and
  call it from `pfront_main.c3::compile_one` in the right spot, or, if it
  is a theory-level concern (e.g. another program logic), add it to
  `theory_check.c3::TheoryPipeline.run` in the correct order (most
  analyses go after stage-check and before the optimizer; most
  transformations go after the TRS).
* **New AIR syntactic form** → add a tag to `AirPrdTag`/`AirCnsTag`/
  `AirCmdTag`, a smart constructor in `air_ir.c3`, cases in lower +
  write + read, and document the form in `docs/specs/AIR.md`; a backend must refuse it until implemented
  (`docs/pear2/CONTRACT.md` §2).

## Invariants worth not breaking

1. **After resolution, every reachable `N_EXPR_IDENT` has either `.resolved`
   non-null, `.sym` non-null, or `NF_RESOLVED` set** (the last case is a
   module-path segment, not a value name). The Verifier in pfront_main.c3
   enforces this and reports counts.
2. **AIR output is stubless**: grep the output for `*k*`, `*dummy*`,
   `prd-unknown`, `cns-unknown`, `<()|·>` after every change; zero hits is
   the bar. These strings should not appear anywhere in pear_ir/*.
3. **Right-to-left μ̃ wrapping**: when lowering `f(a,b,c)` in a context `k`,
   first build `call_rest = <f|a·b·c·k>`, then wrap `c` as `<c|μ̃_xN.call_rest[b→_xN]>`,
   then `b` as `<b|μ̃_xM. …>`, then `a` as `<a|μ̃_xL. …>`. Never call
   `lr.nop()` to pad a μ̃ body — that drops continuations and turns args
   into nops.
4. **Return stack**: `return v` must cut to `scope.current_ret()`, NOT to
   the `k` parameter of `lr.cmd(n, k)`. The latter is whatever μ̃ is active
   at the statement site; using it gives non-local-return bugs.
5. **Terminals**: `is_terminal_cmd` must recognize every command that
   transfers control away (cuts to %ret*, jump, trap, break, continue, ub),
   recursing through SEQ/MU/BLOCK. `seq_cmds` relies on this to drop dead
   code.

## C3 language quirks (the compiler is written in C3)

See `pfront/pear_ir/README.md` for the full list. The ones that bite
most often:

* Structs end with `}`, NOT `};`.
* No comma-separated multi-pointer declarations: `T* a; T* b;` not `T* a, *b;`.
* Every `if/else` with both branches needs `{}` on BOTH branches.
* Methods use `.` not `->`; declared as `fn void Type.method(Type* self, …)`.
* No non-extern forward declarations — methods on the same struct are
  mutually visible; forward decl blocks produce "already defined" errors.
* Reserved words include `bool`, `it`, `mod`, `fn`, `var`, `cont`, `sz`,
  `alias`, `any`, `err`, `static` — don't use them as variable/field/
  parameter names.
* No implicit narrowing casts: write `(long)(x & 0xff)` for ulong→long.
* `extern fn …` declarations must live at file top, not inside a body.
* Method names may not collide with struct field names.
* No `byte`; use `char`.
* Switch cases fall through by default; every non-empty case must end with
  `return;`.
* Stack allocs >64KB are rejected; `T[0]` is disallowed.

## Legacy code

* `legacy/pride1/` is the previous monolithic compiler (module `pride`,
  `pride.c3` driver, lex→parse→typecheck→SSI/SASI→LLVM 22 codegen, ~26
  root-level `.c3` files). It is kept for reference only; it is not built
  by `make all`. Use `make legacy` to try building it (expects c3c 0.8.1
  at /tmp/c3/c3c and an LLVM 22 toolchain).
* `tests/legacy/c89c/` is a C89 subset written in Pride, kept as parser/
  layout regression inputs.
