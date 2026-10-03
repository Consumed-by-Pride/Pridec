// ============================================================================
// air_write.c3 — canonical AIR 2.0 text writer (AirModule -> .air).
// ----------------------------------------------------------------------------
// This is the only producer of the `.air` file that backends consume. Unlike
// the human-oriented printer in air_emit.c3 it is a SERIALISATION: it prints
// every field a backend may read, never elides an administrative redex, never
// truncates a literal, and never prints a placeholder. If a node cannot be
// represented it is counted as a writer error and the caller must not publish
// the file — a lossy `.air` that looks fine is worse than none.
//
// Grammar: docs/specs/AIR.md. Vocabulary: air_text.c3.
// ============================================================================
module air_write;
import air_ir;
import air_text;

extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn int   fputs(char* s, void* f);
extern fn int   fputc(int c, void* f);
extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);
extern fn void* fdopen(int fd, char* mode);
extern fn char* getenv(char* name);
extern fn int   fflush(void* f);

struct AirW
{
    void* out;
    int   errs;
    char*[8] first_err;
    bool  dg_verbose;
    bool  dg_quiet;
    ulong dg_total;
    bool  dg_on;     // AIR_DIGEST debugging aid: see AirW.dig
    ulong dg;
}

// Debugging aid (env AIR_DIGEST=1): folds every node's raw non-pointer bytes into
// a per-declaration digest printed as a comment. Two modules whose text is equal
// but whose digests differ carry state the text does not (the round-trip hunt).
// Pointer words are reduced to "present or not"; the id word is ignored.
fn void AirW.dig(AirW* w, void* node, usz size_)
{
    if (!w.dg_on || node == null) { return; }
    ulong* words = (ulong*)node;
    bool verbose = w.dg_verbose;
    if (verbose) { fprintf(w.out, "// node %lu bytes:", (ulong)size_); }
    for (usz i = 0; i < size_ / 8; i++)
    {
        ulong x = words[i];
        if (i == 0) { x = x >> 32; }
        else if (x > 0xFFFFFFFFUL) { x = 1; }
        w.dg = (w.dg ^ x) * 1099511628211UL + (ulong)i;
        if (verbose && x != 0) { fprintf(w.out, " %lu:%lx", (ulong)i, x); }
    }
    if (verbose) { fprintf(w.out, "\n"); }
}

fn void AirW.s(AirW* w, char* t) { fputs(t, w.out); }
fn void AirW.c(AirW* w, char ch) { fputc((int)ch, w.out); }
fn void AirW.nl(AirW* w, int depth)
{
    fputc('\n', w.out);
    for (int i = 0; i < depth; i++) { fputs("  ", w.out); }
}
fn void AirW.err(AirW* w, char* what)
{
    if (w.errs < 8) { w.first_err[(usz)w.errs] = what; }
    w.errs++;
}
fn void AirW.int_(AirW* w, long v) { fprintf(w.out, "%ld", v); }

fn void AirW.esc_byte(AirW* w, char ch, char quote)
{
    if (ch == '\\') { w.s("\\\\"); return; }
    if (ch == quote) { w.c('\\'); w.c(ch); return; }
    if (ch >= 32 && ch < 127) { w.c(ch); return; }
    fprintf(w.out, "\\x%02x", (int)((uint)ch & 255));
}

// A name: bare when it is a plain non-reserved identifier, otherwise quoted
// with backticks. A null pointer is the literal `nil`.
fn void AirW.name(AirW* w, char* s)
{
    if (s == null) { w.s("nil"); return; }
    if (air_text::is_bare_ident(s)) { w.s(s); return; }
    w.c('`');
    usz i = 0;
    while (s[i] != 0) { w.esc_byte(s[i], '`'); i++; }
    w.c('`');
}
fn void AirW.lit(AirW* w, char* buf, usz len)
{
    w.c('"');
    for (usz i = 0; i < len; i++) { w.esc_byte(buf[i], '"'); }
    w.c('"');
}
fn void AirW.opt_str(AirW* w, char* s)
{
    if (s == null) { w.s("nil"); return; }
    usz n = 0; while (s[n] != 0) { n++; }
    w.lit(s, n);
}

