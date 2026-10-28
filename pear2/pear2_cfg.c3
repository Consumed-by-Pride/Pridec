// PEAR 2 native pipeline, stage 1: AIR -> PIR (the middle representation).
//
// This file is the *seam* the backend has been missing. Everything PEAR 2 emits
// today goes through LLVM: AIR becomes IR text, LLVM parses that text, and LLVM
// decides what machine code to produce. That is correct and well tested, but it
// makes the compiler's own middle end impossible to grow -- there is no place to
// put a pass that is PEAR's rather than LLVM's, and every compile pays for
// printing, lexing, and re-parsing a textual IR.
//
// PIR is deliberately small. It is a control-flow graph of basic blocks holding
// three-address instructions over virtual registers, plus frame slots for the
// bindings AIR lets cross a block boundary. It is not an SSA form with phi
// nodes: AIR's own structure already gives every `let` a single definition, so
// the only values that genuinely need to meet at a join are the ones AIR itself
// carries through label parameters, and those become ordinary slot stores and
// loads. Adding phis later is a local change (see "What the next stages add").
//
// Why slots rather than phis, stated plainly: AIR is CPS-shaped. A mutable local
// is a label parameter, a `jump` passes it, and a `while` re-enters its header.
// Modelling that as a parallel copy into a block parameter is exactly a phi, but
// getting dominance right for every construct -- labels that appear after their
// jumps, `break`/`continue` out of nested loops, MATCH arms that each return --
// is the kind of work that produces subtly wrong code. A slot is always correct,
// costs one store and one load, and can be promoted away by a later pass that
// has the dominance information PIR records.
//
// What the next stages add (each one is a separate file on purpose):
//   * slot promotion / register allocation over PIR (the store-load pairs this
//     stage emits are the obvious input),
//   * machine-specific selection (pear2_x64.c3 reads PIR, not AIR),
//   * an ELF writer (pear2_elf.c3) so a target binary needs no linker driver,
//   * later middle-end passes: SCCP, GVN, loop-invariant motion -- all of them
//     operate on PIR and none of them can reach into LLVM.
//
// The whole pipeline fails closed. A construct outside the subset this stage
// models is reported with a source position and the compile stops; nothing is
// approximated, because a wrong instruction is worse than a refusal.
module pear2c;
import air_ir;

extern fn void* malloc(usz size_);
extern fn void  free(void* ptr);
extern fn void* memset(void* dst, int value, usz n);

// ── PIR instruction set ────────────────────────────────────────────────────
//
// One flat enum rather than a hierarchy: a pass that wants to look at every
// arithmetic instruction can write one `switch`, and the fixed record below
// keeps the instruction stream contiguous in memory, which is what makes the
// linear passes at the end of this file cheap.
enum POp : int {
    PO_CONST,      // dst = imm
    PO_COPY,       // dst = a
    PO_ADD, PO_SUB, PO_MUL,
    PO_DIVS, PO_DIVU, PO_REMS, PO_REMU,
    PO_AND, PO_OR, PO_XOR, PO_SHL, PO_SHR, PO_SAR,
    PO_NEG, PO_NOT,        // PO_NOT is bitwise inversion
    PO_CMP,        // dst = (a <pred> b) as 0 or 1, width 8
    PO_CMPI,       // dst = (a <pred> imm) as 0 or 1, width 8
    PO_LOAD,       // dst = *(slot)
    PO_STORE,      // *(slot) = a          (slot in `imm`)
    PO_SLOTADDR,   // dst = address of slot (used by later stages; PIR-level no-op)
    PO_CALL,       // dst = callee(args...)
    PO_JMP,        // terminator: to block `target`
    PO_BR,         // terminator: a != 0 -> target, else target2
    PO_RET         // terminator: return a (ignored when the function is unit)
}

// Predicates are their own small enum so a comparison reads the same in the CFG,
// the machine layer, and any future pass. The order matches the x86 condition
// encodings this backend targets (E, NE, L, LE, G, GE for signed), which is a
// convenience, not a contract.
enum PPred : int { PP_EQ, PP_NE, PP_LT, PP_LE, PP_GT, PP_GE, PP_ULT, PP_ULE, PP_UGT, PP_UGE }

struct PInst {
    POp op;
    int dst;        // destination vreg, or -1
    int a;          // first source vreg, or -1
    int b;          // second source vreg, or -1
    long imm;       // constant operand / slot index / jump table value
    int pred;       // PPred for PO_CMP / PO_CMPI
    int width;      // operand width in bits: 1, 8, 16, 32, 64
    bool sign;      // signed interpretation of the operands
    int target;     // branch targets (block ids) for PO_JMP / PO_BR
    int target2;
    int argc;       // PO_CALL argument count
    int[6] args;    // PO_CALL argument vregs
    char* callee;   // PO_CALL callee symbol, already resolved
    bool is_extern; // PO_CALL: callee is an external symbol (PLT relocation)
}

struct PBlock {
    int id;
    char* name;
    PInst* code;
    int count;
    int cap;
    // Label parameters (AIR `label L(a, b).`) are the block's incoming values.
    // A jump stores into these slots before the edge; the block reloads them on
    // entry because the builder's value cache is scoped to the defining block.
    char*[16] param_names;
    int[16] param_slots;
    int[16] param_widths;
    bool[16] param_signs;
    bool[16] param_ptrs;
    int param_count;
}

struct PBinding {
    char* name;
    int slot;         // frame slot holding the authoritative value
    int vreg;         // cached register value for the block below, or -1
    int defined_in;   // block id the cache is valid in, or -1
    int width;
    bool sign;
    bool is_ptr;
}

struct PParam {
    char* name;
    int slot;
    int vreg;         // incoming argument vreg (assigned by the machine layer)
    int width;
    bool sign;
    bool is_ptr;
}

struct PFunc {
    char* name;
    bool is_public;
    PBlock* blocks;
    int block_count;
    int block_cap;
    int vreg_count;
    int slot_count;      // slots are 8 bytes each in this stage
    int slot_bytes;
    PParam[16] params;
    int param_count;
    int ret_width;
    bool ret_sign;
    bool ret_unit;
    bool ret_ptr;
    int entry;
}

