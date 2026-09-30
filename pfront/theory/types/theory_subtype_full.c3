// ============================================================================
// theory_subtype_full.c3 — FCB semantic subtyping: atom-level emptiness
// ----------------------------------------------------------------------------
// theory_setops.c3 gives us the Boolean algebra. This file adds the
// EXTENSIONAL INTERPRETATION from Frisch/Castagna/Benzaken 2008 §4-6:
//
//   * primitives disjoint (int ∧ bool ≃ ∅)
//   * nominals: distinct names disjoint
//   * products:  (t1×t2) ∧ ¬(s1×s2) via projection
//   * records:   row-tail intersection
//   * arrows:    contra/covariant binary rule (d→c)∧¬(d'→c') ≃ ∅
//                  ⇐ d' ≤: d ∧ c ≤: c'
//   * arrays:    [t] ∧ [s] ≃ [t ∧ s]
//
// Emptiness is conservative under malformed stores, atom-budget exhaustion,
// or recursion cutoffs: uncertainty never becomes an emptiness proof. Boolean
// connectives are normalized only when a DNF clause actually needs distribution.
// Products, records, arrays, options, and arrows compare positive and negative
// atoms through their extensional projections; bounded algebra audits exercise
// those rules against independent coordinate-level expectations.
// ============================================================================

module theory_subtype_full;

import pfront_lex;
import pfront_core;
import theory_term;
import theory_setops;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias TypeStore = theory_setops::TypeStore;
alias St = theory_setops::StKind;
alias PrimTag = theory_setops::PrimTag;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* ptr, long size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const int SUB_MAX_DEPTH = 60;
const usz SUB_MAX_ATOMS = 4096;
const usz SUB_STACK_CAP = 512;
const usz SUB_AUDIT_LIMIT = 512;

// ── Atom collection per kind ─────────────────────────────────────────────
struct AtomSet
{
    int*     prim_pos; int* prim_neg; usz prim_pos_count; usz prim_neg_count;
    int*     nom_pos;  int* nom_neg;  usz nom_pos_count;  usz nom_neg_count;
    int*     prod_l;   int* prod_r;   usz prod_count;
    int*     prod_neg_l; int* prod_neg_r; usz prod_neg_count;
    int*     rec_ids;  usz  rec_count;
    int*     rec_neg_ids; usz rec_neg_count;
    int*     arr_dom;  int* arr_cod;  usz arr_count;
    int*     arr_neg_dom; int* arr_neg_cod; usz arr_neg_count;
    int*     arr_elem; usz  arr_elem_count;
    int*     arr_neg_elem; usz arr_neg_elem_count;
    int*     opt_inner; usz opt_count;
    int*     opt_neg_inner; usz opt_neg_count;
    bool     has_bot;  bool has_top;
    bool     overflow;
}

fn void atomset_init(AtomSet* a)
{
    a.prim_pos = null; a.prim_neg = null; a.prim_pos_count = 0; a.prim_neg_count = 0;
    a.nom_pos = null; a.nom_neg = null; a.nom_pos_count = 0; a.nom_neg_count = 0;
    a.prod_l = null; a.prod_r = null; a.prod_count = 0;
    a.prod_neg_l = null; a.prod_neg_r = null; a.prod_neg_count = 0;
    a.rec_ids = null; a.rec_count = 0;
    a.rec_neg_ids = null; a.rec_neg_count = 0;
    a.arr_dom = null; a.arr_cod = null; a.arr_count = 0;
    a.arr_neg_dom = null; a.arr_neg_cod = null; a.arr_neg_count = 0;
    a.arr_elem = null; a.arr_elem_count = 0;
    a.arr_neg_elem = null; a.arr_neg_elem_count = 0;
    a.opt_inner = null; a.opt_count = 0;
    a.opt_neg_inner = null; a.opt_neg_count = 0;
    a.has_bot = false; a.has_top = false; a.overflow = false;
}

fn bool append_i(int** arr, usz* count, int value)
{
    if (arr == null || count == null || *count >= SUB_MAX_ATOMS) return false;
    usz next_count = *count + 1;
    int* grown = (int*)realloc((void*)arr[0], (long)(next_count * int::size));
    if (grown == null) return false;
    grown[*count] = value;
    arr[0] = grown;
    *count = next_count;
    return true;
}

fn bool append_pair(int** left, int** right, usz* count, int lvalue, int rvalue)
{
    if (left == null || right == null || count == null || *count >= SUB_MAX_ATOMS) return false;
    usz next_count = *count + 1;
    int* grown_left = (int*)realloc((void*)left[0], (long)(next_count * int::size));
    if (grown_left == null) return false;
    left[0] = grown_left;
    int* grown_right = (int*)realloc((void*)right[0], (long)(next_count * int::size));
    if (grown_right == null) return false;
    right[0] = grown_right;
    left[0][*count] = lvalue;
    right[0][*count] = rvalue;
    *count = next_count;
    return true;
}

fn bool atomset_add(AtomSet* atoms, int** list, usz* count, int value)
{
    if (atoms.overflow) return false;
    if (!append_i(list, count, value)) { atoms.overflow = true; return false; }
    return true;
}

fn bool atomset_add_pair(AtomSet* atoms, int** left, int** right, usz* count,
                         int lvalue, int rvalue)
{
    if (atoms.overflow) return false;
    if (!append_pair(left, right, count, lvalue, rvalue))
    {
        atoms.overflow = true;
        return false;
    }
    return true;
}

