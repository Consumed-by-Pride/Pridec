// ============================================================================
// air_read.c3 — AIR 2.0 text reader (.air -> AirModule).
// ----------------------------------------------------------------------------
// The executable form of the grammar in docs/specs/AIR.md: a hand-written
// recursive-descent parser with one token of lookahead and no backtracking.
// It is deliberately strict — unknown keywords, unterminated forms, counts over
// the IR limits and trailing garbage are errors with file:line:col, never
// guesses — because a backend that "recovers" from a malformed .air hides
// frontend bugs.
//
// Trust boundary: the text may carry qualifier CLAIMS (`facts`, `readonly`,
// `nocapture`). They are read as candidates only: every decl that claims
// anything comes back as AFACT_AST_FINAL, never AFACT_AIR_CHECKED. The caller
// re-screens with air_facts::validate_module; a forged claim cannot authorise an
// LLVM attribute because only the screen can promote it.
// ============================================================================
module air_read;
import air_ir;
import air_text;

extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn usz   fread(void* buf, usz size_, usz count_, void* f);
extern fn int   fseek(void* f, long off, int whence);
extern fn long  ftell(void* f);
extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   fflush(void* f);
extern fn void* fdopen(int fd, char* mode);
extern fn void* malloc(usz n);
extern fn void  free(void* p);
extern fn double strtod(char* s, char** end);

enum TokKind : int { T_EOF, T_ID, T_QID, T_INT, T_FLOAT, T_STR, T_BSTR, T_PUNCT, T_MID, T_ARROW, T_ERR }

struct Rd
{
    char*     src;
    usz       len;
    usz       pos;
    int       line;
    int       col;
    TokKind   kind;
    char      punct;
    long      ival;
    double    fval;
    int       ver_major;   // 2 or 3 (3 = low profile: alloca/load/gep/store/global are legal)
    int       ver_minor;   // header version 2.<ver_minor>: 2.1 requires result continuations (2.2: perform too)
    char*     tb;      // decoded token text (ids, strings)
    usz       tlen;
    int       tline;
    int       tcol;
    AirArena* a;
    bool      failed;
    char*     path;
    bool      quiet;
    char*     errmsg;
    int       err_line;
    int       err_col;
}

fn void Rd.fail(Rd* r, char* msg)
{
    if (r.failed) { return; }
    r.failed = true;
    r.errmsg = msg;
    r.err_line = r.tline;
    r.err_col = r.tcol;
    if (!r.quiet)
    {
        void* se = fdopen(2, "w");
        fprintf(se, "%s:%d:%d: air-read error: %s\n", r.path != null ? r.path : "<air>", r.tline, r.tcol, msg);
        fflush(se);
    }
}

// ── Lexer ─────────────────────────────────────────────────────────────────
fn char Rd.ch(Rd* r) { if (r.pos >= r.len) { return (char)0; } return r.src[r.pos]; }
fn char Rd.ch2(Rd* r, usz k) { if (r.pos + k >= r.len) { return (char)0; } return r.src[r.pos + k]; }
fn void Rd.adv(Rd* r)
{
    if (r.pos >= r.len) { return; }
    if (r.src[r.pos] == '\n') { r.line++; r.col = 1; } else { r.col++; }
    r.pos++;
}
fn bool is_digit(char c) { return c >= '0' && c <= '9'; }
fn int hexval(char c)
{
    if (c >= '0' && c <= '9') { return (int)(c - '0'); }
    if (c >= 'a' && c <= 'f') { return (int)(c - 'a') + 10; }
    if (c >= 'A' && c <= 'F') { return (int)(c - 'A') + 10; }
    return -1;
}

fn void Rd.skip_ws(Rd* r)
{
    while (r.pos < r.len)
    {
        char c = r.ch();
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { r.adv(); continue; }
        if (c == '/' && r.ch2(1) == '/')
        {
            while (r.pos < r.len && r.ch() != '\n') { r.adv(); }
            continue;
        }
        break;
    }
}

// Reads a quoted body up to `q`, decoding \xHH \\ \q \n \t. Result in r.tb.
fn bool Rd.read_quoted(Rd* r, char q)
{
    r.tlen = 0;
    while (true)
    {
        if (r.pos >= r.len) { r.fail("unterminated quoted text"); return false; }
        char c = r.ch();
        if (c == q) { r.adv(); r.tb[r.tlen] = 0; return true; }
        if (c == '\n') { r.fail("newline in quoted text"); return false; }
        if (c == '\\')
        {
            r.adv();
            char e = r.ch();
            if (e == 'x')
            {
                int h1 = hexval(r.ch2(1)); int h2 = hexval(r.ch2(2));
                if (h1 < 0 || h2 < 0) { r.fail("bad \\x escape"); return false; }
                r.adv(); r.adv(); r.adv();
                r.tb[r.tlen] = (char)(h1 * 16 + h2); r.tlen++;
                continue;
            }
            if (e == '\\' || e == '"' || e == '`') { r.adv(); r.tb[r.tlen] = e; r.tlen++; continue; }
            if (e == 'n') { r.adv(); r.tb[r.tlen] = '\n'; r.tlen++; continue; }
            if (e == 't') { r.adv(); r.tb[r.tlen] = '\t'; r.tlen++; continue; }
            r.fail("unknown escape");
            return false;
        }
        r.tb[r.tlen] = c; r.tlen++;
        r.adv();
    }
}

