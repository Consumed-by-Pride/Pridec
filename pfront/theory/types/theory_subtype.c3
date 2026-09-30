// ============================================================================
// theory_subtype.c3 — set-theoretic semantic subtyping (part 26)
// ----------------------------------------------------------------------------
// `theory_modal` has a structural `subtype()` that handles unions and
// intersections by distributing over them. That is correct as far as it goes,
// but it cannot decide the cases that make set-theoretic types worth having:
//
//     (A ∪ B) ∩ C  <:  (A ∩ C) ∪ (B ∩ C)      distributivity
//     A ∩ ¬A       <:  ⊥                       contradiction
//     A            <:  A ∪ ¬A                  excluded middle
//     ¬(A ∪ B)     ≡   ¬A ∩ ¬B                 De Morgan
//
// Deciding those needs the SEMANTIC reading: a type denotes a SET of values,
// and `A <: B` means `⟦A⟧ ⊆ ⟦B⟧`, equivalently `⟦A ∩ ¬B⟧ = ∅`. So subtyping
// reduces to EMPTINESS, and emptiness is decided on a normal form.
//
// The normal form used here is DISJUNCTIVE NORMAL FORM over atoms:
//
//     τ  ≡  ⋁ᵢ ( ⋀ⱼ aᵢⱼ  ∧  ⋀ₖ ¬bᵢₖ )
//
// A DNF clause is empty when it contains an atom and its negation, or two
// atoms that cannot coexist (`i64 ∩ bool` is empty because no value is both).
// The whole type is empty when every clause is.
//
// This is the Castagna–Frisch algorithm in miniature. The full version handles
// arrow types by a subtle decomposition; this implementation is complete for
// atoms, products, and negation, and is CONSERVATIVE for arrows — it answers
// "not a subtype" when it cannot prove otherwise, which is the safe direction:
// a false negative rejects a valid program with a clear message, a false
// positive accepts an invalid one and miscompiles it.
// ============================================================================

module theory_subtype;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz ST_MAX_ATOMS    = 64;
const usz ST_MAX_CLAUSES  = 128;
const usz ST_MAX_CACHE    = 8192;
const int ST_MAX_DEPTH    = 64;

// ── Atoms ───────────────────────────────────────────────────────────────────
// An atom is an indivisible type: a primitive, a named nominal type, or a
// structural former whose components are themselves types.
enum AtomKind : int
{
    AT_PRIM,        // i64, bool, f64 ...
    AT_NAMED,       // struct / enum / newtype
    AT_PTR,
    AT_SLICE,
    AT_ARRAY,
    AT_TUPLE,
    AT_ARROW,
    AT_UNIT,
    AT_TOP,         // any value
    AT_BOTTOM       // no value
}

struct Atom
{
    AtomKind kind;
    uint     name_id;
    Node*    decl;
    Node*    node;
    bool     negated;
}

fn bool atom_eq(Atom* a, Atom* b)
{
    if (a.kind != b.kind) { return false; }
    if (a.kind == AtomKind.AT_PRIM || a.kind == AtomKind.AT_NAMED)
    {
        if (a.decl != null && b.decl != null) { return a.decl == b.decl; }
        return a.name_id == b.name_id;
    }
    return theory_term::term_eq(a.node, b.node, 0);
}

// Two atoms are DISJOINT when no value inhabits both. This is what makes
// `i64 ∩ bool` provably empty rather than merely unusual.
fn bool atoms_disjoint(Atom* a, Atom* b)
{
    if (a.kind == AtomKind.AT_BOTTOM || b.kind == AtomKind.AT_BOTTOM) { return true; }
    if (a.kind == AtomKind.AT_TOP || b.kind == AtomKind.AT_TOP) { return false; }

    // Different structural formers never overlap: a pointer is not a tuple.
    if (a.kind != b.kind) { return true; }

    // Same former, different identity: two distinct nominal types are
    // disjoint because Pride has nominal (not structural) named types.
    if (a.kind == AtomKind.AT_NAMED)
    {
        if (a.decl != null && b.decl != null) { return a.decl != b.decl; }
        return a.name_id != b.name_id;
    }
    if (a.kind == AtomKind.AT_PRIM) { return a.name_id != b.name_id; }
    return false;
}

// ── DNF clauses ─────────────────────────────────────────────────────────────
// One clause is a conjunction of possibly-negated atoms.
struct Clause
{
    Atom[ST_MAX_ATOMS] atoms;
    usz                count;
    bool               known_empty;
}

fn void Clause.init(Clause* c)
{
    c.count = 0;
    c.known_empty = false;
}

fn bool Clause.add(Clause* c, Atom a)
{
    if (c.count >= ST_MAX_ATOMS) { return false; }
    // A clause containing both A and ¬A is empty: no value is in a set and
    // its complement.
    for (usz i = 0; i < c.count; i++)
    {
        if (atom_eq(&c.atoms[i], &a) && c.atoms[i].negated != a.negated)
        {
            c.known_empty = true;
        }
        // Two disjoint positive atoms also make the clause empty.
        if (!c.atoms[i].negated && !a.negated && atoms_disjoint(&c.atoms[i], &a))
        {
            c.known_empty = true;
        }
        // Duplicate: idempotent, skip.
        if (atom_eq(&c.atoms[i], &a) && c.atoms[i].negated == a.negated)
        {
            return true;
        }
    }
    c.atoms[c.count] = a;
    c.count = c.count + 1;
    return true;
}

fn bool Clause.contains(Clause* c, Atom* atom)
{
    if (c == null || atom == null) return false;
    for (usz i = 0; i < c.count && i < ST_MAX_ATOMS; i++)
    {
        if (atom_eq(&c.atoms[i], atom) && c.atoms[i].negated == atom.negated) return true;
    }
    return false;
}

// A conjunction with fewer literals denotes a superset of one with more
// literals. DNF union can discard the narrower clause without losing values.
fn bool Clause.subsumes(Clause* general, Clause* specific)
{
    if (general == null || specific == null
        || general.count > ST_MAX_ATOMS || specific.count > ST_MAX_ATOMS
        || general.count > specific.count) return false;
    for (usz i = 0; i < general.count; i++)
    {
        if (!specific.contains(&general.atoms[i])) return false;
    }
    return true;
}

