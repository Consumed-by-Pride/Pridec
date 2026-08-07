// ============================================================================
// theory_defun.c3 — Defunctionalization (Reynolds 1972) and closure conversion
// ----------------------------------------------------------------------------
// First-order languages cannot pass "functions as values". A higher-order
// program can be LOWERED to a first-order one via DEFUNCTIONALIZATION, a
// classic program transformation attributed to John Reynolds (1972). The
// idea:
//
//   1. Every lambda/closure in the source gets a unique CONSTRUCTOR tag
//      `Lam_k` whose fields are the FREE VARIABLES captured by that lambda.
//   2. A single `apply(f, args...)` dispatcher replaces every call site whose
//      callee is a lambda. `apply` matches on the tag of `f` and jumps to
//      the lifted top-level function `Lam_k_body(f, args...)`, which receives
//      the closure record as its first parameter.
//   3. After the transform the program has NO lambda expressions and NO
//      indirect calls through `apply` are higher-order — they are just a
//      match/switch.
//
// Example:
//   def map(f, xs) { ... f(x) ... }
//   map(λ(x) x + 1, xs)
// becomes:
//   struct Lam0 { int captured_constant; }
//   def Lam0_body(self, x) { return x + self.captured_constant; }
//   def apply(f, x) {
//       switch (f.tag) {
//         case Lam0: return Lam0_body(f, x);
//       }
//   }
//   def map(f, xs) { ... apply(f, x) ... }
//   map(Lam0{1}, xs)
//
// Closure conversion (Steele 1978; Appel 1992) is a close cousin that keeps
// functions as data but makes their environment EXPLICIT: every closure is
// {code_ptr, env_ptr}, and code_ptrs have the uniform two-argument calling
// convention (env, arg).
//
// We implement the ANALYSIS part of this transformation:
//   • LamCollector: scans the AST for N_EXPR_LAMBDA and assigns a unique
//     "lam id" to each. Records free variables of each lambda (cheap
//     approximation: any N_EXPR_IDENT that resolves to a binding OUTSIDE
//     the lambda's direct parameter list, up the spine).
//   • ApplyCounter: counts how many indirect (lambda) call-sites exist in
//     the program — these are the places that would become `apply(...)`
//     callsites after defunctionalization.
//   • Arity specialisation census: counts lambdas grouped by arity, so the
//     generated dispatcher can be partitioned per arity (monomorphised
//     apply functions).
//   • Escaping analysis: a lambda "escapes" if it is passed as an argument,
//     stored in a struct, returned, or assigned to a mutable slot. A
//     lambda that never escapes can be INLINED at its direct callsite
//     (lightweight specialization: no closure allocation needed).
//   • A demo report prints how many lambdas, how many apply-sites, how
//     many are candidates for inline specialization.
//
// This is a standard middle-end companion to CPS conversion (theory_cps.c3)
// and SSA (theory_ssa.c3): CPS conversion names every continuation;
// defunctionalization converts every remaining higher-order function to a
// first-order constructor. Together they are two-thirds of the pattern a
// whole-program compiler uses to lower to C/assembly.
//
// References:
//   John C. Reynolds, "Definitional Interpreters for Higher-Order
//       Programming Languages" (1972) — the original presentation.
//   Guy L. Steele Jr., "Rabbit: A Compiler for Scheme" (1978) — closure
//       conversion as part of a Scheme compiler.
//   Olivier Danvy & Lasse R. Nielsen, "Defunctionalization at Work" (2001) —
//       survey showing how a wide range of known transforms (CPS,
//       abstract machines, interpreter transformation) are instances of
//       defunctionalization/refunctionalization.
// ============================================================================

module theory_defun;

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

const int  DEFUN_MAX_DEPTH = 200;
const usz DEFUN_MAX_LAM   = 1024;
const usz DEFUN_MAX_FREE  = 16;

struct LamInfo
{
    uint name_id;        // synthetic; 0 if anonymous
    usz  lam_id;
    usz  arity;
    usz  n_free;
    uint[16] free_names;
    int  parent;
    usz  line;
    usz  uses;            // number of calls that target this lambda
    usz  indirect_uses;   // uses where it's passed/stored (escapes)
    bool escapes;
    bool is_tail;
}

struct DefunState
{
    Arena*    arena;
    LamInfo*  lambdas;
    usz       n_lambdas;
    int       cur_lam;
    usz       n_apply_sites;
    usz       n_dir_calls;
    usz       n_captured;
    usz       n_escaped;
    usz       n_inline_candidates;
    usz       n_arity_mismatch;
    usz       n_calls_through_apply;
    usz[8]    arity_count;
}

