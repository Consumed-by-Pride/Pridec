// ============================================================================
// theory_stratified.c3 — stratification of type definitions
// ----------------------------------------------------------------------------
// "Stratified" in the type-theoretic sense: types are arranged in levels so
// that every definition only refers to levels below it, except where a
// recursion is *guarded* (behind an indirection) and therefore well-founded.
// This is the same idea as universe levels in Martin-Löf type theory, the
// positivity condition on inductive definitions (Coq/Agda), and the
// regularity condition that makes ML/Rust-style monomorphisation terminate.
//
// The earlier file in this slot was a Kernel-F<: sketch that compared each
// function type against itself and reported "predicative=N". Pride's corpus
// contains no bounded quantification, so that machinery had nothing to act
// on. What Pride *does* have is a few thousand nominal type definitions —
// structs, unions, enums, newtypes, aliases, generics — and the questions a
// compiler must answer about them are exactly the stratification questions:
//
//   1. THE DEFINITION GRAPH. One node per type declaration; an edge D → E
//      for every mention of E inside D's body, labelled
//          VALUE     E is embedded by value (field, tuple/array element,
//                    variant payload, newtype body, generic argument)
//          GUARDED   E is reached through an indirection (*E, &E, [E], fn)
//          ALIAS     D is a `type` alias whose expansion mentions E
//      and with the POLARITY of the occurrence (an argument position of a
//      function type flips it) and, for generic targets, the argument list.
//
//   2. STRATA. Tarjan's SCC over the graph; the condensation is a DAG whose
//      longest-path rank is a type's *level* — the order in which layouts
//      can be computed bottom-up. A non-trivial SCC (or a self edge) is a
//      RECURSIVE type family; its declarations are flagged NF_RECURSIVE_TY
//      so a backend knows it must forward-declare / use an opaque pointer.
//
//   3. WELL-FOUNDEDNESS CHECKS on each SCC:
//        • an SCC whose cycle runs entirely through ALIAS edges is not a
//          type at all — aliases are transparent, so `type A = B; type B = A`
//          or `type P = *P` expands forever (E4240; nothing else caught it)
//        • a cycle of VALUE edges is an infinite-size type. The resolver
//          already rejects the struct/union/newtype case (E3020) but does
//          not look through enum variants; a by-value cycle through a
//          variant is reported here as N4241 (--lint): the representation
//          needs a box
//        • a recursive occurrence in NEGATIVE position (`f : fn(D) -> …`)
//          means D is not strictly positive: structural recursion over it
//          is not guaranteed to terminate (N4242, --lint) — theory_sct's
//          structural-descent argument does not apply to such types
//        • NON-REGULAR recursion: a generic family that refers to itself at
//          a *larger* instance (`struct Nest<T> { inner : *Nest<Box<T>> }`)
//          needs infinitely many instantiations; monomorphisation cannot
//          terminate on it (W4243)
//
//   4. A small census of the quantifier / bound syntax that *is* present
//      (∀/∃ types, `where T : C` bounds) so the report stays truthful about
//      what the module saw.
//
// Report lines (tests/pfront/run.sh `strata` block)
//     strata           : %d type decls in %d strata (depth %d): %d recursive
//                        (%d guarded, %d by value, %d via variant), %d alias cycles,
//                        %d non-regular, %d non-positive
//     strata-edges     : %d edges (%d value, %d guarded, %d alias), %d generic
//                        params, %d forall, %d exists, %d bounds
//
// References: Coquand & Paulin 1990 (positivity); Pierce TAPL ch. 20/21
// (regular recursive types); Mycroft 1984 (polymorphic recursion); Tarjan 1972.
// ============================================================================

module theory_stratified;

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

const usz ST_MAX_DECLS  = 8192;
const usz ST_MAX_EDGES  = 65536;
const usz ST_MAX_PARAMS = 16;
const usz ST_BUCKETS    = 8192;
const int ST_MAX_DEPTH  = 120;

const char E_VALUE   = 0;
const char E_GUARDED = 1;
const char E_ALIAS   = 2;

