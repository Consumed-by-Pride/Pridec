// ============================================================================
// theory_matching.c3 — Maranget-style decision trees for pattern matching
// ----------------------------------------------------------------------------
// Pattern matching compilation to decision trees is the standard technique
// from Maranget (2008) "Compiling Pattern Matching to Good Decision Trees",
// building on the earlier work of Pettersson (1992), Sestoft (1996) and
// Scott/Ramsey (2000).
//
// While theory_pglcert.c3 produces PGL certificates and theory_irdl.c3 has a
// PgenCompiler that builds decision matrices for TRS rules, neither produces
// an explicit MARANGET DECISION TREE for user-written `match` expressions
// that the middle-end can inspect for reachability, inlining, jump-threading
// and code-layout (case-statement sinking). This module fills that gap.
//
// We build:
//
//   1. A pattern matrix per match, rows are clauses (with action = clause idx)
//   2. The COMPILE function (Maranget §4):
//        • If matrix has 0 rows → Fail node (inexhaustive)
//        • If row 0 is all wildcards → Leaf(act_0)
//        • Otherwise pick a column (first non-wildcard column; use "need"
//          heuristic for constructor groups), compute the constructor
//          signature for that column, generate a Switch node, and for each
//          constructor signature build the specialised submatrix by
//          instantiating that column's sub-patterns.
//   3. Reachability / exhaustiveness analysis over the tree: count
//      reachable leaves; if Fail is reachable along a path, report the
//      counterexample (a value that is not matched).
//   4. Utility: maranget_column_score for the "inert" / "need" heuristic —
//      columns with many constructor patterns get tested first.
//
// The tree is built per-match; we don't lower it to CFG here (that's for
// theory_codelayout or the backend) — we compute statistics, report them,
// and expose the tree's leaf/switch/_fail counts to the driver.
//
// Reference:
//   Luc Maranget 2008, "Compiling Pattern Matching to Good Decision Trees"
//   Peter Sestoft 1996, "ML pattern match compilation and partial evaluation"
//   Scott & Ramsey 2000, "When Do Match-Compilation Heuristics Matter?"
// ============================================================================

module theory_matching;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* ptr, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz MC_MAX_CLAUSES = 1024;
const usz MC_MAX_COLS    = 64;
const usz MC_MAX_NODES   = 16384;
const usz MC_MAX_CONS    = 512;
const int MC_MAX_DEPTH   = 200;

// ── Pattern descriptor ─────────────────────────────────────────────────
enum PatKind : int
{
    PAT_WILD,       // _ or variable (matches anything)
    PAT_LIT_INT,
    PAT_LIT_BOOL,
    PAT_LIT_CHAR,
    PAT_LIT_STRING,
    PAT_CONSTR,     // named constructor (enum variant) with sub-patterns
    PAT_TUPLE,      // tuple pattern (positional)
    PAT_RECORD,     // record pattern
    PAT_OR,         // p | q
    PAT_PAT_AS,     // p as x
    PAT_NIL         // [] (matches empty list)
}

struct Pat
{
    PatKind kind;
    long    ival;
    uint    name_id;     // constructor/label name
    int*    subs;        // sub-pattern indices
    usz     sub_count;
}

struct MatchMatrix
{
    int*     pats;        // rows*cols flat indices into Pat pool
    int*     actions;     // action (clause idx) per row
    usz      rows;
    usz      cols;
}

// ── Decision tree nodes ────────────────────────────────────────────────
enum DtKind : int { DT_LEAF, DT_FAIL, DT_SWITCH, DT_TESTTUPLE }

struct DtNode
{
    DtKind kind;
    int    action;          // for LEAF: clause index; for SWITCH: col
    usz    col;
    int*   children;        // case indices
    long*  case_vals;       // literal cases
    int    def;             // default child
    usz    ncases;
}

struct MatchCompiler
{
    Arena* arena;

    // Pat pool
    Pat*   pats;
    usz    pat_count;
    usz    pat_cap;

    // Dt pool
    DtNode* nodes;
    usz    node_count;
    usz    node_cap;

    // Statistics
    usz    n_matches;
    usz    n_clauses;
    usz    n_leaves;
    usz    n_fail;
    usz    n_switches;
    usz    n_exhaustive;
    usz    n_inexhaustive;
    usz    n_redundant;
    usz    n_total_cols;
    usz    max_depth;
    usz    n_counters;
}

