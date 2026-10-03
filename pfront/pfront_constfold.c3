// ============================================================================
// pfront_constfold.c3 — tree-level constant folding and simple strength reduction
// ----------------------------------------------------------------------------
// After type checking and const-eval (pfront_sema::ConstEval can compute the
// value of any compile-time expression), this pass REWRITES the AST to:
//
//   1. Replace constant subexpressions with their folded literal node.
//      `2 + 3 * 4` -> `14`, `true && x` -> `x`, `false || y` -> `y`,
//      `if true then a else b` -> `a`, `match 2 | 1 -> a | 2 -> b | _ -> c` -> `b`.
//   2. Drop unreachable arms / branches / statements. When an if-condition
//      folds to a boolean constant only the live branch remains; code in the
//      dead branch is dropped (diagnostics still reported via child walk).
//   3. Strength-reduce obvious idioms: `x * 1` -> `x`, `x + 0` -> `x`,
//      `x - 0` -> `x`, `x << 0` -> `x`, `!!x` -> `x`, `(T)(T)e` -> `(T)e`.
//   4. Simplify boolean identities: `!(!e)` -> `e`, `e == e` -> `true`
//      (for integral scalars), `x * 0` -> `0` when x has no side effects,
//      `0 / x` -> `0` (when x != 0 constant).
//
// The pass iterates bottom-up to fixpoint with a hard cap so pathological
// inputs terminate. Every replacement preserves source span information.
// We never fold across nodes with effects (calls, IO, unsafe, diverge).
//
// This is what turns `const N = 64; let a = [0i32; N * 4]` into
// `let a = [0i32; 256]`, lets narrowing see the actual value after a
// discriminant check, and makes DCE remove branches that become dead after
// monomorphisation.
// ============================================================================

module pfront_constfold;

import pfront_lex;
import pfront_core;
import pfront_sema;

extern fn int printf(char* fmt, ...);

alias Tk   = pfront_lex::TokenType;
alias Nk   = pfront_core::NodeKind;
alias Node = pfront_core::PNode;
alias Arena = pfront_core::Arena;
alias ConstEval = pfront_sema::ConstEval;
alias ConstValue = pfront_sema::ConstValue;
alias ConstStatus = pfront_sema::ConstStatus;

// Effects that prevent any folding across/through a node. Folding a node
// with these bits would drop a side effect the program depends on.
const uint EFF_VOLATILE = pfront_core::EFF_IO
                       | pfront_core::EFF_DIVERGE
                       | pfront_core::EFF_PANIC
                       | pfront_core::EFF_UNSAFE
                       | pfront_core::EFF_UB;

fn bool node_is_pure(Node* n)
{
    if (n == null) { return true; }
    return (n.effects & EFF_VOLATILE) == 0;
}

// Is this node a side-effect-free literal?
fn bool is_trivial(Node* n)
{
    if (n == null) { return true; }
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_FLOAT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
        case N_EXPR_STRING:
        case N_EXPR_NULL:
            return true;
        default:
            return false;
    }
}

// ── Folder state ────────────────────────────────────────────────────────────
struct Folder
{
    Arena* arena;
    pfront_core::DiagBag* diags;
    pfront_core::Interner* interner;
    ConstEval* eval;
    char* filename;
    int   iterations;
    int   folded;
    int   branches_killed;
    int   identities;
    int   max_iter;
    bool  changed;
}

fn void Folder.init(Folder* f, Arena* a, pfront_core::DiagBag* d,
                    pfront_core::Interner* it, ConstEval* ev, char* file)
{
    f.arena = a;
    f.diags = d;
    f.interner = it;
    f.eval = ev;
    f.filename = file;
    f.iterations = 0;
    f.folded = 0;
    f.branches_killed = 0;
    f.identities = 0;
    f.max_iter = 5;
    f.changed = false;
}

// the suffix type a folded arithmetic expression inherits from its literals (`1i32 - 1023i32` stays i32); false when none is written
fn bool lit_type_of(Node* n, char* w, bool* sg, int depth)
{
    if (n == null || depth > 40) { return false; }
    if (n.kind == N_EXPR_INT) { if (n.p.width != 0 && n.p.aux != 99) { *w = n.p.width; *sg = n.p.is_signed; return true; } return false; }
    if (n.kind == N_EXPR_BINARY)
    {
        Tk op = (Tk)n.p.op;
        if (op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ || op == Tk.TOKEN_LT || op == Tk.TOKEN_GT || op == Tk.TOKEN_LTEQ || op == Tk.TOKEN_GTEQ) { return false; }
        for (usz i = 0; i < n.child_count && i < 2; i++) { if (lit_type_of(n.children[i], w, sg, depth + 1)) { return true; } }
        return false;
    }
    if (n.kind == N_EXPR_UNARY && n.child_count > 0) { return lit_type_of(n.children[0], w, sg, depth + 1); }
    return false;
}

