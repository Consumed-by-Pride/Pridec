// ============================================================================
// pfront_tailcall.c3 — Tail-call position detection
// ----------------------------------------------------------------------------
// Walks every function body looking for direct calls that appear in *tail
// position*: a call whose result is immediately returned by the enclosing
// function, with no intervening computation. Classic tail-call-optimisation
// (TCO) candidates. Also recognises:
//
//   - sibling (same-function) tail recursion (self-TCO)
//   - mutually recursive tail calls (call graph cross-ref)
//   - conditional tail returns (if-tail / match-tail)
//   - block-tail (last statement of a block is return-of-call)
//
// This is PURELY advisory. The counts inform later passes (inlining budgets,
// recursion classification, perf hints); nothing is ever rewritten, and no
// code is rejected for not being in tail position.
// ============================================================================

module pfront_tailcall;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk      = pfront_core::NodeKind;
alias Tk      = pfront_lex::TokenType;
alias Node    = pfront_core::PNode;
alias Arena   = pfront_core::Arena;
alias Cfg     = pfront_cfg::Cfg;
alias Block   = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;

extern fn int printf(char* fmt, ...);

struct TailCall
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_tail_calls;        // any tail-position call
    usz    n_tail_self;         // sibling self-recursion
    usz    n_tail_other;        // cross-function tail calls
    usz    n_cond_tail;         // conditional (if/match) tail
    usz    n_call_total;        // total call sites in the function
    usz    n_tail_blocks;       // blocks whose term is a return with a call expr
    usz    n_nontail_returns;   // returns without a callexpr in operand position
    usz    n_effectful_tail;    // tail calls that still carry effects
    bool   is_recursive;        // does any self-tail-call exist?
}

fn void TailCall.init(TailCall* tc, Arena* a)
{
    tc.arena = a;
    tc.cfg = null;
    tc.n_tail_calls = 0;
    tc.n_tail_self = 0;
    tc.n_tail_other = 0;
    tc.n_cond_tail = 0;
    tc.n_call_total = 0;
    tc.n_tail_blocks = 0;
    tc.n_nontail_returns = 0;
    tc.n_effectful_tail = 0;
    tc.is_recursive = false;
}

// A node is a "direct call expression" if it's N_EXPR_CALL with a plain
// callee ident (name_id != 0). Returns the callee name_id or 0.
fn uint is_direct_call(Node* n)
{
    if (n == null) { return 0; }
    if (n.kind != Nk.N_EXPR_CALL) { return 0; }
    if (n.child_count < 1) { return 0; }
    Node* callee = n.children[0];
    if (callee == null) { return 0; }
    // Simple direct call: callee is an identifier.
    if (callee.kind == Nk.N_EXPR_IDENT && callee.name_id != 0)
    {
        return callee.name_id;
    }
    return 0;
}

// Does this node represent a `return call_expr(...)` tail form?
// Returns the callee name_id if yes, 0 otherwise.
fn uint return_has_tail_call(Node* retn)
{
    if (retn == null) { return 0; }
    if (retn.kind != Nk.N_STMT_RETURN) { return 0; }
    if (retn.child_count < 1) { return 0; }
    Node* rv = retn.children[0];
    return is_direct_call(rv);
}

// Scan a statement list for the last "effective" statement and see if
// it is a tail-calling return.
fn uint block_last_is_tail(Node* blk)
{
    if (blk == null) { return 0; }
    if (blk.kind != Nk.N_BLOCK && blk.kind != Nk.N_CLAUSE) { return 0; }
    // Find last non-null child that is a stmt/return/call
    for (long i = (long)blk.child_count - 1; i >= 0; i--)
    {
        Node* s = blk.children[(usz)i];
        if (s == null) { continue; }
        if (s.kind == Nk.N_STMT_RETURN) { return return_has_tail_call(s); }
        // An entire block that ends in a tail return is itself a tail.
        if (s.kind == Nk.N_BLOCK)
        {
            uint inner = block_last_is_tail(s);
            if (inner != 0) { return inner; }
        }
        break;
    }
    return 0;
}

// Count calls anywhere in an expression tree (for total call-site count).
fn usz count_calls_in(Node* n, usz depth)
{
    if (n == null || depth > 80) { return 0; }
    usz c = 0;
    if (n.kind == Nk.N_EXPR_CALL) { c = 1; }
    for (usz i = 0; i < n.child_count; i++)
    {
        c = c + count_calls_in(n.children[i], depth + 1);
    }
    if (n.type_ann != null) { c = c + count_calls_in(n.type_ann, depth + 1); }
    return c;
}

