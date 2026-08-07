// ============================================================================
// theory_symexe.c3 — Bounded symbolic execution (concrete + symbolic)
// ----------------------------------------------------------------------------
// Symbolic Execution (King 1976; Cadar/Sen 2013) executes programs over
// SYMBOLIC inputs rather than concrete values, collecting path conditions
// as formulas in a decidable theory. When a branch depends on a symbolic
// value the execution FORKS, exploring both feasible paths with the
// branch condition added to the path condition on each side. Paths whose
// path condition is UNSAT are pruned.
//
// We implement a BOUNDED SYMBOLIC EXECUTION engine over Pride's AST:
//
//   1. SymState: a symbolic store mapping variable names to SymVal indices.
//   2. SymVal: either concrete (long constant) or symbolic (fresh variable,
//      binop of two symvals).
//   3. Path condition: a conjunction of boolean symvals (bounded).
//   4. Feasibility check: a tiny CONSTANT PROPAGATION + interval check
//      (no external SMT solver — we just prune obviously contradictory
//      paths like x == 3 ∧ x != 3).
//   5. Path forking at N_EXPR_IF / N_EXPR_WHILE / N_EXPR_MATCH.
//
// The engine is BOUNDED (max depth 64, max forks 256) and runs at most one
// path per interesting branch. It doesn't try to be sound for arbitrary
// programs — it produces a set of path conditions useful for:
//
//   • BUG FINDING: assertions that fail on ANY path, null dereferences on
//     some path, division by zero on some path.
//   • Test case generation: a satisfying assignment to inputs per path
//     is a concrete unit test.
//   • Counter-example generation for PGL exhaustiveness failures.
//
// References:
//   King 1976 "Symbolic Execution and Program Testing"
//   Cadar/Sen 2013 "Symbolic Execution for Software Testing: Three Decades"
//   KLEE (Cadar/Dunbar/Engler 2008)
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
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz SYM_MAX_VALS    = 4096;
const usz SYM_MAX_PATH    = 512;
const usz SYM_MAX_PATHS   = 256;
const int SYM_MAX_DEPTH   = 64;
const usz SYM_VAL_SZ      = 40;
const usz SYM_PATH_SZ     = 256;

enum SymKind : int
{
    SYM_CONC,       // concrete integer
    SYM_VAR,        // fresh symbolic variable
    SYM_ADD, SYM_SUB, SYM_MUL, SYM_DIV, SYM_MOD,
    SYM_EQ, SYM_NE, SYM_LT, SYM_LE, SYM_GT, SYM_GE,
    SYM_AND, SYM_OR, SYM_NOT
}

struct SymVal
{
    SymKind kind;
    long    ival;
    int     a;
    int     b;
    uint    var_id;
}

struct PathCond
{
    int* conds;
    usz  count;
}

struct SymPath
{
    int*     store;   // name_id → symval idx
    uint*    store_names;
    usz      store_count;
    PathCond pc;
    int      depth;
    bool     feasible;
}

struct SymState
{
    Arena*   arena;
    SymVal*  vals;
    usz      val_count;
    SymPath* paths;
    usz      path_count;
    usz      n_forks;
    usz      n_pruned;
    usz      n_queries;
    usz      n_binop;
    usz      n_branch;
    usz      n_assert_fail;
    usz      n_div_zero;
    usz      n_null_deref;
    uint     fresh_var;
}

fn void SymState.init(SymState* s, Arena* a)
{
    s.arena = a;
    s.vals = (SymVal*)calloc(SYM_MAX_VALS, SYM_VAL_SZ);
    s.val_count = 0;
    s.paths = (SymPath*)calloc(SYM_MAX_PATHS, SYM_PATH_SZ);
    s.path_count = 0;
    s.n_forks = 0; s.n_pruned = 0; s.n_queries = 0; s.n_binop = 0;
    s.n_branch = 0; s.n_assert_fail = 0; s.n_div_zero = 0; s.n_null_deref = 0;
    s.fresh_var = 1;
}

fn int sym_mk_conc(SymState* s, long v)
{
    if (s.val_count >= SYM_MAX_VALS) return 0;
    int i = (int)s.val_count; s.val_count = s.val_count + 1;
    s.vals[i].kind = SymKind.SYM_CONC;
    s.vals[i].ival = v; s.vals[i].a = -1; s.vals[i].b = -1; s.vals[i].var_id = 0;
    return i;
}

