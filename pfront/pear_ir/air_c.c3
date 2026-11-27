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
// Ctx is a TRANSPILATION TARGET here (docs/pear2/C_TARGET.md §1). The reason it
// beats C3 for this job is one property: Ctx has `goto`. AIR 3.0 is a CFG with
// label-parameter (phi) joins, so in Ctx one AIR label is one Ctx label and one AIR
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
// tests/air3/c/shape_test.c on every `make test-c-target`, so the Ctx is proven
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

struct Ctx
{
    AirModule* m;
    int        errs;
    char*      fn_name;
    bool       emit;

    // per function
    char**     vn; Val* vv; usz nv;
    Lbl*       lbls; usz nl;
    Sb         decls;      // every local declaration, hoisted to the top (§3.4)
    char**     dn; usz ndn; // names already declared in this function
    usz        tmp;
    AirTyp*    cur_ret;
    AirTyp*    ret_seen;   // the type infer_ret settled on
    bool       quiet;      // a prescan pass: a partial answer is not an error
    char**     tup; // tuple shapes already defined (module level)
    usz        ntup;

    // module level
    Sb         types_out;  // structs, one per distinct shape
    Sb         pre;        // string literals
    usz        nstr;
}

fn void Ctx.err(Ctx* c, char* what, char* who)
{
    if (c.quiet) { return; }
    c.errs++;
    void* se = fdopen(2, "w");
    if (c.errs <= 12) { fprintf(se, "air-c: in `%s`: %s%s%s\n", c.fn_name == null ? (char*)"<module>" : c.fn_name, what, who == null ? (char*)"@" : (char*)": ", who == null ? (char*)"" : who); }
    fflush(se);
}

fn AirDecl* Ctx.find(Ctx* c, char* nm)
{
    if (nm == null) { return null; }
    for (usz i = 0; i < c.m.decl_count; i++)
    {
        AirDecl* d = c.m.decls[i];
        if (d != null && d.name != null && d.tag != ADECL_MODULE && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

fn AirDecl* Ctx.find_data(Ctx* c, char* nm)
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

fn void Ctx.bind(Ctx* c, char* nm, char* op, AirTyp* ty)
{
    if (nm == null) { return; }
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { c.vv[i].op = op; c.vv[i].ty = ty; return; } }
    if (c.nv >= MAXV) { c.err((char*)"too many names", nm); return; }
    c.vn[c.nv] = nm; c.vv[c.nv].op = op; c.vv[c.nv].ty = ty; c.nv++;
}

fn bool Ctx.lookup(Ctx* c, char* nm, Val* out)
{
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { *out = c.vv[i]; return true; } }
    return false;
}

fn char* Ctx.fresh(Ctx* c, char* stem)
{
    Sb s; s.init(); s.put(stem); s.int_((long)c.tmp); c.tmp++;
    return s.take();
}

// C has no quoted-identifier escape, while AIR names may be any bytes (the spec's
// quoted-identifier form, §3). air_low emits dotted labels as a matter of course
// (`wh.head4`), so refusing every non-C name refuses every real loop. The mapping
// applied by Ctx.name is injective -- `_` becomes `__`, any other byte outside
// [A-Za-z0-9] becomes `_h` and two lowercase hex digits -- so distinct AIR names
// stay distinct C names and nothing is silently merged. A rename that cannot
// collide is a spelling, not a silent rename.
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
    static char*[45] kw = {
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof",
        "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local", "_FakeMono"
    };
    for (usz ki = 0; ki < 45; ki++) { if (air_text::streq(kw[ki], s)) { return false; } }
    return true;
}

// Injective: `_` -> `__`, a legal byte -> itself, any other byte -> `_hHH`.
// A leading digit is escaped too, since no C identifier may start with one.
fn void Ctx.mangle(Ctx* c, Sb* o, char* nm)
{
    (void)c;
    char* hex = (char*)"0123456789abcdef";
    usz i = 0;
    while (nm[i] != 0)
    {
        char ch = nm[i];
        bool legal = (ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ((ch >= '0' && ch <= '9') && i > 0));
        if (ch == '_') { o.put((char*)"__"); }
        else if (legal) { o.putc(ch); }
        else
        {
            uint u = (uint)ch & 255;
            o.put((char*)"_h");
            o.putc(hex[(u >> 4) & 15]);
            o.putc(hex[u & 15]);
        }
        i = i + 1;
    }
}

fn void Ctx.name(Ctx* c, Sb* o, char* nm, bool global)
{
    if (nm == null || (nm[0] == '_' && nm[1] == 0)) { o.put((char*)"__anon"); return; }
    if (global) { o.put((char*)"pear_out_"); }
    if (c_ident_ok(nm)) { o.put(nm); return; }
    c.mangle(o, nm);
}

// ── types ──────────────────────────────────────────────────────────────────
fn void Ctx.ty(Ctx* c, Sb* o, AirTyp* t)
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

// `T name` with the declarator attached where Ctx needs it. An arrow type already
// carries its own `(*)`, so the name goes inside it; everything else is `T name`.
// C's declarator syntax is not prefix: `T a[N]`, `T (*a)[N]`, `T *a`. A type
// written `ptr(array(i64, 128))` must therefore become `int64_t (*a)[128]`, and
// printing the type first and the name after -- which is what this did -- wrote
// the *Pride* spelling (`int64_t[128] * a`) into the C. Build the declarator
// from the inside out instead.
fn void Ctx.declarator(Ctx* c, Sb* o, AirTyp* t, char* nm)
{
    if (t == null) { o.put((char*)"int64_t "); c.name(o, nm, false); return; }
    if (t.tag == ATYP_ARROW)
    {
        AirTyp* dom = t.arg_count > 0 ? t.args[0] : null;
        AirTyp* cod = t.arg_count > 1 ? t.args[1] : null;
        if (cod == null || cod.tag == ATYP_UNIT) { o.put((char*)"void"); } else { c.ty(o, cod); }
        o.put((char*)" (*"); c.name(o, nm, false); o.put((char*)")( ");
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
        o.put((char*)"))");
        return;
    }
    if (t.tag == ATYP_PTR && t.arg_count > 0 && t.args[0] != null && t.args[0].tag == ATYP_ARRAY)
    {
        // A pointer to an array is `T (*a)[N]`, never `T[N] *a`.
        AirTyp* at = t.args[0];
        long[8] dims; usz nd = 0;
        while (at != null && at.tag == ATYP_ARRAY && nd < 8)
        {
            dims[nd] = at.ival; nd = nd + 1;
            at = at.arg_count > 0 ? at.args[0] : null;
        }
        c.ty(o, at);
        o.put((char*)" (*"); c.name(o, nm, false); o.putc(')');
        for (usz di = 0; di < nd; di++) { o.putc('['); o.int_(dims[nd - 1 - di]); o.putc(']'); }
        return;
    }
    if (t.tag == ATYP_ARRAY)
    {
        AirTyp* at = t;
        long[8] dims; usz nd = 0;
        while (at != null && at.tag == ATYP_ARRAY && nd < 8)
        {
            dims[nd] = at.ival; nd = nd + 1;
            at = at.arg_count > 0 ? at.args[0] : null;
        }
        c.ty(o, at);
        o.putc(' '); c.name(o, nm, false);
        for (usz di = 0; di < nd; di++) { o.putc('['); o.int_(dims[nd - 1 - di]); o.putc(']'); }
        return;
    }
    c.ty(o, t); o.putc(' '); c.name(o, nm, false);
}

