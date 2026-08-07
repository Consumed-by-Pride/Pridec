// ============================================================================
// pfront_dfe.c3 — Dead-Flag / predicate-aware DCE using CFG reachability
// ----------------------------------------------------------------------------
// ADCE removes statements that are not live (effects/unused results), but
// it cannot prove an entire branch arm dead when the condition is folded
// by SCCP to a constant. DFE computes reachability under the folded
// conditions, marking blocks that become unreachable because their only
// incoming edges are on the not-taken side of a constant branch.
//
// This is a lightweight companion to SCCP+ADCE: it does not mutate the
// AST, it only counts dead blocks/statements and reports. The CFG
// simplification that actually cuts edges lives in a later tree pass.
// ============================================================================

module pfront_dfe;

import pfront_core;
import pfront_cfg;
import pfront_lex;
import pfront_sccp;

alias Nk   = pfront_core::NodeKind;
alias Tk   = pfront_lex::TokenType;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias TermKind = pfront_cfg::TermKind;
alias Lval    = pfront_sccp::Lval;
alias Lattice = pfront_sccp::Lattice;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

struct Dfe
{
    Arena* arena;
    Cfg*   cfg;
    bool*  dead;
    bool*  br_known;
    bool*  br_taken;
    pfront_sccp::Sccp* sccp;

    usz dead_blocks;
    usz dead_stmts;
    usz folded_branches;
}

fn void Dfe.init(Dfe* d, Arena* a)
{
    d.arena = a;
    d.cfg = null;
    d.dead = null;
    d.br_known = null;
    d.br_taken = null;
    d.sccp = null;
    d.dead_blocks = 0;
    d.dead_stmts = 0;
    d.folded_branches = 0;
}

// Look up the Lval for an expression node via the SCCP table.
fn Lval* dfe_lv(Dfe* d, Node* e)
{
    if (e == null || d.sccp == null) return null;
    return d.sccp.get(e);
}

fn bool dfe_is_const_bool(Dfe* d, Node* e, bool* out)
{
    Lval* lv = dfe_lv(d, e);
    if (lv == null) return false;
    if (lv.lat != Lattice.LAT_CONST) return false;
    if (!lv.is_bool)
    {
        // Also accept integer 0/1 (C-style truth) only when width is 1.
        if (lv.is_float) return false;
        if (lv.ival != 0 && lv.ival != 1) return false;
    }
    out[0] = lv.ival != 0;
    return true;
}

fn bool dfe_term_folds(Dfe* d, Block* b, bool* taken)
{
    if (b == null) return false;
    if (b.term_node == null) return false;
    Node* cond = b.term_node;
    if (b.term == TermKind.TERM_IF)
    {
        bool v;
        if (dfe_is_const_bool(d, cond, &v)) { taken[0] = v; return true; }
        if (cond.kind == Nk.N_EXPR_UNARY && (Tk)cond.p.op == Tk.TOKEN_BANG && cond.child_count >= 1)
        {
            bool vv;
            if (dfe_is_const_bool(d, cond.children[0], &vv)) { taken[0] = !vv; return true; }
        }
    }
    return false;
}

fn void Dfe.run_on_cfg(Dfe* d, Cfg* c, pfront_sccp::Sccp* s)
{
    if (c == null) return;
    d.cfg = c;
    d.sccp = s;
    usz nb = c.block_count;
    if (nb == 0) return;

    d.dead = (bool*)calloc(nb, 1);
    d.br_known = (bool*)calloc(nb, 1);
    d.br_taken = (bool*)calloc(nb, 1);
    if (d.dead == null) return;

    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        bool taken;
        if (dfe_term_folds(d, b, &taken))
        {
            d.br_known[bi] = true;
            d.br_taken[bi] = taken;
            d.folded_branches = d.folded_branches + 1;
        }
    }

    // Flood-fill reachability from entry along edges that are possible
    // given folded branches.
    char* live = (char*)calloc(nb, 1);
    usz* wl = (usz*)malloc(nb * 8);
    char* inwl = (char*)calloc(nb, 1);
    usz wlh = 0; usz wlt = 0;
    if (c.entry >= 0 && (usz)c.entry < nb)
    {
        live[c.entry] = 1;
        wl[wlt++] = (usz)c.entry;
        inwl[c.entry] = 1;
    }
    while (wlh < wlt)
    {
        usz bi = wl[wlh++];
        inwl[bi] = 0;
        if (bi >= nb) continue;
        Block* b = &c.blocks[bi];
        if (d.br_known[bi])
        {
            // Only one successor is live.
            usz si = d.br_taken[bi] ? 0 : 1;
            if (si < b.succ_count)
            {
                int sb = b.succs[si];
                if (sb >= 0 && (usz)sb < nb && !live[sb])
                {
                    live[sb] = 1;
                    if (!inwl[sb]) { wl[wlt++] = (usz)sb; inwl[sb] = 1; }
                }
            }
            // Conservatively mark all succs when the taken branch is a
            // backedge: loops have break/continue edges that may still
            // be reachable from the body. Simple heuristic: if succs[0]
            // is a block with a lower ID than bi, it is a backedge and
            // we must also propagate to any other successors (e.g. the
            // loop exit).
            if (b.succ_count > 1 && b.succs[0] >= 0 && (usz)b.succs[0] < bi)
            {
                for (usz s2 = 1; s2 < b.succ_count; s2++)
                {
                    int sb = b.succs[s2];
                    if (sb >= 0 && (usz)sb < nb && !live[sb])
                    {
                        live[sb] = 1;
                        if (!inwl[sb]) { wl[wlt++] = (usz)sb; inwl[sb] = 1; }
                    }
                }
            }
        }
        else
        {
            for (usz si = 0; si < b.succ_count; si++)
            {
                int sb = b.succs[si];
                if (sb >= 0 && (usz)sb < nb && !live[sb])
                {
                    live[sb] = 1;
                    if (!inwl[sb]) { wl[wlt++] = (usz)sb; inwl[sb] = 1; }
                }
            }
        }
    }

    for (usz bi = 0; bi < nb; bi++)
    {
        if (!live[bi])
        {
            d.dead[bi] = true;
            d.dead_blocks = d.dead_blocks + 1;
            if (bi < c.block_count)
            {
                d.dead_stmts = d.dead_stmts + c.blocks[bi].stmt_count;
            }
        }
    }

    free((void*)live); free((void*)wl); free((void*)inwl);
}

fn void Dfe.report(Dfe* d)
{
    printf("  dfe folded br    : %d\n", (int)d.folded_branches);
    printf("  dfe dead blocks  : %d\n", (int)d.dead_blocks);
    printf("  dfe dead stmts   : %d\n", (int)d.dead_stmts);
}

fn void Dfe.free(Dfe* d)
{
    free((void*)d.dead);
    free((void*)d.br_known);
    free((void*)d.br_taken);
    d.dead = null;
    d.br_known = null;
    d.br_taken = null;
}