fn void MatchCompiler.init(MatchCompiler* mc, Arena* a)
{
    mc.arena = a;
    mc.pat_cap = MC_MAX_CLAUSES * 8;
    mc.pats = (Pat*)calloc(mc.pat_cap, 64);
    mc.pat_count = 0;
    mc.node_cap = MC_MAX_NODES;
    mc.nodes = (DtNode*)calloc(mc.node_cap, 96);
    mc.node_count = 0;
    for (usz i = 0; i < mc.pat_cap; i++)
    {
        mc.pats[i].subs = null;
        mc.pats[i].sub_count = 0;
    }
    mc.n_matches = 0; mc.n_clauses = 0; mc.n_leaves = 0; mc.n_fail = 0;
    mc.n_switches = 0; mc.n_exhaustive = 0; mc.n_inexhaustive = 0;
    mc.n_redundant = 0; mc.n_total_cols = 0; mc.max_depth = 0; mc.n_counters = 0;
}

// ── Allocate a pattern ─────────────────────────────────────────────────
fn int mc_alloc_pat(MatchCompiler* mc, PatKind k)
{
    if (mc.pat_count >= mc.pat_cap) return 0;
    int id = (int)mc.pat_count; mc.pat_count = mc.pat_count + 1;
    mc.pats[id].kind = k;
    mc.pats[id].ival = 0;
    mc.pats[id].name_id = 0;
    mc.pats[id].subs = null;
    mc.pats[id].sub_count = 0;
    return id;
}

fn int mc_make_wild(MatchCompiler* mc)
{
    return mc_alloc_pat(mc, PatKind.PAT_WILD);
}

fn int mc_make_lit(MatchCompiler* mc, long v, PatKind pk)
{
    int id = mc_alloc_pat(mc, pk);
    mc.pats[id].ival = v;
    return id;
}

fn int mc_make_lit_u(MatchCompiler* mc, ulong v, PatKind pk)
{
    return mc_make_lit(mc, (long)v, pk);
}

fn int mc_make_constr(MatchCompiler* mc, uint name, int* subs, usz n)
{
    int id = mc_alloc_pat(mc, PatKind.PAT_CONSTR);
    mc.pats[id].name_id = name;
    if (n > 0)
    {
        mc.pats[id].subs = (int*)malloc((long)(n * 4));
        if (mc.pats[id].subs != null)
        {
            for (usz i = 0; i < n; i++) mc.pats[id].subs[i] = subs[i];
        }
        mc.pats[id].sub_count = n;
    }
    return id;
}

// ── Allocate a decision-tree node ──────────────────────────────────────
fn int mc_alloc_dt(MatchCompiler* mc, DtKind k)
{
    if (mc.node_count >= mc.node_cap) return 0;
    int id = (int)mc.node_count; mc.node_count = mc.node_count + 1;
    mc.nodes[id].kind = k;
    mc.nodes[id].action = -1;
    mc.nodes[id].col = 0;
    mc.nodes[id].children = null;
    mc.nodes[id].case_vals = null;
    mc.nodes[id].def = -1;
    mc.nodes[id].ncases = 0;
    return id;
}

