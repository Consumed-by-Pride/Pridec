// PEAR 2 native pipeline, stage 2: the x86-64 instruction encoder.
//
// A deliberate, complete, and boring byte emitter. It knows the REX/ModRM/SIB
// encodings for the integer instruction set PEAR 2 lowers to, and nothing else:
// no floating point (yet), no vector units, no assembler syntax, no text. The
// output is the instruction stream, in order, with fixup sites recorded so the
// linker-facing stage can turn them into relocations.
//
// Why hand-write this instead of generating through an assembler library: the
// whole point of the native pipeline is to stop paying for text. Producing
// assembly text and parsing it again would reproduce exactly the round trip that
// makes the LLVM path slow, and it would re-introduce a dependency the native
// path exists to remove.
//
// Encoding conventions this file follows, stated once so the emitters read
// consistently:
//   * every register is the 64-bit index (RAX=0 .. R15=15); the width is carried
//     by the instruction, not by the register name;
//   * a REX prefix is emitted only when it is needed -- a 64-bit operand, an
//     extended register, or the low-byte registers SPL/BPL/SIL/DIL, which is the
//     one case where REX *changes* the meaning of the encoding;
//   * memory operands are `[base + disp]`, with disp8 when it fits and disp32
//     otherwise; a base of RBP or R13 always uses a displacement because their
//     mod=00 encoding means "no base"; RSP and R12 always emit a SIB byte;
//   * anything this file is asked to encode that it does not model sets the
//     buffer's `failed` flag rather than emitting a plausible-looking wrong
//     instruction.
module pear2c;
import air_ir;


// ── byte buffer with fixup sites ───────────────────────────────────────────

struct XFixup {
    usz at;         // offset of the 4-byte field to patch
    char* symbol;   // symbol the field is relative to
    int kind;       // XF_REL32 (call/jmp), XF_PCREL32 (data reference)
}

const int XF_REL32 = 0;
const int XF_PCREL32 = 1;

struct XBuf {
    char* data;
    usz len;
    usz cap;
    bool failed;
    XFixup* fixups;
    int fixup_count;
    int fixup_cap;
}

fn bool xbuf_init(XBuf* b, usz capacity)
{
    if (b == null) { return false; }
    b.data = (char*)malloc(capacity);
    if (b.data == null) { return false; }
    memset(b.data, 0, capacity);
    b.len = 0;
    b.cap = capacity;
    b.failed = false;
    b.fixups = null;
    b.fixup_count = 0;
    b.fixup_cap = 0;
    return true;
}

fn void xbuf_free(XBuf* b)
{
    if (b == null) { return; }
    if (b.data != null) { free(b.data); }
    if (b.fixups != null) { free(b.fixups); }
    b.data = null;
    b.fixups = null;
    b.len = 0;
    b.cap = 0;
}

fn bool xbuf_reserve(XBuf* b, usz extra)
{
    if (b == null || b.failed) { return false; }
    if (b.len + extra <= b.cap) { return true; }
    usz next = b.cap == 0 ? 1024 : b.cap;
    while (next < b.len + extra) { next = next * 2; }
    char* grown = (char*)malloc(next);
    if (grown == null) { b.failed = true; return false; }
    memset(grown, 0, next);
    if (b.data != null)
    {
        for (usz i = 0; i < b.len; i++) { grown[i] = b.data[i]; }
        free(b.data);
    }
    b.data = grown;
    b.cap = next;
    return true;
}

fn void xb8(XBuf* b, char v)
{
    if (!xbuf_reserve(b, 1)) { return; }
    b.data[b.len] = v;
    b.len++;
}

fn void xb32(XBuf* b, uint v)
{
    xb8(b, (char)(v & 0xFF));
    xb8(b, (char)((v >> 8) & 0xFF));
    xb8(b, (char)((v >> 16) & 0xFF));
    xb8(b, (char)((v >> 24) & 0xFF));
}

fn void xb64(XBuf* b, ulong v)
{
    xb32(b, (uint)(v & 0xFFFFFFFF));
    xb32(b, (uint)((v >> 32) & 0xFFFFFFFF));
}

fn void xb_align(XBuf* b, usz alignment)
{
    if (alignment == 0) { return; }
    while (b.len % alignment != 0) { xb8(b, 0x90); }
}

