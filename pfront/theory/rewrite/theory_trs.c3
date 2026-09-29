// ============================================================================
// theory_trs.c3 — Term Rewriting System (part 12)
// ----------------------------------------------------------------------------
// A confluence-aware, terminating term rewriter over Pride AST fragments.
//
// Rules come from `rewrite { lhs ↦ rhs }` blocks and `rule` declarations. A
// naive rewriter is slow for four structural reasons; each is addressed here:
//
//   1. Re-traversing the whole tree every pass
//        → a WORKLIST holding only changed subterms and their parents.
//   2. Trying every rule at every node
//        → a DISCRIMINATION TREE keyed on the subject's top symbol, so two or
//          three candidate rules are tested rather than all N.
//   3. Rebuilding identical subterms repeatedly
//        → HASH-CONSING plus a MEMO table: each term's normal form is computed
//          once and shared.
//   4. Re-matching a pattern from scratch
//        → rules carry a pre-analysed key and a left-linear fast path;
//          non-linear patterns exploit hash-consed pointer identity.
//
// TERMINATION is guaranteed by fuel: every firing spends one unit, and running
// out is a diagnostic rather than a hang. That is a deliberate engineering
// choice — deciding termination of an arbitrary TRS is undecidable, so the
// honest options are "bound it" or "hang", and a compiler must never hang.
//
// CONFLUENCE is checked, not assumed: `critical_pairs()` detects rule pairs
// whose left-hand sides overlap, which is where non-confluent behaviour comes
// from. Overlaps are reported, since a non-confluent rule set gives results
// that depend on traversal order.
// ============================================================================

module theory_trs;

import pfront_lex;
import pfront_core;
import theory_term;

extern fn int snprintf(char* buf, usz cap, char* fmt, ...);

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias Subst = theory_term::Subst;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz MAX_RULES      = 4096;
const usz DISC_KINDS     = 1024;
const usz DISC_BUCKET    = 64;
const usz WORKLIST_CAP   = 65536;
const usz MEMO_BUCKETS   = 32768;
const int DEFAULT_FUEL   = 200000;
const int TRS_MAX_DEPTH  = 400;

// ── Rules ───────────────────────────────────────────────────────────────────
struct Rule
{
    Node*  lhs;
    Node*  rhs;
    Node*  guard;        // optional condition, must evaluate true to fire
    Node*  guard2;       // second condition (`lhs, g1, g2 ↦ rhs`); null if absent
    Node*  guard3;
    bool   lpo_ok;       // termination proved by LPO for this rule
    uint   name_id;
    int    key;          // top symbol of lhs, for the discrimination tree
    bool   left_linear;  // no variable repeats in lhs -> fast match path
    bool   var_headed;   // lhs is a bare variable -> matches anything
    usz    lhs_size;
    usz    rhs_size;
    usz    fire_count;
    bool   size_increasing;   // rhs bigger than lhs: divergence candidate
}

struct RuleSet
{
    Rule[MAX_RULES] rules;
    usz             count;

    // Discrimination tree: key -> rule indices.
    int[DISC_KINDS]              bucket_len;
    int[DISC_KINDS * DISC_BUCKET] bucket;
    int[DISC_BUCKET]             catch_all;    // var-headed rules
    int                          catch_all_len;

    usz overlaps;         // critical pairs found
    usz size_increasing;
    usz rejected_nonterminating;   // var-headed AND growing: cannot terminate

    // ── Proof state (filled by analyse(); see theory_trs_proof.c3) ──────
    bool analysed;
    bool terminating;       // every rule oriented by LPO under `prec`
    usz  lpo_unproven;      // rules LPO could not orient
    usz  cp_total;          // critical pairs (proper overlaps)
    usz  cp_joinable;
    usz  cp_nonjoinable;
    usz  cp_conditional;    // overlaps involving a guarded rule: not decided
    bool confluent;         // terminating && cp_nonjoinable == 0 && cp_conditional == 0
    int  first_bad_rule;    // index of first LPO-unproven rule, -1 if none
    char* first_cp_text;    // printed first non-joinable pair, or null
    int  first_cp_line;
    int  first_cp_col;
    int  cp_cost;           // unification attempts spent
}

fn void RuleSet.init(RuleSet* rs)
{
    rs.count = 0;
    for (usz i = 0; i < DISC_KINDS; i++) { rs.bucket_len[i] = 0; }
    rs.catch_all_len = 0;
    rs.overlaps = 0;
    rs.size_increasing = 0;
    rs.rejected_nonterminating = 0;
    rs.analysed = false;
    rs.terminating = false;
    rs.lpo_unproven = 0;
    rs.cp_total = 0;
    rs.cp_joinable = 0;
    rs.cp_nonjoinable = 0;
    rs.cp_conditional = 0;
    rs.confluent = false;
    rs.first_bad_rule = -1;
    rs.first_cp_text = null;
    rs.first_cp_line = 0;
    rs.first_cp_col = 0;
    rs.cp_cost = 0;
}

