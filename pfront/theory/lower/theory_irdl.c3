// ============================================================================
// theory_irdl.c3 — IRDL dialects + PGL pattern generation (part 14)
// ----------------------------------------------------------------------------
// Two compilers that both turn declarative descriptions into executable
// selection structures, sharing the term substrate.
//
// PART A — IRDL (IR Definition Language, after MLIR)
//   A program may DECLARE its own IR opcodes and the rules that LOWER them:
//
//       dialect GpuD
//         opcode gadd
//         opcode gmul
//       irdl
//         GpuD.gadd [a, b] ↦ a + b
//
//   Then `GpuD.gadd(x, y)` in real code lowers to `x + y`. This module
//   registers dialects, validates every use against the registry (unknown
//   dialect / unknown opcode / arity mismatch), and lowers uses by
//   substituting arguments into the rule template. Lowering runs to a
//   fixpoint because one dialect may lower to opcodes of a lower dialect.
//
// PART B — PGL (Pattern Generation Language)
//   Where rewriting transforms one term, PGL builds the matching
//   INFRASTRUCTURE: many clauses compiled into ONE decision tree that selects
//   the right action with minimal, shared tests. The algorithm is Maranget's
//   pattern-match compilation:
//
//     1. Collect clauses into a pattern MATRIX, one row per clause.
//     2. If the first row is all wildcards, emit a LEAF (that action).
//        Otherwise choose a column and SWITCH on the constructors in it; for
//        each constructor SPECIALISE the matrix and recurse, plus a DEFAULT
//        edge for the wildcard rows.
//     3. The result is a tree of TEST nodes ending in ACTION leaves.
//
//   Column selection matters for tree size, not correctness: this uses the
//   "most constructors first" heuristic, which reduces the branching factor
//   earlier and empirically yields smaller trees than left-to-right.
// ============================================================================

module theory_irdl;

import pfront_lex;
import pfront_core;
import theory_term;

alias Tk    = pfront_lex::TokenType;
alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias Subst = theory_term::Subst;

extern fn void* malloc(usz size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz MAX_DIALECTS   = 256;
const usz MAX_OPCODES    = 4096;
const usz MAX_LOWERINGS  = 4096;
const usz MAX_RULES_PER_OP = 8;
const int LOWER_FUEL     = 100000;
const int LOWER_MAX_DEPTH = 400;
const int IRDL_VARIADIC_AUX_T = 7; // must equal pfront_ext::IRDL_VARIADIC_AUX
const int IRDL_BLOCK_AUX  = 3;     // parse_irdl_decl marks `irdl` lowering blocks with aux 3
const usz TPL_EVENTS_MAX  = 64;
const usz MAX_GLOBALS     = 8192;
const usz MAX_LOCALS      = 1024;

// ════════════════════════════════════════════════════════════════════════════
// PART A — IRDL
// ════════════════════════════════════════════════════════════════════════════
struct LowerRule
{
    Node* pattern_args;   // binder list  [a, b]
    Node* action;         // template     a + b
    usz   arity;
    usz   fire_count;
    bool  asm_only;       // template is `emit_asm(..)`: registered, but no native lowering exists
}

struct Opcode
{
    uint      name_id;
    int       dialect;
    usz       arity;          // declared, or 0 when unspecified
    bool      arity_known;
    Node*     decl;
    LowerRule[MAX_RULES_PER_OP] rules;
    usz       rule_count;
    usz       use_count;
}

struct Dialect
{
    uint  name_id;
    Node* decl;
    int   first_opcode;
    usz   opcode_count;
}

struct DialectTable
{
    Dialect[MAX_DIALECTS] dialects;
    usz                   dialect_count;
    Opcode[MAX_OPCODES]   opcodes;
    usz                   opcode_count;

    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    Arena*                 arena;
    char*                  file;

    usz uses_validated;
    usz unknown_dialect;
    usz unknown_opcode;
    usz arity_mismatch;
    usz lowered;
    usz rules_registered;
    usz rules_rejected;
    usz unlowered;
    usz guard_blocked;
    usz asm_templates;
    uint[MAX_GLOBALS] globals;      // names declared at module top level
    usz  global_count;
    uint[MAX_LOCALS]  locals;       // binders (params/patterns) inside the item being lowered
    usz  local_count;
    bool locals_unknown;
    int fuel;
}

fn void DialectTable.init(DialectTable* dt, Arena* a, pfront_core::DiagBag* d,
                          pfront_core::Interner* it, char* file)
{
    dt.dialect_count = 0;
    dt.opcode_count = 0;
    dt.diags = d;
    dt.interner = it;
    dt.arena = a;
    dt.file = file;
    dt.uses_validated = 0;
    dt.unknown_dialect = 0;
    dt.unknown_opcode = 0;
    dt.arity_mismatch = 0;
    dt.lowered = 0;
    dt.rules_registered = 0;
    dt.rules_rejected = 0;
    dt.unlowered = 0;
    dt.guard_blocked = 0;
    dt.asm_templates = 0;
    dt.global_count = 0;
    dt.local_count = 0;
    dt.locals_unknown = false;
    dt.fuel = LOWER_FUEL;
}

fn int DialectTable.find_dialect(DialectTable* dt, uint name)
{
    for (usz i = 0; i < dt.dialect_count; i++)
    {
        if (dt.dialects[i].name_id == name) { return (int)i; }
    }
    return -1;
}

fn int DialectTable.find_opcode(DialectTable* dt, int dialect, uint name)
{
    for (usz i = 0; i < dt.opcode_count; i++)
    {
        if (dt.opcodes[i].dialect == dialect && dt.opcodes[i].name_id == name)
        {
            return (int)i;
        }
    }
    return -1;
}

fn int DialectTable.add_dialect(DialectTable* dt, uint name, Node* decl)
{
    int existing = dt.find_dialect(name);
    if (existing >= 0) { return existing; }
    if (dt.dialect_count >= MAX_DIALECTS) { return -1; }
    int id = (int)dt.dialect_count;
    dt.dialects[id].name_id = name;
    dt.dialects[id].decl = decl;
    dt.dialects[id].first_opcode = (int)dt.opcode_count;
    dt.dialects[id].opcode_count = 0;
    dt.dialect_count = dt.dialect_count + 1;
    return id;
}

fn int DialectTable.add_opcode(DialectTable* dt, int dialect, uint name, Node* decl)
{
    if (dialect < 0) { return -1; }
    int existing = dt.find_opcode(dialect, name);
    if (existing >= 0) { return existing; }
    if (dt.opcode_count >= MAX_OPCODES) { return -1; }
    int id = (int)dt.opcode_count;
    Opcode* op = &dt.opcodes[id];
    op.name_id = name;
    op.dialect = dialect;
    op.arity = 0;
    op.arity_known = false;
    op.decl = decl;
    op.rule_count = 0;
    op.use_count = 0;
    dt.opcode_count = dt.opcode_count + 1;
    dt.dialects[dialect].opcode_count = dt.dialects[dialect].opcode_count + 1;
    return id;
}

// Register every `dialect` block in the tree.
fn void DialectTable.register_dialects(DialectTable* dt, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    // The parser lowers `dialect X { opcode a ... }` to N_DECL_INTERFACE with
    // NF_SYNTHETIC, whose N_DECL_FIELD children are the opcodes.
    if (n.kind == Nk.N_DECL_INTERFACE && (n.flags & pfront_core::NF_SYNTHETIC) != 0
        && n.p.aux != IRDL_BLOCK_AUX)
    {
        int did = dt.add_dialect(n.name_id, n);
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* c = n.children[i];
            if (c == null || c.kind != Nk.N_DECL_FIELD) { continue; }
            dt.add_opcode(did, c.name_id, c);
        }
    }
    for (usz i = 0; i < n.child_count; i++) { dt.register_dialects(n.children[i], depth + 1); }
}

