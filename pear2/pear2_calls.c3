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

// Does a call possibly write through a pointer it is handed?
//
// For a body in this file the answer is a scan of that body; for an external
// symbol, an indirect call, or a body nested past the scan budget, the honest
// answer is yes. What the answer decides is whether the pointer cells inside the
// argument's object survive the call: "yes" costs precision (the caller has to
// store the pointer again before reading it back), while a wrong "no" would leave
// a cell describing memory the callee has already overwritten, and hand a load
// the provenance of whatever used to live there.
fn bool M1Gen.call_writes(M1Gen* g, AirDecl* target, bool direct, int depth)
{
    if (!direct || target == null || target.is_extern || target.def_body == null) { return true; }
    if (depth >= 4) { return true; }
    return g.cmd_writes(target.def_body, depth + 1);
}
fn bool M1Gen.cns_writes(M1Gen* g, AirCns* k, int depth)
{
    if (k == null) { return false; }
    if (depth >= 48) { return true; }
    if (k.tag == ACNS_COMU && g.cmd_writes(k.body, depth + 1)) { return true; }
    for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null && g.cmd_writes(k.branches[i].body, depth + 1)) { return true; } }
    for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null && g.cmd_writes(k.cobranches[i].body, depth + 1)) { return true; } }
    return g.cns_writes(k.tail, depth + 1);
}
fn bool M1Gen.cmd_writes(M1Gen* g, AirCmd* c, int depth)
{
    if (c == null) { return false; }
    if (depth >= 48) { return true; }
    if (c.tag == ACMD_STORE || c.tag == ACMD_ATOMIC || c.tag == ACMD_SYSCALL || c.tag == ACMD_ASM) { return true; }
    // A call is a cut whose continuation is ACNS_CALL; the callee is the producer.
    if (c.tag == ACMD_CUT && c.cns != null && c.cns.tag == ACNS_CALL)
    {
        AirDecl* target = (c.prd != null && c.prd.tag == APRD_VAR && g.lookup(c.prd.name) == null) ? g.find_function(c.prd.name) : null;
        if (target == null) { return true; }
        if (g.call_writes(target, true, depth + 1)) { return true; }
    }
    if (g.cns_writes(c.cns, depth + 1)) { return true; }
    if (g.cmd_writes(c.body, depth + 1)) { return true; }
    if (g.cmd_writes(c.then_c, depth + 1)) { return true; }
    if (g.cmd_writes(c.else_c, depth + 1)) { return true; }
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null && g.cmd_writes(c.branches[i].body, depth + 1)) { return true; } }
    return g.cmd_writes(c.next, depth + 1);
}
// The byte count of a heap call. A literal is proved here, so a non-positive one
// is a bug the compiler can point at; anything else becomes the register that
// every bound check against the object compares with.
fn bool M1Gen.heap_size_operand(M1Gen* g, AirPrd* arg, char* value, AirTyp* param_ty, long* out_size, char** out_value, int line, int col)
{
    *out_size = 0; *out_value = null;
    if (arg == null || param_ty == null) { return g.note_failure(line, col, (char*)"heap size operand is missing"); }
    if (arg.tag == APRD_INT)
    {
        if (arg.ival <= 0) { return g.note_failure(line, col, (char*)"a constant heap size must be positive"); }
        *out_size = arg.ival;
        return true;
    }
    if (m1_int_bits(param_ty) != 64 || value == null)
    { return g.note_failure(line, col, (char*)"a runtime heap size must be a 64-bit integer"); }
    *out_size = M1EXTENT_RUNTIME; *out_value = value;
    return true;
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
    // `realloc` is the growth step a container is built on. The call itself is
    // ordinary; what the backend has to record is that the old pointer is gone and
    // that the new one carries the requested size.
    bool is_realloc = direct && g.low_profile && same(m1_link_name(target), "realloc");
    long heap_size = 0; char* heap_allocation = null; char* heap_size_value = null;
    if (is_malloc)
    {
        if (argc != 1 || !m1_pointer_type(target_return) || args[0] == null || !m1_integer_type(target_params[0]))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"heap allocation requires one integer size argument and a pointer result"); return false; }
        if (!g.heap_size_operand(args[0], values[0], target_params[0], &heap_size, &heap_size_value, callee.source_line, callee.source_col)) { return false; }
    }
    if (is_realloc)
    {
        if (argc != 2 || !m1_pointer_type(target_return) || args[0] == null || args[1] == null ||
            !m1_pointer_type(target_params[0]) || !m1_integer_type(target_params[1]))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"realloc takes (pointer, integer) and returns a pointer"); return false; }
        if (!g.heap_size_operand(args[1], values[1], target_params[1], &heap_size, &heap_size_value, callee.source_line, callee.source_col)) { return false; }
        if (args[0].tag != APRD_NULL)
        {
            M1Provenance* hp = g.prov(values[0]);
            if (hp == null || hp.kind != M1PROV_HEAP || hp.freed || !hp.offset_known || hp.offset != 0)
            { g.note_failure(args[0].source_line, args[0].source_col, (char*)"realloc requires the live base pointer of a known heap allocation"); return false; }
            heap_allocation = hp.allocation;
        }
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
    // The three bulk operations are the only libc calls whose byte ranges this
    // backend can still reason about: the length is an argument, so the same bound
    // that guards a typed access guards a copy, proved when it is a literal and
    // checked when it is a register. Without this the model would have one hole
    // exactly where a buffer overflow is easiest to write.
    bool is_memcpy = direct && g.low_profile && (same(m1_link_name(target), "memcpy") || same(m1_link_name(target), "memmove"));
    bool is_memset = direct && g.low_profile && same(m1_link_name(target), "memset");
    if (is_memcpy)
    {
        if (argc != 3 || args[0] == null || args[1] == null || args[2] == null ||
            !m1_pointer_type(target_params[0]) || !m1_pointer_type(target_params[1]) || !m1_integer_type(target_params[2]))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"memcpy/memmove take (pointer, pointer, integer)"); return false; }
    }
    if (is_memset)
    {
        if (argc != 3 || args[0] == null || args[1] == null || args[2] == null ||
            !m1_pointer_type(target_params[0]) || !m1_integer_type(target_params[1]) || !m1_integer_type(target_params[2]))
        { g.note_failure(callee.source_line, callee.source_col, (char*)"memset takes (pointer, integer, integer)"); return false; }
    }
    if (is_memcpy || is_memset)
    {
        long bulk_size = -1; char* bulk_size_value = null;
        if (args[2].tag == APRD_INT)
        {
            if (args[2].ival < 0)
            { g.note_failure(args[2].source_line, args[2].source_col, (char*)"a bulk memory length cannot be negative"); return false; }
            bulk_size = args[2].ival;
        }
        else
        {
            if (m1_int_bits(target_params[2]) != 64 || values[2] == null)
            { g.note_failure(args[2].source_line, args[2].source_col, (char*)"a run-time bulk memory length must be a 64-bit integer"); return false; }
            bulk_size_value = values[2];
        }
        if (!g.check_range(values[0], bulk_size, bulk_size_value, args[0].source_line, args[0].source_col, true)) { return false; }
        if (is_memcpy && !g.check_range(values[1], bulk_size, bulk_size_value, args[1].source_line, args[1].source_col, false)) { return false; }
    }
    // Any other call can write through what it is given, and this backend does not
    // see it happen. Dropping the cells inside those objects is the fail-closed
    // answer: the next load of a pointer from that memory yields a value with no
    // provenance, which cannot be dereferenced until the program stores a tracked
    // pointer there again. The three modelled calls above keep their cells because
    // their effect is recorded exactly.
    if (!(is_malloc || is_free || is_realloc) && g.call_writes(target, direct, 0))
    {
        for (usz i = 0; i < argc; i++)
        {
            if (!m1_pointer_type(target_params[i])) { continue; }
            M1Provenance* ap = g.prov(values[i]);
            if (ap != null) { g.forget_cells_in(ap.allocation); }
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
        AirTyp* byte_ty = air_ir::air_mk_typ_simple(g.arena, ATYP_U8);
        AirTyp* byte_ptr_ty = air_ir::air_mk_typ_ptr(g.arena, byte_ty);
        if (byte_ty == null || byte_ptr_ty == null) { return false; }
        values[0] = closure_env;
        target_params[0] = byte_ptr_ty;
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
    if (is_malloc || is_realloc)
    {
        bool ok = heap_size_value != null
            ? g.prov_set_dynamic_extent(dst, m1_pointee_type(target_return), M1PROV_HEAP, 16, heap_size_value)
            : g.prov_set(dst, m1_pointee_type(target_return), M1PROV_HEAP, 16, heap_size, 0, true, true);
        if (!ok) { g.failed = true; return false; }
    }
    if (is_free && heap_allocation != null) { g.mark_allocation_freed(heap_allocation); }
    if (is_realloc && heap_allocation != null)
    {
        // The object may have moved: its cells describe memory this program no
        // longer owns, and every alias of the old pointer has to fail closed.
        g.forget_cells_in(heap_allocation);
        g.mark_allocation_freed(heap_allocation);
    }
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
