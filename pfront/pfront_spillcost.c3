// ============================================================================
// pfront_spillcost.c3 — Spill cost / live-range weight heuristics
// ----------------------------------------------------------------------------
// Computes a rough "spill weight" for each locally-defined pseudo by scanning
// CFG blocks backwards and accumulating use counts weighted by loop-nesting
// depth. The idea comes from Briggs et al. and the Chaitin-Briggs style
// register allocators; we don't do allocation here, just report distribution
// of weights so later passes can see how hot/cold live ranges are.
//
// Weight for a use = 10^(loop_depth) (classic 10^d heuristic). Defs get half.
// Values above a threshold are "hot" (never spill); below are "cold" (good
// spill candidates). Between is "warm".
// ============================================================================

module pfront_spillcost;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk       = pfront_core::NodeKind;
alias Tk       = pfront_lex::TokenType;
alias Node     = pfront_core::PNode;
alias Arena    = pfront_core::Arena;
alias Cfg      = pfront_cfg::Cfg;
alias Block    = pfront_cfg::Block;
alias Loop     = pfront_cfg::Loop;

extern fn int printf(char* fmt, ...);

const usz SC_MAX_LOCALS = 512;

struct PseudoWeight
{
    Node* decl;          // the N_DECL_LET / N_EXPR_IDENT decl
    uint  name_id;
    long  weight;       // accumulated 10^d uses
    usz   use_count;
    usz   def_count;
    int   max_depth;
}

struct SpillCost
{
    Arena*        arena;
    Cfg*          cfg;
    PseudoWeight* weights;
    usz           n_pseudo;
    usz           n_hot;
    usz           n_warm;
    usz           n_cold;
    usz           n_zero;
    long          total_weight;
    long          max_weight;
    usz           total_uses;
    usz           total_defs;
}

fn void SpillCost.init(SpillCost* sc, Arena* a)
{
    sc.arena = a;
    sc.cfg = null;
    sc.weights = (PseudoWeight*)malloc((long)(SC_MAX_LOCALS * PseudoWeight::size));
    sc.n_pseudo = 0;
    sc.n_hot = 0; sc.n_warm = 0; sc.n_cold = 0; sc.n_zero = 0;
    sc.total_weight = 0; sc.max_weight = 0;
    sc.total_uses = 0; sc.total_defs = 0;
}

fn int weight_index(SpillCost* sc, Node* v)
{
    if (v == null || sc.weights == null) { return -1; }
    uint id = v.name_id;
    for (usz i = 0; i < sc.n_pseudo; i++)
    {
        if (sc.weights[i].decl == v || sc.weights[i].name_id == id) { return (int)i; }
    }
    if (sc.n_pseudo >= SC_MAX_LOCALS) { return -1; }
    int idx = (int)sc.n_pseudo;
    sc.n_pseudo = sc.n_pseudo + 1;
    sc.weights[idx].decl = v;
    sc.weights[idx].name_id = id;
    sc.weights[idx].weight = 0;
    sc.weights[idx].use_count = 0;
    sc.weights[idx].def_count = 0;
    sc.weights[idx].max_depth = 0;
    return idx;
}

// Classic 10^depth weighting. Keep it small/simple.
fn long depth_mult(int d)
{
    long m = 1;
    for (int i = 0; i < d; i++) { m = m * 10; if (m > 1000000) { m = 1000000; break; } }
    return m;
}

fn void add_use(SpillCost* sc, Node* v, int depth)
{
    int idx = weight_index(sc, v);
    if (idx < 0) { return; }
    long m = depth_mult(depth);
    sc.weights[idx].weight = sc.weights[idx].weight + m;
    sc.weights[idx].use_count = sc.weights[idx].use_count + 1;
    if (depth > sc.weights[idx].max_depth) { sc.weights[idx].max_depth = depth; }
    sc.total_uses = sc.total_uses + 1;
    sc.total_weight = sc.total_weight + m;
    if (sc.weights[idx].weight > sc.max_weight) { sc.max_weight = sc.weights[idx].weight; }
}

fn void add_def(SpillCost* sc, Node* v, int depth)
{
    int idx = weight_index(sc, v);
    if (idx < 0) { return; }
    long m = depth_mult(depth) / 2;
    sc.weights[idx].weight = sc.weights[idx].weight + m;
    sc.weights[idx].def_count = sc.weights[idx].def_count + 1;
    if (depth > sc.weights[idx].max_depth) { sc.weights[idx].max_depth = depth; }
    sc.total_defs = sc.total_defs + 1;
    sc.total_weight = sc.total_weight + m;
}

