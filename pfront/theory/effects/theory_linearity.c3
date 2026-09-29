// ============================================================================
// theory_linearity.c3 — Linear / affine resource tracking (ownership)
// ----------------------------------------------------------------------------
// Linear logic (Girard 1987) classifies hypotheses by how many times they are
// USED: linear (exactly once), affine (at most once), relevant (at least
// once), unrestricted (any number). Wadler 1990 showed the same discipline
// makes in-place update safe; Rust made it the ownership model.
//
// Pride has one resource that is linear by construction: the result of
// `alloc`. It must be released by `free` EXACTLY ONCE on EVERY path, and it
// must not be touched afterwards. This pass is a flow-sensitive ownership
// analysis over the resolved AST, per function, in statement order:
//
//   resources    every `alloc` creates one; a parameter is a resource of
//                unknown provenance (never reported as leaked, but freeing
//                it twice or using it after `free` is still wrong)
//   aliases      `let q = p`, `p = q` bind another name to the SAME
//                resource; freeing through any alias frees the resource
//   states       LIVE → FREED (at L:C) ; LIVE → ESCAPED (returned, stored,
//                passed to a call, captured, borrowed) ; joins of paths
//                that disagree give MAYBE-FREED with the branch that freed
//   defer        `defer free p` releases p at scope exit: no leak; an
//                explicit `free p` on top is a double free
//   loops        the body is analysed twice — a `free` of an outer resource
//                that is reached again is a double free on iteration two
//
// Diagnostics:
//   W4160  double free            `p` is freed here but was already freed at L:C
//   W4161  use after free         `p` is used here but was freed at L:C
//   W4162  leak                   `p` allocated at L:C is never freed (on this path)
//   N4163  may be freed twice     freed at L:C when <branch> is taken
//   N4164  may be used after free
//   N4165  may leak               freed on one branch of the `if` at L:C only
//   W4166  overwritten while owned  `p` is reassigned but still owns the block from L:C
//
// The multiplicity census (unused / once / multi per local) is kept: it is
// what an in-place-update optimisation would consult, and it is reported.
//
// Not claimed: ownership through struct fields or arrays (`free v.data`
// is not tracked), through calls (a callee that frees its argument is an
// ESCAPE here, not a free), or across functions. Nothing here is a type
// system; it is the ownership discipline the spec already imposes on
// `alloc`/`free`, checked.
//
// References:
//   Girard 1987 "Linear Logic"; Wadler 1990 "Linear types can change the
//   world!"; Tofte & Talpin 1997 (regions); Rust Reference, Ownership.
// ============================================================================

module theory_linearity;

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

const usz LIN_MAX_LOCALS = 8192;   // multiplicity census
const usz LIN_MAX_RES    = 256;    // resources per function
const usz LIN_MAX_BIND   = 512;    // binder → resource entries per function
const usz LIN_MAX_DEFER  = 64;
const int LIN_MAX_DEPTH  = 200;

// ── Multiplicity census (kept from the original pass) ───────────────────────
struct UseCount
{
    Node* binder;
    uint  name_id;
    int   uses;
}

// ── Resource states ─────────────────────────────────────────────────────────
enum RState : char
{
    R_LIVE,          // owned here, must be freed
    R_FREED,         // released on every path that reaches here
    R_MAYBE_FREED,   // released on some paths
    R_ESCAPED,       // ownership left this function (returned/stored/passed)
    R_DEAD           // scope ended (already reported if it leaked)
}

struct Resource
{
    Node*  origin;        // the `alloc` (or the parameter binder)
    Node*  first_binder;  // name it was first bound to (for messages)
    bool   is_param;      // unknown provenance: never a leak
    bool   declared_here; // created in the function being analysed
    RState state;
    Node*  freed_at;      // the `free` (or defer) that released it
    Node*  branch;        // for MAYBE: the `if`/`match`/`while` that split
    bool   branch_then;   // freed on the then-side?
    bool   deferred;      // a `defer free` in scope will release it
    Node*  defer_at;
    Node*  escaped_at;
}

struct Binding
{
    Node* binder;         // pat-ident / param binder node
    int   res;            // resource index, -1 = not a resource
}

// A snapshot of resource states for path joins.
struct StateSnap
{
    RState[LIN_MAX_RES] st;
    Node*[LIN_MAX_RES]  freed_at;
    bool[LIN_MAX_RES]   deferred;
    usz n;
}

struct LinAnalysis
{
    Arena*    arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;

    // census
    UseCount* counts;
    usz       n_counts;
    usz       n_unused;
    usz       n_once;
    usz       n_multi;
    usz       n_affine;

    // ownership, per function
    Resource* res;
    usz       n_res;
    Binding*  binds;
    usz       n_binds;
    Node**    defers;          // pending `defer` bodies, innermost last
    usz       n_defers;
    Node*     cur_fn;
    bool      path_dead;       // after return/break/continue in this block
    bool      second_pass;     // re-analysing a loop body: only loop-carried double frees are reported

    // totals
    usz       n_fns;
    usz       n_allocs;
    usz       n_frees;
    usz       n_aliases;
    usz       n_escapes;
    usz       n_double_free;
    usz       n_uaf;
    usz       n_leaks;
    usz       n_maybe;
    usz       n_overwrite;
    usz       n_defer_frees;
}

fn void LinAnalysis.attach(LinAnalysis* s, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    s.diags = d; s.interner = it; s.file = file;
}

fn char* LinAnalysis.name(LinAnalysis* s, uint id)
{
    if (s.interner == null || id == 0) { return "_"; }
    return s.interner.text(id);
}

fn char* LinAnalysis.msgbuf(LinAnalysis* s)
{
    char* m = (char*)s.arena.alloc(320, 1);
    if (m != null) { m[0] = 0; }
    return m;
}

// ── Diagnostics ─────────────────────────────────────────────────────────────
fn void LinAnalysis.warn(LinAnalysis* s, int code, Node* at, char* msg)
{
    if (s.diags == null || at == null) { return; }
    if (s.second_pass && code != 4160) { return; }
    s.diags.warn(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, s.file);
}
fn void LinAnalysis.note(LinAnalysis* s, int code, Node* at, char* msg)
{
    if (s.diags == null || at == null) { return; }
    s.diags.note(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, s.file);
}

