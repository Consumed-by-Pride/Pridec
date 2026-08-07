// ============================================================================
// air_emit.c3 — Emitter from lowered AirModule IR (λ̄μμ̃) → stable AIR 1.0 text.
// ============================================================================
module air_emit;

import pfront_core;
import air_ir;
import air_lower;
import air_scope;

extern fn int fprintf(void* f, char* fmt, ...);
extern fn int fputs(char* s, void* f);
extern fn int fputc(int c, void* f);
extern fn int snprintf(char* buf, usz n, char* fmt, ...);

struct AirPrinter {
    void* out;
    int   indent;
    bool  need_sep;
}

fn void AirPrinter.nl(AirPrinter* p)    { fputc(10, p.out); for (int i = 0; i < p.indent; i++) fputc(' ', p.out); p.need_sep = false; return; }
fn void AirPrinter.p(AirPrinter* p, char* s)   { if (s != null) fputs(s, p.out); p.need_sep = false; return; }
fn void AirPrinter.sp(AirPrinter* p)    { fputc(' ', p.out); return; }
fn void AirPrinter.semi(AirPrinter* p)  { fputc(';', p.out); p.nl(); return; }
fn void AirPrinter.ind(AirPrinter* p)   { p.indent = p.indent + 2; return; }
fn void AirPrinter.ded(AirPrinter* p)   { if (p.indent >= 2) p.indent = p.indent - 2; return; }

fn bool is_anon_hole(char* nm) {
    if (nm == null) return false;
    // · is UTF-8 0xC2 0xB7
    if (nm[0] == 0xc2 && nm[1] == 0xb7 && nm[2] == 0) return true;
    return false;
}
fn void mult_p(AirPrinter* p, AirMult m) {
    switch (m) {
        case AMULT_UNR:   return;
        case AMULT_LIN:   p.p("lin "); return;
        case AMULT_AFF:   p.p("aff "); return;
        case AMULT_EXACT: p.p("1 ");   return;
        default: return;
    }
}

