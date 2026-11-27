// ============================================================================
// lair_ll.c3 — LModule -> LLVM textual IR (.ll), LAIR.md §5.
//
// The spelling follows pfront/pear_ir/air_ll.c3 on purpose: two consumers of
// the same AIR that print a given operator differently are both suspect, so
// every mapping below is the reference printer's, transplanted onto LAIR's
// closed opcode set (air_ll's producer switch collapses to LI_BINOP /
// LI_UNOP / LI_COERCE / LI_CALL because N1 already made the operands atoms).
//
// The only structurally new thing versus air_ll is the phi: block parameters
// are phis, filled from jump edge arguments (`jump %ret(x)` -> `%x = phi T
// [ x, pred ]`). The slice reifies no parameterized blocks yet (N3 keeps
// `ret` for every exit), so the phi path is exercised by the verifier's
// L1/L5 and sits ready for phase 2's labels.
//
// `trap` is a real instruction, not a label: `call void @llvm.trap()` +
// `unreachable`, which matches how pear2c's M1Gen lowers ACMD_TRAP.
// ============================================================================
module lair_ll;
import air_ir;
import air_text;
import air_util;
import lair_ir;

extern fn int snprintf(char* buf, usz n, char* fmt, ...);
extern fn int fputs(char* s, void* f);
extern fn void free(void* ptr);

// x86-64 SysV, the same layout/triple pear2c emits for this target.
fn char* ll_datalayout()
{
    return (char*)"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
}
fn char* ll_triple() { return (char*)"x86_64-unknown-linux-gnu"; }

fn char* ll_lty(LTy t)
{
    switch (t)
    {
        case LT_BOOL: return (char*)"i1";
        case LT_I8: return (char*)"i8";
        case LT_I16: return (char*)"i16";
        case LT_I32: return (char*)"i32";
        case LT_I64: return (char*)"i64";
        case LT_U8: return (char*)"i8";
        case LT_U16: return (char*)"i16";
        case LT_U32: return (char*)"i32";
        case LT_U64: return (char*)"i64";
        case LT_CHAR: return (char*)"i32";
        case LT_F32: return (char*)"float";
        case LT_F64: return (char*)"double";
        case LT_UNIT: return (char*)"void";
        case LT_PTR: return (char*)"ptr";
        default: return (char*)"i64";
    }
}

fn void ll_atom(Sb* s, LAtom a)
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
        case LA_BOOL:
            s.put(a.ival != 0 ? (char*)"true" : (char*)"false");
            break;
        case LA_FLOAT:
        {
            char[64] b;
            if (a.ty == LT_F32) { (void)snprintf(&b[0], 64, "%g", a.fval); }
            else { (void)snprintf(&b[0], 64, "%.17g", a.fval); }
            s.put(&b[0]);
            break;
        }
        case LA_UNIT:
            s.put((char*)"zeroinitializer");
            break;
        case LA_SYM:
            s.put((char*)"@");
            s.put(a.name);
            break;
    }
}

// typed operand: `i64 %x` / `double 4.5`
fn void ll_typed(Sb* s, LAtom a)
{
    if (a.k == LA_SYM)
    {
        s.put((char*)"ptr ");                        // function symbol as an argument: ptr @sym
        ll_atom(s, a);
        return;
    }
    s.put(ll_lty(a.ty));
    s.put((char*)" ");
    ll_atom(s, a);
}