// xf_record -- remember a 4-byte field that must be patched with a symbol's
// address. The field is zero while the buffer is still being built.
fn void xbuf_fixup(XBuf* b, usz at, char* symbol, int kind)
{
    if (b == null || symbol == null) { return; }
    if (b.fixup_count >= b.fixup_cap)
    {
        int next = b.fixup_cap == 0 ? 16 : b.fixup_cap * 2;
        XFixup* grown = (XFixup*)malloc((usz)next * XFixup::size);
        if (grown == null) { b.failed = true; return; }
        memset(grown, 0, (usz)next * XFixup::size);
        for (int i = 0; i < b.fixup_count; i++) { grown[i] = b.fixups[i]; }
        if (b.fixups != null) { free(b.fixups); }
        b.fixups = grown;
        b.fixup_cap = next;
    }
    b.fixups[b.fixup_count].at = at;
    b.fixups[b.fixup_count].symbol = symbol;
    b.fixups[b.fixup_count].kind = kind;
    b.fixup_count++;
}

fn void xbuf_patch32(XBuf* b, usz at, uint value)
{
    if (b == null || at + 4 > b.len) { return; }
    b.data[at] = (char)(value & 0xFF);
    b.data[at + 1] = (char)((value >> 8) & 0xFF);
    b.data[at + 2] = (char)((value >> 16) & 0xFF);
    b.data[at + 3] = (char)((value >> 24) & 0xFF);
}

// ── registers ──────────────────────────────────────────────────────────────

const int RAX = 0;
const int RCX = 1;
const int RDX = 2;
const int RBX = 3;
const int RSP = 4;
const int RBP = 5;
const int RSI = 6;
const int RDI = 7;
const int R8  = 8;
const int R9  = 9;
const int R10 = 10;
const int R11 = 11;
const int R12 = 12;
const int R13 = 13;
const int R14 = 14;
const int R15 = 15;

// x86 condition encodings, indexed by PIR's PPred where the widths agree.
const int CC_O  = 0x0;
const int CC_NO = 0x1;
const int CC_B  = 0x2;
const int CC_AE = 0x3;
const int CC_E  = 0x4;
const int CC_NE = 0x5;
const int CC_BE = 0x6;
const int CC_A  = 0x7;
const int CC_S  = 0x8;
const int CC_NS = 0x9;
const int CC_L  = 0xC;
const int CC_GE = 0xD;
const int CC_LE = 0xE;
const int CC_G  = 0xF;

struct XMem {
    int base;   // register holding the address
    long disp;  // byte displacement
}

fn XMem xmem(int base, long disp)
{
    XMem m;
    m.base = base;
    m.disp = disp;
    return m;
}

// ── prefix and operand encoding ────────────────────────────────────────────

// x_rex -- emit a REX prefix when one is needed. `force` covers the low-byte
// register case (SPL/BPL/SIL/DIL are only addressable with a REX prefix, and
// without one the encoding names AH/CH/DH/BH instead).
fn void x_rex(XBuf* b, bool w, int reg, int index, int base, bool force, bool* emitted)
{
    bool r = (reg & 8) != 0;
    bool x = (index & 8) != 0;
    bool bb = (base & 8) != 0;
    bool need = w || r || x || bb || force;
    if (emitted != null) { *emitted = need; }
    if (!need) { return; }
    char v = 0x40;
    if (w) { v = v | 0x08; }
    if (r) { v = v | 0x04; }
    if (x) { v = v | 0x02; }
    if (bb) { v = v | 0x01; }
    xb8(b, v);
}

// x_modrm -- emit a ModRM byte plus the SIB and displacement a memory operand
// needs. `reg` is the register field (0..15, its bit 3 goes in REX.R), `rm` is
// either a register or the base of a memory operand.
fn void x_modrm_mem(XBuf* b, int reg, XMem m)
{
    int base = m.base & 7;
    bool need_disp8 = m.disp != 0 && m.disp >= -128 && m.disp <= 127;
    bool force_disp32 = base == 5; // RBP/R13 with mod=00 means RIP-relative
    int mod = 0;
    if (m.disp == 0 && !force_disp32) { mod = 0; }
    else if (need_disp8 && !force_disp32) { mod = 1; }
    else { mod = 2; }
    xb8(b, (char)((mod << 6) | ((reg & 7) << 3) | base));
    // SIB: RSP/R12 as a base has no direct encoding; a SIB with index=100 (none)
    // and scale=0 is the canonical form.
    if (base == 4)
    {
        xb8(b, 0x24);
    }
    if (mod == 1) { xb8(b, (char)(m.disp & 0xFF)); }
    else if (mod == 2) { xb32(b, (uint)m.disp); }
}

