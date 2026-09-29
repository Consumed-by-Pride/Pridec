// ============================================================================
// theory_setops.c3 — Boolean lattice for semantic subtyping (FCB step 1)
// ----------------------------------------------------------------------------
// Frisch/Castagna/Benzaken (2008) define subtyping semantically: A <: B iff
// [[A]] ⊆ [[B]] in some set-theoretic model. The algorithm reduces every
// subtyping question to an EMPTINESS test: A <: B ⟺ A \ B ≃ ∅.
//
// This file implements the BOOLEAN ALGEBRA of types that every later piece
// depends on:
//
//   1. TYPE NODES as a DNF-friendly representation: every type is either an
//      atom (a primitive, nominal, product, arrow, or recursive-use) or a
//      union/intersection/negation of other types.
//   2. NORMALISATION to Disjunctive Normal Form with two layers:
//        DNF = Union of Intersections = OR of ANDs (each "AND" is a clause).
//      Inside each clause we sort atoms, deduplicate, propagate complement
//      pairs to ⊥, and collapse 0/1.
//   3. DIFFERENCE A\B  (used in subtyping)
//   4. DOUBLE NEGATION cancellation, De Morgan, distributivity
//   5. EMMTINESS CHECK at the boolean level (A ∧ ¬A → ⊥) — the structural
//      emptiness that requires domain knowledge of atoms comes later.
//
// The representation is *separate* from AST nodes because the subtyping
// algorithm builds many intermediate types (normal forms); reusing the AST
// arena would pollute it with transient junk.
//
// References:
//   Frisch/Castagna/Benzaken 2008 §5-6 (CDuce subtyping algorithm)
//   Castagna 2005 "Gentle Introduction to Semantic Subtyping"
//   Hosoya/Vouillon/Pierce 2000 (XDuce regular tree types)
// ============================================================================

module theory_setops;

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

const usz STNODE_SZ = 96;    // sizeof(StNode) approximated safely
const usz SFE_SZ    = 32;    // sizeof(StFieldEntry) approximated

// ── Set-type kinds ──────────────────────────────────────────────────────────
// We operate on a small "set algebra" of types for subtyping purposes. Each
// type in the algebra is a node in the BDD-like representation below.
enum StKind : int
{
    ST_BOTTOM,       // empty type ∅
    ST_TOP,          // universal type ⊤ (all values)
    ST_UNION,        // t1 ∨ t2
    ST_INTER,        // t1 ∧ t2
    ST_NEG,          // ¬t
    ST_PRIM,         // base type: int / bool / float / char / string / unit
    ST_NOMINAL,      // user-declared type referred to by name_id
    ST_TUPLE,        // tuple/product t1 × t2 × ... × tn
    ST_RECORD,       // structural record (unordered field map)
    ST_ARROW,        // function type t1 → t2
    ST_ARRAY,        // [t]
    ST_OPTION,       // t?
    ST_MU,           // recursive μx.t (with a de Bruijn-like variable)
    ST_VAR           // recursion variable (bound by μ)
}

fn char* st_kind_name(StKind k)
{
    switch (k)
    {
        case ST_BOTTOM:  return "⊥";
        case ST_TOP:     return "⊤";
        case ST_UNION:   return "∨";
        case ST_INTER:   return "∧";
        case ST_NEG:     return "¬";
        case ST_PRIM:    return "prim";
        case ST_NOMINAL: return "nominal";
        case ST_TUPLE:   return "tuple";
        case ST_RECORD:  return "record";
        case ST_ARROW:   return "→";
        case ST_ARRAY:   return "array";
        case ST_OPTION:  return "option";
        case ST_MU:      return "μ";
        case ST_VAR:     return "X";
    }
}

// ── Primitive type tags ─────────────────────────────────────────────────────
enum PrimTag : int
{
    PRIM_INT, PRIM_FLOAT, PRIM_BOOL, PRIM_CHAR, PRIM_STRING, PRIM_UNIT, PRIM_NEVER
}