fn char* LinAnalysis.res_name(LinAnalysis* s, Resource* r)
{
    if (r.first_binder != null) { return s.name(r.first_binder.name_id); }
    return "the block";
}

fn char* branch_kind(Node* b)
{
    if (b == null) { return "branch"; }
    if (b.kind == Nk.N_EXPR_IF) { return "if"; }
    if (b.kind == Nk.N_EXPR_MATCH) { return "match"; }
    if (b.kind == Nk.N_EXPR_WHILE) { return "while"; }
    return "branch";
}

fn void LinAnalysis.report_double_free(LinAnalysis* s, Resource* r, Node* at)
{
    char* m = s.msgbuf(); if (m == null) { return; }
    if (s.second_pass && r.state != RState.R_MAYBE_FREED) { return; }
    if (r.state == RState.R_FREED)
    {
        if (r.freed_at != null && r.freed_at.kind == Nk.N_STMT_DEFER)
        {
            snprintf(m, 320, "`%s` is freed here but the `defer` at %d:%d already frees it at scope exit: double free",
                     s.res_name(r), r.freed_at.line, r.freed_at.col);
        }
        else if (r.freed_at != null)
        {
            snprintf(m, 320, "`%s` is freed here but was already freed at %d:%d: double free",
                     s.res_name(r), r.freed_at.line, r.freed_at.col);
        }
        else
        {
            snprintf(m, 320, "`%s` is freed here but was already freed: double free", s.res_name(r));
        }
        s.warn(4160, at, m);
        s.n_double_free = s.n_double_free + 1;
        return;
    }
    // MAYBE
    if (r.branch != null && r.branch.kind == Nk.N_EXPR_WHILE)
    {
        snprintf(m, 320, "`%s` may be freed twice: this `free` is inside the `while` at %d:%d and `%s` is allocated outside it, so the second iteration frees it again",
                 s.res_name(r), r.branch.line, r.branch.col, s.res_name(r));
    }
    else if (r.freed_at != null && r.branch != null)
    {
        snprintf(m, 320, "`%s` may be freed twice: it was freed at %d:%d when the `%s` at %d:%d takes its %s branch",
                 s.res_name(r), r.freed_at.line, r.freed_at.col, branch_kind(r.branch), r.branch.line, r.branch.col,
                 r.branch_then ? "then" : "else");
    }
    else
    {
        snprintf(m, 320, "`%s` may be freed twice: it is already freed on some path", s.res_name(r));
    }
    s.note(4163, at, m);
    s.n_maybe = s.n_maybe + 1;
}

fn void LinAnalysis.report_uaf(LinAnalysis* s, Resource* r, Node* at, Node* ident)
{
    if (s.second_pass) { return; }
    char* m = s.msgbuf(); if (m == null) { return; }
    char* nm = ident != null ? s.name(ident.name_id) : s.res_name(r);
    if (r.state == RState.R_FREED)
    {
        if (r.freed_at != null)
        {
            snprintf(m, 320, "`%s` is used here but was freed at %d:%d: use after free", nm, r.freed_at.line, r.freed_at.col);
        }
        else
        {
            snprintf(m, 320, "`%s` is used here but was already freed: use after free", nm);
        }
        s.warn(4161, at, m);
        s.n_uaf = s.n_uaf + 1;
        return;
    }
    if (r.freed_at != null && r.branch != null && r.branch.kind != Nk.N_EXPR_WHILE)
    {
        snprintf(m, 320, "`%s` may be used after free: it was freed at %d:%d when the `%s` at %d:%d takes its %s branch",
                 nm, r.freed_at.line, r.freed_at.col, branch_kind(r.branch), r.branch.line, r.branch.col,
                 r.branch_then ? "then" : "else");
    }
    else if (r.freed_at != null)
    {
        snprintf(m, 320, "`%s` may be used after free: it is freed at %d:%d on some path reaching here", nm, r.freed_at.line, r.freed_at.col);
    }
    else
    {
        snprintf(m, 320, "`%s` may be used after free", nm);
    }
    s.note(4164, at, m);
    s.n_maybe = s.n_maybe + 1;
}

fn void LinAnalysis.report_leak(LinAnalysis* s, Resource* r, Node* at, char* how)
{
    if (r.is_param || !r.declared_here || r.origin == null || s.second_pass) { return; }
    char* m = s.msgbuf(); if (m == null) { return; }
    if (r.state == RState.R_LIVE)
    {
        snprintf(m, 320, "`%s` allocated at %d:%d is never freed%s: leak",
                 s.res_name(r), r.origin.line, r.origin.col, how);
        s.warn(4162, at, m);
        s.n_leaks = s.n_leaks + 1;
        return;
    }
    // MAYBE
    if (r.branch != null && r.branch.kind == Nk.N_EXPR_WHILE)
    {
        snprintf(m, 320, "`%s` allocated at %d:%d may leak: it is only freed inside the `while` at %d:%d, which may run zero times",
                 s.res_name(r), r.origin.line, r.origin.col, r.branch.line, r.branch.col);
    }
    else if (r.branch != null)
    {
        snprintf(m, 320, "`%s` allocated at %d:%d may leak: it is freed only when the `%s` at %d:%d takes its %s branch",
                 s.res_name(r), r.origin.line, r.origin.col, branch_kind(r.branch), r.branch.line, r.branch.col,
                 r.branch_then ? "then" : "else");
    }
    else
    {
        snprintf(m, 320, "`%s` allocated at %d:%d may leak: it is freed on some paths only", s.res_name(r), r.origin.line, r.origin.col);
    }
    s.note(4165, at, m);
    s.n_maybe = s.n_maybe + 1;
}

// ── Census ──────────────────────────────────────────────────────────────────
fn void LinAnalysis.census_declare(LinAnalysis* s, Node* binder)
{
    if (binder == null || s.n_counts >= LIN_MAX_LOCALS) { return; }
    s.counts[s.n_counts].binder = binder;
    s.counts[s.n_counts].name_id = binder.name_id;
    s.counts[s.n_counts].uses = 0;
    s.n_counts = s.n_counts + 1;
}

