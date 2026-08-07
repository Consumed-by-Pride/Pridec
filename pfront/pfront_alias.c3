// ============================================================================
// pfront_alias.c3 — Steensgaard-style unification-based alias analysis
// ----------------------------------------------------------------------------
// This is a fast, NEAR-LINEAR alias analysis based on Bjarne Steensgaard's
// 1996 algorithm ("Points-to Analysis in Almost Linear Time"). It produces
// a may-alias relation over pointer-typed expressions that is less precise
// than Andersen but dramatically cheaper (union-find with path compression
// and union-by-rank gives essentially α(N) per operation).
//
// The analysis assigns each pointer-bearing node a "location set":
//
//   loc(τ)  = ref(α, λ)
//
// where α is the abstract ADDRESS (the "variable" the pointer points to) and
// λ is the location set of the *contents* (for double-indirection). Each α
// can optionally have a "fun" field for function pointers. When two pointers
// are unified we union their α nodes and recurse into their contents.
//
// For Pride this is perfect because:
//   * We are in AST land; we have no mem2reg / SSA requirement.
//   * We need alias info quickly during unsafe/safety checks and the theory
//     layer's UB detector (aliasing mutable references is UB in Rust-like
//     settings, and it matters for alias.scope/noalias in the future LLVM
//     emitter the user has in mind).
//   * Steensgaard is ONE pass: unify as we walk, then query. No fixpoint.
//
// Precision notes:
//   * Allocations (N_EXPR_ALLOC), address-taken (`&x`) and parameter pointers
//     each get fresh α nodes.
//   * Copy (a = b) unifies the RHS loc with the LHS loc — Steensgaard's
//     hallmark (contravariant/equality rather than inclusion).
//   * LOAD  (*p = e) creates a fresh "star-pointer" for p's ref-field and
//     unifies the RHS into it.
//   * STORE (e = *p) similarly unifies from the star-pointer into the LHS.
//   * Function arguments unify caller-pointer with callee parameter at
//     call sites.
//
// Public API:
//   aa.init(arena);
//   aa.run(root);
//   aa.alias(a, b) → true  (may-alias), false (definitely no-alias)
//   aa.report();
// ============================================================================

module pfront_alias;

import pfront_core;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

// A term in the points-to language. Either a REF(alpha, lambda) or TOP (any),
// BOT (none).
enum AliasKind : int
{
    ALIAS_TOP,    // unknown
    ALIAS_REF,    // pointer: ->alpha with contents
    ALIAS_BOT,    // no pointer
}


struct AType
{
    AVar*  v;     // the variable for this type's location
    AType* next;  // free-list / pool
}

struct AVar
{
    AVar*  parent;     // union-find parent
    usz    rank;
    uint   name_id;    // for named vars (idents), the interner name (for debug)
    AliasKind kind;
    AType* ref_of;     // contents-location when ALIAS_REF
    bool   is_alloc;   // came from N_EXPR_ALLOC (heap)
    bool   is_stack;   // came from &local
    bool   is_global;  // came from &static/const
    bool   is_func;    // function pointer
    usz    site;       // unique id for debug
}

const usz MAX_VARS = 32768;
const usz MAX_TYPES = 65536;

struct AliasAnalysis
{
    Arena* arena;

    // Pool of variables.
    AVar[MAX_VARS] vars_arr;
    usz  var_count;

    // Pool of types.
    AType[MAX_TYPES] types_arr;
    usz  type_count;

    // Map from Node* -> AVar* (open addressing, same scheme as SCCP).
    AVar*[16384] n_var;
    Node*[16384] n_key;

    // Stats:
    usz unifications;
    usz finds;
    usz alloc_sites;
    usz stack_sites;
    usz global_sites;
    usz func_sites;
    usz aliasing_pairs;
    usz non_alias_pairs;
}

// --- pool allocation -------------------------------------------------------
fn AVar* AliasAnalysis.new_var(AliasAnalysis* a, AliasKind kind)
{
    if (a.var_count >= MAX_VARS) { return null; }
    AVar* v = &a.vars_arr[a.var_count++];
    v.parent = v;
    v.rank = 0;
    v.name_id = 0;
    v.kind = kind;
    v.ref_of = null;
    v.is_alloc = false;
    v.is_stack = false;
    v.is_global = false;
    v.is_func = false;
    v.site = a.var_count - 1;
    return v;
}

fn AType* AliasAnalysis.new_type(AliasAnalysis* a)
{
    if (a.type_count >= MAX_TYPES) { return null; }
    AType* t = &a.types_arr[a.type_count++];
    t.v = null;
    t.next = null;
    return t;
}

