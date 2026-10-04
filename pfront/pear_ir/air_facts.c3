// Conservative post-lowering contract screen. Unknown is never a promise.
// The final AST supplies candidates; this AIR dataflow check can only remove
// them. It models the emitted scalar fragment, not arbitrary Pride semantics.
module air_facts;
import air_ir;

extern fn void* calloc(usz n, usz size);
extern fn void free(void* p);

const usz FACT_VARS = 1024;
const usz FACT_STEPS = 200000;
const int FACT_DEPTH = 200;
const int FACT_ROUNDS = 24;

struct FactScan
{
    air_ir::AirModule* mod;
    air_ir::AirDecl* decl;
    char*[FACT_VARS] names;
    ulong[FACT_VARS] deps;
    usz vars;
    usz steps;
    ulong escaped;
    ulong control;
    bool writes;
    bool complete;
    bool changed;
}

fn bool same(char* a, char* b)
{
    if (a == null || b == null) { return false; }
    usz i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}

fn bool FactScan.step(FactScan* s, int depth)
{
    s.steps++;
    if (depth > FACT_DEPTH || s.steps > FACT_STEPS) { s.complete = false; return false; }
    return true;
}

fn ulong FactScan.lookup(FactScan* s, char* name)
{
    for (usz i = 0; i < s.vars; i++) { if (same(s.names[i], name)) { return s.deps[i]; } }
    return 0;
}

fn void FactScan.bind(FactScan* s, char* name, ulong mask)
{
    if (name == null || mask == 0) { return; }
    for (usz i = 0; i < s.vars; i++)
    {
        if (same(s.names[i], name))
        {
            ulong joined = s.deps[i] | mask;
            if (joined != s.deps[i]) { s.deps[i] = joined; s.changed = true; }
            return;
        }
    }
    if (s.vars >= FACT_VARS) { s.complete = false; return; }
    s.names[s.vars] = name; s.deps[s.vars] = mask; s.vars++; s.changed = true;
}

fn air_ir::AirDecl* FactScan.callee(FactScan* s, char* name)
{
    air_ir::AirDecl* found = null;
    for (usz i = 0; i < s.mod.decl_count; i++)
    {
        air_ir::AirDecl* d = s.mod.decls[i];
        if (d == null || d.tag != air_ir::AirDeclTag.ADECL_DEF || !same(d.name, name)) { continue; }
        // Bare-name collisions are not evidence of a unique analyzed callee.
        if (found != null) { return null; }
        found = d;
    }
    if (found == null || found.fact_state == air_ir::AirFactState.AFACT_UNKNOWN) { return null; }
    return found;
}

fn ulong FactScan.prd(FactScan* s, air_ir::AirPrd* p, int depth)
{
    if (p == null) { return 0; }
    if (!s.step(depth)) { return 0; }
    switch (p.tag)
    {
        case APRD_VAR: return s.lookup(p.name);
        case APRD_INT: case APRD_FLOAT: case APRD_BOOL: case APRD_CHAR:
        case APRD_STRING: case APRD_BYTES: case APRD_UNIT: case APRD_NULL:
            return 0;
        case APRD_BINOP: case APRD_COERCE: case APRD_UNOP:
        case APRD_TUPLE: case APRD_ARRAY: case APRD_INL: case APRD_INR:
        {
            ulong mask = 0;
            for (usz i = 0; i < p.sub_count; i++) { mask |= s.prd(p.subs[i], depth + 1); }
            if (p.sub_count > 16) { s.complete = false; }
            return mask;
        }
        case APRD_RECORD:
        {
            ulong mask = 0;
            for (usz i = 0; i < p.rec_init_count; i++)
            {
                if (p.rec_inits[i] != null) { mask |= s.prd(p.rec_inits[i].value, depth + 1); }
            }
            if (p.rec_init_count > 16) { s.complete = false; }
            return mask;
        }
        case APRD_CON:
            if (p.sub_count == 0) { return s.lookup(p.name); }
            s.complete = false; return 0;
        default:
            // Closures, embedded mu/eval/quotes and unknown producers need a
            // richer semantic model. Do not fabricate a no-write/no-capture fact.
            s.complete = false;
            return 0;
    }
}

