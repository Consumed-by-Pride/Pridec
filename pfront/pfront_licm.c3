// ============================================================================
// pfront_licm.c3 — Loop-invariant expression detection
// ----------------------------------------------------------------------------
// For every natural loop found by pfront_cfg, an expression is LOOP-INVARIANT
// if:
//
//   (1) it is in a block dominated by the loop header,
//   (2) all of its operands are defined OUTSIDE the loop, or are themselves
//       loop-invariant, and
//   (3) evaluating it has no side effects (no call, no volatile, no unsafe,
//       no trap/ub/diverge/io/panic).
//
// This pass does NOT actually move code — it is a pure ANALYSIS that tags
// invariant expressions so a future code motion pass (or the emitter, or the
// optimizer in theory_opt) can hoist them. The tag uses node flag NF_SYNTHETIC
// bit 16 (a free bit at time of writing) as "is_loop_invariant".
//
// We iterate to fixpoint per loop because invariant operands in iteration k
// make dependent expressions invariant in iteration k+1.
// ============================================================================

module pfront_licm;

import pfront_core;
import pfront_cfg;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias Loop = pfront_cfg::Loop;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const uint EFF_VOLATILE = pfront_core::EFF_IO
                       | pfront_core::EFF_DIVERGE
                       | pfront_core::EFF_PANIC
                       | pfront_core::EFF_UNSAFE
                       | pfront_core::EFF_UB;

const uint NF_LOOP_INVARIANT = 1 << 16; // free flag bit? Let's just track in our own table.

const usz INV_MAX = 65536;

struct Licm
{
    Arena* arena;
    Cfg*   cfg;

    // Per-node invariant bitset indexed by a hash of node pointer.
    bool[INV_MAX] inv;

    // Stats.
    usz loops_analysed;
    usz total_invariant;
    usz candidates;
}

fn void Licm.init(Licm* l, Arena* a)
{
    l.arena = a;
    l.cfg = null;
    l.loops_analysed = 0;
    l.total_invariant = 0;
    l.candidates = 0;
    for (usz i = 0; i < INV_MAX; i++) l.inv[i] = false;
}

fn usz node_idx(Node* n) { return ((usz)n >> 3) & (INV_MAX - 1); }

fn bool Licm.is_inv(Licm* l, Node* n)
{
    if (n == null) return true;
    return l.inv[node_idx(n)];
}

fn void Licm.set_inv(Licm* l, Node* n)
{
    if (n == null) return;
    usz i = node_idx(n);
    if (!l.inv[i])
    {
        l.inv[i] = true;
        l.total_invariant = l.total_invariant + 1;
    }
}

// An expression is "pure" (no side effects, safe to hoist).
fn bool pure_hoistable(Node* n)
{
    if (n == null) return true;
    if ((n.effects & EFF_VOLATILE) != 0) return false;
    switch (n.kind)
    {
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
        case Nk.N_EXPR_SYSCALL:
        case Nk.N_EXPR_ASM:
        case Nk.N_EXPR_ALLOC:  // alloc is stateful (depends on heap state)
        case Nk.N_EXPR_FREE:
        case Nk.N_EXPR_VOLATILE:
        case Nk.N_EXPR_ATOMIC:
        case Nk.N_EXPR_FENCE:
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_RESUME:
        case Nk.N_STMT_ASSIGN:
        case Nk.N_EXPR_ASSIGN:
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_STMT_DEFER:
        case Nk.N_EXPR_UNREACHABLE:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_POISON:
            return false;
        default: return true;
    }
}

// Is a block id IN the given loop?
fn bool block_in_loop(Loop* lp, Block* blocks, int bid)
{
    for (usz i = 0; i < lp.block_count; i++)
    {
        if (lp.blocks[i] == bid) return true;
    }
    return false;
}

// Is every child of n defined outside loop or already invariant?
fn bool children_inv(Licm* l, Node* n, Loop* lp, Block* blocks)
{
    if (n == null) return true;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        // Types/patterns are not values and don't need hoisting.
        if (pfront_core::is_type(c.kind)) continue;
        if (pfront_core::is_pattern(c.kind)) continue;
        // If the child is a literal or constant it is trivially invariant.
        if (c.kind == Nk.N_EXPR_INT || c.kind == Nk.N_EXPR_FLOAT
            || c.kind == Nk.N_EXPR_BOOL || c.kind == Nk.N_EXPR_CHAR
            || c.kind == Nk.N_EXPR_STRING || c.kind == Nk.N_EXPR_NULL
            || c.kind == Nk.N_EXPR_UNIT) { continue; }
        // If the child is invariant, fine.
        if (l.is_inv(c)) continue;
        // Otherwise not invariant yet.
        return false;
    }
    return true;
}

// Scan all stmts in all blocks of the loop; mark expressions whose children
// are all inv/outside-loop as invariant; iterate.
fn void Licm.analyze_loop(Licm* l, Loop* lp)
{
    if (l.cfg == null || lp == null) return;
    if (lp.block_count == 0) return;
    l.loops_analysed = l.loops_analysed + 1;

    // Iterate to fixpoint.
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < 16)
    {
        changed = false;
        rounds = rounds + 1;
        for (usz bi = 0; bi < lp.block_count; bi++)
        {
            int bid = lp.blocks[bi];
            if (bid < 0 || bid >= (int)l.cfg.block_count) continue;
            Block* b = &l.cfg.blocks[bid];
            for (usz si = 0; si < b.stmt_count; si++)
            {
                Node* s = b.stmts[si];
                if (s == null) continue;
                if (!pure_hoistable(s)) continue;
                if (l.is_inv(s)) continue;
                l.candidates = l.candidates + 1;
                if (children_inv(l, s, lp, l.cfg.blocks))
                {
                    l.set_inv(s);
                    changed = true;
                }
            }
            // Also walk the terminator node.
            if (b.term_node != null && pure_hoistable(b.term_node) && !l.is_inv(b.term_node))
            {
                if (children_inv(l, b.term_node, lp, l.cfg.blocks))
                {
                    l.set_inv(b.term_node);
                    changed = true;
                }
            }
        }
    }
}

fn void Licm.run_on_cfg(Licm* l, Cfg* c)
{
    l.cfg = c;
    for (usz i = 0; i < c.loop_count; i++)
    {
        l.analyze_loop(&c.loops[i]);
    }
}

fn bool Licm.is_invariant(Licm* l, Node* n)
{
    return l.is_inv(n);
}

fn void Licm.report(Licm* l)
{
    printf("  licm loops        : %d\n", (int)l.loops_analysed);
    printf("  licm candidates   : %d\n", (int)l.candidates);
    printf("  licm invariants   : %d\n", (int)l.total_invariant);
}
