// PEAR 2 native pipeline, stage 4: PIR -> x86-64 machine code -> ELF object.
//
// This is the file that replaces the LLVM round trip. It reads PIR (never AIR,
// never text), walks each basic block once, and appends instructions to a byte
// buffer. There is no textual IR, no parser, no library call: the compiler's
// own bytes are the object file.
//
// How a value reaches a register:
//
//   * every virtual register owns a frame slot, which is what makes spilling
//     always legal;
//   * a vreg whose whole live range is inside one basic block competes for a
//     scratch register (R8-R11, RSI, RDI). RAX, RCX, and RDX stay out of the
//     pool because the divide instructions demand RAX:RDX and a shift demands
//     CL, and a value living there would have to be shuffled around them;
//   * when a call appears, every scratch register holding a value that is still
//     live afterwards is spilled first. This is the whole calling-convention
//     contract in one rule, and it is what keeps the allocator simple enough to
//     be obviously correct.
//
// What this stage deliberately does not do yet: no instruction scheduling, no
// loop-invariant hoisting, no constant rematerialisation, no register allocation
// *across* blocks. Those are passes over PIR, and the point of stopping here is
// that PIR is the seam where they belong -- a pass added to `pear2_cfg.c3`'s
// instruction set improves this file automatically.
module pear2c;
import air_ir;

extern fn void* malloc(usz size_);
extern fn void  free(void* ptr);
extern fn void* memset(void* dst, int value, usz n);
extern fn void* memcpy(void* dst, void* src, usz n);

// A branch whose displacement is patched once every block has an offset. The
// encoder cannot know a forward target's position while it is still emitting the
// block that branches to it.
struct NatPatch {
    usz at;         // offset of the 4-byte displacement field
    int block;      // target block id
}

struct NatGen {
    XBuf* text;
    PFunc* fn;
    int[64] block_offset;   // text offset of each block, -1 until emitted
    NatPatch[2048] patches;
    int patch_count;
    int[2048] vreg_slot;    // frame slot of each vreg
    int[2048] vreg_reg;     // scratch register holding each vreg, or -1
    int[2048] vreg_def_block;
    int[2048] vreg_last_block;
    int[2048] vreg_uses;
    int frame_bytes;
    bool failed;
    char* fail_message;
}

// The scratch pool. Six registers, all caller-saved, none of them required by a
// specific instruction (see the header comment for why RAX/RCX/RDX are absent).
const int[6] NAT_POOL = { R8, R9, R10, R11, RSI, RDI };

// ── analysis ───────────────────────────────────────────────────────────────

// nat_scan_uses -- record, for every vreg, where it is defined, where it is last
// used, and how many uses it has. A vreg never defined inside the function is a
// parameter: it is marked as defined in the entry block.
fn void nat_scan_uses(NatGen* g)
{
    if (g == null || g.fn == null) { return; }
    for (int v = 0; v < g.fn.vreg_count && v < 2048; v++)
    {
        g.vreg_def_block[(usz)v] = -1;
        g.vreg_last_block[(usz)v] = -1;
        g.vreg_uses[(usz)v] = 0;
        g.vreg_reg[(usz)v] = -1;
    }
    for (int b = 0; b < g.fn.block_count; b++)
    {
        PBlock* block = &g.fn.blocks[(usz)b];
        for (int i = 0; i < block.count; i++)
        {
            PInst* ins = &block.code[(usz)i];
            if (ins.dst >= 0 && ins.dst < 2048 && g.vreg_def_block[(usz)ins.dst] < 0) { g.vreg_def_block[(usz)ins.dst] = b; }
            int[6] inputs;
            int n = 0;
            if (ins.a >= 0) { inputs[n] = ins.a; n++; }
            if (ins.b >= 0) { inputs[n] = ins.b; n++; }
            for (int k = 0; k < ins.argc && k < 6; k++) { if (ins.args[k] >= 0) { inputs[n] = ins.args[k]; n++; } }
            for (int k = 0; k < n; k++)
            {
                int v = inputs[k];
                if (v < 0 || v >= 2048) { continue; }
                g.vreg_uses[(usz)v] = g.vreg_uses[(usz)v] + 1;
                g.vreg_last_block[(usz)v] = b;
            }
        }
    }
}

