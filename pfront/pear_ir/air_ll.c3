// ============================================================================
// air_ll.c3 -- reference consumer of the AIR 3.0 low profile: .air -> LLVM .ll text.
//
// This file is the executable definition of "the .air has everything a backend needs".
// It reads ONLY an AirModule (no AST, no front end, no LLVM library), type-checks every
// function as it goes (the rules of docs/specs/AIR3.md section "Typing"), and prints
// textual LLVM IR. `airtool verify-low` runs the same walk with the output discarded, so
// the type rules and the code generator cannot drift apart.
//
// A PEAR 2 author may copy any part of this; it is deliberately plain.
// Anything outside the low profile is reported as an error naming the construct and the
// function -- never silently compiled to something else.
// ============================================================================
module air_ll;
import air_ir;
import air_text;

extern fn void* malloc(usz size_);
extern fn void* realloc(void* p, usz size_);
extern fn void  free(void* p);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn usz   fwrite(void* p, usz size_, usz count_, void* f);
extern fn void* fdopen(int fd, char* mode);
extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   fflush(void* f);

const usz MAXV = 16384;     // names per function
const usz MAXB = 4096;      // blocks per function
const usz MAXI = 16384;     // phi incoming edges per function
const usz MAXS = 8192;      // string literals per module

// ── string builder ─────────────────────────────────────────────────────────
struct Sb { char* d; usz n; usz cap; }
fn void Sb.init(Sb* s) { s.d = null; s.n = 0; s.cap = 0; }
fn void Sb.reserve(Sb* s, usz more)
{
    if (s.n + more + 1 <= s.cap) { return; }
    usz nc = s.cap == 0 ? 256 : s.cap;
    while (nc < s.n + more + 1) { nc = nc * 2; }
    s.d = (char*)realloc((void*)s.d, nc); s.cap = nc;
}
fn void Sb.putc(Sb* s, char c) { s.reserve(1); s.d[s.n] = c; s.n++; s.d[s.n] = 0; }
fn void Sb.put(Sb* s, char* t)
{
    if (t == null) { return; }
    usz k = 0; while (t[k] != 0) { k++; }
    s.reserve(k);
    for (usz i = 0; i < k; i++) { s.d[s.n + i] = t[i]; }
    s.n = s.n + k; s.d[s.n] = 0;
}
fn void Sb.int_(Sb* s, long v)
{
    if (v == 0) { s.putc('0'); return; }
    char[24] tmp; usz k = 0; bool neg = v < 0;
    ulong u = neg ? (ulong)(0 - v) : (ulong)v;
    while (u > 0) { tmp[k] = (char)('0' + (int)(u % 10)); u = u / 10; k++; }
    if (neg) { s.putc('-'); }
    while (k > 0) { k--; s.putc(tmp[k]); }
}
fn void Sb.hex(Sb* s, ulong v, int digits)
{
    int i = digits - 1;
    while (i >= 0)
    {
        int d = (int)((v >> (ulong)(i * 4)) & 15);
        s.putc((char)(d < 10 ? '0' + d : 'A' + (d - 10)));
        i = i - 1;
    }
}
fn void Sb.name(Sb* s, char sigil, char* nm)   // %"x"  /  @"x"
{
    s.putc(sigil); s.putc('"');
    if (nm != null) { for (usz i = 0; nm[i] != 0; i++) { if (nm[i] == '"' || nm[i] == '\\') { s.putc('_'); } else { s.putc(nm[i]); } } }
    s.putc('"');
}
fn char* Sb.take(Sb* s)
{
    usz n = s.n;
    char* r = (char*)malloc(n + 1);
    for (usz i = 0; i < n; i++) { r[i] = s.d[i]; }
    r[n] = 0; s.n = 0; if (s.d != null) { s.d[0] = 0; }
    return r;
}

// ── types ──────────────────────────────────────────────────────────────────
fn bool ty_is_int(AirTyp* t)
{
    if (t == null) { return false; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_I16: case ATYP_I32: case ATYP_I64: case ATYP_ISZ:
        case ATYP_U8: case ATYP_U16: case ATYP_U32: case ATYP_U64: case ATYP_USZ: case ATYP_CHAR: return true;
        default: return false;
    }
}
fn bool ty_is_signed(AirTyp* t)
{
    if (t == null) { return false; }
    return t.tag == ATYP_I8 || t.tag == ATYP_I16 || t.tag == ATYP_I32 || t.tag == ATYP_I64 || t.tag == ATYP_ISZ;
}
fn int ty_bits(AirTyp* t)
{
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8: return 8;
        case ATYP_I16: case ATYP_U16: return 16;
        case ATYP_I32: case ATYP_U32: case ATYP_CHAR: return 32;
        case ATYP_F32: return 32;
        case ATYP_BOOL: return 1;
        default: return 64;
    }
}
fn bool ty_is_float(AirTyp* t) { return t != null && (t.tag == ATYP_F32 || t.tag == ATYP_F64); }
fn bool ty_is_ptr(AirTyp* t)   { return t != null && (t.tag == ATYP_PTR || t.tag == ATYP_ARROW); }
fn bool ty_is_bool(AirTyp* t)  { return t != null && t.tag == ATYP_BOOL; }
fn bool ty_is_unit(AirTyp* t)  { return t != null && t.tag == ATYP_UNIT; }

fn bool ty_eq(AirTyp* a, AirTyp* b)
{
    if (a == b) { return true; }
    if (a == null || b == null) { return false; }
    if (a.tag != b.tag) { return false; }
    if (a.tag == ATYP_NOMINAL) { return air_text::streq(a.name, b.name); }
    if (a.tag == ATYP_ARRAY && a.ival != b.ival) { return false; }
    if (a.arg_count != b.arg_count) { return false; }
    for (usz i = 0; i < a.arg_count; i++) { if (!ty_eq(a.args[i], b.args[i])) { return false; } }
    return true;
}

// Does `t` mention only things a consumer can size? infer/var/generic/... are rejected.
fn bool ty_low(AirTyp* t, int depth)
{
    if (t == null || depth > 24) { return false; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_I16: case ATYP_I32: case ATYP_I64: case ATYP_ISZ:
        case ATYP_U8: case ATYP_U16: case ATYP_U32: case ATYP_U64: case ATYP_USZ:
        case ATYP_F32: case ATYP_F64: case ATYP_BOOL: case ATYP_CHAR: case ATYP_UNIT: case ATYP_BOTTOM:
        case ATYP_NOMINAL: return true;
        case ATYP_PTR: case ATYP_ARRAY: case ATYP_TUPLE: case ATYP_ARROW:
            for (usz i = 0; i < t.arg_count; i++) { if (!ty_low(t.args[i], depth + 1)) { return false; } }
            return true;
        default: return false;
    }
}


