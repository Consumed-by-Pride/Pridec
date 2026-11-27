// ============================================================================
// lair_lower.c3 — AirModule -> LModule: the three normalizations of
// docs/pear2/LAIR.md §1, implemented as one CPS walk.
//
// The walk mirrors air_ll.c3 (the reference consumer) in what it *accepts*
// and how types are inferred -- that correspondence is deliberate: two
// consumers of the same AIR that disagree about a form are both wrong -- but
// instead of printing LLVM as it goes it builds LAIR blocks, so every
// decision (block boundaries, terminators, atom bindings) exists as data
// before anything is printed.
//
// N1: every compound producer becomes an instruction with atom operands.
// N2: consumer stacks (call chains) are walked once, into one LI_CALL; the
//     continuation is either a comu (bind + continue) or a cut to %ret.
// N3: a covariable whose code must exist in more than one place is a block
//     with parameters. The function's return is one covariable (a cut site
//     prints `ret`); labels are the others: `label l(params). body` is a
//     block whose parameters are the declared params plus one per name the
//     label captures from its environment, and every `jump l(args)`,
//     `break l` and `continue l` is an edge whose arguments are the declared
//     args plus the *current* values of the captured names -- the block
//     parameters are the phi nodes, exactly as pear2c's M9 promotion does.
//     A `while` whose body rebinds captured names gets the same treatment:
//     the header is a parameterized join, the entry edge carries the entry
//     values, the back edge the body's final bindings.
//
// Everything outside the slice fails closed with an AIR source position:
// a LAIR bug that reaches LLVM is a LLVM diagnostic with no file attached.
// ============================================================================
module lair_lower;
extern fn int fprintf(void* f, char* fmt, ...);
extern fn void* fdopen(int fd, char* mode);
extern fn int fflush(void* f);

import air_ir;
import air_text;
import air_util;
import lair_ir;

struct Lower
{
    AirModule* am;
    LModule* lm;
    AirArena* a;
    LFunc* cur_fn;
    LBlock* cur;
    int tmp;
    int anon;
    char*[256] vn;
    LAtom[256] vv;
    bool[256] carried;          // env entry was captured by a label: rebinding
                                // it inside a loop makes it loop-carried
    int nv;
    char* ret_name;             // the covariable bound by the def's `mu~`
    int line;
    int col;
    char* fn_name;
    // loop-carried watch: the last value bound to each tracked name during
    // a while body (pear2c's watch_*), read for the back-edge arguments
    char*[32] wl_names;
    LAtom[32] wl_vals;
    int wl_n;
    bool watch_on;
    int watch_base;             // branch depth the watch records at
    int bdepth;                 // branch depth (arms increment it)
    // label table (phase 2): name -> block, in first-encounter order
    char*[32] lbl_names;
    LBlock*[32] lbl_blocks;
    int[32] lbl_np;             // declared parameter count (captured params
                                // are appended when the label is lowered)
    char*[512] lbl_par;         // declared parameter AIR names (per label)
    char*[512] lbl_cap;         // captured environment AIR names (per label)
    int[32] lbl_parn;
    int[32] lbl_capn;
    int lbl_n;
}

// ── diagnostics ────────────────────────────────────────────────────────────
fn void Lower.fail(Lower* l, char* what, char* who)
{
    l.lm.errs++;
    char* src = l.lm.source != null ? l.lm.source : (char*)"?";
    int ln = l.line;
    int cl = l.col;
    char* fnm = l.fn_name != null ? l.fn_name : (char*)"<module>";
    void* se = fdopen(2, "w");
    if (who != null)
    {
        fprintf(se, "lairc: %s:%d:%d: in %s: %s: %s\n", src, ln, cl, fnm, what, who);
    }
    else
    {
        fprintf(se, "lairc: %s:%d:%d: in %s: %s\n", src, ln, cl, fnm, what);
    }
    fflush(se);
}

fn char* lair_cmd_name(AirCmdTag tag)
{
    switch (tag)
    {
        case ACMD_INVALID: return (char*)"invalid";
        case ACMD_CUT: return (char*)"cut";
        case ACMD_MU: return (char*)"mu";
        case ACMD_MUTILDE: return (char*)"mu~";
        case ACMD_JUMP: return (char*)"jump";
        case ACMD_SEQ: return (char*)"seq";
        case ACMD_BLOCK: return (char*)"block";
        case ACMD_LET: return (char*)"let";
        case ACMD_LETREC: return (char*)"letrec";
        case ACMD_IF: return (char*)"if";
        case ACMD_WHILE: return (char*)"while";
        case ACMD_FOR: return (char*)"for";
        case ACMD_MATCH: return (char*)"match";
        case ACMD_HANDLE: return (char*)"handle";
        case ACMD_PERFORM: return (char*)"perform";
        case ACMD_RESUME: return (char*)"resume";
        case ACMD_UNSAFE: return (char*)"unsafe";
        case ACMD_UNCHECKED: return (char*)"unchecked";
        case ACMD_COMPTIME: return (char*)"comptime";
        case ACMD_ASSERT: return (char*)"assert";
        case ACMD_ASSUME: return (char*)"assume";
        case ACMD_UB: return (char*)"ub";
        case ACMD_TRAP: return (char*)"trap";
        case ACMD_RET: return (char*)"ret";
        case ACMD_BREAK: return (char*)"break";
        case ACMD_CONTINUE: return (char*)"continue";
        case ACMD_DEFER: return (char*)"defer";
        case ACMD_LABEL: return (char*)"label";
        case ACMD_NOP: return (char*)"nop";
        case ACMD_ASM: return (char*)"asm";
        case ACMD_SYSCALL: return (char*)"syscall";
        case ACMD_ATOMIC: return (char*)"atomic";
        case ACMD_FENCE: return (char*)"fence";
        case ACMD_STORE: return (char*)"store";
        default: break;
    }
    return (char*)"cmd?";
}

fn char* lair_cns_name(AirCnsTag tag)
{
    switch (tag)
    {
        case ACNS_COVAR: return (char*)"covariable";
        case ACNS_STACK: return (char*)"stack";
        case ACNS_FST: return (char*)"fst";
        case ACNS_SND: return (char*)"snd";
        case ACNS_PROJ: return (char*)"proj";
        case ACNS_FIELD: return (char*)"field";
        case ACNS_INDEX: return (char*)"index";
        case ACNS_CALL: return (char*)"call";
        case ACNS_CASE: return (char*)"case";
        case ACNS_COCASE: return (char*)"cocase";
        case ACNS_COMU: return (char*)"comu";
        case ACNS_DEFAULT: return (char*)"default";
        case ACNS_ASCRIBE: return (char*)"ascribe";
        case ACNS_SUBST: return (char*)"subst";
        case ACNS_SHARE: return (char*)"share";
        case ACNS_ERASE: return (char*)"erase";
        case ACNS_DEREF: return (char*)"deref";
        case ACNS_STORE: return (char*)"store";
        case ACNS_LABEL: return (char*)"label";
        default: break;
    }
    return (char*)"consumer?";
}

fn char* lair_prd_name(AirPrdTag tag)
{
    switch (tag)
    {
        case APRD_VAR: return (char*)"variable";
        case APRD_CON: return (char*)"constructor";
        case APRD_INT: return (char*)"integer literal";
        case APRD_FLOAT: return (char*)"float literal";
        case APRD_BOOL: return (char*)"boolean literal";
        case APRD_CHAR: return (char*)"char literal";
        case APRD_STRING: return (char*)"string literal";
        case APRD_BYTES: return (char*)"bytes literal";
        case APRD_UNIT: return (char*)"unit";
        case APRD_NULL: return (char*)"null";
        case APRD_TUPLE: return (char*)"tuple";
        case APRD_RECORD: return (char*)"record";
        case APRD_ARRAY: return (char*)"array";
        case APRD_LAMBDA: return (char*)"lambda";
        case APRD_MU: return (char*)"mu";
        case APRD_BINOP: return (char*)"binary operation";
        case APRD_UNOP: return (char*)"unary operation";
        case APRD_COERCE: return (char*)"coerce";
        case APRD_SIZEOF: return (char*)"sizeof";
        case APRD_ALLOCA: return (char*)"alloca";
        case APRD_LOAD: return (char*)"load";
        case APRD_GEP: return (char*)"gep";
        default: break;
    }
    return (char*)"producer?";
}

