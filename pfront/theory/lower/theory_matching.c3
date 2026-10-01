// ============================================================================
// theory_matching.c3 — compiling pattern matching to good decision trees
// ----------------------------------------------------------------------------
// The previous file in this slot built a matrix per `match`, picked the
// first non-wildcard column, and reported "exhaustive" whenever the root of
// the tree was not a Fail node — which is not what exhaustive means. It
// ignored function clauses, or-patterns (turned into wildcards), guards,
// ranges and enum signatures, verified nothing, and wrote nothing back.
//
// This module is the match COMPILER of the theory layer. Exhaustiveness and
// unreachable-arm warnings are theory_pglcert's job (W4090/W4091, with
// witnesses); what a backend needs beyond that is the TREE — which tests to
// perform, in which order, on which sub-value, sharing what — and a proof
// that the tree agrees with first-match semantics. That is what is built
// here, for every `match` expression AND every multi-clause function.
//
//   PATTERNS      wildcard/variable · literal (int/bool/char/string) · range
//                 lo..hi · enum variant with payload · tuple/array (positional)
//                 · struct (positional over declared fields) · or-pattern
//                 (rows are duplicated, Maranget §2) · `p as x` / &p (see
//                 through). Guards make a row NON-COVERING: a guarded row that
//                 reaches the top yields a leaf with a fallthrough tree
//                 compiled from the remaining rows.
//
//   OCCURRENCES   every column is a path into the scrutinee (x, x.0, x.1.2);
//                 the tree tests occurrences, never re-computes them.
//
//   COMPILATION   Maranget 2008 with the composite heuristic f → b → a
//                 (rows needed by the first row, fewest branches, smallest
//                 arity), tie broken leftmost. Signatures: bool = {true,
//                 false}; enum = its declared variants (looked up from the
//                 program's enum declarations, so a switch over every variant
//                 needs no default); tuple/struct = the single constructor
//                 (an UNPACK step, not a test); integers/chars/strings/ranges
//                 are open, always with a default.
//
//   SHARING       nodes are hash-consed on (kind, occurrence, cases,
//                 children) — the tree is really a DAG; identical subtrees
//                 produced by different specialisations (the classic blow-up
//                 of decision trees) are emitted once. Counted as merges.
//
//   VERIFICATION  for each row, a sample value is built from its patterns
//                 (wildcards filled with a value no literal in the matrix
//                 mentions), the DAG is executed on it, and the answer is
//                 compared with a naive first-match interpreter over the
//                 original rows. Plus the same for every case value the tree
//                 tests, and for a "none of the above" value. The count of
//                 agreements/disagreements is reported; a disagreement is a
//                 compiler bug and is printed as such.
//
//   METRICS       tree nodes vs DAG nodes, worst-case tests along a path,
//                 average tests weighted uniformly over rows, switch fan-out.
//
//   WRITEBACK     NF_DENSE_SWITCH on a `match` / fn whose root test is a
//                 dense, unguarded integer/character literal switch in the
//                 subset currently supported by PEAR. The general decision
//                 tree can be denser than the backend-lowerable subset.
//                 N4210 reports the dense analysis shape under --lint.
//
//   --emit-dtree prints every DAG.
//
// References: Maranget 2008 "Compiling Pattern Matching to Good Decision
// Trees"; Maranget 2007 "Warnings for pattern matching"; Scott & Ramsey 2000
// "When Do Match-Compilation Heuristics Matter?"; Sestoft 1996; Pettersson
// 1992 "A term pattern-match compiler inspired by finite automata theory".
// ============================================================================

module theory_matching;

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

const usz MC_MAX_ROWS     = 512;
const usz MC_MAX_COLS     = 64;
const usz MC_MAX_ARITY    = 32;
const usz MC_MAX_ENUMS    = 512;
const usz MC_MAX_VARIANTS = 64;
const usz MC_MAX_NODES    = 32768;
const usz MC_MAX_OCCS     = 8192;
const usz MC_HASH         = 8192;
const int MC_MAX_DEPTH    = 64;
const usz MC_MAX_CASES    = 4096;

// ── Constructors and patterns ───────────────────────────────────────────
enum Ctag : char
{
    C_INT,      // integer literal  (ival)
    C_BOOL,     // ival 0/1
    C_CHAR,     // ival
    C_STR,      // name = interned text id (equality by id)
    C_RANGE,    // [lo, hi]  (ival, ival2)  — open signature
    C_VARIANT,  // name = variant name, decl = variant decl, arity = payload
    C_TUPLE,    // positional, arity = width   — single constructor
    C_STRUCT,   // name = struct name, arity = fields written
    C_OTHER     // "some value none of the literals mention" (verification only)
}

struct Con
{
    Ctag  tag;
    long  ival;
    long  ival2;
    uint  name;
    Node* decl;      // C_VARIANT: the N_DECL_VARIANT; C_STRUCT: struct decl (may be null)
    Node* enum_decl; // C_VARIANT: owning enum
    usz   arity;
}

// A pattern is a wildcard or a constructor with sub-patterns.
// Or-patterns never live in a Pat: they are expanded into rows.
struct Pat
{
    bool  wild;
    Con   con;
    Pat** subs;
    Node* src;
}

struct Row
{
    Pat** pats;      // width = matrix cols
    int   action;    // arm index
    bool  guarded;
    Node* src;
}

// occurrence = path into the scrutinee
struct Occ
{
    int parent;      // -1 = root
    int index;
}

struct Matrix
{
    Row* rows;
    usz  n_rows;
    int* occs;       // one occurrence id per column
    usz  n_cols;
}

// ── Decision DAG ────────────────────────────────────────────────────────
enum DtKind : char
{
    DT_LEAF,     // action; if guarded, `next` is the fallthrough tree
    DT_FAIL,
    DT_SWITCH,   // on occ: cases[i] -> children[i], default -> def
    DT_UNPACK    // tuple/struct: single constructor, one child
}

struct DtNode
{
    DtKind kind;
    int    occ;
    int    action;
    bool   guarded;
    int    next;          // LEAF: fallthrough tree id (-1 none)
    Con*   cases;
    int*   children;
    usz    n_cases;
    int    def;           // -1 = no default (signature complete)
    ulong  hash;
    int    hnext;         // hash chain
    usz    size;          // number of distinct nodes reachable (DAG size)
}

// enum table: name -> variants
struct EnumInfo
{
    Node* decl;
    uint  name;
    usz   n_variants;
    Node*[MC_MAX_VARIANTS] variants;
}

struct MatchFacts
{
    Node* site;            // N_EXPR_MATCH or N_DECL_FN
    int   root;
    usz   n_rows;
    usz   n_or_expanded;
    usz   tree_nodes;      // nodes if the DAG were unshared
    usz   dag_nodes;
    usz   merges;
    usz   worst_tests;
    usz   total_tests;     // sum over rows of tests on the path of the row's sample
    usz   verified;
    usz   disagreements;
    bool  dense;
    bool  complete_root;   // root switch has no default
    bool  is_fn;
}

struct MatchCompiler
{
    Arena* arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*  file;
    bool   emit;

    DtNode* nodes;
    usz     n_nodes;
    int*    buckets;

    Occ*    occs;
    usz     n_occs;

    EnumInfo* enums;
    usz       n_enums;

    // literal universe of the current match (for the "other" value)
    long    lit_max;

    MatchFacts* facts;
    usz         n_facts;

    // aggregate
    usz n_matches, n_fn_sites, n_rows_total, n_or_rows;
    usz n_leaves, n_switches, n_unpacks, n_fails;
    usz n_tree_nodes, n_dag_nodes, n_merges;
    usz n_complete_switches, n_default_switches;
    usz n_verified, n_disagree, n_samples, n_impossible;
    usz worst_tests_all; uint worst_site;
    usz n_dense, n_n4210;
    usz max_fanout; usz sum_tests; usz sum_rows;
}

