// ============================================================================
// theory_defun.c3 — Closure analysis: free variables, escape, capture hazards
// ----------------------------------------------------------------------------
// Reynolds 1972 (definitional interpreters: defunctionalisation), Johnsson
// 1985 (lambda lifting), Appel 1992 (Compiling with Continuations, closure
// conversion), Shao & Appel 1994 (space-efficient closure representations),
// Kennedy 2007 (Compiling with continuations, continued).
//
// Closure conversion in PEAR needs three facts about every lambda that only
// the front end can establish cheaply, and one of them is a correctness
// requirement, not an optimisation:
//
//   FREE VARIABLES   by binder identity — an inner `n` that shadows an outer
//                    `n` is not a capture (the old pass compared names).
//   ESCAPE           does the closure outlive the expression that creates
//                    it? returned · passed to a call · stored into an
//                    aggregate / through a pointer · assigned to an outer
//                    binder · captured by another closure that escapes. A
//                    lambda bound by `let f = …` inherits the fate of `f`:
//                    if every use of `f` is a direct call, it does not
//                    escape and can be lambda-lifted or inlined outright.
//   MUTABLE CAPTURE  a `let mut` captured by a closure is shared state: the
//                    closure reads and writes the VARIABLE, not a snapshot
//                    (that is the semantics NbE's β already implements).
//                    If such a closure escapes, the variable outlives its
//                    frame and must be boxed. We record this on the binder
//                    as NF_ADDR_TAKEN — the same fact `&x` establishes — so
//                    liveness, the optimiser's dead-store elimination and
//                    the backend's alloca decisions all see it.
//
// Verdicts per lambda are written back to the AST: NF_NOESCAPE on the
// N_EXPR_LAMBDA, so NbE / the backend can treat it as a local function.
//
// Diagnostics:
//   W4190  closure escapes and captures a `let mut`: shared mutable state
//          outlives the frame (boxed capture required; note under --lint,
//          warning if the closure is also written through)
//   N4191  a captured variable is reassigned after the closure is created
//          and before it is called: the closure will see the new value
//   N4192  (--lint) non-escaping, single-use lambda: inline candidate
//   W4193  call of a let-bound lambda with the wrong number of arguments
//   W4194  a let-bound lambda is never used
// ============================================================================

module theory_defun;

import pfront_lex;
import pfront_core;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz DF_MAX_LAMBDAS  = 2048;
const usz DF_MAX_CAPTURES = 32;      // per lambda
const usz DF_MAX_BINDERS  = 256;     // binders local to one lambda
const int DF_MAX_DEPTH    = 200;

enum Esc : char
{
    ESC_NONE,        // only ever called directly
    ESC_RETURNED,
    ESC_ARG,         // passed to a call
    ESC_STORED,      // into an aggregate / through a pointer / outer binder
    ESC_CAPTURED,    // captured by another closure that escapes
    ESC_UNKNOWN      // used as a value in a way we do not classify
}

struct Capture
{
    Node* binder;        // the captured binder (pat-ident / param)
    bool  is_mut;        // declared `let mut`
    bool  written;       // the closure assigns to it
    uint  name;
}

struct Lambda
{
    Node*   node;
    Node*   owner_fn;    // the fn (or outer lambda) it appears in
    Node*   bound_to;    // `let f = fn …` binder, if any
    usz     n_params;
    Capture[DF_MAX_CAPTURES] caps;
    usz     n_caps;
    Esc     esc;
    Node*   esc_at;
    usz     direct_calls;
    usz     value_uses;  // uses of the binder that are not calls
    bool    immediate;   // (fn …)(args)
}

struct DefunState
{
    Arena*    arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;

    Lambda*   lams;
    usz       n_lams;

    // scratch for free-variable computation
    Node**    local_binders;
    usz       n_local;