fn void ll_binop(Sb* s, LInstr* in)
{
    LTy t = in.a.ty;                                 // operand type == result type (cmp -> i1)
    bool flt = lair_ir::lty_is_float(t);
    bool sgn = lair_ir::lty_is_signed(t) || t == LT_BOOL;
    char* op = null;
    bool cmp = false;
    switch ((AirBinop)in.bop)
    {
        case ABIN_ADD: op = flt ? (char*)"fadd" : (char*)"add"; break;
        case ABIN_SUB: op = flt ? (char*)"fsub" : (char*)"sub"; break;
        case ABIN_MUL: op = flt ? (char*)"fmul" : (char*)"mul"; break;
        case ABIN_DIV: op = flt ? (char*)"fdiv" : (sgn ? (char*)"sdiv" : (char*)"udiv"); break;
        case ABIN_MOD: op = flt ? (char*)"frem" : (sgn ? (char*)"srem" : (char*)"urem"); break;
        case ABIN_AND: op = (char*)"and"; break;
        case ABIN_OR: op = (char*)"or"; break;
        case ABIN_XOR: op = (char*)"xor"; break;
        case ABIN_SHL: op = (char*)"shl"; break;
        case ABIN_SHR: op = sgn ? (char*)"ashr" : (char*)"lshr"; break;
        case ABIN_LAND: op = (char*)"and"; break;
        case ABIN_LOR: op = (char*)"or"; break;
        case ABIN_EQ: op = (char*)"eq"; cmp = true; break;
        case ABIN_NEQ: op = (char*)"ne"; cmp = true; break;
        case ABIN_LT: op = flt ? (char*)"olt" : (sgn ? (char*)"slt" : (char*)"ult"); cmp = true; break;
        case ABIN_GT: op = flt ? (char*)"ogt" : (sgn ? (char*)"sgt" : (char*)"ugt"); cmp = true; break;
        case ABIN_LE: op = flt ? (char*)"ole" : (sgn ? (char*)"sle" : (char*)"ule"); cmp = true; break;
        case ABIN_GE: op = flt ? (char*)"oge" : (char*)"uge"; cmp = true; break;
        default: op = (char*)"add"; break;
    }
    // fresh result, then either the compare form or the operator form
    s.put((char*)"%");
    s.put(in.dst);
    s.put((char*)" = ");
    if (cmp)
    {
        s.put(flt ? (char*)"fcmp " : (char*)"icmp ");
        s.put(op);                                  // eq / ne / slt / ogt / ...
        s.put((char*)" ");
        s.put(ll_lty(t));
        s.put((char*)" ");
        ll_atom(s, in.a);
        s.put((char*)", ");
        ll_atom(s, in.b);
        return;
    }
    s.put(op);
    s.put((char*)" ");
    s.put(ll_lty(t));
    s.put((char*)" ");
    ll_atom(s, in.a);
    s.put((char*)", ");
    ll_atom(s, in.b);
}

fn void ll_instr(Sb* s, LInstr* in)
{
    s.put((char*)"  ");
    switch (in.op)
    {
        case LI_BINOP:
            ll_binop(s, in);
            break;
        case LI_UNOP:
        {
            LTy t = in.a.ty;
            s.put((char*)"%");
            s.put(in.dst);
            s.put((char*)" = ");
            switch ((AirUnop)in.uop)
            {
                case AUN_NEG:
                    if (lair_ir::lty_is_float(t))
                    {
                        s.put((char*)"fneg ");
                        s.put(ll_lty(t));
                        s.put((char*)" ");
                        ll_atom(s, in.a);
                    }
                    else
                    {
                        s.put((char*)"sub ");
                        s.put(ll_lty(t));
                        s.put((char*)" 0, ");
                        ll_atom(s, in.a);
                    }
                    break;
                case AUN_NOT:
                    s.put((char*)"xor ");
                    s.put(ll_lty(t));
                    s.put((char*)" ");
                    ll_atom(s, in.a);
                    s.put((char*)", true");
                    break;
                case AUN_BITNOT:
                    s.put((char*)"xor ");
                    s.put(ll_lty(t));
                    s.put((char*)" ");
                    ll_atom(s, in.a);
                    s.put((char*)", -1");
                    break;
                default:
                    s.put((char*)"add ");
                    s.put(ll_lty(t));
                    s.put((char*)" ");
                    ll_atom(s, in.a);
                    s.put((char*)", 0");
                    break;
            }
            break;
        }
        case LI_COERCE:
        {
            LTy f = in.from;
            LTy t = in.ty;
            s.put((char*)"%");
            s.put(in.dst);
            s.put((char*)" = ");
            bool fi = lair_ir::lty_is_int(f) || f == LT_BOOL;
            bool ti = lair_ir::lty_is_int(t) || t == LT_BOOL;
            if (fi && ti)
            {
                int fb = lair_ir::lty_bits(f);
                int tb = lair_ir::lty_bits(t);
                if (fb > tb) { s.put((char*)"trunc "); }
                else if (fb < tb) { s.put(lair_ir::lty_is_signed(f) ? (char*)"sext " : (char*)"zext "); }
                else { s.put((char*)"bitcast "); }     // same width, different signedness: a no-op
                s.put(ll_lty(f));
                s.put((char*)" ");
                ll_atom(s, in.a);
                s.put((char*)" to ");
                s.put(ll_lty(t));
            }
            else if (fi && lair_ir::lty_is_float(t))
            {
                s.put(lair_ir::lty_is_signed(f) ? (char*)"sitofp " : (char*)"uitofp ");
                s.put(ll_lty(f));
                s.put((char*)" ");
                ll_atom(s, in.a);
                s.put((char*)" to ");
                s.put(ll_lty(t));
            }
            else if (lair_ir::lty_is_float(f) && ti)
            {
                s.put(lair_ir::lty_is_signed(t) ? (char*)"fptosi " : (char*)"fptoui ");
                s.put(ll_lty(f));
                s.put((char*)" ");
                ll_atom(s, in.a);
                s.put((char*)" to ");
                s.put(ll_lty(t));
            }
            else if (lair_ir::lty_is_float(f) && lair_ir::lty_is_float(t))
            {
                s.put(lair_ir::lty_bits(f) < lair_ir::lty_bits(t) ? (char*)"fpext " : (char*)"fptrunc ");
                s.put(ll_lty(f));
                s.put((char*)" ");
                ll_atom(s, in.a);
                s.put((char*)" to ");
                s.put(ll_lty(t));
            }
            else
            {
                s.put((char*)"bitcast ");
                s.put(ll_lty(f));
                s.put((char*)" ");
                ll_atom(s, in.a);
                s.put((char*)" to ");
                s.put(ll_lty(t));
            }
            break;
        }
        case LI_CALL:
        {
            if (in.ty != LT_UNIT && in.dst != null)
            {
                s.put((char*)"%");
                s.put(in.dst);
                s.put((char*)" = ");
            }
            s.put((char*)"call ");
            s.put(ll_lty(in.ty));
            s.put((char*)" @");
            s.put(in.callee);
            s.put((char*)"(");
            for (int i = 0; i < in.argc; i++)
            {
                if (i > 0) { s.put((char*)", "); }
                ll_typed(s, in.args[i]);
            }
            if (in.va) { if (in.argc > 0) { s.put((char*)", "); } s.put((char*)"..."); }
            s.put((char*)")");
            break;
        }
    }
    s.put((char*)"\n");
}