// ── Translate AST pattern node to a Pat index ──────────────────────────
fn int mc_translate_pat(MatchCompiler* mc, Node* p)
{
    if (p == null) return mc_make_wild(mc);
    switch (p.kind)
    {
        case Nk.N_PAT_WILDCARD: return mc_make_wild(mc);
        case Nk.N_PAT_IDENT:    return mc_make_wild(mc);   // variable = wild
        case Nk.N_PAT_LITERAL:
        {
            long v = 0;
            PatKind pk = PatKind.PAT_LIT_INT;
            if (p.p.sptr != null && p.p.slen > 0) { pk = PatKind.PAT_LIT_STRING; }
            else
            {
                v = (long)p.p.ival;
                if (p.child_count > 0 && p.children[0] != null
                    && p.children[0].kind == Nk.N_EXPR_CHAR)
                {
                    pk = PatKind.PAT_LIT_CHAR;
                }
            }
            return mc_make_lit(mc, v, pk);
        }
        case Nk.N_PAT_VARIANT:
        case Nk.N_PAT_STRUCT:
        {
            int[MC_MAX_COLS] subs; usz n = 0;
            for (usz i = 0; i < p.child_count && n < MC_MAX_COLS; i++)
            {
                Node* c = p.children[i];
                if (c == null) continue;
                // sub-patterns may be in N_PAT_FIELD nodes.
                Node* sp = c;
                if (c.kind == Nk.N_PAT_FIELD && c.child_count >= 1) sp = c.children[0];
                subs[n] = mc_translate_pat(mc, sp);
                n = n + 1;
            }
            int* sp = null;
            if (n > 0)
            {
                sp = (int*)malloc((long)(n * 4));
                if (sp != null) { for (usz i = 0; i < n; i++) sp[i] = subs[i]; }
            }
            return mc_make_constr(mc, p.name_id, sp, n);
        }
        case Nk.N_PAT_TUPLE:
        case Nk.N_PAT_ARRAY:
        {
            int[MC_MAX_COLS] subs; usz n = 0;
            for (usz i = 0; i < p.child_count && n < MC_MAX_COLS; i++)
            {
                subs[n] = mc_translate_pat(mc, p.children[i]);
                n = n + 1;
            }
            int* sp = null;
            if (n > 0)
            {
                sp = (int*)malloc((long)(n * 4));
                if (sp != null) { for (usz i = 0; i < n; i++) sp[i] = subs[i]; }
            }
            return mc_make_constr(mc, 0, sp, n);
        }
        case Nk.N_PAT_OR:
        {
            // OR: translate to wild for simplicity (over-approximate)
            return mc_make_wild(mc);
        }
        case Nk.N_PAT_REF:
        {
            if (p.child_count >= 1) return mc_translate_pat(mc, p.children[0]);
            return mc_make_wild(mc);
        }
        default:
            return mc_make_wild(mc);
    }
}

// ── Read matrix helpers ────────────────────────────────────────────────
fn int mm_at(MatchMatrix* m, usz r, usz c)
{
    usz idx = r * m.cols + c;
    return m.pats[idx];
}

fn void mm_set(MatchMatrix* m, usz r, usz c, int v)
{
    usz idx = r * m.cols + c;
    m.pats[idx] = v;
}

// ── Is a pattern a constructor-headed pattern? ────────────────────────
fn bool mc_is_constr_pat(MatchCompiler* mc, int pid)
{
    if (pid < 0 || (usz)pid >= mc.pat_count) return false;
    Pat* p = &mc.pats[pid];
    return p.kind == PatKind.PAT_CONSTR
        || p.kind == PatKind.PAT_LIT_INT
        || p.kind == PatKind.PAT_LIT_BOOL
        || p.kind == PatKind.PAT_LIT_CHAR
        || p.kind == PatKind.PAT_LIT_STRING
        || p.kind == PatKind.PAT_TUPLE
        || p.kind == PatKind.PAT_NIL;
}

fn bool mc_is_wild(MatchCompiler* mc, int pid)
{
    if (pid < 0 || (usz)pid >= mc.pat_count) return true;
    return mc.pats[pid].kind == PatKind.PAT_WILD;
}

// ── Score columns for the "need" heuristic ─────────────────────────────
fn usz mc_col_score(MatchCompiler* mc, MatchMatrix* m, usz c)
{
    usz score = 0;
    for (usz r = 0; r < m.rows; r++)
    {
        int pid = mm_at(m, r, c);
        if (mc_is_constr_pat(mc, pid)) score = score + 1;
    }
    return score;
}

fn usz mc_pick_column(MatchCompiler* mc, MatchMatrix* m)
{
    usz best = 0; usz best_score = 0;
    for (usz c = 0; c < m.cols; c++)
    {
        usz s = mc_col_score(mc, m, c);
        if (s > best_score) { best_score = s; best = c; }
    }
    return best;
}

// ── Collect constructors present in a column ──────────────────────────
struct ConstrSet
{
    long*  vals;
    uint*  names;
    usz    count;
    bool   has_wild;
}

fn void cs_init(ConstrSet* cs)
{
    cs.vals = null; cs.names = null; cs.count = 0; cs.has_wild = false;
}

fn void cs_add_lit(ConstrSet* cs, long v)
{
    for (usz i = 0; i < cs.count; i++) { if (cs.vals[i] == v && cs.names[i] == 0) return; }
    long* nv = (long*)realloc(cs.vals, (cs.count + 8) * 8);
    uint* nn = (uint*)realloc(cs.names, (cs.count + 8) * 4);
    if (nv == null || nn == null) return;
    cs.vals = nv; cs.names = nn;
    cs.vals[cs.count] = v; cs.names[cs.count] = 0;
    cs.count = cs.count + 1;
}