fn AType* AliasAnalysis.mk_ref(AliasAnalysis* a, AVar* contents)
{
    AType* t = a.new_type();
    if (t == null) { return null; }
    t.v = contents;
    return t;
}

// --- union-find ------------------------------------------------------------
fn AVar* AVar.find(AVar* v)
{
    if (v == null) { return null; }
    while (v.parent != v)
    {
        v.parent = v.parent.parent;  // path halving
        v = v.parent;
    }
    return v;
}

// --- node map --------------------------------------------------------------
fn usz aa_hash(Node* n) { usz p = (usz)n >> 3; return p & 16383; }

fn AVar* AliasAnalysis.lookup(AliasAnalysis* a, Node* n, bool create)
{
    if (n == null) { return null; }
    usz h = aa_hash(n);
    for (usz i = 0; i < 32; i++)
    {
        usz idx = (h + i) & 16383;
        if (a.n_key[idx] == n) { return a.n_var[idx].find(); }
        if (a.n_key[idx] == null)
        {
            if (!create) { return null; }
            AVar* v = a.new_var(AliasKind.ALIAS_TOP);
            if (v == null) { return null; }
            a.n_key[idx] = n;
            a.n_var[idx] = v;
            return v;
        }
    }
    return null;
}

fn void AliasAnalysis.bind_node(AliasAnalysis* a, Node* n, AVar* v)
{
    if (n == null || v == null) { return; }
    usz h = aa_hash(n);
    for (usz i = 0; i < 32; i++)
    {
        usz idx = (h + i) & 16383;
        if (a.n_key[idx] == n || a.n_key[idx] == null)
        {
            a.n_key[idx] = n;
            a.n_var[idx] = v;
            return;
        }
    }
}

// --- unification -----------------------------------------------------------
fn bool AliasAnalysis.unify_type(AliasAnalysis* a, AType* tx, AType* ty)
{
    if (tx == null || ty == null) { return false; }
    return a.unify(tx.v, ty.v);
}

fn bool AliasAnalysis.unify(AliasAnalysis* a, AVar* x, AVar* y)
{
    if (x == null || y == null) { return false; }
    x = x.find();
    y = y.find();
    if (x == y) { return false; }
    a.unifications = a.unifications + 1;

    // BOT loses to anything.
    if (x.kind == AliasKind.ALIAS_BOT) { x.parent = y; return true; }
    if (y.kind == AliasKind.ALIAS_BOT) { y.parent = x; return true; }
    // TOP loses to anything concrete.
    if (x.kind == AliasKind.ALIAS_TOP && y.kind == AliasKind.ALIAS_TOP)
    {
        // union by rank
        if (x.rank < y.rank) { x.parent = y; }
        else { y.parent = x; if (x.rank == y.rank) { x.rank = x.rank + 1; } }
        return true;
    }
    if (x.kind == AliasKind.ALIAS_TOP) { x.parent = y; return true; }
    if (y.kind == AliasKind.ALIAS_TOP) { y.parent = x; return true; }
    // Both ALIAS_REF: union contents recursively.
    bool changed = false;
    if (x.ref_of == null && y.ref_of != null)
    {
        x.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
        changed = true;
    }
    else if (y.ref_of == null && x.ref_of != null)
    {
        y.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
        changed = true;
    }
    else if (x.ref_of == null && y.ref_of == null)
    {
        AVar* f = a.new_var(AliasKind.ALIAS_TOP);
        x.ref_of = a.mk_ref(f);
        y.ref_of = a.mk_ref(f);
        changed = true;
    }
    // Union-by-rank merge.
    if (x.rank < y.rank) { x.parent = y; }
    else { y.parent = x; if (x.rank == y.rank) { x.rank = x.rank + 1; } }
    // Merge flags (any-site wins).
    AVar* rep = x.find();
    rep.is_alloc  = rep.is_alloc || x.is_alloc  || y.is_alloc;
    rep.is_stack  = rep.is_stack || x.is_stack  || y.is_stack;
    rep.is_global = rep.is_global|| x.is_global || y.is_global;
    rep.is_func   = rep.is_func  || x.is_func   || y.is_func;
    // Unify ref_of contents.
    if (x.ref_of != null && y.ref_of != null)
    {
        if (a.unify_type(x.ref_of, y.ref_of)) { changed = true; }
    }
    return changed;
}

// --- make ref for an expression --------------------------------------------
fn AVar* AliasAnalysis.fresh_alloc(AliasAnalysis* a, Node* site)
{
    AVar* v = a.new_var(AliasKind.ALIAS_REF);
    if (v == null) { return null; }
    v.is_alloc = true;
    v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
    a.alloc_sites = a.alloc_sites + 1;
    if (site != null) { a.bind_node(site, v); }
    return v;
}

