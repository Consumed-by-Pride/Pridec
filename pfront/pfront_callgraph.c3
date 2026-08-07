// ============================================================================
// pfront_callgraph.c3 — Static call graph + SCC-based recursion analysis
// ----------------------------------------------------------------------------
// The call graph maps each function to the set of functions it directly
// calls (by N_DECL_FN node identity, after resolution). With that we can
// compute Strongly Connected Components (Tarjan's algorithm) to find:
//
//   - Directly recursive functions (self-loops).
//   - Mutually recursive groups (size-2+ SCCs with cycles).
//   - Leaf functions (no outgoing calls) – candidates for inlining/callsite
//     specialization, and trivially pure/non-effectful depending on body.
//   - Functions that never return (callees that are known-divergent).
//
// The call graph is built from the AST by walking every N_EXPR_CALL and
// recording its `resolved` target if that target is an N_DECL_FN in the
// current arena. Indirect calls (target is an arbitrary expression) are
// marked but contribute no static edges.
//
// Outputs are purely diagnostic / advisory — like the rest of our passes
// this is read-only against the AST and does no mutation.
// ============================================================================

module pfront_callgraph;

import pfront_core;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz CG_MAX = 16384;

struct CallGraph
{
    Arena* arena;
    Node*  root;

    // Collected functions (all N_DECL_FN reachable from root).
    Node** fns;
    usz    fn_count;
    usz    fn_cap;

    // Map from Node* (identity) to index in fns[]; uses open-addressing.
    Node** idx_key;
    int*   idx_val;
    usz    idx_cap;

    // Edges: outgoing from fn[i] -> fn[j]. Stored as dynamic per-node lists.
    int**  edges;
    usz*   edge_count;
    usz*   edge_cap;

    // Indirect-call flags (function's address leaks / is called through fn ptr).
    bool*  indir;

    // Tarjan SCC state.
    int*   index;
    int*   low;
    bool*  onstack;
    int*   stk;
    usz    sp;
    int    idx;

    // SCC outputs.
    int*   scc_id;         // scc_id[i] = scc number of fn i
    usz*   scc_size;       // size of each scc
    usz    scc_count;
    usz    scc_cap;

    bool*  self_rec;       // has a self-edge
    bool*  is_leaf;        // no outgoing edges to known fns
    usz    n_dir_rec;
    usz    n_mut_rec;
    usz    n_leaf;
    usz    n_indir;
}

fn void CallGraph.init(CallGraph* cg, Arena* a)
{
    cg.arena = a;
    cg.root = null;
    cg.fns = null;
    cg.fn_count = 0;
    cg.fn_cap = 0;
    cg.idx_key = null;
    cg.idx_val = null;
    cg.idx_cap = 0;
    cg.edges = null;
    cg.edge_count = null;
    cg.edge_cap = null;
    cg.indir = null;
    cg.index = null;
    cg.low = null;
    cg.onstack = null;
    cg.stk = null;
    cg.sp = 0;
    cg.idx = 0;
    cg.scc_id = null;
    cg.scc_size = null;
    cg.scc_count = 0;
    cg.scc_cap = 0;
    cg.self_rec = null;
    cg.is_leaf = null;
    cg.n_dir_rec = 0;
    cg.n_mut_rec = 0;
    cg.n_leaf = 0;
    cg.n_indir = 0;
}

fn void cg_grow_fns(CallGraph* cg)
{
    usz nc = cg.fn_cap == 0 ? 64 : cg.fn_cap * 2;
    Node** na = (Node**)realloc(cg.fns, nc * 8);
    int**  ea = (int**)realloc(cg.edges, nc * 8);
    usz*   eca = (usz*)realloc(cg.edge_count, nc * 8);
    usz*   ecap = (usz*)realloc(cg.edge_cap, nc * 8);
    bool*  inda = (bool*)realloc(cg.indir, nc);
    if (na == null) return;
    cg.fns = na; cg.fn_cap = nc;
    cg.edges = ea; cg.edge_count = eca; cg.edge_cap = ecap;
    cg.indir = inda;
    for (usz i = cg.fn_count; i < nc; i++)
    {
        cg.fns[i] = null;
        cg.edges[i] = null;
        cg.edge_count[i] = 0;
        cg.edge_cap[i] = 0;
        cg.indir[i] = false;
    }
}

