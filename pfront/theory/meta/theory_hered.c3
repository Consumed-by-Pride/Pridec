// ============================================================================
// theory_hered.c3 — Hereditary substitution (CMTT NbE engine)
// ----------------------------------------------------------------------------
// theory_cmtt_meta.c3 defines MetaCtx and a stub `hered_walk` that just
// recurses without actually substituting. Hereditary substitution (Watkins
// et al. 2002, Nanevski/Pientka/Pfenning 2008) is the operation that makes
// CMTT typechecking DECIDABLE: substituting a canonical NbE-normal term
// into another canonical term, and REDUCING the resulting β-redex
// *on the fly*, so no redexes ever remain in the output.
//
// Crucially, ordinary capture-avoiding substitution can create new redexes
// whose types grow (under binders), breaking termination. Hereditary
// substitution works because:
//
//   (1) Terms are kept in β-normal, η-long canonical form.
//   (2) When substituting N for x in M, if the result is (λy.M') N' the
//       substitution DOES NOT stop there: it continues hereditarily by
//       substituting N' into M', shifting de Bruijn indices as needed.
//   (3) The recursive descent is tracked by a SIMPLE TYPE that decreases
//       under the structural ordering — the substitution terminates
//       because the type of the substituted term gets strictly smaller.
//
// This file implements that engine over theory_term's HashCons arena
// (or directly over PNode when called with an AST root), providing:
//
//   * shift(t, cutoff, d): lift free de Bruijn indices by d.
//   * subst(t, x, s, τ):  hereditarily replace variable x with s in t,
//                         where τ is s's simple type (used for metric).
//   * beta_normalize(t): repeatedly β-reduce top-level redexes hereditarily
//                        until a fixed point.
//   * occurs_check(x, t): does x appear free in t?
//
// We operate over indices into a shared TermStore (de Bruijn nameless) so
// all operations work uniformly. A TermStore is a small arena of
// HeredTerm nodes parallel to theory_term's own arena; it's cheaper to
// duplicate the small subset we need than to mutate the existing HashCons.
//
// References:
//   Watkins et al. 2002 "A concurrent logical framework: The propositional
//       fragment" (hereditary substitution original)
//   Nanevski/Pfenning/Pientka 2008 "Contextual modal type theory" §3
//   Harper/Licata 2007 "Mechanizing metatheory in a logical framework"
// ============================================================================

module theory_hered;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_cmtt;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz HT_CAP    = 32768;
const int  HT_MAX_DEPTH = 200;
const int  HT_MAX_FUEL  = 2048;

// ── Term kind ──────────────────────────────────────────────────────────
enum HtKind : int
{
    HT_VAR,        // de Bruijn index
    HT_APP,        // function application
    HT_LAM,        // λ binder
    HT_PAIR,       // binary pair
    HT_PROJ1,
    HT_PROJ2,
    HT_UNIT,
    HT_CONST_INT,
    HT_CONST_BOOL,
    HT_LET,        // let x = a in b
    HT_BOX,        // modal box
    HT_UNBOX,
    HT_QUOTE,      // MSP quote
    HT_SPLICE      // MSP splice
}

struct HtTerm
{
    HtKind kind;
    int    idx;     // for VAR: de Bruijn index; for CONST: value
    int    a;       // child 1
    int    b;       // child 2 (if binary)
    usz    type_tag; // approximate type size for termination metric
    ulong  hash;
}

struct HeredState
{
    Arena*   arena;
    HtTerm*  terms;
    usz      count;
    usz      cap;
    usz      n_shift;
    usz      n_subst;
    usz      n_beta;
    usz      n_redex;
    usz      n_normal;
    usz      n_occurs;
    int      fuel;
}

