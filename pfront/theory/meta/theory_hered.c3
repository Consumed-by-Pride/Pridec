// ============================================================================
// theory_hered.c3 — Hereditary substitution: a decision procedure for
//                   βη-equivalence of Pride's functional fragment
// ----------------------------------------------------------------------------
// Hereditary substitution (Watkins et al. 2002; Nanevski/Pfenning/Pientka
// 2008 §3; Harper/Licata 2007) is the operation that makes CMTT / LF
// typechecking DECIDABLE: substituting a canonical (β-normal, η-short) term
// into another canonical term and REDUCING every β-redex the substitution
// creates *on the fly*, so the output is canonical again. Ordinary
// substitution followed by β-reduction can diverge; hereditary substitution
// terminates because every redex it reduces has a strictly smaller simple
// type than the substitution that created it (the "metric").
//
// This file is that engine, made real for Pride:
//
//   TRANSLATION   Pride expressions → de Bruijn terms in a hash-consed store.
//                 Lambdas, clause-form functions and `let` are binders;
//                 identifiers resolve by the resolver's binder pointer (never
//                 by name); multi-argument calls are curried; tuples are
//                 nested pairs; `if`, arithmetic, comparisons, field access,
//                 `quote`/`splice` are terms; everything imperative (loops,
//                 assignment, `match`, effects, mutable bindings, `return`)
//                 becomes an OPAQUE leaf keyed by its own AST node — it is
//                 equal only to itself, which keeps every judgement below
//                 sound (two units are equal only if they are equal on the
//                 pure fragment AND share all their opaque parts).
//
//   ENGINE        shift · hereditary substitution · δ-rules for literal
//                 arithmetic and comparison · `if` on a literal · projection
//                 of a pair · modal β (splice(quote e) → e) and modal η
//                 (quote(splice q) → q) · η-contraction of λx. f x (x ∉ f)
//                 at construction, so normal forms are η-short and
//                 βη-equivalence is INDEX EQUALITY in the hash-consed store.
//                 Every substitution carries the simple-type size of the
//                 substituted term as its metric; the report says how deep
//                 that metric went and whether any normalisation was cut
//                 by fuel (none should be — the metric is the proof).
//
//   JUDGEMENTS    over the module (advisory; the program is never changed):
//     N4270  (--lint) two functions / closures are βη-equivalent: they
//                     normalise to the same canonical term. Reported once
//                     per pair, on the later one, with the shared normal
//                     form. Only non-trivial forms (≥ 4 nodes) and only
//                     when both sides are opaque-free.
//     N4271  (--lint) η-wrapper: a function whose canonical form IS another
//                     function (`fn f | x -> g(x)`, `fn h | (a, b) -> g(a, b)`).
//     N4272  (--lint) a β-redex written in the source, `(fn x -> e)(a)`,
//                     with what it reduces to.
//     N4273  (--lint) a staging redex: `splice (quote e)` or `quote (splice q)`.
//
//   META-VARIABLES  every `splice x` under a `quote` whose `x` is bound
//                 OUTSIDE the quote is a contextual meta-variable u::A[Ψ]
//                 (Ψ = the binders introduced inside the quote up to that
//                 point). They are collected and counted; the cmtt-meta
//                 report reads them. Cross-stage escapes are already sema
//                 errors (E3202), so nothing is re-diagnosed here.
//
// References:
//   Watkins, Cervesato, Pfenning, Walker 2002 "A concurrent logical
//       framework I: judgments and properties" (hereditary substitution)
//   Nanevski, Pfenning, Pientka 2008 "Contextual modal type theory", TOCL
//   Harper, Licata 2007 "Mechanizing metatheory in a logical framework", JFP
//   Abel 2009 "Normalization by evaluation for hereditary substitution"
// ============================================================================

module theory_hered;

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

const usz HT_CAP        = 262144;   // terms
const usz HT_BUCKETS    = 65536;    // hash-cons table (power of two)
const int HT_MAX_DEPTH  = 256;
const int HT_FUEL       = 200000;   // steps per normalisation; the metric should never need it
const usz HT_MAX_UNITS  = 8192;
const usz HT_MAX_ENV    = 512;
const usz HT_MAX_METAS  = 2048;
const int HT_MIN_REPORT = 4;        // smallest normal form worth an N4270

// ── Terms ────────────────────────────────────────────────────────────────────
enum HtKind : int
{
    HT_VAR,      // de Bruijn index (val)
    HT_FREE,     // a free name: binder pointer in key, ident node in at
    HT_LAM,      // λ. a           (val = simple-type size of the parameter, 0 unknown)
    HT_APP,      // a b
    HT_PAIR,     // (a, b)
    HT_FST,      // π₁ a
    HT_SND,      // π₂ a
    HT_UNIT,     // ()
    HT_INT,      // integer literal (val)
    HT_BOOL,     // boolean literal (val)
    HT_PRIM,     // binary primitive: key = operator token, a, b
    HT_NEG,      // unary primitive: key = operator token, a
    HT_IF,       // if a then b else c
    HT_FIELD,    // a.field   (key = field name id)
    HT_SEQ,      // a; b      (a kept for its effect)
    HT_QUOTE,    // ⌜a⌝
    HT_SPLICE,   // ~a
    HT_OPAQUE    // an effectful / unsupported construct: key = its AST node
}

struct HtTerm
{
    HtKind kind;
    int    a;        // children (−1 if absent)
    int    b;
    int    c;
    long   val;      // literal value / de Bruijn index / λ metric
    ulong  key;      // operator, field id, binder / node identity
    Node*  at;       // source node (FREE: the identifier; OPAQUE: the construct)
    int    size;     // node count
    int    mfree;    // 1 + highest free de Bruijn index (0 = closed)
    bool   opaque;   // contains an HT_OPAQUE
    ulong  hash;
    int    next;     // hash-cons chain
}

// ── Judged units: top-level fns and lambdas ─────────────────────────────────
enum UnitKind : int { UK_FN, UK_LAMBDA }

struct Unit
{
    Node*    node;
    UnitKind kind;
    int      term;      // translation
    int      nf;        // canonical form
    int      nparams;
    bool     judged;    // opaque-free and fully normalised
    bool     reported;  // already the subject of an N4270
    Node*    fn_decl;   // enclosing fn (lambdas)
    usz      snap;      // start of the definition-site environment snapshot
    usz      snap_len;
    int      closed;    // nf with the definition-site binders as free names
}

// ── Contextual meta-variables (splices under quotes) ────────────────────────
struct MetaVar
{
    Node* splice;       // the `splice` node
    Node* binder;       // what it splices (a stage-0 binder), or null
    int   psi;          // |Ψ|: binders introduced inside the quote above it
    int   level;        // quotation depth at the splice
}

struct EnvEnt { Node* b1; Node* b2; }   // two AST spellings of one binder (param + its pattern)

struct HeredState
{
    Arena*    arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;

    HtTerm*   terms;
    usz       count;
    usz       cap;
    int*      buckets;

    // translation
    EnvEnt*   env;
    usz       env_len;
    int       level;          // quotation depth while translating
    int       quote_base;     // env_len when the innermost quote was entered
    Node*     cur_fn;
    usz       n_src_redex;    // `(fn …)(…)` written in the source
    usz       n_let_redex;    // `let x = e` (a β-redex by construction)
    usz       n_opaque;
    usz       n_free;
    usz       n_binders;

    // engine
    int       fuel;
    bool      stuck;
    usz       n_shift;
    usz       n_subst;
    usz       n_beta;
    usz       n_delta;
    usz       n_proj;
    usz       n_ifsel;
    usz       n_eta;
    usz       n_modal;
    usz       n_norm_calls;
    usz       n_fuel_cuts;
    long      metric_max;
    usz       n_hits;         // hash-cons hits (structural sharing found)

    // units
    Unit*     units;
    usz       n_units;
    Node**    snaps;          // environment snapshots (binders, outermost first)
    usz       n_snaps;
    usz       n_fn_units;
    usz       n_lam_units;
    usz       n_judged;
    usz       n_equiv;        // N4270
    usz       n_eta_wrap;     // N4271
    usz       n_n4272;
    usz       n_n4273;

    // metas
    MetaVar*  metas;
    usz       n_metas;
    usz       n_quotes;
    usz       n_open_quotes;  // quotes that mention a stage-0 binder through a splice
    usz       n_splices;
}

