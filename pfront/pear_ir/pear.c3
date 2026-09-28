// pear.c3 — PEAR: Pride's Engine for Abstractive Representations.
//
// v0.2 CFG/SSA emitter. AIR is in near-ANF form (lets + cuts + if/case), so
// lowering to SSA basic blocks is straightforward. Emits clean LLVM IR text.
//
// Supported:
//   • def/declare, typed params, void returns
//   • APRD_INT/BOOL/UNIT/VAR/CON/BINOP/MU
//   • ACNS_COVAR (→ ret), ACNS_COMU (→ let + continue), ACNS_CALL/STACK
//   • ACMD_CUT/SEQ/LET/NOP/MU/MUTILDE/RET/TRAP/UB/IF/BLOCK
//   • Comparisons produce i1 natively for br, zext to i64 for value use
//   • Direct @fn calls; indirect %fn calls
//   • Diamond CFG for ACMD_IF (both arms cut to ret → no φ needed)

module pear;
import air_ir;
import air_types;

extern fn int   fprintf(void* f, char* fmt, ...);
extern fn int   snprintf(char* buf, ulong n, char* fmt, ...);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);

const uint NAMELEN = 64;
const uint NAMES_N = 256;
const uint DEFS_N  = 256;

struct PearCg {
    AirModule* mod;
    void*      fp;
    uint       tmp;
    uint       blk;
    uint       name_n;
    char[NAMELEN][NAMES_N] names;
    bool       blk_open;
    bool       fn_is_void;
    uint       defn_n;
    char[NAMELEN][DEFS_N] defbuf;
    // Simple copy-prop alias map: aliases[i] is the target name for names[i].
    // When we skip emitting `%x = add i64 0, %y`, we record x→y so subsequent
    // reads of %x resolve to %y.
    char*[NAMES_N] aliases;
}

fn bool seq_eq(char* a, char* b)
{
    if (a == null || b == null) return a == b;
    uint i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) return false; i++; }
    return a[i] == 0 && b[i] == 0;
}

fn char* PearCg.intern(PearCg* cg, char* s)
{
    if (s == null) return (char*)"0";
    if (s[0] == '0' && s[1] == 0) return (char*)"0";
    if (s[0] == '1' && s[1] == 0) return (char*)"1";
    uint i = cg.name_n;
    if (i < NAMES_N)
    {
        uint j = 0;
        while (j < NAMELEN - 1 && s[j] != 0) { cg.names[i][j] = s[j]; j++; }
        cg.names[i][j] = 0;
        cg.name_n = i + 1;
        return &cg.names[i][0];
    }
    return s;
}

fn char* PearCg.mktmp(PearCg* cg)
{
    char[NAMELEN] b;
    (void)snprintf(&b[0], NAMELEN, "%%_t%u", cg.tmp);
    cg.tmp++;
    return cg.intern(&b[0]);
}

// Resolve an SSA name through the alias table (returns the ultimate name).
fn char* PearCg.resolve(PearCg* cg, char* nm)
{
    if (nm == null) return (char*)"0";
    if (nm[0] != '%') return nm;
    // Look up nm in names[]; if found and alias exists, follow chain.
    for (uint iter = 0; iter < 8; iter++)
    {
        bool found = false;
        for (uint i = 0; i < cg.name_n; i++)
        {
            if (seq_eq(&cg.names[i][0], nm))
            {
                if (cg.aliases[i] != null) { nm = cg.aliases[i]; found = true; }
                break;
            }
        }
        if (!found) break;
    }
    return nm;
}

fn char* PearCg.mklbl(PearCg* cg, char* pfx)
{
    char[NAMELEN] b;
    (void)snprintf(&b[0], NAMELEN, "%s.%u", pfx, cg.blk);
    cg.blk++;
    return cg.intern(&b[0]);
}

fn bool is_ret_covar(char* nm)
{
    if (nm == null) return false;
    if (nm[0] != '%') return false;
    if (nm[1] != 'r' || nm[2] != 'e' || nm[3] != 't') return false;
    char c = nm[4];
    if (c == 0) return true;
    return c == '_';
}

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

fn bool is_cmp_binop(AirBinop op)
{
    switch (op)
    {
        case ABIN_LT: case ABIN_GT: case ABIN_LE:
        case ABIN_GE: case ABIN_EQ: case ABIN_NEQ: return true;
        default: return false;
    }
}

