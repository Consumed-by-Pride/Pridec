// ============================================================================
// air_c3.c3 -- a consumer of the AIR 3.0 low profile: .air -> C3 source text.
//
// The second complete consumer of the low profile. air_ll.c3 (AIR -> LLVM text)
// is the first; the two walk the same module with the same typing rules
// (docs/specs/AIR3.md, "Typing") and differ only in what they print. Accepting a
// module air_ll refuses would mean one of them is wrong about what the low
// profile is, so the two must agree on every tag.
//
// C3 is a TRANSPILATION TARGET here (docs/pear2/C3_TARGET.md §1), not the
// implementation language of the compiler hosting this file. The mapping
// implemented below is that document's §4, row for row.
//
// The hard part is not the mapping, it is control flow: AIR 3.0 is a CFG with
// label-parameter (phi) joins and C3 has NO goto. The strategy (same document,
// §3) is PIR's argument from pear2/pear2_cfg.c3 applied to C3:
//
//   1. every label parameter becomes a C3 variable declared at the top of the
//      function, and every jump assigns them -- always correct;
//   2. three CFG shapes are printed structurally so the text stays readable:
//        PLAIN    a label with no back edge: its body, then fall through
//        TAIL     a label whose body ends in a single jump to a label that the
//                 very next label also jumps to: print as an if/else
//        LOOP     a label that is the target of a back edge: while (true)
//   3. anything else is driven by one `while (true) { switch (__pc) { .. } }`
//      using C3's `nextcase <expr>`, which selects a case by run-time value.
//      That is the last resort and it is COUNTED and PRINTED, never silent.
//
// Like air_ll, anything outside the low profile is an error naming the construct
// and the function. Nothing is ever compiled to a form the AIR did not ask for.
// ============================================================================
module air_c3;
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
const usz MAXL = 4096;      // labels (blocks) per function
const usz MAXS = 8192;      // string literals per module

// ── C3 vocabulary, checked against c3c v0.8.4 ─────────────────────────────
// The Makefile pins C3C_VER := v0.8.4 and the emitter cannot compile itself, so
// the names below are taken from that tag's src/compiler/tokens.c rather than
// from memory or from the current docs. The three that would have been wrong:
// `sz` is the signed pointer-width type (`isz` is not a keyword), `tlocal` is
// thread-local storage (not `tls`), and there is no 128-bit integer keyword.
// C3 has NO quoted-identifier escape (`@"name"` is AIR's syntax, not C3's), so
// an AIR name that is not a legal C3 identifier is refused rather than mangled.
fn bool c3_keyword(char* s)
{
    static char*[69] kw = {
        "_", "alias", "any", "asm", "assert", "attrdef", "attrmacro", "bitstruct",
        "bool", "break", "case", "catch", "cenum", "char", "const", "constdef",
        "constset", "continue", "default", "defer", "distinct", "do", "double",
        "else", "enum", "extern", "false", "fault", "faultdef", "faultset", "float",
        "fn", "for", "foreach", "foreach_r", "ichar", "if", "import", "inline",
        "int", "interface", "iptr", "lengthof", "long", "macro", "module",
        "nextcase", "null", "return", "short", "static", "struct", "switch", "sz",
        "tlocal", "true", "try", "typedef", "typeid", "uint", "ulong", "union",
        "untypedlist", "uptr", "ushort", "usz", "var", "void", "while"
    };
    if (s == null) { return false; }
    for (usz i = 0; i < 69; i++) { if (air_text::streq(kw[i], s)) { return true; } }
    return false;
}

