// ============================================================================
// air_util.c3 — the AIR layer's own shared utilities
// ----------------------------------------------------------------------------
// AirTyp predicates and a grown-on-demand string builder. Nothing in here knows
// what LLVM is.
//
// Why this file exists. These two things used to live in `air_ll.c3`, the module
// that prints textual LLVM IR. That was fine while `air_ll` was just "one more
// file in pear_ir", but it made three emit-side modules depend on the whole
// consumer:
//
//     air_verify  -> air_ll   for cc_known
//     air_fold    -> air_ll   for ty_is_int / ty_bits / ty_eq / ty_is_signed
//     air_low     -> air_ll   for ty_*  and Sb
//
// `air_low` is the front end's AIR *emitter*. It should not be able to reach an
// LLVM printer, and once the boundary is enforced it cannot. The predicates below
// are properties of `AirTyp`, i.e. of the AIR layer itself: `ty_bits` answers
// "how wide is this type on the target the module names", which the emitter, the
// verifier, a folder and every backend all have to agree on. They belong here.
//
// `Sb` is here for the same reason: it is a byte buffer, not a printer. The
// emitting side uses it to assemble an inline-asm template; `air_ll` uses it to
// assemble a function body. One implementation, no second copy to drift.
//
// The split is one-way and checked: `air_util` imports `air_ir` and `air_text`,
// and nothing in the emit side may import the consumer side (tests/air/boundary.sh
// fails the build if it does).
// ============================================================================
module air_util;

import air_ir;
import air_text;

// The builder allocates; nothing else here does. Declared with the same `usz`
// signatures air_ll used, so the two modules agree on the libc prototypes.
extern fn void* malloc(usz size_);
extern fn void* realloc(void* p, usz size_);

// ── type predicates ────────────────────────────────────────────────────────
// A predicate takes `null` and answers false: the AIR reader can produce a
// partially-formed node on a bad input, and every caller here has to survive it
// rather than crash on the way to reporting the real error.

fn bool ty_is_int(AirTyp* t)
{
    if (t == null) { return false; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_I16: case ATYP_I32: case ATYP_I64: case ATYP_ISZ:
        case ATYP_U8: case ATYP_U16: case ATYP_U32: case ATYP_U64: case ATYP_USZ: case ATYP_CHAR: return true;
        default: return false;
    }
}

fn bool ty_is_signed(AirTyp* t)
{
    if (t == null) { return false; }
    return t.tag == ATYP_I8 || t.tag == ATYP_I16 || t.tag == ATYP_I32 || t.tag == ATYP_I64 || t.tag == ATYP_ISZ;
}

// `usz`/`isz` are as wide as a pointer of the target (docs/specs/AIR3.md
// "Target"): 64 unless `emit-ll --target=` names a 32-bit triple. This is the one
// piece of target state in the AIR layer, and it is here rather than in a backend
// because the ANSWER is a property of the module's own triple.
int g_ptr_bits = 64;
char* g_triple = null;

fn int triple_ptr_bits(char* tr)
{
    if (tr == null) { return 64; }
    usz n = 0; while (tr[n] != 0 && tr[n] != '-') { n++; }
    char[24] a; if (n >= 23) { return 64; }
    for (usz i = 0; i < n; i++) { a[i] = tr[i]; } a[n] = 0;
    char* s = &a[0];
    if (air_text::streq(s, "wasm32") || air_text::streq(s, "x86") || air_text::streq(s, "riscv32") || air_text::streq(s, "mips") || air_text::streq(s, "mipsel")
        || air_text::streq(s, "powerpc") || air_text::streq(s, "sparc") || air_text::streq(s, "hexagon") || air_text::streq(s, "avr") || air_text::streq(s, "msp430")) { return 32; }
    if (n >= 4 && s[0] == 'i' && s[2] == '8' && s[3] == '6') { return 32; }                      // i386 .. i686
    if (n >= 3 && s[0] == 'a' && s[1] == 'r' && s[2] == 'm' && !(n >= 5 && s[3] == '6' && s[4] == '4')) { return 32; }   // arm, armv7 (not arm64/aarch64)
    if (n >= 5 && s[0] == 't' && s[1] == 'h' && s[2] == 'u' && s[3] == 'm' && s[4] == 'b') { return 32; }
    return 64;
}

fn int ty_bits(AirTyp* t)
{
    switch (t.tag)
    {
        case ATYP_ISZ: case ATYP_USZ: return g_ptr_bits;
        case ATYP_I8: case ATYP_U8: return 8;
        case ATYP_I16: case ATYP_U16: return 16;
        case ATYP_I32: case ATYP_U32: case ATYP_CHAR: return 32;
        case ATYP_F32: return 32;
        case ATYP_BOOL: return 1;
        default: return 64;
    }
}

