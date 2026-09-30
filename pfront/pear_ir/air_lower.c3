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

    // ── Nested function hoisting ──────────────────────────────────────────
    // `fn` declarations inside a body were lowered to a nop, so call sites kept
    // referring to a name no decl defined: AIR contained `<inner|call(3; ...)>`
    // with no `fn inner`, codegen resolved the callee to null and emitted a call
    // to address 0 — a binary that segfaults on the first call. stmts() records
    // such decls (binding their name so calls resolve) and module_body() emits
    // them as top-level defs after the main walk.
    Node*[64]    hoist_nodes;
    char*[64]    hoist_names;
    usz          hoist_count;
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
    lr.hoist_count = 0;
}

// ── Small helpers ──────────────────────────────────────────────────────────
// These are used everywhere; keeping them short but well-named makes the
// code below read like pseudocode.
fn char* AirLower.fresh_k(AirLower* lr)    { return lr.scope.fresh_k_covar(); }
fn char* AirLower.fresh_x(AirLower* lr)    { return lr.scope.fresh_x_var(); }
fn char* AirLower.fresh_lbl(AirLower* lr, char* hint) { return lr.scope.fresh_label(hint); }

// node_text — extract the identifier/literal name from a PNode. For decls
// and bindings the source sptr points at the leading keyword (`fn`, `def`,
// `let`), so we drill into the first ident child instead. For everything
// else we try sptr first, then the interner, then the resolved node.
fn char* node_text(Node* n, pfront_core::Interner* it)
{
    if (n == null) return null;
    // Decl/binder/module/use/field/etc: name lives in the first ident child.
    if (pfront_core::is_decl(n.kind)
        || n.kind == Nk.N_MODULE
        || n.kind == Nk.N_USE
        || n.kind == Nk.N_DECL_FIELD
        || n.kind == Nk.N_DECL_VARIANT
        || n.kind == Nk.N_DECL_EFFECT_OP
        || n.kind == Nk.N_EXPR_FIELD_INIT)
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i];
            if (c == null) continue;
            if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_EXPR_IDENT
                || c.kind == Nk.N_TY_NAME)
            {
                char* cn = node_text(c, it);
                if (cn != null && cn[0] != 0) return cn;
            }
        }
    }
    // For ident/pat/ty-name nodes prefer the interner over sptr because sptr
    // may span a multi-token construct while name_id carries the resolved name.
    if (it != null && n.name_id != 0)
    {
        char* iname = it.text(n.name_id);
        if (iname != null && iname[0] != 0) return iname;
    }
    if (n.p.sptr != null && n.p.slen > 0
        && (n.kind == Nk.N_PAT_IDENT || n.kind == Nk.N_EXPR_IDENT
            || n.kind == Nk.N_TY_NAME || n.kind == Nk.N_EXPR_CHAR
            || n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_FLOAT))
    {
        return n.p.sptr;
    }
    if (n.p.sptr != null && n.p.slen > 0
        && (n.kind == Nk.N_EXPR_STRING || n.kind == Nk.N_PAT_LITERAL))
    {
        return n.p.sptr;
    }
    if (n.resolved != null)
    {
        Node* r = n.resolved;
        if (it != null && r.name_id != 0) return it.text(r.name_id);
        if (r.p.sptr != null && r.p.slen > 0
            && (r.kind == Nk.N_PAT_IDENT || r.kind == Nk.N_EXPR_IDENT || r.kind == Nk.N_TY_NAME))
        {
            return r.p.sptr;
        }
    }
    return null;
}