// Attach a lowering rule to an opcode.
fn bool DialectTable.add_lowering(DialectTable* dt, uint dialect_name,
                                  uint opcode_name, Node* args, Node* action)
{
    int did = dt.find_dialect(dialect_name);
    if (did < 0)
    {
        dt.unknown_dialect = dt.unknown_dialect + 1;
        return false;
    }
    int oid = dt.find_opcode(did, opcode_name);
    if (oid < 0)
    {
        dt.unknown_opcode = dt.unknown_opcode + 1;
        return false;
    }
    Opcode* op = &dt.opcodes[oid];
    if (op.rule_count >= MAX_RULES_PER_OP) { return false; }
    LowerRule* r = &op.rules[op.rule_count];
    r.pattern_args = args;
    r.action = action;
    r.arity = args == null ? 0 : args.child_count;
    r.fire_count = 0;
    r.asm_only = false;
    op.rule_count = op.rule_count + 1;
    // The first rule fixes the opcode's arity.
    if (!op.arity_known) { op.arity = r.arity; op.arity_known = true; }
    return true;
}

// Recognise a call whose callee is a dialect-qualified path `D.op(...)`.
/*
 Recognise `Dialect.opcode(args...)`.

 TWO shapes, because the parser produces different trees for what looks
 like one syntax:

   N_EXPR_METHOD          `T.add(a, b)` written directly. Child 0 is the
                          receiver, the rest are arguments, and the
                          opcode is the node's own name_id. This is what
                          the parser ACTUALLY builds -- it cannot tell a
                          method call on a value from a call to a module
                          or dialect member, so it always emits a method
                          node and lets the resolver decide.

   N_EXPR_CALL of         the shape this function originally handled, and
   N_EXPR_FIELD           only reachable when something else has already
                          rewritten the method node.

 Only the second was matched, so `irdl dialects: 2 dialects, 6 opcodes,
 0 uses validated` was printed for a program whose every dialect call was
 written the ordinary way. Arity checking, unknown-opcode diagnosis and
 the lowering to emit_asm were all unreachable for real source.
*/
fn bool split_dialect_call(Node* call, uint* out_dialect, uint* out_opcode)
{
    if (call == null) { return false; }

    if (call.kind == Nk.N_EXPR_METHOD)
    {
        if (call.child_count == 0) { return false; }
        Node* recv = call.children[0];
        if (recv == null || recv.kind != Nk.N_EXPR_IDENT) { return false; }
        *out_dialect = recv.name_id;
        *out_opcode = call.name_id;
        return true;
    }

    if (call.kind != Nk.N_EXPR_CALL || call.child_count == 0) { return false; }
    Node* callee = call.children[0];
    if (callee == null || callee.kind != Nk.N_EXPR_FIELD) { return false; }
    Node* base = callee.child(0);
    if (base == null || base.kind != Nk.N_EXPR_IDENT) { return false; }
    *out_dialect = base.name_id;
    *out_opcode = callee.name_id;
    return true;
}



// ── Name hygiene ───────────────────────────────────────────────────────────
// A template's FREE names (anything that is not an operand binder) are resolved
// where the opcode is USED, after substitution. They are therefore accepted
// only if (1) they name a top-level declaration of this module and (2) no
// binder inside the using item shadows them. Otherwise lowering could silently
// call a different function, or an undefined one.
fn bool DialectTable.is_global(DialectTable* dt, uint name)
{
    for (usz i = 0; i < dt.global_count; i++) { if (dt.globals[i] == name) { return true; } }
    return false;
}

fn void DialectTable.collect_globals(DialectTable* dt, Node* root, int depth)
{
    if (depth == 0) { dt.global_count = 0; }
    if (root == null || depth > 8) { return; }
    for (usz i = 0; i < root.child_count; i++)
    {
        Node* c = root.children[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_MODULE) { dt.collect_globals(c, depth + 1); continue; }
        if (c.name_id == 0 || c.kind == Nk.N_DECL_INTERFACE) { continue; }
        if (dt.global_count < MAX_GLOBALS)
        {
            dt.globals[dt.global_count] = c.name_id;
            dt.global_count = dt.global_count + 1;
        }
    }
}

fn void DialectTable.collect_locals(DialectTable* dt, Node* n, int depth)
{
    if (n == null) { return; }
    if (depth > 400) { dt.locals_unknown = true; return; }
    if ((n.kind == Nk.N_PAT_IDENT || n.kind == Nk.N_DECL_PARAM) && n.name_id != 0)
    {
        if (dt.local_count >= MAX_LOCALS) { dt.locals_unknown = true; return; }
        dt.locals[dt.local_count] = n.name_id;
        dt.local_count = dt.local_count + 1;
    }
    for (usz i = 0; i < n.child_count; i++) { dt.collect_locals(n.children[i], depth + 1); }
}

fn bool DialectTable.is_local(DialectTable* dt, uint name)
{
    if (dt.locals_unknown) { return true; }
    for (usz i = 0; i < dt.local_count; i++) { if (dt.locals[i] == name) { return true; } }
    return false;
}

