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
    decl.param_count = 1;
    decl.params[0] = &binder;

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
    printf("LLVM semantic attribute regressions: pass=%d fail=%d\n", passed, failed);
    free((void*)cg);
    pear::ll_mod_dispose(mod);
    pear::ll_ctx_dispose(ctx);
    return failed;
}