fn char* AirLower.nm(AirLower* lr, Node* n) { return node_text(n, lr.it); }

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
            char* nm = node_text(p, lr.it);
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
            char* vnm = node_text(p, lr.it);
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
            char* nm = node_text(n, lr.it);
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
                pnm = node_text(pp, lr.it);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) pty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            bc = bc + 1;
        }
    }
    char* ret = lr.scope.push_ret("%ret");
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
    AirPrd* lam = air_ir::air_mk_lambda(lr.arena, &bv[0], bc, body);
    lr.scope.pop_ret();
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
            char* fnm = node_text(c, lr.it);
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
    // Emit field inits in DECLARATION order (source order is free — `P { y = 2,
    // x = 40 }` is legal), so the backend can lay them out sequentially. The
    // `_fN` markers (the type name and bare positional values) stay in front.
    Node* sdecl = lr.struct_decl_of(n);
    AirFieldInit*[16] ordered;
    for (usz i = 0; i < 16; i++) { ordered[i] = null; }
    usz ordered_n = 0;
    for (usz i = 0; i < ic && i < 16; i++)
    {
        AirFieldInit* fi = inits[i];
        if (fi == null) continue;
        if (fi.name == null || fi.name[0] == '_' || sdecl == null)
        {
            if (ordered_n < 16) { ordered[ordered_n] = fi; ordered_n++; }
            lr.total_decl = lr.total_decl;   // (no-op keeps the branch shape)
            continue;
        }
        long oi = lr.struct_field_index(sdecl, fi.name);
        if (oi < 0 || oi > 14 || (usz)oi + 1 >= 16) { if (ordered_n < 16) { ordered[ordered_n] = fi; ordered_n++; } continue; }
        if (ordered[(usz)oi + 1] != null) { if (ordered_n < 16) { ordered[ordered_n] = fi; ordered_n++; } continue; }
        ordered[(usz)oi + 1] = fi;
    }
    for (usz i = 0; i < 16; i++)
    {
        AirFieldInit* fi = ordered[i];
        if (fi == null) continue;
        if (rec.rec_init_count < 16) { rec.rec_inits[rec.rec_init_count] = fi; rec.rec_init_count++; }
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
            // return v  =  < v | %ret >  — ALWAYS cut to the innermost
            // function's return covariable, regardless of what k is (k may
            // be a μα α for a block-expr consumer; return does NOT honor α,
            // it unwinds to the enclosing fn).
            char* rk = lr.scope.current_ret();
            if (n.child_count > 0) return lr.expr_to_cns(n.children[0], lr.cns_k(rk));
            return lr.cut(lr.mod.p_unit, lr.cns_k(rk));
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
        case Nk.N_DECL_LET:
        case Nk.N_DECL_CONST:
        case Nk.N_DECL_STATIC:
        {
            // Local let/const/static appearing as a single-stmt block or
            // in a non-tail dispatch through cmd(): thread through letlike
            // with a unit-cut as the rest (no following statement).
            return lr.letlike(n, lr.cut(lr.mod.p_unit, lr.cns_k(k)));
        }
        case Nk.N_DECL_FN:
        case Nk.N_DECL_EXTERN_FN:
        case Nk.N_DECL_STRUCT:
        case Nk.N_DECL_UNION:
        case Nk.N_DECL_ENUM:
        case Nk.N_DECL_TYPE:
        case Nk.N_DECL_EFFECT:
        case Nk.N_DECL_NEWTYPE:
        case Nk.N_DECL_INTERFACE:
        case Nk.N_DECL_IMPL:
        {
            // Local item declarations are side-effect-free at runtime (top-level
            // registration only); emit nop so they don't cut to k.
            return lr.nop();
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
fn bool pclaim_pat_wild(Node* c)
{
    if (c == null) return false;
    return c.kind == Nk.N_PAT_WILDCARD;
}

// ── Nested function hoisting ────────────────────────────────────────────────
// mod_has_fn — is there already a module-level function (definition or extern
// declaration) with this name?
fn bool AirLower.mod_has_fn(AirLower* lr, char* nm)
{
    if (nm == null) return false;
    for (usz i = 0; i < lr.mod.decl_count; i++)
    {
        AirDecl* d = lr.mod.decls[i];
        if (d == null || d.name == null) continue;
        if (d.tag != ADECL_DEF && d.tag != ADECL_DECLARE) continue;
        usz j = 0;
        while (d.name[j] != 0 && nm[j] != 0) { if (d.name[j] != nm[j]) break; j++; }
        if (d.name[j] == 0 && nm[j] == 0) return true;
    }
    return false;
}

// hoist_name_taken — is this AIR name already used by a previously hoisted local
// function? Hoisted defs only enter the module at the end of the walk, so
// mod_has_fn() cannot see them.
fn bool AirLower.hoist_name_taken(AirLower* lr, char* nm)
{
    if (nm == null) return false;
    for (usz i = 0; i < lr.hoist_count; i++)
    {
        char* h = lr.hoist_names[i];
        if (h == null) continue;
        usz j = 0;
        while (h[j] != 0 && nm[j] != 0) { if (h[j] != nm[j]) break; j++; }
        if (h[j] == 0 && nm[j] == 0) return true;
    }
    return false;
}

// hoist_local_fn — a `fn` declared inside a body: pick an AIR name for its
// definition and bind the SOURCE name in the current scope, so call sites in
// this body resolve to it (AirScope.bind_as keeps key and emitted name apart).
// The definition is emitted later, from module_body().
fn char* AirLower.hoist_local_fn(AirLower* lr, Node* n)
{
    if (n == null) return null;
    for (usz i = 0; i < lr.hoist_count; i++)
    {
        if (lr.hoist_nodes[i] == n) { return lr.hoist_names[i]; }
    }
    char* base = node_text(n, lr.it);
    if (base == null || base[0] == 0) { base = (char*)"_fn"; }
    // Free AIR name: the plain name when nothing else uses it, else `base$N`.
    // C3 identifiers cannot contain '$', so a mangled name never collides with
    // a user-written one.
    char* air = base;
    for (usz n2 = 1; n2 < 1000; n2++)
    {
        if (!lr.scope.air_name_used(air) && !lr.mod_has_fn(air) && !lr.hoist_name_taken(air)) { break; }
        (void)snprintf(&lr.tmp[0], 256, "%s$%d", base, (int)n2);
        air = lr.dup(&lr.tmp[0]);
    }
    char* bound = lr.scope.bind_as(base, air, n);
    if (lr.hoist_count < 64)
    {
        lr.hoist_nodes[lr.hoist_count] = n;
        lr.hoist_names[lr.hoist_count] = bound;
        lr.hoist_count++;
    }
    return bound;
}

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

    // ── Pre-bind this block's locals BEFORE lowering the tail ────────────────
    // The tail is lowered first (see the backward walk below), so a reference to
    // a local declared earlier in the same block was looked up before the `let`
    // that binds it had run. That only appeared to work when the AIR printer's
    // fallback name happened to match the name the later `bind` chose; add an
    // intervening block, the names diverge, and the reference silently degraded
    // to unit — `let x = n; { let y = 2; } return x` returned 0.
    // Binding the declarations here (and reusing the binding in letlike) makes
    // the tail's lookups resolve to the real local.
    for (usz pi = 0; pi < container.child_count; pi++)
    {
        Node* ps = container.children[pi];
        if (ps == null) continue;
        if (ps.kind == Nk.N_DECL_FN)
        {
            // Nested function: bind its name now so the tail lowered below
            // resolves calls to it; the definition is emitted after the walk.
            (void)lr.hoist_local_fn(ps);
            continue;
        }
        if (ps.kind != Nk.N_DECL_LET && ps.kind != Nk.N_DECL_CONST
         && ps.kind != Nk.N_DECL_STATIC) continue;
        if (lr.scope.lookup_decl(ps) != null) continue;    // already bound
        char* pnm = node_text(ps, lr.it);
        if (pnm == null || pnm[0] == 0 || pnm[0] == '_') continue;   // _-names stay wildcards
        bool has_wildcard = false;
        for (usz ci = 0; ci < ps.child_count; ci++)
        {
            Node* pc = ps.children[ci];
            if (pc != null && pclaim_pat_wild(pc)) { has_wildcard = true; break; }
        }
        if (has_wildcard) continue;
        lr.scope.bind_var(pnm, ps);
    }

    AirCmd* cur;
    Node* last_n = container.children[(usz)last];
    if (last_n == null)
    {
        cur = lr.cut(lr.mod.p_unit, lr.cns_k(k));
    }
    else if (last_n.kind == Nk.N_BLOCK || last_n.kind == Nk.N_STMT_EXPR
          || pfront_core::is_decl(last_n.kind))
    {
        // The final child is a block/stmt/decl: dispatch through cmd().
        // Note: N_DECL_FN/STRUCT/etc inside a block are LOCAL declarations
        // (e.g. letrec when we add them); for now we emit them as nop+side
        // effect.  We must NOT call decl_inner() here because that would
        // register them as TOP-LEVEL decls!
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

    // Walk backwards prepending preceding statements.
    long i = last - 1;
    while (i >= 0)
    {
        Node* s = container.children[(usz)i];
        if (s != null)
        {
            AirCmd* sc;
            bool sc_consumes_cur = false;
            if (s.kind == Nk.N_DECL_LET || s.kind == Nk.N_DECL_CONST
             || s.kind == Nk.N_DECL_STATIC)
            {
                // Local let/const/static binding becomes ACMD_LET.
                // letlike(s, rest) already threads `rest` (our `cur`) as its body,
                // so we must NOT wrap it again in SEQ.
                sc = lr.letlike(s, cur);
                sc_consumes_cur = true;
            }
            else if (s.kind == Nk.N_DECL_FN || s.kind == Nk.N_DECL_EXTERN_FN
                  || s.kind == Nk.N_DECL_STRUCT || s.kind == Nk.N_DECL_UNION
                  || s.kind == Nk.N_DECL_ENUM || s.kind == Nk.N_DECL_TYPE
                  || s.kind == Nk.N_DECL_EFFECT
                  || s.kind == Nk.N_DECL_NEWTYPE || s.kind == Nk.N_DECL_INTERFACE
                  || s.kind == Nk.N_DECL_IMPL)
            {
                // Local fn/struct/enum/type/effect: nop placeholder (local defs
                // via letrec are a future feature; top-level ones are handled
                // by walk_decls).
                sc = lr.nop();
            }
            else if (pfront_core::is_expr(s.kind))
            {
                // Evaluate s, discard its value via fresh _x, then cur.
                // expr_to_cns already includes the μ̃ binder wrapping cur.
                char* ignore = lr.fresh_x();
                sc = lr.expr_to_cns(s,
                    air_ir::air_mk_comu_cns(lr.arena, ignore, cur));
                sc_consumes_cur = true;
            }
            else if (s.kind == Nk.N_STMT_RETURN || s.kind == Nk.N_STMT_BREAK
                  || s.kind == Nk.N_STMT_CONTINUE)
            {
                // Genuine control transfer: unwind to the enclosing fn / loop.
                // It does NOT fall through, so the following command stays
                // reachable only on other paths and is kept by seq_cmds.
                sc = lr.cmd(s, k);
            }
            else
            {
                // ── Fall-through statement: continue with `cur`, not with `k` ──
                // This branch covers statement-position blocks, assignments and
                // control constructs (if/while/for/match/defer). Passing the
                // block's ORIGINAL continuation `k` here made the statement jump
                // past everything that followed it: `{ let y = 2; }` lowered to
                // `let y = 2; <()|%ret_2>` — a cut to the function's RETURN
                // covariable, which is_terminal_cmd() then reported as terminal,
                // so seq_cmds() DROPPED the already-lowered `return x`. Hence
                //   fn f(n: i64) -> i64 { let x: i64 = n; { let y: i64 = 2; } return x; }
                // emitted `<()|%ret_2>` in tail position and returned 0.
                // cmd_to_cns() lowers the statement against a consumer standing
                // for `cur` (μ̃α.cur), so the rest of the block is threaded
                // through instead of being discarded.
                // Lower the statement against a FRESH admin continuation: its
                // exit cut <()|%kN> becomes a join block and `cur` — sequenced
                // next — is emitted into that block by the backend. (Passing the
                // container's own `k` made the statement jump out of the block,
                // and is_terminal_cmd() then let seq_cmds() drop `cur`.)
                char* after = lr.fresh_k();
                sc = lr.cmd(s, after);
            }
            if (sc_consumes_cur)
            {
                cur = sc;
            }
            else
            {
                cur = seq_cmds(lr, sc, cur);
            }
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

// cmd_to_cns — lift a cmd-node (block/match-arm body) into an expr-position
// command that, when run, evaluates the body and cuts its result to the
// consumer k. This bridges between the cmd-world (which threads a covariable
// *name*) and the cns-world (which threads an AirCns*).
//
// If the cmd unconditionally transfers control (return/break/continue/ub),
// then no μα wrapping is needed and no value will ever reach k — just emit
// the body directly.  This avoids admin redices of the form
//   <μα.<v|%ret>|μ̃x.dead_rest>
// which were previously printed as `let _x5 = μα.<v|%ret>; dead_rest`,
// leaking dead code inside the μα.
fn AirCmd* AirLower.cmd_to_cns(AirLower* lr, Node* n, AirCns* k)
{
    if (n == null) return lr.cut(lr.mod.p_unit, k);
    if (n.kind == Nk.N_BLOCK) return lr.block_to_cns(n, k);
    if (pfront_core::is_expr(n.kind)) return lr.expr_to_cns(n, k);
    char* alpha = lr.fresh_k();
    lr.mu++;
    AirCmd* body = lr.cmd(n, alpha);
    // Only skip μα if body escapes out of α (e.g., return/jump/break).  If
    // the only "terminal" cut is to α itself (the normal "produce a value"
    // path), or if body is non-terminal, we need the wrapper.
    if (terminal_escapes(body, alpha))
    {
        return body;
    }
    AirPrd* mu = air_ir::air_mk_mu_prd(lr.arena, alpha, body);
    lr.total_prd++;
    return lr.cut(mu, k);
}

// block_to_cns — block as an expression: evaluate the block, cutting the
// tail to a fresh covariable α, then wrap in μα so the result is a producer
// feeding into consumer k.  If the block unconditionally escapes (return /
// jump / etc.) we skip the μα wrapper.
fn AirCmd* AirLower.block_to_cns(AirLower* lr, Node* n, AirCns* k)
{
    char* alpha = lr.fresh_k();
    lr.mu++;
    AirCmd* body = lr.stmts(n, alpha, true);
    if (terminal_escapes(body, alpha))
    {
        return body;
    }
    AirPrd* mu = air_ir::air_mk_mu_prd(lr.arena, alpha, body);
    lr.total_prd++;
    return lr.cut(mu, k);
}

// terminal_escapes — does `body` directly and unconditionally cut to
// `%ret_N` (the enclosing function's return covariable), bypassing α?
// That is: is body a SINGLE immediate cut `<v|%ret_N>` (modulo trivial
// μα or ACMD_RET wrapping)?  If so, the outer μα wrapper is an admin
// redex: the value never actually gets produced for α/k because return
// unwinds the call frame.
//
// We deliberately keep this check simple (no recursion into seq/if/let
// chains): those are handled by dead-code pruning at seq_cmds + emit
// time, not by μα elision.
fn bool terminal_escapes(AirCmd* c, char* alpha)
{
    if (c == null) return false;
    // Peeling away outer μα / ACMD_RET wrappers (α binder shadowing):
    while (c.tag == ACMD_MU) { c = c.body; }
    if (c.tag == ACMD_RET) return true;
    if (c.tag == ACMD_JUMP || c.tag == ACMD_TRAP || c.tag == ACMD_UB
     || c.tag == ACMD_BREAK || c.tag == ACMD_CONTINUE) return true;
    if (c.tag == ACMD_CUT
     && c.cns != null && c.cns.tag == ACNS_COVAR
     && c.cns.name != alpha
     && c.cns.name != null
     && c.cns.name[0] == '%'
     && c.cns.name[1] == 'r'
     && c.cns.name[2] == 'e'
     && c.cns.name[3] == 't') { return true; }
    return false;
}

// letlike — translate a let/const/static declaration (NOT top-level).
// Produces `let x = init; rest` where `rest` is the continuation threaded
// in by stmts (which already wraps the remainder of the block). The init
// is evaluated L→R: if it is a compound expression we CPS it into a μ̃x
// binder; for simple value nodes we use the prd directly.
//
// Wildcard pattern (`let _ = init`) does NOT introduce a named binding —
// we evaluate init for effect, discarding the value through μ̃_x with no
// subsequent let.
fn AirCmd* AirLower.letlike(AirLower* lr, Node* s, AirCmd* rest)
{
    if (s.child_count == 0) return rest;

    // Detect wildcard pattern vs named binder.
    bool wildcard = false;
    char* nm = node_text(s, lr.it);
    for (usz i = 0; i < s.child_count; i++)
    {
        Node* c = s.children[i];
        if (c != null && c.kind == Nk.N_PAT_WILDCARD) { wildcard = true; break; }
    }
    // node_text on a wildcard pattern may legitimately return "_".
    if (!wildcard && nm != null && nm[0] == '_' && nm[1] == 0) wildcard = true;

    Node* val = null;
    Node* pat_node = null;
    for (usz i = 0; i < s.child_count; i++)
    {
        Node* c = s.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_TYPEPARAM || c.kind == Nk.N_DECL_PARAM) continue;
        if (pfront_core::is_pattern(c.kind))
        {
            if (pat_node == null) pat_node = c;
            continue;
        }
        val = c;
        break;
    }

    // Effective type annotation: let node may have it, or its pattern child may
    // (e.g. `let a: u8 = 255` parses type on pat-ident, not on let itself).
    Node* eff_type_ann = s.type_ann;
    if (eff_type_ann == null && pat_node != null)
    {
        eff_type_ann = pat_node.type_ann;
        // Also check nested pat-ident if pat_node is tuple/struct etc? For now check first child
        if (eff_type_ann == null && pat_node.child_count > 0)
        {
            // pat_node may contain nested pattern with type_ann (unlikely)
            for (usz pi = 0; pi < pat_node.child_count; pi++)
            {
                Node* pc = pat_node.children[pi];
                if (pc != null && pc.type_ann != null) { eff_type_ann = pc.type_ann; break; }
            }
        }
    }

    if (wildcard)
    {
        // Wildcard: evaluate init for effect, drop result, continue to rest.
        if (val == null) return rest;
        if (is_value_node(val)) return rest; // pure value, no side effect — drop
        char* xv = lr.fresh_x();
        return lr.expr_to_cns(val, air_ir::air_mk_comu_cns(lr.arena, xv, rest));
    }

    if (nm == null) nm = (char*)"_let";
    // Reuse the pre-binding made by stmts() for this declaration, if any: the
    // block tail was already lowered against that name, so binding a second,
    // differently-renamed local here would leave the tail pointing at the first.
    char* x = lr.scope.lookup_decl(s);
    if (x == null) { x = lr.scope.bind_var(nm, s); }
    if (val == null)
    {
        lr.lets++;
        return air_ir::air_mk_let(lr.arena, x, lr.mod.p_unit, rest);
    }
    if (is_value_node(val))
    {
        AirPrd* vp = lr.prd(val);
        // Truncate narrow types to fix Agent-4 §18: narrow-type arithmetic compared untruncated
        // If let has explicit type annotation like u8/i16, truncate the value before binding
        // eff_type_ann handles both `let x: u8` (type on let) and `let a: u8` parsed as pat-ident type
        if (eff_type_ann != null)
        {
            AirTyp* aty = air_types::air_ty(lr.mod, eff_type_ann, lr.it);
            if (aty != null)
            {
                if (aty.tag == ATYP_U8)
                {
                    AirPrd* mask = air_ir::air_mk_int(lr.arena, 255);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_AND, vp, mask);
                }
                else if (aty.tag == ATYP_I8)
                {
                    AirPrd* sh = air_ir::air_mk_int(lr.arena, 56);
                    AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, vp, sh);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
                }
                else if (aty.tag == ATYP_U16)
                {
                    AirPrd* mask = air_ir::air_mk_int(lr.arena, 65535);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_AND, vp, mask);
                }
                else if (aty.tag == ATYP_I16)
                {
                    AirPrd* sh = air_ir::air_mk_int(lr.arena, 48);
                    AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, vp, sh);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
                }
                else if (aty.tag == ATYP_U32)
                {
                    AirPrd* mask = air_ir::air_mk_int(lr.arena, 4294967295);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_AND, vp, mask);
                }
                else if (aty.tag == ATYP_I32)
                {
                    AirPrd* sh = air_ir::air_mk_int(lr.arena, 32);
                    AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, vp, sh);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
                }
                else if (aty.tag == ATYP_BOOL)
                {
                    AirPrd* mask = air_ir::air_mk_int(lr.arena, 1);
                    vp = air_ir::air_mk_binop(lr.arena, ABIN_AND, vp, mask);
                }
            }
        }
        lr.lets++;
        return air_ir::air_mk_let(lr.arena, x, vp, rest);
    }
    // Compound init: evaluate it into a fresh μ̃-bound xv, then let x=xv in rest.
    char* xv = lr.fresh_x();
    AirPrd* xp = air_ir::air_mk_var(lr.arena, xv);
    // Truncate narrow types for compound inits too (same fix as value case)
    if (eff_type_ann != null)
    {
        AirTyp* aty2 = air_types::air_ty(lr.mod, eff_type_ann, lr.it);
        if (aty2 != null)
        {
            if (aty2.tag == ATYP_U8)
            {
                AirPrd* mask = air_ir::air_mk_int(lr.arena, 255);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_AND, xp, mask);
            }
            else if (aty2.tag == ATYP_I8)
            {
                AirPrd* sh = air_ir::air_mk_int(lr.arena, 56);
                AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, xp, sh);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
            }
            else if (aty2.tag == ATYP_U16)
            {
                AirPrd* mask = air_ir::air_mk_int(lr.arena, 65535);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_AND, xp, mask);
            }
            else if (aty2.tag == ATYP_I16)
            {
                AirPrd* sh = air_ir::air_mk_int(lr.arena, 48);
                AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, xp, sh);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
            }
            else if (aty2.tag == ATYP_U32)
            {
                AirPrd* mask = air_ir::air_mk_int(lr.arena, 4294967295);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_AND, xp, mask);
            }
            else if (aty2.tag == ATYP_I32)
            {
                AirPrd* sh = air_ir::air_mk_int(lr.arena, 32);
                AirPrd* tmp = air_ir::air_mk_binop(lr.arena, ABIN_SHL, xp, sh);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_SHR, tmp, sh);
            }
            else if (aty2.tag == ATYP_BOOL)
            {
                AirPrd* mask = air_ir::air_mk_int(lr.arena, 1);
                xp = air_ir::air_mk_binop(lr.arena, ABIN_AND, xp, mask);
            }
        }
    }
    lr.lets++;
    AirCmd* bind = air_ir::air_mk_let(lr.arena, x, xp, rest);
    return lr.expr_to_cns(val, air_ir::air_mk_comu_cns(lr.arena, xv, bind));
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
            char* nm = node_text(n, lr.it);
            if (nm == null) nm = (char*)"_";
            char* x = lr.scope.lookup_var(nm);
            if (x == null) x = lr.dup(nm);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_var(lr.arena, x), k);
        }
        case Nk.N_EXPR_PATH:
        {
            char* nm = node_text(n, lr.it);
            if (nm == null) nm = (char*)"_";
            // A path can name a LOCAL binding (the resolver emits a plain
            // function reference, including a call callee, as a path node), so
            // consult the scope before falling back to the literal text —
            // otherwise a nested function's definition and its call sites end up
            // under different names and the call goes to the wrong function.
            char* bound = lr.scope.lookup_var(nm);
            lr.total_prd++;
            return lr.cut(air_ir::air_mk_var(lr.arena, bound != null ? bound : lr.dup(nm)), k);
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
            char* mname = node_text(n, lr.it);
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
        case Nk.N_EXPR_LOOP:      return lr.loop_(n, k);
        case Nk.N_EXPR_FOR:       return lr.for_(n, k);
        case Nk.N_EXPR_LAMBDA:    return lr.lambda(n, k);
        case Nk.N_EXPR_BINARY:    return lr.binop(n, k);
        case Nk.N_EXPR_UNARY:     return lr.unop(n, k);
        case Nk.N_BLOCK:          return lr.block_to_cns(n, k);
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
            // alloc [T; N] → malloc(n): heap allocate n bytes, return the
            // pointer as an i64 (PEAR represents pointers as intptr_t).
            // The v0.8 bootstrap used a static [256 x i8] entry-BB alloca
            // (__pear_alloca), which capped allocations at 256 B and tickled
            // EarlyCSE on dynamic alloca sizes. v0.9 moves to real malloc
            // so kernels like sieve (n+1 byte array) can run.
            lr.total_prd++;
            lr.total_cns++;
            long bytes = lr.alloc_bytes(n);
            if (bytes <= 0) bytes = 16;
            AirPrd* szp = air_ir::air_mk_int(lr.arena, bytes);
            AirPrd*[1] av; av[0] = szp;
            AirPrd* callee = air_ir::air_mk_var(lr.arena, lr.dup((char*)"malloc"));
            AirCns* call_k = air_ir::air_mk_call(lr.arena, &av[0], 1, k);
            return lr.cut(callee, call_k);
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
    AirPrd*[16] vars; char*[16] xnames; bool[16] is_comp; usz vc = 0;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (is_value_node(c))
        {
            vars[vc] = lr.prd(c); is_comp[vc] = false;
        }
        else
        {
            char* xv = lr.fresh_x();
            vars[vc] = air_ir::air_mk_var(lr.arena, xv);
            xnames[vc] = xv; is_comp[vc] = true;
        }
        vc = vc + 1;
    }
    lr.total_prd++;
    AirPrd* tup = air_ir::air_mk_tuple(lr.arena, &vars[0], vc);
    AirCmd* out = lr.cut(tup, k);
    long i = (long)vc - 1;
    while (i >= 0)
    {
        if (is_comp[(usz)i]) {
            out = lr.expr_to_cns(n.children[(usz)i],
                air_ir::air_mk_comu_cns(lr.arena, xnames[(usz)i], out));
        }
        i = i - 1;
    }
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.array_lit(AirLower* lr, Node* n, AirCns* k)
{
    AirPrd*[16] vars; char*[16] xnames; bool[16] is_comp; usz vc = 0;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count && i < 16; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (is_value_node(c))
        {
            vars[vc] = lr.prd(c); is_comp[vc] = false;
        }
        else
        {
            char* xv = lr.fresh_x();
            vars[vc] = air_ir::air_mk_var(lr.arena, xv);
            xnames[vc] = xv; is_comp[vc] = true;
        }
        vc = vc + 1;
    }
    lr.total_prd++;
    AirPrd* arr = air_ir::air_mk_array(lr.arena, &vars[0], vc);
    AirCmd* out = lr.cut(arr, k);
    long i = (long)vc - 1;
    while (i >= 0)
    {
        if (is_comp[(usz)i]) {
            out = lr.expr_to_cns(n.children[(usz)i],
                air_ir::air_mk_comu_cns(lr.arena, xnames[(usz)i], out));
        }
        i = i - 1;
    }
    lr.scope.leave();
    return out;
}