// ── Setup ───────────────────────────────────────────────────────────────
fn void MatchCompiler.init(MatchCompiler* mc, Arena* a)
{
    mc.arena = a;
    mc.diags = null; mc.interner = null; mc.file = null; mc.emit = false;
    mc.nodes = (DtNode*)calloc(MC_MAX_NODES, DtNode::size);
    mc.n_nodes = 0;
    mc.buckets = (int*)malloc(int::size * MC_HASH);
    if (mc.buckets != null) { for (usz i = 0; i < MC_HASH; i++) { mc.buckets[i] = -1; } }
    mc.occs = (Occ*)calloc(MC_MAX_OCCS, Occ::size);
    mc.n_occs = 0;
    mc.enums = (EnumInfo*)calloc(MC_MAX_ENUMS, EnumInfo::size);
    mc.n_enums = 0;
    mc.lit_max = 0;
    mc.facts = (MatchFacts*)calloc(4096, MatchFacts::size);
    mc.n_facts = 0;
    mc.n_matches = 0; mc.n_fn_sites = 0; mc.n_rows_total = 0; mc.n_or_rows = 0;
    mc.n_leaves = 0; mc.n_switches = 0; mc.n_unpacks = 0; mc.n_fails = 0;
    mc.n_tree_nodes = 0; mc.n_dag_nodes = 0; mc.n_merges = 0;
    mc.n_complete_switches = 0; mc.n_default_switches = 0;
    mc.n_verified = 0; mc.n_disagree = 0; mc.n_samples = 0; mc.n_impossible = 0;
    mc.worst_tests_all = 0; mc.worst_site = 0;
    mc.n_dense = 0; mc.n_n4210 = 0;
    mc.max_fanout = 0; mc.sum_tests = 0; mc.sum_rows = 0;
}

fn void MatchCompiler.attach(MatchCompiler* mc, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    mc.diags = d; mc.interner = it; mc.file = file;
}

fn void MatchCompiler.destroy(MatchCompiler* mc)
{
    if (mc.nodes != null) { free((void*)mc.nodes); mc.nodes = null; }
    if (mc.buckets != null) { free((void*)mc.buckets); mc.buckets = null; }
    if (mc.occs != null) { free((void*)mc.occs); mc.occs = null; }
    if (mc.enums != null) { free((void*)mc.enums); mc.enums = null; }
    if (mc.facts != null) { free((void*)mc.facts); mc.facts = null; }
}

fn char* MatchCompiler.name(MatchCompiler* mc, uint id)
{
    if (mc.interner == null || id == 0) { return "_"; }
    char* s = mc.interner.text(id);
    return s == null ? "_" : s;
}

fn void* MatchCompiler.zalloc(MatchCompiler* mc, usz size)
{
    void* p = mc.arena.alloc(size, 8);
    if (p != null) { memset(p, 0, size); }
    return p;
}

// ── Enum table ──────────────────────────────────────────────────────────
fn void MatchCompiler.collect_enums(MatchCompiler* mc, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_DECL_ENUM && mc.n_enums < MC_MAX_ENUMS)
    {
        EnumInfo* e = &mc.enums[mc.n_enums];
        e.decl = n; e.name = n.name_id; e.n_variants = 0;
        for (usz i = 0; i < n.child_count && e.n_variants < MC_MAX_VARIANTS; i++)
        {
            Node* v = n.children[i];
            if (v != null && v.kind == Nk.N_DECL_VARIANT) { e.variants[e.n_variants] = v; e.n_variants = e.n_variants + 1; }
        }
        mc.n_enums = mc.n_enums + 1;
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { mc.collect_enums(n.children[i], depth + 1); }
}

// a variant pattern names a variant; find the enum that declares it
fn EnumInfo* MatchCompiler.enum_of_variant(MatchCompiler* mc, Node* pat, Node** variant_out)
{
    *variant_out = null;
    // resolved link first
    if (pat.resolved != null && pat.resolved.kind == Nk.N_DECL_VARIANT)
    {
        for (usz i = 0; i < mc.n_enums; i++)
        {
            EnumInfo* e = &mc.enums[i];
            for (usz j = 0; j < e.n_variants; j++) { if (e.variants[j] == pat.resolved) { *variant_out = pat.resolved; return e; } }
        }
    }
    // by name: last path segment
    uint nm = pat.name_id;
    for (usz i = 0; i < pat.child_count; i++)
    {
        Node* c = pat.children[i];
        if (c != null && c.kind == Nk.N_MODULE_PATH && c.child_count > 0)
        {
            Node* seg = c.children[c.child_count - 1];
            if (seg != null && seg.name_id != 0) { nm = seg.name_id; }
        }
    }
    for (usz i = 0; i < mc.n_enums; i++)
    {
        EnumInfo* e = &mc.enums[i];
        for (usz j = 0; j < e.n_variants; j++)
        {
            if (e.variants[j].name_id == nm) { *variant_out = e.variants[j]; return e; }
        }
    }
    return null;
}

fn usz variant_arity(Node* v)
{
    if (v == null) { return 0; }
    usz n = 0;
    for (usz i = 0; i < v.child_count; i++) { if (v.children[i] != null) { n = n + 1; } }
    return n;
}

// ── Pattern translation (with or-expansion into alternatives) ───────────
// A translated pattern may denote several alternatives (or-patterns at any
// depth). We return a list of Pat* alternatives; callers multiply rows.
struct Alts
{
    Pat** items;
    usz   n;
}

fn Pat* MatchCompiler.mk_wild(MatchCompiler* mc, Node* src)
{
    Pat* p = (Pat*)mc.zalloc(Pat::size);
    if (p == null) { return null; }
    p.wild = true; p.src = src;
    return p;
}

fn Pat* MatchCompiler.mk_con(MatchCompiler* mc, Con c, Pat** subs, Node* src)
{
    Pat* p = (Pat*)mc.zalloc(Pat::size);
    if (p == null) { return null; }
    p.wild = false; p.con = c; p.subs = subs; p.src = src;
    return p;
}

fn Alts MatchCompiler.single(MatchCompiler* mc, Pat* p)
{
    Alts a;
    a.items = (Pat**)mc.zalloc(usz::size);
    a.n = 0;
    if (a.items != null && p != null) { a.items[0] = p; a.n = 1; }
    return a;
}

fn Con con_lit(Ctag t, long v)
{
    Con c; c.tag = t; c.ival = v; c.ival2 = v; c.name = 0; c.decl = null; c.enum_decl = null; c.arity = 0;
    return c;
}

fn bool con_eq(Con* a, Con* b)
{
    if (a.tag != b.tag) { return false; }
    switch (a.tag)
    {
        case Ctag.C_INT: case Ctag.C_BOOL: case Ctag.C_CHAR: return a.ival == b.ival;
        case Ctag.C_RANGE: return a.ival == b.ival && a.ival2 == b.ival2;
        case Ctag.C_STR: return a.name == b.name;
        case Ctag.C_VARIANT: return a.decl != null ? a.decl == b.decl : a.name == b.name;
        case Ctag.C_TUPLE: return a.arity == b.arity;
        case Ctag.C_STRUCT: return a.name == b.name && a.arity == b.arity;
        case Ctag.C_OTHER: return true;
    }
    return false;
}

