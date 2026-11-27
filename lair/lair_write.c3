// ============================================================================
// lair_write.c3 — the .lair text form: LModule -> file (LAIR.md §5).
//
// This is the debuggable middle form, one emitter away from LLVM:
//
//   lair 0.1 Main "arithmetic_main.pie";
//
//   extern declare write(i32, ptr, i64) -> i64;
//
//   def main() -> i64 {
//     entry:
//       %.t0 = cut add(40, %.t1) : i64
//       ret %.t0
//   }
//
// It is round-trippable in principle (that is the point of a text form) but
// the slice's reader is not built yet -- phase 2 feeds lair_lower from AIR,
// never from .lair. Names print exactly as LLVM will see them, so a .lair
// diff and a .ll diff of the same compile tell the same story. Phase 4 adds
// aggregate construction/access and memory instructions; aggregate types print
// their element types, resolved through the module's interned pool.
// ============================================================================
module lair_write;
import air_text;
import air_util;
import lair_ir;
import air_ir;

extern fn int snprintf(char* buf, usz n, char* fmt, ...);
extern fn int fputs(char* s, void* f);
extern fn void free(void* ptr);

fn void w_atom(Sb* s, LAtom a)
{
    switch (a.k)
    {
        case LA_VAR:
            s.put((char*)"%");
            s.put(a.name);
            break;
        case LA_INT:
            s.int_(a.ival);
            break;
        case LA_FLOAT:
            s.put((char*)"float(");
            char[64] b;
            snprintf(&b[0], 64, "%.17g", a.fval);
            s.put(&b[0]);
            s.put((char*)")");
            break;
        case LA_BOOL:
            s.put(a.ival != 0 ? (char*)"true" : (char*)"false");
            break;
        case LA_UNIT:
            s.put((char*)"unit");
            break;
        case LA_SYM:
            s.put((char*)"@");
            s.put(a.name);
            break;
    }
}

fn void w_ty(Sb* s, LModule* lm, LTy t, int atid)
{
    if (!lair_ir::lty_is_agg(t)) { s.put(lair_ir::lty_name(t)); return; }
    LType* ag = lm.tp + atid;
    if (ag.k == LT_TUPLE)
    {
        s.put((char*)"tuple(");
        for (int i = 0; i < ag.n; i++)
        {
            if (i > 0) { s.put((char*)", "); }
            s.put(lair_ir::lty_name(ag.elems[i]));
        }
        s.put((char*)")");
    }
    else if (ag.k == LT_ARRAY)
    {
        s.put((char*)"array[");
        s.put(lair_ir::lty_name(ag.elems[0]));
        s.put((char*)", ");
        s.int_((long)ag.n);
        s.put((char*)"]");
    }
    else // LT_RECORD
    {
        s.put((char*)"record{");
        for (int i = 0; i < ag.n; i++)
        {
            if (i > 0) { s.put((char*)", "); }
            s.put(ag.names[i] != null ? ag.names[i] : (char*)"?");
            s.put((char*)": ");
            s.put(lair_ir::lty_name(ag.elems[i]));
        }
        s.put((char*)"}");
    }
}

fn void w_instr(Sb* s, LModule* lm, LInstr* in)
{
    s.put((char*)"  ");
    if (in.dst != null)
    {
        s.put((char*)"%");
        s.put(in.dst);
        s.put((char*)" = ");
    }
    switch (in.op)
    {
        case LI_BINOP:
            s.put((char*)"cut ");
            s.put(air_text::binop_name((AirBinop)in.bop));
            s.put((char*)"(");
            w_atom(s, in.a);
            s.put((char*)", ");
            w_atom(s, in.b);
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_UNOP:
            s.put((char*)"cut ");
            s.put(air_text::unop_name((AirUnop)in.uop));
            s.put((char*)"(");
            w_atom(s, in.a);
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_COERCE:
            s.put((char*)"cut coerce(");
            w_atom(s, in.a);
            s.put((char*)", ");
            w_ty(s, lm, in.ty, in.atid);
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_CALL:
            s.put((char*)"cut call ");
            s.put(in.callee);
            s.put((char*)"(");
            for (int i = 0; i < in.argc; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                w_atom(s, in.args[i]);
            }
            if (in.va) { if (in.argc > 0) { s.put((char*)", "); } s.put((char*)"..."); }
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        // ── aggregates (phase 4) ──────────────────────────────────────────
        case LI_TUPLE:
            s.put((char*)"cut tuple(");
            for (int i = 0; i < in.argc; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                w_atom(s, in.args[i]);
            }
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_ARRAY:
            s.put((char*)"cut array(");
            for (int i = 0; i < in.argc; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                w_atom(s, in.args[i]);
            }
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_RECORD:
            s.put((char*)"cut record(");
            for (int i = 0; i < in.argc; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                w_atom(s, in.args[i]);
            }
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_EXTRACT:
            s.put((char*)"cut extract(");
            w_atom(s, in.a);
            s.put((char*)", ");
            s.int_(in.ival);
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        // ── memory (phase 4) ──────────────────────────────────────────────
        case LI_ALLOCA:
            s.put((char*)"alloca ");
            w_ty(s, lm, in.from, -1);
            break;
        case LI_LOAD:
            s.put((char*)"load ");
            w_atom(s, in.a);
            s.put((char*)") : ");
            w_ty(s, lm, in.ty, in.atid);
            break;
        case LI_STORE:
            s.put((char*)"store ");
            w_atom(s, in.a);
            s.put((char*)", ");
            w_atom(s, in.b);
            s.put((char*)") : unit");
            break;
        case LI_GEP:
            s.put((char*)"gep ");
            w_atom(s, in.a);
            s.put((char*)", ");
            w_atom(s, in.b);
            s.put((char*)") : ptr");
            break;
    }
    s.put((char*)"\n");
}