struct TyDecl
{
    Node* decl;
    uint  name;
    int   first_edge;        // head of the outgoing edge list (-1: none)
    int   scc;               // component id after Tarjan
    int   level;             // stratum: 0 for leaves, longest path in the condensation
    // Tarjan scratch
    int   index;
    int   lowlink;
    bool  on_stack;
    // verdicts
    bool  recursive;
    bool  value_cycle;       // participates in a by-value cycle
    bool  via_variant;       // …that passes through an enum variant
    bool  alias_cycle;
    bool  negative;          // occurs negatively somewhere in its own SCC
    bool  nonregular;
    usz   n_params;
    Node*[ST_MAX_PARAMS] params;
}

struct Edge
{
    int   from;
    int   to;
    char  kind;
    bool  negative;
    bool  via_variant;
    Node* at;                // the mentioning type node
    int   next;              // next outgoing edge of `from`
}

struct DeclSlot { Node* decl; int idx; }

struct StratChecker
{
    Arena* arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*  file;

    TyDecl*   decls;
    usz       n_decls;
    Edge*     edges;
    usz       n_edges;
    DeclSlot* slots;
    int*      stack;
    usz       sp;
    int       tarjan_index;
    int       n_sccs;
    int*      scc_size;
    int*      scc_level;
    int       max_level;

    // current walk
    int   cur;
    bool  cur_negative;
    bool  cur_guarded;
    bool  cur_variant;

    // census
    usz n_value_edges, n_guarded_edges, n_alias_edges;
    usz n_recursive, n_rec_guarded, n_rec_value, n_rec_variant;
    usz n_alias_cycles, n_nonregular, n_nonpositive;
    usz n_params_total, n_forall, n_exists, n_bounds;
    usz n_flag_recursive;
    usz n_e4240, n_n4241, n_n4242, n_w4243;
}

fn void StratChecker.init(StratChecker* sc, Arena* a)
{
    sc.arena = a; sc.diags = null; sc.interner = null; sc.file = null;
    sc.decls = (TyDecl*)calloc(ST_MAX_DECLS, TyDecl::size);
    sc.edges = (Edge*)calloc(ST_MAX_EDGES, Edge::size);
    sc.slots = (DeclSlot*)calloc(ST_BUCKETS, DeclSlot::size);
    sc.stack = (int*)calloc(ST_MAX_DECLS, int::size);
    sc.scc_size = (int*)calloc(ST_MAX_DECLS, int::size);
    sc.scc_level = (int*)calloc(ST_MAX_DECLS, int::size);
    sc.n_decls = 0; sc.n_edges = 0; sc.sp = 0; sc.tarjan_index = 0; sc.n_sccs = 0; sc.max_level = 0;
    sc.cur = -1; sc.cur_negative = false; sc.cur_guarded = false; sc.cur_variant = false;
    sc.n_value_edges = 0; sc.n_guarded_edges = 0; sc.n_alias_edges = 0;
    sc.n_recursive = 0; sc.n_rec_guarded = 0; sc.n_rec_value = 0; sc.n_rec_variant = 0;
    sc.n_alias_cycles = 0; sc.n_nonregular = 0; sc.n_nonpositive = 0;
    sc.n_params_total = 0; sc.n_forall = 0; sc.n_exists = 0; sc.n_bounds = 0;
    sc.n_flag_recursive = 0; sc.n_e4240 = 0; sc.n_n4241 = 0; sc.n_n4242 = 0; sc.n_w4243 = 0;
}

fn void StratChecker.attach(StratChecker* sc, pfront_core::DiagBag* d, pfront_core::Interner* it, char* file)
{
    sc.diags = d; sc.interner = it; sc.file = file;
}

fn void StratChecker.destroy(StratChecker* sc)
{
    if (sc.decls != null) { free((void*)sc.decls); sc.decls = null; }
    if (sc.edges != null) { free((void*)sc.edges); sc.edges = null; }
    if (sc.slots != null) { free((void*)sc.slots); sc.slots = null; }
    if (sc.stack != null) { free((void*)sc.stack); sc.stack = null; }
    if (sc.scc_size != null) { free((void*)sc.scc_size); sc.scc_size = null; }
    if (sc.scc_level != null) { free((void*)sc.scc_level); sc.scc_level = null; }
}