fn char* icode(AirBinop op)
{
    switch (op)
    {
        case ABIN_ADD: return (char*)"add nsw i64";
        case ABIN_SUB: return (char*)"sub nsw i64";
        case ABIN_MUL: return (char*)"mul nsw i64";
        case ABIN_DIV: return (char*)"sdiv i64";
        case ABIN_MOD: return (char*)"srem i64";
        case ABIN_AND: return (char*)"and i64";
        case ABIN_OR:  return (char*)"or i64";
        case ABIN_XOR: return (char*)"xor i64";
        case ABIN_SHL: return (char*)"shl i64";
        case ABIN_SHR: return (char*)"ashr i64";
        case ABIN_LT:  return (char*)"icmp slt i64";
        case ABIN_GT:  return (char*)"icmp sgt i64";
        case ABIN_LE:  return (char*)"icmp sle i64";
        case ABIN_GE:  return (char*)"icmp sge i64";
        case ABIN_EQ:  return (char*)"icmp eq i64";
        case ABIN_NEQ: return (char*)"icmp ne i64";
        default:       return (char*)"add nsw i64";
    }
}

fn void pear_emit_ret(PearCg* cg, char* v)
{
    if (!cg.blk_open) return;
    if (v != null)      { (void)fprintf(cg.fp, "  ret i64 %s\n", v); }
    else if (cg.fn_is_void) { (void)fprintf(cg.fp, "  ret void\n"); }
    else               { (void)fprintf(cg.fp, "  ret i64 0\n"); }
    cg.blk_open = false;
}

fn void pear_open(PearCg* cg, char* lbl)
{
    if (cg.blk_open) pear_emit_ret(cg, null);
    (void)fprintf(cg.fp, "%s:\n", lbl);
    cg.blk_open = true;
}

fn void pear_br(PearCg* cg, char* tgt)
{
    if (!cg.blk_open) return;
    (void)fprintf(cg.fp, "  br label %%%s\n", tgt);
    cg.blk_open = false;
}

fn void pear_condbr(PearCg* cg, char* cv, char* t, char* e)
{
    if (!cg.blk_open) return;
    (void)fprintf(cg.fp, "  br i1 %s, label %%%s, label %%%s\n", cv, t, e);
    cg.blk_open = false;
}

fn void pear_trap(PearCg* cg)
{
    if (!cg.blk_open) return;
    (void)fprintf(cg.fp, "  call void @llvm.trap()\n  unreachable\n");
    cg.blk_open = false;
}

fn void PearCg.add_def(PearCg* cg, char* nm)
{
    if (nm == null) return;
    if (cg.defn_n >= DEFS_N) return;
    uint k = cg.defn_n;
    uint j = 0;
    while (j < NAMELEN - 1 && nm[j] != 0) { cg.defbuf[k][j] = nm[j]; j++; }
    cg.defbuf[k][j] = 0;
    cg.defn_n = k + 1;
}

fn bool PearCg.is_def(PearCg* cg, char* nm)
{
    if (nm == null) return false;
    char* s = nm;
    if (s[0] == '%') s = &s[1];
    for (uint i = 0; i < cg.defn_n; i++)
    {
        if (seq_eq(&cg.defbuf[i][0], s)) return true;
    }
    return false;
}