fn bool Clause.is_empty(Clause* c)
{
    if (c == null || c.count > ST_MAX_ATOMS) return false;
    if (c.known_empty) { return true; }
    // A clause with a positive BOTTOM is empty; one with only negations of
    // TOP is empty too.
    for (usz i = 0; i < c.count; i++)
    {
        Atom* a = &c.atoms[i];
        if (!a.negated && a.kind == AtomKind.AT_BOTTOM) { return true; }
        if (a.negated && a.kind == AtomKind.AT_TOP) { return true; }
    }
    return false;
}

// ── DNF ─────────────────────────────────────────────────────────────────────
struct Dnf
{
    Clause[ST_MAX_CLAUSES] clauses;
    usz                    count;
    usz                    duplicate_drops;
    usz                    absorbed_drops;
    bool                   overflowed;
}

fn void Dnf.init(Dnf* d)
{
    d.count = 0;
    d.duplicate_drops = 0;
    d.absorbed_drops = 0;
    d.overflowed = false;
}

fn bool Dnf.add_clause(Dnf* d, Clause* c)
{
    if (d == null || c == null || d.overflowed) return false;
    if (d.count > ST_MAX_CLAUSES)
    {
        d.overflowed = true;
        return false;
    }
    // An empty clause contributes nothing to a union.
    if (c.is_empty()) return true;
    if (c.count > ST_MAX_ATOMS) { d.overflowed = true; return false; }
    usz i = 0;
    while (i < d.count)
    {
        Clause* existing = &d.clauses[i];
        if (existing.subsumes(c))
        {
            if (c.subsumes(existing))
            {
                d.duplicate_drops++;
            }
            else
            {
                d.absorbed_drops++;
            }
            return true;
        }
        if (c.subsumes(existing))
        {
            for (usz j = i + 1; j < d.count; j++) d.clauses[j - 1] = d.clauses[j];
            d.count--;
            d.absorbed_drops++;
            continue;
        }
        i++;
    }
    if (d.count >= ST_MAX_CLAUSES) { d.overflowed = true; return false; }
    d.clauses[d.count] = *c;
    d.count++;
    return true;
}

// The whole type is empty exactly when every clause is.
fn bool Dnf.is_empty(Dnf* d)
{
    if (d == null || d.overflowed || d.count > ST_MAX_CLAUSES) { return false; }
    // Cannot prove emptiness after a budget or shape failure.
    for (usz i = 0; i < d.count; i++)
    {
        if (!d.clauses[i].is_empty()) { return false; }
    }
    return true;
}

struct DnfAudit
{
    usz checks;
    usz failures;
    usz absorption_cases;
    usz duplicate_cases;
    usz overflow_cases;
    usz conversion_cases;
    usz distribution_cases;
    usz query_cases;
}

fn void DnfAudit.expect(DnfAudit* audit, bool condition)
{
    audit.checks++;
    if (!condition)
    {
        audit.failures++;
        printf("  dnf law failure : check %d\n", (int)audit.checks);
    }
}

fn Atom audit_primitive_atom(uint identity)
{
    Atom atom;
    atom.kind = AtomKind.AT_PRIM;
    atom.name_id = identity;
    atom.decl = null;
    atom.node = null;
    atom.negated = false;
    return atom;
}

// Run inexpensive representation-level checks once per subtyper instance.
// These guard absorption ordering, truth/false encodings, fixed-capacity
// overflow, and duplicate normalization used by every subsequent query.
fn DnfAudit dnf_verify_laws()
{
    DnfAudit audit;
    audit.checks = 0; audit.failures = 0;
    audit.absorption_cases = 0; audit.duplicate_cases = 0; audit.overflow_cases = 0;
    audit.conversion_cases = 0; audit.distribution_cases = 0; audit.query_cases = 0;
    Dnf* dnf = (Dnf*)malloc(Dnf::size);
    if (dnf == null)
    {
        audit.failures = 1;
        audit.overflow_cases++;
        return audit;
    }
    Node broad_node;
    broad_node.kind = Nk.N_TY_TUPLE;
    broad_node.p.op = 0;
    broad_node.name_id = 0x7101u;
    broad_node.child_count = 0;
    Node narrow_node;
    narrow_node.kind = Nk.N_TY_TUPLE;
    narrow_node.p.op = 0;
    narrow_node.name_id = 0x7102u;
    narrow_node.child_count = 0;
    Atom broad_atom;
    broad_atom.kind = AtomKind.AT_TUPLE;
    broad_atom.name_id = 0;
    broad_atom.decl = null;
    broad_atom.node = &broad_node;
    broad_atom.negated = false;
    Atom narrow_atom;
    narrow_atom.kind = AtomKind.AT_TUPLE;
    narrow_atom.name_id = 0;
    narrow_atom.decl = null;
    narrow_atom.node = &narrow_node;
    narrow_atom.negated = false;
    Clause broad; broad.init(); broad.add(broad_atom);
    Clause narrow; narrow.init(); narrow.add(broad_atom); narrow.add(narrow_atom);

    dnf.init();
    dnf.add_clause(&narrow);
    dnf.add_clause(&broad);
    audit.expect(dnf.count == 1 && dnf.clauses[0].count == 1
        && dnf.clauses[0].atoms[0].node == broad_atom.node
        && dnf.absorbed_drops == 1 && !dnf.overflowed);
    audit.absorption_cases++;

    dnf.init();
    dnf.add_clause(&broad);
    dnf.add_clause(&narrow);
    audit.expect(dnf.count == 1 && dnf.absorbed_drops == 1 && !dnf.overflowed);
    audit.absorption_cases++;

    dnf.init();
    dnf.add_clause(&broad);
    dnf.add_clause(&broad);
    audit.expect(dnf.count == 1 && dnf.duplicate_drops == 1);
    audit.duplicate_cases++;

    dnf.init();
    Clause truth; truth.init();
    dnf.add_clause(&broad);
    dnf.add_clause(&truth);
    audit.expect(dnf.count == 1 && dnf.clauses[0].count == 0 && !dnf.is_empty());
    audit.absorption_cases++;

    dnf.init();
    audit.expect(dnf.is_empty());
    Clause contradiction; contradiction.init(); contradiction.known_empty = true;
    dnf.add_clause(&contradiction);
    audit.expect(dnf.count == 0 && dnf.is_empty());
    Atom complement = broad_atom;
    complement.negated = true;
    Clause complementary_pair; complementary_pair.init();
    complementary_pair.add(broad_atom);
    complementary_pair.add(complement);
    audit.expect(complementary_pair.is_empty());

    dnf.init();
    for (uint i = 0; i < ST_MAX_CLAUSES + 1; i++)
    {
        Clause candidate; candidate.init();
        Atom atom = audit_primitive_atom(0x7200u + i);
        candidate.add(atom);
        dnf.add_clause(&candidate);
    }
    audit.expect(dnf.overflowed && !dnf.is_empty());
    audit.overflow_cases++;

    Clause capped; capped.init();
    bool all_atoms_fit = true;
    for (uint i = 0; i < ST_MAX_ATOMS; i++)
    {
        Atom atom = audit_primitive_atom(0x7300u + i);
        if (!capped.add(atom)) all_atoms_fit = false;
    }
    Atom extra = audit_primitive_atom(0x7400u);
    bool rejected_extra = !capped.add(extra);
    audit.expect(all_atoms_fit && rejected_extra && capped.count == ST_MAX_ATOMS);
    audit.overflow_cases++;

    Clause malformed_clause; malformed_clause.init();
    malformed_clause.count = ST_MAX_ATOMS + 1;
    dnf.init();
    bool accepted_malformed_clause = dnf.add_clause(&malformed_clause);
    audit.expect(!accepted_malformed_clause && dnf.overflowed && !dnf.is_empty());

    dnf.init();
    dnf.count = ST_MAX_CLAUSES + 1;
    bool accepted_malformed_dnf = dnf.add_clause(&broad);
    audit.expect(!accepted_malformed_dnf && dnf.overflowed && !dnf.is_empty());
    free((void*)dnf);
    return audit;
}

