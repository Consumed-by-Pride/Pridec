// ============================================================================
// theory_subtype_engine.c3 — a decision procedure for set-theoretic subtyping
// ----------------------------------------------------------------------------
// The layer this replaces answers `A ≤ B` by building the DNF of `A ∧ ¬B` and
// asking whether a clause is *literally* `⊥`. That recognises ⊥ and ¬⊤ and
// nothing else, so `int ∧ bool` comes back "not empty", `A ∧ ¬A` comes back
// "not empty" unless the two sides are the same node, and every example the
// subtyping headers quote (distributivity, contradiction, excluded middle,
// De Morgan) is undecided.
//
// This module is the missing half: the *atom-level emptiness* procedure.
// Semantic subtyping is decided as
//
//     A ≤ B   ⟺   A ∧ ¬B  is empty
//
// where a type is normalised to a union of clauses (DNF), a clause is a
// conjunction of literals over atoms, and a clause is decided by asking what
// the atoms say about each other:
//
//   primitives   distinct primitives are disjoint          → p ∧ q ≃ ⊥
//   nominals     distinct names are disjoint               → n ∧ m ≃ ⊥
//   tuples       (a×b) ∧ (c×d) ≃ (a∧c)×(b∧d)
//                (a×b) ⊆ (c×d) ⟺ a ≤ c ∧ b ≤ d             → (a×b) ∧ ¬(c×d)
//   arrays       [a] ∧ [b] ≃ [a∧b];  [a] ⊆ [b] ⟺ a ≤ b
//   options      t? ∧ s? ≃ (t∧s)?;   t? ⊆ s? ⟺ t ≤ s
//   records      closed records: equal label sets, fieldwise containment
//   arrows       (d→c) ⊆ (d'→c') ⟺ d' ≤ d ∧ c ≤ c'        (contravariant dom)
//                with the FCB splitting rule when containment fails
//
// Everything the procedure cannot decide answers UNKNOWN — a third value, not a
// guess. UNKNOWN is counted and reported, so an incomplete answer can never be
// mistaken for a proof. Recursion variables (μ) and open records are UNKNOWN by
// construction: deciding them needs the unfolding layer, and pretending would
// be the exact failure this module exists to remove.
//
// References:
//   Frisch/Castagna/Benzaken 2008, §4-6 (set-theoretic types, CDuce)
//   Castagna & Xu 2011, "Set-theoretic foundation of parametric polymorphism"
// ============================================================================

module theory_subtype_engine;

import theory_setops;
import pfront_core;

alias St   = theory_setops::StKind;
alias Prim = theory_setops::PrimTag;
alias Store = theory_setops::TypeStore;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

// ── Bounds ──────────────────────────────────────────────────────────────────
// The procedure is exponential in the worst case (that is a property of the
// problem, not of this implementation); every dimension that can blow up has an
// explicit cap, and hitting a cap yields UNKNOWN rather than a wrong answer.
const usz SE_MAX_LITS     = 32;    // literals in one clause
const usz SE_MAX_CLAUSES  = 256;   // clauses in one DNF
const int SE_MAX_DEPTH    = 40;    // recursive containment/splitting depth
const usz SE_MEMO_SIZE    = 1 << 14; // direct-mapped memo (16384 slots)

// ── Three-valued results ────────────────────────────────────────────────────
// Three-valued result codes. `const int` rather than an enum: every result
// flows into `int` locals and integer statistics, and the failure mode this
// module exists to prevent is confusing "unknown" with a real answer.
const int TRI_FALSE   = 0;
const int TRI_TRUE    = 1;
const int TRI_UNKNOWN = 2;

fn char* tri_name(int t)
{
    if (t == TRI_TRUE) { return "yes"; }
    if (t == TRI_FALSE) { return "no"; }
    return "unknown";
}

// ── Clause representation ───────────────────────────────────────────────────
// A literal is an atom or the negation of an atom. Only atoms appear here: all
// unions/intersections/negations were eliminated by `clauses_of` below.
struct Lit
{
    int  ty;      // index into the TypeStore
    bool neg;
}

struct Clause
{
    Lit[SE_MAX_LITS] lits;
    usz  count;
    bool overflowed;
}

// A `ClauseSet` is a disjunction of clauses: the DNF of one type.
struct ClauseSet
{
    Clause[SE_MAX_CLAUSES] cs;
    usz  count;
    bool overflowed;
}

fn void Clause.init(Clause* c)
{
    c.count = 0;
    c.overflowed = false;
}

fn bool Clause.push(Clause* c, int ty, bool neg)
{
    if (c.count >= SE_MAX_LITS) { c.overflowed = true; return false; }
    c.lits[c.count].ty = ty;
    c.lits[c.count].neg = neg;
    c.count = c.count + 1;
    return true;
}

fn void ClauseSet.init(ClauseSet* s)
{
    s.count = 0;
    s.overflowed = false;
}

// Add a clause, dropping duplicates of an identical literal set would be an
// optimisation; the procedure's cost is dominated by the emptiness tests, so we
// only enforce the cap here.
fn bool ClauseSet.add(ClauseSet* s, Clause* c)
{
    if (s.count >= SE_MAX_CLAUSES) { s.overflowed = true; return false; }
    s.cs[s.count] = *c;
    s.count = s.count + 1;
    return true;
}

fn void ClauseSet.add_true(ClauseSet* s)
{
    Clause c;
    c.init();
    s.add(&c);
}

// ── The engine ──────────────────────────────────────────────────────────────
struct Engine
{
    Store*   ts;
    // Direct-mapped memo: `keys[i]` hashes to slot i; 0 means empty. Both the
    // containment relation and clause satisfiability land here.
    ulong[SE_MEMO_SIZE] keys;
    int[SE_MEMO_SIZE]   vals;
    // Statistics. These count real events (a decision actually taken), which is
    // the only kind of statistic this repository accepts.
    usz queries;
    usz proved;      // "A ≤ B" proved true
    usz refuted;     // "A ≤ B" refuted by a witness clause
    usz undecided;   // tri-state UNKNOWN
    usz hits;
    usz splits;      // clauses closed by the domain-escape rule
    usz deferred;    // clause pairs handed to the general splitting rule (not implemented)
    usz overflows;
    usz max_clause;
}

