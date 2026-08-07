// ============================================================================
// pfront_cse.c3 — Local Common Subexpression Elimination (analysis only)
// ----------------------------------------------------------------------------
// Within a basic block, two computations of the same pure expression are
// redundant: the second can reuse the first's result. Unlike GVN which
// works across the dominator tree, CSE is strictly local to a block and
// uses a simple hash-scoped table, so it is very cheap.
//
// A "computation" is considered available at a point if:
//   1. It appears earlier in the same block;
//   2. No intervening statement writes to any variable referenced by it
//      (i.e. it is still safe to reuse);
//   3. The computation is pure (effects == 0) so duplicating it has no
//      observable side effects.
//
// This pass reports how many redundant computations exist. It does not
// mutate the AST.
// ============================================================================

module pfront_cse;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz CSE_TBL = 1024;

struct Cse
{
    Arena* arena;
    Cfg*   cfg;

    // Per-run table: expression hash -> "seen node" identity.
    // We track a fixed small number of expressions per block.
    usz    redundant;
    usz    available;
    usz    blocks;
    usz    total_exprs;
}

fn void Cse.init(Cse* c, Arena* a)
{
    c.arena = a;
    c.cfg = null;
    c.redundant = 0;
    c.available = 0;
    c.blocks = 0;
    c.total_exprs = 0;
}

fn usz cse_hash(Node* n)
{
    if (n == null) return 0;
    usz h = (usz)n.kind * 2654435761u;
    h = h ^ (usz)(n.p.op * 97);
    h = h ^ (usz)(n.name_id * 131);
    if (n.kind == Nk.N_EXPR_INT)  h = h ^ (usz)n.p.ival;
    if (n.kind == Nk.N_EXPR_BOOL) h = h ^ (usz)(n.p.ival & 1u);
    if (n.kind == Nk.N_EXPR_CHAR) h = h ^ (usz)n.p.ival;
    // Combine children hashes in order.
    for (usz i = 0; i < n.child_count && i < 4; i++)
    {
        usz ch = cse_hash(n.children[i]);
        h = (h ^ (ch << ((i * 7) & 63))) * 1099511628211u;
    }
    return h;
}

// Conservative "does this node reference some identifier?" — used to kill
// available expressions when a variable is assigned.
fn void cse_kill_if_write(Cse* c, Node* s, Node** avail_k, Node** avail_v, usz* navail)
{
    if (c == null) return;
    if (s == null) return;
    usz killed_name = 0;
    if (s.kind == Nk.N_STMT_ASSIGN && s.child_count >= 1)
    {
        Node* tgt = s.children[0];
        if (tgt != null && tgt.kind == Nk.N_EXPR_IDENT) killed_name = tgt.name_id;
    }
    if (s.kind == Nk.N_DECL_LET && s.child_count >= 1)
    {
        Node* nm = s.children[0];
        if (nm != null) killed_name = nm.name_id;
    }
    if (killed_name == 0)
    {
        // Effectful statement kills everything.
        if (s.effects != 0) { *navail = 0; }
        return;
    }
    // Remove entries that reference this name.
    usz w = 0;
    for (usz i = 0; i < *navail; i++)
    {
        Node* k = avail_k[i];
        bool drop = false;
        if (cse_mentions(k, killed_name)) { drop = true; }
        if (!drop)
        {
            avail_k[w] = k; avail_v[w] = avail_v[i]; w++;
        }
    }
    *navail = w;
}

fn bool cse_mentions(Node* n, usz name)
{
    if (n == null) return false;
    if (n.kind == Nk.N_EXPR_IDENT && n.name_id == name) return true;
    for (usz i = 0; i < n.child_count; i++)
    {
        if (cse_mentions(n.children[i], name)) return true;
    }
    return false;
}

fn bool cse_is_pure(Node* n)
{
    if (n == null) return false;
    return n.effects == 0;
}

