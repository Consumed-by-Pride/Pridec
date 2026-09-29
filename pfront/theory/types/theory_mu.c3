// ============================================================================
// theory_mu.c3 — Iso-recursive μ-types with contractivity + proper unfolding
// ----------------------------------------------------------------------------
// FCB §5.3 treats μ-types via the UNFOLDING equivalence  μα.t ≃ t[μα.t/α]. Two
// ingredients are needed for the subtyping algorithm to stay terminating:
//
//   (1) CONTRACTIVITY: every recursive occurrence must be guarded by a type
//       constructor (tuple, record, arrow, nominal, prim, array). A type like
//       μα.α or μα.μβ.α is NOT contractive — it would unfold to itself forever.
//
//   (2) A MEMO TABLE (the "already seen" set, sometimes written A) so that
//       when we encounter (μα.t) ≤ s while already assuming it, we answer
//       true coinductively (Park's principle). CDuce represents A as a set
//       of pairs (L, R) currently on the stack; we use a bounded hash of the
//       pair plus a depth cap.
//
// This file provides:
//
//   * μ-type construction with De Bruijn indices (ST_VAR / ST_MU),
//   * contractivity check (recursively; a μ-body is contractive iff every
//     free ST_VAR path to the variable crosses a constructor),
//   * one-step unfolding: unfold(μα.t) = t[μα.t/0] with De Bruijn shift,
//   * the subtyping algorithm over μ-types using the FCB coinductive rule
//       (μα.t ≤ s) ⇔ (t[μα.t/0] ≤ s)   (unfold left)
//       (t ≤ μβ.s) ⇔ (t ≤ s[μβ.s/0])   (unfold right)
//     guarded by the A set (memo) and a global step budget to avoid divergence
//     if a non-contractive μ slips through.
//
// Reference: Frisch/Castagna/Benzaken 2008 §5.3; Brandt/Henglein 1998
// "Coinductive axiomatization of recursive type equality and subtyping".
// ============================================================================

module theory_mu;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_setops;
import theory_subtype_full;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias TypeStore = theory_setops::TypeStore;
alias St = theory_setops::StKind;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const int MU_MAX_DEPTH  = 120;
const int MU_MAX_UNFOLD = 64;
const int MU_MAX_MEMO   = 4096;

// Memo pair (lhs, rhs) for coinductive circularity detection
struct MemoPair { int l; int r; }

struct MuState
{
    TypeStore* ts;
    Arena*     arena;

    // statistics
    usz n_mu;
    usz n_contractive;
    usz n_non_contractive;
    usz n_unfold_left;
    usz n_unfold_right;
    usz n_memo_hit;
    usz n_subtype_calls;
    usz n_shift_steps;

    // memo table (simple linear probe array)
    MemoPair* memo;
    usz       memo_count;

    // budget (per-query) so we don't loop forever
    int budget;

    // declarations
    MuDecl* mdecls;
    usz     n_decls;
    usz     n_uninhabited, n_compared, n_equal_pairs, n_subtype_pairs;
    usz     n_w4250, n_n4251;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*   file;
}

fn void MuState.attach(MuState* ms, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    ms.diags = d; ms.interner = it; ms.file = file;
}

fn void MuState.init(MuState* ms, Arena* a, TypeStore* ts)
{
    ms.arena = a; ms.ts = ts;
    ms.n_mu = 0; ms.n_contractive = 0; ms.n_non_contractive = 0;
    ms.n_unfold_left = 0; ms.n_unfold_right = 0; ms.n_memo_hit = 0;
    ms.n_subtype_calls = 0; ms.n_shift_steps = 0;
    ms.memo = (MemoPair*)calloc(MU_MAX_MEMO, 16);
    ms.memo_count = 0;
    ms.budget = MU_MAX_UNFOLD;
    ms.mdecls = (MuDecl*)calloc(MU_MAX_DECLS, MuDecl::size);
    ms.n_decls = 0; ms.n_uninhabited = 0; ms.n_compared = 0; ms.n_equal_pairs = 0; ms.n_subtype_pairs = 0;
    ms.n_w4250 = 0; ms.n_n4251 = 0; ms.diags = null; ms.interner = null; ms.file = null;
}

fn void memo_clear(MuState* ms)
{
    ms.memo_count = 0; ms.budget = MU_MAX_UNFOLD;
}

fn bool memo_seen(MuState* ms, int l, int r)
{
    for (usz i = 0; i < ms.memo_count; i++)
    {
        if (ms.memo[i].l == l && ms.memo[i].r == r) { ms.n_memo_hit = ms.n_memo_hit + 1; return true; }
    }
    if (ms.memo_count < MU_MAX_MEMO)
    {
        ms.memo[ms.memo_count].l = l;
        ms.memo[ms.memo_count].r = r;
        ms.memo_count = ms.memo_count + 1;
    }
    return false;
}

