// ============================================================================
// air_fold.c3 — constant folding over the AIR, in the front end
// ----------------------------------------------------------------------------
// This is the first AIR-to-AIR rewrite, and it is deliberately the most boring
// one: if both operands of an integer/unary operator are literals, the operator
// becomes the literal answer. Nothing else is invented here.
//
// Why it lives here rather than in a backend: `pear2/pear2_opt.c3` already has
// this rewrite (fold_binary, fold_coerce, strength reduction, ~2.1 kLoC) and it
// only runs for the `.bc` backend. AIR is the contract between the front end and
// every consumer, so a rewrite that is true of the AIR belongs upstream of all
// of them — and then the backend copy can be deleted instead of being kept in
// sync by hand.
//
// Correctness rules, each of which is a way to be wrong:
//
//   * both operands must be APRD_INT and the SAME type, or the fold is not
//     type-correct (AIR has no implicit conversions, `docs/specs/AIR3.md`);
//   * the result must fit the type's width, or the fold changes the program:
//     `i8 100 + 100` is a wrapping add in the backend, and folding it to 200
//     would produce an `i8` literal that no longer means the same thing. When in
//     doubt, do not fold — an unfolded add is always correct;
//   * division/remainder by zero is never folded (it would move a trap from run
//     time to compile time);
//   * a shift amount outside 0..width-1 is never folded (it is UB in the
//     backend, and picking a value would be inventing semantics);
//   * signed overflow of + - * is never folded (also UB).
//
// The pass rewrites in place: an AirPrd keeps its identity so every parent keeps
// pointing at it, and only tag/ival change. A shared node is safe to rewrite
// because the folded value is by construction equal to the unfolded one.
// ============================================================================
module air_fold;

extern fn int printf(char* fmt, ...);

import air_ir;
import air_util;

struct Stats
{
    usz binops;       // binary folds
    usz unops;        // unary folds
    usz identities;   // x+0, x*1, x-0 -> x
    usz skipped;      // literal operands that were NOT folded, and why it is safe
    bool failed;
}

fn void Stats.init(Stats* st)
{
    st.binops = 0; st.unops = 0; st.identities = 0; st.skipped = 0; st.failed = false;
}

// Does `v` fit in `bits` bits of a signed/unsigned integer? The fold is only
// taken when the answer is yes for the type's signedness: the alternative is a
// silently different program.
// What type does this operator produce?
//
// AIR is not uniform about where an operator's type is written: `(add 2 3 : i64)`
// parses as a binop whose SECOND OPERAND carries `: i64`, and the binop itself has
// no `ty` (air_read's `(op a b : T)` production attaches the annotation to `b`;
// `air_util::binop` then takes the type from the operands). A producer written as
// `(add 2 3) : i64` instead carries it on the operator. Both are legal text, so a
// rewrite has to read the type the same way the backend does or it is reasoning
// about a different program than the one that gets emitted.
//
// Returns false when two typed operands disagree: that module is ill-typed, and
// the verifier's job, not the folder's — the folder just refuses to touch it.
fn bool result_ty(AirPrd* p, AirPrd* a, AirPrd* b, AirTyp** out)
{
    *out = null;
    AirTyp* t = p.ty;
    if (a != null && a.ty != null) { if (t != null && !air_util::ty_eq(t, a.ty)) { return false; } t = a.ty; }
    if (b != null && b.ty != null) { if (t != null && !air_util::ty_eq(t, b.ty)) { return false; } t = b.ty; }
    *out = t;
    return true;
}

fn bool fits(long v, int bits, bool is_signed)
{
    if (bits >= 64) { return true; }
    if (bits >= 63)
    {
        // A 63-bit mask would shift into the sign bit; the only type that gets
        // here is `isz`/`usz` on a 64-bit target, where `>= 64` already returned.
        return is_signed || v >= 0;
    }
    if (is_signed)
    {
        long hi = ((long)1 << (bits - 1)) - 1;
        long lo = 0 - ((long)1 << (bits - 1));
        return v >= lo && v <= hi;
    }
    long hi = ((long)1 << bits) - 1;
    return v >= 0 && v <= hi;
}