// A builder owns one function's construction. `bindings` is the lexical scope
// stack: AIR binds names and restores the environment on exit, so a stack with a
// saved height is the direct model. The stack is what makes shadowing in nested
// lambdas and match arms behave the way the AIR scoping rules say it does.
struct PBuilder {
    PFunc* fn;
    PBinding[512] bindings;
    int binding_count;
    int cur_block;
    bool failed;
    int fail_line;
    int fail_col;
    char* fail_message;
}

// ── allocation helpers ─────────────────────────────────────────────────────

fn PBlock* pblock_new(PFunc* fn, char* name)
{
    if (fn == null) { return null; }
    if (fn.block_count >= fn.block_cap)
    {
        int next = fn.block_cap <= 0 ? 8 : fn.block_cap * 2;
        PBlock* grown = (PBlock*)malloc((usz)next * PBlock::size);
        if (grown == null) { return null; }
        memset(grown, 0, (usz)next * PBlock::size);
        for (int i = 0; i < fn.block_count; i++) { grown[i] = fn.blocks[i]; }
        if (fn.blocks != null) { free(fn.blocks); }
        fn.blocks = grown;
        fn.block_cap = next;
    }
    PBlock* b = &fn.blocks[fn.block_count];
    b.id = fn.block_count;
    b.name = name;
    b.code = null;
    b.count = 0;
    b.cap = 0;
    fn.block_count++;
    return b;
}

fn bool pblock_reserve(PBlock* b, int extra)
{
    if (b == null) { return false; }
    if (b.count + extra <= b.cap) { return true; }
    int next = b.cap <= 0 ? 16 : b.cap;
    while (next < b.count + extra) { next = next * 2; }
    PInst* grown = (PInst*)malloc((usz)next * PInst::size);
    if (grown == null) { return false; }
    memset(grown, 0, (usz)next * PInst::size);
    for (int i = 0; i < b.count; i++) { grown[i] = b.code[i]; }
    if (b.code != null) { free(b.code); }
    b.code = grown;
    b.cap = next;
    return true;
}

// pinst_push -- append one zeroed instruction and hand it back for filling. The
// caller sets only the fields it means; everything else is already "absent"
// (-1 vregs, block target -1), so a forgotten field cannot alias a real vreg 0.
fn PInst* pblock_push(PBlock* b)
{
    if (b == null || !pblock_reserve(b, 1)) { return null; }
    PInst* ins = &b.code[b.count];
    *ins = {};
    ins.dst = -1;
    ins.a = -1;
    ins.b = -1;
    ins.target = -1;
    ins.target2 = -1;
    ins.width = 64;
    ins.callee = null;
    ins.argc = 0;
    b.count++;
    return ins;
}

fn int pvreg_new(PBuilder* pb)
{
    if (pb == null || pb.fn == null) { return -1; }
    int v = pb.fn.vreg_count;
    pb.fn.vreg_count++;
    return v;
}

// pslot_new -- allocate one 8-byte frame slot. Slots are numbered, not offset:
// the machine layer assigns the frame layout, because only it knows the saving
// convention it uses (and a future allocator will want to split slots).
fn int pslot_new(PBuilder* pb, int width)
{
    if (pb == null || pb.fn == null) { return -1; }
    int slot = pb.fn.slot_count;
    pb.fn.slot_count++;
    pb.fn.slot_bytes += 8;
    if (width > 8) { pb.fn.slot_bytes = pb.fn.slot_bytes + (width / 8) * 8 - 8; }
    return slot;
}

// ── builder state ──────────────────────────────────────────────────────────

fn bool pb_fail(PBuilder* pb, int line, int col, char* message)
{
    if (pb == null) { return false; }
    if (!pb.failed)
    {
        pb.failed = true;
        pb.fail_line = line;
        pb.fail_col = col;
        pb.fail_message = message;
    }
    return false;
}

fn PInst* pb_emit(PBuilder* pb, POp op)
{
    if (pb == null || pb.fn == null || pb.failed) { return null; }
    if (pb.cur_block < 0 || pb.cur_block >= pb.fn.block_count) { return null; }
    PInst* ins = pblock_push(&pb.fn.blocks[pb.cur_block]);
    if (ins == null) { pb_fail(pb, 0, 0, (char*)"out of memory building the middle representation"); return null; }
    ins.op = op;
    return ins;
}

fn bool pb_terminated(PBuilder* pb)
{
    if (pb == null || pb.fn == null || pb.cur_block < 0) { return true; }
    PBlock* b = &pb.fn.blocks[pb.cur_block];
    if (b.count == 0) { return false; }
    POp last = b.code[b.count - 1].op;
    return last == PO_JMP || last == PO_BR || last == PO_RET;
}

fn int pb_push_binding(PBuilder* pb, char* name, int slot, int width, bool sign, bool is_ptr)
{
    if (pb == null || name == null) { return -1; }
    if (pb.binding_count >= 512) { pb_fail(pb, 0, 0, (char*)"more than 512 bindings in scope"); return -1; }
    PBinding* b = &pb.bindings[pb.binding_count];
    b.name = name;
    b.slot = slot;
    b.vreg = -1;
    b.defined_in = -1;
    b.width = width;
    b.sign = sign;
    b.is_ptr = is_ptr;
    pb.binding_count++;
    return pb.binding_count - 1;
}

fn int pb_find(PBuilder* pb, char* name)
{
    if (pb == null || name == null) { return -1; }
    long i = (long)pb.binding_count - 1;
    while (i >= 0)
    {
        if (same(pb.bindings[(usz)i].name, name)) { return (int)i; }
        i--;
    }
    return -1;
}

// pb_read -- the value of a binding as a vreg, valid in the current block.
//
// The cache is the whole trick: a binding keeps the vreg it was produced in as
// long as we stay in the block that produced it. Stepping into any other block
// reloads from the slot, which is what makes loop headers correct on the second
// iteration and what makes a `jump` argument visible to the block it enters.
fn int pb_read(PBuilder* pb, char* name, int line, int col)
{
    int i = pb_find(pb, name);
    if (i < 0) { pb_fail(pb, line, col, (char*)"use of a name this stage cannot resolve to a binding"); return -1; }
    PBinding* b = &pb.bindings[(usz)i];
    if (b.vreg >= 0 && b.defined_in == pb.cur_block) { return b.vreg; }
    PInst* load = pb_emit(pb, PO_LOAD);
    if (load == null) { return -1; }
    int dst = pvreg_new(pb);
    if (dst < 0) { return -1; }
    load.dst = dst;
    load.imm = (long)b.slot;
    load.width = b.width;
    load.sign = b.sign;
    b.vreg = dst;
    b.defined_in = pb.cur_block;
    return dst;
}

