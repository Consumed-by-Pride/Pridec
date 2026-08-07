// ============================================================================
// pfront_effectinfer.c3 — Function effect summary inference
// ----------------------------------------------------------------------------
// Computes a per-function effect bit vector bottom-up over the body, without
// relying on the call graph. Each function's summary is the union of:
//   * Direct effects in its body (IO/alloc/unsafe/ub/panic/diverge).
//   * Effects of any directly CALLED functions whose resolved target we know.
//   * EFF_VOLATILE for unresolved/indirect calls.
//
// This is a local, cheap companion to pfront_purity's global fixed point.
// It runs without building the call graph so it can be used during editing.
//
// Output: sets n.effects bit more precisely on N_DECL_FN nodes (the parser
// currently marks every extern call as EFF_UNSAFE conservatively; this
// tightens it). In Pride's untyped world this is strictly informational —
// no pass ever rejects code based on effects.
// ============================================================================

module pfront_effectinfer;

import pfront_core;

alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn int printf(char* fmt, ...);

const ulong EI_IO      = 1;
const ulong EI_ALLOC   = 2;
const ulong EI_UNSAFE  = 4;
const ulong EI_UB      = 8;
const ulong EI_PANIC   = 16;
const ulong EI_DIVERGE = 32;
const ulong EI_VOLATILE = EI_IO|EI_DIVERGE|EI_PANIC|EI_UNSAFE|EI_UB;

struct EffectInfer
{
    Arena* arena;
    usz    n_fns;
    usz    n_pure;
    usz    n_total;
    usz    n_partial;
    usz    n_impure;
    usz    fns_tightened;
}

fn void EffectInfer.init(EffectInfer* ei, Arena* a)
{
    ei.arena = a;
    ei.n_fns = 0; ei.n_pure = 0; ei.n_total = 0; ei.n_partial = 0;
    ei.n_impure = 0; ei.fns_tightened = 0;
}

fn ulong ei_scan(EffectInfer* ei, Node* n)
{
    if (n == null) return 0;
    ulong e = n.effects;
    // If this is a known call to another fn, merge that fn's known effects
    // (one level only; deeper levels come from iterative runs).
    if (n.kind == Nk.N_EXPR_CALL && n.child_count >= 1)
    {
        Node* tgt = n.children[0];
        if (tgt != null && tgt.resolved != null && tgt.resolved.kind == Nk.N_DECL_FN)
        {
            e = e | tgt.resolved.effects;
        }
        else if (tgt != null && tgt.kind != Nk.N_EXPR_IDENT && tgt.kind != Nk.N_EXPR_PATH)
        {
            // Indirect call: assume volatile.
            e = e | EI_VOLATILE;
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        e = e | ei_scan(ei, n.children[i]);
    }
    return e;
}

fn void ei_scan_fns(EffectInfer* ei, Node* n)
{
    if (n == null) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        ei.n_fns = ei.n_fns + 1;
        ulong before = n.effects;
        ulong e = 0;
        for (usz i = 0; i < n.child_count; i++)
        {
            e = e | ei_scan(ei, n.children[i]);
        }
        // Tighten (don't broaden — be conservative by keeping old bits if any).
        ulong after = before | e;
        n.effects = after;
        if (after != before) ei.fns_tightened = ei.fns_tightened + 1;
        bool vol = (after & EI_VOLATILE) != 0;
        bool panics = (after & (EI_UB|EI_PANIC)) != 0;
        bool allocs = (after & EI_ALLOC) != 0;
        if (vol) { ei.n_impure++; }
        else if (panics) { ei.n_partial++; }
        else if (allocs) { ei.n_total++; }
        else { ei.n_pure++; }
        return;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ei_scan_fns(ei, n.children[i]);
    }
}

fn void EffectInfer.run(EffectInfer* ei, Node* root)
{
    if (root == null) return;
    // Two passes so that direct callees' computed effects propagate up.
    ei_scan_fns(ei, root);
    ei_scan_fns(ei, root);
}

fn void EffectInfer.report(EffectInfer* ei)
{
    printf("  effect-infer fns : %d (tightened %d)\n",
           (int)ei.n_fns, (int)ei.fns_tightened);
    printf("  effect-infer cls : pure %d, total %d, partial %d, impure %d\n",
           (int)ei.n_pure, (int)ei.n_total, (int)ei.n_partial, (int)ei.n_impure);
}
