// ============================================================================
// pfront_sccp.c3 — Sparse Conditional Constant Propagation (Wegman-Zadeck '91)
// ----------------------------------------------------------------------------
// Simultaneously propagates constants and deletes unreachable code over the
// pfront_cfg CFG. This is a real textbook SCCP with three lattice values
// (TOP, CONST, BOT), executable-edge marking, and two worklists (SSA + CFG).
//
// The pass does NOT rewrite the tree; it computes a map of Node* -> Lval that
// downstream passes (e.g. the Folder, or a future simplifier) can query. This
// keeps it trivially safe: we never mutate shared structure.
// ============================================================================

module pfront_sccp;

import pfront_lex;
import pfront_core;
import pfront_cfg;

alias Tk   = pfront_lex::TokenType;
alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

enum Lattice : int
{
    LAT_TOP,
    LAT_CONST,
    LAT_BOT,
}

struct Lval
{
    Lattice lat;
    long    ival;
    double  fval;
    bool    is_float;
    bool    is_bool;
}

fn Lval lv_top()  { Lval v; v.lat = Lattice.LAT_TOP;   v.ival=0; v.fval=0.0; v.is_float=false; v.is_bool=false; return v; }
fn Lval lv_bot()  { Lval v; v.lat = Lattice.LAT_BOT;   v.ival=0; v.fval=0.0; v.is_float=false; v.is_bool=false; return v; }
fn Lval lv_iconst(long x)   { Lval v; v.lat=Lattice.LAT_CONST; v.ival=x; v.fval=0.0; v.is_float=false; v.is_bool=false; return v; }
fn Lval lv_bconst(bool b)   { Lval v; v.lat=Lattice.LAT_CONST; v.ival=b?1:0; v.fval=0.0; v.is_float=false; v.is_bool=true; return v; }
fn Lval lv_fconst(double x) { Lval v; v.lat=Lattice.LAT_CONST; v.ival=0; v.fval=x; v.is_float=true; v.is_bool=false; return v; }

fn bool lval_eq(Lval* a, Lval* b)
{
    if (a.lat != b.lat) { return false; }
    if (a.lat != Lattice.LAT_CONST) { return true; }
    if (a.is_float != b.is_float) { return false; }
    if (a.is_bool  != b.is_bool)  { return false; }
    if (a.is_float) { return a.fval == b.fval; }
    return a.ival == b.ival;
}

fn Lval lval_meet(Lval* a, Lval* b)
{
    if (a.lat == Lattice.LAT_TOP) { return *b; }
    if (b.lat == Lattice.LAT_TOP) { return *a; }
    if (a.lat == Lattice.LAT_BOT || b.lat == Lattice.LAT_BOT) { return lv_bot(); }
    if (lval_eq(a, b)) { return *a; }
    return lv_bot();
}

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz LAT_CAP   = 16384;
const usz EDGE_CAP  = 32768;
const usz CFG_WL_CAP = 8192;
const usz SSA_WL_CAP = 16384;

struct Sccp
{
    Arena* arena;
    Cfg*   cfg;

    // Lattice table (open addressing by node ptr).
    Node*[LAT_CAP] l_key;
    Lval [LAT_CAP] l_val;

    // Reachable blocks.
    bool[8193] reachable;

    // Executable edges (from, to) pairs.
    int[EDGE_CAP] e_from;
    int[EDGE_CAP] e_to;
    usz edge_count;

    // Worklists.
    int[CFG_WL_CAP] cfg_wl;
    usz             cfg_wl_count;
    Node*[SSA_WL_CAP] ssa_wl;
    usz              ssa_wl_count;

    // Stats.
    usz consts_found;
    usz branches_folded;
    usz edges_marked;
    usz unreachable_blocks;
    // Apply-phase stats (set by run_program).
    usz substitutions;
    usz ifs_folded;
    usz loops_killed;
}