// ═══════════════════════════════════════════════════════════════════════════
// Store: hash-consed construction with smart constructors
// ═══════════════════════════════════════════════════════════════════════════
fn void HeredState.init(HeredState* h, Arena* a)
{
    h.arena = a;
    h.diags = null; h.interner = null; h.file = null;
    h.cap = HT_CAP;
    h.terms = (HtTerm*)calloc(HT_CAP, HtTerm::size);
    h.count = 0;
    h.buckets = (int*)malloc(HT_BUCKETS * 4);
    for (usz i = 0; i < HT_BUCKETS; i++) { h.buckets[i] = -1; }
    h.env = (EnvEnt*)calloc(HT_MAX_ENV, EnvEnt::size);
    h.env_len = 0; h.level = 0; h.quote_base = 0; h.cur_fn = null;
    h.n_src_redex = 0; h.n_let_redex = 0; h.n_opaque = 0; h.n_free = 0; h.n_binders = 0;
    h.fuel = HT_FUEL; h.stuck = false;
    h.n_shift = 0; h.n_subst = 0; h.n_beta = 0; h.n_delta = 0; h.n_proj = 0; h.n_ifsel = 0;
    h.n_eta = 0; h.n_modal = 0; h.n_norm_calls = 0; h.n_fuel_cuts = 0; h.metric_max = 0; h.n_hits = 0;
    h.units = (Unit*)calloc(HT_MAX_UNITS, Unit::size);
    h.snaps = (Node**)calloc(HT_MAX_UNITS * 16, (usz)8);
    h.n_snaps = 0;
    h.n_units = 0; h.n_fn_units = 0; h.n_lam_units = 0; h.n_judged = 0;
    h.n_equiv = 0; h.n_eta_wrap = 0; h.n_n4272 = 0; h.n_n4273 = 0;
    h.metas = (MetaVar*)calloc(HT_MAX_METAS, MetaVar::size);
    h.n_metas = 0; h.n_quotes = 0; h.n_open_quotes = 0; h.n_splices = 0;
}

fn void HeredState.attach(HeredState* h, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    h.diags = d; h.interner = it; h.file = file;
}

fn void HeredState.destroy(HeredState* h)
{
    if (h.terms != null)   { free((void*)h.terms);   h.terms = null; }
    if (h.buckets != null) { free((void*)h.buckets); h.buckets = null; }
    if (h.env != null)     { free((void*)h.env);     h.env = null; }
    if (h.units != null)   { free((void*)h.units);   h.units = null; }
    if (h.snaps != null)   { free((void*)h.snaps);   h.snaps = null; }
    if (h.metas != null)   { free((void*)h.metas);   h.metas = null; }
}

fn ulong mix(ulong x)
{
    x = x ^ (x >> 33); x = x * 0xff51afd7ed558ccd; x = x ^ (x >> 33);
    x = x * 0xc4ceb9fe1a85ec53; x = x ^ (x >> 33);
    return x;
}

fn ulong term_hash(HtKind k, int a, int b, int c, long val, ulong key)
{
    ulong x = (ulong)k * 0x9e3779b97f4a7c15;
    x = mix(x ^ (ulong)(a + 1)) * 31 + mix((ulong)(b + 1));
    x = mix(x ^ (ulong)(c + 1)) * 31 + mix((ulong)val);
    x = mix(x ^ key);
    return x;
}

fn int HeredState.child_size(HeredState* h, int t) { return t >= 0 ? h.terms[t].size : 0; }
fn int HeredState.child_mfree(HeredState* h, int t) { return t >= 0 ? h.terms[t].mfree : 0; }
fn bool HeredState.child_opaque(HeredState* h, int t) { return t >= 0 ? h.terms[t].opaque : false; }
fn int imax(int a, int b) { return a > b ? a : b; }

// raw hash-consed allocation; all constructors go through here
fn int HeredState.mk(HeredState* h, HtKind k, int a, int b, int c, long val, ulong key, Node* at)
{
    ulong hv = term_hash(k, a, b, c, val, key);
    usz bkt = (usz)(hv & (ulong)(HT_BUCKETS - 1));
    int i = h.buckets[bkt];
    while (i >= 0)
    {
        HtTerm* t = &h.terms[i];
        if (t.hash == hv && t.kind == k && t.a == a && t.b == b && t.c == c && t.val == val && t.key == key)
        {
            h.n_hits = h.n_hits + 1;
            return i;
        }
        i = t.next;
    }
    if (h.count >= h.cap) { h.stuck = true; return h.count > 0 ? 0 : -1; }
    int id = (int)h.count;
    h.count = h.count + 1;
    HtTerm* n = &h.terms[id];
    n.kind = k; n.a = a; n.b = b; n.c = c; n.val = val; n.key = key; n.at = at;
    n.hash = hv; n.next = h.buckets[bkt];
    h.buckets[bkt] = id;
    n.size = 1 + h.child_size(a) + h.child_size(b) + h.child_size(c);
    n.opaque = k == HtKind.HT_OPAQUE || h.child_opaque(a) || h.child_opaque(b) || h.child_opaque(c);
    switch (k)
    {
        case HtKind.HT_VAR: n.mfree = (int)val + 1; break;
        case HtKind.HT_LAM: n.mfree = imax(0, h.child_mfree(a) - 1); break;
        default: n.mfree = imax(h.child_mfree(a), imax(h.child_mfree(b), h.child_mfree(c))); break;
    }
    return id;
}

fn int HeredState.bvar(HeredState* h, int idx)      { return h.mk(HtKind.HT_VAR, -1, -1, -1, (long)idx, 0, null); }
fn int HeredState.unit(HeredState* h)              { return h.mk(HtKind.HT_UNIT, -1, -1, -1, 0, 0, null); }
fn int HeredState.lit_int(HeredState* h, long v)   { return h.mk(HtKind.HT_INT, -1, -1, -1, v, 0, null); }
fn int HeredState.lit_bool(HeredState* h, bool v)  { return h.mk(HtKind.HT_BOOL, -1, -1, -1, v ? 1 : 0, 0, null); }
fn int HeredState.free_name(HeredState* h, Node* binder, Node* ident)
{
    ulong key = binder != null ? (ulong)(uptr)binder : (0x5eed0000 + (ulong)ident.name_id);
    return h.mk(HtKind.HT_FREE, -1, -1, -1, (long)ident.name_id, key, ident);
}
fn int HeredState.pair(HeredState* h, int a, int b) { return h.mk(HtKind.HT_PAIR, a, b, -1, 0, 0, null); }
fn int HeredState.prim(HeredState* h, int op, int a, int b) { return h.mk(HtKind.HT_PRIM, a, b, -1, 0, (ulong)op, null); }
fn int HeredState.neg(HeredState* h, int op, int a)  { return h.mk(HtKind.HT_NEG, a, -1, -1, 0, (ulong)op, null); }
fn int HeredState.ite(HeredState* h, int c, int t, int e) { return h.mk(HtKind.HT_IF, c, t, e, 0, 0, null); }
fn int HeredState.field(HeredState* h, int a, uint name) { return h.mk(HtKind.HT_FIELD, a, -1, -1, 0, (ulong)name, null); }
fn int HeredState.seq(HeredState* h, int a, int b)   { return h.mk(HtKind.HT_SEQ, a, b, -1, 0, 0, null); }
fn int HeredState.opaque(HeredState* h, Node* n)     { h.n_opaque = h.n_opaque + 1; return h.mk(HtKind.HT_OPAQUE, -1, -1, -1, 0, (ulong)(uptr)n, n); }
fn int HeredState.app(HeredState* h, int f, int x)   { return h.mk(HtKind.HT_APP, f, x, -1, 0, 0, null); }
fn int HeredState.quote(HeredState* h, int a)        { return h.mk(HtKind.HT_QUOTE, a, -1, -1, 0, 0, null); }
fn int HeredState.splice(HeredState* h, int a)       { return h.mk(HtKind.HT_SPLICE, a, -1, -1, 0, 0, null); }
fn int HeredState.proj(HeredState* h, bool first, int a) { return h.mk(first ? HtKind.HT_FST : HtKind.HT_SND, a, -1, -1, 0, 0, null); }

// λ with η-contraction: λ. f 0  with 0 ∉ f  ≡  f↓   (only on canonical bodies;
// `lam_raw` is used during translation so the source shape survives)
fn int HeredState.lam_raw(HeredState* h, int body, long metric) { return h.mk(HtKind.HT_LAM, body, -1, -1, metric, 0, null); }

fn int HeredState.lam(HeredState* h, int body, long metric)
{
    if (body >= 0 && h.terms[body].kind == HtKind.HT_APP)
    {
        HtTerm* ap = &h.terms[body];
        if (ap.b >= 0 && h.terms[ap.b].kind == HtKind.HT_VAR && h.terms[ap.b].val == 0
            && ap.a >= 0 && !h.occurs(ap.a, 0, 0) && !h.terms[ap.a].opaque)
        {
            h.n_eta = h.n_eta + 1;
            return h.shift(ap.a, 0, -1, 0);
        }
    }
    return h.lam_raw(body, metric);
}

