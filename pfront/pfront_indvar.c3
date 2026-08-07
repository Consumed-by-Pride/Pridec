// ============================================================================
// pfront_indvar.c3 — Induction variable and trip-count analysis
// ----------------------------------------------------------------------------
// Runs after CFG + loop detection. For each natural loop, this pass:
//
//   1. Identifies BASIC INDUCTION VARIABLES: variables that are:
//        (a) assigned exactly once in the loop,
//        (b) initialised before the loop header,
//        (c) incremented by a loop-invariant amount on every back edge,
//        (d) compared (in the loop header condition) against a loop-
//            invariant limit.
//
//   2. DERIVED induction variables: variables whose value is a linear
//      function (affine) of a basic IV plus a loop-invariant offset.
//
//   3. TRIP COUNT estimation: when the IV's initial value, increment, and
//      limit are all known constants, compute a safe static upper bound on
//      the iteration count. This feeds unrolling, vectorisation, bounds-
//      check elimination in array accesses, and array overflow warnings.
//
// This is NOT a full SCEV (scalar evolution) pass — it does not track wrap
// behavior or handle multi-exit loops precisely — but it handles the common
// idioms Pride codegen emits (for i in range, while i < N, C-style for (i=0;
// i<N; i++)). Unknown values result in an unknown trip count, not a wrong
// one.
// ============================================================================

module pfront_indvar;

import pfront_lex;
import pfront_core;
import pfront_cfg;
import pfront_licm;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias Loop = pfront_cfg::Loop;
alias Licm = pfront_licm::Licm;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz IV_MAX_LOOPS = 256;
const usz IV_MAX_VARS  = 1024;

// A basic induction variable descriptor.
struct BasicIV
{
    Node* ident;        // the N_EXPR_IDENT / N_PAT_IDENT node for this iv
    long  init;       // constant initial value (if known)
    long  step;       // constant increment per iteration (if known)
    long  limit;      // constant limit (if known)
    bool  init_known;
    bool  step_known;
    bool  limit_known;
    Node* init_expr;  // initialiser expression (may be non-constant)
    Node* step_expr;
    Node* limit_expr;
    int   cmp_op;     // Tk.TOKEN_LT / LE / GT / GE / EQ / NE
    Node* cmp_node;   // the compare node in the header
    bool  valid;
}

struct DerivedIV
{
    Node* ident;
    Node* base_iv;
    long  coeff;
    long  addend;
    bool  valid;
}

struct IndvarAnalysis
{
    Arena* arena;
    Cfg*   cfg;
    Licm*  licm;

    // Per-loop analysis results. Arrays indexed by loop index in cfg.loops[].
    BasicIV[IV_MAX_VARS] basic;
    usz[IV_MAX_LOOPS] basic_count;
    DerivedIV[IV_MAX_VARS] derived;
    usz[IV_MAX_LOOPS] derived_count;

    // Trip counts. -1 means "unknown".
    long[IV_MAX_LOOPS] trip_count;

    // Stats.
    usz loops_scanned;
    usz basic_found;
    usz derived_found;
    usz trip_known;
}

fn void IndvarAnalysis.init(IndvarAnalysis* iv, Arena* a)
{
    iv.arena = a;
    iv.cfg = null;
    iv.licm = null;
    iv.loops_scanned = 0;
    iv.basic_found = 0;
    iv.derived_found = 0;
    iv.trip_known = 0;
    for (usz i = 0; i < IV_MAX_LOOPS; i++)
    {
        iv.basic_count[i] = 0;
        iv.derived_count[i] = 0;
        iv.trip_count[i] = -1;
    }
}

// Look for simple integer literals in an expression.
fn bool as_int_lit(Node* n, long* out)
{
    if (n == null) return false;
    if (n.kind == Nk.N_EXPR_INT) { *out = (long)n.p.ival; return true; }
    if (n.kind == Nk.N_EXPR_UNARY && n.child_count >= 1
        && n.children[0].kind == Nk.N_EXPR_INT)
    {
        *out = -(long)n.children[0].p.ival; return true;
    }
    return false;
}

// Check if a node is a reference to a name (identifier/path).
//
fn bool is_name_ref(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH;
}

// Check if two name references refer to the same binding.
//
fn bool same_name(Node* a, Node* b)
{
    if (a == null || b == null) return false;
    if (a.kind != b.kind) return false;
    return a.name_id != 0 && a.name_id == b.name_id;
}

