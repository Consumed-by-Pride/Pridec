// ============================================================================
// theory_effcont.c3 — Algebraic effect handlers: the discipline, checked
// ----------------------------------------------------------------------------
// Plotkin & Pretnar 2009 (handlers of algebraic effects), Kammar/Lindley/
// Oury 2013 (Handlers in Action), Leijen 2017 (Koka; tail-resumptive
// handlers), Biernacki/Piróg/Polesiuk/Sieczkowski 2018 (Abstracting
// Algebraic Effects — the frame-list model of delimited continuations).
//
// theory_effects.c3 owns the row calculus and the per-handler coverage
// check (W4070–W4072). What was missing is everything that happens at the
// PERFORM and RESUME sites — the part the programmer actually gets wrong.
// This pass walks every function with a lexical model of the delimited
// continuation stack: entering the computation of a `handle` pushes a
// prompt naming the operations its arms catch; entering an ARM body pops
// it again (a deep handler re-handles only the CONTINUATION, never the
// arm's own body — performs there go to the next handler out), and a
// lambda body is a fresh frame in which `resume` no longer refers to the
// enclosing arm's continuation.
//
//   perform E.op(..)   caught by the nearest enclosing prompt with an arm
//                      for `op`; otherwise it escapes to the caller and must
//                      be in the function's row  `! [E, ..]`
//   f(..) with a row   every effect in f's row is performed by the call
//   handler arm        `resume(v)` is the delimited continuation. Count it
//                      along every path: 0 on all paths = ABORT arm; exactly
//                      1 on every path in TAIL position = TAIL-RESUMPTIVE
//                      (Leijen: no continuation capture is needed — the arm
//                      is an ordinary function; NF_TAIL is set on the arm so
//                      the backend can lower it that way); ≥ 2 on some path
//                      or inside a loop = MULTI-SHOT (the continuation is
//                      copied — legal, but it is what it is)
//
// Diagnostics:
//   W4180  `Ask.ask` is performed here but no enclosing `handle` has an arm
//          for it and the row of `f` (`! [IO]`) does not list `Ask`
//   W4181  calling `asks` performs `Ask`: handle it or add it to the row of `f`
//   N4182  the continuation is resumed more than once in this arm (multi-shot)
//   W4183  `resume` outside a handler arm has no continuation to resume
//   W4184  `resume` inside a closure: the continuation escapes the arm
//   N4185  the handled computation can never perform `Tell.tell`; this arm
//          is dead
//   W4186  arm binds N values but `tell` carries M
//   N4187  (--lint) arm is tail-resumptive / abort; NF_TAIL set
//
// Functions without a written row are UNANNOTATED: their performs escape
// silently (rows are inferred elsewhere, theory_rowinfer). Only a written
// row is a promise, and only a broken promise is reported.
// ============================================================================

module theory_effcont;

import pfront_lex;
import pfront_core;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz EC_MAX_EFFECTS = 128;
const usz EC_MAX_OPS     = 16;      // per effect
const usz EC_MAX_PROMPTS = 64;      // lexical handler depth
const usz EC_MAX_ROW     = 32;      // effects in one row
const usz EC_MAX_FNS     = 1024;
const int EC_MAX_DEPTH   = 200;

// ── Effect declarations ─────────────────────────────────────────────────────
struct OpInfo
{
    uint  name;
    Node* decl;
    int   arity;        // number of values the op carries (-1 unknown)
}

struct EffectInfo
{
    uint   name;
    Node*  decl;
    OpInfo[EC_MAX_OPS] ops;
    usz    n_ops;
}

// A function's written effect row.
struct Row
{
    uint[EC_MAX_ROW] effects;
    usz  n;
    bool open;          // `..r` tail, or no row written at all
    bool written;
}

struct FnRow
{
    Node* decl;
    Row   row;
}

// A prompt on the lexical continuation stack: the `handle` whose
// computation we are inside, and the operations its arms catch.
struct Prompt
{
    Node* handle;
    uint[EC_MAX_OPS * 4] ops;
    usz   n_ops;
    bool  catch_all;    // a `_` / unknown arm: assume it catches anything
}

// Resume census for one arm body, path-sensitive.
struct ResumeCount
{
    int  min;           // fewest resumes on any path
    int  max;           // most resumes on any path (capped)
    bool in_loop;       // a resume sits inside a loop
    bool all_tail;      // every resume is in tail position
    bool seen;          // at least one resume somewhere
    bool escaped;       // a resume sits inside a closure
    int  seen_count;    // resumes seen so far in walk order
    Node* first;
    Node* second;       // the second resume on the path that has ≥ 2
}

struct EffCont
{
    Arena*    arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;

    EffectInfo* effects;
    usz         n_effects;
    FnRow*      fn_rows;
    usz         n_fn_rows;

    // walk state
    Prompt*   prompts;
    usz       n_prompts;
    Node*     cur_fn;
    Row       cur_row;
    Node*     cur_arm;         // handler arm whose body we are in (resume target)
    Node*     cur_k;           // explicit continuation binder of the arm (`| E.op x k -> k v`), if any
    int       lambda_depth;    // > 0: inside a closure relative to cur_arm
    int       loop_depth;

    // resume census for the arm being analysed
    ResumeCount rc;

