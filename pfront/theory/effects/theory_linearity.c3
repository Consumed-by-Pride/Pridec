// ============================================================================
// theory_linearity.c3 — Linear/affine/relevant type tracking via multiplicity
// ----------------------------------------------------------------------------
// Linear logic (Girard 1987) classifies hypotheses by how many times they are
// USED: linear (must be used exactly once), affine (at most once), relevant
// (at least once), and unrestricted (any number of uses). Linear types are
// the foundation of Rust-style ownership, session types, and uniqueness.
//
// This module implements a multiplicity analysis that counts per-variable
// uses in a function:
//
//   • We traverse the AST, maintaining a USE COUNT per local variable.
//   • Variables introduced by `let` start at count 0.
//   • Each N_EXPR_IDENT referencing a local bumps its count.
//   • After traversal:
//       count == 0 → unused
//       count == 1 → affine/linear candidate
//       count > 1  → used multiple times (must be unrestricted)
//   • Linear-violating patterns: a linear variable moved twice, or a linear
//     variable never used.
//   • MOVE SEMANTICS: passing a variable to a function that "takes ownership"
//     (heuristic: function name starts with `take_`/`move_`/`free_`/`close_`)
//     counts as final use; any later use is a double-free / use-after-move.
//
// We don't reject programs, but we report linearity statistics: how many
// variables are affine candidates, how many unused, how many potentially-
// moved, and how many multi-use. This feeds the optimiser (e.g. in-place
// update eligibility) and the PGL pattern compiler (linearity of pattern
// variables).
//
// References:
//   Girard 1987 "Linear Logic"
//   Wadler 1990 "Linear types can change the world!"
//   Mazurak/Zhao/Weirich 2010 "Lightweight Linear Types in System F°"
//   Rust Reference: Ownership and moves
// ============================================================================

module theory_linearity;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz LIN_MAX_LOCALS = 8192;

struct UseCount
{
    uint name_id;
    int  uses;
    bool moved;
    bool in_scope;
    int  decl_line;
}

struct Scope
{
    UseCount* vars;
    usz       count;
    usz       cap;
}

struct LinAnalysis
{
    Arena* arena;
    UseCount* all;
    usz        all_count;
    usz        n_locals;
    usz        n_unused;
    usz        n_once;
    usz        n_multi;
    usz        n_moved;
    usz        n_double_use;
    usz        n_use_after_move;
    usz        n_affine_candidates;
    int        depth;
}

fn void lin_scope_init(Scope* s)
{
    s.cap = 64;
    s.vars = (UseCount*)calloc(s.cap, 32);
    s.count = 0;
}

fn void lin_scope_free(Scope* s)
{
    if (s.vars != null) { free((void*)s.vars); s.vars = null; }
}

fn void lin_scope_declare(Scope* s, uint name, int line)
{
    if (s.count >= s.cap) return;
    s.vars[s.count].name_id = name;
    s.vars[s.count].uses = 0;
    s.vars[s.count].moved = false;
    s.vars[s.count].in_scope = true;
    s.vars[s.count].decl_line = line;
    s.count = s.count + 1;
}

fn int lin_scope_lookup(Scope* s, uint name)
{
    for (long i = (long)s.count - 1; i >= 0; i = i - 1)
    {
        if (s.vars[i].name_id == name && s.vars[i].in_scope) return (int)i;
    }
    return -1;
}

fn void LinAnalysis.init(LinAnalysis* la, Arena* a)
{
    la.arena = a;
    la.all = (UseCount*)calloc(LIN_MAX_LOCALS, 32);
    la.all_count = 0;
    la.n_locals = 0; la.n_unused = 0; la.n_once = 0; la.n_multi = 0;
    la.n_moved = 0; la.n_double_use = 0; la.n_use_after_move = 0;
    la.n_affine_candidates = 0; la.depth = 0;
}

fn bool lin_is_move_fn(Node* call)
{
    if (call == null || call.child_count < 1 || call.children[0] == null) return false;
    Node* callee = call.children[0];
    char* s = callee.p.sptr;
    usz n = callee.p.slen;
    if (s == null || n < 5) return false;
    if (s[0] == 'f' && s[1] == 'r' && s[2] == 'e' && s[3] == 'e' && s[4] == '_') return true;
    if (s[0] == 'c' && s[1] == 'l' && s[2] == 'o' && s[3] == 's' && s[4] == 'e') return true;
    if (s[0] == 'd' && s[1] == 'r' && s[2] == 'o' && s[3] == 'p') return true;
    if (n >= 5 && s[0] == 'm' && s[1] == 'o' && s[2] == 'v' && s[3] == 'e' && s[4] == '_') return true;
    if (n >= 5 && s[0] == 't' && s[1] == 'a' && s[2] == 'k' && s[3] == 'e' && s[4] == '_') return true;
    return false;
}

