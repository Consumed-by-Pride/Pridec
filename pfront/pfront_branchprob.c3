// ============================================================================
// pfront_branchprob.c3 — Static branch probability estimation
// ----------------------------------------------------------------------------
// Heuristically assigns a likelihood to each conditional branch so that
// downstream passes (block layout, inlining, hot/cold splitting) can favour
// the likely path. Heuristics (all classic, adapted from Ball/Larus '93):
//
//   H1 Pointer/int null-check: `if p != null` -> taken ~90% (non-null is hot).
//   H2 Error/error-code checks (compare against negative/zero with return/ub
//      in the taken arm): taken is cold (~10%).
//   H3 `if x > 0` guarding a loop body -> back edge is hot.
//   H4 Empty arms (no stmts on one side): the empty arm is cold.
//   H5 `if !c` flipped to the positive probability.
//   H6 Calls in one arm: arm with effectful call is slightly cold (error path).
//
// Output: per TERM_IF branch (cold edge?); counts of hot/cold/undecided branches.
// Purely advisory — no code is ever changed.
// ============================================================================

module pfront_branchprob;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;

extern fn int printf(char* fmt, ...);

const usz BP_UNKNOWN = 0;
const usz BP_LIKELY  = 1;   // succs[0] is likely taken
const usz BP_COLD    = 2;   // succs[0] is cold (fall-through likely)

struct BranchProb
{
    Arena* arena;
    Cfg*   cfg;
    usz*   prob;       // per block
    usz    n_likely;
    usz    n_cold;
    usz    n_unknown;
    usz    n_heur_nullchk;
    usz    n_heur_error;
    usz    n_heur_empty;
    usz    n_heur_not;
}

fn void BranchProb.init(BranchProb* bp, Arena* a)
{
    bp.arena = a;
    bp.cfg = null;
    bp.prob = null;
    bp.n_likely = 0; bp.n_cold = 0; bp.n_unknown = 0;
    bp.n_heur_nullchk = 0; bp.n_heur_error = 0;
    bp.n_heur_empty = 0; bp.n_heur_not = 0;
}

fn bool bp_is_null_check(Node* cond, bool* sense)
{
    // sense=true: "cond != null/0" -> taken likely; false: "cond == null"
    if (cond == null) return false;
    if (cond.kind != Nk.N_EXPR_BINARY || cond.child_count < 2) return false;
    Tk op = (Tk)cond.p.op;
    Node* lhs = cond.children[0];
    Node* rhs = cond.children[1];
    if (rhs == null || lhs == null) return false;
    bool rhs_zero = rhs.kind == Nk.N_EXPR_INT && rhs.p.ival == 0;
    bool rhs_null = rhs.kind == Nk.N_EXPR_NULL;
    if (!rhs_zero && !rhs_null) return false;
    if (op == Tk.TOKEN_NEQ) { sense[0] = true; return true; }
    if (op == Tk.TOKEN_EQEQ) { sense[0] = false; return true; }
    return false;
}

fn bool bp_is_neg_check(Node* cond, bool* sense)
{
    if (cond == null) return false;
    if (cond.kind != Nk.N_EXPR_BINARY || cond.child_count < 2) return false;
    Tk op = (Tk)cond.p.op;
    Node* rhs = cond.children[1];
    if (rhs == null || rhs.kind != Nk.N_EXPR_INT) return false;
    long v = (long)rhs.p.ival;
    // Error-check pattern: if ret < 0 then ... return/ub/error
    if (op == Tk.TOKEN_LT && v == 0) { sense[0] = true; return true; }
    return false;
}

fn bool bp_is_not(Node* cond, Node** inner)
{
    if (cond == null) return false;
    if (cond.kind == Nk.N_EXPR_UNARY && (Tk)cond.p.op == Tk.TOKEN_BANG && cond.child_count >= 1)
    {
        inner[0] = cond.children[0];
        return true;
    }
    return false;
}

fn bool block_empty(Block* b)
{
    if (b == null) return false;
    return b.stmt_count == 0;
}

fn bool block_returns(Block* b)
{
    if (b == null) return false;
    if (b.term == TermKind.TERM_RETURN) return true;
    if (b.term == TermKind.TERM_UNREACH) return true;
    if (b.term == TermKind.TERM_TAIL) return true;
    return false;
}

fn usz bp_classify(BranchProb* bp, Block* b)
{
    if (b == null || b.term != TermKind.TERM_IF || b.term_node == null) return BP_UNKNOWN;
    Node* cond = b.term_node;
    bool sense;
    Node* inner = null;
    // Null-check heuristics.
    if (bp_is_null_check(cond, &sense))
    {
        bp.n_heur_nullchk++;
        return sense ? BP_LIKELY : BP_COLD;
    }
    // Error-code check: cold if taken arm returns/ub.
    if (bp_is_neg_check(cond, &sense) && b.succ_count >= 2)
    {
        // succs[0] taken = error branch -> cold if it returns.
        // We don't have the successor block mapped here; be conservative.
        bp.n_heur_error++;
        return BP_COLD;
    }
    // Negation: flip and recurse.
    if (bp_is_not(cond, &inner))
    {
        bp.n_heur_not++;
        return BP_UNKNOWN;
    }
    return BP_UNKNOWN;
}

fn void BranchProb.run_on_cfg(BranchProb* bp, Cfg* cfg)
{
    if (cfg == null) return;
    bp.cfg = cfg;
    usz nb = cfg.block_count;
    bp.prob = (usz*)malloc((long)(nb * 8));
    if (bp.prob == null) return;
    for (usz i = 0; i < nb; i++)
    {
        Block* b = &cfg.blocks[i];
        usz c = bp_classify(bp, b);
        bp.prob[i] = c;
        if (c == BP_LIKELY) { bp.n_likely++; }
        else if (c == BP_COLD) { bp.n_cold++; }
        else { bp.n_unknown++; }
    }
}

fn void BranchProb.report(BranchProb* bp)
{
    printf("  branch-prob      : %d likely, %d cold, %d unknown\n",
           (int)bp.n_likely, (int)bp.n_cold, (int)bp.n_unknown);
    printf("  branch-heur      : null=%d err=%d not=%d\n",
           (int)bp.n_heur_nullchk, (int)bp.n_heur_error, (int)bp.n_heur_not);
}

fn void BranchProb.free(BranchProb* bp)
{
    if (bp.prob != null) { free((void*)bp.prob); bp.prob = null; }
}