// ── Conversion to DNF ───────────────────────────────────────────────────────
struct DnfBuilder
{
    Arena*                arena;
    pfront_core::DiagBag* diags;
    char*                 file;

    usz conversions;
    usz distributions;
    usz demorgan_steps;
    usz overflows;
    int max_depth;
}

fn void DnfBuilder.init(DnfBuilder* b, Arena* a, pfront_core::DiagBag* d, char* file)
{
    b.arena = a;
    b.diags = d;
    b.file = file;
    b.conversions = 0;
    b.distributions = 0;
    b.demorgan_steps = 0;
    b.overflows = 0;
    b.max_depth = 0;
}

fn Atom make_atom(Node* t, bool negated)
{
    Atom a;
    a.name_id = t == null ? 0 : t.name_id;
    a.decl = t == null ? null : t.resolved;
    a.node = t;
    a.negated = negated;
    a.kind = AtomKind.AT_NAMED;
    if (t == null) { a.kind = AtomKind.AT_TOP; return a; }
    switch (t.kind)
    {
        case N_TY_UNIT:   a.kind = AtomKind.AT_UNIT;
        case N_TY_BOTTOM: a.kind = AtomKind.AT_BOTTOM;
        case N_TY_PTR:
        case N_TY_REF:    a.kind = AtomKind.AT_PTR;
        case N_TY_SLICE:  a.kind = AtomKind.AT_SLICE;
        case N_TY_ARRAY:  a.kind = AtomKind.AT_ARRAY;
        case N_TY_TUPLE:  a.kind = AtomKind.AT_TUPLE;
        case N_TY_FN:     a.kind = AtomKind.AT_ARROW;
        case N_TY_INFER:  a.kind = AtomKind.AT_TOP;
        case N_TY_NAME:
        {
            // A primitive is recognised by spelling; anything else is nominal.
            char* s = t.p.sptr;
            usz n = t.p.slen;
            if (n == 3 && s != null && s[0] == 'a' && s[1] == 'n' && s[2] == 'y')
            {
                a.kind = AtomKind.AT_TOP;
                return a;
            }
            bool prim = false;
            if (s != null && n >= 2)
            {
                if ((s[0] == 'i' || s[0] == 'u' || s[0] == 'f')
                    && s[1] >= '0' && s[1] <= '9') { prim = true; }
                if (n == 4 && s[0] == 'b' && s[1] == 'o') { prim = true; }
                if (n == 4 && s[0] == 'c' && s[1] == 'h') { prim = true; }
                if (n == 3 && s[0] == 's' && s[1] == 't') { prim = true; }
            }
            a.kind = prim ? AtomKind.AT_PRIM : AtomKind.AT_NAMED;
        }
        default:
            a.kind = AtomKind.AT_NAMED;
    }
    return a;
}