fn bool DialectTable.free_names_declared(DialectTable* dt, Node* tmpl, Node* binds, int depth)
{
    if (tmpl == null) { return true; }
    if (depth > LOWER_MAX_DEPTH) { return false; }
    if (tmpl.kind == Nk.N_EXPR_IDENT && tmpl.name_id != 0)
    {
        bool is_binder = false;
        for (usz i = 0; i < binds.child_count; i++)
        {
            Node* b = binds.children[i];
            if (binder_is_name(b) && b.name_id == tmpl.name_id) { is_binder = true; }
        }
        if (!is_binder && !dt.is_global(tmpl.name_id)) { return false; }
    }
    uint tdn = 0;
    uint ton = 0;
    // `Dialect.op(..)` inside a template: the receiver names a dialect, not a value.
    bool dialect_use = tmpl.kind == Nk.N_EXPR_METHOD && split_dialect_call(tmpl, &tdn, &ton)
                       && dt.find_dialect(tdn) >= 0;
    for (usz i = dialect_use ? 1 : 0; i < tmpl.child_count; i++)
    {
        if (!dt.free_names_declared(tmpl.children[i], binds, depth + 1)) { return false; }
    }
    return true;
}

fn bool DialectTable.free_names_unshadowed(DialectTable* dt, Node* tmpl, Node* binds, int depth)
{
    if (tmpl == null) { return true; }
    if (depth > LOWER_MAX_DEPTH) { return false; }
    if (tmpl.kind == Nk.N_EXPR_IDENT && tmpl.name_id != 0)
    {
        bool is_binder = false;
        for (usz i = 0; i < binds.child_count; i++)
        {
            Node* b = binds.children[i];
            if (binder_is_name(b) && b.name_id == tmpl.name_id) { is_binder = true; }
        }
        if (!is_binder && dt.is_local(tmpl.name_id)) { return false; }
    }
    uint tdn = 0;
    uint ton = 0;
    // `Dialect.op(..)` inside a template: the receiver names a dialect, not a value.
    bool dialect_use = tmpl.kind == Nk.N_EXPR_METHOD && split_dialect_call(tmpl, &tdn, &ton)
                       && dt.find_dialect(tdn) >= 0;
    for (usz i = dialect_use ? 1 : 0; i < tmpl.child_count; i++)
    {
        if (!dt.free_names_unshadowed(tmpl.children[i], binds, depth + 1)) { return false; }
    }
    return true;
}

fn bool is_emit_asm_call(Node* action)
{
    if (action == null || action.kind != Nk.N_EXPR_CALL || action.child_count == 0) { return false; }
    Node* f = action.children[0];
    if (f == null || f.kind != Nk.N_EXPR_IDENT || f.p.slen != 8 || f.p.sptr == null) { return false; }
    char* t = f.p.sptr;
    return t[0] == 'e' && t[1] == 'm' && t[2] == 'i' && t[3] == 't' && t[4] == '_'
        && t[5] == 'a' && t[6] == 's' && t[7] == 'm';
}

// ── Rule validation and the operand-effect guard ────────────────────────────
// An irdl template is substituted TEXTUALLY, so it must stay inside a fragment
// where substitution is meaning-preserving: no binders (a `let`/lambda could
// capture an operand), no control flow, no allocation/IO/assignment forms.
// Anything else is rejected with a diagnostic instead of being lowered.
fn bool template_construct_ok(Node* n, int depth)
{
    if (n == null) { return true; }
    if (depth > LOWER_MAX_DEPTH) { return false; }
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_FLOAT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
        case N_EXPR_STRING:
        case N_EXPR_UNIT:
        case N_EXPR_IDENT:
        case N_EXPR_BINARY:
        case N_EXPR_UNARY:
        case N_EXPR_CALL:
        case N_EXPR_METHOD:
        case N_EXPR_FIELD:
        case N_EXPR_INDEX:
        case N_EXPR_TUPLE:
        case N_EXPR_CAST:
            break;
        default:
            return false;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (!template_construct_ok(n.children[i], depth + 1)) { return false; }
    }
    return true;
}

// Operands that can be evaluated zero, one or many times without changing
// behaviour: names, literals and arithmetic over them. Calls are NOT pure.
fn bool operand_is_pure(Node* n, int depth)
{
    if (n == null) { return true; }
    if (depth > LOWER_MAX_DEPTH) { return false; }
    switch (n.kind)
    {
        case N_EXPR_INT:
        case N_EXPR_FLOAT:
        case N_EXPR_BOOL:
        case N_EXPR_CHAR:
        case N_EXPR_UNIT:
        case N_EXPR_IDENT:
        case N_EXPR_BINARY:
        case N_EXPR_UNARY:
        case N_EXPR_CAST:
        case N_EXPR_TUPLE:
        case N_EXPR_FIELD:
            break;
        default:
            return false;
    }
    for (usz i = 0; i < n.child_count; i++)
    {
        if (!operand_is_pure(n.children[i], depth + 1)) { return false; }
    }
    return true;
}

fn bool binder_is_wild(Node* b)
{
    return b != null && b.kind == Nk.N_EXPR_IDENT && b.p.slen == 1 && b.p.sptr != null
        && b.p.sptr[0] == '_';
}

fn bool binder_is_literal(Node* b)
{
    if (b == null) { return false; }
    return b.kind == Nk.N_EXPR_INT || b.kind == Nk.N_EXPR_BOOL || b.kind == Nk.N_EXPR_CHAR;
}

fn bool binder_is_name(Node* b)
{
    return b != null && b.kind == Nk.N_EXPR_IDENT && b.name_id != 0 && !binder_is_wild(b);
}

// Records the evaluation-order skeleton of a template: which binder (by index)
// is read, and where a call completes. Operands are evaluated left to right
// BEFORE the dialect op, so an operand with effects may only be moved if no
// call (possible effect) sits ahead of it in the template.
struct TplEvents
{
    int[TPL_EVENTS_MAX] ev;    // >=0: binder index read; -1: a call completed
    usz count;
    bool overflow;
}

fn void tpl_events(Node* tmpl, Node* binds, TplEvents* out, int depth)
{
    if (tmpl == null) { return; }
    if (depth > LOWER_MAX_DEPTH) { out.overflow = true; return; }
    if (tmpl.kind == Nk.N_EXPR_IDENT && tmpl.name_id != 0)
    {
        for (usz i = 0; i < binds.child_count; i++)
        {
            Node* b = binds.children[i];
            if (binder_is_name(b) && b.name_id == tmpl.name_id)
            {
                if (out.count >= TPL_EVENTS_MAX) { out.overflow = true; return; }
                out.ev[out.count] = (int)i;
                out.count = out.count + 1;
                return;
            }
        }
    }
    for (usz i = 0; i < tmpl.child_count; i++) { tpl_events(tmpl.children[i], binds, out, depth + 1); }
    if (tmpl.kind == Nk.N_EXPR_CALL || tmpl.kind == Nk.N_EXPR_METHOD)
    {
        if (out.count >= TPL_EVENTS_MAX) { out.overflow = true; return; }
        out.ev[out.count] = -1;
        out.count = out.count + 1;
    }
}