fn void Ctx.ty_decl(Ctx* c, Sb* o, AirTyp* t, char* nm)
{
    c.declarator(o, t, nm);
}

// ── producers ──────────────────────────────────────────────────────────────
fn char* Ctx.str_const(Ctx* c, AirPrd* p)
{
    Sb nm; nm.init(); nm.put((char*)"__s"); nm.int_((long)c.nstr);
    char* name = nm.take();
    c.nstr++;
    // A string's bytes live in `name` and a byte-string's in `bytes`
    // (air_ir.c3:513 vs :515 -- only the bytes constructor sets `bytes`).
    // Reading `bytes` for both dereferenced null on the first string literal.
    char* body = p.tag == APRD_BYTES ? p.bytes : p.name;
    usz n = p.bytes_len > 0 ? (usz)p.bytes_len : 0;
    Sb* o = &c.pre;
    o.put((char*)"static const char ");
    c.name(o, name, false);
    o.put((char*)"[") ; o.int_((long)(n + 1)); o.put((char*)"] = \"");
    for (usz i = 0; i < n; i++)
    {
        uint b = body != null ? (uint)body[i] & 255 : 0;
        if (b == 34) { o.put((char*)"\\\""); }
        else if (b == 92) { o.put((char*)"\\\\"); }
        else if (b == 10) { o.put((char*)"\\n"); }
        else if (b == 9) { o.put((char*)"\\t"); }
        else if (b == 13) { o.put((char*)"\\r"); }
        else if (b == 63) { o.put((char*)"\\?"); }      // not a trigraph by accident
        else if (b < 32 || b > 126) { o.put((char*)"\\x"); o.hex((ulong)b, 2); }
        else { o.putc((char)b); }
    }
    o.put((char*)"\";\n");
    return name;
}

fn void Ctx.scalar(Ctx* c, Sb* o, AirPrd* p, AirTyp* typed)
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
        case APRD_CHAR:
        {
            // air_ll.c3:311 types a char t_char and prints the code point as a
            // bare number. Doing the same here is what keeps the two consumers
            // agreeing, but a bare number is only correct if the operand type is
            // also t_char (uint32_t): C's usual conversions would otherwise make
            // `i8 -61 == 195` quietly false. So the cast is explicit and the
            // type is ATYP_CHAR, never a fixed width that fights the context.
            o.put((char*)"((uint32_t)"); o.int_(p.ival); o.putc(')');
            return;
        }
        case APRD_NULL: o.put((char*)"NULL"); return;
        default: c.err((char*)"not a scalar constant", prd_tag_name(p.tag)); return;
    }
}

fn Val Ctx.prd(Ctx* c, AirPrd* p)
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
        case APRD_INT: case APRD_FLOAT: case APRD_BOOL: case APRD_NULL:
        {
            Sb s; s.init(); c.scalar(&s, p, p.ty); v.op = s.take(); v.ty = p.ty; return v;
        }
        case APRD_CHAR:
        {
            // air_ll types a char literal t_char unconditionally (air_ll.c3:311).
            // Doing it here too keeps `v.ty` non-null: `binop` refuses operands
            // whose type it cannot see, so a null type turned every char
            // comparison into `/*undef*/` -- silently, because the error was
            // reported against a producer, not the expression.
            Sb s; s.init(); c.scalar(&s, p, p.ty); v.op = s.take(); v.ty = c.m.t_char; return v;
        }
        case APRD_UNIT: v.ty = p.ty; v.op = (char*)"((pride_unit){0})"; return v;
        case APRD_STRING: case APRD_BYTES: v.ty = p.ty; v.op = c.str_const(p); return v;
        case APRD_BINOP:  return c.binop(p);
        case APRD_UNOP:   return c.unop(p);
        case APRD_COERCE: return c.coerce(p);
        case APRD_ALLOCA:
        {
            if (!ty_low(p.ty_arg, 0)) { c.err((char*)"alloca of a non-low type", null); }
            char* t = c.fresh((char*)"v");
            // Hoisted with every other declaration (§3.4): a jump must never cross
            // a declaration, and the slot is addressed on more than one path.
            c.decls.put((char*)"    ");
            c.ty_decl(&c.decls, p.ty_arg, t);
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
        case APRD_GEP: return c.gep(p);
        case APRD_TUPLE: case APRD_RECORD: case APRD_ARRAY: return c.aggregate(p);
        case APRD_SIZEOF:
        {
            Sb s; s.init(); s.put((char*)"((pride_usz)sizeof("); c.ty(&s, p.ty); s.put((char*)"))");
            v.op = s.take(); v.ty = c.m.t_usz; return v;
        }
        default:
            c.err((char*)"producer is not part of the low profile", prd_tag_name(p.tag)); return v;
    }
}

fn bool field_at(Ctx* c, AirTyp* cur, long ix, AirTyp** out)
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