// ── Contractivity check ──────────────────────────────────────────────────
// A body is contractive iff every ST_VAR matching `bind_idx` appears under at
// least one CONSTRUCTOR (prim/nominal/tuple/arrow/array/record).
//
// In De Bruijn terms for a single μ-binder the "bound variable" is index 0
// (the innermost binder), which is what we are checking for.
fn bool contractive_walk(TypeStore* ts, int ty, int depth, bool under_ctor, int bind_idx)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return true; }
    theory_setops::StNode* n = &ts.nodes[ty];
    bool is_ctor = (n.kind == St.ST_PRIM || n.kind == St.ST_NOMINAL
                    || n.kind == St.ST_TUPLE || n.kind == St.ST_ARROW
                    || n.kind == St.ST_ARRAY || n.kind == St.ST_RECORD);
    bool now_under = under_ctor || is_ctor;
    switch (n.kind)
    {
        case St.ST_BOTTOM:
        case St.ST_TOP:    return true;
        case St.ST_VAR:
            // If this var is the bound one, we must be under a constructor.
            if (n.mu_var == bind_idx) { return now_under; }
            return true;
        case St.ST_PRIM:
        case St.ST_NOMINAL: return true;
        case St.ST_NEG:
            if (n.child_count >= 1) { return contractive_walk(ts, n.children[0], depth+1, now_under, bind_idx); }
            return true;
        case St.ST_MU:
            // Nested μ: its body binds a new variable (index 0 shifts to 1).
            // Its body is under its own binder but our question is about
            // the OUTER binder (bind_idx+1 under the nested μ).
            if (n.child_count >= 1)
            {
                return contractive_walk(ts, n.children[0], depth+1, now_under, bind_idx + 1);
            }
            return true;
        case St.ST_RECORD:
        case St.ST_OPTION:
            if (n.child_count >= 1) { return contractive_walk(ts, n.children[0], depth+1, true, bind_idx); }
            return true;
        default: break;
    }
    // UNION / INTER / TUPLE / ARROW / ARRAY: check children under current context
    // (TUPLE/ARROW/ARRAY are themselves ctors, so children are now_under).
    for (usz i = 0; i < n.child_count; i++)
    {
        bool ctor_here = is_ctor || now_under;
        // For UNION/INTER the children are NOT under a ctor (the connective
        // isn't a type former — it's a propositional connective).
        bool child_under = ctor_here;
        if (n.kind == St.ST_UNION || n.kind == St.ST_INTER || n.kind == St.ST_NEG)
        {
            child_under = now_under;
        }
        if (n.kind == St.ST_TUPLE || n.kind == St.ST_ARROW || n.kind == St.ST_ARRAY
            || n.kind == St.ST_RECORD) { child_under = true; }
        if (!contractive_walk(ts, n.children[i], depth+1, child_under, bind_idx)) { return false; }
    }
    return true;
}

fn bool MuState.check_contractive(MuState* ms, int body)
{
    bool ok = contractive_walk(ms.ts, body, 0, false, 0);
    if (ok) { ms.n_contractive = ms.n_contractive + 1; }
    else    { ms.n_non_contractive = ms.n_non_contractive + 1; }
    return ok;
}

