// ============================================================================
// theory_sct.c3 — Size-Change Termination (Lee / Jones / Ben-Amram, POPL 2001)
// ----------------------------------------------------------------------------
// A recursive function terminates if along every infinite call chain some
// well-founded measure decreases infinitely often. Size-change graphs (SCGs)
// record, per call site, how each callee parameter relates to the caller's
// parameters:  ">"  strictly smaller,  "≥"  no larger,  nothing otherwise.
// Compose the graphs to a closure; the program is size-change terminating
// iff every idempotent self-loop graph has a strict self-edge (theorem 4 of
// the paper — Ramsey lets us look at idempotent graphs only).
//
// What counts as "smaller" here — and this is where a naive version is wrong:
//
//   • a binder bound INSIDE a pattern that matched a parameter (`Cons(_, t)`
//     over `xs`) is a strict sub-term of that parameter: well-founded, always;
//   • an integer `n - k` (k ≥ 1) is NOT a well-founded descent by itself —
//     `fact(-1)` recurses forever. It counts as ">" only under a LOWER BOUND
//     on `n` from an enclosing guard (`if n <= 0 return …`, `while n > 0`,
//     `if n >= 1 … `); `n / k` (k ≥ 2) and `n >> k` need `n ≥ 1`;
//   • an identifier is a parameter only if it RESOLVES to that parameter's
//     binder — a local that shares the name is not (shadow-safe), and a
//     binder that is assigned anywhere in the function is never trusted.
//
// Verdicts, per recursive function (self- or mutual recursion):
//   W4150  every argument of a recursive call is the caller's own parameter,
//          unchanged, under no guard that could differ next time: the call
//          cannot terminate once reached
//   N4151  proved terminating (which parameters descend and why)
//   N4152  not proved terminating: the cycle through <call> has no argument
//          shown to decrease (with the reason: unbounded decrement, or none)
// ============================================================================

module theory_sct;

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

const usz MAXP        = 8;      // parameters tracked per function
const usz MAX_FNS     = 512;
const usz MAX_SCG     = 4096;
const usz MAX_ENV     = 256;    // binders mapped to parameters, per function
const usz MAX_FACTS   = 64;     // guard facts in scope
const usz MAX_SITES   = 2048;
const int MAX_DEPTH   = 200;

enum Ek : char { NONE, GEQ, GT }

// ── Size-change graph ───────────────────────────────────────────────────────
struct ScGraph
{
    char[MAXP * MAXP] e;     // e[src*MAXP + dst]
    int  src_fi;
    int  dst_fi;
    int  site;               // call site index for call graphs, -1 for composites
    int  via_site;           // for composites: first call on the path
}

fn Ek scg_get(ScGraph* g, usz i, usz j) { return (Ek)g.e[i * MAXP + j]; }
fn void scg_set(ScGraph* g, usz i, usz j, Ek k) { g.e[i * MAXP + j] = (char)k; }

fn bool scg_same(ScGraph* a, ScGraph* b)
{
    if (a.src_fi != b.src_fi || a.dst_fi != b.dst_fi) { return false; }
    for (usz i = 0; i < MAXP * MAXP; i++) { if (a.e[i] != b.e[i]) { return false; } }
    return true;
}

fn ScGraph scg_compose(ScGraph* g, ScGraph* h)
{
    ScGraph r;
    for (usz i = 0; i < MAXP * MAXP; i++) { r.e[i] = 0; }
    r.src_fi = g.src_fi; r.dst_fi = h.dst_fi; r.site = -1;
    r.via_site = g.site >= 0 ? g.site : g.via_site;
    for (usz x = 0; x < MAXP; x++)
    {
        for (usz z = 0; z < MAXP; z++)
        {
            Ek best = Ek.NONE;
            for (usz y = 0; y < MAXP; y++)
            {
                Ek e1 = scg_get(g, x, y);
                Ek e2 = scg_get(h, y, z);
                if (e1 == Ek.NONE || e2 == Ek.NONE) { continue; }
                Ek joined = (e1 == Ek.GT || e2 == Ek.GT) ? Ek.GT : Ek.GEQ;
                if ((int)joined > (int)best) { best = joined; }
            }
            scg_set(&r, x, z, best);
        }
    }
    return r;
}

fn bool scg_empty(ScGraph* g)
{
    for (usz i = 0; i < MAXP * MAXP; i++) { if (g.e[i] != 0) { return false; } }
    return true;
}

fn bool scg_idempotent(ScGraph* g)
{
    if (g.src_fi != g.dst_fi) { return false; }
    ScGraph g2 = scg_compose(g, g);
    return scg_same(&g2, g);
}

fn int scg_strict_self(ScGraph* g)
{
    for (usz p = 0; p < MAXP; p++) { if (scg_get(g, p, p) == Ek.GT) { return (int)p; } }
    return -1;
}

// ── State ───────────────────────────────────────────────────────────────────
struct FnInfo
{
    Node* decl;
    uint  name_id;
    usz   paramc;
    uint[MAXP] pnames;
    bool  is_rec;             // takes part in some cycle
    char  verdict;            // 0 none, 1 terminating, 2 not proved, 3 loops
    int   bad_site;           // call site witnessing the failure
    int   good_param;         // parameter that descends (verdict 1)
    char  bad_reason;         // 0 nothing decreases, 1 unbounded decrement, 2 rotates
}