fn Val Ctx.gep(Ctx* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    Val b = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    if (b.ty == null || b.ty.tag != ATYP_PTR) { c.err((char*)"gep base is not a pointer", null); return v; }
    AirTyp* cur = p.ty_arg;
    if (!ty_low(cur, 0)) { c.err((char*)"gep over a non-low type", null); return v; }
    if (!air_util::ty_eq(b.ty.args[0], cur)) { c.err((char*)"gep source element type differs from the base pointee", null); return v; }

    Val[16] idx;
    for (usz i = 1; i < p.sub_count && i < 16; i++) { idx[i] = c.prd(p.subs[i]); }
    for (usz i = 1; i < p.sub_count && i < 16; i++) { if (!air_util::ty_is_int(idx[i].ty)) { c.err((char*)"gep index is not an integer", null); } }
    if (p.sub_count > 16) { c.err((char*)"gep with more than 15 indices", null); }

    // The access expression, following the same walk air_ll's Ll.gep does so the
    // two consumers cannot disagree about layout.
    Sb acc; acc.init();
    AirTyp* step = cur;
    // Index 1 scales: `base + i` IS the element address. Every later step
    // (a field `->f`, an element `[i]`) appends to the expression and leaves an
    // lvalue instead, which is what decides whether the result needs `&`.
    bool acc_is_ptr = true;
    if (p.sub_count <= 1) { acc.put(b.op); }
    else
    {
        acc.putc('('); acc.put(b.op); acc.put((char*)" + "); acc.put(idx[1].op); acc.putc(')');
        for (usz i = 2; i < p.sub_count && i < 16; i++)
        {
            if (step == null) { c.err((char*)"gep indexes past a scalar", null); break; }
            if (step.tag == ATYP_ARRAY) { acc.putc('['); acc.put(idx[i].op); acc.putc(']'); step = step.args[0]; acc_is_ptr = false; continue; }
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
                    // `gep` steps through ADDRESSES, so the value before this
                    // field access is a pointer whenever the earlier steps were
                    // not array indexing -- `(_s7 + 0).json` is the bug: C wants
                    // `->`. Track whether the current step yields a value or an
                    // address, which is exactly the `.` versus `->` distinction.
                    if (acc_is_ptr) { acc.put((char*)"->"); }
                    else { acc.putc('.'); }
                    c.name(&acc, dd.ctors[0].fields[(usz)ip.ival].name, false);
                    acc_is_ptr = false;
                }
                step = ft;
                continue;
            }
            c.err((char*)"gep indexes into a type with no members", null); break;
        }
    }
    Sb s; s.init();
    // A pointer-element gep IS the address: `base + i` is `&base[i]`, and its C
    // type is already the element pointer AIR's `: ptr(T)` names. Wrapping it in
    // `&` produced `&(base + i)` -- type T**, one indirection too many, so `store`
    // wrote through the wrong level. An aggregate gep needs `&(base.field)`.
    char* accs = acc.take();
    // Two forms, and they are not interchangeable:
    //   * a field or element step ends in an lvalue (`(base+i)->f`, `a[i]`), so
    //     the address the consumer wants is `&lvalue`;
    //   * a bare scaled pointer (`base + i`) is already that address.
    // Emitting the second where the first belongs made `store` assign to the
    // expression and gcc said "assignment to expression with array type"; using
    // the first everywhere gave `&(base+i)`, one indirection too many.
    if (acc_is_ptr) { s.put((char*)"("); s.put(accs); s.putc(')'); }
    else { s.putc('&'); s.put((char*)"("); s.put(accs); s.putc(')'); }
    v.op = s.take();
    v.ty = (step != null && p.ty != null) ? p.ty : null;
    return v;
}

fn Val Ctx.aggregate(Ctx* c, AirPrd* p)
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

fn Val Ctx.binop(Ctx* c, AirPrd* p)
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

fn Val Ctx.unop(Ctx* c, AirPrd* p)
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

fn Val Ctx.coerce(Ctx* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = p.ty;
    Val a = c.prd(p.sub_count > 0 ? p.subs[0] : null);
    AirTyp* to = p.ty;
    // A coerced operand may be a binder the text does not re-type (`coerce(_sz2,
    // i64)`). The prescan already recorded it; ask before giving up.
    if (a.ty == null && p.sub_count > 0 && p.subs[0] != null) { Val t = c.prd_ty(p.subs[0]); a.ty = t.ty; }
    if (a.ty == null || to == null) { c.err((char*)"coerce without types", null); return v; }
    if (!ty_low(to, 0)) { c.err((char*)"coerce to a non-low type", null); return v; }
    if (air_util::ty_eq(a.ty, to)) { v.op = a.op; return v; }
    AirTyp* f = a.ty;
    bool fi = air_util::ty_is_int(f) || air_util::ty_is_bool(f);
    bool ti = air_util::ty_is_int(to) || air_util::ty_is_bool(to);
    bool legal = false;
    // Two integer types are coercible whenever they differ -- `usz -> i64` is a
    // 64-bit-to-64-bit reinterpret and air_low emits it for every sizeof. Testing
    // the bit widths instead called that "not defined" and refused the program.
    if (fi && ti) { legal = !air_util::ty_eq(f, to); }
    else if (fi && air_util::ty_is_float(to)) { legal = true; }
    else if (air_util::ty_is_float(f) && ti) { legal = true; }
    else if (air_util::ty_is_float(f) && air_util::ty_is_float(to)) { legal = true; }
    else if (air_util::ty_is_ptr(f) && ti) { legal = true; }
    else if (fi && air_util::ty_is_ptr(to)) { legal = true; }
    // Two pointers of different pointee types are NOT the same C type, so a bare
    // `v.op = a.op` silently reinterprets `uint8_t*` as `int64_t*` (gcc warns and
    // the arithmetic is then wrong). Emit the cast that says what AIR meant.
    else if (air_util::ty_is_ptr(f) && air_util::ty_is_ptr(to))
    {
        if (air_util::ty_eq(f, to)) { v.op = a.op; return v; }
        Sb ps; ps.init(); ps.put((char*)"(("); c.ty(&ps, to); ps.put((char*)")(("); ps.put(a.op); ps.put((char*)")))");
        v.op = ps.take(); return v;
    }
    else if ((f.tag == ATYP_ARROW && air_util::ty_is_ptr(to)) || (air_util::ty_is_ptr(f) && to.tag == ATYP_ARROW)) { v.op = a.op; return v; }
    if (!legal) { c.err((char*)"coerce between these types is not defined", null); return v; }
    // One cast. Ctx picks the signed/unsigned and truncate/extend path from the
    // source type, which is exactly what AIR's coerce means; LLVM needs a
    // distinct opcode for each and air_ll therefore has eight branches here.
    Sb s; s.init(); s.put((char*)"(("); c.ty(&s, to); s.put((char*)")(("); s.put(a.op); s.put((char*)")))");
    v.op = s.take();
    return v;
}

// ── statements ─────────────────────────────────────────────────────────────
fn void Ctx.pad(Ctx* c, Sb* o) { (void)c; o.put((char*)"    "); }

fn void Ctx.stmt_ret(Ctx* c, Sb* o, AirPrd* p)
{
    c.pad(o);
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

fn void Ctx.call(Ctx* c, AirPrd* callee, AirCns* k, AirCmd** next_out, Sb* o)
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
    // AIR writes a call's continuation as bare `comu _r2.` -- the text carries no
    // type there, because the callee's declaration already says it. Take it from
    // the callee rather than emitting an untyped declaration.
    AirTyp* rty = cur.ty;
    if (rty == null && callee != null && callee.tag == APRD_VAR)
    {
        AirDecl* fd = c.find(callee.name);
        if (fd != null) { rty = fd.ret_ty; }
    }
    Sb s; s.init();
    c.pad(o);
    // A call result is read from another branch as often as from its own (a
    // `parse` in one arm, tested in the next), so it belongs at function scope
    // for the same reason a `let` does. Declared where C can see it, assigned here.
    if (cur.bind != null && rty != null && !ty_is_void(rty))
    {
        if (!c.declared(cur.bind))
        {
            c.decls.put((char*)"    ");
            c.ty_decl(&c.decls, rty, cur.bind);
            c.decls.put((char*)";\n");
            c.mark_declared(cur.bind);
        }
        c.name(&s, cur.bind, false); s.put((char*)" = ");
    }
    else if (cur.bind != null && rty == null) { c.err((char*)"call result has no known type", callee != null ? callee.name : null); }
    s.putc('('); s.put(f.op); s.put((char*)")(");
    for (usz i = 0; i < na; i++) { if (i > 0) { s.put((char*)", "); } s.put(args[i].op); }
    s.put((char*)")"); s.put((char*)";\n");
    o.put(s.take());
    if (cur.bind != null) { c.bind(cur.bind, cur.bind, rty); }
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

fn void Ctx.jump(Ctx* c, AirCmd* x, Sb* o)
{
    if (x.target_label == null) { c.err((char*)"jump without a target", null); return; }
    // No raw c_ident_ok here: AIR labels carry dots (`wh.head4`) and Ctx.name
    // applies the injective spelling. Testing the raw name here rejected every
    // real loop before it reached the writer that knows how to spell it.

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
            tmps[i] = c.fresh((char*)"t");
            c.pad(o);
            if (tb.params[i] != null)
            {
                c.ty_decl(o, tb.params[i].ty, tmps[i]);
                o.put((char*)" = "); o.put(src[i].op); o.put((char*)";\n");
            }
        }
        for (usz i = 0; i < n; i++)
        {
            if (tb.params[i] == null) { continue; }
            c.pad(o);
            c.name(o, tb.params[i].name, false);
            o.put((char*)" = "); o.put(tmps[i]); o.put((char*)";\n");
        }
    }
    else if (n == 1 && tb.params[0] != null)
    {
        c.pad(o);
        c.name(o, tb.params[0].name, false);
        o.put((char*)" = "); o.put(src[0].op); o.put((char*)";\n");
    }
    c.pad(o); o.put((char*)"goto ");
    // Through Ctx.name, not the raw bytes: the label definition was spelled by
    // name(), so an unmangled `goto` would name a label that does not exist.
    c.name(o, x.target_label, false);
    o.put((char*)";\n");
}

