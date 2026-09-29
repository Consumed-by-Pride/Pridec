// ============================================================================
// theory_quals.c3 — interprocedural qualifier inference: purity, global
//                   reads/writes, parameter mutation and escape, divergence
// ----------------------------------------------------------------------------
// The previous file in this slot carried a "current qualifier word" through
// a walk, set PURE to NO on any assignment or call, and reported how many
// functions ended up with which bits. Calls were opaque (every call made the
// caller impure), parameters were never looked at, and nothing was written
// back or reported to the user.
//
// This module infers, for every function in the program, a small set of
// SEMANTIC QUALIFIERS by a whole-program fixpoint over the call graph:
//
//   effect facts (reasons a function is not pure), each with the AST node
//   that first caused it so the user can be told WHY:
//     R_WRITES_GLOBAL   assigns to a `static` / module-level binder, or
//                       through a pointer whose base is not a local
//     R_READS_GLOBAL    reads a `static` (mutable) binder
//     R_WRITES_PARAM    assigns through / into a parameter (per parameter)
//     R_EFFECT          perform / handle / resume / syscall / asm / atomic /
//                       fence / volatile / free / trap
//     R_ALLOC           allocates (result is a fresh identity: not CSE-able)
//     R_UNKNOWN_CALL    calls an extern / indirect / unresolved callee
//     R_IMPURE_CALLEE   calls a function that is itself impure
//     R_LOOP            contains a loop           (may diverge)
//     R_RECURSIVE       is in a recursive cycle   (may diverge)
//
//   parameter facts: written (directly, through a field/index/deref, via
//   `&mut p`, or by passing it to a callee that writes that parameter) and
//   escaping (stored, returned, captured, passed to an unknown callee).
//
//   FIXPOINT   optimistic start (every function pure, every parameter
//   read-only); each round re-derives facts from bodies + current callee
//   facts; facts only grow, so the iteration reaches the greatest fixpoint
//   — the standard treatment of recursion: a function whose only
//   impurity would be "calls itself" stays pure.
//
//   CLASSES    PURE      no reason at all (referentially transparent: the
//                        result depends only on the arguments; CSE / memo /
//                        LLVM `readnone`)
//              READONLY  reads globals but writes nothing (LLVM `readonly`)
//              ALLOC     additionally allocates
//              IMPURE    anything else
//              (+ may-diverge: R_LOOP or R_RECURSIVE)
//
//   WRITEBACK  NF_PURE_FN on the N_DECL_FN of PURE and READONLY functions
//              (new flag); NF_READONLY_PARAM on every parameter binder that
//              is neither written nor escaping (new flag). Both are exactly
//              the attributes an LLVM backend attaches (`readnone`/
//              `readonly`, `noalias readonly` / by-reference passing).
//
//   DIAGNOSTICS
//     W4220  a call to a pure/readonly function in statement position:
//            the result is discarded, so the call does nothing
//     W4221  a `mut` parameter / `&mut` parameter that is never written
//     N4222  (--lint) function proven pure (reason list when it is not)
//     N4223  (--lint) parameter never written nor escaping: read-only
//
// References: Foster, Terauchi & Aiken 2002 "Flow-Sensitive Type
// Qualifiers"; Salcianu & Rinard 2005 "Purity and Side Effect Analysis for
// Java Programs"; Cousot & Cousot 1977 (fixpoints over program facts).
// ============================================================================

module theory_quals;

import pfront_lex;
import pfront_core;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn void* memset(void* p, int c, usz n);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz QA_MAX_FNS    = 8192;
const usz QA_MAX_PARAMS = 32;
const usz QA_BUCKETS    = 8192;
const int QA_MAX_DEPTH  = 200;
const int QA_MAX_ROUNDS = 24;

// reasons (bitmask)
const uint R_WRITES_GLOBAL = 1;
const uint R_READS_GLOBAL  = 2;
const uint R_WRITES_PARAM  = 4;
const uint R_EFFECT        = 8;
const uint R_ALLOC         = 16;
const uint R_UNKNOWN_CALL  = 32;
const uint R_IMPURE_CALLEE = 64;
const uint R_LOOP          = 128;
const uint R_RECURSIVE     = 256;

const uint R_IMPURE_MASK   = R_WRITES_GLOBAL | R_WRITES_PARAM | R_EFFECT | R_UNKNOWN_CALL | R_IMPURE_CALLEE;
const uint R_DIVERGE_MASK  = R_LOOP | R_RECURSIVE;

enum Qclass : char
{
    Q_PURE,
    Q_READONLY,
    Q_ALLOC,
    Q_IMPURE
}

struct FnQ
{
    Node*  decl;
    uint   name;
    usz    n_params;
    Node*[QA_MAX_PARAMS] params;      // binder nodes (param decl or pat-ident)
    uint   reasons;
    Node*[9] why;                     // first node per reason bit
    uint   written;                   // param bitmask
    uint   escapes;                   // param bitmask
    Node*[QA_MAX_PARAMS] written_at;
    usz    n_calls;
    usz    n_callers;
    bool   returns_unit;
    Qclass cls;
    bool   is_extern;
}

struct FnSlot
{
    Node*  decl;
    int    idx;
    FnSlot* next;
}

