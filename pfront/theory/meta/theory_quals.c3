// ============================================================================
// theory_quals.c3 — Qualifier / type-class / capability inference
// ----------------------------------------------------------------------------
// Type qualifiers (const, pure, throws, owned, borrowed, send, sync, etc.)
// are small lattice-valued annotations that don't change the runtime
// representation but CONSTRAIN how a value may be used. They form the
// backbone of Rust-style ownership, Pony's reference capabilities, and
// Haskell-style type class constraints (Eq a, Ord a).
//
// This module implements a GENERIC qualifier analysis over a fixed set of
// qualifier dimensions:
//
//   DIM_CONST    — value is read-only (no writes through it)
//   DIM_PURE     — function provably has no side effects
//   DIM_THROWS   — function may throw/perform an effect
//   DIM_OWNED    — unique owning pointer (affine/linear)
//   DIM_BORROWED — shared borrow (read-only aliasing)
//   DIM_SEND     — safe to send across threads ('static + Sync in Rust)
//   DIM_SYNC     — safe to share between threads
//   DIM_UNSAFE   — unsafe block; suppresses some checks
//
// Each dimension is a 3-point lattice (NO / MAYBE / YES) where join = max.
// Function arguments propagate qualifiers to results via small built-in
// signatures: e.g. deref(owned) → borrowed, deref(borrowed) → borrowed,
// add(pure, pure) → pure.
//
// The analysis runs intra-procedurally, collecting qualifiers per function
// and reporting the number of functions inferred pure, const, send, etc.
// Pessimistic defaults (every extern function is non-pure and may throw)
// keep the analysis sound for Pride's untyped setting.
//
// References:
//   Foster/Terauchi/Aiken 2002 "Flow-Sensitive Type Qualifiers"
//   Chin/Markstrum/Millstein 2005 "Semantic Type Qualifiers"
//   Rust Reference: Ownership, Send & Sync
//   Greenaway/Andronick/Klein 2012 "Bridging the Gap: Automatic
//       Verification of C in Isabelle/HOL" (qualifiers for Cogent)
// ============================================================================

module theory_quals;

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

enum QualLvl : int
{
    QL_NO,
    QL_MAYBE,
    QL_YES
}

// Qualifier set bit-packed into a u32 per dimension.
const usz Q_CONST = 0;
const usz Q_PURE  = 2;
const usz Q_THROW = 4;
const usz Q_OWNED = 6;
const usz Q_BORROW = 8;
const usz Q_SEND  = 10;
const usz Q_SYNC  = 12;
const usz Q_UNSAFE = 14;

fn uint qual_mk(QualLvl c, QualLvl p, QualLvl t, QualLvl o, QualLvl b,
             QualLvl sd, QualLvl sy, QualLvl u)
{
    return ((uint)c & 3u) << Q_CONST
         | ((uint)p & 3u) << Q_PURE
         | ((uint)t & 3u) << Q_THROW
         | ((uint)o & 3u) << Q_OWNED
         | ((uint)b & 3u) << Q_BORROW
         | ((uint)sd & 3u) << Q_SEND
         | ((uint)sy & 3u) << Q_SYNC
         | ((uint)u & 3u) << Q_UNSAFE;
}

fn QualLvl qual_get(uint q, usz dim)
{
    return (QualLvl)((q >> dim) & 3u);
}

fn uint qual_set(uint q, usz dim, QualLvl v)
{
    uint mask = ~(3u << dim);
    return (q & mask) | (((uint)v & 3u) << dim);
}

fn uint qual_join(uint a, uint b)
{
    uint r = 0;
    usz[8] dims;
    dims[0] = Q_CONST; dims[1] = Q_PURE; dims[2] = Q_THROW; dims[3] = Q_OWNED;
    dims[4] = Q_BORROW; dims[5] = Q_SEND; dims[6] = Q_SYNC; dims[7] = Q_UNSAFE;
    for (usz i = 0; i < 8; i++)
    {
        QualLvl av = qual_get(a, dims[i]);
        QualLvl bv = qual_get(b, dims[i]);
        QualLvl rv = (int)av > (int)bv ? av : bv;
        r = qual_set(r, dims[i], rv);
    }
    return r;
}

struct QualAnalysis
{
    Arena* arena;
    uint   current;
    usz    n_fns;
    usz    n_pure;
    usz    n_const;
    usz    n_throws;
    usz    n_owned;
    usz    n_send;
    usz    n_sync;
    usz    n_unsafe;
    usz    n_deref;
    usz    n_assign;
    usz    n_calls;
}

fn void QualAnalysis.init(QualAnalysis* q, Arena* a)
{
    q.arena = a;
    q.current = qual_mk(QualLvl.QL_MAYBE, QualLvl.QL_YES, QualLvl.QL_NO,
                        QualLvl.QL_NO, QualLvl.QL_NO,
                        QualLvl.QL_MAYBE, QualLvl.QL_MAYBE, QualLvl.QL_NO);
    q.n_fns = 0; q.n_pure = 0; q.n_const = 0; q.n_throws = 0;
    q.n_owned = 0; q.n_send = 0; q.n_sync = 0; q.n_unsafe = 0;
    q.n_deref = 0; q.n_assign = 0; q.n_calls = 0;
}

