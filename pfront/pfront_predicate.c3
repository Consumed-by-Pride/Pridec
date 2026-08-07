// ============================================================================
// pfront_predicate.c3 — Predicate analysis / path condition tracking
// ----------------------------------------------------------------------------
// Walks each CFG collecting edge predicates (conditions under which a block
// is reached):
//
//   * After `if c then T else E`, the edge to T carries "c is true", edge to
//     E carries "c is false".
//   * After `if x == k` then T, T carries x=k.
//   * After guard `x != null`, the subsequent block carries x!=null.
//   * A chain of these is ANDed into a path condition per block.
//
// We collect predicate facts (lhs, cmpop, rhs-literal) in conjunctive normal
// form and propagate them forward at join points using intersection. This is
// the edge-predicate half of sparse conditional constant propagation; the
// SCCP pass already does lattice propagation, but this pass records the raw
// facts for use by nullchk, vrange, branchprob, etc.
//
// All counts are advisory.
// ============================================================================

module pfront_predicate;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk       = pfront_core::NodeKind;
alias Tk       = pfront_lex::TokenType;
alias Node     = pfront_core::PNode;
alias Arena    = pfront_core::Arena;
alias Cfg      = pfront_cfg::Cfg;
alias Block    = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;

extern fn int printf(char* fmt, ...);
extern fn void* malloc(usz size);
extern fn void  free(void* ptr);

const usz PRED_MAX_FACTS = 64;

struct Fact
{
    uint lhs;        // name_id
    Tk   op;
    long ival;       // for integer rhs
    bool rhs_is_null;
    bool is_not;     // fact is negated
}

struct PredSet
{
    Fact[PRED_MAX_FACTS] facts;
    usz count;
}

fn void predset_init(PredSet* p) { p.count = 0; }

fn void predset_add(PredSet* p, Fact f)
{
    if (p.count >= PRED_MAX_FACTS) { return; }
    // dedup
    for (usz i = 0; i < p.count; i++)
    {
        if (p.facts[i].lhs == f.lhs && p.facts[i].op == f.op
            && p.facts[i].ival == f.ival && p.facts[i].rhs_is_null == f.rhs_is_null
            && p.facts[i].is_not == f.is_not) { return; }
    }
    p.facts[p.count] = f;
    p.count = p.count + 1;
}

fn void predset_intersect(PredSet* out, PredSet* a, PredSet* b)
{
    out.count = 0;
    for (usz i = 0; i < a.count; i++)
    {
        Fact f = a.facts[i];
        for (usz j = 0; j < b.count; j++)
        {
            Fact g = b.facts[j];
            if (f.lhs == g.lhs && f.op == g.op && f.ival == g.ival
                && f.rhs_is_null == g.rhs_is_null && f.is_not == g.is_not)
            {
                predset_add(out, f); break;
            }
        }
    }
}

struct Predicate
{
    Arena*   arena;
    Cfg*     cfg;
    PredSet* bfacts;
    usz      n_nonnull;
    usz      n_eqconst;
    usz      n_range_facts;
    usz      n_negations;
    usz      n_facts_total;
}

fn void Predicate.init(Predicate* pa, Arena* a)
{
    pa.arena = a; pa.cfg = null; pa.bfacts = null;
    pa.n_nonnull = 0; pa.n_eqconst = 0; pa.n_range_facts = 0;
    pa.n_negations = 0; pa.n_facts_total = 0;
}