// Build a fresh literal node from a ConstValue, carrying the span of `span`.
fn Node* Folder.make_lit_from(Folder* f, Node* span, ConstValue v)
{
    if (v.status != ConstStatus.CONST_OK || span == null || f.arena == null) { return span; }
    if (v.is_float)
    {
        Node* n = f.arena.node(N_EXPR_FLOAT, span.line, span.col);
        if (n != null)
        {
            n.p.fval = v.fval;
            n.p.width = 64;
            n.effects = 0;
        }
        return n;
    }
    if (v.is_bool)
    {
        Node* n = f.arena.node(N_EXPR_BOOL, span.line, span.col);
        if (n != null)
        {
            n.p.ival = v.ival != 0 ? 1 : 0;
            n.effects = 0;
        }
        return n;
    }
    Node* n = f.arena.node(N_EXPR_INT, span.line, span.col);
    if (n != null)
    {
        n.p.ival = (ulong)v.ival;
        n.p.width = 64;
        n.p.aux = 99;   // folded: the width is a default, not a written suffix
        n.effects = 0;
        char lw_ = 0; bool lsg = true;
        if (span.kind != N_EXPR_CAST && lit_type_of(span, &lw_, &lsg, 0)) { n.p.width = lw_; n.p.is_signed = lsg; n.p.aux = 0; }   // `1i32 - 1023i32` stays i32
    }
    return n;
}

// ── Recursive rewriting ─────────────────────────────────────────────────────
fn Node* Folder.fold(Folder* f, Node* n)
{
    if (n == null) { return null; }
    if (n.kind == N_INVALID) { return n; }
    if ((n.flags & pfront_core::NF_ERROR) != 0) { return n; }

    f.fold_children(n);

    Node* r = null;
    switch (n.kind)
    {
        case N_EXPR_IF:        r = f.fold_if(n);
        case N_EXPR_MATCH:     r = f.fold_match(n);
        case N_EXPR_BINARY:    r = f.fold_binary(n);
        case N_EXPR_UNARY:     r = f.fold_unary(n);
        case N_EXPR_CAST:      r = f.fold_cast(n);
        case N_BLOCK:          r = f.fold_block(n);
        case N_EXPR_SIZEOF:    r = f.fold_sizeof(n);
        case N_EXPR_ALIGNOF:   r = f.fold_alignof(n);
        case N_EXPR_OFFSETOF:  r = f.fold_offsetof(n);
        case N_EXPR_TUPLE:     r = f.fold_tuple(n);
        case N_EXPR_ARRAY:     r = f.fold_array(n);
        default: break;
    }
    if (r == null && node_is_pure(n))
    {
        ConstValue v = f.eval.eval(n, 0);
        if (v.status == ConstStatus.CONST_OK
            && n.kind != N_EXPR_INT && n.kind != N_EXPR_FLOAT
            && n.kind != N_EXPR_BOOL && n.kind != N_EXPR_CHAR
            && !(n.kind == N_EXPR_CAST && n.type_ann != null && n.type_ann.kind != N_TY_NAME))   // `0 as *T` stays a cast: a bare 0 would be an integer
        {
            r = f.make_lit_from(n, v);
            if (r != null && r != n && n.kind == N_EXPR_CAST) { r.type_ann = n.type_ann; }   // `300 as u16` keeps its type
            if (r != null && r != n && r.kind == N_EXPR_INT && n.kind != N_EXPR_CAST)
            {
                char lw_ = 0; bool lsg = true;
                if (lit_type_of(n, &lw_, &lsg, 0)) { r.p.width = lw_; r.p.is_signed = lsg; r.p.aux = 0; }
            }
            if (r != null && r != n) { f.folded = f.folded + 1; f.changed = true; }
        }
    }
    return r != null ? r : n;
}