fn void LinAnalysis.census_use(LinAnalysis* s, Node* binder)
{
    if (binder == null) { return; }
    for (usz i = s.n_counts; i > 0; i--)
    {
        if (s.counts[i - 1].binder == binder) { s.counts[i - 1].uses = s.counts[i - 1].uses + 1; return; }
    }
}

fn void LinAnalysis.census_finish(LinAnalysis* s)
{
    s.n_unused = 0; s.n_once = 0; s.n_multi = 0; s.n_affine = 0;
    for (usz i = 0; i < s.n_counts; i++)
    {
        int u = s.counts[i].uses;
        if (u == 0) { s.n_unused = s.n_unused + 1; }
        else if (u == 1) { s.n_once = s.n_once + 1; s.n_affine = s.n_affine + 1; }
        else { s.n_multi = s.n_multi + 1; }
    }
}

// ── Resources and bindings ──────────────────────────────────────────────────
fn int LinAnalysis.new_resource(LinAnalysis* s, Node* origin, Node* binder, bool is_param)
{
    if (s.n_res >= LIN_MAX_RES) { return -1; }
    Resource* r = &s.res[s.n_res];
    r.origin = origin; r.first_binder = binder; r.is_param = is_param;
    r.declared_here = true; r.state = RState.R_LIVE;
    r.freed_at = null; r.branch = null; r.branch_then = false;
    r.deferred = false; r.defer_at = null; r.escaped_at = null;
    s.n_res = s.n_res + 1;
    if (!is_param) { s.n_allocs = s.n_allocs + 1; }
    return (int)(s.n_res - 1);
}

fn void LinAnalysis.bind(LinAnalysis* s, Node* binder, int res)
{
    if (binder == null || s.n_binds >= LIN_MAX_BIND) { return; }
    // rebinding a mutable name: overwrite the latest entry for it
    for (usz i = s.n_binds; i > 0; i--)
    {
        if (s.binds[i - 1].binder == binder) { s.binds[i - 1].res = res; return; }
    }
    s.binds[s.n_binds].binder = binder;
    s.binds[s.n_binds].res = res;
    s.n_binds = s.n_binds + 1;
}

fn int LinAnalysis.res_of_binder(LinAnalysis* s, Node* binder)
{
    if (binder == null) { return -1; }
    for (usz i = s.n_binds; i > 0; i--)
    {
        if (s.binds[i - 1].binder == binder) { return s.binds[i - 1].res; }
    }
    return -1;
}

// The resource an expression denotes, if it is (a cast/paren of) an ident
// bound to one.
fn int LinAnalysis.res_of_expr(LinAnalysis* s, Node* e, int depth)
{
    if (e == null || depth > 8) { return -1; }
    if (e.kind == Nk.N_EXPR_IDENT) { return s.res_of_binder(e.resolved); }
    if (e.kind == Nk.N_EXPR_CAST && e.child_count >= 1) { return s.res_of_expr(e.children[0], depth + 1); }
    if (e.kind == Nk.N_EXPR_UNSAFE && e.child_count >= 1) { return s.res_of_expr(e.children[0], depth + 1); }
    if (e.kind == Nk.N_BLOCK && e.child_count >= 1) { return s.res_of_expr(e.children[e.child_count - 1], depth + 1); }
    return -1;
}

fn bool is_alloc_expr(Node* e, int depth)
{
    if (e == null || depth > 8) { return false; }
    if (e.kind == Nk.N_EXPR_ALLOC) { return true; }
    if (e.kind == Nk.N_EXPR_CAST && e.child_count >= 1) { return is_alloc_expr(e.children[0], depth + 1); }
    if (e.kind == Nk.N_EXPR_UNSAFE && e.child_count >= 1) { return is_alloc_expr(e.children[0], depth + 1); }
    return false;
}

fn Node* alloc_node(Node* e, int depth)
{
    if (e == null || depth > 8) { return null; }
    if (e.kind == Nk.N_EXPR_ALLOC) { return e; }
    if (e.child_count >= 1) { return alloc_node(e.children[0], depth + 1); }
    return null;
}

// ── State snapshots for joins ───────────────────────────────────────────────
fn void LinAnalysis.snap(LinAnalysis* s, StateSnap* out)
{
    out.n = s.n_res;
    for (usz i = 0; i < s.n_res; i++)
    {
        out.st[i] = s.res[i].state;
        out.freed_at[i] = s.res[i].freed_at;
        out.deferred[i] = s.res[i].deferred;
    }
}

fn void LinAnalysis.restore(LinAnalysis* s, StateSnap* in)
{
    for (usz i = 0; i < in.n && i < s.n_res; i++)
    {
        s.res[i].state = in.st[i];
        s.res[i].freed_at = in.freed_at[i];
        s.res[i].deferred = in.deferred[i];
    }
    // resources created inside the abandoned path stay as they are: they
    // were declared in a scope that has ended
}

// Join the current state (path A, `a_live` = it actually reaches the join)
// with a snapshot (path B). `branch` is the splitting node; `cur_is_then`
// tells which side the current state came from.
fn void LinAnalysis.join(LinAnalysis* s, StateSnap* other, bool cur_reaches, bool other_reaches, Node* branch, bool cur_is_then)
{
    if (!cur_reaches && !other_reaches) { return; }
    if (!cur_reaches) { s.restore(other); return; }
    if (!other_reaches) { return; }
    for (usz i = 0; i < other.n && i < s.n_res; i++)
    {
        Resource* r = &s.res[i];
        RState a = r.state;
        RState b = other.st[i];
        if (a == b) { continue; }
        // ESCAPED dominates: once ownership left on any path we cannot say
        // anything about it again
        if (a == RState.R_ESCAPED || b == RState.R_ESCAPED) { r.state = RState.R_ESCAPED; continue; }
        if (a == RState.R_DEAD || b == RState.R_DEAD) { r.state = RState.R_DEAD; continue; }
        // LIVE vs FREED (either way) → MAYBE, remembering who freed it
        bool a_freed = a == RState.R_FREED || a == RState.R_MAYBE_FREED;
        bool b_freed = b == RState.R_FREED || b == RState.R_MAYBE_FREED;
        if (a_freed && !b_freed)
        {
            r.state = RState.R_MAYBE_FREED;
            r.branch = branch; r.branch_then = cur_is_then;
        }
        else if (b_freed && !a_freed)
        {
            r.state = RState.R_MAYBE_FREED;
            r.freed_at = other.freed_at[i];
            r.branch = branch; r.branch_then = !cur_is_then;
        }
        else
        {
            // FREED vs MAYBE → MAYBE
            r.state = RState.R_MAYBE_FREED;
            if (r.freed_at == null) { r.freed_at = other.freed_at[i]; }
        }
        if (other.deferred[i]) { r.deferred = true; }
    }
}