// ── Types ─────────────────────────────────────────────────────────────────
fn void AirW.typ(AirW* w, AirTyp* t)
{
    if (t == null) { w.s("nil"); return; }
    w.dig(t, AirTyp::size);
    switch (t.tag)
    {
        case ATYP_INVALID: case ATYP_RECORD: case ATYP_MULT:
            w.err("type tag not representable in AIR 2.0 (record/mult/invalid)");
            w.s("invalid"); return;
        default: break;
    }
    w.s(air_text::typ_kw(t.tag));
    if (air_text::typ_has_name(t.tag)) { w.c(' '); w.name(t.name); }
    else if (t.name != null) { w.err("type carries a name its tag cannot print"); }
    if (air_text::typ_has_ival(t.tag)) { w.s(" #"); w.int_(t.ival); }
    else if (t.ival != 0) { w.err("type carries an integer its tag cannot print"); }
    if (t.rec_field_count != 0 || t.refine_extra != null || t.eff_name != null || t.mult_exact != 0)
    {
        w.err("type carries a payload AIR 2.0 does not define (rec_fields/refine_extra/eff_name/mult)");
    }
    if (t.arg_count > 0)
    {
        w.c('(');
        for (usz i = 0; i < t.arg_count; i++)
        {
            if (i > 0) { w.s(", "); }
            w.typ(t.args[i]);
        }
        w.c(')');
    }
    if (t.eff_tail != null) { w.s(" tail("); w.typ(t.eff_tail); w.c(')'); }
}

// ── Binders ───────────────────────────────────────────────────────────────
fn void AirW.binder(AirW* w, AirBinder* b)
{
    if (b == null) { w.s("nil"); return; }
    w.dig(b, AirBinder::size);
    if (b.is_mutable) { w.s("mut "); }
    if (b.no_capture) { w.s("nocapture "); }
    switch (b.mult)
    {
        case AMULT_UNR:   break;
        case AMULT_LIN:   w.s("lin "); break;
        case AMULT_AFF:   w.s("aff "); break;
        case AMULT_EXACT: w.s("exact("); w.int_((long)b.mult_exact); w.s(") "); break;
    }
    w.name(b.name);
    if (b.ty != null) { w.s(" : "); w.typ(b.ty); }
}
fn void AirW.binders(AirW* w, AirBinder** bs, usz n)
{
    w.c('(');
    for (usz i = 0; i < n; i++) { if (i > 0) { w.s(", "); } w.binder(bs[i]); }
    w.c(')');
}
fn void AirW.names(AirW* w, char** ns, usz n)
{
    w.c('(');
    for (usz i = 0; i < n; i++) { if (i > 0) { w.s(", "); } w.name(ns[i]); }
    w.c(')');
}

// ── Patterns ──────────────────────────────────────────────────────────────
fn void AirW.pat(AirW* w, AirPat* p)
{
    if (p == null) { w.s("nil"); return; }
    w.dig(p, AirPat::size);
    switch (p.tag)
    {
        case APAT_WILD:   w.c('_'); return;
        case APAT_BIND:   w.s("bind "); w.name(p.name); return;
        case APAT_INT:    w.int_(p.ival); return;
        case APAT_BOOL:   w.s(p.ival != 0 ? "true" : "false"); return;
        case APAT_CHAR:   w.s("char("); w.int_(p.ival); w.c(')'); return;
        case APAT_STRING:
        {
            usz n = 0; if (p.name != null) { while (p.name[n] != 0) { n++; } }
            if (p.name == null) { w.s("nil"); } else { w.lit(p.name, n); }
            return;
        }
        case APAT_FLOAT:  w.float_lit(p.fval); return;
        case APAT_TUPLE:
        case APAT_ARRAY:
        {
            w.s(p.tag == APAT_TUPLE ? "tuple(" : "array(");
            for (usz i = 0; i < p.sub_count; i++) { if (i > 0) { w.s(", "); } w.pat(p.sub[i]); }
            w.c(')');
            return;
        }
        case APAT_RECORD:
        {
            w.s("record{");
            for (usz i = 0; i < p.field_count; i++)
            {
                if (i > 0) { w.s(", "); }
                AirFieldInit* f = p.fields[i];
                if (f == null) { w.err("null record-pattern field"); w.s("nil"); continue; }
                w.name(f.name);
                if (f.value != null) { w.err("record-pattern field with a payload"); }
            }
            w.c('}');
            return;
        }
        case APAT_VARIANT:
        {
            w.s("ctor "); w.name(p.name);
            if (p.sub_count > 0)
            {
                w.c('(');
                for (usz i = 0; i < p.sub_count; i++) { if (i > 0) { w.s(", "); } w.pat(p.sub[i]); }
                w.c(')');
            }
            return;
        }
        case APAT_AS:
        {
            // `as(<pat>, NAME)` — sub[0] is the inner pattern, name the alias.
            w.s("as("); w.pat(p.sub_count > 0 ? p.sub[0] : null); w.s(", "); w.name(p.name); w.c(')');
            if (p.as_pat != null) { w.err("as-pattern with as_pat payload"); }
            return;
        }
        case APAT_OR:
        {
            w.s("or("); w.pat(p.sub_count > 0 ? p.sub[0] : null); w.s(", "); w.pat(p.or_alt); w.c(')');
            return;
        }
        case APAT_REF:
        {
            w.s("ref("); w.pat(p.sub_count > 0 ? p.sub[0] : null); w.c(')');
            return;
        }
        case APAT_REST:   w.s("rest"); return;
        default:
            w.err("pattern tag not representable in AIR 2.0 (range/invalid)");
            w.c('_');
            return;
    }
}
fn void AirW.float_lit(AirW* w, double v)
{
    char[64] b;
    if (!(v == v) || (v - v) != 0.0) { w.err("non-finite float literal"); w.s("0.0"); return; }
    snprintf(&b[0], 64, "%.17g", v);
    bool dot = false;
    for (usz i = 0; b[i] != 0; i++) { if (b[i] == '.' || b[i] == 'e' || b[i] == 'E') { dot = true; } }
    w.s(&b[0]);
    if (!dot) { w.s(".0"); }
}

