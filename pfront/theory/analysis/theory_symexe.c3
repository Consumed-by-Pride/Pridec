// ============================================================================
// theory_symexe.c3 — Bounded symbolic execution with a real path solver
// ----------------------------------------------------------------------------
// Symbolic execution (King 1976; Cadar/Sen 2013) runs a function over
// SYMBOLIC inputs, forking at every branch and carrying a PATH CONDITION —
// the conjunction of branch outcomes taken so far. A path whose condition is
// unsatisfiable is pruned; a fault found on a satisfiable path is a real
// fault, with the path condition as its witness.
//
// What this engine is:
//
//   • PER FUNCTION. Each fn body is executed from a fresh state with its
//     parameters as symbolic variables. Variables are keyed by their BINDER
//     NODE (the resolver's `resolved` pointer), so shadowing is exact.
//   • FORKING at `if`, `match` (literal arms add `scrut == c` / `!= c`,
//     guards add themselves), `while` (one body iteration under the
//     condition, one exit path with every variable the body assigns
//     havocked and `¬cond` assumed), `&&`/`||` short-circuit as conjunction
//     atoms.
//   • A DECISION PROCEDURE, not a constant check. Every path keeps an
//     interval [lo,hi] and a set of excluded constants per variable, refined
//     from the path atoms to a fixpoint (`x > 5` tightens lo; `x != 0`
//     excludes; `x + 2 < 7` shifts). Atoms are then re-evaluated under those
//     facts; one that is FALSE makes the path infeasible. It is sound for
//     pruning — it only ever says "infeasible" when the arithmetic really is
//     contradictory — and incomplete, which is the correct failure mode.
//   • BOUNDED: per function ≤ 64 paths, depth ≤ 64, PC ≤ 64 atoms; a bound
//     hit ends the path, it never trades soundness for coverage.
//
// What it reports (only on FEASIBLE paths, only when DEFINITE):
//
//   W4050  division / modulo whose divisor is exactly 0 under the path
//          condition. `x / (n - n)` after const-fold, `a % 0` after
//          `if a == 0 { return }` on the other path — real faults, with the
//          witness printed.
//   N4051  a branch condition decided by the PATH (not by constants: those
//          are pfront_narrow's job and are skipped here): `if x > 5 { if
//          x < 3 { ... } }` — the inner condition is always false, and the
//          note says which earlier facts make it so.
//   W4052  `assert c` where c is false on a feasible path.
//
// Everything a path learns from `unsafe`, calls, field/index writes, refs,
// effects or anything else it does not model is HAVOC: the value becomes a
// fresh variable. Unknown means unknown; it never means zero.
// ============================================================================

module theory_symexe;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz cap, char* fmt, ...);

const usz  SX_MAX_VALS     = 8192;
const usz  SX_MAX_VARS     = 1024;
const usz  SX_STORE_CAP    = 128;
const usz  SX_PC_CAP       = 64;
const usz  SX_MAX_PATHS    = 64;      // per function
const int  SX_MAX_DEPTH    = 64;
const usz  SX_MAX_DIAGS    = 24;      // per file
const long SX_INF          = 4611686018427387903L;   // 2^62-1: saturating bounds
const usz  SX_NEQ_CAP      = 8;

enum SxKind : int
{
    SX_CONC, SX_VAR,
    SX_ADD, SX_SUB, SX_MUL, SX_DIV, SX_MOD,
    SX_EQ, SX_NE, SX_LT, SX_LE, SX_GT, SX_GE,
    SX_AND, SX_OR, SX_NOT
}

struct SxVal
{
    SxKind kind;
    long   c;        // SX_CONC value
    int    a;        // operands
    int    b;
    int    vix;      // SX_VAR index into names
}

// A variable's facts on one path.
struct SxFact
{
    long lo;
    long hi;
    long[SX_NEQ_CAP] neq;
    usz  neq_count;
}

struct SxBind
{
    Node* key;       // binder node (pat-ident / param) — or null for name-keyed
    uint  name;
    int   val;
}

struct SxPath
{
    SxBind[SX_STORE_CAP] store;
    usz                  store_count;
    int[SX_PC_CAP]       pc;
    usz                  pc_count;
    SxFact*              facts;      // SX_MAX_VARS entries, owned
    bool                 alive;      // still executing (not returned/ended)
    bool                 feasible;
    int                  in_loop;    // >0 while executing a loop body iteration
}

// Per-branch verdict, aggregated over every path that reaches it.
struct SxBranch
{
    Node* cond;
    usz   reached;
    usz   decided_true;
    usz   decided_false;
    bool  tainted;       // some path decided it by constants alone / inside a loop
    char* witness;
}
const usz SX_MAX_BRANCHES = 256;

struct SymState
{
    Arena*                 arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*                  file;

    SxVal*  vals;
    usz     val_count;
    uint*   var_names;      // SX_MAX_VARS
    usz     var_count;

    SxPath* paths;          // SX_MAX_PATHS
    usz     path_count;

    // counters
    usz fns_run;
    usz paths_total;
    usz paths_pruned;
    usz forks;
    usz bound_hits;
    usz solver_rounds;
    usz atoms_decided;
    usz div_zero;
    usz dead_branch;
    usz assert_fail;
    usz assert_proved;
    usz havocs;
    usz diags_emitted;
    SxBranch* branches;     // per-function verdict table, SX_MAX_BRANCHES
    usz       branch_count;
    bool strict;
    Node* cur_fn;
}

fn void SymState.init(SymState* s, Arena* a)
{
    s.arena = a;
    s.diags = null;
    s.interner = null;
    s.file = null;
    s.vals = (SxVal*)malloc(SxVal::size * SX_MAX_VALS);
    s.var_names = (uint*)malloc(uint::size * SX_MAX_VARS);
    s.paths = (SxPath*)malloc(SxPath::size * SX_MAX_PATHS);
    s.branches = (SxBranch*)malloc(SxBranch::size * SX_MAX_BRANCHES);
    s.branch_count = 0;
    s.val_count = 0;
    s.var_count = 0;
    s.path_count = 0;
    if (s.paths != null)
    {
        for (usz i = 0; i < SX_MAX_PATHS; i++) { s.paths[i].facts = null; }
    }
    s.fns_run = 0; s.paths_total = 0; s.paths_pruned = 0; s.forks = 0;
    s.bound_hits = 0; s.solver_rounds = 0; s.atoms_decided = 0;
    s.div_zero = 0; s.dead_branch = 0; s.assert_fail = 0; s.assert_proved = 0;
    s.havocs = 0; s.diags_emitted = 0;
    s.strict = false;
    s.cur_fn = null;
}

fn void SymState.attach(SymState* s, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    s.diags = d;
    s.interner = it;
    s.file = file;
}

fn void SymState.destroy(SymState* s)
{
    if (s.paths != null)
    {
        for (usz i = 0; i < SX_MAX_PATHS; i++)
        {
            if (s.paths[i].facts != null) { free((void*)s.paths[i].facts); s.paths[i].facts = null; }
        }
        free((void*)s.paths);
        s.paths = null;
    }
    if (s.vals != null) { free((void*)s.vals); s.vals = null; }
    if (s.branches != null) { free((void*)s.branches); s.branches = null; }
    if (s.var_names != null) { free((void*)s.var_names); s.var_names = null; }
}

// ── Values ──────────────────────────────────────────────────────────────────
fn int SymState.conc(SymState* s, long v)
{
    if (s.vals == null || s.val_count >= SX_MAX_VALS) { return -1; }
    if (v >= SX_INF || v <= -SX_INF) { return s.fresh(0); }   // beyond the solver's line: unknown
    int id = (int)s.val_count;
    s.vals[id].kind = SxKind.SX_CONC;
    s.vals[id].c = v;
    s.vals[id].a = -1;
    s.vals[id].b = -1;
    s.vals[id].vix = -1;
    s.val_count = s.val_count + 1;
    return id;
}

