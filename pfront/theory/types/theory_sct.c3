// ============================================================================
// theory_sct.c3 — Size-Change Termination (Lee/Jones/Ben-Amram 2001)
// ----------------------------------------------------------------------------
// The size-change principle is a classic termination analysis. A program
// terminates iff for every infinite call-chain f → … → f, some parameter
// decreases infinitely in a well-founded order. Captured by SIZE-CHANGE
// GRAPHS (SCGs) labelling call sites with "-->"/"--≥" edges between source
// and destination parameters, then closing under composition and checking
// every idempotent SCG has a strict self-edge.
// ============================================================================

module theory_sct;

import pfront_lex;
import pfront_core;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz SCT_MAX_PARAMS   = 4;
const usz SCT_MAX_FNS      = 256;
const usz SCT_MAX_SCG      = 1024;
const int  SCT_MAX_DEPTH   = 200;

enum Ek : int
{
    EK_NONE,
    EK_GEQ,
    EK_GT
}

struct ScGraph
{
    uint bits;
    int  src_fi;
    int  dst_fi;
    bool is_call;
}

fn uint scg_bitpos(usz i, usz j)
{
    return (uint)((i * SCT_MAX_PARAMS + j) * 2);
}

fn Ek scg_get(ScGraph* g, usz i, usz j)
{
    uint sh = scg_bitpos(i, j);
    return (Ek)((g.bits >> sh) & 3u);
}

fn void scg_set(ScGraph* g, usz i, usz j, Ek k)
{
    uint sh = scg_bitpos(i, j);
    uint mask = ~(3u << sh);
    g.bits = (g.bits & mask) | ((uint)k << sh);
}

fn ScGraph scg_compose(ScGraph* g, ScGraph* h)
{
    ScGraph r;
    r.bits = 0;
    r.src_fi = g.src_fi;
    r.dst_fi = h.dst_fi;
    r.is_call = false;
    for (usz x = 0; x < SCT_MAX_PARAMS; x++)
    {
        for (usz z = 0; z < SCT_MAX_PARAMS; z++)
        {
            Ek best = Ek.EK_NONE;
            for (usz y = 0; y < SCT_MAX_PARAMS; y++)
            {
                Ek e1 = scg_get(g, x, y);
                Ek e2 = scg_get(h, y, z);
                if (e1 == Ek.EK_NONE || e2 == Ek.EK_NONE) { continue; }
                Ek joined = Ek.EK_GEQ;
                if (e1 == Ek.EK_GT || e2 == Ek.EK_GT) { joined = Ek.EK_GT; }
                if ((int)joined > (int)best) { best = joined; }
            }
            if (best != Ek.EK_NONE) { scg_set(&r, x, z, best); }
        }
    }
    return r;
}

fn bool scg_idempotent(ScGraph* g)
{
    if (g.src_fi != g.dst_fi) return false;
    ScGraph g2 = scg_compose(g, g);
    return g2.bits == g.bits;
}

fn bool scg_has_strict_self(ScGraph* g)
{
    for (usz p = 0; p < SCT_MAX_PARAMS; p++)
    {
        if (scg_get(g, p, p) == Ek.EK_GT) return true;
    }
    return false;
}

struct FnInfo
{
    uint name_id;
    usz  paramc;
    bool is_rec;
}

struct SctState
{
    Arena*    arena;
    FnInfo*   fns;
    usz       n_fns;
    ScGraph*  scgs;
    usz       n_scgs;
    usz       n_callsites;
    usz       n_recursive;
    usz       n_terminating;
    usz       n_nonterm;
    usz       n_unknown;
    usz       n_self_edges;
    int       cur_fi;
}

fn int sct_find_fn(SctState* s, uint name)
{
    for (usz i = 0; i < s.n_fns; i++)
    {
        if (s.fns[i].name_id == name) return (int)i;
    }
    if (s.n_fns >= SCT_MAX_FNS) return -1;
    int fi = (int)s.n_fns; s.n_fns = s.n_fns + 1;
    s.fns[fi].name_id = name;
    s.fns[fi].paramc = 0;
    s.fns[fi].is_rec = false;
    return fi;
}

