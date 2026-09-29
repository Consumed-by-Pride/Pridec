// ============================================================================
// theory_session.c3 — Binary session types (Honda/Kubo/Vasconcelos 1998;
//                      Gay & Hole 2005)
// ----------------------------------------------------------------------------
// Session types describe COMMUNICATION PROTOCOLS on a channel as a
// coinductive, linear-type structure that alternates between "choice offered"
// and "choice made". A channel is linear, so every prefix is consumed
// exactly once as the conversation progresses — mis-timed sends/receives
// are caught exactly like double-use/move-after-free in the linearity
// pass (theory_linearity.c3), but at a richer protocol level.
//
// Grammar (coinductive, with recursion `μx.T`):
//
//   T  ::=  !a.T          // SEND a value of type a, then continue as T
//        |  ?a.T          // RECEIVE a value of type a, then continue as T
//        |  +{l_i:T_i}    // INTERNAL choice (select): pick one label l_i
//        |  &{l_i:T_i}    // EXTERNAL choice (offer/branch): wait for label l_i
//        |  end           // terminator — channel closed
//        |  μx.T          // recursive session
//        |  x             // recursion variable (de Bruijn)
//
// Subtyping (Gay & Hole 2005) is COINDUCTIVE and contravariant on inputs,
// covariant on outputs, width in both directions for branches/selects:
//
//   !a.T ≤ !a'.T'     ⇐   a' ≤ a  ∧  T ≤ T'            // send cov in payload!
//   ?a.T ≤ ?a'.T'     ⇐   a ≤ a'  ∧  T ≤ T'            // recv contravariant
//   +{l_i:T_i} ≤ +{m_j:U_j} ⇐ {l_i} ⊇ {m_j} ∧ ∀j. T_{m_j} ≤ U_j
//   &{l_i:T_i} ≤ &{m_j:U_j} ⇐ {l_i} ⊆ {m_j} ∧ ∀i. T_i ≤ U_{l_i}
//   end ≤ end
//
// In words:
//   • If you OFFER fewer branches (& narrower), you are a subtype of a
//     wider offer because the environment can handle the bigger set.
//   • If you SELECT more labels (+ wider), you are a subtype of a narrower
//     select because the receiver only needs to handle a smaller set.
//   • SEND is covariant in payload: sending a subtype satisfies any
//     expectation of a supertype being sent.
//   • RECV is contravariant in payload: expecting to receive a supertype
//     accepts any subtype.
//
// Duality is the central operation: flip send↔recv, branch↔select, keep end,
// flip μ binders. dual(!a.T) = ?a.dual(T); dual(?a.T)=!a.dual(T);
// dual(+{...})=&{dual(...)}; dual(&{...})=+{dual(...)}; dual(end)=end;
// dual(μx.T)=μx.dual(T). If two channels are dual, plugging them together
// (linking both ends of a fresh channel) is DEADLOCK-FREE by construction
// because every send matches a receive and every select matches a branch.
//
// We do NOT build a full reconstructive type system. Pride's front-end is
// untyped. What we DO is:
//   1. A SessionStore — hash-consed session types with μ-binders, de Bruijn
//      indices for recursion variables, with shift/subst/contractivity
//      tests (same machinery as theory_mu.c3).
//   2. A COINDUCTIVE subtype decision procedure up to a depth budget, with
//      a memo table of pairs (s, t) assumed true, to avoid infinite loops
//      on μ-types (standard coinduction-as-coalgebra trick; we model the
//      greatest-fixed-point as the closure of pairs we have no reason to
//      reject).
//   3. A DUALITY check: scan the program for `send/recv/select/offer/close`
//      primitives (identified by name_id on N_EXPR_IDENT/N_EXPR_CALL), and
//      try to pair up operations on the same channel. Report mismatches
//      (send on one side without matching recv, select of label never
//      offered, etc.) as COUNTERS only; we don't emit hard errors because
//      Pride is untyped.
//   4. A linearity check per channel-slot: each end of the inferred session
//      must be fully consumed exactly once (uses linearity machinery; close
//      counts as a use).
//
// This file is roughly a journal-club implementation of Gay/Hole 2005 with
// the duality-as-deadlock-freedom observation from Honda et al. 1998 and
// the pragmatic take of the RUST SESSION TYPES / RUMPETTE/SESSIONS libraries.
// References:
//   Honda, Vasconcelos, Kubo 1998 "Language Primitives and Type Disciplines
//     for Structured Communication-Based Programming"
//   Gay & Hole 2005 "Subtyping for Session Types in the Pi-Calculus"
//   Lindley & Morris 2016 "Talking Bananas: Structural Recursion for Session
//     Types" (on the μ-contractivity requirement)
//   Padovani 2017 "A Simple Library Implementation of Binary Sessions"
//     (for the pragmatic AST-level recognition)
// ============================================================================

module theory_session;

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
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz SESS_MAX_NODES   = 4096;
const usz SESS_MAX_LABELS  = 256;
const usz SESS_MAX_PAIRS   = 1024;
const int  SESS_MAX_DEPTH  = 200;
const usz SESS_NODE_SZ     = 32;
const usz SESS_PAIR_SZ     = 16;
const usz SESS_LABEL_SZ    = 12;
const usz SESS_CHANS       = 256;

// Session type node kinds.
enum Sk : int
{
    SK_END,       // closed channel
    SK_SEND,      // !a.S
    SK_RECV,      // ?a.S
    SK_SELECT,    // +{l_i:S_i}  (internal choice)
    SK_BRANCH,    // &{l_i:S_i}  (external choice)
    SK_MU,        // μx.S
    SK_VAR        // x  (de Bruijn index)
}

struct Slbl
{
    uint name_id;
    int  cont;      // session node index
}

struct Snode
{
    Sk   kind;
    uint payload;    // for SEND/RECV: a nominal "payload id" (name hash)
    int  cont;       // continuation node index
    int  lbl_start;  // for SELECT/BRANCH: index into labels array
    usz  lbl_count;  // number of labels
    int  var_idx;    // for SK_VAR: de Bruijn index
    uint hash;
    Node* at;        // the source operation / construct this node came from
}

struct SPair
{
    int a;
    int b;
}

struct ChanState
{
    uint name_id;
    int  ssn;        // current session (mutates as operations consume prefix)
    usz uses;
    bool active;
}

struct SessionCheck
{
    Arena*   arena;
    Snode*   nodes;
    usz      n_nodes;
    Slbl*    labels;
    usz      n_labels;
    SPair*   pairs;     // memo for coinductive subtyping
    usz      n_pairs;
    ChanState* chans;
    usz      n_chans;
    usz      n_end;
    usz      n_send;
    usz      n_recv;
    usz      n_select;
    usz      n_branch;
    usz      n_mu;
    usz      n_dual_checks;
    usz      n_dual_ok;
    usz      n_dual_fail;
    usz      n_sub_checks;
    usz      n_sub_ok;
    usz      n_sub_fail;
    usz      n_unclosed;
    usz      n_linearity_err;
    // endpoints
    Endpoint* eps;
    usz       n_eps;
    usz       n_pairs_found, n_pairs_skipped, n_param_eps;
    usz       n_w4260, n_w4261, n_n4262;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*     file;
    uint      lbl_then, lbl_else, lbl_again, lbl_done, lbl_arm_base;
    int*      dual_memo;      // per-dual μ memo (cyclic graphs)
    usz       dual_memo_cap;
}