fn int SymState.fresh(SymState* s, uint name)
{
    if (s.vals == null || s.val_count >= SX_MAX_VALS || s.var_count >= SX_MAX_VARS) { return -1; }
    int id = (int)s.val_count;
    s.vals[id].kind = SxKind.SX_VAR;
    s.vals[id].c = 0;
    s.vals[id].a = -1;
    s.vals[id].b = -1;
    s.vals[id].vix = (int)s.var_count;
    s.var_names[s.var_count] = name;
    s.var_count = s.var_count + 1;
    s.val_count = s.val_count + 1;
    return id;
}

fn bool sx_is_conc(SymState* s, int v) { return v >= 0 && s.vals[v].kind == SxKind.SX_CONC; }

fn long sat_add(long a, long b)
{
    if (a >= SX_INF || b >= SX_INF) { if (a <= -SX_INF || b <= -SX_INF) { return 0; } return SX_INF; }
    if (a <= -SX_INF || b <= -SX_INF) { return -SX_INF; }
    long r = a + b;
    if (r > SX_INF) { return SX_INF; }
    if (r < -SX_INF) { return -SX_INF; }
    return r;
}
fn bool sx_fin(long x) { return x > -SX_INF && x < SX_INF; }
fn long sat_neg(long a) { return a >= SX_INF ? -SX_INF : (a <= -SX_INF ? SX_INF : -a); }
fn long sat_mul(long a, long b)
{
    if (a == 0 || b == 0) { return 0; }
    bool neg = (a < 0) != (b < 0);
    long x = a < 0 ? sat_neg(a) : a;
    long y = b < 0 ? sat_neg(b) : b;
    if (x >= SX_INF || y >= SX_INF || x > SX_INF / y) { return neg ? -SX_INF : SX_INF; }
    long r = x * y;
    return neg ? -r : r;
}

// Constant folding at construction: both concrete → concrete.
fn int SymState.binop(SymState* s, SxKind k, int a, int b)
{
    if (a < 0 || b < 0) { return -1; }
    if (sx_is_conc(s, a) && sx_is_conc(s, b))
    {
        long x = s.vals[a].c;
        long y = s.vals[b].c;
        switch (k)
        {
            case SX_ADD: return s.conc(sat_add(x, y));
            case SX_SUB: return s.conc(sat_add(x, sat_neg(y)));
            case SX_MUL: return s.conc(sat_mul(x, y));
            case SX_DIV: if (y != 0) { return s.conc(x / y); }
            case SX_MOD: if (y != 0) { return s.conc(x % y); }
            case SX_EQ:  return s.conc(x == y ? 1 : 0);
            case SX_NE:  return s.conc(x != y ? 1 : 0);
            case SX_LT:  return s.conc(x <  y ? 1 : 0);
            case SX_LE:  return s.conc(x <= y ? 1 : 0);
            case SX_GT:  return s.conc(x >  y ? 1 : 0);
            case SX_GE:  return s.conc(x >= y ? 1 : 0);
            case SX_AND: return s.conc((x != 0 && y != 0) ? 1 : 0);
            case SX_OR:  return s.conc((x != 0 || y != 0) ? 1 : 0);
            default: break;
        }
    }
    if (s.val_count >= SX_MAX_VALS) { return -1; }
    int id = (int)s.val_count;
    s.vals[id].kind = k;
    s.vals[id].c = 0;
    s.vals[id].a = a;
    s.vals[id].b = b;
    s.vals[id].vix = -1;
    s.val_count = s.val_count + 1;
    return id;
}

fn int SymState.not(SymState* s, int a)
{
    if (a < 0) { return -1; }
    SxVal* v = &s.vals[a];
    if (v.kind == SxKind.SX_CONC) { return s.conc(v.c != 0 ? 0 : 1); }
    if (v.kind == SxKind.SX_NOT) { return v.a; }
    // Push negation through comparisons so the solver sees atoms.
    switch (v.kind)
    {
        case SX_EQ: return s.binop(SxKind.SX_NE, v.a, v.b);
        case SX_NE: return s.binop(SxKind.SX_EQ, v.a, v.b);
        case SX_LT: return s.binop(SxKind.SX_GE, v.a, v.b);
        case SX_LE: return s.binop(SxKind.SX_GT, v.a, v.b);
        case SX_GT: return s.binop(SxKind.SX_LE, v.a, v.b);
        case SX_GE: return s.binop(SxKind.SX_LT, v.a, v.b);
        case SX_AND: return s.binop(SxKind.SX_OR, s.not(v.a), s.not(v.b));
        case SX_OR:  return s.binop(SxKind.SX_AND, s.not(v.a), s.not(v.b));
        default: break;
    }
    if (s.val_count >= SX_MAX_VALS) { return -1; }
    int id = (int)s.val_count;
    s.vals[id].kind = SxKind.SX_NOT;
    s.vals[id].c = 0;
    s.vals[id].a = a;
    s.vals[id].b = -1;
    s.vals[id].vix = -1;
    s.val_count = s.val_count + 1;
    return id;
}

// ── Paths ───────────────────────────────────────────────────────────────────
fn bool SxPath.reset(SxPath* p)
{
    if (p.facts == null) { p.facts = (SxFact*)malloc(SxFact::size * SX_MAX_VARS); }
    if (p.facts == null) { return false; }
    for (usz i = 0; i < SX_MAX_VARS; i++)
    {
        p.facts[i].lo = -SX_INF;
        p.facts[i].hi = SX_INF;
        p.facts[i].neq_count = 0;
    }
    p.store_count = 0;
    p.pc_count = 0;
    p.alive = true;
    p.feasible = true;
    p.in_loop = 0;
    return true;
}

fn void SxPath.copy_from(SxPath* dst, SxPath* src)
{
    dst.store_count = src.store_count;
    for (usz i = 0; i < src.store_count; i++) { dst.store[i] = src.store[i]; }
    dst.pc_count = src.pc_count;
    for (usz i = 0; i < src.pc_count; i++) { dst.pc[i] = src.pc[i]; }
    for (usz i = 0; i < SX_MAX_VARS; i++) { dst.facts[i] = src.facts[i]; }
    dst.alive = src.alive;
    dst.feasible = src.feasible;
    dst.in_loop = src.in_loop;
}

fn int SxPath.lookup(SxPath* p, Node* key, uint name)
{
    for (usz i = p.store_count; i > 0; i--)
    {
        SxBind* b = &p.store[i - 1];
        if (key != null ? b.key == key : (b.key == null && b.name == name)) { return b.val; }
    }
    return -1;
}

fn void SxPath.bind(SxPath* p, Node* key, uint name, int v)
{
    for (usz i = p.store_count; i > 0; i--)
    {
        SxBind* b = &p.store[i - 1];
        if (key != null ? b.key == key : (b.key == null && b.name == name)) { b.val = v; return; }
    }
    if (p.store_count >= SX_STORE_CAP) { return; }
    p.store[p.store_count].key = key;
    p.store[p.store_count].name = name;
    p.store[p.store_count].val = v;
    p.store_count = p.store_count + 1;
}

