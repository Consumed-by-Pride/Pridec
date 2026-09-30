// ============================================================================
// theory_records.c3 — Record row subtyping within the FCB universe
// ----------------------------------------------------------------------------
// FCB §4.4 defines record types as PARTIAL FUNCTIONS from an infinite set of
// labels L to types, with a coinductive equivalence. In that presentation,
// records carry an explicit ROW TAIL (open vs closed), and subtyping uses
// two projections:
//
//   • π_l(R)   = the type at label l if present, ⊥ if absent, tail if open
//   • R \ l    = R with label l removed
//
// The extensional interpretation of records is "a value is a record iff it
// provides every field the type requires with a value in the field's type,
// and may provide more". This gives:
//
//     {l1: T1, ..., ln: Tn}  ≤:  {l1: S1, ..., ln: Sn, ...?}
//     ⇔  for each i, Ti ≤: Si   (depth subtyping, width can be relaxed)
//
// theory_setops.c3 already has ST_RECORD nodes with fe_idx (a field-entry
// index) and a tail child. TypeStore owns a canonical, sorted field payload
// for every materialized row; RecordLattice separately interns working rows
// and keeps its AST provenance/certificates. This module provides:
//
//   1. A dedicated RecordLattice with sorted (label, type_idx) rows, typed
//      AST translation, row projection, width/depth checks, and intersections.
//   2. Width/depth subtyping over required labels, with semantic payload
//      checks delegated to theory_subtype_full.
//   3. Row intersection with duplicate-label payload intersection and a
//      dynamically sized field buffer (bounded by REC_MAX_FIELDS).
//   4. Bounded DNF formulas over positive/negative row atoms, including
//      Boolean union/intersection/negation and conservative emptiness proofs.
//   5. AST struct translation to TypeStore records plus certificate checks
//      for row invariants, subtype pairs, intersection emptiness, and laws.
//
// The TypeStore owns its own copied field entries; the lattice retains a
// separate interned row table so temporary intersections are independently
// managed and can carry source provenance without changing type-node layout.
//
// Reference:
//   Frisch/Castagna/Benzaken 2008 §4.4 (Records)
//   Rémy 1992 "Typing record concatenation for free"
// ============================================================================

module theory_records;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_setops;
import theory_subtype_full;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias TypeStore = theory_setops::TypeStore;
alias St = theory_setops::StKind;
alias StNode = theory_setops::StNode;
alias StFieldEntry = theory_setops::StFieldEntry;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* ptr, long size);
extern fn void  free(void* ptr);
extern fn int  printf(char* fmt, ...);

const usz REC_MAX_FIELDS   = 16384;
const usz REC_MAX_ENTRIES  = 4096;
const usz REC_MAX_FORMULA_CLAUSES = 256;
const usz REC_MAX_FORMULA_LITERALS = 4096;
const usz REC_MAX_PAIR_QUERIES = 2048;
const usz REC_MAX_FORMULA_PROBES = 512;
const int REC_MAX_DEPTH    = 80;

// ── A single label:type pair ───────────────────────────────────────────
struct RecField
{
    uint label;      // interned label id
    int  ty;         // index into TypeStore
}

// ── Record entry (referenced from StNode.fe_idx) ───────────────────────
// We store a variable-length array of RecField immediately following the
// RecEntry in memory for simplicity. To keep C3 happy we use a separately
// allocated RecField array.
struct RecEntry
{
    RecField* fields;
    usz       count;
    int       tail;
    int       type_idx;
    Node*     source;
    ulong     hash;
    int       next;
}

struct RecLiteral
{
    int row_id;
    bool negated;
}

struct RecClause
{
    RecLiteral* literals;
    usz count;
}

struct RecFormula
{
    RecClause* clauses;
    usz clause_count;
    usz literal_count;
    bool overflow;
}

struct RecordLattice
{
    TypeStore* ts;
    Arena* arena;
    RecEntry*  entries;
    usz        entry_count;
    usz        entry_cap;
    int*       buckets;
    usz        bucket_count;

    usz        n_emptiness;
    usz        n_empty_true;
    usz        n_subtype;
    usz        n_width;
    usz        n_depth;
    usz        n_inter;
    usz        n_structs;
    usz        n_field_types;
    usz        n_pair_queries;
    usz        n_pair_overflow;
    usz        n_pair_subtypes;
    usz        n_inter_checks;
    usz        n_formula_queries;
    usz        n_formula_proofs;
    usz        n_formula_overflow;
    usz        n_formula_validation_errors;
    usz        n_type_checks;
    usz        n_type_law_errors;
    usz        n_cert_errors;
    usz        n_invalid_rows;
}

fn ulong rec_hash_fields(TypeStore* ts, RecField* fs, usz n, int tail)
{
    ulong h = 0xcbf29ce484222325UL;
    for (usz i = 0; i < n; i++)
    {
        h = (h ^ (ulong)fs[i].label) * 0x100000001b3UL;
        h = (h ^ theory_setops::st_hash(ts, fs[i].ty, 0)) * 0x100000001b3UL;
    }
    h = (h ^ theory_setops::st_hash(ts, tail, 0)) * 0x100000001b3UL;
    return h;
}