// phi for a parameterized block: one incoming per predecessor edge.
fn void ll_phis(Sb* s, LFunc* f, LBlock* b)
{
    if (b.np == 0) { return; }
    for (int p = 0; p < b.np; p++)
    {
        s.put((char*)"  %");
        s.put(b.params[p].name);
        s.put((char*)" = phi ");
        s.put(ll_lty(b.params[p].ty));
        bool first = true;
        for (int oi = 0; oi < f.nb; oi++)
        {
            LBlock* o = f.blocks[oi];
            if (!o.has_term) { continue; }
            LTerm* t = &o.term;
            int hit = 0;
            if (t.k == LTM_JUMP && air_text::streq(t.target, b.name)) { hit = 1; }
            else if (t.k == LTM_BR && (air_text::streq(t.t1, b.name) || air_text::streq(t.t2, b.name))) { hit = 1; }
            else if (t.k == LTM_SWITCH)
            {
                if (t.def != null && air_text::streq(t.def, b.name)) { hit = 1; }
                for (int c = 0; c < t.ncase; c++) { if (air_text::streq(t.tgts[c], b.name)) { hit = 1; } }
            }
            if (hit == 0) { continue; }
            LAtom arg = lair_ir::la_atom_unit();
            if (t.k == LTM_JUMP && t.argc > p) { arg = t.args[p]; }
            if (!first) { s.put((char*)", "); }
            first = false;
            s.put((char*)"[ ");
            ll_atom(s, arg);
            s.put((char*)", %");
            s.put(o.name);
            s.put((char*)" ]");
        }
        if (first) { s.put((char*)"[ zeroinitializer, entry ]"); }   // unreachable param edge: keep the text valid
        s.put((char*)"\n");
    }
}