fn char* prd_tag_name(AirPrdTag t)
{
    switch (t)
    {
        case APRD_CON: return "con"; case APRD_INL: return "inl"; case APRD_INR: return "inr"; case APRD_LAMBDA: return "lam";
        case APRD_MU: return "mu"; case APRD_COMETA: return "cometa"; case APRD_OFFSETOF: return "offsetof"; case APRD_ALIGNOF: return "alignof";
        case APRD_REIFY: return "reify"; case APRD_EVAL: return "eval"; case APRD_QUOTE: return "quote"; case APRD_SPLICE: return "splice";
        case APRD_POISON: return "poison"; case APRD_UNREACHABLE_VAL: return "unreachable"; default: return "?";
    }
}
fn char* cns_tag_name(AirCnsTag t)
{
    switch (t)
    {
        case ACNS_FST: return "fst"; case ACNS_SND: return "snd"; case ACNS_PROJ: return "proj"; case ACNS_FIELD: return "field";
        case ACNS_INDEX: return "index"; case ACNS_CALL: return "call"; case ACNS_CASE: return "case"; case ACNS_COCASE: return "cocase";
        case ACNS_DEFAULT: return "default"; case ACNS_ASCRIBE: return "as"; case ACNS_STORE: return "store"; case ACNS_DEREF: return "deref";
        default: return "?";
    }
}
fn char* cmd_tag_name(AirCmdTag t)
{
    switch (t)
    {
        case ACMD_MU: return "mu"; case ACMD_MUTILDE: return "mu~"; case ACMD_LETREC: return "letrec"; case ACMD_WHILE: return "while";
        case ACMD_FOR: return "for"; case ACMD_HANDLE: return "handle"; case ACMD_PERFORM: return "perform"; case ACMD_RESUME: return "resume";
        case ACMD_UNSAFE: return "unsafe"; case ACMD_UNCHECKED: return "unchecked"; case ACMD_COMPTIME: return "comptime";
        case ACMD_ASSERT: return "assert"; case ACMD_ASSUME: return "assume"; case ACMD_BREAK: return "break"; case ACMD_CONTINUE: return "continue";
        case ACMD_DEFER: return "defer"; case ACMD_LABEL: return "label (only legal on the spine of a body)"; case ACMD_ASM: return "asm";
        case ACMD_ATOMIC: return "atomic"; case ACMD_FENCE: return "fence"; case ACMD_BLOCK: return "block"; default: return "?";
    }
}

struct Val { char* op; AirTyp* ty; }

struct Inc { char* val; char* pred; usz blk; usz param; }
struct Blk
{
    char*  name;
    Sb     text;
    AirBinder*[16] params; usz np;
    AirCmd* body;
    bool   done;      // terminated
    bool   is_label;
}

struct Ll
{
    AirModule* m;
    int        errs;
    char*      first_err;
    char*      fn_name;
    bool       emit;
    // per function
    char**     vn;  Val* vv;  usz nv;
    Blk*       blks; usz nb; usz cur;
    Inc*       incs; usz ni;
    Sb         allocas;
    Sb         pre;       // module-level text printed before functions (string constants)
    usz        nstr; usz tmp; usz anon;
    AirTyp*    cur_ret;
    // module level
    Sb         types_out;
}

fn void Ll.err(Ll* l, char* what, char* who)
{
    l.errs++;
    void* se = fdopen(2, "w");
    if (l.errs <= 12) { fprintf(se, "air-ll: in `%s`: %s%s%s\n", l.fn_name == null ? "<module>" : l.fn_name, what, who == null ? "" : ": ", who == null ? "" : who); }
    fflush(se);
}