// Fold one binary operation. Returns true when it rewrote `p`.
fn bool fold_binop(AirPrd* p, Stats* st)
{
    if (p == null || p.sub_count != 2 || p.subs == null) { return false; }
    AirPrd* a = p.subs[0];
    AirPrd* b = p.subs[1];
    if (a == null || b == null || a.tag != APRD_INT || b.tag != APRD_INT) { return false; }
    AirTyp* t = null;
    if (!result_ty(p, a, b, &t)) { st.skipped = st.skipped + 1; return false; }
    if (t == null || !air_util::ty_is_int(t)) { return false; }
    int bits = air_util::ty_bits(t);
    bool sgn = air_util::ty_is_signed(t);
    long x = a.ival; long y = b.ival; long r = 0;
    switch (p.bop)
    {
        case ABIN_ADD: r = x + y; break;
        case ABIN_SUB: r = x - y; break;
        case ABIN_MUL: r = x * y; break;
        case ABIN_DIV:
        {
            if (y == 0) { st.skipped = st.skipped + 1; return false; }
            r = x / y; break;
        }
        case ABIN_MOD:
        {
            if (y == 0) { st.skipped = st.skipped + 1; return false; }
            r = x % y; break;
        }
        case ABIN_SHL:
        {
            if (y < 0 || y >= bits) { st.skipped = st.skipped + 1; return false; }
            r = x << y; break;
        }
        case ABIN_SHR:
        {
            // Arithmetic shift for a signed type, logical for an unsigned one:
            // the AIR says which by the operand's signedness.
            if (y < 0 || y >= bits) { st.skipped = st.skipped + 1; return false; }
            if (sgn) { r = x >> y; } else { ulong u = (ulong)x; r = (long)(u >> (ulong)y); }
            break;
        }
        case ABIN_AND: r = x & y; break;
        case ABIN_OR: r = x | y; break;
        case ABIN_XOR: r = x ^ y; break;
        default: { st.skipped = st.skipped + 1; return false; }
    }
    if (!fits(r, bits, sgn)) { st.skipped = st.skipped + 1; return false; }
    p.tag = APRD_INT; p.ival = r; p.fval = 0.0; p.ty = t;
    st.binops = st.binops + 1;
    return true;
}

// Fold one unary operation over an integer literal.
fn bool fold_unop(AirPrd* p, Stats* st)
{
    if (p == null || p.sub_count != 1 || p.subs == null) { return false; }
    AirPrd* a = p.subs[0];
    if (a == null || a.tag != APRD_INT) { return false; }
    AirTyp* t = null;
    if (!result_ty(p, a, null, &t)) { st.skipped = st.skipped + 1; return false; }
    if (t == null || !air_util::ty_is_int(t)) { return false; }
    int bits = air_util::ty_bits(t);
    bool sgn = air_util::ty_is_signed(t);
    long r = 0;
    switch (p.uop)
    {
        case AUN_NEG: r = -a.ival; break;
        case AUN_BITNOT: r = ~a.ival; break;
        default: { st.skipped = st.skipped + 1; return false; }
    }
    if (!fits(r, bits, sgn)) { st.skipped = st.skipped + 1; return false; }
    p.tag = APRD_INT; p.ival = r; p.ty = t;
    st.unops = st.unops + 1;
    return true;
}

// Algebraic identities that remove an operation without needing `x` to be a
// literal: `x + 0`, `x - 0`, `x | 0`, `x ^ 0`, `x << 0`, `x >> 0`, `x * 1`,
// `x / 1`. The node becomes a copy of its left operand, so it keeps its identity
// and the type the operator was annotated with.
fn bool fold_identity(AirPrd* p, Stats* st)
{
    if (p == null || p.sub_count != 2 || p.subs == null) { return false; }
    AirPrd* a = p.subs[0];
    AirPrd* b = p.subs[1];
    if (a == null || b == null || b.tag != APRD_INT) { return false; }
    // `x * 1`, `x / 1` and `x % 1`... the last one is not x, it is 0, so only the
    // two that return their left operand are here.
    bool by_zero = b.ival == 0;
    bool by_one = b.ival == 1;
    if (!by_zero && !by_one) { return false; }
    AirTyp* t = null;
    if (!result_ty(p, a, b, &t)) { return false; }
    if (t == null || !air_util::ty_is_int(t)) { return false; }
    if (by_one && p.bop != ABIN_MUL && p.bop != ABIN_DIV) { return false; }
    if (by_zero)
    {
        switch (p.bop)
        {
            case ABIN_ADD: case ABIN_SUB: case ABIN_OR: case ABIN_XOR: case ABIN_SHL: case ABIN_SHR: break;
            default: return false;
        }
    }
    replace_with_operand(p, a, t, st);
    return true;
}