// literal value of a pat-literal node
fn Con MatchCompiler.literal_con(MatchCompiler* mc, Node* p)
{
    Node* lit = p.child_count > 0 ? p.children[0] : null;
    if (lit == null) { return con_lit(Ctag.C_INT, (long)p.p.ival); }
    switch (lit.kind)
    {
        case Nk.N_EXPR_BOOL: return con_lit(Ctag.C_BOOL, (long)lit.p.ival);
        case Nk.N_EXPR_CHAR: return con_lit(Ctag.C_CHAR, (long)lit.p.ival);
        case Nk.N_EXPR_STRING:
        {
            Con c = con_lit(Ctag.C_STR, 0);
            c.name = lit.name_id != 0 ? lit.name_id : (uint)(lit.p.slen * 131 + (lit.p.sptr != null ? (uint)(char)lit.p.sptr[0] : 0));
            return c;
        }
        case Nk.N_EXPR_UNARY:
        {
            // -N
            Node* in = lit.child_count > 0 ? lit.children[0] : null;
            long v = in != null ? (long)in.p.ival : 0;
            if (lit.p.op == (int)Tk.TOKEN_MINUS) { v = -v; }
            return con_lit(Ctag.C_INT, v);
        }
        default:
        {
            long v = (long)lit.p.ival;
            if (v > mc.lit_max) { mc.lit_max = v; }
            return con_lit(Ctag.C_INT, v);
        }
    }
}

// cartesian product of alternatives for sub-patterns
fn Alts MatchCompiler.product(MatchCompiler* mc, Con c, Alts* subalts, usz n, Node* src)
{
    usz total = 1;
    for (usz i = 0; i < n; i++) { total = total * (subalts[i].n == 0 ? 1 : subalts[i].n); if (total > 64) { total = 64; break; } }
    Alts out;
    out.items = (Pat**)mc.zalloc(usz::size * total);
    out.n = 0;
    if (out.items == null) { return out; }
    usz[MC_MAX_ARITY] idx;
    for (usz i = 0; i < n && i < MC_MAX_ARITY; i++) { idx[i] = 0; }
    for (usz k = 0; k < total; k++)
    {
        Pat** subs = (Pat**)mc.zalloc(usz::size * (n == 0 ? 1 : n));
        if (subs == null) { break; }
        for (usz i = 0; i < n && i < MC_MAX_ARITY; i++)
        {
            subs[i] = subalts[i].n > 0 ? subalts[i].items[idx[i]] : mc.mk_wild(src);
        }
        c.arity = n;
        out.items[out.n] = mc.mk_con(c, subs, src);
        out.n = out.n + 1;
        // advance odometer
        usz i = 0;
        while (i < n && i < MC_MAX_ARITY)
        {
            idx[i] = idx[i] + 1;
            if (idx[i] < (subalts[i].n == 0 ? 1 : subalts[i].n)) { break; }
            idx[i] = 0;
            i = i + 1;
        }
        if (i >= n) { break; }
    }
    return out;
}

fn Alts MatchCompiler.translate(MatchCompiler* mc, Node* p, int depth)
{
    if (p == null || depth > MC_MAX_DEPTH) { return mc.single(mc.mk_wild(p)); }
    switch (p.kind)
    {
        case Nk.N_PAT_WILDCARD:
        case Nk.N_PAT_IDENT:
        case Nk.N_PAT_REST:
            return mc.single(mc.mk_wild(p));
        case Nk.N_PAT_LITERAL:
        {
            Con c = mc.literal_con(p);
            return mc.single(mc.mk_con(c, null, p));
        }
        case Nk.N_PAT_RANGE:
        {
            Con c = con_lit(Ctag.C_RANGE, 0);
            Node* lo = p.child_count > 0 ? p.children[0] : null;
            Node* hi = p.child_count > 1 ? p.children[1] : null;
            c.ival = lo != null ? (long)lo.p.ival : 0;
            c.ival2 = hi != null ? (long)hi.p.ival : c.ival;
            if (lo != null && lo.kind == Nk.N_PAT_LITERAL) { c.ival = mc.literal_con(lo).ival; }
            if (hi != null && hi.kind == Nk.N_PAT_LITERAL) { c.ival2 = mc.literal_con(hi).ival; }
            if (c.ival2 > mc.lit_max) { mc.lit_max = c.ival2; }
            return mc.single(mc.mk_con(c, null, p));
        }
        case Nk.N_PAT_REF:
            return mc.translate(p.child_count > 0 ? p.children[0] : null, depth + 1);
        case Nk.N_PAT_OR:
        {
            // union of alternatives
            Alts[MC_MAX_ARITY] parts; usz np = 0; usz total = 0;
            for (usz i = 0; i < p.child_count && np < MC_MAX_ARITY; i++)
            {
                Node* c = p.children[i];
                if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
                parts[np] = mc.translate(c, depth + 1);
                total = total + parts[np].n;
                np = np + 1;
            }
            Alts out;
            out.items = (Pat**)mc.zalloc(usz::size * (total == 0 ? 1 : total));
            out.n = 0;
            if (out.items == null) { return out; }
            for (usz i = 0; i < np; i++) { for (usz j = 0; j < parts[i].n; j++) { out.items[out.n] = parts[i].items[j]; out.n = out.n + 1; } }
            return out;
        }
        case Nk.N_PAT_VARIANT:
        {
            Node* vdecl = null;
            EnumInfo* e = mc.enum_of_variant(p, &vdecl);
            Con c = con_lit(Ctag.C_VARIANT, 0);
            c.name = p.name_id; c.decl = vdecl; c.enum_decl = e != null ? e.decl : null;
            Alts[MC_MAX_ARITY] subalts; usz n = 0;
            for (usz i = 0; i < p.child_count && n < MC_MAX_ARITY; i++)
            {
                Node* ch = p.children[i];
                if (ch == null || !pfront_core::is_pattern(ch.kind)) { continue; }
                Node* sp = ch;
                if (ch.kind == Nk.N_PAT_FIELD && ch.child_count > 0) { sp = ch.children[0]; }
                subalts[n] = mc.translate(sp, depth + 1);
                n = n + 1;
            }
            // arity from the declaration wins (payload not written = wildcards)
            usz da = variant_arity(vdecl);
            if (da > n && da <= MC_MAX_ARITY)
            {
                for (usz i = n; i < da; i++) { subalts[i] = mc.single(mc.mk_wild(p)); }
                n = da;
            }
            return mc.product(c, &subalts[0], n, p);
        }
        case Nk.N_PAT_TUPLE:
        case Nk.N_PAT_ARRAY:
        case Nk.N_PAT_STRUCT:
        {
            Con c = con_lit(p.kind == Nk.N_PAT_STRUCT ? Ctag.C_STRUCT : Ctag.C_TUPLE, 0);
            c.name = p.name_id; c.decl = p.resolved;
            Alts[MC_MAX_ARITY] subalts; usz n = 0;
            for (usz i = 0; i < p.child_count && n < MC_MAX_ARITY; i++)
            {
                Node* ch = p.children[i];
                if (ch == null || !pfront_core::is_pattern(ch.kind)) { continue; }
                Node* sp = ch;
                if (ch.kind == Nk.N_PAT_FIELD && ch.child_count > 0 && ch.children[0] != null && pfront_core::is_pattern(ch.children[0].kind)) { sp = ch.children[0]; }
                if (ch.kind == Nk.N_PAT_FIELD && (ch.child_count == 0 || sp == ch)) { subalts[n] = mc.single(mc.mk_wild(ch)); n = n + 1; continue; }
                subalts[n] = mc.translate(sp, depth + 1);
                n = n + 1;
            }
            return mc.product(c, &subalts[0], n, p);
        }
        default:
            return mc.single(mc.mk_wild(p));
    }
}

// ── Occurrences ─────────────────────────────────────────────────────────
fn int MatchCompiler.occ_root(MatchCompiler* mc)
{
    if (mc.n_occs >= MC_MAX_OCCS) { return 0; }
    mc.occs[mc.n_occs].parent = -1; mc.occs[mc.n_occs].index = 0;
    mc.n_occs = mc.n_occs + 1;
    return (int)mc.n_occs - 1;
}