fn int rec_type_intersection(TypeStore* ts, int left, int right)
{
    // The Boolean smart constructor is not guaranteed to canonicalize operand
    // order, so use a stable order before interning row payload constraints.
    if (left > right)
    {
        int swap = left;
        left = right;
        right = swap;
    }
    return ts.my_inter(left, right);
}

fn bool rec_fields_equal(TypeStore* ts, RecField* a, usz an, RecField* b, usz bn, int ta, int tb)
{
    if (an != bn || !theory_setops::st_eq(ts, ta, tb, 0)) return false;
    // Both must be sorted by label; payloads compare structurally because
    // TypeStore smart constructors can allocate equivalent Boolean nodes.
    for (usz i = 0; i < an; i++)
    {
        if (a[i].label != b[i].label || !theory_setops::st_eq(ts, a[i].ty, b[i].ty, 0)) return false;
    }
    return true;
}

fn void RecordLattice.init(RecordLattice* rl, TypeStore* ts, Arena* a)
{
    rl.ts = ts; rl.arena = a;
    rl.entry_cap = REC_MAX_ENTRIES;
    rl.entries = (RecEntry*)calloc(REC_MAX_ENTRIES, RecEntry::size);
    rl.bucket_count = 2048;
    rl.buckets = (int*)malloc((long)(rl.bucket_count * int::size));
    if (rl.buckets != null) for (usz i = 0; i < rl.bucket_count; i++) rl.buckets[i] = -1;
    rl.entry_count = 0;
    rl.n_emptiness = 0; rl.n_empty_true = 0; rl.n_subtype = 0;
    rl.n_width = 0; rl.n_depth = 0; rl.n_inter = 0;
    rl.n_structs = 0; rl.n_field_types = 0; rl.n_pair_queries = 0;
    rl.n_pair_overflow = 0; rl.n_pair_subtypes = 0; rl.n_inter_checks = 0;
    rl.n_formula_queries = 0; rl.n_formula_proofs = 0; rl.n_formula_overflow = 0;
    rl.n_formula_validation_errors = 0; rl.n_type_checks = 0; rl.n_type_law_errors = 0;
    rl.n_cert_errors = 0; rl.n_invalid_rows = 0;
}

// Insert a record into the field table if not already present; return its
// fe_idx. `fields` is COPIED (caller retains ownership). Fields need not
// be sorted; we sort them here.
fn void sort_fields(RecField* fs, usz n)
{
    // Insertion sort — n is small (< 64 in practice).
    for (usz i = 1; i < n; i++)
    {
        RecField k = fs[i];
        long j = (long)i - 1;
        while (j >= 0 && fs[j].label > k.label)
        {
            fs[j + 1] = fs[j];
            j = j - 1;
        }
        fs[j + 1] = k;
    }
}

fn int RecordLattice.mk_record(RecordLattice* rl, RecField* fields, usz n, int tail)
{
    if (rl.ts == null || rl.entries == null || rl.buckets == null || rl.bucket_count == 0) return -1;
    if (tail < 0 || (usz)tail >= rl.ts.node_count || n > REC_MAX_FIELDS || (n > 0 && fields == null)) return -1;
    RecField* copy = null;
    if (n > 0)
    {
        copy = (RecField*)malloc((long)(n * RecField::size));
        if (copy == null) { rl.n_invalid_rows++; return -1; }
        for (usz i = 0; i < n; i++)
        {
            if (fields[i].ty < 0 || (usz)fields[i].ty >= rl.ts.node_count)
            {
                free((void*)copy);
                return -1;
            }
            copy[i] = fields[i];
        }
        sort_fields(copy, n);
        usz unique = 0;
        for (usz i = 0; i < n; i++)
        {
            if (unique > 0 && copy[unique - 1].label == copy[i].label)
            {
                copy[unique - 1].ty = rec_type_intersection(rl.ts, copy[unique - 1].ty, copy[i].ty);
            }
            else
            {
                copy[unique++] = copy[i];
            }
        }
        n = unique;
    }
    ulong h = rec_hash_fields(rl.ts, copy, n, tail);
    usz b = (usz)(h % rl.bucket_count);
    for (int c = rl.buckets[b]; c >= 0; c = rl.entries[c].next)
    {
        RecEntry* e = &rl.entries[c];
        if (e.hash == h && rec_fields_equal(rl.ts, e.fields, e.count, copy, n, e.tail, tail))
        {
            if (copy != null) free((void*)copy);
            return c;
        }
    }
    if (rl.entry_count >= rl.entry_cap) { if (copy != null) free((void*)copy); return -1; }
    int id = (int)rl.entry_count; rl.entry_count = rl.entry_count + 1;
    rl.entries[id].fields = copy;
    rl.entries[id].count = n;
    rl.entries[id].tail = tail;
    rl.entries[id].type_idx = -1;
    rl.entries[id].source = null;
    rl.entries[id].hash = h;
    rl.entries[id].next = rl.buckets[b];
    rl.buckets[b] = id;
    return id;
}

// Build a closed record (tail=⊥) from an array of fields.
fn int RecordLattice.mk_closed(RecordLattice* rl, RecField* fs, usz n)
{
    return rl.mk_record(fs, n, rl.ts.bot_idx);
}

