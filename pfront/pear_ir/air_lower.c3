// ============================================================================
// air_lower.c3 — PNode AST → AIR (λ̄μμ̃) lowering.
// ----------------------------------------------------------------------------
// This module is the HEART of the pfront→AIR bridge. It walks the resolved,
// type-annotated, theory-optimized PNode tree that comes out of the pfront
// pipeline (parser → resolver → type-infer → checker → theory passes) and
// translates it into an AirModule of classical sequent calculus terms: the
// λ̄μμ̃ calculus of Curien & Herbelin (2000).
//
// Short recap of the calculus (3 sorts):
//
//   Producers (prd, p, v): terms that produce values — variables, literals,
//     pairs, sums, lambdas, constructors. Inhabitant on the LEFT of a cut.
//
//   Consumers (cns, e, k): contexts/evaluation contexts/stacks — co-
//     variables, ·-stack (push), projections, field access, case, cocase,
//     mu~ binders. Inhabitant on the RIGHT of a cut.
//
//   Commands (cmd, c): cuts  < p | e >  that pair a producer with a consumer,
//     plus the two binders μ α.c (producer-side activation, "give me a
//     covariable and I'll run c") and μ̃ x.c (consumer-side activation,
//     "give me a value and I'll run c").
//
// The three key equations that guide translation:
//
//   (call)    f(a,b,c)     =  < f | a·b·c·%ret >    (args pushed on stack)
//   (field)   x.f          =  < x | .f·%ret >        (field is a destructor)
//   (tail)    return e     =  < e | %ret >           (immediate cut to ret)
//   (non-tail) let x = e in c  =  < e | μ̃x.c >      (ANF-bind the value)
//   (if)      if p then t else e = < p | case{true→t; false→e} >
//   (fn)      fn(x){b}     =  λx.< b | %ret >       (producer lambda)
//   (def)     def f(x)=b   =  f = μ̃%ret.(λx.<b|%ret>)
//   (struct)  struct S{f}  =  codata S { .f(·) }     (codata w/ destructors)
//   (enum)    enum E{C(x)}  =  data E { C(x) }       (data w/ constructors)
//
// All traversal functions are METHODS on `AirLower` so that C3's rule about
// forward declarations (which are disallowed for non-extern functions) does
// not bite us — methods of a struct are all mutually visible within the
// module regardless of definition order.
//
// Design principles of this pass:
//
//   1. The pass is TOTAL over the resolved PNode tree: every node kind that
//      can reach this point (after type checking and theory optimisation) has
//      a translation. Unknown nodes produce `poison[T]` terms so the emitter
//      doesn't crash, and the bug is obvious in the output.
//
//   2. ANF-adjacent: every non-trivial producer in a non-tail position is
//      μ̃-bound to a fresh variable. Tail expressions cut directly against
//      the continuation `k` passed down by the caller. This means the output
//      looks like A-normal form but is fully classical sequent calculus —
//      every intermediate is bound, which is exactly what PEAR needs for
//      structural focusing.
//
//   3. Alpha-renaming: every binding is given through the AirScope, which
//      detects shadowing by appending _N suffixes. The output AIR has no
//      shadowed variables, which is a precondition for PEAR's linear
//      analysis.
//
//   4. Type ascription is preserved when available: every producer that has
//      a type_slot filled in by the type checker gets its `ty` field set,
//      and every binder gets its parameter type. The emitter prints these
//      as human-readable annotations; PEAR can ignore or use them.
//
//   5. Source spans are NOT threaded through to AIR (we could add them as
//      metadata later for better diagnostics in PEAR) — the current priority
//      is correct, well-scoped, well-typed λ̄μμ̃ terms.
//
//   6. Debug counters: every cut / mu / mu~ / jump / label / let bumps a
//      counter. After lowering the stats footer of the .air file reports
//      counts so we can spot explosions (e.g. an infinite loop inserting
//      admin redexes would show as billions of cuts).
//
//   7. Nested local bindings (let/const inside function bodies) become
//      ACMD_LET commands nested in the command sequence, NEVER top-level
//      AirDecls. This was a bug in the first draft where stmts() called
//      decl_inner() on every is_decl() child, lifting nested lets to
//      module scope. The current code distinguishes: only
//      N_FN/N_STRUCT/N_ENUM/... (top-level-izable things) at MODULE body
//      depth become AirDecls.
//
//   8. Entry: `AirLower.module_body(root)` — driver function called from
//      air::emit_air. It walks into the PROGRAM/MODULE wrapper and iterates
//      top-level declarations, calling AirLower.decl(n) for each.
//
//   9. The lowering produces syntactic sugar markers: multi-arg call stacks
//      are tagged ACNS_CALL so the emitter prints (a,b,c) instead of the
//      raw a·b·c·k chain; boolean ifs are tagged ACMD_IF rather than raw
//      case-on-bool, for readability. These are NOT semantic distinctions
//      — PEAR will treat ACNS_CALL identically to nested STACK — they just
//      make the .air output a human can actually read.
//
//  10. Multiplicity annotations (linear / affine / unrestricted / exact) are
//      threaded from Pride's type system when available; until the linear
//      types pass is wired up we default every binder to AMULT_UNR.
//
//  11. SENTINELS: m.p_unit, m.c_ret, m.p_true, m.p_false, m.p_null,
//      m.pat_wild, m.nop are preallocated in AirModule.init() so we never
//      allocate a fresh `unit` or `_` or `%ret` node per use site.
//
//  12. Error recovery: if allocation fails mid-lowering, the AirArena.oom
//      flag is set, and all air_new_* functions return null. The lowering
//      pass null-checks every allocation and substitutes nop / unit /
//      wild as needed so we don't crash even if OOM strikes.
//
//  13. All strings emitted into AIR are duplicated into the AirArena via
//      AirArena.dup(), so freeing the arena at the end frees everything.
//      We never retain pointers into the PNode source after lowering
//      completes — the AIR is self-contained.
//
//  14. The generated μ̃ binder for %ret is ALWAYS freshly bound by the
//      scope when entering a def or lambda. At module scope the preloaded
//      %ret from AirModule.init() is used for top-level expressions (which
//      shouldn't happen but are tolerated).
//
//  15. Loops are encoded as:
//        label %exit {
//          label %loop {
//            < cond | case{ true  -> body; jump %loop
//                          ; false -> jump %exit } >
//          }
//          jump %loop
//        }
//      which is the standard CPS-encoding of loops using join points.
//      break/continue inside the body jump to %exit/%loop respectively,
//      maintained by AirScope.push_loop/pop_loop.
//
//  16. Match arms become a case{} consumer over the scrutinee. Patterns
//      are translated by pat_node() which recurses into tuple/variant/
//      literal patterns and binds variables through the scope.
//
//  17. Algebraic effects: perform op(v)  =  < v | %op >  (cut to an op
//      covariable). handle c { arms } is ACMD_HANDLE which the emitter
//      prints using the `handle` keyword and PEAR will interpret as a
//      delimited control prompt. Effect declarations become
//      ADECL_EFFECT with a list of op names.
//
//  18. The unsafe/comptime/unchecked markers become ACMD_UNSAFE /
//      ACMD_COMPTIME / ACMD_UNCHECKED wrappers around their body;
//      assert/assume become ACMD_ASSERT / ACMD_ASSUME cuts against
//      an implicit-assert consumer (we model them as commands that take
//      a producer witness).
//
//  19. defer is scoped: μ̃k.(defer-body; <unit|k>) wrapping the continuation.
//      In proper CPS this would be a reified continuation, but for AIR
//      we emit it as a command wrapper that PEAR can reason about.
//
//  20. Try/resume: for now try(e) = e (exception handling not yet modeled
//      in AIR, placeholder until the effect system extends it).
//
//  21. asm / syscall / atomic / fence: these are "marker" commands with
//      literal string/operand storage. They round-trip through AIR so
//      that later PEAR passes can do machine-specific lowering without
//      losing information, but we do not attempt to model their semantics
//      in λ̄μμ̃ (they are primitives).
//
//  22. The offsetof/sizeof/alignof producers are APRD_SIZEOF/APRD_ALIGNOF/
//      (offsetof is folded into sizeof of the field type as a placeholder).
//
//  23. Quote/reify/splice/eval (meta-programming / multi-stage programming):
//      these are tracked but lowered as opaque primitives — the theory
//      layer already normalised staged code, and this pass just preserves
//      the remaining markers.
//
//  24. Range literals (a..b) are desugared into a Range(a,b) constructor
//      application. This matches how the stdlib models them.
//
//  25. Volatile loads/stores are passed through (they become normal
//      deref/store producers wrapped in an ACMD_UNCHECKED wrapper to
//      signal the optimiser not to touch them).
//
//  26. Poison / unreachable: APRD_POISON and ACMD_UB with message.
//
//  27. Traits / impls: not modelled at the term level in AIR (they are
//      compile-time dictionaries already resolved away by the type
//      checker). We could encode them as explicit dictionary arguments
//      later; for now the def's param list contains only source-level
//      parameters.
//
//  28. Closures / lambdas: fn(x) => e  lowers to APRD_LAMBDA. Captured
//      variables become free variables in the body; closure conversion
//      is a PEAR pass (lambda lifting / defunctionalisation).
//
//  29. Methods: x.f(args) lowers to < x | .f·(args)·k >, i.e., field
//      projection followed by call, which is correct for the OO dot
//      syntax in Pride.
//
//  30. Index a[i] lowers to < a | [i]·k >, which is the ACNS_INDEX
//      consumer. Arrays/slices/pointer indexing all use the same shape
//      at the AIR level; PEAR will distinguish them via types.
//
//  31. Slicing a[b:c] lowers to a method call to .slice(b,c) per the
//      expr_to_cns N_EXPR_SLICE case.
//
//  32. Casts (as / transmute) become ACNS_ASCRIBE [T] on the consumer,
//      with an explicit ACNS_DEREF/ACNS_STORE not modeled here (we
//      produce a binary-app like coercion).
//
//  33. Alloc/free: alloc is a nullary primitive var; free(p) becomes
//      < free | p·k > (call to the free primitive).
//
//  34. References: &x  = AUN_ADDR / ACNS_COMU binding; *p = ACNS_DEREF.
//      Assignment is lr.store model: we write a store consumer (placeholder
//      — real stores will be modeled as a CNS_STORE in a future pass once
//      we have MLVar / ref-type semantics figured out).
//
//  35. The short-circuit operators && and || are NOT desugared into ifs
//      at the surface level (they become ACMD_IF over the first arg, with
//      the second arg in the then/else branch). This avoids code blow-up
//      for chained `a && b && c && d` and lets PEAR see the boolean
//      structure.
//
//  36. Operator precedence is NOT represented in AIR — n-ary
//      applications are flattened into binary binop producers; PEAR will
//      re-associate according to the language rules.
//
//  37. Parenthesised expressions are invisible to AIR (the parser strips
//      them).
//
//  38. Doc comments (N_DOC) are skipped during lowering; we could attach
//      them as metadata later.
//
//  39. Use/import declarations become ADECL_IMPORT nodes, carrying the
//      path and optional alias/glob flag, so PEAR can resolve cross-module
//      references.
//
//  40. The recursion pattern is: module_body walks top-level forms,
//      decl() dispatches to decl_fn / decl_struct / decl_enum / etc, each
//      of which allocates an AirDecl and fills its fields by walking
//      the children of the decl node. The body of a fn is translated by
//      calling cmd()/expr_to_cns()/stmts()/block() which recursively
//      walk statements and expressions.
//
// This file is deliberately long — every node kind gets explicit handling,
// every branch is commented, and we aim for a highly readable output that
// a human reading the .air file can trace back to the source .pie program.
// The companion emitter air_emit.c3 prints every node with sufficient
// whitespace and indentation that you can read it like LLVM IR.
//
// Writing code in Pride is a piece of cake... well, a piece of '.pie'.
// ============================================================================
module air_lower;

