// ============================================================================
// pfront_scev.c3 — Scalar Evolution: chains of recurrences for loop variables
// ----------------------------------------------------------------------------
// Scalar Evolution (SCEV) is the classic LLVM analysis that represents every
// scalar in a loop as a CHAIN OF RECURRENCES expression:
//
//   {start, +, step}            -- basic induction variable, starts at `start`
//                                  and adds `step` each iteration.
//   {start, *, factor}          -- geometric IV (x *= factor each iter).
//   {base, +, step}_loop       -- addrec nested inside a loop.
//   {base, *, factor}_loop     -- multrec.
//
// With SCEV we can:
//
//   * Prove two IVs are equal/different (trip counts, dependence analysis).
//   * Determine the final value of a variable after a known-trip loop.
//   * Prove an IV is strictly increasing/decreasing (no overflow assumed
//     in Pride -- untyped, we just report the pattern).
//   * Feed the existing indvar pass tighter trip counts.
//   * Drive strength reduction: array accesses through linear IVs become
//     simple pointer increments.
//
// This is the initial structural analysis: it walks the CFG, identifies
// basic induction variables of the form `x = x + k` inside natural loops
// (the pattern indvar already looks for), and tags them as AddRecs with
// start/step/loop trip count. It does not yet handle nested addrecs or
// multivariate chains.
// ============================================================================

module pfront_scev;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;
alias Loop  = pfront_cfg::Loop;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

// SCEV tag: what kind of recurrence.
const usz SCEV_CONST   = 0;
const usz SCEV_UNKNOWN = 1;
const usz SCEV_ADDREC  = 2;
const usz SCEV_MULREC  = 3;
const usz SCEV_ADD     = 4;
const usz SCEV_MUL     = 5;
const usz SCEV_CAST    = 6;

const usz SCEV_CAP = 4096;

struct Scev
{
    usz tag;
    long  c;             // for SCEV_CONST
    long  start;         // for addrec
    long  step;          // for addrec
    int   loop;          // loop id, -1 if top-level
    usz   a;             // operand 1 index (for add/mul/cast)
    usz   b;             // operand 2 index (for add/mul)
    Node* expr;          // originating expr
}

struct ScevAnalysis
{
    Arena* arena;
    Cfg*   cfg;

    Scev*  nodes;
    usz    n_count;
    usz    n_cap;

    // Map name_id -> scev index (for current block/loop).
    int*   name_map;
    usz    name_map_cap;

    usz    n_const;
    usz    n_addrec;
    usz    n_unknown;
    usz    n_add;
    usz    loops_analyzed;
    usz    ivs_found;
}

fn void ScevAnalysis.init(ScevAnalysis* sa, Arena* a)
{
    sa.arena = a;
    sa.cfg = null;
    sa.n_cap = SCEV_CAP;
    sa.nodes = (Scev*)calloc(SCEV_CAP, Scev::size);
    sa.n_count = 0;
    sa.name_map_cap = 4096;
    sa.name_map = (int*)malloc(4096 * 4);
    for (usz i = 0; i < 4096; i++) sa.name_map[i] = -1;
    sa.n_const = 0;
    sa.n_addrec = 0;
    sa.n_unknown = 0;
    sa.n_add = 0;
    sa.loops_analyzed = 0;
    sa.ivs_found = 0;
}

fn usz sa_new(ScevAnalysis* sa, usz tag)
{
    if (sa.n_count >= sa.n_cap) return 0;
    usz i = sa.n_count;
    sa.n_count = i + 1;
    sa.nodes[i].tag = tag;
    sa.nodes[i].c = 0;
    sa.nodes[i].start = 0;
    sa.nodes[i].step = 0;
    sa.nodes[i].loop = -1;
    sa.nodes[i].a = 0;
    sa.nodes[i].b = 0;
    sa.nodes[i].expr = null;
    return i;
}

fn usz sa_const(ScevAnalysis* sa, long v)
{
    usz i = sa_new(sa, SCEV_CONST);
    sa.nodes[i].c = v;
    sa.n_const++;
    return i;
}

fn usz sa_unknown(ScevAnalysis* sa)
{
    usz i = sa_new(sa, SCEV_UNKNOWN);
    sa.n_unknown++;
    return i;
}

fn bool node_is_int_lit(Node* n, long* v)
{
    if (n == null) return false;
    if (n.kind == Nk.N_EXPR_INT)
    {
        v[0] = (long)n.p.ival;
        return true;
    }
    if (n.kind == Nk.N_EXPR_BOOL)
    {
        v[0] = n.p.ival != 0 ? 1 : 0;
        return true;
    }
    return false;
}

fn bool is_same_name(Node* a, Node* b)
{
    if (a == null || b == null) return false;
    return a.kind == Nk.N_EXPR_IDENT && b.kind == Nk.N_EXPR_IDENT && a.name_id == b.name_id;
}

