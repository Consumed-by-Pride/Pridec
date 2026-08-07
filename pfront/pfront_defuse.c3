// ============================================================================
// pfront_defuse.c3 — Def-use chain construction (syntactic, CFG-local)
// ----------------------------------------------------------------------------
// For every local let-binding, records which later statements/expressions
// *use* that name, and whether there are any intervening re-defs (kills).
// Classic reaching-definitions lite: we walk each block forward; when we see
// a let-pattern-ident we record a def; when we see an ident-expr we append a
// use. This is BLOCK-LOCAL only (no phi-insertion across edges) — but that is
// already enough for many useful advisories:
//
//   - unused-but-set locals (def with zero uses)
//   - used-before-def? (impossible in Pride's let scoping, but record anyway)
//   - re-defined before first use (shadow-write dead store)
//   - number of distinct SSA-like webs across the function
//
// Purely advisory counters, never rejects.
// ============================================================================

module pfront_defuse;

import pfront_core;
import pfront_cfg;
import pfront_lex;

alias Nk      = pfront_core::NodeKind;
alias Tk      = pfront_lex::TokenType;
alias Node    = pfront_core::PNode;
alias Arena   = pfront_core::Arena;
alias Cfg     = pfront_cfg::Cfg;
alias Block   = pfront_cfg::Block;

extern fn int printf(char* fmt, ...);

const usz DU_MAX_LOCALS = 1024;

struct DuEntry
{
    Node* def;         // declaring node (N_PAT_IDENT under N_DECL_LET, or lhs ident)
    uint  name_id;
    usz   use_count;
    usz   block_id;
    usz   stmt_idx;
    bool  killed;      // another def of same name appeared before first use
    bool  ever_used;
    bool  used_in_nested;
}

struct DefUse
{
    Arena*    arena;
    Cfg*      cfg;
    DuEntry*  entries;
    usz       entry_cap;
    usz       entry_count;
    usz       n_dead_stores;        // defs with zero uses
    usz       n_multi_def;          // multiple defs of same name in scope
    usz       n_used_multi;         // name multiply defined but used
    usz       n_used_once;
    usz       n_used_many;
    usz       total_uses;
    usz       total_defs;
    usz       n_nested_uses;
    usz       n_loop_uses;
}

fn void DefUse.init(DefUse* du, Arena* a)
{
    du.arena = a;
    du.cfg = null;
    du.entry_cap = 256;
    du.entries = (DuEntry*)malloc((long)(du.entry_cap * DuEntry::size));
    du.entry_count = 0;
    du.n_dead_stores = 0; du.n_multi_def = 0; du.n_used_multi = 0;
    du.n_used_once = 0; du.n_used_many = 0; du.total_uses = 0;
    du.total_defs = 0; du.n_nested_uses = 0; du.n_loop_uses = 0;
}

fn int du_find(DefUse* du, uint name_id, usz block_id)
{
    if (du.entries == null) { return -1; }
    // Find most recent def in same block.
    int last = -1;
    for (usz i = 0; i < du.entry_count; i++)
    {
        if (du.entries[i].name_id == name_id && du.entries[i].block_id == block_id)
        {
            last = (int)i;
        }
    }
    return last;
}

fn int du_add_def(DefUse* du, Node* def, uint name_id, usz block_id, usz stmt_idx)
{
    if (du.entries == null || name_id == 0) { return -1; }
    // Mark previous def as killed if not yet used.
    int prev = du_find(du, name_id, block_id);
    if (prev >= 0 && !du.entries[prev].ever_used)
    {
        du.entries[prev].killed = true;
        du.n_dead_stores = du.n_dead_stores + 1;
    }
    if (prev >= 0) { du.n_multi_def = du.n_multi_def + 1; }
    if (du.entry_count >= du.entry_cap)
    {
        usz nc = du.entry_cap * 2;
        DuEntry* bigger = (DuEntry*)malloc((long)(nc * DuEntry::size));
        if (bigger == null) { return -1; }
        for (usz i = 0; i < du.entry_count; i++) { bigger[i] = du.entries[i]; }
        free((void*)du.entries);
        du.entries = bigger;
        du.entry_cap = nc;
    }
    int idx = (int)du.entry_count;
    du.entry_count = du.entry_count + 1;
    du.entries[idx].def = def;
    du.entries[idx].name_id = name_id;
    du.entries[idx].use_count = 0;
    du.entries[idx].block_id = block_id;
    du.entries[idx].stmt_idx = stmt_idx;
    du.entries[idx].killed = false;
    du.entries[idx].ever_used = false;
    du.entries[idx].used_in_nested = false;
    du.total_defs = du.total_defs + 1;
    return idx;
}