// ── The solver ──────────────────────────────────────────────────────────────
// Interval of a value under the path's facts.
fn void SymState.range(SymState* s, SxPath* p, int v, long* lo, long* hi, int depth)
{
    *lo = -SX_INF;
    *hi = SX_INF;
    if (v < 0 || depth > 32) { return; }
    SxVal* x = &s.vals[v];
    switch (x.kind)
    {
        case SX_CONC: *lo = x.c; *hi = x.c; return;
        case SX_VAR:
        {
            SxFact* f = &p.facts[x.vix];
            *lo = f.lo;
            *hi = f.hi;
            // A point interval excluded by a disequality is empty; report
            // it as an inverted interval which every comparison rejects.
            if (*lo == *hi)
            {
                for (usz i = 0; i < f.neq_count; i++) { if (f.neq[i] == *lo) { *lo = 1; *hi = 0; return; } }
            }
            return;
        }
        case SX_ADD:
        case SX_SUB:
        {
            long alo; long ahi; long blo; long bhi;
            s.range(p, x.a, &alo, &ahi, depth + 1);
            s.range(p, x.b, &blo, &bhi, depth + 1);
            if (x.kind == SxKind.SX_ADD) { *lo = sat_add(alo, blo); *hi = sat_add(ahi, bhi); }
            else { *lo = sat_add(alo, sat_neg(bhi)); *hi = sat_add(ahi, sat_neg(blo)); }
            return;
        }
        case SX_MUL:
        {
            long alo; long ahi; long blo; long bhi;
            s.range(p, x.a, &alo, &ahi, depth + 1);
            s.range(p, x.b, &blo, &bhi, depth + 1);
            long p1 = sat_mul(alo, blo); long p2 = sat_mul(alo, bhi);
            long p3 = sat_mul(ahi, blo); long p4 = sat_mul(ahi, bhi);
            long mn = p1; long mx = p1;
            if (p2 < mn) { mn = p2; } if (p2 > mx) { mx = p2; }
            if (p3 < mn) { mn = p3; } if (p3 > mx) { mx = p3; }
            if (p4 < mn) { mn = p4; } if (p4 > mx) { mx = p4; }
            *lo = mn; *hi = mx;
            return;
        }
        case SX_MOD:
        {
            long blo; long bhi;
            s.range(p, x.b, &blo, &bhi, depth + 1);
            if (blo > 0) { *lo = sat_neg(sat_add(bhi, -1)); *hi = sat_add(bhi, -1); }
            return;
        }
        case SX_EQ: case SX_NE: case SX_LT: case SX_LE: case SX_GT: case SX_GE:
        case SX_AND: case SX_OR: case SX_NOT:
        {
            int t = s.truth(p, v, depth + 1);
            if (t == 1) { *lo = 1; *hi = 1; }
            else if (t == 0) { *lo = 0; *hi = 0; }
            else { *lo = 0; *hi = 1; }
            return;
        }
        default: return;
    }
}

// Three-valued truth of a boolean value under the facts: 1, 0, or -1.
fn int SymState.truth(SymState* s, SxPath* p, int v, int depth)
{
    if (v < 0 || depth > 32) { return -1; }
    SxVal* x = &s.vals[v];
    switch (x.kind)
    {
        case SX_CONC: return x.c != 0 ? 1 : 0;
        case SX_NOT:
        {
            int t = s.truth(p, x.a, depth + 1);
            return t < 0 ? -1 : 1 - t;
        }
        case SX_AND:
        {
            int ta = s.truth(p, x.a, depth + 1);
            int tb = s.truth(p, x.b, depth + 1);
            if (ta == 0 || tb == 0) { return 0; }
            if (ta == 1 && tb == 1) { return 1; }
            return -1;
        }
        case SX_OR:
        {
            int ta = s.truth(p, x.a, depth + 1);
            int tb = s.truth(p, x.b, depth + 1);
            if (ta == 1 || tb == 1) { return 1; }
            if (ta == 0 && tb == 0) { return 0; }
            return -1;
        }
        case SX_EQ: case SX_NE: case SX_LT: case SX_LE: case SX_GT: case SX_GE:
        {
            long alo; long ahi; long blo; long bhi;
            s.range(p, x.a, &alo, &ahi, depth + 1);
            s.range(p, x.b, &blo, &bhi, depth + 1);
            if (alo > ahi || blo > bhi) { return 0; }   // empty operand: unsatisfiable atom
            // A saturated endpoint is "unbounded", and unbounded decides nothing.
            if (!sx_fin(alo)) { alo = -SX_INF - 1; }
            if (!sx_fin(ahi)) { ahi = SX_INF + 1; }
            if (!sx_fin(blo)) { blo = -SX_INF - 1; }
            if (!sx_fin(bhi)) { bhi = SX_INF + 1; }
            bool same_var = s.vals[x.a].kind == SxKind.SX_VAR && s.vals[x.b].kind == SxKind.SX_VAR
                         && s.vals[x.a].vix == s.vals[x.b].vix;
            switch (x.kind)
            {
                case SX_LT:
                    if (ahi < blo) { return 1; }
                    if (alo >= bhi || same_var) { return 0; }
                    return -1;
                case SX_LE:
                    if (ahi <= blo || same_var) { return 1; }
                    if (alo > bhi) { return 0; }
                    return -1;
                case SX_GT:
                    if (alo > bhi) { return 1; }
                    if (ahi <= blo || same_var) { return 0; }
                    return -1;
                case SX_GE:
                    if (alo >= bhi || same_var) { return 1; }
                    if (ahi < blo) { return 0; }
                    return -1;
                case SX_EQ:
                    if (same_var) { return 1; }
                    if (ahi < blo || alo > bhi) { return 0; }
                    if (alo == ahi && blo == bhi && alo == blo) { return 1; }
                    // x == c with c excluded
                    if (s.vals[x.a].kind == SxKind.SX_VAR && blo == bhi && s.excluded(p, s.vals[x.a].vix, blo)) { return 0; }
                    if (s.vals[x.b].kind == SxKind.SX_VAR && alo == ahi && s.excluded(p, s.vals[x.b].vix, alo)) { return 0; }
                    return -1;
                case SX_NE:
                    if (same_var) { return 0; }
                    if (ahi < blo || alo > bhi) { return 1; }
                    if (alo == ahi && blo == bhi && alo == blo) { return 0; }
                    if (s.vals[x.a].kind == SxKind.SX_VAR && blo == bhi && s.excluded(p, s.vals[x.a].vix, blo)) { return 1; }
                    if (s.vals[x.b].kind == SxKind.SX_VAR && alo == ahi && s.excluded(p, s.vals[x.b].vix, alo)) { return 1; }
                    return -1;
                default: return -1;
            }
        }
        default:
        {
            // An integer used as a condition.
            long lo; long hi;
            s.range(p, v, &lo, &hi, depth + 1);
            if (lo > 0 || hi < 0) { return 1; }
            if (lo == 0 && hi == 0) { return 0; }
            return -1;
        }
    }
}

fn bool SymState.excluded(SymState* s, SxPath* p, int vix, long c)
{
    SxFact* f = &p.facts[vix];
    for (usz i = 0; i < f.neq_count; i++) { if (f.neq[i] == c) { return true; } }
    return false;
}

// Refine facts from one atom. Returns true if anything changed.
// Handles  VAR rel E  and  E rel VAR  and  (VAR ± CONC) rel E.
fn bool SymState.refine(SymState* s, SxPath* p, int atom)
{
    if (atom < 0) { return false; }
    SxVal* x = &s.vals[atom];
    if (x.kind == SxKind.SX_AND)
    {
        bool c1 = s.refine(p, x.a);
        bool c2 = s.refine(p, x.b);
        return c1 || c2;
    }
    if (x.kind == SxKind.SX_NOT)
    {
        // Only a NOT that could not be pushed (e.g. ¬VAR): VAR == 0.
        if (s.vals[x.a].kind == SxKind.SX_VAR) { return s.tighten(p, s.vals[x.a].vix, 0, 0); }
        return false;
    }
    if (x.kind == SxKind.SX_VAR) { return s.exclude(p, x.vix, 0); }   // `if v` ⇒ v ≠ 0
    if (x.kind != SxKind.SX_EQ && x.kind != SxKind.SX_NE && x.kind != SxKind.SX_LT
     && x.kind != SxKind.SX_LE && x.kind != SxKind.SX_GT && x.kind != SxKind.SX_GE) { return false; }

    bool changed = false;
    // Normalise to  side rel other  for each side that is a vix or vix±c.
    changed = s.refine_side(p, x.kind, x.a, x.b, false) || changed;
    changed = s.refine_side(p, x.kind, x.b, x.a, true) || changed;
    return changed;
}

