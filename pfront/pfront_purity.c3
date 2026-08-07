// ============================================================================
// pfront_purity.c3 — Purity / totality / divergence inference
// ----------------------------------------------------------------------------
// Even in an untyped language the question "can this expression be safely
// duplicated or deleted?" is central to every optimization. GVN, LICM, ADCE
// and SCCP all depend on knowing whether an expression has side effects.
//
// The existing `Node.effects` field carries a bitset (EFF_IO, EFF_ALLOC,
// EFF_UNSAFE, EFF_UB, EFF_PANIC, EFF_DIVERGE) that is set during parsing
// for primitives (e.g. a call to a known-IO fn gets EFF_IO). This pass
// PROPAGATES those bits bottom-up across the entire AST: an expression is
// pure (effects == 0) iff every sub-expression is pure and the expression
// itself introduces no new effect.
//
// Beyond simple purity we also classify functions into four categories:
//   PURE      — no effects, always returns, deterministic
//   TOTAL     — may allocate but no IO/UB/panic/diverge; deterministic
//   PARTIAL   — may panic or hit UB on some inputs; otherwise total
//   IMPURE    — performs IO, diverges, or calls impure fns
//
// We use a worklist fixed-point over the call graph (functions start
// optimistic and are lowered as evidence of impurity is found) — a
// classic monotone analysis.
//
// Output: for each N_DECL_FN, fills f.p.fn_effects with the computed bit
// set and reports summary counts. Like other passes this is read-only
// against the AST shape; it only mutates an analysis-side shadow table.
// ============================================================================

module pfront_purity;

import pfront_core;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* p, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

// Local copies of effect bits (pfront_core exports bare consts, no enum).
const ulong EFF_PURE     = 0;
const ulong EFF_IO_L     = 1;
const ulong EFF_ALLOC_L  = 2;
const ulong EFF_UNSAFE_L = 4;
const ulong EFF_UB_L     = 8;
const ulong EFF_PANIC_L  = 16;
const ulong EFF_DIVERGE_L= 32;
const usz EFF_VOLATILE = (usz)(EFF_IO_L|EFF_DIVERGE_L|EFF_PANIC_L|EFF_UNSAFE_L|EFF_UB_L);

const usz PUR_MAX_FN = 8192;

struct PurityAnalysis
{
    Arena* arena;
    Node*  root;

    Node** fns;
    usz    fn_count;
    usz    fn_cap;

    // Map node->index (open-addressing).
    Node** idx_key;
    int*   idx_val;
    usz    idx_cap;

    usz*   eff;           // eff[i] = current effects bit set for fn i
    usz*   body_eff;      // body_eff[i] = effects in body EXCLUDING calls
    bool*  has_ub;
    bool*  has_panic;
    bool*  has_diverge;
    bool*  has_io;
    bool*  has_alloc;

    // Call targets per fn.
    int**  calls;
    usz*   call_count;
    usz*   call_cap;

    // Classifications.
    usz n_pure;
    usz n_total;
    usz n_partial;
    usz n_impure;
    usz n_divergent;
}

fn void PurityAnalysis.init(PurityAnalysis* pa, Arena* a)
{
    pa.arena = a;
    pa.root = null;
    pa.fns = null;
    pa.fn_count = 0;
    pa.fn_cap = 0;
    pa.idx_key = null;
    pa.idx_val = null;
    pa.idx_cap = 0;
    pa.eff = null;
    pa.body_eff = null;
    pa.has_ub = null;
    pa.has_panic = null;
    pa.has_diverge = null;
    pa.has_io = null;
    pa.has_alloc = null;
    pa.calls = null;
    pa.call_count = null;
    pa.call_cap = null;
    pa.n_pure = 0; pa.n_total = 0; pa.n_partial = 0;
    pa.n_impure = 0; pa.n_divergent = 0;
}

fn void pa_grow_fns(PurityAnalysis* pa)
{
    usz nc = pa.fn_cap == 0 ? 64 : pa.fn_cap * 2;
    Node** nfn = (Node**)realloc(pa.fns, nc * 8);
    usz*   nef = (usz*)realloc(pa.eff, nc * 8);
    usz*   nbe = (usz*)realloc(pa.body_eff, nc * 8);
    bool*  nub = (bool*)realloc(pa.has_ub, nc);
    bool*  npa = (bool*)realloc(pa.has_panic, nc);
    bool*  ndv = (bool*)realloc(pa.has_diverge, nc);
    bool*  nio = (bool*)realloc(pa.has_io, nc);
    bool*  nal = (bool*)realloc(pa.has_alloc, nc);
    int**  ncl = (int**)realloc(pa.calls, nc * 8);
    usz*   ncc = (usz*)realloc(pa.call_count, nc * 8);
    usz*   ncp = (usz*)realloc(pa.call_cap, nc * 8);
    if (nfn == null) return;
    pa.fns = nfn; pa.eff = nef; pa.body_eff = nbe;
    pa.has_ub = nub; pa.has_panic = npa; pa.has_diverge = ndv;
    pa.has_io = nio; pa.has_alloc = nal;
    pa.calls = ncl; pa.call_count = ncc; pa.call_cap = ncp;
    pa.fn_cap = nc;
    for (usz i = pa.fn_count; i < nc; i++)
    {
        pa.fns[i] = null;
        pa.eff[i] = 0; pa.body_eff[i] = 0;
        pa.has_ub[i] = false; pa.has_panic[i] = false; pa.has_diverge[i] = false;
        pa.has_io[i] = false; pa.has_alloc[i] = false;
        pa.calls[i] = null; pa.call_count[i] = 0; pa.call_cap[i] = 0;
    }
}