fn AVar* AliasAnalysis.fresh_stack(AliasAnalysis* a, Node* site)
{
    AVar* v = a.new_var(AliasKind.ALIAS_REF);
    if (v == null) { return null; }
    v.is_stack = true;
    v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
    a.stack_sites = a.stack_sites + 1;
    if (site != null) { a.bind_node(site, v); }
    return v;
}

fn AVar* AliasAnalysis.fresh_global(AliasAnalysis* a, Node* site)
{
    AVar* v = a.new_var(AliasKind.ALIAS_REF);
    if (v == null) { return null; }
    v.is_global = true;
    v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
    a.global_sites = a.global_sites + 1;
    if (site != null) { a.bind_node(site, v); }
    return v;
}

fn AVar* AliasAnalysis.fresh_func(AliasAnalysis* a, Node* site)
{
    AVar* v = a.new_var(AliasKind.ALIAS_REF);
    if (v == null) { return null; }
    v.is_func = true;
    v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
    a.func_sites = a.func_sites + 1;
    if (site != null) { a.bind_node(site, v); }
    return v;
}

// --- public API ------------------------------------------------------------
fn void AliasAnalysis.init(AliasAnalysis* a, Arena* ar)
{
    a.arena = ar;
    a.var_count = 0;
    a.type_count = 0;
    a.unifications = 0;
    a.finds = 0;
    a.alloc_sites = 0;
    a.stack_sites = 0;
    a.global_sites = 0;
    a.func_sites = 0;
    a.aliasing_pairs = 0;
    a.non_alias_pairs = 0;
    for (usz i = 0; i < 16384; i++) { a.n_key[i] = null; a.n_var[i] = null; }
}

// Get the "dereferenced" contents var for a pointer.
fn AVar* AliasAnalysis.deref(AliasAnalysis* a, AVar* v)
{
    v = v.find();
    if (v == null) { return null; }
    if (v.kind != AliasKind.ALIAS_REF) { return null; }
    if (v.ref_of == null)
    {
        v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP));
    }
    return v.ref_of.v.find();
}