// ── De Bruijn shifting ──────────────────────────────────────────────────
// When substituting under a binder we must shift free variables by 1.
// shift(ty, cutoff, d) adds d to every ST_VAR with index >= cutoff.
fn int shift(TypeStore* ts, int ty, int cutoff, int d, int depth)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return ty; }
    theory_setops::StNode* n = &ts.nodes[ty];
    switch (n.kind)
    {
        case St.ST_VAR:
        {
            int idx = n.mu_var;
            if (idx >= cutoff) { return ts.mk_var(idx + d); }
            return ty;
        }
        case St.ST_BOTTOM:
        case St.ST_TOP:
        case St.ST_PRIM:
        case St.ST_NOMINAL: return ty;
        case St.ST_NEG:
            if (n.child_count >= 1)
            {
                int inner = shift(ts, n.children[0], cutoff, d, depth+1);
                return ts.neg(inner);
            }
            return ty;
        case St.ST_MU:
            // body is under a new binder: variables below cutoff stay the
            // same; the bound var is cutoff+1 inside.
            if (n.child_count >= 1)
            {
                int body = shift(ts, n.children[0], cutoff + 1, d, depth+1);
                return ts.mk_mu(body);
            }
            return ty;
        default: break;
    }
    // Compound: shift children then rebuild smartly
    if (n.kind == St.ST_UNION && n.child_count >= 2)
    {
        int l = shift(ts, n.children[0], cutoff, d, depth+1);
        int r = shift(ts, n.children[1], cutoff, d, depth+1);
        return ts.my_union(l, r);
    }
    if (n.kind == St.ST_INTER && n.child_count >= 2)
    {
        int l = shift(ts, n.children[0], cutoff, d, depth+1);
        int r = shift(ts, n.children[1], cutoff, d, depth+1);
        return ts.my_inter(l, r);
    }
    if (n.kind == St.ST_TUPLE && n.child_count >= 2)
    {
        int l = shift(ts, n.children[0], cutoff, d, depth+1);
        int r = shift(ts, n.children[1], cutoff, d, depth+1);
        return ts.mk_binary(St.ST_TUPLE, l, r);
    }
    if (n.kind == St.ST_ARROW && n.child_count >= 2)
    {
        int l = shift(ts, n.children[0], cutoff, d, depth+1);
        int r = shift(ts, n.children[1], cutoff, d, depth+1);
        return ts.mk_arrow(l, r);
    }
    if (n.kind == St.ST_ARRAY && n.child_count >= 1)
    {
        int e = shift(ts, n.children[0], cutoff, d, depth+1);
        return ts.mk_array(e);
    }
    if (n.kind == St.ST_OPTION && n.child_count >= 1)
    {
        int e = shift(ts, n.children[0], cutoff, d, depth+1);
        return ts.mk_option(e);
    }
    if (n.kind == St.ST_RECORD && n.child_count >= 1)
    {
        int e = shift(ts, n.children[0], cutoff, d, depth+1);
        return ts.mk_unary(St.ST_RECORD, e);
    }
    return ty;
}

// ── Substitution: subst(ty, j, s) replaces ST_VAR(j) in ty with s, and
// decreases higher variables by 1 (closing the binder). We assume s has
// been lifted already if substituting under a binder.
fn int subst(TypeStore* ts, int ty, int j, int s, int depth)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return ty; }
    theory_setops::StNode* n = &ts.nodes[ty];
    switch (n.kind)
    {
        case St.ST_VAR:
            if (n.mu_var == j) { return s; }
            if (n.mu_var > j) { return ts.mk_var(n.mu_var - 1); }
            return ty;
        case St.ST_BOTTOM:
        case St.ST_TOP:
        case St.ST_PRIM:
        case St.ST_NOMINAL: return ty;
        case St.ST_NEG:
            if (n.child_count >= 1)
            {
                int inner = subst(ts, n.children[0], j, s, depth+1);
                return ts.neg(inner);
            }
            return ty;
        case St.ST_MU:
            if (n.child_count >= 1)
            {
                // under a binder: shift s up by 1, substitute body with j+1
                int s_shifted = shift(ts, s, 0, 1, 0);
                int body = subst(ts, n.children[0], j + 1, s_shifted, depth+1);
                return ts.mk_mu(body);
            }
            return ty;
        default: break;
    }
    if (n.kind == St.ST_UNION && n.child_count >= 2)
    {
        int l = subst(ts, n.children[0], j, s, depth+1);
        int r = subst(ts, n.children[1], j, s, depth+1);
        return ts.my_union(l, r);
    }
    if (n.kind == St.ST_INTER && n.child_count >= 2)
    {
        int l = subst(ts, n.children[0], j, s, depth+1);
        int r = subst(ts, n.children[1], j, s, depth+1);
        return ts.my_inter(l, r);
    }
    if (n.kind == St.ST_TUPLE && n.child_count >= 2)
    {
        int l = subst(ts, n.children[0], j, s, depth+1);
        int r = subst(ts, n.children[1], j, s, depth+1);
        return ts.mk_binary(St.ST_TUPLE, l, r);
    }
    if (n.kind == St.ST_ARROW && n.child_count >= 2)
    {
        int l = subst(ts, n.children[0], j, s, depth+1);
        int r = subst(ts, n.children[1], j, s, depth+1);
        return ts.mk_arrow(l, r);
    }
    if (n.kind == St.ST_ARRAY && n.child_count >= 1)
    {
        int e = subst(ts, n.children[0], j, s, depth+1);
        return ts.mk_array(e);
    }
    if (n.kind == St.ST_OPTION && n.child_count >= 1)
    {
        // `*T` / `&T` translate to an option: the recursion of every
        // pointer-linked structure lives under it, so it must be substituted
        int e = subst(ts, n.children[0], j, s, depth+1);
        return ts.mk_option(e);
    }
    if (n.kind == St.ST_RECORD && n.child_count >= 1)
    {
        int e = subst(ts, n.children[0], j, s, depth+1);
        return ts.mk_unary(St.ST_RECORD, e);
    }
    return ty;
}