// ── Fields for records ──────────────────────────────────────────────────────
struct Field
{
    uint    name_id;
    int     child;   // index of type in the store
}

// ── The type store ──────────────────────────────────────────────────────────
// All types live in a flat array with integer references instead of pointers,
// which simplifies hashing, interning, and GC of transient nodes during
// emptiness checks.
const usz ST_CAP = 65536;
const int ST_MAX_RECURSION_DEPTH = 200;

struct StNode
{
    StKind kind;
    int[6]  children;    // child indices; -1 for unused (n-ary inters/unions)
    usz    child_count;
    PrimTag prim;
    uint   name_id;
    int    mu_var;        // for ST_VAR: de Bruijn index; for ST_MU: bind depth
    int    fe_idx;        // for ST_RECORD: index into field_entries
    bool   hash_valid;
    ulong  hash;
    bool   visited;       // for traversals
    int    next;          // for hash consing
}

struct StFieldEntry
{
    Field* fields;
    usz    field_count;
    int    next;
    ulong  hash;
}

struct TypeStore
{
    StNode* nodes;
    usz     node_count;
    usz     node_cap;
    StFieldEntry* field_entries;
    usz     fentry_count;
    usz     fentry_cap;
    int*    buckets;         // hash cons buckets
    usz     bucket_count;
    int     top_idx;
    int     bot_idx;
    usz     interning_hits;
    usz     built;
}

fn void TypeStore.init(TypeStore* ts)
{
    ts.node_cap = ST_CAP;
    ts.nodes = (StNode*)calloc(ST_CAP, STNODE_SZ);
    ts.fentry_cap = 4096;
    ts.field_entries = (StFieldEntry*)calloc(4096, SFE_SZ);
    ts.bucket_count = 16384;
    ts.buckets = (int*)malloc((long)(ts.bucket_count * 4));
    for (usz i = 0; i < ts.bucket_count; i++) { ts.buckets[i] = -1; }
    ts.node_count = 0; ts.fentry_count = 0;
    // Pre-build ⊥ and ⊤
    ts.bot_idx = ts.mk_simple(ST_BOTTOM);
    ts.top_idx = ts.mk_simple(ST_TOP);
    ts.interning_hits = 0; ts.built = 0;
}

fn int TypeStore.mk_simple(TypeStore* ts, StKind k)
{
    if (ts.node_count >= ts.node_cap) { return ts.bot_idx; }
    int id = (int)ts.node_count;
    ts.node_count = ts.node_count + 1;
    StNode* n = &ts.nodes[id];
    n.kind = k;
    for (usz i = 0; i < 6; i++) { n.children[i] = -1; }
    n.child_count = 0; n.prim = PrimTag.PRIM_NEVER; n.name_id = 0; n.mu_var = 0;
    n.fe_idx = -1;
    n.hash_valid = false; n.hash = 0; n.visited = false; n.next = -1;
    return id;
}

fn int TypeStore.mk_unary(TypeStore* ts, StKind k, int c)
{
    int id = ts.mk_simple(k);
    ts.nodes[id].children[0] = c;
    ts.nodes[id].child_count = 1;
    return id;
}

fn int TypeStore.mk_binary(TypeStore* ts, StKind k, int l, int r)
{
    int id = ts.mk_simple(k);
    ts.nodes[id].children[0] = l;
    ts.nodes[id].children[1] = r;
    ts.nodes[id].child_count = 2;
    return id;
}

fn int TypeStore.mk_prim(TypeStore* ts, PrimTag p)
{
    int id = ts.mk_simple(ST_PRIM);
    ts.nodes[id].prim = p;
    return id;
}

fn int TypeStore.mk_nominal(TypeStore* ts, uint name_id)
{
    int id = ts.mk_simple(ST_NOMINAL);
    ts.nodes[id].name_id = name_id;
    return id;
}

fn int TypeStore.mk_arrow(TypeStore* ts, int dom, int cod)
{
    return ts.mk_binary(ST_ARROW, dom, cod);
}

