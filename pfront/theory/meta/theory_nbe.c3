// ============================================================================
// theory_nbe.c3 — Normalisation by Evaluation over the Pride AST
// ----------------------------------------------------------------------------
// NbE (Berger/Schwichtenberg 1991) normalises a term by EVALUATING it into a
// semantic domain and READING BACK (reifying) the result as syntax. The
// domain here:
//
//     value ::= LIT  n                       integer / bool / char literal
//             | LAM  ⟨λ-node, env⟩           a closure: lambda + captured env
//             | NEU  e                       a neutral: syntax that cannot be
//                                            reduced further, already
//                                            normalised underneath
//
// `eval` turns syntax into values; `reify` turns values back into syntax.
// The normal form of `e` is `reify(eval(e, ρ))`. Because Pride is an
// imperative language with effects, the fragment that actually computes is
// the λ-calculus core — lambdas, application, let-bound function values,
// literals and arithmetic — and everything else is neutral: it is kept, its
// children are normalised, and its evaluation order is preserved.
//
// What it does, concretely:
//
//   β    (fn (x) { body })(a)            →  body[a/x]
//        let f = fn (x) { … }; f(a)      →  …[a/x]   (f immutable, not
//                                                     recursive, not &-taken)
//        higher-order chains reduce all the way: twice(inc)(3) → 5.
//   δ    literal arithmetic and comparison created by β (1 + 1 → 2), and
//        `if` on a literal condition selects its arm.
//   η    fn (x) { g(x) } → g   when g is a function-valued name ≠ x.
//   let  a let whose only value was a lambda that has been fully inlined
//        away is deleted.
//
// What keeps it SOUND (each of these was a way to miscompile):
//
//   * Substitution is by BINDER POINTER (the resolver's `resolved`), never
//     by name, and a lambda body is CLONED with fresh binders for every β
//     — two inlinings of the same lambda never share a `let` binder node.
//   * A substituted expression must not be captured. Before a β, every free
//     identifier of every value that will be placed at the call site is
//     checked against the call site's scope: if the innermost binder of
//     that name there is not the one the identifier resolves to, the β is
//     refused (a `let x` between the lambda's definition and its use would
//     capture the lambda's `x`).
//   * Effects and evaluation order. An argument is substituted for its
//     parameter only if it is a VALUE (literal, lambda, or an identifier
//     of an immutable binding). Anything else — calls, reads of `mut`
//     bindings, arithmetic on them — is bound by a fresh `let` in front of
//     the body: evaluated exactly once, in argument order, before the body.
//   * Only single-clause, simple-parameter lambdas with a block body are
//     reduced; multi-clause lambdas (pattern matching) are neutral.
//   * Fuel: 2048 β-steps per function, depth 96. Out of fuel means "leave
//     the application as it is", never a wrong term.
//
// The counters in the report are the numbers of rewrites actually made.
// ============================================================================

module theory_nbe;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const int  NBE_MAX_DEPTH  = 96;
const int  NBE_FUEL       = 2048;
const usz  NBE_SCOPE_CAP  = 2048;
const usz  NBE_MAP_CAP    = 512;
const usz  NBE_MAX_ARGS   = 16;

enum VKind : int { V_LIT, V_LAM, V_NEU }

struct NVal
{
    VKind kind;
    Node* node;      // LIT: literal node; LAM: the lambda node; NEU: the syntax
    NEnv* env;       // LAM: captured environment
    Node* origin;    // LAM: the `let` binder it came from (for fallback reify)
    bool  fresh;     // produced by substitution or reduction (not source syntax)
}

struct NEnv
{
    Node* binder;
    NVal* val;
    NEnv* next;
}

// Call-site scope: innermost binder per name, maintained by the walker.
struct ScopeEnt { uint name; Node* binder; }

// Binder map used while cloning a lambda body.
struct MapEnt { Node* from; Node* to; }

struct NbeState
{
    Arena* arena;
    ScopeEnt* scope;
    usz       scope_count;
    MapEnt*   map;
    usz       map_count;
    int       fuel;
    int       in_lambda;    // >0 while normalising under a residual lambda

    // Real counts.
    usz n_beta;
    usz n_delta;
    usz n_eta;
    usz n_if_folded;
    usz n_lets_dropped;
    usz n_lets_made;
    usz n_refused_capture;
    usz n_refused_fuel;
    usz n_fns;
    usz n_lambdas_seen;
    usz n_apps_seen;
}

fn void NbeState.init(NbeState* s, Arena* a)
{
    s.arena = a;
    s.scope = (ScopeEnt*)malloc(ScopeEnt::size * NBE_SCOPE_CAP);
    s.map = (MapEnt*)malloc(MapEnt::size * NBE_MAP_CAP);
    s.scope_count = 0;
    s.map_count = 0;
    s.fuel = 0;
    s.in_lambda = 0;
    s.n_beta = 0; s.n_delta = 0; s.n_eta = 0; s.n_if_folded = 0;
    s.n_lets_dropped = 0; s.n_lets_made = 0; s.n_refused_capture = 0; s.n_refused_fuel = 0;
    s.n_fns = 0; s.n_lambdas_seen = 0; s.n_apps_seen = 0;
}

