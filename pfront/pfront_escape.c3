// ============================================================================
// pfront_escape.c3 — Simple escape analysis for stack-allocated values
// ----------------------------------------------------------------------------
// A value "escapes" a function if a pointer/reference to it is stored into
// a location that outlives the function (global, returned, stored through a
// pointer that itself escapes, passed to an unknown function). If a value
// does NOT escape it can be:
//
//   * Stack-allocated (even large aggregates — no heap needed).
//   * Scalar-replaced (pfront_sra.c3's future job): its fields become scalars.
//   * Safely modified even if declared `let` (since no outside observer can
//     tell) — but in untyped Pride we don't enforce mutability anyway.
//
// This is a cheap flow-insensitive whole-function analysis:
//   1. Collect all address-taken locals (N_EXPR_REF applied to a local).
//   2. Mark as escaping any local whose address:
//        - is returned
//        - is stored into a global/static
//        - is stored through a non-local pointer
//        - is passed to an external/unknown function
//        - is assigned to a variable that itself escapes
//   3. Propagate escape via a simple worklist.
//
// Since Pride is untyped this is advisory. Reports counts.
// ============================================================================

module pfront_escape;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz ESC_MAX_LOCS = 2048;

struct EscapeAnalysis
{
    Arena* arena;
    Cfg*   cfg;

    // Candidate "locations": N_DECL_LET/N_DECL_VAR that have their address taken.
    Node** locs;
    usz    n_loc;
    usz    cap_loc;

    // Map from name_id -> location index.
    Node** idx_key;
    int*   idx_val;
    usz    idx_cap;

    bool*  escapes;

    usz n_addr_taken;
    usz n_escapes;
    usz n_stacksafe;
    usz n_returns;
    usz n_global_store;
    usz n_unknown_call;
}

fn void EscapeAnalysis.init(EscapeAnalysis* ea, Arena* a)
{
    ea.arena = a;
    ea.cfg = null;
    ea.cap_loc = 256;
    ea.locs = (Node**)calloc(ea.cap_loc, 8);
    ea.n_loc = 0;
    ea.idx_cap = 1024;
    ea.idx_key = (Node**)calloc(ea.idx_cap, 8);
    ea.idx_val = (int*)malloc(ea.idx_cap * 4);
    for (usz i = 0; i < ea.idx_cap; i++) ea.idx_val[i] = -1;
    ea.escapes = null;
    ea.n_addr_taken = 0;
    ea.n_escapes = 0;
    ea.n_stacksafe = 0;
    ea.n_returns = 0;
    ea.n_global_store = 0;
    ea.n_unknown_call = 0;
}

fn void ea_grow(EscapeAnalysis* ea)
{
    usz nc = ea.cap_loc * 2;
    Node** nl = (Node**)realloc(ea.locs, (long)(nc * 8));
    if (nl != null) { ea.locs = nl; ea.cap_loc = nc; }
    bool* ne = (bool*)realloc(ea.escapes, (long)nc);
    if (ne != null)
    {
        for (usz i = ea.n_loc; i < nc; i++) ne[i] = false;
        ea.escapes = ne;
    }
}

fn usz ea_hash(EscapeAnalysis* ea, Node* n)
{
    return ((usz)n >> 3) & (ea.idx_cap - 1);
}

fn int ea_find(EscapeAnalysis* ea, Node* n)
{
    if (n == null) return -1;
    usz h = ea_hash(ea, n);
    for (usz p = 0; p < ea.idx_cap; p++)
    {
        usz s = (h + p) & (ea.idx_cap - 1);
        if (ea.idx_key[s] == null) return -1;
        if (ea.idx_key[s] == n) return ea.idx_val[s];
    }
    return -1;
}

fn void ea_add(EscapeAnalysis* ea, Node* n)
{
    if (n == null) return;
    if (ea_find(ea, n) >= 0) return;
    if (ea.n_loc >= ea.cap_loc) ea_grow(ea);
    usz i = ea.n_loc;
    ea.locs[i] = n;
    ea.n_loc = i + 1;
    ea.escapes[i] = false;
    usz h = ea_hash(ea, n);
    for (usz p = 0; p < ea.idx_cap; p++)
    {
        usz s = (h + p) & (ea.idx_cap - 1);
        if (ea.idx_key[s] == null)
        {
            ea.idx_key[s] = n;
            ea.idx_val[s] = (int)i;
            return;
        }
    }
}

fn bool is_local_decl(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_DECL_LET;
}