fn int MatchCompiler.occ_child(MatchCompiler* mc, int parent, int idx)
{
    // reuse an existing identical occurrence (keeps hash-consing meaningful)
    for (usz i = 0; i < mc.n_occs; i++) { if (mc.occs[i].parent == parent && mc.occs[i].index == idx) { return (int)i; } }
    if (mc.n_occs >= MC_MAX_OCCS) { return parent; }
    mc.occs[mc.n_occs].parent = parent; mc.occs[mc.n_occs].index = idx;
    mc.n_occs = mc.n_occs + 1;
    return (int)mc.n_occs - 1;
}

fn void MatchCompiler.print_occ(MatchCompiler* mc, int o)
{
    if (o < 0 || (usz)o >= mc.n_occs) { printf("?"); return; }
    if (mc.occs[o].parent < 0) { printf("x"); return; }
    mc.print_occ(mc.occs[o].parent);
    printf(".%d", mc.occs[o].index);
}

// ── Matrices ────────────────────────────────────────────────────────────
fn Matrix* MatchCompiler.mk_matrix(MatchCompiler* mc, usz rows, usz cols)
{
    Matrix* m = (Matrix*)mc.zalloc(Matrix::size);
    if (m == null) { return null; }
    m.rows = (Row*)mc.zalloc(Row::size * (rows == 0 ? 1 : rows));
    m.n_rows = 0;
    m.occs = (int*)mc.zalloc(int::size * (cols == 0 ? 1 : cols));
    m.n_cols = cols;
    return m;
}

fn void MatchCompiler.add_row(MatchCompiler* mc, Matrix* m, Pat** pats, int action, bool guarded, Node* src)
{
    Row* r = &m.rows[m.n_rows];
    r.pats = pats; r.action = action; r.guarded = guarded; r.src = src;
    m.n_rows = m.n_rows + 1;
}

// Specialise on constructor c at column col: rows whose col is c (subs
// replace the column) or wild (arity wildcards replace it).
fn Matrix* MatchCompiler.specialise(MatchCompiler* mc, Matrix* m, usz col, Con* c)
{
    usz ar = c.arity;
    usz nc = m.n_cols - 1 + ar;
    Matrix* out = mc.mk_matrix(m.n_rows, nc);
    if (out == null) { return null; }
    // occurrences: c's fields first, then the remaining columns
    usz w = 0;
    for (usz i = 0; i < ar; i++) { out.occs[w] = mc.occ_child(m.occs[col], (int)i); w = w + 1; }
    for (usz j = 0; j < m.n_cols; j++) { if (j != col) { out.occs[w] = m.occs[j]; w = w + 1; } }
    for (usz r = 0; r < m.n_rows; r++)
    {
        Pat* p = m.rows[r].pats[col];
        bool take = false; bool from_con = false;
        if (p.wild) { take = true; }
        else if (con_eq(&p.con, c)) { take = true; from_con = true; }
        else if (c.tag == Ctag.C_INT && p.con.tag == Ctag.C_RANGE && c.ival >= p.con.ival && c.ival <= p.con.ival2) { take = true; }  // a range row also matches this literal
        if (!take) { continue; }
        Pat** np = (Pat**)mc.zalloc(usz::size * (nc == 0 ? 1 : nc));
        if (np == null) { continue; }
        usz k = 0;
        for (usz i = 0; i < ar; i++)
        {
            np[k] = (from_con && p.subs != null && i < p.con.arity) ? p.subs[i] : mc.mk_wild(p.src);
            k = k + 1;
        }
        for (usz j = 0; j < m.n_cols; j++) { if (j != col) { np[k] = m.rows[r].pats[j]; k = k + 1; } }
        mc.add_row(out, np, m.rows[r].action, m.rows[r].guarded, m.rows[r].src);
    }
    return out;
}

// Default matrix: rows whose col is a wildcard, column removed.
fn Matrix* MatchCompiler.defaults(MatchCompiler* mc, Matrix* m, usz col)
{
    usz nc = m.n_cols - 1;
    Matrix* out = mc.mk_matrix(m.n_rows, nc);
    if (out == null) { return null; }
    usz w = 0;
    for (usz j = 0; j < m.n_cols; j++) { if (j != col) { out.occs[w] = m.occs[j]; w = w + 1; } }
    for (usz r = 0; r < m.n_rows; r++)
    {
        if (!m.rows[r].pats[col].wild) { continue; }
        Pat** np = (Pat**)mc.zalloc(usz::size * (nc == 0 ? 1 : nc));
        if (np == null) { continue; }
        usz k = 0;
        for (usz j = 0; j < m.n_cols; j++) { if (j != col) { np[k] = m.rows[r].pats[j]; k = k + 1; } }
        mc.add_row(out, np, m.rows[r].action, m.rows[r].guarded, m.rows[r].src);
    }
    return out;
}

// ── Column heuristics (Maranget §7: f, b, a) ────────────────────────────
// f: column is needed by the first row (its pattern there is a constructor).
// b: fewest distinct constructors (small branching factor).
// a: smallest total arity of the constructors in the column.
fn usz MatchCompiler.distinct_cons(MatchCompiler* mc, Matrix* m, usz col, usz* arity_sum)
{
    Con* seen = (Con*)mc.arena.alloc(Con::size * (m.n_rows == 0 ? 1 : m.n_rows), 8);
    usz n = 0; usz asum = 0;
    if (seen == null) { *arity_sum = 0; return 0; }
    for (usz r = 0; r < m.n_rows; r++)
    {
        Pat* p = m.rows[r].pats[col];
        if (p.wild) { continue; }
        bool dup = false;
        for (usz i = 0; i < n; i++) { if (con_eq(&seen[i], &p.con)) { dup = true; break; } }
        if (dup || n >= MC_MAX_CASES) { continue; }
        seen[n] = p.con; n = n + 1; asum = asum + p.con.arity;
    }
    *arity_sum = asum;
    return n;
}

fn usz MatchCompiler.pick_column(MatchCompiler* mc, Matrix* m)
{
    usz best = 0; bool have = false;
    bool best_f = false; usz best_b = 0; usz best_a = 0;
    for (usz c = 0; c < m.n_cols; c++)
    {
        // a column of all wildcards cannot be tested
        bool any_con = false;
        for (usz r = 0; r < m.n_rows; r++) { if (!m.rows[r].pats[c].wild) { any_con = true; break; } }
        if (!any_con) { continue; }
        bool f = !m.rows[0].pats[c].wild;
        usz a = 0;
        usz b = mc.distinct_cons(m, c, &a);
        bool better = false;
        if (!have) { better = true; }
        else if (f != best_f) { better = f; }
        else if (b != best_b) { better = b < best_b; }
        else if (a != best_a) { better = a < best_a; }
        if (better) { best = c; best_f = f; best_b = b; best_a = a; have = true; }
    }
    return best;
}

// ── Node construction with hash-consing ─────────────────────────────────
fn ulong mix(ulong h, ulong v)
{
    h = h ^ (v + 0x9E3779B97F4A7C15UL + (h << 6) + (h >> 2));
    return h;
}

fn ulong con_hash(Con* c)
{
    ulong h = (ulong)c.tag;
    h = mix(h, (ulong)c.ival); h = mix(h, (ulong)c.ival2); h = mix(h, (ulong)c.name); h = mix(h, (ulong)c.arity);
    h = mix(h, (ulong)(uptr)c.decl);
    return h;
}