// ═══════════════════════════════════════════════════════════════════════════
// Engine
// ═══════════════════════════════════════════════════════════════════════════
fn bool HeredState.occurs(HeredState* h, int t, int x, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return false;
    HtTerm* n = &h.terms[t];
    if (n.mfree <= x) return false;             // cheap: no free index that high
    switch (n.kind)
    {
        case HtKind.HT_VAR: return (int)n.val == x;
        case HtKind.HT_LAM: return h.occurs(n.a, x + 1, depth + 1);
        default:
            return h.occurs(n.a, x, depth + 1) || h.occurs(n.b, x, depth + 1) || h.occurs(n.c, x, depth + 1);
    }
}

// lift free indices ≥ cutoff by d (d may be −1 after an η-contraction)
fn int HeredState.shift(HeredState* h, int t, int cutoff, int d, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return t;
    HtTerm* n = &h.terms[t];
    if (n.mfree <= cutoff) return t;            // nothing to move
    h.n_shift = h.n_shift + 1;
    switch (n.kind)
    {
        case HtKind.HT_VAR:
            return (int)n.val >= cutoff ? h.bvar((int)n.val + d) : t;
        case HtKind.HT_LAM:
            return h.lam_raw(h.shift(n.a, cutoff + 1, d, depth + 1), n.val);
        default:
        {
            int a = h.shift(n.a, cutoff, d, depth + 1);
            int b = h.shift(n.b, cutoff, d, depth + 1);
            int c = h.shift(n.c, cutoff, d, depth + 1);
            return h.mk(n.kind, a, b, c, n.val, n.key, n.at);
        }
    }
}

fn bool HeredState.spend(HeredState* h)
{
    if (h.fuel <= 0) { if (!h.stuck) { h.n_fuel_cuts = h.n_fuel_cuts + 1; } h.stuck = true; return false; }
    h.fuel = h.fuel - 1;
    return true;
}

// δ-rules: literal arithmetic / comparison / boolean connectives
fn int HeredState.delta(HeredState* h, int op, int a, int b)
{
    HtTerm* x = &h.terms[a];
    HtTerm* y = &h.terms[b];
    bool ints  = x.kind == HtKind.HT_INT && y.kind == HtKind.HT_INT;
    bool bools = x.kind == HtKind.HT_BOOL && y.kind == HtKind.HT_BOOL;
    long p = x.val; long q = y.val;
    if (ints)
    {
        switch ((Tk)op)
        {
            case Tk.TOKEN_PLUS:    h.n_delta = h.n_delta + 1; return h.lit_int(p + q);
            case Tk.TOKEN_MINUS:   h.n_delta = h.n_delta + 1; return h.lit_int(p - q);
            case Tk.TOKEN_STAR:    h.n_delta = h.n_delta + 1; return h.lit_int(p * q);
            case Tk.TOKEN_SLASH:   if (q != 0) { h.n_delta = h.n_delta + 1; return h.lit_int(p / q); } break;
            case Tk.TOKEN_PERCENT: if (q != 0) { h.n_delta = h.n_delta + 1; return h.lit_int(p % q); } break;
            case Tk.TOKEN_EQEQ:    h.n_delta = h.n_delta + 1; return h.lit_bool(p == q);
            case Tk.TOKEN_NEQ:
            case Tk.TOKEN_NEQ_UNI: h.n_delta = h.n_delta + 1; return h.lit_bool(p != q);
            case Tk.TOKEN_LT:      h.n_delta = h.n_delta + 1; return h.lit_bool(p < q);
            case Tk.TOKEN_GT:      h.n_delta = h.n_delta + 1; return h.lit_bool(p > q);
            case Tk.TOKEN_LTEQ:    h.n_delta = h.n_delta + 1; return h.lit_bool(p <= q);
            case Tk.TOKEN_GTEQ:    h.n_delta = h.n_delta + 1; return h.lit_bool(p >= q);
            default: break;
        }
    }
    if (bools)
    {
        switch ((Tk)op)
        {
            case Tk.TOKEN_AMPAMP:   h.n_delta = h.n_delta + 1; return h.lit_bool(p != 0 && q != 0);
            case Tk.TOKEN_PIPEPIPE: h.n_delta = h.n_delta + 1; return h.lit_bool(p != 0 || q != 0);
            case Tk.TOKEN_EQEQ:     h.n_delta = h.n_delta + 1; return h.lit_bool(p == q);
            case Tk.TOKEN_NEQ:
            case Tk.TOKEN_NEQ_UNI:  h.n_delta = h.n_delta + 1; return h.lit_bool(p != q);
            default: break;
        }
    }
    // algebraic identities on one literal side (x + 0, x * 1, true && x …)
    if (y.kind == HtKind.HT_INT)
    {
        if ((op == (int)Tk.TOKEN_PLUS || op == (int)Tk.TOKEN_MINUS) && q == 0) { h.n_delta = h.n_delta + 1; return a; }
        if (op == (int)Tk.TOKEN_STAR && q == 1) { h.n_delta = h.n_delta + 1; return a; }
    }
    if (x.kind == HtKind.HT_INT)
    {
        if (op == (int)Tk.TOKEN_PLUS && p == 0) { h.n_delta = h.n_delta + 1; return b; }
        if (op == (int)Tk.TOKEN_STAR && p == 1) { h.n_delta = h.n_delta + 1; return b; }
    }
    if (y.kind == HtKind.HT_BOOL)
    {
        if (op == (int)Tk.TOKEN_AMPAMP && q != 0) { h.n_delta = h.n_delta + 1; return a; }
        if (op == (int)Tk.TOKEN_PIPEPIPE && q == 0) { h.n_delta = h.n_delta + 1; return a; }
    }
    if (x.kind == HtKind.HT_BOOL)
    {
        if (op == (int)Tk.TOKEN_AMPAMP && p != 0) { h.n_delta = h.n_delta + 1; return b; }
        if (op == (int)Tk.TOKEN_PIPEPIPE && p == 0) { h.n_delta = h.n_delta + 1; return b; }
    }
    return h.prim(op, a, b);
}

fn int HeredState.delta1(HeredState* h, int op, int a)
{
    HtTerm* x = &h.terms[a];
    if (x.kind == HtKind.HT_INT && op == (int)Tk.TOKEN_MINUS) { h.n_delta = h.n_delta + 1; return h.lit_int(-x.val); }
    if (x.kind == HtKind.HT_BOOL && op == (int)Tk.TOKEN_BANG) { h.n_delta = h.n_delta + 1; return h.lit_bool(x.val == 0); }
    // ¬¬x → x
    if (x.kind == HtKind.HT_NEG && (int)x.key == op && (op == (int)Tk.TOKEN_BANG || op == (int)Tk.TOKEN_MINUS)) { h.n_delta = h.n_delta + 1; return x.a; }
    return h.neg(op, a);
}

// canonical-form smart constructors used by both `subst` and `norm`: given
// canonical children they return a canonical term (this is where the
// "hereditary" reductions live)
fn int HeredState.c_app(HeredState* h, int f, int x, long metric, int depth)
{
    if (f >= 0 && h.terms[f].kind == HtKind.HT_LAM && x >= 0)
    {
        h.n_beta = h.n_beta + 1;
        long m = h.terms[f].val > 0 ? h.terms[f].val : metric;
        if (m > h.metric_max) { h.metric_max = m; }
        return h.subst(h.terms[f].a, 0, x, m, depth + 1);
    }
    return h.app(f, x);
}

fn int HeredState.c_proj(HeredState* h, bool first, int p)
{
    if (p >= 0 && h.terms[p].kind == HtKind.HT_PAIR)
    {
        h.n_proj = h.n_proj + 1;
        return first ? h.terms[p].a : h.terms[p].b;
    }
    return h.proj(first, p);
}

fn int HeredState.c_if(HeredState* h, int c, int t, int e)
{
    if (c >= 0 && h.terms[c].kind == HtKind.HT_BOOL) { h.n_ifsel = h.n_ifsel + 1; return h.terms[c].val != 0 ? t : e; }
    if (t == e && t >= 0 && !h.terms[t].opaque) { h.n_ifsel = h.n_ifsel + 1; return t; }   // if c then x else x
    return h.ite(c, t, e);
}

fn int HeredState.c_splice(HeredState* h, int a)
{
    if (a >= 0 && h.terms[a].kind == HtKind.HT_QUOTE) { h.n_modal = h.n_modal + 1; return h.terms[a].a; }   // modal β
    return h.splice(a);
}