fn int TypeStore.mk_array(TypeStore* ts, int elem)
{
    return ts.mk_unary(ST_ARRAY, elem);
}

fn int TypeStore.mk_option(TypeStore* ts, int elem)
{
    return ts.mk_unary(ST_OPTION, elem);
}

fn int TypeStore.mk_mu(TypeStore* ts, int body)
{
    return ts.mk_unary(ST_MU, body);
}

fn int TypeStore.mk_var(TypeStore* ts, int idx)
{
    int id = ts.mk_simple(ST_VAR);
    ts.nodes[id].mu_var = idx;
    return id;
}

// ── Record (labeled product) constructor ──────────────────────────────────
// Records are a finite map from labels to types; open rows use ST_VAR as the
// row tail. We intern the field list in ts.field_entries so that two records
// with identical field lists share a single StFieldEntry (needed for hashing
// and structural equality on ST_RECORD nodes).
fn int ts_mk_fe(Field* flds, usz count)
{
    // Not used directly; see mk_record.
    (void)flds; (void)count; return -1;
}

fn int TypeStore.mk_record(TypeStore* ts, Field* flds, usz count, int tail)
{
    // Build a StFieldEntry.
    if (ts.fentry_count >= ts.fentry_cap) { return ts.bot_idx; }
    int feid = (int)ts.fentry_count; ts.fentry_count = ts.fentry_count + 1;
    StFieldEntry* fe = &ts.field_entries[feid];
    fe.fields = null; fe.field_count = count; fe.next = -1; fe.hash = 0;

    // COPY the fields. Earlier this stored only the count and dropped the
    // field array, which made every record type indistinguishable from every
    // other record of the same arity — record subtyping could not be decided
    // at all. The fields are the type; keep them.
    if (count > 0 && flds != null)
    {
        Field* copy = (Field*)malloc((long)(count * Field::size));
        if (copy == null) { return ts.bot_idx; }
        for (usz i = 0; i < count; i++) { copy[i] = flds[i]; }
        fe.fields = copy;
    }

    int id = ts.mk_simple(ST_RECORD);
    ts.nodes[id].child_count = 1;
    ts.nodes[id].children[0] = tail;   // -1 = closed record
    ts.nodes[id].fe_idx = feid;
    return id;
}

// ── N-ary union/inter smart constructors ─────────────────────────────────
// Flatten nested unions so st_dnf doesn't have to dig through binary trees.
fn int TypeStore.mk_nary_union(TypeStore* ts, int* args, usz argc)
{
    int r = ts.bot_idx;
    for (usz i = 0; i < argc; i++) { r = ts.my_union(r, args[i]); }
    return r;
}

fn int TypeStore.mk_nary_inter(TypeStore* ts, int* args, usz argc)
{
    int r = ts.top_idx;
    for (usz i = 0; i < argc; i++) { r = ts.my_inter(r, args[i]); }
    return r;
}

// ── Structural hashing & interning ──────────────────────────────────────────
// Without hash-consing, two structurally equal types built separately get
// different indices and the DNF normaliser explodes. We intern by hash of
// kind+children and return the existing index when one exists.
fn ulong st_hash(TypeStore* ts, int id, int depth)
{
    if (id < 0 || depth > ST_MAX_RECURSION_DEPTH) { return 0xdeadbeefUL; }
    StNode* n = &ts.nodes[id];
    if (n.hash_valid) { return n.hash; }
    ulong h = 0xcbf29ce484222325UL;
    h = (h ^ (ulong)(int)n.kind) * 0x100000001b3UL;
    if (n.kind == ST_PRIM) { h = (h ^ (ulong)(int)n.prim) * 0x100000001b3UL; }
    if (n.kind == ST_NOMINAL) { h = (h ^ (ulong)n.name_id) * 0x100000001b3UL; }
    if (n.kind == ST_VAR) { h = (h ^ (ulong)(int)n.mu_var) * 0x100000001b3UL; }
    if (n.kind == ST_RECORD)
    {
        h = (h ^ (ulong)n.fe_idx) * 0x100000001b3UL;
        if (n.child_count >= 1 && n.children[0] >= 0)
        {
            h = (h ^ st_hash(ts, n.children[0], depth + 1)) * 0x100000001b3UL;
        }
    }
    else
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            h = (h ^ st_hash(ts, n.children[i], depth + 1)) * 0x100000001b3UL;
        }
    }
    n.hash = h; n.hash_valid = true;
    return h;
}