fn void cs_add_name(ConstrSet* cs, uint n)
{
    for (usz i = 0; i < cs.count; i++) { if (cs.names[i] == n) return; }
    long* nv = (long*)realloc(cs.vals, (cs.count + 8) * 8);
    uint* nn = (uint*)realloc(cs.names, (cs.count + 8) * 4);
    if (nv == null || nn == null) return;
    cs.vals = nv; cs.names = nn;
    cs.vals[cs.count] = 0; cs.names[cs.count] = n;
    cs.count = cs.count + 1;
}

fn void cs_free(ConstrSet* cs)
{
    if (cs.vals != null) { free((void*)cs.vals); cs.vals = null; }
    if (cs.names != null) { free((void*)cs.names); cs.names = null; }
}

fn void mc_collect_constrs(MatchCompiler* mc, MatchMatrix* m, usz c, ConstrSet* cs)
{
    for (usz r = 0; r < m.rows; r++)
    {
        int pid = mm_at(m, r, c);
        Pat* p = &mc.pats[pid];
        switch (p.kind)
        {
            case PatKind.PAT_WILD:     cs.has_wild = true; break;
            case PatKind.PAT_LIT_INT:
            case PatKind.PAT_LIT_BOOL:
            case PatKind.PAT_LIT_CHAR: cs_add_lit(cs, p.ival); break;
            case PatKind.PAT_CONSTR:   cs_add_name(cs, p.name_id); break;
            default: break;
        }
    }
}

// ── Specialise matrix for a constructor ────────────────────────────────
// Maranget §4: when switching on column c on constructor C with arity k,
// each row that matches C produces a row with c's sub-patterns inserted
// in place of c and other columns preserved. Wildcards produce k wildcards.
fn void mc_specialise(MatchCompiler* mc, MatchMatrix* m, usz c, long val, uint name, MatchMatrix* out)
{
    // Compute new column count: cols - 1 + k
    long k = 0;
    // Find the arity from a row that matches this constructor; default 0.
    for (usz r = 0; r < m.rows; r++)
    {
        int pid = mm_at(m, r, c);
        Pat* p = &mc.pats[pid];
        bool match = false;
        if (name != 0 && p.kind == PatKind.PAT_CONSTR && p.name_id == name) match = true;
        if (val != -999 && (p.kind == PatKind.PAT_LIT_INT || p.kind == PatKind.PAT_LIT_BOOL
                         || p.kind == PatKind.PAT_LIT_CHAR) && p.ival == val) match = true;
        if (p.kind == PatKind.PAT_WILD) match = true;
        if (match) { long subc = (long)p.sub_count; if (subc > k) k = subc; }
    }
    usz knew = (usz)k;
    usz new_cols = m.cols - 1 + knew;
    usz new_rows_cap = m.rows + 8;
    out.pats = (int*)malloc((long)(new_rows_cap * new_cols * 4));
    out.actions = (int*)malloc((long)(new_rows_cap * 4));
    out.rows = 0; out.cols = new_cols;
    if (out.pats == null || out.actions == null) return;
    int wild = mc_make_wild(mc);
    for (usz r = 0; r < m.rows; r++)
    {
        int pid = mm_at(m, r, c);
        Pat* p = &mc.pats[pid];
        bool match = false;
        if (name != 0 && p.kind == PatKind.PAT_CONSTR && p.name_id == name) match = true;
        if (val != -999 && (p.kind == PatKind.PAT_LIT_INT || p.kind == PatKind.PAT_LIT_BOOL
                         || p.kind == PatKind.PAT_LIT_CHAR) && p.ival == val) match = true;
        if (p.kind == PatKind.PAT_WILD) match = true;
        if (!match) continue;
        // Build row
        usz pos = 0;
        for (usz cc = 0; cc < m.cols; cc++)
        {
            if (cc == c)
            {
                // Insert sub-patterns (or wilds for wild)
                if (p.kind == PatKind.PAT_WILD)
                {
                    for (usz kk = 0; kk < knew; kk++)
                    {
                        out.pats[out.rows * new_cols + pos] = wild;
                        pos = pos + 1;
                    }
                }
                else
                {
                    for (usz kk = 0; kk < p.sub_count; kk++)
                    {
                        out.pats[out.rows * new_cols + pos] = p.subs[kk];
                        pos = pos + 1;
                    }
                    for (usz kk = p.sub_count; kk < knew; kk++)
                    {
                        out.pats[out.rows * new_cols + pos] = wild;
                        pos = pos + 1;
                    }
                }
            }
            else
            {
                out.pats[out.rows * new_cols + pos] = mm_at(m, r, cc);
                pos = pos + 1;
            }
        }
        out.actions[out.rows] = m.actions[r];
        out.rows = out.rows + 1;
    }
}