// ── AirTyp -> LTy ──────────────────────────────────────────────────────────
fn LTy lair_to_lty(AirTyp* t)
{
    if (t == null) { return LT_INVALID; }
    switch (t.tag)
    {
        case ATYP_BOOL: return LT_BOOL;
        case ATYP_I8: return LT_I8;
        case ATYP_I16: return LT_I16;
        case ATYP_I32: return LT_I32;
        case ATYP_I64: return LT_I64;
        case ATYP_U8: return LT_U8;
        case ATYP_U16: return LT_U16;
        case ATYP_U32: return LT_U32;
        case ATYP_U64: return LT_U64;
        case ATYP_ISZ: return LT_I64;       // slice target: x86-64
        case ATYP_USZ: return LT_U64;
        case ATYP_CHAR: return LT_CHAR;
        case ATYP_F32: return LT_F32;
        case ATYP_F64: return LT_F64;
        case ATYP_UNIT: return LT_UNIT;
        case ATYP_BOTTOM: return LT_UNIT;
        case ATYP_PTR: return LT_PTR;
        case ATYP_ARROW: return LT_PTR;     // a function value is a symbol here;
                                            // arrow-typed externs print as ptr
        default: return LT_INVALID;
    }
}

// ── environment ────────────────────────────────────────────────────────────
// Flat with shadowing: a `let` (or comu bind, or loop-carried phi) of a name
// that is already in scope appends a new entry and hides the old one, exactly
// like AIR's lexical scopes. Lookup takes the innermost binding. Scopes are
// saved/restored around every construct whose bindings must not escape.
fn bool Lower.lookup(Lower* l, char* nm, LAtom* out)
{
    if (nm == null) { return false; }
    for (int i = l.nv - 1; i >= 0; i--)
    {
        if (air_text::streq(l.vn[i], nm)) { *out = l.vv[i]; return true; }
    }
    return false;
}

fn int Lower.env_index(Lower* l, char* nm)
{
    if (nm == null) { return -1; }
    for (int i = l.nv - 1; i >= 0; i--)
    {
        if (air_text::streq(l.vn[i], nm)) { return i; }
    }
    return -1;
}

fn void Lower.bind(Lower* l, char* nm, LAtom v)
{
    if (nm == null || (nm[0] == '_' && nm[1] == 0)) { return; }
    if (l.nv >= 256) { Lower.fail(l, "too many names in one function", nm); return; }
    // a rebinding inherits carried-ness from the binding it shadows (pear2c's
    // env_carried chain): a captured name rebound to a loop phi stays carried
    int prev = Lower.env_index(l, nm);
    l.vn[l.nv] = nm;
    l.vv[l.nv] = v;
    l.carried[l.nv] = prev >= 0 && l.carried[prev];
    l.nv++;
    // loop-carried watch: the last value bound to a tracked name during a
    // while body becomes that loop's back-edge argument
    if (l.watch_on && l.bdepth == l.watch_base)
    {
        for (int i = 0; i < l.wl_n; i++)
        {
            if (air_text::streq(l.wl_names[i], nm)) { l.wl_vals[i] = v; return; }
        }
    }
}

fn void Lower.env_mark_carried(Lower* l)
{
    for (int i = 0; i < l.nv; i++) { l.carried[i] = true; }
}

// watch lookup with the entry value as the fallback (pear2c's watch_lookup)
fn LAtom Lower.watch_get(Lower* l, char* nm, LAtom fallback)
{
    for (int i = 0; i < l.wl_n; i++)
    {
        if (air_text::streq(l.wl_names[i], nm)) { return l.wl_vals[i]; }
    }
    return fallback;
}

fn void Lower.watch_reg(Lower* l, char* nm)
{
    for (int i = 0; i < l.wl_n; i++)
    {
        if (air_text::streq(l.wl_names[i], nm)) { return; }
    }
    if (l.wl_n >= 32) { Lower.fail(l, "loop carries more mutable locals than supported", null); return; }
    l.wl_names[l.wl_n] = nm;
    l.wl_vals[l.wl_n] = lair_ir::la_atom_unit();
    l.wl_n++;
}

// ── label table ────────────────────────────────────────────────────────────
fn int Lower.label_index(Lower* l, char* nm)
{
    if (nm == null) { return -1; }
    for (int i = 0; i < l.lbl_n; i++)
    {
        if (air_text::streq(l.lbl_names[i], nm)) { return i; }
    }
    return -1;
}

fn bool Lower.label_reg(Lower* l, char* nm, LBlock* b, AirCmd* c)
{
    if (Lower.label_index(l, nm) >= 0)
    {
        Lower.fail(l, "label declared twice", nm);
        return false;
    }
    if (l.lbl_n >= 32) { Lower.fail(l, "too many labels in one function", nm); return false; }
    l.lbl_names[l.lbl_n] = nm;
    l.lbl_blocks[l.lbl_n] = b;
    l.lbl_np[l.lbl_n] = (int)c.mbinder_count;
    l.lbl_parn[l.lbl_n] = (int)c.mbinder_count;
    for (usz i = 0; i < c.mbinder_count && i < 16; i++)
    {
        l.lbl_par[(usz)l.lbl_n * 16 + (usz)i] = c.mbinders[i] != null ? c.mbinders[i].name : null;
    }
    l.lbl_capn[l.lbl_n] = 0;
    l.lbl_n++;
    return true;
}

// ── pre-pass: register labels and validate jump targets, in walk order ──────
// A jump may only target a label already declared on the spine (forward
// jumps fail closed -- pear2c's order-independent edge collection is phase 3).
fn bool Lower.collect_cns(Lower* l, AirCns* k)
{
    if (k == null) { return true; }
    if (k.tag == ACNS_COMU && k.body != null && !Lower.collect(l, k.body)) { return false; }
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] != null && k.branches[i].body != null && !Lower.collect(l, k.branches[i].body)) { return false; }
    }
    if (k.tail != null && !Lower.collect_cns(l, k.tail)) { return false; }
    return true;
}

