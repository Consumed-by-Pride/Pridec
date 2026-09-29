// ============================================================================
// theory_crdt.c3 — commutativity analysis: statement independence, loop
//                  reductions and the CALM/CRDT classification of accumulators
// ----------------------------------------------------------------------------
// The question this module answers is the CALM question (Hellerstein &
// Alvaro 2010): which parts of a program are *order-insensitive*? Two
// operations commute when running them in either order yields the same
// state; a loop whose iterations pairwise commute is a monotone
// accumulation — its accumulator is a CRDT (Shapiro et al. 2011) and the
// loop may be split, reordered, vectorised or run in parallel with no
// coordination. Anything that does not commute needs its program order kept.
//
// What is computed
//
//   1. EFFECT SUMMARIES. Every statement gets a set of *locations* it reads
//      and a set it writes. A location is
//          VAR(b)    a named binder (local, parameter, global, static)
//          HEAP(b)   memory reachable through binder `b` (p.x, a[i], *p, &p)
//          WORLD     everything else: the heap through a computed pointer,
//                    an impure callee, an extern, an effect operation
//      Calls consult the purity verdict written back by theory_quals
//      (NF_PURE_FN): a call to a proven-pure function only reads its
//      arguments; any other call reads and writes WORLD. `return`,
//      `break`, `continue`, `perform` are *barriers*: order is part of their
//      meaning, they conflict with every neighbour.
//
//   2. STATEMENT DEPENDENCE. Within each block, statements i < j conflict
//      when i writes something j touches (RAW), j writes something i reads
//      (WAR) or both write the same location (WAW). The transitive skeleton
//      of that relation is the block's dependence DAG; its longest chain is
//      the *critical path*, and (statements − critical path) is the slack a
//      scheduler may exploit. Adjacent statements that do not conflict may
//      be swapped: the second one is flagged NF_INDEPENDENT so a later
//      scheduler / lowering can hoist or sink it without re-deriving alias
//      facts.
//
//   3. LOOP REDUCTIONS. For every loop body, each local variable written in
//      it is classified by *how* it is written, using the CRDT lattice:
//          COUNTER    b = b ± e, b += e            (PN-counter: assoc+comm)
//          PRODUCT    b = b * e                    (assoc+comm)
//          JOIN       b = b | e, b = b & e, b ^= e (∨/∧-semilattice: ACI; ^ is
//                     assoc+comm but not idempotent — tracked as PRODUCT-like)
//          MAXMIN     if e > b then b = e          (max/min register: ACI)
//          REGISTER   b = e   (plain overwrite: last-writer-wins, order matters)
//          MIXED      several incompatible update shapes
//      and by whether it is read anywhere in the body other than in its own
//      updates (an *induction variable* is a COUNTER that is: it feeds the
//      condition or an index). The body's other effects are checked too: a
//      barrier, a WORLD write or a HEAP write make the iterations
//      non-commuting regardless of the accumulators.
//      A loop whose every written local is an ACI accumulator (or an
//      induction variable stepping by a constant) and whose body has no
//      other write is a *commutative reduction*: it is flagged NF_REDUCTION
//      and, under --lint, reported (N4230) with the accumulator list.
//
// Diagnostics
//     N4230 (--lint) loop is a commutative reduction over the listed
//                    accumulators; iterations may run in any order
//     N4231 (--lint) accumulator updated by plain assignment inside a loop
//                    whose other updates are commutative (the one thing that
//                    pins the iteration order — often `last = x`)
//
// Report line (see tests/pfront/run.sh `crdt` block)
//     crdt-commute     : %d blocks, %d stmts, %d dependences (%d raw, %d war, %d waw),
//                        %d adjacent pairs commute, critical path %d / %d
//     crdt-loops       : %d loops: %d commutative reductions, %d counting, %d ordered;
//                        accumulators %d counter, %d product, %d join, %d maxmin,
//                        %d register, %d mixed, %d induction
//
// Runs AFTER theory_quals (needs NF_PURE_FN).
// ============================================================================

module theory_crdt;

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

const usz CR_MAX_LOCS   = 48;     // per effect set; overflow collapses to WORLD
const usz CR_MAX_STMTS  = 512;    // per block; longer blocks are analysed in windows
const usz CR_MAX_ACCS   = 64;     // accumulators tracked per loop
const int CR_MAX_DEPTH  = 200;

// ── Locations ───────────────────────────────────────────────────────────
enum LocKind : char { L_VAR, L_HEAP, L_WORLD }

struct Loc
{
    LocKind kind;
    Node*   key;      // binder for VAR / HEAP; null for WORLD (or HEAP via unknown base)
}

struct Eff
{
    Loc[CR_MAX_LOCS] reads;
    Loc[CR_MAX_LOCS] writes;
    usz  n_reads;
    usz  n_writes;
    bool barrier;      // return/break/continue/perform/asm: fixes order
    bool overflow;     // too many locations: treated as WORLD read+write
}

// CRDT classes of an accumulator (a join-semilattice: merge is `max`)
enum Crdt : char
{
    C_NONE,       // never updated (not an accumulator)
    C_COUNTER,    // + -          associative, commutative
    C_PRODUCT,    // * ^          associative, commutative, not idempotent
    C_JOIN,       // | &          associative, commutative, idempotent
    C_MAXMIN,     // guarded copy associative, commutative, idempotent
    C_MIXED,      // several commutative shapes on one variable (still commutes only if they are the same monoid — they are not)
    C_REGISTER    // plain assignment: last writer wins, order-sensitive
}

struct Acc
{
    Node* binder;
    Crdt  cls;
    int   n_updates;
    int   n_other_reads;   // reads outside its own update statements
    bool  induction;       // COUNTER stepped by a literal and read elsewhere
    Node* first_update;
    Tk    op;              // normalised operator of the updates (+/- → PLUS, * → STAR, ^, |, &, > → GT, < → LT); MIXED if they differ
    bool  self_ref;        // some update reads the variable itself in a non-fold shape (x = f(x))
    Node* guard_if;        // MAXMIN: the `if` whose condition is part of the update
}

struct CrdtAnalysis
{
    Arena* arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*  file;

    Eff*   effs;             // CR_MAX_STMTS scratch summaries for the current block
    int*   cp;               // critical-path dp per statement
    Acc*   accs;             // per-loop accumulator table
    usz    n_accs;
    Node*  cur_loop_body;
    Node*  cur_update;       // statement whose rhs is being scanned (self-reads are not "other" reads)

