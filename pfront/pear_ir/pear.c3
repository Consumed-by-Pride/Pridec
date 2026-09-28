// pear.c3 — PEAR: Pride's Engine for Abstractive Representations.
//
// Bootstrap codegen: AirModule -> LLVM IR text (.ll).  This is version 0.1
// and targets a small subset (direct calls, binops, returns, lets, tail
// composition).  SSA conversion for full μα/μ̃/jump/label/case will be
// added incrementally.

module pear;
import air_ir;
import air_types;

// ── Externs ────────────────────────────────────────────────────────────

extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);

// ── Codegen state ─────────────────────────────────────────────────────

struct PearCg {
    AirModule* mod;
    void*      fp;
    usz        tmp;
    char[64]   scratch;     // primary scratch
    char[64]   scratch2;    // secondary scratch (so two names can be live)
    usz        name_n;
    char[64][64] names;     // persistent name cache (stable pointers)
}

// Allocate a persistent %-name from the names[] cache so callers can hold
// two or three names live simultaneously.
fn char* PearCg.fresh(PearCg* cg, char* s)
{
    if (s == null) return (char*)"0";
    usz i = cg.name_n;
    if (i < 64)
    {
        usz j = 0;
        while (j < 62 && s[j] != 0) { cg.names[i][j] = s[j]; j++; }
        cg.names[i][j] = 0;
        cg.name_n = i + 1;
        return &cg.names[i][0];
    }
    return s;
}

// ── Entry point ───────────────────────────────────────────────────────

fn void pear_emit_module(AirModule* mod, char* ll_path)
{
    if (mod == null || ll_path == null) return;
    void* fp = fopen(ll_path, "wb");
    if (fp == null) return;

    PearCg cg;
    cg.mod = mod;
    cg.fp = fp;
    cg.tmp = 0;
    cg.name_n = 0;

    (void)fprintf(fp, "; PEAR -> LLVM IR (bootstrap)\n");
    (void)fprintf(fp, "target triple = \"x86_64-pc-linux-gnu\"\n");
    (void)fprintf(fp, "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n\n");
    (void)fprintf(fp, "declare i64 @write(i32, i8*, i64)\n");
    (void)fprintf(fp, "declare i8* @malloc(i64)\n");
    (void)fprintf(fp, "declare void @free(i8*)\n");
    (void)fprintf(fp, "declare void @exit(i32) noreturn\n\n");

    for (usz i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DEF) { pear_emit_fn(&cg, d); }
    }

    (void)fclose(fp);
}

// ── Type printing ─────────────────────────────────────────────────────

fn void pear_typ(PearCg* cg, AirTyp* t)
{
    if (t == null) { (void)fprintf(cg.fp, "i64"); return; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8:    (void)fprintf(cg.fp, "i8"); return;
        case ATYP_I16: case ATYP_U16:  (void)fprintf(cg.fp, "i16"); return;
        case ATYP_I32: case ATYP_U32:  (void)fprintf(cg.fp, "i32"); return;
        case ATYP_I64: case ATYP_U64:
        case ATYP_I128: case ATYP_U128:
        case ATYP_ISZ: case ATYP_USZ:
        case ATYP_INFER:               (void)fprintf(cg.fp, "i64"); return;
        case ATYP_BOOL:                (void)fprintf(cg.fp, "i1"); return;
        case ATYP_UNIT: case ATYP_BOTTOM: (void)fprintf(cg.fp, "void"); return;
        case ATYP_PTR: case ATYP_REF: case ATYP_REF_MUT:
            (void)fprintf(cg.fp, "i8*"); return;
        default: (void)fprintf(cg.fp, "i64"); return;
    }
}

fn bool pear_is_void(AirTyp* t)
{
    if (t == null) return true;
    return t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM;
}

fn char* PearCg.mktmp(PearCg* cg)
{
    char[64] b;
    (void)snprintf(&b[0], 64, "_t%ld", (long)cg.tmp);
    cg.tmp++;
    return cg.fresh(&b[0]);
}

fn char* PearCg.mktmp_pct(PearCg* cg)
{
    char[64] b;
    (void)snprintf(&b[0], 64, "%%_t%ld", (long)cg.tmp);
    cg.tmp++;
    return cg.fresh(&b[0]);
}

// ── Function emission ────────────────────────────────────────────────

