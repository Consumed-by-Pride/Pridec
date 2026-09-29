// ============================================================================
// theory_ub.c3 — Explicit undefined behaviour lattice (Lee et al. 2012; Lee 2018)
// ----------------------------------------------------------------------------
// Undefined behaviour is not a single bit. Every value is one of
//
//              UB       the program is meaningless from here on
//             /
//         POISON       a value that is UB the moment it is USED
//        /
//    DEFINED
//
// (Lee/Kim/Park/Song 2012 "Taming Undefined Behavior in LLVM"; Lee/Kim/Sun/
// Song 2018 "Freezing Poison"). Pride's spec §14 adopts exactly this split:
// `poison` is a value that propagates UB *if used*, `ub!` is immediate UB.
//
// This pass makes the lattice do work. Per function, in statement order:
//
//   sources      `poison`                         → POISON
//                `x << n` with literal n ≥ width  → POISON (LLVM: shl poison)
//                `x << n`, `x >> n` with n < 0    → POISON
//                anything with a POISON operand   → POISON (arithmetic,
//                                                   casts, tuples, fields)
//   bindings     `let x = e` carries e's value to every use of x; an
//                assignment `x = e` re-tags x (mutable bindings included:
//                the walk is in statement order)
//   uses         a POISON value at a point where the semantics demands a
//                defined one is UB, reported ONCE per point with its origin:
//                   branch condition        (if / while / match scrutinee)
//                   pointer dereference, index base or index
//                   call argument, method receiver
//                   return value
//                   divisor of / or %
//                   value written to memory (field/index/deref target)
//                   assert / assume operand
//   ub!          statements after `ub!` / `unreachable` in the same block
//                are unreachable (noted once per block)
//
// Diagnostics (all advisory — Pride is untyped, nothing is rejected):
//   W4140  poison used here (<how>): undefined behaviour; it came from
//          `poison` at L:C [via x]
//   W4141  shift by N on a W-bit value is poison
//   N4142  N statement(s) after `ub!` here can never run
//
// What it does not claim: poison through calls (a callee returning poison
// is DEF here — no interprocedural summary), through memory (a store of
// poison is itself reported as a use; loads are DEF), or path-sensitively
// (a `mut` re-tagged in one branch is re-tagged for what follows). Every
// number in the report is a count of things actually found.
// ============================================================================

module theory_ub;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz cap, char* fmt, ...);

const int UB_MAX_DEPTH = 200;
const usz UB_MAX_BINDS = 4096;
const usz UB_MAX_DIAGS = 32;

enum UbVal : int
{
    UB_DEF,        // definitely defined
    UB_POISON,     // poison: UB when used
    UB_UB          // undefined behaviour reached
}

fn char* ub_name(UbVal v)
{
    switch (v)
    {
        case UbVal.UB_DEF:    return "def";
        case UbVal.UB_POISON: return "poison";
        case UbVal.UB_UB:     return "ub";
    }
}

fn UbVal ub_join(UbVal a, UbVal b) { return (int)a >= (int)b ? a : b; }

// A value tag: the lattice point plus where the poison came from.
struct UbTag
{
    UbVal v;
    Node* origin;     // the `poison` (or shift) that started it
    Node* via;        // the binding it travelled through, if any
}

struct UbBind
{
    Node* binder;
    UbTag tag;
}

struct UbAnalysis
{
    Arena*  arena;
    pfront_core::DiagBag* diags;
    pfront_core::Interner* interner;
    char*   file;
    UbBind* binds;
    usz     bind_count;
    usz     diags_emitted;

    // Real counts.
    usz n_fns;
    usz n_poison_sources;
    usz n_poison_shifts;
    usz n_poison_bindings;
    usz n_ub_uses;
    usz n_dead_after_ub;
    usz n_div;
    usz n_shift;
    usz n_deref;
    usz n_branch;
}

