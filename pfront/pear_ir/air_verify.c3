// ============================================================================
// air_verify.c3 — well-formedness checks for AIR 2.0 (what a producer must
// guarantee and a consumer may rely on). The rules are the ones listed in
// docs/specs/AIR.md section "Validity"; every rule here is checked against the
// whole test corpus, and a rule that the real producer violates is NOT claimed:
// it is listed in the spec as a known deviation instead.
//
// Checks (V = violation class, printed with the declaration name):
//   V1  covariable use is bound: a consumer covariable is `%ret`/`%ret_N`, the
//       hole `·`, or bound by an enclosing `mu`, `mu~`, `comu`, `label` or
//       cobranch binder. EXCEPTION (convention J1, counted not failed): `%kN`
//       is an implicit join continuation: the code that follows the jump in the
//       enclosing `seq` is its body. The producer never binds it.
//       `%resume` (convention J2): inside an effect handler clause the resume
//       continuation is implicit. Effects are not executable end to end yet
//       (ledger P04-P06): a consumer must treat `%resume` as unsupported.
//   V2  jump/break/continue target is a `label` of the same def that is
//       visible: its own body, or the rest of the `seq` that defines it (labels
//       are block definitions laid out by `seq`; jumps enter them).
//   V3  every variable use names a binder somewhere in the same declaration
//       (parameter, let, letrec, lambda, comu, mu~, pattern bind, label
//       parameter) or a top-level declaration / constructor of the program.
//       The scope is deliberately FLAT per declaration: see "Scoping" in the
//       spec — the producer binds with `comu x. nop` and uses x in the commands
//       that follow in the enclosing `seq`.
//   Conventions the producer relies on and a consumer must implement (counted,
//   not failed): J1 implicit `%kN` joins (above); N1 a variable that is
//   unbound but is the receiver of a `field` chain is a MODULE-PATH ROOT
//   (`os.linux.PROT_READ`): resolved by name against the loaded modules.
//   V4  a `def` has a body, a `declare` has none, names are present.
//   V5  (modules of the low profile only, AIR 3.0) the low-profile rules that need no LLVM: declaration attributes are known, carry
//       the argument they need and sit on a declaration they mean something for; a `naked` def has no parameters and an `asm`;
//       data is a single-constructor struct (no enum layout, no type parameters); atomic operation/order and fence order are in
//       range; an `asm` has a template, constraints and a result type. (`airtool verify-low` additionally runs the type walk.)
// ============================================================================
module air_verify;
import air_ir;
import air_text;

extern fn int   fprintf(void* f, char* fmt, ...);
extern fn void* fdopen(int fd, char* mode);
extern fn int   fflush(void* f);
extern fn void* malloc(usz n);
extern fn void  free(void* p);

const usz VMAX = 8192;

struct Verify
{
    AirModule* m;
    AirDecl*   d;
    char*[VMAX] cov;      // covariable scope stack (lexical)
    usz         ncov;
    char*[VMAX] lab;      // label scope stack (lexical)
    usz         nlab;
    char*[VMAX] bound;    // every variable binder seen in this decl (flat)
    usz         nbound;
    int[8]      counts;   // [0..3] violations V1..V4; [4] J1 implicit joins; [5] N1 module-path roots; [6] J2 `%resume`; [7] violations V5
    bool        saw_asm;
    bool        field_recv;   // the variable use being checked is a field-chain receiver
    int         shown;
    int         limit;
    bool        quiet;
}