fn void pear_emit_fn(PearCg* cg, AirDecl* d)
{
    if (d == null) return;
    char* nm = d.name;
    if (nm == null) nm = (char*)"_anon";
    cg.tmp = 0;

    bool is_void = pear_is_void(d.ret_ty);

    (void)fprintf(cg.fp, "define ");
    if (is_void) { (void)fprintf(cg.fp, "void"); }
    else         { pear_typ(cg, d.ret_ty); }
    (void)fprintf(cg.fp, " @%s(", nm);
    for (usz i = 0; i < d.param_count; i++)
    {
        AirBinder* p = d.params[i];
        if (i > 0) (void)fprintf(cg.fp, ", ");
        (void)fprintf(cg.fp, "i64 %%%s", (p != null && p.name != null) ? p.name : "_");
    }
    (void)fprintf(cg.fp, ") #0 {\nentry:\n");

    bool term = false;
    if (d.def_body != null) { term = pear_cmd(cg, d.def_body); }
    if (!term)
    {
        if (is_void) { (void)fprintf(cg.fp, "  ret void\n"); }
        else         { (void)fprintf(cg.fp, "  ret i64 0\n"); }
    }
    (void)fprintf(cg.fp, "}\n\n");
}

// ── Producers → "%name" / literal string ─────────────────────────────

fn char* pear_prd(PearCg* cg, AirPrd* p)
{
    if (p == null) return (char*)"0";
    switch (p.tag)
    {
        case APRD_INT:
        {
            (void)snprintf(&cg.scratch[0], 64, "%ld", (long)p.ival);
            return cg.fresh(&cg.scratch[0]);
        }
        case APRD_BOOL:
        {
            return p.bval ? (char*)"1" : (char*)"0";
        }
        case APRD_UNIT: return (char*)"0";
        case APRD_NULL: return (char*)"0";
        case APRD_VAR:
        case APRD_CON:
        {
            if (p.name == null) return (char*)"0";
            // Already %-prefixed (e.g. %ret, %k1 used by the emitter).
            if (p.name[0] == '%') return p.name;
            // Bare variable → emit %name.
            (void)snprintf(&cg.scratch[0], 64, "%%%s", p.name);
            return cg.fresh(&cg.scratch[0]);
        }
        case APRD_BINOP:
        {
            // Evaluate operands FIRST (both names are stable in fresh[]),
            // then emit the instruction using a fresh tmp for the result.
            char* a = pear_prd(cg, p.subs[0]);
            char* b = pear_prd(cg, p.subs[1]);
            char* tn = cg.mktmp_pct();  // persistent %name in fresh[]
            char* opc;
            bool is_i1 = false;
            switch (p.bop)
            {
                case ABIN_ADD: opc = (char*)"add nsw i64"; break;
                case ABIN_SUB: opc = (char*)"sub nsw i64"; break;
                case ABIN_MUL: opc = (char*)"mul nsw i64"; break;
                case ABIN_DIV: opc = (char*)"sdiv i64"; break;
                case ABIN_MOD: opc = (char*)"srem i64"; break;
                case ABIN_AND: opc = (char*)"and i64"; break;
                case ABIN_OR:  opc = (char*)"or i64"; break;
                case ABIN_XOR: opc = (char*)"xor i64"; break;
                case ABIN_SHL: opc = (char*)"shl i64"; break;
                case ABIN_SHR: opc = (char*)"ashr i64"; break;
                case ABIN_LT:  opc = (char*)"icmp slt i64"; is_i1 = true; break;
                case ABIN_GT:  opc = (char*)"icmp sgt i64"; is_i1 = true; break;
                case ABIN_LE:  opc = (char*)"icmp sle i64"; is_i1 = true; break;
                case ABIN_GE:  opc = (char*)"icmp sge i64"; is_i1 = true; break;
                case ABIN_EQ:  opc = (char*)"icmp eq i64";  is_i1 = true; break;
                case ABIN_NEQ: opc = (char*)"icmp ne i64";  is_i1 = true; break;
                default:       opc = (char*)"add nsw i64"; break;
            }
            if (is_i1)
            {
                // Emit icmp into a tmp i1, then zext to i64; return the zext name.
                char[64] in;
                (void)snprintf(&in[0], 64, "_t%ld", (long)cg.tmp);
                cg.tmp++;
                char* in_pct = cg.fresh(&in[0]);  // alloc %name for i1 result
                // Need to write "%in" for the i1 register name.
                char[64] in_pct_buf;
                (void)snprintf(&in_pct_buf[0], 64, "%%%s", &in[0]);
                (void)fprintf(cg.fp, "  %s = %s %s, %s\n", &in_pct_buf[0], opc, a, b);
                char* zn_pct = cg.mktmp_pct();
                (void)fprintf(cg.fp, "  %s = zext i1 %s to i64\n", zn_pct, &in_pct_buf[0]);
                return zn_pct;
            }
            (void)fprintf(cg.fp, "  %s = %s %s, %s\n", tn, opc, a, b);
            return tn;
        }
        case APRD_MU:
        {
            (void)pear_cmd(cg, p.body);
            return (char*)"0";
        }
        default:
        {
            (void)fprintf(cg.fp, "  ; prd tag %d NYI\n", (int)p.tag);
            return (char*)"0";
        }
    }
}