fn int HeredState.c_quote(HeredState* h, int a)
{
    if (a >= 0 && h.terms[a].kind == HtKind.HT_SPLICE) { h.n_modal = h.n_modal + 1; return h.terms[a].a; }  // modal η
    return h.quote(a);
}

// [x ↦ s] t, hereditarily. `t` and `s` canonical ⇒ result canonical.
// `metric` is the simple-type size of s: each nested redex this creates is
// reduced with a strictly smaller metric (the function's parameter type is
// a proper subterm of the arrow type the metric measures).
fn int HeredState.subst(HeredState* h, int t, int x, int s, long metric, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) { if (depth > HT_MAX_DEPTH) { h.stuck = true; } return t; }
    if (!h.spend()) return t;
    HtTerm* n = &h.terms[t];
    if (n.mfree <= x) return t;                 // x does not occur: nothing to do (indices above x are not present either)
    h.n_subst = h.n_subst + 1;
    switch (n.kind)
    {
        case HtKind.HT_VAR:
            if ((int)n.val == x) return s;
            if ((int)n.val > x) return h.bvar((int)n.val - 1);
            return t;
        case HtKind.HT_LAM:
        {
            int s1 = h.shift(s, 0, 1, 0);
            int body = h.subst(n.a, x + 1, s1, metric, depth + 1);
            return h.lam(body, n.val);
        }
        case HtKind.HT_APP:
        {
            int f2 = h.subst(n.a, x, s, metric, depth + 1);
            int a2 = h.subst(n.b, x, s, metric, depth + 1);
            long sub = metric > 1 ? metric - 1 : 1;
            return h.c_app(f2, a2, sub, depth);
        }
        case HtKind.HT_PAIR:
            return h.pair(h.subst(n.a, x, s, metric, depth + 1), h.subst(n.b, x, s, metric, depth + 1));
        case HtKind.HT_FST: return h.c_proj(true,  h.subst(n.a, x, s, metric, depth + 1));
        case HtKind.HT_SND: return h.c_proj(false, h.subst(n.a, x, s, metric, depth + 1));
        case HtKind.HT_PRIM:
            return h.delta((int)n.key, h.subst(n.a, x, s, metric, depth + 1), h.subst(n.b, x, s, metric, depth + 1));
        case HtKind.HT_NEG:
            return h.delta1((int)n.key, h.subst(n.a, x, s, metric, depth + 1));
        case HtKind.HT_IF:
        {
            int c = h.subst(n.a, x, s, metric, depth + 1);
            // do not substitute into a branch that is being discarded
            if (c >= 0 && h.terms[c].kind == HtKind.HT_BOOL)
            {
                h.n_ifsel = h.n_ifsel + 1;
                return h.subst(h.terms[c].val != 0 ? n.b : n.c, x, s, metric, depth + 1);
            }
            return h.c_if(c, h.subst(n.b, x, s, metric, depth + 1), h.subst(n.c, x, s, metric, depth + 1));
        }
        case HtKind.HT_FIELD:  return h.field(h.subst(n.a, x, s, metric, depth + 1), (uint)n.key);
        case HtKind.HT_SEQ:    return h.seq(h.subst(n.a, x, s, metric, depth + 1), h.subst(n.b, x, s, metric, depth + 1));
        case HtKind.HT_QUOTE:  return h.c_quote(h.subst(n.a, x, s, metric, depth + 1));
        case HtKind.HT_SPLICE: return h.c_splice(h.subst(n.a, x, s, metric, depth + 1));
        default: return t;   // FREE / literals / UNIT / OPAQUE have mfree 0 and never reach here
    }
}

// canonical form of an arbitrary (translated) term
fn int HeredState.norm(HeredState* h, int t, int depth)
{
    if (t < 0) return t;
    if (depth > HT_MAX_DEPTH) { h.stuck = true; return t; }
    if (!h.spend()) return t;
    h.n_norm_calls = h.n_norm_calls + 1;
    HtTerm* n = &h.terms[t];
    switch (n.kind)
    {
        case HtKind.HT_VAR: case HtKind.HT_FREE: case HtKind.HT_UNIT:
        case HtKind.HT_INT: case HtKind.HT_BOOL: case HtKind.HT_OPAQUE:
            return t;
        case HtKind.HT_LAM:  return h.lam(h.norm(n.a, depth + 1), n.val);
        case HtKind.HT_APP:
        {
            int f = h.norm(n.a, depth + 1);
            int x = h.norm(n.b, depth + 1);
            return h.c_app(f, x, 1, depth);
        }
        case HtKind.HT_PAIR: return h.pair(h.norm(n.a, depth + 1), h.norm(n.b, depth + 1));
        case HtKind.HT_FST:  return h.c_proj(true,  h.norm(n.a, depth + 1));
        case HtKind.HT_SND:  return h.c_proj(false, h.norm(n.a, depth + 1));
        case HtKind.HT_PRIM: return h.delta((int)n.key, h.norm(n.a, depth + 1), h.norm(n.b, depth + 1));
        case HtKind.HT_NEG:  return h.delta1((int)n.key, h.norm(n.a, depth + 1));
        case HtKind.HT_IF:
        {
            int c = h.norm(n.a, depth + 1);
            if (c >= 0 && h.terms[c].kind == HtKind.HT_BOOL) { h.n_ifsel = h.n_ifsel + 1; return h.norm(h.terms[c].val != 0 ? n.b : n.c, depth + 1); }
            return h.c_if(c, h.norm(n.b, depth + 1), h.norm(n.c, depth + 1));
        }
        case HtKind.HT_FIELD:  return h.field(h.norm(n.a, depth + 1), (uint)n.key);
        case HtKind.HT_SEQ:    return h.seq(h.norm(n.a, depth + 1), h.norm(n.b, depth + 1));
        case HtKind.HT_QUOTE:  return h.c_quote(h.norm(n.a, depth + 1));
        case HtKind.HT_SPLICE: return h.c_splice(h.norm(n.a, depth + 1));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Translation: Pride AST → terms
// ═══════════════════════════════════════════════════════════════════════════
fn Node* param_pattern(Node* prm)
{
    if (prm == null) return null;
    if (prm.kind == Nk.N_DECL_PARAM)
    {
        for (usz i = 0; i < prm.child_count; i++)
        {
            Node* c = prm.children[i];
            if (c != null && c.kind >= pfront_core::N_PAT_FIRST && pfront_core::is_pattern(c.kind)) return c;
        }
        return prm;
    }
    return prm;
}

// simple-type size from an annotation (the metric); 1 when unknown
fn long ty_size(Node* ty, int depth)
{
    if (ty == null || depth > 32) return 1;
    long s = 1;
    for (usz i = 0; i < ty.child_count; i++) { s = s + ty_size(ty.children[i], depth + 1); }
    return s;
}

fn void HeredState.env_push(HeredState* h, Node* b1, Node* b2)
{
    if (h.env_len >= HT_MAX_ENV) return;
    h.env[h.env_len].b1 = b1; h.env[h.env_len].b2 = b2;
    h.env_len = h.env_len + 1;
    h.n_binders = h.n_binders + 1;
}

fn void HeredState.env_pop(HeredState* h, usz n) { h.env_len = n <= h.env_len ? h.env_len - n : 0; }

// de Bruijn index of a binder, or −1 when free
fn int HeredState.env_index(HeredState* h, Node* binder)
{
    if (binder == null) return -1;
    for (usz i = h.env_len; i > 0; i--)
    {
        EnvEnt* e = &h.env[i - 1];
        if (e.b1 == binder || e.b2 == binder) return (int)(h.env_len - i);
    }
    return -1;
}

// a binder that is assigned to anywhere in `scope` (its value is not a term)
fn bool binder_written(Node* scope, Node* binder, int depth)
{
    if (scope == null || binder == null || depth > HT_MAX_DEPTH) return false;
    if (scope.kind == Nk.N_STMT_ASSIGN || scope.kind == Nk.N_STMT_COMPOUND_ASSIGN || scope.kind == Nk.N_EXPR_ASSIGN)
    {
        Node* lhs = scope.child_count > 0 ? scope.children[0] : null;
        while (lhs != null && (lhs.kind == Nk.N_EXPR_FIELD || lhs.kind == Nk.N_EXPR_INDEX || lhs.kind == Nk.N_EXPR_DEREF) && lhs.child_count > 0) { lhs = lhs.children[0]; }
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.resolved == binder) return true;
    }
    if (scope.kind == Nk.N_EXPR_REF && (scope.flags & pfront_core::NF_MUT) != 0)
    {
        Node* e = scope.child_count > 0 ? scope.children[0] : null;
        if (e != null && e.kind == Nk.N_EXPR_IDENT && e.resolved == binder) return true;
    }
    for (usz i = 0; i < scope.child_count; i++) { if (binder_written(scope.children[i], binder, depth + 1)) return true; }
    return false;
}

// bind the identifiers of a parameter pattern; returns how many were pushed.
// tuples of identifiers are one binder each (the argument is projected);
// anything else (literal / variant patterns) makes the unit opaque.
fn int HeredState.pattern_binders(HeredState* h, Node* pat, Node* prm, bool* simple)
{
    if (pat == null) { *simple = false; return 0; }
    switch (pat.kind)
    {
        case Nk.N_PAT_IDENT:    h.env_push(pat, prm); return 1;
        case Nk.N_PAT_WILDCARD: h.env_push(pat, prm); return 1;
        case Nk.N_PAT_TUPLE:
        {
            if (pat.child_count == 0) { h.env_push(pat, prm); return 1; }   // `()`
            int n = 0;
            for (usz i = 0; i < pat.child_count; i++)
            {
                Node* c = pat.children[i];
                if (c != null && (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_PAT_WILDCARD)) { h.env_push(c, null); n = n + 1; }
                else { *simple = false; h.env_push(c, null); n = n + 1; }
            }
            return n;
        }
        default: *simple = false; h.env_push(pat, prm); return 1;
    }
}

// a block: `let`s are β-redexes (λ.rest) init; statements before the tail
// are sequenced; the tail is the value
fn int HeredState.tr_block(HeredState* h, Node* b, usz from, int depth)
{
    if (b == null || depth > HT_MAX_DEPTH) return h.unit();
    if (from >= b.child_count) return h.unit();
    Node* s = b.children[from];
    bool last = from + 1 == b.child_count;
    if (s == null) return h.tr_block(b, from + 1, depth);
    if (s.kind == Nk.N_DECL_LET)
    {
        Node* pat = null; Node* init = null;
        for (usz i = 0; i < s.child_count; i++)
        {
            Node* c = s.children[i];
            if (c == null) continue;
            if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; }
            else if (pfront_core::is_expr(c.kind)) { init = c; }
        }
        bool mut = (s.flags & pfront_core::NF_MUT) != 0;
        if (pat == null || init == null || mut || pat.kind != Nk.N_PAT_IDENT || binder_written(b, pat, 0))
        {
            // not a value binding: opaque, and everything after it sees an opaque scope
            int o = h.opaque(s);
            if (last) return o;
            return h.seq(o, h.tr_block(b, from + 1, depth));
        }
        int v = h.tr(init, depth + 1);
        h.env_push(pat, s);
        int rest = h.tr_block(b, from + 1, depth);
        h.env_pop(1);
        h.n_let_redex = h.n_let_redex + 1;
        long m = ty_size(pat.type_ann, 0);
        return h.app(h.lam_raw(rest, m), v);
    }
    if (s.kind == Nk.N_STMT_EXPR)
    {
        Node* e = s.child_count > 0 ? s.children[0] : null;
        int v = e != null ? h.tr(e, depth + 1) : h.unit();
        if (last) return v;
        return h.seq(v, h.tr_block(b, from + 1, depth));
    }
    if (pfront_core::is_expr(s.kind))
    {
        int v = h.tr(s, depth + 1);
        if (last) return v;
        return h.seq(v, h.tr_block(b, from + 1, depth));
    }
    // return / break / continue / defer / assignment: control, not a term
    int o = h.opaque(s);
    if (last) return o;
    return h.seq(o, h.tr_block(b, from + 1, depth));
}