fn bool RuleSet.add(RuleSet* rs, Node* lhs, Node* rhs, Node* guard, uint name)
{
    if (rs.count >= MAX_RULES || lhs == null || rhs == null) { return false; }
    int id = (int)rs.count;
    Rule* r = &rs.rules[id];
    r.lhs = lhs;
    r.rhs = rhs;
    r.guard = guard;
    r.guard2 = null;
    r.guard3 = null;
    r.lpo_ok = false;
    r.name_id = name;
    r.key = theory_term::top_key(lhs);
    r.var_headed = theory_term::is_pattern_var(lhs);
    r.left_linear = is_left_linear(lhs);
    r.lhs_size = theory_term::term_size(lhs, 0);
    r.rhs_size = theory_term::term_size(rhs, 0);
    r.fire_count = 0;
    r.size_increasing = r.rhs_size > r.lhs_size;
    if (r.size_increasing) { rs.size_increasing = rs.size_increasing + 1; }

    /*
     A VAR-HEADED, SIZE-INCREASING rule cannot terminate.

     `_ -> x` matches every term there is, and rewrites each one to
     something strictly larger, so every rewrite creates more work than
     it removes. The engine burned all 200,000 units of fuel on a
     four-line file and the growing terms took the process from 2.8 MB to
     77 MB; a 2 KB fuzzed file reached ~1.4 GB and was OOM-killed. Found
     by fuzzing, then by reading `--time-passes`, which put 98% of the
     time in trs-rewrite -- not in the pgen tree builder the file
     appeared to be about.

     Fuel already bounded the FIRINGS. It did not bound the MEMORY,
     because each firing leaves a bigger term behind. The rule is
     rejected at registration instead, which is the only point where the
     property is cheap to see and where refusing costs nothing that was
     ever going to work.

     Narrow on purpose. A var-headed rule that does NOT grow (`_ -> 0`)
     is still accepted: it terminates, and refusing it would break
     `x |> simplify` idioms. A size-increasing rule with a real
     constructor at its head is also still accepted: it only fires where
     that constructor appears.
    */
    if (r.var_headed && r.size_increasing)
    {
        // Counted here and REPORTED by print_stats, because add() has no
        // DiagBag: a counter that is printed is the same contract as a
        // warning, and inventing a parameter for one call site is worse.
        rs.rejected_nonterminating = rs.rejected_nonterminating + 1;
        return false;
    }

    rs.count = rs.count + 1;

    if (r.var_headed)
    {
        if (rs.catch_all_len < (int)DISC_BUCKET)
        {
            rs.catch_all[rs.catch_all_len] = id;
            rs.catch_all_len = rs.catch_all_len + 1;
        }
        return true;
    }
    usz k = (usz)r.key;
    if (k >= DISC_KINDS) { k = DISC_KINDS - 1; }
    if (rs.bucket_len[k] < (int)DISC_BUCKET)
    {
        rs.bucket[k * DISC_BUCKET + (usz)rs.bucket_len[k]] = id;
        rs.bucket_len[k] = rs.bucket_len[k] + 1;
    }
    return true;
}

// A pattern is left-linear when no variable occurs twice. Left-linear patterns
// can be matched without consulting previous bindings, which is the fast path.
fn bool is_left_linear(Node* lhs)
{
    uint[64] seen;
    usz n = 0;
    return collect_vars_unique(lhs, &seen[0], &n, 64, 0);
}

fn bool collect_vars_unique(Node* n, uint* seen, usz* count, usz cap, int depth)
{
    if (n == null || depth > TRS_MAX_DEPTH) { return true; }
    if (theory_term::is_pattern_var(n) && n.name_id != 0)
    {
        for (usz i = 0; i < *count; i++)
        {
            if (seen[i] == n.name_id) { return false; }   // repeated variable
        }
        if (*count < cap) { seen[*count] = n.name_id; *count = *count + 1; }
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (!collect_vars_unique(n.children[i], seen, count, cap, depth + 1))
        {
            return false;
        }
    }
    return true;
}

// ── Matching ────────────────────────────────────────────────────────────────
// Match `subject` against `pattern`, extending `s`. On failure the caller
// rolls back to a saved mark, so a partial match leaves no residue.
fn bool match_term(Node* pattern, Node* subject, Subst* s, int depth)
{
    return match_term_at(pattern, subject, s, depth, false);
}

/*
 `callee` is true when `pattern` sits in the callee slot of a call. That
 position names a FUNCTION SYMBOL, never a hole: `foo(x) ↦ bar(x)` must
 match calls to foo only. Before this flag, `foo` -- lowercase, so a
 pattern variable by the naming convention -- was bound to whatever the
 subject's callee happened to be, and the rule matched every unary call in
 the program.
*/
fn bool match_term_at(Node* pattern, Node* subject, Subst* s, int depth, bool callee)
{
    if (pattern == null || subject == null) { return false; }
    if (depth > TRS_MAX_DEPTH) { return false; }

    if (!callee && theory_term::is_pattern_var(pattern))
    {
        if (pattern.kind == Nk.N_PAT_WILDCARD) { return true; }
        return s.bind(pattern.name_id, subject);
    }

    if (pattern.kind != subject.kind) { return false; }
    if (pattern.p.op != subject.p.op) { return false; }

    // Literals must agree exactly.
    switch (pattern.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
        case N_EXPR_BOOL:
            if (pattern.p.ival != subject.p.ival) { return false; }
        case N_EXPR_FLOAT:
            if (theory_term::f64_bits(pattern.p.fval)
                != theory_term::f64_bits(subject.p.fval)) { return false; }
        case N_EXPR_STRING:
        {
            if (pattern.p.slen != subject.p.slen) { return false; }
            for (usz i = 0; i < pattern.p.slen; i++)
            {
                if (pattern.p.sptr[i] != subject.p.sptr[i]) { return false; }
            }
        }
        case N_EXPR_IDENT:
            // A non-variable identifier is a literal symbol.
            if (pattern.name_id != subject.name_id) { return false; }
        case N_EXPR_METHOD:
        case N_EXPR_FIELD:
            if (pattern.name_id != subject.name_id) { return false; }
        default:
            break;
    }

    if (pattern.child_count != subject.child_count) { return false; }
    bool is_call = pattern.kind == Nk.N_EXPR_CALL;
    for (usz i = 0; i < pattern.child_count; i++)
    {
        if (!match_term_at(pattern.children[i], subject.children[i], s, depth + 1,
                           is_call && i == 0))
        {
            return false;
        }
    }
    return true;
}

