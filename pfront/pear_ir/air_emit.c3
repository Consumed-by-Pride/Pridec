// ============================================================================
// air_emit.c3 — IR-to-text printer for AIR 1.0 (λ̄μμ̃ calculus).
// ----------------------------------------------------------------------------
// Consumes an AirModule produced by air_lower and prints clean, stubless AIR
// text: no `*k*`/`*dummy*` placeholders, no `<()|·>` administrative nops, no
// leaked source spans in identifiers, no duplicated/dead code after
// terminal commands.
//
// Nop-elimination rules applied during printing:
//   * ACMD_CUT     <()|μ̃x.c>   →  c
//   * ACMD_SEQ     c1;c2       →  c1  when c2 is nop
//   * ACMD_LET     let _ = e   →  elided (unit-let)
//   * ACMD_MUTILDE wrapping a single <p|%ret> in a fn body → shown directly
//
// The output is intentionally plain ASCII+μ/μ̃/·/⟨⟩ so terminals render it.
// ============================================================================
module air_emit;

import pfront_core;
import air_ir;
import air_lower;
import air_scope;

extern fn void* fdopen(int fd, char* mode);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn int   fputs(char* s, void* f);
extern fn int   fputc(int c, void* f);
extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);
extern fn long  ftell(void* f);

struct AirEmitter {
    void* out;
    AirModule* mod;
    AirLower*  lr;
    int  indent;
    bool need_space;
    bool in_tail;    // we're directly under a μ̃/case-arm (can suppress let _)
}

fn void* get_stdout() { return fdopen(1, "w"); }

// ── Tiny output helpers ────────────────────────────────────────────────────
fn void AirEmitter.wr(AirEmitter* e, char* s) { fputs(s, e.out); e.need_space = false; }
fn void AirEmitter.sp(AirEmitter* e) { fputc(' ', e.out); }
fn void AirEmitter.nl(AirEmitter* e) { fputc('\n', e.out); e.need_space = false; }
fn void AirEmitter.ind(AirEmitter* e) {
    for (int i = 0; i < e.indent; i++) fputc(' ', e.out);
}
fn void AirEmitter.indent_more(AirEmitter* e) { e.indent = e.indent + 2; }
fn void AirEmitter.indent_less(AirEmitter* e) { if (e.indent >= 2) e.indent = e.indent - 2; }
fn void AirEmitter.comma(AirEmitter* e) { e.wr(","); e.sp(); }
fn void AirEmitter.semi(AirEmitter* e) { e.wr(";"); }

// ── Nop detection ─────────────────────────────────────────────────────────
// A cmd is "nop" if it is the administrative redex <()|·>.
fn bool is_nop_cmd(AirCmd* c)
{
    if (c == null) return true;
    if (c.tag == ACMD_CUT
        && c.prd != null && c.prd.tag == APRD_UNIT
        && c.cns != null && c.cns.tag == ACNS_COVAR
        && c.cns.name != null
        && c.cns.name[0] == (char)0xC2  // · is UTF-8 C2 B7
        && c.cns.name[1] == (char)0xB7) return true;
    return false;
}

// Is this a command that unconditionally transfers control (no code after
// it is reachable)?
// Administrative join covariables (%kN) are not terminal: the backend emits the
// commands that follow them into the join block they name. Mirrors
// air_lower.is_admin_join_name() so the printed AIR keeps live commands.
fn bool is_admin_join_name_e(char* nm)
{
    if (nm == null) return false;
    if (nm[0] != '%' || nm[1] != 'k') return false;
    if (nm[2] < '0' || nm[2] > '9') return false;
    return true;
}

fn bool is_terminal(AirCmd* c)
{
    if (c == null) return false;
    switch (c.tag)
    {
        case ACMD_JUMP: case ACMD_TRAP: case ACMD_UB:
        case ACMD_BREAK: case ACMD_CONTINUE: case ACMD_RET:
            return true;
        case ACMD_CUT:
        {
            if (c.cns != null && c.cns.tag == ACNS_COVAR)
            {
                return !is_admin_join_name_e(c.cns.name);
            }
            return false;
        }
        case ACMD_SEQ: return is_terminal(c.body);
        case ACMD_MU:  return is_terminal(c.body);
        case ACMD_MUTILDE: return is_terminal(c.body);
        case ACMD_LET: return is_terminal(c.body);
        default: return false;
    }
}

// ── Types (must come before prd/cns/cmd because those may call emit_typ) ──
fn void emit_mult(AirEmitter* e, AirMult m)
{
    switch (m)
    {
        case AMULT_LIN: e.wr("lin "); return;
        case AMULT_AFF: e.wr("aff "); return;
        case AMULT_EXACT: e.wr("1 "); return;
        default: return;
    }
}