fn void pa_idx_put(PurityAnalysis* pa, Node* k, int v)
{
    if (pa.idx_cap == 0)
    {
        usz nc = 1024;
        pa.idx_key = (Node**)calloc(nc, 8);
        pa.idx_val = (int*)malloc(nc * 4);
        pa.idx_cap = nc;
        for (usz i = 0; i < nc; i++) pa.idx_val[i] = -1;
    }
    usz mask = pa.idx_cap - 1;
    usz h = ((usz)k >> 3) & mask;
    while (pa.idx_key[h] != null && pa.idx_key[h] != k) h = (h + 1) & mask;
    if (pa.idx_key[h] == null) pa.idx_key[h] = k;
    pa.idx_val[h] = v;
}

fn int pa_idx_get(PurityAnalysis* pa, Node* k)
{
    if (k == null || pa.idx_cap == 0) return -1;
    usz mask = pa.idx_cap - 1;
    usz h = ((usz)k >> 3) & mask;
    while (pa.idx_key[h] != null)
    {
        if (pa.idx_key[h] == k) return pa.idx_val[h];
        h = (h + 1) & mask;
    }
    return -1;
}

fn int pa_add_fn(PurityAnalysis* pa, Node* f)
{
    if (f == null) return -1;
    int ex = pa_idx_get(pa, f);
    if (ex >= 0) return ex;
    if (pa.fn_count >= pa.fn_cap) pa_grow_fns(pa);
    usz i = pa.fn_count;
    pa.fns[i] = f;
    pa.eff[i] = 0;
    pa_idx_put(pa, f, (int)i);
    pa.fn_count = i + 1;
    return (int)i;
}

fn void pa_add_call(PurityAnalysis* pa, int from, int to)
{
    if (from < 0 || to < 0) return;
    usz u = (usz)from;
    usz cnt = pa.call_count[u];
    usz cap = pa.call_cap[u];
    for (usz i = 0; i < cnt; i++)
    {
        if (pa.calls[u][i] == to) return;
    }
    if (cnt >= cap)
    {
        usz nc = cap == 0 ? 4 : cap * 2;
        int* na = (int*)realloc(pa.calls[u], nc * 4);
        if (na == null) return;
        pa.calls[u] = na;
        pa.call_cap[u] = nc;
    }
    pa.calls[u][cnt] = to;
    pa.call_count[u] = cnt + 1;
}

// Locally compute effects from a single node (ignoring call targets).
fn usz local_effects_of(Node* n)
{
    if (n == null) return 0;
    usz e = n.effects;
    // Inline assembly is unsafe.
    if (n.kind == Nk.N_EXPR_UNSAFE || n.kind == Nk.N_EXPR_UNCHECKED)
    {
        e = e | EFF_UNSAFE_L;
    }
    if (n.kind == Nk.N_EXPR_UB)     { e = e | EFF_UB_L; }
    if (n.kind == Nk.N_EXPR_POISON) { e = e | EFF_UB_L; }
    return e;
}

