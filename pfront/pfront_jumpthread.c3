// ============================================================================
// pfront_jumpthread.c3 — Jump threading (pure analysis, read-only on AST)
// ----------------------------------------------------------------------------
// Jump threading identifies blocks that end in a conditional branch where
// one of the successor's condition is determined by the edge itself. The
// canonical case:
//
//     B1: if c then B2 else B3
//     B2: if c then B4 else B5     (B2's c == true is known here, so B5 is unreachable)
//     B3: if c then B4 else B5     (B3's c == false is known here, so B4 is unreachable)
//
// We can "thread" B1->B2->B4 and B1->B3->B5 directly, avoiding a redundant
// branch and exposing more simplification to later passes.
//
// This implementation is pure-AST-read-only: it identifies opportunities
// and reports counts, it does not mutate the CFG. An actual CFG/IR rewrite
// pass can use these facts to collapse the branches.
//
// The algorithm:
//   1. For each block B ending in TERM_IF with condition c, look at each
//      successor S. If S also ends in TERM_IF with condition c (or its
//      negation), then we know which way S will branch given that we
//      arrived via B. Count that as a threadable edge.
//   2. Additionally, any block that is empty (no statements, falls through
//      to exactly one successor) is a "jump block" that can be redirected.
//   3. Also detect "branch to same successor" — when both arms of an IF
//      target the same successor, the condition is dead.
// ============================================================================

module pfront_jumpthread;

import pfront_core;
import pfront_cfg;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

struct JumpThread
{
    Arena* arena;
    Cfg*   cfg;

    // Statistics.
    usz threadable;     // edges that could be threaded (B -> S -> T)
    usz trivial_br;     // both arms target the same successor
    usz empty_blocks;   // blocks with 0 statements (jump-only)
    usz unreach_succ;   // successors unreachable given edge context
}

fn void JumpThread.init(JumpThread* jt, Arena* a)
{
    jt.arena = a;
    jt.cfg = null;
    jt.threadable = 0;
    jt.trivial_br = 0;
    jt.empty_blocks = 0;
    jt.unreach_succ = 0;
}

// Two exprs are syntactically the same node (identity) — cheap pointer
// equality. We do not do expression-equivalence here (GVN already does
// that and its VN could be reused in principle).
fn bool same_node(Node* a, Node* b)
{
    return a == b && a != null;
}

fn bool is_negation(Node* a, Node* b)
{
    if (a == null || b == null) return false;
    // a is !b?
    if (a.kind == Nk.N_EXPR_UNARY && a.child_count >= 1 && a.children[0] == b) return true;
    // b is !a?
    if (b.kind == Nk.N_EXPR_UNARY && b.child_count >= 1 && b.children[0] == a) return true;
    return false;
}

fn void JumpThread.run_on_cfg(JumpThread* jt, Cfg* c)
{
    if (c == null) return;
    jt.cfg = c;
    usz nb = c.block_count;

    // 1. Trivial branches: both successors identical.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        if (b.stmt_count == 0) { jt.empty_blocks = jt.empty_blocks + 1; }
        if (b.term == TermKind.TERM_IF && b.succ_count >= 2)
        {
            if (b.succs[0] == b.succs[1])
            {
                jt.trivial_br = jt.trivial_br + 1;
                jt.unreach_succ = jt.unreach_succ + 1;
            }
        }
    }

    // 2. Threadable edges: B -> S where B.c == S.c (or its negation),
    // revealing S's branch direction.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        if (b.term != TermKind.TERM_IF) continue;
        if (b.succ_count < 2) continue;
        Node* bc = b.term_node;
        if (bc == null) continue;
        for (usz si = 0; si < b.succ_count; si++)
        {
            int s = b.succs[si];
            if (s < 0 || (usz)s >= nb) continue;
            Block* sb = &c.blocks[s];
            if (sb.term != TermKind.TERM_IF) continue;
            Node* sc = sb.term_node;
            if (sc == null) continue;
            // Edge bi -> s carries bc = (si==0). If S branches on the SAME
            // condition, we know which way it goes.
            bool known = false;
            if (same_node(bc, sc))
            {
                known = true;
            }
            else if (is_negation(bc, sc))
            {
                known = true;
            }
            if (known)
            {
                jt.threadable = jt.threadable + 1;
                // The other arm of S is unreachable from this edge.
                jt.unreach_succ = jt.unreach_succ + 1;
            }
        }
    }
}

fn void JumpThread.report(JumpThread* jt)
{
    printf("  jt threadable   : %d\n", (int)jt.threadable);
    printf("  jt trivial br   : %d\n", (int)jt.trivial_br);
    printf("  jt empty blocks : %d\n", (int)jt.empty_blocks);
    printf("  jt unreach succ : %d\n", (int)jt.unreach_succ);
}
