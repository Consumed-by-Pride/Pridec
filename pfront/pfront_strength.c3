// ============================================================================
// pfront_strength.c3 — Strength-reduction opportunity counter
// ----------------------------------------------------------------------------
// Scans the AST looking for expressions that could be replaced by cheaper
// equivalents on a typical CPU. This pass ONLY counts opportunities — nothing
// is rewritten. Counters feed into `--time-passes` so we can see how many
// rewrites a later lowering pass would have available.
//
// Patterns recognised (all classic compiler SR):
//   *  multiply by power-of-2       ->  shift
//   *  divide by power-of-2 (uint)  ->  shift
//   *  mod by power-of-2            ->  and
//   *  multiply by 0/1              ->  0/x   (identities)
//   *  add 0, sub 0, or 0, xor 0    ->  x     (identities)
//   *  and -1, or 0, mul 1          ->  x
//   *  xor x, x-x, x^x              ->  0
//   *  boolean !!, !(!x&!y) demorg  ->  cheaper forms
//   *  comparison chain a<b && b<c   ->  range hint (no SR, but counted)
//   *  a*2 + b*2                    ->  (a+b)*2  (sum-of-products)
// ============================================================================

module pfront_strength;

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

struct Strength
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_mul_pow2;
    usz    n_div_pow2;
    usz    n_mod_pow2;
    usz    n_mul_zero;
    usz    n_mul_one;
    usz    n_add_zero;
    usz    n_sub_zero;
    usz    n_and_all;
    usz    n_or_zero;
    usz    n_xor_self;
    usz    n_sub_self;
    usz    n_double_neg;
    usz    n_cmp_zero_after;   // `if (x != 0)` after an assignment
    usz    n_mul2_add;        // a*2+b*2 patterns
    usz    n_lea_candidate;   // a+b*scale pattern
    usz    n_unsigned_div;
    usz    n_total_binop;
    usz    n_total_unary;
}

fn void Strength.init(Strength* sr, Arena* a)
{
    sr.arena = a;
    sr.cfg = null;
    sr.n_mul_pow2 = 0; sr.n_div_pow2 = 0; sr.n_mod_pow2 = 0;
    sr.n_mul_zero = 0; sr.n_mul_one = 0; sr.n_add_zero = 0; sr.n_sub_zero = 0;
    sr.n_and_all = 0; sr.n_or_zero = 0; sr.n_xor_self = 0; sr.n_sub_self = 0;
    sr.n_double_neg = 0; sr.n_cmp_zero_after = 0; sr.n_mul2_add = 0;
    sr.n_lea_candidate = 0; sr.n_unsigned_div = 0;
    sr.n_total_binop = 0; sr.n_total_unary = 0;
}

fn bool is_int_lit(Node* n, long v)
{
    if (n == null) { return false; }
    return n.kind == Nk.N_EXPR_INT && (long)n.p.ival == v;
}

fn bool is_pow2_int(Node* n, int* lg)
{
    if (n == null || n.kind != Nk.N_EXPR_INT) { return false; }
    long v = (long)n.p.ival;
    if (v <= 0 || v > 0x7FFFFFFF) { return false; }
    // v is power of two
    if ((v & (v - 1)) != 0) { return false; }
    int bits = 0;
    long t = v;
    while (t > 1) { t = t >> 1; bits++; }
    if (lg != null) { *lg = bits; }
    return true;
}

fn bool is_minus_one(Node* n)
{
    if (n == null || n.kind != Nk.N_EXPR_INT) { return false; }
    return (long)n.p.ival == -1;
}