// a lambda / clause body with its parameters bound; returns the curried λ
fn int HeredState.tr_binder(HeredState* h, Node* params_owner, usz first, usz count, Node* body, bool* simple, int depth)
{
    if (count == 0)
    {
        if (first > 0) return h.tr(body, depth + 1);      // all parameters bound
        // nullary: λ_. body  (applied to unit at call sites)
        h.env_push(params_owner, null);
        int t = h.tr(body, depth + 1);
        h.env_pop(1);
        return h.lam_raw(t, 1);
    }
    Node* prm = params_owner.children[first];
    Node* pat = param_pattern(prm);
    usz before = h.env_len;
    int pushed = h.pattern_binders(pat, prm, simple);
    long m = ty_size(prm != null && prm.type_ann != null ? prm.type_ann : (pat != null ? pat.type_ann : null), 0);
    int inner = h.tr_binder(params_owner, first + 1, count - 1, body, simple, depth + 1);
    h.env_pop(h.env_len - before);
    if (pushed == 1) return h.lam_raw(inner, m);
    // a tuple parameter (a, b): λp. inner[a ↦ π₁ p, b ↦ π₂ p …] — bind the
    // components by substituting projections of the fresh variable
    int t = inner;
    // inner has `pushed` binders on top of the environment; replace them
    // innermost-first by projections of the tuple variable (index `pushed`
    // after shifting the tuple variable in)
    t = h.shift(t, 0, 1, 0);                    // make room for p at index 0 … actually p ends up outermost
    // after the shift, components are at 1..pushed and p is at 0.
    for (int i = 0; i < pushed; i++)
    {
        // component i (leftmost = highest index pushed-i) := proj_i (var 0)
        int comp = h.bvar(0);
        int target = pushed - i;                // current index of component i
        int sel = h.tuple_proj(comp, i, pushed);
        t = h.subst(t, target, sel, 1, 0);
        // after substituting index `target`, indices above it drop by one; p (index 0) stays
    }
    return h.lam_raw(t, m);
}

// i-th component of an n-tuple encoded as right-nested pairs
fn int HeredState.tuple_proj(HeredState* h, int p, int i, int n)
{
    int t = p;
    for (int k = 0; k < i; k++) { t = h.proj(false, t); }
    if (i + 1 < n) t = h.proj(true, t);
    return t;
}

fn int HeredState.tr_tuple(HeredState* h, Node* n, usz from, int depth)
{
    if (from >= n.child_count) return h.unit();
    int a = h.tr(n.children[from], depth + 1);
    if (from + 1 == n.child_count) return a;
    return h.pair(a, h.tr_tuple(n, from + 1, depth));
}

// a lambda: either N_DECL_PARAM… + body, or a single N_CLAUSE
fn int HeredState.tr_lambda(HeredState* h, Node* lam, bool* simple, int* nparams, int depth)
{
    usz np = 0; Node* body = null; Node* clause = null; usz nclauses = 0;
    for (usz i = 0; i < lam.child_count; i++)
    {
        Node* c = lam.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_DECL_PARAM) { np = np + 1; }
        else if (c.kind == Nk.N_CLAUSE) { clause = c; nclauses = nclauses + 1; }
        else { body = c; }
    }
    if (nclauses > 1) { *simple = false; return h.opaque(lam); }
    if (clause != null)
    {
        Node* pat = null; Node* cb = null;
        for (usz i = 0; i < clause.child_count; i++)
        {
            Node* c = clause.children[i];
            if (c == null) continue;
            if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; } else { cb = c; }
        }
        if (pat == null || cb == null) { *simple = false; return h.opaque(lam); }
        *nparams = 1;
        return h.tr_binder(clause, 0, 1, cb, simple, depth);
    }
    if (body == null) { *simple = false; return h.opaque(lam); }
    *nparams = (int)np;
    return h.tr_binder(lam, 0, np, body, simple, depth);
}

fn int HeredState.tr_call(HeredState* h, Node* n, int depth)
{
    // callee
    int f;
    usz first_arg;
    if (n.kind == Nk.N_EXPR_METHOD)
    {
        Node* recv = n.child_count > 0 ? n.children[0] : null;
        Node* rb = recv != null ? recv.resolved : null;
        bool recv_is_path = recv != null && (recv.kind == Nk.N_EXPR_IDENT || recv.kind == Nk.N_EXPR_PATH)
            && (rb == null || !(rb.kind == Nk.N_PAT_IDENT || rb.kind == Nk.N_DECL_PARAM || rb.kind == Nk.N_DECL_LET));
        // the method itself is a free name; a value receiver is its first argument
        f = h.mk(HtKind.HT_FREE, -1, -1, -1, (long)n.name_id, 0x6d000000 + (ulong)n.name_id, n);
        h.n_free = h.n_free + 1;
        if (recv_is_path) { first_arg = 1; }
        else { first_arg = 1; f = h.app(f, h.tr(recv, depth + 1)); }
    }
    else
    {
        Node* callee = n.child_count > 0 ? n.children[0] : null;
        if (callee != null && callee.kind == Nk.N_EXPR_LAMBDA) { h.n_src_redex = h.n_src_redex + 1; }
        f = callee != null ? h.tr(callee, depth + 1) : h.unit();
        first_arg = 1;
    }
    if (n.child_count <= first_arg) return h.app(f, h.unit());    // nullary call: apply to ()
    int t = f;
    for (usz i = first_arg; i < n.child_count; i++) { t = h.app(t, h.tr(n.children[i], depth + 1)); }
    return t;
}