fn bool c3_ident_ok(char* s)
{
    if (s == null || s[0] == 0) { return false; }
    char c0 = s[0];
    if (!(c0 == '_' || (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z'))) { return false; }
    usz i = 0;
    while (s[i] != 0)
    {
        char ch = s[i];
        if (!(ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))) { return false; }
        i++;
    }
    return !c3_keyword(s);
}

// ── types ──────────────────────────────────────────────────────────────────
// A property of the profile, not of a printer; the identical predicate is in
// air_ll.c3 and in the tests that assert the two consumers agree.
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
        case APRD_VAR: return (char*)"var"; case APRD_CON: return (char*)"con";
        case APRD_INT: return (char*)"int"; case APRD_FLOAT: return (char*)"float";
        case APRD_BOOL: return (char*)"bool"; case APRD_CHAR: return (char*)"char";
        case APRD_STRING: return (char*)"string"; case APRD_BYTES: return (char*)"bytes";
        case APRD_UNIT: return (char*)"unit"; case APRD_NULL: return (char*)"null";
        case APRD_TUPLE: return (char*)"tuple"; case APRD_RECORD: return (char*)"record";
        case APRD_ARRAY: return (char*)"array"; case APRD_INL: return (char*)"inl";
        case APRD_INR: return (char*)"inr"; case APRD_LAMBDA: return (char*)"lambda";
        case APRD_MU: return (char*)"mu"; case APRD_COMETA: return (char*)"cometa";
        case APRD_BINOP: return (char*)"binop"; case APRD_UNOP: return (char*)"unop";
        case APRD_COERCE: return (char*)"coerce"; case APRD_SIZEOF: return (char*)"sizeof";
        case APRD_ALIGNOF: return (char*)"alignof"; case APRD_OFFSETOF: return (char*)"offsetof";
        case APRD_REIFY: return (char*)"reify"; case APRD_EVAL: return (char*)"eval";
        case APRD_QUOTE: return (char*)"quote"; case APRD_SPLICE: return (char*)"splice";
        case APRD_POISON: return (char*)"poison"; case APRD_UNREACHABLE_VAL: return (char*)"unreachable";
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

// The lowercase spelling of a type, used to derive a stable struct name for a
// tuple shape. Independent of AirTypTag numbering on purpose.
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

// One AIR label on the spine of a def body: `seq { label A. c ; ... entry }`.
struct Lbl
{
    char*      name;
    AirBinder*[16] params; usz np;
    AirCmd*    body;
    usz        n_pred;      // incoming jumps, counted before printing
    bool       back_edge;   // a jump to it is reachable from inside it
    bool       is_entry;
}

// One jump edge, so a phi can be printed as the assignment a jump makes.
struct Edge { usz to; char*[16] args; usz nargs; }

struct C3
{
    AirModule* m;
    int        errs;
    char*      fn_name;
    bool       emit;
    usz        dispatch_fns;    // functions that needed the __pc fallback

    // per function
    char**     vn; Val* vv; usz nv;
    Lbl*       lbls; usz nl; usz cur;
    Edge*      edges; usz ne;
    bool       driven;           // this function is printed as a __pc dispatch loop
    Sb         locals;           // hoisted declarations
    usz        tmp;
    AirTyp*    cur_ret;
    usz        ind;

    // module level
    Sb         types_out;
    Sb         pre;
    usz        nstr;
}

fn void C3.err(C3* c, char* what, char* who)
{
    c.errs++;
    void* se = fdopen(2, "w");
    if (c.errs <= 12) { fprintf(se, "air-c3: in `%s`: %s%s%s\n", c.fn_name == null ? (char*)"<module>" : c.fn_name, what, who == null ? (char*)"" : (char*)": ", who == null ? (char*)"" : who); }
    fflush(se);
}

fn AirDecl* C3.find(C3* c, char* nm)
{
    if (nm == null) { return null; }
    for (usz i = 0; i < c.m.decl_count; i++)
    {
        AirDecl* d = c.m.decls[i];
        if (d != null && d.name != null && d.tag != ADECL_MODULE && air_text::streq(d.name, nm)) { return d; }
    }
    return null;
}

fn AirDecl* C3.find_data(C3* c, char* nm)
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

fn void C3.bind(C3* c, char* nm, char* op, AirTyp* ty)
{
    if (nm == null) { return; }
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { c.vv[i].op = op; c.vv[i].ty = ty; return; } }
    if (c.nv >= MAXV) { c.err((char*)"too many names", nm); return; }
    c.vn[c.nv] = nm; c.vv[c.nv].op = op; c.vv[c.nv].ty = ty; c.nv++;
}

fn bool C3.lookup(C3* c, char* nm, Val* out)
{
    for (usz i = 0; i < c.nv; i++) { if (air_text::streq(c.vn[i], nm)) { *out = c.vv[i]; return true; } }
    return false;
}

fn char* C3.fresh(C3* c)
{
    Sb s; s.init(); s.put((char*)"_t"); s.int_((long)c.tmp); c.tmp++;
    return s.take();
}

// An AIR name as a C3 identifier. Every emitted name goes through here, so an
// unrepresentable name is reported once, at the place it is used, instead of
// producing a .c3 file that does not parse.
fn void C3.name(C3* c, Sb* o, char* nm, bool qualified)
{
    if (!c3_ident_ok(nm)) { c.err((char*)"name is not a legal C3 identifier", nm); o.put((char*)"__bad_name"); return; }
    if (qualified) { o.put((char*)"pear_out::"); }
    o.put(nm);
}

fn void C3.ty(C3* c, Sb* o, AirTyp* t)
{
    if (t == null) { c.err((char*)"missing type", null); o.put((char*)"long"); return; }
    switch (t.tag)
    {
        // C3's sized integers are the same distinctions AIR makes, which is the
        // reason a C target would need a partner header and this does not.
        case ATYP_I8: o.put((char*)"ichar"); return;
        case ATYP_I16: o.put((char*)"short"); return;
        case ATYP_I32: o.put((char*)"int"); return;
        case ATYP_I64: o.put((char*)"long"); return;
        case ATYP_U8: o.put((char*)"char"); return;      // C3 `char` is unsigned
        case ATYP_U16: o.put((char*)"ushort"); return;
        case ATYP_U32: o.put((char*)"uint"); return;
        case ATYP_U64: o.put((char*)"ulong"); return;
        case ATYP_ISZ: o.put((char*)"sz"); return;       // NOT `isz`: no such keyword
        case ATYP_USZ: o.put((char*)"usz"); return;
        case ATYP_F32: o.put((char*)"float"); return;
        case ATYP_F64: o.put((char*)"double"); return;
        case ATYP_BOOL: o.put((char*)"bool"); return;
        // AIR `char` is a code point; air_ll prints it i32 and air_util counts it
        // as an integer. C3's `char` is a byte, so this must be `uint`.
        case ATYP_CHAR: o.put((char*)"uint"); return;
        case ATYP_UNIT: case ATYP_BOTTOM: o.put((char*)"void"); return;
        case ATYP_PTR:
        {
            if (t.arg_count == 0 || t.args[0] == null) { c.err((char*)"pointer without a pointee", null); o.put((char*)"void*"); return; }
            c.ty(o, t.args[0]); o.putc('*'); return;
        }
        case ATYP_ARRAY:
        {
            if (t.arg_count == 0 || t.args[0] == null) { c.err((char*)"array without an element type", null); o.put((char*)"char[]"); return; }
            c.ty(o, t.args[0]); o.putc('['); o.int_(t.ival); o.putc(']'); return;
        }
        case ATYP_TUPLE:
        {
            // No C3 type a field index can address, so each distinct shape gets
            // one generated struct. The name is derived from the shape so two
            // modules emitting the same tuple agree on it.
            o.put((char*)"__tup");
            for (usz i = 0; i < t.arg_count; i++)
            {
                AirTyp* a = t.args[i];
                o.putc('_'); o.put(ty_slug(a));
                if (a != null) { if (a.tag == ATYP_ARRAY) { o.int_(a.ival); } }
                if (a != null && a.arg_count > 0) { o.putc('x'); o.int_((long)a.arg_count); }
            }
            return;
        }
        case ATYP_ARROW:
        {
            // A raw code pointer (a `declare`, an `ind.clo` adapter result, an
            // extern). AIR 3.0 function values are {fn, env} records; those are
            // ordinary nominal types and never reach this case.
            // AIR arrows are `domain -> codomain`: args[0] is the DOMAIN (which is
            // a tuple of the parameter types) and args[1] is the result. Checked
            // against air_emit.c3's ATYP_ARROW printer, which writes
            // `emit_typ(args[0]); " -> "; emit_typ(args[1])`. An earlier draft of
            // this file had the two reversed.
            o.put((char*)"fn ");
            AirTyp* dom = t.arg_count > 0 ? t.args[0] : null;
            AirTyp* cod = t.arg_count > 1 ? t.args[1] : null;
            if (cod == null || cod.tag == ATYP_UNIT) { o.put((char*)"void"); } else { c.ty(o, cod); }
            o.putc('(');
            bool wrote = false;
            usz nargs = (dom != null && dom.tag == ATYP_TUPLE) ? dom.arg_count : 1;
            for (usz i = 0; i < nargs; i++)
            {
                AirTyp* a = (dom != null && dom.tag == ATYP_TUPLE) ? dom.args[i] : dom;
                if (a == null) { continue; }
                if (wrote) { o.put((char*)", "); }
                c.ty(o, a); o.putc('*'); wrote = true;
            }
            o.putc(')');
            return;
        }
        case ATYP_NOMINAL: c.name(o, t.name, false); return;
        default:
            c.err((char*)"type is not part of the low profile", air_text::typ_kw(t.tag));
            o.put((char*)"long"); return;
    }
}

fn void C3.ty_decl(C3* c, Sb* o, AirTyp* t, char* nm)
{
    c.ty(o, t); o.putc(' '); c.name(o, nm, false);
}

fn bool ty_is_void(AirTyp* t) { return t == null || t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM; }

// ── producers ──────────────────────────────────────────────────────────────
fn char* C3.str_const(C3* c, AirPrd* p)
{
    Sb nm; nm.init(); nm.put((char*)"__s"); nm.int_((long)c.nstr);
    char* name = nm.take();
    c.nstr++;
    Sb* o = &c.pre;
    o.put((char*)"const char[] ");
    c.name(o, name, false);
    o.put((char*)" = \"");
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

// A C3 literal for a constant producer. Integers carry the suffix of their AIR
// type: an unsuffixed literal in C3 is `int`, which would narrow at i64.
fn void C3.scalar(C3* c, Sb* o, AirPrd* p, AirTyp* typed)
{
    switch (p.tag)
    {
        case APRD_INT:
        {
            o.int_(p.ival);
            AirTyp* t = p.ty != null ? p.ty : typed;
            if (t == null) { c.err((char*)"integer literal without a type", null); return; }
            if (!air_util::ty_is_int(t)) { c.err((char*)"integer literal without an integer type", null); return; }
            switch (t.tag)
            {
                case ATYP_I8: o.put((char*)"i8"); break;
                case ATYP_I16: o.put((char*)"i16"); break;
                case ATYP_I32: o.put((char*)"i32"); break;
                case ATYP_U8: o.put((char*)"u8"); break;
                case ATYP_U16: o.put((char*)"u16"); break;
                case ATYP_U32: o.put((char*)"u32"); break;
                case ATYP_U64: o.put((char*)"u64"); break;
                case ATYP_USZ: o.put((char*)"usz"); break;
                case ATYP_ISZ: o.put((char*)"sz"); break;
                default: break;     // i64: `long` width is the default for a written literal; ATYP_CHAR: a plain number
            }
            return;
        }
        case APRD_FLOAT:
        {
            AirTyp* t = p.ty != null ? p.ty : typed;
            if (!air_util::ty_is_float(t)) { c.err((char*)"float literal without a float type", null); return; }
            // 17 significant digits round-trip an IEEE double exactly and 9 do
            // the same for a float, so the emitted literal is the same value the
            // AIR carries -- not a re-rounded decimal. printf's own conversion is
            // used rather than a hand-written formatter, and rather than a
            // bitcast intrinsic whose C3 spelling cannot be checked here.
            char[64] buf;
            double dv = p.fval;
            int n = (t.tag == ATYP_F32)
                ? snprintf(&buf[0], 64, "%.9g", (double)dv)
                : snprintf(&buf[0], 64, "%.17g", dv);
            if (n <= 0 || n >= 64) { c.err((char*)"float literal did not format", null); return; }
            o.put(&buf[0]);
            if (t.tag == ATYP_F32) { o.putc('f'); }
            // A value printf writes as inf/nan cannot be read back as a decimal
            // literal; AIR does not promise them and guessing a spelling would
            // be inventing syntax, so this is refused by name. A finite literal
            // always starts with a digit, a sign, or a decimal point.
            char f0 = buf[0];
            if (f0 != '-' && f0 != '+' && f0 != '.' && (f0 < '0' || f0 > '9'))
            { c.err((char*)"non-finite float literal has no verified C3 spelling", null); }
            return;
        }
        case APRD_BOOL: o.put(p.bval ? (char*)"true" : (char*)"false"); return;
        case APRD_CHAR: o.put((char*)"(uint)"); o.int_(p.ival); return;
        case APRD_NULL: o.put((char*)"null"); return;
        default: c.err((char*)"not a scalar constant", prd_tag_name(p.tag)); return;
    }
}

fn Val C3.prd(C3* c, AirPrd* p)
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
                Sb s; s.init(); c.name(&s, p.name, true); v.op = s.take(); v.ty = d.ret_ty; return v;
            }
            // A label parameter read before any jump assigned it is a phi with
            // no incoming value here; the AIR verifier owns that, so reaching
            // this means the module was printed without being verified.
            c.err((char*)"unbound variable", p.name); return v;
        }
        case APRD_INT: case APRD_FLOAT: case APRD_BOOL: case APRD_CHAR: case APRD_NULL:
        {
            Sb s; s.init(); c.scalar(&s, p, p.ty); v.op = s.take(); v.ty = p.ty; return v;
        }
        case APRD_UNIT: v.ty = p.ty; v.op = (char*)"/*unit*/"; return v;
        case APRD_STRING: case APRD_BYTES: v.ty = p.ty; v.op = c.str_const(c, p); return v;
        case APRD_BINOP:  return c.binop(c, p);
        case APRD_UNOP:   return c.unop(c, p);
        case APRD_COERCE: return c.coerce(c, p);
        case APRD_ALLOCA:
        {
            if (!ty_low(p.ty_arg, 0)) { c.err((char*)"alloca of a non-low type", null); }
            char* t = c.fresh();
            // Hoisted to the top of the function so that a slot addressed on two
            // paths has exactly one declaration. docs/pear2/C3_TARGET.md §3.4
            // refuses an alloca whose slot would escape its iteration.
            c.locals.put((char*)"    ");
            c.ty_decl(c, &c.locals, p.ty_arg, t);
            c.locals.put((char*)"\n");
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
            if (p.bval) { s.put((char*)"volatile_load("); s.put(a.op); s.putc(')'); }
            else { s.putc('*'); s.put(a.op); }
            v.op = s.take(); v.ty = et; return v;
        }
        case APRD_GEP: return c.gep(c, p);
        case APRD_TUPLE: case APRD_RECORD: case APRD_ARRAY: return c.aggregate(c, p);
        case APRD_SIZEOF:
        {
            Sb s; s.init(); s.put((char*)"(usz)("); c.ty(&s, p.ty); s.put((char*)").sizeof");
            v.op = s.take(); v.ty = c.m.t_usz; return v;
        }
        default:
            c.err((char*)"producer is not part of the low profile", prd_tag_name(p.tag)); return v;
    }
}