fn SxKind flip_rel(SxKind k)
{
    switch (k)
    {
        case SX_LT: return SxKind.SX_GT;
        case SX_LE: return SxKind.SX_GE;
        case SX_GT: return SxKind.SX_LT;
        case SX_GE: return SxKind.SX_LE;
        default: return k;
    }
}

// `lhs rel rhs` where we try to read lhs as VAR + shift.
fn bool SymState.refine_side(SymState* s, SxPath* p, SxKind rel, int lhs, int rhs, bool flipped)
{
    if (flipped) { rel = flip_rel(rel); }
    int vix = -1;
    long shift = 0;
    SxVal* l = &s.vals[lhs];
    if (l.kind == SxKind.SX_VAR) { vix = l.vix; }
    else if ((l.kind == SxKind.SX_ADD || l.kind == SxKind.SX_SUB)
          && s.vals[l.a].kind == SxKind.SX_VAR && sx_is_conc(s, l.b))
    {
        vix = s.vals[l.a].vix;
        shift = l.kind == SxKind.SX_ADD ? s.vals[l.b].c : sat_neg(s.vals[l.b].c);
    }
    else if (l.kind == SxKind.SX_ADD && sx_is_conc(s, l.a) && s.vals[l.b].kind == SxKind.SX_VAR)
    {
        vix = s.vals[l.b].vix;
        shift = s.vals[l.a].c;
    }
    if (vix < 0) { return false; }
    long rlo; long rhi;
    s.range(p, rhs, &rlo, &rhi, 0);
    if (rlo > rhi) { return false; }
    // vix + shift rel [rlo, rhi]  ⇒  vix rel [rlo - shift, rhi - shift]
    rlo = sat_add(rlo, sat_neg(shift));
    rhi = sat_add(rhi, sat_neg(shift));
    switch (rel)
    {
        case SX_LT: return s.tighten(p, vix, -SX_INF, sat_add(rhi, -1));
        case SX_LE: return s.tighten(p, vix, -SX_INF, rhi);
        case SX_GT: return s.tighten(p, vix, sat_add(rlo, 1), SX_INF);
        case SX_GE: return s.tighten(p, vix, rlo, SX_INF);
        case SX_EQ: return s.tighten(p, vix, rlo, rhi);
        case SX_NE: if (rlo == rhi) { return s.exclude(p, vix, rlo); } return false;
        default: return false;
    }
}

fn bool SymState.tighten(SymState* s, SxPath* p, int vix, long lo, long hi)
{
    SxFact* f = &p.facts[vix];
    bool changed = false;
    if (lo > f.lo) { f.lo = lo; changed = true; }
    if (hi < f.hi) { f.hi = hi; changed = true; }
    // Excluded endpoints shrink the interval further.
    bool moved = true;
    int guard = 0;
    while (moved && guard < 16)
    {
        moved = false;
        guard = guard + 1;
        for (usz i = 0; i < f.neq_count; i++)
        {
            if (f.neq[i] == f.lo && f.lo <= f.hi) { f.lo = f.lo + 1; moved = true; changed = true; }
            if (f.neq[i] == f.hi && f.lo <= f.hi) { f.hi = f.hi - 1; moved = true; changed = true; }
        }
    }
    return changed;
}

fn bool SymState.exclude(SymState* s, SxPath* p, int vix, long c)
{
    SxFact* f = &p.facts[vix];
    for (usz i = 0; i < f.neq_count; i++) { if (f.neq[i] == c) { return false; } }
    if (f.neq_count < SX_NEQ_CAP) { f.neq[f.neq_count] = c; f.neq_count = f.neq_count + 1; }
    // Endpoint exclusion tightens.
    if (f.lo == c && f.lo <= f.hi) { f.lo = f.lo + 1; }
    if (f.hi == c && f.lo <= f.hi) { f.hi = f.hi - 1; }
    return true;
}

// Decide feasibility of the path: refine to a fixpoint, then every atom
// must not be FALSE and every variable interval must be non-empty.
fn bool SymState.feasible(SymState* s, SxPath* p)
{
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < 8)
    {
        changed = false;
        rounds = rounds + 1;
        s.solver_rounds = s.solver_rounds + 1;
        for (usz i = 0; i < p.pc_count; i++)
        {
            if (s.refine(p, p.pc[i])) { changed = true; }
        }
    }
    for (usz i = 0; i < s.var_count; i++)
    {
        if (p.facts[i].lo > p.facts[i].hi) { return false; }
    }
    for (usz i = 0; i < p.pc_count; i++)
    {
        int t = s.truth(p, p.pc[i], 0);
        if (t == 0) { return false; }
    }
    return true;
}

// Assume `atom` on the path; returns false if that makes it infeasible.
fn bool SymState.assume(SymState* s, SxPath* p, int atom)
{
    if (atom < 0) { return true; }
    if (sx_is_conc(s, atom)) { return s.vals[atom].c != 0; }
    if (p.pc_count >= SX_PC_CAP) { s.bound_hits = s.bound_hits + 1; return true; }
    p.pc[p.pc_count] = atom;
    p.pc_count = p.pc_count + 1;
    p.feasible = s.feasible(p);
    return p.feasible;
}

// ── Printing ────────────────────────────────────────────────────────────────
fn usz sx_put(char* buf, usz cap, char* str)
{
    usz n = 0;
    while (str[n] != 0 && n + 1 < cap) { buf[n] = str[n]; n = n + 1; }
    return n;
}

fn char* sx_op(SxKind k)
{
    switch (k)
    {
        case SX_ADD: return " + "; case SX_SUB: return " - "; case SX_MUL: return " * ";
        case SX_DIV: return " / "; case SX_MOD: return " % ";
        case SX_EQ: return " == "; case SX_NE: return " != ";
        case SX_LT: return " < "; case SX_LE: return " <= ";
        case SX_GT: return " > "; case SX_GE: return " >= ";
        case SX_AND: return " && "; case SX_OR: return " || ";
        default: return " ? ";
    }
}

fn usz SymState.print_val(SymState* s, int v, char* buf, usz cap, int depth)
{
    if (cap < 4) { return 0; }
    if (v < 0 || depth > 12) { return sx_put(buf, cap, "?"); }
    SxVal* x = &s.vals[v];
    usz pos = 0;
    switch (x.kind)
    {
        case SX_CONC: return (usz)snprintf(buf, cap, "%ld", x.c);
        case SX_VAR:
        {
            uint nm = s.var_names[x.vix];
            if (nm != 0 && s.interner != null) { return sx_put(buf, cap, s.interner.text(nm)); }
            return (usz)snprintf(buf, cap, "v%d", x.vix);
        }
        case SX_NOT:
        {
            pos = pos + sx_put(buf + pos, cap - pos, "!");
            pos = pos + s.print_val(x.a, buf + pos, cap - pos, depth + 1);
            return pos;
        }
        default:
        {
            bool paren = depth > 0 || x.kind == SxKind.SX_OR;
            if (paren) { pos = pos + sx_put(buf + pos, cap - pos, "("); }
            pos = pos + s.print_val(x.a, buf + pos, cap - pos, depth + 1);
            pos = pos + sx_put(buf + pos, cap - pos, sx_op(x.kind));
            pos = pos + s.print_val(x.b, buf + pos, cap - pos, depth + 1);
            if (paren) { pos = pos + sx_put(buf + pos, cap - pos, ")"); }
            return pos;
        }
    }
}

