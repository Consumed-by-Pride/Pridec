// ============================================================================
// air_low.c3 -- typed lowering: resolved PNode AST -> AIR 3.0 low profile.
//
// This is the "everything is lowered" half of the .air contract (docs/pear2/AIR3_PLAN.md).
// It sits BESIDE air_lower.c3 (the untyped AIR-H lowering that PEAR 1 still consumes) and
// never touches it. Its output is read by air_ll.c3 (the reference consumer), airtool
// verify-low and, later, PEAR 2: every value has a concrete type, every local is either an
// SSA name or an `alloca`, every loop is a label/jump, every call names a function.
//
// What it accepts is the subset listed in docs/pear2/AIR3_PLAN.md ("lowered today"). A
// construct outside it is a DIAGNOSTIC naming the construct and the function; no .air is
// written. There is no silent approximation: that is the point of the low profile.
//
// Shape of the work:
//   * a function body becomes basic blocks (instructions + one terminator);
//   * the blocks are assembled into the nested AIR: seq { label B1. ..; seq { label B2. ..; entry } };
//   * only functions reachable from `main` are lowered.
// ============================================================================
module air_low;
import pfront_core;
import pfront_lex;
import air_ir;
import air_ll;
import air_text;
import air_lower;
import air_types;
import air_write;

alias Node = pfront_core::PNode;
alias Nk   = pfront_core::NodeKind;
alias Tk   = pfront_lex::TokenType;

extern fn void* calloc(usz count_, usz size_);
extern fn void* realloc(void* p, usz size_);
extern fn int   snprintf(char* buf, usz cap_, char* fmt, ...);
extern fn int   printf(char* fmt, ...);
extern fn int   fflush(void* f);
extern fn int   remove(char* path);
extern fn char* getenv(char* name);

const usz MAXFN  = 4096;
const usz MAXST  = 1024;
const usz MAXGL  = 1024;
const usz MAXBLK = 8192;
const usz MAXVAR = 8192;
const usz MAXNM  = 32768;
const usz NOBLK  = 0xFFFFFFFF;

enum InsK : int { I_LET, I_STORE, I_CALL, I_FIELD, I_PROJ, I_SYS }
struct Ins
{
    InsK k; char* name; AirPrd* a; AirPrd* b; AirPrd*[16] args; usz nargs; char* fld; long idx;
}
enum TermK : int { T_NONE, T_RET, T_JUMP, T_COND, T_TRAP, T_UNREACH }
struct Blk
{
    char* name; char*[8] pnames; AirTyp*[8] ptys; usz np;
    Ins* ins; usz ni; usz cap;
    TermK tk; AirPrd* tp; char*[8] jargs; usz nj; usz t1; usz t2; usz npred;
}
struct Vx { AirPrd* p; AirTyp* t; }
struct Pl { AirPrd* ptr; AirTyp* t; }
struct VarB { Node* decl; AirPrd* p; AirTyp* t; bool slot; }
struct LoopF { usz brk; usz cont; }
struct Cap { Node* decl; AirTyp* t; bool by_ref; AirPrd* sp; }
// a `defer`: function-scoped, registered by setting its flag, replayed (in reverse order) before every return
struct DeferR { Node* node; AirPrd* flag; Cap[8] snap; usz nsnap; }
struct FnInfo
{
    Node* decl; char* name; AirTyp* ret; AirTyp*[16] pty; usz np; AirTyp* fnty; bool ext; bool queued; bool seen; bool variadic;
    bool is_arm; long hnd; usz arm_j; bool is_lam; bool is_ind; bool is_adapt; FnInfo* adapt; Cap[16] caps; usz ncaps; AirTyp* envty;
    TSub[4] ts; usz nts;
}
// a function VALUE is the record { fn: ptr, env: ptr(u8) }; `fn` takes the environment as its first argument
struct CloI { AirTyp* ty; AirTyp* fnty; AirTyp*[16] ps; usz np; AirTyp* ret; }
// generics are monomorphised: an instance is keyed by its declaration and the concrete type arguments
struct TSub { Node* tp; AirTyp* t; }
struct StInfo { Node* decl; char* name; AirTyp* ty; AirTyp*[4] targs; usz nt; }
// an untagged `union` is a block of words; every field is a typed view of offset 0
struct UniI { Node* decl; AirTyp* ty; char*[8] fnames; AirTyp*[8] ft; usz nf; usz words; }
struct Fat { AirTyp* elem; AirTyp* ty; bool is_str; }
// an enum is the explicit record { tag: i64, payload: [words x i64] }; every payload field sits at its own
// 8-byte word offset and is stored/loaded through a typed pointer (the layout is decided HERE, not by the consumer)
struct VarI { char* name; Node* decl; AirTyp*[8] ft; usz nf; usz[8] off; }
struct Enm { Node* decl; char* name; AirTyp* ty; VarI[32] v; usz nv; usz words; AirTyp*[8] um; usz nm; }   // nm > 0: a set-theoretic union `A ∪ B` (variants are its members)
// effect handlers: a handler arm is a closure installed in the per-operation global `hop.E.op` for the dynamic
// extent of the `handle` body.  A `perform` calls the installed closure.  An arm that resumes in tail position
// returns the resumption value to the perform site; an arm that does not resume ABORTS: it stores its value into
// the handler's result slot and raises the unwinding flag `__unw` (= the handler id), and every call site checks
// the flag and unwinds (jump to the enclosing handler exit, or return).  Non-tail / multi-shot resumption needs
// continuations and is reported as unsupported.
struct HndI { usz id; AirTyp* frame; AirTyp* th; usz nops; char*[8] g; AirTyp*[8] hty; AirTyp*[8] cty; }
struct ArmCx { Node* kdecl; AirPrd* flag; AirPrd* rv; AirTyp* opret; AirTyp* th; bool on; }
struct GlInfo { Node* decl; char* name; AirTyp* ty; }

struct Low
{
    AirArena* a; AirModule* m; pfront_core::Interner* it;
    FnInfo* fns; usz nfn; usz done_fn;
    StInfo* sts; usz nst;
    GlInfo* gls; usz ngl;
    Blk* blks; usz nb; usz cur;
    VarB* vars; usz nvars;
    LoopF[64] loops; usz nloops;
    char** names; usz nnames; usz tmpn; usz lbln;
    AirTyp* ret_ty; char* cur_fn; Node* cur_node;
    int errors; int fn_errors; int fns_ok; int fail_fn; Node* entry_decl;
    bool uses_alloc;
    Fat[48] fats; usz nfat;
    Enm* ens; usz nen;
    CloI* clos; usz nclo; usz nlam;
    DeferR[16] defers; usz ndefer; bool in_replay;
    TSub[16] tsub; usz ntsub;
    Node** roots; usz nroots;
    UniI[32] unis; usz nuni;
    HndI[256] hnds; usz nhnd; ArmCx arm; usz[16] hx; AirTyp*[16] hxt; usz nhx; bool eff_on; bool unw_made; char*[64] hopn; AirTyp*[64] hopt; usz nhop;
    Node* ty_root;
    int unchecked; bool discard; bool if_discard; bool blk_discard;
}

// ── small utilities ────────────────────────────────────────────────────────
fn bool seq(char* a, char* b)
{
    if (a == null || b == null) { return a == b; }
    usz i = 0; while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}
fn char* Low.dup(Low* lw, char* s)
{
    if (s == null) { return null; }
    usz n = 0; while (s[n] != 0) { n++; }
    return lw.a.dup(s, n);
}
fn char* Low.text(Low* lw, Node* n) { return air_lower::node_text(n, lw.it); }

fn void Low.err(Low* lw, Node* n, char* what, char* who)
{
    lw.errors++; lw.fn_errors++;
    if (lw.fn_errors > 1) { return; }      // first error per function only: later ones are cascades
    Node* at = n != null ? n : lw.cur_node;
    printf("air-low: error: %d:%d: in `%s`: %s%s%s\n", at != null ? at.line : 0, at != null ? at.col : 0,
           lw.cur_fn != null ? lw.cur_fn : "?", what, who != null ? ": " : "", who != null ? who : "");
}
fn void Low.unsup(Low* lw, Node* n, char* what)
{
    char[128] b;
    snprintf(&b[0], 128, "not lowered yet (%s)", what);
    lw.err(n, &b[0], n != null ? pfront_core::kind_name(n.kind) : null);
}

fn char* Low.fresh(Low* lw, char* stem)
{
    char[64] b; lw.tmpn++;
    snprintf(&b[0], 64, "%s%d", stem, (int)lw.tmpn);
    char* r = lw.dup(&b[0]);
    if (lw.nnames < MAXNM) { lw.names[lw.nnames] = r; lw.nnames++; }
    return r;
}
// a user name, made unique within the function (low profile is single assignment)
fn char* Low.uname(Low* lw, char* base)
{
    if (base == null || base[0] == 0) { base = "_"; }
    bool used = false;
    for (usz i = 0; i < lw.nnames; i++) { if (seq(lw.names[i], base)) { used = true; break; } }
    if (!used) { char* r = lw.dup(base); if (lw.nnames < MAXNM) { lw.names[lw.nnames] = r; lw.nnames++; } return r; }
    char[160] b; lw.tmpn++;
    snprintf(&b[0], 160, "%s.%d", base, (int)lw.tmpn);
    char* r = lw.dup(&b[0]);
    if (lw.nnames < MAXNM) { lw.names[lw.nnames] = r; lw.nnames++; }
    return r;
}

// ── types ──────────────────────────────────────────────────────────────────
fn AirTyp* Low.nominal(Low* lw, char* nm) { AirTyp* t = air_ir::air_mk_typ(lw.a, ATYP_NOMINAL); t.name = nm; return t; }
fn AirTyp* Low.ptr(Low* lw, AirTyp* t) { return air_ir::air_mk_typ_ptr(lw.a, t); }

fn AirDecl* Low.data_of(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.m.decl_count; i++)
    {
        AirDecl* d = lw.m.decls[i];
        if (d != null && d.tag == ADECL_DATA && seq(d.name, t.name)) { return d; }
    }
    return null;
}

fn usz Low.typarams(Low* lw, Node* d, Node** out)
{
    usz n = 0;
    for (usz i = 0; i < d.child_count && n < 4; i++) { Node* c = d.children[i]; if (c != null && c.kind == Nk.N_DECL_TYPEPARAM) { out[n] = c; n++; } }
    return n;
}
fn AirTyp* Low.tsub_get(Low* lw, Node* tp)
{
    for (usz i = lw.ntsub; i > 0; i--) { if (lw.tsub[i - 1].tp == tp) { return lw.tsub[i - 1].t; } }
    return null;
}
fn void Low.tsub_push(Low* lw, Node* tp, AirTyp* t)
{
    if (lw.ntsub < 16) { lw.tsub[lw.ntsub].tp = tp; lw.tsub[lw.ntsub].t = t; lw.ntsub++; }
}
fn StInfo* Low.st_of(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.nst; i++) { if (lw.sts[i].ty == t || seq(lw.sts[i].name, t.name)) { return &lw.sts[i]; } }
    return null;
}
fn AirTyp* Low.struct_ty(Low* lw, Node* decl)
{
    Node*[4] tps;
    if (lw.typarams(decl, &tps[0]) > 0) { lw.unsup(decl, "generic struct used without type arguments"); return null; }
    return lw.struct_inst(decl, null, 0);
}
fn AirTyp* Low.struct_inst(Low* lw, Node* decl, AirTyp** targs, usz nt)
{
    for (usz i = 0; i < lw.nst; i++)
    {
        if (lw.sts[i].decl != decl || lw.sts[i].nt != nt) { continue; }
        bool same = true;
        for (usz j = 0; j < nt; j++) { if (!air_ll::ty_eq(lw.sts[i].targs[j], targs[j])) { same = false; } }
        if (same) { return lw.sts[i].ty; }
    }
    if (lw.nst >= MAXST) { lw.unsup(decl, "more than 1024 struct types"); return null; }
    char* base = lw.text(decl);
    if (base == null) { base = "S"; }
    char[300] bb; usz bn = (usz)snprintf(&bb[0], 300, "%s", base);
    for (usz j = 0; j < nt; j++) { bn += (usz)snprintf(&bb[0] + bn, (usz)(300 - bn), "."); bn = mang(targs[j], &bb[0], bn, 300); }
    base = lw.dup(&bb[0]);
    // unique among data names
    char* nm = lw.dup(base);
    int k = 1;
    while (true)
    {
        bool clash = false;
        for (usz i = 0; i < lw.nst; i++) { if (seq(lw.sts[i].name, nm)) { clash = true; } }
        for (usz i = 0; i < lw.nen; i++) { if (seq(lw.ens[i].name, nm)) { clash = true; } }
        if (!clash) { break; }
        char[360] b; k++; snprintf(&b[0], 360, "%s.%d", base, k); nm = lw.dup(&b[0]);
    }
    AirTyp* t = lw.nominal(nm);
    lw.sts[lw.nst].decl = decl; lw.sts[lw.nst].name = nm; lw.sts[lw.nst].ty = t; lw.sts[lw.nst].nt = nt;
    for (usz j = 0; j < nt; j++) { lw.sts[lw.nst].targs[j] = targs[j]; }
    lw.nst++;
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, nm);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, nm);
    c.result_ty = t;
    d.add_ctor(c);
    lw.m.add_decl(d);
    Node*[4] tps; usz ntp = lw.typarams(decl, &tps[0]);
    usz mark = lw.ntsub;
    for (usz j = 0; j < ntp && j < nt; j++) { lw.tsub_push(tps[j], targs[j]); }
    for (usz i = 0; i < decl.child_count; i++)
    {
        Node* f = decl.children[i];
        if (f == null || f.kind != Nk.N_DECL_FIELD) { continue; }
        AirTyp* ft = lw.ty(f.type_ann);
        if (ft == null) { lw.unsup(f, "field type"); ft = lw.m.t_i64; }
        char* fnm = lw.text(f);
        c.add_field(air_ir::air_mk_field(lw.a, lw.dup(fnm != null ? fnm : "_"), ft, AMULT_UNR));
    }
    lw.ntsub = mark;
    return t;
}
// bind the type parameters of a generic declaration by matching its declared types against actual ones
fn void Low.unify(Low* lw, Node* tn, AirTyp* a)
{
    if (tn == null || a == null) { return; }
    switch (tn.kind)
    {
        case Nk.N_TY_NAME:
        {
            Node* r = tn.resolved;
            if (r != null && r.kind == Nk.N_DECL_TYPEPARAM)
            {
                for (usz i = lw.ntsub; i > 0; i--) { if (lw.tsub[i - 1].tp == r) { if (lw.tsub[i - 1].t == null) { lw.tsub[i - 1].t = a; } return; } }
            }
            return;
        }
        case Nk.N_TY_ARRAY: if (a.tag == ATYP_ARRAY && tn.child_count > 0) { lw.unify(tn.children[0], a.args[0]); } return;
        case Nk.N_TY_PTR: if (a.tag == ATYP_PTR && tn.child_count > 0) { lw.unify(tn.children[0], a.args[0]); } return;
        case Nk.N_TY_SLICE: { AirTyp* fe = lw.fat_elem(a); if (fe != null && tn.child_count > 0) { lw.unify(tn.children[0], fe); } return; }
        case Nk.N_TY_TUPLE: if (a.tag == ATYP_TUPLE) { for (usz i = 0; i < tn.child_count && i < a.arg_count; i++) { lw.unify(tn.children[i], a.args[i]); } } return;
        case Nk.N_TY_CONSTRAINT: if (tn.child_count > 0) { lw.unify(tn.children[0], a); } return;
        case Nk.N_TY_GENERIC:
        {
            StInfo* st = lw.st_of(a);
            if (st != null && tn.child_count > 0 && tn.children[0].resolved == st.decl) { for (usz i = 1; i < tn.child_count && i - 1 < st.nt; i++) { lw.unify(tn.children[i], st.targs[i - 1]); } }
            return;
        }
        case Nk.N_TY_FN:
        {
            CloI* ci = lw.clo_of(a); if (ci == null || tn.child_count < 2) { return; }
            Node* dom = tn.children[0];
            if (dom.kind == Nk.N_TY_TUPLE) { for (usz i = 0; i < dom.child_count && i < ci.np; i++) { lw.unify(dom.children[i], ci.ps[i]); } }
            else if (dom.kind != Nk.N_TY_UNIT && ci.np > 0) { lw.unify(dom, ci.ps[0]); }
            lw.unify(tn.children[1], ci.ret);
            return;
        }
        default: return;
    }
}

fn AirTyp* Low.ty(Low* lw, Node* t)
{
    if (t == null) { return null; }
    switch (t.kind)
    {
        case Nk.N_TY_UNIT: return lw.m.t_unit;
        case Nk.N_TY_BOTTOM: return lw.m.t_bottom;
        case Nk.N_TY_NAME: case Nk.N_TY_PATH:
        {
            char* nm = air_types::air_node_text(t, lw.it);
            if (nm != null && seq(nm, "str")) { return lw.fat_ty(null, true); }
            if (nm != null && seq(nm, "ptr")) { return lw.ptr(lw.m.t_u8); }   // the untyped pointer
            if (nm != null)
            {
                AirTyp* pr = air_types::air_prim_ty(lw.m, nm);
                if (pr != null && pr.tag != ATYP_STR && pr.tag != ATYP_BYTES) { return pr; }
            }
            Node* r = t.resolved;
            if (r == null && t.kind == Nk.N_TY_PATH) { r = lw.resolve_tpath(t); }
            if (r == null && t.kind == Nk.N_TY_NAME && lw.ty_root != null) { r = lw.type_in_root(lw.ty_root, nm); }   // a global's annotation is never resolved by the front end
            if (r != null && r.kind == Nk.N_DECL_TYPEPARAM)
            {
                AirTyp* bt = lw.tsub_get(r);
                if (bt == null) { lw.unsup(t, "type parameter with no instantiation"); return null; }
                return bt;
            }
            if (r != null && (r.kind == Nk.N_DECL_STRUCT)) { return lw.struct_ty(r); }
            if (r != null && r.kind == Nk.N_DECL_UNION) { return lw.union_ty(r); }
            if (r != null && r.kind == Nk.N_DECL_ENUM) { Enm* en = lw.enum_for(r); return en == null ? null : en.ty; }
            if (r != null && r.kind == Nk.N_DECL_TYPE && r.type_ann != null && r.type_ann != t) { return lw.ty(r.type_ann); }
            lw.unsup(t, nm != null ? nm : "type"); return null;
        }
        case Nk.N_TY_PTR:
        {
            if (t.child_count == 0) { return null; }
            Node* c0 = t.children[0];
            AirTyp* in_ = (c0 != null && c0.kind == Nk.N_TY_UNIT) ? lw.m.t_u8 : lw.ty(c0);   // *() is an untyped pointer: ptr(u8)
            return in_ == null ? null : lw.ptr(in_);
        }
        case Nk.N_TY_UNION:
        {
            AirTyp*[8] ms; usz nm = 0;
            lw.flatten_union(t, &ms[0], &nm, false);
            if (nm == 0) { return null; }
            if (nm == 1) { return ms[0]; }
            return lw.union_enum_ty(&ms[0], nm);
        }
        case Nk.N_TY_INTERSECT:
        {
            AirTyp*[8] ms; usz nm = 0;
            lw.flatten_union(t, &ms[0], &nm, true);
            if (nm == 1) { return ms[0]; }
            lw.unsup(t, "intersection of distinct types"); return null;
        }
        case Nk.N_TY_GENERIC:
        {
            Node* h = t.child_count > 0 ? t.children[0] : null;
            if (h == null || h.resolved == null || h.resolved.kind != Nk.N_DECL_STRUCT) { lw.unsup(t, "generic type"); return null; }
            AirTyp*[4] ta; usz nta = 0;
            for (usz i = 1; i < t.child_count && nta < 4; i++) { AirTyp* x = lw.ty(t.children[i]); if (x == null) { return null; } ta[nta] = x; nta++; }
            return lw.struct_inst(h.resolved, &ta[0], nta);
        }
        case Nk.N_TY_SLICE:
        {
            AirTyp* el = t.child_count > 0 ? lw.ty(t.children[0]) : null;
            return el == null ? null : lw.fat_ty(el, false);
        }
        case Nk.N_TY_ARRAY:
        {
            long alen = 0;
            if (t.child_count < 2 || !lw.const_int(t.children[1], &alen) || alen < 0) { lw.unsup(t, "array type without a constant length"); return null; }
            AirTyp* el = lw.ty(t.children[0]);
            return el == null ? null : air_ir::air_mk_typ_array(lw.a, el, alen);
        }
        case Nk.N_TY_TUPLE:
        {
            AirTyp*[16] ts; usz n = 0;
            for (usz i = 0; i < t.child_count && n < 16; i++) { AirTyp* e = lw.ty(t.children[i]); if (e == null) { return null; } ts[n] = e; n++; }
            return air_ir::air_mk_typ_tuple(lw.a, &ts[0], n);
        }
        case Nk.N_TY_FN:
        {
            AirTyp*[16] ps; usz np; AirTyp* rt;
            if (!lw.sig_of(t, &ps[0], &np, &rt)) { return null; }
            return lw.clo_ty(&ps[0], np, rt);   // a function-typed value is a closure record
        }
        case Nk.N_TY_CONSTRAINT: case Nk.N_TY_WHERE:
            return t.child_count > 0 ? lw.ty(t.children[0]) : null;
        default:
            lw.unsup(t, "type"); return null;
    }
}

// `A -> R ! [fx]`: parameters are the domain (a tuple = several), the result is the constraint child
fn bool Low.sig_of(Low* lw, Node* tf, AirTyp** ps, usz* np, AirTyp** rt)
{
    usz cc = tf.child_count;
    if (cc > 0 && tf.children[cc - 1] != null && tf.children[cc - 1].kind == Nk.N_TY_EFFECT_ROW) { cc--; }
    if (cc < 2) { lw.unsup(tf, "function type shape"); return false; }
    Node* dom = tf.children[0];
    *np = 0;
    if (cc > 2)   // `fn(a, b) -> r`: the parameters are the leading children
    {
        for (usz i = 0; i + 1 < cc && *np < 16; i++) { AirTyp* e = lw.ty(tf.children[i]); if (e == null) { return false; } ps[*np] = e; *np = *np + 1; }
    }
    else if (dom.kind == Nk.N_TY_UNIT) { }
    else if (dom.kind == Nk.N_TY_TUPLE)
    {
        for (usz i = 0; i < dom.child_count && *np < 16; i++)
        {
            if (dom.children[i] != null && dom.children[i].kind == Nk.N_TY_INFER && i + 1 == dom.child_count) { continue; }   // the trailing `...` of a variadic extern
            AirTyp* e = lw.ty(dom.children[i]); if (e == null) { return false; }
            ps[*np] = e; *np = *np + 1;
        }
    }
    else { AirTyp* e = lw.ty(dom); if (e == null) { return false; } ps[0] = e; *np = 1; }
    AirTyp* r = lw.ty(tf.children[cc - 1]);
    if (r == null) { return false; }
    *rt = r;
    return true;
}

// ── function registry ──────────────────────────────────────────────────────
fn FnInfo* Low.fn_for(Low* lw, Node* d)
{
    Node*[4] tps;
    if (lw.typarams(d, &tps[0]) > 0) { lw.unsup(d, "generic function used without type arguments"); return null; }
    return lw.fn_inst(d, null, 0);
}
fn FnInfo* Low.fn_inst(Low* lw, Node* d, AirTyp** targs, usz nt)
{
    for (usz i = 0; i < lw.nfn; i++)
    {
        if (lw.fns[i].decl != d || lw.fns[i].is_lam || lw.fns[i].is_adapt || lw.fns[i].nts != nt) { continue; }
        bool same = true;
        for (usz j = 0; j < nt; j++) { if (!air_ll::ty_eq(lw.fns[i].ts[j].t, targs[j])) { same = false; } }
        if (same) { return &lw.fns[i]; }
    }
    usz mark = lw.ntsub;
    Node*[4] tps; usz ntp = lw.typarams(d, &tps[0]);
    for (usz j = 0; j < ntp && j < nt; j++) { lw.tsub_push(tps[j], targs[j]); }
    FnInfo* f = lw.fn_build(d, targs, nt, &tps[0]);
    lw.ntsub = mark;
    return f;
}
// pick the instance a call refers to: infer the type arguments by unifying the declared parameter types with the arguments
fn FnInfo* Low.callee_fn(Low* lw, Node* call, Node* cr)
{
    Node*[4] tps; usz ntp = lw.typarams(cr, &tps[0]);
    if (ntp == 0) { return lw.fn_for(cr); }
    usz mark = lw.ntsub;
    for (usz j = 0; j < ntp; j++) { lw.tsub_push(tps[j], null); }
    Node* ft = cr.type_ann;
    if (ft != null && ft.kind == Nk.N_TY_FN && ft.child_count > 0)
    {
        Node* dom = ft.children[0];
        for (usz i = 1; i < call.child_count; i++)
        {
            Node* pn = null;
            if (dom.kind == Nk.N_TY_TUPLE) { pn = (i - 1) < dom.child_count ? dom.children[i - 1] : null; }
            else if (i == 1) { pn = dom; }
            AirTyp* ah = lw.hint(call.children[i]);
            if (ah == null && call.children[i].kind == Nk.N_EXPR_INT) { ah = lw.m.t_i64; }
            lw.unify(pn, ah);
        }
    }
    AirTyp*[4] ta; bool ok = true;
    for (usz j = 0; j < ntp; j++) { ta[j] = lw.tsub[mark + j].t; if (ta[j] == null) { ok = false; } }
    lw.ntsub = mark;
    if (!ok) { lw.err(call, "cannot infer the type arguments of this call", lw.text(cr)); return null; }
    return lw.fn_inst(cr, &ta[0], ntp);
}
fn FnInfo* Low.fn_build(Low* lw, Node* d, AirTyp** targs, usz nt, Node** tps)
{
    if (lw.nfn >= MAXFN) { lw.unsup(d, "more than 4096 functions"); return null; }
    FnInfo* f = &lw.fns[lw.nfn];
    usz esl = 0; char* esp = pfront_core::ext_sym_of(d, &esl);
    f.decl = d; f.ext = d.kind == Nk.N_DECL_EXTERN_FN || (d.kind == Nk.N_DECL_FN && esp != null); f.nts = nt;
    for (usz j = 0; j < nt; j++) { f.ts[j].tp = tps[j]; f.ts[j].t = targs[j]; }
    char* base = lw.text(d); if (base == null) { base = "_fn"; }
    if (esp != null)   // #extern("symbol"): the C symbol is the name
    {
        char[200] sb; usz k = esl < 199 ? esl : 199;
        for (usz i = 0; i < k; i++) { sb[i] = esp[i]; } sb[k] = 0;
        base = lw.dup(&sb[0]);
    }
    if (nt > 0)
    {
        char[300] bb; usz bn = (usz)snprintf(&bb[0], 300, "%s", base);
        for (usz j = 0; j < nt; j++) { bn += (usz)snprintf(&bb[0] + bn, (usz)(300 - bn), "."); bn = mang(targs[j], &bb[0], bn, 300); }
        base = lw.dup(&bb[0]);
    }
    // names are unique across the program; externs keep their C symbol, so they are never renamed
    char* nm = lw.dup(base);
    if (!f.ext)
    {
        int k = 1;
        while (true)
        {
            bool clash = seq(nm, "malloc") || seq(nm, "free") || seq(nm, "write") || seq(nm, "syscall") || seq(nm, "main") && !lw.is_entry(d);
            if (!clash && lw.is_extern_symbol(nm)) { clash = true; }   // an extern keeps its C symbol, so a Pride def of the same name is the one renamed
            for (usz i = 0; i < lw.nfn; i++) { if (seq(lw.fns[i].name, nm)) { clash = true; } }
            if (!clash) { break; }
            char[160] b; k++; snprintf(&b[0], 160, "%s.%d", base, k); nm = lw.dup(&b[0]);
        }
    }
    f.name = nm;
    lw.nfn++;
    if (d.kind == Nk.N_DECL_FN && d.type_ann != null && d.type_ann.kind == Nk.N_TY_FN)
    {
        if (!lw.sig_of(d.type_ann, &f.pty[0], &f.np, &f.ret)) { lw.nfn--; return null; }
        if (d.type_ann.child_count > 0 && d.type_ann.children[0] != null && (d.type_ann.children[0].flags & pfront_core::NF_VARIADIC) != 0) { f.variadic = true; }
    }
    else if (f.ext || d.kind == Nk.N_DECL_FN)
    {
        // `extern fn` and brace-style `fn f(a: T, b: U) -> R { .. }`: params are N_DECL_PARAM children,
        // the result is the node's own annotation
        f.np = 0;
        for (usz i = 0; i < d.child_count; i++)
        {
            Node* c = d.children[i];
            if (c == null || c.kind != Nk.N_DECL_PARAM) { continue; }
            Node* tn = c.type_ann;
            if (tn == null && c.child_count > 0 && c.children[0] != null) { tn = c.children[0].type_ann; }
            if (tn == null && c.child_count > 0 && c.children[0] != null && c.children[0].kind == Nk.N_PAT_WILDCARD) { continue; }   // `main(_)`: no parameter
            AirTyp* pt = lw.ty(tn); if (pt == null) { lw.nfn--; return null; }
            if (f.np < 16) { f.pty[f.np] = pt; f.np++; }
        }
        Node* rn = d.type_ann;
        f.ret = (rn == null || rn.kind == Nk.N_TY_FN) ? lw.m.t_unit : lw.ty(rn);
        if (f.ret == null) { lw.nfn--; return null; }
        f.variadic = (d.flags & pfront_core::NF_VARIADIC) != 0;
    }
    else { lw.unsup(d, "function without a signature"); lw.nfn--; return null; }
    f.fnty = lw.arrow(&f.pty[0], f.np, f.ret);
    return f;
}
fn bool Low.is_brace_fn(Low* lw, Node* d)
{
    for (usz i = 0; i < d.child_count; i++) { if (d.children[i] != null && d.children[i].kind == Nk.N_DECL_PARAM) { return true; } }
    return d.type_ann != null && d.type_ann.kind != Nk.N_TY_FN;
}
fn bool Low.is_entry(Low* lw, Node* d) { return d != null && d == lw.entry_decl; }