fn void collect_from_cond(PredSet* ps, Node* c, bool pol)
{
    if (c == null) { return; }
    if (c.kind == Nk.N_EXPR_BINARY && c.child_count >= 2)
    {
        Tk op = (Tk)c.p.op;
        Node* l = c.children[0]; Node* r = c.children[1];
        if (l == null) { return; }
        uint lhs = 0;
        if (l.kind == Nk.N_EXPR_IDENT) { lhs = l.name_id; }
        if (lhs == 0) { return; }
        Fact f;
        f.lhs = lhs; f.is_not = !pol; f.rhs_is_null = false; f.ival = 0;
        if (r != null && r.kind == Nk.N_EXPR_INT) { f.ival = (long)r.p.ival; }
        if (r != null && r.kind == Nk.N_EXPR_NULL) { f.rhs_is_null = true; f.ival = 0; }
        Tk real_op = op;
        if (!pol)
        {
            // negate op
            switch (op)
            {
                case Tk.TOKEN_EQEQ: real_op = Tk.TOKEN_NEQ; break;
                case Tk.TOKEN_NEQ:  real_op = Tk.TOKEN_EQEQ; break;
                case Tk.TOKEN_LT:   real_op = Tk.TOKEN_GTEQ; break;
                case Tk.TOKEN_GT:   real_op = Tk.TOKEN_LTEQ; break;
                case Tk.TOKEN_LTEQ: real_op = Tk.TOKEN_GT; break;
                case Tk.TOKEN_GTEQ: real_op = Tk.TOKEN_LT; break;
                default: break;
            }
        }
        f.op = real_op;
        predset_add(ps, f);
    }
    if (c.kind == Nk.N_EXPR_UNARY && (Tk)c.p.op == Tk.TOKEN_BANG && c.child_count >= 1)
    {
        collect_from_cond(ps, c.children[0], !pol);
    }
}

fn void Predicate.run_on_cfg(Predicate* pa, Cfg* cfg)
{
    if (cfg == null) { return; }
    pa.cfg = cfg;
    usz nb = cfg.block_count;
    pa.bfacts = (PredSet*)malloc((long)(nb * 2048));
    if (pa.bfacts == null) { return; }
    for (usz i = 0; i < nb; i++) { predset_init(&pa.bfacts[i]); }
    // Iterative dataflow: propagate facts through successor edges.
    for (usz iter = 0; iter < 8; iter++)
    {
        bool changed = false;
        for (usz i = 0; i < nb; i++)
        {
            Block* bb = &cfg.blocks[i];
            PredSet cur = pa.bfacts[i];
            // Apply term: if it's an if, add facts on edges.
            if (bb.term == TermKind.TERM_IF && bb.term_node != null && bb.succ_count >= 2)
            {
                PredSet t = cur; PredSet f = cur;
                collect_from_cond(&t, bb.term_node, true);
                collect_from_cond(&f, bb.term_node, false);
                int t_succ = bb.succs[0]; int f_succ = bb.succs[1];
                PredSet t_new; predset_init(&t_new);
                predset_intersect(&t_new, &pa.bfacts[t_succ], &t);
                if (t_new.count > pa.bfacts[t_succ].count) { pa.bfacts[t_succ] = t_new; changed = true; }
                PredSet f_new; predset_init(&f_new);
                predset_intersect(&f_new, &pa.bfacts[f_succ], &f);
                if (f_new.count > pa.bfacts[f_succ].count) { pa.bfacts[f_succ] = f_new; changed = true; }
            }
            else
            {
                for (usz j = 0; j < bb.succ_count; j++)
                {
                    int s = bb.succs[j];
                    if (s < 0 || (usz)s >= nb) { continue; }
                    // Pass through facts unchanged.
                    for (usz k = 0; k < cur.count; k++) { predset_add(&pa.bfacts[s], cur.facts[k]); }
                }
            }
        }
        if (!changed) { break; }
    }
    for (usz i = 0; i < nb; i++)
    {
        for (usz k = 0; k < pa.bfacts[i].count; k++)
        {
            Fact f = pa.bfacts[i].facts[k];
            pa.n_facts_total = pa.n_facts_total + 1;
            if (f.op == Tk.TOKEN_NEQ && f.rhs_is_null) { pa.n_nonnull = pa.n_nonnull + 1; }
            else if (f.op == Tk.TOKEN_EQEQ && !f.rhs_is_null) { pa.n_eqconst = pa.n_eqconst + 1; }
            else if (f.op == Tk.TOKEN_LT || f.op == Tk.TOKEN_LTEQ || f.op == Tk.TOKEN_GT || f.op == Tk.TOKEN_GTEQ)
            {
                pa.n_range_facts = pa.n_range_facts + 1;
            }
        }
    }
}


fn void Predicate.report(Predicate* pa)
{
    printf("  predicate        : %d facts propagated (nonnull=%d eqconst=%d range=%d)\n",
           (int)pa.n_facts_total, (int)pa.n_nonnull, (int)pa.n_eqconst, (int)pa.n_range_facts);
}

fn void Predicate.free(Predicate* pa)
{
    if (pa.bfacts != null) { free((void*)pa.bfacts); pa.bfacts = null; }
}
