// ============================================================================
// pfront_stats.c3 — Whole-program statistics collection
// ----------------------------------------------------------------------------
// Walks the entire AST collecting detailed counts for --time-passes reports.
// ============================================================================

module pfront_stats;

import pfront_core;

alias Nk    = pfront_core::NodeKind;
alias Node  = pfront_core::PNode;
alias Arena = pfront_core::Arena;

extern fn int printf(char* fmt, ...);

struct AstStats
{
    Arena* arena;
    usz nodes; usz decls; usz exprs; usz pats; usz types; usz stmts; usz clauses;
    usz fns; usz extern_fns; usz lets; usz muts; usz structs; usz enums;
    usz traits; usz aliases; usz constants; usz interfaces; usz imports; usz modules;
    usz total_fn_size; usz largest_fn;
    usz matches; usz match_arms; usz largest_match;
    usz loops_while; usz loops_for; usz loops_loop;
    usz calls; usz returns; usz breaks; usz continues;
    usz defers; usz trys; usz handles;
    usz binops; usz unops; usz index_ops; usz field_ops;
    usz derefs; usz refs; usz casts; usz tuples; usz arrays; usz lambdas;
    usz quotes; usz splices;
    usz lit_int; usz lit_float; usz lit_bool; usz lit_char; usz lit_str;
    usz lit_null; usz lit_unit; usz idents; usz paths;
    usz effects_total; usz effects_io; usz effects_alloc;
    usz effects_unsafe; usz effects_ub; usz effects_panic; usz effects_diverge;
    usz max_depth; usz depth_total; usz depth_count;
}

fn void AstStats.init(AstStats* s, Arena* a)
{
    s.arena = a;
    s.nodes = 0; s.decls = 0; s.exprs = 0; s.pats = 0; s.types = 0;
    s.stmts = 0; s.clauses = 0; s.fns = 0; s.extern_fns = 0; s.lets = 0;
    s.muts = 0; s.structs = 0; s.enums = 0; s.traits = 0; s.aliases = 0;
    s.constants = 0; s.interfaces = 0; s.imports = 0; s.modules = 0;
    s.total_fn_size = 0; s.largest_fn = 0;
    s.matches = 0; s.match_arms = 0; s.largest_match = 0;
    s.loops_while = 0; s.loops_for = 0; s.loops_loop = 0;
    s.calls = 0; s.returns = 0; s.breaks = 0; s.continues = 0;
    s.defers = 0; s.trys = 0; s.handles = 0;
    s.binops = 0; s.unops = 0; s.index_ops = 0; s.field_ops = 0;
    s.derefs = 0; s.refs = 0; s.casts = 0; s.tuples = 0; s.arrays = 0; s.lambdas = 0;
    s.quotes = 0; s.splices = 0;
    s.lit_int = 0; s.lit_float = 0; s.lit_bool = 0; s.lit_char = 0; s.lit_str = 0;
    s.lit_null = 0; s.lit_unit = 0; s.idents = 0; s.paths = 0;
    s.effects_total = 0; s.effects_io = 0; s.effects_alloc = 0;
    s.effects_unsafe = 0; s.effects_ub = 0; s.effects_panic = 0; s.effects_diverge = 0;
    s.max_depth = 0; s.depth_total = 0; s.depth_count = 0;
}

fn bool is_type_kind(Nk k)
{
    // Crude range check on enum ordinal.
    int ki = (int)k;
    return ki >= (int)Nk.N_TY_NAME && ki <= (int)Nk.N_TY_REFINE;
}

fn bool is_pat_kind(Nk k)
{
    int ki = (int)k;
    return ki >= (int)Nk.N_PAT_WILDCARD && ki <= (int)Nk.N_PAT_REST;
}

fn usz ast_subtree_size(Node* n)
{
    if (n == null) return 0;
    usz c = 1;
    for (usz i = 0; i < n.child_count; i++) c = c + ast_subtree_size(n.children[i]);
    return c;
}

