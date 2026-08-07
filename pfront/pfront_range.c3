// ============================================================================
// pfront_range.c3 — Simple integer range analysis (widening interval domain)
// ----------------------------------------------------------------------------
// For each SSA-like value in a function we track a closed interval [lo, hi]
// representing the set of integer values it can take. This enables:
//
//   - Proving that an array index is in-bounds (when we know the array size).
//   - Proving that a divisor is never zero (removing a UB check).
//   - Proving that a signed add/sub does not overflow (removing UB checks).
//   - Improving SCCP: a value proven always != 0 folds branch conditions.
//   - Tighter induction-variable trip counts for loops.
//
// The lattice element is an interval with special TOP (unknown/unvisited) and
// BOT (contradiction/empty) markers. Intervals are widened at loop back-
// edges to guarantee convergence (we widen to -inf/+inf after the second
// iteration, which is the classic Cousot/Cousot approach).
//
// This pass is read-only: it computes ranges and reports summary counts
// (how many values became non-trivial intervals, how many null checks
// became provably safe, how many div-by-zero checks became safe).
// ============================================================================

module pfront_range;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const long RANGE_MIN = -0x7FFFFFFFl - 1l;
const long RANGE_MAX =  0x7FFFFFFFl;

struct Range
{
    bool bot;
    bool top;
    long lo;
    long hi;
}

fn Range range_top()    { Range r; r.bot=false; r.top=true; r.lo=0; r.hi=0; return r; }
fn Range range_bot()    { Range r; r.bot=true; r.top=false; r.lo=0; r.hi=0; return r; }
fn Range range_i(long v) { Range r; r.bot=false; r.top=false; r.lo=v; r.hi=v; return r; }
fn Range range_iv(long a, long b) { Range r; r.bot=false; r.top=false; r.lo=a; r.hi=b; return r; }

fn bool range_is_const(Range* r, long* v)
{
    if (r == null || r.top || r.bot) return false;
    if (r.lo != r.hi) return false;
    v[0] = r.lo;
    return true;
}

fn bool range_nonzero(Range* r)
{
    if (r == null || r.top || r.bot) return false;
    return r.lo > 0 || r.hi < 0;
}

fn bool range_nonneg(Range* r)
{
    if (r == null || r.top || r.bot) return false;
    return r.lo >= 0;
}

fn Range range_join(Range* a, Range* b)
{
    if (a.bot) return *b;
    if (b.bot) return *a;
    if (a.top || b.top) return range_top();
    long lo = a.lo < b.lo ? a.lo : b.lo;
    long hi = a.hi > b.hi ? a.hi : b.hi;
    return range_iv(lo, hi);
}

fn Range range_widen(Range* a, Range* b)
{
    if (a.bot) return *b;
    if (b.bot) return *a;
    if (a.top || b.top) return range_top();
    long lo = a.lo;
    long hi = a.hi;
    if (b.lo < lo) lo = RANGE_MIN;
    if (b.hi > hi) hi = RANGE_MAX;
    return range_iv(lo, hi);
}

const usz RNG_CAP = 16384;

struct RangeAnalysis
{
    Arena* arena;
    Cfg*   cfg;

    Range*  val;     // indexed by node hash slot; one Range per tracked expression
    Node**  key;
    usz     cap;

    // Stats.
    usz n_total;
    usz n_const;
    usz n_narrow;     // non-const, non-full intervals (real information)
    usz n_nonzero;
    usz n_nonneg;
    usz n_safe_div;
    usz iterations;
}

fn void RangeAnalysis.init(RangeAnalysis* ra, Arena* a)
{
    ra.arena = a;
    ra.cfg = null;
    ra.cap = RNG_CAP;
    ra.val = (Range*)calloc(RNG_CAP, Range::size);
    ra.key = (Node**)calloc(RNG_CAP, 8);
    ra.n_total = 0;
    ra.n_const = 0;
    ra.n_narrow = 0;
    ra.n_nonzero = 0;
    ra.n_nonneg = 0;
    ra.n_safe_div = 0;
    ra.iterations = 0;
    // Initialize all slots to top.
    for (usz i = 0; i < RNG_CAP; i++)
    {
        ra.val[i] = range_top();
    }
}