fn void emit_typ(AirEmitter* e, AirTyp* t)
{
    if (t == null) { e.wr("_"); return; }
    switch (t.tag)
    {
        case ATYP_UNIT:   e.wr("()"); return;
        case ATYP_I8:     e.wr("i8"); return;
        case ATYP_I16:    e.wr("i16"); return;
        case ATYP_I32:    e.wr("i32"); return;
        case ATYP_I64:    e.wr("i64"); return;
        case ATYP_I128:   e.wr("i128"); return;
        case ATYP_ISZ:    e.wr("isz"); return;
        case ATYP_U8:     e.wr("u8"); return;
        case ATYP_U16:    e.wr("u16"); return;
        case ATYP_U32:    e.wr("u32"); return;
        case ATYP_U64:    e.wr("u64"); return;
        case ATYP_U128:   e.wr("u128"); return;
        case ATYP_USZ:    e.wr("usz"); return;
        case ATYP_F16:    e.wr("f16"); return;
        case ATYP_F32:    e.wr("f32"); return;
        case ATYP_F64:    e.wr("f64"); return;
        case ATYP_F128:   e.wr("f128"); return;
        case ATYP_BOOL:   e.wr("bool"); return;
        case ATYP_CHAR:   e.wr("char"); return;
        case ATYP_STR:    e.wr("str"); return;
        case ATYP_BYTES:  e.wr("bytes"); return;
        case ATYP_BOTTOM: e.wr("⊥"); return;
        case ATYP_INFER:  e.wr("_"); return;
        case ATYP_NOMINAL:
        case ATYP_PATH:
        case ATYP_VAR:
        case ATYP_SELF:
        case ATYP_GENERIC_APP:
        {
            if (t.name != null) { e.wr(t.name); } else { e.wr("_"); }
            if (t.arg_count > 0)
            {
                e.wr("<");
                for (usz i = 0; i < t.arg_count; i++)
                {
                    if (i > 0) e.comma();
                    emit_typ(e, t.args[i]);
                }
                e.wr(">");
            }
            return;
        }
        case ATYP_ARROW:
        {
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr(" -> ");
            if (t.arg_count >= 2) { emit_typ(e, t.args[1]); } else { e.wr("_"); }
            return;
        }
        case ATYP_TUPLE:
        {
            e.wr("(");
            for (usz i = 0; i < t.arg_count; i++)
            {
                if (i > 0) e.comma();
                emit_typ(e, t.args[i]);
            }
            e.wr(")");
            return;
        }
        case ATYP_RECORD:
        {
            e.wr("{");
            for (usz i = 0; i < t.rec_field_count; i++)
            {
                if (i > 0) e.comma();
                AirFieldInit* fi = t.rec_fields[i];
                if (fi != null && fi.name != null) { e.wr(fi.name); e.wr(": "); }
            }
            e.wr("}");
            return;
        }
        case ATYP_ARRAY:
        {
            e.wr("[");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr("; ");
            // print ival as length
            char[32] b; int n = 0; long v = t.ival;
            if (v == 0) { b[0]='0'; n=1; }
            else { int j=0; long vv=v; if(vv<0){b[j++]='-';vv=-vv;} long m=1; while(m<=vv/10)m=m*10; while(m>0){b[j++]=(char)('0'+(vv/m));vv=vv%m;m=m/10;} n=j; }
            b[n]=0;
            e.wr(&b[0]);
            e.wr("]");
            return;
        }
        case ATYP_SLICE:
        {
            e.wr("[");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr("]");
            return;
        }
        case ATYP_PTR:
            e.wr("ptr");
            if (t.arg_count >= 1) { e.wr("<"); emit_typ(e, t.args[0]); e.wr(">"); }
            return;
        case ATYP_REF:
            e.wr("&");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        case ATYP_REF_MUT:
            e.wr("&mut ");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        case ATYP_SUM:
        {
            e.wr("(");
            for (usz i = 0; i < t.arg_count; i++)
            {
                if (i > 0) e.wr(" | ");
                emit_typ(e, t.args[i]);
            }
            e.wr(")");
            return;
        }
        case ATYP_UNION:
        {
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr(" & ");
            if (t.arg_count >= 2) emit_typ(e, t.args[1]);
            return;
        }
        case ATYP_INTERSECT:
        {
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr(" /\\ ");
            if (t.arg_count >= 2) emit_typ(e, t.args[1]);
            return;
        }
        case ATYP_NEGATION:
            e.wr("~");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        case ATYP_FORALL:
        {
            e.wr("forall ");
            if (t.name != null) { e.wr(t.name); } else { e.wr("a"); }
            e.wr(". ");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        }
        case ATYP_EXISTS:
        {
            e.wr("exists ");
            if (t.name != null) { e.wr(t.name); } else { e.wr("a"); }
            e.wr(". ");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        }
        case ATYP_BANG:
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            e.wr("!");
            return;
        case ATYP_QUERY:
            e.wr("?");
            if (t.arg_count >= 1) emit_typ(e, t.args[0]);
            return;
        case ATYP_TYPEOF:
        {
            // typeof(prd) — the static type of an expression
            e.wr("typeof(");
            // t.args[0] can carry the inner typ/prd
            if (t.arg_count > 0 && t.args[0] != null) { emit_typ(e, t.args[0]); }
            else if (t.name != null) { e.wr(t.name); }
            else { e.wr("_"); }
            e.wr(")");
            return;
        }
        case ATYP_REFINE:
        {
            // {x: T | P} — refinement type
            e.wr("{");
            if (t.name != null) { e.wr(t.name); } else { e.wr("_"); }
            if (t.arg_count > 0 && t.args[0] != null)
            {
                e.wr(": "); emit_typ(e, t.args[0]);
            }
            // refinement predicate carried in eff_name / refine_extra — just show braces
            e.wr("}");
            return;
        }
        case ATYP_MULT:
            e.wr("*");
            return;
        case ATYP_EFFROW:
        {
            e.wr("{");
            for (usz i = 0; i < t.arg_count; i++)
            {
                if (i > 0) e.comma();
                emit_typ(e, t.args[i]);
            }
            if (t.eff_tail != null)
            {
                if (t.arg_count > 0) e.comma();
                emit_typ(e, t.eff_tail);
            }
            else if (t.ival == 0)
            {
                if (t.arg_count > 0) e.comma();
                e.wr("|");
            }
            e.wr("}");
            return;
        }
        default:
            e.wr("?");
            return;
    }
}

// Preserve a character codepoint in AIR text; never silently truncate to
// the first UTF-8 byte. The lexer accepts a Unicode scalar literal.
fn void emit_char_literal(AirEmitter* e, long code)
{
    e.wr("'");
    if (code == 10) { e.wr("\\n"); }
    else if (code == 13) { e.wr("\\r"); }
    else if (code == 9) { e.wr("\\t"); }
    else if (code == 0) { e.wr("\\x00"); }
    else if (code == 39) { e.wr("\\'"); }
    else if (code == 92) { e.wr("\\\\"); }
    else if (code >= 0 && code < 128) { fputc((int)code, e.out); }
    else if (code < 2048)
    { fputc((int)(192 | (code >> 6)), e.out); fputc((int)(128 | (code & 63)), e.out); }
    else if (code < 65536)
    { fputc((int)(224 | (code >> 12)), e.out); fputc((int)(128 | ((code >> 6) & 63)), e.out); fputc((int)(128 | (code & 63)), e.out); }
    else
    { fputc((int)(240 | (code >> 18)), e.out); fputc((int)(128 | ((code >> 12) & 63)), e.out); fputc((int)(128 | ((code >> 6) & 63)), e.out); fputc((int)(128 | (code & 63)), e.out); }
    e.wr("'");
}