fn void Ctx.cmd(Ctx* c, AirCmd* cmd, Sb* o)
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
                // AIR nests bindings in a dominator spine, so the entry label --
                // which binds the loop's allocas -- is the LAST element of the
                // spine while earlier labels already read those names. C is
                // lexically scoped, so declaring at the point of definition puts
                // every such name out of reach. Declare at function scope
                // instead and assign here: that is the same treatment air_ll
                // gives an alloca, applied to every binding.
                if (!c.declared(x.binder))
                {
                    c.decls.put((char*)"    ");
                    c.ty_decl(&c.decls, v.ty, x.binder);
                    c.decls.put((char*)";\n");
                    c.mark_declared(x.binder);
                }
                // An array-typed binding is a value copy: C cannot assign one,
                // so the declaration is the slot and memcpy fills it.
                if (v.ty != null && v.ty.tag == ATYP_ARRAY)
                {
                    c.pad(o);
                    o.put((char*)"memcpy((void *)(&"); c.name(o, x.binder, false); o.put((char*)"), (const void *)(&"); o.put(v.op);
                    o.put((char*)"), sizeof("); c.ty(o, v.ty); o.put((char*)"));\n");
                }
                else
                {
                    c.pad(o);
                    c.name(o, x.binder, false);
                    o.put((char*)" = "); o.put(v.op); o.put((char*)";\n");
                }
                c.bind(x.binder, x.binder, v.ty);
                x = x.body; continue;
            }
            case ACMD_STORE:
            {
                Val p = c.prd(x.prds[0]); Val v = c.prd(x.prds[1]);
                if (p.ty == null || p.ty.tag != ATYP_PTR) { c.err((char*)"store to a non-pointer", null); return; }
                if (v.ty != null && !air_util::ty_eq(p.ty.args[0], v.ty)) { c.err((char*)"stored value type differs from the pointee type", null); }
                if (ty_is_void(v.ty)) { x = x.next; continue; }
                c.pad(o);
                // C has no aggregate assignment: an array is not assignable at all,
                // and a struct assignment is legal only between identical types.
                // AIR store is a byte copy of the pointee, so say exactly that.
                AirTyp* spt = p.ty.args[0];
                if (spt != null && spt.tag == ATYP_ARRAY)
                {
                    o.put((char*)"memcpy((void *)("); o.put(p.op); o.put((char*)"), (const void *)(&"); o.put(v.op);
                    o.put((char*)"), sizeof("); c.ty(o, spt); o.put((char*)"));\n");
                }
                else if (x.vol) { o.put((char*)"(*(volatile "); c.ty(o, spt); o.put((char*)" *)("); o.put(p.op); o.put((char*)")"); o.put((char*)" = "); o.put(v.op); o.put((char*)";\n"); }
                else { o.putc('*'); o.put((char*)"("); o.put(p.op); o.put((char*)")"); o.put((char*)" = "); o.put(v.op); o.put((char*)";\n"); }
                x = x.next; continue;
            }
            case ACMD_FENCE:
            {
                if (x.atomic_order < 1 || x.atomic_order > 4) { c.err((char*)"a fence needs acquire, release, acq_rel or seq_cst ordering", null); return; }
                c.pad(o); o.put((char*)"atomic_thread_fence("); o.put(order_c(x.atomic_order)); o.put((char*)")"); o.put((char*)";\n");
                x = x.next; continue;
            }
            case ACMD_RET: c.stmt_ret(o, x.prd); return;
            case ACMD_TRAP: c.pad(o); o.put((char*)"__pride_trap(\"trap\")"); o.put((char*)";\n"); return;
            case ACMD_UB:   c.pad(o); o.put((char*)"__pride_ub(\"ub\")"); o.put((char*)";\n"); return;
            case ACMD_JUMP: c.jump(x, o); return;
            case ACMD_IF:
            {
                Val cv = c.prd(x.prd);
                if (cv.ty != null && !air_util::ty_is_bool(cv.ty)) { c.err((char*)"if condition is not a bool", null); }
                c.pad(o); o.put((char*)"if ("); o.put(cv.op); o.put((char*)") {\n");
                c.cmd(x.then_c, o);
                if (x.else_c != null)
                {
                    c.pad(o); o.put((char*)"} else {\n");
                    c.cmd(x.else_c, o);
                    c.pad(o); o.put((char*)"}\n");
                }
                else { c.pad(o); o.put((char*)"}\n"); }
                x = x.next; continue;
            }
            case ACMD_MATCH: c.emit_switch(x, o); return;
            case ACMD_CUT:
            {
                AirCns* k = x.cns;
                if (k == null) { c.err((char*)"cut without a consumer", null); return; }
                if (k.tag == ACNS_COMU)
                {
                    Val v = c.prd(x.prd);
                    c.pad(o); c.ty_decl(o, v.ty, k.bind); o.put((char*)" = "); o.put(v.op); o.put((char*)";\n");
                    c.bind(k.bind, k.bind, v.ty);
                    x = k.body; continue;
                }
                if (k.tag == ACNS_COVAR) { c.stmt_ret(o, x.prd); return; }
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
                    c.pad(o);
                    c.ty_decl(o, ft, k.tail.bind);
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
                char* r = c.fresh((char*)"r");
                Sb s; s.init();
                c.pad(o);
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
                char* r = c.fresh((char*)"r");
                Sb s; s.init();
                c.pad(o);
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
                    char* rmwf = rmw_c(op);
                    if (rmwf == null) { c.err((char*)"atomic operation is not part of the low profile", null); return; }
                    s.put((char*)"int64_t "); s.put(r); s.put((char*)" = (int64_t)"); s.put(rmwf); s.put((char*)"((_Atomic "); c.ty(&s, et); s.put((char*)" *)("); s.put(p.op); s.put((char*)"), ("); c.ty(&s, et); s.put((char*)")("); s.put(c.prd(x.prds[0]).op); s.put((char*)"), "); s.put(order_c(ord)); s.putc(')');
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
                // accepts almost verbatim -- the one place Ctx is easier than C3,
                // where air_c3 has to refuse it.
                if (x.asm_text == null) { c.err((char*)"asm without a template", null); return; }
                if (x.asm_cons == null) { c.err((char*)"asm without constraints", null); return; }
                c.pad(o);
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
                if (x.cns != null && x.cns.tag == ACNS_COMU) { c.bind(x.cns.bind, (char*)"((pride_unit){0})", c.m.t_unit); x = x.cns.body; continue; }
                x = x.next; continue;
            }
            default:
                c.err((char*)"command is not part of the low profile", cmd_tag_name(x.tag)); return;
        }
    }
}

