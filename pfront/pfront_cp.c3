// ============================================================================
// pfront_cp.c3 — Local copy/constant propagation
// ----------------------------------------------------------------------------
// Copy propagation is the simplest useful dataflow analysis: if x = y reaches
// a use of x (unconditionally), replace x with y. When y is a constant we
// call it constant propagation (SCCP handles the conditional case; this
// pass handles the unconditional lexical case).
//
// On Pride's untyped CFG form this is straightforward:
//   - Within a basic block, walk statements forward; when we see
//     `let x = a` (or `x = a` for a mutable), record x -> a.
//   - When we hit ANY assignment to x (including compound), kill the
//     mapping.
//   - When we hit an effectful call or a non-pure expression, kill all
//     mappings to locals that could be modified through the call
//     (conservatively: kill everything).
//   - Record stats: how many copies could be forwarded. No AST mutation.
//
// This is per-block (local) only; global CP across blocks requires SSA
// form which SCCP already does.
// ============================================================================

module pfront_cp;

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

struct CopyProp
{
    Arena* arena;
    Cfg*   cfg;

    usz copy_facts;     // copies discovered (x = a)
    usz kill_facts;     // facts killed
    usz uses_fwd;       // uses that could be replaced
    usz blocks_run;
}

fn void CopyProp.init(CopyProp* cp, Arena* a)
{
    cp.arena = a;
    cp.cfg = null;
    cp.copy_facts = 0;
    cp.kill_facts = 0;
    cp.uses_fwd = 0;
    cp.blocks_run = 0;
}

// Is node an identifier reference we can track?
fn bool cp_is_tracking_target(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_IDENT;
}

// Is node a pure value (no effects, safe to duplicate)?
fn bool cp_is_pure(Node* n)
{
    if (n == null) return false;
    if (n.effects != 0) return false;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_FLOAT:
        case Nk.N_EXPR_NULL:
        case Nk.N_EXPR_UNIT:
        case Nk.N_EXPR_IDENT: return true;
        default: return false;
    }
}

fn usz cp_name_id(Node* n)
{
    if (n == null) return 0;
    return n.name_id;
}

// Walk a statement; returns true if the statement is an effectful call
// that forces killing all facts.
fn bool cp_stmt(CopyProp* cp, Node* s, Node** map_val, usz* map_name, usz* nfact)
{
    if (s == null) return false;
    // kill any facts whose value mentions the assigned target
    usz killed = 0;
    // let x = val  (N_DECL_LET)
    if (s.kind == Nk.N_DECL_LET)
    {
        Node* nm = (s.child_count >= 1) ? s.children[0] : null;
        Node* vl = (s.child_count >= 2) ? s.children[1] : null;
        if (nm != null && cp_is_pure(vl))
        {
            usz nmid = cp_name_id(nm);
            if (nmid != 0)
            {
                // Record fact nm -> vl
                if (*nfact < 256)
                {
                    map_name[*nfact] = nmid;
                    map_val[*nfact] = vl;
                    *nfact = *nfact + 1;
                    cp.copy_facts = cp.copy_facts + 1;
                }
            }
        }
        else if (nm != null)
        {
            // assignment to non-pure: kill facts mentioning nm as a name
            usz nmid = cp_name_id(nm);
            for (usz i = 0; i < *nfact; )
            {
                if (map_name[i] == nmid)
                {
                    // delete by swap with last
                    (*nfact)--;
                    map_name[i] = map_name[*nfact];
                    map_val[i] = map_val[*nfact];
                    killed++;
                }
                else { i++; }
            }
        }
    }
    // assign: x = e   (N_STMT_ASSIGN)
    else if (s.kind == Nk.N_STMT_ASSIGN)
    {
        Node* tgt = (s.child_count >= 1) ? s.children[0] : null;
        Node* vl  = (s.child_count >= 2) ? s.children[1] : null;
        if (tgt != null && cp_is_tracking_target(tgt))
        {
            usz nmid = cp_name_id(tgt);
            if (cp_is_pure(vl) && nmid != 0)
            {
                if (*nfact < 256)
                {
                    map_name[*nfact] = nmid;
                    map_val[*nfact] = vl;
                    *nfact = *nfact + 1;
                    cp.copy_facts++;
                }
            }
            else
            {
                for (usz i = 0; i < *nfact; )
                {
                    if (map_name[i] == nmid)
                    {
                        (*nfact)--;
                        map_name[i] = map_name[*nfact];
                        map_val[i] = map_val[*nfact];
                        killed++;
                    }
                    else { i++; }
                }
            }
        }
        else
        {
            // Compound assignment (e.g. x.f = y) — conservatively kill all.
            if (tgt != null) { return true; }
        }
    }
    else if (s.kind == Nk.N_STMT_COMPOUND_ASSIGN)
    {
        return true;
    }
    else if (s.kind == Nk.N_EXPR_CALL)
    {
        // Effectful calls clobber everything not pure.
        if (s.effects != 0) return true;
        // Even "pure" calls through an unresolved target are unknown.
        Node* tgt = (s.child_count >= 1) ? s.children[0] : null;
        if (tgt == null || tgt.resolved == null) return true;
    }
    cp.kill_facts = cp.kill_facts + killed;
    // Count identifier uses that map to a fact (possible forward target).
    cp_count_uses(s, map_val, map_name, nfact, cp);
    return false;
}

// Recursively count identifier uses that could be forwarded.
fn void cp_count_uses(Node* n, Node** map_val, usz* map_name, usz* nfact, CopyProp* cp)
{
    if (n == null) return;
    if (n.kind == Nk.N_EXPR_IDENT)
    {
        usz nmid = cp_name_id(n);
        for (usz i = 0; i < *nfact; i++)
        {
            if (map_name[i] == nmid)
            {
                cp.uses_fwd = cp.uses_fwd + 1;
                break;
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        cp_count_uses(n.children[i], map_val, map_name, nfact, cp);
    }
}

fn void CopyProp.run_on_cfg(CopyProp* cp, Cfg* c)
{
    if (c == null) return;
    cp.cfg = c;
    usz nb = c.block_count;
    Node** map_val = (Node**)malloc(256 * 8);
    usz*  map_name = (usz*)malloc(256 * 8);
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        usz nfact = 0;
        bool kill_all = false;
        for (usz si = 0; si < b.stmt_count; si++)
        {
            if (kill_all) break;
            Node* s = b.stmts[si];
            if (cp_stmt(cp, s, map_val, map_name, &nfact))
            {
                // effectful -> kill all
                cp.kill_facts = cp.kill_facts + nfact;
                nfact = 0;
                kill_all = true;
            }
        }
        cp.blocks_run = cp.blocks_run + 1;
    }
    free((void*)map_val);
    free((void*)map_name);
}

fn void CopyProp.report(CopyProp* cp)
{
    printf("  cp facts         : %d discovered, %d killed, %d forwardable uses\n",
           (int)cp.copy_facts, (int)cp.kill_facts, (int)cp.uses_fwd);
    printf("  cp blocks        : %d\n", (int)cp.blocks_run);
}