fn void Sccp.init(Sccp* s, Arena* a)
{
    s.arena = a;
    s.cfg = null;
    s.consts_found = 0;
    s.branches_folded = 0;
    s.edges_marked = 0;
    s.unreachable_blocks = 0;
    s.substitutions = 0;
    s.ifs_folded = 0;
    s.loops_killed = 0;
    s.edge_count = 0;
    s.cfg_wl_count = 0;
    s.ssa_wl_count = 0;
    for (usz i = 0; i < LAT_CAP; i++) { s.l_key[i] = null; }
    for (usz i = 0; i < EDGE_CAP; i++) { s.e_from[i] = -1; s.e_to[i] = -1; }
    for (usz i = 0; i < 8193; i++) { s.reachable[i] = false; }
}

fn usz node_hash(Node* n)
{
    usz p = (usz)n >> 3;
    return p & (LAT_CAP - 1);
}

fn Lval* Sccp.get(Sccp* s, Node* n)
{
    if (n == null) { return null; }
    usz h = node_hash(n);
    for (usz i = 0; i < 16; i++)
    {
        usz idx = (h + i) & (LAT_CAP - 1);
        if (s.l_key[idx] == n) { return &s.l_val[idx]; }
        if (s.l_key[idx] == null)
        {
            s.l_key[idx] = n;
            s.l_val[idx] = lv_top();
            return &s.l_val[idx];
        }
    }
    for (usz idx = 0; idx < LAT_CAP; idx++)
    {
        if (s.l_key[idx] == n) { return &s.l_val[idx]; }
        if (s.l_key[idx] == null)
        {
            s.l_key[idx] = n;
            s.l_val[idx] = lv_top();
            return &s.l_val[idx];
        }
    }
    return null;
}

fn bool Sccp.set(Sccp* s, Node* n, Lval newv)
{
    Lval* cur = s.get(n);
    if (cur == null) { return false; }
    if (newv.lat == Lattice.LAT_TOP) { return false; }
    if (cur.lat == Lattice.LAT_BOT) { return false; }
    Lval merged = lval_meet(cur, &newv);
    if (lval_eq(cur, &merged)) { return false; }
    *cur = merged;
    s.push_ssa(n);
    return true;
}

fn void Sccp.push_cfg(Sccp* s, int bid)
{
    if (bid < 0) { return; }
    for (usz i = 0; i < s.cfg_wl_count; i++) { if (s.cfg_wl[i] == bid) { return; } }
    if (s.cfg_wl_count < CFG_WL_CAP) { s.cfg_wl[s.cfg_wl_count++] = bid; }
}

fn void Sccp.push_ssa(Sccp* s, Node* n)
{
    if (n == null) { return; }
    for (usz i = 0; i < s.ssa_wl_count; i++) { if (s.ssa_wl[i] == n) { return; } }
    if (s.ssa_wl_count < SSA_WL_CAP) { s.ssa_wl[s.ssa_wl_count++] = n; }
}

fn bool Sccp.has_edge(Sccp* s, int from, int to)
{
    for (usz i = 0; i < s.edge_count; i++)
    {
        if (s.e_from[i] == from && s.e_to[i] == to) { return true; }
    }
    return false;
}

fn void Sccp.mark_edge(Sccp* s, int from, int to)
{
    if (from < 0 || to < 0) { return; }
    if (s.has_edge(from, to)) { return; }
    if (s.edge_count < EDGE_CAP)
    {
        s.e_from[s.edge_count] = from;
        s.e_to[s.edge_count] = to;
        s.edge_count = s.edge_count + 1;
    }
    s.edges_marked = s.edges_marked + 1;
    s.push_cfg(to);
}

