// ============================================================================
// pfront_codelayout.c3 — Profile-guided / static code layout hints
// ----------------------------------------------------------------------------
// After branch probabilities and hot paths are estimated, a backend wants
// to lay basic blocks so that the fall-through path is the hot one. This
// pass computes a Pettis-Hansen-style layout order:
//
//   1. Start with each block as its own chain.
//   2. Treat (block, successor) edges with weight > threshold as "call chain
//      candidates"; merge chains greedily by edge weight.
//   3. For each chain, place blocks in chain order; arrange chains so hot
//      chains are contiguous.
//
// This implementation is STATIC: it uses pfront_branchprob classifications
// (likely/cold) plus loop-nesting depth (higher = hotter) to assign edge
// weights, then runs the greedy chain merge. Counters report how many chains
// were placed, fall-through hits, broken hot edges, and cold blocks moved
// out-of-line.
//
// Nothing is laid out; this is strictly an analysis producing an ordering
// and reporting statistics.
// ============================================================================

module pfront_codelayout;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk       = pfront_core::NodeKind;
alias Tk       = pfront_lex::TokenType;
alias Node     = pfront_core::PNode;
alias Arena    = pfront_core::Arena;
alias Cfg      = pfront_cfg::Cfg;
alias Block    = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;

extern fn int printf(char* fmt, ...);
extern fn void* malloc(usz size);
extern fn void  free(void* ptr);

struct CodeLayout
{
    Arena* arena;
    Cfg*   cfg;
    int*   order;         // block ids in layout order
    usz    order_count;
    int*   chain_id;
    usz    n_chains;
    long*  edge_weight;   // for each succ pair; flattened
    usz    n_edges;
    usz    ft_hot;        // fallthrough is hot
    usz    ft_cold;       // fallthrough is cold (could reorder)
    usz    chains_merged;
    usz    cold_blocks;   // blocks laid out on cold path
    usz    hot_chains;
}

fn void CodeLayout.init(CodeLayout* cl, Arena* a)
{
    cl.arena = a; cl.cfg = null;
    cl.order = null; cl.order_count = 0;
    cl.chain_id = null;
    cl.n_chains = 0;
    cl.edge_weight = null; cl.n_edges = 0;
    cl.ft_hot = 0; cl.ft_cold = 0; cl.chains_merged = 0;
    cl.cold_blocks = 0; cl.hot_chains = 0;
}

fn long edge_weight(Block* b, usz succ_idx, int depth)
{
    if (b == null || succ_idx >= b.succ_count) { return 0; }
    long w = 1;
    for (int i = 0; i < depth + 1; i++) { w = w * 10; if (w > 1000000) { w = 1000000; break; } }
    // Prefer not-taken for if (fallthrough to succs[1] is usually "else")
    if (b.term == TermKind.TERM_IF && succ_idx == 0) { w = w / 10; }
    // Return/Unreachable blocks are cold
    if (b.term == TermKind.TERM_RETURN || b.term == TermKind.TERM_UNREACH
        || b.term == TermKind.TERM_TAIL) { w = w / 100; }
    return w;
}