// ── Record layout ───────────────────────────────────────────────────────────
// A record value is the address of a stack buffer with one i64 slot per field,
// in DECLARATION order (not source-init order). struct_field_index() recovers
// that order from the resolved AST: a field declaration is an N_DECL_FIELD child
// of the struct decl, and PNode.parent links a field decl back to its struct, so
// `p.x` -> resolved field decl -> parent struct -> ordinal.
fn long AirLower.struct_field_index(AirLower* lr, Node* struct_decl, char* nm)
{
    if (struct_decl == null || nm == null) return -1;
    long idx = 0;
    for (usz i = 0; i < struct_decl.child_count; i++)
    {
        Node* c = struct_decl.children[i];
        if (c == null) continue;
        if (c.kind != Nk.N_DECL_FIELD) continue;
        char* fnm = node_text(c, lr.it);
        if (fnm == null) { idx++; continue; }
        usz j = 0;
        while (fnm[j] != 0 && nm[j] != 0) { if (fnm[j] != nm[j]) break; j++; }
        if (fnm[j] == 0 && nm[j] == 0) return idx;
        idx++;
    }
    return -1;
}

// struct_decl_of — the struct declaration a struct literal / field access refers
// to: the resolver links the node (or its type child) to the struct.
fn Node* AirLower.struct_decl_of(AirLower* lr, Node* n)
{
    if (n == null) return null;
    if (n.resolved != null && n.resolved.kind == Nk.N_DECL_STRUCT) return n.resolved;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.resolved != null && c.resolved.kind == Nk.N_DECL_STRUCT) return c.resolved;
    }
    return null;
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
            char* fnm = node_text(c, lr.it);
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
    lr.scope.enter();

    // Strategy: build <callee_var | call(arg_vars; k)> and wrap each non-value
    // argument (right-to-left, so leftmost arg wraps outermost = evaluates last)
    // and finally the callee, in μ̃ binders.  Each compound arg is bound to a
    // fresh _xN via bind_x_then, which threads the continuation correctly.
    //
    // We use a clean two-pass approach: first snapshot arg variables (values
    // inlined as prds, compounds as fresh var placeholders with their name
    // remembered), then wrap.

    AirPrd*[16] avars; usz vc = 0;
    char*[16]  anames;

    // Pass 1: collect prd slots. For compound args, mint a fresh name NOW
    // (before any wrapping) so names are stable — otherwise fresh_x() calls
    // during wrapping of inner compounds would desync.
    for (usz i = 0; i < ac && i < 16; i++)
    {
        Node* a = args[i];
        if (a == null)
        {
            avars[vc] = lr.mod.p_unit;
            anames[vc] = null;
        }
        else if (is_value_node(a))
        {
            avars[vc] = lr.prd(a);
            anames[vc] = null;
        }
        else
        {
            char* xv = lr.fresh_x();
            avars[vc] = air_ir::air_mk_var(lr.arena, xv);
            anames[vc] = xv;
        }
        vc = vc + 1;
    }

    // Callee placeholder (must be fresh'd BEFORE arg wrapping so arg
    // compounds can take fresh_x names without colliding).
    char* callee_x = null;
    AirPrd* cv_v;
    if (is_value_node(callee))
    {
        cv_v = lr.prd(callee);
    }
    else
    {
        callee_x = lr.fresh_x();
        cv_v = air_ir::air_mk_var(lr.arena, callee_x);
    }

    lr.total_cns++;
    AirCns* call_k = air_ir::air_mk_call(lr.arena, &avars[0], vc, k);
    AirCmd* out = lr.cut(cv_v, call_k);

    // Pass 2: wrap compound args right-to-left.
    long i = (long)vc - 1;
    while (i >= 0)
    {
        if (anames[(usz)i] != null)
        {
            out = lr.expr_to_cns(args[(usz)i],
                air_ir::air_mk_comu_cns(lr.arena, anames[(usz)i], out));
        }
        i = i - 1;
    }

    // Wrap callee (outermost).
    if (callee_x != null)
    {
        out = lr.expr_to_cns(callee,
            air_ir::air_mk_comu_cns(lr.arena, callee_x, out));
    }

    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.method_generic(AirLower* lr, Node* recv, char* mname, Node** args, usz ac, AirCns* k)
{
    lr.scope.enter();
    AirPrd*[16] avars; char*[16] anames; usz vc = 0;
    for (usz i = 0; i < ac && i < 16; i++)
    {
        Node* a = args[i];
        if (a == null) { avars[vc] = lr.mod.p_unit; anames[vc] = null; }
        else if (is_value_node(a)) { avars[vc] = lr.prd(a); anames[vc] = null; }
        else { char*xv=lr.fresh_x(); avars[vc]=air_ir::air_mk_var(lr.arena,xv); anames[vc]=xv; }
        vc = vc + 1;
    }
    char* recv_x = null;
    AirPrd* rv_v;
    if (is_value_node(recv)) { rv_v = lr.prd(recv); }
    else { recv_x = lr.fresh_x(); rv_v = air_ir::air_mk_var(lr.arena, recv_x); }
    AirCns* args_k = air_ir::air_mk_call(lr.arena, &avars[0], vc, k);
    AirCns* proj = air_ir::air_mk_field_cns(lr.arena, lr.dup(mname), args_k);
    AirCmd* out = lr.cut(rv_v, proj);
    long i = (long)vc - 1;
    while (i >= 0)
    {
        if (anames[(usz)i] != null) {
            out = lr.expr_to_cns(args[(usz)i],
                air_ir::air_mk_comu_cns(lr.arena, anames[(usz)i], out));
        }
        i = i - 1;
    }
    if (recv_x != null) {
        out = lr.expr_to_cns(recv,
            air_ir::air_mk_comu_cns(lr.arena, recv_x, out));
    }
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.field_acc(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 1) return lr.cut(lr.mod.p_unit, k);
    char* f = node_text(n, lr.it);
    if (f == null) f = (char*)"f";
    lr.total_cns++;
    AirCns* proj = air_ir::air_mk_field_cns(lr.arena, lr.dup(f), k);
    // Layout index of the field, from the resolver's link: `p.x` resolves to the
    // field declaration, whose parent is the struct whose declaration order
    // defines the slot. -1 means "unknown" and the backend falls back to passing
    // the record through unchanged.
    Node* fdecl = n.resolved;
    if (fdecl != null && fdecl.parent != null && fdecl.parent.kind == Nk.N_DECL_STRUCT)
    {
        proj.idx = lr.struct_field_index(fdecl.parent, f);
    }
    return lr.expr_to_cns(n.children[0], proj);
}