    // counts
    usz n_fns;
    usz n_annotated;
    usz n_handlers;
    usz n_op_arms;
    usz n_value_arms;
    usz n_performs;
    usz n_caught;
    usz n_escaping_declared;
    usz n_escaping_unannotated;
    usz n_undeclared;
    usz n_call_leaks;
    usz n_resumes;
    usz n_tail_arms;
    usz n_abort_arms;
    usz n_multishot_arms;
    usz n_stray_resume;
    usz n_escaping_resume;
    usz n_dead_arms;
    usz n_arity;
}

fn void EffCont.attach(EffCont* ec, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    ec.diags = d; ec.interner = it; ec.file = file;
}

fn char* EffCont.name(EffCont* ec, uint id)
{
    if (ec.interner == null || id == 0) { return "_"; }
    return ec.interner.text(id);
}

fn char* EffCont.msgbuf(EffCont* ec)
{
    char* m = (char*)ec.arena.alloc(384, 1);
    if (m != null) { m[0] = 0; }
    return m;
}

fn void EffCont.warn(EffCont* ec, int code, Node* at, char* msg)
{
    if (ec.diags == null || at == null || msg == null) { return; }
    ec.diags.warn(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, ec.file);
}
fn void EffCont.note(EffCont* ec, int code, Node* at, char* msg)
{
    if (ec.diags == null || at == null || msg == null) { return; }
    ec.diags.note(pfront_core::Phase.PH_RESOLVE, code, at.line, at.col, msg, ec.file);
}

// ── Declarations ────────────────────────────────────────────────────────────
fn int type_arity(Node* t)
{
    if (t == null) { return -1; }
    if (t.kind == Nk.N_TY_UNIT) { return 0; }
    if (t.kind == Nk.N_TY_TUPLE) { return (int)t.child_count; }
    return 1;
}

fn void EffCont.collect(EffCont* ec, Node* n, int depth)
{
    if (n == null || depth > EC_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_EFFECT && ec.n_effects < EC_MAX_EFFECTS)
    {
        EffectInfo* e = &ec.effects[ec.n_effects];
        e.name = n.name_id; e.decl = n; e.n_ops = 0;
        for (usz i = 0; i < n.child_count && e.n_ops < EC_MAX_OPS; i++)
        {
            Node* op = n.children[i];
            if (op == null || op.kind != Nk.N_DECL_EFFECT_OP) { continue; }
            e.ops[e.n_ops].name = op.name_id;
            e.ops[e.n_ops].decl = op;
            // children: [param type, ty-constraint(return)]
            e.ops[e.n_ops].arity = op.child_count >= 1 ? type_arity(op.children[0]) : -1;
            e.n_ops = e.n_ops + 1;
        }
        ec.n_effects = ec.n_effects + 1;
    }
    if (n.kind == Nk.N_DECL_FN && ec.n_fn_rows < EC_MAX_FNS)
    {
        FnRow* fr = &ec.fn_rows[ec.n_fn_rows];
        fr.decl = n;
        ec.row_of_fn(n, &fr.row);
        ec.n_fn_rows = ec.n_fn_rows + 1;
    }
    for (usz i = 0; i < n.child_count; i++) { ec.collect(n.children[i], depth + 1); }
}

fn EffectInfo* EffCont.effect_by_name(EffCont* ec, uint name)
{
    for (usz i = 0; i < ec.n_effects; i++) { if (ec.effects[i].name == name) { return &ec.effects[i]; } }
    return null;
}

fn EffectInfo* EffCont.effect_of_op(EffCont* ec, uint op, OpInfo** out_op)
{
    for (usz i = 0; i < ec.n_effects; i++)
    {
        for (usz j = 0; j < ec.effects[i].n_ops; j++)
        {
            if (ec.effects[i].ops[j].name == op)
            {
                if (out_op != null) { *out_op = &ec.effects[i].ops[j]; }
                return &ec.effects[i];
            }
        }
    }
    return null;
}

fn Node* find_row_node(Node* n, int depth)
{
    if (n == null || depth > 6) { return null; }
    if (n.kind == Nk.N_TY_EFFECT_ROW) { return n; }
    // the row hangs off the fn's type annotation (ty-fn) — do not descend
    // into bodies
    if (n.kind == Nk.N_BLOCK || n.kind == Nk.N_CLAUSE) { return null; }
    if (n.type_ann != null)
    {
        Node* r = find_row_node(n.type_ann, depth + 1);
        if (r != null) { return r; }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_TY_FN || c.kind == Nk.N_TY_EFFECT_ROW || c.kind == Nk.N_TY_CONSTRAINT)
        {
            Node* r = find_row_node(c, depth + 1);
            if (r != null) { return r; }
        }
    }
    return null;
}

fn void EffCont.row_of_fn(EffCont* ec, Node* f, Row* out)
{
    out.n = 0; out.open = true; out.written = false;
    Node* row = find_row_node(f, 0);
    if (row == null) { return; }
    out.written = true;
    out.open = (row.flags & pfront_core::NF_OPEN_ROW) != 0;
    for (usz i = 0; i < row.child_count && out.n < EC_MAX_ROW; i++)
    {
        Node* e = row.children[i];
        if (e == null) { continue; }
        if (e.kind == Nk.N_TY_EFFECT_ELEM || e.kind == Nk.N_TY_NAME)
        {
            if (e.name_id == 0) { out.open = true; continue; }
            out.effects[out.n] = e.name_id; out.n = out.n + 1;
        }
        else { out.open = true; }
    }
}

