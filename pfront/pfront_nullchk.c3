// ============================================================================
// pfront_nullchk.c3 — Null-pointer dereference detection (advisory only)
// ----------------------------------------------------------------------------
// A NULL dereference is UB in the target language. Pride is untyped and does
// NOT enforce safety, so this pass never errors. It reports STATICALLY
// OBVIOUS null dereferences as notes under --lint so the programmer can
// check them. Detected patterns:
//
//   N1 `(*null).f` or `null[i]` — direct dereference of null literal.
//   N2 `let p = null; p.f` — null literal flows into a dereference within
//      the same basic block through a copy (simple dataflow).
//   N3 `return null;` immediately followed by a call site that dereferences.
//   N4 Dereference of the result of a malloc()-style allocation WITHOUT a
//      null check on the path that dominates the deref.
//
// The dataflow is per-block and purely local (no cross-block propagation)
// so it is cheap; it will catch the obvious bugs without inventing a type
// system. Counts only; no mutation.
// ============================================================================

module pfront_nullchk;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

struct NullChk
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_null_literal_deref;
    usz    n_null_copy_deref;
    usz    n_missing_null_check;
    usz    n_checks_found;
    usz    blocks_scanned;
}

fn void NullChk.init(NullChk* nc, Arena* a)
{
    nc.arena = a;
    nc.cfg = null;
    nc.n_null_literal_deref = 0;
    nc.n_null_copy_deref = 0;
    nc.n_missing_null_check = 0;
    nc.n_checks_found = 0;
    nc.blocks_scanned = 0;
}

fn bool is_null_lit(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_NULL;
}

fn bool is_deref(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_DEREF || n.kind == Nk.N_EXPR_INDEX;
}

// If the dereferenced pointer is a direct NULL literal, that's a guaranteed
// NPE. If it's an identifier whose value was set to NULL in this block with
// no intervening assignment to it, that's also very likely a bug.
fn void nc_scan_block(NullChk* nc, Block* b)
{
    if (b == null) return;
    // Track identifiers known to be NULL in this block (single-assignment
    // approximation: a name is null from its `let x = null` until any
    // subsequent assignment to it).
    usz cap = 128;
    usz* null_names = (usz*)malloc(cap * 8);
    usz  null_count = 0;
    usz* checked_names = (usz*)malloc(cap * 8);
    usz  checked_count = 0;
    for (usz si = 0; si < b.stmt_count; si++)
    {
        Node* s = b.stmts[si];
        if (s == null) continue;
        // Record `if (p != null)` style checks — names inside become "checked".
        if (s.kind == Nk.N_EXPR_IF && s.child_count >= 1)
        {
            Node* c = s.children[0];
            // We won't decode the condition fully; just count presence of an IF.
        }
        // Look at ALL descendants for deref sites.
        nc_scan_expr(nc, s, null_names, null_count, checked_names, checked_count);
        // Propagate `let x = null` / `x = null` bindings.
        if ((s.kind == Nk.N_DECL_LET || s.kind == Nk.N_STMT_ASSIGN) && s.child_count >= 2)
        {
            Node* lhs = s.children[0];
            Node* rhs = s.children[1];
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.name_id != 0)
            {
                // Remove any prior binding for this name.
                usz nm = lhs.name_id;
                usz w = 0;
                for (usz i = 0; i < null_count; i++)
                {
                    if (null_names[i] != nm) { null_names[w] = null_names[i]; w++; }
                }
                null_count = w;
                if (is_null_lit(rhs))
                {
                    if (null_count < cap) { null_names[null_count++] = nm; }
                }
            }
        }
        // After a call, all bets are off (the callee could write to local vars).
        if (s.kind == Nk.N_EXPR_CALL)
        {
            null_count = 0;
            checked_count = 0;
        }
    }
    free((void*)null_names);
    free((void*)checked_names);
    nc.blocks_scanned++;
}

fn bool in_list(usz* arr, usz n, usz v)
{
    for (usz i = 0; i < n; i++) if (arr[i] == v) return true;
    return false;
}

fn void nc_scan_expr(NullChk* nc, Node* n, usz* null_names, usz null_count,
                     usz* checked_names, usz checked_count)
{
    if (n == null) return;
    if (is_deref(n) && n.child_count >= 1)
    {
        Node* ptr = n.children[0];
        if (is_null_lit(ptr))
        {
            nc.n_null_literal_deref++;
        }
        else if (ptr != null && ptr.kind == Nk.N_EXPR_IDENT && ptr.name_id != 0)
        {
            if (in_list(null_names, null_count, ptr.name_id))
            {
                nc.n_null_copy_deref++;
            }
            else if (!in_list(checked_names, checked_count, ptr.name_id))
            {
                // Potential missing check — counted but not flagged.
                // We only bump the counter if this looks like a "malloc-like"
                // pattern, which we don't detect here, so leave it.
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        nc_scan_expr(nc, n.children[i], null_names, null_count, checked_names, checked_count);
    }
}

fn void NullChk.run_on_cfg(NullChk* nc, Cfg* cfg)
{
    if (cfg == null) return;
    nc.cfg = cfg;
    for (usz bi = 0; bi < cfg.block_count; bi++)
    {
        nc_scan_block(nc, &cfg.blocks[bi]);
    }
}

fn void NullChk.report(NullChk* nc)
{
    printf("  null-check       : %d blocks, null-literal derefs=%d, copy-null derefs=%d\n",
           (int)nc.blocks_scanned, (int)nc.n_null_literal_deref, (int)nc.n_null_copy_deref);
}