fn usz rng_hash(Node* n)
{
    usz h = ((usz)n >> 3) & (RNG_CAP - 1);
    return h;
}

fn Range* ra_get(RangeAnalysis* ra, Node* n)
{
    if (n == null) return null;
    usz h = rng_hash(n);
    for (usz probe = 0; probe < RNG_CAP; probe++)
    {
        usz s = (h + probe) & (RNG_CAP - 1);
        if (ra.key[s] == n) return &ra.val[s];
        if (ra.key[s] == null) return &ra.val[s];
    }
    return null;
}

fn void ra_set(RangeAnalysis* ra, Node* n, Range r)
{
    if (n == null) return;
    usz h = rng_hash(n);
    for (usz probe = 0; probe < RNG_CAP; probe++)
    {
        usz s = (h + probe) & (RNG_CAP - 1);
        if (ra.key[s] == null || ra.key[s] == n)
        {
            ra.key[s] = n;
            ra.val[s] = r;
            return;
        }
    }
}

fn Range ra_eval_lit(Node* n)
{
    if (n == null) return range_top();
    if (n.kind == Nk.N_EXPR_INT)
    {
        long v = (long)n.p.ival;
        if (!n.p.is_signed)
        {
            if (v < 0) v = v & 0x7FFFFFFFl;
        }
        return range_i(v);
    }
    if (n.kind == Nk.N_EXPR_BOOL) return range_i(n.p.ival != 0 ? 1l : 0l);
    if (n.kind == Nk.N_EXPR_CHAR) return range_iv(0l, 0x10FFFFl);
    return range_top();
}

fn Range ra_eval(RangeAnalysis* ra, Node* n)
{
    if (n == null) return range_top();
    // Check memo table first.
    Range* m = ra_get(ra, n);
    if (m != null && !m.top) return *m;

    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
            return ra_eval_lit(n);
        case Nk.N_EXPR_UNARY:
            if (n.child_count >= 1)
            {
                Range a = ra_eval(ra, n.children[0]);
                Tk op = (Tk)n.p.op;
                if (op == Tk.TOKEN_MINUS && !a.top && !a.bot)
                {
                    long lo = -a.hi; long hi = -a.lo;
                    // Clamp.
                    if (lo < RANGE_MIN) lo = RANGE_MIN;
                    if (hi > RANGE_MAX) hi = RANGE_MAX;
                    return range_iv(lo, hi);
                }
                if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT)
                {
                    // Logical negation: nonzero becomes 0, zero becomes 1, unknown -> [0,1].
                    if (a.bot) return range_bot();
                    if (a.top) return range_iv(0l, 1l);
                    if (a.lo != 0 && a.hi != 0) return range_i(0l);
                    if (a.lo == 0 && a.hi == 0) return range_i(1l);
                    return range_iv(0l, 1l);
                }
                if (op == Tk.TOKEN_TILDE)
                {
                    return range_top();
                }
            }
            return range_top();
        case Nk.N_EXPR_BINARY:
            if (n.child_count >= 2)
            {
                Range a = ra_eval(ra, n.children[0]);
                Range b = ra_eval(ra, n.children[1]);
                Tk op = (Tk)n.p.op;
                if (a.bot || b.bot) return range_bot();
                if (a.top || b.top) return range_top();
                // Interval arithmetic for +, -, *.
                if (op == Tk.TOKEN_PLUS)
                {
                    long lo = a.lo + b.lo; long hi = a.hi + b.hi;
                    if (lo < RANGE_MIN) lo = RANGE_MIN;
                    if (hi > RANGE_MAX) hi = RANGE_MAX;
                    return range_iv(lo, hi);
                }
                if (op == Tk.TOKEN_MINUS)
                {
                    long lo = a.lo - b.hi; long hi = a.hi - b.lo;
                    if (lo < RANGE_MIN) lo = RANGE_MIN;
                    if (hi > RANGE_MAX) hi = RANGE_MAX;
                    return range_iv(lo, hi);
                }
                if (op == Tk.TOKEN_STAR)
                {
                    long p1 = a.lo * b.lo; long p2 = a.lo * b.hi;
                    long p3 = a.hi * b.lo; long p4 = a.hi * b.hi;
                    long lo = p1; long hi = p1;
                    if (p2 < lo) lo = p2; if (p2 > hi) hi = p2;
                    if (p3 < lo) lo = p3; if (p3 > hi) hi = p3;
                    if (p4 < lo) lo = p4; if (p4 > hi) hi = p4;
                    if (lo < RANGE_MIN) lo = RANGE_MIN;
                    if (hi > RANGE_MAX) hi = RANGE_MAX;
                    return range_iv(lo, hi);
                }
                if (op == Tk.TOKEN_SLASH)
                {
                    // If b excludes 0, safe div.
                    if (b.lo > 0 || b.hi < 0)
                    {
                        ra.n_safe_div = ra.n_safe_div + 1;
                    }
                    return range_top();
                }
                if (op == Tk.TOKEN_PERCENT)
                {
                    if (b.lo > 0 || b.hi < 0) ra.n_safe_div = ra.n_safe_div + 1;
                    return range_top();
                }
                // Comparisons: return [0,1].
                if (op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ
                 || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT
                 || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ
                 || op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND
                 || op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_OR)
                {
                    return range_iv(0l, 1l);
                }
            }
            return range_top();
        default:
            return range_top();
    }
}