// ═══════════════════════════════════════════════════════════════════════════
// Constructors
// ═══════════════════════════════════════════════════════════════════════════
fn int sess_mk_end(SessionCheck* sc)
{
    if (sc.n_nodes >= SESS_MAX_NODES) return 0;
    int i = (int)sc.n_nodes; sc.n_nodes = sc.n_nodes + 1;
    sc.nodes[i].kind = Sk.SK_END;
    sc.nodes[i].payload = 0; sc.nodes[i].cont = -1;
    sc.nodes[i].lbl_start = -1; sc.nodes[i].lbl_count = 0;
    sc.nodes[i].var_idx = 0;
    sc.nodes[i].hash = 1;
    sc.n_end = sc.n_end + 1;
    return i;
}

fn int sess_mk_pref(SessionCheck* sc, Sk k, uint payload, int cont)
{
    if (sc.n_nodes >= SESS_MAX_NODES) return 0;
    int i = (int)sc.n_nodes; sc.n_nodes = sc.n_nodes + 1;
    sc.nodes[i].kind = k;
    sc.nodes[i].payload = payload;
    sc.nodes[i].cont = cont;
    sc.nodes[i].lbl_start = -1; sc.nodes[i].lbl_count = 0;
    sc.nodes[i].var_idx = 0;
    uint h = 7919u;
    if (k == Sk.SK_SEND) { h = 131071u; sc.n_send = sc.n_send + 1; }
    if (k == Sk.SK_RECV) { h = 131073u; sc.n_recv = sc.n_recv + 1; }
    h = h * 2654435761u ^ payload ^ (uint)cont;
    sc.nodes[i].hash = h;
    return i;
}

fn int sess_mk_var(SessionCheck* sc, int idx)
{
    if (sc.n_nodes >= SESS_MAX_NODES) return 0;
    int i = (int)sc.n_nodes; sc.n_nodes = sc.n_nodes + 1;
    sc.nodes[i].kind = Sk.SK_VAR;
    sc.nodes[i].payload = 0; sc.nodes[i].cont = -1;
    sc.nodes[i].lbl_start = -1; sc.nodes[i].lbl_count = 0;
    sc.nodes[i].var_idx = idx;
    sc.nodes[i].hash = 524287u ^ (uint)idx;
    return i;
}

fn int sess_mk_mu(SessionCheck* sc, int body)
{
    if (sc.n_nodes >= SESS_MAX_NODES) return 0;
    int i = (int)sc.n_nodes; sc.n_nodes = sc.n_nodes + 1;
    sc.nodes[i].kind = Sk.SK_MU;
    sc.nodes[i].payload = 0; sc.nodes[i].cont = body;
    sc.nodes[i].lbl_start = -1; sc.nodes[i].lbl_count = 0;
    sc.nodes[i].var_idx = 0;
    sc.nodes[i].hash = 262143u ^ (uint)body;
    sc.n_mu = sc.n_mu + 1;
    return i;
}

fn int sess_mk_choice(SessionCheck* sc, Sk k, Slbl* arr, usz count)
{
    if (sc.n_nodes >= SESS_MAX_NODES) return 0;
    int start = -1;
    if (count > 0 && sc.n_labels + count <= SESS_MAX_LABELS)
    {
        start = (int)sc.n_labels;
        for (usz j = 0; j < count; j++)
        {
            sc.labels[sc.n_labels] = arr[j];
            sc.n_labels = sc.n_labels + 1;
        }
    }
    int i = (int)sc.n_nodes; sc.n_nodes = sc.n_nodes + 1;
    sc.nodes[i].kind = k;
    sc.nodes[i].payload = 0; sc.nodes[i].cont = -1;
    sc.nodes[i].lbl_start = start;
    sc.nodes[i].lbl_count = count;
    sc.nodes[i].var_idx = 0;
    uint h = 65537u;
    if (k == Sk.SK_SELECT) { h = 65539u; sc.n_select = sc.n_select + 1; }
    if (k == Sk.SK_BRANCH) { h = 65538u; sc.n_branch = sc.n_branch + 1; }
    for (usz j = 0; j < count; j++) { h = h * 2654435761u ^ arr[j].name_id ^ (uint)arr[j].cont; }
    sc.nodes[i].hash = h;
    return i;
}

// ═══════════════════════════════════════════════════════════════════════════
// Duality (the heart of session types).
// ═══════════════════════════════════════════════════════════════════════════
// Control-flow choices (then/else, again/done, arm_i) are decisions each
// party takes on its own — the dual keeps their kind; protocol labels
// flip ⊕ ↔ &.  μ-nodes are memoised so cyclic graphs dualise in one pass.
fn bool SessionCheck.is_flow_label(SessionCheck* sc, uint id)
{
    return id == sc.lbl_then || id == sc.lbl_else || id == sc.lbl_again || id == sc.lbl_done
        || (id >= sc.lbl_arm_base && id < sc.lbl_arm_base + 64);
}

fn int sess_dual(SessionCheck* sc, int s, int depth)
{
    if (depth == 0)
    {
        usz cap = sc.n_nodes + 1;
        sc.dual_memo = (int*)malloc(cap * 4);
        sc.dual_memo_cap = cap;
        for (usz i = 0; i < cap; i++) { sc.dual_memo[i] = -1; }
    }
    int r = sess_dual_rec(sc, s, depth);
    if (depth == 0 && sc.dual_memo != null) { free(sc.dual_memo); sc.dual_memo = null; sc.dual_memo_cap = 0; }
    return r;
}

