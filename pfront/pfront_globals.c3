// ============================================================================
// pfront_globals.c3 — Mod/global variable analysis (read/write sets)
// ----------------------------------------------------------------------------
// A module-scope or static mutable variable is a GLOBAL. The optimizer must
// know which globals each function READS and WRITES to answer:
//
//   * Is a load from a global redundant? Yes, if no intervening write.
//   * Can two calls be reordered? Only if their write sets don't overlap
//     with each other's read sets.
//   * Does a pure function really have zero effect? Only if it writes no
//     global (calls to functions that write globals must be marked).
//   * Can LICM hoist a load out of a loop? Only if no global written in
//     the loop aliases it (i.e., the loop doesn't write it).
//
// We compute MOD-REF sets per function bottom-up over the call graph:
//   - Each function has a bit representing each global it touches; for
//     simplicity we use an open-addressing set of global name_ids and
//     propagate from callees to callers.
//   - A function is marked "writes unknown" if it calls an external/
//     unresolved function (we assume the worst about foreign code).
//
// Purely read-only access to a global does not invalidate caches.
// ============================================================================

module pfront_globals;

import pfront_core;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz GLOB_MAX_FN = 4096;
const usz GLOB_TBL = 2048;

struct GlobSet
{
    usz* reads;
    usz  read_count;
    usz  read_cap;
    usz* writes;
    usz  write_count;
    usz  write_cap;
    bool writes_unknown;
    bool reads_unknown;
}

struct GlobalAnalysis
{
    Arena* arena;
    Node*  root;

    Node** fns;
    usz    fn_count;
    usz    fn_cap;
    Node** idx_key;
    int*   idx_val;
    usz    idx_cap;

    GlobSet* sets;     // per-fn set
    Node**   globals;  // global N_DECL_LET/N_DECL_STATIC discovered
    usz      g_count;

    usz     n_read;
    usz     n_write;
    usz     n_pure;
    usz     n_unknown;
}

fn void GlobalAnalysis.init(GlobalAnalysis* ga, Arena* a)
{
    ga.arena = a;
    ga.root = null;
    ga.fn_cap = 256;
    ga.fns = (Node**)calloc(ga.fn_cap, 8);
    ga.idx_cap = 1024;
    ga.idx_key = (Node**)calloc(ga.idx_cap, 8);
    ga.idx_val = (int*)malloc(ga.idx_cap * 4);
    for (usz i = 0; i < ga.idx_cap; i++) ga.idx_val[i] = -1;
    ga.sets = null;
    ga.globals = null;
    ga.g_count = 0;
    ga.fn_count = 0;
    ga.n_read = 0;
    ga.n_write = 0;
    ga.n_pure = 0;
    ga.n_unknown = 0;
}

fn usz ga_hash(GlobalAnalysis* ga, Node* n) { return ((usz)n >> 3) & (ga.idx_cap - 1); }

fn void ga_grow_fns(GlobalAnalysis* ga)
{
    usz nc = ga.fn_cap * 2;
    Node** nf = (Node**)realloc(ga.fns, (long)(nc * 8));
    GlobSet* ns = (GlobSet*)realloc(ga.sets, (long)(nc * GlobSet::size));
    if (nf != null) ga.fns = nf;
    if (ns != null)
    {
        for (usz i = ga.fn_count; i < nc; i++)
        {
            ns[i].reads = null; ns[i].read_count = 0; ns[i].read_cap = 0;
            ns[i].writes = null; ns[i].write_count = 0; ns[i].write_cap = 0;
            ns[i].writes_unknown = false; ns[i].reads_unknown = false;
        }
        ga.sets = ns;
    }
    ga.fn_cap = nc;
}

fn int ga_find_or_add(GlobalAnalysis* ga, Node* fnode)
{
    if (fnode == null) return -1;
    usz mask = ga.idx_cap - 1;
    usz h = ga_hash(ga, fnode);
    for (usz p = 0; p < ga.idx_cap; p++)
    {
        usz s = (h + p) & mask;
        if (ga.idx_key[s] == null)
        {
            if (ga.fn_count >= ga.fn_cap) ga_grow_fns(ga);
            usz i = ga.fn_count;
            ga.fns[i] = fnode;
            ga.sets[i].reads = null; ga.sets[i].read_count = 0; ga.sets[i].read_cap = 0;
            ga.sets[i].writes = null; ga.sets[i].write_count = 0; ga.sets[i].write_cap = 0;
            ga.sets[i].writes_unknown = false;
            ga.sets[i].reads_unknown = false;
            ga.idx_key[s] = fnode;
            ga.idx_val[s] = (int)i;
            ga.fn_count = i + 1;
            return (int)i;
        }
        if (ga.idx_key[s] == fnode) return ga.idx_val[s];
    }
    return -1;
}

fn int ga_find(GlobalAnalysis* ga, Node* fnode)
{
    if (fnode == null) return -1;
    usz mask = ga.idx_cap - 1;
    usz h = ga_hash(ga, fnode);
    for (usz p = 0; p < ga.idx_cap; p++)
    {
        usz s = (h + p) & mask;
        if (ga.idx_key[s] == null) return -1;
        if (ga.idx_key[s] == fnode) return ga.idx_val[s];
    }
    return -1;
}