fn void NbeState.destroy(NbeState* s)
{
    if (s.scope != null) { free((void*)s.scope); s.scope = null; }
    if (s.map != null) { free((void*)s.map); s.map = null; }
}

// Kept for pipeline compatibility: the old entry point.
fn void NbeState.run_demo(NbeState* s) { (void)s; }

// ── Values ──────────────────────────────────────────────────────────────────
fn NVal* NbeState.mk(NbeState* s, VKind k, Node* n, NEnv* env)
{
    NVal* v = (NVal*)s.arena.alloc(NVal::size, 8);
    if (v == null) { return null; }
    v.kind = k; v.node = n; v.env = env; v.origin = null; v.fresh = false;
    return v;
}

fn NEnv* NbeState.bind(NbeState* s, NEnv* env, Node* binder, NVal* v)
{
    NEnv* e = (NEnv*)s.arena.alloc(NEnv::size, 8);
    if (e == null) { return env; }
    e.binder = binder; e.val = v; e.next = env;
    return e;
}

fn NVal* env_lookup(NEnv* env, Node* binder)
{
    if (binder == null) { return null; }
    for (NEnv* e = env; e != null; e = e.next) { if (e.binder == binder) { return e.val; } }
    return null;
}

fn bool is_lit(Node* n)
{
    return n != null && (n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_BOOL || n.kind == Nk.N_EXPR_CHAR);
}

// ── Scope tracking ──────────────────────────────────────────────────────────
fn usz NbeState.scope_mark(NbeState* s) { return s.scope_count; }
fn void NbeState.scope_reset(NbeState* s, usz m) { if (m <= s.scope_count) { s.scope_count = m; } }

fn void NbeState.scope_add(NbeState* s, Node* binder)
{
    if (binder == null || s.scope == null || s.scope_count >= NBE_SCOPE_CAP) { return; }
    s.scope[s.scope_count].name = binder.name_id;
    s.scope[s.scope_count].binder = binder;
    s.scope_count = s.scope_count + 1;
}

fn Node* NbeState.scope_innermost(NbeState* s, uint name)
{
    for (usz i = s.scope_count; i > 0; i--) { if (s.scope[i - 1].name == name) { return s.scope[i - 1].binder; } }
    return null;
}

// Register the binders a pattern introduces.
fn void NbeState.scope_pattern(NbeState* s, Node* pat, int depth)
{
    if (pat == null || depth > NBE_MAX_DEPTH) { return; }
    if (pat.kind == Nk.N_PAT_IDENT) { s.scope_add(pat); return; }
    if (pat.kind == Nk.N_DECL_PARAM)
    {
        if (pat.child_count >= 1 && pat.children[0] != null && pat.children[0].kind == Nk.N_PAT_IDENT) { s.scope_add(pat.children[0]); }
        s.scope_add(pat);
        return;
    }
    for (usz i = 0; i < pat.child_count; i++) { s.scope_pattern(pat.children[i], depth + 1); }
}

// Is a binder node located inside `root`? (Used to tell bound from free.)
fn bool node_within(Node* n, Node* root, int depth)
{
    if (n == null || root == null || depth > NBE_MAX_DEPTH * 2) { return false; }
    if (n == root) { return true; }
    return node_within(n.parent, root, depth + 1);
}

// Would placing `e` at the current scope position capture any of its free
// identifiers? True when every free identifier still resolves to the
// innermost binder of its name here (or to something that is not a local).
fn bool NbeState.free_vars_ok(NbeState* s, Node* e, Node* root, int depth)
{
    if (e == null || depth > NBE_MAX_DEPTH) { return true; }
    if (e.kind == Nk.N_EXPR_IDENT && e.resolved != null)
    {
        Node* r = e.resolved;
        bool local_binder = r.kind == Nk.N_PAT_IDENT || r.kind == Nk.N_DECL_PARAM || r.kind == Nk.N_DECL_LET;
        if (local_binder && !node_within(r, root, 0))
        {
            Node* inner = s.scope_innermost(e.name_id);
            if (inner != null && inner != r) { return false; }
        }
        else if (!local_binder)
        {
            // A global (fn, const): shadowed here by a local of the same name?
            if (s.scope_innermost(e.name_id) != null) { return false; }
        }
    }
    for (usz i = 0; i < e.child_count; i++) { if (!s.free_vars_ok(e.children[i], root, depth + 1)) { return false; } }
    return true;
}