fn AirDecl* Ll.find(Ll* l, char* nm)
{
    if (nm == null) { return null; }
    for (usz i = 0; i < l.m.decl_count; i++)
    {
        AirDecl* d = l.m.decls[i];
        if (d != null && d.name != null && d.tag != ADECL_MODULE && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}
fn AirDecl* Ll.find_data(Ll* l, char* nm)
{
    for (usz i = 0; i < l.m.decl_count; i++)
    {
        AirDecl* d = l.m.decls[i];
        if (d != null && d.tag == ADECL_DATA && d.name != null && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

// LLVM spelling of a type. Unit is `{}` as a value and `void` only as a return type.
fn void Ll.ty(Ll* l, Sb* o, AirTyp* t)
{
    if (t == null) { l.err("missing type", null); o.put("i64"); return; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8: o.put("i8"); return;
        case ATYP_I16: case ATYP_U16: o.put("i16"); return;
        case ATYP_I32: case ATYP_U32: case ATYP_CHAR: o.put("i32"); return;
        case ATYP_I64: case ATYP_U64: case ATYP_ISZ: case ATYP_USZ: o.put("i64"); return;
        case ATYP_F32: o.put("float"); return;
        case ATYP_F64: o.put("double"); return;
        case ATYP_BOOL: o.put("i1"); return;
        case ATYP_UNIT: o.put("{}"); return;
        case ATYP_PTR: case ATYP_ARROW: o.put("ptr"); return;
        case ATYP_ARRAY:
            o.putc('['); o.int_(t.ival); o.put(" x "); l.ty(o, t.arg_count > 0 ? t.args[0] : null); o.putc(']'); return;
        case ATYP_TUPLE:
            o.put("{ ");
            for (usz i = 0; i < t.arg_count; i++) { if (i > 0) { o.put(", "); } l.ty(o, t.args[i]); }
            o.put(" }"); return;
        case ATYP_NOMINAL: o.putc('%'); o.putc('"'); o.put(t.name); o.putc('"'); return;
        default: l.err("type is not part of the low profile", air_text::typ_kw(t.tag)); o.put("i64"); return;
    }
}
fn void Ll.ret_ty(Ll* l, Sb* o, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM)) { o.put("void"); return; }
    l.ty(o, t);
}

// ── environment ────────────────────────────────────────────────────────────
fn void Ll.bind(Ll* l, char* nm, char* op, AirTyp* ty)
{
    if (nm == null || (nm[0] == '_' && nm[1] == 0)) { return; }
    for (usz i = 0; i < l.nv; i++) { if (air_text::streq(l.vn[i], nm)) { l.err("name bound twice (low profile is single-assignment)", nm); return; } }
    if (l.nv >= MAXV) { l.err("too many names in one function", nm); return; }
    l.vn[l.nv] = nm; l.vv[l.nv].op = op; l.vv[l.nv].ty = ty; l.nv++;
}
fn bool Ll.lookup(Ll* l, char* nm, Val* out)
{
    for (usz i = 0; i < l.nv; i++) { if (air_text::streq(l.vn[i], nm)) { *out = l.vv[i]; return true; } }
    return false;
}
fn char* Ll.fresh(Ll* l)
{
    Sb s; s.init(); s.put("%t"); s.int_((long)l.tmp); l.tmp++;
    return s.take();
}
fn Sb* Ll.out(Ll* l) { return &l.blks[l.cur].text; }

fn AirTyp* Ll.mk_ptr(Ll* l, AirTyp* inner)
{
    return air_ir::air_mk_typ_ptr(l.m.arena, inner);
}
fn AirTyp* Ll.fn_type_of(Ll* l, AirDecl* d)
{
    AirTyp* dom = air_ir::air_mk_typ(l.m.arena, ATYP_TUPLE);
    for (usz i = 0; i < d.param_count; i++) { if (d.params[i] != null) { dom.add_arg(d.params[i].ty); } }
    AirTyp* a = air_ir::air_mk_typ(l.m.arena, ATYP_ARROW);
    a.add_arg(dom); a.add_arg(d.ret_ty);
    return a;
}

// ── producers ──────────────────────────────────────────────────────────────
fn char* Ll.str_const(Ll* l, AirPrd* p)
{
    usz id = l.nstr; l.nstr++;
    Sb nm; nm.init(); nm.put("@.str."); nm.int_((long)id);
    char* name = nm.take();
    usz n = (usz)p.bytes_len;
    char* data = p.tag == APRD_BYTES ? p.bytes : p.name;
    l.pre.put(name); l.pre.put(" = private unnamed_addr constant [");
    l.pre.int_((long)(n + 1)); l.pre.put(" x i8] c\"");
    for (usz i = 0; i < n; i++)
    {
        int ch = (int)(data[i]) & 255;
        if (ch >= 32 && ch < 127 && ch != '"' && ch != '\\') { l.pre.putc((char)ch); }
        else { l.pre.putc('\\'); l.pre.hex((ulong)ch, 2); }
    }
    l.pre.put("\\00\"\n");
    return name;
}

fn Val Ll.prd(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = null;
    if (p == null) { l.err("missing producer", null); return v; }
    switch (p.tag)
    {
        case APRD_VAR:
        {
            Val got;
            if (l.lookup(p.name, &got)) { return got; }
            AirDecl* d = l.find(p.name);
            if (d != null)
            {
                Sb s; s.init(); s.name('@', p.name); v.op = s.take();
                if (d.tag == ADECL_GLOBAL) { v.ty = l.mk_ptr(d.ret_ty); }
                else if (d.tag == ADECL_DEF || d.tag == ADECL_DECLARE) { v.ty = l.fn_type_of(d); }
                else { l.err("name is not a value", p.name); }
                return v;
            }
            l.err("unbound variable", p.name); return v;
        }
        case APRD_INT:
        {
            if (!ty_is_int(p.ty)) { l.err("integer literal without an integer type", null); v.ty = l.m.t_i64; }
            else { v.ty = p.ty; }
            Sb s; s.init(); s.int_(p.ival); v.op = s.take(); return v;
        }
        case APRD_FLOAT:
        {
            if (!ty_is_float(p.ty)) { l.err("float literal without a float type", null); v.ty = l.m.t_f64; } else { v.ty = p.ty; }
            double dv = p.fval; ulong bits = 0;
            // bit pattern of the double via memcpy-free union trick
            ulong* bp = (ulong*)&dv; bits = *bp;
            Sb s; s.init(); s.put("0x"); s.hex(bits, 16); v.op = s.take(); return v;
        }
        case APRD_BOOL: v.ty = l.m.t_bool; v.op = p.bval ? "true" : "false"; return v;
        case APRD_CHAR: v.ty = l.m.t_char; { Sb s; s.init(); s.int_(p.ival); v.op = s.take(); } return v;
        case APRD_UNIT: v.ty = l.m.t_unit; v.op = "zeroinitializer"; return v;
        case APRD_NULL:
        {
            if (p.ty == null || p.ty.tag != ATYP_PTR) { l.err("null without a pointer type", null); }
            v.ty = p.ty != null ? p.ty : l.mk_ptr(l.m.t_u8); v.op = "null"; return v;
        }
        case APRD_STRING: case APRD_BYTES:
            v.ty = l.mk_ptr(l.m.t_u8); v.op = l.str_const(p); return v;
        case APRD_BINOP: return l.binop(p);
        case APRD_UNOP:  return l.unop(p);
        case APRD_COERCE: return l.coerce(p);
        case APRD_ALLOCA:
        {
            if (!ty_low(p.ty_arg, 0)) { l.err("alloca of a non-low type", null); }
            char* t = l.fresh();
            l.allocas.put("  "); l.allocas.put(t); l.allocas.put(" = alloca "); l.ty(&l.allocas, p.ty_arg); l.allocas.put("\n");
            v.op = t; v.ty = l.mk_ptr(p.ty_arg); return v;
        }
        case APRD_LOAD:
        {
            Val a = l.prd(p.sub_count > 0 ? p.subs[0] : null);
            if (a.ty == null || a.ty.tag != ATYP_PTR) { l.err("load from a non-pointer", null); return v; }
            AirTyp* et = a.ty.args[0];
            if (p.ty != null && !ty_eq(p.ty, et)) { l.err("load annotation differs from the pointee type", null); }
            char* t = l.fresh();
            Sb* o = l.out(); o.put("  "); o.put(t); o.put(" = load "); l.ty(o, et); o.put(", ptr "); o.put(a.op); o.putc('\n');
            v.op = t; v.ty = et; return v;
        }
        case APRD_GEP: return l.gep(p);
        case APRD_TUPLE: case APRD_RECORD: case APRD_ARRAY: return l.aggregate(p);
        case APRD_SIZEOF:
        {
            // sizeof via the gep-null-1 idiom; folds to a constant in LLVM
            char* t1 = l.fresh(); char* t2 = l.fresh();
            Sb* o = l.out();
            o.put("  "); o.put(t1); o.put(" = getelementptr "); l.ty(o, p.ty); o.put(", ptr null, i64 1\n");
            o.put("  "); o.put(t2); o.put(" = ptrtoint ptr "); o.put(t1); o.put(" to i64\n");
            v.op = t2; v.ty = l.m.t_usz; return v;
        }
        default:
            l.err("producer is not part of the low profile", prd_tag_name(p.tag)); return v;
    }
}

// An initialiser constant for a global (LLVM constant syntax, without the leading type).
fn void Ll.const_init(Ll* l, Sb* o, AirPrd* g, AirTyp* t, char* gname)
{
    if (g == null || t == null) { l.err("global initialiser must be a constant", gname); o.put("zeroinitializer"); return; }
    switch (g.tag)
    {
        case APRD_INT: case APRD_CHAR: o.int_(g.ival); return;
        case APRD_BOOL: o.put(g.bval ? "true" : "false"); return;
        case APRD_NULL: o.put("null"); return;
        case APRD_UNIT: o.put("zeroinitializer"); return;
        case APRD_FLOAT: { double dv = g.fval; ulong* bp = (ulong*)&dv; o.put("0x"); o.hex(*bp, 16); return; }
        case APRD_STRING: case APRD_BYTES: o.put(l.str_const(g)); return;
        case APRD_TUPLE: case APRD_ARRAY:
        {
            bool is_t = g.tag == APRD_TUPLE;
            if (is_t && (t.tag != ATYP_TUPLE || t.arg_count != g.sub_count)) { l.err("tuple initialiser does not match its type", gname); return; }
            if (!is_t && (t.tag != ATYP_ARRAY || t.ival != (long)g.sub_count)) { l.err("array initialiser does not match its length", gname); return; }
            o.put(is_t ? "{ " : "[ ");
            for (usz i = 0; i < g.sub_count; i++)
            {
                if (i > 0) { o.put(", "); }
                AirTyp* et = is_t ? t.args[i] : t.args[0];
                l.ty(o, et); o.putc(' '); l.const_init(o, g.subs[i], et, gname);
            }
            o.put(is_t ? " }" : " ]");
            return;
        }
        case APRD_RECORD:
        {
            if (t.tag != ATYP_NOMINAL) { l.err("record initialiser without a nominal type", gname); return; }
            AirDecl* dd = l.find_data(t.name);
            if (dd == null || dd.ctor_count != 1 || dd.ctors[0].field_count != g.rec_init_count) { l.err("record initialiser does not match its declaration", gname); return; }
            AirCtorDecl* c = dd.ctors[0];
            o.put("{ ");
            for (usz i = 0; i < c.field_count; i++)
            {
                if (i > 0) { o.put(", "); }
                if (!air_text::streq(c.fields[i].name, g.rec_inits[i].name)) { l.err("record initialiser fields out of declaration order", gname); return; }
                l.ty(o, c.fields[i].ty); o.putc(' '); l.const_init(o, g.rec_inits[i].value, c.fields[i].ty, gname);
            }
            o.put(" }");
            return;
        }
        default: break;
    }
    l.err("global initialiser must be a constant", gname); o.put("zeroinitializer");
}

fn Val Ll.aggregate(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = p.ty;
    if (p.ty == null) { l.err("aggregate without a type", null); return v; }
    usz n = p.tag == APRD_RECORD ? p.rec_init_count : p.sub_count;
    Val[64] parts;
    AirTyp*[64] want;
    if (n > 64) { l.err("aggregate with more than 64 parts", null); return v; }
    if (p.tag == APRD_TUPLE)
    {
        if (p.ty.tag != ATYP_TUPLE || p.ty.arg_count != n) { l.err("tuple type does not match its parts", null); return v; }
        for (usz i = 0; i < n; i++) { want[i] = p.ty.args[i]; }
    }
    else if (p.tag == APRD_ARRAY)
    {
        if (p.ty.tag != ATYP_ARRAY || p.ty.ival != (long)n) { l.err("array type does not match its length", null); return v; }
        for (usz i = 0; i < n; i++) { want[i] = p.ty.args[0]; }
    }
    else
    {
        if (p.ty.tag != ATYP_NOMINAL) { l.err("record without a nominal type", null); return v; }
        AirDecl* d = l.find_data(p.ty.name);
        if (d == null || d.ctor_count != 1) { l.err("record of a type that is not a single-constructor data", p.ty.name); return v; }
        AirCtorDecl* c = d.ctors[0];
        if (c.field_count != n) { l.err("record field count differs from the declaration", p.ty.name); return v; }
        for (usz i = 0; i < n; i++)
        {
            bool found = false;
            for (usz j = 0; j < c.field_count; j++)
            {
                if (air_text::streq(c.fields[j].name, p.rec_inits[i].name)) { want[i] = c.fields[j].ty; found = true; }
            }
            if (!found) { l.err("record field is not declared", p.rec_inits[i].name); }
        }
        // fields must appear in declaration order (consumer-visible layout)
        for (usz i = 0; i < n && i < c.field_count; i++)
        {
            if (!air_text::streq(c.fields[i].name, p.rec_inits[i].name)) { l.err("record fields out of declaration order", p.rec_inits[i].name); break; }
        }
    }
    for (usz i = 0; i < n; i++)
    {
        parts[i] = l.prd(p.tag == APRD_RECORD ? p.rec_inits[i].value : p.subs[i]);
        if (parts[i].ty != null && want[i] != null && !ty_eq(parts[i].ty, want[i])) { l.err("aggregate part has the wrong type", null); }
    }
    char* cur = "undef";
    for (usz i = 0; i < n; i++)
    {
        char* t = l.fresh();
        Sb* o = l.out();
        o.put("  "); o.put(t); o.put(" = insertvalue "); l.ty(o, p.ty); o.putc(' '); o.put(cur); o.put(", ");
        l.ty(o, want[i]); o.putc(' '); o.put(parts[i].op); o.put(", "); o.int_((long)i); o.putc('\n');
        cur = t;
    }
    v.op = cur;
    return v;
}

fn Val Ll.gep(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = null;
    Val b = l.prd(p.subs[0]);
    if (b.ty == null || b.ty.tag != ATYP_PTR) { l.err("gep base is not a pointer", null); return v; }
    AirTyp* cur = p.ty_arg;
    if (!ty_low(cur, 0)) { l.err("gep over a non-low type", null); return v; }
    if (!ty_eq(b.ty.args[0], cur)) { l.err("gep source element type differs from the base pointee", null); }
    Sb* o = l.out();
    Val[16] idx; char* t0 = null;
    for (usz i = 1; i < p.sub_count; i++) { idx[i] = l.prd(p.subs[i]); }
    char* t = l.fresh();
    // emit after operands are computed (they may have printed instructions)
    o = l.out();
    o.put("  "); o.put(t); o.put(" = getelementptr "); l.ty(o, p.ty_arg); o.put(", ptr "); o.put(b.op);
    for (usz i = 1; i < p.sub_count; i++)
    {
        if (!ty_is_int(idx[i].ty)) { l.err("gep index is not an integer", null); }
        o.put(", ");
        if (i == 1) { l.ty(o, idx[i].ty); o.putc(' '); o.put(idx[i].op); continue; }
        // step into the aggregate
        if (cur == null) { l.err("gep indexes past a scalar", null); continue; }
        if (cur.tag == ATYP_ARRAY) { l.ty(o, idx[i].ty); o.putc(' '); o.put(idx[i].op); cur = cur.args[0]; }
        else if (cur.tag == ATYP_TUPLE || cur.tag == ATYP_NOMINAL)
        {
            AirPrd* ip = p.subs[i];
            if (ip == null || ip.tag != APRD_INT) { l.err("struct gep index must be a literal", null); o.put("i32 0"); continue; }
            o.put("i32 "); o.int_(ip.ival);
            if (cur.tag == ATYP_TUPLE) { cur = ip.ival >= 0 && (usz)ip.ival < cur.arg_count ? cur.args[(usz)ip.ival] : null; }
            else
            {
                AirDecl* dd = l.find_data(cur.name);
                cur = (dd != null && dd.ctor_count == 1 && ip.ival >= 0 && (usz)ip.ival < dd.ctors[0].field_count) ? dd.ctors[0].fields[(usz)ip.ival].ty : null;
            }
        }
        else { l.err("gep indexes into a type with no members", null); o.put("i32 0"); }
    }
    o.putc('\n');
    v.op = t; v.ty = cur == null ? null : l.mk_ptr(cur);
    if (p.ty != null && v.ty != null && !ty_eq(p.ty, v.ty)) { l.err("gep annotation differs from the computed pointer type", null); }
    return v;
}

fn Val Ll.binop(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = null;
    Val a = l.prd(p.subs[0]); Val b = l.prd(p.subs[1]);
    if (a.ty == null || b.ty == null) { return v; }
    if (!ty_eq(a.ty, b.ty)) { l.err("binary operands have different types", air_text::binop_name(p.bop)); return v; }
    AirTyp* t = a.ty;
    bool isi = ty_is_int(t); bool isf = ty_is_float(t); bool isb = ty_is_bool(t); bool isp = ty_is_ptr(t);
    char* opn = null; bool cmp = false; bool boolres = false;
    switch (p.bop)
    {
        case ABIN_ADD: opn = isf ? "fadd" : "add"; break;
        case ABIN_SUB: opn = isf ? "fsub" : "sub"; break;
        case ABIN_MUL: opn = isf ? "fmul" : "mul"; break;
        case ABIN_DIV: opn = isf ? "fdiv" : (ty_is_signed(t) ? "sdiv" : "udiv"); break;
        case ABIN_MOD: opn = isf ? "frem" : (ty_is_signed(t) ? "srem" : "urem"); break;
        case ABIN_AND: case ABIN_LAND: opn = "and"; break;
        case ABIN_OR: case ABIN_LOR: opn = "or"; break;
        case ABIN_XOR: opn = "xor"; break;
        case ABIN_SHL: opn = "shl"; break;
        case ABIN_SHR: opn = ty_is_signed(t) ? "ashr" : "lshr"; break;
        case ABIN_EQ: cmp = true; opn = isf ? "fcmp oeq" : "icmp eq"; break;
        case ABIN_NEQ: cmp = true; opn = isf ? "fcmp une" : "icmp ne"; break;
        case ABIN_LT: cmp = true; opn = isf ? "fcmp olt" : (ty_is_signed(t) ? "icmp slt" : "icmp ult"); break;
        case ABIN_GT: cmp = true; opn = isf ? "fcmp ogt" : (ty_is_signed(t) ? "icmp sgt" : "icmp ugt"); break;
        case ABIN_LE: cmp = true; opn = isf ? "fcmp ole" : (ty_is_signed(t) ? "icmp sle" : "icmp ule"); break;
        case ABIN_GE: cmp = true; opn = isf ? "fcmp oge" : (ty_is_signed(t) ? "icmp sge" : "icmp uge"); break;
        default: l.err("binary operator is not part of the low profile", air_text::binop_name(p.bop)); return v;
    }
    boolres = cmp;
    bool arith = p.bop == ABIN_ADD || p.bop == ABIN_SUB || p.bop == ABIN_MUL || p.bop == ABIN_DIV || p.bop == ABIN_MOD;
    bool bits = p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR || p.bop == ABIN_SHL || p.bop == ABIN_SHR;
    bool logic = p.bop == ABIN_LAND || p.bop == ABIN_LOR;
    if (arith && !(isi || isf)) { l.err("arithmetic on a non-number", air_text::binop_name(p.bop)); return v; }
    if (bits && !(isi || (isb && (p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR)))) { l.err("bitwise operation on a non-integer", air_text::binop_name(p.bop)); return v; }
    if (logic && !isb) { l.err("land/lor need bool operands", null); return v; }
    if (cmp && !(isi || isf || isb || isp)) { l.err("comparison of a type with no order", null); return v; }
    if (cmp && isf == false && !(isi || isb || isp)) { l.err("comparison of this type", null); return v; }
    if (cmp && (isb || isp) && !(p.bop == ABIN_EQ || p.bop == ABIN_NEQ)) { l.err("ordered comparison of bool/pointer", null); return v; }
    char* r = l.fresh();
    Sb* o = l.out();
    o.put("  "); o.put(r); o.put(" = "); o.put(opn); o.putc(' '); l.ty(o, t); o.putc(' '); o.put(a.op); o.put(", "); o.put(b.op); o.putc('\n');
    v.op = r; v.ty = boolres ? l.m.t_bool : t;
    if (p.ty != null && !ty_eq(p.ty, v.ty)) { l.err("operation annotation differs from the computed type", air_text::binop_name(p.bop)); }
    return v;
}

fn Val Ll.unop(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = null;
    Val a = l.prd(p.subs[0]);
    if (a.ty == null) { return v; }
    char* r = l.fresh(); Sb* o = l.out();
    switch (p.uop)
    {
        case AUN_NEG:
            if (ty_is_float(a.ty)) { o.put("  "); o.put(r); o.put(" = fneg "); l.ty(o, a.ty); o.putc(' '); o.put(a.op); o.putc('\n'); }
            else if (ty_is_int(a.ty)) { o.put("  "); o.put(r); o.put(" = sub "); l.ty(o, a.ty); o.put(" 0, "); o.put(a.op); o.putc('\n'); }
            else { l.err("neg of a non-number", null); return v; }
            break;
        case AUN_NOT:
            if (!ty_is_bool(a.ty)) { l.err("not of a non-bool", null); return v; }
            o.put("  "); o.put(r); o.put(" = xor i1 "); o.put(a.op); o.put(", true\n"); break;
        case AUN_BITNOT:
            if (!ty_is_int(a.ty)) { l.err("bitnot of a non-integer", null); return v; }
            o.put("  "); o.put(r); o.put(" = xor "); l.ty(o, a.ty); o.putc(' '); o.put(a.op); o.put(", -1\n"); break;
        default: l.err("unary operator is not part of the low profile", air_text::unop_name(p.uop)); return v;
    }
    v.op = r; v.ty = a.ty;
    if (p.ty != null && !ty_eq(p.ty, v.ty)) { l.err("operation annotation differs from the computed type", null); }
    return v;
}

fn Val Ll.coerce(Ll* l, AirPrd* p)
{
    Val v; v.op = "undef"; v.ty = p.ty;
    Val a = l.prd(p.subs[0]);
    AirTyp* to = p.ty;
    if (a.ty == null || to == null) { l.err("coerce without types", null); return v; }
    if (!ty_low(to, 0)) { l.err("coerce to a non-low type", null); return v; }
    if (ty_eq(a.ty, to)) { v.op = a.op; return v; }
    char* kind = null;
    AirTyp* f = a.ty;
    bool fi = ty_is_int(f) || ty_is_bool(f); bool ti = ty_is_int(to) || ty_is_bool(to);
    if (fi && ti)
    {
        int fb = ty_bits(f); int tb = ty_bits(to);
        if (fb == tb) { v.op = a.op; return v; }       // same width, different signedness: no-op
        kind = fb > tb ? "trunc" : ((ty_is_signed(f) && !ty_is_bool(f)) ? "sext" : "zext");
    }
    else if (fi && ty_is_float(to)) { kind = (ty_is_signed(f) && !ty_is_bool(f)) ? "sitofp" : "uitofp"; }
    else if (ty_is_float(f) && ti) { kind = ty_is_signed(to) ? "fptosi" : "fptoui"; }
    else if (ty_is_float(f) && ty_is_float(to)) { kind = ty_bits(f) < ty_bits(to) ? "fpext" : "fptrunc"; }
    else if (ty_is_ptr(f) && ti) { kind = "ptrtoint"; }
    else if (fi && ty_is_ptr(to)) { kind = "inttoptr"; }
    else if (ty_is_ptr(f) && ty_is_ptr(to)) { v.op = a.op; return v; }
    else if ((f.tag == ATYP_ARROW && ty_is_ptr(to)) || (ty_is_ptr(f) && to.tag == ATYP_ARROW)) { v.op = a.op; return v; }   // a code pointer is a pointer
    else { l.err("coerce between these types is not defined", null); return v; }
    char* r = l.fresh(); Sb* o = l.out();
    o.put("  "); o.put(r); o.putc(' '); o.put("= "); o.put(kind); o.putc(' '); l.ty(o, f); o.putc(' '); o.put(a.op); o.put(" to "); l.ty(o, to); o.putc('\n');
    v.op = r; return v;
}

// ── commands ───────────────────────────────────────────────────────────────
fn usz Ll.new_block(Ll* l, char* name, bool is_label)
{
    if (l.nb >= MAXB) { l.err("too many blocks", null); return 0; }
    Blk* b = &l.blks[l.nb];
    b.name = name; b.text.init(); b.np = 0; b.body = null; b.done = false; b.is_label = is_label;
    l.nb++;
    return l.nb - 1;
}
fn usz Ll.find_label(Ll* l, char* nm)
{
    for (usz i = 0; i < l.nb; i++) { if (l.blks[i].is_label && air_text::streq(l.blks[i].name, nm)) { return i; } }
    return MAXB;
}
fn char* Ll.anon_name(Ll* l, char* stem)
{
    Sb s; s.init(); s.put("a."); s.put(stem); s.int_((long)l.anon); l.anon++; return s.take();   // `a.` keeps emitter-made blocks apart from the program's own labels
}

fn void Ll.terminate(Ll* l) { l.blks[l.cur].done = true; }

fn void Ll.emit_ret(Ll* l, AirPrd* p)
{
    Sb* o = l.out();
    if (l.cur_ret == null || ty_is_unit(l.cur_ret) || l.cur_ret.tag == ATYP_BOTTOM)
    {
        if (p != null) { Val v = l.prd(p); if (v.ty != null && !ty_is_unit(v.ty)) { l.err("ret of a value in a unit function", null); } }
        l.out().put("  ret void\n");
    }
    else
    {
        Val v = l.prd(p);
        if (v.ty != null && !ty_eq(v.ty, l.cur_ret)) { l.err("ret value type differs from the function's return type", null); }
        o = l.out(); o.put("  ret "); l.ty(o, l.cur_ret); o.putc(' '); o.put(v.op); o.putc('\n');
    }
    l.terminate();
}

// call: args come from the STACK chain, the result continuation is the COMU at its end
fn void Ll.emit_call(Ll* l, AirPrd* callee, AirCns* k, AirCmd** next_out, char** bind_out)
{
    Val f = l.prd(callee);
    Val[16] args; usz na = 0;
    AirCns* cur = k.tail;
    while (cur != null && cur.tag == ACNS_STACK)
    {
        if (na >= 16) { l.err("call with more than 16 arguments", null); return; }
        args[na] = l.prd(cur.prd); na++; cur = cur.tail;
    }
    if (cur == null || cur.tag != ACNS_COMU) { l.err("call result must be bound with `comu`", null); return; }
    AirDecl* d = null;
    if (callee.tag == APRD_VAR) { Val tmpv; if (!l.lookup(callee.name, &tmpv)) { d = l.find(callee.name); } }
    AirTyp* ft = f.ty;
    if (ft == null || ft.tag != ATYP_ARROW) { l.err("callee is not a function", null); return; }
    AirTyp* dom = ft.args[0]; AirTyp* ret = ft.args[1];
    bool va = d != null && d.is_varargs;
    if (dom.arg_count > na || (!va && dom.arg_count != na)) { l.err("call has the wrong number of arguments", callee.name); return; }
    for (usz i = 0; i < dom.arg_count; i++)
    {
        if (args[i].ty != null && !ty_eq(args[i].ty, dom.args[i])) { l.err("argument has the wrong type", callee.name); }
    }
    bool isvoid = ret == null || ty_is_unit(ret) || ret.tag == ATYP_BOTTOM;
    char* r = isvoid ? "zeroinitializer" : l.fresh();
    Sb* o = l.out();
    o.put("  ");
    if (!isvoid) { o.put(r); o.put(" = "); }
    o.put("call ");
    l.ret_ty(o, ret);
    if (va)
    {
        o.put(" (");
        for (usz i = 0; i < dom.arg_count; i++) { if (i > 0) { o.put(", "); } l.ty(o, dom.args[i]); }
        if (dom.arg_count > 0) { o.put(", "); }
        o.put("...)");
    }
    o.putc(' '); o.put(f.op); o.putc('(');
    for (usz i = 0; i < na; i++) { if (i > 0) { o.put(", "); } l.ty(o, args[i].ty); o.putc(' '); o.put(args[i].op); }
    o.put(")\n");
    AirTyp* rt = isvoid ? l.m.t_unit : ret;
    l.bind(cur.bind, r, rt);
    *next_out = cur.body; *bind_out = cur.bind;
    if (ret != null && ret.tag == ATYP_BOTTOM) { l.out().put("  unreachable\n"); l.terminate(); }
}

fn void Ll.cmd(Ll* l, AirCmd* c)
{
    while (c != null && !l.blks[l.cur].done)
    {
        switch (c.tag)
        {
            case ACMD_NOP: return;
            case ACMD_LET:
            {
                Val v = l.prd(c.prd);
                l.bind(c.binder, v.op, v.ty);
                c = c.body; continue;
            }
            case ACMD_SEQ:
            {
                l.cmd(c.body);
                if (l.blks[l.cur].done) { return; }
                c = c.next; continue;
            }
            case ACMD_STORE:
            {
                Val p = l.prd(c.prds[0]); Val v = l.prd(c.prds[1]);
                if (p.ty == null || p.ty.tag != ATYP_PTR) { l.err("store to a non-pointer", null); return; }
                if (v.ty != null && !ty_eq(p.ty.args[0], v.ty)) { l.err("stored value type differs from the pointee type", null); }
                if (ty_is_unit(v.ty)) { return; }
                Sb* o = l.out(); o.put("  store "); l.ty(o, v.ty); o.putc(' '); o.put(v.op); o.put(", ptr "); o.put(p.op); o.putc('\n');
                return;
            }
            case ACMD_RET: l.emit_ret(c.prd); return;
            case ACMD_TRAP: l.out().put("  call void @llvm.trap()\n  unreachable\n"); l.terminate(); return;
            case ACMD_UB:   l.out().put("  unreachable\n"); l.terminate(); return;
            case ACMD_JUMP:
            {
                usz bi = l.find_label(c.target_label);
                if (bi == MAXB) { l.err("jump to an unknown label", c.target_label); l.terminate(); return; }
                Blk* tb = &l.blks[bi];
                if (tb.np != c.jump_arg_count) { l.err("jump has the wrong number of arguments", c.target_label); }
                for (usz i = 0; i < c.jump_arg_count && i < tb.np; i++)
                {
                    Val a; if (!l.lookup(c.jump_args[i], &a)) { l.err("jump argument is unbound", c.jump_args[i]); continue; }
                    if (a.ty != null && !ty_eq(a.ty, tb.params[i].ty)) { l.err("jump argument has the wrong type", c.jump_args[i]); }
                    if (l.ni >= MAXI) { l.err("too many jump arguments", null); continue; }
                    l.incs[l.ni].val = a.op; l.incs[l.ni].pred = l.blks[l.cur].name; l.incs[l.ni].blk = bi; l.incs[l.ni].param = i; l.ni++;
                }
                Sb* o = l.out(); o.put("  br label %"); o.putc('"'); o.put(c.target_label); o.put("\"\n");
                l.terminate(); return;
            }
            case ACMD_IF:
            {
                Val cv = l.prd(c.prd);
                if (!ty_is_bool(cv.ty)) { l.err("if condition is not a bool", null); }
                char* tn = l.anon_name("then"); char* en = l.anon_name("else");
                Sb* o = l.out();
                o.put("  br i1 "); o.put(cv.op); o.put(", label %"); o.putc('"'); o.put(tn); o.put("\", label %"); o.putc('"'); o.put(en); o.put("\"\n");
                l.terminate();
                usz ti = l.new_block(tn, false); usz ei = l.new_block(en, false);
                l.cur = ti; l.cmd(c.then_c); if (!l.blks[l.cur].done) { l.err("then-branch falls off its block", null); }
                l.cur = ei; l.cmd(c.else_c); if (!l.blks[l.cur].done) { l.err("else-branch falls off its block", null); }
                return;
            }
            case ACMD_MATCH: { l.emit_switch(c); return; }
            case ACMD_CUT:
            {
                AirCns* k = c.cns;
                if (k == null) { l.err("cut without a consumer", null); return; }
                if (k.tag == ACNS_COMU)
                {
                    Val v = l.prd(c.prd); l.bind(k.bind, v.op, v.ty); c = k.body; continue;
                }
                if (k.tag == ACNS_COVAR) { l.emit_ret(c.prd); return; }
                if (k.tag == ACNS_CALL)
                {
                    AirCmd* nx = null; char* bn = null;
                    l.emit_call(c.prd, k, &nx, &bn);
                    if (l.blks[l.cur].done) { return; }
                    if (nx == null) { l.err("call continuation is empty", null); return; }
                    c = nx; continue;
                }
                if ((k.tag == ACNS_FIELD || k.tag == ACNS_PROJ) && k.tail != null && k.tail.tag == ACNS_COMU)
                {
                    Val a = l.prd(c.prd);
                    AirTyp* ft = null; long ix = -1;
                    if (k.tag == ACNS_PROJ)
                    {
                        ix = k.idx;
                        if (a.ty == null || a.ty.tag != ATYP_TUPLE || ix < 0 || (usz)ix >= a.ty.arg_count) { l.err("proj outside the tuple", null); return; }
                        ft = a.ty.args[(usz)ix];
                    }
                    else
                    {
                        if (a.ty == null || a.ty.tag != ATYP_NOMINAL) { l.err("field of a non-record", k.name); return; }
                        AirDecl* dd = l.find_data(a.ty.name);
                        if (dd == null || dd.ctor_count != 1) { l.err("field of a type that is not a single-constructor data", a.ty.name); return; }
                        AirCtorDecl* cd = dd.ctors[0];
                        for (usz j = 0; j < cd.field_count; j++) { if (air_text::streq(cd.fields[j].name, k.name)) { ix = (long)j; ft = cd.fields[j].ty; } }
                        if (ix < 0) { l.err("field is not declared", k.name); return; }
                        if (k.idx != ix) { l.err("field slot number differs from the declaration", k.name); }
                    }
                    char* r = l.fresh(); Sb* o = l.out();
                    o.put("  "); o.put(r); o.put(" = extractvalue "); l.ty(o, a.ty); o.putc(' '); o.put(a.op); o.put(", "); o.int_(ix); o.putc('\n');
                    l.bind(k.tail.bind, r, ft); c = k.tail.body; continue;
                }
                l.err("consumer is not part of the low profile", cns_tag_name(k.tag)); return;
            }
            case ACMD_SYSCALL:
            {
                Val[8] a; usz na = 0;
                a[0] = l.prd(c.prd); na = 1;
                for (usz i = 0; i < c.prd_count && na < 8; i++) { a[na] = l.prd(c.prds[i]); na++; }
                for (usz i = 0; i < na; i++) { if (a[i].ty == null || a[i].ty.tag != ATYP_I64) { l.err("syscall operands must be i64", null); break; } }
                char* r = l.fresh(); Sb* o = l.out();
                o.put("  "); o.put(r); o.put(" = call i64 (i64, ...) @syscall(");
                for (usz i = 0; i < na; i++) { if (i > 0) { o.put(", "); } o.put("i64 "); o.put(a[i].op); }
                o.put(")\n");
                if (c.cns == null || c.cns.tag != ACNS_COMU) { l.err("syscall result must be bound with `comu`", null); return; }
                l.bind(c.cns.bind, r, l.m.t_i64); c = c.cns.body; continue;
            }
            default:
                l.err("command is not part of the low profile", cmd_tag_name(c.tag)); return;
        }
    }
}

fn void Ll.emit_switch(Ll* l, AirCmd* c)
{
    Val s = l.prd(c.prd);
    if (!(ty_is_int(s.ty) || ty_is_bool(s.ty))) { l.err("match scrutinee is not an integer or bool", null); l.terminate(); return; }
    usz[64] bi; long[64] cv; usz nc = 0; usz def = MAXB;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b == null || b.pat == null) { continue; }
        if (b.guard != null) { l.err("match guard in the low profile", null); }
        if (b.pat.tag == APAT_WILD || b.pat.tag == APAT_BIND)
        {
            if (b.pat.tag == APAT_BIND) { l.bind(b.pat.name, s.op, s.ty); }
            def = l.new_block(l.anon_name("dflt"), false); l.blks[def].body = b.body; if (def == MAXB) { } continue;
        }
        if (b.pat.tag == APAT_INT || b.pat.tag == APAT_BOOL || b.pat.tag == APAT_CHAR)
        {
            if (nc >= 64) { l.err("switch with more than 64 cases", null); continue; }
            bi[nc] = l.new_block(l.anon_name("case"), false); cv[nc] = b.pat.ival; l.blks[bi[nc]].body = b.body; nc++;
            continue;
        }
        l.err("pattern is not part of the low profile", null);
    }
    if (def == MAXB) { def = l.new_block(l.anon_name("dflt"), false); l.blks[def].body = null; }
    Sb* o = l.out();
    o.put("  switch "); l.ty(o, s.ty); o.putc(' '); o.put(s.op); o.put(", label %"); o.putc('"'); o.put(l.blks[def].name); o.put("\" [\n");
    for (usz i = 0; i < nc; i++) { o.put("    "); l.ty(o, s.ty); o.putc(' '); o.int_(cv[i]); o.put(", label %"); o.putc('"'); o.put(l.blks[bi[i]].name); o.put("\"\n"); }
    o.put("  ]\n");
    l.terminate();
    for (usz i = 0; i < nc; i++) { l.cur = bi[i]; l.cmd(l.blks[bi[i]].body); if (!l.blks[l.cur].done) { l.err("switch case falls off its block", null); } }
    l.cur = def;
    if (l.blks[def].body == null) { l.out().put("  unreachable\n"); l.terminate(); }
    else { l.cmd(l.blks[def].body); if (!l.blks[l.cur].done) { l.err("switch default falls off its block", null); } }
}

// ── functions and module ───────────────────────────────────────────────────
fn void Ll.function(Ll* l, AirDecl* d, Sb* out)
{
    l.fn_name = d.name;
    l.nv = 0; l.nb = 0; l.ni = 0; l.tmp = 0; l.anon = 0; l.allocas.n = 0; if (l.allocas.d != null) { l.allocas.d[0] = 0; }
    l.cur_ret = d.ret_ty;
    if (!ty_low(d.ret_ty, 0)) { l.err("return type is not part of the low profile", null); }
    bool is_main = air_text::streq(d.name, "main");
    bool wrap = is_main && (d.ret_ty == null || ty_is_unit(d.ret_ty));
    Sb hdr; hdr.init();
    hdr.put("define "); l.ret_ty(&hdr, d.ret_ty); hdr.putc(' '); hdr.name('@', wrap ? "pride_main" : d.name); hdr.putc('(');
    usz entry = l.new_block("entry", false);
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* b = d.params[i];
        if (b == null) { continue; }
        if (!ty_low(b.ty, 0)) { l.err("parameter type is not part of the low profile", b.name); }
        if (i > 0) { hdr.put(", "); }
        l.ty(&hdr, b.ty); hdr.putc(' ');
        Sb pn; pn.init(); pn.name('%', b.name);
        char* ps = pn.take();
        hdr.put(ps);
        l.bind(b.name, ps, b.ty);
    }
    hdr.put(") {\n");
    // labels live on the spine of the body: seq { label A. c ; seq { label B. c ; entry } }
    AirCmd* c = d.def_body;
    while (c != null && c.tag == ACMD_SEQ && c.body != null && c.body.tag == ACMD_LABEL)
    {
        AirCmd* lb = c.body;
        usz bi = l.new_block(lb.binder, true);
        l.blks[bi].np = lb.mbinder_count; l.blks[bi].body = lb.body;
        for (usz i = 0; i < lb.mbinder_count; i++) { l.blks[bi].params[i] = lb.mbinders[i]; }
        c = c.next;
    }
    if (c != null && c.tag == ACMD_LABEL)   // a body that is only a label
    {
        usz bi = l.new_block(c.binder, true);
        l.blks[bi].np = c.mbinder_count; l.blks[bi].body = c.body;
        for (usz i = 0; i < c.mbinder_count; i++) { l.blks[bi].params[i] = c.mbinders[i]; }
        c = null;
    }
    // label parameters are SSA names visible everywhere in the function
    for (usz bi = 1; bi < l.nb; bi++)
    {
        for (usz i = 0; i < l.blks[bi].np; i++)
        {
            AirBinder* pb = l.blks[bi].params[i];
            if (pb == null) { continue; }
            if (!ty_low(pb.ty, 0)) { l.err("label parameter type is not part of the low profile", pb.name); }
            Sb pn; pn.init(); pn.name('%', pb.name);
            l.bind(pb.name, pn.take(), pb.ty);
        }
    }
    l.cur = entry;
    l.cmd(c);
    if (!l.blks[entry].done) { l.err("entry block falls off its end (needs ret/jump/trap)", null); }
    usz nlab = l.nb;
    for (usz bi = 1; bi < nlab; bi++)
    {
        if (!l.blks[bi].is_label) { continue; }
        l.cur = bi; l.cmd(l.blks[bi].body);
        if (!l.blks[bi].done && !l.blks[l.cur].done) { l.err("block falls off its end", l.blks[bi].name); }
    }
    // assemble
    out.put(hdr.d);
    out.put("entry:\n"); if (l.allocas.d != null) { out.put(l.allocas.d); }
    out.put(l.blks[0].text.d == null ? "" : l.blks[0].text.d);
    for (usz bi = 1; bi < l.nb; bi++)
    {
        out.putc('"'); out.put(l.blks[bi].name); out.put("\":\n");
        for (usz pi = 0; pi < l.blks[bi].np; pi++)
        {
            AirBinder* pb = l.blks[bi].params[pi];
            if (pb == null) { continue; }
            out.put("  "); out.name('%', pb.name); out.put(" = phi "); l.ty(out, pb.ty);
            bool first = true;
            for (usz k = 0; k < l.ni; k++)
            {
                if (l.incs[k].blk != bi || l.incs[k].param != pi) { continue; }
                out.put(first ? " [ " : ", [ "); first = false;
                out.put(l.incs[k].val); out.put(", %"); out.putc('"'); out.put(l.incs[k].pred); out.put("\" ]");
            }
            if (first) { l.err("label parameter has no incoming jump", pb.name); out.put(" [ undef, %entry ]"); }
            out.putc('\n');
        }
        if (l.blks[bi].text.d != null) { out.put(l.blks[bi].text.d); }
    }
    out.put("}\n\n");
    if (wrap)
    {
        out.put("define i32 @main() {\n  call void @\"pride_main\"()\n  ret i32 0\n}\n\n");
    }
    l.fn_name = null;
}