fn AirCmd* AirLower.index_acc(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    lr.scope.enter();
    AirPrd* ov_p; AirPrd* iv_p;
    char* ov_name = null; char* iv_name = null;
    bool ov_comp = false; bool iv_comp = false;
    if (is_value_node(n.children[1]))
    {
        iv_p = lr.prd(n.children[1]);
    }
    else
    {
        iv_name = lr.fresh_x();
        iv_p = air_ir::air_mk_var(lr.arena, iv_name);
        iv_comp = true;
    }
    long esz = lr.index_elem_size(n);
    AirCns* ik = air_ir::air_mk_index(lr.arena, iv_p, esz, k);
    AirCmd* out;
    if (is_value_node(n.children[0]))
    {
        ov_p = lr.prd(n.children[0]);
        out = lr.cut(ov_p, ik);
    }
    else
    {
        ov_name = lr.fresh_x();
        ov_p = air_ir::air_mk_var(lr.arena, ov_name);
        out = lr.cut(ov_p, ik);
        ov_comp = true;
    }
    if (iv_comp) { out = lr.expr_to_cns(n.children[1],
        air_ir::air_mk_comu_cns(lr.arena, iv_name, out)); }
    if (ov_comp) { out = lr.expr_to_cns(n.children[0],
        air_ir::air_mk_comu_cns(lr.arena, ov_name, out)); }
    lr.scope.leave();
    return out;
}

// elem_size_from_name — element byte size for a primitive type name
// (u8/i8/bool→1, u16/i16→2, u32/i32/f32→4, u64/i64/f64/usize/isize/pointer→8).
fn long elem_size_from_name(char* nm)
{
    if (nm == null) return 8;
    if ((nm[0] == 'u' || nm[0] == 'i') && nm[1] != 0)
    {
        char b0 = nm[1];
        if (b0 == '8') return 1;
        if (b0 == '1' && nm[2] == '6') return 2;
        if (b0 == '3' && nm[2] == '2') return 4;
        if (b0 == '6' && nm[2] == '4') return 8;
        if (b0 == 's' && nm[2] == 'z') return 8; // isz/usize
    }
    else if (nm[0] == 'f')
    {
        if (nm[1] == '3' && nm[2] == '2') return 4;
        if (nm[1] == '6' && nm[2] == '4') return 8;
    }
    else if (nm[0] == 'b' && nm[1] == 'o' && nm[2] == 'o' && nm[3] == 'l') return 1;
    return 8; // pointers and unknown types default to 8 bytes.
}

// index_elem_size — byte size of the pointee of an N_EXPR_INDEX (reads the
// base's type annotation; pointer-dereferences of *T give esz=sizeof(T);
// array [T;N] gives esz=sizeof(T)).
fn long AirLower.index_elem_size(AirLower* lr, Node* n)
{
    // n is N_EXPR_INDEX (a[i]). Base is n.children[0]. Look at its type_ann
    // for *T; if the annotation is missing or is a variable ref, try the
    // base's own type_ann or fall back to 8.
    if (n == null || n.child_count < 1) return 8;
    Node* base = n.children[0];
    if (base != null && base.type_ann != null)
    {
        Node* bt = base.type_ann;
        // *T → look at children[0] which should be T.
        if (bt.kind == Nk.N_TY_PTR || bt.kind == Nk.N_TY_REF)
        {
            if (bt.child_count > 0 && bt.children[0] != null
                && bt.children[0].kind == Nk.N_TY_PATH)
            {
                return elem_size_from_name(node_text(bt.children[0], lr.it));
            }
            return 8;
        }
        if (bt.kind == Nk.N_TY_ARRAY && bt.child_count >= 1
            && bt.children[0] != null && bt.children[0].kind == Nk.N_TY_PATH)
        {
            return elem_size_from_name(node_text(bt.children[0], lr.it));
        }
    }
    // No annotation on the expr; see if it's a var whose declared type is
    // a pointer/array (lookup in scope). Fallback 8.
    if (base != null && base.kind == Nk.N_EXPR_PATH)
    {
        // AirScope.lookup() maps a source name to its AIR name and is not a
        // declaration lookup; decl_for() gives the AST declaration so we can
        // read the variable's type annotation.
        char* bname = node_text(base, lr.it);
        Node* bnd = bname != null ? lr.scope.decl_for(bname) : null;
        if (bnd != null && bnd.type_ann != null)
        {
            Node* bt = bnd.type_ann;
            if ((bt.kind == Nk.N_TY_PTR || bt.kind == Nk.N_TY_REF)
                && bt.child_count > 0 && bt.children[0] != null
                && bt.children[0].kind == Nk.N_TY_PATH)
            {
                return elem_size_from_name(node_text(bt.children[0], lr.it));
            }
        }
    }
    return 1; // byte pointer by default for bare a[i] on *u8 without annotations.
}

// index_elem_size_for_deref — pointee size for a DEREF (*p) expression base.
fn long AirLower.index_elem_size_for_deref(AirLower* lr, Node* base)
{
    // *p on an i64* stores 8 bytes; on *u8 stores 1.
    if (base != null && base.type_ann != null)
    {
        Node* bt = base.type_ann;
        if ((bt.kind == Nk.N_TY_PTR || bt.kind == Nk.N_TY_REF)
            && bt.child_count > 0 && bt.children[0] != null
            && bt.children[0].kind == Nk.N_TY_PATH)
        {
            return elem_size_from_name(node_text(bt.children[0], lr.it));
        }
    }
    return 8; // default deref is i64-sized.
}

// alloc_bytes — compute byte count for `alloc [T; N]` from n.type_ann.
// Bootstrap: recognizes N_TY_ARRAY with integer literal length and a
// primitive element type (u8→1, u16/i16→2, u32/i32/f32→4, u64/i64/f64/pointer→8).
// Falls back to 16 if it can't statically determine.
fn long AirLower.alloc_bytes(AirLower* lr, Node* n)
{
    if (n == null || n.type_ann == null) return 16;
    Node* t = n.type_ann;
    if (t.kind != Nk.N_TY_ARRAY || t.child_count < 2) return 16;
    Node* cnt = t.children[1];
    long n_el = 16;
    if (cnt != null)
    {
        if ((long)cnt.p.ival > 0) { n_el = (long)cnt.p.ival; }
        if (n_el <= 0) n_el = 16;
    }
    Node* elem = t.children[0];
    long esz = 8;
    if (elem != null && elem.kind == Nk.N_TY_PATH)
    {
        char* nm = node_text(elem, lr.it);
        if (nm != null)
        {
            if ((nm[0] == 'u' || nm[0] == 'i') && nm[1] != 0)
            {
                char b0 = nm[1];
                if (b0 == '8') { esz = 1; }
                else if (b0 == '1' && nm[2] == '6') { esz = 2; }
                else if (b0 == '3' && nm[2] == '2') { esz = 4; }
                else if (b0 == '6' && nm[2] == '4') { esz = 8; }
            }
            else if (nm[0] == 'f')
            {
                if (nm[1] == '3' && nm[2] == '2') { esz = 4; }
                else if (nm[1] == '6' && nm[2] == '4') { esz = 8; }
            }
            else if (nm[0] == 'b' && nm[1] == 'o' && nm[2] == 'o' && nm[3] == 'l') { esz = 1; }
        }
    }
    return n_el * esz;
}

// bind_x_then — allocate a fresh μ̃-bound producer name xv, build the
// consumer μ̃xv.then_body, then evaluate n into that consumer. This is
// the primitive used to thread compound subexpressions into an outer
// computation. ALWAYS use this instead of lr.nop() as the body of a
// comu_cns when that comu wraps a non-value subexpression — lr.nop()
// drops the continuation.
fn AirCmd* AirLower.bind_x_then(AirLower* lr, Node* n, char** xv_out, AirCmd* then_body)
{
    char* xv = lr.fresh_x();
    if (xv_out != null) *xv_out = xv;
    return lr.expr_to_cns(n, air_ir::air_mk_comu_cns(lr.arena, xv, then_body));
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
    lr.scope.enter();
    // Evaluate left-to-right (C-like semantics):
    //   <e_lhs|μ̃lv.<e_rhs|μ̃rv.<(lv op rv)|k>>>
    char* rx = null; char* lx = null;
    AirPrd* rv_p; AirPrd* lv_p;
    bool rv_comp = !is_value_node(n.children[1]);
    bool lv_comp = !is_value_node(n.children[0]);
    // Inner: <(lv op rv) | k>
    if (lv_comp) { lx = lr.fresh_x(); lv_p = air_ir::air_mk_var(lr.arena, lx); }
    else         { lv_p = lr.prd(n.children[0]); }
    if (rv_comp) { rx = lr.fresh_x(); rv_p = air_ir::air_mk_var(lr.arena, rx); }
    else         { rv_p = lr.prd(n.children[1]); }
    lr.total_prd++;
    AirPrd* bp = air_ir::air_mk_binop(lr.arena, b, lv_p, rv_p);
    AirCmd* out = lr.cut(bp, k);
    // Wrap RHS first (evaluated after LHS is bound, so wrap closer to inner).
    if (rv_comp)
    {
        out = lr.expr_to_cns(n.children[1],
            air_ir::air_mk_comu_cns(lr.arena, rx, out));
    }
    // Wrap LHS outermost (evaluated first at runtime).
    if (lv_comp)
    {
        out = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, lx, out));
    }
    lr.scope.leave();
    return out;
}
fn AirCmd* AirLower.shortcircuit_and(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_false, k);
    lr.scope.enter();
    AirCmd* els = lr.cut(lr.mod.p_false, k);
    AirCmd* thn = lr.expr_to_cns(n.children[1], k);
    AirCmd* iff = air_ir::air_mk_if(lr.arena, lr.mod.p_unit, thn, els);
    AirCmd* out;
    if (is_value_node(n.children[0]))
    {
        // iff needs real scrutinee; rebuild with prd:
        iff = air_ir::air_mk_if(lr.arena, lr.prd(n.children[0]), thn, els);
        out = iff;
    }
    else
    {
        char* ax = lr.fresh_x();
        AirPrd* ap = air_ir::air_mk_var(lr.arena, ax);
        iff = air_ir::air_mk_if(lr.arena, ap, thn, els);
        out = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, ax, iff));
    }
    lr.scope.leave();
    return out;
}