fn void x_modrm_reg(XBuf* b, int reg, int rm)
{
    xb8(b, (char)(0xC0 | ((reg & 7) << 3) | (rm & 7)));
}

// ── moves ──────────────────────────────────────────────────────────────────

// mov r64, imm64 -- always the full 10-byte form when the constant does not fit
// a sign-extended 32-bit immediate, and the 7-byte C7 form when it does.
fn void x_mov_ri(XBuf* b, int reg, long value)
{
    if (value >= -2147483648L && value <= 2147483647L)
    {
        x_rex(b, true, 0, 0, reg, false, null);
        xb8(b, 0xC7);
        x_modrm_reg(b, 0, reg);
        xb32(b, (uint)value);
        return;
    }
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, (char)(0xB8 + (reg & 7)));
    xb64(b, (ulong)value);
}

// mov r64, r64  (89 /r, operand order is r/m <- reg)
fn void x_mov_rr(XBuf* b, int dst, int src)
{
    x_rex(b, true, src, 0, dst, false, null);
    xb8(b, 0x89);
    x_modrm_reg(b, src, dst);
}

// mov r32, r32  (89 /r without REX.W)
//
// A 32-bit move zeroes the upper half of the destination, which is exactly the
// semantics a narrowing assignment wants, so this is both the narrower encoding
// and the one that makes the result well defined.
fn void x_mov_rr32(XBuf* b, int dst, int src)
{
    x_rex(b, false, src, 0, dst, false, null);
    xb8(b, 0x89);
    x_modrm_reg(b, src, dst);
}

// mov r64, [mem]  (8B /r)
fn void x_mov_rm(XBuf* b, int dst, XMem m)
{
    x_rex(b, true, dst, 0, m.base, false, null);
    xb8(b, 0x8B);
    x_modrm_mem(b, dst, m);
}

// mov [mem], r64  (89 /r)
fn void x_mov_mr(XBuf* b, XMem m, int src)
{
    x_rex(b, true, src, 0, m.base, false, null);
    xb8(b, 0x89);
    x_modrm_mem(b, src, m);
}

// A store of a narrow value keeps the low bits of the register: the store width
// is what truncates, so no explicit mask is needed at the instruction level.
fn void x_mov_mr8(XBuf* b, XMem m, int src)
{
    bool emitted = false;
    x_rex(b, false, src, 0, m.base, true, &emitted);
    xb8(b, 0x88);
    x_modrm_mem(b, src, m);
}

fn void x_mov_mr16(XBuf* b, XMem m, int src)
{
    xb8(b, 0x66);
    x_rex(b, false, src, 0, m.base, false, null);
    xb8(b, 0x89);
    x_modrm_mem(b, src, m);
}

fn void x_mov_mr32(XBuf* b, XMem m, int src)
{
    x_rex(b, false, src, 0, m.base, false, null);
    xb8(b, 0x89);
    x_modrm_mem(b, src, m);
}

// lea r64, [mem] -- also the canonical way to compute an address from a base and
// a displacement without touching flags.
fn void x_lea(XBuf* b, int dst, XMem m)
{
    x_rex(b, true, dst, 0, m.base, false, null);
    xb8(b, 0x8D);
    x_modrm_mem(b, dst, m);
}

// ── arithmetic and logic ───────────────────────────────────────────────────

// The 64-bit register-register forms: 01 /r (add), 29 /r (sub), 21 /r (and),
// 09 /r (or), 31 /r (xor), 39 /r (cmp), 85 /r (test).
fn void x_alu_rr(XBuf* b, char opcode, int dst, int src)
{
    x_rex(b, true, src, 0, dst, false, null);
    xb8(b, opcode);
    x_modrm_reg(b, src, dst);
}