import pfront_core;
import pfront_lex;
import air_ir;
import air_scope;
import air_types;

extern fn int snprintf(char* buf, usz n, char* fmt, ...);

alias Node = pfront_core::PNode;
alias Nk   = pfront_core::NodeKind;
alias Tk   = pfront_lex::TokenType;

// ── AirLower state ──────────────────────────────────────────────────────────
// The lowering context threaded through every method. We keep it as a struct
// rather than half a dozen global variables so that the pass is re-entrant
// (in theory you could lower multiple modules interleaved; in practice we
// lower one module per compiler invocation, but good hygiene costs nothing).
struct AirLower
{
    AirModule*   mod;        // output module being built
    AirArena*    arena;      // bump allocator for all AIR nodes
    AirScope*    scope;      // name supply + lexical scope stack
    pfront_core::Interner* it; // interner for node text resolution
    char[256]    tmp;        // scratch buffer for snprintf (fresh_* naming)
    usz          cuts;       // # of ACMD_CUT emitted
    usz          mu;         // # of ACMD_MU emitted
    usz          mutilde;    // # of ACMD_MUTILDE emitted
    usz          jumps;      // # of ACMD_JUMP emitted
    usz          labels;     // # of ACMD_LABEL emitted
    usz          lets;       // # of ACMD_LET (administrative and source)
    usz          total_prd;  // # of AirPrd allocated (debug)
    usz          total_cns;  // # of AirCns allocated (debug)
    usz          total_cmd;  // # of AirCmd allocated (debug)
    usz          total_decl; // # of AirDecl allocated (debug)
    usz          errors;     // # of lowered nodes that fell to poison/default
}

fn void AirLower.init(AirLower* lr, AirModule* m, AirScope* sc, pfront_core::Interner* it)
{
    lr.mod = m;
    lr.arena = m.arena;
    lr.scope = sc;
    lr.it = it;
    for (usz i = 0; i < 256; i++) { lr.tmp[i] = 0; }
    lr.cuts = 0; lr.mu = 0; lr.mutilde = 0; lr.jumps = 0;
    lr.labels = 0; lr.lets = 0;
    lr.total_prd = 0; lr.total_cns = 0; lr.total_cmd = 0; lr.total_decl = 0;
    lr.errors = 0;
}

// ── Small helpers ──────────────────────────────────────────────────────────
// These are used everywhere; keeping them short but well-named makes the
// code below read like pseudocode.
fn char* AirLower.fresh_k(AirLower* lr)    { return lr.scope.fresh_k_covar(); }
fn char* AirLower.fresh_x(AirLower* lr)    { return lr.scope.fresh_x_var(); }
fn char* AirLower.fresh_lbl(AirLower* lr, char* hint) { return lr.scope.fresh_label(hint); }

// node_text — extract the source text (identifier name, literal text, etc.)
// from a PNode and dup it into the arena so we never hold a pointer into
// source memory (which is NOT NUL-terminated and may not outlive lowering).
fn char* node_text(AirLower* lr, Node* n)
{
    if (n == null) return null;
    AirArena* a = lr.arena;
    if (n.p.sptr != null && n.p.slen > 0)
    {
        return a.dup(n.p.sptr, (usz)n.p.slen);
    }
    if (lr.it != null && n.name_id != 0)
    {
        char* t = lr.it.text(n.name_id);
        if (t != null)
        {
            int ln = 0; while (t[ln] != 0) ln++;
            return a.dup(t, (usz)ln);
        }
    }
    if (n.resolved != null) return node_text(lr, n.resolved);
    return null;
}

fn char* AirLower.nm(AirLower* lr, Node* n) { return node_text(lr, n); }

// dup — duplicate a C string into the arena. Returns null for null input.
fn char* AirLower.dup(AirLower* lr, char* s)
{
    if (s == null) return null;
    int n = 0;
    while (s[n] != 0) { n = n + 1; }
    return lr.arena.dup(s, (usz)n);
}

// fmt — format a single long integer into tmp, then dup into arena.
// Used for generating _f0, _f1, ... field names for positional struct
// initialisers, etc.
fn char* AirLower.fmt(AirLower* lr, char* fstr, long arg)
{
    (void)snprintf(&lr.tmp[0], 256, fstr, (int)arg);
    return lr.dup(&lr.tmp[0]);
}

// cut — build < p | e > and bump the cut counter. This is the single most
// common smart-constructor call in the file.
fn AirCmd* AirLower.cut(AirLower* lr, AirPrd* p, AirCns* k)
{
    lr.cuts++;
    lr.total_cmd++;
    return air_ir::air_mk_cut(lr.arena, p, k);
}

// cns_k — wrap a covariable name into a ACNS_COVAR consumer.
fn AirCns* AirLower.cns_k(AirLower* lr, char* k)
{
    lr.total_cns++;
    return air_ir::air_mk_covar(lr.arena, k);
}

// nop — <unit | fresh-covar>; used as "hole" filler for sequences where we
// haven't plugged the real command yet.
fn AirCmd* AirLower.nop(AirLower* lr)
{
    return lr.cut(lr.mod.p_unit, air_ir::air_mk_covar(lr.arena, lr.dup((char*)"·")));
}

// poison — produce a visible marker that something went wrong in lowering,
// rather than crashing or emitting a null pointer.
fn AirCmd* AirLower.poison_cmd(AirLower* lr, char* msg)
{
    lr.errors++;
    return air_ir::air_mk_ub(lr.arena, lr.dup(msg));
}

fn AirPrd* AirLower.poison_prd(AirLower* lr)
{
    lr.errors++;
    return air_ir::air_mk_poison(lr.arena, lr.mod.t_infer);
}

// ── Value vs. non-value classification ────────────────────────────────────
// A "value node" is a PNode that can be emitted directly as an AirPrd with
// no side effects — no need to ANF-bind it through μ̃. Literals, variables,
// tuples/arrays/struct-lits consisting entirely of values, and lambdas are
// values (lambdas are values because they suspend their body).
//
// Non-value nodes (calls, field accesses, binops, if/match, etc.) must be
// let-bound when they appear in non-tail position: the producer position is
// filled with a fresh variable x_v, and the evaluation of the node is
// sequenced as <node | μ̃x_v. ... >.
fn bool is_value_node(Node* n)
{
    if (n == null) return true;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_FLOAT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_STRING:
        case Nk.N_EXPR_BYTES:
        case Nk.N_EXPR_UNIT:
        case Nk.N_EXPR_NULL:
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_SELF:
        {
            return true;
        }
        case Nk.N_EXPR_TUPLE:
        case Nk.N_EXPR_ARRAY:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                if (!is_value_node(n.children[i])) return false;
            }
            return true;
        }
        case Nk.N_EXPR_STRUCT_LIT:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) continue;
                if (c.kind == Nk.N_EXPR_FIELD_INIT && c.child_count > 0)
                {
                    if (!is_value_node(c.children[0])) return false;
                }
                else if (!is_value_node(c))
                {
                    return false;
                }
            }
            return true;
        }
        case Nk.N_EXPR_LAMBDA: return true;
        default: return false;
    }
}

// ── Forward group: pattern → producer → consumer → statement/command ──────
// All methods on AirLower so mutual recursion works without forward decls.
// Convention: every method returns a fully-formed AIR node or null/unit/nop
// on failure. Pat returns AirPat*; prd returns AirPrd*; expr_to_cns returns
// AirCmd* (the command that evaluates `n` and feeds its value into `k`);
// cmd returns AirCmd*; decl returns AirDecl*.
// (All methods are mutually visible within the module; no forward decls needed.)

// ── Patterns ──────────────────────────────────────────────────────────────
// Patterns appear in match arms, let bindings, fn parameters (as pat-ident),
// etc. The translation is straightforward: wildcards become pat_wild,
// identifiers become APAT_BIND (and the name is registered in the scope so
// subsequent references resolve to the alpha-renamed AIR name), literals
// become APAT_INT/APAT_BOOL/APAT_CHAR/APAT_STRING, tuples/arrays/variants
// become APAT_TUPLE/APAT_ARRAY/APAT_VARIANT with recursive sub-patterns.

fn AirPat* AirLower.pat(AirLower* lr, Node* p)
{
    if (p == null) return lr.mod.pat_wild;
    return lr.pat_node(p);
}

fn AirPat* AirLower.pat_node(AirLower* lr, Node* p)
{
    if (p == null) return lr.mod.pat_wild;
    switch (p.kind)
    {
        case Nk.N_PAT_WILDCARD: return lr.mod.pat_wild;
        case Nk.N_PAT_IDENT:
        {
            char* nm = node_text(lr, p);
            // A leading underscore means "wildcard" (unused variable pattern);
            // we emit it as a wildcard rather than a binding to avoid
            // polluting the scope with names the user explicitly said they
            // don't care about.
            if (nm == null || nm[0] == '_') return lr.mod.pat_wild;
            char* an = lr.scope.bind_var(nm, p);
            return air_ir::air_mk_pat_bind(lr.arena, an);
        }
        case Nk.N_PAT_LITERAL:
        {
            if (p.child_count > 0)
            {
                Node* lit = p.children[0];
                if (lit.kind == Nk.N_EXPR_INT)
                {
                    return air_ir::air_mk_pat_int(lr.arena, (long)lit.p.ival);
                }
                if (lit.kind == Nk.N_EXPR_BOOL)
                {
                    return air_ir::air_mk_pat_bool(lr.arena, lit.p.ival != 0);
                }
                if (lit.kind == Nk.N_EXPR_CHAR)
                {
                    AirPat* pp = air_ir::air_mk_pat(lr.arena, APAT_CHAR);
                    pp.ival = (long)(lit.p.ival & 0xff);
                    return pp;
                }
                if (lit.kind == Nk.N_EXPR_STRING)
                {
                    AirPat* pp = air_ir::air_mk_pat(lr.arena, APAT_STRING);
                    pp.name = lr.dup(lit.p.sptr);
                    return pp;
                }
            }
            return lr.mod.pat_wild;
        }
        case Nk.N_PAT_TUPLE:
        {
            AirPat*[16] subs; usz n = 0;
            for (usz i = 0; i < p.child_count && i < 16; i++)
            {
                subs[n] = lr.pat_node(p.children[i]);
                n = n + 1;
            }
            return air_ir::air_mk_pat_tuple(lr.arena, &subs[0], n);
        }
        case Nk.N_PAT_VARIANT:
        {
            char* vnm = node_text(lr, p);
            if (vnm == null) vnm = (char*)"_V";
            AirPat*[16] subs; usz n = 0;
            for (usz i = 0; i < p.child_count && i < 16; i++)
            {
                subs[n] = lr.pat_node(p.children[i]);
                n = n + 1;
            }
            return air_ir::air_mk_pat_variant(lr.arena, lr.dup(vnm), &subs[0], n);
        }
        case Nk.N_PAT_ARRAY:
        {
            AirPat*[16] subs; usz n = 0;
            for (usz i = 0; i < p.child_count && i < 16; i++)
            {
                subs[n] = lr.pat_node(p.children[i]);
                n = n + 1;
            }
            AirPat* pp = air_ir::air_mk_pat(lr.arena, APAT_ARRAY);
            for (usz i = 0; i < n && i < 16; i++) { pp.sub[i] = subs[i]; pp.sub_count++; }
            return pp;
        }
        default: return lr.mod.pat_wild;
    }
}