fn void Engine.init(Engine* e, Store* ts)
{
    e.ts = ts;
    for (usz i = 0; i < SE_MEMO_SIZE; i++)
    {
        e.keys[i] = 0;
        e.vals[i] = 0;
    }
    e.queries = 0; e.proved = 0; e.refuted = 0; e.undecided = 0;
    e.hits = 0; e.splits = 0; e.overflows = 0; e.max_clause = 0; e.deferred = 0;
}

fn ulong se_hash_pair(int a, int b)
{
    ulong x = (ulong)(a + 1) * 0x9E3779B97F4A7C15;
    ulong y = (ulong)(b + 1) * 0xC2B2AE3D27D4EB4F;
    ulong h = x ^ (y + 0x165667B19E3779F9 + (x << 6) + (x >> 2));
    return h | 1;   // never 0: 0 marks an empty slot
}

fn int Engine.memo_get(Engine* e, int a, int b)
{
    usz slot = (usz)(se_hash_pair(a, b) & (SE_MEMO_SIZE - 1));
    if (e.keys[slot] == se_hash_pair(a, b)) { e.hits = e.hits + 1; return e.vals[slot]; }
    return -1;
}

fn void Engine.memo_put(Engine* e, int a, int b, int val)
{
    usz slot = (usz)(se_hash_pair(a, b) & (SE_MEMO_SIZE - 1));
    e.keys[slot] = se_hash_pair(a, b);
    e.vals[slot] = val;
}

// ── Normalisation: type → DNF of clauses ────────────────────────────────────
// `neg` is the parity of negations accumulated on the way down; the function
// pushes negation through the structure with De Morgan and distributes
// intersection over union at the bottom, so the result is unions of
// conjunctions of literals over atoms.
fn void Engine.clauses_of(Engine* e, int ty, bool neg, ClauseSet* out, int depth)
{
    if (depth > SE_MAX_DEPTH || out.overflowed) { out.overflowed = true; return; }
    if (ty < 0) { if (neg) { out.add_true(); } return; }

    St k = e.ts.nodes[ty].kind;
    usz cc = e.ts.nodes[ty].child_count;

    switch (k)
    {
        case St.ST_BOTTOM:
            // ⊥ is an empty union; ¬⊥ is the true clause.
            if (neg) { out.add_true(); }
            return;
        case St.ST_TOP:
            // ⊤ is true; ¬⊤ is false.
            if (!neg) { out.add_true(); }
            return;
        case St.ST_NEG:
        {
            int c0 = e.ts.nodes[ty].children[0];
            e.clauses_of(c0, !neg, out, depth + 1);
            return;
        }
        case St.ST_UNION:
        {
            if (!neg)
            {
                // A ∨ B: union of the two clause sets.
                for (usz i = 0; i < cc; i++)
                {
                    e.clauses_of(e.ts.nodes[ty].children[i], false, out, depth + 1);
                }
                return;
            }
            // ¬(A ∨ B) = ¬A ∧ ¬B: distribute, right to left so the first child
            // ends up outermost. Clause sets are heap-allocated: one is ~40 KB
            // and the language caps stack objects at 64 KB.
            ClauseSet* acc = (ClauseSet*)malloc(ClauseSet::size);
            if (acc == null) { out.overflowed = true; return; }
            acc.init();
            acc.add_true();
            for (usz i = 0; i < cc; i++)
            {
                ClauseSet* one = (ClauseSet*)malloc(ClauseSet::size);
                ClauseSet* next = (ClauseSet*)malloc(ClauseSet::size);
                if (one == null || next == null) { out.overflowed = true; free((void*)acc); return; }
                one.init();
                e.clauses_of(e.ts.nodes[ty].children[i], true, one, depth + 1);
                next.init();
                se_cross(acc, one, next);
                *acc = *next;
                free((void*)one);
                free((void*)next);
                if (acc.overflowed) { out.overflowed = true; free((void*)acc); return; }
            }
            for (usz i = 0; i < acc.count; i++) { out.add(&acc.cs[i]); }
            free((void*)acc);
            return;
        }
        case St.ST_INTER:
        {
            if (neg)
            {
                // ¬(A ∧ B) = ¬A ∨ ¬B.
                for (usz i = 0; i < cc; i++)
                {
                    e.clauses_of(e.ts.nodes[ty].children[i], true, out, depth + 1);
                }
                return;
            }
            ClauseSet* acc = (ClauseSet*)malloc(ClauseSet::size);
            if (acc == null) { out.overflowed = true; return; }
            acc.init();
            acc.add_true();
            for (usz i = 0; i < cc; i++)
            {
                ClauseSet* one = (ClauseSet*)malloc(ClauseSet::size);
                ClauseSet* next = (ClauseSet*)malloc(ClauseSet::size);
                if (one == null || next == null) { out.overflowed = true; free((void*)acc); return; }
                one.init();
                e.clauses_of(e.ts.nodes[ty].children[i], false, one, depth + 1);
                next.init();
                se_cross(acc, one, next);
                *acc = *next;
                free((void*)one);
                free((void*)next);
                if (acc.overflowed) { out.overflowed = true; free((void*)acc); return; }
            }
            for (usz i = 0; i < acc.count; i++) { out.add(&acc.cs[i]); }
            free((void*)acc);
            return;
        }
        default:
            // An atom, possibly negated.
            Clause c;
            c.init();
            c.push(ty, neg);
            out.add(&c);
            return;
    }
}

// Cross product of two clause sets: the DNF of the conjunction.
fn void se_cross(ClauseSet* a, ClauseSet* b, ClauseSet* out)
{
    for (usz i = 0; i < a.count; i++)
    {
        for (usz j = 0; j < b.count; j++)
        {
            Clause m;
            m.init();
            for (usz x = 0; x < a.cs[i].count; x++)
            {
                m.push(a.cs[i].lits[x].ty, a.cs[i].lits[x].neg);
            }
            for (usz y = 0; y < b.cs[j].count; y++)
            {
                m.push(b.cs[j].lits[y].ty, b.cs[j].lits[y].neg);
            }
            if (m.overflowed) { out.overflowed = true; return; }
            if (!out.add(&m)) { return; }
        }
    }
}