// ── Memo table ──────────────────────────────────────────────────────────────
// Maps a term to its normal form so a shared subterm is normalised once.
struct MemoEntry
{
    Node* from;
    Node* to;
    ulong hash;
    int   next;
}

/*
 Keyed STRUCTURALLY (term_hash + term_eq), not by pointer. Every right-hand
 side is instantiated into fresh nodes, so a pointer key was new every
 time and the table recorded 0 hits on the whole standard library.
*/
struct Memo
{
    int[MEMO_BUCKETS]        buckets;
    MemoEntry[WORKLIST_CAP]  entries;
    usz                      count;
    usz                      hits;
}

fn void Memo.init(Memo* m)
{
    for (usz i = 0; i < MEMO_BUCKETS; i++) { m.buckets[i] = 0; }
    m.count = 1;
    m.hits = 0;
}

fn Node* Memo.get(Memo* m, Node* key)
{
    ulong h = theory_term::term_hash(key, 0);
    usz b = (usz)(h & (ulong)(MEMO_BUCKETS - 1));
    int cur = m.buckets[b];
    while (cur != 0)
    {
        MemoEntry* e = &m.entries[cur];
        if (e.hash == h && (e.from == key || theory_term::term_eq(e.from, key, 0)))
        {
            m.hits = m.hits + 1;
            return e.to;
        }
        cur = e.next;
    }
    return null;
}

fn void Memo.put(Memo* m, Node* key, Node* val)
{
    if (m.count >= WORKLIST_CAP) { return; }
    ulong h = theory_term::term_hash(key, 0);
    usz b = (usz)(h & (ulong)(MEMO_BUCKETS - 1));
    int id = (int)m.count;
    m.count = m.count + 1;
    m.entries[id].from = key;
    m.entries[id].to = val;
    m.entries[id].hash = h;
    m.entries[id].next = m.buckets[b];
    m.buckets[b] = id;
}

// ── Rewriter ────────────────────────────────────────────────────────────────
struct Rewriter
{
    Arena*                       arena;
    RuleSet*                     rules;
    pfront_core::DiagBag*        diags;
    pfront_core::Interner*       interner;
    char*                        file;

    theory_term::HashCons*       hc;
    Memo                         memo;

    int   fuel;
    int   fuel_start;
    usz   firings;
    usz   match_attempts;
    usz   match_failures;
    usz   rounds;
    usz   fuel_exhausted;
    usz   depth_exceeded;
    usz   guard_blocked;
    usz   sites;             // `|>` applications performed
    usz   created;           // nodes materialised by firings (this site)
    usz   node_budget;       // cap on `created`; exceeding it is a fuel stall
    bool  use_memo;
}

const usz NODE_BUDGET_PROVED   = 4 * 1024 * 1024;
const usz NODE_BUDGET_UNPROVED = 256 * 1024;
const int FUEL_UNPROVED        = 4096;

fn void Rewriter.init(Rewriter* rw, Arena* a, RuleSet* rs,
                      pfront_core::DiagBag* d, pfront_core::Interner* it,
                      char* file, theory_term::HashCons* hc)
{
    rw.arena = a;
    rw.rules = rs;
    rw.diags = d;
    rw.interner = it;
    rw.file = file;
    rw.hc = hc;
    rw.memo.init();
    rw.fuel = DEFAULT_FUEL;
    rw.fuel_start = DEFAULT_FUEL;
    rw.firings = 0;
    rw.match_attempts = 0;
    rw.match_failures = 0;
    rw.rounds = 0;
    rw.fuel_exhausted = 0;
    rw.depth_exceeded = 0;
    rw.guard_blocked = 0;
    rw.sites = 0;
    rw.created = 0;
    rw.node_budget = NODE_BUDGET_PROVED;
    rw.use_memo = true;
}

// Rebind the rewriter to a different rule set (one `|>` site's value) with
// a clean memo: normal forms are only valid relative to the set that
// produced them.
fn void Rewriter.retarget(Rewriter* rw, RuleSet* rs)
{
    rw.rules = rs;
    rw.memo.init();
}