fn void Ctx.emit_switch(Ctx* c, AirCmd* x, Sb* o)
{
    Val s = c.prd(x.prd);
    if (!(air_util::ty_is_int(s.ty) || air_util::ty_is_bool(s.ty))) { c.err((char*)"match scrutinee is not an integer or bool", null); return; }
    c.pad(o); o.put((char*)"switch ("); o.put(s.op); o.put((char*)") {\n");
    for (usz i = 0; i < x.branch_count; i++)
    {
        AirBranch* b = x.branches[i];
        if (b == null || b.pat == null) { continue; }
        if (b.guard != null) { c.err((char*)"match guard in the low profile", null); }
        c.pad(o);
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
        c.pad(o); o.put((char*)"}\n");
    }
    c.pad(o); o.put((char*)"}\n");
}

// ── functions and module ───────────────────────────────────────────────────
// The AIR fact attributes, printed before the function they license.
//
// This is the one place the Ctx target can be better than the Ctx a person writes,
// and the reason is narrow and exact: a Ctx compiler reading the emitted Ctx cannot
// know that `f` writes no memory or that a pointer does not escape. AIR computes
// both (air_facts.c3) and certifies them. Throwing them away and emitting plain C
// would make this backend a transcriber; using them makes it an optimiser that
// happens to have a Ctx backend.
//
// Old-style attributes (`__attribute__((pure))`) are used rather than C23
// `[[gnu::pure]]` because they work on every GCC/Clang this could meet.
fn void Ctx.fn_attrs(Ctx* c, AirDecl* d, Sb* o)
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
        // this backend can do that a person writing Ctx cannot, because the C
        // compiler cannot see across the module boundary and AIR can.
        o.put((char*)"__attribute__((pure)) ");
    }
}

fn void Ctx.header(Ctx* c, AirDecl* d, Sb* o, bool as_main_wrapper)
{
    if (ty_is_void(d.ret_ty)) { o.put((char*)"void "); } else { c.ty(o, d.ret_ty); o.putc(' '); }
    // When a wrapper `int main(void)` is emitted below, this function must not be
    // called `main` -- two distinct definitions of one name is not C.
    if (as_main_wrapper) { o.put((char*)"pride_main"); } else { c.name(o, d.name, false); }
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
        else { c.ty_decl(o, b.ty, b.name); }
        wrote++;
    }
    if (!wrote) { o.put((char*)"void"); }
    o.putc(')');
}

// An AIR def may omit its result type (air_low does for `main`). C needs it, and
// every `ret(v)` in the body names one, so take the type of the first typed ret.
// A def whose rets disagree is not one function, and refusing beats guessing.
fn AirTyp* Ctx.infer_ret(Ctx* c, AirCmd* body, int* seen)
{
    AirCmd* x = body;
    int guard = 0;
    while (x != null && guard++ < 1000000)
    {
        if (x.tag == ACMD_RET && x.prd != null)
        {
            // The prd's own `: T` annotation is readable without any binder, which
            // matters because this runs in the prototype pass, before the body's
            // binders exist. Fall back to the walked value when it is absent.
            AirTyp* at = x.prd.ty;
            Val v;
            if (at != null) { v.ty = at; v.op = (char*)"/*undef*/"; }
            else { v = c.prd(x.prd); }
            if (v.ty != null && !ty_is_void(v.ty))
            {
                if (*seen > 0 && c.ret_seen != null && !air_util::ty_eq(c.ret_seen, v.ty)) { return null; }
                c.ret_seen = v.ty; *seen = *seen + 1;
            }
            else if (v.ty != null) { *seen = *seen + 1; }
        }
        if (x.tag == ACMD_SEQ && x.body != null) { c.infer_ret(x.body, seen); }
        if (x.then_c != null) { c.infer_ret(x.then_c, seen); }
        if (x.else_c != null) { c.infer_ret(x.else_c, seen); }
        x = (x.tag == ACMD_SEQ) ? x.next : x.next;
    }
    return c.ret_seen;
}

// Record the type of every `let` binder before any body is walked.
//
// AIR's dominator spine binds at the point of domination and the text omits an
// operand's type when the binder already carries it -- `let n = a2 : i64 in ...
// (mul n _r8) : i64`. Walking in emit order, `mul n` is reached before `let n`,
// so the operand looked untyped and `binop` refused it. This pass makes the type
// of every binder known up front, for the same reason the declarations are
// hoisted: emit order is not definition order.
fn void Ctx.prescan_let(Ctx* c, AirCmd* x)
{
    // Diagnostics are suppressed for the duration: a type this pass cannot see is
    // not an error, it is a type the walk will resolve -- and reporting it here
    // both duplicates the message and points at the wrong pass.
    bool was = c.quiet; c.quiet = true;
    int guard = 0;
    while (x != null && guard++ < 1000000)
    {
        if (x.tag == ACMD_LET && x.binder != null && x.prd != null)
        {
            Val v = c.prd_ty(x.prd);
            if (v.ty != null && !c.has_type(x.binder)) { c.bind(x.binder, v.op, v.ty); }
        }
        if (x.tag == ACMD_SEQ && x.body != null) { c.prescan_let(x.body); }
        if (x.tag == ACMD_LETREC && x.body != null) { c.prescan_let(x.body); }
        if (x.then_c != null) { c.prescan_let(x.then_c); }
        if (x.else_c != null) { c.prescan_let(x.else_c); }
        // `cut` names its result with `comu <binder>`; without this the very next
        // instruction reads a binder the prescan never saw.
        if (x.tag == ACMD_CUT && x.cns != null)
        {
            AirCns* k = x.cns;
            while (k != null)
            {
                if (k.tag == ACNS_COMU && k.bind != null && k.ty != null && !c.has_type(k.bind)) { c.bind(k.bind, k.bind, k.ty); }
                if (k.tag == ACNS_CALL && k.bind != null && k.ty != null && !c.has_type(k.bind)) { c.bind(k.bind, k.bind, k.ty); }
                if (k.tag == ACNS_COMU && k.body != null) { c.prescan_let(k.body); }
                if (k.tag == ACNS_CALL && k.body != null) { c.prescan_let(k.body); }
                k = k.tail;
            }
        }
        x = x.next;
    }
    c.quiet = was;
}