    // census
    usz n_blocks, n_stmts, n_edges, n_raw, n_war, n_waw, n_adjacent, n_commute;
    usz sum_cp, sum_len;
    usz n_loops, n_reductions, n_ordered, n_counting;
    usz n_c_counter, n_c_product, n_c_join, n_c_maxmin, n_c_register, n_c_mixed, n_induction;
    usz n_flag_indep, n_flag_red;
    usz n_n4230, n_n4231;
    usz n_calls_pure, n_calls_world;
}

fn void CrdtAnalysis.init(CrdtAnalysis* c, Arena* a)
{
    c.arena = a; c.diags = null; c.interner = null; c.file = null;
    c.effs = (Eff*)calloc(CR_MAX_STMTS, Eff::size);
    c.cp   = (int*)calloc(CR_MAX_STMTS, int::size);
    c.accs = (Acc*)calloc(CR_MAX_ACCS, Acc::size);
    c.n_accs = 0; c.cur_loop_body = null; c.cur_update = null;
    c.n_blocks = 0; c.n_stmts = 0; c.n_edges = 0; c.n_raw = 0; c.n_war = 0; c.n_waw = 0;
    c.n_adjacent = 0; c.n_commute = 0; c.sum_cp = 0; c.sum_len = 0;
    c.n_loops = 0; c.n_reductions = 0; c.n_ordered = 0; c.n_counting = 0;
    c.n_c_counter = 0; c.n_c_product = 0; c.n_c_join = 0; c.n_c_maxmin = 0; c.n_c_register = 0; c.n_c_mixed = 0; c.n_induction = 0;
    c.n_flag_indep = 0; c.n_flag_red = 0; c.n_n4230 = 0; c.n_n4231 = 0;
    c.n_calls_pure = 0; c.n_calls_world = 0;
}

fn void CrdtAnalysis.attach(CrdtAnalysis* c, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    c.diags = d; c.interner = it; c.file = file;
}

fn void CrdtAnalysis.destroy(CrdtAnalysis* c)
{
    if (c.effs != null) { free((void*)c.effs); c.effs = null; }
    if (c.cp != null) { free((void*)c.cp); c.cp = null; }
    if (c.accs != null) { free((void*)c.accs); c.accs = null; }
}

fn char* CrdtAnalysis.name(CrdtAnalysis* c, Node* binder)
{
    if (binder == null || c.interner == null) { return "_"; }
    uint id = binder.name_id != 0 ? binder.name_id : (binder.child_count > 0 && binder.children[0] != null ? binder.children[0].name_id : 0);
    if (id == 0) { return "_"; }
    char* s = c.interner.text(id);
    return s == null ? "_" : s;
}

fn char* CrdtAnalysis.msgbuf(CrdtAnalysis* c)
{
    return (char*)c.arena.alloc(512, 1);
}

// ── Effect sets ─────────────────────────────────────────────────────────
fn void eff_clear(Eff* e)
{
    e.n_reads = 0; e.n_writes = 0; e.barrier = false; e.overflow = false;
}

fn bool loc_eq(Loc a, Loc b)
{
    return a.kind == b.kind && a.key == b.key;
}

fn void eff_read(Eff* e, LocKind k, Node* key)
{
    if (e.overflow) { return; }
    Loc l; l.kind = k; l.key = key;
    if (k == LocKind.L_HEAP && key == null) { l.kind = LocKind.L_WORLD; }
    for (usz i = 0; i < e.n_reads; i++) { if (loc_eq(e.reads[i], l)) { return; } }
    if (e.n_reads >= CR_MAX_LOCS) { e.overflow = true; return; }
    e.reads[e.n_reads] = l; e.n_reads = e.n_reads + 1;
}

fn void eff_write(Eff* e, LocKind k, Node* key)
{
    if (e.overflow) { return; }
    Loc l; l.kind = k; l.key = key;
    if (k == LocKind.L_HEAP && key == null) { l.kind = LocKind.L_WORLD; }
    for (usz i = 0; i < e.n_writes; i++) { if (loc_eq(e.writes[i], l)) { return; } }
    if (e.n_writes >= CR_MAX_LOCS) { e.overflow = true; return; }
    e.writes[e.n_writes] = l; e.n_writes = e.n_writes + 1;
}

fn void eff_union(Eff* into, Eff* from)
{
    if (from.barrier) { into.barrier = true; }
    if (from.overflow) { into.overflow = true; return; }
    for (usz i = 0; i < from.n_reads; i++)  { eff_read(into, from.reads[i].kind, from.reads[i].key); }
    for (usz i = 0; i < from.n_writes; i++) { eff_write(into, from.writes[i].kind, from.writes[i].key); }
}

fn bool is_global_binder(Node* b)
{
    if (b == null) { return false; }
    if (b.kind == Nk.N_DECL_STATIC) { return true; }
    Node* p = b.parent;
    if (p != null && p.kind == Nk.N_DECL_STATIC) { return true; }
    if (b.kind == Nk.N_DECL_LET || b.kind == Nk.N_PAT_IDENT)
    {
        while (p != null)
        {
            if (p.kind == Nk.N_DECL_FN || p.kind == Nk.N_EXPR_LAMBDA) { return false; }
            p = p.parent;
        }
        return true;
    }
    return false;
}

// Do two locations possibly denote overlapping memory?
//   WORLD   ~ WORLD, every HEAP, every global VAR, every address-taken VAR
//   HEAP(b) ~ HEAP(b), WORLD, and HEAP(b') when either binder may hold an alias
//             — without points-to we say two different named pointer bases
//             may alias unless both are locals whose address is never taken
//             AND neither is a pointer initialised from the other. We keep it
//             simple and sound: distinct binders are treated as *may alias*
//             only if at least one is a parameter or global (the usual
//             sources of aliasing); two distinct locals do not alias.
//   VAR(b)  ~ VAR(b); VAR(b) with NF_ADDR_TAKEN ~ HEAP(b) and WORLD
fn bool var_is_local(Node* b)
{
    if (b == null) { return false; }
    if (b.kind == Nk.N_DECL_PARAM) { return false; }
    Node* p = b.parent;
    if (p != null && p.kind == Nk.N_DECL_PARAM) { return false; }
    return !is_global_binder(b);
}