// The field at index `ix` of an aggregate type, following the same walk air_ll's
// Ll.gep does, so the two consumers cannot disagree about layout.
fn bool field_at(C3* c, AirTyp* cur, long ix, AirTyp** out)
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

fn Val C3.gep(C3* c, AirPrd* p)
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

    Sb acc; acc.init();
    AirTyp* step = cur;
    if (p.sub_count <= 1) { acc.put(b.op); }
    else
    {
        acc.putc('('); acc.put(b.op); acc.put((char*)" + "); acc.put(idx[1].op); acc.putc(')');
        for (usz i = 2; i < p.sub_count && i < 16; i++)
        {
            if (step == null) { c.err((char*)"gep indexes past a scalar", null); break; }
            if (step.tag == ATYP_ARRAY)
            {
                acc.putc('['); acc.put(idx[i].op); acc.putc(']');
                // a step through an array of arrays keeps the element type
                step = step.args[0];
                continue;
            }
            if (step.tag == ATYP_TUPLE || step.tag == ATYP_NOMINAL)
            {
                AirPrd* ip = p.subs[i];
                if (ip == null || ip.tag != APRD_INT) { c.err((char*)"struct gep index must be a literal", null); break; }
                AirTyp* ft = null;
                if (!field_at(c, step, ip.ival, &ft)) { c.err((char*)"gep index outside the aggregate", null); break; }
                acc.putc('.');
                if (step.tag == ATYP_TUPLE) { acc.putc('_'); acc.int_(ip.ival); }
                else
                {
                    AirDecl* dd = c.find_data(step.name);
                    c.name(&acc, dd.ctors[0].fields[(usz)ip.ival].name, false);
                }
                step = ft;
                continue;
            }
            c.err((char*)"gep indexes into a type with no members", null); break;
        }
    }
    Sb s; s.init(); s.putc('&'); s.put(acc.take());
    v.op = s.take();
    // The printed pointer is a real C3 pointer, so its type is the pointee the
    // walk landed on -- which is what AIR's own annotation must already be.
    if (step == null) { v.ty = null; }
    else { v.ty = p.ty != null ? p.ty : c.mk_ptr_to(c, step); }
    return v;
}

