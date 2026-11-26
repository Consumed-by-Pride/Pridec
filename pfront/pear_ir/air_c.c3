// ============================================================================
// air_c.c3 -- a consumer of the AIR 3.0 low profile: .air -> C11 source text.
//
// The third complete consumer of the low profile, beside air_ll.c3 (AIR -> LLVM
// text) and air_c3.c3 (AIR -> C3). All three walk the same module with the same
// typing rules (docs/specs/AIR3.md, "Typing") and differ only in what they
// print; tests/air3/test_c_target.py asserts that this one handles exactly the
// tags air_ll handles, because a consumer that is quietly narrower than the last
// one is how a backend silently loses features.
//
// C is a TRANSPILATION TARGET here (docs/pear2/C_TARGET.md §1). The reason it
// beats C3 for this job is one property: C has `goto`. AIR 3.0 is a CFG with
// label-parameter (phi) joins, so in C one AIR label is one C label and one AIR
// `jump` is one `goto` -- the output has the same shape as the input, and there
// is no structuring step to get wrong. In C3 that same CFG has to be recovered
// as structured control flow or driven by a __pc switch; air_c3.c3 does the
// latter and counts the functions that need it.
//
// The one thing that IS subtle here is the parallel copy (§3.2): `jump L(x, y)`
// assigns L's parameters from values that may themselves be L's parameters.
// Emitted one at a time in declaration order, that is the lost-copy bug -- it
// turns fib(10) into 512 instead of 55. So every jump with more than one
// argument goes through explicit temporaries (a "vertex"). Correct first; the
// minimisation is a later pass with a number attached.
//
// The templates this file prints are compiled and executed by
// tests/air3/c/shape_test.c on every `make test-c-target`, so the C is proven
// even though this file (being C3, and there being no c3c here) is not.
// ============================================================================
module air_c;
import air_ir;
import air_text;
import air_util;

alias Sb = air_util::Sb;

extern fn void* malloc(usz size_);
extern fn void  free(void* p);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn usz   fwrite(void* p, usz size_, usz count_, void* f);
extern fn void* fdopen(int fd, char* mode);
extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   fflush(void* f);
extern fn int   snprintf(char* buf, usz size, char* fmt, ...);

const usz MAXV = 16384;     // names per function
const usz MAXL = 4096;      // labels per function
const usz MAXS = 8192;      // string literals per module

// ── types ──────────────────────────────────────────────────────────────────
// A property of the profile, not of a printer. Identical in air_ll.c3 and
// air_c3.c3; if these ever disagree, one consumer accepts a module another
// refuses and the AIR layer has no definition.
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
        case APRD_VAR: return (char*)"var"; case APRD_INT: return (char*)"int";
        case APRD_FLOAT: return (char*)"float"; case APRD_BOOL: return (char*)"bool";
        case APRD_CHAR: return (char*)"char"; case APRD_STRING: return (char*)"string";
        case APRD_BYTES: return (char*)"bytes"; case APRD_UNIT: return (char*)"unit";
        case APRD_NULL: return (char*)"null"; case APRD_TUPLE: return (char*)"tuple";
        case APRD_RECORD: return (char*)"record"; case APRD_ARRAY: return (char*)"array";
        case APRD_INL: return (char*)"inl"; case APRD_INR: return (char*)"inr";
        case APRD_LAMBDA: return (char*)"lambda"; case APRD_MU: return (char*)"mu";
        case APRD_COMETA: return (char*)"cometa"; case APRD_BINOP: return (char*)"binop";
        case APRD_UNOP: return (char*)"unop"; case APRD_COERCE: return (char*)"coerce";
        case APRD_SIZEOF: return (char*)"sizeof"; case APRD_ALIGNOF: return (char*)"alignof";
        case APRD_OFFSETOF: return (char*)"offsetof"; case APRD_REIFY: return (char*)"reify";
        case APRD_EVAL: return (char*)"eval"; case APRD_QUOTE: return (char*)"quote";
        case APRD_SPLICE: return (char*)"splice"; case APRD_POISON: return (char*)"poison";
        case APRD_UNREACHABLE_VAL: return (char*)"unreachable";
        case APRD_ALLOCA: return (char*)"alloca"; case APRD_LOAD: return (char*)"load";
        case APRD_GEP: return (char*)"gep";
        default: return (char*)"<invalid>";
    }
}

fn char* cmd_tag_name(AirCmdTag t)
{
    switch (t)
    {
        case ACMD_CUT: return (char*)"cut"; case ACMD_MU: return (char*)"mu";
        case ACMD_MUTILDE: return (char*)"mu~"; case ACMD_JUMP: return (char*)"jump";
        case ACMD_SEQ: return (char*)"seq"; case ACMD_BLOCK: return (char*)"block";
        case ACMD_LET: return (char*)"let"; case ACMD_LETREC: return (char*)"letrec";
        case ACMD_IF: return (char*)"if"; case ACMD_WHILE: return (char*)"while";
        case ACMD_FOR: return (char*)"for"; case ACMD_MATCH: return (char*)"match";
        case ACMD_HANDLE: return (char*)"handle"; case ACMD_PERFORM: return (char*)"perform";
        case ACMD_RESUME: return (char*)"resume"; case ACMD_UNSAFE: return (char*)"unsafe";
        case ACMD_UNCHECKED: return (char*)"unchecked"; case ACMD_COMPTIME: return (char*)"comptime";
        case ACMD_ASSERT: return (char*)"assert"; case ACMD_ASSUME: return (char*)"assume";
        case ACMD_UB: return (char*)"ub"; case ACMD_TRAP: return (char*)"trap";
        case ACMD_RET: return (char*)"ret"; case ACMD_BREAK: return (char*)"break";
        case ACMD_CONTINUE: return (char*)"continue"; case ACMD_DEFER: return (char*)"defer";
        case ACMD_LABEL: return (char*)"label"; case ACMD_NOP: return (char*)"nop";
        case ACMD_ASM: return (char*)"asm"; case ACMD_SYSCALL: return (char*)"syscall";
        case ACMD_ATOMIC: return (char*)"atomic"; case ACMD_FENCE: return (char*)"fence";
        case ACMD_STORE: return (char*)"store";
        default: return (char*)"<invalid>";
    }
}

fn char* ty_slug(AirTyp* t)
{
    if (t == null) { return (char*)"nil"; }
    switch (t.tag)
    {
        case ATYP_I8: return (char*)"i8"; case ATYP_I16: return (char*)"i16";
        case ATYP_I32: return (char*)"i32"; case ATYP_I64: return (char*)"i64";
        case ATYP_U8: return (char*)"u8"; case ATYP_U16: return (char*)"u16";
        case ATYP_U32: return (char*)"u32"; case ATYP_U64: return (char*)"u64";
        case ATYP_ISZ: return (char*)"isz"; case ATYP_USZ: return (char*)"usz";
        case ATYP_F32: return (char*)"f32"; case ATYP_F64: return (char*)"f64";
        case ATYP_BOOL: return (char*)"bool"; case ATYP_CHAR: return (char*)"ch";
        case ATYP_UNIT: return (char*)"unit"; case ATYP_PTR: return (char*)"p";
        case ATYP_ARRAY: return (char*)"a"; case ATYP_TUPLE: return (char*)"t";
        case ATYP_ARROW: return (char*)"f"; case ATYP_NOMINAL: return (char*)"n";
        default: return (char*)"x";
    }
}

// ── environment ────────────────────────────────────────────────────────────
struct Val { char* op; AirTyp* ty; }
struct Lbl { char* name; AirBinder*[16] params; usz np; AirCmd* body; }

struct C
{
    AirModule* m;
    int        errs;
    char*      fn_name;
    bool       emit;

    // per function
    char**     vn; Val* vv; usz nv;
    Lbl*       lbls; usz nl;
    Sb         decls;      // every local declaration, hoisted to the top (§3.4)
    usz        tmp;
    AirTyp*    cur_ret;

    // module level
    Sb         types_out;  // structs, one per distinct shape
    Sb         pre;        // string literals
    usz        nstr;
}

fn void C.err(C* c, char* what, char* who)
{
    c.errs++;
    void* se = fdopen(2, "w");
    if (c.errs <= 12) { fprintf(se, "air-c: in `%s`: %s%s%s\n", c.fn_name == null ? (char*)"<module>" : c.fn_name, what, who == null ? (char*)"@" : (char*)": ", who == null ? (char*)"" : who); }
    fflush(se);
}