fn char* StratChecker.name(StratChecker* sc, uint id)
{
    if (sc.interner == null || id == 0) { return "_"; }
    char* s = sc.interner.text(id);
    return s == null ? "_" : s;
}

fn char* StratChecker.msgbuf(StratChecker* sc)
{
    return (char*)sc.arena.alloc(512, 1);
}

// ── Declaration table ───────────────────────────────────────────────────
fn bool is_type_decl(Node* d)
{
    if (d == null) { return false; }
    return d.kind == Nk.N_DECL_STRUCT || d.kind == Nk.N_DECL_UNION || d.kind == Nk.N_DECL_ENUM
        || d.kind == Nk.N_DECL_NEWTYPE || d.kind == Nk.N_DECL_TYPE;
}

fn usz slot_hash(Node* d)
{
    ulong x = (ulong)(uptr)d;
    x = x ^ (x >> 17); x = x * 0x9E3779B97F4A7C15UL; x = x ^ (x >> 29);
    return (usz)(x % (ulong)ST_BUCKETS);
}

fn int StratChecker.index_of(StratChecker* sc, Node* d)
{
    if (d == null) { return -1; }
    usz h = slot_hash(d);
    for (usz probe = 0; probe < ST_BUCKETS; probe++)
    {
        DeclSlot* s = &sc.slots[(h + probe) % ST_BUCKETS];
        if (s.decl == d) { return s.idx; }
        if (s.decl == null) { return -1; }
    }
    return -1;
}

fn void StratChecker.register(StratChecker* sc, Node* d)
{
    if (sc.n_decls >= ST_MAX_DECLS || sc.index_of(d) >= 0) { return; }
    usz h = slot_hash(d);
    for (usz probe = 0; probe < ST_BUCKETS; probe++)
    {
        DeclSlot* s = &sc.slots[(h + probe) % ST_BUCKETS];
        if (s.decl == null) { s.decl = d; s.idx = (int)sc.n_decls; break; }
    }
    TyDecl* t = &sc.decls[sc.n_decls];
    sc.n_decls = sc.n_decls + 1;
    t.decl = d; t.name = d.name_id; t.first_edge = -1; t.scc = -1; t.level = 0;
    t.index = -1; t.lowlink = 0; t.on_stack = false;
    t.recursive = false; t.value_cycle = false; t.via_variant = false; t.alias_cycle = false;
    t.negative = false; t.nonregular = false; t.n_params = 0;
    for (usz i = 0; i < d.child_count; i++)
    {
        Node* c = d.children[i];
        if (c != null && c.kind == Nk.N_DECL_TYPEPARAM && t.n_params < ST_MAX_PARAMS)
        {
            t.params[t.n_params] = c; t.n_params = t.n_params + 1;
            sc.n_params_total = sc.n_params_total + 1;
        }
    }
}

fn void StratChecker.collect(StratChecker* sc, Node* n, int depth)
{
    if (n == null || depth > ST_MAX_DEPTH) { return; }
    if (is_type_decl(n)) { sc.register(n); }
    // only descend through modules / blocks / fns for local type decls
    for (usz i = 0; i < n.child_count; i++)
    {
        Node* c = n.children[i];
        if (c == null) { continue; }
        if (pfront_core::is_type(c.kind) || pfront_core::is_pattern(c.kind)) { continue; }
        sc.collect(c, depth + 1);
    }
}

// ── Edges ───────────────────────────────────────────────────────────────
fn void StratChecker.add_edge(StratChecker* sc, int to, char kind, Node* at)
{
    if (sc.cur < 0 || to < 0 || sc.n_edges >= ST_MAX_EDGES) { return; }
    Edge* e = &sc.edges[sc.n_edges];
    int id = (int)sc.n_edges;
    sc.n_edges = sc.n_edges + 1;
    e.from = sc.cur; e.to = to; e.kind = kind; e.negative = sc.cur_negative; e.via_variant = sc.cur_variant; e.at = at;
    e.next = sc.decls[sc.cur].first_edge;
    sc.decls[sc.cur].first_edge = id;
    switch (kind)
    {
        case E_VALUE:   sc.n_value_edges = sc.n_value_edges + 1; break;
        case E_GUARDED: sc.n_guarded_edges = sc.n_guarded_edges + 1; break;
        default:        sc.n_alias_edges = sc.n_alias_edges + 1; break;
    }
}