fn void atomset_free(AtomSet* a)
{
    if (a.prim_pos != null) { free((void*)a.prim_pos); a.prim_pos = null; }
    if (a.prim_neg != null) { free((void*)a.prim_neg); a.prim_neg = null; }
    if (a.nom_pos != null) { free((void*)a.nom_pos); a.nom_pos = null; }
    if (a.nom_neg != null) { free((void*)a.nom_neg); a.nom_neg = null; }
    if (a.prod_l != null) { free((void*)a.prod_l); a.prod_l = null; }
    if (a.prod_r != null) { free((void*)a.prod_r); a.prod_r = null; }
    if (a.prod_neg_l != null) { free((void*)a.prod_neg_l); a.prod_neg_l = null; }
    if (a.prod_neg_r != null) { free((void*)a.prod_neg_r); a.prod_neg_r = null; }
    if (a.rec_ids != null) { free((void*)a.rec_ids); a.rec_ids = null; }
    if (a.rec_neg_ids != null) { free((void*)a.rec_neg_ids); a.rec_neg_ids = null; }
    if (a.arr_dom != null) { free((void*)a.arr_dom); a.arr_dom = null; }
    if (a.arr_cod != null) { free((void*)a.arr_cod); a.arr_cod = null; }
    if (a.arr_neg_dom != null) { free((void*)a.arr_neg_dom); a.arr_neg_dom = null; }
    if (a.arr_neg_cod != null) { free((void*)a.arr_neg_cod); a.arr_neg_cod = null; }
    if (a.arr_elem != null) { free((void*)a.arr_elem); a.arr_elem = null; }
    if (a.arr_neg_elem != null) { free((void*)a.arr_neg_elem); a.arr_neg_elem = null; }
    if (a.opt_inner != null) { free((void*)a.opt_inner); a.opt_inner = null; }
    if (a.opt_neg_inner != null) { free((void*)a.opt_neg_inner); a.opt_neg_inner = null; }
}

fn bool prim_disjoint(theory_setops::StNode* a, theory_setops::StNode* b)
{
    if (a.kind != St.ST_PRIM || b.kind != St.ST_PRIM) return false;
    return a.prim != b.prim;
}

fn bool nominal_equal(TypeStore* ts, int left, int right)
{
    if (left < 0 || right < 0 || (usz)left >= ts.node_count || (usz)right >= ts.node_count) return false;
    theory_setops::StNode* a = &ts.nodes[left];
    theory_setops::StNode* b = &ts.nodes[right];
    return a.kind == St.ST_NOMINAL && b.kind == St.ST_NOMINAL && a.name_id == b.name_id;
}

fn void collect_atoms(TypeStore* ts, int ty, AtomSet* atoms, bool positive, int depth)
{
    if (ts == null || atoms == null || ts.nodes == null || depth > SUB_MAX_DEPTH * 2
        || ty < 0 || (usz)ty >= ts.node_count)
    {
        if (atoms != null) atoms.overflow = true;
        return;
    }
    int[SUB_STACK_CAP] stack;
    bool[SUB_STACK_CAP] polarity;
    usz stack_count = 1;
    stack[0] = ty;
    polarity[0] = positive;
    while (stack_count > 0 && !atoms.overflow)
    {
        stack_count--;
        int current = stack[stack_count];
        bool current_positive = polarity[stack_count];
        if (current < 0 || (usz)current >= ts.node_count)
        {
            atoms.overflow = true;
            break;
        }
        theory_setops::StNode* node = &ts.nodes[current];
        if (node.kind == St.ST_BOTTOM)
        {
            atoms.has_bot = true;
            continue;
        }
        if (node.kind == St.ST_TOP)
        {
            if (current_positive) atoms.has_top = true;
            continue;
        }
        if ((node.kind == St.ST_INTER || node.kind == St.ST_UNION) && node.child_count >= 2)
        {
            if (stack_count + 2 > SUB_STACK_CAP)
            {
                atoms.overflow = true;
                break;
            }
            stack[stack_count] = node.children[0];
            polarity[stack_count] = current_positive;
            stack_count++;
            stack[stack_count] = node.children[1];
            polarity[stack_count] = current_positive;
            stack_count++;
            continue;
        }
        if (node.kind == St.ST_NEG && node.child_count >= 1)
        {
            if (stack_count >= SUB_STACK_CAP)
            {
                atoms.overflow = true;
                break;
            }
            stack[stack_count] = node.children[0];
            polarity[stack_count] = !current_positive;
            stack_count++;
            continue;
        }
        if (!current_positive)
        {
            switch (node.kind)
            {
                case St.ST_PRIM:
                    atomset_add(atoms, &atoms.prim_neg, &atoms.prim_neg_count, current);
                    break;
                case St.ST_NOMINAL:
                    atomset_add(atoms, &atoms.nom_neg, &atoms.nom_neg_count, current);
                    break;
                case St.ST_TUPLE:
                    if (node.child_count >= 2)
                    {
                        atomset_add_pair(atoms, &atoms.prod_neg_l, &atoms.prod_neg_r,
                                         &atoms.prod_neg_count, node.children[0], node.children[1]);
                    }
                    break;
                case St.ST_RECORD:
                    atomset_add(atoms, &atoms.rec_neg_ids, &atoms.rec_neg_count, current);
                    break;
                case St.ST_ARROW:
                    if (node.child_count >= 2)
                    {
                        atomset_add_pair(atoms, &atoms.arr_neg_dom, &atoms.arr_neg_cod,
                                         &atoms.arr_neg_count, node.children[0], node.children[1]);
                    }
                    break;
                case St.ST_ARRAY:
                    if (node.child_count >= 1)
                    {
                        atomset_add(atoms, &atoms.arr_neg_elem, &atoms.arr_neg_elem_count, node.children[0]);
                    }
                    break;
                case St.ST_OPTION:
                    if (node.child_count >= 1)
                    {
                        atomset_add(atoms, &atoms.opt_neg_inner, &atoms.opt_neg_count, node.children[0]);
                    }
                    break;
                default: break;
            }
            continue;
        }
        switch (node.kind)
        {
            case St.ST_PRIM:
                atomset_add(atoms, &atoms.prim_pos, &atoms.prim_pos_count, current);
                break;
            case St.ST_NOMINAL:
                atomset_add(atoms, &atoms.nom_pos, &atoms.nom_pos_count, current);
                break;
            case St.ST_TUPLE:
                if (node.child_count >= 2)
                {
                    atomset_add_pair(atoms, &atoms.prod_l, &atoms.prod_r, &atoms.prod_count,
                                     node.children[0], node.children[1]);
                }
                break;
            case St.ST_RECORD:
                atomset_add(atoms, &atoms.rec_ids, &atoms.rec_count, current);
                break;
            case St.ST_ARROW:
                if (node.child_count >= 2)
                {
                    atomset_add_pair(atoms, &atoms.arr_dom, &atoms.arr_cod, &atoms.arr_count,
                                     node.children[0], node.children[1]);
                }
                break;
            case St.ST_ARRAY:
                if (node.child_count >= 1)
                {
                    atomset_add(atoms, &atoms.arr_elem, &atoms.arr_elem_count, node.children[0]);
                }
                break;
            case St.ST_OPTION:
                if (node.child_count >= 1)
                {
                    atomset_add(atoms, &atoms.opt_inner, &atoms.opt_count, node.children[0]);
                }
                break;
            default: break;
        }
    }
}