// ── Producers (values, no side effects) ───────────────────────────────────
// prd(n) returns an AirPrd* for a value node. It only handles the
// is_value_node set — for non-value nodes you MUST use prd_or_bind/expr_to_cns.
// prd_or_bind is the wrapper that μ-binds non-value subexpressions.

fn AirPrd* AirLower.prd(AirLower* lr, Node* n)
{
    if (n == null) return lr.mod.p_unit;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        {
            AirPrd* p = air_ir::air_mk_int(lr.arena, (long)n.p.ival);
            p.ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
            lr.total_prd++;
            return p;
        }
        case Nk.N_EXPR_FLOAT:
        {
            lr.total_prd++;
            return air_ir::air_mk_float(lr.arena, n.p.fval);
        }
        case Nk.N_EXPR_BOOL:
        {
            lr.total_prd++;
            return (n.p.ival != 0) ? lr.mod.p_true : lr.mod.p_false;
        }
        case Nk.N_EXPR_CHAR:
        {
            lr.total_prd++;
            return air_ir::air_mk_char(lr.arena, (char)(n.p.ival & 0xff));
        }
        case Nk.N_EXPR_STRING:
        {
            lr.total_prd++;
            return air_ir::air_mk_str(lr.arena, n.p.sptr, (usz)n.p.slen);
        }
        case Nk.N_EXPR_BYTES:
        {
            lr.total_prd++;
            return air_ir::air_mk_bytes(lr.arena,
                n.p.sptr == null ? (char*)"" : n.p.sptr, (usz)n.p.slen);
        }
        case Nk.N_EXPR_UNIT:  return lr.mod.p_unit;
        case Nk.N_EXPR_NULL:  return lr.mod.p_null;
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_SELF:
        {
            char* nm = node_text(lr, n);
            if (nm == null) nm = (char*)"_x";
            char* x = lr.scope.lookup_var(nm);
            if (x == null) x = lr.dup(nm);
            lr.total_prd++;
            return air_ir::air_mk_var(lr.arena, x);
        }
        case Nk.N_EXPR_TUPLE:
        {
            AirPrd*[16] s; usz n2 = 0;
            for (usz i = 0; i < n.child_count && i < 16; i++)
            {
                s[n2] = lr.prd(n.children[i]);
                n2 = n2 + 1;
            }
            lr.total_prd++;
            return air_ir::air_mk_tuple(lr.arena, &s[0], n2);
        }
        case Nk.N_EXPR_ARRAY:
        {
            AirPrd*[16] s; usz n2 = 0;
            for (usz i = 0; i < n.child_count && i < 16; i++)
            {
                s[n2] = lr.prd(n.children[i]);
                n2 = n2 + 1;
            }
            lr.total_prd++;
            return air_ir::air_mk_array(lr.arena, &s[0], n2);
        }
        case Nk.N_EXPR_LAMBDA: return lr.lambda_prd(n);
        case Nk.N_EXPR_STRUCT_LIT: return lr.struct_lit_prd(n);
        default: return lr.prd_or_bind(n);
    }
}

fn AirPrd* AirLower.lambda_prd(AirLower* lr, Node* n)
{
    lr.scope.enter();
    AirBinder*[16] bv; usz bc = 0;
    usz i;
    for (i = 0; i < n.child_count && bc < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM)
        {
            char* pnm = (char*)"_";
            AirTyp* pty = lr.mod.t_infer;
            if (c.child_count > 0)
            {
                Node* pp = c.children[0];
                pnm = node_text(lr, pp);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) pty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            bc = bc + 1;
        }
    }
    char* ret = lr.scope.bind_covar("%ret", null);
    lr.scope.push_ret(ret);
    AirCmd* body = null;
    for (i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_PAT_IDENT
         || c.kind == Nk.N_EXPR_IDENT || c.kind == Nk.N_PAT_WILDCARD) continue;
        body = lr.cmd(c, ret);
        break;
    }
    if (body == null) body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
    lr.scope.pop_ret();
    AirPrd* lam = air_ir::air_mk_lambda(lr.arena, &bv[0], bc, body);
    lr.scope.leave();
    lr.total_prd++;
    return lam;
}

fn AirPrd* AirLower.struct_lit_prd(AirLower* lr, Node* n)
{
    AirFieldInit*[16] inits; usz ic = 0;
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        AirFieldInit* fi = air_ir::air_new_AirFieldInit(lr.arena);
        if (c.kind == Nk.N_EXPR_FIELD_INIT)
        {
            char* fnm = node_text(lr, c);
            if (fnm == null) fnm = (char*)"f";
            fi.name = lr.dup(fnm);
            fi.value = c.child_count > 0 ? lr.prd(c.children[0]) : lr.mod.p_unit;
        }
        else
        {
            fi.name = lr.fmt((char*)"_f%ld", (long)i);
            fi.value = lr.prd(c);
        }
        fi.id = 0;
        inits[ic] = fi;
        ic = ic + 1;
    }
    AirPrd* rec = air_ir::air_new_AirPrd(lr.arena);
    rec.tag = APRD_RECORD;
    rec.rec_init_count = 0;
    for (usz i = 0; i < ic && i < 16; i++)
    {
        rec.rec_inits[rec.rec_init_count] = inits[i];
        rec.rec_init_count = rec.rec_init_count + 1;
    }
    lr.total_prd++;
    return rec;
}

// prd_or_bind — if n is a value, return its AirPrd; otherwise mint a fresh
// covariable α and build μα.<n-expr-to-α>, which acts as a producer-side
// activation that captures the evaluation of n as a value. This is the key
// trick that lets us embed non-trivial computations in producer position
// without breaking the ANF shape of the output.
fn AirPrd* AirLower.prd_or_bind(AirLower* lr, Node* n)
{
    if (is_value_node(n)) return lr.prd(n);
    char* alpha = lr.fresh_k();
    AirCmd* cmd = lr.expr_to_cns(n, air_ir::air_mk_covar(lr.arena, alpha));
    lr.mu++;
    lr.total_prd++;
    return air_ir::air_mk_mu_prd(lr.arena, alpha, cmd);
}

// ── Commands (statements, cmd-level constructs) ───────────────────────────
// cmd(n, k) — translate a statement node into a command that eventually
// cuts to the continuation covariable k.  Each statement kind either returns
// a direct cut to k, or builds a composite command (sequence, jump, break,
// continue, return, defer, assign, ...).

fn AirCmd* AirLower.cmd(AirLower* lr, Node* n, char* k)
{
    if (n == null) return lr.cut(lr.mod.p_unit, lr.cns_k(k));
    switch (n.kind)
    {
        case Nk.N_STMT_EXPR:
        {
            // A statement-expression is a block of statements in expression
            // position; route through stmts with tail_is_k=true so the
            // final expression cuts to k.
            return lr.stmts(n, k, true);
        }
        case Nk.N_BLOCK:
        {
            return lr.block(n, k);
        }
        case Nk.N_STMT_RETURN:
        {
            // return v = <v|%ret> where %ret is the enclosing fn's return
            // covariable (not the local k, which may be a μ̃ binder for a
            // case arm / let-binding). This is non-local return semantics.
            char* ret = lr.scope.current_ret();
            if (n.child_count > 0) return lr.expr_to_cns(n.children[0], lr.cns_k(ret));
            return lr.cut(lr.mod.p_unit, lr.cns_k(ret));
        }
        case Nk.N_STMT_BREAK:
        {
            char* lbl = lr.scope.current_break();
            lr.jumps++;
            return air_ir::air_mk_jump0(lr.arena, lbl);
        }
        case Nk.N_STMT_CONTINUE:
        {
            char* lbl = lr.scope.current_continue();
            lr.jumps++;
            return air_ir::air_mk_jump0(lr.arena, lbl);
        }
        case Nk.N_STMT_DEFER:
        {
            // defer b  in our CPS encoding: capture the current continuation
            // in a fresh covariable, then run b before continuing into it.
            //   μ̃old.(b ; <unit|old>)
            char* old = lr.fresh_k();
            lr.scope.enter();
            AirCmd* body = n.child_count > 0 ? lr.cmd(n.children[0], k) : lr.nop();
            lr.scope.leave();
            AirCmd* cont = lr.cut(lr.mod.p_unit, air_ir::air_mk_covar(lr.arena, old));
            lr.mutilde++;
            return air_ir::air_mk_mutilde(lr.arena, old,
                air_ir::air_mk_seq(lr.arena, body, cont));
        }
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        {
            return lr.assign_stmt(n, k);
        }
        default:
        {
            // Fall-through: if the node is an expression used in statement
            // position, evaluate it for effect, discarding the value by
            // μ̃-binding it to a fresh "_"-named variable that is never used.
            if (pfront_core::is_expr(n.kind))
            {
                char* ignore = lr.fresh_x();
                return lr.expr_to_cns(n,
                    air_ir::air_mk_comu_cns(lr.arena, ignore,
                        lr.cut(lr.mod.p_unit, lr.cns_k(k))));
            }
            return lr.cut(lr.mod.p_unit, lr.cns_k(k));
        }
    }
}