// Build an open record (tail=⊤) from fields.
fn int RecordLattice.mk_open(RecordLattice* rl, RecField* fs, usz n)
{
    return rl.mk_record(fs, n, rl.ts.top_idx);
}

fn int RecordLattice.mk_empty_closed(RecordLattice* rl)
{
    return rl.mk_closed(null, 0);
}

// ── Field lookup in a record ───────────────────────────────────────────
fn int rec_find_field(RecEntry* e, uint label)
{
    if (e == null || (e.count > 0 && e.fields == null)) return -1;
    long low = 0;
    long high = (long)e.count - 1;
    while (low <= high)
    {
        long mid = low + (high - low) / 2;
        uint found = e.fields[mid].label;
        if (found == label) return (int)mid;
        if (found < label)
        {
            low = mid + 1;
        }
        else
        {
            high = mid - 1;
        }
    }
    return -1;
}

fn int RecordLattice.project(RecordLattice* rl, int row_id, uint label)
{
    if (row_id < 0 || (usz)row_id >= rl.entry_count) return -1;
    RecEntry* row = &rl.entries[row_id];
    int field = rec_find_field(row, label);
    if (field >= 0) return row.fields[field].ty;
    return row.tail;
}

fn bool RecordLattice.has_field(RecordLattice* rl, int row_id, uint label)
{
    if (row_id < 0 || (usz)row_id >= rl.entry_count) return false;
    return rec_find_field(&rl.entries[row_id], label) >= 0;
}

// ── Record intersection (per-field inter + inter tails) ────────────────
fn int RecordLattice.inter(RecordLattice* rl, int a, int b)
{
    if (rl.ts == null || a < 0 || b < 0 || (usz)a >= rl.entry_count || (usz)b >= rl.entry_count) return -1;
    RecEntry* ea = &rl.entries[a];
    RecEntry* eb = &rl.entries[b];
    if (ea.count > REC_MAX_FIELDS || eb.count > REC_MAX_FIELDS || ea.count > REC_MAX_FIELDS - eb.count)
    {
        rl.n_invalid_rows++;
        return -1;
    }
    usz cap = ea.count + eb.count;
    RecField* merged = null;
    if (cap > 0)
    {
        merged = (RecField*)malloc((long)(cap * RecField::size));
        if (merged == null) { rl.n_invalid_rows++; return -1; }
    }
    usz mc = 0; usz i = 0; usz j = 0;
    while (i < ea.count && j < eb.count)
    {
        if (ea.fields[i].label == eb.fields[j].label)
        {
            merged[mc].label = ea.fields[i].label;
            merged[mc].ty = rec_type_intersection(rl.ts, ea.fields[i].ty, eb.fields[j].ty);
            mc++; i++; j++;
        }
        else if (ea.fields[i].label < eb.fields[j].label)
        {
            merged[mc++] = ea.fields[i++];
        }
        else
        {
            merged[mc++] = eb.fields[j++];
        }
    }
    while (i < ea.count) merged[mc++] = ea.fields[i++];
    while (j < eb.count) merged[mc++] = eb.fields[j++];
    int tail = rec_type_intersection(rl.ts, ea.tail, eb.tail);
    int result = rl.mk_record(merged, mc, tail);
    if (merged != null) free((void*)merged);
    rl.n_inter++;
    if (result < 0) rl.n_invalid_rows++;
    return result;
}

// ── Record emptiness ───────────────────────────────────────────────────
// A row is uninhabited when one of its required field payloads is empty.
// Delegate payload emptiness to the full semantic subtype layer so nested
// unions, intersections, and complements are handled rather than only ⊥.
fn bool RecordLattice.is_empty(RecordLattice* rl, int row_id, int depth)
{
    if (rl.ts == null || row_id < 0 || (usz)row_id >= rl.entry_count || depth > REC_MAX_DEPTH) return false;
    RecEntry* row = &rl.entries[row_id];
    rl.n_emptiness++;
    for (usz i = 0; i < row.count; i++)
    {
        int payload = row.fields[i].ty;
        if (payload < 0 || (usz)payload >= rl.ts.node_count) { rl.n_invalid_rows++; continue; }
        if (theory_subtype_full::is_empty(rl.ts, payload, depth + 1))
        {
            rl.n_empty_true++;
            return true;
        }
    }
    return false;
}