// ── Producers ─────────────────────────────────────────────────────────────
// AIR 2.1: syscall/asm/atomic deliver their result to a consumer (` \xc2\xb7 k`). A missing
// consumer is a writer error: the result of the primitive would be unreachable.
fn void AirW.result(AirW* w, AirCns* k, int d)
{
    if (k == null) { w.err("syscall/asm/atomic/perform without a result continuation (AIR 2.1/2.2)"); return; }
    w.s(" \xc2\xb7 "); w.cns(k, d);
}
fn void AirW.prds(AirW* w, AirPrd** ps, usz n, int d)
{
    w.c('(');
    for (usz i = 0; i < n; i++) { if (i > 0) { w.s(", "); } w.prd(ps[i], d); }
    w.c(')');
}
// A producer may carry the type the front end resolved for it (`5 : i32`).
// SIZEOF/ALIGNOF/POISON/COERCE/OFFSETOF already print their `ty` as an operand;
// every other producer prints it as a trailing annotation. Backends use it, e.g.
// to size integer literals, so it is part of the contract, not decoration.
fn bool prd_ty_is_operand(AirPrdTag t)
{
    return t == APRD_SIZEOF || t == APRD_ALIGNOF || t == APRD_POISON || t == APRD_COERCE || t == APRD_OFFSETOF;
}
fn void AirW.prd(AirW* w, AirPrd* p, int d)
{
    if (p == null) { w.s("nil"); return; }
    w.prd_core(p, d);
    if (!prd_ty_is_operand(p.tag) && p.ty != null) { w.s(" : "); w.typ(p.ty); }
}
fn void AirW.prd_core(AirW* w, AirPrd* p, int d)
{
    w.dig(p, AirPrd::size);
    switch (p.tag)
    {
        case APRD_VAR:   w.name(p.name); return;
        case APRD_CON:
        {
            w.s("con "); w.name(p.name);
            if (p.sub_count > 0) { w.prds(&p.subs[0], p.sub_count, d); }
            return;
        }
        case APRD_INT:   w.int_(p.ival); return;
        case APRD_FLOAT: w.float_lit(p.fval); return;
        case APRD_BOOL:  w.s(p.bval ? "true" : "false"); return;
        case APRD_CHAR:  w.s("char("); w.int_(p.ival); w.c(')'); return;
        case APRD_STRING:
        {
            if (p.name == null) { w.err("string literal without bytes"); w.s("\"\""); return; }
            w.lit(p.name, (usz)p.bytes_len);
            return;
        }
        case APRD_BYTES:
        {
            w.c('b');
            w.lit(p.bytes == null ? "" : p.bytes, p.bytes == null ? 0 : p.bytes_len);
            return;
        }
        case APRD_UNIT:  w.s("unit"); return;
        case APRD_NULL:  w.s("null"); return;
        case APRD_TUPLE: w.s("tuple"); w.prds(&p.subs[0], p.sub_count, d); return;
        case APRD_ARRAY: w.s("array"); w.prds(&p.subs[0], p.sub_count, d); return;
        case APRD_RECORD:
        {
            w.s("record{");
            for (usz i = 0; i < p.rec_init_count; i++)
            {
                if (i > 0) { w.s(", "); }
                AirFieldInit* f = p.rec_inits[i];
                if (f == null) { w.err("null record field"); w.s("nil = nil"); continue; }
                w.name(f.name); w.s(" = "); w.prd(f.value, d);
            }
            w.c('}');
            return;
        }
        case APRD_INL:
        case APRD_INR:
        {
            w.s(p.tag == APRD_INL ? "inl[" : "inr[");
            w.typ(p.ty_arg); w.s("](");
            if (p.sub_count != 1) { w.err("inl/inr needs exactly one payload"); w.s("nil"); }
            else { w.prd(p.subs[0], d); }
            w.c(')');
            return;
        }
        case APRD_LAMBDA:
        {
            w.s("lam"); w.binders(&p.binders[0], p.binder_count);
            w.s(".");  w.nl(d + 1); w.cmd(p.body, d + 1);
            return;
        }
        case APRD_MU:
        {
            w.s("mu "); w.name(p.name); w.s(".");
            w.nl(d + 1); w.cmd(p.body, d + 1);
            return;
        }
        case APRD_COMETA:
        {
            w.s("cometa"); w.binders(&p.binders[0], p.binder_count);
            w.s("."); w.nl(d + 1); w.cmd(p.body, d + 1);
            return;
        }
        case APRD_BINOP:
        {
            if (p.sub_count != 2) { w.err("binop needs two operands"); }
            w.c('('); w.s(air_text::binop_name(p.bop)); w.c(' ');
            w.prd(p.sub_count > 0 ? p.subs[0] : null, d); w.c(' ');
            w.prd(p.sub_count > 1 ? p.subs[1] : null, d); w.c(')');
            return;
        }
        case APRD_UNOP:
        {
            if (p.sub_count != 1) { w.err("unop needs one operand"); }
            w.c('('); w.s(air_text::unop_name(p.uop)); w.c(' ');
            w.prd(p.sub_count > 0 ? p.subs[0] : null, d); w.c(')');
            return;
        }
        case APRD_COERCE:
        {
            w.s("coerce("); w.prd(p.sub_count > 0 ? p.subs[0] : null, d);
            w.s(", "); w.typ(p.ty); w.c(')');
            return;
        }
        case APRD_SIZEOF:  w.s("sizeof(");  w.typ(p.ty); w.c(')'); return;
        case APRD_ALIGNOF: w.s("alignof("); w.typ(p.ty); w.c(')'); return;
        case APRD_OFFSETOF:
        {
            w.s("offsetof("); w.typ(p.ty); w.s(", "); w.name(p.name); w.c(')');
            return;
        }
        case APRD_REIFY:  w.s("reify"); w.nl(d + 1); w.cmd(p.body, d + 1); return;
        case APRD_QUOTE:  w.s("quote"); w.nl(d + 1); w.cmd(p.body, d + 1); return;
        case APRD_EVAL:   w.s("eval(");   w.prd(p.sub_count > 0 ? p.subs[0] : null, d); w.c(')'); return;
        case APRD_SPLICE: w.s("splice("); w.prd(p.sub_count > 0 ? p.subs[0] : null, d); w.c(')'); return;
        case APRD_POISON: w.s("poison("); w.typ(p.ty); w.c(')'); return;
        case APRD_UNREACHABLE_VAL: w.s("unreachable"); return;
        case APRD_ALLOCA: w.s("alloca("); w.typ(p.ty_arg); w.c(')'); return;
        case APRD_LOAD:
            if (p.sub_count != 1) { w.err("load needs one operand"); }
            w.s(p.bval ? "load volatile(" : "load("); w.prd(p.sub_count > 0 ? p.subs[0] : null, d); w.c(')'); return;
        case APRD_GEP:
        {
            if (p.sub_count < 1) { w.err("gep needs a base pointer"); }
            w.s("gep["); w.typ(p.ty_arg); w.s("]("); w.prd(p.sub_count > 0 ? p.subs[0] : null, d);
            for (usz i = 1; i < p.sub_count; i++) { w.s(", "); w.prd(p.subs[i], d); }
            w.c(')'); return;
        }
        default:
            w.err("producer tag not representable in AIR 2.0");
            w.s("nil");
            return;
    }
}