// Check an if/match terminator for conditional-tail returns.
fn usz scan_conditional_tail(Node* cond_node)
{
    if (cond_node == null) { return 0; }
    usz found = 0;
    if (cond_node.kind == Nk.N_EXPR_IF && cond_node.child_count >= 3)
    {
        // then-branch children[1], else-branch children[2]
        uint t = block_last_is_tail(cond_node.children[1]);
        uint e = block_last_is_tail(cond_node.children[2]);
        if (t != 0) { found = found + 1; }
        if (e != 0) { found = found + 1; }
    }
    if (cond_node.kind == Nk.N_EXPR_MATCH)
    {
        for (usz i = 1; i < cond_node.child_count; i++)
        {
            Node* arm = cond_node.children[i];
            if (arm == null) { continue; }
            uint k = block_last_is_tail(arm);
            if (k != 0) { found = found + 1; }
        }
    }
    return found;
}

// Walk a function body looking for tail-call structure. We don't have CFG
// helpers here; we walk the Nodes directly (simpler for syntactic tails).
fn void tc_walk_body(TailCall* tc, Node* n, Node* fdecl, usz depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_STMT_RETURN)
    {
        uint callee = return_has_tail_call(n);
        if (callee != 0)
        {
            tc.n_tail_calls = tc.n_tail_calls + 1;
            bool self = fdecl != null && fdecl.name_id != 0 && callee == fdecl.name_id;
            if (self)
            {
                tc.n_tail_self = tc.n_tail_self + 1;
                tc.is_recursive = true;
            }
            else
            {
                tc.n_tail_other = tc.n_tail_other + 1;
            }
            if (n.child_count >= 1 && n.children[0] != null)
            {
                const ulong EF_IO = 1;
                const ulong EF_PANIC = 16;
                const ulong EF_DIVERGE = 32;
                ulong ef = n.children[0].effects;
                if ((ef & (EF_IO | EF_PANIC | EF_DIVERGE)) != 0)
                {
                    tc.n_effectful_tail = tc.n_effectful_tail + 1;
                }
            }
        }
        else
        {
            tc.n_nontail_returns = tc.n_nontail_returns + 1;
        }
    }
    if (n.kind == Nk.N_EXPR_CALL)
    {
        tc.n_call_total = tc.n_call_total + 1;
    }
    if (n.kind == Nk.N_EXPR_IF || n.kind == Nk.N_EXPR_MATCH)
    {
        usz ct = scan_conditional_tail(n);
        if (ct > 0) { tc.n_cond_tail = tc.n_cond_tail + ct; }
    }
    if (n.kind == Nk.N_BLOCK)
    {
        uint tail_callee = block_last_is_tail(n);
        if (tail_callee != 0) { tc.n_tail_blocks = tc.n_tail_blocks + 1; }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        tc_walk_body(tc, n.children[i], fdecl, depth + 1);
    }
    if (n.type_ann != null) { tc_walk_body(tc, n.type_ann, fdecl, depth + 1); }
}

fn void TailCall.run_on_fn(TailCall* tc, Node* fdecl)
{
    if (fdecl == null || fdecl.kind != Nk.N_DECL_FN) { return; }
    for (usz k = 0; k < fdecl.child_count; k++)
    {
        Node* c = fdecl.children[k];
        if (c == null) { continue; }
        if (c.kind == Nk.N_CLAUSE)
        {
            for (usz j = 1; j < c.child_count; j++)
            {
                tc_walk_body(tc, c.children[j], fdecl, 0);
            }
        }
        else if (c.kind == Nk.N_BLOCK)
        {
            tc_walk_body(tc, c, fdecl, 0);
        }
    }
}

fn void TailCall.report(TailCall* tc)
{
    printf("  tail-call        : %d tail-calls (self=%d cross=%d cond=%d), total calls=%d\n",
           (int)tc.n_tail_calls, (int)tc.n_tail_self, (int)tc.n_tail_other,
           (int)tc.n_cond_tail, (int)tc.n_call_total);
    printf("  tail-blocks      : %d blocks end in return-of-call, %d plain returns\n",
           (int)tc.n_tail_blocks, (int)tc.n_nontail_returns);
    printf("  effectful-tail   : %d tail calls carry IO/panic/diverge effects\n",
           (int)tc.n_effectful_tail);
}