// A synthesized ptr(T) for a gep result. Every field is set explicitly: a struct
// assignment from a dereference (`*p = *q`) is not used anywhere else in this
// tree, and an emitter that cannot be compiled here has no business relying on a
// form it has not seen.
fn AirTyp* C3.mk_ptr_to(C3* c, AirTyp* t)
{
    AirTyp* p = (AirTyp*)malloc(AirTyp::size);
    p.id = 0; p.tag = ATYP_PTR;
    p.args[0] = t; p.arg_count = 1;
    for (usz i = 1; i < 64; i++) { p.args[i] = null; }
    p.name = null; p.mult = AMULT_UNR; p.mult_exact = 0;
    p.ival = 0; p.fval = 0.0;
    p.rec_field_count = 0;
    p.eff_tail = null; p.eff_name = null; p.refine_extra = null;
    return p;
}

fn Val C3.aggregate(C3* c, AirPrd* p)
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
    Sb s; s.init();
    c.ty(&s, p.ty);
    s.put((char*)"{ ");
    for (usz i = 0; i < n; i++)
    {
        if (i > 0) { s.put((char*)", "); }
        if (p.tag == APRD_RECORD) { s.putc('.'); c.name(&s, p.rec_inits[i].name, false); s.put((char*)" = "); }
        else if (p.tag == APRD_TUPLE) { s.putc('.'); s.putc('_'); s.int_((long)i); s.put((char*)" = "); }
        s.put(parts[i].op);
    }
    s.put((char*)" }");
    v.op = s.take();
    return v;
}

fn Val C3.binop(C3* c, AirPrd* p)
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

fn Val C3.unop(C3* c, AirPrd* p)
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
    Sb s; s.init(); s.putc('('); s.put(opn); s.put(a.op); s.putc(')');
    v.op = s.take(); v.ty = a.ty;
    if (p.ty != null && !air_util::ty_eq(p.ty, v.ty)) { c.err((char*)"operation annotation differs from the computed type", null); }
    return v;
}

fn Val C3.coerce(C3* c, AirPrd* p)
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
    // Every conversion air_ll needs a distinct opcode for (`sitofp`, `zext`,
    // `trunc`, `ptrtoint`, `inttoptr`) is one C3 cast: C3 picks the signed or
    // unsigned path from the source type, which is exactly what AIR means.
    Sb t; t.init(); t.putc('('); c.ty(&t, to); t.putc(')'); t.putc('('); t.put(a.op); t.putc(')');
    v.op = t.take();
    return v;
}