// One-step unfold: μα.t → t[μα.t/0]
fn int MuState.unfold_once(MuState* ms, int mu_idx)
{
    if (mu_idx < 0) { return mu_idx; }
    theory_setops::StNode* n = &ms.ts.nodes[mu_idx];
    if (n.kind != St.ST_MU || n.child_count < 1) { return mu_idx; }
    int body = n.children[0];
    int r = subst(ms.ts, body, 0, mu_idx, 0);
    ms.n_unfold_left = ms.n_unfold_left + 1;
    return r;
}

// ── Coinductive subtyping with μ ────────────────────────────────────────
// Brandt–Henglein style: the pair (a, b) is ASSUMED while its unfolding is
// examined (the assumption is never popped inside the subtree — that is
// Park's principle), μ is unfolded on whichever side shows one, and the
// type constructors are compared structurally:
//     union on the left   : every summand ≤ b
//     union on the right  : a ≤ some summand      (sound; complete for the
//                           tagged sums this module builds)
//     tuple/tuple, option/option, array/array : componentwise
//     arrow/arrow         : contravariant domain, covariant codomain
//     nominal/nominal     : same name (variant tags, opaque nominals)
//     prim/prim           : same tag
//     var/var             : same index (only reachable under open binders)
// Anything without a μ inside on either side is handed to the FCB
// set-theoretic decision procedure (theory_subtype_full), which is exact
// for finite types.
fn bool has_mu(TypeStore* ts, int ty, int depth)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return false; }
    theory_setops::StNode* n = &ts.nodes[ty];
    // nominal atoms too: the set-theoretic layer compares them by node id,
    // not by name, so they must be handled here
    if (n.kind == St.ST_MU || n.kind == St.ST_VAR || n.kind == St.ST_NOMINAL) { return true; }
    for (usz i = 0; i < n.child_count; i++) { if (has_mu(ts, n.children[i], depth + 1)) { return true; } }
    return false;
}

