// ============================================================================
// pfront_arith.c3 — Arithmetic safety / wrapping opportunity counters
// ----------------------------------------------------------------------------
// Scans every binary/unary arithmetic expression and categorises it against
// classic undefined/signed-wrap risks. Again: purely advisory counts. This
// pass does not decide anything, it just surfaces how many `+`, `*`, `-`,
// `/` sites exist and how many have literal operands that make the overflow
// risk provably absent (constant fold-safe) vs open (potentially wrapping).
//
// Categorised:
//   * add/sub/mul/div/mod/shl/shr  total counts
//   * constant-on-right (foldable)
//   * both-constant (fully foldable — caught by constfold, counted here too)
//   * same-operand (x+x -> 2*x, x-x -> 0, x*0, x/x -> 1 when x!=0)
//   * negation-of-negation (--x -> x)
//   * increment/decrement patterns (x+1 / x-1)
//   * mixed-sign operations (risk of signed UB in C-semantics)
//   * unsigned-wrapping shifts (shift >= bits)
//
// Nothing is rewritten. The counts guide how much work a later overflow-
// checking insertion pass would have to do.
// ============================================================================

module pfront_arith;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk     = pfront_core::NodeKind;
alias Tk     = pfront_lex::TokenType;
alias Node   = pfront_core::PNode;
alias Arena  = pfront_core::Arena;
alias Cfg    = pfront_cfg::Cfg;
alias Block  = pfront_cfg::Block;

extern fn int printf(char* fmt, ...);

struct Arith
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_add;
    usz    n_sub;
    usz    n_mul;
    usz    n_div;
    usz    n_mod;
    usz    n_shl;
    usz    n_shr;
    usz    n_bitor;
    usz    n_bitand;
    usz    n_bitxor;
    usz    n_neg;
    usz    n_both_const;
    usz    n_right_const;
    usz    n_left_const;
    usz    n_same_operand;
    usz    n_inc_pattern;      // x+1 / x-1
    usz    n_double_neg;
    usz    n_shift_large;      // shift count provably >= 64
    usz    n_div_by_nonconst;
    usz    n_comm_const;       // commutative op with constant anywhere
}

fn void Arith.init(Arith* a, Arena* ar)
{
    a.arena = ar;
    a.cfg = null;
    a.n_add = 0; a.n_sub = 0; a.n_mul = 0; a.n_div = 0; a.n_mod = 0;
    a.n_shl = 0; a.n_shr = 0; a.n_bitor = 0; a.n_bitand = 0; a.n_bitxor = 0;
    a.n_neg = 0; a.n_both_const = 0; a.n_right_const = 0; a.n_left_const = 0;
    a.n_same_operand = 0; a.n_inc_pattern = 0; a.n_double_neg = 0;
    a.n_shift_large = 0; a.n_div_by_nonconst = 0; a.n_comm_const = 0;
}

fn bool is_arith_const(Node* n)
{
    if (n == null) { return false; }
    return n.kind == Nk.N_EXPR_INT
        || n.kind == Nk.N_EXPR_FLOAT
        || n.kind == Nk.N_EXPR_BOOL
        || n.kind == Nk.N_EXPR_CHAR;
}

fn bool is_lit_small(Node* n, long v)
{
    if (n == null || n.kind != Nk.N_EXPR_INT) { return false; }
    return (long)n.p.ival == v;
}

fn void scan_arith(Arith* a, Node* n, usz depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_EXPR_BINARY && n.child_count >= 2)
    {
        Tk op = (Tk)n.p.op;
        Node* l = n.children[0];
        Node* r = n.children[1];
        bool lc = is_arith_const(l);
        bool rc = is_arith_const(r);
        // Counter per op
        switch (op)
        {
            case Tk.TOKEN_PLUS:    a.n_add++; break;
            case Tk.TOKEN_MINUS:   a.n_sub++; break;
            case Tk.TOKEN_STAR:    a.n_mul++; break;
            case Tk.TOKEN_SLASH:   a.n_div++; break;
            case Tk.TOKEN_PERCENT: a.n_mod++; break;
            case Tk.TOKEN_LSHIFT:  a.n_shl++; break;
            case Tk.TOKEN_RSHIFT:  a.n_shr++; break;
            case Tk.TOKEN_PIPE:    a.n_bitor++; break;
            case Tk.TOKEN_AMP:     a.n_bitand++; break;
            case Tk.TOKEN_XOR:     a.n_bitxor++; break;
            default: break;
        }
        if (lc && rc) { a.n_both_const++; }
        if (rc && !lc) { a.n_right_const++; }
        if (lc && !rc) { a.n_left_const++; }
        if (l == r && l != null) { a.n_same_operand++; }
        if ((op == Tk.TOKEN_PLUS && is_lit_small(r, 1))
         || (op == Tk.TOKEN_MINUS && is_lit_small(r, 1)))
        {
            a.n_inc_pattern++;
        }
        if (rc) { a.n_comm_const++; }
        else if (lc && (op == Tk.TOKEN_PLUS || op == Tk.TOKEN_STAR
                        || op == Tk.TOKEN_PIPE || op == Tk.TOKEN_AMP
                        || op == Tk.TOKEN_XOR))
        {
            a.n_comm_const++;
        }
        if ((op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT) && !rc) { a.n_div_by_nonconst++; }
        if ((op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT) && r != null
            && r.kind == Nk.N_EXPR_INT && (long)r.p.ival >= 64)
        {
            a.n_shift_large++;
        }
    }
    if (n.kind == Nk.N_EXPR_UNARY && n.child_count >= 1)
    {
        Tk op = (Tk)n.p.op;
        if (op == Tk.TOKEN_MINUS) { a.n_neg++; }
        if (op == Tk.TOKEN_BANG && n.children[0] != null
            && n.children[0].kind == Nk.N_EXPR_UNARY
            && (Tk)n.children[0].p.op == Tk.TOKEN_BANG)
        {
            a.n_double_neg++;
        }
        if (op == Tk.TOKEN_MINUS && n.children[0] != null
            && n.children[0].kind == Nk.N_EXPR_UNARY
            && (Tk)n.children[0].p.op == Tk.TOKEN_MINUS)
        {
            a.n_double_neg++;
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        scan_arith(a, n.children[i], depth + 1);
    }
}

fn void Arith.run_on_cfg(Arith* a, Cfg* cfg)
{
    if (cfg == null) { return; }
    a.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++)
    {
        Block* b = &cfg.blocks[i];
        for (usz j = 0; j < b.stmt_count; j++) { scan_arith(a, b.stmts[j], 0); }
        if (b.term_node != null) { scan_arith(a, b.term_node, 0); }
    }
}

fn void Arith.report(Arith* a)
{
    printf("  arith-ops        : +%d -%d *%d /%d %%%d <<%d >>%d\n",
           (int)a.n_add, (int)a.n_sub, (int)a.n_mul, (int)a.n_div,
           (int)a.n_mod, (int)a.n_shl, (int)a.n_shr);
    printf("  arith-bitwise    : |%d &%d ^%d neg=%d\n",
           (int)a.n_bitor, (int)a.n_bitand, (int)a.n_bitxor, (int)a.n_neg);
    printf("  arith-fold       : both-const=%d rconst=%d lconst=%d same-op=%d\n",
           (int)a.n_both_const, (int)a.n_right_const, (int)a.n_left_const,
           (int)a.n_same_operand);
    printf("  arith-patterns   : inc/dec=%d !!x/--x=%d comm-const=%d risky-shift=%d\n",
           (int)a.n_inc_pattern, (int)a.n_double_neg, (int)a.n_comm_const,
           (int)a.n_shift_large);
}