// ── Actions ─────────────────────────────────────────────────────────────────
fn void LinAnalysis.do_free(LinAnalysis* s, Node* free_node, Node* operand, bool via_defer, Node* defer_node)
{
    s.n_frees = s.n_frees + 1;
    int ri = s.res_of_expr(operand, 0);
    if (ri < 0) { return; }
    Resource* r = &s.res[(usz)ri];
    if (r.state == RState.R_FREED || r.state == RState.R_MAYBE_FREED)
    {
        s.report_double_free(r, free_node);
    }
    else if (r.deferred && !via_defer)
    {
        // explicit free on top of a pending defer: the defer will fire later
        char* m = s.msgbuf();
        if (m != null && r.defer_at != null)
        {
            snprintf(m, 320, "`%s` is freed here and again by the `defer` at %d:%d at scope exit: double free",
                     s.res_name(r), r.defer_at.line, r.defer_at.col);
            s.warn(4160, free_node, m);
            s.n_double_free = s.n_double_free + 1;
        }
    }
    if (r.state == RState.R_ESCAPED)
    {
        // freeing something we no longer own: cannot judge; it becomes freed
        // for the purpose of later uses
    }
    r.state = RState.R_FREED;
    r.freed_at = via_defer ? defer_node : free_node;
    r.branch = null;
}

fn void LinAnalysis.do_escape(LinAnalysis* s, int ri, Node* at)
{
    if (ri < 0) { return; }
    Resource* r = &s.res[(usz)ri];
    if (r.state == RState.R_LIVE || r.state == RState.R_MAYBE_FREED)
    {
        if (r.state == RState.R_MAYBE_FREED) { s.report_uaf(r, at, at.kind == Nk.N_EXPR_IDENT ? at : null); }
        r.state = RState.R_ESCAPED;
        r.escaped_at = at;
        s.n_escapes = s.n_escapes + 1;
    }
    else if (r.state == RState.R_FREED)
    {
        s.report_uaf(r, at, at.kind == Nk.N_EXPR_IDENT ? at : null);
    }
}

// A read of an identifier bound to a resource.
fn void LinAnalysis.do_use(LinAnalysis* s, Node* ident)
{
    if (ident == null || ident.kind != Nk.N_EXPR_IDENT) { return; }
    s.census_use(ident.resolved);
    int ri = s.res_of_binder(ident.resolved);
    if (ri < 0) { return; }
    Resource* r = &s.res[(usz)ri];
    if (r.state == RState.R_FREED || r.state == RState.R_MAYBE_FREED)
    {
        s.report_uaf(r, ident, ident);
        // report once per resource: after a use-after-free, further uses
        // would only repeat the message
        r.state = RState.R_ESCAPED;
    }
}

// At the end of a scope / at a return: everything declared in this
// function that is still owned leaks.
fn void LinAnalysis.check_leaks(LinAnalysis* s, Node* at, char* how, usz res_from)
{
    for (usz i = res_from; i < s.n_res; i++)
    {
        Resource* r = &s.res[i];
        if (r.deferred) { continue; }
        if (r.state == RState.R_LIVE || r.state == RState.R_MAYBE_FREED)
        {
            s.report_leak(r, at, how);
        }
    }
}