// walk a type expression occurring inside declaration `cur`
fn void StratChecker.walk_type(StratChecker* sc, Node* ty, int depth, bool in_alias)
{
    if (ty == null || depth > ST_MAX_DEPTH) { return; }
    switch (ty.kind)
    {
        case Nk.N_TY_NAME:
        case Nk.N_TY_PATH:
        {
            Node* target = ty.resolved;
            int to = sc.index_of(target);
            if (to >= 0)
            {
                char k = in_alias ? E_ALIAS : (sc.cur_guarded ? E_GUARDED : E_VALUE);
                sc.add_edge(to, k, ty);
            }
            return;
        }
        case Nk.N_TY_GENERIC:
        {
            // head is child 0 (a name), the rest are arguments
            Node* head = ty.child_count > 0 ? ty.children[0] : null;
            Node* target = head != null ? head.resolved : null;
            if (target == null) { target = ty.resolved; }
            int to = sc.index_of(target);
            if (to >= 0)
            {
                char k = in_alias ? E_ALIAS : (sc.cur_guarded ? E_GUARDED : E_VALUE);
                sc.add_edge(to, k, ty);
            }
            // arguments are substituted into the target's body: they inherit
            // the current guardedness (a `*List<Big>` does not embed Big)
            for (usz i = 1; i < ty.child_count; i++) { sc.walk_type(ty.children[i], depth + 1, in_alias); }
            return;
        }
        case Nk.N_TY_PTR:
        case Nk.N_TY_REF:
        case Nk.N_TY_SLICE:
        {
            bool saved = sc.cur_guarded;
            sc.cur_guarded = true;
            for (usz i = 0; i < ty.child_count; i++) { sc.walk_type(ty.children[i], depth + 1, in_alias); }
            sc.cur_guarded = saved;
            return;
        }
        case Nk.N_TY_FN:
        {
            // parameters are negative, the result positive; all guarded (a
            // function value is a pointer)
            bool saved_g = sc.cur_guarded;
            bool saved_n = sc.cur_negative;
            sc.cur_guarded = true;
            usz last = ty.child_count > 0 ? ty.child_count - 1 : 0;
            for (usz i = 0; i < ty.child_count; i++)
            {
                Node* c = ty.children[i];
                if (c == null) { continue; }
                if (c.kind == Nk.N_TY_EFFECT_ROW) { continue; }
                sc.cur_negative = i < last ? !saved_n : saved_n;
                sc.walk_type(c, depth + 1, in_alias);
            }
            sc.cur_guarded = saved_g;
            sc.cur_negative = saved_n;
            return;
        }
        case Nk.N_TY_ARRAY:
        {
            // element by value (a zero-length array occupies nothing, but the
            // type still refers to the element)
            if (ty.child_count > 0) { sc.walk_type(ty.children[0], depth + 1, in_alias); }
            return;
        }
        case Nk.N_TY_FORALL:
            sc.n_forall = sc.n_forall + 1;
            break;
        case Nk.N_TY_EXISTS:
            sc.n_exists = sc.n_exists + 1;
            break;
        case Nk.N_TY_WHERE:
        case Nk.N_TY_CONSTRAINT:
            if (ty.kind == Nk.N_TY_WHERE && ty.p.aux != 0) { sc.n_bounds = sc.n_bounds + 1; }
            break;
        default:
            break;
    }
    for (usz i = 0; i < ty.child_count; i++) { sc.walk_type(ty.children[i], depth + 1, in_alias); }
}