// Get the "base" of an expression: the outermost local decl it refers to.
// Returns null if the expression is not derived from a local address.
fn Node* ea_origin(EscapeAnalysis* ea, Node* n, int depth)
{
    if (ea == null || n == null || depth > 32) return null;
    if (is_local_decl(n)) return n;
    if (n.kind == Nk.N_EXPR_IDENT)
    {
        // Resolved identifier -> its decl.
        if (n.resolved != null && is_local_decl(n.resolved)) return n.resolved;
        return null;
    }
    if (n.kind == Nk.N_EXPR_REF && n.child_count >= 1)
    {
        return ea_origin(ea, n.children[0], depth + 1);
    }
    if (n.kind == Nk.N_EXPR_DEREF && n.child_count >= 1)
    {
        // deref of an unknown pointer -> unknown
        return null;
    }
    if (n.kind == Nk.N_EXPR_FIELD && n.child_count >= 1)
    {
        return ea_origin(ea, n.children[0], depth + 1);
    }
    if (n.kind == Nk.N_EXPR_INDEX && n.child_count >= 1)
    {
        return ea_origin(ea, n.children[0], depth + 1);
    }
    return null;
}

fn void ea_mark(EscapeAnalysis* ea, Node* origin)
{
    if (origin == null) return;
    int i = ea_find(ea, origin);
    if (i < 0) return;
    if (!ea.escapes[i])
    {
        ea.escapes[i] = true;
        ea.n_escapes = ea.n_escapes + 1;
    }
}

fn void ea_scan(EscapeAnalysis* ea, Node* n)
{
    if (n == null) return;
    // Address taken?
    if (n.kind == Nk.N_EXPR_REF && n.child_count >= 1)
    {
        Node* base = n.children[0];
        Node* orig = ea_origin(ea, base, 0);
        if (orig != null)
        {
            ea_add(ea, orig);
            ea.n_addr_taken++;
        }
    }
    // Returning a ref/pointer to a local?
    if (n.kind == Nk.N_STMT_RETURN && n.child_count >= 1)
    {
        Node* orig = ea_origin(ea, n.children[0], 0);
        if (orig != null) { ea_mark(ea, orig); ea.n_returns++; }
    }
    // Storing into a global/static/non-local: mark RHS as escaping.
    if (n.kind == Nk.N_STMT_ASSIGN && n.child_count >= 2)
    {
        Node* lhs = n.children[0];
        Node* rhs = n.children[1];
        Node* rhs_orig = ea_origin(ea, rhs, 0);
        if (rhs_orig != null)
        {
            // Storing into a non-local -> escape.
            Node* lhs_orig = ea_origin(ea, lhs, 0);
            if (lhs_orig == null)
            {
                ea_mark(ea, rhs_orig);
                ea.n_global_store++;
            }
        }
    }
    // Call: pointer arguments to UNKNOWN callees escape.
    if (n.kind == Nk.N_EXPR_CALL)
    {
        Node* tgt = (n.child_count >= 1) ? n.children[0] : null;
        bool unknown = true;
        if (tgt != null && tgt.resolved != null && is_local_decl(tgt.resolved) == false
            && tgt.resolved != null && tgt.resolved.kind == Nk.N_DECL_FN)
        {
            // Known function — in a full system we'd inspect its signature,
            // but conservatively still mark pointer args as escaping unless
            // we know it's "pure" and doesn't capture.
            unknown = true;
        }
        if (unknown)
        {
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* a = n.children[i];
                Node* o = ea_origin(ea, a, 0);
                if (o != null) { ea_mark(ea, o); ea.n_unknown_call++; }
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ea_scan(ea, n.children[i]);
    }
}

fn void EscapeAnalysis.run_on_fn(EscapeAnalysis* ea, Node* fnode)
{
    if (fnode == null) return;
    ea_scan(ea, fnode);
    // Tally.
    for (usz i = 0; i < ea.n_loc; i++)
    {
        if (!ea.escapes[i]) ea.n_stacksafe++;
    }
}

fn void EscapeAnalysis.run_on_cfg(EscapeAnalysis* ea, Cfg* cfg)
{
    if (cfg == null) return;
    ea.cfg = cfg;
    // Allocate escapes array.
    ea.escapes = (bool*)calloc(ea.cap_loc, 1);
    // Walk all blocks' statements.
    for (usz bi = 0; bi < cfg.block_count; bi++)
    {
        Block* b = &cfg.blocks[bi];
        for (usz si = 0; si < b.stmt_count; si++)
        {
            ea_scan(ea, b.stmts[si]);
        }
    }
    for (usz i = 0; i < ea.n_loc; i++)
    {
        if (!ea.escapes[i]) ea.n_stacksafe++;
    }
}

fn void EscapeAnalysis.report(EscapeAnalysis* ea)
{
    printf("  escape addr-taken: %d locs, %d escape (ret=%d global=%d call=%d), %d stack-safe\n",
           (int)ea.n_loc, (int)ea.n_escapes, (int)ea.n_returns,
           (int)ea.n_global_store, (int)ea.n_unknown_call, (int)ea.n_stacksafe);
}

fn void EscapeAnalysis.free(EscapeAnalysis* ea)
{
    free((void*)ea.locs);
    free((void*)ea.idx_key);
    free((void*)ea.idx_val);
    free((void*)ea.escapes);
    ea.locs = null;
    ea.escapes = null;
}