// ── Expression walk ─────────────────────────────────────────────────────────
// `ctx` says how the value of the expression is consumed:
//   0 read (a use), 1 escapes (arg / stored / returned), 2 the operand of free
fn void LinAnalysis.eval(LinAnalysis* s, Node* e, int ctx, int depth)
{
    if (e == null || depth > LIN_MAX_DEPTH) { return; }
    switch (e.kind)
    {
        case N_EXPR_IDENT:
        {
            if (ctx == 1)
            {
                int ri = s.res_of_binder(e.resolved);
                s.census_use(e.resolved);
                if (ri >= 0) { s.do_escape(ri, e); }
                else { s.do_use(e); }
            }
            else { s.do_use(e); }
            return;
        }
        case N_EXPR_FREE:
        {
            Node* op = e.child_count >= 1 ? e.children[0] : null;
            // the operand is not a "use": it is the release
            if (op != null && op.kind == Nk.N_EXPR_IDENT) { s.census_use(op.resolved); }
            else { s.eval_operand_of_free(op, depth + 1); }
            s.do_free(e, op, false, null);
            return;
        }
        case N_EXPR_ALLOC:
            // a bare alloc whose value is dropped leaks immediately
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 0, depth + 1); }
            if (ctx == 0 && e.parent != null && (e.parent.kind == Nk.N_BLOCK || e.parent.kind == Nk.N_STMT_EXPR))
            {
                int ri = s.new_resource(e, null, false);
                if (ri >= 0)
                {
                    char* m = s.msgbuf();
                    if (m != null)
                    {
                        snprintf(m, 320, "the result of this `alloc` is discarded: the block can never be freed (leak)");
                        s.warn(4162, e, m);
                        s.n_leaks = s.n_leaks + 1;
                    }
                    s.res[(usz)ri].state = RState.R_DEAD;
                }
            }
            return;
        case N_EXPR_CALL:
        {
            // callee is a read; every argument escapes (the callee may keep or free it)
            if (e.child_count >= 1) { s.eval(e.children[0], 0, depth + 1); }
            for (usz i = 1; i < e.child_count; i++) { s.eval(e.children[i], 1, depth + 1); }
            return;
        }
        case N_EXPR_METHOD:
        {
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 1, depth + 1); }
            return;
        }
        case N_EXPR_CAST:
        case N_EXPR_UNSAFE:
        case N_EXPR_UNCHECKED:
        {
            // transparent: a cast of an owned pointer that escapes, escapes
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], ctx, depth + 1); }
            return;
        }
        case N_EXPR_REF:
        {
            // `&p` / `&mut p`: a borrow we cannot follow → escape
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 1, depth + 1); }
            return;
        }
        case N_EXPR_TUPLE:
        case N_EXPR_ARRAY:
        case N_EXPR_STRUCT_LIT:
        case N_EXPR_FIELD_INIT:
        {
            // stored into an aggregate: ownership moves into it
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 1, depth + 1); }
            return;
        }
        case N_EXPR_LAMBDA:
        {
            // captured resources escape; the body is analysed as reads only
            s.eval_captures(e, depth + 1);
            return;
        }
        case N_EXPR_INDEX:
        case N_EXPR_FIELD:
        case N_EXPR_DEREF:
        case N_EXPR_SLICE:
        {
            // reading through the pointer is a use of the base
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 0, depth + 1); }
            return;
        }
        case N_EXPR_IF:
            s.eval_if(e, ctx, depth + 1);
            return;
        case N_EXPR_MATCH:
            s.eval_match(e, ctx, depth + 1);
            return;
        case N_EXPR_WHILE:
        case N_EXPR_LOOP:
        case N_EXPR_FOR:
            s.eval_loop(e, depth + 1);
            return;
        case N_BLOCK:
            s.eval_block(e, ctx, depth + 1);
            return;
        case N_STMT_RETURN:
        {
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 1, depth + 1); }
            s.run_defers(e, depth + 1);
            s.check_leaks(e, " before this `return`", 0);
            s.path_dead = true;
            return;
        }
        case N_STMT_BREAK:
        case N_STMT_CONTINUE:
            s.path_dead = true;
            return;
        case N_STMT_DEFER:
        {
            // remember; `defer free p` marks p as released at scope exit
            Node* body = e.child_count >= 1 ? e.children[0] : null;
            if (s.n_defers < LIN_MAX_DEFER) { s.defers[s.n_defers] = e; s.n_defers = s.n_defers + 1; }
            Node* fr = body;
            if (fr != null && fr.kind == Nk.N_BLOCK && fr.child_count == 1) { fr = fr.children[0]; }
            if (fr != null && fr.kind == Nk.N_EXPR_FREE && fr.child_count >= 1)
            {
                int ri = s.res_of_expr(fr.children[0], 0);
                if (ri >= 0)
                {
                    Resource* r = &s.res[(usz)ri];
                    if (r.deferred && r.defer_at != null)
                    {
                        char* m = s.msgbuf();
                        if (m != null)
                        {
                            snprintf(m, 320, "`%s` is already released by the `defer` at %d:%d: this second `defer free` is a double free",
                                     s.res_name(r), r.defer_at.line, r.defer_at.col);
                            s.warn(4160, e, m);
                            s.n_double_free = s.n_double_free + 1;
                        }
                    }
                    else if (r.state == RState.R_FREED)
                    {
                        s.report_double_free(r, e);
                    }
                    r.deferred = true; r.defer_at = e;
                    s.n_defer_frees = s.n_defer_frees + 1;
                    if (fr.children[0].kind == Nk.N_EXPR_IDENT) { s.census_use(fr.children[0].resolved); }
                }
            }
            return;
        }
        case N_DECL_LET:
            s.eval_let(e, depth + 1);
            return;
        case N_STMT_ASSIGN:
        case N_EXPR_ASSIGN:
        case N_STMT_COMPOUND_ASSIGN:
            s.eval_assign(e, depth + 1);
            return;
        case N_STMT_EXPR:
            for (usz i = 0; i < e.child_count; i++) { s.eval(e.children[i], 0, depth + 1); }
            return;
        case N_DECL_FN:
            // nested fn: its own analysis
            s.run_fn(e, depth + 1);
            return;
        default:
            break;
    }
    for (usz i = 0; i < e.child_count; i++)
    {
        Node* c = e.children[i];
        if (c == null) { continue; }
        s.eval(c, pfront_core::is_expr(c.kind) ? 0 : ctx, depth + 1);
    }
}

fn void LinAnalysis.eval_operand_of_free(LinAnalysis* s, Node* op, int depth)
{
    // `free v.data`, `free arr[i]` … the base is read
    if (op == null) { return; }
    s.eval(op, 0, depth);
}