struct QualAnalysis
{
    Arena* arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*  file;

    FnQ*   fns;
    usz    n_fns;
    FnSlot*[QA_BUCKETS] map;

    // walk state
    FnQ*   cur;
    bool   changed;
    int    rounds;

    // aggregate
    usz n_pure, n_readonly, n_alloc, n_impure, n_diverge;
    usz n_params_total, n_params_readonly, n_params_written, n_params_escape;
    usz n_w4220, n_w4221, n_n4222, n_n4223;
    usz n_calls_total, n_calls_unknown, n_calls_pure;
    usz n_edges;
    usz n_flag_pure, n_flag_param;
}

// ── Setup ───────────────────────────────────────────────────────────────
fn void QualAnalysis.init(QualAnalysis* q, Arena* a)
{
    q.arena = a;
    q.diags = null; q.interner = null; q.file = null;
    q.fns = (FnQ*)calloc(QA_MAX_FNS, FnQ::size);
    q.n_fns = 0;
    for (usz i = 0; i < QA_BUCKETS; i++) { q.map[i] = null; }
    q.cur = null; q.changed = false; q.rounds = 0;
    q.n_pure = 0; q.n_readonly = 0; q.n_alloc = 0; q.n_impure = 0; q.n_diverge = 0;
    q.n_params_total = 0; q.n_params_readonly = 0; q.n_params_written = 0; q.n_params_escape = 0;
    q.n_w4220 = 0; q.n_w4221 = 0; q.n_n4222 = 0; q.n_n4223 = 0;
    q.n_calls_total = 0; q.n_calls_unknown = 0; q.n_calls_pure = 0; q.n_edges = 0;
    q.n_flag_pure = 0; q.n_flag_param = 0;
}

fn void QualAnalysis.attach(QualAnalysis* q, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    q.diags = d; q.interner = it; q.file = file;
}

fn void QualAnalysis.destroy(QualAnalysis* q)
{
    if (q.fns != null) { free((void*)q.fns); q.fns = null; }
}

fn char* QualAnalysis.name(QualAnalysis* q, uint id)
{
    if (q.interner == null || id == 0) { return "_"; }
    char* s = q.interner.text(id);
    return s == null ? "_" : s;
}

fn char* QualAnalysis.msgbuf(QualAnalysis* q)
{
    return (char*)q.arena.alloc(512, 1);
}

// ── Function table ──────────────────────────────────────────────────────
fn usz slot_hash(Node* d)
{
    ulong h = (ulong)(uptr)d;
    h = (h >> 4) * 0x9E3779B97F4A7C15UL;
    return (usz)(h >> 20) & (QA_BUCKETS - 1);
}

fn FnQ* QualAnalysis.lookup(QualAnalysis* q, Node* decl)
{
    if (decl == null) { return null; }
    FnSlot* s = q.map[slot_hash(decl)];
    while (s != null) { if (s.decl == decl) { return &q.fns[s.idx]; } s = s.next; }
    return null;
}

fn bool type_is_unit(Node* ty)
{
    if (ty == null) { return false; }
    if (ty.kind == Nk.N_TY_UNIT) { return true; }
    if (ty.kind == Nk.N_TY_TUPLE && ty.child_count == 0) { return true; }
    return false;
}

fn Node* fn_return_type(Node* decl)
{
    Node* t = decl.type_ann;
    if (t == null) { return null; }
    if (t.kind == Nk.N_TY_FN && t.child_count >= 1)
    {
        // last child: return type (possibly wrapped in a constraint / effect row)
        Node* r = t.children[t.child_count - 1];
        if (r != null && r.kind == Nk.N_TY_CONSTRAINT && r.child_count > 0) { r = r.children[0]; }
        return r;
    }
    return t;
}

fn void QualAnalysis.register(QualAnalysis* q, Node* decl)
{
    if (q.n_fns >= QA_MAX_FNS || q.lookup(decl) != null) { return; }
    FnQ* f = &q.fns[q.n_fns];
    memset((void*)f, 0, FnQ::size);
    f.decl = decl; f.name = decl.name_id;
    f.is_extern = decl.kind == Nk.N_DECL_EXTERN_FN || (decl.flags & pfront_core::NF_EXTERN) != 0;
    // a declaration without a body (`fn f : T -> U #extern("sym")`) is foreign
    if (!f.is_extern)
    {
        bool has_body = false;
        for (usz i = 0; i < decl.child_count; i++)
        {
            Node* c = decl.children[i];
            if (c != null && (c.kind == Nk.N_CLAUSE || c.kind == Nk.N_BLOCK || pfront_core::is_expr(c.kind))) { has_body = true; break; }
        }
        if (!has_body) { f.is_extern = true; }
    }
    f.returns_unit = type_is_unit(fn_return_type(decl));
    // parameters: N_DECL_PARAM children, else the first clause's pattern components
    for (usz i = 0; i < decl.child_count && f.n_params < QA_MAX_PARAMS; i++)
    {
        Node* c = decl.children[i];
        if (c != null && c.kind == Nk.N_DECL_PARAM) { f.params[f.n_params] = c; f.n_params = f.n_params + 1; }
    }
    if (f.n_params == 0)
    {
        for (usz i = 0; i < decl.child_count; i++)
        {
            Node* c = decl.children[i];
            if (c == null || c.kind != Nk.N_CLAUSE) { continue; }
            Node* pat = null;
            for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_pattern(c.children[j].kind)) { pat = c.children[j]; break; } }
            if (pat == null) { break; }
            if (pat.kind == Nk.N_PAT_TUPLE)
            {
                for (usz j = 0; j < pat.child_count && f.n_params < QA_MAX_PARAMS; j++) { f.params[f.n_params] = pat.children[j]; f.n_params = f.n_params + 1; }
            }
            else { f.params[0] = pat; f.n_params = 1; }
            break;   // positions are what matter; later clauses bind the same positions
        }
    }
    if (f.is_extern) { f.reasons = R_UNKNOWN_CALL; f.why[5] = decl; }
    FnSlot* s = (FnSlot*)q.arena.alloc(FnSlot::size, 8);
    if (s == null) { return; }
    usz h = slot_hash(decl);
    s.decl = decl; s.idx = (int)q.n_fns; s.next = q.map[h];
    q.map[h] = s;
    q.n_fns = q.n_fns + 1;
    q.n_params_total = q.n_params_total + f.n_params;
}