fn bool mu_subtype(MuState* ms, int a, int b, int depth)
{
    ms.n_subtype_calls = ms.n_subtype_calls + 1;
    if (ms.budget <= 0) { return true; }   // fail-open: untyped Pride
    if (depth > MU_MAX_DEPTH) { return true; }
    TypeStore* ts = ms.ts;
    if (a == b) { return true; }
    if (a == ts.bot_idx || b == ts.top_idx) { return true; }
    if (a == ts.top_idx || b == ts.bot_idx) { return false; }
    theory_setops::StNode* na = &ts.nodes[a];
    theory_setops::StNode* nb = &ts.nodes[b];
    if (na.kind == St.ST_BOTTOM) { return true; }
    if (nb.kind == St.ST_TOP) { return true; }
    // Coinduction: if we are already assuming a ≤ b, answer yes.
    if (memo_seen(ms, a, b)) { return true; }
    if (na.kind == St.ST_MU)
    {
        int ua = ms.unfold_once(a);
        ms.budget = ms.budget - 1;
        return mu_subtype(ms, ua, b, depth + 1);
    }
    if (nb.kind == St.ST_MU)
    {
        int ub = ms.unfold_once(b);
        ms.n_unfold_right = ms.n_unfold_right + 1;
        ms.budget = ms.budget - 1;
        return mu_subtype(ms, a, ub, depth + 1);
    }
    if (na.kind == St.ST_UNION)
    {
        for (usz i = 0; i < na.child_count; i++) { if (na.children[i] >= 0 && !mu_subtype(ms, na.children[i], b, depth + 1)) { return false; } }
        return true;
    }
    if (nb.kind == St.ST_UNION)
    {
        for (usz i = 0; i < nb.child_count; i++) { if (nb.children[i] >= 0 && mu_subtype(ms, a, nb.children[i], depth + 1)) { return true; } }
        return false;
    }
    if (na.kind == St.ST_NOMINAL && nb.kind == St.ST_NOMINAL) { return na.name_id == nb.name_id; }
    if (na.kind == St.ST_PRIM && nb.kind == St.ST_PRIM) { return na.prim == nb.prim; }
    if (!has_mu(ts, a, 0) && !has_mu(ts, b, 0)) { return theory_subtype_full::semantic_subtype(ts, a, b); }
    if (na.kind != nb.kind) { return false; }
    switch (na.kind)
    {
        case St.ST_PRIM:    return na.prim == nb.prim;
        case St.ST_NOMINAL: return na.name_id == nb.name_id;
        case St.ST_VAR:     return na.mu_var == nb.mu_var;
        case St.ST_TUPLE:
        case St.ST_OPTION:
        case St.ST_ARRAY:
        case St.ST_INTER:
            if (na.child_count != nb.child_count) { return false; }
            for (usz i = 0; i < na.child_count; i++) { if (!mu_subtype(ms, na.children[i], nb.children[i], depth + 1)) { return false; } }
            return true;
        case St.ST_ARROW:
            if (na.child_count < 2 || nb.child_count < 2) { return false; }
            return mu_subtype(ms, nb.children[0], na.children[0], depth + 1) && mu_subtype(ms, na.children[1], nb.children[1], depth + 1);
        case St.ST_NEG:
            if (na.child_count < 1 || nb.child_count < 1) { return false; }
            return mu_subtype(ms, nb.children[0], na.children[0], depth + 1);
        default:
            return false;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// From Pride's nominal declarations to μ-types
// ───────────────────────────────────────────────────────────────────────
// Every recursive type declaration (struct / union / enum / newtype, found
// by a bounded cycle search over resolved type names) is translated to a
// closed μ-type in the TypeStore:
//
//     struct S { f1 : T1; …; fn : Tn }   ⟼  μS. (⟦T1⟧ × … × ⟦Tn⟧)
//     enum   E | V1(P…) | V2 …           ⟼  μE. (V1 × ⟦P⟧…) ∨ (V2 …) ∨ …
//     newtype N = T                       ⟼  μN. ⟦T⟧
//     *T, &T                              ⟼  ⟦T⟧ ?          (nullable: the
//                                             option gives the base case)
//     [T; n], [T]                         ⟼  [⟦T⟧]
//     (T1, …)                             ⟼  ⟦T1⟧ × …
//     fn(A…) -> R                         ⟼  ⟦A⟧… → ⟦R⟧
//     a name already on the binder stack  ⟼  the de Bruijn variable
//     a non-recursive nominal             ⟼  its translation, inlined
//     everything else                     ⟼  theory_subtype_full.translate_type
//
// Variant tags are kept as nominal atoms (the variant's name), so two enums
// are equal only when shapes AND constructor names agree.
//
// What is then decided, per recursive type
//   • contractivity of the body (an alias cycle is the only way to fail it —
//     theory_stratified rejects those; here they are counted)
//   • INHABITATION in the inductive (least fixpoint) reading: μX.B has a
//     finite value iff B[X := ∅] is non-empty. `enum S | Next(i64, S)` has
//     none: every constructor embeds another S. W4250.
//   • STRUCTURAL EQUALITY / SUBTYPING between distinct recursive nominal
//     types by the coinductive algorithm (mu_subtype both ways): two enums
//     with the same constructors and payload shapes are one type with two
//     names (N4251, --lint); a one-way inclusion is counted.
// ═══════════════════════════════════════════════════════════════════════

const usz MU_MAX_DECLS = 1024;
const int MU_MAX_STACK = 32;

struct MuDecl
{
    Node* decl;
    int   ty;          // closed μ-type index, -1 until translated
    bool  recursive;
    bool  contractive;
    bool  inhabited;
}

fn bool mu_is_type_decl(Node* d)
{
    if (d == null) { return false; }
    return d.kind == Nk.N_DECL_STRUCT || d.kind == Nk.N_DECL_UNION || d.kind == Nk.N_DECL_ENUM || d.kind == Nk.N_DECL_NEWTYPE;
}

fn Node* mu_target(Node* ty)
{
    if (ty == null) { return null; }
    Node* r = null;
    if (ty.kind == Nk.N_TY_NAME || ty.kind == Nk.N_TY_PATH) { r = ty.resolved; }
    else if (ty.kind == Nk.N_TY_GENERIC)
    {
        Node* head = ty.child_count > 0 ? ty.children[0] : null;
        r = head != null && head.resolved != null ? head.resolved : ty.resolved;
    }
    // aliases are transparent
    int guard = 0;
    while (r != null && r.kind == Nk.N_DECL_TYPE && guard < 16)
    {
        guard = guard + 1;
        r = mu_target(r.type_ann);
    }
    return r;
}

// does the body of `d` reach `root` again (through any constructor)?
fn bool reaches(Node* d, Node* root, Node** stack, int sp, int depth)
{
    if (d == null || depth > 64 || sp >= MU_MAX_STACK) { return false; }
    for (int i = 0; i < sp; i++) { if (stack[i] == d) { return false; } }
    stack[sp] = d;
    for (usz i = 0; i < d.child_count; i++)
    {
        Node* c = d.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_FIELD && c.type_ann != null) { if (reaches_ty(c.type_ann, root, stack, sp + 1, depth + 1)) { return true; } }
        else if (c.kind == Nk.N_DECL_VARIANT)
        {
            for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_type(c.children[j].kind) && reaches_ty(c.children[j], root, stack, sp + 1, depth + 1)) { return true; } }
        }
    }
    if (d.kind == Nk.N_DECL_NEWTYPE && d.type_ann != null) { if (reaches_ty(d.type_ann, root, stack, sp + 1, depth + 1)) { return true; } }
    return false;
}