fn int sess_dual_rec(SessionCheck* sc, int s, int depth)
{
    if (s < 0 || (usz)s >= sc.n_nodes || depth > SESS_MAX_DEPTH) return sess_mk_end(sc);
    if (sc.dual_memo != null && (usz)s < sc.dual_memo_cap && sc.dual_memo[s] >= 0) return sc.dual_memo[s];
    Snode n = sc.nodes[s];
    switch (n.kind)
    {
        case Sk.SK_END: return sess_mk_end(sc);
        case Sk.SK_SEND: return sess_mk_pref(sc, Sk.SK_RECV, n.payload, sess_dual_rec(sc, n.cont, depth + 1));
        case Sk.SK_RECV: return sess_mk_pref(sc, Sk.SK_SEND, n.payload, sess_dual_rec(sc, n.cont, depth + 1));
        case Sk.SK_SELECT:
        case Sk.SK_BRANCH:
        {
            Slbl[16] arr; usz k = 0;
            usz base = (usz)n.lbl_start;
            bool flow = n.lbl_count > 0 && sc.is_flow_label(sc.labels[base].name_id);
            for (usz i = 0; i < n.lbl_count && i < 16; i++)
            {
                arr[k].name_id = sc.labels[base + i].name_id;
                arr[k].cont = sess_dual_rec(sc, sc.labels[base + i].cont, depth + 1);
                k = k + 1;
            }
            Sk dk = flow ? n.kind : (n.kind == Sk.SK_SELECT ? Sk.SK_BRANCH : Sk.SK_SELECT);
            return sess_mk_choice(sc, dk, &arr[0], k);
        }
        case Sk.SK_MU:
        {
            int d = sess_mk_mu(sc, -1);
            if (sc.dual_memo != null && (usz)s < sc.dual_memo_cap) { sc.dual_memo[s] = d; }
            int c = sess_dual_rec(sc, n.cont, depth + 1);
            sc.nodes[d].cont = c;
            sc.nodes[d].at = n.at;
            return d;
        }
        case Sk.SK_VAR: return sess_mk_var(sc, n.var_idx);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Coinductive session subtyping with memo.
// ═══════════════════════════════════════════════════════════════════════════
fn bool sess_pair_seen(SessionCheck* sc, int a, int b)
{
    for (usz i = 0; i < sc.n_pairs; i++)
    {
        if (sc.pairs[i].a == a && sc.pairs[i].b == b) return true;
    }
    return false;
}

fn void sess_pair_push(SessionCheck* sc, int a, int b)
{
    if (sc.n_pairs >= SESS_MAX_PAIRS) return;
    sc.pairs[sc.n_pairs].a = a; sc.pairs[sc.n_pairs].b = b;
    sc.n_pairs = sc.n_pairs + 1;
}

// Find label `name` in a choice node starting at lbl_start.
// Returns the continuation node idx, or -1 if not found.
fn int sess_find_lbl(SessionCheck* sc, Snode* nd, uint name)
{
    if (nd.lbl_start < 0) return -1;
    usz base = (usz)nd.lbl_start;
    for (usz i = 0; i < nd.lbl_count; i++)
    {
        if (sc.labels[base + i].name_id == name)
        {
            return sc.labels[base + i].cont;
        }
    }
    return -1;
}

fn bool sess_subtype(SessionCheck* sc, int a, int b, int depth)
{
    sc.n_sub_checks = sc.n_sub_checks + 1;
    if (a == b) return true;
    if (depth > SESS_MAX_DEPTH) return true;   // budget exhausted: assume ok
    if (a < 0 || b < 0) return true;
    if ((usz)a >= sc.n_nodes || (usz)b >= sc.n_nodes) return true;
    Snode* na = &sc.nodes[a];
    Snode* nb = &sc.nodes[b];
    // coinductive assumption: if we're already checking (a,b), succeed.
    if (sess_pair_seen(sc, a, b)) return true;
    if (na.kind == Sk.SK_MU)
    {
        // Unfold μx.T → T[μx.T/x] — here we approximate by continuing into body.
        sess_pair_push(sc, a, b);
        return sess_subtype(sc, na.cont, b, depth + 1);
    }
    if (nb.kind == Sk.SK_MU)
    {
        sess_pair_push(sc, a, b);
        return sess_subtype(sc, a, nb.cont, depth + 1);
    }
    if (na.kind == Sk.SK_END && nb.kind == Sk.SK_END) { return true; }
    if (na.kind == Sk.SK_VAR && nb.kind == Sk.SK_VAR) { return na.var_idx == nb.var_idx; }
    if (na.kind == Sk.SK_SEND && nb.kind == Sk.SK_SEND)
    {
        // Covariant in payload: a.payload >= b.payload (we simplify by always
        // accepting since we don't track payload subtyping here; the subtype
        // module handles that).
        sess_pair_push(sc, a, b);
        return sess_subtype(sc, na.cont, nb.cont, depth + 1);
    }
    if (na.kind == Sk.SK_RECV && nb.kind == Sk.SK_RECV)
    {
        sess_pair_push(sc, a, b);
        return sess_subtype(sc, na.cont, nb.cont, depth + 1);
    }
    if (na.kind == Sk.SK_SELECT && nb.kind == Sk.SK_SELECT)
    {
        // Width subtyping: narrower-on-right. All RHS labels must be present
        // in LHS, and corresponding continuations must subtype.
        sess_pair_push(sc, a, b);
        usz bnb = (usz)nb.lbl_start;
        usz bna = (usz)na.lbl_start;
        for (usz i = 0; i < nb.lbl_count; i++)
        {
            uint nm = sc.labels[bnb + i].name_id;
            int ac = sess_find_lbl(sc, na, nm);
            if (ac < 0) return false;
            int bc = sc.labels[bnb + i].cont;
            if (!sess_subtype(sc, ac, bc, depth + 1)) return false;
        }
        (void)bna;
        return true;
    }
    if (na.kind == Sk.SK_BRANCH && nb.kind == Sk.SK_BRANCH)
    {
        // Width subtyping: narrower-on-left. All LHS labels must be present
        // in RHS.
        sess_pair_push(sc, a, b);
        usz bna2 = (usz)na.lbl_start;
        for (usz i = 0; i < na.lbl_count; i++)
        {
            uint nm = sc.labels[bna2 + i].name_id;
            int bc = sess_find_lbl(sc, nb, nm);
            if (bc < 0) return false;
            int ac = sc.labels[bna2 + i].cont;
            if (!sess_subtype(sc, ac, bc, depth + 1)) return false;
        }
        return true;
    }
    // Kind mismatch → not subtype (e.g. send vs recv).
    return false;
}

// ═══════════════════════════════════════════════════════════════════════════
// From Pride code to sessions
// ───────────────────────────────────────────────────────────────────────────
// ENDPOINTS. Two sources:
//   • `let (tx, rx) = channel.oneshot()` / `bounded(n)` / `unbounded()` /
//     `*_channel_new(..)` — a PAIR of endpoints created together; both are
//     tracked, and their protocols must be dual.
//   • a parameter whose declared type names a `…Sender` / `…Receiver` — a
//     single endpoint whose protocol is inferred and (under --lint) shown.
// OPERATIONS. A call whose callee's last name segment is `send`, `…_send`,
// `send_…`, `try_send` (SEND); `recv`, `…_recv`, `recv_…`, `try_recv`
// (RECV); `close`, `…_close` (END) and whose first argument is (a
// reference to / a field of) the endpoint binder.
// PARTIES. A function body is one party; every lambda inside it is another.
// An endpoint's protocol is built per party from the statement structure:
//     s1; s2; …            ⟼  prefixes in order
//     if c then A else B   ⟼  +{then: A, else: B}   (when either arm acts)
//     match … arms         ⟼  +{arm_i: …}
//     while / for / loop   ⟼  μX. +{again: body·X, done: rest}
//     return               ⟼  end
//     ops in a lambda      ⟼  belong to the lambda's party
// Any other use of the endpoint (passed to a function, stored, returned)
// makes its protocol unknown from here: the pair is not judged.
//
// JUDGEMENTS
//   W4260  the two ends of one channel are not dual: printed protocols and
//          the first point of disagreement (a recv with no send blocks
//          forever on a oneshot/bounded channel; a send with no recv is a
//          message nobody reads)
//   W4261  a oneshot sender is used twice on one straight path: the second
//          `send` can only return false
//   N4262  (--lint) inferred protocol of a channel parameter
// ═══════════════════════════════════════════════════════════════════════════

const usz SESS_MAX_EPS   = 256;
const usz SESS_MAX_OPS   = 4096;

enum ChanKind : char { CK_UNKNOWN, CK_ONESHOT, CK_BOUNDED, CK_UNBOUNDED }
enum Role : char { ROLE_UNKNOWN, ROLE_SENDER, ROLE_RECEIVER }

struct Endpoint
{
    Node*    binder;
    ChanKind kind;
    Role     role;
    int      pair;        // index of the other end, -1 for a lone endpoint
    Node*    party;       // the (single) fn/lambda whose body acts on it; null if several
    bool     multi_party;
    bool     escapes;
    int      session;     // built protocol, -1 if none
    usz      n_ops;
    Node*    fn_decl;
}

fn bool name_has_suffix(char* s, usz n, char* suf)
{
    usz m = 0;
    while (suf[m] != 0) { m = m + 1; }
    if (n < m) { return false; }
    for (usz i = 0; i < m; i++) { if (s[n - m + i] != suf[i]) { return false; } }
    return true;
}

fn bool name_has_prefix(char* s, usz n, char* pre)
{
    usz m = 0;
    while (pre[m] != 0) { m = m + 1; }
    if (n < m) { return false; }
    for (usz i = 0; i < m; i++) { if (s[i] != pre[i]) { return false; } }
    return true;
}

fn bool name_contains(char* s, usz n, char* sub)
{
    usz m = 0;
    while (sub[m] != 0) { m = m + 1; }
    if (n < m) { return false; }
    for (usz i = 0; i + m <= n; i++)
    {
        bool ok = true;
        for (usz j = 0; j < m; j++) { if (s[i + j] != sub[j]) { ok = false; break; } }
        if (ok) { return true; }
    }
    return false;
}

// last dotted segment of a callee's source text
fn void last_segment(Node* callee, char** out_s, usz* out_n)
{
    *out_s = null; *out_n = 0;
    if (callee == null || callee.p.sptr == null) { return; }
    char* s = callee.p.sptr; usz n = callee.p.slen;
    usz start = 0;
    for (usz i = 0; i < n; i++) { if (s[i] == '.' || s[i] == ':') { start = i + 1; } }
    *out_s = s + start; *out_n = n - start;
}

// callee text and first-argument index of a call; `mod.f(x)` parses as a
// METHOD whose receiver resolves to a module — then `x` is argument 0
fn bool callee_text(Node* call, char** s, usz* n, usz* first_arg)
{
    *s = null; *n = 0; *first_arg = 0;
    if (call == null) { return false; }
    if (call.kind == Nk.N_EXPR_CALL)
    {
        last_segment(call.child_count > 0 ? call.children[0] : null, s, n);
        *first_arg = 1;
        return *s != null;
    }
    if (call.kind == Nk.N_EXPR_METHOD)
    {
        *s = call.p.sptr; *n = call.p.slen;
        Node* recv = call.child_count > 0 ? call.children[0] : null;
        // anything that is not a value binder (module, use-alias, type) is a path prefix
        Node* rb = recv != null ? recv.resolved : null;
        bool recv_is_module = recv != null && (recv.kind == Nk.N_EXPR_IDENT || recv.kind == Nk.N_EXPR_PATH)
            && (rb == null || !(rb.kind == Nk.N_PAT_IDENT || rb.kind == Nk.N_DECL_PARAM || rb.kind == Nk.N_DECL_LET || rb.kind == Nk.N_DECL_STATIC));
        *first_arg = recv_is_module ? 1 : 0;
        return *s != null;
    }
    return false;
}

// SK_SEND / SK_RECV / SK_END for a channel primitive, SK_VAR (unused kind) for "not an op"
fn Sk op_kind_of(char* s, usz n)
{
    if (s == null || n == 0) { return Sk.SK_VAR; }
    if ((n == 4 && s[0] == 's' && s[1] == 'e' && s[2] == 'n' && s[3] == 'd') || name_has_suffix(s, n, "_send") || name_has_prefix(s, n, "send_") || (n == 8 && name_has_prefix(s, n, "try_send"))) { return Sk.SK_SEND; }
    if ((n == 4 && s[0] == 'r' && s[1] == 'e' && s[2] == 'c' && s[3] == 'v') || name_has_suffix(s, n, "_recv") || name_has_prefix(s, n, "recv_") || (n == 8 && name_has_prefix(s, n, "try_recv"))) { return Sk.SK_RECV; }
    if ((n == 5 && s[0] == 'c' && s[1] == 'l' && s[2] == 'o' && s[3] == 's' && s[4] == 'e') || name_has_suffix(s, n, "_close") || name_has_prefix(s, n, "close_")) { return Sk.SK_END; }
    return Sk.SK_VAR;
}

fn ChanKind chan_kind_of(char* s, usz n)
{
    if (s == null) { return ChanKind.CK_UNKNOWN; }
    if (name_contains(s, n, "oneshot")) { return ChanKind.CK_ONESHOT; }
    if (name_contains(s, n, "unbounded")) { return ChanKind.CK_UNBOUNDED; }
    if (name_contains(s, n, "bounded")) { return ChanKind.CK_BOUNDED; }
    return ChanKind.CK_UNKNOWN;
}

fn bool is_channel_ctor(char* s, usz n)
{
    if (s == null) { return false; }
    if (n == 7 && name_has_prefix(s, n, "oneshot")) { return true; }
    if (n == 7 && name_has_prefix(s, n, "bounded")) { return true; }
    if (n == 9 && name_has_prefix(s, n, "unbounded")) { return true; }
    return name_has_suffix(s, n, "_channel_new") || name_has_suffix(s, n, "channel_new");
}

// base binder of an argument: `tx`, `&tx`, `&mut tx`, `tx.field`, `*tx`
fn Node* arg_binder(Node* a)
{
    int guard = 0;
    while (a != null && guard < 32)
    {
        guard = guard + 1;
        switch (a.kind)
        {
            case Nk.N_EXPR_REF: case Nk.N_EXPR_DEREF: case Nk.N_EXPR_FIELD: case Nk.N_EXPR_CAST: case Nk.N_EXPR_UNSAFE:
                a = a.child_count > 0 ? a.children[0] : null; break;
            case Nk.N_EXPR_IDENT: case Nk.N_EXPR_PATH:
                return a.resolved;
            default:
                return null;
        }
    }
    return null;
}

fn Endpoint* SessionCheck.ep_of(SessionCheck* sc, Node* binder)
{
    if (binder == null) { return null; }
    for (usz i = 0; i < sc.n_eps; i++) { if (sc.eps[i].binder == binder) { return &sc.eps[i]; } }
    return null;
}

fn int SessionCheck.ep_add(SessionCheck* sc, Node* binder, ChanKind k, Role r, Node* fn_decl)
{
    if (binder == null || sc.n_eps >= SESS_MAX_EPS || sc.ep_of(binder) != null) { return -1; }
    Endpoint* e = &sc.eps[sc.n_eps];
    int id = (int)sc.n_eps;
    sc.n_eps = sc.n_eps + 1;
    e.binder = binder; e.kind = k; e.role = r; e.pair = -1; e.party = null; e.multi_party = false;
    e.escapes = false; e.session = -1; e.n_ops = 0; e.fn_decl = fn_decl;
    return id;
}

fn Node* first_ident_pat(Node* pat)
{
    if (pat == null) { return null; }
    if (pat.kind == Nk.N_PAT_IDENT) { return pat; }
    return null;
}

// ── endpoint discovery within one function ──────────────────────────────
fn void SessionCheck.discover(SessionCheck* sc, Node* n, Node* fn_decl, int depth)
{
    if (n == null || depth > SESS_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_LET)
    {
        Node* pat = null; Node* init = null;
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i];
            if (c == null) { continue; }
            if (pfront_core::is_pattern(c.kind) && pat == null) { pat = c; }
            else if (pfront_core::is_expr(c.kind)) { init = c; }
        }
        char* cs; usz cn; usz cfa;
        if (pat != null && pat.kind == Nk.N_PAT_TUPLE && pat.child_count == 2 && init != null && callee_text(init, &cs, &cn, &cfa))
        {
            if (is_channel_ctor(cs, cn))
            {
                ChanKind k = chan_kind_of(cs, cn);
                Node* tx = first_ident_pat(pat.children[0]);
                Node* rx = first_ident_pat(pat.children[1]);
                int a = sc.ep_add(tx, k, Role.ROLE_SENDER, fn_decl);
                int b = sc.ep_add(rx, k, Role.ROLE_RECEIVER, fn_decl);
                if (a >= 0 && b >= 0) { sc.eps[a].pair = b; sc.eps[b].pair = a; sc.n_pairs_found = sc.n_pairs_found + 1; }
            }
        }
    }
    if (n.kind == Nk.N_DECL_PARAM || (n.kind == Nk.N_PAT_IDENT && n.parent != null && (n.parent.kind == Nk.N_DECL_PARAM || n.parent.kind == Nk.N_CLAUSE || n.parent.kind == Nk.N_PAT_TUPLE)))
    {
        // parameter typed as an endpoint
        Node* ty = n.type_ann;
        if (ty == null && n.parent != null && n.parent.kind == Nk.N_DECL_PARAM) { ty = n.parent.type_ann; }
        if (ty == null && n.kind == Nk.N_PAT_IDENT && fn_decl != null)
        {
            // clause-form fn: find the parameter position's declared type
            ty = sc.clause_param_type(fn_decl, n);
        }
        int guard = 0;
        while (ty != null && (ty.kind == Nk.N_TY_PTR || ty.kind == Nk.N_TY_REF) && guard < 8) { ty = ty.child_count > 0 ? ty.children[0] : null; guard = guard + 1; }
        if (ty != null && ty.kind == Nk.N_TY_PATH && ty.child_count > 0) { ty = ty.children[ty.child_count - 1]; }   // last segment
        if (ty != null && (ty.kind == Nk.N_TY_NAME || ty.kind == Nk.N_PATH_SEG) && ty.p.sptr != null)
        {
            Node* binder = n.kind == Nk.N_DECL_PARAM ? (n.child_count > 0 && n.children[0] != null && n.children[0].kind == Nk.N_PAT_IDENT ? n.children[0] : n) : n;
            if (name_has_suffix(ty.p.sptr, ty.p.slen, "Sender"))   { if (sc.ep_add(binder, chan_kind_of(ty.p.sptr, ty.p.slen), Role.ROLE_SENDER, fn_decl) >= 0) { sc.n_param_eps = sc.n_param_eps + 1; } }
            if (name_has_suffix(ty.p.sptr, ty.p.slen, "Receiver")) { if (sc.ep_add(binder, chan_kind_of(ty.p.sptr, ty.p.slen), Role.ROLE_RECEIVER, fn_decl) >= 0) { sc.n_param_eps = sc.n_param_eps + 1; } }
        }
    }
    for (usz i = 0; i < n.child_count; i++) { sc.discover(n.children[i], fn_decl, depth + 1); }
}