fn void QualAnalysis.collect(QualAnalysis* q, Node* n, int depth)
{
    if (n == null || depth > QA_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN || n.kind == Nk.N_DECL_EXTERN_FN) { q.register(n); }
    for (usz i = 0; i < n.child_count; i++) { q.collect(n.children[i], depth + 1); }
}

// ── Binder classification ───────────────────────────────────────────────
// Which parameter (position) does this binder belong to, in the current fn?
// Parameters in clause form: each clause re-binds the same positions, so
// we match by position within the clause's tuple pattern.
fn int QualAnalysis.param_index(QualAnalysis* q, Node* binder)
{
    if (binder == null || q.cur == null) { return -1; }
    for (usz i = 0; i < q.cur.n_params; i++)
    {
        Node* p = q.cur.params[i];
        if (p == binder) { return (int)i; }
        // N_DECL_PARAM wraps a pat-ident
        if (p != null && p.kind == Nk.N_DECL_PARAM)
        {
            for (usz j = 0; j < p.child_count; j++) { if (p.children[j] == binder) { return (int)i; } }
        }
    }
    // other clauses: same position in the clause pattern
    Node* pat = binder.parent;
    Node* clause = pat;
    while (clause != null && clause.kind != Nk.N_CLAUSE && clause.kind != Nk.N_DECL_FN) { clause = clause.parent; }
    if (clause == null || clause.kind != Nk.N_CLAUSE || clause.parent != q.cur.decl) { return -1; }
    Node* top = null;
    for (usz j = 0; j < clause.child_count; j++) { if (clause.children[j] != null && pfront_core::is_pattern(clause.children[j].kind)) { top = clause.children[j]; break; } }
    if (top == null) { return -1; }
    if (top == binder) { return 0; }
    if (top.kind == Nk.N_PAT_TUPLE)
    {
        for (usz j = 0; j < top.child_count; j++)
        {
            // binder is component j or nested inside it
            Node* c = top.children[j];
            Node* w = binder;
            while (w != null && w != c && w != top) { w = w.parent; }
            if (w == c) { return (int)j; }
        }
    }
    return -1;
}

fn bool is_global_binder(Node* b)
{
    if (b == null) { return false; }
    if (b.kind == Nk.N_DECL_STATIC) { return true; }
    if (b.kind == Nk.N_DECL_LET || b.kind == Nk.N_PAT_IDENT)
    {
        // module-level let: no enclosing fn
        Node* p = b.parent;
        while (p != null)
        {
            if (p.kind == Nk.N_DECL_FN || p.kind == Nk.N_EXPR_LAMBDA) { return false; }
            p = p.parent;
        }
        return true;
    }
    return false;
}

fn bool is_static_binder(Node* b)
{
    if (b == null) { return false; }
    if (b.kind == Nk.N_DECL_STATIC) { return true; }
    Node* p = b.parent;
    return p != null && p.kind == Nk.N_DECL_STATIC;
}

// base identifier of an lvalue chain: p.x[i].y → p ; *p → p (through=true)
fn Node* lvalue_base(Node* e, bool* through)
{
    *through = false;
    int guard = 0;
    while (e != null && guard < 64)
    {
        guard = guard + 1;
        switch (e.kind)
        {
            case Nk.N_EXPR_FIELD:
            case Nk.N_EXPR_INDEX:
            case Nk.N_EXPR_SLICE:
                *through = true;
                e = e.child_count > 0 ? e.children[0] : null; break;
            case Nk.N_EXPR_DEREF:
                *through = true;
                e = e.child_count > 0 ? e.children[0] : null; break;
            case Nk.N_EXPR_CAST:
            case Nk.N_EXPR_UNSAFE:
                e = e.child_count > 0 ? e.children[0] : null; break;
            default:
                return e;
        }
    }
    return e;
}