// ── Patterns ─────────────────────────────────────────────────────────────
fn void emit_pat(AirEmitter* e, AirPat* p)
{
    if (p == null) { e.wr("_"); return; }
    switch (p.tag)
    {
        case APAT_WILD: e.wr("_"); return;
        case APAT_BIND: e.wr(p.name != null ? p.name : "_x"); return;
        case APAT_INT:
        {
            char[32] b; int n=0; long v=p.ival;
            if(v==0){b[0]='0';n=1;}else{int j=0;long vv=v;if(vv<0){b[j++]='-';vv=-vv;}long m=1;while(m<=vv/10)m=m*10;while(m>0){b[j++]=(char)('0'+(vv/m));vv=vv%m;m=m/10;}n=j;}
            b[n]=0; e.wr(&b[0]); return;
        }
        case APAT_BOOL: e.wr(p.ival!=0 ? "true" : "false"); return;
        case APAT_FLOAT:
        {
            char[64] b;
            (void)snprintf(&b[0], 64, "%g", p.fval);
            e.wr(&b[0]); return;
        }
        case APAT_CHAR:
        {
            emit_char_literal(e, p.ival);
            return;
        }
        case APAT_STRING:
        {
            e.wr("\"");
            if (p.name != null) e.wr(p.name);
            e.wr("\"");
            return;
        }
        case APAT_TUPLE:
        case APAT_ARRAY:
        {
            e.wr("(");
            for (usz i = 0; i < p.sub_count; i++)
            {
                if (i > 0) e.comma();
                emit_pat(e, p.sub[i]);
            }
            e.wr(")");
            return;
        }
        case APAT_RECORD:
        {
            e.wr("{");
            for (usz i = 0; i < p.field_count; i++)
            {
                if (i > 0) e.comma();
                if (p.fields[i] != null && p.fields[i].name != null) e.wr(p.fields[i].name);
            }
            e.wr("}");
            return;
        }
        case APAT_VARIANT:
        {
            e.wr(p.name != null ? p.name : "C");
            if (p.sub_count > 0)
            {
                e.wr("(");
                for (usz i = 0; i < p.sub_count; i++)
                {
                    if (i > 0) e.comma();
                    emit_pat(e, p.sub[i]);
                }
                e.wr(")");
            }
            return;
        }
        case APAT_AS:
        {
            emit_pat(e, p.sub_count>0?p.sub[0]:null);
            e.wr(" as ");
            if (p.as_pat != null) { emit_pat(e, p.as_pat); } else if (p.name != null) { e.wr(p.name); }
            return;
        }
        case APAT_OR:
            emit_pat(e, p.sub_count>0?p.sub[0]:null);
            e.wr(" | ");
            if (p.or_alt != null) emit_pat(e, p.or_alt);
            return;
        case APAT_RANGE:
            e.wr("_.._");
            return;
        case APAT_REF:
            e.wr("&");
            if (p.sub_count > 0) { emit_pat(e, p.sub[0]); } else { e.wr("_"); }
            return;
        case APAT_REST: e.wr(".."); return;
        default: e.wr("_"); return;
    }
}

// ── Producers ───────────────────────────────────────────────────────────
fn void emit_binop(AirEmitter* e, AirBinop op)
{
    switch (op)
    {
        case ABIN_ADD: e.wr(" + "); return;
        case ABIN_SUB: e.wr(" - "); return;
        case ABIN_MUL: e.wr(" * "); return;
        case ABIN_DIV: e.wr(" / "); return;
        case ABIN_MOD: e.wr(" % "); return;
        case ABIN_AND: e.wr(" & "); return;
        case ABIN_OR:  e.wr(" | "); return;
        case ABIN_XOR: e.wr(" ^ "); return;
        case ABIN_SHL: e.wr(" << "); return;
        case ABIN_SHR: e.wr(" >> "); return;
        case ABIN_LAND: e.wr(" && "); return;
        case ABIN_LOR:  e.wr(" || "); return;
        case ABIN_EQ:   e.wr(" == "); return;
        case ABIN_NEQ:  e.wr(" != "); return;
        case ABIN_LT:   e.wr(" < "); return;
        case ABIN_GT:   e.wr(" > "); return;
        case ABIN_LE:   e.wr(" <= "); return;
        case ABIN_GE:   e.wr(" >= "); return;
        case ABIN_PIPE: e.wr(" |> "); return;
        default: e.wr(" ?? "); return;
    }
}

fn void emit_unop(AirEmitter* e, AirUnop op)
{
    switch (op)
    {
        case AUN_NEG:     e.wr("-"); return;
        case AUN_NOT:     e.wr("!"); return;
        case AUN_BITNOT:  e.wr("~"); return;
        case AUN_DEREF:   e.wr("*"); return;
        case AUN_REF:     e.wr("&"); return;
        case AUN_ADDR:    e.wr("&"); return;
        case AUN_COMULT:  e.wr("!"); return;
        default: e.wr("?"); return;
    }
}