fn bool valid_type_reference(TypeStore* ts, int child)
{
    return ts != null && child >= 0 && (usz)child < ts.node_count;
}

fn bool valid_type_node(TypeStore* ts, int type)
{
    if (ts == null || ts.nodes == null || type < 0 || (usz)type >= ts.node_count) return false;
    theory_setops::StNode* node = &ts.nodes[type];
    bool arity_ok = false;
    switch (node.kind)
    {
        case St.ST_BOTTOM: case St.ST_TOP: case St.ST_VAR:
            arity_ok = node.child_count == 0;
            break;
        case St.ST_PRIM:
            arity_ok = node.child_count == 0
                && (int)node.prim >= (int)PrimTag.PRIM_INT
                && (int)node.prim <= (int)PrimTag.PRIM_NEVER;
            break;
        case St.ST_NOMINAL:
            arity_ok = node.child_count == 0;
            break;
        case St.ST_UNION: case St.ST_INTER: case St.ST_TUPLE: case St.ST_ARROW:
            arity_ok = node.child_count == 2;
            break;
        case St.ST_NEG: case St.ST_ARRAY: case St.ST_OPTION: case St.ST_MU:
            arity_ok = node.child_count == 1;
            break;
        case St.ST_RECORD:
            arity_ok = node.child_count == 1
                && node.fe_idx >= 0 && (usz)node.fe_idx < ts.fentry_count;
            if (arity_ok)
            {
                theory_setops::StFieldEntry* entry = &ts.field_entries[node.fe_idx];
                if (entry.field_count > theory_setops::ST_MAX_RECORD_FIELDS
                    || (entry.field_count > 0 && entry.fields == null)) return false;
                for (usz i = 0; i < entry.field_count; i++)
                {
                    if (!valid_type_reference(ts, entry.fields[i].child)) return false;
                    if (i > 0 && entry.fields[i - 1].name_id >= entry.fields[i].name_id) return false;
                }
            }
            break;
        default:
            return false;
    }
    if (!arity_ok) return false;
    for (usz i = 0; i < node.child_count; i++)
    {
        if (!valid_type_reference(ts, node.children[i])) return false;
    }
    return true;
}

fn bool clause_needs_distribution(TypeStore* ts, int type, int depth)
{
    if (ts == null || ts.nodes == null || type < 0 || (usz)type >= ts.node_count || depth > SUB_MAX_DEPTH) return false;
    theory_setops::StNode* node = &ts.nodes[type];
    if (node.kind == St.ST_UNION) return true;
    if (node.kind == St.ST_INTER && node.child_count >= 2)
    {
        return clause_needs_distribution(ts, node.children[0], depth + 1)
            || clause_needs_distribution(ts, node.children[1], depth + 1);
    }
    if (node.kind == St.ST_NEG && node.child_count >= 1)
    {
        int child = node.children[0];
        if (child < 0 || (usz)child >= ts.node_count) return false;
        St child_kind = ts.nodes[child].kind;
        if (child_kind == St.ST_INTER || child_kind == St.ST_UNION) return true;
    }
    return false;
}

fn bool type_needs_distribution(TypeStore* ts, int type, int depth)
{
    if (ts == null || ts.nodes == null || type < 0 || (usz)type >= ts.node_count || depth > SUB_MAX_DEPTH) return false;
    theory_setops::StNode* node = &ts.nodes[type];
    if (node.kind == St.ST_UNION && node.child_count >= 2)
    {
        return type_needs_distribution(ts, node.children[0], depth + 1)
            || type_needs_distribution(ts, node.children[1], depth + 1);
    }
    return clause_needs_distribution(ts, type, depth + 1);
}

// The normalizer is invoked only when a union occurs inside a conjunction or
// a negation wraps a Boolean connective. Ordinary DNF clauses stay on the
// fast path; this prevents repeated rebuilding of equivalent `ST_INTER` nodes.

