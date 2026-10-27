// PEAR 2's conservative AIR optimization pipeline.
//
// Pass 1 is an expression-local, bottom-up rewrite: constant folding, algebraic
// and boolean identities, power-of-two strength reduction, shift combination,
// literal-branch selection, and the restricted constant-let specializations.
// It avoids target-dependent type guesses and rewrites integer constant
// expressions only when host arithmetic is defined and the result fits the
// resolved integer width (or the default i64 literal representation). Integer
// identities require matching resolved representations; boolean branches must
// reduce to literals. Unsupported or ambiguous expressions remain unchanged.
//
// Pass 2 removes dead bindings (see the comment above opt_droppable_value); it
// runs only at -O2 and above. Pass 3 is the first whole-body analysis in the
// pipeline: a name census it spends on constant propagation and on removing
// bindings whose initializer is pure but unused. It runs only at -O3, which is
// what makes the top tier a different *set* of passes rather than the same set
// repeated more often.
//
// The three passes are driven by optimize_module_at, which is where the -O tier
// selects which passes run; pear2c then iterates that set to a fixed point and
// hands the result to LLVM for the machine-level work the AIR is not the right
// level for (mem2reg/SROA, CSE, inlining, loops). Every rewrite is checked by
// the AIR verifier afterwards, so a pass that produces a structurally invalid
// module fails the build instead of reaching the backend.
module pear2_opt;

import air_ir;

struct OptStats
{
    uint rewrites;
    uint constant_folds;
    uint operand_rewrites;
    uint strength_reductions;
    uint shift_combinations;
    uint branch_reductions;
    uint let_specializations;
    uint dead_bindings;      // pass 2: unused literal/variable bindings removed
    uint propagated_bindings; // pass 3: constants substituted at every use in the body
    uint pure_dead_bindings; // pass 3: unused pure producers removed
    uint cse_replacements;   // pass 3: repeated pure values bound to an existing name
    uint loop_eliminations;  // pass 3: `while false` removed
    uint literal_matches;    // pass 3: match on a literal subject folded to one arm
    uint dead_commands;      // pass 3: commands after an unconditional transfer removed
    uint reassociations;     // pass 1: (x op c1) op c2 folded into x op (c1 op c2)
    uint self_folds;         // pass 1: `x - x`, `x ^ x`, `eq x x`, ... decided statically
    uint match_folds;        // pass 3: a one-armed match replaced by its body
    uint copy_bindings;      // pass 3: `let x = y` propagated into the body's uses
    bool drop_dead;          // pass 2 is enabled at -O2 and above
    bool propagate_bindings; // pass 3 is enabled at -O3 only
    // Pass 3's let-chain value table. Scoped by save/restore around each
    // descendant scope, so an entry is only ever visible where its binder is.
    char*[16] cse_names;
    AirPrd*[16] cse_values;
    int cse_count;
    AirArena* arena;
}

const long OPT_LONG_MIN = -9223372036854775807L - 1L;
const long OPT_LONG_MAX = 9223372036854775807L;

fn bool opt_integer_type(AirTyp* t)
{
    if (t == null) { return false; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8: case ATYP_I16: case ATYP_U16:
        case ATYP_I32: case ATYP_U32: case ATYP_I64: case ATYP_U64:
        case ATYP_ISZ: case ATYP_USZ: case ATYP_I128: case ATYP_U128:
        case ATYP_CHAR: return true;
        default: return false;
    }
}

fn int opt_integer_bits(AirTyp* t)
{
    if (t == null || t.tag == ATYP_INFER) { return 64; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8: return 8;
        case ATYP_I16: case ATYP_U16: return 16;
        case ATYP_I32: case ATYP_U32: case ATYP_CHAR: return 32;
        case ATYP_I64: case ATYP_U64: case ATYP_ISZ: case ATYP_USZ: return 64;
        case ATYP_I128: case ATYP_U128: return 128;
        default: return 0;
    }
}

fn bool opt_unsigned(AirTyp* t)
{
    if (t == null) { return false; }
    return t.tag == ATYP_U8 || t.tag == ATYP_U16 || t.tag == ATYP_U32 ||
           t.tag == ATYP_U64 || t.tag == ATYP_USZ || t.tag == ATYP_U128 || t.tag == ATYP_CHAR;
}

fn bool opt_integer_fits(long value, int bits, bool uns)
{
    if (bits <= 0 || bits > 128) { return false; }
    if (uns && value < 0) { return false; }
    if (bits == 64 || bits == 128) { return true; }
    long edge = 1L << (uns ? bits : bits - 1);
    return uns ? value < edge : (value >= -edge && value < edge);
}

fn bool opt_safe_add(long a, long b, long* result)
{
    if ((b > 0 && a > OPT_LONG_MAX - b) || (b < 0 && a < OPT_LONG_MIN - b)) { return false; }
    *result = a + b;
    return true;
}

fn bool opt_safe_sub(long a, long b, long* result)
{
    if ((b < 0 && a > OPT_LONG_MAX + b) || (b > 0 && a < OPT_LONG_MIN + b)) { return false; }
    *result = a - b;
    return true;
}

fn bool opt_safe_mul(long a, long b, long* result)
{
    if (a == 0 || b == 0) { *result = 0; return true; }
    if (a == -1) { if (b == OPT_LONG_MIN) { return false; } *result = -b; return true; }
    if (b == -1) { if (a == OPT_LONG_MIN) { return false; } *result = -a; return true; }
    if (a > 0)
    {
        if ((b > 0 && a > OPT_LONG_MAX / b) || (b < 0 && b < OPT_LONG_MIN / a)) { return false; }
    }
    else
    {
        if ((b > 0 && a < OPT_LONG_MIN / b) || (b < 0 && a < OPT_LONG_MAX / b)) { return false; }
    }
    *result = a * b;
    return true;
}

fn bool opt_integer_from_bits(ulong raw, int bits, bool uns, long* result)
{
    if (bits <= 0 || bits > 64) { return false; }
    ulong mask = bits == 64 ? ~0UL : ((1UL << bits) - 1UL);
    raw &= mask;
    if (uns)
    {
        if (raw > (ulong)OPT_LONG_MAX) { return false; }
        *result = (long)raw;
        return true;
    }
    ulong sign = 1UL << (bits - 1);
    if ((raw & sign) == 0) { *result = (long)raw; return true; }
    if (bits == 64)
    {
        *result = OPT_LONG_MIN + (long)(raw - sign);
        return true;
    }
    *result = (long)raw - (1L << bits);
    return true;
}

fn bool opt_literal_zero(AirPrd* p)
{
    return p != null && p.tag == APRD_INT && p.ival == 0;
}

fn bool opt_literal_one(AirPrd* p)
{
    return p != null && p.tag == APRD_INT && p.ival == 1;
}

fn bool opt_all_ones_literal(AirPrd* operation, AirPrd* literal)
{
    if (operation == null || literal == null || literal.tag != APRD_INT) { return false; }
    AirTyp* type = opt_resolved_integer_type(operation);
    if (type == null) { return false; }
    int bits = opt_integer_bits(type);
    if (bits <= 0 || bits > 64) { return false; }
    if (!opt_unsigned(type)) { return literal.ival == -1; }
    if (bits == 64) { return false; } // The full unsigned mask is not representable by AirPrd.ival.
    ulong mask = (1UL << bits) - 1UL;
    return literal.ival >= 0 && (ulong)literal.ival == mask;
}

fn bool opt_same_name(char* a, char* b)
{
    if (a == null || b == null) { return a == b; }
    usz i = 0;
    while (a[i] != 0 && b[i] != 0)
    {
        if (a[i] != b[i]) { return false; }
        i++;
    }
    return a[i] == b[i];
}

fn bool opt_bool_hint(AirTyp* t)
{
    return t == null || t.tag == ATYP_INFER || t.tag == ATYP_BOOL;
}

fn bool opt_condition_tree(AirPrd* p, int depth)
{
    if (p == null || depth >= 64 || !opt_bool_hint(p.ty)) { return false; }
    if (p.tag == APRD_BOOL || p.tag == APRD_VAR) { return true; }
    if (p.tag == APRD_UNOP)
    {
        return p.uop == AUN_NOT && p.sub_count == 1 && opt_condition_tree(p.subs[0], depth + 1);
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2 &&
        (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR || p.bop == ABIN_LAND || p.bop == ABIN_LOR))
    {
        return opt_condition_tree(p.subs[0], depth + 1) && opt_condition_tree(p.subs[1], depth + 1);
    }
    return false;
}

fn bool OptStats.substitute_bool_var(OptStats* s, AirPrd* p, char* name, AirPrd* value, int depth)
{
    if (p == null || value == null || depth >= 64) { return false; }
    if (p.tag == APRD_VAR)
    {
        if (opt_same_name(p.name, name) && opt_bool_hint(p.ty)) { s.replace_with_prd(p, value); return true; }
        return false;
    }
    if (p.tag == APRD_UNOP && p.uop == AUN_NOT && p.sub_count == 1)
    {
        return s.substitute_bool_var(p.subs[0], name, value, depth + 1);
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2 &&
        (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR || p.bop == ABIN_LAND || p.bop == ABIN_LOR))
    {
        bool left = s.substitute_bool_var(p.subs[0], name, value, depth + 1);
        bool right = s.substitute_bool_var(p.subs[1], name, value, depth + 1);
        return left || right;
    }
    return false;
}

fn AirTyp* opt_resolved_integer_type(AirPrd* p)
{
    if (p == null || p.ty == null || p.ty.tag == ATYP_INFER) { return null; }
    return opt_integer_type(p.ty) ? p.ty : null;
}

fn bool opt_integer_hint(AirTyp* t)
{
    return t == null || t.tag == ATYP_INFER || opt_integer_type(t);
}

fn bool opt_integer_expr_tree(AirPrd* p, int depth)
{
    if (p == null || depth >= 64 || !opt_integer_hint(p.ty)) { return false; }
    if (p.tag == APRD_INT || p.tag == APRD_VAR) { return true; }
    if (p.tag == APRD_UNOP && p.sub_count == 1 && (p.uop == AUN_NEG || p.uop == AUN_BITNOT))
    {
        return opt_integer_expr_tree(p.subs[0], depth + 1);
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        bool supported = p.bop == ABIN_ADD || p.bop == ABIN_SUB || p.bop == ABIN_MUL || p.bop == ABIN_DIV ||
                         p.bop == ABIN_MOD || p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR ||
                         p.bop == ABIN_SHL || p.bop == ABIN_SHR;
        return supported && opt_integer_expr_tree(p.subs[0], depth + 1) && opt_integer_expr_tree(p.subs[1], depth + 1);
    }
    return false;
}

fn bool opt_integer_substitution_compatible(AirPrd* variable, AirPrd* value)
{
    if (variable == null || value == null || variable.tag != APRD_VAR || value.tag != APRD_INT || !opt_integer_hint(variable.ty) || !opt_integer_hint(value.ty)) { return false; }
    AirTyp* variable_type = opt_resolved_integer_type(variable);
    AirTyp* value_type = opt_resolved_integer_type(value);
    if (variable_type == null) { return true; }
    if (value_type != null)
    {
        return opt_integer_bits(variable_type) == opt_integer_bits(value_type) && opt_unsigned(variable_type) == opt_unsigned(value_type);
    }
    return opt_integer_fits(value.ival, opt_integer_bits(variable_type), opt_unsigned(variable_type));
}

fn bool opt_validate_integer_substitution(AirPrd* p, char* name, AirPrd* value, int depth)
{
    if (p == null || depth >= 64) { return false; }
    if (p.tag == APRD_VAR) { return !opt_same_name(p.name, name) || opt_integer_substitution_compatible(p, value); }
    if (p.tag == APRD_UNOP && p.sub_count == 1 && (p.uop == AUN_NEG || p.uop == AUN_BITNOT))
    {
        return opt_validate_integer_substitution(p.subs[0], name, value, depth + 1);
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        return opt_validate_integer_substitution(p.subs[0], name, value, depth + 1) &&
               opt_validate_integer_substitution(p.subs[1], name, value, depth + 1);
    }
    return true;
}