// stmts — translate a sequence of statements (children of a block or module)
// into a sequence of commands that threads into continuation k.  If
// tail_is_k is true, the last expression is in tail position relative to k
// (cuts directly to k); otherwise its value is discarded.
//
// The algorithm walks the statement list BACKWARD (last to first): we start
// with the final command (either cut-to-k for the tail expr or a nop) and
// prepend each preceding statement as a SEQ link.  This matches the
// "continuation is built inside-out" nature of CPS.
fn AirCmd* AirLower.stmts(AirLower* lr, Node* container, char* k, bool tail_is_k)
{
    if (container == null || container.child_count == 0)
    {
        return lr.cut(lr.mod.p_unit, lr.cns_k(k));
    }
    long last = (long)container.child_count - 1;
    while (last >= 0 && container.children[(usz)last] == null) { last = last - 1; }
    if (last < 0) return lr.cut(lr.mod.p_unit, lr.cns_k(k));

    lr.scope.enter();
    AirCmd* cur;
    Node* last_n = container.children[(usz)last];
    if (last_n == null)
    {
        cur = lr.cut(lr.mod.p_unit, lr.cns_k(k));
    }
    else if (last_n.kind == Nk.N_BLOCK || last_n.kind == Nk.N_STMT_EXPR
          || pfront_core::is_decl(last_n.kind))
    {
        cur = lr.cmd(last_n, k);
    }
    else if (pfront_core::is_expr(last_n.kind))
    {
        if (tail_is_k)
        {
            cur = lr.expr_to_cns(last_n, lr.cns_k(k));
        }
        else
        {
            char* ignore = lr.fresh_x();
            cur = lr.expr_to_cns(last_n,
                air_ir::air_mk_comu_cns(lr.arena, ignore,
                    lr.cut(lr.mod.p_unit, lr.cns_k(k))));
        }
    }
    else
    {
        cur = lr.cmd(last_n, k);
    }

    // Walk backwards prepending preceding statements. Stop after a terminal
    // (return/break/continue/trap/ub) so we don't emit dead code after it.
    long i = last - 1;
    bool dead = false;
    while (i >= 0)
    {
        Node* s = container.children[(usz)i];
        if (s != null && !dead)
        {
            AirCmd* sc;
            bool sc_consumes_cur = false;
            if (s.kind == Nk.N_DECL_LET || s.kind == Nk.N_DECL_CONST
             || s.kind == Nk.N_DECL_STATIC)
            {
                // letlike already threads cur as the "rest" continuation,
                // so the returned command already includes cur as its tail.
                sc = lr.letlike(s, cur);
                sc_consumes_cur = true;
            }
            else if (s.kind == Nk.N_DECL_FN || s.kind == Nk.N_DECL_EXTERN_FN
                  || s.kind == Nk.N_DECL_STRUCT || s.kind == Nk.N_DECL_UNION
                  || s.kind == Nk.N_DECL_ENUM || s.kind == Nk.N_DECL_TYPE
                  || s.kind == Nk.N_DECL_EFFECT)
            {
                sc = lr.nop();
            }
            else if (pfront_core::is_expr(s.kind))
            {
                char* ignore = lr.fresh_x();
                sc = lr.expr_to_cns(s,
                    air_ir::air_mk_comu_cns(lr.arena, ignore, cur));
                sc_consumes_cur = true;
            }
            else
            {
                sc = lr.cmd(s, k);
            }
            if (sc_consumes_cur)
            {
                cur = sc;
            }
            else
            {
                cur = air_ir::air_mk_seq(lr.arena, sc, cur);
            }
            if (is_terminal_cmd_node(s)) { dead = true; }
        }
        i = i - 1;
    }
    lr.scope.leave();
    return cur;
}

fn AirCmd* AirLower.block(AirLower* lr, Node* n, char* k)
{
    // A block is a statement sequence in tail position.
    return lr.stmts(n, k, true);
}

// letlike — translate a let/const/static declaration (NOT top-level).
// Produces `let x = init in rest`, where `rest` is the continuation
// passed in (the code following the let, already built inside-out).
fn AirCmd* AirLower.letlike(AirLower* lr, Node* s, AirCmd* rest)
{
    if (s.child_count == 0) return rest == null ? lr.nop() : rest;
    char* nm = node_text(lr, s);
    if (nm == null) nm = (char*)"_let";
    Node* val = null;
    for (usz i = 0; i < s.child_count; i++)
    {
        Node* c = s.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_TYPEPARAM || c.kind == Nk.N_DECL_PARAM) continue;
        if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_PAT_WILDCARD) continue;
        val = c;
        break;
    }
    char* x = lr.scope.bind_var(nm, s);
    if (val == null)
    {
        lr.lets++;
        return air_ir::air_mk_let(lr.arena, x, lr.mod.p_unit, rest);
    }
    AirPrd* vp = lr.prd_or_bind(val);
    lr.lets++;
    return air_ir::air_mk_let(lr.arena, x, vp, rest);
}

// decl_inner — register a top-level declaration into the module.
// Called ONLY from module_body (NOT from stmts, which must not lift
// nested decls to the top level).
fn void AirLower.decl_inner(AirLower* lr, Node* d)
{
    if (d == null) return;
    AirDecl* ad = lr.decl(d);
    if (ad != null)
    {
        lr.mod.add_decl(ad);
        lr.total_decl++;
    }
}

// ── Expression → consumer (CPS-style) ────────────────────────────────────
// expr_to_cns(n, k) — this is the workhorse. It returns a command that
// evaluates the expression n and feeds its value into consumer k. For
// value expressions this is just <prd(n)|k>. For compound expressions
// (calls, field access, binops, control flow, etc.) it builds the
// appropriate CPS shape: let-bind subexpressions to fresh variables,
// build the consumer chain, and cut.

fn AirBinop token_to_binop(long op)
{
    switch ((Tk)op)
    {
        case Tk.TOKEN_PLUS:     return ABIN_ADD;
        case Tk.TOKEN_MINUS:    return ABIN_SUB;
        case Tk.TOKEN_STAR:     return ABIN_MUL;
        case Tk.TOKEN_SLASH:    return ABIN_DIV;
        case Tk.TOKEN_PERCENT:  return ABIN_MOD;
        case Tk.TOKEN_AMP:      return ABIN_AND;
        case Tk.TOKEN_PIPE:     return ABIN_OR;
        case Tk.TOKEN_XOR:      return ABIN_XOR;
        case Tk.TOKEN_LSHIFT:   return ABIN_SHL;
        case Tk.TOKEN_RSHIFT:   return ABIN_SHR;
        case Tk.TOKEN_AMPAMP:   return ABIN_LAND;
        case Tk.TOKEN_PIPEPIPE: return ABIN_LOR;
        case Tk.TOKEN_EQEQ:     return ABIN_EQ;
        case Tk.TOKEN_NEQ:      return ABIN_NEQ;
        case Tk.TOKEN_LT:       return ABIN_LT;
        case Tk.TOKEN_GT:       return ABIN_GT;
        case Tk.TOKEN_LTEQ:     return ABIN_LE;
        case Tk.TOKEN_GTEQ:     return ABIN_GE;
        default:                return ABIN_ADD;
    }
}

fn AirCmd* AirLower.expr_to_cns(AirLower* lr, Node* n, AirCns* k)
{
    if (n == null) return lr.cut(lr.mod.p_unit, k);
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        {
            AirPrd* p = air_ir::air_mk_int(lr.arena, (long)n.p.ival);
            p.ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
            lr.total_prd++;
            return lr.cut(p, k);
        }
        case Nk.N_EXPR_FLOAT:
        {
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_float(lr.arena, n.p.fval), k);
        }
        case Nk.N_EXPR_BOOL:
        {
            return lr.cut((n.p.ival != 0) ? lr.mod.p_true : lr.mod.p_false, k);
        }
        case Nk.N_EXPR_CHAR:
        {
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_char(lr.arena, (char)(n.p.ival & 0xff)), k);
        }
        case Nk.N_EXPR_STRING:
        {
            char* s = n.p.sptr; usz sl = (usz)n.p.slen;
            if (s == null) { s = (char*)""; sl = 0; }
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_str(lr.arena, s, sl), k);
        }
        case Nk.N_EXPR_BYTES:
        {
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_bytes(lr.arena,
                n.p.sptr == null ? (char*)"" : n.p.sptr, (usz)n.p.slen), k);
        }
        case Nk.N_EXPR_UNIT:  return lr.cut(lr.mod.p_unit, k);
        case Nk.N_EXPR_NULL:  return lr.cut(lr.mod.p_null, k);
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_SELF:
        {
            char* nm = node_text(lr, n);
            if (nm == null) nm = (char*)"_";
            char* x = lr.scope.lookup_var(nm);
            if (x == null) x = lr.dup(nm);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_var(lr.arena, x), k);
        }
        case Nk.N_EXPR_PATH:
        {
            char* nm = node_text(lr, n);
            if (nm == null) nm = (char*)"_";
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_var(lr.arena, lr.dup(nm)), k);
        }
        case Nk.N_EXPR_TUPLE:       return lr.tuple_lit(n, k);
        case Nk.N_EXPR_ARRAY:       return lr.array_lit(n, k);
        case Nk.N_EXPR_STRUCT_LIT:  return lr.struct_lit(n, k);
        case Nk.N_EXPR_FIELD:       return lr.field_acc(n, k);
        case Nk.N_EXPR_INDEX:       return lr.index_acc(n, k);
        case Nk.N_EXPR_SLICE:
        {
            if (n.child_count < 3) return lr.cut(lr.mod.p_unit, k);
            return lr.method_generic(n.children[0], (char*)"slice", &n.children[1], 2, k);
        }
        case Nk.N_EXPR_CALL:
        {
            if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
            return lr.call(n.children[0], &n.children[1], n.child_count - 1, k);
        }
        case Nk.N_EXPR_METHOD:
        {
            if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
            char* mname = node_text(lr, n);
            if (mname == null) mname = (char*)"_m";
            Node** rest = null; usz rc = 0;
            if (n.child_count > 1)
            {
                rest = &n.children[1];
                rc = n.child_count - 1;
            }
            return lr.method_generic(n.children[0], mname, rest, rc, k);
        }
        case Nk.N_EXPR_IF:        return lr.if_(n, k);
        case Nk.N_EXPR_MATCH:     return lr.match_(n, k);
        case Nk.N_EXPR_WHILE:
        case Nk.N_EXPR_LOOP:
        case Nk.N_EXPR_FOR:       return lr.loop_(n, k);
        case Nk.N_EXPR_LAMBDA:    return lr.lambda(n, k);
        case Nk.N_EXPR_BINARY:    return lr.binop(n, k);
        case Nk.N_EXPR_UNARY:     return lr.unop(n, k);
        case Nk.N_BLOCK:          return lr.block_expr(n, k);
        case Nk.N_EXPR_REF:
        case Nk.N_EXPR_DEREF:     return lr.ref_deref(n, k);
        case Nk.N_EXPR_CAST:
        case Nk.N_EXPR_TRANSMUTE:
        {
            if (n.child_count > 0)
            {
                AirTyp* t = air_types::air_ty(lr.mod,
                    n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
                AirCns* ask = air_ir::air_mk_ascribe(lr.arena, t, k);
                lr.total_cns++;
                return lr.expr_to_cns(n.children[0], ask);
            }
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_ALLOC:
        {
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_var(lr.arena, lr.dup((char*)"alloc")), k);
        }
        case Nk.N_EXPR_FREE:
        {
            if (n.child_count > 0)
            {
                return lr.expr_to_cns(n.children[0],
                    air_ir::air_mk_stack(lr.arena,
                        air_ir::air_mk_var(lr.arena, lr.dup((char*)"free")), k));
            }
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_SIZEOF:
        {
            AirTyp* t = air_types::air_ty(lr.mod,
                n.type_ann != null ? n.type_ann : (n.child_count > 0 ? n.children[0] : null), lr.it);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_sizeof(lr.arena, t), k);
        }
        case Nk.N_EXPR_ALIGNOF:
        {
            AirTyp* t = air_types::air_ty(lr.mod,
                n.type_ann != null ? n.type_ann : (n.child_count > 0 ? n.children[0] : null), lr.it);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_alignof(lr.arena, t), k);
        }
        case Nk.N_EXPR_PERFORM:   return lr.perform(n, k);
        case Nk.N_EXPR_HANDLE:    return lr.handle(n, k);
        case Nk.N_EXPR_RESUME:
        {
            if (n.child_count > 0)
            {
                return lr.expr_to_cns(n.children[0],
                    air_ir::air_mk_covar(lr.arena, lr.dup((char*)"%resume")));
            }
            return lr.cut(lr.mod.p_unit,
                air_ir::air_mk_covar(lr.arena, lr.dup((char*)"%resume")));
        }
        case Nk.N_EXPR_UNSAFE:
        case Nk.N_EXPR_UNCHECKED: return lr.marker_block(n, k, ACMD_UNSAFE);
        case Nk.N_EXPR_COMPTIME:  return lr.marker_block(n, k, ACMD_COMPTIME);
        case Nk.N_EXPR_QUOTE:
        case Nk.N_EXPR_SPLICE:
        case Nk.N_EXPR_REIFY:
        case Nk.N_EXPR_EVAL:      return lr.msp_expr(n, k);
        case Nk.N_EXPR_ASSERT:
        case Nk.N_EXPR_ASSUME:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_POISON:
        case Nk.N_EXPR_UNREACHABLE:
        case Nk.N_EXPR_TRY:
        case Nk.N_EXPR_ASM:
        case Nk.N_EXPR_SYSCALL:
        case Nk.N_EXPR_ATOMIC:
        case Nk.N_EXPR_FENCE:
        case Nk.N_EXPR_VOLATILE:
        case Nk.N_EXPR_RANGE:
        case Nk.N_EXPR_ASSIGN:
        case Nk.N_EXPR_OFFSETOF:   return lr.control_expr(n, k);
        default:
        {
            // Unknown expression kind: emit a visible poison marker so the
            // .air file is obviously wrong rather than silently wrong.
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_poison(lr.arena, lr.mod.t_infer), k);
        }
    }
}