fn AirCmd* AirLower.shortcircuit_or(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 2) return lr.cut(lr.mod.p_true, k);
    lr.scope.enter();
    AirCmd* thn = lr.cut(lr.mod.p_true, k);
    AirCmd* els = lr.expr_to_cns(n.children[1], k);
    AirCmd* out;
    if (is_value_node(n.children[0]))
    {
        AirCmd* iff = air_ir::air_mk_if(lr.arena, lr.prd(n.children[0]), thn, els);
        out = iff;
    }
    else
    {
        char* ax = lr.fresh_x();
        AirPrd* ap = air_ir::air_mk_var(lr.arena, ax);
        AirCmd* iff = air_ir::air_mk_if(lr.arena, ap, thn, els);
        out = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, ax, iff));
    }
    lr.scope.leave();
    return out;
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
    lr.scope.enter();
    AirCmd* out;
    if (u == AUN_DEREF)
    {
        if (is_value_node(n.children[0]))
        {
            AirCns* dk = air_ir::air_new_AirCns(lr.arena);
            dk.tag = ACNS_DEREF; dk.tail = k;
            lr.total_cns++;
            out = lr.cut(lr.prd(n.children[0]), dk);
        }
        else
        {
            char* vx = lr.fresh_x();
            AirPrd* vp = air_ir::air_mk_var(lr.arena, vx);
            AirCns* dk = air_ir::air_new_AirCns(lr.arena);
            dk.tag = ACNS_DEREF; dk.tail = k;
            lr.total_cns++;
            AirCmd* fin = lr.cut(vp, dk);
            out = lr.expr_to_cns(n.children[0],
                air_ir::air_mk_comu_cns(lr.arena, vx, fin));
        }
    }
    else if (is_value_node(n.children[0]))
    {
        lr.total_prd++;
        AirPrd* up = air_ir::air_mk_unop(lr.arena, u, lr.prd(n.children[0]));
        out = lr.cut(up, k);
    }
    else
    {
        char* vx = lr.fresh_x();
        AirPrd* vp = air_ir::air_mk_var(lr.arena, vx);
        lr.total_prd++;
        AirPrd* up = air_ir::air_mk_unop(lr.arena, u, vp);
        AirCmd* fin = lr.cut(up, k);
        out = lr.expr_to_cns(n.children[0],
            air_ir::air_mk_comu_cns(lr.arena, vx, fin));
    }
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
                    cb = lr.cmd_to_cns(arm.children[j], k);
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

fn AirCmd* AirLower.for_(AirLower* lr, Node* n, AirCns* k)
{
    if (n.child_count < 3)
    {
        return lr.cut(lr.mod.p_unit, k);
    }
    Node* pat = n.children[0];
    Node* iter = n.children[1];
    Node* body = n.children[2];

    if (iter == null || iter.kind != Nk.N_EXPR_RANGE)
    {
        lr.scope.enter();
        char* pat_nm = null;
        if (pat != null) { pat_nm = node_text(pat, lr.it); }
        if (pat_nm == null || pat_nm[0] == 0) { pat_nm = (char*)"_"; }
        char* pat_bound = lr.scope.bind_var(pat_nm, pat);
        AirPrd* iter_prd = lr.prd_or_bind(iter);
        AirCmd* body_cmd = body != null ? lr.expr_to_cns(body, k) : lr.cut(lr.mod.p_unit, k);
        AirCmd* let_pat = air_ir::air_mk_let(lr.arena, pat_bound, iter_prd, body_cmd);
        lr.scope.leave();
        return let_pat;
    }

    Node* left = iter.child_count > 0 ? iter.children[0] : null;
    Node* right = iter.child_count > 1 ? iter.children[1] : null;
    bool inclusive = (iter.flags & pfront_core::NF_INCLUSIVE) != 0;

    lr.scope.enter();
    char* i_name = lr.fresh_x();
    char* end_name = lr.fresh_x();

    AirPrd* left_prd = left != null ? lr.prd_or_bind(left) : air_ir::air_mk_int(lr.arena, 0);
    AirPrd* right_prd = right != null ? lr.prd_or_bind(right) : air_ir::air_mk_int(lr.arena, 0);

    char* brk = lr.fresh_lbl("exit");
    char* cont = lr.fresh_lbl("loop");
    lr.scope.push_loop(brk, cont);

    lr.scope.enter();
    char* pat_nm = null;
    if (pat != null) { pat_nm = node_text(pat, lr.it); }
    if (pat_nm == null || pat_nm[0] == 0) { pat_nm = (char*)"_"; }
    char* pat_bound = lr.scope.bind_var(pat_nm, pat);

    char* after_body = lr.fresh_k();
    AirCmd* user_body_cmd = body != null ? lr.cmd(body, after_body) : lr.cut(lr.mod.p_unit, lr.cns_k(after_body));

    AirPrd* i_var_inc = air_ir::air_mk_var(lr.arena, lr.dup(i_name));
    AirPrd* one = air_ir::air_mk_int(lr.arena, 1);
    AirPrd* inc_prd = air_ir::air_mk_binop(lr.arena, ABIN_ADD, i_var_inc, one);
    AirCmd* jmp_cont = air_ir::air_mk_jump0(lr.arena, cont);
    AirCmd* let_inc = air_ir::air_mk_let(lr.arena, i_name, inc_prd, jmp_cont);

    AirCmd* body_seq = air_ir::air_mk_seq(lr.arena, user_body_cmd, let_inc);

    AirPrd* i_var_pat = air_ir::air_mk_var(lr.arena, lr.dup(i_name));
    AirCmd* let_pat = air_ir::air_mk_let(lr.arena, pat_bound, i_var_pat, body_seq);

    lr.scope.leave();

    AirPrd* i_for_cond = air_ir::air_mk_var(lr.arena, lr.dup(i_name));
    AirPrd* end_for_cond = air_ir::air_mk_var(lr.arena, lr.dup(end_name));
    AirBinop cmp_op = inclusive ? ABIN_LE : ABIN_LT;
    AirPrd* cond_prd = air_ir::air_mk_binop(lr.arena, cmp_op, i_for_cond, end_for_cond);

    AirBranch*[2] bs;
    bs[0] = air_ir::air_mk_branch(lr.arena, air_ir::air_mk_pat_bool(lr.arena, true), let_pat);
    lr.jumps++;
    bs[1] = air_ir::air_mk_branch(lr.arena, air_ir::air_mk_pat_bool(lr.arena, false), air_ir::air_mk_jump0(lr.arena, brk));
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

    AirCmd* let_i = air_ir::air_mk_let(lr.arena, i_name, left_prd, out);
    AirCmd* let_end = air_ir::air_mk_let(lr.arena, end_name, right_prd, let_i);

    lr.scope.pop_loop();
    lr.scope.leave();
    return let_end;
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
        char* after_lbl = lr.fresh_k();
        AirCmd* body_eval = lr.cmd(body, after_lbl);
        AirCmd* j = air_ir::air_mk_jump0(lr.arena, cont);
        body_cmd = air_ir::air_mk_seq(lr.arena, body_eval, j);
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
                pnm = node_text(pp, lr.it);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) pty = air_types::air_ty(lr.mod, c.type_ann, lr.it);
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            bc = bc + 1;
        }
        else if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_EXPR_IDENT)
        {
            char* pnm = node_text(c, lr.it);
            if (pnm == null) pnm = (char*)"_";
            char* an = lr.scope.bind_var(pnm, c);
            bv[bc] = air_ir::air_mk_binder(lr.arena, an, lr.mod.t_infer, AMULT_UNR);
            bc = bc + 1;
        }
    }
    char* ret = lr.scope.push_ret("%ret");
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
    lr.total_prd++;
    AirPrd* lam = air_ir::air_mk_lambda(lr.arena, &bv[0], bc, body);
    lr.scope.pop_ret();
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
            op = node_text(head, lr.it);
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
        comp = lr.cmd_to_cns(n.children[0], k);
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
                cb = lr.cmd_to_cns(arm.children[j], k);
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
    // Assignment: lhs = rhs. Two cases:
    //   (1) Plain identifier lhs (`x = v`):  ≡  < v | μ̃x. k >
    //       (PEAR uses alloca+store for mutable slots so rebinding via COMU
    //       does the store automatically.)
    //   (2) Indexed lhs (`a[i] = v`): compute address of a[i], then
    //       < v | store(addr) >; k  (ACNS_STORE consumer).
    //   (3) Deref lhs (`*p = v`): similar — store v to p.
    if (n.child_count < 2) return lr.cut(lr.mod.p_unit, k);
    Node* lhs = n.children[0];
    Node* rhs = n.children[1];
    lr.scope.enter();

    // Case (2)/(3): memory store.
    if (lhs != null && (lhs.kind == Nk.N_EXPR_INDEX || lhs.kind == Nk.N_EXPR_DEREF))
    {
        return lr.assign_mem(n, k);
    }

    // Case (1): plain rebinding.
    char* lnm = node_text(lhs, lr.it);
    if (lnm == null) lnm = (char*)"_";
    AirCns* rebind = air_ir::air_mk_comu_cns(lr.arena, lnm,
        lr.cut(lr.mod.p_unit, k));
    AirCmd* out;
    if (is_value_node(rhs))
    {
        AirPrd* rv = lr.prd(rhs);
        out = lr.cut(rv, rebind);
    }
    else
    {
        char* xv = lr.fresh_x();
        AirPrd* xp = air_ir::air_mk_var(lr.arena, xv);
        AirCmd* bind = lr.cut(xp, rebind);
        out = lr.expr_to_cns(rhs, air_ir::air_mk_comu_cns(lr.arena, xv, bind));
    }
    lr.scope.leave();
    return out;
}