fn bool is_empty(TypeStore* ts, int ty, int depth)
{
    if (!valid_type_node(ts, ty)) return false;
    if (depth > SUB_MAX_DEPTH) return false;
    theory_setops::StNode* n = &ts.nodes[ty];
    if (n.kind == St.ST_BOTTOM) return true;
    if (n.kind == St.ST_TOP) return false;
    if (n.kind == St.ST_UNION && n.child_count >= 2)
    {
        bool l = is_empty(ts, n.children[0], depth + 1);
        bool r = is_empty(ts, n.children[1], depth + 1);
        return l && r;
    }
    if (type_needs_distribution(ts, ty, 0))
    {
        int normalized = theory_setops::st_dnf(ts, ty);
        if (normalized < 0 || (usz)normalized >= ts.node_count || normalized == ty) return false;
        return is_empty(ts, normalized, depth + 1);
    }
    if (n.kind == St.ST_INTER && n.child_count >= 2)
    {
        if (is_empty(ts, n.children[0], depth + 1)) return true;
        if (is_empty(ts, n.children[1], depth + 1)) return true;
    }
    if (n.kind == St.ST_NEG && n.child_count >= 1)
    {
        int child = n.children[0];
        if (child < 0 || (usz)child >= ts.node_count) return false;
        theory_setops::StNode* cn = &ts.nodes[child];
        if (cn.kind == St.ST_TOP) return true;
        if (cn.kind == St.ST_BOTTOM) return false;
    }

    AtomSet a;
    atomset_init(&a);
    collect_atoms(ts, ty, &a, true, depth);
    bool result = false;
    if (a.overflow)
    {
        atomset_free(&a);
        return false;
    }

    if (a.has_bot) { result = true; }

    // prim disjointness
    if (!result)
    {
        for (usz i = 0; i < a.prim_pos_count && !result; i++)
        {
            theory_setops::StNode* positive = &ts.nodes[a.prim_pos[i]];
            if (positive.kind == St.ST_PRIM && positive.prim == PrimTag.PRIM_NEVER)
            {
                result = true;
                break;
            }
            for (usz j = i + 1; j < a.prim_pos_count; j++)
            {
                if (prim_disjoint(&ts.nodes[a.prim_pos[i]], &ts.nodes[a.prim_pos[j]])) { result = true; break; }
            }
            for (usz j = 0; j < a.prim_neg_count && !result; j++)
            {
                theory_setops::StNode* pi = &ts.nodes[a.prim_pos[i]];
                theory_setops::StNode* pj = &ts.nodes[a.prim_neg[j]];
                if (pi.kind == St.ST_PRIM && pj.kind == St.ST_PRIM && pi.prim == pj.prim) result = true;
            }
        }
    }

    // nominals
    if (!result && a.nom_pos_count > 1)
    {
        for (usz i = 1; i < a.nom_pos_count; i++)
        {
            // Fresh TypeStore nodes can denote the same nominal by name.
            if (!nominal_equal(ts, a.nom_pos[0], a.nom_pos[i])) { result = true; break; }
        }
    }
    if (!result)
    {
        for (usz i = 0; i < a.nom_pos_count && !result; i++)
        {
            for (usz j = 0; j < a.nom_neg_count; j++)
            {
                if (nominal_equal(ts, a.nom_pos[i], a.nom_neg[j])) { result = true; break; }
            }
        }
    }

    // products
    if (!result && a.prod_count > 0)
    {
        int li = ts.top_idx; int ri = ts.top_idx;
        for (usz i = 0; i < a.prod_count; i++)
        { li = ts.my_inter(li, a.prod_l[i]); ri = ts.my_inter(ri, a.prod_r[i]); }
        int ld = theory_setops::st_dnf(ts, li); int rd = theory_setops::st_dnf(ts, ri);
        if (is_empty(ts, ld, depth + 1) || is_empty(ts, rd, depth + 1)) result = true;
        // A positive product conjunction is contained in a negative product
        // atom only when both coordinate projections are contained.
        for (usz j = 0; j < a.prod_neg_count && !result; j++)
        {
            int left_diff = theory_setops::st_dnf(ts, ts.my_inter(li, ts.neg(a.prod_neg_l[j])));
            int right_diff = theory_setops::st_dnf(ts, ts.my_inter(ri, ts.neg(a.prod_neg_r[j])));
            if (is_empty(ts, left_diff, depth + 1) && is_empty(ts, right_diff, depth + 1)) result = true;
        }
    }

    // Records are width-subtyped structural maps. Intersecting positive
    // rows intersects the payload constraints for every required label;
    // a bottom payload makes the whole record conjunction uninhabited.
    if (!result && a.rec_count > 0)
    {
        for (usz i = 0; i < a.rec_count && !result; i++)
        {
            theory_setops::StNode* row = &ts.nodes[a.rec_ids[i]];
            if (row.fe_idx < 0 || (usz)row.fe_idx >= ts.fentry_count) continue;
            theory_setops::StFieldEntry* fields = &ts.field_entries[row.fe_idx];
            if (fields.field_count > 0 && fields.fields == null) continue;
            for (usz f = 0; f < fields.field_count && !result; f++)
            {
                int payload = ts.top_idx;
                for (usz r = 0; r < a.rec_count; r++)
                {
                    theory_setops::StNode* other = &ts.nodes[a.rec_ids[r]];
                    if (other.fe_idx < 0 || (usz)other.fe_idx >= ts.fentry_count) continue;
                    theory_setops::StFieldEntry* other_fields = &ts.field_entries[other.fe_idx];
                    if (other_fields.field_count > 0 && other_fields.fields == null) continue;
                    for (usz g = 0; g < other_fields.field_count; g++)
                    {
                        if (other_fields.fields[g].name_id == fields.fields[f].name_id)
                        {
                            payload = ts.my_inter(payload, other_fields.fields[g].child);
                        }
                    }
                }
                int payload_dnf = theory_setops::st_dnf(ts, payload);
                if (is_empty(ts, payload_dnf, depth + 1)) result = true;
            }
        }
    }
    // A positive row intersected with the complement of a negative row is
    // empty when the positive row is a width/depth subtype of that row.
    if (!result && a.rec_count > 0 && a.rec_neg_count > 0)
    {
        for (usz neg_i = 0; neg_i < a.rec_neg_count && !result; neg_i++)
        {
            theory_setops::StNode* target = &ts.nodes[a.rec_neg_ids[neg_i]];
            if (target.fe_idx < 0 || (usz)target.fe_idx >= ts.fentry_count) continue;
            theory_setops::StFieldEntry* target_fields = &ts.field_entries[target.fe_idx];
            if (target_fields.field_count > 0 && target_fields.fields == null) continue;
            for (usz pos_i = 0; pos_i < a.rec_count && !result; pos_i++)
            {
                theory_setops::StNode* source = &ts.nodes[a.rec_ids[pos_i]];
                if (source.fe_idx < 0 || (usz)source.fe_idx >= ts.fentry_count) continue;
                theory_setops::StFieldEntry* source_fields = &ts.field_entries[source.fe_idx];
                if (source_fields.field_count > 0 && source_fields.fields == null) continue;
                bool covered = true;
                for (usz target_i = 0; target_i < target_fields.field_count && covered; target_i++)
                {
                    int source_payload = -1;
                    for (usz source_i = 0; source_i < source_fields.field_count; source_i++)
                    {
                        if (source_fields.fields[source_i].name_id == target_fields.fields[target_i].name_id)
                        {
                            source_payload = source_fields.fields[source_i].child;
                        }
                    }
                    if (source_payload < 0) { covered = false; break; }
                    int diff = ts.my_inter(source_payload, ts.neg(target_fields.fields[target_i].child));
                    int diff_dnf = theory_setops::st_dnf(ts, diff);
                    if (!is_empty(ts, diff_dnf, depth + 1)) covered = false;
                }
                if (covered) result = true;
            }
        }
    }

    // arrows
    if (!result && a.arr_count > 0)
    {
        int ci = ts.top_idx; int di = ts.top_idx;
        for (usz i = 0; i < a.arr_count; i++)
        { ci = ts.my_inter(ci, a.arr_cod[i]); di = ts.my_inter(di, a.arr_dom[i]); }
        int cid = theory_setops::st_dnf(ts, ci); int did = theory_setops::st_dnf(ts, di);
        if (is_empty(ts, cid, depth + 1) || is_empty(ts, did, depth + 1))
        {
            result = true;
        }
        else
        {
            for (usz i = 0; i < a.arr_count && !result; i++)
            {
                for (usz j = 0; j < a.arr_neg_count; j++)
                {
                    int pd = a.arr_dom[i]; int pc = a.arr_cod[i];
                    int nd = a.arr_neg_dom[j]; int nc = a.arr_neg_cod[j];
                    int diffd = ts.my_inter(nd, ts.neg(pd));
                    int ddn = theory_setops::st_dnf(ts, diffd);
                    bool dom_ok = is_empty(ts, ddn, depth + 1);
                    if (!dom_ok) continue;
                    int diffc = ts.my_inter(pc, ts.neg(nc));
                    int dcn = theory_setops::st_dnf(ts, diffc);
                    bool cod_ok = is_empty(ts, dcn, depth + 1);
                    if (cod_ok) { result = true; break; }
                }
            }
        }
    }

    // Arrays use the element-intersection model used by this type store.
    // A negative array atom excludes the positive array conjunction when its
    // element constraint is a semantic supertype of the positive element.
    if (!result && a.arr_elem_count > 0)
    {
        int elements = ts.top_idx;
        for (usz i = 0; i < a.arr_elem_count; i++) elements = ts.my_inter(elements, a.arr_elem[i]);
        int element_dnf = theory_setops::st_dnf(ts, elements);
        if (is_empty(ts, element_dnf, depth + 1)) result = true;
        for (usz i = 0; i < a.arr_neg_elem_count && !result; i++)
        {
            int difference = ts.my_inter(elements, ts.neg(a.arr_neg_elem[i]));
            int difference_dnf = theory_setops::st_dnf(ts, difference);
            if (is_empty(ts, difference_dnf, depth + 1)) result = true;
        }
    }

    // Options have a shared `none` inhabitant. Intersections of positive
    // option atoms therefore remain inhabited, while a positive option row
    // is contained in a negative option atom when its payload is contained.
    if (!result && a.opt_count > 0 && a.opt_neg_count > 0)
    {
        int payload = ts.top_idx;
        for (usz i = 0; i < a.opt_count; i++) payload = ts.my_inter(payload, a.opt_inner[i]);
        for (usz i = 0; i < a.opt_neg_count && !result; i++)
        {
            int difference = ts.my_inter(payload, ts.neg(a.opt_neg_inner[i]));
            int difference_dnf = theory_setops::st_dnf(ts, difference);
            if (is_empty(ts, difference_dnf, depth + 1)) result = true;
        }
    }

    atomset_free(&a);
    return result;
}