fn void AirPrinter.typ(AirPrinter* p, AirTyp* t) {
    if (t == null) { p.p("_"); return; }
    switch (t.tag) {
        case ATYP_I8:     p.p("i8"); return;
        case ATYP_I16:    p.p("i16"); return;
        case ATYP_I32:    p.p("i32"); return;
        case ATYP_I64:    p.p("i64"); return;
        case ATYP_I128:   p.p("i128"); return;
        case ATYP_ISZ:    p.p("isz"); return;
        case ATYP_U8:     p.p("u8"); return;
        case ATYP_U16:    p.p("u16"); return;
        case ATYP_U32:    p.p("u32"); return;
        case ATYP_U64:    p.p("u64"); return;
        case ATYP_U128:   p.p("u128"); return;
        case ATYP_USZ:    p.p("usz"); return;
        case ATYP_F16:    p.p("f16"); return;
        case ATYP_F32:    p.p("f32"); return;
        case ATYP_F64:    p.p("f64"); return;
        case ATYP_F128:   p.p("f128"); return;
        case ATYP_BOOL:   p.p("bool"); return;
        case ATYP_CHAR:   p.p("char"); return;
        case ATYP_STR:    p.p("str"); return;
        case ATYP_BYTES:  p.p("bytes"); return;
        case ATYP_UNIT:   p.p("()"); return;
        case ATYP_BOTTOM: p.p("!"); return;
        case ATYP_INFER:  p.p("_"); return;
        case ATYP_SELF:   p.p("Self"); return;
        case ATYP_NOMINAL:
        case ATYP_PATH: {
            p.p(t.name != null ? t.name : "?");
            if (t.arg_count > 0) {
                p.p("<");
                for (usz i = 0; i < t.arg_count; i++) {
                    if (i > 0) p.p(", ");
                    p.typ(t.args[i]);
                }
                p.p(">");
            }
            return;
        }
        case ATYP_VAR: { p.p(t.name != null ? t.name : "?t"); return; }
        case ATYP_ARROW: {
            if (t.arg_count >= 2) { p.typ(t.args[0]); p.p(" -> "); p.typ(t.args[1]); }
            else { p.p("?->?"); }
            return;
        }
        case ATYP_TUPLE: {
            p.p("(");
            for (usz i = 0; i < t.arg_count; i++) {
                if (i > 0) p.p(", ");
                p.typ(t.args[i]);
            }
            if (t.arg_count == 1) p.p(",");
            p.p(")");
            return;
        }
        case ATYP_RECORD: {
            p.p("{");
            for (usz i = 0; i < t.rec_field_count; i++) {
                if (i > 0) p.p(", ");
                if (t.rec_fields[i] != null && t.rec_fields[i].name != null) {
                    p.p(t.rec_fields[i].name); p.p(": _");
                }
            }
            p.p("}");
            return;
        }
        case ATYP_ARRAY: {
            p.p("[");
            if (t.arg_count >= 1) p.typ(t.args[0]);
            p.p("; ");
            char[32] b; snprintf(&b[0], 32, "%ld", t.ival); p.p(&b[0]);
            p.p("]");
            return;
        }
        case ATYP_SLICE: { p.p("["); if (t.arg_count >= 1) p.typ(t.args[0]); p.p("]"); return; }
        case ATYP_PTR: { p.p("*"); if (t.arg_count >= 1) { p.typ(t.args[0]); } else { p.p("_"); } return; }
        case ATYP_REF: { p.p("&"); if (t.arg_count >= 1) { p.typ(t.args[0]); } else { p.p("_"); } return; }
        case ATYP_REF_MUT: { p.p("&mut "); if (t.arg_count >= 1) { p.typ(t.args[0]); } else { p.p("_"); } return; }
        case ATYP_SUM: {
            p.p("(");
            for (usz i = 0; i < t.arg_count; i++) {
                if (i > 0) p.p(" | ");
                p.typ(t.args[i]);
            }
            p.p(")");
            return;
        }
        case ATYP_UNION: {
            if (t.arg_count >= 2) { p.typ(t.args[0]); p.p(" | "); p.typ(t.args[1]); }
            else { p.p("?union"); }
            return;
        }
        case ATYP_INTERSECT: {
            if (t.arg_count >= 2) { p.typ(t.args[0]); p.p(" & "); p.typ(t.args[1]); }
            else { p.p("?intersect"); }
            return;
        }
        case ATYP_NEGATION: { p.p("-"); if (t.arg_count >= 1) { p.typ(t.args[0]); } else { p.p("_"); } return; }
        case ATYP_FORALL: { p.p("forall "); p.p(t.name != null ? t.name : "a"); p.p(". "); if (t.arg_count >= 1) p.typ(t.args[0]); return; }
        case ATYP_EXISTS: { p.p("exists "); p.p(t.name != null ? t.name : "a"); p.p(". "); if (t.arg_count >= 1) p.typ(t.args[0]); return; }
        case ATYP_BANG: { if (t.arg_count >= 1) { p.typ(t.args[0]); } else { p.p("_"); } p.p("!"); return; }
        case ATYP_QUERY: { p.p("?"); if (t.arg_count >= 1) p.typ(t.args[0]); return; }
        case ATYP_EFFROW: {
            p.p("<|");
            for (usz i = 0; i < t.arg_count; i++) {
                if (i > 0) p.p(", ");
                p.typ(t.args[i]);
            }
            if (t.eff_tail != null) { if (t.arg_count > 0) p.p(", "); p.p(".."); }
            p.p("|>");
            return;
        }
        case ATYP_MULT: { p.p("Mult"); return; }
        case ATYP_TYPEOF:
        case ATYP_REFINE:
        case ATYP_GENERIC_APP: { p.p("?typ"); return; }
        default: { char[32] b; snprintf(&b[0],32,"?typ(%d)",(int)t.tag); p.p(&b[0]); return; }
    }
}

fn void AirPrinter.binder(AirPrinter* p, AirBinder* b) {
    if (b == null) { p.p("_"); return; }
    mult_p(p, b.mult);
    if (b.is_mutable) p.p("mut(");
    p.p(b.name != null ? b.name : "_b");
    if (b.ty != null) { p.p(": "); p.typ(b.ty); }
    if (b.is_mutable) p.p(")");
    return;
}