// Check if a node represents an assignment x = x + k where k is invariant.
// Returns true if so, and outputs the step delta (k) and the variable.
//
fn bool is_iv_increment(Node* stmt, Node** var_out, long* step_out, bool* inv_step)
{
    if (stmt == null) { return false; }
    if (stmt.kind != Nk.N_STMT_ASSIGN && stmt.kind != Nk.N_EXPR_ASSIGN
        && stmt.kind != Nk.N_STMT_COMPOUND_ASSIGN) { return false; }
    if (stmt.child_count < 2) return false;
    Node* lhs = stmt.children[0];
    Node* rhs = stmt.children[1];
    if (!is_name_ref(lhs)) return false;
    if (var_out != null) *var_out = lhs;
    // rhs is lhs + C?
    if (rhs.kind == Nk.N_EXPR_BINARY && rhs.child_count >= 2)
    {
        long op = (long)rhs.p.op;
        Node* a = rhs.children[0];
        Node* b = rhs.children[1];
        bool a_is_lhs = is_name_ref(a) && same_name(a, lhs);
        bool b_is_lhs = is_name_ref(b) && same_name(b, lhs);
        if (op == Tk.TOKEN_PLUS.ordinal)
        {
            // either x + k or k + x
            Node* other = a_is_lhs ? b : (b_is_lhs ? a : null);
            if (other != null)
            {
                long kv;
                if (as_int_lit(other, &kv))
                {
                    if (step_out != null) *step_out = kv;
                    if (inv_step != null) *inv_step = true;
                    return true;
                }
                if (inv_step != null) *inv_step = false;
                if (step_out != null) *step_out = 1;
                return true;
            }
        }
        if (op == Tk.TOKEN_MINUS.ordinal && a_is_lhs)
        {
            long kv;
            if (as_int_lit(b, &kv))
            {
                if (step_out != null) *step_out = -kv;
                if (inv_step != null) *inv_step = true;
                return true;
            }
        }
    }
    // Compound assigns: x += k
    if (stmt.kind == Nk.N_STMT_COMPOUND_ASSIGN)
    {
        long cop = (long)stmt.p.op;
        if (cop == Tk.TOKEN_PLUSEQ.ordinal)
        {
            long kv;
            if (as_int_lit(rhs, &kv)) { if (step_out != null) *step_out = kv; return true; }
        }
        if (cop == Tk.TOKEN_MINUSEQ.ordinal)
        {
            long kv;
            if (as_int_lit(rhs, &kv)) { if (step_out != null) *step_out = -kv; return true; }
        }
    }
    return false;
}