// pb_bind -- give `name` the value currently in `value` and make that value
// authoritative for the rest of the block.
fn bool pb_bind(PBuilder* pb, char* name, int value, int width, bool sign, bool is_ptr)
{
    if (pb == null || name == null || value < 0) { return false; }
    int existing = pb_find(pb, name);
    int slot = -1;
    if (existing >= 0)
    {
        slot = pb.bindings[(usz)existing].slot;
    }
    else
    {
        slot = pslot_new(pb, width);
        if (slot < 0) { return false; }
        if (pb_push_binding(pb, name, slot, width, sign, is_ptr) < 0) { return false; }
    }
    PInst* store = pb_emit(pb, PO_STORE);
    if (store == null) { return false; }
    store.a = value;
    store.imm = (long)slot;
    store.width = width;
    // Cache the binding in this block so a straight-line read after the binding
    // does not have to reload what it just stored.
    int idx = pb_find(pb, name);
    if (idx >= 0)
    {
        pb.bindings[(usz)idx].vreg = value;
        pb.bindings[(usz)idx].defined_in = pb.cur_block;
    }
    return true;
}

// ── width and type helpers ─────────────────────────────────────────────────

// p_width_of -- the machine width of an AIR type, or 0 when this stage does not
// model it. Scalars only: aggregates need a memory model that PIR does not have
// yet, and pointers are 64-bit addresses with no provenance in this stage.
fn int p_width_of(AirTyp* t)
{
    if (t == null) { return 64; }
    if (m1_bool_type(t)) { return 8; }
    if (m1_pointer_type(t) || t.tag == ATYP_FN) { return 64; }
    if (m1_integer_type(t))
    {
        int bits = m1_int_bits(t);
        if (bits <= 8) { return 8; }
        if (bits <= 16) { return 16; }
        if (bits <= 32) { return 32; }
        return 64;
    }
    return 0;
}

fn bool p_signed_of(AirTyp* t)
{
    if (t == null) { return true; }
    if (m1_bool_type(t) || m1_pointer_type(t)) { return false; }
    return !m1_unsigned(t);
}

// ── producers ──────────────────────────────────────────────────────────────

fn int pb_prd(PBuilder* pb, AirPrd* p, int width, bool sign);

// pb_binop -- map an AIR binary operator onto PIR. The predicate is chosen from
// the operator *and* the operand signedness, because AIR spells `lt` once and
// the type decides whether that is a signed or an unsigned comparison.
fn bool pb_binop_op(PPred* out, AirBinop bop, bool sign)
{
    if (out == null) { return false; }
    switch (bop)
    {
        case ABIN_EQ: *out = PP_EQ; return true;
        case ABIN_NEQ: *out = PP_NE; return true;
        case ABIN_LT: *out = sign ? PP_LT : PP_ULT; return true;
        case ABIN_LE: *out = sign ? PP_LE : PP_ULE; return true;
        case ABIN_GT: *out = sign ? PP_GT : PP_UGT; return true;
        case ABIN_GE: *out = sign ? PP_GE : PP_UGE; return true;
        default: return false;
    }
}

fn bool pb_arith_op(POp* out, AirBinop bop, bool sign)
{
    if (out == null) { return false; }
    switch (bop)
    {
        case ABIN_ADD: *out = PO_ADD; return true;
        case ABIN_SUB: *out = PO_SUB; return true;
        case ABIN_MUL: *out = PO_MUL; return true;
        case ABIN_DIV: *out = sign ? PO_DIVS : PO_DIVU; return true;
        case ABIN_MOD: *out = sign ? PO_REMS : PO_REMU; return true;
        case ABIN_AND: *out = PO_AND; return true;
        case ABIN_OR: *out = PO_OR; return true;
        case ABIN_XOR: *out = PO_XOR; return true;
        case ABIN_SHL: *out = PO_SHL; return true;
        case ABIN_SHR: *out = sign ? PO_SAR : PO_SHR; return true;
        // The value forms of `land`/`lor` are not short-circuit: AIR evaluates
        // both operands and combines them, which for booleans stored as 0/1 is
        // exactly a bitwise and/or. air_ll.c3 emits `and i1`/`or i1` for the same
        // reason, so the two backends agree.
        case ABIN_LAND: *out = PO_AND; return true;
        case ABIN_LOR: *out = PO_OR; return true;
        default: return false;
    }
}