// ── blocks ─────────────────────────────────────────────────────────────────
fn usz Low.blk(Low* lw, char* stem)
{
    if (lw.nb >= MAXBLK) { lw.unsup(null, "more than 8192 basic blocks in one function"); return 0; }
    usz i = lw.nb; lw.nb++;
    Blk* b = &lw.blks[i];
    b.name = lw.fresh(stem); b.np = 0; b.ni = 0; b.tk = T_NONE; b.npred = 0; b.nj = 0;
    return i;
}
fn bool Low.live(Low* lw) { return lw.cur != NOBLK; }
fn Ins* Low.push(Low* lw, InsK k)
{
    if (lw.cur == NOBLK) { return null; }
    Blk* b = &lw.blks[lw.cur];
    if (b.ni >= b.cap)
    {
        usz nc = b.cap == 0 ? 16 : b.cap * 2;
        b.ins = (Ins*)realloc(b.ins, nc * Ins::size); b.cap = nc;
    }
    Ins* r = &b.ins[b.ni]; b.ni++;
    r.k = k; r.name = null; r.a = null; r.b = null; r.nargs = 0; r.fld = null; r.idx = 0;
    return r;
}
fn Vx Low.unit(Low* lw) { Vx v; v.p = lw.m.p_unit; v.t = lw.m.t_unit; return v; }
fn Vx Low.vref(Low* lw, char* nm, AirTyp* t) { Vx v; v.p = air_ir::air_mk_var(lw.a, nm); v.t = t; return v; }

fn Vx Low.let_(Low* lw, AirPrd* p, AirTyp* t, char* stem)
{
    p.ty = t;
    Ins* i = lw.push(I_LET);
    if (i == null) { return lw.unit(); }
    i.name = lw.fresh(stem); i.a = p;
    return lw.vref(i.name, t);
}
fn bool is_lit(AirPrd* p) { return p != null && (p.tag == APRD_INT || p.tag == APRD_BOOL || p.tag == APRD_FLOAT || p.tag == APRD_CHAR || p.tag == APRD_NULL || p.tag == APRD_UNIT); }
fn bool is_atom(AirPrd* p) { return p != null && (p.tag == APRD_VAR || is_lit(p)); }
// a name for a value (jump arguments are names)
fn char* Low.name_of(Low* lw, Vx v)
{
    if (v.p != null && v.p.tag == APRD_VAR) { return v.p.name; }
    Vx t = lw.let_(v.p, v.t, "_v");
    return t.p != null && t.p.tag == APRD_VAR ? t.p.name : "_v";
}

fn Vx Low.lit_int(Low* lw, long v, AirTyp* t)
{
    AirPrd* p = air_ir::air_mk_int(lw.a, v); p.ty = t;
    Vx r; r.p = p; r.t = t; return r;
}
fn Vx Low.lit_bool(Low* lw, bool b) { Vx r; r.p = air_ir::air_mk_prd_bool(lw.a, b); r.p.ty = lw.m.t_bool; r.t = lw.m.t_bool; return r; }

fn Vx Low.binop(Low* lw, AirBinop op, Vx a, Vx b)
{
    bool cmp = op == ABIN_EQ || op == ABIN_NEQ || op == ABIN_LT || op == ABIN_GT || op == ABIN_LE || op == ABIN_GE;
    AirPrd* p = air_ir::air_mk_binop(lw.a, op, a.p, b.p);
    return lw.let_(p, cmp ? lw.m.t_bool : a.t, "_t");
}
fn Vx Low.coerce(Low* lw, Vx v, AirTyp* to)
{
    if (to == null || v.t == null || air_ll::ty_eq(v.t, to)) { return v; }
    if (v.p != null && v.p.tag == APRD_INT && air_ll::ty_is_int(to)) { return lw.lit_int(v.p.ival, to); }
    if (v.p != null && v.p.tag == APRD_NULL && to.tag == ATYP_PTR) { AirPrd* np_ = air_ir::air_mk_prd_null(lw.a); np_.ty = to; Vx r; r.p = np_; r.t = to; return r; }
    if (v.t.tag == ATYP_PTR && lw.clo_of(to) != null) { return lw.raw_clo(v, to); }   // `code_ptr as fn(..) -> r`: a closure whose env IS the code pointer
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_COERCE; p.add_sub(v.p); p.ty = to;
    return lw.let_(p, to, "_c");
}
fn Vx Low.load(Low* lw, AirPrd* ptr, AirTyp* t)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_LOAD; p.add_sub(ptr);
    return lw.let_(p, t, "_l");
}
fn void Low.store(Low* lw, AirPrd* ptr, Vx v)
{
    Ins* i = lw.push(I_STORE); if (i == null) { return; }
    i.a = ptr; i.b = v.p;
}
// gep[T](base, idx...) with the resulting pointer type
fn Vx Low.gep(Low* lw, AirPrd* base, AirTyp* src, Vx* idx, usz ni, AirTyp* result_pointee)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_GEP; p.ty_arg = src; p.add_sub(base);
    for (usz i = 0; i < ni; i++) { p.add_sub(idx[i].p); }
    return lw.let_(p, lw.ptr(result_pointee), "_g");
}
// sizeof(T): the producer's own `ty` IS the measured type (the result is always usz), so no let_() annotation
fn Vx Low.sizeof_(Low* lw, AirTyp* t)
{
    Ins* i = lw.push(I_LET); if (i == null) { return lw.unit(); }
    i.name = lw.fresh("_sz"); i.a = air_ir::air_mk_sizeof(lw.a, t);
    return lw.vref(i.name, lw.m.t_usz);
}
fn Vx Low.alloca_(Low* lw, AirTyp* t)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_ALLOCA; p.ty_arg = t;
    return lw.let_(p, lw.ptr(t), "_s");
}

fn void Low.mark_pred(Low* lw, usz b) { if (b != NOBLK) { lw.blks[b].npred++; } }
fn void Low.t_ret(Low* lw, Vx v)
{
    if (lw.cur == NOBLK) { return; }
    Blk* b = &lw.blks[lw.cur]; b.tk = T_RET; b.tp = v.p; lw.cur = NOBLK;
}
fn void Low.t_jump(Low* lw, usz to, Vx* args, usz n)
{
    if (lw.cur == NOBLK) { return; }
    char*[8] names;
    for (usz i = 0; i < n && i < 8; i++) { names[i] = lw.name_of(args[i]); }
    Blk* b = &lw.blks[lw.cur];
    b.tk = T_JUMP; b.t1 = to; b.nj = n;
    for (usz i = 0; i < n && i < 8; i++) { b.jargs[i] = names[i]; }
    lw.mark_pred(to); lw.cur = NOBLK;
}
fn void Low.t_jump0(Low* lw, usz to) { Vx[1] none; lw.t_jump(to, &none[0], 0); }
fn void Low.t_cond(Low* lw, Vx c, usz yes, usz no)
{
    if (lw.cur == NOBLK) { return; }
    Blk* b = &lw.blks[lw.cur]; b.tk = T_COND; b.tp = c.p; b.t1 = yes; b.t2 = no;
    lw.mark_pred(yes); lw.mark_pred(no); lw.cur = NOBLK;
}
fn void Low.t_end(Low* lw, TermK k)
{
    if (lw.cur == NOBLK) { return; }
    lw.blks[lw.cur].tk = k; lw.cur = NOBLK;
}

// ── variables ──────────────────────────────────────────────────────────────
fn void Low.bind_var(Low* lw, Node* decl, AirPrd* p, AirTyp* t, bool slot)
{
    if (lw.nvars >= MAXVAR) { lw.unsup(decl, "more than 8192 locals in one function"); return; }
    lw.vars[lw.nvars].decl = decl; lw.vars[lw.nvars].p = p; lw.vars[lw.nvars].t = t; lw.vars[lw.nvars].slot = slot; lw.nvars++;
}
fn VarB* Low.find_var(Low* lw, Node* decl)
{
    for (usz i = lw.nvars; i > 0; i--) { if (lw.vars[i - 1].decl == decl) { return &lw.vars[i - 1]; } }
    return null;
}

// ── type hints (no code is emitted) ────────────────────────────────────────
fn AirTyp* Low.pointee(Low* lw, AirTyp* t) { return (t != null && t.tag == ATYP_PTR) ? t.args[0] : null; }
fn AirTyp* Low.field_ty(Low* lw, AirTyp* st, char* f, long* idx)
{
    UniI* un = lw.uni_of(st);
    if (un != null) { *idx = 0; return lw.uni_field(un, f); }
    AirDecl* d = lw.data_of(st);
    if (d == null || d.ctor_count != 1) { return null; }
    AirCtorDecl* c = d.ctors[0];
    for (usz i = 0; i < c.field_count; i++) { if (seq(c.fields[i].name, f)) { *idx = (long)i; return c.fields[i].ty; } }
    return null;
}
fn AirTyp* Low.int_suffix_ty(Low* lw, Node* n)   // `5u8` -> u8; an unsuffixed literal has no type of its own
{
    if (n.p.width == 0 || (n.p.aux == 99 && n.p.width == 64 && n.p.is_signed)) { return null; }
    char[16] sb; snprintf(&sb[0], 16, "%c%d", n.p.is_signed ? 'i' : 'u', (int)n.p.width);
    AirTyp* st = air_types::air_prim_ty(lw.m, &sb[0]);
    return (st != null && air_ll::ty_is_int(st)) ? st : null;
}
fn AirTyp* Low.hint(Low* lw, Node* n)
{
    if (n == null) { return null; }
    switch (n.kind)
    {
        case Nk.N_EXPR_BOOL: return lw.m.t_bool;
        case Nk.N_EXPR_CHAR: return lw.m.t_char;
        case Nk.N_EXPR_INT: return lw.int_suffix_ty(n);
        case Nk.N_EXPR_FLOAT: return lw.m.t_f64;
        case Nk.N_EXPR_STRING: return lw.ptr(lw.m.t_u8);
        case Nk.N_EXPR_LAMBDA:
        {
            AirTyp*[16] hps; usz hnp = 0; AirTyp* hret = null;
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i]; if (c == null || c.kind != Nk.N_DECL_PARAM) { continue; }
                Node* pat = c.child_count > 0 ? c.children[0] : null;
                Node* tn = c.type_ann != null ? c.type_ann : (pat != null ? pat.type_ann : null);
                AirTyp* pt = tn == null ? null : lw.ty_quiet(tn); if (pt == null || hnp >= 15) { return null; }
                hps[hnp] = pt; hnp++;
            }
            hret = n.type_ann == null ? null : lw.ty_quiet(n.type_ann); if (hret == null) { return null; }
            return lw.clo_ty(&hps[0], hnp, hret);
        }
        case Nk.N_EXPR_PERFORM:
        {
            Node* eff = null; Node* op = null; AirTyp*[16] ps; usz np = 0; AirTyp* ret = null;
            if (n.child_count == 0 || !lw.eff_path(n.children[0], &eff, &op)) { return null; }
            return lw.op_sig(op, &ps[0], &np, &ret) ? ret : null;
        }
        case Nk.N_EXPR_HANDLE: return n.child_count > 0 ? lw.hint(n.children[0]) : null;
        case Nk.N_EXPR_METHOD:
        {
            if (n.child_count > 0 && n.children[0] != null && n.children[0].resolved != null && n.children[0].resolved.kind == Nk.N_DECL_EFFECT)
            {
                Node* op = lw.effect_op(n.children[0].resolved, lw.dname(n)); AirTyp*[16] ps; usz np = 0; AirTyp* ret = null;
                return (op != null && lw.op_sig(op, &ps[0], &np, &ret)) ? ret : null;
            }
            Node* mcr = n.resolved;
            if (mcr != null && (mcr.kind == Nk.N_DECL_FN || mcr.kind == Nk.N_DECL_EXTERN_FN))
            {
                Node*[4] mtp; FnInfo* mf = null;
                if (lw.typarams(mcr, &mtp[0]) == 0) { mf = lw.fn_for(mcr); }
                else { int se = lw.errors; int sfe = lw.fn_errors; mf = lw.callee_fn(n, mcr); if (mf == null) { lw.errors = se; lw.fn_errors = sfe; } }
                return mf == null ? null : mf.ret;
            }
            long hv = -1; Enm* he = n.child_count > 0 ? lw.enum_ctor_base(n.children[0], lw.dname(n), &hv) : null;
            return he == null ? null : he.ty;
        }
        case Nk.N_EXPR_QUOTE:
        {
            AirTyp* qr = n.child_count > 0 ? lw.hint_or_lit(n.children[0]) : null;
            return qr == null ? null : lw.clo_ty(null, 0, qr);
        }
        case Nk.N_EXPR_SPLICE:
        case Nk.N_EXPR_EVAL:
        {
            AirTyp* qc = n.child_count > 0 ? lw.hint(n.children[0]) : null;
            CloI* qi = qc == null ? null : lw.clo_of(qc);
            return qi == null ? null : qi.ret;
        }
        case Nk.N_EXPR_ARRAY:
        {
            if (n.child_count == 0) { return null; }
            AirTyp* e0 = lw.hint(n.children[0]);
            long hc = (long)n.child_count;
            if (n.p.aux == 8 && !lw.const_int(n.children[1], &hc)) { return null; }
            return e0 == null ? null : air_ir::air_mk_typ_array(lw.a, e0, hc);
        }
        case Nk.N_EXPR_IDENT:
        {
            Node* r = n.resolved;
            VarB* v = lw.find_var(r);
            if (v != null) { return v.t; }
            if (r != null && r.kind == Nk.N_DECL_CONST && r.type_ann != null) { return lw.ty(r.type_ann); }
            if (r != null && (r.kind == Nk.N_DECL_STATIC || r.kind == Nk.N_DECL_LET)) { return lw.static_ty(r); }
            return null;
        }
        case Nk.N_EXPR_CAST: return lw.ty(n.type_ann);
        case Nk.N_EXPR_CALL:
        {
            if (n.child_count == 0) { return null; }
            Node* cr = n.children[0].resolved;
            if (cr == null && n.children[0].kind == Nk.N_EXPR_IDENT) { cr = lw.fn_by_name(lw.text(n.children[0])); }
            if (cr != null && (cr.kind == Nk.N_DECL_FN || cr.kind == Nk.N_DECL_EXTERN_FN))
            {
                Node*[4] htp; FnInfo* f = null;
                if (lw.typarams(cr, &htp[0]) == 0) { f = lw.fn_for(cr); }
                else { int se = lw.errors; int sfe = lw.fn_errors; f = lw.callee_fn(n, cr); if (f == null) { lw.errors = se; lw.fn_errors = sfe; } }
                return f == null ? null : f.ret;
            }
            return null;
        }
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ
                || op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_AND || op == Tk.TOKEN_KW_OR) { return lw.m.t_bool; }
            AirTyp* l = lw.hint(n.children[0]);
            if (l != null) { return l; }
            return lw.hint(n.children[1]);
        }
        case Nk.N_EXPR_UNARY:
        {
            if ((Tk)n.p.op == Tk.TOKEN_BANG) { return lw.m.t_bool; }
            return lw.hint(n.children[0]);
        }
        case Nk.N_EXPR_DEREF: return lw.pointee(lw.hint(n.children[0]));
        case Nk.N_EXPR_REF: { AirTyp* t = lw.hint(n.children[0]); return t == null ? null : lw.ptr(t); }
        case Nk.N_EXPR_INDEX:
        {
            AirTyp* b = lw.hint(n.children[0]);
            if (b != null && b.tag == ATYP_ARRAY) { return b.args[0]; }
            AirTyp* fe = lw.fat_elem(b); if (fe != null) { return fe; }
            return lw.pointee(b);
        }
        case Nk.N_EXPR_FIELD:
        {
            long hv = -1; Enm* he = lw.enum_ctor_base(n.children[0], lw.dname(n), &hv);
            if (he != null) { return he.ty; }
            AirTyp* b = lw.hint(n.children[0]);
            if (b != null && b.tag == ATYP_TUPLE && n.p.aux == 1)
            {
                long hti = (long)n.p.ival;
                return hti < (long)b.arg_count ? b.args[hti] : null;
            }
            if (b != null && b.tag == ATYP_PTR) { b = b.args[0]; }
            char* f = lw.text(n); long ix = 0;
            return b == null || f == null ? null : lw.field_ty(b, f, &ix);
        }
        case Nk.N_EXPR_STRUCT_LIT:
        {
            Node* r = n.resolved; if (r == null && n.child_count > 0) { r = n.children[0].resolved; }
            if (r != null && r.kind == Nk.N_DECL_UNION) { return lw.union_ty(r); }
            if (r == null || r.kind != Nk.N_DECL_STRUCT) { return null; }
            Node*[4] hq; if (lw.typarams(r, &hq[0]) > 0) { int se = lw.errors; int sf = lw.fn_errors; AirTyp* gt = lw.lit_struct_ty(n, r, null); if (gt == null) { lw.errors = se; lw.fn_errors = sf; } return gt; }
            return lw.struct_ty(r);
        }
        case Nk.N_EXPR_SIZEOF: case Nk.N_EXPR_ALIGNOF: return lw.m.t_usz;
        case Nk.N_EXPR_SYSCALL: return lw.m.t_i64;
        case Nk.N_BLOCK: return n.child_count > 0 ? lw.hint(n.children[n.child_count - 1]) : lw.m.t_unit;
        case Nk.N_EXPR_TUPLE:
        {
            if (n.child_count == 0 || n.child_count > 16) { return null; }
            AirTyp*[16] hts;
            for (usz i = 0; i < n.child_count; i++) { hts[i] = lw.hint(n.children[i]); if (hts[i] == null) { return null; } }
            return air_ir::air_mk_typ_tuple(lw.a, &hts[0], n.child_count);
        }
        case Nk.N_EXPR_ALLOC:
        {
            AirTyp* e = lw.alloc_elem(n, null);
            return e == null ? null : lw.ptr(e);
        }
        default: return null;
    }
}

// ── statics ────────────────────────────────────────────────────────────────
fn AirTyp* Low.static_ty(Low* lw, Node* d)
{
    for (usz i = 0; i < lw.ngl; i++) { if (lw.gls[i].decl == d) { return lw.gls[i].ty; } }
    Node* saved_root = lw.ty_root; lw.ty_root = lw.root_of(d);
    AirTyp* st = lw.static_ty_in(d);
    lw.ty_root = saved_root;
    return st;
}
fn AirTyp* Low.static_ty_in(Low* lw, Node* d)
{
    AirTyp* t = d.type_ann != null ? lw.ty(d.type_ann) : null;
    if (t == null)
    {
        for (usz i = 0; i < d.child_count; i++) { Node* c = d.children[i]; if (c != null && c.type_ann != null && pfront_core::is_type(c.type_ann.kind)) { t = lw.ty(c.type_ann); break; } }
    }
    return t;
}
fn GlInfo* Low.global_for(Low* lw, Node* d)
{
    for (usz i = 0; i < lw.ngl; i++) { if (lw.gls[i].decl == d) { return &lw.gls[i]; } }
    if (lw.ngl >= MAXGL) { lw.unsup(d, "more than 1024 globals"); return null; }
    AirTyp* t = lw.static_ty(d);
    if (t == null)
    {
        for (usz i = 0; i < d.child_count && t == null; i++) { Node* c = d.children[i]; if (c != null && pfront_core::is_expr(c.kind)) { t = lw.hint_or_lit(c); } }
    }
    if (t == null) { lw.unsup(d, "global without a declared type"); return null; }
    char* base = lw.text(d); if (base == null) { base = "g"; }
    char* nm = lw.dup(base); int k = 1;
    while (true)
    {
        bool clash = false;
        for (usz i = 0; i < lw.ngl; i++) { if (seq(lw.gls[i].name, nm)) { clash = true; } }
        for (usz i = 0; i < lw.nfn; i++) { if (seq(lw.fns[i].name, nm)) { clash = true; } }
        if (!clash) { break; }
        char[160] b; k++; snprintf(&b[0], 160, "%s.%d", base, k); nm = lw.dup(&b[0]);
    }
    GlInfo* g = &lw.gls[lw.ngl]; g.decl = d; g.name = nm; g.ty = t; lw.ngl++;
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_GLOBAL, nm);
    ad.ret_ty = t; ad.g_mut = (d.flags & pfront_core::NF_MUT) != 0;
    // constant initialiser: a literal (anything else needs a run-time initialiser, not lowered yet)
    Node* init = null;
    for (usz i = 0; i < d.child_count; i++) { Node* c = d.children[i]; if (c != null && pfront_core::is_expr(c.kind)) { init = c; } }
    if (init != null)
    {
        Node* e = init;
        bool neg = false;
        if (e.kind == Nk.N_EXPR_UNARY && (Tk)e.p.op == Tk.TOKEN_MINUS && e.child_count > 0) { neg = true; e = e.children[0]; }
        if (e.kind == Nk.N_EXPR_INT && air_ll::ty_is_int(t)) { ad.g_init = air_ir::air_mk_int(lw.a, neg ? -(long)e.p.ival : (long)e.p.ival); ad.g_init.ty = t; }
        else if (e.kind == Nk.N_EXPR_FLOAT && air_ll::ty_is_float(t)) { ad.g_init = air_ir::air_mk_float(lw.a, neg ? -e.p.fval : e.p.fval); ad.g_init.ty = t; }
        else if (e.kind == Nk.N_EXPR_BOOL && t.tag == ATYP_BOOL) { ad.g_init = air_ir::air_mk_prd_bool(lw.a, e.p.ival != 0); ad.g_init.ty = t; }
        else if (t.tag == ATYP_PTR && (e.kind == Nk.N_EXPR_NULL || (e.kind == Nk.N_EXPR_INT && e.p.ival == 0)
                 || (e.kind == Nk.N_EXPR_CAST && e.child_count > 0 && e.children[0] != null && e.children[0].kind == Nk.N_EXPR_INT && e.children[0].p.ival == 0)))
        { AirPrd* gz = air_ir::air_mk_prd_null(lw.a); gz.ty = t; ad.g_init = gz; }   // `0 as *T` / `null`
        else
        {
            AirPrd* ci = lw.const_init(init, t);
            if (ci != null) { ad.g_init = ci; }
            else { lw.unsup(init, "global initialiser that is not a constant"); }
        }
    }
    lw.m.add_decl(ad);
    return g;
}


// ── fat pointers: `[T]` and `str` are the record { ptr: ptr(T), len: i64 } ──────────────────────
fn usz mang(AirTyp* t, char* b, usz n, usz cap)
{
    if (t == null || n + 8 >= cap) { return n; }
    if (t.tag == ATYP_PTR) { n += (usz)snprintf(b + n, (usz)(cap - n), "p."); return mang(t.args[0], b, n, cap); }
    if (t.tag == ATYP_NOMINAL) { return n + (usz)snprintf(b + n, (usz)(cap - n), "%s", t.name); }
    if (t.tag == ATYP_ARRAY) { n += (usz)snprintf(b + n, (usz)(cap - n), "a%ld.", t.ival); return mang(t.args[0], b, n, cap); }
    if (t.tag == ATYP_TUPLE) { n += (usz)snprintf(b + n, (usz)(cap - n), "t%d.", (int)t.arg_count); for (usz i = 0; i < t.arg_count; i++) { n = mang(t.args[i], b, n, cap); n += (usz)snprintf(b + n, (usz)(cap - n), "."); } return n; }
    if (t.tag == ATYP_ARROW) { n += (usz)snprintf(b + n, (usz)(cap - n), "fn."); n = mang(t.args[0], b, n, cap); n += (usz)snprintf(b + n, (usz)(cap - n), ">"); return mang(t.args[1], b, n, cap); }
    return n + (usz)snprintf(b + n, (usz)(cap - n), "%s", air_text::typ_kw(t.tag));
}
fn AirTyp* Low.fat_ty(Low* lw, AirTyp* elem, bool is_str)
{
    for (usz i = 0; i < lw.nfat; i++)
    {
        if (lw.fats[i].is_str == is_str && (is_str || air_ll::ty_eq(lw.fats[i].elem, elem))) { return lw.fats[i].ty; }
    }
    if (lw.nfat >= 48) { lw.unsup(null, "more than 48 slice types"); return null; }
    if (is_str) { elem = lw.m.t_u8; }
    char[200] nm; usz n = 0;
    if (is_str) { snprintf(&nm[0], 200, "str"); }
    else { n = (usz)snprintf(&nm[0], 200, "slice."); mang(elem, &nm[0], n, 200); }
    char* name = lw.dup(&nm[0]);
    AirTyp* t = lw.nominal(name);
    lw.fats[lw.nfat].elem = elem; lw.fats[lw.nfat].ty = t; lw.fats[lw.nfat].is_str = is_str; lw.nfat++;
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, name);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, name);
    c.result_ty = t;
    d.add_ctor(c);
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("ptr"), lw.ptr(elem), AMULT_UNR));
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("len"), lw.m.t_i64, AMULT_UNR));
    lw.m.add_decl(d);
    return t;
}
// the element type when `t` is a slice (or `str`), else null
fn AirTyp* Low.fat_elem(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.nfat; i++) { if (lw.fats[i].ty == t || (lw.fats[i].ty.name != null && seq(lw.fats[i].ty.name, t.name))) { return lw.fats[i].elem; } }
    return null;
}
fn Vx Low.mk_fat(Low* lw, AirTyp* ft, Vx ptr, Vx len)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_RECORD;
    AirFieldInit* f0 = air_ir::air_new_AirFieldInit(lw.a); f0.name = lw.dup("ptr"); f0.value = ptr.p;
    AirFieldInit* f1 = air_ir::air_new_AirFieldInit(lw.a); f1.name = lw.dup("len"); f1.value = len.p;
    p.rec_inits[0] = f0; p.rec_inits[1] = f1; p.rec_init_count = 2;
    return lw.let_(p, ft, "_fat");
}
fn Vx Low.field_of(Low* lw, Vx v, char* f, long k, AirTyp* t)
{
    Ins* ins = lw.push(I_FIELD); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_f"); ins.a = v.p; ins.fld = f; ins.idx = k;
    return lw.vref(ins.name, t);
}
// a slice over an array that lives in memory (aliases it: writes through the slice are visible in the array)
fn Vx Low.slice_at(Low* lw, AirPrd* ptr, AirTyp* arr, AirTyp* sl)
{
    Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int(0, lw.m.t_i64);
    Vx g = lw.gep(ptr, arr, &ix[0], 2, arr.args[0]);
    return lw.mk_fat(sl, g, lw.lit_int(arr.ival, lw.m.t_i64));
}
// an array VALUE (a literal, a call result) becomes a slice over a stack copy of it
fn Vx Low.array_to_slice(Low* lw, Vx arr, AirTyp* sl)
{
    Vx slot = lw.alloca_(arr.t);
    lw.store(slot.p, arr);
    return lw.slice_at(slot.p, arr.t, sl);
}
// trap unless 0 <= i < len (one unsigned compare); `unchecked { }` removes the test
fn void Low.bounds(Low* lw, Vx i, Vx len)
{
    if (lw.unchecked > 0 || !lw.live()) { return; }
    AirTyp* u = lw.m.t_u64;
    Vx c = lw.binop(ABIN_LT, lw.coerce(i, u), lw.coerce(len, u));
    usz ok = lw.blk("bnd.ok"); usz bad = lw.blk("bnd.fail");
    lw.t_cond(c, ok, bad);
    lw.cur = bad; lw.t_end(T_TRAP);
    lw.cur = ok;
}
// integer constant expressions: literals, `const` names, + - * / << and parentheses of those
fn bool Low.const_int(Low* lw, Node* n, long* out)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_EXPR_INT) { *out = (long)n.p.ival; return true; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null && n.resolved.kind == Nk.N_DECL_CONST)
    {
        for (usz i = 0; i < n.resolved.child_count; i++) { Node* c = n.resolved.children[i]; if (c != null && pfront_core::is_expr(c.kind)) { return lw.const_int(c, out); } }
        return false;
    }
    if (n.kind == Nk.N_EXPR_BINARY && n.child_count == 2)
    {
        long a = 0; long b = 0;
        if (!lw.const_int(n.children[0], &a) || !lw.const_int(n.children[1], &b)) { return false; }
        switch ((Tk)n.p.op)
        {
            case Tk.TOKEN_PLUS: *out = a + b; return true;
            case Tk.TOKEN_MINUS: *out = a - b; return true;
            case Tk.TOKEN_STAR: *out = a * b; return true;
            case Tk.TOKEN_SLASH: if (b == 0) { return false; } *out = a / b; return true;
            case Tk.TOKEN_LSHIFT: *out = a << b; return true;
            default: return false;
        }
    }
    return false;
}
// `[v; n]`: fill a stack array in place (a loop for large n); returns the slot
fn Vx Low.repeat_slot(Low* lw, Node* n, AirTyp* want, AirTyp** aty)
{
    long cnt = 0;
    if (n.child_count < 2 || !lw.const_int(n.children[1], &cnt) || cnt < 0) { lw.err(n, "array repeat count must be a constant", null); return lw.unit(); }
    AirTyp* el = (want != null && want.tag == ATYP_ARRAY) ? want.args[0] : null;
    Vx v = lw.expr(n.children[0], el);
    if (el == null) { el = v.t; } else { v = lw.coerce_arg(n.children[0], v, el); }
    if (!lw.live() || el == null) { return lw.unit(); }
    AirTyp* at = air_ir::air_mk_typ_array(lw.a, el, cnt);
    *aty = at;
    Vx slot = lw.alloca_(at);
    if (cnt == 0) { return slot; }
    Vx ix = lw.alloca_(lw.m.t_i64); lw.store(ix.p, lw.lit_int(0, lw.m.t_i64));
    usz head = lw.blk("rep.head"); usz body = lw.blk("rep.body"); usz exit = lw.blk("rep.exit");
    lw.t_jump0(head); lw.cur = head;
    Vx i = lw.load(ix.p, lw.m.t_i64);
    Vx more = lw.binop(ABIN_LT, i, lw.lit_int(cnt, lw.m.t_i64));
    lw.t_cond(more, body, exit);
    lw.cur = body;
    Vx[2] gi; gi[0] = lw.lit_int(0, lw.m.t_i64); gi[1] = i;
    Vx ep = lw.gep(slot.p, at, &gi[0], 2, el);
    lw.store(ep.p, v);
    lw.store(ix.p, lw.binop(ABIN_ADD, i, lw.lit_int(1, lw.m.t_i64)));
    lw.t_jump0(head);
    lw.cur = exit;
    return slot;
}
fn Vx Low.array_lit(Low* lw, Node* n, AirTyp* want)
{
    if (n.p.aux == 8)   // the repeat form
    {
        AirTyp* rat = null; Vx sl = lw.repeat_slot(n, want, &rat);
        if (!lw.live() || rat == null) { return lw.unit(); }
        if (rat.ival > 64) { lw.err(n, "array value with more than 64 elements: bind it with `let` (it is filled in place)", null); return lw.unit(); }
        Vx lv = lw.load(sl.p, rat);
        AirTyp* wf = (want != null && want.tag != ATYP_ARRAY) ? lw.fat_elem(want) : null;
        if (wf != null && !lw.is_str_t(want)) { return lw.array_to_slice(lv, want); }
        return lv;
    }
    AirTyp* el = null; AirTyp* sl = null;
    if (want != null && want.tag == ATYP_ARRAY) { el = want.args[0]; }
    else if (want != null) { AirTyp* fe = lw.fat_elem(want); if (fe != null && !lw.is_str_t(want)) { el = fe; sl = want; } }
    Vx[64] vs; usz cnt = 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        if (cnt >= 64) { lw.unsup(n, "array literal with more than 64 elements"); return lw.unit(); }
        Vx v = lw.expr(n.children[i], el);
        if (el == null) { el = v.t; }
        if (el != null) { v = lw.coerce_arg(n.children[i], v, el); }
        vs[cnt] = v; cnt++;
    }
    if (el == null) { lw.err(n, "empty array literal without a known element type", null); return lw.unit(); }
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_ARRAY;
    for (usz i = 0; i < cnt; i++) { p.add_sub(vs[i].p); }
    AirTyp* at = air_ir::air_mk_typ_array(lw.a, el, (long)cnt);
    Vx v = lw.let_(p, at, "_arr");
    if (sl != null) { return lw.array_to_slice(v, sl); }
    return v;
}
fn bool Low.is_str_t(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return false; }
    for (usz i = 0; i < lw.nfat; i++) { if (lw.fats[i].is_str && seq(lw.fats[i].ty.name, t.name)) { return true; } }
    return false;
}