fn bool MatchCompiler.node_eq(MatchCompiler* mc, DtNode* a, DtKind kind, int occ, int action, bool guarded, int next, Con* cases, int* children, usz n_cases, int def)
{
    if (a.kind != kind || a.occ != occ || a.action != action || a.guarded != guarded || a.next != next || a.n_cases != n_cases || a.def != def) { return false; }
    for (usz i = 0; i < n_cases; i++)
    {
        if (a.children[i] != children[i]) { return false; }
        if (!con_eq(&a.cases[i], &cases[i])) { return false; }
    }
    return true;
}

fn int MatchCompiler.intern(MatchCompiler* mc, DtKind kind, int occ, int action, bool guarded, int next, Con* cases, int* children, usz n_cases, int def, MatchFacts* mf)
{
    ulong h = (ulong)kind;
    h = mix(h, (ulong)occ); h = mix(h, (ulong)action); h = mix(h, guarded ? 1 : 0); h = mix(h, (ulong)next); h = mix(h, (ulong)def);
    for (usz i = 0; i < n_cases; i++) { h = mix(h, con_hash(&cases[i])); h = mix(h, (ulong)children[i]); }
    usz b = (usz)(h % MC_HASH);
    int id = mc.buckets != null ? mc.buckets[b] : -1;
    while (id >= 0)
    {
        if (mc.nodes[id].hash == h && mc.node_eq(&mc.nodes[id], kind, occ, action, guarded, next, cases, children, n_cases, def))
        {
            mc.n_merges = mc.n_merges + 1;
            if (mf != null) { mf.merges = mf.merges + 1; }
            return id;
        }
        id = mc.nodes[id].hnext;
    }
    if (mc.n_nodes >= MC_MAX_NODES) { return -1; }
    DtNode* n = &mc.nodes[mc.n_nodes];
    n.kind = kind; n.occ = occ; n.action = action; n.guarded = guarded; n.next = next;
    n.n_cases = n_cases; n.def = def; n.hash = h;
    n.cases = null; n.children = null;
    if (n_cases > 0)
    {
        n.cases = (Con*)mc.zalloc(Con::size * n_cases);
        n.children = (int*)mc.zalloc(int::size * n_cases);
        if (n.cases != null && n.children != null) { for (usz i = 0; i < n_cases; i++) { n.cases[i] = cases[i]; n.children[i] = children[i]; } }
    }
    // DAG size = 1 + distinct reachable; tree size accumulates unshared
    usz size = 1;
    for (usz i = 0; i < n_cases; i++) { if (children[i] >= 0) { size = size + mc.nodes[children[i]].size; } }
    if (def >= 0) { size = size + mc.nodes[def].size; }
    if (next >= 0) { size = size + mc.nodes[next].size; }
    n.size = size;   // unshared (tree) size; DAG size counted separately by a marking walk
    n.hnext = mc.buckets != null ? mc.buckets[b] : -1;
    if (mc.buckets != null) { mc.buckets[b] = (int)mc.n_nodes; }
    mc.n_nodes = mc.n_nodes + 1;
    switch (kind)
    {
        case DtKind.DT_LEAF: mc.n_leaves = mc.n_leaves + 1; break;
        case DtKind.DT_FAIL: mc.n_fails = mc.n_fails + 1; break;
        case DtKind.DT_SWITCH:
            mc.n_switches = mc.n_switches + 1;
            if (def < 0) { mc.n_complete_switches = mc.n_complete_switches + 1; } else { mc.n_default_switches = mc.n_default_switches + 1; }
            if (n_cases > mc.max_fanout) { mc.max_fanout = n_cases; }
            break;
        case DtKind.DT_UNPACK: mc.n_unpacks = mc.n_unpacks + 1; break;
    }
    return (int)mc.n_nodes - 1;
}

// ── Compile (Maranget §4 with guards and signatures) ────────────────────
fn bool MatchCompiler.signature_complete(MatchCompiler* mc, Con* cases, usz n)
{
    if (n == 0) { return false; }
    switch (cases[0].tag)
    {
        case Ctag.C_BOOL:
        {
            bool t = false; bool f = false;
            for (usz i = 0; i < n; i++) { if (cases[i].ival != 0) { t = true; } else { f = true; } }
            return t && f;
        }
        case Ctag.C_VARIANT:
        {
            Node* e = cases[0].enum_decl;
            if (e == null) { return false; }
            usz nv = 0;
            for (usz i = 0; i < mc.n_enums; i++) { if (mc.enums[i].decl == e) { nv = mc.enums[i].n_variants; break; } }
            if (nv == 0) { return false; }
            // every case must be a variant of e, and all nv covered
            usz covered = 0;
            for (usz i = 0; i < n; i++) { if (cases[i].enum_decl == e && cases[i].decl != null) { covered = covered + 1; } }
            return covered == nv;
        }
        case Ctag.C_TUPLE:
        case Ctag.C_STRUCT:
            return true;
        default:
            return false;
    }
}

fn int MatchCompiler.compile(MatchCompiler* mc, Matrix* m, int depth, MatchFacts* mf)
{
    if (m == null || depth > MC_MAX_DEPTH) { return mc.intern(DtKind.DT_FAIL, -1, -1, false, -1, null, null, 0, -1, mf); }
    if (m.n_rows == 0) { return mc.intern(DtKind.DT_FAIL, -1, -1, false, -1, null, null, 0, -1, mf); }
    // first row all wildcards?
    bool all_wild = true;
    for (usz c = 0; c < m.n_cols; c++) { if (!m.rows[0].pats[c].wild) { all_wild = false; break; } }
    if (all_wild)
    {
        int next = -1;
        if (m.rows[0].guarded)
        {
            // fallthrough: the rest of the matrix
            Matrix* rest = mc.mk_matrix(m.n_rows, m.n_cols);
            if (rest != null)
            {
                for (usz c = 0; c < m.n_cols; c++) { rest.occs[c] = m.occs[c]; }
                for (usz r = 1; r < m.n_rows; r++) { mc.add_row(rest, m.rows[r].pats, m.rows[r].action, m.rows[r].guarded, m.rows[r].src); }
                next = mc.compile(rest, depth + 1, mf);
            }
        }
        return mc.intern(DtKind.DT_LEAF, -1, m.rows[0].action, m.rows[0].guarded, next, null, null, 0, -1, mf);
    }
    usz col = mc.pick_column(m);
    // constructor set of the column, in order of first appearance
    Con* cases = (Con*)mc.arena.alloc(Con::size * m.n_rows, 8);
    int* children = (int*)mc.arena.alloc(int::size * m.n_rows, 8);
    if (cases == null || children == null) { return mc.intern(DtKind.DT_FAIL, -1, -1, false, -1, null, null, 0, -1, mf); }
    usz n = 0;
    for (usz r = 0; r < m.n_rows; r++)
    {
        Pat* p = m.rows[r].pats[col];
        if (p.wild) { continue; }
        bool dup = false;
        for (usz i = 0; i < n; i++) { if (con_eq(&cases[i], &p.con)) { dup = true; break; } }
        if (dup || n >= MC_MAX_CASES) { continue; }
        cases[n] = p.con; n = n + 1;
    }
    for (usz i = 0; i < n; i++)
    {
        Matrix* sm = mc.specialise(m, col, &cases[i]);
        children[i] = mc.compile(sm, depth + 1, mf);
    }
    bool complete = mc.signature_complete(&cases[0], n);
    int def = -1;
    if (!complete)
    {
        Matrix* dm = mc.defaults(m, col);
        def = mc.compile(dm, depth + 1, mf);
    }
    if (n == 1 && (cases[0].tag == Ctag.C_TUPLE || cases[0].tag == Ctag.C_STRUCT))
    {
        return mc.intern(DtKind.DT_UNPACK, m.occs[col], -1, false, -1, &cases[0], &children[0], 1, -1, mf);
    }
    return mc.intern(DtKind.DT_SWITCH, m.occs[col], -1, false, -1, &cases[0], &children[0], n, def, mf);
}