fn bool Verify.is_hole(Verify* v, char* nm)
{
    return nm != null && (uint)nm[0] == 0xC2 && (uint)nm[1] == 0xB7;
}
fn bool Verify.is_ret(Verify* v, char* nm)
{
    if (nm == null || nm[0] != '%' || nm[1] != 'r' || nm[2] != 'e' || nm[3] != 't') { return false; }
    return nm[4] == 0 || nm[4] == '_';
}
fn void Verify.viol(Verify* v, int cls, char* what, char* nm)
{
    v.counts[(usz)cls]++;
    if (!v.quiet && v.shown < v.limit)
    {
        v.shown++;
        void* se = fdopen(2, "w");
        fprintf(se, "air-verify: V%d in `%s`: %s `%s`\n", cls + 1, v.d.name == null ? "?" : v.d.name, what, nm == null ? "nil" : nm);
        fflush(se);
    }
}
fn void Verify.viol5(Verify* v, char* what, char* nm)
{
    v.counts[7]++;
    if (!v.quiet && v.shown < v.limit)
    {
        v.shown++;
        void* se = fdopen(2, "w");
        fprintf(se, "air-verify: V5 in `%s`: %s `%s`\n", v.d.name == null ? "?" : v.d.name, what, nm == null ? "nil" : nm);
        fflush(se);
    }
}
fn bool Verify.in_stack(Verify* v, char** st, usz n, char* nm)
{
    for (usz i = n; i > 0; i--) { if (air_text::streq(st[i - 1], nm)) { return true; } }
    return false;
}
fn void Verify.bind_var(Verify* v, char* nm)
{
    if (nm == null) { return; }
    if (v.nbound < VMAX) { v.bound[v.nbound] = nm; v.nbound++; }
}
fn bool Verify.global(Verify* v, char* nm)
{
    for (usz i = 0; i < v.m.decl_count; i++)
    {
        AirDecl* d = v.m.decls[i];
        if (d == null) { continue; }
        if (air_text::streq(d.name, nm)) { return true; }
        for (usz j = 0; j < d.ctor_count; j++) { if (d.ctors[j] != null && air_text::streq(d.ctors[j].name, nm)) { return true; } }
        for (usz j = 0; j < d.op_count; j++) { if (d.ops[j] != null && air_text::streq(d.ops[j].name, nm)) { return true; } }
        for (usz j = 0; j < d.dtor_count; j++) { if (d.dtors[j] != null && air_text::streq(d.dtors[j].name, nm)) { return true; } }
    }
    return false;
}

// Pass 1: collect every variable binder of the declaration (flat scope).
fn void Verify.collect_pat(Verify* v, AirPat* p)
{
    if (p == null) { return; }
    if (p.tag == APAT_BIND) { v.bind_var(p.name); }
    if (p.tag == APAT_AS) { v.bind_var(p.name); }
    for (usz i = 0; i < p.sub_count; i++) { v.collect_pat(p.sub[i]); }
    v.collect_pat(p.or_alt);
}
fn void Verify.collect_prd(Verify* v, AirPrd* p)
{
    if (p == null) { return; }
    if (p.tag == APRD_LAMBDA || p.tag == APRD_COMETA) { for (usz i = 0; i < p.binder_count; i++) { if (p.binders[i] != null) { v.bind_var(p.binders[i].name); } } }
    if (p.tag == APRD_MU) { v.bind_var(p.name); }
    for (usz i = 0; i < p.sub_count; i++) { v.collect_prd(p.subs[i]); }
    for (usz i = 0; i < p.rec_init_count; i++) { if (p.rec_inits[i] != null) { v.collect_prd(p.rec_inits[i].value); } }
    v.collect_cmd(p.body);
}
fn void Verify.collect_cns(Verify* v, AirCns* k)
{
    if (k == null) { return; }
    if (k.tag == ACNS_COMU) { v.bind_var(k.bind); }
    v.collect_prd(k.prd);
    v.collect_cns(k.tail);
    for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null) { v.collect_pat(k.branches[i].pat); v.collect_cmd(k.branches[i].body); v.collect_cmd(k.branches[i].guard); } }
    for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null) { for (usz j = 0; j < k.cobranches[i].binder_count; j++) { v.bind_var(k.cobranches[i].binders[j]); } v.collect_cmd(k.cobranches[i].body); } }
    v.collect_cmd(k.body);
}
fn void Verify.collect_cmd(Verify* v, AirCmd* c)
{
    if (c == null) { return; }
    if (c.tag == ACMD_MU || c.tag == ACMD_MUTILDE || c.tag == ACMD_LET || c.tag == ACMD_FOR) { v.bind_var(c.binder); }
    for (usz i = 0; i < c.mbinder_count; i++) { if (c.mbinders[i] != null) { v.bind_var(c.mbinders[i].name); } }
    v.collect_prd(c.prd);
    v.collect_cns(c.cns);
    for (usz i = 0; i < c.prd_count; i++) { v.collect_prd(c.prds[i]); }
    v.collect_cmd(c.body); v.collect_cmd(c.next); v.collect_cmd(c.then_c); v.collect_cmd(c.else_c); v.collect_cmd(c.handled);
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null) { v.collect_pat(c.branches[i].pat); v.collect_cmd(c.branches[i].body); v.collect_cmd(c.branches[i].guard); } }
}

