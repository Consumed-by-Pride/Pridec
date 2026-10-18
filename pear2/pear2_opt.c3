// PEAR 2's conservative AIR optimization pipeline.
//
// This pass avoids target-dependent type guesses and rewrites integer constant
// expressions only when host arithmetic is defined and the result fits the
// resolved integer width (or the default i64 literal representation). Integer
// identities require matching resolved representations; boolean branches must
// reduce to literals. Unsupported or ambiguous expressions remain unchanged.
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
        (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR))
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
        (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR))
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

fn void OptStats.replace_with_unary(OptStats* s, AirPrd* operation, AirPrd* value, AirUnop unary)
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
    s.operand_rewrites++;
}

// Rewrite x * 2^k to x << k only when both operations have the same
// resolved integer representation. Allocate a fresh shift literal instead of
// mutating the multiplication constant, since AIR products may be shared.
fn bool OptStats.strength_reduce_mul(OptStats* s, AirPrd* p)
{
    if (s == null || s.arena == null || p == null || p.tag != APRD_BINOP || p.bop != ABIN_MUL || p.sub_count != 2 ||
        p.subs[0] == null || p.subs[1] == null || p.subs[1].tag != APRD_INT || p.subs[0].tag == APRD_INT) { return false; }
    AirTyp* operation_type = opt_resolved_integer_type(p);
    AirTyp* value_type = opt_resolved_integer_type(p.subs[0]);
    AirTyp* factor_type = opt_resolved_integer_type(p.subs[1]);
    if (operation_type == null) { operation_type = value_type; }
    if (operation_type == null || value_type == null) { return false; }
    int bits = opt_integer_bits(operation_type);
    bool uns = opt_unsigned(operation_type);
    if (bits <= 0 || bits > 64 || opt_integer_bits(value_type) != bits || opt_unsigned(value_type) != uns) { return false; }
    if (factor_type != null && (opt_integer_bits(factor_type) != bits || opt_unsigned(factor_type) != uns)) { return false; }
    long factor = p.subs[1].ival;
    if (factor <= 1 || !opt_integer_fits(factor, bits, uns) || (factor & (factor - 1)) != 0) { return false; }
    int shift = 0;
    while (factor > 1) { factor >>= 1; shift++; }
    AirPrd* shift_count = air_ir::air_new_AirPrd(s.arena);
    if (shift_count == null) { return false; }
    shift_count.tag = APRD_INT;
    shift_count.ival = shift;
    shift_count.ty = p.subs[1].ty;
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
                else { s.replace_with_unary(p, right, AUN_NOT); }
                return;
            }
            if (right.tag == APRD_BOOL)
            {
                bool keep = (p.bop == ABIN_EQ) == right.bval;
                if (keep) { s.replace_with_prd(p, left); }
                else { s.replace_with_unary(p, left, AUN_NOT); }
                return;
            }
        }
        if (p.bop == ABIN_AND && left.tag == APRD_BOOL && left.bval) { s.replace_with_prd(p, right); return; }
        if (p.bop == ABIN_AND && right.tag == APRD_BOOL && right.bval) { s.replace_with_prd(p, left); return; }
        if (p.bop == ABIN_OR && left.tag == APRD_BOOL && !left.bval) { s.replace_with_prd(p, right); return; }
        if (p.bop == ABIN_OR && right.tag == APRD_BOOL && !right.bval) { s.replace_with_prd(p, left); return; }
        if (p.bop == ABIN_XOR && left.tag == APRD_BOOL && left.bval) { s.replace_with_unary(p, right, AUN_NOT); return; }
        if (p.bop == ABIN_XOR && right.tag == APRD_BOOL && right.bval) { s.replace_with_unary(p, left, AUN_NOT); return; }
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
    if (p.bop == ABIN_XOR && opt_all_ones_literal(p, a) && opt_can_return_operand(p, b)) { s.replace_with_unary(p, b, AUN_BITNOT); return; }
    if (p.bop == ABIN_XOR && opt_all_ones_literal(p, b) && opt_can_return_operand(p, a)) { s.replace_with_unary(p, a, AUN_BITNOT); return; }
    if ((p.bop == ABIN_SHL || p.bop == ABIN_SHR || p.bop == ABIN_OR || p.bop == ABIN_XOR) && opt_literal_zero(b) && opt_can_return_operand(p, a)) { s.replace_with_prd(p, a); return; }
    if (p.bop == ABIN_MUL && s.strength_reduce_mul_zero(p)) { return; }
    if (p.bop == ABIN_MUL && s.strength_reduce_mul(p)) { return; }
    if (p.bop == ABIN_MOD && s.strength_reduce_remainder_one(p)) { return; }
    if (p.bop == ABIN_MOD && s.strength_reduce_unsigned_mod(p)) { return; }
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

fn AirPrd* OptStats.optimize_prd(OptStats* s, AirPrd* p, int depth)
{
    if (p == null || depth >= 128) { return p; }
    for (usz i = 0; i < p.sub_count; i++) { p.subs[i] = s.optimize_prd(p.subs[i], depth + 1); }
    for (usz i = 0; i < p.rec_init_count; i++)
    {
        if (p.rec_inits[i] != null) { p.rec_inits[i].value = s.optimize_prd(p.rec_inits[i].value, depth + 1); }
    }
    if (p.body != null) { p.body = s.optimize_cmd(p.body, depth + 1); }
    if (p.tag == APRD_BINOP) { s.fold_binary(p); }
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
    return c;
}

fn OptStats optimize_module(AirModule* m)
{
    OptStats stats;
    stats.rewrites = 0;
    stats.constant_folds = 0;
    stats.operand_rewrites = 0;
    stats.strength_reductions = 0;
    stats.shift_combinations = 0;
    stats.branch_reductions = 0;
    stats.let_specializations = 0;
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