fn bool Lower.collect(Lower* l, AirCmd* c)
{
    while (c != null)
    {
        if (c.source_line != 0) { l.line = c.source_line; l.col = c.source_col; }
        switch (c.tag)
        {
            case ACMD_NOP:
                return true;
            case ACMD_BLOCK:
                c = c.body;
                continue;
            case ACMD_LET:
                c = c.body;
                continue;
            case ACMD_SEQ:
                if (!Lower.collect(l, c.body)) { return false; }
                c = c.next;
                continue;
            case ACMD_CUT:
            {
                AirCns* k = c.cns;
                if (k == null) { return true; }
                if (k.tag == ACNS_COMU)
                {
                    if (k.body != null && !Lower.collect(l, k.body)) { return false; }
                    return true;
                }
                if (k.tag == ACNS_CALL || k.tag == ACNS_STACK)
                {
                    AirCns* cur = k.tag == ACNS_CALL ? k.tail : k;
                    while (cur != null && cur.tag == ACNS_STACK) { cur = cur.tail; }
                    if (cur != null && cur.tag == ACNS_COMU && cur.body != null)
                    {
                        return Lower.collect(l, cur.body);
                    }
                    return true;
                }
                return true;
            }
            case ACMD_RET:
            case ACMD_TRAP:
            case ACMD_UB:
            case ACMD_ASSERT:
            case ACMD_ASSUME:
                return true;
            case ACMD_IF:
            {
                if (!Lower.collect(l, c.then_c)) { return false; }
                return Lower.collect(l, c.else_c);
            }
            case ACMD_WHILE:
                return Lower.collect(l, c.body);
            case ACMD_MATCH:
            {
                for (usz i = 0; i < c.branch_count; i++)
                {
                    if (c.branches[i] != null && c.branches[i].body != null && !Lower.collect(l, c.branches[i].body)) { return false; }
                }
                return true;
            }
            case ACMD_LABEL:
            {
                if (c.mbinder_count > 16) { Lower.fail(l, "label has more than 16 parameters", c.binder); return false; }
                LBlock* b = lair_ir::lair_new_block(l.a, c.binder);
                if (b == null) { Lower.fail(l, "out of memory", null); return false; }
                b.lbl = true;
                if (l.cur_fn.nb >= 128) { Lower.fail(l, "too many blocks in one function", null); return false; }
                l.cur_fn.blocks[l.cur_fn.nb] = b;
                l.cur_fn.nb++;
                for (usz i = 0; i < c.mbinder_count; i++)
                {
                    AirBinder* p = c.mbinders[i];
                    if (p == null) { continue; }
                    LTy t = lair_to_lty(p.ty);
                    if (t == LT_INVALID || t == LT_SYM)
                    {
                        Lower.fail(l, "label parameter has no type in the LAIR slice", p.name);
                        return false;
                    }
                    b.params[b.np].name = p.name;
                    b.params[b.np].aname = p.name;
                    b.params[b.np].ty = t;
                    b.np++;
                }
                if (!Lower.label_reg(l, c.binder, b, c)) { return false; }
                return Lower.collect(l, c.body);
            }
            case ACMD_JUMP:
            {
                int ix = Lower.label_index(l, c.target_label);
                if (ix < 0)
                {
                    Lower.fail(l, "jump to a label declared later (forward jumps are not in the LAIR slice)", c.target_label);
                    return false;
                }
                if (c.jump_arg_count != (usz)l.lbl_np[ix])
                {
                    Lower.fail(l, "jump passes the wrong number of arguments", c.target_label);
                    return false;
                }
                return true;
            }
            case ACMD_BREAK:
            case ACMD_CONTINUE:
            {
                int ix = Lower.label_index(l, c.target_label);
                if (ix < 0)
                {
                    Lower.fail(l, "break/continue to a label declared later (forward jumps are not in the LAIR slice)", c.target_label);
                    return false;
                }
                if (l.lbl_np[ix] != 0)
                {
                    Lower.fail(l, "break/continue targets a label with parameters", c.target_label);
                    return false;
                }
                return true;
            }
            default:
                return true;                   // the lowerer fails closed on these
        }
    }
    return true;
}

fn LAtom Lower.fresh(Lower* l, LTy t)
{
    // `.tN`: the dot keeps emitter-made names apart from every AIR identifier,
    // the same convention air_ll uses for blocks (`a.then0`).
    Sb s; s.init();
    s.put((char*)".t");
    s.int_((long)l.tmp);
    l.tmp++;
    char* nm = s.take();
    return lair_ir::la_atom_var(nm, t);
}

fn LBlock* Lower.new_block(Lower* l)
{
    Sb s; s.init();
    s.put((char*)".b");
    s.int_((long)l.anon);
    l.anon++;
    char* nm = s.take();
    LBlock* b = lair_ir::lair_new_block(l.a, nm);
    if (b == null) { Lower.fail(l, "out of memory", null); return null; }
    if (l.cur_fn.nb >= 128) { Lower.fail(l, "too many blocks in one function", null); return null; }
    l.cur_fn.blocks[l.cur_fn.nb] = b;
    l.cur_fn.nb++;
    return b;
}

fn void Lower.emit(Lower* l, LInstr in)
{
    if (l.cur == null || l.cur.has_term) { Lower.fail(l, "instruction after the block's terminator", null); return; }
    if (!lair_ir::lair_block_push(l.cur, in)) { Lower.fail(l, "out of memory", null); }
}

fn void Lower.term(Lower* l, LTerm t)
{
    if (l.cur == null) { Lower.fail(l, "terminator with no block", null); return; }
    if (l.cur.has_term) { Lower.fail(l, "block terminated twice", null); return; }
    l.cur.term = t;
    l.cur.has_term = true;
}

fn AirDecl* lair_find_decl(AirModule* am, char* nm)
{
    if (nm == null) { return null; }
    for (usz i = 0; i < am.decl_count; i++)
    {
        AirDecl* d = am.decls[i];
        if (d != null && d.name != null && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

// ── carried-mutation scan (pear2c's scan_carried_mutation) ─────────────────
// Collects the names a loop body rebinds that are in scope *and* captured by
// a label (carried). These become the header's phi parameters. The scan walks
// the sequential spine (body/next, comu continuations, nested loops) but not
// if/match arms: branching constructs are terminal in AIR, so scope-local
// shadowing inside them cannot escape. The watch arrays are the scratch list.
fn bool Lower.scan_carried_cns(Lower* l, AirCns* k, char*[] names, int* count, int depth)
{
    if (k == null || depth >= 64) { return true; }
    if (k.tag == ACNS_COMU && k.bind != null && !(k.bind[0] == '_' && k.bind[1] == 0))
    {
        int ix = Lower.env_index(l, k.bind);
        if (ix >= 0 && l.carried[ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (air_text::streq(names[(usz)i], k.bind)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) { Lower.fail(l, "loop carries more mutable locals than supported", null); return false; }
                names[(usz)(*count)] = k.bind;
                (*count)++;
            }
        }
        if (k.body != null && !Lower.scan_carried(l, k.body, names, count, depth + 1)) { return false; }
    }
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] != null && k.branches[i].body != null && !Lower.scan_carried(l, k.branches[i].body, names, count, depth + 1)) { return false; }
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        if (k.cobranches[i] != null && k.cobranches[i].body != null && !Lower.scan_carried(l, k.cobranches[i].body, names, count, depth + 1)) { return false; }
    }
    return Lower.scan_carried_cns(l, k.tail, names, count, depth + 1);
}

fn bool Lower.scan_carried(Lower* l, AirCmd* c, char*[] names, int* count, int depth)
{
    if (c == null || depth >= 64) { return true; }
    if (c.tag == ACMD_LET && c.binder != null && !(c.binder[0] == '_' && c.binder[1] == 0))
    {
        int ix = Lower.env_index(l, c.binder);
        if (ix >= 0 && l.carried[ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (air_text::streq(names[(usz)i], c.binder)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) { Lower.fail(l, "loop carries more mutable locals than supported", null); return false; }
                names[(usz)(*count)] = c.binder;
                (*count)++;
            }
        }
    }
    if (!Lower.scan_carried_cns(l, c.cns, names, count, depth + 1)) { return false; }
    return Lower.scan_carried(l, c.body, names, count, depth + 1) && Lower.scan_carried(l, c.next, names, count, depth + 1);
}

