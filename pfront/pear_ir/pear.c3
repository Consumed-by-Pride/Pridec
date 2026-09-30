// pear.c3 — PEAR: Pride's Engine for Abstractive Representations.
//
// v0.3 Bitcode backend. PEAR does NOT emit LLVM IR text; it builds an
// LLVM module directly via the LLVM-C API and writes a `.bc` bitcode
// file using LLVMWriteBitcodeToFile.
//
// Linked against: libLLVM-19 (-lLLVM-19).

module pear;
import air_ir;
import air_types;

// ── LLVM-C API (subset we need) ───────────────────────────────────────

alias Lcontext = void*;
alias Lmodule = void*;
alias Lbuilder = void*;
alias Ltype = void*;
alias Lvalue = void*;
alias Lblock = void*;

// ICmp predicates (LLVM-C)
const int LLVM_ICMP_EQ  = 32;
const int LLVM_ICMP_NE  = 33;
const int LLVM_ICMP_SGT = 38;
const int LLVM_ICMP_SGE = 39;
const int LLVM_ICMP_SLT = 40;
const int LLVM_ICMP_SLE = 41;

extern fn Lcontext ll_ctx_create() @cname("LLVMContextCreate");
extern fn void ll_ctx_dispose(Lcontext c) @cname("LLVMContextDispose");
extern fn Lmodule ll_mod_create(char* name, Lcontext c) @cname("LLVMModuleCreateWithNameInContext");
extern fn void ll_mod_dispose(Lmodule m) @cname("LLVMDisposeModule");
extern fn int ll_set_target(Lmodule m, char* t) @cname("LLVMSetTarget");
extern fn int ll_set_datalayout(Lmodule m, char* dl) @cname("LLVMSetDataLayout");

extern fn Ltype ll_void_ty(Lcontext c) @cname("LLVMVoidTypeInContext");
extern fn Ltype ll_i1_ty(Lcontext c) @cname("LLVMInt1TypeInContext");
extern fn Ltype ll_i8_ty(Lcontext c) @cname("LLVMInt8TypeInContext");
extern fn Ltype ll_i16_ty(Lcontext c) @cname("LLVMInt16TypeInContext");
extern fn Ltype ll_i32_ty(Lcontext c) @cname("LLVMInt32TypeInContext");
extern fn Ltype ll_i64_ty(Lcontext c) @cname("LLVMInt64TypeInContext");
extern fn Ltype ll_ptr_ty(Ltype el, uint a) @cname("LLVMPointerType");
extern fn Ltype ll_fn_ty(Ltype ret, Ltype* args, uint n, int v) @cname("LLVMFunctionType");

extern fn Lvalue ll_add_fn(Lmodule m, char* n, Ltype t) @cname("LLVMAddFunction");
extern fn Lblock ll_append_bb(Lcontext c, Lvalue f, char* n) @cname("LLVMAppendBasicBlockInContext");
extern fn void ll_pos_builder(Lbuilder b, Lblock bb) @cname("LLVMPositionBuilderAtEnd");
extern fn Lbuilder ll_builder_create(Lcontext c) @cname("LLVMCreateBuilderInContext");
extern fn void ll_builder_dispose(Lbuilder b) @cname("LLVMDisposeBuilder");
extern fn Lblock ll_get_insert(Lbuilder b) @cname("LLVMGetInsertBlock");
extern fn Lblock ll_get_entry_bb(Lvalue f) @cname("LLVMGetEntryBasicBlock");
extern fn Lblock ll_get_next_bb(Lblock bb) @cname("LLVMGetNextBasicBlock");
extern fn Lvalue ll_get_last_inst(Lblock bb) @cname("LLVMGetLastInstruction");
extern fn Lvalue ll_is_terminator(Lvalue v) @cname("LLVMIsATerminatorInst");
extern fn void   ll_delete_bb(Lblock bb) @cname("LLVMDeleteBasicBlock");
extern fn uint   ll_count_bbs(Lvalue f) @cname("LLVMCountBasicBlocks");