struct EnvEntry { Node* binder; int param; bool strict; }
struct Fact     { Node* binder; char kind; long k; Node* other; }   // kind 0: binder >= k · 1: binder <= k · 2: binder < other

struct CallSite
{
    Node* call;
    int   src_fi;
    int   dst_fi;
    bool  all_unchanged;      // every arg is the same-position parameter itself
    bool  guarded;            // under some condition that is not purely on params
    bool  unbounded_dec;      // saw `p - k` without a lower bound
    bool  ascending;          // …or `p + k` without an upper bound
    uint  unbounded_name;
}

struct SctState
{
    Arena*    arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;

    FnInfo*   fns;
    usz       n_fns;
    ScGraph*  scgs;
    usz       n_scgs;
    usz       n_call_scgs;
    CallSite* sites;
    usz       n_sites;

    // per-function scratch
    int       cur_fi;
    EnvEntry* env;
    usz       n_env;
    Fact*     facts;
    usz       n_facts;
    usz       guard_depth;    // enclosing conditions that mention non-parameters
    Node**    assigned;       // binders assigned somewhere in the current fn
    usz       n_assigned;

    usz       n_recursive;
    usz       n_terminating;
    usz       n_nonterm;
    usz       n_unknown;
    usz       n_loops;
    usz       n_struct_edges;
    usz       n_int_edges;
    usz       n_unbounded;
}

fn void SctState.attach(SctState* s, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    s.diags = d; s.interner = it; s.file = file;
}

fn char* SctState.name(SctState* s, uint id)
{
    if (s.interner == null || id == 0) { return "_"; }
    return s.interner.text(id);
}

// ── Function table ──────────────────────────────────────────────────────────
fn int SctState.find_fn(SctState* s, Node* decl)
{
    if (decl == null) { return -1; }
    for (usz i = 0; i < s.n_fns; i++) { if (s.fns[i].decl == decl) { return (int)i; } }
    return -1;
}

fn void SctState.collect_fns(SctState* s, Node* n, int depth)
{
    if (n == null || depth > MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN && s.n_fns < MAX_FNS)
    {
        FnInfo* f = &s.fns[s.n_fns];
        f.decl = n; f.name_id = n.name_id; f.paramc = 0; f.is_rec = false;
        f.verdict = 0; f.bad_site = -1; f.good_param = -1; f.bad_reason = 0;
        s.n_fns = s.n_fns + 1;
    }
    for (usz i = 0; i < n.child_count; i++) { s.collect_fns(n.children[i], depth + 1); }
}

// ── Environment: binder → parameter ─────────────────────────────────────────
fn bool SctState.is_assigned(SctState* s, Node* b)
{
    for (usz i = 0; i < s.n_assigned; i++) { if (s.assigned[i] == b) { return true; } }
    return false;
}

fn void SctState.env_add(SctState* s, Node* binder, int param, bool strict)
{
    if (binder == null || param < 0 || s.n_env >= MAX_ENV) { return; }
    if (s.is_assigned(binder)) { return; }
    s.env[s.n_env].binder = binder;
    s.env[s.n_env].param = param;
    s.env[s.n_env].strict = strict;
    s.n_env = s.n_env + 1;
}

fn EnvEntry* SctState.env_find(SctState* s, Node* binder)
{
    if (binder == null) { return null; }
    for (usz i = s.n_env; i > 0; i--) { if (s.env[i - 1].binder == binder) { return &s.env[i - 1]; } }
    return null;
}

fn EnvEntry* SctState.param_of_ident(SctState* s, Node* e)
{
    if (e == null || e.kind != Nk.N_EXPR_IDENT) { return null; }
    return s.env_find(e.resolved);
}

// Bind the binders of a pattern that matched something at (param, strict).
// Binders nested under a constructor are strict sub-terms.
fn void SctState.bind_pattern(SctState* s, Node* p, int param, bool strict, int depth)
{
    if (p == null || param < 0 || depth > 32) { return; }
    switch (p.kind)
    {
        case N_PAT_IDENT:
            s.env_add(p, param, strict);
            // `x @ pat` style sub-pattern, if present, binds strictly below x
            for (usz i = 0; i < p.child_count; i++)
            {
                Node* c = p.children[i];
                if (c != null && pfront_core::is_pattern(c.kind)) { s.bind_pattern(c, param, true, depth + 1); }
            }
        case N_PAT_VARIANT:
        case N_PAT_TUPLE:
        case N_PAT_ARRAY:
        case N_PAT_STRUCT:
        case N_PAT_REF:
            for (usz i = 0; i < p.child_count; i++)
            {
                Node* c = p.children[i];
                if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
                s.bind_pattern(c, param, true, depth + 1);
            }
        case N_PAT_FIELD:
            for (usz i = 0; i < p.child_count; i++) { s.bind_pattern(p.children[i], param, true, depth + 1); }
        case N_PAT_OR:
            // binders must agree across alternatives; each is at most as strict
            for (usz i = 0; i < p.child_count; i++) { s.bind_pattern(p.children[i], param, strict, depth + 1); }
        default:
            break;
    }
}

