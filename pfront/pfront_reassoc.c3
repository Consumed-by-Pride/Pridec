// ============================================================================
// pfront_reassoc.c3 — Expression reassociation and algebraic normalization
// ----------------------------------------------------------------------------
// Canonicalizes chains of associative operators (+, *, &, |, ^) so that
// equivalent expressions hash to the same value (for GVN/CSE), and pushes
// constants together for constant folding. The rules:
//
//   1. Constant operands are always the RIGHT operand:  (x + 3) + 5 -> x + 8.
//      Combined with constant folding in pfront_constfold this folds chains
//      of literal additions/multiplications into a single literal.
//   2. For commutative ops (+, *, &, |, ^), operands are sorted by a stable
//      ordering (constant < ident < compound, then by name_id/kind) so that
//      "a + b" and "b + a" become identical trees.
//   3. Nested associative ops are flattened: (a + b) + (c + d) -> +(a,b,c,d)
//      conceptually, exposing more factoring opportunities.
//
// This analysis is purely diagnostic: it counts how many expressions could
// be canonicalized but does not mutate the AST. Real rewriting happens in
// the tree-level folder.
// ============================================================================

module pfront_reassoc;

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
extern fn void  free(void* p);
extern fn int   printf(char* fmt, ...);

struct Reassoc
{
    Arena* arena;
    Cfg*   cfg;
    usz    n_flat;       // nested associative chains found
    usz    n_const_right;// constants moved to right side
    usz    n_commute;    // commutations applied for canonical order
    usz    n_identities; // identities already present (e.g. x+0)
    usz    total;
}

fn void Reassoc.init(Reassoc* r, Arena* a)
{
    r.arena = a;
    r.cfg = null;
    r.n_flat = 0;
    r.n_const_right = 0;
    r.n_commute = 0;
    r.n_identities = 0;
    r.total = 0;
}

fn bool is_assoc_comm(Tk op)
{
    if (op == Tk.TOKEN_PLUS)  return true;
    if (op == Tk.TOKEN_STAR)  return true;
    if (op == Tk.TOKEN_AMP)   return true;
    if (op == Tk.TOKEN_PIPE)  return true;
    if (op == Tk.TOKEN_XOR)   return true;
    if (op == Tk.TOKEN_AMPAMP) return true;
    if (op == Tk.TOKEN_PIPEPIPE) return true;
    return false;
}

fn bool is_assoc_nc(Tk op)
{
    if (op == Tk.TOKEN_MINUS) return true;
    if (op == Tk.TOKEN_SLASH) return true;
    if (op == Tk.TOKEN_LSHIFT) return true;
    if (op == Tk.TOKEN_RSHIFT) return true;
    return false;
}

fn bool node_is_const(Node* n)
{
    if (n == null) return false;
    if (n.kind == Nk.N_EXPR_INT) return true;
    if (n.kind == Nk.N_EXPR_BOOL) return true;
    if (n.kind == Nk.N_EXPR_CHAR) return true;
    if (n.kind == Nk.N_EXPR_FLOAT) return true;
    return false;
}

// Category ordering for canonical sort (lower number = comes first).
fn int node_cat(Node* n)
{
    if (n == null) return 99;
    if (node_is_const(n)) return 0;
    if (n.kind == Nk.N_EXPR_IDENT) return 1;
    return 2;
}

fn bool should_flatten(Node* child, Tk parent_op)
{
    if (child == null) return false;
    if (child.kind != Nk.N_EXPR_BINARY) return false;
    Tk cop = (Tk)child.p.op;
    return cop == parent_op && is_assoc_comm(parent_op);
}

fn void ra_walk(Reassoc* r, Node* n)
{
    if (n == null) return;
    for (usz i = 0; i < n.child_count; i++)
    {
        ra_walk(r, n.children[i]);
    }
    if (n.kind != Nk.N_EXPR_BINARY) return;
    if (n.child_count < 2) return;
    Tk op = (Tk)n.p.op;
    Node* a = n.children[0];
    Node* b = n.children[1];
    r.total = r.total + 1;
    bool ac = is_assoc_comm(op);
    // Flatten nested associative: (a+b)+c => a+b+c.
    if (ac)
    {
        if (should_flatten(a, op) || should_flatten(b, op))
        {
            r.n_flat = r.n_flat + 1;
        }
    }
    // Constant-to-right for associative or even non-assoc constant propagation.
    if (node_is_const(a) && !node_is_const(b))
    {
        if (ac) { r.n_const_right = r.n_const_right + 1; }
    }
    // Commute if not in canonical order for comm ops.
    if (ac)
    {
        int ca = node_cat(a); int cb = node_cat(b);
        bool needs = false;
        if (ca > cb) { needs = true; }
        else if (ca == cb && ca == 1 && a.kind == Nk.N_EXPR_IDENT && b.kind == Nk.N_EXPR_IDENT)
        {
            if (a.name_id > b.name_id) { needs = true; }
        }
        if (needs) { r.n_commute = r.n_commute + 1; }
    }
    // Identity detection: count how many are already in identity form.
    if (op == Tk.TOKEN_PLUS && node_is_const(b) && b.p.ival == 0) { r.n_identities++; }
    if (op == Tk.TOKEN_STAR && node_is_const(b) && b.p.ival == 1) { r.n_identities++; }
    if (op == Tk.TOKEN_AMP)
    {
        // All bits set ~0 is identity; conservatively not counted.
    }
    if (op == Tk.TOKEN_PIPE && node_is_const(b) && b.p.ival == 0) { r.n_identities++; }
    if (op == Tk.TOKEN_XOR && node_is_const(b) && b.p.ival == 0) { r.n_identities++; }
}

fn void Reassoc.run_on_cfg(Reassoc* r, Cfg* cfg)
{
    if (cfg == null) return;
    r.cfg = cfg;
    usz nb = cfg.block_count;
    for (usz bi = 0; bi < nb; bi++)
    {
        Block* b = &cfg.blocks[bi];
        for (usz si = 0; si < b.stmt_count; si++)
        {
            ra_walk(r, b.stmts[si]);
        }
        if (b.term_node != null) ra_walk(r, b.term_node);
    }
}

fn void Reassoc.report(Reassoc* r)
{
    printf("  reassoc bins     : %d (flatten %d, const->r %d, commute %d, ident %d)\n",
           (int)r.total, (int)r.n_flat, (int)r.n_const_right,
           (int)r.n_commute, (int)r.n_identities);
}