fn void x_add_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x01, dst, src); }
fn void x_sub_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x29, dst, src); }
fn void x_and_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x21, dst, src); }
fn void x_or_rr(XBuf* b, int dst, int src)  { x_alu_rr(b, 0x09, dst, src); }
fn void x_xor_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x31, dst, src); }
fn void x_cmp_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x39, dst, src); }
fn void x_test_rr(XBuf* b, int dst, int src) { x_alu_rr(b, 0x85, dst, src); }

// The 81 /digit immediate forms. The immediate is sign-extended to 64 bits by
// the processor, so a caller that wants an unsigned 32-bit constant must not
// route it through here.
fn void x_alu_ri(XBuf* b, char digit, int dst, long value)
{
    x_rex(b, true, 0, 0, dst, false, null);
    xb8(b, 0x81);
    x_modrm_reg(b, digit & 7, dst);
    xb32(b, (uint)value);
}

const int ALU_ADD = 0;
const int ALU_OR  = 1;
const int ALU_AND = 4;
const int ALU_SUB = 5;
const int ALU_XOR = 6;
const int ALU_CMP = 7;

fn void x_add_ri(XBuf* b, int dst, long v) { x_alu_ri(b, ALU_ADD, dst, v); }
fn void x_sub_ri(XBuf* b, int dst, long v) { x_alu_ri(b, ALU_SUB, dst, v); }
fn void x_and_ri(XBuf* b, int dst, long v) { x_alu_ri(b, ALU_AND, dst, v); }
fn void x_or_ri(XBuf* b, int dst, long v)  { x_alu_ri(b, ALU_OR, dst, v); }
fn void x_xor_ri(XBuf* b, int dst, long v) { x_alu_ri(b, ALU_XOR, dst, v); }
fn void x_cmp_ri(XBuf* b, int dst, long v) { x_alu_ri(b, ALU_CMP, dst, v); }

// imul r64, r/m64  (0F AF /r) -- the two-operand form, which is all PIR asks for.
fn void x_imul_rr(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x0F);
    xb8(b, 0xAF);
    x_modrm_reg(b, dst, src);
}

// imul r64, r/m64, imm32  (6B /r ib) -- keeps a constant multiplier in one
// instruction instead of materializing it into a register first.
fn void x_imul_rri(XBuf* b, int dst, int src, long value)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x6B);
    x_modrm_reg(b, dst, src);
    xb32(b, (uint)value);
}

// neg / not / idiv / div / mul, all the F7 group.
fn void x_neg(XBuf* b, int reg)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xF7);
    x_modrm_reg(b, 3, reg);
}

fn void x_not(XBuf* b, int reg)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xF7);
    x_modrm_reg(b, 2, reg);
}

fn void x_udiv(XBuf* b, int reg)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xF7);
    x_modrm_reg(b, 6, reg);
}

fn void x_idiv(XBuf* b, int reg)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xF7);
    x_modrm_reg(b, 7, reg);
}

// cqo -- sign-extend RAX into RDX:RAX, the required setup for idiv.
fn void x_cqo(XBuf* b)
{
    xb8(b, 0x48);
    xb8(b, 0x99);
}

// x_zero_extend -- zero RDX for unsigned div. `xor rdx, rdx` is the shortest
// encoding and, unlike `mov rdx, 0`, also breaks the dependency chain.
fn void x_zero_rdx(XBuf* b)
{
    xb8(b, 0x48);
    xb8(b, 0x31);
    xb8(b, 0xD2);
}

// Shifts: C1 /digit ib (immediate) and D3 /digit (CL).
const int SHL = 4;
const int SHR = 5;
const int SAR = 7;

fn void x_shift_imm(XBuf* b, int digit, int reg, int amount)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xC1);
    x_modrm_reg(b, digit & 7, reg);
    xb8(b, (char)(amount & 0xFF));
}

fn void x_shift_cl(XBuf* b, int digit, int reg)
{
    x_rex(b, true, 0, 0, reg, false, null);
    xb8(b, 0xD3);
    x_modrm_reg(b, digit & 7, reg);
}

// ── extensions and truncations ─────────────────────────────────────────────