fn void AstStats.walk(AstStats* s, Node* n, int depth)
{
    if (n == null) return;
    s.nodes++;
    if (depth < 0) depth = 0;
    if ((usz)depth > s.max_depth) s.max_depth = (usz)depth;
    s.depth_total = s.depth_total + (usz)depth;
    s.depth_count++;
    Nk k = n.kind;
    if (k == Nk.N_DECL_FN) { s.decls++; s.fns++; }
    else if (k == Nk.N_DECL_EXTERN_FN) { s.decls++; s.extern_fns++; }
    else if (k == Nk.N_DECL_LET) { s.decls++; s.lets++; if ((n.flags & 1u) != 0) s.muts++; }
    else if (k == Nk.N_DECL_STRUCT) { s.decls++; s.structs++; }
    else if (k == Nk.N_DECL_ENUM) { s.decls++; s.enums++; }
    else if (k == Nk.N_DECL_INTERFACE) { s.decls++; s.interfaces++; s.traits++; }
    else if (k == Nk.N_DECL_TYPE) { s.decls++; s.aliases++; }
    else if (k == Nk.N_DECL_CONST) { s.decls++; s.constants++; }
    else if (k == Nk.N_DECL_UNION) { s.decls++; }
    else if (k == Nk.N_MODULE) { s.modules++; }
    else if (k == Nk.N_USE) { s.imports++; }
    else if (k == Nk.N_CLAUSE) { s.clauses++; }
    else if (k == Nk.N_EXPR_IF) { s.exprs++; }
    else if (k == Nk.N_EXPR_WHILE) { s.exprs++; s.loops_while++; }
    else if (k == Nk.N_EXPR_FOR) { s.exprs++; s.loops_for++; }
    else if (k == Nk.N_EXPR_LOOP) { s.exprs++; s.loops_loop++; }
    else if (k == Nk.N_EXPR_CALL) { s.exprs++; s.calls++; }
    else if (k == Nk.N_STMT_RETURN) { { s.stmts++; } s.returns++; }
    else if (k == Nk.N_STMT_BREAK) { { s.stmts++; } s.breaks++; }
    else if (k == Nk.N_STMT_CONTINUE) { { s.stmts++; } s.continues++; }
    else if (k == Nk.N_STMT_DEFER) { { s.stmts++; } s.defers++; }
    else if (k == Nk.N_EXPR_TRY) { s.exprs++; s.trys++; }
    else if (k == Nk.N_EXPR_HANDLE) { s.exprs++; s.handles++; }
    else if (k == Nk.N_EXPR_BINARY) { s.exprs++; s.binops++; }
    else if (k == Nk.N_EXPR_UNARY) { s.exprs++; s.unops++; }
    else if (k == Nk.N_EXPR_INDEX) { s.exprs++; s.index_ops++; }
    else if (k == Nk.N_EXPR_FIELD) { s.exprs++; s.field_ops++; }
    else if (k == Nk.N_EXPR_DEREF) { s.exprs++; s.derefs++; }
    else if (k == Nk.N_EXPR_REF) { s.exprs++; s.refs++; }
    else if (k == Nk.N_EXPR_CAST) { s.exprs++; s.casts++; }
    else if (k == Nk.N_EXPR_TUPLE) { s.exprs++; s.tuples++; }
    else if (k == Nk.N_EXPR_ARRAY) { s.exprs++; s.arrays++; }
    else if (k == Nk.N_EXPR_LAMBDA) { s.exprs++; s.lambdas++; s.fns++; }
    else if (k == Nk.N_EXPR_QUOTE) { s.exprs++; s.quotes++; }
    else if (k == Nk.N_EXPR_SPLICE) { s.exprs++; s.splices++; }
    else if (k == Nk.N_EXPR_MATCH)
    {
        s.exprs++; s.matches++;
        usz arms = n.child_count >= 1 ? n.child_count - 1 : 0;
        s.match_arms = s.match_arms + arms;
        if (arms > s.largest_match) s.largest_match = arms;
    }
    else if (k == Nk.N_EXPR_INT) { s.lit_int++; }
    else if (k == Nk.N_EXPR_FLOAT) { s.lit_float++; }
    else if (k == Nk.N_EXPR_BOOL) { s.lit_bool++; }
    else if (k == Nk.N_EXPR_CHAR) { s.lit_char++; }
    else if (k == Nk.N_EXPR_STRING) { s.lit_str++; }
    else if (k == Nk.N_EXPR_NULL) { s.lit_null++; }
    else if (k == Nk.N_EXPR_UNIT) { s.lit_unit++; }
    else if (k == Nk.N_EXPR_IDENT) { s.idents++; }
    else if (k == Nk.N_EXPR_PATH) { s.paths++; }
    else if (k == Nk.N_BLOCK) { s.stmts++; }
    else if (is_pat_kind(k)) { s.pats++; }
    else if (is_type_kind(k)) { s.types++; }

    if ((n.effects & 1) != 0) s.effects_io++;
    if ((n.effects & 2) != 0) s.effects_alloc++;
    if ((n.effects & 4) != 0) s.effects_unsafe++;
    if ((n.effects & 8) != 0) s.effects_ub++;
    if ((n.effects & 16) != 0) s.effects_panic++;
    if ((n.effects & 32) != 0) s.effects_diverge++;
    if (n.effects != 0) s.effects_total++;

    if (k == Nk.N_DECL_FN)
    {
        usz fsz = ast_subtree_size(n);
        s.total_fn_size = s.total_fn_size + fsz;
        if (fsz > s.largest_fn) s.largest_fn = fsz;
    }
    for (usz i = 0; i < n.child_count; i++) s.walk(n.children[i], depth + 1);
}