// ── AST → TypeStore translation ────────────────────────────────────────
fn int translate_type(TypeStore* ts, Node* t, int depth)
{
    if (t == null || depth > SUB_MAX_DEPTH) return ts.top_idx;
    switch (t.kind)
    {
        case Nk.N_TY_BOTTOM: return ts.bot_idx;
        case Nk.N_TY_INFER: case Nk.N_TY_SELF: return ts.top_idx;
        case Nk.N_TY_UNIT: return ts.mk_prim(PrimTag.PRIM_UNIT);
        case Nk.N_TY_NAME: case Nk.N_TY_PATH:
        {
            char* s = t.p.sptr; usz n = t.p.slen;
            if (s != null && n > 0)
            {
                if (n == 3 && s[0] == 'i' && s[1] == 'n' && s[2] == 't') return ts.mk_prim(PrimTag.PRIM_INT);
                if (n == 4 && s[0] == 'b' && s[1] == 'o' && s[2] == 'o' && s[3] == 'l') return ts.mk_prim(PrimTag.PRIM_BOOL);
                if (n >= 5 && s[0] == 'f' && s[1] == 'l' && s[2] == 'o') return ts.mk_prim(PrimTag.PRIM_FLOAT);
                if (n == 4 && s[0] == 'c' && s[1] == 'h' && s[2] == 'a' && s[3] == 'r') return ts.mk_prim(PrimTag.PRIM_CHAR);
                if (n >= 3 && s[0] == 's' && s[1] == 't' && s[2] == 'r') return ts.mk_prim(PrimTag.PRIM_STRING);
                if ((s[0] == 'i' || s[0] == 'u') && n >= 2 && s[1] >= '0' && s[1] <= '9') return ts.mk_prim(PrimTag.PRIM_INT);
                if (s[0] == 'f' && n >= 2 && s[1] >= '0' && s[1] <= '9') return ts.mk_prim(PrimTag.PRIM_FLOAT);
            }
            return ts.mk_nominal(t.name_id);
        }
        case Nk.N_TY_PTR: case Nk.N_TY_REF:
            return ts.mk_nominal(t.kind == Nk.N_TY_PTR ? 0x70000001u : 0x70000002u);
        case Nk.N_TY_ARRAY: case Nk.N_TY_SLICE:
            if (t.child_count >= 1) return ts.mk_array(translate_type(ts, t.children[0], depth + 1));
            return ts.mk_array(ts.top_idx);
        case Nk.N_TY_TUPLE:
        {
            int cur = ts.top_idx;
            for (usz i = 0; i < t.child_count; i++)
            {
                int c = translate_type(ts, t.children[i], depth + 1);
                cur = i == 0 ? c : ts.mk_binary(St.ST_TUPLE, cur, c);
            }
            return cur;
        }
        case Nk.N_TY_FN:
        {
            if (t.child_count == 0) return ts.mk_arrow(ts.top_idx, ts.top_idx);
            int ret = translate_type(ts, t.children[t.child_count - 1], depth + 1);
            if (t.child_count == 1) return ts.mk_arrow(ts.top_idx, ret);
            int args = ts.top_idx;
            for (usz i = 0; i + 1 < t.child_count; i++)
            {
                int aa = translate_type(ts, t.children[i], depth + 1);
                args = i == 0 ? aa : ts.mk_binary(St.ST_TUPLE, args, aa);
            }
            return ts.mk_arrow(args, ret);
        }
        case Nk.N_TY_UNION:
        {
            int r = ts.bot_idx;
            for (usz i = 0; i < t.child_count; i++) r = ts.my_union(r, translate_type(ts, t.children[i], depth + 1));
            return r;
        }
        case Nk.N_TY_INTERSECT:
        {
            int r = ts.top_idx;
            for (usz i = 0; i < t.child_count; i++) r = ts.my_inter(r, translate_type(ts, t.children[i], depth + 1));
            return r;
        }
        case Nk.N_TY_NEGATION:
            if (t.child_count >= 1) return ts.neg(translate_type(ts, t.children[0], depth + 1));
            return ts.top_idx;
        default: return ts.top_idx;
    }
}