fn bool row_has(Row* r, uint eff)
{
    if (r.open) { return true; }
    for (usz i = 0; i < r.n; i++) { if (r.effects[i] == eff) { return true; } }
    return false;
}

fn Row* EffCont.row_of_decl(EffCont* ec, Node* decl)
{
    for (usz i = 0; i < ec.n_fn_rows; i++) { if (ec.fn_rows[i].decl == decl) { return &ec.fn_rows[i].row; } }
    return null;
}

fn void EffCont.render_row(EffCont* ec, Row* r, char* buf, usz cap)
{
    usz pos = 0;
    pos = pos + (usz)snprintf(buf + pos, cap - pos, "! [");
    for (usz i = 0; i < r.n && pos + 2 < cap; i++)
    {
        pos = pos + (usz)snprintf(buf + pos, cap - pos, "%s%s", i > 0 ? ", " : "", ec.name(r.effects[i]));
    }
    if (pos + 2 < cap) { snprintf(buf + pos, cap - pos, "]"); }
}

// ── Prompts ─────────────────────────────────────────────────────────────────
fn Node* arm_op_path(Node* arm)
{
    if (arm == null) { return null; }
    for (usz i = 0; i < arm.child_count; i++)
    {
        Node* c = arm.children[i];
        if (c != null && c.kind == Nk.N_MODULE_PATH) { return c; }
    }
    return null;
}

fn bool arm_is_return(Node* arm)
{
    if (arm == null || arm.name_id != 0) { return false; }
    return arm_op_path(arm) == null;
}

fn void EffCont.push_prompt(EffCont* ec, Node* handle)
{
    if (ec.n_prompts >= EC_MAX_PROMPTS) { return; }
    Prompt* p = &ec.prompts[ec.n_prompts];
    p.handle = handle; p.n_ops = 0; p.catch_all = false;
    for (usz i = 1; i < handle.child_count; i++)
    {
        Node* arm = handle.children[i];
        if (arm == null || arm.kind != Nk.N_HANDLER_ARM) { continue; }
        if (arm_is_return(arm)) { continue; }
        if (arm.name_id == 0) { p.catch_all = true; continue; }
        if (p.n_ops < EC_MAX_OPS * 4) { p.ops[p.n_ops] = arm.name_id; p.n_ops = p.n_ops + 1; }
    }
    ec.n_prompts = ec.n_prompts + 1;
}

fn Prompt* EffCont.find_prompt(EffCont* ec, uint op)
{
    for (usz i = ec.n_prompts; i > 0; i--)
    {
        Prompt* p = &ec.prompts[i - 1];
        if (p.catch_all) { return p; }
        for (usz j = 0; j < p.n_ops; j++) { if (p.ops[j] == op) { return p; } }
    }
    return null;
}

// Is any effect in `row` caught by an enclosing prompt? (For calls: a
// callee's whole effect is handled if some enclosing handler has an arm for
// EVERY op of that effect — approximated by: at least one arm for it, which
// is what theory_effects' W4072 completes.)
fn bool EffCont.effect_caught(EffCont* ec, uint eff)
{
    EffectInfo* e = ec.effect_by_name(eff);
    if (e == null) { return false; }
    for (usz i = ec.n_prompts; i > 0; i--)
    {
        Prompt* p = &ec.prompts[i - 1];
        if (p.catch_all) { return true; }
        for (usz j = 0; j < p.n_ops; j++)
        {
            for (usz k = 0; k < e.n_ops; k++) { if (p.ops[j] == e.ops[k].name) { return true; } }
        }
    }
    return false;
}

// ── Perform / call sites ────────────────────────────────────────────────────
fn void EffCont.check_perform(EffCont* ec, Node* pf)
{
    ec.n_performs = ec.n_performs + 1;
    uint op = pf.name_id;
    if (op == 0) { return; }
    if (ec.find_prompt(op) != null) { ec.n_caught = ec.n_caught + 1; return; }
    OpInfo* oi = null;
    EffectInfo* e = ec.effect_of_op(op, &oi);
    if (e == null) { return; }           // unknown op: theory_effects reports it
    if (!ec.cur_row.written) { ec.n_escaping_unannotated = ec.n_escaping_unannotated + 1; return; }
    if (row_has(&ec.cur_row, e.name)) { ec.n_escaping_declared = ec.n_escaping_declared + 1; return; }
    ec.n_undeclared = ec.n_undeclared + 1;
    char* m = ec.msgbuf(); if (m == null) { return; }
    char[128] rowtxt;
    ec.render_row(&ec.cur_row, &rowtxt[0], 128);
    snprintf(m, 384, "`%s.%s` is performed here but no enclosing `handle` has an arm for it and the row of `%s` (`%s`) does not list `%s`",
             ec.name(e.name), ec.name(op), ec.cur_fn != null ? ec.name(ec.cur_fn.name_id) : "?", &rowtxt[0], ec.name(e.name));
    ec.warn(4180, pf, m);
}

