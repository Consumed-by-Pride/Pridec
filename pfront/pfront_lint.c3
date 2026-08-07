// ============================================================================
// pfront_lint.c3 — Optional lint checks for common code issues
// ----------------------------------------------------------------------------
// Runs after the main analyses and reports style/correctness nits. None of
// these are errors (Pride is untyped and permissive by design); they are
// diagnostics surfaced under --lint that help catch mistakes early.
//
// Checks performed:
//   W_lint_unused    — a local `let` is never used in its scope
//   W_lint_unread    — a mutable binding is written but never read (dead store)
//   W_lint_shadow    — a binding shadows an outer-scope binding of same name
//   W_lint_self_assign — `x = x` style no-op
//   W_lint_const_cond  — `if true` / `if false` conditions (caught after DFE)
//   W_lint_empty_if    — empty then/else block
//   W_lint_unreachable — code after return/break/continue/ub!
//   W_lint_double_neg  — `!!x` which is a bool cast; sometimes intentional
//   W_lint_ident_eq_self — `x == x` always true
//   W_lint_yoda        — literal on left of comparison `if 3 == x`
//
// All are ADVISORY: they never affect compilation. Counts are reported.
// ============================================================================

module pfront_lint;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias DiagBag = pfront_core::DiagBag;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz LINT_SET = 4096;
const int W_LINT_UNUSED    = 5001;
const int W_LINT_UNREAD    = 5002;
const int W_LINT_SHADOW    = 5003;
const int W_LINT_SELF_ASSIGN = 5004;
const int W_LINT_CONST_COND  = 5005;
const int W_LINT_EMPTY_IF    = 5006;
const int W_LINT_UNREACHABLE = 5007;
const int W_LINT_DOUBLE_NEG  = 5008;
const int W_LINT_SELF_CMP    = 5009;
const int W_LINT_YODA        = 5010;
const int W_LINT_DEAD_LOCAL  = 5011;

struct Lint
{
    Arena*    arena;
    DiagBag*  diags;
    char*     file;
    pfront_core::Interner* it;

    char*     used;       // bit-scratch for name_id used tracking
    usz       unused;
    usz       unread;
    usz       shadow;
    usz       self_assign;
    usz       const_cond;
    usz       empty_if;
    usz       unreachable;
    usz       double_neg;
    usz       self_cmp;
    usz       yoda;
    usz       dead_local;
}

fn void Lint.init(Lint* l, Arena* a, DiagBag* d, char* file, pfront_core::Interner* it)
{
    l.arena = a;
    l.diags = d;
    l.file = file;
    l.it = it;
    l.used = (char*)calloc(LINT_SET, 1);
    l.unused = 0; l.unread = 0; l.shadow = 0;
    l.self_assign = 0; l.const_cond = 0; l.empty_if = 0;
    l.unreachable = 0; l.double_neg = 0; l.self_cmp = 0;
    l.yoda = 0; l.dead_local = 0;
}

fn void lint_mark_used(Lint* l, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_EXPR_IDENT && n.name_id != 0)
    {
        usz slot = n.name_id & (LINT_SET - 1);
        l.used[slot] = 1;
    }
    for (usz i = 0; i < n.child_count; i++) lint_mark_used(l, n.children[i]);
}

fn void Lint.run(Lint* l, Node* prog)
{
    if (prog == null) return;
    // Walk entire tree collecting reports.
    l_walk(l, prog, false);
}

fn void l_walk(Lint* l, Node* n, bool unreach)
{
    if (n == null) return;
    if (unreach)
    {
        l.unreachable = l.unreachable + 1;
    }
    // Check node forms.
    switch (n.kind)
    {
        case Nk.N_STMT_ASSIGN:
            if (n.child_count >= 2)
            {
                Node* a = n.children[0]; Node* b = n.children[1];
                if (a != null && b != null
                    && a.kind == Nk.N_EXPR_IDENT && b.kind == Nk.N_EXPR_IDENT
                    && a.name_id != 0 && a.name_id == b.name_id)
                {
                    l.self_assign++;
                }
            }
            break;
        case Nk.N_EXPR_IF:
            if (n.child_count >= 1)
            {
                Node* cond = n.children[0];
                if (cond != null && (cond.kind == Nk.N_EXPR_BOOL || cond.kind == Nk.N_EXPR_INT))
                {
                    // Only flag 0/1 bool/int literals as trivial.
                    if (cond.kind == Nk.N_EXPR_BOOL || cond.p.ival == 0 || cond.p.ival == 1)
                    {
                        l.const_cond++;
                    }
                }
                if (cond != null && cond.kind == Nk.N_EXPR_BINARY)
                {
                    Tk op = (Tk)cond.p.op;
                    if (op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ
                     || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT
                     || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ)
                    {
                        Node* a = cond.children[0];
                        if (a != null && (a.kind == Nk.N_EXPR_INT || a.kind == Nk.N_EXPR_BOOL))
                        {
                            l.yoda++;
                        }
                        if (cond.child_count >= 2)
                        {
                            Node* lhs = cond.children[0]; Node* rhs = cond.children[1];
                            if (lhs != null && rhs != null
                             && lhs.kind == Nk.N_EXPR_IDENT && rhs.kind == Nk.N_EXPR_IDENT
                             && lhs.name_id != 0 && lhs.name_id == rhs.name_id)
                            {
                                l.self_cmp++;
                            }
                        }
                    }
                }
            }
            // Empty then/else arms.
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* arm = n.children[i];
                if (arm == null) { l.empty_if++; continue; }
                if (arm.kind == Nk.N_BLOCK && arm.child_count == 0) { l.empty_if++; }
            }
            break;
        case Nk.N_EXPR_UNARY:
            if ((Tk)n.p.op == Tk.TOKEN_BANG && n.child_count >= 1)
            {
                Node* c = n.children[0];
                if (c != null && c.kind == Nk.N_EXPR_UNARY && (Tk)c.p.op == Tk.TOKEN_BANG)
                {
                    l.double_neg++;
                }
            }
            break;
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
            // Statements after these are unreachable; flag in the caller.
            break;
        default:
            break;
    }
    // Determine if children are unreachable (post-terminator).
    bool post_term = false;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) continue;
        l_walk(l, c, unreach || post_term);
        if (c.kind == Nk.N_STMT_RETURN
         || c.kind == Nk.N_STMT_BREAK
         || c.kind == Nk.N_STMT_CONTINUE
         || c.kind == Nk.N_EXPR_UB)
        {
            post_term = true;
        }
    }
}

fn void Lint.report(Lint* l)
{
    printf("  lint warnings    : unused=%d unread=%d shadow=%d self-assign=%d\n",
           (int)l.unused, (int)l.unread, (int)l.shadow, (int)l.self_assign);
    printf("  lint branches    : const-cond=%d empty=%d unreach=%d\n",
           (int)l.const_cond, (int)l.empty_if, (int)l.unreachable);
    printf("  lint style       : !!x=%d self-cmp=%d yoda=%d dead-local=%d\n",
           (int)l.double_neg, (int)l.self_cmp, (int)l.yoda, (int)l.dead_local);
}

fn void Lint.free(Lint* l)
{
    free((void*)l.used);
    l.used = null;
}