// The formal parameters of a function: a clause's pattern components (tuple
// → one per element) or the `param` children of a brace-style fn.
fn void SctState.bind_params(SctState* s, Node* f, Node* clause)
{
    FnInfo* fi = &s.fns[(usz)s.cur_fi];
    usz idx = 0;
    if (clause != null)
    {
        Node* pat = null;
        for (usz i = 0; i < clause.child_count; i++)
        {
            Node* c = clause.children[i];
            if (c != null && pfront_core::is_pattern(c.kind)) { pat = c; break; }
        }
        if (pat == null) { return; }
        if (pat.kind == Nk.N_PAT_TUPLE)
        {
            for (usz i = 0; i < pat.child_count && idx < MAXP; i++)
            {
                Node* c = pat.children[i];
                if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
                if (c.kind == Nk.N_PAT_IDENT) { fi.pnames[idx] = c.name_id; }
                s.bind_pattern(c, (int)idx, false, 0);
                idx = idx + 1;
            }
        }
        else
        {
            if (pat.kind == Nk.N_PAT_IDENT) { fi.pnames[0] = pat.name_id; }
            s.bind_pattern(pat, 0, false, 0);
            idx = 1;
        }
    }
    else
    {
        for (usz i = 0; i < f.child_count && idx < MAXP; i++)
        {
            Node* c = f.children[i];
            if (c == null || c.kind != Nk.N_DECL_PARAM) { continue; }
            fi.pnames[idx] = c.name_id;
            for (usz j = 0; j < c.child_count; j++)
            {
                Node* p = c.children[j];
                if (p != null && pfront_core::is_pattern(p.kind)) { s.bind_pattern(p, (int)idx, false, 0); }
            }
            idx = idx + 1;
        }
    }
    if (idx > fi.paramc) { fi.paramc = idx; }
}

fn void SctState.scan_assigned(SctState* s, Node* n, int depth)
{
    if (n == null || depth > MAX_DEPTH) { return; }
    if ((n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
        && n.child_count >= 1 && n.children[0] != null)
    {
        Node* lhs = n.children[0];
        if (lhs.kind == Nk.N_EXPR_IDENT && lhs.resolved != null && s.n_assigned < MAX_ENV)
        {
            s.assigned[s.n_assigned] = lhs.resolved;
            s.n_assigned = s.n_assigned + 1;
        }
    }
    if (n.kind == Nk.N_EXPR_REF && n.child_count >= 1 && n.children[0] != null
        && n.children[0].kind == Nk.N_EXPR_IDENT && n.children[0].resolved != null && s.n_assigned < MAX_ENV)
    {
        // `&mut x` may be written through — don't trust x either
        s.assigned[s.n_assigned] = n.children[0].resolved;
        s.n_assigned = s.n_assigned + 1;
    }
    for (usz i = 0; i < n.child_count; i++) { s.scan_assigned(n.children[i], depth + 1); }
}

// ── Guard facts ─────────────────────────────────────────────────────────────
fn bool int_lit(Node* n, long* out)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_EXPR_INT) { *out = (long)n.p.ival; return true; }
    if (n.kind == Nk.N_EXPR_UNARY && n.p.op == (long)Tk.TOKEN_MINUS && n.child_count >= 1
        && n.children[0] != null && n.children[0].kind == Nk.N_EXPR_INT)
    {
        *out = -(long)n.children[0].p.ival; return true;
    }
    return false;
}

fn void SctState.fact_add(SctState* s, Node* binder, long lb)
{
    if (binder == null || s.n_facts >= MAX_FACTS) { return; }
    s.facts[s.n_facts].binder = binder; s.facts[s.n_facts].kind = 0;
    s.facts[s.n_facts].k = lb; s.facts[s.n_facts].other = null;
    s.n_facts = s.n_facts + 1;
}
fn void SctState.fact_add_ub(SctState* s, Node* binder, long ub)
{
    if (binder == null || s.n_facts >= MAX_FACTS) { return; }
    s.facts[s.n_facts].binder = binder; s.facts[s.n_facts].kind = 1;
    s.facts[s.n_facts].k = ub; s.facts[s.n_facts].other = null;
    s.n_facts = s.n_facts + 1;
}
fn void SctState.fact_add_ubv(SctState* s, Node* binder, Node* other)
{
    if (binder == null || other == null || s.n_facts >= MAX_FACTS) { return; }
    s.facts[s.n_facts].binder = binder; s.facts[s.n_facts].kind = 2;
    s.facts[s.n_facts].k = 0; s.facts[s.n_facts].other = other;
    s.n_facts = s.n_facts + 1;
}

// Does the expression mention anything other than parameters and literals?
fn bool SctState.cond_pure_on_params(SctState* s, Node* c, int depth)
{
    if (c == null || depth > 32) { return true; }
    switch (c.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
            return true;
        case N_EXPR_IDENT:
            return s.param_of_ident(c) != null;
        case N_EXPR_BINARY:
        case N_EXPR_UNARY:
            for (usz i = 0; i < c.child_count; i++)
            {
                if (!s.cond_pure_on_params(c.children[i], depth + 1)) { return false; }
            }
            return true;
        default:
            return false;
    }
}