// The type of `let x = <prd>`, where <prd> may itself be a bare var or a binop
// whose operands omit their type. Deliberately narrow: it answers with the
// prd's own annotation when there is one, else the binder type, else null.
fn Val Ctx.prd_ty(Ctx* c, AirPrd* p)
{
    Val v; v.op = (char*)"/*undef*/"; v.ty = null;
    if (p == null) { return v; }
    if (p.ty != null) { v.ty = p.ty; return v; }
    if (p.tag == APRD_VAR)
    {
        for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], p.name)) { v.ty = c.vv[i].ty; return v; } }
        AirDecl* d = c.find(p.name);
        if (d != null) { v.ty = d.ret_ty; }
        return v;
    }
    if (p.tag == APRD_BINOP)
    {
        Val a = c.prd_ty(p.sub_count > 0 ? p.subs[0] : null);
        Val b = c.prd_ty(p.sub_count > 1 ? p.subs[1] : null);
        if (a.ty != null && b.ty != null && air_util::ty_eq(a.ty, b.ty)) { v.ty = a.ty; }
        else if (a.ty != null && air_util::ty_is_int(a.ty) && b.ty != null && air_util::ty_is_int(b.ty)) { v.ty = a.ty; }
        return v;
    }
    if (p.tag == APRD_LOAD)
    {
        Val a = c.prd_ty(p.sub_count > 0 ? p.subs[0] : null);
        if (a.ty != null && a.ty.tag == ATYP_PTR) { v.ty = a.ty.args[0]; }
        return v;
    }
    if (p.tag == APRD_COERCE) { v.ty = p.ty; return v; }
    // sizeof yields usize, which is what makes `coerce(sizeof(i64), i64)` legal.
    if (p.tag == APRD_SIZEOF || p.tag == APRD_ALIGNOF || p.tag == APRD_OFFSETOF) { v.ty = c.m.t_usz; return v; }
    if (p.tag == APRD_GEP) { v.ty = p.ty; return v; }
    if (p.tag == APRD_ALLOCA) { v.ty = p.ty; return v; }
    if (p.tag == APRD_STRING || p.tag == APRD_BYTES) { v.ty = null; return v; }
    return v;
}

fn bool Ctx.has_type(Ctx* c, char* nm)
{
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { return c.vv[i].ty != null; } }
    return false;
}

fn void Ctx.function(Ctx* c, AirDecl* d, Sb* out)
{
    c.fn_name = d.name;
    c.nv = 0; c.nl = 0; c.tmp = 0;
    c.cur_ret = d.ret_ty;
    c.decls.n = 0; if (c.decls.d != null) { c.decls.d[0] = 0; }
    c.ndn = 0;
    c.ret_seen = null;
    AirTyp* rty = d.ret_ty;
    if (rty == null || rty.tag == ATYP_UNIT)
    {
        int seen = 0;
        AirTyp* was = c.ret_seen;
        AirTyp* inf = c.infer_ret(d.def_body, &seen);
        c.ret_seen = was;
        if (inf != null && seen > 0) { rty = inf; }
    }
    d.ret_ty = rty;
    c.cur_ret = rty;
    if (rty != null && !ty_low(rty, 0)) { c.err((char*)"return type is not part of the low profile", null); }

    // label spine: seq { label A c ; seq { label B c ; entry } }
    AirCmd* x = d.def_body;
    while (x != null && x.tag == ACMD_SEQ && x.body != null && x.body.tag == ACMD_LABEL)
    {
        c.add_label(x.body);
        x = x.next;
    }
    if (x != null && x.tag == ACMD_LABEL) { c.add_label(x); x = null; }
    // The tail is not junk. `label A c` binds A inside c (docs/specs/AIR.md, the
    // lambda-bar mu-mu-tilde reading), so the spine's innermost command is the
    // function's ENTRY: it allocates, initialises, and jumps to the first label.
    // Emitting the labels first made the first label the entry, which skipped
    // every binding the tail performs -- the loop-carried allocas among them.
    AirCmd* tail = x;

    for (usz i = 0; i < d.param_count; i++) { AirBinder* b = d.params[i]; if (b != null) { c.bind(b.name, b.name, b.ty); } }
    // Types of every binder in the body, before emitting a single instruction.
    c.prescan_let(d.def_body);

    bool is_main = air_text::streq(d.name, "main");
    bool wrap = is_main && (ty_is_void(d.ret_ty) || air_util::ty_is_int(d.ret_ty));

    // Every label parameter is a function-scope local, declared once (§3.2).
    // This MUST be a separate pass: a label's body may name a parameter of a
    // label emitted later (a `jump` forwards), and binding lazily while walking
    // reported those as unbound variables.
    for (usz i = 0; i < c.nl; i++)
    {
        Lbl* lp = &c.lbls[i];
        for (usz j = 0; j < lp.np; j++)
        {
            if (lp.params[j] == null) { continue; }
            if (lp.params[j].name == null) { continue; }
            c.decls.put((char*)"    ");
            c.ty_decl(&c.decls, lp.params[j].ty, lp.params[j].name);
            c.decls.put((char*)";\n");
            c.bind(lp.params[j].name, lp.params[j].name, lp.params[j].ty);
        }
    }

    Sb body; body.init();
    // The entry block first: C falls into it, and it is the command the spine's
    // tail would otherwise have silently dropped.
    if (tail != null)
    {
        c.cmd(tail, &body);
    }
    for (usz i = 0; i < c.nl; i++)
    {
        Lbl* lb = &c.lbls[i];
        // A label with no incoming jump is unreachable; Ctx accepts it but a
        // compiler warns, and an AIR function never has one. Still print it:
        // dropping a label silently would hide a producer bug.
        c.pad(&body); body.put((char*)"goto ");
        c.name(&body, lb.name, false); body.put((char*)";\n");
        c.name(&body, lb.name, false); body.put((char*)": {\n");
        c.cmd(lb.body, &body);
        c.pad(&body); body.put((char*)"}\n");
    }

    c.fn_attrs(d, out);            // the AIR facts, licensed to the Ctx compiler
    c.header(d, out, wrap);
    out.put((char*)"\n{\n");
    if (c.decls.d != null) { out.put(c.decls.d); }
    if (body.d != null) { out.put(body.d); }
    out.put((char*)"}\n\n");
    if (wrap)
    {
        // the C ABI entry point, the same wrapper air_ll emits (§4.5)
        // The AIR `main` takes whatever parameters the program declares (tokei's
        // takes argc/argv), so the C entry point must forward real ones -- a
        // wrapper that called `pride_main()` for a two-parameter main did not
        // compile at all.
        out.put((char*)"int main(int argc, char **argv)\n{\n");
        Sb al; al.init();
        for (usz i = 0; i < d.param_count; i++)
        {
            if (i > 0) { al.put((char*)", "); }
            // The AIR entry signature is the program's own; supply the C runtime's
            // argc/argv where the shapes line up and a zero otherwise.
            if (i == 0 && air_util::ty_is_int(d.params[i].ty)) { al.put((char*)"(int64_t)argc"); }
            else if (i == 1 && d.params[i].ty != null && d.params[i].ty.tag == ATYP_PTR) { al.put((char*)"((uint8_t *)argv)"); }
            else { al.put((char*)"0"); }
        }
        if (ty_is_void(d.ret_ty))
        {
            out.put((char*)"    pride_main("); out.put(al.take()); out.put((char*)(");\n    return 0;\n}\n\n"));
        }
        else
        {
            out.put((char*)"    return (int)pride_main("); out.put(al.take()); out.put((char*)(");\n}\n\n"));
        }
    }
}