// movzx/movsx from 8, 16, and 32 bits. A 32-bit destination write already zeroes
// the upper half on x86-64, so an unsigned 32->64 widening is a plain mov.
fn void x_movzx8(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x0F);
    xb8(b, 0xB6);
    x_modrm_reg(b, dst, src);
}

fn void x_movsx8(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x0F);
    xb8(b, 0xBE);
    x_modrm_reg(b, dst, src);
}

fn void x_movzx16(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x0F);
    xb8(b, 0xB7);
    x_modrm_reg(b, dst, src);
}

fn void x_movsx16(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x0F);
    xb8(b, 0xBF);
    x_modrm_reg(b, dst, src);
}

// movsxd r64, r/m32 (63 /r) -- the sign-extending 32->64 move.
fn void x_movsxd(XBuf* b, int dst, int src)
{
    x_rex(b, true, dst, 0, src, false, null);
    xb8(b, 0x63);
    x_modrm_reg(b, dst, src);
}

// ── comparisons into a value ───────────────────────────────────────────────

// setcc r/m8 -- writes a single byte, 0 or 1, from the flags. The caller must
// zero the destination first, because the upper bits are not touched.
fn void x_setcc(XBuf* b, int cc, int reg)
{
    bool emitted = false;
    x_rex(b, false, 0, 0, reg, true, &emitted);
    xb8(b, 0x0F);
    xb8(b, (char)(0x90 + (cc & 0x0F)));
    x_modrm_reg(b, 0, reg);
}

// ── control flow ───────────────────────────────────────────────────────────

fn void x_ret(XBuf* b) { xb8(b, 0xC3); }
fn void x_nop(XBuf* b) { xb8(b, 0x90); }
fn void x_ud2(XBuf* b) { xb8(b, 0x0F); xb8(b, 0x0B); }

fn void x_push(XBuf* b, int reg)
{
    x_rex(b, false, 0, 0, reg, false, null);
    xb8(b, (char)(0x50 + (reg & 7)));
}

fn void x_pop(XBuf* b, int reg)
{
    x_rex(b, false, 0, 0, reg, false, null);
    xb8(b, (char)(0x58 + (reg & 7)));
}

// A near jump with a 32-bit displacement. When `symbol` is null the caller is
// jumping inside the function and patches the field itself once the target
// offset is known; otherwise a relocation names the symbol.
fn void x_jmp(XBuf* b, char* symbol)
{
    xb8(b, 0xE9);
    usz at = b.len;
    xb32(b, 0);
    if (symbol != null) { xbuf_fixup(b, at, symbol, XF_REL32); }
}

fn void x_jcc(XBuf* b, int cc, char* symbol)
{
    xb8(b, 0x0F);
    xb8(b, (char)(0x80 + (cc & 0x0F)));
    usz at = b.len;
    xb32(b, 0);
    if (symbol != null) { xbuf_fixup(b, at, symbol, XF_REL32); }
}

fn void x_call(XBuf* b, char* symbol)
{
    xb8(b, 0xE8);
    usz at = b.len;
    xb32(b, 0);
    if (symbol != null) { xbuf_fixup(b, at, symbol, XF_REL32); }
}

// call r/m64 (FF /2) -- an indirect call through a register.
fn void x_call_reg(XBuf* b, int reg)
{
    x_rex(b, false, 0, 0, reg, false, null);
    xb8(b, 0xFF);
    x_modrm_reg(b, 2, reg);
}

// jmp r/m64 (FF /4)
fn void x_jmp_reg(XBuf* b, int reg)
{
    x_rex(b, false, 0, 0, reg, false, null);
    xb8(b, 0xFF);
    x_modrm_reg(b, 4, reg);
}

// ── condition mapping ──────────────────────────────────────────────────────

// x_cc_for_pred -- translate a PIR predicate into an x86 condition code. Signed
// and unsigned predicates differ only in the code, never in the instruction, so
// the whole signedness decision happens here.
fn int x_cc_for_pred(int pred)
{
    switch (pred)
    {
        case 0: return CC_E;
        case 1: return CC_NE;
        case 2: return CC_L;
        case 3: return CC_LE;
        case 4: return CC_G;
        case 5: return CC_GE;
        case 6: return CC_B;
        case 7: return CC_BE;
        case 8: return CC_A;
        default: return CC_AE;
    }
}