fn bool NbeState.value_ok_here(NbeState* s, NVal* v)
{
    if (v == null) { return false; }
    switch (v.kind)
    {
        case V_LIT: return true;
        case V_NEU: return s.free_vars_ok(v.node, v.node, 0);
        case V_LAM:
        {
            if (!s.free_vars_ok(v.node, v.node, 0)) { return false; }
            // The captured environment's values will be reified inside too.
            for (NEnv* e = v.env; e != null; e = e.next)
            {
                if (e.val != null && e.val != v && e.val.kind != VKind.V_LAM && !s.value_ok_here(e.val)) { return false; }
            }
            return true;
        }
    }
}

// ── Cloning ─────────────────────────────────────────────────────────────────
fn Node* NbeState.shallow(NbeState* s, Node* n)
{
    Node* c = s.arena.node(n.kind, n.line, n.col);
    if (c == null) { return null; }
    c.span_start = n.span_start; c.span_end = n.span_end;
    c.name_id = n.name_id;
    c.flags = n.flags | pfront_core::NF_SYNTHETIC;
    c.effects = n.effects;
    c.type_ann = n.type_ann; c.type_slot = n.type_slot; c.type_id = n.type_id;
    c.resolved = n.resolved; c.sym = n.sym; c.owner = n.owner;
    c.p = n.p;
    return c;
}

fn Node* NbeState.map_get(NbeState* s, Node* from)
{
    for (usz i = 0; i < s.map_count; i++) { if (s.map[i].from == from) { return s.map[i].to; } }
    return null;
}

// Deep copy with FRESH BINDERS: every pattern binder inside gets a new node
// and every identifier resolving to it is re-pointed.
fn Node* NbeState.clone(NbeState* s, Node* n, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) { return n; }
    Node* c = s.shallow(n);
    if (c == null) { return n; }
    if (n.kind == Nk.N_PAT_IDENT || n.kind == Nk.N_DECL_PARAM || n.kind == Nk.N_DECL_LET)
    {
        if (s.map != null && s.map_count < NBE_MAP_CAP)
        {
            s.map[s.map_count].from = n; s.map[s.map_count].to = c;
            s.map_count = s.map_count + 1;
        }
    }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null)
    {
        Node* to = s.map_get(n.resolved);
        if (to != null) { c.resolved = to; }
    }
    for (usz i = 0; i < n.child_count; i++) { s.arena.add_child(c, s.clone(n.children[i], depth + 1)); }
    // A forward reference inside the body (ident before its binder in walk
    // order) is fixed by a second pass over the copy.
    return c;
}

fn void NbeState.repoint(NbeState* s, Node* c, int depth)
{
    if (c == null || depth > NBE_MAX_DEPTH) { return; }
    if (c.kind == Nk.N_EXPR_IDENT && c.resolved != null)
    {
        Node* to = s.map_get(c.resolved);
        if (to != null) { c.resolved = to; }
    }
    for (usz i = 0; i < c.child_count; i++) { s.repoint(c.children[i], depth + 1); }
}

fn Node* NbeState.clone_fresh(NbeState* s, Node* n)
{
    s.map_count = 0;
    Node* c = s.clone(n, 0);
    s.repoint(c, 0);
    return c;
}

// ── Purity / shape predicates ───────────────────────────────────────────────
// A VALUE argument can be substituted freely: duplicating or dropping it
// changes nothing observable.
fn bool is_value_arg(NVal* v)
{
    if (v == null) { return false; }
    if (v.kind == VKind.V_LIT || v.kind == VKind.V_LAM) { return true; }
    Node* n = v.node;
    if (n == null || n.kind != Nk.N_EXPR_IDENT) { return false; }
    Node* r = n.resolved;
    if (r == null) { return true; }                          // a global name
    if ((r.flags & pfront_core::NF_MUT) != 0) { return false; }
    if ((r.flags & pfront_core::NF_ADDR_TAKEN) != 0) { return false; }
    return true;
}

fn bool lambda_simple(Node* lam, usz* nparams, Node** body)
{
    if (lam == null || lam.kind != Nk.N_EXPR_LAMBDA || lam.child_count < 1) { return false; }
    usz np = 0;
    for (usz i = 0; i + 1 < lam.child_count; i++)
    {
        Node* c = lam.children[i];
        if (c == null || c.kind != Nk.N_DECL_PARAM) { return false; }
        if (c.child_count < 1 || c.children[0] == null || c.children[0].kind != Nk.N_PAT_IDENT) { return false; }
        if ((c.flags & pfront_core::NF_VARIADIC) != 0) { return false; }
        np = np + 1;
    }
    Node* b = lam.children[lam.child_count - 1];
    if (b == null || b.kind == Nk.N_CLAUSE || b.kind == Nk.N_DECL_PARAM) { return false; }
    *nparams = np;
    *body = b;
    return true;
}

fn Node* param_binder(Node* prm)
{
    return (prm != null && prm.child_count >= 1) ? prm.children[0] : null;
}