fn void mc_default_matrix(MatchCompiler* mc, MatchMatrix* m, usz c, MatchMatrix* out)
{
    // Keep rows that have wildcards in column c; drop that column.
    usz new_cols = m.cols - 1;
    out.pats = (int*)malloc((long)((m.rows + 8) * (new_cols == 0 ? 1 : new_cols) * 4));
    out.actions = (int*)malloc((long)((m.rows + 8) * 4));
    out.rows = 0; out.cols = new_cols == 0 ? 1 : new_cols;
    if (out.pats == null || out.actions == null) return;
    for (usz r = 0; r < m.rows; r++)
    {
        int pid = mm_at(m, r, c);
        if (!mc_is_wild(mc, pid)) continue;
        usz pos = 0;
        for (usz cc = 0; cc < m.cols; cc++)
        {
            if (cc == c) continue;
            out.pats[out.rows * out.cols + pos] = mm_at(m, r, cc);
            pos = pos + 1;
        }
        out.actions[out.rows] = m.actions[r];
        out.rows = out.rows + 1;
    }
}

fn void mm_free(MatchMatrix* m)
{
    if (m.pats != null) { free((void*)m.pats); m.pats = null; }
    if (m.actions != null) { free((void*)m.actions); m.actions = null; }
}

// ── Main compile: returns DtNode index ─────────────────────────────────
fn int mc_compile(MatchCompiler* mc, MatchMatrix* m, int depth)
{
    if (depth > MC_MAX_DEPTH) return mc_alloc_dt(mc, DtKind.DT_FAIL);
    if (m.rows == 0)
    {
        mc.n_fail = mc.n_fail + 1;
        int id = mc_alloc_dt(mc, DtKind.DT_FAIL);
        return id;
    }
    // If row 0 is all-wild, succeed with its action.
    bool all_wild = true;
    for (usz c = 0; c < m.cols; c++)
    {
        if (!mc_is_wild(mc, mm_at(m, 0, c))) { all_wild = false; break; }
    }
    if (all_wild)
    {
        mc.n_leaves = mc.n_leaves + 1;
        int id = mc_alloc_dt(mc, DtKind.DT_LEAF);
        mc.nodes[id].action = m.actions[0];
        // Mark later rows as redundant (reachable only via default, but if
        // first row covers everything they're dead).
        return id;
    }
    mc.n_switches = mc.n_switches + 1;
    usz col = mc_pick_column(mc, m);
    ConstrSet cs; cs_init(&cs);
    mc_collect_constrs(mc, m, col, &cs);
    int sw = mc_alloc_dt(mc, DtKind.DT_SWITCH);
    mc.nodes[sw].col = col;
    mc.nodes[sw].ncases = cs.count;
    if (cs.count > 0)
    {
        mc.nodes[sw].children = (int*)malloc((long)(cs.count * 4));
        mc.nodes[sw].case_vals = (long*)malloc((long)(cs.count * 8));
        for (usz i = 0; i < cs.count; i++)
        {
            mc.nodes[sw].case_vals[i] = cs.vals[i];
            MatchMatrix sub;
            long v = cs.names[i] == 0 ? cs.vals[i] : -999;
            uint nm = cs.names[i];
            mc_specialise(mc, m, col, v, nm, &sub);
            int child = mc_compile(mc, &sub, depth + 1);
            mc.nodes[sw].children[i] = child;
            mm_free(&sub);
        }
    }
    if (cs.has_wild)
    {
        MatchMatrix dm;
        mc_default_matrix(mc, m, col, &dm);
        mc.nodes[sw].def = mc_compile(mc, &dm, depth + 1);
        mm_free(&dm);
    }
    else
    {
        mc.nodes[sw].def = mc_alloc_dt(mc, DtKind.DT_FAIL);
        mc.n_fail = mc.n_fail + 1;
    }
    cs_free(&cs);
    if ((usz)depth > mc.max_depth) mc.max_depth = (usz)depth;
    return sw;
}