// Push the lower bounds implied by `cond == pol`.
fn void SctState.push_cond(SctState* s, Node* c, bool pol, int depth)
{
    if (c == null || depth > 32) { return; }
    if (c.kind == Nk.N_EXPR_UNARY && c.p.op == (long)Tk.TOKEN_BANG && c.child_count >= 1)
    {
        s.push_cond(c.children[0], !pol, depth + 1); return;
    }
    if (c.kind != Nk.N_EXPR_BINARY || c.child_count < 2) { return; }
    long op = c.p.op;
    if ((op == (long)Tk.TOKEN_AMPAMP && pol) || (op == (long)Tk.TOKEN_PIPEPIPE && !pol))
    {
        s.push_cond(c.children[0], pol, depth + 1);
        s.push_cond(c.children[1], pol, depth + 1);
        return;
    }
    Node* l = c.children[0];
    Node* r = c.children[1];
    long k;
    Node* v = null;
    bool flipped = false;      // literal on the left: k OP v
    if (l != null && r != null && l.kind == Nk.N_EXPR_IDENT && r.kind == Nk.N_EXPR_IDENT
        && l.resolved != null && r.resolved != null)
    {
        // a < b  /  b > a  (or the negation of >= / <=): a is bounded above by b
        long o = op;
        if (!pol)
        {
            if (o == (long)Tk.TOKEN_LT) { o = (long)Tk.TOKEN_GTEQ; }
            else if (o == (long)Tk.TOKEN_LTEQ) { o = (long)Tk.TOKEN_GT; }
            else if (o == (long)Tk.TOKEN_GT) { o = (long)Tk.TOKEN_LTEQ; }
            else if (o == (long)Tk.TOKEN_GTEQ) { o = (long)Tk.TOKEN_LT; }
            else { return; }
        }
        if (o == (long)Tk.TOKEN_LT || o == (long)Tk.TOKEN_LTEQ || o == (long)Tk.TOKEN_LEQ_UNI)
        {
            s.fact_add_ubv(l.resolved, r.resolved);
        }
        else if (o == (long)Tk.TOKEN_GT || o == (long)Tk.TOKEN_GTEQ || o == (long)Tk.TOKEN_GEQ_UNI)
        {
            s.fact_add_ubv(r.resolved, l.resolved);
        }
        return;
    }
    if (l != null && l.kind == Nk.N_EXPR_IDENT && int_lit(r, &k)) { v = l.resolved; }
    else if (r != null && r.kind == Nk.N_EXPR_IDENT && int_lit(l, &k)) { v = r.resolved; flipped = true; }
    if (v == null) { return; }
    // normalise to  v OP k
    if (flipped)
    {
        if (op == (long)Tk.TOKEN_LT) { op = (long)Tk.TOKEN_GT; }
        else if (op == (long)Tk.TOKEN_GT) { op = (long)Tk.TOKEN_LT; }
        else if (op == (long)Tk.TOKEN_LTEQ) { op = (long)Tk.TOKEN_GTEQ; }
        else if (op == (long)Tk.TOKEN_GTEQ) { op = (long)Tk.TOKEN_LTEQ; }
    }
    if (op == (long)Tk.TOKEN_LEQ_UNI) { op = (long)Tk.TOKEN_LTEQ; }
    if (op == (long)Tk.TOKEN_GEQ_UNI) { op = (long)Tk.TOKEN_GTEQ; }
    if (!pol)
    {
        if (op == (long)Tk.TOKEN_LT) { op = (long)Tk.TOKEN_GTEQ; }
        else if (op == (long)Tk.TOKEN_LTEQ) { op = (long)Tk.TOKEN_GT; }
        else if (op == (long)Tk.TOKEN_GT) { op = (long)Tk.TOKEN_LTEQ; }
        else if (op == (long)Tk.TOKEN_GTEQ) { op = (long)Tk.TOKEN_LT; }
        else if (op == (long)Tk.TOKEN_EQEQ) { return; }
        else { return; }
    }
    if (op == (long)Tk.TOKEN_GT) { s.fact_add(v, k + 1); }
    else if (op == (long)Tk.TOKEN_GTEQ) { s.fact_add(v, k); }
    else if (op == (long)Tk.TOKEN_LT) { s.fact_add_ub(v, k - 1); }
    else if (op == (long)Tk.TOKEN_LTEQ) { s.fact_add_ub(v, k); }
    else if (op == (long)Tk.TOKEN_EQEQ) { s.fact_add(v, k); s.fact_add_ub(v, k); }
}

// Is `binder` bounded above, either by a literal or by a binder that this
// very call passes on unchanged (so the measure `other - binder` shrinks)?
fn bool SctState.has_upper_bound(SctState* s, Node* binder, Node* call, int callee_fi)
{
    for (usz i = 0; i < s.n_facts; i++)
    {
        if (s.facts[i].binder != binder) { continue; }
        if (s.facts[i].kind == 1) { return true; }
        if (s.facts[i].kind == 2 && call != null && s.cur_fi == callee_fi)
        {
            EnvEntry* q = s.env_find(s.facts[i].other);
            if (q == null || q.strict) { continue; }
            usz pos = (usz)q.param + 1;
            if (pos < call.child_count && call.children[pos] != null
                && call.children[pos].kind == Nk.N_EXPR_IDENT
                && call.children[pos].resolved == s.facts[i].other) { return true; }
        }
    }
    return false;
}