fn bool reaches_ty(Node* ty, Node* root, Node** stack, int sp, int depth)
{
    if (ty == null || depth > 64) { return false; }
    Node* t = mu_target(ty);
    if (t != null)
    {
        if (t == root) { return true; }
        if (mu_is_type_decl(t) && reaches(t, root, stack, sp, depth + 1)) { return true; }
    }
    for (usz i = 0; i < ty.child_count; i++) { if (reaches_ty(ty.children[i], root, stack, sp, depth + 1)) { return true; } }
    return false;
}

// translate a type expression; `stack` holds the decls whose μ-binders are open
fn int MuState.tr(MuState* ms, Node* ty, Node** stack, int sp, int depth)
{
    TypeStore* ts = ms.ts;
    if (ty == null || depth > MU_MAX_DEPTH) { return ts.top_idx; }
    switch (ty.kind)
    {
        case Nk.N_TY_PTR:
        case Nk.N_TY_REF:
        {
            int inner = ty.child_count > 0 ? ms.tr(ty.children[0], stack, sp, depth + 1) : ts.top_idx;
            return ts.mk_option(inner);
        }
        case Nk.N_TY_ARRAY:
        case Nk.N_TY_SLICE:
            return ts.mk_array(ty.child_count > 0 ? ms.tr(ty.children[0], stack, sp, depth + 1) : ts.top_idx);
        case Nk.N_TY_TUPLE:
        {
            int cur = ts.mk_prim(theory_setops::PrimTag.PRIM_UNIT);
            for (usz i = 0; i < ty.child_count; i++)
            {
                int c = ms.tr(ty.children[i], stack, sp, depth + 1);
                cur = i == 0 ? c : ts.mk_binary(St.ST_TUPLE, cur, c);
            }
            return cur;
        }
        case Nk.N_TY_FN:
        {
            usz last = ty.child_count > 0 ? ty.child_count - 1 : 0;
            int args = ts.top_idx;
            usz seen = 0;
            for (usz i = 0; i < last; i++)
            {
                if (ty.children[i] == null || ty.children[i].kind == Nk.N_TY_EFFECT_ROW) { continue; }
                int a = ms.tr(ty.children[i], stack, sp, depth + 1);
                args = seen == 0 ? a : ts.mk_binary(St.ST_TUPLE, args, a);
                seen = seen + 1;
            }
            int ret = ty.child_count > 0 ? ms.tr(ty.children[last], stack, sp, depth + 1) : ts.top_idx;
            return ts.mk_arrow(args, ret);
        }
        case Nk.N_TY_NAME:
        case Nk.N_TY_PATH:
        case Nk.N_TY_GENERIC:
        {
            Node* t = mu_target(ty);
            if (t != null && mu_is_type_decl(t))
            {
                for (int i = sp - 1; i >= 0; i = i - 1)
                {
                    if (stack[i] == t) { return ts.mk_var(sp - 1 - i); }
                }
                return ms.tr_decl(t, stack, sp, depth + 1);
            }
            if (t != null && t.kind == Nk.N_DECL_TYPEPARAM) { return ts.top_idx; }
            return theory_subtype_full::translate_type(ts, ty, depth + 1);
        }
        default:
            return theory_subtype_full::translate_type(ts, ty, depth + 1);
    }
}