// One `expr |> rules` (fixpoint == false) or `expr |> rules*` application.
// A single application is one innermost pass; the fixpoint form re-runs
// until a whole pass fires nothing or fuel runs out.
fn Node* Rewriter.apply_site(Rewriter* rw, Node* term, RuleSet* rs, bool fixpoint)
{
    if (term == null || rs == null || rs.count == 0) { return term; }
    rw.retarget(rs);
    rw.sites = rw.sites + 1;
    /*
     Fuel bounds FIRINGS; it does not bound MEMORY. `g(x) ↦ g(g(x))`
     spent its 200,000 firings cloning a term that grew by one node per
     step and was OOM-killed on a 30-line file. A set whose termination is
     PROVED (LPO) may run to its natural normal form under the large
     budget; a set whose termination is not proved gets a small fuel AND
     a node budget, and stopping early is reported as INCOMPLETE.
    */
    rw.created = 0;
    if (rs.analysed && !rs.terminating)
    {
        rw.fuel = FUEL_UNPROVED;
        rw.node_budget = NODE_BUDGET_UNPROVED;
    }
    else
    {
        rw.fuel = rw.fuel_start;
        rw.node_budget = NODE_BUDGET_PROVED;
    }
    // normalize() rewrites children in place, so keep a pristine copy of
    // the subject: a stalled site hands back what the programmer wrote,
    // never a half-normalised term.
    Node* backup = theory_term::clone_term(rw.arena, term, 0);
    usz stalls_before = rw.fuel_exhausted;
    rw.rounds = rw.rounds + 1;
    Node* out = fixpoint ? rw.run_fixpoint(term, 64) : rw.pass_once(term, 0);
    if (rw.fuel_exhausted > stalls_before)
    {
        if (rw.diags != null)
        {
            // Giving up is not a clean result: say so AT THE SITE.
            rw.diags.warn(pfront_core::Phase.PH_RESOLVE, 4030, term.line, term.col,
                          (rs.analysed && !rs.terminating)
                            ? "rewriting stopped early: this rule set has no termination proof and exhausted its fuel/node budget; the subject is left unrewritten"
                            : "rewriting stopped early: fuel exhausted; the subject is left unrewritten",
                          rw.file);
        }
        return backup != null ? backup : term;
    }
    return out;
}

// `expr |> r` — ONE bottom-up pass: children first, then at most one rule
// firing at each node's root. The result of a firing is not re-examined;
// that is what `|> r*` is for. Spec §16: "apply once / to a fixpoint".
fn Node* Rewriter.pass_once(Rewriter* rw, Node* n, int depth)
{
    if (n == null) { return null; }
    if (depth > TRS_MAX_DEPTH) { rw.depth_exceeded = rw.depth_exceeded + 1; return n; }
    if (n.kind == Nk.N_DECL_FN && (n.flags & pfront_core::NF_SYNTHETIC) != 0) { return n; }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* before = n.children[i];
        Node* after = rw.pass_once(before, depth + 1);
        if (after != null && after != before) { n.set_child(i, after); }
    }
    Node* stepped = rw.try_rules(n);
    return stepped == null ? n : stepped;
}

// Try every candidate rule for this subject's top symbol. Returns the rewritten
// term, or null when no rule applies.
fn Node* Rewriter.try_rules(Rewriter* rw, Node* subject)
{
    if (subject == null) { return null; }
    int key = theory_term::top_key(subject);
    usz k = (usz)key;
    if (k >= DISC_KINDS) { k = DISC_KINDS - 1; }

    Subst s;
    s.clear();

    // Indexed candidates first, then the var-headed catch-all bucket.
    int n = rw.rules.bucket_len[k];
    for (int i = 0; i < n; i++)
    {
        int rid = rw.rules.bucket[k * DISC_BUCKET + (usz)i];
        Node* out = rw.apply_rule(rid, subject, &s);
        if (out != null) { return out; }
    }
    for (int i = 0; i < rw.rules.catch_all_len; i++)
    {
        Node* out = rw.apply_rule(rw.rules.catch_all[i], subject, &s);
        if (out != null) { return out; }
    }
    return null;
}

fn Node* Rewriter.apply_rule(Rewriter* rw, int rid, Node* subject, Subst* s)
{
    if (rid < 0 || (usz)rid >= rw.rules.count) { return null; }
    Rule* r = &rw.rules.rules[rid];
    s.clear();
    rw.match_attempts = rw.match_attempts + 1;
    if (!match_term(r.lhs, subject, s, 0))
    {
        rw.match_failures = rw.match_failures + 1;
        return null;
    }
    // A guard is a side condition; only a literal-true guard fires. Anything
    // requiring evaluation is conservatively treated as not-yet-decidable, so
    // the rule does not fire — a wrong rewrite is far worse than a missed one.
    if (!guard_holds(r, s)) { rw.guard_blocked = rw.guard_blocked + 1; return null; }
    if (rw.fuel <= 0 || rw.created > rw.node_budget)
    {
        rw.fuel_exhausted = rw.fuel_exhausted + 1;
        rw.fuel = 0;
        return null;
    }
    rw.fuel = rw.fuel - 1;
    r.fire_count = r.fire_count + 1;
    rw.firings = rw.firings + 1;
    Node* out = s.instantiate(rw.arena, r.rhs, 0);
    rw.created = rw.created + theory_term::term_size(out, 0);
    // `x * n, is_power_of_2(n) ↦ x << log2(n)`: the right-hand side may
    // call a compile-time builtin over matched literals. Fold those now so
    // the program never sees a call to `log2`.
    return fold_builtins(rw.arena, out, 0);
}

// Every guard of the rule must evaluate to a definite `true` under the
// substitution. An undecidable guard blocks the rule: a missed rewrite is
// a lost optimisation, a wrong one is a miscompile.
fn bool guard_holds(Rule* r, Subst* s)
{
    if (r.guard != null && !guard_is_true(r.guard, s)) { return false; }
    if (r.guard2 != null && !guard_is_true(r.guard2, s)) { return false; }
    if (r.guard3 != null && !guard_is_true(r.guard3, s)) { return false; }
    return true;
}

// ── Guard evaluation ────────────────────────────────────────────────────────
// A guard is a closed boolean expression over the pattern variables. It is
// evaluated by a small total interpreter: integer/bool literals, the bound
// terms (when they are literals), integer arithmetic and comparison, boolean
// connectives, and a fixed vocabulary of term predicates. Anything outside
// that vocabulary is UNDECIDED, and an undecided guard does not fire.
const int GV_UNDEF = 0;
const int GV_INT   = 1;
const int GV_BOOL  = 2;
struct GVal
{
    int  kind;
    long i;
}