// Analyze one assignment: name = rhs; classify RHS shape.
fn usz sa_classify(ScevAnalysis* sa, Node* rhs, int loop_id)
{
    if (rhs == null) return sa_unknown(sa);
    long v;
    if (node_is_int_lit(rhs, &v)) return sa_const(sa, v);
    if (rhs.kind == Nk.N_EXPR_IDENT)
    {
        usz slot = rhs.name_id & (sa.name_map_cap - 1);
        int si = sa.name_map[slot];
        if (si >= 0) return (usz)si;
        return sa_unknown(sa);
    }
    if (rhs.kind == Nk.N_EXPR_BINARY && rhs.child_count >= 2)
    {
        Tk op = (Tk)rhs.p.op;
        Node* l = rhs.children[0];
        Node* r = rhs.children[1];
        usz li = sa_classify(sa, l, loop_id);
        usz ri = sa_classify(sa, r, loop_id);
        // constant + constant = constant
        if (sa.nodes[li].tag == SCEV_CONST && sa.nodes[ri].tag == SCEV_CONST)
        {
            long result = 0;
            bool ok = true;
            if (op == Tk.TOKEN_PLUS) { result = sa.nodes[li].c + sa.nodes[ri].c; }
            else if (op == Tk.TOKEN_MINUS) { result = sa.nodes[li].c - sa.nodes[ri].c; }
            else if (op == Tk.TOKEN_STAR) { result = sa.nodes[li].c * sa.nodes[ri].c; }
            else { ok = false; }
            if (ok) { return sa_const(sa, result); }
            return sa_new_add(sa, li, ri);
        }
        if (op == Tk.TOKEN_PLUS) return sa_new_add(sa, li, ri);
        return sa_unknown(sa);
    }
    return sa_unknown(sa);
}

fn usz sa_new_add(ScevAnalysis* sa, usz a, usz b)
{
    usz i = sa_new(sa, SCEV_ADD);
    sa.nodes[i].a = a;
    sa.nodes[i].b = b;
    sa.n_add++;
    return i;
}

fn usz sa_new_addrec(ScevAnalysis* sa, long start, long step, int loop_id)
{
    usz i = sa_new(sa, SCEV_ADDREC);
    sa.nodes[i].start = start;
    sa.nodes[i].step = step;
    sa.nodes[i].loop = loop_id;
    sa.n_addrec++;
    return i;
}

// Look for induction variables inside a loop:
//   1. Find assignments `x = x + k` (or `x = k + x`, `x = x - k`) in loop blocks.
//   2. x must be initialized BEFORE the loop.
//   3. k must be loop-invariant (we just check it's an integer literal for now).
fn void sa_scan_loop(ScevAnalysis* sa, Cfg* cfg, int loop_id)
{
    if (cfg == null) return;
    if (loop_id < 0 || (usz)loop_id >= cfg.loop_count) return;
    Loop* lp = &cfg.loops[loop_id];
    sa.loops_analyzed++;
    if (lp.blocks == null) return;
    // Walk each block in the loop.
    for (usz bi = 0; bi < lp.block_count; bi++)
    {
        int bid = lp.blocks[bi];
        if (bid < 0 || (usz)bid >= cfg.block_count) continue;
        Block* b = &cfg.blocks[bid];
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* s = b.stmts[si];
            if (s == null) continue;
            if (s.kind != Nk.N_STMT_ASSIGN && s.kind != Nk.N_STMT_COMPOUND_ASSIGN) continue;
            if (s.child_count < 2) continue;
            Node* lhs = s.children[0];
            Node* rhs = s.children[1];
            if (lhs == null || rhs == null) continue;
            if (lhs.kind != Nk.N_EXPR_IDENT) continue;
            // Check for x = x + k
            if (rhs.kind == Nk.N_EXPR_BINARY && rhs.child_count >= 2)
            {
                Tk op = (Tk)rhs.p.op;
                Node* a = rhs.children[0];
                Node* b_node = rhs.children[1];
                long k;
                if (op == Tk.TOKEN_PLUS && is_same_name(a, lhs) && node_is_int_lit(b_node, &k))
                {
                    sa_new_addrec(sa, 0, k, loop_id);
                    sa.ivs_found++;
                }
                else if (op == Tk.TOKEN_PLUS && is_same_name(b_node, lhs) && node_is_int_lit(a, &k))
                {
                    sa_new_addrec(sa, 0, k, loop_id);
                    sa.ivs_found++;
                }
                else if (op == Tk.TOKEN_MINUS && is_same_name(a, lhs) && node_is_int_lit(b_node, &k))
                {
                    sa_new_addrec(sa, 0, -k, loop_id);
                    sa.ivs_found++;
                }
            }
            // Compound += k
            if (s.kind == Nk.N_STMT_COMPOUND_ASSIGN && (Tk)s.p.op == Tk.TOKEN_PLUS)
            {
                long k;
                if (node_is_int_lit(rhs, &k))
                {
                    sa_new_addrec(sa, 0, k, loop_id);
                    sa.ivs_found++;
                }
            }
        }
    }
}

fn void ScevAnalysis.run_on_cfg(ScevAnalysis* sa, Cfg* cfg)
{
    if (cfg == null) return;
    sa.cfg = cfg;
    // Reset name map.
    for (usz i = 0; i < sa.name_map_cap; i++) sa.name_map[i] = -1;
    sa.n_count = 0;
    sa.n_const = 0; sa.n_addrec = 0; sa.n_unknown = 0; sa.n_add = 0;
    // Seed constants and top-level names by walking entry blocks first.
    for (usz li = 0; li < cfg.loop_count; li++)
    {
        sa_scan_loop(sa, cfg, (int)li);
    }
}

fn void ScevAnalysis.report(ScevAnalysis* sa)
{
    printf("  scev nodes       : %d (%d const, %d addrec, %d add, %d unknown)\n",
           (int)sa.n_count, (int)sa.n_const, (int)sa.n_addrec, (int)sa.n_add, (int)sa.n_unknown);
    printf("  scev loops       : %d analyzed, %d IVs found\n",
           (int)sa.loops_analyzed, (int)sa.ivs_found);
}

fn void ScevAnalysis.free(ScevAnalysis* sa)
{
    free((void*)sa.nodes);
    free((void*)sa.name_map);
    sa.nodes = null;
    sa.name_map = null;
}