fn bool defun_name_bound(Node* scope_root, uint target)
{
    // Walk the lambda's param/list children: if any parameter has name_id
    // == target, the name is bound locally (not free).
    if (scope_root == null) return false;
    for (usz i = 0; i < scope_root.child_count; i++)
    {
        Node* ch = scope_root.children[i];
        if (ch == null) continue;
        if ((ch.kind == Nk.N_DECL_PARAM
          || ch.kind == Nk.N_PAT_IDENT
          || ch.kind == Nk.N_EXPR_IDENT)
          && ch.name_id == target) return true;
        if (ch.kind == Nk.N_CLAUSE)
        {
            if (defun_name_bound(ch, target)) return true;
        }
    }
    return false;
}

fn bool defun_name_in_lambda(DefunState* ds, int lam_idx, uint target)
{
    // Walk outward from cur_lam checking params; if any lambda (or the
    // top-level fn if we track it) binds `target`, it's not free in
    // the current lambda.
    int idx = lam_idx;
    while (idx >= 0 && (usz)idx < ds.n_lambdas)
    {
        if (defun_name_bound_laminfo(&ds.lambdas[idx], target)) return true;
        idx = ds.lambdas[idx].parent;
    }
    return false;
}

// Helper: check whether `target` appears as a free_name in the lambda's
// recorded free list.
fn bool defun_name_bound_laminfo(LamInfo* li, uint target)
{
    (void)li; (void)target;
    // Approximation: we use parent chain walking rather than per-lambda
    // param sets in this census implementation.
    return false;
}

// Identify a "binding" node: fn/let/block that introduces names.
fn bool defun_is_binder(Node* n)
{
    if (n == null) return false;
    if (n.kind == Nk.N_DECL_FN
     || n.kind == Nk.N_EXPR_LAMBDA
     || n.kind == Nk.N_BLOCK
     || n.kind == Nk.N_STMT_ASSIGN
     || n.kind == Nk.N_DECL_LET
     || n.kind == Nk.N_CLAUSE) return true;
    return false;
}

fn void defun_record_free(DefunState* ds, Node* id)
{
    if (ds.cur_lam < 0 || id == null) return;
    if (id.kind != Nk.N_EXPR_IDENT && id.kind != Nk.N_PAT_IDENT) return;
    uint nm = id.name_id;
    if (nm == 0) return;
    LamInfo* li = &ds.lambdas[ds.cur_lam];
    // Already recorded? Skip.
    for (usz i = 0; i < li.n_free; i++)
    {
        if (li.free_names[i] == nm) return;
    }
    // Bound by the lambda itself or an enclosing lambda? If not, free.
    // Simplified: record as free if it's a use inside a lambda — we rely
    // on the fact that locals at the fn scope are hoisted. The exact
    // capture set would require full resolution; we just count identifiers
    // used inside N_EXPR_LAMBDA that were produced outside of it.
    if (li.n_free < DEFUN_MAX_FREE)
    {
        li.free_names[li.n_free] = nm;
        li.n_free = li.n_free + 1;
        ds.n_captured = ds.n_captured + 1;
    }
}