// Identifiers used inside a lambda that are bound outside it escape.
fn void LinAnalysis.eval_captures(LinAnalysis* s, Node* n, int depth)
{
    if (n == null || depth > LIN_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_IDENT)
    {
        int ri = s.res_of_binder(n.resolved);
        s.census_use(n.resolved);
        if (ri >= 0) { s.do_escape(ri, n); }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { s.eval_captures(n.children[i], depth + 1); }
}

fn void LinAnalysis.eval_let(LinAnalysis* s, Node* let, int depth)
{
    Node* pat = null; Node* init = null;
    for (usz i = 0; i < let.child_count; i++)
    {
        Node* c = let.children[i];
        if (c == null) { continue; }
        if (pat == null && pfront_core::is_pattern(c.kind)) { pat = c; }
        else if (pfront_core::is_expr(c.kind)) { init = c; }
    }
    if (pat != null && pat.kind == Nk.N_PAT_IDENT) { s.census_declare(pat); }
    else if (pat != null) { s.declare_pattern(pat, depth + 1); }
    if (init == null) { return; }
    if (pat != null && pat.kind == Nk.N_PAT_IDENT)
    {
        if (is_alloc_expr(init, 0))
        {
            Node* an = alloc_node(init, 0);
            // size expression is a read
            if (an != null) { for (usz i = 0; i < an.child_count; i++) { s.eval(an.children[i], 0, depth + 1); } }
            int ri = s.new_resource(an, pat, false);
            s.bind(pat, ri);
            return;
        }
        int src = s.res_of_expr(init, 0);
        if (src >= 0)
        {
            // alias: `let q = p`
            Node* id = init;
            while (id != null && id.kind != Nk.N_EXPR_IDENT && id.child_count >= 1) { id = id.children[0]; }
            if (id != null) { s.census_use(id.resolved); }
            Resource* r = &s.res[(usz)src];
            if (r.state == RState.R_FREED || r.state == RState.R_MAYBE_FREED) { s.report_uaf(r, init, id); }
            s.bind(pat, src);
            s.n_aliases = s.n_aliases + 1;
            return;
        }
        // the value of a block / if / match that ends in an alloc
        s.eval(init, 1, depth + 1);
        return;
    }
    // destructuring: the init escapes into the pattern's binders
    s.eval(init, 1, depth + 1);
}

fn void LinAnalysis.declare_pattern(LinAnalysis* s, Node* p, int depth)
{
    if (p == null || depth > 32) { return; }
    if (p.kind == Nk.N_PAT_IDENT) { s.census_declare(p); }
    for (usz i = 0; i < p.child_count; i++)
    {
        Node* c = p.children[i];
        if (c != null && pfront_core::is_pattern(c.kind)) { s.declare_pattern(c, depth + 1); }
    }
}

fn void LinAnalysis.eval_assign(LinAnalysis* s, Node* a, int depth)
{
    Node* lhs = a.child_count >= 1 ? a.children[0] : null;
    Node* rhs = a.child_count >= 2 ? a.children[1] : null;
    if (lhs == null) { return; }
    if (lhs.kind == Nk.N_EXPR_IDENT && a.kind != Nk.N_STMT_COMPOUND_ASSIGN)
    {
        // `p = <new owner>`: the old resource must not still be owned
        int old = s.res_of_binder(lhs.resolved);
        int fresh = -1;
        if (is_alloc_expr(rhs, 0))
        {
            Node* an = alloc_node(rhs, 0);
            if (an != null) { for (usz i = 0; i < an.child_count; i++) { s.eval(an.children[i], 0, depth + 1); } }
            fresh = s.new_resource(an, lhs.resolved, false);
        }
        else
        {
            int src = s.res_of_expr(rhs, 0);
            if (src >= 0)
            {
                Node* id = rhs;
                while (id != null && id.kind != Nk.N_EXPR_IDENT && id.child_count >= 1) { id = id.children[0]; }
                if (id != null) { s.census_use(id.resolved); }
                Resource* r = &s.res[(usz)src];
                if (r.state == RState.R_FREED || r.state == RState.R_MAYBE_FREED) { s.report_uaf(r, rhs, id); }
                fresh = src;
                s.n_aliases = s.n_aliases + 1;
            }
            else { s.eval(rhs, 1, depth + 1); }
        }
        if (old >= 0 && old != fresh)
        {
            Resource* r = &s.res[(usz)old];
            // is another live name still bound to the old resource?
            bool other_alias = false;
            for (usz i = 0; i < s.n_binds; i++)
            {
                if (s.binds[i].res == old && s.binds[i].binder != lhs.resolved) { other_alias = true; }
            }
            if (!other_alias && !r.deferred && !r.is_param && r.declared_here && r.origin != null
                && (r.state == RState.R_LIVE || r.state == RState.R_MAYBE_FREED))
            {
                char* m = s.msgbuf();
                if (m != null)
                {
                    snprintf(m, 320, "`%s` is reassigned here while it still owns the block allocated at %d:%d: that block can no longer be freed (leak)",
                             s.name(lhs.name_id), r.origin.line, r.origin.col);
                    s.warn(4166, a, m);
                    s.n_overwrite = s.n_overwrite + 1;
                }
                r.state = RState.R_DEAD;
            }
        }
        if (fresh >= 0 || old >= 0) { s.bind(lhs.resolved, fresh); }
        return;
    }
    // store through a pointer / into a field or element: rhs escapes, lhs base is read
    s.eval(lhs, 0, depth + 1);
    if (rhs != null) { s.eval(rhs, 1, depth + 1); }
}

fn void LinAnalysis.eval_block(LinAnalysis* s, Node* b, int ctx, int depth)
{
    usz res_mark = s.n_res;
    usz bind_mark = s.n_binds;
    usz defer_mark = s.n_defers;
    for (usz i = 0; i < b.child_count; i++)
    {
        Node* st = b.children[i];
        if (st == null) { continue; }
        if (s.path_dead) { break; }
        bool last = i + 1 == b.child_count;
        // the block's tail value is consumed the way the block is
        s.eval(st, last ? ctx : 0, depth + 1);
    }
    if (!s.path_dead)
    {
        // scope exit: pending defers fire, then anything declared here that
        // is still owned leaks
        s.run_defers_from(defer_mark, b, depth + 1);
        s.check_leaks_scope(b, res_mark, bind_mark);
    }
    s.n_defers = defer_mark;
    // names declared in this block go out of scope
    s.n_binds = bind_mark;
    for (usz i = res_mark; i < s.n_res; i++)
    {
        if (s.res[i].state == RState.R_LIVE || s.res[i].state == RState.R_MAYBE_FREED) { s.res[i].state = RState.R_DEAD; }
    }
}

// Leak check at the end of a block: only resources whose EVERY binding was
// declared inside the block (an alias bound outside keeps it reachable).
fn void LinAnalysis.check_leaks_scope(LinAnalysis* s, Node* b, usz res_mark, usz bind_mark)
{
    for (usz i = res_mark; i < s.n_res; i++)
    {
        Resource* r = &s.res[i];
        if (r.deferred) { continue; }
        if (r.state != RState.R_LIVE && r.state != RState.R_MAYBE_FREED) { continue; }
        bool outer_alias = false;
        for (usz k = 0; k < bind_mark; k++) { if (s.binds[k].res == (int)i) { outer_alias = true; } }
        if (outer_alias) { continue; }
        Node* at = b.child_count >= 1 && b.children[b.child_count - 1] != null ? b.children[b.child_count - 1] : b;
        s.report_leak(r, at, " before the end of its scope");
    }
}

fn void LinAnalysis.run_defers_from(LinAnalysis* s, usz from, Node* at, int depth)
{
    for (usz i = s.n_defers; i > from; i--)
    {
        Node* d = s.defers[i - 1];
        Node* body = d != null && d.child_count >= 1 ? d.children[0] : null;
        Node* fr = body;
        if (fr != null && fr.kind == Nk.N_BLOCK && fr.child_count == 1) { fr = fr.children[0]; }
        if (fr != null && fr.kind == Nk.N_EXPR_FREE && fr.child_count >= 1)
        {
            int ri = s.res_of_expr(fr.children[0], 0);
            if (ri >= 0)
            {
                Resource* r = &s.res[(usz)ri];
                r.deferred = false;
                if (r.state == RState.R_FREED || r.state == RState.R_MAYBE_FREED)
                {
                    // the explicit free already fired: reported at that free
                }
                r.state = RState.R_FREED;
                r.freed_at = d;
            }
        }
    }
}

fn void LinAnalysis.run_defers(LinAnalysis* s, Node* at, int depth) { s.run_defers_from(0, at, depth); }

// ── Control flow ────────────────────────────────────────────────────────────
fn void LinAnalysis.eval_if(LinAnalysis* s, Node* e, int ctx, int depth)
{
    Node* c = e.child_count >= 1 ? e.children[0] : null;
    s.eval(c, 0, depth);
    StateSnap* before = (StateSnap*)malloc(StateSnap::size);
    StateSnap* after_then = (StateSnap*)malloc(StateSnap::size);
    if (before == null || after_then == null) { return; }
    s.snap(before);
    bool dead0 = s.path_dead;

    if (e.child_count >= 2) { s.eval(e.children[1], ctx, depth); }
    bool then_reaches = !s.path_dead;
    s.snap(after_then);

    s.restore(before);
    s.path_dead = dead0;
    if (e.child_count >= 3) { s.eval(e.children[2], ctx, depth); }
    bool else_reaches = !s.path_dead;

    // current = else side
    s.join(after_then, else_reaches, then_reaches, e, false);
    s.path_dead = !(then_reaches || else_reaches);
    free((void*)before); free((void*)after_then);
}

fn void LinAnalysis.eval_match(LinAnalysis* s, Node* e, int ctx, int depth)
{
    Node* scrut = e.child_count >= 1 ? e.children[0] : null;
    s.eval(scrut, 0, depth);
    StateSnap* before = (StateSnap*)malloc(StateSnap::size);
    StateSnap* acc = (StateSnap*)malloc(StateSnap::size);
    if (before == null || acc == null) { return; }
    s.snap(before);
    bool dead0 = s.path_dead;
    bool have_acc = false;
    bool acc_reaches = false;
    for (usz i = 1; i < e.child_count; i++)
    {
        Node* arm = e.children[i];
        if (arm == null) { continue; }
        s.restore(before);
        s.path_dead = dead0;
        usz bind_mark = s.n_binds;
        for (usz j = 0; j < arm.child_count; j++)
        {
            Node* c = arm.children[j];
            if (c == null) { continue; }
            if (pfront_core::is_pattern(c.kind)) { s.declare_pattern(c, depth + 1); }
            else { s.eval(c, j + 1 == arm.child_count ? ctx : 0, depth + 1); }
        }
        s.n_binds = bind_mark;
        bool reaches = !s.path_dead;
        if (!have_acc)
        {
            s.snap(acc); acc_reaches = reaches; have_acc = true;
        }
        else
        {
            // join current arm into the accumulator, then re-snap
            s.join(acc, reaches, acc_reaches, e, false);
            acc_reaches = acc_reaches || reaches;
            s.snap(acc);
        }
    }
    if (have_acc) { s.restore(acc); s.path_dead = !acc_reaches; }
    free((void*)before); free((void*)acc);
}

fn void LinAnalysis.eval_loop(LinAnalysis* s, Node* e, int depth)
{
    Node* c = e.child_count >= 1 ? e.children[0] : null;
    bool is_while = e.kind == Nk.N_EXPR_WHILE;
    if (is_while) { s.eval(c, 0, depth); }
    StateSnap* before = (StateSnap*)malloc(StateSnap::size);
    StateSnap* after1 = (StateSnap*)malloc(StateSnap::size);
    if (before == null || after1 == null) { return; }
    s.snap(before);
    bool dead0 = s.path_dead;
    usz first_body = is_while ? 1 : 0;

    // iteration one
    for (usz i = first_body; i < e.child_count; i++) { s.eval(e.children[i], 0, depth); }
    bool body_reaches = !s.path_dead;
    s.snap(after1);

    // iteration two starts from the join of "ran once" and "ran zero times":
    // a free of an outer resource inside the body now sees MAYBE-FREED and
    // reports the second-iteration double free as a note
    s.join(before, body_reaches, true, e, true);
    s.path_dead = false;
    // second pass over the body: everything except loop-carried double
    // frees is muted (it was reported in pass one); resources allocated in
    // the body are re-created, so roll them back afterwards
    usz res_before2 = s.n_res; usz allocs_before2 = s.n_allocs; usz frees_before2 = s.n_frees;
    usz escapes_before2 = s.n_escapes; usz aliases_before2 = s.n_aliases;
    StateSnap* mid = (StateSnap*)malloc(StateSnap::size);
    if (mid != null) { s.snap(mid); }
    s.second_pass = true;
    for (usz i = first_body; i < e.child_count; i++) { s.eval(e.children[i], 0, depth); }
    s.second_pass = false;
    s.n_res = res_before2; s.n_allocs = allocs_before2; s.n_frees = frees_before2;
    s.n_escapes = escapes_before2; s.n_aliases = aliases_before2;

    // state after the loop: zero or more iterations
    if (mid != null) { s.restore(mid); }
    s.join(after1, true, body_reaches, e, false);
    // resources freed inside the body are MAYBE after the loop (zero iterations)
    for (usz i = 0; i < before.n && i < s.n_res; i++)
    {
        if (before.st[i] == RState.R_LIVE && (s.res[i].state == RState.R_FREED || s.res[i].state == RState.R_MAYBE_FREED))
        {
            s.res[i].state = RState.R_MAYBE_FREED;
            s.res[i].branch = e; s.res[i].branch_then = true;
        }
    }
    s.path_dead = dead0;
    free((void*)before); free((void*)after1);
    if (mid != null) { free((void*)mid); }
}

// ── Per-function driver ─────────────────────────────────────────────────────
fn void LinAnalysis.run_fn(LinAnalysis* s, Node* f, int depth)
{
    // save the enclosing function's state (nested fns)
    usz res_mark = s.n_res; usz bind_mark = s.n_binds; usz defer_mark = s.n_defers;
    Node* saved_fn = s.cur_fn; bool saved_dead = s.path_dead;
    s.cur_fn = f; s.path_dead = false;
    s.n_fns = s.n_fns + 1;

    for (usz i = 0; i < f.child_count; i++)
    {
        Node* c = f.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM)
        {
            for (usz j = 0; j < c.child_count; j++)
            {
                Node* p = c.children[j];
                if (p != null && p.kind == Nk.N_PAT_IDENT)
                {
                    s.census_declare(p);
                    int ri = s.new_resource(p, p, true);
                    s.bind(p, ri);
                }
            }
        }
        else if (c.kind == Nk.N_CLAUSE)
        {
            usz cb = s.n_binds; usz cr = s.n_res;
            for (usz j = 0; j < c.child_count; j++)
            {
                Node* cc = c.children[j];
                if (cc == null) { continue; }
                if (pfront_core::is_pattern(cc.kind)) { s.bind_clause_params(cc, depth + 1); }
                else
                {
                    s.path_dead = false;
                    s.eval(cc, 1, depth + 1);      // the clause body's value is returned
                    if (!s.path_dead)
                    {
                        s.run_defers_from(defer_mark, cc, depth + 1);
                        s.check_leaks(cc, " before the function returns", cr);
                    }
                }
            }
            s.n_binds = cb;
            for (usz k = cr; k < s.n_res; k++) { s.res[k].state = RState.R_DEAD; }
            s.n_defers = defer_mark;
        }
        else if (c.kind == Nk.N_BLOCK)
        {
            s.path_dead = false;
            s.eval(c, 1, depth + 1);
            if (!s.path_dead) { s.check_leaks(c, " before the function returns", res_mark); }
        }
    }
    s.n_res = res_mark; s.n_binds = bind_mark; s.n_defers = defer_mark;
    s.cur_fn = saved_fn; s.path_dead = saved_dead;
}

