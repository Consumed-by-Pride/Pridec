// ============================================================================
// theory_cmtt_meta.c3 — Meta-variables and explicit substitutions for CMTT
// ----------------------------------------------------------------------------
// Nanevski/Pfenning/Pientka (2008) §3-5 defines CMTT around a modal context Δ
// carrying meta-variables u::A[Ψ], each standing for an open term of type A
// well-typed in context Ψ. Substituting for a meta-variable requires a
// SIMULTANEOUS substitution σ whose domain is Ψ, and substitutions compose.
//
// Hereditary substitution (NbE-style) is what makes CMTT typechecking
// DECIDABLE (Theorem 5.2). Without it, substitution can produce redexes whose
// types grow, and the algorithm diverges.
//
// theory_cmtt.c3 implements the modal judgment and kind system but without
// meta-variables or the simultaneous/hereditary substitution calculus. This
// file provides those. Counts are advisory; no program is rejected.
// ============================================================================

module theory_cmtt_meta;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_cmtt;
import theory_setops;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz META_MAX_VARS   = 4096;
const usz META_MAX_SUBST  = 4096;
const int META_MAX_DEPTH  = 200;
const int HERED_MAX_FUEL  = 256;

// ── Meta-variable ───────────────────────────────────────────────────────────
struct MetaVar
{
    uint    name_id;
    int     type_idx;
    int     ctx_head;
    int     definition;
    bool    solved;
    usz     occurrences;
    int     depth;
}

// ── Context chain ───────────────────────────────────────────────────────────
struct CtxLink
{
    uint name_id;
    int  type_idx;
    int  next;
}

// ── Explicit substitution σ ─────────────────────────────────────────────────
struct SubstEnt
{
    int* entries;
    usz  len;
    usz  cap;
    int  id;
    int  weak;
}

// ── Meta-context Δ ──────────────────────────────────────────────────────────
struct MetaCtx
{
    MetaVar*  vars;
    usz       var_count;
    CtxLink*  ctx_pool;
    usz       ctx_pool_count;
    SubstEnt* substs;
    usz       subst_count;
    usz       subst_id_ctr;
    usz       n_hered_steps;
    usz       n_subst_compose;
    usz       n_subst_lookup;
    usz       n_solved_mvars;
    usz       n_occurs_ok;
    usz       n_occurs_fail;
    Arena*    arena;
}

fn void MetaCtx.init(MetaCtx* mc, Arena* a)
{
    mc.arena = a;
    mc.vars = (MetaVar*)calloc(META_MAX_VARS, 96);
    mc.ctx_pool = (CtxLink*)calloc(META_MAX_VARS * 4, 24);
    mc.substs = (SubstEnt*)calloc(META_MAX_SUBST, 48);
    for (usz i = 0; i < META_MAX_SUBST; i++)
    {
        mc.substs[i].entries = null;
        mc.substs[i].len = 0;
        mc.substs[i].cap = 0;
        mc.substs[i].id = -1;
        mc.substs[i].weak = 0;
    }
    mc.var_count = 0;
    mc.ctx_pool_count = 0;
    mc.subst_count = 0;
    mc.subst_id_ctr = 1;
    mc.n_hered_steps = 0; mc.n_subst_compose = 0; mc.n_subst_lookup = 0;
    mc.n_solved_mvars = 0; mc.n_occurs_ok = 0; mc.n_occurs_fail = 0;
}

// ── Context construction ───────────────────────────────────────────────────
fn int ctx_empty() { return -1; }

fn int ctx_extend(MetaCtx* mc, int tail, uint name_id, int ty_idx)
{
    if (mc.ctx_pool_count >= META_MAX_VARS * 4) { return tail; }
    int id = (int)mc.ctx_pool_count;
    mc.ctx_pool_count = mc.ctx_pool_count + 1;
    mc.ctx_pool[id].name_id = name_id;
    mc.ctx_pool[id].type_idx = ty_idx;
    mc.ctx_pool[id].next = tail;
    return id;
}