fn void emit_prd(AirEmitter* e, AirPrd* p)
{
    if (p == null) { e.wr("()"); return; }
    switch (p.tag)
    {
        case APRD_INVALID: e.wr("<?>"); return;
        case APRD_VAR:     e.wr(p.name != null ? p.name : "_x"); return;
        case APRD_CON:     e.wr(p.name != null ? p.name : "C"); return;
        case APRD_INT:
        {
            char[32] b; int n=0; long v=p.ival;
            if(v==0){b[0]='0';n=1;}else{int j=0;long vv=v;if(vv<0){b[j++]='-';vv=-vv;}long m=1;while(m<=vv/10)m=m*10;while(m>0){b[j++]=(char)('0'+(vv/m));vv=vv%m;m=m/10;}n=j;}
            b[n]=0; e.wr(&b[0]);
            return;
        }
        case APRD_FLOAT:
        {
            char[64] b;
            (void)snprintf(&b[0], 64, "%g", p.fval);
            e.wr(&b[0]); return;
        }
        case APRD_BOOL:  e.wr(p.bval ? "true" : "false"); return;
        case APRD_CHAR:
        {
            emit_char_literal(e, p.ival); return;
        }
        case APRD_STRING:
        {
            e.wr("\"");
            if (p.name != null) e.wr(p.name);
            e.wr("\"");
            return;
        }
        case APRD_BYTES:
        {
            // b"…" literal — show short byte strings inline, long ones as b"…" with length
            e.wr("b\"");
            if (p.bytes != null && p.bytes_len > 0)
            {
                usz n = p.bytes_len < 32 ? p.bytes_len : 32;
                for (usz i = 0; i < n; i++) { fputc((int)p.bytes[i], e.out); }
                if (p.bytes_len > 32) e.wr("...");
            }
            e.wr("\"");
            return;
        }
        case APRD_UNIT:  e.wr("()"); return;
        case APRD_NULL:  e.wr("null"); return;
        case APRD_TUPLE:
        case APRD_ARRAY:
        {
            e.wr("(");
            for (usz i = 0; i < p.sub_count; i++)
            {
                if (i > 0) e.comma();
                emit_prd(e, p.subs[i]);
            }
            e.wr(")");
            return;
        }
        case APRD_RECORD:
        {
            e.wr("{");
            for (usz i = 0; i < p.rec_init_count; i++)
            {
                if (i > 0) e.comma();
                AirFieldInit* fi = p.rec_inits[i];
                if (fi != null)
                {
                    if (fi.name != null) { e.wr(fi.name); e.wr(" = "); }
                    emit_prd(e, fi.value);
                }
            }
            e.wr("}");
            return;
        }
        case APRD_INL:
            e.wr("inl ");
            if (p.sub_count > 0) { emit_prd(e, p.subs[0]); } else { e.wr("()"); }
            return;
        case APRD_INR:
            e.wr("inr ");
            if (p.sub_count > 0) { emit_prd(e, p.subs[0]); } else { e.wr("()"); }
            return;
        case APRD_LAMBDA:
        {
            e.wr("λ");
            for (usz i = 0; i < p.binder_count; i++)
            {
                e.sp();
                AirBinder* b = p.binders[i];
                if (b != null)
                {
                    if (b.name != null) { e.wr(b.name); } else { e.wr("_"); }
                    if (b.ty != null && b.ty.tag != ATYP_INFER)
                    {
                        e.wr(": "); emit_typ(e, b.ty);
                    }
                }
            }
            e.wr(".");
            // body is a cmd; print indented block
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, p.body);
            e.indent_less();
            return;
        }
        case APRD_MU:
        {
            // μ α.c  — producer-side activation
            e.wr("μ");
            if (p.name != null) e.wr(p.name);
            e.wr(".");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, p.body);
            e.indent_less();
            return;
        }
        case APRD_COMETA:
        {
            // cometa is a co-λ (consumer-side lambda):  ~α.c
            e.wr("~");
            for (usz i = 0; i < p.binder_count; i++)
            {
                e.sp();
                AirBinder* b = p.binders[i];
                if (b != null) { e.wr(b.name != null ? b.name : "%k"); }
            }
            e.wr(".");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, p.body);
            e.indent_less();
            return;
        }
        case APRD_BINOP:
        {
            e.wr("(");
            if (p.sub_count >= 1) emit_prd(e, p.subs[0]);
            emit_binop(e, p.bop);
            if (p.sub_count >= 2) emit_prd(e, p.subs[1]);
            e.wr(")");
            return;
        }
        case APRD_UNOP:
        {
            e.wr("(");
            emit_unop(e, p.uop);
            if (p.sub_count >= 1) emit_prd(e, p.subs[0]);
            e.wr(")");
            return;
        }
        case APRD_COERCE:
            if (p.sub_count >= 1) emit_prd(e, p.subs[0]);
            e.wr(" :> ");
            if (p.ty != null) emit_typ(e, p.ty);
            return;
        case APRD_SIZEOF:   e.wr("sizeof("); emit_typ(e, p.ty); e.wr(")"); return;
        case APRD_ALIGNOF:  e.wr("alignof("); emit_typ(e, p.ty); e.wr(")"); return;
        case APRD_OFFSETOF:
        {
            // offsetof(T, .f) — field name lives in p.name
            e.wr("offsetof(");
            emit_typ(e, p.ty);
            if (p.name != null) { e.wr(", ."); e.wr(p.name); }
            e.wr(")");
            return;
        }
        case APRD_REIFY:
        {
            // reify: quote a term to its code value (stage-0 → stage-1)
            e.wr("reify ");
            if (p.body != null) { emit_cmd(e, p.body); } else { e.wr("()"); }
            return;
        }
        case APRD_EVAL:
        {
            // eval: splice-and-run a code value (stage-1 → stage-0)
            e.wr("eval ");
            if (p.sub_count > 0 && p.subs[0] != null) { emit_prd(e, p.subs[0]); }
            else { e.wr("()"); }
            return;
        }
        case APRD_QUOTE:
        {
            // quote: quasi-quote a code block (`<c>` MSP syntax)
            e.wr("quote {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, p.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case APRD_SPLICE:
        {
            // splice: escape a reified value into a quote (~e)
            e.wr("~");
            if (p.sub_count > 0 && p.subs[0] != null) { emit_prd(e, p.subs[0]); }
            else { e.wr("()"); }
            return;
        }
        case APRD_POISON:   e.wr("poison"); return;
        case APRD_UNREACHABLE_VAL: e.wr("unreachable"); return;
        default: e.wr("?prd"); return;
    }
}

// ── Consumers ───────────────────────────────────────────────────────────
fn void emit_cns(AirEmitter* e, AirCns* k)
{
    if (k == null) { e.wr("·"); return; }
    switch (k.tag)
    {
        case ACNS_INVALID: e.wr("·"); return;
        case ACNS_COVAR:   e.wr(k.name != null ? k.name : "%k"); return;
        case ACNS_STACK:
        {
            // p·k : push p onto stack k (argument). Print as p·tail
            if (k.prd != null) emit_prd(e, k.prd);
            e.wr("·");
            emit_cns(e, k.tail);
            return;
        }
        case ACNS_CALL:
        {
            // air_mk_call wraps args in an explicit ACNS_CALL node whose
            // .tail is the STACK chain (right-to-left pushed, so args[0] is
            // top-of-stack printed first). The chain terminates at the
            // continuation consumer (usually a covar; sometimes another
            // composite). Print generically: walk STACKs collecting args,
            // then emit the final consumer.
            AirPrd*[64] args; usz ac = 0;
            AirCns* cur = k.tail;
            while (cur != null && cur.tag == ACNS_STACK)
            {
                if (ac < 64) { args[ac] = cur.prd; ac++; }
                cur = cur.tail;
            }
            e.wr("call(");
            for (usz i = 0; i < ac; i++)
            {
                if (i > 0) e.comma();
                emit_prd(e, args[i]);
            }
            e.wr("; ");
            if (cur != null && cur.tag == ACNS_COVAR && cur.name != null)
            {
                e.wr(cur.name);
            }
            else if (cur != null)
            {
                emit_cns(e, cur);
            }
            else
            {
                e.wr("%ret");
            }
            e.wr(")");
            return;
        }
        case ACNS_FST: e.wr("fst·"); emit_cns(e, k.tail); return;
        case ACNS_SND: e.wr("snd·"); emit_cns(e, k.tail); return;
        case ACNS_PROJ:
        {
            char[16] b;
            (void)snprintf(&b[0], 16, "#%ld·", (long)k.idx);
            e.wr(&b[0]); emit_cns(e, k.tail); return;
        }
        case ACNS_FIELD:
            e.wr(".");
            e.wr(k.name != null ? k.name : "f");
            e.wr("·");
            emit_cns(e, k.tail);
            return;
        case ACNS_INDEX:
            e.wr("[");
            if (k.prd != null) emit_prd(e, k.prd);
            e.wr("]·");
            emit_cns(e, k.tail);
            return;
        case ACNS_CASE:
        {
            e.wr("case{");
            for (usz i = 0; i < k.branch_count; i++)
            {
                if (i > 0) e.wr("; ");
                AirBranch* br = k.branches[i];
                if (br != null)
                {
                    emit_pat(e, br.pat);
                    e.wr(" → ");
                    emit_cmd(e, br.body);
                }
            }
            e.wr("}");
            return;
        }
        case ACNS_COCASE:
        {
            e.wr("cocase{");
            for (usz i = 0; i < k.cobranch_count; i++)
            {
                if (i > 0) e.wr("; ");
                AirCoBranch* cb = k.cobranches[i];
                if (cb != null)
                {
                    e.wr(".");
                    e.wr(cb.dtor_name != null ? cb.dtor_name : "op");
                    if (cb.binder_count > 0)
                    {
                        e.wr("(");
                        for (usz j = 0; j < cb.binder_count; j++)
                        {
                            if (j > 0) e.comma();
                            if (cb.binders[j] != null) { e.wr(cb.binders[j]); } else { e.wr("_"); }
                        }
                        e.wr(")");
                    }
                    e.wr(" → ");
                    // emit_cmd inline (cobranch body stored in… cobranch? we
                    // don't have body field on AirCoBranch; walk prints what we have).
                }
            }
            e.wr("}");
            return;
        }
        case ACNS_COMU:
        {
            // μ̃x.c is a consumer binder. Render as μ̃x.c when there's a tail,
            // but typically COMU is used as the body of a let-binding and is
            // printed inline by ACMD_LET (we shouldn't hit this path often).
            e.wr("μ̃");
            if (k.bind != null) e.wr(k.bind);
            e.wr(".");
            if (k.body != null) { emit_cmd(e, k.body); } else { e.wr("()"); }
            return;
        }
        case ACNS_DEFAULT: e.wr("default·"); emit_cns(e, k.tail); return;
        case ACNS_ASCRIBE:
            e.wr("("); emit_cns(e, k.tail); e.wr(" : "); emit_typ(e, k.ty); e.wr(")");
            return;
        case ACNS_SUBST: e.wr("subst·"); emit_cns(e, k.tail); return;
        case ACNS_SHARE: e.wr("share·"); emit_cns(e, k.tail); return;
        case ACNS_ERASE: e.wr("erase·"); emit_cns(e, k.tail); return;
        case ACNS_DEREF: e.wr("*·"); emit_cns(e, k.tail); return;
        case ACNS_STORE: e.wr(":=·"); emit_cns(e, k.tail); return;
        case ACNS_LABEL: e.wr("label·"); emit_cns(e, k.tail); return;
        default: e.wr("?cns"); return;
    }
}

