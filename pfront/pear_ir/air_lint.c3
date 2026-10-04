// ============================================================================
// air_lint.c3 -- "is this .air as low-level and self-contained as an .ll?"
//
// verify (air_verify.c3) answers "is the file well formed". lint answers the
// question a backend author cares about: how much of the work that a real IR
// has already done is STILL LEFT to the consumer. Each rule is a deficiency of
// the producer, not of the source program. The target is every counter at 0 for
// every program (profile "low", docs/pear2/AIR3_PLAN.md). Rules:
//
//   T1  a def parameter whose type is missing or `infer`
//   T2  a def return type that is missing or `infer`
//   T3  an integer/float literal without a concrete type
//   T4  a binary/unary operation without a concrete result type
//   T5  an aggregate (record/tuple/array) without a concrete type
//   T6  a high-level type constructor in a signature or annotation
//       (forall/self/generic application/union/intersection/negation/refinement/
//       typeof/effect row/bang/query/path/tvar): the consumer cannot size it
//   M1  a name bound twice in one def -- a mutable variable modelled as
//       "rebind the binder", which has no meaning across a join
//   H1  effects: perform / handle / resume (needs a runtime or a CPS lowering)
//   H2  lam / cometa: a closure with no explicit environment
//   H3  staging: quote / eval / reify / splice (must be gone before AIR)
//   H4  a generic declaration (type parameters not instantiated)
//   H5  a pattern the consumer would have to compile to a decision tree
//       (constructor/tuple/record/array/as/or/ref/rest/string/float pattern)
//   H6  a branch guard
//   H7  comptime / defer blocks left in the body
//   H8  data / codata declarations (the consumer must invent the layout); in a low module only codata, generic data and multi-constructor data
//   H9  a `field` whose declaration slot is unresolved (index < 0)
// ============================================================================
module air_lint;
import air_ir;
import air_text;

extern fn void* malloc(usz n);
extern fn void  free(void* p);

const usz LINT_RULES = 20;
const usz LINT_MAXNAMES = 16384;

fn char* rule_name(usz i)
{
    switch (i)
    {
        case 0:  return "T1 untyped parameter";
        case 1:  return "T2 untyped return";
        case 2:  return "T3 untyped literal";
        case 3:  return "T4 untyped operation";
        case 4:  return "T5 untyped aggregate";
        case 5:  return "T6 high-level type";
        case 6:  return "M1 rebound name";
        case 7:  return "H1 effects";
        case 8:  return "H2 closure";
        case 9:  return "H3 staging";
        case 10: return "H4 generic decl";
        case 11: return "H5 complex pattern";
        case 12: return "H6 guard";
        case 13: return "H7 comptime/defer";
        case 14: return "H8 data/codata decl";
        case 15: return "H9 unresolved field slot";
        default: return "";
    }
}

struct Lint
{
    int[LINT_RULES] counts;
    usz             only_entry;   // 1: count only the entry module (before the first `module` marker)
    char**          seen;
    usz             nseen;
    bool            low;          // AIR 3.0 module: a single-constructor, non-generic `data` IS the struct layout (not H8)
}

fn bool lint_untyped(AirTyp* t)
{
    return t == null || t.tag == ATYP_INFER || t.tag == ATYP_INVALID;
}

fn bool lint_high_type(AirTyp* t, int depth)
{
    if (t == null || depth > 16) { return false; }
    switch (t.tag)
    {
        case ATYP_FORALL: case ATYP_EXISTS: case ATYP_SELF: case ATYP_GENERIC_APP: case ATYP_UNION:
        case ATYP_INTERSECT: case ATYP_NEGATION: case ATYP_REFINE: case ATYP_TYPEOF: case ATYP_EFFROW:
        case ATYP_BANG: case ATYP_QUERY: case ATYP_PATH: case ATYP_VAR: case ATYP_MULT:
            return true;
        default: break;
    }
    for (usz i = 0; i < t.arg_count; i++) { if (lint_high_type(t.args[i], depth + 1)) { return true; } }
    return false;
}

fn void Lint.type_use(Lint* l, AirTyp* t)
{
    if (lint_high_type(t, 0)) { l.counts[5]++; }
}

fn void Lint.bind(Lint* l, char* nm)
{
    if (nm == null || nm[0] == 0 || nm[0] == '%') { return; }
    if (nm[0] == '_' && nm[1] == 0) { return; }
    for (usz i = 0; i < l.nseen; i++)
    {
        if (air_text::streq(l.seen[i], nm)) { l.counts[6]++; return; }
    }
    if (l.nseen < LINT_MAXNAMES) { l.seen[l.nseen] = nm; l.nseen++; }
}

fn void Lint.pat(Lint* l, AirPat* p)
{
    if (p == null) { return; }
    switch (p.tag)
    {
        case APAT_WILD: case APAT_INT: case APAT_BOOL: case APAT_CHAR: break;
        case APAT_BIND: l.bind(p.name); break;
        default: l.counts[11]++; break;
    }
    if (p.tag == APAT_AS) { l.bind(p.name); }
    for (usz i = 0; i < p.sub_count; i++) { l.pat(p.sub[i]); }
    l.pat(p.as_pat); l.pat(p.or_alt);
}

