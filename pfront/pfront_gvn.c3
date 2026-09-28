// ============================================================================
// pfront_gvn.c3 — Global Value Numbering (dominator-scoped hash-based)
// ----------------------------------------------------------------------------
// Assigns every expression in a CFG a value number (VN). Two expressions with
// the same VN evaluate to the same value under dominator equivalence, which
// enables redundant-expression elimination, branch simplification, load/load
// forwarding, etc.
//
// This implementation is block-local with dominator inheritance: for each
// basic block (processed in RPO), we start a fresh table and BORROW entries
// from the immediate dominator. Lookups walk the idom chain (path compressed
// by a small per-block cache). To avoid the pathological O(N^2) cases that
// bit the earlier draft, tables use a fixed 4096-entry hash and cap lookups
// per entry at 8 probes.
//
// This is intentionally simple and fast; a full SCCP-style optimistic GVN
// with φ-functions is a later pass. For AST-level work this already finds a
// ton of duplicate expressions and repeated arithmetic inside basic blocks.
// ============================================================================

module pfront_gvn;

import pfront_lex;
import pfront_core;
import pfront_cfg;

alias Tk   = pfront_lex::TokenType;
alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias Cfg  = pfront_cfg::Cfg;
alias Block = pfront_cfg::Block;

extern fn void* malloc(usz size);
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

const usz   VN_MAX      = 32768;
const usz   TBL_CAP     = 4096;
const uint  VN_UNKNOWN  = 0;

struct VnEntry
{
    uint  hash;
    int   opcode;
    uint[4] args;
    usz   arg_count;
    uint  vn;
    Node* node;
}

// One table per basic block. We don't scope via chain pointers; instead when
// processing a block we copy its idom's entries into its own table once.
// That is O(N) total work and makes lookups O(1) single table.
struct VnTable
{
    VnEntry[TBL_CAP] tab;
    uint next_vn;
    bool init;
}

struct Gvn
{
    Arena* arena;
    Cfg*   cfg;
    VnTable* tables;          // [8193] heap-alloc'd (one per block id); c3c 0.8.4 rejects >64KB stack and >1GB static
    uint next_vn_global;
    usz  blocks_done;
    usz  redundant;
    usz  inserted;
}

fn void Gvn.init(Gvn* g, Arena* a)
{
    g.arena = a;
    g.cfg = null;
    g.next_vn_global = 1;
    g.tables = (VnTable*)a.alloc(VnTable::size * 8193, 8);
    g.blocks_done = 0;
    g.redundant = 0;
    g.inserted = 0;
    for (usz i = 0; i < 8193; i++) { g.tables[i].next_vn = 0; g.tables[i].init = false; }
}

fn void vnt_init(VnTable* t)
{
    for (usz i = 0; i < TBL_CAP; i++)
    {
        t.tab[i].hash = 0;
        t.tab[i].opcode = 0;
        t.tab[i].arg_count = 0;
        t.tab[i].vn = VN_UNKNOWN;
        t.tab[i].node = null;
        for (usz j = 0; j < 4; j++) { t.tab[i].args[j] = 0; }
    }
    t.next_vn = 0;
    t.init = true;
}

// Copy all entries from parent into child (once at child start).
fn void vnt_copy_from(VnTable* dst, VnTable* src)
{
    // Iterate source slots; for non-empty entries insert into dst.
    for (usz i = 0; i < TBL_CAP; i++)
    {
        VnEntry* se = &src.tab[i];
        if (se.vn == VN_UNKNOWN) { continue; }
        // Insert into dst with linear probing.
        usz idx = (usz)se.hash & (TBL_CAP - 1);
        for (usz p = 0; p < 16; p++)
        {
            usz k = (idx + p) & (TBL_CAP - 1);
            VnEntry* de = &dst.tab[k];
            if (de.vn == VN_UNKNOWN)
            {
                *de = *se;
                break;
            }
            // Same key? skip (dedup)
            if (de.hash == se.hash && de.opcode == se.opcode && de.arg_count == se.arg_count)
            {
                bool same = true;
                for (usz j = 0; j < se.arg_count && j < 4; j++)
                {
                    if (de.args[j] != se.args[j]) { same = false; break; }
                }
                if (same) break;
            }
        }
    }
}

fn uint vn_hash_mix(uint h, uint x)
{
    x = ((x >> 16) ^ x) * 0x45d9f3b;
    x = ((x >> 16) ^ x) * 0x45d9f3b;
    x = (x >> 16) ^ x;
    return h ^ x + (h << 6) + (h >> 2);
}