fn void Rd.next(Rd* r)
{
    r.skip_ws();
    r.tline = r.line; r.tcol = r.col;
    r.tlen = 0;
    if (r.pos >= r.len) { r.kind = T_EOF; return; }
    char c = r.ch();
    // U+00B7 middle dot  (C2 B7): the stack separator
    if ((uint)c == 0xC2 && (uint)r.ch2(1) == 0xB7) { r.adv(); r.adv(); r.kind = T_MID; return; }
    // U+03BC mu (CE BC), optionally followed by U+0303 (CC 83) = mu-tilde
    if ((uint)c == 0xCE && (uint)r.ch2(1) == 0xBC)
    {
        r.adv(); r.adv();
        if ((uint)r.ch() == 0xCC && (uint)r.ch2(1) == 0x83) { r.adv(); r.adv(); r.tb[0]='m'; r.tb[1]='u'; r.tb[2]='~'; r.tb[3]=0; r.tlen = 3; }
        else { r.tb[0]='m'; r.tb[1]='u'; r.tb[2]=0; r.tlen = 2; }
        r.kind = T_ID; return;
    }
    if (c == '-' && r.ch2(1) == '>') { r.adv(); r.adv(); r.kind = T_ARROW; return; }
    if (is_digit(c) || (c == '-' && is_digit(r.ch2(1))))
    {
        usz start = r.pos;
        bool is_float = false;
        usz n = 0;
        if (c == '-') { r.tb[n] = c; n++; r.adv(); }
        while (is_digit(r.ch())) { r.tb[n] = r.ch(); n++; r.adv(); }
        if (r.ch() == '.' && is_digit(r.ch2(1)))
        {
            is_float = true; r.tb[n] = '.'; n++; r.adv();
            while (is_digit(r.ch())) { r.tb[n] = r.ch(); n++; r.adv(); }
        }
        if (r.ch() == 'e' || r.ch() == 'E')
        {
            char s1 = r.ch2(1);
            if (is_digit(s1) || ((s1 == '-' || s1 == '+') && is_digit(r.ch2(2))))
            {
                is_float = true; r.tb[n] = 'e'; n++; r.adv();
                if (r.ch() == '-' || r.ch() == '+') { r.tb[n] = r.ch(); n++; r.adv(); }
                while (is_digit(r.ch())) { r.tb[n] = r.ch(); n++; r.adv(); }
            }
        }
        r.tb[n] = 0; r.tlen = n;
        if (is_float) { r.kind = T_FLOAT; r.fval = strtod(r.tb, (char**)null); return; }
        // decimal i64 with overflow check
        bool neg = (r.tb[0] == '-');
        ulong acc = 0; usz i = neg ? 1 : 0;
        ulong lim = neg ? 9223372036854775808UL : 9223372036854775807UL;
        while (i < n)
        {
            ulong dgt = (ulong)(r.tb[i] - '0');
            if (acc > (lim - dgt) / 10) { r.fail("integer literal out of range"); r.kind = T_ERR; return; }
            acc = acc * 10 + dgt; i++;
        }
        r.kind = T_INT;
        r.ival = neg ? (long)(0 - acc) : (long)acc;
        (void)start;
        return;
    }
    if (c == '"') { r.adv(); r.kind = T_STR; if (!r.read_quoted('"')) { r.kind = T_ERR; } return; }
    if (c == 'b' && r.ch2(1) == '"')
    {
        r.adv(); r.adv(); r.kind = T_BSTR;
        if (!r.read_quoted('"')) { r.kind = T_ERR; }
        return;
    }
    if (c == '`') { r.adv(); r.kind = T_QID; if (!r.read_quoted('`')) { r.kind = T_ERR; } return; }
    if (air_text::is_bare_start(c))
    {
        usz n = 0;
        while (air_text::is_bare_rest(r.ch())) { r.tb[n] = r.ch(); n++; r.adv(); }
        r.tb[n] = 0; r.tlen = n;
        if (n == 2 && r.tb[0] == 'm' && r.tb[1] == 'u' && r.ch() == '~') { r.adv(); r.tb[2] = '~'; r.tb[3] = 0; r.tlen = 3; }
        r.kind = T_ID;
        return;
    }
    if (c == '#' || c == '(' || c == ')' || c == '{' || c == '}' || c == '[' || c == ']' || c == '<' || c == '>'
        || c == '|' || c == ',' || c == ';' || c == ':' || c == '.' || c == '=')
    {
        r.punct = c; r.kind = T_PUNCT; r.adv(); return;
    }
    r.fail("unexpected character");
    r.kind = T_ERR;
}

// ── Token helpers ─────────────────────────────────────────────────────────
fn bool Rd.is_p(Rd* r, char c) { return r.kind == T_PUNCT && r.punct == c; }
fn bool Rd.is_kw(Rd* r, char* kw) { return r.kind == T_ID && air_text::streq(r.tb, kw); }
fn bool Rd.eat_p(Rd* r, char c) { if (r.is_p(c)) { r.next(); return true; } return false; }
fn bool Rd.eat_kw(Rd* r, char* kw) { if (r.is_kw(kw)) { r.next(); return true; } return false; }
fn void Rd.expect_p(Rd* r, char c)
{
    if (r.failed) { return; }
    if (!r.eat_p(c)) { r.fail("expected a different punctuation mark here"); }
}
fn void Rd.expect_kw(Rd* r, char* kw)
{
    if (r.failed) { return; }
    if (!r.eat_kw(kw)) { r.fail("expected a keyword here"); }
}
fn void Rd.expect_mid(Rd* r)
{
    if (r.failed) { return; }
    if (r.kind == T_MID) { r.next(); } else { r.fail("expected the stack separator \xc2\xb7"); }
}
fn char* Rd.dup_tok(Rd* r) { return r.a.dup(r.tb, r.tlen); }

// NAME ::= bare-ident | `quoted` | nil.  Returns null for `nil`.
fn char* Rd.name(Rd* r)
{
    if (r.failed) { return null; }
    if (r.kind == T_ID)
    {
        if (air_text::streq(r.tb, "nil")) { r.next(); return null; }
        char* s = r.dup_tok(); r.next(); return s;
    }
    if (r.kind == T_QID) { char* s = r.dup_tok(); r.next(); return s; }
    r.fail("expected a name");
    return null;
}
fn long Rd.int_(Rd* r)
{
    if (r.failed) { return 0; }
    if (r.kind != T_INT) { r.fail("expected an integer"); return 0; }
    long v = r.ival; r.next(); return v;
}

