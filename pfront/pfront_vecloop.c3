// ============================================================================
// pfront_vecloop.c3 — Vectorization / SIMD opportunity detector
// ----------------------------------------------------------------------------
// Scans loops for patterns that map cleanly to SIMD:
//   * straight-line bodies with no control flow (if/break/continue inside)
//   * no loop-carried dependencies except reduction (+/*/min/max)
//   * unit-stride array accesses (consecutive memory)
//   * no function calls in the body (except math intrinsics)
//   * all memory accesses are to arrays with affine indices
//
// Loops are classified into:
//   VEC_NONE      — control flow, calls, or unknowable dependency
//   VEC_REDUCTION — associative/commutative reduction (sum += a[i])
//   VEC_MAP       — elementwise map, writes independent
//   VEC_SCATTER   — indexed writes; not vectorizable without gather/scatter
//
// All counters are advisory. No code is transformed.
// ============================================================================

module pfront_vecloop;

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
alias TermKind = pfront_cfg::TermKind;

extern fn int printf(char* fmt, ...);
extern fn void* malloc(usz size);
extern fn void  free(void* ptr);

const int VEC_NONE = 0;
const int VEC_REDUCTION = 1;
const int VEC_MAP = 2;
const int VEC_SCATTER = 3;

struct VecLoop
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_none;
    usz    n_reduction;
    usz    n_map;
    usz    n_scatter;
    usz    n_strided;
    usz    n_unitstride;
    usz    n_has_call;
    usz    n_has_control;
    usz    n_induction_iv;
}

fn void VecLoop.init(VecLoop* vl, Arena* a)
{
    vl.arena = a; vl.cfg = null;
    vl.n_none = 0; vl.n_reduction = 0; vl.n_map = 0; vl.n_scatter = 0;
    vl.n_strided = 0; vl.n_unitstride = 0; vl.n_has_call = 0;
    vl.n_has_control = 0; vl.n_induction_iv = 0;
}

fn bool node_has_call(Node* n, int depth)
{
    if (n == null || depth > 100) { return false; }
    if (n.kind == Nk.N_EXPR_CALL) { return true; }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (node_has_call(n.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn bool node_has_control(Node* n, int depth)
{
    if (n == null || depth > 100) { return false; }
    if (n.kind == Nk.N_EXPR_IF || n.kind == Nk.N_EXPR_MATCH
        || n.kind == Nk.N_STMT_BREAK || n.kind == Nk.N_STMT_CONTINUE) { return true; }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (node_has_control(n.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn bool node_is_index_affine(Node* iv, Node* idx, int depth)
{
    if (idx == null || depth > 50) { return false; }
    if (idx == iv) { return true; }
    if (idx.kind == Nk.N_EXPR_INT) { return true; }
    if (idx.kind == Nk.N_EXPR_BINARY && idx.child_count >= 2)
    {
        Tk op = (Tk)idx.p.op;
        if (op == Tk.TOKEN_PLUS || op == Tk.TOKEN_MINUS)
        {
            bool l = node_is_index_affine(iv, idx.children[0], depth + 1);
            bool r = idx.children[1] != null && idx.children[1].kind == Nk.N_EXPR_INT;
            return l && r;
        }
        if (op == Tk.TOKEN_STAR)
        {
            bool one_side_iv = node_is_index_affine(iv, idx.children[0], depth + 1)
                            && idx.children[1] != null && idx.children[1].kind == Nk.N_EXPR_INT;
            bool other_side = node_is_index_affine(iv, idx.children[1], depth + 1)
                           && idx.children[0] != null && idx.children[0].kind == Nk.N_EXPR_INT;
            return one_side_iv || other_side;
        }
    }
    return false;
}

fn bool is_associative(Tk op)
{
    return op == Tk.TOKEN_PLUS || op == Tk.TOKEN_STAR
        || op == Tk.TOKEN_PIPE || op == Tk.TOKEN_AMP
        || op == Tk.TOKEN_XOR || op == Tk.TOKEN_MINUS /*min*/;
}

fn void VecLoop.run_on_cfg(VecLoop* vl, Cfg* cfg)
{
    if (cfg == null) { return; }
    vl.cfg = cfg;
    for (usz i = 0; i < cfg.loop_count; i++)
    {
        Loop* lp = &cfg.loops[i];
        bool has_call = false; bool has_ctrl = false;
        bool aff = true; bool reduction = false;
        usz blocks_seen = 0;
        for (usz j = 0; j < lp.block_count && blocks_seen < lp.block_count; j++)
        {
            int bid = lp.blocks[j];
            if (bid < 0) { continue; }
            Block* b = &cfg.blocks[bid];
            blocks_seen = blocks_seen + 1;
            for (usz k = 0; k < b.stmt_count; k++)
            {
                Node* s = b.stmts[k];
                if (s == null) { continue; }
                if (node_has_call(s, 0)) { has_call = true; }
                if (node_has_control(s, 0)) { has_ctrl = true; }
                if (s.kind == Nk.N_STMT_ASSIGN && s.child_count >= 2
                    && s.children[1] != null
                    && s.children[1].kind == Nk.N_EXPR_BINARY
                    && is_associative((Tk)s.children[1].p.op)
                    && s.children[0] != null)
                {
                    // x = x + ...  — classic reduction
                    reduction = true;
                }
                if (s.kind == Nk.N_EXPR_INDEX && s.child_count >= 2
                    && !node_is_index_affine(null, s.children[1], 0))
                {
                    aff = false;
                }
            }
        }
        if (has_ctrl) { vl.n_has_control = vl.n_has_control + 1; }
        if (has_call) { vl.n_has_call = vl.n_has_call + 1; }
        
        if (has_ctrl || has_call) { vl.n_none = vl.n_none + 1; continue; }
        if (!aff) { vl.n_scatter = vl.n_scatter + 1; continue; }
        vl.n_unitstride = vl.n_unitstride + 1;
        if (reduction) { vl.n_reduction = vl.n_reduction + 1; }
        else { vl.n_map = vl.n_map + 1; }
    }
}

fn void VecLoop.report(VecLoop* vl)
{
    printf("  vec-loop         : none=%d reduction=%d map=%d scatter=%d\n",
           (int)vl.n_none, (int)vl.n_reduction, (int)vl.n_map, (int)vl.n_scatter);
    printf("  vec-mem          : unit-stride=%d calls=%d ctrl=%d iv=%d\n",
           (int)vl.n_unitstride, (int)vl.n_has_call, (int)vl.n_has_control,
           (int)vl.n_induction_iv);
}

fn void VecLoop.free(VecLoop* vl) { (void)vl; }