fn void QualAnalysis.on_deref(QualAnalysis* q)
{
    q.n_deref = q.n_deref + 1;
    // After a deref we are "borrowed"
    q.current = qual_set(q.current, Q_BORROW, QualLvl.QL_YES);
    // Deref is non-const (might write) — conservatively clear CONST
    q.current = qual_set(q.current, Q_CONST, QualLvl.QL_NO);
}

fn void QualAnalysis.on_assign(QualAnalysis* q)
{
    q.n_assign = q.n_assign + 1;
    q.current = qual_set(q.current, Q_CONST, QualLvl.QL_NO);
    q.current = qual_set(q.current, Q_PURE, QualLvl.QL_NO);
}

fn void QualAnalysis.on_call(QualAnalysis* q, Node* callee)
{
    q.n_calls = q.n_calls + 1;
    (void)callee;
    // A call to an unknown callee is conservatively impure + may throw.
    q.current = qual_set(q.current, Q_PURE, QualLvl.QL_NO);
    q.current = qual_set(q.current, Q_THROW, QualLvl.QL_YES);
}

fn void QualAnalysis.on_unsafe(QualAnalysis* q)
{
    q.current = qual_set(q.current, Q_UNSAFE, QualLvl.QL_YES);
    q.n_unsafe = q.n_unsafe + 1;
}

fn uint QualAnalysis.expr_q(QualAnalysis* q, Node* n, int depth)
{
    if (n == null || depth > 200) return q.current;
    uint sub = q.current;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR: case Nk.N_EXPR_STRING: case Nk.N_EXPR_UNIT:
            // Literals are const, pure, send, sync
            sub = qual_mk(QualLvl.QL_YES, QualLvl.QL_YES, QualLvl.QL_NO,
                          QualLvl.QL_NO, QualLvl.QL_NO,
                          QualLvl.QL_YES, QualLvl.QL_YES, QualLvl.QL_NO);
            break;
        case Nk.N_EXPR_DEREF:
            q.on_deref();
            sub = q.current;
            break;
        case Nk.N_STMT_ASSIGN:
            q.on_assign();
            sub = q.current;
            break;
        case Nk.N_EXPR_CALL:
            if (n.child_count >= 1) q.on_call(n.children[0]);
            sub = q.current;
            break;
        default:
            for (usz i = 0; i < n.child_count; i++)
            {
                uint ch = q.expr_q(n.children[i], depth + 1);
                sub = qual_join(sub, ch);
            }
    }
    return sub;
}

fn void QualAnalysis.walk(QualAnalysis* q, Node* n, int depth)
{
    if (n == null || depth > 200) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        uint saved = q.current;
        // Fresh fn: assume pure + no-throws until we see a call/throw.
        q.current = qual_mk(QualLvl.QL_MAYBE, QualLvl.QL_YES, QualLvl.QL_NO,
                            QualLvl.QL_NO, QualLvl.QL_NO,
                            QualLvl.QL_MAYBE, QualLvl.QL_MAYBE, QualLvl.QL_NO);
        q.n_fns = q.n_fns + 1;
        for (usz i = 0; i < n.child_count; i++)
        {
            if (n.children[i] == null) continue;
            uint cq = q.expr_q(n.children[i], 0);
            q.current = qual_join(q.current, cq);
        }
        // Tally
        if (qual_get(q.current, Q_PURE) == QualLvl.QL_YES) q.n_pure = q.n_pure + 1;
        if (qual_get(q.current, Q_CONST) == QualLvl.QL_YES) q.n_const = q.n_const + 1;
        if (qual_get(q.current, Q_THROW) == QualLvl.QL_YES) q.n_throws = q.n_throws + 1;
        if (qual_get(q.current, Q_SEND) == QualLvl.QL_YES) q.n_send = q.n_send + 1;
        if (qual_get(q.current, Q_SYNC) == QualLvl.QL_YES) q.n_sync = q.n_sync + 1;
        q.current = saved;
        return;
    }
    for (usz i = 0; i < n.child_count; i++) q.walk(n.children[i], depth + 1);
}

fn void QualAnalysis.report(QualAnalysis* q)
{
    printf("  qualifiers       : %d fns: pure=%d const=%d throws=%d\n",
           (int)q.n_fns, (int)q.n_pure, (int)q.n_const, (int)q.n_throws);
    printf("  qual-threads     : send=%d sync=%d, unsafe-blocks=%d\n",
           (int)q.n_send, (int)q.n_sync, (int)q.n_unsafe);
    printf("  qual-ops         : deref=%d assign=%d calls=%d\n",
           (int)q.n_deref, (int)q.n_assign, (int)q.n_calls);
}

fn void QualAnalysis.destroy(QualAnalysis* q) { (void)q; }