// Convert a type to DNF. `negate` implements De Morgan lazily: pushing a
// negation inward swaps union and intersection.
fn void DnfBuilder.to_dnf(DnfBuilder* b, Node* t, bool negate, Dnf* out, int depth)
{
    if (depth > ST_MAX_DEPTH)
    {
        out.overflowed = true;
        b.overflows++;
        return;
    }
    if (depth > b.max_depth) { b.max_depth = depth; }
    b.conversions = b.conversions + 1;

    if (t == null)
    {
        Clause c;
        c.init();
        c.add(make_atom(null, negate));
        out.add_clause(&c);
        return;
    }

    switch (t.kind)
    {
        case N_TY_NEGATION:
        {
            if (t.child_count != 1)
            {
                out.overflowed = true;
                b.overflows++;
                return;
            }
            // ¬¬A ≡ A; otherwise push the negation inward.
            b.demorgan_steps++;
            b.to_dnf(t.children[0], !negate, out, depth + 1);
            return;
        }

        case N_TY_UNION:
        {
            if (t.child_count == 0)
            {
                if (negate)
                {
                    Clause truth;
                    truth.init();
                    out.add_clause(&truth);
                }
                return;
            }
            if (!negate)
            {
                // A ∪ B in DNF: the clauses of A followed by those of B.
                for (usz i = 0; i < t.child_count; i++)
                {
                    b.to_dnf(t.children[i], false, out, depth + 1);
                }
                return;
            }
            // ¬(A ∪ B) ≡ ¬A ∩ ¬B — a conjunction, so DISTRIBUTE.
            b.demorgan_steps = b.demorgan_steps + 1;
            b.conjoin_children(t, true, out, depth);
            return;
        }

        case N_TY_INTERSECT:
        {
            if (t.child_count == 0)
            {
                if (!negate)
                {
                    Clause truth;
                    truth.init();
                    out.add_clause(&truth);
                }
                return;
            }
            if (!negate)
            {
                b.conjoin_children(t, false, out, depth);
                return;
            }
            // ¬(A ∩ B) ≡ ¬A ∪ ¬B — a disjunction.
            b.demorgan_steps = b.demorgan_steps + 1;
            for (usz i = 0; i < t.child_count; i++)
            {
                b.to_dnf(t.children[i], true, out, depth + 1);
            }
            return;
        }

        default:
        {
            Clause c;
            c.init();
            c.add(make_atom(t, negate));
            out.add_clause(&c);
            return;
        }
    }
}

// Conjoin the children of an intersection: the DNF of a conjunction is the
// cross product of the operands' clause sets. This is where the combinatorial
// blow-up lives, hence the clause cap.
fn void DnfBuilder.conjoin_children(DnfBuilder* b, Node* t, bool negate_each,
                                    Dnf* out, int depth)
{
    Dnf* acc = (Dnf*)malloc(Dnf::size);
    if (acc == null) { out.overflowed = true; return; }
    acc.init();

    // Empty conjunction is true; empty union is handled by to_dnf before here.
    if (t.child_count == 0)
    {
        Clause truth;
        truth.init();
        out.add_clause(&truth);
        free((void*)acc);
        return;
    }
    b.to_dnf(t.children[0], negate_each, acc, depth + 1);
    if (acc.overflowed)
    {
        out.overflowed = true;
        b.overflows++;
        free((void*)acc);
        return;
    }

    Dnf* tmp = (Dnf*)malloc(Dnf::size);
    if (tmp == null) { free((void*)acc); out.overflowed = true; return; }

    for (usz i = 1; i < t.child_count; i++)
    {
        Dnf* rhs = (Dnf*)malloc(Dnf::size);
        if (rhs == null)
        {
            out.overflowed = true;
            b.overflows++;
            break;
        }
        rhs.init();
        b.to_dnf(t.children[i], negate_each, rhs, depth + 1);
        if (rhs.overflowed)
        {
            out.overflowed = true;
            b.overflows++;
            free((void*)rhs);
            break;
        }

        tmp.init();
        // Cross product: every clause of acc with every clause of rhs.
        for (usz x = 0; x < acc.count; x++)
        {
            for (usz y = 0; y < rhs.count; y++)
            {
                Clause merged = acc.clauses[x];
                bool clause_complete = true;
                for (usz k = 0; k < rhs.clauses[y].count; k++)
                {
                    if (!merged.add(rhs.clauses[y].atoms[k]))
                    {
                        clause_complete = false;
                        break;
                    }
                }
                if (!clause_complete)
                {
                    tmp.overflowed = true;
                }
                else if (!merged.is_empty())
                {
                    tmp.add_clause(&merged);
                }
                b.distributions++;
            }
        }
        *acc = *tmp;
        free((void*)rhs);
        if (acc.overflowed)
        {
            b.overflows++;
            break;
        }
    }

    for (usz i = 0; i < acc.count; i++) { out.add_clause(&acc.clauses[i]); }
    if (acc.overflowed) { out.overflowed = true; }
    free((void*)tmp);
    free((void*)acc);
}

// The builder audit uses tiny synthetic type ASTs so it exercises the real
// AST-to-DNF conversion and cross-product path without parser or resolver
// dependencies. Every node field read by make_atom/term_eq is initialized.
fn void dnf_audit_node(Node* node, Nk kind, uint identity,
                       Node** children, usz child_count)
{
    node.kind = kind;
    node.p.op = 0;
    node.name_id = identity;
    node.resolved = null;
    node.children = children;
    node.child_count = child_count;
}