// ── untagged unions ───────────────────────────────────────────────────────
fn AirTyp* Low.union_ty(Low* lw, Node* decl)
{
    for (usz i = 0; i < lw.nuni; i++) { if (lw.unis[i].decl == decl) { return lw.unis[i].ty; } }
    if (lw.nuni >= 32) { lw.unsup(decl, "more than 32 union types"); return null; }
    UniI* u = &lw.unis[lw.nuni]; lw.nuni++;
    u.decl = decl; u.nf = 0; u.words = 1;
    char* base = lw.dname(decl); if (base == null) { base = "Union"; }
    char* nm = lw.dup(base); int k = 1;
    while (true)
    {
        bool clash = false;
        for (usz i = 0; i + 1 < lw.nuni; i++) { if (seq(lw.unis[i].ty.name, nm)) { clash = true; } }
        for (usz i = 0; i < lw.nst; i++) { if (seq(lw.sts[i].name, nm)) { clash = true; } }
        for (usz i = 0; i < lw.nen; i++) { if (seq(lw.ens[i].name, nm)) { clash = true; } }
        if (!clash) { break; }
        char[160] b; k++; snprintf(&b[0], 160, "%s.%d", base, k); nm = lw.dup(&b[0]);
    }
    u.ty = lw.nominal(nm);
    for (usz i = 0; i < decl.child_count; i++)
    {
        Node* f = decl.children[i]; if (f == null || f.kind != Nk.N_DECL_FIELD || u.nf >= 8) { continue; }
        AirTyp* ft = lw.ty(f.type_ann); if (ft == null) { return null; }
        u.fnames[u.nf] = lw.dup(lw.text(f)); u.ft[u.nf] = ft; u.nf++;
        usz w = lw.words(ft); if (w > u.words) { u.words = w; }
    }
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, nm);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, nm);
    c.result_ty = u.ty; d.add_ctor(c);
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("bits"), air_ir::air_mk_typ_array(lw.a, lw.m.t_i64, (long)u.words), AMULT_UNR));
    lw.m.add_decl(d);
    return u.ty;
}
fn UniI* Low.uni_of(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.nuni; i++) { if (seq(lw.unis[i].ty.name, t.name)) { return &lw.unis[i]; } }
    return null;
}
fn AirTyp* Low.uni_field(Low* lw, UniI* u, char* f)
{
    if (f == null) { return null; }
    for (usz i = 0; i < u.nf; i++) { if (seq(u.fnames[i], f)) { return u.ft[i]; } }
    return null;
}
fn Vx Low.union_lit(Low* lw, Node* n, Node* r)
{
    AirTyp* ut = lw.union_ty(r); UniI* u = lw.uni_of(ut);
    if (ut == null || u == null) { return lw.unit(); }
    Vx slot = lw.alloca_(ut);
    // zero the whole block first: bytes outside the written field are defined
    AirPrd* z = air_ir::air_new_AirPrd(lw.a); z.tag = APRD_ARRAY;
    for (usz i = 0; i < u.words; i++) { AirPrd* zi = air_ir::air_mk_int(lw.a, 0); zi.ty = lw.m.t_i64; z.add_sub(zi); }
    Vx zv = lw.let_(z, air_ir::air_mk_typ_array(lw.a, lw.m.t_i64, (long)u.words), "_z");
    Vx zr; AirPrd* rec = air_ir::air_new_AirPrd(lw.a); rec.tag = APRD_RECORD;
    AirFieldInit* f0 = air_ir::air_new_AirFieldInit(lw.a); f0.name = lw.dup("bits"); f0.value = zv.p; rec.rec_inits[0] = f0; rec.rec_init_count = 1;
    zr = lw.let_(rec, ut, "_u0");
    lw.store(slot.p, zr);
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* fi = n.children[i]; if (fi == null || fi.kind != Nk.N_EXPR_FIELD_INIT || fi.child_count == 0) { continue; }
        char* fnm = lw.text(fi); AirTyp* ft = lw.uni_field(u, fnm);
        if (ft == null) { lw.err(fi, "field is not declared", fnm); return lw.unit(); }
        Vx v = lw.expr(fi.children[0], ft); v = lw.coerce_arg(fi, v, ft);
        Vx pp = lw.coerce(slot, lw.ptr(ft));
        lw.store(pp.p, v);
    }
    return lw.load(slot.p, ut);
}

// ── enums ─────────────────────────────────────────────────────────────────
fn char* Low.dname(Low* lw, Node* n)   // a declaration's own name (variants: the first child is a payload TYPE)
{
    if (n != null && lw.it != null && n.name_id != 0) { char* t = lw.it.text(n.name_id); if (t != null && t[0] != 0) { return t; } }
    return lw.text(n);
}
// 8-byte words a value of this type occupies inside an enum payload (an over-approximation, never less than its size)
fn usz Low.words(Low* lw, AirTyp* t)
{
    if (t == null) { return 1; }
    switch (t.tag)
    {
        case ATYP_UNIT: return 0;
        case ATYP_ARRAY: return (usz)t.ival * lw.words(t.args[0]);
        case ATYP_TUPLE: { usz w = 0; for (usz i = 0; i < t.arg_count; i++) { w += lw.words(t.args[i]); } return w; }
        case ATYP_NOMINAL:
        {
            AirDecl* d = lw.data_of(t);
            if (d == null || d.ctor_count == 0) { return 1; }
            usz w = 0; AirCtorDecl* c = d.ctors[0];
            for (usz i = 0; i < c.field_count; i++) { w += lw.words(c.fields[i].ty); }
            return w;
        }
        default:
            if (air_ll::ty_is_int(t) && air_ll::ty_bits(t) > 64) { return (usz)((air_ll::ty_bits(t) + 63) / 64); }
            return 1;
    }
}
fn Enm* Low.enum_for(Low* lw, Node* decl)
{
    for (usz i = 0; i < lw.nen; i++) { if (lw.ens[i].decl == decl) { return &lw.ens[i]; } }
    if (lw.nen >= 64) { lw.unsup(decl, "more than 64 enum types"); return null; }
    Enm* e = &lw.ens[lw.nen]; lw.nen++;
    e.decl = decl; e.nv = 0; e.words = 1; e.nm = 0;
    char* base = lw.dname(decl); if (base == null) { base = "Enum"; }
    char* nm = lw.dup(base); int k = 1;
    while (true)
    {
        bool clash = false;
        for (usz i = 0; i + 1 < lw.nen; i++) { if (seq(lw.ens[i].name, nm)) { clash = true; } }
        for (usz i = 0; i < lw.nst; i++) { if (seq(lw.sts[i].name, nm)) { clash = true; } }
        if (!clash) { break; }
        char[160] b; k++; snprintf(&b[0], 160, "%s.%d", base, k); nm = lw.dup(&b[0]);
    }
    e.name = nm; e.ty = lw.nominal(nm);
    for (usz i = 0; i < decl.child_count; i++)
    {
        Node* vn = decl.children[i];
        if (vn == null || vn.kind != Nk.N_DECL_VARIANT) { continue; }
        if (e.nv >= 32) { lw.unsup(decl, "enum with more than 32 variants"); return null; }
        VarI* vi = &e.v[e.nv]; e.nv++;
        vi.name = lw.dname(vn); vi.decl = vn; vi.nf = 0;
        usz off = 0;
        for (usz j = 0; j < vn.child_count; j++)
        {
            Node* tn = vn.children[j]; if (tn == null || !pfront_core::is_type(tn.kind)) { continue; }
            if (vi.nf >= 8) { lw.unsup(vn, "variant with more than 8 payload fields"); return null; }
            AirTyp* ft = lw.ty(tn); if (ft == null) { return null; }
            vi.ft[vi.nf] = ft; vi.off[vi.nf] = off; vi.nf++;
            off += lw.words(ft);
        }
        if (off > e.words) { e.words = off; }
    }
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, nm);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, nm);
    c.result_ty = e.ty; d.add_ctor(c);
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("tag"), lw.m.t_i64, AMULT_UNR));
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("payload"), air_ir::air_mk_typ_array(lw.a, lw.m.t_i64, (long)e.words), AMULT_UNR));
    lw.m.add_decl(d);
    return e;
}
fn Enm* Low.enum_of_ty(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.nen; i++) { if (seq(lw.ens[i].name, t.name)) { return &lw.ens[i]; } }
    return null;
}
fn long Low.variant_index(Low* lw, Enm* e, char* name, Node* decl)
{
    for (usz i = 0; i < e.nv; i++) { if ((decl != null && e.v[i].decl == decl) || (name != null && seq(e.v[i].name, name))) { return (long)i; } }
    return -1;
}
// typed pointer to payload field `i` of variant `vi` inside the enum stored at `slot`
fn Vx Low.payload_ptr(Low* lw, Vx slot, Enm* e, usz vi, usz i)
{
    Vx[3] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int(1, lw.m.t_i32); ix[2] = lw.lit_int((long)e.v[vi].off[i], lw.m.t_i64);
    Vx g = lw.gep(slot.p, e.ty, &ix[0], 3, lw.m.t_i64);
    return lw.coerce(g, lw.ptr(e.v[vi].ft[i]));
}
fn Vx Low.variant_value(Low* lw, Enm* e, usz vi, Node** argn, usz na, Node* at)
{
    VarI* v = &e.v[vi];
    if (na != v.nf) { lw.err(at, "wrong number of payload values for the variant", v.name); return lw.unit(); }
    Vx[8] av;
    for (usz i = 0; i < na; i++) { av[i] = lw.expr(argn[i], v.ft[i]); av[i] = lw.coerce_arg(argn[i], av[i], v.ft[i]); }
    return lw.variant_pack(e, vi, &av[0], na);
}
fn Vx Low.variant_pack(Low* lw, Enm* e, usz vi, Vx* av, usz na)
{
    VarI* v = &e.v[vi];
    if (!lw.live()) { return lw.unit(); }
    Vx slot = lw.alloca_(e.ty);
    Vx[2] ti; ti[0] = lw.lit_int(0, lw.m.t_i64); ti[1] = lw.lit_int(0, lw.m.t_i32);
    Vx tg = lw.gep(slot.p, e.ty, &ti[0], 2, lw.m.t_i64);
    lw.store(tg.p, lw.lit_int((long)vi, lw.m.t_i64));
    for (usz i = 0; i < na; i++)
    {
        if (lw.is_unit_t(v.ft[i])) { continue; }
        Vx pp = lw.payload_ptr(slot, e, vi, i);
        lw.store(pp.p, av[i]);
    }
    return lw.load(slot.p, e.ty);
}
// ── set-theoretic unions: a tagged record over the member types ──
fn void Low.flatten_union(Low* lw, Node* t, AirTyp** out, usz* n, bool inter)
{
    if (t == null) { return; }
    if ((!inter && t.kind == Nk.N_TY_UNION) || (inter && t.kind == Nk.N_TY_INTERSECT))
    {
        for (usz i = 0; i < t.child_count; i++) { lw.flatten_union(t.children[i], out, n, inter); }
        return;
    }
    if (t.kind == Nk.N_TY_NAME && t.resolved != null && t.resolved.kind == Nk.N_DECL_TYPE && t.resolved.type_ann != null
        && ((!inter && t.resolved.type_ann.kind == Nk.N_TY_UNION) || (inter && t.resolved.type_ann.kind == Nk.N_TY_INTERSECT)))
    { lw.flatten_union(t.resolved.type_ann, out, n, inter); return; }
    AirTyp* m = lw.ty(t); if (m == null) { return; }
    for (usz i = 0; i < *n; i++) { if (air_ll::ty_eq(out[i], m)) { return; } }
    if (*n < 8) { out[*n] = m; *n = *n + 1; }
}
fn AirTyp* Low.union_enum_ty(Low* lw, AirTyp** ms, usz nm)
{
    for (usz i = 0; i < lw.nen; i++)
    {
        Enm* e = &lw.ens[i]; if (e.nm != nm) { continue; }
        bool same = true;
        for (usz j = 0; j < nm; j++) { if (!air_ll::ty_eq(e.um[j], ms[j])) { same = false; } }
        if (same) { return e.ty; }
    }
    if (lw.nen >= 64) { lw.unsup(null, "more than 64 enum/union types"); return null; }
    Enm* e = &lw.ens[lw.nen]; lw.nen++;
    e.decl = null; e.nv = 0; e.words = 1; e.nm = nm;
    char[300] bb; usz bn = (usz)snprintf(&bb[0], 300, "Union");
    for (usz j = 0; j < nm; j++) { bn += (usz)snprintf(&bb[0] + bn, (usz)(300 - bn), "."); bn = mang(ms[j], &bb[0], bn, 300); }
    e.name = lw.dup(&bb[0]); e.ty = lw.nominal(e.name);
    for (usz j = 0; j < nm; j++)
    {
        e.um[j] = ms[j];
        VarI* vi = &e.v[e.nv]; e.nv++;
        char[16] vn; snprintf(&vn[0], 16, "m%d", (int)j);
        vi.name = lw.dup(&vn[0]); vi.decl = null; vi.nf = 1; vi.ft[0] = ms[j]; vi.off[0] = 0;
        usz w = lw.words(ms[j]); if (w > e.words) { e.words = w; }
    }
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, e.name);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, e.name);
    c.result_ty = e.ty; d.add_ctor(c);
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("tag"), lw.m.t_i64, AMULT_UNR));
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("payload"), air_ir::air_mk_typ_array(lw.a, lw.m.t_i64, (long)e.words), AMULT_UNR));
    lw.m.add_decl(d);
    return e.ty;
}
// `u as T` for a union `u`: switch on the tag, convert the active member, join
fn Vx Low.union_cast(Low* lw, Vx u, AirTyp* to, Enm* e)
{
    if (!lw.live()) { return lw.unit(); }
    Vx slot = lw.alloca_(e.ty); lw.store(slot.p, u);
    Vx tag = lw.field_of(u, "tag", 0, lw.m.t_i64);
    usz jb = lw.blk("ucast.join"); char* pn = lw.fresh("_uc");
    lw.blks[jb].pnames[0] = pn; lw.blks[jb].ptys[0] = to; lw.blks[jb].np = 1;
    for (usz i = 0; i < e.nv; i++)
    {
        usz arm = lw.blk("ucast.arm"); usz nxt = lw.blk("ucast.next");
        Vx eq = lw.binop(ABIN_EQ, tag, lw.lit_int((long)i, lw.m.t_i64));
        lw.t_cond(eq, arm, nxt);
        lw.cur = arm;
        Vx pp = lw.payload_ptr(slot, e, i, 0);
        Vx val = lw.load(pp.p, e.v[i].ft[0]);
        Vx cv = lw.cast(val, to);
        Vx[1] ja; ja[0] = cv; lw.t_jump(jb, &ja[0], 1);
        lw.cur = nxt;
    }
    lw.t_end(T_TRAP);
    lw.cur = jb;
    return lw.vref(pn, to);
}
// `E.V` / `E.V(args)`: the base names an enum
fn Enm* Low.enum_ctor_base(Low* lw, Node* base, char* name, long* vi)
{
    if (base == null || base.resolved == null || base.resolved.kind != Nk.N_DECL_ENUM) { return null; }
    Enm* e = lw.enum_for(base.resolved); if (e == null) { return null; }
    long k = lw.variant_index(e, name, null);
    if (k < 0) { return null; }
    *vi = k; return e;
}
// pattern on an enum scrutinee: test the tag, then match the payload fields
fn bool Low.pat_variant(Low* lw, Enm* e, usz vi, Node** subs, usz nsub, Vx v, usz fail)
{
    Vx tag = lw.field_of(v, "tag", 0, lw.m.t_i64);
    Vx eq = lw.binop(ABIN_EQ, tag, lw.lit_int((long)vi, lw.m.t_i64));
    usz ok = lw.blk("pat.ok");
    lw.t_cond(eq, ok, fail); lw.cur = ok;
    if (nsub == 0) { return true; }
    VarI* vr = &e.v[vi];
    Vx slot = lw.alloca_(e.ty);
    lw.store(slot.p, v);
    for (usz i = 0; i < nsub && i < vr.nf; i++)
    {
        Vx pp = lw.payload_ptr(slot, e, vi, i);
        Vx val = lw.load(pp.p, vr.ft[i]);
        if (!lw.pat(subs[i], val, fail)) { return false; }
    }
    return true;
}

// ── expressions ────────────────────────────────────────────────────────────
fn bool Low.is_unit_t(Low* lw, AirTyp* t) { return t != null && t.tag == ATYP_UNIT; }

// the AirTyp of the element an `alloc` produces; count (when not constant) is lowered by the caller
fn AirTyp* Low.alloc_elem(Low* lw, Node* n, Node** count)
{
    Node* t = n.type_ann != null ? n.type_ann : (n.child_count > 0 ? n.children[0] : null);
    if (t == null) { return null; }
    if (t.kind == Nk.N_TY_ARRAY && t.child_count >= 2)
    {
        if (count != null) { *count = t.children[1]; }
        return lw.ty(t.children[0]);
    }
    if (pfront_core::is_type(t.kind)) { return lw.ty(t); }
    if (t.kind == Nk.N_EXPR_IDENT && t.resolved != null && t.resolved.kind == Nk.N_DECL_STRUCT) { return lw.struct_ty(t.resolved); }   // `alloc Grid`
    return null;
}

fn Vx Low.lit(Low* lw, Node* n, AirTyp* want)
{
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        {
            if (want != null && want.tag == ATYP_PTR && n.p.ival == 0)   // a bare `0` where a pointer is wanted is null
            { AirPrd* zp = air_ir::air_mk_prd_null(lw.a); zp.ty = want; Vx zr; zr.p = zp; zr.t = want; return zr; }
            AirTyp* t = want;
            if (t == null || !(air_ll::ty_is_int(t) || air_ll::ty_is_float(t)))
            {
                t = lw.m.t_i64;
                AirTyp* a = n.type_ann != null ? lw.ty_quiet(n.type_ann) : null;
                if (a != null && air_ll::ty_is_int(a)) { t = a; }
            }
            if (n.p.width != 0 && !(n.p.aux == 99 && n.p.width == 64 && n.p.is_signed))   // an explicit suffix (`5u8`, `0xFFu32`) is the literal's type
            {
                char[16] sb; snprintf(&sb[0], 16, "%c%d", n.p.is_signed ? 'i' : 'u', (int)n.p.width);
                AirTyp* st = air_types::air_prim_ty(lw.m, &sb[0]);
                if (st != null && air_ll::ty_is_int(st)) { t = st; }
            }
            if (air_ll::ty_is_float(t))
            {
                AirPrd* f = air_ir::air_mk_float(lw.a, (double)(long)n.p.ival); f.ty = t; Vx r; r.p = f; r.t = t; return r;
            }
            return lw.lit_int((long)n.p.ival, t);
        }
        case Nk.N_EXPR_FLOAT:
        {
            AirTyp* t = (want != null && air_ll::ty_is_float(want)) ? want : lw.m.t_f64;
            AirPrd* f = air_ir::air_mk_float(lw.a, n.p.fval); f.ty = t; Vx r; r.p = f; r.t = t; return r;
        }
        case Nk.N_EXPR_BOOL: return lw.lit_bool(n.p.ival != 0);
        case Nk.N_EXPR_CHAR: { AirTyp* t = (want != null && air_ll::ty_is_int(want)) ? want : lw.m.t_char; return lw.lit_int((long)n.p.ival, t); }
        case Nk.N_EXPR_UNIT: return lw.unit();
        case Nk.N_EXPR_NULL:
        {
            AirTyp* t = (want != null && want.tag == ATYP_PTR) ? want : lw.ptr(lw.m.t_u8);
            AirPrd* p = air_ir::air_mk_prd_null(lw.a); p.ty = t; Vx r; r.p = p; r.t = t; return r;
        }
        case Nk.N_EXPR_STRING: case Nk.N_EXPR_BYTES:
        {
            usz sl = n.p.sptr == null ? 0 : (usz)n.p.slen;
            char* tmp = lw.a.dup(n.p.sptr == null ? (char*)"" : n.p.sptr, sl);
            usz dl = sl == 0 ? 0 : air_lower::lit_decode(n.p.sptr, sl, tmp);
            AirPrd* p = n.kind == Nk.N_EXPR_BYTES ? air_ir::air_mk_bytes(lw.a, tmp, dl) : air_ir::air_mk_str(lw.a, tmp, dl);
            Vx r; r.p = p; r.t = lw.ptr(lw.m.t_u8); p.ty = r.t;
            if (n.kind == Nk.N_EXPR_STRING && want != null && lw.is_str_t(want)) { return lw.mk_fat(want, r, lw.lit_int((long)dl, lw.m.t_i64)); }   // str = { ptr, len }
            return r;
        }
        default: break;
    }
    return lw.unit();
}
// translate a type but do not report an unsupported one (hints only)
fn AirTyp* Low.ty_quiet(Low* lw, Node* t)
{
    int e0 = lw.errors; int f0 = lw.fn_errors;
    AirTyp* r = lw.ty(t);
    lw.errors = e0; lw.fn_errors = f0;
    return r;
}