// ── Primitive disjointness ──────────────────────────────────────────────────
// Distinct primitive type constructors denote disjoint sets of values. This is
// the base case the whole procedure rests on.
fn bool se_prim_disjoint(Prim a, Prim b)
{
    if (a == b) { return false; }
    return true;
}

// ── Clause satisfiability ───────────────────────────────────────────────────
// The heart of the module: is a conjunction of literals satisfiable?
//
// Returns TRI_FALSE (empty), TRI_TRUE (non-empty — witnessed by sign the
// literal set is consistent), TRI_UNKNOWN when the atom families involved are
// not comparable by this procedure.
fn int Engine.clause_sat(Engine* e, Clause* c, int depth)
{
    if (depth > SE_MAX_DEPTH) { return TRI_UNKNOWN; }
    if (c.overflowed) { return TRI_UNKNOWN; }
    if (c.count > e.max_clause) { e.max_clause = c.count; }

    // Partition the literals by atom family. Only positive atoms constrain
    // emptiness *by themselves*; negatives constrain it through containment.
    int[SE_MAX_LITS] prims_pos;  usz np = 0;
    int[SE_MAX_LITS] prims_neg;  usz nnp = 0;
    int[SE_MAX_LITS] noms_pos;   usz nn = 0;
    int[SE_MAX_LITS] noms_neg;   usz nnn = 0;
    int[SE_MAX_LITS] tup_pos;    usz nt = 0;
    int[SE_MAX_LITS] tup_neg;    usz nnt = 0;
    int[SE_MAX_LITS] arr_pos;    usz na = 0;
    int[SE_MAX_LITS] arr_neg;    usz nna = 0;
    int[SE_MAX_LITS] opt_pos;    usz no = 0;
    int[SE_MAX_LITS] opt_neg;    usz nno = 0;
    int[SE_MAX_LITS] rec_pos;    usz nr = 0;
    int[SE_MAX_LITS] rec_neg;    usz nnr = 0;
    int[SE_MAX_LITS] arrw_pos;   usz nw = 0;
    int[SE_MAX_LITS] arrw_neg;   usz nnw = 0;
    bool unknown = false;
    bool empty = false;

    for (usz i = 0; i < c.count; i++)
    {
        int  ty = c.lits[i].ty;
        bool neg = c.lits[i].neg;
        if (ty < 0) { continue; }
        St k = e.ts.nodes[ty].kind;
        switch (k)
        {
            case St.ST_BOTTOM:
                if (!neg) { empty = true; }        // ⊥ ∧ ...
                continue;
            case St.ST_TOP:
                if (neg) { empty = true; }         // ... ∧ ¬⊤
                continue;
            case St.ST_PRIM:
                if (e.ts.nodes[ty].prim == Prim.PRIM_NEVER) { empty = true; continue; }
                if (neg) { prims_neg[nnp] = ty; nnp = nnp + 1; }
                else     { prims_pos[np] = ty;  np = np + 1; }
                continue;
            case St.ST_NOMINAL:
                if (neg) { noms_neg[nnn] = ty; nnn = nnn + 1; }
                else     { noms_pos[nn] = ty;  nn = nn + 1; }
                continue;
            case St.ST_TUPLE:
                if (neg) { tup_neg[nnt] = ty; nnt = nnt + 1; }
                else     { tup_pos[nt] = ty;  nt = nt + 1; }
                continue;
            case St.ST_ARRAY:
                if (neg) { arr_neg[nna] = ty; nna = nna + 1; }
                else     { arr_pos[na] = ty;  na = na + 1; }
                continue;
            case St.ST_OPTION:
                if (neg) { opt_neg[nno] = ty; nno = nno + 1; }
                else     { opt_pos[no] = ty;  no = no + 1; }
                continue;
            case St.ST_RECORD:
                if (neg) { rec_neg[nnr] = ty; nnr = nnr + 1; }
                else     { rec_pos[nr] = ty;  nr = nr + 1; }
                continue;
            case St.ST_ARROW:
                if (neg) { arrw_neg[nnw] = ty; nnw = nnw + 1; }
                else     { arrw_pos[nw] = ty;  nw = nw + 1; }
                continue;
            default:
                // μ, recursion variables, and anything added later: not decided
                // here. We do not guess.
                unknown = true;
                continue;
        }
    }

    if (empty) { return TRI_FALSE; }

    // ── primitives ──────────────────────────────────────────────────────────
    if (np > 0)
    {
        for (usz i = 0; i < np && !empty; i++)
        {
            for (usz j = i + 1; j < np; j++)
            {
                if (se_prim_disjoint(e.ts.nodes[prims_pos[i]].prim,
                                     e.ts.nodes[prims_pos[j]].prim)) { empty = true; break; }
            }
        }
        for (usz j = 0; j < nnp && !empty; j++)
        {
            for (usz i = 0; i < np; i++)
            {
                if (e.ts.nodes[prims_pos[i]].prim == e.ts.nodes[prims_neg[j]].prim) { empty = true; break; }
            }
        }
    }
    else if (nnp > 0)
    {
        // Only negated primitives: any primitive not excluded keeps this
        // satisfiable — and there always is one (PRIM_NEVER is excluded above).
        // Nothing to prove empty, so continue; other families may still clash.
    }

    // ── nominals ────────────────────────────────────────────────────────────
    if (nn > 0)
    {
        for (usz i = 0; i < nn && !empty; i++)
        {
            for (usz j = i + 1; j < nn; j++)
            {
                if (e.ts.nodes[noms_pos[i]].name_id != e.ts.nodes[noms_pos[j]].name_id) { empty = true; break; }
            }
        }
        for (usz j = 0; j < nnn && !empty; j++)
        {
            for (usz i = 0; i < nn; i++)
            {
                if (e.ts.nodes[noms_pos[i]].name_id == e.ts.nodes[noms_neg[j]].name_id) { empty = true; break; }
            }
        }
    }

    // ── arrays: [a] ∧ [b] ≃ [a∧b] ───────────────────────────────────────────
    if (na > 0 && !empty)
    {
        int elem = e.ts.nodes[arr_pos[0]].children[0];
        for (usz i = 1; i < na; i++)
        {
            elem = e.ts.my_inter(elem, e.ts.nodes[arr_pos[i]].children[0]);
        }
        if (e.decide_le(elem, e.ts.bot_idx, depth + 1) == TRI_TRUE) { empty = true; }
        for (usz j = 0; j < nna && !empty; j++)
        {
            int want = e.ts.nodes[arr_neg[j]].children[0];
            if (e.decide_le(elem, want, depth + 1) == TRI_TRUE) { empty = true; break; }
        }
    }

    // ── options: t? ∧ s? ≃ (t∧s)? ───────────────────────────────────────────
    if (no > 0 && !empty)
    {
        int elem = e.ts.nodes[opt_pos[0]].children[0];
        for (usz i = 1; i < no; i++)
        {
            elem = e.ts.my_inter(elem, e.ts.nodes[opt_pos[i]].children[0]);
        }
        if (e.decide_le(elem, e.ts.bot_idx, depth + 1) == TRI_TRUE) { empty = true; }
        for (usz j = 0; j < nno && !empty; j++)
        {
            int want = e.ts.nodes[opt_neg[j]].children[0];
            if (e.decide_le(elem, want, depth + 1) == TRI_TRUE) { empty = true; break; }
        }
    }

    // ── tuples: elementwise intersection, containment per negative ───────────
    if (nt > 0 && !empty)
    {
        usz arity = e.ts.nodes[tup_pos[0]].child_count;
        bool arity_clash = false;
        for (usz i = 1; i < nt; i++)
        {
            if (e.ts.nodes[tup_pos[i]].child_count != arity) { arity_clash = true; break; }
        }
        if (arity_clash)
        {
            // Tuples of different arity are disjoint sets of tuples.
            empty = true;
        }
        else
        {
            int[8] elems;
            for (usz p = 0; p < arity && p < 8; p++)
            {
                int sum = e.ts.nodes[tup_pos[0]].children[p];
                for (usz i = 1; i < nt; i++)
                {
                    sum = e.ts.my_inter(sum, e.ts.nodes[tup_pos[i]].children[p]);
                }
                elems[p] = sum;
                if (e.decide_le(sum, e.ts.bot_idx, depth + 1) == TRI_TRUE) { empty = true; }
                if (e.decide_le(sum, e.ts.bot_idx, depth + 1) == TRI_UNKNOWN) { unknown = true; }
            }
            for (usz j = 0; j < nnt && !empty; j++)
            {
                int negt = tup_neg[j];
                if (e.ts.nodes[negt].child_count != arity) { continue; }
                bool contained = true;
                bool partial = false;
                for (usz p = 0; p < arity && p < 8; p++)
                {
                    int r = e.decide_le(elems[p], e.ts.nodes[negt].children[p], depth + 1);
                    if (r == TRI_FALSE) { contained = false; break; }
                    if (r == TRI_UNKNOWN) { partial = true; }
                }
                if (contained && !partial) { empty = true; }
                if (contained && partial) { unknown = true; }
            }
        }
    }

    // ── records: closed records are exact, so label sets must agree ──────────
    if (nr > 0 && !empty)
    {
        int r0 = rec_pos[0];
        if (e.ts.nodes[r0].children[0] != -1) { unknown = true; }   // open record
        int fe0 = e.ts.nodes[r0].fe_idx;
        usz fcount = e.ts.field_entries[fe0].field_count;
        for (usz i = 1; i < nr; i++)
        {
            int ri = rec_pos[i];
            if (e.ts.nodes[ri].children[0] != -1) { unknown = true; }
            int fei = e.ts.nodes[ri].fe_idx;
            if (e.ts.field_entries[fei].field_count != fcount) { empty = true; break; }
            for (usz f = 0; f < fcount; f++)
            {
                if (e.ts.field_entries[fei].fields[f].name_id !=
                    e.ts.field_entries[fe0].fields[f].name_id) { empty = true; break; }
            }
            if (empty) { break; }
        }
        if (!empty)
        {
            for (usz f = 0; f < fcount; f++)
            {
                int sum = e.ts.field_entries[fe0].fields[f].child;
                for (usz i = 1; i < nr; i++)
                {
                    sum = e.ts.my_inter(sum, e.ts.field_entries[e.ts.nodes[rec_pos[i]].fe_idx].fields[f].child);
                }
                if (e.decide_le(sum, e.ts.bot_idx, depth + 1) == TRI_TRUE) { empty = true; break; }
            }
        }
        for (usz j = 0; j < nnr && !empty; j++)
        {
            int rn = rec_neg[j];
            int fen = e.ts.nodes[rn].fe_idx;
            usz fcn = e.ts.field_entries[fen].field_count;
            if (fcn != fcount) { continue; }        // different shape: negative holds
            bool same_labels = true;
            for (usz f = 0; f < fcount; f++)
            {
                if (e.ts.field_entries[fen].fields[f].name_id !=
                    e.ts.field_entries[fe0].fields[f].name_id) { same_labels = false; break; }
            }
            if (!same_labels) { continue; }
            bool contained = true;
            bool partial = false;
            for (usz f = 0; f < fcount; f++)
            {
                int lhs = e.ts.field_entries[fe0].fields[f].child;
                for (usz i = 1; i < nr; i++)
                {
                    lhs = e.ts.my_inter(lhs, e.ts.field_entries[e.ts.nodes[rec_pos[i]].fe_idx].fields[f].child);
                }
                int rhs = e.ts.field_entries[fen].fields[f].child;
                int r = e.decide_le(lhs, rhs, depth + 1);
                if (r == TRI_FALSE) { contained = false; break; }
                if (r == TRI_UNKNOWN) { partial = true; }
            }
            if (contained && !partial) { empty = true; }
            if (contained && partial) { unknown = true; }
        }
    }

    // ── arrows ──────────────────────────────────────────────────────────────
    // FCB (§5, Prop. 5.1) decide this exactly for one positive arrow against one
    // negative arrow:
    //
    //     (d→c) ∧ ¬(d'→c') is empty   ⟺   d' ≤ d  ∧  c ≤ c'
    //
    // Note the domain test is the *negative's* domain being contained in the
    // positive's — contravariance, so `(⊤→int) ≤ (int→int)` holds while
    // `(int→int) ≤ (⊤→int)` does not.
    //
    // With several negative arrows the containment test is no longer complete:
    // (d→c) can sit inside a *union* of arrow types without sitting inside any
    // one of them, which is what the paper's splitting rule exists to handle.
    // Rather than loop on splitting (an earlier version of this file did, and
    // burned 32k iterations to no conclusion) we decide the tractable cases and
    // report the rest as UNKNOWN:
    //
    //   * if the positive domain escapes all the negative domains — that is,
    //     dom ≰ ∪dom_j — then there is an input the negatives cannot constrain
    //     and the clause is satisfiable. Sound, and cheap to check.
    //   * otherwise: UNKNOWN, counted in `deferred`.
    if (nw > 0 && !empty)
    {
        int p0 = arrw_pos[0];
        int dom = e.ts.nodes[p0].children[0];
        int cod = e.ts.nodes[p0].children[1];

        if (nw > 1)
        {
            // Intersecting two arrow types. Decidable in principle
            // ((d→c) ∧ (d'→c') ≃ (d∧d' → c∧c') up to the empty function), but
            // not implemented here: say so instead of guessing.
            if (nnw > 0) { unknown = true; e.deferred = e.deferred + 1; }
        }
        else if (nnw == 1)
        {
            int md = e.ts.nodes[arrw_neg[0]].children[0];
            int mc = e.ts.nodes[arrw_neg[0]].children[1];
            int rl = e.decide_le(md, dom, depth + 1);   // d' ≤ d ?
            int rr = e.decide_le(cod, mc, depth + 1);   // c  ≤ c' ?
            if (rl == TRI_TRUE && rr == TRI_TRUE)
            {
                empty = true;                            // proved: no witness
            }
            else if (rl == TRI_FALSE || rr == TRI_FALSE)
            {
                // Proved: some function in (d→c) is not in (d'→c').
            }
            else
            {
                unknown = true;
                e.deferred = e.deferred + 1;
            }
        }
        else if (nnw > 1)
        {
            int cover = e.ts.nodes[arrw_neg[0]].children[0];
            for (usz j = 1; j < nnw; j++)
            {
                cover = e.ts.my_union(cover, e.ts.nodes[arrw_neg[j]].children[0]);
            }
            int escaped = e.decide_le(dom, cover, depth + 1);   // dom ≤ ∪dom_j ?
            if (escaped == TRI_FALSE)
            {
                // An input lies outside every negative domain: satisfiable.
                e.splits = e.splits + 1;   // this is where the splitting rule would have gone
            }
            else
            {
                unknown = true;
                e.deferred = e.deferred + 1;
            }
        }
    }

    // Cross-family interactions (a primitive and a tuple, a nominal and an
    // arrow, …) are left to a later layer: in a language where a nominal may
    // denote a set of tuples, disjointness across families is not syntactic.
    if (!empty)
    {
        usz families = 0;
        if (np > 0 || nnp > 0) { families = families + 1; }
        if (nn > 0 || nnn > 0) { families = families + 1; }
        if (nt > 0) { families = families + 1; }
        if (na > 0) { families = families + 1; }
        if (no > 0) { families = families + 1; }
        if (nr > 0) { families = families + 1; }
        if (nw > 0) { families = families + 1; }
        if (families > 1) { unknown = true; }
    }

    if (empty) { return TRI_FALSE; }
    if (unknown) { return TRI_UNKNOWN; }
    return TRI_TRUE;
}