fn void cg_index_put(CallGraph* cg, Node* k, int v)
{
    if (cg.idx_cap == 0)
    {
        usz nc = 1024;
        cg.idx_key = (Node**)calloc(nc, 8);
        cg.idx_val = (int*)malloc(nc * 4);
        cg.idx_cap = nc;
        for (usz i = 0; i < nc; i++) { cg.idx_val[i] = -1; }
    }
    usz mask = cg.idx_cap - 1;
    usz h = ((usz)k >> 3) & mask;
    while (cg.idx_key[h] != null && cg.idx_key[h] != k)
    {
        h = (h + 1) & mask;
    }
    if (cg.idx_key[h] == null) { cg.idx_key[h] = k; }
    cg.idx_val[h] = v;
}

fn int cg_index_get(CallGraph* cg, Node* k)
{
    if (k == null || cg.idx_cap == 0) return -1;
    usz mask = cg.idx_cap - 1;
    usz h = ((usz)k >> 3) & mask;
    while (cg.idx_key[h] != null)
    {
        if (cg.idx_key[h] == k) return cg.idx_val[h];
        h = (h + 1) & mask;
    }
    return -1;
}

fn int cg_add_fn(CallGraph* cg, Node* f)
{
    if (f == null) return -1;
    int ex = cg_index_get(cg, f);
    if (ex >= 0) return ex;
    if (cg.fn_count >= cg.fn_cap) cg_grow_fns(cg);
    usz i = cg.fn_count;
    cg.fns[i] = f;
    cg_index_put(cg, f, (int)i);
    cg.fn_count = i + 1;
    return (int)i;
}

fn void cg_add_edge(CallGraph* cg, int from, int to)
{
    if (from < 0 || to < 0) return;
    usz u = (usz)from;
    usz cnt = cg.edge_count[u];
    usz cap = cg.edge_cap[u];
    // dedupe
    for (usz i = 0; i < cnt; i++)
    {
        if (cg.edges[u][i] == to) return;
    }
    if (cnt >= cap)
    {
        usz nc = cap == 0 ? 4 : cap * 2;
        int* na = (int*)realloc(cg.edges[u], nc * 4);
        if (na == null) return;
        cg.edges[u] = na;
        cg.edge_cap[u] = nc;
    }
    cg.edges[u][cnt] = to;
    cg.edge_count[u] = cnt + 1;
}

// Walker: find all N_DECL_FN first, then scan bodies for calls.
fn void cg_walk_decls(CallGraph* cg, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        cg_add_fn(cg, n);
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        cg_walk_decls(cg, n.children[i]);
    }
}