fn VarB* Low.find_var_named(Low* lw, Node* id)
{
    char* nm = lw.text(id);
    if (nm == null) { return null; }
    for (usz i = lw.nvars; i > 0; i--)
    {
        char* vn = lw.text(lw.vars[i - 1].decl);
        if (vn != null && seq(vn, nm)) { return &lw.vars[i - 1]; }
    }
    return null;
}
fn Vx Low.read_var(Low* lw, Node* id)
{
    Node* r = id.resolved;
    VarB* v = lw.find_var(r);
    if (v == null && r == null) { v = lw.find_var_named(id); }   // names inside type positions (`[u8; n + 1]`) are not resolved by the front end
    if (v != null)
    {
        if (v.slot) { return lw.load(v.p, v.t); }
        Vx x; x.p = v.p; x.t = v.t; return x;
    }
    if (r != null && (r.kind == Nk.N_DECL_FN || r.kind == Nk.N_DECL_EXTERN_FN))
    {
        FnInfo* f = lw.fn_for(r);
        if (f == null) { return lw.unit(); }
        lw.queue(f);
        Vx x; x.p = air_ir::air_mk_var(lw.a, f.name); x.t = f.fnty; return x;
    }
    if (r != null && r.kind == Nk.N_DECL_CONST)
    {
        Node* init = null;
        for (usz i = 0; i < r.child_count; i++) { Node* c = r.children[i]; if (c != null && pfront_core::is_expr(c.kind)) { init = c; } }
        if (init != null) { return lw.expr(init, r.type_ann != null ? lw.ty_quiet(r.type_ann) : null); }
    }
    if (r != null && (r.kind == Nk.N_DECL_STATIC || r.kind == Nk.N_DECL_LET))   // a top-level `let` is a global
    {
        GlInfo* g = lw.global_for(r);
        if (g == null) { return lw.unit(); }
        return lw.load(air_ir::air_mk_var(lw.a, g.name), g.ty);
    }
    lw.err(id, "name does not resolve to a local, function or global", lw.text(id));
    return lw.unit();
}
// the module an identifier names: resolved to one, or (the front end lets a same-named fn shadow it) looked up by name
fn bool Low.dotted_of(Low* lw, Node* b, char* buf, usz cap, usz* len)   // `a.b.c` made only of identifiers and field accesses
{
    if (b == null) { return false; }
    if (b.kind == Nk.N_EXPR_FIELD && b.child_count == 1) { if (!lw.dotted_of(b.children[0], buf, cap, len)) { return false; } }
    else if (b.kind != Nk.N_EXPR_IDENT) { return false; }
    char* nm = lw.dname(b); if (nm == null) { return false; }
    usz k = 0; while (nm[k] != 0) { k++; }
    if (*len + k + 2 >= cap) { return false; }
    if (*len > 0) { buf[*len] = '.'; (*len)++; }
    for (usz i = 0; i < k; i++) { buf[*len + i] = nm[i]; }
    *len += k; buf[*len] = 0; return true;
}
fn Node* Low.mod_of_ident(Low* lw, Node* b)
{
    if (b != null && b.kind == Nk.N_EXPR_FIELD)
    {
        char[200] pb; usz pl = 0;
        if (!lw.dotted_of(b, &pb[0], 200, &pl)) { return null; }
        return lw.module_root(&pb[0]);
    }
    if (b == null || b.kind != Nk.N_EXPR_IDENT) { return null; }
    Node* m = b.resolved;
    if (m != null && (m.kind == Nk.N_PROGRAM || m.kind == Nk.N_MODULE)) { return m; }
    if (m == null || m.kind == Nk.N_DECL_FN || m.kind == Nk.N_DECL_EXTERN_FN)
    {
        char* t = lw.dname(b); if (t == null) { return null; }
        return lw.module_root(t);
    }
    return null;
}
fn Node* Low.mod_member(Low* lw, Node* m, char* fnm, bool fns_only)
{
    for (usz i = 0; i < m.child_count; i++)
    {
        Node* d = m.children[i]; if (d == null) { continue; }
        bool isfn = d.kind == Nk.N_DECL_FN || d.kind == Nk.N_DECL_EXTERN_FN;
        if (!isfn && (fns_only || (d.kind != Nk.N_DECL_CONST && d.kind != Nk.N_DECL_STATIC && d.kind != Nk.N_DECL_LET))) { continue; }
        char* dn = lw.dname(d);
        if (dn != null && seq(dn, fnm)) { return d; }
    }
    return null;
}
// `mod.NAME` where `mod` is a module: rewrite the field access into a plain reference to the member declaration;
// `mod.f(args)` the front end could not resolve gets its callee
fn void Low.norm_modfields(Low* lw, Node* n, usz depth)
{
    if (n == null || depth > 400) { return; }
    for (usz i = 0; i < n.child_count; i++) { lw.norm_modfields(n.children[i], depth + 1); }
    if (n.child_count == 0 || n.children[0] == null) { return; }
    if (n.kind == Nk.N_EXPR_FIELD && n.child_count == 1)
    {
        Node* m = lw.mod_of_ident(n.children[0]); if (m == null) { return; }
        char* fnm = lw.dname(n); if (fnm == null) { return; }
        Node* d = lw.mod_member(m, fnm, false);
        if (d != null) { n.kind = Nk.N_EXPR_IDENT; n.resolved = d; n.child_count = 0; }
    }
    else if (n.kind == Nk.N_EXPR_METHOD && n.resolved == null)
    {
        Node* m = lw.mod_of_ident(n.children[0]); if (m == null) { return; }
        char* fnm = lw.dname(n); if (fnm == null) { return; }
        Node* d = lw.mod_member(m, fnm, true);
        if (d != null) { n.resolved = d; }
    }
}
// dotted module path of a `ty-path` (`str.string.String` -> prefix "str.string", last "String")
fn bool Low.tpath_flat(Low* lw, Node* t, char* buf, usz cap, usz* len, bool* last_seg)
{
    if (t == null) { return false; }
    if (t.kind == Nk.N_TY_NAME || t.kind == Nk.N_PATH_SEG)
    {
        char* nm = lw.dname(t); if (nm == null) { return false; }
        usz k = 0; while (nm[k] != 0) { k++; }
        if (*len + k + 2 >= cap) { return false; }
        if (*len > 0) { buf[*len] = '.'; (*len)++; }
        for (usz i = 0; i < k; i++) { buf[*len + i] = nm[i]; }
        *len += k; buf[*len] = 0; return true;
    }
    if (t.kind == Nk.N_TY_PATH)
    {
        for (usz i = 0; i < t.child_count; i++) { if (!lw.tpath_flat(t.children[i], buf, cap, len, last_seg)) { return false; } }
        return true;
    }
    return false;
}
fn Node* Low.module_root(Low* lw, char* dotted)
{
    usz dl = 0; while (dotted[dl] != 0) { dl++; }
    for (usz r = 0; r < lw.nroots; r++)
    {
        Node* root = lw.roots[r]; if (root == null) { continue; }
        for (usz i = 0; i < root.child_count; i++)
        {
            Node* c = root.children[i];
            if (c == null || c.kind != Nk.N_MODULE) { continue; }
            char* mn = lw.dname(c); if (mn == null) { break; }
            usz ml = 0; while (mn[ml] != 0) { ml++; }
            if (ml == dl && seq(mn, dotted)) { return root; }
            if (ml > dl && mn[ml - dl - 1] == '.' && seq(mn + (ml - dl), dotted)) { return root; }
            break;
        }
    }
    return null;
}
fn Node* Low.resolve_tpath(Low* lw, Node* t)
{
    if (t == null || t.kind != Nk.N_TY_PATH || t.child_count < 2) { return null; }
    Node* lastseg = t.children[t.child_count - 1];
    char* ln = lw.dname(lastseg); if (ln == null) { return null; }
    char[200] buf; usz len = 0; bool ls = false;
    if (!lw.tpath_flat(t.children[0], &buf[0], 200, &len, &ls)) { return null; }
    for (usz i = 1; i + 1 < t.child_count; i++) { if (!lw.tpath_flat(t.children[i], &buf[0], 200, &len, &ls)) { return null; } }
    Node* root = lw.module_root(&buf[0]); if (root == null) { return null; }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* d = root.children[i]; if (d == null) { continue; }
        if (d.kind != Nk.N_DECL_STRUCT && d.kind != Nk.N_DECL_UNION && d.kind != Nk.N_DECL_ENUM && d.kind != Nk.N_DECL_TYPE) { continue; }
        char* dn = lw.dname(d); if (dn != null && seq(dn, ln)) { return d; }
    }
    return null;
}
fn void Low.queue(Low* lw, FnInfo* f) { if (!f.seen) { f.seen = true; f.queued = true; } }

// places: an address plus the type stored there
fn bool Low.place(Low* lw, Node* n, Pl* out)
{
    switch (n.kind)
    {
        case Nk.N_EXPR_IDENT:
        {
            Node* r = n.resolved;
            VarB* v = lw.find_var(r);
            if (v != null && v.slot) { out.ptr = v.p; out.t = v.t; return true; }
            if (r != null && (r.kind == Nk.N_DECL_STATIC || r.kind == Nk.N_DECL_LET))
            {
                GlInfo* g = lw.global_for(r); if (g == null) { return false; }
                out.ptr = air_ir::air_mk_var(lw.a, g.name); out.t = g.ty; return true;
            }
            return false;
        }
        case Nk.N_EXPR_DEREF:
        {
            Vx p = lw.expr(n.children[0], null);
            AirTyp* e = lw.pointee(p.t);
            if (e == null) { lw.err(n, "dereference of a non-pointer", null); return false; }
            out.ptr = p.p; out.t = e; return true;
        }
        case Nk.N_EXPR_INDEX:
        {
            if (n.child_count < 2) { return false; }
            AirTyp* bt = lw.hint(n.children[0]);
            Vx i = lw.expr(n.children[1], lw.m.t_i64);
            if (bt != null && bt.tag == ATYP_ARRAY)
            {
                Pl bp;
                if (!lw.place(n.children[0], &bp))   // an array held as a value (a by-value parameter): spill it so it can be indexed by address
                {
                    Vx bv = lw.expr(n.children[0], bt); if (!lw.live()) { return false; }
                    Vx sl = lw.alloca_(bt); lw.store(sl.p, bv);
                    bp.ptr = sl.p; bp.t = bt;
                }
                Vx z = lw.lit_int(0, lw.m.t_i64); Vx[2] ix; ix[0] = z; ix[1] = lw.coerce(i, lw.m.t_i64);
                if (!(i.p != null && i.p.tag == APRD_INT && i.p.ival >= 0 && i.p.ival < bt.ival)) { lw.bounds(ix[1], lw.lit_int(bt.ival, lw.m.t_i64)); }
                Vx g = lw.gep(bp.ptr, bp.t, &ix[0], 2, bt.args[0]);
                out.ptr = g.p; out.t = bt.args[0]; return true;
            }
            AirTyp* se = lw.fat_elem(bt);
            if (se != null)
            {
                Vx sv = lw.expr(n.children[0], null);
                Vx sp = lw.field_of(sv, "ptr", 0, lw.ptr(se)); Vx sn = lw.field_of(sv, "len", 1, lw.m.t_i64);
                Vx ii = lw.coerce(i, lw.m.t_i64);
                lw.bounds(ii, sn);
                Vx[1] ix1; ix1[0] = ii;
                Vx g = lw.gep(sp.p, se, &ix1[0], 1, se);
                out.ptr = g.p; out.t = se; return true;
            }
            Vx b = lw.expr(n.children[0], null);
            AirTyp* e = lw.pointee(b.t);
            if (e == null) { lw.err(n, "indexing a value that is neither a pointer, an array nor a slice", null); return false; }
            Vx[1] ix; ix[0] = i.t != null && air_ll::ty_is_int(i.t) ? i : lw.coerce(i, lw.m.t_i64);
            Vx g = lw.gep(b.p, e, &ix[0], 1, e);
            out.ptr = g.p; out.t = e; return true;
        }
        case Nk.N_EXPR_FIELD:
        {
            AirTyp* bt = lw.hint(n.children[0]);
            char* f = lw.text(n); long k = -1;
            if (bt == null || f == null) { return false; }
            {   // a union field is a typed view of offset 0
                AirTyp* ubt = bt.tag == ATYP_PTR ? bt.args[0] : bt;
                UniI* un = lw.uni_of(ubt);
                if (un != null)
                {
                    AirTyp* uft = lw.uni_field(un, f);
                    if (uft == null) { lw.err(n, "field is not declared", f); return false; }
                    AirPrd* base = null;
                    if (bt.tag == ATYP_PTR) { Vx bv = lw.expr(n.children[0], null); base = bv.p; }
                    else
                    {
                        Pl ub;
                        if (lw.place(n.children[0], &ub)) { base = ub.ptr; }
                        else { Vx bv = lw.expr(n.children[0], null); Vx sl = lw.alloca_(bv.t); lw.store(sl.p, bv); base = sl.p; }
                    }
                    Vx bp; bp.p = base; bp.t = lw.ptr(ubt);
                    Vx pp = lw.coerce(bp, lw.ptr(uft));
                    out.ptr = pp.p; out.t = uft; return true;
                }
            }
            if (bt.tag == ATYP_PTR)
            {
                AirTyp* st = bt.args[0]; AirTyp* ft = lw.field_ty(st, f, &k);
                if (ft == null) { lw.err(n, "field is not declared", f); return false; }
                Vx b = lw.expr(n.children[0], null);
                Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int(k, lw.m.t_i32);
                Vx g = lw.gep(b.p, st, &ix[0], 2, ft);
                out.ptr = g.p; out.t = ft; return true;
            }
            AirTyp* ft = lw.field_ty(bt, f, &k);
            if (ft == null) { return false; }
            Pl bp;
            if (!lw.place(n.children[0], &bp)) { return false; }
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int(k, lw.m.t_i32);
            Vx g = lw.gep(bp.ptr, bt, &ix[0], 2, ft);
            out.ptr = g.p; out.t = ft; return true;
        }
        default: return false;
    }
}

// theory rewrites (IRDL rule right-hand sides) build new call nodes whose callee identifier is not resolved: find the
// function by name in the program (the entry module first)
// A constant initialiser for a global, as a pure predicate tree (no instructions): scalar literals,
// null, string literals, and struct / tuple / array literals of constants.  null = not a constant.
fn AirPrd* Low.const_init(Low* lw, Node* e, AirTyp* t)
{
    if (e == null || t == null) { return null; }
    switch (e.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR: case Nk.N_EXPR_NULL: case Nk.N_EXPR_STRING: case Nk.N_EXPR_BYTES:
        {
            if (e.kind == Nk.N_EXPR_INT && t.tag == ATYP_PTR && e.p.ival != 0) { return null; }
            if (e.kind == Nk.N_EXPR_INT && t.tag == ATYP_PTR) { AirPrd* z = air_ir::air_mk_prd_null(lw.a); z.ty = t; return z; }
            if (e.kind == Nk.N_EXPR_STRING && !(t.tag == ATYP_PTR)) { return null; }
            Vx v = lw.lit(e, t);
            if (v.p == null || v.t == null || !air_ll::ty_eq(v.t, t)) { return null; }
            if (v.p.tag != APRD_INT && v.p.tag != APRD_FLOAT && v.p.tag != APRD_BOOL && v.p.tag != APRD_NULL && v.p.tag != APRD_STRING && v.p.tag != APRD_BYTES && v.p.tag != APRD_CHAR) { return null; }
            return v.p;
        }
        case Nk.N_EXPR_UNARY:
        {
            if ((Tk)e.p.op != Tk.TOKEN_MINUS || e.child_count == 0 || e.children[0] == null) { return null; }
            Node* c0 = e.children[0];
            if (c0.kind == Nk.N_EXPR_INT && air_ll::ty_is_int(t)) { AirPrd* r = air_ir::air_mk_int(lw.a, -(long)c0.p.ival); r.ty = t; return r; }
            if (c0.kind == Nk.N_EXPR_FLOAT && air_ll::ty_is_float(t)) { AirPrd* r = air_ir::air_mk_float(lw.a, -c0.p.fval); r.ty = t; return r; }
            return null;
        }
        case Nk.N_EXPR_CAST:
        {
            if (e.child_count == 0 || e.children[0] == null) { return null; }
            AirTyp* to = lw.ty(e.type_ann); if (to == null || !air_ll::ty_eq(to, t)) { return null; }
            Node* c0 = e.children[0];
            if (t.tag == ATYP_PTR && c0.kind == Nk.N_EXPR_INT && c0.p.ival == 0) { AirPrd* z = air_ir::air_mk_prd_null(lw.a); z.ty = t; return z; }
            return lw.const_init(c0, t);
        }
        case Nk.N_EXPR_STRUCT_LIT:
        {
            Node* r = e.resolved; if (r == null && e.child_count > 0) { r = e.children[0].resolved; }
            if (r == null || r.kind != Nk.N_DECL_STRUCT || t.tag != ATYP_NOMINAL) { return null; }
            AirDecl* d = lw.data_of(t); if (d == null || d.ctor_count != 1) { return null; }
            AirCtorDecl* c = d.ctors[0]; if (c.field_count > 16) { return null; }
            AirPrd*[16] vals; bool[16] seen;
            for (usz i = 0; i < 16; i++) { seen[i] = false; vals[i] = null; }
            for (usz i = 0; i < e.child_count; i++)
            {
                Node* fi = e.children[i];
                if (fi == null || fi.kind != Nk.N_EXPR_FIELD_INIT) { continue; }
                char* fnm = lw.text(fi); long k = -1;
                AirTyp* ft = fnm == null ? null : lw.field_ty(t, fnm, &k);
                if (ft == null || k < 0 || k >= 16 || fi.child_count == 0) { return null; }
                AirPrd* v = lw.const_init(fi.children[0], ft); if (v == null) { return null; }
                vals[(usz)k] = v; seen[(usz)k] = true;
            }
            AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_RECORD; p.ty = t;
            for (usz i = 0; i < c.field_count; i++)
            {
                if (!seen[i]) { return null; }
                AirFieldInit* fi = air_ir::air_new_AirFieldInit(lw.a);
                fi.name = c.fields[i].name; fi.value = vals[i];
                p.rec_inits[p.rec_init_count] = fi; p.rec_init_count++;
            }
            return p;
        }
        case Nk.N_EXPR_TUPLE:
        {
            if (t.tag != ATYP_TUPLE || t.arg_count != e.child_count || e.child_count > 16) { return null; }
            AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_TUPLE; p.ty = t;
            for (usz i = 0; i < e.child_count; i++)
            {
                AirPrd* v = lw.const_init(e.children[i], t.args[i]); if (v == null) { return null; }
                p.subs[i] = v; p.sub_count++;
            }
            return p;
        }
        case Nk.N_EXPR_ARRAY:
        {
            if (t.tag != ATYP_ARRAY) { return null; }
            if (e.p.aux == 8)   // [v; n]: only a zero fill is a constant we can write compactly
            {
                if (e.child_count == 0 || e.children[0] == null) { return null; }
                Node* f0 = e.children[0];
                bool zero = (f0.kind == Nk.N_EXPR_INT && f0.p.ival == 0) || (f0.kind == Nk.N_EXPR_BOOL && f0.p.ival == 0) || f0.kind == Nk.N_EXPR_NULL;
                if (!zero) { return null; }
                AirPrd* z = air_ir::air_mk_prd_unit(lw.a); z.ty = t; return z;   // zeroinitializer
            }
            if (t.ival != (long)e.child_count || e.child_count > 16) { return null; }
            AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_ARRAY; p.ty = t;
            for (usz i = 0; i < e.child_count; i++)
            {
                AirPrd* v = lw.const_init(e.children[i], t.args[0]); if (v == null) { return null; }
                p.subs[i] = v; p.sub_count++;
            }
            return p;
        }
        default: return null;
    }
}

fn bool Low.is_extern_symbol(Low* lw, char* nm)
{
    for (usz r = 0; r < lw.nroots; r++)
    {
        Node* root = lw.roots[r]; if (root == null) { continue; }
        for (usz i = 0; i < root.child_count; i++)
        {
            Node* c = root.children[i];
            if (c == null || (c.kind != Nk.N_DECL_FN && c.kind != Nk.N_DECL_EXTERN_FN)) { continue; }
            usz esl = 0; char* esp = pfront_core::ext_sym_of(c, &esl);
            if (esp != null) { char[160] sb; usz k = esl < 159 ? esl : 159; for (usz j = 0; j < k; j++) { sb[j] = esp[j]; } sb[k] = 0; if (seq(&sb[0], nm)) { return true; } }
            else if (c.kind == Nk.N_DECL_EXTERN_FN) { char* cn = lw.text(c); if (cn != null && seq(cn, nm)) { return true; } }
        }
    }
    return false;
}
fn Node* Low.type_in_root(Low* lw, Node* root, char* nm)
{
    if (nm == null || root == null) { return null; }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* c = root.children[i];
        if (c == null) { continue; }
        if (c.kind != Nk.N_DECL_STRUCT && c.kind != Nk.N_DECL_UNION && c.kind != Nk.N_DECL_ENUM && c.kind != Nk.N_DECL_TYPE) { continue; }
        char* cn = lw.text(c);
        if (cn != null && seq(cn, nm)) { return c; }
    }
    return null;
}
fn Node* Low.root_of(Low* lw, Node* d)
{
    for (usz r = 0; r < lw.nroots; r++)
    {
        Node* root = lw.roots[r]; if (root == null) { continue; }
        for (usz i = 0; i < root.child_count; i++) { if (root.children[i] == d) { return root; } }
    }
    return null;
}
fn Node* Low.fn_by_name(Low* lw, char* nm)
{
    if (nm == null) { return null; }
    for (usz r = 0; r < lw.nroots; r++)
    {
        Node* root = lw.roots[r]; if (root == null) { continue; }
        for (usz i = 0; i < root.child_count; i++)
        {
            Node* c = root.children[i];
            if (c == null || (c.kind != Nk.N_DECL_FN && c.kind != Nk.N_DECL_EXTERN_FN)) { continue; }
            char* cn = lw.text(c);
            if (cn != null && seq(cn, nm)) { return c; }
        }
    }
    return null;
}
fn Vx Low.call(Low* lw, Node* n, AirTyp* want)
{
    if (n.child_count == 0) { return lw.unit(); }
    Node* cal = n.children[0];
    if (lw.arm.on && lw.arm.kdecl != null && lw.is_resume(n, lw.arm.kdecl)) { return lw.resume_do(n.child_count > 1 ? n.children[1] : null, n); }
    Node* cr = cal.resolved;
    if (cr == null && cal.kind == Nk.N_EXPR_IDENT) { cr = lw.fn_by_name(lw.text(cal)); }
    if (cr == null || !(cr.kind == Nk.N_DECL_FN || cr.kind == Nk.N_DECL_EXTERN_FN))
    {
        // a call through a function VALUE (a closure record)
        AirTyp* ch = lw.hint(cal);
        if (ch == null || lw.clo_of(ch) == null) { lw.unsup(n, "call through a callee that is not a function or a function value"); return lw.unit(); }
        Vx cv = lw.expr(cal, null);
        return lw.call_clo(n, cv, lw.clo_of(cv.t));
    }
    return lw.call_to(n, cr, want);
}
// a call whose callee declaration is known; `n.children[1..]` are the arguments (a call node or a `Module.fn(..)` method node)
fn Vx Low.call_to(Low* lw, Node* n, Node* cr, AirTyp* want)
{
    FnInfo* f = lw.callee_fn(n, cr);
    if (f == null) { return lw.unit(); }
    lw.queue(f);
    usz na = n.child_count - 1;
    // a single `()` argument means no arguments
    if (na == 1 && f.np == 0) { na = 0; }
    if (na != f.np && !(f.variadic && na >= f.np)) { lw.err(n, "wrong number of arguments", f.name); return lw.unit(); }
    Vx[16] av;
    for (usz i = 0; i < na && i < 16; i++)
    {
        AirTyp* pt = i < f.np ? f.pty[i] : null;
        Vx a = lw.expr(n.children[i + 1], pt);
        if (pt != null) { a = lw.coerce_arg(n.children[i + 1], a, pt); }
        av[i] = a;
    }
    if (!lw.live()) { return lw.unit(); }
    if (f.ext && seq(f.name, "syscall"))   // libc's variadic `syscall(nr, a…)` is the AIR `syscall` instruction
    {
        if (na == 0 || na > 7) { lw.err(n, "syscall needs 1 to 7 operands", null); return lw.unit(); }
        Ins* si = lw.push(I_SYS); if (si == null) { return lw.unit(); }
        si.name = lw.fresh("_sys"); si.nargs = na;
        for (usz i = 0; i < na; i++) { Vx ci = lw.cast(av[i], lw.m.t_i64); si.args[i] = ci.p; }
        return lw.vref(si.name, lw.m.t_i64);
    }
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_r"); ins.a = air_ir::air_mk_var(lw.a, f.name); ins.nargs = na;
    for (usz i = 0; i < na && i < 16; i++) { ins.args[i] = av[i].p; }
    if (na > 16) { lw.unsup(n, "call with more than 16 arguments"); }
    Vx r = lw.vref(ins.name, f.ret);
    if (f.ret.tag == ATYP_BOTTOM) { lw.t_end(T_UNREACH); }
    else if (!f.ext) { lw.check_unw(); }
    return r;
}
// an argument must already have the parameter's type (literals adopt it); anything else is a type error
fn Vx Low.coerce_arg(Low* lw, Node* at, Vx a, AirTyp* want)
{
    if (a.t == null || air_ll::ty_eq(a.t, want)) { return a; }
    if (a.p != null && a.p.tag == APRD_INT && air_ll::ty_is_int(want)) { return lw.lit_int(a.p.ival, want); }
    if (a.p != null && a.p.tag == APRD_INT && want.tag == ATYP_PTR && air_ll::ty_is_int(a.t))   // the literal `0` as a pointer is null (a constant-folded `0 as *T`)
    {
        if (a.p.ival == 0) { AirPrd* np1 = air_ir::air_mk_prd_null(lw.a); np1.ty = want; Vx nr1; nr1.p = np1; nr1.t = want; return nr1; }
        return lw.coerce(lw.lit_int(a.p.ival, lw.m.t_usz), want);
    }
    Enm* ue = lw.enum_of_ty(want);
    if (ue != null && ue.nm > 0)   // a member flows into its union
    {
        for (usz i = 0; i < ue.nm; i++)
        {
            Vx m = a;
            if (air_ll::ty_eq(ue.um[i], a.t) || (a.p != null && a.p.tag == APRD_INT && air_ll::ty_is_int(ue.um[i]) && air_ll::ty_is_int(a.t) == false))
            { Vx[1] av1; av1[0] = m; return lw.variant_pack(ue, i, &av1[0], 1); }
        }
    }
    if (a.t.tag == ATYP_ARROW && lw.clo_of(want) != null) { return lw.to_clo(a, want, at); }
    if (a.t.tag == ATYP_ARRAY && lw.fat_elem(want) != null && !lw.is_str_t(want) && air_ll::ty_eq(a.t.args[0], lw.fat_elem(want))) {
        Pl pl;   // an array that has an address decays to a slice that ALIASES it
        if (at != null && (at.kind == Nk.N_EXPR_IDENT || at.kind == Nk.N_EXPR_FIELD || at.kind == Nk.N_EXPR_INDEX || at.kind == Nk.N_EXPR_DEREF)
            && lw.place(at, &pl) && air_ll::ty_eq(pl.t, a.t)) { return lw.slice_at(pl.ptr, pl.t, want); }
        return lw.array_to_slice(a, want);
    }
    if (a.t.tag == ATYP_PTR && want.tag == ATYP_PTR)   // `ptr` is the untyped pointer: any pointer flows to it and back
    {
        AirTyp* ae = a.t.args[0]; AirTyp* we = want.args[0];
        if ((ae != null && air_ll::ty_is_int(ae) && air_ll::ty_bits(ae) == 8 && !air_ll::ty_is_signed(ae)) || (we != null && air_ll::ty_is_int(we) && air_ll::ty_bits(we) == 8 && !air_ll::ty_is_signed(we))) { return lw.coerce(a, want); }
    }
    // lossless integer widening is implicit (a `u8` returned from an `i64` function); narrowing needs `as`
    if (air_ll::ty_is_int(a.t) && air_ll::ty_is_int(want) && air_ll::ty_bits(a.t) < air_ll::ty_bits(want)
        && (air_ll::ty_is_signed(a.t) == air_ll::ty_is_signed(want) || !air_ll::ty_is_signed(a.t)))
    { return lw.cast(a, want); }
    { char[200] lb; usz ln = mang(a.t, &lb[0], 0, 90); lb[ln] = 0; char[100] rb; usz rn = mang(want, &rb[0], 0, 90); rb[rn] = 0; char[320] mb; snprintf(&mb[0], 320, "%s given, %s wanted", &lb[0], &rb[0]); lw.err(at, "argument type differs from the parameter type", lw.dup(&mb[0])); }
    return a;
}