// assign_mem — emit an ACNS_STORE for `a[i] = v` or `*p = v`.
// We evaluate (and bind) base/ptr first, then index (if indexed), then rhs,
// and finally emit <rhs | store(addr)>; k.
fn AirCmd* AirLower.assign_mem(AirLower* lr, Node* n, AirCns* k)
{
    Node* lhs = n.children[0];
    Node* rhs = n.children[1];
    // After-store continuation: deliver unit to k. We need an AirCns* that
    // receives unit and continues k. Easiest: emit μ̃_. k (ignore incoming unit,
    // then k). That's a COMU that discards its binder and runs k.
    AirCns* after = air_ir::air_mk_comu_cns(lr.arena, lr.dup((char*)"_"),
        lr.cut(lr.mod.p_unit, k));
    (void)lhs; (void)rhs;
    // We need to build the address producer. For *p: addr = p. For a[i]: addr = gep(a, i)
    // — but we don't model GEP in AIR (PEAR emits GEP directly for ACNS_INDEX loads).
    // For stores, we need the ADDRESS of the element, not the loaded value.
    // So we introduce an "addr-of-index" concept: reuse ACNS_INDEX but with a
    // special sentinel tail=null meaning "produce gep address, not load".
    // SIMPLER: wrap the rhs evaluation so that when the rhs value arrives, we
    // already have both the base (and index) bound in fresh vars, then we can
    // construct a gep+store inline via a small bootstrap: we'll use a
    // dedicated consumer ACNS_STORE_INDEX(base, idx, k) that PEAR lowers to
    // gep(base,0,idx) + trunc(value, i8) + store + continue k.
    //
    // Even simpler (bootstrap for 1-byte arrays a[0]): when lhs is N_EXPR_INDEX:
    //   - bind base_b = lr.prd(lhs.children[0]) (must be a pointer var),
    //   - bind index_i = lr.prd(lhs.children[1])
    //   - emit a "store_index(base_b, index_i)" consumer that PEAR lowers.
    // For N_EXPR_DEREF: ACNS_STORE with ptr=base.
    //
    // Bootstrap shortcut: we use ACNS_STORE and build the address using a
    // pseudo "addrof" by directly reusing INDEX consumer with a flag. Since
    // PEAR's ACNS_INDEX handler currently always does load, we need a sibling.
    //
    // Implemented: for indexed stores, emit <rhs | μ̃v. <base | idx_addr(idx, μ̃a. <v|store(a)>; k)>>
    // but that needs an "idx_addr" consumer (gep without load). We add
    // ACNS_STORE_INDEX (tag reused via AirCns field overload) but simpler still:
    // add a new AirCnsTag ACNS_STORE_INDEX that holds base=k.prd and idx via idx.
    //
    // To minimize churn, we do this: evaluate rhs → v; evaluate base → b;
    // evaluate index → i; build a single ACNS_STORE where the "prd" is an index
    // node. PEAR's STORE handler detects an INDEX "prd" and does the gep itself.
    // But STORE.prd is an AirPrd*, not AirCns*. Instead we introduce a new
    // APRD_INDEX_ADDR producer that takes base+idx. Quickest path: we bind
    // base and index to fresh vars, then call a synthetic helper — but we have
    // no helper decls in this bootstrap.
    //
    // Actually SIMPLEST: reuse the INDEX consumer chain, but have it produce
    // the address (not the loaded value) when its .tail is an ACNS_STORE.
    // PEAR's cns(ACNS_INDEX) can check: if tail is ACNS_STORE, pass addr to
    // tail instead of loading. Let's do that.
    //
    // So the plan: build <base | INDEX(idx, STORE(v_addr_holder, after))>.
    // But v comes from rhs. Evaluate rhs first (outermost μ̃v), then base, then
    // use INDEX→STORE with k.prd replaced by the address (which INDEX passes
    // through if tail is STORE). We need to thread v into the store.
    //
    // Structure:
    //   μ̃v. <base | INDEX(idx, STORE_ADDR_V(?, after))>
    // where STORE_ADDR_V stores v into the incoming address, then continues.
    // We can represent v via a COMU wrapping the STORE? No.
    //
    // OK new plan: introduce ACNS_STORE_INDEX that stores the incoming value
    // into gep(base,0,idx). It reads base/idx from k.{prd,idx} (we'll set idx).
    // Actually prd holds the BASE, and idx (long) holds a name-table index of
    // the idx var? No, we need an AirPrd*. Add an AirCns.prd2 field? Too much.
    //
    // Use the existing single-prd + a COMU chain: emit <base | comu(ap, <idx | comu(ip,
    //   <rhs | store_index_addr(ap,ip)>>))>. But store_index_addr needs two
    // producers in scope. ACNS_STORE only takes one "prd" (dst).
    //
    // Workaround: allocate a tiny 2-element "struct" on the fly by making a
    // dedicated consumer ACNS_STORE_INDEX that abuses existing fields: use
    // k.name as a key for the idx-var name (so we can lookup). This is ugly
    // but bootstrap-quality.
    //
    // CLEANEST approach with 0 parser/struct changes:
    //   Use COMU binding order: after binding v, base, idx into fresh vars vb,
    //   bb, ib, emit a final cmd that is < vb | STORE(<bb|INDEX_no_load(ib, μ̃addr.<addr|hole>)>) ; k >
    // Where INDEX_no_load is a new consumer ACNS_GEP (returns addr instead of
    // loading). Add ACNS_GEP and a STORE path that takes addr already.
    //
    // To minimize code churn, let's add ACNS_GEP (produces an address) and
    // use it.

    lr.total_cns++;
    // Fresh names for rhs value, base pointer, index value.
    char* v_v = lr.fresh_x();
    char* b_v = lr.fresh_x();
    char* i_v = null;
    bool has_index = (lhs.kind == Nk.N_EXPR_INDEX);
    AirPrd* vp = air_ir::air_mk_var(lr.arena, v_v);
    AirPrd* bp = air_ir::air_mk_var(lr.arena, b_v);
    AirPrd* ip = null;
    AirPrd* base_prd;
    AirPrd* idx_prd = null;
    Node* base_node;
    Node* idx_node = null;
    if (has_index && lhs.child_count >= 2)
    {
        i_v = lr.fresh_x();
        ip = air_ir::air_mk_var(lr.arena, i_v);
        base_node = lhs.children[0];
        idx_node = lhs.children[1];
    }
    else
    {
        base_node = lhs.child_count > 0 ? lhs.children[0] : null;
    }
    if (base_node == null) { lr.scope.leave(); return lr.cut(lr.mod.p_unit, k); }

    // Build the innermost:  <vp | store(addr_prod)>;  k
    // where addr_prod is <bp | gep(ip, μ̃a.a)> if indexed, else bp.
    // μ̃a.<a|hole> is just the identity continuation (COVAR for a).
    // But we don't have covar for a fresh name easily — use comu_cns with
    // body = lr.cut(a_var, ...) doesn't work without a name for a.
    // Use a simpler trick: create a fresh GEP consumer whose tail is a
    // STORE that will receive the addr from the GEP. But STORE reads dst
    // from k.prd, not from the producer v it receives. Wait in my current
    // pear.c3 code, ACNS_STORE does `ptr = cg.prd_i64(k.prd)` — wrong! The
    // producer v delivered to STORE IS the pointer (for deref stores). For
    // indexed stores I wanted the producer to be the value, and k.prd to be
    // the addr. But that's inconsistent:
    //   *p = v:   <p|μ̃a.<v|store(a)>> — store consumer receives v, a is the
    //             pointer "already in hand". To pass a as dst we need it
    //             embedded in the consumer.
    //   a[i]=v:   evaluate a, i, v; store v into gep(a,0,i). Similarly a and
    //             i must be in the consumer.
    //
    // REFACTORED semantics for ACNS_STORE: "prd" is an AirPrd that evaluates
    // to the destination address (like an index or deref). The producer
    // delivered to STORE (`v`) is the value to store. So for *p = v:
    //   <p | μ̃a.<v | store(var(a))>> where var(a) is a Var prd for a.
    // For a[i]=v:
    //   <a | μ̃ba.<i | μ̃ii.<v | store(gep(ba, ii))>>>
    // where "gep(ba,ii)" is a producer that computes the address. We don't
    // have a GEP producer. Add APRD_GEP(base, idx).
    //
    // OK let's just add a minimal APRD_GEP (two-operand producer) and have
    // PEAR emit gep for it. That's cleanest.
    //
    // For expediency I'll implement this without APRD_GEP for now and instead
    // have ACNS_STORE accept a chain: if k.prd is an INDEX consumer (we're
    // overloading), walk the INDEX to find base/idx. That's too clever.
    //
    // Let me just add: for deref-store the base IS the value coming into
    // STORE. For index-store, we wrap the base evaluation in an INDEX which
    // detects that its tail is STORE and passes the ADDRESS rather than
    // loading. Then the store uses v (its producer = rhs) as value, and the
    // incoming "v" from INDEX is actually the address. That's the cleanest
    // design!
    //
    // REVISED ACNS_INDEX semantics:
    //   - If tail is a "value consumer" (anything except STORE), do GEP+LOAD
    //     and deliver the i8 value (zext to i64) to tail.
    //   - If tail is ACNS_STORE, do GEP only and deliver the ADDRESS to tail
    //     (without loading). Then STORE uses its producer (`v`, the rhs value)
    //     as the store value, and the incoming value (from INDEX) as dst.
    //
    // That means ACNS_STORE should interpret its incoming `v` as the address
    // to store into, and k.prd as... nothing (or a unit). Wait that changes
    // deref-store semantics too: for `*p = v`, we need <p | deref_store_tail(v)>
    // where deref_store_tail is a consumer that takes p (addr) and stores v into it.
    // But v must come from somewhere. So we still need a binder for v.
    //
    // FINAL clean design:
    //   ACNS_STORE means "take the value you receive (producer of the CUT)
    //   as the ADDRESS, truncate k.prd (an AirPrd we already evaluated) to i8,
    //   store into addr, then deliver unit to k.tail."
    //   NO, that flips things: k.prd should be the value, v the addr.
    //   Why have k.prd? Because we need the value to store to be available
    //   when the addr arrives. If we thread addr as the producer arriving
    //   at STORE, then the value-to-store must already be bound (COMU).
    //
    // Actually the SIMPLEST correct encoding:
    //   *p = v: μ̃v_v.<p | deref_store(v_v)>
    //   deref_store is ACNS_STORE where k.prd is v_v (var prd), and on
    //   reception of addr=p, it truncates v_v to i8, stores to addr, then
    //   continues.
    //
    //   a[i]=v: μ̃v_v.<a | idx_store_idx(i, v_v)>
    //   where idx_store_idx is ACNS_INDEX whose tail is ACNS_STORE k.prd=v_v;
    //   ACNS_INDEX sees tail is STORE, does gep, delivers addr to STORE; STORE
    //   receives addr, loads k.prd (v_v), truncates, stores.
    //
    // YES that works. Let me do it.

    // Build ACNS_STORE tail: receives addr, stores v_v to it, continues to after.
    AirCns* store_c = air_ir::air_new_AirCns(lr.arena);
    lr.total_cns++;
    store_c.tag = ACNS_STORE; store_c.prd = vp; store_c.tail = after;
    long store_esz = 1;
    if (has_index) { store_esz = lr.index_elem_size(lhs); }
    else if (lhs.child_count > 0) { store_esz = lr.index_elem_size_for_deref(lhs.children[0]); }
    store_c.idx = store_esz;

    AirCmd* out;
    if (has_index)
    {
        // a[i] = v: <a | INDEX(i, store_c)>
        //         where INDEX on STORE-tail does gep+pass-addr (no load).
        AirCns* idx_c = air_ir::air_mk_index(lr.arena, ip, store_esz, store_c);
        // Emit a as base: if it's a value node, use prd directly; else μ̃bind.
        if (is_value_node(base_node) && is_value_node(idx_node))
        {
            base_prd = lr.prd(base_node);
            idx_prd = lr.prd(idx_node);
            // Wait — ip/bp are fresh var names but base/index are values so
            // no comu needed; rebuild idx_c with the real prds.
            AirCns* idx_c2 = air_ir::air_mk_index(lr.arena, idx_prd, store_esz, store_c);
            out = lr.cut(base_prd, idx_c2);
        }
        else
        {
            // Use the bound var names (bp/ip) in the INDEX chain; wrap with
            // μ̃ binders for non-value subexpressions, right-to-left.
            AirCns* idx_c2 = air_ir::air_mk_index(lr.arena, ip, store_esz, store_c);
            out = lr.cut(bp, idx_c2);
            // Bind index (right-to-left means index wraps outside base).
            if (idx_node != null && !is_value_node(idx_node))
            {
                out = lr.expr_to_cns(idx_node,
                    air_ir::air_mk_comu_cns(lr.arena, i_v, out));
            }
            else if (idx_node != null)
            {
                // index is a value, but we built INDEX using ip (var); emit a
                // LET that binds ip = idx_value first. Use comu: <idx_val|μ̃ip.out>
                AirPrd* ipv = lr.prd(idx_node);
                out = air_ir::air_mk_seq(lr.arena, lr.cut(ipv,
                    air_ir::air_mk_comu_cns(lr.arena, i_v, lr.nop())), out);
            }
            if (!is_value_node(base_node))
            {
                out = lr.expr_to_cns(base_node,
                    air_ir::air_mk_comu_cns(lr.arena, b_v, out));
            }
            else
            {
                AirPrd* bpv = lr.prd(base_node);
                out = air_ir::air_mk_seq(lr.arena, lr.cut(bpv,
                    air_ir::air_mk_comu_cns(lr.arena, b_v, lr.nop())), out);
            }
        }
    }
    else
    {
        // *p = v: <p | store_c>  (store_c receives addr=p, stores vp to it)
        if (is_value_node(base_node))
        {
            AirPrd* pv = lr.prd(base_node);
            out = lr.cut(pv, store_c);
        }
        else
        {
            out = lr.cut(bp, store_c);
            out = lr.expr_to_cns(base_node,
                air_ir::air_mk_comu_cns(lr.arena, b_v, out));
        }
    }
    // Finally wrap with rhs binder: μ̃v_v. out  (evaluate rhs, bind to v_v, then out)
    if (is_value_node(rhs))
    {
        AirPrd* rv = lr.prd(rhs);
        out = lr.cut(rv, air_ir::air_mk_comu_cns(lr.arena, v_v, out));
    }
    else
    {
        out = lr.expr_to_cns(rhs, air_ir::air_mk_comu_cns(lr.arena, v_v, out));
    }
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
        case Nk.N_DECL_IMPL:       return null;
        case Nk.N_DECL_ENUM:       return lr.decl_enum(n);
        case Nk.N_DECL_TYPE:       return lr.decl_type(n);
        case Nk.N_DECL_LET:
        case Nk.N_DECL_CONST:
        case Nk.N_DECL_STATIC:     return lr.decl_letconst(n);
        case Nk.N_DECL_EFFECT:     return lr.decl_effect(n);
        case Nk.N_USE:
        {
            // For `use foo.bar.baz` the sptr/slen covers the full dotted path
            // while children are path components. Prefer sptr when available
            // because node_text() would otherwise only return the first ident.
            char* pth = null;
            if (n.p.sptr != null && n.p.slen > 0)
            {
                pth = lr.arena.dup(n.p.sptr, (usz)n.p.slen);
            }
            else
            {
                pth = node_text(n, lr.it);
            }
            if (pth == null) pth = lr.dup((char*)"?_");
            bool glob = (n.flags & 1) != 0;
            char* als = null;
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) continue;
                if (c.kind == Nk.N_PAT_IDENT)
                {
                    als = node_text(c, lr.it);
                    if (als != null)
                    {
                        als = lr.dup(als);
                        break;
                    }
                }
            }
            AirDecl* d = air_ir::air_mk_import(lr.arena, lr.dup(pth), als, glob);
            lr.total_decl++;
            return d;
        }
        case Nk.N_MODULE:
        {
            char* nm = node_text(n, lr.it);
            if (nm == null) nm = (char*)"M";
            AirDecl* d = air_ir::air_mk_module_decl(lr.arena, lr.dup(nm));
            lr.total_decl++;
            return d;
        }
        default: return null;
    }
}