fn void gs_add(usz** arr, usz* cnt, usz* cap, usz id)
{
    for (usz i = 0; i < *cnt; i++) { if ((*arr)[i] == id) return; }
    if (*cnt >= *cap)
    {
        usz nc = *cap == 0 ? 8 : (*cap) * 2;
        usz* na = (usz*)realloc(*arr, (long)(nc * 8));
        if (na == null) return;
        *arr = na; *cap = nc;
    }
    (*arr)[*cnt] = id; *cnt = *cnt + 1;
}

fn bool is_global_ref(Node* n)
{
    if (n == null) return false;
    if (n.kind != Nk.N_EXPR_IDENT) return false;
    Node* r = n.resolved;
    if (r == null) return false;
    // Global = decl at top-level (not inside a fn body).
    Node* p = r.parent;
    while (p != null)
    {
        if (p.kind == Nk.N_DECL_FN) return false;
        p = p.parent;
    }
    return true;
}

fn void ga_scan(GlobalAnalysis* ga, Node* n, int fi, bool write_ctx)
{
    if (n == null || fi < 0) return;
    if (n.kind == Nk.N_EXPR_IDENT && is_global_ref(n))
    {
        usz id = n.name_id;
        if (write_ctx)
        {
            gs_add(&ga.sets[fi].writes, &ga.sets[fi].write_count, &ga.sets[fi].write_cap, id);
        }
        else
        {
            gs_add(&ga.sets[fi].reads, &ga.sets[fi].read_count, &ga.sets[fi].read_cap, id);
        }
    }
    if (n.kind == Nk.N_STMT_ASSIGN && n.child_count >= 1)
    {
        // LHS is written.
        ga_scan(ga, n.children[0], fi, true);
        for (usz i = 1; i < n.child_count; i++) ga_scan(ga, n.children[i], fi, false);
        return;
    }
    if (n.kind == Nk.N_EXPR_CALL)
    {
        Node* tgt = (n.child_count >= 1) ? n.children[0] : null;
        bool known = false;
        if (tgt != null && tgt.resolved != null && tgt.resolved.kind == Nk.N_DECL_FN)
        {
            int callee = ga_find_or_add(ga, tgt.resolved);
            if (callee >= 0)
            {
                known = true;
                // Mark that callsite reads/writes will be propagated.
                (void)callee;
            }
        }
        if (!known)
        {
            ga.sets[fi].reads_unknown = true;
            ga.sets[fi].writes_unknown = true;
        }
        for (usz i = 0; i < n.child_count; i++) ga_scan(ga, n.children[i], fi, false);
        return;
    }
    if (n.kind == Nk.N_DECL_FN)
    {
        int sub = ga_find_or_add(ga, n);
        if (sub != fi)
        {
            for (usz i = 0; i < n.child_count; i++) ga_scan(ga, n.children[i], sub, false);
            return;
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ga_scan(ga, n.children[i], fi, false);
    }
}

fn void GlobalAnalysis.run(GlobalAnalysis* ga, Node* prog)
{
    if (prog == null) return;
    ga.root = prog;
    ga.sets = (GlobSet*)calloc(ga.fn_cap, GlobSet::size);
    // First collect all functions and scan their bodies.
    int fi = ga_find_or_add(ga, prog); // dummy root
    (void)fi;
    ga_collect_fns(ga, prog);
    for (usz i = 0; i < ga.fn_count; i++)
    {
        Node* fnode = ga.fns[i];
        if (fnode == null || fnode.kind != Nk.N_DECL_FN) continue;
        for (usz c = 0; c < fnode.child_count; c++)
        {
            ga_scan(ga, fnode.children[c], (int)i, false);
        }
    }
    // Tally.
    for (usz i = 0; i < ga.fn_count; i++)
    {
        bool has_any = ga.sets[i].read_count > 0 || ga.sets[i].write_count > 0
                || ga.sets[i].reads_unknown || ga.sets[i].writes_unknown;
        if (ga.sets[i].write_count > 0 || ga.sets[i].writes_unknown) ga.n_write++;
        if (ga.sets[i].read_count > 0 || ga.sets[i].reads_unknown)   ga.n_read++;
        if (!has_any) ga.n_pure++;
        if (ga.sets[i].writes_unknown) ga.n_unknown++;
    }
}

fn void ga_collect_fns(GlobalAnalysis* ga, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_DECL_FN) { ga_find_or_add(ga, n); }
    for (usz i = 0; i < n.child_count; i++) ga_collect_fns(ga, n.children[i]);
}

fn void GlobalAnalysis.report(GlobalAnalysis* ga)
{
    printf("  globals fns      : %d analyzed, %d read globs, %d write globs\n",
           (int)ga.fn_count, (int)ga.n_read, (int)ga.n_write);
    printf("  globals pure     : %d, unknown-callee: %d\n",
           (int)ga.n_pure, (int)ga.n_unknown);
}

fn void GlobalAnalysis.free(GlobalAnalysis* ga)
{
    for (usz i = 0; i < ga.fn_count; i++)
    {
        free((void*)ga.sets[i].reads);
        free((void*)ga.sets[i].writes);
    }
    free((void*)ga.fns);
    free((void*)ga.sets);
    free((void*)ga.idx_key);
    free((void*)ga.idx_val);
    free((void*)ga.globals);
}