fn void StratChecker.build_edges(StratChecker* sc)
{
    for (usz i = 0; i < sc.n_decls; i++)
    {
        TyDecl* t = &sc.decls[i];
        Node* d = t.decl;
        sc.cur = (int)i; sc.cur_negative = false; sc.cur_guarded = false; sc.cur_variant = false;
        bool is_alias = d.kind == Nk.N_DECL_TYPE;
        if (d.type_ann != null) { sc.walk_type(d.type_ann, 0, is_alias); }
        for (usz k = 0; k < d.child_count; k++)
        {
            Node* c = d.children[k];
            if (c == null) { continue; }
            if (c.kind == Nk.N_DECL_FIELD)
            {
                if (c.type_ann != null) { sc.walk_type(c.type_ann, 0, is_alias); }
                for (usz j = 0; j < c.child_count; j++) { if (c.children[j] != null && pfront_core::is_type(c.children[j].kind)) { sc.walk_type(c.children[j], 0, is_alias); } }
            }
            else if (c.kind == Nk.N_DECL_VARIANT)
            {
                sc.cur_variant = true;
                for (usz j = 0; j < c.child_count; j++)
                {
                    Node* pay = c.children[j];
                    if (pay == null) { continue; }
                    if (pfront_core::is_type(pay.kind)) { sc.walk_type(pay, 0, is_alias); }
                    else if (pay.kind == Nk.N_DECL_FIELD && pay.type_ann != null) { sc.walk_type(pay.type_ann, 0, is_alias); }
                }
                sc.cur_variant = false;
            }
            else if (pfront_core::is_type(c.kind) && c.kind != Nk.N_TY_WHERE)
            {
                sc.walk_type(c, 0, is_alias);
            }
            else if (c.kind == Nk.N_TY_WHERE) { sc.walk_type(c, 0, is_alias); }
        }
    }
    sc.cur = -1;
}

// ── Tarjan SCC ──────────────────────────────────────────────────────────
fn void StratChecker.strongconnect(StratChecker* sc, int v, int depth)
{
    TyDecl* t = &sc.decls[v];
    t.index = sc.tarjan_index; t.lowlink = sc.tarjan_index; sc.tarjan_index = sc.tarjan_index + 1;
    sc.stack[sc.sp] = v; sc.sp = sc.sp + 1; t.on_stack = true;
    if (depth < 4096)
    {
        for (int e = t.first_edge; e >= 0; e = sc.edges[e].next)
        {
            int w = sc.edges[e].to;
            TyDecl* tw = &sc.decls[w];
            if (tw.index < 0)
            {
                sc.strongconnect(w, depth + 1);
                if (tw.lowlink < t.lowlink) { t.lowlink = tw.lowlink; }
            }
            else if (tw.on_stack && tw.index < t.lowlink) { t.lowlink = tw.index; }
        }
    }
    if (t.lowlink == t.index)
    {
        int id = sc.n_sccs; sc.n_sccs = sc.n_sccs + 1;
        int size = 0;
        while (sc.sp > 0)
        {
            sc.sp = sc.sp - 1;
            int w = sc.stack[sc.sp];
            sc.decls[w].on_stack = false;
            sc.decls[w].scc = id;
            size = size + 1;
            if (w == v) { break; }
        }
        sc.scc_size[id] = size;
    }
}

fn void StratChecker.compute_sccs(StratChecker* sc)
{
    for (usz i = 0; i < sc.n_decls; i++) { if (sc.decls[i].index < 0) { sc.strongconnect((int)i, 0); } }
    // Tarjan emits SCCs in reverse topological order: successors first. So
    // the level of an SCC = 1 + max level over its successor SCCs, and a
    // single pass in emission order (id ascending) is enough.
    for (int id = 0; id < sc.n_sccs; id++) { sc.scc_level[id] = 0; }
    for (int id = 0; id < sc.n_sccs; id++)
    {
        int lvl = 0;
        for (usz i = 0; i < sc.n_decls; i++)
        {
            if (sc.decls[i].scc != id) { continue; }
            for (int e = sc.decls[i].first_edge; e >= 0; e = sc.edges[e].next)
            {
                int s = sc.decls[sc.edges[e].to].scc;
                if (s != id && sc.scc_level[s] + 1 > lvl) { lvl = sc.scc_level[s] + 1; }
            }
        }
        sc.scc_level[id] = lvl;
        if (lvl > sc.max_level) { sc.max_level = lvl; }
    }
    for (usz i = 0; i < sc.n_decls; i++) { sc.decls[i].level = sc.scc_level[sc.decls[i].scc]; }
}

