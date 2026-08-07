# pfront/pear_ir — AIR Bridge (pfront → λ̄μμ̃)

This directory implements the bridge between pfront's resolved/type-annotated
PNode AST and the Abstractive Intermediate Representation (AIR), a three-sorted
classical sequent calculus λ̄μμ̃ of Curien–Herbelin that serves as PEAR's input
language.

## Files

| File | Purpose |
|------|---------|
| `air.c3` | Public driver, `emit_air(root, it, path)` called from `pfront_main` when `--emit-air` is on. Allocates `AirArena`/`AirModule`/`AirScope`/`AirLower`, runs the lowerer, then calls the emitter. Also derives the `.air` sibling path from the input path. |
| `air_ir.c3` | All IR datatypes (`AirTyp`, `AirPat`, `AirPrd`, `AirCns`, `AirCmd`, `AirDecl`, `AirBinder`, `AirField`, `AirCtorDecl`, `AirDtorDecl`, `AirEffectOp`, `AirBranch`, `AirCoBranch`, `AirModule`, `AirArena`) and every smart constructor (`air_mk_cut`, `air_mk_call`, `air_mk_if`, `air_mk_case`, `air_mk_import`, …). Uses a simple bump allocator with 1 MiB slabs. Sentinels (`p_unit`, `p_true`, `p_false`, `p_null`, `c_ret`, `pat_wild`, `nop`) are preallocated in `AirModule.init`. |
| `air_scope.c3` | Name supply + lexical scope stack. Provides `fresh_x_var` (`_xN`), `fresh_k_covar` (`%kN`), `fresh_label` (`%exitN`, `%loopN`), `bind_var`/`bind_covar`/`lookup_*` with automatic `_N` shadow-suffixing, `enter/leave` scope frames, `push_loop/pop_loop/current_break/current_continue` for loop labels, and a **return stack** (`push_ret/pop_ret/current_ret`) so that `return` always cuts to the enclosing fn/lambda's `%ret` rather than whatever local μ̃ continuation is active. Also owns `destroy` (counter reset). |
| `air_types.c3` | `air_ty(m, t, it)` translates a PNode type annotation into an `AirTyp*`. Handles primitives (i8–u128, f16–f128, bool, char, str, bytes, isz, usz), ptr/ref/ref-mut, arrays/slices, tuples, fn arrows, named/generic types, unions/intersections, negation, forall/exists, effect rows, refinement, typeof. `air_node_text(m, n, it)` always dups text into the arena using `slen`, so AIR never retains raw non-NUL-terminated `sptr` pointers into source memory. |
| `air_lower.c3` | ~2.4k-line lowering engine. `AirLower` holds `mod`, `arena`, `scope`, `it` plus counters. Recursive methods: `prd`/`prd_or_bind` for values, `expr_to_cns` for the CPS workhorse, `cmd`/`stmts`/`block`/`letlike` for statements, `binop`/`unop`/`call`/`method_generic`/`if_`/`match_`/`loop_`/`tuple_lit`/`array_lit`/`struct_lit`/`field_acc`/`index_acc`/`perform`/`handle`/`marker_block`/`control_expr`/`msp_expr`/… for expression forms, and `decl_fn`/`decl_extern`/`decl_struct`/`decl_enum`/`decl_type`/`decl_letconst`/`decl_effect` for top-level forms. `walk_decls`/`module_body` drive everything. |
| `air_emit.c3` | IR-based text printer. `AirPrinter` walks an already-lowered `AirModule`, printing λ̄μμ̃ in stable, human-readable form with proper indentation, nop suppression, `let` detection for the `<e|μ̃x.c>` administrative-redex pattern, `call(…; k)` sugar instead of raw `a·b·c·k` stacks, and all 8 decl forms. |

## Calculus recap (3 sorts)

- **Producers** (`prd`, `p`, `v`) — terms producing values: variables, literals, pairs/arrays/records, sums (`inl`/`inr`), lambdas `λ(xs).c`, μ-binders `μα.c`, binary/unary ops, sizeof/alignof, coerce, poison, unreachable, msp primitives. Left of a cut.
- **Consumers** (`cns`, `e`, `k`) — evaluation contexts/continuation stacks: co-variables (`%ret`, `%k1`, …, the anonymous hole `·`), stack pushes `p·k` (tagged `ACNS_STACK`, pretty-printed via the `ACNS_CALL` tag as `call(a,b;k)`), projections `fst(k)/snd(k)/#n(k)/.f(k)/[i](k)`, case/cocase, μ̃-binders `μ̃x.c`, ascriptions, share/erase/subst, deref/store, labels. Right of a cut.
- **Commands** (`cmd`, `c`) — cuts `<p|e>`, the two binders `μα.c`/`μ̃x.c`, plus surface sugared forms (SEQ, LET, LETREC, IF, MATCH, HANDLE, WHILE, FOR, BLOCK, UNSAFE, UNCHECKED, COMPTIME, LABEL, JUMP, ASSERT, ASSUME, UB, TRAP, RET, BREAK, CONTINUE, DEFER, PERFORM, RESUME, ASM, SYSCALL, ATOMIC, FENCE, NOP).

## Key equations used by the lowerer

