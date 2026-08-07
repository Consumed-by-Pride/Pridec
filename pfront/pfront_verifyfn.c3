// ============================================================================
// pfront_verifyfn.c3 — Function-level advisory checks (purely informational).
// Pride is untyped and NEVER rejects a program; this pass reports
// suspicious shapes purely for the user's benefit under --time-passes.
// ============================================================================

module pfront_verifyfn;

import pfront_core;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias DiagBag = pfront_core::DiagBag;

extern fn int printf(char* fmt, ...);

struct FnVerify
{
    Arena*    arena;
    DiagBag*  diags;
    char*     file;
    pfront_core::Interner* it;

    usz n_unreach;
    usz n_empty;
    usz n_divzero;
    usz n_shiftovf;
    usz n_dupcond;
    usz n_doubleneg;
    usz n_boolcmp;
    usz n_selfassign;
    usz n_fns_checked;
}

fn void FnVerify.init(FnVerify* fv, Arena* a, DiagBag* d, char* file, pfront_core::Interner* it)
{
    fv.arena = a;
    fv.diags = d;
    fv.file = file;
    fv.it = it;
    fv.n_unreach = 0; fv.n_empty = 0; fv.n_divzero = 0;
    fv.n_shiftovf = 0; fv.n_dupcond = 0; fv.n_doubleneg = 0;
    fv.n_boolcmp = 0; fv.n_selfassign = 0; fv.n_fns_checked = 0;
}

fn bool v_terminates(Node* n)
{
    if (n == null) return false;
    if (n.kind == Nk.N_STMT_RETURN) return true;
    if (n.kind == Nk.N_STMT_BREAK) return true;
    if (n.kind == Nk.N_STMT_CONTINUE) return true;
    if (n.kind == Nk.N_EXPR_UB) return true;
    if (n.kind == Nk.N_EXPR_POISON) return true;
    return false;
}

fn bool v_zero(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_INT && n.p.ival == 0;
}

fn bool v_same(Node* a, Node* b)
{
    if (a == b) return true;
    if (a == null || b == null) return false;
    if (a.kind != b.kind) return false;
    if (a.kind == Nk.N_EXPR_IDENT && b.kind == Nk.N_EXPR_IDENT)
    {
        return a.name_id != 0 && a.name_id == b.name_id;
    }
    if (a.kind == Nk.N_EXPR_INT && b.kind == Nk.N_EXPR_INT) return a.p.ival == b.p.ival;
    if (a.kind == Nk.N_EXPR_BOOL && b.kind == Nk.N_EXPR_BOOL) return a.p.ival == b.p.ival;
    return false;
}

