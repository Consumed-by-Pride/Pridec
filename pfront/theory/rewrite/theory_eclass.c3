// ============================================================================
// theory_eclass.c3 — E-class analyses (egg §4), attached to the real e-graph
// ----------------------------------------------------------------------------
// An e-class analysis is a semilattice value maintained per e-class: computed
// from a node when it is added (`make`), joined when two classes merge
// (`join`), and re-propagated to parents when children change (`modify`
// during rebuild). Because every node in a class denotes the same value, a
// fact proved about ONE node is a fact about the class.
//
// This module implements the analysis that matters for an optimiser — the
// CONSTANT analysis — and wires it into `theory_egraph` at the three points
// egg names:
//
//   make    on_add(g, nid)        a literal makes its class constant; an
//                                 operator whose child classes are all
//                                 constant is folded (δ) and makes its class
//                                 constant too
//   join    on_merge(g, a, b)     const ⊔ none = const; const c ⊔ const c = c;
//                                 const c ⊔ const d (c ≠ d) = CONTRADICTION
//   modify  propagate(g)          after congruence repair, any class that
//                                 became constant gets the literal e-node
//                                 ADDED to it, so extraction (which minimises
//                                 cost) picks the literal over the expression;
//                                 parents are re-examined to a fixpoint
//
// A contradiction is the e-graph proving `1 = 0`. That only happens when the
// rule set asserted an equality that is false — `rewrite | x ↦ 0` say — and
// it is reported at the `|>*` site (W4034) instead of being extracted as
// whatever node happened to be cheapest. Under --strict-types it is an error.
//
// What was here before assigned "classes" by hashing AST node pointers and
// fed them to the lattice; it never touched the e-graph. Every number below
// is now read from the graph.
// ============================================================================

module theory_eclass;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_egraph;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias EGraph = theory_egraph::EGraph;
alias ENode  = theory_egraph::ENode;
alias EClass = theory_egraph::EClass;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);
extern fn int   snprintf(char* buf, usz cap, char* fmt, ...);

// Lattice states stored in EClass.cstate.
const int CL_NONE  = 0;    // nothing known yet
const int CL_CONST = 1;    // EClass.cval is the value; cbool says which literal kind
const int CL_TOP   = 2;    // contradiction: two different constants merged

const long EC_LIM = 1L << 40;   // δ never decides anything width-dependent

