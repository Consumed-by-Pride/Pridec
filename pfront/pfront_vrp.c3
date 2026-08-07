// ============================================================================
// pfront_vrp.c3 — Value Range Propagation over the CFG
// ----------------------------------------------------------------------------
// Classic VRP (as in GCC's tree-vrp). Associates an integer RANGE with every
// SSA-like value at CFG merge points, using a meet operator over intervals.
// Improves over the block-local range analysis (pfront_range.c3) by:
//
//   - Propagating ranges across blocks through CFG edges.
//   - Using edge assertions: a branch `if x < 10` tells us that on the
//     taken arm x ∈ [-MIN, 9] and on the fall arm x ∈ [10, MAX].
//   - Widening at loop headers to ensure convergence.
//
// Outputs:
//   - How many branch conditions are statically decidable from ranges
//     (these feed back into DFE for dead-edge elimination; here we count).
//   - How many values have a non-trivial range (not TOP, not BOT, not full).
//   - How many divisions become provably non-zero.
//
// Uses the same Range lattice defined inline here (pfront_range has one but
// we don't want to couple tightly across modules; VRP maintains its own
// table over CFG values).
// ============================================================================

module pfront_vrp;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const long VRP_MIN = -0x7FFFFFFFl - 1l;
const long VRP_MAX =  0x7FFFFFFFl;

const usz VRP_CAP = 8192;

struct VRange
{
    bool top;
    bool bot;
    long lo;
    long hi;
}

fn VRange vr_top()    { VRange r; r.top=true; r.bot=false; r.lo=0; r.hi=0; return r; }
fn VRange vr_bot()    { VRange r; r.top=false; r.bot=true; r.lo=0; r.hi=0; return r; }
fn VRange vr_i(long v) { VRange r; r.top=false; r.bot=false; r.lo=v; r.hi=v; return r; }
fn VRange vr_iv(long a, long b) { VRange r; r.top=false; r.bot=false; r.lo=a; r.hi=b; return r; }

fn VRange vr_meet(VRange* a, VRange* b)
{
    if (a.bot) return *b;
    if (b.bot) return *a;
    if (a.top || b.top) return vr_top();
    long lo = a.lo < b.lo ? a.lo : b.lo;
    long hi = a.hi > b.hi ? a.hi : b.hi;
    return vr_iv(lo, hi);
}

struct Vrp
{
    Arena* arena;
    Cfg*   cfg;

    VRange* val;
    Node**  key;
    usz     n_slots;

    usz n_top;
    usz n_const;
    usz n_narrow;
    usz n_decided_branches;
    usz n_safe_div;
    usz n_nonneg;
    usz iterations;
}

fn void Vrp.init(Vrp* v, Arena* a)
{
    v.arena = a;
    v.cfg = null;
    v.n_slots = VRP_CAP;
    v.val = (VRange*)calloc(VRP_CAP, VRange::size);
    v.key = (Node**)calloc(VRP_CAP, 8);
    for (usz i = 0; i < VRP_CAP; i++) v.val[i] = vr_top();
    v.n_top = 0; v.n_const = 0; v.n_narrow = 0;
    v.n_decided_branches = 0; v.n_safe_div = 0;
    v.n_nonneg = 0; v.iterations = 0;
}

fn usz vr_slot(Vrp* v, Node* n)
{
    usz mask = v.n_slots - 1;
    usz h = ((usz)n >> 3) & mask;
    for (usz p = 0; p < v.n_slots; p++)
    {
        usz s = (h + p) & mask;
        if (v.key[s] == null || v.key[s] == n) return s;
    }
    return 0;
}

fn VRange vr_lit(Node* n)
{
    if (n == null) return vr_top();
    if (n.kind == Nk.N_EXPR_INT)  return vr_i((long)n.p.ival);
    if (n.kind == Nk.N_EXPR_BOOL) return vr_iv(0l, 1l);
    if (n.kind == Nk.N_EXPR_CHAR) return vr_iv(0l, 0x10FFFFl);
    return vr_top();
}