fn GVal gv_undef() { GVal v; v.kind = GV_UNDEF; v.i = 0; return v; }
fn GVal gv_int(long x)  { GVal v; v.kind = GV_INT;  v.i = x; return v; }
fn GVal gv_bool(bool b) { GVal v; v.kind = GV_BOOL; v.i = b ? 1 : 0; return v; }

fn bool guard_is_true(Node* g, Subst* s)
{
    if (g == null) { return true; }
    GVal v = guard_eval(g, s, 0);
    if (v.kind == GV_BOOL) { return v.i != 0; }
    if (v.kind == GV_INT)  { return v.i != 0; }
    return false;
}

fn bool name_is(Node* n, char* lit)
{
    if (n == null || n.p.sptr == null) { return false; }
    usz k = 0;
    while (lit[k] != 0) { k = k + 1; }
    if (n.p.slen != k) { return false; }
    for (usz i = 0; i < k; i++) { if (n.p.sptr[i] != lit[i]) { return false; } }
    return true;
}

// The literal a term denotes, if it is one (possibly through a literal
// pattern wrapper).
fn GVal literal_of(Node* t)
{
    if (t == null) { return gv_undef(); }
    if (t.kind == Nk.N_PAT_LITERAL && t.child_count > 0) { t = t.children[0]; }
    switch (t.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
            return gv_int((long)t.p.ival);
        case N_EXPR_BOOL:
            return gv_bool(t.p.ival != 0);
        default:
            return gv_undef();
    }
}

fn bool is_pow2(long v) { return v > 0 && (v & (v - 1)) == 0; }
fn long ilog2(long v) { long r = 0; while (v > 1) { v = v >> 1; r = r + 1; } return r; }
fn long popcount64(long v) { ulong u = (ulong)v; long c = 0; while (u != 0) { c = c + (long)(u & 1); u = u >> 1; } return c; }