fn void cg_scan_calls(CallGraph* cg, Node* n, int cur_fn)
{
    if (n == null) return;
    if (n.kind == Nk.N_EXPR_CALL)
    {
        Node* tgt = null;
        if (n.child_count >= 1) tgt = n.children[0];
        if (tgt != null)
        {
            Node* r = tgt.resolved;
            if (r == null && tgt.kind == Nk.N_EXPR_IDENT) r = tgt.resolved;
            if (r != null && r.kind == Nk.N_DECL_FN)
            {
                int callee = cg_index_get(cg, r);
                if (callee >= 0) { cg_add_edge(cg, cur_fn, callee); }
            }
            else
            {
                // Indirect / unknown.
                if (cur_fn >= 0) { cg.indir[cur_fn] = true; }
            }
        }
    }
    // Nested fn decls: do NOT descend into them from this fn (they start
    // their own call graph entries).
    if (n.kind == Nk.N_DECL_FN)
    {
        int sub = cg_index_get(cg, n);
        if (sub >= 0 && sub != cur_fn)
        {
            // Recurse into the nested fn as its own cur_fn.
            for (usz i = 0; i < n.child_count; i++)
            {
                cg_scan_calls(cg, n.children[i], sub);
            }
            return;
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        cg_scan_calls(cg, n.children[i], cur_fn);
    }
}

fn void cg_tarjan(CallGraph* cg, int v)
{
    cg.index[v] = cg.idx;
    cg.low[v] = cg.idx;
    cg.idx++;
    cg.stk[cg.sp++] = v;
    cg.onstack[v] = true;
    usz deg = cg.edge_count[v];
    for (usz i = 0; i < deg; i++)
    {
        int w = cg.edges[v][i];
        if (w < 0 || (usz)w >= cg.fn_count) continue;
        if (cg.index[w] == -1)
        {
            cg_tarjan(cg, w);
            if (cg.low[w] < cg.low[v]) cg.low[v] = cg.low[w];
        }
        else if (cg.onstack[w])
        {
            if (cg.index[w] < cg.low[v]) cg.low[v] = cg.index[w];
        }
    }
    if (cg.low[v] == cg.index[v])
    {
        usz sci = cg.scc_count;
        if (sci >= cg.scc_cap)
        {
            usz nc = cg.scc_cap == 0 ? 64 : cg.scc_cap * 2;
            cg.scc_size = (usz*)realloc(cg.scc_size, nc * 8);
            cg.scc_cap = nc;
        }
        usz scount = 0;
        while (cg.sp > 0)
        {
            int w = cg.stk[--cg.sp];
            cg.onstack[w] = false;
            cg.scc_id[w] = (int)sci;
            scount++;
            if (w == v) break;
        }
        cg.scc_size[sci] = scount;
        cg.scc_count = sci + 1;
    }
}

fn void CallGraph.build(CallGraph* cg, Node* prog)
{
    if (prog == null) return;
    cg.root = prog;
    cg_walk_decls(cg, prog);
    usz n = cg.fn_count;
    if (n == 0) return;
    // Allocate Tarjan state.
    cg.index = (int*)malloc(n * 4);
    cg.low = (int*)malloc(n * 4);
    cg.onstack = (bool*)calloc(n, 1);
    cg.stk = (int*)malloc(n * 4);
    cg.scc_id = (int*)malloc(n * 4);
    cg.self_rec = (bool*)calloc(n, 1);
    cg.is_leaf = (bool*)calloc(n, 1);
    for (usz i = 0; i < n; i++)
    {
        cg.index[i] = -1;
        cg.low[i] = 0;
        cg.scc_id[i] = -1;
    }
    cg.sp = 0; cg.idx = 0; cg.scc_count = 0; cg.scc_cap = 0;
    cg.scc_size = null;

    // Scan each fn body.
    for (usz i = 0; i < n; i++)
    {
        cg_scan_calls(cg, cg.fns[i], (int)i);
    }
    // Run Tarjan.
    for (usz i = 0; i < n; i++)
    {
        if (cg.index[i] == -1) cg_tarjan(cg, (int)i);
    }
    // Analyze.
    for (usz i = 0; i < n; i++)
    {
        usz deg = cg.edge_count[i];
        // Self-edge?
        for (usz j = 0; j < deg; j++)
        {
            if (cg.edges[i][j] == (int)i) { cg.self_rec[i] = true; break; }
        }
        if (cg.self_rec[i]) cg.n_dir_rec++;
        if (deg == 0) { cg.is_leaf[i] = true; cg.n_leaf++; }
        if (cg.indir[i]) cg.n_indir++;
    }
    for (usz s = 0; s < cg.scc_count; s++)
    {
        if (cg.scc_size[s] > 1) cg.n_mut_rec = cg.n_mut_rec + cg.scc_size[s];
    }
}

fn void CallGraph.report(CallGraph* cg)
{
    printf("  callgraph fns    : %d\n", (int)cg.fn_count);
    printf("  callgraph leaves : %d\n", (int)cg.n_leaf);
    printf("  callgraph dirrec : %d\n", (int)cg.n_dir_rec);
    printf("  callgraph mutrec : %d (in sccs size>=2)\n", (int)cg.n_mut_rec);
    printf("  callgraph indir  : %d\n", (int)cg.n_indir);
    printf("  callgraph sccs   : %d\n", (int)cg.scc_count);
}

fn void CallGraph.free(CallGraph* cg)
{
    for (usz i = 0; i < cg.fn_count; i++)
    {
        if (cg.edges != null && cg.edges[i] != null) free((void*)cg.edges[i]);
    }
    free((void*)cg.fns);
    free((void*)cg.edges);
    free((void*)cg.edge_count);
    free((void*)cg.edge_cap);
    free((void*)cg.indir);
    free((void*)cg.index);
    free((void*)cg.low);
    free((void*)cg.onstack);
    free((void*)cg.stk);
    free((void*)cg.scc_id);
    free((void*)cg.scc_size);
    free((void*)cg.self_rec);
    free((void*)cg.is_leaf);
    free((void*)cg.idx_key);
    free((void*)cg.idx_val);
    cg.fns = null; cg.fn_count = 0;
}