fn void LinAnalysis.bind_clause_params(LinAnalysis* s, Node* p, int depth)
{
    if (p == null || depth > 32) { return; }
    if (p.kind == Nk.N_PAT_IDENT)
    {
        s.census_declare(p);
        int ri = s.new_resource(p, p, true);
        s.bind(p, ri);
    }
    for (usz i = 0; i < p.child_count; i++)
    {
        Node* c = p.children[i];
        if (c != null && pfront_core::is_pattern(c.kind)) { s.bind_clause_params(c, depth + 1); }
    }
}

fn void LinAnalysis.walk_top(LinAnalysis* s, Node* n, int depth)
{
    if (n == null || depth > LIN_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN) { s.run_fn(n, depth + 1); return; }
    for (usz i = 0; i < n.child_count; i++) { s.walk_top(n.children[i], depth + 1); }
}

// ── Lifecycle ───────────────────────────────────────────────────────────────
fn void LinAnalysis.init(LinAnalysis* s, Arena* a)
{
    s.arena = a;
    s.diags = null; s.interner = null; s.file = "";
    s.counts = (UseCount*)calloc(LIN_MAX_LOCALS, UseCount::size);
    s.res = (Resource*)calloc(LIN_MAX_RES, Resource::size);
    s.binds = (Binding*)calloc(LIN_MAX_BIND, Binding::size);
    s.defers = (Node**)calloc(LIN_MAX_DEFER, 8);
    s.n_counts = 0; s.n_res = 0; s.n_binds = 0; s.n_defers = 0;
    s.cur_fn = null; s.path_dead = false; s.second_pass = false;
    s.n_unused = 0; s.n_once = 0; s.n_multi = 0; s.n_affine = 0;
    s.n_fns = 0; s.n_allocs = 0; s.n_frees = 0; s.n_aliases = 0; s.n_escapes = 0;
    s.n_double_free = 0; s.n_uaf = 0; s.n_leaks = 0; s.n_maybe = 0; s.n_overwrite = 0; s.n_defer_frees = 0;
}