// ── producers (N1) ─────────────────────────────────────────────────────────
fn LAtom Lower.binop(Lower* l, AirPrd* p)
{
    LAtom z; z.k = LA_UNIT; z.ty = LT_INVALID; z.name = null; z.ival = 0; z.fval = 0.0;
    if (p.sub_count < 2) { Lower.fail(l, "binary operation without two operands", air_text::binop_name(p.bop)); return z; }
    LAtom a = Lower.prd(l, p.subs[0]);
    if (l.lm.errs != 0 && a.ty == LT_INVALID) { return z; }
    LAtom b = Lower.prd(l, p.subs[1]);
    if (l.lm.errs != 0 && b.ty == LT_INVALID) { return z; }
    if (a.ty != b.ty) { Lower.fail(l, "binary operands have different types", air_text::binop_name(p.bop)); return z; }
    LTy t = a.ty;
    bool isi = lair_ir::lty_is_int(t);
    bool isf = lair_ir::lty_is_float(t);
    bool isb = t == LT_BOOL;
    bool cmp = false;
    switch (p.bop)
    {
        case ABIN_ADD: case ABIN_SUB: case ABIN_MUL: case ABIN_DIV: case ABIN_MOD:
            if (!(isi || isf)) { Lower.fail(l, "arithmetic on a non-number", air_text::binop_name(p.bop)); return z; }
            break;
        case ABIN_AND: case ABIN_OR: case ABIN_XOR:
            if (!(isi || (isb && p.bop != ABIN_SHL && p.bop != ABIN_SHR))) { Lower.fail(l, "bitwise operation on a non-integer", air_text::binop_name(p.bop)); return z; }
            break;
        case ABIN_SHL: case ABIN_SHR:
            if (!isi) { Lower.fail(l, "shift of a non-integer", air_text::binop_name(p.bop)); return z; }
            break;
        case ABIN_LAND: case ABIN_LOR:
            if (!isb) { Lower.fail(l, "land/lor need bool operands", null); return z; }
            break;
        case ABIN_EQ: case ABIN_NEQ: case ABIN_LT: case ABIN_GT: case ABIN_LE: case ABIN_GE:
            cmp = true;
            if (!(isi || isf || isb)) { Lower.fail(l, "comparison of a type with no order", air_text::binop_name(p.bop)); return z; }
            if (isb && p.bop != ABIN_EQ && p.bop != ABIN_NEQ) { Lower.fail(l, "ordered comparison of bool", air_text::binop_name(p.bop)); return z; }
            break;
        default:
            Lower.fail(l, "binary operator not in the LAIR slice", air_text::binop_name(p.bop));
            return z;
    }
    // AIR 2.2 annotates the OPERAND type (`(lt x 3 : i64)`, `(add a b : i64)`);
    // the result of a comparison is bool regardless.
    if (p.ty != null)
    {
        LTy ann = lair_to_lty(p.ty);
        if (ann != t) { Lower.fail(l, "operation annotation differs from the operand type", air_text::binop_name(p.bop)); return z; }
    }
    LTy rty = cmp ? LT_BOOL : t;
    LInstr in; in.op = LI_BINOP; in.ty = rty; in.bop = (int)p.bop; in.uop = 0;
    in.a = a; in.b = b; in.from = LT_INVALID; in.callee = null; in.argc = 0; in.va = false;
    LAtom dst = Lower.fresh(l, rty);
    in.dst = dst.name;
    Lower.emit(l, in);
    return dst;
}

fn LAtom Lower.unop(Lower* l, AirPrd* p)
{
    LAtom z; z.k = LA_UNIT; z.ty = LT_INVALID; z.name = null; z.ival = 0; z.fval = 0.0;
    if (p.sub_count < 1) { Lower.fail(l, "unary operation without an operand", air_text::unop_name(p.uop)); return z; }
    LAtom a = Lower.prd(l, p.subs[0]);
    if (a.ty == LT_INVALID) { return z; }
    LTy rty = a.ty;
    switch (p.uop)
    {
        case AUN_NEG:
            if (!(lair_ir::lty_is_float(a.ty) || lair_ir::lty_is_int(a.ty))) { Lower.fail(l, "neg of a non-number", null); return z; }
            break;
        case AUN_NOT:
            if (a.ty != LT_BOOL) { Lower.fail(l, "not of a non-bool", null); return z; }
            break;
        case AUN_BITNOT:
            if (!lair_ir::lty_is_int(a.ty)) { Lower.fail(l, "bitnot of a non-integer", null); return z; }
            break;
        default:
            Lower.fail(l, "unary operator not in the LAIR slice", air_text::unop_name(p.uop));
            return z;
    }
    if (p.ty != null)
    {
        LTy ann = lair_to_lty(p.ty);
        if (ann != a.ty) { Lower.fail(l, "operation annotation differs from the operand type", air_text::unop_name(p.uop)); return z; }
    }
    LInstr in; in.op = LI_UNOP; in.ty = rty; in.bop = 0; in.uop = (int)p.uop;
    in.a = a; in.b = a; in.from = LT_INVALID; in.callee = null; in.argc = 0; in.va = false;
    LAtom dst = Lower.fresh(l, rty);
    in.dst = dst.name;
    Lower.emit(l, in);
    return dst;
}

fn LAtom Lower.coerce(Lower* l, AirPrd* p)
{
    LAtom z; z.k = LA_UNIT; z.ty = LT_INVALID; z.name = null; z.ival = 0; z.fval = 0.0;
    if (p.sub_count < 1 || p.ty == null) { Lower.fail(l, "coerce without types", null); return z; }
    LAtom a = Lower.prd(l, p.subs[0]);
    if (a.ty == LT_INVALID) { return z; }
    LTy to = lair_to_lty(p.ty);
    if (to == LT_INVALID) { Lower.fail(l, "coerce to a type outside the LAIR slice", air_text::typ_kw(p.ty.tag)); return z; }
    if (a.ty == to) { return a; }            // N1: a coercion that changes nothing is no cut
    bool fi = lair_ir::lty_is_int(a.ty) || a.ty == LT_BOOL;
    bool ti = lair_ir::lty_is_int(to) || to == LT_BOOL;
    bool ok = false;
    if (fi && ti) { ok = true; }
    else if (fi && lair_ir::lty_is_float(to)) { ok = true; }
    else if (lair_ir::lty_is_float(a.ty) && ti) { ok = true; }
    else if (lair_ir::lty_is_float(a.ty) && lair_ir::lty_is_float(to)) { ok = true; }
    if (!ok) { Lower.fail(l, "coerce between these types is not defined", null); return z; }
    LInstr in; in.op = LI_COERCE; in.ty = to; in.bop = 0; in.uop = 0;
    in.a = a; in.b = a; in.from = a.ty; in.callee = null; in.argc = 0; in.va = false;
    LAtom dst = Lower.fresh(l, to);
    in.dst = dst.name;
    Lower.emit(l, in);
    return dst;
}

fn LAtom Lower.prd(Lower* l, AirPrd* p)
{
    LAtom z; z.k = LA_UNIT; z.ty = LT_INVALID; z.name = null; z.ival = 0; z.fval = 0.0;
    if (p == null) { Lower.fail(l, "missing producer", null); return z; }
    if (p.source_line != 0) { l.line = p.source_line; l.col = p.source_col; }
    switch (p.tag)
    {
        case APRD_VAR:
        {
            LAtom got;
            if (Lower.lookup(l, p.name, &got)) { return got; }
            AirDecl* d = lair_find_decl(l.am, p.name);
            if (d != null && (d.tag == ADECL_DEF || d.tag == ADECL_DECLARE)) { return lair_ir::la_atom_sym(p.name); }
            Lower.fail(l, "unbound variable", p.name);
            return z;
        }
        case APRD_INT:
        {
            LTy t = lair_to_lty(p.ty);
            if (t == LT_INVALID)
            {
                if (p.ty == null) { t = LT_I64; }        // M1: untyped literal defaults to i64
                else { Lower.fail(l, "integer literal without an integer type", air_text::typ_kw(p.ty.tag)); return z; }
            }
            if (!(lair_ir::lty_is_int(t) || t == LT_BOOL)) { Lower.fail(l, "integer literal without an integer type", null); return z; }
            return lair_ir::la_atom_int(p.ival, t);
        }
        case APRD_FLOAT:
        {
            LTy t = lair_to_lty(p.ty);
            if (t == LT_INVALID)
            {
                if (p.ty == null) { t = LT_F64; }
                else { Lower.fail(l, "float literal without a float type", air_text::typ_kw(p.ty.tag)); return z; }
            }
            if (!lair_ir::lty_is_float(t)) { Lower.fail(l, "float literal without a float type", null); return z; }
            return lair_ir::la_atom_float(p.fval, t);
        }
        case APRD_BOOL: return lair_ir::la_atom_bool(p.bval);
        case APRD_CHAR: return lair_ir::la_atom_int(p.ival, LT_CHAR);
        case APRD_UNIT: return lair_ir::la_atom_unit();
        case APRD_BINOP: return Lower.binop(l, p);
        case APRD_UNOP: return Lower.unop(l, p);
        case APRD_COERCE: return Lower.coerce(l, p);
        default:
            Lower.fail(l, "producer not in the LAIR slice", lair_prd_name(p.tag));
            return z;
    }
}