fn char* pear_prd_i64(PearCg* cg, AirPrd* p)
{
    if (p == null) return (char*)"0";
    switch (p.tag)
    {
        case APRD_INT:
        {
            char[NAMELEN] b;
            (void)snprintf(&b[0], NAMELEN, "%ld", (long)p.ival);
            return cg.intern(&b[0]);
        }
        case APRD_BOOL:
            return p.bval ? (char*)"1" : (char*)"0";
        case APRD_UNIT: case APRD_NULL: return (char*)"0";
        case APRD_VAR: case APRD_CON:
        {
            if (p.name == null) return (char*)"0";
            if (p.name[0] == '%') return cg.resolve(p.name);
            char[NAMELEN] b;
            (void)snprintf(&b[0], NAMELEN, "%%%s", p.name);
            return cg.resolve(cg.intern(&b[0]));
        }
        case APRD_BINOP:
        {
            bool cmp = is_cmp_binop(p.bop);
            char* a = pear_prd_i64(cg, p.subs[0]);
            char* bb = pear_prd_i64(cg, p.subs[1]);
            char* r = cg.mktmp();
            (void)fprintf(cg.fp, "  %s = %s %s, %s\n", r, icode(p.bop), a, bb);
            if (cmp)
            {
                char* z = cg.mktmp();
                (void)fprintf(cg.fp, "  %s = zext i1 %s to i64\n", z, r);
                return z;
            }
            return r;
        }
        case APRD_MU:
        {
            (void)pear_cmd(cg, p.body);
            return (char*)"0";
        }
        case APRD_COERCE:
        {
            // Type ascription: emit the inner value, ignore the type cast for now.
            if (p.sub_count > 0 && p.subs[0] != null) return pear_prd_i64(cg, p.subs[0]);
            return (char*)"0";
        }
        default:
        {
            (void)fprintf(cg.fp, "  ; prd tag %d NYI\n", (int)p.tag);
            return (char*)"0";
        }
    }
}

fn char* pear_prd_i1(PearCg* cg, AirPrd* p)
{
    if (p == null) return (char*)"0";
    // Peel COERCE wrappers (type ascription).
    AirPrd* q = p;
    while (q.tag == APRD_COERCE && q.sub_count > 0 && q.subs[0] != null) q = q.subs[0];
    if (q.tag == APRD_BINOP && is_cmp_binop(q.bop))
    {
        char* a = pear_prd_i64(cg, q.subs[0]);
        char* bb = pear_prd_i64(cg, q.subs[1]);
        char* r = cg.mktmp();
        (void)fprintf(cg.fp, "  %s = %s %s, %s\n", r, icode(q.bop), a, bb);
        return r;
    }
    if (q.tag == APRD_BOOL) return q.bval ? (char*)"1" : (char*)"0";
    // If the producer is a variable that was just assigned an i1 value we
    // can't track yet; fall through to i64 + icmp.
    char* v = pear_prd_i64(cg, p);
    char* r = cg.mktmp();
    (void)fprintf(cg.fp, "  %s = icmp ne i64 %s, 0\n", r, v);
    return r;
}

fn bool pear_cns(PearCg* cg, char* v, AirCns* k)
{
    if (k == null) { pear_emit_ret(cg, v); return true; }
    switch (k.tag)
    {
        case ACNS_COVAR:
        {
            if (is_ret_covar(k.name)) { pear_emit_ret(cg, v); return true; }
            // The "·" (middle-dot) hole covariable means "continue with the
            // next command in the SEQ chain". Fall through: do NOT terminate;
            // return false so the enclosing SEQ/let proceeds to next.
            if (k.name != null && k.name[0] == (char)(0xc2) && k.name[1] == (char)(0xb7))
            {
                return false;
            }
            // Any other covar is treated as a jump target. For bootstrap, ret.
            pear_emit_ret(cg, v);
            return true;
        }
        case ACNS_COMU:
        {
            bool wild = (k.bind == null)
                     || (k.bind[0] == '_' && k.bind[1] == 0)
                     || (v != null && seq_eq(v, (char*)"0"));   // unit/hole binder
            if (!wild && v != null)
            {
                char[NAMELEN] b;
                (void)snprintf(&b[0], NAMELEN, "%%%s", k.bind);
                char* bn = cg.intern(&b[0]);
                char* rv = cg.resolve(v);
                if (!seq_eq(rv, bn))
                {
                    if (rv[0] == '%')
                    {
                        for (uint i = 0; i < cg.name_n; i++)
                        {
                            if (seq_eq(&cg.names[i][0], bn)) { cg.aliases[i] = rv; break; }
                        }
                    }
                    else
                    {
                        (void)fprintf(cg.fp, "  %s = add i64 0, %s\n", bn, rv);
                    }
                }
            }
            return pear_cmd(cg, k.body);
        }
        case ACNS_CALL: case ACNS_STACK:
        {
            AirPrd*[16] args; uint ac = 0;
            AirCns* cur = k;
            AirCns* ret_k = null;
            if (cur.tag == ACNS_CALL) cur = cur.tail;
            while (cur != null)
            {
                if (cur.tag == ACNS_STACK)
                {
                    if (ac < 16) { args[ac] = cur.prd; ac++; }
                    cur = cur.tail;
                }
                else if (cur.tag == ACNS_ASCRIBE)
                {
                    cur = cur.tail;
                }
                else { ret_k = cur; break; }
            }
            char* callee = v;
            bool direct = false;
            if (callee != null && callee[0] == '%' && cg.is_def(&callee[1]))
            {
                callee = &callee[1];
                direct = true;
            }
            char*[16] argn;
            for (uint i = 0; i < ac; i++)
            {
                uint idx = ac - 1 - i;
                argn[idx] = pear_prd_i64(cg, args[idx]);
            }
            char* rn = cg.mktmp();
            if (direct) { (void)fprintf(cg.fp, "  %s = call i64 @%s(", rn, callee); }
            else        { (void)fprintf(cg.fp, "  %s = call i64 %s(", rn, callee != null ? callee : "0"); }
            for (uint i = 0; i < ac; i++)
            {
                if (i > 0) { (void)fprintf(cg.fp, ", "); }
                (void)fprintf(cg.fp, "i64 %s", argn[i] != null ? argn[i] : "0");
            }
            (void)fprintf(cg.fp, ")\n");
            return pear_cns(cg, rn, ret_k);
        }
        default:
        {
            (void)fprintf(cg.fp, "  ; cns tag %d NYI\n", (int)k.tag);
            pear_trap(cg);
            return true;
        }
    }
}