fn void FactScan.branches(FactScan* s, air_ir::AirBranch** bs, usz count, ulong scrutinee, int depth)
{
    if (count > 64) { s.complete = false; return; }
    s.control |= scrutinee;
    for (usz i = 0; i < count; i++)
    {
        air_ir::AirBranch* br = bs[i];
        if (br == null || br.pat == null || br.guard != null) { s.complete = false; continue; }
        if (br.pat.tag == air_ir::AirPatTag.APAT_BIND) { s.bind(br.pat.name, scrutinee); }
        else if (br.pat.tag != air_ir::AirPatTag.APAT_WILD && br.pat.tag != air_ir::AirPatTag.APAT_INT
                 && br.pat.tag != air_ir::AirPatTag.APAT_BOOL && br.pat.tag != air_ir::AirPatTag.APAT_CHAR
                 && !(br.pat.tag == air_ir::AirPatTag.APAT_TUPLE && br.pat.sub_count == 0))
        { s.complete = false; }
        s.cmd(br.body, depth + 1);
    }
}

fn void FactScan.cns(FactScan* s, air_ir::AirCns* k, ulong incoming, char* callee_name, int depth)
{
    if (k == null) { s.escaped |= incoming | s.control; return; }
    if (!s.step(depth)) { return; }
    switch (k.tag)
    {
        case ACNS_COVAR:
            // A ret or opaque continuation can expose its incoming value.
            s.escaped |= incoming | s.control;
            return;
        case ACNS_COMU:
            s.bind(k.bind, incoming);
            s.cmd(k.body, depth + 1);
            return;
        case ACNS_INDEX:
        {
            ulong index = s.prd(k.prd, depth + 1);
            if (k.tail != null && k.tail.tag == air_ir::AirCnsTag.ACNS_STORE)
            { s.cns(k.tail, incoming | index, null, depth + 1); }
            else { s.cns(k.tail, index, null, depth + 1); }
            return;
        }
        case ACNS_DEREF:
            // A load does not export the particular address copy used for it.
            s.cns(k.tail, 0, null, depth + 1);
            return;
        case ACNS_FIELD:
            if (k.idx < 0) { s.cns(k.tail, incoming, null, depth + 1); }
            else { s.cns(k.tail, 0, null, depth + 1); }
            return;
        case ACNS_FST: case ACNS_SND: case ACNS_PROJ:
            // The current emitter forwards projection values; preserve taint.
            s.cns(k.tail, incoming, null, depth + 1); return;
        case ACNS_STORE:
            s.writes = true;
            s.escaped |= s.prd(k.prd, depth + 1) | s.control;
            s.cns(k.tail, 0, null, depth + 1);
            return;
        case ACNS_CASE:
            s.branches(&k.branches[0], k.branch_count, incoming, depth + 1);
            return;
        case ACNS_ASCRIBE: case ACNS_DEFAULT:
            s.cns(k.tail, incoming, callee_name, depth + 1); return;
        case ACNS_CALL: case ACNS_STACK:
        {
            air_ir::AirDecl* target = incoming == 0 ? s.callee(callee_name) : null;
            if (target == null || !target.memory_readonly) { s.writes = true; }
            air_ir::AirCns* at = k.tag == air_ir::AirCnsTag.ACNS_CALL ? k.tail : k;
            usz pos = 0;
            ulong returned = 0;
            while (at != null && at.tag == air_ir::AirCnsTag.ACNS_STACK && pos < 64)
            {
                ulong arg = s.prd(at.prd, depth + 1);
                if (target == null || pos >= target.param_count || target.params[pos] == null
                    || !target.params[pos].no_capture) { s.escaped |= arg; returned |= arg; }
                pos++; at = at.tail;
            }
            if (at != null && at.tag == air_ir::AirCnsTag.ACNS_STACK) { s.complete = false; }
            // Unknown call results may alias any incoming argument or callee.
            if (target == null) { returned |= incoming; s.escaped |= incoming; }
            s.cns(at, returned, null, depth + 1);
            return;
        }
        default:
            s.complete = false;
    }
}