// Does substituting these operands into this rule preserve evaluation of any
// operand that may have effects? (Each such operand: evaluated exactly once,
// in source order, with no template call completing before it.)
fn bool rule_guard_ok(LowerRule* r, Node* call)
{
    usz n = r.arity;
    bool any_impure = false;
    for (usz i = 0; i < n; i++)
    {
        if (!operand_is_pure(call.children[i + 1], 0)) { any_impure = true; }
    }
    if (!any_impure) { return true; }
    TplEvents te;
    te.count = 0;
    te.overflow = false;
    tpl_events(r.action, r.pattern_args, &te, 0);
    if (te.overflow) { return false; }
    int last = -1;
    bool seen_call = false;
    usz[32] reads;
    for (usz i = 0; i < 32; i++) { reads[i] = 0; }
    if (n > 32) { return false; }
    for (usz k = 0; k < te.count; k++)
    {
        int e = te.ev[k];
        if (e < 0) { seen_call = true; continue; }
        reads[(usz)e] = reads[(usz)e] + 1;
        if (!operand_is_pure(call.children[(usz)e + 1], 0))
        {
            if (seen_call) { return false; }            // a call runs before this operand
            if (e <= last) { return false; }            // reordered relative to another impure operand
            last = e;
        }
    }
    for (usz i = 0; i < n; i++)
    {
        if (!operand_is_pure(call.children[i + 1], 0) && reads[i] != 1) { return false; }  // dropped or duplicated
    }
    return true;
}

// 0 = no rule matches, 1 = rule matches and is safe, 2 = matches but the
// operand-effect guard forbids substituting these operands, 3 = the rule is
// an `emit_asm` template (no native lowering), 4 = a template name would be
// captured by a binder of the using item.
fn int DialectTable.try_rule(DialectTable* dt, Opcode* op, Node* call, Subst* s, LowerRule** out)
{
    usz argc = call.child_count > 0 ? call.child_count - 1 : 0;
    for (usz ri = 0; ri < op.rule_count; ri++)
    {
        LowerRule* r = &op.rules[ri];
        if (r.arity != argc) { continue; }
        s.clear();
        bool ok = true;
        for (usz i = 0; i < argc && ok; i++)
        {
            Node* binder = r.pattern_args.children[i];
            Node* arg = call.children[i + 1];
            if (binder_is_wild(binder)) { continue; }
            if (binder_is_literal(binder))
            {
                // literal pattern: matches only an operand that IS that literal
                ok = arg != null && arg.kind == binder.kind && arg.p.ival == binder.p.ival;
                continue;
            }
            if (!binder_is_name(binder)) { ok = false; break; }
            ok = s.bind(binder.name_id, arg);
        }
        if (!ok) { continue; }
        *out = r;
        if (r.asm_only) { return 3; }
        if (!dt.free_names_unshadowed(r.action, r.pattern_args, 0)) { return 4; }
        if (!rule_guard_ok(r, call)) { return 2; }
        return 1;
    }
    return 0;
}

// Register every `irdl` lowering rule in the tree against its opcode.
fn void DialectTable.register_lowerings(DialectTable* dt, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_DECL_INTERFACE && (n.flags & pfront_core::NF_SYNTHETIC) != 0
        && n.p.aux == IRDL_BLOCK_AUX)
    {
        for (usz i = 0; i < n.child_count; i++)
        {
            Node* rule = n.children[i];
            if (rule == null || rule.kind != Nk.N_CLAUSE) { continue; }
            dt.register_one_lowering(rule);
        }
        return;
    }
    for (usz i = 0; i < n.child_count; i++) { dt.register_lowerings(n.children[i], depth + 1); }
}

fn void DialectTable.register_one_lowering(DialectTable* dt, Node* rule)
{
    Node* head = rule.child_count > 0 ? rule.children[0] : null;
    if (head == null || head.kind != Nk.N_MODULE_PATH || head.child_count != 2)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3413, rule.line, rule.col,
                       "irdl rule head must be `Dialect.opcode`", dt.file);
        return;
    }
    uint dn = head.children[0].name_id;
    uint on = head.children[1].name_id;
    int did = dt.find_dialect(dn);
    if (did < 0)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3413, rule.line, rule.col,
                       "unknown dialect in irdl rule: this dialect is not declared", dt.file);
        return;
    }
    int oid = dt.find_opcode(did, on);
    if (oid < 0)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3413, rule.line, rule.col,
                       "unknown opcode in irdl rule: this opcode is not declared in its dialect", dt.file);
        return;
    }
    Node* binds = null;
    Node* action = null;
    if (rule.child_count == 4)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3422, rule.line, rule.col,
                       "guarded irdl rules are not supported: a guard needs a statically decidable condition, and silently ignoring it would change which rule fires",
                       dt.file);
        return;
    }
    if (rule.child_count == 3 && rule.children[1] != null
        && rule.children[1].kind == Nk.N_EXPR_ARRAY)
    {
        binds = rule.children[1];
        action = rule.children[2];
    }
    else if (rule.child_count == 2)
    {
        action = rule.children[1];      // nullary opcode: `D.op ↦ action`
    }
    if (action == null)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3415, rule.line, rule.col,
                       "irdl rule has no `↦ action` template", dt.file);
        return;
    }
    usz arity = binds == null ? 0 : binds.child_count;
    for (usz i = 0; i < arity; i++)
    {
        Node* b = binds.children[i];
        if (b != null && b.kind == Nk.N_EXPR_IDENT && b.p.aux == IRDL_VARIADIC_AUX_T)
        {
            dt.rules_rejected = dt.rules_rejected + 1;
            dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3422, rule.line, rule.col,
                           "variadic irdl operands (`..rest`) are not supported", dt.file);
            return;
        }
        if (!binder_is_name(b) && !binder_is_wild(b) && !binder_is_literal(b))
        {
            dt.rules_rejected = dt.rules_rejected + 1;
            dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3414, rule.line, rule.col,
                           "irdl operand must be a name, `_`, or an integer/bool/char literal", dt.file);
            return;
        }
        for (usz j = 0; j < i; j++)
        {
            Node* c = binds.children[j];
            if (binder_is_name(b) && binder_is_name(c) && b.name_id == c.name_id)
            {
                dt.rules_rejected = dt.rules_rejected + 1;
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3414, rule.line, rule.col,
                               "irdl rule binds the same operand name twice", dt.file);
                return;
            }
        }
    }
    if (!template_construct_ok(action, 0))
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3415, rule.line, rule.col,
                       "irdl template uses a construct outside the substitutable fragment (names, literals, arithmetic, calls)",
                       dt.file);
        return;
    }
    // `emit_asm("...")` is the spec's target-assembly template, but the
    // frontend defines no such function and AIR/PEAR have no inline-asm
    // lowering for it. Declaring such a rule is allowed (warning); USING it is
    // an error (E3219) instead of a placeholder or a crashing binary.
    // (a program that DEFINES a function named emit_asm gets an ordinary call)
    bool asm_rule = is_emit_asm_call(action) && !dt.is_global(action.children[0].name_id);
    if (asm_rule)
    {
        dt.asm_templates = dt.asm_templates + 1;
        dt.diags.warn(pfront_core::Phase.PH_RESOLVE, 3419, rule.line, rule.col,
                      "irdl template calls `emit_asm`, which has no native implementation here: uses of this opcode will be rejected",
                      dt.file);
    }
    else if (!dt.free_names_declared(action, binds == null ? dt.empty_binds() : binds, 0))
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3420, rule.line, rule.col,
                       "irdl template names something that is neither an operand nor a top-level declaration of this module",
                       dt.file);
        return;
    }
    Opcode* op = &dt.opcodes[oid];
    if (op.arity_known && op.arity != arity)
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3416, rule.line, rule.col,
                       "irdl rule operand count differs from this opcode's earlier rules", dt.file);
        return;
    }
    if (!dt.add_lowering(dn, on, binds == null ? dt.empty_binds() : binds, action))
    {
        dt.rules_rejected = dt.rules_rejected + 1;
        dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3416, rule.line, rule.col,
                       "too many irdl rules for this opcode", dt.file);
        return;
    }
    op.rules[op.rule_count - 1].asm_only = asm_rule;
    dt.rules_registered = dt.rules_registered + 1;
}