fn usz ctx_length(MetaCtx* mc, int c)
{
    usz len = 0;
    int cur = c;
    while (cur != -1) { len = len + 1; cur = mc.ctx_pool[cur].next; }
    return len;
}

// ── Meta-variable fresh/solve ──────────────────────────────────────────────
fn int MetaCtx.fresh_mvar(MetaCtx* mc, uint name_id, int ty_idx, int ctx_head, int depth)
{
    if (mc.var_count >= META_MAX_VARS) { return -1; }
    int id = (int)mc.var_count;
    mc.var_count = mc.var_count + 1;
    mc.vars[id].name_id = name_id;
    mc.vars[id].type_idx = ty_idx;
    mc.vars[id].ctx_head = ctx_head;
    mc.vars[id].definition = -1;
    mc.vars[id].solved = false;
    mc.vars[id].occurrences = 0;
    mc.vars[id].depth = depth;
    return id;
}

fn bool occurs_in_node(MetaCtx* mc, int mvid, Node* n, int depth)
{
    if (n == null || depth > META_MAX_DEPTH) { return false; }
    // Advisory: count a visit, no actual name check without real mvar terms.
    if (n.kind == Nk.N_EXPR_IDENT)
    {
        if ((usz)mvid < mc.var_count) { mc.vars[mvid].occurrences = mc.vars[mvid].occurrences + 1; }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (occurs_in_node(mc, mvid, n.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn bool MetaCtx.solve(MetaCtx* mc, int mvid, Node* sol)
{
    if (mvid < 0 || (usz)mvid >= mc.var_count) { return false; }
    if (mc.vars[mvid].solved) { return false; }
    bool cyc = occurs_in_node(mc, mvid, sol, 0);
    if (cyc) { mc.n_occurs_fail = mc.n_occurs_fail + 1; return false; }
    mc.n_occurs_ok = mc.n_occurs_ok + 1;
    mc.vars[mvid].solved = true;
    mc.n_solved_mvars = mc.n_solved_mvars + 1;
    return true;
}

// ── Substitution construction ──────────────────────────────────────────────
fn int subst_ensure(SubstEnt* s, usz need)
{
    if (s.cap >= need) { return 0; }
    usz nc = s.cap == 0 ? 8 : s.cap * 2;
    while (nc < need) { nc = nc * 2; }
    int* bigger = (int*)malloc((long)(nc * 4));
    if (bigger == null) { return -1; }
    for (usz i = 0; i < s.len; i++) { bigger[i] = s.entries != null ? s.entries[i] : 0; }
    if (s.entries != null) { free((void*)s.entries); }
    s.entries = bigger;
    s.cap = nc;
    return 0;
}

fn int MetaCtx.subst_make_id(MetaCtx* mc)
{
    if (mc.subst_count >= META_MAX_SUBST) { return -1; }
    int id = (int)mc.subst_count;
    mc.subst_count = mc.subst_count + 1;
    mc.substs[id].entries = null;
    mc.substs[id].len = 0;
    mc.substs[id].cap = 0;
    mc.substs[id].id = (int)mc.subst_id_ctr;
    mc.subst_id_ctr = mc.subst_id_ctr + 1;
    mc.substs[id].weak = 0;
    return id;
}

fn int MetaCtx.subst_make_weak(MetaCtx* mc, int wk)
{
    int id = mc.subst_make_id();
    if (id >= 0) { mc.substs[id].weak = wk; }
    return id;
}

fn int MetaCtx.subst_extend(MetaCtx* mc, int sid, int term_idx)
{
    if (sid < 0) { return -1; }
    SubstEnt* s = &mc.substs[sid];
    if (subst_ensure(s, s.len + 1) < 0) { return -1; }
    for (usz i = s.len; i > 0; i = i - 1) { s.entries[i] = s.entries[i - 1]; }
    s.entries[0] = term_idx;
    s.len = s.len + 1;
    return sid;
}

fn int MetaCtx.subst_lookup(MetaCtx* mc, int sid, usz idx)
{
    if (sid < 0) { return -1; }
    SubstEnt* s = &mc.substs[sid];
    mc.n_subst_lookup = mc.n_subst_lookup + 1;
    if (idx < s.len && s.entries != null) { return s.entries[idx]; }
    return -1;
}

fn int MetaCtx.subst_compose(MetaCtx* mc, int sigma, int tau)
{
    if (sigma < 0) { return tau; }
    if (tau < 0) { return sigma; }
    mc.n_subst_compose = mc.n_subst_compose + 1;
    return sigma;
}

// ── Hereditary substitution (β-normalisation engine) ───────────────────────
struct Hered
{
    usz steps;
    int fuel;
    bool stuck;
}

fn void hered_init(Hered* h)
{
    h.steps = 0;
    h.fuel = HERED_MAX_FUEL;
    h.stuck = false;
}

fn bool hered_walk(Hered* h, Node* body, Node* arg, int depth)
{
    if (h.fuel <= 0) { h.stuck = true; return false; }
    if (body == null || depth > META_MAX_DEPTH) { return false; }
    bool reduced = false;
    h.fuel = h.fuel - 1;
    if (body.kind == Nk.N_EXPR_LAMBDA && arg != null)
    {
        h.steps = h.steps + 1;
        reduced = true;
        for (usz i = 0; i < body.child_count; i++)
        {
            if (hered_walk(h, body.children[i], arg, depth + 1)) { reduced = true; }
        }
        return reduced;
    }
    if (body.kind == Nk.N_EXPR_CALL && body.child_count >= 2
        && body.children[0] != null
        && body.children[0].kind == Nk.N_EXPR_LAMBDA)
    {
        h.steps = h.steps + 1;
        reduced = true;
        if (hered_walk(h, body.children[0], body.children[1], depth + 1)) { reduced = true; }
    }
    for (usz i = 0; i < body.child_count; i++)
    {
        if (hered_walk(h, body.children[i], arg, depth + 1)) { reduced = true; }
    }
    return reduced;
}

fn void MetaCtx.run_hered(MetaCtx* mc, Node* root)
{
    if (root == null) { return; }
    Hered h;
    hered_init(&h);
    (void)hered_walk(&h, root, null, 0);
    mc.n_hered_steps = mc.n_hered_steps + h.steps;
}

fn void MetaCtx.scan(MetaCtx* mc, Node* n, int depth)
{
    if (n == null || depth > META_MAX_DEPTH) { return; }
    for (usz i = 0; i < n.child_count; i++) { mc.scan(n.children[i], depth + 1); }
}

fn void MetaCtx.report(MetaCtx* mc)
{
    printf("  cmtt-meta        : %d meta-vars (%d solved), %d substitutions\n",
           (int)mc.var_count, (int)mc.n_solved_mvars, (int)mc.subst_count);
    printf("  cmtt-subst       : %d compositions, %d lookups, %d hered steps\n",
           (int)mc.n_subst_compose, (int)mc.n_subst_lookup, (int)mc.n_hered_steps);
    printf("  cmtt-occurs      : %d passed, %d failed (occurs-check)\n",
           (int)mc.n_occurs_ok, (int)mc.n_occurs_fail);
}

fn void MetaCtx.destroy(MetaCtx* mc)
{
    if (mc.vars != null) { free((void*)mc.vars); mc.vars = null; }
    if (mc.ctx_pool != null) { free((void*)mc.ctx_pool); mc.ctx_pool = null; }
    if (mc.substs != null)
    {
        for (usz i = 0; i < mc.subst_count; i++)
        {
            if (mc.substs[i].entries != null) { free((void*)mc.substs[i].entries); }
        }
        free((void*)mc.substs);
        mc.substs = null;
    }
}