// The witness: the path condition as written, most recent last.
fn char* SymState.witness(SymState* s, SxPath* p)
{
    char* buf = (char*)s.arena.alloc(512, 1);
    if (buf == null) { return "?"; }
    usz pos = 0;
    if (p.pc_count == 0) { pos = sx_put(buf, 512, "(unconditionally)"); buf[pos] = 0; return buf; }
    for (usz i = 0; i < p.pc_count && pos + 8 < 500; i++)
    {
        if (i > 0) { pos = pos + sx_put(buf + pos, 512 - pos, " ∧ "); }
        pos = pos + s.print_val(p.pc[i], buf + pos, 512 - pos, 0);
    }
    buf[pos < 511 ? pos : 511] = 0;
    return buf;
}

fn void SymState.emit(SymState* s, int sev, int code, Node* at, char* msg)
{
    if (s.diags == null || at == null) { return; }
    if (s.diags_emitted >= SX_MAX_DIAGS) { return; }
    s.diags_emitted = s.diags_emitted + 1;
    pfront_core::Phase ph = pfront_core::Phase.PH_RESOLVE;
    if (sev == 2)      { if (s.strict) { s.diags.error(ph, code, at.line, at.col, msg, s.file); } else { s.diags.warn(ph, code, at.line, at.col, msg, s.file); } }
    else               { s.diags.note(ph, code, at.line, at.col, msg, s.file); }
}

// ── Evaluation ──────────────────────────────────────────────────────────────
fn int SymState.havoc(SymState* s, uint name)
{
    s.havocs = s.havocs + 1;
    return s.fresh(name);
}

fn SxKind sx_kind_of(Tk op)
{
    switch (op)
    {
        case TOKEN_PLUS: return SxKind.SX_ADD;
        case TOKEN_MINUS: return SxKind.SX_SUB;
        case TOKEN_STAR: return SxKind.SX_MUL;
        case TOKEN_SLASH: return SxKind.SX_DIV;
        case TOKEN_PERCENT: return SxKind.SX_MOD;
        case TOKEN_EQEQ: return SxKind.SX_EQ;
        case TOKEN_NEQ: return SxKind.SX_NE;
        case TOKEN_NEQ_UNI: return SxKind.SX_NE;
        case TOKEN_LT: return SxKind.SX_LT;
        case TOKEN_LTEQ: return SxKind.SX_LE;
        case TOKEN_GT: return SxKind.SX_GT;
        case TOKEN_GTEQ: return SxKind.SX_GE;
        case TOKEN_AMPAMP: return SxKind.SX_AND;
        case TOKEN_KW_AND: return SxKind.SX_AND;
        case TOKEN_PIPEPIPE: return SxKind.SX_OR;
        case TOKEN_KW_OR: return SxKind.SX_OR;
        default: return SxKind.SX_VAR;   // sentinel: unmodelled
    }
}

fn Node* binder_of(Node* ident)
{
    if (ident == null) { return null; }
    Node* r = ident.resolved;
    if (r == null) { return null; }
    if (r.kind == Nk.N_PAT_IDENT || r.kind == Nk.N_DECL_PARAM || r.kind == Nk.N_DECL_LET) { return r; }
    return null;
}

fn void SymState.check_divisor(SymState* s, SxPath* p, Node* at, int divisor)
{
    if (!p.feasible || divisor < 0) { return; }
    long lo; long hi;
    s.range(p, divisor, &lo, &hi, 0);
    if (lo == 0 && hi == 0)
    {
        s.div_zero = s.div_zero + 1;
        char* msg = (char*)s.arena.alloc(640, 1);
        if (msg != null)
        {
            snprintf(msg, 640, "division by zero on a feasible path: the divisor is 0 when %s", s.witness(p));
            s.emit(2, 4050, at, msg);
        }
    }
}

fn int SymState.eval(SymState* s, SxPath* p, Node* n, int depth)
{
    if (n == null || depth > SX_MAX_DEPTH) { return s.havoc(0); }
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
            return s.conc((long)n.p.ival);
        case N_EXPR_BOOL:
            return s.conc(n.p.ival != 0 ? 1 : 0);
        case N_EXPR_IDENT:
        {
            Node* key = binder_of(n);
            int v = p.lookup(key, n.name_id);
            if (v >= 0) { return v; }
            // First sight of a name this path knows nothing about (global,
            // captured, unresolved): a symbolic variable named after it.
            int fresh = s.fresh(n.name_id);
            p.bind(key, n.name_id, fresh);
            return fresh;
        }
        case N_EXPR_TUPLE:
            if (n.child_count == 1) { return s.eval(p, n.children[0], depth + 1); }
            for (usz i = 0; i < n.child_count; i++) { s.eval(p, n.children[i], depth + 1); }
            return s.havoc(0);
        case N_EXPR_BINARY:
        {
            if (n.child_count < 2) { return s.havoc(0); }
            Tk op = (Tk)n.p.op;
            SxKind k = sx_kind_of(op);
            if (k == SxKind.SX_AND || k == SxKind.SX_OR)
            {
                int a = s.eval(p, n.children[0], depth + 1);
                int b = s.eval(p, n.children[1], depth + 1);
                return s.binop(k, a, b);
            }
            int a = s.eval(p, n.children[0], depth + 1);
            int b = s.eval(p, n.children[1], depth + 1);
            if (k == SxKind.SX_VAR) { return s.havoc(0); }   // shifts, bit ops, pipes...
            if ((k == SxKind.SX_DIV || k == SxKind.SX_MOD)
                && !(n.children[1] != null && n.children[1].kind == Nk.N_EXPR_INT && n.children[1].p.ival == 0))
            {
                s.check_divisor(p, n, b);   // a literal `/ 0` is absint's to report
            }
            return s.binop(k, a, b);
        }
        case N_EXPR_UNARY:
        {
            if (n.child_count < 1) { return s.havoc(0); }
            int a = s.eval(p, n.children[0], depth + 1);
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT) { return s.not(a); }
            if (op == Tk.TOKEN_MINUS) { return s.binop(SxKind.SX_SUB, s.conc(0), a); }
            return s.havoc(0);
        }
        case N_EXPR_IF:
        case N_EXPR_MATCH:
        case N_EXPR_WHILE:
        case N_EXPR_FOR:
        case N_EXPR_LOOP:
        case N_BLOCK:
        {
            // Control flow in value position: explore the arms for faults
            // under their conditions; the value is unknown.
            s.explore(p, n, depth + 1);
            return s.havoc(0);
        }
        case N_EXPR_CALL:
        case N_EXPR_METHOD:
        {
            // Arguments are evaluated (they may divide); the result is unknown.
            usz first = n.kind == Nk.N_EXPR_CALL ? 1 : 0;
            for (usz i = first; i < n.child_count; i++) { s.eval(p, n.children[i], depth + 1); }
            return s.havoc(0);
        }
        case N_EXPR_ASSERT:
        {
            if (n.child_count < 1) { return s.conc(1); }
            int c = s.eval(p, n.children[0], depth + 1);
            int t = s.truth(p, c, 0);
            if (t == 0 && p.feasible)
            {
                s.assert_fail = s.assert_fail + 1;
                char* msg = (char*)s.arena.alloc(640, 1);
                if (msg != null)
                {
                    snprintf(msg, 640, "assertion always fails on a feasible path: when %s", s.witness(p));
                    s.emit(2, 4052, n, msg);
                }
            }
            else if (t == 1) { s.assert_proved = s.assert_proved + 1; }
            else { s.assume(p, c); }   // past the assert, it holds
            return s.conc(1);
        }
        case N_EXPR_ASSUME:
        {
            if (n.child_count >= 1) { s.assume(p, s.eval(p, n.children[0], depth + 1)); }
            return s.conc(1);
        }
        case N_EXPR_CAST:
        case N_EXPR_UNSAFE:
        case N_EXPR_UNCHECKED:
            if (n.child_count >= 1) { return s.eval(p, n.children[0], depth + 1); }
            return s.havoc(0);
        default:
        {
            // Anything unmodelled: visit children for faults, value unknown.
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c != null && c.kind >= Nk.N_EXPR_INT && c.kind <= Nk.N_EXPR_VOLATILE) { s.eval(p, c, depth + 1); }
            }
            return s.havoc(0);
        }
    }
}