fn bool SctState.has_lower_bound(SctState* s, Node* binder, long need)
{
    for (usz i = 0; i < s.n_facts; i++)
    {
        if (s.facts[i].binder == binder && s.facts[i].kind == 0 && s.facts[i].k >= need) { return true; }
    }
    return false;
}

// ── Call-site analysis ──────────────────────────────────────────────────────
// Classify one argument expression: which caller parameter it descends from
// and how. Returns the parameter index or -1.
fn int SctState.classify_arg(SctState* s, Node* a, Ek* how, CallSite* cs, Node* call, int callee_fi)
{
    *how = Ek.NONE;
    if (a == null) { return -1; }
    if (a.kind == Nk.N_EXPR_IDENT)
    {
        EnvEntry* e = s.param_of_ident(a);
        if (e == null) { return -1; }
        *how = e.strict ? Ek.GT : Ek.GEQ;
        if (e.strict) { s.n_struct_edges = s.n_struct_edges + 1; }
        return e.param;
    }
    if (a.kind == Nk.N_EXPR_BINARY && a.child_count >= 2)
    {
        Node* l = a.children[0];
        long k;
        EnvEntry* e = s.param_of_ident(l);
        if (e == null || !int_lit(a.children[1], &k)) { return -1; }
        long op = a.p.op;
        long need_lb = 0;
        bool dec = false;
        if (op == (long)Tk.TOKEN_PLUS && k >= 1)
        {
            // ascending counter: the measure is (bound - p), needs an upper bound
            if (s.has_upper_bound(l.resolved, call, callee_fi))
            {
                *how = Ek.GT;
                s.n_int_edges = s.n_int_edges + 1;
                return e.param;
            }
            cs.unbounded_dec = true;
            cs.unbounded_name = l.name_id;
            cs.ascending = true;
            s.n_unbounded = s.n_unbounded + 1;
            return -1;
        }
        if (op == (long)Tk.TOKEN_MINUS && k >= 1) { dec = true; need_lb = -0x7fffffffffffffff; }
        else if (op == (long)Tk.TOKEN_SLASH && k >= 2) { dec = true; need_lb = 1; }
        else if (op == (long)Tk.TOKEN_RSHIFT && k >= 1) { dec = true; need_lb = 1; }
        if (!dec) { return -1; }
        if (e.strict)
        {
            // already a strict sub-term; arithmetic on it stays below only if bounded
        }
        if (s.has_lower_bound(l.resolved, need_lb))
        {
            *how = Ek.GT;
            s.n_int_edges = s.n_int_edges + 1;
            return e.param;
        }
        cs.unbounded_dec = true;
        cs.unbounded_name = l.name_id;
        s.n_unbounded = s.n_unbounded + 1;
        return -1;
    }
    return -1;
}

fn void SctState.extract_call(SctState* s, Node* call, int callee_fi)
{
    if (s.cur_fi < 0 || s.n_sites >= MAX_SITES || s.n_scgs >= MAX_SCG) { return; }
    FnInfo* src = &s.fns[(usz)s.cur_fi];
    CallSite* cs = &s.sites[s.n_sites];
    cs.call = call; cs.src_fi = s.cur_fi; cs.dst_fi = callee_fi;
    cs.all_unchanged = true; cs.guarded = s.guard_depth > 0;
    cs.unbounded_dec = false; cs.unbounded_name = 0; cs.ascending = false;

    ScGraph g;
    for (usz i = 0; i < MAXP * MAXP; i++) { g.e[i] = 0; }
    g.src_fi = s.cur_fi; g.dst_fi = callee_fi; g.site = (int)s.n_sites; g.via_site = -1;

    usz nargs = call.child_count > 0 ? call.child_count - 1 : 0;
    if (nargs == 0 || src.paramc == 0) { cs.all_unchanged = false; }
    for (usz j = 0; j < nargs && j < MAXP; j++)
    {
        Node* a = call.children[j + 1];
        Ek how;
        int p = s.classify_arg(a, &how, cs, call, callee_fi);
        if (p >= 0 && how != Ek.NONE) { scg_set(&g, (usz)p, j, how); }
        bool same = (p == (int)j && how == Ek.GEQ && a != null && a.kind == Nk.N_EXPR_IDENT
                     && s.cur_fi == callee_fi);
        if (!same) { cs.all_unchanged = false; }
    }
    if (nargs != src.paramc) { cs.all_unchanged = false; }
    s.scgs[s.n_scgs] = g;
    s.n_scgs = s.n_scgs + 1;
    s.n_call_scgs = s.n_call_scgs + 1;
    s.n_sites = s.n_sites + 1;
}

// ── Walk ────────────────────────────────────────────────────────────────────
fn bool block_exits(Node* b, int depth)
{
    if (b == null || depth > 8) { return false; }
    if (b.kind == Nk.N_STMT_RETURN || b.kind == Nk.N_STMT_BREAK || b.kind == Nk.N_STMT_CONTINUE
        || b.kind == Nk.N_EXPR_UB || b.kind == Nk.N_EXPR_UNREACHABLE || b.kind == Nk.N_EXPR_TRAP) { return true; }
    if (b.kind == Nk.N_STMT_EXPR && b.child_count >= 1) { return block_exits(b.children[0], depth + 1); }
    if ((b.kind == Nk.N_BLOCK || b.kind == Nk.N_EXPR_UNSAFE) && b.child_count >= 1)
    {
        return block_exits(b.children[b.child_count - 1], depth + 1);
    }
    return false;
}