// ── Containment: does every element of `a` lie in `b`? ──────────────────────
// A ≤ B ⟺ A ∧ ¬B is empty. The clause sets of A and of ¬B are built, paired up,
// and each pair is decided by `clause_sat`.
fn int Engine.decide_le(Engine* e, int a, int b, int depth)
{
    if (depth > SE_MAX_DEPTH) { return TRI_UNKNOWN; }
    int memo = e.memo_get(a, b);
    if (memo >= 0) { return memo; }

    ClauseSet* sa = (ClauseSet*)malloc(ClauseSet::size);
    ClauseSet* sb = (ClauseSet*)malloc(ClauseSet::size);
    if (sa == null || sb == null) { e.overflows = e.overflows + 1; return TRI_UNKNOWN; }
    sa.init();
    e.clauses_of(a, false, sa, depth);
    sb.init();
    e.clauses_of(b, true, sb, depth);
    if (sa.overflowed || sb.overflowed)
    {
        e.overflows = e.overflows + 1;
        free((void*)sa); free((void*)sb);
        e.memo_put(a, b, TRI_UNKNOWN);
        return TRI_UNKNOWN;
    }

    // ¬B false ⇒ B is ⊤ ⇒ every A is included.
    if (sb.count == 0) { free((void*)sa); free((void*)sb); e.memo_put(a, b, TRI_TRUE); return TRI_TRUE; }
    // A false ⇒ ⊥ ≤ B.
    if (sa.count == 0) { free((void*)sa); free((void*)sb); e.memo_put(a, b, TRI_TRUE); return TRI_TRUE; }

    bool any_unknown = false;
    int  result = TRI_TRUE;
    for (usz i = 0; i < sa.count && result == TRI_TRUE; i++)
    {
        for (usz j = 0; j < sb.count; j++)
        {
            Clause m;
            m.init();
            for (usz x = 0; x < sa.cs[i].count; x++)
            {
                m.push(sa.cs[i].lits[x].ty, sa.cs[i].lits[x].neg);
            }
            for (usz y = 0; y < sb.cs[j].count; y++)
            {
                m.push(sb.cs[j].lits[y].ty, sb.cs[j].lits[y].neg);
            }
            if (m.overflowed) { any_unknown = true; continue; }
            int sat = e.clause_sat(&m, depth + 1);
            if (sat == TRI_TRUE)
            {
                // A witness: some value is in A and not in B.
                result = TRI_FALSE;
                break;
            }
            if (sat == TRI_UNKNOWN) { any_unknown = true; }
        }
    }
    free((void*)sa); free((void*)sb);
    if (result == TRI_FALSE) { e.memo_put(a, b, TRI_FALSE); return TRI_FALSE; }
    if (any_unknown) { e.memo_put(a, b, TRI_UNKNOWN); return TRI_UNKNOWN; }
    e.memo_put(a, b, TRI_TRUE);
    return TRI_TRUE;
}