// ── Execution ───────────────────────────────────────────────────────────────
// Every construct maps a SET of live paths to a set of live paths. A path
// that returns, breaks, dies at a bound or becomes infeasible leaves the set.
// `if` doubles the set; `match` multiplies it by its arms; loops fork one
// "entered" path per input path.

struct SxSet
{
    int[SX_MAX_PATHS] ids;
    usz               count;
}

fn void SxSet.add(SxSet* st, int id)
{
    if (id < 0 || st.count >= SX_MAX_PATHS) { return; }
    st.ids[st.count] = id;
    st.count = st.count + 1;
}

fn int SymState.fork(SymState* s, int pid)
{
    if (s.path_count >= SX_MAX_PATHS) { s.bound_hits = s.bound_hits + 1; return -1; }
    SxPath* q = &s.paths[s.path_count];
    if (!q.reset()) { return -1; }
    q.copy_from(&s.paths[pid]);
    int id = (int)s.path_count;
    s.path_count = s.path_count + 1;
    s.forks = s.forks + 1;
    return id;
}

fn void SymState.kill(SymState* s, int pid, bool pruned)
{
    s.paths[pid].alive = false;
    if (pruned) { s.paths_pruned = s.paths_pruned + 1; }
}

fn bool SymState.live(SymState* s, int pid)
{
    return pid >= 0 && s.paths[pid].alive && s.paths[pid].feasible;
}

// Names assigned anywhere inside `n` — havocked at loop exits.
fn void SymState.havoc_assigned(SymState* s, SxPath* p, Node* n, int depth)
{
    if (n == null || depth > SX_MAX_DEPTH) { return; }
    if ((n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN)
        && n.child_count >= 1)
    {
        Node* lhs = n.children[0];
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT)
        {
            p.bind(binder_of(lhs), lhs.name_id, s.havoc(lhs.name_id));
        }
    }
    for (usz i = 0; i < n.child_count; i++) { s.havoc_assigned(p, n.children[i], depth + 1); }
}

// Does this loop body contain a `break` that targets it?
fn bool has_break(Node* n, int depth)
{
    if (n == null || depth > SX_MAX_DEPTH) { return false; }
    if (n.kind == Nk.N_STMT_BREAK) { return true; }
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP
     || n.kind == Nk.N_DECL_FN || n.kind == Nk.N_EXPR_LAMBDA) { return false; }
    for (usz i = 0; i < n.child_count; i++) { if (has_break(n.children[i], depth + 1)) { return true; } }
    return false;
}

fn void SymState.bind_pattern(SymState* s, SxPath* p, Node* pat, int v)
{
    if (pat == null) { return; }
    switch (pat.kind)
    {
        case N_PAT_IDENT:
            p.bind(pat, pat.name_id, v >= 0 ? v : s.havoc(pat.name_id));
        case N_DECL_PARAM:
            if (pat.child_count >= 1 && pat.children[0] != null && pat.children[0].kind == Nk.N_PAT_IDENT)
            {
                p.bind(pat.children[0], pat.children[0].name_id, s.fresh(pat.children[0].name_id));
                p.bind(pat, pat.name_id, p.lookup(pat.children[0], 0));
            }
            else { p.bind(pat, pat.name_id, s.fresh(pat.name_id)); }
        case N_PAT_WILDCARD:
            break;
        default:
            // Tuples, structs, variants: each sub-binder becomes symbolic.
            for (usz i = 0; i < pat.child_count; i++) { s.bind_pattern(p, pat.children[i], -1); }
    }
}

// Does `pat` constrain the scrutinee to a literal? Returns the literal node.
fn Node* pattern_literal(Node* pat)
{
    if (pat == null) { return null; }
    if (pat.kind == Nk.N_PAT_LITERAL && pat.child_count > 0) { pat = pat.children[0]; }
    if (pat.kind == Nk.N_EXPR_INT || pat.kind == Nk.N_EXPR_BOOL || pat.kind == Nk.N_EXPR_CHAR) { return pat; }
    return null;
}

fn void SymState.note_decided(SymState* s, SxPath* p, int cond, Node* at)
{
    if (s.branches == null || at == null) { return; }
    SxBranch* b = null;
    for (usz i = 0; i < s.branch_count; i++) { if (s.branches[i].cond == at) { b = &s.branches[i]; break; } }
    if (b == null)
    {
        if (s.branch_count >= SX_MAX_BRANCHES) { return; }
        b = &s.branches[s.branch_count];
        s.branch_count = s.branch_count + 1;
        b.cond = at; b.reached = 0; b.decided_true = 0; b.decided_false = 0; b.tainted = false; b.witness = null;
    }
    b.reached = b.reached + 1;
    // Decided by constants alone is narrow's job; decided inside a loop
    // iteration is only true of that iteration. Either taints the verdict.
    if (sx_is_conc(s, cond) || p.pc_count == 0 || p.in_loop > 0) { b.tainted = true; return; }
    int t = s.truth(p, cond, 0);
    if (t < 0) { return; }
    s.atoms_decided = s.atoms_decided + 1;
    if (t == 1) { b.decided_true = b.decided_true + 1; } else { b.decided_false = b.decided_false + 1; }
    if (b.witness == null) { b.witness = s.witness(p); }
}

// After a function: a branch decided the same way on EVERY path that
// reached it is dead (false) or redundant (true) — say so once.
fn void SymState.flush_branches(SymState* s)
{
    for (usz i = 0; i < s.branch_count; i++)
    {
        SxBranch* b = &s.branches[i];
        if (b.tainted || b.reached == 0) { continue; }
        bool all_true = b.decided_true == b.reached;
        bool all_false = b.decided_false == b.reached;
        if (!all_true && !all_false) { continue; }
        s.dead_branch = s.dead_branch + 1;
        char* msg = (char*)s.arena.alloc(640, 1);
        if (msg == null) { continue; }
        snprintf(msg, 640, "this condition is always %s: every path reaching it already requires %s",
                 all_true ? "true" : "false", b.witness != null ? b.witness : "?");
        s.emit(1, 4051, b.cond, msg);
    }
    s.branch_count = 0;
}