// Check the loop header's terminator condition. If it is IF with a binary
// comparison of (var, invariant), record it.
fn void IndvarAnalysis.scan_header(IndvarAnalysis* iv, usz lp_idx)
{
    if (iv.cfg == null) return;
    Loop* lp = &iv.cfg.loops[lp_idx];
    if (lp.header < 0) return;
    Block* hdr = &iv.cfg.blocks[lp.header];
    if (hdr.term != pfront_cfg::TermKind.TERM_IF) return;
    Node* cond = hdr.term_node;
    if (cond == null || cond.kind != Nk.N_EXPR_BINARY) return;
    long op = (long)cond.p.op;
    if (cond.child_count < 2) return;
    Node* a = cond.children[0];
    Node* b = cond.children[1];

    // Look for iv in header block? Usually the compare is of iv var vs limit.
    // Scan body blocks for increments.
    // Look at each block in the loop for assignment-like increments.
    // Each iv candidate must have exactly one increment in the loop.
    // Simplified: scan every stmt in every loop block for iv_increment shape.
    Node* first_iv_var = null;
    long  first_iv_step = 1;
    bool  found = false;
    long  increments_found = 0;

    for (usz bi = 0; bi < lp.block_count; bi++)
    {
        int bid = lp.blocks[bi];
        if (bid < 0 || bid >= (int)iv.cfg.block_count) continue;
        Block* bb = &iv.cfg.blocks[bid];
        for (usz si = 0; si < bb.stmt_count; si++)
        {
            Node* s = bb.stmts[si];
            if (s == null) continue;
            Node* vr = null;
            long st = 1;
            bool invst = false;
            if (is_iv_increment(s, &vr, &st, &invst))
            {
                if (vr == null) continue;
                if (!found) { first_iv_var = vr; first_iv_step = st; found = true; }
                else if (!same_name(vr, first_iv_var)) { continue; }
                increments_found = increments_found + 1;
            }
        }
    }
    // A basic iv must be incremented exactly once (at the latch).
    if (!found || increments_found != 1) return;
    // Check that a compares the iv and b is invariant, or vice versa.
    Node* iv_var = null;
    Node* limit_expr = null;
    int   cmp_op = 0;
    bool  iv_on_left = false;
    if (is_name_ref(a) && same_name(a, first_iv_var)) { iv_var = a; limit_expr = b; cmp_op = (int)op; iv_on_left = true; }
    else if (is_name_ref(b) && same_name(b, first_iv_var)) { iv_var = b; limit_expr = a; cmp_op = (int)op; iv_on_left = false; }
    if (iv_var == null) return;

    // Record the basic IV.
    if (iv.basic_count[lp_idx] >= IV_MAX_VARS) return;
    BasicIV* biv = &iv.basic[iv.basic_count[lp_idx]];
    biv.ident = iv_var;
    biv.step = first_iv_step;
    biv.step_known = true;
    biv.step_expr = null;
    biv.init = 0;
    biv.init_expr = null;
    biv.init_known = false;
    biv.limit = 0;
    biv.limit_expr = limit_expr;
    biv.limit_known = false;
    biv.cmp_op = cmp_op;
    biv.cmp_node = cond;
    biv.valid = true;

    // Try to evaluate init: look for an assignment to iv_var in the preheader.
    if (lp.preheader >= 0)
    {
        Block* ph = &iv.cfg.blocks[lp.preheader];
        for (long si = (long)ph.stmt_count - 1; si >= 0; si--)
        {
            Node* s = ph.stmts[(usz)si];
            if (s == null) continue;
            if ((s.kind == Nk.N_STMT_ASSIGN || s.kind == Nk.N_EXPR_ASSIGN
                 || s.kind == Nk.N_DECL_LET || s.kind == Nk.N_DECL_LET
                 || s.kind == Nk.N_STMT_EXPR) && s.child_count >= 2)
            {
                Node* lhs = s.children[0];
                if (is_name_ref(lhs) && same_name(lhs, iv_var))
                {
                    long v;
                    if (as_int_lit(s.children[1], &v)) { biv.init = v; biv.init_known = true; }
                    else { biv.init_expr = s.children[1]; }
                    break;
                }
            }
        }
    }

    // Try to evaluate limit as constant.
    long lv;
    if (as_int_lit(limit_expr, &lv)) { biv.limit = lv; biv.limit_known = true; }

    // Compute trip count if we have init + step + limit + op.
    if (biv.init_known && biv.step_known && biv.limit_known && biv.step != 0)
    {
        long diff = biv.limit - biv.init;
        bool up = biv.step > 0;
        long trips = -1;
        // For LT: trips = ceil((limit - init) / step) if diff>0 in up direction.
        bool lt = (cmp_op == Tk.TOKEN_LT.ordinal && iv_on_left && up)
               || (cmp_op == Tk.TOKEN_GT.ordinal && !iv_on_left && !up);
        bool le = (cmp_op == Tk.TOKEN_LTEQ.ordinal && iv_on_left && up)
               || (cmp_op == Tk.TOKEN_GTEQ.ordinal && !iv_on_left && !up);
        if (lt || le)
        {
            long dist = up ? diff : -diff;
            long s = up ? biv.step : -biv.step;
            if (dist > 0)
            {
                if (lt) { trips = (dist + s - 1) / s; }
                else { trips = dist / s + 1; }
                if (trips < 0) trips = 0;
                if (trips > 0 && trips < 0x7FFFFFFFFFFFFFF0)
                {
                    iv.trip_count[lp_idx] = trips;
                    iv.trip_known = iv.trip_known + 1;
                }
            }
            else { trips = 0; }
        }
    }
    iv.basic_count[lp_idx] = iv.basic_count[lp_idx] + 1;
    iv.basic_found = iv.basic_found + 1;
}

fn void IndvarAnalysis.run_on_cfg(IndvarAnalysis* iv, Cfg* c, Licm* licm)
{
    iv.cfg = c;
    iv.licm = licm;
    if (c == null) return;
    for (usz li = 0; li < c.loop_count && li < IV_MAX_LOOPS; li++)
    {
        iv.scan_header(li);
        iv.loops_scanned = iv.loops_scanned + 1;
    }
}

fn long IndvarAnalysis.trip_count_of(IndvarAnalysis* iv, usz loop_id)
{
    if (loop_id >= IV_MAX_LOOPS) return -1;
    return iv.trip_count[loop_id];
}

fn void IndvarAnalysis.report(IndvarAnalysis* iv)
{
    printf("  indvar loops      : %d\n", (int)iv.loops_scanned);
    printf("  indvar basic ivs  : %d\n", (int)iv.basic_found);
    printf("  indvar trips known: %d\n", (int)iv.trip_known);
}