fn Node* DialectTable.empty_binds(DialectTable* dt)
{
    return dt.arena.node(Nk.N_EXPR_ARRAY, 0, 0);
}

// Validate every dialect-op use against the registry.
fn void DialectTable.validate_uses(DialectTable* dt, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    uint dn = 0;
    uint on = 0;
    if (split_dialect_call(n, &dn, &on))
    {
        int did = dt.find_dialect(dn);
        if (did >= 0)
        {
            dt.uses_validated = dt.uses_validated + 1;
            int oid = dt.find_opcode(did, on);
            if (oid < 0)
            {
                dt.unknown_opcode = dt.unknown_opcode + 1;
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3210, n.line, n.col,
                               "unknown opcode in this dialect", dt.file);
            }
            else
            {
                Opcode* op = &dt.opcodes[oid];
                op.use_count = op.use_count + 1;
                usz argc = n.child_count > 0 ? n.child_count - 1 : 0;
                if (op.arity_known && argc != op.arity)
                {
                    dt.arity_mismatch = dt.arity_mismatch + 1;
                    dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3211, n.line, n.col,
                                   "wrong number of operands for this dialect opcode",
                                   dt.file);
                }
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++) { dt.validate_uses(n.children[i], depth + 1); }
}

// Lower one dialect call by instantiating its rule template.
fn Node* DialectTable.lower_call(DialectTable* dt, Node* call)
{
    uint dn = 0;
    uint on = 0;
    if (!split_dialect_call(call, &dn, &on)) { return null; }
    int did = dt.find_dialect(dn);
    if (did < 0) { return null; }
    int oid = dt.find_opcode(did, on);
    if (oid < 0) { return null; }
    Opcode* op = &dt.opcodes[oid];
    if (op.rule_count == 0) { return null; }
    if (dt.fuel <= 0) { return null; }

    Subst s;
    LowerRule* r = null;
    if (dt.try_rule(op, call, &s, &r) != 1) { return null; }
    dt.fuel = dt.fuel - 1;
    r.fire_count = r.fire_count + 1;
    dt.lowered = dt.lowered + 1;
    return s.instantiate(dt.arena, r.action, 0);
}

// After lowering, a surviving use of a declared opcode has NO executable
// meaning: refuse it rather than let it compile to a placeholder value.
fn void DialectTable.diagnose_unlowered(DialectTable* dt, Node* n, int depth)
{
    if (n == null || depth > 200) { return; }
    if (n.kind == Nk.N_DECL_INTERFACE && (n.flags & pfront_core::NF_SYNTHETIC) != 0) { return; }
    uint dn = 0;
    uint on = 0;
    if (split_dialect_call(n, &dn, &on))
    {
        int did = dt.find_dialect(dn);
        int oid = did < 0 ? -1 : dt.find_opcode(did, on);
        if (oid >= 0)
        {
            Subst s;
            LowerRule* r = null;
            int st = dt.try_rule(&dt.opcodes[oid], n, &s, &r);
            dt.unlowered = dt.unlowered + 1;
            if (st == 0)
            {
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3412, n.line, n.col,
                               "dialect opcode has no lowering rule for these operands, so it has no executable meaning",
                               dt.file);
            }
            else if (st == 3)
            {
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3419, n.line, n.col,
                               "this dialect opcode lowers to `emit_asm`, which has no native implementation here",
                               dt.file);
            }
            else if (st == 4)
            {
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3421, n.line, n.col,
                               "a name in the lowering template is shadowed by a local binder at this use",
                               dt.file);
            }
            else if (st == 2)
            {
                dt.guard_blocked = dt.guard_blocked + 1;
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3417, n.line, n.col,
                               "dialect lowering would duplicate, drop or reorder an operand with effects; bind it to a name first",
                               dt.file);
            }
            else
            {
                dt.diags.error(pfront_core::Phase.PH_RESOLVE, 3418, n.line, n.col,
                               "dialect lowering did not reach a fixpoint within its fuel/depth limit",
                               dt.file);
            }
        }
    }
    for (usz i = 0; i < n.child_count; i++) { dt.diagnose_unlowered(n.children[i], depth + 1); }
}