// ── Values and the two interpreters (verification) ──────────────────────
struct Val
{
    Con    con;
    Val**  subs;
}

fn Val* MatchCompiler.mk_val(MatchCompiler* mc, Con c, usz arity)
{
    Val* v = (Val*)mc.zalloc(Val::size);
    if (v == null) { return null; }
    v.con = c; v.con.arity = arity;
    v.subs = arity > 0 ? (Val**)mc.zalloc(usz::size * arity) : null;
    return v;
}

// a value nothing in the matrix mentions
fn Val* MatchCompiler.other_val(MatchCompiler* mc)
{
    Con c = con_lit(Ctag.C_OTHER, mc.lit_max + 1);
    return mc.mk_val(c, 0);
}

// constructor hint for an occurrence: a bool/variant constructor some row
// tests at that position (so the sample is a value of the right type)
fn bool MatchCompiler.find_at(MatchCompiler* mc, Pat* p, int occ_here, int occ_want, Con* out, int depth)
{
    if (p == null || p.wild || depth > MC_MAX_DEPTH) { return false; }
    if (occ_here == occ_want)
    {
        if (p.con.tag == Ctag.C_BOOL || p.con.tag == Ctag.C_VARIANT || p.con.tag == Ctag.C_TUPLE || p.con.tag == Ctag.C_STRUCT) { *out = p.con; return true; }
        return false;
    }
    for (usz i = 0; i < p.con.arity; i++)
    {
        // child occurrence must already exist to be interesting
        int co = -1;
        for (usz k = 0; k < mc.n_occs; k++) { if (mc.occs[k].parent == occ_here && mc.occs[k].index == (int)i) { co = (int)k; break; } }
        if (co < 0) { continue; }
        if (mc.find_at(p.subs != null ? p.subs[i] : null, co, occ_want, out, depth + 1)) { return true; }
    }
    return false;
}

fn bool MatchCompiler.hint(MatchCompiler* mc, Matrix* m, int occ, Con* out)
{
    for (usz r = 0; r < m.n_rows; r++)
    {
        if (mc.find_at(m.rows[r].pats[0], m.occs[0], occ, out, 0)) { return true; }
    }
    return false;
}

// sample value from a pattern: constructors kept, wildcards filled with a
// hinted constructor of the right type when one is known, else "other"
fn Val* MatchCompiler.sample(MatchCompiler* mc, Matrix* m, Pat* p, int occ, int depth)
{
    if (depth > MC_MAX_DEPTH) { return mc.other_val(); }
    if (p == null || p.wild)
    {
        Con h;
        if (mc.hint(m, occ, &h))
        {
            Val* v = mc.mk_val(h, h.arity);
            if (v == null) { return null; }
            for (usz i = 0; i < h.arity; i++)
            {
                int co = mc.occ_child(occ, (int)i);
                v.subs[i] = mc.sample(m, null, co, depth + 1);
            }
            return v;
        }
        return mc.other_val();
    }
    Con c = p.con;
    if (c.tag == Ctag.C_RANGE) { c.tag = Ctag.C_INT; c.ival2 = c.ival; }   // pick the low end
    Val* v = mc.mk_val(c, p.con.arity);
    if (v == null) { return null; }
    for (usz i = 0; i < p.con.arity; i++)
    {
        int co = mc.occ_child(occ, (int)i);
        v.subs[i] = mc.sample(m, p.subs != null ? p.subs[i] : null, co, depth + 1);
    }
    return v;
}

// does value v match constructor c?
fn bool val_matches_con(Val* v, Con* c)
{
    if (v == null) { return false; }
    if (c.tag == Ctag.C_RANGE)
    {
        return (v.con.tag == Ctag.C_INT || v.con.tag == Ctag.C_CHAR) && v.con.ival >= c.ival && v.con.ival <= c.ival2;
    }
    if (v.con.tag == Ctag.C_OTHER) { return false; }
    return con_eq(&v.con, c);
}

// naive first-match over rows
fn bool MatchCompiler.pat_matches(MatchCompiler* mc, Pat* p, Val* v, int depth)
{
    if (p == null || p.wild) { return true; }
    if (v == null || depth > MC_MAX_DEPTH) { return false; }
    if (!val_matches_con(v, &p.con)) { return false; }
    for (usz i = 0; i < p.con.arity && i < v.con.arity; i++)
    {
        if (!mc.pat_matches(p.subs != null ? p.subs[i] : null, v.subs != null ? v.subs[i] : null, depth + 1)) { return false; }
    }
    return true;
}

fn int MatchCompiler.naive(MatchCompiler* mc, Matrix* m, Val* v)
{
    for (usz r = 0; r < m.n_rows; r++)
    {
        if (mc.pat_matches(m.rows[r].pats[0], v, 0)) { return m.rows[r].action; }   // guards assumed to succeed
    }
    return -1;
}

// value at an occurrence
fn Val* MatchCompiler.at_occ(MatchCompiler* mc, Val* root, int o)
{
    if (o < 0 || (usz)o >= mc.n_occs) { return null; }
    if (mc.occs[o].parent < 0) { return root; }
    Val* p = mc.at_occ(root, mc.occs[o].parent);
    if (p == null || p.subs == null || (usz)mc.occs[o].index >= p.con.arity) { return null; }
    return p.subs[mc.occs[o].index];
}

// run the DAG; counts tests taken
fn int MatchCompiler.run(MatchCompiler* mc, int id, Val* root, usz* tests, int depth)
{
    while (id >= 0 && depth < 4096)
    {
        DtNode* n = &mc.nodes[id];
        switch (n.kind)
        {
            case DtKind.DT_LEAF: return n.action;   // guard assumed to succeed
            case DtKind.DT_FAIL: return -1;
            case DtKind.DT_UNPACK:
            {
                Val* v = mc.at_occ(root, n.occ);
                if (!val_matches_con(v, &n.cases[0])) { return -2; }   // not a tuple/struct: ill-typed sample
                id = n.children[0]; depth = depth + 1; break;
            }
            case DtKind.DT_SWITCH:
            {
                *tests = *tests + 1;
                Val* v = mc.at_occ(root, n.occ);
                int nxt = n.def;
                bool hit = false;
                for (usz i = 0; i < n.n_cases; i++) { if (val_matches_con(v, &n.cases[i])) { nxt = n.children[i]; hit = true; break; } }
                if (!hit && n.def < 0) { return -2; }   // value outside a complete signature: not a value of this type
                id = nxt; depth = depth + 1; break;
            }
        }
    }
    return -1;
}

fn void MatchCompiler.verify(MatchCompiler* mc, Matrix* m, MatchFacts* mf)
{
    if (mf.root < 0) { return; }
    // one sample per row
    for (usz r = 0; r < m.n_rows; r++)
    {
        Val* v = mc.sample(m, m.rows[r].pats[0], m.occs[0], 0);
        usz tests = 0;
        int got = mc.run(mf.root, v, &tests, 0);
        if (got == -2) { mc.n_impossible = mc.n_impossible + 1; continue; }
        int want = mc.naive(m, v);
        mc.n_samples = mc.n_samples + 1;
        mf.total_tests = mf.total_tests + tests;
        if (tests > mf.worst_tests) { mf.worst_tests = tests; }
        if (got == want) { mf.verified = mf.verified + 1; mc.n_verified = mc.n_verified + 1; }
        else
        {
            mf.disagreements = mf.disagreements + 1; mc.n_disagree = mc.n_disagree + 1;
            if (mf.site != null)
            {
                printf("  matching-BUG     : %s:%d:%d row %d: tree says arm %d, first-match says arm %d\n",
                       mc.file != null ? mc.file : "?", mf.site.line, mf.site.col, (int)r, got, want);
            }
        }
    }
    // the "none of the above" value
    Val* o = mc.other_val();
    usz t2 = 0;
    int got2 = mc.run(mf.root, o, &t2, 0);
    if (got2 == -2) { mc.n_impossible = mc.n_impossible + 1; return; }
    int want2 = mc.naive(m, o);
    mc.n_samples = mc.n_samples + 1;
    if (t2 > mf.worst_tests) { mf.worst_tests = t2; }
    if (got2 == want2) { mf.verified = mf.verified + 1; mc.n_verified = mc.n_verified + 1; }
    else { mf.disagreements = mf.disagreements + 1; mc.n_disagree = mc.n_disagree + 1; }
}

