// ============================================================================
// theory_crdt.c3 — CALM/CRDT lattice for commutativity analysis
// ----------------------------------------------------------------------------
// Implements the CALM theorem / CRDT lattice: each operation on a collection
// is classified into an ACI (associative/commutative/idempotent) merge class
// or NONCOM (non-monotonic, requires coordination). Lattice join computes the
// least CRDT data type that supports all classified operations on that
// collection.
//
// References: Shapiro et al. 2011; Hellerstein/Alvaro CALM 2010.
// ============================================================================

module theory_crdt;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

enum CrdtClass : int
{
    CRDT_BOTTOM,
    CRDT_OPSET,
    CRDT_COUNTER,
    CRDT_LWW,
    CRDT_MVREG,
    CRDT_ORSET,
    CRDT_SEQ,
    CRDT_NONCOM
}

fn char* crdt_name(CrdtClass c)
{
    switch (c)
    {
        case CrdtClass.CRDT_BOTTOM: return "bot";
        case CrdtClass.CRDT_OPSET: return "gset";
        case CrdtClass.CRDT_COUNTER: return "pnctr";
        case CrdtClass.CRDT_LWW: return "lww";
        case CrdtClass.CRDT_MVREG: return "mvreg";
        case CrdtClass.CRDT_ORSET: return "orset";
        case CrdtClass.CRDT_SEQ: return "rga";
        case CrdtClass.CRDT_NONCOM: return "noncom";
    }
}

fn CrdtClass crdt_merge(CrdtClass a, CrdtClass b)
{
    if (a == CrdtClass.CRDT_NONCOM || b == CrdtClass.CRDT_NONCOM) return CrdtClass.CRDT_NONCOM;
    if (a == b) return a;
    if (a == CrdtClass.CRDT_BOTTOM) return b;
    if (b == CrdtClass.CRDT_BOTTOM) return a;
    if ((a == CrdtClass.CRDT_OPSET && b == CrdtClass.CRDT_COUNTER)
     || (a == CrdtClass.CRDT_COUNTER && b == CrdtClass.CRDT_OPSET))
    {
        return CrdtClass.CRDT_COUNTER;
    }
    if (a == CrdtClass.CRDT_SEQ || b == CrdtClass.CRDT_SEQ) return CrdtClass.CRDT_SEQ;
    if (a == CrdtClass.CRDT_ORSET || b == CrdtClass.CRDT_ORSET) return CrdtClass.CRDT_ORSET;
    if (a == CrdtClass.CRDT_MVREG || b == CrdtClass.CRDT_MVREG) return CrdtClass.CRDT_MVREG;
    if (a == CrdtClass.CRDT_LWW || b == CrdtClass.CRDT_LWW) return CrdtClass.CRDT_LWW;
    return CrdtClass.CRDT_NONCOM;
}

fn CrdtClass classify_op(Tk op)
{
    switch (op)
    {
        case Tk.TOKEN_PLUS:
        case Tk.TOKEN_STAR:
        case Tk.TOKEN_PIPE:
        case Tk.TOKEN_PIPEPIPE:
        case Tk.TOKEN_AMP:
        case Tk.TOKEN_AMPAMP:
        {
            return CrdtClass.CRDT_COUNTER;
        }
        case Tk.TOKEN_MINUS:
        case Tk.TOKEN_SLASH:
        case Tk.TOKEN_PERCENT:
        {
            return CrdtClass.CRDT_NONCOM;
        }
        case Tk.TOKEN_EQ:
        {
            return CrdtClass.CRDT_LWW;
        }
        default:
            return CrdtClass.CRDT_OPSET;
    }
}

struct CrdtAnalysis
{
    Arena* arena;
    CrdtClass current;
    usz n_ops;
    usz n_monotonic;
    usz n_nonmonotonic;
    usz n_sets;
    usz n_counters;
    usz n_lww;
    usz n_mvreg;
    usz n_seq;
    usz n_coordination;
}

fn void CrdtAnalysis.init(CrdtAnalysis* c, Arena* a)
{
    c.arena = a; c.current = CrdtClass.CRDT_BOTTOM;
    c.n_ops = 0; c.n_monotonic = 0; c.n_nonmonotonic = 0;
    c.n_sets = 0; c.n_counters = 0; c.n_lww = 0; c.n_mvreg = 0;
    c.n_seq = 0; c.n_coordination = 0;
}

fn void CrdtAnalysis.merge_here(CrdtAnalysis* c, CrdtClass k)
{
    c.n_ops = c.n_ops + 1;
    c.current = crdt_merge(c.current, k);
    switch (k)
    {
        case CrdtClass.CRDT_OPSET: c.n_sets = c.n_sets + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_COUNTER: c.n_counters = c.n_counters + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_LWW: c.n_lww = c.n_lww + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_MVREG: c.n_mvreg = c.n_mvreg + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_ORSET: c.n_sets = c.n_sets + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_SEQ: c.n_seq = c.n_seq + 1; c.n_monotonic = c.n_monotonic + 1; break;
        case CrdtClass.CRDT_NONCOM: c.n_nonmonotonic = c.n_nonmonotonic + 1; c.n_coordination = c.n_coordination + 1; break;
        default: break;
    }
}

fn void CrdtAnalysis.walk(CrdtAnalysis* c, Node* n, int depth)
{
    if (n == null || depth > 200) return;
    switch (n.kind)
    {
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            CrdtClass k = classify_op(op);
            c.merge_here(k);
            break;
        }
        case Nk.N_STMT_ASSIGN:
        {
            c.merge_here(CrdtClass.CRDT_LWW);
            break;
        }
        case Nk.N_EXPR_CALL:
        {
            if (n.child_count >= 1 && n.children[0] != null
                && n.children[0].kind == Nk.N_EXPR_PATH)
            {
                char* nm = n.children[0].p.sptr;
                usz nl = n.children[0].p.slen;
                bool insert = false;
                bool remove = false;
                if (nm != null && nl >= 3)
                {
                    if (nm[0] == 'a' && nm[1] == 'd' && nm[2] == 'd') insert = true;
                    if (nm[0] == 'i' && nm[1] == 'n' && nm[2] == 's') insert = true;
                    if (nm[0] == 'p' && nm[1] == 'u' && nm[2] == 's') insert = true;
                    if (nm[0] == 'r' && nm[1] == 'e' && nm[2] == 'm') remove = true;
                    if (nm[0] == 'd' && nm[1] == 'e' && nm[2] == 'l') remove = true;
                }
                if (insert) { c.merge_here(CrdtClass.CRDT_OPSET); }
                else if (remove) { c.merge_here(CrdtClass.CRDT_NONCOM); }
                else { c.merge_here(CrdtClass.CRDT_LWW); }
            }
            break;
        }
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) c.walk(n.children[i], depth + 1);
}

fn void CrdtAnalysis.report(CrdtAnalysis* c)
{
    printf("  crdt-calm        : %d ops (mono=%d nonmono=%d), final class %s\n",
           (int)c.n_ops, (int)c.n_monotonic, (int)c.n_nonmonotonic, crdt_name(c.current));
    printf("  crdt-kinds       : set=%d ctr=%d lww=%d mvreg=%d seq=%d, %d need coord\n",
           (int)c.n_sets, (int)c.n_counters, (int)c.n_lww, (int)c.n_mvreg,
           (int)c.n_seq, (int)c.n_coordination);
}

fn void CrdtAnalysis.destroy(CrdtAnalysis* c) { (void)c; }
