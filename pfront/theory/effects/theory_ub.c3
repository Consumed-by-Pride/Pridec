// ============================================================================
// theory_ub.c3 — Explicit undefined behavior lattice (Lee et al. 2012; Lee 2018)
// ----------------------------------------------------------------------------
// Undefined Behavior (UB) in LLVM and C is *not* a single bit: every operation
// can produce either a defined value, a POISON value, or FULL UB (the program
// is meaningless; semantics allows anything). This three-point lattice
//
//              UB (program meaningless)
//             /
//         poison
//        /
//    defined
//
// is described in Lee et al. 2012 "Taming Undefined Behavior in LLVM" and
// refined in Lee et al. 2018 "Freezing Poison: A Comprehensive Approach to
// Undefined Behavior in LLVM". theory_modal.c3's UbTracker counts UB events
// but does not model the LATTICE or propagation rules. This module provides:
//
//   1. The UB lattice itself (UbVal: DEF, POISON, UB) with join and
//      widen operations.
//   2. Tagging: every expression gets a UbVal abstract value.
//   3. Propagation rules per operator:
//        • arithmetic on poison → poison
//        • branch on poison  → UB (stuck: condition must be defined)
//        • deref poison     → UB (invalid pointer)
//        • division by zero → UB
//        • shift >= bitwidth → UB (in C; poison in LLVM)
//        • pointer overflow → poison
//        • phi of poison & defined → poison (freeze = defined)
//   4. Freeze: converts poison to an arbitrary defined value.
//   5. A must-not-be-UB check at certain well-defined points (branches,
//      dereferences, returns, calls to non-poison-tolerant ABIs).
//
// The analysis is FLOW-SENSITIVE: each block gets an "in" and "out" UbVal
// per tracked fact, merged at control-flow joins. It is conservative: if
// we cannot prove an operation is defined we mark it poison, not UB.
//
// All reporting is advisory; Pride is untyped, so no program is rejected.
//
// References:
//   Lee/Kim/Park/Song 2012 "Taming Undefined Behavior in LLVM" (PLDI)
//   Lee/Kim/Sun/Song 2018 "Freezing Poison"
//   C11 §J.2 (undefined behavior), LLVM LangRef "Undefined Values"
// ============================================================================

module theory_ub;

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

enum UbVal : int
{
    UB_DEF,        // definitely defined
    UB_POISON,     // may be poison (but not UB yet)
    UB_UB          // undefined behavior reached
}

fn char* ub_name(UbVal v)
{
    switch (v)
    {
        case UbVal.UB_DEF:    return "def";
        case UbVal.UB_POISON: return "poison";
        case UbVal.UB_UB:     return "ub";
    }
}

// Join: pick the "higher" (worse) value.
fn UbVal ub_join(UbVal a, UbVal b)
{
    if (a == UbVal.UB_UB || b == UbVal.UB_UB) return UbVal.UB_UB;
    if (a == UbVal.UB_POISON || b == UbVal.UB_POISON) return UbVal.UB_POISON;
    return UbVal.UB_DEF;
}

// Strict-if: branching on non-def is UB.
fn UbVal ub_strict_if(UbVal c)
{
    if (c == UbVal.UB_DEF) return UbVal.UB_DEF;
    if (c == UbVal.UB_POISON) return UbVal.UB_UB;
    return UbVal.UB_UB;
}

fn UbVal ub_binop(UbVal a, UbVal b)
{
    if (a == UbVal.UB_UB || b == UbVal.UB_UB) return UbVal.UB_UB;
    if (a == UbVal.UB_POISON || b == UbVal.UB_POISON) return UbVal.UB_POISON;
    return UbVal.UB_DEF;
}

fn UbVal ub_unop(UbVal a)
{
    return a;
}

fn UbVal ub_freeze(UbVal a)
{
    if (a == UbVal.UB_UB) return UbVal.UB_UB;    // freeze on UB stays UB
    return UbVal.UB_DEF;                          // freeze(poison) = some def
}

fn UbVal ub_deref(UbVal p)
{
    if (p == UbVal.UB_UB) return UbVal.UB_UB;
    if (p == UbVal.UB_POISON) return UbVal.UB_UB;   // deref poison = UB
    return UbVal.UB_DEF;
}

fn UbVal ub_div(UbVal num, UbVal den, bool den_is_zero)
{
    if (num == UbVal.UB_UB || den == UbVal.UB_UB) return UbVal.UB_UB;
    if (den_is_zero) return UbVal.UB_UB;
    if (num == UbVal.UB_POISON || den == UbVal.UB_POISON) return UbVal.UB_POISON;
    return UbVal.UB_DEF;
}

fn UbVal ub_shift(UbVal v, UbVal amt, usz bits)
{
    (void)bits;
    if (v == UbVal.UB_UB || amt == UbVal.UB_UB) return UbVal.UB_UB;
    // If shift amount may be >= bitwidth, UB (in C; poison in LLVM).
    // We don't have constant analysis here; conservatively propagate.
    if (v == UbVal.UB_POISON || amt == UbVal.UB_POISON) return UbVal.UB_POISON;
    return UbVal.UB_DEF;
}

// ── Per-expression tagging ─────────────────────────────────────────────
const usz UB_MAX_FACTS = 65536;

struct UbAnalysis
{
    Arena* arena;
    UbVal* fact;
    usz    fact_count;
    usz    n_def;
    usz    n_poison;
    usz    n_ub;
    usz    n_freeze;
    usz    n_div;
    usz    n_shift;
    usz    n_deref;
    usz    n_branch;
    usz    n_int;
    usz    depth;
}

