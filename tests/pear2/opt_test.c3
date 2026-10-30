module pear2_opt_test;

import air_ir;
import pear2_opt;

extern fn int printf(char* fmt, ...);

fn AirPrd* make_int(AirArena* arena, long value, AirTyp* ty)
{
    AirPrd* p = air_ir::air_new_AirPrd(arena);
    p.tag = APRD_INT;
    p.ival = value;
    p.ty = ty;
    return p;
}

fn AirPrd* make_bool(AirArena* arena, bool value, AirTyp* ty)
{
    AirPrd* p = air_ir::air_new_AirPrd(arena);
    p.tag = APRD_BOOL;
    p.bval = value;
    p.ival = value ? 1 : 0;
    p.ty = ty;
    return p;
}

fn AirPrd* make_binop(AirArena* arena, AirBinop op, AirTyp* ty, AirPrd* left, AirPrd* right)
{
    AirPrd* p = air_ir::air_new_AirPrd(arena);
    p.tag = APRD_BINOP;
    p.bop = op;
    p.ty = ty;
    p.add_sub(left);
    p.add_sub(right);
    return p;
}

fn AirPrd* make_coerce(AirArena* arena, AirTyp* target, AirPrd* source)
{
    AirPrd* p = air_ir::air_new_AirPrd(arena);
    p.tag = APRD_COERCE;
    p.ty = target;
    p.add_sub(source);
    return p;
}