fn bool loc_overlap(Loc a, Loc b)
{
    if (a.kind == LocKind.L_WORLD || b.kind == LocKind.L_WORLD)
    {
        Loc o = a.kind == LocKind.L_WORLD ? b : a;
        if (o.kind == LocKind.L_WORLD) { return true; }
        if (o.kind == LocKind.L_HEAP) { return true; }
        // VAR: globals live in the world; address-taken locals too
        if (is_global_binder(o.key)) { return true; }
        return o.key != null && (o.key.flags & pfront_core::NF_ADDR_TAKEN) != 0;
    }
    if (a.kind == LocKind.L_HEAP && b.kind == LocKind.L_HEAP)
    {
        if (a.key == b.key) { return true; }
        // distinct bases: may alias unless both are plain locals
        return !(var_is_local(a.key) && var_is_local(b.key));
    }
    if (a.kind == LocKind.L_VAR && b.kind == LocKind.L_VAR) { return a.key == b.key; }
    // VAR vs HEAP
    Loc v = a.kind == LocKind.L_VAR ? a : b;
    Loc h = a.kind == LocKind.L_VAR ? b : a;
    if (v.key == null) { return true; }
    if ((v.key.flags & pfront_core::NF_ADDR_TAKEN) != 0) { return true; }
    // a global variable may be reached through any pointer
    if (is_global_binder(v.key) && !var_is_local(h.key)) { return true; }
    return false;
}

// kinds of conflict between an earlier statement a and a later statement b
const int DEP_RAW = 1;
const int DEP_WAR = 2;
const int DEP_WAW = 4;

fn int eff_conflict(Eff* a, Eff* b)
{
    if (a.barrier || b.barrier) { return DEP_RAW | DEP_WAR | DEP_WAW; }
    if (a.overflow || b.overflow)
    {
        // overflow = reads+writes WORLD
        Eff* other = a.overflow ? b : a;
        if (other.overflow) { return DEP_RAW | DEP_WAR | DEP_WAW; }
        Loc w; w.kind = LocKind.L_WORLD; w.key = null;
        int d = 0;
        for (usz i = 0; i < other.n_reads; i++)  { if (loc_overlap(w, other.reads[i]))  { d = d | DEP_RAW; } }
        for (usz i = 0; i < other.n_writes; i++) { if (loc_overlap(w, other.writes[i])) { d = d | DEP_WAW | DEP_WAR; } }
        return d;
    }
    int dep = 0;
    for (usz i = 0; i < a.n_writes; i++)
    {
        for (usz j = 0; j < b.n_reads; j++)  { if (loc_overlap(a.writes[i], b.reads[j]))  { dep = dep | DEP_RAW; break; } }
        for (usz j = 0; j < b.n_writes; j++) { if (loc_overlap(a.writes[i], b.writes[j])) { dep = dep | DEP_WAW; break; } }
    }
    for (usz i = 0; i < b.n_writes; i++)
    {
        for (usz j = 0; j < a.n_reads; j++) { if (loc_overlap(b.writes[i], a.reads[j])) { dep = dep | DEP_WAR; break; } }
    }
    return dep;
}

// ── Effect collection ───────────────────────────────────────────────────
// base identifier of an lvalue chain: p.x[i].y → p ; *p → p (through=true)
fn Node* lvalue_base(Node* e, bool* through)
{
    *through = false;
    int guard = 0;
    while (e != null && guard < 64)
    {
        guard = guard + 1;
        switch (e.kind)
        {
            case Nk.N_EXPR_FIELD:
            case Nk.N_EXPR_INDEX:
            case Nk.N_EXPR_SLICE:
            case Nk.N_EXPR_DEREF:
                *through = true;
                e = e.child_count > 0 ? e.children[0] : null; break;
            case Nk.N_EXPR_CAST:
            case Nk.N_EXPR_UNSAFE:
                e = e.child_count > 0 ? e.children[0] : null; break;
            default:
                return e;
        }
    }
    return e;
}

fn Node* base_binder(Node* base)
{
    if (base == null) { return null; }
    if (base.kind == Nk.N_EXPR_IDENT || base.kind == Nk.N_EXPR_PATH) { return base.resolved; }
    if (base.kind == Nk.N_EXPR_SELF) { return base.resolved; }
    return null;
}

fn void CrdtAnalysis.note_write_lhs(CrdtAnalysis* c, Eff* e, Node* lhs, int depth)
{
    bool through = false;
    Node* base = lvalue_base(lhs, &through);
    Node* b = base_binder(base);
    if (base == null) { eff_write(e, LocKind.L_WORLD, null); return; }
    if (b == null)
    {
        // write through a computed pointer: the world
        eff_write(e, LocKind.L_WORLD, null);
        c.collect(e, base, depth + 1);
    }
    else if (through)
    {
        eff_read(e, LocKind.L_VAR, b);
        eff_write(e, LocKind.L_HEAP, b);
    }
    else
    {
        eff_write(e, LocKind.L_VAR, b);
    }
    // index / field-chain sub-expressions are reads
    Node* w = lhs;
    int guard = 0;
    while (w != null && w != base && guard < 64)
    {
        guard = guard + 1;
        for (usz i = 1; i < w.child_count; i++) { c.collect(e, w.children[i], depth + 1); }
        w = w.child_count > 0 ? w.children[0] : null;
    }
}

fn bool callee_is_pure(Node* callee_decl)
{
    if (callee_decl == null) { return false; }
    if ((callee_decl.flags & pfront_core::NF_PURE_FN) != 0) { return true; }
    // constructors are pure
    return callee_decl.kind == Nk.N_DECL_VARIANT || callee_decl.kind == Nk.N_DECL_STRUCT
        || callee_decl.kind == Nk.N_DECL_ENUM || callee_decl.kind == Nk.N_DECL_NEWTYPE;
}