fn void SctState.walk(SctState* s, Node* n, int depth)
{
    if (n == null || depth > MAX_DEPTH) { return; }
    usz fact_mark = s.n_facts;
    usz env_mark = s.n_env;

    switch (n.kind)
    {
        case N_DECL_FN:
        {
            int fi = s.find_fn(n);
            if (fi < 0) { return; }
            int save_fi = s.cur_fi;
            usz save_env = s.n_env; usz save_facts = s.n_facts; usz save_assigned = s.n_assigned; usz save_guard = s.guard_depth;
            s.cur_fi = fi; s.n_env = 0; s.n_facts = 0; s.n_assigned = 0; s.guard_depth = 0;
            s.scan_assigned(n, 0);
            bool has_clause = false;
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c != null && c.kind == Nk.N_CLAUSE) { has_clause = true; }
            }
            if (!has_clause) { s.bind_params(n, null); }
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (c.kind == Nk.N_CLAUSE)
                {
                    usz em = s.n_env;
                    s.bind_params(n, c);
                    for (usz j = 0; j < c.child_count; j++)
                    {
                        Node* cc = c.children[j];
                        if (cc != null && !pfront_core::is_pattern(cc.kind)) { s.walk(cc, depth + 1); }
                    }
                    s.n_env = em;
                }
                else if (c.kind == Nk.N_BLOCK) { s.walk(c, depth + 1); }
                else if (c.kind != Nk.N_DECL_PARAM && !pfront_core::is_pattern(c.kind)) { s.walk(c, depth + 1); }
            }
            s.cur_fi = save_fi; s.n_env = save_env; s.n_facts = save_facts;
            s.n_assigned = save_assigned; s.guard_depth = save_guard;
            return;
        }
        case N_EXPR_LAMBDA:
            // a lambda's body is a different function for size-change purposes
            return;
        case N_BLOCK:
        {
            // `if c { return }` guards the rest of the block with ¬c
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* st = n.children[i];
                if (st == null) { continue; }
                s.walk(st, depth + 1);
                if (st.kind == Nk.N_EXPR_IF && st.child_count >= 2)
                {
                    bool then_exits = block_exits(st.children[1], 0);
                    bool else_exits = st.child_count >= 3 && block_exits(st.children[2], 0);
                    if (then_exits && !else_exits) { s.push_cond(st.children[0], false, 0); }
                    else if (else_exits && !then_exits) { s.push_cond(st.children[0], true, 0); }
                }
            }
            s.n_facts = fact_mark; s.n_env = env_mark;
            return;
        }
        case N_EXPR_IF:
        {
            Node* c = n.child_count >= 1 ? n.children[0] : null;
            s.walk(c, depth + 1);
            bool pure = s.cond_pure_on_params(c, 0);
            if (!pure) { s.guard_depth = s.guard_depth + 1; }
            if (n.child_count >= 2)
            {
                s.push_cond(c, true, 0);
                s.walk(n.children[1], depth + 1);
                s.n_facts = fact_mark;
            }
            if (n.child_count >= 3)
            {
                s.push_cond(c, false, 0);
                s.walk(n.children[2], depth + 1);
                s.n_facts = fact_mark;
            }
            if (!pure) { s.guard_depth = s.guard_depth - 1; }
            return;
        }
        case N_EXPR_WHILE:
        {
            Node* c = n.child_count >= 1 ? n.children[0] : null;
            s.walk(c, depth + 1);
            bool pure = s.cond_pure_on_params(c, 0);
            if (!pure) { s.guard_depth = s.guard_depth + 1; }
            s.push_cond(c, true, 0);
            for (usz i = 1; i < n.child_count; i++) { s.walk(n.children[i], depth + 1); }
            s.n_facts = fact_mark;
            if (!pure) { s.guard_depth = s.guard_depth - 1; }
            return;
        }
        case N_EXPR_MATCH:
        {
            Node* scrut = n.child_count >= 1 ? n.children[0] : null;
            s.walk(scrut, depth + 1);
            EnvEntry* se = s.param_of_ident(scrut);
            bool pure = se != null;
            if (!pure) { s.guard_depth = s.guard_depth + 1; }
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* arm = n.children[i];
                if (arm == null) { continue; }
                usz em = s.n_env; usz fm = s.n_facts;
                for (usz j = 0; j < arm.child_count; j++)
                {
                    Node* c = arm.children[j];
                    if (c == null) { continue; }
                    if (pfront_core::is_pattern(c.kind))
                    {
                        if (se != null)
                        {
                            // sub-binders are strictly below the scrutinee; a bare
                            // ident arm is the scrutinee itself
                            if (c.kind == Nk.N_PAT_IDENT) { s.env_add(c, se.param, se.strict); }
                            else { s.bind_pattern(c, se.param, true, 0); }
                            long k;
                            if (c.kind == Nk.N_PAT_LITERAL && c.child_count >= 1 && int_lit(c.children[c.child_count - 1], &k))
                            {
                                s.fact_add(scrut.resolved, k);
                            }
                        }
                    }
                    else { s.walk(c, depth + 1); }
                }
                s.n_env = em; s.n_facts = fm;
            }
            if (!pure) { s.guard_depth = s.guard_depth - 1; }
            return;
        }
        case N_DECL_LET:
        {
            // `let t2 = t` keeps the mapping; anything else is unknown
            Node* pat = null; Node* init = null;
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (pat == null && pfront_core::is_pattern(c.kind)) { pat = c; }
                else if (pfront_core::is_expr(c.kind)) { init = c; }
            }
            s.walk(init, depth + 1);
            EnvEntry* e = s.param_of_ident(init);
            if (e != null && pat != null)
            {
                if (pat.kind == Nk.N_PAT_IDENT) { s.env_add(pat, e.param, e.strict); }
                else { s.bind_pattern(pat, e.param, true, 0); }
            }
            return;
        }
        case N_EXPR_CALL:
        {
            Node* callee = n.child_count >= 1 ? n.children[0] : null;
            if (callee != null && callee.kind == Nk.N_EXPR_IDENT && callee.resolved != null
                && callee.resolved.kind == Nk.N_DECL_FN)
            {
                int fi = s.find_fn(callee.resolved);
                if (fi >= 0) { s.extract_call(n, fi); }
            }
            for (usz i = 1; i < n.child_count; i++) { s.walk(n.children[i], depth + 1); }
            return;
        }
        default:
            break;
    }
    for (usz i = 0; i < n.child_count; i++) { s.walk(n.children[i], depth + 1); }
    s.n_facts = fact_mark;
    if (n.kind != Nk.N_CLAUSE) { s.n_env = env_mark; }
}