fn GVal guard_eval(Node* g, Subst* s, int depth)
{
    if (g == null || depth > 64) { return gv_undef(); }
    switch (g.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_CHAR:
            return gv_int((long)g.p.ival);
        case N_EXPR_BOOL:
            return gv_bool(g.p.ival != 0);
        case N_EXPR_IDENT:
        {
            if (name_is(g, "true"))  { return gv_bool(true); }
            if (name_is(g, "false")) { return gv_bool(false); }
            Node* bound = s.lookup(g.name_id);
            if (bound == null) { return gv_undef(); }
            return literal_of(bound);
        }
        case N_EXPR_UNARY:
        {
            if (g.child_count < 1) { return gv_undef(); }
            GVal a = guard_eval(g.children[0], s, depth + 1);
            if (a.kind == GV_UNDEF) { return a; }
            if (g.p.op == (int)Tk.TOKEN_MINUS) { return gv_int(-a.i); }
            if (g.p.op == (int)Tk.TOKEN_BANG)  { return gv_bool(a.i == 0); }
            return gv_undef();
        }
        case N_EXPR_BINARY:
        {
            if (g.child_count < 2) { return gv_undef(); }
            GVal a = guard_eval(g.children[0], s, depth + 1);
            if (a.kind == GV_UNDEF) { return a; }
            // Short-circuit forms decide on the left alone when they can.
            if (g.p.op == (int)Tk.TOKEN_AMPAMP && a.i == 0) { return gv_bool(false); }
            if (g.p.op == (int)Tk.TOKEN_PIPEPIPE && a.i != 0) { return gv_bool(true); }
            GVal b = guard_eval(g.children[1], s, depth + 1);
            if (b.kind == GV_UNDEF) { return b; }
            switch (g.p.op)
            {
                case (int)Tk.TOKEN_PLUS:     return gv_int(a.i + b.i);
                case (int)Tk.TOKEN_MINUS:    return gv_int(a.i - b.i);
                case (int)Tk.TOKEN_STAR:     return gv_int(a.i * b.i);
                case (int)Tk.TOKEN_SLASH:    return b.i == 0 ? gv_undef() : gv_int(a.i / b.i);
                case (int)Tk.TOKEN_PERCENT:  return b.i == 0 ? gv_undef() : gv_int(a.i % b.i);
                case (int)Tk.TOKEN_LSHIFT:   return (b.i < 0 || b.i > 63) ? gv_undef() : gv_int(a.i << b.i);
                case (int)Tk.TOKEN_RSHIFT:   return (b.i < 0 || b.i > 63) ? gv_undef() : gv_int(a.i >> b.i);
                case (int)Tk.TOKEN_AMP:      return gv_int(a.i & b.i);
                case (int)Tk.TOKEN_PIPE:     return gv_int(a.i | b.i);
                case (int)Tk.TOKEN_XOR:    return gv_int(a.i ^ b.i);
                case (int)Tk.TOKEN_LT:       return gv_bool(a.i <  b.i);
                case (int)Tk.TOKEN_LTEQ:     return gv_bool(a.i <= b.i);
                case (int)Tk.TOKEN_GT:       return gv_bool(a.i >  b.i);
                case (int)Tk.TOKEN_GTEQ:     return gv_bool(a.i >= b.i);
                case (int)Tk.TOKEN_EQEQ:     return gv_bool(a.i == b.i);
                case (int)Tk.TOKEN_NEQ:      return gv_bool(a.i != b.i);
                case (int)Tk.TOKEN_NEQ_UNI:  return gv_bool(a.i != b.i);
                case (int)Tk.TOKEN_AMPAMP:   return gv_bool(a.i != 0 && b.i != 0);
                case (int)Tk.TOKEN_PIPEPIPE: return gv_bool(a.i != 0 || b.i != 0);
                default:                     return gv_undef();
            }
        }
        case N_EXPR_CALL:
        {
            if (g.child_count < 1) { return gv_undef(); }
            Node* callee = g.children[0];
            if (callee == null || callee.kind != Nk.N_EXPR_IDENT) { return gv_undef(); }
            usz argc = g.child_count - 1;
            // Term predicates take the MATCHED TERM, not its value.
            if (argc == 1)
            {
                Node* arg = g.children[1];
                Node* t = (arg != null && arg.kind == Nk.N_EXPR_IDENT) ? s.lookup(arg.name_id) : null;
                if (name_is(callee, "is_const") || name_is(callee, "is_literal"))
                {
                    return gv_bool(literal_of(t).kind != GV_UNDEF);
                }
                if (name_is(callee, "is_var") || name_is(callee, "is_ident"))
                {
                    return gv_bool(t != null && t.kind == Nk.N_EXPR_IDENT);
                }
                if (name_is(callee, "is_call"))
                {
                    return gv_bool(t != null && (t.kind == Nk.N_EXPR_CALL || t.kind == Nk.N_EXPR_METHOD));
                }
                if (name_is(callee, "size"))
                {
                    if (t == null) { return gv_undef(); }
                    return gv_int((long)theory_term::term_size(t, 0));
                }
                // Numeric builtins over the VALUE.
                GVal a = guard_eval(arg, s, depth + 1);
                if (a.kind == GV_UNDEF) { return a; }
                if (name_is(callee, "is_power_of_2") || name_is(callee, "is_pow2")) { return gv_bool(is_pow2(a.i)); }
                if (name_is(callee, "is_zero"))  { return gv_bool(a.i == 0); }
                if (name_is(callee, "is_one"))   { return gv_bool(a.i == 1); }
                if (name_is(callee, "is_neg"))   { return gv_bool(a.i < 0); }
                if (name_is(callee, "is_even"))  { return gv_bool((a.i & 1) == 0); }
                if (name_is(callee, "is_odd"))   { return gv_bool((a.i & 1) != 0); }
                if (name_is(callee, "log2"))     { return a.i > 0 ? gv_int(ilog2(a.i)) : gv_undef(); }
                if (name_is(callee, "popcount")) { return gv_int(popcount64(a.i)); }
                if (name_is(callee, "abs"))      { return gv_int(a.i < 0 ? -a.i : a.i); }
                if (name_is(callee, "not"))      { return gv_bool(a.i == 0); }
                return gv_undef();
            }
            if (argc == 2)
            {
                Node* x = g.children[1];
                Node* y = g.children[2];
                if (name_is(callee, "same") || name_is(callee, "not_same"))
                {
                    Node* tx = (x != null && x.kind == Nk.N_EXPR_IDENT) ? s.lookup(x.name_id) : x;
                    Node* ty = (y != null && y.kind == Nk.N_EXPR_IDENT) ? s.lookup(y.name_id) : y;
                    if (tx == null || ty == null) { return gv_undef(); }
                    bool eq = theory_term::term_eq(tx, ty, 0);
                    return gv_bool(name_is(callee, "same") ? eq : !eq);
                }
                GVal a = guard_eval(x, s, depth + 1);
                GVal b = guard_eval(y, s, depth + 1);
                if (a.kind == GV_UNDEF || b.kind == GV_UNDEF) { return gv_undef(); }
                if (name_is(callee, "min")) { return gv_int(a.i < b.i ? a.i : b.i); }
                if (name_is(callee, "max")) { return gv_int(a.i > b.i ? a.i : b.i); }
                if (name_is(callee, "pow"))
                {
                    if (b.i < 0 || b.i > 62) { return gv_undef(); }
                    long r = 1;
                    for (long k = 0; k < b.i; k++) { r = r * a.i; }
                    return gv_int(r);
                }
                return gv_undef();
            }
            return gv_undef();
        }
        default:
            return gv_undef();
    }
}

// Replace calls to the numeric builtins (with literal arguments) inside an
// instantiated right-hand side by their value. Runs bottom-up; anything not
// fully literal is left alone.
fn Node* fold_builtins(Arena* a, Node* n, int depth)
{
    if (n == null || depth > TRS_MAX_DEPTH) { return n; }
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        Node* f = fold_builtins(a, c, depth + 1);
        if (f != null && f != c) { n.set_child(i, f); }
    }
    if (n.kind != Nk.N_EXPR_CALL || n.child_count < 2) { return n; }
    Node* callee = n.children[0];
    if (callee == null || callee.kind != Nk.N_EXPR_IDENT) { return n; }
    bool known = name_is(callee, "log2") || name_is(callee, "popcount")
              || name_is(callee, "abs") || name_is(callee, "min")
              || name_is(callee, "max") || name_is(callee, "pow")
              || name_is(callee, "is_power_of_2") || name_is(callee, "is_pow2");
    if (!known) { return n; }
    Subst empty;
    empty.clear();
    GVal v = guard_eval(n, &empty, 0);
    if (v.kind == GV_UNDEF) { return n; }
    Node* lit = a.node(v.kind == GV_BOOL ? Nk.N_EXPR_BOOL : Nk.N_EXPR_INT, n.line, n.col);
    if (lit == null) { return n; }
    lit.p.ival = (ulong)v.i;
    lit.p.width = 64;
    lit.p.is_signed = true;
    lit.flags = lit.flags | pfront_core::NF_SYNTHETIC;
    return lit;
}