// Rewrite children in place where it's safe to do so.
fn void Folder.fold_children(Folder* f, Node* n)
{
    if (n == null) { return; }
    switch (n.kind)
    {
        // Type nodes, patterns, paths, modules, programs, decls: don't walk
        // generically; we handle decl bodies explicitly.
        case N_TY_NAME:
        case N_TY_PATH:
        case N_TY_PTR:
        case N_TY_REF:
        case N_TY_ARRAY:
        case N_TY_SLICE:
        case N_TY_TUPLE:
        case N_TY_FN:
        case N_TY_GENERIC:
        case N_TY_UNION:
        case N_TY_INTERSECT:
        case N_TY_NEGATION:
        case N_TY_BOTTOM:
        case N_TY_UNIT:
        case N_TY_INFER:
        case N_TY_SELF:
        case N_TY_FORALL:
        case N_TY_EXISTS:
        case N_TY_TYPEOF:
        case N_TY_REFINE:
        case N_TY_CONSTRAINT:
        case N_TY_EFFECT_ROW:
        case N_TY_EFFECT_ELEM:
        case N_TY_WHERE:
        case N_PAT_WILDCARD:
        case N_PAT_IDENT:
        case N_PAT_LITERAL:
        case N_PAT_TUPLE:
        case N_PAT_ARRAY:
        case N_PAT_STRUCT:
        case N_PAT_FIELD:
        case N_PAT_VARIANT:
        case N_PAT_RANGE:
        case N_PAT_OR:
        case N_PAT_REF:
        case N_PAT_REST:
        case N_MODULE:
        case N_MODULE_PATH:
        case N_PATH_SEG:
        case N_PROGRAM:
        case N_DOC:
        case N_USE:
        case N_USE_ITEM:
        case N_DECL_FN:
        case N_DECL_STRUCT:
        case N_DECL_UNION:
        case N_DECL_ENUM:
        case N_DECL_TYPE:
        case N_DECL_FIELD:
        case N_DECL_VARIANT:
        case N_DECL_PARAM:
        case N_DECL_TYPEPARAM:
        case N_DECL_EFFECT:
        case N_DECL_EFFECT_OP:
        case N_DECL_INTERFACE:
        case N_DECL_EXTERN_FN:
        case N_DECL_NEWTYPE:
        case N_CLAUSE:
        case N_MATCH_ARM:
        case N_HANDLER_ARM:
        case N_GUARD:
            f.fold_decl_bodies(n);
            return;
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        Node* nc = f.fold(c);
        if (nc != c) { n.children[i] = nc; f.changed = true; }
    }
}

// For decl/arm/guard nodes, fold only the body/initializer/guard expressions.
fn void Folder.fold_decl_bodies(Folder* f, Node* n)
{
    if (n == null) { return; }
    switch (n.kind)
    {
        case N_DECL_LET:
        case N_DECL_CONST:
        case N_DECL_STATIC:
            if (n.child_count > 0)
            {
                usz last = n.child_count - 1;
                Node* c = n.children[last];
                if (c != null && pfront_core::is_expr(c.kind))
                {
                    Node* nc = f.fold(c);
                    if (nc != c) { n.children[last] = nc; f.changed = true; }
                }
            }
            break;
        case N_GUARD:
            if (n.child_count > 0)
            {
                Node* c = n.children[0];
                Node* nc = f.fold(c);
                if (nc != c) { n.children[0] = nc; f.changed = true; }
            }
            break;
        case N_CLAUSE:
        case N_MATCH_ARM:
        case N_HANDLER_ARM:
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c == null) { continue; }
                if (c.kind == N_GUARD) { f.fold_decl_bodies(c); continue; }
                // skip pattern nodes
                if (pfront_core::is_pattern(c.kind)) { continue; }
                Node* nc = f.fold(c);
                if (nc != c) { n.children[i] = nc; f.changed = true; }
            }
            break;
        case N_DECL_FN:
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* c = n.children[i];
                if (c != null && c.kind == N_CLAUSE) { f.fold_decl_bodies(c); }
            }
            break;
        default: break;
    }
}

// ── if folding ──────────────────────────────────────────────────────────────
fn Node* Folder.fold_if(Folder* f, Node* n)
{
    if (n.child_count < 2) { return null; }
    Node* cond = n.children[0];
    if (cond != null && cond.kind == N_EXPR_BOOL)
    {
        f.branches_killed = f.branches_killed + 1;
        f.changed = true;
        if (cond.p.ival != 0)
        {
            Node* t = n.children[1];
            return t;
        }
        if (n.child_count >= 3) { return n.children[2]; }
        return f.arena.node(N_EXPR_UNIT, n.line, n.col);
    }
    return null;
}