// ── Consumers ────────────────────────────────────────────────────────

fn bool pear_cns(PearCg* cg, char* vname, AirCns* k)
{
    if (k == null) return false;
    switch (k.tag)
    {
        case ACNS_COVAR:
        {
            char* nm = k.name;
            if (nm != null && nm[0] == '%' && nm[1] == 'r')
            {
                (void)fprintf(cg.fp, "  ret i64 %s\n", vname);
                return true;
            }
            (void)fprintf(cg.fp, "  ; cut to %s (val %s) NYI\n", nm != null ? nm : "?", vname);
            return false;
        }
        case ACNS_COMU:
        {
            if (k.bind != null && k.bind[0] != '%')
            {
                (void)fprintf(cg.fp, "  %%%s = %s\n", k.bind, vname);
            }
            return pear_cmd(cg, k.body);
        }
        case ACNS_CALL:
        case ACNS_STACK:
        {
            // Call: vname is the callee name (e.g. "fib" or "one"), walk
            // the STACK chain to collect arguments, then emit an LLVM
            // call and feed the result into the terminal consumer.
            AirPrd*[16] args; usz ac = 0;
            AirCns* cur = k;
            AirCns* ret_k = null;
            // Walk: ACNS_CALL.tail -> ACNS_STACK(arg3, ACNS_STACK(arg2,... -> ret_k))
            // When we see ACNS_CALL first, step into its .tail.
            if (cur.tag == ACNS_CALL) cur = cur.tail;
            while (cur != null)
            {
                if (cur.tag == ACNS_STACK)
                {
                    if (ac < 16) { args[ac] = cur.prd; ac++; }
                    cur = cur.tail;
                }
                else
                {
                    ret_k = cur;
                    break;
                }
            }
            // Emit: %r = call i64 @callee(i64 %a1, i64 %a2, ...)
            char* rn = cg.mktmp();
            (void)fprintf(cg.fp, "  %%%s = call i64 @%s(", rn, vname);
            for (usz i = 0; i < ac; i++)
            {
                if (i > 0) (void)fprintf(cg.fp, ", ");
                char* an = pear_prd(cg, args[i]);
                (void)fprintf(cg.fp, "i64 %s", an);
            }
            (void)fprintf(cg.fp, ")\n");
            // Feed %rn into ret_k.
            char* rn_pct = cg.mktmp_pct();
            return pear_cns(cg, rn_pct, ret_k);
        }
        default:
        {
            (void)fprintf(cg.fp, "  ; cns tag %d NYI (val %s)\n", (int)k.tag, vname);
            return false;
        }
    }
}

// ── Commands ──────────────────────────────────────────────────────────

fn bool pear_cmd(PearCg* cg, AirCmd* c)
{
    if (c == null) return false;
    switch (c.tag)
    {
        case ACMD_CUT:
        {
            char* v = pear_prd(cg, c.prd);
            return pear_cns(cg, v, c.cns);
        }
        case ACMD_SEQ:
        {
            bool t = pear_cmd(cg, c.body);
            if (t) return true;
            return pear_cmd(cg, c.next);
        }
        case ACMD_LET:
        {
            if (c.prd != null)
            {
                char* v = pear_prd(cg, c.prd);
                if (c.binder != null && c.prd.tag != APRD_UNIT)
                {
                    (void)fprintf(cg.fp, "  %%%s = %s\n", c.binder, v);
                }
            }
            return pear_cmd(cg, c.body);
        }
        case ACMD_NOP:
            return false;
        case ACMD_MUTILDE:
        case ACMD_MU:
        {
            return pear_cmd(cg, c.body);
        }
        default:
        {
            (void)fprintf(cg.fp, "  ; cmd tag %d NYI\n", (int)c.tag);
            return false;
        }
    }
}