// Does the lambda mention its own let-binder (a recursive definition)?
fn bool mentions(Node* n, Node* binder, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) { return false; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved == binder) { return true; }
    for (usz i = 0; i < n.child_count; i++) { if (mentions(n.children[i], binder, depth + 1)) { return true; } }
    return false;
}

fn usz count_uses(Node* n, Node* binder, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) { return 0; }
    usz c = (n.kind == Nk.N_EXPR_IDENT && n.resolved == binder) ? 1 : 0;
    for (usz i = 0; i < n.child_count; i++) { c = c + count_uses(n.children[i], binder, depth + 1); }
    return c;
}

// ── δ: literal arithmetic ───────────────────────────────────────────────────
fn Node* NbeState.mk_int(NbeState* s, long v, Node* at)
{
    Node* n = s.arena.node(Nk.N_EXPR_INT, at.line, at.col);
    if (n == null) { return null; }
    n.flags = pfront_core::NF_SYNTHETIC;
    n.p.ival = (ulong)v;
    n.p.width = at.p.width;
    n.p.is_signed = at.p.is_signed;
    n.type_id = at.type_id;
    return n;
}

fn Node* NbeState.mk_bool(NbeState* s, bool v, Node* at)
{
    Node* n = s.arena.node(Nk.N_EXPR_BOOL, at.line, at.col);
    if (n == null) { return null; }
    n.flags = pfront_core::NF_SYNTHETIC;
    n.p.ival = v ? 1 : 0;
    return n;
}

fn Node* NbeState.delta(NbeState* s, Node* op_node, Node* a, Node* b)
{
    if (!is_lit(a) || !is_lit(b)) { return null; }
    if (a.kind == Nk.N_EXPR_BOOL || b.kind == Nk.N_EXPR_BOOL)
    {
        if (a.kind != b.kind) { return null; }
        bool x = a.p.ival != 0; bool y = b.p.ival != 0;
        Tk op = (Tk)op_node.p.op;
        switch (op)
        {
            case TOKEN_AMPAMP: case TOKEN_KW_AND: return s.mk_bool(x && y, a);
            case TOKEN_PIPEPIPE: case TOKEN_KW_OR: return s.mk_bool(x || y, a);
            case TOKEN_EQEQ: return s.mk_bool(x == y, a);
            case TOKEN_NEQ: case TOKEN_NEQ_UNI: return s.mk_bool(x != y, a);
            default: return null;
        }
    }
    long x = (long)a.p.ival; long y = (long)b.p.ival;
    // Stay inside a conservative range so no width-dependent wrap is decided here.
    const long LIM = 1L << 31;
    if (x >= LIM || x <= -LIM || y >= LIM || y <= -LIM) { return null; }
    Tk op = (Tk)op_node.p.op;
    switch (op)
    {
        case TOKEN_PLUS:    return s.mk_int(x + y, a);
        case TOKEN_MINUS:   return s.mk_int(x - y, a);
        case TOKEN_STAR:    return s.mk_int(x * y, a);
        case TOKEN_SLASH:   if (y == 0) { return null; } return s.mk_int(x / y, a);
        case TOKEN_PERCENT: if (y == 0) { return null; } return s.mk_int(x % y, a);
        case TOKEN_EQEQ:    return s.mk_bool(x == y, a);
        case TOKEN_NEQ:     return s.mk_bool(x != y, a);
        case TOKEN_NEQ_UNI: return s.mk_bool(x != y, a);
        case TOKEN_LT:      return s.mk_bool(x < y, a);
        case TOKEN_LTEQ:    return s.mk_bool(x <= y, a);
        case TOKEN_GT:      return s.mk_bool(x > y, a);
        case TOKEN_GTEQ:    return s.mk_bool(x >= y, a);
        default: return null;
    }
}

// ── Reify ───────────────────────────────────────────────────────────────────
fn Node* NbeState.reify(NbeState* s, NVal* v, int depth)
{
    if (v == null) { return null; }
    switch (v.kind)
    {
        case V_LIT: return s.shallow(v.node);
        case V_NEU:
            // A neutral identifier taken from the environment may be placed
            // at several sites; give each its own node.
            if (v.node != null && v.node.kind == Nk.N_EXPR_IDENT) { return s.shallow(v.node); }
            return v.node;
        case V_LAM:
        {
            // A closure escaping into syntax: if it came from a `let` that is
            // still in scope here, name it; otherwise materialise it with its
            // environment substituted into a fresh copy.
            if (v.origin != null && s.scope_innermost(v.origin.name_id) == v.origin)
            {
                Node* id = s.arena.node(Nk.N_EXPR_IDENT, v.node.line, v.node.col);
                if (id != null)
                {
                    id.flags = pfront_core::NF_SYNTHETIC | pfront_core::NF_RESOLVED;
                    id.name_id = v.origin.name_id;
                    id.resolved = v.origin;
                    v.origin.flags = v.origin.flags | pfront_core::NF_USED;
                    return id;
                }
            }
            if (v.env == null) { return v.node; }
            Node* c = s.clone_fresh(v.node);
            s.in_lambda = s.in_lambda + 1;
            usz m = s.scope_mark();
            for (usz i = 0; i + 1 < c.child_count; i++) { s.scope_pattern(c.children[i], 0); }
            Node* body = c.children[c.child_count - 1];
            c.set_child(c.child_count - 1, s.norm(body, v.env, depth + 1));
            s.scope_reset(m);
            s.in_lambda = s.in_lambda - 1;
            return c;
        }
    }
}