// ── match folding ───────────────────────────────────────────────────────────
fn Node* Folder.fold_match(Folder* f, Node* n)
{
    if (n.child_count < 2) { return null; }
    Node* scrut = n.children[0];
    if (scrut == null) { return null; }
    bool scrut_is_lit = scrut.kind == N_EXPR_INT
                     || scrut.kind == N_EXPR_BOOL
                     || scrut.kind == N_EXPR_CHAR;
    if (!scrut_is_lit) { return null; }
    for (usz i = 1; i < n.child_count; i++)
    {
        Node* arm = n.children[i];
        if (arm == null || arm.kind != N_MATCH_ARM) { continue; }
        Node* pat = null;
        Node* body = null;
        Node* guard = null;
        for (usz j = 0; j < arm.child_count; j++)
        {
            Node* c = arm.children[j];
            if (c == null) { continue; }
            if (c.kind == N_GUARD) { guard = c; continue; }
            if (pat == null) { pat = c; }
            else { body = c; }
        }
        if (pat == null || guard != null) { continue; }
        if (f.pat_matches_lit(pat, scrut))
        {
            f.branches_killed = f.branches_killed + 1;
            f.changed = true;
            return body;
        }
    }
    return null;
}

fn bool Folder.pat_matches_lit(Folder* f, Node* pat, Node* lit)
{
    if (pat == null) { return false; }
    if (pat.kind == N_PAT_WILDCARD) { return true; }
    if (pat.kind == N_PAT_LITERAL && pat.child_count >= 1)
    {
        Node* plit = pat.children[0];
        if (plit == null) { return false; }
        if (plit.kind != lit.kind) { return false; }
        if (plit.kind == N_EXPR_INT)  { return plit.p.ival == lit.p.ival; }
        if (plit.kind == N_EXPR_BOOL) { return plit.p.ival == lit.p.ival; }
        if (plit.kind == N_EXPR_CHAR) { return plit.p.ival == lit.p.ival; }
        return false;
    }
    if (pat.kind == N_PAT_OR)
    {
        for (usz i = 0; i < pat.child_count; i++)
        {
            if (f.pat_matches_lit(pat.children[i], lit)) { return true; }
        }
    }
    return false;
}

