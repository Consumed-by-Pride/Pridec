// ============================================================================
// theory_cps.c3 — CPS translation into an explicit continuation IR, with the
//                 CPS-level analyses that make control flow a data structure
// ----------------------------------------------------------------------------
// The previous file in this slot counted call sites and called the count
// "administrative redexes avoided". Nothing was translated. This module
// performs the Danvy–Filinski one-pass call-by-value CPS translation of
// every function into a small continuation IR (Kennedy 2007, "Compiling
// with Continuations, Continued"), then runs real analyses and rewrites on
// the terms it built:
//
//   TERM LANGUAGE (per function: params p₀…pₙ, return continuation k_ret)
//     t ::= f(a₁…aₙ; k)             application with continuation VARIABLE k
//         | f(a₁…aₙ; λx. t)         application with an INLINE continuation
//         | k(a)                    jump: apply a continuation
//         | let x = prim(a…) in t   primitive / projection / opaque node
//         | letk j(x) = t₁ in t₂    continuation (join point / loop header)
//         | letf f(p…; k) = t₁ in t₂ local function (lambda, handler arm)
//         | if a then t₁ else t₂
//         | case a of t₁ … tₙ
//         | halt
//
//   TRANSLATION (one pass, no administrative redexes are ever built)
//     • value position: [[e]] yields an atom, emitting bindings into a hole
//       that is threaded through the walk (`CTerm**`). A call in value
//       position becomes f(a…; λx. □) — the hole moves into the continuation
//       body, which is exactly "the rest of the computation".
//     • tail position: [[e]] k. `if`/`match`/loops/blocks in tail position
//       branch straight to k — no join point is created. In value position
//       they get one: letk j(x) = □ in [[e]] j. This is where Danvy–Filinski
//       differ from Fischer/Plotkin: the join is created only when there is
//       something to join.
//     • loops are continuations: while c do b ≡
//         letk loop(_) = [[c]] (λv. if v then [[b]] (λ_. loop(unit)) else k(unit))
//         in loop(unit)
//       `break` jumps to k, `continue` jumps to loop, `return` jumps to k_ret.
//     • `a and b` / `a or b` are short-circuit: translated as `if`.
//     • lambdas / handler arms are letf; `perform` and `resume` are
//       applications of the effect operation with the current continuation
//       (that is what makes the continuation capturable at that point).
//
//   ANALYSES / REWRITES ON THE CPS TERM (all counts are actual term mutations
//   or facts read off the built term, never estimates)
//     • tail-call verdicts: a source call is a tail call iff its CPS form is
//       f(a…; k) with k a continuation variable that is the function's k_ret.
//       Every such N_EXPR_CALL gets NF_TAIL (the same bit the parser sets for
//       an explicit `tail` annotation) so the backend may release the frame.
//     • W4200: an explicit `tail` annotation on a call that is NOT in tail
//       position (its value flows into an enclosing expression).
//     • continuation contraction: letk j(x) = t used exactly once → inlined
//       (β); letk j(x) = k'(x) → every j replaced by k' (η); unused → dropped.
//     • contification (Kennedy §6 / Fluet–Weeks): a letf f whose every use is
//       a call with the SAME continuation variable K, and which is never used
//       as a value, is a continuation in disguise: its k_ret is replaced by K
//       and it is marked contified — the backend needs no closure, no call,
//       just a jump. N4203 under --lint.
//     • frame census per function: number of pending continuations along the
//       deepest path (how many frames a straight-line evaluation needs), self
//       tail calls (loops), self non-tail calls (real recursion), effect
//       capture points.
//     • N4201 (--lint): a self call in tail position that the source did not
//       annotate — it is a loop already; the annotation would document it.
//
//   --emit-cps prints every function's term after contraction.
//
// Diagnostics: W4200, N4201, N4203 (PH_RESOLVE namespace, 42xx).
//
// References: Danvy & Filinski 1992 "Representing Control"; Kennedy 2007
// "Compiling with Continuations, Continued"; Fluet & Weeks 2001
// "Contification using dominators"; Appel 1992 "Compiling with Continuations".
// ============================================================================

module theory_cps;

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

const int CPS_MAX_DEPTH   = 200;
const usz CPS_MAX_VARS    = 65536;
const usz CPS_MAX_FNS     = 4096;
const usz CPS_LOOP_STACK  = 64;
const usz CPS_ENV_BUCKETS = 4096;

// ── Atoms ───────────────────────────────────────────────────────────────
enum Ak : char
{
    A_UNIT,
    A_LIT,       // literal; ival/fval/text not needed for analysis
    A_VAR,       // CPS variable (vid)
    A_GLOBAL,    // a top-level fn / unresolved global name
    A_EFFECT,    // an effect operation (perform target)
    A_RESUME     // the captured continuation inside a handler arm
}

struct Atom
{
    Ak    kind;
    int   vid;      // A_VAR: variable id
    uint  name;     // interned name for printing (A_GLOBAL / A_EFFECT / binders)
    Node* decl;     // A_GLOBAL: the fn decl if resolved
    long  ival;
}

// ── Terms ───────────────────────────────────────────────────────────────
enum Ck : char
{
    CK_HALT,
    CK_APP,      // f(args; k) or f(args; λx. body)
    CK_JUMP,     // kid(args[0])
    CK_LETV,     // let x = prim(args) in body
    CK_LETK,     // letk kid(x) = rhs in body
    CK_LETF,     // letf f(params; ret_k) = rhs in body
    CK_IF,       // if args[0] then body else alt
    CK_CASE      // case args[0] of arms[0..n)
}

// what a CK_LETV computes
enum Prim : char
{
    P_COPY,      // x = a
    P_BINOP,     // x = a op b          (op = token)
    P_UNOP,      // x = op a
    P_PROJ,      // x = pattern projection of a (pattern node in src)
    P_ASSIGN,    // a := b              (mutation, x unused)
    P_TUPLE,     // x = (a…)
    P_FIELD,     // x = a.name
    P_INDEX,     // x = a[b]
    P_ITER_NEXT, // x = next(a)  (for-loops; x is an option)
    P_OPAQUE     // x = <node kind>(a…)  (anything we do not model)
}

struct CTerm
{
    Ck     kind;
    Node*  src;
    Atom   f;            // APP callee
    Atom*  args;
    usz    n_args;
    int    kid;          // APP: continuation variable (0 = inline); JUMP target; LETK name
    int    x;            // LETV/LETK/APP-inline bound variable
    Prim   prim;
    int    op;
    CTerm* body;
    CTerm* rhs;
    CTerm* alt;
    CTerm** arms;
    usz    n_arms;
    int*   params;
    usz    n_params;
    int    fvar;         // LETF: variable bound to the function
    int    ret_k;        // LETF: its return continuation
    // verdicts
    bool   self_tail;    // APP: tail call to the enclosing top-level fn
    bool   is_tail;      // APP: continuation is k_ret of the enclosing fn
    bool   contified;    // LETF
    bool   is_loop;      // LETK: loop header
    bool   is_join;      // LETK: join for a value-position branch
    bool   effect;       // APP: perform / resume
    bool   under_prompt; // APP: inside a handled body (frame cannot be released)
}

// ── Variables ───────────────────────────────────────────────────────────
struct VarInfo
{
    uint  name;      // 0 for temporaries
    Node* binder;    // source binder, if any
    bool  is_k;      // continuation variable
    usz   uses;      // filled by census
}

// binder Node* → vid
struct EnvEntry
{
    Node* binder;
    int   vid;
    EnvEntry* next;
}

struct LoopCtx
{
    int loop_k;
    int exit_k;
}

// per-function facts (kept for the report and the --lint notes)
struct FnFacts
{
    Node*  decl;
    uint   name;
    CTerm* term;
    int*   params;
    usz    n_params;
    int    ret_k;
    usz    n_apps;
    usz    n_tail;
    usz    n_nontail;
    usz    n_self_tail;
    usz    n_self_nontail;
    usz    n_joins;
    usz    n_loops;
    usz    n_letf;
    usz    n_contified;
    usz    n_effect_pts;
    usz    max_frames;
    usz    n_eta;
    usz    n_beta;
    usz    n_dead_k;
    bool   loop_only;     // self recursion is exclusively tail: runs as a loop
}

struct CpsXform
{
    Arena* arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*  file;
    bool   emit;              // --emit-cps

    VarInfo* vars;
    int      n_vars;
    EnvEntry*[CPS_ENV_BUCKETS] env;

    FnFacts* fns;
    usz      n_fns;

    // translation state for the function being translated
    Node*    cur_fn;
    int      cur_ret_k;
    int      cur_fvar;
    LoopCtx[CPS_LOOP_STACK] loops;
    usz      n_loops;
    int      prompt_depth;
    int      depth;

    // aggregate
    usz n_apps, n_tail, n_nontail, n_self_tail, n_self_nontail;
    usz n_joins, n_joins_avoided, n_loops_total, n_letf, n_contified;
    usz n_effect_pts, n_eta, n_beta, n_dead_k, n_marked_tail;
    usz n_w4200, n_n4201, n_n4203, n_loop_fns, n_rec_fns;
    usz max_frames_all;
    uint max_frames_fn;
    usz n_terms;
}