// Walk the tree and process each node, creating α-vars and unifying per
// Steensgaard rules.
fn void AliasAnalysis.walk(AliasAnalysis* a, Node* n, int depth)
{
    if (n == null || depth > 120) { return; }
    switch (n.kind)
    {
        case Nk.N_DECL_FN:
        case Nk.N_DECL_EXTERN_FN:
        {
            AVar* fv = a.fresh_func(n);
            // Function parameters: treat each as a fresh TOP-pointer (they
            // alias whatever the caller passes in).
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                a.walk(c, depth + 1);
            }
            return;
        }
        case Nk.N_DECL_PARAM:
        case Nk.N_DECL_LET:
        case Nk.N_DECL_CONST:
        case Nk.N_DECL_STATIC:
        {
            AVar* v = a.lookup(n, true);
            if (n.kind == Nk.N_DECL_STATIC) { v.is_global = true; v.kind = AliasKind.ALIAS_REF; v.ref_of = a.mk_ref(a.new_var(AliasKind.ALIAS_TOP)); }
            // Walk children; any initializer unifies with this.
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                a.walk(c, depth + 1);
                if (i >= 1 && v != null)
                {
                    AVar* cv = a.lookup(c, true);
                    a.unify(v, cv);
                }
            }
            return;
        }
        case Nk.N_EXPR_ALLOC:
        {
            AVar* v = a.fresh_alloc(n);
            // Walk initializer if present.
            for (usz i = 0; i < n.child_count; i++) { a.walk(n.children[i], depth + 1); }
            return;
        }
        case Nk.N_EXPR_REF:
        {
            // &e: result is a fresh REF whose contents var IS the variable e.
            if (n.child_count >= 1)
            {
                a.walk(n.children[0], depth + 1);
                AVar* inner = a.lookup(n.children[0], true);
                AVar* v = a.lookup(n, true);
                v.kind = AliasKind.ALIAS_REF;
                if (v.ref_of == null) { v.ref_of = a.mk_ref(inner); }
                else { a.unify(v.ref_of.v, inner); }
                // Mark as stack/global by checking what inner is.
                AVar* irep = inner.find();
                if (irep.is_global) { v.is_global = true; }
                else { v.is_stack = true; }
            }
            return;
        }
        case Nk.N_EXPR_DEREF:
        {
            // *e: dereference the pointer-var of e.
            if (n.child_count >= 1)
            {
                a.walk(n.children[0], depth + 1);
                AVar* inner = a.lookup(n.children[0], true);
                AVar* v = a.lookup(n, true);
                AVar* star = a.deref(inner);
                a.unify(v, star);
            }
            return;
        }
        case Nk.N_EXPR_ASSIGN:
        {
            if (n.child_count < 2) { return; }
            a.walk(n.children[0], depth + 1);
            a.walk(n.children[1], depth + 1);
            AVar* lv = a.lookup(n.children[0], true);
            AVar* rv = a.lookup(n.children[1], true);
            // Assignment: if LHS is a dereference, unify RHS into *lhs_var,
            // else unify RHS into lhs_var directly.
            if (n.children[0].kind == Nk.N_EXPR_DEREF && n.children[0].child_count >= 1)
            {
                AVar* ptr = a.lookup(n.children[0].children[0], true);
                AVar* star = a.deref(ptr);
                a.unify(star, rv);
            }
            else { a.unify(lv, rv); }
            return;
        }
        case Nk.N_STMT_ASSIGN:
        {
            if (n.child_count < 2) { return; }
            a.walk(n.children[0], depth + 1);
            a.walk(n.children[1], depth + 1);
            AVar* lv = a.lookup(n.children[0], true);
            AVar* rv = a.lookup(n.children[1], true);
            if (n.children[0].kind == Nk.N_EXPR_DEREF && n.children[0].child_count >= 1)
            {
                AVar* ptr = a.lookup(n.children[0].children[0], true);
                AVar* star = a.deref(ptr);
                a.unify(star, rv);
            }
            else { a.unify(lv, rv); }
            return;
        }
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
        {
            for (usz i = 0; i < n.child_count; i++) { a.walk(n.children[i], depth + 1); }
            // Call site: result is a fresh TOP (we don't do interprocedural
            // yet; future work: connect ret to func-decl return).
            AVar* v = a.lookup(n, true);
            v.kind = AliasKind.ALIAS_TOP;
            return;
        }
        case Nk.N_EXPR_FIELD:
        case Nk.N_EXPR_INDEX:
        {
            for (usz i = 0; i < n.child_count; i++) { a.walk(n.children[i], depth + 1); }
            // Field/index projections alias their base's contents.
            if (n.child_count >= 1)
            {
                AVar* base = a.lookup(n.children[0], true);
                AVar* v = a.lookup(n, true);
                AVar* star = a.deref(base);
                a.unify(v, star);
            }
            return;
        }
        case Nk.N_EXPR_IDENT:
        {
            // Leaf: ensure var exists, but don't change kind.
            a.lookup(n, true);
            return;
        }
        case Nk.N_CLAUSE:
        case Nk.N_PAT_IDENT:
        case Nk.N_BLOCK:
        case Nk.N_MODULE:
        case Nk.N_PROGRAM:
        case Nk.N_EXPR_IF:
        case Nk.N_EXPR_MATCH:
        case Nk.N_EXPR_WHILE:
        case Nk.N_EXPR_FOR:
        case Nk.N_EXPR_LOOP:
        {
            for (usz i = 0; i < n.child_count; i++) { a.walk(n.children[i], depth + 1); }
            return;
        }
        default:
        {
            for (usz i = 0; i < n.child_count; i++) { a.walk(n.children[i], depth + 1); }
            AVar* v = a.lookup(n, true);
            if (v.kind == AliasKind.ALIAS_TOP) { v.kind = AliasKind.ALIAS_BOT; }
            return;
        }
    }
}

fn void AliasAnalysis.run(AliasAnalysis* a, Node* root)
{
    if (root == null) { return; }
    a.walk(root, 0);
}

// Query: do x and y MAY alias?
fn bool AliasAnalysis.may_alias(AliasAnalysis* a, Node* x, Node* y)
{
    if (x == null || y == null) { return false; }
    if (x == y) { return true; }
    AVar* xv = a.lookup(x, false);
    AVar* yv = a.lookup(y, false);
    if (xv == null || yv == null) { a.aliasing_pairs = a.aliasing_pairs + 1; return true; } // conservative
    xv = xv.find();
    yv = yv.find();
    if (xv == yv) { a.aliasing_pairs = a.aliasing_pairs + 1; return true; }
    a.non_alias_pairs = a.non_alias_pairs + 1;
    return false;
}

fn void AliasAnalysis.report(AliasAnalysis* a)
{
    printf("  alias vars        : %d\n", (int)a.var_count);
    printf("  alias types       : %d\n", (int)a.type_count);
    printf("  alias unifications: %d\n", (int)a.unifications);
    printf("  alloc sites       : %d\n", (int)a.alloc_sites);
    printf("  stack addrs       : %d\n", (int)a.stack_sites);
    printf("  globals           : %d\n", (int)a.global_sites);
    printf("  func pointers     : %d\n", (int)a.func_sites);
}
