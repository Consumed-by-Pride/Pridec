// Independent AIR-boundary tests: intentionally forged/stale candidates must
// never become LLVM guarantees. These build real IR graphs, not stdout counts.
module air_contracts_test;
import air_ir;
import air_facts;
extern fn int printf(char* fmt, ...);

fn air_ir::AirDecl* make_fn(air_ir::AirModule* m, char* name, usz count)
{
    air_ir::AirDecl* d = air_ir::air_mk_decl(m.arena, air_ir::AirDeclTag.ADECL_DEF, name);
    d.fact_state = air_ir::AirFactState.AFACT_AST_FINAL;
    d.memory_readonly = true;
    d.ret_ty = m.t_i64;
    for (usz i = 0; i < count; i++)
    {
        char* arg = i == 0 ? (char*)"p" : (char*)"out";
        air_ir::AirBinder* b = air_ir::air_mk_binder(m.arena, arg,
            air_ir::air_mk_typ_ptr(m.arena, m.t_i64), air_ir::AirMult.AMULT_UNR);
        b.no_capture = true; d.add_param(b);
    }
    m.add_decl(d);
    return d;
}

fn void check(bool value, char* label, int* pass, int* fail)
{
    if (value) { *pass = *pass + 1; }
    else { printf("FAIL AIR contract: %s\n", label); *fail = *fail + 1; }
}