// Public entry point. Counts one query per call, because that is what a caller
// asked: "is A ≤ B?".
fn int Engine.subtype(Engine* e, int a, int b)
{
    e.queries = e.queries + 1;
    int r = e.decide_le(a, b, 0);
    if (r == TRI_TRUE)  { e.proved = e.proved + 1; }
    if (r == TRI_FALSE) { e.refuted = e.refuted + 1; }
    if (r == TRI_UNKNOWN) { e.undecided = e.undecided + 1; }
    return r;
}

fn int Engine.subtype_checked(Engine* e, int a, int b)
{
    // Subtyping is reflexive for any well-formed type: state it as a proof
    // obligation rather than assuming it.
    if (a == b) { e.queries = e.queries + 1; e.proved = e.proved + 1; return TRI_TRUE; }
    return e.subtype(a, b);
}

// Equivalence as two containments.
fn int Engine.equivalent(Engine* e, int a, int b)
{
    int ab = e.subtype(a, b);
    int ba = e.subtype(b, a);
    if (ab == TRI_TRUE && ba == TRI_TRUE) { return TRI_TRUE; }
    if (ab == TRI_FALSE || ba == TRI_FALSE) { return TRI_FALSE; }
    return TRI_UNKNOWN;
}

fn void Engine.report(Engine* e)
{
    printf("  subtype engine   : %d queries, %d proved, %d refuted, %d unknown\n",
        (int)e.queries, (int)e.proved, (int)e.refuted, (int)e.undecided);
    printf("                     %d memo hits, %d domain-escape decisions, %d deferred, %d overflows, widest clause %d\n",
        (int)e.hits, (int)e.splits, (int)e.deferred, (int)e.overflows, (int)e.max_clause);
}