fn void EffCont.check_call(EffCont* ec, Node* call)
{
    Node* callee = call.child_count >= 1 ? call.children[0] : null;
    if (callee == null || callee.kind != Nk.N_EXPR_IDENT || callee.resolved == null) { return; }
    if (callee.resolved.kind != Nk.N_DECL_FN) { return; }
    if (callee.resolved == ec.cur_fn) { return; }
    Row* r = ec.row_of_decl(callee.resolved);
    if (r == null || !r.written || r.open) { return; }
    if (!ec.cur_row.written) { return; }
    char[160] missing; usz mpos = 0; missing[0] = 0; usz nmiss = 0;
    for (usz i = 0; i < r.n; i++)
    {
        uint eff = r.effects[i];
        if (row_has(&ec.cur_row, eff)) { continue; }
        if (ec.effect_caught(eff)) { continue; }
        if (ec.effect_by_name(eff) == null) { continue; }     // builtin like IO: rowinfer's job
        mpos = mpos + (usz)snprintf(&missing[0] + mpos, 160 - mpos, "%s`%s`", nmiss > 0 ? ", " : "", ec.name(eff));
        nmiss = nmiss + 1;
        if (mpos > 120) { break; }
    }
    if (nmiss == 0) { return; }
    ec.n_call_leaks = ec.n_call_leaks + 1;
    char* m = ec.msgbuf(); if (m == null) { return; }
    char[128] rowtxt;
    ec.render_row(&ec.cur_row, &rowtxt[0], 128);
    snprintf(m, 384, "calling `%s` performs %s: handle %s here or add %s to the row of `%s` (`%s`)",
             ec.name(callee.name_id), &missing[0], nmiss > 1 ? "them" : "it", nmiss > 1 ? "them" : "it",
             ec.cur_fn != null ? ec.name(ec.cur_fn.name_id) : "?", &rowtxt[0]);
    ec.warn(4181, call, m);
}

// ── Resume census ───────────────────────────────────────────────────────────
fn void rc_init(ResumeCount* rc)
{
    rc.min = 0; rc.max = 0; rc.in_loop = false; rc.all_tail = true; rc.seen = false;
    rc.first = null; rc.second = null; rc.escaped = false; rc.seen_count = 0;
}

fn bool EffCont.is_resume(EffCont* ec, Node* n)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_EXPR_RESUME) { return true; }
    if (n.kind == Nk.N_EXPR_CALL && ec.cur_k != null && n.child_count >= 1 && n.children[0] != null
        && n.children[0].kind == Nk.N_EXPR_IDENT && n.children[0].resolved == ec.cur_k) { return true; }
    return false;
}

// The last pattern of an arm is the continuation when the arm binds one
// more value than the operation carries.
fn Node* arm_k_binder(Node* arm, int arity)
{
    if (arm == null || arity < 0) { return null; }
    // `| E.op x k -> …` binds the payload patterns and the continuation as
    // SEPARATE children; `| E.op(a, b) -> …` is one tuple pattern (payload only)
    Node* last = null; usz n = 0;
    for (usz i = 0; i < arm.child_count; i++)
    {
        Node* c = arm.children[i];
        if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
        n = n + 1; last = c;
    }
    if (n < 2) { return null; }
    usz payload = 0;
    for (usz i = 0; i < arm.child_count; i++)
    {
        Node* c = arm.children[i];
        if (c == null || !pfront_core::is_pattern(c.kind) || c == last) { continue; }
        if (c.kind == Nk.N_PAT_TUPLE)
        {
            for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_pattern(c.children[j].kind)) { payload = payload + 1; } }
        }
        else { payload = payload + 1; }
    }
    n = payload + 1;
    if ((int)n == arity + 1 && last != null && last.kind == Nk.N_PAT_IDENT) { return last; }
    return null;
}

