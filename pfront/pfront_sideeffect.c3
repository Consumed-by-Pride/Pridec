// ============================================================================
// pfront_sideeffect.c3 — Fine-grained side-effect classification
// ----------------------------------------------------------------------------
// Walks every expression and tags it with a finer-grained effect class than
// the coarse EFF_IO/ALLOC/... bits on n.effects. Categories:
//
//   SE_NONE       : pure, no side effects, no memory read
//   SE_READ       : reads from heap/global (readonly)
//   SE_WRITE      : writes to heap/global
//   SE_ALLOC      : allocates (malloc/calloc)
//   SE_DEALLOC    : frees memory
//   SE_IO         : performs I/O (print/read/syscall)
//   SE_DIV        : may divide by zero (arithmetic risk)
//   SE_PANIC      : may panic/abort/unreachable
//   SE_DIVERGE    : may infinite-loop
//   SE_UNKNOWN    : unknown/opaque call — be conservative
//
// A per-function tally is accumulated. The pass is purely advisory; it
// complements the EFF_* bits with a richer lattice that can inform inlining
// and code-motion decisions without ever enforcing anything.
// ============================================================================

module pfront_sideeffect;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk     = pfront_core::NodeKind;
alias Tk     = pfront_lex::TokenType;
alias Node   = pfront_core::PNode;
alias Arena  = pfront_core::Arena;
alias Cfg    = pfront_cfg::Cfg;
alias Block  = pfront_cfg::Block;

extern fn int printf(char* fmt, ...);

const uint SE_NONE     = 0;
const uint SE_READ     = 1;
const uint SE_WRITE    = 2;
const uint SE_ALLOC    = 4;
const uint SE_DEALLOC  = 8;
const uint SE_IO       = 16;
const uint SE_DIV      = 32;
const uint SE_PANIC    = 64;
const uint SE_DIVERGE  = 128;
const uint SE_UNKNOWN  = 256;

struct SideEffect
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_pure;
    usz    n_readonly;
    usz    n_write;
    usz    n_alloc;
    usz    n_dealloc;
    usz    n_io;
    usz    n_div;
    usz    n_panic;
    usz    n_diverge;
    usz    n_unknown;
    usz    n_total;
    usz    n_pure_calls;
    usz    n_arith_risky;
}

fn void SideEffect.init(SideEffect* se, Arena* a)
{
    se.arena = a;
    se.cfg = null;
    se.n_pure = 0; se.n_readonly = 0; se.n_write = 0; se.n_alloc = 0;
    se.n_dealloc = 0; se.n_io = 0; se.n_div = 0; se.n_panic = 0;
    se.n_diverge = 0; se.n_unknown = 0; se.n_total = 0; se.n_pure_calls = 0;
    se.n_arith_risky = 0;
}

fn uint classify(Node* n)
{
    if (n == null) { return SE_NONE; }
    uint e = SE_NONE;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_FLOAT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_STRING:
        case Nk.N_EXPR_NULL:
            return SE_NONE;
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
            {
                e = e | SE_DIV;
            }
            // potential shift overflow if shift >= bits
            if (op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT || op == Tk.TOKEN_RSHIFT)
            {
                e = e | SE_DIV; // reuse risky bucket
            }
            break;
        }
        case Nk.N_EXPR_CALL:
        {
            // Inspect effects bits if present
            const ulong EF_IO = 1;
            const ulong EF_ALLOC = 2;
            const ulong EF_UNSAFE = 4;
            const ulong EF_UB = 8;
            const ulong EF_PANIC = 16;
            const ulong EF_DIVERGE = 32;
            ulong ef = n.effects;
            if ((ef & EF_IO) != 0) { e = e | SE_IO; }
            if ((ef & EF_ALLOC) != 0) { e = e | SE_ALLOC; }
            if ((ef & EF_PANIC) != 0) { e = e | SE_PANIC; }
            if ((ef & EF_DIVERGE) != 0) { e = e | SE_DIVERGE; }
            if ((ef & EF_UB) != 0) { e = e | SE_UNKNOWN; }
            if (e == SE_NONE) { return SE_UNKNOWN; } // unresolved call, conservative
            break;
        }
        case Nk.N_STMT_ASSIGN:
            e = e | SE_WRITE;
            break;
        case Nk.N_EXPR_UNARY:
        {
            Tk op = (Tk)n.p.op;
            if (op == Tk.TOKEN_STAR) { e = e | SE_READ; } // deref read
            break;
        }
        default: break;
    }
    // Union effects from children
    for (usz i = 0; i < n.child_count; i++)
    {
        uint ce = classify(n.children[i]);
        e = e | ce;
    }
    return e;
}

fn void se_count(SideEffect* se, uint e)
{
    se.n_total = se.n_total + 1;
    if (e == SE_NONE) { se.n_pure++; return; }
    if ((e & SE_UNKNOWN) != 0) { se.n_unknown++; }
    if ((e & SE_WRITE) != 0) { se.n_write++; }
    else if ((e & SE_READ) != 0) { se.n_readonly++; }
    if ((e & SE_ALLOC) != 0) { se.n_alloc++; }
    if ((e & SE_DEALLOC) != 0) { se.n_dealloc++; }
    if ((e & SE_IO) != 0) { se.n_io++; }
    if ((e & SE_DIV) != 0) { se.n_div++; se.n_arith_risky++; }
    if ((e & SE_PANIC) != 0) { se.n_panic++; }
    if ((e & SE_DIVERGE) != 0) { se.n_diverge++; }
    // Call entirely pure?
    if ((e & (SE_READ|SE_WRITE|SE_ALLOC|SE_DEALLOC|SE_IO|SE_DIV|SE_PANIC|SE_DIVERGE|SE_UNKNOWN)) == 0)
    {
        se.n_pure_calls++;
    }
}

fn void se_scan_stmts(SideEffect* se, Node* n, usz depth)
{
    if (n == null || depth > 200) { return; }
    uint e = classify(n);
    se_count(se, e);
    for (usz i = 0; i < n.child_count; i++)
    {
        se_scan_stmts(se, n.children[i], depth + 1);
    }
}

fn void SideEffect.run_on_cfg(SideEffect* se, Cfg* cfg)
{
    if (cfg == null) { return; }
    se.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++)
    {
        Block* b = &cfg.blocks[i];
        for (usz j = 0; j < b.stmt_count; j++)
        {
            se_scan_stmts(se, b.stmts[j], 0);
        }
        if (b.term_node != null)
        {
            uint e = classify(b.term_node);
            se_count(se, e);
        }
    }
}

fn void SideEffect.report(SideEffect* se)
{
    printf("  side-effect      : pure=%d readonly=%d write=%d\n",
           (int)se.n_pure, (int)se.n_readonly, (int)se.n_write);
    printf("  side-effect-ops  : alloc=%d free=%d io=%d panic=%d div=%d\n",
           (int)se.n_alloc, (int)se.n_dealloc, (int)se.n_io,
           (int)se.n_panic, (int)se.n_div);
    printf("  side-effect-cons : diverge=%d unknown=%d risky-arith=%d\n",
           (int)se.n_diverge, (int)se.n_unknown, (int)se.n_arith_risky);
}