fn void sr_scan(Strength* sr, Node* n, usz depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_EXPR_BINARY)
    {
        sr.n_total_binop = sr.n_total_binop + 1;
        Tk op = (Tk)n.p.op;
        Node* l = null; Node* r = null;
        if (n.child_count >= 2) { l = n.children[0]; r = n.children[1]; }
        int lg = 0;
        if (op == Tk.TOKEN_STAR && r != null)
        {
            if (is_pow2_int(r, &lg)) { sr.n_mul_pow2++; }
            if (is_int_lit(r, 0)) { sr.n_mul_zero++; }
            if (is_int_lit(r, 1)) { sr.n_mul_one++; }
        }
        if (op == Tk.TOKEN_SLASH && r != null)
        {
            if (is_pow2_int(r, &lg)) { sr.n_div_pow2++; }
            sr.n_unsigned_div++;
        }
        if (op == Tk.TOKEN_PERCENT && r != null && is_pow2_int(r, &lg))
        {
            sr.n_mod_pow2++;
        }
        if (op == Tk.TOKEN_PLUS && r != null)
        {
            if (is_int_lit(r, 0)) { sr.n_add_zero++; }
            // LEA-like a + b*scale (scale 1/2/4/8)
            if (l != null && l.kind == Nk.N_EXPR_BINARY && l.child_count >= 2)
            {
                Tk op2 = (Tk)l.p.op;
                Node* r2 = l.children[1];
                if (op2 == Tk.TOKEN_STAR && r2 != null)
                {
                    if (is_int_lit(r2, 1) || is_int_lit(r2, 2)
                        || is_int_lit(r2, 4) || is_int_lit(r2, 8))
                    {
                        sr.n_lea_candidate++;
                    }
                }
            }
        }
        if (op == Tk.TOKEN_MINUS && r != null)
        {
            if (is_int_lit(r, 0)) { sr.n_sub_zero++; }
        }
        if (op == Tk.TOKEN_AMP && r != null)
        {
            if (is_minus_one(r)) { sr.n_and_all++; }
        }
        if (op == Tk.TOKEN_PIPE && r != null)
        {
            if (is_int_lit(r, 0)) { sr.n_or_zero++; }
        }
        if (op == Tk.TOKEN_XOR && r != null)
        {
            if (l == r) { sr.n_xor_self++; }
        }
        if (op == Tk.TOKEN_MINUS && l == r) { sr.n_sub_self++; }
        // a*2 + b*2 (distributive SR)
        if (op == Tk.TOKEN_PLUS && l != null && r != null
            && l.kind == Nk.N_EXPR_BINARY && r.kind == Nk.N_EXPR_BINARY
            && l.child_count >= 2 && r.child_count >= 2)
        {
            Tk ol = (Tk)l.p.op; Tk or_ = (Tk)r.p.op;
            if (ol == Tk.TOKEN_STAR && or_ == Tk.TOKEN_STAR)
            {
                Node* ll = l.children[1]; Node* rr = r.children[1];
                if (ll != null && rr != null && ll.kind == Nk.N_EXPR_INT
                    && rr.kind == Nk.N_EXPR_INT && ll.p.ival == rr.p.ival)
                {
                    sr.n_mul2_add++;
                }
            }
        }
    }
    if (n.kind == Nk.N_EXPR_UNARY)
    {
        sr.n_total_unary = sr.n_total_unary + 1;
        Tk op = (Tk)n.p.op;
        if (op == Tk.TOKEN_BANG && n.child_count >= 1 && n.children[0] != null
            && n.children[0].kind == Nk.N_EXPR_UNARY
            && (Tk)n.children[0].p.op == Tk.TOKEN_BANG)
        {
            sr.n_double_neg++;
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        sr_scan(sr, n.children[i], depth + 1);
    }
}

fn void Strength.run_on_cfg(Strength* sr, Cfg* cfg)
{
    if (cfg == null) { return; }
    sr.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++)
    {
        Block* b = &cfg.blocks[i];
        for (usz j = 0; j < b.stmt_count; j++) { sr_scan(sr, b.stmts[j], 0); }
        if (b.term_node != null) { sr_scan(sr, b.term_node, 0); }
    }
}

fn void Strength.report(Strength* sr)
{
    printf("  strength         : mul-pow2=%d div-pow2=%d mod-pow2=%d\n",
           (int)sr.n_mul_pow2, (int)sr.n_div_pow2, (int)sr.n_mod_pow2);
    printf("  strength-ident   : mul0=%d mul1=%d add0=%d sub0=%d and-1=%d or0=%d\n",
           (int)sr.n_mul_zero, (int)sr.n_mul_one, (int)sr.n_add_zero,
           (int)sr.n_sub_zero, (int)sr.n_and_all, (int)sr.n_or_zero);
    printf("  strength-trivial : xor-x=%d x-x=%d !!x=%d lea=%d a2+b2=%d\n",
           (int)sr.n_xor_self, (int)sr.n_sub_self, (int)sr.n_double_neg,
           (int)sr.n_lea_candidate, (int)sr.n_mul2_add);
}