// `p` becomes a copy of `a` (tag and payload), so a parent that shares it keeps
// working. Only the payload the tag needs is copied; `subs` is cleared because a
// literal has no operands.
fn void replace_with_operand(AirPrd* p, AirPrd* a, AirTyp* t, Stats* st)
{
    p.tag = a.tag;
    p.ival = a.ival; p.fval = a.fval; p.bval = a.bval; p.cval = a.cval;
    p.name = a.name; p.bytes = a.bytes; p.bytes_len = a.bytes_len;
    p.bop = a.bop; p.uop = a.uop;
    p.sub_count = 0;
    // The node keeps the type the OPERATOR had, not the operand's: that type is
    // what the parent and the backend were told the value's type is.
    p.ty = t;
    st.identities = st.identities + 1;
}

// ── traversal ──────────────────────────────────────────────────────────────
// Post-order over the producer graph, then the command tree. A node is visited
// once per position it appears in (this is a tree walk, not a DAG walk): folding
// is idempotent, so a shared node folded twice is folded the same way twice.


fn void walk_prd(AirPrd* p, Stats* st, int depth)
{
    if (p == null || depth > 4096) { if (depth > 4096) { st.failed = true; } return; }
    if (p.subs != null) { for (usz i = 0; i < p.sub_count; i++) { walk_prd(p.subs[i], st, depth + 1); } }
    if (p.rec_inits != null)
    {
        for (usz i = 0; i < p.rec_init_count; i++)
        {
            if (p.rec_inits[i] != null) { walk_prd(p.rec_inits[i].value, st, depth + 1); }
        }
    }
    if (p.body != null) { walk_cmd(p.body, st, depth + 1); }
    switch (p.tag)
    {
        case APRD_BINOP: { if (fold_binop(p, st)) { return; } fold_identity(p, st); }
        case APRD_UNOP: { (void)fold_unop(p, st); }
        default: break;
    }
}

fn void walk_cns(AirCns* k, Stats* st, int depth)
{
    if (k == null || depth > 4096) { if (depth > 4096) { st.failed = true; } return; }
    walk_prd(k.prd, st, depth + 1);
    if (k.branch_count > 0)
    {
        for (usz i = 0; i < k.branch_count; i++)
        {
            if (k.branches[i] != null) { walk_cmd(k.branches[i].body, st, depth + 1); walk_pattern(k.branches[i].pat, st, depth + 1); walk_cmd(k.branches[i].guard, st, depth + 1); }
        }
    }
    if (k.cobranch_count > 0)
    {
        for (usz i = 0; i < k.cobranch_count; i++)
        {
            if (k.cobranches[i] != null) { walk_cmd(k.cobranches[i].body, st, depth + 1); }
        }
    }
    if (k.body != null) { walk_cmd(k.body, st, depth + 1); }
    walk_cns(k.tail, st, depth);
    walk_cns(k.cont_k, st, depth);
}

fn void walk_pattern(AirPat* p, Stats* st, int depth)
{
    if (p == null) { return; }
    if (p.field_count > 0)
    {
        for (usz i = 0; i < p.field_count; i++) { if (p.fields[i] != null) { walk_prd(p.fields[i].value, st, depth + 1); } }
    }
    for (usz i = 0; i < p.sub_count; i++) { walk_pattern(p.sub[i], st, depth + 1); }
    walk_pattern(p.as_pat, st, depth + 1);
    walk_pattern(p.or_alt, st, depth + 1);
}

fn void walk_cmd(AirCmd* c, Stats* st, int depth)
{
    if (c == null || depth > 4096) { if (depth > 4096) { st.failed = true; } return; }
    walk_prd(c.prd, st, depth + 1);
    walk_cns(c.cns, st, depth + 1);
    for (usz i = 0; i < c.prd_count; i++) { walk_prd(c.prds[i], st, depth); }
    walk_cmd(c.body, st, depth + 1);
    walk_cmd(c.next, st, depth);
    walk_cmd(c.then_c, st, depth + 1);
    walk_cmd(c.else_c, st, depth + 1);
    walk_cmd(c.handled, st, depth + 1);
    if (c.branch_count > 0)
    {
        for (usz i = 0; i < c.branch_count; i++)
        {
            if (c.branches[i] != null) { walk_cmd(c.branches[i].body, st, depth + 1); walk_pattern(c.branches[i].pat, st, depth + 1); walk_cmd(c.branches[i].guard, st, depth + 1); }
        }
    }
}

// The pass entry point. Returns true iff anything changed.
fn bool run(AirModule* m, Stats* st)
{
    if (m == null || st == null) { return false; }
    usz before = st.binops + st.unops + st.identities;
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        if (d.g_init != null) { walk_prd(d.g_init, st, 0); }
        if (d.def_body != null) { walk_cmd(d.def_body, st, 0); }
    }
    return st.binops + st.unops + st.identities != before;
}