// pb_prd -- lower one producer to a vreg. `width` and `sign` come from the
// context (the binding it will be stored into, or the call signature); AIR
// producers carry only a hint, and the hint is used when it is concrete.
fn int pb_prd(PBuilder* pb, AirPrd* p, int width, bool sign)
{
    if (pb == null || p == null) { return -1; }
    if (pb.failed) { return -1; }
    AirTyp* hint = p.ty;
    if (hint != null && hint.tag != ATYP_INFER)
    {
        int w = p_width_of(hint);
        if (w > 0) { width = w; sign = p_signed_of(hint); }
    }
    if (p.tag == APRD_INT)
    {
        PInst* ins = pb_emit(pb, PO_CONST);
        if (ins == null) { return -1; }
        int dst = pvreg_new(pb);
        ins.dst = dst;
        ins.imm = p.ival;
        ins.width = width;
        return dst;
    }
    if (p.tag == APRD_BOOL)
    {
        PInst* ins = pb_emit(pb, PO_CONST);
        if (ins == null) { return -1; }
        int dst = pvreg_new(pb);
        ins.dst = dst;
        ins.imm = p.bval ? 1 : 0;
        ins.width = 8;
        return dst;
    }
    if (p.tag == APRD_CHAR)
    {
        PInst* ins = pb_emit(pb, PO_CONST);
        if (ins == null) { return -1; }
        int dst = pvreg_new(pb);
        ins.dst = dst;
        ins.imm = (long)p.cval;
        ins.width = 32;
        sign = false;
        return dst;
    }
    if (p.tag == APRD_VAR) { return pb_read(pb, p.name, p.source_line, p.source_col); }
    if (p.tag == APRD_BINOP && p.sub_count == 2 && p.subs[0] != null && p.subs[1] != null)
    {
        PPred pred = PP_EQ;
        if (pb_binop_op(&pred, p.bop, sign))
        {
            // A comparison first tries the immediate form: comparing against a
            // literal is the most common shape in AIR, and it is one machine
            // instruction instead of a materialized constant plus a register
            // compare.
            if (p.subs[1].tag == APRD_INT)
            {
                int left = pb_prd(pb, p.subs[0], width, sign);
                if (left < 0) { return -1; }
                PInst* ins = pb_emit(pb, PO_CMPI);
                if (ins == null) { return -1; }
                int dst = pvreg_new(pb);
                ins.dst = dst;
                ins.a = left;
                ins.imm = p.subs[1].ival;
                ins.pred = pred;
                ins.width = width;
                ins.sign = sign;
                return dst;
            }
            int left = pb_prd(pb, p.subs[0], width, sign);
            int right = pb_prd(pb, p.subs[1], width, sign);
            if (left < 0 || right < 0) { return -1; }
            PInst* ins = pb_emit(pb, PO_CMP);
            if (ins == null) { return -1; }
            int dst = pvreg_new(pb);
            ins.dst = dst;
            ins.a = left;
            ins.b = right;
            ins.pred = pred;
            ins.width = width;
            ins.sign = sign;
            return dst;
        }
        POp op = PO_ADD;
        if (pb_arith_op(&op, p.bop, sign))
        {
            int left = pb_prd(pb, p.subs[0], width, sign);
            int right = pb_prd(pb, p.subs[1], width, sign);
            if (left < 0 || right < 0) { return -1; }
            PInst* ins = pb_emit(pb, op);
            if (ins == null) { return -1; }
            int dst = pvreg_new(pb);
            ins.dst = dst;
            ins.a = left;
            ins.b = right;
            ins.width = width;
            ins.sign = sign;
            return dst;
        }
        pb_fail(pb, p.source_line, p.source_col, (char*)"binary operator outside the native subset");
        return -1;
    }
    if (p.tag == APRD_UNOP && p.sub_count == 1 && p.subs[0] != null)
    {
        if (p.uop == AUN_NEG)
        {
            int operand = pb_prd(pb, p.subs[0], width, sign);
            if (operand < 0) { return -1; }
            PInst* ins = pb_emit(pb, PO_NEG);
            if (ins == null) { return -1; }
            int dst = pvreg_new(pb);
            ins.dst = dst;
            ins.a = operand;
            ins.width = width;
            ins.sign = sign;
            return dst;
        }
        if (p.uop == AUN_NOT)
        {
            // Logical not is `xor 1` on a boolean. It is *not* the bitwise NOT:
            // a 64-bit `not` of 0 gives -1, which is non-zero and would make the
            // branch that consumes it take the wrong edge. The operand must be a
            // boolean, which is what AIR's own type rule for AUN_NOT says.
            AirTyp* ot = p.subs[0].ty;
            bool is_bool = (ot != null && ot.tag == ATYP_BOOL) || width == 1;
            if (!is_bool)
            {
                pb_fail(pb, p.source_line, p.source_col, (char*)"logical not of a non-boolean");
                return -1;
            }
            int operand = pb_prd(pb, p.subs[0], 8, false);
            if (operand < 0) { return -1; }
            PInst* one = pb_emit(pb, PO_CONST);
            if (one == null) { return -1; }
            int one_reg = pvreg_new(pb);
            if (one_reg < 0) { return -1; }
            one.dst = one_reg;
            one.imm = 1;
            one.width = 8;
            PInst* ins = pb_emit(pb, PO_XOR);
            if (ins == null) { return -1; }
            int dst = pvreg_new(pb);
            if (dst < 0) { return -1; }
            ins.dst = dst;
            ins.a = operand;
            ins.b = one_reg;
            ins.width = 8;
            ins.sign = false;
            return dst;
        }
        if (p.uop == AUN_BITNOT)
        {
            int operand = pb_prd(pb, p.subs[0], width, sign);
            if (operand < 0) { return -1; }
            PInst* ins = pb_emit(pb, PO_NOT);
            if (ins == null) { return -1; }
            int dst = pvreg_new(pb);
            ins.dst = dst;
            ins.a = operand;
            ins.width = width;
            ins.sign = sign;
            return dst;
        }
        pb_fail(pb, p.source_line, p.source_col, (char*)"unary operator outside the native subset");
        return -1;
    }
    if (p.tag == APRD_COERCE && p.sub_count == 1 && p.subs[0] != null)
    {
        // A coercion that does not change the machine width is a no-op in PIR;
        // a narrowing or widening one is a copy whose width annotation tells the
        // machine layer to truncate or extend.
        AirTyp* target = p.ty;
        int new_width = p_width_of(target);
        if (new_width == 0) { pb_fail(pb, p.source_line, p.source_col, (char*)"coercion target outside the native subset"); return -1; }
        int operand = pb_prd(pb, p.subs[0], new_width, p_signed_of(target));
        if (operand < 0) { return -1; }
        if (new_width == width) { return operand; }
        PInst* ins = pb_emit(pb, PO_COPY);
        if (ins == null) { return -1; }
        int dst = pvreg_new(pb);
        ins.dst = dst;
        ins.a = operand;
        ins.width = new_width;
        ins.sign = p_signed_of(target);
        return dst;
    }
    pb_fail(pb, p.source_line, p.source_col, (char*)"producer outside the native subset");
    return -1;
}

// ── commands ───────────────────────────────────────────────────────────────


fn bool pb_cmd(PBuilder* pb, AirCmd* c, char* ret_name);
fn bool pb_call(PBuilder* pb, AirCmd* c, AirCns* k, char* ret_name);

// pb_cond -- a producer in condition position. PIR branches test a value for
// non-zero, so a boolean value is already the right shape; a comparison lowers
// to the 0/1 form the CMP instructions produce.
fn int pb_cond(PBuilder* pb, AirPrd* p, int line, int col)
{
    if (p == null) { pb_fail(pb, line, col, (char*)"malformed condition"); return -1; }
    return pb_prd(pb, p, 8, false);
}

fn bool pb_seq(PBuilder* pb, AirCmd* c, char* ret_name)
{
    while (c != null)
    {
        if (!pb_cmd(pb, c, ret_name)) { return false; }
        if (pb_terminated(pb)) { return true; }
        c = c.next;
    }
    return true;
}