// A function's locals are declared at function scope, so a name may be reached
// from several labels; `dn` is what makes the declaration happen exactly once.
fn bool Ctx.declared(Ctx* c, char* nm)
{
    if (nm == null) { return false; }
    for (usz i = 0; i < c.ndn; i++) { if (air_text::streq(c.dn[i], nm)) { return true; } }
    return false;
}

fn void Ctx.mark_declared(Ctx* c, char* nm)
{
    if (nm == null || c.ndn >= MAXV) { return; }
    c.dn[c.ndn] = nm; c.ndn++;
}

fn void Ctx.add_label(Ctx* c, AirCmd* lb)
{
    if (c.nl >= MAXL) { c.err((char*)"too many labels", lb.binder); return; }
    Lbl* l = &c.lbls[c.nl];
    l.name = lb.binder; l.np = lb.mbinder_count; l.body = lb.body;
    for (usz i = 0; i < lb.mbinder_count && i < 16; i++) { l.params[i] = lb.mbinders[i]; }
    c.nl++;
}

// A C struct body is written where the typedef is, so a type must be defined
// before any type that embeds it -- `typedef struct String { RawVec buf; }`
// cannot precede `typedef struct RawVec {...}`. AIR's module order carries no
// such promise (tokei's model.pie declares String before RawVec), so the typedefs
// are emitted in dependency order: every type a struct mentions comes first.
fn bool typ_mentions(AirTyp* t, char* nm, int depth)
{
    if (t == null || depth > 12) { return false; }
    if (t.tag == ATYP_NOMINAL && t.name != null && air_text::streq(t.name, nm)) { return true; }
    for (usz i = 0; i < t.arg_count; i++) { if (typ_mentions(t.args[i], nm, depth + 1)) { return true; } }
    return false;
}

fn bool data_mentions(AirDecl* d, char* nm)
{
    if (d == null || d.ctor_count < 1 || d.ctors[0] == null) { return false; }
    AirCtorDecl* ct = d.ctors[0];
    for (usz j = 0; j < ct.field_count; j++) { if (typ_mentions(ct.fields[j].ty, nm, 0)) { return true; } }
    return false;
}

// A tuple has no `data` declaration in AIR -- air_low synthesizes the type, so
// nothing tells the emitter to define it, and `struct __tup_i64_i64` was used as a
// value type with no definition anywhere ("initializer but incomplete type").
// Define each distinct shape the first time it is written, members deepest-first
// so a tuple of tuples is complete before the tuple that holds it.
fn void Ctx.tuple_defs(Ctx* c, AirTyp* t, int depth)
{
    if (t == null || depth > 8) { return; }
    for (usz i = 0; i < t.arg_count; i++) { c.tuple_defs(t.args[i], depth + 1); }
    if (t.tag != ATYP_TUPLE) { return; }
    Sb nm; nm.init(); c.ty(&nm, t);
    char* name = nm.take();
    for (usz i = 0; i < c.ntup; i++) { if (air_text::streq(c.tup[i], name)) { return; } }
    if (c.ntup >= 512) { return; }
    c.tup[c.ntup] = name; c.ntup++;
    if (t.arg_count == 0) { return; }
    // `ty()` writes `struct __tup_...`, so the definition needs the whole name.
    c.types_out.put(name); c.types_out.put((char*)" {\n");
    for (usz i = 0; i < t.arg_count; i++)
    {
        c.types_out.put((char*)"    ");
        // The gep path writes `-` followed by the literal index, so the member
        // is `_N`; naming these `fN` made every tuple projection a missing field.
        char[16] mn; mn[0] = '_';
        usz di = 1; usz v = i;
        if (v == 0) { mn[di] = '0'; di = di + 1; }
        char[8] dg; usz dl = 0;
        while (v > 0) { dg[dl] = (char)('0' + (char)(v % 10)); dl = dl + 1; v = v / 10; }
        usz k = dl; while (k > 0) { k = k - 1; mn[di] = dg[k]; di = di + 1; }
        mn[di] = 0;
        c.declarator(&c.types_out, t.args[i], &mn[0]);
        c.types_out.put((char*)";\n");
    }
    c.types_out.put((char*)"};\n\n");
}

fn void Ctx.data_type(Ctx* c, AirDecl* d, Sb* o)
{
    if (d.ctor_count != 1) { c.err((char*)"data with several constructors (enum layout) is not part of this profile yet", d.name); return; }
    if (d.typaram_count > 0) { c.err((char*)"generic data is not part of the low profile", d.name); return; }
    if (decl_has_attr(d, "packed")) { o.put((char*)"PRIDE_PACKED "); }
    o.put((char*)"typedef struct "); c.name(o, d.name, false); o.put((char*)" {\n");
    AirCtorDecl* ct = d.ctors[0];
    for (usz j = 0; j < ct.field_count; j++)
    {
        o.put((char*)"    ");
        if (!ty_low(ct.fields[j].ty, 0)) { c.err((char*)"field type is not part of the low profile", ct.fields[j].name); }
        c.ty_decl(o, ct.fields[j].ty, ct.fields[j].name);
        o.put((char*)";\n");
    }
    if (ct.field_count == 0) { o.put((char*)"    char __unit;\n"); }
    // `typedef struct P {...} P;` -- without the second name there is no plain `P`
    // in scope, and C has no implicit tag-to-type conversion.
    o.put((char*)"} "); c.name(o, d.name, false); o.put((char*)" ;\n\n");
}

fn void Ctx.global_decl(Ctx* c, AirDecl* d, Sb* o)
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

// Names the emitter's own includes already declare. A short, deliberate list:
// every entry is provided by the prelude's standard headers, and a name NOT on
// it is declared exactly as AIR asks. Redeclaring one of these is not harmless:
// C rejects a second, differently-typed declaration of one function, and AIR's
// `u64` and glibc's `size_t` are the same width but not the same type to a
// redeclaration.
fn bool libc_declares(char* nm)
{
    if (nm == null) { return false; }
    // ONLY <string.h>: that is the one header the prelude includes besides
    // <stdint.h>/<stdbool.h>/<stdatomic.h>, and none of those declare a function.
    // Listing `printf` here without including <stdio.h> left every call to an
    // undeclared function -- the skip and the include have to agree.
    static char*[8] names = { "strlen", "strcmp", "strncmp", "memcpy", "memmove", "memset", "strchr", "strcpy" };
    for (usz i = 0; i < 8; i++) { if (air_text::streq(names[i], nm)) { return true; } }
    return false;
}