// ── calls (N2: the stack walk) ─────────────────────────────────────────────
// Returns the continuation command (null = the block was terminated).
fn AirCmd* Lower.call(Lower* l, AirPrd* callee, AirCns* k)
{
    if (callee == null || callee.tag != APRD_VAR) { Lower.fail(l, "callee is not a direct function reference (slice)", null); return null; }
    AirDecl* d = lair_find_decl(l.am, callee.name);
    if (d == null || (d.tag != ADECL_DEF && d.tag != ADECL_DECLARE)) { Lower.fail(l, "call of an unknown function", callee.name); return null; }
    LAtom[16] args;
    int na = 0;
    AirCns* cur = k.tag == ACNS_CALL ? k.tail : k;
    while (cur != null && cur.tag == ACNS_STACK)
    {
        if (na >= 16) { Lower.fail(l, "call with more than 16 arguments", callee.name); return null; }
        args[na] = Lower.prd(l, cur.prd);
        if (l.lm.errs != 0 && args[na].ty == LT_INVALID) { return null; }
        na++;
        cur = cur.tail;
    }
    if (cur == null) { Lower.fail(l, "call stack with no continuation", callee.name); return null; }
    if (cur.tag != ACNS_COMU && cur.tag != ACNS_COVAR)
    {
        Lower.fail(l, "call continuation must be comu or the return covariable", lair_cns_name(cur.tag));
        return null;
    }
    // signature
    LTy ret = lair_to_lty(d.ret_ty);
    if (ret == LT_INVALID) { ret = LT_UNIT; }           // unannotated = unit for the slice
    bool va = d.is_varargs;
    if (!va && na != (int)d.param_count)
    {
        Sb s; s.init();
        s.put((char*)"call has ");
        s.int_((long)na);
        s.put((char*)" arguments, signature has ");
        s.int_((long)d.param_count);
        Lower.fail(l, s.take(), callee.name);
        return null;
    }
    if (va && na < (int)d.param_count) { Lower.fail(l, "call has fewer arguments than the signature", callee.name); return null; }
    for (int i = 0; i < na && i < (int)d.param_count; i++)
    {
        if (d.params[i] == null) { continue; }
        LTy want = lair_to_lty(d.params[i].ty);
        if (want != LT_INVALID && args[i].ty != want && !(want == LT_PTR && args[i].ty == LT_SYM))
        {
            Lower.fail(l, "argument has the wrong type", callee.name);
            return null;
        }
    }
    LInstr in; in.op = LI_CALL; in.ty = ret; in.bop = 0; in.uop = 0;
    in.a = lair_ir::la_atom_unit(); in.b = lair_ir::la_atom_unit(); in.from = LT_INVALID;
    in.callee = callee.name; in.va = va;
    in.argc = na;
    for (int i = 0; i < na; i++) { in.args[i] = args[i]; }
    char* dst_name = null;
    if (ret != LT_UNIT)
    {
        char* want_name = cur.tag == ACNS_COMU ? cur.bind : null;
        if (want_name == null || (want_name[0] == '_' && want_name[1] == 0))
        {
            dst_name = Lower.fresh(l, ret).name;
        }
        else
        {
            dst_name = want_name;
        }
    }
    in.dst = dst_name;
    Lower.emit(l, in);
    if (cur.tag == ACNS_COMU)
    {
        if (ret == LT_UNIT) { Lower.bind(l, cur.bind, lair_ir::la_atom_unit()); }
        else { Lower.bind(l, cur.bind, lair_ir::la_atom_var(dst_name, ret)); }
        return cur.body;
    }
    // cut of the call result to the return covariable: a tail call
    if (!air_text::streq(cur.name, l.ret_name))
    {
        Lower.fail(l, "cut to a covariable other than the function's return (labels: phase 2)", cur.name);
        return null;
    }
    LTerm t; t.k = LTM_RET;
    if (ret == LT_UNIT) { t.a = lair_ir::la_atom_unit(); }
    else { t.a = lair_ir::la_atom_var(dst_name, ret); }
    t.target = null; t.argc = 0; t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
    Lower.term(l, t);
    return null;
}

// ── commands ───────────────────────────────────────────────────────────────
fn void Lower.emit_ret(Lower* l, AirPrd* p)
{
    LAtom v = lair_ir::la_atom_unit();
    if (p != null) { v = Lower.prd(l, p); }
    if (v.ty == LT_INVALID) { return; }
    if (l.cur_fn.ret == LT_INVALID) { l.cur_fn.ret = v.ty; }
    else if (l.cur_fn.ret != v.ty)
    {
        Sb s; s.init();
        s.put((char*)"return value is ");
        s.put(lair_ir::lty_name(v.ty));
        s.put((char*)", function returns ");
        s.put(lair_ir::lty_name(l.cur_fn.ret));
        Lower.fail(l, s.take(), null);
        return;
    }
    LTerm t; t.k = LTM_RET; t.a = v; t.target = null; t.argc = 0; t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
    Lower.term(l, t);
}