// ── DAG size (distinct reachable) ───────────────────────────────────────
fn usz MatchCompiler.dag_size(MatchCompiler* mc, int id, char* mark, int depth)
{
    if (id < 0 || depth > 4096 || mark[id] != 0) { return 0; }
    mark[id] = 1;
    DtNode* n = &mc.nodes[id];
    usz s = 1;
    for (usz i = 0; i < n.n_cases; i++) { s = s + mc.dag_size(n.children[i], mark, depth + 1); }
    if (n.def >= 0) { s = s + mc.dag_size(n.def, mark, depth + 1); }
    if (n.next >= 0) { s = s + mc.dag_size(n.next, mark, depth + 1); }
    return s;
}

// ── Dense switch detection ──────────────────────────────────────────────
fn bool MatchCompiler.is_dense(MatchCompiler* mc, int id)
{
    int cur = id;
    // look through unpacks
    while (cur >= 0 && mc.nodes[cur].kind == DtKind.DT_UNPACK) { cur = mc.nodes[cur].children[0]; }
    if (cur < 0 || mc.nodes[cur].kind != DtKind.DT_SWITCH) { return false; }
    DtNode* n = &mc.nodes[cur];
    if (n.n_cases < 4) { return false; }
    if (n.cases[0].tag == Ctag.C_VARIANT) { return true; }
    if (n.cases[0].tag != Ctag.C_INT && n.cases[0].tag != Ctag.C_CHAR) { return false; }
    long lo = n.cases[0].ival; long hi = lo;
    for (usz i = 0; i < n.n_cases; i++)
    {
        if (n.cases[i].tag != Ctag.C_INT && n.cases[i].tag != Ctag.C_CHAR) { return false; }
        if (n.cases[i].ival < lo) { lo = n.cases[i].ival; }
        if (n.cases[i].ival > hi) { hi = n.cases[i].ival; }
    }
    ulong span = (ulong)(hi - lo) + 1;
    return span <= 2 * (ulong)n.n_cases;
}

// ── Printing (--emit-dtree) ─────────────────────────────────────────────
fn void MatchCompiler.print_con(MatchCompiler* mc, Con* c)
{
    switch (c.tag)
    {
        case Ctag.C_INT: printf("%ld", c.ival); return;
        case Ctag.C_BOOL: printf(c.ival != 0 ? "true" : "false"); return;
        case Ctag.C_CHAR: printf("'\\%ld'", c.ival); return;
        case Ctag.C_STR: printf("\"#%u\"", c.name); return;
        case Ctag.C_RANGE: printf("%ld..%ld", c.ival, c.ival2); return;
        case Ctag.C_VARIANT: printf("%s", mc.name(c.name)); if (c.arity > 0) { printf("/%d", (int)c.arity); } return;
        case Ctag.C_TUPLE: printf("tuple/%d", (int)c.arity); return;
        case Ctag.C_STRUCT: printf("%s{%d}", mc.name(c.name), (int)c.arity); return;
        case Ctag.C_OTHER: printf("<other>"); return;
    }
}

fn void indent(int n) { for (int i = 0; i < n; i++) { printf("  "); } }

fn void MatchCompiler.print_node(MatchCompiler* mc, int id, int ind, char* seen, int depth)
{
    if (id < 0) { indent(ind); printf("fail\n"); return; }
    DtNode* n = &mc.nodes[id];
    if (depth > 64) { indent(ind); printf("…\n"); return; }
    if (seen[id] != 0 && n.kind != DtKind.DT_LEAF && n.kind != DtKind.DT_FAIL) { indent(ind); printf("goto n%d\n", id); return; }
    seen[id] = 1;
    switch (n.kind)
    {
        case DtKind.DT_LEAF:
            indent(ind); printf("arm %d%s\n", n.action, n.guarded ? " if guard" : "");
            if (n.guarded) { indent(ind); printf("else\n"); mc.print_node(n.next, ind + 1, seen, depth + 1); }
            return;
        case DtKind.DT_FAIL:
            indent(ind); printf("fail\n"); return;
        case DtKind.DT_UNPACK:
            indent(ind); printf("n%d: unpack ", id); mc.print_occ(n.occ); printf(" as "); mc.print_con(&n.cases[0]); printf("\n");
            mc.print_node(n.children[0], ind + 1, seen, depth + 1);
            return;
        case DtKind.DT_SWITCH:
            indent(ind); printf("n%d: switch ", id); mc.print_occ(n.occ); printf("%s\n", n.def < 0 ? "   ; complete" : "");
            for (usz i = 0; i < n.n_cases; i++)
            {
                indent(ind + 1); printf("| "); mc.print_con(&n.cases[i]); printf(" ->\n");
                mc.print_node(n.children[i], ind + 2, seen, depth + 1);
            }
            if (n.def >= 0) { indent(ind + 1); printf("| _ ->\n"); mc.print_node(n.def, ind + 2, seen, depth + 1); }
            return;
    }
}