fn Vx Low.expr(Low* lw, Node* n, AirTyp* want)
{
    if (n == null) { return lw.unit(); }
    if (lw.fn_errors > 0) { return lw.unit(); }
    lw.cur_node = n;
    bool dsc = lw.discard; lw.discard = false;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR: case Nk.N_EXPR_UNIT:
        case Nk.N_EXPR_NULL: case Nk.N_EXPR_STRING: case Nk.N_EXPR_BYTES:
            return lw.lit(n, want);
        case Nk.N_EXPR_IDENT: return lw.read_var(n);
        case Nk.N_BLOCK: lw.blk_discard = dsc || (want != null && !lw.carries(want)); return lw.block(n, want);
        case Nk.N_EXPR_BINARY: return lw.binary(n, want);
        case Nk.N_EXPR_UNARY: return lw.unary(n, want);
        case Nk.N_EXPR_CALL: return lw.call(n, want);
        case Nk.N_EXPR_CAST:
        {
            AirTyp* to = lw.ty(n.type_ann);
            if (to == null || n.child_count == 0) { return lw.unit(); }
            AirTyp* h = lw.hint(n.children[0]);
            // literals take the target type directly; everything else is evaluated at its own type
            Node* c0 = n.children[0];
            if (c0.kind == Nk.N_EXPR_INT && to.tag == ATYP_PTR)   // `0 as *T` is null; any other integer is an address
            {
                if (c0.p.ival == 0) { AirPrd* np0 = air_ir::air_mk_prd_null(lw.a); np0.ty = to; Vx nr; nr.p = np0; nr.t = to; return nr; }
                return lw.coerce(lw.lit_int((long)c0.p.ival, lw.m.t_usz), to);
            }
            bool lit0 = c0.kind == Nk.N_EXPR_INT || c0.kind == Nk.N_EXPR_FLOAT;
            Vx v = lw.expr(c0, lit0 ? to : h);
            Enm* ce = lw.enum_of_ty(v.t);
            if (ce != null && ce.nm > 0) { return lw.union_cast(v, to, ce); }
            if (v.t != null && v.t.tag == ATYP_ARRAY && to.tag == ATYP_PTR)   // an array decays to the address of its storage (a stack slot of this function)
            {
                if (!lw.live()) { return lw.unit(); }
                Vx asl = lw.alloca_(v.t); lw.store(asl.p, v);
                return lw.cast(asl, to);
            }
            return lw.cast(v, to);
        }
        case Nk.N_EXPR_IF: lw.if_discard = dsc || (want != null && !lw.carries(want)); return lw.if_(n, want);
        case Nk.N_EXPR_WHILE: return lw.while_(n);
        case Nk.N_EXPR_FOR: return lw.for_(n);
        case Nk.N_EXPR_LOOP: return lw.loop_(n);
        case Nk.N_EXPR_MATCH: return lw.match_(n, want);
        case Nk.N_STMT_RETURN:
        {
            Vx v = n.child_count > 0 ? lw.expr(n.children[0], lw.ret_ty) : lw.unit();
            lw.finish_ret(v, n);
            return lw.unit();
        }
        case Nk.N_STMT_BREAK:
        {
            if (lw.nloops == 0) { lw.err(n, "break outside a loop", null); return lw.unit(); }
            lw.t_jump0(lw.loops[lw.nloops - 1].brk); return lw.unit();
        }
        case Nk.N_STMT_CONTINUE:
        {
            if (lw.nloops == 0) { lw.err(n, "continue outside a loop", null); return lw.unit(); }
            lw.t_jump0(lw.loops[lw.nloops - 1].cont); return lw.unit();
        }
        case Nk.N_STMT_EXPR: return n.child_count > 0 ? lw.expr(n.children[0], null) : lw.unit();
        case Nk.N_DECL_LET: lw.let_decl(n); return lw.unit();
        case Nk.N_STMT_DEFER: lw.register_defer(n); return lw.unit();
        case Nk.N_DECL_FN: return lw.unit();   // a nested fn is a top-level def of its own (it captures nothing); reached through its call sites
        case Nk.N_STMT_ASSIGN: case Nk.N_EXPR_ASSIGN: case Nk.N_STMT_COMPOUND_ASSIGN: lw.assign(n); return lw.unit();
        case Nk.N_EXPR_INDEX: case Nk.N_EXPR_FIELD: case Nk.N_EXPR_DEREF:
        {
            Pl p;
            if (n.kind == Nk.N_EXPR_FIELD && n.child_count > 0)
            {
                long evi = -1; Enm* ee = lw.enum_ctor_base(n.children[0], lw.dname(n), &evi);   // `E.B`
                if (ee != null) { return lw.variant_value(ee, (usz)evi, null, 0, n); }
                AirTyp* abt = lw.hint(n.children[0]); char* af = lw.text(n);
                if (abt != null && abt.tag == ATYP_ARRAY && af != null && seq(af, "len")) { return lw.lit_int(abt.ival, lw.m.t_i64); }
                if (abt != null && abt.tag == ATYP_TUPLE && n.p.aux == 1)   // `t.0`
                {
                    long ti = (long)n.p.ival;
                    if (ti >= (long)abt.arg_count) { lw.err(n, "tuple index out of range", null); return lw.unit(); }
                    Vx tb = lw.expr(n.children[0], abt);
                    Ins* pi = lw.push(I_PROJ); if (pi == null) { return lw.unit(); }
                    pi.name = lw.fresh("_p"); pi.a = tb.p; pi.idx = ti;
                    return lw.vref(pi.name, abt.args[ti]);
                }
            }
            if (lw.place(n, &p)) { return lw.load(p.ptr, p.t); }
            if (n.kind == Nk.N_EXPR_FIELD && n.child_count > 0)
            {
                AirTyp* bt = lw.hint(n.children[0]); char* f = lw.text(n); long k = -1;
                AirTyp* ft = (bt != null && f != null) ? lw.field_ty(bt, f, &k) : null;
                if (ft != null)
                {
                    Vx b = lw.expr(n.children[0], bt);
                    Ins* ins = lw.push(I_FIELD); if (ins == null) { return lw.unit(); }
                    ins.name = lw.fresh("_f"); ins.a = b.p; ins.fld = f; ins.idx = k;
                    return lw.vref(ins.name, ft);
                }
            }
            if (lw.fn_errors == 0) { lw.unsup(n, "this access path"); }
            return lw.unit();
        }
        case Nk.N_EXPR_REF:
        {
            Pl p;
            if (n.child_count > 0 && lw.place(n.children[0], &p)) { Vx r; r.p = p.ptr; r.t = lw.ptr(p.t); return r; }
            if (n.child_count == 0 || lw.fn_errors > 0) { return lw.unit(); }
            // `&e` of a value that has no address (an immutable `let`, a call result): the address of a stack copy
            Vx sv = lw.expr(n.children[0], (want != null && want.tag == ATYP_PTR) ? want.args[0] : null);
            if (!lw.live() || sv.t == null) { return lw.unit(); }
            Vx sl = lw.alloca_(sv.t); lw.store(sl.p, sv); return sl;
        }
        case Nk.N_EXPR_STRUCT_LIT: return lw.struct_lit(n, want);
        case Nk.N_EXPR_ARRAY: return lw.array_lit(n, want);
        case Nk.N_EXPR_LAMBDA: return lw.lambda(n, want);
        case Nk.N_EXPR_QUOTE: return lw.lambda(n, want);
        case Nk.N_EXPR_SPLICE:
        case Nk.N_EXPR_EVAL:
        {
            // code is a delayed computation: splicing or running it calls it
            if (n.child_count == 0) { return lw.unit(); }
            Vx cv = lw.expr(n.children[0], null);
            CloI* ci = lw.clo_of(cv.t);
            if (ci == null || ci.np != 0) { lw.err(n, "splice/eval of something that is not code", null); return lw.unit(); }
            Vx fp = lw.field_of(cv, "fn", 0, ci.fnty); Vx ep = lw.field_of(cv, "env", 1, lw.ptr(lw.m.t_u8));
            Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
            ins.name = lw.fresh("_r"); ins.a = fp.p; ins.nargs = 1; ins.args[0] = ep.p;
            Vx r = lw.vref(ins.name, ci.ret); lw.check_unw(); return r;
        }
        case Nk.N_EXPR_PERFORM:
        {
            Node* eff = null; Node* op = null;
            if (n.child_count == 0 || !lw.eff_path(n.children[0], &eff, &op)) { lw.err(n, "perform of an unknown effect operation", null); return lw.unit(); }
            return lw.perform_op(eff, op, n.child_count > 1 ? &n.children[1] : null, n.child_count - 1, n);
        }
        case Nk.N_EXPR_HANDLE: return lw.handle(n, want);
        case Nk.N_EXPR_ASSERT:
        {
            if (n.child_count == 0) { return lw.unit(); }
            Vx c = lw.expr(n.children[0], lw.m.t_bool);
            if (!lw.live()) { return lw.unit(); }
            usz okb = lw.blk("assert.ok"); usz bad = lw.blk("assert.fail");
            lw.t_cond(c, okb, bad);
            lw.cur = bad; lw.t_end(T_TRAP);
            lw.cur = okb; return lw.unit();
        }
        case Nk.N_EXPR_POISON:   // an arbitrary value (a use of it is the program's undefined behaviour, which the optimiser may exploit)
            return lw.zero_of(want != null ? want : lw.m.t_i64);
        case Nk.N_EXPR_RESUME: return lw.resume_do(n.child_count > 0 ? n.children[0] : null, n);
        case Nk.N_EXPR_METHOD:
        {
            if (n.child_count > 0 && n.children[0] != null && n.children[0].resolved != null && n.children[0].resolved.kind == Nk.N_DECL_EFFECT)
            {
                Node* eff = n.children[0].resolved; Node* op = lw.effect_op(eff, lw.dname(n));
                if (op == null) { lw.err(n, "unknown effect operation", lw.dname(n)); return lw.unit(); }
                return lw.perform_op(eff, op, &n.children[1], n.child_count - 1, n);
            }
            if (n.resolved != null && (n.resolved.kind == Nk.N_DECL_FN || n.resolved.kind == Nk.N_DECL_EXTERN_FN)) { return lw.call_to(n, n.resolved, want); }   // `module.fn(args)`
            long vi = -1; char* mn = lw.dname(n);
            Enm* e = n.child_count > 0 ? lw.enum_ctor_base(n.children[0], mn, &vi) : null;
            if (e == null) { lw.unsup(n, "method call"); return lw.unit(); }
            return lw.variant_value(e, (usz)vi, &n.children[1], n.child_count - 1, n);
        }
        case Nk.N_EXPR_TUPLE:
        {
            AirTyp* wt = (want != null && want.tag == ATYP_TUPLE) ? want : null;
            if (n.child_count == 0) { return lw.unit(); }
            AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_TUPLE;
            AirTyp*[16] ts;
            for (usz i = 0; i < n.child_count && i < 16; i++)
            {
                Vx e = lw.expr(n.children[i], wt != null && i < wt.arg_count ? wt.args[i] : null);
                ts[i] = e.t; p.add_sub(e.p);
            }
            AirTyp* tt = air_ir::air_mk_typ_tuple(lw.a, &ts[0], n.child_count);
            return lw.let_(p, tt, "_tu");
        }
        case Nk.N_EXPR_ALLOC: return lw.alloc(n);
        case Nk.N_EXPR_FREE:
        {
            if (n.child_count == 0) { return lw.unit(); }
            Vx p = lw.expr(n.children[0], null);
            Vx b = lw.coerce(p, lw.ptr(lw.m.t_u8));
            Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
            ins.name = lw.fresh("_fr"); ins.a = air_ir::air_mk_var(lw.a, "free"); ins.nargs = 1; ins.args[0] = b.p;
            return lw.unit();
        }
        case Nk.N_EXPR_SIZEOF:
        {
            AirTyp* t = n.child_count > 0 ? lw.ty(n.children[0]) : lw.ty(n.type_ann);
            if (t == null) { return lw.unit(); }
            return lw.sizeof_(t);
        }
        case Nk.N_EXPR_SYSCALL:
        {
            if (n.child_count == 0 || n.child_count > 7) { lw.err(n, "syscall needs 1 to 7 operands", null); return lw.unit(); }
            Vx[8] av;
            for (usz i = 0; i < n.child_count; i++)
            {
                Vx a = lw.expr(n.children[i], lw.m.t_i64);
                av[i] = lw.cast(a, lw.m.t_i64);
            }
            Ins* ins = lw.push(I_SYS); if (ins == null) { return lw.unit(); }
            ins.name = lw.fresh("_sys"); ins.nargs = n.child_count;
            for (usz i = 0; i < n.child_count; i++) { ins.args[i] = av[i].p; }
            return lw.vref(ins.name, lw.m.t_i64);
        }
        case Nk.N_EXPR_UB: lw.t_end(T_UNREACH); return lw.unit();
        case Nk.N_EXPR_TRAP: lw.t_end(T_TRAP); return lw.unit();
        case Nk.N_EXPR_UNREACHABLE: lw.t_end(T_UNREACH); return lw.unit();
        case Nk.N_EXPR_UNSAFE: case Nk.N_EXPR_UNCHECKED:
        {
            if (n.kind == Nk.N_EXPR_UNCHECKED) { lw.unchecked++; }
            Vx uv = n.child_count > 0 ? lw.expr(n.children[n.child_count - 1], want) : lw.unit();
            if (n.kind == Nk.N_EXPR_UNCHECKED) { lw.unchecked--; }
            return uv;
        }
        default:
            lw.unsup(n, "expression"); return lw.unit();
    }
}

// value conversion with the rules of `as`
fn Vx Low.cast(Low* lw, Vx v, AirTyp* to)
{
    if (v.t == null || to == null) { return v; }
    return lw.coerce(v, to);
}

fn Vx Low.alloc(Low* lw, Node* n)
{
    Node* cnt = null;
    AirTyp* el = lw.alloc_elem(n, &cnt);
    if (el == null) { lw.unsup(n, "alloc of this type"); return lw.unit(); }
    Vx count = cnt == null ? lw.lit_int(1, lw.m.t_i64) : lw.coerce(lw.expr(cnt, lw.m.t_i64), lw.m.t_i64);
    Vx esz = lw.sizeof_(el);
    Vx esz64 = lw.coerce(esz, lw.m.t_i64);
    Vx bytes = lw.binop(ABIN_MUL, count, esz64);
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_m"); ins.a = air_ir::air_mk_var(lw.a, "malloc"); ins.nargs = 1; ins.args[0] = bytes.p;
    Vx raw = lw.vref(ins.name, lw.ptr(lw.m.t_u8));
    return lw.coerce(raw, lw.ptr(el));
}

// the (possibly generic) struct type of a literal: from the expected type, else from the field values
fn AirTyp* Low.lit_struct_ty(Low* lw, Node* n, Node* r, AirTyp* want)
{
    Node*[4] tps; usz ntp = lw.typarams(r, &tps[0]);
    if (ntp == 0) { return lw.struct_ty(r); }
    StInfo* ws = lw.st_of(want);
    if (ws != null && ws.decl == r) { return want; }
    usz mark = lw.ntsub;
    for (usz j = 0; j < ntp; j++) { lw.tsub_push(tps[j], null); }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* fi = n.children[i]; if (fi == null || fi.kind != Nk.N_EXPR_FIELD_INIT || fi.child_count == 0) { continue; }
        char* fnm = lw.text(fi);
        for (usz k = 0; k < r.child_count; k++)
        {
            Node* fd = r.children[k];
            if (fd == null || fd.kind != Nk.N_DECL_FIELD) { continue; }
            char* dn = lw.text(fd);
            if (dn == null || fnm == null || !seq(dn, fnm)) { continue; }
            AirTyp* ah = lw.hint(fi.children[0]);
            if (ah == null && fi.children[0].kind == Nk.N_EXPR_INT) { ah = lw.m.t_i64; }
            lw.unify(fd.type_ann, ah);
        }
    }
    AirTyp*[4] ta; bool ok = true;
    for (usz j = 0; j < ntp; j++) { ta[j] = lw.tsub[mark + j].t; if (ta[j] == null) { ok = false; } }
    lw.ntsub = mark;
    if (!ok) { lw.err(n, "cannot infer the type arguments of this struct literal", lw.text(r)); return null; }
    return lw.struct_inst(r, &ta[0], ntp);
}
fn Vx Low.struct_lit(Low* lw, Node* n, AirTyp* want)
{
    Node* r = n.resolved; if (r == null && n.child_count > 0) { r = n.children[0].resolved; }
    if (r != null && r.kind == Nk.N_DECL_UNION) { return lw.union_lit(n, r); }
    if (r == null || r.kind != Nk.N_DECL_STRUCT) { lw.unsup(n, "literal of a non-struct type"); return lw.unit(); }
    AirTyp* st = lw.lit_struct_ty(n, r, want);
    AirDecl* d = lw.data_of(st);
    if (st == null || d == null) { return lw.unit(); }
    AirCtorDecl* c = d.ctors[0];
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_RECORD;
    Vx[16] vals; bool[16] seen;
    for (usz i = 0; i < 16; i++) { seen[i] = false; }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* fi = n.children[i];
        if (fi == null || fi.kind != Nk.N_EXPR_FIELD_INIT) { continue; }
        char* fnm = lw.text(fi); long k = -1;
        AirTyp* ft = fnm == null ? null : lw.field_ty(st, fnm, &k);
        if (ft == null || k < 0 || k >= 16) { lw.err(fi, "field is not declared", fnm); return lw.unit(); }
        Vx v = lw.expr(fi.child_count > 0 ? fi.children[0] : null, ft);
        v = lw.coerce_arg(fi, v, ft);
        vals[(usz)k] = v; seen[(usz)k] = true;
    }
    for (usz i = 0; i < c.field_count && i < 16; i++)
    {
        if (!seen[i]) { lw.err(n, "field is not initialised", c.fields[i].name); return lw.unit(); }
        AirFieldInit* fi = air_ir::air_new_AirFieldInit(lw.a);
        fi.name = c.fields[i].name; fi.value = vals[i].p;
        p.rec_inits[p.rec_init_count] = fi; p.rec_init_count++;
    }
    return lw.let_(p, st, "_rec");
}

fn Vx Low.unary(Low* lw, Node* n, AirTyp* want)
{
    if (n.child_count == 0) { return lw.unit(); }
    Tk op = (Tk)n.p.op;
    if (op == Tk.TOKEN_MINUS)
    {
        Node* c0 = n.children[0];
        if (c0.kind == Nk.N_EXPR_INT)
        {
            Vx l = lw.lit(c0, want);
            return lw.lit_int(-l.p.ival, l.t);
        }
        Vx v = lw.expr(c0, want);
        AirPrd* p = air_ir::air_mk_unop(lw.a, AUN_NEG, v.p);
        return lw.let_(p, v.t, "_n");
    }
    if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT)
    {
        Vx v = lw.expr(n.children[0], null);
        AirUnop u = (v.t != null && v.t.tag == ATYP_BOOL) ? AUN_NOT : AUN_BITNOT;
        AirPrd* p = air_ir::air_mk_unop(lw.a, u, v.p);
        return lw.let_(p, v.t, "_n");
    }
    if (op == Tk.TOKEN_TILDE)
    {
        Vx v = lw.expr(n.children[0], want);
        AirPrd* p = air_ir::air_mk_unop(lw.a, AUN_BITNOT, v.p);
        return lw.let_(p, v.t, "_n");
    }
    lw.unsup(n, "unary operator"); return lw.unit();
}

fn bool Low.binop_for(Low* lw, Tk op, AirBinop* out)
{
    switch (op)
    {
        case Tk.TOKEN_PLUS: case Tk.TOKEN_PLUS_PERCENT: *out = ABIN_ADD; return true;
        case Tk.TOKEN_MINUS: case Tk.TOKEN_MINUS_PERCENT: *out = ABIN_SUB; return true;
        case Tk.TOKEN_STAR: case Tk.TOKEN_STAR_PERCENT: *out = ABIN_MUL; return true;
        case Tk.TOKEN_SLASH: *out = ABIN_DIV; return true;
        case Tk.TOKEN_PERCENT: *out = ABIN_MOD; return true;
        case Tk.TOKEN_AMP: *out = ABIN_AND; return true;
        case Tk.TOKEN_PIPE: *out = ABIN_OR; return true;
        case Tk.TOKEN_XOR: *out = ABIN_XOR; return true;
        case Tk.TOKEN_LSHIFT: *out = ABIN_SHL; return true;
        case Tk.TOKEN_RSHIFT: *out = ABIN_SHR; return true;
        case Tk.TOKEN_EQEQ: *out = ABIN_EQ; return true;
        case Tk.TOKEN_NEQ: *out = ABIN_NEQ; return true;
        case Tk.TOKEN_LT: *out = ABIN_LT; return true;
        case Tk.TOKEN_GT: *out = ABIN_GT; return true;
        case Tk.TOKEN_LTEQ: *out = ABIN_LE; return true;
        case Tk.TOKEN_GTEQ: *out = ABIN_GE; return true;
        default: return false;
    }
}

// an extern declaration for an LLVM intrinsic: the low profile has no operation for it, an ordinary call to
// a function named `llvm.*` is the escape hatch (a consumer that is not LLVM must implement the name)
fn char* Low.intrinsic(Low* lw, char* nm, AirTyp** ps, usz np, AirTyp* ret)
{
    for (usz i = 0; i < lw.m.decl_count; i++) { AirDecl* d = lw.m.decls[i]; if (d != null && d.tag == ADECL_DECLARE && seq(d.name, nm)) { return d.name; } }
    char* nn = lw.dup(nm);
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DECLARE, nn);
    ad.is_extern = true; ad.ret_ty = ret;
    for (usz i = 0; i < np; i++) { ad.add_param(air_ir::air_mk_binder(lw.a, lw.dup("_"), ps[i], AMULT_UNR)); }
    lw.m.add_decl(ad);
    return nn;
}
fn Vx Low.saturating(Low* lw, Node* n, bool add, AirTyp* want)
{
    AirTyp* h = lw.hint(n.children[0]); if (h == null) { h = lw.hint(n.children[1]); } if (h == null) { h = want; }
    Vx l = lw.expr(n.children[0], h); Vx r = lw.expr(n.children[1], h != null ? h : l.t);
    if (l.t == null || !air_ll::ty_is_int(l.t)) { lw.err(n, "saturating arithmetic needs integers", null); return lw.unit(); }
    if (!air_ll::ty_eq(l.t, r.t)) { r = lw.coerce_arg(n.children[1], r, l.t); }
    char[64] b; int bits = air_ll::ty_bits(l.t);
    snprintf(&b[0], 64, "llvm.%c%s.sat.i%d", air_ll::ty_is_signed(l.t) ? 's' : 'u', add ? "add" : "sub", bits);
    AirTyp*[2] ps; ps[0] = l.t; ps[1] = l.t;
    char* fnm = lw.intrinsic(&b[0], &ps[0], 2, l.t);
    if (!lw.live()) { return lw.unit(); }
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_sat"); ins.a = air_ir::air_mk_var(lw.a, fnm); ins.nargs = 2; ins.args[0] = l.p; ins.args[1] = r.p;
    return lw.vref(ins.name, l.t);
}
// `x |> f`: application of a function (or function value) to x
fn Vx Low.pipeline(Low* lw, Node* n, AirTyp* want)
{
    Node* f = n.children[1];
    Node* cr = f.resolved;
    if (cr != null && (cr.kind == Nk.N_DECL_FN || cr.kind == Nk.N_DECL_EXTERN_FN))
    {
        // call_to reads its arguments from children[1..]: build a call node on the stack-free arena copy
        FnInfo* fi = lw.fn_for(cr); if (fi == null) { return lw.unit(); }
        lw.queue(fi);
        if (fi.np != 1) { lw.err(n, "`|>` needs a function of one argument", fi.name); return lw.unit(); }
        Vx a = lw.expr(n.children[0], fi.pty[0]); a = lw.coerce_arg(n.children[0], a, fi.pty[0]);
        if (!lw.live()) { return lw.unit(); }
        Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
        ins.name = lw.fresh("_r"); ins.a = air_ir::air_mk_var(lw.a, fi.name); ins.nargs = 1; ins.args[0] = a.p;
        Vx r = lw.vref(ins.name, fi.ret);
        if (!fi.ext) { lw.check_unw(); }
        return r;
    }
    Vx cv = lw.expr(f, null); CloI* ci = lw.clo_of(cv.t);
    if (ci == null || ci.np != 1) { lw.err(n, "`|>` needs a function of one argument", null); return lw.unit(); }
    Vx a = lw.expr(n.children[0], ci.ps[0]); a = lw.coerce_arg(n.children[0], a, ci.ps[0]);
    if (!lw.live()) { return lw.unit(); }
    Vx fp = lw.field_of(cv, "fn", 0, ci.fnty); Vx ep = lw.field_of(cv, "env", 1, lw.ptr(lw.m.t_u8));
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_r"); ins.a = fp.p; ins.nargs = 2; ins.args[0] = ep.p; ins.args[1] = a.p;
    Vx r = lw.vref(ins.name, ci.ret); lw.check_unw(); return r;
}
fn Vx Low.binary(Low* lw, Node* n, AirTyp* want)
{
    if (n.child_count < 2) { return lw.unit(); }
    Tk op = (Tk)n.p.op;
    if (op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_AND || op == Tk.TOKEN_KW_OR) { return lw.shortcircuit(n, op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND); }
    if (op == Tk.TOKEN_PIPELINE) { return lw.pipeline(n, want); }
    if (op == Tk.TOKEN_PLUS_PIPE || op == Tk.TOKEN_MINUS_PIPE) { return lw.saturating(n, op == Tk.TOKEN_PLUS_PIPE, want); }
    AirBinop b;
    if (!lw.binop_for(op, &b)) { lw.unsup(n, "binary operator"); return lw.unit(); }
    if (op == Tk.TOKEN_PLUS || op == Tk.TOKEN_MINUS)   // pointer arithmetic: p + n / p - n advance by n elements; p - q is the element distance
    {
        AirTyp* lh = lw.hint(n.children[0]);
        if (lh != null && lh.tag == ATYP_PTR)
        {
            AirTyp* el = lh.args[0];
            Vx pl = lw.expr(n.children[0], lh);
            AirTyp* rh = lw.hint(n.children[1]);
            if (op == Tk.TOKEN_MINUS && rh != null && rh.tag == ATYP_PTR)
            {
                Vx pr = lw.expr(n.children[1], rh);
                if (!lw.live()) { return lw.unit(); }
                Vx li = lw.coerce(pl, lw.m.t_i64); Vx ri = lw.coerce(pr, lw.m.t_i64);
                Vx bytes = lw.binop(ABIN_SUB, li, ri);
                Vx esz = lw.coerce(lw.sizeof_(el), lw.m.t_i64);
                return lw.binop(ABIN_DIV, bytes, esz);
            }
            Vx off = lw.expr(n.children[1], lw.m.t_i64);
            if (off.t != null && !air_ll::ty_eq(off.t, lw.m.t_i64)) { off = lw.coerce(off, lw.m.t_i64); }
            if (!lw.live()) { return lw.unit(); }
            if (op == Tk.TOKEN_MINUS) { off = lw.binop(ABIN_SUB, lw.lit_int(0, lw.m.t_i64), off); }
            Vx[1] gi; gi[0] = off;
            return lw.gep(pl.p, el, &gi[0], 1, el);
        }
    }
    bool cmp = b == ABIN_EQ || b == ABIN_NEQ || b == ABIN_LT || b == ABIN_GT || b == ABIN_LE || b == ABIN_GE;
    bool shift = b == ABIN_SHL || b == ABIN_SHR;
    AirTyp* h = lw.hint(n.children[0]);
    if (h == null) { h = lw.hint(n.children[1]); }
    if (h == null && !cmp) { h = want; }
    Vx l = lw.expr(n.children[0], h);
    Vx r = lw.expr(n.children[1], shift ? l.t : (h != null ? h : l.t));
    if (l.t != null && r.t != null && !air_ll::ty_eq(l.t, r.t))
    {
        if (r.p != null && r.p.tag == APRD_INT && air_ll::ty_is_int(l.t)) { r = lw.lit_int(r.p.ival, l.t); }
        else if (l.p != null && l.p.tag == APRD_INT && air_ll::ty_is_int(r.t)) { l = lw.lit_int(l.p.ival, r.t); }
        else if (l.t.tag == ATYP_PTR && r.p != null && r.p.tag == APRD_NULL) { r = lw.coerce(r, l.t); }
        else if (shift && air_ll::ty_is_int(l.t) && air_ll::ty_is_int(r.t)) { r = lw.coerce(r, l.t); }
        else { char[200] lb; usz ln = mang(l.t, &lb[0], 0, 90); lb[ln] = 0; char[100] rb; usz rn = mang(r.t, &rb[0], 0, 90); rb[rn] = 0; char[320] mb; snprintf(&mb[0], 320, "%s vs %s", &lb[0], &rb[0]); lw.err(n, "operands have different types", lw.dup(&mb[0])); return lw.unit(); }
    }
    if (!lw.live()) { return lw.unit(); }
    return lw.binop(b, l, r);
}

// a && b / a || b: the right side runs only when needed; the result is a bool block parameter
fn Vx Low.shortcircuit(Low* lw, Node* n, bool is_and)
{
    Vx l = lw.expr(n.children[0], lw.m.t_bool);
    if (!lw.live()) { return lw.unit(); }
    usz rhs = lw.blk("sc.rhs"); usz join = lw.blk("sc.join");
    char* pn = lw.fresh("_b");
    lw.blks[join].pnames[0] = pn; lw.blks[join].ptys[0] = lw.m.t_bool; lw.blks[join].np = 1;
    // short value goes straight to the join
    usz shortb = lw.blk("sc.short");
    if (is_and) { lw.t_cond(l, rhs, shortb); } else { lw.t_cond(l, shortb, rhs); }
    lw.cur = shortb;
    { Vx[1] a; a[0] = lw.lit_bool(!is_and); lw.t_jump(join, &a[0], 1); }
    lw.cur = rhs;
    Vx r = lw.expr(n.children[1], lw.m.t_bool);
    if (lw.live()) { Vx[1] a; a[0] = r; lw.t_jump(join, &a[0], 1); }
    lw.cur = join;
    return lw.vref(pn, lw.m.t_bool);
}

fn Vx Low.block(Low* lw, Node* n, AirTyp* want)
{
    Vx last = lw.unit();
    bool bdsc = lw.blk_discard; lw.blk_discard = false;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        bool is_last = i + 1 == n.child_count;
        lw.discard = !is_last || bdsc;
        last = lw.expr(c, is_last ? want : null);
        lw.discard = false;
        if (lw.fn_errors > 0) { break; }
        if (!lw.live()) { break; }       // code after return/break/trap is unreachable
    }
    return last;
}

fn void Low.let_decl(Low* lw, Node* n)
{
    // children: pattern, [initialiser]
    Node* pat = n.child_count > 0 ? n.children[0] : null;
    Node* init = n.child_count > 1 ? n.children[1] : null;
    if (pat == null) { lw.unsup(n, "let without a pattern"); return; }
    if (pat.kind != Nk.N_PAT_IDENT && pat.kind != Nk.N_PAT_WILDCARD)
    {
        // destructuring let: an irrefutable pattern; a refutable one that does not match traps
        if (init == null) { lw.unsup(pat, "destructuring let without an initialiser"); return; }
        AirTyp* dh = pat.type_ann != null ? lw.ty(pat.type_ann) : (n.type_ann != null ? lw.ty(n.type_ann) : null);
        Vx dv = lw.expr(init, dh);
        if (!lw.live()) { return; }
        usz bad = lw.blk("let.fail");
        usz sv = lw.cur; lw.cur = bad; lw.t_end(T_TRAP); lw.cur = sv;
        lw.pat(pat, dv, bad);
        return;
    }
    AirTyp* declared = pat.type_ann != null ? lw.ty(pat.type_ann) : (n.type_ann != null ? lw.ty(n.type_ann) : null);
    if (pat.type_ann != null && declared == null) { return; }
    if (init != null && init.kind == Nk.N_EXPR_ARRAY && init.p.aux == 8 && pat.kind == Nk.N_PAT_IDENT && (declared == null || declared.tag == ATYP_ARRAY))
    {
        AirTyp* rat = null; Vx sl = lw.repeat_slot(init, declared, &rat);   // `let a = [v; n]` fills the array in place
        if (lw.live() && rat != null) { lw.bind_var(pat, sl.p, rat, true); }
        return;
    }
    Vx v;
    if (init != null) { v = lw.expr(init, declared); v = declared != null ? lw.coerce_arg(init, v, declared) : v; }
    else
    {
        if (declared == null) { lw.unsup(n, "let without a type or initialiser"); return; }
        v.t = declared; v.p = null;
    }
    AirTyp* t = declared != null ? declared : v.t;
    if (t == null) { lw.unsup(n, "let of an untyped value"); return; }
    if (!lw.live()) { return; }
    bool mutable = (n.flags & pfront_core::NF_MUT) != 0 || (pat.flags & pfront_core::NF_MUT) != 0
                   || (n.flags & pfront_core::NF_ADDR_TAKEN) != 0 || (pat.flags & pfront_core::NF_ADDR_TAKEN) != 0;
    if (pat.kind == Nk.N_PAT_WILDCARD) { return; }
    char* nm = lw.uname(lw.text(pat));
    if (mutable || (v.p == null) || t.tag == ATYP_ARRAY)   // arrays live in memory: they can be sliced / indexed by address
    {
        Vx s = lw.alloca_(t);
        // the slot gets the user's name so the .air stays readable
        if (s.p != null && s.p.tag == APRD_VAR) { s.p = air_ir::air_mk_var(lw.a, s.p.name); }
        if (v.p != null) { lw.store(s.p, v); }
        lw.bind_var(pat, s.p, t, true);
        return;
    }
    // immutable: an SSA name
    if (v.p != null && v.p.tag == APRD_VAR) { lw.bind_var(pat, v.p, t, false); return; }
    Ins* ins = lw.push(I_LET); if (ins == null) { return; }
    ins.name = nm; ins.a = v.p; v.p.ty = t;
    lw.bind_var(pat, air_ir::air_mk_var(lw.a, nm), t, false);
}

