// ============================================================================
// pfront_regpress.c3 — Register pressure estimation per block and loop
// ----------------------------------------------------------------------------
// Register pressure is the number of simultaneously live values at a point.
// When pressure exceeds physical register count, the register allocator
// (downstream) must spill. Estimating pressure at the AST stage is useful
// because:
//
//   - LICM must NOT hoist loop-invariant computations when pressure is
//     already high in the loop (hoisting extends live ranges and increases
//     spills, which is slower than recomputing).
//   - Unrolling decisions depend on pressure: unrolling a low-pressure
//     loop is almost always win; unrolling a high-pressure loop can blow
//     up spill cost.
//   - Inlining decisions are pressure-sensitive (callee live ranges add
//     to caller pressure around the call site).
//
// We compute a BLOCK-LOCAL estimate: walk statements backwards counting
// defs (which kill live ranges) and uses (which extend them upward). This
// is the classic linear-scan style backward pass, simplified because we
// do not yet have SSA or a precise live-range representation — we
// approximate by using `name_id` for identifiers.
//
// Output: per-block max pressure, per-loop max pressure, counts.
// ============================================================================

module pfront_regpress;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias Loop  = pfront_cfg::Loop;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz RP_SET = 4096;

struct RegPress
{
    Arena* arena;
    Cfg*   cfg;

    // Per-block max pressure.
    usz*   block_max;
    usz    total_blocks;
    usz    over_16;      // blocks with pressure > 16 (typical ISA reg count)
    usz    over_32;      // pressure > 32
    usz    max_pressure;
    usz    loops_above_16;
    usz    hot_loops;    // loops with high pressure AND high depth (bad)
}

fn void RegPress.init(RegPress* rp, Arena* a)
{
    rp.arena = a;
    rp.cfg = null;
    rp.block_max = null;
    rp.total_blocks = 0;
    rp.over_16 = 0;
    rp.over_32 = 0;
    rp.max_pressure = 0;
    rp.loops_above_16 = 0;
    rp.hot_loops = 0;
}

// Backwards scan of a block: compute max pressure.
fn usz rp_scan_block(RegPress* rp, Block* b)
{
    if (rp == null || b == null) return 0;
    char* live = (char*)calloc(RP_SET, 1);
    if (live == null) return 0;
    usz cur = 0;
    usz mx = 0;
    // Walk stmts backwards.
    for (long si = (long)b.stmt_count - 1; si >= 0; si--)
    {
        Node* s = b.stmts[si];
        // A node "defines" (kills) a name if it's a let/assign that BINDS.
        usz def = 0;
        if (s != null && (s.kind == Nk.N_DECL_LET || s.kind == Nk.N_STMT_ASSIGN))
        {
            Node* nm = (s.child_count >= 1) ? s.children[0] : null;
            if (nm != null && nm.kind == Nk.N_EXPR_IDENT) def = nm.name_id;
        }
        // If def is live, remove it (the def "starts" here; uses above don't see it).
        if (def != 0)
        {
            usz slot = def & (RP_SET - 1);
            if (live[slot] != 0) { live[slot] = 0; cur--; }
        }
        // Count uses in s that are identifiers.
        cur = cur + rp_add_uses(s, live);
        if (cur > mx) mx = cur;
    }
    free((void*)live);
    return mx;
}

// Walk a subtree, mark identifiers as live; returns number of NEW liveness marks added.
fn usz rp_add_uses(Node* n, char* live)
{
    if (n == null) return 0;
    usz added = 0;
    // defs in nested lets/assigns: don't count their LHS as a use, and the
    // LHS is defined inside this subtree (so its uses here are LOCAL).
    // Simpler: just count ident uses everywhere; nested lets inside a stmt
    // are rare enough that this overestimate is acceptable.
    if (n.kind == Nk.N_EXPR_IDENT && n.name_id != 0)
    {
        usz slot = n.name_id & (RP_SET - 1);
        if (live[slot] == 0) { live[slot] = 1; added = 1; }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        added = added + rp_add_uses(n.children[i], live);
    }
    return added;
}

fn void RegPress.run_on_cfg(RegPress* rp, Cfg* cfg)
{
    if (cfg == null) return;
    rp.cfg = cfg;
    usz nb = cfg.block_count;
    rp.block_max = (usz*)malloc(nb * 8);
    if (rp.block_max == null) return;
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &cfg.blocks[bi];
        usz m = rp_scan_block(rp, b);
        rp.block_max[bi] = m;
        rp.total_blocks++;
        if (m > rp.max_pressure) rp.max_pressure = m;
        if (m > 16) rp.over_16++;
        if (m > 32) rp.over_32++;
    }
    // Loop pressure: max of blocks in each loop.
    for (usz li = 0; li < cfg.loop_count; li++)
    {
        Loop* lp = &cfg.loops[li];
        usz lm = 0;
        // Loops in our CFG have `blocks` (int*) and `block_count`.
        if (lp.blocks != null)
        {
            for (usz bi = 0; bi < lp.block_count; bi++)
            {
                int bid = lp.blocks[bi];
                if (bid >= 0 && (usz)bid < nb)
                {
                    if (rp.block_max[bid] > lm) lm = rp.block_max[bid];
                }
            }
        }
        if (lm > 16) rp.loops_above_16++;
        if (lm > 16 && lp.depth >= 2) rp.hot_loops++;
    }
}

fn void RegPress.report(RegPress* rp)
{
    printf("  regpress blocks  : %d, max %d live, >16: %d, >32: %d\n",
           (int)rp.total_blocks, (int)rp.max_pressure,
           (int)rp.over_16, (int)rp.over_32);
    printf("  regpress loops>16: %d, hot (depth>=2): %d\n",
           (int)rp.loops_above_16, (int)rp.hot_loops);
}

fn void RegPress.free(RegPress* rp)
{
    free((void*)rp.block_max);
    rp.block_max = null;
}