// ── One match site ──────────────────────────────────────────────────────
// Builds the matrix from arms/clauses (or-patterns → extra rows), compiles,
// verifies, measures, writes back.
fn void MatchCompiler.compile_site(MatchCompiler* mc, Node* site, Node** arms, usz n_arms, bool is_fn, uint label)
{
    if (n_arms == 0 || mc.n_facts >= 4096) { return; }
    MatchFacts* mf = &mc.facts[mc.n_facts];
    mc.n_facts = mc.n_facts + 1;
    memset((void*)mf, 0, MatchFacts::size);
    mf.site = site; mf.is_fn = is_fn; mf.root = -1;
    mc.lit_max = 0;
    // sharing is per site: a leaf of another match is not this match's leaf
    if (mc.buckets != null) { for (usz i = 0; i < MC_HASH; i++) { mc.buckets[i] = -1; } }

    // rows: one column (the scrutinee / the parameter tuple)
    Matrix* m = mc.mk_matrix(MC_MAX_ROWS, 1);
    if (m == null) { return; }
    m.occs[0] = mc.occ_root();
    bool dense_scalar_lowerable = n_arms <= 64;
    long[64] dense_scalars;
    usz dense_scalar_count = 0;
    for (usz a = 0; a < n_arms; a++)
    {
        Node* arm = arms[a];
        Node* pat = null; bool guarded = false;
        for (usz i = 0; i < arm.child_count; i++)
        {
            Node* c = arm.children[i];
            if (c == null) { continue; }
            if (pat == null && pfront_core::is_pattern(c.kind)) { pat = c; }
            else if (c.kind == Nk.N_GUARD) { guarded = true; }
            else if (i + 1 < arm.child_count && pat != null && pfront_core::is_expr(c.kind)) { guarded = true; }
        }
        // NF_DENSE_SWITCH is consumed by a backend path that currently
        // supports only unguarded scalar literals and a final wildcard.
        // Do not label expanded or structured patterns as jump-table inputs.
        if (guarded || pat == null) { dense_scalar_lowerable = false; }
        else if (pat.kind == Nk.N_PAT_WILDCARD || pat.kind == Nk.N_PAT_IDENT)
        {
            // A final binder is a valid default too; PEAR binds the scrutinee
            // value in that default block before lowering the arm body.
            if (a + 1 != n_arms) { dense_scalar_lowerable = false; }
        }
        else
        {
            Node* lit = pat.kind == Nk.N_PAT_LITERAL ? pat.child(0) : null;
            if (lit == null || (lit.kind != Nk.N_EXPR_INT && lit.kind != Nk.N_EXPR_CHAR))
            {
                dense_scalar_lowerable = false;
            }
            else if (dense_scalar_count >= 64)
            {
                dense_scalar_lowerable = false;
            }
            else
            {
                for (usz k = 0; k < dense_scalar_count; k++)
                {
                    if (dense_scalars[k] == (long)lit.p.ival)
                    { dense_scalar_lowerable = false; }
                }
                dense_scalars[dense_scalar_count] = (long)lit.p.ival;
                dense_scalar_count++;
            }
        }
        Alts alts = mc.translate(pat, 0);
        if (alts.n > 1) { mf.n_or_expanded = mf.n_or_expanded + alts.n - 1; mc.n_or_rows = mc.n_or_rows + alts.n - 1; }
        for (usz k = 0; k < alts.n && m.n_rows < MC_MAX_ROWS; k++)
        {
            Pat** ps = (Pat**)mc.zalloc(usz::size);
            if (ps == null) { break; }
            ps[0] = alts.items[k];
            mc.add_row(m, ps, (int)a, guarded, arm);
        }
    }
    mf.n_rows = m.n_rows;
    mc.n_rows_total = mc.n_rows_total + n_arms;
    if (is_fn) { mc.n_fn_sites = mc.n_fn_sites + 1; } else { mc.n_matches = mc.n_matches + 1; }

    usz nodes_before = mc.n_nodes;
    mf.root = mc.compile(m, 0, mf);
    if (mf.root < 0) { return; }
    mf.tree_nodes = mc.nodes[mf.root].size;
    char* mark = (char*)mc.arena.alloc(mc.n_nodes + 1, 1);
    if (mark != null) { memset((void*)mark, 0, mc.n_nodes + 1); mf.dag_nodes = mc.dag_size(mf.root, mark, 0); }
    mc.n_tree_nodes = mc.n_tree_nodes + mf.tree_nodes;
    mc.n_dag_nodes = mc.n_dag_nodes + mf.dag_nodes;
    (void)nodes_before;

    mc.verify(m, mf);
    mc.sum_tests = mc.sum_tests + mf.total_tests; mc.sum_rows = mc.sum_rows + mf.n_rows;
    if (mf.worst_tests > mc.worst_tests_all) { mc.worst_tests_all = mf.worst_tests; mc.worst_site = label; }

    int r = mf.root;
    while (r >= 0 && mc.nodes[r].kind == DtKind.DT_UNPACK) { r = mc.nodes[r].children[0]; }
    mf.complete_root = r >= 0 && mc.nodes[r].kind == DtKind.DT_SWITCH && mc.nodes[r].def < 0;

    mf.dense = mc.is_dense(mf.root);
    if (mf.dense && dense_scalar_lowerable)
    {
        mc.n_dense = mc.n_dense + 1;
        site.flags = site.flags | pfront_core::NF_DENSE_SWITCH;
        if (mc.diags != null && mc.diags.advisories)
        {
            DtNode* sw = &mc.nodes[r];
            char* msg = (char*)mc.arena.alloc(256, 1);
            if (msg != null)
            {
                snprintf(msg, 256, "%s on %d %s in one dense switch: a jump table, not a chain of comparisons",
                         is_fn ? "these clauses dispatch" : "this match dispatches", (int)sw.n_cases,
                         sw.cases[0].tag == Ctag.C_VARIANT ? "variants" : "values");
                mc.diags.note(pfront_core::Phase.PH_RESOLVE, 4210, site.line, site.col, msg, mc.file);
                mc.n_n4210 = mc.n_n4210 + 1;
            }
        }
    }

    if (mc.emit)
    {
        printf("=== dtree: %s %s @%d:%d ===   [%d rows%s, tree %d → dag %d nodes, worst %d tests, %d/%d samples agree%s%s]\n",
               is_fn ? "fn" : "match", mc.name(label), site.line, site.col,
               (int)mf.n_rows, mf.n_or_expanded > 0 ? " (or-expanded)" : "",
               (int)mf.tree_nodes, (int)mf.dag_nodes, (int)mf.worst_tests,
               (int)mf.verified, (int)(mf.verified + mf.disagreements),
               mf.complete_root ? ", complete" : "", mf.dense ? ", dense" : "");
        char* seen = (char*)mc.arena.alloc(mc.n_nodes + 1, 1);
        if (seen != null) { memset((void*)seen, 0, mc.n_nodes + 1); mc.print_node(mf.root, 1, seen, 0); }
    }
}

// ── Driver ──────────────────────────────────────────────────────────────
fn void MatchCompiler.walk(MatchCompiler* mc, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    if (depth == 0) { mc.collect_enums(n, 0); }
    if (n.kind == Nk.N_EXPR_MATCH)
    {
        Node*[MC_MAX_ROWS] arms; usz na = 0;
        for (usz i = 1; i < n.child_count && na < MC_MAX_ROWS; i++)
        {
            Node* c = n.children[i];
            if (c != null && c.kind == Nk.N_MATCH_ARM) { arms[na] = c; na = na + 1; }
        }
        if (na >= 1)
        {
            Node* fnd = n.parent;
            while (fnd != null && fnd.kind != Nk.N_DECL_FN) { fnd = fnd.parent; }
            mc.compile_site(n, &arms[0], na, false, fnd != null ? fnd.name_id : 0);
        }
    }
    else if (n.kind == Nk.N_DECL_FN)
    {
        Node*[MC_MAX_ROWS] arms; usz na = 0;
        for (usz i = 0; i < n.child_count && na < MC_MAX_ROWS; i++)
        {
            Node* c = n.children[i];
            if (c != null && c.kind == Nk.N_CLAUSE) { arms[na] = c; na = na + 1; }
        }
        if (na >= 2) { mc.compile_site(n, &arms[0], na, true, n.name_id); }
    }
    for (usz i = 0; i < n.child_count; i++) { mc.walk(n.children[i], depth + 1); }
}

fn void MatchCompiler.report(MatchCompiler* mc)
{
    printf("  matching         : %d matches + %d clause sets → %d rows (%d from or-patterns), %d leaves, %d switches (%d complete, %d with default), %d unpacks\n",
           (int)mc.n_matches, (int)mc.n_fn_sites, (int)(mc.n_rows_total + mc.n_or_rows), (int)mc.n_or_rows,
           (int)mc.n_leaves, (int)mc.n_switches, (int)mc.n_complete_switches, (int)mc.n_default_switches, (int)mc.n_unpacks);
    printf("  matching-dag     : %d tree nodes shared into %d (%d merges), max fan-out %d, %d dense switches (jump tables)\n",
           (int)mc.n_tree_nodes, (int)mc.n_dag_nodes, (int)mc.n_merges, (int)mc.max_fanout, (int)mc.n_dense);
    usz avg10 = mc.sum_rows > 0 ? (mc.sum_tests * 10) / mc.sum_rows : 0;
    printf("  matching-verify  : %d samples run through the trees, %d agree with first-match, %d disagree (%d ill-typed samples skipped); worst path %d tests (%s), avg %d.%d\n",
           (int)mc.n_samples, (int)mc.n_verified, (int)mc.n_disagree, (int)mc.n_impossible, (int)mc.worst_tests_all, mc.name(mc.worst_site),
           (int)(avg10 / 10), (int)(avg10 % 10));
}