fn void LinAnalysis.run(LinAnalysis* s, Node* root)
{
    if (s.counts == null) { return; }
    s.n_counts = 0; s.n_res = 0; s.n_binds = 0; s.n_defers = 0;
    s.walk_top(root, 0);
    s.census_finish();
}

fn void LinAnalysis.report(LinAnalysis* s)
{
    printf("  linearity        : %d locals: unused=%d once=%d multi=%d, affine-candidates=%d\n",
           (int)s.n_counts, (int)s.n_unused, (int)s.n_once, (int)s.n_multi, (int)s.n_affine);
    printf("  ownership        : %d fns, %d allocs, %d frees (%d via defer), %d aliases, %d escapes\n",
           (int)s.n_fns, (int)s.n_allocs, (int)s.n_frees, (int)s.n_defer_frees, (int)s.n_aliases, (int)s.n_escapes);
    printf("  ownership-bugs   : %d double free, %d use-after-free, %d leaks, %d overwritten-while-owned, %d path-dependent notes\n",
           (int)s.n_double_free, (int)s.n_uaf, (int)s.n_leaks, (int)s.n_overwrite, (int)s.n_maybe);
}

fn void LinAnalysis.destroy(LinAnalysis* s)
{
    if (s.counts != null) { free((void*)s.counts); s.counts = null; }
    if (s.res != null) { free((void*)s.res); s.res = null; }
    if (s.binds != null) { free((void*)s.binds); s.binds = null; }
    if (s.defers != null) { free((void*)s.defers); s.defers = null; }
}