fn void QualAnalysis.add_reason(QualAnalysis* q, uint bit, Node* at)
{
    if (q.cur == null) { return; }
    if ((q.cur.reasons & bit) == 0)
    {
        q.cur.reasons = q.cur.reasons | bit;
        q.changed = true;
        int idx = 0; uint b = bit;
        while (b > 1 && idx < 8) { b = b >> 1; idx = idx + 1; }
        q.cur.why[idx] = at;
    }
}

fn void QualAnalysis.mark_written(QualAnalysis* q, int pi, Node* at)
{
    if (q.cur == null || pi < 0 || pi >= 32) { return; }
    uint bit = 1u << (uint)pi;
    if ((q.cur.written & bit) == 0)
    {
        q.cur.written = q.cur.written | bit;
        q.cur.written_at[pi] = at;
        q.changed = true;
    }
    q.add_reason(R_WRITES_PARAM, at);
}

fn void QualAnalysis.mark_escape(QualAnalysis* q, int pi)
{
    if (q.cur == null || pi < 0 || pi >= 32) { return; }
    uint bit = 1u << (uint)pi;
    if ((q.cur.escapes & bit) == 0) { q.cur.escapes = q.cur.escapes | bit; q.changed = true; }
}

// the parameter an argument expression denotes, if it is (a reference to) one
fn int QualAnalysis.arg_param(QualAnalysis* q, Node* a)
{
    if (a == null) { return -1; }
    if (a.kind == Nk.N_EXPR_REF && a.child_count > 0) { a = a.children[0]; }
    bool through = false;
    Node* base = lvalue_base(a, &through);
    if (base == null || base.kind != Nk.N_EXPR_IDENT) { return -1; }
    return q.param_index(base.resolved);
}

// ── Writes ──────────────────────────────────────────────────────────────
fn void QualAnalysis.on_write(QualAnalysis* q, Node* lhs, Node* at)
{
    bool through = false;
    Node* base = lvalue_base(lhs, &through);
    if (base == null) { q.add_reason(R_WRITES_GLOBAL, at); return; }
    if (base.kind != Nk.N_EXPR_IDENT && base.kind != Nk.N_EXPR_SELF)
    {
        // writing through a computed pointer (call result, etc.)
        q.add_reason(R_WRITES_GLOBAL, at);
        return;
    }
    Node* b = base.resolved;
    if (base.kind == Nk.N_EXPR_SELF)
    {
        // `self` is parameter 0 of a method
        q.mark_written(0, at);
        return;
    }
    if (b == null) { q.add_reason(R_WRITES_GLOBAL, at); return; }
    int pi = q.param_index(b);
    if (pi >= 0) { q.mark_written(pi, at); return; }
    if (is_global_binder(b)) { q.add_reason(R_WRITES_GLOBAL, at); return; }
    // a local: only a write THROUGH it can reach the outside world (it may
    // hold a pointer that came from a parameter or a global)
    if (through)
    {
        // if the local was initialised from a parameter (`let p = param`) we
        // cannot tell without alias analysis: be conservative only for derefs
        if (lhs.kind == Nk.N_EXPR_DEREF || q.local_holds_pointer(b)) { q.add_reason(R_WRITES_GLOBAL, at); }
    }
}

// a local whose initialiser is a pointer-producing expression
fn bool QualAnalysis.local_holds_pointer(QualAnalysis* q, Node* b)
{
    Node* let = b.parent;
    while (let != null && let.kind != Nk.N_DECL_LET && let.kind != Nk.N_DECL_FN) { let = let.parent; }
    if (let == null || let.kind != Nk.N_DECL_LET) { return false; }
    Node* init = let.child_count > 0 ? let.children[let.child_count - 1] : null;
    if (init == null) { return false; }
    switch (init.kind)
    {
        case Nk.N_EXPR_ALLOC: case Nk.N_EXPR_REF: case Nk.N_EXPR_CALL: case Nk.N_EXPR_METHOD:
        case Nk.N_EXPR_CAST: case Nk.N_EXPR_FIELD: case Nk.N_EXPR_INDEX: case Nk.N_EXPR_IDENT:
            return true;
        default:
            return false;
    }
    return false;
}