fn void w_term(Sb* s, LModule* lm, LTerm* t)
{
    s.put((char*)"  ");
    switch (t.k)
    {
        case LTM_RET:
            s.put((char*)"ret ");
            w_atom(s, t.a);
            break;
        case LTM_JUMP:
            s.put((char*)"jump ");
            s.put((char*)"%");
            s.put(t.target);
            if (t.argc > 0)
            {
                s.put((char*)"(");
                for (int i = 0; i < t.argc; i++)
                {
                    if (i > 0) { s.put((char*)", "); }
                    w_atom(s, t.args[i]);
                }
                s.put((char*)")");
            }
            break;
        case LTM_BR:
            s.put((char*)"br ");
            w_atom(s, t.a);
            s.put((char*)", %");
            s.put(t.t1);
            s.put((char*)", %");
            s.put(t.t2);
            break;
        case LTM_SWITCH:
            s.put((char*)"switch ");
            w_ty(s, lm, t.a.ty, t.a.atid);
            s.put((char*)" ");
            w_atom(s, t.a);
            s.put((char*)" [");
            for (int i = 0; i < t.ncase; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                s.int_(t.vals[i]);
                s.put((char*)" -> %");
                s.put(t.tgts[i]);
            }
            s.put((char*)"]");
            if (t.def != null) { s.put((char*)" default %"); s.put(t.def); }
            else { s.put((char*)" default unreachable"); }
            break;
        case LTM_TRAP:
            s.put((char*)"trap");
            break;
        case LTM_UNREACH:
            s.put((char*)"unreachable");
            break;
    }
    s.put((char*)"\n");
}

fn void w_func(Sb* s, LModule* lm, LFunc* f)
{
    s.put((char*)"def ");
    s.put(f.name);
    s.put((char*)"(");
    for (int i = 0; i < f.np; i++)
    {
        if (i > 0) { s.put((char*)", "); }
        s.put(f.params[i].name);
        s.put((char*)" : ");
        w_ty(s, lm, f.params[i].ty, f.params[i].atid);
    }
    s.put((char*)") -> ");
    w_ty(s, lm, f.ret, f.retid);
    s.put((char*)" {\n");
    for (int b = 0; b < f.nb; b++)
    {
        LBlock* blk = f.blocks[b];
        s.put(blk.name);
        s.put((char*)":\n");
        if (blk.np > 0)
        {
            s.put((char*)"  params ");
            for (int i = 0; i < blk.np; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                s.put((char*)"%");
                s.put(blk.params[i].name);
                s.put((char*)" : ");
                w_ty(s, lm, blk.params[i].ty, blk.params[i].atid);
            }
            s.put((char*)"\n");
        }
        for (int k = 0; k < blk.ni; k++) { w_instr(s, lm, blk.instrs + k); }
        w_term(s, lm, &blk.term);
    }
    s.put((char*)"}\n\n");
}

// Writes the .lair text to `out` (a FILE*). Returns false only on I/O failure.
fn bool write_lair(LModule* lm, void* out)
{
    Sb s;
    s.init();
    s.put((char*)"lair 0.1 ");
    s.put(lm.name != null ? lm.name : (char*)"M");
    if (lm.source != null)
    {
        s.put((char*)" \"");
        s.put(lm.source);
        s.put((char*)"\"");
    }
    s.put((char*)";\n\n");
    for (int i = 0; i < lm.next_; i++)
    {
        LExtern* e = lm.externs[i];
        s.put((char*)"extern declare ");
        s.put(e.name);
        s.put((char*)"(");
        for (int k = 0; k < e.np; k++)
        {
            if (k > 0) { s.put((char*)", "); }
            w_ty(&s, lm, e.params[k], e.p_atid[k]);
        }
        if (e.va) { if (e.np > 0) { s.put((char*)", "); } s.put((char*)"..."); }
        s.put((char*)") -> ");
        w_ty(&s, lm, e.ret, e.retid);
        s.put((char*)";\n");
    }
    if (lm.next_ > 0) { s.put((char*)"\n"); }
    for (int i = 0; i < lm.nf; i++) { w_func(&s, lm, lm.funcs[i]); }
    char* txt = s.take();
    bool ok = fputs(txt, out) >= 0;
    free(txt);
    return ok;
}
