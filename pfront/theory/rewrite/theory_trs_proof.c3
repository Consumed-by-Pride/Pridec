// ============================================================================
// theory_trs_proof.c3 — termination and confluence for a rule set
// ----------------------------------------------------------------------------
// Companion to theory_trs.c3 (same module). theory_trs.c3 is the ENGINE:
// match, instantiate, normalise. This file is the THEORY: does the rule set
// terminate, and does the normal form depend on the order rules are tried?
//
// TERMINATION — lexicographic path order (LPO).
//   A rule l → r is oriented when l >lpo r under a strict precedence on
//   function symbols. LPO is a simplification order, so if EVERY rule is
//   oriented the system terminates, for any strategy, without fuel. The
//   precedence is not guessed at random: the rules themselves induce
//   constraints (root(l) > every symbol of r that is not root(l)); those
//   constraints are topologically sorted into ranks; if the constraint graph
//   has a cycle no LPO with that precedence exists and the rules that need
//   the cyclic edge stay unproven. Fuel still bounds the engine either way —
//   this proof upgrades "bounded" to "terminates", it never removes a bound.
//
// CONFLUENCE — critical pairs + Newman's lemma.
//   Two rules l1→r1, l2→r2 (variables renamed apart) overlap when l2 unifies
//   with a NON-VARIABLE subterm of l1 at position p. The critical pair is
//   ⟨r1σ, l1σ[r2σ]_p⟩ — the two one-step results from the same term. If the
//   system terminates and every critical pair is joinable (both sides reach
//   the same normal form) the system is confluent (Newman + the critical
//   pair lemma), so `|>` gives the same answer regardless of rule order.
//   A pair that is NOT joinable is a witness of non-confluence and is
//   reported with both sides printed. Overlaps that involve a GUARDED rule
//   are conditional pairs; joinability under a side condition is not
//   decided here, so such sets are reported as "not decided", never as
//   confluent.
//
// Everything here is bounded: unification is occurs-checked, instantiation
// is depth-capped, normalisation runs with a small private fuel budget.
// ============================================================================

module theory_trs;

import pfront_lex;
import pfront_core;
import theory_term;

// ── Function symbols ────────────────────────────────────────────────────────
// A symbol is the head of a non-variable term: (kind, op, name, literal).
const usz SYM_CAP = 512;
struct Sym
{
    int   kind;
    int   op;
    uint  name;
    long  lit;
    int   rank;     // precedence rank: larger = greater
}

struct SymTable
{
    Sym[SYM_CAP] syms;
    usz          count;
    // precedence constraint edges: gt[a] > gt_of[a]
    int[SYM_CAP * 4] edge_from;
    int[SYM_CAP * 4] edge_to;
    usz              edge_count;
    bool             cyclic;
}

fn void SymTable.init(SymTable* st)
{
    st.count = 0;
    st.edge_count = 0;
    st.cyclic = false;
}

fn bool sym_head(Node* n, Sym* out)
{
    if (n == null) { return false; }
    if (theory_term::is_pattern_var(n)) { return false; }
    Node* lit = n;
    if (n.kind == Nk.N_PAT_LITERAL && n.child_count > 0) { lit = n.children[0]; }
    out.kind = (int)n.kind;
    out.op = n.p.op;
    out.name = 0;
    out.lit = 0;
    out.rank = 0;
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
        case N_EXPR_BOOL:
            out.lit = (long)n.p.ival;
        case N_PAT_LITERAL:
            out.kind = (int)lit.kind;
            out.lit = (long)lit.p.ival;
        case N_EXPR_IDENT:
        case N_EXPR_METHOD:
        case N_EXPR_FIELD:
            out.name = n.name_id;
        case N_EXPR_CALL:
            if (n.child_count > 0 && n.children[0] != null
                && n.children[0].kind == Nk.N_EXPR_IDENT)
            {
                out.name = n.children[0].name_id;
            }
        default:
            break;
    }
    return true;
}

fn int SymTable.find_or_add(SymTable* st, Node* n)
{
    Sym s;
    if (!sym_head(n, &s)) { return -1; }
    for (usz i = 0; i < st.count; i++)
    {
        Sym* t = &st.syms[i];
        if (t.kind == s.kind && t.op == s.op && t.name == s.name && t.lit == s.lit)
        {
            return (int)i;
        }
    }
    if (st.count >= SYM_CAP) { return -1; }
    st.syms[st.count] = s;
    st.count = st.count + 1;
    return (int)(st.count - 1);
}