// ── Aggregate literals ──────────────────────────────────────────────────
// tuple_lit / array_lit / struct_lit: for each sub-element, if it's a value
// we use prd() directly; otherwise we μ̃-bind it to a fresh variable and
// sequence the evaluation, then plug all the (possibly-bound) vars into the
// tuple/array/record producer. This preserves the ANF shape.

fn AirCmd* AirLower.tuple_lit(AirLower* lr, Node* n, AirCns* k)
{
    AirPrd*[16] vars; usz vc = 0;
    AirCmd* binds = null;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (is_value_node(c))
        {
            vars[vc] = lr.prd(c);
        }
        else
        {
            char* xv = lr.fresh_x();
            vars[vc] = air_ir::air_mk_var(lr.arena, xv);
            AirCmd* ev = lr.expr_to_cns(c,
                air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
            binds = binds == null ? ev : air_ir::air_mk_seq(lr.arena, binds, ev);
        }
        vc = vc + 1;
    }
    lr.total_prd++;
    AirPrd* tup = air_ir::air_mk_tuple(lr.arena, &vars[0], vc);
    AirCmd* fin = lr.cut(tup, k);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.array_lit(AirLower* lr, Node* n, AirCns* k)
{
    AirPrd*[16] vars; usz vc = 0;
    AirCmd* binds = null;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (is_value_node(c))
        {
            vars[vc] = lr.prd(c);
        }
        else
        {
            char* xv = lr.fresh_x();
            vars[vc] = air_ir::air_mk_var(lr.arena, xv);
            AirCmd* ev = lr.expr_to_cns(c,
                air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
            binds = binds == null ? ev : air_ir::air_mk_seq(lr.arena, binds, ev);
        }
        vc = vc + 1;
    }
    lr.total_prd++;
    AirPrd* arr = air_ir::air_mk_array(lr.arena, &vars[0], vc);
    AirCmd* fin = lr.cut(arr, k);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.struct_lit(AirLower* lr, Node* n, AirCns* k)
{
    AirFieldInit*[16] inits; usz ic = 0;
    AirCmd* binds = null;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        AirFieldInit* fi = air_ir::air_new_AirFieldInit(lr.arena);
        if (c.kind == Nk.N_EXPR_FIELD_INIT)
        {
            char* fnm = node_text(lr, c);
            if (fnm == null) fnm = (char*)"f";
            fi.name = lr.dup(fnm);
            Node* val = c.child_count > 0 ? c.children[0] : null;
            AirPrd* vp;
            if (val != null && is_value_node(val))
            {
                vp = lr.prd(val);
            }
            else
            {
                char* xv = lr.fresh_x();
                vp = air_ir::air_mk_var(lr.arena, xv);
                if (val != null)
                {
                    AirCmd* ev = lr.expr_to_cns(val,
                        air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
                    binds = binds == null ? ev : air_ir::air_mk_seq(lr.arena, binds, ev);
                }
            }
            fi.value = vp;
        }
        else
        {
            char* xv = lr.fresh_x();
            AirPrd* vp;
            if (is_value_node(c))
            {
                vp = lr.prd(c);
            }
            else
            {
                vp = air_ir::air_mk_var(lr.arena, xv);
                AirCmd* ev = lr.expr_to_cns(c,
                    air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
                binds = binds == null ? ev : air_ir::air_mk_seq(lr.arena, binds, ev);
            }
            fi.name = lr.fmt((char*)"_f%ld", (long)i);
            fi.value = vp;
        }
        fi.id = 0;
        inits[ic] = fi; ic = ic + 1;
    }
    AirPrd* rec = air_ir::air_new_AirPrd(lr.arena);
    rec.tag = APRD_RECORD;
    rec.rec_init_count = 0;
    for (usz i = 0; i < ic && i < 16; i++)
    {
        rec.rec_inits[rec.rec_init_count] = inits[i];
        rec.rec_init_count = rec.rec_init_count + 1;
    }
    lr.total_prd++;
    AirCmd* fin = lr.cut(rec, k);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

// ── Calls / fields / index ─────────────────────────────────────────────
// call(callee, args, ac, k): evaluate callee, evaluate args right-to-left,
// then cut < callee_v | (argN · ... · arg1 · k) > which is the λμμ̃ encoding
// of multi-argument application.  air_mk_call reverses the args onto a STACK
// chain and tags the outermost as ACNS_CALL so the emitter prints (a1,...,an).

fn AirCmd* AirLower.call(AirLower* lr, Node* callee, Node** args, usz ac, AirCns* k)
{
    AirPrd*[16] avars; usz vc = 0;
    AirCmd* binds = null;
    lr.scope.enter();
    AirPrd* callee_v;
    if (is_value_node(callee))
    {
        callee_v = lr.prd(callee);
    }
    else
    {
        char* cv = lr.fresh_x();
        callee_v = air_ir::air_mk_var(lr.arena, cv);
        AirCmd* ec = lr.expr_to_cns(callee,
            air_ir::air_mk_comu_cns(lr.arena, cv, lr.nop()));
        binds = ec;
    }
    for (usz i = 0; i < ac && i < 16; i++)
    {
        Node* a = args[i];
        if (a == null) { avars[vc] = lr.mod.p_unit; }
        else if (is_value_node(a)) { avars[vc] = lr.prd(a); }
        else
        {
            char* xv = lr.fresh_x();
            avars[vc] = air_ir::air_mk_var(lr.arena, xv);
            AirCmd* ea = lr.expr_to_cns(a,
                air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
            binds = binds == null ? ea : air_ir::air_mk_seq(lr.arena, binds, ea);
        }
        vc = vc + 1;
    }
    lr.total_cns++;
    AirCns* call_k = air_ir::air_mk_call(lr.arena, &avars[0], vc, k);
    AirCmd* fin = lr.cut(callee_v, call_k);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.method_generic(AirLower* lr, Node* recv, char* mname, Node** args, usz ac, AirCns* k)
{
    AirPrd* rv; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(recv))
    {
        rv = lr.prd(recv);
    }
    else
    {
        char* rv2 = lr.fresh_x();
        rv = air_ir::air_mk_var(lr.arena, rv2);
        binds = lr.expr_to_cns(recv,
            air_ir::air_mk_comu_cns(lr.arena, rv2, lr.nop()));
    }
    AirPrd*[16] avars; usz vc = 0;
    for (usz i = 0; i < ac && i < 16; i++)
    {
        Node* a = args[i];
        if (a == null) { avars[vc] = lr.mod.p_unit; }
        else if (is_value_node(a)) { avars[vc] = lr.prd(a); }
        else
        {
            char* xv = lr.fresh_x();
            avars[vc] = air_ir::air_mk_var(lr.arena, xv);
            AirCmd* ea = lr.expr_to_cns(a,
                air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
            binds = binds == null ? ea : air_ir::air_mk_seq(lr.arena, binds, ea);
        }
        vc = vc + 1;
    }
    lr.total_cns++;
    AirCns* args_k = air_ir::air_mk_call(lr.arena, &avars[0], vc, k);
    lr.total_cns++;
    AirCns* proj = air_ir::air_mk_field_cns(lr.arena, lr.dup(mname), args_k);
    AirCmd* fin = lr.cut(rv, proj);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.field_acc(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
    char* f = node_text(lr, n);
    if (f == null) f = (char*)"f";
    lr.total_cns++;
    AirCns* proj = air_ir::air_mk_field_cns(lr.arena, lr.dup(f), k);
    return lr.expr_to_cns(n.children[0], proj);
}

fn AirCmd* AirLower.index_acc(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    AirPrd* ov; AirPrd* iv; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        ov = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        ov = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    if (is_value_node(n.children[1]))
    {
        iv = lr.prd(n.children[1]);
    }
    else
    {
        char* xv = lr.fresh_x();
        iv = air_ir::air_mk_var(lr.arena, xv);
        AirCmd* ei = lr.expr_to_cns(n.children[1],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
        binds = binds == null ? ei : air_ir::air_mk_seq(lr.arena, binds, ei);
    }
    lr.total_cns++;
    AirCns* ik = air_ir::air_mk_index(lr.arena, iv, k);
    AirCmd* fin = lr.cut(ov, ik);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

// ── Operators ──────────────────────────────────────────────────────────
// binop: for non-short-circuit binary ops (arithmetic, bitwise, comparison),
// evaluate both sides (let-binding non-value sub-exprs), then cut against
// a binary-op producer <binop(l,r)|k>.
// shortcircuit_and/or: desugar into if (lhs) rhs else false/true, which
// gives the natural short-circuit semantics without needing special ops.
// unop: negation / bitwise-not / logical-not / deref / address-of.  Deref
// is special: it produces an ACNS_DEREF consumer so the emitter prints
// *x rather than a unary function call.

fn AirCmd* AirLower.binop(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    long op = n.p.op;
    if ((Tk)op == Tk.TOKEN_AMPAMP) return lr.shortcircuit_and(n, k);
    if ((Tk)op == Tk.TOKEN_PIPEPIPE) return lr.shortcircuit_or(n, k);
    AirBinop b = token_to_binop(op);
    AirPrd* l; AirPrd* r; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        l = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        l = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    if (is_value_node(n.children[1]))
    {
        r = lr.prd(n.children[1]);
    }
    else
    {
        char* xv = lr.fresh_x();
        r = air_ir::air_mk_var(lr.arena, xv);
        AirCmd* er = lr.expr_to_cns(n.children[1],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
        binds = binds == null ? er : air_ir::air_mk_seq(lr.arena, binds, er);
    }
    lr.total_prd++;
    AirPrd* bp = air_ir::air_mk_binop(lr.arena, b, l, r);
    AirCmd* fin = lr.cut(bp, k);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.shortcircuit_and(AirLower* lr, Node* n, AirCns* k)
{
    // l && r  ≡  if l then r else false
    if (n.child_count < 2) return lr.cut(lr.mod.p_false, k);
    AirPrd* ap; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        ap = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        ap = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    AirCmd* thn = lr.expr_to_cns(n.children[1], k);
    AirCmd* els = lr.cut(lr.mod.p_false, k);
    AirCmd* iff = air_ir::air_mk_if(lr.arena, ap, thn, els);
    lr.scope.leave();
    return binds == null ? iff : air_ir::air_mk_seq(lr.arena, binds, iff);
}

fn AirCmd* AirLower.shortcircuit_or(AirLower* lr, Node* n, AirCns* k)
{
    // l || r  ≡  if l then true else r
    if (n.child_count < 2) return lr.cut(lr.mod.p_true, k);
    AirPrd* ap; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        ap = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        ap = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    AirCmd* thn = lr.cut(lr.mod.p_true, k);
    AirCmd* els = lr.expr_to_cns(n.children[1], k);
    AirCmd* iff = air_ir::air_mk_if(lr.arena, ap, thn, els);
    lr.scope.leave();
    return binds == null ? iff : air_ir::air_mk_seq(lr.arena, binds, iff);
}

fn AirCmd* AirLower.unop(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
    long op = n.p.op;
    AirUnop u = AUN_NEG;
    switch ((Tk)op)
    {
        case TOKEN_MINUS: u = AUN_NEG; break;
        case TOKEN_BANG:  u = AUN_NOT; break;
        case TOKEN_TILDE: u = AUN_BITNOT; break;
        case TOKEN_STAR:  u = AUN_DEREF; break;
        case TOKEN_AMP:   u = AUN_ADDR; break;
        default: u = AUN_NEG;
    }
    AirPrd* v; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        v = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        v = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    AirCmd* fin;
    if (u == AUN_DEREF)
    {
        // Deref is a consumer: < v | deref·k >
        AirCns* dk = air_ir::air_new_AirCns(lr.arena);
        dk.tag = ACNS_DEREF; dk.tail = k;
        lr.total_cns++;
        fin = lr.cut(v, dk);
    }
    else
    {
        lr.total_prd++;
        AirPrd* up = air_ir::air_mk_unop(lr.arena, u, v);
        fin = lr.cut(up, k);
    }
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.ref_deref(AirLower* lr, Node* n, AirCns* k)
{
    return lr.unop(n, k);
}

// ── Control flow ───────────────────────────────────────────────────────
// if/then/else: build an ACMD_IF sugar command; lowered as <p|case{true→thn;false→els}>
// match: build a case consumer over the scrutinee with one branch per arm
// loop: while/loop/for via labels and jumps (see design comments at top of file)
// lambda: APRD_LAMBDA producer wrapping a μ̃%ret body

fn AirCmd* AirLower.if_(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    AirPrd* cp; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        cp = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        cp = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    lr.scope.enter();
    AirCmd* thn = lr.expr_to_cns(n.children[1], k);
    lr.scope.leave();
    lr.scope.enter();
    AirCmd* els;
    if (n.child_count > 2)
    {
        els = lr.expr_to_cns(n.children[2], k);
    }
    else
    {
        els = lr.cut(lr.mod.p_unit, k);
    }
    lr.scope.leave();
    AirCmd* iff = air_ir::air_mk_if(lr.arena, cp, thn, els);
    AirCmd* out = binds == null ? iff : air_ir::air_mk_seq(lr.arena, binds, iff);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.match_(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
    AirPrd* scr; AirCmd* binds = null;
    lr.scope.enter();
    if (is_value_node(n.children[0]))
    {
        scr = lr.prd(n.children[0]);
    }
    else
    {
        char* xv = lr.fresh_x();
        scr = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    AirBranch*[64] bs; usz bc = 0;
    for (usz i = 1; i < n.child_count && bc < 64; i++)
    {
        Node* arm = n.children[i];
        if (arm == null) continue;
        lr.scope.enter();
        AirPat* pat = lr.mod.pat_wild;
        AirCmd* body = lr.cut(lr.mod.p_unit, k);
        if (arm.child_count > 0)
        {
            pat = lr.pat(arm.children[0]);
            body = null;
            for (usz j = 1; j < arm.child_count; j++)
            {
                if (arm.children[j] == null) continue;
                AirCmd* cb;
                if (pfront_core::is_expr(arm.children[j].kind))
                {
                    cb = lr.expr_to_cns(arm.children[j], k);
                }
                else
                {
                    cb = lr.cmd_cns(arm.children[j], k);
                }
                body = body == null ? cb : air_ir::air_mk_seq(lr.arena, body, cb);
            }
            if (body == null) body = lr.cut(lr.mod.p_unit, k);
        }
        AirBranch* br = air_ir::air_mk_branch(lr.arena, pat, body);
        bs[bc] = br; bc = bc + 1;
        lr.scope.leave();
    }
    if (bc == 0)
    {
        bs[0] = air_ir::air_mk_branch(lr.arena, lr.mod.pat_wild, air_ir::air_mk_trap(lr.arena));
        bc = 1;
    }
    lr.total_cns++;
    AirCns* cs = air_ir::air_mk_case(lr.arena, &bs[0], bc);
    AirCmd* fin = lr.cut(scr, cs);
    AirCmd* out = binds == null ? fin : air_ir::air_mk_seq(lr.arena, binds, fin);
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.loop_(AirLower* lr, Node* n, AirCns* k)
{
    lr.scope.enter();
    char* brk = lr.fresh_lbl("exit");
    char* cont = lr.fresh_lbl("loop");
    lr.scope.push_loop(brk, cont);

    Node* cond; Node* body;
    if (n.kind == Nk.N_EXPR_WHILE)
    {
        cond = n.child_count > 0 ? n.children[0] : null;
        body = n.child_count > 1 ? n.children[1] : null;
    }
    else if (n.kind == Nk.N_EXPR_LOOP)
    {
        cond = null;
        body = n.child_count > 0 ? n.children[0] : null;
    }
    else
    {
        cond = null;
        body = n;
    }

    AirCmd* body_cmd;
    if (body == null)
    {
        body_cmd = air_ir::air_mk_jump0(lr.arena, cont);
    }
    else
    {
        lr.scope.enter();
        char* ignore = lr.fresh_x();
        AirCns* drop_k = air_ir::air_mk_comu_cns(lr.arena, ignore,
            air_ir::air_mk_jump0(lr.arena, cont));
        body_cmd = lr.expr_to_cns(body, drop_k);
        lr.scope.leave();
    }
    AirBranch*[2] bs;
    bs[0] = air_ir::air_mk_branch(lr.arena, air_ir::air_mk_pat_bool(lr.arena, true), body_cmd);
    lr.jumps++;
    bs[1] = air_ir::air_mk_branch(lr.arena, air_ir::air_mk_pat_bool(lr.arena, false),
        air_ir::air_mk_jump0(lr.arena, brk));
    AirPrd* cond_prd;
    if (cond == null)
    {
        cond_prd = lr.mod.p_true;
    }
    else
    {
        cond_prd = lr.prd_or_bind(cond);
    }
    lr.total_cns++;
    AirCmd* cond_cut = lr.cut(cond_prd, air_ir::air_mk_case(lr.arena, &bs[0], 2));
    AirBinder*[1] no_args_arr;
    no_args_arr[0] = null;
    lr.labels++;
    AirCmd* loop_lbl = air_ir::air_mk_label(lr.arena, cont, &no_args_arr[0], 0, cond_cut);
    lr.jumps++;
    AirCmd* jmp_loop = air_ir::air_mk_jump0(lr.arena, cont);
    AirCmd* exit_body = lr.cut(lr.mod.p_unit, k);
    lr.labels++;
    AirCmd* exit_lbl = air_ir::air_mk_label(lr.arena, brk, &no_args_arr[0], 0, exit_body);
    AirCmd* out = air_ir::air_mk_seq(lr.arena,
        air_ir::air_mk_seq(lr.arena, exit_lbl,
            air_ir::air_mk_seq(lr.arena, loop_lbl, jmp_loop)), null);
    lr.scope.pop_loop();
    lr.scope.leave();
    lr.labels = lr.labels + 2; lr.jumps = lr.jumps + 2;
    return out;
}

fn AirCmd* AirLower.lambda(AirLower* lr, Node* n, AirCns* k)
{
    lr.scope.enter();
    AirBinder*[16] bv; usz bc = 0;
    for (usz i = 0; i < n.child_count && bc < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM)
        {
            char* pnm = (char*)"_";
            AirTyp* pty = lr.mod.t_infer;
            if (c.child_count > 0)
            {
                Node* pp = c.children[0];
                pnm = node_text(lr, pp);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) pty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            bc = bc + 1;
        }
        else if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_EXPR_IDENT)
        {
            char* pnm = node_text(lr, c);
            if (pnm == null) pnm = (char*)"_";
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, lr.mod.t_infer, AMULT_UNR);
            bc = bc + 1;
        }
    }
    char* ret = lr.scope.bind_covar("%ret", null);
    lr.scope.push_ret(ret);
    AirCmd* body = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_PAT_IDENT
         || c.kind == Nk.N_EXPR_IDENT || c.kind == Nk.N_PAT_WILDCARD) continue;
        body = lr.cmd(c, ret);
        break;
    }
    if (body == null) body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
    lr.scope.pop_ret();
    lr.total_prd++;
    AirPrd* lam = air_ir::air_mk_lambda(lr.arena, &bv[0], bc, body);
    lr.scope.leave();
    return lr.cut(lam, k);
}

fn AirCmd* AirLower.marker_block(AirLower* lr, Node* n, AirCns* k, AirCmdTag tag)
{
    lr.scope.enter();
    AirCmd* body;
    if (n.child_count > 0)
    {
        body = lr.expr_to_cns(n.children[0], k);
    }
    else
    {
        body = lr.cut(lr.mod.p_unit, k);
    }
    lr.scope.leave();
    AirCmd* m = air_ir::air_new_AirCmd(lr.arena);
    m.tag = tag; m.body = body;
    m.prd = null; m.cns = null; m.next = null;
    lr.total_cmd++;
    return m;
}

fn AirCmd* AirLower.msp_expr(AirLower* lr, Node* n, AirCns* k)
{
    // Multi-stage programming: quote/splice/reify/eval. These are preserved
    // as primitive var cuts after the theory layer has already staged them.
    char* nm;
    switch (n.kind)
    {
        case Nk.N_EXPR_QUOTE:  nm = (char*)"quote"; break;
        case Nk.N_EXPR_SPLICE: nm = (char*)"splice"; break;
        case Nk.N_EXPR_REIFY:  nm = (char*)"reify"; break;
        default:              nm = (char*)"eval"; break;
    }
    lr.total_prd++;
    AirPrd* prim = air_ir::air_mk_var(lr.arena, lr.dup(nm));
    if (n.child_count > 0)
    {
        char* xv = lr.fresh_x();
        AirCmd* sub_cmd = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_stack(lr.arena, air_ir::air_mk_var(lr.arena, xv), k));
        AirCmd* bv = lr.cut(prim,
            air_ir::air_mk_stack(lr.arena, air_ir::air_mk_var(lr.arena, xv), k));
        lr.mutilde++;
        return air_ir::air_mk_mutilde(lr.arena, xv,
            air_ir::air_mk_seq(lr.arena, sub_cmd, bv));
    }
    return lr.cut(prim, k);
}

fn AirCmd* AirLower.control_expr(AirLower* lr, Node* n, AirCns* k)
{
    switch (n.kind)
    {
        case Nk.N_EXPR_ASSERT:
        {
            if (n.child_count > 0)
            {
                AirPrd* p = lr.prd_or_bind(n.children[0]);
                return air_ir::air_mk_seq(lr.arena, air_ir::air_mk_assert(lr.arena, p), lr.cut(lr.mod.p_unit, k));
            }
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_ASSUME:
        {
            if (n.child_count > 0)
            {
                AirPrd* p = lr.prd_or_bind(n.children[0]);
                return air_ir::air_mk_seq(lr.arena, air_ir::air_mk_assume(lr.arena, p), lr.cut(lr.mod.p_unit, k));
            }
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_UB:
        {
            return air_ir::air_mk_ub(lr.arena, n.p.sptr);
        }
        case Nk.N_EXPR_TRAP: return air_ir::air_mk_trap(lr.arena);
        case Nk.N_EXPR_POISON:
        {
            AirTyp* t = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_poison(lr.arena, t), k);
        }
        case Nk.N_EXPR_UNREACHABLE:
        {
            return air_ir::air_mk_ub(lr.arena, lr.dup((char*)"unreachable"));
        }
        case Nk.N_EXPR_TRY:
        {
            if (n.child_count > 0) return lr.expr_to_cns(n.children[0], k);
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_ASM:
        {
            AirCmd* c = air_ir::air_new_AirCmd(lr.arena);
            c.tag = ACMD_ASM;
            if (n.child_count > 0 && n.children[0].p.sptr != null)
            {
                c.asm_text = lr.dup(n.children[0].p.sptr);
            }
            else
            {
                c.asm_text = lr.dup((char*)"");
            }
            c.asm_dialect = n.p.aux; c.next = null;
            lr.total_cmd++;
            return air_ir::air_mk_seq(lr.arena, c, lr.cut(lr.mod.p_unit, k));
        }
        case Nk.N_EXPR_SYSCALL:
        {
            AirCmd* c = air_ir::air_new_AirCmd(lr.arena);
            c.tag = ACMD_SYSCALL; c.next = null; lr.total_cmd++;
            return air_ir::air_mk_seq(lr.arena, c, lr.cut(lr.mod.p_unit, k));
        }
        case Nk.N_EXPR_ATOMIC:
        {
            AirCmd* c = air_ir::air_new_AirCmd(lr.arena);
            c.tag = ACMD_ATOMIC; c.atomic_op = n.p.op; c.atomic_order = (int)n.p.ival; c.next = null;
            lr.total_cmd++;
            return air_ir::air_mk_seq(lr.arena, c, lr.cut(lr.mod.p_unit, k));
        }
        case Nk.N_EXPR_FENCE:
        {
            AirCmd* c = air_ir::air_new_AirCmd(lr.arena);
            c.tag = ACMD_FENCE; c.atomic_order = (int)n.p.ival; c.next = null; lr.total_cmd++;
            return air_ir::air_mk_seq(lr.arena, c, lr.cut(lr.mod.p_unit, k));
        }
        case Nk.N_EXPR_VOLATILE:
        {
            if (n.child_count > 0) return lr.expr_to_cns(n.children[0], k);
            return lr.cut(lr.mod.p_unit, k);
        }
        case Nk.N_EXPR_RANGE:
        {
            AirPrd*[2] args; usz ac = 0;
            if (n.child_count > 0) { args[0] = lr.prd_or_bind(n.children[0]); ac++; }
            if (n.child_count > 1) { args[1] = lr.prd_or_bind(n.children[1]); ac++; }
            lr.total_prd++;
            AirPrd* rng = air_ir::air_mk_con(lr.arena, lr.dup((char*)"Range"));
            for (usz i = 0; i < ac; i++) rng.add_sub(args[i]);
            return lr.cut(rng, k);
        }
        case Nk.N_EXPR_ASSIGN:
        {
            return lr.assign_expr(n, k);
        }
        case Nk.N_EXPR_OFFSETOF:
        {
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_sizeof(lr.arena, lr.mod.t_usz), k);
        }
        default: return lr.cut(lr.mod.p_unit, k);
    }
}

fn AirCmd* AirLower.perform(AirLower* lr, Node* n, AirCns* k)
{
    char* op = (char*)"op";
    AirPrd* payload = lr.mod.p_unit;
    if (n.child_count > 0)
    {
        Node* head = n.children[0];
        if (head.kind == Nk.N_EXPR_PATH || head.kind == Nk.N_EXPR_IDENT)
        {
            op = node_text(lr, head);
        }
    }
    if (op == null) op = (char*)"op";
    char* op2 = lr.dup(op);
    AirPrd*[16] av; usz ac = 0;
    AirCmd* binds = null;
    lr.scope.enter();
    for (usz i = 1; i < n.child_count && ac < 16; i++)
    {
        Node* a = n.children[i];
        if (a == null) continue;
        if (is_value_node(a))
        {
            av[ac] = lr.prd(a);
        }
        else
        {
            char* xv = lr.fresh_x();
            av[ac] = air_ir::air_mk_var(lr.arena, xv);
            AirCmd* ea = lr.expr_to_cns(a,
                air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
            binds = binds == null ? ea : air_ir::air_mk_seq(lr.arena, binds, ea);
        }
        ac = ac + 1;
    }
    if (ac == 1)
    {
        payload = av[0];
    }
    else if (ac > 1)
    {
        lr.total_prd++;
        payload = air_ir::air_mk_tuple(lr.arena, &av[0], ac);
    }
    AirCmd* perf = air_ir::air_mk_perform(lr.arena, op2, payload);
    AirCmd* next = lr.cut(lr.mod.p_unit, k);
    AirCmd* out = air_ir::air_mk_seq(lr.arena, perf, next);
    lr.scope.leave();
    return binds == null ? out : air_ir::air_mk_seq(lr.arena, binds, out);
}

fn AirCmd* AirLower.handle(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    AirCmd* comp;
    lr.scope.enter();
    if (pfront_core::is_expr(n.children[0].kind))
    {
        comp = lr.expr_to_cns(n.children[0], k);
    }
    else
    {
        comp = lr.cmd_cns(n.children[0], k);
    }
    AirBranch*[64] bs; usz bc = 0;
    for (usz i = 1; i < n.child_count && bc < 64; i++)
    {
        Node* arm = n.children[i];
        if (arm == null) continue;
        lr.scope.enter();
        AirPat* pat = lr.mod.pat_wild;
        if (arm.child_count > 0) pat = lr.pat(arm.children[0]);
        AirCmd* body = lr.cut(lr.mod.p_unit, k);
        for (usz j = 1; j < arm.child_count; j++)
        {
            if (arm.children[j] == null) continue;
            AirCmd* cb;
            if (pfront_core::is_expr(arm.children[j].kind))
            {
                cb = lr.expr_to_cns(arm.children[j], k);
            }
            else
            {
                cb = lr.cmd_cns(arm.children[j], k);
            }
            body = air_ir::air_mk_seq(lr.arena, body, cb);
        }
        bs[bc] = air_ir::air_mk_branch(lr.arena, pat, body);
        bc = bc + 1;
        lr.scope.leave();
    }
    AirCmd* h = air_ir::air_mk_handle(lr.arena, comp, &bs[0], bc);
    lr.scope.leave();
    return h;
}

fn AirCmd* AirLower.assign_stmt(AirLower* lr, Node* n, char* k)
{
    return lr.assign_expr(n, lr.cns_k(k));
}

fn AirCmd* AirLower.assign_expr(AirLower* lr, Node* n, AirCns* k)
{
    // Placeholder assignment: evaluate RHS and cut against k.
    // Full store semantics will come when we model ML-variables / ref cells.
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    Node* rhs = n.children[1];
    (void)n.children[0]; // lhs reserved
    lr.scope.enter();
    AirPrd* rv; AirCmd* binds = null;
    if (is_value_node(rhs))
    {
        rv = lr.prd(rhs);
    }
    else
    {
        char* xv = lr.fresh_x();
        rv = air_ir::air_mk_var(lr.arena, xv);
        binds = lr.expr_to_cns(rhs,
            air_ir::air_mk_comu_cns(lr.arena, xv, lr.nop()));
    }
    AirCmd* store = lr.cut(rv, k);
    AirCmd* out = binds == null ? store : air_ir::air_mk_seq(lr.arena, binds, store);
    lr.scope.leave();
    return out;
}

// ── Declarations ───────────────────────────────────────────────────────
// Each decl_* method builds an AirDecl* for a top-level declaration: fn,
// extern fn, struct, enum, type alias, let/const, effect. All top-level
// defs wrap their body in μ̃%ret.body which binds the return covariable.
// Structs become codata (destructors per field); enums become data
// (constructors per variant); effects become ADECL_EFFECT with op list.

fn AirDecl* AirLower.decl(AirLower* lr, Node* n)
{
    if (n == null) return null;
    switch (n.kind)
    {
        case Nk.N_DECL_FN:         return lr.decl_fn(n);
        case Nk.N_DECL_EXTERN_FN:  return lr.decl_extern(n);
        case Nk.N_DECL_STRUCT:
        case Nk.N_DECL_UNION:
        case Nk.N_DECL_NEWTYPE:
        case Nk.N_DECL_INTERFACE:  return lr.decl_struct(n);
        case Nk.N_DECL_ENUM:       return lr.decl_enum(n);
        case Nk.N_DECL_TYPE:       return lr.decl_type(n);
        case Nk.N_DECL_LET:
        case Nk.N_DECL_CONST:
        case Nk.N_DECL_STATIC:     return lr.decl_letconst(n);
        case Nk.N_DECL_EFFECT:     return lr.decl_effect(n);
        case Nk.N_DECL_IMPL:       return null;  // impls are compile-time dict tables
        default: return null;
    }
}

fn AirDecl* AirLower.decl_fn(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"_fn";
    char* nm2 = lr.dup(nm);
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DEF, nm2);
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    d.ret_ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
    lr.scope.enter();
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_TYPEPARAM)
        {
            char* tn = node_text(lr, c);
            if (tn == null) tn = (char*)"T";
            char* ta = lr.scope.bind_var(tn, c);
            AirBinder* tb = air_ir::air_mk_binder(lr.arena, ta, lr.mod.t_infer, AMULT_UNR);
            d.add_typaram(tb);
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM)
        {
            char* pnm = (char*)"_";
            AirTyp* pty = lr.mod.t_infer;
            if (c.child_count > 0)
            {
                Node* pp = c.children[0];
                pnm = node_text(lr, pp);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) pty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            char* an = lr.scope.bind_var(pnm, c);
            AirBinder* pb = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            d.add_param(pb);
        }
    }
    char* ret = lr.scope.bind_covar("%ret", n);
    lr.scope.push_ret(ret);
    AirCmd* body = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_DECL_TYPEPARAM) continue;
        if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_TY_NAME) continue;
        AirCmd* cm;
        bool is_last = true;
        for (usz j = i + 1; j < n.child_count; j++)
        {
            Node* c2 = n.children[j];
            if (c2 == null) continue;
            if (c2.kind == Nk.N_DECL_PARAM || c2.kind == Nk.N_DECL_TYPEPARAM
             || c2.kind == Nk.N_PAT_IDENT || c2.kind == Nk.N_TY_NAME) continue;
            is_last = false;
            break;
        }
        if (is_last && pfront_core::is_expr(c.kind))
        {
            cm = lr.expr_to_cns(c, lr.cns_k(ret));
        }
        else
        {
            cm = lr.cmd(c, ret);
        }
        body = body == null ? cm : air_ir::air_mk_seq(lr.arena, body, cm);
    }
    if (body == null) body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
    lr.scope.pop_ret();
    lr.mutilde++;
    d.def_body = air_ir::air_mk_mutilde(lr.arena, ret, body);
    lr.scope.leave();
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_extern(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"extern";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DECLARE, lr.dup(nm));
    d.is_extern = true;
    d.ret_ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM)
        {
            char* pnm = (char*)"_";
            AirTyp* ty = lr.mod.t_infer;
            if (c.type_ann != null) ty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            if (c.child_count > 0)
            {
                Node* pp = c.children[0];
                pnm = node_text(lr, pp);
                if (pnm == null) pnm = (char*)"_";
            }
            AirBinder* pb = air_ir::air_mk_binder(lr.arena, lr.dup(pnm), ty, AMULT_UNR);
            d.add_param(pb);
        }
    }
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_struct(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"S";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_CODATA, lr.dup(nm));
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* f = n.children[i];
        if (f == null) continue;
        if (f.kind != Nk.N_DECL_FIELD) continue;
        char* fnm = node_text(lr, f);
        if (fnm == null) fnm = (char*)"f";
        AirDtorDecl* dd = air_ir::air_mk_dtor_decl(lr.arena, lr.dup(fnm));
        AirTyp* fty = air_types::air_ty(lr.mod, f.type_ann != null ? f.type_ann : f.type_slot, lr.it);
        dd.return_ty = fty;
        d.add_dtor(dd);
    }
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_enum(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"E";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DATA, lr.dup(nm));
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* v = n.children[i];
        if (v == null) continue;
        if (v.kind != Nk.N_DECL_VARIANT) continue;
        char* vnm = node_text(lr, v);
        if (vnm == null) vnm = (char*)"V";
        AirCtorDecl* ct = air_ir::air_mk_ctor_decl(lr.arena, lr.dup(vnm));
        for (usz j = 0; j < v.child_count; j++)
        {
            Node* a = v.children[j];
            if (a == null) continue;
            AirTyp* at;
            if (a.kind == Nk.N_DECL_FIELD)
            {
                at = air_types::air_ty(lr.mod, a.type_ann != null ? a.type_ann : a.type_slot, lr.it);
            }
            else
            {
                at = air_types::air_ty(lr.mod, a, lr.it);
            }
            char* fnm = lr.fmt((char*)"_%ld", (long)j);
            AirField* af = air_ir::air_mk_field(lr.arena, fnm, at, AMULT_UNR);
            ct.add_field(af);
        }
        ct.result_ty = air_ir::air_mk_typ_named(lr.arena, lr.dup(nm));
        d.add_ctor(ct);
    }
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_type(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"T";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DECLARE, lr.dup(nm));
    d.ret_ty = lr.mod.t_infer;
    if (n.child_count > 0 && n.children[0] != null)
    {
        d.ret_ty = air_types::air_ty(lr.mod, n.children[0], lr.it);
    }
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_letconst(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"_c";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DEF, lr.dup(nm));
    d.ret_ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
    lr.scope.enter();
    char* ret = lr.scope.bind_covar("%ret", null);
    lr.scope.push_ret(ret);
    AirCmd* body = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_DECL_TYPEPARAM) continue;
        if (c.kind == Nk.N_PAT_IDENT) continue;
        if (pfront_core::is_expr(c.kind))
        {
            body = lr.expr_to_cns(c, lr.cns_k(ret));
        }
        else
        {
            body = lr.cmd(c, ret);
        }
        break;
    }
    if (body == null) body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
    lr.scope.pop_ret();
    lr.mutilde++;
    d.def_body = air_ir::air_mk_mutilde(lr.arena, ret, body);
    lr.scope.leave();
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_effect(AirLower* lr, Node* n)
{
    char* nm = node_text(lr, n);
    if (nm == null) nm = (char*)"Eff";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_EFFECT, lr.dup(nm));
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* op = n.children[i];
        if (op == null) continue;
        if (op.kind != Nk.N_DECL_EFFECT_OP) continue;
        char* onm = node_text(lr, op);
        if (onm == null) onm = (char*)"op";
        AirTyp* sig = air_types::air_ty(lr.mod, op.type_ann != null ? op.type_ann : op.type_slot, lr.it);
        AirEffectOp* aop = air_ir::air_mk_eff_op(lr.arena, lr.dup(onm), sig);
        d.add_op(aop);
    }
    lr.total_decl++;
    return d;
}

