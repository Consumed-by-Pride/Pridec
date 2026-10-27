// PEAR 2 call lowering and ABI agreement checks for direct, external,
// closure, and supported indirect calls. Same pear2c module/context.
module pear2c;
import air_ir;

// m1_cns_delivers_to_return -- does this continuation hand the call's result
// straight back to the caller, with nothing in between? That is the shape a tail
// call takes in CPS: the call's own continuation *is* the function's return
// covariable, possibly reached through ascriptions and the argument stack that
// the caller already consumed.
//
// The marker this enables is LLVM's `tail`, not `musttail`: `tail` is a promise
// about the callee's stack frame only, so it stays correct for every call this
// backend emits, including indirect closure calls whose signature the emitter
// derived from a type instead of from the callee's declaration.
fn bool m1_cns_delivers_to_return(AirCns* k, char* ret_name, int depth)
{
    if (k == null || ret_name == null || depth >= 24) { return false; }
    if (k.tag == ACNS_COVAR) { return same(k.name, ret_name); }
    if (k.tag == ACNS_ASCRIBE) { return m1_cns_delivers_to_return(k.tail, ret_name, depth + 1); }
    return false;
}

fn bool M1Gen.call(M1Gen* g, AirPrd* callee, AirCns* k, char* ret_name)
{
    if (callee == null || k == null || k.tag != ACNS_CALL)
    {
        g.note_failure(g.last_line, g.last_col, (char*)"malformed call continuation"); return false;
    }
    AirDecl* target = null;
    bool direct = false;
    if (callee.tag == APRD_VAR && g.lookup(callee.name) == null)
    {
        target = g.find_function(callee.name);
        direct = target != null;
    }
    AirTyp* target_return = null;
    AirTyp*[64] target_params;
    usz target_param_count = 0;
    char* indirect_value = null;
    bool closure_abi = false; char* closure_env = null; char* closure_value = null;
    if (direct)
    {
        if (!m1_safe_name(target.name) || !m1_function_signature(target) || !m1_safe_name(m1_link_name(target)))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"invalid direct call target signature"); return false; }
        target_return = g.decl_return_type(target);
        target_param_count = target.param_count;
        if (!m1_backend_type(target_return, g.decls, g.decl_count, 0))
        {
            if (target.is_extern && m1_c_abi_aggregate_type(target_return)) { g.note_external_aggregate_failure(target, target_return, callee.source_line, callee.source_col); }
 return false;
        }
        if (target.is_extern && !m1_scalar_type(target_return) && !m1_unit_type(target_return) &&
            g.external_aggregate_problem(target_return) != null)
        { g.note_external_aggregate_failure(target, target_return, callee.source_line, callee.source_col);
 return false; }
        for (usz i = 0; i < target_param_count; i++)
        {
            target_params[i] = g.decl_value_type(target.params[i].ty, target_return);
            if (!m1_backend_type(target_params[i], g.decls, g.decl_count, 0))
            {
                if (target.is_extern && m1_c_abi_aggregate_type(target_params[i])) { g.note_external_aggregate_failure(target, target_params[i], callee.source_line, callee.source_col); }
 return false;
            }
            if (target.is_extern && !m1_scalar_type(target_params[i]) &&
                g.external_aggregate_problem(target_params[i]) != null)
            { g.note_external_aggregate_failure(target, target_params[i], callee.source_line, callee.source_col);
 return false; }
        }
    }
    else
    {
        AirTyp* function_type = g.expr_type(callee);
        closure_abi = m1_closure_type(function_type);
        if (closure_abi)
        {
            AirTyp* raw = function_type.args[0];
            target_return = raw.args[1];
            target_param_count = raw.args[0].arg_count - 1;
            for (usz i = 0; i < target_param_count; i++) { target_params[i] = raw.args[0].args[i + 1]; }
            if (!(m1_unit_type(target_return) || m1_value_type(target_return, 0)) ||
                !m1_backend_type(target_return, g.decls, g.decl_count, 0))
            { g.note_failure(callee.source_line, callee.source_col, (char*)"unsupported closure-call result type"); return false; }
            for (usz i = 0; i < target_param_count; i++)
            {
                if (!m1_value_type(target_params[i], 0) || !m1_backend_type(target_params[i], g.decls, g.decl_count, 0))
                { g.note_failure(callee.source_line, callee.source_col, (char*)"unsupported closure-call parameter type"); return false; }
            }
            closure_value = g.prd(callee);
            if (g.failed || closure_value == null) { return false; }
            char* closure_ir = g.llvm_value_type_text(function_type);
            char* code_tmp = g.tmp(); char* env_tmp = g.tmp();
            if (closure_ir == null || code_tmp == null || env_tmp == null) { return false; }
            fprintf(g.out, "  %s = extractvalue %s %s, 0\n", code_tmp, closure_ir, closure_value);
            fprintf(g.out, "  %s = extractvalue %s %s, 1\n", env_tmp, closure_ir, closure_value);
            indirect_value = code_tmp;
            closure_env = env_tmp;
        }
        if (!closure_abi && (!m1_function_pointer_type(function_type) || !m1_value_type(function_type, 0)))
        {
            g.note_failure(callee.source_line, callee.source_col, (char*)"indirect call requires a supported function-pointer signature"); return false;
        }
        if (callee.tag == APRD_NULL)
        {
            g.note_failure(callee.source_line, callee.source_col, (char*)"cannot invoke a null function pointer"); return false;
        }
        if (!closure_abi)
        {
        target_return = function_type.args[1];
        target_param_count = function_type.args[0].arg_count;
        if (!(m1_unit_type(target_return) || m1_value_type(target_return, 0)) ||
            !m1_backend_type(target_return, g.decls, g.decl_count, 0))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"unsupported indirect-call result type"); return false; }
        for (usz i = 0; i < target_param_count; i++)
        {
            target_params[i] = function_type.args[0].args[i];
            if (!m1_value_type(target_params[i], 0) || !m1_backend_type(target_params[i], g.decls, g.decl_count, 0))
            { g.note_failure(callee.source_line, callee.source_col, (char*)"unsupported indirect-call parameter type"); return false; }
            if (m1_c_abi_aggregate_type(target_params[i]) &&
                (g.external_aggregate_problem(target_params[i]) != null || g.type_size(target_params[i], 0) > 16))
            { g.note_indirect_aggregate_failure(target_params[i], (char*)"parameter", callee.source_line, callee.source_col);
 return false; }
        }
        if (m1_c_abi_aggregate_type(target_return) &&
            (g.external_aggregate_problem(target_return) != null || g.type_size(target_return, 0) > 16))
        { g.note_indirect_aggregate_failure(target_return, (char*)"result", callee.source_line, callee.source_col);
 return false; }
        indirect_value = g.pointer_value(callee);
        if (g.failed || indirect_value == null) {
 return false; }
        }
    }
    bool external_abi = direct && target.is_extern;
    bool sret_result = external_abi && g.external_aggregate_indirect(target_return);
    AirPrd*[64] args;
    usz argc = 0;
    AirCns* tail = k.tail;
    while (tail != null && tail.tag == ACNS_STACK)
    {
        if (argc >= 64 || tail.prd == null) {
 return false; }
        args[argc] = tail.prd;
        argc++;
        tail = tail.tail;
    }
    if (argc != target_param_count || tail == null)
    {
        g.note_failure(callee.source_line, callee.source_col, (char*)"call argument count does not match function-pointer signature"); return false;
    }
    char*[64] values;
    for (usz i = 0; i < argc; i++)
    {
        if (!m1_value_type(target_params[i], 0)) {
 return false; }
        bool expected_bool = m1_bool_type(target_params[i]);
        bool expected_ptr = m1_pointer_repr_type(target_params[i]);
        bool actual_bool = g.is_condition(args[i]);
        bool actual_ptr = !actual_bool && g.is_pointer_value(args[i]);
        if (actual_bool != expected_bool || actual_ptr != expected_ptr)
        {
            g.note_failure(args[i].source_line, args[i].source_col, (char*)"call argument representation does not match expected signature"); return false;
        }
        if (m1_function_pointer_type(target_params[i]) &&
            !m1_value_type_compatible(target_params[i], g.expr_type(args[i]), 0))
        {
            g.note_failure(args[i].source_line, args[i].source_col, (char*)"function-pointer argument signature mismatch"); return false;
        }
        if (!expected_bool && !expected_ptr)
        {
            bool compatible = m1_float_type(target_params[i]) ? m1_scalar_compatible(target_params[i], g.expr_type(args[i])) : (m1_integer_type(target_params[i]) ? g.integer_value_compatible(args[i], target_params[i]) : m1_value_type_compatible(target_params[i], g.expr_type(args[i]), 0));
            if (!compatible)
            { g.note_failure(args[i].source_line, args[i].source_col, (char*)"call argument type does not match expected signature"); return false; }
        }
        values[i] = actual_bool ? g.condition(args[i]) : (actual_ptr ? g.pointer_value(args[i]) : g.prd(args[i]));
        if (g.failed || values[i] == null) {
 return false; }
    }
    bool is_malloc = direct && g.low_profile && same(m1_link_name(target), "malloc");
    bool is_free = direct && g.low_profile && same(m1_link_name(target), "free");
    long heap_size = 0; char* heap_allocation = null;
    if (is_malloc)
    {
        if (argc != 1 || !m1_pointer_type(target_return) || args[0].tag != APRD_INT || args[0].ival <= 0 || args[0].ival > 1048576)
        { g.note_failure(callee.source_line, callee.source_col, (char*)"heap allocation requires a positive constant size no greater than 1 MiB"); return false; }
        heap_size = args[0].ival;
    }
    if (is_free)
    {
        if (argc != 1 || !m1_unit_type(target_return) || !m1_pointer_type(target_params[0]))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"free requires one typed pointer argument and unit result"); return false; }
        if (args[0].tag != APRD_NULL)
        {
            M1Provenance* hp = g.prov(values[0]);
            if (hp == null || hp.kind != M1PROV_HEAP || hp.freed || !hp.offset_known || hp.offset != 0)
            { g.note_failure(args[0].source_line, args[0].source_col, (char*)"free requires the live base pointer of a known heap allocation"); return false; }
            heap_allocation = hp.allocation;
        }
    }
    if (external_abi)
    {
        for (usz i = 0; i < argc; i++)
        {
            if (!g.external_aggregate_indirect(target_params[i])) { continue; }
            char* aggregate_type = g.llvm_type_text(target_params[i]);
            char* slot = g.tmp();
            int align = g.type_alignment(target_params[i], 0);
            if (aggregate_type == null || slot == null || align <= 0) {
 return false; }
            fprintf(g.out, "  %s = alloca %s, align %d\n", slot, aggregate_type, align);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", aggregate_type, values[i], slot, align);
            values[i] = slot;
        }
    }
    if (!direct && !closure_abi)
    {
        char* is_null = g.tmp();
        char* trap_label = g.label((char*)"indirect.null.");
        char* call_label = g.label((char*)"indirect.call.");
        if (is_null == null || trap_label == null || call_label == null) {
 return false; }
        fprintf(g.out, "  %s = icmp eq ptr %s, null\n", is_null, indirect_value);
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", is_null, trap_label, call_label);
        g.terminated = true;
        g.begin_block(trap_label);
        fprintf(g.out, "  call void @llvm.trap()\n  unreachable\n");
        g.begin_block(call_label);
        g.terminated = false;
    }
    bool result_unit = m1_unit_type(target_return);
    bool result_bool = m1_bool_type(target_return);
    bool result_ptr = m1_pointer_repr_type(target_return);
    char* dst = null;
    char* sret_slot = null;
    char* sret_type = null;
    int sret_align = 0;
    if (sret_result)
    {
        sret_type = g.llvm_type_text(target_return);
        sret_slot = g.tmp();
        sret_align = g.type_alignment(target_return, 0);
        if (sret_type == null || sret_slot == null || sret_align <= 0) {
 return false; }
        fprintf(g.out, "  %s = alloca %s, align %d\n", sret_slot, sret_type, sret_align);
    }
    if (closure_abi)
    {
        // Prepend the captured environment as the hidden first argument.
        usz shift = argc;
        while (shift >= 1) { values[shift] = values[shift - 1]; target_params[shift] = target_params[shift - 1]; shift--; }
        AirTyp* u8 = air_ir::air_mk_typ_simple(g.arena, ATYP_U8);
        AirTyp* u8p = air_ir::air_mk_typ_ptr(g.arena, u8);
        if (u8 == null || u8p == null) { return false; }
        values[0] = closure_env;
        target_params[0] = u8p;
        argc++;
    }
    char* call_result_type = sret_result ? (char*)"void" : g.llvm_abi_return_text(target_return);
    if (call_result_type == null) {
 return false; }
    char* call_cc_text = direct && target != null && m1_decl_callconv(target) == 1 ? "fastcc " : "";
    // A call whose continuation is the function's own return covariable is in
    // tail position: its frame can be replaced rather than stacked. Marking it
    // is what makes a recursive binding a loop in machine code instead of a
    // stack overflow, and PEAR 2's closure ABI (a hidden leading `ptr %env`)
    // keeps the signature identical on both sides of a self call, which is
    // exactly the case the marker is for.
    char* tail_text = m1_cns_delivers_to_return(k.tail, ret_name, 0) ? (char*)"tail " : (char*)"";
    if (result_unit || sret_result) { fprintf(g.out, "  call %s%svoid ", tail_text, call_cc_text); }
    else
    {
        dst = g.tmp();
        if (dst == null) {
 return false; }
        fprintf(g.out, "  %s = call %s%s%s ", dst, tail_text, call_cc_text, call_result_type);
    }
    if (direct) { fprintf(g.out, "@%s(", m1_link_name(target)); }
    else { fprintf(g.out, "%s(", indirect_value); }
    bool have_call_arg = false;
    if (sret_result)
    {
        fprintf(g.out, "ptr sret(%s) align %d %s", sret_type, sret_align, sret_slot);
        have_call_arg = true;
    }
    for (usz i = 0; i < argc; i++)
    {
        if (have_call_arg) { fprintf(g.out, ", "); }
        if (external_abi && g.external_aggregate_indirect(target_params[i]))
        {
            char* aggregate_type = g.llvm_type_text(target_params[i]);
            int align = g.type_alignment(target_params[i], 0);
            if (aggregate_type == null || align <= 0) {
 return false; }
            fprintf(g.out, "ptr byval(%s) align %d %s", aggregate_type, align, values[i]);
        }
        else { fprintf(g.out, "%s %s", g.llvm_abi_argument_text(target_params[i]), values[i]); }
        have_call_arg = true;
    }
    fprintf(g.out, ")\n");    if (sret_result)
    {
        dst = g.tmp();
        if (dst == null) {
 return false; }
        fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", dst, sret_type, sret_slot, sret_align);
    }
    if (is_malloc && !g.prov_set(dst, m1_pointee_type(target_return), M1PROV_HEAP, 16, heap_size, 0, true, true)) { g.failed = true;
 return false; }
    if (is_free && heap_allocation != null) { g.mark_allocation_freed(heap_allocation); }
    if (result_unit) { return g.consume_unit(tail, ret_name); }
    return g.consume(dst, result_bool, result_ptr, target_return, tail, ret_name);
}
fn bool m1_abi_scalar_compatible(AirTyp* a, AirTyp* b)
{    if (a == null || b == null) {
 return false; }
    if (m1_unit_type(a)) { return m1_unit_type(b); }
    if (m1_bool_type(a)) { return m1_bool_type(b); }
    if (m1_function_pointer_type(a) || m1_function_pointer_type(b)) { return m1_value_type_compatible(a, b, 0); }
    if (m1_pointer_type(a)) { return m1_pointer_type(b); }
    if (m1_float_type(a)) { return m1_float_type(b) && a.tag == b.tag; }
    if (m1_integer_type(a))
    {        if (!m1_integer_type(b) || m1_int_bits(a) != m1_int_bits(b)) {
 return false; }
        if (m1_int_bits(a) < 32 && m1_unsigned(a) != m1_unsigned(b)) {
 return false; }
        return true;
    }
    if (a.tag == ATYP_NOMINAL) { return b.tag == ATYP_NOMINAL && same(a.name, b.name); }
    if (a.tag == ATYP_ARRAY)
    {
        return b.tag == ATYP_ARRAY && a.ival == b.ival && a.arg_count == 1 && b.arg_count == 1 && m1_abi_scalar_compatible(a.args[0], b.args[0]);
    }
    if (a.tag == ATYP_TUPLE)
    {        if (b.tag != ATYP_TUPLE || a.arg_count != b.arg_count) {
 return false; }
        for (usz i = 0; i < a.arg_count; i++) { if (!m1_abi_scalar_compatible(a.args[i], b.args[i])) {
 return false; } }
        return true;
    }
 return false;
}
fn bool m1_same_abi(AirDecl* a, AirDecl* b)
{
    if (a == null || b == null || a.param_count != b.param_count || !m1_abi_scalar_compatible(a.ret_ty, b.ret_ty)) {
 return false; }
    for (usz i = 0; i < a.param_count; i++)
    {
        if (a.params[i] == null || b.params[i] == null || !m1_abi_scalar_compatible(a.params[i].ty, b.params[i].ty)) {
 return false; }
    }
    return true;
}