// pb_cut -- a cut, which in AIR is the one command shape that carries both a
// branch and a call. The consumer decides which:
//
//   x | return          the covariable of the enclosing function: a return;
//   x | comu v. body    bind the value and continue in the same block;
//   f(args)             ACNS_CALL: a call, whose result is bound by the comu that
//                        closes the argument chain (or returned when it is the
//                        return covariable).
//
// Everything else -- a projection, an index, a store, a field, a case -- is a
// consumer PIR does not model yet and is refused with the consumer's own name so
// the diagnostic says which construct was hit.
fn bool pb_cut(PBuilder* pb, AirCmd* c, char* ret_name)
{
    if (c.cns == null) { pb_fail(pb, c.source_line, c.source_col, (char*)"cut without a continuation"); return false; }
    AirCns* k = c.cns;
    int steps = 0;
    while (k != null && k.tag == ACNS_ASCRIBE && steps < 16) { k = k.tail; steps++; }
    if (k == null)
    {
        return pb_fail(pb, c.source_line, c.source_col, (char*)"cut to an erased continuation");
    }
    if (k.tag == ACNS_COVAR)
    {
        // A cut to a covariable is a return. This is not a guess: the low profile
        // has exactly one covariable in scope -- the enclosing function's return
        // -- and air_ll.c3 emits a `ret` for every ACNS_COVAR without looking at
        // the name. Matching that here is what keeps the two backends in step; a
        // name check would reject legal code the LLVM path accepts.
        // The value is optional: a unit function returns before it has anything
        // to return, and AIR states that as a bare cut.
        if (pb.fn.ret_unit || c.prd == null)
        {
            PInst* ins = pb_emit(pb, PO_RET);
            return ins != null;
        }
        int value = pb_prd(pb, c.prd, pb.fn.ret_width, pb.fn.ret_sign);
        if (value < 0) { return false; }
        PInst* ins = pb_emit(pb, PO_RET);
        if (ins == null) { return false; }
        ins.a = value;
        ins.width = pb.fn.ret_width;
        return true;
    }
    if (k.tag == ACNS_COMU)
    {
        // `value | comu v. body`: bind and keep going. Nothing is emitted: the
        // binding is a name for a vreg, and PIR is not SSA-critical here.
        int value = pb_prd(pb, c.prd, 64, true);
        if (value < 0) { return false; }
        if (!pb_bind(pb, k.bind, value, 64, true, true)) { return false; }
        return pb_cmd(pb, k.body, ret_name);
    }
    if (k.tag == ACNS_CALL) { return pb_call(pb, c, k, ret_name); }
    return pb_fail(pb, c.source_line, c.source_col, (char*)"cut consumer outside the native subset (only return, comu and call are modelled)");
}

// pb_call -- `cut` to an ACNS_CALL. The callee is a producer (a direct symbol in
// the subset), the arguments are an ACNS_STACK chain, and the node after the
// arguments is either a comu that binds the result or the return covariable.
//
// Only direct calls are accepted: an indirect call would need the closure
// representation and a register-indirect call form, and neither exists in this
// stage. A varargs call is accepted because the System V ABI passes varargs in
// the same registers as named arguments, with AL holding the vector count -- and
// this backend passes no vector arguments, so AL is zero.
fn bool pb_call(PBuilder* pb, AirCmd* c, AirCns* k, char* ret_name)
{
    if (c.prd == null || c.prd.tag != APRD_VAR || c.prd.name == null)
    {
        return pb_fail(pb, c.source_line, c.source_col, (char*)"indirect call outside the native subset");
    }
    int[6] args;
    int argc = 0;
    AirCns* cur = k.tail;
    while (cur != null && cur.tag == ACNS_STACK)
    {
        if (argc >= 6)
        {
            return pb_fail(pb, c.source_line, c.source_col, (char*)"call with more than 6 arguments is outside the native subset");
        }
        if (cur.prd == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"call argument is missing"); }
        int v = pb_prd(pb, cur.prd, 64, true);
        if (v < 0) { return false; }
        args[argc] = v;
        argc++;
        cur = cur.tail;
    }
    bool returns_value = cur != null && cur.tag == ACNS_COMU;
    bool returns_directly = cur != null && cur.tag == ACNS_COVAR && same(cur.name, ret_name);
    if (!returns_value && !returns_directly)
    {
        return pb_fail(pb, c.source_line, c.source_col, (char*)"call continuation outside the native subset (expected a comu or a return)");
    }
    PInst* call = pb_emit(pb, PO_CALL);
    if (call == null) { return false; }
    call.callee = c.prd.name;
    call.argc = argc;
    for (int i = 0; i < argc; i++) { call.args[i] = args[i]; }
    call.dst = -1;
    if (returns_directly)
    {
        // A call in return position is the ordinary shape of every function that
        // ends in `f(x)`. It is emitted as a call followed by a return, not as a
        // tail jump: PIR has no tail marker yet (that is a later pass), and a
        // call+ret is always correct.
        PInst* ins = pb_emit(pb, PO_RET);
        if (ins == null) { return false; }
        if (!pb.fn.ret_unit)
        {
            int dst = pvreg_new(pb);
            if (dst < 0) { return false; }
            call.dst = dst;
            ins.a = dst;
            ins.width = pb.fn.ret_width;
        }
        return true;
    }
    int dst = pvreg_new(pb);
    if (dst < 0) { return false; }
    call.dst = dst;
    // The result's type is not on the continuation, so it is bound as a 64-bit
    // value. That is the widest case and the one a pointer also satisfies; a
    // narrower consumer truncates at its own use site.
    if (!pb_bind(pb, cur.bind, dst, 64, true, true)) { return false; }
    return pb_cmd(pb, cur.body, ret_name);
}

fn bool pb_if(PBuilder* pb, AirCmd* c, char* ret_name)
{
    int cond = pb_cond(pb, c.prd, c.source_line, c.source_col);
    if (cond < 0) { return false; }
    PBlock* then_block = pblock_new(pb.fn, (char*)"if.then");
    PBlock* else_block = pblock_new(pb.fn, (char*)"if.else");
    PBlock* join_block = pblock_new(pb.fn, (char*)"if.join");
    if (then_block == null || else_block == null || join_block == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"out of memory"); }
    PInst* br = pb_emit(pb, PO_BR);
    if (br == null) { return false; }
    br.a = cond;
    br.target = then_block.id;
    br.target2 = else_block.id;
    pb.cur_block = then_block.id;
    if (!pb_cmd(pb, c.then_c, ret_name)) { return false; }
    bool then_falls = !pb_terminated(pb);
    if (then_falls)
    {
        PInst* j = pb_emit(pb, PO_JMP);
        if (j == null) { return false; }
        j.target = join_block.id;
    }
    pb.cur_block = else_block.id;
    if (!pb_cmd(pb, c.else_c, ret_name)) { return false; }
    bool else_falls = !pb_terminated(pb);
    if (else_falls)
    {
        PInst* j = pb_emit(pb, PO_JMP);
        if (j == null) { return false; }
        j.target = join_block.id;
    }
    if (!then_falls && !else_falls)
    {
        // Both arms transfer control, so the join is unreachable. Leaving the
        // current block as the else arm is what makes the enclosing sequence stop
        // instead of emitting into a dead block.
        return true;
    }
    pb.cur_block = join_block.id;
    return true;
}