// ── make ────────────────────────────────────────────────────────────────────
// Is this e-node a literal, or an operator over constant classes? If so,
// what value does it denote?
fn bool eclass_value_of(EGraph* g, ENode* n, long* out, bool* is_bool)
{
    if (n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_CHAR) { *out = (long)n.ival; *is_bool = false; return true; }
    if (n.kind == Nk.N_EXPR_BOOL) { *out = n.ival != 0 ? 1 : 0; *is_bool = true; return true; }

    if (n.kind == Nk.N_EXPR_TUPLE && n.child_count == 1)
    {
        int c = g.find(n.children[0]);
        if (c < 0 || g.classes[c].cstate != CL_CONST) { return false; }
        *out = g.classes[c].cval; *is_bool = g.classes[c].cbool; return true;
    }

    if (n.kind == Nk.N_EXPR_UNARY && n.child_count == 1)
    {
        int c = g.find(n.children[0]);
        if (c < 0 || g.classes[c].cstate != CL_CONST) { return false; }
        long a = g.classes[c].cval;
        Tk op = (Tk)n.op;
        if (g.classes[c].cbool)
        {
            if (op == Tk.TOKEN_BANG || op == Tk.TOKEN_KW_NOT) { *out = a != 0 ? 0 : 1; *is_bool = true; return true; }
            return false;
        }
        if (op == Tk.TOKEN_MINUS && a > -EC_LIM && a < EC_LIM) { *out = -a; *is_bool = false; return true; }
        return false;
    }

    if (n.kind == Nk.N_EXPR_BINARY && n.child_count == 2)
    {
        int ca = g.find(n.children[0]);
        int cb = g.find(n.children[1]);
        if (ca < 0 || cb < 0) { return false; }
        if (g.classes[ca].cstate != CL_CONST || g.classes[cb].cstate != CL_CONST) { return false; }
        long a = g.classes[ca].cval;
        long b = g.classes[cb].cval;
        bool ba = g.classes[ca].cbool;
        bool bb = g.classes[cb].cbool;
        Tk op = (Tk)n.op;
        if (ba || bb)
        {
            if (ba != bb) { return false; }
            bool x = a != 0; bool y = b != 0;
            *is_bool = true;
            switch (op)
            {
                case TOKEN_AMPAMP: case TOKEN_KW_AND: *out = (x && y) ? 1 : 0; return true;
                case TOKEN_PIPEPIPE: case TOKEN_KW_OR: *out = (x || y) ? 1 : 0; return true;
                case TOKEN_EQEQ: *out = x == y ? 1 : 0; return true;
                case TOKEN_NEQ: case TOKEN_NEQ_UNI: *out = x != y ? 1 : 0; return true;
                default: return false;
            }
        }
        if (a <= -EC_LIM || a >= EC_LIM || b <= -EC_LIM || b >= EC_LIM) { return false; }
        *is_bool = false;
        switch (op)
        {
            case TOKEN_PLUS:    *out = a + b; return true;
            case TOKEN_MINUS:   *out = a - b; return true;
            case TOKEN_STAR:    *out = a * b; return true;
            case TOKEN_SLASH:   if (b == 0) { return false; } *out = a / b; return true;
            case TOKEN_PERCENT: if (b == 0) { return false; } *out = a % b; return true;
            case TOKEN_LSHIFT:     if (b < 0 || b > 40) { return false; } *out = a << b; return true;
            case TOKEN_RSHIFT:     if (b < 0 || b > 63) { return false; } *out = a >> b; return true;
            case TOKEN_AMP:     *out = a & b; return true;
            case TOKEN_PIPE:    *out = a | b; return true;
            case TOKEN_XOR:   *out = a ^ b; return true;
            case TOKEN_EQEQ:    *out = a == b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_NEQ:     *out = a != b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_NEQ_UNI: *out = a != b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_LT:      *out = a <  b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_LTEQ:    *out = a <= b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_GT:      *out = a >  b ? 1 : 0; *is_bool = true; return true;
            case TOKEN_GTEQ:    *out = a >= b ? 1 : 0; *is_bool = true; return true;
            default: return false;
        }
    }
    return false;
}

// Set a class constant; returns true if the class changed.
fn bool eclass_set_const(EGraph* g, int cid, long v, bool is_bool)
{
    EClass* c = &g.classes[cid];
    if (c.cstate == CL_TOP) { return false; }
    if (c.cstate == CL_CONST)
    {
        if (c.cval == v && c.cbool == is_bool) { return false; }
        c.cstate = CL_TOP;
        g.an_contradictions = g.an_contradictions + 1;
        eclass_report_contradiction(g, c.cval, v);
        return true;
    }
    c.cstate = CL_CONST;
    c.cval = v;
    c.cbool = is_bool;
    c.cfolded = false;
    g.an_const_classes = g.an_const_classes + 1;
    return true;
}

fn void eclass_report_contradiction(EGraph* g, long a, long b)
{
    if (g.diags == null || g.an_reported) { return; }
    g.an_reported = true;
    char* msg = (char*)g.arena.alloc(200, 1);
    if (msg == null) { return; }
    snprintf(msg, 200, "rewrite rules equate the distinct constants %ld and %ld: the rule set is unsound, result left unrewritten", a, b);
    int line = g.site != null ? g.site.line : 0;
    int col = g.site != null ? g.site.col : 0;
    if (g.strict) { g.diags.error(pfront_core::Phase.PH_RESOLVE, 4034, line, col, msg, g.file); }
    else { g.diags.warn(pfront_core::Phase.PH_RESOLVE, 4034, line, col, msg, g.file); }
}

// make: called by EGraph.add_node for every new e-node.
fn void on_add(EGraph* g, int nid)
{
    if (nid < 0 || (usz)nid >= g.node_count) { return; }
    ENode* n = &g.nodes[nid];
    long v; bool b;
    if (!eclass_value_of(g, n, &v, &b)) { return; }
    int c = g.find(n.klass);
    if (c < 0) { return; }
    bool lit = n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_BOOL || n.kind == Nk.N_EXPR_CHAR;
    if (eclass_set_const(g, c, v, b) && !lit) { g.an_folds = g.an_folds + 1; }
    if (lit) { g.classes[c].cfolded = true; }   // the literal is already in the class
}