fn void AirPrinter.pat(AirPrinter* p, AirPat* pa) {
    if (pa == null) { p.p("_"); return; }
    switch (pa.tag) {
        case APAT_WILD: { p.p("_"); return; }
        case APAT_BIND: { p.p(pa.name != null ? pa.name : "_x"); return; }
        case APAT_INT: { char[32] b; snprintf(&b[0],32,"%ld",pa.ival); p.p(&b[0]); return; }
        case APAT_FLOAT: { char[64] b; snprintf(&b[0],64,"%g",pa.fval); p.p(&b[0]); return; }
        case APAT_BOOL: { p.p(pa.ival != 0 ? "true" : "false"); return; }
        case APAT_CHAR: { p.p("'"); { char[2] b; b[0] = (char)pa.ival; b[1] = 0; p.p(&b[0]); } p.p("'"); return; }
        case APAT_STRING: { p.p("\""); p.p(pa.name != null ? pa.name : ""); p.p("\""); return; }
        case APAT_TUPLE:
        case APAT_ARRAY: {
            p.p("(");
            for (usz i = 0; i < pa.sub_count; i++) {
                if (i > 0) p.p(", ");
                p.pat(pa.sub[i]);
            }
            p.p(")");
            return;
        }
        case APAT_VARIANT: {
            if (pa.name != null) p.p(pa.name);
            if (pa.sub_count > 0) {
                p.p("(");
                for (usz i = 0; i < pa.sub_count; i++) { if (i > 0) p.p(", "); p.pat(pa.sub[i]); }
                p.p(")");
            }
            return;
        }
        case APAT_AS: { p.pat(pa.sub_count > 0 ? pa.sub[0] : null); p.p(" as "); if (pa.as_pat != null) p.pat(pa.as_pat); return; }
        case APAT_OR: { if (pa.sub_count >= 2) { p.pat(pa.sub[0]); p.p(" | "); p.pat(pa.sub[1]); } return; }
        case APAT_RECORD: case APAT_RANGE: case APAT_REF: case APAT_REST:
        default: { p.p("?pat"); return; }
    }
}

fn char* binop_name(AirBinop op) {
    switch (op) {
        case ABIN_ADD: return "+";
        case ABIN_SUB: return "-";
        case ABIN_MUL: return "*";
        case ABIN_DIV: return "/";
        case ABIN_MOD: return "%";
        case ABIN_AND: return "&";
        case ABIN_OR:  return "|";
        case ABIN_XOR: return "^";
        case ABIN_SHL: return "<<";
        case ABIN_SHR: return ">>";
        case ABIN_LAND: return "&&";
        case ABIN_LOR:  return "||";
        case ABIN_EQ:  return "==";
        case ABIN_NEQ: return "!=";
        case ABIN_LT:  return "<";
        case ABIN_GT:  return ">";
        case ABIN_LE:  return "<=";
        case ABIN_GE:  return ">=";
        case ABIN_PIPE: return "|>";
        default: return "?binop";
    }
}
fn char* unop_name(AirUnop op) {
    switch (op) {
        case AUN_NEG: return "-";
        case AUN_NOT: return "!";
        case AUN_BITNOT: return "~";
        case AUN_DEREF: return "*";
        case AUN_REF: case AUN_ADDR: return "&";
        case AUN_COMULT: return "?";
        default: return "?unop";
    }
}