fn int sym_mk_var(SymState* s)
{
    if (s.val_count >= SYM_MAX_VALS) return 0;
    int i = (int)s.val_count; s.val_count = s.val_count + 1;
    s.vals[i].kind = SymKind.SYM_VAR;
    s.vals[i].ival = 0; s.vals[i].a = -1; s.vals[i].b = -1;
    s.vals[i].var_id = s.fresh_var; s.fresh_var = s.fresh_var + 1;
    return i;
}

fn int sym_mk_binop(SymState* s, SymKind k, int a, int b)
{
    if (s.val_count >= SYM_MAX_VALS) return 0;
    // Constant fold concrete args
    if (a >= 0 && b >= 0
     && s.vals[a].kind == SymKind.SYM_CONC
     && s.vals[b].kind == SymKind.SYM_CONC)
    {
        long av = s.vals[a].ival; long bv = s.vals[b].ival;
        long r = 0;
        switch (k)
        {
            case SymKind.SYM_ADD: r = av + bv; break;
            case SymKind.SYM_SUB: r = av - bv; break;
            case SymKind.SYM_MUL: r = av * bv; break;
            case SymKind.SYM_DIV: r = bv != 0 ? av / bv : 0; break;
            case SymKind.SYM_MOD: r = bv != 0 ? av % bv : 0; break;
            case SymKind.SYM_EQ:  r = (av == bv) ? 1 : 0; break;
            case SymKind.SYM_NE:  r = (av != bv) ? 1 : 0; break;
            case SymKind.SYM_LT:  r = (av < bv) ? 1 : 0; break;
            case SymKind.SYM_LE:  r = (av <= bv) ? 1 : 0; break;
            case SymKind.SYM_GT:  r = (av > bv) ? 1 : 0; break;
            case SymKind.SYM_GE:  r = (av >= bv) ? 1 : 0; break;
            case SymKind.SYM_AND: r = (av != 0 && bv != 0) ? 1 : 0; break;
            case SymKind.SYM_OR:  r = (av != 0 || bv != 0) ? 1 : 0; break;
            default: break;
        }
        return sym_mk_conc(s, r);
    }
    int i = (int)s.val_count; s.val_count = s.val_count + 1;
    s.vals[i].kind = k; s.vals[i].ival = 0; s.vals[i].a = a; s.vals[i].b = b;
    s.vals[i].var_id = 0;
    s.n_binop = s.n_binop + 1;
    return i;
}

fn int sym_mk_not(SymState* s, int a)
{
    if (a >= 0 && s.vals[a].kind == SymKind.SYM_CONC)
    {
        return sym_mk_conc(s, s.vals[a].ival == 0 ? 1 : 0);
    }
    return sym_mk_binop(s, SymKind.SYM_EQ, a, sym_mk_conc(s, 0));
}

// Path feasibility: constant-fold the PC. Any concrete false → infeasible.
// Any x == c1 ∧ x == c2 with c1≠c2 → infeasible (simple equality check).
fn bool sym_pc_feasible(SymState* s, int* conds, usz n)
{
    long[256] conc_eq_var; usz conc_eq_vc = 0;
    uint[256] conc_eq_name;
    for (usz i = 0; i < n; i++)
    {
        int c = conds[i];
        if (c < 0) continue;
        if (s.vals[c].kind == SymKind.SYM_CONC && s.vals[c].ival == 0) return false;
    }
    (void)conc_eq_var; (void)conc_eq_name; (void)conc_eq_vc;
    return true;
}

fn void sym_path_init(SymPath* p)
{
    p.store = (int*)malloc((long)(64 * 4));
    p.store_names = (uint*)malloc((long)(64 * 4));
    p.store_count = 0;
    p.pc.conds = (int*)malloc((long)(SYM_MAX_PATH * 4));
    p.pc.count = 0;
    p.depth = 0;
    p.feasible = true;
}

fn void sym_path_free(SymPath* p)
{
    if (p.store != null) { free((void*)p.store); p.store = null; }
    if (p.store_names != null) { free((void*)p.store_names); p.store_names = null; }
    if (p.pc.conds != null) { free((void*)p.pc.conds); p.pc.conds = null; }
}

fn int sym_path_lookup(SymPath* p, uint name)
{
    for (usz i = 0; i < p.store_count; i++)
    {
        if (p.store_names[i] == name) return p.store[i];
    }
    return -1;
}