// ── Setup ───────────────────────────────────────────────────────────────
fn void CpsXform.init(CpsXform* cx, Arena* a)
{
    cx.arena = a;
    cx.diags = null; cx.interner = null; cx.file = null; cx.emit = false;
    cx.vars = (VarInfo*)calloc(CPS_MAX_VARS, VarInfo::size);
    cx.n_vars = 1;   // vid 0 = "no variable"
    for (usz i = 0; i < CPS_ENV_BUCKETS; i++) { cx.env[i] = null; }
    cx.fns = (FnFacts*)calloc(CPS_MAX_FNS, FnFacts::size);
    cx.n_fns = 0;
    cx.cur_fn = null; cx.cur_ret_k = 0; cx.cur_fvar = 0; cx.n_loops = 0; cx.prompt_depth = 0; cx.depth = 0;
    cx.n_apps = 0; cx.n_tail = 0; cx.n_nontail = 0; cx.n_self_tail = 0; cx.n_self_nontail = 0;
    cx.n_joins = 0; cx.n_joins_avoided = 0; cx.n_loops_total = 0; cx.n_letf = 0; cx.n_contified = 0;
    cx.n_effect_pts = 0; cx.n_eta = 0; cx.n_beta = 0; cx.n_dead_k = 0; cx.n_marked_tail = 0;
    cx.n_w4200 = 0; cx.n_n4201 = 0; cx.n_n4203 = 0; cx.n_loop_fns = 0; cx.n_rec_fns = 0;
    cx.max_frames_all = 0; cx.max_frames_fn = 0; cx.n_terms = 0;
}

fn void CpsXform.attach(CpsXform* cx, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    cx.diags = d; cx.interner = it; cx.file = file;
}

fn void CpsXform.destroy(CpsXform* cx)
{
    if (cx.vars != null) { free((void*)cx.vars); cx.vars = null; }
    if (cx.fns != null) { free((void*)cx.fns); cx.fns = null; }
}

fn char* CpsXform.name(CpsXform* cx, uint id)
{
    if (cx.interner == null || id == 0) { return "_"; }
    char* s = cx.interner.text(id);
    return s == null ? "_" : s;
}

fn void* CpsXform.zalloc(CpsXform* cx, usz size)
{
    void* p = cx.arena.alloc(size, 8);
    if (p != null) { memset(p, 0, size); }
    return p;
}

fn char* CpsXform.msgbuf(CpsXform* cx)
{
    return (char*)cx.arena.alloc(512, 1);
}

// ── Variables & environment ─────────────────────────────────────────────
fn int CpsXform.fresh(CpsXform* cx, uint name, Node* binder, bool is_k)
{
    if ((usz)cx.n_vars >= CPS_MAX_VARS) { return 1; }
    int v = cx.n_vars;
    cx.vars[v].name = name; cx.vars[v].binder = binder; cx.vars[v].is_k = is_k; cx.vars[v].uses = 0;
    cx.n_vars = cx.n_vars + 1;
    return v;
}

fn usz env_hash(Node* b)
{
    ulong h = (ulong)(uptr)b;
    h = (h >> 4) * 0x9E3779B97F4A7C15UL;
    return (usz)(h >> 20) & (CPS_ENV_BUCKETS - 1);
}

fn int CpsXform.lookup(CpsXform* cx, Node* binder)
{
    if (binder == null) { return 0; }
    EnvEntry* e = cx.env[env_hash(binder)];
    while (e != null) { if (e.binder == binder) { return e.vid; } e = e.next; }
    return 0;
}

fn int CpsXform.bind(CpsXform* cx, Node* binder, uint name)
{
    int v = cx.fresh(name, binder, false);
    if (binder == null) { return v; }
    EnvEntry* e = (EnvEntry*)cx.zalloc(EnvEntry::size);
    if (e == null) { return v; }
    usz h = env_hash(binder);
    e.binder = binder; e.vid = v; e.next = cx.env[h];
    cx.env[h] = e;
    return v;
}

// a parameter: `param 'x'` wrapping a `pat-ident 'x'` — uses resolve to either
fn int CpsXform.bind_param(CpsXform* cx, Node* p)
{
    int v = cx.bind(p, p.name_id);
    for (usz i = 0; i < p.child_count; i++)
    {
        Node* c = p.children[i];
        if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
        if (c.kind == Nk.N_PAT_IDENT)
        {
            EnvEntry* e = (EnvEntry*)cx.zalloc(EnvEntry::size);
            if (e != null) { usz h = env_hash(c); e.binder = c; e.vid = v; e.next = cx.env[h]; cx.env[h] = e; }
        }
    }
    return v;
}

// ── Term constructors ───────────────────────────────────────────────────
fn CTerm* CpsXform.mk(CpsXform* cx, Ck k, Node* src)
{
    CTerm* t = (CTerm*)cx.zalloc(CTerm::size);
    if (t == null) { return null; }
    t.kind = k; t.src = src;
    cx.n_terms = cx.n_terms + 1;
    return t;
}

fn Atom atom_var(int v)  { Atom a; a.kind = Ak.A_VAR; a.vid = v; a.name = 0; a.decl = null; a.ival = 0; return a; }
fn Atom atom_unit()      { Atom a; a.kind = Ak.A_UNIT; a.vid = 0; a.name = 0; a.decl = null; a.ival = 0; return a; }
fn Atom atom_lit(long v) { Atom a; a.kind = Ak.A_LIT; a.vid = 0; a.name = 0; a.decl = null; a.ival = v; return a; }
fn Atom atom_global(uint name, Node* decl) { Atom a; a.kind = Ak.A_GLOBAL; a.vid = 0; a.name = name; a.decl = decl; a.ival = 0; return a; }

fn Atom* CpsXform.atoms(CpsXform* cx, usz n)
{
    if (n == 0) { return null; }
    return (Atom*)cx.zalloc(Atom::size * n);
}

// let x = prim(args) in □ ; returns x, advances hole
fn int CpsXform.emit_letv(CpsXform* cx, CTerm*** hole, Prim p, int op, Atom* args, usz n, Node* src, uint name)
{
    CTerm* t = cx.mk(Ck.CK_LETV, src);
    if (t == null) { return 0; }
    t.prim = p; t.op = op; t.args = args; t.n_args = n;
    t.x = cx.fresh(name, null, false);
    **hole = t;
    *hole = &t.body;
    return t.x;
}

fn void CpsXform.emit_jump(CpsXform* cx, CTerm** hole, int k, Atom a, Node* src)
{
    CTerm* t = cx.mk(Ck.CK_JUMP, src);
    if (t == null) { return; }
    t.kid = k;
    t.args = cx.atoms(1);
    if (t.args != null) { t.args[0] = a; }
    t.n_args = 1;
    *hole = t;
}

// letk j(x) = □rest in □body — returns j; *rest and *body receive the holes
fn int CpsXform.emit_letk(CpsXform* cx, CTerm** hole, Node* src, CTerm*** rest, CTerm*** body, bool is_loop)
{
    CTerm* t = cx.mk(Ck.CK_LETK, src);
    if (t == null) { return 0; }
    t.kid = cx.fresh(0, null, true);
    t.x   = cx.fresh(0, null, false);
    t.is_loop = is_loop; t.is_join = !is_loop;
    *hole = t;
    *rest = &t.rhs;
    *body = &t.body;
    return t.kid;
}

// ── Source helpers ──────────────────────────────────────────────────────
fn bool is_literal(Nk k)
{
    switch (k)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_STRING: case Nk.N_EXPR_BYTES: case Nk.N_EXPR_NULL: case Nk.N_EXPR_UNIT:
            return true;
        default: return false;
    }
}

fn bool is_control(Nk k)
{
    switch (k)
    {
        case Nk.N_EXPR_IF: case Nk.N_EXPR_MATCH: case Nk.N_EXPR_WHILE: case Nk.N_EXPR_FOR:
        case Nk.N_EXPR_LOOP: case Nk.N_BLOCK: case Nk.N_EXPR_HANDLE: case Nk.N_EXPR_UNSAFE:
        case Nk.N_EXPR_UNCHECKED:
            return true;
        default: return false;
    }
}

fn Node* last_child(Node* n)
{
    if (n == null || n.child_count == 0) { return null; }
    return n.children[n.child_count - 1];
}

fn bool is_short_circuit(int op)
{
    return op == (int)Tk.TOKEN_AMPAMP || op == (int)Tk.TOKEN_KW_AND
        || op == (int)Tk.TOKEN_PIPEPIPE || op == (int)Tk.TOKEN_KW_OR;
}

fn bool is_and_op(int op)
{
    return op == (int)Tk.TOKEN_AMPAMP || op == (int)Tk.TOKEN_KW_AND;
}

// Bind every pat-ident inside `pat` as a projection of `scrut`.
fn void CpsXform.bind_pattern(CpsXform* cx, CTerm*** hole, Node* pat, Atom scrut, int depth)
{
    if (pat == null || depth > CPS_MAX_DEPTH) { return; }
    if (pat.kind == Nk.N_PAT_IDENT)
    {
        Atom* a = cx.atoms(1);
        if (a != null) { a[0] = scrut; }
        CTerm* t = cx.mk(Ck.CK_LETV, pat);
        if (t == null) { return; }
        t.prim = Prim.P_PROJ; t.args = a; t.n_args = 1;
        t.x = cx.bind(pat, pat.name_id);
        **hole = t;
        *hole = &t.body;
        return;
    }
    for (usz i = 0; i < pat.child_count; i++)
    {
        Node* c = pat.children[i];
        if (c != null && pfront_core::is_pattern(c.kind)) { cx.bind_pattern(hole, c, scrut, depth + 1); }
    }
}

// ── Value-position translation: [[e]] → atom, bindings into the hole ────
fn Atom CpsXform.val(CpsXform* cx, Node* n, CTerm*** hole)
{
    if (n == null) { return atom_unit(); }
    cx.depth = cx.depth + 1;
    if (cx.depth > CPS_MAX_DEPTH) { cx.depth = cx.depth - 1; return atom_unit(); }
    Atom r = cx.val_inner(n, hole);
    cx.depth = cx.depth - 1;
    return r;
}