// ── Consumers ─────────────────────────────────────────────────────────────
fn void AirW.branches(AirW* w, AirBranch** bs, usz n, int d)
{
    for (usz i = 0; i < n; i++)
    {
        AirBranch* b = bs[i];
        w.nl(d + 1);
        if (b == null) { w.err("null branch"); w.s("_ -> nil;"); continue; }
        w.pat(b.pat);
        if (b.guard != null) { w.s(" guard {"); w.nl(d + 2); w.cmd(b.guard, d + 2); w.nl(d + 1); w.c('}'); }
        w.s(" ->"); w.nl(d + 2); w.cmd(b.body, d + 2); w.c(';');
    }
}
fn void AirW.tailed(AirW* w, char* head, AirCns* k, int d)
{
    w.s(head); w.s(" \xc2\xb7 ");
    w.cns(k, d);
}
fn void AirW.cns(AirW* w, AirCns* k, int d)
{
    if (k == null) { w.s("nil"); return; }
    w.dig(k, AirCns::size);
    switch (k.tag)
    {
        case ACNS_COVAR:   w.name(k.name); return;
        case ACNS_STACK:
        {
            w.prd(k.prd, d); w.s(" \xc2\xb7 "); w.cns(k.tail, d);
            return;
        }
        case ACNS_FST:     w.tailed("fst", k.tail, d); return;
        case ACNS_SND:     w.tailed("snd", k.tail, d); return;
        case ACNS_DEREF:   w.tailed("deref", k.tail, d); return;
        case ACNS_DEFAULT: w.tailed("default", k.tail, d); return;
        case ACNS_SHARE:   w.tailed("share", k.tail, d); return;
        case ACNS_ERASE:   w.tailed("erase", k.tail, d); return;
        case ACNS_CALL:    w.tailed("call", k.tail, d); return;
        case ACNS_PROJ:
        {
            w.s("proj "); w.int_(k.idx); w.s(" \xc2\xb7 "); w.cns(k.tail, d);
            return;
        }
        case ACNS_FIELD:
        {
            w.s("field "); w.name(k.name); w.s(" #"); w.int_(k.idx); w.s(" \xc2\xb7 "); w.cns(k.tail, d);
            return;
        }
        case ACNS_INDEX:
        {
            w.s("index("); w.prd(k.prd, d); w.s("; "); w.int_(k.idx); w.s(") \xc2\xb7 ");
            w.cns(k.tail, d);
            return;
        }
        case ACNS_STORE:
        {
            w.s("store("); w.prd(k.prd, d); w.s("; "); w.int_(k.idx); w.s(") \xc2\xb7 ");
            w.cns(k.tail, d);
            return;
        }
        case ACNS_ASCRIBE:
        {
            w.s("as("); w.typ(k.ty); w.s(") \xc2\xb7 ");
            w.cns(k.tail, d);
            return;
        }
        case ACNS_CASE:
        {
            w.s(k.dense_switch ? "case dense {" : "case {");
            w.branches(&k.branches[0], k.branch_count, d);
            w.nl(d); w.c('}');
            return;
        }
        case ACNS_COCASE:
        {
            w.s("cocase {");
            for (usz i = 0; i < k.cobranch_count; i++)
            {
                AirCoBranch* cb = k.cobranches[i];
                w.nl(d + 1);
                if (cb == null) { w.err("null cobranch"); w.s(". nil() -> nil;"); continue; }
                w.c('.'); w.name(cb.dtor_name);
                w.names(&cb.binders[0], cb.binder_count);
                w.s(" ->"); w.nl(d + 2); w.cmd(cb.body, d + 2); w.c(';');
            }
            w.nl(d); w.c('}');
            return;
        }
        case ACNS_COMU:
        {
            w.s("comu "); w.name(k.bind); w.s(".");
            w.nl(d + 1); w.cmd(k.body, d + 1);
            return;
        }
        default:
            w.err("consumer tag not representable in AIR 2.0 (subst/label/invalid)");
            w.s("nil");
            return;
    }
}