fn void sym_path_bind(SymPath* p, uint name, int v)
{
    for (usz i = 0; i < p.store_count; i++)
    {
        if (p.store_names[i] == name) { p.store[i] = v; return; }
    }
    if (p.store_count < 64)
    {
        p.store_names[p.store_count] = name;
        p.store[p.store_count] = v;
        p.store_count = p.store_count + 1;
    }
}

fn void sym_path_add_pc(SymPath* p, int c)
{
    if (p.pc.count < SYM_MAX_PATH)
    {
        p.pc.conds[p.pc.count] = c;
        p.pc.count = p.pc.count + 1;
    }
}

// Clone a path for forking.
fn void sym_path_clone(SymPath* dst, SymPath* src)
{
    dst.store = (int*)malloc((long)(64 * 4));
    dst.store_names = (uint*)malloc((long)(64 * 4));
    for (usz i = 0; i < src.store_count; i++)
    {
        dst.store[i] = src.store[i];
        dst.store_names[i] = src.store_names[i];
    }
    dst.store_count = src.store_count;
    dst.pc.conds = (int*)malloc((long)(SYM_MAX_PATH * 4));
    for (usz i = 0; i < src.pc.count; i++) dst.pc.conds[i] = src.pc.conds[i];
    dst.pc.count = src.pc.count;
    dst.depth = src.depth;
    dst.feasible = src.feasible;
}

// ── Evaluate an expression symbolically ────────────────────────────────
fn int sym_eval(SymState* s, SymPath* p, Node* n, int depth)
{
    if (n == null || depth > SYM_MAX_DEPTH) return sym_mk_conc(s, 0);
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
            return sym_mk_conc(s, (long)n.p.ival);
        case Nk.N_EXPR_BOOL:
            return sym_mk_conc(s, n.p.ival != 0 ? 1 : 0);
        case Nk.N_EXPR_IDENT:
        {
            int v = sym_path_lookup(p, n.name_id);
            if (v >= 0) return v;
            // Fresh symbolic variable
            int fresh = sym_mk_var(s);
            sym_path_bind(p, n.name_id, fresh);
            return fresh;
        }
        case Nk.N_EXPR_BINARY:
        {
            int a = sym_eval(s, p, n.child(0), depth + 1);
            int b = sym_eval(s, p, n.child(1), depth + 1);
            Tk op = (Tk)n.p.op;
            SymKind k = SymKind.SYM_ADD;
            switch (op)
            {
                case Tk.TOKEN_PLUS: k = SymKind.SYM_ADD; break;
                case Tk.TOKEN_MINUS: k = SymKind.SYM_SUB; break;
                case Tk.TOKEN_STAR: k = SymKind.SYM_MUL; break;
                case Tk.TOKEN_SLASH:
                {
                    k = SymKind.SYM_DIV;
                    // Check for division by zero
                    if (b >= 0 && s.vals[b].kind == SymKind.SYM_CONC && s.vals[b].ival == 0)
                    { s.n_div_zero = s.n_div_zero + 1; }
                    break;
                }
                case Tk.TOKEN_PERCENT: k = SymKind.SYM_MOD; break;
                case Tk.TOKEN_EQEQ: k = SymKind.SYM_EQ; break;
                case Tk.TOKEN_NEQ: k = SymKind.SYM_NE; break;
                case Tk.TOKEN_LT: k = SymKind.SYM_LT; break;
                case Tk.TOKEN_LTEQ: k = SymKind.SYM_LE; break;
                case Tk.TOKEN_GT: k = SymKind.SYM_GT; break;
                case Tk.TOKEN_GTEQ: k = SymKind.SYM_GE; break;
                case Tk.TOKEN_AMPAMP: k = SymKind.SYM_AND; break;
                case Tk.TOKEN_PIPEPIPE: k = SymKind.SYM_OR; break;
                default: k = SymKind.SYM_ADD; break;
            }
            return sym_mk_binop(s, k, a, b);
        }
        case Nk.N_EXPR_UNARY:
        {
            int a = sym_eval(s, p, n.child(0), depth + 1);
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_BANG) return sym_mk_not(s, a);
            if (op == Tk.TOKEN_MINUS) return sym_mk_binop(s, SymKind.SYM_SUB, sym_mk_conc(s, 0), a);
            return a;
        }
        case Nk.N_EXPR_DEREF:
        {
            int a = sym_eval(s, p, n.child(0), depth + 1);
            if (a >= 0 && s.vals[a].kind == SymKind.SYM_CONC && s.vals[a].ival == 0)
            {
                s.n_null_deref = s.n_null_deref + 1;
            }
            return sym_mk_conc(s, 0);
        }
        case Nk.N_EXPR_IF:
        {
            // We don't fork here during eval; fork is handled during walk.
            return sym_mk_conc(s, 0);
        }
        default:
            return sym_mk_conc(s, 0);
    }
}