fn void DnfBuilder.verify_laws(DnfBuilder* b, DnfAudit* audit)
{
    DnfBuilder probe;
    probe.init(b.arena, b.diags, b.file);
    Dnf* dnf = (Dnf*)malloc(Dnf::size);
    if (dnf == null)
    {
        audit.failures++;
        return;
    }
    Node atom_a; dnf_audit_node(&atom_a, Nk.N_TY_TUPLE, 0x7501u, null, 0);
    Node atom_b; dnf_audit_node(&atom_b, Nk.N_TY_TUPLE, 0x7502u, null, 0);
    Node atom_c; dnf_audit_node(&atom_c, Nk.N_TY_TUPLE, 0x7503u, null, 0);

    Node*[2] union_children;
    union_children[0] = &atom_a;
    union_children[1] = &atom_b;
    Node union_ab;
    dnf_audit_node(&union_ab, Nk.N_TY_UNION, 0, &union_children[0], 2);

    dnf.init();
    probe.to_dnf(&union_ab, false, dnf, 0);
    audit.expect(dnf.count == 2 && !dnf.overflowed
        && dnf.clauses[0].count == 1 && dnf.clauses[1].count == 1);
    audit.conversion_cases++;

    Node*[2] intersect_children;
    intersect_children[0] = &union_ab;
    intersect_children[1] = &atom_c;
    Node union_intersect_c;
    dnf_audit_node(&union_intersect_c, Nk.N_TY_INTERSECT, 0, &intersect_children[0], 2);
    usz distributions_before = probe.distributions;
    dnf.init();
    probe.to_dnf(&union_intersect_c, false, dnf, 0);
    audit.expect(dnf.count == 2 && !dnf.overflowed
        && dnf.clauses[0].count == 2 && dnf.clauses[1].count == 2
        && probe.distributions - distributions_before == 2);
    audit.distribution_cases++;

    Node*[1] unary_child;
    unary_child[0] = &union_ab;
    Node not_union;
    dnf_audit_node(&not_union, Nk.N_TY_NEGATION, 0, &unary_child[0], 1);
    dnf.init();
    probe.to_dnf(&not_union, false, dnf, 0);
    audit.expect(dnf.count == 1 && dnf.clauses[0].count == 2
        && dnf.clauses[0].atoms[0].negated && dnf.clauses[0].atoms[1].negated);
    audit.conversion_cases++;

    Node*[2] atom_pair;
    atom_pair[0] = &atom_a;
    atom_pair[1] = &atom_b;
    Node intersect_ab;
    dnf_audit_node(&intersect_ab, Nk.N_TY_INTERSECT, 0, &atom_pair[0], 2);
    unary_child[0] = &intersect_ab;
    Node not_intersection;
    dnf_audit_node(&not_intersection, Nk.N_TY_NEGATION, 0, &unary_child[0], 1);
    dnf.init();
    probe.to_dnf(&not_intersection, false, dnf, 0);
    audit.expect(dnf.count == 2 && dnf.clauses[0].count == 1
        && dnf.clauses[1].count == 1
        && dnf.clauses[0].atoms[0].negated && dnf.clauses[1].atoms[0].negated);
    audit.conversion_cases++;

    Node empty_union;
    dnf_audit_node(&empty_union, Nk.N_TY_UNION, 0, null, 0);
    dnf.init();
    probe.to_dnf(&empty_union, false, dnf, 0);
    audit.expect(dnf.count == 0 && dnf.is_empty());
    audit.conversion_cases++;
    dnf.init();
    probe.to_dnf(&empty_union, true, dnf, 0);
    audit.expect(dnf.count == 1 && dnf.clauses[0].count == 0 && !dnf.is_empty());
    audit.conversion_cases++;

    Node empty_intersection;
    dnf_audit_node(&empty_intersection, Nk.N_TY_INTERSECT, 0, null, 0);
    dnf.init();
    probe.to_dnf(&empty_intersection, false, dnf, 0);
    audit.expect(dnf.count == 1 && dnf.clauses[0].count == 0 && !dnf.is_empty());
    audit.conversion_cases++;
    dnf.init();
    probe.to_dnf(&empty_intersection, true, dnf, 0);
    audit.expect(dnf.count == 0 && dnf.is_empty());
    audit.conversion_cases++;

    Node malformed_negation;
    dnf_audit_node(&malformed_negation, Nk.N_TY_NEGATION, 0, &union_children[0], 2);
    dnf.init();
    probe.to_dnf(&malformed_negation, false, dnf, 0);
    audit.expect(dnf.overflowed && !dnf.is_empty());
    audit.overflow_cases++;

    dnf.init();
    usz overflow_before = probe.overflows;
    probe.to_dnf(&atom_a, false, dnf, ST_MAX_DEPTH + 1);
    audit.expect(dnf.overflowed && !dnf.is_empty() && probe.overflows == overflow_before + 1);
    audit.overflow_cases++;

    Node[12] left_atoms;
    Node*[12] left_children;
    Node[12] right_atoms;
    Node*[12] right_children;
    for (uint i = 0; i < 12; i++)
    {
        dnf_audit_node(&left_atoms[i], Nk.N_TY_TUPLE, 0x7600u + i, null, 0);
        dnf_audit_node(&right_atoms[i], Nk.N_TY_TUPLE, 0x7700u + i, null, 0);
        left_children[i] = &left_atoms[i];
        right_children[i] = &right_atoms[i];
    }
    Node left_union; dnf_audit_node(&left_union, Nk.N_TY_UNION, 0, &left_children[0], 12);
    Node right_union; dnf_audit_node(&right_union, Nk.N_TY_UNION, 0, &right_children[0], 12);
    Node*[2] wide_product_children;
    wide_product_children[0] = &left_union;
    wide_product_children[1] = &right_union;
    Node wide_product;
    dnf_audit_node(&wide_product, Nk.N_TY_INTERSECT, 0, &wide_product_children[0], 2);
    distributions_before = probe.distributions;
    dnf.init();
    probe.to_dnf(&wide_product, false, dnf, 0);
    audit.expect(dnf.overflowed && !dnf.is_empty()
        && probe.distributions - distributions_before == 144);
    audit.distribution_cases++;
    audit.overflow_cases++;

    Node bottom;
    dnf_audit_node(&bottom, Nk.N_TY_BOTTOM, 0, null, 0);
    dnf.init();
    probe.to_dnf(&bottom, false, dnf, 0);
    audit.expect(dnf.count == 0 && dnf.is_empty());
    audit.conversion_cases++;
    dnf.init();
    probe.to_dnf(&bottom, true, dnf, 0);
    audit.expect(dnf.count == 1 && !dnf.is_empty());
    audit.conversion_cases++;

    dnf.init();
    probe.to_dnf(null, false, dnf, 0);
    audit.expect(dnf.count == 1 && !dnf.is_empty());
    audit.conversion_cases++;
    dnf.init();
    probe.to_dnf(null, true, dnf, 0);
    audit.expect(dnf.count == 0 && dnf.is_empty());
    audit.conversion_cases++;
    free((void*)dnf);
}

// ── Semantic subtyping ──────────────────────────────────────────────────────
// A <: B  ⟺  ⟦A ∩ ¬B⟧ = ∅. Reducing subtyping to emptiness is what makes the
// distributive laws fall out automatically instead of being special-cased.
struct CacheEntry
{
    Node* a;
    Node* b;
    bool  result;
}

struct SemanticSubtyper
{
    DnfBuilder builder;
    DnfAudit dnf_laws;
    CacheEntry[ST_MAX_CACHE] cache;
    usz                      cache_count;

    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    Arena*                 arena;
    char*                  file;

    usz queries;
    usz cache_hits;
    usz emptiness_checks;
    usz proved_empty;
    usz arrow_conservative;   // arrow cases answered conservatively
}