fn bool pear_cmd(PearCg* cg, AirCmd* c)
{
    if (c == null) return false;
    switch (c.tag)
    {
        case ACMD_CUT:
        {
            if (c.prd != null && c.prd.tag == APRD_MU)
            {
                return pear_cmd(cg, c.prd.body);
            }
            char* v = pear_prd_i64(cg, c.prd);
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
            if (c.prd != null && c.prd.tag != APRD_UNIT)
            {
                bool wild = (c.binder == null) || (c.binder[0] == '_' && c.binder[1] == 0);
                char* v = pear_prd_i64(cg, c.prd);
                if (!wild && v != null)
                {
                    char[NAMELEN] b;
                    (void)snprintf(&b[0], NAMELEN, "%%%s", c.binder);
                    char* bn = cg.intern(&b[0]);
                    char* rv = cg.resolve(v);
                    if (!seq_eq(rv, bn))
                    {
                        if (rv[0] == '%')
                        {
                            for (uint i = 0; i < cg.name_n; i++)
                            {
                                if (seq_eq(&cg.names[i][0], bn)) { cg.aliases[i] = rv; break; }
                            }
                        }
                        else
                        {
                            (void)fprintf(cg.fp, "  %s = add i64 0, %s\n", bn, rv);
                        }
                    }
                }
            }
            return pear_cmd(cg, c.body);
        }
        case ACMD_NOP: return false;
        case ACMD_MU: case ACMD_MUTILDE: case ACMD_BLOCK:
            return pear_cmd(cg, c.body);
        case ACMD_IF:
        {
            char* cv = pear_prd_i1(cg, c.prd);
            char* tl = cg.mklbl("if.then");
            char* el = cg.mklbl("if.else");
            pear_condbr(cg, cv, tl, el);
            pear_open(cg, tl);
            bool tt = pear_cmd(cg, c.then_c);
            if (!tt && cg.blk_open) { pear_emit_ret(cg, null); }
            else if (cg.blk_open) { cg.blk_open = false; }
            pear_open(cg, el);
            bool et = pear_cmd(cg, c.else_c);
            if (!et && cg.blk_open) { pear_emit_ret(cg, null); }
            else if (cg.blk_open) { cg.blk_open = false; }
            if (!tt || !et)
            {
                char* cont = cg.mklbl("if.cont");
                pear_open(cg, cont);
            }
            return false;
        }
        case ACMD_RET:
        {
            if (c.prd != null) { char* v = pear_prd_i64(cg, c.prd); pear_emit_ret(cg, v); }
            else { pear_emit_ret(cg, null); }
            return true;
        }
        case ACMD_TRAP: pear_trap(cg); return true;
        case ACMD_UB:
            if (cg.blk_open) { (void)fprintf(cg.fp, "  unreachable\n"); cg.blk_open = false; }
            return true;
        default:
        {
            (void)fprintf(cg.fp, "  ; cmd tag %d NYI (then_c=%p else_c=%p body=%p next=%p)\n",
                (int)c.tag, (void*)c.then_c, (void*)c.else_c, (void*)c.body, (void*)c.next);
            return false;
        }
    }
}