fn void Low.assign(Low* lw, Node* n)
{
    if (n.child_count < 2) { return; }
    Pl p;
    if (!lw.place(n.children[0], &p))
    {
        if (lw.fn_errors == 0) { lw.unsup(n.children[0], "assignment target that is not a mutable place"); }
        return;
    }
    if (n.kind == Nk.N_STMT_COMPOUND_ASSIGN)
    {
        AirBinop b = air_lower::compound_binop((long)n.p.op);
        Vx cur = lw.load(p.ptr, p.t);
        bool shift = b == ABIN_SHL || b == ABIN_SHR;
        Vx r = lw.expr(n.children[1], p.t);
        if (shift) { r = lw.coerce(r, p.t); }
        else { r = lw.coerce_arg(n.children[1], r, p.t); }
        if (!lw.live()) { return; }
        Vx res = lw.binop(b, cur, r);
        lw.store(p.ptr, res);
        return;
    }
    Vx v = lw.expr(n.children[1], p.t);
    v = lw.coerce_arg(n.children[1], v, p.t);
    if (!lw.live()) { return; }
    lw.store(p.ptr, v);
}

// a value flowing out of if/match arms: unit/bottom arms carry nothing
fn bool Low.carries(Low* lw, AirTyp* t) { return t != null && t.tag != ATYP_UNIT && t.tag != ATYP_BOTTOM; }

fn Vx Low.if_(Low* lw, Node* n, AirTyp* want)
{
    bool dsc = lw.if_discard; lw.if_discard = false;
    if (n.child_count < 2) { return lw.unit(); }
    Vx c = lw.expr(n.children[0], lw.m.t_bool);
    if (!lw.live()) { return lw.unit(); }
    if (c.t == null || c.t.tag != ATYP_BOOL) { lw.err(n, "if condition is not a bool", null); return lw.unit(); }
    bool has_else = n.child_count > 2;
    usz tb = lw.blk("then"); usz eb = lw.blk("else"); usz jb = lw.blk("join");
    lw.t_cond(c, tb, eb);
    AirTyp* rt = null; bool t_live = false; bool e_live = false; Vx tv = lw.unit(); Vx ev = lw.unit();
    lw.cur = tb;
    AirTyp* twant = want;
    if (has_else && twant == null && !dsc) { AirTyp* eh = lw.hint(n.children[2]); if (eh != null && lw.carries(eh)) { twant = eh; } }   // the else arm may know the type the untyped literals of the then arm need
    lw.discard = dsc; tv = lw.expr(n.children[1], has_else ? twant : null);
    t_live = lw.live();
    if (t_live) { rt = tv.t; }
    usz t_end = lw.cur;
    // the then-arm's last block still needs its jump: delay it until the join's parameter is known
    lw.cur = eb;
    lw.discard = dsc;
    if (has_else) { ev = lw.expr(n.children[2], (rt != null && lw.carries(rt)) ? rt : want); }
    e_live = lw.live();
    usz e_end = lw.cur;
    AirTyp* jt = null;
    if (has_else)
    {
        if (t_live && e_live)
        {
            if (tv.t != null && ev.t != null && !air_ll::ty_eq(tv.t, ev.t) && dsc) { tv = lw.unit(); ev = lw.unit(); }   // the value is discarded
            else if (tv.t != null && ev.t != null && !air_ll::ty_eq(tv.t, ev.t))
            {
                if (ev.p != null && ev.p.tag == APRD_INT && air_ll::ty_is_int(tv.t)) { ev = lw.lit_int(ev.p.ival, tv.t); }
                else if (tv.p != null && tv.p.tag == APRD_INT && air_ll::ty_is_int(ev.t)) { tv = lw.lit_int(tv.p.ival, ev.t); }
                else if (tv.p != null && tv.p.tag == APRD_INT && ev.t.tag == ATYP_PTR) { tv = lw.coerce_arg(n.children[1], tv, ev.t); }
                else if (ev.p != null && ev.p.tag == APRD_INT && tv.t.tag == ATYP_PTR) { ev = lw.coerce_arg(n.children[2], ev, tv.t); }
                else if (lw.carries(tv.t) || lw.carries(ev.t)) { char[200] tb2; usz tn2 = mang(tv.t, &tb2[0], 0, 100); tb2[tn2] = 0; char[100] eb2; usz en2 = mang(ev.t, &eb2[0], 0, 100); eb2[en2] = 0; char[320] mb2; snprintf(&mb2[0], 320, "%s vs %s", &tb2[0], &eb2[0]); lw.err(n, "if branches have different types", lw.dup(&mb2[0])); return lw.unit(); }
            }
            jt = tv.t;
        }
        else if (t_live) { jt = tv.t; }
        else if (e_live) { jt = ev.t; }
    }
    bool carry = has_else && lw.carries(jt);
    char* pn = null;
    if (carry) { pn = lw.fresh("_j"); lw.blks[jb].pnames[0] = pn; lw.blks[jb].ptys[0] = jt; lw.blks[jb].np = 1; }
    if (t_live)
    {
        lw.cur = t_end;
        if (carry) { Vx[1] a; a[0] = tv; lw.t_jump(jb, &a[0], 1); } else { lw.t_jump0(jb); }
    }
    if (e_live)
    {
        lw.cur = e_end;
        if (carry) { Vx[1] a; a[0] = ev; lw.t_jump(jb, &a[0], 1); } else { lw.t_jump0(jb); }
    }
    if (lw.blks[jb].npred == 0) { lw.cur = NOBLK; return lw.unit(); }
    lw.cur = jb;
    if (carry) { return lw.vref(pn, jt); }
    return lw.unit();
}

fn Vx Low.while_(Low* lw, Node* n)
{
    if (n.child_count < 2) { return lw.unit(); }
    bool post = (n.flags & pfront_core::NF_POSTTEST) != 0;
    if (post) { lw.unsup(n, "do-while"); return lw.unit(); }
    usz head = lw.blk("wh.head"); usz body = lw.blk("wh.body"); usz exit = lw.blk("wh.exit");
    lw.t_jump0(head);
    lw.cur = head;
    Vx c = lw.expr(n.children[0], lw.m.t_bool);
    if (lw.live())
    {
        if (c.t == null || c.t.tag != ATYP_BOOL) { lw.err(n, "while condition is not a bool", null); return lw.unit(); }
        lw.t_cond(c, body, exit);
    }
    lw.cur = body;
    lw.loops[lw.nloops].brk = exit; lw.loops[lw.nloops].cont = head; lw.nloops++;
    lw.expr(n.children[1], null);
    lw.nloops--;
    if (lw.live()) { lw.t_jump0(head); }
    lw.cur = lw.blks[exit].npred > 0 ? exit : NOBLK;
    return lw.unit();
}

fn Vx Low.loop_(Low* lw, Node* n)
{
    usz head = lw.blk("lp.head"); usz exit = lw.blk("lp.exit");
    lw.t_jump0(head);
    lw.cur = head;
    lw.loops[lw.nloops].brk = exit; lw.loops[lw.nloops].cont = head; lw.nloops++;
    if (n.child_count > 0) { lw.expr(n.children[n.child_count - 1], null); }
    lw.nloops--;
    if (lw.live()) { lw.t_jump0(head); }
    lw.cur = lw.blks[exit].npred > 0 ? exit : NOBLK;
    return lw.unit();
}

fn Vx Low.for_(Low* lw, Node* n)
{
    if (n.child_count < 3) { return lw.unit(); }
    Node* pat = n.children[0]; Node* it = n.children[1]; Node* body = n.children[2];
    if (it == null || it.kind != Nk.N_EXPR_RANGE || it.child_count < 2) { lw.unsup(n, "for over something that is not a range"); return lw.unit(); }
    bool incl = (it.flags & pfront_core::NF_INCLUSIVE) != 0;
    AirTyp* h = lw.hint(it.children[0]); if (h == null) { h = lw.hint(it.children[1]); }
    if (h == null) { h = lw.m.t_i64; }
    Vx lo = lw.expr(it.children[0], h); Vx hi = lw.expr(it.children[1], h);
    if (!lw.live()) { return lw.unit(); }
    if (lo.t != null && !air_ll::ty_is_int(lo.t)) { lw.err(n, "for range bounds are not integers", null); return lw.unit(); }
    if (hi.t != null && !air_ll::ty_eq(lo.t, hi.t)) { hi = lw.coerce(hi, lo.t); }
    AirTyp* t = lo.t;
    Vx slot = lw.alloca_(t);
    lw.store(slot.p, lo);
    usz head = lw.blk("for.head"); usz body_b = lw.blk("for.body"); usz step = lw.blk("for.step"); usz exit = lw.blk("for.exit");
    lw.t_jump0(head);
    lw.cur = head;
    Vx i = lw.load(slot.p, t);
    Vx c = lw.binop(incl ? ABIN_LE : ABIN_LT, i, hi);
    lw.t_cond(c, body_b, exit);
    lw.cur = body_b;
    if (pat != null && pat.kind == Nk.N_PAT_IDENT && lw.has_defer(body))
    {
        lw.bind_var(pat, slot.p, t, true);   // a deferred statement reads the counter when it replays (after the loop: the exit value)
    }
    else if (pat != null && pat.kind == Nk.N_PAT_IDENT)
    {
        char* nm = lw.uname(lw.text(pat));
        Ins* ins = lw.push(I_LET);
        if (ins != null) { ins.name = nm; ins.a = i.p; i.p.ty = t; lw.bind_var(pat, air_ir::air_mk_var(lw.a, nm), t, false); }
    }
    lw.loops[lw.nloops].brk = exit; lw.loops[lw.nloops].cont = step; lw.nloops++;
    lw.expr(body, null);
    lw.nloops--;
    if (lw.live()) { lw.t_jump0(step); }
    if (lw.blks[step].npred > 0)
    {
        lw.cur = step;
        Vx cur = lw.load(slot.p, t);
        Vx nx = lw.binop(ABIN_ADD, cur, lw.lit_int(1, t));
        lw.store(slot.p, nx);
        lw.t_jump0(head);
    }
    lw.cur = exit;
    return lw.unit();
}

// ── patterns and match ─────────────────────────────────────────────────────
// Tests `v` against pattern `p`; on mismatch control goes to `fail`. Binds names. Returns false if unsupported.
fn bool Low.pat(Low* lw, Node* p, Vx v, usz fail)
{
    if (p == null) { return true; }
    switch (p.kind)
    {
        case Nk.N_PAT_WILDCARD: return true;
        case Nk.N_PAT_IDENT:
        {
            if (lw.is_unit_t(v.t)) { return true; }
            if ((p.flags & (pfront_core::NF_MUT | pfront_core::NF_ADDR_TAKEN)) != 0)   // `mut x` / `&x`: a stack slot
            {
                Vx sl = lw.alloca_(v.t); lw.store(sl.p, v); lw.bind_var(p, sl.p, v.t, true); return true;
            }
            char* nm = lw.uname(lw.text(p));
            Ins* ins = lw.push(I_LET); if (ins == null) { return true; }
            ins.name = nm; ins.a = v.p; v.p.ty = v.t;
            lw.bind_var(p, air_ir::air_mk_var(lw.a, nm), v.t, false);
            return true;
        }
        case Nk.N_PAT_LITERAL:
        {
            if (p.child_count == 0) { lw.unsup(p, "literal pattern"); return false; }
            Node* lit = p.children[0];
            Vx l = lw.expr(lit, v.t);
            if (!lw.live()) { return true; }
            if (l.t != null && v.t != null && !air_ll::ty_eq(l.t, v.t))
            {
                if (l.p != null && l.p.tag == APRD_INT && air_ll::ty_is_int(v.t)) { l = lw.lit_int(l.p.ival, v.t); }
                else { lw.err(p, "pattern type differs from the scrutinee", null); return false; }
            }
            Vx eq = lw.binop(ABIN_EQ, v, l);
            usz ok = lw.blk("pat.ok");
            lw.t_cond(eq, ok, fail);
            lw.cur = ok;
            return true;
        }
        case Nk.N_PAT_RANGE:
        {
            if (p.child_count < 2) { lw.unsup(p, "range pattern"); return false; }
            Vx lo = lw.expr(p.children[0], v.t); Vx hi = lw.expr(p.children[1], v.t);
            Vx a = lw.binop(ABIN_GE, v, lo);
            Vx b = lw.binop((p.flags & pfront_core::NF_INCLUSIVE) != 0 ? ABIN_LE : ABIN_LT, v, hi);
            usz mid = lw.blk("pat.mid"); usz ok = lw.blk("pat.ok");
            lw.t_cond(a, mid, fail);
            lw.cur = mid;
            lw.t_cond(b, ok, fail);
            lw.cur = ok;
            return true;
        }
        case Nk.N_PAT_TUPLE:
        {
            if (p.child_count == 0 && lw.is_unit_t(v.t)) { return true; }
            if (v.t == null || v.t.tag != ATYP_TUPLE || v.t.arg_count != p.child_count) { lw.unsup(p, "tuple pattern against this type"); return false; }
            for (usz i = 0; i < p.child_count; i++)
            {
                Ins* ins = lw.push(I_PROJ); if (ins == null) { return true; }
                ins.name = lw.fresh("_p"); ins.a = v.p; ins.idx = (long)i;
                Vx e = lw.vref(ins.name, v.t.args[i]);
                if (!lw.pat(p.children[i], e, fail)) { return false; }
            }
            return true;
        }
        case Nk.N_PAT_VARIANT: case Nk.N_PAT_STRUCT:
        {
            Enm* e = lw.enum_of_ty(v.t);
            Node*[8] subs; usz ns = 0;
            if (e != null && p.kind == Nk.N_PAT_VARIANT)
            {
                long vi = lw.variant_index(e, lw.dname(p), p.resolved);
                if (vi < 0) { lw.err(p, "pattern names no variant of the scrutinee's enum", lw.dname(p)); return false; }
                for (usz i = 0; i < p.child_count && ns < 8; i++) { Node* c = p.children[i]; if (c != null && pfront_core::is_pattern(c.kind)) { subs[ns] = c; ns++; } }
                return lw.pat_variant(e, (usz)vi, &subs[0], ns, v, fail);
            }
            if (e != null)    // `{ A: a }` / `{ B }` on an enum
            {
                for (usz i = 0; i < p.child_count; i++)
                {
                    Node* f = p.children[i]; if (f == null || f.kind != Nk.N_PAT_FIELD) { continue; }
                    long vi = lw.variant_index(e, lw.dname(f), null);
                    if (vi < 0) { lw.err(f, "pattern names no variant of the scrutinee's enum", lw.dname(f)); return false; }
                    if (e.v[(usz)vi].nf > 0 && f.child_count > 0) { subs[0] = f.children[0]; ns = 1; }
                    return lw.pat_variant(e, (usz)vi, &subs[0], ns, v, fail);
                }
                lw.unsup(p, "enum struct-pattern without a variant"); return false;
            }
            AirDecl* sd = lw.data_of(v.t);   // struct pattern
            if (sd == null || sd.ctor_count != 1) { lw.unsup(p, "struct pattern against this type"); return false; }
            for (usz i = 0; i < p.child_count; i++)
            {
                Node* f = p.children[i]; if (f == null || f.kind != Nk.N_PAT_FIELD) { continue; }
                char* fnm = lw.dname(f); long k = -1;
                AirTyp* ft = fnm == null ? null : lw.field_ty(v.t, fnm, &k);
                if (ft == null) { lw.err(f, "field is not declared", fnm); return false; }
                Vx fv = lw.field_of(v, fnm, k, ft);
                if (f.child_count > 0 && f.children[0] != null) { if (!lw.pat(f.children[0], fv, fail)) { return false; } }
            }
            return true;
        }
        default:
            lw.unsup(p, "pattern"); return false;
    }
}
fn bool Low.irrefutable(Low* lw, Node* p)
{
    if (p == null) { return true; }
    if (p.kind == Nk.N_PAT_WILDCARD || p.kind == Nk.N_PAT_IDENT) { return true; }
    if (p.kind == Nk.N_PAT_TUPLE)
    {
        for (usz i = 0; i < p.child_count; i++) { if (!lw.irrefutable(p.children[i])) { return false; } }
        return true;
    }
    return false;
}

// arms: clause/match-arm nodes (pattern, [guard], body); scrutinees: one value per tuple slot
fn Vx Low.arms(Low* lw, Node** arms, usz narms, Vx* scr, usz nscr, AirTyp* want, bool tuple_pat)
{
    char* pn = null; AirTyp* jt = null; bool carry_known = false; bool carry = false;
    usz jb = lw.blk("m.join");
    // results are collected while arms are lowered; the join parameter is added once the type is known
    usz[64] end_blk; Vx[64] end_val; usz nend = 0;
    bool exhaustive = false;
    for (usz ai = 0; ai < narms; ai++)
    {
        Node* arm = arms[ai];
        if (arm == null || arm.child_count == 0) { continue; }
        usz next = lw.blk("arm.next");
        usz nv0 = lw.nvars;
        Node* pat = arm.children[0];
        bool ok = true;
        if (tuple_pat && nscr != 1)
        {
            if (pat.kind == Nk.N_PAT_IDENT || pat.kind == Nk.N_PAT_WILDCARD)   // `t`: the whole argument tuple
            {
                AirTyp*[16] tts; for (usz i = 0; i < nscr && i < 16; i++) { tts[i] = scr[i].t; }
                AirPrd* tp = air_ir::air_new_AirPrd(lw.a); tp.tag = APRD_TUPLE;
                for (usz i = 0; i < nscr && i < 16; i++) { tp.add_sub(scr[i].p); }
                Vx tv = lw.let_(tp, air_ir::air_mk_typ_tuple(lw.a, &tts[0], nscr), "_tu");
                ok = lw.pat(pat, tv, next);
            }
            else
            {
                if (pat.kind != Nk.N_PAT_TUPLE || pat.child_count != nscr) { lw.unsup(pat, "clause pattern shape"); return lw.unit(); }
                for (usz i = 0; i < nscr && ok; i++) { ok = lw.pat(pat.children[i], scr[i], next); }
            }
        }
        else if (nscr == 0) { }
        else { ok = lw.pat(pat, scr[0], next); }
        if (!ok) { return lw.unit(); }
        Node* guard = null; Node* body = null;
        for (usz j = 1; j < arm.child_count; j++)
        {
            Node* c = arm.children[j]; if (c == null) { continue; }
            if (c.kind == Nk.N_GUARD) { guard = c; } else { body = c; }
        }
        bool irref = true;
        if (tuple_pat && nscr != 1 && pat.kind != Nk.N_PAT_TUPLE) { irref = lw.irrefutable(pat); }
        else if (tuple_pat && nscr != 1) { for (usz i = 0; i < nscr && i < pat.child_count; i++) { if (!lw.irrefutable(pat.children[i])) { irref = false; } } }
        else if (nscr > 0) { irref = lw.irrefutable(pat); }
        if (guard != null)
        {
            irref = false;
            Vx g = lw.expr(guard.child_count > 0 ? guard.children[0] : null, lw.m.t_bool);
            if (lw.live()) { usz gok = lw.blk("guard.ok"); lw.t_cond(g, gok, next); lw.cur = gok; }
        }
        Vx bv = body != null ? lw.expr(body, (carry_known && carry) ? jt : want) : lw.unit();
        if (lw.fn_errors > 0) { return lw.unit(); }
        if (lw.live())
        {
            if (nend >= 64) { lw.unsup(arm, "more than 64 arms"); return lw.unit(); }
            end_blk[nend] = lw.cur; end_val[nend] = bv; nend++;
            if (!carry_known) { carry_known = true; jt = bv.t; carry = lw.carries(bv.t); }
            lw.cur = NOBLK;
        }
        lw.nvars = nv0;             // pattern names go out of scope
        if (irref && lw.blks[next].npred == 0) { exhaustive = true; break; }
        lw.cur = next;
        if (ai + 1 == narms)
        {
            // fell through every arm: the front end proved exhaustiveness, so this is unreachable;
            // a trap keeps a wrong proof from becoming silent undefined behaviour
            lw.t_end(T_TRAP);
        }
    }
    if (!exhaustive && lw.live()) { lw.t_end(T_TRAP); }
    if (carry) { pn = lw.fresh("_m"); lw.blks[jb].pnames[0] = pn; lw.blks[jb].ptys[0] = jt; lw.blks[jb].np = 1; }
    for (usz i = 0; i < nend; i++)
    {
        lw.cur = end_blk[i];
        Vx ev = end_val[i];
        if (carry)
        {
            if (ev.t != null && !air_ll::ty_eq(ev.t, jt))
            {
                if (ev.p != null && ev.p.tag == APRD_INT && air_ll::ty_is_int(jt)) { ev = lw.lit_int(ev.p.ival, jt); }
                else { lw.err(null, "match arms have different types", null); return lw.unit(); }
            }
            Vx[1] a; a[0] = ev; lw.t_jump(jb, &a[0], 1);
        }
        else { lw.t_jump0(jb); }
    }
    if (lw.blks[jb].npred == 0) { lw.cur = NOBLK; return lw.unit(); }
    lw.cur = jb;
    if (carry) { return lw.vref(pn, jt); }
    return lw.unit();
}

fn Vx Low.match_(Low* lw, Node* n, AirTyp* want)
{
    if (n.child_count < 2) { return lw.unit(); }
    AirTyp* h = lw.hint(n.children[0]);
    Vx s = lw.expr(n.children[0], h);
    if (!lw.live()) { return lw.unit(); }
    Vx[1] sv; sv[0] = s;
    return lw.arms(&n.children[1], n.child_count - 1, &sv[0], 1, want, false);
}

// ── functions ──────────────────────────────────────────────────────────────

// ── defer ─────────────────────────────────────────────────────────────────
fn bool Low.has_defer(Low* lw, Node* n)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_STMT_DEFER) { return true; }
    if (n.kind == Nk.N_EXPR_LAMBDA || n.kind == Nk.N_DECL_FN) { return false; }
    for (usz i = 0; i < n.child_count; i++) { if (lw.has_defer(n.children[i])) { return true; } }
    return false;
}
// at function entry: one `registered` flag per defer statement (false until its statement executes)
fn void Low.scan_defers(Low* lw, Node* n, Node* top)
{
    if (n == null) { return; }
    if (n != top && (n.kind == Nk.N_EXPR_LAMBDA || n.kind == Nk.N_DECL_FN)) { return; }
    if (n.kind == Nk.N_STMT_DEFER)
    {
        if (lw.ndefer >= 16) { lw.unsup(n, "more than 16 defer statements in one function"); return; }
        DeferR* d = &lw.defers[lw.ndefer]; lw.ndefer++;
        d.node = n; d.nsnap = 0;
        Vx fl = lw.alloca_(lw.m.t_bool);
        lw.store(fl.p, lw.lit_bool(false));
        d.flag = fl.p;
    }
    for (usz i = 0; i < n.child_count; i++) { lw.scan_defers(n.children[i], top); }
}
fn void Low.register_defer(Low* lw, Node* n)
{
    DeferR* d = null;
    for (usz i = 0; i < lw.ndefer; i++) { if (lw.defers[i].node == n) { d = &lw.defers[i]; } }
    if (d == null) { lw.unsup(n, "defer in this position"); return; }
    if (!lw.live()) { return; }
    // SSA values the body mentions are copied now (they may not dominate the exits); memory slots are read at replay
    Cap[16] caps; usz nc = 0;
    for (usz i = 0; i < n.child_count; i++) { lw.collect_caps(n.children[i], n, &caps[0], &nc); }
    d.nsnap = 0;
    for (usz i = 0; i < nc && d.nsnap < 8; i++)
    {
        if (caps[i].by_ref) { continue; }
        VarB* v = lw.find_var(caps[i].decl); if (v == null) { continue; }
        Vx sl = lw.alloca_(v.t);
        Vx val; val.p = v.p; val.t = v.t;
        lw.store(sl.p, val);
        d.snap[d.nsnap].decl = caps[i].decl; d.snap[d.nsnap].t = v.t; d.snap[d.nsnap].sp = sl.p; d.nsnap++;
    }
    lw.store(d.flag, lw.lit_bool(true));
}
fn void Low.replay_defers(Low* lw)
{
    if (lw.in_replay || lw.ndefer == 0 || !lw.live()) { return; }
    lw.in_replay = true;
    for (usz k = lw.ndefer; k > 0; k--)
    {
        DeferR* d = &lw.defers[k - 1];
        Vx fl = lw.load(d.flag, lw.m.t_bool);
        usz run = lw.blk("defer.run"); usz skip = lw.blk("defer.done");
        lw.t_cond(fl, run, skip);
        lw.cur = run;
        usz saved = lw.nvars;
        for (usz j = 0; j < d.nsnap; j++) { lw.bind_var(d.snap[j].decl, d.snap[j].sp, d.snap[j].t, true); }
        for (usz i = 0; i < d.node.child_count; i++) { lw.expr(d.node.children[i], null); }
        lw.nvars = saved;
        if (lw.live()) { lw.t_jump0(skip); }
        lw.cur = skip;
        if (lw.blks[skip].npred == 0) { lw.cur = NOBLK; break; }
    }
    lw.in_replay = false;
}

fn void Low.finish_ret(Low* lw, Vx v, Node* at)
{
    if (!lw.live()) { return; }
    lw.replay_defers();
    if (!lw.live()) { return; }
    if (lw.ret_ty == null) { return; }
    if (lw.ret_ty.tag == ATYP_UNIT || lw.ret_ty.tag == ATYP_BOTTOM) { lw.t_ret(lw.unit()); return; }
    Vx c = lw.coerce_arg(at, v, lw.ret_ty);
    lw.t_ret(c);
}


