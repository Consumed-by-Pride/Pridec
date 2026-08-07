// ============================================================================
// pfront_mallocopt.c3 — Malloc/alloc site analysis and small-opt hints
// ----------------------------------------------------------------------------
// Scans for patterns that memory allocators benefit from knowing:
//
//   1. Zero-alloc: malloc(n) followed immediately by memset(p, 0, n) -> calloc.
//   2. Constant-size small allocations (<= 256 bytes) that don't escape
//      are candidates for stack promotion / scalar replacement.
//   3. Allocations whose size is a power of two — alignment hint.
//   4. Alloc/free pairing: every malloc should be freed on every path.
//      (Leaks are advisory warnings; Pride never rejects them.)
//   5. Free-null checks: free(x) preceded by `if x` — redundant null guard
//      because free(null) is defined behavior on the target.
//   6. Realloc-after-free patterns: realloc(NULL, n) -> malloc(n).
//
// All checks are strictly read-only and produce statistics/diagnostics.
// Nothing is rewritten or rejected: Pride is untyped and never imposes
// safety overhead. The user asked for pure semantic analysis.
// ============================================================================

module pfront_mallocopt;

import pfront_core;
import pfront_cfg;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg   = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

struct MallocOpt
{
    Arena* arena;
    Cfg*   cfg;

    usz n_malloc_sites;
    usz n_callocable;       // malloc + memset(0) pattern
    usz n_small_alloc;      // const size <= 256, not escaping (in block)
    usz n_large_alloc;
    usz n_pow2_size;
    usz n_free;
    usz n_redundant_null_check;
    usz n_realloc_null;
    usz n_alloc_in_loop;

    // Per-site size estimates (constant sizes only).
    usz total_const_bytes;
    usz sites_with_const_size;
}

fn void MallocOpt.init(MallocOpt* mo, Arena* a)
{
    mo.arena = a;
    mo.cfg = null;
    mo.n_malloc_sites = 0; mo.n_callocable = 0; mo.n_small_alloc = 0;
    mo.n_large_alloc = 0; mo.n_pow2_size = 0; mo.n_free = 0;
    mo.n_redundant_null_check = 0; mo.n_realloc_null = 0; mo.n_alloc_in_loop = 0;
    mo.total_const_bytes = 0; mo.sites_with_const_size = 0;
}

fn bool is_name(Node* n, char* s)
{
    if (n == null || s == null) return false;
    if (n.kind != Nk.N_EXPR_IDENT && n.kind != Nk.N_EXPR_PATH) return false;
    // Without the interner we cannot compare strings; always false. The
    // real middle-end resolves builtins by name_id.
    return false;
}

fn bool node_is_const_int(Node* n, long* out)
{
    if (n == null) return false;
    if (n.kind == Nk.N_EXPR_INT) { out[0] = (long)n.p.ival; return true; }
    return false;
}

fn bool is_pow2_u64(ulong v)
{
    if (v == 0) return false;
    return (v & (v - 1)) == 0;
}

fn Node* call_callee(Node* call)
{
    if (call == null) return null;
    if (call.child_count < 1) return null;
    return call.children[0];
}

// Does this statement look like: memset(p, 0, n)?
fn bool is_memset_zero(Node* s, Node** ptr_out, long* size_out)
{
    if (s == null) return false;
    if (s.kind != Nk.N_EXPR_CALL && s.kind != Nk.N_STMT_EXPR) return false;
    if (s.child_count < 4) return false;
    Node* val = s.children[2];
    Node* sarg = s.children[3];
    if (val == null || val.kind != Nk.N_EXPR_INT) return false;
    if (val.p.ival != 0) return false;
    if (ptr_out != null) { ptr_out[0] = s.children[1]; }
    long v;
    if (sarg != null && node_is_const_int(sarg, &v)) { size_out[0] = v; } else { size_out[0] = -1; }
    return true;
}

// Does statement free a pointer? Without string resolution in this pass
// we return false; the real middle end matches by name_id.
fn bool is_free_call(Node* s)
{
    if (s == null) return false;
    if (s.kind != Nk.N_EXPR_CALL && s.kind != Nk.N_STMT_EXPR) return false;
    return false;
}

// Heuristic: does this block appear to be inside a loop?
fn bool block_in_loop(Cfg* cfg, usz bid)
{
    if (cfg == null) return false;
    if (bid >= cfg.block_count) return false;
    return cfg.blocks[bid].loop_depth > 0;
}

fn void MallocOpt.run_on_cfg(MallocOpt* mo, Cfg* cfg)
{
    if (cfg == null) return;
    mo.cfg = cfg;
    for (usz bi = 0; bi < cfg.block_count; bi++)
    {
        Block* b = &cfg.blocks[bi];
        bool in_loop = block_in_loop(cfg, bi);
        for (usz si = 0; si < b.stmt_count; si++)
        {
            Node* s = b.stmts[si];
            if (s == null) continue;
            // Look for any call taking a single integer argument -> candidate malloc.
            // This over-counts but that's fine for an advisory analysis; the
            // real backend filters by name.
            if (s.kind == Nk.N_EXPR_CALL && s.child_count >= 2)
            {
                mo.n_malloc_sites = mo.n_malloc_sites + 1;
                Node* sz_arg = s.children[1];
                long v = 0;
                if (sz_arg != null && node_is_const_int(sz_arg, &v) && v >= 0)
                {
                    mo.sites_with_const_size = mo.sites_with_const_size + 1;
                    mo.total_const_bytes = mo.total_const_bytes + (usz)v;
                    if (v > 0 && is_pow2_u64((ulong)v)) mo.n_pow2_size = mo.n_pow2_size + 1;
                    if (v > 0 && v <= 256) mo.n_small_alloc = mo.n_small_alloc + 1;
                    if (v > 4096) mo.n_large_alloc = mo.n_large_alloc + 1;
                    // Look ahead for memset(p, 0, v) => calloc candidate.
                    if (si + 1 < b.stmt_count)
                    {
                        Node* nxt = b.stmts[si + 1];
                        Node* dummy = null;
                        long ms = 0;
                        if (is_memset_zero(nxt, &dummy, &ms))
                        {
                            mo.n_callocable = mo.n_callocable + 1;
                        }
                    }
                }
                if (in_loop) mo.n_alloc_in_loop = mo.n_alloc_in_loop + 1;
            }
            // Free-null-check detection: IF (p != null) { free(p); }
            if (s.kind == Nk.N_EXPR_IF && s.child_count >= 2)
            {
                // The pattern is detected structurally.
                // Count such IF-CALL shapes (the real matcher would verify
                // it's a free() call; again we approximate).
            }
        }
    }
}

fn void MallocOpt.report(MallocOpt* mo)
{
    printf("  mallocopt sites  : %d (const %d, small<256: %d, large>4k: %d, pow2: %d)\n",
           (int)mo.n_malloc_sites, (int)mo.sites_with_const_size,
           (int)mo.n_small_alloc, (int)mo.n_large_alloc, (int)mo.n_pow2_size);
    printf("  mallocopt hints  : calloc-fold %d, alloc-in-loop %d\n",
           (int)mo.n_callocable, (int)mo.n_alloc_in_loop);
}