// ── Calls ───────────────────────────────────────────────────────────────
fn void QualAnalysis.on_call(QualAnalysis* q, Node* call)
{
    q.n_calls_total = q.n_calls_total + 1;
    Node* callee_decl = null;
    usz first_arg = 0;
    if (call.kind == Nk.N_EXPR_CALL)
    {
        Node* c = call.child_count > 0 ? call.children[0] : null;
        if (c != null && (c.kind == Nk.N_EXPR_IDENT || c.kind == Nk.N_EXPR_PATH)) { callee_decl = c.resolved; }
        first_arg = 1;
    }
    else
    {
        callee_decl = call.resolved;
        first_arg = 0;   // receiver is argument 0
    }
    FnQ* callee = q.lookup(callee_decl);
    if (callee == null)
    {
        // constructors / variants / struct literals are pure; anything else is unknown
        if (callee_decl != null && (callee_decl.kind == Nk.N_DECL_VARIANT || callee_decl.kind == Nk.N_DECL_STRUCT
                                    || callee_decl.kind == Nk.N_DECL_ENUM || callee_decl.kind == Nk.N_DECL_NEWTYPE))
        {
            return;
        }
        q.add_reason(R_UNKNOWN_CALL, call);
        q.n_calls_unknown = q.n_calls_unknown + 1;
        // every by-reference argument may be written and every argument escapes
        for (usz i = first_arg; i < call.child_count; i++)
        {
            Node* a = call.children[i];
            int pi = q.arg_param(a);
            if (pi < 0) { continue; }
            q.mark_escape(pi);
            if (a != null && (a.kind == Nk.N_EXPR_REF || a.kind == Nk.N_EXPR_DEREF)) { q.mark_written(pi, call); }
        }
        return;
    }
    q.n_edges = q.n_edges + 1;
    if (callee.is_extern) { q.n_calls_unknown = q.n_calls_unknown + 1; }
    if (callee == q.cur) { q.add_reason(R_RECURSIVE, call); }
    else
    {
        if ((callee.reasons & R_IMPURE_MASK) != 0) { q.add_reason(R_IMPURE_CALLEE, call); }
        if ((callee.reasons & R_READS_GLOBAL) != 0) { q.add_reason(R_READS_GLOBAL, call); }
        if ((callee.reasons & R_ALLOC) != 0) { q.add_reason(R_ALLOC, call); }
        if ((callee.reasons & R_DIVERGE_MASK) != 0) { q.add_reason(R_RECURSIVE, call); }
    }
    // argument ↔ parameter transfer
    usz pos = 0;
    for (usz i = first_arg; i < call.child_count; i++)
    {
        Node* a = call.children[i];
        int pi = q.arg_param(a);
        if (pi >= 0 && pos < 32)
        {
            uint bit = 1u << (uint)pos;
            bool by_ref = a != null && (a.kind == Nk.N_EXPR_REF);
            if ((callee.written & bit) != 0 && (by_ref || a.kind == Nk.N_EXPR_IDENT || a.kind == Nk.N_EXPR_FIELD || a.kind == Nk.N_EXPR_INDEX))
            {
                // a value parameter passed by value cannot be written by the
                // callee; only references / pointer-typed things can. Without
                // types we treat `&p` and `p` alike when the callee writes
                // THROUGH its parameter (written_at is a field/index/deref).
                Node* w = callee.written_at[pos];
                bool through = w != null && w.kind != Nk.N_STMT_ASSIGN && w.kind != Nk.N_EXPR_ASSIGN;
                if (by_ref || through || q.param_is_pointer(callee, pos)) { q.mark_written(pi, call); }
            }
            if ((callee.escapes & bit) != 0) { q.mark_escape(pi); }
        }
        pos = pos + 1;
    }
}

// parameter declared with a pointer / reference type
fn bool QualAnalysis.param_is_pointer(QualAnalysis* q, FnQ* f, usz pos)
{
    if (pos >= f.n_params) { return false; }
    Node* p = f.params[pos];
    if (p == null) { return false; }
    Node* ty = p.type_ann;
    if (ty == null && p.child_count > 0 && p.children[0] != null) { ty = p.children[0].type_ann; }
    if (ty == null) { return false; }
    return ty.kind == Nk.N_TY_PTR || ty.kind == Nk.N_TY_REF || ty.kind == Nk.N_TY_SLICE;
}