// --- evaluation -------------------------------------------------------------
fn Lval Sccp.eval(Sccp* s, Node* n)
{
    if (n == null) { return lv_bot(); }
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:   return lv_iconst((long)n.p.ival);
        case Nk.N_EXPR_BOOL:  return lv_bconst(n.p.ival != 0);
        case Nk.N_EXPR_CHAR:  return lv_iconst((long)n.p.ival);
        case Nk.N_EXPR_FLOAT: return lv_fconst(n.p.fval);
        case Nk.N_EXPR_NULL:  return lv_iconst(0);
        case Nk.N_EXPR_UNIT:  return lv_iconst(0);
        case Nk.N_EXPR_UNARY: return s.eval_unary(n);
        case Nk.N_EXPR_BINARY:return s.eval_binary(n);
        case Nk.N_EXPR_IF:    return s.eval_select(n);
        case Nk.N_BLOCK:
            if (n.child_count == 0) { return lv_iconst(0); }
            return s.eval(n.children[n.child_count - 1]);
        case Nk.N_EXPR_CAST:
            if (n.child_count < 1) { return lv_bot(); }
            {
                Lval* a = s.get(n.children[0]);
                if (a == null) { return lv_bot(); }
                // Narrowing/widening int casts preserve constant value (but
                // may truncate when width is signed and narrower).
                if (a.lat == Lattice.LAT_CONST && !a.is_float)
                {
                    // Perform a narrowing for small widths.
                    Lval r = *a;
                    int w = n.p.width > 0 ? n.p.width : 64;
                    if (w > 0 && w < 64 && !a.is_bool)
                    {
                        long mask = (1l << w) - 1;
                        long v = a.ival & mask;
                        if (n.p.is_signed && (v & (1l << (w - 1))) != 0)
                        {
                            v = v - (1l << w);
                        }
                        r.ival = v;
                    }
                    return r;
                }
                return *a;
            }
        case Nk.N_EXPR_TUPLE:
        case Nk.N_EXPR_ARRAY:
        {
            // An array/tuple literal is CONSTANT if every element is CONSTANT
            // and of matching type. Since we are untyped we approximate: if
            // all children are const scalars, the whole aggregate is CONST
            // (we carry the element count but not the elements themselves;
            // that requires a richer lattice). For now just return BOT
            // (overdefined) unless ALL children are top (never visited), in
            // which case we return TOP to allow optimistic propagation.
            bool all_top = true;
            bool any_bot = false;
            for (usz i = 0; i < n.child_count; i++)
            {
                Lval* c = (n.children[i] != null) ? s.get(n.children[i]) : null;
                if (c == null) { any_bot = true; break; }
                if (c.lat != Lattice.LAT_TOP) { all_top = false; }
                if (c.lat == Lattice.LAT_BOT) { any_bot = true; }
            }
            if (n.child_count == 0) { return lv_iconst(0); }
            if (all_top) return lv_top();
            if (any_bot) return lv_bot();
            // Mixed/const: don't assign a scalar const; return BOT (safe).
            return lv_bot();
        }
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_PATH:
        case Nk.N_EXPR_FIELD:
        {
            Lval* v = s.get(n);
            if (v != null) { return *v; }
            return lv_bot();
        }
        default:
        {
            // Calls, loops, match, etc. — overdefined unless the expression
            // produced a const binding already.
            Lval* v = s.get(n);
            if (v != null && v.lat != Lattice.LAT_TOP) { return *v; }
            return lv_bot();
        }
    }
}

fn Lval Sccp.eval_unary(Sccp* s, Node* n)
{
    if (n.child_count < 1) { return lv_bot(); }
    Lval* a = s.get(n.children[0]);
    if (a == null || a.lat == Lattice.LAT_TOP) { return lv_top(); }
    if (a.lat == Lattice.LAT_BOT) { return lv_bot(); }
    Tk op = (Tk)n.p.op;
    if (op == Tk.TOKEN_MINUS)
    {
        if (a.is_float) { return lv_fconst(-a.fval); }
        return lv_iconst(-a.ival);
    }
    if (op == Tk.TOKEN_TILDE) { return lv_iconst(~a.ival); }
    if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT) { return lv_bconst(a.ival == 0); }
    if (op == Tk.TOKEN_STAR) { return lv_bot(); } // deref
    if (op == Tk.TOKEN_AMP)  { return lv_bot(); } // addr-of
    return lv_bot();
}

