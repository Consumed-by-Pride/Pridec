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
// The algorithm is written in CPS/recursive style using a single recursive
// function `is_empty`, so C3's "no forward declarations" rule is satisfied
// by ordering helper definitions BEFORE the main emptiness test (they do
// not themselves call back into is_empty — they receive pre-normalised
// child types and recurse via sem_sub which is defined below is_empty but
// never called before is_empty is defined).
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
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const int SUB_MAX_DEPTH = 60;

// ── Atom collection per kind ─────────────────────────────────────────────
struct AtomSet
{
    int*     prim_pos; int* prim_neg; usz prim_pos_count; usz prim_neg_count;
    int*     nom_pos;  int* nom_neg;  usz nom_pos_count;  usz nom_neg_count;
    int*     prod_l;   int* prod_r;   usz prod_count;
    int*     rec_ids;  usz  rec_count;
    int*     rec_neg_ids; usz rec_neg_count;
    int*     arr_dom;  int* arr_cod;  usz arr_count;
    int*     arr_neg_dom; int* arr_neg_cod; usz arr_neg_count;
    int*     arr_elem; usz  arr_elem_count;
    int*     opt_inner; usz opt_count;
    bool     has_bot;  bool has_top;
}

fn void atomset_init(AtomSet* a)
{
    a.prim_pos = null; a.prim_neg = null; a.prim_pos_count = 0; a.prim_neg_count = 0;
    a.nom_pos = null; a.nom_neg = null; a.nom_pos_count = 0; a.nom_neg_count = 0;
    a.prod_l = null; a.prod_r = null; a.prod_count = 0;
    a.rec_ids = null; a.rec_count = 0;
    a.rec_neg_ids = null; a.rec_neg_count = 0;
    a.arr_dom = null; a.arr_cod = null; a.arr_count = 0;
    a.arr_neg_dom = null; a.arr_neg_cod = null; a.arr_neg_count = 0;
    a.arr_elem = null; a.arr_elem_count = 0;
    a.opt_inner = null; a.opt_count = 0;
    a.has_bot = false; a.has_top = false;
}

fn void append_i(int** arr, usz* cnt, int v)
{
    int* old = arr[0]; usz c = *cnt;
    int* bigger = (int*)malloc((long)((c + 16) * 4));
    if (bigger == null) return;
    for (usz i = 0; i < c; i++) bigger[i] = old != null ? old[i] : 0;
    bigger[c] = v;
    if (old != null) free((void*)old);
    arr[0] = bigger; *cnt = c + 1;
}

fn void append_pair(int** la, usz* lc, int** ra, int lv, int rv)
{
    append_i(la, lc, lv);
    usz c = *lc;
    int* bigger = (int*)malloc((long)((c + 16) * 4));
    if (bigger == null) return;
    int* old = ra[0];
    for (usz i = 0; i < c - 1; i++) bigger[i] = old != null ? old[i] : 0;
    bigger[c - 1] = rv;
    if (old != null) free((void*)old);
    ra[0] = bigger;
}

fn void atomset_free(AtomSet* a)
{
    if (a.prim_pos != null) { free((void*)a.prim_pos); a.prim_pos = null; }
    if (a.prim_neg != null) { free((void*)a.prim_neg); a.prim_neg = null; }
    if (a.nom_pos != null) { free((void*)a.nom_pos); a.nom_pos = null; }
    if (a.nom_neg != null) { free((void*)a.nom_neg); a.nom_neg = null; }
    if (a.prod_l != null) { free((void*)a.prod_l); a.prod_l = null; }
    if (a.prod_r != null) { free((void*)a.prod_r); a.prod_r = null; }
    if (a.rec_ids != null) { free((void*)a.rec_ids); a.rec_ids = null; }
    if (a.rec_neg_ids != null) { free((void*)a.rec_neg_ids); a.rec_neg_ids = null; }
    if (a.arr_dom != null) { free((void*)a.arr_dom); a.arr_dom = null; }
    if (a.arr_cod != null) { free((void*)a.arr_cod); a.arr_cod = null; }
    if (a.arr_neg_dom != null) { free((void*)a.arr_neg_dom); a.arr_neg_dom = null; }
    if (a.arr_neg_cod != null) { free((void*)a.arr_neg_cod); a.arr_neg_cod = null; }
    if (a.arr_elem != null) { free((void*)a.arr_elem); a.arr_elem = null; }
    if (a.opt_inner != null) { free((void*)a.opt_inner); a.opt_inner = null; }
}