// ── Cycle classification ────────────────────────────────────────────────
// Is there a cycle inside SCC `id` using only edges accepted by `mask`?
// (bit 0: value, bit 1: guarded, bit 2: alias). Bounded DFS from `start`
// back to itself.
fn bool StratChecker.cycle_with(StratChecker* sc, int start, int v, int mask, int depth, bool* through_variant)
{
    if (depth > 64) { return false; }
    TyDecl* t = &sc.decls[v];
    int id = t.scc;
    for (int e = t.first_edge; e >= 0; e = sc.edges[e].next)
    {
        Edge* ed = &sc.edges[e];
        if (sc.decls[ed.to].scc != id) { continue; }
        int bit = 1 << (int)ed.kind;
        if ((mask & bit) == 0) { continue; }
        if (ed.to == start) { if (ed.via_variant) { *through_variant = true; } return true; }
        // avoid revisiting: use `on_stack` as a visited mark for this search
        if (sc.decls[ed.to].on_stack) { continue; }
        sc.decls[ed.to].on_stack = true;
        bool found = sc.cycle_with(start, ed.to, mask, depth + 1, through_variant);
        sc.decls[ed.to].on_stack = false;
        if (found) { if (ed.via_variant) { *through_variant = true; } return true; }
    }
    return false;
}

// is `arg` a bare type parameter of declaration `t`?
fn bool is_bare_param(TyDecl* t, Node* arg)
{
    if (arg == null || (arg.kind != Nk.N_TY_NAME && arg.kind != Nk.N_TY_PATH)) { return false; }
    for (usz i = 0; i < t.n_params; i++)
    {
        if (arg.resolved != null && arg.resolved == t.params[i]) { return true; }
        if (arg.name_id != 0 && arg.name_id == t.params[i].name_id) { return true; }
    }
    return false;
}

// does `arg` mention any type parameter of `t` under a constructor?
fn bool mentions_param(TyDecl* t, Node* arg, int depth)
{
    if (arg == null || depth > 32) { return false; }
    if (is_bare_param(t, arg)) { return true; }
    for (usz i = 0; i < arg.child_count; i++) { if (mentions_param(t, arg.children[i], depth + 1)) { return true; } }
    return false;
}

