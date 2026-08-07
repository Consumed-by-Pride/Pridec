// ============================================================================
// pfront_domfront.c3 — Dominance frontier computation (Cytron et al.)
// ----------------------------------------------------------------------------
// The dominance frontier of a node b is the set of nodes where b's
// "dominance stops": DF(b) = { c | b dominates a predecessor of c but does
// not strictly dominate c }. DF is required by every SSA construction
// algorithm (Cytron '91) to know where φ functions must be placed. Even
// though our current passes do not transform into SSA form, having DF
// available means the future lowering pass can use it directly.
//
// We compute DF using the standard algorithm:
//   for each node b in the CFG,
//     for each predecessor p of b,
//       runner = p
//       while runner != idom(b) and runner is defined,
//         add b to DF(runner)
//         runner = idom(runner)
//
// This is computed from the existing idom tree built by pfront_cfg.c3's
// dominator analysis. Output is per-node DF sets, plus summary statistics.
// ============================================================================

module pfront_domfront;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz DF_MAX = 64;

struct DomFront
{
    Arena* arena;
    Cfg*   cfg;
    int**  df;
    usz*   df_count;
    usz*   df_cap;
    usz    n_nodes;
    usz    n_df_edges;
    usz    join_points;
    usz    max_df;
    double avg_df;
    bool   computed;
}

fn void DomFront.init(DomFront* d, Arena* a)
{
    d.arena = a;
    d.cfg = null;
    d.df = null;
    d.df_count = null;
    d.df_cap = null;
    d.n_nodes = 0;
    d.n_df_edges = 0;
    d.join_points = 0;
    d.max_df = 0;
    d.avg_df = 0.0;
    d.computed = false;
}

fn void df_add(DomFront* d, usz b, int tgt)
{
    if (tgt < 0) return;
    usz u = b;
    if (u >= d.n_nodes) return;
    usz cnt = d.df_count[u];
    usz cap = d.df_cap[u];
    // dedup
    int* arr = d.df[u];
    for (usz i = 0; i < cnt; i++)
    {
        if (arr[i] == tgt) return;
    }
    if (cnt >= cap)
    {
        usz nc = cap == 0 ? 4 : cap * 2;
        int* na = (int*)realloc(arr, (long)(nc * 4));
        if (na == null) return;
        d.df[u] = na;
        d.df_cap[u] = nc;
    }
    d.df[u][cnt] = tgt;
    d.df_count[u] = cnt + 1;
    d.n_df_edges = d.n_df_edges + 1;
}

fn void DomFront.compute(DomFront* d, Cfg* c)
{
    if (c == null) return;
    if (d.computed) return;
    d.cfg = c;
    usz nb = c.block_count;
    d.n_nodes = nb;
    d.df = (int**)calloc(nb, 8);
    d.df_count = (usz*)calloc(nb, 8);
    d.df_cap = (usz*)calloc(nb, 8);
    if (d.df == null) return;
    // For each block b, for each predecessor p, walk up p's idom chain.
    for (usz b = 0; b < nb; b++)
    {
        Block* blk = &c.blocks[b];
        for (usz pi = 0; pi < blk.pred_count; pi++)
        {
            int p_id = blk.preds[pi];
            if (p_id < 0) continue;
            int runner = p_id;
            while (runner >= 0 && (usz)runner < nb && runner != blk.idom)
            {
                df_add(d, (usz)runner, (int)b);
                int nr = c.blocks[runner].idom;
                if (nr == runner) break;
                runner = nr;
            }
        }
    }
    // Stats
    for (usz b = 0; b < nb; b++)
    {
        usz cnt = d.df_count[b];
        if (cnt > 0) d.join_points++;
        if (cnt > d.max_df) d.max_df = cnt;
        d.avg_df = d.avg_df + (double)cnt;
    }
    if (nb > 0) d.avg_df = d.avg_df / (double)nb;
    d.computed = true;
}

fn bool DomFront.has_phi(DomFront* d, usz b)
{
    if (!d.computed || b >= d.n_nodes) return false;
    return d.df_count[b] > 0;
}

fn void DomFront.report(DomFront* d)
{
    printf("  domfront         : %d join-point blocks (phi-sites), %d DF edges\n",
           (int)d.join_points, (int)d.n_df_edges);
    printf("  domfront stats   : max DF=%d, avg %.2f\n",
           (int)d.max_df, d.avg_df);
}

fn void DomFront.free(DomFront* d)
{
    if (d.df != null)
    {
        for (usz i = 0; i < d.n_nodes; i++)
        {
            if (d.df[i] != null) free((void*)d.df[i]);
        }
        free((void*)d.df);
    }
    free((void*)d.df_count);
    free((void*)d.df_cap);
    d.df = null; d.df_count = null; d.df_cap = null;
    d.n_nodes = 0; d.computed = false;
}