fn bool sct_add_scg(SctState* s, ScGraph g)
{
    for (usz i = 0; i < s.n_scgs; i++)
    {
        if (s.scgs[i].src_fi == g.src_fi
         && s.scgs[i].dst_fi == g.dst_fi
         && s.scgs[i].bits == g.bits) return false;
    }
    if (s.n_scgs >= SCT_MAX_SCG) return false;
    s.scgs[s.n_scgs] = g;
    s.n_scgs = s.n_scgs + 1;
    return true;
}

fn usz sct_param_count(Node* fnode)
{
    if (fnode == null) return 0;
    usz c = 0;
    for (usz i = 0; i < fnode.child_count && c < SCT_MAX_PARAMS; i++)
    {
        Node* ch = fnode.children[i];
        if (ch == null) continue;
        if (ch.kind == Nk.N_DECL_PARAM
         || ch.kind == Nk.N_PAT_IDENT
         || ch.kind == Nk.N_PAT_WILDCARD
         || ch.kind == Nk.N_EXPR_IDENT)
        {
            c = c + 1;
        }
    }
    return c;
}

fn void sct_extract_call(SctState* s, Node* call, int callee_fi)
{
    if (call == null || callee_fi < 0 || s.cur_fi < 0) return;
    usz src_params = s.fns[(usz)s.cur_fi].paramc;
    if (src_params == 0) return;
    ScGraph g;
    g.bits = 0;
    g.src_fi = s.cur_fi;
    g.dst_fi = callee_fi;
    g.is_call = true;
    bool found_any = false;
    for (usz i = 0; i + 1 < call.child_count && i < SCT_MAX_PARAMS; i++)
    {
        Node* arg = call.children[i + 1];
        if (arg == null) continue;
        if (arg.kind == Nk.N_EXPR_IDENT)
        {
            if (i < src_params)
            {
                scg_set(&g, i, i, Ek.EK_GEQ);
                found_any = true;
            }
        }
        else if (arg.kind == Nk.N_EXPR_BINARY
              && arg.p.op == (long)Tk.TOKEN_MINUS
              && arg.child_count >= 2
              && arg.children[0] != null
              && arg.children[0].kind == Nk.N_EXPR_IDENT
              && arg.children[1] != null
              && arg.children[1].kind == Nk.N_EXPR_INT
              && arg.children[1].p.ival >= 1)
        {
            if (i < src_params)
            {
                scg_set(&g, i, i, Ek.EK_GT);
                s.n_self_edges = s.n_self_edges + 1;
                found_any = true;
            }
        }
    }
    if (found_any)
    {
        sct_add_scg(s, g);
        s.n_callsites = s.n_callsites + 1;
        if (s.cur_fi == callee_fi)
        {
            s.fns[(usz)s.cur_fi].is_rec = true;
            s.n_recursive = s.n_recursive + 1;
        }
    }
}

fn uint sct_node_name(Node* n)
{
    if (n == null) return 0;
    if (n.kind == Nk.N_EXPR_IDENT) return n.name_id;
    if (n.kind == Nk.N_DECL_FN) return n.name_id;
    return 0;
}

fn void sct_walk(SctState* s, Node* n, int depth)
{
    if (n == null || depth > SCT_MAX_DEPTH) return;
    int save = s.cur_fi;
    if (n.kind == Nk.N_DECL_FN || n.kind == Nk.N_EXPR_LAMBDA)
    {
        uint nm = sct_node_name(n);
        int fi = sct_find_fn(s, nm);
        if (fi >= 0)
        {
            s.fns[(usz)fi].paramc = sct_param_count(n);
            s.cur_fi = fi;
        }
    }
    if (n.kind == Nk.N_EXPR_CALL && n.child_count >= 1 && n.children[0] != null)
    {
        uint callee_name = sct_node_name(n.children[0]);
        if (callee_name != 0)
        {
            int callee_fi = sct_find_fn(s, callee_name);
            if (callee_fi >= 0) sct_extract_call(s, n, callee_fi);
        }
    }
    for (usz i = 0; i < n.child_count; i++) sct_walk(s, n.children[i], depth + 1);
    s.cur_fi = save;
}