// pb_while -- kept for AIR that still carries a `while` node. The low profile
// prefer-lowers loops to labels and jumps, so this path is the exception: the
// header is entered by a jump, the condition is re-evaluated there, and the body
// edges back to the header.
fn bool pb_while(PBuilder* pb, AirCmd* c, char* ret_name)
{
    PBlock* header = pblock_new(pb.fn, (char*)"while.header");
    PBlock* body = pblock_new(pb.fn, (char*)"while.body");
    PBlock* exit_block = pblock_new(pb.fn, (char*)"while.exit");
    if (header == null || body == null || exit_block == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"out of memory"); }
    PInst* entry_jump = pb_emit(pb, PO_JMP);
    if (entry_jump == null) { return false; }
    entry_jump.target = header.id;
    pb.cur_block = header.id;
    int cond = pb_cond(pb, c.prd, c.source_line, c.source_col);
    if (cond < 0) { return false; }
    PInst* br = pb_emit(pb, PO_BR);
    if (br == null) { return false; }
    br.a = cond;
    br.target = body.id;
    br.target2 = exit_block.id;
    pb.cur_block = body.id;
    if (!pb_cmd(pb, c.body, ret_name)) { return false; }
    if (!pb_terminated(pb))
    {
        PInst* back = pb_emit(pb, PO_JMP);
        if (back == null) { return false; }
        back.target = header.id;
    }
    pb.cur_block = exit_block.id;
    return true;
}

// pb_find_block -- the block a `jump` or `break` names, or -1. Labels are peeled
// off the spine before the entry body is built, so every legal jump target exists
// by the time any jump is lowered; a miss here is a real error, not a forward
// reference the builder has not seen yet.
fn int pb_find_block(PBuilder* pb, char* name)
{
    if (pb == null || name == null || pb.fn == null) { return -1; }
    for (int i = 0; i < pb.fn.block_count; i++)
    {
        if (pb.fn.blocks[i].name != null && same(pb.fn.blocks[i].name, name)) { return i; }
    }
    return -1;
}

// pb_jump -- emit an edge with AIR's jump arguments. The arguments are *names*
// (AIR passes bindings, not expressions), so this is a parallel copy: every
// source value is read into a fresh vreg first, and only then written into the
// destination block's parameter slots. Reading everything before writing
// anything is what keeps a self-edge correct when an argument and a parameter
// happen to be the same binding.
fn bool pb_jump(PBuilder* pb, AirCmd* c, char* ret_name)
{
    if (c.target_label == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"jump without a target"); }
    int target = pb_find_block(pb, c.target_label);
    if (target < 0) { return pb_fail(pb, c.source_line, c.source_col, (char*)"jump to an undeclared label"); }
    PBlock* dest = &pb.fn.blocks[target];
    if (c.jump_arg_count != (usz)dest.param_count)
    {
        return pb_fail(pb, c.source_line, c.source_col, (char*)"jump argument count does not match the label's parameters");
    }
    int[16] values;
    for (usz i = 0; i < c.jump_arg_count && i < 16; i++)
    {
        if (c.jump_args[i] == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"jump argument without a name"); }
        values[i] = pb_read(pb, c.jump_args[i], c.source_line, c.source_col);
        if (values[i] < 0) { return false; }
    }
    for (usz i = 0; i < c.jump_arg_count && i < 16; i++)
    {
        PInst* store = pb_emit(pb, PO_STORE);
        if (store == null) { return false; }
        store.a = values[i];
        store.imm = (long)dest.param_slots[i];
    }
    PInst* ins = pb_emit(pb, PO_JMP);
    if (ins == null) { return false; }
    ins.target = target;
    return true;
}

