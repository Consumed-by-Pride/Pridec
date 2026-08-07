// ============================================================================
// pfront_inline.c3 — Inlining profitability heuristics
// ----------------------------------------------------------------------------
// For every static call site in a function body, computes an advisory
// "inline bonus / penalty" score and buckets calls into:
//
//   INLINE_ALWAYS  : score >= threshold — tiny leaf, direct, no loops, often
//                    called (local hint), trivially cheap body.
//   INLINE_HOT     : in a loop, small body — inline to expose further opts.
//   INLINE_BENIGN  : medium body, single call site — inline if budget allows.
//   INLINE_NEVER   : recursive, large, effectful-heavy, or polymorphic dispatch.
//
// Size metrics are purely syntactic (AST node count of callee body). No
// transformation happens; the scores feed later passes (perf hints, code
// layout) and are printed under --time-passes.
// ============================================================================

module pfront_inline;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk     = pfront_core::NodeKind;
alias Tk     = pfront_lex::TokenType;
alias Node   = pfront_core::PNode;
alias Arena  = pfront_core::Arena;
alias Cfg    = pfront_cfg::Cfg;
alias Block  = pfront_cfg::Block;

extern fn int printf(char* fmt, ...);

const int INLINE_UNKNOWN = 0;
const int INLINE_ALWAYS  = 1;
const int INLINE_HOT     = 2;
const int INLINE_BENIGN  = 3;
const int INLINE_NEVER   = 4;

struct CallSite
{
    Node* call;        // the N_EXPR_CALL node
    uint  callee_id;   // name_id of direct callee, 0 if indirect
    usz   callee_size; // ast node count of callee body
    int   score;       // higher = more profitable
    int   bucket;      // INLINE_*
    bool  in_loop;
}

struct InlineHeur
{
    Arena*      arena;
    Cfg*        cfg;
    CallSite*   sites;
    usz         site_cap;
    usz         site_count;
    usz         n_always;
    usz         n_hot;
    usz         n_benign;
    usz         n_never;
    usz         n_indirect;
    usz         n_leaf_candidates;
    usz         n_small;
    usz         n_large;
    long        total_bonus;
}

fn void InlineHeur.init(InlineHeur* ih, Arena* a)
{
    ih.arena = a;
    ih.cfg = null;
    ih.site_cap = 64;
    ih.sites = (CallSite*)malloc((long)(ih.site_cap * CallSite::size));
    ih.site_count = 0;
    ih.n_always = 0; ih.n_hot = 0; ih.n_benign = 0; ih.n_never = 0;
    ih.n_indirect = 0; ih.n_leaf_candidates = 0; ih.n_small = 0; ih.n_large = 0;
    ih.total_bonus = 0;
}

// Count AST nodes in a subtree (cheap syntactic size proxy).
fn usz ast_size(Node* n, usz depth)
{
    if (n == null || depth > 200) { return 0; }
    usz s = 1;
    for (usz i = 0; i < n.child_count; i++)
    {
        s = s + ast_size(n.children[i], depth + 1);
    }
    if (n.type_ann != null) { s = s + ast_size(n.type_ann, depth + 1); }
    return s;
}

// Does the subtree contain a loop? (while/for/loop)
fn bool contains_loop(Node* n, usz depth)
{
    if (n == null || depth > 200) { return false; }
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP)
    {
        return true;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (contains_loop(n.children[i], depth + 1)) { return true; }
    }
    return false;
}