// ── statements ─────────────────────────────────────────────────────────────
fn void C3.pad(C3* c, Sb* o) { for (usz i = 0; i < c.ind; i++) { o.putc(' '); } }

fn void C3.stmt_ret(C3* c, Sb* o, AirPrd* p)
{
    c.pad(c, o);
    if (ty_is_void(c.cur_ret))
    {
        if (p != null)
        {
            Val v = c.prd(p);
            if (v.ty != null && !ty_is_void(v.ty)) { c.err((char*)"ret of a value in a unit function", null); }
        }
        o.put((char*)"return;"); o.putc('\n');
        return;
    }
    Val v = c.prd(p);
    if (v.ty != null && !air_util::ty_eq(v.ty, c.cur_ret)) { c.err((char*)"ret value type differs from the function's return type", null); }
    o.put((char*)"return "); o.put(v.op); o.put((char*)";"); o.putc('\n');
}

fn void C3.call(C3* c, AirPrd* callee, AirCns* k, AirCmd** next_out, Sb* o)
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
    s.put(f.op); s.putc('(');
    for (usz i = 0; i < na; i++) { if (i > 0) { s.put((char*)", "); } s.put(args[i].op); }
    s.put((char*)")"); s.putc(';'); s.putc('\n');
    o.put(s.take());
    if (cur.bind != null) { c.bind(cur.bind, cur.bind, cur.ty); }
    *next_out = cur.body;
}

fn char* atomic_order_c3(int ord)
{
    switch (ord)
    {
        case 1: return (char*)"MemoryOrder.ACQUIRE";
        case 2: return (char*)"MemoryOrder.RELEASE";
        case 3: return (char*)"MemoryOrder.ACQ_REL";
        default: return (char*)"MemoryOrder.SEQ_CST";
    }
}

fn char* atomic_op_c3(int op)
{
    switch (op)
    {
        case 2: return (char*)"atomic_xchg";
        case 3: return (char*)"atomic_add";
        case 4: return (char*)"atomic_sub";
        case 5: return (char*)"atomic_and";
        case 6: return (char*)"atomic_or";
        case 7: return (char*)"atomic_xor";
        default: return null;
    }
}

fn void C3.cmd(C3* c, AirCmd* cmd, Sb* o)
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
                o.put((char*)" = "); o.put(v.op); o.put((char*)";"); o.putc('\n');
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
                if (x.vol) { o.put((char*)"volatile_store("); o.put(p.op); o.put((char*)", "); o.put(v.op); o.putc(')'); }
                else { o.putc('*'); o.put(p.op); o.put((char*)" = "); o.put(v.op); }
                o.put((char*)";"); o.putc('\n');
                x = x.next; continue;
            }
            case ACMD_FENCE:
            {
                if (x.atomic_order < 1 || x.atomic_order > 4) { c.err((char*)"a fence needs acquire, release, acq_rel or seq_cst ordering", null); return; }
                c.pad(c, o); o.put((char*)"fence("); o.put(atomic_order_c3(x.atomic_order)); o.put((char*)")"); o.put((char*)";"); o.putc('\n');
                x = x.next; continue;
            }
            case ACMD_RET: c.stmt_ret(c, o, x.prd); return;
            case ACMD_TRAP: c.pad(c, o); o.put((char*)"unreachable(\"trap\")"); o.put((char*)";"); o.putc('\n'); return;
            case ACMD_UB:   c.pad(c, o); o.put((char*)"unreachable(\"ub\")"); o.put((char*)";"); o.putc('\n'); return;
            case ACMD_JUMP: c.jump_transfer(c, x, o); return;
            case ACMD_IF:
            {
                Val cv = c.prd(x.prd);
                if (cv.ty != null && !air_util::ty_is_bool(cv.ty)) { c.err((char*)"if condition is not a bool", null); }
                c.pad(c, o); o.put((char*)"if ("); o.put(cv.op); o.put((char*)") {"); o.putc('\n');
                c.ind += 4; c.cmd(x.then_c, o); c.ind -= 4;
                if (x.else_c != null)
                {
                    c.pad(c, o); o.put((char*)"} else {"); o.putc('\n');
                    c.ind += 4; c.cmd(x.else_c, o); c.ind -= 4;
                }
                c.pad(c, o); o.put((char*)"}"); o.putc('\n');
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
                    c.pad(c, o); c.ty_decl(c, o, v.ty, k.bind); o.put((char*)" = "); o.put(v.op); o.put((char*)";"); o.putc('\n');
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
                    if (k.tag == ACNS_PROJ) { s.putc('.'); s.putc('_'); s.int_(ix); }
                    else { s.putc('.'); c.name(&s, k.name, false); }
                    c.pad(c, o);
                    c.ty_decl(c, o, ft, k.tail.bind);
                    o.put((char*)" = "); o.put(s.take()); o.put((char*)";"); o.putc('\n');
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
                char* r = c.fresh();
                Sb s; s.init();
                c.pad(c, o);
                s.put((char*)"long "); s.put(r); s.put((char*)" = __pride_syscall"); s.int_((long)na); s.putc('(');
                for (usz i = 0; i < na; i++) { if (i > 0) { s.put((char*)", "); } s.put(a[i].op); }
                s.putc(')'); s.put((char*)";"); s.putc('\n');
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
                char* r = c.fresh();
                Sb s; s.init();
                c.pad(c, o);
                if (op == 0)
                {
                    s.put((char*)"long "); s.put(r); s.put((char*)" = atomic_load("); s.put(p.op); s.put((char*)", "); s.put(atomic_order_c3(ord)); s.putc(')');
                }
                else if (op == 1)
                {
                    if (x.prd_count < 1) { c.err((char*)"atomic store needs an operand", null); return; }
                    s.put((char*)"atomic_store("); s.put(p.op); s.put((char*)", "); s.put(c.prd(x.prds[0]).op); s.put((char*)", "); s.put(atomic_order_c3(ord)); s.putc(')');
                }
                else
                {
                    if (x.prd_count < 1) { c.err((char*)"atomic read-modify-write needs an operand", null); return; }
                    char* fn = atomic_op_c3(op);
                    if (fn == null) { c.err((char*)"atomic operation is not part of the low profile", null); return; }
                    s.put((char*)"long "); s.put(r); s.put((char*)" = "); s.put(fn); s.putc('('); s.put(p.op); s.put((char*)", "); s.put(c.prd(x.prds[0]).op); s.put((char*)", "); s.put(atomic_order_c3(ord)); s.putc(')');
                }
                s.put((char*)";"); s.putc('\n');
                o.put(s.take());
                if (op == 1) { c.bind(x.cns.bind, (char*)"/*unit*/", c.m.t_unit); }
                else { c.bind(x.cns.bind, r, et); }
                x = x.cns.body; continue;
            }
            case ACMD_ASM:
            {
                // C3's inline asm takes ONE string operand and no constraint list
                // of LLVM's shape, so a module carrying LLVM constraints is not
                // translatable without inventing semantics. Refuse it by name.
                if (x.asm_cons == null || x.asm_ret == null) { c.err((char*)"asm in the low profile needs constraints and a result type", null); return; }
                c.err((char*)"inline asm carries LLVM constraints and has no C3 form yet", null);
                return;
            }
            default:
                c.err((char*)"command is not part of the low profile", cmd_tag_name(x.tag)); return;
        }
    }
}