fn Atom CpsXform.val_inner(CpsXform* cx, Node* n, CTerm*** hole)
{
    switch (n.kind)
    {
        case Nk.N_EXPR_UNIT:
            return atom_unit();
        case Nk.N_EXPR_INT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR:
            return atom_lit((long)n.p.ival);
        case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_STRING: case Nk.N_EXPR_BYTES: case Nk.N_EXPR_NULL:
            return atom_lit(0);
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_SELF:
        {
            int v = cx.lookup(n.resolved);
            if (v != 0) { return atom_var(v); }
            return atom_global(n.name_id, n.resolved);
        }
        case Nk.N_EXPR_PATH:
            return atom_global(n.name_id, n.resolved);
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_RESUME:
        {
            // f(args; λx. □)
            CTerm* app = cx.build_app(n, hole, 0);
            if (app == null) { return atom_unit(); }
            app.x = cx.fresh(0, null, false);
            **hole = app;
            *hole = &app.body;
            cx.after_app(app, false);
            return atom_var(app.x);
        }
        case Nk.N_EXPR_LAMBDA:
        {
            int f = cx.build_letf(n, hole, 0, null);
            return atom_var(f);
        }
        case Nk.N_EXPR_BINARY:
        {
            if (is_short_circuit(n.p.op) && n.child_count >= 2)
            {
                // join, then translate as if in tail position with j
                CTerm** rest; CTerm** body;
                int j = cx.emit_letk(*hole, n, &rest, &body, false);
                CTerm* letk = **hole;
                cx.n_joins = cx.n_joins + 1;
                cx.tail(n, j, body);
                *hole = rest;
                return atom_var(letk.x);
            }
            Atom* a = cx.atoms(2);
            Atom l = cx.val(n.child_count > 0 ? n.children[0] : null, hole);
            Atom r = cx.val(n.child_count > 1 ? n.children[1] : null, hole);
            if (a != null) { a[0] = l; a[1] = r; }
            int x = cx.emit_letv(hole, Prim.P_BINOP, n.p.op, a, 2, n, 0);
            return atom_var(x);
        }
        case Nk.N_EXPR_UNARY:
        case Nk.N_EXPR_DEREF:
        case Nk.N_EXPR_REF:
        case Nk.N_EXPR_TRY:
        case Nk.N_EXPR_CAST:
        {
            Atom* a = cx.atoms(1);
            Atom o = cx.val(n.child_count > 0 ? n.children[0] : null, hole);
            if (a != null) { a[0] = o; }
            int x = cx.emit_letv(hole, Prim.P_UNOP, n.kind == Nk.N_EXPR_UNARY ? n.p.op : 0, a, 1, n, 0);
            return atom_var(x);
        }
        case Nk.N_EXPR_FIELD:
        {
            Atom* a = cx.atoms(1);
            Atom o = cx.val(n.child_count > 0 ? n.children[0] : null, hole);
            if (a != null) { a[0] = o; }
            int x = cx.emit_letv(hole, Prim.P_FIELD, 0, a, 1, n, n.name_id);
            return atom_var(x);
        }
        case Nk.N_EXPR_INDEX:
        {
            Atom* a = cx.atoms(2);
            Atom o = cx.val(n.child_count > 0 ? n.children[0] : null, hole);
            Atom i = cx.val(n.child_count > 1 ? n.children[1] : null, hole);
            if (a != null) { a[0] = o; a[1] = i; }
            int x = cx.emit_letv(hole, Prim.P_INDEX, 0, a, 2, n, 0);
            return atom_var(x);
        }
        case Nk.N_EXPR_TUPLE:
        case Nk.N_EXPR_ARRAY:
        case Nk.N_EXPR_STRUCT_LIT:
        {
            usz cnt = n.child_count;
            Atom* a = cx.atoms(cnt);
            for (usz i = 0; i < cnt; i++)
            {
                Node* c = n.children[i];
                Atom v = (c != null && c.kind == Nk.N_EXPR_FIELD_INIT) ? cx.val(last_child(c), hole) : cx.val(c, hole);
                if (a != null) { a[i] = v; }
            }
            int x = cx.emit_letv(hole, Prim.P_TUPLE, 0, a, cnt, n, 0);
            return atom_var(x);
        }
        case Nk.N_EXPR_ASSIGN:
        {
            cx.stmt(n, hole);
            return atom_unit();
        }
        default:
            break;
    }
    if (is_control(n.kind))
    {
        // letk j(x) = □ in [[n]] j
        CTerm** rest; CTerm** body;
        int j = cx.emit_letk(*hole, n, &rest, &body, false);
        CTerm* letk = **hole;
        if (letk == null) { return atom_unit(); }
        cx.n_joins = cx.n_joins + 1;
        cx.tail(n, j, body);
        *hole = rest;
        return atom_var(letk.x);
    }
    // opaque: translate every expression child, bind the node
    usz cnt = 0;
    for (usz i = 0; i < n.child_count; i++) { if (n.children[i] != null && pfront_core::is_expr(n.children[i].kind)) { cnt = cnt + 1; } }
    Atom* a = cx.atoms(cnt);
    usz w = 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null || !pfront_core::is_expr(c.kind)) { continue; }
        Atom v = cx.val(c, hole);
        if (a != null) { a[w] = v; }
        w = w + 1;
    }
    int x = cx.emit_letv(hole, Prim.P_OPAQUE, (int)n.kind, a, cnt, n, 0);
    return atom_var(x);
}

// Build f(args; ·) with the continuation left for the caller to fill.
fn CTerm* CpsXform.build_app(CpsXform* cx, Node* n, CTerm*** hole, int k)
{
    CTerm* app = cx.mk(Ck.CK_APP, n);
    if (app == null) { return null; }
    usz first = 0;
    if (n.kind == Nk.N_EXPR_CALL)
    {
        Node* callee = n.child_count > 0 ? n.children[0] : null;
        app.f = cx.val(callee, hole);
        first = 1;
    }
    else if (n.kind == Nk.N_EXPR_METHOD)
    {
        app.f = atom_global(n.name_id, null);
        first = 0;   // receiver is the first argument
    }
    else if (n.kind == Nk.N_EXPR_PERFORM)
    {
        app.f = atom_global(n.name_id, null); app.f.kind = Ak.A_EFFECT; app.effect = true;
    }
    else
    {
        app.f = atom_global(n.name_id, null); app.f.kind = Ak.A_RESUME; app.effect = true;
    }
    usz cnt = 0;
    for (usz i = first; i < n.child_count; i++) { if (n.children[i] != null) { cnt = cnt + 1; } }
    app.args = cx.atoms(cnt);
    usz w = 0;
    for (usz i = first; i < n.child_count; i++)
    {
        if (n.children[i] == null) { continue; }
        Atom v = cx.val(n.children[i], hole);
        if (app.args != null) { app.args[w] = v; }
        w = w + 1;
    }
    app.n_args = cnt;
    app.kid = k;
    app.under_prompt = cx.prompt_depth > 0;
    return app;
}

// Verdicts once the continuation of an application is known.
fn void CpsXform.after_app(CpsXform* cx, CTerm* app, bool tail_k_is_ret)
{
    cx.n_apps = cx.n_apps + 1;
    if (app.effect) { cx.n_effect_pts = cx.n_effect_pts + 1; }
    bool self_call = app.f.kind == Ak.A_GLOBAL && app.f.decl != null && app.f.decl == cx.cur_fn;
    if (!self_call && app.f.kind == Ak.A_VAR && app.f.vid == cx.cur_fvar && cx.cur_fvar != 0) { self_call = true; }
    app.is_tail = tail_k_is_ret && !app.under_prompt && !app.effect;
    if (app.is_tail)
    {
        cx.n_tail = cx.n_tail + 1;
        if (self_call) { app.self_tail = true; cx.n_self_tail = cx.n_self_tail + 1; }
        Node* src = app.src;
        if (src != null && src.kind == Nk.N_EXPR_CALL)
        {
            if ((src.flags & pfront_core::NF_TAIL) == 0)
            {
                src.flags = src.flags | pfront_core::NF_TAIL;
                cx.n_marked_tail = cx.n_marked_tail + 1;
                if (self_call && cx.diags != null && cx.diags.advisories)
                {
                    char* m = cx.msgbuf();
                    if (m != null)
                    {
                        snprintf(m, 512, "this self-call to `%s` is in tail position and already runs as a loop; `tail` would document that", cx.name(src.children[0] != null ? src.children[0].name_id : 0));
                        cx.diags.note(pfront_core::Phase.PH_RESOLVE, 4201, src.line, src.col, m, cx.file);
                        cx.n_n4201 = cx.n_n4201 + 1;
                    }
                }
            }
        }
    }
    else
    {
        cx.n_nontail = cx.n_nontail + 1;
        if (self_call) { cx.n_self_nontail = cx.n_self_nontail + 1; }
        Node* src = app.src;
        if (src != null && src.kind == Nk.N_EXPR_CALL && (src.flags & pfront_core::NF_TAIL) != 0 && cx.diags != null)
        {
            char* m = cx.msgbuf();
            if (m != null)
            {
                char* why = app.under_prompt ? "it runs inside a `handle` body, whose prompt must stay on the stack"
                                             : "its result flows into the enclosing expression, so the frame cannot be released";
                snprintf(m, 512, "`tail` here is not a tail call: %s", why);
                cx.diags.warn(pfront_core::Phase.PH_RESOLVE, 4200, src.line, src.col, m, cx.file);
                cx.n_w4200 = cx.n_w4200 + 1;
            }
            // do not lie to the backend
            src.flags = src.flags & ~pfront_core::NF_TAIL;
        }
    }
}