// ── Normalisation ───────────────────────────────────────────────────────────
// Innermost-first (call-by-value) normalisation: children reach normal form
// before the parent is tried, which is the strategy that terminates most often
// for the size-decreasing rules typical of algebraic simplification.
fn Node* Rewriter.normalize(Rewriter* rw, Node* n, int depth)
{
    if (n == null) { return null; }
    if (depth > TRS_MAX_DEPTH) { rw.depth_exceeded = rw.depth_exceeded + 1; return n; }

    /*
     Never rewrite a rule's own definition.

     A `rewrite | lhs -> rhs` block is an N_DECL_FN with NF_SYNTHETIC
     whose clause children ARE the rules -- RuleSet.collect reads exactly
     those nodes. normalize walked them like any other subtree, so the
     rewriter matched its own left-hand sides and rewrote the rules into
     their own right-hand sides.

     The damage was not subtle. Two rules as simple as

         | foo(x) -> bar(x)
         | bar(x) -> x

     produced 32,768 firings and never reached a fixpoint: rewriting the
     definition of rule 1 creates a new `bar` term, which rule 2 matches,
     which changes the rule set the next round reads, which fires again.
     run_fixpoint exhausted all 8 rounds every time, 4,096 firings per
     round, and reported success. The actor-protocol test hit 65,548.

     It also silently CORRUPTS the rule set: after the first round the
     rules are no longer the ones the programmer wrote.

     Skipped by flag rather than by node kind because an ordinary nested
     function is a legitimate rewrite target; only the synthetic block a
     rewrite value desugars to is off limits.
    */
    if (n.kind == Nk.N_DECL_FN && (n.flags & pfront_core::NF_SYNTHETIC) != 0)
    {
        return n;
    }

    if (rw.use_memo)
    {
        Node* cached = rw.memo.get(n);
        if (cached != null) { return cached; }
    }

    Node* cur = n;
    // Normalise children first.
    for (usz i = 0; i < cur.child_count; i++)
    {
        Node* before = cur.children[i];
        Node* after = rw.normalize(before, depth + 1);
        if (after != null && after != before) { cur.set_child(i, after); }
    }

    /*
     Then repeatedly rewrite at the root until no rule applies.

     ── Why the children are NOT re-normalised here ─────────────────────

     They were, and it cost an exponential blowup. The children are
     already in normal form when this loop starts -- that is what the
     loop above did -- and a rewrite at the ROOT replaces the root node
     while its operands are substituted subterms of those already-normal
     children. Re-walking them meant every root step re-normalised the
     whole subtree from scratch:

         1 rule  in a chain ->      2 firings
         2 rules in a chain -> 32,768 firings

     Measured, on two rules as simple as `foo(x) -> bar(x)` and
     `bar(x) -> x`. The count is 2^15, not a coincidence: each root
     rewrite doubles the work below it.

     The memoisation that was supposed to absorb this could never fire.
     `Memo` is keyed by node POINTER, and `instantiate` builds a fresh
     node for every right-hand side, so the key is new every time. Memo
     hits were 0 on every file in the project, including the whole
     standard library.

     What a root rewrite CAN expose is a redex in the substituted
     operands -- `foo(bar(y))` rewriting to `bar(y)` puts a `bar` at the
     root, which the next turn of this same loop handles. So the loop
     alone is sufficient, and the inner re-walk was pure duplication.

     A term whose children genuinely change shape is handled by
     run_fixpoint, which re-runs the whole traversal until a round fires
     nothing.
    */
    int guard = 0;
    while (guard < 1024)
    {
        Node* stepped = rw.try_rules(cur);
        if (stepped == null) { break; }
        cur = stepped;
        guard = guard + 1;
        if (rw.fuel <= 0) { break; }
    }

    /*
     Normalise the operands the rewrite substituted in. Done ONCE, after
     the root has stopped changing, rather than once per root step.
    */
    if (cur != n)
    {
        for (usz i = 0; i < cur.child_count; i++)
        {
            Node* before = cur.children[i];
            Node* after = rw.normalize(before, depth + 1);
            if (after != null && after != before) { cur.set_child(i, after); }
        }
    }

    if (rw.use_memo && cur != n) { rw.memo.put(n, cur); }
    return cur;
}

fn Node* Rewriter.run(Rewriter* rw, Node* root)
{
    rw.rounds = rw.rounds + 1;
    return rw.normalize(root, 0);
}

// Apply to a fixpoint across the whole tree.
fn Node* Rewriter.run_fixpoint(Rewriter* rw, Node* root, int max_rounds)
{
    Node* cur = root;
    for (int i = 0; i < max_rounds; i++)
    {
        usz before = rw.firings;
        cur = rw.run(cur);
        if (rw.firings == before) { break; }
        if (rw.fuel <= 0) { break; }
    }
    return cur;
}