// Dialect ELABORATION is semantics, not an optional analysis: it runs with or
// without the theory layer so a dialect use never reaches AIR unlowered.
// Lower one module container item by item so name hygiene can see the binders
// of the item being lowered.
fn void DialectTable.lower_items(DialectTable* dt, Node* container, int depth)
{
    if (container == null || depth > 8) { return; }
    for (usz i = 0; i < container.child_count; i++)
    {
        Node* item = container.children[i];
        if (item == null) { continue; }
        if (item.kind == Nk.N_MODULE) { dt.lower_items(item, depth + 1); continue; }
        dt.local_count = 0;
        dt.locals_unknown = false;
        dt.collect_locals(item, 0);
        Node* out = dt.lower_tree(item, 0);
        container.set_child(i, out);
        dt.diagnose_unlowered(out, 0);
    }
}

fn Node* DialectTable.elaborate(DialectTable* dt, Node* root)
{
    dt.register_dialects(root, 0);
    dt.collect_globals(root, 0);
    dt.register_lowerings(root, 0);
    dt.validate_uses(root, 0);
    if (dt.opcode_count == 0 || root == null) { return root; }
    if (root.kind != Nk.N_PROGRAM && root.kind != Nk.N_MODULE)
    {
        dt.locals_unknown = true;     // unknown shape: assume every template name may be shadowed
        Node* whole = dt.lower_tree(root, 0);
        dt.diagnose_unlowered(whole, 0);
        return whole;
    }
    dt.lower_items(root, 0);
    return root;
}

// Lower to a fixpoint: a lowered action may itself use dialect opcodes.
fn Node* DialectTable.lower_tree(DialectTable* dt, Node* n, int depth)
{
    if (n == null || depth > LOWER_MAX_DEPTH) { return n; }
    for (usz i = 0; i < n.child_count; i++)
    {
        n.set_child(i, dt.lower_tree(n.children[i], depth + 1));
    }
    Node* out = dt.lower_call(n);
    if (out == null) { return n; }
    // Re-lower the produced term: one dialect may target a lower dialect.
    return dt.lower_tree(out, depth + 1);
}

fn void DialectTable.report(DialectTable* dt)
{
    printf("  irdl dialects    : %d dialects, %d opcodes, %d uses validated\n",
           (int)dt.dialect_count, (int)dt.opcode_count, (int)dt.uses_validated);
    if (dt.unknown_dialect > 0)
    {
        printf("  irdl unknown-dia : %d reference(s) to a dialect that is not declared\n",
               (int)dt.unknown_dialect);
    }
    printf("  irdl lowering    : %d rules registered (%d rejected), %d uses lowered, %d unlowered, %d unknown-op, %d arity errors\n",
           (int)dt.rules_registered, (int)dt.rules_rejected, (int)dt.lowered,
           (int)dt.unlowered, (int)dt.unknown_opcode, (int)dt.arity_mismatch);
}

// ════════════════════════════════════════════════════════════════════════════
// PART B — PGL decision-tree compiler
// ════════════════════════════════════════════════════════════════════════════
const usz PG_MAX_ROWS = 256;
const usz PG_MAX_COLS = 32;
const usz DT_POOL     = 16384;

enum DtKind : int
{
    DT_FAIL,        // no clause matches
    DT_LEAF,        // an action was selected
    DT_SWITCH       // test a column, branch on constructor
}

struct DtCase
{
    int   ctor_key;      // top_key of the constructor
    usz   ctor_arity;
    int   target;        // child node index
}

const usz DT_MAX_CASES = 32;

struct DtNode
{
    DtKind          kind;
    int             column;         // which occurrence is tested
    Node*           action;         // DT_LEAF
    DtCase[DT_MAX_CASES] cases;
    usz             case_count;
    int             default_target; // -1 when absent
    int             depth;
}

struct PgRow
{
    Node*[PG_MAX_COLS] cols;
    usz                width;
    Node*              action;
    bool               live;
}

struct PgMatrix
{
    PgRow[PG_MAX_ROWS] rows;
    usz                row_count;
    usz                width;
}

fn void PgMatrix.init(PgMatrix* m, usz width)
{
    m.row_count = 0;
    m.width = width < PG_MAX_COLS ? width : PG_MAX_COLS;
}

fn bool PgMatrix.add_row(PgMatrix* m, Node** cols, usz n, Node* action)
{
    if (m.row_count >= PG_MAX_ROWS) { return false; }
    PgRow* r = &m.rows[m.row_count];
    r.width = n < PG_MAX_COLS ? n : PG_MAX_COLS;
    for (usz i = 0; i < r.width; i++) { r.cols[i] = cols[i]; }
    r.action = action;
    r.live = true;
    m.row_count = m.row_count + 1;
    return true;
}

struct PgenCompiler
{
    DtNode[DT_POOL]        pool;
    usz                    pool_count;
    Arena*                 arena;
    pfront_core::DiagBag*  diags;
    pfront_core::Interner* interner;
    char*                  file;

    usz  trees_built;
    usz  leaves;
    usz  switches;
    usz  redundant_rows;
    usz  last_redundant;   // redundancies found in the most recent tree
    /*
     Per-clause reachability, keyed by the clause's action node.

     A clause is REDUNDANT only when it is shadowed on EVERY path. The
     original code incremented a counter inside compile(), which recurses
     once per constructor branch, so it was counting shadowings rather
     than clauses -- and any shadowing at all was reported as redundancy.

     Both halves were wrong on ordinary code. `match n | 1 | _` claimed
     the catch-all could never match: inside the branch for `1` the
     literal row always matches first, so the wildcard IS shadowed there
     -- but it is the only thing that matches on the default path. And
     `| 1 | 2 | ... | _` scored exactly one redundancy per literal arm,
     because the wildcard is shadowed once per branch.

     So both facts are recorded per clause and combined at the end:
     shadowed somewhere AND emitted nowhere means genuinely unreachable.
    */
    Node*[PG_MAX_ROWS] clause_id;      // action node, the clause's identity
    bool[PG_MAX_ROWS]  clause_emitted; // reached as a leaf on some path
    bool[PG_MAX_ROWS]  clause_shadowed;// shadowed on some path
    usz  clause_count;
    int  max_depth;
    usz  total_nodes;
}

fn void PgenCompiler.init(PgenCompiler* c, Arena* a, pfront_core::DiagBag* d,
                          pfront_core::Interner* it, char* file)
{
    c.pool_count = 0;
    c.arena = a;
    c.diags = d;
    c.interner = it;
    c.file = file;
    c.trees_built = 0;
    c.leaves = 0;
    c.switches = 0;
    c.redundant_rows = 0;
    c.last_redundant = 0;
    c.clause_count = 0;
    c.max_depth = 0;
    c.total_nodes = 0;
}