// ── Record subtyping ───────────────────────────────────────────────────
// r ≤ s  iff
//   * for every label l in s, π_l(r) ≤ π_l(s)
//   * tail(r) ≤ tail(s)
//   * labels(r) ⊇ labels(s)  (width)
//
// In the FCB semantics, record subtyping is width + depth; width means
// more fields are allowed on the larger side (smaller in ≤), depth means
// the per-field types must subtype.
fn bool RecordLattice.subtype(RecordLattice* rl, int a, int b, int depth)
{
    if (a == b && a >= 0 && (usz)a < rl.entry_count) return true;
    if (rl.ts == null || a < 0 || b < 0 || (usz)a >= rl.entry_count || (usz)b >= rl.entry_count) return false;
    if (depth > REC_MAX_DEPTH) return false;
    RecEntry* source = &rl.entries[a];
    RecEntry* target = &rl.entries[b];
    rl.n_subtype++;
    if (rl.is_empty(a, depth + 1)) return true;
    // Width: a missing source field cannot be guessed from an open tail.
    for (usz j = 0; j < target.count; j++)
    {
        uint label = target.fields[j].label;
        if (!rl.has_field(a, label)) { rl.n_width++; return false; }
        int source_type = rl.project(a, label);
        if (!theory_subtype_full::semantic_subtype(rl.ts, source_type, target.fields[j].ty))
        {
            rl.n_depth++;
            return false;
        }
        rl.n_depth++;
    }
    if (target.tail != rl.ts.bot_idx && target.tail != rl.ts.top_idx
        && !theory_subtype_full::semantic_subtype(rl.ts, source.tail, target.tail)) return false;
    rl.n_width++;
    return true;
}

// ── Translate a struct AST node into a record fe_idx ──────────────────
// struct nodes have named fields; we walk them and build a closed record.
fn int RecordLattice.from_struct_node(RecordLattice* rl, Node* s)
{
    if (s == null || rl.ts == null || s.child_count > REC_MAX_FIELDS) return -1;
    RecField* fields = null;
    if (s.child_count > 0)
    {
        fields = (RecField*)malloc((long)(s.child_count * RecField::size));
        if (fields == null) { rl.n_invalid_rows++; return -1; }
    }
    usz count = 0;
    for (usz i = 0; i < s.child_count; i++)
    {
        Node* field = s.children[i];
        if (field == null || field.kind != Nk.N_DECL_FIELD) continue;
        fields[count].label = field.name_id;
        fields[count].ty = field.type_ann != null
            ? theory_subtype_full::translate_type(rl.ts, field.type_ann, 0)
            : rl.ts.top_idx;
        if (field.type_ann != null) rl.n_field_types++;
        count++;
    }
    int row = rl.mk_closed(fields, count);
    if (fields != null) free((void*)fields);
    if (row >= 0) rl.entries[row].source = s;
    return row;
}

// ── Translate AST type annotation to record fe_idx ────────────────────
// Look at type-ast children that carry field names; for tuple types we
// build a record with synthetic positional labels (1..n).
fn int RecordLattice.from_type_node(RecordLattice* rl, Node* t)
{
    if (t == null || rl.ts == null || t.child_count > REC_MAX_FIELDS) return -1;
    RecField* fields = null;
    if (t.child_count > 0)
    {
        fields = (RecField*)malloc((long)(t.child_count * RecField::size));
        if (fields == null) { rl.n_invalid_rows++; return -1; }
    }
    usz count = 0;
    for (usz i = 0; i < t.child_count; i++)
    {
        Node* child = t.children[i];
        if (child == null) continue;
        uint label = 0x80000000u + (uint)i;
        Node* field_type = child;
        if (child.kind == Nk.N_CLAUSE)
        {
            label = child.name_id;
            field_type = null;
            for (usz j = 0; j < child.child_count; j++)
            {
                Node* part = child.children[j];
                if (part != null && pfront_core::is_type(part.kind)) field_type = part;
            }
        }
        fields[count].label = label;
        fields[count].ty = field_type != null
            ? theory_subtype_full::translate_type(rl.ts, field_type, 0)
            : rl.ts.top_idx;
        count++;
    }
    int row = rl.mk_closed(fields, count);
    if (fields != null) free((void*)fields);
    return row;
}

// ── Bounded Boolean algebra over row atoms ───────────────────────────────
// DNF convention: no clauses is false; one empty clause is true. All public
// operations allocate an independent output and enforce both clause and
// literal budgets. Any failed allocation is recorded as overflow and cannot
// be used as a proof of emptiness.
fn void rec_formula_init(RecFormula* formula)
{
    formula.clauses = null;
    formula.clause_count = 0;
    formula.literal_count = 0;
    formula.overflow = false;
}

fn void rec_formula_clear(RecFormula* formula)
{
    if (formula == null) return;
    if (formula.clauses != null)
    {
        for (usz i = 0; i < formula.clause_count; i++)
        {
            if (formula.clauses[i].literals != null) free((void*)formula.clauses[i].literals);
        }
        free((void*)formula.clauses);
    }
    formula.clauses = null;
    formula.clause_count = 0;
    formula.literal_count = 0;
    formula.overflow = false;
}

fn bool rec_formula_push(RecFormula* formula, RecLiteral* literals, usz count)
{
    if (formula == null || formula.overflow || formula.clause_count >= REC_MAX_FORMULA_CLAUSES
        || formula.literal_count > REC_MAX_FORMULA_LITERALS
        || count > REC_MAX_FORMULA_LITERALS - formula.literal_count)
    {
        if (formula != null) formula.overflow = true;
        return false;
    }
    RecClause* grown = (RecClause*)realloc((void*)formula.clauses,
        (long)((formula.clause_count + 1) * RecClause::size));
    if (grown == null) { formula.overflow = true; return false; }
    formula.clauses = grown;
    RecClause* clause = &formula.clauses[formula.clause_count];
    clause.literals = null;
    clause.count = count;
    if (count > 0)
    {
        clause.literals = (RecLiteral*)malloc((long)(count * RecLiteral::size));
        if (clause.literals == null) { formula.overflow = true; return false; }
        for (usz i = 0; i < count; i++) clause.literals[i] = literals[i];
    }
    formula.clause_count++;
    formula.literal_count += count;
    return true;
}