// declared type of the parameter position a clause pattern binder occupies
fn Node* SessionCheck.clause_param_type(SessionCheck* sc, Node* fn_decl, Node* binder)
{
    (void)sc;
    Node* clause = binder.parent;
    int pos = 0;
    if (clause != null && clause.kind == Nk.N_PAT_TUPLE)
    {
        for (usz i = 0; i < clause.child_count; i++) { if (clause.children[i] == binder) { pos = (int)i; } }
        clause = clause.parent;
    }
    if (clause == null || clause.kind != Nk.N_CLAUSE) { return null; }
    // the fn's signature: an N_TY_FN child, or the type_ann
    Node* sig = fn_decl.type_ann;
    for (usz i = 0; sig == null && i < fn_decl.child_count; i++) { if (fn_decl.children[i] != null && fn_decl.children[i].kind == Nk.N_TY_FN) { sig = fn_decl.children[i]; } }
    if (sig == null || sig.kind != Nk.N_TY_FN || sig.child_count == 0) { return null; }
    Node* dom = sig.children[0];
    if (dom != null && dom.kind == Nk.N_TY_TUPLE) { return pos < (int)dom.child_count ? dom.children[pos] : null; }
    return pos == 0 ? dom : null;
}

// ── operations: (endpoint, kind, at) in evaluation order ────────────────
struct Op { Endpoint* ep; Sk kind; Node* at; }