// nat_is_block_local -- can this vreg live in a register for its whole life? The
// answer is yes only when it is defined and last used inside the same block,
// because the allocator has no liveness information that crosses an edge.
fn bool nat_is_block_local(NatGen* g, int v)
{
    if (g == null || v < 0 || v >= 2048) { return false; }
    int def_block = g.vreg_def_block[(usz)v];
    int last_block = g.vreg_last_block[(usz)v];
    if (def_block < 0) { return false; }
    return def_block == last_block;
}

// nat_slot_of -- the frame slot of a vreg. Slots are laid out at negative
// offsets from RBP: slot 0 is at -8, slot 1 at -16, and so on, so a vreg's address
// is `-8 * (slot + 1)`.
fn XMem nat_slot_mem(NatGen* g, int slot)
{
    long disp = -8L * (long)(slot + 1);
    return xmem(RBP, disp);
}

// ── register pool management ───────────────────────────────────────────────

fn int nat_reg_holding(NatGen* g, int vreg)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return -1; }
    return g.vreg_reg[(usz)vreg];
}

fn int nat_reg_in_use(NatGen* g, int reg)
{
    for (int v = 0; v < g.fn.vreg_count && v < 2048; v++)
    {
        if (g.vreg_reg[(usz)v] == reg) { return v; }
    }
    return -1;
}

// nat_take_reg -- a free scratch register, spilling the oldest holder if every
// one is busy. The spill target is always the vreg's own slot, which exists for
// every vreg, so the choice of victim can never fail.
fn int nat_take_reg(NatGen* g)
{
    for (int i = 0; i < 6; i++)
    {
        if (nat_reg_in_use(g, NAT_POOL[(usz)i]) < 0) { return NAT_POOL[(usz)i]; }
    }
    // Every register is live: evict the first one and remember its value in its
    // slot, which the next use will reload.
    int victim_reg = NAT_POOL[0];
    int victim_vreg = nat_reg_in_use(g, victim_reg);
    if (victim_vreg >= 0)
    {
        x_mov_mr(g.text, nat_slot_mem(g, g.vreg_slot[(usz)victim_vreg]), victim_reg);
        g.vreg_reg[(usz)victim_vreg] = -1;
    }
    return victim_reg;
}

// nat_release -- a vreg is dead after this instruction: hand its register back
// and forget the mapping.
fn void nat_release(NatGen* g, int vreg)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return; }
    g.vreg_reg[(usz)vreg] = -1;
}

// nat_spill_live -- before a call, save every scratch register whose value is
// still needed afterwards. Caller-saved means exactly this: the callee may use
// these registers for anything.
fn void nat_spill_live(NatGen* g, int current_block, int from_index)
{
    if (g == null || g.fn == null) { return; }
    PBlock* block = &g.fn.blocks[(usz)current_block];
    for (int v = 0; v < g.fn.vreg_count && v < 2048; v++)
    {
        int reg = g.vreg_reg[(usz)v];
        if (reg < 0) { continue; }
        bool needed_later = g.vreg_last_block[(usz)v] != current_block;
        if (!needed_later)
        {
            // Same block: look for a use after the call.
            needed_later = false;
            for (int i = from_index; i < block.count; i++)
            {
                PInst* ins = &block.code[(usz)i];
                if (ins.a == v || ins.b == v) { needed_later = true; break; }
                bool in_args = false;
                for (int k = 0; k < ins.argc; k++) { if (ins.args[k] == v) { in_args = true; break; } }
                if (in_args) { needed_later = true; break; }
            }
        }
        if (needed_later)
        {
            x_mov_mr(g.text, nat_slot_mem(g, g.vreg_slot[(usz)v]), reg);
            g.vreg_reg[(usz)v] = -1;
        }
    }
}