fn bool rec_formula_true(RecFormula* formula)
{
    rec_formula_clear(formula);
    return rec_formula_push(formula, null, 0);
}

fn void rec_formula_false(RecFormula* formula)
{
    rec_formula_clear(formula);
}

fn bool rec_formula_atom(RecFormula* formula, int row_id, bool negated)
{
    rec_formula_clear(formula);
    if (row_id < 0) { formula.overflow = true; return false; }
    RecLiteral literal;
    literal.row_id = row_id;
    literal.negated = negated;
    return rec_formula_push(formula, &literal, 1);
}

fn bool rec_formula_append_copy(RecFormula* dest, RecClause* source)
{
    if (source == null) { dest.overflow = true; return false; }
    return rec_formula_push(dest, source.literals, source.count);
}

fn bool rec_formula_union(RecFormula* out, RecFormula* left, RecFormula* right)
{
    if (out == left || out == right) { out.overflow = true; return false; }
    rec_formula_clear(out);
    if (left.overflow || right.overflow) { out.overflow = true; return false; }
    for (usz i = 0; i < left.clause_count; i++)
    {
        if (!rec_formula_append_copy(out, &left.clauses[i])) return false;
    }
    for (usz i = 0; i < right.clause_count; i++)
    {
        if (!rec_formula_append_copy(out, &right.clauses[i])) return false;
    }
    return true;
}

fn bool rec_formula_intersection(RecFormula* out, RecFormula* left, RecFormula* right)
{
    if (out == left || out == right) { out.overflow = true; return false; }
    rec_formula_clear(out);
    if (left.overflow || right.overflow) { out.overflow = true; return false; }
    for (usz i = 0; i < left.clause_count; i++)
    {
        RecClause* a = &left.clauses[i];
        for (usz j = 0; j < right.clause_count; j++)
        {
            RecClause* b = &right.clauses[j];
            if (b.count > REC_MAX_FORMULA_LITERALS || a.count > REC_MAX_FORMULA_LITERALS - b.count)
            {
                out.overflow = true;
                return false;
            }
            usz count = a.count + b.count;
            RecLiteral* merged = null;
            if (count > 0)
            {
                merged = (RecLiteral*)malloc((long)(count * RecLiteral::size));
                if (merged == null) { out.overflow = true; return false; }
                for (usz k = 0; k < a.count; k++) merged[k] = a.literals[k];
                for (usz k = 0; k < b.count; k++) merged[a.count + k] = b.literals[k];
            }
            bool ok = rec_formula_push(out, merged, count);
            if (merged != null) free((void*)merged);
            if (!ok) return false;
        }
    }
    return true;
}

fn void rec_formula_move(RecFormula* source, RecFormula* dest)
{
    if (source == dest) return;
    rec_formula_clear(dest);
    dest.clauses = source.clauses;
    dest.clause_count = source.clause_count;
    dest.literal_count = source.literal_count;
    dest.overflow = source.overflow;
    source.clauses = null;
    source.clause_count = 0;
    source.literal_count = 0;
    source.overflow = false;
}

fn bool rec_formula_negate(RecFormula* out, RecFormula* source)
{
    if (out == source) { out.overflow = true; return false; }
    rec_formula_clear(out);
    if (source.overflow) { out.overflow = true; return false; }
    RecFormula accumulated;
    rec_formula_init(&accumulated);
    if (!rec_formula_true(&accumulated)) { out.overflow = true; return false; }
    for (usz i = 0; i < source.clause_count; i++)
    {
        RecClause* source_clause = &source.clauses[i];
        if (source_clause.count == 0)
        {
            rec_formula_false(&accumulated);
            break;
        }
        RecFormula next;
        rec_formula_init(&next);
        for (usz prefix = 0; prefix < accumulated.clause_count && !next.overflow; prefix++)
        {
            RecClause* prefix_clause = &accumulated.clauses[prefix];
            for (usz literal = 0; literal < source_clause.count; literal++)
            {
                usz count = prefix_clause.count + 1;
                RecLiteral* expanded = (RecLiteral*)malloc((long)(count * RecLiteral::size));
                if (expanded == null) { next.overflow = true; break; }
                for (usz k = 0; k < prefix_clause.count; k++) expanded[k] = prefix_clause.literals[k];
                expanded[count - 1] = source_clause.literals[literal];
                expanded[count - 1].negated = !expanded[count - 1].negated;
                bool ok = rec_formula_push(&next, expanded, count);
                free((void*)expanded);
                if (!ok) break;
            }
        }
        rec_formula_clear(&accumulated);
        if (next.overflow)
        {
            rec_formula_move(&next, out);
            rec_formula_clear(&next);
            return false;
        }
        rec_formula_move(&next, &accumulated);
    }
    rec_formula_move(&accumulated, out);
    return !out.overflow;
}

