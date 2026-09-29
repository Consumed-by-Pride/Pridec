// ============================================================================
// theory_rwsite.c3 — first-class rewrite values, applied where written
// ----------------------------------------------------------------------------
// Spec §16: rewrite rules are VALUES. They are built by a `rewrite` block or
// a `rule` declaration, composed with `++`, and applied with `expr |> r`
// (one pass) or `expr |> r*` (to a fixpoint). Nothing else in the program is
// ever touched by a rule.
//
// This pass is the evaluator for that little language. It walks the tree
// with a scope of rewrite-valued bindings and, at each `|>` whose right-hand
// side denotes a rule set, replaces the whole `|>` node by the rewritten
// left operand. Before a set is first applied it is ANALYSED (LPO
// termination, critical pairs, confluence — theory_trs_proof.c3) and the
// verdict is reported as a diagnostic at the set's definition.
//
// Why a separate pass rather than a flag on the old global rewriter: the old
// code collected every rule in the file into one set and ran it over the
// whole module, including the rule definitions themselves. On the spec's own
// example that turned `x + 0 ↦ x` into `x ↦ x`, rewrote `0` to `1` inside an
// unrelated function, and left the `|>` node in place, unapplied. Scoping is
// the semantics, not an optimisation of it.
// ============================================================================

module theory_rwsite;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_trs;
import theory_egraph;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz cap, char* fmt, ...);

const usz RW_ENV_CAP  = 512;
const usz RW_SETS_CAP = 256;

struct RwBinding
{
    Node*               key;     // pat-ident / let / rewrite-block node
    theory_trs::RuleSet* set;
}

struct RwSites
{
    Arena*                     arena;
    pfront_core::DiagBag*      diags;
    pfront_core::Interner*     interner;
    char*                      file;
    theory_trs::Rewriter*      rw;
    theory_egraph::Saturator*  sat;
    bool                       use_egraph;
    bool                       strict;

    RwBinding[RW_ENV_CAP]      env;
    usz                        env_count;

    theory_trs::RuleSet*[RW_SETS_CAP] sets;      // owned, freed on destroy
    char*[RW_SETS_CAP]                labels;
    usz                               set_count;

    usz sites;            // `|>` applications performed
    usz sites_fix;        // of which `|>*`
    usz sites_skipped;    // `|>` whose rhs is not a rewrite value (a pipeline)
    usz unions;           // `++` evaluated
    usz nodes_before;
    usz nodes_after;
    usz egraph_improved;
    usz sets_confluent;
    usz sets_terminating;
    usz sets_nonconfluent;
    usz sets_undecided;
}

fn void RwSites.init(RwSites* w, Arena* a, pfront_core::DiagBag* d,
                     pfront_core::Interner* it, char* file,
                     theory_trs::Rewriter* rw, theory_egraph::Saturator* sat)
{
    w.arena = a;
    w.diags = d;
    w.interner = it;
    w.file = file;
    w.rw = rw;
    w.sat = sat;
    w.use_egraph = true;
    w.strict = false;
    w.env_count = 0;
    w.set_count = 0;
    w.sites = 0;
    w.sites_fix = 0;
    w.sites_skipped = 0;
    w.unions = 0;
    w.nodes_before = 0;
    w.nodes_after = 0;
    w.egraph_improved = 0;
    w.sets_confluent = 0;
    w.sets_terminating = 0;
    w.sets_nonconfluent = 0;
    w.sets_undecided = 0;
}

fn void RwSites.destroy(RwSites* w)
{
    for (usz i = 0; i < w.set_count; i++)
    {
        if (w.sets[i] != null) { free((void*)w.sets[i]); }
    }
    w.set_count = 0;
    w.env_count = 0;
}

// ── Environment ─────────────────────────────────────────────────────────────
fn theory_trs::RuleSet* RwSites.lookup(RwSites* w, Node* key)
{
    if (key == null) { return null; }
    for (usz i = w.env_count; i > 0; i--)
    {
        if (w.env[i - 1].key == key) { return w.env[i - 1].set; }
    }
    return null;
}

fn void RwSites.bind(RwSites* w, Node* key, theory_trs::RuleSet* set)
{
    if (key == null || set == null) { return; }
    if (w.env_count >= RW_ENV_CAP) { return; }
    w.env[w.env_count].key = key;
    w.env[w.env_count].set = set;
    w.env_count = w.env_count + 1;
}

fn theory_trs::RuleSet* RwSites.new_set(RwSites* w, char* label)
{
    if (w.set_count >= RW_SETS_CAP) { return null; }
    theory_trs::RuleSet* rs = (theory_trs::RuleSet*)malloc(theory_trs::RuleSet::size);
    if (rs == null) { return null; }
    rs.init();
    w.sets[w.set_count] = rs;
    w.labels[w.set_count] = label;
    w.set_count = w.set_count + 1;
    return rs;
}