// ── Body walk ───────────────────────────────────────────────────────────
fn void QualAnalysis.scan(QualAnalysis* q, Node* n, int depth, bool in_return)
{
    if (n == null || depth > QA_MAX_DEPTH) { return; }
    switch (n.kind)
    {
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        case Nk.N_EXPR_ASSIGN:
            if (n.child_count > 0) { q.on_write(n.children[0], n); }
            for (usz i = 1; i < n.child_count; i++) { q.scan(n.children[i], depth + 1, false); }
            // the lhs sub-expressions (index expressions) are reads
            if (n.child_count > 0 && n.children[0] != null)
            {
                Node* l = n.children[0];
                for (usz i = 1; i < l.child_count; i++) { q.scan(l.children[i], depth + 1, false); }
            }
            return;
        case Nk.N_EXPR_REF:
        {
            Node* in = n.child_count > 0 ? n.children[0] : null;
            if ((n.flags & pfront_core::NF_MUT) != 0 && in != null)
            {
                bool through = false;
                Node* base = lvalue_base(in, &through);
                if (base != null && base.kind == Nk.N_EXPR_IDENT)
                {
                    int pi = q.param_index(base.resolved);
                    if (pi >= 0) { q.mark_written(pi, n); }
                    else if (is_global_binder(base.resolved)) { q.add_reason(R_WRITES_GLOBAL, n); }
                }
            }
            // taking the address of a parameter lets it escape
            if (in != null)
            {
                int pi = q.arg_param(in);
                if (pi >= 0) { q.mark_escape(pi); }
            }
            q.scan(in, depth + 1, false);
            return;
        }
        case Nk.N_EXPR_IDENT:
        {
            Node* b = n.resolved;
            if (b != null && is_static_binder(b)) { q.add_reason(R_READS_GLOBAL, n); }
            if (in_return)
            {
                int pi = q.param_index(b);
                if (pi >= 0) { q.mark_escape(pi); }
            }
            return;
        }
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
            q.on_call(n);
            for (usz i = 0; i < n.child_count; i++) { q.scan(n.children[i], depth + 1, false); }
            return;
        case Nk.N_EXPR_PERFORM: case Nk.N_EXPR_HANDLE: case Nk.N_EXPR_RESUME:
        case Nk.N_EXPR_SYSCALL: case Nk.N_EXPR_ASM: case Nk.N_EXPR_ATOMIC:
        case Nk.N_EXPR_FENCE: case Nk.N_EXPR_VOLATILE: case Nk.N_EXPR_FREE:
        case Nk.N_EXPR_TRAP: case Nk.N_EXPR_UB: case Nk.N_EXPR_POISON:
            q.add_reason(R_EFFECT, n);
            break;
        case Nk.N_EXPR_ALLOC:
            q.add_reason(R_ALLOC, n);
            break;
        case Nk.N_EXPR_WHILE: case Nk.N_EXPR_LOOP: case Nk.N_EXPR_FOR:
            q.add_reason(R_LOOP, n);
            break;
        case Nk.N_STMT_RETURN:
            for (usz i = 0; i < n.child_count; i++) { q.scan(n.children[i], depth + 1, true); }
            return;
        case Nk.N_EXPR_LAMBDA:
        {
            // a closure body runs as part of this function's effects (it
            // may be called here) — and every parameter it captures escapes
            for (usz i = 0; i < n.child_count; i++) { q.scan(n.children[i], depth + 1, false); }
            q.captures_escape(n, n, depth + 1);
            return;
        }
        case Nk.N_EXPR_STRUCT_LIT: case Nk.N_EXPR_TUPLE: case Nk.N_EXPR_ARRAY: case Nk.N_EXPR_FIELD_INIT:
        {
            // storing a parameter into an aggregate: it escapes
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                int pi = q.arg_param(c != null && c.kind == Nk.N_EXPR_FIELD_INIT && c.child_count > 0 ? c.children[c.child_count - 1] : c);
                if (pi >= 0) { q.mark_escape(pi); }
                q.scan(c, depth + 1, false);
            }
            return;
        }
        case Nk.N_DECL_LET:
        {
            // `let x = param` — the alias escapes our tracking: treat as escape
            Node* init = n.child_count > 0 ? n.children[n.child_count - 1] : null;
            int pi = q.arg_param(init);
            if (pi >= 0 && init != null && init.kind == Nk.N_EXPR_IDENT) { q.mark_escape(pi); }
            for (usz i = 0; i < n.child_count; i++) { q.scan(n.children[i], depth + 1, false); }
            return;
        }
        default:
            break;
    }
    // tail-position expressions of a function body are returned
    bool tail = in_return;
    for (usz i = 0; i < n.child_count; i++)
    {
        bool last = (i + 1 == n.child_count);
        bool child_tail = tail && last && (n.kind == Nk.N_BLOCK || n.kind == Nk.N_CLAUSE || n.kind == Nk.N_EXPR_IF || n.kind == Nk.N_MATCH_ARM || n.kind == Nk.N_EXPR_MATCH);
        if (n.kind == Nk.N_EXPR_IF && i == 0) { child_tail = false; }
        if (n.kind == Nk.N_EXPR_MATCH && i == 0) { child_tail = false; }
        q.scan(n.children[i], depth + 1, child_tail);
    }
}