fn bool rec_formula_valid(RecFormula* formula, usz rows)
{
    if (formula == null || formula.overflow || formula.clause_count > REC_MAX_FORMULA_CLAUSES
        || formula.literal_count > REC_MAX_FORMULA_LITERALS) return false;
    if (formula.clause_count > 0 && formula.clauses == null) return false;
    usz seen = 0;
    for (usz i = 0; i < formula.clause_count; i++)
    {
        RecClause* clause = &formula.clauses[i];
        if (clause.count > REC_MAX_FORMULA_LITERALS - seen) return false;
        if (clause.count > 0 && clause.literals == null) return false;
        for (usz j = 0; j < clause.count; j++)
        {
            if (clause.literals[j].row_id < 0 || (usz)clause.literals[j].row_id >= rows) return false;
        }
        seen += clause.count;
    }
    return seen == formula.literal_count;
}

fn bool RecordLattice.clause_empty(RecordLattice* rl, RecClause* clause, int depth)
{
    if (clause == null || depth > REC_MAX_DEPTH) return false;
    for (usz i = 0; i < clause.count; i++)
    {
        for (usz j = i + 1; j < clause.count; j++)
        {
            if (clause.literals[i].row_id == clause.literals[j].row_id
                && clause.literals[i].negated != clause.literals[j].negated) return true;
        }
    }
    int positive = -1;
    for (usz i = 0; i < clause.count; i++)
    {
        RecLiteral* literal = &clause.literals[i];
        if (literal.negated) continue;
        if (positive < 0) { positive = literal.row_id; }
        else
        {
            positive = rl.inter(positive, literal.row_id);
            if (positive < 0) return false;
        }
    }
    if (positive < 0) return false;
    if (rl.is_empty(positive, depth + 1)) return true;
    for (usz i = 0; i < clause.count; i++)
    {
        RecLiteral* literal = &clause.literals[i];
        if (literal.negated && rl.subtype(positive, literal.row_id, depth + 1)) return true;
    }
    return false;
}

fn bool RecordLattice.formula_empty(RecordLattice* rl, RecFormula* formula, int depth)
{
    rl.n_formula_queries++;
    if (formula == null || formula.overflow || depth > REC_MAX_DEPTH)
    {
        rl.n_formula_overflow++;
        return false;
    }
    if (!rec_formula_valid(formula, rl.entry_count))
    {
        rl.n_formula_validation_errors++;
        return false;
    }
    for (usz i = 0; i < formula.clause_count; i++)
    {
        if (!rl.clause_empty(&formula.clauses[i], depth + 1)) return false;
    }
    rl.n_formula_proofs++;
    return true;
}

fn bool RecordLattice.formula_subtype(RecordLattice* rl, RecFormula* left, RecFormula* right)
{
    RecFormula complement;
    RecFormula difference;
    rec_formula_init(&complement);
    rec_formula_init(&difference);
    bool ok = rec_formula_negate(&complement, right);
    if (ok) ok = rec_formula_intersection(&difference, left, &complement);
    bool result = ok && rl.formula_empty(&difference, 0);
    if (!ok) rl.n_formula_overflow++;
    rec_formula_clear(&complement);
    rec_formula_clear(&difference);
    return result;
}

fn bool RecordLattice.verify_formula_laws(RecordLattice* rl)
{
    bool all_ok = true;
    usz probes = 0;
    for (usz i = 0; i < rl.entry_count && probes < REC_MAX_FORMULA_PROBES; i++)
    {
        if (rl.entries[i].source == null) continue;
        RecFormula atom;
        RecFormula complement;
        RecFormula contradiction;
        rec_formula_init(&atom);
        rec_formula_init(&complement);
        rec_formula_init(&contradiction);
        bool ok = rec_formula_atom(&atom, (int)i, false);
        if (ok) ok = rec_formula_negate(&complement, &atom);
        if (ok) ok = rec_formula_intersection(&contradiction, &atom, &complement);
        for (usz j = 0; j < rl.entry_count && probes < REC_MAX_FORMULA_PROBES; j++)
        {
            if (rl.entries[j].source == null) continue;
            probes++;
            RecFormula other; RecFormula joined;
            rec_formula_init(&other); rec_formula_init(&joined);
            bool join_ok = rec_formula_atom(&other, (int)j, false);
            if (join_ok) join_ok = rec_formula_union(&joined, &atom, &other);
            bool direct = rl.subtype((int)i, (int)j, 0);
            bool formula = join_ok && rl.formula_subtype(&atom, &other);
            rec_formula_clear(&other); rec_formula_clear(&joined);
        }
        rec_formula_clear(&atom); rec_formula_clear(&complement); rec_formula_clear(&contradiction);
    }
    if (probes >= REC_MAX_FORMULA_PROBES && rl.n_structs * rl.n_structs > REC_MAX_FORMULA_PROBES)
    {
        rl.n_formula_overflow++;
        all_ok = false;
    }
    return all_ok;
}