// reg_clause_pat_params — recurse into a clause pattern (tuple/wild/ident)
// and register one AirDecl param per leaf binder. Fixes clause-style
// `fn add : (i64,i64)->i64 | (a,b) -> a+b` which previously called
// node_text on N_PAT_TUPLE and registered only the first child's text,
// leaving 2-arg fns with arity=1.
fn void AirLower.reg_clause_pat_params(AirLower* lr, AirDecl* dd, Node* pat)
{
    if (pat == null) return;
    switch (pat.kind)
    {
        case Nk.N_PAT_TUPLE:
        {
            for (usz k2 = 0; k2 < pat.child_count; k2++)
            {
                lr.reg_clause_pat_params(dd, pat.children[k2]);
            }
            return;
        }
        case Nk.N_PAT_WILDCARD:
        {
            char* wn = (char*)"_";
            char* wan = lr.scope.bind_var(wn, pat);
            AirBinder* wpb = air_ir::air_mk_binder(lr.arena, wan, lr.mod.t_infer, AMULT_UNR);
            dd.add_param(wpb);
            return;
        }
        default:
        {
            char* pnm = node_text(pat, lr.it);
            if (pnm == null) pnm = (char*)"_";
            char* an = lr.scope.bind_var(pnm, pat);
            AirBinder* pb = air_ir::air_mk_binder(lr.arena, an, lr.mod.t_infer, AMULT_UNR);
            dd.add_param(pb);
            return;
        }
    }
}

fn AirDecl* AirLower.decl_fn(AirLower* lr, Node* n)
{
    // A hoisted nested function is emitted under the AIR name chosen for it.
    char* nm = null;
    for (usz hi = 0; hi < lr.hoist_count; hi++)
    {
        if (lr.hoist_nodes[hi] == n) { nm = lr.hoist_names[hi]; break; }
    }
    if (nm == null) nm = node_text(n, lr.it);
    if (nm == null) nm = (char*)"_fn";
    // libc intrinsics (malloc/free/write) are pre-registered as ADECL_DECLARE
    // externs in AirModule.init. Never let a stray builtin decl synthesize a
    // zero-returning DEF body for them — that made malloc ret 0 and every
    // alloc program wrote through NULL → SIGSEGV.
    if (lr.mod_has_fn(nm))
    {
        bool is_libc = false;
        char* c = nm;
        if (c[0]=='m'&&c[1]=='a'&&c[2]=='l'&&c[3]=='l'&&c[4]=='o'&&c[5]=='c'&&c[6]==0) { is_libc = true; }
        else if (c[0]=='f'&&c[1]=='r'&&c[2]=='e'&&c[3]=='e'&&c[4]==0) { is_libc = true; }
        else if (c[0]=='w'&&c[1]=='r'&&c[2]=='i'&&c[3]=='t'&&c[4]=='e'&&c[5]==0) { is_libc = true; }
        if (is_libc) { return null; }
    }
    char* nm2 = lr.dup(nm);
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DEF, nm2);
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    // Return type: if the fn uses clause syntax (has N_CLAUSE children) the
    // parser attaches an N_TY_FN covering the entire clause as type_ann, so we
    // force t_infer and let PEAR infer the real arrow type. Otherwise trust
    // an explicit N_TY_* annotation.
    AirTyp* rty = lr.mod.t_infer;
    bool has_clauses = false;
    for (usz k2 = 0; k2 < n.child_count; k2++)
    {
        if (n.children[k2] != null && n.children[k2].kind == Nk.N_CLAUSE)
        { has_clauses = true; break; }
    }
    if (!has_clauses && n.type_ann != null && pfront_core::is_type(n.type_ann.kind))
    {
        rty = air_types::air_ty(lr.mod, n.type_ann, lr.it);
    }
    d.ret_ty = rty;
    lr.scope.enter();
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_TYPEPARAM)
        {
            char* tn = node_text(c, lr.it);
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
                pnm = node_text(pp, lr.it);
                if (pnm == null) pnm = (char*)"_";
            }
            if (c.type_ann != null) { pty = air_types::air_ty(lr.mod, c.type_ann, lr.it); }
            else if (c.type_slot != null) { pty = air_types::air_ty(lr.mod, c.type_slot, lr.it); }
            char* an = lr.scope.bind_var(pnm, c);
            AirBinder* pb = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
            d.add_param(pb);
        }
        else if (c.kind == Nk.N_CLAUSE)
        {
            // Gather binders from the FIRST clause only (single-clause fns
            // defined via clause syntax carry their params as patterns here).
            // Multi-clause fns use pattern matching — parameters are still
            // registered from the first clause so call-sites have arity info.
            if (d.param_count == 0)
            {
                // Detect "thunk" clauses: | _ -> body or | () -> body (unit)
                // register no params. Unit is a 0-child N_PAT_TUPLE.
                bool is_thunk = false;
                if (c.child_count == 1 && c.children[0] != null)
                {
                    Node* p0 = c.children[0];
                    if (p0.kind == Nk.N_PAT_WILDCARD) { is_thunk = true; }
                    else if (p0.kind == Nk.N_PAT_TUPLE && p0.child_count == 0) { is_thunk = true; }
                }
                // Does this clause have a non-empty tuple pattern (multi-arg)?
                bool has_nonempty_tuple = false;
                for (usz j = 0; j < c.child_count; j++)
                {
                    Node* cp = c.children[j];
                    if (cp != null && cp.kind == Nk.N_PAT_TUPLE && cp.child_count > 0) { has_nonempty_tuple = true; break; }
                }
                for (usz j = 0; j < c.child_count; j++)
                {
                    Node* cp = c.children[j];
                    if (cp == null) continue;
                    if (!pfront_core::is_pattern(cp.kind)) continue;
                    if (is_thunk) continue;
                    // Skip unit tuple `()` (0-child N_PAT_TUPLE) — no param.
                    if (cp.kind == Nk.N_PAT_TUPLE && cp.child_count == 0) continue;
                    if (has_nonempty_tuple)
                    {
                        // Multi-arg (tuple) pattern: use reg_clause_pat_params to
                        // recurse into tuple children so (a,b) registers TWO
                        // params instead of one (the old node_text returned only
                        // the first child's text).
                        lr.reg_clause_pat_params(d, cp);
                    }
                    else
                    {
                        // Single-arg / wildcard: fall back to legacy registration
                        // to avoid perturbing code paths already known to work.
                        char* pnm; AirTyp* pty = lr.mod.t_infer;
                        if (cp.kind == Nk.N_PAT_WILDCARD) { pnm = (char*)"_"; }
                        else
                        {
                            pnm = node_text(cp, lr.it);
                            if (pnm == null) pnm = (char*)"_";
                        }
                        char* an = lr.scope.bind_var(pnm, cp);
                        AirBinder* pb = air_ir::air_mk_binder(lr.arena, an, pty, AMULT_UNR);
                        d.add_param(pb);
                    }
                }
            }
        }
    }
    char* ret = lr.scope.push_ret("%ret");
    // Build body: prefer single BLOCK child; otherwise walk N_CLAUSEs as match,
    // then walk expr children after the clauses; if nothing, emit <()|%ret>.
    AirCmd* body = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_DECL_TYPEPARAM
            || c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_TY_NAME) continue;
        if (c.kind == Nk.N_CLAUSE) continue; // handled below
        AirCmd* cm;
        bool is_last = true;
        for (usz j = i + 1; j < n.child_count; j++)
        {
            Node* c2 = n.children[j];
            if (c2 == null) continue;
            if (c2.kind == Nk.N_DECL_PARAM || c2.kind == Nk.N_DECL_TYPEPARAM
             || c2.kind == Nk.N_PAT_IDENT || c2.kind == Nk.N_TY_NAME
             || c2.kind == Nk.N_CLAUSE) continue;
            is_last = false;
            break;
        }
        if (is_last && pfront_core::is_expr(c.kind))
        {
            cm = lr.expr_to_cns(c, lr.cns_k(ret));
        }
        else if (c.kind == Nk.N_BLOCK || c.kind == Nk.N_STMT_EXPR)
        {
            cm = lr.cmd(c, ret);
        }
        else
        {
            cm = lr.cmd(c, ret);
        }
        body = body == null ? cm : seq_cmds(lr, body, cm);
    }
    // Multi-clause: if any N_CLAUSE children exist, build a match on the
    // parameter (clause-syntax functions receive their argument via pattern
    // matching). When param_count is 0 we match against unit.
    if (body == null)
    {
        usz ccnt = 0;
        for (usz i = 0; i < n.child_count; i++)
        {
            if (n.children[i] != null && n.children[i].kind == Nk.N_CLAUSE) ccnt++;
        }
        if (ccnt > 0)
        {
            if (ccnt == 1 && d.param_count > 1)
            {
                // Single-clause MULTI-ARG fn (e.g. `(a,b) -> a+b`): params
                // are already registered in outer scope by reg_clause_pat_params.
                //
                // For simple expression-bodied fns (no BLOCK/stmt list), emit
                // body directly without building a match (which would call
                // lr.pat → lr.scope.enter() → shadow-rename a→a_1, leaving
                // the body reading unbound 0). This covers the common
                // "tuple-lambda arithmetic" shape (adders, mul64_hi, etc.).
                //
                // Multi-arg clause fns with a block/stmt body fall through to
                // the legacy match path — their tuple-pattern matching is
                // TODO.
                for (usz i = 0; i < n.child_count; i++)
                {
                    Node* cl = n.children[i];
                    if (cl == null || cl.kind != Nk.N_CLAUSE) continue;
                    Node* body_n = null;
                    bool all_expr = true;
                    usz bcnt = 0;
                    for (usz j = 0; j < cl.child_count; j++)
                    {
                        Node* cp = cl.children[j];
                        if (cp == null) continue;
                        if (pfront_core::is_pattern(cp.kind)) continue;
                        bcnt++;
                        body_n = cp;
                        if (!pfront_core::is_expr(cp.kind)) { all_expr = false; }
                    }
                    if (bcnt == 1 && all_expr && body_n != null
                        && pfront_core::is_expr(body_n.kind))
                    {
                        body = lr.expr_to_cns(body_n, lr.cns_k(ret));
                    }
                    // else: fall through to legacy multi-clause match path
                    // (which will produce a 1-arg scrutinee match on param0
                    // and UB-prune the body since params>1 — conservatively
                    // safe but returns 0 for complex multi-arg clause fns
                    // until proper tuple-match is implemented).
                    break;
                }
            }
            if (body == null)
            {
                AirBranch*[64] bs; usz bc = 0;
                AirPrd* scr;
                if (d.param_count >= 1)
                {
                    char* arg0 = d.params[0].name;
                    scr = air_ir::air_mk_var(lr.arena, arg0);
                }
                else
                {
                    scr = lr.mod.p_unit;
                }
                for (usz i = 0; i < n.child_count; i++)
                {
                    Node* cl = n.children[i];
                    if (cl == null || cl.kind != Nk.N_CLAUSE) continue;
                    AirPat*[16] ps; usz pc = 0;
                    Node* body_n = null;
                    for (usz j = 0; j < cl.child_count; j++)
                    {
                        Node* cp = cl.children[j];
                        if (cp == null) continue;
                        if (pfront_core::is_pattern(cp.kind))
                        {
                            AirPat* pp = lr.pat(cp);
                            if (pp != null && pc < 16) { ps[pc] = pp; pc++; }
                        }
                        else if (pfront_core::is_expr(cp.kind) || cp.kind == Nk.N_BLOCK
                                 || cp.kind == Nk.N_STMT_EXPR)
                        {
                            body_n = cp;
                        }
                    }
                    AirPat* pat;
                    if (pc == 0) { pat = lr.mod.pat_wild; }
                    else if (pc == 1) { pat = ps[0]; }
                    else { pat = air_ir::air_mk_pat_tuple(lr.arena, &ps[0], pc); }
                    lr.scope.enter();
                    AirCmd* bcmd = lr.nop();
                    if (body_n != null)
                    {
                        if (pfront_core::is_expr(body_n.kind))
                        {
                            bcmd = lr.expr_to_cns(body_n, lr.cns_k(ret));
                        }
                        else
                        {
                            bcmd = lr.cmd(body_n, ret);
                        }
                    }
                    lr.scope.leave();
                    AirBranch* br = air_ir::air_mk_branch(lr.arena, pat, bcmd);
                    if (bc < 64) { bs[bc] = br; bc++; }
                }
                if (bc == 0) { body = lr.cut(lr.mod.p_unit, lr.cns_k(ret)); }
                else if (bc == 1 && bs[0].pat == lr.mod.pat_wild && scr == lr.mod.p_unit)
                {
                    // Single `| _ -> expr` with no params: just evaluate expr, no match.
                    body = bs[0].body;
                }
                else
                {
                    body = air_ir::air_mk_match(lr.arena, scr, &bs[0], bc);
                }
            }
        }
        else
        {
            body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
        }
    }
    if (body == null) body = lr.cut(lr.mod.p_unit, lr.cns_k(ret));
    lr.mutilde++;
    d.def_body = air_ir::air_mk_mutilde(lr.arena, ret, body);
    lr.scope.pop_ret();
    lr.scope.leave();
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_extern(AirLower* lr, Node* n)
{
    char* nm = node_text(n, lr.it);
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
                pnm = node_text(pp, lr.it);
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
    char* nm = node_text(n, lr.it);
    if (nm == null) nm = (char*)"S";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_CODATA, lr.dup(nm));
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* f = n.children[i];
        if (f == null) continue;
        if (f.kind != Nk.N_DECL_FIELD) continue;
        char* fnm = node_text(f, lr.it);
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
    char* nm = node_text(n, lr.it);
    if (nm == null) nm = (char*)"E";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DATA, lr.dup(nm));
    d.is_pub = (n.flags & pfront_core::NF_PUB) != 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* v = n.children[i];
        if (v == null) continue;
        if (v.kind != Nk.N_DECL_VARIANT) continue;
        char* vnm = node_text(v, lr.it);
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
    char* nm = node_text(n, lr.it);
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
    char* nm = node_text(n, lr.it);
    if (nm == null) nm = (char*)"_c";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_DEF, lr.dup(nm));
    d.ret_ty = air_types::air_ty(lr.mod, n.type_ann != null ? n.type_ann : n.type_slot, lr.it);
    lr.scope.enter();
    char* ret = lr.scope.push_ret("%ret");
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
    lr.mutilde++;
    d.def_body = air_ir::air_mk_mutilde(lr.arena, ret, body);
    lr.scope.pop_ret();
    lr.scope.leave();
    lr.total_decl++;
    return d;
}