// ── function values and closures ──────────────────────────────────────────
// the consumer's arrow type always has a TUPLE domain (zero or more parameters)
fn AirTyp* Low.arrow(Low* lw, AirTyp** ps, usz np, AirTyp* ret)
{
    return air_ir::air_mk_typ_arrow(lw.a, air_ir::air_mk_typ_tuple(lw.a, ps, np), ret);
}
fn AirTyp* Low.clo_ty(Low* lw, AirTyp** ps, usz np, AirTyp* ret)
{
    for (usz i = 0; i < lw.nclo; i++)
    {
        CloI* c = &lw.clos[i];
        if (c.np != np || !air_ll::ty_eq(c.ret, ret)) { continue; }
        bool same = true;
        for (usz j = 0; j < np; j++) { if (!air_ll::ty_eq(c.ps[j], ps[j])) { same = false; } }
        if (same) { return c.ty; }
    }
    if (lw.nclo >= 128) { lw.unsup(null, "more than 128 function types"); return null; }
    if (np > 7) { lw.unsup(null, "function value with more than 7 parameters"); return null; }
    char[260] nm; usz n = (usz)snprintf(&nm[0], 260, "Fn.");
    for (usz j = 0; j < np; j++) { n = mang(ps[j], &nm[0], n, 260); n += (usz)snprintf(&nm[0] + n, (usz)(260 - n), "."); }
    n += (usz)snprintf(&nm[0] + n, (usz)(260 - n), ">"); mang(ret, &nm[0], n, 260);
    char* name = lw.dup(&nm[0]);
    AirTyp* t = lw.nominal(name);
    CloI* c = &lw.clos[lw.nclo]; lw.nclo++;
    c.ty = t; c.np = np; c.ret = ret;
    AirTyp*[16] fps; fps[0] = lw.ptr(lw.m.t_u8);
    for (usz j = 0; j < np; j++) { c.ps[j] = ps[j]; fps[j + 1] = ps[j]; }
    c.fnty = lw.arrow(&fps[0], np + 1, ret);
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, name);
    AirCtorDecl* cd = air_ir::air_mk_ctor_decl(lw.a, name);
    cd.result_ty = t; d.add_ctor(cd);
    cd.add_field(air_ir::air_mk_field(lw.a, lw.dup("fn"), c.fnty, AMULT_UNR));
    cd.add_field(air_ir::air_mk_field(lw.a, lw.dup("env"), lw.ptr(lw.m.t_u8), AMULT_UNR));
    lw.m.add_decl(d);
    return t;
}
fn CloI* Low.clo_of(Low* lw, AirTyp* t)
{
    if (t == null || t.tag != ATYP_NOMINAL) { return null; }
    for (usz i = 0; i < lw.nclo; i++) { if (seq(lw.clos[i].ty.name, t.name)) { return &lw.clos[i]; } }
    return null;
}
fn Vx Low.mk_clo(Low* lw, AirTyp* cty, AirPrd* fnp, AirPrd* envp)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_RECORD;
    AirFieldInit* f0 = air_ir::air_new_AirFieldInit(lw.a); f0.name = lw.dup("fn"); f0.value = fnp;
    AirFieldInit* f1 = air_ir::air_new_AirFieldInit(lw.a); f1.name = lw.dup("env"); f1.value = envp;
    p.rec_inits[0] = f0; p.rec_inits[1] = f1; p.rec_init_count = 2;
    return lw.let_(p, cty, "_clo");
}
fn Vx Low.null_env(Low* lw)
{
    AirTyp* t = lw.ptr(lw.m.t_u8);
    AirPrd* p = air_ir::air_mk_prd_null(lw.a); p.ty = t; Vx r; r.p = p; r.t = t; return r;
}
// a top-level function used as a value: wrap it in an adapter that ignores the environment
fn FnInfo* Low.adapter_for(Low* lw, FnInfo* tg)
{
    for (usz i = 0; i < lw.nfn; i++) { if (lw.fns[i].is_adapt && lw.fns[i].adapt == tg) { return &lw.fns[i]; } }
    if (lw.nfn >= MAXFN) { lw.unsup(null, "more than 4096 functions"); return null; }
    FnInfo* f = &lw.fns[lw.nfn]; lw.nfn++;
    char[200] b; snprintf(&b[0], 200, "%s.clo", tg.name);
    f.name = lw.dup(&b[0]); f.is_adapt = true; f.adapt = tg; f.decl = null;
    f.np = tg.np + 1; f.pty[0] = lw.ptr(lw.m.t_u8);
    for (usz i = 0; i < tg.np; i++) { f.pty[i + 1] = tg.pty[i]; }
    f.ret = tg.ret; f.fnty = lw.arrow(&f.pty[0], f.np, f.ret);
    lw.queue(f);
    return f;
}
// function value of the right closure type from `a` (a plain function name, or already a closure)
fn Vx Low.to_clo(Low* lw, Vx a, AirTyp* want, Node* at)
{
    CloI* ci = lw.clo_of(want);
    if (ci == null || a.t == null || a.t.tag != ATYP_ARROW || a.p == null || a.p.tag != APRD_VAR) { return a; }
    FnInfo* tg = null;
    for (usz i = 0; i < lw.nfn; i++) { if (!lw.fns[i].is_adapt && !lw.fns[i].is_lam && seq(lw.fns[i].name, a.p.name)) { tg = &lw.fns[i]; } }
    if (tg == null) { return a; }
    bool ok = tg.np == ci.np && air_ll::ty_eq(tg.ret, ci.ret);
    for (usz j = 0; ok && j < ci.np; j++) { if (!air_ll::ty_eq(tg.pty[j], ci.ps[j])) { ok = false; } }
    if (!ok) { lw.err(at, "function does not have the expected function type", tg.name); return a; }
    if (tg.ext) { Vx ec = lw.coerce(a, lw.ptr(lw.m.t_u8)); return lw.raw_clo(ec, want); }   // an extern is a bare code pointer: wrap it
    lw.queue(tg);
    FnInfo* ad = lw.adapter_for(tg); if (ad == null) { return a; }
    return lw.mk_clo(want, air_ir::air_mk_var(lw.a, ad.name), lw.null_env().p);
}
// ── lambda capture analysis ──
fn bool Low.decl_inside(Low* lw, Node* d, Node* top)
{
    Node* c = d;
    while (c != null) { if (c == top) { return true; } c = c.parent; }
    return false;
}
fn void Low.collect_caps(Low* lw, Node* n, Node* lam, Cap* caps, usz* nc)
{
    if (n == null) { return; }
    if (n.kind == Nk.N_EXPR_IDENT && n.resolved != null && !lw.decl_inside(n.resolved, lam))
    {
        VarB* v = lw.find_var(n.resolved);
        if (v != null)
        {
            bool have = false;
            for (usz i = 0; i < *nc; i++) { if (caps[i].decl == n.resolved) { have = true; } }
            if (!have && *nc < 16) { caps[*nc].decl = n.resolved; caps[*nc].t = v.t; caps[*nc].by_ref = v.slot; *nc = *nc + 1; }
        }
    }
    for (usz i = 0; i < n.child_count; i++) { lw.collect_caps(n.children[i], lam, caps, nc); }
}
// a type for an expression whose only type information is its literals (an untyped literal is i64 / f64)
fn AirTyp* Low.hint_or_lit(Low* lw, Node* n)
{
    if (n == null) { return null; }
    AirTyp* h = lw.hint(n); if (h != null) { return h; }
    switch (n.kind)
    {
        case Nk.N_EXPR_INT: return lw.m.t_i64;
        case Nk.N_EXPR_FLOAT: return lw.m.t_f64;
        case Nk.N_EXPR_BOOL: return lw.m.t_bool;
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ) { return lw.m.t_bool; }
            return n.child_count > 0 ? lw.hint_or_lit(n.children[0]) : null;
        }
        default:
            if (n.child_count == 1 && n.kind == Nk.N_EXPR_SPLICE) { return lw.hint_or_lit(n.children[0]); }
            return null;
    }
}
fn bool Low.lam_sig(Low* lw, Node* n, AirTyp* want, AirTyp** ps, usz* np, AirTyp** ret)
{
    CloI* wc = lw.clo_of(want);
    *np = 0;
    if (n.kind == Nk.N_EXPR_QUOTE)   // `quote e` is the delayed computation `fn () -> T { e }`
    {
        *ret = (wc != null && wc.np == 0) ? wc.ret : (n.child_count > 0 ? lw.hint_or_lit(n.children[0]) : null);
        if (*ret == null) { lw.err(n, "cannot determine the type of the quoted code", null); return false; }
        return true;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i]; if (c == null || c.kind != Nk.N_DECL_PARAM) { continue; }
        Node* pat = c.child_count > 0 ? c.children[0] : null;
        Node* tn = c.type_ann != null ? c.type_ann : (pat != null ? pat.type_ann : null);
        AirTyp* pt = tn != null ? lw.ty(tn) : ((wc != null && *np < wc.np) ? wc.ps[*np] : null);
        if (pt == null) { lw.err(c, "lambda parameter needs a type", null); return false; }
        if (*np >= 15) { lw.unsup(n, "lambda with more than 15 parameters"); return false; }
        ps[*np] = pt; *np = *np + 1;
    }
    *ret = n.type_ann != null ? lw.ty(n.type_ann) : (wc != null ? wc.ret : null);
    if (*ret == null) { lw.err(n, "lambda needs a result type", null); return false; }
    return true;
}
// A closure whose environment may outlive the creating call needs a heap environment. Only a lambda written directly as a
// call argument (or the callee) keeps its environment on the stack (it is the same discipline Rust enforces with lifetimes
// and the callee is trusted not to keep it); every other position -- let, return, field, assignment -- heap-allocates.
fn bool Low.lam_escapes(Low* lw, Node* n)
{
    Node* p = n.parent;
    if (p != null && p.kind == Nk.N_EXPR_CALL) { return false; }
    return true;
}
// malloc(sizeof T) as a ptr(T)
fn Vx Low.heap_box(Low* lw, AirTyp* t)
{
    Vx esz = lw.coerce(lw.sizeof_(t), lw.m.t_i64);
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_m"); ins.a = air_ir::air_mk_var(lw.a, "malloc"); ins.nargs = 1; ins.args[0] = esz.p;
    Vx raw = lw.vref(ins.name, lw.ptr(lw.m.t_u8));
    return lw.coerce(raw, lw.ptr(t));
}
fn Vx Low.lambda(Low* lw, Node* n, AirTyp* want)
{
    AirTyp*[16] ps; usz np = 0; AirTyp* ret = null;
    if (!lw.lam_sig(n, want, &ps[0], &np, &ret)) { return lw.unit(); }
    AirTyp* cty = lw.clo_ty(&ps[0], np, ret); if (cty == null) { return lw.unit(); }
    if (lw.nfn >= MAXFN) { lw.unsup(n, "more than 4096 functions"); return lw.unit(); }
    FnInfo* f = &lw.fns[lw.nfn]; lw.nfn++;
    lw.nlam++;
    char[200] b; snprintf(&b[0], 200, "%s.lam%d", lw.cur_fn, (int)lw.nlam);
    f.name = lw.dup(&b[0]); f.is_lam = true; f.decl = n;
    lw.collect_caps(n, n, &f.caps[0], &f.ncaps);
    f.np = np + 1; f.pty[0] = lw.ptr(lw.m.t_u8);
    for (usz i = 0; i < np; i++) { f.pty[i + 1] = ps[i]; }
    f.ret = ret; f.fnty = lw.arrow(&f.pty[0], f.np, f.ret);
    Vx env = lw.null_env();
    if (f.ncaps > 0)
    {
        char[200] en; snprintf(&en[0], 200, "Env.%s", f.name);
        char* ename = lw.dup(&en[0]);
        f.envty = lw.nominal(ename);
        AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, ename);
        AirCtorDecl* cd = air_ir::air_mk_ctor_decl(lw.a, ename);
        cd.result_ty = f.envty; d.add_ctor(cd);
        for (usz i = 0; i < f.ncaps; i++)
        {
            char[40] fnm; snprintf(&fnm[0], 40, "c%d", (int)i);
            AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
            cd.add_field(air_ir::air_mk_field(lw.a, lw.dup(&fnm[0]), ft, AMULT_UNR));
        }
        lw.m.add_decl(d);
        bool heap = lw.lam_escapes(n);
        Vx slot = heap ? lw.heap_box(f.envty) : lw.alloca_(f.envty);
        for (usz i = 0; i < f.ncaps; i++)
        {
            VarB* v = lw.find_var(f.caps[i].decl);
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)i, lw.m.t_i32);
            AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
            Vx g = lw.gep(slot.p, f.envty, &ix[0], 2, ft);
            Vx val; val.p = v.p; val.t = v.t;
            if (f.caps[i].by_ref)
            {
                if (heap)
                {
                    // an escaping closure owns a heap copy of a captured `mut` variable (the stack slot would dangle):
                    // writes by the closure persist in the box, the creator's variable is no longer shared (move semantics)
                    Vx box = lw.heap_box(v.t);
                    Vx cur = lw.load(v.p, v.t);
                    lw.store(box.p, cur);
                    val.p = box.p; val.t = lw.ptr(v.t);
                }
                else { val.t = lw.ptr(v.t); }   // the slot's address: later writes are visible both ways
            }
            lw.store(g.p, val);
        }
        env = lw.coerce(slot, lw.ptr(lw.m.t_u8));
    }
    lw.queue(f);
    return lw.mk_clo(cty, air_ir::air_mk_var(lw.a, f.name), env.p);
}
fn Vx Low.call_clo(Low* lw, Node* n, Vx c, CloI* ci)
{
    usz na = n.child_count - 1;
    if (na == 1 && ci.np == 0) { na = 0; }
    if (na != ci.np) { lw.err(n, "wrong number of arguments for a function value", null); return lw.unit(); }
    Vx[8] av;
    for (usz i = 0; i < na; i++) { av[i] = lw.expr(n.children[i + 1], ci.ps[i]); av[i] = lw.coerce_arg(n.children[i + 1], av[i], ci.ps[i]); }
    if (!lw.live()) { return lw.unit(); }
    Vx fp = lw.field_of(c, "fn", 0, ci.fnty); Vx ep = lw.field_of(c, "env", 1, lw.ptr(lw.m.t_u8));
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_r"); ins.a = fp.p; ins.nargs = na + 1; ins.args[0] = ep.p;
    for (usz i = 0; i < na; i++) { ins.args[i + 1] = av[i].p; }
    Vx r = lw.vref(ins.name, ci.ret);
    if (ci.ret.tag == ATYP_BOTTOM) { lw.t_end(T_UNREACH); } else { lw.check_unw(); }
    return r;
}
fn void Low.lower_lambda(Low* lw, FnInfo* f)
{
    Node* n = f.decl;
    lw.cur_fn = f.name; lw.fn_errors = 0; lw.cur_node = n;
    lw.nb = 0; lw.nvars = 0; lw.nloops = 0; lw.nhx = 0; lw.arm.on = false; lw.nnames = 0; lw.tmpn = 0; lw.unchecked = 0;
    lw.ret_ty = f.ret; lw.ndefer = 0; lw.in_replay = false;
    usz entry = lw.blk("entry"); lw.cur = entry;
    lw.scan_defers(n, n);
    AirBinder*[16] pb; Vx[16] pv;
    for (usz i = 0; i < f.np; i++)
    {
        char* pnm = lw.fresh("a");
        pb[i] = air_ir::air_mk_binder(lw.a, pnm, f.pty[i], AMULT_UNR);
        pv[i] = lw.vref(pnm, f.pty[i]);
    }
    if (f.ncaps > 0)
    {
        Vx ep = lw.coerce(pv[0], lw.ptr(f.envty));
        for (usz i = 0; i < f.ncaps; i++)
        {
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)i, lw.m.t_i32);
            AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
            Vx g = lw.gep(ep.p, f.envty, &ix[0], 2, ft);
            Vx val = lw.load(g.p, ft);
            lw.bind_var(f.caps[i].decl, val.p, f.caps[i].t, f.caps[i].by_ref);
        }
    }
    usz pi = 1; Node* body = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i]; if (c == null) { continue; }
        if (c.kind == Nk.N_DECL_PARAM)
        {
            Node* pat = c.child_count > 0 ? c.children[0] : null;
            if (pat != null && pi < f.np) { lw.pat(pat, pv[pi], NOBLK); }
            pi++;
        }
        else if (c.kind == Nk.N_BLOCK || pfront_core::is_expr(c.kind)) { body = c; }
    }
    Vx rv = lw.unit();
    if (body == null) { lw.unsup(n, "lambda without a body"); }
    else { rv = lw.expr(body, f.ret); lw.finish_ret(rv, n); }
    if (lw.live() && lw.fn_errors == 0) { lw.t_end(T_TRAP); }
    if (lw.fn_errors > 0) { lw.fail_fn++; return; }
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DEF, f.name);
    ad.is_pub = true;
    for (usz i = 0; i < f.np; i++) { ad.add_param(pb[i]); }
    ad.ret_ty = f.ret; ad.def_body = lw.assemble();
    lw.m.add_decl(ad); lw.fns_ok++;
}
// a raw code pointer as a function value: {fn = indirect adapter, env = the pointer}; the adapter calls its env with the arguments
fn FnInfo* Low.ind_for(Low* lw, CloI* ci)
{
    char[240] b; snprintf(&b[0], 240, "ind.%s", ci.ty.name);
    for (usz i = 0; i < lw.nfn; i++) { if (lw.fns[i].is_ind && seq(lw.fns[i].name, &b[0])) { return &lw.fns[i]; } }
    if (lw.nfn >= MAXFN) { lw.unsup(null, "more than 4096 functions"); return null; }
    FnInfo* f = &lw.fns[lw.nfn]; lw.nfn++;
    f.name = lw.dup(&b[0]); f.is_ind = true; f.decl = null;
    f.np = ci.np + 1; f.pty[0] = lw.ptr(lw.m.t_u8);
    for (usz i = 0; i < ci.np; i++) { f.pty[i + 1] = ci.ps[i]; }
    f.ret = ci.ret; f.fnty = lw.arrow(&f.pty[0], f.np, f.ret);
    lw.queue(f);
    return f;
}
fn Vx Low.raw_clo(Low* lw, Vx code, AirTyp* want)
{
    CloI* ci = lw.clo_of(want); if (ci == null) { return code; }
    FnInfo* ind = lw.ind_for(ci); if (ind == null) { return code; }
    Vx env = code;
    AirTyp* pu8 = lw.ptr(lw.m.t_u8);
    if (!air_ll::ty_eq(code.t, pu8)) { env = lw.coerce(code, pu8); }
    return lw.mk_clo(want, air_ir::air_mk_var(lw.a, ind.name), env.p);
}
fn void Low.lower_ind(Low* lw, FnInfo* f)
{
    lw.cur_fn = f.name; lw.fn_errors = 0; lw.cur_node = null;
    lw.nb = 0; lw.nvars = 0; lw.nloops = 0; lw.nhx = 0; lw.arm.on = false; lw.nnames = 0; lw.tmpn = 0;
    lw.ret_ty = f.ret; lw.ndefer = 0; lw.in_replay = false;
    usz entry = lw.blk("entry"); lw.cur = entry;
    AirBinder*[16] pb; Vx[16] pv;
    for (usz i = 0; i < f.np; i++)
    {
        char* pnm = lw.fresh("a");
        pb[i] = air_ir::air_mk_binder(lw.a, pnm, f.pty[i], AMULT_UNR);
        pv[i] = lw.vref(pnm, f.pty[i]);
    }
    AirTyp* raw = lw.arrow(&f.pty[1], f.np - 1, f.ret);
    Vx fp = lw.coerce(pv[0], raw);
    Ins* ins = lw.push(I_CALL);
    ins.name = lw.fresh("_r"); ins.a = fp.p; ins.nargs = f.np - 1;
    for (usz i = 1; i < f.np; i++) { ins.args[i - 1] = pv[i].p; }
    Vx r = lw.vref(ins.name, f.ret);
    if (f.ret.tag == ATYP_BOTTOM) { lw.t_end(T_UNREACH); } else { lw.finish_ret(r, null); }
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DEF, f.name);
    ad.is_pub = true;
    for (usz i = 0; i < f.np; i++) { ad.add_param(pb[i]); }
    ad.ret_ty = f.ret; ad.def_body = lw.assemble();
    lw.m.add_decl(ad); lw.fns_ok++;
}
fn void Low.lower_adapter(Low* lw, FnInfo* f)
{
    lw.cur_fn = f.name; lw.fn_errors = 0; lw.cur_node = null;
    lw.nb = 0; lw.nvars = 0; lw.nloops = 0; lw.nhx = 0; lw.arm.on = false; lw.nnames = 0; lw.tmpn = 0;
    lw.ret_ty = f.ret; lw.ndefer = 0; lw.in_replay = false;
    usz entry = lw.blk("entry"); lw.cur = entry;
    AirBinder*[16] pb; Vx[16] pv;
    for (usz i = 0; i < f.np; i++)
    {
        char* pnm = lw.fresh("a");
        pb[i] = air_ir::air_mk_binder(lw.a, pnm, f.pty[i], AMULT_UNR);
        pv[i] = lw.vref(pnm, f.pty[i]);
    }
    Ins* ins = lw.push(I_CALL);
    ins.name = lw.fresh("_r"); ins.a = air_ir::air_mk_var(lw.a, f.adapt.name); ins.nargs = f.np - 1;
    for (usz i = 1; i < f.np; i++) { ins.args[i - 1] = pv[i].p; }
    Vx r = lw.vref(ins.name, f.ret);
    if (f.ret.tag == ATYP_BOTTOM) { lw.t_end(T_UNREACH); } else { lw.finish_ret(r, null); }
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DEF, f.name);
    ad.is_pub = true;
    for (usz i = 0; i < f.np; i++) { ad.add_param(pb[i]); }
    ad.ret_ty = f.ret; ad.def_body = lw.assemble();
    lw.m.add_decl(ad); lw.fns_ok++;
}


