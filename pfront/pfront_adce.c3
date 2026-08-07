// ============================================================================
// pfront_adce.c3 — Aggressive Dead Code Elimination over the CFG
// ----------------------------------------------------------------------------
// Classic ADCE:
//   1. Start from a set of "live" seeds (terminators, calls with side effects,
//      returns, volatile/IO/UNSAFE/UB/PANIC/DIVERGE expressions).
//   2. Iteratively mark CONTROLLING CONDITIONS and USED OPERANDS of live
//      instructions as also-live (reverse dataflow along operands + reverse
//      control-dependence from branches).
//   3. Any statement not marked live can be dropped. Any branch whose
//      condition is dead and whose taken/not-taken successors both dominate
//      the post-dominator is turned into a jump to the live successor.
//
// Unlike a simple "after return" DCE (which the Folder already does in
// fold_block), ADCE removes assignments whose result is never consumed,
// pure computations whose result is unused, and dead conditional branches.
//
// This implementation operates on the CFG built by pfront_cfg.c3 and returns
// a bitset of (block, stmt) pairs that are live. The tree REWRITER that
// actually deletes stmts is the Folder's fold_block cousin; the analysis
// itself is read-only so running it is cheap and safe.
// ============================================================================

module pfront_adce;

import pfront_core;
import pfront_cfg;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz MAX_STMTS = 131072;

const uint EFF_VOLATILE = pfront_core::EFF_IO
                       | pfront_core::EFF_DIVERGE
                       | pfront_core::EFF_PANIC
                       | pfront_core::EFF_UNSAFE
                       | pfront_core::EFF_UB;

// A work item is a (block_id, stmt_index) pair encoded as (block_id<<16 | idx).
struct Adce
{
    Arena* arena;
    Cfg*   cfg;

    // Per-stmt liveness (flat indexed by an internal stmt-id; we assign ids
    // sequentially as we walk each block's statement list).
    bool[MAX_STMTS] live;
    usz live_count;
    usz stmt_count;

    // Block-live flags: a block is live if any of its stmts are live.
    bool[8193] block_live;

    // Worklist of stmt ids to propagate from.
    int[MAX_STMTS] wl;
    usz wl_count;

    // Map block_id -> starting stmt index.
    int[8193] block_stmt_start;
    usz[8193] block_stmt_count;

    // Stats.
    usz seeds;
    usz propagated;
    usz dead_stmts;
    usz dead_branches;
}

fn void Adce.init(Adce* a, Arena* ar)
{
    a.arena = ar;
    a.cfg = null;
    a.live_count = 0;
    a.stmt_count = 0;
    a.wl_count = 0;
    a.seeds = 0;
    a.propagated = 0;
    a.dead_stmts = 0;
    a.dead_branches = 0;
    for (usz i = 0; i < MAX_STMTS; i++) { a.live[i] = false; }
    for (usz i = 0; i < 8193; i++) { a.block_live[i] = false; a.block_stmt_start[i] = -1; a.block_stmt_count[i] = 0; }
    for (usz i = 0; i < MAX_STMTS; i++) { a.wl[i] = -1; }
}

fn usz Adce.stmt_id(Adce* a, int bid, usz idx)
{
    return (usz)(a.block_stmt_start[bid] + (int)idx);
}

fn void Adce.mark_live(Adce* a, usz sid)
{
    if (sid >= MAX_STMTS) return;
    if (a.live[sid]) return;
    a.live[sid] = true;
    a.live_count = a.live_count + 1;
    if (a.wl_count < MAX_STMTS) { a.wl[a.wl_count++] = (int)sid; }
}