fn char* RwSites.label_for(RwSites* w, Node* n, char* fallback)
{
    if (n != null && n.name_id != 0 && w.interner != null) { return w.interner.text(n.name_id); }
    return fallback;
}

fn void RwSites.relabel(RwSites* w, theory_trs::RuleSet* rs, char* label)
{
    if (rs == null || label == null) { return; }
    for (usz i = 0; i < w.set_count; i++)
    {
        if (w.sets[i] == rs) { w.labels[i] = label; return; }
    }
}

// ── Evaluating a Rewrite-valued expression ─────────────────────────────────
fn theory_trs::RuleSet* RwSites.eval(RwSites* w, Node* e, int depth)
{
    if (e == null || depth > 32) { return null; }

    // `rewrite | ... ` block, inline or as a let initializer.
    if (theory_trs::is_rewrite_block(e))
    {
        theory_trs::RuleSet* have = w.lookup(e);
        if (have != null) { return have; }
        theory_trs::RuleSet* rs = w.new_set(w.label_for(e, "rewrite"));
        if (rs == null) { return null; }
        rs.add_block(e);
        w.bind(e, rs);
        return rs;
    }

    switch (e.kind)
    {
        case N_EXPR_IDENT:
        {
            Node* target = e.resolved;
            if (target == null) { return null; }
            theory_trs::RuleSet* rs = w.lookup(target);
            if (rs != null) { return rs; }
            // A binder we have not evaluated yet (forward reference to a
            // module-level `let`): evaluate its initializer on demand.
            Node* decl = target;
            if (decl.kind == Nk.N_PAT_IDENT && decl.parent != null) { decl = decl.parent; }
            if (decl.kind == Nk.N_DECL_LET && decl.child_count >= 2)
            {
                theory_trs::RuleSet* v = w.eval(decl.children[decl.child_count - 1], depth + 1);
                if (v != null) { w.bind(target, v); w.bind(decl, v); }
                return v;
            }
            if (theory_trs::is_rewrite_block(decl)) { return w.eval(decl, depth + 1); }
            return null;
        }
        case N_EXPR_BINARY:
        {
            if (e.p.op != (int)Tk.TOKEN_PLUSPLUS || e.child_count < 2) { return null; }
            theory_trs::RuleSet* a = w.eval(e.children[0], depth + 1);
            theory_trs::RuleSet* b = w.eval(e.children[1], depth + 1);
            if (a == null || b == null) { return null; }
            theory_trs::RuleSet* rs = w.new_set("++");
            if (rs == null) { return null; }
            rs.add_all(a);
            rs.add_all(b);
            w.unions = w.unions + 1;
            w.bind(e, rs);
            return rs;
        }
        case N_EXPR_TUPLE:
            // `(r)` parenthesised.
            if (e.child_count == 1) { return w.eval(e.children[0], depth + 1); }
            return null;
        default:
            return null;
    }
}

// ── Analysis + diagnostics, once per set ───────────────────────────────────
fn void RwSites.analyse(RwSites* w, theory_trs::RuleSet* rs, Node* site)
{
    if (rs == null || rs.analysed) { return; }
    rs.analyse(w.rw, w.arena, w.interner);

    if (rs.terminating) { w.sets_terminating = w.sets_terminating + 1; }
    if (rs.confluent) { w.sets_confluent = w.sets_confluent + 1; }
    else if (rs.cp_nonjoinable > 0) { w.sets_nonconfluent = w.sets_nonconfluent + 1; }
    else { w.sets_undecided = w.sets_undecided + 1; }

    if (w.diags == null) { return; }
    pfront_core::Phase ph = pfront_core::Phase.PH_RESOLVE;

    if (!rs.terminating && rs.first_bad_rule >= 0)
    {
        theory_trs::Rule* r = &rs.rules[rs.first_bad_rule];
        char* msg = (char*)w.arena.alloc(256, 1);
        if (msg != null)
        {
            snprintf(msg, 256,
                     "termination of this rewrite rule set is not proved: rule %d is not orientable by LPO; `|>` stays fuel-bounded",
                     rs.first_bad_rule + 1);
            w.diags.note(ph, 4032, r.lhs.line, r.lhs.col, msg, w.file);
        }
    }
    if (rs.cp_nonjoinable > 0 && rs.first_cp_text != null)
    {
        char* msg = (char*)w.arena.alloc(768, 1);
        if (msg != null)
        {
            snprintf(msg, 768,
                     "rewrite rules are not confluent: critical pair `%s` has two distinct normal forms, so the result of `|>` depends on rule order",
                     rs.first_cp_text);
            if (w.strict) { w.diags.error(ph, 4031, rs.first_cp_line, rs.first_cp_col, msg, w.file); }
            else          { w.diags.warn(ph, 4031, rs.first_cp_line, rs.first_cp_col, msg, w.file); }
        }
    }
    else if (rs.cp_conditional > 0 && site != null)
    {
        char* msg = (char*)w.arena.alloc(256, 1);
        if (msg != null)
        {
            snprintf(msg, 256,
                     "confluence of this rewrite rule set is not decided: %d overlap(s) involve guarded rules",
                     (int)rs.cp_conditional);
            w.diags.note(ph, 4033, site.line, site.col, msg, w.file);
        }
    }
}