// ── Eval ────────────────────────────────────────────────────────────────────
fn NVal* NbeState.neutral_children(NbeState* s, Node* n, NEnv* env, int depth)
{
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        n.set_child(i, s.norm(c, env, depth + 1));
    }
    return s.mk(VKind.V_NEU, n, null);
}

fn NVal* NbeState.eval(NbeState* s, Node* n, NEnv* env, int depth)
{
    if (n == null) { return null; }
    if (depth > NBE_MAX_DEPTH) { return s.mk(VKind.V_NEU, n, null); }
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
            return s.mk(VKind.V_LIT, n, null);

        case N_EXPR_IDENT:
        {
            NVal* v = env_lookup(env, n.resolved);
            if (v != null)
            {
                if (v.fresh) { return v; }
                NVal* f = s.mk(v.kind, v.node, v.env);
                if (f == null) { return v; }
                f.origin = v.origin; f.fresh = true;
                return f;
            }
            return s.mk(VKind.V_NEU, n, null);
        }

        case N_EXPR_LAMBDA:
        {
            s.n_lambdas_seen = s.n_lambdas_seen + 1;
            usz np; Node* body;
            if (lambda_simple(n, &np, &body))
            {
                // η: fn (x) { g(x) }  →  g
                Node* inner = body;
                if (inner.kind == Nk.N_BLOCK && inner.child_count == 1) { inner = inner.children[0]; }
                if (np == 1 && inner != null && inner.kind == Nk.N_EXPR_CALL && inner.child_count == 2)
                {
                    Node* g = inner.children[0];
                    Node* x = inner.children[1];
                    Node* pb = param_binder(n.children[0]);
                    if (g != null && x != null && g.kind == Nk.N_EXPR_IDENT && x.kind == Nk.N_EXPR_IDENT
                        && x.resolved == pb && g.resolved != pb && g.resolved != null
                        && (g.resolved.kind == Nk.N_DECL_FN || env_lookup(env, g.resolved) != null
                            || (g.resolved.kind == Nk.N_PAT_IDENT && (g.resolved.flags & pfront_core::NF_MUT) == 0)))
                    {
                        s.n_eta = s.n_eta + 1;
                        return s.eval(g, env, depth + 1);
                    }
                }
                return s.mk(VKind.V_LAM, n, env);
            }
            // Multi-clause lambda: neutral; normalise inside.
            return s.neutral_children(n, env, depth);
        }

        case N_EXPR_CALL:
        {
            s.n_apps_seen = s.n_apps_seen + 1;
            if (n.child_count < 1) { return s.mk(VKind.V_NEU, n, null); }
            NVal* f = s.eval(n.children[0], env, depth + 1);
            usz nargs = n.child_count - 1;
            NVal*[NBE_MAX_ARGS] args;
            if (nargs > NBE_MAX_ARGS) { return s.neutral_children(n, env, depth); }
            for (usz i = 0; i < nargs; i++) { args[i] = s.eval(n.children[i + 1], env, depth + 1); }

            if (f != null && f.kind == VKind.V_LAM)
            {
                NVal* r = s.beta(f, &args[0], nargs, n, depth);
                if (r != null) { return r; }
            }
            // Neutral application.
            n.set_child(0, s.reify(f, depth + 1));
            for (usz i = 0; i < nargs; i++) { n.set_child(i + 1, s.reify(args[i], depth + 1)); }
            return s.mk(VKind.V_NEU, n, null);
        }

        case N_EXPR_BINARY:
        {
            if (n.child_count != 2) { return s.neutral_children(n, env, depth); }
            NVal* a = s.eval(n.children[0], env, depth + 1);
            NVal* b = s.eval(n.children[1], env, depth + 1);
            // δ only on redexes that β CREATED: source-level `1 + 2` belongs
            // to constfold and the optimizer, whose counts must stay honest.
            if (a != null && b != null && a.kind == VKind.V_LIT && b.kind == VKind.V_LIT && (a.fresh || b.fresh))
            {
                Node* r = s.delta(n, a.node, b.node);
                if (r != null)
                {
                    s.n_delta = s.n_delta + 1;
                    NVal* rv = s.mk(VKind.V_LIT, r, null);
                    if (rv != null) { rv.fresh = true; }
                    return rv;
                }
            }
            n.set_child(0, s.reify(a, depth + 1));
            n.set_child(1, s.reify(b, depth + 1));
            return s.mk(VKind.V_NEU, n, null);
        }

        case N_EXPR_UNARY:
        {
            if (n.child_count != 1) { return s.neutral_children(n, env, depth); }
            NVal* a = s.eval(n.children[0], env, depth + 1);
            Tk op = (Tk)n.p.op;
            if (a != null && a.kind == VKind.V_LIT && a.fresh)
            {
                if ((op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT) && a.node.kind == Nk.N_EXPR_BOOL)
                {
                    s.n_delta = s.n_delta + 1;
                    NVal* rv = s.mk(VKind.V_LIT, s.mk_bool(a.node.p.ival == 0, a.node), null);
                    if (rv != null) { rv.fresh = true; }
                    return rv;
                }
                if (op == Tk.TOKEN_MINUS && a.node.kind == Nk.N_EXPR_INT && (long)a.node.p.ival < (1L << 31) && (long)a.node.p.ival > -(1L << 31))
                {
                    s.n_delta = s.n_delta + 1;
                    NVal* rv = s.mk(VKind.V_LIT, s.mk_int(-(long)a.node.p.ival, a.node), null);
                    if (rv != null) { rv.fresh = true; }
                    return rv;
                }
            }
            n.set_child(0, s.reify(a, depth + 1));
            return s.mk(VKind.V_NEU, n, null);
        }

        case N_EXPR_TUPLE:
            if (n.child_count == 1) { return s.eval(n.children[0], env, depth + 1); }
            return s.neutral_children(n, env, depth);

        case N_EXPR_IF:
        {
            if (n.child_count < 2) { return s.neutral_children(n, env, depth); }
            NVal* c = s.eval(n.children[0], env, depth + 1);
            if (c != null && c.kind == VKind.V_LIT && c.node.kind == Nk.N_EXPR_BOOL && c.fresh)
            {
                bool t = c.node.p.ival != 0;
                Node* arm = t ? n.children[1] : (n.child_count >= 3 ? n.children[2] : null);
                s.n_if_folded = s.n_if_folded + 1;
                if (arm == null)
                {
                    Node* u = s.arena.node(Nk.N_EXPR_UNIT, n.line, n.col);
                    return s.mk(VKind.V_NEU, u != null ? u : n, null);
                }
                return s.eval_block_value(arm, env, depth + 1);
            }
            n.set_child(0, s.reify(c, depth + 1));
            for (usz i = 1; i < n.child_count; i++) { n.set_child(i, s.norm(n.children[i], env, depth + 1)); }
            return s.mk(VKind.V_NEU, n, null);
        }

        case N_BLOCK:
            return s.eval_block_value(n, env, depth);

        case N_EXPR_QUOTE:
        case N_EXPR_COMPTIME:
            return s.mk(VKind.V_NEU, n, null);     // quoted code is data

        default:
            return s.neutral_children(n, env, depth);
    }
}