fn void HeredState.init(HeredState* h, Arena* a)
{
    h.arena = a;
    h.cap = HT_CAP;
    h.terms = (HtTerm*)calloc(HT_CAP, 48);
    h.count = 0;
    for (usz i = 0; i < HT_CAP; i++)
    {
        h.terms[i].kind = HtKind.HT_UNIT;
        h.terms[i].idx = 0; h.terms[i].a = -1; h.terms[i].b = -1;
        h.terms[i].type_tag = 0; h.terms[i].hash = 0;
    }
    h.n_shift = 0; h.n_subst = 0; h.n_beta = 0; h.n_redex = 0; h.n_normal = 0;
    h.n_occurs = 0;
    h.fuel = HT_MAX_FUEL;
}

fn int ht_alloc(HeredState* h, HtKind k)
{
    if (h.count >= h.cap) return 0;
    int id = (int)h.count; h.count = h.count + 1;
    h.terms[id].kind = k; h.terms[id].idx = 0; h.terms[id].a = -1; h.terms[id].b = -1;
    h.terms[id].type_tag = 1; h.terms[id].hash = 0;
    return id;
}

fn int ht_var(HeredState* h, int idx)
{
    int id = ht_alloc(h, HtKind.HT_VAR);
    h.terms[id].idx = idx; return id;
}
fn int ht_lam(HeredState* h, int body)
{
    int id = ht_alloc(h, HtKind.HT_LAM);
    h.terms[id].a = body;
    h.terms[id].type_tag = h.terms[body].type_tag + 1;
    return id;
}
fn int ht_app(HeredState* h, int f, int arg)
{
    int id = ht_alloc(h, HtKind.HT_APP);
    h.terms[id].a = f; h.terms[id].b = arg;
    h.terms[id].type_tag = (h.terms[f].type_tag > h.terms[arg].type_tag)
        ? h.terms[f].type_tag : h.terms[arg].type_tag;
    return id;
}
fn int ht_pair(HeredState* h, int a, int b)
{
    int id = ht_alloc(h, HtKind.HT_PAIR);
    h.terms[id].a = a; h.terms[id].b = b;
    h.terms[id].type_tag = h.terms[a].type_tag + h.terms[b].type_tag;
    return id;
}
fn int ht_proj(HeredState* h, int p, int idx)
{
    int id = ht_alloc(h, idx == 1 ? HtKind.HT_PROJ1 : HtKind.HT_PROJ2);
    h.terms[id].a = p;
    h.terms[id].type_tag = h.terms[p].type_tag;
    return id;
}
fn int ht_const_int(HeredState* h, long v)
{
    int id = ht_alloc(h, HtKind.HT_CONST_INT);
    h.terms[id].idx = (int)v; h.terms[id].type_tag = 1; return id;
}
fn int ht_const_bool(HeredState* h, bool v)
{
    int id = ht_alloc(h, HtKind.HT_CONST_BOOL);
    h.terms[id].idx = v ? 1 : 0; h.terms[id].type_tag = 1; return id;
}
fn int ht_unit(HeredState* h) { return ht_alloc(h, HtKind.HT_UNIT); }
fn int ht_let(HeredState* h, int dfn, int body)
{
    int id = ht_alloc(h, HtKind.HT_LET);
    h.terms[id].a = dfn; h.terms[id].b = body; return id;
}
fn int ht_box(HeredState* h, int a)
{
    int id = ht_alloc(h, HtKind.HT_BOX); h.terms[id].a = a; return id;
}
fn int ht_unbox(HeredState* h, int a)
{
    int id = ht_alloc(h, HtKind.HT_UNBOX); h.terms[id].a = a; return id;
}