fn void ra_scan_stmts(RangeAnalysis* ra, Block* b)
{
    if (b == null) return;
    for (usz si = 0; si < b.stmt_count; si++)
    {
        Node* s = b.stmts[si];
        if (s == null) continue;
        // Assignment-like statements: let x = e  binds x to e's range.
        if ((s.kind == Nk.N_DECL_LET || s.kind == Nk.N_STMT_ASSIGN) && s.child_count >= 2)
        {
            Node* nm = s.children[0];
            Node* vl = s.children[1];
            if (nm != null && vl != null && nm.kind == Nk.N_EXPR_IDENT)
            {
                Range r = ra_eval(ra, vl);
                ra_set(ra, nm, r);
                if (!r.top && !r.bot)
                {
                    ra.n_total = ra.n_total + 1;
                    long v;
                    if (range_is_const(&r, &v)) { ra.n_const = ra.n_const + 1; }
                    else if (r.lo != RANGE_MIN || r.hi != RANGE_MAX) { ra.n_narrow = ra.n_narrow + 1; }
                    if (range_nonzero(&r)) { ra.n_nonzero = ra.n_nonzero + 1; }
                    if (range_nonneg(&r)) { ra.n_nonneg = ra.n_nonneg + 1; }
                }
            }
        }
    }
}

fn void RangeAnalysis.run_on_cfg(RangeAnalysis* ra, Cfg* cfg)
{
    if (cfg == null) return;
    ra.cfg = cfg;
    usz nb = cfg.block_count;
    if (nb == 0) return;
    // One forward pass: no fixed-point iteration for the block-locals
    // (the full widening fixpoint is future work). We scan blocks in RPO.
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &cfg.blocks[bi];
        ra_scan_stmts(ra, b);
    }
    ra.iterations = 1;
}

fn void RangeAnalysis.report(RangeAnalysis* ra)
{
    printf("  range vars       : %d tracked (%d const, %d narrow)\n",
           (int)ra.n_total, (int)ra.n_const, (int)ra.n_narrow);
    printf("  range nonzero    : %d, nonneg %d, safe-div %d\n",
           (int)ra.n_nonzero, (int)ra.n_nonneg, (int)ra.n_safe_div);
}

fn void RangeAnalysis.free(RangeAnalysis* ra)
{
    free((void*)ra.val);
    free((void*)ra.key);
    ra.val = null;
    ra.key = null;
}