// ══ effects and handlers ═══════════════════════════════════════════════════
fn Node* Low.effect_named(Low* lw, char* nm)
{
    for (usz r = 0; r < lw.nroots; r++)
    {
        Node* root = lw.roots[r]; if (root == null) { continue; }
        for (usz i = 0; i < root.child_count; i++)
        {
            Node* c = root.children[i];
            if (c != null && c.kind == Nk.N_DECL_EFFECT && seq(lw.dname(c), nm)) { return c; }
        }
    }
    return null;
}
fn Node* Low.effect_op(Low* lw, Node* eff, char* nm)
{
    if (eff == null) { return null; }
    for (usz i = 0; i < eff.child_count; i++)
    {
        Node* c = eff.children[i];
        if (c != null && c.kind == Nk.N_DECL_EFFECT_OP && seq(lw.dname(c), nm)) { return c; }
    }
    return null;
}
// `E.op` from a module path (perform) -> effect and operation declarations
fn bool Low.eff_path(Low* lw, Node* path, Node** eff, Node** op)
{
    if (path == null || path.child_count < 2) { return false; }
    *eff = lw.effect_named(lw.dname(path.children[0]));
    *op = lw.effect_op(*eff, lw.dname(path.children[path.child_count - 1]));
    return *op != null;
}
fn bool Low.op_sig(Low* lw, Node* op, AirTyp** ps, usz* np, AirTyp** ret)
{
    *np = 0; *ret = lw.m.t_unit;
    for (usz i = 0; i < op.child_count; i++)
    {
        Node* c = op.children[i]; if (c == null) { continue; }
        if (c.kind == Nk.N_TY_CONSTRAINT)
        {
            if (c.child_count > 0) { *ret = lw.ty(c.children[0]); if (*ret == null) { return false; } }
            continue;
        }
        if (c.kind == Nk.N_TY_UNIT && *np == 0) { continue; }
        if (c.kind == Nk.N_TY_TUPLE && *np == 0)   // `(A, B) -> R`: several parameters
        {
            for (usz k = 0; k < c.child_count; k++)
            {
                AirTyp* tk = lw.ty(c.children[k]); if (tk == null) { return false; }
                if (*np >= 15) { lw.unsup(op, "effect operation with more than 15 parameters"); return false; }
                ps[*np] = tk; *np = *np + 1;
            }
            continue;
        }
        if (!pfront_core::is_type(c.kind)) { continue; }
        AirTyp* t = lw.ty(c); if (t == null) { return false; }
        if (*np >= 15) { lw.unsup(op, "effect operation with more than 15 parameters"); return false; }
        ps[*np] = t; *np = *np + 1;
    }
    return true;
}
fn AirTyp* Low.hop_ty(Low* lw, AirTyp* cty)
{
    CloI* ci = lw.clo_of(cty); if (ci == null) { return null; }
    char[300] b; snprintf(&b[0], 300, "Hop.%s", cty.name);
    for (usz i = 0; i < lw.nhop; i++) { if (seq(lw.hopn[i], &b[0])) { return lw.hopt[i]; } }
    if (lw.nhop >= 64) { lw.unsup(null, "more than 64 handler cell types"); return null; }
    char* nm = lw.dup(&b[0]); AirTyp* t = lw.nominal(nm);
    lw.hopn[lw.nhop] = nm; lw.hopt[lw.nhop] = t; lw.nhop++;
    AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, nm);
    AirCtorDecl* c = air_ir::air_mk_ctor_decl(lw.a, nm); c.result_ty = t; d.add_ctor(c);
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("fn"), ci.fnty, AMULT_UNR));
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("env"), lw.ptr(lw.m.t_u8), AMULT_UNR));
    c.add_field(air_ir::air_mk_field(lw.a, lw.dup("on"), lw.m.t_i64, AMULT_UNR));
    lw.m.add_decl(d);
    return t;
}
// the global cell of one operation: { fn, env, on }; zero = no handler installed
fn char* Low.hop_global(Low* lw, char* en, char* on, AirTyp* hty)
{
    char[200] b; snprintf(&b[0], 200, "hop.%s.%s", en, on);
    char* nm = lw.dup(&b[0]);
    for (usz i = 0; i < lw.ngl; i++) { if (seq(lw.gls[i].name, nm)) { return nm; } }
    if (lw.ngl >= MAXGL) { lw.unsup(null, "more than 1024 globals"); return nm; }
    GlInfo* g = &lw.gls[lw.ngl]; g.decl = null; g.name = nm; g.ty = hty; lw.ngl++;
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_GLOBAL, nm); ad.ret_ty = hty; ad.g_mut = true;
    lw.m.add_decl(ad);
    return nm;
}
fn char* Low.unw_global(Low* lw)
{
    if (!lw.unw_made)
    {
        lw.unw_made = true;
        AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_GLOBAL, "__unw"); ad.ret_ty = lw.m.t_i64; ad.g_mut = true;
        ad.g_init = air_ir::air_mk_int(lw.a, 0); ad.g_init.ty = lw.m.t_i64;
        lw.m.add_decl(ad);
        GlInfo* g = &lw.gls[lw.ngl]; g.decl = null; g.name = "__unw"; g.ty = lw.m.t_i64; lw.ngl++;
    }
    return "__unw";
}
fn Vx Low.gptr(Low* lw, char* g, AirTyp* t)
{
    Vx r; r.p = air_ir::air_mk_var(lw.a, g); r.t = lw.ptr(t); return r;
}
// an arbitrary value of the type (the dummy returned while unwinding / after an abort)
fn Vx Low.zero_of(Low* lw, AirTyp* t)
{
    if (t == null || !lw.carries(t)) { return lw.unit(); }
    Vx s = lw.alloca_(t); return lw.load(s.p, t);
}
// after anything that may abort: if the unwinding flag is raised, leave this region
fn void Low.check_unw(Low* lw)
{
    if (!lw.eff_on || !lw.live()) { return; }
    Vx up = lw.gptr(lw.unw_global(), lw.m.t_i64);
    Vx u = lw.load(up.p, lw.m.t_i64);
    Vx raised = lw.binop(ABIN_NEQ, u, lw.lit_int(0, lw.m.t_i64));
    usz uw = lw.blk("unwind"); usz ok = lw.blk("cont");
    lw.t_cond(raised, uw, ok);
    lw.cur = uw;
    if (lw.nhx > 0)
    {
        AirTyp* ht = lw.hxt[lw.nhx - 1];
        if (lw.carries(ht)) { Vx[1] a; a[0] = lw.zero_of(ht); lw.t_jump(lw.hx[lw.nhx - 1], &a[0], 1); }
        else { lw.t_jump0(lw.hx[lw.nhx - 1]); }
    }
    else { lw.finish_ret(lw.zero_of(lw.ret_ty), null); }
    lw.cur = ok;
}
fn Vx Low.mk_hop(Low* lw, AirTyp* hty, AirPrd* fnp, AirPrd* envp, long on)
{
    AirPrd* p = air_ir::air_new_AirPrd(lw.a); p.tag = APRD_RECORD;
    AirFieldInit* f0 = air_ir::air_new_AirFieldInit(lw.a); f0.name = lw.dup("fn"); f0.value = fnp;
    AirFieldInit* f1 = air_ir::air_new_AirFieldInit(lw.a); f1.name = lw.dup("env"); f1.value = envp;
    AirFieldInit* f2 = air_ir::air_new_AirFieldInit(lw.a); f2.name = lw.dup("on"); f2.value = lw.lit_int(on, lw.m.t_i64).p;
    p.rec_inits[0] = f0; p.rec_inits[1] = f1; p.rec_inits[2] = f2; p.rec_init_count = 3;
    return lw.let_(p, hty, "_hop");
}
fn Vx Low.perform_op(Low* lw, Node* eff, Node* op, Node** args, usz na, Node* at)
{
    AirTyp*[16] ps; usz np = 0; AirTyp* ret = null;
    if (!lw.op_sig(op, &ps[0], &np, &ret)) { return lw.unit(); }
    if (na == 1 && np == 0) { na = 0; }
    if (na != np) { lw.err(at, "wrong number of arguments for the effect operation", lw.dname(op)); return lw.unit(); }
    AirTyp* cty = lw.clo_ty(&ps[0], np, ret); if (cty == null) { return lw.unit(); }
    CloI* ci = lw.clo_of(cty); AirTyp* hty = lw.hop_ty(cty); if (hty == null) { return lw.unit(); }
    Vx[8] av;
    for (usz i = 0; i < na; i++) { av[i] = lw.expr(args[i], ps[i]); av[i] = lw.coerce_arg(args[i], av[i], ps[i]); }
    if (!lw.live()) { return lw.unit(); }
    char* g = lw.hop_global(lw.dname(eff), lw.dname(op), hty);
    Vx gp = lw.gptr(g, hty);
    Vx h = lw.load(gp.p, hty);
    Vx on = lw.field_of(h, "on", 2, lw.m.t_i64);
    Vx has = lw.binop(ABIN_NEQ, on, lw.lit_int(0, lw.m.t_i64));
    usz go = lw.blk("perform"); usz bad = lw.blk("unhandled");
    lw.t_cond(has, go, bad);
    lw.cur = bad; lw.t_end(T_TRAP);   // an operation performed with no handler installed
    lw.cur = go;
    Vx fp = lw.field_of(h, "fn", 0, ci.fnty); Vx ep = lw.field_of(h, "env", 1, lw.ptr(lw.m.t_u8));
    Ins* ins = lw.push(I_CALL); if (ins == null) { return lw.unit(); }
    ins.name = lw.fresh("_r"); ins.a = fp.p; ins.nargs = na + 1; ins.args[0] = ep.p;
    for (usz i = 0; i < na; i++) { ins.args[i + 1] = av[i].p; }
    Vx r = lw.vref(ins.name, ret);
    lw.check_unw();
    return r;
}
// ── resume ──
fn Vx Low.resume_do(Low* lw, Node* arg, Node* at)
{
    if (!lw.arm.on)
    {
        // outside a handler arm `resume(x)` is an ordinary call when the program defines a function of that name
        // (stdlib/pride/effects.pie wraps the runtime's __pride_resume as `resume`)
        Node* rf = arg == null ? null : lw.fn_by_name("resume");
        FnInfo* f = rf == null ? null : lw.fn_for(rf);
        if (f != null && f.np == 1)
        {
            lw.queue(f);
            Vx a = lw.expr(arg, f.pty[0]); a = lw.coerce_arg(arg, a, f.pty[0]);
            if (!lw.live()) { return lw.unit(); }
            Ins* ci = lw.push(I_CALL); if (ci == null) { return lw.unit(); }
            ci.name = lw.fresh("_r"); ci.a = air_ir::air_mk_var(lw.a, f.name); ci.nargs = 1; ci.args[0] = a.p;
            Vx r = lw.vref(ci.name, f.ret);
            if (!f.ext) { lw.check_unw(); }
            return r;
        }
        lw.err(at, "resume outside a handler arm", null); return lw.unit();
    }
    if (arg != null)
    {
        Vx v = lw.expr(arg, lw.arm.opret);
        if (lw.carries(lw.arm.opret)) { v = lw.coerce_arg(arg, v, lw.arm.opret); lw.store(lw.arm.rv, v); }
    }
    lw.store(lw.arm.flag, lw.lit_int(1, lw.m.t_i64));
    return lw.zero_of(lw.arm.th);
}
fn bool Low.is_resume(Low* lw, Node* n, Node* kdecl)
{
    if (n == null) { return false; }
    if (n.kind == Nk.N_EXPR_RESUME) { return true; }
    return n.kind == Nk.N_EXPR_CALL && n.child_count > 0 && n.children[0] != null && n.children[0].kind == Nk.N_EXPR_IDENT
        && kdecl != null && n.children[0].resolved == kdecl;
}
// resume may only be a TAIL form of the arm (once, on every path that resumes)
fn bool Low.tail_ok(Low* lw, Node* n, Node* kdecl, bool tail)
{
    if (n == null) { return true; }
    if (lw.is_resume(n, kdecl))
    {
        if (!tail) { return false; }
        for (usz i = 1; i < n.child_count; i++) { if (!lw.tail_ok(n.children[i], kdecl, false)) { return false; } }
        return true;
    }
    if (n.kind == Nk.N_BLOCK)
    {
        for (usz i = 0; i < n.child_count; i++) { if (!lw.tail_ok(n.children[i], kdecl, tail && i + 1 == n.child_count)) { return false; } }
        return true;
    }
    if (n.kind == Nk.N_EXPR_IF)
    {
        for (usz i = 0; i < n.child_count; i++) { if (!lw.tail_ok(n.children[i], kdecl, tail && i > 0)) { return false; } }
        return true;
    }
    if (n.kind == Nk.N_EXPR_MATCH)
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i]; if (c == null) { continue; }
            if (c.kind == Nk.N_MATCH_ARM)
            {
                for (usz j = 0; j < c.child_count; j++)
                { if (!lw.tail_ok(c.children[j], kdecl, tail && j + 1 == c.child_count)) { return false; } }
            }
            else if (!lw.tail_ok(c, kdecl, false)) { return false; }
        }
        return true;
    }
    for (usz i = 0; i < n.child_count; i++) { if (!lw.tail_ok(n.children[i], kdecl, false)) { return false; } }
    return true;
}
// ── handle ──
fn Vx Low.handle(Low* lw, Node* n, AirTyp* want)
{
    if (n.child_count < 2) { return lw.unit(); }
    Node* body = n.children[0];
    AirTyp* th = want != null ? want : lw.hint(body);
    if (th == null) { for (usz i = 1; i < n.child_count && th == null; i++) { Node* arm = n.children[i]; if (arm != null && arm.child_count > 0) { th = lw.hint(arm.children[arm.child_count - 1]); } } }
    if (th == null) { lw.err(n, "cannot determine the result type of the handle expression", null); return lw.unit(); }
    if (lw.nhnd >= 256) { lw.unsup(n, "more than 256 handle expressions"); return lw.unit(); }
    HndI* h = &lw.hnds[lw.nhnd]; h.id = lw.nhnd + 1; lw.nhnd++;
    h.th = th; h.nops = 0;
    Node*[8] arms; Node*[8] ops; Node*[8] effs;
    for (usz i = 1; i < n.child_count; i++)
    {
        Node* arm = n.children[i]; if (arm == null) { continue; }
        Node* op = arm.resolved;
        if (op == null || op.kind != Nk.N_DECL_EFFECT_OP) { lw.unsup(arm, "handler arm that is not an effect operation (return arm)"); return lw.unit(); }
        if (h.nops >= 8) { lw.unsup(n, "handler with more than 8 operations"); return lw.unit(); }
        for (usz j = 0; j < h.nops; j++) { if (ops[j] == op) { lw.err(arm, "two arms for one operation", null); return lw.unit(); } }
        arms[h.nops] = arm; ops[h.nops] = op; effs[h.nops] = op.parent; h.nops++;
    }
    // one frame on this function's stack: the displaced handler cells and the result slot
    char[64] fnm; snprintf(&fnm[0], 64, "Frame.%d", (int)h.id);
    h.frame = lw.nominal(lw.dup(&fnm[0]));
    AirDecl* fd = air_ir::air_mk_decl(lw.a, ADECL_DATA, h.frame.name);
    AirCtorDecl* fc = air_ir::air_mk_ctor_decl(lw.a, h.frame.name); fc.result_ty = h.frame; fd.add_ctor(fc);
    FnInfo*[8] afs;
    for (usz j = 0; j < h.nops; j++)
    {
        AirTyp*[16] ps; usz np = 0; AirTyp* ret = null;
        if (!lw.op_sig(ops[j], &ps[0], &np, &ret)) { return lw.unit(); }
        AirTyp* cty = lw.clo_ty(&ps[0], np, ret); if (cty == null) { return lw.unit(); }
        h.cty[j] = cty; h.hty[j] = lw.hop_ty(cty);
        h.g[j] = lw.hop_global(lw.dname(effs[j]), lw.dname(ops[j]), h.hty[j]);
        char[16] pn; snprintf(&pn[0], 16, "prev%d", (int)j);
        fc.add_field(air_ir::air_mk_field(lw.a, lw.dup(&pn[0]), h.hty[j], AMULT_UNR));
    }
    fc.add_field(air_ir::air_mk_field(lw.a, lw.dup("res"), lw.carries(th) ? th : lw.m.t_i64, AMULT_UNR));
    lw.m.add_decl(fd);
    if (!lw.live()) { return lw.unit(); }
    Vx fslot = lw.alloca_(h.frame);
    for (usz j = 0; j < h.nops; j++)
    {
        Vx gp = lw.gptr(h.g[j], h.hty[j]); Vx cur = lw.load(gp.p, h.hty[j]);
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)j, lw.m.t_i32);
        Vx slotp = lw.gep(fslot.p, h.frame, &ix[0], 2, h.hty[j]);
        lw.store(slotp.p, cur);
    }
    // the arm closures
    for (usz j = 0; j < h.nops; j++)
    {
        Node* arm = arms[j]; Node* op = ops[j];
        AirTyp*[16] ps; usz np = 0; AirTyp* ret = null; lw.op_sig(op, &ps[0], &np, &ret);
        if (lw.nfn >= MAXFN) { lw.unsup(n, "more than 4096 functions"); return lw.unit(); }
        FnInfo* f = &lw.fns[lw.nfn]; lw.nfn++; lw.nlam++;
        char[200] b; snprintf(&b[0], 200, "%s.arm%d", lw.cur_fn, (int)lw.nlam);
        f.name = lw.dup(&b[0]); f.is_lam = true; f.is_arm = true; f.decl = arm; f.hnd = (long)(h.id - 1); f.arm_j = j;
        lw.collect_caps(arm, arm, &f.caps[0], &f.ncaps);
        f.np = np + 1; f.pty[0] = lw.ptr(lw.m.t_u8);
        for (usz i = 0; i < np; i++) { f.pty[i + 1] = ps[i]; }
        f.ret = ret; f.fnty = lw.arrow(&f.pty[0], f.np, f.ret);
        char[200] en; snprintf(&en[0], 200, "Env.%s", f.name);
        char* ename = lw.dup(&en[0]);
        f.envty = lw.nominal(ename);
        AirDecl* d = air_ir::air_mk_decl(lw.a, ADECL_DATA, ename);
        AirCtorDecl* cd = air_ir::air_mk_ctor_decl(lw.a, ename); cd.result_ty = f.envty; d.add_ctor(cd);
        for (usz i = 0; i < f.ncaps; i++)
        {
            char[40] fnm2; snprintf(&fnm2[0], 40, "c%d", (int)i);
            AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
            cd.add_field(air_ir::air_mk_field(lw.a, lw.dup(&fnm2[0]), ft, AMULT_UNR));
        }
        cd.add_field(air_ir::air_mk_field(lw.a, lw.dup("frame"), lw.ptr(h.frame), AMULT_UNR));
        lw.m.add_decl(d);
        Vx eslot = lw.alloca_(f.envty);
        for (usz i = 0; i < f.ncaps; i++)
        {
            VarB* v = lw.find_var(f.caps[i].decl);
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)i, lw.m.t_i32);
            AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
            Vx g = lw.gep(eslot.p, f.envty, &ix[0], 2, ft);
            Vx val; val.p = v.p; val.t = v.t;
            if (f.caps[i].by_ref) { val.t = lw.ptr(v.t); }
            lw.store(g.p, val);
        }
        {
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)f.ncaps, lw.m.t_i32);
            Vx g = lw.gep(eslot.p, f.envty, &ix[0], 2, lw.ptr(h.frame));
            lw.store(g.p, fslot);
        }
        Vx env = lw.coerce(eslot, lw.ptr(lw.m.t_u8));
        lw.queue(f);
        Vx hv = lw.mk_hop(h.hty[j], air_ir::air_mk_var(lw.a, f.name), env.p, 1);
        Vx gp = lw.gptr(h.g[j], h.hty[j]);
        lw.store(gp.p, hv);
        afs[j] = f;
    }
    // the handled computation, with an exit block for abort-unwinding
    usz hx = lw.blk("hexit");
    char* hpn = lw.fresh("_hx");
    lw.blks[hx].pnames[0] = hpn; lw.blks[hx].ptys[0] = th; lw.blks[hx].np = lw.carries(th) ? 1 : 0;
    if (lw.nhx >= 16) { lw.unsup(n, "handle nested deeper than 16 in one function"); return lw.unit(); }
    lw.hx[lw.nhx] = hx; lw.hxt[lw.nhx] = th; lw.nhx++;
    Vx bv = lw.expr(body, th);
    lw.nhx--;
    if (lw.live())
    {
        bv = lw.coerce_arg(body, bv, th);
        if (lw.carries(th)) { Vx[1] a; a[0] = bv; lw.t_jump(hx, &a[0], 1); } else { lw.t_jump0(hx); }
    }
    if (lw.blks[hx].npred == 0) { lw.cur = NOBLK; return lw.unit(); }
    lw.cur = hx;
    for (usz j = 0; j < h.nops; j++)
    {
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)j, lw.m.t_i32);
        Vx slotp = lw.gep(fslot.p, h.frame, &ix[0], 2, h.hty[j]);
        Vx pv = lw.load(slotp.p, h.hty[j]);
        Vx gp = lw.gptr(h.g[j], h.hty[j]); lw.store(gp.p, pv);
    }
    Vx hval = lw.vref(hpn, th);
    Vx up = lw.gptr(lw.unw_global(), lw.m.t_i64);
    Vx u = lw.load(up.p, lw.m.t_i64);
    Vx mine = lw.binop(ABIN_EQ, u, lw.lit_int((long)h.id, lw.m.t_i64));
    usz caught = lw.blk("caught"); usz pass = lw.blk("pass"); usz done = lw.blk("hdone");
    char* dpn = lw.fresh("_hd");
    lw.blks[done].pnames[0] = dpn; lw.blks[done].ptys[0] = th; lw.blks[done].np = lw.carries(th) ? 1 : 0;
    lw.t_cond(mine, caught, pass);
    lw.cur = caught;
    lw.store(up.p, lw.lit_int(0, lw.m.t_i64));
    if (lw.carries(th))
    {
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)h.nops, lw.m.t_i32);
        Vx rp = lw.gep(fslot.p, h.frame, &ix[0], 2, th);
        Vx r = lw.load(rp.p, th);
        Vx[1] a; a[0] = r; lw.t_jump(done, &a[0], 1);
    }
    else { lw.t_jump0(done); }
    lw.cur = pass;
    if (lw.carries(th)) { Vx[1] a; a[0] = hval; lw.t_jump(done, &a[0], 1); } else { lw.t_jump0(done); }
    lw.cur = done;
    Vx res = lw.carries(th) ? lw.vref(dpn, th) : lw.unit();
    lw.check_unw();   // an abort aimed at an enclosing handler continues to unwind
    return res;
}
// the code of one handler arm: runs in the context OUTSIDE its handler (deep handlers)
fn void Low.lower_arm(Low* lw, FnInfo* f)
{
    Node* arm = f.decl; HndI* h = &lw.hnds[f.hnd];
    lw.cur_fn = f.name; lw.fn_errors = 0; lw.cur_node = arm;
    lw.nb = 0; lw.nvars = 0; lw.nloops = 0; lw.nnames = 0; lw.tmpn = 0; lw.unchecked = 0; lw.nhx = 0;
    lw.ret_ty = f.ret; lw.ndefer = 0; lw.in_replay = false;
    usz entry = lw.blk("entry"); lw.cur = entry;
    AirBinder*[16] pb; Vx[16] pv;
    for (usz i = 0; i < f.np; i++)
    {
        char* pnm = lw.fresh("a");
        pb[i] = air_ir::air_mk_binder(lw.a, pnm, f.pty[i], AMULT_UNR);
        pv[i] = lw.vref(pnm, f.pty[i]);
    }
    Vx ep = lw.coerce(pv[0], lw.ptr(f.envty));
    for (usz i = 0; i < f.ncaps; i++)
    {
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)i, lw.m.t_i32);
        AirTyp* ft = f.caps[i].by_ref ? lw.ptr(f.caps[i].t) : f.caps[i].t;
        Vx g = lw.gep(ep.p, f.envty, &ix[0], 2, ft);
        Vx val = lw.load(g.p, ft);
        lw.bind_var(f.caps[i].decl, val.p, f.caps[i].t, f.caps[i].by_ref);
    }
    Vx frame;
    {
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)f.ncaps, lw.m.t_i32);
        Vx g = lw.gep(ep.p, f.envty, &ix[0], 2, lw.ptr(h.frame));
        frame = lw.load(g.p, lw.ptr(h.frame));
    }
    // run in the handler's outer context: install what the handle displaced, remember what is installed now
    Vx[8] saved;
    for (usz j = 0; j < h.nops; j++)
    {
        Vx gp = lw.gptr(h.g[j], h.hty[j]);
        saved[j] = lw.load(gp.p, h.hty[j]);
        Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)j, lw.m.t_i32);
        Vx slotp = lw.gep(frame.p, h.frame, &ix[0], 2, h.hty[j]);
        Vx prev = lw.load(slotp.p, h.hty[j]);
        lw.store(gp.p, prev);
    }
    // payload and continuation binders
    usz nargs = f.np - 1; Node*[8] pats; usz npat = 0; Node* body = null; Node* bodyseq = null;
    for (usz i = 0; i < arm.child_count; i++)
    {
        Node* c = arm.children[i]; if (c == null) { continue; }
        if (c.kind == Nk.N_MODULE_PATH || c.kind == Nk.N_EXPR_PATH) { continue; }
        if (pfront_core::is_pattern(c.kind)) { if (npat < 8) { pats[npat] = c; npat++; } continue; }
        if (body != null) { bodyseq = body; }
        body = c;
    }
    Node* kdecl = null;
    if (npat > nargs) { kdecl = pats[npat - 1]; }
    for (usz i = 0; i < nargs && i < npat; i++) { lw.pat(pats[i], pv[i + 1], NOBLK); }
    if (nargs == 1 && npat == 0) { }
    lw.arm.on = true; lw.arm.kdecl = kdecl; lw.arm.opret = f.ret; lw.arm.th = h.th;
    lw.arm.flag = lw.alloca_(lw.m.t_i64).p;
    lw.store(lw.arm.flag, lw.lit_int(0, lw.m.t_i64));
    lw.arm.rv = lw.carries(f.ret) ? lw.alloca_(f.ret).p : null;
    Vx bv = lw.unit();
    if (body == null) { lw.unsup(arm, "handler arm without a body"); }
    else if (!lw.tail_ok(body, kdecl, true)) { lw.unsup(arm, "resume that is not in tail position of the handler arm (needs continuations)"); }
    else { if (bodyseq != null) { lw.expr(bodyseq, null); } bv = lw.expr(body, h.th); }
    lw.arm.on = false;
    if (lw.live())
    {
        for (usz j = 0; j < h.nops; j++) { Vx gp = lw.gptr(h.g[j], h.hty[j]); lw.store(gp.p, saved[j]); }
        Vx fl = lw.load(lw.arm.flag, lw.m.t_i64);
        Vx resumed = lw.binop(ABIN_NEQ, fl, lw.lit_int(0, lw.m.t_i64));
        usz rb = lw.blk("resumed"); usz ab = lw.blk("aborted");
        lw.t_cond(resumed, rb, ab);
        lw.cur = rb;
        if (lw.carries(f.ret)) { Vx r = lw.load(lw.arm.rv, f.ret); lw.t_ret(r); } else { lw.t_ret(lw.unit()); }
        lw.cur = ab;
        if (lw.carries(h.th))
        {
            Vx c = lw.coerce_arg(body, bv, h.th);
            Vx[2] ix; ix[0] = lw.lit_int(0, lw.m.t_i64); ix[1] = lw.lit_int((long)h.nops, lw.m.t_i32);
            Vx rp = lw.gep(frame.p, h.frame, &ix[0], 2, h.th);
            lw.store(rp.p, c);
        }
        Vx up = lw.gptr(lw.unw_global(), lw.m.t_i64);
        lw.store(up.p, lw.lit_int((long)h.id, lw.m.t_i64));
        lw.t_ret(lw.zero_of(f.ret));
    }
    if (lw.fn_errors > 0) { lw.fail_fn++; return; }
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DEF, f.name);
    ad.is_pub = true;
    for (usz i = 0; i < f.np; i++) { ad.add_param(pb[i]); }
    ad.ret_ty = f.ret; ad.def_body = lw.assemble();
    lw.m.add_decl(ad); lw.fns_ok++;
}

fn void Low.lower_fn(Low* lw, FnInfo* f)
{
    if (f.is_arm) { lw.lower_arm(f); return; }
    if (f.is_lam) { lw.lower_lambda(f); return; }
    if (f.is_ind) { lw.lower_ind(f); return; }
    if (f.is_adapt) { lw.lower_adapter(f); return; }
    Node* d = f.decl;
    lw.ntsub = 0; for (usz j = 0; j < f.nts; j++) { lw.tsub_push(f.ts[j].tp, f.ts[j].t); }
    lw.cur_fn = f.name; lw.fn_errors = 0; lw.cur_node = d;
    lw.nb = 0; lw.nvars = 0; lw.nloops = 0; lw.nhx = 0; lw.arm.on = false; lw.nnames = 0; lw.tmpn = 0;
    lw.ret_ty = f.ret; lw.ndefer = 0; lw.in_replay = false;
    usz entry = lw.blk("entry");
    lw.cur = entry;
    lw.norm_modfields(d, 0);
    lw.scan_defers(d, d);
    // parameters
    AirBinder*[16] pb;
    Vx[16] pv;
    for (usz i = 0; i < f.np; i++)
    {
        char* pnm = lw.fresh("a");
        pb[i] = air_ir::air_mk_binder(lw.a, pnm, f.pty[i], AMULT_UNR);
        pv[i] = lw.vref(pnm, f.pty[i]);
    }
    Node*[256] arms; usz narms = 0;
    Node* single_body = null;
    for (usz i = 0; i < d.child_count; i++)
    {
        Node* c = d.children[i]; if (c == null) { continue; }
        if (c.kind == Nk.N_CLAUSE && narms < 256) { arms[narms] = c; narms++; }
    }
    Vx rv = lw.unit();
    if (narms == 0 && lw.is_brace_fn(d))
    {
        usz pi = 0; Node* body = null;
        for (usz i = 0; i < d.child_count; i++)
        {
            Node* c = d.children[i]; if (c == null) { continue; }
            if (c.kind == Nk.N_DECL_PARAM)
            {
                Node* pat = c.child_count > 0 ? c.children[0] : null;
                if (pat != null && pat.kind == Nk.N_PAT_WILDCARD && c.type_ann == null && pat.type_ann == null) { continue; }
                if (pi < f.np && pat != null) { lw.pat(pat, pv[pi], NOBLK); }
                pi++;
            }
            else if (c.kind == Nk.N_BLOCK || pfront_core::is_expr(c.kind)) { body = c; }
        }
        if (body == null) { lw.unsup(d, "function without a body"); }
        else { rv = lw.expr(body, f.ret); lw.finish_ret(rv, d); }
    }
    else if (narms == 0) { lw.unsup(d, "function without clauses"); }
    else
    {
        // a single irrefutable clause binds names directly; several clauses are an arm chain
        rv = lw.arms(&arms[0], narms, &pv[0], f.np, f.ret, true);
        lw.finish_ret(rv, d);
    }
    if (lw.live() && lw.fn_errors == 0) { lw.t_end(T_TRAP); }
    if (lw.fn_errors > 0) { lw.fail_fn++; return; }
    AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DEF, f.name);
    ad.is_pub = true;
    for (usz i = 0; i < f.np; i++) { ad.add_param(pb[i]); }
    ad.ret_ty = f.ret;
    ad.def_body = lw.assemble();
    lw.m.add_decl(ad);
    lw.fns_ok++;
}

fn AirCmd* Low.blk_cmd(Low* lw, Blk* b)
{
    AirCmd* c = null;
    switch (b.tk)
    {
        case T_RET: { c = air_ir::air_new_AirCmd(lw.a); c.tag = ACMD_RET; c.prd = b.tp; break; }
        case T_JUMP: { c = air_ir::air_mk_jump(lw.a, lw.blks[b.t1].name, &b.jargs[0], b.nj); break; }
        case T_COND:
            c = air_ir::air_mk_if(lw.a, b.tp, air_ir::air_mk_jump0(lw.a, lw.blks[b.t1].name), air_ir::air_mk_jump0(lw.a, lw.blks[b.t2].name)); break;
        case T_TRAP: c = air_ir::air_mk_trap(lw.a); break;
        default: c = air_ir::air_mk_ub(lw.a, null); break;
    }
    for (usz ii = b.ni; ii > 0; ii--)
    {
        Ins* i = &b.ins[ii - 1];
        switch (i.k)
        {
            case I_LET: c = air_ir::air_mk_let(lw.a, i.name, i.a, c); break;
            case I_STORE:
            {
                AirCmd* s = air_ir::air_new_AirCmd(lw.a); s.tag = ACMD_STORE; s.add_prd(i.a); s.add_prd(i.b);
                c = air_ir::air_mk_seq(lw.a, s, c); break;
            }
            case I_CALL:
                c = air_ir::air_mk_cut(lw.a, i.a, air_ir::air_mk_call(lw.a, &i.args[0], i.nargs, air_ir::air_mk_comu_cns(lw.a, i.name, c))); break;
            case I_FIELD:
            {
                AirCns* k = air_ir::air_mk_field_cns(lw.a, i.fld, air_ir::air_mk_comu_cns(lw.a, i.name, c)); k.idx = i.idx;
                c = air_ir::air_mk_cut(lw.a, i.a, k); break;
            }
            case I_PROJ:
                c = air_ir::air_mk_cut(lw.a, i.a, air_ir::air_mk_proj(lw.a, i.idx, air_ir::air_mk_comu_cns(lw.a, i.name, c))); break;
            case I_SYS:
            {
                AirCmd* s = air_ir::air_new_AirCmd(lw.a); s.tag = ACMD_SYSCALL; s.prd = i.args[0];
                for (usz j = 1; j < i.nargs; j++) { s.add_prd(i.args[j]); }
                s.cns = air_ir::air_mk_comu_cns(lw.a, i.name, c); c = s; break;
            }
        }
    }
    return c;
}

fn AirCmd* Low.assemble(Low* lw)
{
    AirCmd* spine = lw.blk_cmd(&lw.blks[0]);
    for (usz bi = lw.nb; bi > 1; bi--)
    {
        Blk* b = &lw.blks[bi - 1];
        if (b.npred == 0) { continue; }
        AirBinder*[8] ps;
        for (usz i = 0; i < b.np; i++) { ps[i] = air_ir::air_mk_binder(lw.a, b.pnames[i], b.ptys[i], AMULT_UNR); }
        AirCmd* lb = air_ir::air_mk_label(lw.a, b.name, &ps[0], b.np, lw.blk_cmd(b));
        spine = air_ir::air_mk_seq(lw.a, lb, spine);
    }
    return spine;
}

fn Node* find_main(Node* root, pfront_core::Interner* it)
{
    if (root == null) { return null; }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* c = root.children[i];
        if (c == null || c.kind != Nk.N_DECL_FN) { continue; }
        char* nm = air_lower::node_text(c, it);
        if (nm != null && seq(nm, "main")) { return c; }
    }
    return null;
}

// emit_low_program -- lower the program reachable from `main` to FILE.low.air.
// Returns the number of lowering errors (0 = a .air was written), or -1/-2 on setup failure.
fn int emit_low_program(Node** roots, usz root_count, Node* entry_root, pfront_core::Interner* it, char* src_path, char* out_path)
{
    if (roots == null || root_count == 0) { return -2; }
    char* ovr = getenv("PFRONT_LOW_OUT");   // tests: keep the artifact out of the source tree
    if (ovr != null && ovr[0] != 0) { out_path = ovr; }
    AirArena arena;
    if (!arena.init()) { return -2; }
    AirModule mod;
    if (!mod.init(&arena, "Main", src_path)) { arena.destroy(); return -2; }
    mod.low = true;
    Low lw;
    lw.a = &arena; lw.m = &mod; lw.it = it; lw.roots = roots; lw.nroots = root_count;
    for (usz r = 0; r < root_count; r++) { for (usz i = 0; roots[r] != null && i < roots[r].child_count; i++) { Node* c = roots[r].children[i]; if (c != null && c.kind == Nk.N_DECL_EFFECT) { lw.eff_on = true; } } }
    lw.fns = (FnInfo*)calloc(MAXFN, FnInfo::size); lw.nfn = 0; lw.done_fn = 0;
    lw.sts = (StInfo*)calloc(MAXST, StInfo::size); lw.nst = 0;
    lw.gls = (GlInfo*)calloc(MAXGL, GlInfo::size); lw.ngl = 0;
    lw.blks = (Blk*)calloc(MAXBLK, Blk::size); lw.nb = 0;
    lw.vars = (VarB*)calloc(MAXVAR, VarB::size); lw.nvars = 0;
    lw.names = (char**)calloc(MAXNM, 8); lw.nnames = 0;
    lw.nfat = 0; lw.unchecked = 0; lw.nuni = 0;
    lw.ens = (Enm*)calloc(64, Enm::size); lw.nen = 0;
    lw.clos = (CloI*)calloc(128, CloI::size); lw.nclo = 0; lw.nlam = 0;
    lw.errors = 0; lw.fn_errors = 0; lw.fns_ok = 0; lw.fail_fn = 0; lw.cur = NOBLK;
    Node* mn = null;
    for (usz i = 0; i < root_count && mn == null; i++) { mn = find_main(roots[i], it); }
    if (mn != null)
    {
        lw.entry_decl = mn;
        lw.cur_fn = "main";
        FnInfo* mf = lw.fn_for(mn);
        if (mf == null) { arena.destroy(); return lw.errors > 0 ? lw.errors : 1; }
        lw.queue(mf);
    }
    else
    {
        // a library: every non-generic function of the entry module is a root
        Node* er = entry_root != null ? entry_root : roots[0];
        usz nroots_q = 0;
        for (usz i = 0; i < er.child_count; i++)
        {
            Node* c = er.children[i];
            if (c == null || c.kind != Nk.N_DECL_FN) { continue; }
            Node*[4] tpq; if (lw.typarams(c, &tpq[0]) > 0) { continue; }   // generics are instantiated by their callers
            lw.cur_fn = lw.text(c);
            FnInfo* fq = lw.fn_for(c);
            if (fq != null) { lw.queue(fq); nroots_q++; }
        }
        if (nroots_q == 0) { printf("air-low: note: no function to lower (constants only); writing an empty library module\n"); }
    }
    // worklist: functions are lowered as they are first referenced
    bool progress = true;
    while (progress)
    {
        progress = false;
        for (usz i = 0; i < lw.nfn; i++)
        {
            FnInfo* f = &lw.fns[i];
            if (!f.queued) { continue; }
            f.queued = false; progress = true;
            if (f.ext)
            {
                bool dup_decl = false;   // two source declarations of one C symbol: one declaration
                for (usz di = 0; di < lw.m.decl_count; di++) { AirDecl* od = lw.m.decls[di]; if (od != null && od.tag == ADECL_DECLARE && seq(od.name, f.name)) { dup_decl = true; } }
                if (dup_decl) { continue; }
                AirDecl* ad = air_ir::air_mk_decl(lw.a, ADECL_DECLARE, f.name);
                ad.is_extern = true; ad.ret_ty = f.ret; ad.is_varargs = f.variadic;
                for (usz k = 0; k < f.np; k++) { ad.add_param(air_ir::air_mk_binder(lw.a, lw.dup("_"), f.pty[k], AMULT_UNR)); }
                lw.m.add_decl(ad);
                continue;
            }
            lw.lower_fn(f);
        }
    }
    int errs = lw.errors;
    if (errs == 0)
    {
        int w = air_write::write_module(&mod, out_path);
        if (w != 0) { printf("air-low: %d writer error(s)\n", w); errs = w; }
        else { printf("air-low: %d function(s) lowered -> %s\n", lw.fns_ok, out_path); }
    }
    else { printf("air-low: %d error(s) in %d function(s); no .air written\n", errs, lw.fail_fn); }
    arena.destroy();
    return errs;
}