// match: bind/wildcard/tuple-unit become the default arm; int/bool/char
// become switch cases. Anything else (guards, destructuring, or-patterns)
// fails closed with a position.
fn void Lower.match(Lower* l, AirCmd* c)
{
    LAtom s = Lower.prd(l, c.prd);
    if (s.ty == LT_INVALID) { return; }
    if (!(lair_ir::lty_is_int(s.ty) || s.ty == LT_BOOL || s.ty == LT_UNIT))
    {
        Lower.fail(l, "match scrutinee is not an integer, char, bool or unit", null);
        return;
    }
    LBlock* def = null;
    char* bind_name = null;
    LBlock*[64] case_blks;
    long[64] case_vals;
    int nc = 0;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b == null || b.pat == null) { continue; }
        if (b.guard != null) { Lower.fail(l, "match guard not in the LAIR slice", null); return; }
        if (b.pat.tag == APAT_WILD || b.pat.tag == APAT_BIND)
        {
            if (def != null) { Lower.fail(l, "match has more than one catch-all arm", null); return; }
            def = Lower.new_block(l);
            if (def == null) { return; }
            if (b.pat.tag == APAT_BIND) { bind_name = b.pat.name; }
            continue;
        }
        if (b.pat.tag == APAT_TUPLE && b.pat.sub_count == 0 && s.ty == LT_UNIT)
        {
            // `match unit { tuple() -> ... }` over a unit scrutinee: the arm
            // cannot fail, so it is the default arm with no binding.
            if (def != null) { Lower.fail(l, "match has more than one catch-all arm", null); return; }
            def = Lower.new_block(l);
            if (def == null) { return; }
            continue;
        }
        if (b.pat.tag == APAT_INT || b.pat.tag == APAT_BOOL || b.pat.tag == APAT_CHAR)
        {
            if (s.ty == LT_UNIT) { Lower.fail(l, "value pattern over a unit scrutinee", null); return; }
            if (nc >= 64) { Lower.fail(l, "switch with more than 64 cases", null); return; }
            LBlock* cb = Lower.new_block(l);
            if (cb == null) { return; }
            case_blks[nc] = cb;
            case_vals[nc] = b.pat.ival;
            nc++;
            continue;
        }
        Lower.fail(l, "pattern not in the LAIR slice", null);
        return;
    }
    LBlock* defb = def;
    if (defb == null)
    {
        defb = Lower.new_block(l);
        if (defb == null) { return; }
    }
    // terminator on the current block: zero cases (a unit match with only a
    // catch-all) is an unconditional jump -- `switch void` is rejected by LLVM.
    LTerm t; t.k = nc == 0 ? LTM_JUMP : LTM_SWITCH;
    t.a = s; t.target = nc == 0 ? defb.name : null; t.argc = 0; t.t1 = null; t.t2 = null;
    t.ncase = nc;
    for (int i = 0; i < nc; i++) { t.vals[i] = case_vals[i]; t.tgts[i] = case_blks[i].name; }
    t.def = defb.name;
    Lower.term(l, t);
    // lower every arm
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b == null || b.pat == null || b.body == null) { continue; }
        bool is_def = b.pat.tag == APAT_WILD || b.pat.tag == APAT_BIND
                   || (b.pat.tag == APAT_TUPLE && b.pat.sub_count == 0 && s.ty == LT_UNIT);
        LBlock* tgt = is_def ? defb : null;
        if (!is_def)
        {
            // find the block created for this arm's value
            long want = b.pat.ival;
            for (int k2 = 0; k2 < nc; k2++)
            {
                if (case_vals[k2] == want) { tgt = case_blks[k2]; break; }
            }
        }
        if (tgt == null) { continue; }
        // arms are isolated scopes, like if-arms
        int saved = l.nv;
        l.bdepth++;
        l.cur = tgt;
        if (is_def && bind_name != null) { Lower.bind(l, bind_name, s); }
        Lower.cmd(l, b.body);
        l.bdepth--;
        if (!l.cur.has_term) { Lower.fail(l, "match arm falls off its block", null); return; }
        l.nv = saved;
    }
    if (!defb.has_term)
    {
        l.cur = defb;
        LTerm u; u.k = LTM_UNREACH; u.a = lair_ir::la_atom_unit(); u.target = null; u.argc = 0; u.t1 = null; u.t2 = null; u.ncase = 0; u.def = null;
        Lower.term(l, u);
    }
    // the match is terminal: leave the cursor on the default block (any open
    // continuation would have to be one of the arms, and they all terminated)
    l.cur = defb;
}