fn void StratChecker.classify(StratChecker* sc)
{
    for (usz i = 0; i < sc.n_decls; i++)
    {
        TyDecl* t = &sc.decls[i];
        int id = t.scc;
        bool self_edge = false;
        for (int e = t.first_edge; e >= 0; e = sc.edges[e].next) { if (sc.edges[e].to == (int)i) { self_edge = true; break; } }
        if (sc.scc_size[id] <= 1 && !self_edge) { continue; }
        t.recursive = true;
        sc.n_recursive = sc.n_recursive + 1;
        t.decl.flags = t.decl.flags | pfront_core::NF_RECURSIVE_TY;
        sc.n_flag_recursive = sc.n_flag_recursive + 1;
        bool thru_var = false;
        // alias-only cycle
        if (t.decl.kind == Nk.N_DECL_TYPE && sc.cycle_with((int)i, (int)i, 4, 0, &thru_var)) { t.alias_cycle = true; }
        // by-value cycle (alias edges are transparent: they count as value)
        thru_var = false;
        if (!t.alias_cycle && sc.cycle_with((int)i, (int)i, 1 | 4, 0, &thru_var)) { t.value_cycle = true; t.via_variant = thru_var; }
        // negativity: any intra-SCC edge out of this SCC's members that is negative and lands in the SCC
        for (usz j = 0; j < sc.n_decls; j++)
        {
            if (sc.decls[j].scc != id) { continue; }
            for (int e = sc.decls[j].first_edge; e >= 0; e = sc.edges[e].next)
            {
                Edge* ed = &sc.edges[e];
                if (ed.negative && ed.to == (int)i) { t.negative = true; }
            }
        }
        // non-regularity: an intra-SCC edge to a generic instance whose
        // arguments are not bare parameters of the source
        if (t.n_params > 0)
        {
            for (int e = t.first_edge; e >= 0; e = sc.edges[e].next)
            {
                Edge* ed = &sc.edges[e];
                if (sc.decls[ed.to].scc != id || ed.at == null || ed.at.kind != Nk.N_TY_GENERIC) { continue; }
                for (usz a = 1; a < ed.at.child_count; a++)
                {
                    Node* arg = ed.at.children[a];
                    if (arg == null) { continue; }
                    if (!is_bare_param(t, arg) && mentions_param(t, arg, 0)) { t.nonregular = true; }
                }
            }
        }
        if (t.alias_cycle) { sc.n_alias_cycles = sc.n_alias_cycles + 1; }
        else if (t.value_cycle) { sc.n_rec_value = sc.n_rec_value + 1; if (t.via_variant) { sc.n_rec_variant = sc.n_rec_variant + 1; } }
        else { sc.n_rec_guarded = sc.n_rec_guarded + 1; }
        if (t.negative) { sc.n_nonpositive = sc.n_nonpositive + 1; }
        if (t.nonregular) { sc.n_nonregular = sc.n_nonregular + 1; }
    }
}

// ── Diagnostics ─────────────────────────────────────────────────────────
fn char* decl_kind_word(Node* d)
{
    switch (d.kind)
    {
        case Nk.N_DECL_STRUCT:  return "struct";
        case Nk.N_DECL_UNION:   return "union";
        case Nk.N_DECL_ENUM:    return "enum";
        case Nk.N_DECL_NEWTYPE: return "newtype";
        case Nk.N_DECL_TYPE:    return "type alias";
        default:                return "type";
    }
}

// the first intra-SCC edge out of `t`, for pointing at the offending mention
fn Edge* StratChecker.first_cycle_edge(StratChecker* sc, TyDecl* t, int mask)
{
    int id = t.scc;
    for (int e = t.first_edge; e >= 0; e = sc.edges[e].next)
    {
        Edge* ed = &sc.edges[e];
        if (sc.decls[ed.to].scc != id) { continue; }
        if ((mask & (1 << (int)ed.kind)) == 0) { continue; }
        return ed;
    }
    return null;
}