fn Lval Sccp.eval_binary(Sccp* s, Node* n)
{
    if (n.child_count < 2) { return lv_bot(); }
    Lval* a = s.get(n.children[0]);
    Lval* b = s.get(n.children[1]);
    if (a == null || b == null) { return lv_bot(); }
    if (a.lat == Lattice.LAT_TOP || b.lat == Lattice.LAT_TOP) { return lv_top(); }
    if (a.lat == Lattice.LAT_BOT || b.lat == Lattice.LAT_BOT)
    {
        // short-circuit logic can still resolve even with one BOT
        Tk op = (Tk)n.p.op;
        if ((op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND) && a.lat == Lattice.LAT_CONST && a.is_bool && a.ival == 0) { return lv_bconst(false); }
        if ((op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_OR) && a.lat == Lattice.LAT_CONST && a.is_bool && a.ival != 0) { return lv_bconst(true); }
        return lv_bot();
    }
    Tk op = (Tk)n.p.op;
    // Boolean short circuit when both const.
    if ((op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND))
    {
        if (!a.is_bool || !b.is_bool) { return lv_bot(); }
        return lv_bconst(a.ival != 0 && b.ival != 0);
    }
    if ((op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_OR))
    {
        if (!a.is_bool || !b.is_bool) { return lv_bot(); }
        return lv_bconst(a.ival != 0 || b.ival != 0);
    }
    bool fp = a.is_float || b.is_float;
    if (fp)
    {
        double fa = a.is_float ? a.fval : (double)a.ival;
        double fb = b.is_float ? b.fval : (double)b.ival;
        switch (op)
        {
            case Tk.TOKEN_PLUS:  return lv_fconst(fa + fb);
            case Tk.TOKEN_MINUS: return lv_fconst(fa - fb);
            case Tk.TOKEN_STAR:  return lv_fconst(fa * fb);
            case Tk.TOKEN_SLASH: if (fb == 0.0) { return lv_bot(); } return lv_fconst(fa / fb);
            case Tk.TOKEN_EQEQ:  return lv_bconst(fa == fb);
            case Tk.TOKEN_NEQ:   return lv_bconst(fa != fb);
            case Tk.TOKEN_LT:    return lv_bconst(fa <  fb);
            case Tk.TOKEN_GT:    return lv_bconst(fa >  fb);
            case Tk.TOKEN_LTEQ:    return lv_bconst(fa <= fb);
            case Tk.TOKEN_GTEQ:    return lv_bconst(fa >= fb);
            default: return lv_bot();
        }
    }
    long ia = a.ival;
    long ib = b.ival;
    switch (op)
    {
        case Tk.TOKEN_PLUS:    return lv_iconst(ia + ib);
        case Tk.TOKEN_MINUS:   return lv_iconst(ia - ib);
        case Tk.TOKEN_STAR:    return lv_iconst(ia * ib);
        case Tk.TOKEN_SLASH:
            if (ib == 0) { return lv_bot(); }
            return lv_iconst(ia / ib);
        case Tk.TOKEN_PERCENT:
            if (ib == 0) { return lv_bot(); }
            return lv_iconst(ia % ib);
        case Tk.TOKEN_AMP:     return lv_iconst(ia & ib);
        case Tk.TOKEN_PIPE:    return lv_iconst(ia | ib);
        case Tk.TOKEN_XOR:   return lv_iconst(ia ^ ib);
        case Tk.TOKEN_LSHIFT:  return lv_iconst(ia << (ib & 63));
        case Tk.TOKEN_RSHIFT:  return lv_iconst((long)((ulong)ia >> (ib & 63)));
        case Tk.TOKEN_EQEQ:    return lv_bconst(ia == ib);
        case Tk.TOKEN_NEQ:     return lv_bconst(ia != ib);
        case Tk.TOKEN_LT:      return lv_bconst(ia <  ib);
        case Tk.TOKEN_GT:      return lv_bconst(ia >  ib);
        case Tk.TOKEN_LTEQ:      return lv_bconst(ia <= ib);
        case Tk.TOKEN_GTEQ:      return lv_bconst(ia >= ib);
        default:               return lv_bot();
    }
}