fn void pear_emit_fn(PearCg* cg, AirDecl* d)
{
    if (d == null) return;
    char* nm = d.name;
    if (nm == null) nm = (char*)"_anon";
    cg.tmp = 0; cg.blk = 0; cg.name_n = 0;
    for (uint i = 0; i < NAMES_N; i++) cg.aliases[i] = null;
    cg.fn_is_void = pear_is_void(d.ret_ty);

    (void)fprintf(cg.fp, "define ");
    if (cg.fn_is_void) { (void)fprintf(cg.fp, "void"); }
    else { pear_typ(cg, d.ret_ty); }
    (void)fprintf(cg.fp, " @%s(", nm);
    for (uint i = 0; i < d.param_count; i++)
    {
        AirBinder* p = d.params[i];
        if (i > 0) { (void)fprintf(cg.fp, ", "); }
        char* pnm = (p != null && p.name != null) ? p.name : "_";
        AirTyp* pt = (p != null) ? p.ty : null;
        if (pt != null && !pear_is_void(pt)) { pear_typ(cg, pt); }
        else { (void)fprintf(cg.fp, "i64"); }
        (void)fprintf(cg.fp, " %%%s", pnm);
    }
    (void)fprintf(cg.fp, ") #0 {\n");
    cg.blk_open = false;
    pear_open(cg, (char*)"entry");
    bool term = false;
    if (d.def_body != null) term = pear_cmd(cg, d.def_body);
    if (!term && cg.blk_open)
    {
        if (cg.fn_is_void) { (void)fprintf(cg.fp, "  ret void\n"); }
        else { (void)fprintf(cg.fp, "  ret i64 0\n"); }
        cg.blk_open = false;
    }
    else if (cg.blk_open) { cg.blk_open = false; }
    (void)fprintf(cg.fp, "}\n\n");
}

fn void pear_emit_module(AirModule* mod, char* ll_path)
{
    if (mod == null || ll_path == null) return;
    void* fp = fopen(ll_path, "wb");
    if (fp == null) return;

    PearCg cg;
    cg.mod = mod; cg.fp = fp;
    cg.tmp = 0; cg.blk = 0; cg.name_n = 0;
    cg.blk_open = false; cg.fn_is_void = false; cg.defn_n = 0;

    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DEF && d.name != null) cg.add_def(d.name);
    }

    (void)fprintf(fp, "; PEAR v0.2 -> LLVM IR (CFG/SSA)\n");
    (void)fprintf(fp, "target triple = \"x86_64-pc-linux-gnu\"\n");
    (void)fprintf(fp, "target datalayout = \"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n\n");
    (void)fprintf(fp, "declare void @llvm.trap() noreturn nounwind\n");
    (void)fprintf(fp, "declare i64 @write(i32, i8*, i64)\n");
    (void)fprintf(fp, "declare i8* @malloc(i64)\n");
    (void)fprintf(fp, "declare void @free(i8*)\n");
    (void)fprintf(fp, "declare void @exit(i32) noreturn\n\n");

    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DECLARE)
        {
            (void)fprintf(fp, "declare ");
            if (pear_is_void(d.ret_ty)) { (void)fprintf(fp, "void"); }
            else { pear_typ(&cg, d.ret_ty); }
            (void)fprintf(fp, "@%s(", d.name != null ? d.name : "_ext");
            for (uint j = 0; j < d.param_count; j++)
            {
                if (j > 0) { (void)fprintf(fp, ", "); }
                AirBinder* p = d.params[j];
                if (p != null && p.ty != null && !pear_is_void(p.ty)) { pear_typ(&cg, p.ty); }
                else { (void)fprintf(fp, "i64"); }
            }
            (void)fprintf(fp, ")\n");
        }
    }
    (void)fprintf(fp, "\n");

    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DEF) pear_emit_fn(&cg, d);
    }

    (void)fprintf(fp, "attributes #0 = { nounwind ssp uwtable \"frame-pointer\"=\"all\" }\n");
    (void)fclose(fp);
}