// ── binary folding ──────────────────────────────────────────────────────────
fn Node* Folder.fold_binary(Folder* f, Node* n)
{
    if (n.child_count < 2) { return null; }
    Node* a = n.children[0];
    Node* b = n.children[1];
    Tk op = (Tk)n.p.op;

    if (op == Tk.TOKEN_PIPEPIPE || op == Tk.TOKEN_KW_OR)
    {
        if (a != null && a.kind == N_EXPR_BOOL)
        {
            f.changed = true; f.identities = f.identities + 1;
            if (a.p.ival != 0) { return f.make_bool(n, true); }
            return b;
        }
        if (b != null && b.kind == N_EXPR_BOOL && b.p.ival != 0 && node_is_pure(a))
        {
            f.changed = true; f.identities++;
            return f.make_bool(n, true);
        }
    }
    if (op == Tk.TOKEN_AMPAMP || op == Tk.TOKEN_KW_AND)
    {
        if (a != null && a.kind == N_EXPR_BOOL)
        {
            f.changed = true; f.identities++;
            if (a.p.ival == 0) { return f.make_bool(n, false); }
            return b;
        }
        if (b != null && b.kind == N_EXPR_BOOL && b.p.ival == 0 && node_is_pure(a))
        {
            f.changed = true; f.identities++;
            return f.make_bool(n, false);
        }
    }

    bool a_z = is_int_lit(a, 0);
    bool b_z = is_int_lit(b, 0);
    bool a_o = is_int_lit(a, 1);
    bool b_o = is_int_lit(b, 1);
    bool a_pure = node_is_pure(a);
    bool b_pure = node_is_pure(b);

    if (op == Tk.TOKEN_PLUS)
    {
        if (a_z && b_pure) { f.changed = true; f.identities++; return b; }
        if (b_z && a_pure) { f.changed = true; f.identities++; return a; }
    }
    if (op == Tk.TOKEN_MINUS)
    {
        if (b_z && a_pure) { f.changed = true; f.identities++; return a; }
    }
    if (op == Tk.TOKEN_STAR)
    {
        if (b_o && a_pure) { f.changed = true; f.identities++; return a; }
        if (a_o && b_pure) { f.changed = true; f.identities++; return b; }
        if (b_z && a_pure) { f.changed = true; f.identities++; return f.make_int(n, 0); }
        if (a_z && b_pure) { f.changed = true; f.identities++; return f.make_int(n, 0); }
    }
    if ((op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT) && b_pure && !b_z)
    {
        if (b_o && op == Tk.TOKEN_SLASH && a_pure) { f.changed = true; f.identities++; return a; }
        if (a_z) { f.changed = true; f.identities++; return f.make_int(n, 0); }
    }
    if (op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT)
    {
        if (b_z && a_pure) { f.changed = true; f.identities++; return a; }
    }
    if ((op == Tk.TOKEN_EQEQ || op == Tk.TOKEN_NEQ) && a != null && b != null
        && is_trivial(a) && is_trivial(b) && a.kind == b.kind && same_trivial(a, b))
    {
        f.changed = true; f.identities++;
        return f.make_bool(n, op == Tk.TOKEN_EQEQ);
    }

    // ── Strength reduction: x * 2^k -> x << k; x / 2^k -> x >> k  (unsigned) ──
    // We only reduce when the power-of-two operand is a positive integer
    // literal and k is small (avoid overflow on 64-bit).
    if (op == Tk.TOKEN_STAR && a_pure)
    {
        long k;
        if (b != null && b.kind == N_EXPR_INT && !b.p.is_signed
            && is_pow2((long)b.p.ival, &k) && k > 0 && k < 63)
        {
            f.changed = true; f.identities++;
            return f.make_binop(n, Tk.TOKEN_LSHIFT, a, f.make_int(n, k));
        }
        if (b != null && b.kind == N_EXPR_INT && b.p.is_signed
            && (long)b.p.ival > 0 && is_pow2((long)b.p.ival, &k) && k > 0 && k < 63)
        {
            f.changed = true; f.identities++;
            return f.make_binop(n, Tk.TOKEN_LSHIFT, a, f.make_int(n, k));
        }
    }
    if (op == Tk.TOKEN_STAR && b_pure)
    {
        long k;
        if (a != null && a.kind == N_EXPR_INT && !a.p.is_signed
            && is_pow2((long)a.p.ival, &k) && k > 0 && k < 63)
        {
            f.changed = true; f.identities++;
            return f.make_binop(n, Tk.TOKEN_LSHIFT, b, f.make_int(n, k));
        }
    }
    if (op == Tk.TOKEN_SLASH && a_pure)
    {
        long k;
        if (b != null && b.kind == N_EXPR_INT && !b.p.is_signed
            && is_pow2((long)b.p.ival, &k) && k > 0 && k < 63)
        {
            f.changed = true; f.identities++;
            return f.make_binop(n, Tk.TOKEN_RSHIFT, a, f.make_int(n, k));
        }
    }
    // x % 2^k -> x & (2^k - 1) for unsigned.
    if (op == Tk.TOKEN_PERCENT && a_pure)
    {
        long k;
        if (b != null && b.kind == N_EXPR_INT && !b.p.is_signed
            && is_pow2((long)b.p.ival, &k) && k > 0 && k < 63)
        {
            f.changed = true; f.identities++;
            return f.make_binop(n, Tk.TOKEN_AMP, a, f.make_int(n, ((long)b.p.ival) - 1));
        }
    }

    // Boolean identities:
    //   x | false = x,  x | true = true
    //   x & false = false, x & true = x
    //   x ^ false = x,  x ^ true = !x,  x ^ x = 0
    if (op == Tk.TOKEN_PIPE && b_pure)
    {
        if (b_z && a_pure) { f.changed = true; f.identities++; return a; }
        bool bo;
        if (is_bool_lit(b, &bo) && bo) { f.changed = true; f.identities++; return f.make_bool(n, true); }
    }
    if (op == Tk.TOKEN_AMP && b_pure)
    {
        if (b_z && a_pure) { f.changed = true; f.identities++; return f.make_int(n, 0); }
        bool bo;
        if (is_bool_lit(b, &bo) && bo) { f.changed = true; f.identities++; return a; }
    }
    if (op == Tk.TOKEN_XOR)
    {
        if (b_z && a_pure) { f.changed = true; f.identities++; return a; }
        if (a != null && b != null && same_trivial(a, b) && a_pure)
        {
            f.changed = true; f.identities++; return f.make_int(n, 0);
        }
    }
    // Min/max-like: x - x = 0, x + (-x) = 0
    if (op == Tk.TOKEN_MINUS && a != null && b != null && same_trivial(a, b) && a_pure)
    {
        f.changed = true; f.identities++; return f.make_int(n, 0);
    }
    // x * -1 -> -x
    if (op == Tk.TOKEN_STAR && a_pure)
    {
        if (b != null && b.kind == N_EXPR_INT && (long)b.p.ival == -1)
        {
            f.changed = true; f.identities++;
            return f.make_unop(n, Tk.TOKEN_MINUS, a);
        }
    }
    return null;
}