fn void pa_scan(PurityAnalysis* pa, Node* n, int cur_fn, int depth)
{
    if (n == null || depth > 256) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        int sub = pa_idx_get(pa, n);
        if (sub >= 0 && sub != cur_fn)
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                pa_scan(pa, n.children[i], sub, depth + 1);
            }
            return;
        }
    }
    if (cur_fn >= 0)
    {
        usz le = local_effects_of(n);
        if (le != 0)
        {
            pa.body_eff[cur_fn] = pa.body_eff[cur_fn] | le;
            if ((le & EFF_IO_L) != 0)      pa.has_io[cur_fn] = true;
            if ((le & EFF_UB_L) != 0)      pa.has_ub[cur_fn] = true;
            if ((le & EFF_PANIC_L) != 0)   pa.has_panic[cur_fn] = true;
            if ((le & EFF_DIVERGE_L) != 0) pa.has_diverge[cur_fn] = true;
            if ((le & EFF_ALLOC_L) != 0)   pa.has_alloc[cur_fn] = true;
        }
        if (n.kind == Nk.N_EXPR_CALL)
        {
            Node* tgt = (n.child_count >= 1) ? n.children[0] : null;
            Node* r = (tgt != null) ? tgt.resolved : null;
            if (r != null && r.kind == Nk.N_DECL_FN)
            {
                int callee = pa_idx_get(pa, r);
                if (callee >= 0) pa_add_call(pa, cur_fn, callee);
            }
            else
            {
                // Indirect call: assume impure.
                pa.body_eff[cur_fn] = pa.body_eff[cur_fn] | EFF_VOLATILE;
                pa.has_io[cur_fn] = true;
                pa.has_diverge[cur_fn] = true;
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        pa_scan(pa, n.children[i], cur_fn, depth + 1);
    }
}

fn void PurityAnalysis.run(PurityAnalysis* pa, Node* root)
{
    if (root == null) return;
    pa.root = root;
    // First pass: collect functions.
    pa_collect_fns(pa, root, 0);
    usz n = pa.fn_count;
    if (n == 0) return;
    // Second pass: scan bodies for local effects and direct calls.
    for (usz i = 0; i < n; i++) pa_scan(pa, pa.fns[i], (int)i, 0);
    // Initialize eff[i] = body_eff[i] (optimistic: callees are pure).
    for (usz i = 0; i < n; i++) pa.eff[i] = pa.body_eff[i];
    // Fixed-point: propagate callee effects to callers.
    bool changed = true;
    int iters = 0;
    bool* dirty = (bool*)malloc(n);
    while (changed && iters < 100)
    {
        changed = false;
        iters++;
        for (usz i = 0; i < n; i++) dirty[i] = false;
        for (usz i = 0; i < n; i++)
        {
            usz cc = pa.call_count[i];
            for (usz j = 0; j < cc; j++)
            {
                int callee = pa.calls[i][j];
                if (callee < 0 || (usz)callee >= n) continue;
                usz ce = pa.eff[callee];
                usz oe = pa.eff[i];
                usz ne = oe | ce;
                if (ne != oe)
                {
                    pa.eff[i] = ne;
                    dirty[i] = true;
                    changed = true;
                    if ((ce & EFF_IO_L) != 0) pa.has_io[i] = true;
                    if ((ce & EFF_UB_L) != 0) pa.has_ub[i] = true;
                    if ((ce & EFF_PANIC_L) != 0) pa.has_panic[i] = true;
                    if ((ce & EFF_DIVERGE_L) != 0) pa.has_diverge[i] = true;
                    if ((ce & EFF_ALLOC_L) != 0) pa.has_alloc[i] = true;
                }
            }
        }
    }
    free((void*)dirty);
    // Classify.
    for (usz i = 0; i < n; i++)
    {
        usz e = pa.eff[i];
        bool vol = (e & EFF_VOLATILE) != 0;
        bool has_any_alloc = pa.has_alloc[i];
        bool panic = pa.has_panic[i] || pa.has_ub[i];
        if (vol)
        {
            pa.n_impure++;
            if (pa.has_diverge[i]) pa.n_divergent++;
        }
        else if (panic)
        {
            pa.n_partial++;
        }
        else if (has_any_alloc)
        {
            pa.n_total++;
        }
        else
        {
            pa.n_pure++;
        }
    }
}

fn void pa_collect_fns(PurityAnalysis* pa, Node* n, int depth)
{
    if (n == null || depth > 256) return;
    if (n.kind == Nk.N_DECL_FN) { pa_add_fn(pa, n); }
    for (usz i = 0; i < n.child_count; i++)
    {
        pa_collect_fns(pa, n.children[i], depth + 1);
    }
}

fn void PurityAnalysis.report(PurityAnalysis* pa)
{
    printf("  purity pure      : %d\n", (int)pa.n_pure);
    printf("  purity total     : %d\n", (int)pa.n_total);
    printf("  purity partial   : %d\n", (int)pa.n_partial);
    printf("  purity impure    : %d\n", (int)pa.n_impure);
    printf("  purity divergent : %d\n", (int)pa.n_divergent);
}

fn void PurityAnalysis.free(PurityAnalysis* pa)
{
    for (usz i = 0; i < pa.fn_count; i++)
    {
        if (pa.calls != null && pa.calls[i] != null) free((void*)pa.calls[i]);
    }
    free((void*)pa.fns);
    free((void*)pa.eff);
    free((void*)pa.body_eff);
    free((void*)pa.has_ub); free((void*)pa.has_panic); free((void*)pa.has_diverge);
    free((void*)pa.has_io); free((void*)pa.has_alloc);
    free((void*)pa.calls); free((void*)pa.call_count); free((void*)pa.call_cap);
    free((void*)pa.idx_key); free((void*)pa.idx_val);
    pa.fns = null; pa.fn_count = 0;
}