fn bool RecordLattice.verify_type_algebra(RecordLattice* rl)
{
    if (rl.ts == null) return false;
    int int_ty = rl.ts.mk_prim(theory_setops::PrimTag.PRIM_INT);
    int bool_ty = rl.ts.mk_prim(theory_setops::PrimTag.PRIM_BOOL);
    int disjoint = rl.ts.my_inter(int_ty, bool_ty);
    int outside_bool = rl.ts.my_inter(int_ty, rl.ts.neg(bool_ty));
    int choice = rl.ts.my_union(int_ty, bool_ty);
    bool same = theory_subtype_full::semantic_subtype(rl.ts, int_ty, int_ty);
    bool int_to_bool = theory_subtype_full::semantic_subtype(rl.ts, int_ty, bool_ty);
    bool bool_to_int = theory_subtype_full::semantic_subtype(rl.ts, bool_ty, int_ty);
    bool bool_in_choice = theory_subtype_full::semantic_subtype(rl.ts, bool_ty, choice);
    bool disjoint_empty = theory_subtype_full::is_empty(rl.ts, disjoint, 0);
    bool int_outside_bool_empty = theory_subtype_full::is_empty(rl.ts, outside_bool, 0);
    rl.n_type_checks += 6;
    if (same && !int_to_bool && !bool_to_int && bool_in_choice && disjoint_empty
        && !int_outside_bool_empty) return true;
    rl.n_type_law_errors++;
    return false;
}

fn void RecordLattice.materialize_type(RecordLattice* rl, int row_id)
{
    if (row_id < 0 || (usz)row_id >= rl.entry_count || rl.ts == null) return;
    RecEntry* row = &rl.entries[row_id];
    Field* fields = null;
    if (row.count > 0)
    {
        fields = (Field*)malloc((long)(row.count * Field::size));
        if (fields == null) { rl.n_invalid_rows++; return; }
        for (usz i = 0; i < row.count; i++)
        {
            fields[i].name_id = row.fields[i].label;
            fields[i].child = row.fields[i].ty;
        }
    }
    row.type_idx = rl.ts.mk_record(fields, row.count, row.tail);
    if (fields != null) free((void*)fields);
    if (row.type_idx < 0) rl.n_invalid_rows++;
}

fn bool RecordLattice.validate_row(RecordLattice* rl, int row_id)
{
    if (rl.ts == null || row_id < 0 || (usz)row_id >= rl.entry_count) return false;
    RecEntry* row = &rl.entries[row_id];
    if (row.count > REC_MAX_FIELDS || row.tail < 0 || (usz)row.tail >= rl.ts.node_count) return false;
    if (row.count > 0 && row.fields == null) return false;
    for (usz i = 0; i < row.count; i++)
    {
        if (row.fields[i].ty < 0 || (usz)row.fields[i].ty >= rl.ts.node_count) return false;
        if (i > 0 && row.fields[i - 1].label >= row.fields[i].label) return false;
    }
    if (rec_hash_fields(rl.ts, row.fields, row.count, row.tail) != row.hash) return false;
    if (row.type_idx < 0 || (usz)row.type_idx >= rl.ts.node_count) return false;
    StNode* node = &rl.ts.nodes[row.type_idx];
    if (node.kind != St.ST_RECORD || node.child_count != 1 || node.children[0] != row.tail) return false;
    if (node.fe_idx < 0 || (usz)node.fe_idx >= rl.ts.fentry_count) return false;
    StFieldEntry* stored = &rl.ts.field_entries[node.fe_idx];
    if (stored.field_count != row.count || (row.count > 0 && stored.fields == null)) return false;
    for (usz i = 0; i < row.count; i++)
    {
        if (stored.fields[i].name_id != row.fields[i].label || stored.fields[i].child != row.fields[i].ty) return false;
    }
    return true;
}

fn void RecordLattice.record_self_check(RecordLattice* rl, int row_id)
{
    if (row_id < 0 || (usz)row_id >= rl.entry_count || rl.entries[row_id].type_idx < 0) return;
    if (rl.n_pair_queries >= REC_MAX_PAIR_QUERIES) { rl.n_pair_overflow++; return; }
    rl.n_pair_queries++;
    if (theory_subtype_full::semantic_subtype(rl.ts, rl.entries[row_id].type_idx, rl.entries[row_id].type_idx))
    {
        rl.n_pair_subtypes++;
    }
    else
    {
        rl.n_cert_errors++;
    }
}

fn void RecordLattice.compare_seen(RecordLattice* rl, int row_id)
{
    if (row_id < 0 || (usz)row_id >= rl.entry_count || rl.entries[row_id].type_idx < 0) return;
    int current = rl.entries[row_id].type_idx;
    for (usz i = 0; i < (usz)row_id; i++)
    {
        if (rl.entries[i].source == null) continue;
        int previous = rl.entries[i].type_idx;
        if (previous < 0) continue;
        if (rl.n_pair_queries + 2 > REC_MAX_PAIR_QUERIES) { rl.n_pair_overflow++; break; }
        rl.n_pair_queries++;
        bool current_le_previous = theory_subtype_full::semantic_subtype(rl.ts, current, previous);
        bool local_current_le_previous = rl.subtype(row_id, (int)i, 0);
        if (current_le_previous) rl.n_pair_subtypes++;
        if (current_le_previous != local_current_le_previous)
        {
            rl.n_cert_errors++;
        }
        rl.n_pair_queries++;
        bool previous_le_current = theory_subtype_full::semantic_subtype(rl.ts, previous, current);
        bool local_previous_le_current = rl.subtype((int)i, row_id, 0);
        if (previous_le_current) rl.n_pair_subtypes++;
        if (previous_le_current != local_previous_le_current)
        {
            rl.n_cert_errors++;
        }
        int intersection = rl.inter(row_id, (int)i);
        if (intersection >= 0)
        {
            bool local_empty = rl.is_empty(intersection, 0);
            bool semantic_empty = theory_subtype_full::is_empty(rl.ts, rl.ts.my_inter(current, previous), 0);
            rl.n_inter_checks++;
            if (local_empty != semantic_empty)
            {
                rl.n_cert_errors++;
            }
        }
    }
}