fn void Lower.cmd(Lower* l, AirCmd* c)
{
    while (c != null && !l.cur.has_term && l.lm.errs == 0)
    {
        if (c.source_line != 0) { l.line = c.source_line; l.col = c.source_col; }
        switch (c.tag)
        {
            case ACMD_NOP:
                return;                     // falls through to the caller's next
            case ACMD_BLOCK:
                c = c.body;
                continue;
            case ACMD_LET:
            {
                LAtom v = Lower.prd(l, c.prd);
                if (v.ty == LT_INVALID) { return; }
                int saved = l.nv;
                Lower.bind(l, c.binder, v);
                if (l.lm.errs != 0) { return; }
                Lower.cmd(l, c.body);
                l.nv = saved;                 // the let's binding does not escape
                if (l.lm.errs != 0 || l.cur.has_term) { return; }
                return;                      // the let's scope ends here
            }
            case ACMD_SEQ:
            {
                Lower.cmd(l, c.body);
                if (l.cur.has_term || l.lm.errs != 0) { return; }
                c = c.next;
                continue;
            }
            case ACMD_CUT:
            {
                AirCns* k = c.cns;
                if (k == null) { Lower.fail(l, "cut without a consumer", null); return; }
                if (k.source_line != 0) { l.line = k.source_line; l.col = k.source_col; }
                if (k.tag == ACNS_COMU)
                {
                    LAtom v = Lower.prd(l, c.prd);
                    if (v.ty == LT_INVALID) { return; }
                    Lower.bind(l, k.bind, v);
                    if (l.lm.errs != 0) { return; }
                    c = k.body;
                    continue;
                }
                if (k.tag == ACNS_COVAR)
                {
                    if (l.ret_name == null || !air_text::streq(k.name, l.ret_name))
                    {
                        Lower.fail(l, "cut to a covariable other than the function's return (labels: phase 2)", k.name);
                        return;
                    }
                    Lower.emit_ret(l, c.prd);
                    return;
                }
                if (k.tag == ACNS_CALL || k.tag == ACNS_STACK)
                {
                    AirCmd* nx = Lower.call(l, c.prd, k);
                    if (nx == null) { return; }
                    c = nx;
                    continue;
                }
                Lower.fail(l, "consumer not in the LAIR slice", lair_cns_name(k.tag));
                return;
            }
            case ACMD_RET:
            {
                Lower.emit_ret(l, c.prd);
                return;
            }
            case ACMD_TRAP:
            {
                LTerm t; t.k = LTM_TRAP; t.a = lair_ir::la_atom_unit(); t.target = null; t.argc = 0; t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
                Lower.term(l, t);
                return;
            }
            case ACMD_UB:
            {
                LTerm t; t.k = LTM_UNREACH; t.a = lair_ir::la_atom_unit(); t.target = null; t.argc = 0; t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
                Lower.term(l, t);
                return;
            }
            case ACMD_ASSERT:
            {
                LAtom v = Lower.prd(l, c.prd);
                if (v.ty == LT_INVALID) { return; }
                if (v.ty != LT_BOOL) { Lower.fail(l, "assert condition is not a bool", null); return; }
                LBlock* cont = Lower.new_block(l);
                LBlock* trp = Lower.new_block(l);
                if (cont == null || trp == null) { return; }
                LTerm b; b.k = LTM_BR; b.a = v; b.t1 = cont.name; b.t2 = trp.name;
                b.target = null; b.argc = 0; b.ncase = 0; b.def = null;
                Lower.term(l, b);
                l.cur = trp;
                LTerm tt; tt.k = LTM_TRAP; tt.a = lair_ir::la_atom_unit(); tt.target = null; tt.argc = 0; tt.t1 = null; tt.t2 = null; tt.ncase = 0; tt.def = null;
                Lower.term(l, tt);
                l.cur = cont;               // the sequence continues here
                return;
            }
            case ACMD_IF:
            {
                LAtom cv = Lower.prd(l, c.prd);
                if (cv.ty == LT_INVALID) { return; }
                if (cv.ty != LT_BOOL) { Lower.fail(l, "if condition is not a bool", null); return; }
                LBlock* th = Lower.new_block(l);
                LBlock* el = Lower.new_block(l);
                if (th == null || el == null) { return; }
                LTerm b; b.k = LTM_BR; b.a = cv; b.t1 = th.name; b.t2 = el.name;
                b.target = null; b.argc = 0; b.ncase = 0; b.def = null;
                Lower.term(l, b);
                // arms are isolated scopes (pear2c's branch_enter/leave): their
                // bindings must not leak into siblings or the watch
                int saved = l.nv;
                l.bdepth++;
                l.cur = th;
                Lower.cmd(l, c.then_c);
                l.bdepth--;
                if (l.lm.errs != 0) { return; }
                if (!l.cur.has_term) { Lower.fail(l, "then-branch falls off its block", null); return; }
                l.nv = saved;
                saved = l.nv;
                l.bdepth++;
                l.cur = el;
                Lower.cmd(l, c.else_c);
                l.bdepth--;
                if (l.lm.errs != 0) { return; }
                if (!l.cur.has_term) { Lower.fail(l, "else-branch falls off its block", null); return; }
                l.nv = saved;
                l.cur = el;                 // terminal; cursor kept on the else arm
                return;
            }
            case ACMD_WHILE:
            {
                // N3: the header is a join (entry edge + back edge), the body
                // falls back into it, and the exit block is where the sequence
                // continues. When the body rebinds names captured by a label,
                // the header is parameterized: one phi per carried name, the
                // entry edge carrying the entry values, the back edge the
                // body's final bindings (the watch).
                int saved_wl = l.wl_n;
                int saved_env = l.nv;
                bool started = !l.watch_on;      // did this loop start the watch?
                char*[32] tracked_names;
                int tracked = 0;
                if (!Lower.scan_carried(l, c.body, &tracked_names, &tracked, 0)) { return; }
                LBlock* hdr = Lower.new_block(l);
                LBlock* body = Lower.new_block(l);
                LBlock* exitb = Lower.new_block(l);
                if (hdr == null || body == null || exitb == null) { return; }
                LAtom[32] entry_vals;
                if (tracked > 0)
                {
                    if (tracked > 24) { Lower.fail(l, "loop carries more mutable locals than supported", null); return; }
                    for (int k = 0; k < tracked; k++)
                    {
                        Lower.watch_reg(l, tracked_names[(usz)k]);
                        LAtom pa = Lower.fresh(l, l.vv[Lower.env_index(l, tracked_names[(usz)k])].ty);
                        hdr.params[hdr.np].name = pa.name;
                        hdr.params[hdr.np].aname = tracked_names[(usz)k];
                        hdr.params[hdr.np].ty = pa.ty;
                        hdr.np++;
                        LAtom cur;
                        if (!Lower.lookup(l, tracked_names[(usz)k], &cur))
                        {
                            Lower.fail(l, "carried name vanished from the environment", tracked_names[(usz)k]);
                            return;
                        }
                        entry_vals[k] = cur;
                    }
                }
                LTerm j; j.k = LTM_JUMP; j.target = hdr.name; j.a = lair_ir::la_atom_unit();
                j.t1 = null; j.t2 = null; j.ncase = 0; j.def = null;
                j.argc = tracked;
                for (int k = 0; k < tracked; k++) { j.args[k] = entry_vals[k]; }
                Lower.term(l, j);
                l.cur = hdr;
                for (int k = 0; k < tracked; k++)
                {
                    Lower.bind(l, tracked_names[(usz)k], lair_ir::la_atom_var(hdr.params[k].name, hdr.params[k].ty));
                }
                LAtom cv = Lower.prd(l, c.prd);
                if (cv.ty == LT_INVALID) { return; }
                if (cv.ty != LT_BOOL) { Lower.fail(l, "while condition is not a bool", null); return; }
                LTerm b; b.k = LTM_BR; b.a = cv; b.t1 = body.name; b.t2 = exitb.name;
                b.target = null; b.argc = 0; b.ncase = 0; b.def = null;
                Lower.term(l, b);
                l.cur = body;
                l.watch_on = true;
                l.watch_base = l.bdepth;
                Lower.cmd(l, c.body);
                if (l.lm.errs != 0) { return; }
                if (!l.cur.has_term)
                {
                    // the body's last open block falls into the back edge,
                    // carrying each tracked name's final binding
                    LTerm jb; jb.k = LTM_JUMP; jb.target = hdr.name;
                    jb.a = lair_ir::la_atom_unit(); jb.t1 = null; jb.t2 = null; jb.ncase = 0; jb.def = null;
                    jb.argc = tracked;
                    for (int k = 0; k < tracked; k++)
                    {
                        jb.args[k] = Lower.watch_get(l, tracked_names[(usz)k], entry_vals[k]);
                    }
                    Lower.term(l, jb);
                }
                // the loop body's bindings do not leak; the carried names
                // surface as the header phis. The binds still hit the watch
                // (an outer loop is recording): a nested loop's completion
                // carries its header phis out, exactly as pear2c's
                // note_carried_bind does -- the phis dominate the exit, the
                // raw body instructions do not.
                l.nv = saved_env;
                for (int k = 0; k < tracked; k++)
                {
                    Lower.bind(l, tracked_names[(usz)k], lair_ir::la_atom_var(hdr.params[k].name, hdr.params[k].ty));
                }
                if (started) { l.watch_on = false; l.wl_n = saved_wl; }
                l.cur = exitb;
                return;                     // sequence continues in the exit block
            }
            case ACMD_LABEL:
            {
                int ix = Lower.label_index(l, c.binder);
                if (ix < 0) { Lower.fail(l, "label not registered", c.binder); return; }
                LBlock* lb = l.lbl_blocks[ix];
                // capture: one block parameter per environment name, in env
                // order; the names become loop-carried
                Lower.env_mark_carried(l);
                if (l.nv > 16) { Lower.fail(l, "label captures more than 16 environment names", c.binder); return; }
                char*[16] cap_names;
                for (int i = 0; i < l.nv; i++) { cap_names[i] = l.vn[i]; }
                int np0 = lb.np;
                if (lb.np + l.nv > 24) { Lower.fail(l, "label block has too many parameters", c.binder); return; }
                for (int i = 0; i < l.nv; i++)
                {
                    lb.params[lb.np].name = cap_names[i];
                    lb.params[lb.np].aname = cap_names[i];
                    lb.params[lb.np].ty = l.vv[i].ty;
                    lb.np++;
                }
                l.lbl_capn[ix] = l.nv;
                for (int i = 0; i < l.nv; i++) { l.lbl_cap[(usz)ix * 16 + (usz)i] = cap_names[i]; }
                // lower the label body in the label block: declared params and
                // captured names bind to fresh phi atoms
                int saved = l.nv;
                LBlock* save_cur = l.cur;
                for (int i = 0; i < lb.np; i++)
                {
                    char* nm = i < np0 ? l.lbl_par[(usz)ix * 16 + (usz)i] : cap_names[i - np0];
                    LAtom pa = Lower.fresh(l, lb.params[i].ty);
                    lb.params[i].name = pa.name;
                    lb.params[i].aname = nm;
                    Lower.bind(l, nm, pa);
                }
                l.cur = lb;
                Lower.cmd(l, c.body);
                if (l.lm.errs != 0) { return; }
                if (!l.cur.has_term)
                {
                    Lower.fail(l, "label body does not end in a terminator", c.binder);
                    return;
                }
                l.nv = saved;
                l.cur = save_cur;
                return;                     // the label emitted nothing on the spine
            }
            case ACMD_JUMP:
            {
                int ix = Lower.label_index(l, c.target_label);
                if (ix < 0) { Lower.fail(l, "jump to an unknown label", c.target_label); return; }
                LBlock* lb = l.lbl_blocks[ix];
                int np0 = l.lbl_np[ix];
                LTerm t; t.k = LTM_JUMP; t.target = lb.name; t.a = lair_ir::la_atom_unit();
                t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
                int n = 0;
                for (usz i = 0; i < c.jump_arg_count; i++)
                {
                    if (n >= 24) { Lower.fail(l, "jump passes too many arguments", c.target_label); return; }
                    LAtom v;
                    if (!Lower.lookup(l, c.jump_args[i], &v))
                    {
                        Lower.fail(l, "jump argument is not a bound name", c.jump_args[i]);
                        return;
                    }
                    if (v.ty != lb.params[n].ty)
                    {
                        Lower.fail(l, "jump argument has the wrong type", c.jump_args[i]);
                        return;
                    }
                    t.args[n] = v;
                    n++;
                }
                for (int k = 0; k < l.lbl_capn[ix]; k++)
                {
                    if (n >= 24) { Lower.fail(l, "jump passes too many arguments", c.target_label); return; }
                    LAtom v;
                    if (!Lower.lookup(l, l.lbl_cap[(usz)ix * 16 + (usz)k], &v))
                    {
                        Lower.fail(l, "label environment changed since capture", l.lbl_cap[(usz)ix * 16 + (usz)k]);
                        return;
                    }
                    if (v.ty != lb.params[np0 + k].ty)
                    {
                        Lower.fail(l, "label environment changed since capture", l.lbl_cap[(usz)ix * 16 + (usz)k]);
                        return;
                    }
                    t.args[n] = v;
                    n++;
                }
                t.argc = n;
                Lower.term(l, t);
                return;
            }
            case ACMD_BREAK:
            case ACMD_CONTINUE:
            {
                int ix = Lower.label_index(l, c.target_label);
                if (ix < 0) { Lower.fail(l, "break/continue to an unknown label", c.target_label); return; }
                LBlock* lb = l.lbl_blocks[ix];
                LTerm t; t.k = LTM_JUMP; t.target = lb.name; t.a = lair_ir::la_atom_unit();
                t.t1 = null; t.t2 = null; t.ncase = 0; t.def = null;
                int n = 0;
                for (int k = 0; k < l.lbl_capn[ix]; k++)
                {
                    if (n >= 24) { Lower.fail(l, "break/continue passes too many arguments", c.target_label); return; }
                    LAtom v;
                    if (!Lower.lookup(l, l.lbl_cap[(usz)ix * 16 + (usz)k], &v))
                    {
                        Lower.fail(l, "label environment changed since capture", l.lbl_cap[(usz)ix * 16 + (usz)k]);
                        return;
                    }
                    if (v.ty != lb.params[k].ty)
                    {
                        Lower.fail(l, "label environment changed since capture", l.lbl_cap[(usz)ix * 16 + (usz)k]);
                        return;
                    }
                    t.args[n] = v;
                    n++;
                }
                t.argc = n;
                Lower.term(l, t);
                return;
            }
            case ACMD_MATCH:
            {
                Lower.match(l, c);
                return;
            }
            case ACMD_MUTILDE:
                Lower.fail(l, "nested mu~ (join reification: phase 2)", null);
                return;
            default:
                Lower.fail(l, "command not in the LAIR slice", lair_cmd_name(c.tag));
                return;
        }
    }
}

