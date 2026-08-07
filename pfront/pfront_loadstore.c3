// ============================================================================
// pfront_loadstore.c3 — Local load-store forwarding analysis (block-local)
// ----------------------------------------------------------------------------
// Within a basic block, a load from a location is redundant if an earlier
// store to the SAME location dominates it and no intervening store to an
// aliasing location occurs. This is the memory-version of CSE/GVN for
// memory accesses and is read-only (reports statistics only).
//
// For an untyped language like Pride we do NOT have types to tell us the
// size/alignment of a load, so we use a conservative address-equality
// based model: two accesses are "same location" if their address expression
// is syntactically identical (or GVN-equivalent via our existing VN).
//
// We also detect DEAD STORES: a store that is immediately overwritten by
// another store to the same location with no intervening load is dead.
//
// The analysis:
//   1. Walk statements forward per block.
//   2. Maintain a small "last store" table keyed by address expression.
//   3. When a load hits the table => redundant load (forwardable).
//   4. When a store hits the table => previous store is dead.
//   5. Effectful calls, unknown ptr writes, and escapes kill the table.
// ============================================================================

module pfront_loadstore;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk    = pfront_core::NodeKind;
alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz LS_MAX = 64;

struct LoadStore
{
    Arena* arena;
    Cfg*   cfg;

    usz redundant_loads;
    usz dead_stores;
    usz killed_tables;
    usz blocks_run;
}

fn void LoadStore.init(LoadStore* ls, Arena* a)
{
    ls.arena = a;
    ls.cfg = null;
    ls.redundant_loads = 0;
    ls.dead_stores = 0;
    ls.killed_tables = 0;
    ls.blocks_run = 0;
}

fn bool ls_is_store(Node* n)
{
    if (n == null) return false;
    if (n.kind == Nk.N_STMT_ASSIGN && n.child_count >= 1)
    {
        Node* tgt = n.children[0];
        if (tgt != null && (tgt.kind == Nk.N_EXPR_DEREF || tgt.kind == Nk.N_EXPR_INDEX))
        {
            return true;
        }
    }
    if (n.kind == Nk.N_STMT_COMPOUND_ASSIGN && n.child_count >= 1)
    {
        Node* tgt = n.children[0];
        if (tgt != null && (tgt.kind == Nk.N_EXPR_DEREF || tgt.kind == Nk.N_EXPR_INDEX))
        {
            return true;
        }
    }
    return false;
}

fn bool ls_is_load(Node* n)
{
    if (n == null) return false;
    return n.kind == Nk.N_EXPR_DEREF;
}

fn Node* ls_addr(Node* n)
{
    if (n == null) return null;
    if (n.kind == Nk.N_EXPR_DEREF && n.child_count >= 1) return n.children[0];
    if (n.kind == Nk.N_EXPR_INDEX && n.child_count >= 1) return n;
    return null;
}

fn bool ls_same_addr(Node* a, Node* b)
{
    if (a == b && a != null) return true;
    if (a == null || b == null) return false;
    if (a.kind != b.kind) return false;
    if (a.kind == Nk.N_EXPR_IDENT && b.kind == Nk.N_EXPR_IDENT)
    {
        return a.name_id != 0 && a.name_id == b.name_id;
    }
    if (a.kind == Nk.N_EXPR_INT && b.kind == Nk.N_EXPR_INT)
    {
        return a.p.ival == b.p.ival;
    }
    // For compound addresses (field, index) require identical child structure.
    if (a.child_count != b.child_count) return false;
    if (a.kind == Nk.N_EXPR_BINARY && (Tk)a.p.op != (Tk)b.p.op) return false;
    if (a.child_count == 0) return false;
    for (usz i = 0; i < a.child_count; i++)
    {
        if (!ls_same_addr(a.children[i], b.children[i])) return false;
    }
    return true;
}

fn bool ls_kills_table(Node* n)
{
    if (n == null) return true;
    // Effectful calls kill all entries (callee may write anything).
    if (n.kind == Nk.N_EXPR_CALL) return true;
    // asm / unsafe blocks kill everything.
    if (n.kind == Nk.N_EXPR_UNSAFE || n.kind == Nk.N_EXPR_UNCHECKED) return true;
    // Deferred code may run later.
    if (n.kind == Nk.N_STMT_DEFER) return true;
    // Try/handle have exceptional edges.
    if (n.kind == Nk.N_EXPR_TRY || n.kind == Nk.N_EXPR_HANDLE) return true;
    return false;
}

fn void LoadStore.run_on_cfg(LoadStore* ls, Cfg* cfg)
{
    if (cfg == null) return;
    ls.cfg = cfg;
    Node** store_addr = (Node**)malloc(LS_MAX * 8);
    Node** store_val  = (Node**)malloc(LS_MAX * 8);
    for (usz bi = 0; bi < cfg.block_count; bi++)
    {
        Block* b = &cfg.blocks[bi];
        usz n_stored = 0;
        bool killed = false;
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* s = b.stmts[si];
            if (s == null) continue;
            if (killed || ls_kills_table(s))
            {
                n_stored = 0;
                killed = false;
                ls.killed_tables++;
            }
            // Check for loads anywhere in s first.
            ls_scan_loads(ls, s, store_addr, store_val, n_stored);
            // If this is a store, record it.
            if (ls_is_store(s))
            {
                Node* addr = ls_addr(s.children[0]);
                if (addr != null)
                {
                    // Find existing entry to this addr -> previous store dead.
                    for (usz k = 0; k < n_stored; k++)
                    {
                        if (ls_same_addr(store_addr[k], addr))
                        {
                            ls.dead_stores++;
                            // Overwrite in place.
                            store_val[k] = s.children[1];
                            addr = null;   // don't re-add
                            break;
                        }
                    }
                    if (addr != null && n_stored < LS_MAX)
                    {
                        store_addr[n_stored] = addr;
                        store_val[n_stored] = (s.child_count >= 2) ? s.children[1] : null;
                        n_stored++;
                    }
                    else if (addr != null)
                    {
                        // table full, flush
                        n_stored = 0;
                        ls.killed_tables++;
                    }
                }
            }
        }
        ls.blocks_run++;
    }
    free((void*)store_addr);
    free((void*)store_val);
}

fn void ls_scan_loads(LoadStore* ls, Node* n, Node** addrs, Node** vals, usz n_stored)
{
    if (n == null) return;
    if (ls_is_load(n))
    {
        Node* addr = ls_addr(n);
        if (addr != null)
        {
            for (usz k = 0; k < n_stored; k++)
            {
                if (ls_same_addr(addrs[k], addr))
                {
                    ls.redundant_loads++;
                    break;
                }
            }
        }
        return;   // don't descend into the deref ptr (it's a use, not a load)
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        ls_scan_loads(ls, n.children[i], addrs, vals, n_stored);
    }
}

fn void LoadStore.report(LoadStore* ls)
{
    printf("  load-store       : %d redundant loads, %d dead stores (blocks %d, kills %d)\n",
           (int)ls.redundant_loads, (int)ls.dead_stores,
           (int)ls.blocks_run, (int)ls.killed_tables);
}