// Does the subtree contain another call? (used for leaf detection)
fn bool contains_call(Node* n, usz depth)
{
    if (n == null || depth > 200) { return false; }
    if (n.kind == Nk.N_EXPR_CALL && depth > 0) { return true; }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (contains_call(n.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn int classify_score(usz body_size, bool in_loop, bool is_leaf, bool has_loop,
                      bool is_self_rec, usz arg_count)
{
    int sc = 0;
    if (is_self_rec) { return -1000; }
    if (body_size <= 6)  { sc = sc + 40; }   // tiny (getter/setter/leaf op)
    else if (body_size <= 15) { sc = sc + 20; }
    else if (body_size <= 40) { sc = sc + 5; }
    else if (body_size <= 100) { sc = sc - 10; }
    else { sc = sc - 60; }    // large
    if (is_leaf) { sc = sc + 25; }
    if (in_loop) { sc = sc + 30; }   // loop-invariant calls benefit
    if (has_loop) { sc = sc - 80; }  // inlining a loop grows code fast
    if (arg_count <= 2) { sc = sc + 5; }
    if (arg_count >= 6) { sc = sc - 15; }
    return sc;
}

fn int bucket_from_score(int sc, usz body_size)
{
    if (sc >= 40) { return INLINE_ALWAYS; }
    if (sc >= 15) { return INLINE_HOT; }
    if (sc >= -10) { return INLINE_BENIGN; }
    return INLINE_NEVER;
}

fn void ih_push_site(InlineHeur* ih, CallSite cs)
{
    if (ih.sites == null) { return; }
    if (ih.site_count >= ih.site_cap)
    {
        usz nc = ih.site_cap * 2;
        CallSite* bigger = (CallSite*)malloc((long)(nc * CallSite::size));
        if (bigger == null) { return; }
        for (usz i = 0; i < ih.site_count; i++) { bigger[i] = ih.sites[i]; }
        free((void*)ih.sites);
        ih.sites = bigger;
        ih.site_cap = nc;
    }
    ih.sites[ih.site_count] = cs;
    ih.site_count = ih.site_count + 1;
}

// Try to resolve a callee by walking the function decl list. For pfront's
// AST stage this is a simple name-id equality scan (no overloading).
fn Node* find_fn_by_name(Node* root, uint name_id, usz depth)
{
    if (root == null || depth > 40 || name_id == 0) { return null; }
    if (root.kind == Nk.N_DECL_FN && root.name_id == name_id) { return root; }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* r = find_fn_by_name(root.children[i], name_id, depth + 1);
        if (r != null) { return r; }
    }
    return null;
}

fn usz fn_body_size(Node* fdecl)
{
    if (fdecl == null) { return 0; }
    usz s = 0;
    for (usz k = 0; k < fdecl.child_count; k++)
    {
        s = s + ast_size(fdecl.children[k], 0);
    }
    return s;
}

fn bool fn_is_leaf(Node* fdecl)
{
    if (fdecl == null) { return false; }
    for (usz k = 0; k < fdecl.child_count; k++)
    {
        Node* c = fdecl.children[k];
        if (c == null) { continue; }
        if (c.kind == Nk.N_CLAUSE)
        {
            for (usz j = 1; j < c.child_count; j++)
            {
                if (contains_call(c.children[j], 0)) { return false; }
            }
        }
        else if (c.kind == Nk.N_BLOCK)
        {
            if (contains_call(c, 0)) { return false; }
        }
    }
    return true;
}

fn bool fn_has_loop(Node* fdecl)
{
    if (fdecl == null) { return false; }
    for (usz k = 0; k < fdecl.child_count; k++)
    {
        Node* c = fdecl.children[k];
        if (c == null) { continue; }
        if (c.kind == Nk.N_CLAUSE)
        {
            for (usz j = 1; j < c.child_count; j++)
            {
                if (contains_loop(c.children[j], 0)) { return true; }
            }
        }
        else if (c.kind == Nk.N_BLOCK)
        {
            if (contains_loop(c, 0)) { return true; }
        }
    }
    return false;
}

fn void ih_scan_expr(InlineHeur* ih, Node* n, Node* root, Node* self_fdecl,
                     bool in_loop, usz depth)
{
    if (n == null || depth > 200) { return; }
    bool next_loop = in_loop;
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP)
    {
        next_loop = true;
    }
    if (n.kind == Nk.N_EXPR_CALL)
    {
        uint callee = 0;
        usz argc = 0;
        if (n.child_count >= 1 && n.children[0] != null
            && n.children[0].kind == Nk.N_EXPR_IDENT)
        {
            callee = n.children[0].name_id;
            argc = (n.child_count > 1) ? n.child_count - 1 : 0;
        }
        if (callee == 0) { ih.n_indirect = ih.n_indirect + 1; }
        else
        {
            Node* tgt = find_fn_by_name(root, callee, 0);
            usz bs = fn_body_size(tgt);
            bool is_leaf = fn_is_leaf(tgt);
            bool has_loop = fn_has_loop(tgt);
            bool is_self = self_fdecl != null && self_fdecl.name_id == callee;
            int sc = classify_score(bs, next_loop, is_leaf, has_loop, is_self, argc);
            int bk = bucket_from_score(sc, bs);
            CallSite cs;
            cs.call = n; cs.callee_id = callee; cs.callee_size = bs;
            cs.score = sc; cs.bucket = bk; cs.in_loop = next_loop;
            ih_push_site(ih, cs);
            ih.total_bonus = ih.total_bonus + (long)sc;
            if (bk == INLINE_ALWAYS) { ih.n_always = ih.n_always + 1; if (is_leaf) ih.n_leaf_candidates++; if (bs <= 15) ih.n_small++; }
            else if (bk == INLINE_HOT) { ih.n_hot = ih.n_hot + 1; if (bs <= 15) ih.n_small++; }
            else if (bk == INLINE_BENIGN) { ih.n_benign = ih.n_benign + 1; }
            else { ih.n_never = ih.n_never + 1; if (bs >= 100) ih.n_large++; }
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ih_scan_expr(ih, n.children[i], root, self_fdecl, next_loop, depth + 1);
    }
}

fn void InlineHeur.run_on_module(InlineHeur* ih, Node* root)
{
    if (root == null) { return; }
    ih_scan_fns(ih, root, root, 0);
}

fn void ih_scan_fns(InlineHeur* ih, Node* n, Node* root, usz depth)
{
    if (n == null || depth > 60) { return; }
    if (n.kind == Nk.N_DECL_FN)
    {
        // Walk body of this fn looking for calls.
        for (usz k = 0; k < n.child_count; k++)
        {
            Node* c = n.children[k];
            if (c == null) { continue; }
            ih_scan_expr(ih, c, root, n, false, 0);
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ih_scan_fns(ih, n.children[i], root, depth + 1);
    }
}

fn void InlineHeur.report(InlineHeur* ih)
{
    printf("  inline-heur      : always=%d hot=%d benign=%d never=%d indirect=%d\n",
           (int)ih.n_always, (int)ih.n_hot, (int)ih.n_benign, (int)ih.n_never, (int)ih.n_indirect);
    printf("  inline-size      : leaf-cands=%d small=%d large=%d total-bonus=%ld\n",
           (int)ih.n_leaf_candidates, (int)ih.n_small, (int)ih.n_large, ih.total_bonus);
}

fn void InlineHeur.free(InlineHeur* ih)
{
    if (ih.sites != null) { free((void*)ih.sites); ih.sites = null; }
}