fn void SymState.walk_if(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    if (n.child_count < 2) { return; }
    SxSet thens; thens.count = 0;
    SxSet elses; elses.count = 0;
    for (usz i = 0; i < in.count; i++)
    {
        int pid = in.ids[i];
        if (!s.live(pid)) { continue; }
        int cond = s.eval(&s.paths[pid], n.children[0], depth + 1);
        if (!s.live(pid)) { continue; }
        s.note_decided(&s.paths[pid], cond, n.children[0]);
        int q = s.fork(pid);
        if (q >= 0)
        {
            if (s.assume(&s.paths[q], cond)) { thens.add(q); } else { s.kill(q, true); }
        }
        if (s.assume(&s.paths[pid], s.not(cond))) { elses.add(pid); } else { s.kill(pid, true); }
    }
    SxSet t2; t2.count = 0;
    s.walk_block_set(&thens, &t2, n.children[1], depth + 1);
    for (usz i = 0; i < t2.count; i++) { out.add(t2.ids[i]); }
    if (n.child_count >= 3)
    {
        SxSet e2; e2.count = 0;
        s.walk_block_set(&elses, &e2, n.children[2], depth + 1);
        for (usz i = 0; i < e2.count; i++) { out.add(e2.ids[i]); }
    }
    else
    {
        for (usz i = 0; i < elses.count; i++) { out.add(elses.ids[i]); }
    }
}

fn void SymState.walk_match(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    if (n.child_count < 2) { return; }
    // `rest` = paths that have not matched any arm yet.
    SxSet rest; rest.count = 0;
    int[SX_MAX_PATHS] scrut;
    for (usz i = 0; i < in.count; i++)
    {
        int pid = in.ids[i];
        if (!s.live(pid)) { continue; }
        int sv = s.eval(&s.paths[pid], n.children[0], depth + 1);
        if (!s.live(pid)) { continue; }
        scrut[pid] = sv;
        rest.add(pid);
    }
    for (usz ai = 1; ai < n.child_count && rest.count > 0; ai++)
    {
        Node* arm = n.children[ai];
        if (arm == null || arm.child_count < 2) { continue; }
        Node* pat = arm.children[0];
        Node* body = arm.children[arm.child_count - 1];
        Node* guard = arm.child_count >= 3 ? arm.children[1] : null;
        if (guard != null && guard.kind == Nk.N_BLOCK) { guard = null; }
        Node* lit = pattern_literal(pat);
        bool irrefutable = lit == null && guard == null
                        && (pat.kind == Nk.N_PAT_IDENT || pat.kind == Nk.N_PAT_WILDCARD);
        bool last = ai + 1 == n.child_count;

        SxSet taken; taken.count = 0;
        SxSet next; next.count = 0;
        for (usz i = 0; i < rest.count; i++)
        {
            int pid = rest.ids[i];
            if (!s.live(pid)) { continue; }
            int q = (last || irrefutable) ? pid : s.fork(pid);
            if (q < 0) { next.add(pid); continue; }
            if (q != pid) { scrut[q] = scrut[pid]; }
            SxPath* qp = &s.paths[q];
            bool ok = true;
            int g = -1;
            if (lit != null) { ok = s.assume(qp, s.binop(SxKind.SX_EQ, scrut[q], s.conc((long)lit.p.ival))); }
            else { s.bind_pattern(qp, pat, pat.kind == Nk.N_PAT_IDENT ? scrut[q] : -1); }
            if (ok && guard != null) { g = s.eval(qp, guard, depth + 1); ok = s.assume(qp, g); }
            if (ok) { taken.add(q); } else { s.kill(q, true); }
            if (q == pid) { continue; }
            // pid falls through: this arm did not match.
            SxPath* pp = &s.paths[pid];
            bool still = true;
            if (lit != null) { still = s.assume(pp, s.binop(SxKind.SX_NE, scrut[pid], s.conc((long)lit.p.ival))); }
            else if (g >= 0) { still = s.assume(pp, s.not(g)); }
            if (still) { next.add(pid); } else { s.kill(pid, true); }
        }
        SxSet done; done.count = 0;
        s.walk_block_set(&taken, &done, body, depth + 1);
        for (usz i = 0; i < done.count; i++) { out.add(done.ids[i]); }
        rest = next;
    }
    // Paths that matched nothing (non-exhaustive as far as we can tell) continue.
    for (usz i = 0; i < rest.count; i++) { out.add(rest.ids[i]); }
}

fn void SymState.walk_while(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    if (n.child_count < 2) { return; }
    Node* body = n.children[n.child_count - 1];
    bool brk = has_break(body, 0);
    SxSet entered; entered.count = 0;
    SxSet skipped; skipped.count = 0;
    for (usz i = 0; i < in.count; i++)
    {
        int pid = in.ids[i];
        if (!s.live(pid)) { continue; }
        // "Entered" path: one iteration under cond, then it rejoins the exit.
        int q = s.fork(pid);
        if (q >= 0)
        {
            int cond = s.eval(&s.paths[q], n.children[0], depth + 1);
            if (s.assume(&s.paths[q], cond)) { s.paths[q].in_loop = s.paths[q].in_loop + 1; entered.add(q); }
            else { s.kill(q, true); }
        }
        skipped.add(pid);
    }
    SxSet after; after.count = 0;
    s.walk_block_set(&entered, &after, body, depth + 1);
    for (usz i = 0; i < after.count; i++) { s.paths[after.ids[i]].in_loop = s.paths[after.ids[i]].in_loop - 1; }
    // Exit: whatever the body assigns is unknown; without `break`, ¬cond holds.
    for (usz k = 0; k < 2; k++)
    {
        SxSet* src = k == 0 ? &after : &skipped;
        for (usz i = 0; i < src.count; i++)
        {
            int pid = src.ids[i];
            if (!s.live(pid)) { continue; }
            SxPath* p = &s.paths[pid];
            s.havoc_assigned(p, body, 0);
            int cond2 = s.eval(p, n.children[0], depth + 1);
            if (!brk && !s.assume(p, s.not(cond2))) { s.kill(pid, true); continue; }
            out.add(pid);
        }
    }
}

fn void SymState.walk_loop(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    Node* body = n.child_count > 0 ? n.children[n.child_count - 1] : null;
    if (body == null) { return; }
    SxSet entered; entered.count = 0;
    for (usz i = 0; i < in.count; i++)
    {
        int pid = in.ids[i];
        if (!s.live(pid)) { continue; }
        SxPath* p = &s.paths[pid];
        s.havoc_assigned(p, n, 0);
        for (usz c = 0; c + 1 < n.child_count; c++)
        {
            Node* ch = n.children[c];
            if (ch == null) { continue; }
            if (ch.kind >= pfront_core::N_PAT_FIRST) { s.bind_pattern(p, ch, -1); }
            else { s.eval(p, ch, depth + 1); }
        }
        int q = s.fork(pid);
        if (q >= 0) { s.paths[q].in_loop = s.paths[q].in_loop + 1; entered.add(q); }
        out.add(pid);   // the zero-iteration / exit path
    }
    SxSet after; after.count = 0;
    s.walk_block_set(&entered, &after, body, depth + 1);
    for (usz i = 0; i < after.count; i++)
    {
        int pid = after.ids[i];
        s.paths[pid].in_loop = s.paths[pid].in_loop - 1;
        s.havoc_assigned(&s.paths[pid], body, 0);
        out.add(pid);
    }
}

// One statement over a set.
fn void SymState.walk_stmt_set(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    if (n == null) { for (usz i = 0; i < in.count; i++) { out.add(in.ids[i]); } return; }
    if (depth > SX_MAX_DEPTH) { s.bound_hits = s.bound_hits + 1; return; }
    switch (n.kind)
    {
        case N_EXPR_IF:    s.walk_if(in, out, n, depth); return;
        case N_EXPR_MATCH: s.walk_match(in, out, n, depth); return;
        case N_EXPR_WHILE: s.walk_while(in, out, n, depth); return;
        case N_EXPR_FOR:
        case N_EXPR_LOOP:  s.walk_loop(in, out, n, depth); return;
        case N_BLOCK:
        case N_STMT_EXPR:  s.walk_block_set(in, out, n, depth); return;
        case N_STMT_RETURN:
            for (usz i = 0; i < in.count; i++)
            {
                int pid = in.ids[i];
                if (!s.live(pid)) { continue; }
                if (n.child_count >= 1) { s.eval(&s.paths[pid], n.children[0], depth + 1); }
                s.kill(pid, false);
            }
            return;
        case N_STMT_BREAK:
        case N_STMT_CONTINUE:
            for (usz i = 0; i < in.count; i++) { if (s.live(in.ids[i])) { s.kill(in.ids[i], false); } }
            return;
        case N_DECL_FN:
        case N_EXPR_LAMBDA:
        case N_EXPR_QUOTE:
        case N_EXPR_COMPTIME:
            for (usz i = 0; i < in.count; i++) { out.add(in.ids[i]); }
            return;
        default: break;
    }
    // Straight-line statement: apply to every path independently.
    for (usz i = 0; i < in.count; i++)
    {
        int pid = in.ids[i];
        if (!s.live(pid)) { continue; }
        s.walk_simple(&s.paths[pid], n, depth);
        if (s.live(pid)) { out.add(pid); }
    }
}