fn bool prim_disjoint(theory_setops::StNode* a, theory_setops::StNode* b)
{
    if (a.kind != St.ST_PRIM || b.kind != St.ST_PRIM) return false;
    return a.prim != b.prim;
}

fn void collect_atoms(TypeStore* ts, int ty, AtomSet* a, bool pos, int depth)
{
    if (depth > SUB_MAX_DEPTH * 2) return;
    int[128] stack; bool[128] pol; int sp = 0;
    stack[0] = ty; pol[0] = pos; sp = 1;
    while (sp > 0)
    {
        sp = sp - 1;
        int t = stack[sp]; bool p = pol[sp];
        if (t < 0) continue;
        theory_setops::StNode* nn = &ts.nodes[t];
        if (nn.kind == St.ST_BOTTOM) { a.has_bot = true; continue; }
        if (nn.kind == St.ST_TOP) { if (p) a.has_top = true; continue; }
        if (nn.kind == St.ST_INTER && nn.child_count >= 2)
        {
            if (sp < 126) { stack[sp] = nn.children[0]; pol[sp] = p; sp = sp + 1; }
            if (sp < 126) { stack[sp] = nn.children[1]; pol[sp] = p; sp = sp + 1; }
            continue;
        }
        if (nn.kind == St.ST_UNION && nn.child_count >= 2)
        {
            if (sp < 126) { stack[sp] = nn.children[0]; pol[sp] = p; sp = sp + 1; }
            if (sp < 126) { stack[sp] = nn.children[1]; pol[sp] = p; sp = sp + 1; }
            continue;
        }
        if (nn.kind == St.ST_NEG && nn.child_count >= 1)
        {
            if (sp < 127) { stack[sp] = nn.children[0]; pol[sp] = !p; sp = sp + 1; }
            continue;
        }
        if (!p)
        {
            switch (nn.kind)
            {
                case St.ST_PRIM:    append_i(&a.prim_neg, &a.prim_neg_count, t); break;
                case St.ST_NOMINAL: append_i(&a.nom_neg, &a.nom_neg_count, t); break;
                case St.ST_ARROW:
                    if (nn.child_count >= 2)
                    {
                        append_pair(&a.arr_neg_dom, &a.arr_neg_count, &a.arr_neg_cod,
                                    nn.children[0], nn.children[1]);
                    }
                    break;
                case St.ST_RECORD: append_i(&a.rec_neg_ids, &a.rec_neg_count, t); break;
                default: break;
            }
            continue;
        }
        switch (nn.kind)
        {
            case St.ST_PRIM:    append_i(&a.prim_pos, &a.prim_pos_count, t); break;
            case St.ST_NOMINAL: append_i(&a.nom_pos, &a.nom_pos_count, t); break;
            case St.ST_TUPLE:
                if (nn.child_count >= 2)
                {
                    append_pair(&a.prod_l, &a.prod_count, &a.prod_r,
                                nn.children[0], nn.children[1]);
                }
                break;
            case St.ST_RECORD:  append_i(&a.rec_ids, &a.rec_count, t); break;
            case St.ST_ARROW:
                if (nn.child_count >= 2)
                {
                    append_pair(&a.arr_dom, &a.arr_count, &a.arr_cod,
                                nn.children[0], nn.children[1]);
                }
                break;
            case St.ST_ARRAY:
                if (nn.child_count >= 1) { append_i(&a.arr_elem, &a.arr_elem_count, nn.children[0]); }
                break;
            case St.ST_OPTION:
                if (nn.child_count >= 1) { append_i(&a.opt_inner, &a.opt_count, nn.children[0]); }
                break;
            default: break;
        }
    }
}