// A block in value position: a single expression evaluates through; a real
// statement sequence is normalised and stays a (neutral) block.
fn NVal* NbeState.eval_block_value(NbeState* s, Node* b, NEnv* env, int depth)
{
    if (b == null) { return null; }
    if (b.kind != Nk.N_BLOCK) { return s.eval(b, env, depth); }
    if (b.child_count == 1 && b.children[0] != null && pfront_core::is_expr(b.children[0].kind))
    {
        return s.eval(b.children[0], env, depth + 1);
    }
    return s.mk(VKind.V_NEU, s.norm_block(b, env, depth), null);
}

// ── β ───────────────────────────────────────────────────────────────────────
fn NVal* NbeState.beta(NbeState* s, NVal* f, NVal** args, usz nargs, Node* site, int depth)
{
    usz np; Node* body;
    if (!lambda_simple(f.node, &np, &body) || np != nargs) { return null; }
    if (s.fuel <= 0) { s.n_refused_fuel = s.n_refused_fuel + 1; return null; }
    // Capture check: everything that will be placed here must be free of
    // capture at this site — the arguments and the closure's own free names.
    if (!s.value_ok_here(f)) { s.n_refused_capture = s.n_refused_capture + 1; return null; }
    for (usz i = 0; i < nargs; i++)
    {
        if (args[i] == null) { return null; }
        if (!s.value_ok_here(args[i])) { s.n_refused_capture = s.n_refused_capture + 1; return null; }
    }
    s.fuel = s.fuel - 1;
    s.n_beta = s.n_beta + 1;

    // Fresh copy of the whole lambda so parameter binders are fresh too.
    Node* lam = s.clone_fresh(f.node);
    Node* cbody = lam.children[lam.child_count - 1];
    NEnv* env = f.env;

    // Non-value arguments become `let`s in front of the body, in order.
    Node* lets = null;
    for (usz i = 0; i < nargs; i++)
    {
        Node* pb = param_binder(lam.children[i]);
        NVal* a = args[i];
        if (is_value_arg(a))
        {
            env = s.bind(env, pb, a);
            continue;
        }
        Node* init = s.reify(a, depth + 1);
        bool pure = init != null && init.effects == 0 && !has_call_or_write(init, 0);
        if (pure && count_uses(cbody, pb, 0) == 0) { s.n_lets_dropped = s.n_lets_dropped + 1; continue; }
        if (lets == null) { lets = s.arena.node(Nk.N_BLOCK, site.line, site.col); if (lets == null) { return null; } lets.flags = pfront_core::NF_SYNTHETIC; }
        Node* let = s.arena.node(Nk.N_DECL_LET, site.line, site.col);
        if (let == null) { return null; }
        let.flags = pfront_core::NF_SYNTHETIC;
        let.name_id = pb.name_id;
        s.arena.add_child(let, pb);
        s.arena.add_child(let, init);
        s.arena.add_child(lets, let);
        s.n_lets_made = s.n_lets_made + 1;
    }

    usz m = s.scope_mark();
    if (lets != null)
    {
        for (usz i = 0; i < lets.child_count; i++) { s.scope_add(lets.children[i].children[0]); }
        // {{ lets…; body }} as one block.
        if (cbody.kind == Nk.N_BLOCK) { for (usz i = 0; i < cbody.child_count; i++) { s.arena.add_child(lets, s.norm(cbody.children[i], env, depth + 1)); } }
        else { s.arena.add_child(lets, s.norm(cbody, env, depth + 1)); }
        s.scope_reset(m);
        return s.mk(VKind.V_NEU, lets, null);
    }
    NVal* r = s.eval_block_value(cbody, env, depth + 1);
    s.scope_reset(m);
    return r;
}