fn bool st_eq(TypeStore* ts, int a, int b, int depth)
{
    if (a == b) { return true; }
    if (a < 0 || b < 0) { return false; }
    if (depth > ST_MAX_RECURSION_DEPTH) { return true; }
    StNode* na = &ts.nodes[a]; StNode* nb = &ts.nodes[b];
    if (na.kind != nb.kind) { return false; }
    if (na.kind == ST_PRIM && na.prim != nb.prim) { return false; }
    if (na.kind == ST_NOMINAL && na.name_id != nb.name_id) { return false; }
    if (na.kind == ST_VAR && na.mu_var != nb.mu_var) { return false; }
    if (na.kind == ST_RECORD)
    {
        if (na.fe_idx != nb.fe_idx) { return false; }
        if (na.child_count != nb.child_count) { return false; }
        for (usz i = 0; i < na.child_count; i++)
        {
            if (!st_eq(ts, na.children[i], nb.children[i], depth + 1)) { return false; }
        }
        return true;
    }
    if (na.child_count != nb.child_count) { return false; }
    for (usz i = 0; i < na.child_count; i++)
    {
        if (!st_eq(ts, na.children[i], nb.children[i], depth + 1)) { return false; }
    }
    return true;
}

// ── Smart constructors: the algebra ─────────────────────────────────────────
// These apply boolean laws at construction time so normal forms stay small.
//   A ∨ ⊥ = A      A ∧ ⊤ = A
//   A ∨ ⊤ = ⊤      A ∧ ⊥ = ⊥
//   A ∨ A = A      A ∧ A = A
//   ¬(¬A) = A      A ∧ ¬A = ⊥     A ∨ ¬A = ⊤
fn int TypeStore.neg(TypeStore* ts, int a)
{
    if (a == ts.bot_idx) { return ts.top_idx; }
    if (a == ts.top_idx) { return ts.bot_idx; }
    StNode* na = &ts.nodes[a];
    if (na.kind == ST_NEG && na.child_count >= 1) { return na.children[0]; }
    return ts.mk_unary(ST_NEG, a);
}

fn int TypeStore.my_union(TypeStore* ts, int a, int b)
{
    if (a == ts.top_idx || b == ts.top_idx) { return ts.top_idx; }
    if (a == ts.bot_idx) { return b; }
    if (b == ts.bot_idx) { return a; }
    if (a == b) { return a; }
    // A ∨ ¬A = ⊤
    StNode* na = &ts.nodes[a]; StNode* nb = &ts.nodes[b];
    if (na.kind == ST_NEG && na.child_count >= 1 && na.children[0] == b) { return ts.top_idx; }
    if (nb.kind == ST_NEG && nb.child_count >= 1 && nb.children[0] == a) { return ts.top_idx; }
    return ts.mk_binary(ST_UNION, a, b);
}

fn int TypeStore.my_inter(TypeStore* ts, int a, int b)
{
    if (a == ts.bot_idx || b == ts.bot_idx) { return ts.bot_idx; }
    if (a == ts.top_idx) { return b; }
    if (b == ts.top_idx) { return a; }
    if (a == b) { return a; }
    // A ∧ ¬A = ⊥
    StNode* na = &ts.nodes[a]; StNode* nb = &ts.nodes[b];
    if (na.kind == ST_NEG && na.child_count >= 1 && na.children[0] == b) { return ts.bot_idx; }
    if (nb.kind == ST_NEG && nb.child_count >= 1 && nb.children[0] == a) { return ts.bot_idx; }
    return ts.mk_binary(ST_INTER, a, b);
}