fn void C3.emit_switch(C3* c, AirCmd* x, Sb* o)
{
    Val s = c.prd(x.prd);
    if (!(air_util::ty_is_int(s.ty) || air_util::ty_is_bool(s.ty))) { c.err((char*)"match scrutinee is not an integer or bool", null); return; }
    c.pad(c, o); o.put((char*)"switch ("); o.put(s.op); o.put((char*)") {"); o.putc('\n');
    c.ind += 4;
    for (usz i = 0; i < x.branch_count; i++)
    {
        AirBranch* b = x.branches[i];
        if (b == null || b.pat == null) { continue; }
        if (b.guard != null) { c.err((char*)"match guard in the low profile", null); }
        c.pad(c, o);
        if (b.pat.tag == APAT_WILD || b.pat.tag == APAT_BIND)
        {
            if (b.pat.tag == APAT_BIND) { c.bind(b.pat.name, s.op, s.ty); }
            o.put((char*)"default:"); o.putc('\n');
        }
        else if (b.pat.tag == APAT_INT || b.pat.tag == APAT_BOOL || b.pat.tag == APAT_CHAR)
        {
            o.put((char*)"case "); o.int_(b.pat.ival); o.put((char*)":"); o.putc('\n');
        }
        else
        {
            c.err((char*)"pattern is not part of the low profile", null);
            c.ind -= 4; c.pad(c, o); o.put((char*)"}"); o.putc('\n'); return;
        }
        c.ind += 4; c.cmd(b.body, o); c.ind -= 4;
    }
    c.ind -= 4;
    c.pad(c, o); o.put((char*)"}"); o.putc('\n');
}

// ── the control-flow strategy ──────────────────────────────────────────────
// docs/pear2/C3_TARGET.md §3. A label whose incoming jumps can be expressed as
// one assignment per jump is a PLAIN block; a label that is the target of a back
// edge is a LOOP head; everything else is DISPATCH, the driven switch. The
// classification is made once, from the whole function, before anything prints.
fn usz C3.find_label(C3* c, char* nm)
{
    if (nm == null) { return MAXL; }
    for (usz i = 0; i < c.nl; i++) { if (air_text::streq(c.lbls[i].name, nm)) { return i; } }
    return MAXL;
}

fn void C3.jump_transfer(C3* c, AirCmd* x, Sb* o)
{
    usz ti = c.find_label(c.target_label);
    if (ti == MAXL) { c.err((char*)"jump to an unknown label", c.target_label); return; }
    Lbl* tb = &c.lbls[ti];
    if (tb.np != x.jump_arg_count) { c.err((char*)"jump has the wrong number of arguments", c.target_label); }
    for (usz i = 0; i < x.jump_arg_count && i < tb.np; i++)
    {
        Val a;
        if (!c.lookup(x.jump_args[i], &a)) { c.err((char*)"jump argument is unbound", x.jump_args[i]); continue; }
        if (a.ty != null && tb.params[i] != null && tb.params[i].ty != null && !air_util::ty_eq(a.ty, tb.params[i].ty)) { c.err((char*)"jump argument has the wrong type", x.jump_args[i]); }
        c.pad(c, o);
        c.name(o, tb.params[i].name, false);
        o.put((char*)" = "); o.put(a.op); o.put((char*)";"); o.putc('\n');
    }
    // The transfer. In a driven function the case ends by setting the program
    // counter and going round, which is the only form C3 allows -- there is no
    // goto and no label. In a straight-line function the only legal transfer is
    // to a later label, which the printer reaches by simply continuing.
    if (c.driven)
    {
        c.pad(c, o); o.put((char*)"__pc = "); o.int_((long)ti); o.put((char*)";"); o.putc('\n');
        c.pad(c, o); o.put((char*)"nextcase;"); o.putc('\n');
        return;
    }
    if (ti <= c.cur) { c.err((char*)"back edge in a function printed without a dispatch loop", c.target_label); return; }
}

fn void C3.add_label(C3* c, AirCmd* lb)
{
    if (c.nl >= MAXL) { c.err((char*)"too many labels", lb.binder); return; }
    Lbl* l = &c.lbls[c.nl];
    l.name = lb.binder; l.np = lb.mbinder_count; l.body = lb.body;
    l.n_pred = 0; l.back_edge = false; l.is_entry = (c.nl == 0);
    for (usz i = 0; i < lb.mbinder_count && i < 16; i++) { l.params[i] = lb.mbinders[i]; }
    c.nl++;
}