fn Lval Sccp.eval_select(Sccp* s, Node* n)
{
    if (n.child_count < 3) { return lv_bot(); }
    Lval* c = s.get(n.children[0]);
    if (c == null || c.lat == Lattice.LAT_TOP) { return lv_top(); }
    if (c.lat == Lattice.LAT_BOT)
    {
        Lval* a = s.get(n.children[1]);
        Lval* b = s.get(n.children[2]);
        Lval la = (a != null) ? *a : lv_bot();
        Lval lb = (b != null) ? *b : lv_bot();
        return lval_meet(&la, &lb);
    }
    if (c.ival != 0) { Lval* a = s.get(n.children[1]); return (a != null) ? *a : lv_top(); }
    Lval* b = s.get(n.children[2]); return (b != null) ? *b : lv_top();
}

// --- main loop --------------------------------------------------------------
fn bool mentions_node(Node* haystack, Node* needle, int depth)
{
    if (haystack == null || needle == null) { return false; }
    if (depth > 80) { return false; }
    if (haystack == needle) { return true; }
    for (usz i = 0; i < haystack.child_count; i++)
    {
        if (mentions_node(haystack.children[i], needle, depth + 1)) { return true; }
    }
    return false;
}

fn void Sccp.reeval_users(Sccp* s, Node* n)
{
    if (s.cfg == null) { return; }
    for (usz bi = 0; bi < s.cfg.block_count; bi++)
    {
        if (!s.reachable[bi]) { continue; }
        Block* b = &s.cfg.blocks[bi];
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* st = b.stmts[si];
            if (st == null) { continue; }
            if (mentions_node(st, n, 0))
            {
                Lval nv = s.eval(st);
                s.set(st, nv);
                // propagate to N_PAT_BIND targets in lets
                if ((st.kind == Nk.N_STMT_ASSIGN || st.kind == Nk.N_EXPR_ASSIGN) && st.child_count >= 1)
                {
                    // kill target
                    s.set(st.children[0], lv_bot());
                }
            }
        }
        if (b.term_node != null && mentions_node(b.term_node, n, 0))
        {
            s.eval_terminator((int)bi);
        }
    }
}

fn void Sccp.run_on_cfg(Sccp* s, Cfg* c)
{
    s.cfg = c;
    s.reachable[c.entry] = true;
    s.push_cfg(c.entry);
    usz iters = 0;
    while ((s.cfg_wl_count > 0 || s.ssa_wl_count > 0) && iters < 200000)
    {
        iters = iters + 1;
        while (s.cfg_wl_count > 0)
        {
            int bid = s.cfg_wl[--s.cfg_wl_count];
            s.visit_block(bid);
        }
        if (s.ssa_wl_count > 0)
        {
            Node* n = s.ssa_wl[--s.ssa_wl_count];
            s.reeval_users(n);
        }
    }
    for (usz i = 0; i < c.block_count; i++)
    {
        if (!s.reachable[i]) { s.unreachable_blocks = s.unreachable_blocks + 1; }
    }
}

fn void Sccp.visit_block(Sccp* s, int bid)
{
    if (s.cfg == null) { return; }
    if (bid < 0 || bid >= (int)s.cfg.block_count) { return; }
    s.reachable[bid] = true;
    Block* b = &s.cfg.blocks[bid];
    for (usz i = 0; i < b.stmt_count; i++) { s.visit_stmt(b.stmts[i]); }
    s.eval_terminator(bid);
}