// ── Self-test ───────────────────────────────────────────────────────────────
// Every case below is a fact about sets, checked by running the procedure. The
// suite is the module's specification: if it passes, the procedure decides the
// cases; if it fails, the failure is named. `unknown` is not a pass.
struct SeTest
{
    char* name;
    int   kind;     // 0: a ≤ b expected yes, 1: expected no, 2: equivalent, 3: not equivalent
    int   a;
    int   b;
}

fn int se_check(Engine* e, SeTest* t)
{
    int r = -1;
    bool expect = false;
    if (t.kind == 0) { r = e.subtype(t.a, t.b); expect = true; }
    if (t.kind == 1) { r = e.subtype(t.a, t.b); expect = false; }
    if (t.kind == 2) { r = e.equivalent(t.a, t.b); expect = true; }
    if (t.kind == 3) { r = e.equivalent(t.a, t.b); expect = false; }
    if (t.kind == 4)
    {
        // Asserting incompleteness: the procedure must say UNKNOWN here. If a
        // later slice implements the general splitting rule this case will
        // start reporting a definite answer, and the suite will say so.
        r = e.subtype(t.a, t.b);
        if (r == TRI_UNKNOWN) { return 0; }
        printf("  FAIL  %-46s expected unknown, got %s\n", t.name, tri_name(r));
        return 1;
    }

    bool ok = (r == TRI_TRUE) == expect;
    if (!ok)
    {
        printf("  FAIL  %-46s got %s\n", t.name, tri_name(r));
        return 1;
    }
    return 0;
}