// Count resumes in `n`, returning (min, max) over paths through it.
// `tail` says whether n is in tail position of the arm.
fn void EffCont.count_resumes(EffCont* ec, Node* n, bool tail, int* mn, int* mx, int depth)
{
    *mn = 0; *mx = 0;
    if (n == null || depth > EC_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_CALL && ec.is_resume(n))
    {
        ec.rc.seen = true;
        ec.rc.seen_count = ec.rc.seen_count + 1;
        if (ec.rc.first == null) { ec.rc.first = n; }
        else if (ec.rc.second == null) { ec.rc.second = n; }
        if (!tail) { ec.rc.all_tail = false; }
        if (ec.loop_depth > 0) { ec.rc.in_loop = true; }
        int amin = 0; int amax = 0;
        for (usz i = 1; i < n.child_count; i++)
        {
            int a; int b;
            ec.count_resumes(n.children[i], false, &a, &b, depth + 1);
            amin = amin + a; amax = amax + b;
        }
        *mn = 1 + amin; *mx = 1 + amax;
        return;
    }
    if (n.kind == Nk.N_EXPR_IDENT && ec.cur_k != null && n.resolved == ec.cur_k
        && !(n.parent != null && n.parent.kind == Nk.N_EXPR_CALL && n.parent.child_count >= 1 && n.parent.children[0] == n))
    {
        // the continuation used as a value: it escapes
        ec.rc.escaped = true;
        ec.n_escaping_resume = ec.n_escaping_resume + 1;
        char* m = ec.msgbuf();
        if (m != null)
        {
            snprintf(m, 384, "the continuation `%s` is used as a value here: it escapes its handler arm and may be resumed after the handler has returned", ec.name(n.name_id));
            ec.warn(4184, n, m);
        }
        return;
    }
    switch (n.kind)
    {
        case N_EXPR_RESUME:
        {
            ec.rc.seen = true;
            ec.rc.seen_count = ec.rc.seen_count + 1;
            if (ec.rc.first == null) { ec.rc.first = n; }
            else if (ec.rc.second == null) { ec.rc.second = n; }
            if (!tail) { ec.rc.all_tail = false; }
            if (ec.loop_depth > 0) { ec.rc.in_loop = true; }
            // the argument may itself resume (resume(resume(x)))
            int a; int b;
            int amin = 0; int amax = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                ec.count_resumes(n.children[i], false, &a, &b, depth + 1);
                amin = amin + a; amax = amax + b;
            }
            *mn = 1 + amin; *mx = 1 + amax;
            return;
        }
        case N_EXPR_LAMBDA:
        {
            // a resume in a closure escapes; counted separately
            ec.scan_lambda_resume(n, depth + 1);
            return;
        }
        case N_EXPR_HANDLE:
        {
            // a nested handler: its arms have their own continuation; only
            // the computation is on our path
            if (n.child_count >= 1) { ec.count_resumes(n.children[0], false, mn, mx, depth + 1); }
            return;
        }
        case N_EXPR_IF:
        {
            int cmn; int cmx; int tmn; int tmx; int emn = 0; int emx = 0;
            ec.count_resumes(n.child_count >= 1 ? n.children[0] : null, false, &cmn, &cmx, depth + 1);
            ec.count_resumes(n.child_count >= 2 ? n.children[1] : null, tail, &tmn, &tmx, depth + 1);
            if (n.child_count >= 3) { ec.count_resumes(n.children[2], tail, &emn, &emx, depth + 1); }
            *mn = cmn + (tmn < emn ? tmn : emn);
            *mx = cmx + (tmx > emx ? tmx : emx);
            return;
        }
        case N_EXPR_MATCH:
        {
            int smn; int smx;
            ec.count_resumes(n.child_count >= 1 ? n.children[0] : null, false, &smn, &smx, depth + 1);
            int bmin = 1000000; int bmax = 0; bool any_arm = false;
            for (usz i = 1; i < n.child_count; i++)
            {
                Node* arm = n.children[i];
                if (arm == null) { continue; }
                any_arm = true;
                int amn = 0; int amx = 0;
                for (usz j = 0; j < arm.child_count; j++)
                {
                    Node* c = arm.children[j];
                    if (c == null || pfront_core::is_pattern(c.kind)) { continue; }
                    int x; int y;
                    ec.count_resumes(c, tail && j + 1 == arm.child_count, &x, &y, depth + 1);
                    amn = amn + x; amx = amx + y;
                }
                if (amn < bmin) { bmin = amn; }
                if (amx > bmax) { bmax = amx; }
            }
            if (!any_arm) { bmin = 0; }
            *mn = smn + bmin; *mx = smx + bmax;
            return;
        }
        case N_EXPR_WHILE:
        case N_EXPR_LOOP:
        case N_EXPR_FOR:
        {
            ec.loop_depth = ec.loop_depth + 1;
            int bmn = 0; int bmx = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                int x; int y;
                ec.count_resumes(n.children[i], false, &x, &y, depth + 1);
                bmn = bmn + x; bmx = bmx + y;
            }
            ec.loop_depth = ec.loop_depth - 1;
            // zero iterations possible; many iterations possible
            *mn = 0; *mx = bmx > 0 ? 1000 : 0;
            return;
        }
        case N_BLOCK:
        {
            int smn = 0; int smx = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                int x; int y;
                bool last = i + 1 == n.child_count;
                ec.count_resumes(n.children[i], tail && last, &x, &y, depth + 1);
                smn = smn + x; smx = smx + y;
                Node* st = n.children[i];
                if (st != null && (st.kind == Nk.N_STMT_RETURN || st.kind == Nk.N_STMT_BREAK)) { break; }
            }
            *mn = smn; *mx = smx;
            return;
        }
        case N_STMT_RETURN:
        {
            // `return resume(x)` is a tail resume
            int smn = 0; int smx = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                int x; int y;
                ec.count_resumes(n.children[i], true, &x, &y, depth + 1);
                smn = smn + x; smx = smx + y;
            }
            *mn = smn; *mx = smx;
            return;
        }
        case N_DECL_LET:
        case N_STMT_ASSIGN:
        case N_EXPR_ASSIGN:
        case N_STMT_COMPOUND_ASSIGN:
        case N_EXPR_CALL:
        case N_EXPR_METHOD:
        case N_EXPR_BINARY:
        case N_EXPR_UNARY:
        case N_EXPR_CAST:
        case N_EXPR_INDEX:
        case N_EXPR_FIELD:
        case N_EXPR_TUPLE:
        case N_EXPR_ARRAY:
        case N_EXPR_STRUCT_LIT:
        case N_EXPR_PERFORM:
        {
            // the value is consumed: not tail
            int smn = 0; int smx = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                int x; int y;
                ec.count_resumes(n.children[i], false, &x, &y, depth + 1);
                smn = smn + x; smx = smx + y;
            }
            *mn = smn; *mx = smx;
            return;
        }
        default:
        {
            int smn = 0; int smx = 0;
            for (usz i = 0; i < n.child_count; i++)
            {
                int x; int y;
                bool last = i + 1 == n.child_count;
                ec.count_resumes(n.children[i], tail && last, &x, &y, depth + 1);
                smn = smn + x; smx = smx + y;
            }
            *mn = smn; *mx = smx;
            return;
        }
    }
}