fn bool OptStats.substitute_integer_var(OptStats* s, AirPrd* p, char* name, AirPrd* value, int depth)
{
    if (p == null || depth >= 64) { return false; }
    if (p.tag == APRD_VAR)
    {
        if (opt_same_name(p.name, name) && opt_integer_substitution_compatible(p, value)) { s.replace_with_prd(p, value); return true; }
        return false;
    }
    if (p.tag == APRD_UNOP && p.sub_count == 1 && (p.uop == AUN_NEG || p.uop == AUN_BITNOT))
    {
        return s.substitute_integer_var(p.subs[0], name, value, depth + 1);
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        bool left = s.substitute_integer_var(p.subs[0], name, value, depth + 1);
        bool right = s.substitute_integer_var(p.subs[1], name, value, depth + 1);
        return left || right;
    }
    return false;
}

fn bool opt_can_return_operand(AirPrd* operation, AirPrd* operand)
{
    AirTyp* result_type = opt_resolved_integer_type(operation);
    AirTyp* operand_type = opt_resolved_integer_type(operand);
    if (operand_type == null || result_type == null) { return false; }
    return opt_integer_bits(result_type) == opt_integer_bits(operand_type) && opt_unsigned(result_type) == opt_unsigned(operand_type);
}

fn bool opt_integer_operation(AirPrd* p)
{
    if (p == null || p.tag != APRD_BINOP || p.sub_count != 2 || p.subs[0] == null || p.subs[1] == null) { return false; }
    bool comparison = p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE;
    if (p.ty != null && p.ty.tag != ATYP_INFER && (comparison ? p.ty.tag != ATYP_BOOL : !opt_integer_type(p.ty))) { return false; }
    AirTyp* left = opt_resolved_integer_type(p.subs[0]);
    AirTyp* right = opt_resolved_integer_type(p.subs[1]);
    if ((p.subs[0].ty != null && p.subs[0].ty.tag != ATYP_INFER && left == null) ||
        (p.subs[1].ty != null && p.subs[1].ty.tag != ATYP_INFER && right == null)) { return false; }

    // Mirror PEAR2's operand-width and signedness checks. In particular, do
    // not make an ill-represented constant operation acceptable by folding it.
    AirTyp* result = comparison ? null : opt_resolved_integer_type(p);
    int bits = comparison ? (left != null ? opt_integer_bits(left) : (right != null ? opt_integer_bits(right) : 64)) :
                            (result != null ? opt_integer_bits(result) : (left != null ? opt_integer_bits(left) : (right != null ? opt_integer_bits(right) : 64)));
    bool uns = result != null ? opt_unsigned(result) : (left != null ? opt_unsigned(left) : (right != null ? opt_unsigned(right) : false));
    if (bits <= 0) { return false; }
    if (left != null && (opt_integer_bits(left) != bits || (result != null && opt_unsigned(left) != uns))) { return false; }
    if (right != null && (opt_integer_bits(right) != bits || (result != null && opt_unsigned(right) != uns))) { return false; }
    if (left != null && right != null && opt_unsigned(left) != opt_unsigned(right)) { return false; }
    if (!opt_integer_fits(p.subs[0].ival, bits, uns) && p.subs[0].tag == APRD_INT && (p.subs[0].ty == null || p.subs[0].ty.tag == ATYP_INFER)) { return false; }
    if (!opt_integer_fits(p.subs[1].ival, bits, uns) && p.subs[1].tag == APRD_INT && (p.subs[1].ty == null || p.subs[1].ty.tag == ATYP_INFER)) { return false; }
    return left != null || right != null || (p.subs[0].tag == APRD_INT && p.subs[1].tag == APRD_INT);
}

// opt_variable_substitution_compatible -- may a use of one binding become a use
// of another? Only when the two carry the same type hint, because a variable
// producer is resolved by the emitter from the binder in scope, not from the
// node. Two untyped producers are accepted: the emitter resolves both from their
// binders and rejects a mismatch at the use site, so the worst case for a wrong
// guess is a fail-closed compile rather than mis-typed code.
fn bool opt_variable_substitution_compatible(AirPrd* use, AirPrd* value)
{
    if (use == null || value == null || use.tag != APRD_VAR || value.tag != APRD_VAR) { return false; }
    if (!opt_ty_hint_equals(use.ty, value.ty)) { return false; }
    return true;
}

fn void OptStats.replace_with_prd(OptStats* s, AirPrd* dst, AirPrd* src)
{
    if (dst == null || src == null || dst == src) { return; }
    uint old_id = dst.id;
    AirTyp* result_hint = dst.ty;
    *dst = *src;
    dst.id = old_id;
    if (result_hint != null && result_hint.tag != ATYP_INFER) { dst.ty = result_hint; }
    s.rewrites++;
    s.operand_rewrites++;
}

fn void OptStats.rewrite_to_unary(OptStats* s, AirPrd* operation, AirPrd* value, AirUnop unary, bool strength)
{
    if (s == null || operation == null || value == null || operation.subs == null) { return; }
    operation.tag = APRD_UNOP;
    operation.name = null;
    operation.ival = 0;
    operation.fval = 0.0;
    operation.bval = false;
    operation.cval = 0;
    operation.subs[0] = value;
    operation.sub_count = 1;
    operation.binder_count = 0;
    operation.body = null;
    operation.ty_arg = null;
    operation.rec_inits = null;
    operation.rec_init_count = 0;
    operation.rec_init_cap = 0;
    operation.bop = ABIN_ADD;
    operation.uop = unary;
    s.rewrites++;
    if (strength) { s.strength_reductions++; }
    else { s.operand_rewrites++; }
}

// Rewrite x * 2^k to x << k only when both operations have the same
// x * 2^k is the same fixed-width bit operation as x << k. Accept the
// constant on either side, but allocate a fresh shift literal so shared AIR
// products are never mutated. Moving x across a literal preserves effects.
fn bool OptStats.strength_reduce_mul(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MUL || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null) { return false; }
    AirPrd* value = null;
    AirPrd* factor_node = null;
    if (p.subs[1].tag == APRD_INT && p.subs[0].tag != APRD_INT)
    {
        value = p.subs[0]; factor_node = p.subs[1];
    }
    else if (p.subs[0].tag == APRD_INT && p.subs[1].tag != APRD_INT)
    {
        value = p.subs[1]; factor_node = p.subs[0];
    }
    else { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(value);
    AirTyp* factor_type = opt_resolved_integer_type(factor_node);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null) { return false; }
    int bits = opt_integer_bits(operation_type);
    bool uns = opt_unsigned(operation_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(value_type) != bits || opt_unsigned(value_type) != uns) { return false; }
    if (factor_type != null && (opt_integer_bits(factor_type) != bits || opt_unsigned(factor_type) != uns)) { return false; }
    long factor = factor_node.ival;
    if (factor <= 1 || !opt_integer_fits(factor, bits, uns) || (factor & (factor - 1)) != 0) { return false; }
    int shift = 0;
    while (factor > 1) { factor >>= 1; shift++; }
    AirPrd* shift_count = air_ir::air_new_AirPrd(s.arena);
    if (shift_count == null) { return false; }
    shift_count.tag = APRD_INT;
    shift_count.ival = shift;
    shift_count.ty = factor_node.ty;
    p.subs[0] = value;
    p.subs[1] = shift_count;
    p.bop = ABIN_SHL;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// Multiplication by zero has the same bitwise result as AND with zero.
// Preserve the other operand so effects, poison, and undefined values are not
// erased; let the ordinary fold handle the all-literal case.
fn bool OptStats.strength_reduce_mul_zero(OptStats* s, AirPrd* p)
{
    if (s == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MUL || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null) { return false; }
    bool left_zero = opt_literal_zero(p.subs[0]);
    bool right_zero = opt_literal_zero(p.subs[1]);
    if ((!left_zero && !right_zero) || (p.subs[0].tag == APRD_INT && p.subs[1].tag == APRD_INT)) { return false; }
    AirPrd* value = left_zero ? p.subs[1] : p.subs[0];
    if (!opt_can_return_operand(p, value)) { return false; }
    p.bop = ABIN_AND;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// For unsigned integers, x % 2^k is the same bit-vector operation as
// x & (2^k - 1). Keep x in the expression so poison and evaluation are not
// discarded; signed remainder is intentionally excluded.
fn bool OptStats.strength_reduce_unsigned_mod(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MOD || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null || p.subs[0].tag == APRD_INT || p.subs[1].tag != APRD_INT) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* divisor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null || !opt_unsigned(operation_type)) { return false; }
    int bits = opt_integer_bits(operation_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(value_type) != bits || !opt_unsigned(value_type)) { return false; }
    if (divisor_type != null && (opt_integer_bits(divisor_type) != bits || !opt_unsigned(divisor_type))) { return false; }
    long divisor = p.subs[1].ival;
    if (divisor <= 1 || !opt_integer_fits(divisor, bits, true) || (divisor & (divisor - 1)) != 0) { return false; }
    AirPrd* mask = air_ir::air_new_AirPrd(s.arena);
    if (mask == null) { return false; }
    mask.tag = APRD_INT;
    mask.ival = divisor - 1;
    mask.ty = p.subs[1].ty;
    p.subs[1] = mask;
    p.bop = ABIN_AND;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// Any defined integer remainder by one is zero. Keep the value as an AND
// operand to preserve evaluation and poison propagation instead of dropping it.
fn bool OptStats.strength_reduce_remainder_one(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MOD || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null || p.subs[0].tag == APRD_INT || p.subs[1].tag != APRD_INT ||
        p.subs[1].ival != 1) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* divisor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null) { return false; }
    int bits = opt_integer_bits(operation_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(value_type) != bits || opt_unsigned(value_type) != opt_unsigned(operation_type)) { return false; }
    if (divisor_type != null && (opt_integer_bits(divisor_type) != bits || opt_unsigned(divisor_type) != opt_unsigned(operation_type))) { return false; }
    AirPrd* zero = air_ir::air_new_AirPrd(s.arena);
    if (zero == null) { return false; }
    zero.tag = APRD_INT;
    zero.ival = 0;
    zero.ty = p.subs[1].ty;
    p.subs[1] = zero;
    p.bop = ABIN_AND;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

fn AirPrd* OptStats.new_binary_product(OptStats* s, AirBinop op, AirTyp* type, AirPrd* left, AirPrd* right)
{
    if (s == null || s.arena == null || left == null || right == null) { return null; }
    AirPrd* p = air_ir::air_new_AirPrd(s.arena);
    if (p == null) { return null; }
    AirPrd** operands = (AirPrd**)s.arena.alloc(16, 8);
    if (operands == null) { return null; }
    operands[0] = left;
    operands[1] = right;
    p.tag = APRD_BINOP;
    p.bop = op;
    p.ty = type;
    p.subs = operands;
    p.sub_count = 2;
    p.sub_cap = 2;
    return p;
}

fn AirPrd* OptStats.new_integer_literal(OptStats* s, long value, AirTyp* type)
{
    if (s == null || s.arena == null) { return null; }
    AirPrd* p = air_ir::air_new_AirPrd(s.arena);
    if (p == null) { return null; }
    p.tag = APRD_INT;
    p.ival = value;
    p.ty = type;
    return p;
}

fn AirPrd* OptStats.new_signed_power_two_quotient(OptStats* s, AirTyp* type, AirPrd* value, int bits, long divisor, int shift)
{
    if (s == null || type == null || value == null || bits <= 1 || shift <= 0) { return null; }
    AirPrd* sign_count = s.new_integer_literal((long)(bits - 1), type);
    AirPrd* bias_mask = s.new_integer_literal(divisor - 1, type);
    AirPrd* quotient_shift = s.new_integer_literal((long)shift, type);
    if (sign_count == null || bias_mask == null || quotient_shift == null) { return null; }
    AirPrd* sign = s.new_binary_product(ABIN_SHR, type, value, sign_count);
    if (sign == null) { return null; }
    AirPrd* bias = s.new_binary_product(ABIN_AND, type, sign, bias_mask);
    if (bias == null) { return null; }
    AirPrd* adjusted = s.new_binary_product(ABIN_ADD, type, value, bias);
    if (adjusted == null) { return null; }
    return s.new_binary_product(ABIN_SHR, type, adjusted, quotient_shift);
}