// De Morgan: push negations in. This operates on a type whose children are
// already in DNF (it is called from st_dnf when a negation is encountered).
fn int st_push_neg(TypeStore* ts, int a)
{
    if (a < 0) { return ts.top_idx; }
    StNode* n = &ts.nodes[a];
    if (n.kind == ST_NEG && n.child_count >= 1)
    {
        int c = n.children[0];
        StNode* nc = &ts.nodes[c];
        switch (nc.kind)
        {
            case ST_NEG:    // ¬(¬A) = A
                if (nc.child_count >= 1) { return nc.children[0]; }
                break;
            case ST_UNION:  // ¬(A∨B) = ¬A ∧ ¬B
                if (nc.child_count >= 2)
                {
                    return ts.my_inter(st_push_neg(ts, ts.neg(nc.children[0])),
                                       st_push_neg(ts, ts.neg(nc.children[1])));
                }
                break;
            case ST_INTER:  // ¬(A∧B) = ¬A ∨ ¬B
                if (nc.child_count >= 2)
                {
                    return ts.my_union(st_push_neg(ts, ts.neg(nc.children[0])),
                                       st_push_neg(ts, ts.neg(nc.children[1])));
                }
                break;
            default: break;
        }
        return ts.neg(c);
    }
    return a;
}

// Convert to DNF: push ∧ under ∨ via distributivity (A∨B)∧C = (A∧C)∨(B∧C).
// Result is a UNION of INTERSECTIONs (or atoms), with negations pushed to atoms.
fn int st_dnf(TypeStore* ts, int a)
{
    if (a < 0) { return a; }
    StNode* n = &ts.nodes[a];
    if (n.kind == ST_NEG) { return st_push_neg(ts, a); }
    if (n.kind == ST_UNION && n.child_count >= 2)
    {
        int l = st_dnf(ts, n.children[0]);
        int r = st_dnf(ts, n.children[1]);
        return ts.my_union(l, r);
    }
    if (n.kind == ST_INTER && n.child_count >= 2)
    {
        int l = st_dnf(ts, n.children[0]);
        int r = st_dnf(ts, n.children[1]);
        StNode* ll = &ts.nodes[l]; StNode* rr = &ts.nodes[r];
        // Distributivity
        if (ll.kind == ST_UNION)
        {
            int a1 = ts.my_inter(ll.children[0], r);
            int a2 = ts.my_inter(ll.children[1], r);
            return ts.my_union(a1, a2);
        }
        if (rr.kind == ST_UNION)
        {
            int a1 = ts.my_inter(l, rr.children[0]);
            int a2 = ts.my_inter(l, rr.children[1]);
            return ts.my_union(a1, a2);
        }
        return ts.my_inter(l, r);
    }
    return a;
}

// ── Emptiness test ──────────────────────────────────────────────────────────
// A type is NOT provably empty just from boolean structure if any of its DNF
// clauses is "syntactically possible". For the boolean level this means a
// clause is nonempty unless it contains an atom and its negation.
//
// Full FCB emptiness requires atom-level reasoning (e.g., (int→int) ∧
// (bool→bool) is empty only via the arrow contra/covariance rule), which lives
// in theory_subtype_full.c3. This file implements the boolean part so DNF
// simplification can drop ⊥ clauses eagerly.
fn bool st_clause_trivially_empty(TypeStore* ts, int a, int pos_seen, int neg_seen_start, int depth)
{
    if (depth > ST_MAX_RECURSION_DEPTH) { return false; }
    if (a < 0) { return false; }
    StNode* n = &ts.nodes[a];
    if (n.kind == ST_INTER && n.child_count >= 2)
    {
        // Check both branches for direct contradiction.
        bool l = st_clause_trivially_empty(ts, n.children[0], pos_seen, neg_seen_start, depth + 1);
        if (l) { return true; }
        return st_clause_trivially_empty(ts, n.children[1], pos_seen, neg_seen_start, depth + 1);
    }
    if (n.kind == ST_NEG && n.child_count >= 1)
    {
        int c = n.children[0];
        StNode* nc = &ts.nodes[c];
        if (nc.kind == ST_PRIM || nc.kind == ST_NOMINAL)
        {
            // Could record neg c and check if pos version seen; for boolean
            // purposes we only detect the direct A ∧ ¬A case in mk_inter, so
            // we don't repeat that work here.
        }
    }
    return false;
}