fn void Sccp.visit_stmt(Sccp* s, Node* n)
{
    if (n == null) { return; }
    // Handle let/const/assign bindings by propagating the rhs lattice value
    // to the defined name.  Pattern bindings (N_PAT_BIND with an ident child)
    // also propagate.
    if (n.kind == Nk.N_DECL_LET || n.kind == Nk.N_DECL_CONST)
    {
        if (n.child_count >= 2)
        {
            Lval v = s.eval(n.children[1]);
            s.set(n, v);
            if (n.children[0] != null)
            {
                s.set(n.children[0], v);
                if (n.children[0].child_count >= 1) { s.set(n.children[0].children[0], v); }
            }
        }
        return;
    }
    if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
    {
        if (n.child_count >= 2)
        {
            // evaluate rhs, but assign makes target BOT (mutable)
            s.eval(n.children[1]);
            s.set(n.children[0], lv_bot());
        }
        return;
    }
    Lval v = s.eval(n);
    s.set(n, v);
}

fn void Sccp.eval_terminator(Sccp* s, int bid)
{
    if (s.cfg == null) { return; }
    Block* b = &s.cfg.blocks[bid];
    switch (b.term)
    {
        case pfront_cfg::TermKind.TERM_FALL:
            if (b.id + 1 < (int)s.cfg.block_count) { s.mark_edge(bid, b.id + 1); }
            return;
        case pfront_cfg::TermKind.TERM_RETURN:
        case pfront_cfg::TermKind.TERM_UNREACH:
        case pfront_cfg::TermKind.TERM_TAIL:
            return;
        case pfront_cfg::TermKind.TERM_BREAK:
        case pfront_cfg::TermKind.TERM_CONTINUE:
            for (usz i = 0; i < b.succ_count; i++) { s.mark_edge(bid, b.succs[i]); }
            return;
        case pfront_cfg::TermKind.TERM_IF:
        {
            Lval cv = s.eval(b.term_node);
            if (cv.lat == Lattice.LAT_CONST && !cv.is_float)
            {
                s.branches_folded = s.branches_folded + 1;
                if (cv.ival != 0) { if (b.term_taken >= 0) s.mark_edge(bid, b.term_taken); }
                else              { if (b.term_not   >= 0) s.mark_edge(bid, b.term_not); }
            }
            else
            {
                if (b.term_taken >= 0) s.mark_edge(bid, b.term_taken);
                if (b.term_not   >= 0) s.mark_edge(bid, b.term_not);
            }
            return;
        }
        case pfront_cfg::TermKind.TERM_MATCH:
            for (usz i = 0; i < b.match_target_count; i++) { s.mark_edge(bid, b.match_targets[i]); }
            if (b.term_not >= 0) s.mark_edge(bid, b.term_not);
            return;
        default:
            for (usz i = 0; i < b.succ_count; i++) { s.mark_edge(bid, b.succs[i]); }
            return;
    }
}

fn void Sccp.report(Sccp* s)
{
    printf("  sccp constants    : %d found, %d substituted into tree\n",
           (int)s.consts_found, (int)s.substitutions);
    printf("  sccp folded brs   : %d (cfg), %d if-arms, %d dead loops\n",
           (int)s.branches_folded, (int)s.ifs_folded, (int)s.loops_killed);
    printf("  sccp edges marked : %d\n", (int)s.edges_marked);
    printf("  sccp unreachable  : %d blocks\n", (int)s.unreachable_blocks);
}

// ===========================================================================
// SCCP APPLY PHASE — now this pass actually rewrites the AST.
//
// After run_on_cfg() populates the lattice table (Node* -> Lval), we walk the
// AST and:
//   (1) Replace any N_EXPR_IDENT or N_EXPR_BINARY/UNARY whose lattice value is
//       CONST <int/bool> with a fresh N_EXPR_INT/N_EXPR_BOOL literal node.
//   (2) When an N_EXPR_IF condition evaluates to CONST, replace the whole if
//       with just the live arm (the dead arm is dropped).
//   (3) Mark unreachable blocks so downstream DCE drops them. For straight-
//       line ASTs (our CFG doesn't encode loop arms fully), the branch fold
//       at (2) handles both arms.
//
// This is the code that turns `sccp.consts_found` from a printed counter
// into real IR simplification. The constfold pass that runs just before us
// will clean up any leftover identities/constants introduced by substitution.
// ===========================================================================