fn void UbAnalysis.init(UbAnalysis* u, Arena* a)
{
    u.arena = a;
    u.diags = null;
    u.interner = null;
    u.file = null;
    u.binds = (UbBind*)malloc(UbBind::size * UB_MAX_BINDS);
    u.bind_count = 0;
    u.diags_emitted = 0;
    u.n_fns = 0; u.n_poison_sources = 0; u.n_poison_shifts = 0; u.n_poison_bindings = 0;
    u.n_ub_uses = 0; u.n_dead_after_ub = 0;
    u.n_div = 0; u.n_shift = 0; u.n_deref = 0; u.n_branch = 0;
}

fn void UbAnalysis.attach(UbAnalysis* u, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file) { u.diags = d; u.interner = it; u.file = file; }

fn void UbAnalysis.destroy(UbAnalysis* u)
{
    if (u.binds != null) { free((void*)u.binds); u.binds = null; }
}

fn UbTag tag_def()
{
    UbTag t; t.v = UbVal.UB_DEF; t.origin = null; t.via = null; return t;
}

fn UbTag tag_poison(Node* origin)
{
    UbTag t; t.v = UbVal.UB_POISON; t.origin = origin; t.via = null; return t;
}

fn UbTag tag_join(UbTag a, UbTag b)
{
    if ((int)b.v > (int)a.v) { return b; }
    return a;
}

// ── Bindings ────────────────────────────────────────────────────────────────
fn void UbAnalysis.bind(UbAnalysis* u, Node* binder, UbTag t)
{
    if (binder == null || u.binds == null) { return; }
    for (usz i = 0; i < u.bind_count; i++)
    {
        if (u.binds[i].binder == binder) { u.binds[i].tag = t; return; }
    }
    if (t.v == UbVal.UB_DEF) { return; }              // absent means DEF
    if (u.bind_count >= UB_MAX_BINDS) { return; }
    u.binds[u.bind_count].binder = binder;
    u.binds[u.bind_count].tag = t;
    u.bind_count = u.bind_count + 1;
}

fn UbTag UbAnalysis.lookup(UbAnalysis* u, Node* binder)
{
    if (binder == null || u.binds == null) { return tag_def(); }
    for (usz i = 0; i < u.bind_count; i++)
    {
        if (u.binds[i].binder == binder) { return u.binds[i].tag; }
    }
    return tag_def();
}

// ── Reporting ───────────────────────────────────────────────────────────────
fn void UbAnalysis.report_use(UbAnalysis* u, Node* at, UbTag t, char* how)
{
    u.n_ub_uses = u.n_ub_uses + 1;
    if (u.diags == null || u.diags_emitted >= UB_MAX_DIAGS || at == null) { return; }
    u.diags_emitted = u.diags_emitted + 1;
    char* msg = (char*)u.arena.alloc(256, 1);
    if (msg == null) { return; }
    int ol = t.origin != null ? t.origin.line : 0;
    int oc = t.origin != null ? t.origin.col : 0;
    char* what = (t.origin != null && t.origin.kind == Nk.N_EXPR_BINARY) ? "a poison shift" : "`poison`";
    if (t.via != null && t.via.name_id != 0)
    {
        char* nm = u.interner != null ? u.interner.text(t.via.name_id) : null;
        snprintf(msg, 256, "poison is used here (%s): undefined behaviour; it came from %s at %d:%d via `%s`",
                 how, what, ol, oc, nm != null ? nm : "?");
    }
    else
    {
        snprintf(msg, 256, "poison is used here (%s): undefined behaviour; it came from %s at %d:%d",
                 how, what, ol, oc);
    }
    u.diags.warn(pfront_core::Phase.PH_RESOLVE, 4140, at.line, at.col, msg, u.file);
}