// letf f(params; k') = [[body]] k' in □ — returns f's variable.
// `bound_to` is the `let f = fn …` binder (so recursive uses resolve), else null.
fn int CpsXform.build_letf(CpsXform* cx, Node* lam, CTerm*** hole, int unused, Node* bound_to)
{
    (void)unused;
    CTerm* t = cx.mk(Ck.CK_LETF, lam);
    if (t == null) { return 0; }
    t.fvar = bound_to != null ? cx.bind(bound_to, bound_to.name_id) : cx.fresh(0, null, false);
    t.ret_k = cx.fresh(0, null, true);
    // parameters
    usz np = 0;
    for (usz i = 0; i < lam.child_count; i++) { if (lam.children[i] != null && lam.children[i].kind == Nk.N_DECL_PARAM) { np = np + 1; } }
    Node* clause = null;
    for (usz i = 0; i < lam.child_count; i++) { if (lam.children[i] != null && lam.children[i].kind == Nk.N_CLAUSE) { clause = lam.children[i]; break; } }
    CTerm** bh = &t.rhs;
    if (np > 0)
    {
        t.params = (int*)cx.zalloc(int::size * np);
        t.n_params = np;
        usz w = 0;
        for (usz i = 0; i < lam.child_count; i++)
        {
            Node* p = lam.children[i];
            if (p == null || p.kind != Nk.N_DECL_PARAM) { continue; }
            int v = cx.bind_param(p);
            if (t.params != null) { t.params[w] = v; }
            w = w + 1;
        }
    }
    else if (clause != null)
    {
        // clause-style lambda: one parameter per pattern component
        Node* pat = null;
        for (usz i = 0; i < clause.child_count; i++) { if (clause.children[i] != null && pfront_core::is_pattern(clause.children[i].kind)) { pat = clause.children[i]; break; } }
        usz pc = (pat != null && pat.kind == Nk.N_PAT_TUPLE) ? pat.child_count : (pat != null ? 1 : 0);
        t.params = (int*)cx.zalloc(int::size * (pc == 0 ? 1 : pc));
        t.n_params = pc;
        for (usz i = 0; i < pc; i++)
        {
            int v = cx.fresh(0, null, false);
            if (t.params != null) { t.params[i] = v; }
            Node* sub = (pat.kind == Nk.N_PAT_TUPLE) ? pat.children[i] : pat;
            cx.bind_pattern(&bh, sub, atom_var(v), 0);
        }
    }
    // body: last child of the lambda (or of the clause)
    Node* body = clause != null ? last_child(clause) : last_child(lam);
    int saved_ret = cx.cur_ret_k; int saved_fvar = cx.cur_fvar; Node* saved_fn = cx.cur_fn;
    usz saved_loops = cx.n_loops; int saved_prompt = cx.prompt_depth;
    cx.cur_ret_k = t.ret_k; cx.cur_fvar = t.fvar; cx.cur_fn = null; cx.n_loops = 0; cx.prompt_depth = 0;
    cx.tail(body, t.ret_k, bh);
    cx.cur_ret_k = saved_ret; cx.cur_fvar = saved_fvar; cx.cur_fn = saved_fn; cx.n_loops = saved_loops; cx.prompt_depth = saved_prompt;
    cx.n_letf = cx.n_letf + 1;
    **hole = t;
    *hole = &t.body;
    return t.fvar;
}

// ── Statements inside blocks ────────────────────────────────────────────
// Returns true if the statement transfers control (the rest is unreachable).
fn bool CpsXform.stmt(CpsXform* cx, Node* n, CTerm*** hole)
{
    if (n == null) { return false; }
    switch (n.kind)
    {
        case Nk.N_DECL_LET:
        {
            Node* pat = null; Node* init = null;
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; }
                else if (pfront_core::is_expr(c.kind)) { init = c; }
            }
            if (init != null && init.kind == Nk.N_EXPR_LAMBDA && pat != null && pat.kind == Nk.N_PAT_IDENT)
            {
                cx.build_letf(init, hole, 0, pat);
                return false;
            }
            Atom v = cx.val(init, hole);
            if (pat != null && pat.kind == Nk.N_PAT_IDENT)
            {
                Atom* a = cx.atoms(1);
                if (a != null) { a[0] = v; }
                CTerm* t = cx.mk(Ck.CK_LETV, n);
                if (t == null) { return false; }
                t.prim = Prim.P_COPY; t.args = a; t.n_args = 1;
                t.x = cx.bind(pat, pat.name_id);
                **hole = t;
                *hole = &t.body;
            }
            else if (pat != null)
            {
                cx.bind_pattern(hole, pat, v, 0);
            }
            return false;
        }
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        case Nk.N_EXPR_ASSIGN:
        {
            Atom* a = cx.atoms(2);
            Atom rhs = cx.val(n.child_count > 1 ? n.children[1] : null, hole);
            Node* lhs = n.child_count > 0 ? n.children[0] : null;
            Atom l = atom_unit();
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT)
            {
                int v = cx.lookup(lhs.resolved);
                l = v != 0 ? atom_var(v) : atom_global(lhs.name_id, lhs.resolved);
            }
            else { l = cx.val(lhs, hole); }
            if (a != null) { a[0] = l; a[1] = rhs; }
            cx.emit_letv(hole, Prim.P_ASSIGN, n.kind == Nk.N_STMT_COMPOUND_ASSIGN ? n.p.op : 0, a, 2, n, 0);
            return false;
        }
        case Nk.N_STMT_RETURN:
        {
            Node* e = n.child_count > 0 ? n.children[0] : null;
            if (e != null) { cx.tail(e, cx.cur_ret_k, *hole); }
            else { cx.emit_jump(*hole, cx.cur_ret_k, atom_unit(), n); }
            return true;
        }
        case Nk.N_STMT_BREAK:
        {
            int k = cx.n_loops > 0 ? cx.loops[cx.n_loops - 1].exit_k : cx.cur_ret_k;
            Node* e = n.child_count > 0 ? n.children[0] : null;
            if (e != null && pfront_core::is_expr(e.kind)) { cx.tail(e, k, *hole); }
            else { cx.emit_jump(*hole, k, atom_unit(), n); }
            return true;
        }
        case Nk.N_STMT_CONTINUE:
        {
            int k = cx.n_loops > 0 ? cx.loops[cx.n_loops - 1].loop_k : cx.cur_ret_k;
            cx.emit_jump(*hole, k, atom_unit(), n);
            return true;
        }
        case Nk.N_STMT_EXPR:
        {
            Node* e = n.child_count > 0 ? n.children[0] : null;
            if (e == null) { return false; }
            return cx.stmt(e, hole);
        }
        case Nk.N_STMT_DEFER:
            return false;
        default:
            break;
    }
    if (pfront_core::is_expr(n.kind)) { cx.val(n, hole); }
    return false;
}

// ── Tail-position translation: [[e]] k ──────────────────────────────────
fn void CpsXform.tail(CpsXform* cx, Node* n, int k, CTerm** hole)
{
    if (hole == null) { return; }
    if (n == null) { cx.emit_jump(hole, k, atom_unit(), null); return; }
    cx.depth = cx.depth + 1;
    if (cx.depth > CPS_MAX_DEPTH) { cx.depth = cx.depth - 1; cx.emit_jump(hole, k, atom_unit(), n); return; }
    cx.tail_inner(n, k, hole);
    cx.depth = cx.depth - 1;
}