fn void CrdtAnalysis.note_call(CrdtAnalysis* c, Eff* e, Node* call, int depth)
{
    Node* callee_decl = null;
    usz first_arg = 0;
    if (call.kind == Nk.N_EXPR_CALL)
    {
        Node* f = call.child_count > 0 ? call.children[0] : null;
        if (f != null && (f.kind == Nk.N_EXPR_IDENT || f.kind == Nk.N_EXPR_PATH)) { callee_decl = f.resolved; }
        else if (f != null) { c.collect(e, f, depth + 1); }   // computed callee: also an unknown call
        first_arg = 1;
    }
    else
    {
        callee_decl = call.resolved;
        first_arg = 0;
    }
    bool pure = callee_is_pure(callee_decl);
    if (pure) { c.n_calls_pure = c.n_calls_pure + 1; }
    else
    {
        c.n_calls_world = c.n_calls_world + 1;
        eff_read(e, LocKind.L_WORLD, null);
        eff_write(e, LocKind.L_WORLD, null);
    }
    for (usz i = first_arg; i < call.child_count; i++)
    {
        Node* a = call.children[i];
        if (a == null) { continue; }
        if (a.kind == Nk.N_EXPR_REF && !pure)
        {
            // `&x` / `&mut x` handed to an impure callee: x may be written
            bool through = false;
            Node* base = lvalue_base(a.child_count > 0 ? a.children[0] : null, &through);
            Node* b = base_binder(base);
            if (b != null) { eff_read(e, LocKind.L_VAR, b); eff_write(e, LocKind.L_HEAP, b); if (!through) { eff_write(e, LocKind.L_VAR, b); } }
            else { eff_write(e, LocKind.L_WORLD, null); }
            continue;
        }
        c.collect(e, a, depth + 1);
    }
}

fn void CrdtAnalysis.bind_pattern(CrdtAnalysis* c, Eff* e, Node* pat, int depth)
{
    if (pat == null || depth > CR_MAX_DEPTH) { return; }
    if (pat.kind == Nk.N_PAT_IDENT) { eff_write(e, LocKind.L_VAR, pat); return; }
    for (usz i = 0; i < pat.child_count; i++) { c.bind_pattern(e, pat.children[i], depth + 1); }
}

