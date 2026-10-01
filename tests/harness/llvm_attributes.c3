// Qualifier facts must be LLVM semantic attrs, not ignored string metadata.
module llvm_attributes_test;
import pear;
import air_ir;

extern fn int printf(char* fmt, ...);
extern fn void* calloc(usz n, usz size);
extern fn void free(void* p);
extern fn uint attr_kind(char* name, usz len) @cname("LLVMGetEnumAttributeKindForName");
extern fn void* enum_at(void* fnv, uint idx, uint kind) @cname("LLVMGetEnumAttributeAtIndex");
extern fn ulong enum_value(void* attr) @cname("LLVMGetEnumAttributeValue");

fn int main()
{
    pear::Lcontext ctx = pear::ll_ctx_create();
    pear::Lmodule mod = pear::ll_mod_create((char*)"n3-semantic-attributes", ctx);
    pear::Ltype[1] params;
    params[0] = pear::ll_ptr_ty(pear::ll_i8_ty(ctx), 0);
    pear::Ltype ty = pear::ll_fn_ty(pear::ll_i64_ty(ctx), &params[0], 1, 0);
    pear::Lvalue fnv = pear::ll_add_fn(mod, (char*)"attribute_probe", ty);
    pear::PearCg* cg = (pear::PearCg*)calloc(1, pear::PearCg::size);
    if (cg == null) { return 2; }
    cg.ctx = ctx;
    air_ir::AirDecl decl;
    air_ir::AirBinder binder;
    binder.no_capture = true;
    // Low-level API test explicitly supplies trusted facts; production facts
    // must pass the separate post-lowering AIR screen.
    decl.fact_state = air_ir::AirFactState.AFACT_AIR_CHECKED;
    decl.param_count = 1;
    decl.params[0] = &binder;

    pear::pear_tag_fn(cg, fnv, pear::LLVM_ATTR_NOUNWIND);
    pear::pear_tag_memory_read(cg, fnv);
    pear::pear_tag_captures_none_params(cg, fnv, &decl);
    uint memory_kind = attr_kind((char*)"memory", 6);
    uint captures_kind = attr_kind((char*)"captures", 8);
    void* memory = enum_at(fnv, 0xffffffffu, memory_kind);
    void* captures = enum_at(fnv, 1, captures_kind);
    int passed = 0; int failed = 0;
    // LLVM 23's parser maps standard `memory(read)` to 0x555 (1365).
    // This reference came from parsing the actual semantic IR attribute;
    // older 3-location masks such as 21 are NOT sufficient for LLVM 23.
    if (memory != null && enum_value(memory) == 1365) { passed++; }
    else { printf("FAIL qualifier memory(read): not a semantic LLVM attribute\n"); failed++; }
    if (captures != null && enum_value(captures) == 0) { passed++; }
    else { printf("FAIL qualifier captures(none): not a semantic LLVM attribute\n"); failed++; }
    uint nounwind_kind = attr_kind((char*)"nounwind", 8);
    void* nounwind = enum_at(fnv, 0xffffffffu, nounwind_kind);
    if (nounwind != null) { passed++; }
    else { printf("FAIL named nounwind: copied enum ordinal was used\n"); failed++; }

    pear::Ltype[1] size_arg; size_arg[0] = pear::ll_i64_ty(ctx);
    pear::Ltype pointer = pear::ll_ptr_ty(pear::ll_i8_ty(ctx), 0);
    pear::Lvalue allocate = pear::ll_add_fn(mod, (char*)"allocator_probe", pear::ll_fn_ty(pointer, &size_arg[0], 1, 0));
    pear::Lvalue deallocate = pear::ll_add_fn(mod, (char*)"free_probe", pear::ll_fn_ty(pear::ll_void_ty(ctx), &params[0], 1, 0));
    pear::pear_tag_alloc_kind(cg, allocate, 9);
    pear::pear_tag_alloc_kind(cg, deallocate, 4);
    uint allocation_kind = attr_kind((char*)"allockind", 9);
    void* alloc = enum_at(allocate, 0xffffffffu, allocation_kind);
    void* freed = enum_at(deallocate, 0xffffffffu, allocation_kind);
    if (alloc != null && enum_value(alloc) == 9) { passed++; }
    else { printf("FAIL semantic alloc-kind: alloc/uninitialized not encoded\n"); failed++; }
    if (freed != null && enum_value(freed) == 4) { passed++; }
    else { printf("FAIL semantic alloc-kind: free not encoded\n"); failed++; }
    printf("LLVM semantic attribute regressions: pass=%d fail=%d\n", passed, failed);
    free((void*)cg);
    pear::ll_mod_dispose(mod);
    pear::ll_ctx_dispose(ctx);
    return failed;
}