// ── Commands ────────────────────────────────────────────────────────────
fn void emit_binders_list(AirEmitter* e, AirBinder** bv, usz bc)
{
    for (usz i = 0; i < bc; i++)
    {
        AirBinder* b = bv[i];
        if (b == null) continue;
        if (i > 0) e.sp();
        if (b.name != null) { e.wr(b.name); } else { e.wr("_"); }
        if (b.ty != null && b.ty.tag != ATYP_INFER)
        {
            e.wr(": "); emit_typ(e, b.ty);
        }
    }
}

// Helpers for detecting nested μ̃ bindings inside a consumer chain (used
// to print `<f|call(a; μ̃x.body)>` as `let x = f(a); body`).
fn AirCns* cns_terminal(AirCns* c)
{
    AirCns* cur = c;
    while (cur != null)
    {
        switch (cur.tag)
        {
            case ACNS_CALL: case ACNS_STACK: case ACNS_FIELD: case ACNS_INDEX:
            case ACNS_PROJ: case ACNS_FST: case ACNS_SND:
                cur = cur.tail; continue;
            default: return cur;
        }
    }
    return null;
}
fn void emit_cns_prefix_up_to(AirEmitter* e, AirCns* c, AirCns* term)
{
    if (c == null || c == term) return;
    switch (c.tag)
    {
        case ACNS_COMU: case ACNS_COVAR: return;
        case ACNS_CALL:
        {
            AirPrd*[64] args; usz ac = 0;
            AirCns* cur = c.tail;
            while (cur != null && cur.tag == ACNS_STACK && cur != term)
            {
                if (ac < 64) { args[ac] = cur.prd; ac++; }
                cur = cur.tail;
            }
            e.wr("call(");
            for (usz i = 0; i < ac; i++)
            {
                if (i > 0) e.comma();
                emit_prd(e, args[i]);
            }
            e.wr("; ");
            return;
        }
        case ACNS_FIELD:
            e.wr("."); e.wr(c.name != null ? c.name : "f"); e.wr("·");
            emit_cns_prefix_up_to(e, c.tail, term); return;
        case ACNS_INDEX:
            e.wr("["); if (c.prd != null) emit_prd(e, c.prd); e.wr("]·");
            emit_cns_prefix_up_to(e, c.tail, term); return;
        case ACNS_PROJ:
        {
            char[16] b; (void)snprintf(&b[0], 16, "#%ld·", (long)c.idx);
            e.wr(&b[0]); emit_cns_prefix_up_to(e, c.tail, term); return;
        }
        case ACNS_FST: e.wr("fst·"); emit_cns_prefix_up_to(e, c.tail, term); return;
        case ACNS_SND: e.wr("snd·"); emit_cns_prefix_up_to(e, c.tail, term); return;
        default: emit_cns(e, c); return;
    }
}