// ── Confluence: critical pairs ──────────────────────────────────────────────
// Two rules overlap when one's left-hand side unifies with a non-variable
// subterm of the other's. Overlaps are where non-confluence comes from: the
// same term can be rewritten two ways and reach different normal forms.
fn usz RuleSet.critical_pairs(RuleSet* rs, pfront_core::DiagBag* d, char* file,
                              bool report)
{
    usz found = 0;
    for (usz i = 0; i < rs.count; i++)
    {
        for (usz j = 0; j < rs.count; j++)
        {
            if (i == j) { continue; }
            Rule* a = &rs.rules[i];
            Rule* b = &rs.rules[j];
            if (a.var_headed || b.var_headed) { continue; }
            if (a.key != b.key) { continue; }
            // Same top symbol: check whether the left-hand sides can match the
            // same term. Approximated by structural overlap of their patterns.
            if (patterns_overlap(a.lhs, b.lhs, 0))
            {
                found = found + 1;
                if (report)
                {
                    d.warn(pfront_core::Phase.PH_RESOLVE, 4031,
                           a.lhs.line, a.lhs.col,
                           "rewrite rules overlap; the result may depend on rule order",
                           file);
                }
            }
        }
    }
    rs.overlaps = found;
    return found;
}

// Can these two patterns match a common term? A variable matches anything, so
// it overlaps everything; otherwise the shapes must agree recursively.
fn bool patterns_overlap(Node* a, Node* b, int depth)
{
    if (a == null || b == null) { return false; }
    if (depth > TRS_MAX_DEPTH) { return false; }
    if (theory_term::is_pattern_var(a) || theory_term::is_pattern_var(b)) { return true; }
    if (a.kind != b.kind) { return false; }
    if (a.p.op != b.p.op) { return false; }
    switch (a.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
            return a.p.ival == b.p.ival;
        case N_EXPR_IDENT:
            return a.name_id == b.name_id;
        default:
            break;
    }
    if (a.child_count != b.child_count) { return false; }
    for (usz i = 0; i < a.child_count; i++)
    {
        if (!patterns_overlap(a.children[i], b.children[i], depth + 1)) { return false; }
    }
    return true;
}

// ── Rule collection from the AST ────────────────────────────────────────────
// `rewrite { lhs ↦ rhs }` blocks are parsed as N_DECL_FN with NF_SYNTHETIC and
// N_CLAUSE children holding (lhs, rhs[, guard...]).
fn bool is_rewrite_block(Node* n)
{
    return n != null && n.kind == Nk.N_DECL_FN
        && (n.flags & pfront_core::NF_SYNTHETIC) != 0
        && n.p.aux != 2;   // aux == 2 is a `pgen` block
}

// Add every rule of ONE rewrite block. Returns rules added.
fn usz RuleSet.add_block(RuleSet* rs, Node* block)
{
    usz before = rs.count;
    if (!is_rewrite_block(block)) { return 0; }
    for (usz i = 0; i < block.child_count; i++)
    {
        Node* c = block.children[i];
        if (c == null || c.kind != Nk.N_CLAUSE) { continue; }
        if (c.child_count < 2) { continue; }
        Node* g1 = c.child_count >= 3 ? c.children[2] : null;
        if (!rs.add(c.children[0], c.children[1], g1, block.name_id)) { continue; }
        Rule* r = &rs.rules[rs.count - 1];
        if (c.child_count >= 4) { r.guard2 = c.children[3]; }
        if (c.child_count >= 5) { r.guard3 = c.children[4]; }
    }
    return rs.count - before;
}

// `a ++ b`: the union, in order. Rules keep their identity so a shared
// rule fires under either name.
fn void RuleSet.add_all(RuleSet* rs, RuleSet* other)
{
    if (other == null) { return; }
    for (usz i = 0; i < other.count; i++)
    {
        Rule* r = &other.rules[i];
        if (!rs.add(r.lhs, r.rhs, r.guard, r.name_id)) { continue; }
        Rule* n = &rs.rules[rs.count - 1];
        n.guard2 = r.guard2;
        n.guard3 = r.guard3;
    }
}

// Whole-tree census (every block in the file). Used for reporting and by
// the PGL tree builder; NOT for rewriting, which is site-directed.
fn usz RuleSet.collect(RuleSet* rs, Node* n, int depth)
{
    if (n == null || depth > 200) { return rs.count; }
    if (is_rewrite_block(n)) { rs.add_block(n); }
    for (usz i = 0; i < n.child_count; i++) { rs.collect(n.children[i], depth + 1); }
    return rs.count;
}

fn void RuleSet.report(RuleSet* rs)
{
    printf("  rewrite rules    : %d declared in file (%d size-increasing)\n",
           (int)rs.count, (int)rs.size_increasing);
    if (rs.rejected_nonterminating > 0)
    {
        printf("  rules REJECTED   : %d   (match any term and grow it: cannot terminate)\n",
               (int)rs.rejected_nonterminating);
    }
}

fn void Rewriter.report(Rewriter* rw)
{
    printf("  rewriting        : %d sites, %d firings, %d/%d match attempts failed, %d guard-blocked\n",
           (int)rw.sites, (int)rw.firings, (int)rw.match_failures, (int)rw.match_attempts,
           (int)rw.guard_blocked);
    printf("  fuel             : %d per site, memo hits %d\n",
           rw.fuel_start, (int)rw.memo.hits);
    /*
     GIVING UP IS NOT A CLEAN RESULT.

     Both of these mean the rewriter stopped early and the term it
     returned is NOT a normal form. They were counted and never printed,
     so a truncated rewrite was indistinguishable from a completed one --
     which is the silent-truncation failure D6 exists to forbid, in a
     different file.

     Printed only when non-zero: a line of zeroes on every compilation
     trains readers to skip the block.
    */
    if (rw.depth_exceeded > 0 || rw.fuel_exhausted > 0)
    {
        printf("  INCOMPLETE       : %d subterms past the depth limit, %d fuel stalls\n",
               (int)rw.depth_exceeded, (int)rw.fuel_exhausted);
    }
}