// ── operand access ─────────────────────────────────────────────────────────

// nat_into_reg -- materialise a vreg into a specific register.
fn bool nat_into_reg(NatGen* g, int vreg, int reg)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return false; }
    int have = g.vreg_reg[(usz)vreg];
    if (have == reg) { return true; }
    if (have >= 0) { x_mov_rr(g.text, reg, have); return true; }
    x_mov_rm(g.text, reg, nat_slot_mem(g, g.vreg_slot[(usz)vreg]));
    return true;
}

// nat_operand_ready -- make a vreg usable as an ALU source register, returning
// the register that holds it. A block-local vreg gets a pool register on first
// use; anything else is loaded into a scratch that is not tracked (it is only
// valid until the next instruction, which is all the ALU needs).
fn int nat_operand_reg(NatGen* g, int vreg, int scratch)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return -1; }
    int have = g.vreg_reg[(usz)vreg];
    if (have >= 0) { return have; }
    x_mov_rm(g.text, scratch, nat_slot_mem(g, g.vreg_slot[(usz)vreg]));
    return scratch;
}

// nat_result_reg -- where a definition should be computed. A block-local vreg
// takes a pool register; anything else is computed in RAX and stored, because it
// has to survive a block boundary and a register would not.
fn int nat_result_reg(NatGen* g, int vreg)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return RAX; }
    if (!nat_is_block_local(g, vreg)) { return RAX; }
    int existing = g.vreg_reg[(usz)vreg];
    if (existing >= 0) { return existing; }
    int reg = nat_take_reg(g);
    g.vreg_reg[(usz)vreg] = reg;
    return reg;
}

// nat_finish_def -- if the value was computed in a register that does not own it
// (or that owns it only for this block), make the slot authoritative as well.
// A pooled register keeps its value; a non-local vreg is always stored.
fn void nat_finish_def(NatGen* g, int vreg, int computed_in)
{
    if (g == null || vreg < 0 || vreg >= 2048) { return; }
    if (g.vreg_reg[(usz)vreg] == computed_in) { return; }
    x_mov_mr(g.text, nat_slot_mem(g, g.vreg_slot[(usz)vreg]), computed_in);
}

// ── branches ───────────────────────────────────────────────────────────────

fn bool nat_patch_new(NatGen* g, usz at, int block)
{
    if (g == null) { return false; }
    if (g.patch_count >= 2048) { g.failed = true; return false; }
    g.patches[(usz)g.patch_count].at = at;
    g.patches[(usz)g.patch_count].block = block;
    g.patch_count++;
    return true;
}

fn void nat_jmp_to(NatGen* g, int block)
{
    if (g == null || g.text == null) { return; }
    usz before = g.text.len;
    xb8(g.text, 0xE9);
    usz at = g.text.len;
    xb32(g.text, 0);
    nat_patch_new(g, at, block);
    (void)before;
}

fn void nat_jcc_to(NatGen* g, int cc, int block)
{
    if (g == null || g.text == null) { return; }
    xb8(g.text, 0x0F);
    xb8(g.text, (u8)(0x80 + (cc & 0x0F)));
    usz at = g.text.len;
    xb32(g.text, 0);
    nat_patch_new(g, at, block);
}

// ── instruction selection ──────────────────────────────────────────────────

// nat_shift_by_cl -- shift count in CL, which is how x86 encodes a variable
// shift. The count vreg is placed in RCX for the instruction and nowhere else.
fn void nat_shift(NatGen* g, int digit, int dst, int value, int count, int scratch)
{
    if (g == null) { return; }
    int vreg = nat_operand_reg(g, value, dst == RAX ? R11 : RAX);
    nat_into_reg(g, count, RCX);
    if (dst == RAX) { x_shift_cl(g.text, digit, RAX); return; }
    if (vreg != dst) { x_mov_rr(g.text, dst, vreg); }
    x_shift_cl(g.text, digit, dst);
}