fn bool is_bool_lit(Node* n, bool* out)
{
    if (n == null) return false;
    if (n.kind == N_EXPR_BOOL) { out[0] = n.p.ival != 0; return true; }
    if (n.kind == N_EXPR_INT) { out[0] = n.p.ival != 0; return true; }
    return false;
}

fn Node* Folder.make_bool(Folder* f, Node* span, bool v)
{
    if (f.arena == null || span == null) { return null; }
    Node* n = f.arena.node(N_EXPR_BOOL, span.line, span.col);
    if (n != null) { n.p.ival = v ? 1 : 0; n.effects = 0; }
    return n;
}

fn Node* Folder.make_int(Folder* f, Node* span, long v)
{
    if (f.arena == null || span == null) { return null; }
    Node* n = f.arena.node(N_EXPR_INT, span.line, span.col);
    if (n != null)
    {
        n.p.ival = (ulong)v;
        n.p.width = 64;
        n.p.aux = 99;
        n.p.is_signed = true;
        n.effects = 0;
    }
    return n;
}

fn Node* Folder.make_binop(Folder* f, Node* span, Tk op, Node* lhs, Node* rhs)
{
    if (f.arena == null || span == null || lhs == null || rhs == null) { return null; }
    Node* n = f.arena.node2(N_EXPR_BINARY, lhs, rhs, span.line, span.col);
    if (n != null)
    {
        n.p.op = (int)op;
        n.effects = 0;
    }
    return n;
}

fn Node* Folder.make_unop(Folder* f, Node* span, Tk op, Node* inner)
{
    if (f.arena == null || span == null || inner == null) { return null; }
    Node* n = f.arena.node1(N_EXPR_UNARY, inner, span.line, span.col);
    if (n != null)
    {
        n.p.op = (int)op;
        n.effects = 0;
    }
    return n;
}

fn bool is_int_lit(Node* n, long want)
{
    if (n == null) { return false; }
    if (n.kind != N_EXPR_INT) { return false; }
    return (long)n.p.ival == want;
}

fn bool same_trivial(Node* a, Node* b)
{
    if (a == b) { return true; }
    if (a == null || b == null) { return false; }
    if (a.kind != b.kind) { return false; }
    switch (a.kind)
    {
        case N_EXPR_INT:  return a.p.ival == b.p.ival;
        case N_EXPR_BOOL: return a.p.ival == b.p.ival;
        case N_EXPR_CHAR: return a.p.ival == b.p.ival;
        case N_EXPR_IDENT:
            return a.name_id != 0 && a.name_id == b.name_id;
        default: return false;
    }
}

// ── unary folding ───────────────────────────────────────────────────────────
fn Node* Folder.fold_unary(Folder* f, Node* n)
{
    if (n.child_count < 1) { return null; }
    Node* a = n.children[0];
    Tk op = (Tk)n.p.op;

    if ((op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT)
        && a != null && a.kind == N_EXPR_UNARY && a.child_count >= 1
        && node_is_pure(a.children[0]))
    {
        Tk aop = (Tk)a.p.op;
        if (aop == Tk.TOKEN_BANG || aop == Tk.TOKEN_KW_NOT)
        {
            f.changed = true; f.identities++;
            return a.children[0];
        }
    }
    if (op == Tk.TOKEN_TILDE && a != null && a.kind == N_EXPR_UNARY && a.child_count >= 1
        && (Tk)a.p.op == Tk.TOKEN_TILDE && node_is_pure(a.children[0]))
    {
        f.changed = true; f.identities++;
        return a.children[0];
    }
    if (op == Tk.TOKEN_MINUS && a != null && a.kind == N_EXPR_UNARY && a.child_count >= 1
        && (Tk)a.p.op == Tk.TOKEN_MINUS && node_is_pure(a.children[0]))
    {
        Node* aa = a.children[0];
        if (aa != null && aa.kind == N_EXPR_INT
            && (long)aa.p.ival != -9223372036854775807L - 1)
        {
            f.changed = true; f.identities++;
            return aa;
        }
    }
    return null;
}