fn void du_record_use(DefUse* du, Node* use, uint name_id, usz block_id, bool in_loop, bool in_nested)
{
    if (name_id == 0) { return; }
    int idx = du_find(du, name_id, block_id);
    if (idx < 0)
    {
        // Use before any def in this block; could be an upvalue / param, skip.
        return;
    }
    du.entries[idx].use_count = du.entries[idx].use_count + 1;
    du.entries[idx].ever_used = true;
    du.total_uses = du.total_uses + 1;
    if (in_nested)
    {
        du.entries[idx].used_in_nested = true;
        du.n_nested_uses = du.n_nested_uses + 1;
    }
    if (in_loop) { du.n_loop_uses = du.n_loop_uses + 1; }
}

// Check if this node is the LHS of an assignment or a pat-ident in a let.
fn bool is_lhs_of(Node* parent, Node* child)
{
    if (parent == null) { return false; }
    if (parent.kind == Nk.N_STMT_ASSIGN && parent.child_count >= 1 && parent.children[0] == child)
    {
        return true;
    }
    return false;
}

fn void du_walk_expr(DefUse* du, Node* n, Node* parent, usz bid, bool in_loop, bool in_nested, usz lvl)
{
    if (n == null || lvl > 100) { return; }
    if (n.kind == Nk.N_EXPR_IDENT && n.name_id != 0)
    {
        if (!is_lhs_of(parent, n))
        {
            du_record_use(du, n, n.name_id, bid, in_loop, in_nested);
        }
    }
    bool next_loop = in_loop;
    bool next_nested = in_nested;
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP)
    {
        next_loop = true;
    }
    if (n.kind == Nk.N_EXPR_LAMBDA)
    {
        next_nested = true;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        du_walk_expr(du, n.children[i], n, bid, next_loop, next_nested, lvl + 1);
    }
}

fn void du_scan_block(DefUse* du, Block* b, usz bid)
{
    if (b == null) { return; }
    bool in_loop = b.loop_depth > 0;
    for (usz si = 0; si < b.stmt_count; si++)
    {
        Node* s = b.stmts[si];
        if (s == null) { continue; }
        // let decl: children may contain N_PAT_IDENT patterns
        if (s.kind == Nk.N_DECL_LET)
        {
            for (usz k = 0; k < s.child_count; k++)
            {
                Node* c = s.children[k];
                if (c == null) { continue; }
                if (c.kind == Nk.N_PAT_IDENT && c.name_id != 0)
                {
                    du_add_def(du, c, c.name_id, bid, si);
                }
                else if (c.kind == Nk.N_PAT_TUPLE || c.kind == Nk.N_PAT_STRUCT)
                {
                    // Walk nested patterns for idents
                    for (usz j = 0; j < c.child_count; j++)
                    {
                        Node* cc = c.children[j];
                        if (cc != null && cc.kind == Nk.N_PAT_IDENT && cc.name_id != 0)
                        {
                            du_add_def(du, cc, cc.name_id, bid, si);
                        }
                    }
                }
                else
                {
                    du_walk_expr(du, c, s, bid, in_loop, false, 0);
                }
            }
            continue;
        }
        // Assignment: LHS is def, RHS uses
        if (s.kind == Nk.N_STMT_ASSIGN && s.child_count >= 2)
        {
            Node* lhs = s.children[0];
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && lhs.name_id != 0)
            {
                du_add_def(du, lhs, lhs.name_id, bid, si);
            }
            du_walk_expr(du, s.children[1], s, bid, in_loop, false, 0);
            continue;
        }
        du_walk_expr(du, s, null, bid, in_loop, false, 0);
    }
    if (b.term_node != null)
    {
        du_walk_expr(du, b.term_node, null, bid, in_loop, false, 0);
    }
}

fn void du_finalize(DefUse* du)
{
    for (usz i = 0; i < du.entry_count; i++)
    {
        DuEntry* e = &du.entries[i];
        if (!e.ever_used && !e.killed) { du.n_dead_stores = du.n_dead_stores + 1; }
        if (e.use_count == 1) { du.n_used_once = du.n_used_once + 1; }
        if (e.use_count > 1) { du.n_used_many = du.n_used_many + 1; if (e.block_id != (usz)-1) {} }
    }
}

fn void DefUse.run_on_cfg(DefUse* du, Cfg* cfg)
{
    if (cfg == null) { return; }
    du.cfg = cfg;
    for (usz i = 0; i < cfg.block_count; i++)
    {
        du_scan_block(du, &cfg.blocks[i], i);
    }
    du_finalize(du);
}

fn void DefUse.report(DefUse* du)
{
    printf("  def-use          : %d defs, %d uses (blocks scanned)\n",
           (int)du.total_defs, (int)du.total_uses);
    printf("  def-use-usage    : dead=%d once=%d many=%d multi=%d\n",
           (int)du.n_dead_stores, (int)du.n_used_once, (int)du.n_used_many, (int)du.n_multi_def);
    printf("  def-use-context  : nested=%d in-loop=%d\n",
           (int)du.n_nested_uses, (int)du.n_loop_uses);
}

fn void DefUse.free(DefUse* du)
{
    if (du.entries != null) { free((void*)du.entries); du.entries = null; }
}