// pb_match -- scalar dispatch, the subset of AIR's match this stage models.
//
// Three shapes cover almost every match that reaches the backend:
//   * one arm whose pattern cannot test anything (`_`, `tuple()`, `bind x`) is
//     not a dispatch at all -- the body runs unconditionally;
//   * literal integer/bool/char arms become a compare-and-branch chain, which is
//     what a switch degrades to anyway once the arms are sparse;
//   * anything else (guards, record/tuple destructuring, cobranches) needs the
//     full pattern compiler and is refused here.
//
// The chain is built from the front: each test block compares the scrutinee
// against one literal and branches either to its arm or to the next test. The
// final miss goes to a join block that is only emitted when some arm falls
// through to it.
fn bool pb_match(PBuilder* pb, AirCmd* c, char* ret_name)
{
    // AirCmd carries `branches` only: cobranches live on the continuation
    // (ACNS_COCASE), so a cobranch match never reaches this builder as a command
    // with arms. An armless match is not dispatch and is refused here.
    if (c.branch_count == 0)
    {
        return pb_fail(pb, c.source_line, c.source_col, (char*)"match shape outside the native subset");
    }
    bool trivial = c.branch_count == 1 && c.branches[0] != null && c.branches[0].guard == null &&
                   c.branches[0].pat != null &&
                   (c.branches[0].pat.tag == APAT_WILD || c.branches[0].pat.tag == APAT_BIND ||
                    (c.branches[0].pat.tag == APAT_TUPLE && c.branches[0].pat.sub_count == 0));
    if (trivial)
    {
        AirBranch* arm = c.branches[0];
        int scrutinee = pb_prd(pb, c.prd, 32, true);
        if (scrutinee < 0) { return false; }
        if (arm.pat.tag == APAT_BIND)
        {
            if (!pb_bind(pb, arm.pat.name, scrutinee, 32, true, false)) { return false; }
        }
        return pb_cmd(pb, arm.body, ret_name);
    }
    int scrutinee = pb_prd(pb, c.prd, 32, true);
    if (scrutinee < 0) { return false; }
    PBlock* join_block = pblock_new(pb.fn, (char*)"match.join");
    if (join_block == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"out of memory"); }
    bool any_falls = false;
    int test_block = pb.cur_block;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* arm = c.branches[i];
        if (arm == null || arm.pat == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"malformed match arm"); }
        if (arm.guard != null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"match guards are outside the native subset"); }
        bool is_last = (i + 1) >= c.branch_count;
        bool catch_all = arm.pat.tag == APAT_WILD || arm.pat.tag == APAT_BIND ||
                         (arm.pat.tag == APAT_TUPLE && arm.pat.sub_count == 0);
        bool literal = arm.pat.tag == APAT_INT || arm.pat.tag == APAT_BOOL || arm.pat.tag == APAT_CHAR;
        if (!catch_all && !literal)
        {
            return pb_fail(pb, c.source_line, c.source_col, (char*)"match pattern outside the native subset");
        }
        if (catch_all && !is_last)
        {
            return pb_fail(pb, c.source_line, c.source_col, (char*)"a catch-all match arm must be last");
        }
        PBlock* arm_block = pblock_new(pb.fn, (char*)"match.arm");
        if (arm_block == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"out of memory"); }
        PBlock* next_test = null;
        if (!is_last)
        {
            next_test = pblock_new(pb.fn, (char*)"match.test");
            if (next_test == null) { return pb_fail(pb, c.source_line, c.source_col, (char*)"out of memory"); }
        }
        pb.cur_block = test_block;
        if (catch_all)
        {
            if (arm.pat.tag == APAT_BIND)
            {
                if (!pb_bind(pb, arm.pat.name, scrutinee, 32, true, false)) { return false; }
            }
            PInst* j = pb_emit(pb, PO_JMP);
            if (j == null) { return false; }
            j.target = arm_block.id;
        }
        else
        {
            PInst* test = pb_emit(pb, PO_CMPI);
            if (test == null) { return false; }
            int dst = pvreg_new(pb);
            if (dst < 0) { return false; }
            test.dst = dst;
            test.a = scrutinee;
            test.imm = arm.pat.tag == APAT_BOOL ? (arm.pat.ival != 0 ? 1 : 0) : arm.pat.ival;
            test.pred = PP_EQ;
            test.width = 32;
            test.sign = true;
            PInst* br = pb_emit(pb, PO_BR);
            if (br == null) { return false; }
            br.a = dst;
            br.target = arm_block.id;
            br.target2 = next_test != null ? next_test.id : join_block.id;
        }
        pb.cur_block = arm_block.id;
        if (!pb_cmd(pb, arm.body, ret_name)) { return false; }
        if (!pb_terminated(pb))
        {
            PInst* j = pb_emit(pb, PO_JMP);
            if (j == null) { return false; }
            j.target = join_block.id;
            any_falls = true;
        }
        if (next_test == null) { test_block = -1; }
        else { test_block = next_test.id; }
    }
    if (!any_falls)
    {
        // Every arm transferred control, so the join is unreachable and nothing
        // is emitted into it. The builder stays in the last arm, which is
        // terminated, so the enclosing sequence stops here.
        return true;
    }
    pb.cur_block = join_block.id;
    return true;
}

fn bool pb_cmd(PBuilder* pb, AirCmd* c, char* ret_name)
{
    if (pb == null || pb.failed) { return false; }
    if (c == null) { return true; }
    switch (c.tag)
    {
        case ACMD_NOP:
            return true;
        case ACMD_BLOCK: case ACMD_UNSAFE: case ACMD_UNCHECKED:
            return pb_cmd(pb, c.body, ret_name);
        case ACMD_SEQ:
            if (!pb_cmd(pb, c.body, ret_name)) { return false; }
            if (pb_terminated(pb)) { return true; }
            return pb_seq(pb, c.next, ret_name);
        case ACMD_MU: case ACMD_MUTILDE:
            return pb_cmd(pb, c.body, ret_name);
        case ACMD_LET:
        {
            int width = 32;
            bool sign = true;
            AirTyp* hint = c.prd != null ? c.prd.ty : null;
            int w = p_width_of(hint);
            if (w > 0) { width = w; sign = p_signed_of(hint); }
            int value = pb_prd(pb, c.prd, width, sign);
            if (value < 0) { return false; }
            if (!pb_bind(pb, c.binder, value, width, sign, m1_pointer_type(hint))) { return false; }
            // AIR's `let` carries its continuation in `body`, not in `next`: the
            // binding is in scope for exactly that subtree.
            return pb_cmd(pb, c.body, ret_name);
        }
        case ACMD_CUT:
            return pb_cut(pb, c, ret_name);
        case ACMD_RET:
        {
            PInst* ins = pb_emit(pb, PO_RET);
            if (ins == null) { return false; }
            if (c.prd != null && !pb.fn.ret_unit)
            {
                int value = pb_prd(pb, c.prd, pb.fn.ret_width, pb.fn.ret_sign);
                if (value < 0) { return false; }
                ins.a = value;
                ins.width = pb.fn.ret_width;
            }
            return true;
        }
        case ACMD_IF:
            return pb_if(pb, c, ret_name);
        case ACMD_WHILE:
            return pb_while(pb, c, ret_name);
        case ACMD_JUMP:
            return pb_jump(pb, c, ret_name);
        case ACMD_MATCH:
            return pb_match(pb, c, ret_name);
        case ACMD_LABEL:
            // Labels are peeled off the spine by pfunc_build; a label nested in a
            // body is not a construct the low profile produces, and emitting it
            // inline would silently reorder the function.
            return pb_fail(pb, c.source_line, c.source_col, (char*)"a label nested inside a body is outside the native subset");
        case ACMD_BREAK: case ACMD_CONTINUE:
            return pb_fail(pb, c.source_line, c.source_col, (char*)"break/continue must be lowered to a jump before this stage");
        default:
            return pb_fail(pb, c.source_line, c.source_col, (char*)"command outside the native subset");
    }
}

// ── function entry point ───────────────────────────────────────────────────