// ── Commands ──────────────────────────────────────────────────────────────
fn void AirW.body_block(AirW* w, char* kw, AirCmd* body, int d)
{
    w.s(kw); w.s(" {"); w.nl(d + 1); w.cmd(body, d + 1); w.nl(d); w.c('}');
}
fn void AirW.cmd(AirW* w, AirCmd* c, int d)
{
    if (c == null) { w.s("nil"); return; }
    w.dig(c, AirCmd::size);
    switch (c.tag)
    {
        case ACMD_CUT:
        {
            w.c('<'); w.prd(c.prd, d); w.s(" | "); w.cns(c.cns, d); w.c('>');
            return;
        }
        case ACMD_MU:      w.s("mu ");  w.name(c.binder); w.s("."); w.nl(d + 1); w.cmd(c.body, d + 1); return;
        case ACMD_MUTILDE: w.s("mu~ "); w.name(c.binder); w.s("."); w.nl(d + 1); w.cmd(c.body, d + 1); return;
        case ACMD_JUMP:
        {
            w.s("jump "); w.name(c.target_label);
            w.names(&c.jump_args[0], c.jump_arg_count);
            return;
        }
        case ACMD_SEQ:
        {
            w.s("seq {"); w.nl(d + 1); w.cmd(c.body, d + 1); w.c(';');
            w.nl(d + 1); w.cmd(c.next, d + 1); w.nl(d); w.c('}');
            return;
        }
        case ACMD_BLOCK:     w.body_block("block", c.body, d); return;
        case ACMD_UNSAFE:    w.body_block("unsafe", c.body, d); return;
        case ACMD_UNCHECKED: w.body_block("unchecked", c.body, d); return;
        case ACMD_COMPTIME:  w.body_block("comptime", c.body, d); return;
        case ACMD_DEFER:     w.body_block("defer", c.body, d); return;
        case ACMD_WHILE:
        {
            w.s("while "); w.prd(c.prd, d); w.c(' ');
            w.body_block("do", c.body, d);
            return;
        }
        case ACMD_LET:
        {
            w.s("let "); w.name(c.binder); w.s(" = "); w.prd(c.prd, d); w.s(" in");
            w.nl(d + 1); w.cmd(c.body, d + 1);
            return;
        }
        case ACMD_LETREC:
        {
            w.s("letrec (");
            if (c.prd_count != c.mbinder_count) { w.err("letrec binder/producer count mismatch"); }
            for (usz i = 0; i < c.mbinder_count; i++)
            {
                if (i > 0) { w.s(", "); }
                w.binder(c.mbinders[i]); w.s(" = ");
                w.prd(i < c.prd_count ? c.prds[i] : null, d);
            }
            w.s(") in"); w.nl(d + 1); w.cmd(c.body, d + 1);
            return;
        }
        case ACMD_IF:
        {
            w.s("if "); w.prd(c.prd, d); w.s(" then"); w.nl(d + 1); w.cmd(c.then_c, d + 1);
            w.nl(d); w.s("else"); w.nl(d + 1); w.cmd(c.else_c, d + 1);
            return;
        }
        case ACMD_FOR:
        {
            w.s("for "); w.name(c.binder); w.s(" in "); w.prd(c.prd, d); w.c(' ');
            w.body_block("do", c.body, d);
            return;
        }
        case ACMD_MATCH:
        {
            w.s(c.dense_switch ? "match dense " : "match "); w.prd(c.prd, d); w.s(" {");
            w.branches(&c.branches[0], c.branch_count, d);
            w.nl(d); w.c('}');
            return;
        }
        case ACMD_HANDLE:
        {
            w.s("handle {"); w.nl(d + 1); w.cmd(c.handled, d + 1); w.nl(d); w.s("} {");
            w.branches(&c.branches[0], c.branch_count, d);
            w.nl(d); w.c('}');
            return;
        }
        case ACMD_PERFORM:
        {
            w.s("perform "); w.name(c.eff_op); w.c('('); w.prd(c.prd, d); w.c(')');
            w.result(c.cns, d);      // AIR 2.2: the value the handler resumes with
            return;
        }
        case ACMD_RESUME:  w.s("resume(");  w.prd(c.prd, d); w.c(')'); return;
        case ACMD_ASSERT:  w.s("assert(");  w.prd(c.prd, d); w.c(')'); return;
        case ACMD_ASSUME:  w.s("assume(");  w.prd(c.prd, d); w.c(')'); return;
        case ACMD_RET:     w.s("ret(");     w.prd(c.prd, d); w.c(')'); return;
        case ACMD_UB:      w.s("ub "); w.opt_str(c.ub_msg); return;
        case ACMD_TRAP:    w.s("trap"); return;
        case ACMD_NOP:     w.s("nop"); return;
        case ACMD_BREAK:    w.s("break ");    w.name(c.target_label); return;
        case ACMD_CONTINUE: w.s("continue "); w.name(c.target_label); return;
        case ACMD_LABEL:
        {
            w.s("label "); w.name(c.binder); w.binders(&c.mbinders[0], c.mbinder_count);
            w.s("."); w.nl(d + 1); w.cmd(c.body, d + 1);
            return;
        }
        case ACMD_ASM:
        {
            w.s("asm");
            if (c.asm_dialect == 1) { w.s(" intel"); }
            else if (c.asm_dialect == 2) { w.s(" att"); }
            else if (c.asm_dialect != 0) { w.err("unknown asm dialect"); }
            w.c(' '); w.opt_str(c.asm_text);
            if (c.asm_cons != null) { w.c(' '); w.opt_str(c.asm_cons); w.s(" : ["); w.typ(c.asm_ret); w.c(']'); }   // AIR 3.0: LLVM constraints and the result type
            w.prds(&c.prds[0], c.prd_count, d);
            w.result(c.cns, d);
            return;
        }
        case ACMD_SYSCALL:
        {
            w.s("syscall("); w.prd(c.prd, d);
            for (usz i = 0; i < c.prd_count; i++) { w.s(", "); w.prd(c.prds[i], d); }
            w.c(')');
            w.result(c.cns, d);
            return;
        }
        case ACMD_ATOMIC:
        {
            char* op = air_text::atomic_op_name(c.atomic_op);
            char* ord = air_text::atomic_order_name(c.atomic_order);
            if (op == null || ord == null) { w.err("atomic op/order out of range"); op = "load"; ord = "relaxed"; }
            w.s("atomic "); w.s(op); w.c(' '); w.s(ord); w.c('('); w.prd(c.prd, d);
            for (usz i = 0; i < c.prd_count; i++) { w.s(", "); w.prd(c.prds[i], d); }
            w.c(')');
            w.result(c.cns, d);
            return;
        }
        case ACMD_STORE:
            if (c.prd_count != 2) { w.err("store needs a pointer and a value"); }
            w.s(c.vol ? "store volatile(" : "store("); w.prd(c.prd_count > 0 ? c.prds[0] : null, d); w.s(", "); w.prd(c.prd_count > 1 ? c.prds[1] : null, d); w.c(')'); return;
        case ACMD_FENCE:
        {
            char* ord = air_text::atomic_order_name(c.atomic_order);
            if (ord == null) { w.err("fence order out of range"); ord = "relaxed"; }
            w.s("fence "); w.s(ord);
            return;
        }
        default:
            w.err("command tag not representable in AIR 2.0");
            w.s("nil");
            return;
    }
}

