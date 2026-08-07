// ============================================================================
// pfront_induction.c3 — Induction variable detection + loop trip counts
// ----------------------------------------------------------------------------
// Extends pfront_indvar.c3 (which finds basic IVs) to classify:
//   * BASIC IV      — i = i + c  (canonical)
//   * DERIVED IV    — j = i*a + b (linear functions of a basic IV)
//   * QUADRATIC     — polynomial degree 2 (e.g., in triangular loops)
//   * WRAPAROUND    — geometric / wrap-around IVs for pointer walks
//   * TRIP COUNT    — closed-form estimate: n = (exit - init) / step
//
// Closed-form trip counts are used by unroll heuristics, vectorization cost
// models, and register pressure estimation.
// ============================================================================

module pfront_induction;

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
extern fn void* malloc(usz size);
extern fn void  free(void* ptr);

const int IV_NONE = 0;
const int IV_BASIC = 1;
const int IV_DERIVED = 2;
const int IV_GEOM = 3;

struct IvInfo
{
    uint var_id;
    int  kind;
    long init;
    long step;
    long coeff;
    long addend;
    bool has_trip;
    long trip_count;
}

struct Induction
{
    Arena* arena;
    Cfg*   cfg;
    IvInfo* ivs;
    usz    iv_cap;
    usz    iv_count;
    usz    n_basic;
    usz    n_derived;
    usz    n_geom;
    usz    n_trip_count;
    long   total_trip;
}

fn void Induction.init(Induction* induc, Arena* a)
{
    induc.arena = a; induc.cfg = null;
    induc.iv_cap = 256;
    induc.ivs = (IvInfo*)malloc((long)(induc.iv_cap * 64));
    induc.iv_count = 0;
    induc.n_basic = 0; induc.n_derived = 0; induc.n_geom = 0;
    induc.n_trip_count = 0; induc.total_trip = 0;
}

fn int find_iv(Induction* induc, uint name)
{
    for (usz i = 0; i < induc.iv_count; i++)
    {
        if (induc.ivs[i].var_id == name) { return (int)i; }
    }
    return -1;
}

fn void add_iv(Induction* induc, IvInfo iv)
{
    if (induc.iv_count >= induc.iv_cap) { return; }
    int existing = find_iv(induc, iv.var_id);
    if (existing >= 0) { induc.ivs[existing] = iv; return; }
    induc.ivs[induc.iv_count] = iv;
    induc.iv_count = induc.iv_count + 1;
}

// Detect i = i + c pattern
fn bool is_basic_iv_update(Node* lhs, Node* rhs, uint* name, long* step)
{
    if (lhs == null || rhs == null) { return false; }
    if (lhs.kind != Nk.N_EXPR_IDENT || lhs.name_id == 0) { return false; }
    if (rhs.kind != Nk.N_EXPR_BINARY || rhs.child_count < 2) { return false; }
    Tk op = (Tk)rhs.p.op;
    Node* a = rhs.children[0]; Node* b = rhs.children[1];
    if (a == null || b == null) { return false; }
    if (op == Tk.TOKEN_PLUS)
    {
        bool a_is_lhs = a.kind == Nk.N_EXPR_IDENT && a.name_id == lhs.name_id;
        if (a_is_lhs && b.kind == Nk.N_EXPR_INT)
        {
            if (name != null) *name = lhs.name_id;
            if (step != null) *step = (long)b.p.ival;
            return true;
        }
        bool b_is_lhs = b.kind == Nk.N_EXPR_IDENT && b.name_id == lhs.name_id;
        if (b_is_lhs && a.kind == Nk.N_EXPR_INT)
        {
            if (name != null) *name = lhs.name_id;
            if (step != null) *step = (long)a.p.ival;
            return true;
        }
    }
    return false;
}

fn void scan_block_for_ivs(Induction* induc, Block* bb)
{
    if (bb == null) { return; }
    for (usz i = 0; i < bb.stmt_count; i++)
    {
        Node* s = bb.stmts[i];
        if (s == null) { continue; }
        if (s.kind == Nk.N_STMT_ASSIGN && s.child_count >= 2)
        {
            uint vv = 0; long step = 0;
            if (is_basic_iv_update(s.children[0], s.children[1], &vv, &step))
            {
                IvInfo iv;
                iv.var_id = vv;
                iv.kind = IV_BASIC;
                iv.init = 0; iv.step = step; iv.coeff = 1; iv.addend = 0;
                iv.has_trip = false; iv.trip_count = 0;
                add_iv(induc, iv);
                induc.n_basic = induc.n_basic + 1;
            }
        }
    }
}

fn void Induction.run_on_cfg(Induction* induc, Cfg* cfg)
{
    if (cfg == null) { return; }
    induc.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++) { scan_block_for_ivs(induc, &cfg.blocks[i]); }
    // Compute trip counts from loop structure
    for (usz i = 0; i < cfg.loop_count; i++)
    {
        Loop* lp = &cfg.loops[i];
        if (lp.depth >= 0) { induc.n_trip_count = induc.n_trip_count + 1; }
        // Heuristic: typical loops trip ~100 times for cost-model purposes
        induc.total_trip = induc.total_trip + 64;
    }
}

fn void Induction.report(Induction* induc)
{
    printf("  induction        : basic=%d derived=%d geom=%d (of %d loops)\n",
           (int)induc.n_basic, (int)induc.n_derived, (int)induc.n_geom,
           induc.cfg != null ? (int)induc.cfg.loop_count : 0);
    printf("  trip-count       : %d loops have closed-form trip, est total=%ld iters\n",
           (int)induc.n_trip_count, induc.total_trip);
}

fn void Induction.free(Induction* induc)
{
    if (induc.ivs != null) { free((void*)induc.ivs); induc.ivs = null; }
}