fn void EffCont.scan_lambda_resume(EffCont* ec, Node* n, int depth)
{
    if (n == null || depth > EC_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_RESUME || (n.kind == Nk.N_EXPR_CALL && ec.is_resume(n))
        || (n.kind == Nk.N_EXPR_IDENT && ec.cur_k != null && n.resolved == ec.cur_k))
    {
        ec.n_escaping_resume = ec.n_escaping_resume + 1;
        ec.rc.escaped = true;
        char* m = ec.msgbuf();
        if (m != null)
        {
            snprintf(m, 384, "`resume` inside a closure: the continuation of `%s` escapes its handler arm and may be resumed after the handler has returned",
                     ec.cur_arm != null ? ec.name(ec.cur_arm.name_id) : "?");
            ec.warn(4184, n, m);
        }
        return;
    }
    if (n.kind == Nk.N_EXPR_HANDLE) { return; }   // its own arms
    for (usz i = 0; i < n.child_count; i++) { ec.scan_lambda_resume(n.children[i], depth + 1); }
}

// The set of effects a handled computation may perform: direct performs
// plus the written rows of the functions it calls. `known` is false when a
// call to an unannotated / unknown callee makes the set open.
fn void EffCont.effects_of_computation(EffCont* ec, Node* n, uint* out, usz* n_out, bool* known, int depth)
{
    if (n == null || depth > EC_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_PERFORM && n.name_id != 0)
    {
        EffectInfo* e = ec.effect_of_op(n.name_id, null);
        if (e == null) { *known = false; }
        else if (*n_out < EC_MAX_ROW) { out[*n_out] = e.name; *n_out = *n_out + 1; }
    }
    else if (n.kind == Nk.N_EXPR_CALL || n.kind == Nk.N_EXPR_METHOD)
    {
        Node* callee = n.child_count >= 1 ? n.children[0] : null;
        Row* r = null;
        if (callee != null && callee.kind == Nk.N_EXPR_IDENT && callee.resolved != null && callee.resolved.kind == Nk.N_DECL_FN)
        {
            r = ec.row_of_decl(callee.resolved);
        }
        if (r == null || !r.written || r.open) { *known = false; }
        else
        {
            for (usz i = 0; i < r.n && *n_out < EC_MAX_ROW; i++) { out[*n_out] = r.effects[i]; *n_out = *n_out + 1; }
        }
    }
    else if (n.kind == Nk.N_EXPR_LAMBDA) { *known = false; }
    else if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null && n.resolved.kind == Nk.N_DECL_FN)
    {
        // a function value passed along: it may be called inside
        Row* r = ec.row_of_decl(n.resolved);
        if (r == null || !r.written || r.open) { *known = false; }
        else { for (usz i = 0; i < r.n && *n_out < EC_MAX_ROW; i++) { out[*n_out] = r.effects[i]; *n_out = *n_out + 1; } }
    }
    for (usz i = 0; i < n.child_count; i++) { ec.effects_of_computation(n.children[i], out, n_out, known, depth + 1); }
}

fn usz pattern_arity(Node* arm)
{
    // patterns between the op path and the body
    usz n = 0;
    for (usz i = 0; i < arm.child_count; i++)
    {
        Node* c = arm.children[i];
        if (c == null || !pfront_core::is_pattern(c.kind)) { continue; }
        if (c.kind == Nk.N_PAT_TUPLE)
        {
            usz k = 0;
            for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_pattern(c.children[j].kind)) { k = k + 1; } }
            n = n + k;
        }
        else { n = n + 1; }
    }
    return n;
}