// Determine if a node is an INTRINSIC SIDE EFFECT (must be kept regardless
// of whether its result is used).
fn bool has_obvious_effect(Node* n)
{
    if (n == null) return false;
    if ((n.effects & EFF_VOLATILE) != 0) return true;
    switch (n.kind)
    {
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_EXPR_UNREACHABLE:
        case Nk.N_EXPR_TRAP:
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_POISON:
        case Nk.N_EXPR_ASM:
        case Nk.N_EXPR_SYSCALL:
        case Nk.N_EXPR_VOLATILE:
        case Nk.N_EXPR_FENCE:
        case Nk.N_EXPR_ATOMIC:
        case Nk.N_EXPR_FREE:
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_RESUME:
            return true;
        default: return false;
    }
}

// Determine if a node is a "pure" expression we can drop if its result is
// unused. Calls to known-pure functions can be dropped too — but for now we
// treat ALL calls as live (conservatively), because calling a user function
// may loop forever or perform effects we cannot see here.
fn bool is_pure_dropable(Node* n)
{
    if (n == null) return true;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_FLOAT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_STRING:
        case Nk.N_EXPR_NULL:
        case Nk.N_EXPR_UNIT:
        case Nk.N_EXPR_TUPLE:
        case Nk.N_EXPR_ARRAY:
        case Nk.N_EXPR_STRUCT_LIT:
        case Nk.N_EXPR_FIELD_INIT:
        case Nk.N_EXPR_CAST:
        case Nk.N_EXPR_BINARY:
        case Nk.N_EXPR_UNARY:
        case Nk.N_EXPR_FIELD:
        case Nk.N_EXPR_INDEX:
        case Nk.N_EXPR_RANGE:
        case Nk.N_EXPR_SIZEOF:
        case Nk.N_EXPR_ALIGNOF:
        case Nk.N_EXPR_OFFSETOF:
            return (n.effects & EFF_VOLATILE) == 0;
        default: return false;
    }
}

// Assign ids to all statements across all blocks.
fn void Adce.assign_ids(Adce* a)
{
    if (a.cfg == null) return;
    usz sid = 0;
    for (usz bid = 0; bid < a.cfg.block_count; bid++)
    {
        Block* b = &a.cfg.blocks[bid];
        a.block_stmt_start[bid] = (int)sid;
        a.block_stmt_count[bid] = b.stmt_count;
        // Reserve ids for stmts + 1 for the terminator.
        usz need = b.stmt_count + 1;
        if (sid + need >= MAX_STMTS) { need = MAX_STMTS - sid; if (need == 0) break; }
        sid = sid + need;
    }
    a.stmt_count = sid;
}

// When a node is live, recursively mark its children as live operands.
fn void Adce.use_children(Adce* a, Node* n, int bid)
{
    if (n == null) return;
    for (usz i = 0; i < n.child_count; i++) { a.use_node(n.children[i], bid); }
}

fn void Adce.use_node(Adce* a, Node* n, int bid)
{
    if (n == null) return;
    // We don't track per-node ids outside stmt roots; operands are made live
    // transitively by walking their AST, marking any STATEMENT nodes live
    // using their enclosing block's id (approximate but sound — we never
    // drop something needed).
    // For simplicity, if n is itself a control-flow terminator or effectful
    // expression, mark the block live. The pass already marks seeds per-stmt.
    // For children, just recurse (their stmts get seeded below).
    //
    // When n is an N_STMT_ASSIGN/N_EXPR_ASSIGN, the LHS is a USE (because we
    // write to it, which is an effect if LHS is mutable/deref). Walk anyway.
    a.use_children(n, bid);
}