fn void UbAnalysis.report_shift(UbAnalysis* u, Node* at, long amt, int width)
{
    u.n_poison_shifts = u.n_poison_shifts + 1;
    if (u.diags == null || u.diags_emitted >= UB_MAX_DIAGS) { return; }
    u.diags_emitted = u.diags_emitted + 1;
    char* msg = (char*)u.arena.alloc(160, 1);
    if (msg == null) { return; }
    if (amt < 0) { snprintf(msg, 160, "shift by a negative amount (%ld) is poison", amt); }
    else { snprintf(msg, 160, "shift by %ld on a %d-bit value is poison (amount must be < %d)", amt, width, width); }
    u.diags.warn(pfront_core::Phase.PH_RESOLVE, 4141, at.line, at.col, msg, u.file);
}

fn void UbAnalysis.report_dead(UbAnalysis* u, Node* at, usz count)
{
    u.n_dead_after_ub = u.n_dead_after_ub + count;
    if (u.diags == null || u.diags_emitted >= UB_MAX_DIAGS) { return; }
    u.diags_emitted = u.diags_emitted + 1;
    char* msg = (char*)u.arena.alloc(160, 1);
    if (msg == null) { return; }
    snprintf(msg, 160, "%d statement%s after this `%s` can never run",
             (int)count, count == 1 ? "" : "s", at.kind == Nk.N_EXPR_UB ? "ub!" : "unreachable");
    u.diags.note(pfront_core::Phase.PH_RESOLVE, 4142, at.line, at.col, msg, u.file);
}

// ── Widths ──────────────────────────────────────────────────────────────────
// The bit width of an operand when it is knowable locally: a suffixed
// literal, or an identifier whose binding was initialised by one.
fn int UbAnalysis.width_of(UbAnalysis* u, Node* n, int depth)
{
    if (n == null || depth > 8) { return 0; }
    if (n.kind == Nk.N_EXPR_INT && n.p.width != 0) { return (int)n.p.width; }
    if (n.kind == Nk.N_EXPR_TUPLE && n.child_count == 1) { return u.width_of(n.children[0], depth + 1); }
    if (n.kind == Nk.N_EXPR_BINARY && n.child_count == 2)
    {
        int a = u.width_of(n.children[0], depth + 1);
        return a != 0 ? a : u.width_of(n.children[1], depth + 1);
    }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null)
    {
        Node* b = n.resolved;
        if (b.kind == Nk.N_PAT_IDENT && b.parent != null && b.parent.kind == Nk.N_DECL_LET
            && b.parent.child_count >= 2 && (b.flags & pfront_core::NF_MUT) == 0)
        {
            return u.width_of(b.parent.children[b.parent.child_count - 1], depth + 1);
        }
    }
    return 0;
}

fn bool const_int(Node* n, long* out)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_EXPR_INT) { *out = (long)n.p.ival; return true; }
    if (n.kind == Nk.N_EXPR_TUPLE && n.child_count == 1) { return const_int(n.children[0], out); }
    if (n.kind == Nk.N_EXPR_UNARY && n.child_count == 1 && (Tk)n.p.op == Tk.TOKEN_MINUS)
    {
        long v; if (!const_int(n.children[0], &v)) { return false; }
        *out = -v; return true;
    }
    return false;
}