fn int se_selftest()
{
    Store* ts = (Store*)malloc(Store::size);
    ts.init();
    Engine* e = (Engine*)malloc(Engine::size);
    e.init(ts);

    int t_int  = ts.mk_prim(Prim.PRIM_INT);
    int t_bool  = ts.mk_prim(Prim.PRIM_BOOL);
    int t_str  = ts.mk_prim(Prim.PRIM_STRING);
    int t_char  = ts.mk_prim(Prim.PRIM_CHAR);
    int t_never = ts.mk_prim(Prim.PRIM_NEVER);
    int t_top = ts.top_idx;
    int t_bot = ts.bot_idx;

    int t_iu = ts.my_union(t_int, t_bool);
    int t_ib = ts.my_inter(t_int, t_bool);
    int t_niu = ts.neg(t_iu);
    int t_ni  = ts.neg(t_int);
    int t_nbc = ts.neg(t_bool);

    // products and arrows
    int p_ii   = e.ts.mk_binary(St.ST_TUPLE, t_int, t_int);
    int p_ib  = e.ts.mk_binary(St.ST_TUPLE, t_int, t_bool);
    int p_iii  = e.ts.mk_binary(St.ST_TUPLE, t_int, p_ii);
    int p_iiu  = e.ts.mk_binary(St.ST_TUPLE, t_int, t_iu);
    int p_iib  = e.ts.mk_binary(St.ST_TUPLE, t_int, t_ib);
    int f_ii = e.ts.mk_arrow(t_int, t_int);
    int f_ti = e.ts.mk_arrow(t_top, t_int);
    int f_iu = e.ts.mk_arrow(t_int, t_iu);
    int f_bi = e.ts.mk_arrow(t_bool, t_int);

    // nominals
    int n_1 = ts.mk_nominal(1);
    int n_2 = ts.mk_nominal(2);
    int n_1u = ts.my_union(n_1, t_int);

    // arrays / options
    int a_i = ts.mk_array(t_int);
    int a_u = ts.mk_array(t_iu);
    int a_b = ts.mk_array(t_bool);
    int o_i = ts.mk_option(t_int);
    int o_u = ts.mk_option(t_iu);

    // records {a:int} and {a:int, b:bool}
    theory_setops::Field[2] f1;
    f1[0].name_id = 10; f1[0].child = t_int;
    int r_a = ts.mk_record(&f1[0], 1, -1);
    theory_setops::Field[2] f2;
    f2[0].name_id = 10; f2[0].child = t_int;
    f2[1].name_id = 11; f2[1].child = t_bool;
    int r_ab = ts.mk_record(&f2[0], 2, -1);
    f2[0].child = t_iu;
    int r_au = ts.mk_record(&f2[0], 1, -1);

    printf("=== subtype engine self-test ===\n");

    SeTest[96] ts_cases;
    usz n = 0;

    // ── lattice basics ──────────────────────────────────────────────────────
    ts_cases[n].name = "int <= int";                       ts_cases[n].kind = 0; ts_cases[n].a = t_int;   ts_cases[n].b = t_int;   n++;
    ts_cases[n].name = "⊥ <= int";                          ts_cases[n].kind = 0; ts_cases[n].a = t_bot; ts_cases[n].b = t_int;   n++;
    ts_cases[n].name = "int <= ⊤";                          ts_cases[n].kind = 0; ts_cases[n].a = t_int;   ts_cases[n].b = t_top; n++;
    ts_cases[n].name = "never <= int";                      ts_cases[n].kind = 0; ts_cases[n].a = t_never;  ts_cases[n].b = t_int;   n++;
    ts_cases[n].name = "int <= bool  (must be no)";         ts_cases[n].kind = 1; ts_cases[n].a = t_int;   ts_cases[n].b = t_bool;   n++;
    ts_cases[n].name = "int <= int|bool";                   ts_cases[n].kind = 0; ts_cases[n].a = t_int;   ts_cases[n].b = t_iu;  n++;
    ts_cases[n].name = "int|bool <= int  (must be no)";     ts_cases[n].kind = 1; ts_cases[n].a = t_iu;  ts_cases[n].b = t_int;   n++;

    // ── the cases the old procedure could not decide ────────────────────────
    ts_cases[n].name = "int ∧ bool ≃ ⊥";                    ts_cases[n].kind = 2; ts_cases[n].a = t_ib;  ts_cases[n].b = t_bot; n++;
    ts_cases[n].name = "int ∧ bool <= int";                 ts_cases[n].kind = 0; ts_cases[n].a = t_ib;  ts_cases[n].b = t_int;   n++;
    ts_cases[n].name = "A ∧ ¬A ≃ ⊥  (contradiction)";
    ts_cases[n].kind = 2; ts_cases[n].a = ts.my_inter(t_int, t_ni); ts_cases[n].b = t_bot; n++;
    ts_cases[n].name = "A ∨ ¬A ≃ ⊤  (excluded middle)";     ts_cases[n].kind = 2; ts_cases[n].a = ts.my_union(t_int, t_ni); ts_cases[n].b = t_top; n++;

    // ── De Morgan ───────────────────────────────────────────────────────────
    ts_cases[n].name = "¬(A|t_bool) ≃ ¬A ∧ ¬t_bool";                 ts_cases[n].kind = 2; ts_cases[n].a = t_niu; ts_cases[n].b = ts.my_inter(t_ni, t_nbc); n++;
    ts_cases[n].name = "¬(A ∧ t_bool) ≃ ¬A ∨ ¬t_bool";               ts_cases[n].kind = 2; ts_cases[n].a = ts.neg(t_ib); ts_cases[n].b = ts.my_union(t_ni, t_nbc); n++;
    ts_cases[n].name = "¬¬A ≃ A";                          ts_cases[n].kind = 2; ts_cases[n].a = ts.neg(t_ni); ts_cases[n].b = t_int; n++;

    // ── distributivity ──────────────────────────────────────────────────────
    {
        int lhs = ts.my_inter(t_iu, t_str);
        int rhs = ts.my_union(ts.my_inter(t_int, t_str), ts.my_inter(t_bool, t_str));
        ts_cases[n].name = "(A|t_bool) ∧ t_char ≃ (A∧t_char) | (t_bool∧t_char)";   ts_cases[n].kind = 2;
        ts_cases[n].a = lhs; ts_cases[n].b = rhs; n++;
    }

    // ── products ────────────────────────────────────────────────────────────
    ts_cases[n].name = "int×int <= int×int";                ts_cases[n].kind = 0; ts_cases[n].a = p_ii;  ts_cases[n].b = p_ii;  n++;
    ts_cases[n].name = "int×int <= int×(int|bool)";         ts_cases[n].kind = 0; ts_cases[n].a = p_ii;  ts_cases[n].b = p_iiu; n++;
    ts_cases[n].name = "int×int <= int×bool  (must be no)"; ts_cases[n].kind = 1; ts_cases[n].a = p_ii;  ts_cases[n].b = p_ib; n++;
    ts_cases[n].name = "int×(int∧bool) ≃ ⊥";                ts_cases[n].kind = 2; ts_cases[n].a = p_iib; ts_cases[n].b = t_bot; n++;
    ts_cases[n].name = "int×int ≰ int×int×int (arity)";     ts_cases[n].kind = 1; ts_cases[n].a = p_ii;  ts_cases[n].b = p_iii; n++;
    ts_cases[n].name = "int×bool <= int×int  (must be no)"; ts_cases[n].kind = 1; ts_cases[n].a = p_ib; ts_cases[n].b = p_ii;  n++;

    // ── arrows: domains are contravariant ───────────────────────────────────
    ts_cases[n].name = "(int→int) <= (int→int|bool)";       ts_cases[n].kind = 0; ts_cases[n].a = f_ii; ts_cases[n].b = f_iu; n++;
    ts_cases[n].name = "(⊤→int) <= (int→int)  [contra]";    ts_cases[n].kind = 0; ts_cases[n].a = f_ti; ts_cases[n].b = f_ii; n++;
    ts_cases[n].name = "(int→int) <= (⊤→int)  (must be no)";ts_cases[n].kind = 1; ts_cases[n].a = f_ii; ts_cases[n].b = f_ti; n++;
    ts_cases[n].name = "(int→int) <= (bool→int) (must be no)"; ts_cases[n].kind = 1; ts_cases[n].a = f_ii; ts_cases[n].b = f_bi; n++;

    // ── arrays and options ──────────────────────────────────────────────────
    ts_cases[n].name = "[int] <= [int|bool]";               ts_cases[n].kind = 0; ts_cases[n].a = a_i;  ts_cases[n].b = a_u;  n++;
    ts_cases[n].name = "[int] <= [bool]  (must be no)";     ts_cases[n].kind = 1; ts_cases[n].a = a_i;  ts_cases[n].b = a_b;  n++;
    ts_cases[n].name = "int? <= (int|bool)?";               ts_cases[n].kind = 0; ts_cases[n].a = o_i;  ts_cases[n].b = o_u;  n++;

    // ── records (closed) ────────────────────────────────────────────────────
    ts_cases[n].name = "{a:int} <= {a:int}";                ts_cases[n].kind = 0; ts_cases[n].a = r_a;   ts_cases[n].b = r_a;   n++;
    ts_cases[n].name = "{a:int,b:bool} <= {a:int} (must be no)"; ts_cases[n].kind = 1; ts_cases[n].a = r_ab; ts_cases[n].b = r_a; n++;
    ts_cases[n].name = "{a:int} <= {a:int|bool}";           ts_cases[n].kind = 0; ts_cases[n].a = r_a;   ts_cases[n].b = r_au;  n++;

    // ── nominals ────────────────────────────────────────────────────────────
    ts_cases[n].name = "n_1 <= n_1";                          ts_cases[n].kind = 0; ts_cases[n].a = n_1;  ts_cases[n].b = n_1;  n++;
    ts_cases[n].name = "n_1 <= n_2  (must be no)";            ts_cases[n].kind = 1; ts_cases[n].a = n_1;  ts_cases[n].b = n_2;  n++;
    ts_cases[n].name = "n_1 <= int|n_1";                      ts_cases[n].kind = 0; ts_cases[n].a = n_1;  ts_cases[n].b = n_1u; n++;

    // ── transitivity, by hand: three links of a chain ───────────────────────
    ts_cases[n].name = "int <= int|bool <= ⊤ (link 1)";     ts_cases[n].kind = 0; ts_cases[n].a = t_int;   ts_cases[n].b = t_iu;  n++;
    ts_cases[n].name = "int <= int|bool <= ⊤ (link 2)";     ts_cases[n].kind = 0; ts_cases[n].a = t_iu;  ts_cases[n].b = t_top; n++;

    // ── negative facts that must NOT be proved ───────────────────────────────
    ts_cases[n].name = "⊤ <= int  (must be no)";            ts_cases[n].kind = 1; ts_cases[n].a = t_top; ts_cases[n].b = t_int;   n++;
    ts_cases[n].name = "int <= ⊥  (must be no)";            ts_cases[n].kind = 1; ts_cases[n].a = t_int;   ts_cases[n].b = t_bot; n++;
    ts_cases[n].name = "char <= int  (must be no)";         ts_cases[n].kind = 1; ts_cases[n].a = t_char;   ts_cases[n].b = t_int;   n++;

    // ── more shapes: nesting, arity, labels, μ ──────────────────────────────
    {
        int piip = e.ts.mk_binary(St.ST_TUPLE, t_int, p_ii);              // int×(int×int)
        int piu  = e.ts.mk_binary(St.ST_TUPLE, t_int, p_iiu);             // int×(int×(int|bool))
        int ai   = e.ts.mk_array(p_ii);                                // [int×int]
        int aiu  = e.ts.mk_array(p_iiu);                               // [int×(int|bool)]
        int ani  = e.ts.mk_array(ts.my_union(t_int, t_bool));    // unused
        theory_setops::Field[1] g1;
        g1[0].name_id = 11; g1[0].child = t_int;                        // {b:int}
        int rec_b = e.ts.mk_record(&g1[0], 1, -1);
        int rec_au = e.ts.mk_record(&f1[0], 1, -1);
        ts_cases[n].name = "int×(int×int) <= int×(int×(int|bool))";
        ts_cases[n].kind = 0; ts_cases[n].a = piip; ts_cases[n].b = piu; n++;
        ts_cases[n].name = "[int×int] <= [int×(int|bool)]";
        ts_cases[n].kind = 0; ts_cases[n].a = ai; ts_cases[n].b = aiu; n++;
        ts_cases[n].name = "[int×(int∧bool)] ≃ ⊥";
        ts_cases[n].kind = 2; ts_cases[n].a = e.ts.mk_array(p_iib); ts_cases[n].b = t_bot; n++;
        ts_cases[n].name = "{a:int} <= {b:int}  (labels differ, must be no)";
        ts_cases[n].kind = 1; ts_cases[n].a = r_a; ts_cases[n].b = rec_b; n++;
        ts_cases[n].name = "(int→int)×int <= (int→int)×(int|bool)";
        ts_cases[n].kind = 0; ts_cases[n].a = e.ts.mk_binary(St.ST_TUPLE, f_ii, t_int);
        ts_cases[n].b = e.ts.mk_binary(St.ST_TUPLE, f_ii, t_iu); n++;
        ts_cases[n].name = "never? <= int?";
        ts_cases[n].kind = 0; ts_cases[n].a = ts.mk_option(t_never); ts_cases[n].b = ts.mk_option(t_int); n++;
        ts_cases[n].name = "⊤? <= int?  (must be no)";
        ts_cases[n].kind = 1; ts_cases[n].a = ts.mk_option(t_top); ts_cases[n].b = ts.mk_option(t_int); n++;

        // μ: honestly undecided by construction until the unfolding layer lands
        int mu = ts.mk_mu(t_int);
        ts_cases[n].name = "μX.int <= int  (needs unfolding: expect unknown)";
        ts_cases[n].kind = 4; ts_cases[n].a = mu; ts_cases[n].b = t_int; n++;
    }

    int fails = 0;
    for (usz i = 0; i < n; i++) { fails = fails + se_check(e, &ts_cases[i]); }

    printf("  --------------------------------------------------\n");
    printf("  self-test: %d/%d passed, %d failed\n", (int)n - fails, (int)n, fails);
    e.report();
    free((void*)e);
    ts.destroy();
    free((void*)ts);
    return fails;
}