// Pass 2: check uses with lexical covariable/label scopes.
fn void Verify.use_var(Verify* v, char* nm)
{
    if (nm == null) { return; }
    if (v.in_stack(&v.bound[0], v.nbound, nm)) { return; }
    if (v.global(nm)) { return; }
    if (v.field_recv) { v.counts[5]++; return; }
    v.viol(2, "variable is not bound in its declaration and is not a top-level name:", nm);
}
fn void Verify.chk_prd(Verify* v, AirPrd* p)
{
    if (p == null) { return; }
    if (p.tag == APRD_VAR) { v.use_var(p.name); v.field_recv = false; }
    usz mark = v.ncov;
    if (p.tag == APRD_MU && v.ncov < VMAX) { v.cov[v.ncov] = p.name; v.ncov++; }
    for (usz i = 0; i < p.sub_count; i++) { v.chk_prd(p.subs[i]); }
    for (usz i = 0; i < p.rec_init_count; i++) { if (p.rec_inits[i] != null) { v.chk_prd(p.rec_inits[i].value); } }
    v.chk_cmd(p.body);
    v.ncov = mark;
}
fn void Verify.chk_cns(Verify* v, AirCns* k)
{
    if (k == null) { return; }
    if (k.tag == ACNS_COVAR)
    {
        char* nm = k.name;
        if (nm != null && nm[0] == '%' && nm[1] == 'k' && nm[2] >= '0' && nm[2] <= '9' && !v.in_stack(&v.cov[0], v.ncov, nm)) { v.counts[4]++; }
        else if (nm != null && air_text::streq(nm, "%resume") && !v.in_stack(&v.cov[0], v.ncov, nm)) { v.counts[6]++; }
        else if (!v.is_ret(nm) && !v.is_hole(nm) && !v.in_stack(&v.cov[0], v.ncov, nm) && !v.in_stack(&v.lab[0], v.nlab, nm))
        {
            v.viol(0, "covariable is not bound by an enclosing mu/mu~/comu/label:", nm);
        }
    }
    v.chk_prd(k.prd);
    usz mark = v.ncov;
    if (k.tag == ACNS_COMU && v.ncov < VMAX) { v.cov[v.ncov] = k.bind; v.ncov++; }
    v.chk_cns(k.tail);
    for (usz i = 0; i < k.branch_count; i++)
    {
        AirBranch* b = k.branches[i];
        if (b != null) { v.chk_guard(b.guard); v.chk_cmd(b.body); }
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        AirCoBranch* cb = k.cobranches[i];
        if (cb == null) { continue; }
        usz m2 = v.ncov;
        for (usz j = 0; j < cb.binder_count && v.ncov < VMAX; j++) { v.cov[v.ncov] = cb.binders[j]; v.ncov++; }
        v.chk_cmd(cb.body);
        v.ncov = m2;
    }
    v.chk_cmd(k.body);
    v.ncov = mark;
}
// A branch guard is checked with the implicit covariable %guard in scope (AIR.md section 7b).
fn void Verify.chk_guard(Verify* v, AirCmd* g)
{
    if (g == null) { return; }
    usz mark = v.ncov;
    if (v.ncov < VMAX) { v.cov[v.ncov] = (char*)"%guard"; v.ncov++; }
    v.chk_cmd(g);
    v.ncov = mark;
}
fn void Verify.chk_cmd(Verify* v, AirCmd* c)
{
    if (c == null) { return; }
    usz cmark = v.ncov; usz lmark = v.nlab;
    if ((c.tag == ACMD_MU || c.tag == ACMD_MUTILDE) && v.ncov < VMAX) { v.cov[v.ncov] = c.binder; v.ncov++; }
    if (c.tag == ACMD_LABEL)
    {
        if (v.nlab < VMAX) { v.lab[v.nlab] = c.binder; v.nlab++; }
        if (v.ncov < VMAX) { v.cov[v.ncov] = c.binder; v.ncov++; }
    }
    if (c.tag == ACMD_JUMP || c.tag == ACMD_BREAK || c.tag == ACMD_CONTINUE)
    {
        // break/continue name the label they leave/repeat; an unnamed one targets the innermost loop
        if (c.target_label != null && !v.in_stack(&v.lab[0], v.nlab, c.target_label) && !v.in_stack(&v.cov[0], v.ncov, c.target_label))
        {
            v.viol(1, "jump target is not an enclosing label:", c.target_label);
        }
        for (usz i = 0; i < c.jump_arg_count; i++) { v.use_var(c.jump_args[i]); }
    }
    v.field_recv = (c.cns != null && c.cns.tag == ACNS_FIELD);
    v.chk_prd(c.prd);
    v.field_recv = false;
    v.chk_cns(c.cns);
    for (usz i = 0; i < c.prd_count; i++) { v.chk_prd(c.prds[i]); }
    if (c.tag == ACMD_SEQ)
    {
        // a label defined at the head of the first half is visible in the second half
        v.chk_cmd(c.body);
        if (c.body != null && c.body.tag == ACMD_LABEL && v.nlab < VMAX) { v.lab[v.nlab] = c.body.binder; v.nlab++; }
        v.chk_cmd(c.next);
        v.ncov = cmark; v.nlab = lmark;
        return;
    }
    v.chk_cmd(c.body); v.chk_cmd(c.next); v.chk_cmd(c.then_c); v.chk_cmd(c.else_c); v.chk_cmd(c.handled);
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b != null) { v.chk_guard(b.guard); v.chk_cmd(b.body); }
    }
    v.ncov = cmark; v.nlab = lmark;
}