    // counts
    usz n_captures;
    usz n_mut_captures;
    usz n_written_captures;
    usz n_escaping;
    usz n_returned;
    usz n_arg;
    usz n_stored;
    usz n_captured;
    usz n_noescape;
    usz n_inline;
    usz n_immediate;
    usz n_direct_calls;
    usz n_boxed_binders;
    usz n_stale;
    usz n_arity;
    usz n_unused;
    usz max_caps;
}

fn void DefunState.attach(DefunState* ds, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    ds.diags = d; ds.interner = it; ds.file = file;
}

fn char* DefunState.name(DefunState* ds, uint id)
{
    if (ds.interner == null || id == 0) { return "_"; }
    return ds.interner.text(id);
}

fn char* DefunState.msgbuf(DefunState* ds)
{
    char* m = (char*)ds.arena.alloc(320, 1);
    if (m != null) { m[0] = 0; }
    return m;
}

fn void DefunState.warn(DefunState* ds, int code, Node* at, char* msg)
{
    if (ds.diags == null || at == null || msg == null) { return; }
    ds.diags.warn(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, ds.file);
}
fn void DefunState.note(DefunState* ds, int code, Node* at, char* msg)
{
    if (ds.diags == null || at == null || msg == null) { return; }
    ds.diags.note(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, ds.file);
}

// ── Binders ─────────────────────────────────────────────────────────────────
fn bool is_local_binder(Node* b)
{
    if (b == null) { return false; }
    return b.kind == Nk.N_PAT_IDENT || b.kind == Nk.N_DECL_PARAM;
}

fn bool binder_is_mut(Node* b)
{
    if (b == null) { return false; }
    if ((b.flags & pfront_core::NF_MUT) != 0) { return true; }
    // `let mut x` carries the flag on the let; the pat-ident is its child
    Node* p = b.parent;
    if (p != null && p.kind == Nk.N_DECL_LET && (p.flags & pfront_core::NF_MUT) != 0) { return true; }
    return false;
}

fn void DefunState.collect_local_binders(DefunState* ds, Node* n, int depth)
{
    if (n == null || depth > DF_MAX_DEPTH) { return; }
    if ((n.kind == Nk.N_PAT_IDENT || n.kind == Nk.N_DECL_PARAM) && ds.n_local < DF_MAX_BINDERS)
    {
        ds.local_binders[ds.n_local] = n; ds.n_local = ds.n_local + 1;
    }
    for (usz i = 0; i < n.child_count; i++) { ds.collect_local_binders(n.children[i], depth + 1); }
}

fn bool DefunState.is_local(DefunState* ds, Node* b)
{
    for (usz i = 0; i < ds.n_local; i++) { if (ds.local_binders[i] == b) { return true; } }
    return false;
}

fn Capture* lam_capture(Lambda* l, Node* binder)
{
    for (usz i = 0; i < l.n_caps; i++) { if (l.caps[i].binder == binder) { return &l.caps[i]; } }
    return null;
}

// Free variables: identifiers inside the lambda whose binder is a local of
// an ENCLOSING scope (not declared inside the lambda, not a top-level decl).
fn void DefunState.collect_free(DefunState* ds, Lambda* l, Node* n, bool as_lhs, int depth)
{
    if (n == null || depth > DF_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null && is_local_binder(n.resolved) && !ds.is_local(n.resolved))
    {
        Capture* c = lam_capture(l, n.resolved);
        if (c == null && l.n_caps < DF_MAX_CAPTURES)
        {
            c = &l.caps[l.n_caps];
            c.binder = n.resolved; c.is_mut = binder_is_mut(n.resolved); c.written = false; c.name = n.name_id;
            l.n_caps = l.n_caps + 1;
        }
        if (c != null && as_lhs) { c.written = true; }
        return;
    }
    if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        if (n.child_count >= 1) { ds.collect_free(l, n.children[0], true, depth + 1); }
        for (usz i = 1; i < n.child_count; i++) { ds.collect_free(l, n.children[i], false, depth + 1); }
        return;
    }
    if (n.kind == Nk.N_EXPR_REF && n.child_count >= 1 && (n.flags & pfront_core::NF_MUT) != 0)
    {
        ds.collect_free(l, n.children[0], true, depth + 1);
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { ds.collect_free(l, n.children[i], as_lhs && i == 0 && (n.kind == Nk.N_EXPR_INDEX || n.kind == Nk.N_EXPR_FIELD || n.kind == Nk.N_EXPR_DEREF), depth + 1); }
}