fn AirDecl* AirLower.decl_effect(AirLower* lr, Node* n)
{
    char* nm = node_text(n, lr.it);
    if (nm == null) nm = (char*)"Eff";
    AirDecl* d = air_ir::air_mk_decl(lr.arena, ADECL_EFFECT, lr.dup(nm));
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* op = n.children[i];
        if (op == null) continue;
        if (op.kind != Nk.N_DECL_EFFECT_OP) continue;
        char* onm = node_text(op, lr.it);
        if (onm == null) onm = (char*)"op";
        AirTyp* sig = air_types::air_ty(lr.mod, op.type_ann != null ? op.type_ann : op.type_slot, lr.it);
        AirEffectOp* aop = air_ir::air_mk_eff_op(lr.arena, lr.dup(onm), sig);
        d.add_op(aop);
    }
    lr.total_decl++;
    return d;
}

// ── Top-level driver ─────────────────────────────────────────────────────
// is_terminal_cmd — does this IR command already transfer control
// unconditionally (cut to ret, jump, trap, ub, break, continue)? A seq is
// terminal iff its *first* command is terminal (the rest is dead code).
// is_admin_join_name — is `nm` a freshly minted administrative continuation
// ("%k" + digits, the shape AirScope.fresh_k_covar() mints)?
//
// The LLVM backend (pear.c3 Codegen.cns, ACNS_COVAR) implements <v|%kN> as a
// JOIN: it positions the builder at block kN (creating it if this is the first
// occurrence), emits the branch, and then emits the FOLLOWING commands into
// that block. So a join cut is not a control transfer out of the current
// region — the rest of the command stream is its body. Pruning commands after
// such a cut (as a plain covar cut is pruned) silently deleted live code.
fn bool is_admin_join_name(char* nm)
{
    if (nm == null) return false;
    if (nm[0] != '%' || nm[1] != 'k') return false;
    if (nm[2] < '0' || nm[2] > '9') return false;
    return true;
}

fn bool is_terminal_cmd(AirCmd* c)
{
    if (c == null) return false;
    switch (c.tag)
    {
        case ACMD_JUMP: case ACMD_TRAP: case ACMD_UB:
        case ACMD_BREAK: case ACMD_CONTINUE: case ACMD_RET:
            return true;
        case ACMD_CUT:
        {
            // A cut <v|k> is terminal when k is a covariable (named
            // continuation point): %ret, α from a μα, %lbl, etc. This
            // is a direct control transfer; anything after is dead.
            //
            // EXCEPTION: administrative join covariables %kN — see
            // is_admin_join_name(). The backend turns those into a block that
            // the rest of the stream flows into, so following commands are live.
            //
            // We do NOT look through μ̃/if/match here because those
            // require a deeper analysis that we leave to PEAR passes.
            if (c.cns != null && c.cns.tag == ACNS_COVAR)
            {
                return !is_admin_join_name(c.cns.name);
            }
            return false;
        }
        case ACMD_SEQ:
            return is_terminal_cmd(c.body);
        case ACMD_MU:
            return is_terminal_cmd(c.body);
        case ACMD_MUTILDE:
            return is_terminal_cmd(c.body);
        case ACMD_LET:
            return is_terminal_cmd(c.body);
        default: return false;
    }
}

fn bool is_nop_cmd(AirCmd* c)
{
    if (c == null) return true;
    if (c.tag == ACMD_CUT
        && c.prd != null && c.prd.tag == APRD_UNIT
        && c.cns != null && c.cns.tag == ACNS_COVAR) return true;
    return false;
}

// seq — build a sequence, dropping nop/terminal dead code.
fn AirCmd* seq_cmds(AirLower* lr, AirCmd* a, AirCmd* b)
{
    if (a == null || is_nop_cmd(a)) return b;
    if (b == null || is_nop_cmd(b)) return a;
    if (is_terminal_cmd(a)) return a; // b is dead
    return air_ir::air_mk_seq(lr.arena, a, b);
}

// eval_then — evaluate expression n, bind its value to k's top, then run rest.
// (Used when we need sequencing but don't want to bother with μ̃ binding.)
fn AirCmd* eval_then(AirLower* lr, Node* n, AirCns* k, AirCmd* rest)
{
    AirCmd* c = lr.expr_to_cns(n, k);
    return seq_cmds(lr, c, rest);
}

// walk_decls — recursive descent through the post-theory AST, collecting
// N_MODULE/N_PROGRAM/N_BLOCK/N_STMT_EXPR children. N_MODULEs emit an
// ADECL_MODULE followed by their contained decls.
//
// IMPORTANT: we must NOT blindly recurse into the children of every decl,
// because that would drag local let-bindings (nested inside fn bodies,
// block exprs, etc.) up to the top level as spurious `def _c { … }`
// entries. We only recurse into structural "container" nodes that
// legitimately hold more top-level decls.
fn void AirLower.walk_decls(AirLower* lr, Node* n)
{
    if (n == null) return;
    switch (n.kind)
    {
        case Nk.N_PROGRAM:
        case Nk.N_MODULE:
        {
            if (n.kind == Nk.N_MODULE)
            {
                AirDecl* md = lr.decl(n);
                if (md != null) lr.mod.add_decl(md);
            }
            for (usz i = 0; i < n.child_count; i++)
            {
                lr.walk_decls(n.children[i]);
            }
            return;
        }
        case Nk.N_USE:
        {
            // `use` items may have nested use-tree children; recurse to
            // find them, but `use` isn't itself a value decl so don't
            // call decl_inner().
            for (usz i = 0; i < n.child_count; i++)
            {
                lr.walk_decls(n.children[i]);
            }
            return;
        }
        default:
        {
            if (pfront_core::is_decl(n.kind))
            {
                lr.decl_inner(n);
            }
            // Do NOT recurse into children: any nested blocks / function
            // bodies / let-inits will be reached via decl() which lowers
            // them into their enclosing ADECL's body, not as separate
            // top-level defs.  This prevents e.g. `fn main { let _ = f(); }`
            // from leaking a stray `def _c { … }` into the module.
            return;
        }
    }
}

// module_body — driver. Sets up the return covariable on the scope and
// walks the tree; decl_inner takes care of registering each decl into
// lr.mod. Call this once per AirModule you want populated.
fn void AirLower.module_body(AirLower* lr, Node* root)
{
    // Whole-program emission calls this once per loaded module; the hoist list
    // belongs to the module being lowered NOW, so it must start empty each time
    // (otherwise module N's nested functions are emitted again for module N+1).
    lr.hoist_count = 0;
    lr.scope.enter();
    // Bind %ret as the top-level return covariable (for top-level exprs
    // and any accidental free `return` at module scope).
    (void)lr.scope.bind_covar("%ret", root);
    lr.walk_decls(root);
    // Emit nested functions collected while lowering bodies (hoist_local_fn).
    for (usz i = 0; i < lr.hoist_count; i++)
    {
        Node* fn_node = lr.hoist_nodes[i];
        if (fn_node != null) { lr.decl_inner(fn_node); }
    }
    lr.scope.leave();
}