fn int PgenCompiler.alloc_node(PgenCompiler* c, DtKind k, int depth)
{
    if (c.pool_count >= DT_POOL) { return -1; }
    int id = (int)c.pool_count;
    c.pool_count = c.pool_count + 1;
    DtNode* n = &c.pool[id];
    n.kind = k;
    n.column = 0;
    n.action = null;
    n.case_count = 0;
    n.default_target = -1;
    n.depth = depth;
    if (depth > c.max_depth) { c.max_depth = depth; }
    c.total_nodes = c.total_nodes + 1;
    return id;
}

// Is every column of this row a wildcard? Then the row matches unconditionally.
fn bool row_all_wildcards(PgRow* r)
{
    for (usz i = 0; i < r.width; i++)
    {
        Node* c = r.cols[i];
        if (c == null) { continue; }
        if (c.kind == Nk.N_PAT_WILDCARD || c.kind == Nk.N_PAT_IDENT) { continue; }
        if (theory_term::is_pattern_var(c)) { continue; }
        return false;
    }
    return true;
}

// Column-selection heuristic: pick the column with the MOST distinct
// constructors. Branching on the most discriminating column first reduces the
// number of tests along every path. Correctness does not depend on the choice.
fn int PgMatrix.best_column(PgMatrix* m)
{
    int best_col = -1;
    usz best_score = 0;
    for (usz c = 0; c < m.width; c++)
    {
        int[DT_MAX_CASES] seen;
        usz n = 0;
        bool found_any = false;
        for (usz r = 0; r < m.row_count; r++)
        {
            if (!m.rows[r].live) { continue; }
            if (c >= m.rows[r].width) { continue; } // row shorter than matrix width — treat as wildcard
            Node* p = m.rows[r].cols[c];
            if (p == null) { continue; }
            if (p.kind == Nk.N_PAT_WILDCARD || theory_term::is_pattern_var(p)) { continue; }
            found_any = true;
            int k = theory_term::top_key(p);
            bool dup = false;
            for (usz i = 0; i < n; i++) { if (seen[i] == k) { dup = true; break; } }
            if (!dup && n < DT_MAX_CASES) { seen[n] = k; n = n + 1; }
        }
        if (found_any && n > best_score) { best_score = n; best_col = (int)c; }
    }
    return best_col;
}

// Specialise: keep rows whose column-`col` pattern matches constructor `key`,
// expanding that pattern's children into the row.
fn void specialise_matrix(PgMatrix* src, int col, int key, usz arity, PgMatrix* dst)
{
    dst.init(src.width + arity);
    for (usz r = 0; r < src.row_count; r++)
    {
        PgRow* row = &src.rows[r];
        if (!row.live) { continue; }
        Node* p = null;
        bool wild;
        if ((usz)col >= row.width)
        {
            // Row shorter than col — treat as wildcard (missing column)
            wild = true;
        }
        else
        {
            p = row.cols[col];
            wild = p == null || p.kind == Nk.N_PAT_WILDCARD
                 || theory_term::is_pattern_var(p);
        }
        if (!wild && theory_term::top_key(p) != key) { continue; }

        Node*[PG_MAX_COLS] cols;
        usz w = 0;
        // Sub-patterns of the matched constructor first.
        for (usz k = 0; k < arity && w < PG_MAX_COLS; k++)
        {
            cols[w] = wild ? null : p.child(k);
            w = w + 1;
        }
        // Then the untouched columns.
        for (usz k = 0; k < row.width && w < PG_MAX_COLS; k++)
        {
            if (k == (usz)col) { continue; }
            cols[w] = row.cols[k];
            w = w + 1;
        }
        dst.add_row(&cols[0], w, row.action);
    }
}

// Default matrix: rows whose column-`col` pattern is a wildcard, that column
// removed.
fn void default_matrix(PgMatrix* src, int col, PgMatrix* dst)
{
    dst.init(src.width > 0 ? src.width - 1 : 0);
    for (usz r = 0; r < src.row_count; r++)
    {
        PgRow* row = &src.rows[r];
        if (!row.live) { continue; }
        Node* p = null;
        bool wild;
        if ((usz)col >= row.width)
        {
            wild = true;
        }
        else
        {
            p = row.cols[col];
            wild = p == null || p.kind == Nk.N_PAT_WILDCARD
                 || theory_term::is_pattern_var(p);
        }
        if (!wild) { continue; }
        Node*[PG_MAX_COLS] cols;
        usz w = 0;
        for (usz k = 0; k < row.width && w < PG_MAX_COLS; k++)
        {
            if (k == (usz)col) { continue; }
            cols[w] = row.cols[k];
            w = w + 1;
        }
        dst.add_row(&cols[0], w, row.action);
    }
}

// The core of Maranget's algorithm.
/*
 Find (or create) the per-clause slot for an action node.

 The action is the one field specialise_matrix copies unchanged into
 every sub-matrix, so it is the stable identity of a source clause across
 the whole recursion.
*/
fn int PgenCompiler.clause_slot(PgenCompiler* c, Node* action)
{
    if (action == null) { return -1; }
    for (usz i = 0; i < c.clause_count; i++)
    {
        if (c.clause_id[i] == action) { return (int)i; }
    }
    if (c.clause_count >= PG_MAX_ROWS) { return -1; }
    int id = (int)c.clause_count;
    c.clause_id[id] = action;
    c.clause_emitted[id] = false;
    c.clause_shadowed[id] = false;
    c.clause_count = c.clause_count + 1;
    return id;
}

fn void PgenCompiler.note_emitted(PgenCompiler* c, Node* action)
{
    int i = c.clause_slot(action);
    if (i >= 0) { c.clause_emitted[i] = true; }
}

fn void PgenCompiler.note_shadowed(PgenCompiler* c, Node* action)
{
    int i = c.clause_slot(action);
    if (i >= 0) { c.clause_shadowed[i] = true; }
    else { c.redundant_rows = c.redundant_rows + 1; }   // no identity: count it
}

/*
 Combine the two facts. Called once the whole tree is built, because
 "shadowed on every path" cannot be known until every path exists.
*/
fn void PgenCompiler.finish_redundancy(PgenCompiler* c)
{
    for (usz i = 0; i < c.clause_count; i++)
    {
        if (c.clause_shadowed[i] && !c.clause_emitted[i])
        {
            c.redundant_rows = c.redundant_rows + 1;
        }
    }
}