fn void StratChecker.verdicts(StratChecker* sc)
{
    if (sc.diags == null) { return; }
    for (usz i = 0; i < sc.n_decls; i++)
    {
        TyDecl* t = &sc.decls[i];
        if (!t.recursive) { continue; }
        Node* d = t.decl;
        if (t.alias_cycle)
        {
            Edge* ed = sc.first_cycle_edge(t, 4);
            char* m = sc.msgbuf();
            if (ed != null && ed.to != (int)i)
            {
                snprintf(m, 512, "type alias `%s` is defined in terms of itself (through `%s`): an alias is transparent, so this expands forever — make one of them a struct or newtype",
                         sc.name(t.name), sc.name(sc.decls[ed.to].name));
            }
            else
            {
                snprintf(m, 512, "type alias `%s` is defined in terms of itself: an alias is transparent, so this expands forever — make it a struct or newtype",
                         sc.name(t.name));
            }
            sc.diags.add(pfront_core::Severity.SEV_ERROR, pfront_core::Phase.PH_RESOLVE, 4240, d.line, d.col, m, null, sc.file);
            sc.n_e4240 = sc.n_e4240 + 1;
            continue;
        }
        if (t.value_cycle && t.via_variant && d.kind == Nk.N_DECL_ENUM && sc.diags.advisories)
        {
            Edge* ed = sc.first_cycle_edge(t, 1 | 4);
            char* m = sc.msgbuf();
            snprintf(m, 512, "enum `%s` embeds itself by value through a variant payload%s%s%s: its representation needs an indirection (box the payload or use `*%s`)",
                     sc.name(t.name),
                     ed != null && ed.to != (int)i ? " (via `" : "", ed != null && ed.to != (int)i ? sc.name(sc.decls[ed.to].name) : "", ed != null && ed.to != (int)i ? "`)" : "",
                     sc.name(t.name));
            sc.diags.note(pfront_core::Phase.PH_RESOLVE, 4241, ed != null && ed.at != null ? ed.at.line : d.line, ed != null && ed.at != null ? ed.at.col : d.col, m, sc.file);
            sc.n_n4241 = sc.n_n4241 + 1;
        }
        if (t.nonregular)
        {
            // find the offending instance for the message
            Node* inst = null;
            for (int e = t.first_edge; e >= 0 && inst == null; e = sc.edges[e].next)
            {
                Edge* ed = &sc.edges[e];
                if (sc.decls[ed.to].scc != t.scc || ed.at == null || ed.at.kind != Nk.N_TY_GENERIC) { continue; }
                for (usz a = 1; a < ed.at.child_count; a++)
                {
                    Node* arg = ed.at.children[a];
                    if (arg != null && !is_bare_param(t, arg) && mentions_param(t, arg, 0)) { inst = ed.at; break; }
                }
            }
            char* m = sc.msgbuf();
            snprintf(m, 512, "non-regular recursive type: `%s` refers to itself at a larger instance here, so every instantiation needs a fresh one — monomorphisation cannot terminate on it (use an indirection with a non-growing argument, or a dynamic representation)",
                     sc.name(t.name));
            sc.diags.warn(pfront_core::Phase.PH_RESOLVE, 4243, inst != null ? inst.line : d.line, inst != null ? inst.col : d.col, m, sc.file);
            sc.n_w4243 = sc.n_w4243 + 1;
        }
        if (t.negative && sc.diags.advisories)
        {
            Node* at = null;
            for (usz j = 0; j < sc.n_decls && at == null; j++)
            {
                if (sc.decls[j].scc != t.scc) { continue; }
                for (int e = sc.decls[j].first_edge; e >= 0; e = sc.edges[e].next)
                {
                    Edge* ed = &sc.edges[e];
                    if (ed.negative && ed.to == (int)i) { at = ed.at; break; }
                }
            }
            char* m = sc.msgbuf();
            snprintf(m, 512, "%s `%s` occurs in negative position here (an argument of a function-typed field): the type is not strictly positive, so structural recursion over it is not guaranteed to terminate",
                     decl_kind_word(d), sc.name(t.name));
            sc.diags.note(pfront_core::Phase.PH_RESOLVE, 4242, at != null ? at.line : d.line, at != null ? at.col : d.col, m, sc.file);
            sc.n_n4242 = sc.n_n4242 + 1;
        }
    }
}

// ── Driver ──────────────────────────────────────────────────────────────
fn void StratChecker.scan(StratChecker* sc, Node* root, int depth)
{
    (void)depth;
    if (root == null) { return; }
    sc.collect(root, 0);
    sc.build_edges();
    sc.compute_sccs();
    sc.classify();
    sc.verdicts();
}

fn void StratChecker.report(StratChecker* sc)
{
    printf("  strata           : %d type decls in %d strata (depth %d): %d recursive (%d guarded, %d by value, %d via variant), %d alias cycles, %d non-regular, %d non-positive\n",
           (int)sc.n_decls, sc.n_sccs, sc.max_level, (int)sc.n_recursive, (int)sc.n_rec_guarded, (int)sc.n_rec_value, (int)sc.n_rec_variant,
           (int)sc.n_alias_cycles, (int)sc.n_nonregular, (int)sc.n_nonpositive);
    printf("  strata-edges     : %d edges (%d value, %d guarded, %d alias), %d generic params, %d forall, %d exists, %d bounds\n",
           (int)sc.n_edges, (int)sc.n_value_edges, (int)sc.n_guarded_edges, (int)sc.n_alias_edges,
           (int)sc.n_params_total, (int)sc.n_forall, (int)sc.n_exists, (int)sc.n_bounds);
}