fn int HeredState.tr(HeredState* h, Node* n, int depth)
{
    if (n == null) return h.unit();
    if (depth > HT_MAX_DEPTH) { h.stuck = true; return h.opaque(n); }
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:   return h.lit_int((long)n.p.ival);
        case Nk.N_EXPR_BOOL:  return h.lit_bool(n.p.ival != 0);
        case Nk.N_EXPR_UNIT:  return h.unit();
        case Nk.N_EXPR_IDENT:
        {
            int ix = h.env_index(n.resolved);
            if (ix >= 0) return h.bvar(ix);
            h.n_free = h.n_free + 1;
            return h.free_name(n.resolved, n);
        }
        case Nk.N_EXPR_PATH:
        {
            h.n_free = h.n_free + 1;
            return h.free_name(n.resolved, n);
        }
        case Nk.N_EXPR_LAMBDA:
        {
            bool simple = true; int np = 0;
            int t = h.tr_lambda(n, &simple, &np, depth);
            h.add_unit(n, UnitKind.UK_LAMBDA, t, np, simple);
            return t;
        }
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
            return h.tr_call(n, depth);
        case Nk.N_EXPR_BINARY:
        {
            if (n.p.op == (int)Tk.TOKEN_PIPELINE)
            {
                // x |> f  ≡  f x  (the fixpoint form `|>*` is not a plain application)
                if (n.p.aux != 0) return h.opaque(n);
                if (n.child_count >= 2) return h.app(h.tr(n.children[1], depth + 1), h.tr(n.children[0], depth + 1));
            }
            if (n.child_count < 2) return h.opaque(n);
            return h.prim(n.p.op, h.tr(n.children[0], depth + 1), h.tr(n.children[1], depth + 1));
        }
        case Nk.N_EXPR_UNARY:
            if (n.child_count < 1) return h.opaque(n);
            return h.neg(n.p.op, h.tr(n.children[0], depth + 1));
        case Nk.N_EXPR_IF:
        {
            if (n.child_count < 2) return h.opaque(n);
            int c = h.tr(n.children[0], depth + 1);
            int t = h.tr(n.children[1], depth + 1);
            int e = n.child_count >= 3 ? h.tr(n.children[2], depth + 1) : h.unit();
            return h.ite(c, t, e);
        }
        case Nk.N_EXPR_TUPLE:
            if (n.child_count == 0) return h.unit();
            return h.tr_tuple(n, 0, depth);
        case Nk.N_EXPR_FIELD:
        {
            if (n.child_count < 1) return h.opaque(n);
            int r = h.tr(n.children[0], depth + 1);
            // numeric field on a tuple: .0 / .1 are projections
            if (n.p.sptr != null && n.p.slen == 1 && n.p.sptr[0] == '0') return h.proj(true, r);
            if (n.p.sptr != null && n.p.slen == 1 && n.p.sptr[0] == '1') return h.proj(true, h.proj(false, r));
            return h.field(r, n.name_id);
        }
        case Nk.N_BLOCK:
            return h.tr_block(n, 0, depth);
        case Nk.N_EXPR_CAST:
            // a cast changes representation, not the term; keep it as a
            // field-like wrapper keyed on the target type text so `x as i64`
            // and `x as u8` stay distinct
            if (n.child_count < 1) return h.opaque(n);
            return h.mk(HtKind.HT_FIELD, h.tr(n.children[0], depth + 1), -1, -1, 1, 0xca570000 + (ulong)(n.type_ann != null ? n.type_ann.name_id : 0), null);
        case Nk.N_EXPR_QUOTE:
        {
            if (n.child_count < 1) return h.opaque(n);
            h.n_quotes = h.n_quotes + 1;
            int saved_base = h.quote_base;
            usz metas_before = h.n_metas;
            h.level = h.level + 1;
            h.quote_base = (int)h.env_len;
            int a = h.tr(n.children[0], depth + 1);
            h.level = h.level - 1;
            h.quote_base = saved_base;
            if (h.n_metas > metas_before) { h.n_open_quotes = h.n_open_quotes + 1; }
            if (n.children[0] != null && n.children[0].kind == Nk.N_EXPR_SPLICE) { h.note_staging(n, "`quote (splice q)` is `q`"); }
            return h.quote(a);
        }
        case Nk.N_EXPR_SPLICE:
        {
            if (n.child_count < 1) return h.opaque(n);
            h.n_splices = h.n_splices + 1;
            Node* e = n.children[0];
            if (h.level > 0)
            {
                // a meta-variable u::A[Ψ] when it refers to a stage-0 binder
                Node* b = e != null && e.kind == Nk.N_EXPR_IDENT ? e.resolved : null;
                int ix = h.env_index(b);
                bool stage0 = b != null && ix >= (int)h.env_len - h.quote_base;   // bound outside the quote
                if (h.n_metas < HT_MAX_METAS)
                {
                    h.metas[h.n_metas].splice = n;
                    h.metas[h.n_metas].binder = stage0 ? b : null;
                    h.metas[h.n_metas].psi = (int)h.env_len - h.quote_base;
                    h.metas[h.n_metas].level = h.level;
                    h.n_metas = h.n_metas + 1;
                }
            }
            if (e != null && e.kind == Nk.N_EXPR_QUOTE) { h.note_staging(n, "`splice (quote e)` is `e`"); }
            return h.splice(h.tr(e, depth + 1));
        }
        case Nk.N_EXPR_ASSERT: case Nk.N_EXPR_ASSUME:
            // a check with no value: its argument is a term, the check an effect
            if (n.child_count < 1) return h.opaque(n);
            return h.seq(h.opaque(n), h.tr(n.children[0], depth + 1));
        default:
            // loops, match, assignment, effects, refs, unsafe, allocation,
            // struct literals, indexing, ranges, … : one opaque leaf each
            return h.opaque(n);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Units and judgements
// ═══════════════════════════════════════════════════════════════════════════
fn void HeredState.add_unit(HeredState* h, Node* node, UnitKind k, int term, int nparams, bool simple)
{
    if (h.n_units >= HT_MAX_UNITS) return;
    Unit* u = &h.units[h.n_units];
    h.n_units = h.n_units + 1;
    u.node = node; u.kind = k; u.term = term; u.nf = -1; u.nparams = nparams;
    u.judged = false; u.reported = false; u.fn_decl = h.cur_fn;
    u.closed = -1;
    u.snap = h.n_snaps; u.snap_len = 0;
    for (usz i = 0; i < h.env_len && h.n_snaps < HT_MAX_UNITS * 16; i++)
    {
        h.snaps[h.n_snaps] = h.env[i].b1 != null ? h.env[i].b1 : h.env[i].b2;
        h.n_snaps = h.n_snaps + 1; u.snap_len = u.snap_len + 1;
    }
    if (k == UnitKind.UK_FN) { h.n_fn_units = h.n_fn_units + 1; } else { h.n_lam_units = h.n_lam_units + 1; }
    (void)simple;
}

// a top-level fn: single clause with a simple pattern
fn void HeredState.tr_fn(HeredState* h, Node* fnd)
{
    Node* clause = null; usz nclauses = 0; Node* sig = fnd.type_ann;
    for (usz i = 0; i < fnd.child_count; i++)
    {
        Node* c = fnd.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_CLAUSE) { clause = c; nclauses = nclauses + 1; }
        else if (c.kind == Nk.N_TY_FN && sig == null) { sig = c; }
    }
    if (clause == null) return;
    Node* pat = null; Node* body = null;
    for (usz i = 0; i < clause.child_count; i++)
    {
        Node* c = clause.children[i];
        if (c == null) continue;
        if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; } else { body = c; }
    }
    if (pat == null || body == null) return;
    h.cur_fn = fnd;
    h.env_len = 0;
    h.level = 0; h.quote_base = 0;
    bool simple = nclauses == 1;
    int t;
    if (nclauses > 1) { t = h.opaque(fnd); }
    else { t = h.tr_binder(clause, 0, 1, body, &simple, 0); }
    h.add_unit(fnd, UnitKind.UK_FN, t, 1, simple);
    h.cur_fn = null;
}