fn bool ty_is_float(AirTyp* t) { return t != null && (t.tag == ATYP_F32 || t.tag == ATYP_F64); }
fn bool ty_is_ptr(AirTyp* t)   { return t != null && (t.tag == ATYP_PTR || t.tag == ATYP_ARROW); }
fn bool ty_is_bool(AirTyp* t)  { return t != null && t.tag == ATYP_BOOL; }
fn bool ty_is_unit(AirTyp* t)  { return t != null && t.tag == ATYP_UNIT; }

fn bool ty_eq(AirTyp* a, AirTyp* b)
{
    if (a == b) { return true; }
    if (a == null || b == null) { return false; }
    if (a.tag != b.tag) { return false; }
    if (a.tag == ATYP_NOMINAL) { return air_text::streq(a.name, b.name); }
    if (a.tag == ATYP_ARRAY && a.ival != b.ival) { return false; }
    if (a.arg_count != b.arg_count) { return false; }
    for (usz i = 0; i < a.arg_count; i++) { if (!ty_eq(a.args[i], b.args[i])) { return false; } }
    return true;
}

// ── string builder ─────────────────────────────────────────────────────────
// Grown on demand. `take` hands ownership of the buffer to the caller (which is
// usually an arena or a `free` at exit); everything else appends.
struct Sb { char* d; usz n; usz cap; }

fn void Sb.init(Sb* s) { s.d = null; s.n = 0; s.cap = 0; }
fn void Sb.reserve(Sb* s, usz more)
{
    if (s.n + more + 1 <= s.cap) { return; }
    usz nc = s.cap == 0 ? 256 : s.cap;
    while (nc < s.n + more + 1) { nc = nc * 2; }
    s.d = (char*)realloc((void*)s.d, nc); s.cap = nc;
}
fn void Sb.putc(Sb* s, char c) { s.reserve(1); s.d[s.n] = c; s.n++; s.d[s.n] = 0; }
fn void Sb.put(Sb* s, char* t)
{
    if (t == null) { return; }
    usz k = 0; while (t[k] != 0) { k++; }
    s.reserve(k);
    for (usz i = 0; i < k; i++) { s.d[s.n + i] = t[i]; }
    s.n = s.n + k; s.d[s.n] = 0;
}
fn void Sb.int_(Sb* s, long v)
{
    if (v == 0) { s.putc('0'); return; }
    char[24] tmp; usz k = 0; bool neg = v < 0;
    ulong u = neg ? (ulong)(0 - v) : (ulong)v;
    while (u > 0) { tmp[k] = (char)('0' + (int)(u % 10)); u = u / 10; k++; }
    if (neg) { s.putc('-'); }
    while (k > 0) { k--; s.putc(tmp[k]); }
}
fn void Sb.hex(Sb* s, ulong v, int digits)
{
    int i = digits - 1;
    while (i >= 0)
    {
        int d = (int)((v >> (ulong)(i * 4)) & 15);
        s.putc((char)(d < 10 ? '0' + d : 'A' + (d - 10)));
        i = i - 1;
    }
}
fn void Sb.name(Sb* s, char sigil, char* nm)   // %"x"  /  @"x"
{
    s.putc(sigil); s.putc('"');
    if (nm != null) { for (usz i = 0; nm[i] != 0; i++) { if (nm[i] == '"' || nm[i] == '\\') { s.putc('_'); } else { s.putc(nm[i]); } } }
    s.putc('"');
}
fn char* Sb.take(Sb* s)
{
    usz n = s.n;
    char* r = (char*)malloc(n + 1);
    for (usz i = 0; i < n; i++) { r[i] = s.d[i]; }
    r[n] = 0; s.n = 0; if (s.d != null) { s.d[0] = 0; }
    return r;
}

// ── call conventions ───────────────────────────────────────────────────────
// AIR spells a call convention as a name; the backends need the keyword. Keeping
// the mapping here means a new convention is added once, not once per backend.
fn char* cc_keyword(char* nm)
{
    if (nm == null) { return null; }
    if (air_text::streq(nm, "c")) { return null; }
    if (air_text::streq(nm, "fast")) { return "fastcc"; }
    if (air_text::streq(nm, "preserve_most")) { return "preserve_mostcc"; }
    if (air_text::streq(nm, "preserve_all")) { return "preserve_allcc"; }
    if (air_text::streq(nm, "x86_intr")) { return "x86_intrcc"; }
    if (air_text::streq(nm, "win64")) { return "win64cc"; }
    if (air_text::streq(nm, "sysv64")) { return "x86_64_sysvcc"; }
    if (air_text::streq(nm, "aapcs")) { return "arm_aapcscc"; }
    if (air_text::streq(nm, "aapcs_vfp")) { return "arm_aapcs_vfpcc"; }
    return null;
}
fn bool cc_known(char* nm) { return nm != null && (air_text::streq(nm, "c") || cc_keyword(nm) != null); }
