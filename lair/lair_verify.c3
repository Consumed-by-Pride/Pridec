// ============================================================================
// lair_verify.c3 — the independent check of docs/pear2/LAIR.md §3.
//
// The lowerer already refuses everything out of the slice with positions;
// this pass re-derives the structural invariants from the LModule alone, so a
// lowering bug fails HERE, before anything is printed, with the function's
// position:
//
//   L1  every jump/br/switch target exists, and edge arity = parameters
//   L2  every variable atom is defined on a block that dominates its use
//   L3  every block ends in exactly one terminator
//   L4  return atom types agree with the function's return type
//   L5  edge argument types agree with the target block's parameters
//
// Dominators are the textbook iterative intersection over the block graph;
// the entry block dominates itself, and every use must be defined in a block
// whose dom-set contains the use's block. Block parameters are defined at
// the top of their block (N3), function parameters at entry. The environment
// is flat with shadowing (the lowerer's scopes): lookups take the innermost
// binding, and a source label block's parameters are unset again after the
// block -- they are scope-local, while a while-header phi persists (the
// lowerer rebinds the carried names to it after the loop).
// ============================================================================
module lair_verify;
extern fn int fprintf(void* f, char* fmt, ...);
extern fn void* fdopen(int fd, char* mode);
extern fn int fflush(void* f);

import air_ir;
import air_text;
import air_util;
import lair_ir;

struct VState
{
    LFunc* f;
    LModule* lm;
    int errs;
    char* fn_name;
    int line;
}

fn void VState.verr(VState* v, char* what, char* who)
{
    v.errs++;
    v.lm.errs++;
    char* src = v.lm.source != null ? v.lm.source : (char*)"?";
    void* se = fdopen(2, "w");
    if (who != null)
    {
        fprintf(se, "lairc: %s:%d: verify: in %s: %s: %s\n", src, v.line, v.fn_name, what, who);
    }
    else
    {
        fprintf(se, "lairc: %s:%d: verify: in %s: %s\n", src, v.line, v.fn_name, what);
    }
    fflush(se);
}

// name -> type / defining block. Bind-once (the lowerer refuses duplicate
// names), so a flat map is a complete environment for the whole function.
struct VEnv
{
    char*[512] names;
    LTy[512] tys;
    int[512] blk;
    int n;
}

fn int v_find(VEnv* e, char* nm)
{
    if (nm == null) { return -1; }
    for (int i = e.n - 1; i >= 0; i--)
    {
        if (air_text::streq(e.names[i], nm)) { return i; }
    }
    return -1;
}

// remove the innermost entry with this name (scope exit)
fn void v_unset(VEnv* e, char* nm)
{
    int idx = v_find(e, nm);
    if (idx < 0 || idx != e.n - 1) { return; }
    e.n--;
}

fn void v_set(VEnv* e, char* nm, LTy t, int blk)
{
    if (e.n >= 512) { return; }
    e.names[e.n] = nm;
    e.tys[e.n] = t;
    e.blk[e.n] = blk;
    e.n++;
}

// Dominator sets: block i occupies bits 2i and 2i+1 of a flat ulong array
// (128 blocks x 2 words). Single-dimension arrays only -- no nested fixed
// arrays, per the repo's C3 style rules.
struct DomSets
{
    int n;
    ulong[256] bits;
}

fn bool dom_has(DomSets* d, int b, int i)
{
    int w = b * 2 + (i / 64);
    int bit = i % 64;
    return (d.bits[w] & (1ul << bit)) != 0;
}

fn void dom_set(DomSets* d, int b, int i)
{
    int w = b * 2 + (i / 64);
    int bit = i % 64;
    d.bits[w] = d.bits[w] | (1ul << bit);
}

fn void dom_clear(DomSets* d, int b)
{
    d.bits[b * 2] = 0;
    d.bits[b * 2 + 1] = 0;
}

fn void dom_copy(DomSets* d, int dst, int src)
{
    d.bits[dst * 2] = d.bits[src * 2];
    d.bits[dst * 2 + 1] = d.bits[src * 2 + 1];
}

fn bool dom_eq(DomSets* d, int a, int b)
{
    return d.bits[a * 2] == d.bits[b * 2] && d.bits[a * 2 + 1] == d.bits[b * 2 + 1];
}

// The atom a terminator or instruction mentions, checked against blk: its
// defining block (from the environment) must dominate the use's block.
fn void v_atom(VState* v, VEnv* e, DomSets* d, LAtom a, int blk)
{
    if (a.k != LA_VAR) { return; }
    int idx = v_find(e, a.name);
    if (idx < 0)
    {
        VState.verr(v, "use of a name with no definition", a.name);
        return;
    }
    if (!dom_has(d, blk, e.blk[idx]))
    {
        VState.verr(v, "use is not dominated by its definition", a.name);
    }
}