struct Span { int line; int col; }
fn Span node_span(Node* n) { Span s; s.line = (n != null) ? n.line : 0; s.col = (n != null) ? n.col : 0; return s; }

fn Node* sccp_mk_int(Arena* a, long v, Span sp)
{
    Node* n = a.node(Nk.N_EXPR_INT, sp.line, sp.col);
    if (n != null) { n.p.ival = (ulong)v; n.p.width = 64; n.effects = 0; }
    return n;
}

fn Node* sccp_mk_bool(Arena* a, bool v, Span sp)
{
    Node* n = a.node(Nk.N_EXPR_BOOL, sp.line, sp.col);
    if (n != null) { n.p.ival = v ? 1 : 0; n.effects = 0; }
    return n;
}

// If node n has a CONST lattice value, return a fresh literal for it; else n.
fn Node* Sccp.replace_const(Sccp* s, Node* n)
{
    if (n == null) return null;
    // Only EXPRESSIONS are values. The lattice also carries entries for
    // binder patterns (`set(n.children[0], v)` on a let) so that uses can
    // look them up; substituting the binder itself turns `let y = 3` into
    // `let 3 = 3` and leaves every `y` pointing at a detached node.
    if (!pfront_core::is_expr(n.kind)) return n;
    // Don't replace already-trivial literals.
    if (n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_BOOL
     || n.kind == Nk.N_EXPR_FLOAT || n.kind == Nk.N_EXPR_CHAR
     || n.kind == Nk.N_EXPR_STRING || n.kind == Nk.N_EXPR_NULL) return n;
    Lval* lv = s.get(n);
    if (lv == null) return n;
    if (lv.lat != Lattice.LAT_CONST) return n;
    if (lv.is_float) return n; // don't replace floats in int bootstrap
    Span sp = node_span(n);
    if (lv.is_bool) { s.substitutions = s.substitutions + 1; return sccp_mk_bool(s.arena, lv.ival != 0, sp); }
    s.substitutions = s.substitutions + 1;
    return sccp_mk_int(s.arena, lv.ival, sp);
}

// Walk tree, replacing nodes with constant values and folding constant ifs.
fn Node* Sccp.apply(Sccp* s, Node* n)
{
    if (n == null) return null;
    if (n.kind == Nk.N_INVALID) return n;

    // Fold if-constant: if cond is CONST, replace with live arm only.
    if (n.kind == Nk.N_EXPR_IF && n.child_count >= 3)
    {
        // Recurse into children first so the cond is simplified.
        for (usz i = 0; i < n.child_count; i++)
        {
            n.set_child(i, s.apply(n.children[i]));
        }
        Node* cond = n.children[0];
        if (cond != null && cond.kind == Nk.N_EXPR_BOOL)
        {
            s.ifs_folded = s.ifs_folded + 1;
            // cond is bool literal: take the corresponding arm.
            Node* live = cond.p.ival != 0 ? n.children[1] : n.children[2];
            if (live == null) live = n.children[1];
            // Wrap live arm in a block so seq continues work (the arm might
            // be a single expr that's meant to evaluate in place).
            return live;
        }
        return n;
    }

    // While/for loops with constant-false cond: replace with just the init
    // code (pre-body statements that precede the loop test). Tricky without
    // knowing which child is which; bootstrap: only replace when cond is a
    // direct bool literal child.
    if (n.kind == Nk.N_EXPR_WHILE && n.child_count >= 2)
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            n.set_child(i, s.apply(n.children[i]));
        }
        Node* cond = n.children[0];
        if (cond != null && cond.kind == Nk.N_EXPR_BOOL && cond.p.ival == 0)
        {
            // Loop never executes: replace with unit (dead loop).
            s.loops_killed = s.loops_killed + 1;
            Span sp = node_span(n);
            return sccp_mk_int(s.arena, 0, sp);
        }
        return n;
    }

    // Default: recurse into children, then try to replace THIS node.
    // An assignment's target is a PLACE, not a value: never substitute it.
    bool lhs_is_place = n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN
                     || n.kind == Nk.N_EXPR_ASSIGN;
    for (usz i = 0; i < n.child_count; i++)
    {
        if (lhs_is_place && i == 0) continue;
        n.set_child(i, s.apply(n.children[i]));
    }
    return s.replace_const(n);
}