fn void SemanticSubtyper.init(SemanticSubtyper* s, Arena* a,
                              pfront_core::DiagBag* d,
                              pfront_core::Interner* it, char* file)
{
    s.builder.init(a, d, file);
    s.dnf_laws = dnf_verify_laws();
    s.builder.verify_laws(&s.dnf_laws);
    s.cache_count = 0;
    s.diags = d;
    s.interner = it;
    s.arena = a;
    s.file = file;
    s.queries = 0;
    s.cache_hits = 0;
    s.emptiness_checks = 0;
    s.proved_empty = 0;
    s.arrow_conservative = 0;
}

fn bool SemanticSubtyper.cache_get(SemanticSubtyper* s, Node* a, Node* b, bool* out)
{
    for (usz i = 0; i < s.cache_count; i++)
    {
        if (s.cache[i].a == a && s.cache[i].b == b)
        {
            *out = s.cache[i].result;
            s.cache_hits = s.cache_hits + 1;
            return true;
        }
    }
    return false;
}

fn void SemanticSubtyper.cache_put(SemanticSubtyper* s, Node* a, Node* b, bool r)
{
    if (s.cache_count >= ST_MAX_CACHE) { return; }
    s.cache[s.cache_count].a = a;
    s.cache[s.cache_count].b = b;
    s.cache[s.cache_count].result = r;
    s.cache_count = s.cache_count + 1;
}

// Is `t` uninhabited?
fn bool SemanticSubtyper.is_empty(SemanticSubtyper* s, Node* t)
{
    s.emptiness_checks = s.emptiness_checks + 1;
    if (s.dnf_laws.failures > 0) return false;
    Dnf* d = (Dnf*)malloc(Dnf::size);
    if (d == null) { return false; }
    d.init();
    s.builder.to_dnf(t, false, d, 0);
    bool empty = d.is_empty();
    if (empty) { s.proved_empty = s.proved_empty + 1; }
    free((void*)d);
    return empty;
}

// The main entry point.
fn bool SemanticSubtyper.subtype(SemanticSubtyper* s, Node* a, Node* b)
{
    if (a == null || b == null) { return false; }
    if (a == b) { return true; }
    s.queries = s.queries + 1;
    if (s.dnf_laws.failures > 0) return false;

    bool cached = false;
    if (s.cache_get(a, b, &cached)) { return cached; }

    // Build A ∩ ¬B as a DNF directly: the clauses of A, each conjoined with
    // every clause of ¬B.
    Dnf* da = (Dnf*)malloc(Dnf::size);
    Dnf* db = (Dnf*)malloc(Dnf::size);
    if (da == null || db == null)
    {
        if (da != null) { free((void*)da); }
        if (db != null) { free((void*)db); }
        return false;
    }
    da.init();
    db.init();
    s.builder.to_dnf(a, false, da, 0);
    s.builder.to_dnf(b, true, db, 0);     // ¬B

    bool all_empty = true;
    for (usz i = 0; i < da.count && all_empty; i++)
    {
        for (usz j = 0; j < db.count && all_empty; j++)
        {
            Clause merged = da.clauses[i];
            bool clause_complete = true;
            for (usz k = 0; k < db.clauses[j].count; k++)
            {
                if (!merged.add(db.clauses[j].atoms[k]))
                {
                    clause_complete = false;
                    break;
                }
            }
            if (!clause_complete || !merged.is_empty()) all_empty = false;
        }
    }

    // Overflow means "could not decide"; answer conservatively.
    if (da.overflowed || db.overflowed) { all_empty = false; }

    free((void*)da);
    free((void*)db);
    s.cache_put(a, b, all_empty);
    return all_empty;
}

// Structural refinement for the cases DNF alone cannot see through: an arrow
// is contravariant in its argument, a tuple is covariant componentwise.
fn bool SemanticSubtyper.subtype_structural(SemanticSubtyper* s, Node* a, Node* b,
                                            int depth)
{
    if (a == null || b == null || depth > ST_MAX_DEPTH) { return false; }
    if (s.subtype(a, b)) { return true; }
    if (a.kind != b.kind) { return false; }

    switch (a.kind)
    {
        case N_TY_TUPLE:
        {
            if (a.child_count != b.child_count) { return false; }
            for (usz i = 0; i < a.child_count; i++)
            {
                if (!s.subtype_structural(a.children[i], b.children[i], depth + 1))
                {
                    return false;
                }
            }
            return true;
        }
        case N_TY_SLICE:
            return s.subtype_structural(a.child(0), b.child(0), depth + 1);
        case N_TY_FN:
        {
            // Contravariant in the parameter, covariant in the result. The
            // full set-theoretic decomposition of arrow subtyping is more
            // involved; this covers the common case and answers
            // conservatively otherwise.
            s.arrow_conservative = s.arrow_conservative + 1;
            if (a.child_count == 0 || b.child_count == 0) { return false; }
            if (!s.subtype_structural(b.children[0], a.children[0], depth + 1))
            {
                return false;
            }
            Node* ar = a.children[a.child_count - 1];
            Node* br = b.children[b.child_count - 1];
            return s.subtype_structural(ar, br, depth + 1);
        }
        default:
            return false;
    }
}

// Type equivalence: mutual subtyping. `A ∪ B` and `B ∪ A` are equivalent
// despite being syntactically different, which a term comparison cannot see.
fn bool SemanticSubtyper.equivalent(SemanticSubtyper* s, Node* a, Node* b)
{
    return s.subtype(a, b) && s.subtype(b, a);
}

