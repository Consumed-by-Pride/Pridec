// ============================================================================
// pfront_pdom.c3 — Post-dominators and control-dependence graph
// ----------------------------------------------------------------------------
// Post-dominator is the dual of dominator: a block POST-DOMINATES b if every
// path from b to the EXIT goes through a. The immediate post-dominator (ipdom)
// tree is built with a Cooper-style iterative algorithm on the REVERSE CFG.
//
// With the post-dominator tree we get:
//   1. CONTROL DEPENDENCIES: a node b is control-dependent on a iff there
//      exists an edge a -> c such that b post-dominates c but does NOT
//      strictly post-dominate a. Intuitively: "branching at a determines
//      whether b executes."
//   2. Control-dependent frontiers (analogous to dominance frontiers), which
//      is where φ-like joins live for effects/assignments in predicated code.
//   3. The set of "control-dependent" statements per branch: those that a
//      dead-branch pass can safely remove when the condition folds to a
//      constant (which ADCE alone misses when it doesn't have the cdg).
//   4. The basis for a future GSA / gated SSA / ψ-function construction.
//
// This pass uses the existing Cfg and adds (a) a virtual EXIT block, (b)
// reverse edges, (c) a post-order over the reverse CFG, (d) ipdom, (e) the
// post-dominator tree, (f) control-dependence edges. Like pfront_cfg it is
// read-only: nothing is mutated on the AST.
//
// NOTE: all per-block arrays are dynamically sized to cfg.block_count+1 to
// avoid the huge fixed PDOM_MAX inline arrays that blew up memory/compile
// time on large functions (e.g. c89c/lex.pie lexer loop).
// ============================================================================

module pfront_pdom;

import pfront_core;
import pfront_cfg;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz CD_OUT_MAX = 16; // per-block control-dependent-out edges

struct PostDom
{
    Arena* arena;
    Cfg*   cfg;
    int    exit_b;      // virtual exit block id
    usz    n;           // number of blocks (including vexit) = c.block_count + 1

    // Reverse graph (reverse-CFG predecessors = original successors).
    // Grown per-block on demand.
    int** rpreds;
    usz*  rpred_count;
    usz*  rpred_cap;

    int*  ipdom;        // size n

    // Post-dom tree children (grown dynamically per-parent).
    int** pdom_children;
    usz*  pdom_child_count;
    usz*  pdom_child_cap;

    // Control dependents: flat layout cd_out[b * CD_OUT_MAX + k].
    int*  cd_out;
    usz*  cd_count;
    usz   cd_edges;

    bool computed;
}

fn void PostDom.init(PostDom* pd, Arena* a)
{
    pd.arena = a;
    pd.cfg = null;
    pd.exit_b = -1;
    pd.n = 0;
    pd.rpreds = null;
    pd.rpred_count = null;
    pd.rpred_cap = null;
    pd.ipdom = null;
    pd.pdom_children = null;
    pd.pdom_child_count = null;
    pd.pdom_child_cap = null;
    pd.cd_out = null;
    pd.cd_count = null;
    pd.cd_edges = 0;
    pd.computed = false;
}

fn void PostDom.free(PostDom* pd)
{
    if (pd.rpreds != null)
    {
        for (usz i = 0; i < pd.n; i++)
        {
            if (pd.rpreds[i] != null) free((void*)pd.rpreds[i]);
        }
        free((void*)pd.rpreds);
    }
    if (pd.pdom_children != null)
    {
        for (usz i = 0; i < pd.n; i++)
        {
            if (pd.pdom_children[i] != null) free((void*)pd.pdom_children[i]);
        }
        free((void*)pd.pdom_children);
    }
    free((void*)pd.rpred_count);
    free((void*)pd.rpred_cap);
    free((void*)pd.ipdom);
    free((void*)pd.pdom_child_count);
    free((void*)pd.pdom_child_cap);
    free((void*)pd.cd_out);
    free((void*)pd.cd_count);
    pd.rpreds = null;
    pd.pdom_children = null;
    pd.ipdom = null;
    pd.cd_out = null;
    pd.computed = false;
}