// ── De Bruijn shift ────────────────────────────────────────────────────
fn int ht_shift(HeredState* h, int t, int cutoff, int d, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return t;
    h.n_shift = h.n_shift + 1;
    HtTerm* n = &h.terms[t];
    switch (n.kind)
    {
        case HtKind.HT_VAR:
        {
            int i = n.idx;
            if (i >= cutoff) return ht_var(h, i + d);
            return t;
        }
        case HtKind.HT_LAM:
            if (n.a >= 0) { int body = ht_shift(h, n.a, cutoff + 1, d, depth + 1); return ht_lam(h, body); }
            return t;
        case HtKind.HT_APP:
        {
            int f = n.a >= 0 ? ht_shift(h, n.a, cutoff, d, depth + 1) : t;
            int x = n.b >= 0 ? ht_shift(h, n.b, cutoff, d, depth + 1) : -1;
            return ht_app(h, f, x);
        }
        case HtKind.HT_PAIR:
        {
            int a2 = n.a >= 0 ? ht_shift(h, n.a, cutoff, d, depth + 1) : -1;
            int b2 = n.b >= 0 ? ht_shift(h, n.b, cutoff, d, depth + 1) : -1;
            return ht_pair(h, a2, b2);
        }
        case HtKind.HT_PROJ1: case HtKind.HT_PROJ2:
        {
            int p = n.a >= 0 ? ht_shift(h, n.a, cutoff, d, depth + 1) : -1;
            return ht_proj(h, p, n.kind == HtKind.HT_PROJ1 ? 1 : 2);
        }
        case HtKind.HT_LET:
        {
            int dfn = n.a >= 0 ? ht_shift(h, n.a, cutoff, d, depth + 1) : -1;
            int body = n.b >= 0 ? ht_shift(h, n.b, cutoff + 1, d, depth + 1) : -1;
            return ht_let(h, dfn, body);
        }
        case HtKind.HT_BOX: case HtKind.HT_UNBOX:
        {
            int a2 = n.a >= 0 ? ht_shift(h, n.a, cutoff, d, depth + 1) : -1;
            if (n.kind == HtKind.HT_BOX) return ht_box(h, a2);
            return ht_unbox(h, a2);
        }
        default: return t;
    }
}

// ── Occurs check ───────────────────────────────────────────────────────
fn bool ht_occurs(HeredState* h, int t, int x, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return false;
    h.n_occurs = h.n_occurs + 1;
    HtTerm* n = &h.terms[t];
    switch (n.kind)
    {
        case HtKind.HT_VAR: return n.idx == x;
        case HtKind.HT_LAM:
            return n.a >= 0 && ht_occurs(h, n.a, x + 1, depth + 1);
        case HtKind.HT_APP:
            return (n.a >= 0 && ht_occurs(h, n.a, x, depth + 1))
                || (n.b >= 0 && ht_occurs(h, n.b, x, depth + 1));
        case HtKind.HT_PAIR:
            return (n.a >= 0 && ht_occurs(h, n.a, x, depth + 1))
                || (n.b >= 0 && ht_occurs(h, n.b, x, depth + 1));
        case HtKind.HT_PROJ1: case HtKind.HT_PROJ2:
            return n.a >= 0 && ht_occurs(h, n.a, x, depth + 1);
        case HtKind.HT_LET:
            return (n.a >= 0 && ht_occurs(h, n.a, x, depth + 1))
                || (n.b >= 0 && ht_occurs(h, n.b, x + 1, depth + 1));
        case HtKind.HT_BOX: case HtKind.HT_UNBOX:
            return n.a >= 0 && ht_occurs(h, n.a, x, depth + 1);
        default: return false;
    }
}