// Incoming jumps and back edges over the whole function, before anything prints:
// whether a function needs the dispatch loop is a property of the whole body, not
// of one label.
fn void C3.scan(C3* c, AirCmd* x, usz from)
{
    while (x != null)
    {
        switch (x.tag)
        {
            case ACMD_JUMP:
            {
                usz ti = c.find_label(x.target_label);
                if (ti != MAXL)
                {
                    c.lbls[ti].n_pred++;
                    if (ti <= from) { c.lbls[ti].back_edge = true; }
                }
                return;
            }
            case ACMD_LET: if (x.prd != null) { c.scan(c, x.prd.body, from); } x = x.body; continue;
            case ACMD_SEQ: c.scan(c, x.body, from); x = x.next; continue;
            case ACMD_IF: c.scan(c, x.then_c, from); c.scan(c, x.else_c, from); x = x.next; continue;
            case ACMD_MATCH:
                for (usz i = 0; i < x.branch_count; i++) { AirBranch* b = x.branches[i]; if (b != null) { c.scan(c, b.body, from); } }
                return;
            case ACMD_CUT:
            {
                AirCns* k = x.cns;
                if (k != null && k.tag == ACNS_COMU) { x = k.body; continue; }
                return;
            }
            default: return;
        }
    }
}

// ── functions and module ───────────────────────────────────────────────────
fn bool is_void_ty(AirTyp* t) { return t == null || t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM; }

fn void C3.header(C3* c, AirDecl* d, Sb* o)
{
    o.put((char*)"fn ");
    if (is_void_ty(d.ret_ty)) { o.put((char*)"void "); } else { c.ty(o, d.ret_ty); o.putc(' '); }
    c.name(o, d.name, false);
    o.putc('(');
    usz wrote = 0;
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* b = d.params[i];
        if (b == null) { continue; }
        if (!ty_low(b.ty, 0)) { c.err((char*)"parameter type is not part of the low profile", b.name); }
        if (wrote > 0) { o.put((char*)", "); }
        c.ty_decl(c, o, b.ty, b.name);
        wrote++;
    }
    o.putc(')');
}

// A label's parameters become C3 variables declared at the top of the function.
// They cannot be declared inside the dispatch switch: a `case` body does not
// share scope with the next one, and a phi written on one path is read on
// another.
fn void C3.label_body(C3* c, Sb* o)
{
    Lbl* lb = &c.lbls[c.cur];
    for (usz j = 0; j < lb.np; j++)
    {
        if (lb.params[j] == null) { continue; }
        if (!c3_ident_ok(lb.params[j].name)) { c.err((char*)"label parameter is not a legal C3 identifier", lb.params[j].name); continue; }
        c.locals.put((char*)"    ");
        c.ty_decl(c, &c.locals, lb.params[j].ty, lb.params[j].name);
        c.locals.putc('\n');
        c.bind(lb.params[j].name, lb.params[j].name, lb.params[j].ty);
    }
    c.cmd(lb.body, o);
}

fn void C3.function(C3* c, AirDecl* d, Sb* out)
{
    c.fn_name = d.name;
    c.nv = 0; c.nl = 0; c.cur = 0; c.tmp = 0; c.ind = 4; c.driven = false;
    c.cur_ret = d.ret_ty;
    c.locals.n = 0; if (c.locals.d != null) { c.locals.d[0] = 0; }
    if (!ty_low(d.ret_ty, 0)) { c.err((char*)"return type is not part of the low profile", null); }

    // 1. the label spine (the same walk Ll.function does in air_ll.c3)
    AirCmd* x = d.def_body;
    while (x != null && x.tag == ACMD_SEQ && x.body != null && x.body.tag == ACMD_LABEL)
    {
        c.add_label(c, x.body);
        x = x.next;
    }
    if (x != null && x.tag == ACMD_LABEL) { c.add_label(c, x); x = null; }
    if (x != null) { c.err((char*)"function body is not a label spine", null); }

    // 2. parameters are bound before any body prints
    for (usz i = 0; i < d.param_count; i++) { AirBinder* b = d.params[i]; if (b != null) { c.bind(b.name, b.name, b.ty); } }

    // 3. predecessors and back edges
    for (usz i = 0; i < c.nl; i++) { c.scan(c, c.lbls[i].body, i); }
    bool any_back = false;
    for (usz i = 0; i < c.nl; i++) { if (c.lbls[i].back_edge) { any_back = true; } }

    // 4. shape. A function whose CFG is a straight spine is printed as a straight
    //    spine, which is what almost every function is. One back edge, or one
    //    forward jump that is not the next label, and the whole function is
    //    driven by the __pc switch: C3 cannot express an arbitrary transfer and
    //    splitting a function into a half-driven shape would be worse than
    //    driving all of it.
    c.driven = any_back || c.has_forward_skips(c);
    if (c.driven) { c.dispatch_fns++; }

    Sb body; body.init();
    if (c.driven)
    {
        body.put((char*)"    sz __pc = 0;"); body.putc('\n');
        body.put((char*)"    while (true) {"); body.putc('\n');
        body.put((char*)"        switch (__pc) {"); body.putc('\n');
        for (usz i = 0; i < c.nl; i++)
        {
            c.cur = i;
            c.ind = 12; c.pad(c, &body);
            body.put((char*)"case "); body.int_((long)i); body.put((char*)":"); body.putc('\n');
            c.ind = 16;
            c.label_body(c, &body);
        }
        c.ind = 12; c.pad(c, &body); body.put((char*)"default: return;"); body.putc('\n');
        body.put((char*)"        }"); body.putc('\n');
        body.put((char*)"    }"); body.putc('\n');
        c.ind = 4;
    }
    else
    {
        for (usz i = 0; i < c.nl; i++)
        {
            c.cur = i;
            c.pad(c, &body);
            body.put((char*)"// "); body.put((char*)(c.lbls[i].name == null ? (char*)"label" : c.lbls[i].name)); body.putc('\n');
            c.label_body(c, &body);
        }
    }

    // 5. header, the hoisted declarations, the body
    c.header(c, d, out);
    out.putc('\n'); out.put((char*)"{"); out.putc('\n');
    if (c.locals.d != null) { out.put(c.locals.d); }
    if (body.d != null) { out.put(body.d); }
    out.put((char*)"}"); out.putc('\n'); out.putc('\n');
}