// ── Public API ──────────────────────────────────────────────────────────
fn bool semantic_subtype(TypeStore* ts, int a, int b)
{
    int diff = ts.my_inter(a, ts.neg(b));
    int d = theory_setops::st_dnf(ts, diff);
    return is_empty(ts, d, 0);
}

// ── Algebra-law audit used by the record/type pipeline ──────────────────
// Each assertion asks the same public emptiness path used by clients. The
// audit deliberately spans atom, product, function, sequence, option, row,
// Boolean and malformed-input cases rather than checking only reflexivity.
struct SubtypeAudit
{
    usz checks;
    usz failures;
    usz subtype_checks;
    usz emptiness_checks;
    usz algebra_checks;
    usz skipped_checks;
    bool invalid_store;
}

fn void SubtypeAudit.init(SubtypeAudit* audit)
{
    audit.checks = 0;
    audit.failures = 0;
    audit.subtype_checks = 0;
    audit.emptiness_checks = 0;
    audit.algebra_checks = 0;
    audit.skipped_checks = 0;
    audit.invalid_store = false;
}

fn void SubtypeAudit.expect(SubtypeAudit* audit, bool actual, bool expected)
{
    audit.checks++;
    if (actual != expected) audit.failures++;
}

fn void audit_expect_subtype(TypeStore* ts, SubtypeAudit* audit,
                             int source, int target, bool expected)
{
    audit.subtype_checks++;
    audit.expect(semantic_subtype(ts, source, target), expected);
}

fn void audit_expect_empty(TypeStore* ts, SubtypeAudit* audit, int ty, bool expected)
{
    audit.emptiness_checks++;
    audit.expect(is_empty(ts, ty, 0), expected);
}

fn void audit_expect_equivalent(TypeStore* ts, SubtypeAudit* audit, int left, int right)
{
    audit.algebra_checks++;
    audit_expect_subtype(ts, audit, left, right, true);
    audit_expect_subtype(ts, audit, right, left, true);
}

fn void audit_record_width_depth(TypeStore* ts, SubtypeAudit* audit)
{
    if (ts.node_count + 24 >= ts.node_cap || ts.fentry_count + 8 >= ts.fentry_cap)
    {
        audit.skipped_checks++;
        return;
    }
    theory_setops::Field[2] narrow_fields;
    narrow_fields[0].name_id = 0x6a01u;
    narrow_fields[0].child = ts.mk_prim(PrimTag.PRIM_INT);
    theory_setops::Field[2] wide_fields;
    wide_fields[0] = narrow_fields[0];
    wide_fields[1].name_id = 0x6a02u;
    wide_fields[1].child = ts.mk_prim(PrimTag.PRIM_BOOL);
    theory_setops::Field[1] wrong_fields;
    wrong_fields[0].name_id = narrow_fields[0].name_id;
    wrong_fields[0].child = ts.mk_prim(PrimTag.PRIM_BOOL);
    int narrow = ts.mk_record(&narrow_fields[0], 1, ts.bot_idx);
    int wide = ts.mk_record(&wide_fields[0], 2, ts.bot_idx);
    int wrong = ts.mk_record(&wrong_fields[0], 1, ts.bot_idx);
    if (narrow == ts.bot_idx || wide == ts.bot_idx || wrong == ts.bot_idx)
    {
        audit.skipped_checks++;
        return;
    }
    audit_expect_subtype(ts, audit, wide, narrow, true);
    audit_expect_subtype(ts, audit, narrow, wide, false);
    audit_expect_subtype(ts, audit, wrong, narrow, false);
    audit_expect_empty(ts, audit, ts.my_inter(wide, wrong), true);
    audit_expect_empty(ts, audit, ts.my_inter(wide, narrow), false);
}

fn void audit_product_laws(TypeStore* ts, SubtypeAudit* audit,
                           int int_ty, int bool_ty, int wide_ty)
{
    int left_pair = ts.mk_binary(St.ST_TUPLE, int_ty, bool_ty);
    int left_pair_copy = ts.mk_binary(St.ST_TUPLE, int_ty, bool_ty);
    int bad_target = ts.mk_binary(St.ST_TUPLE, int_ty, int_ty);
    int wide_target = ts.mk_binary(St.ST_TUPLE, wide_ty, wide_ty);
    audit_expect_subtype(ts, audit, left_pair, left_pair_copy, true);
    audit_expect_subtype(ts, audit, left_pair, bad_target, false);
    audit_expect_subtype(ts, audit, left_pair, wide_target, true);
    audit_expect_empty(ts, audit, ts.my_inter(left_pair, ts.neg(left_pair_copy)), true);
    audit_expect_empty(ts, audit, ts.my_inter(left_pair, ts.neg(bad_target)), false);
}