// ── Declarations ──────────────────────────────────────────────────────────
fn void AirW.mult(AirW* w, AirMult m)
{
    switch (m)
    {
        case AMULT_UNR:   break;
        case AMULT_LIN:   w.s(" lin"); break;
        case AMULT_AFF:   w.s(" aff"); break;
        case AMULT_EXACT: w.err("exact multiplicity on a declaration"); break;
    }
}
fn void AirW.field(AirW* w, AirField* f)
{
    if (f == null) { w.err("null field"); w.s("nil"); return; }
    if (f.is_mut) { w.s("mut "); }
    switch (f.mult)
    {
        case AMULT_UNR:   break;
        case AMULT_LIN:   w.s("lin "); break;
        case AMULT_AFF:   w.s("aff "); break;
        case AMULT_EXACT: w.err("exact multiplicity on a field"); break;
    }
    w.name(f.name); w.s(" : "); w.typ(f.ty);
}
fn void AirW.fields(AirW* w, AirField** fs, usz n)
{
    w.c('(');
    for (usz i = 0; i < n; i++) { if (i > 0) { w.s(", "); } w.field(fs[i]); }
    w.c(')');
}
fn void AirW.attrs(AirW* w, AirDecl* d)
{
    for (usz i = 0; i < d.attr_count; i++)
    {
        w.s("attr "); w.name(d.attr_name[i]);
        if (d.attr_str[i] != null) { w.c(' '); w.opt_str(d.attr_str[i]); }
        else if (d.attr_has_int[i]) { w.c(' '); w.int_(d.attr_int[i]); }
        w.c(' ');
    }
}
fn void AirW.decl(AirW* w, AirDecl* d)
{
    if (d == null) { w.err("null declaration"); return; }
    w.dg = 14695981039346656037UL;
    if (w.dg_on && !w.dg_quiet) { fprintf(w.out, "// digest-open %s\n", d.name == null ? "-" : d.name); }
    w.dig(d, AirDecl::size);
    w.decl_body(d);
    w.dg_total = (w.dg_total ^ w.dg) * 1099511628211UL;
    if (w.dg_on && !w.dg_quiet) { fprintf(w.out, "// digest %s %016lx\n", d.name == null ? "-" : d.name, w.dg); }
}
fn void AirW.decl_body(AirW* w, AirDecl* d)
{
    switch (d.tag)
    {
        case ADECL_MODULE:
        {
            w.s("module "); w.name(d.module_name); w.s(";\n");
            return;
        }
        case ADECL_IMPORT:
        {
            w.s("import "); w.opt_str(d.import_path);
            if (d.import_alias != null) { w.s(" as "); w.name(d.import_alias); }
            if (d.import_glob) { w.s(" glob"); }
            w.s(";\n");
            return;
        }
        case ADECL_DEF:
        case ADECL_DEFCO:
        case ADECL_DECLARE:
        {
            w.attrs(d);
            if (d.is_pub)     { w.s("pub "); }
            if (d.is_extern)  { w.s("extern "); }
            if (d.is_fastcc)  { w.s("fastcc "); }
            if (d.is_varargs) { w.s("varargs "); }
            if (d.extern_link != null) { w.s("link "); w.opt_str(d.extern_link); w.c(' '); }
            // Qualifier claims: candidates only. A reader re-screens them on
            // the AIR body and never promotes them to trusted facts.
            if (d.fact_state != AFACT_UNKNOWN) { w.s("facts "); w.s(d.fact_state == AFACT_AIR_CHECKED ? "air_checked " : "ast_final "); }
            if (d.memory_readonly) { w.s("readonly "); }
            w.s(d.tag == ADECL_DEF ? "def " : (d.tag == ADECL_DEFCO ? "defco " : "declare "));
            w.name(d.name);
            if (d.typaram_count > 0) { w.s(" ["); for (usz i = 0; i < d.typaram_count; i++) { if (i > 0) { w.s(", "); } w.binder(d.typarams[i]); } w.c(']'); }
            w.binders(&d.params[0], d.param_count);
            if (d.ret_ty != null) { w.s(" : "); w.typ(d.ret_ty); }
            if (d.def_body != null) { w.s(" ="); w.nl(1); w.cmd(d.def_body, 1); }
            w.s(";\n\n");
            return;
        }
        case ADECL_DATA:
        {
            w.attrs(d);
            if (d.is_pub) { w.s("pub "); }
            w.s("data "); w.name(d.name); w.mult(d.mult);
            if (d.typaram_count > 0) { w.s(" ["); for (usz i = 0; i < d.typaram_count; i++) { if (i > 0) { w.s(", "); } w.binder(d.typarams[i]); } w.c(']'); }
            w.s(" {");
            for (usz i = 0; i < d.ctor_count; i++)
            {
                AirCtorDecl* c = d.ctors[i];
                w.nl(1);
                if (c == null) { w.err("null constructor"); continue; }
                w.s("ctor "); w.name(c.name); w.fields(&c.fields[0], c.field_count);
                if (c.result_ty != null) { w.s(" : "); w.typ(c.result_ty); }
                w.c(';');
            }
            w.s("\n};\n\n");
            return;
        }
        case ADECL_CODATA:
        {
            if (d.is_pub) { w.s("pub "); }
            w.s("codata "); w.name(d.name); w.mult(d.mult);
            if (d.typaram_count > 0) { w.s(" ["); for (usz i = 0; i < d.typaram_count; i++) { if (i > 0) { w.s(", "); } w.binder(d.typarams[i]); } w.c(']'); }
            w.s(" {");
            for (usz i = 0; i < d.dtor_count; i++)
            {
                AirDtorDecl* x = d.dtors[i];
                w.nl(1);
                if (x == null) { w.err("null destructor"); continue; }
                w.s("op "); w.name(x.name); w.fields(&x.params[0], x.param_count);
                if (x.return_ty != null) { w.s(" : "); w.typ(x.return_ty); }
                w.c(';');
            }
            w.s("\n};\n\n");
            return;
        }
        case ADECL_GLOBAL:
        {
            w.attrs(d);
            if (d.is_pub) { w.s("pub "); }
            if (d.is_extern) { w.s("extern "); }
            w.s("global "); if (d.g_mut) { w.s("mut "); }
            w.name(d.name); w.s(" : "); w.typ(d.ret_ty);
            if (d.g_init != null) { w.s(" = "); w.prd(d.g_init, 1); }
            w.s(";\n\n");
            return;
        }
        case ADECL_EFFECT:
        {
            if (d.is_pub) { w.s("pub "); }
            w.s("effect "); w.name(d.name); w.s(" {");
            for (usz i = 0; i < d.op_count; i++)
            {
                AirEffectOp* o = d.ops[i];
                w.nl(1);
                if (o == null) { w.err("null effect op"); continue; }
                w.s("op "); w.name(o.name); w.s(" : "); w.typ(o.op_ty); w.c(';');
            }
            w.s("\n};\n\n");
            return;
        }
        default:
            w.err("declaration tag not representable in AIR 2.0");
            return;
    }
}