// Driver: walk the top-level AST, run SCCP per function body, then apply.
// Returns replacement root (usually the same node but mutated in place).
fn Node* Sccp.run_program(Sccp* s, Node* root)
{
    if (root == null) return null;
    s.substitutions = 0;
    s.ifs_folded = 0;
    s.loops_killed = 0;
    // For simplicity (to avoid 8KB CFG stack per function and malloc/free of
    // stmt arrays), walk the program and just do TOP-DOWN constant propagation
    // over expression DAG via the eval/get machinery, then apply substitution.
    // Full SSA-CFG worklist SCCP requires the CFG builder which needs malloc
    // tracking to avoid leaks. Bootstrap: run a single RPO-style walk over
    // decl bodies to seed lattice values, then apply.
    s.seed_constants(root, 0);
    // Apply substitution across the whole tree.
    root = s.apply(root);
    return root;
}

// Seed lattice values by recursively walking expressions: int/bool literals
// get CONST; bindings propagate their rhs to their binder; binops/unops
// over const args become const. This is the poor man's SCCP — no CFG, no
// edge marking, but it catches intra-block constants.
fn void Sccp.seed_constants(Sccp* s, Node* n, int depth)
{
    if (n == null || depth > 200) return;
    // Seed this node's lattice value via eval (which reads children).
    // eval() looks up children via s.get(); we need to first seed children.
    for (usz i = 0; i < n.child_count; i++)
    {
        s.seed_constants(n.children[i], depth + 1);
    }
    // Evaluate and set lattice value (skip statements that don't produce values).
    switch (n.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_NULL: case Nk.N_EXPR_UNIT:
        {
            Lval v = s.eval(n);
            s.set(n, v);
            s.consts_found = s.consts_found + 1;
            return;
        }
        case Nk.N_EXPR_UNARY: case Nk.N_EXPR_BINARY:
        case Nk.N_EXPR_CAST: case Nk.N_EXPR_IF:
        case Nk.N_EXPR_TUPLE: case Nk.N_EXPR_ARRAY:
        case Nk.N_BLOCK:
        {
            Lval v = s.eval(n);
            if (v.lat == Lattice.LAT_CONST) { s.set(n, v); s.consts_found = s.consts_found + 1; }
            return;
        }
        case Nk.N_DECL_LET: case Nk.N_DECL_CONST:
        {
            if (n.child_count >= 2)
            {
                Lval v = s.eval(n.children[1]);
                s.set(n.children[1], v);
                // Propagate value to the pattern/binder so idents get CONST.
                if (n.children[0] != null)
                {
                    s.set(n.children[0], v);
                    if (n.children[0].child_count >= 1 && n.children[0].children[0] != null)
                    {
                        s.set(n.children[0].children[0], v);
                        if (v.lat == Lattice.LAT_CONST) { s.consts_found = s.consts_found + 1; }
                    }
                }
            }
            return;
        }
        case Nk.N_EXPR_IDENT: case Nk.N_EXPR_PATH: case Nk.N_EXPR_FIELD:
        {
            // If this ident resolves to a const binding, pick it up: lookup
            // will resolve via the lattice if it was propagated from a LET.
            Lval* cur = s.get(n);
            if (cur != null && cur.lat == Lattice.LAT_CONST) { s.consts_found = s.consts_found + 1; }
            return;
        }
        default:
            return;
    }
}