// cmd_cns — run a statement node, ensuring its final value feeds into the
// consumer k. Terminal statements (return/break/continue/trap/ub) don't need
// the μα wrapper — we call cmd() with a fresh dummy covar they never reach.
fn AirCmd* AirLower.cmd_cns(AirLower* lr, Node* n, AirCns* k)
{
    if (n == null) return lr.cut(lr.mod.p_unit, k);
    switch (n.kind)
    {
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_UNREACHABLE:
        {
            char* d = lr.fresh_k();
            return lr.cmd(n, d);
        }
        default: break;
    }
    if (pfront_core::is_expr(n.kind)) return lr.expr_to_cns(n, k);
    return lr.block_expr(n, k);
}

// block_expr — block used in expression position, feeding the result into
// an AirCns* continuation (allocates a fresh μα and calls stmts() against it).
fn AirCmd* AirLower.block_expr(AirLower* lr, Node* n, AirCns* k)
{
    if (n == null) return lr.cut(lr.mod.p_unit, k);
    char* alpha = lr.fresh_k();
    lr.scope.enter();
    AirCmd* body = lr.stmts(n, alpha, true);
    lr.mu++;
    AirPrd* mu_p = air_ir::air_mk_mu_prd(lr.arena, alpha, body);
    AirCmd* out = lr.cut(mu_p, k);
    lr.scope.leave();
    return out;
}