// Writes the whole module. Returns the number of writer errors (0 = faithful).
// `path == null` writes to stdout. On errors the file is still written (so it
// can be inspected) but the caller is expected to treat it as unusable.
fn int write_module(AirModule* m, char* path)
{
    AirW w;
    w.errs = 0;
    for (usz i = 0; i < 8; i++) { w.first_err[i] = null; }
    void* f = (path != null) ? fopen(path, "w") : fdopen(1, "w");
    if (f == null) { return -1; }
    w.out = f;
    w.s(m.low ? "// AIR 3.0 -- Abstractive Intermediate Representation (lambda-bar mu mu-tilde), low profile\n" : "// AIR 2.2 -- Abstractive Intermediate Representation (lambda-bar mu mu-tilde)\n");
    w.s("// canonical text; grammar in docs/specs/AIR.md; do not hand-edit\n");
    w.dg_on = (getenv("AIR_DIGEST") != null);
    w.dg_quiet = false;
    w.dg_total = 0;
    w.dg_verbose = (getenv("AIR_DIGEST_V") != null);
    w.dg = 0;
    w.s(m.low ? "air 3.0 " : "air 2.2 "); w.name(m.name); w.c(' '); w.opt_str(m.source_path); w.s(";\n\n");
    for (usz i = 0; i < m.decl_count; i++) { w.decl(m.decls[i]); }
    if (path != null) { fclose(f); } else { fflush(f); }
    void* se = fdopen(2, "w");
    for (int i = 0; i < w.errs && i < 8; i++) { fprintf(se, "air-write: %s\n", w.first_err[(usz)i]); }
    fflush(se);
    return w.errs;
}

// Structural fingerprint of a module: every node's tag and non-pointer fields,
// plus which pointers are present, folded in traversal order. Equal modules
// give equal fingerprints; ids and addresses are ignored. Used by the
// round-trip check to prove the text carried every field, not just the ones
// that happened to change the bitcode of one test program.
fn ulong digest_module(AirModule* m)
{
    AirW w;
    w.errs = 0;
    for (usz i = 0; i < 8; i++) { w.first_err[i] = null; }
    w.out = fopen("/dev/null", "w");
    if (w.out == null) { return 0; }
    w.dg_on = true; w.dg_quiet = true; w.dg_verbose = false; w.dg = 0; w.dg_total = 1469598103934665603UL;
    for (usz i = 0; i < m.decl_count; i++) { w.decl(m.decls[i]); }
    fclose(w.out);
    return w.dg_total;
}