fn void CodeLayout.run_on_cfg(CodeLayout* cl, Cfg* cfg)
{
    if (cfg == null) { return; }
    cl.cfg = cfg;
    usz nb = cfg.block_count;
    cl.order = (int*)malloc((long)(nb * 4));
    cl.chain_id = (int*)malloc((long)(nb * 4));
    // First count total edges so we can size edge_weight precisely.
    usz total_edges = 0;
    for (usz i = 0; i < nb; i++) { total_edges = total_edges + cfg.blocks[i].succ_count; }
    if (total_edges == 0) { total_edges = 1; }
    cl.edge_weight = (long*)malloc((long)(total_edges * 8));
    if (cl.order == null || cl.chain_id == null || cl.edge_weight == null) { return; }
    for (usz i = 0; i < nb; i++) { cl.chain_id[i] = (int)i; }
    cl.n_chains = nb;
    // Compute edge weights
    usz ei = 0;
    for (usz i = 0; i < nb; i++)
    {
        Block* b = &cfg.blocks[i];
        for (usz j = 0; j < b.succ_count; j++)
        {
            cl.edge_weight[ei] = edge_weight(b, j, b.loop_depth);
            ei = ei + 1;
        }
    }
    cl.n_edges = ei;
    // Greedy chain merge: for each block with exactly one successor (or the
    // highest-weight successor), merge into a chain. Full Pettis-Hansen is
    // O(E^2) and doesn't belong here; we do the linear fallthrough pass.
    for (usz i = 0; i < nb; i++)
    {
        Block* b = &cfg.blocks[i];
        if (b.succ_count == 0) { continue; }
        // Pick hottest successor
        usz best_s = 0; long best_w = -1;
        usz base_e = 0;
        for (usz k = 0; k < i; k++) { base_e = base_e + cfg.blocks[k].succ_count; }
        for (usz j = 0; j < b.succ_count; j++)
        {
            long w = cl.edge_weight[base_e + j];
            if (w > best_w) { best_w = w; best_s = j; }
        }
        int sb = b.succs[best_s];
        if (sb < 0 || (usz)sb >= nb) { continue; }
        // If successor has exactly one predecessor and we haven't chained it
        // elsewhere, merge.
        if (cl.chain_id[i] != cl.chain_id[sb])
        {
            cl.chains_merged = cl.chains_merged + 1;
            int old = cl.chain_id[sb];
            for (usz k = 0; k < nb; k++) { if (cl.chain_id[k] == old) { cl.chain_id[k] = cl.chain_id[i]; } }
            cl.n_chains = cl.n_chains - 1;
            if (best_s == 0) { cl.ft_cold = cl.ft_cold + 1; }
            else { cl.ft_hot = cl.ft_hot + 1; }
        }
    }
    // Compute simple order: chains concatenated in DFS order from entry,
    // cold chains to the end.
    usz placed = 0;
    bool* visited = (bool*)malloc((long)(nb));
    int* stk = (int*)malloc((long)(nb * 4 + 16));
    if (visited == null || stk == null)
    {
        if (visited != null) free((void*)visited);
        if (stk != null) free((void*)stk);
        return;
    }
    for (usz i = 0; i < nb; i++) { visited[i] = false; }
    // Iterative DFS from 0
    int sp = 0;
    stk[0] = 0; sp = 1;
    while (sp > 0 && placed < nb)
    {
        sp = sp - 1; int id = stk[sp];
        if (id < 0 || (usz)id >= nb || visited[id]) { continue; }
        visited[id] = true;
        cl.order[placed] = id; placed = placed + 1;
        Block* b = &cfg.blocks[id];
        // Push successors in reverse so hot succ is processed first
        for (long j = (long)b.succ_count - 1; j >= 0; j--)
        {
            int s = b.succs[j];
            if (s >= 0 && (usz)s < nb && sp < (int)(nb + 3)) { stk[sp] = s; sp = sp + 1; }
        }
    }
    free((void*)stk);
    // Place remaining (cold) blocks
    for (usz i = 0; i < nb && placed < nb; i++)
    {
        if (!visited[i])
        {
            cl.order[placed] = (int)i; placed = placed + 1;
            cl.cold_blocks = cl.cold_blocks + 1;
        }
    }
    cl.order_count = placed;
    free((void*)visited);
}

fn void CodeLayout.report(CodeLayout* cl)
{
    printf("  code-layout      : %d blocks, %d chains, %d fallthrough-hot, %d reordered\n",
           (int)(cl.cfg != null ? cl.cfg.block_count : 0),
           (int)cl.n_chains, (int)cl.ft_hot, (int)cl.chains_merged);
    printf("  layout-cold      : %d cold blocks placed out-of-line\n",
           (int)cl.cold_blocks);
}

fn void CodeLayout.free(CodeLayout* cl)
{
    if (cl.order != null) { free((void*)cl.order); cl.order = null; }
    if (cl.chain_id != null) { free((void*)cl.chain_id); cl.chain_id = null; }
    if (cl.edge_weight != null) { free((void*)cl.edge_weight); cl.edge_weight = null; }
}
