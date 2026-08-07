// ============================================================================
// pfront_critpath.c3 — Critical path length estimator
// ----------------------------------------------------------------------------
// Computes the longest dependency chain through each CFG block (critical path
// length), useful for scheduling / superblock formation. The metric is in
// "cycles" estimated from a simple per-op cost model:
//    integer op = 1, load = 4, store = 4, float op = 3, call = 10, branch = 1
// The critical path through a block is the longest latency chain from any
// input (live-in) to any output (live-out/branch). Loops accumulate critical
// path around their back edge (multiplied by trip count estimate — we use
// a conservative 10 for hot loops).
//
// Counters are advisory.
// ============================================================================

module pfront_critpath;

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
alias Loop     = pfront_cfg::Loop;

extern fn int printf(char* fmt, ...);
extern fn void* malloc(usz size);
extern fn void  free(void* ptr);

struct CritPath
{
    Arena* arena;
    Cfg*   cfg;
    long*  cp_in;     // earliest start cycle for each block
    long*  cp_out;    // finish cycle
    long*  cost;      // per-block total cost
    long   max_path;
    long   loop_cp;
    usz    longest_bid;
    usz    n_blocks_heavy;
}

fn long op_cost(Node* n)
{
    if (n == null) { return 1; }
    switch (n.kind)
    {
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_STAR || op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT) { return 3; }
            if (op == Tk.TOKEN_PIPE || op == Tk.TOKEN_AMP || op == Tk.TOKEN_XOR) { return 1; }
            if (op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT) { return 1; }
            return 1;
        }
        case Nk.N_EXPR_CALL:    return 10;
        case Nk.N_STMT_ASSIGN: return 4;
        case Nk.N_EXPR_UNARY:  return 1;
        case Nk.N_EXPR_FIELD:  return 1;
        case Nk.N_EXPR_INDEX:  return 4;
        case Nk.N_EXPR_DEREF:  return 4;
        case Nk.N_EXPR_REF:    return 1;
        default: break;
    }
    return 1;
}

fn long block_cost(Block* b)
{
    if (b == null) { return 0; }
    long c = 0;
    for (usz i = 0; i < b.stmt_count; i++)
    {
        c = c + op_cost(b.stmts[i]);
    }
    if (b.term == TermKind.TERM_IF || b.term == TermKind.TERM_MATCH) { c = c + 1; }
    return c;
}

fn void CritPath.init(CritPath* cp, Arena* a)
{
    cp.arena = a; cp.cfg = null;
    cp.cp_in = null; cp.cp_out = null; cp.cost = null;
    cp.max_path = 0; cp.loop_cp = 0; cp.longest_bid = 0; cp.n_blocks_heavy = 0;
}

fn void CritPath.run_on_cfg(CritPath* cp, Cfg* cfg)
{
    if (cfg == null) { return; }
    cp.cfg = cfg;
    usz nb = cfg.block_count;
    cp.cp_in = (long*)malloc((long)(nb * 8));
    cp.cp_out = (long*)malloc((long)(nb * 8));
    cp.cost = (long*)malloc((long)(nb * 8));
    if (cp.cp_in == null || cp.cp_out == null || cp.cost == null) { return; }
    for (usz i = 0; i < nb; i++) { cp.cp_in[i] = 0; cp.cost[i] = block_cost(&cfg.blocks[i]); }
    // Simple longest path in topological-ish order: iterate to fixpoint.
    for (usz iter = 0; iter < nb + 4; iter++)
    {
        bool changed = false;
        for (usz i = 0; i < nb; i++)
        {
            Block* b = &cfg.blocks[i];
            long maxpred = 0;
            for (usz j = 0; j < b.pred_count; j++)
            {
                int p = b.preds[j];
                if (p >= 0 && (usz)p < nb && cp.cp_out[p] > maxpred) { maxpred = cp.cp_out[p]; }
            }
            if (cp.cp_in[i] != maxpred) { cp.cp_in[i] = maxpred; changed = true; }
            long finish = maxpred + cp.cost[i];
            // loop-depth multiplier
            long mult = 1;
            for (int d = 0; d < b.loop_depth; d++) { mult = mult * 10; if (mult > 1000) { mult = 1000; break; } }
            long real_finish = maxpred + cp.cost[i] * mult;
            if (cp.cp_out[i] != real_finish) { cp.cp_out[i] = real_finish; changed = true; }
            (void)finish;
            if (real_finish > cp.max_path) { cp.max_path = real_finish; cp.longest_bid = i; }
            if (cp.cost[i] > 50) { cp.n_blocks_heavy = cp.n_blocks_heavy + 1; }
        }
        if (!changed) { break; }
    }
    // Loop CP: sum around each loop's latches
    cp.loop_cp = 0;
    for (usz i = 0; i < cfg.loop_count; i++)
    {
        Loop* lp = &cfg.loops[i];
        long body = 0;
        for (usz j = 0; j < lp.block_count; j++)
        {
            int bid = lp.blocks[j];
            if (bid >= 0 && (usz)bid < nb) { body = body + cp.cost[bid]; }
        }
        if (body > cp.loop_cp) { cp.loop_cp = body; }
    }
}

fn void CritPath.report(CritPath* cp)
{
    printf("  crit-path        : longest %ld cycles, hot-loop body %ld cycles, heavy blocks=%d\n",
           cp.max_path, cp.loop_cp, (int)cp.n_blocks_heavy);
    printf("  crit-path-bid    : block %d on critical path\n",
           (int)cp.longest_bid);
}

fn void CritPath.free(CritPath* cp)
{
    if (cp.cp_in != null) { free((void*)cp.cp_in); cp.cp_in = null; }
    if (cp.cp_out != null) { free((void*)cp.cp_out); cp.cp_out = null; }
    if (cp.cost != null) { free((void*)cp.cost); cp.cost = null; }
}