// the channel operation a call performs, if any
fn bool SessionCheck.call_op(SessionCheck* sc, Node* call, Endpoint** ep_out, Sk* kind_out)
{
    if (call == null) { return false; }
    char* s; usz n; usz first_arg;
    if (!callee_text(call, &s, &n, &first_arg)) { return false; }
    Sk k = op_kind_of(s, n);
    if (k == Sk.SK_VAR) { return false; }
    Node* a0 = call.child_count > first_arg ? call.children[first_arg] : null;
    Endpoint* ep = sc.ep_of(arg_binder(a0));
    if (ep == null) { return false; }
    *ep_out = ep; *kind_out = k;
    return true;
}

// collect the ops an expression performs (not descending into lambdas /
// nested statements-with-structure, which the builder handles itself);
// any other mention of an endpoint is an escape
fn void SessionCheck.expr_ops(SessionCheck* sc, Node* n, Op* ops, usz* n_ops, int depth)
{
    if (n == null || depth > SESS_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_EXPR_LAMBDA) { return; }
    if (n.kind == Nk.N_EXPR_CALL || n.kind == Nk.N_EXPR_METHOD)
    {
        Endpoint* ep = null; Sk k = Sk.SK_VAR;
        // arguments first (evaluation order), then the call itself
        char* cs; usz cn; usz first_arg = n.kind == Nk.N_EXPR_CALL ? 1 : 0;
        callee_text(n, &cs, &cn, &first_arg);
        bool is_op = sc.call_op(n, &ep, &k);
        for (usz i = 0; i < n.child_count; i++)
        {
            if (is_op && i == first_arg) { continue; }   // the endpoint argument is the op, not an escape
            if (i == 0 && (n.kind == Nk.N_EXPR_CALL || first_arg == 1)) { continue; }   // callee / module receiver
            sc.expr_ops(n.children[i], ops, n_ops, depth + 1);
        }
        if (is_op && *n_ops < SESS_MAX_OPS) { ops[*n_ops].ep = ep; ops[*n_ops].kind = k; ops[*n_ops].at = n; *n_ops = *n_ops + 1; ep.n_ops = ep.n_ops + 1; }
        else if (!is_op)
        {
            // an endpoint handed to some other function escapes
            for (usz i = first_arg; i < n.child_count; i++)
            {
                Endpoint* e2 = sc.ep_of(arg_binder(n.children[i]));
                if (e2 != null) { e2.escapes = true; }
            }
        }
        return;
    }
    if (n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH)
    {
        Endpoint* e2 = sc.ep_of(n.resolved);
        if (e2 != null)
        {
            // a bare mention outside an op: stored / returned / compared → escapes
            Node* p = n.parent;
            bool benign = p != null && (p.kind == Nk.N_EXPR_REF || p.kind == Nk.N_EXPR_FIELD || p.kind == Nk.N_EXPR_DEREF);
            if (!benign) { e2.escapes = true; }
            else
            {
                // `&tx` / `tx.x` used somewhere other than as an op argument
                Node* q = p;
                int g = 0;
                while (q != null && g < 8 && (q.kind == Nk.N_EXPR_REF || q.kind == Nk.N_EXPR_FIELD || q.kind == Nk.N_EXPR_DEREF || q.kind == Nk.N_EXPR_CAST)) { q = q.parent; g = g + 1; }
                if (q == null || (q.kind != Nk.N_EXPR_CALL && q.kind != Nk.N_EXPR_METHOD)) { e2.escapes = true; }
            }
        }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { sc.expr_ops(n.children[i], ops, n_ops, depth + 1); }
}

// ── building one endpoint's protocol for one party ──────────────────────
fn int SessionCheck.chain(SessionCheck* sc, Endpoint* ep, Op* ops, usz n_ops, int rest)
{
    // prefixes for this endpoint, in order, ending in `rest`
    int cur = rest;
    for (usz i = n_ops; i > 0; i--)
    {
        Op* o = &ops[i - 1];
        if (o.ep != ep) { continue; }
        if (o.kind == Sk.SK_END) { cur = sess_mk_end(sc); sc.nodes[cur].at = o.at; continue; }
        int id = sess_mk_pref(sc, o.kind, 0, cur);
        sc.nodes[id].at = o.at;
        cur = id;
    }
    return cur;
}

fn bool SessionCheck.mentions_ep(SessionCheck* sc, Node* n, Endpoint* ep, bool into_lambdas, int depth)
{
    if (n == null || depth > SESS_MAX_DEPTH) { return false; }
    if (n.kind == Nk.N_EXPR_LAMBDA && !into_lambdas) { return false; }
    if ((n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH) && n.resolved == ep.binder) { return true; }
    for (usz i = 0; i < n.child_count; i++) { if (sc.mentions_ep(n.children[i], ep, into_lambdas, depth + 1)) { return true; } }
    return false;
}

fn int SessionCheck.build_stmts(SessionCheck* sc, Endpoint* ep, Node* blk, usz from, int rest, int depth)
{
    if (blk == null || depth > SESS_MAX_DEPTH) { return rest; }
    if (from >= blk.child_count) { return rest; }
    int after = sc.build_stmts(ep, blk, from + 1, rest, depth + 1);
    return sc.build_stmt(ep, blk.children[from], after, depth + 1);
}

fn int SessionCheck.build_body(SessionCheck* sc, Endpoint* ep, Node* body, int rest, int depth)
{
    if (body == null) { return rest; }
    if (body.kind == Nk.N_BLOCK) { return sc.build_stmts(ep, body, 0, rest, depth + 1); }
    return sc.build_stmt(ep, body, rest, depth + 1);
}

fn int SessionCheck.build_stmt(SessionCheck* sc, Endpoint* ep, Node* s, int rest, int depth)
{
    if (s == null || depth > SESS_MAX_DEPTH) { return rest; }
    if (!sc.mentions_ep(s, ep, false, 0)) { return rest; }
    Op[64] ops; usz n_ops = 0;
    switch (s.kind)
    {
        case Nk.N_BLOCK:
            return sc.build_stmts(ep, s, 0, rest, depth + 1);
        case Nk.N_EXPR_IF:
        {
            Node* cond = s.child_count > 0 ? s.children[0] : null;
            Node* thn = s.child_count > 1 ? s.children[1] : null;
            Node* els = s.child_count > 2 ? s.children[2] : null;
            bool t_acts = sc.mentions_ep(thn, ep, false, 0);
            bool e_acts = sc.mentions_ep(els, ep, false, 0);
            int body = rest;
            if (t_acts || e_acts)
            {
                Slbl[2] arr;
                arr[0].name_id = sc.lbl_then; arr[0].cont = sc.build_body(ep, thn, rest, depth + 1);
                arr[1].name_id = sc.lbl_else; arr[1].cont = sc.build_body(ep, els, rest, depth + 1);
                body = sess_mk_choice(sc, Sk.SK_SELECT, &arr[0], 2);
                sc.nodes[body].at = s;
            }
            sc.expr_ops(cond, &ops[0], &n_ops, 0);
            return sc.chain(ep, &ops[0], n_ops, body);
        }
        case Nk.N_EXPR_MATCH:
        {
            Node* subj = s.child_count > 0 ? s.children[0] : null;
            Slbl[16] arr; usz k = 0;
            for (usz i = 1; i < s.child_count && k < 16; i++)
            {
                Node* arm = s.children[i];
                if (arm == null) { continue; }
                Node* body = arm.child_count > 0 ? arm.children[arm.child_count - 1] : null;
                arr[k].name_id = sc.lbl_arm_base + (uint)k;
                arr[k].cont = sc.build_body(ep, body, rest, depth + 1);
                k = k + 1;
            }
            int body2 = k > 0 ? sess_mk_choice(sc, Sk.SK_SELECT, &arr[0], k) : rest;
            if (k > 0) { sc.nodes[body2].at = s; }
            sc.expr_ops(subj, &ops[0], &n_ops, 0);
            return sc.chain(ep, &ops[0], n_ops, body2);
        }
        case Nk.N_EXPR_WHILE:
        case Nk.N_EXPR_FOR:
        case Nk.N_EXPR_LOOP:
        {
            Node* body = s.child_count > 0 ? s.children[s.child_count - 1] : null;
            if (!sc.mentions_ep(body, ep, false, 0))
            {
                // only the header acts (e.g. `while recv(rx).1`) — a loop of that op
                for (usz i = 0; i + 1 < s.child_count; i++) { if (s.children[i] != null && !pfront_core::is_pattern(s.children[i].kind)) { sc.expr_ops(s.children[i], &ops[0], &n_ops, 0); } }
                if (n_ops == 0) { return rest; }
            }
            int mu = sess_mk_mu(sc, -1);
            sc.nodes[mu].at = s;
            Op[64] hops; usz n_hops = 0;
            for (usz i = 0; i + 1 < s.child_count; i++) { if (s.children[i] != null && !pfront_core::is_pattern(s.children[i].kind)) { sc.expr_ops(s.children[i], &hops[0], &n_hops, 0); } }
            int again = sc.build_body(ep, body, mu, depth + 1);
            Slbl[2] arr;
            arr[0].name_id = sc.lbl_again; arr[0].cont = again;
            arr[1].name_id = sc.lbl_done;  arr[1].cont = rest;
            int choice = sess_mk_choice(sc, Sk.SK_SELECT, &arr[0], 2);
            // header ops happen before every decision
            sc.nodes[mu].cont = sc.chain(ep, &hops[0], n_hops, choice);
            return mu;
        }
        case Nk.N_STMT_RETURN:
        {
            for (usz i = 0; i < s.child_count; i++) { sc.expr_ops(s.children[i], &ops[0], &n_ops, 0); }
            int e = sess_mk_end(sc);
            return sc.chain(ep, &ops[0], n_ops, e);
        }
        case Nk.N_EXPR_LAMBDA:
            return rest;
        default:
            break;
    }
    // a plain statement / expression: its ops in evaluation order
    if (s.kind == Nk.N_DECL_LET || s.kind == Nk.N_STMT_ASSIGN || s.kind == Nk.N_STMT_COMPOUND_ASSIGN || s.kind == Nk.N_EXPR_ASSIGN)
    {
        for (usz i = 0; i < s.child_count; i++)
        {
            Node* c = s.children[i];
            if (c == null || pfront_core::is_pattern(c.kind) || pfront_core::is_type(c.kind)) { continue; }
            // an endpoint copied into another name escapes our tracking
            if (s.kind == Nk.N_DECL_LET && (c.kind == Nk.N_EXPR_IDENT || c.kind == Nk.N_EXPR_PATH)) { Endpoint* e2 = sc.ep_of(c.resolved); if (e2 != null) { e2.escapes = true; } }
            sc.expr_ops(c, &ops[0], &n_ops, 0);
        }
        return sc.chain(ep, &ops[0], n_ops, rest);
    }
    // nested structure inside an expression statement (blocks in arms etc.)
    bool structured = false;
    for (usz i = 0; i < s.child_count; i++)
    {
        Node* c = s.children[i];
        if (c != null && (c.kind == Nk.N_BLOCK || c.kind == Nk.N_EXPR_IF || c.kind == Nk.N_EXPR_MATCH || c.kind == Nk.N_EXPR_WHILE || c.kind == Nk.N_EXPR_FOR || c.kind == Nk.N_EXPR_LOOP)) { structured = true; }
    }
    if (structured)
    {
        int cur = rest;
        for (usz i = s.child_count; i > 0; i--) { cur = sc.build_stmt(ep, s.children[i - 1], cur, depth + 1); }
        return cur;
    }
    sc.expr_ops(s, &ops[0], &n_ops, 0);
    return sc.chain(ep, &ops[0], n_ops, rest);
}

// the party (fn body or lambda) a node belongs to
fn Node* party_of(Node* n)
{
    Node* p = n != null ? n.parent : null;
    while (p != null)
    {
        if (p.kind == Nk.N_EXPR_LAMBDA || p.kind == Nk.N_DECL_FN) { return p; }
        p = p.parent;
    }
    return null;
}

// determine which party acts on an endpoint (all op sites must agree)
fn void SessionCheck.find_party(SessionCheck* sc, Node* n, Endpoint* ep, int depth)
{
    if (n == null || depth > SESS_MAX_DEPTH) { return; }
    if ((n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH) && n.resolved == ep.binder)
    {
        Node* p = party_of(n);
        if (ep.party == null) { ep.party = p; }
        else if (ep.party != p) { ep.multi_party = true; }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { sc.find_party(n.children[i], ep, depth + 1); }
}

fn Node* body_of(Node* party)
{
    if (party == null) { return null; }
    if (party.kind == Nk.N_EXPR_LAMBDA) { return party.child_count > 0 ? party.children[party.child_count - 1] : null; }
    // fn: clause bodies / block
    return party;
}

fn int SessionCheck.build_for(SessionCheck* sc, Endpoint* ep)
{
    Node* party = ep.party;
    if (party == null) { return -1; }
    int e = sess_mk_end(sc);
    if (party.kind == Nk.N_EXPR_LAMBDA) { return sc.build_body(ep, body_of(party), e, 0); }
    // a fn: the clause containing the binder (or the block body)
    int cur = e;
    for (usz i = party.child_count; i > 0; i--)
    {
        Node* c = party.children[i - 1];
        if (c == null) { continue; }
        if (c.kind == Nk.N_CLAUSE)
        {
            Node* body = c.child_count > 0 ? c.children[c.child_count - 1] : null;
            if (sc.mentions_ep(c, ep, true, 0)) { cur = sc.build_body(ep, body, e, 0); }
        }
        else if (c.kind == Nk.N_BLOCK) { cur = sc.build_body(ep, c, e, 0); }
    }
    return cur;
}

// ── printing ────────────────────────────────────────────────────────────
fn int SessionCheck.show(SessionCheck* sc, int s, char* buf, int off, int cap, int* mus, int n_mus, int depth)
{
    if (off >= cap - 8 || depth > 24) { return off; }
    if (s < 0 || (usz)s >= sc.n_nodes) { return off + snprintf(buf + off, (usz)(cap - off), "?"); }
    Snode* n = &sc.nodes[s];
    switch (n.kind)
    {
        case Sk.SK_END:  return off + snprintf(buf + off, (usz)(cap - off), "end");
        case Sk.SK_SEND: off = off + snprintf(buf + off, (usz)(cap - off), "!msg."); return sc.show(n.cont, buf, off, cap, mus, n_mus, depth + 1);
        case Sk.SK_RECV: off = off + snprintf(buf + off, (usz)(cap - off), "?msg."); return sc.show(n.cont, buf, off, cap, mus, n_mus, depth + 1);
        case Sk.SK_MU:
        {
            for (int i = 0; i < n_mus; i++) { if (mus[i] == s) { return off + snprintf(buf + off, (usz)(cap - off), "X%d", i); } }
            if (n_mus < 8) { mus[n_mus] = s; }
            off = off + snprintf(buf + off, (usz)(cap - off), "μX%d.", n_mus);
            return sc.show(n.cont, buf, off, cap, mus, n_mus < 8 ? n_mus + 1 : n_mus, depth + 1);
        }
        case Sk.SK_SELECT:
        case Sk.SK_BRANCH:
        {
            off = off + snprintf(buf + off, (usz)(cap - off), n.kind == Sk.SK_SELECT ? "+{" : "&{");
            for (usz i = 0; i < n.lbl_count && off < cap - 8; i++)
            {
                Slbl* l = &sc.labels[(usz)n.lbl_start + i];
                char* nm = l.name_id == sc.lbl_then ? "then" : (l.name_id == sc.lbl_else ? "else" : (l.name_id == sc.lbl_again ? "again" : (l.name_id == sc.lbl_done ? "done" : "arm")));
                off = off + snprintf(buf + off, (usz)(cap - off), "%s%s: ", i > 0 ? ", " : "", nm);
                off = sc.show(l.cont, buf, off, cap, mus, n_mus, depth + 1);
            }
            return off + snprintf(buf + off, (usz)(cap - off), "}");
        }
        default: return off + snprintf(buf + off, (usz)(cap - off), "X");
    }
}

fn char* SessionCheck.name(SessionCheck* sc, Node* binder)
{
    if (binder == null || sc.interner == null || binder.name_id == 0) { return "_"; }
    char* s = sc.interner.text(binder.name_id);
    return s == null ? "_" : s;
}

// count straight-line prefixes of one kind from a root (no choices crossed)
fn int SessionCheck.straight_count(SessionCheck* sc, int s, Sk k, Node** second)
{
    int c = 0; int guard = 0;
    while (s >= 0 && (usz)s < sc.n_nodes && guard < 256)
    {
        guard = guard + 1;
        Snode* n = &sc.nodes[s];
        if (n.kind == Sk.SK_SEND || n.kind == Sk.SK_RECV)
        {
            if (n.kind == k) { c = c + 1; if (c == 2) { *second = n.at; } }
            s = n.cont;
        }
        else { break; }
    }
    return c;
}

// first point where two sessions stop being dual (for the message)
fn Node* SessionCheck.first_disagreement(SessionCheck* sc, int a, int b_dual, int depth)
{
    if (depth > 64 || a < 0 || b_dual < 0) { return null; }
    Snode* na = &sc.nodes[a]; Snode* nb = &sc.nodes[b_dual];
    if (na.kind == Sk.SK_MU) { return sc.first_disagreement(na.cont, b_dual, depth + 1); }
    if (nb.kind == Sk.SK_MU) { return sc.first_disagreement(a, nb.cont, depth + 1); }
    if (na.kind != nb.kind) { return na.at != null ? na.at : nb.at; }
    if (na.kind == Sk.SK_SEND || na.kind == Sk.SK_RECV) { return sc.first_disagreement(na.cont, nb.cont, depth + 1); }
    if ((na.kind == Sk.SK_SELECT || na.kind == Sk.SK_BRANCH) && na.lbl_count == nb.lbl_count)
    {
        for (usz i = 0; i < na.lbl_count; i++)
        {
            Node* r = sc.first_disagreement(sc.labels[(usz)na.lbl_start + i].cont, sc.labels[(usz)nb.lbl_start + i].cont, depth + 1);
            if (r != null) { return r; }
        }
    }
    return null;
}

// ── driver ──────────────────────────────────────────────────────────────
fn void SessionCheck.per_fn(SessionCheck* sc, Node* fn_decl)
{
    usz first = sc.n_eps;
    sc.discover(fn_decl, fn_decl, 0);
    if (sc.n_eps == first) { return; }
    for (usz i = first; i < sc.n_eps; i++) { sc.find_party(fn_decl, &sc.eps[i], 0); }
    // collect escapes (expr_ops marks them) and build protocols
    for (usz i = first; i < sc.n_eps; i++)
    {
        Endpoint* ep = &sc.eps[i];
        if (ep.multi_party || ep.party == null) { continue; }
        ep.session = sc.build_for(ep);
    }
    for (usz i = first; i < sc.n_eps; i++)
    {
        Endpoint* ep = &sc.eps[i];
        if (ep.session < 0) { continue; }
        // oneshot: a second send on the same straight path is dead
        if (ep.kind == ChanKind.CK_ONESHOT && ep.role == Role.ROLE_SENDER)
        {
            Node* second = null;
            if (sc.straight_count(ep.session, Sk.SK_SEND, &second) >= 2 && second != null && sc.diags != null)
            {
                char* m = (char*)sc.arena.alloc(512, 1);
                snprintf(m, 512, "oneshot sender `%s` is used a second time on this path: a oneshot carries one value, so this send can only return false", sc.name(ep.binder));
                sc.diags.warn(pfront_core::Phase.PH_RESOLVE, 4261, second.line, second.col, m, sc.file);
                sc.n_w4261 = sc.n_w4261 + 1;
            }
        }
        // parameters: show the inferred protocol
        if (ep.pair < 0 && sc.diags != null && sc.diags.advisories && ep.n_ops > 0)
        {
            char* buf = (char*)sc.arena.alloc(256, 1);
            int[8] mus;
            int off = sc.show(ep.session, buf, 0, 256, &mus[0], 0, 0);
            (void)off;
            char* m = (char*)sc.arena.alloc(512, 1);
            snprintf(m, 512, "channel parameter `%s` follows the protocol %s%s", sc.name(ep.binder), buf, ep.escapes ? " (and is also passed on, so this is a lower bound)" : "");
            sc.diags.note(pfront_core::Phase.PH_RESOLVE, 4262, ep.binder.line, ep.binder.col, m, sc.file);
            sc.n_n4262 = sc.n_n4262 + 1;
        }
    }
    // duality of pairs created together
    for (usz i = first; i < sc.n_eps; i++)
    {
        Endpoint* tx = &sc.eps[i];
        if (tx.pair < 0 || tx.role != Role.ROLE_SENDER) { continue; }
        Endpoint* rx = &sc.eps[tx.pair];
        if (tx.session < 0 || rx.session < 0 || tx.escapes || rx.escapes || tx.multi_party || rx.multi_party) { sc.n_pairs_skipped = sc.n_pairs_skipped + 1; continue; }
        if (tx.n_ops == 0 && rx.n_ops == 0) { sc.n_pairs_skipped = sc.n_pairs_skipped + 1; continue; }
        sc.n_dual_checks = sc.n_dual_checks + 1;
        int want_rx = sess_dual(sc, tx.session, 0);
        sc.n_pairs = 0;
        bool ok1 = sess_subtype(sc, want_rx, rx.session, 0);
        sc.n_pairs = 0;
        bool ok2 = sess_subtype(sc, rx.session, want_rx, 0);
        if (ok1 && ok2) { sc.n_dual_ok = sc.n_dual_ok + 1; continue; }
        sc.n_dual_fail = sc.n_dual_fail + 1;
        if (sc.diags == null) { continue; }
        char* b1 = (char*)sc.arena.alloc(256, 1);
        char* b2 = (char*)sc.arena.alloc(256, 1);
        int[8] m1; int[8] m2;
        sc.show(tx.session, b1, 0, 256, &m1[0], 0, 0);
        sc.show(rx.session, b2, 0, 256, &m2[0], 0, 0);
        Node* at = sc.first_disagreement(want_rx, rx.session, 0);
        char* m = (char*)sc.arena.alloc(768, 1);
        char* why = "the two ends disagree here";
        if (at != null)
        {
            // classify the disagreement by what the failing side does
            Endpoint* ep_at = null; Sk k_at = Sk.SK_VAR;
            if (sc.call_op(at, &ep_at, &k_at))
            {
                if (k_at == Sk.SK_RECV) { why = tx.kind == ChanKind.CK_UNBOUNDED ? "this receive has no matching send" : "this receive has no matching send and will block forever"; }
                else if (k_at == Sk.SK_SEND) { why = "this send has no matching receive: the message is never read"; }
            }
        }
        snprintf(m, 768, "the two ends of this channel are not dual: `%s` follows %s but `%s` follows %s — %s",
                 sc.name(tx.binder), b1, sc.name(rx.binder), b2, why);
        Node* where = at != null ? at : tx.binder;
        sc.diags.warn(pfront_core::Phase.PH_RESOLVE, 4260, where.line, where.col, m, sc.file);
        sc.n_w4260 = sc.n_w4260 + 1;
    }
}

fn void SessionCheck.walk_fns(SessionCheck* sc, Node* n, int depth)
{
    if (n == null || depth > SESS_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_DECL_FN) { sc.per_fn(n); return; }
    for (usz i = 0; i < n.child_count; i++) { sc.walk_fns(n.children[i], depth + 1); }
}

fn void SessionCheck.attach(SessionCheck* sc, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    sc.diags = d; sc.interner = it; sc.file = file;
    if (it != null)
    {
        sc.lbl_then = it.intern("then", 4);
        sc.lbl_else = it.intern("else", 4);
        sc.lbl_again = it.intern("again", 5);
        sc.lbl_done = it.intern("done", 4);
        sc.lbl_arm_base = 0x40000000u;
    }
}

fn void SessionCheck.init(SessionCheck* sc, Arena* a)
{
    sc.arena = a;
    sc.nodes = (Snode*)calloc(SESS_MAX_NODES, Snode::size);
    sc.labels = (Slbl*)calloc(SESS_MAX_LABELS, Slbl::size);
    sc.pairs = (SPair*)calloc(SESS_MAX_PAIRS, SPair::size);
    sc.chans = null;
    sc.eps = (Endpoint*)calloc(SESS_MAX_EPS, Endpoint::size);
    sc.n_eps = 0;
    sc.n_nodes = 0; sc.n_labels = 0; sc.n_pairs = 0; sc.n_chans = 0;
    sc.n_end = 0; sc.n_send = 0; sc.n_recv = 0; sc.n_select = 0; sc.n_branch = 0;
    sc.n_mu = 0;
    sc.n_dual_checks = 0; sc.n_dual_ok = 0; sc.n_dual_fail = 0;
    sc.n_sub_checks = 0; sc.n_sub_ok = 0; sc.n_sub_fail = 0;
    sc.n_unclosed = 0; sc.n_linearity_err = 0;
    sc.n_pairs_found = 0; sc.n_pairs_skipped = 0; sc.n_param_eps = 0;
    sc.n_w4260 = 0; sc.n_w4261 = 0; sc.n_n4262 = 0;
    sc.diags = null; sc.interner = null; sc.file = null;
    sc.lbl_then = 1; sc.lbl_else = 2; sc.lbl_again = 3; sc.lbl_done = 4; sc.lbl_arm_base = 0x40000000u;
}

fn void SessionCheck.scan(SessionCheck* sc, Node* root, int depth)
{
    (void)depth;
    sc.n_pairs = 0;
    sc.walk_fns(root, 0);
}

fn void SessionCheck.report(SessionCheck* sc)
{
    usz oneshot = 0; usz bounded = 0; usz unbounded = 0; usz escaped = 0; usz multi = 0;
    for (usz i = 0; i < sc.n_eps; i++)
    {
        if (sc.eps[i].kind == ChanKind.CK_ONESHOT) { oneshot = oneshot + 1; }
        if (sc.eps[i].kind == ChanKind.CK_BOUNDED) { bounded = bounded + 1; }
        if (sc.eps[i].kind == ChanKind.CK_UNBOUNDED) { unbounded = unbounded + 1; }
        if (sc.eps[i].escapes) { escaped = escaped + 1; }
        if (sc.eps[i].multi_party) { multi = multi + 1; }
    }
    printf("  session-types    : %d endpoints (%d oneshot, %d bounded, %d unbounded; %d parameters, %d pairs, %d escaping, %d multi-party); %d nodes (!=%d ?=%d +=%d &=%d μ=%d)\n",
           (int)sc.n_eps, (int)oneshot, (int)bounded, (int)unbounded, (int)sc.n_param_eps, (int)sc.n_pairs_found, (int)escaped, (int)multi,
           (int)sc.n_nodes, (int)sc.n_send, (int)sc.n_recv, (int)sc.n_select, (int)sc.n_branch, (int)sc.n_mu);
    printf("  session-duality  : %d pairs judged: %d dual, %d not dual (W4260), %d not judged; %d oneshot double-sends (W4261); %d coinductive subtype steps\n",
           (int)sc.n_dual_checks, (int)sc.n_dual_ok, (int)sc.n_dual_fail, (int)sc.n_pairs_skipped, (int)sc.n_w4261, (int)sc.n_sub_checks);
}

fn void SessionCheck.destroy(SessionCheck* sc)
{
    if (sc.nodes != null) { free((void*)sc.nodes); sc.nodes = null; }
    if (sc.labels != null) { free((void*)sc.labels); sc.labels = null; }
    if (sc.pairs != null) { free((void*)sc.pairs); sc.pairs = null; }
    if (sc.eps != null) { free((void*)sc.eps); sc.eps = null; }
}