fn void ll_term(Sb* s, LTerm* t)
{
    s.put((char*)"  ");
    switch (t.k)
    {
        case LTM_RET:
            s.put((char*)"ret ");
            if (t.a.ty == LT_UNIT || t.a.k == LA_UNIT) { s.put((char*)"void"); }
            else { ll_typed(s, t.a); }
            break;
        case LTM_JUMP:
            // LLVM has no `jump`: a parameterless jump is `br label`, and an
            // argument-passing jump's edge args are already the target's phi
            // incoming values (ll_phis), so the terminator is the same br.
            s.put((char*)"br label %");
            s.put(t.target);
            break;
        case LTM_BR:
            s.put((char*)"br i1 ");
            ll_atom(s, t.a);
            s.put((char*)", label %");
            s.put(t.t1);
            s.put((char*)", label %");
            s.put(t.t2);
            break;
        case LTM_SWITCH:
        {
            s.put((char*)"switch ");
            s.put(ll_lty(t.a.ty));
            s.put((char*)" ");
            ll_atom(s, t.a);
            s.put((char*)", label %");
            s.put(t.def != null ? t.def : (char*)"unreachable");
            s.put((char*)" [\n");
            for (int i = 0; i < t.ncase; i++)
            {
                s.put((char*)"    ");
                s.put(ll_lty(t.a.ty));
                s.put((char*)" ");
                s.int_(t.vals[i]);
                s.put((char*)", label %");
                s.put(t.tgts[i]);
                s.put((char*)"\n");
            }
            s.put((char*)"  ]");
            break;
        }
        case LTM_TRAP:
            s.put((char*)"call void @llvm.trap()\n  unreachable");
            break;
        case LTM_UNREACH:
            s.put((char*)"unreachable");
            break;
    }
    s.put((char*)"\n");
}

fn void ll_func(Sb* s, LFunc* f)
{
    s.put((char*)"define ");
    s.put(ll_lty(f.ret));
    s.put((char*)" @");
    s.put(f.name);
    s.put((char*)"(");
    for (int i = 0; i < f.np; i++)
    {
        if (i > 0) { s.put((char*)", "); }
        s.put(ll_lty(f.params[i].ty));
        s.put((char*)" %");
        s.put(f.params[i].name);
    }
    s.put((char*)") {\n");
    for (int b = 0; b < f.nb; b++)
    {
        LBlock* blk = f.blocks[b];
        s.put(blk.name);
        s.put((char*)":\n");
        ll_phis(s, f, blk);
        for (int k = 0; k < blk.ni; k++) { ll_instr(s, blk.instrs + k); }
        ll_term(s, &blk.term);
    }
    s.put((char*)"}\n\n");
}

fn bool write_ll(LModule* lm, void* out)
{
    Sb s;
    s.init();
    s.put((char*)"; lairc (LAIR -> LLVM), source: ");
    s.put(lm.source != null ? lm.source : (char*)"?");
    s.put((char*)"\nsource_filename = \"");
    s.put(lm.source != null ? lm.source : (char*)"m");
    s.put((char*)"\"\n");
    s.put((char*)"target triple = \"");
    s.put(ll_triple());
    s.put((char*)"\"\n");
    s.put((char*)"target datalayout = \"");
    s.put(ll_datalayout());
    s.put((char*)"\"\n\n");
    for (int i = 0; i < lm.next_; i++)
    {
        LExtern* e = lm.externs[i];
        s.put((char*)"declare ");
        s.put(ll_lty(e.ret));
        s.put((char*)" @");
        s.put(e.name);
        s.put((char*)"(");
        for (int k = 0; k < e.np; k++)
        {
            if (k > 0) { s.put((char*)", "); }
            s.put(ll_lty(e.params[k]));
        }
        if (e.va) { if (e.np > 0) { s.put((char*)", "); } s.put((char*)"..."); }
        s.put((char*)")\n");
    }
    if (lm.next_ > 0) { s.put((char*)"\n"); }
    s.put((char*)"declare void @llvm.trap()\n\n");
    for (int i = 0; i < lm.nf; i++) { ll_func(&s, lm.funcs[i]); }
    s.put((char*)"!llvm.module.flags = !{!0, !1, !2}\n");
    s.put((char*)"!llvm.ident = !{!3}\n\n");
    s.put((char*)"!0 = !{i32 1, !\"wchar_size\", i32 4}\n");
    s.put((char*)"!1 = !{i32 8, !\"PIC Level\", i32 2}\n");
    s.put((char*)"!2 = !{i32 7, !\"PIE Level\", i32 2}\n");
    s.put((char*)"!3 = !{!\"lairc 0.1\"}\n");
    char* txt = s.take();
    bool ok = fputs(txt, out) >= 0;
    free(txt);
    return ok;
}