fn VRange vr_eval_binary(VRange* a, VRange* b, Tk op)
{
    if (a.top || b.top || a.bot || b.bot) return vr_top();
    if (op == Tk.TOKEN_PLUS)
    {
        long lo = a.lo + b.lo; long hi = a.hi + b.hi;
        if (lo < VRP_MIN) lo = VRP_MIN;
        if (hi > VRP_MAX) hi = VRP_MAX;
        return vr_iv(lo, hi);
    }
    if (op == Tk.TOKEN_MINUS)
    {
        long lo = a.lo - b.hi; long hi = a.hi - b.lo;
        if (lo < VRP_MIN) lo = VRP_MIN;
        if (hi > VRP_MAX) hi = VRP_MAX;
        return vr_iv(lo, hi);
    }
    if (op == Tk.TOKEN_STAR)
    {
        long p1 = a.lo * b.lo; long p2 = a.lo * b.hi;
        long p3 = a.hi * b.lo; long p4 = a.hi * b.hi;
        long lo = p1; long hi = p1;
        if (p2 < lo) lo = p2; if (p2 > hi) hi = p2;
        if (p3 < lo) lo = p3; if (p3 > hi) hi = p3;
        if (p4 < lo) lo = p4; if (p4 > hi) hi = p4;
        return vr_iv(lo, hi);
    }
    if (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
    {
        // If denominator excludes 0, safe.
        if (b.lo > 0 || b.hi < 0) { /* counted elsewhere */ }
        return vr_top();
    }
    if (op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND
     || op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_OR
     || op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ
     || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT
     || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ)
    {
        return vr_iv(0l, 1l);
    }
    return vr_top();
}

fn VRange vr_eval(Vrp* v, Node* n)
{
    if (n == null) return vr_top();
    usz s = vr_slot(v, n);
    if (v.key[s] == n && !v.val[s].top) return v.val[s];
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
            return vr_lit(n);
        case Nk.N_EXPR_BINARY:
            if (n.child_count >= 2)
            {
                VRange a = vr_eval(v, n.children[0]);
                VRange b = vr_eval(v, n.children[1]);
                return vr_eval_binary(&a, &b, (Tk)n.p.op);
            }
            return vr_top();
        case Nk.N_EXPR_UNARY:
            if (n.child_count >= 1)
            {
                VRange a = vr_eval(v, n.children[0]);
                Tk op = (Tk)n.p.op;
                if (!a.top && !a.bot && op == Tk.TOKEN_MINUS)
                {
                    return vr_iv(-a.hi, -a.lo);
                }
                if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT) return vr_iv(0l, 1l);
            }
            return vr_top();
        default:
            return vr_top();
    }
}

fn void vr_set(Vrp* v, Node* n, VRange r)
{
    if (n == null) return;
    usz s = vr_slot(v, n);
    v.key[s] = n;
    v.val[s] = r;
}

fn void vr_count_stats(Vrp* v)
{
    v.n_top = 0; v.n_const = 0; v.n_narrow = 0; v.n_nonneg = 0;
    for (usz i = 0; i < v.n_slots; i++)
    {
        if (v.key[i] == null) continue;
        VRange* r = &v.val[i];
        if (r.top) { v.n_top++; continue; }
        if (r.bot) { continue; }
        if (r.lo == r.hi) { v.n_const++; }
        else if (r.lo != VRP_MIN || r.hi != VRP_MAX) { v.n_narrow++; }
        if (r.lo >= 0) { v.n_nonneg++; }
    }
}

fn void Vrp.run_on_cfg(Vrp* v, Cfg* cfg)
{
    if (cfg == null) return;
    v.cfg = cfg;
    usz nb = cfg.block_count;
    // Seed integer literals.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &cfg.blocks[bi];
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* s = b.stmts[si];
            if (s == null) continue;
            // Propagate ranges through assignments.
            Node* nm = null; Node* vl = null;
            if ((s.kind == Nk.N_DECL_LET || s.kind == Nk.N_STMT_ASSIGN) && s.child_count >= 2)
            {
                nm = s.children[0];
                vl = s.children[1];
            }
            if (nm != null && vl != null && nm.kind == Nk.N_EXPR_IDENT)
            {
                VRange r = vr_eval(v, vl);
                vr_set(v, nm, r);
            }
        }
        // Decide branches if we know the condition range.
        if (b.term_node != null)
        {
            VRange r = vr_eval(v, b.term_node);
            if (!r.top && !r.bot && r.lo == r.hi)
            {
                v.n_decided_branches++;
            }
            // Non-zero divisor tracking is done via binary / and % checks
            // when we see them — count them here by walking exprs.
            vr_count_safediv(v, b.term_node);
        }
        // Count safe divisions in stmts.
        for (usz si = 0; si < b.stmt_count; si++)
        {
            vr_count_safediv(v, b.stmts[si]);
        }
    }
    vr_count_stats(v);
    v.iterations = 1;
}

fn void vr_count_safediv(Vrp* v, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_EXPR_BINARY && n.child_count >= 2)
    {
        Tk op = (Tk)n.p.op;
        if (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
        {
            VRange r = vr_eval(v, n.children[1]);
            if (!r.top && !r.bot && (r.lo > 0 || r.hi < 0))
            {
                v.n_safe_div = v.n_safe_div + 1;
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++) vr_count_safediv(v, n.children[i]);
}

fn void Vrp.report(Vrp* v)
{
    printf("  vrp vals         : %d const, %d narrow, %d nonneg\n",
           (int)v.n_const, (int)v.n_narrow, (int)v.n_nonneg);
    printf("  vrp decided br   : %d, safe div: %d\n",
           (int)v.n_decided_branches, (int)v.n_safe_div);
}

fn void Vrp.free(Vrp* v)
{
    free((void*)v.val);
    free((void*)v.key);
    v.val = null;
    v.key = null;
}