// ── Evaluation: the tag of an expression ────────────────────────────────────
fn UbTag UbAnalysis.eval(UbAnalysis* u, Node* n, int depth)
{
    if (n == null || depth > UB_MAX_DEPTH) { return tag_def(); }
    switch (n.kind)
    {
        case N_EXPR_POISON:
            u.n_poison_sources = u.n_poison_sources + 1;
            return tag_poison(n);

        case N_EXPR_INT: case N_EXPR_FLOAT: case N_EXPR_BOOL: case N_EXPR_CHAR:
        case N_EXPR_STRING: case N_EXPR_UNIT: case N_EXPR_NULL:
            return tag_def();

        case N_EXPR_IDENT:
        {
            UbTag t = u.lookup(n.resolved);
            if (t.v != UbVal.UB_DEF) { t.via = n.resolved; }   // nearest binding it travelled through
            return t;
        }

        case N_EXPR_BINARY:
        {
            if (n.child_count != 2) { return u.eval_children(n, depth); }
            Tk op = (Tk)n.p.op;
            UbTag a = u.eval(n.children[0], depth + 1);
            UbTag b = u.eval(n.children[1], depth + 1);
            if (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
            {
                u.n_div = u.n_div + 1;
                if (b.v == UbVal.UB_POISON) { u.report_use(n, b, "as a divisor"); }
            }
            if (op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT)
            {
                u.n_shift = u.n_shift + 1;
                long amt;
                if (const_int(n.children[1], &amt))
                {
                    int w = u.width_of(n.children[0], 0);
                    if (amt < 0 || (w != 0 && amt >= (long)w))
                    {
                        u.report_shift(n, amt, w != 0 ? w : 64);
                        return tag_poison(n);
                    }
                }
            }
            return tag_join(a, b);
        }

        case N_EXPR_UNARY:
        {
            if (n.child_count != 1) { return tag_def(); }
            UbTag a = u.eval(n.children[0], depth + 1);
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_STAR)
            {
                u.n_deref = u.n_deref + 1;
                if (a.v == UbVal.UB_POISON) { u.report_use(n, a, "as a dereferenced pointer"); return tag_def(); }
            }
            return a;
        }

        case N_EXPR_DEREF:
        {
            u.n_deref = u.n_deref + 1;
            UbTag a = u.eval(n.child(0), depth + 1);
            if (a.v == UbVal.UB_POISON) { u.report_use(n, a, "as a dereferenced pointer"); }
            return tag_def();     // what is loaded is not tracked
        }

        case N_EXPR_INDEX:
        {
            UbTag base = u.eval(n.child(0), depth + 1);
            if (base.v == UbVal.UB_POISON) { u.report_use(n, base, "as an indexed base"); }
            for (usz i = 1; i < n.child_count; i++)
            {
                UbTag ix = u.eval(n.children[i], depth + 1);
                if (ix.v == UbVal.UB_POISON) { u.report_use(n.children[i], ix, "as an index"); }
            }
            return tag_def();
        }

        case N_EXPR_CALL:
        case N_EXPR_METHOD:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                UbTag t = u.eval(c, depth + 1);
                if (t.v == UbVal.UB_POISON)
                {
                    char* how = (i == 0) ? (n.kind == Nk.N_EXPR_METHOD ? "as a method receiver" : "as a callee") : "as a call argument";
                    u.report_use(c, t, how);
                }
            }
            return tag_def();     // no interprocedural summary: a call result is defined here
        }

        case N_EXPR_IF:
        {
            u.n_branch = u.n_branch + 1;
            UbTag c = u.eval(n.child(0), depth + 1);
            if (c.v == UbVal.UB_POISON) { u.report_use(n.child(0), c, "as a branch condition"); }
            UbTag r = tag_def();
            for (usz i = 1; i < n.child_count; i++) { r = tag_join(r, u.eval_stmt(n.children[i], depth + 1)); }
            return r;
        }

        case N_EXPR_WHILE:
        {
            u.n_branch = u.n_branch + 1;
            UbTag c = u.eval(n.child(0), depth + 1);
            if (c.v == UbVal.UB_POISON) { u.report_use(n.child(0), c, "as a loop condition"); }
            for (usz i = 1; i < n.child_count; i++) { u.eval_stmt(n.children[i], depth + 1); }
            return tag_def();
        }

        case N_EXPR_MATCH:
        {
            u.n_branch = u.n_branch + 1;
            UbTag s = u.eval(n.child(0), depth + 1);
            if (s.v == UbVal.UB_POISON) { u.report_use(n.child(0), s, "as a match scrutinee"); }
            UbTag r = tag_def();
            for (usz i = 1; i < n.child_count; i++) { r = tag_join(r, u.eval_stmt(n.children[i], depth + 1)); }
            return r;
        }

        case N_EXPR_ASSERT:
        case N_EXPR_ASSUME:
        {
            UbTag a = u.eval(n.child(0), depth + 1);
            if (a.v == UbVal.UB_POISON) { u.report_use(n.child(0), a, n.kind == Nk.N_EXPR_ASSERT ? "as an assertion" : "as an assumption"); }
            return tag_def();
        }

        case N_EXPR_ASSIGN:
            return u.eval_assign(n, depth);

        case N_BLOCK:
            return u.eval_block(n, depth);

        case N_EXPR_LAMBDA:
        case N_EXPR_QUOTE:
        case N_DECL_FN:
            return tag_def();     // separate bodies; a lambda value itself is defined

        default:
            return u.eval_children(n, depth);
    }
}