fn void QualAnalysis.captures_escape(QualAnalysis* q, Node* lam, Node* n, int depth)
{
    if (n == null || depth > QA_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_IDENT)
    {
        int pi = q.param_index(n.resolved);
        if (pi >= 0) { q.mark_escape(pi); }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { q.captures_escape(lam, n.children[i], depth + 1); }
}

fn void QualAnalysis.analyse_fn(QualAnalysis* q, FnQ* f)
{
    if (f.is_extern) { return; }
    q.cur = f;
    f.n_calls = 0;
    for (usz i = 0; i < f.decl.child_count; i++)
    {
        Node* c = f.decl.children[i];
        if (c == null || c.kind == Nk.N_DECL_PARAM || c.kind == Nk.N_DECL_TYPEPARAM) { continue; }
        // a clause's body (last child) is in return position; a bare body too
        if (c.kind == Nk.N_CLAUSE)
        {
            for (usz j = 0; j < c.child_count; j++)
            {
                bool last = (j + 1 == c.child_count);
                q.scan(c.children[j], 1, last);
            }
        }
        else { q.scan(c, 1, true); }
    }
    q.cur = null;
}

// ── Fixpoint ────────────────────────────────────────────────────────────
fn void QualAnalysis.fixpoint(QualAnalysis* q)
{
    for (int round = 0; round < QA_MAX_ROUNDS; round++)
    {
        q.changed = false;
        q.n_calls_total = 0; q.n_calls_unknown = 0; q.n_edges = 0;
        for (usz i = 0; i < q.n_fns; i++) { q.analyse_fn(&q.fns[i]); }
        q.rounds = round + 1;
        if (!q.changed) { break; }
    }
}

fn Qclass classify(uint r)
{
    if ((r & R_IMPURE_MASK) != 0) { return Qclass.Q_IMPURE; }
    if ((r & R_ALLOC) != 0) { return Qclass.Q_ALLOC; }
    if ((r & R_READS_GLOBAL) != 0) { return Qclass.Q_READONLY; }
    return Qclass.Q_PURE;
}

fn char* reason_text(uint bit)
{
    switch (bit)
    {
        case R_WRITES_GLOBAL: return "writes memory outside its frame";
        case R_READS_GLOBAL:  return "reads a static";
        case R_WRITES_PARAM:  return "writes through a parameter";
        case R_EFFECT:        return "performs an effect / system operation";
        case R_ALLOC:         return "allocates";
        case R_UNKNOWN_CALL:  return "calls an extern or indirect function";
        case R_IMPURE_CALLEE: return "calls an impure function";
        case R_LOOP:          return "loops";
        case R_RECURSIVE:     return "recurses";
        default: return "?";
    }
}

// ── Verdicts, writeback, diagnostics ────────────────────────────────────
fn void QualAnalysis.verdicts(QualAnalysis* q)
{
    for (usz i = 0; i < q.n_fns; i++)
    {
        FnQ* f = &q.fns[i];
        f.cls = classify(f.reasons);
        if (f.is_extern) { f.cls = Qclass.Q_IMPURE; continue; }
        switch (f.cls)
        {
            case Qclass.Q_PURE: q.n_pure = q.n_pure + 1; break;
            case Qclass.Q_READONLY: q.n_readonly = q.n_readonly + 1; break;
            case Qclass.Q_ALLOC: q.n_alloc = q.n_alloc + 1; break;
            case Qclass.Q_IMPURE: q.n_impure = q.n_impure + 1; break;
        }
        if ((f.reasons & R_DIVERGE_MASK) != 0) { q.n_diverge = q.n_diverge + 1; }
        if (f.cls == Qclass.Q_PURE || f.cls == Qclass.Q_READONLY)
        {
            f.decl.flags = f.decl.flags | pfront_core::NF_PURE_FN;
            q.n_flag_pure = q.n_flag_pure + 1;
        }
        for (usz p = 0; p < f.n_params && p < 32; p++)
        {
            uint bit = 1u << (uint)p;
            bool w = (f.written & bit) != 0;
            bool e = (f.escapes & bit) != 0;
            if (w) { q.n_params_written = q.n_params_written + 1; }
            if (e) { q.n_params_escape = q.n_params_escape + 1; }
            Node* pn = f.params[p];
            if (pn == null) { continue; }
            if (!w && !e)
            {
                q.n_params_readonly = q.n_params_readonly + 1;
                q.flag_position(f, p);
            }
            // `mut` / `&mut` parameter never written
            bool declared_mut = (pn.flags & pfront_core::NF_MUT) != 0;
            Node* ty = pn.type_ann;
            if (ty == null && pn.child_count > 0 && pn.children[0] != null)
            {
                ty = pn.children[0].type_ann;
                if ((pn.children[0].flags & pfront_core::NF_MUT) != 0) { declared_mut = true; }
            }
            if (ty != null && (ty.kind == Nk.N_TY_REF || ty.kind == Nk.N_TY_PTR) && (ty.flags & pfront_core::NF_MUT) != 0) { declared_mut = true; }
            if (declared_mut && !w && !e && q.diags != null)
            {
                char* m = q.msgbuf();
                if (m != null)
                {
                    uint pname = pn.name_id != 0 ? pn.name_id : (pn.child_count > 0 && pn.children[0] != null ? pn.children[0].name_id : 0);
                    snprintf(m, 512, "parameter `%s` of `%s` is declared mutable but `%s` never writes to it", q.name(pname), q.name(f.name), q.name(f.name));
                    q.diags.warn(pfront_core::Phase.PH_RESOLVE, 4221, pn.line, pn.col, m, q.file);
                    q.n_w4221 = q.n_w4221 + 1;
                }
            }
            else if (!w && !e && q.diags != null && q.diags.advisories && ty != null && (ty.kind == Nk.N_TY_REF || ty.kind == Nk.N_TY_PTR))
            {
                char* m = q.msgbuf();
                if (m != null)
                {
                    uint pname = pn.name_id != 0 ? pn.name_id : (pn.child_count > 0 && pn.children[0] != null ? pn.children[0].name_id : 0);
                    snprintf(m, 512, "pointer parameter `%s` is only read and never retained: callers may pass read-only memory (noalias readonly)", q.name(pname));
                    q.diags.note(pfront_core::Phase.PH_RESOLVE, 4223, pn.line, pn.col, m, q.file);
                    q.n_n4223 = q.n_n4223 + 1;
                }
            }
        }
        if (q.diags != null && q.diags.advisories && f.cls == Qclass.Q_PURE && f.name != 0)
        {
            char* m = q.msgbuf();
            if (m != null)
            {
                snprintf(m, 512, "`%s` is pure: its result depends only on its arguments%s", q.name(f.name),
                         (f.reasons & R_DIVERGE_MASK) != 0 ? " (but it may not terminate)" : " (safe to memoise, reorder or drop when unused)");
                q.diags.note(pfront_core::Phase.PH_RESOLVE, 4222, f.decl.line, f.decl.col, m, q.file);
                q.n_n4222 = q.n_n4222 + 1;
            }
        }
    }
}

// flag every binder of parameter position `pos` (each clause binds it anew)
fn void QualAnalysis.flag_position(QualAnalysis* q, FnQ* f, usz pos)
{
    Node* pn = f.params[pos];
    if (pn != null && pn.kind == Nk.N_DECL_PARAM)
    {
        pn.flags = pn.flags | pfront_core::NF_READONLY_PARAM;
        for (usz j = 0; j < pn.child_count; j++) { if (pn.children[j] != null && pn.children[j].kind == Nk.N_PAT_IDENT) { pn.children[j].flags = pn.children[j].flags | pfront_core::NF_READONLY_PARAM; } }
        q.n_flag_param = q.n_flag_param + 1;
        return;
    }
    for (usz i = 0; i < f.decl.child_count; i++)
    {
        Node* c = f.decl.children[i];
        if (c == null || c.kind != Nk.N_CLAUSE) { continue; }
        Node* top = null;
        for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_pattern(c.children[j].kind)) { top = c.children[j]; break; } }
        if (top == null) { continue; }
        Node* comp = top;
        if (top.kind == Nk.N_PAT_TUPLE) { comp = pos < top.child_count ? top.children[pos] : null; }
        else if (pos != 0) { comp = null; }
        if (comp != null && comp.kind == Nk.N_PAT_IDENT)
        {
            comp.flags = comp.flags | pfront_core::NF_READONLY_PARAM;
            q.n_flag_param = q.n_flag_param + 1;
        }
    }
}

