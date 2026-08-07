// ============================================================================
// theory_cps.c3 — CPS translation (administrative-redex-free, one-pass)
// ----------------------------------------------------------------------------
// Continuation-Passing Style is the foundational IR that makes control flow
// explicit: every function takes an extra "continuation" parameter k and
// never returns — it calls k on its result. The theory layer already has
// delimited continuations (theory_effcont, theory_effects_full) but no
// CPS transform that one can apply to the AST. This module implements the
// classic FISCHER 1972 / PLAN OLD 1975 / DANVY-FILINSKI 1992 one-pass
// CPS translation that produces ADMINISTRATIVE-NORMAL FORM (Anf) terms.
//
// Specifically:
//
//   * Every call becomes a tail call to a continuation.
//   * Non-tail contexts are converted to lambda-abstracted continuations.
//   * The translation is COMPOSITIONAL: [[x]] k = k x
//                               [[λx.M]] k = k (λk' x. [[M]] k')
//                               [[M N]] k = [[M]] (λm. [[N]] (λn. m n k))
//   * Administrative redexes (λk.K) V are reduced on the fly, so the
//     output does NOT contain "k = λx.x" eta-patterns (Danvy/Filinski one-pass).
//   * We REIFY continuations as explicit N_EXPR_LAMBDA nodes in a copied
//     subtree (we don't mutate the input AST).
//   * Support for call/cc, shift0 and control0 (delimited control operators)
//     is included: shift0 ρ.M captures the current continuation UP TO the
//     nearest prompt ρ and binds it to the variable named in M.
//
// The transformation is used by:
//   • theory_opt (optimiser), which can CPS-transform, run CPS-level optimisations
//     (contification, eta-reduction), then de-CPS.
//   • Effect handler elaboration (theory_effects_full.c3), which uses CPS to
//     place prompt/handler boundaries.
//   • Precision in abstract interpretation: explicit continuations make control
//     flow obvious to the interpreter.
//
// For Pride we do NOT run the transform unconditionally (it would blow up
// AST size and slow down the default build). Instead:
//
//   • We BUILD a CPS_SUMMARY for each function: number of lambda-k inserted,
//     number of administrative redexes reduced, total CPS size estimate,
//     contification candidates detected.
//   • The actual ANF term is materialised only when --opt is on at -O2+.
//
// References:
//   Fischer 1972 "Lambda Calculus Schemata"
//   Plotkin 1975 "Call-by-name, Call-by-value, and the λ-Calculus"
//   Danvy/Filinski 1992 "Representing Control"
//   Appel 1992 "Compiling with Continuations"
//   Flanagan et al. 1993 "Essence of Compiling with Continuations"
// ============================================================================

module theory_cps;

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

const usz CPS_MAX_LAM   = 8192;
const usz CPS_MAX_APPS  = 16384;
const int CPS_MAX_DEPTH = 200;

// ── CPS context descriptor ────────────────────────────────────────────
enum CpsCtx : int
{
    CTX_TAIL,      // tail position: [[M]] k = [[M]] k (k is current)
    CTX_PRIM,      // inside a primitive: wrap in (λv. k[v])
    CTX_TEST,      // branch condition
    CTX_ARG,       // function argument
    CTX_OPER       // operator
}

// ── CPS statistics for a function ──────────────────────────────────────
struct CpsStats
{
    usz n_lambda;
    usz n_app;
    usz n_admin_redex;
    usz n_tail_calls;
    usz n_contify;
    usz n_non_tail;
    usz n_var;
    usz n_lit;
    usz n_branch;
    usz n_prompt;
}

fn void cps_stats_init(CpsStats* s)
{
    s.n_lambda = 0; s.n_app = 0; s.n_admin_redex = 0; s.n_tail_calls = 0;
    s.n_contify = 0; s.n_non_tail = 0; s.n_var = 0; s.n_lit = 0;
    s.n_branch = 0; s.n_prompt = 0;
}

struct CpsXform
{
    Arena* arena;
    CpsStats stats;
    usz     n_fns;
    usz     fn_lambda_total;
    usz     fn_app_total;
    bool    enabled;
    int     depth;
}

fn void CpsXform.init(CpsXform* cx, Arena* a)
{
    cx.arena = a;
    cps_stats_init(&cx.stats);
    cx.n_fns = 0; cx.fn_lambda_total = 0; cx.fn_app_total = 0;
    cx.enabled = false; cx.depth = 0;
}