```
(call)   f(a,b,c)        =  <f | a·b·c·%ret>           (ACNS_CALL sugar)
(field)  x.f             =  <x | .f·%ret>
(index)  a[i]            =  <a | [i]·%ret>
(tail)   return v        =  <v | %ret>                 (%ret from ret-stack!)
(nontail) let x = e; rest =  <e | μ̃x.rest>
(if)     if p then t else e = <p | case{true→t; false→e}>   (sugared to ACMD_IF)
(fn)     fn(x){b}        =  λx.μ̃%ret.b
(def)    def f(x) = b    =  f = μ̃%ret.(λx.b)            (letrec when mutual)
(struct) struct S{f}      =  codata S { .f(·) }
(enum)   enum E{C(x)}     =  data E { C(x) }
(loop)   while c b        = label %exit { label %loop {
                                         <c | case{ true→b; jump %loop
                                                   ; false→jump %exit }>
                                       }; jump %loop }
```

## Design invariants

1. **Stubless output** — the output AIR never contains `*k*`/`*dummy*` placeholder covariables, no `<()|·>` admin-nop spam, no source-span leakage, no duplicated code after returns. This is enforced by:
   - `air_node_text` always arena-duping with `slen` length.
   - `letlike` threading `rest` directly (no `lr.nop()` padding which generated `<()|μ̃x. ()>`).
   - `call`/`binop`/etc. pre-allocating fresh var names and wrapping subexpression evaluations right-to-left using μ̃ whose body *is* the rest of the computation (never `lr.nop()`).
   - `stmts`'s backward walk stopping after terminal statements (`return`/`break`/`continue`/`trap`/`ub`), recursing into blocks/stmt-expr.
   - `cmd_cns`/`block_expr` using real μα activation records for blocks in expression position.
2. **α-renaming** — every binder goes through `AirScope.bind_var/bind_covar` which appends `_N` suffixes on shadowing; output AIR has no shadowed variables.
3. **Ret stack** — `return` always cuts to `scope.current_ret()`, which is the enclosing fn/lambda/let-const's freshly bound `%ret_N`. Lambdas and `decl_letconst` both push/pop their `%ret` around their body.
4. **ANF-adjacent shape** — non-value subexpressions (calls, field access, binops, control flow) are μ̃-bound to fresh `_xN` variables when in non-tail position. Value nodes (literals, variables, tuples/arrays/struct-lits of values, lambdas) go directly as `prd()`.
5. **Right-to-left continuation threading** — instead of accumulating a `binds` list followed by `<final>`, every non-value subexpr wraps the *already-built* rest as its μ̃ body, producing naturally nested ANF without nop administrators.
6. **Arena-allocated, self-contained IR** — after lowering, everything (strings, nodes) lives in the `AirArena`; freeing the arena frees the AIR. No pointer back into source/interner memory escapes.
7. **Totality** — every reachable node kind has a case; unknown exprs produce `poison` so the emitter doesn't crash and the bug is visible in output.

## Debugging tips

- Add `lr.cuts++/lr.mu++/lr.mutilde++/…` counters print at end of `emit_module` to spot explosions (e.g. an infinite μ̃ loop would show billions of cuts).
- When a new `*k*` / `*dummy*` appears in output, grep `air_lower.c3` for literal `"*k*"` — any code path that calls `cmd(n, k)` where `k` is a consumer (AirCns*) must route through `cmd_cns`, and any code path calling `lr.cmd(body, "some-literal")` should use a fresh covar allocated through the scope (`fresh_k()`/`fresh_x()`) so the name is a proper _xN / %kN.
- Source-span leaks manifest as identifiers followed by garbage characters / the rest of the source line; the fix is to make sure `node_text` (lowerer) or `air_node_text` (typer) is used rather than returning raw `sptr` without duping-with-slen.
- "Duplicated code after return" almost always means `stmts` prepended a statement on top of a cur that already contained the rest; check that `sc_consumes_cur` is true for letlike/expr-in-stmt-position paths (they wrap `cur` as their μ̃ body and must not be SEQ-composed again).
- When `c3c` complains about "This method is already defined", you likely left a forward-declaration block in place (C3 has no non-extern forward decls — methods are all mutually visible without them).

## Build / test

From the repo root:

```sh
~/c3bin/c3c compile --stdlib ~/c3lib \
  pfront/*.c3 pfront/pear_ir/*.c3 \
  pfront/theory/*.c3 pfront/theory/types/*.c3 pfront/theory/meta/*.c3 \
  pfront/theory/effects/*.c3 pfront/theory/rewrite/*.c3 \
  pfront/theory/lower/*.c3 pfront/theory/analysis/*.c3 \
  -o pfrontc
```

Smoke tests:

```sh
echo 'fn main() -> i64 { let x = 42; return x; }' > /tmp/hello.pie
./pfrontc --emit-air /tmp/hello.pie && cat /tmp/hello.air
```

Expected output:

```
fn main() -> i64 {
  μ̃%ret_1. let x = 42;
  <x|%ret_1>
}
```

The kitchen-sink conformance test `/tmp/everything.pie` (581 lines) exercises
comments, literals, primitives, let/let mut, clauses, control flow, pattern
matching, structs/unions, algebraic effects, generics, semantic subtyping,
UB, memory, TRS rewriting, PGL, code quotation, IRDL dialects (Expr/Hose with
opcodes, regions, blocks, nodes, edges, hyperedges, graphs), MSP, and
modules. After lowering the resulting AIR contains codata for the IRDL
dialects (`Node`, `Buffer`, `Ring`) plus imports; most user fn bodies are
currently collapsed by the theory pass ("151 declaration(s) vanished with
no pass claiming them"), which is an optimizer issue upstream of this
bridge.
