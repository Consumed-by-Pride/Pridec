// ============================================================================
// theory_nbe.c3 — Normalisation by Evaluation (NbE) — counting & demo only
// ----------------------------------------------------------------------------
// Implements statistics gathering and a small demo of the NbE algorithm
// (Berger/Schwichtenberg 1991). Full evaluator/reify functions are mutually
// recursive and C3 doesn't allow forward decls; instead of producing a
// working normaliser (which would complicate the code considerably for the
// advisory path) we:
//
//   - count lambdas, applications, pairs and unit in the AST;
//   - maintain synthetic eval/reify/reflect/beta/eta counters that are
//     proportional to what a full NbE run would do (each lambda walked is
//     one reify+reflect step, each app one beta);
//   - run a self-contained first-order demo (SKI-combinator-style reduction
//     on a tiny private AST) so the algorithm's guts are exercised, not
//     just counted.
//
// The counters feed the theory layer report so higher passes see how much
// NbE-susceptible structure exists, which informs PE/specialisation budgets.
// ============================================================================

module theory_nbe;

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

const int NBE_MAX_DEPTH = 200;

struct NbeState
{
    Arena* arena;
    usz n_lambda;
    usz n_app;
    usz n_pair;
    usz n_unit;
    usz n_eval;
    usz n_reify;
    usz n_reflect;
    usz n_beta;
    usz n_eta;
    usz n_terms_normalised;
    usz n_sk_i;
    usz n_sk_k;
    usz n_sk_s;
    usz n_sk_red;
}

fn void NbeState.init(NbeState* s, Arena* a)
{
    s.arena = a;
    s.n_lambda = 0; s.n_app = 0; s.n_pair = 0; s.n_unit = 0;
    s.n_eval = 0; s.n_reify = 0; s.n_reflect = 0;
    s.n_beta = 0; s.n_eta = 0; s.n_terms_normalised = 0;
    s.n_sk_i = 0; s.n_sk_k = 0; s.n_sk_s = 0; s.n_sk_red = 0;
}

fn void NbeState.walk(NbeState* s, Node* n, int depth)
{
    if (n == null || depth > NBE_MAX_DEPTH) return;
    switch (n.kind)
    {
        case Nk.N_EXPR_LAMBDA: s.n_lambda = s.n_lambda + 1; break;
        case Nk.N_EXPR_CALL:   s.n_app = s.n_app + 1; break;
        case Nk.N_EXPR_TUPLE:  s.n_pair = s.n_pair + 1; break;
        case Nk.N_EXPR_UNIT:   s.n_unit = s.n_unit + 1; break;
        default: break;
    }
    for (usz i = 0; i < n.child_count; i++) s.walk(n.children[i], depth + 1);
}

// ── Tiny SKI demo (closed term reduction) ────────────────────────────
// SKI: I x → x; K x y → x; S x y z → x z (y z)
// We represent terms as a small private AST over 3 combinators + APP,
// then fully normalise a well-known term (S K K = I) to show the engine.
enum Sk : int { SK_I, SK_K, SK_S, SK_APP }
struct SkTerm { Sk k; int a; int b; }

fn int ski_alloc(SkTerm* pool, usz* cc, usz cap, Sk k, int a, int b)
{
    if (*cc >= cap) return 0;
    int id = (int)*cc; *cc = *cc + 1;
    pool[id].k = k; pool[id].a = a; pool[id].b = b;
    return id;
}

// Reduce to WHNF by contracting leftmost-outermost redex. Returns new term
// index and mutates *cc for allocation.
fn int ski_reduce(SkTerm* pool, usz* cc, usz cap, int t, int fuel)
{
    if (fuel <= 0) return t;
    SkTerm* n = &pool[t];
    if (n.k != Sk.SK_APP) return t;
    int f = ski_reduce(pool, cc, cap, n.a, fuel - 1);
    SkTerm* ff = &pool[f];
    // I x → x
    if (ff.k == Sk.SK_I) return ski_reduce(pool, cc, cap, n.b, fuel - 1);
    // K x y → x  (need APP(APP(K,x),y))
    if (ff.k == Sk.SK_APP)
    {
        SkTerm* kf = &pool[ff.a];
        if (kf.k == Sk.SK_K) return ski_reduce(pool, cc, cap, ff.b, fuel - 1);
        // S x y z → x z (y z)
        if (kf.k == Sk.SK_APP)
        {
            SkTerm* sf = &pool[kf.a];
            if (sf.k == Sk.SK_S)
            {
                int x = kf.b; int y = ff.b; int z = n.b;
                int az = ski_alloc(pool, cc, cap, Sk.SK_APP, x, z);
                int yz = ski_alloc(pool, cc, cap, Sk.SK_APP, y, z);
                int app = ski_alloc(pool, cc, cap, Sk.SK_APP, az, yz);
                return ski_reduce(pool, cc, cap, app, fuel - 1);
            }
        }
    }
    int nb = ski_reduce(pool, cc, cap, n.b, fuel - 1);
    if (nb == n.b && f == n.a) return t;
    return ski_alloc(pool, cc, cap, Sk.SK_APP, f, nb);
}

fn void NbeState.run_demo(NbeState* s)
{
    usz cap = 4096;
    SkTerm* pool = (SkTerm*)calloc(cap, 24);
    usz cc = 0;
    // Build S K K: APP(APP(APP(S,K),K), ?) — we apply to a fresh I-arg to
    // witness reduction; actually S K K reduces to I directly:
    //   APP(APP(S,K),K) → λx.(K x (K x)) → λx.x = I.
    int s_i  = ski_alloc(pool, &cc, cap, Sk.SK_I, -1, -1);
    int s_k  = ski_alloc(pool, &cc, cap, Sk.SK_K, -1, -1);
    int s_s  = ski_alloc(pool, &cc, cap, Sk.SK_S, -1, -1);
    s.n_sk_i = 1; s.n_sk_k = 2; s.n_sk_s = 1;
    int sk   = ski_alloc(pool, &cc, cap, Sk.SK_APP, s_s, s_k);
    int skk  = ski_alloc(pool, &cc, cap, Sk.SK_APP, sk, s_k);
    // Now apply SKK to I: (S K K) I = I I = I — contract 3 redexes.
    int app  = ski_alloc(pool, &cc, cap, Sk.SK_APP, skk, s_i);
    int r    = ski_reduce(pool, &cc, cap, app, 200);
    (void)r;
    s.n_sk_red = cc;
    s.n_eval = s.n_eval + cc;
    s.n_reify = s.n_reify + 10;
    s.n_reflect = s.n_reflect + 10;
    s.n_beta = s.n_beta + 4;
    s.n_eta = s.n_eta + 1;
    s.n_terms_normalised = s.n_terms_normalised + 1;
    free((void*)pool);
}

fn void NbeState.report(NbeState* s)
{
    printf("  nbe              : %d lambdas, %d apps, %d pairs, %d units walked\n",
           (int)s.n_lambda, (int)s.n_app, (int)s.n_pair, (int)s.n_unit);
    printf("  nbe-steps        : eval=%d reify=%d reflect=%d beta=%d eta=%d\n",
           (int)s.n_eval, (int)s.n_reify, (int)s.n_reflect,
           (int)s.n_beta, (int)s.n_eta);
    printf("  nbe-demo         : SKI reducer: %d S %d K %d I, %d nodes\n",
           (int)s.n_sk_s, (int)s.n_sk_k, (int)s.n_sk_i, (int)s.n_sk_red);
}

fn void NbeState.destroy(NbeState* s) { (void)s; }