// AIR 3.0 (low profile): the labels of a body form one control-flow graph, so a jump may target any label of the same def
// (docs/specs/AIR3.md "Labels"); they are all visible from the start.
fn void Verify.collect_labels(Verify* v, AirCmd* c)
{
    if (c == null) { return; }
    if (c.tag == ACMD_LABEL && c.binder != null && v.nlab < VMAX) { v.lab[v.nlab] = c.binder; v.nlab++; }
    v.collect_labels(c.body); v.collect_labels(c.next); v.collect_labels(c.then_c); v.collect_labels(c.else_c); v.collect_labels(c.handled);
    for (usz i = 0; i < c.branch_count; i++) { AirBranch* b = c.branches[i]; if (b != null) { v.collect_labels(b.body); } }
}

fn void Verify.low_cmd(Verify* v, AirCmd* c)
{
    if (c == null) { return; }
    if (c.tag == ACMD_ASM)
    {
        v.saw_asm = true;
        if (c.asm_text == null || c.asm_cons == null || c.asm_ret == null) { v.viol5("asm without a template, constraints or result type:", null); }
    }
    if (c.tag == ACMD_ATOMIC && (c.atomic_op < 0 || c.atomic_op > 13 || c.atomic_order < 0 || c.atomic_order > 4)) { v.viol5("atomic operation or memory order out of range:", null); }
    if (c.tag == ACMD_FENCE && (c.atomic_order < 1 || c.atomic_order > 4)) { v.viol5("fence order must be acquire, release, acq_rel or seq_cst:", null); }
    v.low_cmd(c.body); v.low_cmd(c.next); v.low_cmd(c.then_c); v.low_cmd(c.else_c); v.low_cmd(c.handled);
    for (usz i = 0; i < c.branch_count; i++) { AirBranch* b = c.branches[i]; if (b != null) { v.low_cmd(b.body); } }
}
fn bool known_attr(char* n)
{
    char*[11] ok = { "section", "align", "packed", "thread_local", "naked", "noinline", "inline", "cold", "noredzone", "no_builtins", null };
    for (usz i = 0; ok[i] != null; i++) { if (air_text::streq(ok[i], n)) { return true; } }
    return false;
}
fn void Verify.low_decl(Verify* v, AirDecl* d)
{
    bool is_def = d.tag == ADECL_DEF; bool is_glob = d.tag == ADECL_GLOBAL; bool is_data = d.tag == ADECL_DATA;
    if (d.tag == ADECL_CODATA) { v.viol5("codata in the low profile:", d.name); }
    if (is_data)
    {
        if (d.typaram_count > 0) { v.viol5("generic data in the low profile:", d.name); }
        if (d.ctor_count != 1) { v.viol5("data with several constructors (enum layout) in the low profile:", d.name); }
    }
    bool has_inline = false; bool has_noinline = false;
    for (usz i = 0; i < d.attr_count; i++)
    {
        char* n = d.attr_name[i];
        if (n == null || !known_attr(n)) { v.viol5("unknown attribute:", n); continue; }
        for (usz j = 0; j < i; j++) { if (air_text::streq(d.attr_name[j], n)) { v.viol5("attribute given twice:", n); } }
        bool s = air_text::streq(n, "section"); bool a = air_text::streq(n, "align");
        if (s || a)
        {
            if (!is_def && !is_glob) { v.viol5("section/align apply to functions and globals:", n); }
            if (s && (d.attr_str[i] == null || d.attr_str[i][0] == 0)) { v.viol5("section needs a non-empty string:", d.name); }
            if (s && d.attr_str[i] != null) { for (usz k = 0; d.attr_str[i][k] != 0; k++) { if (d.attr_str[i][k] == '"') { v.viol5("section name contains a quote:", d.name); } } }
            if (a && (!d.attr_has_int[i] || d.attr_int[i] <= 0 || (d.attr_int[i] & (d.attr_int[i] - 1)) != 0)) { v.viol5("align needs a power of two:", d.name); }
        }
        else if (air_text::streq(n, "packed")) { if (!is_data) { v.viol5("packed applies to data:", d.name); } }
        else if (air_text::streq(n, "thread_local")) { if (!is_glob || !d.g_mut) { v.viol5("thread_local applies to a mutable global:", d.name); } }
        else { if (!is_def) { v.viol5("function attribute on something that is not a def:", n); } }
        if (air_text::streq(n, "inline")) { has_inline = true; }
        if (air_text::streq(n, "noinline")) { has_noinline = true; }
    }
    if (has_inline && has_noinline) { v.viol5("inline and noinline together:", d.name); }
    v.saw_asm = false;
    if (is_def) { v.low_cmd(d.def_body); }
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (is_def && d.attr_name[i] != null && air_text::streq(d.attr_name[i], "naked"))
        {
            if (d.param_count != 0) { v.viol5("a naked function has no parameters:", d.name); }
            if (!v.saw_asm) { v.viol5("a naked function must be assembly:", d.name); }
        }
    }
}