fn void CpsXform.tail_inner(CpsXform* cx, Node* n, int k, CTerm** hole)
{
    switch (n.kind)
    {
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_RESUME:
        {
            CTerm** h = hole;
            CTerm* app = cx.build_app(n, &h, k);
            if (app == null) { return; }
            *h = app;
            cx.after_app(app, k == cx.cur_ret_k);
            if (k != cx.cur_ret_k) { cx.n_joins_avoided = cx.n_joins_avoided + 1; }
            return;
        }
        case Nk.N_EXPR_IF:
        {
            CTerm** h = hole;
            Atom c = cx.val(n.child_count > 0 ? n.children[0] : null, &h);
            CTerm* t = cx.mk(Ck.CK_IF, n);
            if (t == null) { return; }
            t.args = cx.atoms(1); if (t.args != null) { t.args[0] = c; } t.n_args = 1;
            *h = t;
            cx.n_joins_avoided = cx.n_joins_avoided + 1;
            cx.tail(n.child_count > 1 ? n.children[1] : null, k, &t.body);
            cx.tail(n.child_count > 2 ? n.children[2] : null, k, &t.alt);
            return;
        }
        case Nk.N_EXPR_BINARY:
        {
            if (is_short_circuit(n.p.op) && n.child_count >= 2)
            {
                // a and b ≡ if a then b else false ; a or b ≡ if a then true else b
                CTerm** h = hole;
                Atom c = cx.val(n.children[0], &h);
                CTerm* t = cx.mk(Ck.CK_IF, n);
                if (t == null) { return; }
                t.args = cx.atoms(1); if (t.args != null) { t.args[0] = c; } t.n_args = 1;
                *h = t;
                if (is_and_op(n.p.op))
                {
                    cx.tail(n.children[1], k, &t.body);
                    cx.emit_jump(&t.alt, k, atom_lit(0), n);
                }
                else
                {
                    cx.emit_jump(&t.body, k, atom_lit(1), n);
                    cx.tail(n.children[1], k, &t.alt);
                }
                return;
            }
            break;
        }
        case Nk.N_EXPR_MATCH:
        {
            CTerm** h = hole;
            Atom s = cx.val(n.child_count > 0 ? n.children[0] : null, &h);
            usz na = 0;
            for (usz i = 1; i < n.child_count; i++) { if (n.children[i] != null && n.children[i].kind == Nk.N_MATCH_ARM) { na = na + 1; } }
            CTerm* t = cx.mk(Ck.CK_CASE, n);
            if (t == null) { return; }
            t.args = cx.atoms(1); if (t.args != null) { t.args[0] = s; } t.n_args = 1;
            t.arms = (CTerm**)cx.zalloc(usz::size * (na == 0 ? 1 : na));
            t.n_arms = na;
            *h = t;
            cx.n_joins_avoided = cx.n_joins_avoided + 1;
            usz w = 0;
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* arm = n.children[i];
                if (arm == null || arm.kind != Nk.N_MATCH_ARM) { continue; }
                if (t.arms == null) { break; }
                cx.arm(arm, s, k, &t.arms[w]);
                w = w + 1;
            }
            if (na == 0) { cx.emit_jump(&t.body, k, atom_unit(), n); }
            return;
        }
        case Nk.N_BLOCK:
        {
            CTerm** h = hole;
            usz cnt = n.child_count;
            for (usz i = 0; i < cnt; i++)
            {
                Node* s = n.children[i];
                if (s == null) { continue; }
                bool is_last = (i + 1 == cnt);
                if (is_last)
                {
                    Node* e = s;
                    if (e.kind == Nk.N_STMT_EXPR && e.child_count > 0) { e = e.children[0]; }
                    if (pfront_core::is_expr(e.kind) && e.kind != Nk.N_EXPR_ASSIGN) { cx.tail(e, k, h); return; }
                    if (cx.stmt(s, &h)) { return; }
                    cx.emit_jump(h, k, atom_unit(), n);
                    return;
                }
                if (cx.stmt(s, &h)) { return; }   // return/break/continue: rest unreachable
            }
            cx.emit_jump(h, k, atom_unit(), n);
            return;
        }
        case Nk.N_EXPR_WHILE:
        case Nk.N_EXPR_LOOP:
        case Nk.N_EXPR_FOR:
        {
            cx.loop(n, k, hole);
            return;
        }
        case Nk.N_EXPR_HANDLE:
        {
            // handler arms become local functions; the body runs under a prompt
            CTerm** h = hole;
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* arm = n.children[i];
                if (arm == null) { continue; }
                if (arm.kind == Nk.N_MATCH_ARM || arm.kind == Nk.N_CLAUSE || arm.kind == Nk.N_EXPR_LAMBDA)
                {
                    cx.build_letf(arm, &h, 0, null);
                }
            }
            cx.prompt_depth = cx.prompt_depth + 1;
            cx.tail(n.child_count > 0 ? n.children[0] : null, k, h);
            cx.prompt_depth = cx.prompt_depth - 1;
            return;
        }
        case Nk.N_EXPR_UNSAFE:
        case Nk.N_EXPR_UNCHECKED:
        {
            cx.tail(last_child(n), k, hole);
            return;
        }
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_DECL_LET:
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        case Nk.N_STMT_EXPR:
        {
            CTerm** h = hole;
            if (!cx.stmt(n, &h)) { cx.emit_jump(h, k, atom_unit(), n); }
            return;
        }
        default:
            break;
    }
    // value, then jump
    CTerm** h = hole;
    Atom v = cx.val(n, &h);
    cx.emit_jump(h, k, v, n);
}

// one match arm: bind pattern, guard, body — all with continuation k
fn void CpsXform.arm(CpsXform* cx, Node* arm, Atom scrut, int k, CTerm** hole)
{
    CTerm** h = hole;
    Node* body = last_child(arm);
    Node* guard = null;
    for (usz i = 0; i + 1 < arm.child_count; i++)
    {
        Node* c = arm.children[i];
        if (c == null) { continue; }
        if (pfront_core::is_pattern(c.kind)) { cx.bind_pattern(&h, c, scrut, 0); }
        else if (pfront_core::is_expr(c.kind)) { guard = c; }
    }
    if (guard != null)
    {
        Atom g = cx.val(guard, &h);
        CTerm* t = cx.mk(Ck.CK_IF, guard);
        if (t == null) { return; }
        t.args = cx.atoms(1); if (t.args != null) { t.args[0] = g; } t.n_args = 1;
        *h = t;
        cx.tail(body, k, &t.body);
        // guard failed: fall through to the next arm (modelled as an opaque step)
        CTerm** fh = &t.alt;
        Atom* a = cx.atoms(1); if (a != null) { a[0] = scrut; }
        int x = cx.emit_letv(&fh, Prim.P_OPAQUE, (int)Nk.N_MATCH_ARM, a, 1, arm, 0);
        cx.emit_jump(fh, k, atom_var(x), arm);
        return;
    }
    cx.tail(body, k, h);
}

// loops as continuations
fn void CpsXform.loop(CpsXform* cx, Node* n, int k, CTerm** hole)
{
    CTerm** rest; CTerm** body;
    int loop_k = cx.emit_letk(hole, n, &rest, &body, true);
    CTerm* letk = *hole;
    if (letk == null) { return; }
    cx.n_loops_total = cx.n_loops_total + 1;
    // body of the letk: the loop iteration
    if (cx.n_loops < CPS_LOOP_STACK) { cx.loops[cx.n_loops].loop_k = loop_k; cx.loops[cx.n_loops].exit_k = k; cx.n_loops = cx.n_loops + 1; }
    CTerm** h = rest;
    Node* lbody = last_child(n);
    if (n.kind == Nk.N_EXPR_LOOP)
    {
        // loop { body } : body then jump loop; only break leaves
        CTerm** bh = h;
        cx.stmt_seq_then_jump(lbody, loop_k, bh);
    }
    else if (n.kind == Nk.N_EXPR_WHILE && (n.flags & pfront_core::NF_POSTTEST) != 0)
    {
        // do body while cond: body; if cond then loop() else k()
        Node* cond = n.child_count > 0 ? n.children[0] : null;
        CTerm** bh = h;
        cx.discard(lbody, &bh);
        Atom c = cx.val(cond, &bh);
        CTerm* t = cx.mk(Ck.CK_IF, n);
        if (t != null)
        {
            t.args = cx.atoms(1); if (t.args != null) { t.args[0] = c; } t.n_args = 1;
            *bh = t;
            cx.emit_jump(&t.body, loop_k, atom_unit(), n);
            cx.emit_jump(&t.alt, k, atom_unit(), n);
        }
    }
    else
    {
        // while cond do body / for pat in it do body
        Atom c = atom_unit();
        CTerm** bh = h;
        if (n.kind == Nk.N_EXPR_WHILE)
        {
            c = cx.val(n.child_count > 0 ? n.children[0] : null, &bh);
        }
        else
        {
            // for: iterate; the iterator expression is the last non-body expr child
            Node* it = null; Node* pat = null;
            for (usz i = 0; i + 1 < n.child_count; i++)
            {
                Node* ch = n.children[i];
                if (ch == null) { continue; }
                if (pfront_core::is_pattern(ch.kind)) { pat = ch; }
                else if (pfront_core::is_expr(ch.kind)) { it = ch; }
            }
            Atom iv = cx.val(it, &bh);
            Atom* a = cx.atoms(1); if (a != null) { a[0] = iv; }
            int nx = cx.emit_letv(&bh, Prim.P_ITER_NEXT, 0, a, 1, n, 0);
            c = atom_var(nx);
            if (pat != null) { cx.bind_pattern(&bh, pat, c, 0); }
        }
        CTerm* t = cx.mk(Ck.CK_IF, n);
        if (t != null)
        {
            t.args = cx.atoms(1); if (t.args != null) { t.args[0] = c; } t.n_args = 1;
            *bh = t;
            cx.stmt_seq_then_jump(lbody, loop_k, &t.body);
            cx.emit_jump(&t.alt, k, atom_unit(), n);
        }
    }
    if (cx.n_loops > 0) { cx.n_loops = cx.n_loops - 1; }
    // enter the loop
    cx.emit_jump(body, loop_k, atom_unit(), n);
}

// run a loop body for effect, then jump to `k`
fn void CpsXform.stmt_seq_then_jump(CpsXform* cx, Node* body, int k, CTerm** hole)
{
    CTerm** h = hole;
    if (body != null && body.kind == Nk.N_BLOCK)
    {
        for (usz i = 0; i < body.child_count; i++)
        {
            if (cx.stmt(body.children[i], &h)) { return; }
        }
    }
    else if (body != null)
    {
        if (cx.stmt(body, &h)) { return; }
    }
    cx.emit_jump(h, k, atom_unit(), body);
}

fn void CpsXform.discard(CpsXform* cx, Node* body, CTerm*** hole)
{
    if (body == null) { return; }
    if (body.kind == Nk.N_BLOCK)
    {
        for (usz i = 0; i < body.child_count; i++) { if (cx.stmt(body.children[i], hole)) { return; } }
        return;
    }
    cx.stmt(body, hole);
}