fn bool nat_cmp(NatGen* g, int dst, int a, int b, long imm, bool immediate, int pred)
{
    if (g == null) { return false; }
    int cc = x_cc_for_pred(pred);
    int work = dst == RAX ? R11 : RAX;
    if (immediate)
    {
        int left = nat_operand_reg(g, a, work);
        if (left != work) { x_mov_rr(g.text, work, left); }
        x_cmp_ri(g.text, work, imm);
    }
    else
    {
        int left = nat_operand_reg(g, a, work);
        int right = nat_operand_reg(g, b, work == RAX ? RCX : RAX);
        if (left != work) { x_mov_rr(g.text, work, left); }
        x_cmp_rr(g.text, work, right);
    }
    // setcc writes one byte; the upper bits of the destination are zeroed first
    // so the vreg holds exactly 0 or 1 and can be used as an integer directly.
    x_xor_rr(g.text, RAX, RAX);
    x_setcc(g.text, cc, RAX);
    if (dst != RAX) { x_mov_rr(g.text, dst, RAX); }
    return true;
}

fn bool nat_emit_inst(NatGen* g, int block, int index)
{
    if (g == null || g.fn == null) { return false; }
    PBlock* blk = &g.fn.blocks[(usz)block];
    PInst* ins = &blk.code[(usz)index];
    switch (ins.op)
    {
        case PO_CONST:
        {
            int dst = nat_result_reg(g, ins.dst);
            x_mov_ri(g.text, dst, ins.imm);
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_COPY:
        {
            int dst = nat_result_reg(g, ins.dst);
            nat_into_reg(g, ins.a, dst);
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_LOAD:
        {
            int dst = nat_result_reg(g, ins.dst);
            x_mov_rm(g.text, dst, nat_slot_mem(g, (int)ins.imm));
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_STORE:
        {
            int src = nat_operand_reg(g, ins.a, RAX);
            x_mov_mr(g.text, nat_slot_mem(g, (int)ins.imm), src);
            return true;
        }
        case PO_ADD: case PO_SUB: case PO_MUL: case PO_AND: case PO_OR: case PO_XOR:
        {
            int dst = nat_result_reg(g, ins.dst);
            int work = dst;
            int left = nat_operand_reg(g, ins.a, dst == R11 ? RAX : R11);
            if (left != work) { x_mov_rr(g.text, work, left); }
            if (ins.op == PO_MUL)
            {
                if (ins.b >= 0)
                {
                    int right = nat_operand_reg(g, ins.b, R11);
                    x_imul_rr(g.text, work, right);
                }
            }
            else
            {
                int right = nat_operand_reg(g, ins.b, work == R11 ? RAX : R11);
                if (ins.op == PO_ADD) { x_add_rr(g.text, work, right); }
                else if (ins.op == PO_SUB) { x_sub_rr(g.text, work, right); }
                else if (ins.op == PO_AND) { x_and_rr(g.text, work, right); }
                else if (ins.op == PO_OR) { x_or_rr(g.text, work, right); }
                else { x_xor_rr(g.text, work, right); }
            }
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_DIVS: case PO_DIVU: case PO_REMS: case PO_REMU:
        {
            // The divide instructions take their dividend in RDX:RAX and leave
            // the quotient in RAX and the remainder in RDX, so this is the one
            // place where the two registers are chosen for the instruction
            // rather than by the allocator.
            int divisor = nat_operand_reg(g, ins.b, R10);
            if (divisor == RAX || divisor == RDX) { x_mov_rr(g.text, R10, divisor); divisor = R10; }
            nat_into_reg(g, ins.a, RAX);
            bool quotient = ins.op == PO_DIVS || ins.op == PO_DIVU;
            if (ins.op == PO_DIVS || ins.op == PO_REMS) { x_cqo(g.text); }
            else { x_zero_rdx(g.text); }
            if (ins.op == PO_DIVS || ins.op == PO_REMS) { x_idiv(g.text, divisor); }
            else { x_udiv(g.text, divisor); }
            int dst = nat_result_reg(g, ins.dst);
            if (quotient) { if (dst != RAX) { x_mov_rr(g.text, dst, RAX); } }
            else { if (dst != RDX) { x_mov_rr(g.text, dst, RDX); } }
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_SHL: case PO_SHR: case PO_SAR:
        {
            int dst = nat_result_reg(g, ins.dst);
            int digit = ins.op == PO_SHL ? SHL : (ins.op == PO_SHR ? SHR : SAR);
            nat_shift(g, digit, dst, ins.a, ins.b, dst);
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_NEG:
        {
            int dst = nat_result_reg(g, ins.dst);
            nat_into_reg(g, ins.a, dst);
            x_neg(g.text, dst);
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_NOT:
        {
            int dst = nat_result_reg(g, ins.dst);
            nat_into_reg(g, ins.a, dst);
            x_not(g.text, dst);
            nat_finish_def(g, ins.dst, dst);
            return true;
        }
        case PO_CMP:
            return nat_cmp(g, ins.dst, ins.a, ins.b, 0, false, ins.pred);
        case PO_CMPI:
            return nat_cmp(g, ins.dst, ins.a, -1, ins.imm, true, ins.pred);
        case PO_CALL:
        {
            nat_spill_live(g, block, index);
            // System V: the first six integer arguments go in RDI, RSI, RDX, RCX,
            // R8, R9. They are filled left to right, which is safe because no
            // argument's source register is a later argument's destination (the
            // sources are vregs, and the spill above has already moved any live
            // value out of a scratch register into its slot).
            int[6] arg_regs = { RDI, RSI, RDX, RCX, R8, R9 };
            for (int k = 0; k < ins.argc && k < 6; k++)
            {
                int reg = arg_regs[(usz)k];
                int src = nat_operand_reg(g, ins.args[(usz)k], R11);
                if (src != reg) { x_mov_rr(g.text, reg, src); }
            }
            x_call(g.text, ins.callee);
            if (ins.dst >= 0)
            {
                int dst = nat_result_reg(g, ins.dst);
                if (dst != RAX) { x_mov_rr(g.text, dst, RAX); }
                nat_finish_def(g, ins.dst, dst);
            }
            return true;
        }
        case PO_JMP:
            nat_jmp_to(g, ins.target);
            return true;
        case PO_BR:
        {
            int cond = nat_operand_reg(g, ins.a, RAX);
            if (cond != RAX) { x_mov_rr(g.text, RAX, cond); }
            x_test_rr(g.text, RAX, RAX);
            nat_jcc_to(g, CC_NE, ins.target);
            nat_jmp_to(g, ins.target2);
            return true;
        }
        case PO_RET:
        {
            if (ins.a >= 0) { nat_into_reg(g, ins.a, RAX); }
            // Epilogue: restore the frame pointer and hand the frame back. The
            // prologue pushed RBP and reserved the frame with a single SUB, so
            // this is exactly its inverse.
            x_mov_rr(g.text, RSP, RBP);
            x_pop(g.text, RBP);
            x_ret(g.text);
            return true;
        }
        default:
            g.failed = true;
            g.fail_message = (char*)"PIR instruction outside the x86-64 selector";
            return false;
    }
}

// ── functions ──────────────────────────────────────────────────────────────

// nat_layout -- assign a frame slot to every vreg. Slot 0..slot_count-1 belong
// to AIR bindings; vreg i lives at slot_count + i.
fn bool nat_layout(NatGen* g)
{
    if (g == null || g.fn == null) { return false; }
    int base = g.fn.slot_count;
    for (int v = 0; v < g.fn.vreg_count && v < 2048; v++) { g.vreg_slot[(usz)v] = base + v; }
    int slots = base + g.fn.vreg_count;
    g.frame_bytes = slots * 8;
    // Keep the frame 16-byte aligned: the ABI requires RSP to be aligned at a
    // call, and a misaligned frame is the classic source of a crash inside
    // printf that looks like a compiler bug.
    while (g.frame_bytes % 16 != 0) { g.frame_bytes += 8; }
    return true;
}

// nat_emit_function -- one function's prologue, blocks, and patch-up.
fn bool nat_emit_function(NatGen* g, ElfObject* elf, bool is_public)
{
    if (g == null || g.fn == null || g.text == null) { return false; }
    if (!nat_layout(g)) { return false; }
    nat_scan_uses(g);
    for (int b = 0; b < 64; b++) { g.block_offset[(usz)b] = -1; }
    g.patch_count = 0;
    usz start = g.text->len;
    // Prologue.
    x_push(g.text, RBP);
    x_mov_rr(g.text, RBP, RSP);
    if (g.frame_bytes > 0) { x_sub_ri(g.text, RSP, g.frame_bytes); }
    // Incoming arguments land in their slots immediately: the body may call
    // another function at any point, and a caller-saved register cannot be
    // trusted after that.
    int[6] arg_regs = { RDI, RSI, RDX, RCX, R8, R9 };
    for (int i = 0; i < g.fn->param_count && i < 6; i++)
    {
        int slot = g.fn->params[(usz)i].slot;
        x_mov_mr(g.text, nat_slot_mem(g, slot), arg_regs[(usz)i]);
    }
    for (int b = 0; b < g.fn->block_count; b++)
    {
        if (b >= 64) { g.failed = true; g.fail_message = (char*)"more than 64 basic blocks in one function"; return false; }
        g.block_offset[(usz)b] = (int)g.text->len;
        PBlock* block = &g.fn->blocks[(usz)b];
        for (int i = 0; i < block->count; i++)
        {
            if (!nat_emit_inst(g, b, i)) { return false; }
        }
        // A block that runs off its end without a terminator falls into the next
        // one, which is correct only because PIR emits blocks in layout order and
        // the builder always appends a jump when it means one.
    }
    usz end = g.text->len;
    for (int p = 0; p < g.patch_count; p++)
    {
        NatPatch* patch = &g.patches[(usz)p];
        int target_offset = patch->block >= 0 && patch->block < 64 ? g.block_offset[(usz)patch->block] : -1;
        if (target_offset < 0)
        {
            g.failed = true;
            g.fail_message = (char*)"branch to a block that was never emitted";
            return false;
        }
        long rel = (long)target_offset - (long)(patch->at + 4);
        xbuf_patch32(g.text, patch->at, (uint)(rel & 0xFFFFFFFF));
    }
    if (g.text->failed) { g.failed = true; g.fail_message = (char*)"instruction buffer overflow"; return false; }
    (void)end;
    // Symbol for the function.
    if (elf != null)
    {
        elf_add_symbol(elf, g.fn->name, 1, (ulong)start, (ulong)(g.text->len - start),
                       is_public ? STB_GLOBAL : STB_LOCAL, STT_FUNC);
    }
    return true;
}

// nat_emit_start -- the process entry point.
//
// A relocatable object holding nothing but PEAR functions is not runnable: the
// kernel jumps to `_start`, and a program's first instruction has to establish
// the exit status by hand. Twelve bytes do it, and they do it without libc, which
// is the entire point of this backend -- `ld -o prog prog.o` produces a static
// executable from nothing but this compiler and the program itself.
//
// The exit status is `main`'s return value, truncated to the low 32 bits, which
// is the C ABI's rule (only the low byte reaches the shell, but the truncation is
// what makes a negative result come out as the conventional 255 rather than as a
// 64-bit value the kernel would reject).
fn void nat_emit_start(ElfObject* elf, XBuf* text)
{
    if (elf == null || text == null) { return; }
    usz start = text.len;
    x_xor_rr(text, RDI, RDI);      // argc is not consulted: a PEAR program that
                                   // wants argv calls main-style arguments itself
    x_call(text, (char*)"main");   // PLT32 relocation, resolved against this object
                                   // when main is defined here
    x_mov_rr32(text, RDI, RAX);    // exit status = (int)main()
    x_mov_ri(text, RAX, 60);       // SYS_exit
    xb8(text, 0x0F);               // syscall
    xb8(text, 0x05);
    elf_add_symbol(elf, (char*)"_start", 1, (ulong)start, (ulong)(text.len - start), STB_GLOBAL, STT_FUNC);
}

// nat_emit_module -- the whole pipeline for one module: build PIR for every
// definition, select machine code, and serialise the object.
//
// `decls` is the root declaration list the caller already resolved; functions
// outside the native subset are reported by index so the caller can name them in
// a diagnostic instead of failing with a generic message.
fn bool nat_emit_module(AirDecl** decls, usz decl_count, bool emit_start, u8** out_data, usz* out_size,
                        char** fail_name, int* fail_line, int* fail_col, char** fail_message)
{
    if (decls == null || out_data == null || out_size == null) { return false; }
    ElfObject elf;
    memset(&elf, 0, ElfObject::size);
    if (!elf_new_object(&elf)) { return false; }
    XBuf text;
    memset(&text, 0, XBuf::size);
    if (!xbuf_init(&text, 65536)) { elf_free(&elf); return false; }
    for (usz di = 0; di < decl_count; di++)
    {
        AirDecl* d = decls[di];
        if (d == null || d.tag != ADECL_DEF || d.def_body == null) { continue; }
        PFunc* fn = (PFunc*)malloc(PFunc::size);
        if (fn == null) { elf_free(&elf); xbuf_free(&text); return false; }
        memset(fn, 0, PFunc::size);
        fn.name = d.name;
        fn.is_public = d.is_pub;
        PBuilder pb;
        memset(&pb, 0, PBuilder::size);
        if (!pfunc_build(d, fn, &pb))
        {
            if (fail_name != null) { *fail_name = d.name; }
            if (fail_line != null) { *fail_line = pb.fail_line; }
            if (fail_col != null) { *fail_col = pb.fail_col; }
            if (fail_message != null) { *fail_message = pb.fail_message; }
            free(fn);
            elf_free(&elf);
            xbuf_free(&text);
            return false;
        }
        NatGen g;
        memset(&g, 0, NatGen::size);
        g.text = &text;
        g.fn = fn;
        if (!nat_emit_function(&g, &elf, d.is_pub))
        {
            if (fail_name != null) { *fail_name = d.name; }
            if (fail_line != null) { *fail_line = 0; }
            if (fail_col != null) { *fail_col = 0; }
            if (fail_message != null) { *fail_message = g.fail_message; }
            free(fn);
            elf_free(&elf);
            xbuf_free(&text);
            return false;
        }
        free(fn);
    }
    if (emit_start) { nat_emit_start(&elf, &text); }
    // External calls become undefined symbols plus PLT32 relocations.
    for (int i = 0; i < text.fixup_count; i++)
    {
        XFixup* f = &text.fixups[(usz)i];
        int sym = elf_find_symbol(&elf, f->symbol);
        if (sym < 0) { sym = elf_ensure_undefined(&elf, f->symbol); }
        if (sym < 0) { elf_free(&elf); xbuf_free(&text); return false; }
        int type = f->kind == XF_REL32 ? R_X86_64_PLT32 : R_X86_64_PC32;
        if (!elf_add_rela(&elf, f->at, sym, type, -4)) { elf_free(&elf); xbuf_free(&text); return false; }
    }
    if (!elf_set_bytes(&elf, 1, text.data, text.len)) { elf_free(&elf); xbuf_free(&text); return false; }
    bool ok = elf_write(&elf, out_data, out_size);
    elf_free(&elf);
    xbuf_free(&text);
    return ok;
}