// body of a declaration under a fresh μ-binder for it
fn int MuState.tr_decl(MuState* ms, Node* d, Node** stack, int sp, int depth)
{
    TypeStore* ts = ms.ts;
    if (sp >= MU_MAX_STACK || depth > MU_MAX_DEPTH) { return ts.top_idx; }
    stack[sp] = d;
    int nsp = sp + 1;
    int body = ts.top_idx;
    if (d.kind == Nk.N_DECL_ENUM)
    {
        body = ts.bot_idx;
        for (usz i = 0; i < d.child_count; i++)
        {
            Node* v = d.children[i];
            if (v == null || v.kind != Nk.N_DECL_VARIANT) { continue; }
            int vt = ts.mk_nominal(v.name_id);
            for (usz j = 0; j < v.child_count; j++)
            {
                Node* pay = v.children[j];
                if (pay == null) { continue; }
                int pt = -1;
                if (pfront_core::is_type(pay.kind)) { pt = ms.tr(pay, stack, nsp, depth + 1); }
                else if (pay.kind == Nk.N_DECL_FIELD && pay.type_ann != null) { pt = ms.tr(pay.type_ann, stack, nsp, depth + 1); }
                if (pt >= 0) { vt = ts.mk_binary(St.ST_TUPLE, vt, pt); }
            }
            body = ts.my_union(body, vt);
        }
    }
    else if (d.kind == Nk.N_DECL_NEWTYPE)
    {
        body = d.type_ann != null ? ms.tr(d.type_ann, stack, nsp, depth + 1) : ts.top_idx;
    }
    else
    {
        // struct / union: product of the fields (a union is a sum, but for
        // inhabitation and shape comparison the field list is what matters;
        // we take the union of its fields' types)
        bool is_union = d.kind == Nk.N_DECL_UNION;
        body = is_union ? ts.bot_idx : ts.mk_prim(theory_setops::PrimTag.PRIM_UNIT);
        usz seen = 0;
        for (usz i = 0; i < d.child_count; i++)
        {
            Node* f = d.children[i];
            if (f == null || f.kind != Nk.N_DECL_FIELD || f.type_ann == null) { continue; }
            int ft = ms.tr(f.type_ann, stack, nsp, depth + 1);
            if (is_union) { body = ts.my_union(body, ft); }
            else { body = seen == 0 ? ft : ts.mk_binary(St.ST_TUPLE, body, ft); }
            seen = seen + 1;
        }
    }
    // only wrap in μ when the body actually uses the binder
    if (uses_var(ts, body, 0, 0)) { return ts.mk_mu(body); }
    return body;
}

fn bool uses_var(TypeStore* ts, int ty, int idx, int depth)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return false; }
    theory_setops::StNode* n = &ts.nodes[ty];
    if (n.kind == St.ST_VAR) { return n.mu_var == idx; }
    int inner = n.kind == St.ST_MU ? idx + 1 : idx;
    for (usz i = 0; i < n.child_count; i++) { if (uses_var(ts, n.children[i], inner, depth + 1)) { return true; } }
    return false;
}

// ── Inhabitation: least fixpoint reading ────────────────────────────────
// μX.B is inhabited by a finite value iff B[X := ∅] is non-empty (one
// unfolding with the empty type for the recursive occurrences: some
// constructor must bottom out). Nested μ's inside B are handled by the
// same substitution (their own variables are shifted by subst).
// a function value can always be written down (a closure), whatever its
// domain says: for the inhabitation question arrows are just "some value"
fn int erase_arrows(TypeStore* ts, int ty, int depth)
{
    if (ty < 0 || depth > MU_MAX_DEPTH) { return ty; }
    theory_setops::StNode* n = &ts.nodes[ty];
    switch (n.kind)
    {
        case St.ST_ARROW: return ts.mk_prim(theory_setops::PrimTag.PRIM_UNIT);
        case St.ST_TUPLE: case St.ST_UNION: case St.ST_INTER:
            if (n.child_count >= 2) { return ts.mk_binary(n.kind, erase_arrows(ts, n.children[0], depth + 1), erase_arrows(ts, n.children[1], depth + 1)); }
            return ty;
        case St.ST_OPTION: case St.ST_ARRAY: case St.ST_MU: case St.ST_NEG:
            if (n.child_count >= 1) { return ts.mk_unary(n.kind, erase_arrows(ts, n.children[0], depth + 1)); }
            return ty;
        default: return ty;
    }
}

fn bool MuState.inhabited(MuState* ms, int mu_ty)
{
    TypeStore* ts = ms.ts;
    theory_setops::StNode* n = &ts.nodes[mu_ty];
    if (n.kind != St.ST_MU || n.child_count < 1) { return true; }
    int base = subst(ts, erase_arrows(ts, n.children[0], 0), 0, ts.bot_idx, 0);
    int d = theory_setops::st_dnf(ts, base);
    return !theory_subtype_full::is_empty(ts, d, 0);
}

// ── Driver over the AST ─────────────────────────────────────────────────
fn void MuState.collect(MuState* ms, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    if (mu_is_type_decl(n) && ms.n_decls < MU_MAX_DECLS)
    {
        MuDecl* md = &ms.mdecls[ms.n_decls];
        ms.n_decls = ms.n_decls + 1;
        md.decl = n; md.ty = -1; md.recursive = false; md.contractive = true; md.inhabited = true;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null || pfront_core::is_type(c.kind) || pfront_core::is_pattern(c.kind)) { continue; }
        ms.collect(c, depth + 1);
    }
}

fn char* MuState.name(MuState* ms, uint id)
{
    if (ms.interner == null || id == 0) { return "_"; }
    char* s = ms.interner.text(id);
    return s == null ? "_" : s;
}