// ── Per-function translation ────────────────────────────────────────────
fn void CpsXform.translate_fn(CpsXform* cx, Node* fndecl)
{
    if (cx.n_fns >= CPS_MAX_FNS) { return; }
    FnFacts* ff = &cx.fns[cx.n_fns];
    cx.n_fns = cx.n_fns + 1;
    memset((void*)ff, 0, FnFacts::size);
    ff.decl = fndecl; ff.name = fndecl.name_id;
    ff.ret_k = cx.fresh(0, null, true);

    cx.cur_fn = fndecl; cx.cur_ret_k = ff.ret_k; cx.cur_fvar = 0; cx.n_loops = 0; cx.prompt_depth = 0; cx.depth = 0;

    usz before_apps = cx.n_apps; usz before_tail = cx.n_tail; usz before_nontail = cx.n_nontail;
    usz before_st = cx.n_self_tail; usz before_snt = cx.n_self_nontail; usz before_joins = cx.n_joins;
    usz before_loops = cx.n_loops_total; usz before_letf = cx.n_letf; usz before_eff = cx.n_effect_pts;

    // parameters: N_DECL_PARAM children, else the arity of the first clause pattern
    usz np = 0;
    Node* first_clause = null;
    for (usz i = 0; i < fndecl.child_count; i++)
    {
        Node* c = fndecl.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM) { np = np + 1; }
        if (c.kind == Nk.N_CLAUSE && first_clause == null) { first_clause = c; }
    }
    CTerm* root = null;
    CTerm** h = &root;
    if (np > 0)
    {
        ff.params = (int*)cx.zalloc(int::size * np); ff.n_params = np;
        usz w = 0;
        for (usz i = 0; i < fndecl.child_count; i++)
        {
            Node* p = fndecl.children[i];
            if (p == null || p.kind != Nk.N_DECL_PARAM) { continue; }
            int v = cx.bind_param(p);
            if (ff.params != null) { ff.params[w] = v; }
            w = w + 1;
        }
    }
    if (first_clause != null)
    {
        // arity from the first clause's pattern
        Node* pat = null;
        for (usz i = 0; i < first_clause.child_count; i++) { if (first_clause.children[i] != null && pfront_core::is_pattern(first_clause.children[i].kind)) { pat = first_clause.children[i]; break; } }
        usz pc = (pat != null && pat.kind == Nk.N_PAT_TUPLE) ? pat.child_count : (pat != null ? 1 : 0);
        usz nc = 0;
        for (usz i = 0; i < fndecl.child_count; i++) { if (fndecl.children[i] != null && fndecl.children[i].kind == Nk.N_CLAUSE) { nc = nc + 1; } }
        if (np == 0)
        {
            ff.params = (int*)cx.zalloc(int::size * (pc == 0 ? 1 : pc)); ff.n_params = pc;
            for (usz i = 0; i < pc; i++) { int v = cx.fresh(0, null, false); if (ff.params != null) { ff.params[i] = v; } }
        }
        // one clause: bind and go; several: case on the parameter tuple
        Atom scrut = atom_unit();
        if (ff.n_params == 1 && ff.params != null) { scrut = atom_var(ff.params[0]); }
        else if (ff.n_params > 1 && ff.params != null && nc > 1)
        {
            Atom* a = cx.atoms(ff.n_params);
            for (usz i = 0; i < ff.n_params; i++) { if (a != null) { a[i] = atom_var(ff.params[i]); } }
            int tv = cx.emit_letv(&h, Prim.P_TUPLE, 0, a, ff.n_params, fndecl, 0);
            scrut = atom_var(tv);
        }
        if (nc == 1)
        {
            cx.clause(first_clause, scrut, ff.params, ff.n_params, ff.ret_k, h);
        }
        else
        {
            CTerm* t = cx.mk(Ck.CK_CASE, fndecl);
            if (t != null)
            {
                t.args = cx.atoms(1); if (t.args != null) { t.args[0] = scrut; } t.n_args = 1;
                t.arms = (CTerm**)cx.zalloc(usz::size * nc); t.n_arms = nc;
                *h = t;
                usz w = 0;
                for (usz i = 0; i < fndecl.child_count; i++)
                {
                    Node* c = fndecl.children[i];
                    if (c == null || c.kind != Nk.N_CLAUSE || t.arms == null) { continue; }
                    cx.clause(c, scrut, ff.params, ff.n_params, ff.ret_k, &t.arms[w]);
                    w = w + 1;
                }
            }
        }
    }
    else
    {
        Node* body = last_child(fndecl);
        if (body != null && (pfront_core::is_expr(body.kind) || body.kind == Nk.N_BLOCK)) { cx.tail(body, ff.ret_k, h); }
        else { cx.emit_jump(h, ff.ret_k, atom_unit(), fndecl); }
    }
    ff.term = root;

    // contraction + contification on the built term
    cx.contract(ff);
    cx.contify(ff);

    ff.n_apps = cx.n_apps - before_apps;
    ff.n_tail = cx.n_tail - before_tail;
    ff.n_nontail = cx.n_nontail - before_nontail;
    ff.n_self_tail = cx.n_self_tail - before_st;
    ff.n_self_nontail = cx.n_self_nontail - before_snt;
    ff.n_joins = cx.n_joins - before_joins;
    ff.n_loops = cx.n_loops_total - before_loops;
    ff.n_letf = cx.n_letf - before_letf;
    ff.n_effect_pts = cx.n_effect_pts - before_eff;
    ff.max_frames = cx.frames(root, 0, 0);
    if (ff.max_frames > cx.max_frames_all) { cx.max_frames_all = ff.max_frames; cx.max_frames_fn = ff.name; }
    ff.loop_only = ff.n_self_tail > 0 && ff.n_self_nontail == 0;
    if (ff.loop_only) { cx.n_loop_fns = cx.n_loop_fns + 1; }
    if (ff.n_self_nontail > 0) { cx.n_rec_fns = cx.n_rec_fns + 1; }

    if (cx.emit) { cx.print_fn(ff); }
    cx.cur_fn = null;
}

// one fn clause: bind the pattern against the parameters, guard, body
fn void CpsXform.clause(CpsXform* cx, Node* c, Atom scrut, int* params, usz np, int k, CTerm** hole)
{
    CTerm** h = hole;
    Node* body = last_child(c);
    Node* guard = null;
    for (usz i = 0; i + 1 < c.child_count; i++)
    {
        Node* ch = c.children[i];
        if (ch == null) { continue; }
        if (pfront_core::is_pattern(ch.kind))
        {
            if (ch.kind == Nk.N_PAT_TUPLE && np > 1 && params != null)
            {
                // component i of the tuple pattern binds against parameter i
                for (usz j = 0; j < ch.child_count && j < np; j++) { cx.bind_pattern(&h, ch.children[j], atom_var(params[j]), 0); }
            }
            else { cx.bind_pattern(&h, ch, scrut, 0); }
        }
        else if (pfront_core::is_expr(ch.kind)) { guard = ch; }
    }
    if (guard != null)
    {
        Atom g = cx.val(guard, &h);
        CTerm* t = cx.mk(Ck.CK_IF, guard);
        if (t == null) { return; }
        t.args = cx.atoms(1); if (t.args != null) { t.args[0] = g; } t.n_args = 1;
        *h = t;
        cx.tail(body, k, &t.body);
        CTerm** fh = &t.alt;
        Atom* a = cx.atoms(1); if (a != null) { a[0] = scrut; }
        int x = cx.emit_letv(&fh, Prim.P_OPAQUE, (int)Nk.N_CLAUSE, a, 1, c, 0);
        cx.emit_jump(fh, k, atom_var(x), c);
        return;
    }
    cx.tail(body, k, h);
}

// ── Census: variable use counts ─────────────────────────────────────────
fn void CpsXform.use_atom(CpsXform* cx, Atom a)
{
    if (a.kind == Ak.A_VAR && a.vid > 0 && a.vid < cx.n_vars) { cx.vars[a.vid].uses = cx.vars[a.vid].uses + 1; }
}

fn void CpsXform.use_k(CpsXform* cx, int k)
{
    if (k > 0 && k < cx.n_vars) { cx.vars[k].uses = cx.vars[k].uses + 1; }
}

fn void CpsXform.census(CpsXform* cx, CTerm* t, int depth)
{
    while (t != null && depth < 4096)
    {
        for (usz i = 0; i < t.n_args; i++) { cx.use_atom(t.args[i]); }
        switch (t.kind)
        {
            case Ck.CK_APP:
                cx.use_atom(t.f);
                if (t.kid != 0) { cx.use_k(t.kid); }
                t = t.body; break;
            case Ck.CK_JUMP:
                cx.use_k(t.kid); return;
            case Ck.CK_LETV:
                t = t.body; break;
            case Ck.CK_LETK:
                cx.census(t.rhs, depth + 1);
                t = t.body; break;
            case Ck.CK_LETF:
                cx.census(t.rhs, depth + 1);
                t = t.body; break;
            case Ck.CK_IF:
                cx.census(t.body, depth + 1);
                cx.census(t.alt, depth + 1);
                return;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { cx.census(t.arms[i], depth + 1); }
                t = t.body; break;
            default:
                return;
        }
    }
}

fn void CpsXform.reset_uses(CpsXform* cx, CTerm* t)
{
    // cheap: clear all counters (vids are per-run, so this is fine per function)
    for (int i = 0; i < cx.n_vars; i++) { cx.vars[i].uses = 0; }
    cx.census(t, 0);
}

// ── Substitution ────────────────────────────────────────────────────────
// replace continuation variable `from` by `to` everywhere in t
fn void subst_k(CTerm* t, int from, int to, int depth)
{
    while (t != null && depth < 4096)
    {
        switch (t.kind)
        {
            case Ck.CK_APP:
                if (t.kid == from) { t.kid = to; }
                t = t.body; break;
            case Ck.CK_JUMP:
                if (t.kid == from) { t.kid = to; }
                return;
            case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_LETK: subst_k(t.rhs, from, to, depth + 1); t = t.body; break;
            case Ck.CK_LETF: subst_k(t.rhs, from, to, depth + 1); t = t.body; break;
            case Ck.CK_IF: subst_k(t.body, from, to, depth + 1); subst_k(t.alt, from, to, depth + 1); return;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { subst_k(t.arms[i], from, to, depth + 1); }
                t = t.body; break;
            default: return;
        }
    }
}

// replace value variable `from` by atom `to`
fn void subst_v(CTerm* t, int from, Atom to, int depth)
{
    while (t != null && depth < 4096)
    {
        for (usz i = 0; i < t.n_args; i++) { if (t.args[i].kind == Ak.A_VAR && t.args[i].vid == from) { t.args[i] = to; } }
        switch (t.kind)
        {
            case Ck.CK_APP:
                if (t.f.kind == Ak.A_VAR && t.f.vid == from) { t.f = to; }
                t = t.body; break;
            case Ck.CK_JUMP: return;
            case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_LETK: subst_v(t.rhs, from, to, depth + 1); t = t.body; break;
            case Ck.CK_LETF: subst_v(t.rhs, from, to, depth + 1); t = t.body; break;
            case Ck.CK_IF: subst_v(t.body, from, to, depth + 1); subst_v(t.alt, from, to, depth + 1); return;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { subst_v(t.arms[i], from, to, depth + 1); }
                t = t.body; break;
            default: return;
        }
    }
}