fn void Lint.prd(Lint* l, AirPrd* p)
{
    if (p == null) { return; }
    switch (p.tag)
    {
        case APRD_INT: case APRD_FLOAT: if (lint_untyped(p.ty)) { l.counts[2]++; } break;
        case APRD_BINOP: case APRD_UNOP: if (lint_untyped(p.ty)) { l.counts[3]++; } break;
        case APRD_RECORD: case APRD_TUPLE: case APRD_ARRAY: if (lint_untyped(p.ty)) { l.counts[4]++; } break;
        case APRD_LAMBDA: case APRD_COMETA: l.counts[8]++; break;
        case APRD_QUOTE: case APRD_EVAL: case APRD_REIFY: case APRD_SPLICE: l.counts[9]++; break;
        default: break;
    }
    l.type_use(p.ty); l.type_use(p.ty_arg);
    if (p.tag == APRD_LAMBDA || p.tag == APRD_COMETA)
    {
        for (usz i = 0; i < p.binder_count; i++) { if (p.binders[i] != null) { l.bind(p.binders[i].name); } }
    }
    if (p.tag == APRD_MU) { }
    for (usz i = 0; i < p.sub_count; i++) { l.prd(p.subs[i]); }
    for (usz i = 0; i < p.rec_init_count; i++) { if (p.rec_inits[i] != null) { l.prd(p.rec_inits[i].value); } }
    l.cmd(p.body);
}

fn void Lint.cns(Lint* l, AirCns* k)
{
    if (k == null) { return; }
    if (k.tag == ACNS_COMU) { l.bind(k.bind); }
    if (k.tag == ACNS_FIELD && k.idx < 0) { l.counts[15]++; }
    l.type_use(k.ty);
    l.prd(k.prd);
    l.cns(k.tail);
    for (usz i = 0; i < k.branch_count; i++)
    {
        AirBranch* b = k.branches[i];
        if (b == null) { continue; }
        l.pat(b.pat);
        if (b.guard != null) { l.counts[12]++; l.cmd(b.guard); }
        l.cmd(b.body);
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        AirCoBranch* cb = k.cobranches[i];
        if (cb != null) { l.cmd(cb.body); }
    }
    l.cmd(k.body);
}

fn void Lint.cmd(Lint* l, AirCmd* c)
{
    if (c == null) { return; }
    switch (c.tag)
    {
        case ACMD_PERFORM: case ACMD_HANDLE: case ACMD_RESUME: l.counts[7]++; break;
        case ACMD_COMPTIME: case ACMD_DEFER: l.counts[13]++; break;
        case ACMD_LET: case ACMD_FOR: l.bind(c.binder); break;
        default: break;
    }
    for (usz i = 0; i < c.mbinder_count; i++) { if (c.mbinders[i] != null) { l.bind(c.mbinders[i].name); } }
    l.type_use(c.poison_ty);
    l.prd(c.prd);
    l.cns(c.cns);
    for (usz i = 0; i < c.prd_count; i++) { l.prd(c.prds[i]); }
    l.cmd(c.body); l.cmd(c.next); l.cmd(c.then_c); l.cmd(c.else_c); l.cmd(c.handled);
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b == null) { continue; }
        l.pat(b.pat);
        if (b.guard != null) { l.counts[12]++; l.cmd(b.guard); }
        l.cmd(b.body);
    }
}

fn void Lint.decl(Lint* l, AirDecl* d)
{
    if (d == null) { return; }
    if (l.low && d.tag == ADECL_DATA && d.ctor_count == 1 && d.typaram_count == 0) { return; }
    if (d.tag == ADECL_DATA || d.tag == ADECL_CODATA) { l.counts[14]++; return; }
    if (d.tag != ADECL_DEF && d.tag != ADECL_DEFCO && d.tag != ADECL_DECLARE) { return; }
    if (d.typaram_count > 0) { l.counts[10]++; }
    for (usz i = 0; i < d.param_count; i++)
    {
        if (d.params[i] == null) { continue; }
        if (lint_untyped(d.params[i].ty)) { l.counts[0]++; }
        l.type_use(d.params[i].ty);
    }
    if (lint_untyped(d.ret_ty)) { l.counts[1]++; }
    l.type_use(d.ret_ty);
    l.nseen = 0;
    for (usz i = 0; i < d.param_count; i++) { if (d.params[i] != null) { l.bind(d.params[i].name); } }
    l.cmd(d.def_body);
}

// Fills counts[0..LINT_RULES). entry_only: stop at the first `module NAME;` marker.
// Returns the total.
fn int lint_module(AirModule* m, int* counts, bool entry_only)
{
    Lint* l = (Lint*)malloc(Lint::size);
    if (l == null) { return -1; }
    for (usz i = 0; i < LINT_RULES; i++) { l.counts[i] = 0; }
    l.seen = (char**)malloc(8 * LINT_MAXNAMES);
    l.nseen = 0; l.low = m.low;
    if (l.seen == null) { free((void*)l); return -1; }
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        if (d.tag == ADECL_MODULE && entry_only) { break; }
        l.decl(d);
    }
    int total = 0;
    for (usz i = 0; i < LINT_RULES; i++) { counts[i] = l.counts[i]; total = total + l.counts[i]; }
    free((void*)l.seen); free((void*)l);
    return total;
}