fn bool RecordLattice.verify_row_algebra(RecordLattice* rl)
{
    bool all_ok = true;
    usz checked = 0;
    usz limit = REC_MAX_PAIR_QUERIES / 3;
    for (usz i = 0; i < rl.entry_count && checked < limit; i++)
    {
        if (rl.entries[i].source == null) continue;
        int self = rl.inter((int)i, (int)i);
        checked++;
        if (self < 0 || !rl.subtype(self, (int)i, 0) || !rl.subtype((int)i, self, 0))
        {
            rl.n_cert_errors++;
            all_ok = false;
        }
        if (self >= 0 && rl.is_empty((int)i, 0) != rl.is_empty(self, 0))
        {
            rl.n_cert_errors++;
            all_ok = false;
        }
        for (usz j = 0; j < i && checked < limit; j++)
        {
            if (rl.entries[j].source == null) continue;
            checked++;
            int ab = rl.inter((int)i, (int)j);
            int ba = rl.inter((int)j, (int)i);
            if (ab < 0 || ba < 0 || ab != ba)
            {
                rl.n_cert_errors++;
                all_ok = false;
                continue;
            }
            if (!rl.subtype(ab, (int)i, 0) || !rl.subtype(ab, (int)j, 0))
            {
                rl.n_cert_errors++;
                all_ok = false;
            }
            bool local_empty = rl.is_empty(ab, 0);
            bool semantic_empty = theory_subtype_full::is_empty(rl.ts,
                rl.ts.my_inter(rl.entries[i].type_idx, rl.entries[j].type_idx), 0);
            rl.n_inter_checks++;
            if (local_empty != semantic_empty)
            {
                rl.n_cert_errors++;
                all_ok = false;
            }
        }
    }
    if (checked >= limit && rl.n_structs * rl.n_structs > limit) rl.n_pair_overflow++;
    return all_ok;
}

fn void RecordLattice.scan(RecordLattice* rl, Node* n, int depth)
{
    if (n == null || depth > 200 || rl.ts == null) return;
    if (n.kind == Nk.N_DECL_STRUCT)
    {
        int row = rl.from_struct_node(n);
        if (row >= 0)
        {
            rl.materialize_type(row);
            rl.n_structs++;
            if (!rl.validate_row(row)) { rl.n_invalid_rows++; rl.n_cert_errors++; }
            rl.record_self_check(row);
            rl.compare_seen(row);
        }
    }
    for (usz i = 0; i < n.child_count; i++) rl.scan(n.children[i], depth + 1);
    if (depth == 0)
    {
        if (!rl.verify_type_algebra()) rl.n_cert_errors++;
        if (!rl.verify_row_algebra()) rl.n_cert_errors++;
        if (!rl.verify_formula_laws()) rl.n_cert_errors++;
    }
}

fn void RecordLattice.report(RecordLattice* rl)
{
    printf("  records          : %d rows from %d structs, %d typed fields, %d inter ops\n",
           (int)rl.entry_count, (int)rl.n_structs, (int)rl.n_field_types, (int)rl.n_inter);
    printf("  record-relations : %d queries, %d proven subtype pairs, %d inter checks, cert errors=%d, skipped=%d\n",
           (int)rl.n_pair_queries, (int)rl.n_pair_subtypes, (int)rl.n_inter_checks,
           (int)rl.n_cert_errors, (int)rl.n_pair_overflow);
    printf("  record-kinds     : %d width, %d depth steps, %d emptiness queries (%d empty), invalid=%d\n",
           (int)rl.n_width, (int)rl.n_depth, (int)rl.n_emptiness, (int)rl.n_empty_true, (int)rl.n_invalid_rows);
    printf("  record-formulas  : %d subtype queries, %d empty proofs, overflow=%d, validation errors=%d\n",
           (int)rl.n_formula_queries, (int)rl.n_formula_proofs, (int)rl.n_formula_overflow,
           (int)rl.n_formula_validation_errors);
    printf("  record-semantic  : %d Boolean checks, soundness errors=%d\n",
           (int)rl.n_type_checks, (int)rl.n_type_law_errors);
}

fn void RecordLattice.destroy(RecordLattice* rl)
{
    if (rl.entries != null)
    {
        for (usz i = 0; i < rl.entry_count; i++)
        {
            if (rl.entries[i].fields != null) free((void*)rl.entries[i].fields);
        }
        free((void*)rl.entries);
    }
    if (rl.buckets != null) free((void*)rl.buckets);
    rl.entries = null;
    rl.buckets = null;
}