fn void FactScan.cmd(FactScan* s, air_ir::AirCmd* c, int depth)
{
    if (c == null) { return; }
    if (!s.step(depth)) { return; }
    switch (c.tag)
    {
        case ACMD_CUT:
        {
            ulong mask = s.prd(c.prd, depth + 1);
            char* name = c.prd != null && c.prd.tag == air_ir::AirPrdTag.APRD_VAR ? c.prd.name : null;
            s.cns(c.cns, mask, name, depth + 1);
            return;
        }
        case ACMD_LET:
            s.bind(c.binder, s.prd(c.prd, depth + 1));
            s.cmd(c.body, depth + 1); return;
        case ACMD_SEQ:
            s.cmd(c.body, depth + 1); s.cmd(c.next, depth + 1); return;
        case ACMD_MU: case ACMD_MUTILDE: case ACMD_BLOCK: case ACMD_LABEL: case ACMD_DEFER:
            s.cmd(c.body, depth + 1); return;
        case ACMD_IF:
            s.control |= s.prd(c.prd, depth + 1);
            s.cmd(c.then_c, depth + 1); s.cmd(c.else_c, depth + 1); return;
        case ACMD_WHILE: case ACMD_FOR:
            s.control |= s.prd(c.prd, depth + 1);
            s.cmd(c.body, depth + 1); s.cmd(c.next, depth + 1); return;
        case ACMD_MATCH:
            s.branches(&c.branches[0], c.branch_count, s.prd(c.prd, depth + 1), depth + 1); return;
        case ACMD_RET:
            s.escaped |= s.prd(c.prd, depth + 1) | s.control; return;
        case ACMD_NOP: case ACMD_TRAP: case ACMD_UB: case ACMD_BREAK: case ACMD_CONTINUE:
            return;
        case ACMD_SYSCALL:
        {
            // A system call may write any memory and may retain any pointer operand.
            s.writes = true;
            ulong sm = s.prd(c.prd, depth + 1);
            for (usz i = 0; i < c.prd_count && i < 64; i++) { sm |= s.prd(c.prds[i], depth + 1); }
            s.escaped |= sm | s.control;
            s.cns(c.cns, 0, null, depth + 1);
            return;
        }
        case ACMD_JUMP:
            for (usz i = 0; i < c.jump_arg_count && i < 16; i++) { s.escaped |= s.lookup(c.jump_args[i]); }
            if (c.jump_arg_count > 16) { s.complete = false; }
            return;
        default:
            s.complete = false;
    }
}

fn bool screen(air_ir::AirModule* mod, air_ir::AirDecl* d)
{
    bool changed = false;
    if (d.fact_state == air_ir::AirFactState.AFACT_UNKNOWN || d.is_extern || d.param_count > 16)
    {
        changed = d.memory_readonly;
        d.memory_readonly = false; d.fact_state = air_ir::AirFactState.AFACT_UNKNOWN;
        for (usz i = 0; i < d.param_count && i < 64; i++)
        {
            if (d.params[i] != null) { changed |= d.params[i].no_capture; d.params[i].no_capture = false; }
        }
        return changed;
    }
    FactScan* s = (FactScan*)calloc(1, FactScan::size);
    if (s == null) { d.fact_state = air_ir::AirFactState.AFACT_UNKNOWN; return screen(mod, d); }
    s.mod = mod; s.decl = d; s.complete = true;
    for (usz i = 0; i < d.param_count; i++)
    {
        if (d.params[i] != null) { s.bind(d.params[i].name, 1UL << i); }
    }
    bool stable = false;
    for (int round = 0; round < FACT_ROUNDS; round++)
    {
        s.changed = false; s.steps = 0;
        s.cmd(d.def_body, 0);
        if (!s.changed) { stable = true; break; }
        if (!s.complete) { break; }
    }
    if (!stable) { s.complete = false; }
    if ((!s.complete || s.writes) && d.memory_readonly) { d.memory_readonly = false; changed = true; }
    for (usz i = 0; i < d.param_count; i++)
    {
        air_ir::AirBinder* p = d.params[i];
        bool pointer = p != null && p.ty != null && (p.ty.tag == air_ir::AirTypTag.ATYP_PTR
                    || p.ty.tag == air_ir::AirTypTag.ATYP_REF || p.ty.tag == air_ir::AirTypTag.ATYP_REF_MUT);
        if (p != null && p.no_capture && (!s.complete || !pointer || (s.escaped & (1UL << i)) != 0))
        { p.no_capture = false; changed = true; }
    }
    d.fact_state = s.complete ? air_ir::AirFactState.AFACT_AIR_CHECKED : air_ir::AirFactState.AFACT_UNKNOWN;
    free((void*)s);
    return changed;
}

fn void validate_module(air_ir::AirModule* mod)
{
    if (mod == null) { return; }
    bool stable = false;
    for (int round = 0; round < FACT_ROUNDS; round++)
    {
        bool changed = false;
        for (usz i = 0; i < mod.decl_count; i++)
        {
            air_ir::AirDecl* d = mod.decls[i];
            if (d != null && d.tag == air_ir::AirDeclTag.ADECL_DEF) { changed |= screen(mod, d); }
        }
        if (!changed) { stable = true; break; }
    }
    if (!stable)
    {
        for (usz i = 0; i < mod.decl_count; i++)
        {
            air_ir::AirDecl* d = mod.decls[i];
            if (d != null && d.tag == air_ir::AirDeclTag.ADECL_DEF)
            { d.fact_state = air_ir::AirFactState.AFACT_UNKNOWN; screen(mod, d); }
        }
    }
}