fn usz lambda_param_count(Node* lam)
{
    usz n = 0;
    for (usz i = 0; i < lam.child_count; i++)
    {
        Node* c = lam.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM) { n = n + 1; }
        else if (c.kind == Nk.N_CLAUSE)
        {
            // `fn | (x, y) -> …`: the first clause's pattern is the parameter list
            for (usz j = 0; j < c.child_count; j++)
            {
                Node* pat = c.children[j];
                if (pat == null || !pfront_core::is_pattern(pat.kind)) { continue; }
                if (pat.kind == Nk.N_PAT_TUPLE)
                {
                    for (usz k = 0; k < pat.child_count; k++) { if (pat.children[k] != null && pfront_core::is_pattern(pat.children[k].kind)) { n = n + 1; } }
                }
                else { n = n + 1; }
                break;
            }
            return n;
        }
    }
    return n;
}

// ── Escape classification ───────────────────────────────────────────────────
// Is `n` in tail (returned) position of `fn_node`'s body?
fn bool in_tail_of_fn(Node* n, Node* fn_node, int depth)
{
    if (n == null || fn_node == null || depth > DF_MAX_DEPTH) { return false; }
    Node* p = n.parent;
    if (p == null) { return false; }
    if (p == fn_node) { return true; }
    switch (p.kind)
    {
        case N_CLAUSE:
            return p.child_count >= 1 && p.children[p.child_count - 1] == n && p.parent == fn_node;
        case N_BLOCK:
            if (p.child_count >= 1 && p.children[p.child_count - 1] == n) { return in_tail_of_fn(p, fn_node, depth + 1); }
            return false;
        case N_EXPR_IF:
            if (p.child_count >= 2 && p.children[0] != n) { return in_tail_of_fn(p, fn_node, depth + 1); }
            return false;
        case N_MATCH_ARM:
            if (p.child_count >= 1 && p.children[p.child_count - 1] == n) { return in_tail_of_fn(p, fn_node, depth + 1); }
            return false;
        case N_EXPR_MATCH:
            if (p.child_count >= 1 && p.children[0] != n) { return in_tail_of_fn(p, fn_node, depth + 1); }
            return false;
        case N_STMT_RETURN:
            return true;
        case N_EXPR_UNSAFE:
        case N_EXPR_CAST:
            return in_tail_of_fn(p, fn_node, depth + 1);
        default:
            return false;
    }
}

// Classify how the VALUE at `n` (a lambda or an ident bound to one) is used.
fn Esc classify_use(Node* n, Node* owner_fn, Node** at)
{
    Node* p = n.parent;
    *at = n;
    if (p == null) { return Esc.ESC_UNKNOWN; }
    // look through casts / unsafe
    while (p != null && (p.kind == Nk.N_EXPR_CAST || p.kind == Nk.N_EXPR_UNSAFE)) { n = p; p = p.parent; }
    if (p == null) { return Esc.ESC_UNKNOWN; }
    switch (p.kind)
    {
        case N_EXPR_CALL:
            if (p.child_count >= 1 && p.children[0] == n) { return Esc.ESC_NONE; }   // callee
            *at = p; return Esc.ESC_ARG;
        case N_EXPR_METHOD:
            *at = p; return Esc.ESC_ARG;
        case N_STMT_RETURN:
            *at = p; return Esc.ESC_RETURNED;
        case N_DECL_LET:
            return Esc.ESC_NONE;    // handled by the binder analysis
        case N_STMT_ASSIGN:
        case N_EXPR_ASSIGN:
            *at = p; return Esc.ESC_STORED;
        case N_EXPR_TUPLE:
        case N_EXPR_ARRAY:
        case N_EXPR_STRUCT_LIT:
        case N_EXPR_FIELD_INIT:
            *at = p; return Esc.ESC_STORED;
        case N_EXPR_LAMBDA:
            *at = p; return Esc.ESC_CAPTURED;
        case N_EXPR_PERFORM:
        case N_EXPR_RESUME:
            *at = p; return Esc.ESC_ARG;
        default:
            break;
    }
    if (in_tail_of_fn(n, owner_fn, 0)) { *at = n; return Esc.ESC_RETURNED; }
    return Esc.ESC_UNKNOWN;
}