fn int SymTable.lookup(SymTable* st, Node* n)
{
    Sym s;
    if (!sym_head(n, &s)) { return -1; }
    for (usz i = 0; i < st.count; i++)
    {
        Sym* t = &st.syms[i];
        if (t.kind == s.kind && t.op == s.op && t.name == s.name && t.lit == s.lit)
        {
            return (int)i;
        }
    }
    return -1;
}

fn void SymTable.add_edge(SymTable* st, int from, int to)
{
    if (from < 0 || to < 0 || from == to) { return; }
    for (usz i = 0; i < st.edge_count; i++)
    {
        if (st.edge_from[i] == from && st.edge_to[i] == to) { return; }
    }
    if (st.edge_count >= SYM_CAP * 4) { return; }
    st.edge_from[st.edge_count] = from;
    st.edge_to[st.edge_count] = to;
    st.edge_count = st.edge_count + 1;
}

fn void SymTable.register_term(SymTable* st, Node* n, int depth)
{
    if (n == null || depth > TRS_MAX_DEPTH) { return; }
    st.find_or_add(n);
    bool is_call = n.kind == Nk.N_EXPR_CALL;
    for (usz i = 0; i < n.child_count; i++)
    {
        if (is_call && i == 0) { continue; }   // callee is part of the head
        st.register_term(n.children[i], depth + 1);
    }
}

// root(l) must exceed every OTHER symbol of r. This is the weakest set of
// precedence facts that lets LPO case (b) fire on the rule's root; a rule
// that can be oriented by the subterm case alone adds nothing.
fn void SymTable.constrain(SymTable* st, int root, Node* r, int depth)
{
    if (r == null || depth > TRS_MAX_DEPTH) { return; }
    int g = st.lookup(r);
    if (g >= 0 && g != root) { st.add_edge(root, g); }
    bool is_call = r.kind == Nk.N_EXPR_CALL;
    for (usz i = 0; i < r.child_count; i++)
    {
        if (is_call && i == 0) { continue; }
        st.constrain(root, r.children[i], depth + 1);
    }
}

// Kahn's algorithm. Ranks: sources (greatest symbols) get the highest
// rank. Symbols in a cycle keep rank 0 and are flagged.
fn void SymTable.assign_ranks(SymTable* st)
{
    int[SYM_CAP] indeg;
    for (usz i = 0; i < st.count; i++) { indeg[i] = 0; st.syms[i].rank = 0; }
    for (usz e = 0; e < st.edge_count; e++) { indeg[st.edge_to[e]] = indeg[st.edge_to[e]] + 1; }

    int[SYM_CAP] queue;
    int qh = 0;
    int qt = 0;
    for (usz i = 0; i < st.count; i++)
    {
        if (indeg[i] == 0) { queue[qt] = (int)i; qt = qt + 1; }
    }
    int level = (int)st.count + 1;
    usz done = 0;
    while (qh < qt)
    {
        int layer_end = qt;
        while (qh < layer_end)
        {
            int u = queue[qh];
            qh = qh + 1;
            st.syms[u].rank = level;
            done = done + 1;
            for (usz e = 0; e < st.edge_count; e++)
            {
                if (st.edge_from[e] != u) { continue; }
                int v = st.edge_to[e];
                indeg[v] = indeg[v] - 1;
                if (indeg[v] == 0) { queue[qt] = v; qt = qt + 1; }
            }
        }
        level = level - 1;
    }
    st.cyclic = done < st.count;
}

// f > g in the precedence. Symbols left at rank 0 (cyclic) compare as
// incomparable, so no rule can lean on a contradictory edge.
fn bool SymTable.prec_gt(SymTable* st, int f, int g)
{
    if (f < 0 || g < 0 || f == g) { return false; }
    int rf = st.syms[f].rank;
    int rg = st.syms[g].rank;
    if (rf == 0 || rg == 0) { return false; }
    return rf > rg;
}