fn UbTag UbAnalysis.eval_children(UbAnalysis* u, Node* n, int depth)
{
    UbTag r = tag_def();
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        if (pfront_core::is_pattern(c.kind)) { continue; }
        r = tag_join(r, pfront_core::is_expr(c.kind) || c.kind == Nk.N_BLOCK ? u.eval(c, depth + 1) : u.eval_stmt(c, depth + 1));
    }
    return r;
}

// `place = value`: a write of poison to memory is a use; a write to a plain
// binding re-tags it.
fn UbTag UbAnalysis.eval_assign(UbAnalysis* u, Node* n, int depth)
{
    if (n.child_count < 2) { return tag_def(); }
    Node* lhs = n.children[0];
    UbTag v = u.eval(n.children[n.child_count - 1], depth + 1);
    if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT)
    {
        if (v.v == UbVal.UB_POISON) { u.n_poison_bindings = u.n_poison_bindings + 1; }
        u.bind(lhs.resolved, v);
        return tag_def();
    }
    // Sub-expressions of the place (index, base) are evaluated as uses.
    if (lhs != null)
    {
        for (usz i = 0; i < lhs.child_count; i++)
        {
            UbTag p = u.eval(lhs.children[i], depth + 1);
            if (p.v == UbVal.UB_POISON) { u.report_use(lhs.children[i], p, "as part of a written place"); }
        }
    }
    if (v.v == UbVal.UB_POISON) { u.report_use(n, v, "as a value written to memory"); }
    return tag_def();
}

fn UbTag UbAnalysis.eval_stmt(UbAnalysis* u, Node* s, int depth)
{
    if (s == null || depth > UB_MAX_DEPTH) { return tag_def(); }
    switch (s.kind)
    {
        case N_DECL_LET:
        case N_DECL_CONST:
        {
            if (s.child_count < 2) { return tag_def(); }
            Node* pat = s.children[0];
            UbTag v = u.eval(s.children[s.child_count - 1], depth + 1);
            if (pat != null && pat.kind == Nk.N_PAT_IDENT)
            {
                if (v.v == UbVal.UB_POISON) { u.n_poison_bindings = u.n_poison_bindings + 1; }
                u.bind(pat, v);
            }
            return tag_def();
        }
        case N_STMT_ASSIGN:
        case N_STMT_COMPOUND_ASSIGN:
            return u.eval_assign(s, depth);
        case N_STMT_RETURN:
        {
            UbTag v = u.eval(s.child(0), depth + 1);
            if (v.v == UbVal.UB_POISON) { u.report_use(s, v, "as a return value"); }
            return tag_def();
        }
        case N_BLOCK:
            return u.eval_block(s, depth);
        case N_CLAUSE:
        case N_MATCH_ARM:
        {
            UbTag r = tag_def();
            for (usz i = 1; i < s.child_count; i++)
            {
                Node* c = s.children[i];
                if (c == null) { continue; }
                r = tag_join(r, pfront_core::is_expr(c.kind) || c.kind == Nk.N_BLOCK ? u.eval(c, depth + 1) : u.eval_stmt(c, depth + 1));
            }
            return r;
        }
        default:
            if (pfront_core::is_expr(s.kind)) { return u.eval(s, depth); }
            return u.eval_children(s, depth);
    }
}