fn Esc esc_max(Esc a, Esc b) { return (int)a >= (int)b ? a : b; }

// Uses of a let-bound lambda's binder throughout the owner function.
fn void DefunState.scan_binder_uses(DefunState* ds, Lambda* l, Node* n, int depth)
{
    if (n == null || depth > DF_MAX_DEPTH || l.bound_to == null) { return; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved == l.bound_to)
    {
        Node* at;
        Esc e = classify_use(n, l.owner_fn, &at);
        if (e == Esc.ESC_NONE && n.parent != null && n.parent.kind == Nk.N_EXPR_CALL && n.parent.children[0] == n)
        {
            l.direct_calls = l.direct_calls + 1;
            usz nargs = n.parent.child_count - 1;
            if (nargs != l.n_params)
            {
                ds.n_arity = ds.n_arity + 1;
                char* m = ds.msgbuf();
                if (m != null)
                {
                    snprintf(m, 320, "`%s` is a lambda of %d parameter%s but is called here with %d argument%s",
                             ds.name(n.name_id), (int)l.n_params, l.n_params == 1 ? "" : "s", (int)nargs, nargs == 1 ? "" : "s");
                    ds.warn(4193, n.parent, m);
                }
            }
        }
        else if (e == Esc.ESC_NONE)
        {
            // an ident whose parent is a let: `let g = f` — an alias; treat as stored
            l.value_uses = l.value_uses + 1;
            if ((int)Esc.ESC_STORED > (int)l.esc) { l.esc = Esc.ESC_STORED; l.esc_at = n; }
        }
        else
        {
            l.value_uses = l.value_uses + 1;
            if ((int)e > (int)l.esc) { l.esc = e; l.esc_at = at; }
        }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { ds.scan_binder_uses(l, n.children[i], depth + 1); }
}

// A captured variable assigned between the lambda's creation and a use of
// the lambda, in the same block: the closure sees the new value.
fn void DefunState.check_stale(DefunState* ds, Lambda* l)
{
    if (l.bound_to == null || l.n_caps == 0) { return; }
    Node* let = l.bound_to.parent;
    if (let == null || let.kind != Nk.N_DECL_LET) { return; }
    Node* blk = let.parent;
    if (blk == null || blk.kind != Nk.N_BLOCK) { return; }
    usz start = 0;
    for (usz i = 0; i < blk.child_count; i++) { if (blk.children[i] == let) { start = i + 1; break; } }
    for (usz i = start; i < blk.child_count; i++)
    {
        Node* st = blk.children[i];
        if (st == null) { continue; }
        if ((st.kind == Nk.N_STMT_ASSIGN || st.kind == Nk.N_STMT_COMPOUND_ASSIGN) && st.child_count >= 1
            && st.children[0] != null && st.children[0].kind == Nk.N_EXPR_IDENT)
        {
            Capture* c = lam_capture(l, st.children[0].resolved);
            if (c == null) { continue; }
            // is the lambda used after this statement?
            bool used_after = false;
            for (usz j = i + 1; j < blk.child_count && !used_after; j++) { used_after = mentions_binder(blk.children[j], l.bound_to, 0); }
            if (!used_after) { continue; }
            ds.n_stale = ds.n_stale + 1;
            char* m = ds.msgbuf();
            if (m != null)
            {
                snprintf(m, 320, "`%s` is reassigned here after the closure `%s` (created at %d:%d) captured it: the closure reads the variable, not a snapshot, so it will see this new value",
                         ds.name(c.name), ds.name(l.bound_to.name_id), l.node.line, l.node.col);
                ds.note(4191, st, m);
            }
            return;
        }
    }
}

fn bool mentions_binder(Node* n, Node* b, int depth)
{
    if (n == null || depth > DF_MAX_DEPTH) { return false; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved == b) { return true; }
    for (usz i = 0; i < n.child_count; i++) { if (mentions_binder(n.children[i], b, depth + 1)) { return true; } }
    return false;
}

// ── Per-lambda analysis ─────────────────────────────────────────────────────
fn void DefunState.analyse_lambda(DefunState* ds, Node* lam, Node* owner_fn)
{
    if (ds.n_lams >= DF_MAX_LAMBDAS) { return; }
    Lambda* l = &ds.lams[ds.n_lams];
    ds.n_lams = ds.n_lams + 1;
    l.node = lam; l.owner_fn = owner_fn; l.bound_to = null; l.n_caps = 0;
    l.esc = Esc.ESC_NONE; l.esc_at = null; l.direct_calls = 0; l.value_uses = 0; l.immediate = false;
    l.n_params = lambda_param_count(lam);

    // free variables
    ds.n_local = 0;
    ds.collect_local_binders(lam, 0);
    for (usz i = 0; i < lam.child_count; i++)
    {
        Node* c = lam.children[i];
        if (c == null || c.kind == Nk.N_DECL_PARAM) { continue; }
        ds.collect_free(l, c, false, 0);
    }
    ds.n_captures = ds.n_captures + l.n_caps;
    if (l.n_caps > ds.max_caps) { ds.max_caps = l.n_caps; }
    for (usz i = 0; i < l.n_caps; i++)
    {
        if (l.caps[i].is_mut) { ds.n_mut_captures = ds.n_mut_captures + 1; }
        if (l.caps[i].written) { ds.n_written_captures = ds.n_written_captures + 1; }
    }

    // where does the lambda expression itself go?
    Node* p = lam.parent;
    if (p != null && p.kind == Nk.N_DECL_LET)
    {
        for (usz i = 0; i < p.child_count; i++)
        {
            Node* c = p.children[i];
            if (c != null && c.kind == Nk.N_PAT_IDENT) { l.bound_to = c; break; }
        }
        if (l.bound_to != null) { ds.scan_binder_uses(l, owner_fn, 0); }
        else { l.esc = Esc.ESC_STORED; l.esc_at = p; }     // destructuring let
    }
    else if (p != null && p.kind == Nk.N_EXPR_CALL && p.child_count >= 1 && p.children[0] == lam)
    {
        l.immediate = true; l.direct_calls = 1;
        ds.n_immediate = ds.n_immediate + 1;
        usz nargs = p.child_count - 1;
        if (nargs != l.n_params)
        {
            ds.n_arity = ds.n_arity + 1;
            char* m = ds.msgbuf();
            if (m != null)
            {
                snprintf(m, 320, "this lambda of %d parameter%s is applied to %d argument%s",
                         (int)l.n_params, l.n_params == 1 ? "" : "s", (int)nargs, nargs == 1 ? "" : "s");
                ds.warn(4193, p, m);
            }
        }
    }
    else
    {
        Node* at;
        l.esc = classify_use(lam, owner_fn, &at); l.esc_at = at;
        if (l.esc == Esc.ESC_NONE) { l.esc = Esc.ESC_UNKNOWN; }
    }

    // a captured lambda escapes if its captor does — resolved in a second pass
    // (the captor is analysed later in walk order); approximate here as escape
    ds.n_direct_calls = ds.n_direct_calls + l.direct_calls;

    // verdicts
    if (l.esc == Esc.ESC_NONE)
    {
        ds.n_noescape = ds.n_noescape + 1;
        lam.flags = lam.flags | pfront_core::NF_NOESCAPE;      // "does not escape" on a lambda
        if (l.bound_to != null && l.direct_calls == 0 && l.value_uses == 0)
        {
            ds.n_unused = ds.n_unused + 1;
            char* m = ds.msgbuf();
            if (m != null)
            {
                snprintf(m, 320, "the lambda bound to `%s` is never used", ds.name(l.bound_to.name_id));
                ds.warn(4194, l.bound_to.parent != null ? l.bound_to.parent : lam, m);
            }
        }
        else if (l.direct_calls == 1 && !l.immediate)
        {
            ds.n_inline = ds.n_inline + 1;
            if (ds.diags != null && ds.diags.advisories)
            {
                char* m = ds.msgbuf();
                if (m != null)
                {
                    snprintf(m, 320, "the lambda bound to `%s` does not escape and is called exactly once: it can be inlined at its call site",
                             l.bound_to != null ? ds.name(l.bound_to.name_id) : "_");
                    ds.note(4192, lam, m);
                }
            }
        }
    }
    else
    {
        ds.n_escaping = ds.n_escaping + 1;
        if (l.esc == Esc.ESC_RETURNED) { ds.n_returned = ds.n_returned + 1; }
        else if (l.esc == Esc.ESC_ARG) { ds.n_arg = ds.n_arg + 1; }
        else if (l.esc == Esc.ESC_STORED) { ds.n_stored = ds.n_stored + 1; }
        else if (l.esc == Esc.ESC_CAPTURED) { ds.n_captured = ds.n_captured + 1; }
        // mutable captures outlive their frame: mark the binder address-taken
        for (usz i = 0; i < l.n_caps; i++)
        {
            Capture* c = &l.caps[i];
            if (!c.is_mut && !c.written) { continue; }
            if ((c.binder.flags & pfront_core::NF_ADDR_TAKEN) == 0)
            {
                c.binder.flags = c.binder.flags | pfront_core::NF_ADDR_TAKEN;
                ds.n_boxed_binders = ds.n_boxed_binders + 1;
            }
            char* m = ds.msgbuf();
            if (m == null) { continue; }
            char* how = l.esc == Esc.ESC_RETURNED ? "is returned" : l.esc == Esc.ESC_ARG ? "is passed to a call"
                      : l.esc == Esc.ESC_STORED ? "is stored" : l.esc == Esc.ESC_CAPTURED ? "is captured by another closure" : "escapes";
            if (c.written)
            {
                snprintf(m, 320, "this closure writes to the captured `let mut %s` and %s: `%s` is shared mutable state that outlives the frame of `%s` (it must live in a box, not on the stack)",
                         ds.name(c.name), how, ds.name(c.name), owner_fn != null ? ds.name(owner_fn.name_id) : "?");
                ds.warn(4190, lam, m);
            }
            else if (ds.diags != null && ds.diags.advisories)
            {
                snprintf(m, 320, "this closure captures the `let mut %s` and %s: `%s` outlives the frame of `%s` and must be boxed",
                         ds.name(c.name), how, ds.name(c.name), owner_fn != null ? ds.name(owner_fn.name_id) : "?");
                ds.note(4190, lam, m);
            }
        }
    }
    ds.check_stale(l);
}

// ── Walk ────────────────────────────────────────────────────────────────────
fn void DefunState.walk(DefunState* ds, Node* n, Node* owner_fn, int depth)
{
    if (n == null || depth > DF_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN) { owner_fn = n; }
    if (n.kind == Nk.N_EXPR_LAMBDA)
    {
        ds.analyse_lambda(n, owner_fn);
        // nested lambdas: their owner for escape purposes is this lambda
        for (usz i = 0; i < n.child_count; i++) { ds.walk(n.children[i], n, depth + 1); }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { ds.walk(n.children[i], owner_fn, depth + 1); }
}

// Second pass: a lambda captured by an escaping closure escapes too.
fn void DefunState.propagate_captured(DefunState* ds)
{
    bool changed = true; int rounds = 0;
    while (changed && rounds < 8)
    {
        changed = false; rounds = rounds + 1;
        for (usz i = 0; i < ds.n_lams; i++)
        {
            Lambda* l = &ds.lams[i];
            if (l.esc != Esc.ESC_CAPTURED || l.esc_at == null) { continue; }
            // find the captor
            for (usz j = 0; j < ds.n_lams; j++)
            {
                if (ds.lams[j].node != l.esc_at) { continue; }
                if (ds.lams[j].esc == Esc.ESC_NONE)
                {
                    // captor does not escape: neither do we, unless used as a value inside it
                    l.esc = Esc.ESC_NONE;
                    l.node.flags = l.node.flags | pfront_core::NF_NOESCAPE;
                    ds.n_escaping = ds.n_escaping - 1; ds.n_captured = ds.n_captured - 1; ds.n_noescape = ds.n_noescape + 1;
                    changed = true;
                }
            }
        }
    }
}

// ── Lifecycle ───────────────────────────────────────────────────────────────
fn void DefunState.init(DefunState* ds, Arena* a)
{
    ds.arena = a;
    ds.diags = null; ds.interner = null; ds.file = "";
    ds.lams = (Lambda*)calloc(DF_MAX_LAMBDAS, Lambda::size);
    ds.local_binders = (Node**)calloc(DF_MAX_BINDERS, 8);
    ds.n_lams = 0; ds.n_local = 0;
    ds.n_captures = 0; ds.n_mut_captures = 0; ds.n_written_captures = 0;
    ds.n_escaping = 0; ds.n_returned = 0; ds.n_arg = 0; ds.n_stored = 0; ds.n_captured = 0;
    ds.n_noescape = 0; ds.n_inline = 0; ds.n_immediate = 0; ds.n_direct_calls = 0;
    ds.n_boxed_binders = 0; ds.n_stale = 0; ds.n_arity = 0; ds.n_unused = 0; ds.max_caps = 0;
}

fn void DefunState.run(DefunState* ds, Node* root)
{
    if (ds.lams == null) { return; }
    ds.n_lams = 0;
    ds.walk(root, null, 0);
    ds.propagate_captured();
}

fn void DefunState.report(DefunState* ds)
{
    printf("  closures         : %d lambdas, %d captures (%d mutable, %d written; max %d per closure), %d binders marked address-taken for boxing\n",
           (int)ds.n_lams, (int)ds.n_captures, (int)ds.n_mut_captures, (int)ds.n_written_captures, (int)ds.max_caps, (int)ds.n_boxed_binders);
    printf("  closure-escape   : %d escape (%d returned, %d as argument, %d stored, %d via another closure), %d do not (%d immediate, %d inline candidates, %d direct calls)\n",
           (int)ds.n_escaping, (int)ds.n_returned, (int)ds.n_arg, (int)ds.n_stored, (int)ds.n_captured,
           (int)ds.n_noescape, (int)ds.n_immediate, (int)ds.n_inline, (int)ds.n_direct_calls);
    printf("  closure-hazards  : %d stale captures, %d arity mismatches, %d unused lambdas\n",
           (int)ds.n_stale, (int)ds.n_arity, (int)ds.n_unused);
}

fn void DefunState.destroy(DefunState* ds)
{
    if (ds.lams != null) { free((void*)ds.lams); ds.lams = null; }
    if (ds.local_binders != null) { free((void*)ds.local_binders); ds.local_binders = null; }
}