// ── LPO ─────────────────────────────────────────────────────────────────────
fn bool var_occurs_in(Node* v, Node* t, int depth)
{
    if (t == null || depth > TRS_MAX_DEPTH) { return false; }
    if (theory_term::is_pattern_var(t) && t.name_id == v.name_id
        && t.kind != Nk.N_PAT_WILDCARD) { return true; }
    for (usz i = 0; i < t.child_count; i++)
    {
        if (var_occurs_in(v, t.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn bool lpo_ge(SymTable* st, Node* s, Node* t, int depth)
{
    if (theory_term::term_eq(s, t, 0)) { return true; }
    return lpo_gt(st, s, t, depth);
}

// Arguments of a term for ordering purposes: a call's callee is part of
// the head, not an argument.
fn usz lpo_argc(Node* n)
{
    if (n == null) { return 0; }
    if (n.kind == Nk.N_EXPR_CALL) { return n.child_count > 0 ? n.child_count - 1 : 0; }
    return n.child_count;
}
fn Node* lpo_arg(Node* n, usz i)
{
    if (n.kind == Nk.N_EXPR_CALL) { return n.children[i + 1]; }
    return n.children[i];
}

fn bool lpo_gt(SymTable* st, Node* s, Node* t, int depth)
{
    if (s == null || t == null || depth > 64) { return false; }
    // A variable is never greater than anything.
    if (theory_term::is_pattern_var(s)) { return false; }
    // (1) t is a variable occurring in s.
    if (theory_term::is_pattern_var(t))
    {
        if (t.kind == Nk.N_PAT_WILDCARD) { return false; }
        return var_occurs_in(t, s, 0);
    }
    // (2a) some argument of s is >= t.
    usz ns = lpo_argc(s);
    for (usz i = 0; i < ns; i++)
    {
        if (lpo_ge(st, lpo_arg(s, i), t, depth + 1)) { return true; }
    }
    int f = st.lookup(s);
    int g = st.lookup(t);
    if (f < 0 || g < 0) { return false; }
    usz nt = lpo_argc(t);
    // (2b) f > g and s > every argument of t.
    if (st.prec_gt(f, g))
    {
        for (usz j = 0; j < nt; j++)
        {
            if (!lpo_gt(st, s, lpo_arg(t, j), depth + 1)) { return false; }
        }
        return true;
    }
    // (2c) f == g: lexicographic on arguments, and s > every argument of t.
    if (f == g && ns == nt)
    {
        for (usz j = 0; j < nt; j++)
        {
            if (!lpo_gt(st, s, lpo_arg(t, j), depth + 1)) { return false; }
        }
        for (usz i = 0; i < ns; i++)
        {
            Node* a = lpo_arg(s, i);
            Node* b = lpo_arg(t, i);
            if (theory_term::term_eq(a, b, 0)) { continue; }
            return lpo_gt(st, a, b, depth + 1);
        }
        return false;   // identical argument lists: s == t
    }
    return false;
}

fn void RuleSet.prove_termination(RuleSet* rs, SymTable* st)
{
    st.init();
    for (usz i = 0; i < rs.count; i++)
    {
        st.register_term(rs.rules[i].lhs, 0);
        st.register_term(rs.rules[i].rhs, 0);
    }
    for (usz i = 0; i < rs.count; i++)
    {
        Rule* r = &rs.rules[i];
        int root = st.lookup(r.lhs);
        if (root < 0) { continue; }
        st.constrain(root, r.rhs, 0);
    }
    st.assign_ranks();

    rs.lpo_unproven = 0;
    rs.first_bad_rule = -1;
    for (usz i = 0; i < rs.count; i++)
    {
        Rule* r = &rs.rules[i];
        r.lpo_ok = lpo_gt(st, r.lhs, r.rhs, 0);
        if (!r.lpo_ok)
        {
            rs.lpo_unproven = rs.lpo_unproven + 1;
            if (rs.first_bad_rule < 0) { rs.first_bad_rule = (int)i; }
        }
    }
    rs.terminating = rs.count > 0 && rs.lpo_unproven == 0;
}

// ── Unification (two variable namespaces) ───────────────────────────────────
// Rule i's variables live on side 0, rule j's on side 1: that IS the
// renaming apart, without touching either pattern.
const usz UNIFY_CAP = 128;
struct UBind
{
    uint  vname;
    int   side;
    Node* term;
    int   term_side;
}
struct Unifier
{
    UBind[UNIFY_CAP] binds;
    usz              count;
    bool             overflow;
}

fn void Unifier.init(Unifier* u) { u.count = 0; u.overflow = false; }

fn int Unifier.find(Unifier* u, uint vname, int side)
{
    for (usz i = 0; i < u.count; i++)
    {
        if (u.binds[i].vname == vname && u.binds[i].side == side) { return (int)i; }
    }
    return -1;
}

fn bool is_real_var(Node* n)
{
    return n != null && theory_term::is_pattern_var(n) && n.kind != Nk.N_PAT_WILDCARD
        && n.name_id != 0;
}

// Follow bindings until a non-variable or an unbound variable.
fn void Unifier.deref(Unifier* u, Node** t, int* side)
{
    int hops = 0;
    while (is_real_var(*t) && hops < 64)
    {
        int b = u.find((*t).name_id, *side);
        if (b < 0) { return; }
        *t = u.binds[b].term;
        *side = u.binds[b].term_side;
        hops = hops + 1;
    }
}

fn bool Unifier.occurs(Unifier* u, uint vname, int side, Node* t, int tside, int depth)
{
    if (t == null || depth > TRS_MAX_DEPTH) { return false; }
    u.deref(&t, &tside);
    if (is_real_var(t)) { return t.name_id == vname && tside == side; }
    for (usz i = 0; i < t.child_count; i++)
    {
        if (u.occurs(vname, side, t.children[i], tside, depth + 1)) { return true; }
    }
    return false;
}

fn bool Unifier.bind(Unifier* u, uint vname, int side, Node* t, int tside)
{
    if (u.occurs(vname, side, t, tside, 0)) { return false; }
    if (u.count >= UNIFY_CAP) { u.overflow = true; return false; }
    u.binds[u.count].vname = vname;
    u.binds[u.count].side = side;
    u.binds[u.count].term = t;
    u.binds[u.count].term_side = tside;
    u.count = u.count + 1;
    return true;
}

fn bool heads_agree(Node* a, Node* b)
{
    if (a.kind != b.kind) { return false; }
    if (a.p.op != b.p.op) { return false; }
    if (a.child_count != b.child_count) { return false; }
    switch (a.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
        case N_EXPR_BOOL:
            return a.p.ival == b.p.ival;
        case N_EXPR_FLOAT:
            return theory_term::f64_bits(a.p.fval) == theory_term::f64_bits(b.p.fval);
        case N_EXPR_STRING:
        {
            if (a.p.slen != b.p.slen) { return false; }
            for (usz i = 0; i < a.p.slen; i++) { if (a.p.sptr[i] != b.p.sptr[i]) { return false; } }
            return true;
        }
        case N_EXPR_IDENT:
        case N_EXPR_METHOD:
        case N_EXPR_FIELD:
            return a.name_id == b.name_id;
        default:
            return true;
    }
}

fn bool Unifier.unify(Unifier* u, Node* a, int sa, Node* b, int sb, int depth)
{
    if (a == null || b == null || depth > TRS_MAX_DEPTH) { return false; }
    u.deref(&a, &sa);
    u.deref(&b, &sb);
    // Wildcards unify with anything and bind nothing.
    if (a.kind == Nk.N_PAT_WILDCARD || b.kind == Nk.N_PAT_WILDCARD) { return true; }
    if (is_real_var(a))
    {
        if (is_real_var(b) && a.name_id == b.name_id && sa == sb) { return true; }
        return u.bind(a.name_id, sa, b, sb);
    }
    if (is_real_var(b)) { return u.bind(b.name_id, sb, a, sa); }
    if (!heads_agree(a, b)) { return false; }
    bool is_call = a.kind == Nk.N_EXPR_CALL;
    for (usz i = 0; i < a.child_count; i++)
    {
        if (is_call && i == 0)
        {
            // Callee slot: symbols, compared by name.
            Node* ca = a.children[0];
            Node* cb = b.children[0];
            if (ca == null || cb == null) { return false; }
            if (ca.kind != cb.kind || ca.name_id != cb.name_id) { return false; }
            continue;
        }
        if (!u.unify(a.children[i], sa, b.children[i], sb, depth + 1)) { return false; }
    }
    return true;
}

// Build the instance of `t` (on `side`) under the unifier. `hole`, when it
// is reached on side `hole_side`, is replaced by the instance of `plug` on
// `plug_side` — that is how l1σ[r2σ]_p is built without positions.
struct Inst
{
    Unifier*  u;
    Arena*    arena;
    Node*     hole;
    int       hole_side;
    Node*     plug;
    int       plug_side;
    pfront_core::Interner* interner;
}

fn Node* Inst.build(Inst* in, Node* t, int side, int depth)
{
    if (t == null || depth > TRS_MAX_DEPTH) { return null; }
    if (t == in.hole && side == in.hole_side && in.plug != null)
    {
        Node* saved_hole = in.hole;
        in.hole = null;                    // the plug is not re-plugged
        Node* out = in.build(in.plug, in.plug_side, depth + 1);
        in.hole = saved_hole;
        return out;
    }
    if (is_real_var(t))
    {
        int b = in.u.find(t.name_id, side);
        if (b >= 0) { return in.build(in.u.binds[b].term, in.u.binds[b].term_side, depth + 1); }
        Node* v = in.arena.node(Nk.N_EXPR_IDENT, t.line, t.col);
        if (v == null) { return null; }
        v.flags = t.flags | pfront_core::NF_SYNTHETIC;
        v.p = t.p;
        v.name_id = t.name_id;
        if (side != 0 && in.interner != null)
        {
            // Rename side-1 variables apart in the OUTPUT so `x` from rule
            // i and `x` from rule j cannot be confused by term_eq.
            usz n = t.p.slen;
            char* buf = (char*)in.arena.alloc(n + 2, 1);
            if (buf != null)
            {
                for (usz k = 0; k < n; k++) { buf[k] = t.p.sptr[k]; }
                buf[n] = '\'';
                buf[n + 1] = 0;
                v.p.sptr = buf;
                v.p.slen = n + 1;
                v.name_id = in.interner.intern(buf, n + 1);
            }
        }
        return v;
    }
    Node* c = in.arena.node(t.kind, t.line, t.col);
    if (c == null) { return null; }
    c.name_id = t.name_id;
    c.flags = t.flags | pfront_core::NF_SYNTHETIC;
    c.effects = t.effects;
    c.type_ann = t.type_ann;
    c.resolved = t.resolved;
    c.owner = t.owner;
    c.p = t.p;
    for (usz i = 0; i < t.child_count; i++)
    {
        Node* k = in.build(t.children[i], side, depth + 1);
        if (k == null) { return null; }
        in.arena.add_child(c, k);
    }
    return c;
}

// ── Critical pairs ──────────────────────────────────────────────────────────
struct CpCtx
{
    RuleSet*   rs;
    Rewriter*  rw;
    Arena*     arena;
    pfront_core::Interner* interner;
    usz        budget;      // unification attempts left
}

fn bool rule_is_conditional(Rule* r)
{
    return r.guard != null || r.guard2 != null || r.guard3 != null;
}

// Try the overlap of rule j's lhs with the subterm `sub` of rule i's lhs.
fn void CpCtx.try_overlap(CpCtx* cx, usz i, usz j, Node* sub, bool at_root)
{
    if (cx.budget == 0) { return; }
    cx.budget = cx.budget - 1;
    cx.rs.cp_cost = cx.rs.cp_cost + 1;
    Rule* a = &cx.rs.rules[i];
    Rule* b = &cx.rs.rules[j];

    Unifier* u = (Unifier*)malloc(Unifier::size);
    if (u == null) { return; }
    u.init();
    bool ok = u.unify(sub, 0, b.lhs, 1, 0);
    if (!ok || u.overflow) { free((void*)u); return; }

    // Root overlap of a rule with itself is the trivial pair ⟨r, r⟩.
    if (at_root && i == j) { free((void*)u); return; }

    cx.rs.cp_total = cx.rs.cp_total + 1;
    if (rule_is_conditional(a) || rule_is_conditional(b))
    {
        cx.rs.cp_conditional = cx.rs.cp_conditional + 1;
        free((void*)u);
        return;
    }

    Inst in;
    in.u = u;
    in.arena = cx.arena;
    in.interner = cx.interner;
    in.hole = null;
    in.hole_side = 0;
    in.plug = null;
    in.plug_side = 0;
    Node* left = in.build(a.rhs, 0, 0);          // r1σ
    in.hole = sub;
    in.hole_side = 0;
    in.plug = b.rhs;
    in.plug_side = 1;
    Node* right = in.build(a.lhs, 0, 0);         // l1σ[r2σ]_p
    free((void*)u);
    if (left == null || right == null) { return; }

    // Joinability: both sides to normal form under the same rules, with a
    // private fuel budget so a divergent set cannot stall the analysis.
    Rewriter* rw = cx.rw;
    int saved_fuel = rw.fuel;
    usz saved_firings = rw.firings;
    rw.retarget(cx.rs);
    rw.fuel = 4096;
    rw.created = 0;
    rw.node_budget = 64 * 1024;
    Node* nl = rw.run_fixpoint(left, 16);
    rw.memo.init();
    rw.fuel = 4096;
    rw.created = 0;
    Node* nr = rw.run_fixpoint(right, 16);
    rw.fuel = saved_fuel;
    rw.firings = saved_firings;   // analysis firings are not user firings
    for (usz k = 0; k < cx.rs.count; k++) { cx.rs.rules[k].fire_count = 0; }

    if (theory_term::term_eq(nl, nr, 0))
    {
        cx.rs.cp_joinable = cx.rs.cp_joinable + 1;
        return;
    }
    cx.rs.cp_nonjoinable = cx.rs.cp_nonjoinable + 1;
    if (cx.rs.first_cp_text == null)
    {
        char* buf = (char*)cx.arena.alloc(512, 1);
        if (buf != null)
        {
            usz pos = 0;
            pos = pos + term_print(nl, buf + pos, 512 - pos, cx.interner, 0);
            pos = pos + str_put(buf + pos, 512 - pos, "  vs  ");
            pos = pos + term_print(nr, buf + pos, 512 - pos, cx.interner, 0);
            buf[pos < 511 ? pos : 511] = 0;
            cx.rs.first_cp_text = buf;
            cx.rs.first_cp_line = a.lhs.line;
            cx.rs.first_cp_col = a.lhs.col;
        }
    }
}

// Enumerate the non-variable subterms of rule i's lhs.
fn void CpCtx.overlaps_in(CpCtx* cx, usz i, usz j, Node* sub, bool at_root, int depth)
{
    if (sub == null || depth > TRS_MAX_DEPTH) { return; }
    if (theory_term::is_pattern_var(sub)) { return; }
    cx.try_overlap(i, j, sub, at_root);
    bool is_call = sub.kind == Nk.N_EXPR_CALL;
    for (usz k = 0; k < sub.child_count; k++)
    {
        if (is_call && k == 0) { continue; }
        cx.overlaps_in(i, j, sub.children[k], false, depth + 1);
    }
}

fn void RuleSet.compute_critical_pairs(RuleSet* rs, Rewriter* rw, Arena* a,
                                        pfront_core::Interner* it)
{
    rs.cp_total = 0;
    rs.cp_joinable = 0;
    rs.cp_nonjoinable = 0;
    rs.cp_conditional = 0;
    rs.first_cp_text = null;
    CpCtx cx;
    cx.rs = rs;
    cx.rw = rw;
    cx.arena = a;
    cx.interner = it;
    cx.budget = 20000;
    for (usz i = 0; i < rs.count; i++)
    {
        for (usz j = 0; j < rs.count; j++)
        {
            if (rs.rules[i].var_headed || rs.rules[j].var_headed) { continue; }
            cx.overlaps_in(i, j, rs.rules[i].lhs, true, 0);
        }
    }
    rs.overlaps = rs.cp_total;
}

// Full analysis: termination first (the joinability check leans on it),
// then critical pairs. Idempotent per set.
fn void RuleSet.analyse(RuleSet* rs, Rewriter* rw, Arena* a, pfront_core::Interner* it)
{
    if (rs.analysed) { return; }
    rs.analysed = true;
    SymTable* st = (SymTable*)malloc(SymTable::size);
    if (st != null)
    {
        rs.prove_termination(st);
        free((void*)st);
    }
    rs.compute_critical_pairs(rw, a, it);
    rs.confluent = rs.terminating && rs.cp_nonjoinable == 0 && rs.cp_conditional == 0;
}

// ── Printing ────────────────────────────────────────────────────────────────
fn usz str_put(char* buf, usz cap, char* s)
{
    usz n = 0;
    while (s[n] != 0 && n + 1 < cap) { buf[n] = s[n]; n = n + 1; }
    return n;
}

fn usz term_print(Node* n, char* buf, usz cap, pfront_core::Interner* it, int depth)
{
    if (cap < 8) { return 0; }
    if (n == null) { return str_put(buf, cap, "?"); }
    if (depth > 24) { return str_put(buf, cap, "…"); }
    usz pos = 0;
    switch (n.kind)
    {
        case N_EXPR_INT:
            return (usz)snprintf(buf, cap, "%ld", (long)n.p.ival);
        case N_EXPR_BOOL:
            return str_put(buf, cap, n.p.ival != 0 ? "true" : "false");
        case N_EXPR_CHAR:
            return (usz)snprintf(buf, cap, "'%c'", (int)n.p.ival);
        case N_PAT_WILDCARD:
            return str_put(buf, cap, "_");
        case N_PAT_LITERAL:
            if (n.child_count > 0) { return term_print(n.children[0], buf, cap, it, depth + 1); }
            return str_put(buf, cap, "?");
        case N_EXPR_IDENT:
        {
            if (n.p.sptr != null && n.p.slen > 0)
            {
                usz k = 0;
                while (k < n.p.slen && k + 1 < cap) { buf[k] = n.p.sptr[k]; k = k + 1; }
                return k;
            }
            if (it != null && n.name_id != 0) { return str_put(buf, cap, it.text(n.name_id)); }
            return str_put(buf, cap, "?");
        }
        case N_EXPR_BINARY:
        {
            pos = pos + str_put(buf + pos, cap - pos, "(");
            if (n.child_count > 0) { pos = pos + term_print(n.children[0], buf + pos, cap - pos, it, depth + 1); }
            pos = pos + str_put(buf + pos, cap - pos, " ");
            pos = pos + str_put(buf + pos, cap - pos, pfront_lex::token_type_name((Tk)n.p.op));
            pos = pos + str_put(buf + pos, cap - pos, " ");
            if (n.child_count > 1) { pos = pos + term_print(n.children[1], buf + pos, cap - pos, it, depth + 1); }
            pos = pos + str_put(buf + pos, cap - pos, ")");
            return pos;
        }
        case N_EXPR_UNARY:
        {
            pos = pos + str_put(buf + pos, cap - pos, pfront_lex::token_type_name((Tk)n.p.op));
            if (n.child_count > 0) { pos = pos + term_print(n.children[0], buf + pos, cap - pos, it, depth + 1); }
            return pos;
        }
        case N_EXPR_CALL:
        case N_EXPR_METHOD:
        {
            usz first = 0;
            if (n.kind == Nk.N_EXPR_CALL && n.child_count > 0)
            {
                pos = pos + term_print(n.children[0], buf + pos, cap - pos, it, depth + 1);
                first = 1;
            }
            else if (it != null && n.name_id != 0)
            {
                pos = pos + str_put(buf + pos, cap - pos, it.text(n.name_id));
            }
            pos = pos + str_put(buf + pos, cap - pos, "(");
            for (usz i = first; i < n.child_count; i++)
            {
                if (i > first) { pos = pos + str_put(buf + pos, cap - pos, ", "); }
                pos = pos + term_print(n.children[i], buf + pos, cap - pos, it, depth + 1);
            }
            pos = pos + str_put(buf + pos, cap - pos, ")");
            return pos;
        }
        default:
        {
            pos = pos + str_put(buf + pos, cap - pos, pfront_core::kind_name(n.kind));
            if (n.child_count == 0) { return pos; }
            pos = pos + str_put(buf + pos, cap - pos, "(");
            for (usz i = 0; i < n.child_count; i++)
            {
                if (i > 0) { pos = pos + str_put(buf + pos, cap - pos, ", "); }
                pos = pos + term_print(n.children[i], buf + pos, cap - pos, it, depth + 1);
            }
            pos = pos + str_put(buf + pos, cap - pos, ")");
            return pos;
        }
    }
}

// One-line verdict for the report.
fn void RuleSet.report_proof(RuleSet* rs, char* label)
{
    if (!rs.analysed) { return; }
    printf("  trs %-12s : %d rules; termination %s (LPO, %d unproven); critical pairs %d (%d joinable, %d not, %d conditional) => %s\n",
           label, (int)rs.count,
           rs.terminating ? "PROVED" : "unproven", (int)rs.lpo_unproven,
           (int)rs.cp_total, (int)rs.cp_joinable, (int)rs.cp_nonjoinable, (int)rs.cp_conditional,
           rs.confluent ? "confluent" : (rs.cp_nonjoinable > 0 ? "NOT confluent" : "confluence undecided"));
}