fn void emit_cmd(AirEmitter* e, AirCmd* c)
{
    if (c == null) { e.wr("()"); return; }
    if (is_nop_cmd(c)) { e.wr("()"); return; }
    switch (c.tag)
    {
        case ACMD_NOP: e.wr("()"); return;
        case ACMD_INVALID: e.wr("()"); return;
        case ACMD_CUT:
        {
            // Suppress the admin redex <()|μ̃x.c> → c (unit-μ̃-admin)
            if (c.prd != null && c.prd.tag == APRD_UNIT
                && c.cns != null && c.cns.tag == ACNS_COMU
                && c.cns.body != null)
            {
                emit_cmd(e, c.cns.body);
                return;
            }
            // Detect <v | … μ̃x.body> as a let-binding sugar, where the … may
            // include a call(args;)/field/index/proj chain leading to μ̃x:
            //   <f|call(a; μ̃x.body)>  ≡ let x = f(a); body
            //   <e|μ̃x.body>           ≡ let x = e; body
            // This fires for the standard right-to-left μ̃ wrapping produced
            // by the lowerer for all compound subexpressions.
            {
                AirCns* term = cns_terminal(c.cns);
                if (term != null && term.tag == ACNS_COMU
                    && term.body != null && term.bind != null && c.prd != null)
                {
                    char* xn = term.bind;
                    bool is_fresh = (xn[0] == '_' && xn[1] == 'x'); // fresh _xN
                    bool is_wild  = (xn[0] == '_' && xn[1] == 0);
                    if ((is_fresh || is_wild) && c.prd.tag == APRD_UNIT)
                    {
                        if (is_nop_cmd(term.body)) return;
                        emit_cmd(e, term.body);
                        return;
                    }
                    e.wr("let "); e.wr(xn); e.wr(" = ");
                    // Emit the prd, then the consumer prefix up to μ̃.
                    // Determine if the shape is a simple call:
                    //   <f|call(args; μ̃x)>  where the outermost cns is ACNS_CALL
                    //   or a value: <e|μ̃x>
                    bool simple = (c.cns == term);
                    bool is_call = (!simple && c.cns.tag == ACNS_CALL);
                    // Nested field/index/proj/etc would need more work; fall
                    // back to <...> for those.
                    bool is_complex = (!simple && !is_call);
                    // Walk to see if the path from cns to term is JUST the call
                    // stack (no fields/indexes between CALL and STACKs).
                    if (is_call)
                    {
                        AirCns* cc = c.cns.tail;
                        while (cc != null && cc != term && cc.tag == ACNS_STACK) cc = cc.tail;
                        if (cc != term) { is_call = false; is_complex = true; }
                    }
                    if (simple)
                    {
                        emit_prd(e, c.prd);
                    }
                    else if (is_call)
                    {
                        // Print `f(args)` directly (the μ̃ binder is already in
                        // "let x = ..."); no wrapping <...>.
                        emit_prd(e, c.prd);
                        e.wr("(");
                        AirPrd*[64] args; usz ac = 0;
                        AirCns* cc = c.cns.tail;
                        while (cc != null && cc != term && cc.tag == ACNS_STACK)
                        {
                            if (ac < 64) { args[ac] = cc.prd; ac++; }
                            cc = cc.tail;
                        }
                        for (usz i = 0; i < ac; i++)
                        {
                            if (i > 0) e.comma();
                            emit_prd(e, args[i]);
                        }
                        e.wr(")");
                    }
                    else
                    {
                        // Complex (field/index): print prefix then close.
                        e.wr("<");
                        emit_prd(e, c.prd);
                        e.wr("|");
                        emit_cns_prefix_up_to(e, c.cns, term);
                        e.wr("μ̃"); e.wr(term.bind);
                        AirCns* open_c = c.cns;
                        while (open_c != null && open_c != term
                            && open_c.tail != null && open_c.tail != term)
                        { open_c = open_c.tail; }
                        if (open_c != null && open_c.tag == ACNS_CALL) e.wr(")");
                        e.wr(">");
                    }
                    if (is_nop_cmd(term.body)) return;
                    bool body_is_seq = (term.body.tag == ACMD_SEQ)
                                    || (term.body.tag == ACMD_LET)
                                    || (term.body.tag == ACMD_IF)
                                    || (term.body.tag == ACMD_MATCH)
                                    || (term.body.tag == ACMD_WHILE)
                                    || (term.body.tag == ACMD_HANDLE);
                    if (body_is_seq)
                    {
                        e.semi(); e.nl(); e.ind(); emit_cmd(e, term.body);
                    }
                    else
                    {
                        e.wr("; "); emit_cmd(e, term.body);
                    }
                    return;
                }
            }
            // Default: print the raw cut.
            e.wr("<");
            emit_prd(e, c.prd);
            e.wr("|");
            emit_cns(e, c.cns);
            e.wr(">");
            return;
        }
        case ACMD_MU:
        {
            e.wr("μ");
            if (c.binder != null) e.wr(c.binder);
            e.wr(". ");
            emit_cmd(e, c.body);
            return;
        }
        case ACMD_MUTILDE:
        {
            e.wr("μ̃");
            if (c.binder != null) e.wr(c.binder);
            e.wr(". ");
            emit_cmd(e, c.body);
            return;
        }
        case ACMD_SEQ:
        {
            // Print first then rest. Skip nops.
            if (is_nop_cmd(c.body)) { emit_cmd(e, c.next); return; }
            if (is_terminal(c.body)) { emit_cmd(e, c.body); return; } // rest dead
            emit_cmd(e, c.body);
            if (c.next != null && !is_nop_cmd(c.next))
            {
                e.semi(); e.nl(); e.ind();
                emit_cmd(e, c.next);
            }
            return;
        }
        case ACMD_LET:
        {
            // Detect  let x = p; <()|%ret>  → not special; just print let.
            // Suppress  let _ = () — elide.
            bool is_discard = (c.binder == null)
                || (c.binder[0] == '_' && c.binder[1] == 'x');
            if (is_discard && c.prd != null && c.prd.tag == APRD_UNIT
                && is_nop_cmd(c.body)) return;
            if (is_discard && c.prd != null && c.prd.tag == APRD_UNIT)
            {
                // just emit rest
                emit_cmd(e, c.body);
                return;
            }
            // Detect "let x = e; next" → just `let x = e;`
            // Normally ACMD_LET x p rest with rest == () — we print "let x = p"
            e.wr("let ");
            e.wr(c.binder != null ? c.binder : "_x");
            e.wr(" = ");
            emit_prd(e, c.prd);
            if (c.body != null && !is_nop_cmd(c.body))
            {
                e.semi(); e.nl(); e.ind();
                emit_cmd(e, c.body);
            }
            return;
        }
        case ACMD_LETREC:
        {
            // Mutual-recursive let:
            //   letrec x1 = p1; x2 = p2; ... ; body
            e.wr("letrec ");
            // The binders/prds are in mbinders/prds arrays
            for (usz i = 0; i < c.mbinder_count; i++)
            {
                if (i > 0) { e.wr(";"); e.sp(); }
                AirBinder* b = c.mbinders[i];
                if (b != null && b.name != null) { e.wr(b.name); }
                else { e.wr("_"); }
                e.wr(" = ");
                if (i < c.prd_count && c.prds[i] != null) { emit_prd(e, c.prds[i]); }
                else { e.wr("()"); }
            }
            if (c.body != null && !is_nop_cmd(c.body))
            {
                e.semi(); e.nl(); e.ind();
                emit_cmd(e, c.body);
            }
            return;
        }
        case ACMD_BLOCK:
        {
            e.wr("{");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_IF:
        {
            e.wr("if ");
            emit_prd(e, c.prd);
            e.wr(" {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.then_c);
            e.indent_less(); e.nl(); e.ind();
            e.wr("} else {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.else_c);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_WHILE:
        {
            e.wr("while {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_FOR:
        {
            // for-pattern:
            //   for pat = start .. end { body }   OR   for x in coll { body }
            // The lowerer doesn't emit ACMD_FOR directly yet; when it does
            // the binder is in c.binder, iterable prd in c.prd, body in c.body.
            e.wr("for ");
            if (c.binder != null) { e.wr(c.binder); } else { e.wr("_"); }
            e.wr(" in ");
            if (c.prd != null) { emit_prd(e, c.prd); } else { e.wr("()"); }
            e.wr(" {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_MATCH:
        {
            e.wr("match ");
            emit_prd(e, c.prd);
            e.wr(" {");
            e.indent_more();
            for (usz i = 0; i < c.branch_count; i++)
            {
                e.nl(); e.ind();
                AirBranch* br = c.branches[i];
                if (br != null)
                {
                    emit_pat(e, br.pat);
                    e.wr(" → {");
                    e.indent_more(); e.nl(); e.ind();
                    emit_cmd(e, br.body);
                    e.indent_less(); e.nl(); e.ind(); e.wr("}");
                }
            }
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_HANDLE:
        {
            e.wr("handle {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.handled);
            e.indent_less(); e.nl(); e.ind();
            e.wr("} with {");
            e.indent_more();
            for (usz i = 0; i < c.branch_count; i++)
            {
                e.nl(); e.ind();
                AirBranch* br = c.branches[i];
                if (br != null)
                {
                    emit_pat(e, br.pat);
                    e.wr(" → {");
                    e.indent_more(); e.nl(); e.ind();
                    emit_cmd(e, br.body);
                    e.indent_less(); e.nl(); e.ind(); e.wr("}");
                }
            }
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        }
        case ACMD_PERFORM:
        {
            e.wr("perform ");
            if (c.eff_op != null) e.wr(c.eff_op);
            if (c.prd != null) { e.sp(); emit_prd(e, c.prd); }
            return;
        }
        case ACMD_RESUME:
        {
            // resume v  (algebraic-effect resume of the delimited continuation)
            e.wr("resume");
            if (c.prd != null) { e.sp(); emit_prd(e, c.prd); }
            return;
        }
        case ACMD_JUMP:
        {
            e.wr("jump ");
            e.wr(c.target_label != null ? c.target_label : "%lbl");
            if (c.jump_arg_count > 0)
            {
                e.wr("(");
                for (usz i = 0; i < c.jump_arg_count; i++)
                {
                    if (i > 0) e.comma();
                    if (c.jump_args[i] != null) e.wr(c.jump_args[i]);
                }
                e.wr(")");
            }
            return;
        }
        case ACMD_LABEL:
        {
            e.wr("label ");
            if (c.binder != null) e.wr(c.binder);
            if (c.mbinder_count > 0)
            {
                e.wr("(");
                for (usz i = 0; i < c.mbinder_count; i++)
                {
                    if (i > 0) e.comma();
                    if (c.mbinders[i] != null && c.mbinders[i].name != null) e.wr(c.mbinders[i].name);
                }
                e.wr(")");
            }
            e.wr(".");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less();
            return;
        }
        case ACMD_UNSAFE:
            e.wr("unsafe {"); e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        case ACMD_UNCHECKED:
            e.wr("unchecked {"); e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        case ACMD_COMPTIME:
            e.wr("comptime {"); e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        case ACMD_ASSERT:
            e.wr("assert("); if (c.prd != null) emit_prd(e, c.prd); e.wr(")");
            return;
        case ACMD_ASSUME:
            e.wr("assume("); if (c.prd != null) emit_prd(e, c.prd); e.wr(")");
            return;
        case ACMD_UB:
            e.wr("ub ");
            if (c.ub_msg != null) { e.wr("\""); e.wr(c.ub_msg); e.wr("\""); }
            return;
        case ACMD_TRAP: e.wr("trap"); return;
        case ACMD_RET:
            e.wr("ret ");
            if (c.prd != null) emit_prd(e, c.prd);
            return;
        case ACMD_BREAK:    e.wr("break"); return;
        case ACMD_CONTINUE: e.wr("continue"); return;
        case ACMD_DEFER:
            e.wr("defer {"); e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, c.body);
            e.indent_less(); e.nl(); e.ind(); e.wr("}");
            return;
        case ACMD_ASM:
        {
            // asm("…" [: "constraint"(v), …] [: "constraint"(out), …] [: clobbers]) dialect[att|intel]
            e.wr("asm");
            if (c.asm_dialect == 1) { e.wr(" intel"); }
            else { if (c.asm_dialect == 2) e.wr(" att"); }
            e.wr(" \"");
            if (c.asm_text != null) e.wr(c.asm_text);
            e.wr("\"");
            // Operands (if any attached as prds)
            if (c.prd_count > 0)
            {
                e.wr(" :");
                for (usz i = 0; i < c.prd_count; i++)
                {
                    if (i > 0) e.comma();
                    e.sp();
                    if (c.prds[i] != null) emit_prd(e, c.prds[i]);
                }
            }
            return;
        }
        case ACMD_SYSCALL:
        {
            // syscall n(arg1, …, argN)  — Linux-style syscall
            e.wr("syscall");
            if (c.prd != null) { e.sp(); emit_prd(e, c.prd); }
            if (c.prd_count > 0)
            {
                e.wr("(");
                for (usz i = 0; i < c.prd_count; i++)
                {
                    if (i > 0) e.comma();
                    if (c.prds[i] != null) emit_prd(e, c.prds[i]);
                }
                e.wr(")");
            }
            return;
        }
        case ACMD_ATOMIC:
        {
            // atomic op [ordering]  (op from atomic_op, ordering: 0=relaxed,1=acq,2=rel,3=acq_rel,4=seq_cst)
            static char*[5] orders = { "relaxed", "acquire", "release", "acq_rel", "seq_cst" };
            e.wr("atomic");
            switch (c.atomic_op) {
                case 0: e.wr(" load"); break;
                case 1: e.wr(" store"); break;
                case 2: e.wr(" xchg"); break;
                case 3: e.wr(" add"); break;
                case 4: e.wr(" sub"); break;
                case 5: e.wr(" and"); break;
                case 6: e.wr(" or"); break;
                case 7: e.wr(" xor"); break;
                case 8: e.wr(" nand"); break;
                case 9: e.wr(" max"); break;
                case 10: e.wr(" min"); break;
                case 11: e.wr(" umax"); break;
                case 12: e.wr(" umin"); break;
                default: e.wr(" op"); break;
            }
            if (c.atomic_order >= 0 && c.atomic_order < 5) { e.sp(); e.wr(orders[c.atomic_order]); }
            if (c.prd != null) { e.sp(); emit_prd(e, c.prd); }
            return;
        }
        case ACMD_FENCE:
        {
            static char*[5] orders = { "relaxed", "acquire", "release", "acq_rel", "seq_cst" };
            e.wr("fence");
            if (c.atomic_order >= 0 && c.atomic_order < 5) { e.sp(); e.wr(orders[c.atomic_order]); }
            return;
        }
        default: e.wr("?cmd"); return;
    }
}

// ── Declarations ────────────────────────────────────────────────────────
fn void emit_typ_sig(AirEmitter* e, AirTyp* t)
{
    if (t == null || t.tag == ATYP_INFER) { e.wr("_"); return; }
    emit_typ(e, t);
}

fn void emit_decl(AirEmitter* e, AirDecl* d)
{
    if (d == null) return;
    e.ind();
    switch (d.tag)
    {
        case ADECL_IMPORT:
        {
            e.wr("import ");
            if (d.import_path != null) { e.wr(d.import_path); } else { e.wr("?"); }
            if (d.import_alias != null)
            {
                e.wr(" as ");
                e.wr(d.import_alias);
            }
            if (d.import_glob) e.wr(".*");
            e.semi(); e.nl();
            return;
        }
        case ADECL_MODULE:
        {
            e.wr("module ");
            e.wr(d.module_name != null ? d.module_name : (d.name != null ? d.name : "M"));
            e.semi(); e.nl();
            return;
        }
        case ADECL_DECLARE:
        {
            if (d.is_extern) e.wr("extern ");
            e.wr("declare ");
            if (d.name != null) e.wr(d.name);
            e.wr("(");
            for (usz i = 0; i < d.param_count; i++)
            {
                if (i > 0) e.comma();
                AirBinder* b = d.params[i];
                if (b != null)
                {
                    if (b.name != null) { e.wr(b.name); } else { e.wr("_"); }
                    if (b.ty != null && b.ty.tag != ATYP_INFER)
                    {
                        e.wr(": ");
                        emit_typ_sig(e, b.ty);
                    }
                }
            }
            e.wr(")");
            if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER) { e.wr(" : "); emit_typ_sig(e, d.ret_ty); }
            e.semi(); e.nl(); return;
        }
        case ADECL_DEF:
        {
            if (d.fact_state == air_ir::AirFactState.AFACT_AIR_CHECKED)
            {
                // Diagnostic projection of in-memory AIR contracts. Comments
                // do not add an unimplemented text-to-PEAR parser contract.
                e.wr("; air facts: checked");
                if (d.memory_readonly) { e.wr(" memory(read)"); }
                for (usz i = 0; i < d.param_count && i < 64; i++)
                {
                    if (d.params[i] != null && d.params[i].no_capture)
                    { e.wr(" captures(none):"); e.wr(d.params[i].name); }
                }
                e.nl(); e.ind();
            }
            if (d.is_extern) e.wr("extern ");
            if (d.is_pub) e.wr("pub ");
            if (d.param_count > 0) { e.wr("fn "); } else { e.wr("def "); }
            if (d.name != null) e.wr(d.name);
            if (d.typaram_count > 0)
            {
                e.wr("<");
                for (usz i = 0; i < d.typaram_count; i++)
                {
                    if (i > 0) e.comma();
                    if (d.typarams[i] != null && d.typarams[i].name != null)
                    {
                        e.wr(d.typarams[i].name);
                    }
                }
                e.wr(">");
            }
            if (d.param_count > 0)
            {
                e.wr("(");
                for (usz i = 0; i < d.param_count; i++)
                {
                    if (i > 0) e.comma();
                    AirBinder* b = d.params[i];
                    if (b != null)
                    {
                        if (b.name != null) { e.wr(b.name); } else { e.wr("_"); }
                        if (b.ty != null && b.ty.tag != ATYP_INFER)
                        {
                            e.wr(": ");
                            emit_typ_sig(e, b.ty);
                        }
                    }
                }
                e.wr(")");
            }
            if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER)
            {
                e.wr(" -> ");
                emit_typ_sig(e, d.ret_ty);
            }
            e.wr(" {");
            e.indent_more(); e.nl(); e.ind();
            emit_cmd(e, d.def_body);
            e.indent_less(); e.nl(); e.ind();
            e.wr("}"); e.nl();
            return;
        }
        case ADECL_DEFCO:
        {
            e.wr("codefn ");
            if (d.name != null) e.wr(d.name);
            e.wr(" { ... }"); e.nl();
            return;
        }
        case ADECL_DATA:
        {
            if (d.is_pub) e.wr("pub ");
            e.wr("data ");
            if (d.name != null) e.wr(d.name);
            e.wr(" {"); e.nl();
            e.indent_more();
            for (usz i = 0; i < d.ctor_count; i++)
            {
                e.ind();
                AirCtorDecl* ct = d.ctors[i];
                if (ct != null)
                {
                    if (ct.name != null) e.wr(ct.name);
                    if (ct.field_count > 0)
                    {
                        e.wr("(");
                        for (usz j = 0; j < ct.field_count; j++)
                        {
                            if (j > 0) e.comma();
                            AirField* f = ct.fields[j];
                            if (f != null)
                            {
                                if (f.name != null) { e.wr(f.name); e.wr(": "); }
                                emit_typ_sig(e, f.ty);
                            }
                        }
                        e.wr(")");
                    }
                    e.semi(); e.nl();
                }
            }
            e.indent_less();
            e.ind(); e.wr("}"); e.nl();
            return;
        }
        case ADECL_CODATA:
        {
            if (d.is_pub) e.wr("pub ");
            e.wr("codata ");
            if (d.name != null) e.wr(d.name);
            e.wr(" {"); e.nl();
            e.indent_more();
            for (usz i = 0; i < d.dtor_count; i++)
            {
                e.ind();
                AirDtorDecl* dd = d.dtors[i];
                if (dd != null)
                {
                    e.wr(".");
                    if (dd.name != null) e.wr(dd.name);
                    if (dd.param_count > 0)
                    {
                        e.wr("(");
                        for (usz j = 0; j < dd.param_count; j++)
                        {
                            if (j > 0) e.comma();
                            AirField* f = dd.params[j];
                            if (f != null)
                            {
                                if (f.name != null) { e.wr(f.name); e.wr(": "); }
                                emit_typ_sig(e, f.ty);
                            }
                        }
                        e.wr(")");
                    }
                    if (dd.return_ty != null) { e.wr(" : "); emit_typ_sig(e, dd.return_ty); }
                    e.semi(); e.nl();
                }
            }
            e.indent_less();
            e.ind(); e.wr("}"); e.nl();
            return;
        }
        case ADECL_EFFECT:
        {
            e.wr("effect ");
            if (d.name != null) e.wr(d.name);
            e.wr(" {"); e.nl();
            e.indent_more();
            for (usz i = 0; i < d.op_count; i++)
            {
                e.ind();
                AirEffectOp* op = d.ops[i];
                if (op != null)
                {
                    if (op.name != null) e.wr(op.name);
                    if (op.op_ty != null) { e.wr(": "); emit_typ_sig(e, op.op_ty); }
                    e.semi(); e.nl();
                }
            }
            e.indent_less();
            e.ind(); e.wr("}"); e.nl();
            return;
        }
        default:
            e.wr("; unknown decl"); e.nl();
            return;
    }
}

// ── Public entry point ─────────────────────────────────────────────────
fn void emit_module(AirModule* mod, AirLower* lr, char* path)
{
    AirEmitter e;
    e.mod = mod;
    e.lr = lr;
    e.indent = 0;
    e.need_space = false;
    e.in_tail = false;
    void* std_out = get_stdout();
    if (path != null)
    {
        void* f = fopen(path, "w");
        e.out = (f != null) ? f : std_out;
    }
    else { e.out = std_out; }

    e.wr("; AIR 1.0 -- Abstractive Intermediate Representation (\xce\xbb\xcc\x84\xce\xbc\xce\xbc\xcc\x83)\n");
    e.wr("; generated by pfront (pride) -- stable text format -- see docs/specs/AIR.md\n\n");

    if (mod.name != null)
    {
        e.wr("module ");
        e.wr(mod.name);
        e.wr(";\n\n");
    }

    for (usz i = 0; i < mod.decl_count; i++)
    {
        emit_decl(&e, mod.decls[i]);
    }

    e.wr("\n; end of AIR\n");

    if (path != null && e.out != std_out) { fclose(e.out); }
}