// A block's value is its last expression's tag (so `let x = { …; poison }`
// carries poison out). Statements after `ub!`/`unreachable` are dead.
fn UbTag UbAnalysis.eval_block(UbAnalysis* u, Node* b, int depth)
{
    UbTag last = tag_def();
    for (usz i = 0; i < b.child_count; i++)
    {
        Node* s = b.children[i];
        if (s == null) { continue; }
        if (stmt_diverges(s, 0))
        {
            usz after = b.child_count - i - 1;
            if (after > 0) { u.report_dead(diverging_leaf(s, 0), after); }
            return tag_def();
        }
        last = pfront_core::is_expr(s.kind) || s.kind == Nk.N_BLOCK ? u.eval(s, depth + 1) : u.eval_stmt(s, depth + 1);
        if (!pfront_core::is_expr(s.kind) && s.kind != Nk.N_BLOCK) { last = tag_def(); }
    }
    return last;
}

// `ub!` / `unreachable`, possibly wrapped in `unsafe { … }` or a block
// whose last statement is one.
fn bool stmt_diverges(Node* s, int depth)
{
    if (s == null || depth > 8) { return false; }
    if (s.kind == Nk.N_EXPR_UB || s.kind == Nk.N_EXPR_UNREACHABLE) { return true; }
    if ((s.kind == Nk.N_EXPR_UNSAFE || s.kind == Nk.N_BLOCK) && s.child_count >= 1)
    {
        return stmt_diverges(s.children[s.child_count - 1], depth + 1);
    }
    return false;
}

fn Node* diverging_leaf(Node* s, int depth)
{
    if (s == null || depth > 8) { return s; }
    if (s.kind == Nk.N_EXPR_UB || s.kind == Nk.N_EXPR_UNREACHABLE) { return s; }
    if (s.child_count >= 1) { return diverging_leaf(s.children[s.child_count - 1], depth + 1); }
    return s;
}

// ── Driver ──────────────────────────────────────────────────────────────────
fn void UbAnalysis.run_fn(UbAnalysis* u, Node* f)
{
    u.n_fns = u.n_fns + 1;
    u.bind_count = 0;
    for (usz i = 0; i < f.child_count; i++)
    {
        Node* c = f.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_BLOCK) { u.eval_block(c, 0); }
        else if (c.kind == Nk.N_CLAUSE) { u.eval_stmt(c, 0); }
    }
    // Lambdas inside get their own scan (their bodies were skipped above).
    u.scan_lambdas(f, 0);
}

fn void UbAnalysis.scan_lambdas(UbAnalysis* u, Node* n, int depth)
{
    if (n == null || depth > UB_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_LAMBDA && n.child_count >= 1)
    {
        Node* body = n.children[n.child_count - 1];
        if (body != null && body.kind == Nk.N_BLOCK) { u.eval_block(body, 0); }
        else if (body != null) { u.eval_stmt(body, 0); }
    }
    for (usz i = 0; i < n.child_count; i++) { u.scan_lambdas(n.children[i], depth + 1); }
}

fn void UbAnalysis.walk(UbAnalysis* u, Node* n, int depth)
{
    if (n == null || depth > UB_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN) { u.run_fn(n); return; }
    for (usz i = 0; i < n.child_count; i++) { u.walk(n.children[i], depth + 1); }
}

fn void UbAnalysis.report(UbAnalysis* u)
{
    printf("  ub-lattice       : %d fns; %d poison sources, %d poison shifts, %d poison bindings, %d UB uses, %d dead after ub!\n",
           (int)u.n_fns, (int)u.n_poison_sources, (int)u.n_poison_shifts, (int)u.n_poison_bindings,
           (int)u.n_ub_uses, (int)u.n_dead_after_ub);
    printf("  ub-ops           : %d div, %d shift, %d deref, %d branches\n",
           (int)u.n_div, (int)u.n_shift, (int)u.n_deref, (int)u.n_branch);
}