fn uint expr_hash(int opcode, uint* args, usz n)
{
    uint h = (uint)opcode * 2654435761u;
    for (usz i = 0; i < n && i < 4; i++) { h = vn_hash_mix(h, args[i]); }
    return h | 1u; // make sure hash never 0 (0 = empty)
}

fn bool is_commutative(int opcode, Tk tk)
{
    if (opcode != Nk.N_EXPR_BINARY.ordinal) { return false; }
    if (tk == Tk.TOKEN_PLUS) return true;
    if (tk == Tk.TOKEN_STAR) return true;
    if (tk == Tk.TOKEN_AMP) return true;
    if (tk == Tk.TOKEN_PIPE) return true;
    if (tk == Tk.TOKEN_XOR) return true;
    if (tk == Tk.TOKEN_EQEQ) return true;
    if (tk == Tk.TOKEN_NEQ) return true;
    if (tk == Tk.TOKEN_AMPAMP) return true;
    if (tk == Tk.TOKEN_PIPEPIPE) return true;
    return false;
}

// Lookup in a table: returns existing VN or VN_UNKNOWN.
fn uint vnt_lookup(VnTable* t, uint h, int opcode, uint* args, usz n, bool commute)
{
    usz idx = (usz)h & (TBL_CAP - 1);
    for (usz p = 0; p < 12; p++)
    {
        usz k = (idx + p) & (TBL_CAP - 1);
        VnEntry* e = &t.tab[k];
        if (e.vn == VN_UNKNOWN) { return VN_UNKNOWN; }
        if (e.hash != h || e.opcode != opcode || e.arg_count != n) { continue; }
        bool match = true;
        for (usz i = 0; i < n && i < 4; i++)
        {
            if (e.args[i] != args[i])
            {
                if (!commute || n != 2 || !(i == 0 ? e.args[1] == args[0] && e.args[0] == args[1] : false))
                { match = false; break; }
            }
        }
        if (commute && n == 2)
        {
            if ((e.args[0] == args[0] && e.args[1] == args[1]) ||
                (e.args[0] == args[1] && e.args[1] == args[0])) { return e.vn; }
            continue;
        }
        if (match) { return e.vn; }
    }
    return VN_UNKNOWN;
}

fn uint vnt_insert(Gvn* g, VnTable* t, uint h, int opcode, uint* args, usz n, Node* nnode)
{
    usz idx = (usz)h & (TBL_CAP - 1);
    for (usz p = 0; p < 16; p++)
    {
        usz k = (idx + p) & (TBL_CAP - 1);
        VnEntry* e = &t.tab[k];
        if (e.vn == VN_UNKNOWN)
        {
            e.hash = h;
            e.opcode = opcode;
            e.arg_count = n;
            for (usz i = 0; i < n && i < 4; i++) { e.args[i] = args[i]; }
            g.next_vn_global = g.next_vn_global + 1;
            e.vn = g.next_vn_global;
            e.node = nnode;
            g.inserted = g.inserted + 1;
            return e.vn;
        }
    }
    // Table saturated; allocate a one-off VN.
    g.next_vn_global = g.next_vn_global + 1;
    return g.next_vn_global;
}