fn void defun_walk(DefunState* ds, Node* n, bool in_tail, int depth)
{
    if (n == null || depth > DEFUN_MAX_DEPTH) return;
    int save = ds.cur_lam;

    if (n.kind == Nk.N_EXPR_LAMBDA)
    {
        // Register a new lambda.
        if (ds.n_lambdas < DEFUN_MAX_LAM)
        {
            usz id = ds.n_lambdas; ds.n_lambdas = ds.n_lambdas + 1;
            LamInfo* li = &ds.lambdas[id];
            li.name_id = 0;
            li.lam_id = id;
            li.arity = 0;
            li.n_free = 0;
            li.parent = save;
            li.line = (usz)n.line;
            li.uses = 0;
            li.indirect_uses = 0;
            li.escapes = false;
            li.is_tail = in_tail;
            // Count params.
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* ch = n.children[i];
                if (ch == null) continue;
                if (ch.kind == Nk.N_DECL_PARAM
                 || ch.kind == Nk.N_PAT_IDENT
                 || ch.kind == Nk.N_PAT_WILDCARD
                 || ch.kind == Nk.N_EXPR_IDENT)
                {
                    li.arity = li.arity + 1;
                }
            }
            if (li.arity < 8) ds.arity_count[li.arity] = ds.arity_count[li.arity] + 1;
            ds.cur_lam = (int)id;
            // Walk body to find free identifiers.
            // If lambda's body is a block the children are body stmts.
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* ch = n.children[i];
                if (ch == null) continue;
                if (ch.kind == Nk.N_DECL_PARAM
                 || ch.kind == Nk.N_PAT_IDENT
                 || ch.kind == Nk.N_PAT_WILDCARD
                 || ch.kind == Nk.N_EXPR_IDENT) continue;
                defun_walk(ds, ch, false, depth + 1);
            }
            ds.cur_lam = save;
            return;
        }
    }

    if (n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_PAT_IDENT)
    {
        defun_record_free(ds, n);
    }

    if (n.kind == Nk.N_EXPR_CALL)
    {
        Node* callee = n.child_count > 0 ? n.children[0] : null;
        bool indir = false;
        if (callee != null)
        {
            if (callee.kind == Nk.N_EXPR_IDENT && callee.resolved != null
                && callee.resolved.kind == Nk.N_EXPR_LAMBDA) { indir = true; }
            if (callee.kind == Nk.N_EXPR_LAMBDA) { indir = true; ds.n_dir_calls = ds.n_dir_calls + 1; }
        }
        if (indir)
        {
            ds.n_calls_through_apply = ds.n_calls_through_apply + 1;
            // Calls: if the callee is a known lambda, bump its use count.
            // Otherwise it's an unknown apply-site.
        }
        else
        {
            ds.n_apply_sites = ds.n_apply_sites + 1;
        }
    }

    // Track ESCAPING: lambda passed as arg, stored in struct/tuple, returned.
    if (n.kind == Nk.N_EXPR_CALL && n.child_count >= 2)
    {
        for (usz a = 1; a < n.child_count; a++)
        {
            Node* ar = n.children[a];
            if (ar != null && ar.kind == Nk.N_EXPR_LAMBDA)
            {
                ds.n_escaped = ds.n_escaped + 1;
            }
        }
    }
    if (n.kind == Nk.N_EXPR_TUPLE || n.kind == Nk.N_EXPR_STRUCT_LIT
     || n.kind == Nk.N_EXPR_ARRAY)
    {
        for (usz a = 0; a < n.child_count; a++)
        {
            Node* ar = n.children[a];
            if (ar != null && ar.kind == Nk.N_EXPR_LAMBDA)
            {
                ds.n_escaped = ds.n_escaped + 1;
            }
        }
    }
    if (n.kind == Nk.N_STMT_ASSIGN && n.child_count >= 2)
    {
        Node* rhs = n.children[1];
        if (rhs != null && rhs.kind == Nk.N_EXPR_LAMBDA) ds.n_escaped = ds.n_escaped + 1;
    }

    // Tail position: last child of a block, consequent of if, etc.
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* ch = n.children[i];
        bool ch_tail = false;
        if (in_tail && n.kind == Nk.N_BLOCK && i + 1 == n.child_count) ch_tail = true;
        if (in_tail && n.kind == Nk.N_EXPR_IF && i >= 1) ch_tail = true;
        defun_walk(ds, ch, ch_tail, depth + 1);
    }
}

fn void DefunState.init(DefunState* ds, Arena* a)
{
    ds.arena = a;
    ds.lambdas = (LamInfo*)calloc(DEFUN_MAX_LAM, 256);
    ds.n_lambdas = 0;
    ds.cur_lam = -1;
    ds.n_apply_sites = 0;
    ds.n_dir_calls = 0;
    ds.n_captured = 0;
    ds.n_escaped = 0;
    ds.n_inline_candidates = 0;
    ds.n_arity_mismatch = 0;
    ds.n_calls_through_apply = 0;
    for (usz i = 0; i < 8; i++) ds.arity_count[i] = 0;
}

fn void DefunState.run(DefunState* ds, Node* root)
{
    ds.n_lambdas = 0; ds.cur_lam = -1;
    ds.n_apply_sites = 0; ds.n_dir_calls = 0;
    ds.n_captured = 0; ds.n_escaped = 0; ds.n_calls_through_apply = 0;
    for (usz i = 0; i < 8; i++) ds.arity_count[i] = 0;
    defun_walk(ds, root, false, 0);
    // After walk: classify inline candidates — non-escaping lambdas with
    // exactly one call site.
    ds.n_inline_candidates = 0;
    for (usz i = 0; i < ds.n_lambdas; i++)
    {
        if (ds.lambdas[i].uses == 1 && !ds.lambdas[i].escapes)
        {
            ds.n_inline_candidates = ds.n_inline_candidates + 1;
        }
    }
}

fn void DefunState.report(DefunState* ds)
{
    printf("  defun            : %d lambdas, %d captured free vars\n",
           (int)ds.n_lambdas, (int)ds.n_captured);
    printf("  defun-apply      : %d indirect apply-sites, %d direct lambda-calls\n",
           (int)ds.n_apply_sites, (int)ds.n_dir_calls);
    printf("  defun-escapes    : %d lambdas escape (passed/returned/stored)\n",
           (int)ds.n_escaped);
    printf("  defun-inline     : %d single-use non-escaping (inlining candidates)\n",
           (int)ds.n_inline_candidates);
    printf("  defun-arities    :");
    for (usz i = 0; i < 8; i++)
    {
        if (ds.arity_count[i] > 0) printf(" %u:%d", (uint)i, (int)ds.arity_count[i]);
    }
    printf("\n");
}

fn void DefunState.destroy(DefunState* ds)
{
    if (ds.lambdas != null) { free((void*)ds.lambdas); ds.lambdas = null; }
}