fn int main()
{
    AirArena arena;
    if (!arena.init()) { return 1; }
    AirModule mod;
    if (!mod.init(&arena, (char*)"optimizer-test", null)) { arena.destroy(); return 1; }

    // Constant folding preserves the operation's node identity and resolved type.
    AirPrd* lhs = make_int(&arena, 19, mod.t_i64);
    AirPrd* rhs = make_int(&arena, 23, mod.t_i64);
    AirPrd* sum = air_ir::air_new_AirPrd(&arena);
    sum.tag = APRD_BINOP;
    sum.bop = ABIN_ADD;
    sum.ty = mod.t_i64;
    sum.add_sub(lhs);
    sum.add_sub(rhs);
    sum.id = 91;
    AirCmd* ret = air_ir::air_new_AirCmd(&arena);
    ret.tag = ACMD_RET;
    ret.prd = sum;
    AirDecl* fold_decl = air_ir::air_new_AirDecl(&arena);
    fold_decl.tag = ADECL_DEF;
    fold_decl.name = (char*)"fold";
    fold_decl.def_body = ret;
    mod.decls[0] = fold_decl;

    // A resolved integer identity may discard an untyped literal zero only
    // when the retained variable has the same machine representation.
    AirPrd* variable = air_ir::air_new_AirPrd(&arena);
    variable.tag = APRD_VAR;
    variable.name = (char*)"x";
    variable.ty = mod.t_i64;
    AirPrd* zero = make_int(&arena, 0, null);
    AirPrd* subtract = air_ir::air_new_AirPrd(&arena);
    subtract.tag = APRD_BINOP;
    subtract.bop = ABIN_SUB;
    subtract.ty = mod.t_i64;
    subtract.add_sub(variable);
    subtract.add_sub(zero);
    AirCmd* identity_ret = air_ir::air_new_AirCmd(&arena);
    identity_ret.tag = ACMD_RET;
    identity_ret.prd = subtract;
    AirDecl* identity_decl = air_ir::air_new_AirDecl(&arena);
    identity_decl.tag = ADECL_DEF;
    identity_decl.name = (char*)"identity";
    identity_decl.def_body = identity_ret;
    mod.decls[1] = identity_decl;

    // A typed integer comparison folds to a bool, allowing the enclosing
    // literal-boolean branch to be selected in the parent graph.
    AirPrd* comparison = air_ir::air_new_AirPrd(&arena);
    comparison.tag = APRD_BINOP;
    comparison.bop = ABIN_LT;
    comparison.ty = mod.t_bool;
    comparison.add_sub(make_int(&arena, 1, mod.t_i64));
    comparison.add_sub(make_int(&arena, 2, mod.t_i64));
    AirPrd* logical_not = air_ir::air_new_AirPrd(&arena);
    logical_not.tag = APRD_UNOP;
    logical_not.uop = AUN_NOT;
    logical_not.ty = mod.t_bool;
    logical_not.add_sub(comparison);
    AirPrd* negation = air_ir::air_new_AirPrd(&arena);
    negation.tag = APRD_UNOP;
    negation.uop = AUN_NEG;
    negation.ty = mod.t_i32;
    negation.add_sub(make_int(&arena, 17, mod.t_i32));
    AirCmd* neg_ret = air_ir::air_new_AirCmd(&arena);
    neg_ret.tag = ACMD_RET;
    neg_ret.prd = negation;
    AirDecl* neg_decl = air_ir::air_new_AirDecl(&arena);
    neg_decl.tag = ADECL_DEF;
    neg_decl.name = (char*)"negate";
    neg_decl.def_body = neg_ret;
    mod.decls[7] = neg_decl;

    AirPrd* bitnot = air_ir::air_new_AirPrd(&arena);
    bitnot.tag = APRD_UNOP;
    bitnot.uop = AUN_BITNOT;
    bitnot.ty = mod.t_u8;
    bitnot.add_sub(make_int(&arena, 0, mod.t_u8));
    AirCmd* bitnot_ret = air_ir::air_new_AirCmd(&arena);
    bitnot_ret.tag = ACMD_RET;
    bitnot_ret.prd = bitnot;
    AirDecl* bitnot_decl = air_ir::air_new_AirDecl(&arena);
    bitnot_decl.tag = ADECL_DEF;
    bitnot_decl.name = (char*)"bitnot";
    bitnot_decl.def_body = bitnot_ret;
    mod.decls[8] = bitnot_decl;

    AirCmd* then_ret = air_ir::air_new_AirCmd(&arena);
    then_ret.tag = ACMD_RET;
    then_ret.prd = make_int(&arena, 1, mod.t_i64);
    AirCmd* else_ret = air_ir::air_new_AirCmd(&arena);
    else_ret.tag = ACMD_RET;
    else_ret.prd = make_int(&arena, 0, mod.t_i64);
    AirCmd* branch = air_ir::air_new_AirCmd(&arena);
    branch.tag = ACMD_IF;
    branch.prd = logical_not;
    branch.then_c = then_ret;
    branch.else_c = else_ret;
    AirDecl* branch_decl = air_ir::air_new_AirDecl(&arena);
    branch_decl.tag = ADECL_DEF;
    branch_decl.name = (char*)"branch";
    branch_decl.def_body = branch;
    mod.decls[2] = branch_decl;

    // A constant bool let can specialize its immediate if condition while
    // retaining the binding for any possible uses inside the selected branch.
    AirPrd* let_not = air_ir::air_new_AirPrd(&arena);
    let_not.tag = APRD_UNOP;
    let_not.uop = AUN_NOT;
    let_not.ty = mod.t_bool;
    let_not.add_sub(air_ir::air_mk_prd_bool(&arena, false));
    AirPrd* let_condition = air_ir::air_new_AirPrd(&arena);
    let_condition.tag = APRD_VAR;
    let_condition.name = (char*)"known";
    let_condition.ty = mod.t_bool;
    AirPrd* let_compare = air_ir::air_new_AirPrd(&arena);
    let_compare.tag = APRD_BINOP;
    let_compare.bop = ABIN_LAND;
    let_compare.ty = mod.t_bool;
    let_compare.add_sub(let_condition);
    let_compare.add_sub(air_ir::air_mk_prd_bool(&arena, false));
    AirCmd* let_then = air_ir::air_new_AirCmd(&arena);
    let_then.tag = ACMD_RET;
    let_then.prd = make_int(&arena, 3, mod.t_i64);
    AirCmd* let_else = air_ir::air_new_AirCmd(&arena);
    let_else.tag = ACMD_RET;
    let_else.prd = air_ir::air_new_AirPrd(&arena);
    let_else.prd.tag = APRD_VAR;
    let_else.prd.name = (char*)"known";
    let_else.prd.ty = mod.t_bool;
    AirCmd* let_if = air_ir::air_new_AirCmd(&arena);
    let_if.tag = ACMD_IF;
    let_if.prd = let_compare;
    let_if.then_c = let_then;
    let_if.else_c = let_else;
    AirCmd* let_cmd = air_ir::air_new_AirCmd(&arena);
    let_cmd.tag = ACMD_LET;
    let_cmd.binder = (char*)"known";
    let_cmd.prd = let_not;
    let_cmd.body = let_if;
    AirDecl* let_decl = air_ir::air_new_AirDecl(&arena);
    let_decl.tag = ADECL_DEF;
    let_decl.name = (char*)"literal_let_branch";
    let_decl.def_body = let_cmd;
    mod.decls[9] = let_decl;

    AirCmd* arithmetic_shift_ret = air_ir::air_new_AirCmd(&arena);
    arithmetic_shift_ret.tag = ACMD_RET;
    arithmetic_shift_ret.prd = make_binop(&arena, ABIN_SHR, mod.t_i8,
        make_int(&arena, -8, mod.t_i8), make_int(&arena, 2, mod.t_i8));
    AirDecl* arithmetic_shift_decl = air_ir::air_new_AirDecl(&arena);
    arithmetic_shift_decl.tag = ADECL_DEF;
    arithmetic_shift_decl.name = (char*)"arithmetic_shift";
    arithmetic_shift_decl.def_body = arithmetic_shift_ret;
    mod.decls[10] = arithmetic_shift_decl;

    AirCmd* logical_shift_ret = air_ir::air_new_AirCmd(&arena);
    logical_shift_ret.tag = ACMD_RET;
    logical_shift_ret.prd = make_binop(&arena, ABIN_SHR, mod.t_u8,
        make_int(&arena, 128, mod.t_u8), make_int(&arena, 2, mod.t_u8));
    AirDecl* logical_shift_decl = air_ir::air_new_AirDecl(&arena);
    logical_shift_decl.tag = ADECL_DEF;
    logical_shift_decl.name = (char*)"logical_shift";
    logical_shift_decl.def_body = logical_shift_ret;
    mod.decls[11] = logical_shift_decl;

    AirCmd* left_shift_ret = air_ir::air_new_AirCmd(&arena);
    left_shift_ret.tag = ACMD_RET;
    left_shift_ret.prd = make_binop(&arena, ABIN_SHL, mod.t_i8,
        make_int(&arena, 32, mod.t_i8), make_int(&arena, 2, mod.t_i8));
    AirDecl* left_shift_decl = air_ir::air_new_AirDecl(&arena);
    left_shift_decl.tag = ADECL_DEF;
    left_shift_decl.name = (char*)"left_shift";
    left_shift_decl.def_body = left_shift_ret;
    mod.decls[12] = left_shift_decl;

    AirCmd* bad_shift_ret = air_ir::air_new_AirCmd(&arena);
    bad_shift_ret.tag = ACMD_RET;
    bad_shift_ret.prd = make_binop(&arena, ABIN_SHR, mod.t_i8,
        make_int(&arena, 8, mod.t_i8), make_int(&arena, 8, mod.t_i8));
    AirDecl* bad_shift_decl = air_ir::air_new_AirDecl(&arena);
    bad_shift_decl.tag = ADECL_DEF;
    bad_shift_decl.name = (char*)"out_of_range_shift";
    bad_shift_decl.def_body = bad_shift_ret;
    mod.decls[13] = bad_shift_decl;

    AirCmd* div_overflow_ret = air_ir::air_new_AirCmd(&arena);
    div_overflow_ret.tag = ACMD_RET;
    div_overflow_ret.prd = make_binop(&arena, ABIN_DIV, mod.t_i8,
        make_int(&arena, -128, mod.t_i8), make_int(&arena, -1, mod.t_i8));
    AirDecl* div_overflow_decl = air_ir::air_new_AirDecl(&arena);
    div_overflow_decl.tag = ADECL_DEF;
    div_overflow_decl.name = (char*)"narrow_div_overflow";
    div_overflow_decl.def_body = div_overflow_ret;
    mod.decls[14] = div_overflow_decl;

    AirCmd* compare_range_ret = air_ir::air_new_AirCmd(&arena);
    compare_range_ret.tag = ACMD_RET;
    compare_range_ret.prd = make_binop(&arena, ABIN_EQ, mod.t_bool,
        make_int(&arena, 255, mod.t_i8), make_int(&arena, -1, mod.t_i8));
    AirDecl* compare_range_decl = air_ir::air_new_AirDecl(&arena);
    compare_range_decl.tag = ADECL_DEF;
    compare_range_decl.name = (char*)"typed_compare_range";
    compare_range_decl.def_body = compare_range_ret;
    mod.decls[15] = compare_range_decl;

    AirPrd* base_value = make_int(&arena, 40, null);
    AirPrd* base_var = air_ir::air_new_AirPrd(&arena);
    base_var.tag = APRD_VAR;
    base_var.name = (char*)"base";
    base_var.ty = mod.t_i64;
    AirCmd* int_let_cut = air_ir::air_new_AirCmd(&arena);
    int_let_cut.tag = ACMD_CUT;
    int_let_cut.prd = make_binop(&arena, ABIN_ADD, mod.t_i64, base_var, make_int(&arena, 2, null));
    int_let_cut.cns = air_ir::air_mk_cns_covar(&arena, (char*)"%ret");
    AirCmd* int_let = air_ir::air_new_AirCmd(&arena);
    int_let.tag = ACMD_LET;
    int_let.binder = (char*)"base";
    int_let.prd = base_value;
    int_let.body = int_let_cut;
    AirDecl* int_let_decl = air_ir::air_new_AirDecl(&arena);
    int_let_decl.tag = ADECL_DEF;
    int_let_decl.name = (char*)"integer_let_specialization";
    int_let_decl.def_body = int_let;
    mod.decls[16] = int_let_decl;

    AirPrd* narrow_var = air_ir::air_new_AirPrd(&arena);
    narrow_var.tag = APRD_VAR;
    narrow_var.name = (char*)"narrow";
    narrow_var.ty = mod.t_i8;
    AirCmd* bad_const_ret = air_ir::air_new_AirCmd(&arena);
    bad_const_ret.tag = ACMD_RET;
    bad_const_ret.prd = make_binop(&arena, ABIN_ADD, mod.t_i8, narrow_var, make_int(&arena, 1, null));
    AirCmd* bad_const_let = air_ir::air_new_AirCmd(&arena);
    bad_const_let.tag = ACMD_LET;
    bad_const_let.binder = (char*)"narrow";
    bad_const_let.prd = make_int(&arena, 200, null);
    bad_const_let.body = bad_const_ret;
    AirDecl* bad_const_decl = air_ir::air_new_AirDecl(&arena);
    bad_const_decl.tag = ADECL_DEF;
    bad_const_decl.name = (char*)"out_of_range_let";
    bad_const_decl.def_body = bad_const_let;
    mod.decls[17] = bad_const_decl;

    AirPrd* bool_var = air_ir::air_new_AirPrd(&arena);
    bool_var.tag = APRD_VAR;
    bool_var.name = (char*)"flag";
    bool_var.ty = mod.t_bool;
    AirCmd* bool_identity_ret = air_ir::air_new_AirCmd(&arena);
    bool_identity_ret.tag = ACMD_RET;
    bool_identity_ret.prd = make_binop(&arena, ABIN_AND, mod.t_bool, air_ir::air_mk_prd_bool(&arena, true), bool_var);
    AirDecl* bool_identity_decl = air_ir::air_new_AirDecl(&arena);
    bool_identity_decl.tag = ADECL_DEF;
    bool_identity_decl.name = (char*)"boolean_identity";
    bool_identity_decl.def_body = bool_identity_ret;
    mod.decls[18] = bool_identity_decl;

    AirPrd* unknown_bool_var = air_ir::air_new_AirPrd(&arena);
    unknown_bool_var.tag = APRD_VAR;
    unknown_bool_var.name = (char*)"maybe_bool";
    AirCmd* unknown_bool_ret = air_ir::air_new_AirCmd(&arena);
    unknown_bool_ret.tag = ACMD_RET;
    unknown_bool_ret.prd = make_binop(&arena, ABIN_AND, null, air_ir::air_mk_prd_bool(&arena, true), unknown_bool_var);
    AirDecl* unknown_bool_decl = air_ir::air_new_AirDecl(&arena);
    unknown_bool_decl.tag = ADECL_DEF;
    unknown_bool_decl.name = (char*)"unknown_boolean_identity";
    unknown_bool_decl.def_body = unknown_bool_ret;
    mod.decls[19] = unknown_bool_decl;

    AirCmd* sign_extend_ret = air_ir::air_new_AirCmd(&arena);
    sign_extend_ret.tag = ACMD_RET;
    sign_extend_ret.prd = make_coerce(&arena, mod.t_i32, make_int(&arena, -7, mod.t_i8));
    AirDecl* sign_extend_decl = air_ir::air_new_AirDecl(&arena);
    sign_extend_decl.tag = ADECL_DEF;
    sign_extend_decl.name = (char*)"constant_sign_extend";
    sign_extend_decl.def_body = sign_extend_ret;
    mod.decls[20] = sign_extend_decl;

    AirCmd* zero_extend_ret = air_ir::air_new_AirCmd(&arena);
    zero_extend_ret.tag = ACMD_RET;
    zero_extend_ret.prd = make_coerce(&arena, mod.t_i16, make_int(&arena, 250, mod.t_u8));
    AirDecl* zero_extend_decl = air_ir::air_new_AirDecl(&arena);
    zero_extend_decl.tag = ADECL_DEF;
    zero_extend_decl.name = (char*)"constant_zero_extend";
    zero_extend_decl.def_body = zero_extend_ret;
    mod.decls[21] = zero_extend_decl;

    AirCmd* truncate_ret = air_ir::air_new_AirCmd(&arena);
    truncate_ret.tag = ACMD_RET;
    truncate_ret.prd = make_coerce(&arena, mod.t_u8, make_int(&arena, 258, mod.t_i16));
    AirDecl* truncate_decl = air_ir::air_new_AirDecl(&arena);
    truncate_decl.tag = ADECL_DEF;
    truncate_decl.name = (char*)"constant_truncate";
    truncate_decl.def_body = truncate_ret;
    mod.decls[22] = truncate_decl;

    AirTyp* i128_type = air_ir::air_mk_typ_simple(&arena, ATYP_I128);
    AirCmd* wide_coerce_ret = air_ir::air_new_AirCmd(&arena);
    wide_coerce_ret.tag = ACMD_RET;
    wide_coerce_ret.prd = make_coerce(&arena, mod.t_i64, make_int(&arena, 1, i128_type));
    AirDecl* wide_coerce_decl = air_ir::air_new_AirDecl(&arena);
    wide_coerce_decl.tag = ADECL_DEF;
    wide_coerce_decl.name = (char*)"unsupported_wide_coercion_fold";
    wide_coerce_decl.def_body = wide_coerce_ret;
    mod.decls[23] = wide_coerce_decl;

    AirPrd* scale_value = air_ir::air_new_AirPrd(&arena);
    scale_value.tag = APRD_VAR;
    scale_value.name = (char*)"scale_x";
    scale_value.ty = mod.t_i32;
    AirPrd* scale_factor = make_int(&arena, 8, null);
    AirPrd* multiply_by_eight = make_binop(&arena, ABIN_MUL, mod.t_i32, scale_value, scale_factor);
    AirCmd* scale_ret = air_ir::air_new_AirCmd(&arena);
    scale_ret.tag = ACMD_RET;
    scale_ret.prd = multiply_by_eight;
    AirDecl* scale_decl = air_ir::air_new_AirDecl(&arena);
    scale_decl.tag = ADECL_DEF;
    scale_decl.name = (char*)"multiply_by_power_of_two";
    scale_decl.def_body = scale_ret;
    mod.decls[24] = scale_decl;

    AirPrd* non_power_factor = make_int(&arena, 6, null);
    AirPrd* multiply_by_six = make_binop(&arena, ABIN_MUL, mod.t_i32, scale_value, non_power_factor);
    AirCmd* non_power_ret = air_ir::air_new_AirCmd(&arena);
    non_power_ret.tag = ACMD_RET;
    non_power_ret.prd = multiply_by_six;
    AirDecl* non_power_decl = air_ir::air_new_AirDecl(&arena);
    non_power_decl.tag = ADECL_DEF;
    non_power_decl.name = (char*)"multiply_by_non_power_of_two";
    non_power_decl.def_body = non_power_ret;
    mod.decls[25] = non_power_decl;

    AirPrd* left_shift_value = air_ir::air_new_AirPrd(&arena);
    left_shift_value.tag = APRD_VAR;
    left_shift_value.name = (char*)"left_shift_value";
    left_shift_value.ty = mod.t_i32;
    AirPrd* inner_left_shift = make_binop(&arena, ABIN_SHL, mod.t_i32, left_shift_value, make_int(&arena, 2, mod.t_i32));
    AirPrd* combined_left_shift = make_binop(&arena, ABIN_SHL, mod.t_i32, inner_left_shift, make_int(&arena, 3, mod.t_i32));
    AirCmd* combine_left_ret = air_ir::air_new_AirCmd(&arena);
    combine_left_ret.tag = ACMD_RET;
    combine_left_ret.prd = combined_left_shift;
    AirDecl* combine_left_decl = air_ir::air_new_AirDecl(&arena);
    combine_left_decl.tag = ADECL_DEF;
    combine_left_decl.name = (char*)"combine_left_shifts";
    combine_left_decl.def_body = combine_left_ret;
    mod.decls[26] = combine_left_decl;

    AirPrd* right_shift_value = air_ir::air_new_AirPrd(&arena);
    right_shift_value.tag = APRD_VAR;
    right_shift_value.name = (char*)"right_shift_value";
    right_shift_value.ty = mod.t_i32;
    AirPrd* inner_right_shift = make_binop(&arena, ABIN_SHR, mod.t_i32, right_shift_value, make_int(&arena, 1, mod.t_i32));
    AirPrd* combined_right_shift = make_binop(&arena, ABIN_SHR, mod.t_i32, inner_right_shift, make_int(&arena, 2, mod.t_i32));
    AirCmd* combine_right_ret = air_ir::air_new_AirCmd(&arena);
    combine_right_ret.tag = ACMD_RET;
    combine_right_ret.prd = combined_right_shift;
    AirDecl* combine_right_decl = air_ir::air_new_AirDecl(&arena);
    combine_right_decl.tag = ADECL_DEF;
    combine_right_decl.name = (char*)"combine_right_shifts";
    combine_right_decl.def_body = combine_right_ret;
    mod.decls[27] = combine_right_decl;

    AirPrd* narrow_shift_value = air_ir::air_new_AirPrd(&arena);
    narrow_shift_value.tag = APRD_VAR;
    narrow_shift_value.name = (char*)"narrow_shift_value";
    narrow_shift_value.ty = mod.t_i8;
    AirPrd* inner_narrow_shift = make_binop(&arena, ABIN_SHL, mod.t_i8, narrow_shift_value, make_int(&arena, 5, mod.t_i8));
    AirPrd* uncombined_narrow_shift = make_binop(&arena, ABIN_SHL, mod.t_i8, inner_narrow_shift, make_int(&arena, 3, mod.t_i8));
    AirCmd* uncombined_shift_ret = air_ir::air_new_AirCmd(&arena);
    uncombined_shift_ret.tag = ACMD_RET;
    uncombined_shift_ret.prd = uncombined_narrow_shift;
    AirDecl* uncombined_shift_decl = air_ir::air_new_AirDecl(&arena);
    uncombined_shift_decl.tag = ADECL_DEF;
    uncombined_shift_decl.name = (char*)"leave_shift_sum_out_of_range";
    uncombined_shift_decl.def_body = uncombined_shift_ret;
    mod.decls[28] = uncombined_shift_decl;

    AirPrd* unsigned_mod_value = air_ir::air_new_AirPrd(&arena);
    unsigned_mod_value.tag = APRD_VAR;
    unsigned_mod_value.name = (char*)"unsigned_mod_value";
    unsigned_mod_value.ty = mod.t_u32;
    AirPrd* unsigned_modulo = make_binop(&arena, ABIN_MOD, mod.t_u32, unsigned_mod_value, make_int(&arena, 8, null));
    AirCmd* unsigned_mod_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_mod_ret.tag = ACMD_RET;
    unsigned_mod_ret.prd = unsigned_modulo;
    AirDecl* unsigned_mod_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_mod_decl.tag = ADECL_DEF;
    unsigned_mod_decl.name = (char*)"unsigned_remainder_power_of_two";
    unsigned_mod_decl.def_body = unsigned_mod_ret;
    mod.decls[29] = unsigned_mod_decl;

    AirPrd* signed_mod_value = air_ir::air_new_AirPrd(&arena);
    signed_mod_value.tag = APRD_VAR;
    signed_mod_value.name = (char*)"signed_mod_value";
    signed_mod_value.ty = mod.t_i32;
    AirPrd* signed_modulo = make_binop(&arena, ABIN_MOD, mod.t_i32, signed_mod_value, make_int(&arena, 6, null));
    AirCmd* signed_mod_ret = air_ir::air_new_AirCmd(&arena);
    signed_mod_ret.tag = ACMD_RET;
    signed_mod_ret.prd = signed_modulo;
    AirDecl* signed_mod_decl = air_ir::air_new_AirDecl(&arena);
    signed_mod_decl.tag = ADECL_DEF;
    signed_mod_decl.name = (char*)"signed_remainder_non_power_of_two";
    signed_mod_decl.def_body = signed_mod_ret;
    mod.decls[30] = signed_mod_decl;

    AirPrd* irregular_mod = make_binop(&arena, ABIN_MOD, mod.t_u32, unsigned_mod_value, make_int(&arena, 6, null));
    AirCmd* irregular_mod_ret = air_ir::air_new_AirCmd(&arena);
    irregular_mod_ret.tag = ACMD_RET;
    irregular_mod_ret.prd = irregular_mod;
    AirDecl* irregular_mod_decl = air_ir::air_new_AirDecl(&arena);
    irregular_mod_decl.tag = ADECL_DEF;
    irregular_mod_decl.name = (char*)"unsigned_remainder_non_power_of_two";
    irregular_mod_decl.def_body = irregular_mod_ret;
    mod.decls[31] = irregular_mod_decl;

    AirPrd* unsigned_div_value = air_ir::air_new_AirPrd(&arena);
    unsigned_div_value.tag = APRD_VAR;
    unsigned_div_value.name = (char*)"unsigned_div_value";
    unsigned_div_value.ty = mod.t_u32;
    AirPrd* unsigned_quotient = make_binop(&arena, ABIN_DIV, mod.t_u32, unsigned_div_value, make_int(&arena, 8, null));
    AirCmd* unsigned_div_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_div_ret.tag = ACMD_RET;
    unsigned_div_ret.prd = unsigned_quotient;
    AirDecl* unsigned_div_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_div_decl.tag = ADECL_DEF;
    unsigned_div_decl.name = (char*)"unsigned_division_power_of_two";
    unsigned_div_decl.def_body = unsigned_div_ret;
    mod.decls[32] = unsigned_div_decl;

    AirPrd* signed_div_value = air_ir::air_new_AirPrd(&arena);
    signed_div_value.tag = APRD_VAR;
    signed_div_value.name = (char*)"signed_div_value";
    signed_div_value.ty = mod.t_i32;
    AirPrd* signed_quotient = make_binop(&arena, ABIN_DIV, mod.t_i32, signed_div_value, make_int(&arena, 6, null));
    AirCmd* signed_div_ret = air_ir::air_new_AirCmd(&arena);
    signed_div_ret.tag = ACMD_RET;
    signed_div_ret.prd = signed_quotient;
    AirDecl* signed_div_decl = air_ir::air_new_AirDecl(&arena);
    signed_div_decl.tag = ADECL_DEF;
    signed_div_decl.name = (char*)"signed_division_non_power_of_two";
    signed_div_decl.def_body = signed_div_ret;
    mod.decls[33] = signed_div_decl;

    AirPrd* irregular_div = make_binop(&arena, ABIN_DIV, mod.t_u32, unsigned_div_value, make_int(&arena, 6, null));
    AirCmd* irregular_div_ret = air_ir::air_new_AirCmd(&arena);
    irregular_div_ret.tag = ACMD_RET;
    irregular_div_ret.prd = irregular_div;
    AirDecl* irregular_div_decl = air_ir::air_new_AirDecl(&arena);
    irregular_div_decl.tag = ADECL_DEF;
    irregular_div_decl.name = (char*)"unsigned_division_non_power_of_two";
    irregular_div_decl.def_body = irregular_div_ret;
    mod.decls[34] = irregular_div_decl;

    AirPrd* signed_mask_value = air_ir::air_new_AirPrd(&arena);
    signed_mask_value.tag = APRD_VAR;
    signed_mask_value.name = (char*)"signed_mask_value";
    signed_mask_value.ty = mod.t_i32;
    AirPrd* signed_mask = make_binop(&arena, ABIN_AND, mod.t_i32, signed_mask_value, make_int(&arena, -1, mod.t_i32));
    AirCmd* signed_mask_ret = air_ir::air_new_AirCmd(&arena);
    signed_mask_ret.tag = ACMD_RET;
    signed_mask_ret.prd = signed_mask;
    AirDecl* signed_mask_decl = air_ir::air_new_AirDecl(&arena);
    signed_mask_decl.tag = ADECL_DEF;
    signed_mask_decl.name = (char*)"signed_and_all_ones";
    signed_mask_decl.def_body = signed_mask_ret;
    mod.decls[35] = signed_mask_decl;

    AirPrd* unsigned_mask_value = air_ir::air_new_AirPrd(&arena);
    unsigned_mask_value.tag = APRD_VAR;
    unsigned_mask_value.name = (char*)"unsigned_mask_value";
    unsigned_mask_value.ty = mod.t_u32;
    AirPrd* unsigned_mask = make_binop(&arena, ABIN_AND, mod.t_u32, unsigned_mask_value, make_int(&arena, 4294967295L, mod.t_u32));
    AirCmd* unsigned_mask_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_mask_ret.tag = ACMD_RET;
    unsigned_mask_ret.prd = unsigned_mask;
    AirDecl* unsigned_mask_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_mask_decl.tag = ADECL_DEF;
    unsigned_mask_decl.name = (char*)"unsigned_and_all_ones";
    unsigned_mask_decl.def_body = unsigned_mask_ret;
    mod.decls[36] = unsigned_mask_decl;

    AirPrd* signed_xor = make_binop(&arena, ABIN_XOR, mod.t_i32, signed_mask_value, make_int(&arena, -1, mod.t_i32));
    AirCmd* signed_xor_ret = air_ir::air_new_AirCmd(&arena);
    signed_xor_ret.tag = ACMD_RET;
    signed_xor_ret.prd = signed_xor;
    AirDecl* signed_xor_decl = air_ir::air_new_AirDecl(&arena);
    signed_xor_decl.tag = ADECL_DEF;
    signed_xor_decl.name = (char*)"signed_xor_all_ones";
    signed_xor_decl.def_body = signed_xor_ret;
    mod.decls[37] = signed_xor_decl;

    AirPrd* unsigned_xor = make_binop(&arena, ABIN_XOR, mod.t_u32, unsigned_mask_value, make_int(&arena, 4294967295L, mod.t_u32));
    AirCmd* unsigned_xor_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_xor_ret.tag = ACMD_RET;
    unsigned_xor_ret.prd = unsigned_xor;
    AirDecl* unsigned_xor_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_xor_decl.tag = ADECL_DEF;
    unsigned_xor_decl.name = (char*)"unsigned_xor_all_ones";
    unsigned_xor_decl.def_body = unsigned_xor_ret;
    mod.decls[38] = unsigned_xor_decl;

    AirPrd* unsigned_or_zero = make_binop(&arena, ABIN_OR, mod.t_u32, make_int(&arena, 0, mod.t_u32), unsigned_mask_value);
    AirCmd* unsigned_or_zero_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_or_zero_ret.tag = ACMD_RET;
    unsigned_or_zero_ret.prd = unsigned_or_zero;
    AirDecl* unsigned_or_zero_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_or_zero_decl.tag = ADECL_DEF;
    unsigned_or_zero_decl.name = (char*)"unsigned_or_zero_left";
    unsigned_or_zero_decl.def_body = unsigned_or_zero_ret;
    mod.decls[39] = unsigned_or_zero_decl;

    AirPrd* unsigned_xor_zero = make_binop(&arena, ABIN_XOR, mod.t_u32, make_int(&arena, 0, mod.t_u32), unsigned_mask_value);
    AirCmd* unsigned_xor_zero_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_xor_zero_ret.tag = ACMD_RET;
    unsigned_xor_zero_ret.prd = unsigned_xor_zero;
    AirDecl* unsigned_xor_zero_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_xor_zero_decl.tag = ADECL_DEF;
    unsigned_xor_zero_decl.name = (char*)"unsigned_xor_zero_left";
    unsigned_xor_zero_decl.def_body = unsigned_xor_zero_ret;
    mod.decls[40] = unsigned_xor_zero_decl;

    AirPrd* bool_not_value = air_ir::air_new_AirPrd(&arena);
    bool_not_value.tag = APRD_VAR;
    bool_not_value.name = (char*)"bool_not_value";
    bool_not_value.ty = mod.t_bool;
    AirPrd* inner_bool_not = air_ir::air_new_AirPrd(&arena);
    inner_bool_not.tag = APRD_UNOP;
    inner_bool_not.uop = AUN_NOT;
    inner_bool_not.ty = mod.t_bool;
    inner_bool_not.add_sub(bool_not_value);
    AirPrd* double_bool_not = air_ir::air_new_AirPrd(&arena);
    double_bool_not.tag = APRD_UNOP;
    double_bool_not.uop = AUN_NOT;
    double_bool_not.ty = mod.t_bool;
    double_bool_not.add_sub(inner_bool_not);
    AirCmd* double_bool_not_ret = air_ir::air_new_AirCmd(&arena);
    double_bool_not_ret.tag = ACMD_RET;
    double_bool_not_ret.prd = double_bool_not;
    AirDecl* double_bool_not_decl = air_ir::air_new_AirDecl(&arena);
    double_bool_not_decl.tag = ADECL_DEF;
    double_bool_not_decl.name = (char*)"double_boolean_not";
    double_bool_not_decl.def_body = double_bool_not_ret;
    mod.decls[41] = double_bool_not_decl;

    AirPrd* int_not_value = air_ir::air_new_AirPrd(&arena);
    int_not_value.tag = APRD_VAR;
    int_not_value.name = (char*)"int_not_value";
    int_not_value.ty = mod.t_i16;
    AirPrd* inner_int_not = air_ir::air_new_AirPrd(&arena);
    inner_int_not.tag = APRD_UNOP;
    inner_int_not.uop = AUN_BITNOT;
    inner_int_not.ty = mod.t_i16;
    inner_int_not.add_sub(int_not_value);
    AirPrd* double_int_not = air_ir::air_new_AirPrd(&arena);
    double_int_not.tag = APRD_UNOP;
    double_int_not.uop = AUN_BITNOT;
    double_int_not.ty = mod.t_i16;
    double_int_not.add_sub(inner_int_not);
    AirCmd* double_int_not_ret = air_ir::air_new_AirCmd(&arena);
    double_int_not_ret.tag = ACMD_RET;
    double_int_not_ret.prd = double_int_not;
    AirDecl* double_int_not_decl = air_ir::air_new_AirDecl(&arena);
    double_int_not_decl.tag = ADECL_DEF;
    double_int_not_decl.name = (char*)"double_integer_bitnot";
    double_int_not_decl.def_body = double_int_not_ret;
    mod.decls[42] = double_int_not_decl;

    AirPrd* narrow_not_value = air_ir::air_new_AirPrd(&arena);
    narrow_not_value.tag = APRD_VAR;
    narrow_not_value.name = (char*)"narrow_not_value";
    narrow_not_value.ty = mod.t_u8;
    AirPrd* narrow_inner_not = air_ir::air_new_AirPrd(&arena);
    narrow_inner_not.tag = APRD_UNOP;
    narrow_inner_not.uop = AUN_BITNOT;
    narrow_inner_not.ty = mod.t_u8;
    narrow_inner_not.add_sub(narrow_not_value);
    AirPrd* mismatched_double_not = air_ir::air_new_AirPrd(&arena);
    mismatched_double_not.tag = APRD_UNOP;
    mismatched_double_not.uop = AUN_BITNOT;
    mismatched_double_not.ty = mod.t_i16;
    mismatched_double_not.add_sub(narrow_inner_not);
    AirCmd* mismatched_not_ret = air_ir::air_new_AirCmd(&arena);
    mismatched_not_ret.tag = ACMD_RET;
    mismatched_not_ret.prd = mismatched_double_not;
    AirDecl* mismatched_not_decl = air_ir::air_new_AirDecl(&arena);
    mismatched_not_decl.tag = ADECL_DEF;
    mismatched_not_decl.name = (char*)"mismatched_double_bitnot";
    mismatched_not_decl.def_body = mismatched_not_ret;
    mod.decls[43] = mismatched_not_decl;

    AirPrd* remainder_one_value = air_ir::air_new_AirPrd(&arena);
    remainder_one_value.tag = APRD_VAR;
    remainder_one_value.name = (char*)"remainder_one_value";
    remainder_one_value.ty = mod.t_i32;
    AirPrd* remainder_one = make_binop(&arena, ABIN_MOD, mod.t_i32, remainder_one_value, make_int(&arena, 1, null));
    AirCmd* remainder_one_ret = air_ir::air_new_AirCmd(&arena);
    remainder_one_ret.tag = ACMD_RET;
    remainder_one_ret.prd = remainder_one;
    AirDecl* remainder_one_decl = air_ir::air_new_AirDecl(&arena);
    remainder_one_decl.tag = ADECL_DEF;
    remainder_one_decl.name = (char*)"signed_remainder_by_one";
    remainder_one_decl.def_body = remainder_one_ret;
    mod.decls[44] = remainder_one_decl;

    AirPrd* remainder_zero = make_binop(&arena, ABIN_MOD, mod.t_i32, remainder_one_value, make_int(&arena, 0, null));
    AirCmd* remainder_zero_ret = air_ir::air_new_AirCmd(&arena);
    remainder_zero_ret.tag = ACMD_RET;
    remainder_zero_ret.prd = remainder_zero;
    AirDecl* remainder_zero_decl = air_ir::air_new_AirDecl(&arena);
    remainder_zero_decl.tag = ADECL_DEF;
    remainder_zero_decl.name = (char*)"signed_remainder_by_zero";
    remainder_zero_decl.def_body = remainder_zero_ret;
    mod.decls[45] = remainder_zero_decl;

    AirPrd* bool_xor_value = air_ir::air_new_AirPrd(&arena);
    bool_xor_value.tag = APRD_VAR;
    bool_xor_value.name = (char*)"bool_xor_value";
    bool_xor_value.ty = mod.t_bool;
    AirPrd* bool_xor_left = make_binop(&arena, ABIN_XOR, mod.t_bool, make_bool(&arena, true, mod.t_bool), bool_xor_value);
    AirCmd* bool_xor_left_ret = air_ir::air_new_AirCmd(&arena);
    bool_xor_left_ret.tag = ACMD_RET;
    bool_xor_left_ret.prd = bool_xor_left;
    AirDecl* bool_xor_left_decl = air_ir::air_new_AirDecl(&arena);
    bool_xor_left_decl.tag = ADECL_DEF;
    bool_xor_left_decl.name = (char*)"boolean_xor_true_left";
    bool_xor_left_decl.def_body = bool_xor_left_ret;
    mod.decls[46] = bool_xor_left_decl;

    AirPrd* bool_xor_right = make_binop(&arena, ABIN_XOR, mod.t_bool, bool_xor_value, make_bool(&arena, true, mod.t_bool));
    AirCmd* bool_xor_right_ret = air_ir::air_new_AirCmd(&arena);
    bool_xor_right_ret.tag = ACMD_RET;
    bool_xor_right_ret.prd = bool_xor_right;
    AirDecl* bool_xor_right_decl = air_ir::air_new_AirDecl(&arena);
    bool_xor_right_decl.tag = ADECL_DEF;
    bool_xor_right_decl.name = (char*)"boolean_xor_true_right";
    bool_xor_right_decl.def_body = bool_xor_right_ret;
    mod.decls[47] = bool_xor_right_decl;

    AirPrd* mul_zero_right_value = air_ir::air_new_AirPrd(&arena);
    mul_zero_right_value.tag = APRD_VAR;
    mul_zero_right_value.name = (char*)"mul_zero_right_value";
    mul_zero_right_value.ty = mod.t_i32;
    AirPrd* mul_zero_right = make_binop(&arena, ABIN_MUL, mod.t_i32, mul_zero_right_value, make_int(&arena, 0, null));
    AirCmd* mul_zero_right_ret = air_ir::air_new_AirCmd(&arena);
    mul_zero_right_ret.tag = ACMD_RET;
    mul_zero_right_ret.prd = mul_zero_right;
    AirDecl* mul_zero_right_decl = air_ir::air_new_AirDecl(&arena);
    mul_zero_right_decl.tag = ADECL_DEF;
    mul_zero_right_decl.name = (char*)"mul_zero_right";
    mul_zero_right_decl.def_body = mul_zero_right_ret;
    mod.decls[48] = mul_zero_right_decl;

    AirPrd* mul_zero_left_value = air_ir::air_new_AirPrd(&arena);
    mul_zero_left_value.tag = APRD_VAR;
    mul_zero_left_value.name = (char*)"mul_zero_left_value";
    mul_zero_left_value.ty = mod.t_u32;
    AirPrd* mul_zero_left = make_binop(&arena, ABIN_MUL, mod.t_u32, make_int(&arena, 0, mod.t_u32), mul_zero_left_value);
    AirCmd* mul_zero_left_ret = air_ir::air_new_AirCmd(&arena);
    mul_zero_left_ret.tag = ACMD_RET;
    mul_zero_left_ret.prd = mul_zero_left;
    AirDecl* mul_zero_left_decl = air_ir::air_new_AirDecl(&arena);
    mul_zero_left_decl.tag = ADECL_DEF;
    mul_zero_left_decl.name = (char*)"mul_zero_left";
    mul_zero_left_decl.def_body = mul_zero_left_ret;
    mod.decls[49] = mul_zero_left_decl;

    AirPrd* mul_zero_constants = make_binop(&arena, ABIN_MUL, mod.t_i32, make_int(&arena, 0, mod.t_i32), make_int(&arena, 42, mod.t_i32));
    AirCmd* mul_zero_constants_ret = air_ir::air_new_AirCmd(&arena);
    mul_zero_constants_ret.tag = ACMD_RET;
    mul_zero_constants_ret.prd = mul_zero_constants;
    AirDecl* mul_zero_constants_decl = air_ir::air_new_AirDecl(&arena);
    mul_zero_constants_decl.tag = ADECL_DEF;
    mul_zero_constants_decl.name = (char*)"mul_zero_constant_fold";
    mul_zero_constants_decl.def_body = mul_zero_constants_ret;
    mod.decls[50] = mul_zero_constants_decl;

    AirPrd* bool_eq_true = make_binop(&arena, ABIN_EQ, mod.t_bool, make_bool(&arena, true, mod.t_bool), bool_xor_value);
    AirCmd* bool_eq_true_ret = air_ir::air_new_AirCmd(&arena);
    bool_eq_true_ret.tag = ACMD_RET;
    bool_eq_true_ret.prd = bool_eq_true;
    AirDecl* bool_eq_true_decl = air_ir::air_new_AirDecl(&arena);
    bool_eq_true_decl.tag = ADECL_DEF;
    bool_eq_true_decl.name = (char*)"boolean_equals_true";
    bool_eq_true_decl.def_body = bool_eq_true_ret;
    mod.decls[51] = bool_eq_true_decl;

    AirPrd* bool_eq_false = make_binop(&arena, ABIN_EQ, mod.t_bool, make_bool(&arena, false, mod.t_bool), bool_xor_value);
    AirCmd* bool_eq_false_ret = air_ir::air_new_AirCmd(&arena);
    bool_eq_false_ret.tag = ACMD_RET;
    bool_eq_false_ret.prd = bool_eq_false;
    AirDecl* bool_eq_false_decl = air_ir::air_new_AirDecl(&arena);
    bool_eq_false_decl.tag = ADECL_DEF;
    bool_eq_false_decl.name = (char*)"boolean_equals_false";
    bool_eq_false_decl.def_body = bool_eq_false_ret;
    mod.decls[52] = bool_eq_false_decl;

    AirPrd* bool_neq_true = make_binop(&arena, ABIN_NEQ, mod.t_bool, bool_xor_value, make_bool(&arena, true, mod.t_bool));
    AirCmd* bool_neq_true_ret = air_ir::air_new_AirCmd(&arena);
    bool_neq_true_ret.tag = ACMD_RET;
    bool_neq_true_ret.prd = bool_neq_true;
    AirDecl* bool_neq_true_decl = air_ir::air_new_AirDecl(&arena);
    bool_neq_true_decl.tag = ADECL_DEF;
    bool_neq_true_decl.name = (char*)"boolean_not_equals_true";
    bool_neq_true_decl.def_body = bool_neq_true_ret;
    mod.decls[53] = bool_neq_true_decl;

    AirPrd* bool_neq_false = make_binop(&arena, ABIN_NEQ, mod.t_bool, make_bool(&arena, false, mod.t_bool), bool_xor_value);
    AirCmd* bool_neq_false_ret = air_ir::air_new_AirCmd(&arena);
    bool_neq_false_ret.tag = ACMD_RET;
    bool_neq_false_ret.prd = bool_neq_false;
    AirDecl* bool_neq_false_decl = air_ir::air_new_AirDecl(&arena);
    bool_neq_false_decl.tag = ADECL_DEF;
    bool_neq_false_decl.name = (char*)"boolean_not_equals_false";
    bool_neq_false_decl.def_body = bool_neq_false_ret;
    mod.decls[54] = bool_neq_false_decl;

    AirPrd* same_i32_value = air_ir::air_new_AirPrd(&arena);
    same_i32_value.tag = APRD_VAR;
    same_i32_value.name = (char*)"same_i32_value";
    same_i32_value.ty = mod.t_i32;
    AirPrd* same_i32_coerce = make_coerce(&arena, mod.t_i32, same_i32_value);
    AirCmd* same_i32_ret = air_ir::air_new_AirCmd(&arena);
    same_i32_ret.tag = ACMD_RET;
    same_i32_ret.prd = same_i32_coerce;
    AirDecl* same_i32_decl = air_ir::air_new_AirDecl(&arena);
    same_i32_decl.tag = ADECL_DEF;
    same_i32_decl.name = (char*)"same_integer_coercion";
    same_i32_decl.def_body = same_i32_ret;
    mod.decls[55] = same_i32_decl;

    AirPrd* same_bool_value = air_ir::air_new_AirPrd(&arena);
    same_bool_value.tag = APRD_VAR;
    same_bool_value.name = (char*)"same_bool_value";
    same_bool_value.ty = mod.t_bool;
    AirPrd* same_bool_coerce = make_coerce(&arena, mod.t_bool, same_bool_value);
    AirCmd* same_bool_ret = air_ir::air_new_AirCmd(&arena);
    same_bool_ret.tag = ACMD_RET;
    same_bool_ret.prd = same_bool_coerce;
    AirDecl* same_bool_decl = air_ir::air_new_AirDecl(&arena);
    same_bool_decl.tag = ADECL_DEF;
    same_bool_decl.name = (char*)"same_boolean_coercion";
    same_bool_decl.def_body = same_bool_ret;
    mod.decls[56] = same_bool_decl;

    AirPrd* same_f32_value = air_ir::air_new_AirPrd(&arena);
    same_f32_value.tag = APRD_VAR;
    same_f32_value.name = (char*)"same_f32_value";
    same_f32_value.ty = mod.t_f32;
    AirPrd* same_f32_coerce = make_coerce(&arena, mod.t_f32, same_f32_value);
    AirCmd* same_f32_ret = air_ir::air_new_AirCmd(&arena);
    same_f32_ret.tag = ACMD_RET;
    same_f32_ret.prd = same_f32_coerce;
    AirDecl* same_f32_decl = air_ir::air_new_AirDecl(&arena);
    same_f32_decl.tag = ADECL_DEF;
    same_f32_decl.name = (char*)"same_f32_coercion";
    same_f32_decl.def_body = same_f32_ret;
    mod.decls[57] = same_f32_decl;

    AirPrd* mismatch_i32_value = air_ir::air_new_AirPrd(&arena);
    mismatch_i32_value.tag = APRD_VAR;
    mismatch_i32_value.name = (char*)"mismatch_i32_value";
    mismatch_i32_value.ty = mod.t_i32;
    AirPrd* mismatch_i32_coerce = make_coerce(&arena, mod.t_u32, mismatch_i32_value);
    AirCmd* mismatch_i32_ret = air_ir::air_new_AirCmd(&arena);
    mismatch_i32_ret.tag = ACMD_RET;
    mismatch_i32_ret.prd = mismatch_i32_coerce;
    AirDecl* mismatch_i32_decl = air_ir::air_new_AirDecl(&arena);
    mismatch_i32_decl.tag = ADECL_DEF;
    mismatch_i32_decl.name = (char*)"different_signedness_coercion";
    mismatch_i32_decl.def_body = mismatch_i32_ret;
    mod.decls[58] = mismatch_i32_decl;

    AirPrd* signed_neg_value = air_ir::air_new_AirPrd(&arena);
    signed_neg_value.tag = APRD_VAR;
    signed_neg_value.name = (char*)"signed_neg_value";
    signed_neg_value.ty = mod.t_i32;
    AirPrd* signed_mul_neg_one = make_binop(&arena, ABIN_MUL, mod.t_i32, signed_neg_value, make_int(&arena, -1, mod.t_i32));
    AirCmd* signed_mul_neg_one_ret = air_ir::air_new_AirCmd(&arena);
    signed_mul_neg_one_ret.tag = ACMD_RET;
    signed_mul_neg_one_ret.prd = signed_mul_neg_one;
    AirDecl* signed_mul_neg_one_decl = air_ir::air_new_AirDecl(&arena);
    signed_mul_neg_one_decl.tag = ADECL_DEF;
    signed_mul_neg_one_decl.name = (char*)"signed_multiply_by_negative_one";
    signed_mul_neg_one_decl.def_body = signed_mul_neg_one_ret;
    mod.decls[59] = signed_mul_neg_one_decl;

    AirPrd* unsigned_neg_value = air_ir::air_new_AirPrd(&arena);
    unsigned_neg_value.tag = APRD_VAR;
    unsigned_neg_value.name = (char*)"unsigned_neg_value";
    unsigned_neg_value.ty = mod.t_u32;
    AirPrd* unsigned_mul_all_ones = make_binop(&arena, ABIN_MUL, mod.t_u32, unsigned_neg_value, make_int(&arena, 4294967295L, mod.t_u32));
    AirCmd* unsigned_mul_all_ones_ret = air_ir::air_new_AirCmd(&arena);
    unsigned_mul_all_ones_ret.tag = ACMD_RET;
    unsigned_mul_all_ones_ret.prd = unsigned_mul_all_ones;
    AirDecl* unsigned_mul_all_ones_decl = air_ir::air_new_AirDecl(&arena);
    unsigned_mul_all_ones_decl.tag = ADECL_DEF;
    unsigned_mul_all_ones_decl.name = (char*)"unsigned_multiply_by_all_ones";
    unsigned_mul_all_ones_decl.def_body = unsigned_mul_all_ones_ret;
    mod.decls[60] = unsigned_mul_all_ones_decl;

    AirPrd* left_scale_factor = make_int(&arena, 8, null);
    AirPrd* multiply_by_eight_left = make_binop(&arena, ABIN_MUL, mod.t_i32, left_scale_factor, scale_value);
    AirCmd* scale_left_ret = air_ir::air_new_AirCmd(&arena);
    scale_left_ret.tag = ACMD_RET;
    scale_left_ret.prd = multiply_by_eight_left;
    AirDecl* scale_left_decl = air_ir::air_new_AirDecl(&arena);
    scale_left_decl.tag = ADECL_DEF;
    scale_left_decl.name = (char*)"multiply_by_power_of_two_left";
    scale_left_decl.def_body = scale_left_ret;
    mod.decls[61] = scale_left_decl;

    AirPrd* multiply_by_six_left = make_binop(&arena, ABIN_MUL, mod.t_i32, non_power_factor, scale_value);
    AirCmd* non_power_left_ret = air_ir::air_new_AirCmd(&arena);
    non_power_left_ret.tag = ACMD_RET;
    non_power_left_ret.prd = multiply_by_six_left;
    AirDecl* non_power_left_decl = air_ir::air_new_AirDecl(&arena);
    non_power_left_decl.tag = ADECL_DEF;
    non_power_left_decl.name = (char*)"multiply_by_non_power_of_two_left";
    non_power_left_decl.def_body = non_power_left_ret;
    mod.decls[62] = non_power_left_decl;

    AirPrd* true_to_i32 = make_coerce(&arena, mod.t_i32, make_bool(&arena, true, mod.t_bool));
    AirCmd* true_to_i32_ret = air_ir::air_new_AirCmd(&arena);
    true_to_i32_ret.tag = ACMD_RET;
    true_to_i32_ret.prd = true_to_i32;
    AirDecl* true_to_i32_decl = air_ir::air_new_AirDecl(&arena);
    true_to_i32_decl.tag = ADECL_DEF;
    true_to_i32_decl.name = (char*)"boolean_true_to_integer";
    true_to_i32_decl.def_body = true_to_i32_ret;
    mod.decls[63] = true_to_i32_decl;

    AirPrd* false_to_u8 = make_coerce(&arena, mod.t_u8, make_bool(&arena, false, mod.t_bool));
    AirCmd* false_to_u8_ret = air_ir::air_new_AirCmd(&arena);
    false_to_u8_ret.tag = ACMD_RET;
    false_to_u8_ret.prd = false_to_u8;
    AirDecl* false_to_u8_decl = air_ir::air_new_AirDecl(&arena);
    false_to_u8_decl.tag = ADECL_DEF;
    false_to_u8_decl.name = (char*)"boolean_false_to_unsigned";
    false_to_u8_decl.def_body = false_to_u8_ret;
    mod.decls[64] = false_to_u8_decl;

    AirPrd* odd_to_bool = make_coerce(&arena, mod.t_bool, make_int(&arena, 3, mod.t_i16));
    AirCmd* odd_to_bool_ret = air_ir::air_new_AirCmd(&arena);
    odd_to_bool_ret.tag = ACMD_RET;
    odd_to_bool_ret.prd = odd_to_bool;
    AirDecl* odd_to_bool_decl = air_ir::air_new_AirDecl(&arena);
    odd_to_bool_decl.tag = ADECL_DEF;
    odd_to_bool_decl.name = (char*)"odd_integer_to_boolean";
    odd_to_bool_decl.def_body = odd_to_bool_ret;
    mod.decls[65] = odd_to_bool_decl;

    AirPrd* even_to_bool = make_coerce(&arena, mod.t_bool, make_int(&arena, 4, mod.t_i16));
    AirCmd* even_to_bool_ret = air_ir::air_new_AirCmd(&arena);
    even_to_bool_ret.tag = ACMD_RET;
    even_to_bool_ret.prd = even_to_bool;
    AirDecl* even_to_bool_decl = air_ir::air_new_AirDecl(&arena);
    even_to_bool_decl.tag = ADECL_DEF;
    even_to_bool_decl.name = (char*)"even_integer_to_boolean";
    even_to_bool_decl.def_body = even_to_bool_ret;
    mod.decls[66] = even_to_bool_decl;

    AirPrd* logic_value = air_ir::air_new_AirPrd(&arena);
    logic_value.tag = APRD_VAR;
    logic_value.name = (char*)"logical_value";
    logic_value.ty = mod.t_bool;
    AirPrd* logical_and_true = make_binop(&arena, ABIN_LAND, mod.t_bool, logic_value, make_bool(&arena, true, mod.t_bool));
    AirCmd* logical_and_true_ret = air_ir::air_new_AirCmd(&arena);
    logical_and_true_ret.tag = ACMD_RET;
    logical_and_true_ret.prd = logical_and_true;
    AirDecl* logical_and_true_decl = air_ir::air_new_AirDecl(&arena);
    logical_and_true_decl.tag = ADECL_DEF;
    logical_and_true_decl.name = (char*)"logical_and_true_identity";
    logical_and_true_decl.def_body = logical_and_true_ret;
    mod.decls[67] = logical_and_true_decl;

    AirPrd* logical_or_false = make_binop(&arena, ABIN_LOR, mod.t_bool, make_bool(&arena, false, mod.t_bool), logic_value);
    AirCmd* logical_or_false_ret = air_ir::air_new_AirCmd(&arena);
    logical_or_false_ret.tag = ACMD_RET;
    logical_or_false_ret.prd = logical_or_false;
    AirDecl* logical_or_false_decl = air_ir::air_new_AirDecl(&arena);
    logical_or_false_decl.tag = ADECL_DEF;
    logical_or_false_decl.name = (char*)"logical_or_false_identity";
    logical_or_false_decl.def_body = logical_or_false_ret;
    mod.decls[68] = logical_or_false_decl;

    AirPrd* chain_base_ref = air_ir::air_new_AirPrd(&arena);
    chain_base_ref.tag = APRD_VAR;
    chain_base_ref.name = (char*)"chain_base";
    chain_base_ref.ty = mod.t_i64;
    AirPrd* chain_initializer = make_binop(&arena, ABIN_ADD, mod.t_i64, chain_base_ref, make_int(&arena, 2, null));
    AirPrd* chain_value_ref = air_ir::air_new_AirPrd(&arena);
    chain_value_ref.tag = APRD_VAR;
    chain_value_ref.name = (char*)"chain_value";
    chain_value_ref.ty = mod.t_i64;
    AirCmd* chain_ret = air_ir::air_new_AirCmd(&arena);
    chain_ret.tag = ACMD_RET;
    chain_ret.prd = make_binop(&arena, ABIN_ADD, mod.t_i64, chain_value_ref, make_int(&arena, 3, null));
    AirCmd* chain_inner_let = air_ir::air_new_AirCmd(&arena);
    chain_inner_let.tag = ACMD_LET;
    chain_inner_let.binder = (char*)"chain_value";
    chain_inner_let.prd = chain_initializer;
    chain_inner_let.body = chain_ret;
    AirCmd* chain_outer_let = air_ir::air_new_AirCmd(&arena);
    chain_outer_let.tag = ACMD_LET;
    chain_outer_let.binder = (char*)"chain_base";
    chain_outer_let.prd = make_int(&arena, 39, mod.t_i64);
    chain_outer_let.body = chain_inner_let;
    AirDecl* chain_decl = air_ir::air_new_AirDecl(&arena);
    chain_decl.tag = ADECL_DEF;
    chain_decl.name = (char*)"chained_integer_let_specialization";
    chain_decl.def_body = chain_outer_let;
    mod.decls[69] = chain_decl;

    AirPrd* signed_power_two_div = make_binop(&arena, ABIN_DIV, mod.t_i32, signed_div_value, make_int(&arena, 8, null));
    AirCmd* signed_power_two_ret = air_ir::air_new_AirCmd(&arena);
    signed_power_two_ret.tag = ACMD_RET;
    signed_power_two_ret.prd = signed_power_two_div;
    AirDecl* signed_power_two_decl = air_ir::air_new_AirDecl(&arena);
    signed_power_two_decl.tag = ADECL_DEF;
    signed_power_two_decl.name = (char*)"signed_division_by_power_of_two";
    signed_power_two_decl.def_body = signed_power_two_ret;
    mod.decls[70] = signed_power_two_decl;

    AirPrd* negative_divisor = make_binop(&arena, ABIN_DIV, mod.t_i32, signed_div_value, make_int(&arena, -8, null));
    AirCmd* negative_divisor_ret = air_ir::air_new_AirCmd(&arena);
    negative_divisor_ret.tag = ACMD_RET;
    negative_divisor_ret.prd = negative_divisor;
    AirDecl* negative_divisor_decl = air_ir::air_new_AirDecl(&arena);
    negative_divisor_decl.tag = ADECL_DEF;
    negative_divisor_decl.name = (char*)"signed_division_by_negative_power_of_two";
    negative_divisor_decl.def_body = negative_divisor_ret;
    mod.decls[71] = negative_divisor_decl;

    AirPrd* computed_dividend = make_binop(&arena, ABIN_ADD, mod.t_i32, signed_div_value, make_int(&arena, 1, null));
    AirPrd* computed_division = make_binop(&arena, ABIN_DIV, mod.t_i32, computed_dividend, make_int(&arena, 8, null));
    AirCmd* computed_division_ret = air_ir::air_new_AirCmd(&arena);
    computed_division_ret.tag = ACMD_RET;
    computed_division_ret.prd = computed_division;
    AirDecl* computed_division_decl = air_ir::air_new_AirDecl(&arena);
    computed_division_decl.tag = ADECL_DEF;
    computed_division_decl.name = (char*)"signed_division_computed_operand";
    computed_division_decl.def_body = computed_division_ret;
    mod.decls[72] = computed_division_decl;

    AirPrd* signed_power_two_mod = make_binop(&arena, ABIN_MOD, mod.t_i32, signed_mod_value, make_int(&arena, 8, null));
    AirCmd* signed_power_two_mod_ret = air_ir::air_new_AirCmd(&arena);
    signed_power_two_mod_ret.tag = ACMD_RET;
    signed_power_two_mod_ret.prd = signed_power_two_mod;
    AirDecl* signed_power_two_mod_decl = air_ir::air_new_AirDecl(&arena);
    signed_power_two_mod_decl.tag = ADECL_DEF;
    signed_power_two_mod_decl.name = (char*)"signed_remainder_by_power_of_two";
    signed_power_two_mod_decl.def_body = signed_power_two_mod_ret;
    mod.decls[73] = signed_power_two_mod_decl;

    AirPrd* negative_mod_divisor = make_binop(&arena, ABIN_MOD, mod.t_i32, signed_mod_value, make_int(&arena, -8, null));
    AirCmd* negative_mod_ret = air_ir::air_new_AirCmd(&arena);
    negative_mod_ret.tag = ACMD_RET;
    negative_mod_ret.prd = negative_mod_divisor;
    AirDecl* negative_mod_decl = air_ir::air_new_AirDecl(&arena);
    negative_mod_decl.tag = ADECL_DEF;
    negative_mod_decl.name = (char*)"signed_remainder_by_negative_power_of_two";
    negative_mod_decl.def_body = negative_mod_ret;
    mod.decls[74] = negative_mod_decl;

    // Refuse a narrow signed overflow rather than baking host or wrapping
    // semantics into a constant, and leave division-by-zero untouched.
    AirPrd* narrow_sum = air_ir::air_new_AirPrd(&arena);
    narrow_sum.tag = APRD_BINOP;
    narrow_sum.bop = ABIN_ADD;
    narrow_sum.ty = mod.t_i8;
    narrow_sum.add_sub(make_int(&arena, 127, mod.t_i8));
    narrow_sum.add_sub(make_int(&arena, 1, mod.t_i8));
    AirCmd* narrow_ret = air_ir::air_new_AirCmd(&arena);
    narrow_ret.tag = ACMD_RET;
    narrow_ret.prd = narrow_sum;
    AirDecl* narrow_decl = air_ir::air_new_AirDecl(&arena);
    narrow_decl.tag = ADECL_DEF;
    narrow_decl.name = (char*)"narrow_overflow";
    narrow_decl.def_body = narrow_ret;
    mod.decls[3] = narrow_decl;

    AirPrd* div_zero = air_ir::air_new_AirPrd(&arena);
    div_zero.tag = APRD_BINOP;
    div_zero.bop = ABIN_DIV;
    div_zero.ty = mod.t_i64;
    div_zero.add_sub(make_int(&arena, 9, mod.t_i64));
    div_zero.add_sub(make_int(&arena, 0, mod.t_i64));
    AirCmd* div_ret = air_ir::air_new_AirCmd(&arena);
    div_ret.tag = ACMD_RET;
    div_ret.prd = div_zero;
    AirDecl* div_decl = air_ir::air_new_AirDecl(&arena);
    div_decl.tag = ADECL_DEF;
    div_decl.name = (char*)"divide_by_zero";
    div_decl.def_body = div_ret;
    mod.decls[4] = div_decl;

    AirPrd* mixed_width = air_ir::air_new_AirPrd(&arena);
    mixed_width.tag = APRD_BINOP;
    mixed_width.bop = ABIN_ADD;
    mixed_width.ty = mod.t_i64;
    mixed_width.add_sub(make_int(&arena, 1, mod.t_i64));
    mixed_width.add_sub(make_int(&arena, 2, mod.t_i32));
    AirCmd* mixed_ret = air_ir::air_new_AirCmd(&arena);
    mixed_ret.tag = ACMD_RET;
    mixed_ret.prd = mixed_width;
    AirDecl* mixed_decl = air_ir::air_new_AirDecl(&arena);
    mixed_decl.tag = ADECL_DEF;
    mixed_decl.name = (char*)"mixed_width";
    mixed_decl.def_body = mixed_ret;
    mod.decls[5] = mixed_decl;

    AirPrd* out_of_range = air_ir::air_new_AirPrd(&arena);
    out_of_range.tag = APRD_BINOP;
    out_of_range.bop = ABIN_ADD;
    out_of_range.ty = mod.t_i8;
    out_of_range.add_sub(make_int(&arena, 1, mod.t_i8));
    out_of_range.add_sub(make_int(&arena, 200, null));
    AirCmd* range_ret = air_ir::air_new_AirCmd(&arena);
    range_ret.tag = ACMD_RET;
    range_ret.prd = out_of_range;
    AirDecl* range_decl = air_ir::air_new_AirDecl(&arena);
    range_decl.tag = ADECL_DEF;
    range_decl.name = (char*)"out_of_range";
    range_decl.def_body = range_ret;
    mod.decls[6] = range_decl;
    mod.decl_count = 75;

    // Level 1 pins the expression pass alone: this harness asserts exact
    // counter values, so it must not also run the -O2 dead-binding pass.
    pear2_opt::OptStats stats = pear2_opt::optimize_module_at(&mod, 1);
    uint rewrites = stats.rewrites;
    if (rewrites != 65 || stats.constant_folds != 21 || stats.operand_rewrites != 25 || stats.strength_reductions != 11 ||
        stats.shift_combinations != 2 || stats.branch_reductions != 2 || stats.let_specializations != 4)
    {
        printf("FAIL: unexpected optimizer counters (total=%u folds=%u operands=%u strength=%u shifts=%u branches=%u lets=%u)\n",
               rewrites, stats.constant_folds, stats.operand_rewrites, stats.strength_reductions,
               stats.shift_combinations, stats.branch_reductions, stats.let_specializations);
        arena.destroy(); return 1;
    }
    if (multiply_by_eight.bop != ABIN_SHL || multiply_by_eight.subs[1] == scale_factor ||
        multiply_by_eight.subs[1].ival != 3 || scale_factor.ival != 8 ||
        multiply_by_eight_left.bop != ABIN_SHL || multiply_by_eight_left.subs[0] != scale_value ||
        multiply_by_eight_left.subs[1] == left_scale_factor || multiply_by_eight_left.subs[1].ival != 3 || left_scale_factor.ival != 8 ||
        multiply_by_six.bop != ABIN_MUL || multiply_by_six_left.bop != ABIN_MUL || non_power_factor.ival != 6)
    {
        printf("FAIL: power-of-two multiplication rewrite changed semantics or a shared constant\n");
        arena.destroy(); return 1;
    }
    if (combined_left_shift.bop != ABIN_SHL || combined_left_shift.subs[0] != left_shift_value || combined_left_shift.subs[1].ival != 5 ||
        combined_right_shift.bop != ABIN_SHR || combined_right_shift.subs[0] != right_shift_value || combined_right_shift.subs[1].ival != 3 ||
        inner_left_shift.subs[1].ival != 2 || inner_right_shift.subs[1].ival != 1 ||
        uncombined_narrow_shift.bop != ABIN_SHL || uncombined_narrow_shift.subs[0] != inner_narrow_shift ||
        uncombined_narrow_shift.subs[1].ival != 3)
    {
        printf("FAIL: nested shift composition or out-of-range rejection was incorrect\n");
        arena.destroy(); return 1;
    }
    if (unsigned_modulo.bop != ABIN_AND || unsigned_modulo.subs[1].ival != 7 ||
        signed_modulo.bop != ABIN_MOD || signed_power_two_mod.bop != ABIN_SUB ||
        signed_power_two_mod.subs[0] != signed_mod_value || signed_power_two_mod.subs[1].bop != ABIN_SHL ||
        signed_power_two_mod.subs[1].subs[1].ival != 3 || signed_power_two_mod.subs[1].subs[0].bop != ABIN_SHR ||
        signed_power_two_mod.subs[1].subs[0].subs[0].bop != ABIN_ADD || negative_mod_divisor.bop != ABIN_MOD || irregular_mod.bop != ABIN_MOD ||
        unsigned_quotient.bop != ABIN_SHR || unsigned_quotient.subs[1].ival != 3 ||
        signed_quotient.bop != ABIN_DIV || signed_power_two_div.bop != ABIN_SHR || signed_power_two_div.subs[1].ival != 3 ||
        signed_power_two_div.subs[0].bop != ABIN_ADD || signed_power_two_div.subs[0].subs[0] != signed_div_value ||
        signed_power_two_div.subs[0].subs[1].bop != ABIN_AND ||
        signed_power_two_div.subs[0].subs[1].subs[0].bop != ABIN_SHR ||
        signed_power_two_div.subs[0].subs[1].subs[0].subs[1].ival != 31 ||
        signed_power_two_div.subs[0].subs[1].subs[1].ival != 7 ||
        negative_divisor.bop != ABIN_DIV || computed_division.bop != ABIN_DIV || irregular_div.bop != ABIN_DIV ||
        signed_mask.tag != APRD_VAR || signed_mask.name != signed_mask_value.name ||
        unsigned_mask.tag != APRD_VAR || unsigned_mask.name != unsigned_mask_value.name ||
        signed_xor.tag != APRD_UNOP || signed_xor.uop != AUN_BITNOT || signed_xor.subs[0] != signed_mask_value || signed_xor.ty != mod.t_i32 ||
        unsigned_xor.tag != APRD_UNOP || unsigned_xor.uop != AUN_BITNOT || unsigned_xor.subs[0] != unsigned_mask_value || unsigned_xor.ty != mod.t_u32 ||
        unsigned_or_zero.tag != APRD_VAR || unsigned_or_zero.name != unsigned_mask_value.name ||
        unsigned_xor_zero.tag != APRD_VAR || unsigned_xor_zero.name != unsigned_mask_value.name ||
        double_bool_not.tag != APRD_VAR || double_bool_not.name != bool_not_value.name ||
        double_int_not.tag != APRD_VAR || double_int_not.name != int_not_value.name ||
        mismatched_double_not.tag != APRD_UNOP || mismatched_double_not.subs[0] != narrow_inner_not ||
        bool_xor_left.tag != APRD_UNOP || bool_xor_left.uop != AUN_NOT || bool_xor_left.subs[0] != bool_xor_value ||
        bool_xor_right.tag != APRD_UNOP || bool_xor_right.uop != AUN_NOT || bool_xor_right.subs[0] != bool_xor_value ||
        bool_eq_true.tag != APRD_VAR || bool_eq_true.name != bool_xor_value.name ||
        bool_eq_false.tag != APRD_UNOP || bool_eq_false.uop != AUN_NOT || bool_eq_false.subs[0] != bool_xor_value ||
        bool_neq_true.tag != APRD_UNOP || bool_neq_true.uop != AUN_NOT || bool_neq_true.subs[0] != bool_xor_value ||
        bool_neq_false.tag != APRD_VAR || bool_neq_false.name != bool_xor_value.name ||
        same_i32_coerce.tag != APRD_VAR || same_i32_coerce.name != same_i32_value.name ||
        same_bool_coerce.tag != APRD_VAR || same_bool_coerce.name != same_bool_value.name ||
        same_f32_coerce.tag != APRD_VAR || same_f32_coerce.name != same_f32_value.name ||
        mismatch_i32_coerce.tag != APRD_COERCE ||
        signed_mul_neg_one.tag != APRD_UNOP || signed_mul_neg_one.uop != AUN_NEG || signed_mul_neg_one.subs[0] != signed_neg_value || signed_mul_neg_one.ty != mod.t_i32 ||
        unsigned_mul_all_ones.tag != APRD_UNOP || unsigned_mul_all_ones.uop != AUN_NEG || unsigned_mul_all_ones.subs[0] != unsigned_neg_value || unsigned_mul_all_ones.ty != mod.t_u32 ||
        true_to_i32.tag != APRD_INT || true_to_i32.ival != 1 || false_to_u8.tag != APRD_INT || false_to_u8.ival != 0 ||
        odd_to_bool.tag != APRD_BOOL || !odd_to_bool.bval || even_to_bool.tag != APRD_BOOL || even_to_bool.bval ||
        logical_and_true.tag != APRD_VAR || logical_and_true.name != logic_value.name ||
        logical_or_false.tag != APRD_VAR || logical_or_false.name != logic_value.name ||
        remainder_one.bop != ABIN_AND || remainder_one.subs[0] != remainder_one_value || remainder_one.subs[1].ival != 0 ||
        remainder_zero.bop != ABIN_MOD || remainder_zero.subs[0] != remainder_one_value || remainder_zero.subs[1].ival != 0 ||
        mul_zero_right.bop != ABIN_AND || mul_zero_right.subs[0] != mul_zero_right_value || mul_zero_right.subs[1].ival != 0 ||
        mul_zero_left.bop != ABIN_AND || mul_zero_left.subs[0].ival != 0 || mul_zero_left.subs[1] != mul_zero_left_value ||
        mul_zero_constants.tag != APRD_INT || mul_zero_constants.ival != 0)
    {
        printf("FAIL: unsigned division/remainder reductions, all-ones identity, or safety rejection failed\n");
        arena.destroy(); return 1;
    }
    if (ret.prd.tag != APRD_INT || ret.prd.ival != 42 || ret.prd.id != 91 || ret.prd.ty != mod.t_i64)
    {
        printf("FAIL: constant fold changed value, id, or type\n"); arena.destroy(); return 1;
    }
    if (identity_ret.prd.tag != APRD_VAR || identity_ret.prd.name != variable.name || identity_ret.prd.ty != mod.t_i64)
    {
        printf("FAIL: typed integer identity did not preserve its operand value\n"); arena.destroy(); return 1;
    }
    if (branch_decl.def_body != else_ret || logical_not.tag != APRD_BOOL || logical_not.bval)
    {
        printf("FAIL: comparison/not folding did not select the correct branch\n"); arena.destroy(); return 1;
    }
    if (neg_ret.prd.tag != APRD_INT || neg_ret.prd.ival != -17 || bitnot_ret.prd.tag != APRD_INT || bitnot_ret.prd.ival != 255)
    {
        printf("FAIL: signed negate or unsigned narrow bitwise-not folded incorrectly\n"); arena.destroy(); return 1;
    }
    if (let_decl.def_body != let_cmd || let_cmd.body != let_else || let_if.prd.tag != APRD_BOOL || let_if.prd.bval || let_else.prd.tag != APRD_VAR)
    {
        printf("FAIL: nested bool-let condition was not folded safely with its branch use retained\n"); arena.destroy(); return 1;
    }
    if (int_let_decl.def_body != int_let || int_let_cut.prd.tag != APRD_INT || int_let_cut.prd.ival != 42)
    {
        printf("FAIL: integer let expression was not substituted and folded safely\n"); arena.destroy(); return 1;
    }
    if (chain_decl.def_body != chain_outer_let || chain_outer_let.body != chain_inner_let ||
        chain_inner_let.prd.tag != APRD_INT || chain_inner_let.prd.ival != 41 ||
        chain_inner_let.body != chain_ret || chain_ret.prd.tag != APRD_INT || chain_ret.prd.ival != 44)
    {
        printf("FAIL: chained integer-let constants did not propagate through pure initializers and return values\n"); arena.destroy(); return 1;
    }
    if (bool_identity_ret.prd.tag != APRD_VAR || bool_identity_ret.prd.name == null ||
        bool_identity_ret.prd.name[0] != 'f' || bool_identity_ret.prd.name[1] != 'l' ||
        bool_identity_ret.prd.name[2] != 'a' || bool_identity_ret.prd.name[3] != 'g' || bool_identity_ret.prd.name[4] != 0 ||
        unknown_bool_ret.prd.tag != APRD_BINOP)
    {
        printf("FAIL: typed boolean identity or ambiguous-boolean rejection was incorrect\n"); arena.destroy(); return 1;
    }
    if (sign_extend_ret.prd.tag != APRD_INT || sign_extend_ret.prd.ival != -7 ||
        zero_extend_ret.prd.tag != APRD_INT || zero_extend_ret.prd.ival != 250 ||
        truncate_ret.prd.tag != APRD_INT || truncate_ret.prd.ival != 2 || wide_coerce_ret.prd.tag != APRD_COERCE)
    {
        printf("FAIL: integer constant coercion folded incorrectly\n"); arena.destroy(); return 1;
    }
    if (arithmetic_shift_ret.prd.tag != APRD_INT || arithmetic_shift_ret.prd.ival != -2 ||
        logical_shift_ret.prd.tag != APRD_INT || logical_shift_ret.prd.ival != 32 ||
        left_shift_ret.prd.tag != APRD_INT || left_shift_ret.prd.ival != -128 ||
        bad_shift_ret.prd.tag != APRD_BINOP)
    {
        printf("FAIL: signed/logical/left shift fold or invalid shift rejection was incorrect\n"); arena.destroy(); return 1;
    }
    if (narrow_ret.prd.tag != APRD_BINOP || div_ret.prd.tag != APRD_BINOP || mixed_ret.prd.tag != APRD_BINOP ||
        range_ret.prd.tag != APRD_BINOP || div_overflow_ret.prd.tag != APRD_BINOP || compare_range_ret.prd.tag != APRD_BINOP ||
        bad_const_let.body != bad_const_ret || bad_const_ret.prd.tag != APRD_BINOP)
    {
        printf("FAIL: optimizer folded overflow, division hazards, or ill-represented operands\n"); arena.destroy(); return 1;
    }
    printf("PASS: optimizer folds, power-of-two strength reduction, typed identities, and representation/overflow safety (%u rewrites)\n", rewrites);
    arena.destroy();
    return 0;
}