fn void pd_add_rpred(PostDom* pd, int to, int from)
{
    if (to < 0 || from < 0) return;
    usz u = (usz)to;
    if (u >= pd.n) return;
    usz c = pd.rpred_count[u];
    usz cp = pd.rpred_cap[u];
    if (c >= cp)
    {
        usz nc = cp == 0 ? 8 : cp * 2;
        int* na = (int*)realloc(pd.rpreds[u], nc * 8);
        if (na == null) return;
        pd.rpreds[u] = na;
        pd.rpred_cap[u] = nc;
    }
    pd.rpreds[u][c] = from;
    pd.rpred_count[u] = c + 1;
}

fn void pd_add_pdom_child(PostDom* pd, int parent, int child)
{
    if (parent < 0 || child < 0) return;
    usz u = (usz)parent;
    if (u >= pd.n) return;
    usz c = pd.pdom_child_count[u];
    usz cp = pd.pdom_child_cap[u];
    if (c >= cp)
    {
        usz nc = cp == 0 ? 4 : cp * 2;
        int* na = (int*)realloc(pd.pdom_children[u], nc * 8);
        if (na == null) return;
        pd.pdom_children[u] = na;
        pd.pdom_child_cap[u] = nc;
    }
    pd.pdom_children[u][c] = child;
    pd.pdom_child_count[u] = c + 1;
}

fn int pd_intersect(PostDom* pd, int b1, int b2, int* rpo_idx)
{
    int a = b1;
    int b = b2;
    while (a != b)
    {
        while (rpo_idx[a] > rpo_idx[b])
        {
            a = pd.ipdom[a];
            if (a < 0) return pd.exit_b;
        }
        while (rpo_idx[b] > rpo_idx[a])
        {
            b = pd.ipdom[b];
            if (b < 0) return pd.exit_b;
        }
    }
    return a;
}