// Signed truncating division by 2^k uses a sign-derived bias before arithmetic
// shift. Restrict to SSA variables so the dividend is not duplicated if it can
// have effects; the adjustment remains in-range for every signed dividend.
fn bool OptStats.strength_reduce_signed_div(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_DIV || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[0].tag != APRD_VAR || p.subs[1] == null || p.subs[1].tag != APRD_INT) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* divisor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null || opt_unsigned(operation_type)) { return false; }
    int bits = opt_integer_bits(operation_type);
    if (bits <= 1 || bits > 64 || opt_integer_bits(value_type) != bits || opt_unsigned(value_type)) { return false; }
    if (divisor_type != null && (opt_integer_bits(divisor_type) != bits || opt_unsigned(divisor_type))) { return false; }
    long divisor = p.subs[1].ival;
    if (divisor <= 1 || !opt_integer_fits(divisor, bits, false) || (divisor & (divisor - 1)) != 0) { return false; }
    int shift = 0;
    long scan = divisor;
    while (scan > 1) { scan >>= 1; shift++; }
    if (shift <= 0 || shift >= bits) { return false; }

    AirPrd* quotient = s.new_signed_power_two_quotient(operation_type, p.subs[0], bits, divisor, shift);
    if (quotient == null) { return false; }

    p.bop = ABIN_SHR;
    p.subs[0] = quotient.subs[0];
    p.subs[1] = quotient.subs[1];
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// Signed remainder can be recovered from the same truncating quotient. The
// SSA dividend may be reused because it has no evaluation effects.
fn bool OptStats.strength_reduce_signed_mod(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MOD || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[0].tag != APRD_VAR || p.subs[1] == null || p.subs[1].tag != APRD_INT) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* divisor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null || opt_unsigned(operation_type)) { return false; }
    int bits = opt_integer_bits(operation_type);
    if (bits <= 1 || bits > 64 || opt_integer_bits(value_type) != bits || opt_unsigned(value_type)) { return false; }
    if (divisor_type != null && (opt_integer_bits(divisor_type) != bits || opt_unsigned(divisor_type))) { return false; }
    long divisor = p.subs[1].ival;
    if (divisor <= 1 || !opt_integer_fits(divisor, bits, false) || (divisor & (divisor - 1)) != 0) { return false; }
    int shift = 0;
    long scan = divisor;
    while (scan > 1) { scan >>= 1; shift++; }
    if (shift <= 0 || shift >= bits) { return false; }

    AirPrd* quotient = s.new_signed_power_two_quotient(operation_type, p.subs[0], bits, divisor, shift);
    AirPrd* shift_count = s.new_integer_literal((long)shift, operation_type);
    if (quotient == null || shift_count == null) { return false; }
    AirPrd* scaled_quotient = s.new_binary_product(ABIN_SHL, operation_type, quotient, shift_count);
    if (scaled_quotient == null) { return false; }

    p.bop = ABIN_SUB;
    p.subs[1] = scaled_quotient;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// For unsigned integers, division by 2^k is a logical right shift. Preserve
// the value operand (and therefore poison propagation) and only reduce known
// unsigned widths with an in-range nonzero power-of-two divisor.
fn bool OptStats.strength_reduce_unsigned_div(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_DIV || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null || p.subs[0].tag == APRD_INT || p.subs[1].tag != APRD_INT) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* divisor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null || !opt_unsigned(operation_type)) { return false; }
    int bits = opt_integer_bits(operation_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(value_type) != bits || !opt_unsigned(value_type)) { return false; }
    if (divisor_type != null && (opt_integer_bits(divisor_type) != bits || !opt_unsigned(divisor_type))) { return false; }
    long divisor = p.subs[1].ival;
    if (divisor <= 1 || !opt_integer_fits(divisor, bits, true) || (divisor & (divisor - 1)) != 0) { return false; }
    int shift = 0;
    while (divisor > 1) { divisor >>= 1; shift++; }
    AirPrd* shift_count = air_ir::air_new_AirPrd(s.arena);
    if (shift_count == null) { return false; }
    shift_count.tag = APRD_INT;
    shift_count.ival = shift;
    shift_count.ty = p.subs[1].ty;
    p.subs[1] = shift_count;
    p.bop = ABIN_SHR;
    s.rewrites++;
    s.strength_reductions++;
    return true;
}

// Compose nested same-kind shifts while their sum stays in range. The fresh
// count avoids mutating shared AIR literals; the value operand is evaluated
// once and retains the same width and signedness.
fn bool OptStats.combine_nested_shift(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP ||
        (p.bop != ABIN_SHL && p.bop != ABIN_SHR) || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null || p.subs[0].tag != APRD_BINOP ||
        p.subs[0].bop != p.bop || p.subs[0].sub_count != 2 ||
        p.subs[0].subs[0] == null || p.subs[0].subs[1] == null ||
        p.subs[1].tag != APRD_INT || p.subs[0].subs[1].tag != APRD_INT) { return false; }
    AirPrd* inner = p.subs[0];
    if (!opt_integer_operation(p) || !opt_integer_operation(inner)) { return false; }
    AirTyp* result_type = opt_resolved_integer_type(p);
    AirTyp* inner_type = opt_resolved_integer_type(inner);
    AirTyp* value_type = opt_resolved_integer_type(inner.subs[0]);
    if (result_type == null || inner_type == null || value_type == null) { return false; }
    int bits = opt_integer_bits(result_type);
    bool uns = opt_unsigned(result_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(inner_type) != bits || opt_unsigned(inner_type) != uns ||
        opt_integer_bits(value_type) != bits || opt_unsigned(value_type) != uns) { return false; }
    long first = inner.subs[1].ival;
    long second = p.subs[1].ival;
    if (first < 0 || second < 0 || first >= bits || second >= bits || first + second >= bits) { return false; }
    if (!opt_integer_fits(first, bits, uns) || !opt_integer_fits(second, bits, uns)) { return false; }
    AirPrd* combined = air_ir::air_new_AirPrd(s.arena);
    if (combined == null) { return false; }
    combined.tag = APRD_INT;
    combined.ival = first + second;
    combined.ty = p.subs[1].ty;
    p.subs[0] = inner.subs[0];
    p.subs[1] = combined;
    s.rewrites++;
    s.shift_combinations++;
    return true;
}

fn void OptStats.set_int(OptStats* s, AirPrd* p, long value)
{
    if (p == null) { return; }
    p.tag = APRD_INT;
    p.name = null;
    p.ival = value;
    p.fval = 0.0;
    p.bval = false;
    p.cval = 0;
    p.bytes = null;
    p.bytes_len = 0;
    p.subs = null;
    p.sub_count = 0;
    p.sub_cap = 0;
    p.binder_count = 0;
    p.body = null;
    p.ty_arg = null;
    p.rec_inits = null;
    p.rec_init_count = 0;
    p.rec_init_cap = 0;
    p.bop = ABIN_ADD;
    p.uop = AUN_NEG;
    s.rewrites++;
    s.constant_folds++;
}

fn void OptStats.set_bool(OptStats* s, AirPrd* p, bool value)
{
    if (p == null) { return; }
    p.tag = APRD_BOOL;
    p.name = null;
    p.ival = value ? 1 : 0;
    p.fval = 0.0;
    p.bval = value;
    p.cval = 0;
    p.bytes = null;
    p.bytes_len = 0;
    p.subs = null;
    p.sub_count = 0;
    p.sub_cap = 0;
    p.binder_count = 0;
    p.body = null;
    p.ty_arg = null;
    p.rec_inits = null;
    p.rec_init_count = 0;
    p.rec_init_cap = 0;
    p.bop = ABIN_ADD;
    p.uop = AUN_NEG;
    s.rewrites++;
    s.constant_folds++;
}