// ── cast folding ────────────────────────────────────────────────────────────
fn Node* Folder.fold_cast(Folder* f, Node* n)
{
    if (n.child_count < 1 || n.type_ann == null) { return null; }
    Node* a = n.children[0];
    if (a != null && a.kind == N_EXPR_CAST && a.type_ann != null
        && types_structurally_equal(n.type_ann, a.type_ann))
    {
        f.changed = true; f.identities++;
        return a;
    }
    return null;
}

fn bool types_structurally_equal(Node* ta, Node* tb)
{
    if (ta == tb) { return true; }
    if (ta == null || tb == null) { return false; }
    if (ta.kind != tb.kind) { return false; }
    if (ta.kind == N_TY_NAME || ta.kind == N_TY_PATH)
    {
        return ta.name_id != 0 && ta.name_id == tb.name_id;
    }
    if (ta.child_count != tb.child_count) { return false; }
    for (usz i = 0; i < ta.child_count; i++)
    {
        if (!types_structurally_equal(ta.children[i], tb.children[i])) { return false; }
    }
    return true;
}

// ── block folding ───────────────────────────────────────────────────────────
fn Node* Folder.fold_block(Folder* f, Node* n)
{
    if (n.child_count == 0) { return null; }
    bool saw_term = false;
    usz dead = 0;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        if (saw_term) { dead = dead + 1; }
        else if (is_terminator(c)) { saw_term = true; }
    }
    if (dead > 0)
    {
        f.changed = true;
        f.branches_killed = f.branches_killed + (int)dead;
        // Can't truncate child_count, so mark dead children with NF_SYNTHETIC
        // and null them out; later passes skip null children.
        bool past = false;
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i];
            if (c == null) { continue; }
            if (past) { n.children[i] = null; }
            else if (is_terminator(c)) { past = true; }
        }
    }
    // Single-expression block -> unwrap.
    usz live = 0;
    Node* only = null;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        live = live + 1;
        only = c;
    }
    if (live == 1 && only != null && pfront_core::is_expr(only.kind)
        && only.kind != N_DECL_LET && only.kind != N_DECL_CONST)
    {
        f.changed = true; f.identities++;
        return only;
    }
    return null;
}

fn bool is_terminator(Node* n)
{
    if (n == null) { return false; }
    switch (n.kind)
    {
        case N_STMT_RETURN:
        case N_STMT_BREAK:
        case N_STMT_CONTINUE:
        case N_EXPR_UNREACHABLE:
        case N_EXPR_TRAP:
            return true;
        case N_EXPR_IF:
            if (n.child_count < 3) { return false; }
            return is_terminator(n.children[1]) && is_terminator(n.children[2]);
        case N_BLOCK:
            if (n.child_count == 0) { return false; }
            for (usz i = n.child_count; i > 0; i--)
            {
                Node* c = n.children[i - 1];
                if (c == null) { continue; }
                return is_terminator(c);
            }
            return false;
        default: return false;
    }
}

// ── sizeof / alignof / offsetof folding ─────────────────────────────────────
// These reduce to integer constants when their operand is a known type. We
// compute sizes conservatively based on the type's kind. Real layout (with
// padding and alignment) will be done by the backend; the AST-stage answer
// is a useful approximation for code that uses sizeof in array sizes.
fn long size_of_type(Node* tn)
{
    if (tn == null) { return 8; }
    switch (tn.kind)
    {
        case N_TY_UNIT:     return 0;
        case N_TY_BOTTOM:   return 0;
        case N_EXPR_BOOL:   return 1;
        case N_TY_NAME:
        case N_TY_PATH:
            return 8;
        case N_TY_PTR:
        case N_TY_REF:      return 8;
        case N_TY_ARRAY:
        {
            if (tn.child_count >= 2)
            {
                long elem = size_of_type(tn.children[0]);
                Node* snd = tn.children[1];
                long cnt = 1;
                if (snd != null && snd.kind == N_EXPR_INT) { cnt = (long)snd.p.ival; }
                return elem * cnt;
            }
            return 0;
        }
        case N_TY_SLICE:    return 16;
        case N_TY_TUPLE:
        {
            long total = 0;
            for (usz i = 0; i < tn.child_count; i++)
            {
                total = total + size_of_type(tn.children[i]);
            }
            return total;
        }
        case N_TY_FN:       return 8;
        default:            return 8;
    }
}