// ── Closure + verdicts ──────────────────────────────────────────────────────
fn void SctState.add_scg(SctState* s, ScGraph g)
{
    for (usz i = 0; i < s.n_scgs; i++) { if (scg_same(&s.scgs[i], &g)) { return; } }
    if (s.n_scgs >= MAX_SCG) { return; }
    s.scgs[s.n_scgs] = g;
    s.n_scgs = s.n_scgs + 1;
}

fn void SctState.closure(SctState* s)
{
    // only compose along actual call graph edges; the empty graph on a cycle
    // still matters (it is the "nothing descends" witness), so keep it
    usz rounds = 0;
    while (rounds < 64)
    {
        usz before = s.n_scgs;
        usz calls = s.n_call_scgs;
        for (usz i = 0; i < before; i++)
        {
            for (usz j = 0; j < calls; j++)
            {
                if (s.scgs[i].dst_fi != s.scgs[j].src_fi) { continue; }
                ScGraph c = scg_compose(&s.scgs[i], &s.scgs[j]);
                s.add_scg(c);
            }
        }
        if (s.n_scgs == before) { break; }
        rounds = rounds + 1;
    }
}

fn void SctState.classify(SctState* s)
{
    for (usz i = 0; i < s.n_scgs; i++)
    {
        ScGraph* g = &s.scgs[i];
        if (g.src_fi != g.dst_fi) { continue; }
        FnInfo* f = &s.fns[(usz)g.src_fi];
        f.is_rec = true;
        if (!scg_idempotent(g)) { continue; }
        int sp = scg_strict_self(g);
        if (sp >= 0)
        {
            if (f.verdict == 0) { f.verdict = 1; f.good_param = sp; }
        }
        else
        {
            f.verdict = 2;
            int site = g.site >= 0 ? g.site : g.via_site;
            if (f.bad_site < 0 && site >= 0) { f.bad_site = site; }
            // is the pair merely rotating? (some ≥ edge off the diagonal, nothing strict)
            bool any_edge = false;
            for (usz a = 0; a < MAXP * MAXP; a++) { if (g.e[a] != 0) { any_edge = true; } }
            if (any_edge) { f.bad_reason = 2; }
        }
    }
    // a direct self-call with every argument unchanged, not under a guard that
    // could differ next time: a proved loop
    for (usz i = 0; i < s.n_sites; i++)
    {
        CallSite* cs = &s.sites[i];
        if (cs.src_fi == cs.dst_fi && cs.all_unchanged && !cs.guarded)
        {
            FnInfo* f = &s.fns[(usz)cs.src_fi];
            f.verdict = 3; f.bad_site = (int)i;
        }
    }
    for (usz i = 0; i < s.n_sites; i++)
    {
        CallSite* cs = &s.sites[i];
        FnInfo* f = &s.fns[(usz)cs.src_fi];
        if (f.verdict == 2 && cs.unbounded_dec && f.bad_reason == 0)
        {
            f.bad_reason = 1; f.bad_site = (int)i;
        }
    }
    for (usz i = 0; i < s.n_fns; i++)
    {
        FnInfo* f = &s.fns[i];
        if (!f.is_rec) { continue; }
        s.n_recursive = s.n_recursive + 1;
        if (f.verdict == 1) { s.n_terminating = s.n_terminating + 1; }
        else if (f.verdict == 2) { s.n_nonterm = s.n_nonterm + 1; }
        else if (f.verdict == 3) { s.n_loops = s.n_loops + 1; }
        else { s.n_unknown = s.n_unknown + 1; }
    }
}

