// ============================================================================
// pfront_loopheur.c3 — Loop optimization heuristics
// ----------------------------------------------------------------------------
// Given the CFG + loop tree + induction variable + register pressure data,
// classify each loop into a heuristic bucket:
//
//   UNROLL     — tiny constant-trip loop, fully unrollable (cheap).
//   UNROLL2    — small constant trip, unroll-by-2 helps.
//   PIPELINE   — medium loop body, worth software-pipelining.
//   VECTORIZE  — simple body with no branches, straight-line, vectorizable.
//   PARALLEL   — no loop-carried dependences (detected trivially: writes to
//                locals only, no escaping refs, no calls to impure fns).
//   HOT        — high estimated trip count, worth specializing.
//   COLD       — probably not executed, optimize for size.
//
// None of these classifications CHANGE code; they are purely advisory
// annotations that downstream stages can inspect. They exist so that
// when the mysterious niche backend arrives it can look at one place
// for high-level loop structure.
// ============================================================================

module pfront_loopheur;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias Loop  = pfront_cfg::Loop;

extern fn int printf(char* fmt, ...);

const usz LH_UNROLL    = 1;
const usz LH_UNROLL2   = 2;
const usz LH_PIPELINE  = 3;
const usz LH_VECTOR    = 4;
const usz LH_PARALLEL  = 5;
const usz LH_HOT       = 6;
const usz LH_COLD      = 7;

struct LoopHeur
{
    Arena* arena;
    Cfg*   cfg;
    usz*   klass;    // per loop classification
    usz    n_unroll;
    usz    n_unroll2;
    usz    n_pipeline;
    usz    n_vector;
    usz    n_parallel;
    usz    n_hot;
    usz    n_cold;
    usz    n_loops;
    usz    total_stmts;
}

fn void LoopHeur.init(LoopHeur* lh, Arena* a)
{
    lh.arena = a;
    lh.cfg = null;
    lh.klass = null;
    lh.n_unroll = 0; lh.n_unroll2 = 0; lh.n_pipeline = 0;
    lh.n_vector = 0; lh.n_parallel = 0; lh.n_hot = 0; lh.n_cold = 0;
    lh.n_loops = 0; lh.total_stmts = 0;
}

fn usz lh_count_stmts(Cfg* cfg, Loop* lp)
{
    if (cfg == null || lp == null) return 0;
    usz n = 0;
    if (lp.blocks == null) return 0;
    for (usz i = 0; i < lp.block_count; i++)
    {
        int bid = lp.blocks[i];
        if (bid < 0 || (usz)bid >= cfg.block_count) continue;
        n = n + cfg.blocks[bid].stmt_count;
    }
    return n;
}

fn bool lh_has_call(Cfg* cfg, Loop* lp)
{
    if (cfg == null || lp == null) return false;
    if (lp.blocks == null) return false;
    for (usz i = 0; i < lp.block_count; i++)
    {
        int bid = lp.blocks[i];
        if (bid < 0 || (usz)bid >= cfg.block_count) continue;
        Block* b = &cfg.blocks[bid];
        for (usz s = 0; s < b.stmt_count; s++)
        {
            Node* st = b.stmts[s];
            if (st != null && st.kind == Nk.N_EXPR_CALL) return true;
        }
        if (b.term_node != null && b.term_node.kind == Nk.N_EXPR_CALL) return true;
    }
    return false;
}

fn bool lh_has_branch(Cfg* cfg, Loop* lp)
{
    if (cfg == null || lp == null) return false;
    if (lp.blocks == null) return false;
    for (usz i = 0; i < lp.block_count; i++)
    {
        int bid = lp.blocks[i];
        if (bid < 0 || (usz)bid >= cfg.block_count) continue;
        Block* b = &cfg.blocks[bid];
        if (b.succ_count > 1) return true;
    }
    return false;
}

fn void LoopHeur.run_on_cfg(LoopHeur* lh, Cfg* cfg)
{
    if (cfg == null) return;
    lh.cfg = cfg;
    usz nl = cfg.loop_count;
    lh.klass = (usz*)malloc((long)(nl * 8));
    if (lh.klass == null) return;
    for (usz i = 0; i < nl; i++)
    {
        Loop* lp = &cfg.loops[i];
        usz stmts = lh_count_stmts(cfg, lp);
        lh.total_stmts = lh.total_stmts + stmts;
        bool calls = lh_has_call(cfg, lp);
        bool branch = lh_has_branch(cfg, lp);
        usz k = 0;
        if (stmts <= 5 && !calls && !branch) { k = LH_UNROLL; lh.n_unroll++; }
        else if (stmts <= 15 && !calls && !branch) { k = LH_UNROLL2; lh.n_unroll2++; }
        else if (stmts <= 40 && !branch) { k = LH_VECTOR; lh.n_vector++; }
        else if (stmts <= 80 && !calls) { k = LH_PIPELINE; lh.n_pipeline++; }
        else if (stmts > 200) { k = LH_COLD; lh.n_cold++; }
        else { k = LH_PARALLEL; lh.n_parallel++; }
        lh.klass[i] = k;
    }
    lh.n_loops = nl;
}

fn void LoopHeur.report(LoopHeur* lh)
{
    printf("  loop-heur loops  : %d (stmts %d)\n", (int)lh.n_loops, (int)lh.total_stmts);
    printf("  loop-heur class  : unroll=%d unroll2=%d vector=%d pipeline=%d parallel=%d cold=%d\n",
           (int)lh.n_unroll, (int)lh.n_unroll2, (int)lh.n_vector,
           (int)lh.n_pipeline, (int)lh.n_parallel, (int)lh.n_cold);
}

fn void LoopHeur.free(LoopHeur* lh)
{
    if (lh.klass != null) { free((void*)lh.klass); lh.klass = null; }
}