// reads + writes of an arbitrary node (statement or expression)
fn void CrdtAnalysis.collect(CrdtAnalysis* c, Eff* e, Node* n, int depth)
{
    if (n == null || depth > CR_MAX_DEPTH) { return; }
    if (e.overflow) { return; }
    switch (n.kind)
    {
        case Nk.N_EXPR_IDENT:
        case Nk.N_EXPR_PATH:
        case Nk.N_EXPR_SELF:
        {
            Node* b = n.resolved;
            if (b == null) { return; }
            if (b.kind == Nk.N_DECL_FN || b.kind == Nk.N_DECL_VARIANT || b.kind == Nk.N_DECL_STRUCT
                || b.kind == Nk.N_DECL_ENUM || b.kind == Nk.N_DECL_EXTERN_FN || b.kind == Nk.N_DECL_NEWTYPE) { return; }
            eff_read(e, LocKind.L_VAR, b);
            if (c.cur_loop_body != null) { c.note_acc_read(b, n); }
            return;
        }
        case Nk.N_EXPR_FIELD:
        case Nk.N_EXPR_INDEX:
        case Nk.N_EXPR_SLICE:
        case Nk.N_EXPR_DEREF:
        {
            bool through = false;
            Node* base = lvalue_base(n, &through);
            Node* b = base_binder(base);
            if (b == null) { eff_read(e, LocKind.L_WORLD, null); c.collect(e, base, depth + 1); }
            else { eff_read(e, LocKind.L_VAR, b); eff_read(e, LocKind.L_HEAP, b); if (c.cur_loop_body != null) { c.note_acc_read(b, base); } }
            Node* w = n;
            int guard = 0;
            while (w != null && w != base && guard < 64)
            {
                guard = guard + 1;
                for (usz i = 1; i < w.child_count; i++) { c.collect(e, w.children[i], depth + 1); }
                w = w.child_count > 0 ? w.children[0] : null;
            }
            return;
        }
        case Nk.N_EXPR_REF:
        {
            // taking an address: the object is read now, and may be reached later
            Node* in = n.child_count > 0 ? n.children[0] : null;
            bool through = false;
            Node* base = lvalue_base(in, &through);
            Node* b = base_binder(base);
            if (b != null)
            {
                eff_read(e, LocKind.L_VAR, b); eff_read(e, LocKind.L_HEAP, b);
                if ((n.flags & pfront_core::NF_MUT) != 0) { eff_write(e, LocKind.L_HEAP, b); }
            }
            else { eff_read(e, LocKind.L_WORLD, null); }
            for (usz i = 0; in != null && i < in.child_count; i++) { if (i > 0 || in.kind == Nk.N_EXPR_CALL) { c.collect(e, in.children[i], depth + 1); } }
            return;
        }
        case Nk.N_STMT_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        case Nk.N_EXPR_ASSIGN:
        {
            Node* lhs = n.child_count > 0 ? n.children[0] : null;
            if (lhs != null) { c.note_write_lhs(e, lhs, depth); }
            if (n.kind == Nk.N_STMT_COMPOUND_ASSIGN && lhs != null)
            {
                // `x += e` reads x too
                bool through = false;
                Node* base = lvalue_base(lhs, &through);
                Node* b = base_binder(base);
                if (b != null) { eff_read(e, LocKind.L_VAR, b); if (through) { eff_read(e, LocKind.L_HEAP, b); } }
            }
            for (usz i = 1; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
            return;
        }
        case Nk.N_DECL_LET:
        {
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* ch = n.children[i];
                if (ch == null) { continue; }
                if (pfront_core::is_pattern(ch.kind)) { c.bind_pattern(e, ch, depth + 1); }
                else if (!pfront_core::is_type(ch.kind)) { c.collect(e, ch, depth + 1); }
            }
            return;
        }
        case Nk.N_EXPR_CALL:
        case Nk.N_EXPR_METHOD:
            c.note_call(e, n, depth);
            return;
        case Nk.N_STMT_RETURN:
        case Nk.N_STMT_BREAK:
        case Nk.N_STMT_CONTINUE:
        case Nk.N_EXPR_PERFORM:
        case Nk.N_EXPR_ASM:
            e.barrier = true;
            for (usz i = 0; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
            return;
        case Nk.N_EXPR_ALLOC:
            // allocation reads the allocator state; two allocations commute
            eff_read(e, LocKind.L_WORLD, null);
            for (usz i = 0; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
            return;
        case Nk.N_EXPR_LAMBDA:
            // creating a closure reads its captures; calling it is a call
            for (usz i = 0; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
            return;
        case Nk.N_EXPR_HANDLE:
            // installing a handler is control: keep its order
            e.barrier = true;
            for (usz i = 0; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
            return;
        case Nk.N_EXPR_FOR:
        {
            // `for pat in it body`: the pattern binds fresh names
            for (usz i = 0; i < n.child_count; i++)
            {
                Node* ch = n.children[i];
                if (ch == null) { continue; }
                if (pfront_core::is_pattern(ch.kind)) { c.bind_pattern(e, ch, depth + 1); }
                else { c.collect(e, ch, depth + 1); }
            }
            return;
        }
        default:
            break;
    }
    if (pfront_core::is_type(n.kind)) { return; }
    for (usz i = 0; i < n.child_count; i++) { c.collect(e, n.children[i], depth + 1); }
}

// ── Block dependence ────────────────────────────────────────────────────
fn void CrdtAnalysis.analyse_block(CrdtAnalysis* c, Node* blk)
{
    // statements are the block's direct children that are not types/patterns
    usz n = blk.child_count;
    if (n < 2) { return; }
    usz start = 0;
    while (start < n)
    {
        usz len = n - start;
        if (len > CR_MAX_STMTS) { len = CR_MAX_STMTS; }
        c.analyse_window(blk, start, len);
        start = start + len;
    }
}

fn void CrdtAnalysis.analyse_window(CrdtAnalysis* c, Node* blk, usz start, usz len)
{
    for (usz i = 0; i < len; i++)
    {
        Eff* e = &c.effs[i];
        eff_clear(e);
        Node* s = blk.children[start + i];
        if (s == null) { continue; }
        s.flags = s.flags & ~pfront_core::NF_INDEPENDENT;
        c.collect(e, s, 0);
    }
    c.n_blocks = c.n_blocks + 1;
    c.n_stmts = c.n_stmts + len;
    // dependence DAG + critical path (longest chain, in statements)
    int best = 0;
    for (usz j = 0; j < len; j++)
    {
        int longest = 0;
        bool any_dep = false;
        for (usz i = 0; i < j; i++)
        {
            int d = eff_conflict(&c.effs[i], &c.effs[j]);
            if (d == 0) { continue; }
            any_dep = true;
            c.n_edges = c.n_edges + 1;
            if ((d & DEP_RAW) != 0) { c.n_raw = c.n_raw + 1; }
            if ((d & DEP_WAR) != 0) { c.n_war = c.n_war + 1; }
            if ((d & DEP_WAW) != 0) { c.n_waw = c.n_waw + 1; }
            if (c.cp[i] > longest) { longest = c.cp[i]; }
        }
        c.cp[j] = longest + 1;
        if (c.cp[j] > best) { best = c.cp[j]; }
        if (j > 0)
        {
            c.n_adjacent = c.n_adjacent + 1;
            int adj = eff_conflict(&c.effs[j - 1], &c.effs[j]);
            if (adj == 0)
            {
                c.n_commute = c.n_commute + 1;
                Node* s = blk.children[start + j];
                if (s != null) { s.flags = s.flags | pfront_core::NF_INDEPENDENT; c.n_flag_indep = c.n_flag_indep + 1; }
            }
        }
        (void)any_dep;
    }
    c.sum_cp = c.sum_cp + (usz)best;
    c.sum_len = c.sum_len + len;
}

// ── Loop reductions ─────────────────────────────────────────────────────
fn Acc* CrdtAnalysis.acc_for(CrdtAnalysis* c, Node* b, bool create)
{
    for (usz i = 0; i < c.n_accs; i++) { if (c.accs[i].binder == b) { return &c.accs[i]; } }
    if (!create || c.n_accs >= CR_MAX_ACCS) { return null; }
    Acc* a = &c.accs[c.n_accs];
    c.n_accs = c.n_accs + 1;
    a.binder = b; a.cls = Crdt.C_NONE; a.n_updates = 0; a.n_other_reads = 0; a.induction = false; a.first_update = null; a.guard_if = null; a.self_ref = false; a.op = Tk.TOKEN_EOF;
    return a;
}

// a read of binder b while scanning a loop body; reads inside b's own update
// statement (`b = b + e`) are not "other" reads
fn void CrdtAnalysis.note_acc_read(CrdtAnalysis* c, Node* b, Node* at)
{
    if (b == null || !var_is_local(b)) { return; }
    Acc* a = c.acc_for(b, false);
    if (a == null) { return; }
    if (c.cur_update != null)
    {
        Node* p = at;
        int guard = 0;
        while (p != null && guard < 64) { if (p == c.cur_update) { return; } p = p.parent; guard = guard + 1; }
    }
    a.n_other_reads = a.n_other_reads + 1;
}

fn Crdt op_class(Tk op)
{
    switch (op)
    {
        case Tk.TOKEN_PLUS: case Tk.TOKEN_MINUS: case Tk.TOKEN_PLUSEQ: case Tk.TOKEN_MINUSEQ: return Crdt.C_COUNTER;
        case Tk.TOKEN_STAR: case Tk.TOKEN_STAREQ: case Tk.TOKEN_XOR: case Tk.TOKEN_XOREQ:       return Crdt.C_PRODUCT;
        case Tk.TOKEN_PIPE: case Tk.TOKEN_AMP: case Tk.TOKEN_PIPEEQ: case Tk.TOKEN_AMPEQ:       return Crdt.C_JOIN;
        default: return Crdt.C_REGISTER;
    }
}

// the monoid an update belongs to; two updates of one variable only commute
// with each other when they are in the SAME monoid (`h ^= b; h *= P` is FNV,
// not a fold; `x |= a; x &= b` is not either)
fn Tk norm_op(Tk op)
{
    switch (op)
    {
        case Tk.TOKEN_PLUS: case Tk.TOKEN_MINUS: case Tk.TOKEN_PLUSEQ: case Tk.TOKEN_MINUSEQ: return Tk.TOKEN_PLUS;
        case Tk.TOKEN_STAR: case Tk.TOKEN_STAREQ: return Tk.TOKEN_STAR;
        case Tk.TOKEN_XOR: case Tk.TOKEN_XOREQ:   return Tk.TOKEN_XOR;
        case Tk.TOKEN_PIPE: case Tk.TOKEN_PIPEEQ: return Tk.TOKEN_PIPE;
        case Tk.TOKEN_AMP: case Tk.TOKEN_AMPEQ:   return Tk.TOKEN_AMP;
        case Tk.TOKEN_GT: case Tk.TOKEN_GTEQ:     return Tk.TOKEN_GT;
        case Tk.TOKEN_LT: case Tk.TOKEN_LTEQ:     return Tk.TOKEN_LT;
        default: return op;
    }
}

fn Crdt crdt_join(Crdt a, Crdt b)
{
    if (a == Crdt.C_NONE) { return b; }
    if (b == Crdt.C_NONE) { return a; }
    if (a == b) { return a; }
    if (a == Crdt.C_REGISTER || b == Crdt.C_REGISTER) { return Crdt.C_REGISTER; }
    return Crdt.C_MIXED;
}

fn char* crdt_name(Crdt k)
{
    switch (k)
    {
        case Crdt.C_COUNTER:  return "counter (+/-)";
        case Crdt.C_PRODUCT:  return "product (*/^)";
        case Crdt.C_JOIN:     return "join (|/&)";
        case Crdt.C_MAXMIN:   return "max/min register";
        case Crdt.C_MIXED:    return "mixed operators (not one monoid)";
        case Crdt.C_REGISTER: return "last-writer-wins register";
        default:              return "none";
    }
}

fn bool is_literal(Node* e)
{
    if (e == null) { return false; }
    switch (e.kind)
    {
        case Nk.N_EXPR_INT: case Nk.N_EXPR_FLOAT: case Nk.N_EXPR_BOOL: case Nk.N_EXPR_CHAR: return true;
        case Nk.N_EXPR_CAST: return e.child_count > 0 && is_literal(e.children[0]);
        default: return false;
    }
}

// structural equality of two side-effect-free expressions
fn bool expr_equal(Node* a, Node* b, int depth)
{
    if (a == null || b == null) { return a == b; }
    if (depth > 32 || a.kind != b.kind || a.child_count != b.child_count) { return false; }
    switch (a.kind)
    {
        case Nk.N_EXPR_IDENT: case Nk.N_EXPR_PATH: return a.resolved != null && a.resolved == b.resolved;
        case Nk.N_EXPR_INT: case Nk.N_EXPR_CHAR: case Nk.N_EXPR_BOOL: return a.p.ival == b.p.ival;
        case Nk.N_EXPR_BINARY: case Nk.N_EXPR_UNARY: if (a.p.op != b.p.op) { return false; } break;
        case Nk.N_EXPR_FIELD: if (a.name_id != b.name_id) { return false; } break;
        case Nk.N_EXPR_CALL: case Nk.N_EXPR_METHOD: case Nk.N_EXPR_ALLOC: case Nk.N_EXPR_LAMBDA: return false;
        default: break;
    }
    for (usz i = 0; i < a.child_count; i++) { if (!expr_equal(a.children[i], b.children[i], depth + 1)) { return false; } }
    return true;
}

// does expression `e` mention binder b?
fn bool mentions(Node* e, Node* b, int depth)
{
    if (e == null || depth > CR_MAX_DEPTH) { return false; }
    if ((e.kind == Nk.N_EXPR_IDENT || e.kind == Nk.N_EXPR_PATH) && e.resolved == b) { return true; }
    for (usz i = 0; i < e.child_count; i++) { if (mentions(e.children[i], b, depth + 1)) { return true; } }
    return false;
}

// classify one update statement of a local variable
fn void CrdtAnalysis.classify_update(CrdtAnalysis* c, Node* stmt, Node* lhs_binder, Node* rhs, Tk compound_op, bool guarded_copy, Node* guard_if, Tk guard_op)
{
    Acc* a = c.acc_for(lhs_binder, true);
    if (a == null) { return; }
    if (guarded_copy) { a.guard_if = guard_if; }
    a.n_updates = a.n_updates + 1;
    if (a.first_update == null) { a.first_update = stmt; }
    Crdt k = Crdt.C_REGISTER;
    Node* step = null;
    Tk used = Tk.TOKEN_EOF;
    if (guarded_copy) { k = Crdt.C_MAXMIN; used = guard_op; }
    else if (compound_op != Tk.TOKEN_EOF)
    {
        k = op_class(compound_op);
        used = compound_op;
        step = rhs;
        if (k != Crdt.C_REGISTER && mentions(rhs, lhs_binder, 0)) { k = Crdt.C_REGISTER; }   // x += f(x): not a fold
    }
    else if (rhs != null && rhs.kind == Nk.N_EXPR_BINARY && rhs.child_count == 2)
    {
        Tk op = (Tk)rhs.p.op;
        Node* l = rhs.children[0];
        Node* r = rhs.children[1];
        bool l_self = l != null && (l.kind == Nk.N_EXPR_IDENT) && l.resolved == lhs_binder;
        bool r_self = r != null && (r.kind == Nk.N_EXPR_IDENT) && r.resolved == lhs_binder;
        Crdt ok = op_class(op);
        if (ok != Crdt.C_REGISTER && (l_self != r_self))
        {
            Node* other = l_self ? r : l;
            // `x = e - x` is not a fold; `x = x - e` is (counter)
            bool minus_reversed = op == Tk.TOKEN_MINUS && r_self;
            if (!minus_reversed && !mentions(other, lhs_binder, 0)) { k = ok; step = other; used = op; }
        }
    }
    if (k == Crdt.C_COUNTER && step != null && is_literal(step)) { a.induction = true; }
    if (k == Crdt.C_REGISTER && rhs != null && mentions(rhs, lhs_binder, 0)) { a.self_ref = true; }
    a.cls = crdt_join(a.cls, k);
    if (k != Crdt.C_REGISTER)
    {
        Tk nop = norm_op(used);
        if (a.op == Tk.TOKEN_EOF) { a.op = nop; }
        else if (a.op != nop && a.cls != Crdt.C_REGISTER) { a.cls = Crdt.C_MIXED; }
    }
}

// find every update of a local in a loop body (recursively), classify it
fn void CrdtAnalysis.scan_updates(CrdtAnalysis* c, Node* n, int depth)
{
    if (n == null || depth > CR_MAX_DEPTH) { return; }
    switch (n.kind)
    {
        case Nk.N_STMT_ASSIGN:
        case Nk.N_EXPR_ASSIGN:
        case Nk.N_STMT_COMPOUND_ASSIGN:
        {
            Node* lhs = n.child_count > 0 ? n.children[0] : null;
            Node* rhs = n.child_count > 1 ? n.children[1] : null;
            if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && var_is_local(lhs.resolved))
            {
                Tk cop = n.kind == Nk.N_STMT_COMPOUND_ASSIGN ? (Tk)n.p.op : Tk.TOKEN_EOF;
                // guarded copy: `if e > x then x = e` (max) / `if e < x then x = e` (min)
                bool guarded = false;
                Tk guard_op = Tk.TOKEN_EOF;
                Node* p = n.parent;
                if (p != null && p.kind == Nk.N_BLOCK && p.child_count == 1) { p = p.parent; }
                if (p != null && p.kind == Nk.N_EXPR_IF && p.child_count == 2 && cop == Tk.TOKEN_EOF && rhs != null)
                {
                    Node* cond = p.children[0];
                    if (cond != null && cond.kind == Nk.N_EXPR_BINARY && cond.child_count == 2)
                    {
                        Tk cmp = (Tk)cond.p.op;
                        bool is_cmp = cmp == Tk.TOKEN_LT || cmp == Tk.TOKEN_GT || cmp == Tk.TOKEN_LTEQ || cmp == Tk.TOKEN_GTEQ;
                        Node* cl = cond.children[0];
                        Node* cr = cond.children[1];
                        bool l_self = cl != null && cl.kind == Nk.N_EXPR_IDENT && cl.resolved == lhs.resolved;
                        bool r_self = cr != null && cr.kind == Nk.N_EXPR_IDENT && cr.resolved == lhs.resolved;
                        Node* other = l_self ? cr : (r_self ? cl : null);
                        // `if e > x then x = e`: the compared value and the stored value are the same expression
                        if (is_cmp && other != null && (l_self != r_self) && expr_equal(other, rhs, 0) && !mentions(rhs, lhs.resolved, 0))
                        {
                            guarded = true;
                            // orient the comparison as `e ? x`: `x < e` is the same max as `e > x`
                            Tk gn = norm_op(cmp);
                            if (l_self) { gn = gn == Tk.TOKEN_GT ? Tk.TOKEN_LT : Tk.TOKEN_GT; }
                            guard_op = gn;
                        }
                    }
                }
                c.classify_update(n, lhs.resolved, rhs, cop, guarded, guarded ? p : null, guard_op);
            }
            break;
        }
        default: break;
    }
    if (pfront_core::is_type(n.kind)) { return; }
    for (usz i = 0; i < n.child_count; i++) { c.scan_updates(n.children[i], depth + 1); }
}

// reads of accumulators: a second pass so every accumulator is registered first
fn void CrdtAnalysis.scan_reads(CrdtAnalysis* c, Node* n, int depth)
{
    if (n == null || depth > CR_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN)
    {
        Node* lhs = n.child_count > 0 ? n.children[0] : null;
        Node* saved = c.cur_update;
        if (lhs != null && lhs.kind == Nk.N_EXPR_IDENT && c.acc_for(lhs.resolved, false) != null) { c.cur_update = n; }
        // the rhs of an update may read OTHER accumulators: those count
        for (usz i = 1; i < n.child_count; i++) { c.scan_reads_expr(n.children[i], lhs.resolved, depth + 1); }
        c.cur_update = saved;
        return;
    }
    if ((n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH || n.kind == Nk.N_EXPR_SELF) && n.resolved != null)
    {
        Acc* a = c.acc_for(n.resolved, false);
        if (a != null) { a.n_other_reads = a.n_other_reads + 1; }
        return;
    }
    if (n.kind == Nk.N_EXPR_IF && n.child_count == 2)
    {
        // a max/min guard: `if e > x then x = e` — the read of x in the
        // condition belongs to the update itself
        for (usz i = 0; i < c.n_accs; i++)
        {
            if (c.accs[i].guard_if == n)
            {
                c.scan_reads_expr(n.children[0], c.accs[i].binder, depth + 1);
                c.scan_reads(n.children[1], depth + 1);
                return;
            }
        }
    }
    if (pfront_core::is_type(n.kind)) { return; }
    for (usz i = 0; i < n.child_count; i++) { c.scan_reads(n.children[i], depth + 1); }
}

fn void CrdtAnalysis.scan_reads_expr(CrdtAnalysis* c, Node* n, Node* self, int depth)
{
    if (n == null || depth > CR_MAX_DEPTH) { return; }
    if ((n.kind == Nk.N_EXPR_IDENT || n.kind == Nk.N_EXPR_PATH) && n.resolved != null)
    {
        if (n.resolved == self) { return; }
        Acc* a = c.acc_for(n.resolved, false);
        if (a != null) { a.n_other_reads = a.n_other_reads + 1; }
        return;
    }
    // nested statements inside the rhs (blocks) go back to the general scan
    if (n.kind == Nk.N_STMT_ASSIGN || n.kind == Nk.N_EXPR_ASSIGN || n.kind == Nk.N_STMT_COMPOUND_ASSIGN) { c.scan_reads(n, depth); return; }
    for (usz i = 0; i < n.child_count; i++) { c.scan_reads_expr(n.children[i], self, depth + 1); }
}

fn void CrdtAnalysis.analyse_loop(CrdtAnalysis* c, Node* loop)
{
    Node* body = loop.child_count > 0 ? loop.children[loop.child_count - 1] : null;
    if (body == null) { return; }
    c.n_loops = c.n_loops + 1;
    c.n_accs = 0;
    c.cur_loop_body = null;
    c.scan_updates(body, 0);
    // reads anywhere in the loop — the condition included: an accumulator that
    // steers the trip count is a loop-carried dependence through control
    for (usz i = 0; i < loop.child_count; i++) { if (loop.children[i] != null && !pfront_core::is_pattern(loop.children[i].kind)) { c.scan_reads(loop.children[i], 0); } }
    // other effects of the body: any write besides the accumulators?
    Eff* e = &c.effs[0];
    eff_clear(e);
    c.collect(e, body, 0);
    bool heap_or_world_write = e.overflow || e.barrier;
    for (usz i = 0; !heap_or_world_write && i < e.n_writes; i++)
    {
        Loc w = e.writes[i];
        if (w.kind != LocKind.L_VAR) { heap_or_world_write = true; break; }
        if (!var_is_local(w.key)) { heap_or_world_write = true; break; }
        if ((w.key.flags & pfront_core::NF_ADDR_TAKEN) != 0) { heap_or_world_write = true; break; }
    }
    // classify accumulators
    bool all_commute = !heap_or_world_write;
    usz n_named = 0;
    Acc* register_acc = null;
    usz n_registers = 0;
    for (usz i = 0; i < c.n_accs; i++)
    {
        Acc* a = &c.accs[i];
        switch (a.cls)
        {
            case Crdt.C_COUNTER:  c.n_c_counter = c.n_c_counter + 1; break;
            case Crdt.C_PRODUCT:  c.n_c_product = c.n_c_product + 1; break;
            case Crdt.C_JOIN:     c.n_c_join = c.n_c_join + 1; break;
            case Crdt.C_MAXMIN:   c.n_c_maxmin = c.n_c_maxmin + 1; break;
            case Crdt.C_REGISTER: c.n_c_register = c.n_c_register + 1; n_registers = n_registers + 1; register_acc = a; break;
            case Crdt.C_MIXED:    c.n_c_mixed = c.n_c_mixed + 1; break;
            default: break;
        }
        bool commutes = a.cls == Crdt.C_COUNTER || a.cls == Crdt.C_PRODUCT || a.cls == Crdt.C_JOIN || a.cls == Crdt.C_MAXMIN;
        if (a.induction && a.n_other_reads > 0)
        {
            // induction variable: iterations read a different value each —
            // the loop as a whole still commutes iff its only use is as an
            // index/condition (we cannot tell without dataflow); we accept it
            // when it is the *only* non-accumulator dependence
            c.n_induction = c.n_induction + 1;
        }
        else if (commutes && a.n_other_reads > 0)
        {
            // an accumulator whose intermediate value is observed elsewhere in
            // the body: `s = s + x; if s > 10 …` — iterations no longer commute
            commutes = false;
        }
        if (!commutes && !(a.induction && a.n_other_reads > 0)) { all_commute = false; }
        if (commutes || a.induction) { n_named = n_named + 1; }
    }
    // nothing accumulated (or only the induction variable stepping): a
    // counting loop, not a reduction — nothing to reorder
    bool has_real_acc = false;
    for (usz i = 0; i < c.n_accs; i++) { if (!(c.accs[i].induction && c.accs[i].n_other_reads > 0) && !(c.accs[i].induction && c.n_accs == 1)) { has_real_acc = true; } }
    bool counting = false;
    if (c.n_accs == 0 || !has_real_acc) { if (all_commute) { c.n_counting = c.n_counting + 1; counting = true; } all_commute = false; }
    if (all_commute)
    {
        c.n_reductions = c.n_reductions + 1;
        loop.flags = loop.flags | pfront_core::NF_REDUCTION;
        c.n_flag_red = c.n_flag_red + 1;
        if (c.diags != null && c.diags.advisories)
        {
            char* m = c.msgbuf();
            int off = snprintf(m, 512, "loop is a commutative reduction: ");
            usz shown = 0;
            for (usz i = 0; i < c.n_accs && off < 400; i++)
            {
                Acc* a = &c.accs[i];
                if (a.induction && a.n_other_reads > 0)
                {
                    off = off + snprintf(m + off, (usz)(512 - off), "%s`%s` steps by a constant (induction)", shown > 0 ? ", " : "", c.name(a.binder));
                }
                else
                {
                    off = off + snprintf(m + off, (usz)(512 - off), "%s`%s` is a %s", shown > 0 ? ", " : "", c.name(a.binder), crdt_name(a.cls));
                }
                shown = shown + 1;
            }
            snprintf(m + off, (usz)(512 - off), "; iterations may run in any order (splittable, vectorisable)");
            c.diags.note(pfront_core::Phase.PH_RESOLVE, 4230, loop.line, loop.col, m, c.file);
            c.n_n4230 = c.n_n4230 + 1;
        }
    }
    else
    {
        if (!counting) { c.n_ordered = c.n_ordered + 1; }
        // the single thing that pins the order: one plain assignment among commutative updates
        if (n_registers == 1 && !heap_or_world_write && c.n_accs >= 2 && register_acc != null && c.diags != null && c.diags.advisories)
        {
            bool others_commute = !register_acc.self_ref;
            bool any_real_acc = false;   // an accumulator that is not merely the induction variable
            for (usz i = 0; i < c.n_accs; i++)
            {
                Acc* a = &c.accs[i];
                if (a == register_acc) { continue; }
                bool ok = a.cls == Crdt.C_COUNTER || a.cls == Crdt.C_PRODUCT || a.cls == Crdt.C_JOIN || a.cls == Crdt.C_MAXMIN;
                if (!ok || (a.n_other_reads > 0 && !a.induction)) { others_commute = false; break; }
                if (!(a.induction && a.n_other_reads > 0)) { any_real_acc = true; }
            }
            if (others_commute && any_real_acc && register_acc.first_update != null)
            {
                char* m = c.msgbuf();
                snprintf(m, 512, "`%s` is overwritten here (last writer wins) while every other update in this loop commutes: this assignment alone pins the iteration order", c.name(register_acc.binder));
                c.diags.note(pfront_core::Phase.PH_RESOLVE, 4231, register_acc.first_update.line, register_acc.first_update.col, m, c.file);
                c.n_n4231 = c.n_n4231 + 1;
            }
        }
    }
    (void)n_named;
}

// ── Driver ──────────────────────────────────────────────────────────────
fn void CrdtAnalysis.walk(CrdtAnalysis* c, Node* n, int depth)
{
    if (n == null || depth > CR_MAX_DEPTH) { return; }
    if (n.kind == Nk.N_BLOCK) { c.analyse_block(n); }
    if (n.kind == Nk.N_EXPR_WHILE || n.kind == Nk.N_EXPR_FOR || n.kind == Nk.N_EXPR_LOOP) { c.analyse_loop(n); }
    for (usz i = 0; i < n.child_count; i++) { c.walk(n.children[i], depth + 1); }
}

fn void CrdtAnalysis.report(CrdtAnalysis* c)
{
    printf("  crdt-commute     : %d blocks, %d stmts, %d dependences (%d raw, %d war, %d waw), %d/%d adjacent pairs commute, critical path %d / %d\n",
           (int)c.n_blocks, (int)c.n_stmts, (int)c.n_edges, (int)c.n_raw, (int)c.n_war, (int)c.n_waw,
           (int)c.n_commute, (int)c.n_adjacent, (int)c.sum_cp, (int)c.sum_len);
    printf("  crdt-loops       : %d loops: %d commutative reductions, %d counting, %d ordered; accumulators %d counter, %d product, %d join, %d maxmin, %d register, %d mixed, %d induction; calls %d pure, %d world\n",
           (int)c.n_loops, (int)c.n_reductions, (int)c.n_counting, (int)c.n_ordered,
           (int)c.n_c_counter, (int)c.n_c_product, (int)c.n_c_join, (int)c.n_c_maxmin, (int)c.n_c_register, (int)c.n_c_mixed, (int)c.n_induction,
           (int)c.n_calls_pure, (int)c.n_calls_world);
}