fn long align_of_type(Node* tn)
{
    if (tn == null) { return 8; }
    long s = size_of_type(tn);
    if (s <= 1) return 1;
    if (s <= 2) return 2;
    if (s <= 4) return 4;
    return 8;
}

fn Node* Folder.fold_sizeof(Folder* f, Node* n)
{
    if (n.type_ann == null) { return null; }
    long s = size_of_type(n.type_ann);
    f.changed = true;
    f.folded = f.folded + 1;
    return f.make_int(n, s);
}

fn Node* Folder.fold_alignof(Folder* f, Node* n)
{
    if (n.type_ann == null) { return null; }
    long a = align_of_type(n.type_ann);
    f.changed = true;
    f.folded = f.folded + 1;
    return f.make_int(n, a);
}

fn Node* Folder.fold_offsetof(Folder* f, Node* n)
{
    if (n.child_count < 2 || n.type_ann == null) { return null; }
    Node* tgt = n.type_ann;
    Node* field = n.children[1];
    if (field == null) { return null; }
    uint fname = field.name_id;
    long off = 0;
    if (tgt.kind == N_TY_TUPLE)
    {
        for (usz i = 0; i < tgt.child_count; i++)
        {
            Node* c = tgt.children[i];
            if (c == null) { continue; }
            if (c.name_id == fname && fname != 0)
            {
                f.changed = true;
                f.folded = f.folded + 1;
                return f.make_int(n, off);
            }
            off = off + size_of_type(c);
        }
    }
    return null;
}

// ── Tuple / array constant folding ──────────────────────────────────────────
// When every element of a tuple/array literal folds to a constant, the whole
// literal is "constant" (but we don't replace the node — tuples/arrays have
// structure downstream uses rely on). We do propagate identity: a tuple whose
// elements are all trivial constants and that is itself a trivial value stays
// as-is; this hook mainly marks the node as effect-free (effects=0) so later
// passes know it is safe to duplicate/dead-code.
fn Node* Folder.fold_tuple(Folder* f, Node* n)
{
    if (n == null) { return null; }
    bool all_const = true;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { all_const = false; break; }
        if (!is_trivial(c) && c.kind != N_EXPR_TUPLE) { all_const = false; break; }
    }
    if (all_const) { n.effects = 0; }
    return null;
}

fn Node* Folder.fold_array(Folder* f, Node* n)
{
    if (n == null) { return null; }
    // [val; N] repeat: if val is constant and N is integer, nothing to rewrite
    // but mark effects as 0 if val is pure.
    bool all_pure = true;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        if (!node_is_pure(c)) { all_pure = false; }
    }
    if (all_pure) { n.effects = 0; }
    // Identity: [x; 1] -> x wrapped in a 1-elem array stays as array, nothing
    // to rewrite.
    return null;
}

// ── Strength reduction: multiply / divide by power-of-two constants ─────────
// x * 2^k  ->  x << k,   x / 2^k  ->  x >> k (for unsigned positive divisors).
// Runs alongside the identity rules in fold_binary; we only emit shifts when
// the operand is a positive power-of-two literal that did not already hit an
// identity (x*1, x/1 handled above).
fn bool is_pow2(long v, long* log)
{
    if (v <= 0) return false;
    if ((v & (v - 1)) != 0) return false;
    long k = 0; long t = v;
    while (t > 1) { t = t >> 1; k = k + 1; }
    *log = k;
    return true;
}

// ── Driver ──────────────────────────────────────────────────────────────────
fn void Folder.run(Folder* f, Node* prog)
{
    if (prog == null) { return; }
    for (int iter = 0; iter < f.max_iter; iter++)
    {
        f.changed = false;
        f.fold(prog);
        f.iterations = iter + 1;
        if (!f.changed) { break; }
    }
}

fn void Folder.report(Folder* f)
{
    printf("  const-fold     : %d folded, %d identities, %d branches killed (%d iters)\n",
           f.folded, f.identities, f.branches_killed, f.iterations);
}