fn int PgenCompiler.compile(PgenCompiler* c, PgMatrix* m, int depth)
{
    if (depth > 32) { return c.alloc_node(DtKind.DT_FAIL, depth); }

    // No rows: nothing matches.
    usz live = 0;
    usz first_live = 0;
    for (usz r = 0; r < m.row_count; r++)
    {
        if (m.rows[r].live) { if (live == 0) { first_live = r; } live = live + 1; }
    }
    if (live == 0) { return c.alloc_node(DtKind.DT_FAIL, depth); }

    // First live row all wildcards: it always matches, emit its action.
    if (row_all_wildcards(&m.rows[first_live]))
    {
        int id = c.alloc_node(DtKind.DT_LEAF, depth);
        if (id >= 0)
        {
            c.pool[id].action = m.rows[first_live].action;
            c.leaves = c.leaves + 1;
        }
        // This clause fires on this path.
        c.note_emitted(m.rows[first_live].action);
        // Rows after an unconditionally-matching one cannot fire HERE.
        // Whether they fire anywhere is decided in finish_redundancy.
        for (usz r = first_live + 1; r < m.row_count; r++)
        {
            if (m.rows[r].live) { c.note_shadowed(m.rows[r].action); }
        }
        return id;
    }

    int col = m.best_column();
    if (col < 0) { return c.alloc_node(DtKind.DT_FAIL, depth); }

    int id = c.alloc_node(DtKind.DT_SWITCH, depth);
    if (id < 0) { return -1; }
    c.pool[id].column = col;
    c.switches = c.switches + 1;

    // Collect the distinct constructors in the chosen column.
    int[DT_MAX_CASES] keys;
    usz[DT_MAX_CASES] arities;
    usz nk = 0;
    for (usz r = 0; r < m.row_count; r++)
    {
        if (!m.rows[r].live) { continue; }
        if ((usz)col >= m.rows[r].width) { continue; }
        Node* p = m.rows[r].cols[col];
        if (p == null || p.kind == Nk.N_PAT_WILDCARD
            || theory_term::is_pattern_var(p)) { continue; }
        int k = theory_term::top_key(p);
        bool dup = false;
        for (usz i = 0; i < nk; i++) { if (keys[i] == k) { dup = true; break; } }
        if (dup || nk >= DT_MAX_CASES) { continue; }
        keys[nk] = k;
        /*
         A literal's child is its VALUE, not a sub-pattern.

         `p.child_count` is the right arity for a constructor pattern --
         `Some(x)` has one sub-pattern to match against a new column --
         but N_PAT_LITERAL wraps the constant it compares to. Treating
         that as arity 1 made specialise_matrix open a column for it, so
         the sub-matrix had a column no row could discharge: the literal
         row filled it with the constant and a wildcard row filled it with
         null, and the wildcard was then reported as shadowing nothing
         while itself being flagged redundant.

         Concretely, `match n | 1 | _` claimed the catch-all could never
         match, which is false for every n other than 1.

         A literal is a leaf: matching it consumes the column and opens
         none.
        */
        arities[nk] = p.kind == Nk.N_PAT_LITERAL ? 0 : p.child_count;
        nk = nk + 1;
    }

    for (usz i = 0; i < nk; i++)
    {
        PgMatrix* sub = (PgMatrix*)malloc(PgMatrix::size);
        if (sub == null) { continue; }
        specialise_matrix(m, col, keys[i], arities[i], sub);
        int child = c.compile(sub, depth + 1);
        free((void*)sub);
        if (c.pool[id].case_count < DT_MAX_CASES)
        {
            usz ci = c.pool[id].case_count;
            c.pool[id].cases[ci].ctor_key = keys[i];
            c.pool[id].cases[ci].ctor_arity = arities[i];
            c.pool[id].cases[ci].target = child;
            c.pool[id].case_count = ci + 1;
        }
    }

    PgMatrix* dm = (PgMatrix*)malloc(PgMatrix::size);
    if (dm != null)
    {
        default_matrix(m, col, dm);
        bool found_any = false;
        for (usz r = 0; r < dm.row_count; r++) { if (dm.rows[r].live) { found_any = true; break; } }
        if (found_any) { c.pool[id].default_target = c.compile(dm, depth + 1); }
        free((void*)dm);
    }
    return id;
}

// Build a decision tree from a set of clause patterns.
fn int PgenCompiler.build_from_clauses(PgenCompiler* c, Node* owner)
{
    if (owner == null) { return -1; }
    PgMatrix* m = (PgMatrix*)malloc(PgMatrix::size);
    if (m == null) { return -1; }
    m.init(1);
    for (usz i = 0; i < owner.child_count; i++)
    {
        Node* cl = owner.children[i];
        if (cl == null) { continue; }
        if (cl.kind != Nk.N_CLAUSE && cl.kind != Nk.N_MATCH_ARM) { continue; }
        Node* pat = cl.child(0);
        Node* action = cl.child_count > 1 ? cl.children[cl.child_count - 1] : null;
        Node*[PG_MAX_COLS] cols;
        cols[0] = pat;
        m.add_row(&cols[0], 1, action);
    }
    if (m.row_count == 0) { free((void*)m); return -1; }
    usz slots_before = c.clause_count;
    usz red_before = c.redundant_rows;
    int root = c.compile(m, 0);
    c.finish_redundancy();
    c.last_redundant = c.redundant_rows - red_before;
    // Each tree gets a fresh clause namespace: two matches in one file
    // have unrelated clauses and must not share slots.
    c.clause_count = slots_before;
    c.trees_built = c.trees_built + 1;
    free((void*)m);
    return root;
}

fn void PgenCompiler.report(PgenCompiler* c)
{
    printf("  pgl trees        : %d built, %d nodes (%d leaves, %d switches)\n",
           (int)c.trees_built, (int)c.total_nodes, (int)c.leaves, (int)c.switches);
    printf("  pgl quality      : depth %d, %d redundant clauses\n",
           c.max_depth, (int)c.redundant_rows);
}

// Report clauses the decision tree proved unreachable.
/*
 Warn about the clause set just built.

 Tests `last_redundant` -- the count from THIS tree -- not the running
 total. Testing the total meant that once any match in the file had a
 redundant clause, every clause set compiled afterwards was warned about
 too, so a correct rewrite rule set two declarations later was blamed for
 someone else's dead arm.
*/
fn void PgenCompiler.report_redundant(PgenCompiler* c, Node* owner)
{
    if (c.last_redundant == 0 || owner == null) { return; }
    c.diags.warn(pfront_core::Phase.PH_RESOLVE, 4040, owner.line, owner.col,
                 "some clauses can never match (an earlier clause always succeeds)",
                 c.file);
}
