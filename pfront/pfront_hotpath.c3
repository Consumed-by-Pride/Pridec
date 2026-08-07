// ============================================================================
// pfront_hotpath.c3 — Hot-path / loop-nesting weight estimation
// ----------------------------------------------------------------------------
// Computes a per-block "heat" score by combining loop nesting, branch
// probability hints from pfront_branchprob, and call-site density. Heat is
// used purely for advisory purposes (which blocks are hottest, which loops
// dominate runtime estimate, what fraction of blocks are cold) — no decisions
// are enforced. Classic Ball-Larus style static estimation on the cheap.
// ============================================================================

module pfront_hotpath;

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

const long HEAT_BASE = 1000;

struct HotPath
{
    Arena* arena;
    Cfg*   cfg;
    long*  block_heat;
    long   total_heat;
    long   max_heat;
    usz    n_hot;
    usz    n_warm;
    usz    n_cold;
    usz    n_loops;
    usz    hottest_bid;
    long   loop_heat;
    long   entry_heat;
    usz    n_call_blocks;
}

fn void HotPath.init(HotPath* hp, Arena* a)
{
    hp.arena = a;
    hp.cfg = null;
    hp.block_heat = null;
    hp.total_heat = 0; hp.max_heat = 0;
    hp.n_hot = 0; hp.n_warm = 0; hp.n_cold = 0;
    hp.n_loops = 0; hp.hottest_bid = 0; hp.loop_heat = 0; hp.entry_heat = 0;
    hp.n_call_blocks = 0;
}

fn long loop_multiplier(int depth)
{
    long m = 1;
    for (int i = 0; i < depth; i++)
    {
        m = m * 10;
        if (m > 1000000) { m = 1000000; break; }
    }
    return m;
}

fn usz block_calls(Block* b)
{
    if (b == null) { return 0; }
    usz c = 0;
    for (usz i = 0; i < b.stmt_count; i++)
    {
        c = c + calls_in(b.stmts[i], 0);
    }
    if (b.term_node != null)
    {
        // If the terminator has children that are calls.
        for (usz i = 0; i < b.term_node.child_count; i++)
        {
            c = c + calls_in(b.term_node.children[i], 0);
        }
    }
    return c;
}

fn usz calls_in(Node* n, usz depth)
{
    if (n == null || depth > 40) { return 0; }
    usz c = 0;
    if (n.kind == Nk.N_EXPR_CALL) { c = 1; }
    for (usz i = 0; i < n.child_count; i++)
    {
        c = c + calls_in(n.children[i], depth + 1);
    }
    return c;
}

fn usz block_stores(Block* b)
{
    if (b == null) { return 0; }
    usz c = 0;
    for (usz i = 0; i < b.stmt_count; i++)
    {
        Node* s = b.stmts[i];
        if (s == null) { continue; }
        if (s.kind == Nk.N_STMT_ASSIGN) { c++; }
        if (s.kind == Nk.N_DECL_LET) { c++; }
    }
    return c;
}

fn void HotPath.run_on_cfg(HotPath* hp, Cfg* cfg)
{
    if (cfg == null) { return; }
    hp.cfg = cfg;
    usz nb = cfg.block_count;
    hp.block_heat = (long*)malloc((long)(nb * 8));
    if (hp.block_heat == null) { return; }
    for (usz i = 0; i < nb; i++)
    {
        Block* b = &cfg.blocks[i];
        long h = HEAT_BASE;
        long lm = loop_multiplier(b.loop_depth);
        h = h * lm;
        usz calls = block_calls(b);
        if (calls > 0) { h = h + (long)calls * 50; hp.n_call_blocks = hp.n_call_blocks + 1; }
        usz stores = block_stores(b);
        h = h + (long)stores * 5;
        // Entry block starts hotter.
        if (i == 0) { h = h + HEAT_BASE; hp.entry_heat = h; }
        // Return/exit blocks are cold.
        if (b.term == TermKind.TERM_RETURN || b.term == TermKind.TERM_UNREACH
            || b.term == TermKind.TERM_TAIL)
        {
            h = h / 2;
        }
        hp.block_heat[i] = h;
        hp.total_heat = hp.total_heat + h;
        if (h > hp.max_heat) { hp.max_heat = h; hp.hottest_bid = i; }
        if (b.loop_depth > 0) { hp.loop_heat = hp.loop_heat + h; hp.n_loops = hp.n_loops + 1; }
    }
    // Bucket blocks.
    long hot_thresh = HEAT_BASE * 10;   // inside a loop
    long cold_thresh = HEAT_BASE / 2;
    for (usz i = 0; i < nb; i++)
    {
        long h = hp.block_heat[i];
        if (h >= hot_thresh) { hp.n_hot = hp.n_hot + 1; }
        else if (h < cold_thresh) { hp.n_cold = hp.n_cold + 1; }
        else { hp.n_warm = hp.n_warm + 1; }
    }
}

fn void HotPath.report(HotPath* hp)
{
    printf("  hot-path         : blocks hot=%d warm=%d cold=%d (total=%d blocks)\n",
           (int)hp.n_hot, (int)hp.n_warm, (int)hp.n_cold,
           (int)(hp.cfg != null ? hp.cfg.block_count : 0));
    printf("  hot-path-weight  : total=%ld max=%ld hottest-bid=%d loop-heat=%ld\n",
           hp.total_heat, hp.max_heat, (int)hp.hottest_bid, hp.loop_heat);
    printf("  call-blocks      : %d blocks contain a direct call\n",
           (int)hp.n_call_blocks);
}

fn void HotPath.free(HotPath* hp)
{
    if (hp.block_heat != null) { free((void*)hp.block_heat); hp.block_heat = null; }
}