fn void AstStats.run(AstStats* s, Node* root)
{
    if (root != null) s.walk(root, 0);
}

fn void AstStats.report(AstStats* s)
{
    printf("  ast nodes        : %d (%d decls, %d exprs, %d stmts, %d pats, %d types)\n",
           (int)s.nodes, (int)s.decls, (int)s.exprs, (int)s.stmts, (int)s.pats, (int)s.types);
    printf("  ast functions    : %d (ext %d, lambdas inlined), largest %d nodes\n",
           (int)s.fns, (int)s.extern_fns, (int)s.largest_fn);
    printf("  ast lets         : %d (mut %d), structs %d, enums %d, ifaces %d, aliases %d, consts %d\n",
           (int)s.lets, (int)s.muts, (int)s.structs, (int)s.enums,
           (int)s.traits, (int)s.aliases, (int)s.constants);
    printf("  ast matches      : %d (%d arms, max %d), loops while %d for %d loop %d\n",
           (int)s.matches, (int)s.match_arms, (int)s.largest_match,
           (int)s.loops_while, (int)s.loops_for, (int)s.loops_loop);
    printf("  ast calls        : %d, returns %d, breaks %d, continues %d, defers %d, trys %d, handles %d\n",
           (int)s.calls, (int)s.returns, (int)s.breaks, (int)s.continues,
           (int)s.defers, (int)s.trys, (int)s.handles);
    printf("  ast ops          : bin %d, un %d, idx %d, fld %d, deref %d, ref %d, cast %d\n",
           (int)s.binops, (int)s.unops, (int)s.index_ops, (int)s.field_ops,
           (int)s.derefs, (int)s.refs, (int)s.casts);
    printf("  ast literals     : int %d, float %d, bool %d, char %d, str %d, null %d\n",
           (int)s.lit_int, (int)s.lit_float, (int)s.lit_bool, (int)s.lit_char,
           (int)s.lit_str, (int)s.lit_null);
    printf("  ast compounds    : tuple %d, array %d, lambda %d, quote %d, splice %d\n",
           (int)s.tuples, (int)s.arrays, (int)s.lambdas, (int)s.quotes, (int)s.splices);
    printf("  ast modules      : %d, uses/imports %d, max depth %d\n",
           (int)s.modules, (int)s.imports, (int)s.max_depth);
}