fn void SctState.emit(SctState* s)
{
    if (s.diags == null) { return; }
    for (usz i = 0; i < s.n_fns; i++)
    {
        FnInfo* f = &s.fns[i];
        if (!f.is_rec || f.decl == null) { continue; }
        char* fname = s.name(f.name_id);
        char* msg = (char*)s.arena.alloc(512, 1);
        if (msg == null) { return; }
        if (f.verdict == 3 && f.bad_site >= 0)
        {
            Node* at = s.sites[(usz)f.bad_site].call;
            snprintf(msg, 512, "this call to `%s` passes every parameter unchanged and nothing guards it: once reached, the recursion never terminates", fname);
            s.diags.warn(pfront_core::Phase.PH_RESOLVE, 4150, at.line, at.col, msg, s.file);
        }
        else if (f.verdict == 1 && s.diags.advisories)
        {
            uint pid = f.good_param >= 0 && (usz)f.good_param < MAXP ? f.pnames[(usz)f.good_param] : 0;
            if (pid != 0)
            {
                snprintf(msg, 512, "recursion of `%s` terminates: every cycle strictly decreases a parameter (size-change; e.g. `%s`)", fname, s.name(pid));
            }
            else
            {
                snprintf(msg, 512, "recursion of `%s` terminates: every cycle strictly decreases a parameter (size-change; e.g. argument %d, by structural descent)", fname, f.good_param + 1);
            }
            s.diags.note(pfront_core::Phase.PH_RESOLVE, 4151, f.decl.line, f.decl.col, msg, s.file);
        }
        else if (f.verdict == 2)
        {
            Node* at = f.bad_site >= 0 ? s.sites[(usz)f.bad_site].call : f.decl;
            if (f.bad_reason == 1)
            {
                char* un = s.name(s.sites[(usz)f.bad_site].unbounded_name);
                if (s.sites[(usz)f.bad_site].ascending)
                {
                    snprintf(msg, 512, "recursion of `%s` is not proved terminating: `%s` increases here but nothing bounds it above", fname, un);
                }
                else
                {
                    snprintf(msg, 512, "recursion of `%s` is not proved terminating: `%s` decreases here but nothing bounds it below (guard it, e.g. `if %s <= 0 return …`)", fname, un, un);
                }
            }
            else if (f.bad_reason == 2)
            {
                snprintf(msg, 512, "recursion of `%s` is not proved terminating: the arguments on this cycle are rearranged but none strictly decreases", fname);
            }
            else
            {
                snprintf(msg, 512, "recursion of `%s` is not proved terminating: no argument of this call is shown to decrease", fname);
            }
            s.diags.note(pfront_core::Phase.PH_RESOLVE, 4152, at.line, at.col, msg, s.file);
        }
    }
}

// ── Lifecycle ───────────────────────────────────────────────────────────────
fn void SctState.init(SctState* s, Arena* a)
{
    s.arena = a;
    s.diags = null; s.interner = null; s.file = "";
    s.fns = (FnInfo*)calloc(MAX_FNS, FnInfo::size);
    s.scgs = (ScGraph*)calloc(MAX_SCG, ScGraph::size);
    s.sites = (CallSite*)calloc(MAX_SITES, CallSite::size);
    s.env = (EnvEntry*)calloc(MAX_ENV, EnvEntry::size);
    s.facts = (Fact*)calloc(MAX_FACTS, Fact::size);
    s.assigned = (Node**)calloc(MAX_ENV, (usz)8);
    s.n_fns = 0; s.n_scgs = 0; s.n_call_scgs = 0; s.n_sites = 0;
    s.n_env = 0; s.n_facts = 0; s.n_assigned = 0; s.guard_depth = 0;
    s.cur_fi = -1;
    s.n_recursive = 0; s.n_terminating = 0; s.n_nonterm = 0; s.n_unknown = 0; s.n_loops = 0;
    s.n_struct_edges = 0; s.n_int_edges = 0; s.n_unbounded = 0;
}

fn void SctState.run(SctState* s, Node* root)
{
    s.n_fns = 0; s.n_scgs = 0; s.n_call_scgs = 0; s.n_sites = 0; s.cur_fi = -1;
    s.collect_fns(root, 0);
    s.walk(root, 0);
    s.closure();
    s.classify();
    s.emit();
}

fn void SctState.report(SctState* s)
{
    printf("  size-change      : %d fns, %d recursive, %d call graphs, %d in closure (%d structural edges, %d bounded integer edges, %d unbounded decrements)\n",
        (int)s.n_fns, (int)s.n_recursive, (int)s.n_call_scgs, (int)s.n_scgs,
        (int)s.n_struct_edges, (int)s.n_int_edges, (int)s.n_unbounded);
    printf("  sct-verdicts     : %d terminating, %d not proved, %d proved loops, %d unknown\n",
        (int)s.n_terminating, (int)s.n_nonterm, (int)s.n_loops, (int)s.n_unknown);
}

fn void SctState.destroy(SctState* s)
{
    if (s.fns != null) { free((void*)s.fns); s.fns = null; }
    if (s.scgs != null) { free((void*)s.scgs); s.scgs = null; }
    if (s.sites != null) { free((void*)s.sites); s.sites = null; }
    if (s.env != null) { free((void*)s.env); s.env = null; }
    if (s.facts != null) { free((void*)s.facts); s.facts = null; }
    if (s.assigned != null) { free((void*)s.assigned); s.assigned = null; }
}