fn AirDecl* C.find(C* c, char* nm)
{
    if (nm == null) { return null; }
    for (usz i = 0; i < c.m.decl_count; i++)
    {
        AirDecl* d = c.m.decls[i];
        if (d != null && d.name != null && d.tag != ADECL_MODULE && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

fn AirDecl* C.find_data(C* c, char* nm)
{
    for (usz i = 0; i < c.m.decl_count; i++)
    {
        AirDecl* d = c.m.decls[i];
        if (d != null && d.tag == ADECL_DATA && d.name != null && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

fn bool decl_has_attr(AirDecl* d, char* nm)
{
    if (d == null) { return false; }
    for (usz i = 0; i < d.attr_count; i++) { if (air_text::streq(d.attr_name[i], nm)) { return true; } }
    return false;
}
fn char* decl_attr_str(AirDecl* d, char* nm)
{
    if (d == null) { return null; }
    for (usz i = 0; i < d.attr_count; i++) { if (air_text::streq(d.attr_name[i], nm)) { return d.attr_str[i]; } }
    return null;
}
fn long decl_attr_int(AirDecl* d, char* nm)
{
    if (d == null) { return 0; }
    for (usz i = 0; i < d.attr_count; i++) { if (air_text::streq(d.attr_name[i], nm) && d.attr_has_int[i]) { return d.attr_int[i]; } }
    return 0;
}

fn void C.bind(C* c, char* nm, char* op, AirTyp* ty)
{
    if (nm == null) { return; }
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { c.vv[i].op = op; c.vv[i].ty = ty; return; } }
    if (c.nv >= MAXV) { c.err((char*)"too many names", nm); return; }
    c.vn[c.nv] = nm; c.vv[c.nv].op = op; c.vv[c.nv].ty = ty; c.nv++;
}

fn bool C.lookup(C* c, char* nm, Val* out)
{
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { *out = c.vv[i]; return true; } }
    return false;
}

fn char* C.fresh(C* c, char* stem)
{
    Sb s; s.init(); s.put(stem); s.int_((long)c.tmp); c.tmp++;
    return s.take();
}

// C has no quoted-identifier escape and a bare identifier cannot carry the
// characters AIR allows, so a name that is not a legal C identifier is refused
// where it would be printed. Never mangled: a mangled name is a silent rename.
fn bool c_ident_ok(char* s)
{
    if (s == null || s[0] == 0) { return false; }
    if (s[0] >= '0' && s[0] <= '9') { return false; }
    usz i = 0;
    while (s[i] != 0)
    {
        char ch = s[i];
        if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))) { return false; }
        i++;
    }
    static char*[44] kw = {
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof",
        "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local", "_FakeMono"
    };
    for (usz i = 0; i < 43; i++) { if (air_text::streq(kw[i], s)) { return false; } }
    return true;
}

fn void C.name(C* c, Sb* o, char* nm, bool global)
{
    if (!c_ident_ok(nm)) { c.err((char*)"name is not a legal C identifier", nm); o.put((char*)"__bad_name"); return; }
    if (global) { o.put((char*)"pear_out_"); }
    o.put(nm);
}

// ── types ──────────────────────────────────────────────────────────────────
fn void C.ty(C* c, Sb* o, AirTyp* t)
{
    if (t == null) { c.err((char*)"missing type", null); o.put((char*)"int64_t"); return; }
    switch (t.tag)
    {
        case ATYP_I8: o.put((char*)"int8_t"); return;
        case ATYP_I16: o.put((char*)"int16_t"); return;
        case ATYP_I32: o.put((char*)"int32_t"); return;
        case ATYP_I64: o.put((char*)"int64_t"); return;
        case ATYP_U8: o.put((char*)"uint8_t"); return;
        case ATYP_U16: o.put((char*)"uint16_t"); return;
        case ATYP_U32: o.put((char*)"uint32_t"); return;
        case ATYP_U64: o.put((char*)"uint64_t"); return;
        case ATYP_ISZ: o.put((char*)"pride_isz"); return;
        case ATYP_USZ: o.put((char*)"pride_usz"); return;
        case ATYP_F32: o.put((char*)"float"); return;
        case ATYP_F64: o.put((char*)"double"); return;
        case ATYP_BOOL: o.put((char*)"bool"); return;
        // AIR `char` is a code point: air_util::ty_is_int counts it as an integer
        // and air_ll prints it i32. C's `char` is a byte and would truncate.
        case ATYP_CHAR: o.put((char*)"uint32_t"); return;
        case ATYP_UNIT: case ATYP_BOTTOM: o.put((char*)"void"); return;
        case ATYP_PTR:
        {
            if (t.arg_count == 0 || t.args[0] == null) { c.err((char*)"pointer without a pointee", null); o.put((char*)"void *"); return; }
            c.ty(o, t.args[0]); o.put((char*)" *"); return;
        }
        case ATYP_ARRAY:
        {
            if (t.arg_count == 0 || t.args[0] == null) { c.err((char*)"array without an element type", null); o.put((char*)"uint8_t *"); return; }
            c.ty(o, t.args[0]); o.putc('['); o.int_(t.ival); o.putc(']'); return;
        }
        case ATYP_TUPLE:
        {
            // Named from the shape, so two modules emitting the same tuple agree.
            o.put((char*)"struct __tup");
            for (usz i = 0; i < t.arg_count; i++)
            {
                AirTyp* a = t.args[i];
                o.putc('_'); o.put(ty_slug(a));
                if (a != null && a.tag == ATYP_ARRAY) { o.int_(a.ival); }
                if (a != null && a.arg_count > 0) { o.putc('x'); o.int_((long)a.arg_count); }
            }
            return;
        }
        // AIR arrows are `domain -> codomain`: args[0] is the DOMAIN, args[1] the
        // codomain. Confirmed against air_emit.c3's ATYP_ARROW printer, which
        // writes emit_typ(args[0]) + " -> " + emit_typ(args[1]).
        case ATYP_ARROW:
        {
            AirTyp* dom = t.arg_count > 0 ? t.args[0] : null;
            AirTyp* cod = t.arg_count > 1 ? t.args[1] : null;
            if (cod == null || cod.tag == ATYP_UNIT) { o.put((char*)"void"); } else { c.ty(o, cod); }
            o.put((char*)" (*)(");
            bool wrote = false;
            usz nargs = (dom != null && dom.tag == ATYP_TUPLE) ? dom.arg_count : (dom == null ? 0 : 1);
            for (usz i = 0; i < nargs; i++)
            {
                AirTyp* a = (dom != null && dom.tag == ATYP_TUPLE) ? dom.args[i] : dom;
                if (a == null) { continue; }
                if (wrote) { o.put((char*)", "); }
                c.ty(o, a); wrote = true;
            }
            if (!wrote) { o.put((char*)"void"); }
            o.putc(')');
            return;
        }
        case ATYP_NOMINAL: c.name(o, t.name, false); return;
        default:
            c.err((char*)"type is not part of the low profile", air_text::typ_kw(t.tag));
            o.put((char*)"int64_t"); return;
    }
}

fn bool ty_is_void(AirTyp* t) { return t == null || t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM; }

// Does an AIR fact license an alias qualifier on this parameter?
// `no_capture` means the pointee does not escape the callee, which is exactly
// what C's `restrict` promises about a pointer parameter. It is only used when AIR
// certifies the fact (AFACT_AIR_CHECKED): a candidate fact is not a fact.
fn bool param_can_restrict(AirDecl* d, AirBinder* b)
{
    if (d == null || b == null || b.ty == null) { return false; }
    if (b.ty.tag != ATYP_PTR) { return false; }          // restrict needs an object pointer
    if (d.fact_state != air_ir::AirFactState.AFACT_AIR_CHECKED) { return false; }
    return b.no_capture;
}

// `T name` with the declarator attached where C needs it. An arrow type already
// carries its own `(*)`, so the name goes inside it; everything else is `T name`.
fn void C.ty_decl(C* c, Sb* o, AirTyp* t, char* nm)
{
    if (t != null && t.tag == ATYP_ARROW)
    {
        AirTyp* dom = t.arg_count > 0 ? t.args[0] : null;
        AirTyp* cod = t.arg_count > 1 ? t.args[1] : null;
        if (cod == null || cod.tag == ATYP_UNIT) { o.put((char*)"void"); } else { c.ty(o, cod); }
        o.put((char*)" (*"); c.name(c, o, nm, false); o.put((char*)")(");
        bool wrote = false;
        usz nargs = (dom != null && dom.tag == ATYP_TUPLE) ? dom.arg_count : (dom == null ? 0 : 1);
        for (usz i = 0; i < nargs; i++)
        {
            AirTyp* a = (dom != null && dom.tag == ATYP_TUPLE) ? dom.args[i] : dom;
            if (a == null) { continue; }
            if (wrote) { o.put((char*)", "); }
            c.ty(o, a); wrote = true;
        }
        if (!wrote) { o.put((char*)"void"); }
        o.putc(')');
        return;
    }
    c.ty(o, t); o.putc(' '); c.name(c, o, nm, false);
}

// ── producers ──────────────────────────────────────────────────────────────
fn char* C.str_const(C* c, AirPrd* p)
{
    Sb nm; nm.init(); nm.put((char*)"__s"); nm.int_((long)c.nstr);
    char* name = nm.take();
    c.nstr++;
    Sb* o = &c.pre;
    o.put((char*)"static const char ");
    c.name(o, name, false);
    o.put((char*)"[") ; o.int_((long)(p.bytes_len + 1)); o.put((char*)"] = \"");
    for (usz i = 0; i < p.bytes_len; i++)
    {
        ubyte b = (ubyte)p.bytes[i];
        if (b == 34) { o.put((char*)"\\\""); }
        else if (b == 92) { o.put((char*)"\\\\"); }
        else if (b == 10) { o.put((char*)"\\n"); }
        else if (b == 9) { o.put((char*)"\\t"); }
        else if (b == 13) { o.put((char*)"\\r"); }
        else if (b < 32 || b > 126) { o.put((char*)"\\x"); o.hex((ulong)b, 2); }
        else { o.putc((char)b); }
    }
    o.put((char*)"\";\n");
    return name;
}

fn void C.scalar(C* c, Sb* o, AirPrd* p, AirTyp* typed)
{
    switch (p.tag)
    {
        case APRD_INT:
        {
            AirTyp* t = p.ty != null ? p.ty : typed;
            if (t == null || !air_util::ty_is_int(t)) { c.err((char*)"integer literal without an integer type", null); return; }
            switch (t.tag)
            {
                case ATYP_I8:  o.put((char*)"INT8_C(");  o.int_(p.ival); o.putc(')'); return;
                case ATYP_I16: o.put((char*)"INT16_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_I32: o.put((char*)"INT32_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_I64: o.put((char*)"INT64_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_U8:  o.put((char*)"UINT8_C(");  o.int_(p.ival); o.putc(')'); return;
                case ATYP_U16: o.put((char*)"UINT16_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_U32: o.put((char*)"UINT32_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_U64: o.put((char*)"UINT64_C("); o.int_(p.ival); o.putc(')'); return;
                case ATYP_ISZ: o.put((char*)"((pride_isz)"); o.int_(p.ival); o.putc(')'); return;
                case ATYP_USZ: o.put((char*)"((pride_usz)"); o.int_(p.ival); o.putc(')'); return;
                default: o.int_(p.ival); return;     // ATYP_CHAR: a plain number is correct
            }
        }
        case APRD_FLOAT:
        {
            AirTyp* t = p.ty != null ? p.ty : typed;
            if (t == null || !air_util::ty_is_float(t)) { c.err((char*)"float literal without a float type", null); return; }
            // hex-float: the exact value, with no rounding through a decimal
            // parser. C99 requires it. inf/nan has no hex form, so it is refused
            // rather than spelled as a division that could be folded wrongly.
            char[64] buf;
            int n = (t.tag == ATYP_F32) ? snprintf(&buf[0], 64, "%a", (double)p.fval)
                                        : snprintf(&buf[0], 64, "%a", p.fval);
            if (n <= 0 || n >= 64) { c.err((char*)"float literal did not format", null); return; }
            if (buf[0] == 'i' || buf[0] == 'n' || (buf[0] == '-' && (buf[1] == 'i' || buf[1] == 'n')))
            { c.err((char*)"non-finite float literal has no hex spelling", null); return; }
            o.put(&buf[0]);
            if (t.tag == ATYP_F32) { o.putc('f'); }
            return;
        }
        case APRD_BOOL: o.put(p.bval ? (char*)"true" : (char*)"false"); return;
        case APRD_CHAR: o.put((char*)"((uint32_t)"); o.int_(p.ival); o.putc(')'); return;
        case APRD_NULL: o.put((char*)"NULL"); return;
        default: c.err((char*)"not a scalar constant", prd_tag_name(p.tag)); return;
    }
}

fn Val C.prd(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    if (p == null) { c.err((char*)"missing producer", null); return v; }
    switch (p.tag)
    {
        case APRD_VAR:
        {
            Val got;
            if (c.lookup(p.name, &got)) { return got; }
            AirDecl* d = c.find(p.name);
            if (d != null && (d.tag == ADECL_GLOBAL || d.tag == ADECL_DEF || d.tag == ADECL_DECLARE))
            {
                Sb s; s.init(); c.name(&s, p.name, d.tag == ADECL_GLOBAL); v.op = s.take(); v.ty = d.ret_ty; return v;
            }
            c.err((char*)"unbound variable", p.name); return v;
        }
        case APRD_INT: case APRD_FLOAT: case APRD_BOOL: case APRD_CHAR: case APRD_NULL:
        {
            Sb s; s.init(); c.scalar(&s, p, p.ty); v.op = s.take(); v.ty = p.ty; return v;
        }
        case APRD_UNIT: v.ty = p.ty; v.op = (char*)"((pride_unit){0})"; return v;
        case APRD_STRING: case APRD_BYTES: v.ty = p.ty; v.op = c.str_const(c, p); return v;
        case APRD_BINOP:  return c.binop(c, p);
        case APRD_UNOP:   return c.unop(c, p);
        case APRD_COERCE: return c.coerce(c, p);
        case APRD_ALLOCA:
        {
            if (!ty_low(p.ty_arg, 0)) { c.err((char*)"alloca of a non-low type", null); }
            char* t = c.fresh(c, (char*)"v");
            // Hoisted with every other declaration (§3.4): a jump must never cross
            // a declaration, and the slot is addressed on more than one path.
            c.decls.put((char*)"    ");
            c.ty_decl(c, &c.decls, p.ty_arg, t);
            c.decls.put((char*)";\n");
            Sb s; s.init(); s.putc('&'); s.put(t); v.op = s.take();
            v.ty = p.ty; return v;
        }
        case APRD_LOAD:
        {
            Val a = c.prd(p.sub_count > 0 ? p.subs[0] : null);
            if (a.ty == null || a.ty.tag != ATYP_PTR) { c.err((char*)"load from a non-pointer", null); return v; }
            AirTyp* et = a.ty.args[0];
            if (p.ty != null && !air_util::ty_eq(p.ty, et)) { c.err((char*)"load annotation differs from the pointee type", null); }
            Sb s; s.init();
            if (p.bval)
            {
                // a volatile read is a cast on the pointer, not a helper
                s.put((char*)"(*(volatile "); c.ty(&s, et); s.put((char*)" *)("); s.put(a.op); s.put((char*)"))");
            }
            else { s.putc('*'); s.put((char*)"("); s.put(a.op); s.putc(')'); }
            v.op = s.take(); v.ty = et; return v;
        }
        case APRD_GEP: return c.gep(c, p);
        case APRD_TUPLE: case APRD_RECORD: case APRD_ARRAY: return c.aggregate(c, p);
        case APRD_SIZEOF:
        {
            Sb s; s.init(); s.put((char*)"((pride_usz)sizeof("); c.ty(&s, p.ty); s.put((char*)"))");
            v.op = s.take(); v.ty = c.m.t_usz; return v;
        }
        default:
            c.err((char*)"producer is not part of the low profile", prd_tag_name(p.tag)); return v;
    }
}

fn bool field_at(C* c, AirTyp* cur, long ix, AirTyp** out)
{
    *out = null;
    if (cur == null || ix < 0) { return false; }
    if (cur.tag == ATYP_TUPLE) { if ((usz)ix >= cur.arg_count) { return false; } *out = cur.args[(usz)ix]; return true; }
    if (cur.tag == ATYP_NOMINAL)
    {
        AirDecl* dd = c.find_data(cur.name);
        if (dd == null || dd.ctor_count != 1) { return false; }
        AirCtorDecl* ct = dd.ctors[0];
        if ((usz)ix >= ct.field_count) { return false; }
        *out = ct.fields[(usz)ix].ty;
        return true;
    }
    return false;
}

fn Val C.gep(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    Val b = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    if (b.ty == null || b.ty.tag != ATYP_PTR) { c.err((char*)"gep base is not a pointer", null); return v; }
    AirTyp* cur = p.ty_arg;
    if (!ty_low(cur, 0)) { c.err((char*)"gep over a non-low type", null); return v; }
    if (!air_util::ty_eq(b.ty.args[0], cur)) { c.err((char*)"gep source element type differs from the base pointee", null); return v; }

    Val idx[16];
    for (usz i = 1; i < p.sub_count && i < 16; i++) { idx[i] = c.prd(p.subs[i]); }
    for (usz i = 1; i < p.sub_count && i < 16; i++) { if (!air_util::ty_is_int(idx[i].ty)) { c.err((char*)"gep index is not an integer", null); } }
    if (p.sub_count > 16) { c.err((char*)"gep with more than 15 indices", null); }

    // The access expression, following the same walk air_ll's Ll.gep does so the
    // two consumers cannot disagree about layout.
    Sb acc; acc.init();
    AirTyp* step = cur;
    if (p.sub_count <= 1) { acc.put(b.op); }
    else
    {
        acc.putc('('); acc.put(b.op); acc.put((char*)" + "); acc.put(idx[1].op); acc.putc(')');
        for (usz i = 2; i < p.sub_count && i < 16; i++)
        {
            if (step == null) { c.err((char*)"gep indexes past a scalar", null); break; }
            if (step.tag == ATYP_ARRAY) { acc.putc('['); acc.put(idx[i].op); acc.putc(']'); step = step.args[0]; continue; }
            if (step.tag == ATYP_TUPLE || step.tag == ATYP_NOMINAL)
            {
                AirPrd* ip = p.subs[i];
                if (ip == null || ip.tag != APRD_INT) { c.err((char*)"struct gep index must be a literal", null); break; }
                AirTyp* ft = null;
                if (!field_at(c, step, ip.ival, &ft)) { c.err((char*)"gep index outside the aggregate", null); break; }
                if (step.tag == ATYP_TUPLE) { acc.put((char*)"-");  }
                else
                {
                    AirDecl* dd = c.find_data(step.name);
                    acc.putc('.'); c.name(&acc, dd.ctors[0].fields[(usz)ip.ival].name, false);
                }
                step = ft;
                continue;
            }
            c.err((char*)"gep indexes into a type with no members", null); break;
        }
    }
    Sb s; s.init(); s.putc('&'); s.put((char*)"("); s.put(acc.take()); s.put((char*)")");
    v.op = s.take();
    v.ty = (step != null && p.ty != null) ? p.ty : null;
    return v;
}

fn Val C.aggregate(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = p.ty;
    if (p.ty == null) { c.err((char*)"aggregate without a type", null); return v; }
    usz n = p.tag == APRD_RECORD ? p.rec_init_count : p.sub_count;
    if (n > 64) { c.err((char*)"aggregate with more than 64 parts", null); return v; }
    Val[64] parts;
    AirTyp*[64] want;
    if (p.tag == APRD_TUPLE)
    {
        if (p.ty.tag != ATYP_TUPLE || p.ty.arg_count != n) { c.err((char*)"tuple type does not match its parts", null); return v; }
        for (usz i = 0; i < n; i++) { want[i] = p.ty.args[i]; }
    }
    else if (p.tag == APRD_ARRAY)
    {
        if (p.ty.tag != ATYP_ARRAY || p.ty.ival != (long)n) { c.err((char*)"array type does not match its length", null); return v; }
        for (usz i = 0; i < n; i++) { want[i] = p.ty.args[0]; }
    }
    else
    {
        if (p.ty.tag != ATYP_NOMINAL) { c.err((char*)"record without a nominal type", null); return v; }
        AirDecl* d = c.find_data(p.ty.name);
        if (d == null || d.ctor_count != 1) { c.err((char*)"record of a type that is not a single-constructor data", p.ty.name); return v; }
        AirCtorDecl* ct = d.ctors[0];
        if (ct.field_count != n) { c.err((char*)"record field count differs from the declaration", p.ty.name); return v; }
        for (usz i = 0; i < n; i++)
        {
            bool found = false;
            for (usz j = 0; j < ct.field_count; j++)
            {
                if (air_text::streq(ct.fields[j].name, p.rec_inits[i].name)) { want[i] = ct.fields[j].ty; found = true; }
            }
            if (!found) { c.err((char*)"record field is not declared", p.rec_inits[i].name); }
        }
        for (usz i = 0; i < n && i < ct.field_count; i++)
        {
            if (!air_text::streq(ct.fields[i].name, p.rec_inits[i].name)) { c.err((char*)"record fields out of declaration order", p.rec_inits[i].name); break; }
        }
    }
    for (usz i = 0; i < n; i++)
    {
        parts[i] = c.prd(p.tag == APRD_RECORD ? p.rec_inits[i].value : p.subs[i]);
        if (parts[i].ty != null && want[i] != null && !air_util::ty_eq(parts[i].ty, want[i])) { c.err((char*)"aggregate part has the wrong type", null); }
    }
    // A compound literal needs its type in parentheses; `T[N]` is already the
    // array form, so the cast shape is right for both.
    Sb s; s.init();
    s.putc('('); c.ty(&s, p.ty); s.putc(')');
    s.putc('{');
    for (usz i = 0; i < n; i++)
    {
        if (i > 0) { s.put((char*)", "); }
        if (p.tag == APRD_RECORD) { s.putc('.'); c.name(&s, p.rec_inits[i].name, false); s.put((char*)" = "); }
        else if (p.tag == APRD_TUPLE) { s.put((char*)"._"); s.int_((long)i); s.put((char*)" = "); }
        s.put(parts[i].op);
    }
    s.putc('}');
    v.op = s.take();
    return v;
}

fn Val C.binop(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    Val a = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    Val b = c.prd(p.sub_count > 1 ? p.subs[1] : null);
    if (a.ty == null || b.ty == null) { return v; }
    if (!air_util::ty_eq(a.ty, b.ty)) { c.err((char*)"binary operands have different types", air_text::binop_name(p.bop)); return v; }
    AirTyp* t = a.ty;
    bool isi = air_util::ty_is_int(t); bool isf = air_util::ty_is_float(t);
    bool isb = air_util::ty_is_bool(t); bool isp = air_util::ty_is_ptr(t);
    char* opn = null; bool cmp = false;
    switch (p.bop)
    {
        case ABIN_ADD: opn = (char*)"+"; break;
        case ABIN_SUB: opn = (char*)"-"; break;
        case ABIN_MUL: opn = (char*)"*"; break;
        case ABIN_DIV: opn = (char*)"/"; break;
        case ABIN_MOD: opn = (char*)"%"; break;
        case ABIN_AND: case ABIN_LAND: opn = (char*)"&"; break;
        case ABIN_OR:  case ABIN_LOR:  opn = (char*)"|"; break;
        case ABIN_XOR: opn = (char*)"^"; break;
        case ABIN_SHL: opn = (char*)"<<"; break;
        case ABIN_SHR: opn = (char*)">>"; break;
        case ABIN_EQ:  cmp = true; opn = (char*)"=="; break;
        case ABIN_NEQ: cmp = true; opn = (char*)"!="; break;
        case ABIN_LT:  cmp = true; opn = (char*)"<"; break;
        case ABIN_GT:  cmp = true; opn = (char*)">"; break;
        case ABIN_LE:  cmp = true; opn = (char*)"<="; break;
        case ABIN_GE:  cmp = true; opn = (char*)">="; break;
        default: c.err((char*)"binary operator is not part of the low profile", air_text::binop_name(p.bop)); return v;
    }
    bool arith = p.bop == ABIN_ADD || p.bop == ABIN_SUB || p.bop == ABIN_MUL || p.bop == ABIN_DIV || p.bop == ABIN_MOD;
    bool bits = p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR || p.bop == ABIN_SHL || p.bop == ABIN_SHR;
    bool logic = p.bop == ABIN_LAND || p.bop == ABIN_LOR;
    if (arith && !(isi || isf)) { c.err((char*)"arithmetic on a non-number", air_text::binop_name(p.bop)); return v; }
    if (bits && !(isi || (isb && (p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR)))) { c.err((char*)"bitwise operation on a non-integer", air_text::binop_name(p.bop)); return v; }
    if (logic && !isb) { c.err((char*)"land/lor need bool operands", null); return v; }
    if (cmp && !(isi || isf || isb || isp)) { c.err((char*)"comparison of a type with no order", null); return v; }
    if (cmp && (isb || isp) && !(p.bop == ABIN_EQ || p.bop == ABIN_NEQ)) { c.err((char*)"ordered comparison of bool/pointer", null); return v; }
    Sb s; s.init(); s.putc('('); s.put(a.op); s.putc(' '); s.put(opn); s.putc(' '); s.put(b.op); s.putc(')');
    v.op = s.take();
    v.ty = cmp ? c.m.t_bool : t;
    if (p.ty != null && !air_util::ty_eq(p.ty, v.ty)) { c.err((char*)"operation annotation differs from the computed type", air_text::binop_name(p.bop)); }
    return v;
}

fn Val C.unop(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    Val a = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    if (a.ty == null) { return v; }
    char* opn = null;
    switch (p.uop)
    {
        case AUN_NEG:
            if (!(air_util::ty_is_float(a.ty) || air_util::ty_is_int(a.ty))) { c.err((char*)"neg of a non-number", null); return v; }
            opn = (char*)"-"; break;
        case AUN_NOT:
            if (!air_util::ty_is_bool(a.ty)) { c.err((char*)"not of a non-bool", null); return v; }
            opn = (char*)"!"; break;
        case AUN_BITNOT:
            if (!air_util::ty_is_int(a.ty)) { c.err((char*)"bitnot of a non-integer", null); return v; }
            opn = (char*)"~"; break;
        default: c.err((char*)"unary operator is not part of the low profile", air_text::unop_name(p.uop)); return v;
    }
    Sb s; s.init(); s.putc('('); s.put(opn); s.putc('('); s.put(a.op); s.put((char*)")"); s.putc(')');
    v.op = s.take(); v.ty = a.ty;
    if (p.ty != null && !air_util::ty_eq(p.ty, v.ty)) { c.err((char*)"operation annotation differs from the computed type", null); }
    return v;
}

fn Val C.coerce(C* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = p.ty;
    Val a = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    AirTyp* to = p.ty;
    if (a.ty == null || to == null) { c.err((char*)"coerce without types", null); return v; }
    if (!ty_low(to, 0)) { c.err((char*)"coerce to a non-low type", null); return v; }
    if (air_util::ty_eq(a.ty, to)) { v.op = a.op; return v; }
    AirTyp* f = a.ty;
    bool fi = air_util::ty_is_int(f) || air_util::ty_is_bool(f);
    bool ti = air_util::ty_is_int(to) || air_util::ty_is_bool(to);
    bool legal = false;
    if (fi && ti) { legal = (air_util::ty_bits(f) != air_util::ty_bits(to)); }
    else if (fi && air_util::ty_is_float(to)) { legal = true; }
    else if (air_util::ty_is_float(f) && ti) { legal = true; }
    else if (air_util::ty_is_float(f) && air_util::ty_is_float(to)) { legal = true; }
    else if (air_util::ty_is_ptr(f) && ti) { legal = true; }
    else if (fi && air_util::ty_is_ptr(to)) { legal = true; }
    else if (air_util::ty_is_ptr(f) && air_util::ty_is_ptr(to)) { v.op = a.op; return v; }
    else if ((f.tag == ATYP_ARROW && air_util::ty_is_ptr(to)) || (air_util::ty_is_ptr(f) && to.tag == ATYP_ARROW)) { v.op = a.op; return v; }
    if (!legal) { c.err((char*)"coerce between these types is not defined", null); return v; }
    // One cast. C picks the signed/unsigned and truncate/extend path from the
    // source type, which is exactly what AIR's coerce means; LLVM needs a
    // distinct opcode for each and air_ll therefore has eight branches here.
    Sb s; s.init(); s.put((char*)"(("); c.ty(&s, to); s.put((char*)")(("); s.put(a.op); s.put((char*)")))");
    v.op = s.take();
    return v;
}

// ── statements ─────────────────────────────────────────────────────────────
fn void C.pad(C* c, Sb* o) { (void)c; o.put((char*)"    "); }

fn void C.stmt_ret(C* c, Sb* o, AirPrd* p)
{
    c.pad(c, o);
    if (ty_is_void(c.cur_ret))
    {
        if (p != null)
        {
            Val v = c.prd(p);
            if (v.ty != null && !ty_is_void(v.ty)) { c.err((char*)"ret of a value in a unit function", null); }
        }
        o.put((char*)"return;\n");
        return;
    }
    Val v = c.prd(p);
    if (v.ty != null && !air_util::ty_eq(v.ty, c.cur_ret)) { c.err((char*)"ret value type differs from the function's return type", null); }
    o.put((char*)"return "); o.put(v.op); o.put((char*)";\n");
}

fn void C.call(C* c, AirPrd* callee, AirCns* k, AirCmd** next_out, Sb* o)
{
    Val f = c.prd(callee);
    Val[64] args; usz na = 0;
    AirCns* cur = k != null ? k.tail : null;
    while (cur != null && cur.tag == ACNS_STACK)
    {
        if (na >= 64) { c.err((char*)"call with more than 64 arguments", null); break; }
        args[na] = c.prd(cur.prd); na++;
        cur = cur.tail;
    }
    if (cur == null || cur.tag != ACNS_COMU) { c.err((char*)"call continuation is not `comu`", null); *next_out = null; return; }
    Sb s; s.init();
    c.pad(c, o);
    if (cur.bind != null) { c.ty_decl(c, &s, cur.ty, cur.bind); s.put((char*)" = "); }
    s.putc('('); s.put(f.op); s.put((char*)")(");
    for (usz i = 0; i < na; i++) { if (i > 0) { s.put((char*)", "); } s.put(args[i].op); }
    s.put((char*)")"); s.put((char*)";\n");
    o.put(s.take());
    if (cur.bind != null) { c.bind(cur.bind, cur.bind, cur.ty); }
    *next_out = cur.body;
}

fn char* order_c(int ord)
{
    switch (ord)
    {
        case 1: return (char*)"memory_order_acquire";
        case 2: return (char*)"memory_order_release";
        case 3: return (char*)"memory_order_acq_rel";
        default: return (char*)"memory_order_seq_cst";
    }
}

fn char* rmw_c(int op)
{
    switch (op)
    {
        case 2: return (char*)"atomic_exchange_explicit";
        case 3: return (char*)"atomic_fetch_add_explicit";
        case 4: return (char*)"atomic_fetch_sub_explicit";
        case 5: return (char*)"atomic_fetch_and_explicit";
        case 6: return (char*)"atomic_fetch_or_explicit";
        case 7: return (char*)"atomic_fetch_xor_explicit";
        default: return null;
    }
}

fn void C.jump(C* c, AirCmd* x, Sb* o)
{
    if (x.target_label == null) { c.err((char*)"jump without a target", null); return; }
    if (!c_ident_ok(x.target_label)) { c.err((char*)"label is not a legal C identifier", x.target_label); return; }

    // The parallel copy (§3.2). With one argument the assignment cannot interfere
    // with itself; with more than one, every source is read into a temporary
    // first, so no assignment can read a value another already overwrote.
    Val[16] src; usz n = 0;
    for (usz i = 0; i < x.jump_arg_count && i < 16; i++)
    {
        Val a;
        if (!c.lookup(x.jump_args[i], &a)) { c.err((char*)"jump argument is unbound", x.jump_args[i]); return; }
        src[n] = a; n++;
    }
    Lbl* tb = null;
    for (usz i = 0; i < c.nl; i++) { if (c.lbls[i].name != null && air_text::streq(c.lbls[i].name, x.target_label)) { tb = &c.lbls[i]; break; } }
    if (tb == null) { c.err((char*)"jump to an unknown label", x.target_label); return; }
    if (tb.np != n) { c.err((char*)"jump has the wrong number of arguments", x.target_label); }

    if (n > 1)
    {
        char*[16] tmps;
        for (usz i = 0; i < n; i++)
        {
            tmps[i] = c.fresh(c, (char*)"t");
            c.pad(c, o);
            if (tb.params[i] != null)
            {
                c.ty_decl(c, o, tb.params[i].ty, tmps[i]);
                o.put((char*)" = "); o.put(src[i].op); o.put((char*)";\n");
            }
        }
        for (usz i = 0; i < n; i++)
        {
            if (tb.params[i] == null) { continue; }
            c.pad(c, o);
            c.name(o, tb.params[i].name, false);
            o.put((char*)" = "); o.put(tmps[i]); o.put((char*)";\n");
        }
    }
    else if (n == 1 && tb.params[0] != null)
    {
        c.pad(c, o);
        c.name(o, tb.params[0].name, false);
        o.put((char*)" = "); o.put(src[0].op); o.put((char*)";\n");
    }
    c.pad(c, o); o.put((char*)"goto "); o.put(x.target_label); o.put((char*)";\n");
}

fn void C.cmd(C* c, AirCmd* cmd, Sb* o)
{
    AirCmd* x = cmd;
    int guard = 0;
    while (x != null)
    {
        if (guard++ > 1000000) { c.err((char*)"command chain did not terminate", null); return; }
        switch (x.tag)
        {
            case ACMD_NOP: x = x.next; continue;
            case ACMD_SEQ: c.cmd(x.body, o); x = x.next; continue;
            case ACMD_LET:
            {
                Val v = c.prd(x.prd);
                c.pad(c, o);
                c.ty_decl(c, o, v.ty, x.binder);
                o.put((char*)" = "); o.put(v.op); o.put((char*)";\n");
                c.bind(x.binder, x.binder, v.ty);
                x = x.body; continue;
            }
            case ACMD_STORE:
            {
                Val p = c.prd(x.prds[0]); Val v = c.prd(x.prds[1]);
                if (p.ty == null || p.ty.tag != ATYP_PTR) { c.err((char*)"store to a non-pointer", null); return; }
                if (v.ty != null && !air_util::ty_eq(p.ty.args[0], v.ty)) { c.err((char*)"stored value type differs from the pointee type", null); }
                if (ty_is_void(v.ty)) { x = x.next; continue; }
                c.pad(c, o);
                if (x.vol) { o.put((char*)"(*(volatile "); c.ty(o, p.ty.args[0]); o.put((char*)" *)("); o.put(p.op); o.put((char*)"))"); }
                else { o.putc('*'); o.put((char*)"("); o.put(p.op); o.put((char*)")"); }
                o.put((char*)" = "); o.put(v.op); o.put((char*)";\n");
                x = x.next; continue;
            }
            case ACMD_FENCE:
            {
                if (x.atomic_order < 1 || x.atomic_order > 4) { c.err((char*)"a fence needs acquire, release, acq_rel or seq_cst ordering", null); return; }
                c.pad(c, o); o.put((char*)"atomic_thread_fence("); o.put(order_c(x.atomic_order)); o.put((char*)")"); o.put((char*)";\n");
                x = x.next; continue;
            }
            case ACMD_RET: c.stmt_ret(c, o, x.prd); return;
            case ACMD_TRAP: c.pad(c, o); o.put((char*)"__pride_trap(\"trap\")"); o.put((char*)";\n"); return;
            case ACMD_UB:   c.pad(c, o); o.put((char*)"__pride_ub(\"ub\")"); o.put((char*)";\n"); return;
            case ACMD_JUMP: c.jump(c, x, o); return;
            case ACMD_IF:
            {
                Val cv = c.prd(x.prd);
                if (cv.ty != null && !air_util::ty_is_bool(cv.ty)) { c.err((char*)"if condition is not a bool", null); }
                c.pad(c, o); o.put((char*)"if ("); o.put(cv.op); o.put((char*)") {\n");
                c.cmd(x.then_c, o);
                if (x.else_c != null)
                {
                    c.pad(c, o); o.put((char*)"} else {\n");
                    c.cmd(x.else_c, o);
                    c.pad(c, o); o.put((char*)"}\n");
                }
                else { c.pad(c, o); o.put((char*)"}\n"); }
                x = x.next; continue;
            }
            case ACMD_MATCH: c.emit_switch(c, x, o); return;
            case ACMD_CUT:
            {
                AirCns* k = x.cns;
                if (k == null) { c.err((char*)"cut without a consumer", null); return; }
                if (k.tag == ACNS_COMU)
                {
                    Val v = c.prd(x.prd);
                    c.pad(c, o); c.ty_decl(c, o, v.ty, k.bind); o.put((char*)" = "); o.put(v.op); o.put((char*)";\n");
                    c.bind(k.bind, k.bind, v.ty);
                    x = k.body; continue;
                }
                if (k.tag == ACNS_COVAR) { c.stmt_ret(c, o, x.prd); return; }
                if (k.tag == ACNS_CALL)
                {
                    AirCmd* nx = null;
                    c.call(x.prd, k, &nx, o);
                    if (nx == null) { c.err((char*)"call continuation is empty", null); return; }
                    x = nx; continue;
                }
                if ((k.tag == ACNS_FIELD || k.tag == ACNS_PROJ) && k.tail != null && k.tail.tag == ACNS_COMU)
                {
                    Val a = c.prd(x.prd);
                    AirTyp* ft = null; long ix = -1;
                    if (k.tag == ACNS_PROJ)
                    {
                        ix = k.idx;
                        if (a.ty == null || a.ty.tag != ATYP_TUPLE || ix < 0 || (usz)ix >= a.ty.arg_count) { c.err((char*)"proj outside the tuple", null); return; }
                        ft = a.ty.args[(usz)ix];
                    }
                    else
                    {
                        if (a.ty == null || a.ty.tag != ATYP_NOMINAL) { c.err((char*)"field of a non-record", k.name); return; }
                        AirDecl* dd = c.find_data(a.ty.name);
                        if (dd == null || dd.ctor_count != 1) { c.err((char*)"field of a type that is not a single-constructor data", a.ty.name); return; }
                        AirCtorDecl* cd = dd.ctors[0];
                        for (usz j = 0; j < cd.field_count; j++) { if (air_text::streq(cd.fields[j].name, k.name)) { ix = (long)j; ft = cd.fields[j].ty; } }
                        if (ix < 0) { c.err((char*)"field is not declared", k.name); return; }
                        if (k.idx != ix) { c.err((char*)"field slot number differs from the declaration", k.name); }
                    }
                    Sb s; s.init(); s.putc('('); s.put(a.op); s.put((char*)")");
                    if (k.tag == ACNS_PROJ) { s.put((char*)"._"); s.int_(ix); }
                    else { s.putc('.'); c.name(&s, k.name, false); }
                    c.pad(c, o);
                    c.ty_decl(c, o, ft, k.tail.bind);
                    o.put((char*)" = "); o.put(s.take()); o.put((char*)";\n");
                    c.bind(k.tail.bind, k.tail.bind, ft);
                    x = k.tail.body; continue;
                }
                c.err((char*)"consumer is not part of the low profile", (char*)"cut"); return;
            }
            case ACMD_SYSCALL:
            {
                Val[8] a; usz na = 0;
                a[0] = c.prd(x.prd); na = 1;
                for (usz i = 0; i < x.prd_count && na < 8; i++) { a[na] = c.prd(x.prds[i]); na++; }
                for (usz i = 0; i < na; i++) { if (a[i].ty == null || a[i].ty.tag != ATYP_I64) { c.err((char*)"syscall operands must be i64", null); break; } }
                if (na > 7) { c.err((char*)"a syscall takes a number and at most 6 arguments", null); return; }
                if (x.cns == null || x.cns.tag != ACNS_COMU) { c.err((char*)"syscall result must be bound with `comu`", null); return; }
                // The prelude has one convention (x86-64 Linux). air_ll supports
                // four; this target refuses the ones it does not have rather than
                // emitting a call with the wrong registers.
                if (air_util::g_triple != null && air_util::g_ptr_bits != 64) { c.err((char*)"syscall on a non-x86-64 target is not in the C prelude", null); return; }
                char* r = c.fresh(c, (char*)"r");
                Sb s; s.init();
                c.pad(c, o);
                s.put((char*)"int64_t "); s.put(r); s.put((char*)" = __pride_syscall"); s.int_((long)na); s.putc('(');
                for (usz i = 0; i < na; i++) { if (i > 0) { s.put((char*)", "); } s.put(a[i].op); }
                s.put((char*)")"); s.put((char*)";\n");
                o.put(s.take());
                c.bind(x.cns.bind, r, c.m.t_i64);
                x = x.cns.body; continue;
            }
            case ACMD_ATOMIC:
            {
                Val p = c.prd(x.prd);
                if (p.ty == null || p.ty.tag != ATYP_PTR || p.ty.args[0] == null || !air_util::ty_is_int(p.ty.args[0]) || air_util::ty_bits(p.ty.args[0]) > 64) { c.err((char*)"atomic operand 0 must be a pointer to an integer of at most 64 bits", null); return; }
                int op = x.atomic_op; int ord = x.atomic_order;
                if (ord < 1 || ord > 4) { c.err((char*)"atomic operation needs an ordering", null); return; }
                if (op == 0 && (ord == 2 || ord == 3)) { c.err((char*)"an atomic load cannot be release or acq_rel", null); return; }
                if (op == 1 && (ord == 1 || ord == 3)) { c.err((char*)"an atomic store cannot be acquire or acq_rel", null); return; }
                if (x.cns == null || x.cns.tag != ACNS_COMU) { c.err((char*)"atomic result must be bound with `comu`", null); return; }
                AirTyp* et = p.ty.args[0];
                char* r = c.fresh(c, (char*)"r");
                Sb s; s.init();
                c.pad(c, o);
                if (op == 0)
                {
                    s.put((char*)"int64_t "); s.put(r); s.put((char*)" = (int64_t)atomic_load_explicit((_Atomic "); c.ty(&s, et); s.put((char*)" *)("); s.put(p.op); s.put((char*)"), "); s.put(order_c(ord)); s.putc(')');
                }
                else if (op == 1)
                {
                    if (x.prd_count < 1) { c.err((char*)"atomic store needs an operand", null); return; }
                    s.put((char*)"atomic_store_explicit((_Atomic "); c.ty(&s, et); s.put((char*)" *)("); s.put(p.op); s.put((char*)"), ("); c.ty(&s, et); s.put((char*)")("); s.put(c.prd(x.prds[0]).op); s.put((char*)"), "); s.put(order_c(ord)); s.putc(')');
                }
                else
                {
                    if (x.prd_count < 1) { c.err((char*)"atomic read-modify-write needs an operand", null); return; }
                    char* fn = rmw_c(op);
                    if (fn == null) { c.err((char*)"atomic operation is not part of the low profile", null); return; }
                    s.put((char*)"int64_t "); s.put(r); s.put((char*)" = (int64_t)"); s.put(fn); s.put((char*)"((_Atomic "); c.ty(&s, et); s.put((char*)" *)("); s.put(p.op); s.put((char*)"), ("); c.ty(&s, et); s.put((char*)")("); s.put(c.prd(x.prds[0]).op); s.put((char*)"), "); s.put(order_c(ord)); s.putc(')');
                }
                s.put((char*)";\n");
                o.put(s.take());
                if (op == 1) { c.bind(x.cns.bind, (char*)"((pride_unit){0})", c.m.t_unit); }
                else { c.bind(x.cns.bind, r, et); }
                x = x.cns.body; continue;
            }
            case ACMD_ASM:
            {
                // AIR's asm carries the GCC/Clang constraint syntax, which C
                // accepts almost verbatim -- the one place C is easier than C3,
                // where air_c3 has to refuse it.
                if (x.asm_text == null) { c.err((char*)"asm without a template", null); return; }
                if (x.asm_cons == null) { c.err((char*)"asm without constraints", null); return; }
                c.pad(c, o);
                o.put((char*)"__asm__ volatile (\"");
                for (usz i = 0; x.asm_text[i] != 0; i++)
                {
                    char ch = x.asm_text[i];
                    if (ch == '"' || ch == '\\') { o.putc('\\'); o.putc(ch); }
                    else if (ch == '\n') { o.put((char*)"\\n"); }
                    else if (ch == '\t') { o.put((char*)"\\t"); }
                    else { o.putc(ch); }
                }
                o.put((char*)"\" : \"");
                o.put(x.asm_cons);
                o.put((char*)"\");\n");
                if (x.cns != null && x.cns.tag == ACNS_COMU) { c.bind(x.cns.bind, r_asm_unit(c), c.m.t_unit); x = x.cns.body; continue; }
                x = x.next; continue;
            }
            default:
                c.err((char*)"command is not part of the low profile", cmd_tag_name(x.tag)); return;
        }
    }
}

fn void C.emit_switch(C* c, AirCmd* x, Sb* o)
{
    Val s = c.prd(x.prd);
    if (!(air_util::ty_is_int(s.ty) || air_util::ty_is_bool(s.ty))) { c.err((char*)"match scrutinee is not an integer or bool", null); return; }
    c.pad(c, o); o.put((char*)"switch ("); o.put(s.op); o.put((char*)") {\n");
    for (usz i = 0; i < x.branch_count; i++)
    {
        AirBranch* b = x.branches[i];
        if (b == null || b.pat == null) { continue; }
        if (b.guard != null) { c.err((char*)"match guard in the low profile", null); }
        c.pad(c, o);
        if (b.pat.tag == APAT_WILD || b.pat.tag == APAT_BIND)
        {
            if (b.pat.tag == APAT_BIND) { c.bind(b.pat.name, s.op, s.ty); }
            o.put((char*)"default: {\n");
        }
        else if (b.pat.tag == APAT_INT || b.pat.tag == APAT_BOOL || b.pat.tag == APAT_CHAR)
        {
            o.put((char*)"case "); o.int_(b.pat.ival); o.put((char*)": {\n");
        }
        else { c.err((char*)"pattern is not part of the low profile", null); return; }
        c.cmd(b.body, o);
        c.pad(c, o); o.put((char*)"}\n");
    }
    c.pad(c, o); o.put((char*)"}\n");
}

// ── functions and module ───────────────────────────────────────────────────
// The AIR fact attributes, printed before the function they license.
//
// This is the one place the C target can be better than the C a person writes,
// and the reason is narrow and exact: a C compiler reading the emitted C cannot
// know that `f` writes no memory or that a pointer does not escape. AIR computes
// both (air_facts.c3) and certifies them. Throwing them away and emitting plain C
// would make this backend a transcriber; using them makes it an optimiser that
// happens to have a C backend.
//
// Old-style attributes (`__attribute__((pure))`) are used rather than C23
// `[[gnu::pure]]` because they work on every GCC/Clang this could meet.
fn void C.fn_attrs(C* c, AirDecl* d, Sb* o)
{
    if (d == null) { return; }
    if (d.fact_state == air_ir::AirFactState.AFACT_AIR_CHECKED && d.memory_readonly)
    {
        // memory_readonly: no externally visible writes. That is C's `pure`
        // (may read globals/memory, may be called with different arguments to
        // the same result, no side effects). It is NOT `const`: `const` promises
        // the function reads no memory at all, which AIR does not establish.
        //
        // Measured (tests/air3/c/opt): on a count-and-sum loop whose callee is a
        // separate module, this is 1.5-1.8x over the same program compiled as
        // plain C, and 0.96x -- i.e. nothing -- without it. It is the one thing
        // this backend can do that a person writing C cannot, because the C
        // compiler cannot see across the module boundary and AIR can.
        o.put((char*)"__attribute__((pure)) ");
    }
}

fn void C.header(C* c, AirDecl* d, Sb* o, bool as_main_wrapper)
{
    (void)as_main_wrapper;
    if (ty_is_void(d.ret_ty)) { o.put((char*)"void "); } else { c.ty(o, d.ret_ty); o.putc(' '); }
    c.name(o, d.name, false);
    o.putc('(');
    usz wrote = 0;
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* b = d.params[i];
        if (b == null) { continue; }
        if (!ty_low(b.ty, 0)) { c.err((char*)"parameter type is not part of the low profile", b.name); }
        if (wrote > 0) { o.put((char*)", "); }
        // `T *restrict name` -- the qualifier goes between the star and the name.
        bool restr = param_can_restrict(d, b) && b.ty.arg_count == 1 && b.ty.args[0] != null;
        if (restr)
        {
            c.ty(o, b.ty.args[0]); o.put((char*)" *restrict "); c.name(o, b.name, false);
        }
        else { c.ty_decl(c, o, b.ty, b.name); }
        wrote++;
    }
    if (!wrote) { o.put((char*)"void"); }
    o.putc(')');
}

fn void C.function(C* c, AirDecl* d, Sb* out)
{
    c.fn_name = d.name;
    c.nv = 0; c.nl = 0; c.tmp = 0;
    c.cur_ret = d.ret_ty;
    c.decls.n = 0; if (c.decls.d != null) { c.decls.d[0] = 0; }
    if (!ty_low(d.ret_ty, 0)) { c.err((char*)"return type is not part of the low profile", null); }

    // label spine: seq { label A c ; seq { label B c ; entry } }
    AirCmd* x = d.def_body;
    while (x != null && x.tag == ACMD_SEQ && x.body != null && x.body.tag == ACMD_LABEL)
    {
        c.add_label(c, x.body);
        x = x.next;
    }
    if (x != null && x.tag == ACMD_LABEL) { c.add_label(c, x); x = null; }
    if (x != null) { c.err((char*)"function body is not a label spine", null); }

    for (usz i = 0; i < d.param_count; i++) { AirBinder* b = d.params[i]; if (b != null) { c.bind(b.name, b.name, b.ty); } }

    bool is_main = air_text::streq(d.name, "main");
    bool wrap = is_main && (ty_is_void(d.ret_ty) || air_util::ty_is_int(d.ret_ty));

    Sb body; body.init();
    for (usz i = 0; i < c.nl; i++)
    {
        Lbl* lb = &c.lbls[i];
        // every label parameter is a function-scope local, declared once (§3.2)
        for (usz j = 0; j < lb.np; j++)
        {
            if (lb.params[j] == null) { continue; }
            c.decls.put((char*)"    ");
            c.ty_decl(c, &c.decls, lb.params[j].ty, lb.params[j].name);
            c.decls.put((char*)";\n");
            c.bind(lb.params[j].name, lb.params[j].name, lb.params[j].ty);
        }
        // A label with no incoming jump is unreachable; C accepts it but a
        // compiler warns, and an AIR function never has one. Still print it:
        // dropping a label silently would hide a producer bug.
        c.pad(c, &body); body.put((char*)"goto ");
        c.name(c, &body, lb.name, false); body.put((char*)";\n");
        c.name(c, &body, lb.name, false); body.put((char*)": {\n");
        c.cmd(lb.body, &body);
        c.pad(c, &body); body.put((char*)"}\n");
    }

    c.fn_attrs(c, d, out);            // the AIR facts, licensed to the C compiler
    c.header(c, d, out, wrap);
    out.put((char*)"\n{\n");
    if (c.decls.d != null) { out.put(c.decls.d); }
    if (body.d != null) { out.put(body.d); }
    out.put((char*)"}\n\n");
    if (wrap)
    {
        // the C ABI entry point, the same wrapper air_ll emits (§4.5)
        out.put((char*)"int main(void)\n{\n");
        if (ty_is_void(d.ret_ty))
        {
            out.put((char*)"    "); c.name(out, d.name, false); out.put((char*)"();\n    return 0;\n}\n\n");
        }
        else
        {
            out.put((char*)"    return (int)"); c.name(out, d.name, false); out.put((char*)"();\n}\n\n");
        }
    }
}

fn void C.add_label(C* c, AirCmd* lb)
{
    if (c.nl >= MAXL) { c.err((char*)"too many labels", lb.binder); return; }
    Lbl* l = &c.lbls[c.nl];
    l.name = lb.binder; l.np = lb.mbinder_count; l.body = lb.body;
    for (usz i = 0; i < lb.mbinder_count && i < 16; i++) { l.params[i] = lb.mbinders[i]; }
    c.nl++;
}

fn void C.data_type(C* c, AirDecl* d, Sb* o)
{
    if (d.ctor_count != 1) { c.err((char*)"data with several constructors (enum layout) is not part of this profile yet", d.name); return; }
    if (d.typaram_count > 0) { c.err((char*)"generic data is not part of the low profile", d.name); return; }
    if (decl_has_attr(d, "packed")) { o.put((char*)"PRIDE_PACKED "); }
    o.put((char*)"struct "); c.name(o, d.name, false); o.put((char*)" {\n");
    AirCtorDecl* ct = d.ctors[0];
    for (usz j = 0; j < ct.field_count; j++)
    {
        o.put((char*)"    ");
        if (!ty_low(ct.fields[j].ty, 0)) { c.err((char*)"field type is not part of the low profile", ct.fields[j].name); }
        c.ty_decl(c, o, ct.fields[j].ty, ct.fields[j].name);
        o.put((char*)";\n");
    }
    if (ct.field_count == 0) { o.put((char*)"    char __unit;\n"); }
    o.put((char*)"};\n\n");
}

fn void C.global_decl(C* c, AirDecl* d, Sb* o)
{
    char* sec = decl_attr_str(d, "section");
    if (sec != null) { o.put((char*)"PRIDE_SECTION(\""); o.put(sec); o.put((char*)"\") "); }
    long al = decl_attr_int(d, "align");
    if (al > 0) { o.put((char*)"PRIDE_ALIGN("); o.int_(al); o.put((char*)") "); }
    if (decl_has_attr(d, "thread_local")) { o.put((char*)"PRIDE_TLOCAL "); }
    if (d.is_extern && d.g_init == null)
    {
        o.put((char*)"extern "); c.ty(o, d.ret_ty); o.putc(' ');
        c.name(o, d.name, true); o.put((char*)";\n");
        return;
    }
    if (!d.g_mut) { o.put((char*)"const "); }
    c.ty(o, d.ret_ty); o.putc(' ');
    c.name(o, d.name, true);
    if (d.g_init == null) { o.put((char*)";\n"); return; }   // C zero-initialises
    o.put((char*)" = ");
    Sb s; s.init(); c.scalar(&s, d.g_init, d.ret_ty); o.put(s.take());
    o.put((char*)";\n");
}

fn void C.declare(C* c, AirDecl* d, Sb* o)
{
    c.fn_attrs(c, d, o);
    o.put((char*)"extern ");
    if (ty_is_void(d.ret_ty)) { o.put((char*)"void "); } else { c.ty(o, d.ret_ty); o.putc(' '); }
    c.name(o, d.name, false);
    o.putc('(');
    usz wrote = 0;
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* b = d.params[i];
        if (b == null) { continue; }
        if (wrote > 0) { o.put((char*)", "); }
        c.ty_decl(c, o, b.ty, b.name);
        wrote++;
    }
    if (d.is_varargs) { if (wrote > 0) { o.put((char*)", "); } o.put((char*)"..."); }
    else if (!wrote) { o.put((char*)"void"); }
    o.put((char*)")"); o.put((char*)";\n");
}

// The generated runtime, emitted verbatim into every file so that the artifact is
// self-contained: a .c produced from a user's .pie must not depend on where this
// repository's headers live. tests/air3/c/__pride_rt.h is a copy used by the
// executed shape test, and tests/air3/test_c_target.py asserts that every
// __pride_ name the emitter prints appears in this text.
fn void C.prelude(C* c, Sb* o)
{
    (void)c;
    o.put((char*)"#include <stdint.h>\n#include <stdbool.h>\n#include <stdatomic.h>\n#include <string.h>\n\n");
    o.put((char*)"typedef intptr_t  pride_isz;\ntypedef uintptr_t pride_usz;\ntypedef struct { char __unused; } pride_unit;\n\n");
    o.put((char*)"static inline void __pride_trap(const char *why) { (void)why; __builtin_trap(); }\n");
    o.put((char*)"#define __pride_ub(why) __builtin_unreachable()\n\n");
    o.put((char*)"#define PRIDE_SECTION(x) __attribute__((section(x)))\n");
    o.put((char*)"#define PRIDE_ALIGN(n)   __attribute__((aligned(n)))\n");
    o.put((char*)"#define PRIDE_PACKED     __attribute__((packed))\n");
    o.put((char*)"#define PRIDE_TLOCAL     _Thread_local\n");
    o.put((char*)"#define PRIDE_NORETURN   __attribute__((noreturn))\n");
    o.put((char*)"#define PRIDE_INLINE     __attribute__((always_inline)) inline\n");
    o.put((char*)"#define PRIDE_NOINLINE   __attribute__((noinline))\n\n");
    // syscall: x86-64 Linux only. rax = number, then rdi rsi rdx r10 r8 r9.
    o.put((char*)"/* syscall: x86-64 Linux. r10 before r8 is the kernel ABI, not a typo. */\n");
    o.put((char*)"static inline int64_t __pride_syscall1(int64_t n)\n{ int64_t r; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall2(int64_t n, int64_t a)\n{ int64_t r; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall3(int64_t n, int64_t a, int64_t b)\n{ int64_t r; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a), \"S\"(b) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall4(int64_t n, int64_t a, int64_t b, int64_t d)\n{ int64_t r; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a), \"S\"(b), \"d\"(d) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall5(int64_t n, int64_t a, int64_t b, int64_t d, int64_t e)\n{ int64_t r; register int64_t r10 __asm__(\"r10\") = e; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a), \"S\"(b), \"d\"(d), \"r\"(r10) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall6(int64_t n, int64_t a, int64_t b, int64_t d, int64_t e, int64_t f)\n{ int64_t r; register int64_t r10 __asm__(\"r10\") = e; register int64_t r8 __asm__(\"r8\") = f; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a), \"S\"(b), \"d\"(d), \"r\"(r10), \"r\"(r8) : \"rcx\", \"r11\", \"memory\"); return r; }\n");
    o.put((char*)"static inline int64_t __pride_syscall7(int64_t n, int64_t a, int64_t b, int64_t d, int64_t e, int64_t f, int64_t g)\n{ int64_t r; register int64_t r10 __asm__(\"r10\") = e; register int64_t r8 __asm__(\"r8\") = f; register int64_t r9 __asm__(\"r9\") = g; __asm__ volatile (\"syscall\" : \"=a\"(r) : \"a\"(n), \"D\"(a), \"S\"(b), \"d\"(d), \"r\"(r10), \"r\"(r8), \"r\"(r9) : \"rcx\", \"r11\", \"memory\"); return r; }\n\n");
}

fn int to_c(AirModule* m, char** result, bool want_text)
{
    C* c = (C*)malloc(C::size);
    c.m = m; c.errs = 0; c.fn_name = null; c.emit = want_text;
    c.vn = (char**)malloc(8 * MAXV); c.vv = (Val*)malloc(Val::size * MAXV);
    c.lbls = (Lbl*)malloc(Lbl::size * MAXL);
    c.nv = 0; c.nl = 0; c.tmp = 0; c.nstr = 0;
    c.decls.init(); c.types_out.init(); c.pre.init();

    Sb body; body.init();
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null || d.tag != ADECL_DATA) { continue; }
        c.fn_name = d.name;
        c.data_type(c, d, &c.types_out);
        c.fn_name = null;
    }
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        switch (d.tag)
        {
            case ADECL_GLOBAL: c.fn_name = d.name; c.global_decl(c, d, &body); c.fn_name = null; break;
            case ADECL_DECLARE:
            {
                bool defd = false;
                for (usz j = 0; j < m.decl_count; j++) { AirDecl* e = m.decls[j]; if (e != null && e.tag == ADECL_DEF && air_text::streq(e.name, d.name)) { defd = true; } }
                if (defd) { break; }
                c.fn_name = d.name; c.declare(c, d, &body); c.fn_name = null; break;
            }
            case ADECL_DEF: c.function(c, d, &body); break;
            case ADECL_MODULE: case ADECL_IMPORT: case ADECL_DATA: break;
            default: c.fn_name = d.name; c.err((char*)"declaration is not part of the low profile", d.name); c.fn_name = null; break;
        }
    }

    Sb all; all.init();
    all.put((char*)"/* generated by air_c from an AIR 3.0 module -- C is a transpilation target,\n");
    all.put((char*)" * docs/pear2/C_TARGET.md. Do not edit: regenerate from the .air. */\n");
    if (m.source_path != null) { all.put((char*)"/* source: "); all.put(m.source_path); all.put((char*)" */\n"); }
    c.prelude(&all);
    if (c.types_out.d != null) { all.put(c.types_out.d); }
    if (c.pre.d != null) { all.put(c.pre.d); all.putc('\n'); }
    if (body.d != null) { all.put(body.d); }
    *result = all.take();
    int e = c.errs;
    return e;
}

fn int write_c(AirModule* m, char* path)
{
    char* text = null;
    int errs = to_c(m, &text, true);
    if (text == null) { return -1; }
    void* f = path != null ? fopen(path, "w") : fdopen(1, "w");
    if (f == null) { return -1; }
    usz n = 0; while (text[n] != 0) { n++; }
    fwrite((void*)text, 1, n, f);
    // The close IS the write result: a full disk reports success on every fwrite
    // and fails at fclose. Ignoring it published empty artifacts (defect 2).
    int close_rc = (path != null) ? fclose(f) : fflush(f);
    if (close_rc != 0 && errs == 0) { errs = 1; }
    return errs;
}