fn bool has_call_or_write(Node* n, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) { return false; }
    switch (n.kind)
    {
        case N_EXPR_CALL: case N_EXPR_METHOD: case N_EXPR_ASSIGN: case N_STMT_ASSIGN:
        case N_STMT_COMPOUND_ASSIGN: case N_EXPR_UNSAFE: case N_EXPR_LAMBDA: case N_EXPR_WHILE:
        case N_EXPR_FOR: case N_EXPR_LOOP: case N_EXPR_ASSERT:
            return true;
        case N_EXPR_IDENT:
            if (n.resolved != null && (n.resolved.flags & pfront_core::NF_MUT) != 0) { return true; }
            return false;
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) { if (has_call_or_write(n.children[i], depth + 1)) { return true; } }
    return false;
}

// ── Statements ──────────────────────────────────────────────────────────────
// `norm` is the normal form of any node under `env`; for expressions it is
// reify∘eval, for statements it is structural with the environment threaded
// through `let`s.
fn Node* NbeState.norm(NbeState* s, Node* n, NEnv* env, int depth)
{
    if (n == null) { return null; }
    if (depth > NBE_MAX_DEPTH) { return n; }
    if (n.kind == Nk.N_BLOCK) { return s.norm_block(n, env, depth); }
    if (pfront_core::is_expr(n.kind)) { return s.reify(s.eval(n, env, depth + 1), depth + 1); }
    switch (n.kind)
    {
        case N_DECL_FN:
        case N_EXPR_QUOTE:
            return n;   // nested fns are normalised by their own run
        case N_DECL_LET:
        {
            if (n.child_count >= 2) { n.set_child(n.child_count - 1, s.norm(n.children[n.child_count - 1], env, depth + 1)); }
            if (n.child_count >= 1) { s.scope_pattern(n.children[0], 0); }
            return n;
        }
        case N_STMT_ASSIGN:
        case N_STMT_COMPOUND_ASSIGN:
        {
            // The target is a place: normalise only its sub-expressions.
            if (n.child_count >= 2) { n.set_child(1, s.norm(n.children[1], env, depth + 1)); }
            if (n.child_count >= 1 && n.children[0] != null && n.children[0].kind != Nk.N_EXPR_IDENT)
            {
                Node* lhs = n.children[0];
                for (usz i = 1; i < lhs.child_count; i++) { lhs.set_child(i, s.norm(lhs.children[i], env, depth + 1)); }
            }
            return n;
        }
        case N_CLAUSE:
        case N_MATCH_ARM:
        {
            usz m = s.scope_mark();
            if (n.child_count >= 1) { s.scope_pattern(n.children[0], 0); }
            for (usz i = 1; i < n.child_count; i++) { n.set_child(i, s.norm(n.children[i], env, depth + 1)); }
            s.scope_reset(m);
            return n;
        }
        default:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (pfront_core::is_pattern(c.kind)) { s.scope_pattern(c, 0); continue; }
                n.set_child(i, s.norm(c, env, depth + 1));
            }
            return n;
        }
    }
}