fn void SymState.walk_simple(SymState* s, SxPath* p, Node* n, int depth)
{
    switch (n.kind)
    {
        case N_DECL_LET:
        {
            if (n.child_count < 1) { return; }
            int v = n.child_count >= 2 ? s.eval(p, n.children[n.child_count - 1], depth + 1) : -1;
            s.bind_pattern(p, n.children[0], v);
            return;
        }
        case N_STMT_ASSIGN:
        case N_EXPR_ASSIGN:
        {
            if (n.child_count < 2) { return; }
            Node* lhs = n.children[0];
            int v = s.eval(p, n.children[1], depth + 1);
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT) { p.bind(binder_of(lhs), lhs.name_id, v); }
            else { s.eval(p, lhs, depth + 1); }   // field/index target: evaluate for faults only
            return;
        }
        case N_STMT_COMPOUND_ASSIGN:
        {
            if (n.child_count < 2) { return; }
            Node* lhs = n.children[0];
            s.eval(p, n.children[1], depth + 1);
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT) { p.bind(binder_of(lhs), lhs.name_id, s.havoc(lhs.name_id)); }
            return;
        }
        default:
        {
            if (n.kind >= pfront_core::N_EXPR_FIRST && n.kind <= pfront_core::N_EXPR_LAST) { s.eval(p, n, depth + 1); return; }
            for (usz i = 0; i < n.child_count && p.alive && p.feasible; i++)
            {
                Node* c = n.children[i];
                if (c != null && c.kind >= pfront_core::N_EXPR_FIRST && c.kind <= pfront_core::N_EXPR_LAST) { s.eval(p, c, depth + 1); }
            }
            return;
        }
    }
}

// A block (or a single statement used as one) over a set.
fn void SymState.walk_block_set(SymState* s, SxSet* in, SxSet* out, Node* n, int depth)
{
    if (n == null || in.count == 0) { for (usz i = 0; i < in.count; i++) { out.add(in.ids[i]); } return; }
    if (n.kind != Nk.N_BLOCK && n.kind != Nk.N_STMT_EXPR) { s.walk_stmt_set(in, out, n, depth); return; }
    SxSet cur; cur.count = in.count;
    for (usz i = 0; i < in.count; i++) { cur.ids[i] = in.ids[i]; }
    for (usz i = 0; i < n.child_count && cur.count > 0; i++)
    {
        SxSet nxt; nxt.count = 0;
        s.walk_stmt_set(&cur, &nxt, n.children[i], depth + 1);
        cur = nxt;
    }
    for (usz i = 0; i < cur.count; i++) { out.add(cur.ids[i]); }
}

// Value-position control flow inside an expression: explore the branches
// for faults on throwaway forks; the enclosing path continues unconstrained.
fn void SymState.explore(SymState* s, SxPath* p, Node* n, int depth)
{
    int pid = (int)(((usz)(void*)p - (usz)(void*)s.paths) / SxPath::size);
    int q = s.fork(pid);
    if (q < 0) { return; }
    SxSet in; in.count = 0; in.add(q);
    SxSet out; out.count = 0;
    s.walk_stmt_set(&in, &out, n, depth);
    for (usz i = 0; i < out.count; i++) { s.kill(out.ids[i], false); }
}

// Execute one function: parameters symbolic, then each clause body.
fn void SymState.run_fn(SymState* s, Node* fnode)
{
    if (s.paths == null || s.vals == null) { return; }
    if (fnode.kind == Nk.N_DECL_FN && (fnode.flags & pfront_core::NF_SYNTHETIC) != 0) { return; }  // rewrite/pgen blocks
    s.fns_run = s.fns_run + 1;
    s.cur_fn = fnode;
    s.branch_count = 0;

    // Brace form: N_DECL_PARAM... then N_BLOCK. Clause form: N_CLAUSE(pattern, body).
    bool any_clause = false;
    for (usz i = 0; i < fnode.child_count; i++)
    {
        Node* c = fnode.children[i];
        if (c != null && c.kind == Nk.N_CLAUSE) { any_clause = true; }
    }
    if (any_clause)
    {
        for (usz i = 0; i < fnode.child_count; i++)
        {
            Node* cl = fnode.children[i];
            if (cl == null || cl.kind != Nk.N_CLAUSE || cl.child_count < 2) { continue; }
            s.path_count = 0;
            s.val_count = 0;
            s.var_count = 0;
            SxPath* p = &s.paths[0];
            if (!p.reset()) { return; }
            s.path_count = 1;
            s.bind_pattern(p, cl.children[0], -1);
            Node* guard = cl.child_count >= 3 ? cl.children[1] : null;
            if (guard != null && guard.kind != Nk.N_BLOCK && cl.child_count >= 3)
            {
                s.assume(p, s.eval(p, guard, 0));
            }
            SxSet in; in.count = 0; in.add(0);
            SxSet out; out.count = 0;
            s.walk_block_set(&in, &out, cl.children[cl.child_count - 1], 0);
            s.paths_total = s.paths_total + s.path_count;
            s.flush_branches();
        }
        return;
    }
    s.path_count = 0;
    s.val_count = 0;
    s.var_count = 0;
    SxPath* p = &s.paths[0];
    if (!p.reset()) { return; }
    s.path_count = 1;
    for (usz i = 0; i < fnode.child_count; i++)
    {
        Node* c = fnode.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM) { s.bind_pattern(p, c, -1); }
        else if (c.kind == Nk.N_BLOCK)
        {
            SxSet in; in.count = 0; in.add(0);
            SxSet out; out.count = 0;
            s.walk_block_set(&in, &out, c, 0);
        }
    }
    s.paths_total = s.paths_total + s.path_count;
    s.flush_branches();
}

fn void SymState.run_on(SymState* s, Node* root)
{
    s.visit(root, 0);
}

fn void SymState.visit(SymState* s, Node* n, int depth)
{
    if (n == null || depth > 128) { return; }
    if (n.kind == Nk.N_DECL_FN)
    {
        s.run_fn(n);
        // Nested fns / lambdas inside get their own runs.
    }
    for (usz i = 0; i < n.child_count; i++) { s.visit(n.children[i], depth + 1); }
}

fn void SymState.report(SymState* s)
{
    printf("  symexe           : %d fns, %d paths (%d pruned infeasible, %d forks, %d bound hits), %d solver rounds\n",
           (int)s.fns_run, (int)s.paths_total, (int)s.paths_pruned, (int)s.forks, (int)s.bound_hits,
           (int)s.solver_rounds);
    printf("  symexe-findings  : %d div-by-zero, %d branches decided by path, %d asserts failing, %d asserts proved, %d havocs\n",
           (int)s.div_zero, (int)s.dead_branch, (int)s.assert_fail, (int)s.assert_proved, (int)s.havocs);
}