// ── functions ──────────────────────────────────────────────────────────────
fn bool Lower.func(Lower* l, AirDecl* d)
{
    l.fn_name = d.name;
    l.line = d.source_line;
    l.col = d.source_col;
    l.tmp = 0;
    l.anon = 0;
    l.nv = 0;
    l.ret_name = null;
    l.wl_n = 0;
    l.watch_on = false;
    l.watch_base = 0;
    l.bdepth = 0;
    l.lbl_n = 0;
    LFunc* f = (LFunc*)lair_ir::lair_alloc(l.a, LFunc::size);
    if (f == null) { Lower.fail(l, "out of memory", null); return false; }
    f.name = d.name;
    f.ret = lair_to_lty(d.ret_ty);
    f.source_line = d.source_line;
    l.cur_fn = f;
    AirCmd* body = d.def_body;
    if (body != null && body.tag == ACMD_MUTILDE)
    {
        l.ret_name = body.binder;
        body = body.body;
    }
    else
    {
        Lower.fail(l, "def body is not `mu~ %ret. ...` (labels: phase 2)", null);
        return false;
    }
    while (body != null && body.tag == ACMD_BLOCK) { body = body.body; }
    // parameters
    if (d.param_count > 64) { Lower.fail(l, "more than 64 parameters", null); return false; }
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* p = d.params[i];
        if (p == null) { continue; }
        LTy t = lair_to_lty(p.ty);
        if (t == LT_INVALID || t == LT_SYM)
        {
            Lower.fail(l, "parameter has no type in the LAIR slice (the slice needs annotations)", p.name);
            return false;
        }
        f.params[f.np].name = p.name;
        f.params[f.np].ty = t;
        f.np++;
        if (p.name != null && !(p.name[0] == '_' && p.name[1] == 0))
        {
            Lower.bind(l, p.name, lair_ir::la_atom_var(p.name, t));
        }
    }
    LBlock* entry = lair_ir::lair_new_block(l.a, (char*)"entry");
    if (entry == null) { Lower.fail(l, "out of memory", null); return false; }
    f.blocks[f.nb] = entry;
    f.nb++;
    l.cur = entry;
    // pre-pass: register labels and validate jump targets before lowering
    if (!Lower.collect(l, body)) { return false; }
    if (l.lm.errs != 0) { return false; }
    Lower.cmd(l, body);
    if (l.lm.errs != 0) { return false; }
    if (!l.cur.has_term)
    {
        Lower.fail(l, "the function body does not end in a terminator (no return or delivered continuation)", null);
        return false;
    }
    if (f.ret == LT_INVALID) { f.ret = LT_UNIT; }    // no `ret` anywhere: trap-only body
    if (l.lm.nf >= 256) { Lower.fail(l, "too many functions", null); return false; }
    l.lm.funcs[l.lm.nf] = f;
    l.lm.nf++;
    return true;
}

// ── module ─────────────────────────────────────────────────────────────────
fn int lower_module(AirModule* am, LModule* lm)
{
    Lower l;
    l.am = am;
    l.lm = lm;
    l.a = am.arena;
    l.cur_fn = null;
    l.cur = null;
    l.tmp = 0;
    l.anon = 0;
    l.nv = 0;
    l.ret_name = null;
    l.wl_n = 0;
    l.watch_on = false;
    l.watch_base = 0;
    l.bdepth = 0;
    l.lbl_n = 0;
    l.line = 1;
    l.col = 1;
    l.fn_name = null;
    lm.name = am.name;
    lm.source = am.source_path;
    lm.arena = am.arena;
    lm.errs = 0;
    for (usz i = 0; i < am.decl_count; i++)
    {
        AirDecl* d = am.decls[i];
        if (d == null) { continue; }
        l.line = d.source_line != 0 ? d.source_line : 1;
        l.col = d.source_col != 0 ? d.source_col : 1;
        l.fn_name = d.name;
        switch (d.tag)
        {
            case ADECL_MODULE:
                continue;                   // the header record, not code
            case ADECL_DECLARE:
            {
                LExtern* e = (LExtern*)lair_ir::lair_alloc(lm.arena, LExtern::size);
                if (e == null) { Lower.fail(&l, "out of memory", null); continue; }
                e.name = d.name;
                e.va = d.is_varargs;
                e.ret = lair_to_lty(d.ret_ty);
                if (e.ret == LT_INVALID) { e.ret = LT_UNIT; }
                bool bad = false;
                for (usz p2 = 0; p2 < d.param_count; p2++)
                {
                    if (p2 >= 16) { bad = true; break; }
                    AirBinder* pb = d.params[p2];
                    LTy t = pb == null ? LT_INVALID : lair_to_lty(pb.ty);
                    if (t == LT_INVALID || t == LT_SYM) { bad = true; break; }
                    e.params[e.np] = t;
                    e.np++;
                }
                if (bad)
                {
                    Lower.fail(&l, "extern signature has a type outside the LAIR slice", d.name);
                    continue;
                }
                if (lm.next_ >= 64) { Lower.fail(&l, "too many externs", null); continue; }
                lm.externs[lm.next_] = e;
                lm.next_++;
                continue;
            }
            case ADECL_DEF:
            {
                Lower.func(&l, d);
                continue;
            }
            default:
                Lower.fail(&l, "declaration not in the LAIR slice (data/codata/global/import/...)", d.name);
                continue;
        }
    }
    l.fn_name = null;
    return lm.errs;
}