// ── Application at a `|>` site ─────────────────────────────────────────────
fn Node* RwSites.apply(RwSites* w, Node* pipe)
{
    Node* subject = pipe.children[0];
    Node* rhs = pipe.children[1];
    theory_trs::RuleSet* rs = w.eval(rhs, 0);
    if (rs == null)
    {
        w.sites_skipped = w.sites_skipped + 1;   // ordinary pipeline `x |> f`
        return pipe;
    }
    w.analyse(rs, rhs);

    bool fixpoint = pipe.p.aux == 1;
    w.sites = w.sites + 1;
    if (fixpoint) { w.sites_fix = w.sites_fix + 1; }
    w.nodes_before = w.nodes_before + theory_term::term_size(subject, 0);

    // The destructive pass mutates the subject; keep the original for the
    // e-graph, which must search from the SUBJECT, not from the TRS answer.
    Node* original = (fixpoint && w.use_egraph && w.sat != null && rs.count > 0)
                   ? theory_term::clone_term(w.arena, subject, 0) : null;

    Node* out = w.rw.apply_site(subject, rs, fixpoint);
    if (out == null) { out = subject; }

    // Equality saturation over the same rules from the original subject,
    // with the TRS normal form added as one more member of the root class:
    // every reachable form is kept and the cheapest is extracted, so the
    // answer depends neither on rule order nor on where the TRS stalled.
    // Only for `*`: a single `|>` is one pass by definition.
    if (original != null)
    {
        Node* better = w.sat.search(original, out, rs);
        if (better != null) { out = better; w.egraph_improved = w.egraph_improved + 1; }
    }

    w.nodes_after = w.nodes_after + theory_term::term_size(out, 0);
    out.parent = pipe.parent;
    return out;
}

// ── Walk ───────────────────────────────────────────────────────────────────
fn Node* RwSites.walk(RwSites* w, Node* n, int depth)
{
    if (n == null || depth > 512) { return n; }

    // Rule definitions are data, never a rewrite subject.
    if (theory_trs::is_rewrite_block(n))
    {
        if (n.name_id != 0) { w.eval(n, 0); }   // `rewrite name | ...` declaration form
        return n;
    }

    // Children first, so an inner `|>` inside a subject is resolved before
    // the outer one sees it, and so a let's initializer is processed before
    // it is bound.
    usz saved_env = w.env_count;
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        Node* r = w.walk(c, depth + 1);
        if (r != null && r != c) { n.set_child(i, r); }
    }

    switch (n.kind)
    {
        case N_DECL_LET:
        {
            if (n.child_count < 2) { break; }
            Node* init = n.children[n.child_count - 1];
            theory_trs::RuleSet* rs = w.eval(init, 0);
            if (rs == null) { break; }
            Node* pat = n.children[0];
            w.bind(pat, rs);
            w.bind(n, rs);
            w.relabel(rs, w.label_for(pat, w.label_for(n, "let")));
            // A let-bound set outlives this walk frame (its scope is the
            // enclosing block, which the caller is still inside).
            saved_env = w.env_count;
        }
        case N_EXPR_BINARY:
        {
            if (n.p.op == (int)Tk.TOKEN_PIPELINE && n.child_count == 2)
            {
                return w.apply(n);
            }
        }
        case N_DECL_FN:
        case N_EXPR_LAMBDA:
        case N_BLOCK:
            // Scope boundary: bindings made inside do not leak out.
            w.env_count = saved_env;
        default:
            break;
    }
    return n;
}

fn Node* RwSites.run(RwSites* w, Node* root)
{
    return w.walk(root, 0);
}

fn void RwSites.report(RwSites* w)
{
    if (w.set_count == 0 && w.sites == 0) { return; }
    printf("  rewrite values   : %d sets (%d via ++), %d `|>` sites (%d fixpoint, %d plain pipelines), nodes %d -> %d, e-graph improved %d\n",
           (int)w.set_count, (int)w.unions, (int)w.sites, (int)w.sites_fix, (int)w.sites_skipped,
           (int)w.nodes_before, (int)w.nodes_after, (int)w.egraph_improved);
    printf("  rewrite theory   : %d terminating, %d confluent, %d NOT confluent, %d undecided\n",
           (int)w.sets_terminating, (int)w.sets_confluent, (int)w.sets_nonconfluent, (int)w.sets_undecided);
    for (usz i = 0; i < w.set_count; i++)
    {
        if (w.sets[i] != null && w.sets[i].analysed) { w.sets[i].report_proof(w.labels[i]); }
    }
}