fn void MuState.scan_ast(MuState* ms, Node* root, int depth)
{
    (void)depth;
    if (root == null || ms.ts == null) { return; }
    ms.collect(root, 0);
    Node*[MU_MAX_STACK] stack;
    // 1. which declarations are recursive?
    for (usz i = 0; i < ms.n_decls; i++)
    {
        MuDecl* md = &ms.mdecls[i];
        md.recursive = reaches(md.decl, md.decl, &stack[0], 0, 0);
        if (!md.recursive) { continue; }
        ms.n_mu = ms.n_mu + 1;
        md.ty = ms.tr_decl(md.decl, &stack[0], 0, 0);
        theory_setops::StNode* tn = &ms.ts.nodes[md.ty];
        if (tn.kind == St.ST_MU)
        {
            md.contractive = ms.check_contractive(tn.children[0]);
            md.inhabited = ms.inhabited(md.ty);
        }
        else
        {
            // recursion only through a path the translation dropped (e.g. a
            // type parameter): nothing to unfold
            ms.n_contractive = ms.n_contractive + 1;
        }
        if (!md.inhabited)
        {
            ms.n_uninhabited = ms.n_uninhabited + 1;
            // structs/unions/newtypes embedding themselves by value are already
            // E3020 (infinite size) in the resolver; the enum case is the gap
            if (ms.diags != null && md.decl.kind == Nk.N_DECL_ENUM)
            {
                char* m = (char*)ms.arena.alloc(512, 1);
                snprintf(m, 512, "recursive %s `%s` has no finite value: every constructor embeds another `%s` by value, so nothing can ever be built (add a base case or an indirection)",
                         md.decl.kind == Nk.N_DECL_ENUM ? "enum" : (md.decl.kind == Nk.N_DECL_NEWTYPE ? "newtype" : "struct"),
                         ms.name(md.decl.name_id), ms.name(md.decl.name_id));
                ms.diags.warn(pfront_core::Phase.PH_RESOLVE, 4250, md.decl.line, md.decl.col, m, ms.file);
                ms.n_w4250 = ms.n_w4250 + 1;
            }
        }
    }
    // 2. pairwise shape comparison of recursive types of the same kind
    usz compared = 0;
    for (usz i = 0; i < ms.n_decls && compared < 4096; i++)
    {
        MuDecl* a = &ms.mdecls[i];
        if (!a.recursive || a.ty < 0 || !a.contractive) { continue; }
        for (usz j = i + 1; j < ms.n_decls && compared < 4096; j++)
        {
            MuDecl* b = &ms.mdecls[j];
            if (!b.recursive || b.ty < 0 || !b.contractive || b.decl.kind != a.decl.kind) { continue; }
            compared = compared + 1;
            memo_clear(ms);
            bool ab = mu_subtype(ms, a.ty, b.ty, 0);
            memo_clear(ms);
            bool ba = mu_subtype(ms, b.ty, a.ty, 0);
            if (ab && ba)
            {
                ms.n_equal_pairs = ms.n_equal_pairs + 1;
                if (ms.diags != null && ms.diags.advisories)
                {
                    char* m = (char*)ms.arena.alloc(512, 1);
                    snprintf(m, 512, "`%s` is structurally identical to `%s` (same constructors, same payload shapes, same recursion): one definition with two names — they can share a layout",
                             ms.name(b.decl.name_id), ms.name(a.decl.name_id));
                    ms.diags.note(pfront_core::Phase.PH_RESOLVE, 4251, b.decl.line, b.decl.col, m, ms.file);
                    ms.n_n4251 = ms.n_n4251 + 1;
                }
            }
            else if (ab || ba) { ms.n_subtype_pairs = ms.n_subtype_pairs + 1; }
        }
    }
    ms.n_compared = compared;
}

fn void MuState.report(MuState* ms)
{
    printf("  mu-types         : %d type decls, %d recursive → μ-types: %d contractive, %d non-contractive, %d uninhabited; %d pairs compared: %d structurally equal, %d one-way subtypes\n",
           (int)ms.n_decls, (int)ms.n_mu, (int)ms.n_contractive, (int)ms.n_non_contractive, (int)ms.n_uninhabited,
           (int)ms.n_compared, (int)ms.n_equal_pairs, (int)ms.n_subtype_pairs);
    printf("  mu-unfold        : L=%d R=%d unfold steps, %d subtype calls, %d memo hits\n",
           (int)ms.n_unfold_left, (int)ms.n_unfold_right,
           (int)ms.n_subtype_calls, (int)ms.n_memo_hit);
}

fn void MuState.destroy(MuState* ms)
{
    if (ms.memo != null) { free((void*)ms.memo); ms.memo = null; }
    if (ms.mdecls != null) { free((void*)ms.mdecls); ms.mdecls = null; }
    ms.ts = null; ms.arena = null;
}