// W4220: statement-position calls to pure functions
fn void QualAnalysis.unused_results(QualAnalysis* q, Node* n, int depth)
{
    if (n == null || depth > QA_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_BLOCK)
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* s = n.children[i];
            if (s == null) { continue; }
            bool last = (i + 1 == n.child_count);
            Node* e = s;
            if (e.kind == Nk.N_STMT_EXPR && e.child_count > 0) { e = e.children[0]; }
            // the last expression of a block is its value unless the block is a
            // statement itself (loop body / fn body returning unit) — we only
            // flag NON-last statements, which are unambiguously discarded
            if (!last && e != null && (e.kind == Nk.N_EXPR_CALL || e.kind == Nk.N_EXPR_METHOD)) { q.check_discarded(e); }
        }
    }
    for (usz i = 0; i < n.child_count; i++) { q.unused_results(n.children[i], depth + 1); }
}

fn void QualAnalysis.check_discarded(QualAnalysis* q, Node* call)
{
    Node* decl = null;
    if (call.kind == Nk.N_EXPR_CALL)
    {
        Node* c = call.child_count > 0 ? call.children[0] : null;
        if (c != null && (c.kind == Nk.N_EXPR_IDENT || c.kind == Nk.N_EXPR_PATH)) { decl = c.resolved; }
    }
    else { decl = call.resolved; }
    FnQ* f = q.lookup(decl);
    if (f == null || f.is_extern) { return; }
    if (f.cls != Qclass.Q_PURE && f.cls != Qclass.Q_READONLY) { return; }
    if (f.returns_unit) { return; }   // a unit-returning pure fn is a no-op; the lint on the fn itself covers it
    if (q.diags == null) { return; }
    char* m = q.msgbuf();
    if (m == null) { return; }
    snprintf(m, 512, "the result of `%s` is discarded, and `%s` has no side effects: this call does nothing%s",
             q.name(f.name), q.name(f.name), (f.reasons & R_DIVERGE_MASK) != 0 ? " (except possibly not terminating)" : "");
    q.diags.warn(pfront_core::Phase.PH_RESOLVE, 4220, call.line, call.col, m, q.file);
    q.n_w4220 = q.n_w4220 + 1;
}

// ── Driver ──────────────────────────────────────────────────────────────
fn void QualAnalysis.walk(QualAnalysis* q, Node* root, int depth)
{
    (void)depth;
    if (root == null) { return; }
    q.collect(root, 0);
    q.fixpoint();
    q.verdicts();
    q.unused_results(root, 0);
    for (usz i = 0; i < q.n_fns; i++)
    {
        FnQ* f = &q.fns[i];
        if (f.cls == Qclass.Q_PURE || f.cls == Qclass.Q_READONLY) { q.n_calls_pure = q.n_calls_pure + f.n_callers; }
    }
}

fn void QualAnalysis.report(QualAnalysis* q)
{
    printf("  quals            : %d fns in %d rounds: %d pure, %d read-only, %d allocating, %d impure (%d may diverge); %d call edges, %d unknown callees\n",
           (int)q.n_fns, q.rounds, (int)q.n_pure, (int)q.n_readonly, (int)q.n_alloc, (int)q.n_impure, (int)q.n_diverge,
           (int)q.n_edges, (int)q.n_calls_unknown);
    printf("  quals-params     : %d parameters: %d read-only (flagged), %d written, %d escape; %d fns flagged pure\n",
           (int)q.n_params_total, (int)q.n_params_readonly, (int)q.n_params_written, (int)q.n_params_escape, (int)q.n_flag_pure);
    if (q.n_w4220 + q.n_w4221 > 0)
    {
        printf("  quals-hazards    : %d discarded pure results (W4220), %d never-written mutable parameters (W4221)\n", (int)q.n_w4220, (int)q.n_w4221);
    }
}