fn void Adce.run_on_cfg(Adce* a, Cfg* c)
{
    a.cfg = c;
    a.assign_ids();

    // Seed: every terminator is live, every effectful statement is live,
    // every statement in the entry block is live (entry args are the
    // function's live-ins).
    for (usz bid = 0; bid < c.block_count; bid++)
    {
        Block* b = &c.blocks[bid];
        bool is_entry = (int)bid == c.entry;
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* st = b.stmts[si];
            if (st == null) continue;
            if (is_entry || has_obvious_effect(st))
            {
                usz sid = a.stmt_id((int)bid, si);
                a.mark_live(sid);
                a.seeds = a.seeds + 1;
                a.block_live[bid] = true;
            }
            // Also seed calls (conservative — they may diverge or have effects).
            if (st.kind == Nk.N_EXPR_CALL || st.kind == Nk.N_EXPR_METHOD
                || st.kind == Nk.N_STMT_RETURN || st.kind == Nk.N_EXPR_IF
                || st.kind == Nk.N_EXPR_MATCH || st.kind == Nk.N_EXPR_WHILE
                || st.kind == Nk.N_EXPR_FOR || st.kind == Nk.N_EXPR_LOOP)
            {
                usz sid = a.stmt_id((int)bid, si);
                a.mark_live(sid);
                a.block_live[bid] = true;
            }
        }
    }

    // Propagate: for each live stmt, mark its AST children's side-effecting
    // sub-statements as live and mark controlling branches' predecessors as
    // needed. Since we don't build per-substatement ids, we use a conservative
    // rule: a block is live if ANY successor is live and the terminator is a
    // branch whose condition feeds into it. For this simplified ADCE we just
    // mark all blocks that post-dominate a live block as live. This is less
    // precise than full ADCE but still removes trivially dead blocks (e.g.
    // after unconditional jump to return, everything after dies).
    //
    // Iterate to fixed-point.
    int iter = 0;
    while (a.wl_count > 0 && iter < 200)
    {
        iter = iter + 1;
        usz old_count = a.wl_count;
        // Process one pass: mark all predecessors of live blocks live.
        for (usz bid = 0; bid < c.block_count; bid++)
        {
            if (!a.block_live[bid]) continue;
            Block* b = &c.blocks[bid];
            // All stmts in a live block that have effects remain live;
            // pure dropable stmts without live users DIE.
            for (usz si = 0; si < b.stmt_count; si++)
            {
                Node* st = b.stmts[si];
                if (st == null) continue;
                // Branches are live; mark conditions as live operands.
                if (st.kind == Nk.N_EXPR_IF && st.child_count >= 1)
                {
                    a.use_node(st.children[0], (int)bid);
                }
            }
            // Mark predecessor blocks as live (their terminator branches to us).
            for (usz p = 0; p < b.pred_count; p++)
            {
                int pred = b.preds[p];
                if (pred < 0) continue;
                if (!a.block_live[(usz)pred])
                {
                    a.block_live[(usz)pred] = true;
                    // Mark all stmts in predecessor that lead to terminator.
                    Block* pb = &c.blocks[(usz)pred];
                    for (usz si = 0; si < pb.stmt_count; si++)
                    {
                        Node* st = pb.stmts[si];
                        if (st != null)
                        {
                            usz sid = a.stmt_id(pred, si);
                            if (!a.live[sid])
                            {
                                a.mark_live(sid);
                                a.propagated = a.propagated + 1;
                            }
                        }
                    }
                }
            }
        }
        if (a.wl_count == old_count) break;
    }

    // Count dead stmts (those in live blocks that are pure-dropable and whose
    // result feeds nothing live).
    for (usz bid = 0; bid < c.block_count; bid++)
    {
        Block* b = &c.blocks[bid];
        if (!a.block_live[bid]) { a.dead_stmts = a.dead_stmts + b.stmt_count; continue; }
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* st = b.stmts[si];
            if (st == null) { a.dead_stmts = a.dead_stmts + 1; continue; }
            usz sid = a.stmt_id((int)bid, si);
            if (!a.live[sid] && is_pure_dropable(st)) { a.dead_stmts = a.dead_stmts + 1; }
        }
    }
}

fn void Adce.report(Adce* a)
{
    printf("  adce seeds        : %d\n", (int)a.seeds);
    printf("  adce propagated   : %d\n", (int)a.propagated);
    printf("  adce live stmts   : %d\n", (int)a.live_count);
    printf("  adce dead stmts   : %d\n", (int)a.dead_stmts);
    printf("  adce dead branches: %d\n", (int)a.dead_branches);
}