fn void EffCont.check_handle(EffCont* ec, Node* h, int depth)
{
    ec.n_handlers = ec.n_handlers + 1;
    // 1. the computation runs under this handler's prompt
    ec.push_prompt(h);
    if (h.child_count >= 1) { ec.walk(h.children[0], depth + 1); }
    if (ec.n_prompts > 0) { ec.n_prompts = ec.n_prompts - 1; }

    // what can the computation perform?
    uint[EC_MAX_ROW] can; usz n_can = 0; bool known = true;
    if (h.child_count >= 1) { ec.effects_of_computation(h.children[0], &can[0], &n_can, &known, 0); }

    // 2. each arm: its body runs OUTSIDE this prompt (deep handler semantics:
    //    only the continuation is re-handled), with `resume` bound
    for (usz i = 1; i < h.child_count; i++)
    {
        Node* arm = h.children[i];
        if (arm == null || arm.kind != Nk.N_HANDLER_ARM) { continue; }
        Node* body = arm.child_count >= 1 ? arm.children[arm.child_count - 1] : null;
        if (arm_is_return(arm))
        {
            ec.n_value_arms = ec.n_value_arms + 1;
            // no continuation in a return arm
            Node* saved = ec.cur_arm; ec.cur_arm = null;
            ec.walk(body, depth + 1);
            ec.cur_arm = saved;
            continue;
        }
        ec.n_op_arms = ec.n_op_arms + 1;
        OpInfo* oi = null;
        EffectInfo* e = arm.name_id != 0 ? ec.effect_of_op(arm.name_id, &oi) : null;

        // dead arm: the computation cannot perform this effect
        if (e != null && known)
        {
            bool possible = false;
            for (usz k = 0; k < n_can; k++) { if (can[k] == e.name) { possible = true; } }
            if (!possible)
            {
                ec.n_dead_arms = ec.n_dead_arms + 1;
                char* m = ec.msgbuf();
                if (m != null)
                {
                    snprintf(m, 384, "the handled computation can never perform `%s.%s`: this arm is dead", ec.name(e.name), ec.name(arm.name_id));
                    ec.note(4185, arm, m);
                }
            }
        }
        // arity
        if (oi != null && oi.arity >= 0)
        {
            usz bound = pattern_arity(arm);
            if ((int)bound != oi.arity && arm_k_binder(arm, oi.arity) == null)
            {
                ec.n_arity = ec.n_arity + 1;
                char* m = ec.msgbuf();
                if (m != null)
                {
                    snprintf(m, 384, "this arm binds %d value%s but `%s.%s` carries %d", (int)bound, bound == 1 ? "" : "s",
                             ec.name(e.name), ec.name(arm.name_id), oi.arity);
                    ec.warn(4186, arm, m);
                }
            }
        }
        // resume census (`resume(v)` or an explicit continuation binder `k v`)
        Node* saved_arm = ec.cur_arm; ec.cur_arm = arm;
        Node* saved_k = ec.cur_k; ec.cur_k = arm_k_binder(arm, oi != null ? oi.arity : -1);
        ResumeCount saved_rc = ec.rc;
        rc_init(&ec.rc);
        int mn; int mx;
        int saved_loop = ec.loop_depth; ec.loop_depth = 0;
        ec.count_resumes(body, true, &mn, &mx, 0);
        ec.loop_depth = saved_loop;
        ec.rc.min = mn; ec.rc.max = mx;
        ec.n_resumes = ec.n_resumes + (usz)(mx > 100 ? 1 : mx);
        if (ec.rc.escaped)
        {
            // reported by scan_lambda_resume; no verdict on the arm
        }
        else if (!ec.rc.seen)
        {
            ec.n_abort_arms = ec.n_abort_arms + 1;
            if (ec.diags != null && ec.diags.advisories)
            {
                char* m = ec.msgbuf();
                if (m != null)
                {
                    snprintf(m, 384, "arm for `%s` never resumes: it aborts the handled computation", ec.name(arm.name_id));
                    ec.note(4187, arm, m);
                }
            }
        }
        else if (ec.rc.max >= 2 || ec.rc.in_loop)
        {
            ec.n_multishot_arms = ec.n_multishot_arms + 1;
            char* m = ec.msgbuf();
            if (m != null)
            {
                if (ec.rc.in_loop)
                {
                    snprintf(m, 384, "the continuation of `%s` is resumed inside a loop: multi-shot — every iteration re-runs the rest of the handled computation from the `perform`",
                             ec.name(arm.name_id));
                }
                else
                {
                    snprintf(m, 384, "the continuation of `%s` is resumed more than once on the same path (first at %d:%d): multi-shot — the rest of the handled computation runs again from the `perform`",
                             ec.name(arm.name_id), ec.rc.first != null ? ec.rc.first.line : 0, ec.rc.first != null ? ec.rc.first.col : 0);
                }
                ec.note(4182, ec.rc.second != null ? ec.rc.second : ec.rc.first, m);
            }
        }
        else if (ec.rc.min == 1 && ec.rc.max == 1 && ec.rc.all_tail)
        {
            ec.n_tail_arms = ec.n_tail_arms + 1;
            arm.flags = arm.flags | pfront_core::NF_TAIL;
            if (ec.diags != null && ec.diags.advisories)
            {
                char* m = ec.msgbuf();
                if (m != null)
                {
                    snprintf(m, 384, "arm for `%s` is tail-resumptive: it resumes exactly once, in tail position, so no continuation needs to be captured",
                             ec.name(arm.name_id));
                    ec.note(4187, arm, m);
                }
            }
        }
        // walk the body for performs / nested handlers / calls (resume is fine here)
        ec.walk(body, depth + 1);
        ec.rc = saved_rc;
        ec.cur_arm = saved_arm; ec.cur_k = saved_k;
    }
}

fn bool fn_has_handle(Node* n, int depth)
{
    if (n == null || depth > EC_MAX_DEPTH) { return false; }
    if (n.kind == Nk.N_EXPR_HANDLE) { return true; }
    for (usz i = 0; i < n.child_count; i++) { if (fn_has_handle(n.children[i], depth + 1)) { return true; } }
    return false;
}