// pfunc_peel_label -- turn one spine label into a block with parameters. The
// parameters get slots here; their *names* are bound only while the block's own
// body is built, because two labels in one function may use the same parameter
// name and a single flat scope would make the second shadow the first.
fn bool pfunc_peel_label(PBuilder* pb, AirCmd* lb)
{
    if (pb == null || pb.fn == null || lb == null) { return false; }
    PBlock* block = pblock_new(pb.fn, lb.binder);
    if (block == null) { return pb_fail(pb, lb.source_line, lb.source_col, (char*)"out of memory"); }
    for (usz i = 0; i < lb.mbinder_count && i < 16; i++)
    {
        AirBinder* b = lb.mbinders[i];
        if (b == null || b.name == null) { continue; }
        int width = p_width_of(b.ty);
        if (width == 0) { return pb_fail(pb, lb.source_line, lb.source_col, (char*)"label parameter type outside the native subset"); }
        int slot = pslot_new(pb, width);
        if (slot < 0) { return false; }
        int k = block.param_count;
        block.param_names[k] = b.name;
        block.param_slots[k] = slot;
        block.param_widths[k] = width;
        block.param_signs[k] = p_signed_of(b.ty);
        block.param_ptrs[k] = m1_pointer_type(b.ty);
        block.param_count++;
    }
    return true;
}

// pfunc_build -- AIR declaration to PIR function.
//
// The layout this walks is the one air_low.c3's assemble() produces:
//
//     seq { label L1(p). body1 ; seq { label L2. body2 ; entry } }
//
// Every non-entry block is a label prepended to the spine, so the entry commands
// come *last*. Walking that inline would run the label bodies first, which is why
// the labels are peeled into blocks (with their own parameter slots) and the
// entry body is built afterwards. A jump into a block stores the arguments into
// that block's parameter slots; the block's body reloads them.
fn bool pfunc_build(AirDecl* d, PFunc* fn, PBuilder* pb)
{
    if (d == null || fn == null || pb == null) { return false; }
    fn.name = d.name;
    fn.is_public = d.is_pub;
    fn.block_count = 0;
    fn.vreg_count = 0;
    fn.slot_count = 0;
    fn.param_count = 0;
    pb.fn = fn;
    pb.binding_count = 0;
    pb.failed = false;
    pb.fail_line = d.source_line;
    pb.fail_col = d.source_col;

    // Return shape.
    AirTyp* rt = d.ret_ty;
    fn.ret_unit = rt == null || rt.tag == ATYP_UNIT || rt.tag == ATYP_BOTTOM || p_width_of(rt) == 0;
    fn.ret_width = fn.ret_unit ? 0 : p_width_of(rt);
    fn.ret_sign = fn.ret_unit ? true : p_signed_of(rt);
    fn.ret_ptr = fn.ret_unit ? false : m1_pointer_type(rt);

    PBlock* entry = pblock_new(fn, (char*)"entry");
    if (entry == null) { return pb_fail(pb, d.source_line, d.source_col, (char*)"out of memory"); }
    fn.entry = entry.id;

    // Parameters: one slot each, bound for the whole body. The machine layer
    // stores the incoming ABI registers into these slots in the prologue, which
    // is why they are the first slots in the frame.
    for (usz i = 0; i < d.param_count && i < 16; i++)
    {
        AirBinder* b = d.params[i];
        if (b == null || b.name == null) { continue; }
        int width = p_width_of(b.ty);
        if (width == 0) { return pb_fail(pb, d.source_line, d.source_col, (char*)"parameter type outside the native subset"); }
        int slot = pslot_new(pb, width);
        if (slot < 0) { return false; }
        PParam* p = &fn.params[fn.param_count];
        p.name = b.name;
        p.slot = slot;
        p.vreg = -1;
        p.width = width;
        p.sign = p_signed_of(b.ty);
        p.is_ptr = m1_pointer_type(b.ty);
        fn.param_count++;
        if (pb_push_binding(pb, b.name, slot, width, p_signed_of(b.ty), m1_pointer_type(b.ty)) < 0) { return false; }
    }

    // Peel the spine labels.
    AirCmd*[64] label_body;
    int[64] label_block;
    int[64] label_scope;
    int peeled = 0;
    AirCmd* c = d.def_body;
    while (c != null && c.tag == ACMD_SEQ && c.body != null && c.body.tag == ACMD_LABEL)
    {
        if (peeled >= 64) { return pb_fail(pb, c.source_line, c.source_col, (char*)"more than 64 labels in one function"); }
        if (!pfunc_peel_label(pb, c.body)) { return false; }
        label_body[peeled] = c.body.body;
        label_block[peeled] = pb.fn.block_count - 1;
        label_scope[peeled] = pb.binding_count;
        peeled++;
        c = c.next;
    }
    if (c != null && c.tag == ACMD_LABEL)
    {
        if (peeled >= 64) { return pb_fail(pb, c.source_line, c.source_col, (char*)"more than 64 labels in one function"); }
        if (!pfunc_peel_label(pb, c)) { return false; }
        label_body[peeled] = c.body;
        label_block[peeled] = pb.fn.block_count - 1;
        label_scope[peeled] = pb.binding_count;
        peeled++;
        c = null;
    }

    // The entry body.
    pb.cur_block = entry.id;
    if (!pb_cmd(pb, c, d.name)) { return false; }
    if (!pb_terminated(pb))
    {
        // Falling off the end of a unit function is legal in AIR and returns unit;
        // falling off a value function is not, and is reported rather than
        // silently returning whatever happened to be in RAX.
        if (!fn.ret_unit)
        {
            return pb_fail(pb, d.source_line, d.source_col, (char*)"function falls off its end without returning a value");
        }
        PInst* ins = pb_emit(pb, PO_RET);
        if (ins == null) { return false; }
    }

    // Label bodies, each in its own block with its parameters in scope.
    for (int i = 0; i < peeled; i++)
    {
        PBlock* block = &pb.fn.blocks[label_block[i]];
        int saved = pb.binding_count;
        for (int k = 0; k < block.param_count; k++)
        {
            if (pb_push_binding(pb, block.param_names[k], block.param_slots[k],
                                block.param_widths[k], block.param_signs[k], block.param_ptrs[k]) < 0) { return false; }
        }
        pb.cur_block = block.id;
        if (!pb_cmd(pb, label_body[i], d.name)) { return false; }
        if (!pb_terminated(pb))
        {
            if (!fn.ret_unit)
            {
                return pb_fail(pb, d.source_line, d.source_col, (char*)"label body falls off its end without transferring control");
            }
            PInst* ins = pb_emit(pb, PO_RET);
            if (ins == null) { return false; }
        }
        pb.binding_count = saved;
    }
    return !pb.failed;
}