fn void sct_closure(SctState* s)
{
    usz budget = 0;
    while (budget < 64)
    {
        usz before = s.n_scgs;
        for (usz i = 0; i < s.n_scgs; i++)
        {
            for (usz j = 0; j < s.n_scgs; j++)
            {
                if (s.scgs[i].dst_fi != s.scgs[j].src_fi) continue;
                ScGraph c = scg_compose(&s.scgs[i], &s.scgs[j]);
                if (c.bits == 0) continue;
                sct_add_scg(s, c);
            }
        }
        if (s.n_scgs == before) break;
        budget = budget + 1;
    }
}

fn void sct_classify(SctState* s)
{
    char[256] has_nonterm;
    char[256] has_sct;
    char[256] has_cycle;
    for (usz i = 0; i < s.n_fns; i++)
    {
        has_nonterm[i] = 0;
        has_sct[i] = 0;
        has_cycle[i] = 0;
    }
    for (usz i = 0; i < s.n_scgs; i++)
    {
        if (s.scgs[i].src_fi != s.scgs[i].dst_fi) continue;
        int fi = s.scgs[i].src_fi;
        if (fi < 0 || (usz)fi >= s.n_fns) continue;
        has_cycle[fi] = 1;
        if (scg_idempotent(&s.scgs[i]))
        {
            if (scg_has_strict_self(&s.scgs[i])) { has_sct[fi] = 1; }
            else { has_nonterm[fi] = 1; }
        }
    }
    for (usz i = 0; i < s.n_fns; i++)
    {
        if (!s.fns[i].is_rec && has_cycle[i] == 0) continue;
        if (has_nonterm[i] != 0) { s.n_nonterm = s.n_nonterm + 1; }
        else if (has_sct[i] != 0) { s.n_terminating = s.n_terminating + 1; }
        else { s.n_unknown = s.n_unknown + 1; }
    }
}

fn void SctState.init(SctState* s, Arena* a)
{
    s.arena = a;
    s.fns = (FnInfo*)calloc(SCT_MAX_FNS, 40);
    s.scgs = (ScGraph*)calloc(SCT_MAX_SCG, 20);
    s.n_fns = 0; s.n_scgs = 0;
    s.n_callsites = 0; s.n_recursive = 0;
    s.n_terminating = 0; s.n_nonterm = 0; s.n_unknown = 0;
    s.n_self_edges = 0;
    s.cur_fi = -1;
}

fn void SctState.run(SctState* s, Node* root)
{
    s.n_fns = 0; s.n_scgs = 0; s.cur_fi = -1;
    sct_walk(s, root, 0);
    sct_closure(s);
    sct_classify(s);
}

fn void SctState.report(SctState* s)
{
    printf("  size-change      : %d fns, %d call SCGs, %d closure SCGs\n",
           (int)s.n_fns, (int)s.n_callsites, (int)s.n_scgs);
    printf("  sct-terminating  : %d recursive fns proved terminating\n",
           (int)s.n_terminating);
    printf("  sct-nonterm      : %d fns have idempotent SCG without strict descent\n",
           (int)s.n_nonterm);
    printf("  sct-unknown      : %d fns (recursive but no idempotent SCG)\n",
           (int)s.n_unknown);
}

fn void SctState.destroy(SctState* s)
{
    if (s.fns != null) { free((void*)s.fns); s.fns = null; }
    if (s.scgs != null) { free((void*)s.scgs); s.scgs = null; }
}