// replace the free de Bruijn indices of a unit's canonical form by the
// binders they denote at its definition site, so two closures are compared
// as terms over the SAME names whatever their nesting depth
fn int HeredState.close_over(HeredState* h, int t, Unit* u, int d, int depth)
{
    if (t < 0 || depth > HT_MAX_DEPTH) return t;
    HtTerm* n = &h.terms[t];
    if (n.mfree <= d) return t;
    switch (n.kind)
    {
        case HtKind.HT_VAR:
        {
            int j = (int)n.val - d;                       // j-th binder outward from the unit
            if (j < 0 || (usz)j >= u.snap_len) return t;
            Node* b = h.snaps[u.snap + u.snap_len - 1 - (usz)j];
            if (b == null) return t;
            return h.mk(HtKind.HT_FREE, -1, -1, -1, (long)b.name_id, (ulong)(uptr)b, b);
        }
        case HtKind.HT_LAM: return h.lam_raw(h.close_over(n.a, u, d + 1, depth + 1), n.val);
        default:
            return h.mk(n.kind, h.close_over(n.a, u, d, depth + 1), h.close_over(n.b, u, d, depth + 1), h.close_over(n.c, u, d, depth + 1), n.val, n.key, n.at);
    }
}

// canonicalise every unit
fn void HeredState.normalise_units(HeredState* h)
{
    for (usz i = 0; i < h.n_units; i++)
    {
        Unit* u = &h.units[i];
        h.fuel = HT_FUEL; h.stuck = false;
        u.nf = h.norm(u.term, 0);
        u.judged = !h.stuck && u.nf >= 0 && !h.terms[u.nf].opaque;
        u.closed = u.judged ? h.close_over(u.nf, u, 0, 0) : -1;
        if (u.judged) h.n_judged = h.n_judged + 1;
    }
}

// the source spelling of the head of an η-wrapper's body
fn Node* HeredState.eta_head(HeredState* h, int nf)
{
    if (nf < 0) return null;
    int cur = nf;
    if (h.terms[cur].kind == HtKind.HT_LAM) cur = h.terms[cur].a;
    while (cur >= 0 && h.terms[cur].kind == HtKind.HT_APP) cur = h.terms[cur].a;
    return cur >= 0 && h.terms[cur].kind == HtKind.HT_FREE ? h.terms[cur].at : null;
}

// the fn a canonical form is an η-expansion of: F itself, λp. F(π₁p)(π₂p)…,
// or (after η-contraction) any FREE head applied to exactly the parameter's
// components in order
fn Node* HeredState.eta_target(HeredState* h, int nf)
{
    if (nf < 0) return null;
    HtTerm* t = &h.terms[nf];
    if (t.kind == HtKind.HT_FREE) return free_decl(t);
    if (t.kind != HtKind.HT_LAM) return null;
    // spine of the body
    int cur = t.a;
    int[16] args; usz n = 0;
    while (cur >= 0 && h.terms[cur].kind == HtKind.HT_APP && n < 16) { args[n] = h.terms[cur].b; n = n + 1; cur = h.terms[cur].a; }
    if (cur < 0 || h.terms[cur].kind != HtKind.HT_FREE || n < 2) return null;
    if (h.occurs(cur, 0, 0)) return null;
    // args are collected innermost-last: args[n-1] is the first argument
    for (usz i = 0; i < n; i++)
    {
        int want = h.tuple_proj(h.bvar(0), (int)i, (int)n);
        if (args[n - 1 - i] != want) return null;
    }
    return free_decl(&h.terms[cur]);
}

// ── printing canonical forms ─────────────────────────────────────────────
fn char* HeredState.ident_text(HeredState* h, Node* at, long name_id)
{
    if (at != null && at.kind == Nk.N_EXPR_METHOD && at.p.sptr != null && at.p.slen < 100 && at.child_count > 0
        && at.children[0] != null && at.children[0].kind == Nk.N_EXPR_IDENT && at.children[0].p.sptr != null && at.children[0].p.slen < 100)
    {
        // `mod.f` — keep the qualification so `f` and `mod.f` read differently
        Node* r = at.children[0];
        char* s = (char*)h.arena.alloc(r.p.slen + at.p.slen + 2, 1);
        usz k = 0;
        for (usz i = 0; i < r.p.slen; i++) { s[k] = r.p.sptr[i]; k = k + 1; }
        s[k] = '.'; k = k + 1;
        for (usz i = 0; i < at.p.slen; i++) { s[k] = at.p.sptr[i]; k = k + 1; }
        s[k] = 0;
        return s;
    }
    if (at != null && at.p.sptr != null && at.p.slen > 0 && at.p.slen < 200)
    {
        char* s = (char*)h.arena.alloc(at.p.slen + 1, 1);
        for (usz i = 0; i < at.p.slen; i++) { s[i] = at.p.sptr[i]; }
        s[at.p.slen] = 0;
        return s;
    }
    if (h.interner != null) { char* t = h.interner.text((uint)name_id); if (t != null) return t; }
    return "?";
}

fn int put(char* buf, int off, int cap, char* s)
{
    if (s == null) { s = "?"; }
    while (*s != 0 && off + 1 < cap) { buf[off] = *s; off = off + 1; s = s + 1; }
    if (off < cap) buf[off] = 0;
    return off;
}

fn char* op_text(int op)
{
    char* s = pfront_lex::token_type_name((Tk)op);
    return s == null ? "?" : s;
}

fn int HeredState.show(HeredState* h, int t, char* buf, int off, int cap, int binders, int depth)
{
    if (off + 8 >= cap) return off;
    if (t < 0) return put(buf, off, cap, "?");
    if (depth > 24) return put(buf, off, cap, "…");
    HtTerm* n = &h.terms[t];
    char[48] tmp;
    switch (n.kind)
    {
        case HtKind.HT_VAR:
        {
            int k = binders - 1 - (int)n.val;
            if (k >= 0) { snprintf(&tmp[0], 48, "x%d", k); } else { snprintf(&tmp[0], 48, "#%d", (int)n.val); }
            return put(buf, off, cap, &tmp[0]);
        }
        case HtKind.HT_FREE:   return put(buf, off, cap, h.ident_text(n.at, n.val));
        case HtKind.HT_UNIT:   return put(buf, off, cap, "()");
        case HtKind.HT_INT:    snprintf(&tmp[0], 48, "%lld", n.val); return put(buf, off, cap, &tmp[0]);
        case HtKind.HT_BOOL:   return put(buf, off, cap, n.val != 0 ? "true" : "false");
        case HtKind.HT_LAM:
        {
            snprintf(&tmp[0], 48, "λx%d. ", binders);
            off = put(buf, off, cap, &tmp[0]);
            return h.show(n.a, buf, off, cap, binders + 1, depth + 1);
        }
        case HtKind.HT_APP:
        {
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, "(");
            off = h.show(n.b, buf, off, cap, binders, depth + 1);
            return put(buf, off, cap, ")");
        }
        case HtKind.HT_PAIR:
        {
            off = put(buf, off, cap, "(");
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, ", ");
            off = h.show(n.b, buf, off, cap, binders, depth + 1);
            return put(buf, off, cap, ")");
        }
        case HtKind.HT_FST: off = put(buf, off, cap, "π₁ "); return h.show(n.a, buf, off, cap, binders, depth + 1);
        case HtKind.HT_SND: off = put(buf, off, cap, "π₂ "); return h.show(n.a, buf, off, cap, binders, depth + 1);
        case HtKind.HT_PRIM:
        {
            off = put(buf, off, cap, "(");
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, " "); off = put(buf, off, cap, op_text((int)n.key)); off = put(buf, off, cap, " ");
            off = h.show(n.b, buf, off, cap, binders, depth + 1);
            return put(buf, off, cap, ")");
        }
        case HtKind.HT_NEG:
            off = put(buf, off, cap, op_text((int)n.key));
            return h.show(n.a, buf, off, cap, binders, depth + 1);
        case HtKind.HT_IF:
        {
            off = put(buf, off, cap, "if ");
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, " then ");
            off = h.show(n.b, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, " else ");
            return h.show(n.c, buf, off, cap, binders, depth + 1);
        }
        case HtKind.HT_FIELD:
        {
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            if (n.val == 1) return put(buf, off, cap, " as …");
            off = put(buf, off, cap, ".");
            return put(buf, off, cap, h.interner != null ? h.interner.text((uint)n.key) : "field");
        }
        case HtKind.HT_SEQ:
        {
            off = h.show(n.a, buf, off, cap, binders, depth + 1);
            off = put(buf, off, cap, "; ");
            return h.show(n.b, buf, off, cap, binders, depth + 1);
        }
        case HtKind.HT_QUOTE:  off = put(buf, off, cap, "⌜"); off = h.show(n.a, buf, off, cap, binders, depth + 1); return put(buf, off, cap, "⌝");
        case HtKind.HT_SPLICE: off = put(buf, off, cap, "~"); return h.show(n.a, buf, off, cap, binders, depth + 1);
        case HtKind.HT_OPAQUE: return put(buf, off, cap, n.at != null ? pfront_core::kind_name(n.at.kind) : "opaque");
    }
}