// Does any jump skip forward past the next label? A straight spine reaches every
// label by falling into it; a skip needs a transfer C3 does not have.
fn bool C3.has_forward_skips(C3* c)
{
    for (usz i = 0; i < c.nl; i++)
    {
        if (c.lbls[i].n_pred == 0 && i > 0) { return true; }   // an unreachable label
        if (c.lbls[i].n_pred > 1) { return true; }             // a join: more than one way in
    }
    return false;
}

// ── module ─────────────────────────────────────────────────────────────────
fn void C3.global_decl(C3* c, AirDecl* d, Sb* o)
{
    // docs/pear2/C3_TARGET.md §4.5
    char* sec = decl_attr_str(d, "section");
    if (sec != null) { o.put((char*)"@section(\""); o.put(sec); o.put((char*)"\") "); }
    long al = decl_attr_int(d, "align");
    if (al > 0) { o.put((char*)"@align("); o.int_(al); o.put((char*)") "); }
    if (decl_has_attr(d, "thread_local")) { o.put((char*)"tlocal "); }
    if (d.is_extern && d.g_init == null)
    {
        o.put((char*)"extern "); c.ty(o, d.ret_ty); o.putc(' ');
        c.name(o, d.name, false); o.putc(';'); o.putc('\n');
        return;
    }
    if (!d.g_mut) { o.put((char*)"const "); }
    c.ty(o, d.ret_ty); o.putc(' ');
    c.name(o, d.name, false);
    o.put((char*)" = ");
    if (d.g_init == null) { o.put((char*)"{}"); }
    else { Sb s; s.init(); c.scalar(&s, d.g_init, d.ret_ty); o.put(s.take()); }
    o.putc(';'); o.putc('\n');
}

fn void C3.declare(C3* c, AirDecl* d, Sb* o)
{
    o.put((char*)"extern fn ");
    if (is_void_ty(d.ret_ty)) { o.put((char*)"void "); } else { c.ty(o, d.ret_ty); o.putc(' '); }
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
    o.put((char*)")"); o.put((char*)";"); o.putc('\n');
}

fn void C3.data_type(C3* c, AirDecl* d, Sb* o)
{
    if (d.ctor_count != 1) { c.err((char*)"data with several constructors (enum layout) is not part of this profile yet", d.name); return; }
    if (d.typaram_count > 0) { c.err((char*)"generic data is not part of the low profile", d.name); return; }
    if (decl_has_attr(d, "packed")) { o.put((char*)"@packed "); }
    o.put((char*)"struct "); c.name(o, d.name, false); o.put((char*)" {"); o.putc('\n');
    AirCtorDecl* ct = d.ctors[0];
    for (usz j = 0; j < ct.field_count; j++)
    {
        o.put((char*)"    ");
        if (!ty_low(ct.fields[j].ty, 0)) { c.err((char*)"field type is not part of the low profile", ct.fields[j].name); }
        // A zero-length field list cannot be spelled, so a marker keeps the
        // struct legal while using none of the AIR layout.
        c.ty_decl(c, o, ct.fields[j].ty, ct.fields[j].name);
        o.putc(';'); o.putc('\n');
    }
    if (ct.field_count == 0) { o.put((char*)"    char __unit;"); o.putc('\n'); }
    o.put((char*)"}"); o.putc('\n'); o.putc('\n');
}

fn int to_c3(AirModule* m, char** result, bool want_text)
{
    C3* c = (C3*)malloc(C3::size);
    c.m = m; c.errs = 0; c.fn_name = null; c.emit = want_text; c.dispatch_fns = 0;
    c.vn = (char**)malloc(8 * MAXV); c.vv = (Val*)malloc(Val::size * MAXV);
    c.lbls = (Lbl*)malloc(Lbl::size * MAXL);
    c.nv = 0; c.nl = 0; c.cur = 0; c.tmp = 0; c.ind = 4; c.driven = false;
    c.nstr = 0;
    c.locals.init(); c.types_out.init(); c.pre.init();

    Sb body; body.init();
    // Types first: a function signature may name one.
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
    all.put((char*)"// generated by air_c3 from an AIR 3.0 module -- C3 is a transpilation target, docs/pear2/C3_TARGET.md");
    all.putc('\n');
    if (m.source_path != null) { all.put((char*)"// source: "); all.put(m.source_path); all.putc('\n'); }
    all.put((char*)"module pear_out;"); all.putc('\n');
    all.put((char*)"import std::atomic;"); all.putc('\n'); all.putc('\n');
    if (c.types_out.d != null) { all.put(c.types_out.d); }
    if (c.pre.d != null) { all.put(c.pre.d); all.putc('\n'); }
    if (body.d != null) { all.put(body.d); }
    *result = all.take();
    // The dispatch fallback is reported, never silent: docs/pear2/C3_TARGET.md §3.3
    if (c.dispatch_fns > 0)
    {
        void* se = fdopen(2, "w");
        fprintf(se, "air-c3: %ld function(s) used the __pc dispatch loop (target: 0)\n", (long)c.dispatch_fns);
        fflush(se);
    }
    int e = c.errs;
    return e;
}

fn int write_c3(AirModule* m, char* path)
{
    char* text = null;
    int errs = to_c3(m, &text, true);
    if (text == null) { return -1; }
    void* f = path != null ? fopen(path, "w") : fdopen(1, "w");
    if (f == null) { return -1; }
    usz n = 0; while (text[n] != 0) { n++; }
    fwrite((void*)text, 1, n, f);
    // The close IS the write result: a full disk reports success on every
    // fwrite and fails at fclose. Ignoring it published empty artifacts.
    int close_rc = (path != null) ? fclose(f) : fflush(f);
    if (close_rc != 0 && errs == 0) { errs = 1; }
    return errs;
}