fn void audit_array_option_laws(TypeStore* ts, SubtypeAudit* audit,
                                int int_ty, int bool_ty, int wide_ty)
{
    int int_array = ts.mk_array(int_ty);
    int int_array_copy = ts.mk_array(int_ty);
    int wide_array = ts.mk_array(wide_ty);
    int bool_array = ts.mk_array(bool_ty);
    audit_expect_subtype(ts, audit, int_array, int_array_copy, true);
    audit_expect_subtype(ts, audit, int_array, wide_array, true);
    audit_expect_subtype(ts, audit, int_array, bool_array, false);
    audit_expect_empty(ts, audit, ts.my_inter(int_array, ts.neg(int_array_copy)), true);
    audit_expect_empty(ts, audit, ts.my_inter(int_array, ts.neg(bool_array)), false);

    int int_option = ts.mk_option(int_ty);
    int int_option_copy = ts.mk_option(int_ty);
    int wide_option = ts.mk_option(wide_ty);
    int bool_option = ts.mk_option(bool_ty);
    audit_expect_subtype(ts, audit, int_option, int_option_copy, true);
    audit_expect_subtype(ts, audit, int_option, wide_option, true);
    audit_expect_subtype(ts, audit, int_option, bool_option, false);
    audit_expect_empty(ts, audit, ts.my_inter(int_option, ts.neg(int_option_copy)), true);
    audit_expect_empty(ts, audit, ts.my_inter(int_option, ts.neg(bool_option)), false);
}

fn void audit_arrow_laws(TypeStore* ts, SubtypeAudit* audit,
                         int int_ty, int wide_ty)
{
    int int_arrow = ts.mk_arrow(int_ty, int_ty);
    int wide_domain = ts.mk_arrow(wide_ty, int_ty);
    int wider_codomain = ts.mk_arrow(int_ty, wide_ty);
    audit_expect_subtype(ts, audit, wide_domain, int_arrow, true);
    audit_expect_subtype(ts, audit, int_arrow, wide_domain, false);
    audit_expect_subtype(ts, audit, int_arrow, wider_codomain, true);
    audit_expect_subtype(ts, audit, wider_codomain, int_arrow, false);
    audit_expect_empty(ts, audit, ts.my_inter(int_arrow, ts.neg(wide_domain)), false);
    audit_expect_empty(ts, audit, ts.my_inter(int_arrow, ts.neg(int_arrow)), true);
}

fn void audit_boolean_laws(TypeStore* ts, SubtypeAudit* audit,
                           int int_ty, int bool_ty, int float_ty)
{
    int[3] prims;
    prims[0] = int_ty; prims[1] = bool_ty; prims[2] = float_ty;
    for (usz i = 0; i < 3; i++)
    {
        audit_expect_subtype(ts, audit, prims[i], prims[i], true);
        audit_expect_subtype(ts, audit, ts.bot_idx, prims[i], true);
        audit_expect_subtype(ts, audit, prims[i], ts.top_idx, true);
        audit_expect_empty(ts, audit, ts.my_inter(prims[i], ts.neg(prims[i])), true);
        int double_negation = ts.neg(ts.neg(prims[i]));
        audit_expect_equivalent(ts, audit, prims[i], double_negation);
        for (usz j = 0; j < 3; j++)
        {
            int joined = ts.my_union(prims[i], prims[j]);
            audit_expect_subtype(ts, audit, prims[i], joined, true);
            audit_expect_empty(ts, audit, ts.my_inter(prims[i], prims[j]), i != j);
            audit_expect_empty(ts, audit, ts.my_inter(prims[i], ts.neg(prims[j])), i == j);
        }
    }
    int left = ts.my_inter(ts.my_union(int_ty, bool_ty), float_ty);
    int right = ts.my_union(ts.my_inter(int_ty, float_ty), ts.my_inter(bool_ty, float_ty));
    audit_expect_equivalent(ts, audit, left, right);
    int neg_union = ts.neg(ts.my_union(int_ty, bool_ty));
    int union_neg = ts.my_inter(ts.neg(int_ty), ts.neg(bool_ty));
    audit_expect_equivalent(ts, audit, neg_union, union_neg);
    // An unexpanded union inside a conjunction must be distributed before
    // atom collection; this catches the nested-DNF false-empty regression.
    int nested = ts.my_inter(ts.my_union(int_ty, bool_ty), int_ty);
    audit_expect_empty(ts, audit, nested, false);
    audit_expect_subtype(ts, audit, nested, int_ty, true);
}

fn void audit_nominal_laws(TypeStore* ts, SubtypeAudit* audit)
{
    int same_a = ts.mk_nominal(0x6b01u);
    int same_b = ts.mk_nominal(0x6b01u);
    int other = ts.mk_nominal(0x6b02u);
    audit_expect_subtype(ts, audit, same_a, same_b, true);
    audit_expect_subtype(ts, audit, same_b, same_a, true);
    audit_expect_subtype(ts, audit, same_a, other, false);
    audit_expect_empty(ts, audit, ts.my_inter(same_a, other), true);
    audit_expect_empty(ts, audit, ts.my_inter(same_a, ts.neg(same_b)), true);
}

fn bool audit_basis_subtype(usz source, usz target)
{
    if (source == 0) return target == 0 || target == 3;
    if (source == 1) return target == 1 || target == 3;
    if (source == 2) return target == 2;
    if (source == 3) return target == 3;
    return false;
}