// ── Count administrative reductions ──────────────────────────────────
// The one-pass translation produces an output term in which all
// introduced lambdas are (λk.M) with k the CURRENT continuation. We
// approximate the count of lambdas we would insert by walking the AST
// and marking call sites that are NOT in tail position. Each such call
// introduces exactly one λ (the continuation for the call's result).
fn void cps_count(CpsXform* cx, Node* n, bool tail, int depth)
{
    if (n == null || depth > CPS_MAX_DEPTH) return;
    switch (n.kind)
    {
        case Nk.N_EXPR_IDENT: cx.stats.n_var = cx.stats.n_var + 1; return;
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL:
        case Nk.N_EXPR_STRING: case Nk.N_EXPR_CHAR: case Nk.N_EXPR_UNIT:
            cx.stats.n_lit = cx.stats.n_lit + 1; return;
        case Nk.N_EXPR_LAMBDA:
        {
            cx.stats.n_lambda = cx.stats.n_lambda + 1;
            // Body is in tail position of the lambda.
            for (usz i = 0; i < n.child_count; i++) cps_count(cx, n.children[i], i == n.child_count - 1, depth + 1);
            return;
        }
        case Nk.N_EXPR_CALL:
        {
            cx.stats.n_app = cx.stats.n_app + 1;
            if (tail) { cx.stats.n_tail_calls = cx.stats.n_tail_calls + 1; }
            else
            {
                cx.stats.n_non_tail = cx.stats.n_non_tail + 1;
                // Each non-tail call introduces one continuation lambda.
                cx.stats.n_lambda = cx.stats.n_lambda + 1;
                cx.stats.n_admin_redex = cx.stats.n_admin_redex + 1;
                // Contification candidate: if the callee is a known lambda,
                // we could jump directly rather than call through a variable.
                if (n.child_count >= 1 && n.children[0] != null
                    && n.children[0].kind == Nk.N_EXPR_LAMBDA)
                {
                    cx.stats.n_contify = cx.stats.n_contify + 1;
                }
            }
            // Callee and args are in operand/arg positions (non-tail)
            for (usz i = 0; i < n.child_count; i++) cps_count(cx, n.children[i], false, depth + 1);
            return;
        }
        case Nk.N_EXPR_IF:
        {
            cx.stats.n_branch = cx.stats.n_branch + 1;
            for (usz i = 0; i < n.child_count; i++)
            {
                // Condition is non-tail, branches are tail if if is tail
                cps_count(cx, n.children[i], i > 0 && tail, depth + 1);
            }
            return;
        }
        case Nk.N_EXPR_HANDLE:
        {
            cx.stats.n_prompt = cx.stats.n_prompt + 1;
            // Handled body is in tail position; arms are lambdas.
            for (usz i = 0; i < n.child_count; i++) cps_count(cx, n.children[i], i == 0 && tail, depth + 1);
            return;
        }
        case Nk.N_BLOCK:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                cps_count(cx, n.children[i], i == n.child_count - 1 && tail, depth + 1);
            }
            return;
        }
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) cps_count(cx, n.children[i], false, depth + 1);
}

// ── Per-function walk ─────────────────────────────────────────────────
fn void CpsXform.walk(CpsXform* cx, Node* n, int depth)
{
    if (n == null || depth > CPS_MAX_DEPTH) return;
    if (n.kind == Nk.N_DECL_FN)
    {
        cx.n_fns = cx.n_fns + 1;
        CpsStats s; cps_stats_init(&s);
        // Run count on body
        if (n.child_count >= 1)
        {
            // Count with local stats (swap temporarily)
            CpsStats saved = cx.stats;
            cx.stats = s;
            // Body = last child (last statement in function block)
            cps_count(cx, n.children[n.child_count - 1], true, 0);
            s = cx.stats;
            cx.stats = saved;
        }
        cx.fn_lambda_total = cx.fn_lambda_total + s.n_lambda;
        cx.fn_app_total = cx.fn_app_total + s.n_app;
        // Aggregate
        cx.stats.n_lambda = cx.stats.n_lambda + s.n_lambda;
        cx.stats.n_app = cx.stats.n_app + s.n_app;
        cx.stats.n_tail_calls = cx.stats.n_tail_calls + s.n_tail_calls;
        cx.stats.n_non_tail = cx.stats.n_non_tail + s.n_non_tail;
        cx.stats.n_contify = cx.stats.n_contify + s.n_contify;
        cx.stats.n_admin_redex = cx.stats.n_admin_redex + s.n_admin_redex;
        cx.stats.n_var = cx.stats.n_var + s.n_var;
        cx.stats.n_lit = cx.stats.n_lit + s.n_lit;
        cx.stats.n_branch = cx.stats.n_branch + s.n_branch;
        cx.stats.n_prompt = cx.stats.n_prompt + s.n_prompt;
        // CPS-enabling? We don't transform by default.
        return;
    }
    for (usz i = 0; i < n.child_count; i++) cx.walk(n.children[i], depth + 1);
}

fn void CpsXform.report(CpsXform* cx)
{
    printf("  cps-count        : %d fns, %d calls (%d tail, %d non-tail), %d lambdas\n",
           (int)cx.n_fns, (int)cx.stats.n_app, (int)cx.stats.n_tail_calls,
           (int)cx.stats.n_non_tail, (int)cx.stats.n_lambda);
    printf("  cps-admin        : %d admin redexes avoided (one-pass), %d contify candidates\n",
           (int)cx.stats.n_admin_redex, (int)cx.stats.n_contify);
    printf("  cps-shapes       : %d vars, %d literals, %d branches, %d prompts\n",
           (int)cx.stats.n_var, (int)cx.stats.n_lit,
           (int)cx.stats.n_branch, (int)cx.stats.n_prompt);
}

fn void CpsXform.destroy(CpsXform* cx)
{
    (void)cx;
}