// Walk expression, tally ident uses. Defs come from N_DECL_LET or assignment
// LHS; this pass only tracks uses — defs are recorded at scan_let.
fn void sc_scan_uses(SpillCost* sc, Node* n, int depth, usz lvl)
{
    if (n == null || lvl > 80) { return; }
    if (n.kind == Nk.N_EXPR_IDENT && n.name_id != 0)
    {
        // Only count variables that were declared (def seen), not fns/builtins.
        add_use(sc, n, depth);
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        sc_scan_uses(sc, n.children[i], depth, lvl + 1);
    }
}

fn void sc_scan_stmts(SpillCost* sc, Node* n, int depth, usz lvl)
{
    if (n == null || lvl > 200) { return; }
    if (n.kind == Nk.N_DECL_LET)
    {
        // Record def at name node; walk init for uses.
        if (n.child_count >= 1)
        {
            Node* nm = null;
            // children[0] is often the pattern; find ident.
            for (usz k = 0; k < n.child_count; k++)
            {
                if (n.children[k] != null && n.children[k].kind == Nk.N_PAT_IDENT)
                {
                    nm = n.children[k];
                    break;
                }
            }
            if (nm == null && n.child_count >= 2) { nm = n.children[0]; }
            if (nm != null)
            {
                int idx = weight_index(sc, nm);
                if (idx >= 0)
                {
                    long m = depth_mult(depth) / 2;
                    sc.weights[idx].def_count = sc.weights[idx].def_count + 1;
                    sc.weights[idx].weight = sc.weights[idx].weight + m;
                    sc.total_defs = sc.total_defs + 1;
                    sc.total_weight = sc.total_weight + m;
                }
            }
            // init expressions at children[child_count-1] often
            for (usz k = 0; k < n.child_count; k++)
            {
                Node* c = n.children[k];
                if (c != null && c.kind != Nk.N_PAT_IDENT)
                {
                    sc_scan_uses(sc, c, depth, lvl + 1);
                }
            }
        }
        return;
    }
    if (n.kind == Nk.N_STMT_ASSIGN && n.child_count >= 2)
    {
        // LHS is def, RHS uses
        Node* lhs = n.children[0];
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT)
        {
            add_def(sc, lhs, depth);
        }
        sc_scan_uses(sc, n.children[1], depth, lvl + 1);
        return;
    }
    // Loops bump depth
    int nd = depth;
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP)
    {
        nd = depth + 1;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP)
        {
            sc_scan_stmts(sc, n.children[i], nd, lvl + 1);
        }
        else
        {
            sc_scan_stmts(sc, n.children[i], depth, lvl + 1);
        }
    }
}

fn void sc_classify(SpillCost* sc)
{
    const long HOT_THRESH = 100;
    const long COLD_THRESH = 10;
    for (usz i = 0; i < sc.n_pseudo; i++)
    {
        long w = sc.weights[i].weight;
        if (w == 0) { sc.n_zero++; }
        else if (w >= HOT_THRESH) { sc.n_hot++; }
        else if (w < COLD_THRESH) { sc.n_cold++; }
        else { sc.n_warm++; }
    }
}

fn void SpillCost.run_on_cfg(SpillCost* sc, Cfg* cfg)
{
    if (cfg == null) { return; }
    sc.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++)
    {
        Block* b = &cfg.blocks[i];
        // Walk block statements
        for (usz j = 0; j < b.stmt_count; j++)
        {
            sc_scan_stmts(sc, b.stmts[j], b.loop_depth, 0);
        }
        // terminator condition uses
        if (b.term_node != null)
        {
            sc_scan_uses(sc, b.term_node, b.loop_depth, 0);
        }
    }
    sc_classify(sc);
}

fn void SpillCost.report(SpillCost* sc)
{
    printf("  spill-cost       : pseudos=%d (hot=%d warm=%d cold=%d zero=%d)\n",
           (int)sc.n_pseudo, (int)sc.n_hot, (int)sc.n_warm, (int)sc.n_cold, (int)sc.n_zero);
    printf("  spill-uses       : %d uses, %d defs, max-weight=%ld\n",
           (int)sc.total_uses, (int)sc.total_defs, sc.max_weight);
}

fn void SpillCost.free(SpillCost* sc)
{
    if (sc.weights != null) { free((void*)sc.weights); sc.weights = null; }
}