fn void audit_primitive_lattice(TypeStore* ts, SubtypeAudit* audit)
{
    PrimTag[7] tags;
    tags[0] = PrimTag.PRIM_INT;
    tags[1] = PrimTag.PRIM_FLOAT;
    tags[2] = PrimTag.PRIM_BOOL;
    tags[3] = PrimTag.PRIM_CHAR;
    tags[4] = PrimTag.PRIM_STRING;
    tags[5] = PrimTag.PRIM_UNIT;
    tags[6] = PrimTag.PRIM_NEVER;
    int[7] atoms;
    for (usz i = 0; i < 7; i++) atoms[i] = ts.mk_prim(tags[i]);
    for (usz i = 0; i < 7; i++)
    {
        bool source_empty = i == 6;
        audit_expect_empty(ts, audit, atoms[i], source_empty);
        for (usz j = 0; j < 7; j++)
        {
            bool expected_subtype = i == 6 || i == j;
            bool expected_empty = i == 6 || j == 6 || i != j;
            audit_expect_subtype(ts, audit, atoms[i], atoms[j], expected_subtype);
            audit_expect_empty(ts, audit, ts.my_inter(atoms[i], atoms[j]), expected_empty);
        }
    }
    int never_complement = ts.neg(atoms[6]);
    audit_expect_equivalent(ts, audit, ts.top_idx, never_complement);
}

fn void audit_constructor_variance(TypeStore* ts, SubtypeAudit* audit,
                                  int int_ty, int bool_ty, int float_ty)
{
    int[4] basis;
    basis[0] = int_ty;
    basis[1] = bool_ty;
    basis[2] = float_ty;
    basis[3] = ts.my_union(int_ty, bool_ty);
    for (usz source = 0; source < 4; source++)
    {
        for (usz target = 0; target < 4; target++)
        {
            bool expected = audit_basis_subtype(source, target);
            int source_array = ts.mk_array(basis[source]);
            int target_array = ts.mk_array(basis[target]);
            int source_option = ts.mk_option(basis[source]);
            int target_option = ts.mk_option(basis[target]);
            int source_tuple = ts.mk_binary(St.ST_TUPLE, basis[source], int_ty);
            int target_tuple = ts.mk_binary(St.ST_TUPLE, basis[target], int_ty);
            audit_expect_subtype(ts, audit, source_array, target_array, expected);
            audit_expect_subtype(ts, audit, source_option, target_option, expected);
            audit_expect_subtype(ts, audit, source_tuple, target_tuple, expected);

            // Function domains are contravariant, while codomains are
            // covariant. Each expected answer is computed from the already
            // tested primitive/union basis relation, not from arrow nodes.
            int source_domain_arrow = ts.mk_arrow(basis[target], int_ty);
            int target_domain_arrow = ts.mk_arrow(basis[source], int_ty);
            int source_codomain_arrow = ts.mk_arrow(int_ty, basis[source]);
            int target_codomain_arrow = ts.mk_arrow(int_ty, basis[target]);
            audit_expect_subtype(ts, audit, source_domain_arrow, target_domain_arrow,
                                 audit_basis_subtype(source, target));
            audit_expect_subtype(ts, audit, source_codomain_arrow, target_codomain_arrow, expected);
        }
    }
}

fn void audit_distribution_matrix(TypeStore* ts, SubtypeAudit* audit,
                                  int int_ty, int bool_ty, int float_ty)
{
    int[3] atoms;
    atoms[0] = int_ty;
    atoms[1] = bool_ty;
    atoms[2] = float_ty;
    for (usz left = 0; left < 3; left++)
    {
        for (usz right = 0; right < 3; right++)
        {
            for (usz factor = 0; factor < 3; factor++)
            {
                int distributed_left = ts.my_inter(ts.my_union(atoms[left], atoms[right]), atoms[factor]);
                int distributed_right = ts.my_union(ts.my_inter(atoms[left], atoms[factor]),
                                                    ts.my_inter(atoms[right], atoms[factor]));
                audit_expect_equivalent(ts, audit, distributed_left, distributed_right);
                int demorgan_left = ts.neg(ts.my_union(atoms[left], atoms[right]));
                int demorgan_right = ts.my_inter(ts.neg(atoms[left]), ts.neg(atoms[right]));
                audit_expect_equivalent(ts, audit, demorgan_left, demorgan_right);
            }
        }
    }
}

fn bool verify_semantic_laws(TypeStore* ts, SubtypeAudit* audit)
{
    audit.init();
    if (ts == null || ts.nodes == null || ts.node_count < 2
        || ts.top_idx < 0 || ts.bot_idx < 0
        || (usz)ts.top_idx >= ts.node_count || (usz)ts.bot_idx >= ts.node_count)
    {
        audit.invalid_store = true;
        audit.failures = 1;
        return false;
    }
    if (ts.node_count + SUB_AUDIT_LIMIT >= ts.node_cap)
    {
        audit.skipped_checks++;
        return true;
    }
    int int_ty = ts.mk_prim(PrimTag.PRIM_INT);
    int bool_ty = ts.mk_prim(PrimTag.PRIM_BOOL);
    int float_ty = ts.mk_prim(PrimTag.PRIM_FLOAT);
    int wide_ty = ts.my_union(int_ty, bool_ty);
    audit_boolean_laws(ts, audit, int_ty, bool_ty, float_ty);
    audit_primitive_lattice(ts, audit);
    audit_constructor_variance(ts, audit, int_ty, bool_ty, float_ty);
    audit_distribution_matrix(ts, audit, int_ty, bool_ty, float_ty);
    audit_nominal_laws(ts, audit);
    audit_product_laws(ts, audit, int_ty, bool_ty, wide_ty);
    audit_array_option_laws(ts, audit, int_ty, bool_ty, wide_ty);
    audit_arrow_laws(ts, audit, int_ty, wide_ty);
    audit_record_width_depth(ts, audit);
    // Invalid references and exhausted recursion budget must be inconclusive,
    // never a proof of emptiness or subtyping.
    audit.expect(is_empty(ts, -1, 0), false);
    audit.expect(is_empty(ts, (int)ts.node_count + 10, 0), false);
    audit.expect(is_empty(ts, int_ty, SUB_MAX_DEPTH + 1), false);
    return audit.failures == 0 && !audit.invalid_store;
}