fn void OptStats.fold_binary(OptStats* s, AirPrd* p)
{
    if (p != null && p.tag == APRD_BINOP && p.sub_count == 2 && p.subs[0] != null && p.subs[1] != null &&
        p.subs[0].tag == APRD_BOOL && p.subs[1].tag == APRD_BOOL && opt_bool_hint(p.ty) &&
        opt_bool_hint(p.subs[0].ty) && opt_bool_hint(p.subs[1].ty))
    {
        bool a_bool = p.subs[0].bval;
        bool b_bool = p.subs[1].bval;
        switch (p.bop)
        {
            case ABIN_EQ: s.set_bool(p, a_bool == b_bool); return;
            case ABIN_NEQ: s.set_bool(p, a_bool != b_bool); return;
            case ABIN_AND: case ABIN_LAND: s.set_bool(p, a_bool && b_bool); return;
            case ABIN_OR: case ABIN_LOR: s.set_bool(p, a_bool || b_bool); return;
            case ABIN_XOR: s.set_bool(p, a_bool != b_bool); return;
            default: break;
        }
    }
    bool known_bool_operation = p != null && ((p.ty != null && p.ty.tag == ATYP_BOOL) ||
                               (p.sub_count == 2 && p.subs[0] != null && p.subs[1] != null &&
                                ((p.subs[0].tag == APRD_BOOL && p.subs[1].ty != null && p.subs[1].ty.tag == ATYP_BOOL) ||
                                 (p.subs[1].tag == APRD_BOOL && p.subs[0].ty != null && p.subs[0].ty.tag == ATYP_BOOL))));
    if (p != null && p.tag == APRD_BINOP && p.sub_count == 2 && p.subs[0] != null && p.subs[1] != null &&
        known_bool_operation && opt_bool_hint(p.ty) && opt_bool_hint(p.subs[0].ty) && opt_bool_hint(p.subs[1].ty))
    {
        AirPrd* left = p.subs[0];
        AirPrd* right = p.subs[1];
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ)
        {
            if (left.tag == APRD_BOOL)
            {
                bool keep = (p.bop == ABIN_EQ) == left.bval;
                if (keep) { s.replace_with_prd(p, right); }
                else { s.rewrite_to_unary(p, right, AUN_NOT, false); }
                return;
            }
            if (right.tag == APRD_BOOL)
            {
                bool keep = (p.bop == ABIN_EQ) == right.bval;
                if (keep) { s.replace_with_prd(p, left); }
                else { s.rewrite_to_unary(p, left, AUN_NOT, false); }
                return;
            }
        }
        if (p.bop == ABIN_AND && left.tag == APRD_BOOL && left.bval) { s.replace_with_prd(p, right); return; }
        if (p.bop == ABIN_AND && right.tag == APRD_BOOL && right.bval) { s.replace_with_prd(p, left); return; }
        if ((p.bop == ABIN_OR || p.bop == ABIN_LOR) && left.tag == APRD_BOOL && !left.bval) { s.replace_with_prd(p, right); return; }
        if ((p.bop == ABIN_OR || p.bop == ABIN_LOR) && right.tag == APRD_BOOL && !right.bval) { s.replace_with_prd(p, left); return; }
        if (p.bop == ABIN_LAND && left.tag == APRD_BOOL && left.bval) { s.replace_with_prd(p, right); return; }
        if (p.bop == ABIN_LAND && right.tag == APRD_BOOL && right.bval) { s.replace_with_prd(p, left); return; }
        if (p.bop == ABIN_XOR && left.tag == APRD_BOOL && left.bval) { s.rewrite_to_unary(p, right, AUN_NOT, false); return; }
        if (p.bop == ABIN_XOR && right.tag == APRD_BOOL && right.bval) { s.rewrite_to_unary(p, left, AUN_NOT, false); return; }
        if (p.bop == ABIN_XOR && left.tag == APRD_BOOL && !left.bval) { s.replace_with_prd(p, right); return; }
        if (p.bop == ABIN_XOR && right.tag == APRD_BOOL && !right.bval) { s.replace_with_prd(p, left); return; }
    }
    if (!opt_integer_operation(p) || p.subs[0] == null || p.subs[1] == null) { return; }
    AirPrd* a = p.subs[0];
    AirPrd* b = p.subs[1];
    AirTyp* result_type = opt_resolved_integer_type(p);
    AirTyp* left_type = opt_resolved_integer_type(a);
    AirTyp* right_type = opt_resolved_integer_type(b);
    bool known_unsigned = opt_unsigned(result_type != null ? result_type : (left_type != null ? left_type : right_type));
    int bits = opt_integer_bits(result_type != null ? result_type : (left_type != null ? left_type : right_type));
    if ((a.tag == APRD_INT && !opt_integer_fits(a.ival, bits, known_unsigned)) ||
        (b.tag == APRD_INT && !opt_integer_fits(b.ival, bits, known_unsigned))) { return; }

    // Do not use an identity to erase an operand whose representation is
    // unknown: that could turn a malformed mixed-type operation into valid AIR.
    if (p.bop == ABIN_ADD && opt_literal_zero(a) && opt_can_return_operand(p, b)) { s.replace_with_prd(p, b); return; }
    if (p.bop == ABIN_ADD && opt_literal_zero(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_SUB && opt_literal_zero(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if ((p.bop == ABIN_OR || p.bop == ABIN_XOR) && opt_literal_zero(a) && opt_can_return_operand(p, b)) { s.replace_with_prd(p, b); return; }
    if (p.bop == ABIN_MUL && opt_literal_one(a) && opt_can_return_operand(p, b)) { s.replace_with_prd(p, b); return; }
    if (p.bop == ABIN_MUL && opt_literal_one(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_DIV && opt_literal_one(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_AND && opt_all_ones_literal(p, a) && opt_can_return_operand(p, b)) { s.replace_with_prd(p, b); return; }
    if (p.bop == ABIN_AND && opt_all_ones_literal(p, b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_XOR && opt_all_ones_literal(p, a) && opt_can_return_operand(p, b)) { s.rewrite_to_unary(p, b, AUN_BITNOT, false); return; }
    if (p.bop == ABIN_XOR && opt_all_ones_literal(p, b) && opt_can_return_operand(p, a)) { s.rewrite_to_unary(p, a, AUN_BITNOT, false); return; }
    if ((p.bop == ABIN_SHL || p.bop == ABIN_SHR || p.bop == ABIN_OR || p.bop == ABIN_XOR) && opt_literal_zero(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_MUL && a.tag == APRD_INT && b.tag != APRD_INT &&
        opt_all_ones_literal(p, a) && opt_can_return_operand(p, b))
    {
        s.rewrite_to_unary(p, b, AUN_NEG, true);
        return;
    }
    if (p.bop == ABIN_MUL && b.tag == APRD_INT && a.tag != APRD_INT &&
        opt_all_ones_literal(p, b) && opt_can_return_operand(p, a))
    {
        s.rewrite_to_unary(p, a, AUN_NEG, true);
        return;
    }
    if (p.bop == ABIN_MUL && s.strength_reduce_mul_zero(p)) { return; }
    if (p.bop == ABIN_MUL && s.strength_reduce_mul(p)) { return; }
    if (p.bop == ABIN_MOD && s.strength_reduce_remainder_one(p)) { return; }
    if (p.bop == ABIN_MOD && s.strength_reduce_signed_mod(p)) { return; }
    if (p.bop == ABIN_MOD && s.strength_reduce_unsigned_mod(p)) { return; }
    if (p.bop == ABIN_DIV && s.strength_reduce_signed_div(p)) { return; }
    if (p.bop == ABIN_DIV && s.strength_reduce_unsigned_div(p)) { return; }
    if ((p.bop == ABIN_SHL || p.bop == ABIN_SHR) && s.combine_nested_shift(p)) { return; }

    if (a.tag != APRD_INT || b.tag != APRD_INT || bits <= 0 || bits > 64) { return; }
    // AIR integer payloads are signed host longs. Restrict constant folding to
    // values representable in the actual operation type; do not reinterpret
    // out-of-range typed payloads as implicit modular casts.
    if (!opt_integer_fits(a.ival, bits, known_unsigned) || !opt_integer_fits(b.ival, bits, known_unsigned)) { return; }
    long result = 0;
    bool folded = false;
    switch (p.bop)
    {
        case ABIN_ADD: folded = opt_safe_add(a.ival, b.ival, &result); break;
        case ABIN_SUB: folded = opt_safe_sub(a.ival, b.ival, &result); break;
        case ABIN_MUL: folded = opt_safe_mul(a.ival, b.ival, &result); break;
        case ABIN_DIV:
        case ABIN_MOD:
        {
            long signed_min = bits == 64 ? OPT_LONG_MIN : -(1L << (bits - 1));
            if (b.ival == 0 || (!known_unsigned && a.ival == signed_min && b.ival == -1)) { return; }
            result = p.bop == ABIN_DIV ? a.ival / b.ival : a.ival % b.ival;
            folded = true;
            break;
        }
        case ABIN_AND: result = a.ival & b.ival; folded = true; break;
        case ABIN_OR: result = a.ival | b.ival; folded = true; break;
        case ABIN_XOR: result = a.ival ^ b.ival; folded = true; break;
        case ABIN_SHL:
        case ABIN_SHR:
        {
            if (b.ival < 0 || b.ival >= bits) { return; }
            int shift = (int)b.ival;
            ulong mask = bits == 64 ? ~0UL : ((1UL << bits) - 1UL);
            ulong raw = (ulong)a.ival & mask;
            if (p.bop == ABIN_SHL) { raw = (raw << shift) & mask; }
            else
            {
                bool negative = !known_unsigned && (raw & (1UL << (bits - 1))) != 0;
                raw >>= shift;
                if (negative && shift > 0)
                {
                    ulong low_mask = (1UL << (bits - shift)) - 1UL;
                    raw |= mask ^ low_mask;
                }
            }
            folded = opt_integer_from_bits(raw, bits, known_unsigned, &result);
            break;
        }
        case ABIN_EQ: s.set_bool(p, a.ival == b.ival); return;
        case ABIN_NEQ: s.set_bool(p, a.ival != b.ival); return;
        case ABIN_LT: s.set_bool(p, known_unsigned ? ((ulong)a.ival < (ulong)b.ival) : a.ival < b.ival); return;
        case ABIN_GT: s.set_bool(p, known_unsigned ? ((ulong)a.ival > (ulong)b.ival) : a.ival > b.ival); return;
        case ABIN_LE: s.set_bool(p, known_unsigned ? ((ulong)a.ival <= (ulong)b.ival) : a.ival <= b.ival); return;
        case ABIN_GE: s.set_bool(p, known_unsigned ? ((ulong)a.ival >= (ulong)b.ival) : a.ival >= b.ival); return;
        default: return;
    }
    if (folded && opt_integer_fits(result, bits, known_unsigned)) { s.set_int(p, result); }
}

fn void OptStats.fold_coerce(OptStats* s, AirPrd* p)
{
    if (p == null || p.tag != APRD_COERCE || p.sub_count != 1 || p.subs[0] == null || p.ty == null || p.ty.tag == ATYP_INFER) { return; }
    AirPrd* operand = p.subs[0];
    AirTyp* source_type = opt_resolved_integer_type(operand);
    AirTyp* target_type = opt_resolved_integer_type(p);
    if (source_type != null && target_type != null && opt_can_return_operand(p, operand))
    {
        s.replace_with_prd(p, operand);
        return;
    }
    if (p.ty.tag == ATYP_BOOL && operand.ty != null && operand.ty.tag == ATYP_BOOL)
    {
        s.replace_with_prd(p, operand);
        return;
    }
    if (operand.ty != null && p.ty.tag == operand.ty.tag &&
        (p.ty.tag == ATYP_F32 || p.ty.tag == ATYP_F64))
    {
        s.replace_with_prd(p, operand);
        return;
    }
    if (operand.tag == APRD_BOOL && opt_bool_hint(operand.ty) && target_type != null)
    {
        int target_bits = opt_integer_bits(target_type);
        if (target_bits > 0 && target_bits <= 64) { s.set_int(p, operand.bval ? 1 : 0); }
        return;
    }
    if (operand.tag == APRD_INT && p.ty.tag == ATYP_BOOL && source_type != null)
    {
        int source_bits = opt_integer_bits(source_type);
        bool source_unsigned = opt_unsigned(source_type);
        if (source_bits > 0 && source_bits <= 64 && opt_integer_fits(operand.ival, source_bits, source_unsigned))
        {
            s.set_bool(p, ((ulong)operand.ival & 1UL) != 0);
        }
        return;
    }
    if (operand.tag != APRD_INT || source_type == null || target_type == null) { return; }
    int source_bits = opt_integer_bits(source_type);
    int target_bits = opt_integer_bits(target_type);
    bool source_unsigned = opt_unsigned(source_type);
    bool target_unsigned = opt_unsigned(target_type);
    if (source_bits <= 0 || source_bits > 64 || target_bits <= 0 || target_bits > 64 ||
        !opt_integer_fits(operand.ival, source_bits, source_unsigned)) { return; }

    ulong source_mask = source_bits == 64 ? ~0UL : ((1UL << source_bits) - 1UL);
    ulong target_mask = target_bits == 64 ? ~0UL : ((1UL << target_bits) - 1UL);
    ulong raw = (ulong)operand.ival & source_mask;
    if (target_bits > source_bits && !source_unsigned && operand.ival < 0)
    {
        raw |= target_mask ^ source_mask;
    }
    raw &= target_mask;
    long result = 0;
    if (opt_integer_from_bits(raw, target_bits, target_unsigned, &result)) { s.set_int(p, result); }
}

fn void OptStats.fold_unary(OptStats* s, AirPrd* p)
{
    if (p == null || p.tag != APRD_UNOP || p.sub_count != 1 || p.subs[0] == null) { return; }
    AirPrd* operand = p.subs[0];
    if (p.uop == AUN_NOT)
    {
        bool result_bool = opt_bool_hint(p.ty);
        bool operand_bool = opt_bool_hint(operand.ty);
        if (result_bool && operand_bool && operand.tag == APRD_UNOP && operand.uop == AUN_NOT &&
            operand.sub_count == 1 && operand.subs[0] != null && opt_bool_hint(operand.subs[0].ty))
        {
            s.replace_with_prd(p, operand.subs[0]);
            return;
        }
        if (result_bool && operand_bool && operand.tag == APRD_BOOL) { s.set_bool(p, !operand.bval); }
        return;
    }
    if (p.uop != AUN_NEG && p.uop != AUN_BITNOT) { return; }
    if (p.ty != null && p.ty.tag != ATYP_INFER && !opt_integer_type(p.ty)) { return; }
    if (operand.ty != null && operand.ty.tag != ATYP_INFER && !opt_integer_type(operand.ty)) { return; }
    if (p.uop == AUN_BITNOT && operand.tag == APRD_UNOP && operand.uop == AUN_BITNOT &&
        operand.sub_count == 1 && operand.subs[0] != null &&
        opt_can_return_operand(p, operand) && opt_can_return_operand(operand, operand.subs[0]))
    {
        s.replace_with_prd(p, operand.subs[0]);
        return;
    }
    if (operand.tag != APRD_INT) { return; }
    AirTyp* result_type = opt_resolved_integer_type(p);
    AirTyp* operand_type = opt_resolved_integer_type(operand);
    if (result_type != null && operand_type != null &&
        (opt_integer_bits(result_type) != opt_integer_bits(operand_type) || opt_unsigned(result_type) != opt_unsigned(operand_type))) { return; }
    int bits = result_type != null ? opt_integer_bits(result_type) : (operand_type != null ? opt_integer_bits(operand_type) : 64);
    bool uns = result_type != null ? opt_unsigned(result_type) : (operand_type != null ? opt_unsigned(operand_type) : false);
    if (bits <= 0 || bits > 64 || !opt_integer_fits(operand.ival, bits, uns)) { return; }
    long result = 0;
    if (p.uop == AUN_NEG)
    {
        if (uns && operand.ival != 0) { return; }
        if (!opt_safe_sub(0, operand.ival, &result)) { return; }
    }
    else if (uns)
    {
        // A ulong complement may not fit in AirPrd.ival; fold only widths whose
        // complete unsigned result is representable in the signed host field.
        if (bits >= 64) { return; }
        ulong mask = (1UL << bits) - 1UL;
        result = (long)((~(ulong)operand.ival) & mask);
    }
    else { result = ~operand.ival; }
    if (opt_integer_fits(result, bits, uns)) { s.set_int(p, result); }
}

// ── Pass 2: dead binding elimination ─────────────────────────────────────
//
// `let x = <literal|variable>` where x never appears in the body. Dropping it
// stops PEAR 2 from materialising a slot for a value nothing reads, and it
// removes the binding before the emitter has to lower its initialiser, so a
// dead binding can no longer make an otherwise-supported function fail closed.
//
// Two restrictions keep it sound:
//
//   inert value   the initialiser is a literal or a variable, so deleting the
//                 binding cannot discard an effect or a trap.
//   absent name   the name must not appear anywhere in the body -- not as a
//                 use, not as a binder, match-pattern binder, covariable, jump
//                 argument, label, subst entry, or the name carried by a
//                 non-variable producer. That test is deliberately stronger
//                 than a use count: it cannot be fooled by shadowing, and it
//                 cannot miss a name that reaches the emitter through an
//                 unusual field.
//
// Copy propagation (`let x = y` rewritten to use y directly) is deliberately
// NOT done here. PEAR 2 lowers mutable locals to allocas, so `let x = y` is a
// snapshot of a load; renaming the uses would re-load the slot and observe
// later writes. Deciding that a name is an immutable binding needs the
// emitter's scope and mutability information, which this pass does not have --
// and the transform would buy nothing anyway, because the emitter already
// binds AIR names to SSA values, so an alias costs no instructions.

fn bool opt_droppable_value(AirPrd* p)
{
    if (p == null) { return false; }
    if (p.tag == APRD_VAR || p.tag == APRD_INT || p.tag == APRD_FLOAT || p.tag == APRD_BOOL ||
        p.tag == APRD_CHAR || p.tag == APRD_STRING || p.tag == APRD_BYTES || p.tag == APRD_UNIT ||
        p.tag == APRD_NULL) { return true; }
    return false;
}

// Pattern binders live in AirPat, which the scans below do not walk as uses. A
// match arm that binds a name must therefore block removal of a binding with
// that name for the whole command: the arm's binder shadows nothing here, but
// treating it as an occurrence is the conservative reading.
fn bool opt_pat_binds(AirPat* p, char* name, int depth)
{
    if (p == null || depth >= 128) { return false; }
    if (p.tag == APAT_BIND || p.tag == APAT_AS)
    {
        if (p.name != null && opt_same_name(p.name, name)) { return true; }
    }
    for (usz i = 0; i < p.sub_count; i++) { if (opt_pat_binds(p.sub[i], name, depth + 1)) { return true; } }
    // A record pattern binds its field names (`Name { x, y }`); those are
    // binders, not uses.
    if (p.tag == APAT_RECORD)
    {
        for (usz i = 0; i < p.field_count; i++)
        {
            if (p.fields[i] != null && p.fields[i].name != null && opt_same_name(p.fields[i].name, name)) { return true; }
        }
    }
    return opt_pat_binds(p.or_alt, name, depth + 1);
}

// scan_prd / scan_cns / scan_cmd accumulate, for one name:
//   var_uses — how many APRD_VAR producers reference it
//   blocked  — whether it appears in any other position (binder, covariable,
//              label, jump argument, subst entry, non-variable producer name)
fn void OptStats.scan_prd(OptStats* s, AirPrd* p, char* name, int* var_uses, bool* blocked, int depth)
{
    if (p == null || depth >= 128 || *blocked) { return; }
    if (p.tag == APRD_VAR && p.name != null && opt_same_name(p.name, name)) { *var_uses = *var_uses + 1; }
    else if (p.name != null && opt_same_name(p.name, name)) { *blocked = true; return; }
    for (usz i = 0; i < p.sub_count; i++) { s.scan_prd(p.subs[i], name, var_uses, blocked, depth + 1); }
    for (usz i = 0; i < p.rec_init_count; i++)
    {
        if (p.rec_inits[i] != null) { s.scan_prd(p.rec_inits[i].value, name, var_uses, blocked, depth + 1); }
        if (*blocked) { return; }
    }
    for (usz i = 0; i < p.binder_count; i++)
    {
        if (p.binders[i] != null && p.binders[i].name != null && opt_same_name(p.binders[i].name, name)) { *blocked = true; return; }
    }
    if (p.body != null) { s.scan_cmd(p.body, name, var_uses, blocked, depth + 1); }
}

fn void OptStats.scan_cns(OptStats* s, AirCns* k, char* name, int* var_uses, bool* blocked, int depth)
{
    if (k == null || depth >= 128 || *blocked) { return; }
    if (k.name != null && opt_same_name(k.name, name)) { *blocked = true; return; }
    if (k.bind != null && opt_same_name(k.bind, name)) { *blocked = true; return; }
    if (k.label_name != null && opt_same_name(k.label_name, name)) { *blocked = true; return; }
    for (usz i = 0; i < k.label_arg_count; i++)
    {
        if (k.label_args[i] != null && k.label_args[i].name != null && opt_same_name(k.label_args[i].name, name)) { *blocked = true; return; }
    }
    for (usz i = 0; i < k.subst_count; i++)
    {
        if (k.subst_vars[i] != null && opt_same_name(k.subst_vars[i], name)) { *blocked = true; return; }
        if (s.opt_cns_blocked(k.subst_prds[i], name, var_uses, depth)) { *blocked = true; return; }
    }
    s.scan_prd(k.prd, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cns(k.tail, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cns(k.cont_k, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(k.body, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(k.label_body, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] == null) { continue; }
        if (opt_pat_binds(k.branches[i].pat, name, 0)) { *blocked = true; return; }
        s.scan_cmd(k.branches[i].body, name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
        s.scan_cmd(k.branches[i].guard, name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        if (k.cobranches[i] == null) { continue; }
        for (usz j = 0; j < k.cobranches[i].binder_count; j++)
        {
            if (k.cobranches[i].binders[j] != null && opt_same_name(k.cobranches[i].binders[j], name)) { *blocked = true; return; }
        }
        s.scan_cmd(k.cobranches[i].body, name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
    }
}

// Small helper so the subst_prds loop above cannot quietly swallow a hit.
fn bool OptStats.opt_cns_blocked(OptStats* s, AirPrd* p, char* name, int* var_uses, int depth)
{
    bool blocked = false;
    s.scan_prd(p, name, var_uses, &blocked, depth + 1);
    return blocked;
}

fn void OptStats.scan_cmd(OptStats* s, AirCmd* c, char* name, int* var_uses, bool* blocked, int depth)
{
    if (c == null || depth >= 128 || *blocked) { return; }
    if (c.binder != null && opt_same_name(c.binder, name)) { *blocked = true; return; }
    if (c.target_label != null && opt_same_name(c.target_label, name)) { *blocked = true; return; }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        if (c.mbinders[i] != null && c.mbinders[i].name != null && opt_same_name(c.mbinders[i].name, name)) { *blocked = true; return; }
    }
    for (usz i = 0; i < c.jump_arg_count; i++)
    {
        if (c.jump_args[i] != null && opt_same_name(c.jump_args[i], name)) { *blocked = true; return; }
    }
    s.scan_prd(c.prd, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    for (usz i = 0; i < c.prd_count; i++)
    {
        s.scan_prd(c.prds[i], name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
    }
    s.scan_cns(c.cns, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(c.body, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(c.next, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(c.then_c, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(c.else_c, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    s.scan_cmd(c.handled, name, var_uses, blocked, depth + 1);
    if (*blocked) { return; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        if (c.branches[i] == null) { continue; }
        if (opt_pat_binds(c.branches[i].pat, name, 0)) { *blocked = true; return; }
        s.scan_cmd(c.branches[i].guard, name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
        s.scan_cmd(c.branches[i].body, name, var_uses, blocked, depth + 1);
        if (*blocked) { return; }
    }
}


// ===== pass 3: whole-body binding propagation (-O3) =========================
//
// Passes 1 and 2 are expression-local. Pass 1 reaches a constant only through
// an immediate initializer or an immediate result; pass 2 removes only a
// binding whose value is inert. Both stop at one nesting level because neither
// ever asks a question about the whole body.
//
// Pass 3 asks that question once, as a name census, and spends the answer
// twice:
//
//   propagation  `let x = <literal>` where the census proves `x` is bound
//                nowhere else and never appears as a jump argument: every use
//                becomes the literal, and the enclosing expressions then fold.
//   removal      the same census proves an unused binding dead even when its
//                initializer computes something, which pass 2 cannot do
//                because it only accepts inert values.
//
// Why substitution is sound here: AIR has no assignment command. A mutable
// local is carried by label and jump parameters, so it always shows up as an
// extra binder position or a jump argument, and the census refuses. A name
// that no other position mentions therefore has exactly one value for the
// whole body, and replacing its uses with that value cannot observe a later
// write -- the failure mode that made copy propagation unsound in the emitter
// instead of here.
//
// The substitution is also type-checked per use rather than per binding: an
// integer literal only replaces a use whose resolved width and signedness
// match (or an untyped use that the literal fits), so a narrow binding is
// never widened by a rewrite.

// opt_pure_value -- can this producer be evaluated and discarded with no
// observable difference? Pure means no call, no memory operation, no
// allocation, no closure, no effect -- and no trap. Division and remainder are
// deliberately excluded: `div x 0` faults at run time, and deleting a trapping
// expression would turn a crash into a silent result, which is a semantics
// change rather than an optimization. Loads, gepe, allocas, ref/addr/deref and
// every closure form are excluded for the same reason: they touch state.
fn bool opt_pure_value(AirPrd* p, int depth)
{
    if (p == null || depth >= 64) { return false; }
    if (p.body != null || p.binder_count != 0 || p.rec_init_count != 0) { return false; }
    for (usz i = 0; i < p.sub_count; i++) { if (!opt_pure_value(p.subs[i], depth + 1)) { return false; } }
    switch (p.tag)
    {
        case APRD_VAR: case APRD_INT: case APRD_FLOAT: case APRD_BOOL: case APRD_CHAR:
        case APRD_STRING: case APRD_BYTES: case APRD_UNIT: case APRD_NULL:
            return true;
        case APRD_BINOP:
            return p.bop == ABIN_ADD || p.bop == ABIN_SUB || p.bop == ABIN_MUL ||
                   p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR ||
                   p.bop == ABIN_SHL || p.bop == ABIN_SHR ||
                   p.bop == ABIN_LAND || p.bop == ABIN_LOR ||
                   p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT ||
                   p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE;
        case APRD_UNOP:
            return p.uop == AUN_NEG || p.uop == AUN_NOT || p.uop == AUN_BITNOT;
        case APRD_COERCE: case APRD_TUPLE: case APRD_ARRAY:
            return true;
        default:
            return false;
    }
}

// substitute_all_prd/_cns/_cmd -- replace every `APRD_VAR name` in a subtree
// with `value`, one use at a time, and report how many were rewritten. Each
// site is checked for type compatibility on its own; a site that does not fit
// is left as it was and the binding stays available for it. The walk mirrors
// scan_* field for field, so a position the census counts as a use is exactly a
// position this rewrite can reach.
fn int OptStats.substitute_all_prd(OptStats* s, AirPrd* p, char* name, AirPrd* value, bool boolean, int depth)
{
    if (p == null || depth >= 128) { return 0; }
    if (p.tag == APRD_VAR && p.name != null && opt_same_name(p.name, name))
    {
        bool fits = false;
        if (boolean) { fits = opt_bool_hint(p.ty) && opt_bool_hint(value.ty); }
        else if (value.tag == APRD_VAR) { fits = opt_variable_substitution_compatible(p, value); }
        else { fits = opt_integer_substitution_compatible(p, value); }
        if (!fits) { return 0; }
        s.replace_with_prd(p, value);
        return 1;
    }
    int replaced = 0;
    for (usz i = 0; i < p.sub_count; i++)
    {
        replaced = replaced + s.substitute_all_prd(p.subs[i], name, value, boolean, depth + 1);
    }
    for (usz i = 0; i < p.rec_init_count; i++)
    {
        if (p.rec_inits[i] != null)
        {
            replaced = replaced + s.substitute_all_prd(p.rec_inits[i].value, name, value, boolean, depth + 1);
        }
    }
    if (p.body != null) { replaced = replaced + s.substitute_all_cmd(p.body, name, value, boolean, depth + 1); }
    return replaced;
}

fn int OptStats.substitute_all_cns(OptStats* s, AirCns* k, char* name, AirPrd* value, bool boolean, int depth)
{
    if (k == null || depth >= 128) { return 0; }
    int replaced = s.substitute_all_prd(k.prd, name, value, boolean, depth + 1);
    for (usz i = 0; i < k.subst_count; i++)
    {
        replaced = replaced + s.substitute_all_prd(k.subst_prds[i], name, value, boolean, depth + 1);
    }
    replaced = replaced + s.substitute_all_cns(k.tail, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cns(k.cont_k, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(k.body, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(k.label_body, name, value, boolean, depth + 1);
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] == null) { continue; }
        replaced = replaced + s.substitute_all_cns(k.branches[i].guard, name, value, boolean, depth + 1);
        replaced = replaced + s.substitute_all_cmd(k.branches[i].body, name, value, boolean, depth + 1);
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        if (k.cobranches[i] == null) { continue; }
        replaced = replaced + s.substitute_all_cmd(k.cobranches[i].body, name, value, boolean, depth + 1);
    }
    return replaced;
}

fn int OptStats.substitute_all_cmd(OptStats* s, AirCmd* c, char* name, AirPrd* value, bool boolean, int depth)
{
    if (c == null || depth >= 128) { return 0; }
    int replaced = s.substitute_all_prd(c.prd, name, value, boolean, depth + 1);
    for (usz i = 0; i < c.prd_count; i++)
    {
        replaced = replaced + s.substitute_all_prd(c.prds[i], name, value, boolean, depth + 1);
    }
    replaced = replaced + s.substitute_all_cns(c.cns, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(c.body, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(c.next, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(c.then_c, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(c.else_c, name, value, boolean, depth + 1);
    replaced = replaced + s.substitute_all_cmd(c.handled, name, value, boolean, depth + 1);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if (c.branches[i] == null) { continue; }
        replaced = replaced + s.substitute_all_cmd(c.branches[i].guard, name, value, boolean, depth + 1);
        replaced = replaced + s.substitute_all_cmd(c.branches[i].body, name, value, boolean, depth + 1);
    }
    return replaced;
}

// propagate_let -- the pass-3 rewrite for one `let`. It reports whether it
// changed anything so the caller knows to re-fold the body it just rewrote.
fn bool OptStats.propagate_let(OptStats* s, AirCmd* c, int depth)
{
    if (c == null || c.tag != ACMD_LET || c.binder == null || c.prd == null || c.body == null || c.next != null) { return false; }
    // `_` is the discard binder: there is nothing to propagate, and the name is
    // not unique by construction.
    if (opt_same_name(c.binder, (char*)"_")) { return false; }
    bool boolean = c.prd.tag == APRD_BOOL;
    bool copy = c.prd.tag == APRD_VAR;
    if (!boolean && !copy && c.prd.tag != APRD_INT) { return false; }
    if (boolean) { if (!opt_bool_hint(c.prd.ty)) { return false; } }
    else if (!copy) { if (!opt_integer_hint(c.prd.ty)) { return false; } }
    int var_uses = 0;
    bool blocked = false;
    s.scan_cmd(c.body, c.binder, &var_uses, &blocked, 0);
    if (blocked || var_uses == 0) { return false; }
    if (copy)
    {
        // Copy propagation of a binding, which pass 2 and the emitter both
        // refuse: `let x = y in body` may only be rewritten when `y` cannot
        // mean anything else anywhere in `body`. The census answers exactly
        // that question -- a name that never appears in a binder position
        // inside `body` has one value there, so replacing a use of `x` with `y`
        // cannot observe a later write. (The emitter cannot make this call,
        // because `let x = y` is a snapshot of a load there; here it is a
        // statement about AIR names.)
        if (c.prd.name == null || opt_same_name(c.prd.name, (char*)"_")) { return false; }
        if (opt_same_name(c.binder, c.prd.name)) { return false; }
        int source_uses = 0;
        bool source_blocked = false;
        s.scan_cmd(c.body, c.prd.name, &source_uses, &source_blocked, 0);
        if (source_blocked) { return false; }
    }
    int replaced = s.substitute_all_cmd(c.body, c.binder, c.prd, boolean, depth + 1);
    if (replaced == 0) { return false; }
    if (copy) { s.copy_bindings = s.copy_bindings + 1; }
    else { s.propagated_bindings = s.propagated_bindings + 1; }
    s.let_specializations = s.let_specializations + 1;
    return true;
}

// opt_ty_hint_equals -- do two type hints describe the same value? An absent
// hint is not equal to a present one: the emitter resolves an untyped producer
// from context, so the two are not interchangeable.
fn bool opt_ty_hint_equals(AirTyp* a, AirTyp* b)
{
    if (a == b) { return true; }
    if (a == null || b == null) { return false; }
    if (a.tag != b.tag || a.arg_count != b.arg_count) { return false; }
    if (a.tag == ATYP_ARRAY && a.ival != b.ival) { return false; }
    if (a.tag == ATYP_NOMINAL && !opt_same_name(a.name, b.name)) { return false; }
    for (usz i = 0; i < a.arg_count; i++)
    {
        if (!opt_ty_hint_equals(a.args[i], b.args[i])) { return false; }
    }
    return true;
}

// opt_prd_equals -- structural equality for the pure producers opt_pure_value
// accepts. There is no call, load, or allocation form to compare, so two pure
// trees denote the same value exactly when their operators, leaves, names, and
// type hints agree. Anything with a body or binders is refused rather than
// compared.
//
// Three shapes are excluded even though they are pure, because equal *content*
// is not equal *value* for them: a string or byte literal is a pointer to a
// distinct global per occurrence, and a float can be `-0.0` where the other is
// `0.0` (which compare equal but behave differently) or `NaN` (which never
// compares equal). Reusing one for the other would be observable.
fn bool opt_prd_equals(AirPrd* a, AirPrd* b, int depth)
{
    if (a == b) { return true; }
    if (a == null || b == null || depth >= 32) { return false; }
    if (a.tag != b.tag || a.bop != b.bop || a.uop != b.uop) { return false; }
    if (a.body != null || b.body != null || a.binder_count != 0 || b.binder_count != 0) { return false; }
    if (a.rec_init_count != 0 || b.rec_init_count != 0) { return false; }
    if (!opt_ty_hint_equals(a.ty, b.ty) || !opt_ty_hint_equals(a.ty_arg, b.ty_arg)) { return false; }
    if (!opt_same_name(a.name, b.name)) { return false; }
    if (a.sub_count != b.sub_count) { return false; }
    if (a.tag == APRD_STRING || a.tag == APRD_BYTES || a.tag == APRD_FLOAT) { return false; }
    if (a.tag == APRD_INT && a.ival != b.ival) { return false; }
    if (a.tag == APRD_BOOL && a.bval != b.bval) { return false; }
    if (a.tag == APRD_CHAR && a.cval != b.cval) { return false; }
    for (usz i = 0; i < a.sub_count; i++)
    {
        if (!opt_prd_equals(a.subs[i], b.subs[i], depth + 1)) { return false; }
    }
    return true;
}

// cse_lookup -- the most recent enclosing let binder whose pure value is
// structurally identical to `value`, provided that binder cannot be shadowed
// anywhere in `body`. The census check is what keeps the reuse honest: a name
// that some binder position below mentions may denote a different value there,
// so that entry is skipped rather than trusted.
fn char* OptStats.cse_lookup(OptStats* s, AirPrd* value, AirCmd* body)
{
    if (s == null || value == null || body == null) { return null; }
    for (int i = s.cse_count - 1; i >= 0; i--)
    {
        char* name = s.cse_names[(usz)i];
        if (name == null) { continue; }
        if (!opt_prd_equals(s.cse_values[(usz)i], value, 0)) { continue; }
        int var_uses = 0;
        bool blocked = false;
        s.scan_cmd(body, name, &var_uses, &blocked, 0);
        if (blocked) { continue; }
        return name;
    }
    return null;
}

// rewrite_to_var -- turn one producer node into a reference to an existing
// binder. The node keeps its own type hint, so the rewrite cannot silently
// retype the use; every other field is cleared so the emitter cannot read a
// stale literal out of the old shape.
fn void OptStats.rewrite_to_var(OptStats* s, AirPrd* p, char* name)
{
    if (s == null || p == null || name == null) { return; }
    AirTyp* hint = p.ty;
    p.tag = APRD_VAR;
    p.name = name;
    p.ival = 0;
    p.fval = 0.0;
    p.bval = false;
    p.cval = 0;
    p.subs = null;
    p.sub_count = 0;
    p.sub_cap = 0;
    p.bytes = null;
    p.bytes_len = 0;
    p.binder_count = 0;
    p.body = null;
    p.ty_arg = null;
    p.rec_inits = null;
    p.rec_init_count = 0;
    p.rec_init_cap = 0;
    p.ty = hint;
    s.rewrites = s.rewrites + 1;
    s.operand_rewrites = s.operand_rewrites + 1;
}

// ===== pass 3: control-flow folding =========================================
//
// AIR control flow is structured, but two shapes are still statically decided
// once the condition or subject is a literal -- which pass 3's propagation is
// what usually makes it one:
//
//   `while false`        the body cannot run, so the loop is a no-op.
//   `match <literal>`    exactly one unguarded arm can be selected, so the
//                        dispatch disappears.
//
// Both are restricted to the case where the answer does not depend on anything
// but the literal: a guarded arm is a runtime condition, and a `bind` pattern
// would introduce a name, so either one stops the fold instead of guessing.

// opt_terminates -- does this command always transfer control away before the
// continuation that follows it? Used to drop the unreachable remainder of a
// sequence; anything that can fall through reports false.
fn bool opt_terminates(AirCmd* c, int depth)
{
    if (c == null || depth >= 64) { return false; }
    if (c.tag == ACMD_RET || c.tag == ACMD_JUMP || c.tag == ACMD_BREAK || c.tag == ACMD_CONTINUE || c.tag == ACMD_TRAP) { return true; }
    if (c.tag == ACMD_SEQ) { return opt_terminates(c.body, depth + 1) || opt_terminates(c.next, depth + 1); }
    if (c.tag == ACMD_BLOCK || c.tag == ACMD_UNCHECKED || c.tag == ACMD_UNSAFE || c.tag == ACMD_COMPTIME)
    {
        return opt_terminates(c.body, depth + 1);
    }
    if (c.tag == ACMD_IF)
    {
        return c.then_c != null && c.else_c != null && opt_terminates(c.then_c, depth + 1) && opt_terminates(c.else_c, depth + 1);
    }
    return false;
}

// match_literal_arm -- the single arm a literal subject must select, or null
// when the dispatch needs a run-time decision.
fn AirCmd* OptStats.match_literal_arm(OptStats* s, AirCmd* c)
{
    if (c == null || c.tag != ACMD_MATCH || c.prd == null || c.branch_count == 0) { return null; }
    if (c.cobranch_count != 0) { return null; }
    AirPrd* subject = c.prd;
    bool is_int = subject.tag == APRD_INT;
    bool is_bool = subject.tag == APRD_BOOL;
    bool is_char = subject.tag == APRD_CHAR;
    if (!is_int && !is_bool && !is_char) { return null; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* b = c.branches[i];
        if (b == null || b.pat == null) { return null; }
        // A guard is a run-time condition, so nothing after it is decidable.
        if (b.guard != null) { return null; }
        AirPat* pat = b.pat;
        if (pat.tag == APAT_WILD) { return b.body; }
        if (pat.tag == APAT_INT && is_int && pat.ival == subject.ival) { return b.body; }
        if (pat.tag == APAT_BOOL && is_bool && (pat.ival != 0) == subject.bval) { return b.body; }
        if (pat.tag == APAT_CHAR && is_char && pat.ival == (long)subject.cval) { return b.body; }
        // Another literal arm simply does not match and the search continues; any
        // other pattern (bind, tuple, record, variant, or-pattern, range) either
        // introduces a name or needs the value, so it stops the fold.
        if (pat.tag == APAT_INT && is_int) { continue; }
        if (pat.tag == APAT_BOOL && is_bool) { continue; }
        if (pat.tag == APAT_CHAR && is_char) { continue; }
        return null;
    }
    return null;
}

// match_single_arm -- a `match` with exactly one unguarded arm that cannot fail
// is a binding, not a dispatch.
//
//   match s { _ -> body }        ->  body            (s must be pure)
//   match s { bind x -> body }   ->  let x = s in body
//
// The `bind` form becomes a real `let` rather than a substitution so the
// subject keeps its evaluation position: a match evaluates the subject before
// the body, and so does a let. The `let` then feeds the ordinary machinery --
// if the subject is a literal, pass 3 propagates it into the body and pass 2
// removes the binding, so the whole dispatch disappears without this pass
// knowing anything about literals.
fn AirCmd* OptStats.match_single_arm(OptStats* s, AirCmd* c)
{
    if (s == null || s.arena == null || c == null || c.tag != ACMD_MATCH) { return null; }
    if (c.branch_count != 1 || c.cobranch_count != 0 || c.branches[0] == null) { return null; }
    AirBranch* arm = c.branches[0];
    if (arm.guard != null || arm.pat == null || arm.body == null) { return null; }
    AirCmd* body = arm.body;
    if (arm.pat.tag == APAT_WILD)
    {
        // Nothing names the subject, so it is dropped: only legal when dropping
        // it cannot discard work.
        if (!opt_pure_value(c.prd, 0)) { return null; }
        s.rewrites = s.rewrites + 1;
        s.match_folds = s.match_folds + 1;
        return body;
    }
    if (arm.pat.tag != APAT_BIND || arm.pat.name == null) { return null; }
    AirCmd* let = air_ir::air_new_AirCmd(s.arena);
    if (let == null) { return null; }
    let.tag = ACMD_LET;
    let.binder = arm.pat.name;
    let.prd = c.prd;
    let.body = body;
    let.source_line = c.source_line;
    let.source_col = c.source_col;
    s.rewrites = s.rewrites + 1;
    s.match_folds = s.match_folds + 1;
    return let;
}

// cse_let -- bind `c`'s pure value to an earlier identical one when the chain
// already computed it, then publish `c`'s own binder for the subtree below.
fn void OptStats.cse_let(OptStats* s, AirCmd* c)
{
    if (s == null || c == null || c.tag != ACMD_LET || c.binder == null || c.prd == null || c.body == null) { return; }
    if (opt_same_name(c.binder, (char*)"_") || !opt_pure_value(c.prd, 0)) { return; }
    char* earlier = s.cse_lookup(c.prd, c.body);
    if (earlier != null)
    {
        s.rewrite_to_var(c.prd, earlier);
        s.cse_replacements = s.cse_replacements + 1;
        return;
    }
    // Shadowing: an inner binder that reuses this name ends the visibility of
    // everything below its entry, so truncate there.
    for (int i = 0; i < s.cse_count; i++)
    {
        if (opt_same_name(s.cse_names[(usz)i], c.binder)) { s.cse_count = i; break; }
    }
    if (s.cse_count < 16)
    {
        s.cse_names[(usz)s.cse_count] = c.binder;
        s.cse_values[(usz)s.cse_count] = c.prd;
        s.cse_count = s.cse_count + 1;
    }
}

// optimize_prd -- bottom-up rewrite of one producer. Substitution sites are
// rewritten in place by substitute_all_*; this walk is the folding half.
// ===== pass 1: algebraic reassociation and self-folding ====================
//
// Two families of rewrites that need nothing but the shape of one expression:
//
//   reassociation   `(x op c1) op c2` where both constants have the operand's
//                   own width folds to `x op (c1 op c2)`, because the host
//                   computes the constant part exactly and the rewrite refuses
//                   when it would overflow.
//   self-folding    `x - x`, `x ^ x`, `x & x`, `x | x`, and the comparisons of
//                   a value with itself. These are decided by the operand, not
//                   by a literal, and the operand has to be pure for the fold to
//                   be observable-free -- `(div y 0) - (div y 0)` traps twice at
//                   run time and must not become `0`.

// opt_same_pure_operand -- are the two operands the same pure expression? This
// is the structural-equality test pass 3 already uses for its value table, with
// the same exclusions (a string literal is a distinct global per occurrence).
fn bool opt_same_pure_operand(AirPrd* a, AirPrd* b)
{
    if (a == null || b == null) { return false; }
    if (!opt_pure_value(a, 0)) { return false; }
    return opt_prd_equals(a, b, 0);
}

// reassociate_constant -- `(x op c1) op c2` with two in-range integer constants
// becomes `x op (c1 op c2)`. Handled combinations are the ones that are exactly
// associative in a wrapping integer type once the constant part is proven to fit:
//
//   (x + c1) + c2   ->  x + (c1 + c2)
//   (x + c1) - c2   ->  x + (c1 - c2)
//   (x - c1) + c2   ->  x + (c2 - c1)
//   (x - c1) - c2   ->  x - (c1 + c2)
//   (x * c1) * c2   ->  x * (c1 * c2)
//   (x & c1) & c2   ->  x & (c1 & c2)
//   (x | c1) | c2   ->  x | (c1 | c2)
//   (x ^ c1) ^ c2   ->  x ^ (c1 ^ c2)
//
// The `+`/`-`/`*` forms additionally require that the folded constant does not
// overflow the host `long` accumulator; the bitwise forms cannot.
//
// Reassociation cannot change trap behaviour: PEAR 2 emits wrapping integer
// arithmetic (a plain LLVM `add`/`sub`/`mul`, no `nsw`/`nuw`), so the value of
// the expression is the same regardless of how the constants group. The fold
// still refuses whenever the folded constant is not representable in the
// operation's width, which keeps the rewrite inside the subset the emitter can
// spell.
fn bool OptStats.reassociate_constant(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.sub_count != 2) { return false; }
    AirPrd* inner = p.subs[0];
    AirPrd* outer_constant = p.subs[1];
    if (inner == null || outer_constant == null || inner.tag != APRD_BINOP || inner.sub_count != 2) { return false; }
    AirPrd* value = inner.subs[0];
    AirPrd* inner_constant = inner.subs[1];
    if (value == null || inner_constant == null || inner_constant.tag != APRD_INT || outer_constant.tag != APRD_INT) { return false; }
    if (!opt_integer_operation(p) || !opt_integer_operation(inner)) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* inner_type = opt_resolved_integer_type(inner);
    if (operation_type == null || inner_type == null) { return false; }
    int bits = opt_integer_bits(operation_type);
    bool uns = opt_unsigned(operation_type);
    if (bits <= 0 || bits > 64) { return false; }
    if (opt_integer_bits(inner_type) != bits || opt_unsigned(inner_type) != uns) { return false; }
    long a = inner_constant.ival;
    long b = outer_constant.ival;
    if (!opt_integer_fits(a, bits, uns) || !opt_integer_fits(b, bits, uns)) { return false; }
    // Keep the host arithmetic below far away from `long` overflow: the largest
    // magnitude that can appear in the constant part is bounded by 2^(bits-1),
    // and every combination below stays under four times that. `LONG_MIN` is
    // excluded outright because negating it overflows.
    if (a == (-9223372036854775807L - 1) || b == (-9223372036854775807L - 1)) { return false; }
    long magnitude_limit = bits >= 61 ? 1152921504606846976L : (1L << (bits - 1));
    AirBinop outer_op = p.bop;
    AirBinop inner_op = inner.bop;
    long folded = 0;
    AirBinop result_op = outer_op;
    bool additive = outer_op == ABIN_ADD || outer_op == ABIN_SUB;
    if (additive)
    {
        // Normalise to `x + ( ... )` for `+`, `x - ( ... )` for `-`.
        long sign = outer_op == ABIN_ADD ? 1 : -1;
        long inner_sign = inner_op == ABIN_ADD ? 1 : (inner_op == ABIN_SUB ? -1 : 0);
        if (inner_sign == 0) { return false; }
        if (b <= -magnitude_limit || b >= magnitude_limit || a <= -magnitude_limit || a >= magnitude_limit) { return false; }
        long sum = sign * b + inner_sign * a;
        if (sum == 0)
        {
            // The constants cancel: the whole operation is the value itself.
            s.replace_with_prd(p, value);
            s.rewrites = s.rewrites + 1;
            s.reassociations = s.reassociations + 1;
            return true;
        }
        if (sum > 0) { result_op = ABIN_ADD; folded = sum; }
        else { result_op = ABIN_SUB; folded = -sum; }
        if (!opt_integer_fits(folded, bits, uns)) { return false; }
    }
    else if (outer_op == ABIN_MUL)
    {
        if (inner_op != ABIN_MUL) { return false; }
        if (a == 0 || b == 0) { folded = 0; }
        else
        {
            long scale = a > 0 ? a : -a;
            if (b > 9223372036854775807L / scale || b < (-9223372036854775807L - 1) / scale) { return false; }
            folded = a * b;
        }
        if (!opt_integer_fits(folded, bits, uns)) { return false; }
        result_op = ABIN_MUL;
    }
    else if (outer_op == ABIN_AND || outer_op == ABIN_OR || outer_op == ABIN_XOR)
    {
        if (inner_op != outer_op) { return false; }
        if (outer_op == ABIN_AND) { folded = a & b; }
        else if (outer_op == ABIN_OR) { folded = a | b; }
        else { folded = a ^ b; }
        if (!opt_integer_fits(folded, bits, uns)) { return false; }
        result_op = outer_op;
    }
    else { return false; }
    AirPrd* constant = s.new_integer_literal(folded, operation_type);
    if (constant == null) { return false; }
    // Keep the outer constant's ascription when it has one: it is the spelling
    // the emitter would have produced for that operand had it been folded by
    // hand, down to the narrow-width annotation.
    if (outer_constant.ty != null) { constant.ty = outer_constant.ty; }
    p.bop = result_op;
    p.subs[0] = value;
    p.subs[1] = constant;
    s.rewrites = s.rewrites + 1;
    s.reassociations = s.reassociations + 1;
    return true;
}

// fold_self_operands -- decide an operation whose two operands are the same pure
// expression. Report whether the node was replaced.
// opt_self_foldable -- may this operation be decided without looking at its
// value? The answer needs a type witness, because an AIR binop carries no
// type of its own: `<(sub a b) | %ret>` is the spelling of float subtraction
// just as much as integer subtraction, and `a - a` is zero for one and NaN for
// the other. The witness is an integer (or boolean, for a comparison)
// ascription on the operation itself; a float ascription, or a float hint on
// either operand, refuses outright. An entirely untyped operation is left alone
// rather than guessed at.
fn bool opt_self_foldable(AirPrd* p)
{
    if (p == null || p.tag != APRD_BINOP || p.sub_count != 2) { return false; }
    bool comparison = p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE;
    bool arithmetic = p.bop == ABIN_SUB || p.bop == ABIN_XOR || p.bop == ABIN_AND || p.bop == ABIN_OR;
    if (!comparison && !arithmetic) { return false; }
    if (p.ty == null || p.ty.tag == ATYP_INFER) { return false; }
    // A boolean ascription witnesses a comparison or a boolean AND/OR, where the
    // two operands are the same predicate; anything else boolean-typed is not an
    // operation this pass can decide.
    bool boolean_witness = comparison || p.bop == ABIN_AND || p.bop == ABIN_OR;
    bool witness = p.ty.tag == ATYP_BOOL ? boolean_witness : opt_integer_type(p.ty);
    if (!witness) { return false; }
    for (usz i = 0; i < 2; i++)
    {
        AirTyp* hint = p.subs[i] != null ? p.subs[i].ty : null;
        if (hint == null || hint.tag == ATYP_INFER) { continue; }
        if (hint.tag == ATYP_F32 || hint.tag == ATYP_F64) { return false; }
    }
    return true;
}

fn bool OptStats.fold_self_operands(OptStats* s, AirPrd* p)
{
    if (s == null || p == null || p.tag != APRD_BINOP || p.sub_count != 2) { return false; }
    if (!opt_self_foldable(p)) { return false; }
    if (!opt_same_pure_operand(p.subs[0], p.subs[1])) { return false; }
    // An arithmetic result keeps the integer representation; a comparison
    // becomes a boolean literal, which is what the emitter expects from a
    // comparison in a condition position.
    switch (p.bop)
    {
        case ABIN_SUB:
        case ABIN_XOR:
            s.set_int(p, 0);
            s.self_folds = s.self_folds + 1;
            return true;
        case ABIN_AND:
        case ABIN_OR:
            s.replace_with_prd(p, p.subs[0]);
            s.self_folds = s.self_folds + 1;
            return true;
        case ABIN_EQ:
        case ABIN_LE:
        case ABIN_GE:
            s.set_bool(p, true);
            s.self_folds = s.self_folds + 1;
            return true;
        case ABIN_NEQ:
        case ABIN_LT:
        case ABIN_GT:
            s.set_bool(p, false);
            s.self_folds = s.self_folds + 1;
            return true;
        default:
            return false;
    }
}

fn AirPrd* OptStats.optimize_prd(OptStats* s, AirPrd* p, int depth)
{
    if (p == null || depth >= 128) { return p; }
    for (usz i = 0; i < p.sub_count; i++) { p.subs[i] = s.optimize_prd(p.subs[i], depth + 1); }
    for (usz i = 0; i < p.rec_init_count; i++)
    {
        if (p.rec_inits[i] != null) { p.rec_inits[i].value = s.optimize_prd(p.rec_inits[i].value, depth + 1); }
    }
    if (p.body != null) { p.body = s.optimize_cmd(p.body, depth + 1); }
    if (p.tag == APRD_BINOP)
    {
        // Order matters: reassociation first, because it can expose a constant
        // fold (`(x + 1) + 2` -> `x + 3` -> the fold sees two constants only if
        // x is one too), then the identity/fold machinery, then self-folding.
        s.reassociate_constant(p);
        s.fold_binary(p);
        s.fold_self_operands(p);
    }
    else if (p.tag == APRD_UNOP) { s.fold_unary(p); }
    else if (p.tag == APRD_COERCE) { s.fold_coerce(p); }
    return p;
}

fn AirCns* OptStats.optimize_cns(OptStats* s, AirCns* k, int depth)
{
    if (k == null || depth >= 128) { return k; }
    k.prd = s.optimize_prd(k.prd, depth + 1);
    k.tail = s.optimize_cns(k.tail, depth + 1);
    k.cont_k = s.optimize_cns(k.cont_k, depth + 1);
    k.body = s.optimize_cmd(k.body, depth + 1);
    k.label_body = s.optimize_cmd(k.label_body, depth + 1);
    for (usz i = 0; i < k.subst_count; i++) { k.subst_prds[i] = s.optimize_prd(k.subst_prds[i], depth + 1); }
    for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null) { k.branches[i].body = s.optimize_cmd(k.branches[i].body, depth + 1); } }
    for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null) { k.cobranches[i].body = s.optimize_cmd(k.cobranches[i].body, depth + 1); } }
    return k;
}

fn AirCmd* OptStats.optimize_cmd(OptStats* s, AirCmd* c, int depth)
{
    if (c == null || depth >= 128) { return c; }
    c.prd = s.optimize_prd(c.prd, depth + 1);
    for (usz i = 0; i < c.prd_count; i++) { c.prds[i] = s.optimize_prd(c.prds[i], depth + 1); }
    c.cns = s.optimize_cns(c.cns, depth + 1);
    if (c.tag == ACMD_LET && c.binder != null && c.prd != null && c.prd.tag == APRD_BOOL && opt_bool_hint(c.prd.ty) &&
        c.body != null && c.body.tag == ACMD_IF && opt_condition_tree(c.body.prd, 0))
    {
        // Substitute only inside a restricted, side-effect-free boolean tree
        // used as the immediate if-condition. Retain the let binding so any
        // other uses in either branch remain in scope.
        if (s.substitute_bool_var(c.body.prd, c.binder, c.prd, 0))
        {
            c.body.prd = s.optimize_prd(c.body.prd, depth + 1);
            c.body = s.optimize_cmd(c.body, depth + 1);
            s.rewrites++;
            s.let_specializations++;
        }
    }
    if (c.tag == ACMD_LET && c.binder != null && c.prd != null && c.prd.tag == APRD_INT &&
        opt_integer_hint(c.prd.ty) && c.body != null && (c.body.tag == ACMD_RET || c.body.tag == ACMD_CUT) &&
        opt_integer_expr_tree(c.body.prd, 0) && opt_validate_integer_substitution(c.body.prd, c.binder, c.prd, 0))
    {
        // Integer propagation is limited to a pure scalar expression in the
        // immediate return/cut value. Keep the binding intact for all other uses.
        if (s.substitute_integer_var(c.body.prd, c.binder, c.prd, 0))
        {
            c.body.prd = s.optimize_prd(c.body.prd, depth + 1);
            s.rewrites++;
            s.let_specializations++;
        }
    }
    if (c.tag == ACMD_LET && c.binder != null && c.prd != null && c.prd.tag == APRD_INT &&
        opt_integer_hint(c.prd.ty) && c.body != null && c.body.tag == ACMD_LET && c.body.binder != null &&
        c.body.prd != null && opt_integer_expr_tree(c.body.prd, 0) &&
        opt_validate_integer_substitution(c.body.prd, c.binder, c.prd, 0))
    {
        // Propagate through one immediate nested initializer only. The inner
        // let is optimized recursively afterward and can propagate its own
        // constant; neither binding is removed, and unsupported/effectful
        // initializer forms are left alone.
        if (s.substitute_integer_var(c.body.prd, c.binder, c.prd, 0))
        {
            c.body.prd = s.optimize_prd(c.body.prd, depth + 1);
            s.rewrites++;
            s.let_specializations++;
        }
    }
    if (c.tag == ACMD_IF && c.prd != null && c.prd.tag == APRD_BOOL)
    {
        AirCmd* selected = c.prd.bval ? c.then_c : c.else_c;
        if (selected != null)
        {
            s.rewrites++;
            s.branch_reductions++;
            return s.optimize_cmd(selected, depth + 1);
        }
    }
    // Pass 3's value table is scoped to the descendants of this command: the
    // binder published here is visible in them and nowhere else.
    int saved_cse = s.cse_count;
    if (s.propagate_bindings) { s.cse_let(c); }
    c.body = s.optimize_cmd(c.body, depth + 1);
    c.next = s.optimize_cmd(c.next, depth + 1);
    c.then_c = s.optimize_cmd(c.then_c, depth + 1);
    c.else_c = s.optimize_cmd(c.else_c, depth + 1);
    c.handled = s.optimize_cmd(c.handled, depth + 1);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if (c.branches[i] != null)
        {
            c.branches[i].guard = s.optimize_cmd(c.branches[i].guard, depth + 1);
            c.branches[i].body = s.optimize_cmd(c.branches[i].body, depth + 1);
        }
    }
    s.cse_count = saved_cse;
    // Pass 3 control-flow folding: a loop whose condition is a literal false, a
    // dispatch on a literal subject, and the unreachable tail of a sequence.
    // All three are decided by the literal alone, so none of them needs the CFG
    // an AIR-level dataflow pass would otherwise require.
    if (s.propagate_bindings)
    {
        // Sequence cleanup. `seq { nop; rest }` and `seq { x; nop }` carry no
        // meaning beyond `rest` and `x`: `nop` is the unit value, not an
        // instruction, so dropping it cannot reorder or discard work. This is
        // worth doing here rather than leaving to LLVM because the fold above
        // *creates* the shape -- an eliminated loop leaves `seq { nop; rest }`
        // behind, and a later pass that looks for a trailing cut would see it.
        if (c.tag == ACMD_SEQ && c.body != null && c.body.tag == ACMD_NOP && c.next != null)
        {
            s.rewrites = s.rewrites + 1;
            return s.optimize_cmd(c.next, depth + 1);
        }
        if (c.tag == ACMD_SEQ && c.next != null && c.next.tag == ACMD_NOP)
        {
            s.rewrites = s.rewrites + 1;
            return c.body;
        }
        // A block with one command is the command: AIR blocks exist to give a
        // binder a scope, and a single child subtree cannot observe the scope it
        // was given.
        if (c.tag == ACMD_BLOCK && c.body != null && c.next == null)
        {
            s.rewrites = s.rewrites + 1;
            return s.optimize_cmd(c.body, depth + 1);
        }
        if (c.tag == ACMD_WHILE && c.prd != null && c.prd.tag == APRD_BOOL && !c.prd.bval && s.arena != null)
        {
            AirCmd* nop = air_ir::air_new_AirCmd(s.arena);
            if (nop != null)
            {
                nop.tag = ACMD_NOP;
                s.rewrites = s.rewrites + 1;
                s.loop_eliminations = s.loop_eliminations + 1;
                return nop;
            }
        }
        // A one-armed, unguarded match cannot dispatch: it either binds the
        // subject or ignores it. Folding it first is what lets a literal subject
        // reach the propagation above on the next descent instead of being
        // re-emitted as a switch with a single block.
        AirCmd* single = s.match_single_arm(c);
        if (single != null) { return s.optimize_cmd(single, depth + 1); }
        AirCmd* arm = s.match_literal_arm(c);
        if (arm != null)
        {
            s.rewrites = s.rewrites + 1;
            s.literal_matches = s.literal_matches + 1;
            return s.optimize_cmd(arm, depth + 1);
        }
        if (c.tag == ACMD_SEQ && c.next != null && opt_terminates(c.body, 0))
        {
            s.rewrites = s.rewrites + 1;
            s.dead_commands = s.dead_commands + 1;
            c.next = null;
        }
    }
    // Pass 3 propagates a literal to every use in the body, then re-folds what
    // the substitution exposed. The re-fold is a second descent on purpose: the
    // census is already paid for, and folding is what turns a propagated
    // constant into a shorter program rather than a renamed one.
    if (s.propagate_bindings && s.propagate_let(c, depth))
    {
        c.body = s.optimize_cmd(c.body, depth + 1);
    }
    // Pass 2 runs on the already-rewritten body, so a binding that folding made
    // dead is seen in its final shape.
    // c.next is only used by ACMD_SEQ, but requiring it to be null keeps the
    // rewrite honest if a reader ever attaches a trailing continuation to a let.
    // Pass 3 widens what counts as removable from "inert" to "pure": an
    // initializer that computes a value but cannot trap, call, allocate, or
    // touch memory is dead work once nothing reads the binding.
    bool inert_value = opt_droppable_value(c.prd);
    bool pure_value = !inert_value && s.propagate_bindings && opt_pure_value(c.prd, 0);
    if ((s.drop_dead || s.propagate_bindings) && (inert_value || pure_value) &&
        c.tag == ACMD_LET && c.binder != null && c.body != null && c.next == null)
    {
        int var_uses = 0;
        bool blocked = false;
        s.scan_cmd(c.body, c.binder, &var_uses, &blocked, 0);
        if (!blocked && var_uses == 0)
        {
            // The body cannot see the binding, and the value is either inert or
            // pure, so removing it can discard neither an effect nor a trap.
            if (inert_value) { s.dead_bindings = s.dead_bindings + 1; }
            else { s.pure_dead_bindings = s.pure_dead_bindings + 1; }
            s.rewrites = s.rewrites + 1;
            return c.body;
        }
    }
    return c;
}

// optimize_module_at -- one pass of the pipeline at a given -O tier. The tier
// decides *which* passes run, not just how many times:
//
//   -O1        pass 1 only: folding, identities, strength reduction, shift
//              combination, literal branches, constant-let specialization.
//   -O2        pass 1 + pass 2: the dead-binding sweep, still expression-local.
//   -O3        pass 1 + pass 2 + pass 3: whole-body name census, so a constant
//              reaches every use in the body and a pure-but-unused initializer
//              is removable.
//
// pear2c repeats the selected set to a fixed point, then LLVM runs
// default<O2>/default<O3> over the module it is given.
//
// Level 0 is handled by the caller, which never calls this function.
fn OptStats optimize_module_at(AirModule* m, int level)
{
    OptStats stats;
    stats.rewrites = 0;
    stats.constant_folds = 0;
    stats.operand_rewrites = 0;
    stats.strength_reductions = 0;
    stats.shift_combinations = 0;
    stats.branch_reductions = 0;
    stats.let_specializations = 0;
    stats.dead_bindings = 0;
    stats.propagated_bindings = 0;
    stats.pure_dead_bindings = 0;
    stats.cse_replacements = 0;
    stats.loop_eliminations = 0;
    stats.literal_matches = 0;
    stats.dead_commands = 0;
    stats.reassociations = 0;
    stats.self_folds = 0;
    stats.match_folds = 0;
    stats.copy_bindings = 0;
    stats.cse_count = 0;
    stats.drop_dead = level >= 2;
    stats.propagate_bindings = level >= 3;
    stats.arena = null;
    if (m == null) { return stats; }
    stats.arena = m.arena;
    for (usz i = 0; i < m.decl_count; i++)
    {
        AirDecl* d = m.decls[i];
        if (d == null) { continue; }
        d.def_body = stats.optimize_cmd(d.def_body, 0);
        d.g_init = stats.optimize_prd(d.g_init, 0);
    }
    return stats;
}

// optimize_module -- full strength (every pass enabled). The structural harness
// (tests/pear2/opt_test.c3) and any caller that wants the final IR regardless of
// tier use this.
fn OptStats optimize_module(AirModule* m)
{
    return optimize_module_at(m, 3);
}