// Look up an expression in the available table; if found, mark redundant.
fn void cse_lookup(Cse* c, Node* e, Node** avail_k, Node** avail_v, usz navail)
{
    if (e == null) return;
    if (!cse_is_pure(e)) return;
    // We only CSE pure computations with at least one child (so plain
    // identifiers/constants don't count — they are already "free").
    if (e.child_count == 0) return;
    switch (e.kind)
    {
        case Nk.N_EXPR_BINARY:
        case Nk.N_EXPR_UNARY:
        case Nk.N_EXPR_FIELD:
        case Nk.N_EXPR_INDEX:
        case Nk.N_EXPR_CAST:
        case Nk.N_EXPR_TUPLE:
        case Nk.N_EXPR_ARRAY:
            break;
        default:
            return;
    }
    c.total_exprs = c.total_exprs + 1;
    usz h = cse_hash(e) & (CSE_TBL - 1);
    for (usz i = 0; i < navail; i++)
    {
        if (cse_hash(avail_k[i]) == h && cse_equal(avail_k[i], e))
        {
            c.redundant = c.redundant + 1;
            return;
        }
    }
    // Insert.
    if (navail < CSE_TBL - 1)
    {
        avail_k[navail] = e; avail_v[navail] = e;
        c.available = c.available + 1;
    }
}

fn bool cse_equal(Node* a, Node* b)
{
    if (a == b) return true;
    if (a == null || b == null) return false;
    if (a.kind != b.kind) return false;
    if (a.p.op != b.p.op) return false;
    if (a.name_id != b.name_id) return false;
    switch (a.kind)
    {
        case Nk.N_EXPR_INT:  return a.p.ival == b.p.ival;
        case Nk.N_EXPR_BOOL: return (a.p.ival != 0) == (b.p.ival != 0);
        case Nk.N_EXPR_CHAR: return a.p.ival == b.p.ival;
        case Nk.N_EXPR_IDENT: return a.name_id == b.name_id;
        default: break;
    }
    if (a.child_count != b.child_count) return false;
    for (usz i = 0; i < a.child_count; i++)
    {
        if (!cse_equal(a.children[i], b.children[i])) return false;
    }
    return true;
}

fn void cse_scan_expr(Cse* c, Node* e, Node** avail_k, Node** avail_v, usz* navail)
{
    if (e == null) return;
    // Process children first (bottom-up).
    for (usz i = 0; i < e.child_count; i++)
    {
        cse_scan_expr(c, e.children[i], avail_k, avail_v, navail);
    }
    usz before = c.available;
    cse_lookup(c, e, avail_k, avail_v, *navail);
    if (c.available > before && *navail < CSE_TBL - 1)
    {
        (*navail)++;
    }
}

fn void Cse.run_on_cfg(Cse* c, Cfg* cfg)
{
    if (cfg == null) return;
    c.cfg = cfg;
    Node** avail_k = (Node**)malloc(CSE_TBL * 8);
    Node** avail_v = (Node**)malloc(CSE_TBL * 8);
    usz nb = cfg.block_count;
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &cfg.blocks[bi];
        usz navail = 0;
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* s = b.stmts[si];
            if (s == null) continue;
            // Scan subexpressions first.
            cse_scan_expr(c, s, avail_k, avail_v, &navail);
            // Then kill based on writes.
            cse_kill_if_write(c, s, avail_k, avail_v, &navail);
        }
        // Process terminator condition.
        if (b.term_node != null)
        {
            cse_scan_expr(c, b.term_node, avail_k, avail_v, &navail);
        }
        c.blocks = c.blocks + 1;
    }
    free((void*)avail_k); free((void*)avail_v);
}

fn void Cse.report(Cse* c)
{
    printf("  cse available    : %d expressions\n", (int)c.available);
    printf("  cse redundant    : %d\n", (int)c.redundant);
    printf("  cse total exprs  : %d across %d blocks\n", (int)c.total_exprs, (int)c.blocks);
}