fn void AirPrinter.prd(AirPrinter* p, AirPrd* v) {
    if (v == null) { p.p("()"); return; }
    switch (v.tag) {
        case APRD_VAR: { p.p(v.name != null ? v.name : "?_"); return; }
        case APRD_CON: { p.p(v.name != null ? v.name : "?C"); return; }
        case APRD_INT: { char[32] b; snprintf(&b[0],32,"%ld",v.ival); p.p(&b[0]); return; }
        case APRD_FLOAT: { char[64] b; snprintf(&b[0],64,"%g",v.fval); p.p(&b[0]); return; }
        case APRD_BOOL: { p.p(v.bval ? "true" : "false"); return; }
        case APRD_CHAR: { p.p("'"); char[2] b; b[0] = v.cval; b[1] = 0; p.p(&b[0]); p.p("'"); return; }
        case APRD_STRING: { p.p("\""); if (v.name != null) p.p(v.name); p.p("\""); return; }
        case APRD_BYTES: { p.p("b\"...\""); return; }
        case APRD_UNIT: { p.p("()"); return; }
        case APRD_NULL: { p.p("null"); return; }
        case APRD_TUPLE: case APRD_ARRAY: case APRD_RECORD: {
            p.p("(");
            for (usz i = 0; i < v.sub_count; i++) { if (i > 0) p.p(", "); p.prd(v.subs[i]); }
            if (v.sub_count == 1) p.p(",");
            p.p(")");
            return;
        }
        case APRD_INL: { p.p("inl("); if (v.sub_count >= 1) p.prd(v.subs[0]); p.p(")"); return; }
        case APRD_INR: { p.p("inr("); if (v.sub_count >= 1) p.prd(v.subs[0]); p.p(")"); return; }
        case APRD_LAMBDA: {
            p.p("λ(");
            for (usz i = 0; i < v.binder_count; i++) { if (i > 0) p.p(", "); p.binder(v.binders[i]); }
            p.p(").");
            if (v.body != null) { p.sp(); p.cmd(v.body); }
            return;
        }
        case APRD_MU: { p.p("μ"); if (v.name != null) p.p(v.name); p.p("."); if (v.body != null) { p.sp(); p.cmd(v.body); } return; }
        case APRD_COMETA: { p.p("μ̃"); if (v.name != null) p.p(v.name); p.p("."); if (v.body != null) { p.sp(); p.cmd(v.body); } return; }
        case APRD_BINOP: {
            if (v.sub_count >= 2) {
                p.p("("); p.prd(v.subs[0]); p.p(")");
                p.sp(); p.p(binop_name(v.bop)); p.sp();
                p.p("("); p.prd(v.subs[1]); p.p(")");
            } else { p.p("?binop"); }
            return;
        }
        case APRD_UNOP: { p.p(unop_name(v.uop)); if (v.sub_count >= 1) { p.p("("); p.prd(v.subs[0]); p.p(")"); } return; }
        case APRD_COERCE: { p.p("coerce("); if (v.sub_count >= 1) p.prd(v.subs[0]); if (v.ty != null) { p.p(": "); p.typ(v.ty); } p.p(")"); return; }
        case APRD_SIZEOF: { p.p("sizeof("); p.typ(v.ty); p.p(")"); return; }
        case APRD_ALIGNOF: { p.p("alignof("); p.typ(v.ty); p.p(")"); return; }
        case APRD_OFFSETOF: { p.p("offsetof(...)"); return; }
        case APRD_REIFY: case APRD_EVAL: case APRD_QUOTE: case APRD_SPLICE: { p.p("«msp»"); return; }
        case APRD_POISON: { p.p("poison"); return; }
        case APRD_UNREACHABLE_VAL: { p.p("unreachable"); return; }
        default: { char[32] b; snprintf(&b[0],32,"?prd(%d)",(int)v.tag); p.p(&b[0]); return; }
    }
}

fn bool is_nop_cmd(AirCmd* c) {
    if (c == null) return true;
    if (c.tag == ACMD_NOP) return true;
    if (c.tag == ACMD_CUT && c.prd != null && c.prd.tag == APRD_UNIT
        && c.cns != null && is_anon_hole(c.cns.name)) return true;
    return false;
}