fn int main()
{
    air_ir::AirArena a; a.init();
    air_ir::AirModule m; m.init(&a, (char*)"contract-tests", null);
    int pass = 0; int fail = 0;
    air_ir::AirPrd* p = air_ir::air_mk_var(&a, (char*)"p");
    air_ir::AirPrd* out = air_ir::air_mk_var(&a, (char*)"out");
    air_ir::AirPrd* zero = air_ir::air_mk_int(&a, 0);

    air_ir::AirDecl* read = make_fn(&m, (char*)"load_only", 1);
    air_ir::AirCns* load = air_ir::air_new_AirCns(&a);
    load.tag = air_ir::AirCnsTag.ACNS_INDEX; load.prd = zero; load.idx = 8; load.tail = m.c_ret;
    read.def_body = air_ir::air_mk_cut(&a, p, load);
    air_facts::validate_module(&m);
    check(read.fact_state == air_ir::AirFactState.AFACT_AIR_CHECKED && read.memory_readonly
          && read.params[0].no_capture, "loaded value is not its address copy", &pass, &fail);

    air_ir::AirDecl* returned = make_fn(&m, (char*)"returns_address", 1);
    returned.def_body = air_ir::air_mk_cut(&a, p, m.c_ret);
    air_facts::validate_module(&m);
    check(returned.memory_readonly && !returned.params[0].no_capture,
          "returned pointer cannot claim capture-none", &pass, &fail);

    air_ir::AirDecl* stored = make_fn(&m, (char*)"stores_address", 2);
    air_ir::AirCns* store = air_ir::air_new_AirCns(&a);
    store.tag = air_ir::AirCnsTag.ACNS_STORE; store.prd = p; store.idx = 8; store.tail = m.c_ret;
    stored.def_body = air_ir::air_mk_cut(&a, out, store);
    air_facts::validate_module(&m);
    check(!stored.memory_readonly && !stored.params[0].no_capture,
          "external address storage defeats both forged claims", &pass, &fail);

    air_ir::AirDecl* alias_fn = make_fn(&m, (char*)"stores_alias", 2);
    air_ir::AirCns* alias_store = air_ir::air_new_AirCns(&a);
    alias_store.tag = air_ir::AirCnsTag.ACNS_STORE;
    alias_store.prd = air_ir::air_mk_var(&a, (char*)"alias"); alias_store.idx = 8; alias_store.tail = m.c_ret;
    alias_fn.def_body = air_ir::air_mk_cut(&a, p,
        air_ir::air_mk_comu_cns(&a, (char*)"alias", air_ir::air_mk_cut(&a, out, alias_store)));
    air_facts::validate_module(&m);
    check(!alias_fn.params[0].no_capture && !alias_fn.memory_readonly,
          "local SSA alias retains original parameter taint", &pass, &fail);

    air_ir::AirDecl* integer = make_fn(&m, (char*)"integer_param", 1);
    integer.params[0].ty = m.t_i64;
    integer.def_body = air_ir::air_mk_cut(&a, zero, m.c_ret);
    air_facts::validate_module(&m);
    check(!integer.params[0].no_capture, "capture contract is pointer-only", &pass, &fail);

    air_ir::AirDecl* stale = make_fn(&m, (char*)"unfinalized", 1);
    stale.fact_state = air_ir::AirFactState.AFACT_UNKNOWN;
    stale.def_body = air_ir::air_mk_cut(&a, zero, m.c_ret);
    air_facts::validate_module(&m);
    check(!stale.memory_readonly && !stale.params[0].no_capture,
          "unfinalized source facts are never upgraded", &pass, &fail);

    air_ir::AirDecl* unsupported = make_fn(&m, (char*)"unknown_effect", 1);
    unsupported.def_body = air_ir::air_new_AirCmd(&a);
    unsupported.def_body.tag = air_ir::AirCmdTag.ACMD_ASM;
    air_facts::validate_module(&m);
    check(unsupported.fact_state == air_ir::AirFactState.AFACT_UNKNOWN
          && !unsupported.memory_readonly && !unsupported.params[0].no_capture,
          "unsupported IR becomes unknown, not pure", &pass, &fail);

    air_ir::AirDecl* conditional = make_fn(&m, (char*)"exposes_nullness", 1);
    conditional.def_body = air_ir::air_new_AirCmd(&a);
    conditional.def_body.tag = air_ir::AirCmdTag.ACMD_IF;
    conditional.def_body.prd = p;
    conditional.def_body.then_c = air_ir::air_mk_cut(&a, air_ir::air_mk_int(&a, 1), m.c_ret);
    conditional.def_body.else_c = air_ir::air_mk_cut(&a, zero, m.c_ret);
    air_facts::validate_module(&m);
    check(!conditional.params[0].no_capture,
          "control-dependent returns may expose address information", &pass, &fail);

    // Put a caller before a callee so the first scan sees the forged callee
    // candidate. Module revalidation must propagate its later downgrade.
    air_ir::AirDecl* caller = make_fn(&m, (char*)"forward_caller", 1);
    air_ir::AirPrd*[2] argv; argv[0] = p; argv[1] = zero;
    caller.def_body = air_ir::air_mk_cut(&a, air_ir::air_mk_var(&a, (char*)"late_bad_callee"),
                                      air_ir::air_mk_call(&a, &argv[0], 2, m.c_ret));
    air_ir::AirDecl* late = make_fn(&m, (char*)"late_bad_callee", 2);
    late.def_body = air_ir::air_mk_cut(&a, out, store);
    air_facts::validate_module(&m);
    check(!caller.memory_readonly && !caller.params[0].no_capture,
          "callee downgrades invalidate dependent caller facts", &pass, &fail);

    air_ir::AirDecl* deep = make_fn(&m, (char*)"over_budget", 1);
    deep.def_body = air_ir::air_mk_cut(&a, zero, m.c_ret);
    for (int i = 0; i < 210; i++)
    {
        air_ir::AirCmd* block = air_ir::air_new_AirCmd(&a);
        block.tag = air_ir::AirCmdTag.ACMD_BLOCK; block.body = deep.def_body; deep.def_body = block;
    }
    air_facts::validate_module(&m);
    check(deep.fact_state == air_ir::AirFactState.AFACT_UNKNOWN
          && !deep.memory_readonly && !deep.params[0].no_capture,
          "depth budget exhaustion is fail-closed", &pass, &fail);

    printf("AIR contract regressions: pass=%d fail=%d\n", pass, fail);
    a.destroy();
    return fail;
}