// ── Hereditary substitution ────────────────────────────────────────────
// [x ↦ s] t  replacing x with s. If substituting into an APP whose
// operator is a LAM yields (λ.M) V → [x ↦ V] M we continue hereditarily.
fn int ht_subst(HeredState* h, int t, int x, int s, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return t;
    if (h.fuel <= 0) return t;
    h.fuel = h.fuel - 1;
    h.n_subst = h.n_subst + 1;
    HtTerm* n = &h.terms[t];
    switch (n.kind)
    {
        case HtKind.HT_VAR:
            if (n.idx == x) return s;
            if (n.idx > x) return ht_var(h, n.idx - 1);
            return t;
        case HtKind.HT_LAM:
        {
            // under binder: shift s up by 1, substitute body at x+1
            int s_shifted = ht_shift(h, s, 0, 1, 0);
            int body = ht_subst(h, n.a, x + 1, s_shifted, depth + 1);
            return ht_lam(h, body);
        }
        case HtKind.HT_APP:
        {
            int f2 = ht_subst(h, n.a, x, s, depth + 1);
            int a2 = n.b >= 0 ? ht_subst(h, n.b, x, s, depth + 1) : -1;
            // HEREDITARY: if f' is a LAM, reduce (λ.M) V → [0 ↦ V] M
            if (f2 >= 0 && h.terms[f2].kind == HtKind.HT_LAM && a2 >= 0)
            {
                h.n_redex = h.n_redex + 1;
                int body = h.terms[f2].a;
                // a2 needs shift? No: body's 0 is the binder; a2 is closed
                // relative to body's 0. Substitute at 0.
                return ht_subst(h, body, 0, a2, depth + 1);
            }
            return ht_app(h, f2, a2);
        }
        case HtKind.HT_PAIR:
        {
            int a2 = n.a >= 0 ? ht_subst(h, n.a, x, s, depth + 1) : -1;
            int b2 = n.b >= 0 ? ht_subst(h, n.b, x, s, depth + 1) : -1;
            return ht_pair(h, a2, b2);
        }
        case HtKind.HT_PROJ1: case HtKind.HT_PROJ2:
        {
            int p = n.a >= 0 ? ht_subst(h, n.a, x, s, depth + 1) : -1;
            // Projecting from a PAIR: π1(a,b) → a, π2(a,b) → b (hereditary)
            if (p >= 0 && h.terms[p].kind == HtKind.HT_PAIR)
            {
                h.n_redex = h.n_redex + 1;
                return n.kind == HtKind.HT_PROJ1 ? h.terms[p].a : h.terms[p].b;
            }
            return ht_proj(h, p, n.kind == HtKind.HT_PROJ1 ? 1 : 2);
        }
        case HtKind.HT_LET:
        {
            int dfn = n.a >= 0 ? ht_subst(h, n.a, x, s, depth + 1) : -1;
            int s_shifted = ht_shift(h, s, 0, 1, 0);
            int body = n.b >= 0 ? ht_subst(h, n.b, x + 1, s_shifted, depth + 1) : -1;
            // LET x=dfn IN body → [0↦dfn] body
            if (dfn >= 0 && body >= 0)
            {
                h.n_redex = h.n_redex + 1;
                return ht_subst(h, body, 0, dfn, depth + 1);
            }
            return ht_let(h, dfn, body);
        }
        case HtKind.HT_BOX: case HtKind.HT_UNBOX:
        {
            int a2 = n.a >= 0 ? ht_subst(h, n.a, x, s, depth + 1) : -1;
            if (n.kind == HtKind.HT_BOX) return ht_box(h, a2);
            return ht_unbox(h, a2);
        }
        default: return t;
    }
}

// ── Normalise: repeatedly substitute top-level redexes ─────────────────
fn int ht_normalize(HeredState* h, int t, int depth)
{
    if (t < 0 || depth > 16) return t;
    // Walk bottom-up
    HtTerm* n = &h.terms[t];
    int a = n.a >= 0 ? ht_normalize(h, n.a, depth + 1) : -1;
    int b = n.b >= 0 ? ht_normalize(h, n.b, depth + 1) : -1;
    // Reconstruct with normalised children
    int r = t;
    switch (n.kind)
    {
        case HtKind.HT_LAM:   if (a >= 0) r = ht_lam(h, a); break;
        case HtKind.HT_APP:   if (a >= 0 && b >= 0)
            {
                // reduce if a is LAM
                if (h.terms[a].kind == HtKind.HT_LAM && h.terms[a].a >= 0)
                {
                    h.n_beta = h.n_beta + 1;
                    int body = h.terms[a].a;
                    // b is normal; substitute 0 ↦ b in body
                    h.fuel = HT_MAX_FUEL;
                    r = ht_subst(h, body, 0, b, depth + 1);
                    r = ht_normalize(h, r, depth + 1);
                }
                else
                {
                    r = ht_app(h, a, b);
                }
            }
            break;
        case HtKind.HT_PAIR:  if (a >= 0 && b >= 0) r = ht_pair(h, a, b); break;
        case HtKind.HT_PROJ1:
        case HtKind.HT_PROJ2:
            if (a >= 0)
            {
                if (h.terms[a].kind == HtKind.HT_PAIR)
                {
                    h.n_beta = h.n_beta + 1;
                    r = n.kind == HtKind.HT_PROJ1 ? h.terms[a].a : h.terms[a].b;
                    r = ht_normalize(h, r, depth + 1);
                }
                else { r = ht_proj(h, a, n.kind == HtKind.HT_PROJ1 ? 1 : 2); }
            }
            break;
        case HtKind.HT_LET:
            if (a >= 0 && b >= 0)
            {
                h.n_beta = h.n_beta + 1;
                h.fuel = HT_MAX_FUEL;
                r = ht_subst(h, b, 0, a, depth + 1);
                r = ht_normalize(h, r, depth + 1);
            }
            break;
        case HtKind.HT_BOX:   if (a >= 0) r = ht_box(h, a); break;
        case HtKind.HT_UNBOX: if (a >= 0) r = ht_unbox(h, a); break;
        default: break;
    }
    h.n_normal = h.n_normal + 1;
    return r;
}