// Returns true if this subtree definitely terminates (no fallthrough).
fn bool fv_walk(FnVerify* fv, Node* n, bool termd)
{
    if (n == null) return false;
    bool local_term = false;
    switch (n.kind)
    {
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
            return true;
        case Nk.N_EXPR_UB:
        case Nk.N_EXPR_POISON:
            return true;
        case Nk.N_EXPR_IF:
            {
                bool then_t = false;
                bool else_t = false;
                if (n.child_count >= 2) { then_t = fv_walk(fv, n.children[1], termd || local_term); }
                if (n.child_count >= 3) { else_t = fv_walk(fv, n.children[2], termd || local_term); }
                // dup condition in else-if chain
                if (n.child_count >= 3 && n.children[2] != null
                    && n.children[2].kind == Nk.N_EXPR_IF && n.children[2].child_count >= 1
                    && n.children[0] != null)
                {
                    if (v_same(n.children[0], n.children[2].children[0]))
                    {
                        fv.n_dupcond = fv.n_dupcond + 1;
                    }
                }
                if (then_t && else_t) return true;
            }
            break;
        case Nk.N_BLOCK:
            {
                for (usz i = 0; i < n.child_count; i++)
                {
                    Node* c = n.children[i];
                    if (local_term && c != null) { fv.n_unreach = fv.n_unreach + 1; }
                    bool ct = fv_walk(fv, c, termd || local_term);
                    if (ct) { local_term = true; }
                }
                if (local_term) return true;
            }
            break;
        case Nk.N_EXPR_WHILE:
        case Nk.N_EXPR_FOR:
        case Nk.N_EXPR_LOOP:
            for (usz i = 0; i < n.child_count; i++)
            {
                fv_walk(fv, n.children[i], termd || local_term);
            }
            break;
        case Nk.N_EXPR_BINARY:
            {
                Tk op = (Tk)n.p.op;
                for (usz i = 0; i < n.child_count; i++)
                {
                    fv_walk(fv, n.children[i], termd || local_term);
                }
                if (n.child_count >= 2)
                {
                    Node* rhs = n.children[1];
                    if ((op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT) && v_zero(rhs))
                    {
                        fv.n_divzero = fv.n_divzero + 1;
                    }
                    if ((op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT)
                        && rhs != null && rhs.kind == Nk.N_EXPR_INT)
                    {
                        long sh = (long)rhs.p.ival;
                        if (sh < 0 || sh >= 64) { fv.n_shiftovf = fv.n_shiftovf + 1; }
                    }
                    if ((op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ) && n.children[1] != null
                        && n.children[1].kind == Nk.N_EXPR_BOOL)
                    {
                        fv.n_boolcmp = fv.n_boolcmp + 1;
                    }
                }
            }
            break;
        case Nk.N_EXPR_UNARY:
            if (n.child_count >= 1)
            {
                Node* c = n.children[0];
                if ((Tk)n.p.op == Tk.TOKEN_BANG && c != null
                    && c.kind == Nk.N_EXPR_UNARY && (Tk)c.p.op == Tk.TOKEN_BANG)
                {
                    fv.n_doubleneg = fv.n_doubleneg + 1;
                }
                fv_walk(fv, c, termd || local_term);
            }
            break;
        case Nk.N_STMT_ASSIGN:
            if (n.child_count >= 2)
            {
                Node* lhs = n.children[0];
                Node* rhs = n.children[1];
                if (lhs != null && rhs != null
                    && lhs.kind == Nk.N_EXPR_IDENT && rhs.kind == Nk.N_EXPR_IDENT
                    && lhs.name_id != 0 && lhs.name_id == rhs.name_id)
                {
                    fv.n_selfassign = fv.n_selfassign + 1;
                }
            }
            for (usz i = 0; i < n.child_count; i++)
            {
                fv_walk(fv, n.children[i], termd || local_term);
            }
            break;
        default:
            for (usz i = 0; i < n.child_count; i++)
            {
                fv_walk(fv, n.children[i], termd || local_term);
            }
            break;
    }
    return local_term;
}

fn bool fn_body_empty(Node* f)
{
    for (usz i = 0; i < f.child_count; i++)
    {
        Node* c = f.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_CLAUSE)
        {
            if (c.child_count >= 2)
            {
                Node* body = c.children[c.child_count - 1];
                if (body != null && body.kind == Nk.N_BLOCK && body.child_count == 0) { continue; }
                return false;
            }
            return false;
        }
        if (c.kind == Nk.N_BLOCK)
        {
            if (c.child_count == 0) continue;
            return false;
        }
        return false;
    }
    return true;
}

fn void fv_scan(FnVerify* fv, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        fv.n_fns_checked = fv.n_fns_checked + 1;
        if (fn_body_empty(n)) { fv.n_empty = fv.n_empty + 1; }
        for (usz i = 0; i < n.child_count; i++)
        {
            fv_walk(fv, n.children[i], false);
        }
        return;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        fv_scan(fv, n.children[i]);
    }
}

fn void FnVerify.run(FnVerify* fv, Node* prog)
{
    if (prog != null) fv_scan(fv, prog);
}

fn void FnVerify.report(FnVerify* fv)
{
    printf("  fnverify fns     : %d checked\n", (int)fv.n_fns_checked);
    printf("  fnverify shapes  : unreach=%d empty=%d div0=%d shift=%d dupcond=%d\n",
           (int)fv.n_unreach, (int)fv.n_empty, (int)fv.n_divzero,
           (int)fv.n_shiftovf, (int)fv.n_dupcond);
    printf("  fnverify style   : !!x=%d boolcmp=%d selfassign=%d\n",
           (int)fv.n_doubleneg, (int)fv.n_boolcmp, (int)fv.n_selfassign);
}

fn void FnVerify.free(FnVerify* fv)
{
    // Nothing allocated; nothing to free.
    if (fv == null) return;
}