fn void PostDom.compute(PostDom* pd, Cfg* c)
{
    if (pd.computed) return;
    pd.cfg = c;
    if (c == null) return;

    usz nb = c.block_count;
    pd.n = nb + 1;
    int vexit = (int)nb;
    pd.exit_b = vexit;

    // Allocate per-block arrays.
    usz np = pd.n;
    pd.rpreds = (int**)calloc(np, 8);
    pd.rpred_count = (usz*)calloc(np, 8);
    pd.rpred_cap = (usz*)calloc(np, 8);
    pd.ipdom = (int*)malloc(np * 8);
    pd.pdom_children = (int**)calloc(np, 8);
    pd.pdom_child_count = (usz*)calloc(np, 8);
    pd.pdom_child_cap = (usz*)calloc(np, 8);
    pd.cd_out = (int*)malloc(np * CD_OUT_MAX * 4);
    pd.cd_count = (usz*)calloc(np, 8);
    pd.cd_edges = 0;
    if (pd.ipdom == null || pd.rpreds == null || pd.cd_out == null) return;

    // Build reverse graph. Connect every block that does not fall through
    // (return / unreach / tail / no succs) to virtual exit.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        bool must_exit = (b.succ_count == 0)
                      || (b.term == pfront_cfg::TermKind.TERM_RETURN)
                      || (b.term == pfront_cfg::TermKind.TERM_UNREACH)
                      || (b.term == pfront_cfg::TermKind.TERM_TAIL);
        if (must_exit)
        {
            pd_add_rpred(pd, vexit, (int)bi);
        }
        for (usz s = 0; s < b.succ_count; s++)
        {
            pd_add_rpred(pd, b.succs[s], (int)bi);
        }
    }

    // Iterative post-order DFS over reverse CFG from vexit.
    int* post = (int*)malloc(np * 8);
    int* rpo  = (int*)malloc(np * 8);
    int* rpo_idx = (int*)malloc(np * 4);
    char* visited = (char*)calloc(np, 1);
    char* done = (char*)calloc(np, 1);
    int* stk = (int*)malloc(np * 8);
    usz post_n = 0;
    usz sp = 0;
    stk[sp++] = vexit;
    while (sp > 0)
    {
        int u = stk[sp - 1];
        if (u < 0 || (usz)u >= np) { sp--; continue; }
        if (visited[u])
        {
            if (!done[u]) { post[post_n++] = u; done[u] = 1; }
            sp--;
            continue;
        }
        visited[u] = 1;
        usz rc = pd.rpred_count[u];
        // Push children in reverse for stable order.
        for (usz ii = rc; ii > 0; ii--)
        {
            int v = pd.rpreds[u][ii - 1];
            if (v >= 0 && (usz)v < np && !visited[v])
            {
                if (sp < np - 1) { stk[sp++] = v; }
            }
        }
    }
    // rpo = reverse of post.
    for (usz i = 0; i < post_n; i++)
    {
        rpo[i] = post[post_n - 1 - i];
        rpo_idx[rpo[i]] = (int)i;
    }
    // Initialise ipdom: undefined for all, vexit's ipdom is itself.
    for (usz i = 0; i < np; i++) { pd.ipdom[i] = -1; rpo_idx[i] = rpo_idx[i]; }
    pd.ipdom[vexit] = vexit;

    bool changed = true;
    int iters = 0;
    while (changed && iters < 200)
    {
        changed = false;
        iters++;
        // Process nodes in reverse post-order except exit (start at i=1).
        for (usz i = 1; i < post_n; i++)
        {
            int bb = rpo[i];
            if (bb == vexit) continue;
            usz rc = pd.rpred_count[bb];
            int new_idom = -1;
            for (usz j = 0; j < rc; j++)
            {
                int p = pd.rpreds[bb][j];
                if (p < 0 || (usz)p >= np) continue;
                if (pd.ipdom[p] == -1) continue;
                if (new_idom == -1) { new_idom = p; }
                else { new_idom = pd_intersect(pd, new_idom, p, rpo_idx); }
            }
            if (new_idom == -1) new_idom = vexit;
            if (pd.ipdom[bb] != new_idom)
            {
                pd.ipdom[bb] = new_idom;
                changed = true;
            }
        }
    }
    pd.ipdom[vexit] = -1;
    free((void*)visited);
    free((void*)done);
    free((void*)stk);

    // Build pdom children lists.
    for (usz i = 0; i < nb; i++)
    {
        int idm = pd.ipdom[(int)i];
        if (idm >= 0 && idm != (int)i && (usz)idm < np)
        {
            pd_add_pdom_child(pd, idm, (int)i);
        }
    }

    // Control dependence edges (Cytron et al. 1991).
    // For each CFG edge (a, b): if b is not ipdom[a], then a is control-
    // dependent on every node on the path b -> ipdom[b] in the pdom tree.
    // We record in cd_out[x] the list of blocks whose execution depends on x.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &c.blocks[bi];
        for (usz s = 0; s < b.succ_count; s++)
        {
            int tgt = b.succs[s];
            if (tgt < 0 || (usz)tgt >= np) continue;
            int ipdom_tgt = pd.ipdom[tgt];
            if (ipdom_tgt != (int)bi)
            {
                int x = tgt;
                while (x >= 0 && x != ipdom_tgt && (usz)x < np)
                {
                    usz cc = pd.cd_count[x];
                    if (cc < CD_OUT_MAX)
                    {
                        // avoid dups
                        bool dup = false;
                        int* row = &pd.cd_out[x * (int)CD_OUT_MAX];
                        for (usz k = 0; k < cc; k++)
                        {
                            if (row[k] == (int)bi) { dup = true; break; }
                        }
                        if (!dup)
                        {
                            row[cc] = (int)bi;
                            pd.cd_count[x] = cc + 1;
                            pd.cd_edges = pd.cd_edges + 1;
                        }
                    }
                    if (pd.ipdom[x] == x) break;
                    x = pd.ipdom[x];
                }
            }
        }
    }

    free((void*)post);
    free((void*)rpo);
    free((void*)rpo_idx);
    pd.computed = true;
}

fn bool PostDom.postdominates(PostDom* pd, int a, int b)
{
    if (!pd.computed) return false;
    if (a == b) return true;
    int x = b;
    usz safeg = 0;
    while (x >= 0 && (usz)x < pd.n && safeg < pd.n + 2)
    {
        safeg++;
        if (x == a) return true;
        int nx = pd.ipdom[x];
        if (nx == x) return false;
        x = nx;
    }
    return false;
}

fn bool PostDom.strictly_postdominates(PostDom* pd, int a, int b)
{
    if (a == b) return false;
    return pd.postdominates(a, b);
}

fn void PostDom.report(PostDom* pd)
{
    printf("  pdom exit block  : %d\n", pd.exit_b);
    printf("  pdom cd edges    : %d\n", (int)pd.cd_edges);
}