fn void AirPrinter.cns(AirPrinter* p, AirCns* e) {
    if (e == null) { p.p("·"); return; }
    switch (e.tag) {
        case ACNS_COVAR: { if (is_anon_hole(e.name)) { p.p("·"); } else { p.p(e.name != null ? e.name : "%?k"); } return; }
        case ACNS_STACK: case ACNS_CALL: {
            bool is_call = (e.tag == ACNS_CALL);
            if (is_call) p.p("call(");
            bool first = true;
            AirCns* cur = e;
            while (cur != null && (cur.tag == ACNS_CALL || cur.tag == ACNS_STACK)) {
                if (!first) p.p(", ");
                p.prd(cur.prd);
                first = false;
                cur = cur.tail;
            }
            if (cur != null && is_call) { p.p("; "); p.cns(cur); }
            else if (cur != null) { p.p(" :: "); p.cns(cur); }
            if (is_call) p.p(")");
            return;
        }
        case ACNS_FST: { p.p("fst("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_SND: { p.p("snd("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_PROJ: { char[32] b; snprintf(&b[0],32,"#%ld(",e.idx); p.p(&b[0]); p.cns(e.tail); p.p(")"); return; }
        case ACNS_FIELD: { p.p("."); p.p(e.name != null ? e.name : "f"); p.p("("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_INDEX: { p.p("["); p.prd(e.prd); p.p("]("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_CASE: {
            p.p("case {");
            for (usz i = 0; i < e.branch_count; i++) {
                p.sp();
                if (e.branches[i] != null) { p.pat(e.branches[i].pat); p.p(" => "); p.cmd(e.branches[i].body); }
                if (i + 1 < e.branch_count) p.p(",");
            }
            p.p("}");
            return;
        }
        case ACNS_COCASE: {
            p.p("cocase {");
            for (usz i = 0; i < e.cobranch_count; i++) {
                p.sp();
                if (e.cobranches[i] != null) {
                    p.p(e.cobranches[i].dtor_name != null ? e.cobranches[i].dtor_name : "?d");
                    if (e.cobranches[i].binder_count > 0) {
                        p.p("(");
                        for (usz j = 0; j < e.cobranches[i].binder_count; j++) { if (j>0) p.p(", "); p.p(e.cobranches[i].binders[j]); }
                        p.p(")");
                    }
                    p.p(" => "); p.cmd(e.cobranches[i].body);
                }
                if (i + 1 < e.cobranch_count) p.p(",");
            }
            p.p("}");
            return;
        }
        case ACNS_COMU: { p.p("μ̃"); p.p(e.bind != null ? e.bind : "x"); p.p("."); if (e.body != null) { p.sp(); p.cmd(e.body); } return; }
        case ACNS_DEFAULT: { p.p("default("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_ASCRIBE: { p.p("(: "); p.typ(e.ty); p.p(")("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_SUBST: { p.p("subst("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_SHARE: { p.p("share("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_ERASE: { p.p("erase("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_DEREF: { p.p("deref("); p.cns(e.tail); p.p(")"); return; }
        case ACNS_STORE: { p.p("store("); p.prd(e.prd); p.p(", "); p.cns(e.tail); p.p(")"); return; }
        case ACNS_LABEL: { p.p(e.label_name != null ? e.label_name : "?L"); p.p("{"); if (e.body != null) { p.sp(); p.cmd(e.body); p.sp(); } p.p("}"); return; }
        default: { char[32] b; snprintf(&b[0],32,"?cns(%d)",(int)e.tag); p.p(&b[0]); return; }
    }
}

fn void AirPrinter.cmd(AirPrinter* p, AirCmd* c) {
    if (c == null) { p.p("/*null*/"); return; }
    if (is_nop_cmd(c)) { p.p("()"); return; }
    switch (c.tag) {
        case ACMD_CUT: {
            if (c.prd != null && c.prd.tag == APRD_UNIT && c.cns != null && c.cns.tag == ACNS_COMU && c.cns.body != null) {
                p.cmd(c.cns.body); return;
            }
            p.p("<"); p.prd(c.prd); p.p("|"); p.cns(c.cns); p.p(">");
            return;
        }
        case ACMD_MU: { p.p("μ"); p.p(c.binder != null ? c.binder : "%k"); p.p("."); if (c.body != null) { p.sp(); p.cmd(c.body); } return; }
        case ACMD_MUTILDE: { p.p("μ̃"); p.p(c.binder != null ? c.binder : "x"); p.p("."); if (c.body != null) { p.sp(); p.cmd(c.body); } return; }
        case ACMD_JUMP: { p.p("goto "); p.p(c.target_label != null ? c.target_label : "?L");
            if (c.jump_arg_count > 0) { p.p("("); for (usz i=0;i<c.jump_arg_count;i++){if(i>0)p.p(", ");p.p(c.jump_args[i]);} p.p(")"); } return; }
        case ACMD_SEQ: {
            if (c.body != null && c.body.tag == ACMD_CUT && c.body.cns != null && c.body.cns.tag == ACNS_COMU
                && is_nop_cmd(c.body.cns.body) && !is_nop_cmd(c.next))
            {
                p.p("let "); p.p(c.body.cns.bind != null ? c.body.cns.bind : "_");
                if (c.body.prd != null) { p.p(" = "); p.prd(c.body.prd); }
                p.p(";"); p.nl(); p.cmd(c.next);
                return;
            }
            p.cmd(c.body);
            if (is_nop_cmd(c.next)) { return; }
            p.semi(); p.cmd(c.next);
            return;
        }
        case ACMD_BLOCK: { p.p("{"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_LET: {
            if (c.mbinder_count > 0 && c.mbinders[0] != null && c.mbinders[0].is_mutable) { p.p("mut("); }
            p.p("let ");
            if (c.binder != null) { p.p(c.binder); }
            else if (c.mbinder_count > 0 && c.mbinders[0] != null) { p.binder(c.mbinders[0]); }
            else { p.p("_"); }
            if (c.mbinder_count > 0 && c.mbinders[0] != null && c.mbinders[0].is_mutable) { p.p(")"); }
            if (c.prd != null) { p.p(" = "); p.prd(c.prd); }
            if (!is_nop_cmd(c.body)) { p.p(";"); p.nl(); p.cmd(c.body); }
            return;
        }
        case ACMD_LETREC: {
            p.p("letrec ");
            for (usz i=0;i<c.mbinder_count;i++) {
                if (i>0) p.p(" and ");
                p.binder(c.mbinders[i]);
                if (i < c.prd_count && c.prds[i] != null) { p.p(" = "); p.prd(c.prds[i]); }
            }
            if (!is_nop_cmd(c.body)) { p.p(";"); p.nl(); p.cmd(c.body); }
            return;
        }
        case ACMD_IF: {
            p.p("if ("); p.prd(c.prd); p.p(") {"); p.ind(); p.nl();
            p.cmd(c.then_c);
            p.ded(); p.nl(); p.p("}");
            if (c.else_c != null && !is_nop_cmd(c.else_c)) { p.p(" else {"); p.ind(); p.nl(); p.cmd(c.else_c); p.ded(); p.nl(); p.p("}"); }
            return;
        }
        case ACMD_WHILE: { p.p("while ("); p.prd(c.prd); p.p(") {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_FOR: { p.p("for ("); p.prd(c.prd); p.p(") {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_MATCH: {
            p.p("match "); p.prd(c.prd); p.p(" {"); p.ind(); p.nl();
            for (usz i=0;i<c.branch_count;i++) {
                if (c.branches[i] != null) {
                    p.pat(c.branches[i].pat); p.p(" => {"); p.ind(); p.nl();
                    p.cmd(c.branches[i].body); p.ded(); p.nl(); p.p("}");
                }
                if (i+1<c.branch_count) { p.semi(); } else { p.nl(); }
            }
            p.p("}");
            return;
        }
        case ACMD_HANDLE: {
            p.p("handle {"); p.ind(); p.nl(); p.cmd(c.handled); p.ded(); p.nl();
            p.p("} with {"); p.ind(); p.nl();
            for (usz i=0;i<c.branch_count;i++) {
                if (c.branches[i] != null) {
                    p.pat(c.branches[i].pat); p.p(" => {"); p.ind(); p.nl();
                    p.cmd(c.branches[i].body); p.ded(); p.nl(); p.p("}");
                }
                if (i+1<c.branch_count) { p.semi(); } else { p.nl(); }
            }
            p.p("}");
            return;
        }
        case ACMD_PERFORM: { p.p("perform "); p.p(c.eff_op != null ? c.eff_op : "?op"); if (c.prd != null) { p.p("("); p.prd(c.prd); p.p(")"); } return; }
        case ACMD_RESUME: { p.p("resume"); if (c.prd != null) { p.p(" "); p.prd(c.prd); } return; }
        case ACMD_UNSAFE: { p.p("unsafe {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_UNCHECKED: { p.p("unchecked {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_COMPTIME: { p.p("comptime {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_ASSERT: { p.p("assert("); p.prd(c.prd); p.p(")"); return; }
        case ACMD_ASSUME: { p.p("assume("); p.prd(c.prd); p.p(")"); return; }
        case ACMD_UB: { p.p("ub \""); p.p(c.ub_msg != null ? c.ub_msg : ""); p.p("\""); return; }
        case ACMD_TRAP: { p.p("trap"); return; }
        case ACMD_RET: { p.p("ret"); if (c.prd != null) { p.p(" "); p.prd(c.prd); } return; }
        case ACMD_BREAK: { p.p("break"); if (c.target_label != null) { p.p(" "); p.p(c.target_label); } return; }
        case ACMD_CONTINUE: { p.p("continue"); if (c.target_label != null) { p.p(" "); p.p(c.target_label); } return; }
        case ACMD_DEFER: { p.p("defer {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_LABEL: { p.p("label "); p.p(c.binder != null ? c.binder : "?L");
            for (usz i=0;i<c.mbinder_count;i++){ p.sp(); p.binder(c.mbinders[i]); }
            p.p(" {"); p.ind(); p.nl(); p.cmd(c.body); p.ded(); p.nl(); p.p("}"); return; }
        case ACMD_ASM: { p.p("asm"); if (c.asm_dialect != 0) p.p("(att)"); p.p(" \""); p.p(c.asm_text != null ? c.asm_text : ""); p.p("\""); return; }
        case ACMD_SYSCALL: { p.p("syscall("); for (usz i=0;i<c.prd_count;i++){if(i>0)p.p(", ");p.prd(c.prds[i]);} p.p(")"); return; }
        case ACMD_ATOMIC: { char[64] b; snprintf(&b[0],64,"atomic(op=%d,order=%d)",(int)c.atomic_op,(int)c.atomic_order); p.p(&b[0]); return; }
        case ACMD_FENCE: { char[32] b; snprintf(&b[0],32,"fence(order=%d)",(int)c.atomic_order); p.p(&b[0]); return; }
        case ACMD_NOP: { p.p("()"); return; }
        default: { char[32] b; snprintf(&b[0],32,"; UNKNOWN_CMD(%d)",(int)c.tag); p.p(&b[0]); return; }
    }
}

fn void AirPrinter.decl(AirPrinter* p, AirDecl* d) {
    if (d == null) return;
    switch (d.tag) {
        case ADECL_IMPORT: {
            p.p("import "); p.p(d.import_path != null ? d.import_path : "?");
            if (d.import_alias != null) { p.p(" as "); p.p(d.import_alias); }
            if (d.import_glob) { p.p(".*"); }
            p.semi(); return;
        }
        case ADECL_MODULE: { p.p("mod "); p.p(d.name != null ? d.name : "?"); p.p(";"); p.nl(); return; }
        case ADECL_DECLARE: {
            if (d.is_extern) p.p("extern ");
            p.p("fn "); p.p(d.name != null ? d.name : "?fn");
            if (d.typaram_count > 0) { p.p("<"); for (usz i=0;i<d.typaram_count;i++){if(i>0)p.p(", ");p.binder(d.typarams[i]);} p.p(">"); }
            p.p("(");
            for (usz i=0;i<d.param_count;i++) { if (i>0) p.p(", "); p.binder(d.params[i]); }
            if (d.is_varargs) { if (d.param_count > 0) p.p(", "); p.p("..."); }
            p.p(")");
            if (d.ret_ty != null) { p.p(" -> "); p.typ(d.ret_ty); }
            if (d.extern_link != null) { p.p(" = \""); p.p(d.extern_link); p.p("\""); }
            p.semi(); return;
        }
        case ADECL_DEF: {
            if (d.is_pub) p.p("pub ");
            mult_p(p, d.mult);
            p.p("fn "); p.p(d.name != null ? d.name : "?fn");
            if (d.typaram_count > 0) { p.p("<"); for (usz i=0;i<d.typaram_count;i++){if(i>0)p.p(", ");p.binder(d.typarams[i]);} p.p(">"); }
            p.p("(");
            for (usz i=0;i<d.param_count;i++) { if (i>0) p.p(", "); p.binder(d.params[i]); }
            if (d.is_varargs) { if (d.param_count > 0) p.p(", "); p.p("..."); }
            p.p(")");
            if (d.ret_ty != null) { p.p(" -> "); p.typ(d.ret_ty); }
            p.p(" {"); p.ind(); p.nl();
            p.cmd(d.def_body);
            p.ded(); p.nl(); p.p("}"); p.nl(); p.nl();
            return;
        }
        case ADECL_DATA: {
            p.p("data "); p.p(d.name != null ? d.name : "?data");
            if (d.typaram_count > 0) { p.p("<"); for (usz i=0;i<d.typaram_count;i++){if(i>0)p.p(", ");p.binder(d.typarams[i]);} p.p(">"); }
            p.p(" {"); p.ind(); p.nl();
            for (usz i=0;i<d.ctor_count;i++) {
                AirCtorDecl* c = d.ctors[i]; if (c == null) continue;
                p.p(c.name != null ? c.name : "?C");
                if (c.field_count > 0) {
                    p.p("(");
                    for (usz j=0;j<c.field_count;j++) {
                        if (j>0) p.p(", ");
                        if (c.fields[j] != null) {
                            mult_p(p, c.fields[j].mult);
                            if (c.fields[j].name != null) { p.p(c.fields[j].name); p.p(": "); }
                            p.typ(c.fields[j].ty);
                        }
                    }
                    p.p(")");
                }
                if (i+1<d.ctor_count) p.p(",");
                p.nl();
            }
            p.ded(); p.p("}"); p.nl(); p.nl();
            return;
        }
        case ADECL_CODATA: {
            p.p("codata "); p.p(d.name != null ? d.name : "?codata");
            if (d.typaram_count > 0) { p.p("<"); for (usz i=0;i<d.typaram_count;i++){if(i>0)p.p(", ");p.binder(d.typarams[i]);} p.p(">"); }
            p.p(" {"); p.ind(); p.nl();
            for (usz i=0;i<d.dtor_count;i++) {
                AirDtorDecl* dd = d.dtors[i]; if (dd == null) continue;
                p.p(dd.name != null ? dd.name : "?d");
                if (dd.param_count > 0) {
                    p.p("(");
                    for (usz j=0;j<dd.param_count;j++) {
                        if (j>0) p.p(", ");
                        if (dd.params[j] != null) {
                            mult_p(p, dd.params[j].mult);
                            if (dd.params[j].name != null) { p.p(dd.params[j].name); p.p(": "); }
                            p.typ(dd.params[j].ty);
                        }
                    }
                    p.p(")");
                }
                if (dd.return_ty != null) { p.p(" -> "); p.typ(dd.return_ty); }
                if (i+1<d.dtor_count) p.p(",");
                p.nl();
            }
            p.ded(); p.p("}"); p.nl(); p.nl();
            return;
        }
        case ADECL_DEFCO: {
            p.p("codef "); p.p(d.name != null ? d.name : "?codef");
            if (d.param_count > 0) {
                p.p("(");
                for (usz i=0;i<d.param_count;i++) { if (i>0) p.p(", "); p.binder(d.params[i]); }
                p.p(")");
            }
            p.p(" {"); p.ind(); p.nl(); p.cmd(d.def_body); p.ded(); p.nl(); p.p("}"); p.nl(); p.nl();
            return;
        }
        case ADECL_EFFECT: {
            p.p("effect "); p.p(d.name != null ? d.name : "?eff");
            if (d.typaram_count > 0) { p.p("<"); for (usz i=0;i<d.typaram_count;i++){if(i>0)p.p(", ");p.binder(d.typarams[i]);} p.p(">"); }
            p.p(" {"); p.ind(); p.nl();
            for (usz i=0;i<d.op_count;i++) {
                if (d.ops[i] != null) {
                    p.p("op "); p.p(d.ops[i].name != null ? d.ops[i].name : "?op");
                    if (d.ops[i].op_ty != null) { p.p(": "); p.typ(d.ops[i].op_ty); }
                    if (i+1<d.op_count) { p.semi(); } else { p.nl(); }
                }
            }
            p.ded(); p.p("}"); p.nl(); p.nl();
            return;
        }
        default: { char[32] b; snprintf(&b[0],32,"; unknown decl(%d)",(int)d.tag); p.p(&b[0]); p.semi(); return; }
    }
}

fn void emit_module(void* f, AirModule* m, AirLower* lr, AirArena* arena) {
    (void)lr; (void)arena;
    if (f == null || m == null) return;
    AirPrinter p;
    p.out = f; p.indent = 0; p.need_sep = false;

    p.p("; AIR 1.0 -- Abstractive Intermediate Representation ");
    p.p("(lambda-mu-mu-tilde classical sequent calculus)"); p.nl();
    p.p("; generated by pfront (Pride) -- stable text format ");
    p.p("-- see docs/specs/AIR.md"); p.nl();
    if (m.name != null) { p.p("; module: "); p.p(m.name); p.nl(); }
    if (m.source_path != null) { p.p("; source: "); p.p(m.source_path); p.nl(); }
    p.nl();

    for (usz i = 0; i < m.decl_count; i++) { p.decl(m.decls[i]); }

    p.nl(); p.p("; end of AIR"); p.nl();
    return;
}