// A block: lets that bind a usable lambda extend the environment for the
// statements after them; the scope stack tracks every binder for the
// capture check.
fn Node* NbeState.norm_block(NbeState* s, Node* b, NEnv* env, int depth)
{
    usz m = s.scope_mark();
    for (usz i = 0; i < b.child_count; i++)
    {
        Node* st = b.children[i];
        if (st == null) { continue; }
        if (st.kind == Nk.N_DECL_LET && st.child_count >= 2 && st.children[0] != null
            && st.children[0].kind == Nk.N_PAT_IDENT)
        {
            Node* binder = st.children[0];
            Node* init = st.children[st.child_count - 1];
            NVal* v = s.eval(init, env, depth + 1);
            Node* rinit = s.reify(v, depth + 1);
            st.set_child(st.child_count - 1, rinit);
            s.scope_add(binder);
            bool immutable = (binder.flags & pfront_core::NF_MUT) == 0 && (st.flags & pfront_core::NF_MUT) == 0
                          && (binder.flags & pfront_core::NF_ADDR_TAKEN) == 0;
            if (immutable && v != null && v.kind == VKind.V_LAM && !mentions(v.node, binder, 0))
            {
                // Remember where it came from so an escaping use can be named.
                NVal* named = s.mk(VKind.V_LAM, v.node, v.env);
                if (named != null) { named.origin = binder; env = s.bind(env, binder, named); }
            }
            // Literal lets are deliberately NOT propagated here: constant
            // propagation belongs to constfold/SCCP, and the analyses that
            // run after NbE (symexe) want to see the binding, not the number.
            continue;
        }
        b.set_child(i, s.norm(st, env, depth + 1));
    }
    s.scope_reset(m);
    return b;
}

// Delete `let f = fn …` whose binder has no remaining uses after
// normalisation: the lambda is a value, dropping it is unobservable.
fn void NbeState.sweep(NbeState* s, Node* fnroot, Node* n, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_BLOCK)
    {
        usz w = 0;
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* st = n.children[i];
            bool drop = false;
            if (st != null && st.kind == Nk.N_DECL_LET && st.child_count >= 2 && st.children[0] != null
                && st.children[0].kind == Nk.N_PAT_IDENT && (st.children[0].flags & pfront_core::NF_MUT) == 0
                && st.children[st.child_count - 1] != null && st.children[st.child_count - 1].kind == Nk.N_EXPR_LAMBDA
                && (st.children[0].flags & pfront_core::NF_ADDR_TAKEN) == 0)
            {
                if (count_uses(fnroot, st.children[0], 0) == 0) { drop = true; }
            }
            if (drop) { s.n_lets_dropped = s.n_lets_dropped + 1; continue; }
            n.children[w] = st;
            w = w + 1;
        }
        n.child_count = w;
    }
    for (usz i = 0; i < n.child_count; i++) { s.sweep(fnroot, n.children[i], depth + 1); }
}

fn void NbeState.run_fn(NbeState* s, Node* fnode)
{
    if (s.scope == null || s.map == null) { return; }
    if ((fnode.flags & pfront_core::NF_SYNTHETIC) != 0) { return; }   // rewrite/pgen blocks
    s.n_fns = s.n_fns + 1;
    s.fuel = NBE_FUEL;
    s.scope_count = 0;
    usz beta_before = s.n_beta;
    for (usz i = 0; i < fnode.child_count; i++)
    {
        Node* c = fnode.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM) { s.scope_pattern(c, 0); }
        else if (c.kind == Nk.N_BLOCK || c.kind == Nk.N_CLAUSE) { fnode.set_child(i, s.norm(c, null, 0)); }
    }
    if (s.n_beta != beta_before || s.n_eta > 0) { s.sweep(fnode, fnode, 0); }
}

// The pipeline entry point (was `walk`).
fn void NbeState.walk(NbeState* s, Node* root, int depth)
{
    if (root == null || depth > NBE_MAX_DEPTH) { return; }
    if (root.kind == Nk.N_DECL_FN) { s.run_fn(root); }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* c = root.children[i];
        if (c == null) { continue; }
        // Only descend to find further fn decls (modules, nested fns).
        if (c.kind == Nk.N_DECL_FN || c.kind == Nk.N_MODULE || c.kind == Nk.N_BLOCK || c.kind == Nk.N_CLAUSE
            || c.kind == Nk.N_DECL_IMPL)
        {
            s.walk(c, depth + 1);
        }
    }
}

fn void NbeState.report(NbeState* s)
{
    printf("  nbe              : %d fns, %d lambdas, %d applications seen\n",
           (int)s.n_fns, (int)s.n_lambdas_seen, (int)s.n_apps_seen);
    printf("  nbe-rewrites     : %d beta, %d delta, %d eta, %d if-folded, %d lets made, %d lets dropped, refused: %d capture %d fuel\n",
           (int)s.n_beta, (int)s.n_delta, (int)s.n_eta, (int)s.n_if_folded, (int)s.n_lets_made,
           (int)s.n_lets_dropped, (int)s.n_refused_capture, (int)s.n_refused_fuel);
}