// ── Walk ────────────────────────────────────────────────────────────────────
fn void EffCont.walk(EffCont* ec, Node* n, int depth)
{
    if (n == null || depth > EC_MAX_DEPTH) { return; }
    switch (n.kind)
    {
        case N_DECL_FN:
        {
            Node* saved_fn = ec.cur_fn; Row saved_row = ec.cur_row;
            usz saved_prompts = ec.n_prompts; Node* saved_arm = ec.cur_arm; int saved_lambda = ec.lambda_depth;
            ec.cur_fn = n; ec.n_prompts = 0; ec.cur_arm = null; ec.lambda_depth = 0;
            ec.row_of_fn(n, &ec.cur_row);
            ec.n_fns = ec.n_fns + 1;
            if (ec.cur_row.written) { ec.n_annotated = ec.n_annotated + 1; }
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null || c.kind == Nk.N_DECL_PARAM || pfront_core::is_pattern(c.kind)) { continue; }
                if (c.kind == Nk.N_TY_FN || c.kind == Nk.N_TY_EFFECT_ROW) { continue; }
                ec.walk(c, depth + 1);
            }
            ec.cur_fn = saved_fn; ec.cur_row = saved_row; ec.n_prompts = saved_prompts;
            ec.cur_arm = saved_arm; ec.lambda_depth = saved_lambda;
            return;
        }
        case N_EXPR_HANDLE:
            ec.check_handle(n, depth);
            return;
        case N_EXPR_PERFORM:
            ec.check_perform(n);
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], depth + 1); }
            return;
        case N_EXPR_CALL:
            ec.check_call(n);
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], depth + 1); }
            return;
        case N_EXPR_RESUME:
        {
            if (ec.cur_arm == null && ec.lambda_depth == 0)
            {
                ec.n_stray_resume = ec.n_stray_resume + 1;
                char* m = ec.msgbuf();
                if (m != null)
                {
                    snprintf(m, 384, "`resume` outside a handler arm: there is no continuation to resume here");
                    // a function that contains no `handle` at all may be a
                    // runtime wrapper around the primitive: a note, not a warning
                    if (fn_has_handle(ec.cur_fn, 0)) { ec.warn(4183, n, m); } else { ec.note(4183, n, m); }
                }
            }
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], depth + 1); }
            return;
        }
        case N_EXPR_LAMBDA:
        {
            // inside a closure the arm's continuation is not ours (reported
            // by scan_lambda_resume when under an arm); prompts do not
            // cross the closure boundary either — the lambda may be called
            // anywhere
            Node* saved_arm = ec.cur_arm; usz saved_prompts = ec.n_prompts; Node* saved_k = ec.cur_k;
            ec.cur_arm = null; ec.cur_k = null; ec.lambda_depth = ec.lambda_depth + 1; ec.n_prompts = 0;
            for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], depth + 1); }
            ec.cur_arm = saved_arm; ec.cur_k = saved_k; ec.lambda_depth = ec.lambda_depth - 1; ec.n_prompts = saved_prompts;
            return;
        }
        default:
            break;
    }
    for (usz i = 0; i < n.child_count; i++) { ec.walk(n.children[i], depth + 1); }
}

// ── Lifecycle ───────────────────────────────────────────────────────────────
fn void EffCont.init(EffCont* ec, Arena* a)
{
    ec.arena = a;
    ec.diags = null; ec.interner = null; ec.file = "";
    ec.effects = (EffectInfo*)calloc(EC_MAX_EFFECTS, EffectInfo::size);
    ec.fn_rows = (FnRow*)calloc(EC_MAX_FNS, FnRow::size);
    ec.prompts = (Prompt*)calloc(EC_MAX_PROMPTS, Prompt::size);
    ec.n_effects = 0; ec.n_fn_rows = 0; ec.n_prompts = 0;
    ec.cur_fn = null; ec.cur_arm = null; ec.cur_k = null; ec.lambda_depth = 0; ec.loop_depth = 0;
    ec.cur_row.n = 0; ec.cur_row.open = true; ec.cur_row.written = false;
    rc_init(&ec.rc);
    ec.n_fns = 0; ec.n_annotated = 0; ec.n_handlers = 0; ec.n_op_arms = 0; ec.n_value_arms = 0;
    ec.n_performs = 0; ec.n_caught = 0; ec.n_escaping_declared = 0; ec.n_escaping_unannotated = 0;
    ec.n_undeclared = 0; ec.n_call_leaks = 0; ec.n_resumes = 0; ec.n_tail_arms = 0; ec.n_abort_arms = 0;
    ec.n_multishot_arms = 0; ec.n_stray_resume = 0; ec.n_escaping_resume = 0; ec.n_dead_arms = 0; ec.n_arity = 0;
}

fn void EffCont.run(EffCont* ec, Node* root)
{
    if (ec.effects == null) { return; }
    ec.n_effects = 0; ec.n_fn_rows = 0; ec.n_prompts = 0;
    ec.collect(root, 0);
    ec.walk(root, 0);
}

fn void EffCont.report(EffCont* ec)
{
    printf("  eff-cont         : %d fns (%d with a written row), %d effect decls, %d handlers (%d op arms, %d value arms)\n",
           (int)ec.n_fns, (int)ec.n_annotated, (int)ec.n_effects, (int)ec.n_handlers, (int)ec.n_op_arms, (int)ec.n_value_arms);
    printf("  eff-perform      : %d performs: %d caught by an enclosing handle, %d escape via the row, %d escape unannotated, %d undeclared, %d call leaks\n",
           (int)ec.n_performs, (int)ec.n_caught, (int)ec.n_escaping_declared, (int)ec.n_escaping_unannotated, (int)ec.n_undeclared, (int)ec.n_call_leaks);
    printf("  eff-resume       : %d resumes: %d tail-resumptive arms (NF_TAIL), %d abort arms, %d multi-shot arms, %d stray, %d escaping, %d dead arms, %d arity\n",
           (int)ec.n_resumes, (int)ec.n_tail_arms, (int)ec.n_abort_arms, (int)ec.n_multishot_arms, (int)ec.n_stray_resume,
           (int)ec.n_escaping_resume, (int)ec.n_dead_arms, (int)ec.n_arity);
}

fn void EffCont.destroy(EffCont* ec)
{
    if (ec.effects != null) { free((void*)ec.effects); ec.effects = null; }
    if (ec.fn_rows != null) { free((void*)ec.fn_rows); ec.fn_rows = null; }
    if (ec.prompts != null) { free((void*)ec.prompts); ec.prompts = null; }
}