fn void LinAnalysis.walk(LinAnalysis* la, Node* n, Scope* s, int depth)
{
    if (n == null || depth > 200) return;
    switch (n.kind)
    {
        case Nk.N_STMT_ASSIGN:
        {
            // Declare the LHS variable (children[0] is ident when it's a `let`)
            if (n.child_count >= 2)
            {
                Node* lhs = n.children[0];
                if (lhs != null && (lhs.kind == Nk.N_EXPR_IDENT || lhs.kind == Nk.N_PAT_IDENT))
                {
                    lin_scope_declare(s, lhs.name_id, lhs.line);
                    la.n_locals = la.n_locals + 1;
                }
                la.walk(n.children[1], s, depth + 1);
            }
            return;
        }
        case Nk.N_EXPR_IDENT:
        {
            int idx = lin_scope_lookup(s, n.name_id);
            if (idx >= 0)
            {
                if (s.vars[idx].moved) { la.n_use_after_move = la.n_use_after_move + 1; }
                s.vars[idx].uses = s.vars[idx].uses + 1;
            }
            return;
        }
        case Nk.N_EXPR_CALL:
        {
            // If calling a move function with first arg = ident, mark as moved.
            bool mv = lin_is_move_fn(n);
            for (usz i = 0; i < n.child_count; i++)
            {
                if (mv && i == 1 && n.children[i] != null && n.children[i].kind == Nk.N_EXPR_IDENT)
                {
                    int idx = lin_scope_lookup(s, n.children[i].name_id);
                    if (idx >= 0)
                    {
                        if (s.vars[idx].moved) la.n_double_use = la.n_double_use + 1;
                        s.vars[idx].moved = true; la.n_moved = la.n_moved + 1;
                        s.vars[idx].uses = s.vars[idx].uses + 1;
                    }
                    continue;
                }
                la.walk(n.children[i], s, depth + 1);
            }
            return;
        }
        case Nk.N_EXPR_LAMBDA:
        {
            la.walk_fn(n);
            return;
        }
        case Nk.N_BLOCK:
        {
            Scope inner; lin_scope_init(&inner);
            for (usz i = 0; i < n.child_count; i++) la.walk(n.children[i], &inner, depth + 1);
            // Roll up stats
            for (usz i = 0; i < inner.count; i++)
            {
                UseCount* u = &inner.vars[i];
                if (u.uses == 0) { la.n_unused = la.n_unused + 1; }
                else if (u.uses == 1) { la.n_once = la.n_once + 1; if (!u.moved) { la.n_affine_candidates = la.n_affine_candidates + 1; } }
                else { la.n_multi = la.n_multi + 1; if (u.moved) { la.n_double_use = la.n_double_use + 1; } }
            }
            lin_scope_free(&inner);
            return;
        }
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) la.walk(n.children[i], s, depth + 1);
}

fn void LinAnalysis.walk_fn(LinAnalysis* la, Node* fnode)
{
    Scope s; lin_scope_init(&s);
    // Lambda parameters: bind each param pattern ident.
    for (usz i = 0; i < fnode.child_count; i++)
    {
        Node* c = fnode.children[i];
        if (c == null) continue;
        if (c.kind == Nk.N_PAT_IDENT || c.kind == Nk.N_EXPR_IDENT)
        {
            lin_scope_declare(&s, c.name_id, c.line);
            la.n_locals = la.n_locals + 1;
        }
        la.walk(c, &s, 1);
    }
    for (usz i = 0; i < s.count; i++)
    {
        UseCount* u = &s.vars[i];
        if (u.uses == 0) { la.n_unused = la.n_unused + 1; }
        else if (u.uses == 1) { la.n_once = la.n_once + 1; if (!u.moved) { la.n_affine_candidates = la.n_affine_candidates + 1; } }
        else { la.n_multi = la.n_multi + 1; if (u.moved) { la.n_double_use = la.n_double_use + 1; } }
    }
    lin_scope_free(&s);
}

fn void LinAnalysis.run(LinAnalysis* la, Node* root)
{
    Scope s; lin_scope_init(&s);
    la.walk(root, &s, 0);
    for (usz i = 0; i < s.count; i++)
    {
        UseCount* u = &s.vars[i];
        if (u.uses == 0) { la.n_unused = la.n_unused + 1; }
        else if (u.uses == 1) { la.n_once = la.n_once + 1; if (!u.moved) { la.n_affine_candidates = la.n_affine_candidates + 1; } }
        else { la.n_multi = la.n_multi + 1; }
    }
    lin_scope_free(&s);
}

fn void LinAnalysis.report(LinAnalysis* la)
{
    printf("  linearity        : %d locals: unused=%d once=%d multi=%d, affine-candidates=%d\n",
           (int)la.n_locals, (int)la.n_unused, (int)la.n_once, (int)la.n_multi,
           (int)la.n_affine_candidates);
    printf("  linearity-move   : %d moves, %d double-use, %d use-after-move\n",
           (int)la.n_moved, (int)la.n_double_use, (int)la.n_use_after_move);
}

fn void LinAnalysis.destroy(LinAnalysis* la)
{
    if (la.all != null) { free((void*)la.all); la.all = null; }
}