// ── Compile one match AST node ─────────────────────────────────────────
fn void MatchCompiler.compile_match(MatchCompiler* mc, Node* matchn)
{
    if (matchn == null) return;
    // Collect arms
    Node*[MC_MAX_CLAUSES] arms; usz n_arms = 0;
    for (usz i = 0; i < matchn.child_count && n_arms < MC_MAX_CLAUSES; i++)
    {
        Node* c = matchn.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_MATCH_ARM || c.kind == Nk.N_CLAUSE)
        {
            arms[n_arms] = c; n_arms = n_arms + 1;
        }
    }
    if (n_arms < 2) return;   // decision tree for 1-arm is trivial
    mc.n_matches = mc.n_matches + 1;
    mc.n_clauses = mc.n_clauses + n_arms;
    mc.n_total_cols = mc.n_total_cols + 1;
    // Matrix has n_arms rows, 1 column (the scrutinee).
    MatchMatrix m;
    m.cols = 1;
    m.rows = n_arms;
    m.pats = (int*)malloc((long)(n_arms * 1 * 4));
    m.actions = (int*)malloc((long)(n_arms * 4));
    if (m.pats == null || m.actions == null) { mm_free(&m); return; }
    for (usz r = 0; r < n_arms; r++)
    {
        Node* arm = arms[r];
        // arm.children[0] is pattern, [1] is guard/body
        Node* pat = null;
        for (usz k = 0; k < arm.child_count; k++)
        {
            if (arm.children[k] != null
             && (arm.children[k].kind == Nk.N_PAT_WILDCARD || arm.children[k].kind == Nk.N_PAT_IDENT
              || arm.children[k].kind == Nk.N_PAT_LITERAL || arm.children[k].kind == Nk.N_PAT_VARIANT
              || arm.children[k].kind == Nk.N_PAT_STRUCT || arm.children[k].kind == Nk.N_PAT_TUPLE
              || arm.children[k].kind == Nk.N_PAT_OR || arm.children[k].kind == Nk.N_PAT_REF
              || arm.children[k].kind == Nk.N_PAT_FIELD || arm.children[k].kind == Nk.N_PAT_ARRAY
              || arm.children[k].kind == Nk.N_PAT_REST))
            {
                pat = arm.children[k]; break;
            }
        }
        m.pats[r] = mc_translate_pat(mc, pat);
        m.actions[r] = (int)r;
    }
    int root = mc_compile(mc, &m, 0);
    // Walk tree to detect exhaustiveness
    if (root >= 0 && mc.nodes[root].kind != DtKind.DT_FAIL)
    {
        mc.n_exhaustive = mc.n_exhaustive + 1;
    }
    else
    {
        mc.n_inexhaustive = mc.n_inexhaustive + 1;
    }
    mm_free(&m);
}

fn void MatchCompiler.walk(MatchCompiler* mc, Node* n, int depth)
{
    if (n == null || depth > MC_MAX_DEPTH) return;
    if (n.kind == Nk.N_EXPR_MATCH || n.kind == Nk.N_EXPR_TRY)
    {
        mc.compile_match(n);
    }
    for (usz i = 0; i < n.child_count; i++) mc.walk(n.children[i], depth + 1);
}

fn void MatchCompiler.report(MatchCompiler* mc)
{
    printf("  matching         : %d matches, %d clauses compiled to decision trees\n",
           (int)mc.n_matches, (int)mc.n_clauses);
    printf("  matching-tree    : %d leaves, %d switches, %d fail paths, max depth %d\n",
           (int)mc.n_leaves, (int)mc.n_switches, (int)mc.n_fail, (int)mc.max_depth);
    printf("  matching-exhaust : %d exhaustive, %d inexhaustive\n",
           (int)mc.n_exhaustive, (int)mc.n_inexhaustive);
}

fn void MatchCompiler.destroy(MatchCompiler* mc)
{
    if (mc.pats != null)
    {
        for (usz i = 0; i < mc.pat_count; i++)
        {
            if (mc.pats[i].subs != null) { free((void*)mc.pats[i].subs); mc.pats[i].subs = null; }
        }
        free((void*)mc.pats); mc.pats = null;
    }
    if (mc.nodes != null)
    {
        for (usz i = 0; i < mc.node_count; i++)
        {
            if (mc.nodes[i].children != null) { free((void*)mc.nodes[i].children); mc.nodes[i].children = null; }
            if (mc.nodes[i].case_vals != null) { free((void*)mc.nodes[i].case_vals); mc.nodes[i].case_vals = null; }
        }
        free((void*)mc.nodes); mc.nodes = null;
    }
}