// join: called by EGraph.merge with the two ROOTS before they are unioned
// (ra survives).
fn void on_merge(EGraph* g, int ra, int rb)
{
    EClass* a = &g.classes[ra];
    EClass* b = &g.classes[rb];
    if (b.cstate == CL_NONE) { return; }
    if (b.cstate == CL_TOP) { a.cstate = CL_TOP; return; }
    if (a.cstate == CL_NONE)
    {
        a.cstate = CL_CONST; a.cval = b.cval; a.cbool = b.cbool; a.cfolded = b.cfolded;
        return;
    }
    if (a.cstate == CL_CONST)
    {
        if (a.cval != b.cval || a.cbool != b.cbool)
        {
            a.cstate = CL_TOP;
            g.an_contradictions = g.an_contradictions + 1;
            eclass_report_contradiction(g, a.cval, b.cval);
        }
        else if (b.cfolded) { a.cfolded = true; }
    }
}

// modify: after rebuild, (1) fold any node whose children have since become
// constant, to a fixpoint; (2) give every constant class its literal e-node
// so the extractor can choose it.
fn void propagate(EGraph* g)
{
    bool changed = true;
    int rounds = 0;
    while (changed && rounds < 16)
    {
        changed = false;
        rounds = rounds + 1;
        for (usz ni = 0; ni < g.node_count; ni++)
        {
            ENode* n = &g.nodes[ni];
            if (n.child_count == 0) { continue; }
            int c = g.find(n.klass);
            if (c < 0 || g.classes[c].cstate != CL_NONE) { continue; }
            long v; bool b;
            if (!eclass_value_of(g, n, &v, &b)) { continue; }
            if (eclass_set_const(g, c, v, b)) { g.an_folds = g.an_folds + 1; changed = true; }
        }
    }
    // Materialise literals. Adding a node may merge classes (hashcons hit on
    // an existing literal), which is exactly the equality we want recorded.
    usz classes_now = g.class_count;
    for (usz ci = 0; ci < classes_now; ci++)
    {
        int c = g.find((int)ci);
        if (c < 0 || (usz)c != ci) { continue; }              // roots only
        EClass* cls = &g.classes[c];
        if (cls.cstate != CL_CONST || cls.cfolded) { continue; }
        // Position: any origin in the class.
        Node* at = null;
        for (usz k = 0; k < cls.node_count && at == null; k++)
        {
            int nid = cls.nodes[k];
            if (nid >= 0 && (usz)nid < g.node_count) { at = g.nodes[nid].origin; }
        }
        Node* lit = g.arena.node(cls.cbool ? Nk.N_EXPR_BOOL : Nk.N_EXPR_INT, at != null ? at.line : 0, at != null ? at.col : 0);
        if (lit == null) { continue; }
        lit.flags = pfront_core::NF_SYNTHETIC;
        lit.p.ival = (ulong)cls.cval;
        if (at != null) { lit.p.width = at.p.width; lit.p.is_signed = at.p.is_signed; lit.type_id = at.type_id; }
        cls.cfolded = true;
        int lc = g.add_term(lit, 0);
        if (lc >= 0) { g.merge(c, lc); g.an_literals_added = g.an_literals_added + 1; }
    }
    if (g.worklist_len > 0) { g.rebuild(); }
}

// ── Pipeline-facing shell ───────────────────────────────────────────────────
// The pipeline owns one of these; it only reports what the e-graph did.
struct EClassAnalyses
{
    theory_egraph::Saturator* sat;
}

fn void EClassAnalyses.attach(EClassAnalyses* eca, theory_egraph::Saturator* sat) { eca.sat = sat; }
fn void EClassAnalyses.destroy(EClassAnalyses* eca) { eca.sat = null; }

fn void EClassAnalyses.report(EClassAnalyses* eca)
{
    if (eca.sat == null) { return; }
    EGraph* g = eca.sat.eg;
    if (g == null) { return; }
    if (eca.sat.terms_optimised == 0 && g.an_const_classes == 0) { return; }
    printf("  eclass-analysis  : %d constant classes, %d folds, %d literals materialised, %d contradictions\n",
           (int)g.an_const_classes, (int)g.an_folds, (int)g.an_literals_added, (int)g.an_contradictions);
}