// ── is_empty is the ONLY recursive point. All helpers are defined after it
//    so we don't need forward decls; they refer back to is_empty via a
//    function pointer stored in a parameter? No — simpler: we define the
//    helpers AFTER is_empty and only reference them from within is_empty
//    which means the compiler already saw them. That means we define them
//    FIRST. But they need to call is_empty. Chicken-and-egg.
//
//    Solution: a single recursive is_empty that handles ALL kinds in one
//    go via inline dispatch. No helpers call back. ─────────────────────

fn bool is_empty(TypeStore* ts, int ty, int depth)
{
    if (ty < 0 || depth > SUB_MAX_DEPTH) return true;
    theory_setops::StNode* n = &ts.nodes[ty];
    if (n.kind == St.ST_BOTTOM) return true;
    if (n.kind == St.ST_TOP) return false;
    if (n.kind == St.ST_UNION && n.child_count >= 2)
    {
        bool l = is_empty(ts, n.children[0], depth + 1);
        bool r = is_empty(ts, n.children[1], depth + 1);
        return l && r;
    }
    if (n.kind == St.ST_INTER && n.child_count >= 2)
    {
        if (is_empty(ts, n.children[0], depth + 1)) return true;
        if (is_empty(ts, n.children[1], depth + 1)) return true;
    }
    if (n.kind == St.ST_NEG && n.child_count >= 1)
    {
        theory_setops::StNode* cn = &ts.nodes[n.children[0]];
        if (cn.kind == St.ST_TOP) return true;
        if (cn.kind == St.ST_BOTTOM) return false;
    }

    AtomSet a;
    atomset_init(&a);
    collect_atoms(ts, ty, &a, true, depth);
    bool result = false;

    if (a.has_bot) { result = true; }

    // prim disjointness
    if (!result)
    {
        for (usz i = 0; i < a.prim_pos_count && !result; i++)
        {
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
            if (a.nom_pos[0] != a.nom_pos[i]) { result = true; break; }
        }
    }
    if (!result)
    {
        for (usz i = 0; i < a.nom_pos_count && !result; i++)
        {
            for (usz j = 0; j < a.nom_neg_count; j++)
            {
                if (a.nom_pos[i] == a.nom_neg[j]) { result = true; break; }
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

    // arrays
    if (!result && a.arr_elem_count > 0)
    {
        int ei = ts.top_idx;
        for (usz i = 0; i < a.arr_elem_count; i++) ei = ts.my_inter(ei, a.arr_elem[i]);
        int eid = theory_setops::st_dnf(ts, ei);
        if (is_empty(ts, eid, depth + 1)) result = true;
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

struct SemSub
{
    TypeStore* ts;
    usz n_queries;
    usz n_translated;
    Arena* arena;
}

fn void SemSub.init(SemSub* ss, Arena* a)
{
    ss.arena = a;
    ss.ts = (TypeStore*)malloc(theory_setops::TypeStore::size);
    if (ss.ts != null) ss.ts.init();
    ss.n_queries = 0; ss.n_translated = 0;
}

fn void SemSub.walk(SemSub* ss, Node* n, int depth)
{
    if (n == null || depth > 50 || ss.ts == null) return;
    if (n.kind == Nk.N_TY_FN && n.child_count >= 2)
    {
        int aa = translate_type(ss.ts, n.children[0], 0);
        int bb = translate_type(ss.ts, n.children[n.child_count - 1], 0);
        (void)aa; (void)bb;
        ss.n_queries = ss.n_queries + 1;
        ss.n_translated = ss.n_translated + 2;
    }
    if (n.kind == Nk.N_EXPR_INT || n.kind == Nk.N_EXPR_FLOAT || n.kind == Nk.N_EXPR_BOOL)
    {
        ss.n_queries = ss.n_queries + 1;
    }
    for (usz i = 0; i < n.child_count; i++) ss.walk(n.children[i], depth + 1);
}

fn void SemSub.report(SemSub* ss)
{
    printf("  sem-subtype      : %d exprs visited, %d types translated\n",
           (int)ss.n_queries, (int)ss.n_translated);
    if (ss.ts != null) ss.ts.report();
}

fn void SemSub.destroy(SemSub* ss)
{
    if (ss.ts != null) { ss.ts.destroy(); free((void*)ss.ts); ss.ts = null; }
}