fn void Ctx.declare(Ctx* c, AirDecl* d, Sb* o)
{
    c.fn_attrs(d, o);
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
        // `_` is AIR's anonymous binder. Two of them in one C parameter list is
        // a redeclaration, so each gets its own positional spelling.
        char* pn = b.name;
        if (pn == null || (pn[0] == '_' && pn[1] == 0))
        {
            char[16] anon;
            anon[0] = '_'; anon[1] = '_'; anon[2] = 'p';
            usz nd = 0; usz iv = wrote / 10;
            if (iv > 0) { nd = 1; }
            char[8] dig; usz dl = 0; usz v = wrote;
            if (v == 0) { dig[dl] = '0'; dl = 1; }
            while (v > 0) { dig[dl] = (char)('0' + (char)(v % 10)); dl = dl + 1; v = v / 10; }
            usz ai = 3;
            usz k = dl; while (k > 0) { k = k - 1; anon[ai] = dig[k]; ai = ai + 1; }
            anon[ai] = 0;
            pn = &anon[0];
            c.ty_decl(o, b.ty, pn);
        }
        else { c.ty_decl(o, b.ty, pn); }
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
fn void Ctx.prelude(Ctx* c, Sb* o)
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
    Ctx* c = (Ctx*)malloc(Ctx::size);
    c.m = m; c.errs = 0; c.fn_name = null; c.emit = want_text; c.quiet = false;
    c.vn = (char**)malloc(8 * MAXV); c.vv = (Val*)malloc(Val::size * MAXV);
    c.dn = (char**)malloc(8 * MAXV); c.ndn = 0;
    c.tup = (char**)malloc(8 * 512); c.ntup = 0;
    c.lbls = (Lbl*)malloc(Lbl::size * MAXL);
    c.nv = 0; c.nl = 0; c.tmp = 0; c.nstr = 0;
    c.decls.init(); c.types_out.init(); c.pre.init();

    Sb body; body.init();
    // Dependency order (see typ_mentions). `done` records what has been written;
    // a cycle would leave a gap, and a gap is reported rather than emitted as a
    // struct that refers to a name C does not have yet.
    bool[4096] data_done;
    for (usz i = 0; i < 4096; i++) { data_done[i] = false; }
    usz total_data = 0;
    for (usz i = 0; i < m.decl_count; i++) { AirDecl* d = m.decls[i]; if (d != null && d.tag == ADECL_DATA) { total_data++; } }
    for (usz pass = 0; pass <= total_data; pass++)
    {
        bool progress = false;
        for (usz i = 0; i < m.decl_count && i < 4096; i++)
        {
            AirDecl* d = m.decls[i];
            if (d == null || d.tag != ADECL_DATA || data_done[i]) { continue; }
            bool ready = true;
            for (usz j = 0; j < m.decl_count && j < 4096; j++)
            {
                AirDecl* e = m.decls[j];
                if (e == null || e.tag != ADECL_DATA || j == i || data_done[j]) { continue; }
                if (data_mentions(d, e.name)) { ready = false; break; }
            }
            if (!ready) { continue; }
            c.fn_name = d.name;
            c.data_type(d, &c.types_out);
            c.fn_name = null;
            data_done[i] = true; progress = true;
        }
        if (!progress) { break; }
    }
    for (usz i = 0; i < m.decl_count && i < 4096; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null || d.tag != ADECL_DATA || data_done[i]) { continue; }
        c.fn_name = d.name;
        c.data_type(d, &c.types_out);
        c.err((char*)"data type is part of a dependency cycle; emitted last", d.name);
        c.fn_name = null;
    }
    // Extern declarations first: a call to a library function may appear in the
    // very first body (tokei's `main` printf's immediately), while its `declare`
    // sits wherever the module happened to put it. C requires the declaration
    // before the call.
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null || d.tag != ADECL_DECLARE) { continue; }
        bool defd = false;
        for (usz j = 0; j < m.decl_count; j++) { AirDecl* e = m.decls[j]; if (e != null && e.tag == ADECL_DEF && air_text::streq(e.name, d.name)) { defd = true; } }
        if (defd) { continue; }
        // A name this C library already declares is NOT redeclared here. glibc's
        // `strlen` returns `size_t` where AIR says `u64`: the same width spelled
        // through a different typedef, which C treats as a conflicting type. The
        // include is emitted for exactly this purpose, and the AIR type still
        // governs every call the emitter writes.
        if (libc_declares(d.name)) { continue; }
        c.fn_name = d.name;
        c.declare(d, &c.pre);
        c.fn_name = null;
    }

    // One prototype per definition, BEFORE the bodies: a program's `main` is
    // usually first in the module while the functions it calls come after it,
    // and C without a prototype assumes `int f()` -- or refuses outright.
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null || d.tag != ADECL_DEF) { continue; }
        if (d.ret_ty == null || d.ret_ty.tag == ATYP_UNIT)
        {
            // infer_ret reads rets, whose operands carry no type of their own in
            // the text (`ret(_r2)`), so it needs the program's binder types --
            // the same prescan the body walk uses, run here for the same reason.
            int seen = 0;
            c.nv = 0; c.ret_seen = null;
            for (usz pi = 0; pi < d.param_count; pi++) { AirBinder* b = d.params[pi]; if (b != null) { c.bind(b.name, b.name, b.ty); } }
            c.prescan_let(d.def_body);
            AirTyp* inf = c.infer_ret(d.def_body, &seen);
            c.ret_seen = null; c.nv = 0;
            if (inf != null) { d.ret_ty = inf; }
        }
        c.fn_name = d.name;
        c.decls.n = 0;
        c.tuple_defs(d.ret_ty, 0);
        for (usz pi = 0; pi < d.param_count; pi++) { if (d.params[pi] != null) { c.tuple_defs(d.params[pi].ty, 0); } }
        if (!air_text::streq(d.name, "main")) { c.header(d, &c.pre, false); }
        else { c.header(d, &c.pre, true); }
        c.pre.put((char*)";\n");
        c.fn_name = null;
    }
    c.pre.put((char*)"\n");

    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        switch (d.tag)
        {
            case ADECL_GLOBAL: c.fn_name = d.name; c.global_decl(d, &body); c.fn_name = null; break;
            case ADECL_DECLARE:
            {
                bool defd = false;
                for (usz j = 0; j < m.decl_count; j++) { AirDecl* e = m.decls[j]; if (e != null && e.tag == ADECL_DEF && air_text::streq(e.name, d.name)) { defd = true; } }
                // Already emitted by the hoisting pass above (and skipped there
                // when the C library declares the name). Emitting again here put
                // glibc's strcmp/strlen back into the file with AIR's types.
                // Every declare was emitted by the hoisting pass, which is the
                // only place that applies the libc rule. Re-emitting here put
                // glibc's strcmp/strlen back with AIR's types.
                if (defd) { break; }
                break;
            }
            case ADECL_DEF: c.function(d, &body); break;
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