// --- Node to VN ------------------------------------------------------------
fn uint Gvn.vn_node(Gvn* g, VnTable* t, Node* n)
{
    if (n == null || t == null) { return VN_UNKNOWN; }
    // Immediate leaf cases (don't recurse).
    if (n.kind == Nk.N_EXPR_INT)
    {
        long v = (long)n.p.ival;
        uint[2] args; args[0] = (uint)(v & 0xFFFFFFFF); args[1] = (uint)(((ulong)v >> 32) & 0xFFFFFFFF);
        uint h = expr_hash((n.kind.ordinal << 4) | 1, &args[0], 2);
        bool comm = false;
        uint existing = vnt_lookup(t, h, (n.kind.ordinal << 4) | 1, &args[0], 2, comm);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, (n.kind.ordinal << 4) | 1, &args[0], 2, n);
    }
    if (n.kind == Nk.N_EXPR_BOOL)
    {
        uint[1] args; args[0] = n.p.ival != 0 ? 1u : 0u;
        uint h = expr_hash((n.kind.ordinal << 4) | 1, &args[0], 1);
        uint existing = vnt_lookup(t, h, (n.kind.ordinal << 4) | 1, &args[0], 1, false);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, (n.kind.ordinal << 4) | 1, &args[0], 1, n);
    }
    if (n.kind == Nk.N_EXPR_CHAR)
    {
        uint[1] args; args[0] = (uint)n.p.ival;
        uint h = expr_hash((n.kind.ordinal << 4) | 1, &args[0], 1);
        uint existing = vnt_lookup(t, h, (n.kind.ordinal << 4) | 1, &args[0], 1, false);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, (n.kind.ordinal << 4) | 1, &args[0], 1, n);
    }
    if (n.kind == Nk.N_EXPR_FLOAT)
    {
        double fv = n.p.fval;
        long* lp = (long*)&fv;
        uint[2] args; args[0] = (uint)(*lp & 0xFFFFFFFF); args[1] = (uint)((*lp >> 32) & 0xFFFFFFFF);
        uint h = expr_hash((n.kind.ordinal << 4) | 1, &args[0], 2);
        uint existing = vnt_lookup(t, h, (n.kind.ordinal << 4) | 1, &args[0], 2, false);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, (n.kind.ordinal << 4) | 1, &args[0], 2, n);
    }
    if (n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH)
    {
        // Idents are "leaf" values with their name as key; but since values
        // change after stores, we give each ident occurrence a fresh VN.
        g.next_vn_global = g.next_vn_global + 1;
        return g.next_vn_global;
    }
    // Unary.
    if (n.kind == Nk.N_EXPR_UNARY && n.child_count >= 1)
    {
        uint cv = g.vn_node(t, n.children[0]);
        Tk tk = (Tk)n.p.op;
        int opcode = (n.kind.ordinal << 4) | ((int)tk.ordinal & 0xF);
        uint[1] args; args[0] = cv;
        uint h = expr_hash(opcode, &args[0], 1);
        uint existing = vnt_lookup(t, h, opcode, &args[0], 1, false);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, opcode, &args[0], 1, n);
    }
    // Binary.
    if (n.kind == Nk.N_EXPR_BINARY && n.child_count >= 2)
    {
        uint cv0 = g.vn_node(t, n.children[0]);
        uint cv1 = g.vn_node(t, n.children[1]);
        Tk tk = (Tk)n.p.op;
        int opcode = (n.kind.ordinal << 4) | ((int)tk.ordinal & 0xF);
        uint[2] args; args[0] = cv0; args[1] = cv1;
        bool comm = is_commutative(n.kind.ordinal, tk);
        // Canonicalise order for commutative ops (smaller VN first)
        if (comm && cv0 > cv1) { uint tmp = args[0]; args[0] = args[1]; args[1] = tmp; }
        uint h = expr_hash(opcode, &args[0], 2);
        uint existing = vnt_lookup(t, h, opcode, &args[0], 2, comm);
        if (existing != VN_UNKNOWN) { g.redundant = g.redundant + 1; return existing; }
        return vnt_insert(g, t, h, opcode, &args[0], 2, n);
    }
    // Calls / control flow / etc: pure VNs, no recursion across blocks.
    for (usz i = 0; i < n.child_count; i++) { g.vn_node(t, n.children[i]); }
    g.next_vn_global = g.next_vn_global + 1;
    return g.next_vn_global;
}

fn void Gvn.run_on_cfg(Gvn* g, Cfg* c)
{
    g.cfg = c;
    // Build order by RPO ascending.
    int[8192] order;
    usz order_n = 0;
    for (usz i = 0; i < c.block_count && order_n < 8192; i++) { order[order_n++] = (int)i; }
    for (usz i = 1; i < order_n; i++)
    {
        int key = order[i];
        int krpo = c.blocks[key].rpo;
        long j = (long)i - 1;
        while (j >= 0 && c.blocks[order[j]].rpo > krpo) { order[j + 1] = order[j]; j = j - 1; }
        order[j + 1] = key;
    }
    for (usz i = 0; i < order_n; i++)
    {
        int bid = order[i];
        if (bid < 0 || bid >= (int)c.block_count) { continue; }
        Block* b = &c.blocks[bid];
        VnTable* t = &g.tables[bid];
        vnt_init(t);
        // Inherit from idom.
        if (b.idom >= 0 && b.idom != bid && (usz)b.idom < c.block_count && g.tables[b.idom].init)
        {
            vnt_copy_from(t, &g.tables[b.idom]);
        }
        g.blocks_done = g.blocks_done + 1;
        for (usz si = 0; si < b.stmt_count; si++) { g.vn_node(t, b.stmts[si]); }
        if (b.term_node != null) { g.vn_node(t, b.term_node); }
    }
}

fn void Gvn.report(Gvn* g)
{
    printf("  gvn blocks        : %d\n", (int)g.blocks_done);
    printf("  gvn vns assigned  : %d\n", (int)g.next_vn_global);
    printf("  gvn inserted      : %d\n", (int)g.inserted);
    printf("  gvn redundant     : %d\n", (int)g.redundant);
}