// find the single jump to k (and its parent slot) — used for β-inlining
fn CTerm** find_jump(CTerm** slot, int k, int depth)
{
    CTerm* t = *slot;
    if (t == null || depth > 4096) { return null; }
    switch (t.kind)
    {
        case Ck.CK_JUMP:
            return t.kid == k ? slot : null;
        case Ck.CK_APP:
            return find_jump(&t.body, k, depth + 1);
        case Ck.CK_LETV:
            return find_jump(&t.body, k, depth + 1);
        case Ck.CK_LETK:
        case Ck.CK_LETF:
        {
            CTerm** r = find_jump(&t.rhs, k, depth + 1);
            if (r != null) { return r; }
            return find_jump(&t.body, k, depth + 1);
        }
        case Ck.CK_IF:
        {
            CTerm** r = find_jump(&t.body, k, depth + 1);
            if (r != null) { return r; }
            return find_jump(&t.alt, k, depth + 1);
        }
        case Ck.CK_CASE:
        {
            for (usz i = 0; i < t.n_arms; i++)
            {
                CTerm** r = find_jump(&t.arms[i], k, depth + 1);
                if (r != null) { return r; }
            }
            return find_jump(&t.body, k, depth + 1);
        }
        default:
            return null;
    }
}

// ── Contraction: η / β / dead continuations ─────────────────────────────
fn void CpsXform.contract(CpsXform* cx, FnFacts* ff)
{
    if (ff.term == null) { return; }
    // fixpoint, bounded
    for (int round = 0; round < 8; round++)
    {
        cx.reset_uses(ff.term);
        usz changed = cx.contract_walk(&ff.term, ff, 0);
        if (changed == 0) { break; }
    }
}

fn usz CpsXform.contract_walk(CpsXform* cx, CTerm** slot, FnFacts* ff, int depth)
{
    usz changed = 0;
    while (*slot != null && depth < 4096)
    {
        CTerm* t = *slot;
        switch (t.kind)
        {
            case Ck.CK_LETK:
            {
                if (t.is_loop) { changed = changed + cx.contract_walk(&t.rhs, ff, depth + 1); slot = &t.body; break; }
                usz uses = (t.kid > 0 && t.kid < cx.n_vars) ? cx.vars[t.kid].uses : 0;
                // η: letk j(x) = k'(x) in body  ⇒  body[j := k']
                if (t.rhs != null && t.rhs.kind == Ck.CK_JUMP && t.rhs.n_args == 1
                    && t.rhs.args[0].kind == Ak.A_VAR && t.rhs.args[0].vid == t.x && t.rhs.kid != t.kid)
                {
                    subst_k(t.body, t.kid, t.rhs.kid, 0);
                    *slot = t.body;
                    cx.n_eta = cx.n_eta + 1; ff.n_eta = ff.n_eta + 1;
                    changed = changed + 1;
                    continue;
                }
                if (uses == 0)
                {
                    // dead join point (e.g. every branch returned)
                    *slot = t.body;
                    cx.n_dead_k = cx.n_dead_k + 1; ff.n_dead_k = ff.n_dead_k + 1;
                    changed = changed + 1;
                    continue;
                }
                if (uses == 1)
                {
                    // β: the single jump j(a) becomes rhs[x := a]
                    CTerm** js = find_jump(&t.body, t.kid, 0);
                    if (js != null && *js != null && (*js).n_args == 1)
                    {
                        Atom a = (*js).args[0];
                        subst_v(t.rhs, t.x, a, 0);
                        *js = t.rhs;
                        *slot = t.body;
                        cx.n_beta = cx.n_beta + 1; ff.n_beta = ff.n_beta + 1;
                        changed = changed + 1;
                        continue;
                    }
                }
                changed = changed + cx.contract_walk(&t.rhs, ff, depth + 1);
                slot = &t.body;
                break;
            }
            case Ck.CK_LETF:
                changed = changed + cx.contract_walk(&t.rhs, ff, depth + 1);
                slot = &t.body; break;
            case Ck.CK_APP:
            case Ck.CK_LETV:
                slot = &t.body; break;
            case Ck.CK_IF:
                changed = changed + cx.contract_walk(&t.body, ff, depth + 1);
                slot = &t.alt; break;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { changed = changed + cx.contract_walk(&t.arms[i], ff, depth + 1); }
                slot = &t.body; break;
            default:
                return changed;
        }
    }
    return changed;
}

// ── Contification ───────────────────────────────────────────────────────
// For letf f: collect the continuation of every call of f; if f is never a
// value and all calls share one continuation VARIABLE, f is a join point.
struct ContifyScan
{
    int  fvar;
    int  common_k;     // 0 = none yet; -1 = conflict
    usz  n_calls;
    usz  n_value_uses;
}

fn void contify_scan(CTerm* t, ContifyScan* s, int depth)
{
    while (t != null && depth < 4096)
    {
        for (usz i = 0; i < t.n_args; i++) { if (t.args[i].kind == Ak.A_VAR && t.args[i].vid == s.fvar) { s.n_value_uses = s.n_value_uses + 1; } }
        switch (t.kind)
        {
            case Ck.CK_APP:
                if (t.f.kind == Ak.A_VAR && t.f.vid == s.fvar)
                {
                    s.n_calls = s.n_calls + 1;
                    if (t.kid == 0) { s.common_k = -1; }
                    else if (s.common_k == 0) { s.common_k = t.kid; }
                    else if (s.common_k != t.kid) { s.common_k = -1; }
                }
                t = t.body; break;
            case Ck.CK_JUMP: return;
            case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_LETK: contify_scan(t.rhs, s, depth + 1); t = t.body; break;
            case Ck.CK_LETF: contify_scan(t.rhs, s, depth + 1); t = t.body; break;
            case Ck.CK_IF: contify_scan(t.body, s, depth + 1); contify_scan(t.alt, s, depth + 1); return;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { contify_scan(t.arms[i], s, depth + 1); }
                t = t.body; break;
            default: return;
        }
    }
}

fn void CpsXform.contify(CpsXform* cx, FnFacts* ff)
{
    cx.contify_walk(ff.term, ff, 0);
}

fn void CpsXform.contify_walk(CpsXform* cx, CTerm* t, FnFacts* ff, int depth)
{
    while (t != null && depth < 4096)
    {
        switch (t.kind)
        {
            case Ck.CK_LETF:
            {
                cx.contify_walk(t.rhs, ff, depth + 1);
                ContifyScan s; s.fvar = t.fvar; s.common_k = 0; s.n_calls = 0; s.n_value_uses = 0;
                contify_scan(t.body, &s, 0);
                // recursive self-calls inside f with f's own return continuation are fine
                if (s.n_calls > 0 && s.n_value_uses == 0 && s.common_k > 0 && !t.contified)
                {
                    subst_k(t.rhs, t.ret_k, s.common_k, 0);
                    t.contified = true;
                    cx.n_contified = cx.n_contified + 1; ff.n_contified = ff.n_contified + 1;
                    if (cx.diags != null && cx.diags.advisories && t.src != null && t.fvar > 0 && cx.vars[t.fvar].name != 0)
                    {
                        char* m = cx.msgbuf();
                        if (m != null)
                        {
                            snprintf(m, 512, "`%s` is called %d time%s, always with the same continuation: it is a join point, not a closure (no allocation, no call — a jump)",
                                     cx.name(cx.vars[t.fvar].name), (int)s.n_calls, s.n_calls == 1 ? "" : "s");
                            cx.diags.note(pfront_core::Phase.PH_RESOLVE, 4203, t.src.line, t.src.col, m, cx.file);
                            cx.n_n4203 = cx.n_n4203 + 1;
                        }
                    }
                }
                t = t.body; break;
            }
            case Ck.CK_LETK: cx.contify_walk(t.rhs, ff, depth + 1); t = t.body; break;
            case Ck.CK_APP: case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_IF: cx.contify_walk(t.body, ff, depth + 1); t = t.alt; break;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { cx.contify_walk(t.arms[i], ff, depth + 1); }
                t = t.body; break;
            default: return;
        }
    }
}

// ── Continuation size: values live across a call ────────────────────────
// f(a…; λx. body) — the continuation closes over every variable that body
// uses and that was bound before the call. That set is exactly what a
// direct-style backend must spill around the call (callee-saved or stack),
// so the largest such set in a function is its frame pressure. Continuation
// variables of enclosing joins do not count: a jump is a branch.
fn usz CpsXform.live_in(CpsXform* cx, CTerm* t, int before, char* seen, int depth)
{
    usz n = 0;
    while (t != null && depth < 4096)
    {
        for (usz i = 0; i < t.n_args; i++)
        {
            Atom a = t.args[i];
            if (a.kind == Ak.A_VAR && a.vid > 0 && a.vid < before && a.vid < cx.n_vars && seen[a.vid] == 0) { seen[a.vid] = 1; n = n + 1; }
        }
        switch (t.kind)
        {
            case Ck.CK_APP:
                if (t.f.kind == Ak.A_VAR && t.f.vid > 0 && t.f.vid < before && t.f.vid < cx.n_vars && seen[t.f.vid] == 0) { seen[t.f.vid] = 1; n = n + 1; }
                t = t.body; break;
            case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_LETK: n = n + cx.live_in(t.rhs, before, seen, depth + 1); t = t.body; break;
            case Ck.CK_LETF: n = n + cx.live_in(t.rhs, before, seen, depth + 1); t = t.body; break;
            case Ck.CK_IF: n = n + cx.live_in(t.body, before, seen, depth + 1); t = t.alt; break;
            case Ck.CK_CASE:
                for (usz i = 0; i < t.n_arms; i++) { n = n + cx.live_in(t.arms[i], before, seen, depth + 1); }
                t = t.body; break;
            default: return n;
        }
    }
    return n;
}