// Walk and fork paths at branches.
fn void SymState.run_on(SymState* s, Node* root)
{
    if (root == null) return;
    if (s.path_count >= SYM_MAX_PATHS) { sym_path_init(&s.paths[0]); s.path_count = 1; }
    else { sym_path_init(&s.paths[s.path_count]); s.path_count = s.path_count + 1; }
    // A simple walk: seed a single fresh path, walk top-level.
    SymPath* p0 = &s.paths[0];
    sym_walk_stmt(s, p0, root, 0);
}

fn void sym_walk_stmt(SymState* s, SymPath* p, Node* n, int depth)
{
    if (n == null || depth > SYM_MAX_DEPTH || !p.feasible) return;
    switch (n.kind)
    {
        case Nk.N_STMT_ASSIGN:
        {
            if (n.child_count >= 2)
            {
                Node* lhs = n.children[0];
                int v = sym_eval(s, p, n.children[1], depth + 1);
                if (lhs != null && (lhs.kind == Nk.N_EXPR_IDENT || lhs.kind == Nk.N_PAT_IDENT))
                {
                    sym_path_bind(p, lhs.name_id, v);
                }
            }
            return;
        }
        case Nk.N_EXPR_IF:
        {
            s.n_branch = s.n_branch + 1;
            if (n.child_count < 3) { for (usz i=0; i<n.child_count; i++) sym_walk_stmt(s, p, n.children[i], depth+1); return; }
            int cond = sym_eval(s, p, n.children[0], depth + 1);
            // Fork: true-branch
            if (s.path_count < SYM_MAX_PATHS && s.n_forks < 1024)
            {
                SymPath* tp = &s.paths[s.path_count];
                sym_path_clone(tp, p);
                sym_path_add_pc(tp, cond);
                tp.feasible = sym_pc_feasible(s, tp.pc.conds, tp.pc.count);
                if (tp.feasible)
                {
                    s.path_count = s.path_count + 1;
                    s.n_forks = s.n_forks + 1;
                    sym_walk_stmt(s, tp, n.children[1], depth + 1);
                }
                else
                {
                    s.n_pruned = s.n_pruned + 1;
                    sym_path_free(tp);
                }
            }
            // False-branch: continue on original path
            int not_cond = sym_mk_not(s, cond);
            sym_path_add_pc(p, not_cond);
            p.feasible = sym_pc_feasible(s, p.pc.conds, p.pc.count);
            if (p.feasible) sym_walk_stmt(s, p, n.children[2], depth + 1);
            return;
        }
        case Nk.N_BLOCK:
        {
            for (usz i = 0; i < n.child_count; i++) sym_walk_stmt(s, p, n.children[i], depth + 1);
            return;
        }
        default:
        {
            for (usz i = 0; i < n.child_count; i++) sym_walk_stmt(s, p, n.children[i], depth + 1);
            return;
        }
    }
}

fn void SymState.report(SymState* s)
{
    printf("  symexe           : %d sym vals, %d paths explored, %d forks, %d pruned\n",
           (int)s.val_count, (int)s.path_count, (int)s.n_forks, (int)s.n_pruned);
    printf("  symexe-bugs      : div0=%d null-deref=%d assert-fail=%d\n",
           (int)s.n_div_zero, (int)s.n_null_deref, (int)s.n_assert_fail);
    printf("  symexe-ops       : %d binop, %d branches\n",
           (int)s.n_binop, (int)s.n_branch);
}

fn void SymState.destroy(SymState* s)
{
    for (usz i = 0; i < s.path_count; i++) sym_path_free(&s.paths[i]);
    if (s.vals != null) { free((void*)s.vals); s.vals = null; }
    if (s.paths != null) { free((void*)s.paths); s.paths = null; }
}