// ── Types ─────────────────────────────────────────────────────────────────
fn AirTyp* Rd.typ(Rd* r)
{
    if (r.failed) { return null; }
    if (r.kind != T_ID) { r.fail("expected a type"); return null; }
    if (air_text::streq(r.tb, "nil")) { r.next(); return null; }
    int tg = air_text::typ_from_kw(r.tb);
    if (tg < 0) { r.fail("unknown type keyword"); return null; }
    AirTypTag tag = (AirTypTag)tg;
    if (tag == ATYP_INVALID || tag == ATYP_RECORD || tag == ATYP_MULT)
    {
        r.fail("unsupported type keyword");
        return null;
    }
    r.next();
    AirTyp* t = air_ir::air_mk_typ(r.a, tag);
    if (t == null) { r.fail("out of memory"); return null; }
    if (air_text::typ_has_name(tag)) { t.name = r.name(); }
    if (air_text::typ_has_ival(tag))
    {
        r.expect_p('#');
        t.ival = r.int_();
    }
    if (r.is_p('('))
    {
        r.next();
        if (!r.is_p(')'))
        {
            while (!r.failed)
            {
                if (t.arg_count >= 16) { r.fail("more than 16 type arguments"); return null; }
                AirTyp* x = r.typ();
                t.args[t.arg_count] = x; t.arg_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p(')');
    }
    if (r.is_kw("tail"))
    {
        r.next(); r.expect_p('(');
        t.eff_tail = r.typ();
        r.expect_p(')');
    }
    return t;
}

// ── Binders ───────────────────────────────────────────────────────────────
fn AirBinder* Rd.binder(Rd* r)
{
    if (r.failed) { return null; }
    if (r.is_kw("nil")) { r.next(); return null; }
    AirBinder* b = air_ir::air_new_AirBinder(r.a);
    if (b == null) { r.fail("out of memory"); return null; }
    while (!r.failed)
    {
        if (r.eat_kw("mut")) { b.is_mutable = true; continue; }
        if (r.eat_kw("nocapture")) { b.no_capture = true; continue; }
        if (r.eat_kw("lin")) { b.mult = AMULT_LIN; continue; }
        if (r.eat_kw("aff")) { b.mult = AMULT_AFF; continue; }
        if (r.is_kw("exact"))
        {
            r.next(); r.expect_p('(');
            b.mult = AMULT_EXACT; b.mult_exact = (int)r.int_();
            r.expect_p(')');
            continue;
        }
        break;
    }
    b.name = r.name();
    if (r.eat_p(':')) { b.ty = r.typ(); }
    return b;
}
// '(' binder,* ')'  into a fixed array; returns count
fn usz Rd.binder_list(Rd* r, AirBinder** out, usz cap)
{
    usz n = 0;
    r.expect_p('(');
    if (!r.is_p(')'))
    {
        while (!r.failed)
        {
            if (n >= cap) { r.fail("too many binders (limit 16)"); return n; }
            out[n] = r.binder(); n++;
            if (r.eat_p(',')) { continue; }
            break;
        }
    }
    r.expect_p(')');
    return n;
}
fn usz Rd.name_list(Rd* r, char** out, usz cap)
{
    usz n = 0;
    r.expect_p('(');
    if (!r.is_p(')'))
    {
        while (!r.failed)
        {
            if (n >= cap) { r.fail("too many names (limit 16)"); return n; }
            out[n] = r.name(); n++;
            if (r.eat_p(',')) { continue; }
            break;
        }
    }
    r.expect_p(')');
    return n;
}

// ── Patterns ──────────────────────────────────────────────────────────────
fn AirPat* Rd.pat(Rd* r)
{
    if (r.failed) { return null; }
    AirArena* a = r.a;
    if (r.kind == T_INT)
    {
        AirPat* p = air_ir::air_mk_pat_int(a, r.ival); r.next(); return p;
    }
    if (r.kind == T_FLOAT)
    {
        AirPat* p = air_ir::air_mk_pat(a, APAT_FLOAT); p.fval = r.fval; r.next(); return p;
    }
    if (r.kind == T_STR)
    {
        AirPat* p = air_ir::air_mk_pat(a, APAT_STRING); p.name = r.dup_tok(); r.next(); return p;
    }
    if (r.kind != T_ID) { r.fail("expected a pattern"); return null; }
    if (r.is_kw("nil")) { r.next(); return null; }
    if (r.is_kw("_")) { r.next(); return air_ir::air_mk_pat_wild(a); }
    if (r.is_kw("true"))  { r.next(); return air_ir::air_mk_pat_bool(a, true); }
    if (r.is_kw("false")) { r.next(); return air_ir::air_mk_pat_bool(a, false); }
    if (r.is_kw("bind")) { r.next(); return air_ir::air_mk_pat_bind(a, r.name()); }
    if (r.is_kw("rest")) { r.next(); return air_ir::air_mk_pat(a, APAT_REST); }
    if (r.is_kw("char"))
    {
        r.next(); r.expect_p('(');
        AirPat* p = air_ir::air_mk_pat(a, APAT_CHAR); p.ival = r.int_();
        r.expect_p(')'); return p;
    }
    if (r.is_kw("tuple") || r.is_kw("array"))
    {
        bool is_tup = r.is_kw("tuple");
        r.next();
        AirPat* p = air_ir::air_mk_pat(a, is_tup ? APAT_TUPLE : APAT_ARRAY);
        r.expect_p('(');
        if (!r.is_p(')'))
        {
            while (!r.failed)
            {
                if (p.sub_count >= 16) { r.fail("more than 16 sub-patterns"); return null; }
                p.sub[p.sub_count] = r.pat(); p.sub_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p(')');
        return p;
    }
    if (r.is_kw("record"))
    {
        r.next();
        AirPat* p = air_ir::air_mk_pat(a, APAT_RECORD);
        r.expect_p('{');
        if (!r.is_p('}'))
        {
            while (!r.failed)
            {
                if (p.field_count >= 16) { r.fail("more than 16 record-pattern fields"); return null; }
                AirFieldInit* f = air_ir::air_new_AirFieldInit(a);
                f.name = r.name();
                p.fields[p.field_count] = f; p.field_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p('}');
        return p;
    }
    if (r.is_kw("ctor"))
    {
        r.next();
        AirPat* p = air_ir::air_mk_pat(a, APAT_VARIANT);
        p.name = r.name();
        if (r.eat_p('('))
        {
            if (!r.is_p(')'))
            {
                while (!r.failed)
                {
                    if (p.sub_count >= 16) { r.fail("more than 16 sub-patterns"); return null; }
                    p.sub[p.sub_count] = r.pat(); p.sub_count++;
                    if (r.eat_p(',')) { continue; }
                    break;
                }
            }
            r.expect_p(')');
        }
        return p;
    }
    if (r.is_kw("as"))
    {
        r.next(); r.expect_p('(');
        AirPat* p = air_ir::air_mk_pat(a, APAT_AS);
        p.sub[0] = r.pat(); p.sub_count = 1;
        r.expect_p(',');
        p.name = r.name();
        r.expect_p(')');
        return p;
    }
    if (r.is_kw("or"))
    {
        r.next(); r.expect_p('(');
        AirPat* p = air_ir::air_mk_pat(a, APAT_OR);
        p.sub[0] = r.pat(); p.sub_count = 1;
        r.expect_p(',');
        p.or_alt = r.pat();
        r.expect_p(')');
        return p;
    }
    if (r.is_kw("ref"))
    {
        r.next(); r.expect_p('(');
        AirPat* p = air_ir::air_mk_pat(a, APAT_REF);
        p.sub[0] = r.pat(); p.sub_count = 1;
        r.expect_p(')');
        return p;
    }
    r.fail("unknown pattern form");
    return null;
}

// ── Producers ─────────────────────────────────────────────────────────────
fn AirPrd* Rd.new_prd(Rd* r, AirPrdTag tag)
{
    AirPrd* p = air_ir::air_new_AirPrd(r.a);
    if (p == null) { r.fail("out of memory"); return null; }
    p.tag = tag;
    return p;
}
fn void Rd.sub_list(Rd* r, AirPrd* p)
{
    r.expect_p('(');
    if (!r.is_p(')'))
    {
        while (!r.failed)
        {
            if (p.sub_count >= 16) { r.fail("more than 16 producer operands"); return; }
            p.subs[p.sub_count] = r.prd(); p.sub_count++;
            if (r.eat_p(',')) { continue; }
            break;
        }
    }
    r.expect_p(')');
}
// A producer may be followed by `: T`, the resolved type annotation (see air_write).
fn AirPrd* Rd.prd(Rd* r)
{
    AirPrd* p = r.prd_core();
    if (p != null && !r.failed && r.is_p(':'))
    {
        if (p.tag == APRD_SIZEOF || p.tag == APRD_ALIGNOF || p.tag == APRD_POISON || p.tag == APRD_COERCE || p.tag == APRD_OFFSETOF)
        {
            r.fail("this producer already carries its type as an operand");
            return null;
        }
        r.next();
        p.ty = r.typ();
    }
    return p;
}
fn AirPrd* Rd.prd_core(Rd* r)
{
    if (r.failed) { return null; }
    AirArena* a = r.a;
    switch (r.kind)
    {
        case T_INT:   { AirPrd* p = r.new_prd(APRD_INT); if (p != null) { p.ival = r.ival; } r.next(); return p; }
        case T_FLOAT: { AirPrd* p = r.new_prd(APRD_FLOAT); if (p != null) { p.fval = r.fval; } r.next(); return p; }
        case T_STR:
        {
            AirPrd* p = r.new_prd(APRD_STRING);
            if (p != null) { p.name = r.dup_tok(); p.bytes_len = r.tlen; }
            r.next(); return p;
        }
        case T_BSTR:
        {
            AirPrd* p = r.new_prd(APRD_BYTES);
            if (p != null) { p.bytes = r.dup_tok(); p.bytes_len = r.tlen; }
            r.next(); return p;
        }
        case T_QID:
        {
            AirPrd* p = r.new_prd(APRD_VAR);
            if (p != null) { p.name = r.dup_tok(); }
            r.next(); return p;
        }
        case T_PUNCT:
        {
            if (r.punct != '(') { r.fail("expected a producer"); return null; }
            r.next();
            if (r.kind != T_ID) { r.fail("expected an operator name after '('"); return null; }
            int bo = air_text::binop_from_name(r.tb);
            if (bo >= 0)
            {
                r.next();
                AirPrd* p = r.new_prd(APRD_BINOP); if (p == null) { return null; }
                p.bop = (AirBinop)bo;
                p.subs[0] = r.prd(); p.subs[1] = r.prd(); p.sub_count = 2;
                r.expect_p(')');
                return p;
            }
            int uo = air_text::unop_from_name(r.tb);
            if (uo >= 0)
            {
                r.next();
                AirPrd* p = r.new_prd(APRD_UNOP); if (p == null) { return null; }
                p.uop = (AirUnop)uo;
                p.subs[0] = r.prd(); p.sub_count = 1;
                r.expect_p(')');
                return p;
            }
            r.fail("unknown operator name");
            return null;
        }
        case T_ID: break;
        default: r.fail("expected a producer"); return null;
    }
    // identifier or keyword
    if (r.is_kw("nil")) { r.next(); return null; }
    if (r.is_kw("true") || r.is_kw("false"))
    {
        AirPrd* p = r.new_prd(APRD_BOOL); if (p != null) { p.bval = r.is_kw("true"); }
        r.next(); return p;
    }
    if (r.is_kw("unit"))        { r.next(); return r.new_prd(APRD_UNIT); }
    if (r.is_kw("null"))        { r.next(); return r.new_prd(APRD_NULL); }
    if (r.is_kw("unreachable")) { r.next(); return r.new_prd(APRD_UNREACHABLE_VAL); }
    if (r.is_kw("char"))
    {
        r.next(); r.expect_p('(');
        AirPrd* p = r.new_prd(APRD_CHAR); if (p == null) { return null; }
        p.ival = r.int_(); p.cval = (char)p.ival;
        r.expect_p(')'); return p;
    }
    if (r.is_kw("con"))
    {
        r.next();
        AirPrd* p = r.new_prd(APRD_CON); if (p == null) { return null; }
        p.name = r.name();
        if (r.is_p('(')) { r.sub_list(p); }
        return p;
    }
    if (r.is_kw("tuple") || r.is_kw("array"))
    {
        bool t = r.is_kw("tuple"); r.next();
        AirPrd* p = r.new_prd(t ? APRD_TUPLE : APRD_ARRAY); if (p == null) { return null; }
        r.sub_list(p); return p;
    }
    if (r.is_kw("record"))
    {
        r.next();
        AirPrd* p = r.new_prd(APRD_RECORD); if (p == null) { return null; }
        r.expect_p('{');
        if (!r.is_p('}'))
        {
            while (!r.failed)
            {
                if (p.rec_init_count >= 16) { r.fail("more than 16 record fields"); return null; }
                AirFieldInit* f = air_ir::air_new_AirFieldInit(a);
                f.name = r.name(); r.expect_p('=');
                f.value = r.prd();
                p.rec_inits[p.rec_init_count] = f; p.rec_init_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p('}');
        return p;
    }
    if (r.is_kw("inl") || r.is_kw("inr"))
    {
        bool l = r.is_kw("inl"); r.next();
        AirPrd* p = r.new_prd(l ? APRD_INL : APRD_INR); if (p == null) { return null; }
        r.expect_p('['); p.ty_arg = r.typ(); r.expect_p(']');
        r.expect_p('(');
        p.subs[0] = r.prd(); p.sub_count = 1;
        r.expect_p(')'); return p;
    }
    if (r.is_kw("lam") || r.is_kw("cometa"))
    {
        bool lam = r.is_kw("lam"); r.next();
        AirPrd* p = r.new_prd(lam ? APRD_LAMBDA : APRD_COMETA); if (p == null) { return null; }
        p.binder_count = r.binder_list(&p.binders[0], 16);
        r.expect_p('.');
        p.body = r.cmd();
        return p;
    }
    if (r.is_kw("mu"))
    {
        r.next();
        AirPrd* p = r.new_prd(APRD_MU); if (p == null) { return null; }
        p.name = r.name(); r.expect_p('.');
        p.body = r.cmd();
        return p;
    }
    if (r.is_kw("alloca") || r.is_kw("load") || r.is_kw("gep"))
    {
        if (r.ver_major < 3) { r.fail("alloca/load/gep need `air 3.0`"); return null; }
        bool is_al = r.is_kw("alloca"); bool is_ld = r.is_kw("load"); r.next();
        AirPrd* p = r.new_prd(is_al ? APRD_ALLOCA : (is_ld ? APRD_LOAD : APRD_GEP)); if (p == null) { return null; }
        if (is_ld && r.eat_kw("volatile")) { p.bval = true; }
        if (!is_al && !is_ld) { r.expect_p('['); p.ty_arg = r.typ(); r.expect_p(']'); }
        r.expect_p('(');
        if (is_al) { p.ty_arg = r.typ(); }
        else
        {
            p.subs[0] = r.prd(); p.sub_count = 1;
            while (!r.failed && r.eat_p(','))
            {
                if (p.sub_count >= 16) { r.fail("more than 16 gep operands"); return null; }
                p.subs[p.sub_count] = r.prd(); p.sub_count++;
            }
        }
        r.expect_p(')'); return p;
    }
    if (r.is_kw("coerce"))
    {
        r.next(); r.expect_p('(');
        AirPrd* p = r.new_prd(APRD_COERCE); if (p == null) { return null; }
        p.subs[0] = r.prd(); p.sub_count = 1; r.expect_p(','); p.ty = r.typ();
        r.expect_p(')'); return p;
    }
    if (r.is_kw("sizeof") || r.is_kw("alignof") || r.is_kw("poison"))
    {
        AirPrdTag tg = r.is_kw("sizeof") ? APRD_SIZEOF : (r.is_kw("alignof") ? APRD_ALIGNOF : APRD_POISON);
        r.next(); r.expect_p('(');
        AirPrd* p = r.new_prd(tg); if (p == null) { return null; }
        p.ty = r.typ(); r.expect_p(')'); return p;
    }
    if (r.is_kw("offsetof"))
    {
        r.next(); r.expect_p('(');
        AirPrd* p = r.new_prd(APRD_OFFSETOF); if (p == null) { return null; }
        p.ty = r.typ(); r.expect_p(','); p.name = r.name(); r.expect_p(')'); return p;
    }
    if (r.is_kw("reify") || r.is_kw("quote"))
    {
        bool rf = r.is_kw("reify"); r.next();
        AirPrd* p = r.new_prd(rf ? APRD_REIFY : APRD_QUOTE); if (p == null) { return null; }
        p.body = r.cmd(); return p;
    }
    if (r.is_kw("eval") || r.is_kw("splice"))
    {
        bool ev = r.is_kw("eval"); r.next(); r.expect_p('(');
        AirPrd* p = r.new_prd(ev ? APRD_EVAL : APRD_SPLICE); if (p == null) { return null; }
        p.subs[0] = r.prd(); p.sub_count = 1; r.expect_p(')'); return p;
    }
    if (air_text::is_reserved(r.tb)) { r.fail("reserved word used as a variable (quote it with backticks)"); return null; }
    AirPrd* v = r.new_prd(APRD_VAR);
    if (v != null) { v.name = r.dup_tok(); }
    r.next();
    return v;
}

// ── Consumers ─────────────────────────────────────────────────────────────
fn AirCns* Rd.new_cns(Rd* r, AirCnsTag tag)
{
    AirCns* k = air_ir::air_new_AirCns(r.a);
    if (k == null) { r.fail("out of memory"); return null; }
    k.tag = tag;
    return k;
}
// pat [guard { cmd }] -> cmd ;   (repeated until the closing brace)
fn void Rd.branches(Rd* r, AirBranch** out, usz* count, usz cap)
{
    r.expect_p('{');
    while (!r.failed && !r.is_p('}'))
    {
        if (*count >= cap) { r.fail("more than 64 branches"); return; }
        AirBranch* b = air_ir::air_new_AirBranch(r.a);
        b.pat = r.pat();
        if (r.is_kw("guard"))
        {
            r.next(); r.expect_p('{'); b.guard = r.cmd(); r.expect_p('}');
        }
        if (r.failed) { return; }
        if (r.kind != T_ARROW) { r.fail("expected '->' in a branch"); return; }
        r.next();
        b.body = r.cmd();
        r.expect_p(';');
        out[*count] = b; *count = *count + 1;
    }
    r.expect_p('}');
}
fn AirCns* Rd.tailed(Rd* r, AirCnsTag tag)
{
    AirCns* k = r.new_cns(tag); if (k == null) { return null; }
    r.expect_mid();
    k.tail = r.cns();
    return k;
}
fn AirCns* Rd.cns(Rd* r)
{
    if (r.failed) { return null; }
    AirArena* a = r.a;
    if (r.kind == T_QID || (r.kind == T_ID && !air_text::is_reserved(r.tb)))
    {
        // a covariable, or a variable producer that starts a stack `x . k`
        char* nm = r.dup_tok();
        r.next();
        if (r.kind == T_MID || r.is_p(':'))
        {
            AirPrd* v = r.new_prd(APRD_VAR); if (v == null) { return null; }
            v.name = nm;
            if (r.eat_p(':')) { v.ty = r.typ(); }
            r.expect_mid();
            AirCns* k = r.new_cns(ACNS_STACK); if (k == null) { return null; }
            k.prd = v; k.tail = r.cns();
            return k;
        }
        AirCns* cv = r.new_cns(ACNS_COVAR); if (cv != null) { cv.name = nm; }
        return cv;
    }
    if (r.kind == T_ID)
    {
        if (r.is_kw("nil")) { r.next(); return null; }
        if (r.is_kw("fst"))     { r.next(); return r.tailed(ACNS_FST); }
        if (r.is_kw("snd"))     { r.next(); return r.tailed(ACNS_SND); }
        if (r.is_kw("deref"))   { r.next(); return r.tailed(ACNS_DEREF); }
        if (r.is_kw("default")) { r.next(); return r.tailed(ACNS_DEFAULT); }
        if (r.is_kw("share"))   { r.next(); return r.tailed(ACNS_SHARE); }
        if (r.is_kw("erase"))   { r.next(); return r.tailed(ACNS_ERASE); }
        if (r.is_kw("call"))    { r.next(); return r.tailed(ACNS_CALL); }
        if (r.is_kw("proj"))
        {
            r.next();
            AirCns* k = r.new_cns(ACNS_PROJ); if (k == null) { return null; }
            k.idx = r.int_(); r.expect_mid(); k.tail = r.cns(); return k;
        }
        if (r.is_kw("field"))
        {
            r.next();
            AirCns* k = r.new_cns(ACNS_FIELD); if (k == null) { return null; }
            k.name = r.name(); r.expect_p('#'); k.idx = r.int_(); r.expect_mid(); k.tail = r.cns(); return k;
        }
        if (r.is_kw("index"))
        {
            r.next(); r.expect_p('(');
            AirCns* k = r.new_cns(ACNS_INDEX); if (k == null) { return null; }
            k.prd = r.prd(); r.expect_p(';'); k.idx = r.int_(); r.expect_p(')');
            r.expect_mid(); k.tail = r.cns(); return k;
        }
        if (r.is_kw("store"))
        {
            r.next(); r.expect_p('(');
            AirCns* k = r.new_cns(ACNS_STORE); if (k == null) { return null; }
            k.prd = r.prd(); r.expect_p(';'); k.idx = r.int_(); r.expect_p(')');
            r.expect_mid(); k.tail = r.cns(); return k;
        }
        if (r.is_kw("as"))
        {
            r.next(); r.expect_p('(');
            AirCns* k = r.new_cns(ACNS_ASCRIBE); if (k == null) { return null; }
            k.ty = r.typ(); r.expect_p(')');
            r.expect_mid(); k.tail = r.cns(); return k;
        }
        if (r.is_kw("case"))
        {
            r.next();
            AirCns* k = r.new_cns(ACNS_CASE); if (k == null) { return null; }
            if (r.eat_kw("dense")) { k.dense_switch = true; }
            r.branches(&k.branches[0], &k.branch_count, 64);
            return k;
        }
        if (r.is_kw("cocase"))
        {
            r.next();
            AirCns* k = r.new_cns(ACNS_COCASE); if (k == null) { return null; }
            r.expect_p('{');
            while (!r.failed && !r.is_p('}'))
            {
                if (k.cobranch_count >= 64) { r.fail("more than 64 cobranches"); return null; }
                AirCoBranch* cb = air_ir::air_new_AirCoBranch(a);
                r.expect_p('.');
                cb.dtor_name = r.name();
                cb.binder_count = r.name_list(&cb.binders[0], 16);
                if (r.kind != T_ARROW) { r.fail("expected '->' in a cobranch"); return null; }
                r.next();
                cb.body = r.cmd();
                r.expect_p(';');
                k.cobranches[k.cobranch_count] = cb; k.cobranch_count++;
            }
            r.expect_p('}');
            return k;
        }
        if (r.is_kw("comu"))
        {
            r.next();
            AirCns* k = r.new_cns(ACNS_COMU); if (k == null) { return null; }
            k.bind = r.name(); r.expect_p('.');
            k.body = r.cmd(); return k;
        }
    }
    // otherwise a producer followed by the stack separator:  p . k
    AirPrd* p = r.prd();
    if (r.failed) { return null; }
    AirCns* k = r.new_cns(ACNS_STACK); if (k == null) { return null; }
    r.expect_mid();
    k.prd = p; k.tail = r.cns();
    return k;
}

// ── Commands ──────────────────────────────────────────────────────────────
fn AirCmd* Rd.new_cmd(Rd* r, AirCmdTag tag)
{
    AirCmd* c = air_ir::air_new_AirCmd(r.a);
    if (c == null) { r.fail("out of memory"); return null; }
    c.tag = tag;
    return c;
}
fn AirCmd* Rd.braced(Rd* r, AirCmdTag tag)
{
    AirCmd* c = r.new_cmd(tag); if (c == null) { return null; }
    r.expect_p('{'); c.body = r.cmd(); r.expect_p('}');
    return c;
}
fn int Rd.order(Rd* r)
{
    if (r.kind == T_ID)
    {
        for (int i = 0; i < 5; i++)
        {
            if (air_text::streq(r.tb, air_text::atomic_order_name(i))) { r.next(); return i; }
        }
    }
    r.fail("expected a memory-order name");
    return 0;
}
// AIR 2.1: syscall/asm/atomic end with ` \xc2\xb7 k` (result continuation). A 2.0 file has none
// and means "result discarded" (cns stays null); a 2.1 file must carry one.
fn void Rd.result(Rd* r, AirCmd* c)
{
    if (r.kind == T_MID) { r.next(); c.cns = r.cns(); }
    else if (r.ver_minor >= 1) { r.fail("expected ` \xc2\xb7 continuation` after a syscall/asm/atomic (AIR 2.1)"); }
}
fn AirCmd* Rd.cmd(Rd* r)
{
    if (r.failed) { return null; }
    if (r.is_p('<'))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_CUT); if (c == null) { return null; }
        c.prd = r.prd();
        if (!r.failed && !r.eat_p('|')) { r.fail("expected '|' in a cut"); return null; }
        c.cns = r.cns();
        r.expect_p('>');
        return c;
    }
    if (r.kind != T_ID) { r.fail("expected a command"); return null; }
    if (r.is_kw("nil")) { r.next(); return null; }
    if (r.is_kw("mu") || r.is_kw("mu~"))
    {
        bool tilde = r.is_kw("mu~"); r.next();
        AirCmd* c = r.new_cmd(tilde ? ACMD_MUTILDE : ACMD_MU); if (c == null) { return null; }
        c.binder = r.name(); r.expect_p('.'); c.body = r.cmd(); return c;
    }
    if (r.is_kw("jump"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_JUMP); if (c == null) { return null; }
        c.target_label = r.name();
        c.jump_arg_count = r.name_list(&c.jump_args[0], 16);
        return c;
    }
    if (r.is_kw("seq"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_SEQ); if (c == null) { return null; }
        r.expect_p('{'); c.body = r.cmd(); r.expect_p(';'); c.next = r.cmd(); r.expect_p('}');
        return c;
    }
    if (r.is_kw("block"))     { r.next(); return r.braced(ACMD_BLOCK); }
    if (r.is_kw("unsafe"))    { r.next(); return r.braced(ACMD_UNSAFE); }
    if (r.is_kw("unchecked")) { r.next(); return r.braced(ACMD_UNCHECKED); }
    if (r.is_kw("comptime"))  { r.next(); return r.braced(ACMD_COMPTIME); }
    if (r.is_kw("defer"))     { r.next(); return r.braced(ACMD_DEFER); }
    if (r.is_kw("while"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_WHILE); if (c == null) { return null; }
        c.prd = r.prd(); r.expect_kw("do"); r.expect_p('{'); c.body = r.cmd(); r.expect_p('}');
        return c;
    }
    if (r.is_kw("for"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_FOR); if (c == null) { return null; }
        c.binder = r.name(); r.expect_kw("in"); c.prd = r.prd();
        r.expect_kw("do"); r.expect_p('{'); c.body = r.cmd(); r.expect_p('}');
        return c;
    }
    if (r.is_kw("let"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_LET); if (c == null) { return null; }
        c.binder = r.name(); r.expect_p('='); c.prd = r.prd();
        r.expect_kw("in"); c.body = r.cmd(); return c;
    }
    if (r.is_kw("letrec"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_LETREC); if (c == null) { return null; }
        r.expect_p('(');
        if (!r.is_p(')'))
        {
            while (!r.failed)
            {
                if (c.mbinder_count >= 16) { r.fail("more than 16 letrec bindings"); return null; }
                c.mbinders[c.mbinder_count] = r.binder(); c.mbinder_count++;
                r.expect_p('=');
                c.prds[c.prd_count] = r.prd(); c.prd_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p(')'); r.expect_kw("in"); c.body = r.cmd(); return c;
    }
    if (r.is_kw("if"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_IF); if (c == null) { return null; }
        c.prd = r.prd(); r.expect_kw("then"); c.then_c = r.cmd();
        r.expect_kw("else"); c.else_c = r.cmd(); return c;
    }
    if (r.is_kw("match"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_MATCH); if (c == null) { return null; }
        if (r.eat_kw("dense")) { c.dense_switch = true; }
        c.prd = r.prd();
        r.branches(&c.branches[0], &c.branch_count, 64);
        return c;
    }
    if (r.is_kw("handle"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_HANDLE); if (c == null) { return null; }
        r.expect_p('{'); c.handled = r.cmd(); r.expect_p('}');
        r.branches(&c.branches[0], &c.branch_count, 64);
        return c;
    }
    if (r.is_kw("perform"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_PERFORM); if (c == null) { return null; }
        c.eff_op = r.name(); r.expect_p('('); c.prd = r.prd(); r.expect_p(')');
        // AIR 2.2: ` \xc2\xb7 k` receives the value the handler resumes with (2.0/2.1 files have none)
        if (r.kind == T_MID) { r.next(); c.cns = r.cns(); }
        else if (r.ver_minor >= 2) { r.fail("expected ` \xc2\xb7 continuation` after a perform (AIR 2.2)"); }
        return c;
    }
    if (r.is_kw("resume") || r.is_kw("assert") || r.is_kw("assume") || r.is_kw("ret"))
    {
        AirCmdTag tg = r.is_kw("resume") ? ACMD_RESUME : (r.is_kw("assert") ? ACMD_ASSERT : (r.is_kw("assume") ? ACMD_ASSUME : ACMD_RET));
        r.next(); r.expect_p('(');
        AirCmd* c = r.new_cmd(tg); if (c == null) { return null; }
        c.prd = r.prd(); r.expect_p(')'); return c;
    }
    if (r.is_kw("ub"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_UB); if (c == null) { return null; }
        if (r.kind == T_STR) { c.ub_msg = r.dup_tok(); r.next(); }
        else if (r.is_kw("nil")) { r.next(); }
        else { r.fail("expected a string or nil after ub"); }
        return c;
    }
    if (r.is_kw("trap")) { r.next(); return r.new_cmd(ACMD_TRAP); }
    if (r.is_kw("nop"))  { r.next(); return r.new_cmd(ACMD_NOP); }
    if (r.is_kw("break") || r.is_kw("continue"))
    {
        bool br = r.is_kw("break"); r.next();
        AirCmd* c = r.new_cmd(br ? ACMD_BREAK : ACMD_CONTINUE); if (c == null) { return null; }
        c.target_label = r.name(); return c;
    }
    if (r.is_kw("label"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_LABEL); if (c == null) { return null; }
        c.binder = r.name();
        c.mbinder_count = r.binder_list(&c.mbinders[0], 16);
        r.expect_p('.'); c.body = r.cmd(); return c;
    }
    if (r.is_kw("asm"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_ASM); if (c == null) { return null; }
        if (r.eat_kw("intel")) { c.asm_dialect = 1; }
        else if (r.eat_kw("att")) { c.asm_dialect = 2; }
        if (r.kind == T_STR) { c.asm_text = r.dup_tok(); r.next(); }
        else if (r.is_kw("nil")) { r.next(); }
        else { r.fail("expected asm text"); return null; }
        if (r.kind == T_STR) { c.asm_cons = r.dup_tok(); r.next(); r.expect_p(':'); r.expect_p('['); c.asm_ret = r.typ(); r.expect_p(']'); }   // AIR 3.0
        r.expect_p('(');
        if (!r.is_p(')'))
        {
            while (!r.failed)
            {
                if (c.prd_count >= 16) { r.fail("more than 16 asm operands"); return null; }
                c.prds[c.prd_count] = r.prd(); c.prd_count++;
                if (r.eat_p(',')) { continue; }
                break;
            }
        }
        r.expect_p(')');
        r.result(c);
        return c;
    }
    if (r.is_kw("syscall"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_SYSCALL); if (c == null) { return null; }
        r.expect_p('(');
        c.prd = r.prd();
        while (r.eat_p(','))
        {
            if (c.prd_count >= 16) { r.fail("more than 16 syscall operands"); return null; }
            c.prds[c.prd_count] = r.prd(); c.prd_count++;
        }
        r.expect_p(')');
        r.result(c);
        return c;
    }
    if (r.is_kw("atomic"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_ATOMIC); if (c == null) { return null; }
        int op = -1;
        if (r.kind == T_ID)
        {
            for (int i = 0; i < 14; i++) { if (air_text::streq(r.tb, air_text::atomic_op_name(i))) { op = i; } }
        }
        if (op < 0) { r.fail("expected an atomic operation name"); return null; }
        r.next();
        c.atomic_op = op; c.atomic_order = r.order();
        r.expect_p('('); c.prd = r.prd();
        while (!r.failed && r.eat_p(','))
        {
            if (c.prd_count >= 16) { r.fail("more than 16 atomic operands"); return null; }
            c.prds[c.prd_count] = r.prd(); c.prd_count++;
        }
        r.expect_p(')');
        r.result(c);
        return c;
    }
    if (r.is_kw("store"))
    {
        if (r.ver_major < 3) { r.fail("store(p, v) needs `air 3.0`"); return null; }
        r.next();
        bool svol = r.eat_kw("volatile");
        r.expect_p('(');
        AirCmd* c = r.new_cmd(ACMD_STORE); if (c == null) { return null; }
        c.vol = svol;
        c.prds[0] = r.prd(); r.expect_p(','); c.prds[1] = r.prd(); c.prd_count = 2;
        r.expect_p(')'); return c;
    }
    if (r.is_kw("fence"))
    {
        r.next();
        AirCmd* c = r.new_cmd(ACMD_FENCE); if (c == null) { return null; }
        c.atomic_order = r.order(); return c;
    }
    r.fail("unknown command keyword");
    return null;
}

// ── Declarations ──────────────────────────────────────────────────────────
fn bool Rd.fields(Rd* r, AirField** out, usz* count, usz cap)
{
    r.expect_p('(');
    if (!r.is_p(')'))
    {
        while (!r.failed)
        {
            if (*count >= cap) { r.fail("more than 64 fields"); return false; }
            AirField* f = air_ir::air_new_AirField(r.a);
            while (!r.failed)
            {
                if (r.eat_kw("mut")) { f.is_mut = true; continue; }
                if (r.eat_kw("lin")) { f.mult = AMULT_LIN; continue; }
                if (r.eat_kw("aff")) { f.mult = AMULT_AFF; continue; }
                break;
            }
            f.name = r.name(); r.expect_p(':'); f.ty = r.typ();
            out[*count] = f; *count = *count + 1;
            if (r.eat_p(',')) { continue; }
            break;
        }
    }
    r.expect_p(')');
    return !r.failed;
}
fn void Rd.typarams(Rd* r, AirDecl* d)
{
    if (!r.eat_p('[')) { return; }
    while (!r.failed)
    {
        if (d.typaram_count >= 16) { r.fail("more than 16 type parameters"); return; }
        d.typarams[d.typaram_count] = r.binder(); d.typaram_count++;
        if (r.eat_p(',')) { continue; }
        break;
    }
    r.expect_p(']');
}
fn bool Rd.decl(Rd* r, AirModule* m)
{
    if (r.failed) { return false; }
    AirArena* a = r.a;
    bool is_pub = false; bool is_extern = false; bool is_fastcc = false; bool is_varargs = false;
    bool ro = false; bool facts = false; char* link = null;
    char*[8] pend_attr_n; char*[8] pend_attr_s; long[8] pend_attr_i; bool[8] pend_attr_h; usz pend_attr_c = 0;
    while (!r.failed && r.kind == T_ID)
    {
        if (r.eat_kw("pub")) { is_pub = true; continue; }
        if (r.eat_kw("extern")) { is_extern = true; continue; }
        if (r.eat_kw("fastcc")) { is_fastcc = true; continue; }
        if (r.eat_kw("varargs")) { is_varargs = true; continue; }
        if (r.eat_kw("readonly")) { ro = true; continue; }
        if (r.is_kw("attr"))
        {
            r.next();
            char* an = r.name();
            if (pend_attr_c >= 8) { r.fail("more than 8 attributes on a declaration"); continue; }
            if (r.kind == T_STR) { char* sv = r.dup_tok(); r.next(); pend_attr_n[pend_attr_c] = an; pend_attr_s[pend_attr_c] = sv; pend_attr_i[pend_attr_c] = 0; pend_attr_h[pend_attr_c] = false; }
            else if (r.kind == T_INT) { long iv = r.ival; r.next(); pend_attr_n[pend_attr_c] = an; pend_attr_s[pend_attr_c] = null; pend_attr_i[pend_attr_c] = iv; pend_attr_h[pend_attr_c] = true; }
            else { pend_attr_n[pend_attr_c] = an; pend_attr_s[pend_attr_c] = null; pend_attr_i[pend_attr_c] = 0; pend_attr_h[pend_attr_c] = false; }
            pend_attr_c++;
            continue;
        }
        if (r.is_kw("facts"))
        {
            r.next();
            if (r.is_kw("ast_final") || r.is_kw("air_checked")) { facts = true; r.next(); }
            else { r.fail("expected ast_final or air_checked after facts"); }
            continue;
        }
        if (r.is_kw("link"))
        {
            r.next();
            if (r.kind == T_STR) { link = r.dup_tok(); r.next(); } else { r.fail("expected a link-name string"); }
            continue;
        }
        break;
    }
    if (r.failed) { return false; }
    if (r.is_kw("module"))
    {
        r.next();
        char* nm = r.name(); r.expect_p(';');
        AirDecl* d = air_ir::air_mk_decl(a, ADECL_MODULE, nm); d.module_name = nm;
        d.is_pub = is_pub;
        return m.add_decl(d);
    }
    if (r.is_kw("import"))
    {
        r.next();
        AirDecl* d = air_ir::air_mk_decl(a, ADECL_IMPORT, null);
        if (r.kind == T_STR) { d.name = r.dup_tok(); d.import_path = d.name; r.next(); }
        else if (r.is_kw("nil")) { r.next(); }
        else { r.fail("expected an import path string"); return false; }
        if (r.eat_kw("as")) { d.import_alias = r.name(); }
        if (r.eat_kw("glob")) { d.import_glob = true; }
        r.expect_p(';');
        return m.add_decl(d);
    }
    if (r.is_kw("def") || r.is_kw("defco") || r.is_kw("declare"))
    {
        AirDeclTag tg = r.is_kw("def") ? ADECL_DEF : (r.is_kw("defco") ? ADECL_DEFCO : ADECL_DECLARE);
        r.next();
        AirDecl* d = air_ir::air_mk_decl(a, tg, r.name());
        d.is_pub = is_pub; d.is_extern = is_extern; d.is_fastcc = is_fastcc; d.is_varargs = is_varargs;
        d.extern_link = link; d.memory_readonly = ro;
        for (usz ai = 0; ai < pend_attr_c; ai++) { air_ir::air_add_attr(d, pend_attr_n[ai], pend_attr_s[ai], pend_attr_i[ai], pend_attr_h[ai]); }
        d.fact_state = facts ? AFACT_AST_FINAL : AFACT_UNKNOWN;   // claims are candidates, always
        r.typarams(d);
        d.param_count = r.binder_list(&d.params[0], 16);
        if (r.eat_p(':')) { d.ret_ty = r.typ(); }
        if (r.eat_p('=')) { d.def_body = r.cmd(); }
        r.expect_p(';');
        if (r.failed) { return false; }
        if (m.decl_count >= 4096) { r.fail("more than 4096 declarations"); return false; }
        return m.add_decl(d);
    }
    if (r.is_kw("global"))
    {
        if (r.ver_major < 3) { r.fail("global needs `air 3.0`"); return false; }
        r.next();
        AirDecl* d = air_ir::air_mk_decl(a, ADECL_GLOBAL, null);
        d.is_pub = is_pub; d.is_extern = is_extern;
        for (usz ai = 0; ai < pend_attr_c; ai++) { air_ir::air_add_attr(d, pend_attr_n[ai], pend_attr_s[ai], pend_attr_i[ai], pend_attr_h[ai]); }
        if (r.eat_kw("mut")) { d.g_mut = true; }
        d.name = r.name(); r.expect_p(':'); d.ret_ty = r.typ();
        if (r.eat_p('=')) { d.g_init = r.prd(); }
        r.expect_p(';');
        if (r.failed) { return false; }
        return m.add_decl(d);
    }
    if (r.is_kw("data") || r.is_kw("codata"))
    {
        bool is_data = r.is_kw("data"); r.next();
        AirDecl* d = air_ir::air_mk_decl(a, is_data ? ADECL_DATA : ADECL_CODATA, r.name());
        d.is_pub = is_pub;
        for (usz ai = 0; ai < pend_attr_c; ai++) { air_ir::air_add_attr(d, pend_attr_n[ai], pend_attr_s[ai], pend_attr_i[ai], pend_attr_h[ai]); }
        if (r.eat_kw("lin")) { d.mult = AMULT_LIN; } else if (r.eat_kw("aff")) { d.mult = AMULT_AFF; }
        r.typarams(d);
        r.expect_p('{');
        while (!r.failed && !r.is_p('}'))
        {
            if (is_data)
            {
                r.expect_kw("ctor");
                if (d.ctor_count >= 64) { r.fail("more than 64 constructors"); return false; }
                AirCtorDecl* c = air_ir::air_new_AirCtorDecl(a);
                c.name = r.name();
                r.fields(&c.fields[0], &c.field_count, 64);
                if (r.eat_p(':')) { c.result_ty = r.typ(); }
                r.expect_p(';');
                d.ctors[d.ctor_count] = c; d.ctor_count++;
            }
            else
            {
                r.expect_kw("op");
                if (d.dtor_count >= 64) { r.fail("more than 64 destructors"); return false; }
                AirDtorDecl* x = air_ir::air_new_AirDtorDecl(a);
                x.name = r.name();
                r.fields(&x.params[0], &x.param_count, 64);
                if (r.eat_p(':')) { x.return_ty = r.typ(); }
                r.expect_p(';');
                d.dtors[d.dtor_count] = x; d.dtor_count++;
            }
        }
        r.expect_p('}'); r.expect_p(';');
        if (r.failed) { return false; }
        return m.add_decl(d);
    }
    if (r.is_kw("effect"))
    {
        r.next();
        AirDecl* d = air_ir::air_mk_decl(a, ADECL_EFFECT, r.name());
        d.is_pub = is_pub;
        r.expect_p('{');
        while (!r.failed && !r.is_p('}'))
        {
            r.expect_kw("op");
            if (d.op_count >= 16) { r.fail("more than 16 effect operations"); return false; }
            AirEffectOp* o = air_ir::air_new_AirEffectOp(a);
            o.name = r.name(); r.expect_p(':'); o.op_ty = r.typ(); r.expect_p(';');
            d.ops[d.op_count] = o; d.op_count++;
        }
        r.expect_p('}'); r.expect_p(';');
        if (r.failed) { return false; }
        return m.add_decl(d);
    }
    r.fail("expected a declaration");
    return false;
}

// Parses `text` into `m` (which must NOT have been initialised: this function
// initialises it so its pre-registered libc declares are replaced by the file's
// own list). Returns true on success. On failure an error has been printed
// (unless `quiet`) and *line/*col describe where.
fn bool read_text(char* text, usz len, char* path, AirArena* a, AirModule* m, bool quiet, int* eline, int* ecol, char** emsg)
{
    Rd r;
    r.src = text; r.len = len; r.pos = 0; r.line = 1; r.col = 1;
    r.a = a; r.failed = false; r.path = path; r.quiet = quiet;
    r.errmsg = null; r.err_line = 0; r.err_col = 0;
    r.tb = (char*)malloc(len + 16);
    r.tlen = 0; r.tline = 1; r.tcol = 1; r.ver_minor = 0; r.ver_major = 2;
    if (r.tb == null) { return false; }
    r.next();
    // header:  air 2.0 NAME SOURCE ;
    r.expect_kw("air");
    if (!r.failed)
    {
        if (r.kind != T_FLOAT) { r.fail("expected the version after 'air'"); }
        else if (r.fval == 2.0) { r.ver_minor = 0; r.next(); }
        else if (r.fval == 2.1) { r.ver_minor = 1; r.next(); }
        else if (r.fval == 2.2) { r.ver_minor = 2; r.next(); }
        else if (r.fval == 3.0) { r.ver_major = 3; r.ver_minor = 2; r.next(); }   // 3.0 keeps every 2.2 rule
        else { r.fail("unsupported AIR version (this reader implements 2.0, 2.1, 2.2 and 3.0)"); }
    }
    char* mname = r.name();
    char* msrc = null;
    if (r.kind == T_STR) { msrc = r.dup_tok(); r.next(); }
    else if (r.is_kw("nil")) { r.next(); }
    else { r.fail("expected the source path string (or nil) in the header"); }
    r.expect_p(';');
    bool ok = false;
    if (!r.failed)
    {
        if (!m.init(a, mname == null ? "" : mname, msrc)) { r.fail("module init failed"); }
        m.decl_count = 0;    // the file lists every decl, including the libc declares
        m.low = (r.ver_major == 3);
    }
    while (!r.failed && r.kind != T_EOF)
    {
        if (!r.decl(m)) { if (!r.failed) { r.fail("declaration rejected"); } }
    }
    ok = !r.failed;
    if (eline != null) { *eline = r.err_line; }
    if (ecol != null) { *ecol = r.err_col; }
    if (emsg != null) { *emsg = r.errmsg; }
    free((void*)r.tb);
    return ok;
}

fn bool read_file(char* path, AirArena* a, AirModule* m, bool quiet)
{
    void* f = fopen(path, "rb");
    if (f == null)
    {
        if (!quiet) { void* se = fdopen(2, "w"); fprintf(se, "%s: air-read error: cannot open file\n", path); fflush(se); }
        return false;
    }
    fseek(f, 0, 2);
    long n = ftell(f);
    fseek(f, 0, 0);
    if (n < 0) { fclose(f); return false; }
    char* buf = (char*)malloc((usz)n + 1);
    if (buf == null) { fclose(f); return false; }
    usz got = fread((void*)buf, 1, (usz)n, f);
    fclose(f);
    buf[got] = 0;
    bool ok = read_text(buf, got, path, a, m, quiet, null, null, null);
    free((void*)buf);
    return ok;
}