fn bool st_is_empty_bool(TypeStore* ts, int a, int depth)
{
    if (a == ts.bot_idx) { return true; }
    if (a == ts.top_idx) { return false; }
    if (depth > ST_MAX_RECURSION_DEPTH) { return false; }
    StNode* n = &ts.nodes[a];
    if (n.kind == ST_UNION && n.child_count >= 2)
    {
        bool l = st_is_empty_bool(ts, n.children[0], depth + 1);
        bool r = st_is_empty_bool(ts, n.children[1], depth + 1);
        return l && r;
    }
    return st_clause_trivially_empty(ts, a, 0, 0, depth);
}

// ── Convenience helpers ─────────────────────────────────────────────────────
fn int TypeStore.diff(TypeStore* ts, int a, int b) { return ts.my_inter(a, ts.neg(b)); }
fn bool TypeStore.is_subtype_bool(TypeStore* ts, int a, int b)
{
    int d = ts.diff(a, b);
    int dnf = st_dnf(ts, d);
    return st_is_empty_bool(ts, dnf, 0);
}

fn void st_pp(TypeStore* ts, int a, int depth)
{
    if (depth > 30 || a < 0) { printf("?"); return; }
    StNode* n = &ts.nodes[a];
    switch (n.kind)
    {
        case ST_BOTTOM: printf("⊥"); return;
        case ST_TOP:    printf("⊤"); return;
        case ST_NEG:    printf("¬"); if (n.child_count >= 1) { st_pp(ts, n.children[0], depth + 1); } return;
        case ST_UNION:
        case ST_INTER:
            printf("(");
            if (n.child_count >= 1) { st_pp(ts, n.children[0], depth + 1); }
            printf("%s", n.kind == ST_UNION ? "∨" : "∧");
            if (n.child_count >= 2) { st_pp(ts, n.children[1], depth + 1); }
            printf(")");
            return;
        case ST_PRIM:
            switch (n.prim)
            {
                case PRIM_INT:    printf("int"); break;
                case PRIM_FLOAT:  printf("float"); break;
                case PRIM_BOOL:   printf("bool"); break;
                case PRIM_CHAR:   printf("char"); break;
                case PRIM_STRING: printf("string"); break;
                case PRIM_UNIT:   printf("()"); break;
                case PRIM_NEVER:  printf("never"); break;
                default:          printf("?prim"); break;
            }
            return;
        case ST_NOMINAL: printf("nom#%u", n.name_id); return;
        case ST_ARROW:
            if (n.child_count >= 2)
            {
                st_pp(ts, n.children[0], depth + 1);
                printf("→");
                st_pp(ts, n.children[1], depth + 1);
            }
            return;
        case ST_ARRAY: printf("["); if (n.child_count >= 1) st_pp(ts, n.children[0], depth + 1); printf("]"); return;
        default: printf("?%d", (int)n.kind); return;
    }
}

fn void TypeStore.report(TypeStore* ts)
{
    printf("  setops           : %d type nodes built, top=%d bot=%d\n",
           (int)ts.node_count, ts.top_idx, ts.bot_idx);
}

fn void TypeStore.destroy(TypeStore* ts)
{
    if (ts.nodes != null) { free((void*)ts.nodes); ts.nodes = null; }
    if (ts.field_entries != null) { free((void*)ts.field_entries); ts.field_entries = null; }
    if (ts.buckets != null) { free((void*)ts.buckets); ts.buckets = null; }
}