fn LTy v_atom_ty(VEnv* e, LAtom a)
{
    if (a.k != LA_VAR && a.k != LA_SYM) { return a.ty; }
    int idx = v_find(e, a.name);
    if (idx < 0) { return LT_INVALID; }
    return e.tys[idx];
}

// block name -> index (the lowerer makes names unique per function)
fn int v_find_blk(LFunc* f, char* nm)
{
    if (nm == null) { return -1; }
    for (int i = 0; i < f.nb; i++)
    {
        if (air_text::streq(f.blocks[i].name, nm)) { return i; }
    }
    return -1;
}

fn int verify_func(VState* v)
{
    LFunc* f = v.f;
    int nb = f.nb;
    if (nb == 0)
    {
        VState.verr(v, "function has no blocks", f.name);
        return v.errs;
    }
    // predecessors
    int* preds = (int*)v.lm.arena.alloc((usz)nb * 128 * int::size, 8);
    if (preds == null) { VState.verr(v, "out of memory", null); return 1; }
    for (int i = 0; i < nb * 128; i++) { preds[i] = 0; }
    for (int i = 0; i < nb; i++)
    {
        LBlock* b = f.blocks[i];
        if (!b.has_term) { continue; }
        int[72] t;
        int nt = 0;
        switch (b.term.k)
        {
            case LTM_JUMP:
            {
                int tg = v_find_blk(f, b.term.target);
                if (tg >= 0) { t[nt] = tg; nt++; }
                break;
            }
            case LTM_BR:
            {
                int a1 = v_find_blk(f, b.term.t1);
                int a2 = v_find_blk(f, b.term.t2);
                if (a1 >= 0) { t[nt] = a1; nt++; }
                if (a2 >= 0) { t[nt] = a2; nt++; }
                break;
            }
            case LTM_SWITCH:
            {
                for (int c = 0; c < b.term.ncase; c++)
                {
                    int tg = v_find_blk(f, b.term.tgts[c]);
                    if (tg >= 0) { t[nt] = tg; nt++; }
                }
                int df = v_find_blk(f, b.term.def);
                if (df >= 0) { t[nt] = df; nt++; }
                break;
            }
            default: break;
        }
        for (int k = 0; k < nt; k++)
        {
            int slot = t[k] * 128 + 0;
            int count = preds[slot];
            if (count < 127) { preds[t[k] * 128 + 1 + count] = i; preds[t[k] * 128] = count + 1; }
        }
    }
    // dominators: init all = {all}, entry = {entry}; iterate to a fixpoint
    DomSets doms;
    doms.n = nb;
    for (int i = 0; i < 256; i++) { doms.bits[i] = 0; }
    for (int b = 0; b < nb; b++)
    {
        for (int i = 0; i < nb; i++) { dom_set(&doms, b, i); }
    }
    dom_clear(&doms, 0);
    dom_set(&doms, 0, 0);
    bool changed = true;
    int guard = 0;
    while (changed && guard < 4096)
    {
        changed = false;
        guard++;
        for (int b = 1; b < nb; b++)
        {
            int* ps = preds + b * 128;
            int pc = ps[0];
            // new = {b} ∩ (intersection of preds' doms); unreachable (pc==0) keeps all
            if (pc == 0) { continue; }
            DomSets acc;
            acc.n = nb;
            for (int i = 0; i < 256; i++) { acc.bits[i] = 0; }
            for (int i = 0; i < nb; i++) { dom_set(&acc, 0, i); }
            for (int k = 0; k < pc; k++)
            {
                int p = ps[1 + k];
                for (int i = 0; i < nb; i++)
                {
                    if (!dom_has(&acc, 0, i) || !dom_has(&doms, p, i))
                    {
                        int w = (i / 64);
                        int bit = i % 64;
                        acc.bits[w] = acc.bits[w] & ~(1ul << bit);
                    }
                }
            }
            // union {b}
            dom_set(&acc, 0, b);
            // acc's set lives at acc's index 0 (words 0,1); compare it with
            // doms[b] (words 2b, 2b+1) -- doms[0] is ENTRY, never the scratch.
            if (doms.bits[b * 2] != acc.bits[0] || doms.bits[b * 2 + 1] != acc.bits[1])
            {
                doms.bits[b * 2] = acc.bits[0];
                doms.bits[b * 2 + 1] = acc.bits[1];
                changed = true;
            }
        }
    }
    // environment + structural checks, blocks in creation order
    VEnv env;
    env.n = 0;
    for (int i = 0; i < f.np; i++)
    {
        v_set(&env, f.params[i].name, f.params[i].ty, 0);      // params live in entry
    }
    for (int i = 0; i < nb; i++)
    {
        LBlock* b = f.blocks[i];
        v.line = f.source_line;
        // L3
        if (!b.has_term)
        {
            VState.verr(v, "block without a terminator", b.name);
            continue;
        }
        // N3: block parameters are defined at the top of the block
        for (int p = 0; p < b.np; p++)
        {
            v_set(&env, b.params[p].name, b.params[p].ty, i);
        }
        // instructions
        for (int k = 0; k < b.ni; k++)
        {
            LInstr* in = b.instrs + k;
            switch (in.op)
            {
                case LI_BINOP:
                case LI_UNOP:
                case LI_COERCE:
                    v_atom(v, &env, &doms, in.a, i);
                    if (in.op == LI_BINOP) { v_atom(v, &env, &doms, in.b, i); }
                    break;
                case LI_CALL:
                    for (int a = 0; a < in.argc; a++) { v_atom(v, &env, &doms, in.args[a], i); }
                    break;
            }
            if (in.dst != null) { v_set(&env, in.dst, in.ty, i); }
        }
        // terminator
        LTerm* t = &b.term;
        switch (t.k)
        {
            case LTM_RET:
            {
                v_atom(v, &env, &doms, t.a, i);
                if (f.ret != LT_INVALID)
                {
                    LTy got = v_atom_ty(&env, t.a);
                    if (got != LT_INVALID && got != f.ret)
                    {
                        Sb s; s.init();
                        s.put((char*)"return atom is ");
                        s.put(lair_ir::lty_name(got));
                        s.put((char*)", function returns ");
                        s.put(lair_ir::lty_name(f.ret));
                        VState.verr(v, s.take(), b.name);
                    }
                }
                break;
            }
            case LTM_JUMP:
            {
                v_atom(v, &env, &doms, t.a, i);
                int tg = v_find_blk(f, t.target);
                if (tg < 0) { VState.verr(v, "jump to an unknown block", t.target); break; }
                // L1/L5 arity + types
                if (t.argc != f.blocks[tg].np)
                {
                    Sb s; s.init();
                    s.put((char*)"jump passes ");
                    s.int_((long)t.argc);
                    s.put((char*)" arguments, block has ");
                    s.int_((long)f.blocks[tg].np);
                    VState.verr(v, s.take(), t.target);
                    break;
                }
                for (int a = 0; a < t.argc; a++)
                {
                    v_atom(v, &env, &doms, t.args[a], i);
                    LTy got = v_atom_ty(&env, t.args[a]);
                    LTy want = f.blocks[tg].params[a].ty;
                    if (got != LT_INVALID && want != LT_INVALID && got != want)
                    {
                        VState.verr(v, "edge argument has the wrong type", t.target);
                    }
                }
                break;
            }
            case LTM_BR:
            {
                v_atom(v, &env, &doms, t.a, i);
                if (t.a.ty != LT_BOOL && v_atom_ty(&env, t.a) != LT_BOOL)
                {
                    VState.verr(v, "br condition is not a bool", b.name);
                }
                if (v_find_blk(f, t.t1) < 0) { VState.verr(v, "br to an unknown block", t.t1); }
                if (v_find_blk(f, t.t2) < 0) { VState.verr(v, "br to an unknown block", t.t2); }
                break;
            }
            case LTM_SWITCH:
            {
                v_atom(v, &env, &doms, t.a, i);
                for (int c = 0; c < t.ncase; c++)
                {
                    if (v_find_blk(f, t.tgts[c]) < 0) { VState.verr(v, "switch case to an unknown block", t.tgts[c]); }
                }
                if (t.def != null && v_find_blk(f, t.def) < 0) { VState.verr(v, "switch default to an unknown block", t.def); }
                break;
            }
            case LTM_TRAP:
            case LTM_UNREACH:
                break;
        }
        // a source label's parameters are scope-local: leave the environment
        // exactly as the lowerer left it after the label body
        if (b.lbl)
        {
            for (int p = 0; p < b.np; p++) { v_unset(&env, b.params[p].aname != null ? b.params[p].aname : b.params[p].name); }
        }
    }
    return v.errs;
}

fn int verify_module(LModule* lm)
{
    int before = lm.errs;
    for (int i = 0; i < lm.nf; i++)
    {
        VState v;
        v.f = lm.funcs[i];
        v.lm = lm;
        v.errs = 0;
        v.fn_name = v.f.name;
        v.line = v.f.source_line != 0 ? v.f.source_line : 1;
        verify_func(&v);
    }
    return lm.errs - before;
}