// Is the intersection of these two types inhabited? Used to decide whether a
// match arm is reachable given the scrutinee's type.
fn bool SemanticSubtyper.overlaps(SemanticSubtyper* s, Node* a, Node* b)
{
    // On an audit failure, preserve reachability rather than diagnosing an arm dead.
    if (s.dnf_laws.failures > 0) return true;
    Dnf* da = (Dnf*)malloc(Dnf::size);
    Dnf* db = (Dnf*)malloc(Dnf::size);
    if (da == null || db == null)
    {
        if (da != null) { free((void*)da); }
        if (db != null) { free((void*)db); }
        return true;
    }
    da.init();
    db.init();
    s.builder.to_dnf(a, false, da, 0);
    s.builder.to_dnf(b, false, db, 0);

    bool found = da.overflowed || db.overflowed;
    for (usz i = 0; i < da.count && !found; i++)
    {
        for (usz j = 0; j < db.count && !found; j++)
        {
            Clause merged = da.clauses[i];
            bool clause_complete = true;
            for (usz k = 0; k < db.clauses[j].count; k++)
            {
                if (!merged.add(db.clauses[j].atoms[k]))
                {
                    clause_complete = false;
                    break;
                }
            }
            if (!clause_complete || !merged.is_empty()) found = true;
        }
    }
    free((void*)da);
    free((void*)db);
    return found;
}

// Simplify a type by dropping empty clauses and absorbing redundant ones.
// `(A ∩ ¬A) ∪ B` becomes `B`.
fn Node* SemanticSubtyper.simplify(SemanticSubtyper* s, Node* t)
{
    if (t == null) { return null; }
    if (s.dnf_laws.failures > 0) { return t; }
    if (t.kind != Nk.N_TY_UNION && t.kind != Nk.N_TY_INTERSECT) { return t; }

    Dnf* d = (Dnf*)malloc(Dnf::size);
    if (d == null) { return t; }
    d.init();
    s.builder.to_dnf(t, false, d, 0);

    if (d.is_empty())
    {
        free((void*)d);
        // Everything cancelled: the type is uninhabited.
        Node* bot = s.arena.node(Nk.N_TY_BOTTOM, t.line, t.col);
        return bot == null ? t : bot;
    }

    // A single surviving clause with a single atom simplifies to that atom.
    if (d.count == 1 && d.clauses[0].count == 1 && !d.clauses[0].atoms[0].negated)
    {
        Node* only = d.clauses[0].atoms[0].node;
        free((void*)d);
        return only == null ? t : only;
    }
    free((void*)d);
    return t;
}

// Exercise public semantic queries against small synthetic ASTs. Snapshot
// transient counters/cache state so the law audit does not masquerade as
// analysis of the user's program or poison its query cache with stack nodes.
fn void SemanticSubtyper.verify_query_laws(SemanticSubtyper* s)
{
    if (s.dnf_laws.failures > 0) return;
    DnfBuilder saved_builder = s.builder;
    usz saved_cache_count = s.cache_count;
    usz saved_queries = s.queries;
    usz saved_cache_hits = s.cache_hits;
    usz saved_emptiness_checks = s.emptiness_checks;
    usz saved_proved_empty = s.proved_empty;
    usz saved_arrow_conservative = s.arrow_conservative;

    Node atom_a; dnf_audit_node(&atom_a, Nk.N_TY_TUPLE, 0x7801u, null, 0);
    Node atom_b; dnf_audit_node(&atom_b, Nk.N_TY_TUPLE, 0x7802u, null, 0);
    Node bottom; dnf_audit_node(&bottom, Nk.N_TY_BOTTOM, 0, null, 0);
    Node*[2] union_children;
    union_children[0] = &atom_a;
    union_children[1] = &atom_b;
    Node union_ab;
    dnf_audit_node(&union_ab, Nk.N_TY_UNION, 0, &union_children[0], 2);
    Node*[2] reversed_children;
    reversed_children[0] = &atom_b;
    reversed_children[1] = &atom_a;
    Node union_ba;
    dnf_audit_node(&union_ba, Nk.N_TY_UNION, 0, &reversed_children[0], 2);
    Node*[2] intersect_children;
    intersect_children[0] = &atom_a;
    intersect_children[1] = &atom_b;
    Node intersection_ab;
    dnf_audit_node(&intersection_ab, Nk.N_TY_INTERSECT, 0, &intersect_children[0], 2);
    Node*[2] empty_intersection_children;
    empty_intersection_children[0] = &atom_a;
    empty_intersection_children[1] = &bottom;
    Node empty_intersection;
    dnf_audit_node(&empty_intersection, Nk.N_TY_INTERSECT, 0,
                   &empty_intersection_children[0], 2);
    Node empty_union;
    dnf_audit_node(&empty_union, Nk.N_TY_UNION, 0, null, 0);

    s.dnf_laws.expect(s.subtype(&atom_a, &union_ab));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.subtype(&atom_b, &union_ab));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(!s.subtype(&union_ab, &atom_a));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.subtype(&intersection_ab, &atom_a));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.is_empty(&empty_intersection));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.overlaps(&atom_a, &atom_b));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(!s.overlaps(&atom_a, &bottom));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.equivalent(&union_ab, &union_ba));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(s.subtype(&empty_union, &atom_a));
    s.dnf_laws.query_cases++;
    s.dnf_laws.expect(!s.subtype(&atom_a, &empty_union));
    s.dnf_laws.query_cases++;

    Node*[2] duplicate_children;
    duplicate_children[0] = &atom_a;
    duplicate_children[1] = &atom_a;
    Node duplicate_union;
    dnf_audit_node(&duplicate_union, Nk.N_TY_UNION, 0, &duplicate_children[0], 2);
    s.dnf_laws.expect(s.simplify(&duplicate_union) == &atom_a);
    s.dnf_laws.query_cases++;

    usz prior_failures = s.dnf_laws.failures;
    s.dnf_laws.failures = prior_failures + 1;
    bool safe_overlap = s.overlaps(&atom_a, &bottom);
    Node* safe_simplify = s.simplify(&duplicate_union);
    s.dnf_laws.failures = prior_failures;
    s.dnf_laws.expect(safe_overlap && safe_simplify == &duplicate_union);
    s.dnf_laws.query_cases++;

    s.builder = saved_builder;
    s.cache_count = saved_cache_count;
    s.queries = saved_queries;
    s.cache_hits = saved_cache_hits;
    s.emptiness_checks = saved_emptiness_checks;
    s.proved_empty = saved_proved_empty;
    s.arrow_conservative = saved_arrow_conservative;
}