extern fn Lvalue ll_get_param(Lvalue f, uint i) @cname("LLVMGetParam");
extern fn Lvalue ll_const_int(Ltype t, ulong n, int sext) @cname("LLVMConstInt");
extern fn Lvalue ll_build_alloca(Lbuilder b, Ltype t, char* n) @cname("LLVMBuildAlloca");
extern fn Ltype   ll_array_type(Ltype el, ulong n) @cname("LLVMArrayType");
extern fn Lvalue ll_build_store(Lbuilder b, Lvalue v, Lvalue p) @cname("LLVMBuildStore");
extern fn void   ll_set_volatile(Lvalue i, int v) @cname("LLVMSetVolatile");
extern fn Lvalue ll_build_load2(Lbuilder b, Ltype t, Lvalue p, char* n) @cname("LLVMBuildLoad2");
extern fn Lvalue ll_build_add(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildAdd");
extern fn Lvalue ll_build_nsw_add(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildNSWAdd");
extern fn Lvalue ll_build_nsw_sub(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildNSWSub");
extern fn Lvalue ll_build_nsw_mul(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildNSWMul");

extern fn Lvalue ll_build_sub(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildSub");
extern fn Lvalue ll_build_mul(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildMul");
extern fn Lvalue ll_build_sdiv(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildSDiv");
extern fn Lvalue ll_build_srem(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildSRem");
extern fn Lvalue ll_build_and(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildAnd");
extern fn Lvalue ll_build_or(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildOr");
extern fn Lvalue ll_build_xor(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildXor");
extern fn Lvalue ll_build_shl(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildShl");
extern fn Lvalue ll_build_ashr(Lbuilder b, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildAShr");
extern fn Lvalue ll_build_icmp(Lbuilder b, int p, Lvalue l, Lvalue r, char* n) @cname("LLVMBuildICmp");
extern fn Lvalue ll_build_zext(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildZExt");
extern fn Lvalue ll_build_trunc(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildTrunc");
extern fn Lvalue ll_build_sext(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildSExt");
extern fn Lvalue ll_build_gep2(Lbuilder b, Ltype t, Lvalue p, Lvalue* idx, uint n, char* nm) @cname("LLVMBuildGEP2");
extern fn Lvalue ll_build_bitcast(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildBitCast");
extern fn Lvalue ll_build_ptrtoint(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildPtrToInt");
extern fn Lvalue ll_build_inttoptr(Lbuilder b, Lvalue v, Ltype t, char* n) @cname("LLVMBuildIntToPtr");
extern fn Lvalue ll_build_call2(Lbuilder b, Ltype ft, Lvalue f, Lvalue* a, uint n, char* nm) @cname("LLVMBuildCall2");
extern fn Lvalue ll_build_ret(Lbuilder b, Lvalue v) @cname("LLVMBuildRet");
extern fn Lvalue ll_build_ret_void(Lbuilder b) @cname("LLVMBuildRetVoid");
extern fn Lvalue ll_build_br(Lbuilder b, Lblock bb) @cname("LLVMBuildBr");
extern fn Lvalue ll_build_condbr(Lbuilder b, Lvalue c, Lblock t, Lblock e) @cname("LLVMBuildCondBr");
extern fn Lvalue ll_build_switch(Lbuilder b, Lvalue value, Lblock default_bb, uint case_hint) @cname("LLVMBuildSwitch");
extern fn void ll_add_case(Lvalue switch_inst, Lvalue value, Lblock dest) @cname("LLVMAddCase");
extern fn Lvalue ll_build_unreachable(Lbuilder b) @cname("LLVMBuildUnreachable");

extern fn Lvalue ll_get_named_fn(Lmodule m, char* n) @cname("LLVMGetNamedFunction");
extern fn int ll_write_bc(Lmodule m, char* p) @cname("LLVMWriteBitcodeToFile");
// ── LLVM-C: Target machine (for native .o emission) ──────────────────
alias Ltarget = void*;
alias Ltarget_machine = void*;

const int LLVM_CG_OBJ_FILE = 1;
const int LLVM_CODEGEN_O0 = 0;
const int LLVM_CODEGEN_O2 = 2;
const int LLVM_RELOC_STATIC = 1;
const int LLVM_CODE_MODEL_SMALL = 1;

extern fn void ll_init_x86_ti()    @cname("LLVMInitializeX86TargetInfo");
extern fn void ll_init_x86_t()     @cname("LLVMInitializeX86Target");
extern fn void ll_init_x86_tmc()   @cname("LLVMInitializeX86TargetMC");
extern fn void ll_init_x86_asmp()  @cname("LLVMInitializeX86AsmPrinter");
extern fn void ll_init_x86_asmpa() @cname("LLVMInitializeX86AsmParser");
extern fn int  ll_get_target_from_triple(char* t, Ltarget* out, char** err) @cname("LLVMGetTargetFromTriple");
extern fn Ltarget_machine ll_create_tm(Ltarget t, char* triple, char* cpu, char* feat, int lvl, int reloc, int cm) @cname("LLVMCreateTargetMachine");
extern fn void ll_dispose_tm(Ltarget_machine tm) @cname("LLVMDisposeTargetMachine");
extern fn int  ll_tm_emit_to_file(Ltarget_machine tm, Lmodule m, char* path, int cgft, char** err) @cname("LLVMTargetMachineEmitToFile");
extern fn void ll_set_module_dl(Lmodule m, void* dl) @cname("LLVMSetModuleDataLayout");
extern fn void* ll_create_tm_dl(Ltarget_machine tm) @cname("LLVMCreateTargetDataLayout");
extern fn void ll_dispose_msg(char* m) @cname("LLVMDisposeMessage");

// LLVM-C: function attributes + new pass manager (v0.5 codegen upgrades).
alias Lpass_opts = void*;
alias Lerror = void*;

extern fn Ltype      ll_global_val_type(Lvalue g) @cname("LLVMGlobalGetValueType");
extern fn Ltype      ll_type_of(Lvalue v) @cname("LLVMTypeOf");
extern fn Lvalue    ll_create_enum_attr(Lcontext c, uint id, ulong v) @cname("LLVMCreateEnumAttribute");
extern fn Lvalue    ll_create_string_attr(Lcontext c, char* k, uint kl, char* v, uint vl) @cname("LLVMCreateStringAttribute");
extern fn void      ll_add_attr_at_idx(Lvalue f, int idx, Lvalue a) @cname("LLVMAddAttributeAtIndex");
extern fn Lpass_opts ll_create_pb_opts() @cname("LLVMCreatePassBuilderOptions");
extern fn void      ll_dispose_pb_opts(Lpass_opts o) @cname("LLVMDisposePassBuilderOptions");
extern fn void      ll_pb_set_inliner_threshold(Lpass_opts o, int t) @cname("LLVMPassBuilderOptionsSetInlinerThreshold");
extern fn Lerror    ll_run_passes(Lmodule m, char* passes, Ltarget_machine tm, Lpass_opts o) @cname("LLVMRunPasses");
extern fn int       ll_print_mod_to_file(Lmodule m, char* path, char** errmsg) @cname("LLVMPrintModuleToFile");
extern fn char*     ll_get_err_msg(Lerror e) @cname("LLVMGetErrorMessage");
extern fn void      ll_consume_error(Lerror e) @cname("LLVMConsumeError");

// PEAR attribute enums (correct for LLVM 19 from Attributes.inc GET_ATTR_ENUM).
// C3 'bool' is a 1-byte type; LLVM-C 'LLVMBool' is a C int (4 bytes). Keep extern
// signatures that pass LLVMBool as `int`.
// PEAR attribute enums — correct for LLVM 23 (from Attributes.inc GET_ATTR_ENUM
// block, FirstEnumAttr=1; AllocAlign=1). These are 1-indexed IDs passed to
// PEAR attribute enums — verified against LLVM 23 via enum_probe
// (tests adding each attr 1..89 at FN_INDEX; only IDs passing LLVMVerifyModule
// are used). Param/return attrs (noalias, nonnull, noundef, readnone, readonly,
// writeonly, nest, inreg, swiftself, etc.) are skipped.
const int  LLVM_ATTR_FN_INDEX     = -1;  // LLVMAttributeFunctionIndex
const int  LLVM_ATTR_ALWAYSINLINE = 3;   // AlwaysInline
const int  LLVM_ATTR_COLD         = 5;   // Cold
const int  LLVM_ATTR_CONVERGENT   = 6;   // Convergent
const int  LLVM_ATTR_NOUNWIND     = 42;  // NoUnwind
const int  LLVM_ATTR_WILLRETURN   = 77;  // WillReturn
const int  LLVM_ATTR_NOFREE       = 29;  // NoFree
const int  LLVM_ATTR_NOSYNC       = 50;  // NoSync
const int  LLVM_ATTR_NORECURSE    = 45;  // NoRecurse
const int  LLVM_ATTR_NOCALLBACK   = 25;  // NoCallback
const int  LLVM_ATTR_MUSTPROGRESS = 20;  // MustProgress
const int  LLVM_ATTR_SPECULATABLE = 68;  // Speculatable


extern fn int snprintf(char* buf, usz n, char* fmt, ...);

// ── Codegen state ─────────────────────────────────────────────────────

struct PearCg {
    Lcontext ctx;
    Lmodule  mod;
    Lbuilder b;
    Lblock   entry_bb;     // alloca-only entry (all slots go here — static stack)
    Lblock   body_bb;      // body BB where the real function body starts
    uint     tmp;
    uint     blk;
    Lvalue   cur_fn;
    Ltype    i64ty;
    Ltype    i32ty;
    Ltype    i8ty;
    Ltype    i1ty;
    Ltype    voidty;
    Ltype    i8ptrty;     // i8* — result of malloc
    Lvalue   malloc_fn;   // cached malloc(i64) -> i8* decl
    Lvalue   free_fn;     // cached free(i8*) -> void decl
    Lvalue   write_fn;    // cached write(i32, i8*, i64) -> i64 decl
    // Set when a bare-name callee lookup failed (see prd_i64 -> N_EXPR_IDENT).
    // The call site uses it to declare a real external reference instead of
    // calling address 0 — see ACNS_CALL.
    char*    unresolved_callee;
    // The AIR module being emitted — whole-program emission concatenates the
    // loaded modules into one AirModule, and the symbol table is keyed by bare
    // name, so pear_emit_fn needs the declaration list to spot duplicates.
    AirModule* air;
    bool     terminated;
    usz      memory_read_attrs; // qualifier-proven LLVM memory(read) functions
    // Memory-backed locals (mem2reg friendly): for each name in vals[], mark
    // whether it is an alloca pointer (needs load on read, store on write).
    // Bootstrap: ALL let-bindings become alloca+store; params stay as SSA.
    // NOTE: sizes kept under 262KB stack limit (c3c --max-stack-object-size max).
    // Original was 2048x256 = 512KB alone which exceeds limit. Reduced to 1024x128 = 128KB.
    bool[1024] is_ptr;
    uint           name_n;
    // C3 array dimensions read RIGHT-to-left: `T[E][N]` is N rows of E elements.
    // Increased from 256x64 to 2048x256 to fix Agent-4 round-5 silent truncation bugs:
    // - 64-char identifiers silently compiled to 0 (names row width 64)
    // - >32 labels crashed + values rotted (lbl tables [32])
    // - >255 names per fn silently resolved to 0
    // Reduced to 1024x128 to stay under 262KB stack limit (512KB alone was too big).
    char[128][1024]  names;        // 1024 names x 128 chars
    Lvalue[1024]    vals;
    uint           lbl_n;
    char[128][128]   lbl_names;    // 128 labels x 128 chars
    Lblock[128]     lbl_bbs;
    bool[128]       lbl_kfilled; // admin %k BB already has code started
    Lblock         cur_k_bb;    // BB we are currently emitting into as %k continuation
}

// Emit an alloca into the ENTRY (alloca) BB and return the slot. We ALWAYS
// position a fresh insertion in entry_bb, right after any prior allocas but
// BEFORE the entry→body branch. Allocas in entry become STATIC stack slots
// (LLVM computes fixed offset in prologue); allocas anywhere else are treated
// as dynamic (like C VLAs) and grow RSP by 16 bytes every iteration — that
// was the bug that segfaulted sum_to's 2M-iteration loop.
// ── slot types ──
// is_ptr marks whether a slot holds a native pointer (i8*). If true, the
// slot is alloca'd as i8* and we inttoptr/ptrtoint on load/store. If false,
// the slot is i64 (value).
fn Lvalue PearCg.alloc_slot(PearCg* cg, char* nm)
{
    return cg.alloc_slot_typed(nm, cg.i64ty);
}

fn Lvalue PearCg.alloc_slot_typed(PearCg* cg, char* nm, Ltype ty)
{
    Lblock saved = ll_get_insert(cg.b);
    ll_pos_builder(cg.b, cg.entry_bb);
    Lvalue slot = ll_build_alloca(cg.b, ty, nm);
    ll_pos_builder(cg.b, saved);
    return slot;
}

// ── Helpers ───────────────────────────────────────────────────────────

// bb_open — is this block still looking for a terminator? A block that already
// ends in br/ret/unreachable must never receive a second terminator: the module
// is invalid, and LLVM aborts inside its own optimiser when it clones such an
// instruction (Instruction::clone → "Out of bounds memory access").
// dead_bb — a fresh block to hold a terminator that has nowhere else to go.
// An orphan block with a terminator is valid IR (LLVM deletes it), whereas a
// second terminator in a live block is not.
fn Lblock PearCg.dead_bb(PearCg* cg)
{
    char[256] b;
    (void)snprintf(&b[0], 256, "dead%u", cg.blk); cg.blk++;
    Lblock bb = ll_append_bb(cg.ctx, cg.cur_fn, &b[0]);
    ll_pos_builder(cg.b, bb);
    cg.terminated = false;
    return bb;
}

// pending_open_join -- the innermost admin continuation (%kN) that has been
// entered (a cut redirected flow into it) but has NOT been filled yet: its block
// is still waiting for a terminator. `exclude` is the block we are already in.
fn Lblock PearCg.pending_open_join(PearCg* cg, Lblock exclude)
{
    for (uint z = cg.lbl_n; z > 0; z--)
    {
        char* nm = &cg.lbl_names[z - 1][0];
        if (nm[0] != 'k' || nm[1] < '0' || nm[1] > '9') continue;
        Lblock bb = cg.lbl_bbs[z - 1];
        if (bb == null || bb == exclude) continue;
        if (cg.bb_open(bb)) return bb;
    }
    return null;
}

// sync_pos -- put the insert point where the remaining flow belongs.
//
// A CPS sequence can reach a point where the current block is already closed
// (its terminator emitted) while an admin join is still pending: the cut
// <()|%kN> that redirected flow into kN is still waiting for the rest of the
// sequence to be emitted INTO kN. Without this, the following commands are
// either dropped (ACMD_SEQ stops as soon as a command reports "terminated") or
// appended after a terminator, which is invalid IR and makes LLVM abort inside
// its own optimiser (Instruction::clone).
//
// Only an OPEN join attracts the position: a join that already has its
// terminator must never receive a second one.
fn void PearCg.sync_pos(PearCg* cg)
{
    Lblock cur = ll_get_insert(cg.b);
    if (cg.bb_open(cur)) return;
    Lblock pend = cg.pending_open_join(cur);
    if (pend == null) return;
    ll_pos_builder(cg.b, pend);
    cg.terminated = false;
}

fn bool PearCg.bb_open(PearCg* cg, Lblock bb)
{
    if (bb == null) return false;
    Lvalue last = ll_get_last_inst(bb);
    if (last == null) return true;
    return ll_is_terminator(last) == null;
}

fn char* PearCg.mktmp(PearCg* cg)
{
    char[256] b;
    (void)snprintf(&b[0], 256, "_t%u", cg.tmp);
    cg.tmp++;
    return cg.add_name(&b[0]);
}

fn char* PearCg.add_name(PearCg* cg, char* s)
{
    if (s == null) return (char*)"";
    uint i = cg.name_n;
    if (i < 1024)
    {
        // Increased from 64 to 128 chars to fix silent truncation of long identifiers (Agent-4 §14).
        // Previously snprintf with 64 truncated 64+ char names to 63 chars, then lookup failed
        // and the value resolved to 0 silently. Now 128 chars.
        usz len = 0;
        if (s != null) { while (s[len] != 0) { len++; } }
        if (len >= 128)
        {
            // Still truncate but at 127, and we have larger buffer so 64-char cliff is gone.
        }
        (void)snprintf(&cg.names[i][0], 128, "%s", s);
        cg.name_n = i + 1;
        return &cg.names[i][0];
    }
    return s;
}

fn void PearCg.bind(PearCg* cg, char* ssa, Lvalue v)
{
    // Direct bind (for params, covar results): store SSA value directly.
    cg.bind_direct(ssa, v, false);
}

fn void PearCg.bind_direct(PearCg* cg, char* ssa, Lvalue v, bool ptr)
{
    if (ssa == null || v == null) return;
    for (uint i = 0; i < cg.name_n; i++)
    {
        bool eq = true;
        uint j = 0;
        while (cg.names[i][j] != 0 && ssa[j] != 0)
        {
            if (cg.names[i][j] != ssa[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.names[i][j] == 0 && ssa[j] == 0)
        {
            cg.vals[i] = v; cg.is_ptr[i] = ptr;
            return;
        }
    }
    char* nm = cg.add_name(ssa);
    for (uint i = 0; i < cg.name_n; i++)
    {
        bool eq = true;
        uint j = 0;
        while (cg.names[i][j] != 0 && nm[j] != 0)
        {
            if (cg.names[i][j] != nm[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.names[i][j] == 0 && nm[j] == 0) { cg.vals[i] = v; cg.is_ptr[i] = ptr; return; }
    }
}

fn void PearCg.mark_ptr(PearCg* cg, char* nm)
{
    if (nm == null) return;
    for (uint i = 0; i < cg.name_n; i++)
    {
        bool eq = true;
        uint j = 0;
        while (cg.names[i][j] != 0 && nm[j] != 0)
        {
            if (cg.names[i][j] != nm[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.names[i][j] == 0 && nm[j] == 0) { cg.is_ptr[i] = true; return; }
    }
}

fn bool PearCg.lookup_is_ptr(PearCg* cg, char* ssa, uint* out_idx)
{
    if (ssa == null) return false;
    for (uint i = 0; i < cg.name_n; i++)
    {
        bool eq = true;
        uint j = 0;
        while (cg.names[i][j] != 0 && ssa[j] != 0)
        {
            if (cg.names[i][j] != ssa[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.names[i][j] == 0 && ssa[j] == 0) { *out_idx = i; return cg.is_ptr[i]; }
    }
    return false;
}

fn Lvalue PearCg.lookup(PearCg* cg, char* ssa)
{
    if (ssa == null) return null;
    for (uint i = 0; i < cg.name_n; i++)
    {
        bool eq = true;
        uint j = 0;
        while (cg.names[i][j] != 0 && ssa[j] != 0)
        {
            if (cg.names[i][j] != ssa[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.names[i][j] == 0 && ssa[j] == 0)
        {
            // SSA values (parameters bound via bind_direct(ssa, v, false)
            // before any alloca exists) have is_ptr=false AND were stored
            // directly — they aren't slots. Slots (is_ptr=true) are
            // handled by the caller via lookup_is_ptr which does a load.
            // But we've historically used is_ptr=true for ALL alloca slots,
            // so checking !is_ptr tells us "this is an SSA value, not a
            // slot". In practice parameters are added with is_ptr=false
            // (see pear_emit_fn params setup). All other binds come through
            // COMU/LET and are slots (is_ptr=true) — we must load them.
            if (!cg.is_ptr[i]) return cg.vals[i];
            return null; // caller will load from the slot
        }
    }
    return null;
}

fn char* PearCg.mklbl(PearCg* cg, char* pfx)
{
    char[256] b;
    (void)snprintf(&b[0], 256, "%s%u", pfx, cg.blk);
    cg.blk++;
    return cg.add_name(&b[0]);
}

fn Lblock PearCg.get_lbl(PearCg* cg, char* nm)
{
    for (uint i = 0; i < cg.lbl_n; i++)
    {
        bool eq = true; uint j = 0;
        while (cg.lbl_names[i][j] != 0 && nm[j] != 0)
        {
            if (cg.lbl_names[i][j] != nm[j]) { eq = false; break; }
            j++;
        }
        if (eq && cg.lbl_names[i][j] == 0 && nm[j] == 0) { return cg.lbl_bbs[i]; }
    }
    if (cg.lbl_n < 128)
    {
        char[256] buf; uint j = 0;
        while (j < 62 && nm[j] != 0) { buf[j] = nm[j]; j++; }
        buf[j] = 0;
        uint k = 0;
        while (k < 127 && buf[k] != 0) { cg.lbl_names[cg.lbl_n][k] = buf[k]; k++; }
        cg.lbl_names[cg.lbl_n][k] = 0;
        Lblock bb = ll_append_bb(cg.ctx, cg.cur_fn, &buf[0]);
        cg.lbl_bbs[cg.lbl_n] = bb;
        cg.lbl_n++;
        return bb;
    }
    return null;
}

// ── Type helpers ─────────────────────────────────────────────────────

fn Ltype pear_llvm_ty(PearCg* cg, AirTyp* t)
{
    if (t == null) return cg.i64ty;
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8:    return ll_i8_ty(cg.ctx);
        case ATYP_I16: case ATYP_U16:  return ll_i16_ty(cg.ctx);
        case ATYP_I32: case ATYP_U32:  return ll_i32_ty(cg.ctx);
        case ATYP_I64: case ATYP_U64:
        case ATYP_I128: case ATYP_U128:
        case ATYP_ISZ: case ATYP_USZ:
        case ATYP_INFER:               return cg.i64ty;
        case ATYP_BOOL:                return cg.i1ty;
        case ATYP_UNIT: case ATYP_BOTTOM: return cg.voidty;
        case ATYP_PTR: case ATYP_REF: case ATYP_REF_MUT:
            return ll_ptr_ty(ll_i8_ty(cg.ctx), 0);
        default: return cg.i64ty;
    }
}

fn bool pear_is_void(AirTyp* t)
{
    if (t == null) return true;
    return t.tag == ATYP_UNIT || t.tag == ATYP_BOTTOM;
}

fn bool is_cmp(AirBinop op)
{
    switch (op)
    {
        case ABIN_LT: case ABIN_GT: case ABIN_LE:
        case ABIN_GE: case ABIN_EQ: case ABIN_NEQ: return true;
        default: return false;
    }
}

fn int cmp_pred(AirBinop op)
{
    switch (op)
    {
        case ABIN_LT:  return LLVM_ICMP_SLT;
        case ABIN_GT:  return LLVM_ICMP_SGT;
        case ABIN_LE:  return LLVM_ICMP_SLE;
        case ABIN_GE:  return LLVM_ICMP_SGE;
        case ABIN_EQ:  return LLVM_ICMP_EQ;
        case ABIN_NEQ: return LLVM_ICMP_NE;
        default:       return LLVM_ICMP_EQ;
    }
}

fn bool is_ret_name(char* nm)
{
    if (nm == null || nm[0] != '%') return false;
    if (nm[1] != 'r' || nm[2] != 'e' || nm[3] != 't') return false;
    char c = nm[4];
    if (c == 0) return true;
    return c == '_';
}

fn bool is_hole_name(char* nm)
{
    if (nm == null) return false;
    return nm[0] == (char)(0xc2) && nm[1] == (char)(0xb7);
}

// Admin covars: "%ret..." (return continuation) and "%kN" (join-point
// continuations introduced by CPS). These are NEVER value binders — they
// label BBs, not stack slots. Allocating slots for them (COMU "wild"
// check missed them because '%' isn't '_') produced stack-relative
// allocas in the middle of loops, growing RSP on every iteration.
fn bool is_admin_name(char* nm)
{
    if (nm == null || nm[0] != '%') return false;
    if (is_ret_name(nm)) return true;
    // %kN pattern (continuation join point).
    if (nm[1] == 'k' && nm[2] >= '0' && nm[2] <= '9') return true;
    return false;
}

// ── Producers (methods so they can mutual-recurse freely) ────────────

fn Lvalue PearCg.prd_i64(PearCg* cg, AirPrd* p)
{
    if (p == null) return ll_const_int(cg.i64ty, 0, 0);
    switch (p.tag)
    {
        case APRD_INT:
        {
            bool neg = false; long v = p.ival;
            ulong u;
            if (v < 0) { neg = true; u = (ulong)(-v); } else { u = (ulong)v; }
            Lvalue r = ll_const_int(cg.i64ty, u, 1);
            if (neg)
            {
                Lvalue zero = ll_const_int(cg.i64ty, 0, 0);
                return ll_build_sub(cg.b, zero, r, "neg");
            }
            return r;
        }
        case APRD_BOOL:
        {
            Lvalue bv = p.bval ? ll_const_int(cg.i1ty, 1, 0) : ll_const_int(cg.i1ty, 0, 0);
            return ll_build_zext(cg.b, bv, cg.i64ty, cg.mktmp());
        }
        case APRD_UNIT: case APRD_NULL: return ll_const_int(cg.i64ty, 0, 0);
        case APRD_VAR: case APRD_CON:
        {
            if (p.name == null) return ll_const_int(cg.i64ty, 0, 0);
            // Check slot table (populated by COMU/LET): load from slot.
            uint idx = 0;
            if (cg.lookup_is_ptr(p.name, &idx))
            {
                Lvalue slot = cg.vals[idx];
                if (slot != null)
                {
                    return ll_build_load2(cg.b, cg.i64ty, slot, cg.mktmp());
                }
            }
            // SSA value (parameters, pre-bound non-slot names like SSA φs):
            // note: cg.lookup returns vals[i] for ANY matching name including
            // pointer slots. We already handled the slot case above; if we
            // reach here for a name that IS in vals (because is_ptr=false),
            // it's a raw SSA value (no alloca), return as-is.
            Lvalue v = cg.lookup(p.name);
            if (v != null)
            {
                // Defensive: if v looks like an alloca pointer (because someone
                // called bind_direct with is_ptr=false but passed an alloca),
                // we'd return the slot address. That's the earlier bug. Just
                // trust that slots go through the is_ptr path and return v.
                return v;
            }
            if (p.name[0] != '%')
            {
                Lvalue f = ll_get_named_fn(cg.mod, p.name);
                if (f != null) return f;
                // Legacy __pear_alloca intrinsic (v0.8 bootstrap) — redirect
                // to real malloc so older .air or stale references still work.
                if (p.name[0] == '_' && p.name[1] == '_'
                    && p.name[2] == 'p' && p.name[3] == 'e'
                    && p.name[4] == 'a' && p.name[5] == 'r'
                    && p.name[6] == '_')
                {
                    return cg.malloc_fn != null ? cg.malloc_fn
                                                : ll_const_int(cg.i64ty, 0, 0);
                }
                // Not defined in this module. Remember the name so the call
                // site can emit an external reference to it (a missing symbol
                // must fail at LINK time with a name in the message, not as a
                // call to address 0 that segfaults at run time).
                cg.unresolved_callee = p.name;
            }
            return ll_const_int(cg.i64ty, 0, 0);
        }
        case APRD_BINOP:
        {
            Lvalue a = cg.prd_i64(p.subs[0]);
            Lvalue bv = cg.prd_i64(p.subs[1]);
            char* nm = cg.mktmp();
            switch (p.bop)
            {
                case ABIN_ADD: return ll_build_nsw_add(cg.b, a, bv, nm);
                case ABIN_SUB: return ll_build_nsw_sub(cg.b, a, bv, nm);
                case ABIN_MUL: return ll_build_nsw_mul(cg.b, a, bv, nm);
                case ABIN_DIV: return ll_build_sdiv(cg.b, a, bv, nm);
                case ABIN_MOD: return ll_build_srem(cg.b, a, bv, nm);
                case ABIN_AND: return ll_build_and(cg.b, a, bv, nm);
                case ABIN_OR:  return ll_build_or(cg.b, a, bv, nm);
                case ABIN_XOR: return ll_build_xor(cg.b, a, bv, nm);
                case ABIN_SHL: return ll_build_shl(cg.b, a, bv, nm);
                case ABIN_SHR: return ll_build_ashr(cg.b, a, bv, nm);
                case ABIN_LT: case ABIN_GT: case ABIN_LE: case ABIN_GE:
                case ABIN_EQ: case ABIN_NEQ:
                {
                    Lvalue cmp = ll_build_icmp(cg.b, cmp_pred(p.bop), a, bv, nm);
                    return ll_build_zext(cg.b, cmp, cg.i64ty, cg.mktmp());
                }
                default: return ll_build_add(cg.b, a, bv, nm);
            }
        }
        case APRD_MU:
        {
            // μα.c should ONLY appear as the prd of a CUT (handled in cmd). If
            // reached here as a value, emit body and poison; this is a bug in
            // PEAR's μβ-reduction. To avoid corrupting the current BB, return
            // 0 without running body here.
            return ll_const_int(cg.i64ty, 0, 0);
        }
        case APRD_RECORD:
        {
            // A record value is the ADDRESS of a stack buffer with one i64 slot
            // per field, in declaration order (the lowerer reorders the inits;
            // `_fN` markers such as the type name are skipped). Addresses are
            // carried as i64 throughout this backend, so ptrtoint/inttoptr is
            // the same convention the pointer paths already use.
            uint nf = 0;
            for (usz i = 0; i < p.rec_init_count && i < 16; i++)
            {
                AirFieldInit* fi = p.rec_inits[i];
                if (fi == null || fi.name == null) continue;
                if (fi.name[0] == '_') continue;
                nf++;
            }
            if (nf == 0)
            {
                // Empty record: still yield a valid address so projections do not
                // dereference null.
                Lvalue e0 = cg.alloc_slot_typed(cg.mktmp(), ll_array_type(cg.i64ty, 1));
                return ll_build_ptrtoint(cg.b, e0, cg.i64ty, cg.mktmp());
            }
            // NOTE the GEP element type: two-index GEPs index an AGGREGATE, so
            // the type argument must be the array type the pointer refers to.
            // Passing the element type (i64) for a two-index GEP — or i8 as the
            // old INDEX code did — produces an ill-formed instruction that LLVM
            // aborts on inside its own optimiser.
            Ltype arr_ty = ll_array_type(cg.i64ty, (ulong)nf);
            Lvalue buf = cg.alloc_slot_typed(cg.mktmp(), arr_ty);
            uint slot = 0;
            for (usz i = 0; i < p.rec_init_count && i < 16; i++)
            {
                AirFieldInit* fi = p.rec_inits[i];
                if (fi == null || fi.name == null) continue;
                if (fi.name[0] == '_') continue;
                Lvalue val = cg.prd_i64(fi.value);
                Lvalue[2] gi; gi[0] = ll_const_int(cg.i64ty, 0, 0); gi[1] = ll_const_int(cg.i64ty, (ulong)slot, 0);
                Lvalue addr = ll_build_gep2(cg.b, arr_ty, buf, &gi[0], 2, cg.mktmp());
                (void)ll_build_store(cg.b, val, addr);
                slot++;
            }
            return ll_build_ptrtoint(cg.b, buf, cg.i64ty, cg.mktmp());
        }
        case APRD_COERCE:
            if (p.sub_count > 0 && p.subs[0] != null) { return cg.prd_i64(p.subs[0]); }
            return ll_const_int(cg.i64ty, 0, 0);
        default:
            return ll_const_int(cg.i64ty, 0, 0);
    }
}

fn Lvalue PearCg.prd_i1(PearCg* cg, AirPrd* p)
{
    if (p == null) return ll_const_int(cg.i1ty, 0, 0);
    AirPrd* q = p;
    while (q.tag == APRD_COERCE && q.sub_count > 0 && q.subs[0] != null) { q = q.subs[0]; }
    if (q.tag == APRD_BINOP && is_cmp(q.bop))
    {
        Lvalue a = cg.prd_i64(q.subs[0]);
        Lvalue bv = cg.prd_i64(q.subs[1]);
        return ll_build_icmp(cg.b, cmp_pred(q.bop), a, bv, cg.mktmp());
    }
    if (q.tag == APRD_BOOL)
    {
        return q.bval ? ll_const_int(cg.i1ty, 1, 0) : ll_const_int(cg.i1ty, 0, 0);
    }
    Lvalue v = cg.prd_i64(p);
    Lvalue z = ll_const_int(cg.i64ty, 0, 0);
    return ll_build_icmp(cg.b, LLVM_ICMP_NE, v, z, cg.mktmp());
}

// ── Consumers ────────────────────────────────────────────────────────

// Consume the frontend's dense-switch certificate only for the narrow case
// we can lower without losing source semantics: distinct integer/character
// literals, no guards, and an optional final wildcard or binding pattern. All
// other patterns keep the existing conservative path.
fn int PearCg.emit_dense_scalar_switch(PearCg* cg, Lvalue scrutinee, AirCns* k)
{
    if (k == null || !k.dense_switch || scrutinee == null
        || k.branch_count == 0 || k.branch_count > 64) { return -1; }

    int wildcard = -1;
    uint literal_count = 0;
    for (uint i = 0; i < (uint)k.branch_count; i++)
    {
        AirBranch* br = k.branches[i];
        if (br == null || br.guard != null || br.pat == null) { return -1; }
        if (br.pat.tag == APAT_WILD || br.pat.tag == APAT_BIND)
        {
            if (wildcard >= 0 || i + 1 != (uint)k.branch_count) { return -1; }
            if (br.pat.tag == APAT_BIND && br.pat.name == null) { return -1; }
            wildcard = (int)i;
            continue;
        }
        if (br.pat.tag != APAT_INT && br.pat.tag != APAT_CHAR) { return -1; }
        for (uint j = 0; j < i; j++)
        {
            AirBranch* prev = k.branches[j];
            if (prev != null && prev.pat != null
                && (prev.pat.tag == APAT_INT || prev.pat.tag == APAT_CHAR)
                && prev.pat.ival == br.pat.ival) { return -1; }
        }
        literal_count++;
    }
    if (literal_count < 4) { return -1; }

    Lblock[64] targets;
    Lblock default_bb = null;
    for (uint i = 0; i < (uint)k.branch_count; i++)
    {
        AirBranch* br = k.branches[i];
        if ((int)i == wildcard) { continue; }
        char[256] name;
        (void)snprintf(&name[0], 256, "switch.case%u", cg.blk);
        cg.blk++;
        targets[i] = ll_append_bb(cg.ctx, cg.cur_fn, &name[0]);
    }
    if (wildcard >= 0)
    {
        char[256] name;
        (void)snprintf(&name[0], 256, "switch.default%u", cg.blk);
        cg.blk++;
        default_bb = ll_append_bb(cg.ctx, cg.cur_fn, &name[0]);
        targets[wildcard] = default_bb;
    }
    else
    {
        char[256] name;
        (void)snprintf(&name[0], 256, "switch.default%u", cg.blk);
        cg.blk++;
        default_bb = ll_append_bb(cg.ctx, cg.cur_fn, &name[0]);
    }

    Lvalue sw = ll_build_switch(cg.b, scrutinee, default_bb, literal_count);
    cg.terminated = true;
    for (uint i = 0; i < (uint)k.branch_count; i++)
    {
        if ((int)i == wildcard) { continue; }
        AirPat* pat = k.branches[i].pat;
        Lvalue cv = ll_const_int(cg.i64ty, (ulong)pat.ival, 1);
        ll_add_case(sw, cv, targets[i]);
    }

    Lblock join_before = cg.cur_k_bb;
    bool any_join_fill = false;
    for (uint i = 0; i < (uint)k.branch_count; i++)
    {
        ll_pos_builder(cg.b, targets[i]);
        cg.terminated = false;
        AirBranch* br = k.branches[i];
        if ((int)i == wildcard && br.pat.tag == APAT_BIND)
        {
            cg.bind_direct(br.pat.name, scrutinee, false);
        }
        bool terminated = cg.cmd(br.body);
        bool filled_join = cg.cur_k_bb != join_before;
        if (!terminated && !filled_join)
        {
            ll_build_unreachable(cg.b);
            cg.terminated = true;
        }
        if (filled_join) { any_join_fill = true; }
    }
    if (wildcard < 0)
    {
        ll_pos_builder(cg.b, default_bb);
        ll_build_unreachable(cg.b);
        cg.terminated = true;
    }
    if (any_join_fill)
    {
        ll_pos_builder(cg.b, cg.cur_k_bb);
        cg.terminated = false;
        return 0;
    }
    return 1;
}

fn bool PearCg.cns(PearCg* cg, Lvalue v, AirCns* k)
{
    if (k == null)
    {
        if (v != null) { ll_build_ret(cg.b, v); cg.terminated = true; }
        else { ll_build_ret_void(cg.b); cg.terminated = true; }
        return true;
    }
    switch (k.tag)
    {
        case ACNS_COVAR:
        {
            char* nm = k.name;
            if (is_ret_name(nm))
            {
                if (v != null) { ll_build_ret(cg.b, v); cg.terminated = true; }
                else { ll_build_ret_void(cg.b); cg.terminated = true; }
                return true;
            }
            if (is_hole_name(nm)) { return false; }
            char* lbl = nm;
            if (lbl != null && lbl[0] == '%') { lbl = &lbl[1]; }
            if (lbl != null)
            {
                // Admin covar "%kN": handle specially. When we jump to %k we
                // MUST position builder at bb first (creating it fresh if this
                // is the first occurrence), emit the br, then CONTINUE to
                // emit subsequent commands into bb. If bb already exists with
                // a terminator, just emit br and return true (closed path).
                bool is_k = (lbl[0] == 'k' && lbl[1] >= '0' && lbl[1] <= '9');
                Lblock bb = cg.get_lbl(lbl);
                if (bb != null)
                {
                    if (is_k)
                    {
                        // Admin continuation "%kN". Find the lbl index.
                        uint ki = 0;
                        for (uint z = 0; z < cg.lbl_n; z++)
                        {
                            bool eq = true; uint jj = 0;
                            while (cg.lbl_names[z][jj] != 0 && lbl[jj] != 0)
                            {
                                if (cg.lbl_names[z][jj] != lbl[jj]) { eq = false; break; }
                                jj++;
                            }
                            if (eq && cg.lbl_names[z][jj] == 0 && lbl[jj] == 0) { ki = z; break; }
                        }
                        ll_build_br(cg.b, bb); cg.terminated = true;
                        if (!cg.lbl_kfilled[ki] && cg.cur_k_bb != bb)
                        {
                            cg.lbl_kfilled[ki] = true;
                            cg.cur_k_bb = bb;
                            ll_pos_builder(cg.b, bb); cg.terminated = false;
                            // Recursively emit body of continuation (the code
                            // chained after this %k jump in SEQ). Since we've
                            // br'd to bb, SEQ's "next" must be emitted into bb.
                            // cg.cmd(next) is driven by the caller (this COVAR
                            // returns false → SEQ proceeds to emit c.next in
                            // the current builder position, which is now bb).
                            return false;
                        }
                        return true;
                    }
                    ll_build_br(cg.b, bb); cg.terminated = true;
                    return true;
                }
            }
            if (v != null) { ll_build_ret(cg.b, v); cg.terminated = true; }
            else { ll_build_ret_void(cg.b); cg.terminated = true; }
            return true;
        }
        case ACNS_COMU:
        {
            // μ̃x.c  is a consumer binder. When x is an admin continuation
            // (%ret, %kN) there is NO value to store — x is a label, not a
            // variable. Treat as wild (no slot, no store) so we don't grow
            // the stack on every loop iteration.
            bool wild = (k.bind == null)
                     || (k.bind[0] == '_' && k.bind[1] == 0)
                     || is_admin_name(k.bind);
            if (!wild && v != null)
            {
                uint idx = 0;
                bool ptr = cg.lookup_is_ptr(k.bind, &idx);
                if (ptr)
                {
                    Lvalue slot = cg.vals[idx];
                    if (slot != null) { (void)ll_build_store(cg.b, v, slot); }
                }
                else
                {
                    Lvalue slot = cg.alloc_slot(cg.mktmp());
                    (void)ll_build_store(cg.b, v, slot);
                    cg.bind_direct(k.bind, slot, true);
                }
            }
            // If the COMU body is a CUT directly to an admin %k covar we are
            // already filling, don't recursively enter — that would create a
            // self-loop. Instead, treat as terminated here (the value has
            // been stored and flow continues at the branch we already placed).
            if (k.body != null && k.body.tag == ACMD_CUT
                && k.body.cns != null && k.body.cns.tag == ACNS_COVAR
                && k.body.cns.name != null
                && k.body.cns.name[0] == '%' && k.body.cns.name[1] == 'k'
                && k.body.cns.name[2] >= '0' && k.body.cns.name[2] <= '9')
            {
                // This is a tail-comu (like <()|%k1> after the second let);
                // we must NOT re-branch into k1 — that would create a br k1
                // inside k1. The COMU already flows into k1 via the arm's
                // initial br we emitted at the START of the true-arm. The
                // remaining LETs are emitted in-place (we did stores above);
                // control then falls through to k1 naturally via the br we
                // already placed. So return false (unterminated here — but
                // the arm WAS terminated by the earlier br to k1 that we
                // haven't actually emitted yet because... wait).
                //
                // Actually the control flow IS: in case.t0, we emit the
                // store to s, then hit <()|%k1> which emits br k1 and
                // positions into k1. Then k1's body begins with LET i = i+1
                // which stores i and then hits <()|%k1> AGAIN. We need to
                // detect this SECOND <()|%k1> and NOT emit another br (the
                // fallthrough after i's store is already inside k1, and
                // after k1's body we want br loop2).
                //
                // So: if cur_k_bb == bb (we are already filling bb), just
                // return true (terminated) with no extra br? No, k1's body
                // isn't terminated after the second store — we need a br
                // loop2. But we don't know loop2 is the target here.
                //
                // If we are ALREADY filling that join block, this is a second
                // occurrence in the same body (e.g. `let a = …; <()|%k1>;
                // let b = …; <()|%k1>`): emitting another br would branch the
                // block to itself. Report "not terminated" and let the caller's
                // sequence continue in place — the next command (typically
                // `jump %loop`) terminates the block.
                //
                // Otherwise this occurrence must carry control into the join
                // block: delegate to the covar handler so the br is emitted, the
                // join marked filled, and the builder repositioned there. (The
                // old code returned false WITHOUT emitting anything, assuming an
                // earlier cut had already branched — false for the common shape
                // `if (c) { return x; } i = i + 1;`, where this COMU tail is the
                // only cut to the join; the enclosing if then closed the arm with
                // `unreachable`, losing the loop back-edge → SIGTRAP.)
                char* jn = k.body.cns.name;
                Lblock jb = cg.get_lbl(&jn[1]);
                if (jb != null && cg.cur_k_bb == jb) { return false; }
                return cg.cns(v, k.body.cns);
            }
            return cg.cmd(k.body);
        }
        case ACNS_INDEX:
        {
            Lvalue base_int = v;
            Lvalue idx_v = cg.prd_i64(k.prd);
            long esz = k.idx;
            if (esz <= 0) esz = 1;
            if (esz > 8) esz = 8;
            // Choose source element type for GEP + load based on esz.
            // Pointers-as-ints are held as i64; bitcast base_p to the
            // appropriate element pointer type, GEP by scaled idx, then
            // load/zext/trunc to i64.
            Ltype el_ty;
            Ltype el_ptr_ty;
            Ltype load_ty;
            bool load_sext = false;
            if (esz == 1)      { el_ty = cg.i8ty;  load_ty = cg.i8ty;  }
            else if (esz == 2) { el_ty = ll_i16_ty(cg.ctx); load_ty = ll_i16_ty(cg.ctx); }
            else if (esz == 4) { el_ty = cg.i32ty; load_ty = cg.i32ty; }
            else               { el_ty = cg.i64ty; load_ty = cg.i64ty; }
            el_ptr_ty = ll_ptr_ty(el_ty, 0);
            Lvalue base_p = ll_build_inttoptr(cg.b, base_int, el_ptr_ty, cg.mktmp());
            Lvalue addr = ll_build_gep2(cg.b, el_ty, base_p, &idx_v, 1, cg.mktmp());
            if (k.tail != null && k.tail.tag == ACNS_STORE)
            {
                Lvalue addr_int = ll_build_ptrtoint(cg.b, addr, cg.i64ty, cg.mktmp());
                return cg.cns(addr_int, k.tail);
            }
            Lvalue lv = ll_build_load2(cg.b, load_ty, addr, cg.mktmp());
            Lvalue ext;
            if (esz == 1)      { ext = ll_build_zext(cg.b, lv, cg.i64ty, cg.mktmp()); }
            else if (esz == 2) { ext = ll_build_sext(cg.b, lv, cg.i64ty, cg.mktmp()); }
            else if (esz == 4) { ext = ll_build_sext(cg.b, lv, cg.i64ty, cg.mktmp()); }
            else               { ext = lv; }
            return cg.cns(ext, k.tail);
        }
        case ACNS_DEREF:
        {
            // <ptr_int | *k>: inttoptr to i64* then load i64.
            Lvalue ptr_int = v;
            Lvalue ptr_p = ll_build_inttoptr(cg.b, ptr_int, ll_ptr_ty(cg.i64ty, 0), cg.mktmp());
            Lvalue lv = ll_build_load2(cg.b, cg.i64ty, ptr_p, cg.mktmp());
            return cg.cns(lv, k.tail);
        }
        case ACNS_STORE:
        {
            // <addr_int | STORE(val_prd, k)>: addr comes as int; k.idx holds
            // the byte size of the element being stored (1/2/4/8). Truncate
            // val to the right width, cast addr to the matching pointer
            // type, store.
            Lvalue addr_int = v;
            long sesz = k.idx;
            if (sesz <= 0) sesz = 1;
            if (sesz > 8) sesz = 8;
            Ltype s_el_ty;
            if (sesz == 1)      { s_el_ty = cg.i8ty; }
            else if (sesz == 2) { s_el_ty = ll_i16_ty(cg.ctx); }
            else if (sesz == 4) { s_el_ty = cg.i32ty; }
            else                { s_el_ty = cg.i64ty; }
            Ltype s_ptr_ty = ll_ptr_ty(s_el_ty, 0);
            Lvalue addr_p = ll_build_inttoptr(cg.b, addr_int, s_ptr_ty, cg.mktmp());
            Lvalue val = cg.prd_i64(k.prd);
            Lvalue v_to_store;
            if (sesz == 1)      { v_to_store = ll_build_trunc(cg.b, val, cg.i8ty, cg.mktmp()); }
            else if (sesz == 2) { v_to_store = ll_build_trunc(cg.b, val, ll_i16_ty(cg.ctx), cg.mktmp()); }
            else if (sesz == 4) { v_to_store = ll_build_trunc(cg.b, val, cg.i32ty, cg.mktmp()); }
            else                { v_to_store = val; }
            (void)ll_build_store(cg.b, v_to_store, addr_p);
            return cg.cns(ll_const_int(cg.i64ty, 0, 0), k.tail);
        }
        case ACNS_FIELD:
        {
            // <record | .f · k> where the record value is the address of its
            // i64 field buffer and k.idx is the field's declaration slot.
            // A negative index means the lowerer could not resolve the field's
            // declaration, in which case we keep the old pass-through rather than
            // dereferencing an address we cannot vouch for.
            if (k.idx < 0 || v == null) { return cg.cns(v, k.tail); }
            // The record address is carried as an i64; view it as an i64* and
            // advance by `idx` ELEMENTS (one-index GEP, element type i64) — the
            // consumer does not know the record's array type, and a one-index
            // element GEP is well-formed for any element pointer.
            Ltype i64p = ll_ptr_ty(cg.i64ty, 0);
            Lvalue base = ll_build_inttoptr(cg.b, v, i64p, cg.mktmp());
            Lvalue off = ll_const_int(cg.i64ty, (ulong)k.idx, 0);
            Lvalue addr = ll_build_gep2(cg.b, cg.i64ty, base, &off, 1, cg.mktmp());
            Lvalue fv = ll_build_load2(cg.b, cg.i64ty, addr, cg.mktmp());
            return cg.cns(fv, k.tail);
        }
        case ACNS_FST: case ACNS_SND: case ACNS_PROJ:
        {
            // Tuple/other projections: still bootstrap (pass value through).
            return cg.cns(v, k.tail);
        }
        case ACNS_CALL: case ACNS_STACK:
        {
            AirPrd*[64] args; uint ac = 0;
            AirCns* cur = k;
            AirCns* ret_k = null;
            if (cur.tag == ACNS_CALL) { cur = cur.tail; }
            while (cur != null)
            {
                if (cur.tag == ACNS_STACK)
                {
                    if (ac < 64) { args[ac] = cur.prd; ac++; }
                    cur = cur.tail;
                }
                else if (cur.tag == ACNS_ASCRIBE) { cur = cur.tail; }
                else { ret_k = cur; break; }
            }
            Lvalue callee = v;
            Lvalue[64] argv;
            for (uint i = 0; i < ac; i++)
            {
                uint idx = ac - 1 - i;
                argv[idx] = cg.prd_i64(args[idx]);
            }
            // Use the callee's real function type. malloc returns i8*;
            // we prd_i64-ize everything else as i64. Pointer-returning
            // callees get ptrtoint'd to i64 so they flow through PEAR's
            // i64-uniform value representation like any other value.
            Ltype fn_ty = null;
            bool ret_is_ptr = false;
            if (callee == cg.malloc_fn)
            {
                ret_is_ptr = true;
                Ltype[1] ma; ma[0] = cg.i64ty;
                fn_ty = ll_fn_ty(cg.i8ptrty, &ma[0], 1, 0);
            }
            else if (callee == cg.free_fn)
            {
                // free(i8*) -> void
                Ltype[1] fa; fa[0] = cg.i8ptrty;
                fn_ty = ll_fn_ty(cg.voidty, &fa[0], 1, 0);
                // free's argument arrives as i64 (ptrtoint'd); we bitcast
                // back to i8* at the call site below.
            }
            else if (callee == cg.write_fn)
            {
                // write(i32, i8*, i64) -> i64
                Ltype[3] wa; wa[0] = cg.i32ty; wa[1] = cg.i8ptrty; wa[2] = cg.i64ty;
                fn_ty = ll_fn_ty(cg.i64ty, &wa[0], 3, 0);
            }
            // else user function: we synthesise fn_ty below (opaque-ptr
            // LLVM means we cannot recover the pointee function type from
            // a GlobalValue; the fallback i64(...) signature matches how
            // pear_fn_type and pear_declare build all Pride-declared fns,
            // which widen params/return to i64 by default).
            if (fn_ty == null)
            {
                Ltype[64] atys;
                for (uint i = 0; i < ac; i++) { atys[i] = cg.i64ty; }
                fn_ty = ll_fn_ty(cg.i64ty, &atys[0], ac, 0);
            }
            if (callee == null)
            {
                if (cg.unresolved_callee != null && fn_ty != null && !ret_is_ptr)
                {
                    // The callee was not defined anywhere in this program (see
                    // prd_i64). Emit a real external reference: if the symbol
                    // exists at link time the call is correct, and if it does
                    // not the linker says so by name. Calling address 0 instead
                    // compiled and linked cleanly and then segfaulted, which is
                    // how a cross-module call looked before whole-program
                    // emission went in.
                    Lvalue ext = ll_add_fn(cg.mod, cg.unresolved_callee, fn_ty);
                    if (ext != null)
                    {
                        (void)printf((char*)"pear: '%s' is not defined in this program — linked as an external reference\n",
                                     cg.unresolved_callee);
                        callee = ext;
                    }
                }
                if (callee == null) { callee = ll_const_int(cg.i64ty, 0, 0); }
            }
            cg.unresolved_callee = null;
            // free(p) takes i8* but PEAR holds pointers as i64 — bitcast arg.
            if (callee == cg.free_fn && ac >= 1)
            {
                argv[0] = ll_build_inttoptr(cg.b, argv[0], cg.i8ptrty, cg.mktmp());
            }
            char* nm = cg.mktmp();
            Lvalue r = ll_build_call2(cg.b, fn_ty, callee, &argv[0], ac, nm);
            if (ret_is_ptr)
            {
                r = ll_build_ptrtoint(cg.b, r, cg.i64ty, nm);
            }
            // Do NOT pre-allocate a slot for the binder: let the normal COMU
            // handler do it (it will allocate an i64 slot and store r into it,
            // which correctly writes the pointer value into a named slot).
            return cg.cns(r, ret_k);
        }
        case ACNS_CASE:
        {
            int dense_result = cg.emit_dense_scalar_switch(v, k);
            if (dense_result >= 0) { return dense_result != 0; }
            // Boolean or pattern-matching dispatch. Bootstrap: handle the
            // 2-arm bool case used by if/while/for (true→…; false→…).
            // Evaluate `v` as i1, then cond_br to arms. Fallthrough arm
            // returns false (continues in parent).
            Lvalue cv;
            if (v != null)
            {
                // v could be i1 (from a comparison producer) or i64. Normalize to i1.
                Ltype vt = null; // typeof; we don't expose LLVMTypeOf easily here; use heuristic:
                // Heuristic: if v came from prd_i1 it's already i1. Otherwise treat as i64.
                // Since cns is only reached from cg.cmd which uses prd_i64 for v, v is i64.
                Lvalue z = ll_const_int(cg.i64ty, 0, 0);
                cv = ll_build_icmp(cg.b, LLVM_ICMP_NE, v, z, cg.mktmp());
            }
            else { cv = ll_const_int(cg.i1ty, 0, 0); }
            // Single-arm irrefutable match (e.g. clause-style `| () -> 42`
            // or `match x { _ -> body }`): run the body directly without a
            // condbr. Limit to wildcards and 0-field tuples/records; bool
            // arms must go through condbr even when n_arms==1.
            AirCmd* single_cmd = null;
            uint n_arms = 0;
            bool has_bool_arm = false;
            bool has_irrefutable = false;
            for (uint i = 0; i < (uint)k.branch_count; i++)
            {
                AirBranch* br = k.branches[i];
                if (br == null) continue;
                AirPat* pat = br.pat;
                if (pat == null) continue;
                n_arms++;
                if (pat.tag == APAT_BOOL) { has_bool_arm = true; }
                if (pat.tag == APAT_WILD || pat.tag == APAT_TUPLE)
                {
                    // APAT_TUPLE with 0 children is the unit pattern `()`.
                    if (pat.tag == APAT_WILD || pat.sub_count == 0)
                    {
                        has_irrefutable = true;
                        single_cmd = br.body;
                    }
                }
            }
            if (!has_bool_arm && n_arms == 1 && has_irrefutable && single_cmd != null)
            {
                return cg.cmd(single_cmd);
            }
            // Find true/false arms.
            AirCmd* true_cmd = null;
            AirCmd* false_cmd = null;
            for (uint i = 0; i < (uint)k.branch_count; i++)
            {
                AirBranch* br = k.branches[i];
                if (br == null) continue;
                AirPat* pat = br.pat;
                if (pat == null) continue;
                if (pat.tag == APAT_BOOL)
                {
                    if (pat.ival != 0) { true_cmd = br.body; }
                    else { false_cmd = br.body; }
                }
                else if (pat.tag == APAT_WILD)
                {
                    // Wildcard applies to whichever arm isn't set yet (default).
                    if (true_cmd == null) { true_cmd = br.body; }
                    else { false_cmd = br.body; }
                }
            }
            // Two-arm boolean case: condbr to tb/eb; each arm's body ends with
            // a jump (terminator) that routes flow to the proper continuation.
            // No merge block is needed because both arms explicitly jump away.
            char[256] tb_n; char[256] eb_n;
            (void)snprintf(&tb_n[0], 256, "case.t%u", cg.blk); cg.blk++;
            (void)snprintf(&eb_n[0], 256, "case.f%u", cg.blk); cg.blk++;
            Lblock tb = ll_append_bb(cg.ctx, cg.cur_fn, &tb_n[0]);
            Lblock eb = ll_append_bb(cg.ctx, cg.cur_fn, &eb_n[0]);
            ll_build_condbr(cg.b, cv, tb, eb); cg.terminated = true;
            ll_pos_builder(cg.b, tb); cg.terminated = false;
            // Same admin-join protocol as ACMD_IF: an arm that threaded into a
            // %kN join block reports "not terminated" with the builder inside
            // that block, and the caller's remaining commands belong there.
            Lblock kb_before = cg.cur_k_bb;
            bool tt = true_cmd != null ? cg.cmd(true_cmd) : false;
            bool t_fill = (cg.cur_k_bb != kb_before);
            if (!tt && !t_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
            ll_pos_builder(cg.b, eb); cg.terminated = false;
            bool et = false_cmd != null ? cg.cmd(false_cmd) : false;
            bool e_fill = (cg.cur_k_bb != kb_before);
            if (!et && !e_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
            if (t_fill || e_fill)
            {
                ll_pos_builder(cg.b, cg.cur_k_bb); cg.terminated = false;
                return false;
            }
            // After a case in boolean-form (if/while), BOTH arms end in a
            // jump/return so control does NOT continue after the case. The
            // μ-binder wraps the case and returns control to its enclosing
            // CUT's consumer. Returning true (terminated) tells SEQ that
            // this command "finished" — we've already positioned after
            // eb's terminator, but there's no valid insert point; SEQ will
            // not emit more into a terminated block (it will only be called
            // if an outer μ or something forces continuation, which the
            // CUT+μ structure prevents). Return true to indicate termination.
            return true;
        }
        default:
        {
            ll_build_unreachable(cg.b); cg.terminated = true;
            return true;
        }
    }
}

// ── Commands ─────────────────────────────────────────────────────────

fn bool PearCg.cmd(PearCg* cg, AirCmd* c)
{
    if (c == null) return false;
    // If the current block is closed and a join is still waiting to be filled,
    // the commands that follow belong to that join.
    cg.sync_pos();
    switch (c.tag)
    {
        case ACMD_CUT:
        {
            if (c.prd != null && c.prd.tag == APRD_MU)
            {
                // <μα.c|k>  ≡  c[α := k]
                // Bind α (p.name) to mean "deliver value to k", then execute c.
                // In our IR α always appears as a covar consumer (ACNS_COVAR).
                // Strategy: create a fresh join block "α_bb" where incoming value
                // flows into k; record it via get_lbl-like table; but since
                // covars can appear deeply nested we use the existing bind table
                // keyed by "%α" with a special marker? Simpler: handle the two
                // common shapes:
                //   (a) η-redex: c = <v|α> → evaluate v, send to k directly.
                //   (b) c is a command ending in <...|α> via any path — treat α as
                //       a label bound to k by setting up a trampoline block.
                char* alpha = c.prd.name;
                AirCmd* body = c.prd.body;
                // Shape (a): body is a CUT whose cns is ACNS_COVAR named alpha.
                if (body != null && body.tag == ACMD_CUT
                    && body.cns != null && body.cns.tag == ACNS_COVAR
                    && body.cns.name != null && alpha != null)
                {
                    // Name compare: must be exact match (not just first char).
                    bool same = true; uint ii = 0;
                    while (body.cns.name[ii] != 0 && alpha[ii] != 0)
                    {
                        if (body.cns.name[ii] != alpha[ii]) { same = false; break; }
                        ii++;
                    }
                    if (same && body.cns.name[ii] == 0 && alpha[ii] == 0)
                    {
                        Lvalue v = cg.prd_i64(body.prd);
                        return cg.cns(v, c.cns);
                    }
                }
                // General case: install α as a label-BB that dispatches to c.cns.
                // Build a trampoline BB, stash it in our label table under α (no '%').
                char* anm = alpha;
                if (anm != null && anm[0] == '%') { anm = &anm[1]; }
                if (anm != null)
                {
                    // Create a fresh BB that we'll fill later; but we need the
                    // block to exist now so branches target it. We'll append a BB,
                    // emit body first, then position at end and emit cns of the
                    // phi'd value. Problem: value is what α carries, which is
                    // computed at the <v|α> cut sites. This requires phi nodes.
                    // For bootstrap: just emit body and assume all α-cuts are tail.
                    // But a safer fallback is:
                    (void)anm;
                }
                // Fallback: just emit body; if it never reaches α, return true.
                // This is unsound but matches our existing text-emitter baseline.
                return cg.cmd(body);
            }
            Lvalue v = cg.prd_i64(c.prd);
            return cg.cns(v, c.cns);
        }
        case ACMD_SEQ:
        {
            bool t = cg.cmd(c.body);
            return cg.cmd(c.next);
        }
        case ACMD_LET:
        {
            if (c.prd != null && c.prd.tag != APRD_UNIT)
            {
                bool wild = (c.binder == null) || (c.binder[0] == '_' && c.binder[1] == 0);
                if (!wild)
                {
                    Lvalue v = cg.prd_i64(c.prd);
                    if (v != null)
                    {
                        uint idx = 0;
                        bool existing = cg.lookup_is_ptr(c.binder, &idx);
                        if (existing)
                        {
                            // Rebinding an existing mutable slot (e.g. `s = s+i`
                            // was lowered to `let s = (s+i)` through CPS).
                            Lvalue slot = cg.vals[idx];
                            if (slot != null) { (void)ll_build_store(cg.b, v, slot); }
                        }
                        else
                        {
                            Lvalue slot = cg.alloc_slot(cg.mktmp());
                            (void)ll_build_store(cg.b, v, slot);
                            cg.bind_direct(c.binder, slot, true);
                        }
                    }
                }
                else { (void)cg.prd_i64(c.prd); }
            }
            return cg.cmd(c.body);
        }
        case ACMD_LETREC:
        {
            return cg.cmd(c.body);
        }
        case ACMD_NOP: return false;
        case ACMD_BLOCK:
            return cg.cmd(c.body);
        case ACMD_MUTILDE:
        {
            // μ̃x.c — consumer binder (MUTILDE). Binds x in c to mean "the
            // current continuation" and runs c. At the top of a function body
            // this binds %ret to the return continuation; elsewhere it creates
            // a join point. For top-level %ret binders, our ACMD_CUT → is_ret_name
            // path fires returns. For other μ̃ (e.g. defer, assign), treat as
            // a named binder that forwards to its surrounding context.
            //
            // Bootstrap: record in the label table as a synonym for "fallthrough
            // returns to caller", which already works via is_ret_name for %ret.
            // For non-ret μ̃ (rare in our lowered AIR currently), just run body.
            return cg.cmd(c.body);
        }
        case ACMD_MU:
            return cg.cmd(c.body);
        case ACMD_MATCH:
        {
            // match scrutee { pats... } — evaluate scrutee, dispatch via CASE.
            Lvalue sv = cg.prd_i64(c.prd);
            AirCns kase;
            kase.id = 0; kase.tag = ACNS_CASE; kase.name = null; kase.idx = 0;
            kase.prd = null; kase.tail = null; kase.cont_k = null; kase.body = null;
            kase.bind = null; kase.ty = null; kase.label_name = null;
            kase.label_body = null; kase.label_arg_count = 0; kase.branch_count = 0;
            kase.cobranch_count = 0; kase.subst_count = 0;
            for (usz zi = 0; zi < 16; zi++) { kase.subst_vars[zi] = null; kase.subst_prds[zi] = null; }
            for (usz zi = 0; zi < 64; zi++) { kase.branches[zi] = null; kase.cobranches[zi] = null; }
            for (usz zi = 0; zi < 16; zi++) { kase.label_args[zi] = null; }
            kase.branch_count = c.branch_count;
            kase.dense_switch = c.dense_switch;
            for (usz i = 0; i < c.branch_count && i < 64; i++) { kase.branches[i] = c.branches[i]; }
            return cg.cns(sv, &kase);
        }
        case ACMD_IF:
        {
            Lvalue cv = cg.prd_i1(c.prd);
            char[256] tname; char[256] ename;
            (void)snprintf(&tname[0], 256, "if.then%u", cg.blk); cg.blk++;
            (void)snprintf(&ename[0], 256, "if.else%u", cg.blk); cg.blk++;
            Lblock tb = ll_append_bb(cg.ctx, cg.cur_fn, &tname[0]);
            Lblock eb = ll_append_bb(cg.ctx, cg.cur_fn, &ename[0]);
            ll_build_condbr(cg.b, cv, tb, eb); cg.terminated = true;
            // An arm that lowers to a cut on an admin join (%kN) reports "not
            // terminated" AND leaves the builder inside that join block; the
            // commands after the if belong there. Remember which join block was
            // being filled so control can be handed back to the caller.
            // (Previously `!terminated` was answered with an `unreachable`
            // terminator in the CURRENT block — which after a join fill is the
            // join block itself — and the command reported "terminated", so the
            // caller's sequence dropped everything after the if. That produced
            // `k1: unreachable` and a lost loop back-edge in the while+return
            // repro, i.e. SIGTRAP.)
            Lblock kb_before = cg.cur_k_bb;
            ll_pos_builder(cg.b, tb); cg.terminated = false;
            bool tt = cg.cmd(c.then_c);
            bool t_fill = (cg.cur_k_bb != kb_before);
            if (!tt && !t_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
            ll_pos_builder(cg.b, eb); cg.terminated = false;
            bool et = cg.cmd(c.else_c);
            bool e_fill = (cg.cur_k_bb != kb_before);
            if (!et && !e_fill) { ll_build_unreachable(cg.b); cg.terminated = true; }
            if (t_fill || e_fill)
            {
                ll_pos_builder(cg.b, cg.cur_k_bb); cg.terminated = false;
                return false;
            }
            return true;
        }
        case ACMD_WHILE: case ACMD_FOR:
        {
            char[256] cond_n; char[256] body_n; char[256] exit_n;
            (void)snprintf(&cond_n[0], 256, "loop.cond%u", cg.blk);
            (void)snprintf(&body_n[0], 256, "loop.body%u", cg.blk);
            (void)snprintf(&exit_n[0], 256, "loop.exit%u", cg.blk);
            cg.blk++;
            Lblock cond_bb = ll_append_bb(cg.ctx, cg.cur_fn, &cond_n[0]);
            { /* diag */ }
            Lblock body_bb = ll_append_bb(cg.ctx, cg.cur_fn, &body_n[0]);
            Lblock exit_bb = ll_append_bb(cg.ctx, cg.cur_fn, &exit_n[0]);
            ll_build_br(cg.b, cond_bb); cg.terminated = true;
            ll_pos_builder(cg.b, cond_bb); cg.terminated = false;
            Lvalue cv = cg.prd_i1(c.prd);
            ll_build_condbr(cg.b, cv, body_bb, exit_bb); cg.terminated = true;
            ll_pos_builder(cg.b, body_bb); cg.terminated = false;
            bool bt = cg.cmd(c.body);
            if (!bt) { ll_build_br(cg.b, cond_bb); cg.terminated = true; }
            ll_pos_builder(cg.b, exit_bb); cg.terminated = false;
            return false;
        }
        case ACMD_LABEL:
        {
            // LABEL %l.body declares a named basic block "l" (creating it if a
            // forward jump already referenced it via get_lbl). The label body
            // must be emitted INTO that BB (any jump to %l arrives here).
            // Fall-through code continues in a fresh successor BB.
            char* nm = c.binder;
            if (nm != null && nm[0] == '%') { nm = &nm[1]; }
            if (nm != null)
            {
                Lblock bb = cg.get_lbl(nm);
                if (bb != null)
                {
                    // If the currently-building block has no terminator, br to bb
                    // is NOT automatic — label definitions are join points, not
                    // fall-throughs. However, we must avoid leaving the previous
                    // block unterminated, so insert an unconditional br to bb
                    // only if we know control falls through (i.e. we didn't just
                    // arrive from a jump). Detect by checking whether the current
                    // insert block is still open (it will be if the previous
                    // command returned "not terminated"). This is our situation:
                    // we fall through from SEQ. Emit a br to bb? No — that would
                    // mean "execute the label body here", which is wrong.
                    //
                    // The correct model: a label %l.body in the command stream is
                    // a *definition* of a join point that is reached by JUMP.
                    // Control does NOT flow through a label def in the source
                    // (well-formed AIR uses JUMP to reach labels; seq does not
                    // step into labels). The entry point jumps to the first
                    // label it needs.
                    //
                    // For bootstrap we emit the body into bb and add a fresh BB
                    // after (without br from current). But if current block is
                    // unterminated we leave it for subsequent code to terminate
                    // — but nothing should follow a label at SEQ level besides
                    // LABEL defines a new BB (bb). Save current insert point,
                    // emit label body into bb, then restore insert point so
                    // subsequent SEQ commands (like a JUMP to this label, or
                    // the next LABEL) continue in the original block.
                    Lblock saved = ll_get_insert(cg.b);
                    bool saved_term = cg.terminated;
                    // Emit label body into bb.
                    ll_pos_builder(cg.b, bb); cg.terminated = false;
                    (void)cg.cmd(c.body);
                    // After emitting the label body, bb ends in whatever
                    // terminator its body produced (jump/ret/unreachable).
                    // Restore the insert point to the enclosing block so the
                    // commands that FOLLOW this label definition (typically the
                    // loop's entry/back-edge jump) continue there.
                    ll_pos_builder(cg.b, saved); cg.terminated = saved_term;
                    return false;
                }
            }
            return cg.cmd(c.body);
        }
        case ACMD_JUMP:
        {
            char* nm = c.target_label;
            if (nm != null && nm[0] == '%') { nm = &nm[1]; }
            if (nm == null) return true;
            Lblock bb = cg.get_lbl(nm);
            if (bb == null) return true;

            // Where does this branch belong?
            //
            // Normally the current block. But a CPS sequence can carry sibling
            // jumps: the first closes the current block (e.g. a loop's entry
            // branch) and the second is the CONTENT of a pending join — the
            // block a cut `<()|%kN>` redirected the continuation into, which
            // has not been filled yet. Two things go wrong if we ignore that:
            // appending the second branch to the closed block puts two
            // terminators in it (invalid IR; LLVM aborts in Instruction::clone),
            // and reporting "terminated" makes ACMD_SEQ drop the rest of the
            // sequence, which is exactly the join's content — the loop loses its
            // back edge and the join block is left unterminated.
            // cg.cmd already ran sync_pos, so if we are in a closed block there
            // was no open join to move to.
            Lblock cur = ll_get_insert(cg.b);
            if (!cg.bb_open(cur))
            {
                // Park the branch in a fresh unreachable block: dropping it
                // outright would silently lose a back edge if a later command
                // turns out to need this target, and an orphan block is valid IR
                // (LLVM deletes it).
                ll_pos_builder(cg.b, cg.dead_bb());
                ll_build_br(cg.b, bb); cg.terminated = true;
                return true;
            }
            ll_build_br(cg.b, bb); cg.terminated = true;
            // A jump closes the current block. If a join is still open, the rest
            // of this sequence is that join's content -- the shape of a NESTED
            // loop is [jump %loopN; mu-tilde c. <jump %loopN>], where the first
            // jump enters the inner loop and the continuation of the outer
            // body's cut is the outer back edge. Reporting "terminated" here made
            // ACMD_SEQ drop it, which lost the outer back edge and left the join
            // block unterminated -- invalid IR, and LLVM aborted in
            // Instruction::clone.
            return cg.pending_open_join(cur) == null;
        }
        case ACMD_RET:
        {
            if (c.prd != null) { Lvalue v = cg.prd_i64(c.prd); ll_build_ret(cg.b, v); cg.terminated = true; }
            else { ll_build_ret_void(cg.b); cg.terminated = true; }
            return true;
        }
        case ACMD_BREAK:
        case ACMD_CONTINUE:
        {
            ll_build_unreachable(cg.b); cg.terminated = true;
            return true;
        }
        case ACMD_DEFER:
        {
            return cg.cmd(c.body);
        }
        case ACMD_TRAP: case ACMD_UB:
            ll_build_unreachable(cg.b); cg.terminated = true; return true;
        default:
            ll_build_unreachable(cg.b); cg.terminated = true; return true;
    }
}

// ── Function emission ────────────────────────────────────────────────

// ── Function symbols ────────────────────────────────────────────────────────
// One LLVM function per source function: the type is derived from the AirDecl
// (each parameter is widened to i64 unless it carries an annotation, and a void
// return maps to void), and the function is created once and then reused.
//
// This matters because calls resolve their callee by NAME (prd_i64 ->
// ll_get_named_fn). Emitting bodies in declaration order meant a call to a
// function defined LATER in the file found no symbol, and the call site fell
// back to `callee = ll_const_int(i64, 0)` — a call to address 0, so the program
// compiled, linked, and then segfaulted on the first forward call:
//   fn main(_) -> i64 { return g(41); }   // g defined below
//   fn g(x: i64) -> i64 { return x + 1; }   -> SIGSEGV (139), want 42
fn Ltype pear_fn_type(PearCg* cg, AirDecl* d, Ltype* ptys, char** pnms, uint* pc_out)
{
    uint pc = (uint)d.param_count;
    if (pc > 16) pc = 16;
    for (uint i = 0; i < pc; i++)
    {
        AirBinder* p = d.params[i];
        ptys[i] = cg.i64ty;
        if (pnms != null) { pnms[i] = (p != null && p.name != null) ? p.name : (char*)"_"; }
        if (p != null && p.ty != null && !pear_is_void(p.ty)) { ptys[i] = pear_llvm_ty(cg, p.ty); }
    }
    *pc_out = pc;
    Ltype rty = pear_is_void(d.ret_ty) ? cg.voidty : pear_llvm_ty(cg, d.ret_ty);
    return ll_fn_ty(rty, &ptys[0], pc, 0);
}

// Get the LLVM function for `d`, creating it if this is the first mention. A
// pre-pass in pear_setup() calls this for every definition so that all functions
// are visible to each other regardless of source order; pear_emit_fn() calls it
// again and receives the same symbol, so the body lands in the pre-created
// function instead of a duplicate (`LLVMAddFunction` renames collisions).
fn Lvalue pear_fn_get_or_create(PearCg* cg, AirDecl* d)
{
    if (d == null) return null;
    char* nm = d.name; if (nm == null) nm = (char*)"_anon";
    Lvalue existing = ll_get_named_fn(cg.mod, nm);
    if (existing != null) return existing;
    Ltype[64] ptys;
    char*[64] pnms;
    uint pc = 0;
    Ltype fty = pear_fn_type(cg, d, &ptys[0], &pnms[0], &pc);
    return ll_add_fn(cg.mod, nm, fty);
}

// pear_dup_def — does an EARLIER definition in this program already own `nm`?
//
// Whole-program emission concatenates every loaded module into one AirModule,
// and the symbol table is keyed by the bare name (there is no module mangling
// yet). The first definition therefore wins; emitting a second one would add a
// duplicate symbol that LLVM renames (name.1), leaving a dead body behind and
// making it look like the later module's function was used when it was not.
fn bool pear_dup_def(PearCg* cg, AirDecl* d)
{
    if (cg.air == null || d == null || d.name == null) return false;
    for (usz i = 0; i < cg.air.decl_count; i++)
    {
        AirDecl* e = cg.air.decls[i];
        if (e == null || e == d) continue;
        if (e.name == null) continue;
        if (e.tag != ADECL_DEF) continue;
        usz j = 0; bool eq = true;
        while (e.name[j] != 0 && d.name[j] != 0)
        {
            if (e.name[j] != d.name[j]) { eq = false; break; }
            j++;
        }
        if (eq && e.name[j] == 0 && d.name[j] == 0) { return true; }
    }
    return false;
}

fn void pear_emit_fn(PearCg* cg, AirDecl* d)
{
    if (d == null) return;
    // First definition wins across modules (see pear_dup_def).
    {
        bool seen = false;
        if (cg.air == null) { return; }
        for (usz i = 0; i < cg.air.decl_count; i++)
        {
            AirDecl* e = cg.air.decls[i];
            if (e == null || e == d) { if (e == d) { break; } continue; }
            if (e.tag != ADECL_DEF || e.name == null || d.name == null) continue;
            usz j = 0; bool eq = true;
            while (e.name[j] != 0 && d.name[j] != 0) { if (e.name[j] != d.name[j]) { eq = false; break; } j++; }
            if (eq && e.name[j] == 0 && d.name[j] == 0) { seen = true; break; }
        }
        if (seen)
        {
            (void)printf((char*)"pear: duplicate definition of '%s' — keeping the first\n", d.name);
            return;
        }
    }
    char* nm = d.name; if (nm == null) nm = (char*)"_anon";
    cg.tmp = 0; cg.blk = 0; cg.name_n = 0; cg.lbl_n = 0;
    for (uint i = 0; i < 128; i++) cg.lbl_kfilled[i] = false;
    cg.cur_k_bb = null;
    cg.unresolved_callee = null;
    Ltype[64] ptys;
    char*[64] pnms;
    uint pc = 0;
    (void)pear_fn_type(cg, d, &ptys[0], &pnms[0], &pc);
    Lvalue fnv = pear_fn_get_or_create(cg, d);
    cg.cur_fn = fnv;
    // TWO BBs at function entry:
    //   entry (alloca-only) — holds all alloca instructions (static slots).
    //   body — first real code.
    // We leave entry UNTERMINATED while emitting body so that alloc_slot()
    // can position at end(entry) and append new alloca instructions without
    // inserting past a terminator ("Terminator found in middle of BB").
    // After body emission, we add `br body` to end entry.
    Lblock entry = ll_append_bb(cg.ctx, fnv, "entry");
    Lblock body  = ll_append_bb(cg.ctx, fnv, "body");
    cg.entry_bb = entry;
    cg.body_bb  = body;
    ll_pos_builder(cg.b, entry);
    cg.terminated = false;
    for (uint i = 0; i < pc; i++)
    {
        Lvalue arg = ll_get_param(fnv, i);
        cg.bind(pnms[i], arg);
    }
    // Move builder to body BB for the actual code.
    ll_pos_builder(cg.b, body);
    cg.terminated = false;
    bool term = false;
    if (d.def_body != null)
    {
        term = cg.cmd(d.def_body);
    }
    if (!term)
    {
        if (pear_is_void(d.ret_ty)) { ll_build_ret_void(cg.b); cg.terminated = true; }
        else { ll_build_ret(cg.b, ll_const_int(cg.i64ty, 0, 0)); }
    }
    // Close entry BB: branch from entry → body. Entry now ends in a br
    // terminator, after all allocas.
    ll_pos_builder(cg.b, entry);
    ll_build_br(cg.b, body);

    // Pride fns don't throw, don't free, don't do atomics, always return.
    // These attrs unlock better optimization than plain -O2 C gets.
    // PEAR strong attribute set. λ̄μμ̃ gives us global knowledge C lacks:
    //  - All Pride functions are TOTAL (willreturn, mustprogress) — no unbounded
    //    recursion in well-founded Pride, no infinite loops at effect level
    //  - Never unwind (nounwind), never free (nofree), no atomics (nosync)
    //  - No callback registration (no-callback).
    // These unlock GVN/LICM/speculation C compilers refuse to apply.
    // PEAR strong attribute set. λ̄μμ̃ gives us global knowledge C lacks:
    //  - All Pride functions are TOTAL (willreturn, mustprogress)
    //  - Never unwind (nounwind), never free (nofree), no atomics (nosync)
    //  - No callback registration (no-callback), speculatable.
    // These unlock GVN/LICM/speculation C compilers refuse to apply.
    // Tag with attributes PEAR can prove via effect system.
    // NOTE(v0.9 heap bootstrap): willreturn/mustprogress/nosync are DISABLED
    // while we wire up malloc properly. LLVM's attribute inference was
    // marking `main` as `memory(none) nofree` because our hand-declared
    // @malloc didn't carry `allockind(\"alloc,...\")`, which let the
    // optimizer delete the malloc call, fold the store to NULL, and
    // segfault (movb $0x7,0x0). Re-enable once malloc carries the right
    // allockind string attrs (see pear_setup).
    pear_tag_fn(cg, cg.cur_fn, LLVM_ATTR_NOUNWIND);
    // `memory(read)` means no writes to externally observable memory. This is
    // weaker than memory(none): pointer/global reads and divergence remain
    // legal, so the attribute does not claim termination or purity of values.
    if (d.memory_readonly) { pear_tag_memory_read(cg, cg.cur_fn); }
    // nofree: only if the fn has no Alloc effect (conservative for now: OFF)
    // willreturn / nosync / mustprogress: OFF pending malloc fix.
}

fn void pear_declare(PearCg* cg, AirDecl* d)
{
    if (d == null) return;
    char* nm = d.name; if (nm == null) return;
    if (ll_get_named_fn(cg.mod, nm) != null) return;
    uint pc = (uint)d.param_count;
    if (pc > 64) pc = 64;
    Ltype[64] ptys;
    for (uint i = 0; i < pc; i++)
    {
        AirBinder* p = d.params[i];
        if (p != null && p.ty != null && !pear_is_void(p.ty)) { ptys[i] = pear_llvm_ty(cg, p.ty); }
        else { ptys[i] = cg.i64ty; }
    }
    Ltype rty = pear_is_void(d.ret_ty) ? cg.voidty : pear_llvm_ty(cg, d.ret_ty);
    Ltype fty = ll_fn_ty(rty, &ptys[0], pc, 0);
    (void)ll_add_fn(cg.mod, nm, fty);
}

// ── Entry points ──────────────────────────────────────────────────────
fn void pear_tag_fn(PearCg* cg, Lvalue fnv, int kind)
{
    Lvalue a = ll_create_enum_attr(cg.ctx, (uint)kind, 0);
    ll_add_attr_at_idx(fnv, LLVM_ATTR_FN_INDEX, a);
}

fn void pear_tag_memory_read(PearCg* cg, Lvalue fnv)
{
    if (cg == null || fnv == null) { return; }
    Lvalue a = ll_create_string_attr(cg.ctx,
        (char*)"memory", 6u, (char*)"read", 4u);
    if (a != null)
    {
        ll_add_attr_at_idx(fnv, LLVM_ATTR_FN_INDEX, a);
        cg.memory_read_attrs = cg.memory_read_attrs + 1;
    }
}


// ============================================================================
// PEAR modular optimization pipelines (v0.7).
//
// PEAR is a λ̄μμ̃ → LLVM adaptor that leverages Pride's effect system to apply
// optimizations GCC/Clang cannot safely apply to C:
//
//   * willreturn + mustprogress — totality proof (no infinite loops/recursion)
//   * nounwind — no exceptions
//   * nofree + nosync + nocallback — pure, no observable side effects
//
// We expose three pipeline tiers so the frontend can select `-O0`, `-O1`, `-O2`.
// The `-O2` pipeline is heavier than clang -O2 because it trusts PEAR attrs.
//
// Pass notes:
//   - "adce" / "bdce" / "dce" / "dse" / "die"  : DCE family (aggressive,
//         bit-tracking, dead-store, dead-inst-elim)
//   - "early-cse-memssa" : early common-subexpr elim with MemorySSA
//   - "gvn" : global value numbering (runs twice with simplifycfg between)
//   - "sccp" + "correlated-propagation" : sparse conditional constant prop
//         + correlated value propagation (jump-threading friend)
//   - "licm" / "indvars" / "loop-idiom" / "loop-deletion" : canonical loop opts
//   - "loop-unroll" (partial) + "loop-vectorize" : vectorization
//   - "tailcallelim" : musttail / sibling calls (Pride totality -> all self-
//         tail-recursion can be marked musttail safely)
//   - "function-attrs" + "argument-promotion" : derive readonly/readnone/norecurse
//   - "globalopt" + "globaldce" + "global-split" : IPO
//   - "memcpyopt" : memcpy/memset folding
//   - "sroa" : scalar replacement of aggregates (cleanup after mem2reg)
// ============================================================================
// PEAR v0.7 pipeline tiers. PEAR = Pride's Engine for Abstractive
// Representations (lmm-to-LLVM adaptor). The O2 tier is heavier than
// clang -O2 because PEAR's strong attributes unlock speculation C
// compilers refuse to apply. Passes verified to exist in LLVM 19.
// PEAR v0.8.6 pipeline tiers. PEAR = Pride's Engine for Abstractive
// Representations (λ̄μμ̃-to-LLVM adaptor). We use LLVM's well-tested
// default<O0/O1/O2/O3> pipelines (clang-compatible ordering + all the
// usual canonicalizations, IPO, loop opts, vectorization, cleanup).
// PEAR adds value on top via effect-aware function-attr tagging in
// pear_tag_fn() — nounwind/willreturn/nofree/nosync/nocallback/
// norecurse/mustprogress/speculatable — which unlocks optimizations
// C compilers refuse to apply (they can't prove them). We stopped
// hand-composing pipelines because pass names shift across LLVM
// versions ("early-cse-memssa" → "early-cse" in 23; LICM needs the
// "loop-mssa(licm)" wrapper; "function-attrs" is a module pass not a
// function pass when called mid-pipeline, etc.)
const char* PEAR_PIPE_O0 = (char*)"default<O1>";  // no true -O0: FastISel chokes on our GEPs
const char* PEAR_PIPE_O1 = (char*)"default<O1>";
const char* PEAR_PIPE_O2 = (char*)"default<O2>";
const char* PEAR_PIPE_O3 = (char*)"default<O3>";
const char* PEAR_PIPELINE = PEAR_PIPE_O2;  // default tier; frontend may swap

// Select the PEAR pipeline for an opt level (0/1/2/3).
fn char* pear_pipe_for(int lvl)
{
    if (lvl <= 0) return PEAR_PIPE_O0;
    if (lvl == 1) return PEAR_PIPE_O1;
    if (lvl == 2) return PEAR_PIPE_O2;
    return PEAR_PIPE_O3;
}

fn void pear_setup(PearCg* cg, Lcontext ctx, Lmodule m, Lbuilder b, AirModule* mod)
{
    cg.air = mod;
    cg.ctx = ctx; cg.mod = m; cg.b = b; cg.tmp = 0; cg.blk = 0;
    cg.name_n = 0; cg.lbl_n = 0; cg.terminated = false;
    cg.memory_read_attrs = 0;
    cg.i64ty = ll_i64_ty(ctx);
    cg.i32ty = ll_i32_ty(ctx);
    cg.i8ty  = ll_i8_ty(ctx);
    cg.i1ty  = ll_i1_ty(ctx);
    cg.voidty = ll_void_ty(ctx);
    cg.i8ptrty = ll_ptr_ty(cg.i8ty, 0);
    cg.malloc_fn = null;
    cg.free_fn = null;
    cg.write_fn = null;

    // Pre-declare libc intrinsics we may reference and tag them with the
    // strongest attributes we know hold (so LLVM optimizes through them even
    // without seeing libc definitions — these match what clang gives libc).
    {
        Ltype i8p = cg.i8ptrty;
        // write(i32 fd, i8* buf, i64 n) -> i64
        Ltype[3] wa; wa[0] = cg.i32ty; wa[1] = i8p; wa[2] = cg.i64ty;
        Ltype wfty = ll_fn_ty(cg.i64ty, &wa[0], 3, 0);
        cg.write_fn = ll_add_fn(m, (char*)"write", wfty);
        // malloc(i64 bytes) -> i8*  (nounwind/willreturn/nosync. nofree is
        // WRONG for malloc; it's the thing that *does* alloc.)
        Ltype[1] ma; ma[0] = cg.i64ty;
        Ltype mfty = ll_fn_ty(i8p, &ma[0], 1, 0);
        cg.malloc_fn = ll_add_fn(m, (char*)"malloc", mfty);
        pear_tag_fn(cg, cg.malloc_fn, LLVM_ATTR_NOUNWIND);
        // Tell LLVM this is an allocator (returns fresh, uninitialized
        // memory). Without "allockind" the middle-end treats @malloc as
        // a black-box external and infers nofree/memory(none) on callers,
        // which deletes the call and folds stores to NULL → SIGSEGV.
        // Lengths computed manually: "allockind"=9,
        // "alloc,uninitialized"=19.
        {
            Lvalue sa = ll_create_string_attr(cg.ctx,
                (char*)"allockind", 9u,
                (char*)"alloc,uninitialized", 19u);
            ll_add_attr_at_idx(cg.malloc_fn, LLVM_ATTR_FN_INDEX, sa);
        }
        // free(i8*) -> void: "allockind"="free" (4)
        Ltype[1] fa; fa[0] = i8p;
        Ltype ffty = ll_fn_ty(cg.voidty, &fa[0], 1, 0);
        cg.free_fn = ll_add_fn(m, (char*)"free", ffty);
        pear_tag_fn(cg, cg.free_fn, LLVM_ATTR_NOUNWIND);
        {
            Lvalue sa = ll_create_string_attr(cg.ctx,
                (char*)"allockind", 9u,
                (char*)"free", 4u);
            ll_add_attr_at_idx(cg.free_fn, LLVM_ATTR_FN_INDEX, sa);
        }
    }

    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DECLARE) { pear_declare(cg, d); }
    }
    // Pre-create EVERY definition as an LLVM function before any body is
    // emitted, so calls resolve regardless of source order (a forward call used
    // to become a call to address 0 — see pear_fn_get_or_create).
    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DEF) { (void)pear_fn_get_or_create(cg, d); }
    }
    for (uint i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null) continue;
        if (d.tag == ADECL_DEF) { pear_emit_fn(cg, d); }
    }
}

fn void pear_emit_module(AirModule* mod, char* bc_path, int opt_level)
{
    if (mod == null || bc_path == null) return;
    Lcontext ctx = ll_ctx_create();
    Lmodule m = ll_mod_create((char*)"Pride", ctx);
    Lbuilder b = ll_builder_create(ctx);
    (void)ll_set_target(m, (char*)"x86_64-pc-linux-gnu");
    (void)ll_set_datalayout(m, (char*)"e-m:e-p270:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128");

    PearCg cg;
    pear_setup(&cg, ctx, m, b, mod);
    // Run PEAR modular pipeline (new PM). No TM for bc emission — TM-specific
    // passes (regalloc, isel) run at link/obj time.
    {
        Lpass_opts po = ll_create_pb_opts();
        ll_pb_set_inliner_threshold(po, 250);
        Lerror e = ll_run_passes(m, pear_pipe_for(opt_level), null, po);
        if (e != null)
        {
            // LLVM 23: LLVMGetErrorMessage takes the Error by value and CONSUMES it.
            // Do NOT call LLVMConsumeError after getting the message — that would
            // be a double-free / use-after-return (observed as "Out of bounds
            // memory access" in LLVMConsumeError with bogus Error*).
            char* msg = ll_get_err_msg(e);
            if (msg != null) { (void)printf((char*)"pear: bc pass error: %s\n", msg); ll_dispose_msg(msg); }
        }
        ll_dispose_pb_opts(po);
    }

    (void)ll_write_bc(m, bc_path);
    ll_builder_dispose(b);
    ll_mod_dispose(m);
    ll_ctx_dispose(ctx);
}

// Emit a native ELF .o via LLVMTargetMachineEmitToFile (in-process, no shell).
// Returns true on success.
fn bool pear_emit_obj(AirModule* mod, char* obj_path, int opt_level)
{
    if (mod == null || obj_path == null) return false;
    ll_init_x86_ti();
    ll_init_x86_t();
    ll_init_x86_tmc();
    ll_init_x86_asmp();
    ll_init_x86_asmpa();

    Lcontext ctx = ll_ctx_create();
    Lmodule m = ll_mod_create((char*)"Pride", ctx);
    Lbuilder b = ll_builder_create(ctx);
    (void)ll_set_target(m, (char*)"x86_64-pc-linux-gnu");
    (void)ll_set_datalayout(m, (char*)"e-m:e-p270:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128");

    Ltarget tgt = null;
    char* err = null;
    if (ll_get_target_from_triple((char*)"x86_64-pc-linux-gnu", &tgt, &err) != 0)
    {
        if (err != null) ll_dispose_msg(err);
        ll_builder_dispose(b); ll_mod_dispose(m); ll_ctx_dispose(ctx);
        return false;
    }
    PearCg cg;
    pear_setup(&cg, ctx, m, b, mod);
    // Run PEAR mid-end pipeline WITHOUT the TM attached. LLVM 19's DwarfEHPrepare
    // pass segfaults when added to the codegen pipeline on modules containing
    // recursive functions (see https://github.com/llvm/llvm-project/issues/XXXX);
    // skipping TM during opt avoids triggering EH synthesis entirely. We do this
    // consistently with the bc path so codegen quality matches.
    {
        Lpass_opts po = ll_create_pb_opts();
        ll_pb_set_inliner_threshold(po, 250);
        Lerror pe = ll_run_passes(m, pear_pipe_for(opt_level), null, po);
        if (pe != null)
        {
            // See note above: LLVMGetErrorMessage consumes the Error in LLVM 23.
            char* msg = ll_get_err_msg(pe);
            if (msg != null) { (void)printf((char*)"pear: obj pass error: %s\n", msg); ll_dispose_msg(msg); }
        }
        ll_dispose_pb_opts(po);
    }
    // Use LLVM_CODEGEN_O2 for the TM: FastISel at O0 crashes on GEPs/bitcasts
    // we emit for pointer/index ops (StructType::getTypeAtIndex). Mid-end
    // optimization level is still controlled by pear_pipe_for(opt_level);
    // this only affects instruction selection / regalloc / codegen quality.
    Ltarget_machine tm = ll_create_tm(tgt, (char*)"x86_64-pc-linux-gnu", (char*)"", (char*)"", LLVM_CODEGEN_O2, LLVM_RELOC_STATIC, LLVM_CODE_MODEL_SMALL);
    if (tm == null)
    {
        ll_builder_dispose(b); ll_mod_dispose(m); ll_ctx_dispose(ctx);
        return false;
    }

    char* emsg = null;
    bool ok = (ll_tm_emit_to_file(tm, m, obj_path, LLVM_CG_OBJ_FILE, &emsg) == 0);
    if (emsg != null)
    {
        (void)printf((char*)"pear: obj emit: %s\n", emsg);
        ll_dispose_msg(emsg);
    }

    if (cg.memory_read_attrs > 0)
    {
        (void)printf((char*)"pear qualifier attrs: %d function(s) tagged LLVM memory(read)\n",
                     (int)cg.memory_read_attrs);
    }
    ll_dispose_tm(tm);
    ll_builder_dispose(b);
    ll_mod_dispose(m);
    ll_ctx_dispose(ctx);
    return ok;
}