fn void Ll.declare(Ll* l, AirDecl* d, Sb* out)
{
    l.fn_name = d.name;
    out.put("declare "); l.ret_ty(out, d.ret_ty); out.putc(' '); out.name('@', d.name); out.putc('(');
    for (usz i = 0; i < d.param_count; i++)
    {
        if (i > 0) { out.put(", "); }
        if (d.params[i] != null) { l.ty(out, d.params[i].ty); }
    }
    if (d.is_varargs) { if (d.param_count > 0) { out.put(", "); } out.put("..."); }
    out.put(")\n");
    l.fn_name = null;
}

// Compiles the module to LLVM text. Returns the number of errors; text in *result (malloc'd).
fn int to_ll(AirModule* m, char** result, bool want_text)
{
    Ll* l = (Ll*)malloc(Ll::size);
    l.m = m; l.errs = 0; l.first_err = null; l.fn_name = null; l.emit = want_text;
    l.vn = (char**)malloc(8 * MAXV); l.vv = (Val*)malloc(Val::size * MAXV);
    l.blks = (Blk*)malloc(Blk::size * MAXB); l.incs = (Inc*)malloc(Inc::size * MAXI);
    l.nv = 0; l.nb = 0; l.ni = 0; l.cur = 0; l.nstr = 0; l.tmp = 0; l.anon = 0;
    l.allocas.init(); l.pre.init(); l.types_out.init();
    Sb body; body.init();
    // named types: every `data` with exactly one constructor is a struct
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null || d.tag != ADECL_DATA) { continue; }
        l.fn_name = d.name;
        if (d.ctor_count != 1) { l.err("data with several constructors (enum layout) is not part of this profile yet", d.name); continue; }
        if (d.typaram_count > 0) { l.err("generic data is not part of the low profile", d.name); continue; }
        l.types_out.putc('%'); l.types_out.putc('"'); l.types_out.put(d.name); l.types_out.put("\" = type { ");
        AirCtorDecl* c = d.ctors[0];
        for (usz j = 0; j < c.field_count; j++)
        {
            if (j > 0) { l.types_out.put(", "); }
            if (!ty_low(c.fields[j].ty, 0)) { l.err("field type is not part of the low profile", c.fields[j].name); }
            l.ty(&l.types_out, c.fields[j].ty);
        }
        l.types_out.put(" }\n");
        l.fn_name = null;
    }
    bool have_syscall = false;
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        switch (d.tag)
        {
            case ADECL_GLOBAL:
            {
                l.fn_name = d.name;
                if (!ty_low(d.ret_ty, 0)) { l.err("global type is not part of the low profile", d.name); }
                body.name('@', d.name);
                if (d.is_extern && d.g_init == null) { body.put(" = external "); body.put(d.g_mut ? "global " : "constant "); l.ty(&body, d.ret_ty); body.putc('\n'); }
                else
                {
                    body.put(" = "); body.put(d.g_mut ? "global " : "constant "); l.ty(&body, d.ret_ty); body.putc(' ');
                    if (d.g_init == null) { body.put("zeroinitializer"); }
                    else
                    {
                        l.const_init(&body, d.g_init, d.ret_ty, d.name);
                    }
                    body.putc('\n');
                }
                l.fn_name = null;
                break;
            }
            case ADECL_DECLARE:
                if (air_text::streq(d.name, "syscall")) { have_syscall = true; }
                l.declare(d, &body); break;
            case ADECL_DEF: l.function(d, &body); break;
            case ADECL_MODULE: case ADECL_IMPORT: case ADECL_DATA: break;
            default: l.err("declaration is not part of the low profile", d.name); break;
        }
    }
    Sb all; all.init();
    all.put("; generated by air_ll from an AIR 3.0 module -- reference consumer, docs/specs/AIR3.md\n");
    if (l.types_out.d != null) { all.put(l.types_out.d); all.putc('\n'); }
    if (l.pre.d != null) { all.put(l.pre.d); all.putc('\n'); }
    all.put("declare void @llvm.trap()\n");
    if (!have_syscall) { all.put("declare i64 @syscall(i64, ...)\n"); }
    all.putc('\n');
    if (body.d != null) { all.put(body.d); }
    *result = all.take();
    int e = l.errs;
    return e;
}

fn int write_ll(AirModule* m, char* path)
{
    char* text = null;
    int errs = to_ll(m, &text, true);
    if (text == null) { return -1; }
    void* f = path != null ? fopen(path, "w") : fdopen(1, "w");
    if (f == null) { return -1; }
    usz n = 0; while (text[n] != 0) { n++; }
    fwrite((void*)text, 1, n, f);
    if (path != null) { fclose(f); } else { fflush(f); }
    return errs;
}