fn void SemanticSubtyper.report(SemanticSubtyper* s)
{
    printf("  semantic subtype : %d queries, %d cached, %d emptiness checks\n",
           (int)s.queries, (int)s.cache_hits, (int)s.emptiness_checks);
    printf("  dnf              : %d conversions, %d distributions, %d De Morgan\n",
           (int)s.builder.conversions, (int)s.builder.distributions,
           (int)s.builder.demorgan_steps);
    if (s.proved_empty > 0 || s.builder.overflows > 0)
    {
        printf("  type emptiness   : %d proved uninhabited, %d undecided (overflow)\n",
               (int)s.proved_empty, (int)s.builder.overflows);
    }
    printf("  dnf laws         : %d checks, %d failures (absorptions=%d, duplicates=%d, budget=%d, conversions=%d, distributions=%d)\n",
           (int)s.dnf_laws.checks, (int)s.dnf_laws.failures,
           (int)s.dnf_laws.absorption_cases, (int)s.dnf_laws.duplicate_cases,
           (int)s.dnf_laws.overflow_cases, (int)s.dnf_laws.conversion_cases,
           (int)s.dnf_laws.distribution_cases);
    printf("  subtype laws    : %d query checks\n", (int)s.dnf_laws.query_cases);
}

// ── Type-directed match refinement ──────────────────────────────────────────
// With semantic subtyping available, a match arm can be checked against the
// scrutinee's type: an arm whose pattern type does not overlap the scrutinee
// is dead regardless of clause order.
struct MatchRefiner
{
    SemanticSubtyper*      sub;
    pfront_core::DiagBag*  diags;
    char*                  file;
    usz arms_checked;
    usz impossible_arms;
    usz refinements;
    usz aliases_checked;
    usz empty_aliases;
}

fn void MatchRefiner.init(MatchRefiner* m, SemanticSubtyper* s,
                          pfront_core::DiagBag* d, char* file)
{
    m.sub = s;
    m.diags = d;
    m.file = file;
    m.arms_checked = 0;
    m.aliases_checked = 0;
    m.empty_aliases = 0;
    m.impossible_arms = 0;
    m.refinements = 0;
}

fn void MatchRefiner.check_match(MatchRefiner* m, Node* match_expr)
{
    if (match_expr == null || match_expr.child_count < 2) { return; }
    Node* scrut = match_expr.child(0);
    if (scrut == null) { return; }
    Node* scrut_ty = scrut.type_ann;
    if (scrut_ty == null && scrut.resolved != null)
    {
        scrut_ty = scrut.resolved.type_ann;
    }
    if (scrut_ty == null) { return; }

    for (usz i = 1; i < match_expr.child_count; i++)
    {
        Node* arm = match_expr.children[i];
        if (arm == null) { continue; }
        Node* pat = arm.child(0);
        if (pat == null || pat.type_ann == null) { continue; }
        m.arms_checked = m.arms_checked + 1;

        // An arm whose pattern type cannot overlap the scrutinee is dead.
        if (!m.sub.overlaps(scrut_ty, pat.type_ann))
        {
            m.impossible_arms = m.impossible_arms + 1;
            m.diags.warn(pfront_core::Phase.PH_RESOLVE, 4100, arm.line, arm.col,
                         "this arm's pattern type cannot match the scrutinee",
                         m.file);
        }
        else
        {
            m.refinements = m.refinements + 1;
        }
    }
}

fn void MatchRefiner.walk(MatchRefiner* m, Node* n, int depth)
{
    if (n == null || depth > 300) { return; }
    if (n.kind == Nk.N_EXPR_MATCH) { m.check_match(n); }
    // A DECLARED type alias built from the set algebra is worth analysing on
    // its own. `type Impossible = i32 ∩ bool` is uninhabited, and saying so
    // at the declaration is far more useful than waiting for a value to flow
    // into it. Previously the subtyper only ever saw match scrutinees, so a
    // file full of ∩ / ∪ / ¬ aliases produced "0 queries" and the whole DNF
    // engine sat idle.
    if (n.kind == Nk.N_DECL_TYPE && n.type_ann != null)
    {
        m.check_alias(n);
    }
    for (usz i = 0; i < n.child_count; i++) { m.walk(n.children[i], depth + 1); }
}

// Analyse one `type NAME = <set expression>` declaration.
fn void MatchRefiner.check_alias(MatchRefiner* m, Node* decl)
{
    Node* ty = decl.type_ann;
    if (ty == null || m.sub == null) { return; }

    // Only the set-theoretic forms are interesting; a plain alias to a
    // nominal type has nothing to decide.
    bool algebraic = has_set_operator(ty, 0);
    if (!algebraic) { return; }

    m.aliases_checked = m.aliases_checked + 1;

    // Uninhabited alias: no value can ever have this type. Reported as an
    // advisory because Pride is untyped -- writing it is legal, and it may
    // even be deliberate (a "never" marker).
    if (m.sub.is_empty(ty))
    {
        m.empty_aliases = m.empty_aliases + 1;
        m.diags.advisory_hint(pfront_core::Phase.PH_RESOLVE, 3291,
                              decl.line, decl.col,
                              "this type is uninhabited: no value can inhabit it",
                              "an intersection of disjoint sets reduces to the empty set",
                              m.file);
    }
}

// Does this type mention any of ∩ / ∪ / ¬ anywhere inside?
fn bool has_set_operator(Node* t, int depth)
{
    if (t == null || depth > 64) { return false; }
    if (t.kind == Nk.N_TY_UNION || t.kind == Nk.N_TY_INTERSECT
        || t.kind == Nk.N_TY_NEGATION)
    {
        return true;
    }
    for (usz i = 0; i < t.child_count; i++)
    {
        if (has_set_operator(t.children[i], depth + 1)) { return true; }
    }
    return false;
}

fn void MatchRefiner.report(MatchRefiner* m)
{
    if (m.aliases_checked > 0)
    {
        printf("  type algebra     : %d aliases analysed, %d uninhabited\n",
               (int)m.aliases_checked, (int)m.empty_aliases);
    }
    if (m.arms_checked == 0) { return; }
    printf("  match refinement : %d arms typed, %d impossible, %d refined\n",
           (int)m.arms_checked, (int)m.impossible_arms, (int)m.refinements);
}