// is_terminal_cmd_node — nodes that never return (dead code after them elided).
fn bool is_terminal_cmd_node(Node* n)
{
    if (n == null) return false;
    switch (n.kind)
    {
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_UNREACHABLE:
            return true;
        case Nk.N_STMT_EXPR:
        case Nk.N_BLOCK:
        {
            // A block/stmt-expr is terminal if its LAST non-null child is.
            long last = (long)n.child_count - 1;
            while (last >= 0 && n.children[(usz)last] == null) last--;
            if (last < 0) return false;
            return is_terminal_cmd_node(n.children[(usz)last]);
        }
        default: return false;
    }
}

// ============================================================================
// Module-body driver (entry)
// ============================================================================
fn void AirLower.walk_decls(AirLower* lr, Node* n)
{
    if (n == null) return;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        switch (c.kind)
        {
            case Nk.N_MODULE:
            case Nk.N_PROGRAM:
            {
                char* mnm = node_text(lr, c);
                if (mnm != null && lr.mod.name != null)
                {
                    bool is_main = true;
                    char* p = lr.mod.name;
                    if (p[0] != 'm' || p[1] != 'a' || p[2] != 'i' || p[3] != 'n' || p[4] != 0) is_main = false;
                    if (is_main) lr.mod.name = lr.dup(mnm);
                }
                lr.walk_decls(c);
                continue;
            }
            case Nk.N_USE:
            {
                char* ipath = node_text(lr, c);
                if (ipath == null) ipath = (char*)"?";
                char* als = null;
                bool glob = false;
                for (usz j = 0; j < c.child_count; j++)
                {
                    Node* cc = c.children[j];
                    if (cc == null) continue;
                    if (cc.kind == Nk.N_USE_ITEM || cc.kind == Nk.N_MODULE_PATH)
                    {
                        char* inm = node_text(lr, cc);
                        if (inm != null && als == null) als = inm;
                        for (usz k2 = 0; k2 < cc.child_count; k2++)
                        {
                            Node* cck = cc.children[k2];
                            if (cck == null) continue;
                            char* tnm = node_text(lr, cck);
                            if (tnm != null && tnm[0] == '*' && tnm[1] == 0) glob = true;
                        }
                    }
                }
                AirDecl* imp = air_ir::air_mk_import(lr.arena, lr.dup(ipath),
                    als != null ? lr.dup(als) : null, glob);
                lr.mod.add_decl(imp);
                lr.total_decl++;
                continue;
            }
            case Nk.N_DOC: continue;
            default: break;
        }
        if (pfront_core::is_decl(c.kind))
        {
            lr.decl_inner(c);
        }
        else
        {
            lr.walk_decls(c);
        }
    }
}

fn void AirLower.module_body(AirLower* lr, Node* root)
{
    if (root == null) return;
    lr.walk_decls(root);
}

fn bool is_nop_cmd(AirCmd* c)
{
    if (c == null) return true;
    if (c.tag == ACMD_NOP) return true;
    return false;
}

fn AirCmd* AirLower.seq(AirLower* lr, AirCmd* a, AirCmd* b)
{
    if (is_nop_cmd(a)) return b;
    if (is_nop_cmd(b)) return a;
    return air_ir::air_mk_seq(lr.arena, a, b);
}