// Returns the total number of violations (0 = valid). counts[0..3] = V1..V4.
fn int verify_module(AirModule* m, int* counts_out, bool quiet, int limit)
{
    Verify* v = (Verify*)malloc(Verify::size);
    if (v == null) { return -1; }
    v.m = m; v.quiet = quiet; v.limit = limit; v.shown = 0;
    for (usz i = 0; i < 8; i++) { v.counts[i] = 0; }
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        v.d = d; v.ncov = 0; v.nlab = 0; v.nbound = 0;
        if (m.low) { v.low_decl(d); }
        if (d.tag == ADECL_DEF || d.tag == ADECL_DEFCO || d.tag == ADECL_DECLARE)
        {
            if (d.name == null) { v.viol(3, "declaration without a name:", null); }
            if (d.tag == ADECL_DEF && d.def_body == null) { v.viol(3, "def without a body:", d.name); }
            if (d.tag == ADECL_DECLARE && d.def_body != null) { v.viol(3, "declare with a body:", d.name); }
            for (usz j = 0; j < d.param_count; j++) { if (d.params[j] != null) { v.bind_var(d.params[j].name); } }
            v.collect_cmd(d.def_body);
            if (m.low) { v.collect_labels(d.def_body); }
            v.chk_cmd(d.def_body);
        }
    }
    int total = v.counts[0] + v.counts[1] + v.counts[2] + v.counts[3] + v.counts[7];
    if (counts_out != null) { for (usz i = 0; i < 8; i++) { counts_out[i] = v.counts[i]; } }
    free((void*)v);
    return total;
}