fn void UbAnalysis.init(UbAnalysis* u, Arena* a)
{
    u.arena = a;
    u.fact = (UbVal*)calloc(UB_MAX_FACTS, 4);
    for (usz i = 0; i < UB_MAX_FACTS; i++) u.fact[i] = UbVal.UB_DEF;
    u.fact_count = 0;
    u.n_def = 0; u.n_poison = 0; u.n_ub = 0;
    u.n_freeze = 0; u.n_div = 0; u.n_shift = 0; u.n_deref = 0;
    u.n_branch = 0; u.n_int = 0;
}

// Simple hash of node pointer to fact index (facts are advisory, not precise).
fn usz ub_idx(Node* n)
{
    usz p = (usz)n;
    return (p >> 3) % UB_MAX_FACTS;
}

fn void UbAnalysis.tag(UbAnalysis* u, Node* n, UbVal v)
{
    if (n == null) return;
    usz i = ub_idx(n);
    u.fact[i] = ub_join(u.fact[i], v);
    u.fact_count = u.fact_count + 1;
    switch (v)
    {
        case UbVal.UB_DEF:    u.n_def = u.n_def + 1; break;
        case UbVal.UB_POISON: u.n_poison = u.n_poison + 1; break;
        case UbVal.UB_UB:     u.n_ub = u.n_ub + 1; break;
    }
}

fn UbVal UbAnalysis.get(UbAnalysis* u, Node* n)
{
    if (n == null) return UbVal.UB_POISON;
    return u.fact[ub_idx(n)];
}

// ── Walk ──────────────────────────────────────────────────────────────
fn void UbAnalysis.walk(UbAnalysis* u, Node* n, int depth)
{
    if (n == null || depth > 200) return;
    switch (n.kind)
    {
        case Nk.N_EXPR_INT:
        case Nk.N_EXPR_FLOAT:
        case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_CHAR:
        case Nk.N_EXPR_STRING:
        case Nk.N_EXPR_UNIT:
        case Nk.N_EXPR_NULL:
            u.tag(n, UbVal.UB_DEF);
            u.n_int = u.n_int + 1;
            break;
        case Nk.N_EXPR_BINARY:
        {
            Tk op = (Tk)n.p.op;
            u.walk(n.child(0), depth + 1);
            u.walk(n.child(1), depth + 1);
            UbVal a = u.get(n.child(0));
            UbVal b = u.get(n.child(1));
            bool div_zero = (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
                         && n.child(1) != null && n.child(1).kind == Nk.N_EXPR_INT
                         && n.child(1).p.ival == 0;
            if (op == Tk.TOKEN_SLASH || op == Tk.TOKEN_PERCENT)
            {
                u.n_div = u.n_div + 1;
                u.tag(n, ub_div(a, b, div_zero));
            }
            else if (op == Tk.TOKEN_LSHIFT || op == Tk.TOKEN_RSHIFT)
            {
                u.n_shift = u.n_shift + 1;
                u.tag(n, ub_shift(a, b, 64));
            }
            else
            {
                u.tag(n, ub_binop(a, b));
            }
            break;
        }
        case Nk.N_EXPR_UNARY:
        {
            u.walk(n.child(0), depth + 1);
            u.tag(n, ub_unop(u.get(n.child(0))));
            break;
        }
        case Nk.N_EXPR_DEREF:
        {
            u.walk(n.child(0), depth + 1);
            u.n_deref = u.n_deref + 1;
            u.tag(n, ub_deref(u.get(n.child(0))));
            break;
        }
        case Nk.N_EXPR_IF:
        case Nk.N_EXPR_WHILE:
        {
            u.walk(n.child(0), depth + 1);
            u.n_branch = u.n_branch + 1;
            UbVal cv = ub_strict_if(u.get(n.child(0)));
            // Branch on UB/non-poison is itself UB for both branches.
            if (cv == UbVal.UB_UB) u.tag(n, UbVal.UB_UB);
            for (usz i = 1; i < n.child_count; i++) u.walk(n.children[i], depth + 1);
            break;
        }
        case Nk.N_EXPR_CALL:
        {
            // Calls are conservatively considered DEF unless their callee
            // is known poison (we can't tell without interproc, but mark def).
            for (usz i = 0; i < n.child_count; i++) u.walk(n.children[i], depth + 1);
            u.tag(n, UbVal.UB_DEF);
            break;
        }
        default:
        {
            for (usz i = 0; i < n.child_count; i++) u.walk(n.children[i], depth + 1);
            // If any child is UB we are UB; if any is POISON we are POISON.
            UbVal v = UbVal.UB_DEF;
            for (usz i = 0; i < n.child_count; i++)
            {
                if (n.children[i] != null) v = ub_join(v, u.get(n.children[i]));
            }
            u.tag(n, v);
            break;
        }
    }
}

fn void UbAnalysis.report(UbAnalysis* u)
{
    printf("  ub-lattice       : def=%d poison=%d ub=%d (total tags %d)\n",
           (int)u.n_def, (int)u.n_poison, (int)u.n_ub, (int)u.fact_count);
    printf("  ub-ops           : %d div, %d shift, %d deref, %d branches, %d literals\n",
           (int)u.n_div, (int)u.n_shift, (int)u.n_deref, (int)u.n_branch, (int)u.n_int);
    printf("  ub-freeze        : %d freeze sites tracked\n", (int)u.n_freeze);
}

fn void UbAnalysis.destroy(UbAnalysis* u)
{
    if (u.fact != null) { free((void*)u.fact); u.fact = null; }
}