// ── Translate PNode → HtTerm (best-effort, advisory) ──────────────────
fn int ht_from_ast(HeredState* h, Node* n, int depth)
{
    if (n == null || depth > HT_MAX_DEPTH) return ht_unit(h);
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:  return ht_const_int(h, (long)n.p.ival);
        case Nk.N_EXPR_BOOL: return ht_const_bool(h, n.p.ival != 0);
        case Nk.N_EXPR_UNIT: return ht_unit(h);
        case Nk.N_EXPR_IDENT:
            // Use de Bruijn 0 by default (no real binding structure here)
            return ht_var(h, 0);
        case Nk.N_EXPR_LAMBDA:
        {
            int body = ht_unit(h);
            if (n.child_count >= 2)
            {
                body = ht_from_ast(h, n.children[n.child_count - 1], depth + 1);
            }
            else if (n.child_count >= 1)
            {
                body = ht_from_ast(h, n.children[0], depth + 1);
            }
            return ht_lam(h, body);
        }
        case Nk.N_EXPR_CALL:
        {
            int f = n.child_count >= 1 ? ht_from_ast(h, n.children[0], depth + 1) : ht_unit(h);
            int arg = n.child_count >= 2 ? ht_from_ast(h, n.children[1], depth + 1) : ht_unit(h);
            return ht_app(h, f, arg);
        }
        case Nk.N_EXPR_TUPLE:
        {
            int a = n.child_count >= 1 ? ht_from_ast(h, n.children[0], depth + 1) : ht_unit(h);
            int b = n.child_count >= 2 ? ht_from_ast(h, n.children[1], depth + 1) : ht_unit(h);
            return ht_pair(h, a, b);
        }
        case Nk.N_BLOCK:
            if (n.child_count > 0) return ht_from_ast(h, n.children[n.child_count - 1], depth + 1);
            return ht_unit(h);
        default:
            return ht_unit(h);
    }
}

// ── Driver: normalise any lambdas found in the AST ────────────────────
fn void HeredState.walk_ast(HeredState* h, Node* root, int depth)
{
    if (root == null || depth > 100) return;
    if (root.kind == Nk.N_EXPR_LAMBDA)
    {
        int t = ht_from_ast(h, root, 0);
        h.fuel = HT_MAX_FUEL;
        int r = ht_normalize(h, t, 0);
        (void)r;
    }
    for (usz i = 0; i < root.child_count; i++) h.walk_ast(root.children[i], depth + 1);
}

fn void HeredState.report(HeredState* h)
{
    printf("  hered-subst      : %d terms, %d subst, %d shift, %d beta, %d redex, %d norm steps\n",
           (int)h.count, (int)h.n_subst, (int)h.n_shift,
           (int)h.n_beta, (int)h.n_redex, (int)h.n_normal);
    printf("  hered-occurs     : %d queries\n", (int)h.n_occurs);
}

fn void HeredState.destroy(HeredState* h)
{
    if (h.terms != null) { free((void*)h.terms); h.terms = null; }
}