fn char* HeredState.unit_name(HeredState* h, Unit* u)
{
    if (u.kind == UnitKind.UK_FN && u.node.p.sptr != null) return h.ident_text(u.node, u.node.name_id);
    char* s = (char*)h.arena.alloc(96, 1);
    if (u.fn_decl != null && u.fn_decl.p.sptr != null) { snprintf(s, 96, "closure at %d:%d in `%s`", u.node.line, u.node.col, h.ident_text(u.fn_decl, u.fn_decl.name_id)); }
    else { snprintf(s, 96, "closure at %d:%d", u.node.line, u.node.col); }
    return s;
}

fn void HeredState.note_staging(HeredState* h, Node* at, char* what)
{
    h.n_n4273 = h.n_n4273 + 1;
    if (h.diags == null || !h.diags.advisories) return;
    char* m = (char*)h.arena.alloc(256, 1);
    snprintf(m, 256, "staging redex: %s — the quotation and the splice cancel", what);
    h.diags.note(pfront_core::Phase.PH_RESOLVE, 4273, at.line, at.col, m, h.file);
}

// resolve a FREE canonical form to the fn decl it names (for η-wrappers)
fn Node* free_decl(HtTerm* t)
{
    if (t.kind != HtKind.HT_FREE || t.at == null) return null;
    Node* r = t.at.resolved;
    if (r != null && r.kind == Nk.N_DECL_FN) return r;
    return null;
}

fn void HeredState.judge(HeredState* h)
{
    bool lint = h.diags != null && h.diags.advisories;
    // η-wrappers: a fn whose canonical form is another fn
    for (usz i = 0; i < h.n_units; i++)
    {
        Unit* u = &h.units[i];
        if (!u.judged || u.kind != UnitKind.UK_FN || u.nf < 0) continue;
        Node* g = h.eta_target(u.nf);
        if (g != null && g != u.node)
        {
            h.n_eta_wrap = h.n_eta_wrap + 1;
            if (lint)
            {
                Node* head = h.eta_head(u.nf);
                char* gname = head != null ? h.ident_text(head, g.name_id) : h.ident_text(g, g.name_id);
                char* m = (char*)h.arena.alloc(256, 1);
                snprintf(m, 256, "`%s` is an η-expansion of `%s`: every call to it is a call to `%s` with the same arguments", h.unit_name(u), gname, gname);
                h.diags.note(pfront_core::Phase.PH_RESOLVE, 4271, u.node.line, u.node.col, m, h.file);
            }
        }
    }
    // βη-equivalent units: same canonical index
    for (usz i = 0; i < h.n_units; i++)
    {
        Unit* u = &h.units[i];
        if (!u.judged || u.closed < 0 || u.reported) continue;
        if (h.terms[u.closed].size < HT_MIN_REPORT) continue;
        if (h.eta_target(u.nf) != null) continue;                     // η-wrappers handled above
        for (usz j = i + 1; j < h.n_units; j++)
        {
            Unit* v = &h.units[j];
            if (!v.judged || v.closed != u.closed || v.reported) continue;
            // a lambda inside the fn it equals is the same code, not a duplicate
            if (v.kind == UnitKind.UK_LAMBDA && v.fn_decl == u.node) continue;
            if (u.kind == UnitKind.UK_LAMBDA && u.fn_decl == v.node) continue;
            v.reported = true;
            h.n_equiv = h.n_equiv + 1;
            if (lint)
            {
                char* buf = (char*)h.arena.alloc(200, 1);
                int off = h.show(u.closed, buf, 0, 200, 0, 0);
                (void)off;
                char* m = (char*)h.arena.alloc(512, 1);
                snprintf(m, 512, "%s is βη-equivalent to %s (%d:%d): both normalise to %s", h.unit_name(v), h.unit_name(u), u.node.line, u.node.col, buf);
                h.diags.note(pfront_core::Phase.PH_RESOLVE, 4270, v.node.line, v.node.col, m, h.file);
            }
        }
    }
    // β-redexes written in the source
    if (lint)
    {
        for (usz i = 0; i < h.n_units; i++)
        {
            Unit* u = &h.units[i];
            if (u.kind != UnitKind.UK_LAMBDA || !u.judged) continue;
            Node* p = u.node.parent;
            if (p == null || p.kind != Nk.N_EXPR_CALL || p.child_count == 0 || p.children[0] != u.node) continue;
            // rebuild the application on canonical parts and show what it becomes
            int t = u.nf;
            h.fuel = HT_FUEL; h.stuck = false;
            usz saved = h.env_len; h.env_len = 0;
            bool ok = true;
            for (usz k = 1; k < p.child_count; k++)
            {
                int a = h.norm(h.tr(p.children[k], 0), 0);
                if (a < 0 || h.terms[a].opaque) { ok = false; break; }
                t = h.c_app(t, a, 1, 0);
            }
            if (p.child_count == 1) { t = h.c_app(t, h.unit(), 1, 0); }
            h.env_len = saved;
            if (!ok || h.stuck || t < 0) continue;
            h.n_n4272 = h.n_n4272 + 1;
            char* buf = (char*)h.arena.alloc(200, 1);
            int off = h.show(t, buf, 0, 200, 0, 0);
            (void)off;
            char* m = (char*)h.arena.alloc(400, 1);
            snprintf(m, 400, "β-redex in the source: this immediately-applied closure reduces to %s", buf);
            h.diags.note(pfront_core::Phase.PH_RESOLVE, 4272, p.line, p.col, m, h.file);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Driver
// ═══════════════════════════════════════════════════════════════════════════
fn void HeredState.collect(HeredState* h, Node* n, int depth)
{
    if (n == null || depth > 64) return;
    if (n.kind == Nk.N_DECL_FN) { h.tr_fn(n); return; }
    for (usz i = 0; i < n.child_count; i++) { h.collect(n.children[i], depth + 1); }
}

fn void HeredState.walk_ast(HeredState* h, Node* root, int depth)
{
    (void)depth;
    if (root == null) return;
    h.collect(root, 0);
    h.normalise_units();
    h.judge();
}

// exported for theory_cmtt_meta: the contextual meta-variables found
fn usz HeredState.meta_count(HeredState* h) { return h.n_metas; }
fn usz HeredState.meta_open_count(HeredState* h)
{
    usz n = 0;
    for (usz i = 0; i < h.n_metas; i++) { if (h.metas[i].binder != null) n = n + 1; }
    return n;
}
fn usz HeredState.meta_max_psi(HeredState* h)
{
    usz m = 0;
    for (usz i = 0; i < h.n_metas; i++) { if ((usz)h.metas[i].psi > m) m = (usz)h.metas[i].psi; }
    return m;
}

fn void HeredState.report(HeredState* h)
{
    printf("  hered-terms      : %d units (%d fns, %d closures), %d judged; %d terms hash-consed (%d hits), %d binders, %d free names, %d opaque leaves\n",
           (int)h.n_units, (int)h.n_fn_units, (int)h.n_lam_units, (int)h.n_judged,
           (int)h.count, (int)h.n_hits, (int)h.n_binders, (int)h.n_free, (int)h.n_opaque);
    printf("  hered-subst      : %d subst, %d shift, %d β (%d source redexes, %d lets), %d δ, %d π, %d if, %d η, %d modal; metric ≤ %d, %d fuel cuts\n",
           (int)h.n_subst, (int)h.n_shift, (int)h.n_beta, (int)h.n_src_redex, (int)h.n_let_redex,
           (int)h.n_delta, (int)h.n_proj, (int)h.n_ifsel, (int)h.n_eta, (int)h.n_modal,
           (int)h.metric_max, (int)h.n_fuel_cuts);
    printf("  hered-judge      : %d βη-equivalent pairs (N4270), %d η-wrappers (N4271), %d source redexes shown (N4272), %d staging redexes (N4273)\n",
           (int)h.n_equiv, (int)h.n_eta_wrap, (int)h.n_n4272, (int)h.n_n4273);
    printf("  hered-meta       : %d quotes (%d open), %d splices, %d meta-variables (%d over a stage-0 binder, |Ψ| ≤ %d)\n",
           (int)h.n_quotes, (int)h.n_open_quotes, (int)h.n_splices, (int)h.n_metas, (int)h.meta_open_count(), (int)h.meta_max_psi());
}