fn usz CpsXform.frames(CpsXform* cx, CTerm* t, usz cur, int depth)
{
    usz best = cur;
    while (t != null && depth < 4096)
    {
        switch (t.kind)
        {
            case Ck.CK_APP:
                if (t.kid == 0 && t.body != null)
                {
                    char* seen = (char*)cx.arena.alloc((usz)cx.n_vars + 1, 1);
                    if (seen != null)
                    {
                        memset((void*)seen, 0, (usz)cx.n_vars + 1);
                        usz live = cx.live_in(t.body, t.x, seen, 0);
                        if (live > best) { best = live; }
                    }
                }
                t = t.body; break;
            case Ck.CK_LETV: t = t.body; break;
            case Ck.CK_LETK:
            {
                usz r = cx.frames(t.rhs, cur, depth + 1);
                if (r > best) { best = r; }
                t = t.body; break;
            }
            case Ck.CK_LETF:
            {
                usz r = cx.frames(t.rhs, 0, depth + 1);
                if (r > best) { best = r; }
                t = t.body; break;
            }
            case Ck.CK_IF:
            {
                usz a = cx.frames(t.body, cur, depth + 1);
                usz b = cx.frames(t.alt, cur, depth + 1);
                if (a > best) { best = a; }
                if (b > best) { best = b; }
                return best;
            }
            case Ck.CK_CASE:
            {
                for (usz i = 0; i < t.n_arms; i++) { usz a = cx.frames(t.arms[i], cur, depth + 1); if (a > best) { best = a; } }
                t = t.body; break;
            }
            default: return best;
        }
    }
    return best;
}

// ── Printing (--emit-cps) ───────────────────────────────────────────────
fn void CpsXform.print_atom(CpsXform* cx, Atom a)
{
    switch (a.kind)
    {
        case Ak.A_UNIT:   printf("()"); return;
        case Ak.A_LIT:    printf("%ld", a.ival); return;
        case Ak.A_VAR:
        {
            uint nm = (a.vid > 0 && a.vid < cx.n_vars) ? cx.vars[a.vid].name : 0;
            if (nm != 0) { printf("%s_%d", cx.name(nm), a.vid); } else { printf("t%d", a.vid); }
            return;
        }
        case Ak.A_GLOBAL: printf("%s", cx.name(a.name)); return;
        case Ak.A_EFFECT: printf("perform %s", cx.name(a.name)); return;
        case Ak.A_RESUME: printf("resume"); return;
    }
}

fn void CpsXform.print_k(CpsXform* cx, int k)
{
    if (k == cx.cur_ret_k) { printf("k_ret"); return; }
    printf("k%d", k);
}

fn void indent(int n) { for (int i = 0; i < n; i++) { printf("  "); } }

fn char* prim_name(Prim p)
{
    switch (p)
    {
        case Prim.P_COPY: return "";
        case Prim.P_BINOP: return "binop";
        case Prim.P_UNOP: return "unop";
        case Prim.P_PROJ: return "proj";
        case Prim.P_ASSIGN: return "set!";
        case Prim.P_TUPLE: return "tuple";
        case Prim.P_FIELD: return "field";
        case Prim.P_INDEX: return "index";
        case Prim.P_ITER_NEXT: return "next";
        case Prim.P_OPAQUE: return "opaque";
    }
    return "?";
}

fn void CpsXform.print_term(CpsXform* cx, CTerm* t, int ind, int depth)
{
    while (t != null && depth < 4096)
    {
        indent(ind);
        switch (t.kind)
        {
            case Ck.CK_HALT: printf("halt\n"); return;
            case Ck.CK_APP:
            {
                cx.print_atom(t.f);
                printf("(");
                for (usz i = 0; i < t.n_args; i++) { if (i > 0) { printf(", "); } cx.print_atom(t.args[i]); }
                printf("; ");
                if (t.kid != 0)
                {
                    cx.print_k(t.kid);
                    printf(")");
                    if (t.self_tail) { printf("   ; self tail call → loop"); }
                    else if (t.is_tail) { printf("   ; tail call"); }
                    printf("\n");
                    return;
                }
                printf("λt%d.)\n", t.x);
                t = t.body; break;
            }
            case Ck.CK_JUMP:
                cx.print_k(t.kid); printf("("); if (t.n_args > 0) { cx.print_atom(t.args[0]); } printf(")\n");
                return;
            case Ck.CK_LETV:
            {
                Atom xv = atom_var(t.x);
                if (t.prim == Prim.P_ASSIGN) { printf("set! "); for (usz i = 0; i < t.n_args; i++) { if (i > 0) { printf(" := "); } cx.print_atom(t.args[i]); } printf("\n"); t = t.body; break; }
                else { printf("let "); cx.print_atom(xv); printf(" = "); }
                if ((t.prim == Prim.P_BINOP || t.prim == Prim.P_UNOP) && t.op != 0) { printf("%s ", pfront_lex::token_type_name((Tk)t.op)); }
                else if (t.prim == Prim.P_UNOP && t.src != null) { printf("%s ", pfront_core::kind_name(t.src.kind)); }
                else if (t.prim == Prim.P_OPAQUE) { printf("%s ", pfront_core::kind_name((Nk)t.op)); }
                else if (t.prim == Prim.P_FIELD) { printf(".%s ", cx.name(cx.vars[t.x].name)); }
                else if (t.prim != Prim.P_COPY) { printf("%s ", prim_name(t.prim)); }
                for (usz i = 0; i < t.n_args; i++) { if (i > 0) { printf(" "); } cx.print_atom(t.args[i]); }
                printf("\n");
                t = t.body; break;
            }
            case Ck.CK_LETK:
                printf("letk "); cx.print_k(t.kid); printf("(t%d) =%s\n", t.x, t.is_loop ? "   ; loop" : "   ; join");
                cx.print_term(t.rhs, ind + 2, depth + 1);
                indent(ind); printf("in\n");
                t = t.body; break;
            case Ck.CK_LETF:
            {
                printf("%s ", t.contified ? "letj" : "letf");
                cx.print_atom(atom_var(t.fvar));
                printf("(");
                for (usz i = 0; i < t.n_params; i++) { if (i > 0) { printf(", "); } cx.print_atom(atom_var(t.params[i])); }
                printf("; "); cx.print_k(t.ret_k); printf(") =%s\n", t.contified ? "   ; contified" : "");
                int saved = cx.cur_ret_k;
                cx.print_term(t.rhs, ind + 2, depth + 1);
                cx.cur_ret_k = saved;
                indent(ind); printf("in\n");
                t = t.body; break;
            }
            case Ck.CK_IF:
                printf("if "); if (t.n_args > 0) { cx.print_atom(t.args[0]); } printf(" then\n");
                cx.print_term(t.body, ind + 1, depth + 1);
                indent(ind); printf("else\n");
                cx.print_term(t.alt, ind + 1, depth + 1);
                return;
            case Ck.CK_CASE:
                printf("case "); if (t.n_args > 0) { cx.print_atom(t.args[0]); } printf(" of\n");
                for (usz i = 0; i < t.n_arms; i++) { indent(ind); printf("| arm %d:\n", (int)i); cx.print_term(t.arms[i], ind + 2, depth + 1); }
                t = t.body; break;
        }
    }
}

fn void CpsXform.print_fn(CpsXform* cx, FnFacts* ff)
{
    cx.cur_ret_k = ff.ret_k;
    printf("=== cps: fn %s(", cx.name(ff.name));
    for (usz i = 0; i < ff.n_params; i++) { if (i > 0) { printf(", "); } cx.print_atom(atom_var(ff.params[i])); }
    printf("; k_ret) ===   [%d values live across a call, %d tail / %d non-tail calls%s]\n",
           (int)ff.max_frames, (int)ff.n_tail, (int)ff.n_nontail, ff.loop_only ? ", loop" : "");
    cx.print_term(ff.term, 1, 0);
}

// ── Driver ──────────────────────────────────────────────────────────────
fn void CpsXform.walk(CpsXform* cx, Node* n, int depth)
{
    if (n == null || depth > CPS_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN)
    {
        cx.translate_fn(n);
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { cx.walk(n.children[i], depth + 1); }
}

fn void CpsXform.report(CpsXform* cx)
{
    printf("  cps              : %d fns → %d terms, %d calls (%d tail, %d non-tail), %d effect capture points\n",
           (int)cx.n_fns, (int)cx.n_terms, (int)cx.n_apps, (int)cx.n_tail, (int)cx.n_nontail, (int)cx.n_effect_pts);
    printf("  cps-control      : %d joins created, %d avoided (branch in tail position), %d loops as continuations, %d local fns\n",
           (int)cx.n_joins, (int)cx.n_joins_avoided, (int)cx.n_loops_total, (int)cx.n_letf);
    printf("  cps-contract     : %d η, %d β (join inlined), %d dead joins, %d contified\n",
           (int)cx.n_eta, (int)cx.n_beta, (int)cx.n_dead_k, (int)cx.n_contified);
    printf("  cps-frames       : largest continuation %d live values (%s), %d fns loop by self tail call, %d truly recursive, %d calls marked tail\n",
           (int)cx.max_frames_all, cx.name(cx.max_frames_fn), (int)cx.n_loop_fns, (int)cx.n_rec_fns, (int)cx.n_marked_tail);
    if (cx.n_w4200 > 0) { printf("  cps-hazards      : %d `tail` annotations on non-tail calls (W4200)\n", (int)cx.n_w4200); }
}
