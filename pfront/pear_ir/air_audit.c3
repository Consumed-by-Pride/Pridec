// ============================================================================
// air_audit.c3 — "was every source construct lowered?" instrument.
//
// The lowerer marks each PNode it consumes (air_audit::mark). After lowering a
// module, air_audit::report walks the same tree and prints every construct of a
// semantic kind (expression, statement, block, declaration, clause, pattern, arm)
// that no lowering routine ever looked at, as `air-audit: UNLOWERED kind line:col`.
// Only the OUTERMOST unlowered node of a subtree is reported.
//
// This is a measurement, not a proof: a node can be "looked at" and still be
// lowered wrongly (see air_lower.c3 notes, tests/air/VERIFY_KNOWN.tsv). What it
// does rule out is the silent-drop class: a statement that the front end accepted
// and the .air never mentions. Enabled by `pfrontc --air-audit`; off otherwise.
// ============================================================================
module air_audit;

import pfront_core;

alias Node = pfront_core::PNode;
alias Nk   = pfront_core::NodeKind;

extern fn void* calloc(usz nmemb, usz size);
extern fn int   printf(char* fmt, ...);

bool    g_on  = false;
ulong*  g_bits = null;
usz     g_cap_words = 0;       // capacity of g_bits in 64-bit words

char*[256] g_paths;
fn void enable(bool on) { g_on = on; }
fn void set_path(usz idx, char* p) { if (idx < 256) { g_paths[idx] = p; } }

fn void grow_for(uint id)
{
    usz need = (usz)(id / 64) + 1;
    if (need <= g_cap_words) { return; }
    usz ncap = g_cap_words == 0 ? 4096 : g_cap_words;
    while (ncap < need) { ncap = ncap * 2; }
    ulong* nb = (ulong*)calloc(ncap, 8);
    if (nb == null) { g_on = false; return; }
    for (usz i = 0; i < g_cap_words; i++) { nb[i] = g_bits[i]; }
    // the old block is leaked on purpose: the audit is a diagnostic run
    g_bits = nb;
    g_cap_words = ncap;
}

fn void mark(Node* n)
{
    if (!g_on || n == null) { return; }
    grow_for(n.id);
    if (!g_on) { return; }
    g_bits[n.id / 64] |= (ulong)1 << (n.id % 64);
}

fn bool seen(Node* n)
{
    usz w = (usz)(n.id / 64);
    if (w >= g_cap_words) { return false; }
    return (g_bits[w] & ((ulong)1 << (n.id % 64))) != 0;
}

// Kinds whose absence from the .air is a lowering gap (not a type, not a
// parameter/field/variant list entry that its parent lowers by name).
fn bool audited(Nk k)
{
    switch (k)
    {
        case Nk.N_DECL_FN:
        case Nk.N_DECL_LET:
        case Nk.N_DECL_CONST:
        case Nk.N_DECL_STATIC:
        case Nk.N_DECL_TYPE:
        case Nk.N_DECL_STRUCT:
        case Nk.N_DECL_UNION:
        case Nk.N_DECL_ENUM:
        case Nk.N_DECL_NEWTYPE:
        case Nk.N_DECL_EFFECT:
        case Nk.N_DECL_INTERFACE:
        case Nk.N_DECL_IMPL:
        case Nk.N_DECL_EXTERN_FN:
        case Nk.N_STMT_EXPR:
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_STMT_DEFER:
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        case Nk.N_BLOCK:
        case Nk.N_MATCH_ARM:
        case Nk.N_HANDLER_ARM:
            return true;
        default:
            return pfront_core::is_expr(k);
    }
}

usz g_reported = 0;
usz g_examined = 0;

// A subtree the lowering deliberately does not translate. `why` 0: compile-time only (rewrite /
// IRDL rule clauses are applied by the theory layer before lowering and are not part of the
// program); 1: omitted because the flat AIR namespace already holds a libc `write`/`malloc`/`free`.
fn void mark_tree(Node* n)
{
    if (n == null) { return; }
    mark(n);
    for (usz i = 0; i < n.child_count; i++) { mark_tree(n.children[i]); }
}
fn void skip(Node* n, int why)
{
    if (!g_on || n == null) { return; }
    mark_tree(n);
    printf("air-audit: SKIPPED %s %s %d:%d\n", why == 0 ? "compile-time-only" : "name-collision",
           pfront_core::kind_name(n.kind), n.line, n.col);
}

fn void walk(Node* n, char* mod_name, int depth)
{
    if (n == null || depth > 400) { return; }
    if (pfront_core::is_type(n.kind)) { return; }
    // A clause whose left side is an expression is a rewrite / IRDL rule (also the inline
    // `rewrite | ... ↦ ...` values): applied by the theory layer, not part of the program.
    if (n.kind == Nk.N_CLAUSE && n.child_count > 0 && n.children[0] != null
        && pfront_core::is_expr(n.children[0].kind) && !pfront_core::is_pattern(n.children[0].kind))
    {
        if (!seen(n)) { skip(n, 0); }
        return;
    }
    // Patterns are lowered by AirLower.pat as a whole (their literal expressions included).
    if (pfront_core::is_pattern(n.kind)) { return; }
    if (audited(n.kind))
    {
        g_examined++;
        if (!seen(n))
        {
            g_reported++;
            printf("air-audit: UNLOWERED %s %d:%d under %s in %s\n", pfront_core::kind_name(n.kind), n.line, n.col, n.parent != null ? pfront_core::kind_name(n.parent.kind) : "-", mod_name);
            return;
        }
    }
    // An interface declares method SIGNATURES only (no bodies); methods are resolved at type
    // check time and impl dictionaries are eliminated before lowering (docs/pear2/LOWERING.md).
    if (n.kind == Nk.N_DECL_INTERFACE) { return; }
    for (usz i = 0; i < n.child_count; i++) { walk(n.children[i], mod_name, depth + 1); }
}

fn void report(Node* root, usz idx, char* fallback_name, bool is_entry)
{
    if (!g_on) { return; }
    char* mod_name = (idx < 256 && g_paths[idx] != null) ? g_paths[idx] : fallback_name;
    usz before_r = g_reported; usz before_e = g_examined;
    walk(root, mod_name, 0);
    printf("air-audit: MODULE %s %s examined=%d unlowered=%d\n", is_entry ? "entry" : "library", mod_name,
           (int)(g_examined - before_e), (int)(g_reported - before_r));
}
