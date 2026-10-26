// PEAR 2 bootstrap backend.
//
// The current bootstrap subset accepts scalar and internal tuple/array ABIs;
// integer/float/pointer coercions; local aggregate construction/projection;
// typed pointer indexing and memory; matches, label/jump CFG, layout queries,
// assertions and traps. External aggregate ABIs and unsupported forms fail closed.
module pear2c;
import air_ir;
import air_read;
import air_verify;
import air_facts;
import pear2_opt;
extern fn int printf(char* fmt, ...);
extern fn int fprintf(void* f, char* fmt, ...);
extern fn void* fopen(char* path, char* mode);
extern fn int fclose(void* f);
extern fn void* open_memstream(char** buf, usz* size) @cname("open_memstream");
extern fn usz fwrite(void* ptr, usz size, usz count, void* f) @cname("fwrite");
extern fn void* malloc(usz bytes) @cname("malloc");
extern fn void free(void* p) @cname("free");
extern fn int remove(char* path);
extern fn int rename(char* old_path, char* new_path);
extern fn int snprintf(char* buf, usz cap, char* fmt, ...);
extern fn int getpid();
extern fn int system(char* command) @cname("system");
extern fn char* getenv(char* name) @cname("getenv");
// LLVM C API: parse the generated textual module, verify it, then serialize
// the verified module as LLVM bitcode. PEAR 2 owns this path; it does not call
// PEAR 1 or air_ll.
extern fn void* ll_context_create() @cname("LLVMContextCreate");
extern fn void ll_context_dispose(void* c) @cname("LLVMContextDispose");
extern fn int ll_buffer_from_file(char* path, void** out, char** msg) @cname("LLVMCreateMemoryBufferWithContentsOfFile");
extern fn int ll_parse_ir(void* c, void* buf, void** out_mod, char** msg) @cname("LLVMParseIRInContext");
extern fn int ll_verify_module(void* m, int action, char** msg) @cname("LLVMVerifyModule");
extern fn int ll_write_bitcode(void* m, char* path) @cname("LLVMWriteBitcodeToFile");
extern fn void ll_module_dispose(void* m) @cname("LLVMDisposeModule");
extern fn void ll_message_dispose(char* msg) @cname("LLVMDisposeMessage");
extern fn void ll_set_source_file_name(void* m, char* name, usz len) @cname("LLVMSetSourceFileName");
fn bool same(char* a, char* b)
{
    if (a == null || b == null) { return a == b; }
    usz i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}
struct M1Label
{
    AirCmd* cmd;
    char* name;
    AirBinder*[16] params;
    char*[16] slots;
    bool[16] param_bools;
    bool[16] param_ptrs;
    usz param_count;
    char*[64] env_names;
    char*[64] env_values;
    char*[64] env_slots;
    bool[64] env_bools;
    bool[64] env_ptrs;
    AirTyp*[64] env_types;
    usz env_count;
    bool captured;
    bool has_jump;
    // M9 phi promotion: recorded incoming edges. Each edge row stores the
    // terminating predecessor block name followed by the per-entry captured
    // environment values and the label parameter values at that edge.
    char** edges;
    usz edge_count;
    usz edge_stride;
    // Two-phase buffered emission: phase A renders the body into body_buffer
    // (recording edges into *other* labels as it goes); phase B composes
    // header, phis and buffered body afterwards. This makes sibling label
    // bodies order-independent: e.g. an exit label declared before a loop
    // label still sees the loop body's jump as an incoming edge.
    char* body_buffer;
    usz body_size;
    bool buffered;
    char*[64] env_phis;
    char*[16] param_phis;
}

const int M1PROV_UNKNOWN = 0;
const int M1PROV_STACK = 1;
const int M1PROV_HEAP = 2;
const int M1PROV_GLOBAL = 3;
const int M1PROV_STRING = 4;
const int M1PROV_PARAM = 5;
struct M1String { char* data; usz len; char* name; char* symbol; bool terminate; }
struct M1Provenance { char* value; char* allocation; AirTyp* pointee; int kind; int alignment; long extent; long offset; bool offset_known; bool freed; bool writable; }
struct M1PointerCell { char* allocation; long offset; char* value_allocation; AirTyp* pointee; int kind; int alignment; long extent; long value_offset; bool offset_known; bool freed; bool writable; bool is_null; }// M10 target profile: pointer width, triple and datalayout follow --target.
// wasm32-freestanding narrows isz/usz and the pointer representation to 32
// bits; the default x86_64 profile keeps the historical 64-bit layout so
// emitted IR is byte-identical to earlier slices.
usz g_m1_target_ptr_bits = 64;
bool g_m1_target_freestanding = false;
char* g_m1_target_triple = (char*)"x86_64-unknown-linux-gnu";
char* g_m1_target_datalayout = (char*)"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
fn int m1_target_ptr_bytes() { return (int)(g_m1_target_ptr_bits / 8); }
fn bool m1_has_prefix(char* s, char* prefix)
{
    if (s == null || prefix == null) { return false; }
    usz i = 0;
    while (prefix[i] != 0)
    {
        if (s[i] != prefix[i]) { return false; }
        i++;
    }
    return true;
}
// M10 escape-only effect frames: each lexically enclosing `handle` owns one
// frame; a `perform` resolves its operation innermost-first. Resuming or
// multi-shot arms are rejected with source positions before any emission.
struct M1FxArm { char* op; char* label; char* slot; AirTyp* slot_ty; char* payload; AirCmd* body; bool has_slot; }
struct M1FxFrame { M1FxArm[16] arms; usz arm_count; char* post; }
struct M1Gen
{
    AirArena* arena;
    void* out;
    AirDecl** decls;
    usz decl_count;
    char*[256] env_names;
    char*[256] env_values;
    char*[256] env_slots;
    bool[256] env_bools;
    bool[256] env_ptrs;
    AirTyp*[256] env_types;
    bool[256] env_carried;
    usz env_count;
    // Name (without the leading '%') of the basic block currently being
    // emitted; used to attach phi incoming edges to their predecessor.
    char* cur_block;
    // M8 closure lifting: lambda bodies are rendered module-level into buffered
    // `define` blocks (taking a hidden leading `ptr %env` parameter) and flushed
    // after the enclosing function body is complete.
    char*[24] lam_buffers;
    usz[24] lam_sizes;
    int lam_count;
    int lam_serial;
    // M9 loop-carried watch: while/for bodies record the latest mainline
    // redefinition of each tracked loop-carried name so the backedge phi
    // incoming value survives the body's scope restorations. A redefinition
    // inside a terminal branch arm (branch_depth > watch depth) cannot reach
    // the backedge and is deliberately not recorded.
    bool watch_active;
    int watch_branch_depth;
    char*[32] watch_names;
    char*[32] watch_values;
    int watch_count;
    int branch_depth;
    M1Label[32] labels;
    usz label_count;
    int next_tmp;
    int next_label;
    int next_slot;
    bool default_unsigned;
    int default_bits;
    AirTyp* return_type;
    bool return_bool;
    bool return_ptr;
    bool return_unit;
    bool guard_active;
    char* guard_name;
    char* guard_true_label;
    char* guard_false_label;
    bool has_for;
    int for_depth;
    int seq_depth;
    bool terminated;
    M1String[256] strings; int string_count;
    M1Provenance[1024] provenance; int provenance_count;
    M1PointerCell[512] pointer_cells; int pointer_cell_count;
    bool low_profile; char* input_path; char* current_function;
    M1FxFrame[8] fx_stack; usz fx_depth;
    int fail_line; int fail_col; int last_line; int last_col; char* fail_form;
    bool failed;
    char* error;
}
fn int m1_int_bits(AirTyp* t)
{
    if (t == null || t.tag == ATYP_INFER || t.tag == ATYP_I64 || t.tag == ATYP_U64) { return 64; }
    if (t.tag == ATYP_ISZ || t.tag == ATYP_USZ) { return (int)g_m1_target_ptr_bits; }
    switch (t.tag)
    {
        case ATYP_I8: case ATYP_U8: return 8;
        case ATYP_I16: case ATYP_U16: return 16;
        case ATYP_I32: case ATYP_U32: case ATYP_CHAR: return 32;
        case ATYP_I128: case ATYP_U128: return 128;
        default: return 0;
    }
}
fn bool m1_integer_type(AirTyp* t) { return m1_int_bits(t) != 0; }
fn bool m1_bool_type(AirTyp* t)
{
    return t != null && t.tag == ATYP_BOOL;
}
fn bool m1_pointer_type(AirTyp* t)
{
    return t != null && t.tag == ATYP_PTR;
}
fn bool m1_function_pointer_type(AirTyp* t)
{
    return t != null && t.tag == ATYP_ARROW && t.arg_count == 2 && t.args[0] != null && t.args[1] != null &&
           t.args[0].tag == ATYP_TUPLE && t.args[0].arg_count <= 64;
}
fn bool m1_pointer_repr_type(AirTyp* t)
{
    return m1_pointer_type(t) || m1_function_pointer_type(t);
}
fn AirTyp* m1_pointee_type(AirTyp* t)
{
    if (!m1_pointer_type(t) || t.arg_count != 1 || t.args[0] == null) { return null; }
    return t.args[0];
}
fn bool m1_float_type(AirTyp* t)
{
    return t != null && (t.tag == ATYP_F32 || t.tag == ATYP_F64);
}
fn bool m1_unicode_scalar(long value)
{
    return value >= 0 && value <= 0x10FFFF && (value < 0xD800 || value > 0xDFFF);
}
fn bool m1_supported_memory_width(int bytes)
{
    return bytes == 1 || bytes == 2 || bytes == 4 || bytes == 8;
}
fn int m1_memory_bytes(AirTyp* t)
{
    if (m1_bool_type(t)) { return 1; }
    if (m1_pointer_repr_type(t)) { return m1_target_ptr_bytes(); }
    if (m1_float_type(t)) { return t.tag == ATYP_F32 ? 4 : 8; }
    if (m1_known_type(t) && m1_integer_type(t)) { int bits = m1_int_bits(t); return bits >= 8 && bits <= 64 ? bits / 8 : 0; }
    if (t != null && t.tag == ATYP_ARRAY && t.arg_count == 1 && t.ival > 0 && t.ival <= 1024)
    {
        int element_bytes = m1_memory_bytes(t.args[0]);
        if (element_bytes == 0 || element_bytes > 8) { return 0; }
        int total = element_bytes * (int)t.ival;
        return total <= 8 ? total : 0;
    }
    return 0;
}
fn int m1_value_size(AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return -1; }
    if (t.tag == ATYP_UNIT) { return 0; }
    if (m1_bool_type(t)) { return 1; }
    if (m1_pointer_repr_type(t)) { return m1_target_ptr_bytes(); }
    if (m1_float_type(t)) { return t.tag == ATYP_F32 ? 4 : 8; }
    if (m1_known_type(t) && m1_integer_type(t))
    {
        int bits = m1_int_bits(t);
        return bits >= 8 && bits <= 128 ? bits / 8 : -1;
    }
    if (t.tag == ATYP_ARRAY && t.arg_count == 1 && t.ival >= 0 && t.ival <= 1024)
    {
        int element_bytes = m1_value_size(t.args[0], depth + 1);
        if (element_bytes < 0 || element_bytes > 4096) { return -1; }
        return element_bytes * (int)t.ival;
    }
    if (t.tag == ATYP_TUPLE && t.arg_count <= 64)
    {
        for (usz i = 0; i < t.arg_count; i++)
        {
            if (m1_value_size(t.args[i], depth + 1) != 0 || m1_value_alignment(t.args[i], depth + 1) != 1) { return -1; }
        }
        return 0;
    }
    return -1;
}
fn int m1_value_alignment(AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return 0; }
    if (t.tag == ATYP_UNIT) { return 1; }
    if (t.tag == ATYP_ARRAY && t.arg_count == 1) { return m1_value_alignment(t.args[0], depth + 1); }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count > 64) { return 0; }
        for (usz i = 0; i < t.arg_count; i++)
        {
            if (m1_value_size(t.args[i], depth + 1) != 0 || m1_value_alignment(t.args[i], depth + 1) != 1) { return 0; }
        }
        return 1;
    }
    int bytes = m1_value_size(t, depth + 1);
    return bytes > 0 && bytes <= 8 ? bytes : 0;
}
fn bool m1_unit_type(AirTyp* t)
{
    return t != null && t.tag == ATYP_UNIT;
}
fn bool m1_return_type(AirTyp* t)
{
    return m1_unit_type(t) || m1_value_type(t, 0);
}
fn bool m1_scalar_type(AirTyp* t)
{
    return t != null && (m1_bool_type(t) || m1_integer_type(t) || m1_float_type(t) || m1_pointer_repr_type(t));
}
fn bool m1_value_type(AirTyp* t, int depth)
{
    if (m1_unit_type(t)) { return true; }
    if (t == null || depth >= 16) { return false; }
    if (t.tag == ATYP_ARROW)
    {
        return m1_function_pointer_type(t) && m1_value_type(t.args[0], depth + 1) &&
               (m1_unit_type(t.args[1]) || m1_value_type(t.args[1], depth + 1));
    }
    if (m1_scalar_type(t)) { return true; }
    if (t.tag == ATYP_NOMINAL) { return t.name != null && t.name[0] != 0; }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count > 64) { return false; }
        for (usz i = 0; i < t.arg_count; i++) { if (!m1_value_type(t.args[i], depth + 1)) { return false; } }
        return true;
    }
    if (t.tag == ATYP_ARRAY)
    {
        return t.arg_count == 1 && t.args[0] != null && t.ival >= 0 && t.ival <= 1024 && m1_value_type(t.args[0], depth + 1);
    }
    return false;
}
fn bool m1_value_type_compatible(AirTyp* expected, AirTyp* actual, int depth)
{
    if (expected == null || depth >= 16) { return false; }
    if (m1_unit_type(expected)) { return m1_unit_type(actual); }
    if (m1_integer_type(expected)) { return m1_integer_compatible(expected, actual); }
    if (m1_bool_type(expected)) { return m1_bool_type(actual); }
    if (m1_float_type(expected)) { return m1_float_type(actual) && expected.tag == actual.tag; }
    if (m1_pointer_type(expected)) { return m1_pointer_type(actual); }
    if (expected.tag == ATYP_ARROW)
    {
        if (!m1_function_pointer_type(expected) || !m1_function_pointer_type(actual)) { return false; }
        return m1_value_type_compatible(expected.args[0], actual.args[0], depth + 1) &&
               m1_value_type_compatible(expected.args[1], actual.args[1], depth + 1);
    }
    if (expected.tag == ATYP_NOMINAL) { return actual != null && actual.tag == ATYP_NOMINAL && same(expected.name, actual.name); }
    if (expected.tag == ATYP_ARRAY)
    {
        return actual != null && actual.tag == ATYP_ARRAY && expected.ival == actual.ival && expected.arg_count == 1 && actual.arg_count == 1 && m1_value_type_compatible(expected.args[0], actual.args[0], depth + 1);
    }
    if (expected.tag != ATYP_TUPLE || actual == null || actual.tag != ATYP_TUPLE || expected.arg_count != actual.arg_count) { return false; }
    for (usz i = 0; i < expected.arg_count; i++) { if (!m1_value_type_compatible(expected.args[i], actual.args[i], depth + 1)) { return false; } }
    return true;
}
fn bool m1_type_text_append(char* out, usz cap, usz* used, char* text)
{
    if (text == null) { return false; }
    for (usz i = 0; text[i] != 0; i++)
    {
        if (*used + 1 >= cap) { return false; }
        out[*used] = text[i]; (*used)++;
    }
    return true;
}
fn bool m1_llvm_type_append(char* out, usz cap, usz* used, AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return false; }
    if (t.tag == ATYP_NOMINAL)
    {
        if (t.name == null || !m1_type_text_append(out, cap, used, (char*)"%\"") ||
            !m1_type_text_append(out, cap, used, t.name) || !m1_type_text_append(out, cap, used, (char*)"\"")) { return false; }
        return true;
    }
    if (t.tag == ATYP_ARRAY)
    {
        if (t.arg_count != 1 || t.args[0] == null) { return false; }
        char[32] count;
        int n = snprintf(&count[0], 32, (char*)"%ld", t.ival);
        if (n < 0 || n >= 32 || !m1_type_text_append(out, cap, used, (char*)"[")) { return false; }
        if (!m1_type_text_append(out, cap, used, &count[0]) || !m1_type_text_append(out, cap, used, (char*)" x ")) { return false; }
        return m1_llvm_type_append(out, cap, used, t.args[0], depth + 1) && m1_type_text_append(out, cap, used, (char*)"]");
    }
    if (t.tag != ATYP_TUPLE) { return m1_type_text_append(out, cap, used, m1_llvm_scalar(t)); }
    // The zero-field tuple is the canonical empty LLVM struct, also used for
    // unit values in aggregate fields and as internal by-value parameters.
    if (t.arg_count == 0) { return m1_type_text_append(out, cap, used, (char*)"{ }"); }
    if (*used + 2 >= cap) { return false; }
    out[*used] = '{'; out[*used + 1] = ' '; *used += 2;
    for (usz i = 0; i < t.arg_count; i++)
    {
        if (i != 0 && !m1_type_text_append(out, cap, used, (char*)", ")) { return false; }
        if (!m1_llvm_type_append(out, cap, used, t.args[i], depth + 1)) { return false; }
    }
    return m1_type_text_append(out, cap, used, (char*)" }");
}
fn char* m1_llvm_bits(int bits)
{
    switch (bits)
    {
        case 8: return (char*)"i8";
        case 16: return (char*)"i16";
        case 32: return (char*)"i32";
        case 64: return (char*)"i64";
        case 128: return (char*)"i128";
        default: return null;
    }
}
fn char* m1_llvm_int(AirTyp* t) { return m1_llvm_bits(m1_int_bits(t)); }
fn char* m1_llvm_float(AirTyp* t)
{
    if (t == null) { return null; }
    if (t.tag == ATYP_F32) { return (char*)"float"; }
    if (t.tag == ATYP_F64) { return (char*)"double"; }
    return null;
}
fn char* m1_llvm_scalar(AirTyp* t)
{
    if (m1_unit_type(t)) { return (char*)"{ }"; }
    if (m1_bool_type(t)) { return (char*)"i1"; }
    if (m1_pointer_repr_type(t)) { return (char*)"ptr"; }
    if (m1_float_type(t)) { return m1_llvm_float(t); }
    return m1_llvm_int(t);
}
fn char* m1_llvm_abi_arg(AirTyp* t)
{
    if (m1_bool_type(t)) { return (char*)"i1 zeroext"; }
    if (m1_pointer_repr_type(t)) { return (char*)"ptr"; }
    if (m1_float_type(t)) { return m1_llvm_float(t); }
    int bits = m1_int_bits(t);
    if (bits == 8 || bits == 16)
    {
        if (m1_unsigned(t)) { return bits == 8 ? (char*)"i8 zeroext" : (char*)"i16 zeroext"; }
        return bits == 8 ? (char*)"i8 signext" : (char*)"i16 signext";
    }
    return m1_llvm_int(t);
}
fn char* m1_llvm_abi_ret(AirTyp* t)
{
    if (m1_unit_type(t)) { return (char*)"void"; }
    if (m1_bool_type(t)) { return (char*)"zeroext i1"; }
    if (m1_pointer_repr_type(t)) { return (char*)"ptr"; }
    if (m1_float_type(t)) { return m1_llvm_float(t); }
    int bits = m1_int_bits(t);
    if (bits == 8 || bits == 16)
    {
        if (m1_unsigned(t)) { return bits == 8 ? (char*)"zeroext i8" : (char*)"zeroext i16"; }
        return bits == 8 ? (char*)"signext i8" : (char*)"signext i16";
    }
    return m1_llvm_int(t);
}
fn bool m1_unsigned(AirTyp* t)
{
    return t != null && (t.tag == ATYP_U8 || t.tag == ATYP_U16 || t.tag == ATYP_U32 || t.tag == ATYP_U64 || t.tag == ATYP_U128 || t.tag == ATYP_USZ || t.tag == ATYP_CHAR);
}
fn bool m1_known_type(AirTyp* t)
{
    return t != null && t.tag != ATYP_INFER;
}
fn bool m1_integer_compatible(AirTyp* expected, AirTyp* actual)
{
    if (actual == null || actual.tag == ATYP_INFER) { return true; }
    if (!m1_integer_type(expected) || !m1_integer_type(actual) || m1_int_bits(expected) != m1_int_bits(actual)) { return false; }
    if (m1_known_type(expected) && m1_known_type(actual) && m1_unsigned(expected) != m1_unsigned(actual)) { return false; }
    return true;
}
fn bool m1_scalar_compatible(AirTyp* expected, AirTyp* actual)
{
    if (m1_float_type(expected)) { return m1_float_type(actual) && expected.tag == actual.tag; }
    return m1_integer_compatible(expected, actual);
}
fn bool m1_int_fits(long value, int bits, bool uns)
{
    if (bits <= 0 || (bits > 64 && bits != 128)) { return false; }
    if (uns && value < 0) { return false; }
    if (bits == 128) { return true; }
    if (bits == 64) { return true; }
    long edge = 1;
    edge = edge << (uns ? bits : bits - 1);
    if (uns) { return value < edge; }
    return value >= -edge && value < edge;
}
fn bool m1_contextual_int_fits(AirPrd* p, AirTyp* t)
{
    if (p == null || p.tag != APRD_INT || m1_known_type(p.ty)) { return true; }
    return m1_int_fits(p.ival, m1_int_bits(t), m1_unsigned(t));
}
fn bool m1_safe_name(char* name)
{
    if (name == null || name[0] == 0) { return false; }
    for (usz i = 0; name[i] != 0; i++)
    {
        char c = name[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$' || c == '.' || (i > 0 && c >= '0' && c <= '9');
        if (!ok) { return false; }
    }
    return true;
}

fn AirDecl* m1_find_data_decl(AirDecl** decls, usz decl_count, char* name)
{
    if (decls == null || name == null) { return null; }
    for (usz i = 0; i < decl_count; i++)
    {
        AirDecl* d = decls[i];
        if (d != null && d.tag == ADECL_DATA && same(d.name, name)) { return d; }
    }
    return null;
}
// Product-record view over declarations: a single-constructor `data` is a
// product record, and a *plain* `codata` decl — non-generic, unqualified,
// whose destructors are all nullary projections — is a product record too
// (pfront lowers PEAR struct declarations exactly so; struct construction is
// a `record{_f0 = T, ...}` producer and field access is `field name #i`).
// Everything with dtor parameters (real methods), type parameters,
// multiplicities, or attributes stays outside this view and fails closed.
fn AirDecl* m1_find_record_decl(AirDecl** decls, usz decl_count, char* name)
{
    if (decls == null || name == null) { return null; }
    for (usz i = 0; i < decl_count; i++)
    {
        AirDecl* d = decls[i];
        if (d != null && (d.tag == ADECL_DATA || d.tag == ADECL_CODATA) && same(d.name, name)) { return d; }
    }
    return null;
}
fn bool m1_record_codata_decl(AirDecl* d)
{
    if (d == null || d.tag != ADECL_CODATA || !m1_safe_name(d.name) || d.typaram_count != 0 ||
        d.attr_count != 0 || d.mult != AMULT_UNR || d.dtor_count == 0 || d.dtor_count > 64) { return false; }
    for (usz i = 0; i < d.dtor_count; i++)
    {
        AirDtorDecl* dt = d.dtors[i];
        if (dt == null || !m1_safe_name(dt.name) || dt.param_count != 0) { return false; }
    }
    return true;
}
fn usz m1_record_field_count(AirDecl* d)
{
    if (d == null) { return 0; }
    if (d.tag == ADECL_CODATA) { return d.dtor_count; }
    return d.ctor_count == 1 && d.ctors[0] != null ? d.ctors[0].field_count : 0;
}
fn char* m1_record_field_name(AirDecl* d, usz i)
{
    if (d == null || i >= m1_record_field_count(d)) { return null; }
    if (d.tag == ADECL_CODATA) { AirDtorDecl* dt = d.dtors[i]; return dt != null ? dt.name : null; }
    AirField* f = d.ctors[0].fields[i]; return f != null ? f.name : null;
}
fn AirTyp* m1_record_field_ty(AirDecl* d, usz i)
{
    if (d == null || i >= m1_record_field_count(d)) { return null; }
    if (d.tag == ADECL_CODATA) { AirDtorDecl* dt = d.dtors[i]; return dt != null ? dt.return_ty : null; }
    AirField* f = d.ctors[0].fields[i]; return f != null ? f.ty : null;
}
// Resolve which record declaration a record producer builds: an explicit
// `: nominal T` ascription, or the pfront convention of a leading
// `_f0 = TypeName` marker field (no ascription). *marker is set to 1 when
// the leading init is the marker and does not name a nominal field.
fn AirDecl* m1_record_producer_decl(AirPrd* p, AirDecl** decls, usz decl_count, usz* marker)
{
    if (marker != null) { *marker = 0; }
    if (p == null || p.tag != APRD_RECORD) { return null; }
    if (p.ty != null && p.ty.tag == ATYP_NOMINAL) { return m1_find_record_decl(decls, decl_count, p.ty.name); }
    if ((p.ty == null || p.ty.tag == ATYP_INFER) && p.rec_init_count >= 1 &&
        p.rec_inits[0] != null && same(p.rec_inits[0].name, "_f0") &&
        p.rec_inits[0].value != null && p.rec_inits[0].value.tag == APRD_VAR)
    {
        if (marker != null) { *marker = 1; }
        return m1_find_record_decl(decls, decl_count, p.rec_inits[0].value.name);
    }
    return null;
}

// pfront erases struct parameter annotations to `infer`. Recover them by
// unique field projection: a bare parameter projected with `field name #i`
// is pinned to the unique product record (single-constructor data or plain
// codata) declaring that field at that index. Zero matches leave the
// parameter alone (a later projection reports a positioned error); two or
// more matching records keep the parameter ambiguous and fail closed when
// projected. Only direct `cut(<var | field ...>)` projections starting from a
// parameter name count — locals rebound through comu are answers, not
// evidence, because AST names have no shadowing information.
fn void m1_infer_record_field_at(AirDecl* fn_d, char* var_name, AirCns* k, AirDecl** decls, usz decl_count, AirArena* arena)
{
    if (fn_d == null || var_name == null || k == null || k.name == null || k.idx < 0) { return; }
    AirBinder* param = null;
    for (usz i = 0; i < fn_d.param_count; i++)
    {
        if (fn_d.params[i] != null && same(fn_d.params[i].name, var_name)) { param = fn_d.params[i]; break; }
    }
    if (param == null || (param.ty != null && param.ty.tag != ATYP_INFER)) { return; }
    AirDecl* found = null; bool ambiguous = false;
    for (usz i = 0; i < decl_count; i++)
    {
        AirDecl* cand = decls[i];
        if (cand == null || (cand.tag != ADECL_DATA && cand.tag != ADECL_CODATA)) { continue; }
        if (cand.tag == ADECL_CODATA ? !m1_record_codata_decl(cand) : cand.ctor_count != 1) { continue; }
        if ((usz)k.idx < m1_record_field_count(cand) && same(m1_record_field_name(cand, (usz)k.idx), k.name))
        {
            if (found != null && !same(found.name, cand.name)) { ambiguous = true; break; }
            found = cand;
        }
    }
    if (found == null || ambiguous) { return; }
    AirTyp* t = air_ir::air_mk_typ_simple(arena, ATYP_NOMINAL);
    if (t != null) { t.name = found.name; param.ty = t; }
}
fn void m1_infer_record_params_walk(AirDecl* fn_d, AirCmd* c, AirDecl** decls, usz decl_count, AirArena* arena, int depth)
{
    if (c == null || depth >= 64) { return; }
    if (c.tag == ACMD_CUT && c.prd != null && c.prd.tag == APRD_VAR && c.cns != null && c.cns.tag == ACNS_FIELD)
    {
        m1_infer_record_field_at(fn_d, c.prd.name, c.cns, decls, decl_count, arena);
    }
    AirCns* k = c.cns;
    while (k != null)
    {
        if (k.tag == ACNS_COMU) { m1_infer_record_params_walk(fn_d, k.body, decls, decl_count, arena, depth + 1); }
        for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null) { m1_infer_record_params_walk(fn_d, k.branches[i].body, decls, decl_count, arena, depth + 1); } }
        for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null) { m1_infer_record_params_walk(fn_d, k.cobranches[i].body, decls, decl_count, arena, depth + 1); } }
        k = k.tail;
    }
    m1_infer_record_params_walk(fn_d, c.body, decls, decl_count, arena, depth + 1);
    m1_infer_record_params_walk(fn_d, c.next, decls, decl_count, arena, depth + 1);
    m1_infer_record_params_walk(fn_d, c.then_c, decls, decl_count, arena, depth + 1);
    m1_infer_record_params_walk(fn_d, c.else_c, decls, decl_count, arena, depth + 1);
    m1_infer_record_params_walk(fn_d, c.handled, decls, decl_count, arena, depth + 1);
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null) { m1_infer_record_params_walk(fn_d, c.branches[i].body, decls, decl_count, arena, depth + 1); } }
}fn bool m1_nullary_enum_decl(AirDecl* d)
{
    if (d == null || d.tag != ADECL_DATA || d.typaram_count != 0 || d.ctor_count < 2 || d.ctor_count > 64 || d.attr_count != 0 || d.mult != AMULT_UNR) { return false; }
    for (usz i = 0; i < d.ctor_count; i++)
    {
        AirCtorDecl* ctor = d.ctors[i];
        if (ctor == null || !m1_safe_name(ctor.name) || ctor.field_count != 0 ||
            (ctor.result_ty != null && (ctor.result_ty.tag != ATYP_NOMINAL || !same(ctor.result_ty.name, d.name)))) { return false; }
        for (usz j = 0; j < i; j++) { if (d.ctors[j] != null && same(d.ctors[j].name, ctor.name)) { return false; } }
    }
    return true;
}
fn bool m1_tagged_sum_decl(AirDecl* d)
{
    if (d == null || d.tag != ADECL_DATA || d.typaram_count != 0 || d.ctor_count < 2 || d.ctor_count > 64 || d.attr_count != 0 || d.mult != AMULT_UNR) { return false; }
    for (usz i = 0; i < d.ctor_count; i++)
    {
        AirCtorDecl* ctor = d.ctors[i];
        if (ctor == null || !m1_safe_name(ctor.name) || ctor.field_count > 64 ||
            (ctor.result_ty != null && (ctor.result_ty.tag != ATYP_NOMINAL || !same(ctor.result_ty.name, d.name)))) { return false; }
        for (usz j = 0; j < i; j++) { if (same(d.ctors[j].name, ctor.name)) { return false; } }
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirField* field = ctor.fields[j];
            if (field == null || !m1_safe_name(field.name)) { return false; }
            for (usz k = 0; k < j; k++) { if (same(ctor.fields[k].name, field.name)) { return false; } }
        }
    }
    return true;
}
// Sum payloads are copied through a typed scratch representation. Pointer-bearing
// and unit fields are excluded until their provenance/zero-size rules are modeled.
fn bool m1_sum_payload_type(AirTyp* t, AirDecl** decls, usz decl_count, int depth)
{
    if (t == null || depth >= 16 || m1_unit_type(t) || m1_pointer_repr_type(t)) { return false; }
    if (m1_scalar_type(t)) { return true; }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count > 64) { return false; }
        for (usz i = 0; i < t.arg_count; i++) { if (!m1_sum_payload_type(t.args[i], decls, decl_count, depth + 1)) { return false; } }
        return true;
    }
    if (t.tag == ATYP_ARRAY)
    {
        return t.arg_count == 1 && t.ival >= 0 && t.ival <= 1024 && m1_sum_payload_type(t.args[0], decls, decl_count, depth + 1);
    }
    if (t.tag == ATYP_NOMINAL)
    {
        AirDecl* d = m1_find_data_decl(decls, decl_count, t.name);
        if (d == null || d.typaram_count != 0 || d.attr_count != 0) { return false; }
        if (d.ctor_count == 1 && d.ctors[0] != null)
        {
            for (usz i = 0; i < d.ctors[0].field_count; i++) { if (!m1_sum_payload_type(d.ctors[0].fields[i].ty, decls, decl_count, depth + 1)) { return false; } }
            return true;
        }
        if (m1_tagged_sum_decl(d))
        {
            for (usz i = 0; i < d.ctor_count; i++)
            {
                for (usz j = 0; j < d.ctors[i].field_count; j++)
                {
                    if (!m1_sum_payload_type(d.ctors[i].fields[j].ty, decls, decl_count, depth + 1)) { return false; }
                }
            }
            return true;
        }
    }
    return false;
}
fn bool m1_backend_type(AirTyp* t, AirDecl** decls, usz decl_count, int depth)
{
    if (t == null || depth >= 16) { return false; }
    if (m1_unit_type(t) || m1_scalar_type(t)) { return true; }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count > 64) { return false; }
        for (usz i = 0; i < t.arg_count; i++) { if (!m1_backend_type(t.args[i], decls, decl_count, depth + 1)) { return false; } }
        return true;
    }
    if (t.tag == ATYP_ARRAY)
    {
        return t.arg_count == 1 && t.ival >= 0 && t.ival <= 1024 && m1_backend_type(t.args[0], decls, decl_count, depth + 1);
    }
    if (t.tag == ATYP_NOMINAL)
    {
        AirDecl* d = m1_find_record_decl(decls, decl_count, t.name);        if (d == null || !m1_safe_name(d.name) || d.typaram_count != 0 || d.attr_count != 0) { return false; }
        if (m1_nullary_enum_decl(d)) { return true; }
        if (m1_tagged_sum_decl(d))
        {
            for (usz i = 0; i < d.ctor_count; i++)
            {
                for (usz j = 0; j < d.ctors[i].field_count; j++)
                {
                    AirTyp* field_type = d.ctors[i].fields[j].ty;
                    if (!m1_sum_payload_type(field_type, decls, decl_count, depth + 1) || !m1_backend_type(field_type, decls, decl_count, depth + 1)) { return false; }
                }
            }
            return true;
        }
        if (d.tag == ADECL_CODATA)
        {
            // A codata whose destructors are all nullary is a product record
            // (a PEAR struct). Parameterized destructors are real methods and
            // stay outside the fragment.
            if (!m1_record_codata_decl(d)) { return false; }
            for (usz i = 0; i < d.dtor_count; i++)
            {
                AirTyp* fty = m1_record_field_ty(d, i);
                if (fty == null || !m1_backend_type(fty, decls, decl_count, depth + 1)) { return false; }
            }
            return true;
        }
        if (d.ctor_count != 1 || d.ctors[0] == null || d.ctors[0].field_count > 64) { return false; }
        if (d.ctors[0].result_ty != null && (d.ctors[0].result_ty.tag != ATYP_NOMINAL || !same(d.ctors[0].result_ty.name, d.name))) { return false; }
        for (usz i = 0; i < d.ctors[0].field_count; i++)
        {
            AirField* field = d.ctors[0].fields[i];
            if (field == null || !m1_safe_name(field.name) || !m1_backend_type(field.ty, decls, decl_count, depth + 1)) { return false; }
        }
        return true;
    }
    return false;
}

// A C aggregate is admitted only when its in-memory fields have an unambiguous
// C-compatible LLVM representation. In particular, AIR bool uses i1 while C
// struct bool fields are usually i8, so bool and unit fields are excluded.
fn bool m1_c_abi_field_type(AirTyp* t, AirDecl** decls, usz decl_count, int depth)
{
    if (t == null || depth >= 16 || m1_unit_type(t) || m1_bool_type(t)) { return false; }
    if (m1_integer_type(t)) { int bits = m1_int_bits(t); return bits >= 8 && bits <= 64; }    if (m1_float_type(t) || m1_pointer_repr_type(t)) { return true; }
    if (t.tag == ATYP_ARRAY)
    {
        return t.arg_count == 1 && t.ival > 0 && t.ival <= 1024 && m1_c_abi_field_type(t.args[0], decls, decl_count, depth + 1);
    }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count == 0 || t.arg_count > 64) { return false; }
        for (usz i = 0; i < t.arg_count; i++) { if (!m1_c_abi_field_type(t.args[i], decls, decl_count, depth + 1)) { return false; } }
        return true;
    }
    if (t.tag == ATYP_NOMINAL)
    {
        AirDecl* d = m1_find_record_decl(decls, decl_count, t.name);
        if (d != null && d.tag == ADECL_CODATA && !m1_record_codata_decl(d)) { return false; }
        if (m1_record_field_count(d) == 0) { return false; }
        for (usz i = 0; i < m1_record_field_count(d); i++)
        {
            if (m1_record_field_ty(d, i) == null || !m1_c_abi_field_type(m1_record_field_ty(d, i), decls, decl_count, depth + 1)) { return false; }
        }
        return true;
    }
    return false;
}

fn bool m1_function_signature(AirDecl* d)
{
    if (d == null || (d.tag != ADECL_DEF && d.tag != ADECL_DECLARE) || d.typaram_count != 0 || d.param_count > 64) { return false; }
    if (d.tag == ADECL_DEF)
    {
        if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && !m1_return_type(d.ret_ty)) { return false; }
        if (d.is_extern || d.is_varargs || d.extern_link != null || d.def_body == null) { return false; }
        for (usz i = 0; i < d.param_count; i++)
        {
            if (d.params[i] == null || (d.params[i].ty != null && d.params[i].ty.tag != ATYP_INFER && !m1_value_type(d.params[i].ty, 0))) { return false; }
        }
        return true;
    }
    if (!m1_scalar_type(d.ret_ty) && !m1_unit_type(d.ret_ty) &&
        (d.ret_ty == null || (d.ret_ty.tag != ATYP_TUPLE && d.ret_ty.tag != ATYP_NOMINAL))) { return false; }
    for (usz i = 0; i < d.param_count; i++)
    {
        if (d.params[i] == null || (!m1_scalar_type(d.params[i].ty) &&
            (d.params[i].ty == null || (d.params[i].ty.tag != ATYP_TUPLE && d.params[i].ty.tag != ATYP_NOMINAL)))) { return false; }
    }    return d.is_extern && d.def_body == null && !d.is_varargs && m1_decl_callconv(d) >= 0 && m1_extern_attrs_ok(d) &&
           (d.extern_link == null || m1_safe_name(d.extern_link));
}
// M10 calling conventions: 0 = default (ccc), 1 = fastcc;
// -1 = conflicting markers, -2 = unsupported value or value-less attribute.
fn int m1_decl_callconv(AirDecl* d)
{
    if (d == null) { return 0; }
    int cc = d.is_fastcc ? 1 : 0;
    bool cc_seen = d.is_fastcc;
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (!same(d.attr_name[i], "callconv")) { continue; }
        if (d.attr_str[i] == null || d.attr_has_int[i]) { return -2; }
        int acc = -2;
        if (same(d.attr_str[i], "cdecl") || same(d.attr_str[i], "c")) { acc = 0; }
        if (same(d.attr_str[i], "fastcc")) { acc = 1; }
        if (acc < 0) { return -2; }
        if (cc_seen && acc != cc) { return -1; }
        cc = acc; cc_seen = true;
    }
    return cc;
}
fn char* m1_decl_attr_string(AirDecl* d, char* name)
{
    if (d == null || name == null) { return null; }
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (same(d.attr_name[i], name) && d.attr_str[i] != null && !d.attr_has_int[i]) { return d.attr_str[i]; }
    }
    return null;
}
fn bool m1_decl_flag(AirDecl* d, char* name)
{
    if (d == null || name == null) { return false; }
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (same(d.attr_name[i], name) && d.attr_str[i] == null && !d.attr_has_int[i]) { return true; }
    }
    return false;
}
fn bool m1_section_name_ok(char* s)
{
    if (s == null || s[0] == 0) { return false; }
    usz n = 0;
    while (s[n] != 0)
    {
        char ch = s[n];
        bool ok = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
                  ch == '.' || ch == '_' || ch == '-';
        if (!ok) { return false; }
        n++;
        if (n >= 64) { return false; }
    }
    return true;
}
// Function-attribute policy for definitions: unknown attributes are rejected
// (positioned, at the module gate) instead of being silently dropped.
fn char* m1_def_attr_problem(AirDecl* d)
{
    if (d == null) { return null; }
    for (usz i = 0; i < d.attr_count; i++)
    {
        char* nm = d.attr_name[i];
        if (nm == null) { return (char*)"malformed function attribute"; }
        if (same(nm, "callconv")) { continue; }
        if (same(nm, "noinline") || same(nm, "alwaysinline") || same(nm, "cold") || same(nm, "naked"))
        {
            if (d.attr_str[i] != null || d.attr_has_int[i]) { return (char*)"function attributes `noinline`, `alwaysinline`, `cold` and `naked` take no value"; }
            continue;
        }
        if (same(nm, "section"))
        {
            if (d.attr_str[i] == null || d.attr_has_int[i] || !m1_section_name_ok(d.attr_str[i])) { return (char*)"function attribute `section` requires a section-name string (letters, digits, `.`, `_`, `-`)"; }
            continue;
        }
        if (same(nm, "export"))
        {
            if (d.attr_str[i] == null || d.attr_has_int[i] || !m1_safe_name(d.attr_str[i])) { return (char*)"function attribute `export` requires a symbol-safe string name"; }
            continue;
        }
        return (char*)"unsupported function attribute (supported: callconv, noinline, alwaysinline, cold, naked, section, export)";
    }
    return null;
}
fn bool m1_extern_attrs_ok(AirDecl* d)
{
    if (d == null) { return false; }
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (!same(d.attr_name[i], "callconv")) { return false; }
    }
    return true;
}
// M10: an exported definition renames its symbol; every definitional and
// referential site flows through m1_link_name so the rename is deterministic.
fn char* m1_link_name(AirDecl* d)
{
    if (d == null) { return null; }
    if (d.extern_link != null) { return d.extern_link; }
    char* ex = m1_decl_attr_string(d, "export");
    return ex == null ? d.name : ex;
}
fn AirDecl* M1Gen.find_global(M1Gen* g, char* name)
{
    if (name == null) { return null; }
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d != null && d.tag == ADECL_GLOBAL && same(d.name, name)) { return d; }
    }
    return null;
}
fn long m1_align_up(long value, int alignment)
{
    if (alignment <= 1) { return value; }
    long rem = value % alignment;
    return rem == 0 ? value : value + alignment - rem;
}
fn bool M1Gen.tagged_sum_layout(M1Gen* g, AirDecl* d, int depth, int* align_out, long* payload_offset_out, long* payload_size_out, int* slot_bits_out, long* slot_count_out, long* total_size_out)
{
    if (d == null || !m1_tagged_sum_decl(d) || m1_nullary_enum_decl(d) || depth >= 16) { return false; }
    int payload_align = 1;
    long max_variant_size = 0;
    for (usz i = 0; i < d.ctor_count; i++)
    {
        long offset = 0;
        int variant_align = 1;
        AirCtorDecl* ctor = d.ctors[i];
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirTyp* field_type = ctor.fields[j].ty;
            int field_align = g.type_alignment(field_type, depth + 1);
            long field_size = g.type_size(field_type, depth + 1);
            if (field_align <= 0 || field_size <= 0 || field_size > 1048576) { return false; }
            offset = m1_align_up(offset, field_align);
            if (offset < 0 || field_size > 1048576 - offset) { return false; }
            offset += field_size;
            if (field_align > variant_align) { variant_align = field_align; }
        }
        long variant_size = m1_align_up(offset, variant_align);
        if (variant_size < 0 || variant_size > 1048576) { return false; }
        if (variant_size > max_variant_size) { max_variant_size = variant_size; }
        if (variant_align > payload_align) { payload_align = variant_align; }
    }
    // The tag is i32. The payload backing array uses an integer element whose
    // alignment equals the strictest field alignment, so LLVM's struct layout
    // places payload bytes at the same computed aligned offset.
    if (payload_align < 4) { payload_align = 4; }
    long payload_offset = m1_align_up(4, payload_align);
    long payload_size = m1_align_up(max_variant_size, payload_align);
    if (payload_offset < 0 || payload_size <= 0 || payload_size > 1048576 - payload_offset) { return false; }
    long slots = payload_size / payload_align;
    if (slots <= 0 || slots > 1048576 / payload_align) { return false; }
    align_out[0] = payload_align;
    payload_offset_out[0] = payload_offset;
    payload_size_out[0] = payload_size;
    slot_bits_out[0] = payload_align * 8;
    slot_count_out[0] = slots;
    total_size_out[0] = payload_offset + payload_size;
    return true;
}
fn bool M1Gen.tagged_sum_field_offset(M1Gen* g, AirDecl* d, usz ctor_index, usz field_index, long* out_offset)
{
    if (d == null || ctor_index >= d.ctor_count || d.ctors[ctor_index] == null || field_index >= d.ctors[ctor_index].field_count) { return false; }
    int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
    if (!g.tagged_sum_layout(d, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size)) { return false; }
    AirCtorDecl* ctor = d.ctors[ctor_index];
    long offset = 0;
    for (usz i = 0; i <= field_index; i++)
    {
        int field_align = g.type_alignment(ctor.fields[i].ty, 0);
        long field_size = g.type_size(ctor.fields[i].ty, 0);
        if (field_align <= 0 || field_size <= 0) { return false; }
        offset = m1_align_up(offset, field_align);
        if (offset < 0 || field_size > 1048576 - offset) { return false; }
        if (i == field_index) { out_offset[0] = offset; return true; }
        offset += field_size;
    }
    return false;
}
fn int M1Gen.type_alignment(M1Gen* g, AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return 0; }
    if (t.tag == ATYP_UNIT) { return 1; }
    if (t.tag == ATYP_PTR || t.tag == ATYP_ARROW) { return m1_target_ptr_bytes(); }
    if (t.tag == ATYP_BOOL || t.tag == ATYP_I8 || t.tag == ATYP_U8) { return 1; }
    if (t.tag == ATYP_I16 || t.tag == ATYP_U16) { return 2; }
    if (t.tag == ATYP_I32 || t.tag == ATYP_U32 || t.tag == ATYP_F32 || t.tag == ATYP_CHAR) { return 4; }
    if (t.tag == ATYP_ISZ || t.tag == ATYP_USZ) { return m1_target_ptr_bytes(); }
    if (t.tag == ATYP_I64 || t.tag == ATYP_U64 || t.tag == ATYP_F64) { return 8; }
    if (t.tag == ATYP_I128 || t.tag == ATYP_U128) { return 16; }
    if (t.tag == ATYP_ARRAY && t.arg_count == 1) { return g.type_alignment(t.args[0], depth + 1); }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count > 64) { return 0; }
        int max_align = 1;
        for (usz i = 0; i < t.arg_count; i++)
        {
            int a = g.type_alignment(t.args[i], depth + 1);
            if (a == 0) { return 0; }
            if (a > max_align) { max_align = a; }
        }
        return max_align;
    }
    if (t.tag == ATYP_NOMINAL)
    {
        AirDecl* d = m1_find_record_decl(g.decls, g.decl_count, t.name);
        if (m1_nullary_enum_decl(d)) { return 4; }
        if (m1_tagged_sum_decl(d))
        {
            int align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
            return g.tagged_sum_layout(d, depth, &align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size) ? align : 0;
        }
        if (d == null || (d.tag == ADECL_CODATA && !m1_record_codata_decl(d))) { return 0; }
        usz fcount = m1_record_field_count(d);
        if (fcount > 64 || (d.tag == ADECL_DATA && (d.ctor_count != 1 || d.ctors[0] == null))) { return 0; }
        int max_align = 1;
        for (usz i = 0; i < fcount; i++)
        {
            int a = g.type_alignment(m1_record_field_ty(d, i), depth + 1);
            if (a == 0) { return 0; }
            if (a > max_align) { max_align = a; }
        }
        return max_align;
    }
    return 0;
}
fn long M1Gen.type_size(M1Gen* g, AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return -1; }
    if (t.tag == ATYP_UNIT) { return 0; }
    if (t.tag == ATYP_BOOL || t.tag == ATYP_I8 || t.tag == ATYP_U8) { return 1; }
    if (t.tag == ATYP_I16 || t.tag == ATYP_U16) { return 2; }
    if (t.tag == ATYP_I32 || t.tag == ATYP_U32 || t.tag == ATYP_F32 || t.tag == ATYP_CHAR) { return 4; }
    if (t.tag == ATYP_I64 || t.tag == ATYP_U64 || t.tag == ATYP_F64) { return 8; }
    if (t.tag == ATYP_ISZ || t.tag == ATYP_USZ || t.tag == ATYP_PTR || t.tag == ATYP_ARROW) { return m1_target_ptr_bytes(); }
    if (t.tag == ATYP_I128 || t.tag == ATYP_U128) { return 16; }
    if (t.tag == ATYP_ARRAY && t.arg_count == 1 && t.ival >= 0 && t.ival <= 1024)
    {
        long size = g.type_size(t.args[0], depth + 1);
        int align = g.type_alignment(t.args[0], depth + 1);
        if (size < 0 || align == 0 || size > 1048576) { return -1; }
        long stride = m1_align_up(size, align);
        if (stride < 0 || (t.ival > 0 && stride > 1048576 / t.ival)) { return -1; }
        return stride * t.ival;
    }
    if (t.tag == ATYP_TUPLE || t.tag == ATYP_NOMINAL)
    {
        usz count = t.arg_count;
        if (t.tag == ATYP_NOMINAL)
        {
            AirDecl* d = m1_find_record_decl(g.decls, g.decl_count, t.name);
            if (m1_nullary_enum_decl(d)) { return 4; }
            if (m1_tagged_sum_decl(d))
            {
                int align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
                return g.tagged_sum_layout(d, depth, &align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size) ? total_size : -1;
            }
            if (d == null || (d.tag == ADECL_CODATA && !m1_record_codata_decl(d)) || (d.tag == ADECL_DATA && (d.ctor_count != 1 || d.ctors[0] == null))) { return -1; }
            count = d.tag == ADECL_CODATA ? d.dtor_count : d.ctors[0].field_count;
            if (count > 64) { return -1; }
        }
        else if (count > 64) { return -1; }
        long offset = 0; int max_align = 1;
        for (usz i = 0; i < count; i++)
        {
            AirTyp* field = t.tag == ATYP_TUPLE ? t.args[i] : m1_record_field_ty(m1_find_record_decl(g.decls, g.decl_count, t.name), i);
            int align = g.type_alignment(field, depth + 1);
            long size = g.type_size(field, depth + 1);
            if (align == 0 || size < 0) { return -1; }
            offset = m1_align_up(offset, align);
            if (offset < 0 || size > 1048576 - offset) { return -1; }
            offset += size;
            if (align > max_align) { max_align = align; }
        }
        long total = m1_align_up(offset, max_align);
        return total >= 0 && total <= 1048576 ? total : -1;
    }
    return -1;
}
fn bool m1_c_abi_aggregate_type(AirTyp* t)
{
    return t != null && (t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY || t.tag == ATYP_NOMINAL);
}
fn char* M1Gen.c_abi_field_problem(M1Gen* g, AirTyp* t, int depth)
{
    if (t == null || depth >= 16) { return (char*)"missing or excessively nested aggregate field"; }
    if (m1_bool_type(t)) { return (char*)"bool fields use AIR i1 and are not C-compatible"; }
    if (m1_unit_type(t)) { return (char*)"unit fields have no C object representation"; }
    if (m1_integer_type(t))
    {
        int bits = m1_int_bits(t);
        return bits >= 8 && bits <= 64 ? null : (char*)"aggregate integer fields must be 8..64 bits";
    }
    if (m1_float_type(t) || m1_pointer_repr_type(t)) { return null; }
    if (t.tag == ATYP_ARRAY)
    {
        if (t.arg_count != 1 || t.ival <= 0 || t.ival > 1024) { return (char*)"aggregate arrays must have 1..1024 fixed elements"; }
        return g.c_abi_field_problem(t.args[0], depth + 1);
    }
    if (t.tag == ATYP_TUPLE)
    {
        if (t.arg_count == 0 || t.arg_count > 64) { return (char*)"empty or oversized tuple fields are not C aggregates"; }
        for (usz i = 0; i < t.arg_count; i++)
        {
            char* problem = g.c_abi_field_problem(t.args[i], depth + 1);
            if (problem != null) { return problem; }
        }
        return null;
    }
    if (t.tag == ATYP_NOMINAL)
    {
        AirDecl* d = m1_find_record_decl(g.decls, g.decl_count, t.name);
        if (d == null || d.typaram_count != 0 || d.attr_count != 0) { return (char*)"nested records must be non-generic, plain, non-empty products"; }
        if (d.tag == ADECL_DATA && d.ctor_count != 1) { return (char*)"tagged sums (multi-constructor data) cannot cross the external C boundary"; }
        if (d.tag == ADECL_CODATA && !m1_record_codata_decl(d)) { return (char*)"codata with parameterized destructors cannot cross the external C boundary"; }
        if (m1_record_field_count(d) == 0)
        { return (char*)"nested records must be non-generic, plain, non-empty products"; }
        for (usz i = 0; i < m1_record_field_count(d); i++)
        {
            if (m1_record_field_name(d, i) == null) { return (char*)"record contains a missing field declaration"; }
            char* problem = g.c_abi_field_problem(m1_record_field_ty(d, i), depth + 1);
            if (problem != null) { return problem; }
        }
        return null;
    }
    return (char*)"unsupported aggregate field type";
}
fn char* M1Gen.external_aggregate_problem(M1Gen* g, AirTyp* t)
{
    if (!m1_c_abi_aggregate_type(t)) { return (char*)"external signature is not a supported C aggregate"; }
    char* field_problem = g.c_abi_field_problem(t, 0);
    if (field_problem != null) { return field_problem; }
    long size = g.type_size(t, 0);
    int align = g.type_alignment(t, 0);
    if (size <= 0 || size > 1048576 || align <= 0) { return (char*)"aggregate layout is empty, oversized, or has unknown alignment"; }
    return null;
}
fn bool M1Gen.external_aggregate_indirect(M1Gen* g, AirTyp* t)
{
    return m1_c_abi_aggregate_type(t) && g.type_size(t, 0) > 16;
}
fn bool M1Gen.note_external_aggregate_failure(M1Gen* g, AirDecl* target, AirTyp* t, int line, int col)
{
    char* problem = g.external_aggregate_problem(t);
    char[768] message;
    char* name = target == null || target.name == null ? (char*)"?" : target.name;
    int n = snprintf(&message[0], 768, (char*)"unsupported external aggregate form in definition `%s`: %s", name, problem == null ? (char*)"unknown C ABI layout" : problem);
    if (n < 0 || n >= 768) { return g.note_failure(line, col, (char*)"unsupported external aggregate form in definition"); }
    return g.note_failure(line, col, g.arena.dup(&message[0], (usz)n));
}
fn bool M1Gen.note_indirect_aggregate_failure(M1Gen* g, AirTyp* t, char* role, int line, int col)
{
    long size = g.type_size(t, 0);
    char* layout_problem = g.external_aggregate_problem(t);
    char* reason = layout_problem != null ? layout_problem : (char*)"C byval/sret and internal LLVM aggregate ABIs differ above 16 bytes";
    char[768] message;
    char* name = g.current_function == null ? (char*)"?" : g.current_function;
    int n = snprintf(&message[0], 768, (char*)"unsupported indirect-call aggregate %s (%ld bytes) in definition `%s`: %s", role, size, name, reason);
    if (n < 0 || n >= 768) { return g.note_failure(line, col, (char*)"unsupported indirect-call aggregate ABI"); }
    return g.note_failure(line, col, g.arena.dup(&message[0], (usz)n));
}
fn long M1Gen.field_offset(M1Gen* g, AirTyp* t, long field_index)
{
    if (t == null || field_index < 0) { return -1; }
    usz count = t.tag == ATYP_TUPLE ? t.arg_count : 0;
    AirDecl* d = null;
    if (t.tag == ATYP_NOMINAL)
    {
        d = m1_find_record_decl(g.decls, g.decl_count, t.name);
        if (d == null || (d.tag == ADECL_CODATA && !m1_record_codata_decl(d)) || (d.tag == ADECL_DATA && (d.ctor_count != 1 || d.ctors[0] == null))) { return -1; }
        count = m1_record_field_count(d);
    }
    if (field_index >= (long)count) { return -1; }
    long offset = 0;
    for (long i = 0; i <= field_index; i++)
    {
        AirTyp* field = t.tag == ATYP_TUPLE ? t.args[(usz)i] : m1_record_field_ty(d, (usz)i);
        int align = g.type_alignment(field, 0);
        long size = g.type_size(field, 0);
        if (align == 0 || size < 0) { return -1; }
        offset = m1_align_up(offset, align);
        if (i == field_index) { return offset; }
        offset += size;
    }
    return -1;
}
fn int M1Gen.prov_index(M1Gen* g, char* value)
{
    if (value == null) { return -1; }
    for (int i = g.provenance_count - 1; i >= 0; i--) { if (same(g.provenance[i].value, value)) { return i; } }
    return -1;
}
fn bool M1Gen.prov_set(M1Gen* g, char* value, AirTyp* pointee, int kind, int alignment, long extent, long offset, bool offset_known, bool writable)
{
    if (value == null || alignment <= 0 || extent < 0) { return false; }
    int at = g.prov_index(value);
    bool fresh = at < 0;
    if (fresh) { if (g.provenance_count >= 1024) { return false; } at = g.provenance_count++; }
    M1Provenance* p = &g.provenance[at];
    if (fresh) { p.allocation = value; }
    p.value = value; p.pointee = pointee; p.kind = kind; p.alignment = alignment;
    p.extent = extent; p.offset = offset; p.offset_known = offset_known; p.freed = false; p.writable = writable;
    return true;
}
fn M1Provenance* M1Gen.prov(M1Gen* g, char* value)
{
    int at = g.prov_index(value);
    return at < 0 ? null : &g.provenance[at];
}
fn bool M1Gen.prov_copy(M1Gen* g, char* from, char* to)
{
    M1Provenance* p = g.prov(from);
    if (p == null || to == null) { return true; }
    AirTyp* pointee = p.pointee; int kind = p.kind;
    int alignment = p.alignment; long extent = p.extent; long offset = p.offset;
    bool known = p.offset_known; bool was_freed = p.freed; bool writable = p.writable; char* allocation = p.allocation;
    if (!g.prov_set(to, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    M1Provenance* copy = g.prov(to); copy.freed = was_freed; copy.allocation = allocation;
    return true;
}
fn bool M1Gen.retype_pointer(M1Gen* g, char* value, AirTyp* pointee)
{
    M1Provenance* p = g.prov(value);
    if (p == null) { return true; }
    int kind = p.kind; int alignment = p.alignment; long extent = p.extent;
    long offset = p.offset; bool known = p.offset_known; bool writable = p.writable; bool was_freed = p.freed;
    if (!g.prov_set(value, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    g.prov(value).freed = was_freed;
    return true;
}
fn int M1Gen.cell_index(M1Gen* g, char* allocation, long offset)
{
    for (int i = g.pointer_cell_count - 1; i >= 0; i--)
    {
        if (same(g.pointer_cells[i].allocation, allocation) && g.pointer_cells[i].offset == offset) { return i; }
    }
    return -1;
}
fn bool M1Gen.cell_set_at(M1Gen* g, char* allocation, long offset, char* value, bool is_null)
{
    if (allocation == null || offset < 0) { return false; }
    int ix = g.cell_index(allocation, offset);
    if (ix < 0)
    {
        if (g.pointer_cell_count >= 512) { return false; }
        ix = g.pointer_cell_count++;
    }
    M1PointerCell* c = &g.pointer_cells[ix];
    c.allocation = allocation; c.offset = offset; c.is_null = is_null;
    c.value_allocation = null; c.pointee = null; c.kind = M1PROV_UNKNOWN; c.alignment = 1; c.extent = 0; c.value_offset = 0;
    c.offset_known = false; c.freed = false; c.writable = false;
    if (!is_null)
    {
        M1Provenance* p = g.prov(value);
        if (p == null || p.freed) { return false; }
        c.value_allocation = p.allocation; c.pointee = p.pointee; c.kind = p.kind; c.alignment = p.alignment;
        c.extent = p.extent; c.value_offset = p.offset; c.offset_known = p.offset_known; c.freed = p.freed; c.writable = p.writable;
    }
    return true;
}
fn bool M1Gen.cell_set(M1Gen* g, char* address, char* value, bool is_null)
{
    M1Provenance* p = g.prov(address);
    if (p == null || p.freed || !p.offset_known) { return false; }
    return g.cell_set_at(p.allocation, p.offset, value, is_null);
}
fn bool M1Gen.cell_restore(M1Gen* g, char* address, char* result)
{
    M1Provenance* ap = g.prov(address);
    if (ap == null || result == null) { return true; }
    int ix = g.cell_index(ap.allocation, ap.offset);
    if (ix < 0 || g.pointer_cells[ix].is_null) { return true; }
    M1PointerCell* c = &g.pointer_cells[ix];
    if (!g.prov_set(result, c.pointee, c.kind, c.alignment, c.extent, c.value_offset, c.offset_known, c.writable)) { return false; }
    M1Provenance* p = g.prov(result); p.allocation = c.value_allocation; p.freed = c.freed;
    return true;
}
fn bool M1Gen.note_failure(M1Gen* g, int line, int col, char* form)
{
    if (g.fail_form == null)
    {
        g.fail_line = line; g.fail_col = col; g.fail_form = form;
    }
    g.failed = true;
    return false;
}
fn bool M1Gen.check_access(M1Gen* g, char* address, AirTyp* ty, int line, int col, bool write_access)
{
    M1Provenance* p = g.prov(address);
    long size = g.type_size(ty, 0); int need_align = g.type_alignment(ty, 0);
    if (p == null || p.kind == M1PROV_UNKNOWN || p.freed || !p.offset_known || size < 0 || need_align == 0 ||
        !m1_value_type_compatible(p.pointee, ty, 0) || p.offset < 0 || p.offset + size > p.extent || p.alignment < need_align || (write_access && !p.writable))
    {
        return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
    }
    return true;
}
fn int M1Gen.global_alignment(M1Gen* g, AirDecl* d)
{
    int alignment = g.type_alignment(d.ret_ty, 0);
    for (usz i = 0; i < d.attr_count; i++)
    {
        if (same(d.attr_name[i], "align") && d.attr_has_int[i]) { alignment = (int)d.attr_int[i]; }
    }
    return alignment;
}
fn char* M1Gen.global_symbol(M1Gen* g, AirDecl* d)
{
    if (d == null || !m1_safe_name(m1_link_name(d))) { return null; }
    char[512] buf;
    int n = snprintf(&buf[0], 512, (char*)"@%s", m1_link_name(d));
    if (n < 0 || n >= 512) { return null; }
    return g.arena.dup(&buf[0], (usz)n);
}
fn char* M1Gen.global_pointer(M1Gen* g, AirDecl* d)
{
    char* symbol = g.global_symbol(d);
    long size = g.type_size(d.ret_ty, 0);
    int alignment = g.global_alignment(d);
    if (symbol == null || size < 0 || alignment <= 0) { g.failed = true; return null; }
    M1Provenance* existing = g.prov(symbol);
    if (existing == null && !g.prov_set(symbol, d.ret_ty, M1PROV_GLOBAL, alignment, size, 0, true, d.g_mut)) { g.failed = true; return null; }
    return symbol;
}
fn int M1Gen.string_index(M1Gen* g, char* data, usz len, bool terminate)
{
    if (len > 1048576) { g.failed = true; return -1; }
    for (int i = 0; i < g.string_count; i++)
    {
        M1String* s = &g.strings[i];
        if (s.len == len && s.terminate == terminate)
        {
            bool equal = true;
            for (usz j = 0; j < len; j++) { if (s.data[j] != data[j]) { equal = false; break; } }
            if (equal) { return i; }
        }
    }
    if (g.string_count >= 256) { g.failed = true; return -1; }
    int i = g.string_count++;
    M1String* s = &g.strings[i];
    s.data = data; s.len = len; s.terminate = terminate;
    char[64] name; int n = snprintf(&name[0], 64, (char*)".pear2.str.%d", i);
    if (n < 0 || n >= 64) { g.failed = true; return -1; }
    s.name = g.arena.dup(&name[0], (usz)n);
    char[96] symbol; int sn = snprintf(&symbol[0], 96, (char*)"@%s", s.name);
    if (sn < 0 || sn >= 96) { g.failed = true; return -1; }
    s.symbol = g.arena.dup(&symbol[0], (usz)sn);
    AirTyp* u8 = air_ir::air_mk_typ_simple(g.arena, ATYP_U8);
    long extent = (long)(len + (terminate ? (usz)1 : (usz)0));
    if (u8 == null || !g.prov_set(s.symbol, u8, M1PROV_STRING, 1, extent, 0, true, false)) { g.failed = true; return -1; }
    return i;
}
fn char* M1Gen.string_pointer(M1Gen* g, AirPrd* p)
{
    char* bytes = p.tag == APRD_STRING ? p.name : p.bytes;
    bool terminate = true;
    if (p.bytes_len > 0 && bytes == null) { g.failed = true; return null; }
    int index = g.string_index(bytes, p.bytes_len, terminate);
    if (index < 0) { return null; }
    M1String* s = &g.strings[index];
    int total = (int)(s.len + (s.terminate ? (usz)1 : (usz)0));
    char* symbol = s.symbol;
    char* first = g.tmp();
    if (first == null) { return null; }
    fprintf(g.out, "  %s = getelementptr inbounds [%d x i8], ptr %s, i64 0, i64 0\n", first, total, symbol);
    AirTyp* u8 = air_ir::air_mk_typ_simple(g.arena, ATYP_U8);
    if (!g.prov_set(first, u8, M1PROV_STRING, 1, total, 0, true, false)) { g.failed = true; return null; }
    g.prov(first).allocation = symbol;
    return first;
}





















fn int M1Gen.env_index(M1Gen* g, char* name)
{
    long i = (long)g.env_count - 1;
    while (i >= 0)
    {
        if (same(g.env_names[(usz)i], name)) { return (int)i; }
        i--;
    }
    return -1;
}
fn char* M1Gen.lookup_slot(M1Gen* g, char* name)
{
    int i = g.env_index(name);
    return i < 0 ? null : g.env_slots[(usz)i];
}
fn char* M1Gen.lookup(M1Gen* g, char* name)
{
    int i = g.env_index(name);
    if (i < 0)
    {
        AirDecl* global = g.find_global(name);
        return global == null ? null : g.global_pointer(global);
    }
    char* slot = g.env_slots[(usz)i];
    if (slot == null)
    {
        char* value = g.env_values[(usz)i];
        if (g.env_ptrs[(usz)i] && !g.prov_copy(name, value)) { g.failed = true; }
        return value;
    }
    char* value = g.tmp();
    char* ty = g.llvm_value_type_text(g.env_types[(usz)i]);
    if (value == null || ty == null) { g.failed = true; return null; }
    fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", value, ty, slot);
    if (g.env_ptrs[(usz)i] && !g.prov_copy(name, value)) { g.failed = true; }
    return value;
}
fn bool M1Gen.lookup_bool(M1Gen* g, char* name)
{
    long i = (long)g.env_count - 1;
    while (i >= 0)
    {
        if (same(g.env_names[(usz)i], name)) { return g.env_bools[(usz)i]; }
        i--;
    }
    return false;
}
fn bool M1Gen.lookup_ptr(M1Gen* g, char* name)
{
    long i = (long)g.env_count - 1;
    while (i >= 0)
    {
        if (same(g.env_names[(usz)i], name)) { return g.env_ptrs[(usz)i]; }
        i--;
    }
    return g.find_global(name) != null;
}
fn AirTyp* M1Gen.lookup_type(M1Gen* g, char* name)
{
    long i = (long)g.env_count - 1;
    while (i >= 0)
    {
        if (same(g.env_names[(usz)i], name)) { return g.env_types[(usz)i]; }
        i--;
    }
    AirDecl* global = g.find_global(name);    if (global != null) { return air_ir::air_mk_typ_ptr(g.arena, global.ret_ty); }
    AirDecl* function = g.find_function(name);
    return function == null ? null : g.function_type(function);
}
fn AirTyp* M1Gen.expr_type(M1Gen* g, AirPrd* p)
{
    if (p == null) { return null; }
    if (p.tag == APRD_UNIT) { return p.ty != null ? p.ty : air_ir::air_mk_typ_simple(g.arena, ATYP_UNIT); }
    if (p.tag == APRD_ALLOCA) { return p.ty != null ? p.ty : air_ir::air_mk_typ_ptr(g.arena, p.ty_arg); }
    if (p.tag == APRD_SIZEOF || p.tag == APRD_ALIGNOF) { return g.int_repr(g.default_bits, g.default_unsigned); }
    if (p.ty != null && p.ty.tag != ATYP_INFER) { return p.ty; }
    if (p.tag == APRD_VAR) { return g.lookup_type(p.name); }
    if (p.tag == APRD_LAMBDA) { return g.lambda_closure_type(p); }
    if (p.tag == APRD_CON)
    {
        AirDecl* owner = g.find_constructor_owner(p.name);
        if (owner != null && m1_tagged_sum_decl(owner))
        {
            AirTyp* type = air_ir::air_mk_typ(g.arena, ATYP_NOMINAL);
            if (type != null) { type.name = owner.name; }
            return type;
        }
    }
    if (p.tag == APRD_UNOP && p.sub_count == 1) { return g.expr_type(p.subs[0]); }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE || p.bop == ABIN_LAND || p.bop == ABIN_LOR) { return p.ty; }
        AirTyp* left = g.expr_type(p.subs[0]);
        AirTyp* right = g.expr_type(p.subs[1]);
        return left != null ? left : right;
    }
    if (p.tag == APRD_RECORD)
    {
        AirDecl* rd = m1_record_producer_decl(p, g.decls, g.decl_count, null);
        if (rd != null && (rd.tag != ADECL_CODATA || m1_record_codata_decl(rd)))
        {
            AirTyp* type = air_ir::air_mk_typ(g.arena, ATYP_NOMINAL);
            if (type != null) { type.name = rd.name; }
            return type;
        }
    }
    return p.ty != null && p.ty.tag == ATYP_INFER ? null : p.ty;
}
fn bool M1Gen.integer_value_compatible(M1Gen* g, AirPrd* p, AirTyp* expected)
{
    if (p == null || !m1_integer_type(expected)) { return false; }
    AirTyp* actual = g.expr_type(p);
    if (!m1_integer_compatible(expected, actual)) { return false; }
    if (!m1_known_type(actual) && p.tag != APRD_INT && g.default_bits != m1_int_bits(expected)) { return false; }
    return m1_contextual_int_fits(p, expected);
}
fn bool M1Gen.bind_rep(M1Gen* g, char* name, char* value, bool is_bool, bool is_ptr, AirTyp* ty)
{
    if (name == null || value == null || (is_bool && is_ptr) || g.env_count >= 256) { return false; }
    int previous = g.env_index(name);
    g.env_names[g.env_count] = name;
    g.env_values[g.env_count] = value;
    g.env_slots[g.env_count] = null;
    g.env_bools[g.env_count] = is_bool;
    g.env_ptrs[g.env_count] = is_ptr;
    g.env_types[g.env_count] = ty;
    // Rebinding inherits the loop-carried marking of the shadowed entry so
    // mutations of a name captured by a label stay phi-carried across scopes.
    g.env_carried[g.env_count] = previous >= 0 ? g.env_carried[(usz)previous] : false;
    g.env_count++;
    g.note_carried_bind(name, value);
    if (is_ptr && !g.prov_copy(value, name)) { g.failed = true; return false; }
    return true;
}
// Prints a basic-block header and records it as the block that subsequent
// branches terminate. Every control-flow edge bookkeeping goes through this
// name so phi incoming pairs always reference the real predecessor.
fn void M1Gen.begin_block(M1Gen* g, char* block_name)
{
    fprintf(g.out, "%s:\n", block_name);
    g.cur_block = block_name;
}
fn bool M1Gen.bind_typed(M1Gen* g, char* name, char* value, bool is_bool, bool is_ptr, AirTyp* ty)
{
    char* slot = g.lookup_slot(name);
    if (slot != null)
    {
        AirTyp* previous_type = g.lookup_type(name);
        if (previous_type == null || !m1_value_type_compatible(previous_type, ty, 0)) { return false; }
        char* llvm_ty = g.llvm_value_type_text(ty);
        if (llvm_ty == null) { return false; }
        fprintf(g.out, "  store %s %s, ptr %s, align 1\n", llvm_ty, value, slot);
        if (!g.bind_rep(name, value, is_bool, is_ptr, ty)) { return false; }
        g.env_slots[g.env_count - 1] = slot;
        return true;
    }
    return g.bind_rep(name, value, is_bool, is_ptr, ty);
}
fn AirTyp* M1Gen.int_repr(M1Gen* g, int bits, bool uns)
{
    AirTypTag tag = ATYP_INVALID;
    if (bits == 8) { tag = uns ? ATYP_U8 : ATYP_I8; }
    else if (bits == 16) { tag = uns ? ATYP_U16 : ATYP_I16; }
    else if (bits == 32) { tag = uns ? ATYP_U32 : ATYP_I32; }
    else if (bits == 64) { tag = uns ? ATYP_U64 : ATYP_I64; }
    else if (bits == 128) { tag = uns ? ATYP_U128 : ATYP_I128; }
    if (tag == ATYP_INVALID) { g.failed = true; return null; }
    return air_ir::air_mk_typ_simple(g.arena, tag);
}
fn AirTyp* M1Gen.decl_value_type(M1Gen* g, AirTyp* t, AirTyp* ret_type)
{
    if (t != null && t.tag != ATYP_INFER) { return t; }
    if (ret_type != null && ret_type.tag != ATYP_INFER && m1_integer_type(ret_type)) { return ret_type; }
    return g.int_repr(64, false);
}
fn AirTyp* M1Gen.int_rep_type(M1Gen* g, AirTyp* t)
{
    if (m1_known_type(t) && m1_integer_type(t)) { return t; }
    if (t == null || t.tag == ATYP_INFER || m1_integer_type(t)) { return g.int_repr(g.default_bits, g.default_unsigned); }
    return t;
}
fn bool m1_cns_returns_to(AirCns* k, char* ret_name, int depth)
{
    if (k == null || depth >= 16) { return false; }
    if (k.tag == ACNS_COVAR) { return same(k.name, ret_name); }
    if (k.tag == ACNS_ASCRIBE) { return m1_cns_returns_to(k.tail, ret_name, depth + 1); }
    return false;
}
// Call/stack tails forward their result to their final consumer, so a cut like
// `<f | call · x · %ret>` returns the *callee's* result type.
fn bool m1_cns_tail_returns_to(AirCns* k, char* ret_name, int depth)
{
    if (k == null || depth >= 24) { return false; }
    if (k.tag == ACNS_COVAR) { return same(k.name, ret_name); }
    return m1_cns_tail_returns_to(k.tail, ret_name, depth + 1);
}
fn bool m1_same_inferred_type(AirTyp* left, AirTyp* right)
{
    return left != null && right != null && m1_value_type_compatible(left, right, 0) && m1_value_type_compatible(right, left, 0);
}
// What value actually reaches `%ret` through a projection tail: a cut
// `<v | field x #i · ... · %ret>` returns the projected FIELD's type, not
// v's. Walk record/tuple projection and ascription continuations; anything
// else (stacks, calls, comu binds) is not a return-forwarding chain here.
fn AirTyp* M1Gen.infer_cut_projected_type(M1Gen* g, AirDecl* d, AirPrd* p, AirCns* k, char* ret_name, int depth)
{
    if (p == null || k == null || depth >= 24) { return null; }
    AirTyp* t = g.infer_prd_type(d, p, 0);
    while (k != null)
    {
        if (k.tag == ACNS_COVAR) { return same(k.name, ret_name) && t != null && t.tag != ATYP_INFER ? t : null; }
        if (k.tag == ACNS_ASCRIBE)
        {
            if (k.ty == null) { return null; }
            t = k.ty;
            k = k.tail;
            continue;
        }
        if (k.tag == ACNS_FIELD)
        {
            if (k.name == null || k.idx < 0) { return null; }
            AirDecl* rd = t != null && t.tag == ATYP_NOMINAL ? m1_find_record_decl(g.decls, g.decl_count, t.name) : null;
            if (rd == null)
            {
                // Erased (`infer`) owner annotation: unique (name, index)
                // declaration match, same discipline as consume().
                for (usz i = 0; i < g.decl_count; i++)
                {
                    AirDecl* cand = g.decls[i];
                    if (cand == null || (cand.tag != ADECL_DATA && cand.tag != ADECL_CODATA)) { continue; }
                    if (cand.tag == ADECL_CODATA ? !m1_record_codata_decl(cand) : (cand.ctor_count != 1 || cand.ctors[0] == null)) { continue; }
                    if ((usz)k.idx < m1_record_field_count(cand) && m1_record_field_name(cand, (usz)k.idx) != null && same(m1_record_field_name(cand, (usz)k.idx), k.name))
                    {
                        if (rd != null && !same(rd.name, cand.name)) { return null; }
                        rd = cand;
                    }
                }
                if (rd == null) { return null; }
            }
            if (m1_nullary_enum_decl(rd) || m1_tagged_sum_decl(rd)) { return null; }
            t = m1_record_field_ty(rd, (usz)k.idx);
            if (t == null) { return null; }
            k = k.tail;
            continue;
        }
        if (k.tag == ACNS_PROJ || k.tag == ACNS_FST || k.tag == ACNS_SND)
        {
            long ix = k.tag == ACNS_PROJ ? k.idx : (k.tag == ACNS_FST ? 0 : 1);
            if (t == null || t.tag != ATYP_TUPLE || ix < 0 || (usz)ix >= t.arg_count) { return null; }
            t = t.args[(usz)ix];
            k = k.tail;
            continue;
        }
        if (k.tag == ACNS_COMU)
        {
            // Projection results bound by a continuation: the inferred return
            // comes from the continuation body. Binder-typed producers inside
            // the body simply fall back to the function default when the
            // bound name is not visible to infer_prd_type.
            AirTyp* through_body = g.infer_cmd_return_type(d, k.body, ret_name, depth + 1);
            return through_body;
        }
        return null;
    }
    return null;
}
fn AirTyp* M1Gen.infer_prd_type(M1Gen* g, AirDecl* d, AirPrd* p, int depth)
{
    if (p == null || depth >= 16) { return null; }
    if (p.ty != null && p.ty.tag != ATYP_INFER) { return p.ty; }
    if (p.tag == APRD_BOOL) { return air_ir::air_mk_typ_simple(g.arena, ATYP_BOOL); }
    if (p.tag == APRD_CHAR) { return air_ir::air_mk_typ_simple(g.arena, ATYP_CHAR); }
    if (p.tag == APRD_FLOAT) { return air_ir::air_mk_typ_simple(g.arena, ATYP_F64); }
    if (p.tag == APRD_UNIT) { return air_ir::air_mk_typ_simple(g.arena, ATYP_UNIT); }
    if (p.tag == APRD_INT) { return g.int_repr(g.default_bits, g.default_unsigned); }
    if (p.tag == APRD_VAR)
    {
        for (usz i = 0; i < d.param_count; i++)
        {
            if (d.params[i] != null && same(d.params[i].name, p.name)) { return g.decl_value_type(d.params[i].ty, d.ret_ty); }
        }
        return null;
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE || p.bop == ABIN_LAND || p.bop == ABIN_LOR)
        {
            return air_ir::air_mk_typ_simple(g.arena, ATYP_BOOL);
        }
        AirTyp* left = g.infer_prd_type(d, p.subs[0], depth + 1);
        AirTyp* right = g.infer_prd_type(d, p.subs[1], depth + 1);
        if (left != null && right != null) { return m1_same_inferred_type(left, right) ? left : null; }
        if (left != null) { return left; }
        if (right != null) { return right; }
        return g.int_repr(g.default_bits, g.default_unsigned);
    }
    if (p.tag == APRD_UNOP && p.sub_count == 1)
    {
        if (p.uop == AUN_NOT) { return air_ir::air_mk_typ_simple(g.arena, ATYP_BOOL); }
        return g.infer_prd_type(d, p.subs[0], depth + 1);
    }
    if (p.tag == APRD_RECORD)
    {
        AirDecl* rd = m1_record_producer_decl(p, g.decls, g.decl_count, null);
        if (rd == null || (rd.tag == ADECL_CODATA && !m1_record_codata_decl(rd))) { return null; }
        AirTyp* t = air_ir::air_mk_typ_simple(g.arena, ATYP_NOMINAL);
        if (t != null) { t.name = rd.name; }
        return t;
    }
    return null;
}
fn AirTyp* M1Gen.infer_cmd_return_type(M1Gen* g, AirDecl* d, AirCmd* c, char* ret_name, int depth)
{
    if (c == null || depth >= 24) { return null; }
    if (c.tag == ACMD_CUT)
    {
        AirTyp* projected = g.infer_cut_projected_type(d, c.prd, c.cns, ret_name, 0);
        if (projected != null) { return projected; }
        if (m1_cns_returns_to(c.cns, ret_name, 0)) { return g.infer_prd_type(d, c.prd, 0); }
    }
    if (c.tag == ACMD_CUT && c.cns != null && c.cns.tag == ACNS_CALL && m1_cns_tail_returns_to(c.cns.tail, ret_name, 0))
    {
        AirTyp* callee_ty = g.infer_prd_type(d, c.prd, 0);
        if (m1_function_pointer_type(callee_ty)) { return callee_ty.args[1]; }
        if (m1_closure_type(callee_ty)) { return callee_ty.args[0].args[1]; }
        return null;
    }
    if (c.tag == ACMD_RET) { return g.infer_prd_type(d, c.prd, 0); }
    if (c.tag == ACMD_BLOCK || c.tag == ACMD_UNSAFE || c.tag == ACMD_MU || c.tag == ACMD_MUTILDE) { return g.infer_cmd_return_type(d, c.body, ret_name, depth + 1); }
    if (c.tag == ACMD_SEQ)
    {
        AirTyp* next_type = g.infer_cmd_return_type(d, c.next, ret_name, depth + 1);
        return next_type != null ? next_type : g.infer_cmd_return_type(d, c.body, ret_name, depth + 1);
    }
    if (c.tag == ACMD_IF)
    {
        AirTyp* then_type = g.infer_cmd_return_type(d, c.then_c, ret_name, depth + 1);
        AirTyp* else_type = g.infer_cmd_return_type(d, c.else_c, ret_name, depth + 1);
        return m1_same_inferred_type(then_type, else_type) ? then_type : null;
    }
    if (c.tag == ACMD_MATCH)
    {
        AirTyp* result = null;
        for (usz i = 0; i < c.branch_count; i++)
        {
            if (c.branches[i] == null) { return null; }
            AirTyp* branch_type = g.infer_cmd_return_type(d, c.branches[i].body, ret_name, depth + 1);
            if (branch_type == null || (result != null && !m1_same_inferred_type(result, branch_type))) { return null; }
            result = branch_type;
        }
        return result;
    }
    if ((c.tag == ACMD_ATOMIC || c.tag == ACMD_SYSCALL || c.tag == ACMD_ASM) && c.cns != null && c.cns.tag == ACNS_COMU)
    {
        return g.infer_cmd_return_type(d, c.cns.body, ret_name, depth + 1);
    }
    return null;
}
fn AirTyp* M1Gen.infer_decl_return_type(M1Gen* g, AirDecl* d)
{
    int saved_bits = g.default_bits;
    bool saved_unsigned = g.default_unsigned;
    if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && m1_integer_type(d.ret_ty))
    {
        g.default_bits = m1_int_bits(d.ret_ty);
        g.default_unsigned = m1_unsigned(d.ret_ty);
    }
    else { g.default_bits = 64; g.default_unsigned = false; }
    AirCmd* body = d.def_body;
    char* ret_name = null;
    if (body != null && body.tag == ACMD_MUTILDE) { ret_name = body.binder; body = body.body; }
    while (body != null && body.tag == ACMD_BLOCK) { body = body.body; }
    AirTyp* result = ret_name == null ? null : g.infer_cmd_return_type(d, body, ret_name, 0);
    g.default_bits = saved_bits;
    g.default_unsigned = saved_unsigned;
    return result;
}
fn AirTyp* M1Gen.decl_return_type(M1Gen* g, AirDecl* d)
{
    if (d != null && d.ret_ty != null && d.ret_ty.tag != ATYP_INFER) { return d.ret_ty; }
    AirTyp* inferred = g.infer_decl_return_type(d);
    if (inferred != null && m1_return_type(inferred)) { return inferred; }
    return g.int_repr(64, false);
}
fn AirTyp* M1Gen.function_type(M1Gen* g, AirDecl* d)
{
    if (d == null || !m1_function_signature(d) || d.param_count > 64) { return null; }
    AirTyp* domain = air_ir::air_mk_typ(g.arena, ATYP_TUPLE);
    AirTyp* result = g.decl_return_type(d);
    AirTyp* fn_type = air_ir::air_mk_typ(g.arena, ATYP_ARROW);
    if (domain == null || result == null || fn_type == null || !m1_backend_type(result, g.decls, g.decl_count, 0)) { return null; }
    if (d.is_extern && !m1_scalar_type(result) && !m1_unit_type(result) && !m1_c_abi_field_type(result, g.decls, g.decl_count, 0)) { return null; }
    for (usz i = 0; i < d.param_count; i++)
    {
        if (d.params[i] == null) { return null; }
        AirTyp* parameter = g.decl_value_type(d.params[i].ty, result);
        if (parameter == null || !m1_value_type(parameter, 0) || !m1_backend_type(parameter, g.decls, g.decl_count, 0)) { return null; }
        if (d.is_extern && !m1_scalar_type(parameter) && !m1_c_abi_field_type(parameter, g.decls, g.decl_count, 0)) { return null; }
        domain.add_arg(parameter);
    }
    fn_type.add_arg(domain); fn_type.add_arg(result);
    return fn_type;
}
fn char* M1Gen.convert_integer_width(M1Gen* g, char* value, AirTyp* from_type, AirTyp* to_type)
{
    if (value == null || !m1_integer_type(from_type) || !m1_integer_type(to_type)) { g.failed = true; return null; }
    int from_bits = m1_int_bits(from_type);
    int to_bits = m1_int_bits(to_type);
    if (from_bits <= 0 || to_bits <= 0) { g.failed = true; return null; }
    if (from_bits == to_bits) { return value; }
    char* dst = g.tmp();
    char* op = from_bits > to_bits ? (char*)"trunc" : (m1_unsigned(from_type) ? (char*)"zext" : (char*)"sext");
    if (dst == null) { return null; }
    fprintf(g.out, "  %s = %s %s %s to %s\n", dst, op, m1_llvm_int(from_type), value, m1_llvm_int(to_type));
    return dst;
}
fn int M1Gen.label_index(M1Gen* g, char* name)
{
    char* normalized = name != null && name[0] == '%' ? name + 1 : name;
    for (usz i = 0; i < g.label_count; i++) { if (same(g.labels[i].name, normalized)) { return (int)i; } }
    return -1;
}
fn bool M1Gen.label_environment_unchanged(M1Gen* g, M1Label* target)
{
    // M9: captured bindings arrive at the label block through phi incoming
    // edges, so a jump no longer needs the captured values to be identical to
    // the capture-time ones; only the environment *shape* must match: every
    // captured name is still resolvable with the same kind and value type.
    if (target == null || !target.captured) { return false; }
    for (usz j = 0; j < target.env_count; j++)
    {
        bool is_param = false;
        for (usz p = 0; p < target.param_count; p++)
        {
            if (target.params[p] != null && same(target.params[p].name, target.env_names[j])) { is_param = true; break; }
        }
        if (is_param) { continue; }
        int current = g.env_index(target.env_names[j]);
        if (current < 0) { return false; }
        if (g.env_bools[(usz)current] != target.env_bools[j] || g.env_ptrs[(usz)current] != target.env_ptrs[j]) { return false; }
        if (!target.env_bools[j] && !target.env_ptrs[j] && !m1_value_type_compatible(target.env_types[j], g.env_types[(usz)current], 0)) { return false; }
    }
    return true;
}
// Records one control-flow edge into a label: the terminating predecessor
// block plus, per captured environment entry and per label parameter, the SSA
// value that edge carries. `arg_values` may be null when param_count == 0.
fn bool M1Gen.label_record_edge(M1Gen* g, M1Label* target, char** arg_values)
{
    if (target == null || !target.captured || g.cur_block == null) { return false; }
    if (target.edges == null)
    {
        target.edge_stride = 1 + target.env_count + target.param_count;
        if (target.edge_stride > 128) { return false; }
        target.edges = (char**)malloc((usz)(16 * target.edge_stride * 8));
        if (target.edges == null) { return false; }
    }
    if (target.edge_count >= 16) { return false; }
    char** row = target.edges + target.edge_count * target.edge_stride;
    row[0] = g.cur_block;
    for (usz j = 0; j < target.env_count; j++)
    {
        bool is_param = false;
        for (usz p = 0; p < target.param_count; p++)
        {
            if (target.params[p] != null && same(target.params[p].name, target.env_names[j])) { is_param = true; break; }
        }
        // Parameter-named captured entries are rebound at the label block by
        // the parameter phi itself; record null as a sentinel (never used).
        if (is_param) { row[1 + j] = null; continue; }
        int current = g.env_index(target.env_names[j]);
        if (current < 0) { return false; }
        row[1 + j] = g.env_values[(usz)current];
    }
    for (usz p = 0; p < target.param_count; p++)
    {
        row[1 + target.env_count + p] = arg_values != null ? arg_values[p] : null;
    }
    target.edge_count++;
    target.has_jump = true;
    return true;
}
fn void M1Gen.label_drop_edges(M1Gen* g, M1Label* target)
{
    if (target != null && target.edges != null) { free(target.edges); target.edges = null; }
    if (target != null) { target.edge_count = 0; target.edge_stride = 0; }
}
fn AirDecl* M1Gen.find_function(M1Gen* g, char* name)
{
    // A body takes precedence over a declaration with the same source name.
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d != null && d.tag == ADECL_DEF && same(d.name, name)) { return d; }
    }
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d != null && d.tag == ADECL_DECLARE && same(d.name, name)) { return d; }
    }
    return null;
}

fn AirDecl* M1Gen.find_data(M1Gen* g, char* name)
{
    return m1_find_data_decl(g.decls, g.decl_count, name);
}fn AirDecl* M1Gen.find_constructor_owner(M1Gen* g, char* name)
{
    if (name == null) { return null; }
    AirDecl* found = null;
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d == null || d.tag != ADECL_DATA) { continue; }
        for (usz j = 0; j < d.ctor_count; j++)
        {
            if (d.ctors[j] != null && same(d.ctors[j].name, name))
            {
                if (found != null) { return null; }
                found = d;
            }
        }
    }
    return found;
}
fn int M1Gen.enum_constructor_index(M1Gen* g, AirDecl* d, char* name)
{
    if (!m1_tagged_sum_decl(d) || name == null) { return -1; }
    for (usz i = 0; i < d.ctor_count; i++) { if (same(d.ctors[i].name, name)) { return (int)i; } }
    return -1;
}
fn bool M1Gen.collect_cns(M1Gen* g, AirCns* k)
{
    if (k == null) { return true; }
    if (k.tag == ACNS_COMU && !g.collect_cmd(k.body)) { return false; }
    for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null && !g.collect_cmd(k.branches[i].body)) { return false; } }
    for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null && !g.collect_cmd(k.cobranches[i].body)) { return false; } }
    return g.collect_cns(k.tail);
}
fn bool M1Gen.collect_cmd(M1Gen* g, AirCmd* c)
{
    if (c == null) { return true; }
    if (c.tag == ACMD_FOR) { g.has_for = true; }
    if (c.tag == ACMD_LABEL)
    {
        char* normalized_label = c.binder != null && c.binder[0] == '%' ? c.binder + 1 : c.binder;
        if (!m1_safe_name(normalized_label) || same(normalized_label, "entry") || c.mbinder_count > 16 || g.label_count >= 32 || g.label_index(c.binder) >= 0) {
 return false; }
        M1Label* info = &g.labels[g.label_count];
        info.cmd = c; info.name = normalized_label; info.param_count = c.mbinder_count;
        info.env_count = 0; info.captured = false;
        info.edges = null; info.edge_count = 0; info.edge_stride = 0;
        for (usz i = 0; i < c.mbinder_count; i++)
        {
            AirBinder* p = c.mbinders[i];
            if (p == null || !m1_value_type(p.ty, 0)) {
 return false; }
            info.params[i] = p;
            info.slots[i] = null;
            info.param_bools[i] = m1_bool_type(p.ty);
            info.param_ptrs[i] = m1_pointer_repr_type(p.ty);
        }
        g.label_count++;
    }
    if (!g.collect_cns(c.cns)) {
 return false; }
    if (!g.collect_cmd(c.body) || !g.collect_cmd(c.next) || !g.collect_cmd(c.then_c) || !g.collect_cmd(c.else_c) || !g.collect_cmd(c.handled)) {
 return false; }
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null && !g.collect_cmd(c.branches[i].body)) {
 return false; } }
    return true;
}
fn char* M1Gen.tmp(M1Gen* g)
{
    char[32] b;
    int n = snprintf(&b[0], 32, (char*)"%%t%d", g.next_tmp);
    g.next_tmp++;
    if (n < 0 || n >= 32) { g.failed = true; return null; }
    return g.arena.dup(&b[0], (usz)n);
}
fn char* M1Gen.label(M1Gen* g, char* prefix)
{
    for (int tries = 0; tries < 256; tries++)
    {
        char[64] b;
        int n = snprintf(&b[0], 64, (char*)"pear2.%s%d", prefix, g.next_label);
        g.next_label++;
        if (n < 0 || n >= 64) { g.failed = true; return null; }
        char* name = g.arena.dup(&b[0], (usz)n);
        if (g.label_index(name) < 0) { return name; }
    }
    g.failed = true;
    return null;
}
fn char* M1Gen.int_text(M1Gen* g, long value)
{
    char[32] b;
    int n = snprintf(&b[0], 32, (char*)"%ld", value);
    if (n < 0 || n >= 32) { g.failed = true; return null; }
    return g.arena.dup(&b[0], (usz)n);
}
fn char* M1Gen.llvm_type_text(M1Gen* g, AirTyp* t)
{
    char[2048] text;
    usz used = 0;
    if (!m1_value_type(t, 0) || !m1_llvm_type_append(&text[0], 2048, &used, t, 0)) { g.failed = true; return null; }
    text[used] = 0;
    return g.arena.dup(&text[0], used);
}
fn char* M1Gen.llvm_value_type_text(M1Gen* g, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY || t.tag == ATYP_NOMINAL)) { return g.llvm_type_text(t); }
    return m1_llvm_scalar(t);
}
// Internal PEAR2 functions use LLVM's default ccc convention consistently at
// both definitions and direct calls. Tuples/arrays are passed and returned as
// first-class LLVM aggregates; unit returns are void, while unit values retain
// the empty-struct representation in parameters and aggregate fields.
fn char* M1Gen.llvm_abi_return_text(M1Gen* g, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY || t.tag == ATYP_NOMINAL)) { return g.llvm_type_text(t); }
    return m1_llvm_abi_ret(t);
}
fn char* M1Gen.llvm_abi_argument_text(M1Gen* g, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_UNIT || t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY || t.tag == ATYP_NOMINAL)) { return g.llvm_type_text(t); }
    return m1_llvm_abi_arg(t);
}
fn char* M1Gen.index_as_i64(M1Gen* g, AirPrd* index, AirTyp* index_type)
{
    AirTyp* index_rep = g.int_rep_type(index_type);
    if (index == null || index_rep == null || !g.integer_value_compatible(index, index_rep)) { g.failed = true; return null; }
    char* value = g.prd(index);
    int bits = m1_int_bits(index_rep);
    if (g.failed || value == null || bits == 0) { g.failed = true; return null; }
    if (bits == 64) { return value; }
    char* converted = g.tmp();
    if (converted == null) { return null; }
    if (bits < 64)
    {
        char* extension = m1_unsigned(index_rep) ? (char*)"zext" : (char*)"sext";
        fprintf(g.out, "  %s = %s %s %s to i64\n", converted, extension, m1_llvm_int(index_rep), value);
    }
    else
    {
        fprintf(g.out, "  %s = trunc %s %s to i64\n", converted, m1_llvm_int(index_rep), value);
    }
    return converted;
}
fn char* M1Gen.float_text(M1Gen* g, double value)
{
    ulong* bits_ptr = (ulong*)&value;
    ulong bits = *bits_ptr;
    char[19] text;
    char* digits = (char*)"0123456789ABCDEF";
    text[0] = '0'; text[1] = 'x';
    for (int i = 0; i < 16; i++) { text[2 + i] = digits[(bits >> ((15 - i) * 4)) & 15]; }
    text[18] = 0;
    return g.arena.dup(&text[0], 18);
}

fn int m1_gcd(int a, int b)
{
    if (a < 0) { a = -a; }
    if (b < 0) { b = -b; }
    while (b != 0) { int r = a % b; a = b; b = r; }
    return a <= 0 ? 1 : a;
}

fn char* M1Gen.alloca_prd(M1Gen* g, AirPrd* p)
{
    AirTyp* t = p.ty_arg;
    long size = g.type_size(t, 0); int alignment = g.type_alignment(t, 0);
    if (!m1_backend_type(t, g.decls, g.decl_count, 0) || size <= 0 || size > 1048576 || alignment <= 0)
    {
        g.note_failure(p.source_line, p.source_col, (char*)"unsupported alloca type/size"); return null;
    }
    char* ir = g.llvm_type_text(t); char* address = g.tmp();
    if (g.failed || ir == null || address == null) { return null; }
    fprintf(g.out, "  %s = alloca %s, align %d\n", address, ir, alignment);
    if (!g.prov_set(address, t, M1PROV_STACK, alignment, size, 0, true, true)) { g.failed = true; return null; }
    return address;
}

fn char* M1Gen.load_prd(M1Gen* g, AirPrd* p)
{
    if (p.sub_count != 1 || p.subs[0] == null) { g.note_failure(p.source_line, p.source_col, (char*)"malformed typed load"); return null; }
    AirTyp* ptr_type = g.expr_type(p.subs[0]); AirTyp* t = m1_pointee_type(ptr_type);
    if (t == null || (p.ty != null && !m1_value_type_compatible(t, p.ty, 0)) || !m1_backend_type(t, g.decls, g.decl_count, 0))
    {
        g.note_failure(p.source_line, p.source_col, (char*)"load type does not match pointer pointee"); return null;
    }
    char* address = g.pointer_value(p.subs[0]);
    if (g.failed || address == null || !g.check_access(address, t, p.source_line, p.source_col, false)) { return null; }
    char* ir = g.llvm_type_text(t); char* dst = g.tmp(); int align = g.type_alignment(t, 0);
    if (g.failed || ir == null || dst == null || align <= 0) { return null; }
    fprintf(g.out, "  %s = load %s%s, ptr %s, align %d\n", dst, p.bval ? (char*)"volatile " : (char*)"", ir, address, align);
    if (m1_pointer_type(t) && !g.cell_restore(address, dst)) { g.failed = true; return null; }
    return dst;
}

fn char* M1Gen.gep_prd(M1Gen* g, AirPrd* p)
{
    if (p.sub_count < 2 || p.sub_count > 16 || p.subs[0] == null || p.ty_arg == null)
    {
        g.note_failure(p.source_line, p.source_col, (char*)"malformed typed GEP"); return null;
    }
    AirTyp* base_type = g.expr_type(p.subs[0]);
    AirTyp* source_type = m1_pointee_type(base_type);
    if (source_type == null || !m1_value_type_compatible(source_type, p.ty_arg, 0))
    {
        g.note_failure(p.source_line, p.source_col, (char*)"GEP source type does not match base pointer"); return null;
    }
    char* base = g.pointer_value(p.subs[0]);
    M1Provenance* base_prov = g.prov(base);
    if (base == null || base_prov == null || base_prov.freed || !base_prov.offset_known)
    {
        g.note_failure(p.source_line, p.source_col, (char*)"GEP requires known live pointer provenance"); return null;
    }
    long[16] indices;
    bool[16] is_field;
    AirTyp* current = source_type;
    long delta = 0;
    for (usz i = 1; i < p.sub_count; i++)
    {
        AirPrd* ix = p.subs[i];
        if (ix == null || ix.tag != APRD_INT || !m1_integer_type(g.expr_type(ix)))
        {
            g.note_failure(p.source_line, p.source_col, (char*)"dynamic pointer offsets are unsupported without a static provenance bound"); return null;
        }
        long value = ix.ival; indices[i] = value; is_field[i] = false;
        if (i == 1)
        {
            long size = g.type_size(current, 0);
            if (size < 0 || value > 1048576 || value < -1048576) { g.note_failure(p.source_line, p.source_col, (char*)"GEP offset exceeds supported bounds"); return null; }
            delta += value * size;
        }
        else if (current.tag == ATYP_ARRAY && current.arg_count == 1)
        {
            if (value < 0 || value >= current.ival) { g.note_failure(p.source_line, p.source_col, (char*)"array GEP index is out of bounds"); return null; }
            long size = g.type_size(current.args[0], 0);
            if (size < 0) { g.note_failure(p.source_line, p.source_col, (char*)"unsized array GEP"); return null; }
            delta += value * m1_align_up(size, g.type_alignment(current.args[0], 0));
            current = current.args[0];
        }
        else if (current.tag == ATYP_TUPLE || current.tag == ATYP_NOMINAL)
        {
            long field_count = current.tag == ATYP_TUPLE ? (long)current.arg_count : -1;
            if (current.tag == ATYP_NOMINAL)
            {
                AirDecl* d = m1_find_record_decl(g.decls, g.decl_count, current.name);
                if (d == null || (d.tag == ADECL_CODATA && !m1_record_codata_decl(d)) || (d.tag == ADECL_DATA && (d.ctor_count != 1 || d.ctors[0] == null))) { g.note_failure(p.source_line, p.source_col, (char*)"unsupported GEP record layout"); return null; }
                field_count = (long)m1_record_field_count(d);
            }
            if (value < 0 || value >= field_count) { g.note_failure(p.source_line, p.source_col, (char*)"record GEP field index is out of bounds"); return null; }
            long field_offset = g.field_offset(current, value);
            if (field_offset < 0) { g.note_failure(p.source_line, p.source_col, (char*)"unsupported GEP field layout"); return null; }
            delta += field_offset; is_field[i] = true;
            if (current.tag == ATYP_TUPLE) { current = current.args[(usz)value]; }
            else { current = m1_record_field_ty(m1_find_record_decl(g.decls, g.decl_count, current.name), (usz)value); }
        }
        else { g.note_failure(p.source_line, p.source_col, (char*)"GEP index steps into a scalar type"); return null; }
    }
    long new_offset = base_prov.offset + delta;
    if (new_offset < 0 || new_offset > base_prov.extent) { g.note_failure(p.source_line, p.source_col, (char*)"GEP escapes the known object bounds"); return null; }
    AirTyp* result_type = g.expr_type(p);
    if (m1_pointee_type(result_type) == null || !m1_value_type_compatible(m1_pointee_type(result_type), current, 0))
    {
        g.note_failure(p.source_line, p.source_col, (char*)"GEP result annotation does not match computed pointee"); return null;
    }
    char* source_ir = g.llvm_type_text(source_type); char* out = g.tmp();
    if (g.failed || source_ir == null || out == null) { return null; }
    fprintf(g.out, "  %s = getelementptr %s, ptr %s", out, source_ir, base);
    for (usz i = 1; i < p.sub_count; i++)
    {
        if (is_field[i]) { fprintf(g.out, ", i32 %ld", indices[i]); }
        else { fprintf(g.out, ", i64 %ld", indices[i]); }
    }
    fprintf(g.out, "\n");
    int align = m1_gcd(base_prov.alignment, (int)(new_offset == 0 ? base_prov.alignment : new_offset));
    char* allocation = base_prov.allocation; int kind = base_prov.kind;
    long extent = base_prov.extent; bool writable = base_prov.writable;
    if (!g.prov_set(out, current, kind, align, extent, new_offset, true, writable)) { g.failed = true; return null; }
    g.prov(out).allocation = allocation;
    return out;
}

// Scalar expression lowering. Untyped integer operations use the function
// return width (or i64 when no integer return type supplies a default);
// explicit signedness selects signed or unsigned arithmetic operations.
// ===== M8: first-class closures & environment capture =======================
// A `lam` producer lambda-lifts to a module-level function that takes a hidden
// leading environment pointer (`ptr %env`) followed by the declared binders.
// The closure value itself is a fat pointer rendered as the LLVM aggregate
// `{ ptr, ptr }` = { lifted code pointer, environment pointer } and typed in
// AIR as `tuple(arrow(tuple(ptr u8, params...) -> ret), ptr u8)`.
fn bool m1_closure_type(AirTyp* t)
{
    if (t == null || t.tag != ATYP_TUPLE || t.arg_count != 2 || t.args[0] == null || t.args[1] == null) { return false; }
    AirTyp* code = t.args[0]; AirTyp* env = t.args[1];
    if (env.tag != ATYP_PTR) { return false; }
    if (!m1_function_pointer_type(code) || code.args[0].arg_count < 1) { return false; }
    AirTyp* first = code.args[0].args[0];
    return first != null && first.tag == ATYP_PTR;
}
// Lambda bodies are restricted to a straight-line subset: cuts, sequences,
// blocks, lets, terminal ifs, bare returns, and no side-effecting consumers or
// control-flow constructs that would outlive the lexical scope.
fn bool m1_lambda_cns_ok(AirCns* k, int depth)
{
    if (k == null || depth >= 24) { return true; }
    switch (k.tag)
    {
        case ACNS_CASE: case ACNS_COCASE: case ACNS_DEFAULT: case ACNS_LABEL:
        case ACNS_SUBST: case ACNS_SHARE: case ACNS_ERASE: case ACNS_INVALID:
            return false;
        case ACNS_COMU:
            return m1_lambda_cmd_ok(k.body, depth + 1) && m1_lambda_cns_ok(k.tail, depth + 1);
        case ACNS_STACK: case ACNS_INDEX: case ACNS_STORE:
            if (k.prd != null && !m1_lambda_prd_ok(k.prd, depth + 1)) { return false; }
            return m1_lambda_cns_ok(k.tail, depth + 1);
        default:
            return m1_lambda_cns_ok(k.tail, depth + 1);
    }
}
fn bool m1_lambda_cmd_ok(AirCmd* c, int depth)
{
    if (c == null || depth >= 24) { return true; }
    switch (c.tag)
    {
        case ACMD_CUT:
            return m1_lambda_prd_ok(c.prd, depth + 1) && m1_lambda_cns_ok(c.cns, depth + 1);
        case ACMD_SEQ:
            return m1_lambda_cmd_ok(c.body, depth + 1) && m1_lambda_cmd_ok(c.next, depth + 1);
        case ACMD_BLOCK: case ACMD_UNCHECKED: case ACMD_UNSAFE:
            return m1_lambda_cmd_ok(c.body, depth + 1);
        case ACMD_LET:
            return m1_lambda_prd_ok(c.prd, depth + 1) && m1_lambda_cmd_ok(c.body, depth + 1);
        case ACMD_IF:
            return m1_lambda_prd_ok(c.prd, depth + 1) && m1_lambda_cmd_ok(c.then_c, depth + 1) && m1_lambda_cmd_ok(c.else_c, depth + 1);
        case ACMD_RET:
            return c.prd == null || m1_lambda_prd_ok(c.prd, depth + 1);
        case ACMD_NOP:
            return true;
        default:
            return false;
    }
}
fn bool m1_lambda_prd_ok(AirPrd* p, int depth)
{
    if (p == null || depth >= 24) { return true; }
    if (p.tag == APRD_COMETA || p.tag == APRD_EVAL || p.tag == APRD_QUOTE || p.tag == APRD_REIFY || p.tag == APRD_SPLICE) { return false; }
    if (p.tag == APRD_MU) { return m1_lambda_cmd_ok(p.body, depth + 1); }
    if (p.tag == APRD_LAMBDA) { return m1_lambda_cmd_ok(p.body, depth + 1); }
    for (usz i = 0; i < p.sub_count; i++) { if (!m1_lambda_prd_ok(p.subs[i], depth + 1)) { return false; } }
    for (usz i = 0; i < p.rec_init_count; i++) { if (p.rec_inits[i] != null && !m1_lambda_prd_ok(p.rec_inits[i].value, depth + 1)) { return false; } }
    return true;
}
// Lexical free-variable scan with a scoped bound-name stack: reads resolve
// against `bound` so lambda/let/comu shadowing excludes locally rebound names.
fn void m1_lam_bind(char*[] bound, int* count, char* name)
{
    if (name == null || same(name, "_")) { return; }
    if (*count >= 64) { *count = 999; return; }
    bound[(usz)(*count)] = name; (*count)++;
}
fn bool m1_lam_bound(char*[] bound, int count, char* name)
{
    for (int i = 0; i < count && i < 64; i++) { if (same(bound[(usz)i], name)) { return true; } }
    return false;
}
fn void m1_lam_read(char*[] bound, int bound_count, char*[] reads, int* count, char* name)
{
    if (name == null || m1_lam_bound(bound, bound_count, name)) { return; }
    if (*count >= 64) { *count = 999; return; }
    for (int i = 0; i < *count; i++) { if (same(reads[(usz)i], name)) { return; } }
    reads[(usz)(*count)] = name; (*count)++;
}
fn void m1_lam_scan_prd(AirPrd* p, char*[] bound, int* bound_count, char*[] reads, int* read_count, int depth)
{
    if (p == null || depth >= 24 || *read_count > 900 || *bound_count > 900) { return; }
    if (p.tag == APRD_VAR)
    {
        m1_lam_read(bound, *bound_count, reads, read_count, p.name);
        return;
    }
    if (p.tag == APRD_MU) { m1_lam_scan_cmd(p.body, bound, bound_count, reads, read_count, depth + 1); return; }
    if (p.tag == APRD_LAMBDA)
    {
        int saved = *bound_count;
        for (usz i = 0; i < p.binder_count; i++) { if (p.binders[i] != null) { m1_lam_bind(bound, bound_count, p.binders[i].name); } }
        m1_lam_scan_cmd(p.body, bound, bound_count, reads, read_count, depth + 1);
        *bound_count = saved;
        return;
    }
    for (usz i = 0; i < p.sub_count; i++) { m1_lam_scan_prd(p.subs[i], bound, bound_count, reads, read_count, depth + 1); }
    for (usz i = 0; i < p.rec_init_count; i++) { if (p.rec_inits[i] != null) { m1_lam_scan_prd(p.rec_inits[i].value, bound, bound_count, reads, read_count, depth + 1); } }
}
fn void m1_lam_scan_cns(AirCns* k, char*[] bound, int* bound_count, char*[] reads, int* read_count, int depth)
{
    if (k == null || depth >= 24 || *read_count > 900 || *bound_count > 900) { return; }
    if (k.prd != null) { m1_lam_scan_prd(k.prd, bound, bound_count, reads, read_count, depth + 1); }
    if (k.tag == ACNS_COMU)
    {
        int saved = *bound_count;
        m1_lam_bind(bound, bound_count, k.bind);
        m1_lam_scan_cmd(k.body, bound, bound_count, reads, read_count, depth + 1);
        *bound_count = saved;
    }
    m1_lam_scan_cns(k.tail, bound, bound_count, reads, read_count, depth + 1);
}
fn void m1_lam_scan_cmd(AirCmd* c, char*[] bound, int* bound_count, char*[] reads, int* read_count, int depth)
{
    if (c == null || depth >= 24 || *read_count > 900 || *bound_count > 900) { return; }
    switch (c.tag)
    {
        case ACMD_CUT:
            m1_lam_scan_prd(c.prd, bound, bound_count, reads, read_count, depth + 1);
            m1_lam_scan_cns(c.cns, bound, bound_count, reads, read_count, depth + 1);
            return;
        case ACMD_SEQ:
            m1_lam_scan_cmd(c.body, bound, bound_count, reads, read_count, depth + 1);
            m1_lam_scan_cmd(c.next, bound, bound_count, reads, read_count, depth + 1);
            return;
        case ACMD_BLOCK: case ACMD_UNCHECKED: case ACMD_UNSAFE:
            m1_lam_scan_cmd(c.body, bound, bound_count, reads, read_count, depth + 1);
            return;
        case ACMD_LET:
            m1_lam_scan_prd(c.prd, bound, bound_count, reads, read_count, depth + 1);
            {
                int saved = *bound_count;
                m1_lam_bind(bound, bound_count, c.binder);
                m1_lam_scan_cmd(c.body, bound, bound_count, reads, read_count, depth + 1);
                *bound_count = saved;
            }
            return;
        case ACMD_IF:
            m1_lam_scan_prd(c.prd, bound, bound_count, reads, read_count, depth + 1);
            m1_lam_scan_cmd(c.then_c, bound, bound_count, reads, read_count, depth + 1);
            m1_lam_scan_cmd(c.else_c, bound, bound_count, reads, read_count, depth + 1);
            return;
        case ACMD_RET:
            m1_lam_scan_prd(c.prd, bound, bound_count, reads, read_count, depth + 1);
            return;
        default:
            return;
    }
}
fn bool m1_lambda_capture_type_ok(AirTyp* t)
{
    return t != null && (m1_bool_type(t) || m1_pointer_repr_type(t) || m1_float_type(t) || m1_closure_type(t) ||
                         (m1_known_type(t) && m1_integer_type(t)) || t.tag == ATYP_CHAR);
}
// Scan + type a lambda against the live environment. With diagnose=false the
// scan is pure (no diagnostics) so expr_type can speculate.
fn bool M1Gen.lambda_scan(M1Gen* g, AirPrd* p, bool diagnose,
    char*[] cap_names, char*[] cap_values, AirTyp*[] cap_types, bool[] cap_bools, bool[] cap_ptrs, int* cap_count_out,
    AirTyp*[] param_types, usz* param_count_out, AirTyp** ret_out)
{
    if (p == null || p.tag != APRD_LAMBDA || p.body == null || p.binder_count == 0 || p.binder_count > 15) { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"malformed lambda producer"); } return false; }
    if (!m1_lambda_cmd_ok(p.body, 0))
    { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"lambda body uses a form outside the first-class closure subset (loops, labels, matches, effects)"); } return false; }
    char*[64] bound; int bound_count = 0;
    char*[64] reads; int read_count = 0;
    for (usz i = 0; i < p.binder_count; i++) { if (p.binders[i] != null) { m1_lam_bind(bound[..], &bound_count, p.binders[i].name); } }
    m1_lam_scan_cmd(p.body, bound[..], &bound_count, reads[..], &read_count, 0);
    if (read_count > 900 || bound_count > 900)
    { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"lambda environment scan overflowed its bookkeeping budget"); } return false; }
    int cap_count = 0;
    for (int r = 0; r < read_count; r++)
    {
        int ix = g.env_index(reads[(usz)r]);
        if (ix < 0) { continue; } // module-level names stay linked by symbol
        if (cap_count >= 16)
        { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"closure captures more bindings than supported (16)"); } return false; }
        if (g.watch_active)
        {
            for (int w = 0; w < g.watch_count; w++)
            {
                if (g.watch_names[w] != null && same(g.watch_names[w], reads[(usz)r]))
                { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"closure captures a loop-carried (phi-promoted) binding"); } return false; }
            }
        }
        if (g.env_carried[(usz)ix])
        { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"closure captures a label-captured (phi-promoted) binding"); } return false; }
        AirTyp* ct = g.env_types[(usz)ix];
        if (!m1_lambda_capture_type_ok(ct))
        { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"closure captures a binding with an unsupported type"); } return false; }
        cap_names[(usz)cap_count] = reads[(usz)r];
        cap_values[(usz)cap_count] = g.env_values[(usz)ix];
        cap_types[(usz)cap_count] = ct;
        cap_bools[(usz)cap_count] = g.env_bools[(usz)ix];
        cap_ptrs[(usz)cap_count] = g.env_ptrs[(usz)ix];
        cap_count++;
    }
    usz param_count = 0;
    for (usz i = 0; i < p.binder_count; i++)
    {
        AirBinder* b = p.binders[i];
        AirTyp* pt = g.decl_value_type(b != null ? b.ty : null, null);
        if (pt == null || !m1_lambda_capture_type_ok(pt))
        { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"unsupported lambda parameter type for closure lifting"); } return false; }
        param_types[param_count] = pt; param_count++;
    }
    // Return-type inference: treat binders and captures as synthetic params.
    AirDecl synth;
    synth.tag = ADECL_DEF; synth.ret_ty = null; synth.name = (char*)"pear2.lambda";
    synth.param_count = p.binder_count + (usz)cap_count;
    for (usz i = 0; i < p.binder_count; i++) { synth.params[i] = p.binders[i]; }
    for (int i = 0; i < cap_count; i++)
    {
        AirBinder* cb = air_ir::air_mk_binder(g.arena, cap_names[(usz)i], cap_types[(usz)i], AMULT_UNR);
        if (cb == null) { return false; }
        synth.params[p.binder_count + (usz)i] = cb;
    }
    AirTyp* ret = g.infer_cmd_return_type(&synth, p.body, (char*)"%ret", 0);
    if (ret == null)
    { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"cannot infer the lambda result type; ascribe the returned expression"); } return false; }
    ret = g.decl_value_type(ret, ret);
    if (!(m1_unit_type(ret) || m1_lambda_capture_type_ok(ret)))
    { if (diagnose) { g.note_failure(p.source_line, p.source_col, (char*)"unsupported lambda result type for closure lifting"); } return false; }
    *cap_count_out = cap_count;
    *param_count_out = param_count;
    *ret_out = ret;
    return true;
}
fn AirTyp* M1Gen.lambda_closure_type(M1Gen* g, AirPrd* p)
{
    char*[16] cn; char*[16] cv; AirTyp*[16] ct; bool[16] cb; bool[16] cp; int cc = 0;
    AirTyp*[16] pd; usz pc = 0; AirTyp* ret = null;
    if (!g.lambda_scan(p, false, cn[..], cv[..], ct[..], cb[..], cp[..], &cc, pd[..], &pc, &ret)) { return null; }
    AirTyp* u8 = air_ir::air_mk_typ_simple(g.arena, ATYP_U8);
    AirTyp* u8p = air_ir::air_mk_typ_ptr(g.arena, u8);
    AirTyp* argt = air_ir::air_mk_typ_simple(g.arena, ATYP_TUPLE);
    AirTyp* arrow = air_ir::air_mk_typ(g.arena, ATYP_ARROW);
    AirTyp* closure = air_ir::air_mk_typ_simple(g.arena, ATYP_TUPLE);
    if (u8 == null || u8p == null || argt == null || arrow == null || closure == null) { return null; }
    argt.args[0] = u8p; argt.arg_count = 1;
    for (usz i = 0; i < pc; i++) { argt.args[i + 1] = pd[i]; argt.arg_count++; }
    arrow.args[0] = argt; arrow.args[1] = ret; arrow.arg_count = 2;
    closure.args[0] = arrow; closure.args[1] = u8p; closure.arg_count = 2;
    return closure;
}
// Lift the lambda: render the body as a module-level function taking
// `ptr %env` plus its binders, buffer the definition for end-of-function
// flush, then materialize the { code, env } fat pointer in the current stream.
fn char* M1Gen.lambda_value(M1Gen* g, AirPrd* p)
{
    if (g.current_function == null)
    { g.note_failure(p.source_line, p.source_col, (char*)"lambda producers may only appear inside function bodies"); return null; }
    char*[16] cap_names; char*[16] cap_values; AirTyp*[16] cap_types; bool[16] cap_bools; bool[16] cap_ptrs; int cap_count = 0;
    AirTyp*[16] params; usz param_count = 0; AirTyp* ret = null;
    if (g.for_depth > 0 || g.watch_active)
    { g.note_failure(p.source_line, p.source_col, (char*)"closures cannot be created inside loop bodies yet"); return null; }
    if (!g.lambda_scan(p, true, cap_names[..], cap_values[..], cap_types[..], cap_bools[..], cap_ptrs[..], &cap_count, params[..], &param_count, &ret)) { return null; }
    AirTyp* closure_type = g.lambda_closure_type(p);
    if (closure_type == null) { g.failed = true; return null; }
    char* ret_ir = g.llvm_abi_return_text(ret);
    char* closure_ir = g.llvm_value_type_text(closure_type);
    if (ret_ir == null || closure_ir == null) { g.failed = true; return null; }
    if (g.lam_serial >= 1000000 || g.lam_count >= 24)
    { g.note_failure(p.source_line, p.source_col, (char*)"too many lifted closures in one function"); return null; }
    char[160] name_buf;
    int nn = snprintf(&name_buf[0], 160, (char*)"pear2.lam.%s.%d", g.current_function, g.lam_serial);
    g.lam_serial++;
    if (nn < 0 || nn >= 160) { g.failed = true; return null; }
    char* lam_name = g.arena.dup(&name_buf[0], (usz)nn);
    // Environment struct type from captured field types.
    char* env_ir = null;
    if (cap_count > 0)
    {
        AirTyp* env_struct = air_ir::air_mk_typ_simple(g.arena, ATYP_TUPLE);
        if (env_struct == null) { g.failed = true; return null; }
        for (int i = 0; i < cap_count; i++) { env_struct.args[(usz)i] = cap_types[(usz)i]; env_struct.arg_count++; }
        env_ir = g.llvm_value_type_text(env_struct);
        if (env_ir == null) { g.failed = true; return null; }
    }
    // Render the lifted body into a side buffer.
    char* body_buffer = null; usz body_size = 0;
    void* side = open_memstream(&body_buffer, &body_size);
    if (side == null) { g.failed = true; return null; }
    void* saved_out = g.out;
    char* saved_block = g.cur_block; bool saved_terminated = g.terminated;
    char* saved_current = g.current_function;
    AirTyp* saved_return_type = g.return_type; bool saved_return_bool = g.return_bool;
    bool saved_return_ptr = g.return_ptr; bool saved_return_unit = g.return_unit;
    int saved_bits = g.default_bits; bool saved_unsigned = g.default_unsigned;
    bool saved_watch = g.watch_active; int saved_watch_count = g.watch_count;
    int saved_watch_depth = g.watch_branch_depth; int saved_branch = g.branch_depth; int saved_seq = g.seq_depth;
    bool saved_guard = g.guard_active; char* saved_gn = g.guard_name; char* saved_gt = g.guard_true_label; char* saved_gf = g.guard_false_label;
    usz saved_env = g.env_count;
    g.out = side;
    g.current_function = lam_name;
    g.return_type = ret;
    g.return_bool = m1_bool_type(ret); g.return_ptr = m1_pointer_repr_type(ret); g.return_unit = m1_unit_type(ret);
    g.default_bits = m1_integer_type(ret) ? m1_int_bits(ret) : 64;
    g.default_unsigned = m1_unsigned(ret);
    g.watch_active = false; g.watch_count = 0; g.branch_depth = 0; g.seq_depth = 0;
    g.guard_active = false; g.guard_name = null; g.guard_true_label = null; g.guard_false_label = null;
    g.terminated = false;
    fprintf(side, "define internal %s @%s(ptr %%env", ret_ir, lam_name);
    for (usz i = 0; i < param_count; i++)
    {
        char* pt = g.llvm_value_type_text(params[i]);
        if (pt == null) { fclose(side); free(body_buffer); g.out = saved_out; g.failed = true; return null; }
        fprintf(side, ", %s %%a%d", pt, (int)i);
    }
    fprintf(side, ") {\n");
    g.begin_block((char*)"entry");
    for (int i = 0; i < cap_count; i++)
    {
        char* ft = g.llvm_value_type_text(cap_types[(usz)i]);
        char* gep = g.tmp(); char* ld = g.tmp();
        if (ft == null || gep == null || ld == null) { fclose(side); free(body_buffer); g.out = saved_out; g.failed = true; return null; }
        fprintf(side, "  %s = getelementptr %s, ptr %%env, i32 0, i32 %d\n", gep, env_ir, i);
        fprintf(side, "  %s = load %s, ptr %s, align 1\n", ld, ft, gep);
        if (!g.bind_rep(cap_names[(usz)i], ld, cap_bools[(usz)i], cap_ptrs[(usz)i], cap_types[(usz)i])) { fclose(side); free(body_buffer); g.out = saved_out; return null; }
    }
    for (usz i = 0; i < param_count; i++)
    {
        AirBinder* b = p.binders[i];
        if (b == null || b.name == null || same(b.name, "_")) { continue; }
        char[16] an;
        int na = snprintf(&an[0], 16, (char*)"%%a%d", (int)i);
        if (na < 0 || na >= 16) { fclose(side); free(body_buffer); g.out = saved_out; g.failed = true; return null; }
        if (!g.bind_rep(b.name, g.arena.dup(&an[0], (usz)na), m1_bool_type(params[i]), m1_pointer_repr_type(params[i]), params[i])) { fclose(side); free(body_buffer); g.out = saved_out; return null; }
    }
    bool body_ok = g.command(p.body, (char*)"%ret") && g.terminated;
    if (body_ok) { fprintf(side, "}\n"); }
    if (fclose(side) != 0) { g.out = saved_out; g.failed = true; return null; }
    // Restore the enclosing emission state before touching its stream again.
    g.out = saved_out; g.cur_block = saved_block; g.terminated = saved_terminated;
    g.current_function = saved_current;
    g.return_type = saved_return_type; g.return_bool = saved_return_bool; g.return_ptr = saved_return_ptr; g.return_unit = saved_return_unit;
    g.default_bits = saved_bits; g.default_unsigned = saved_unsigned;
    g.watch_active = saved_watch; g.watch_count = saved_watch_count;
    g.watch_branch_depth = saved_watch_depth; g.branch_depth = saved_branch; g.seq_depth = saved_seq;
    g.guard_active = saved_guard; g.guard_name = saved_gn; g.guard_true_label = saved_gt; g.guard_false_label = saved_gf;
    g.env_count = saved_env;
    if (!body_ok) { free(body_buffer); return null; }
    g.lam_buffers[(usz)g.lam_count] = body_buffer; g.lam_sizes[(usz)g.lam_count] = body_size; g.lam_count++;
    // Materialize the environment and the fat closure value in the host stream.
    char* env_operand = (char*)"null";
    if (cap_count > 0)
    {
        char* slot = g.tmp();
        if (slot == null) { g.failed = true; return null; }
        fprintf(g.out, "  %s = alloca %s, align 8\n", slot, env_ir);
        for (int i = 0; i < cap_count; i++)
        {
            char* ft = g.llvm_value_type_text(cap_types[(usz)i]);
            char* gep = g.tmp();
            if (ft == null || gep == null) { g.failed = true; return null; }
            fprintf(g.out, "  %s = getelementptr %s, ptr %s, i32 0, i32 %d\n", gep, env_ir, slot, i);
            fprintf(g.out, "  store %s %s, ptr %s, align 1\n", ft, cap_values[(usz)i], gep);
        }
        env_operand = slot;
    }
    char* c0 = g.tmp(); char* c1 = g.tmp();
    if (c0 == null || c1 == null) { g.failed = true; return null; }
    fprintf(g.out, "  %s = insertvalue %s undef, ptr @%s, 0\n", c0, closure_ir, lam_name);
    fprintf(g.out, "  %s = insertvalue %s %s, ptr %s, 1\n", c1, closure_ir, c0, env_operand);
    return c1;
}
// Append buffered lifted-closure definitions after the enclosing function.
fn bool M1Gen.flush_lambdas(M1Gen* g)
{
    for (int i = 0; i < g.lam_count; i++)
    {
        if (g.lam_buffers[(usz)i] != null && g.lam_sizes[(usz)i] > 0)
        {
            fwrite(g.lam_buffers[(usz)i], 1, g.lam_sizes[(usz)i], g.out);
            free(g.lam_buffers[(usz)i]);
        }
        g.lam_buffers[(usz)i] = null; g.lam_sizes[(usz)i] = 0;
    }
    g.lam_count = 0; g.lam_serial = 0;
    return true;
}
fn char* M1Gen.prd(M1Gen* g, AirPrd* p)
{
    if (p == null) { g.failed = true; return null; }
    g.last_line = p.source_line; g.last_col = p.source_col;
    if (p.tag == APRD_LAMBDA) { return g.lambda_value(p); }
    if (g.low_profile && p.tag == APRD_ALLOCA) { return g.alloca_prd(p); }
    if (g.low_profile && p.tag == APRD_LOAD) { return g.load_prd(p); }
    if (g.low_profile && p.tag == APRD_GEP) { return g.gep_prd(p); }
    if (g.low_profile && (p.tag == APRD_STRING || p.tag == APRD_BYTES))
    {
        AirTyp* result = g.expr_type(p);
        AirTyp* byte = result != null && m1_pointer_type(result) ? m1_pointee_type(result) : null;
        if (byte == null || (byte.tag != ATYP_U8 && byte.tag != ATYP_I8))
        {
            g.note_failure(p.source_line, p.source_col, (char*)"string/byte buffer requires a byte-pointer type"); return null;
        }
        return g.string_pointer(p);
    }
    if (p.tag == APRD_STRING || p.tag == APRD_BYTES)
    {
        char* bytes = p.tag == APRD_STRING ? p.name : p.bytes;
        bool string_terminator = p.tag == APRD_STRING && p.ty != null && p.ty.tag == ATYP_ARRAY && p.ty.ival == (long)p.bytes_len + 1;
        if (p.ty == null || p.ty.tag != ATYP_ARRAY || p.ty.arg_count != 1 || (p.ty.ival != (long)p.bytes_len && !string_terminator) || p.ty.ival > 1024 || (p.bytes_len > 0 && bytes == null)) { g.failed = true; return null; }
        AirTyp* byte_type = p.ty.args[0];
        if (byte_type == null || (byte_type.tag != ATYP_I8 && byte_type.tag != ATYP_U8)) { g.failed = true; return null; }
        char* aggregate_ir = g.llvm_type_text(p.ty);
        if (g.failed || aggregate_ir == null) { return null; }
        char* aggregate = p.ty.ival == 0 ? (char*)"zeroinitializer" : (char*)"undef";
        for (usz i = 0; i < (usz)p.ty.ival; i++)
        {
            int byte = i < p.bytes_len ? (int)bytes[i] : 0;
            if (byte < 0) { byte += 256; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            fprintf(g.out, "  %s = insertvalue %s %s, %s %d, %d\n", dst, aggregate_ir, aggregate, m1_llvm_scalar(byte_type), byte, (int)i);
            aggregate = dst;
        }
        return aggregate;
    }
    if (p.tag == APRD_CON)
    {
        AirDecl* owner = g.find_constructor_owner(p.name);
        if (owner == null || !m1_tagged_sum_decl(owner))
        { g.note_failure(p.source_line, p.source_col, (char*)"unsupported or ambiguous constructor value; constructors must belong to a supported tagged sum"); return null; }
        AirTyp* value_type = g.expr_type(p);
        if (value_type == null || value_type.tag != ATYP_NOMINAL || !same(value_type.name, owner.name))
        { g.note_failure(p.source_line, p.source_col, (char*)"constructor annotation does not match its declaring data type"); return null; }
        int tag = g.enum_constructor_index(owner, p.name);
        if (tag < 0 || p.sub_count != owner.ctors[(usz)tag].field_count)
        { g.note_failure(p.source_line, p.source_col, (char*)"constructor payload count does not match its declaration"); return null; }
        char* type_ir = g.llvm_type_text(value_type);
        if (type_ir == null) { return null; }
        if (m1_nullary_enum_decl(owner))
        {
            char* result = g.tmp();
            if (result == null) { return null; }
            fprintf(g.out, "  %s = insertvalue %s undef, i32 %d, 0\n", result, type_ir, tag);
            return result;
        }
        int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
        if (!g.tagged_sum_layout(owner, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size))
        { g.note_failure(p.source_line, p.source_col, (char*)"unsupported or malformed tagged-sum payload layout"); return null; }
        char* slot = g.tmp(); char* tag_address = g.tmp();
        if (slot == null || tag_address == null) { return null; }
        fprintf(g.out, "  %s = alloca %s, align %d\n", slot, type_ir, sum_align);
        fprintf(g.out, "  store %s zeroinitializer, ptr %s, align %d\n", type_ir, slot, sum_align);
        fprintf(g.out, "  %s = getelementptr %s, ptr %s, i32 0, i32 0\n", tag_address, type_ir, slot);
        fprintf(g.out, "  store i32 %d, ptr %s, align 4\n", tag, tag_address);
        AirCtorDecl* ctor = owner.ctors[(usz)tag];
        for (usz i = 0; i < ctor.field_count; i++)
        {
            AirTyp* expected = ctor.fields[i].ty;
            AirPrd* part = p.subs[i];
            if (expected == null || part == null) { g.note_failure(p.source_line, p.source_col, (char*)"malformed constructor payload"); return null; }
            bool expected_bool = m1_bool_type(expected);
            bool actual_bool = g.is_condition(part);
            bool actual_ptr = !actual_bool && g.is_pointer_value(part);
            if (actual_bool != expected_bool || actual_ptr)
            { g.note_failure(part.source_line, part.source_col, (char*)"constructor payload representation does not match its declared field"); return null; }
            bool compatible = expected_bool ? m1_bool_type(g.expr_type(part)) :
                (m1_integer_type(expected) ? g.integer_value_compatible(part, expected) :
                 (m1_float_type(expected) ? m1_scalar_compatible(expected, g.expr_type(part)) : m1_value_type_compatible(expected, g.expr_type(part), 0)));
            if (!compatible)
            { g.note_failure(part.source_line, part.source_col, (char*)"constructor payload type does not match its declared field"); return null; }
            char* value = expected_bool ? g.condition(part) : g.prd(part);
            char* field_ir = g.llvm_type_text(expected);
            char* address = g.tmp();
            long local_offset = 0;
            int field_align = g.type_alignment(expected, 0);
            if (g.failed || value == null || field_ir == null || address == null || field_align <= 0 ||
                !g.tagged_sum_field_offset(owner, (usz)tag, i, &local_offset) || local_offset < 0 || local_offset > 1048576 - payload_offset)
            { g.note_failure(part.source_line, part.source_col, (char*)"unsupported constructor payload layout"); return null; }
            fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", address, slot, payload_offset + local_offset);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", field_ir, value, address, field_align);
        }
        char* result = g.tmp();
        if (result == null) { return null; }
        fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", result, type_ir, slot, sum_align);
        return result;
    }
    if (p.tag == APRD_RECORD)
    {
        // Two shape conventions name the record's nominal type: a plain
        // `record { f = .. } : nominal T` ascription, or pfront's struct
        // convention `record{_f0 = T, f = ..}` where `_f0`'s variable names
        // the (data single-ctor or plain codata) record declaration.
        usz marker = 0;
        AirDecl* data = m1_record_producer_decl(p, g.decls, g.decl_count, &marker);
        if (data == null || (data.tag == ADECL_CODATA && !m1_record_codata_decl(data))) { g.failed = true; return null; }
        AirTyp nominal_t; nominal_t.tag = ATYP_NOMINAL; nominal_t.name = data.name; nominal_t.arg_count = 0;
        AirTyp* record_type = p.ty != null ? p.ty : &nominal_t;
        if (!m1_backend_type(record_type, g.decls, g.decl_count, 0)) { g.failed = true; return null; }
        usz field_total = m1_record_field_count(data);
        if (field_total != p.rec_init_count - marker || p.rec_init_count > 64 || field_total > 64) { g.failed = true; return null; }
        char* aggregate_type = g.llvm_type_text(record_type);
        if (g.failed || aggregate_type == null) { return null; }
        char* aggregate = field_total == 0 ? (char*)"zeroinitializer" : (char*)"undef";
        for (usz i = 0; i < field_total; i++)
        {
            AirFieldInit* init = p.rec_inits[i + marker];
            AirTyp* expected = m1_record_field_ty(data, i);
            char* field_name = m1_record_field_name(data, i);
            if (init == null || field_name == null || !same(init.name, field_name) || init.value == null) { g.failed = true; return null; }
            bool expected_bool = m1_bool_type(expected);            bool expected_ptr = m1_pointer_repr_type(expected);
            bool actual_bool = g.is_condition(init.value);
            bool actual_ptr = !actual_bool && g.is_pointer_value(init.value);
            if (actual_bool != expected_bool || actual_ptr != expected_ptr) { g.failed = true; return null; }
            if (m1_function_pointer_type(expected) && !m1_value_type_compatible(expected, g.expr_type(init.value), 0)) { g.failed = true; return null; }
            if (!expected_bool && !expected_ptr && !m1_value_type_compatible(expected, g.expr_type(init.value), 0) &&
                !(m1_integer_type(expected) && g.integer_value_compatible(init.value, expected))) { g.failed = true; return null; }
            char* value = actual_bool ? g.condition(init.value) : (actual_ptr ? g.pointer_value(init.value) : g.prd(init.value));
            char* field_ir = g.llvm_type_text(expected);
            char* dst = g.tmp();
            if (g.failed || value == null || field_ir == null || dst == null) { return null; }
            fprintf(g.out, "  %s = insertvalue %s %s, %s %s, %d\n", dst, aggregate_type, aggregate, field_ir, value, (int)i);
            aggregate = dst;
        }
        return aggregate;
    }
    if (p.tag == APRD_TUPLE || p.tag == APRD_ARRAY)
    {
        bool is_tuple = p.tag == APRD_TUPLE;
        bool shape_ok = p.ty != null && m1_value_type(p.ty, 0) && p.sub_count <= 1024;
        if (is_tuple) { shape_ok = shape_ok && p.ty.tag == ATYP_TUPLE && p.ty.arg_count == p.sub_count; }
        else { shape_ok = shape_ok && p.ty.tag == ATYP_ARRAY && p.ty.arg_count == 1 && p.ty.ival == (long)p.sub_count; }
        if (!shape_ok) { g.failed = true; return null; }
        char* aggregate_type = g.llvm_type_text(p.ty);
        if (g.failed || aggregate_type == null) { return null; }
        char* aggregate = p.sub_count == 0 ? (char*)"zeroinitializer" : (char*)"undef";
        for (usz i = 0; i < p.sub_count; i++)
        {
            AirPrd* part = p.subs[i];
            AirTyp* expected = is_tuple ? p.ty.args[i] : p.ty.args[0];
            if (part == null || expected == null) { g.failed = true; return null; }
            bool expected_bool = m1_bool_type(expected);
            bool expected_ptr = m1_pointer_repr_type(expected);
            bool actual_bool = g.is_condition(part);
            bool actual_ptr = !actual_bool && g.is_pointer_value(part);
            if (actual_bool != expected_bool || actual_ptr != expected_ptr) { g.failed = true; return null; }
            if (m1_function_pointer_type(expected) && !m1_value_type_compatible(expected, g.expr_type(part), 0)) { g.failed = true; return null; }
            if (!expected_bool && !expected_ptr)
            {
                bool compatible = m1_integer_type(expected) ? g.integer_value_compatible(part, expected) : m1_value_type_compatible(expected, g.expr_type(part), 0);
                if (!compatible) { g.failed = true; return null; }
            }
            char* value = actual_bool ? g.condition(part) : (actual_ptr ? g.pointer_value(part) : g.prd(part));
            char* element_type = g.llvm_type_text(expected);
            char* dst = g.tmp();
            if (g.failed || value == null || element_type == null || dst == null) { return null; }
            fprintf(g.out, "  %s = insertvalue %s %s, %s %s, %d\n", dst, aggregate_type, aggregate, element_type, value, (int)i);
            aggregate = dst;
        }
        return aggregate;
    }
    if (p.tag == APRD_SIZEOF || p.tag == APRD_ALIGNOF)
    {
        long low_size = g.low_profile ? g.type_size(p.ty, 0) : (long)m1_value_size(p.ty, 0);
        int low_align = g.low_profile ? g.type_alignment(p.ty, 0) : m1_value_alignment(p.ty, 0);
        long value = p.tag == APRD_SIZEOF ? low_size : (long)low_align;
        if (value < 0 || (p.tag == APRD_ALIGNOF && value == 0)) { g.failed = true; return null; }
        return g.int_text((long)value);
    }
    if (p.tag == APRD_CHAR)
    {
        if ((p.ty != null && p.ty.tag != ATYP_CHAR && p.ty.tag != ATYP_INFER) || !m1_unicode_scalar(p.ival)) { g.failed = true; return null; }
        return g.int_text(p.ival);
    }
    if (p.tag == APRD_INT)
    {
        if (!m1_integer_type(p.ty) || (m1_known_type(p.ty) && !m1_int_fits(p.ival, m1_int_bits(p.ty), m1_unsigned(p.ty)))) { g.failed = true; return null; }
        return g.int_text(p.ival);
    }
    if (p.tag == APRD_FLOAT)
    {
        if (!m1_float_type(p.ty) || !m1_known_type(p.ty)) { g.failed = true; return null; }
        return g.float_text(p.fval);
    }
    if (p.tag == APRD_UNIT) { return (char*)"zeroinitializer"; }
    if (p.tag == APRD_NULL)
    {
        if (!m1_pointer_repr_type(p.ty)) { g.failed = true; return null; }
        return (char*)"null";
    }
    if (p.tag == APRD_VAR)
    {
        AirTyp* value_type = g.expr_type(p);
        if (m1_function_pointer_type(value_type)) { return g.pointer_value(p); }
        char* value = g.lookup(p.name);
        if (value == null || g.lookup_bool(p.name) || g.lookup_ptr(p.name) || (!m1_integer_type(value_type) && !m1_float_type(value_type) && !m1_value_type(value_type, 0))) { g.failed = true; return null; }
        return value;
    }
    if (p.tag == APRD_COERCE)
    {
        if (p.sub_count != 1 || p.subs[0] == null || !m1_known_type(p.ty)) { g.failed = true; return null; }
        AirTyp* from_type = g.expr_type(p.subs[0]);
        bool to_pointer = m1_pointer_type(p.ty);
        bool from_pointer = g.is_pointer_value(p.subs[0]);
        if (to_pointer)
        {
            if (from_pointer)
            {
                char* pointer = g.pointer_value(p.subs[0]);
                if (g.failed || pointer == null || !g.retype_pointer(pointer, m1_pointee_type(p.ty))) { g.failed = true; return null; }
                return pointer;
            }
            if (!m1_integer_type(from_type) || !g.integer_value_compatible(p.subs[0], from_type)) { g.failed = true; return null; }
            char* integer = g.prd(p.subs[0]);
            char* dst = g.tmp();
            if (g.failed || integer == null || dst == null) { return null; }
            fprintf(g.out, "  %s = inttoptr %s %s to ptr\n", dst, m1_llvm_int(from_type), integer);
            return dst;
        }
        if (from_pointer)
        {
            if (!m1_integer_type(p.ty)) { g.failed = true; return null; }
            char* pointer = g.pointer_value(p.subs[0]);
            char* dst = g.tmp();
            if (g.failed || pointer == null || dst == null) { return null; }
            fprintf(g.out, "  %s = ptrtoint ptr %s to %s\n", dst, pointer, m1_llvm_int(p.ty));
            return dst;
        }
        bool from_bool = g.is_condition(p.subs[0]);
        bool to_bool = m1_bool_type(p.ty);
        bool to_int = m1_integer_type(p.ty);
        bool to_float = m1_float_type(p.ty);
        if (from_type == null && !from_bool && p.subs[0].tag == APRD_INT) { from_type = g.int_repr(g.default_bits, g.default_unsigned); }
        bool from_int = !from_bool && m1_integer_type(from_type);
        bool from_float = m1_float_type(from_type);
        if ((!to_bool && !to_int && !to_float) || (!from_bool && !from_int && !from_float)) { g.failed = true; return null; }
        if (to_bool && from_bool) { return g.condition(p.subs[0]); }
        if (to_float)
        {
            if (from_float && from_type.tag == p.ty.tag) { return g.prd(p.subs[0]); }
            if (!from_float && !from_int && !from_bool) { g.failed = true; return null; }
            if (from_int && !g.integer_value_compatible(p.subs[0], from_type)) { return null; }
            char* operand = from_bool ? g.condition(p.subs[0]) : g.prd(p.subs[0]);
            if (g.failed || operand == null) { return null; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            if (from_float)
            {
                char* op = from_type.tag == ATYP_F32 ? (char*)"fpext" : (char*)"fptrunc";
                fprintf(g.out, "  %s = %s %s %s to %s\n", dst, op, m1_llvm_float(from_type), operand, m1_llvm_float(p.ty));
            }
            else
            {
                char* source_ir = from_bool ? (char*)"i1" : m1_llvm_int(from_type);
                char* op = from_bool || m1_unsigned(from_type) ? (char*)"uitofp" : (char*)"sitofp";
                fprintf(g.out, "  %s = %s %s %s to %s\n", dst, op, source_ir, operand, m1_llvm_float(p.ty));
            }
            return dst;
        }
        if (from_float)
        {
            if (!to_int) { g.failed = true; return null; }
            char* operand = g.prd(p.subs[0]);
            char* dst = g.tmp();
            if (g.failed || operand == null || dst == null) { return null; }
            char* op = m1_unsigned(p.ty) ? (char*)"fptoui" : (char*)"fptosi";
            fprintf(g.out, "  %s = %s %s %s to %s\n", dst, op, m1_llvm_float(from_type), operand, m1_llvm_int(p.ty));
            return dst;
        }
        if (!to_bool && !to_int) { g.failed = true; return null; }
        int from_bits = from_bool ? 1 : m1_int_bits(from_type);
        int to_bits = to_bool ? 1 : m1_int_bits(p.ty);
        if (from_bits == 0 || to_bits == 0) { g.failed = true; return null; }
        if (from_int && !g.integer_value_compatible(p.subs[0], from_type)) { return null; }
        char* operand = from_bool ? g.condition(p.subs[0]) : g.prd(p.subs[0]);
        if (g.failed || operand == null) { return null; }
        if (from_bits == to_bits) { return operand; }
        char* dst = g.tmp();
        if (dst == null) { return null; }
        char* source_ir = from_bool ? (char*)"i1" : m1_llvm_int(from_type);
        char* target_ir = to_bool ? (char*)"i1" : m1_llvm_int(p.ty);
        char* op = from_bits > to_bits ? (char*)"trunc" : (from_bool || m1_unsigned(from_type) ? (char*)"zext" : (char*)"sext");
        fprintf(g.out, "  %s = %s %s %s to %s\n", dst, op, source_ir, operand, target_ir);
        return dst;
    }
    if (p.tag == APRD_BINOP)
    {
        if (p.sub_count != 2 || p.subs[0] == null || p.subs[1] == null) { g.failed = true; return null; }
        bool comparison = p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE;
        if (g.low_profile && comparison)
        {
            AirPrd* a = p.subs[0]; AirPrd* b = p.subs[1];
            AirTyp* at = g.expr_type(a); AirTyp* bt = g.expr_type(b);
            bool ap = g.is_pointer_value(a); bool bp = g.is_pointer_value(b);
            bool ab = g.is_condition(a); bool bb = g.is_condition(b);
            char* left = null; char* right = null; char* pred = null; char* llvm_ty = null;
            if (ap || bp)
            {
                if (!ap || !bp || (p.bop != ABIN_EQ && p.bop != ABIN_NEQ)) { g.failed = true; return null; }
                left = g.pointer_value(a); right = g.pointer_value(b); llvm_ty = (char*)"ptr";
                pred = p.bop == ABIN_EQ ? (char*)"eq" : (char*)"ne";
            }
            else if (ab || bb)
            {
                if (!ab || !bb || (p.bop != ABIN_EQ && p.bop != ABIN_NEQ)) { g.failed = true; return null; }
                left = g.condition(a); right = g.condition(b); llvm_ty = (char*)"i1";
                pred = p.bop == ABIN_EQ ? (char*)"eq" : (char*)"ne";
            }
            else if (m1_float_type(at) || m1_float_type(bt))
            {
                if (!m1_float_type(at) || !m1_float_type(bt) || at.tag != bt.tag) { g.failed = true; return null; }
                left = g.prd(a); right = g.prd(b); llvm_ty = m1_llvm_float(at);
                switch (p.bop)
                {
                    case ABIN_EQ: pred = (char*)"oeq"; break; case ABIN_NEQ: pred = (char*)"une"; break;
                    case ABIN_LT: pred = (char*)"olt"; break; case ABIN_GT: pred = (char*)"ogt"; break;
                    case ABIN_LE: pred = (char*)"ole"; break; case ABIN_GE: pred = (char*)"oge"; break;
                    default: return null;
                }
                char* dst = g.tmp();
                if (g.failed || left == null || right == null || dst == null) { return null; }
                fprintf(g.out, "  %s = fcmp %s %s %s, %s\n", dst, pred, llvm_ty, left, right);
                return dst;
            }
            else
            {
                AirTyp* it = m1_integer_type(at) ? at : (m1_integer_type(bt) ? bt : g.int_repr(g.default_bits, g.default_unsigned));
                if (!m1_integer_type(it) || (m1_integer_type(at) && m1_int_bits(at) != m1_int_bits(it)) || (m1_integer_type(bt) && m1_int_bits(bt) != m1_int_bits(it)) ||
                    (m1_known_type(at) && m1_known_type(bt) && m1_unsigned(at) != m1_unsigned(bt))) { g.failed = true; return null; }
                bool uns = m1_unsigned(it); int bits = m1_int_bits(it);
                if (a.tag == APRD_INT && (at == null || at.tag == ATYP_INFER))
                {
                    if (!m1_int_fits(a.ival, bits, uns)) { g.failed = true; return null; }
                    left = g.int_text(a.ival);
                }
                else { left = g.prd(a); }
                if (b.tag == APRD_INT && (bt == null || bt.tag == ATYP_INFER))
                {
                    if (!m1_int_fits(b.ival, bits, uns)) { g.failed = true; return null; }
                    right = g.int_text(b.ival);
                }
                else { right = g.prd(b); }
                llvm_ty = m1_llvm_bits(bits);
                switch (p.bop)
                {
                    case ABIN_EQ: pred = (char*)"eq"; break; case ABIN_NEQ: pred = (char*)"ne"; break;
                    case ABIN_LT: pred = uns ? (char*)"ult" : (char*)"slt"; break;
                    case ABIN_GT: pred = uns ? (char*)"ugt" : (char*)"sgt"; break;
                    case ABIN_LE: pred = uns ? (char*)"ule" : (char*)"sle"; break;
                    case ABIN_GE: pred = uns ? (char*)"uge" : (char*)"sge"; break;
                    default: return null;
                }
            }
            char* dst = g.tmp();
            if (g.failed || left == null || right == null || dst == null || pred == null || llvm_ty == null) { return null; }
            fprintf(g.out, "  %s = icmp %s %s %s, %s\n", dst, pred, llvm_ty, left, right);
            return dst;
        }
        AirTyp* result_type = g.expr_type(p);
        AirTyp* left_type = g.expr_type(p.subs[0]);
        AirTyp* right_type = g.expr_type(p.subs[1]);
        if (m1_float_type(result_type) || m1_float_type(left_type) || m1_float_type(right_type))
        {
            if (!m1_float_type(left_type) || !m1_float_type(right_type) || left_type.tag != right_type.tag || (m1_known_type(result_type) && (!m1_float_type(result_type) || result_type.tag != left_type.tag))) { g.failed = true; return null; }
            char* op = null;
            switch (p.bop)
            {
                case ABIN_ADD: op = (char*)"fadd"; break;
                case ABIN_SUB: op = (char*)"fsub"; break;
                case ABIN_MUL: op = (char*)"fmul"; break;
                case ABIN_DIV: op = (char*)"fdiv"; break;
                case ABIN_MOD: op = (char*)"frem"; break;
                default: g.failed = true; return null;
            }
            char* left = g.prd(p.subs[0]);
            char* right = g.prd(p.subs[1]);
            if (g.failed || left == null || right == null) { return null; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            fprintf(g.out, "  %s = %s %s %s, %s\n", dst, op, m1_llvm_float(left_type), left, right);
            return dst;
        }
        if ((result_type != null && !m1_integer_type(result_type)) || (left_type != null && !m1_integer_type(left_type)) || (right_type != null && !m1_integer_type(right_type))) { g.failed = true; return null; }
        int bits = result_type != null ? m1_int_bits(result_type) : (left_type != null ? m1_int_bits(left_type) : (right_type != null ? m1_int_bits(right_type) : g.default_bits));
        if (bits == 0 || (left_type != null && m1_int_bits(left_type) != bits) || (right_type != null && m1_int_bits(right_type) != bits)) { g.failed = true; return null; }
        bool result_known = m1_known_type(result_type);
        bool left_known = m1_known_type(left_type);
        bool right_known = m1_known_type(right_type);
        bool left_unsigned = m1_unsigned(left_type);
        bool right_unsigned = m1_unsigned(right_type);
        bool result_unsigned = m1_unsigned(result_type);
        if (left_known && right_known && left_unsigned != right_unsigned) { g.failed = true; return null; }
        bool operand_known = left_known || right_known;
        bool operand_unsigned = left_known ? left_unsigned : right_unsigned;
        if (result_known && operand_known && result_unsigned != operand_unsigned) { g.failed = true; return null; }
        bool uns = result_known ? result_unsigned : (operand_known ? operand_unsigned : g.default_unsigned);
        AirTyp* int_context = g.int_repr(bits, uns);
        if (g.failed || !m1_contextual_int_fits(p.subs[0], int_context) || !m1_contextual_int_fits(p.subs[1], int_context)) { g.failed = true; return null; }
        char* left = g.prd(p.subs[0]);
        char* right = g.prd(p.subs[1]);
        if (g.failed || left == null || right == null) { return null; }
        char* op = null;
        switch (p.bop)
        {
            case ABIN_ADD: op = (char*)"add"; break;
            case ABIN_SUB: op = (char*)"sub"; break;
            case ABIN_MUL: op = (char*)"mul"; break;
            case ABIN_DIV: op = uns ? (char*)"udiv" : (char*)"sdiv"; break;
            case ABIN_MOD: op = uns ? (char*)"urem" : (char*)"srem"; break;
            case ABIN_AND: op = (char*)"and"; break;
            case ABIN_OR: op = (char*)"or"; break;
            case ABIN_XOR: op = (char*)"xor"; break;
            case ABIN_SHL: op = (char*)"shl"; break;
            case ABIN_SHR: op = uns ? (char*)"lshr" : (char*)"ashr"; break;
            default: g.failed = true; return null;
        }
        char* dst = g.tmp();
        if (dst == null) { return null; }
        fprintf(g.out, "  %s = %s %s %s, %s\n", dst, op, m1_llvm_bits(bits), left, right);
        return dst;
    }
    if (p.tag == APRD_UNOP && p.sub_count == 1)
    {
        AirTyp* result_type = g.expr_type(p);
        AirTyp* operand_type = g.expr_type(p.subs[0]);
        if (m1_float_type(result_type) || m1_float_type(operand_type))
        {
            if (p.uop != AUN_NEG || !m1_float_type(operand_type) || (m1_known_type(result_type) && (!m1_float_type(result_type) || result_type.tag != operand_type.tag))) { g.failed = true; return null; }
            char* operand = g.prd(p.subs[0]);
            if (g.failed || operand == null) { return null; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            fprintf(g.out, "  %s = fneg %s %s\n", dst, m1_llvm_float(operand_type), operand);
            return dst;
        }
        if ((result_type != null && !m1_integer_type(result_type)) || (operand_type != null && !m1_integer_type(operand_type))) { g.failed = true; return null; }
        int bits = result_type != null ? m1_int_bits(result_type) : (operand_type != null ? m1_int_bits(operand_type) : g.default_bits);
        if (bits == 0 || (operand_type != null && m1_int_bits(operand_type) != bits)) { g.failed = true; return null; }
        bool uns = m1_known_type(result_type) ? m1_unsigned(result_type) : (m1_known_type(operand_type) ? m1_unsigned(operand_type) : g.default_unsigned);
        AirTyp* int_context = g.int_repr(bits, uns);
        if (g.failed || !m1_contextual_int_fits(p.subs[0], int_context)) { g.failed = true; return null; }
        char* operand = g.prd(p.subs[0]);
        if (g.failed || operand == null) { return null; }
        char* op = null;
        char* lhs = operand;
        char* rhs = null;
        if (p.uop == AUN_NEG) { op = (char*)"sub"; rhs = operand; lhs = (char*)"0"; }
        else if (p.uop == AUN_BITNOT) { op = (char*)"xor"; rhs = (char*)"-1"; }
        else { g.failed = true; return null; }
        char* dst = g.tmp();
        if (dst == null) { return null; }
        fprintf(g.out, "  %s = %s %s %s, %s\n", dst, op, m1_llvm_bits(bits), lhs, rhs);
        return dst;
    }
    g.failed = true;
    return null;
}
fn bool M1Gen.is_pointer_value(M1Gen* g, AirPrd* p)
{
    if (p == null) {
 return false; }
    // AIR's null literal is contextually typed by its use. Some valid untyped
    // comparisons retain the enclosing bool result type on the literal node;
    // the APRD_NULL tag itself is the reliable pointer discriminator.
    if (p.tag == APRD_NULL) { return true; }    if (g.low_profile && (p.tag == APRD_ALLOCA || p.tag == APRD_LOAD || p.tag == APRD_GEP || p.tag == APRD_STRING || p.tag == APRD_BYTES) && m1_pointer_repr_type(g.expr_type(p))) { return true; }
    if (p.tag == APRD_VAR)
    {
        AirTyp* type = g.expr_type(p);
        if (g.lookup_ptr(p.name)) { return type == null || type.tag == ATYP_INFER || m1_pointer_repr_type(type); }
        return m1_function_pointer_type(type) && g.lookup(p.name) == null && g.find_function(p.name) != null;
    }
    if (p.tag == APRD_COERCE && p.sub_count == 1 && m1_pointer_type(p.ty))
    {
        return m1_integer_type(g.expr_type(p.subs[0])) || g.is_pointer_value(p.subs[0]);
    }
 return false;
}
fn char* M1Gen.pointer_value(M1Gen* g, AirPrd* p)
{
    if (!g.is_pointer_value(p)) { g.failed = true; return null; }
    if (p.tag == APRD_NULL) { return (char*)"null"; }    if (p.tag == APRD_VAR)
    {
        char* value = g.lookup(p.name);
        if (value != null) { return value; }
        AirDecl* target = g.find_function(p.name);
        if (target != null && target.is_extern && m1_function_signature(target))
        {
            AirTyp* return_type = g.decl_return_type(target);
            if (m1_c_abi_aggregate_type(return_type) && g.external_aggregate_problem(return_type) != null)
            { g.note_external_aggregate_failure(target, return_type, p.source_line, p.source_col); return null; }
            for (usz i = 0; i < target.param_count; i++)
            {
                AirTyp* parameter_type = g.decl_value_type(target.params[i].ty, return_type);
                if (m1_c_abi_aggregate_type(parameter_type) && g.external_aggregate_problem(parameter_type) != null)
                { g.note_external_aggregate_failure(target, parameter_type, p.source_line, p.source_col); return null; }
            }
        }
        AirTyp* actual_type = target == null ? null : g.function_type(target);
        AirTyp* expected_type = g.expr_type(p);
        if (target == null || actual_type == null || !m1_function_pointer_type(expected_type) ||
            !m1_value_type_compatible(expected_type, actual_type, 0) || !m1_safe_name(m1_link_name(target)))
        {
            g.note_failure(p.source_line, p.source_col, (char*)"function value does not match its declared function signature"); return null;
        }
        if (m1_decl_callconv(target) != 0)
        {
            g.note_failure(p.source_line, p.source_col, "a function with a non-default calling convention cannot be used as a first-class value (closures and indirect calls use the default convention)");
            return null;
        }
        char[512] symbol;
        int n = snprintf(&symbol[0], 512, (char*)"@%s", m1_link_name(target));
        if (n < 0 || n >= 512) { g.failed = true; return null; }
        return g.arena.dup(&symbol[0], (usz)n);
    }
    if (g.low_profile && (p.tag == APRD_ALLOCA || p.tag == APRD_LOAD || p.tag == APRD_GEP || p.tag == APRD_STRING || p.tag == APRD_BYTES)) { return g.prd(p); }
    if (p.tag == APRD_COERCE) { return g.prd(p); }
    g.failed = true;
    return null;
}
// Boolean conditions are kept as LLVM i1 values and are not confused with the
// backend's i64 scalar representation.
fn char* M1Gen.condition(M1Gen* g, AirPrd* p)
{
    if (p == null) { g.failed = true; return null; }
    if (p.tag == APRD_COERCE && m1_bool_type(p.ty)) { return g.prd(p); }
    if (p.tag == APRD_BOOL)
    {
        if (p.ty != null && p.ty.tag != ATYP_INFER && p.ty.tag != ATYP_BOOL) { g.failed = true; return null; }
        return p.bval ? (char*)"true" : (char*)"false";
    }
    if (p.tag == APRD_VAR)
    {
        char* value = g.lookup(p.name);
        if (value == null || !g.lookup_bool(p.name)) { g.failed = true; return null; }
        return value;
    }
    if (p.tag == APRD_UNOP && p.uop == AUN_NOT && p.sub_count == 1)
    {
        char* value = g.condition(p.subs[0]);
        if (g.failed || value == null) { return null; }
        char* dst = g.tmp();
        if (dst == null) { return null; }
        fprintf(g.out, "  %s = xor i1 %s, true\n", dst, value);
        return dst;
    }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        if (p.subs[0] == null || p.subs[1] == null) { g.failed = true; return null; }
        bool left_ptr = g.is_pointer_value(p.subs[0]);
        bool right_ptr = g.is_pointer_value(p.subs[1]);
        if (left_ptr || right_ptr)
        {
            if (!left_ptr || !right_ptr || (p.bop != ABIN_EQ && p.bop != ABIN_NEQ)) { g.failed = true; return null; }
            char* left = g.pointer_value(p.subs[0]);
            char* right = g.pointer_value(p.subs[1]);
            if (g.failed || left == null || right == null) { return null; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            fprintf(g.out, "  %s = icmp %s ptr %s, %s\n", dst, p.bop == ABIN_EQ ? (char*)"eq" : (char*)"ne", left, right);
            return dst;
        }
        bool left_bool = g.is_condition(p.subs[0]);
        bool right_bool = g.is_condition(p.subs[1]);
        if (left_bool || right_bool)
        {
            if (!left_bool || !right_bool || (p.ty != null && p.ty.tag != ATYP_INFER && p.ty.tag != ATYP_BOOL)) { g.failed = true; return null; }
            char* left = g.condition(p.subs[0]);
            char* right = g.condition(p.subs[1]);
            if (g.failed || left == null || right == null) { return null; }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ)
            {
                fprintf(g.out, "  %s = icmp %s i1 %s, %s\n", dst, p.bop == ABIN_EQ ? (char*)"eq" : (char*)"ne", left, right);
            }
            else if (p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR)
            {
                char* op = p.bop == ABIN_AND ? (char*)"and" : (p.bop == ABIN_OR ? (char*)"or" : (char*)"xor");
                fprintf(g.out, "  %s = %s i1 %s, %s\n", dst, op, left, right);
            }
            else { g.failed = true; return null; }
            return dst;
        }
        bool compare = p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE;
        AirTyp* left_type = g.expr_type(p.subs[0]);
        AirTyp* right_type = g.expr_type(p.subs[1]);
        if (m1_float_type(left_type) || m1_float_type(right_type))
        {
            if (!compare || !m1_float_type(left_type) || !m1_float_type(right_type) || left_type.tag != right_type.tag || (p.ty != null && p.ty.tag != ATYP_INFER && p.ty.tag != ATYP_BOOL)) { g.failed = true; return null; }
            char* left = g.prd(p.subs[0]);
            char* right = g.prd(p.subs[1]);
            if (g.failed || left == null || right == null) { return null; }
            char* pred = null;
            switch (p.bop)
            {
                case ABIN_EQ: pred = (char*)"oeq"; break;
                case ABIN_NEQ: pred = (char*)"une"; break;
                case ABIN_LT: pred = (char*)"olt"; break;
                case ABIN_GT: pred = (char*)"ogt"; break;
                case ABIN_LE: pred = (char*)"ole"; break;
                case ABIN_GE: pred = (char*)"oge"; break;
                default: g.failed = true; return null;
            }
            char* dst = g.tmp();
            if (dst == null) { return null; }
            fprintf(g.out, "  %s = fcmp %s %s %s, %s\n", dst, pred, m1_llvm_float(left_type), left, right);
            return dst;
        }
        if (!compare || (left_type != null && !m1_integer_type(left_type)) || (right_type != null && !m1_integer_type(right_type))) { g.failed = true; return null; }
        int bits = left_type != null ? m1_int_bits(left_type) : (right_type != null ? m1_int_bits(right_type) : g.default_bits);
        if (bits == 0 || (left_type != null && m1_int_bits(left_type) != bits) || (right_type != null && m1_int_bits(right_type) != bits)) { g.failed = true; return null; }
        bool left_known = m1_known_type(left_type);
        bool right_known = m1_known_type(right_type);
        bool left_unsigned = m1_unsigned(left_type);
        bool right_unsigned = m1_unsigned(right_type);
        if (left_known && right_known && left_unsigned != right_unsigned) { g.failed = true; return null; }
        bool uns = left_known ? left_unsigned : (right_known ? right_unsigned : g.default_unsigned);
        AirTyp* int_context = g.int_repr(bits, uns);
        if (g.failed || !m1_contextual_int_fits(p.subs[0], int_context) || !m1_contextual_int_fits(p.subs[1], int_context)) { g.failed = true; return null; }
        char* left = g.prd(p.subs[0]);
        char* right = g.prd(p.subs[1]);
        if (g.failed || left == null || right == null) { return null; }
        char* pred = null;
        switch (p.bop)
        {
            case ABIN_EQ: pred = (char*)"eq"; break;
            case ABIN_NEQ: pred = (char*)"ne"; break;
            case ABIN_LT: pred = uns ? (char*)"ult" : (char*)"slt"; break;
            case ABIN_GT: pred = uns ? (char*)"ugt" : (char*)"sgt"; break;
            case ABIN_LE: pred = uns ? (char*)"ule" : (char*)"sle"; break;
            case ABIN_GE: pred = uns ? (char*)"uge" : (char*)"sge"; break;
            default: g.failed = true; return null;
        }
        char* dst = g.tmp();
        if (dst == null) { return null; }
        fprintf(g.out, "  %s = icmp %s %s %s, %s\n", dst, pred, m1_llvm_bits(bits), left, right);
        return dst;
    }
    g.failed = true;
    return null;
}
// M1 continuation consumer: scalar values may return or feed a comu binder.
fn bool M1Gen.consume(M1Gen* g, char* value, bool is_bool, bool is_ptr, AirTyp* value_type, AirCns* k, char* ret_name)
{    if (k == null || value == null || (is_bool && is_ptr)) {
 return false; }
    if (k.tag == ACNS_FIELD)
    {
        if (k.tail == null || k.idx < 0) {
 return false; }
        // The owner type comes from the value's nominal ascription when it
        // has one; pfront erases struct parameter annotations (`: infer`), so
        // otherwise resolve the projection by declaration: exactly one
        // product record with a field `k.name` at index `k.idx` must exist.
        AirDecl* data = null;
        AirTyp nominal_t; nominal_t.tag = ATYP_NOMINAL; nominal_t.arg_count = 0;
        if (value_type != null && value_type.tag == ATYP_NOMINAL)
        {
            data = m1_find_record_decl(g.decls, g.decl_count, value_type.name);
        }
        else
        {
            for (usz i = 0; i < g.decl_count; i++)
            {
                AirDecl* cand = g.decls[i];
                if (cand == null || (cand.tag != ADECL_DATA && cand.tag != ADECL_CODATA)) { continue; }
                if (cand.tag == ADECL_CODATA ? !m1_record_codata_decl(cand)
                                             : (cand.ctor_count != 1 || cand.ctors[0] == null)) { continue; }
                if ((usz)k.idx < m1_record_field_count(cand) && same(m1_record_field_name(cand, (usz)k.idx), k.name))
                {
                    if (data != null && !same(data.name, cand.name))
                    {
                        g.note_failure(k.source_line, k.source_col, (char*)"ambiguous record field projection: more than one record declares this field at this index; ascribe the owner type");
                        return false;
                    }
                    data = cand;
                }
            }
            if (data == null)
            {
                g.note_failure(k.source_line, k.source_col, (char*)"no product record declares a field with this name at this index");
                return false;
            }
        }
        if (data == null || (usz)k.idx >= m1_record_field_count(data)) {
 return false; }
        nominal_t.name = data.name;
        AirTyp* field_ty = m1_record_field_ty(data, (usz)k.idx);
        char* field_name = m1_record_field_name(data, (usz)k.idx);
        if (field_name == null || !same(field_name, k.name) || field_ty == null || !m1_backend_type(field_ty, g.decls, g.decl_count, 0)) {
 g.note_failure(k.source_line, k.source_col, (char*)"record field is not a backend-representable projection"); return false; }
        char* aggregate_ir = g.llvm_type_text(&nominal_t);
        char* field_ir = g.llvm_type_text(field_ty);
        char* dst = g.tmp();
        if (g.failed || aggregate_ir == null || field_ir == null || dst == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", dst, aggregate_ir, value, k.idx);
        return g.consume(dst, m1_bool_type(field_ty), m1_pointer_repr_type(field_ty), field_ty, k.tail, ret_name);
    }
    if (k.tag == ACNS_PROJ || k.tag == ACNS_FST || k.tag == ACNS_SND)
    {
        if (k.tail == null || value_type == null) {
 return false; }
        bool is_tuple = value_type.tag == ATYP_TUPLE;
        bool is_array = value_type.tag == ATYP_ARRAY && k.tag == ACNS_PROJ && value_type.arg_count == 1;
        if (!is_tuple && !is_array) {
 return false; }
        long ix = k.tag == ACNS_FST ? 0 : (k.tag == ACNS_SND ? 1 : k.idx);
        usz count = is_tuple ? value_type.arg_count : (usz)value_type.ival;
        if (ix < 0 || (usz)ix >= count) {
 return false; }
        AirTyp* element_type = is_tuple ? value_type.args[(usz)ix] : value_type.args[0];
        if (!m1_value_type(element_type, 0)) {
 return false; }
        char* aggregate_ir = g.llvm_type_text(value_type);
        char* element_ir = g.llvm_type_text(element_type);
        char* dst = g.tmp();
        if (g.failed || aggregate_ir == null || element_ir == null || dst == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", dst, aggregate_ir, value, ix);
        return g.consume(dst, m1_bool_type(element_type), m1_pointer_repr_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_INDEX)
    {
        if (k.prd == null || k.tail == null || is_bool) {
 return false; }
        AirTyp* index_type = g.expr_type(k.prd);
        AirTyp* index_rep = g.int_rep_type(index_type);
        if (index_rep == null || !g.integer_value_compatible(k.prd, index_rep)) {
 return false; }
        if (!is_ptr && value_type != null && value_type.tag == ATYP_ARRAY && value_type.arg_count == 1)
        {
            AirTyp* element_type = value_type.args[0];
            int bytes = m1_memory_bytes(element_type);
            if (k.tail.tag == ACNS_STORE || !m1_supported_memory_width(bytes) || k.idx != bytes || value_type.ival <= 0) {
 return false; }
            char* aggregate_ir = g.llvm_type_text(value_type);
            char* element_ir = g.llvm_type_text(element_type);
            if (g.failed || aggregate_ir == null || element_ir == null) {
 return false; }
            if (k.prd.tag == APRD_INT)
            {
                if (k.prd.ival < 0 || k.prd.ival >= value_type.ival) {
 return false; }
                char* dst = g.tmp();
                if (dst == null) {
 return false; }
                fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", dst, aggregate_ir, value, k.prd.ival);
                return g.consume(dst, m1_bool_type(element_type), m1_pointer_repr_type(element_type), element_type, k.tail, ret_name);
            }
            char* index_value = g.index_as_i64(k.prd, index_type);
            char* slot = g.tmp();
            char* address = g.tmp();
            char* loaded = g.tmp();
            if (g.failed || index_value == null || slot == null || address == null || loaded == null) {
 return false; }
            fprintf(g.out, "  %s = alloca %s, align 1\n", slot, aggregate_ir);
            fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_ir, value, slot);
            fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 0, i64 %s\n", address, aggregate_ir, slot, index_value);
            fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, element_ir, address);
            return g.consume(loaded, m1_bool_type(element_type), m1_pointer_repr_type(element_type), element_type, k.tail, ret_name);
        }
        AirTyp* element_type = m1_pointee_type(value_type);
        int bytes = m1_memory_bytes(element_type);
        if (g.low_profile) { g.note_failure(g.last_line, g.last_col, (char*)"untyped pointer-index memory is unsupported in AIR 3; use typed gep/load/store"); return false; }        if (!is_ptr || !m1_supported_memory_width(bytes) || k.idx != bytes) {
 return false; }
        char* index_value = g.index_as_i64(k.prd, index_type);
        char* llvm_element = g.llvm_value_type_text(element_type);
        if (g.failed || index_value == null || llvm_element == null) {
 return false; }
        char* address = g.tmp();
        if (address == null) {
 return false; }
        fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 %s\n", address, llvm_element, value, index_value);
        if (k.tail.tag == ACNS_STORE)
        {
            AirTyp* element_ptr = air_ir::air_mk_typ_ptr(g.arena, element_type);
            if (element_ptr == null) {
 return false; }
            return g.consume(address, false, true, element_ptr, k.tail, ret_name);
        }
        char* loaded = g.tmp();
        if (loaded == null) {
 return false; }
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, llvm_element, address);
        return g.consume(loaded, m1_bool_type(element_type), m1_pointer_repr_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_DEREF)
    {
        if (g.low_profile) { g.note_failure(g.last_line, g.last_col, (char*)"untyped dereference is unsupported in AIR 3; use typed load"); return false; }
        AirTyp* element_type = m1_pointee_type(value_type);
        if (!is_ptr || is_bool || k.tail == null || m1_memory_bytes(element_type) == 0) {
 return false; }
        char* loaded = g.tmp();
        if (loaded == null) {
 return false; }
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, g.llvm_value_type_text(element_type), value);
        return g.consume(loaded, m1_bool_type(element_type), m1_pointer_repr_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_STORE)
    {
        if (g.low_profile) { g.note_failure(g.last_line, g.last_col, (char*)"untyped continuation store is unsupported in AIR 3; use typed store"); return false; }
        AirTyp* element_type = m1_pointee_type(value_type);
        int bytes = m1_memory_bytes(element_type);
        AirTyp* stored_type = g.expr_type(k.prd);
        if (!is_ptr || is_bool || k.prd == null || !m1_supported_memory_width(bytes) || k.idx != bytes) {
 return false; }
        bool element_bool = m1_bool_type(element_type);
        if (element_bool)
        {
            if (!g.is_condition(k.prd)) {
 return false; }
            char* stored_bool = g.condition(k.prd);
            if (g.failed || stored_bool == null) {
 return false; }
            fprintf(g.out, "  store i1 %s, ptr %s, align 1\n", stored_bool, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (m1_pointer_type(element_type))
        {
            if (!g.is_pointer_value(k.prd)) {
 return false; }
            char* stored_pointer = g.pointer_value(k.prd);
            if (g.failed || stored_pointer == null) {
 return false; }
            fprintf(g.out, "  store ptr %s, ptr %s, align 1\n", stored_pointer, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (element_type != null && (element_type.tag == ATYP_TUPLE || element_type.tag == ATYP_ARRAY))
        {
            if (!m1_value_type_compatible(element_type, stored_type, 0)) {
 return false; }
            char* aggregate_type = g.llvm_type_text(element_type);
            char* stored_aggregate = g.prd(k.prd);
            if (g.failed || aggregate_type == null || stored_aggregate == null) {
 return false; }
            fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_type, stored_aggregate, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (m1_float_type(element_type))
        {
            if (!m1_float_type(stored_type) || stored_type.tag != element_type.tag) {
 return false; }
        }
        else
        {
            if (!m1_integer_type(stored_type)) {
 return false; }
            if (!m1_known_type(stored_type))
            {
                int bits = m1_int_bits(element_type);
                if (k.prd.tag != APRD_INT && g.default_bits != bits) {
 return false; }
                if (!m1_contextual_int_fits(k.prd, element_type)) {
 return false; }
            }
        }
        char* stored = g.prd(k.prd);
        if (g.failed || stored == null) {
 return false; }
        if (!element_bool && !m1_pointer_type(element_type) && !m1_float_type(element_type))
        {
            AirTyp* source_type = g.int_rep_type(stored_type);
            stored = g.convert_integer_width(stored, source_type, element_type);
            if (g.failed || stored == null) {
 return false; }
        }
        fprintf(g.out, "  store %s %s, ptr %s, align 1\n", m1_llvm_scalar(element_type), stored, value);
        return g.consume_unit(k.tail, ret_name);
    }
    if (k.tag == ACNS_COVAR)
    {
        if (g.guard_active && g.guard_name != null && same(k.name, g.guard_name) && same(ret_name, g.guard_name))
        {
            if (!is_bool || is_ptr || g.guard_true_label == null || g.guard_false_label == null) {
 return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", value, g.guard_true_label, g.guard_false_label);
            g.terminated = true;
            return true;
        }
        if (!same(k.name, ret_name) || is_bool != g.return_bool || is_ptr != g.return_ptr || g.return_unit) {
 return false; }
        if (is_ptr && m1_function_pointer_type(g.return_type) && !m1_value_type_compatible(g.return_type, value_type, 0)) {
 return false; }
        if (!is_bool && !is_ptr)
        {
            value_type = g.int_rep_type(value_type);
            if (g.return_type != null && (g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY || g.return_type.tag == ATYP_NOMINAL))
            {
                if (!m1_value_type_compatible(g.return_type, value_type, 0)) {
 return false; }
            }
            else if (m1_integer_type(g.return_type) && m1_integer_type(value_type) && m1_int_bits(g.return_type) > m1_int_bits(value_type))
            {
                value = g.convert_integer_width(value, value_type, g.return_type);
                if (g.failed || value == null) {
 return false; }
                value_type = g.return_type;
            }
            else if (!m1_scalar_compatible(g.return_type, value_type)) {
 return false; }
        }
        char* ret_ir = is_bool ? (char*)"i1" : (is_ptr ? (char*)"ptr" : ((g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY || g.return_type.tag == ATYP_NOMINAL) ? g.llvm_type_text(g.return_type) : m1_llvm_scalar(g.return_type)));        if (ret_ir == null) {
 return false; }
        fprintf(g.out, "  ret %s %s\n", ret_ir, value);
        g.terminated = true;
        return true;
    }
    if (k.tag == ACNS_ASCRIBE)
    {
        if (k.tail == null || k.ty == null || is_bool != m1_bool_type(k.ty) || is_ptr != m1_pointer_repr_type(k.ty)) {
 return false; }
        if ((!is_bool && !is_ptr && !m1_value_type_compatible(k.ty, value_type, 0)) ||
            (is_ptr && m1_function_pointer_type(k.ty) && !m1_value_type_compatible(k.ty, value_type, 0))) {
 return false; }
        return g.consume(value, is_bool, is_ptr, k.ty, k.tail, ret_name);
    }
    if (k.tag == ACNS_COMU)
    {
        usz saved = g.env_count;
        if (!is_bool && !is_ptr) { value_type = g.int_rep_type(value_type); }
        if (!g.bind_typed(k.bind, value, is_bool, is_ptr, value_type)) {
 return false; }
        bool ok = g.command(k.body, ret_name);
        // Bindings introduced by a continuation in ACMD_SEQ remain visible to
        // that sequence's `next`; the sequence restores its environment at exit.
        if (g.seq_depth == 0 || !ok) { g.env_count = saved; }
        return ok;
    }
 return false;
}
fn bool M1Gen.consume_unit(M1Gen* g, AirCns* k, char* ret_name)
{
    if (k == null) {
 return false; }
    if (k.tag == ACNS_COVAR)
    {
        // The middot continuation is AIR's discard hole, not the function
        // return continuation. A unit value sent here is an ordinary no-op.
        if (same(k.name, (char*)"\xc2\xb7") || g.seq_depth > 0) { return true; }
        if (!g.return_unit || !same(k.name, ret_name)) {
 return false; }
        fprintf(g.out, "  ret void\n");
        g.terminated = true;
        return true;
    }
    if (k.tag == ACNS_COMU)
    {
        // A unit continuation may name its ignored unit result (for example
        // an administrative AIR binder). Unit has no LLVM value to materialize;
        // leaving the name unbound makes any attempted scalar use fail closed.
        if (k.bind != null && !same(k.bind, "_") && g.lookup(k.bind) != null) {
 return false; }
        return g.command(k.body, ret_name);
    }
 return false;
}
fn void M1Gen.mark_allocation_freed(M1Gen* g, char* allocation)
{
    for (int i = 0; i < g.provenance_count; i++)
    {
        if (same(g.provenance[i].allocation, allocation)) { g.provenance[i].freed = true; }
    }
    for (int i = 0; i < g.pointer_cell_count; i++)
    {
        if (same(g.pointer_cells[i].value_allocation, allocation)) { g.pointer_cells[i].freed = true; }
    }
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
    if (result_unit || sret_result) { fprintf(g.out, "  call %svoid ", call_cc_text); }
    else
    {
        dst = g.tmp();
        if (dst == null) {
 return false; }
        fprintf(g.out, "  %s = call %s%s ", dst, call_cc_text, call_result_type);
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
fn bool M1Gen.emit_constant(M1Gen* g, AirPrd* p, AirTyp* t, int depth)
{
    if (p == null || t == null || depth >= 16) {
 return false; }
    if (p.tag == APRD_INT || p.tag == APRD_CHAR)
    {
        if (!m1_integer_type(t) && t.tag != ATYP_CHAR) {
 return false; }
        if (m1_integer_type(t) && !m1_int_fits(p.ival, m1_int_bits(t), m1_unsigned(t))) {
 return false; }
        fprintf(g.out, "%ld", p.ival); return true;
    }
    if (p.tag == APRD_BOOL)
    {
        if (!m1_bool_type(t)) {
 return false; }
        fprintf(g.out, "%s", p.bval ? (char*)"true" : (char*)"false"); return true;
    }
    if (p.tag == APRD_FLOAT)
    {
        if (!m1_float_type(t)) {
 return false; }
        fprintf(g.out, "%s", g.float_text(p.fval)); return true;
    }
    if (p.tag == APRD_NULL)
    {
        if (!m1_pointer_repr_type(t)) {
 return false; }
        fprintf(g.out, "null"); return true;
    }
    if (p.tag == APRD_UNIT)
    {
        if (!m1_unit_type(t)) {
 return false; }
        fprintf(g.out, "zeroinitializer"); return true;
    }
    if (p.tag == APRD_STRING || p.tag == APRD_BYTES)
    {
        AirTyp* byte_type = m1_pointee_type(t);
        if (!m1_pointer_type(t) || byte_type == null || (byte_type.tag != ATYP_U8 && byte_type.tag != ATYP_I8)) {
 return false; }
        char* bytes = p.tag == APRD_STRING ? p.name : p.bytes;
        int ix = g.string_index(bytes, p.bytes_len, true);
        if (ix < 0) {
 return false; }
        M1String* s = &g.strings[ix];
        int count = (int)(s.len + (usz)1);
        fprintf(g.out, "getelementptr inbounds ([%d x i8], ptr @%s, i64 0, i64 0)", count, s.name);
        return true;
    }
    if (p.tag == APRD_VAR && m1_pointer_type(t))
    {
        AirDecl* global = g.find_global(p.name);
        if (global == null || !m1_value_type_compatible(m1_pointee_type(t), global.ret_ty, 0)) {
 return false; }
        fprintf(g.out, "%s", g.global_symbol(global)); return true;
    }
    if (p.tag == APRD_ARRAY || p.tag == APRD_TUPLE)
    {
        bool array = p.tag == APRD_ARRAY;
        usz count = array ? (t.tag == ATYP_ARRAY ? (usz)t.ival : 0) : (t.tag == ATYP_TUPLE ? t.arg_count : 0);
        if ((array && (t.tag != ATYP_ARRAY || t.arg_count != 1 || t.ival != (long)p.sub_count)) ||
            (!array && (t.tag != ATYP_TUPLE || t.arg_count != p.sub_count)) || p.sub_count != count) {
 return false; }
        fprintf(g.out, "%s", array ? (char*)"[ " : (char*)"{ ");
        for (usz i = 0; i < count; i++)
        {
            if (i > 0) { fprintf(g.out, ", "); }
            AirTyp* et = array ? t.args[0] : t.args[i];
            char* etext = g.llvm_type_text(et);
            if (etext == null) {
 return false; }
            fprintf(g.out, "%s ", etext);
            if (!g.emit_constant(p.subs[i], et, depth + 1)) {
 return false; }
        }
        fprintf(g.out, "%s", array ? (char*)" ]" : (char*)" }");
        return true;
    }
    if (p.tag == APRD_RECORD && t.tag == ATYP_NOMINAL)
    {
        usz marker = 0;
        AirDecl* data = m1_record_producer_decl(p, g.decls, g.decl_count, &marker);
        usz fcount = m1_record_field_count(data);
        if (data == null || (data.tag == ADECL_CODATA && !m1_record_codata_decl(data)) || fcount != p.rec_init_count - marker || p.rec_init_count > 64) {
 return false; }
        fprintf(g.out, "{ ");
        for (usz i = 0; i < fcount; i++)
        {
            AirTyp* fty = m1_record_field_ty(data, i); AirFieldInit* init = p.rec_inits[i + marker];
            if (i > 0) { fprintf(g.out, ", "); }
            if (fty == null || init == null || !same(m1_record_field_name(data, i), init.name)) {
 return false; }
            char* ft = g.llvm_type_text(fty);
            if (ft == null) {
 return false; }
            fprintf(g.out, "%s ", ft);
            if (!g.emit_constant(init.value, fty, depth + 1)) {
 return false; }
        }
        fprintf(g.out, " }"); return true;
    }
 return false;
}
fn bool M1Gen.record_global_cells(M1Gen* g, AirTyp* t, AirPrd* init, char* allocation, long base_offset, int depth)
{
    if (t == null || depth >= 16) {
 return false; }
    if (m1_pointer_type(t))
    {
        if (init == null || init.tag == APRD_NULL) { return g.cell_set_at(allocation, base_offset, null, true); }
        if (init.tag == APRD_STRING || init.tag == APRD_BYTES)
        {
            char* bytes = init.tag == APRD_STRING ? init.name : init.bytes;
            int ix = g.string_index(bytes, init.bytes_len, true);
            return ix >= 0 && g.cell_set_at(allocation, base_offset, g.strings[ix].symbol, false);
        }
        if (init.tag == APRD_VAR)
        {
            AirDecl* target = g.find_global(init.name);
            char* target_pointer = target == null ? null : g.global_pointer(target);
            return target_pointer != null && g.cell_set_at(allocation, base_offset, target_pointer, false);
        }
 return false;
    }
    usz count = 0; bool is_tuple = false; bool is_array = false; AirDecl* data = null;
    if (t.tag == ATYP_ARRAY) { if (t.arg_count != 1 || t.ival < 0 || t.ival > 1024) {
 return false; } count = (usz)t.ival; is_array = true; }
    else if (t.tag == ATYP_TUPLE) { if (t.arg_count > 64) {
 return false; } count = t.arg_count; is_tuple = true; }
    else if (t.tag == ATYP_NOMINAL)
    {
        data = m1_find_record_decl(g.decls, g.decl_count, t.name);
        if (data == null || (data.tag == ADECL_CODATA && !m1_record_codata_decl(data)) || (data.tag == ADECL_DATA && (data.ctor_count != 1 || data.ctors[0] == null))) {
 return false; }
        count = m1_record_field_count(data);
        if (count > 64) {
 return false; }
    }
    else { return true; }
    long stride = is_array ? m1_align_up(g.type_size(t.args[0], depth + 1), g.type_alignment(t.args[0], depth + 1)) : 0;
    for (usz i = 0; i < count; i++)
    {
        AirTyp* child_type = is_array ? t.args[0] : (is_tuple ? t.args[i] : m1_record_field_ty(data, i));
        AirPrd* child_init = null; long child_offset = 0;
        if (is_array)
        {
            child_offset = (long)i * stride;
            if (init != null)
            {
                if (init.tag != APRD_ARRAY || i >= init.sub_count) {
 return false; }
                child_init = init.subs[i];
            }
        }
        else if (is_tuple)
        {
            child_offset = g.field_offset(t, (long)i);
            if (init != null)
            {
                if (init.tag != APRD_TUPLE || i >= init.sub_count) {
 return false; }
                child_init = init.subs[i];
            }
        }
        else
        {
            child_offset = g.field_offset(t, (long)i);
            if (init != null)
            {
                if (init.tag != APRD_RECORD || i >= init.rec_init_count || !same(init.rec_inits[i].name, data.ctors[0].fields[i].name)) {
 return false; }
                child_init = init.rec_inits[i].value;
            }
        }
        if (child_offset < 0 || !g.record_global_cells(child_type, child_init, allocation, base_offset + child_offset, depth + 1)) {
 return false; }
    }
    return true;
}
fn bool M1Gen.emit_globals(M1Gen* g)
{
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d == null || d.tag != ADECL_GLOBAL) { continue; }
        char* symbol = g.global_symbol(d); char* ty = g.llvm_type_text(d.ret_ty);
        int align = g.global_alignment(d);
        if (symbol == null || ty == null || align <= 0) {
 return false; }
        fprintf(g.out, "%s = ", symbol);
        if (d.is_extern)
        {
            fprintf(g.out, "external %s %s, align %d\n", d.g_mut ? (char*)"global" : (char*)"constant", ty, align);
            continue;
        }
        fprintf(g.out, "%s %s ", d.g_mut ? (char*)"global" : (char*)"constant", ty);
        if (d.g_init == null) { fprintf(g.out, "zeroinitializer"); }
        else if (!g.emit_constant(d.g_init, d.ret_ty, 0))
        {
            g.note_failure(d.g_init.source_line, d.g_init.source_col, (char*)"global initializer is not a supported typed constant"); return false;
        }
        char* global_address = g.global_pointer(d);
        if (global_address == null || !g.record_global_cells(d.ret_ty, d.g_init, global_address, 0, 0))
        {
            g.note_failure(d.source_line, d.source_col, (char*)"global pointer initializer lacks supported provenance"); return false;
        }
        fprintf(g.out, ", align %d\n", align);
    }
    fprintf(g.out, "\n");
    return true;
}
fn bool M1Gen.emit_string_constants(M1Gen* g)
{
    for (int i = 0; i < g.string_count; i++)
    {
        M1String* s = &g.strings[i];
        int total = (int)(s.len + (s.terminate ? (usz)1 : (usz)0));
        fprintf(g.out, "@%s = private unnamed_addr constant [%d x i8] c\"", s.name, total);
        for (usz j = 0; j < s.len; j++)
        {
            int byte = ((int)s.data[j]) & 255;
            if (byte >= 32 && byte < 127 && byte != '"' && byte != '\\\\') { fprintf(g.out, "%c", byte); }
            else { fprintf(g.out, "\\%02X", byte); }
        }
        if (s.terminate) { fprintf(g.out, "\\00"); }
        fprintf(g.out, "\", align 1\n");
    }
    return true;
}
fn bool M1Gen.emit_data_types(M1Gen* g)
{
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d == null || (d.tag != ADECL_DATA && !(d.tag == ADECL_CODATA && m1_record_codata_decl(d)))) { continue; }
        bool duplicate = false;
        for (usz j = 0; j < i; j++)
        {
            AirDecl* prior = g.decls[j];
            if (prior != null && (prior.tag == ADECL_DATA || prior.tag == ADECL_CODATA) && same(prior.name, d.name)) { duplicate = true; break; }
        }
        if (duplicate) { continue; }
        AirTyp nominal; nominal.tag = ATYP_NOMINAL; nominal.name = d.name; nominal.arg_count = 0;
        if (!m1_backend_type(&nominal, g.decls, g.decl_count, 0)) {
 return false; }
        if (m1_nullary_enum_decl(d))
        {
            fprintf(g.out, "%%\"%s\" = type { i32 }\n", d.name);
            continue;
        }
        if (m1_tagged_sum_decl(d))
        {
            int align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
            if (!g.tagged_sum_layout(d, 0, &align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size)) {
 return false; }
            char* storage_type = m1_llvm_bits(slot_bits);
            if (storage_type == null) {
 return false; }
            fprintf(g.out, "%%\"%s\" = type { i32, [%ld x %s] }\n", d.name, slots, storage_type);
            continue;
        }
        if (m1_record_field_count(d) > 64) {
 return false; }
        fprintf(g.out, "%%\"%s\" = type { ", d.name);
        for (usz j = 0; j < m1_record_field_count(d); j++)
        {
            if (j != 0) { fprintf(g.out, ", "); }
            char* field_type = g.llvm_type_text(m1_record_field_ty(d, j));
            if (g.failed || field_type == null) {
 return false; }
            fprintf(g.out, "%s", field_type);
        }
        fprintf(g.out, " }\n");
    }
    return true;
}






fn bool M1Gen.emit_extern_declarations(M1Gen* g)
{
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d == null || d.tag != ADECL_DECLARE) { continue; }
        if (same(m1_link_name(d), "llvm.trap") || same(m1_link_name(d), "llvm.assume") || same(m1_link_name(d), "llvm.stacksave") || same(m1_link_name(d), "llvm.stackrestore")) {
 return false; }
        if (!m1_function_signature(d) || !m1_safe_name(m1_link_name(d))) { continue; }
        bool shadowed_by_def = false;
        for (usz j = 0; j < g.decl_count; j++)
        {
            AirDecl* def = g.decls[j];
            if (def != null && def.tag == ADECL_DEF && same(def.name, d.name)) { shadowed_by_def = true; break; }
        }
        if (shadowed_by_def) { continue; }
        bool duplicate = false;
        for (usz j = 0; j < i; j++)
        {
            AirDecl* prior = g.decls[j];
            if (prior == null || prior.tag != ADECL_DECLARE || !m1_function_signature(prior) || !m1_safe_name(m1_link_name(prior))) { continue; }
            bool prior_shadowed = false;
            for (usz k = 0; k < g.decl_count; k++)
            {
                AirDecl* def = g.decls[k];
                if (def != null && def.tag == ADECL_DEF && same(def.name, prior.name)) { prior_shadowed = true; break; }
            }
            if (prior_shadowed || !same(m1_link_name(prior), m1_link_name(d))) { continue; }
            if (!m1_same_abi(prior, d)) {
 return false; }
            duplicate = true;
            break;
        }
        if (duplicate) { continue; }
        for (usz j = 0; j < g.decl_count; j++)
        {
            AirDecl* def = g.decls[j];
            if (def != null && def.tag == ADECL_DEF && !same(def.name, d.name) && same(def.name, m1_link_name(d))) {
 return false; }
        }
        if (!m1_backend_type(d.ret_ty, g.decls, g.decl_count, 0) ||            (d.ret_ty != null && !m1_scalar_type(d.ret_ty) && !m1_unit_type(d.ret_ty) && g.external_aggregate_problem(d.ret_ty) != null)) { continue; }
        bool params_ok = true;
        for (usz j = 0; j < d.param_count; j++)
        {
            if (!m1_backend_type(d.params[j].ty, g.decls, g.decl_count, 0) ||
                (!m1_scalar_type(d.params[j].ty) && g.external_aggregate_problem(d.params[j].ty) != null)) { params_ok = false; }
        }
        if (!params_ok) { continue; }
        bool sret_result = g.external_aggregate_indirect(d.ret_ty);
        char* return_ir = sret_result ? (char*)"void" : g.llvm_abi_return_text(d.ret_ty);
        if (return_ir == null) {
 return false; }
        int ext_cc = m1_decl_callconv(d);
        fprintf(g.out, "declare %s%s @%s(", ext_cc == 1 ? "fastcc " : "", return_ir, m1_link_name(d));
        bool have_param = false;
        if (sret_result)
        {
            char* aggregate_type = g.llvm_type_text(d.ret_ty);
            int align = g.type_alignment(d.ret_ty, 0);
            if (aggregate_type == null || align <= 0) {
 return false; }
            fprintf(g.out, "ptr sret(%s) align %d", aggregate_type, align);
            have_param = true;
        }
        for (usz j = 0; j < d.param_count; j++)
        {
            AirTyp* parameter = d.params[j].ty;
            if (have_param) { fprintf(g.out, ", "); }
            if (g.external_aggregate_indirect(parameter))
            {
                char* aggregate_type = g.llvm_type_text(parameter);
                int align = g.type_alignment(parameter, 0);
                if (aggregate_type == null || align <= 0) {
 return false; }
                fprintf(g.out, "ptr byval(%s) align %d", aggregate_type, align);
            }
            else { fprintf(g.out, "%s", g.llvm_abi_argument_text(parameter)); }
            have_param = true;
        }
        fprintf(g.out, ")\n");
    }
    return true;
}
fn bool M1Gen.bind_aggregate_pattern(M1Gen* g, AirPat* pat, char* value, AirTyp* value_type, int depth)
{
    if (pat == null || value == null || value_type == null || depth >= 16 || !m1_value_type(value_type, 0)) {
 return false; }
    bool tuple_pattern = pat.tag == APAT_TUPLE && value_type.tag == ATYP_TUPLE;
    bool array_pattern = pat.tag == APAT_ARRAY && value_type.tag == ATYP_ARRAY && value_type.arg_count == 1;
    if (!tuple_pattern && !array_pattern) {
 return false; }
    usz count = tuple_pattern ? value_type.arg_count : (usz)value_type.ival;
    if (count > 64 || pat.sub_count > count + 1) {
 return false; }
    usz matched = pat.sub_count;
    bool has_rest = matched > 0 && pat.sub[matched - 1] != null && pat.sub[matched - 1].tag == APAT_REST;
    if (has_rest) { matched--; }
    if ((!has_rest && matched != count) || (has_rest && matched > count)) {
 return false; }
    char* aggregate_ir = g.llvm_type_text(value_type);
    if (g.failed || aggregate_ir == null) {
 return false; }
    for (usz i = 0; i < matched; i++)
    {
        AirTyp* element_type = tuple_pattern ? value_type.args[i] : value_type.args[0];
        AirPat* element_pattern = pat.sub[i];
        if (element_type == null || element_pattern == null) {
 return false; }
        char* element_ir = g.llvm_type_text(element_type);
        char* extracted = g.tmp();
        if (g.failed || element_ir == null || extracted == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %d\n", extracted, aggregate_ir, value, (int)i);
        if (element_pattern.tag == APAT_TUPLE || element_pattern.tag == APAT_ARRAY)
        {
            if (!g.bind_aggregate_pattern(element_pattern, extracted, element_type, depth + 1)) {
 return false; }
        }
        else if (element_pattern.tag == APAT_BIND)
        {
            if (element_pattern.name != null && !same(element_pattern.name, "_") && !g.bind_typed(element_pattern.name, extracted, m1_bool_type(element_type), m1_pointer_type(element_type), element_type)) {
 return false; }
        }
        else if (element_pattern.tag != APAT_WILD) {
 return false; }
    }
    return true;
}
fn AirPat* m1_match_base_pattern(AirPat* pat)
{
    if (pat == null || pat.tag != APAT_AS) { return pat; }
    if (pat.sub_count != 1 || pat.sub[0] == null) { return null; }
    return pat.sub[0];
}
fn bool m1_sum_pattern_has_literal(AirPat* p, int depth)
{
    if (p == null || depth >= 16) {
 return false; }
    if (p.tag == APAT_INT || p.tag == APAT_FLOAT || p.tag == APAT_BOOL || p.tag == APAT_CHAR) { return true; }
    for (usz i = 0; i < p.sub_count; i++) { if (m1_sum_pattern_has_literal(p.sub[i], depth + 1)) { return true; } }
 return false;
}

// Named-field record destructuring for single-constructor product records.
// The AIR record pattern carries field names only; each name must be a field
// of the record's sole constructor, may appear once, and binds the same name.
fn bool M1Gen.bind_record_pattern(M1Gen* g, AirPat* pat, char* value, AirTyp* record_type, int line, int col)
{
    if (pat == null || pat.tag != APAT_RECORD || value == null || record_type == null || record_type.tag != ATYP_NOMINAL) {
 return false; }
    AirDecl* data = m1_find_record_decl(g.decls, g.decl_count, record_type.name);
    if (data == null || data.typaram_count != 0 || data.attr_count != 0 || (data.tag == ADECL_DATA && (data.ctor_count != 1 || data.ctors[0] == null)) || (data.tag == ADECL_CODATA && !m1_record_codata_decl(data)) || m1_record_field_count(data) > 64)
    { g.note_failure(line, col, (char*)"record patterns currently support only plain single-constructor product records (and struct codata)"); return false; }
    if (!m1_backend_type(record_type, g.decls, g.decl_count, 0)) {
 return false; }
    char* aggregate_ir = g.llvm_type_text(record_type);
    if (g.failed || aggregate_ir == null) {
 return false; }
    for (usz i = 0; i < pat.field_count; i++)
    {
        AirFieldInit* field_pat = pat.fields[i];
        if (field_pat == null || field_pat.name == null || field_pat.name[0] == 0 || same(field_pat.name, "_"))
        { g.note_failure(line, col, (char*)"record pattern entries must name record fields"); return false; }
        for (usz j = 0; j < i; j++)
        {
            if (pat.fields[j] != null && pat.fields[j].name != null && same(pat.fields[j].name, field_pat.name))
            { g.note_failure(line, col, (char*)"duplicate field name in record pattern"); return false; }
        }
        long field_index = -1;
        for (usz j = 0; j < m1_record_field_count(data); j++)
        {
            if (m1_record_field_name(data, j) != null && same(m1_record_field_name(data, j), field_pat.name)) { field_index = (long)j; break; }
        }
        if (field_index < 0)
        { g.note_failure(line, col, (char*)"record pattern names a field absent from the record"); return false; }
        AirTyp* field_type = m1_record_field_ty(data, (usz)field_index);
        if (field_type == null) {
 return false; }
        char* field_ir = g.llvm_type_text(field_type);
        char* extracted = g.tmp();
        if (g.failed || field_ir == null || extracted == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", extracted, aggregate_ir, value, field_index);
        if (!g.bind_typed(field_pat.name, extracted, m1_bool_type(field_type), m1_pointer_repr_type(field_type), field_type)) {
 return false; }
    }
    return true;
}
fn bool M1Gen.match_nullary_enum(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* enum_type, AirDecl* enum_decl)
{
    if (c == null || enum_type == null || enum_decl == null || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    char* aggregate_type = g.llvm_type_text(enum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    char*[64] labels;
    int[64] tags;
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"nullary enum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed enum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(enum_decl, base.name);
            if (base.sub_count != 0 || tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"enum match supports only nullary constructors declared by its scrutinee type"); return false; }
            for (usz j = 0; j < i; j++)
            {
                AirPat* prior = m1_match_base_pattern(c.branches[j].pat);
                if (prior != null && prior.tag == APAT_VARIANT && tags[j] == tag)
                { g.note_failure(c.source_line, c.source_col, (char*)"duplicate constructor arm in enum match"); return false; }
            }
            tags[i] = tag;
            labels[i] = g.label((char*)"enum.case.");
            if (labels[i] == null) {
 return false; }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"enum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"enum.default.");
            if (labels[i] == null) {
 return false; }
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for nullary enum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"nullary enum match requires a final wildcard/default arm"); return false; }
    fprintf(g.out, "  switch i32 %s, label %%%s [", tag_value, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        fprintf(g.out, " i32 %d, label %%%s", tags[i], labels[i]);
    }
    fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        usz saved = g.env_count;
        AirPat* pat = c.branches[i].pat;
        if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
            !g.bind_typed(pat.name, aggregate_value, false, false, enum_type)) {
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(c.branches[i].body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) {
 return false; }
        g.env_count = saved;
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) {
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, enum_type)) {
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, enum_type)) {
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
// Emits payload loads and bindings for a matched constructor arm whose payload
// region lives in `scratch` (the spilled scrutinee aggregate). Handles named
// bindings, wildcards, and nested tuple/array destructuring, then the optional
// `as` alias for the whole scrutinee. Literal fields are tested beforehand by
// the caller (ordered matching only); in switch mode they are rejected here.
fn bool M1Gen.sum_arm_bind_payload(M1Gen* g, AirPat* pat, AirPat* base, AirDecl* sum_decl, int tag, char* scratch, long payload_offset, char* aggregate_value, AirTyp* sum_type, bool skip_literals, int line, int col)
{
    AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
    if (ctor == null || ctor.field_count != base.sub_count) {
 return false; }
    for (usz j = 0; j < ctor.field_count; j++)
    {
        AirPat* sub = base.sub[j];
        AirTyp* field_type = ctor.fields[j] != null ? ctor.fields[j].ty : null;
        if (sub == null || field_type == null) {
 return false; }
        bool is_literal = sub.tag == APAT_INT || sub.tag == APAT_FLOAT || sub.tag == APAT_BOOL || sub.tag == APAT_CHAR;
        if (is_literal && skip_literals) { continue; }
        bool is_bind = sub.tag == APAT_BIND && sub.name != null && !same(sub.name, "_");
        bool is_aggregate = sub.tag == APAT_TUPLE || sub.tag == APAT_ARRAY;
        if (sub.tag != APAT_WILD && !is_bind && !is_aggregate)
        {
            if (is_literal)
            { g.note_failure(line, col, (char*)"literal payload patterns require ordered constructor matching"); }
            else { g.note_failure(line, col, (char*)"unsupported payload sub-pattern; use bindings, wildcards, tuples, or arrays"); }
 return false;
        }
        if (is_aggregate &&
            ((sub.tag == APAT_TUPLE && field_type.tag != ATYP_TUPLE) || (sub.tag == APAT_ARRAY && field_type.tag != ATYP_ARRAY)))
        { g.note_failure(line, col, (char*)"payload aggregate pattern kind does not match the declared field type"); return false; }
        if (sub.tag == APAT_WILD) { continue; }
        char* field_ir = g.llvm_type_text(field_type);
        char* address = g.tmp(); char* loaded = g.tmp();
        long local_offset = 0;
        int field_align = g.type_alignment(field_type, 0);
        if (field_ir == null || address == null || loaded == null || field_align <= 0 ||
            !g.tagged_sum_field_offset(sum_decl, (usz)tag, j, &local_offset) || local_offset < 0 || local_offset > 1048576 - payload_offset)
        { g.note_failure(line, col, (char*)"unsupported constructor payload layout"); return false; }
        fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", address, scratch, payload_offset + local_offset);
        fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", loaded, field_ir, address, field_align);
        if (is_aggregate)
        {
            if (!g.bind_aggregate_pattern(sub, loaded, field_type, 0))
            { g.note_failure(line, col, (char*)"unsupported nested payload pattern shape"); return false; }
            continue;
        }
        if (!g.bind_typed(sub.name, loaded, m1_bool_type(field_type), false, field_type)) {
 return false; }
    }
    if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
        !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) {
 return false; }
    return true;
}
fn bool M1Gen.match_tagged_sum(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* sum_type, AirDecl* sum_decl)
{
    if (c == null || sum_type == null || sum_decl == null || !m1_tagged_sum_decl(sum_decl) || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
    if (!g.tagged_sum_layout(sum_decl, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size))
    { g.note_failure(c.source_line, c.source_col, (char*)"unsupported or malformed tagged-sum layout"); return false; }
    char* aggregate_type = g.llvm_type_text(sum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    char*[64] labels;
    int[64] tags;
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed tagged-sum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(sum_decl, base.name);
            if (tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor arm is not declared by the scrutinee type"); return false; }
            if (base.sub_count != sum_decl.ctors[(usz)tag].field_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor payload pattern count does not match its declaration"); return false; }
            for (usz j = 0; j < i; j++)
            {
                AirPat* prior = m1_match_base_pattern(c.branches[j].pat);
                if (prior != null && prior.tag == APAT_VARIANT && tags[j] == tag)
                { g.note_failure(c.source_line, c.source_col, (char*)"duplicate constructor arm in tagged-sum match"); return false; }
            }
            tags[i] = tag;
            labels[i] = g.label((char*)"sum.case.");
            if (labels[i] == null) {
 return false; }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"sum.default.");
            if (labels[i] == null) {
 return false; }
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for tagged-sum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires a final wildcard/default arm"); return false; }
    fprintf(g.out, "  switch i32 %s, label %%%s [", tag_value, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        fprintf(g.out, " i32 %d, label %%%s", tags[i], labels[i]);
    }
        fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        usz saved = g.env_count;
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base = m1_match_base_pattern(pat);
        if (base == null || base.tag != APAT_VARIANT) { g.env_count = saved;
 return false; }
        int tag = g.enum_constructor_index(sum_decl, base.name);
        if (tag < 0) { g.env_count = saved;
 return false; }
        AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
        if (ctor == null || ctor.field_count != base.sub_count) { g.env_count = saved;
 return false; }
        char* scratch = null;
        if (ctor.field_count > 0)
        {
            scratch = g.tmp();
            if (scratch == null) { g.env_count = saved;
 return false; }
            fprintf(g.out, "  %s = alloca %s, align %d\n", scratch, aggregate_type, sum_align);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", aggregate_type, aggregate_value, scratch, sum_align);
        }
        if (ctor.field_count > 0 && !g.sum_arm_bind_payload(pat, base, sum_decl, tag, scratch, payload_offset, aggregate_value, sum_type, false, c.source_line, c.source_col))
        { g.env_count = saved;
 return false; }
        if (ctor.field_count == 0 && pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
            !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) { g.env_count = saved;
 return false; }
        g.env_count = saved;
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) { g.env_count = saved;
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
// Recursively validates that a nested tuple/array payload sub-pattern contains
// only destructuring forms; literals and other tags are rejected with distinct
// diagnostics by the caller's arm-level validation.
fn bool m1_sum_nested_pattern_ok(AirPat* sub, int depth)
{
    if (sub == null || depth >= 16) {
 return false; }
    if (sub.tag == APAT_BIND || sub.tag == APAT_WILD) { return true; }
    if (sub.tag != APAT_TUPLE && sub.tag != APAT_ARRAY) {
 return false; }
    for (usz i = 0; i < sub.sub_count; i++) { if (!m1_sum_nested_pattern_ok(sub.sub[i], depth + 1)) {
 return false; } }
    return true;
}
// Ordered tagged-sum matching: constructor arms are tested sequentially in
// source order — first the discriminant tag, then each payload literal field —
// and a mismatch falls through to the next arm. This supports bindings,
// wildcards, nested tuple/array destructuring, and int/float/bool/char literal
// payload fields. Guards are rejected; a final wildcard/binding default arm is
// required so every discriminant/literal failure chain is total.
fn bool M1Gen.match_tagged_sum_ordered(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* sum_type, AirDecl* sum_decl)
{
    if (c == null || sum_type == null || sum_decl == null || !m1_tagged_sum_decl(sum_decl) || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
    if (!g.tagged_sum_layout(sum_decl, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size))
    { g.note_failure(c.source_line, c.source_col, (char*)"unsupported or malformed tagged-sum layout"); return false; }
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed tagged-sum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(sum_decl, base.name);
            if (tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor arm is not declared by the scrutinee type"); return false; }
            AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
            if (base.sub_count != ctor.field_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor payload pattern count does not match its declaration"); return false; }
            for (usz j = 0; j < ctor.field_count; j++)
            {
                AirPat* sub = base.sub[j];
                AirTyp* field_type = ctor.fields[j] != null ? ctor.fields[j].ty : null;
                if (sub == null || field_type == null) {
 return false; }
                bool bool_field = m1_bool_type(field_type);
                bool float_field = m1_float_type(field_type);
                bool char_field = field_type.tag == ATYP_CHAR;
                if (sub.tag == APAT_BIND || sub.tag == APAT_WILD) { continue; }
                if (sub.tag == APAT_INT || sub.tag == APAT_FLOAT || sub.tag == APAT_BOOL || sub.tag == APAT_CHAR)
                {
                    if (!m1_valid_match_literal(field_type, sub, bool_field, float_field, char_field, m1_int_bits(field_type), m1_unsigned(field_type)))
                    { g.note_failure(c.source_line, c.source_col, (char*)"invalid literal pattern for payload field type"); return false; }
                    continue;
                }
                if ((sub.tag == APAT_TUPLE && field_type.tag == ATYP_TUPLE) || (sub.tag == APAT_ARRAY && field_type.tag == ATYP_ARRAY))
                {
                    if (!m1_sum_nested_pattern_ok(sub, 0))
                    { g.note_failure(c.source_line, c.source_col, (char*)"nested payload patterns support only bindings, wildcards, tuples, and arrays"); return false; }
                    continue;
                }
                g.note_failure(c.source_line, c.source_col, (char*)"payload aggregate pattern kind does not match the declared field type");
 return false;
            }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for tagged-sum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"ordered tagged-sum match requires a final wildcard/default arm"); return false; }
    char* aggregate_type = g.llvm_type_text(sum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base = m1_match_base_pattern(pat);
        int tag = g.enum_constructor_index(sum_decl, base.name);
        AirCtorDecl* ctor = tag < 0 ? null : sum_decl.ctors[(usz)tag];
        if (base == null || base.tag != APAT_VARIANT || ctor == null) {
 return false; }
        char* tag_test = g.tmp();
        char* case_label = g.label((char*)"sum.ord.case.");
        char* fail_label = g.label((char*)"sum.ord.next.");
        if (tag_test == null || case_label == null || fail_label == null) {
 return false; }
        fprintf(g.out, "  %s = icmp eq i32 %s, %d\n", tag_test, tag_value, tag);
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", tag_test, case_label, fail_label);
        g.terminated = true;
        g.begin_block(case_label);
        g.terminated = false;
        // Literal fields are tested before bindings so a mismatch cannot leak a
        // partial environment into the next arm.
        bool needs_scratch = false;
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirPat* sub = base.sub[j];
            if (sub != null && !((sub.tag == APAT_BIND && (sub.name == null || same(sub.name, "_"))) || sub.tag == APAT_WILD)) { needs_scratch = true; }
        }
        char* scratch = null;
        if (needs_scratch)
        {
            scratch = g.tmp();
            if (scratch == null) {
 return false; }
            fprintf(g.out, "  %s = alloca %s, align %d\n", scratch, aggregate_type, sum_align);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", aggregate_type, aggregate_value, scratch, sum_align);
        }
        usz saved = g.env_count;
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirPat* sub = base.sub[j];
            AirTyp* field_type = ctor.fields[j].ty;
            if (sub == null || field_type == null) {
 return false; }
            if (sub.tag != APAT_INT && sub.tag != APAT_FLOAT && sub.tag != APAT_BOOL && sub.tag != APAT_CHAR) { continue; }
            bool bool_field = m1_bool_type(field_type);
            bool float_field = m1_float_type(field_type);
            bool char_field = field_type.tag == ATYP_CHAR;
            char* field_ir = g.llvm_type_text(field_type);
            char* address = g.tmp(); char* loaded = g.tmp();
            long local_offset = 0;
            int field_align = g.type_alignment(field_type, 0);
            if (field_ir == null || address == null || loaded == null || field_align <= 0 ||
                !g.tagged_sum_field_offset(sum_decl, (usz)tag, j, &local_offset) || local_offset < 0 || local_offset > 1048576 - payload_offset)
            { g.env_count = saved;
 return false; }
            fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", address, scratch, payload_offset + local_offset);
            fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", loaded, field_ir, address, field_align);
            char* field_test = g.match_literal_test(field_type, sub, loaded, bool_field, float_field, char_field, m1_int_bits(field_type));
            char* step_label = g.label((char*)"sum.ord.step.");
            if (field_test == null || step_label == null) { g.env_count = saved;
 return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", field_test, step_label, fail_label);
            g.terminated = true;
            g.begin_block(step_label);
            g.terminated = false;
        }
        if (needs_scratch)
        {
            if (!g.sum_arm_bind_payload(pat, base, sum_decl, tag, scratch, payload_offset, aggregate_value, sum_type, true, c.source_line, c.source_col))
            { g.env_count = saved;
 return false; }
        }
        else if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
                 !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) { g.env_count = saved;
 return false; }
        g.env_count = saved;
        g.begin_block(fail_label);
        g.terminated = false;
    }
    // Final default arm runs where every ordered chain ends.
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) { g.env_count = saved;
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
fn bool m1_valid_match_literal(AirTyp* scrutinee_type, AirPat* pat, bool bool_match, bool float_match, bool char_match, int bits, bool default_unsigned)
{
    if (pat == null) {
 return false; }
    if (bool_match) { return pat.tag == APAT_BOOL && (pat.ival == 0 || pat.ival == 1); }
    if (float_match)
    {
        return pat.tag == APAT_FLOAT && (pat.ty == null || !m1_known_type(pat.ty) || pat.ty.tag == scrutinee_type.tag);
    }
    if (char_match) { return pat.tag == APAT_CHAR && m1_unicode_scalar(pat.ival); }
    if (pat.tag != APAT_INT || !m1_integer_type(pat.ty)) {
 return false; }
    return (!m1_known_type(pat.ty) || m1_int_bits(pat.ty) == bits) && m1_int_fits(pat.ival, bits, scrutinee_type != null ? m1_unsigned(scrutinee_type) : default_unsigned);
}
fn char* M1Gen.match_literal_test(M1Gen* g, AirTyp* scrutinee_type, AirPat* pat, char* scrutinee, bool bool_match, bool float_match, bool char_match, int bits)
{
    if (pat == null || scrutinee == null) { return null; }
    char* test = g.tmp();
    if (test == null) { return null; }
    if (bool_match && pat.tag == APAT_BOOL)
    {
        fprintf(g.out, "  %s = icmp eq i1 %s, %s\n", test, scrutinee, pat.ival != 0 ? (char*)"true" : (char*)"false");
    }
    else if (float_match && pat.tag == APAT_FLOAT)
    {
        char* literal = g.float_text(pat.fval);
        if (literal == null) { return null; }
        fprintf(g.out, "  %s = fcmp oeq %s %s, %s\n", test, m1_llvm_float(scrutinee_type), scrutinee, literal);
    }
    else if (char_match && pat.tag == APAT_CHAR)
    {
        fprintf(g.out, "  %s = icmp eq i32 %s, %ld\n", test, scrutinee, pat.ival);
    }
    else if (!bool_match && !float_match && !char_match && pat.tag == APAT_INT)
    {
        fprintf(g.out, "  %s = icmp eq %s %s, %ld\n", test, m1_llvm_bits(bits), scrutinee, pat.ival);
    }
    else { g.failed = true; return null; }
    return test;
}
fn bool M1Gen.match_guarded_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    bool bool_match = g.is_condition(c.prd);
    if (!bool_match && g.is_pointer_value(c.prd)) {
 return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool float_match = m1_float_type(scrutinee_type);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : ((float_match || char_match) ? 32 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits));
    if (!bool_match && !float_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) {
 return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null || switch_bits <= 0) {
 return false; }
    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null || (pat.tag == APAT_AS && (pat.name == null || pat.name[0] == 0))) {
 return false; }
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (fallback)
        {
            if ((base_pat.tag == APAT_BIND && branch.guard != null && (base_pat.name == null || same(base_pat.name, "_"))) ||
                (pat.tag == APAT_AS && branch.guard != null && same(pat.name, "_"))) {
 return false; }
        }
        else if (base_pat.tag == APAT_OR)
        {
            if (base_pat.sub_count != 1 || base_pat.sub[0] == null || base_pat.or_alt == null ||
                !m1_valid_match_literal(scrutinee_type, base_pat.sub[0], bool_match, float_match, char_match, switch_bits, g.default_unsigned) ||
                !m1_valid_match_literal(scrutinee_type, base_pat.or_alt, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) {
 return false; }
        }
        else if (!m1_valid_match_literal(scrutinee_type, base_pat, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) {
 return false; }
        if (fallback)
        {
            if (branch.guard == null)
            {
                if (i + 1 != c.branch_count) {
 return false; }
                final_default = (int)i;
            }
        }
    }
    if (final_default != (int)c.branch_count - 1) {
 return false; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.guard.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.guard.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) {
 return false; }
        if (!fallback)
        {
            char* test = null;
            if (base_pat.tag == APAT_OR)
            {
                char* left_test = g.match_literal_test(scrutinee_type, base_pat.sub[0], scrutinee, bool_match, float_match, char_match, switch_bits);
                char* right_test = g.match_literal_test(scrutinee_type, base_pat.or_alt, scrutinee, bool_match, float_match, char_match, switch_bits);
                test = g.tmp();
                if (g.failed || left_test == null || right_test == null || test == null) {
 return false; }
                fprintf(g.out, "  %s = or i1 %s, %s\n", test, left_test, right_test);
            }
            else { test = g.match_literal_test(scrutinee_type, base_pat, scrutinee, bool_match, float_match, char_match, switch_bits); }
            if (g.failed || test == null) {
 return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", test, arm_label, next_label);
        }
        else
        {
            fprintf(g.out, "  br label %%%s\n", arm_label);
        }
        g.terminated = true;
        g.begin_block(arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (base_pat.tag == APAT_BIND && base_pat.name != null && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved;
 return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved;
 return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved;
 return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.guard.body.");
            if (body_label == null) { g.env_count = saved;
 return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            g.branch_enter();
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved;
 return false; }
            g.begin_block(body_label);
            g.terminated = false;
        }
        g.branch_leave();
        g.branch_enter();
        bool body_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        if (!body_ok || !g.terminated) {
 return false; }
        if (next_label != null)
        {
            g.begin_block(next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}
fn bool M1Gen.match_aggregate_guarded_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    AirTyp* aggregate_type = g.expr_type(c.prd);
    if (aggregate_type == null || (aggregate_type.tag != ATYP_TUPLE && aggregate_type.tag != ATYP_ARRAY) || !m1_value_type(aggregate_type, 0)) {
 return false; }
    char* aggregate_value = g.prd(c.prd);
    if (g.failed || aggregate_value == null) {
 return false; }
    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) {
 return false; }
        AirPat* base_pat = m1_match_base_pattern(branch.pat);
        if (base_pat == null) {
 return false; }
        bool aggregate_pat = base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY;
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (!aggregate_pat && !fallback) {
 return false; }
        if (branch.guard != null && !aggregate_pat && fallback && base_pat.tag == APAT_BIND && (base_pat.name == null || same(base_pat.name, "_"))) {
 return false; }
        if (branch.guard == null)
        {
            if (i + 1 != c.branch_count) {
 return false; }
            final_default = (int)i;
        }
    }
    if (final_default != (int)c.branch_count - 1) {
 return false; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.aggregate.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.aggregate.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) {
 return false; }
        fprintf(g.out, "  br label %%%s\n", arm_label);
        g.terminated = true;
        g.begin_block(arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (fallback)
        {
            if (base_pat.tag == APAT_BIND && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
        }
        else if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved;
 return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved;
 return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.aggregate.body.");
            if (body_label == null) { g.env_count = saved;
 return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            g.branch_enter();
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved;
 return false; }
            g.begin_block(body_label);
            g.terminated = false;
        }
        g.branch_leave();
        g.branch_enter();
        bool body_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        if (!body_ok || !g.terminated) {
 return false; }
        if (next_label != null)
        {
            g.begin_block(next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}
fn bool M1Gen.match_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (c == null || c.branch_count == 0 || c.branch_count > 64 || c.prd == null) {
 return false; }
    AirTyp* match_type = g.expr_type(c.prd);
    if (match_type != null && match_type.tag == ATYP_NOMINAL)
    {
        AirDecl* data = g.find_data(match_type.name);
        if (m1_nullary_enum_decl(data)) { return g.match_nullary_enum(c, ret_name, match_type, data); }
        if (m1_tagged_sum_decl(data))
        {
            bool ordered = false;
            for (usz i = 0; i < c.branch_count && !ordered; i++)
            {
                AirBranch* branch = c.branches[i];
                if (branch == null) { continue; }
                AirPat* base = m1_match_base_pattern(branch.pat);
                if (base == null || base.tag != APAT_VARIANT) { continue; }
                for (usz j = 0; j < base.sub_count && !ordered; j++)
                {
                    if (m1_sum_pattern_has_literal(base.sub[j], 0)) { ordered = true; }
                }
            }
            return ordered ? g.match_tagged_sum_ordered(c, ret_name, match_type, data) : g.match_tagged_sum(c, ret_name, match_type, data);
        }
    }
    // Record destructuring patterns are total for single-constructor product
    // records: they currently require exactly one arm.
    bool has_record_pat = false;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) { continue; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base != null && base.tag == APAT_RECORD) { has_record_pat = true; }
    }
    if (has_record_pat && c.branch_count != 1)
    { g.note_failure(c.source_line, c.source_col, (char*)"record pattern matches currently require a single destructuring arm"); return false; }
    if (c.branch_count > 1 && match_type != null && (match_type.tag == ATYP_TUPLE || match_type.tag == ATYP_ARRAY)) { return g.match_aggregate_guarded_cmd(c, ret_name); }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null) { continue; }
        AirPat* pat = branch.pat;
        bool aggregate_as = c.branch_count == 1 && pat != null && pat.tag == APAT_AS && pat.sub_count == 1 && pat.sub[0] != null && (pat.sub[0].tag == APAT_TUPLE || pat.sub[0].tag == APAT_ARRAY || pat.sub[0].tag == APAT_RECORD);
        if (branch.guard != null || (pat != null && (pat.tag == APAT_OR || (pat.tag == APAT_AS && !aggregate_as)))) { return g.match_guarded_cmd(c, ret_name); }
    }
    if (m1_float_type(g.expr_type(c.prd))) { return g.match_guarded_cmd(c, ret_name); }
    if (c.branch_count == 1)
    {
        AirBranch* branch = c.branches[0];
        if (branch == null || branch.guard != null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null) {
 return false; }
        if ((base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY) && c.prd.tag != APRD_UNIT)
        {
            AirTyp* aggregate_type = g.expr_type(c.prd);
            if (aggregate_type == null || !m1_value_type(aggregate_type, 0)) {
 return false; }
            char* aggregate_value = g.prd(c.prd);
            if (g.failed || aggregate_value == null) {
 return false; }
            usz saved = g.env_count;
            if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved;
 return false; }
            if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
            g.branch_enter();
            bool ok = g.command(branch.body, ret_name);
            g.branch_leave();
            g.env_count = saved;
            return ok;
        }
        if (base_pat.tag == APAT_RECORD && c.prd.tag != APRD_UNIT)
        {
            AirTyp* record_type = g.expr_type(c.prd);
            if (record_type == null || record_type.tag != ATYP_NOMINAL)
            { g.note_failure(c.source_line, c.source_col, (char*)"record patterns require a nominal product-record scrutinee"); return false; }
            char* aggregate_value = g.prd(c.prd);
            if (g.failed || aggregate_value == null) {
 return false; }
            usz saved = g.env_count;
            if (!g.bind_record_pattern(base_pat, aggregate_value, record_type, c.source_line, c.source_col)) { g.env_count = saved;
 return false; }
            if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, record_type)) { g.env_count = saved;
 return false; }
            g.branch_enter();
            bool ok = g.command(branch.body, ret_name);
            g.branch_leave();
            g.env_count = saved;
            return ok;
        }
        char* value = null;
        bool unit_match = false;
        bool bool_match = false;
        bool ptr_match = false;
        if (c.prd.tag == APRD_UNIT)
        {
            if (pat.tag != APAT_TUPLE || pat.sub_count != 0) {
 return false; }
            unit_match = true;
            value = (char*)"0";
        }
        else if (g.is_condition(c.prd))
        {
            bool_match = true;
            value = g.condition(c.prd);
            if (g.failed || value == null) {
 return false; }
        }
        else if (c.prd.tag == APRD_VAR)
        {
            value = g.lookup(c.prd.name);
            if (value == null || pat.tag == APAT_TUPLE) {
 return false; }
            ptr_match = g.lookup_ptr(c.prd.name);
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            ptr_match = g.is_pointer_value(c.prd);
            value = ptr_match ? g.pointer_value(c.prd) : g.prd(c.prd);
            if (g.failed || value == null) {
 return false; }
        }
        else {
 return false; }
        usz saved = g.env_count;
        if (pat.tag == APAT_BIND && !g.bind_typed(pat.name, value, bool_match, ptr_match, g.expr_type(c.prd))) {
 return false; }
        else if (pat.tag != APAT_BIND && pat.tag != APAT_WILD && !(unit_match && pat.tag == APAT_TUPLE)) {
 return false; }
        g.branch_enter();
        bool ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        return ok;
    }
    bool bool_match = g.is_condition(c.prd);
    if (!bool_match && g.is_pointer_value(c.prd)) {
 return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits);
    if (!bool_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) {
 return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null) {
 return false; }
    char*[64] labels;
    long[64] literals;
    int default_index = -1;
    usz literal_count = 0;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.guard != null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        bool int_case = !bool_match && !char_match && pat.tag == APAT_INT;
        bool char_case = char_match && pat.tag == APAT_CHAR;
        if (int_case || char_case || (bool_match && pat.tag == APAT_BOOL))
        {
            if (default_index >= 0) {
 return false; }
            if (int_case && (!m1_integer_type(pat.ty) || (m1_known_type(pat.ty) && m1_int_bits(pat.ty) != switch_bits) || !m1_int_fits(pat.ival, switch_bits, scrutinee_type != null ? m1_unsigned(scrutinee_type) : g.default_unsigned))) {
 return false; }
            if (char_case && !m1_unicode_scalar(pat.ival)) {
 return false; }
            for (usz j = 0; j < literal_count; j++) { if (literals[j] == pat.ival) {
 return false; } }
            literals[literal_count] = pat.ival;
            labels[i] = g.label((char*)"match.case.");
            if (labels[i] == null) {
 return false; }
            literal_count++;
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            if (default_index >= 0 || i + 1 != c.branch_count) {
 return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"match.default.");
            if (labels[i] == null) {
 return false; }
        }
        else {
 return false; }
    }
    if (default_index < 0) {
 return false; }
    fprintf(g.out, "  switch %s %s, label %%%s [", bool_match ? (char*)"i1" : m1_llvm_bits(switch_bits), scrutinee, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirPat* pat = c.branches[i].pat;
        if (bool_match && pat.tag == APAT_BOOL) { fprintf(g.out, " i1 %s, label %%%s", pat.ival != 0 ? (char*)"true" : (char*)"false", labels[i]); }
        else if (!bool_match && pat.tag == APAT_INT) { fprintf(g.out, " %s %ld, label %%%s", m1_llvm_bits(switch_bits), pat.ival, labels[i]); }
        else if (char_match && pat.tag == APAT_CHAR) { fprintf(g.out, " i32 %ld, label %%%s", pat.ival, labels[i]); }
    }
    fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        g.branch_enter();
        bool arm_ok = g.command(c.branches[i].body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) {
 return false; }
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    usz saved = g.env_count;
    if (default_pat.tag == APAT_BIND && !g.bind_typed(default_pat.name, scrutinee, bool_match, false, scrutinee_type)) {
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
fn bool M1Gen.is_condition(M1Gen* g, AirPrd* p)
{
    if (p == null) {
 return false; }
    if (p.tag == APRD_BOOL) { return true; }
    if (p.tag == APRD_COERCE && m1_bool_type(p.ty) && p.sub_count == 1) { return true; }
    if (p.tag == APRD_VAR) { return g.lookup_bool(p.name); }
    if (p.tag == APRD_UNOP && p.uop == AUN_NOT && p.sub_count == 1) { return g.is_condition(p.subs[0]); }
    if (p.tag == APRD_BINOP)
    {
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE) { return true; }
        if ((p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR) && p.sub_count == 2 &&
            (p.ty == null || p.ty.tag == ATYP_INFER || p.ty.tag == ATYP_BOOL))
        {
            return g.is_condition(p.subs[0]) && g.is_condition(p.subs[1]);
        }
    }
 return false;
}
// M9: collects the names of currently loop-carried locals (captured by a
// label or bound as a label parameter) that a loop body rebinds through
// lets/comus. These become header phis with the entry value on the preheader
// edge and the body's final binding on the backedge. Branching constructs
// (if/match) are terminal in AIR, so scope-local shadowing inside them cannot
// escape; only sequential/nested-loop bindings need tracking.
fn bool M1Gen.scan_carried_mutation_cns(M1Gen* g, AirCns* k, char*[] names, int* count, int depth)
{
    if (k == null) { return true; }
    if (depth >= 64) {
 return false; }
    if (k.tag == ACNS_COMU && k.bind != null && !same(k.bind, "_"))
    {
        int ix = g.env_index(k.bind);
        if (ix >= 0 && g.env_carried[(usz)ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (same(names[(usz)i], k.bind)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) {
 return false; }
                names[(usz)(*count)] = k.bind;
                (*count)++;
            }
        }
    }
    if (k.tag == ACNS_COMU && !g.scan_carried_mutation(k.body, names, count, depth + 1)) {
 return false; }
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] != null && !g.scan_carried_mutation(k.branches[i].body, names, count, depth + 1)) {
 return false; }
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        if (k.cobranches[i] != null && !g.scan_carried_mutation(k.cobranches[i].body, names, count, depth + 1)) {
 return false; }
    }
    return g.scan_carried_mutation_cns(k.tail, names, count, depth + 1);
}
fn bool M1Gen.scan_carried_mutation(M1Gen* g, AirCmd* c, char*[] names, int* count, int depth)
{
    if (c == null) { return true; }
    if (depth >= 64) {
 return false; }
    if (c.tag == ACMD_LET && c.binder != null && !same(c.binder, "_"))
    {
        int ix = g.env_index(c.binder);
        if (ix >= 0 && g.env_carried[(usz)ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (same(names[(usz)i], c.binder)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) {
 return false; }
                names[(usz)(*count)] = c.binder;
                (*count)++;
            }
        }
    }
    if (!g.scan_carried_mutation_cns(c.cns, names, count, depth + 1)) {
 return false; }
    return g.scan_carried_mutation(c.body, names, count, depth + 1) && g.scan_carried_mutation(c.next, names, count, depth + 1);
}
fn void M1Gen.note_carried_bind(M1Gen* g, char* name, char* value)
{
    if (!g.watch_active || g.branch_depth != g.watch_branch_depth || name == null || value == null) { return; }
    for (int k = 0; k < g.watch_count; k++)
    {
        if (same(g.watch_names[(usz)k], name)) { g.watch_values[(usz)k] = value; return; }
    }
}
fn char* M1Gen.watch_lookup(M1Gen* g, char* name, char* fallback)
{
    if (g.watch_active && g.branch_depth == g.watch_branch_depth)
    {
        for (int k = 0; k < g.watch_count; k++)
        {
            if (same(g.watch_names[(usz)k], name)) { return g.watch_values[(usz)k]; }
        }
    }
    return fallback;
}
// Arms of branching constructs are terminal in this backend, so bindings made
// inside them can never flow onto a loop backedge. Track that nesting so the
// carried-watch ignores them.
fn void M1Gen.branch_enter(M1Gen* g) { g.branch_depth++; }
fn void M1Gen.branch_leave(M1Gen* g) { if (g.branch_depth > 0) { g.branch_depth--; } }
// Emits the phi node for one loop-carried local at the head of a loop header
// block: the entry value flows from the preheader, the loop's final binding
// from the backedge block.
fn bool M1Gen.emit_loop_phi(M1Gen* g, char* phi, AirTyp* ty, char* entry_value, char* pre_block, bool has_backedge, char* latch_value, char* latch_block)
{
    char* ty_text = g.llvm_value_type_text(ty);
    if (phi == null || ty_text == null || entry_value == null || pre_block == null) { g.failed = true;
 return false; }
    if (has_backedge)
    {
        if (latch_value == null || latch_block == null) {
 return false; }
        fprintf(g.out, "  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]\n", phi, ty_text, entry_value, pre_block, latch_value, latch_block);
    }
    else { fprintf(g.out, "  %s = phi %s [ %s, %%%s ]\n", phi, ty_text, entry_value, pre_block); }
    return true;
}
// Command slice: return expressions, bindings, direct calls, guarded scalar
// matches, structured while loops, terminal if/else, and label/jump CFG.
// ---- M10 escape-only effect lowering helpers ----
// Backquote-quoted AIR names (`Eff.op`) normalize to their bare form.
fn char* m1_fx_norm(char* s, char* buf, usz cap)
{
    if (s == null || buf == null || cap < 2) { return null; }
    usz n = 0;
    while (s[n] != 0 && n + 1 < cap) { buf[n] = s[n]; n++; }
    if (n >= 2 && (int)buf[0] == 96 && (int)buf[n - 1] == 96) { buf[n - 1] = 0; return buf + 1; }
    buf[n] = 0;
    return buf;
}
// Resolve `Eff.op` (or bare `op`) to a declared effect operation.
fn AirDecl* m1_find_effect_op(AirDecl** decls, usz count, char* qname, AirEffectOp** found_op)
{
    if (found_op != null) { *found_op = null; }
    if (qname == null || qname[0] == 0) { return null; }
    int dot = -1;
    for (usz i = 0; qname[i] != 0; i++) { if (qname[i] == '.') { dot = (int)i; } }
    for (usz i = 0; i < count; i++)
    {
        AirDecl* e = decls[i];
        if (e == null || e.tag != ADECL_EFFECT || e.name == null) { continue; }
        for (usz j = 0; j < e.op_count && j < 16; j++)
        {
            AirEffectOp* o = e.ops[j];
            if (o == null || o.name == null) { continue; }
            if (dot >= 0)
            {
                usz plen = 0;
                while (e.name[plen] != 0) { plen++; }
                if (plen != (usz)dot) { continue; }
                bool prefix_ok = true;
                for (usz cix = 0; cix < plen; cix++) { if (e.name[cix] != qname[cix]) { prefix_ok = false; break; } }
                if (!prefix_ok || !same(o.name, qname + dot + 1)) { continue; }
            }
            else if (!same(o.name, qname)) { continue; }
            if (found_op != null) { *found_op = o; }
            return e;
        }
    }
    return null;
}
// Handler-arm soundness scan: 0 ok, 1 nested `handle` (escapes the subset),
// 2 `resume` command, 3 `%resume` continuation reference.
fn int m1_fx_prd_problem(AirPrd* p, int depth)
{
    if (p == null) { return 0; }
    if (depth > 48) { return 1; }
    int pp = 0;
    if (p.body != null) { pp = m1_fx_cmd_problem(p.body, depth + 1); if (pp != 0) { return pp; } }
    if (p.subs != null)
    {
        for (usz i = 0; i < p.sub_count; i++)
        {
            pp = m1_fx_prd_problem(p.subs[i], depth + 1);
            if (pp != 0) { return pp; }
        }
    }
    if (p.rec_inits != null)
    {
        for (usz i = 0; i < p.rec_init_count; i++)
        {
            if (p.rec_inits[i] == null) { continue; }
            pp = m1_fx_prd_problem(p.rec_inits[i].value, depth + 1);
            if (pp != 0) { return pp; }
        }
    }
    return 0;
}
fn int m1_fx_cmd_problem(AirCmd* c, int depth)
{
    if (c == null) { return 0; }
    if (depth > 48) { return 1; }
    if (c.tag == ACMD_HANDLE) { return 1; }
    if (c.tag == ACMD_RESUME) { return 2; }
    AirCns* k = c.cns;
    while (k != null)
    {
        if (k.name != null && same(k.name, "%resume")) { return 3; }
        int kp = m1_fx_prd_problem(k.prd, depth + 1);
        if (kp != 0) { return kp; }
        k = k.tail;
    }
    int pp = m1_fx_prd_problem(c.prd, depth + 1);
    if (pp != 0) { return pp; }
    for (usz i = 0; i < c.prd_count && i < 64; i++)
    {
        pp = m1_fx_prd_problem(c.prds[i], depth + 1);
        if (pp != 0) { return pp; }
    }
    for (usz i = 0; i < c.branch_count && i < 64; i++)
    {
        if (c.branches[i] == null) { continue; }
        pp = m1_fx_cmd_problem(c.branches[i].guard, depth + 1);
        if (pp != 0) { return pp; }
        pp = m1_fx_cmd_problem(c.branches[i].body, depth + 1);
        if (pp != 0) { return pp; }
    }
    pp = m1_fx_cmd_problem(c.body, depth + 1);
    if (pp != 0) { return pp; }
    pp = m1_fx_cmd_problem(c.next, depth + 1);
    if (pp != 0) { return pp; }
    pp = m1_fx_cmd_problem(c.then_c, depth + 1);
    if (pp != 0) { return pp; }
    return m1_fx_cmd_problem(c.else_c, depth + 1);
}
// Conservative continuation-binder usage scan; deep trees assume a use.
fn bool m1_prd_uses_name(AirPrd* p, char* name, int depth)
{
    if (p == null || name == null) { return false; }
    if (depth > 48) { return true; }
    if (p.tag == APRD_VAR && p.name != null && same(p.name, name)) { return true; }
    if (m1_cmd_uses_name(p.body, name, depth + 1)) { return true; }
    if (p.subs != null)
    {
        for (usz i = 0; i < p.sub_count; i++) { if (m1_prd_uses_name(p.subs[i], name, depth + 1)) { return true; } }
    }
    if (p.rec_inits != null)
    {
        for (usz i = 0; i < p.rec_init_count; i++)
        {
            if (p.rec_inits[i] == null) { continue; }
            if (m1_prd_uses_name(p.rec_inits[i].value, name, depth + 1)) { return true; }
        }
    }
    return false;
}
fn bool m1_cmd_uses_name(AirCmd* c, char* name, int depth)
{
    if (c == null || name == null) { return false; }
    if (depth > 48) { return true; }
    AirCns* k = c.cns;
    while (k != null)
    {
        if (m1_prd_uses_name(k.prd, name, 0)) { return true; }
        k = k.tail;
    }
    if (m1_prd_uses_name(c.prd, name, 0)) { return true; }
    for (usz i = 0; i < c.prd_count && i < 64; i++) { if (m1_prd_uses_name(c.prds[i], name, 0)) { return true; } }
    for (usz i = 0; i < c.jump_arg_count && i < 16; i++) { if (c.jump_args[i] != null && same(c.jump_args[i], name)) { return true; } }
    for (usz i = 0; i < c.branch_count && i < 64; i++)
    {
        if (c.branches[i] == null) { continue; }
        if (m1_cmd_uses_name(c.branches[i].guard, name, depth + 1)) { return true; }
        if (m1_cmd_uses_name(c.branches[i].body, name, depth + 1)) { return true; }
    }
    if (m1_cmd_uses_name(c.body, name, depth + 1)) { return true; }
    if (m1_cmd_uses_name(c.next, name, depth + 1)) { return true; }
    if (m1_cmd_uses_name(c.then_c, name, depth + 1)) { return true; }
    return m1_cmd_uses_name(c.else_c, name, depth + 1);
}

// A `handle` emits its body inline; each arm becomes a block that a matching
// `perform` branches to after storing the payload into a shared slot. Arms
// that resume, reference `%resume`, nest handlers, guard their patterns, bind
// a payload for a unit-typed operation, or use their continuation binder fail
// closed with a source position. The handled computation's own continuation
// is untouched; the post-handle block joins arm (and fall-through) outcomes.
fn bool M1Gen.effect_handle(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (g_m1_target_freestanding)
    {
        g.note_failure(c.source_line, c.source_col, "effect handlers are not lowerable under the freestanding wasm32 target profile (no host stack/continuation runtime)");
        return false;
    }
    if (c.handled == null || c.branch_count == 0) { return false; }
    if (g.fx_depth >= 8)
    {
        g.note_failure(c.source_line, c.source_col, "effect handlers nested deeper than the supported maximum of 8");
        return false;
    }
    if (c.branch_count > 16)
    {
        g.note_failure(c.source_line, c.source_col, "effect handler covers more operations than supported (max 16)");
        return false;
    }
    M1FxFrame* fr = &g.fx_stack[g.fx_depth];
    fr.arm_count = 0;
    fr.post = g.label("fx.post.");
    if (fr.post == null) { return false; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* br = c.branches[i];
        if (br == null || br.guard != null || br.body == null || br.pat == null ||
            br.pat.tag != APAT_VARIANT || br.pat.name == null || br.pat.sub_count < 1 || br.pat.sub_count > 2)
        {
            g.note_failure(c.source_line, c.source_col, "effect handler arm must be a plain `Effect.op(payload[, k])` operation pattern without a guard");
            return false;
        }
        char[256] opbuf;
        char* opn = m1_fx_norm(br.pat.name, &opbuf[0], 256);
        AirEffectOp* op = null;
        if (m1_find_effect_op(g.decls, g.decl_count, opn, &op) == null || op == null)
        {
            g.note_failure(br.body.source_line, br.body.source_col, "effect handler arm does not name a declared effect operation");
            return false;
        }
        char* payload_name = null;
        char* kont_name = null;
        bool binders_ok = true;
        for (usz b = 0; b < br.pat.sub_count; b++)
        {
            AirPat* sp = br.pat.sub[b];
            if (sp == null || (sp.tag != APAT_BIND && sp.tag != APAT_WILD)) { binders_ok = false; break; }
            if (sp.tag == APAT_BIND && sp.name != null)
            {
                if (b == 0) { payload_name = sp.name; }
                else { kont_name = sp.name; }
            }
        }
        if (!binders_ok)
        {
            g.note_failure(c.source_line, c.source_col, "effect handler arm binders must be `bind name` or wildcard `_` patterns");
            return false;
        }
        AirTyp* slot_ty = op.op_ty;
        if (slot_ty == null || slot_ty.tag == ATYP_INFER || !m1_backend_type(slot_ty, g.decls, g.decl_count, 0))
        {
            g.note_failure(c.source_line, c.source_col, "effect operation payload type is not backend-lowerable; declare an explicit scalar/pointer type instead of `infer`");
            return false;
        }
        bool unit_payload = m1_unit_type(slot_ty);
        if (unit_payload && payload_name != null)
        {
            g.note_failure(c.source_line, c.source_col, "effect operation declares no payload but the handler arm binds one");
            return false;
        }
        for (usz e = 0; e < fr.arm_count; e++)
        {
            char[256] ebuf;
            char* en = m1_fx_norm(fr.arms[e].op, &ebuf[0], 256);
            if (en != null && opn != null && same(en, opn))
            {
                g.note_failure(c.source_line, c.source_col, "duplicate effect operation arm in the same handler");
                return false;
            }
        }
        int prob = m1_fx_cmd_problem(br.body, 0);
        if (prob == 1)
        {
            g.note_failure(br.body.source_line, br.body.source_col, "a nested `handle` inside an effect handler arm is not lowerable");
            return false;
        }
        if (prob == 2)
        {
            g.note_failure(br.body.source_line, br.body.source_col, "`resume` escapes the supported effect subset: only one-shot, non-resuming handlers are lowerable");
            return false;
        }
        if (prob == 3)
        {
            g.note_failure(br.body.source_line, br.body.source_col, "handler arm references the `%resume` continuation; resuming handlers are not lowerable");
            return false;
        }
        if (kont_name != null && m1_cmd_uses_name(br.body, kont_name, 0))
        {
            g.note_failure(br.body.source_line, br.body.source_col, "handler arm uses its continuation binder; resuming or multi-shot continuations are not lowerable");
            return false;
        }
        M1FxArm* arm = &fr.arms[fr.arm_count];
        arm.op = null;
        if (opn != null)
        {
            usz on = 0;
            while (opn[on] != 0) { on++; }
            arm.op = g.arena.dup(opn, on);
        }
        arm.label = g.label("fx.arm.");
        if (arm.op == null || arm.label == null) { return false; }
        arm.body = br.body;
        arm.payload = payload_name;
        arm.slot_ty = slot_ty;
        arm.has_slot = !unit_payload;
        arm.slot = null;
        fr.arm_count++;
    }
    // Payload slots are allocated at the handler's entry point so they
    // dominate every perform store and every arm block load.
    for (usz i = 0; i < fr.arm_count; i++)
    {
        if (!fr.arms[i].has_slot) { continue; }
        char* slot = g.tmp();
        char* ty = g.llvm_type_text(fr.arms[i].slot_ty);
        int align = g.type_alignment(fr.arms[i].slot_ty, 0);
        if (slot == null || ty == null || align <= 0) { return false; }
        fr.arms[i].slot = slot;
        fprintf(g.out, "  %s = alloca %s, align %d\n", slot, ty, align);
    }
    usz saved_env = g.env_count;
    g.fx_depth++;
    bool body_ok = g.command(c.handled, ret_name);
    g.fx_depth--;
    g.env_count = saved_env;
    if (!body_ok) { return false; }
    bool body_fell = !g.terminated;
    if (body_fell)
    {
        fprintf(g.out, "  br label %%%s\n", fr.post);
        g.terminated = true;
    }
    bool any_arm_fell = false;
    for (usz i = 0; i < fr.arm_count; i++)
    {
        M1FxArm* arm = &fr.arms[i];
        g.begin_block(arm.label);
        g.terminated = false;
        usz arm_env = g.env_count;
        if (arm.payload != null)
        {
            char* ty = g.llvm_type_text(arm.slot_ty);
            int align = g.type_alignment(arm.slot_ty, 0);
            char* ld = g.tmp();
            if (ty == null || align <= 0 || ld == null || arm.slot == null) { return false; }
            fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", ld, ty, arm.slot, align);
            bool pb = m1_bool_type(arm.slot_ty);
            bool ppayload = !pb && m1_pointer_repr_type(arm.slot_ty);
            if (!g.bind_typed(arm.payload, ld, pb, ppayload, arm.slot_ty)) { return false; }
        }
        bool arm_ok = g.command(arm.body, ret_name);
        g.env_count = arm_env;
        if (!arm_ok) { return false; }
        if (!g.terminated)
        {
            any_arm_fell = true;
            fprintf(g.out, "  br label %%%s\n", fr.post);
            g.terminated = true;
        }
    }
    // The post-handle block exists only when some path actually reaches it;
    // an all-terminal handler would otherwise leave a terminator-less block.
    if (body_fell || any_arm_fell)
    {
        g.begin_block(fr.post);
        g.terminated = false;
    }
    else { g.terminated = true; }
    return true;
}
fn bool M1Gen.effect_perform(M1Gen* g, AirCmd* c)
{
    if (g_m1_target_freestanding)
    {
        g.note_failure(c.source_line, c.source_col, "effect operations are not lowerable under the freestanding wasm32 target profile");
        return false;
    }
    char[256] nbuf;
    char* opn = m1_fx_norm(c.eff_op, &nbuf[0], 256);
    M1FxArm* arm = null;
    for (usz d = g.fx_depth; d > 0 && arm == null; d--)
    {
        M1FxFrame* fr = &g.fx_stack[d - 1];
        for (usz i = 0; i < fr.arm_count; i++)
        {
            char[256] abuf;
            char* an = m1_fx_norm(fr.arms[i].op, &abuf[0], 256);
            if (an != null && opn != null && same(an, opn)) { arm = &fr.arms[i]; break; }
        }
    }
    if (arm == null)
    {
        char[384] mb;
        int mn = snprintf(&mb[0], 384, "perform of effect op `%s` has no enclosing handler in this scope", opn == null ? (char*)"?" : opn);
        if (mn > 0 && mn < 384) { g.note_failure(c.source_line, c.source_col, g.arena.dup(&mb[0], (usz)mn)); }
        return false;
    }
    if (arm.has_slot)
    {
        if (c.prd == null || c.prd.tag == APRD_UNIT)
        {
            g.note_failure(c.source_line, c.source_col, "effect operation expects a payload but the perform passes unit");
            return false;
        }
        bool is_bool = m1_bool_type(arm.slot_ty);
        bool is_ptr = !is_bool && m1_pointer_repr_type(arm.slot_ty);
        AirTyp* vt = g.expr_type(c.prd);
        bool type_ok = vt != null && (m1_value_type_compatible(arm.slot_ty, vt, 0) ||
            (!is_bool && m1_integer_type(arm.slot_ty) && g.integer_value_compatible(c.prd, arm.slot_ty)));
        if (is_bool && !g.is_condition(c.prd)) { type_ok = false; }
        if (!type_ok)
        {
            g.note_failure(c.source_line, c.source_col, "effect payload type does not match the declared operation type");
            return false;
        }
        if (m1_integer_type(arm.slot_ty) && !m1_contextual_int_fits(c.prd, arm.slot_ty)) { return false; }
        char* value = is_bool ? g.condition(c.prd) : (is_ptr ? g.pointer_value(c.prd) : g.prd(c.prd));
        if (g.failed || value == null) { return false; }
        if (!is_bool && !is_ptr && vt != null && m1_integer_type(vt) && m1_int_bits(vt) != m1_int_bits(arm.slot_ty))
        {
            value = g.convert_integer_width(value, vt, arm.slot_ty);
            if (g.failed || value == null) { return false; }
        }
        if (g.low_profile && is_ptr && c.prd.tag != APRD_NULL)
        {
            M1Provenance* vp = g.prov(value);
            if (vp == null || vp.freed)
            {
                g.note_failure(c.source_line, c.source_col, "effect payload pointer has no live provenance");
                return false;
            }
        }
        char* ty = g.llvm_type_text(arm.slot_ty);
        int align = g.type_alignment(arm.slot_ty, 0);
        if (ty == null || align <= 0 || arm.slot == null) { return false; }
        fprintf(g.out, "  store %s %s, ptr %s, align %d\n", ty, value, arm.slot, align);
    }
    else if (c.prd != null && c.prd.tag != APRD_UNIT)
    {
        g.note_failure(c.source_line, c.source_col, "effect operation declares no payload but the perform passes one");
        return false;
    }
    fprintf(g.out, "  br label %%%s\n", arm.label);
    g.terminated = true;
    return true;
}
// ── AIR 2.1/2.2 machine forms: fence · atomic · syscall · asm ────────────
// fence/atomic map one-to-one onto LLVM's C11 memory-model instructions.
// syscall lowers through the pinned-register x86-64 Linux syscall ABI (host
// profile only). asm is an inline-assembly call. Anything outside this
// surface fails closed with a positioned diagnostic instead of guessing.
fn char* m1_air_order_text(int order)
{
    switch (order)
    {
        case 0: return (char*)"monotonic";
        case 1: return (char*)"acquire";
        case 2: return (char*)"release";
        case 3: return (char*)"acq_rel";
        case 4: return (char*)"seq_cst";
        default: return null;
    }
}
fn bool M1Gen.fence_cmd(M1Gen* g, AirCmd* c)
{
    // LLVM admits acquire/release/acq_rel/seq_cst on a fence; a relaxed
    // (monotonic) fence is a no-op in the C11 model with no LLVM spelling.
    if (c.atomic_order < 1 || c.atomic_order > 4)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"fence requires an acquire, release, acq_rel, or seq_cst ordering (a relaxed fence has no LLVM lowering)");
        return false;
    }
    fprintf(g.out, "  fence %s\n", m1_air_order_text(c.atomic_order));
    return true;
}
fn bool M1Gen.atomic_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (!g.low_profile)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"atomic operations require an AIR 3 typed pointer operand (alloca/typed gep); untyped pointer atomics are unsupported");
        return false;
    }
    if (c.prd == null) { g.note_failure(c.source_line, c.source_col, (char*)"atomic operation is missing its pointer operand"); return false; }
    if (c.atomic_op == 13)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"atomic cmpxchg is not lowerable: the AIR grammar carries a single ORDER, but cmpxchg needs separate success/failure orderings");
        return false;
    }
    if (c.atomic_op < 0 || c.atomic_op > 12) { g.note_failure(c.source_line, c.source_col, (char*)"unknown atomic operation"); return false; }
    bool is_load = c.atomic_op == 0; bool is_store = c.atomic_op == 1;
    int want = is_load ? 0 : 1;
    if ((int)c.prd_count != want)
    {
        g.note_failure(c.source_line, c.source_col, is_load ? (char*)"atomic load takes only its pointer operand" : (char*)"atomic operation takes exactly one value operand");
        return false;
    }
    if (is_load && (c.atomic_order == 2 || c.atomic_order == 3))
    { g.note_failure(c.source_line, c.source_col, (char*)"atomic load ordering must be relaxed, acquire, or seq_cst"); return false; }
    if (is_store && (c.atomic_order == 1 || c.atomic_order == 3))
    { g.note_failure(c.source_line, c.source_col, (char*)"atomic store ordering must be relaxed, release, or seq_cst"); return false; }
    AirTyp* pty = g.expr_type(c.prd);
    AirTyp* element = m1_pointee_type(pty);
    int ebits = m1_int_bits(element);
    if (element == null || (ebits != 8 && ebits != 16 && ebits != 32 && ebits != 64))
    { g.note_failure(c.source_line, c.source_col, (char*)"atomic pointee must be an 8/16/32/64-bit integer (pointer, bool, float, and 128-bit atomics are unsupported)"); return false; }
    char* address = g.pointer_value(c.prd);
    if (g.failed || address == null) { return false; }
    if (!g.check_access(address, element, c.source_line, c.source_col, !is_load)) { return false; }
    char* ety = g.llvm_type_text(element);
    int align = g.type_alignment(element, 0);
    char* order = m1_air_order_text(c.atomic_order);
    if (ety == null || align <= 0 || order == null) { return false; }
    if (is_load)
    {
        char* dst = g.tmp(); if (dst == null) { return false; }
        fprintf(g.out, "  %s = load atomic %s, ptr %s %s, align %d\n", dst, ety, address, order, align);
        if (c.cns == null) { return true; }
        return g.consume(dst, false, false, element, c.cns, ret_name);
    }
    AirPrd* vp = c.prds[0];
    bool vok = vp != null && m1_integer_type(element) &&
        (m1_value_type_compatible(element, g.expr_type(vp), 0) || g.integer_value_compatible(vp, element));
    if (!vok)
    { g.note_failure(c.source_line, c.source_col, (char*)"atomic value operand must be an integer compatible with the pointee type"); return false; }
    char* value = g.prd(vp);
    if (g.failed || value == null) { return false; }
    if (is_store)
    {
        fprintf(g.out, "  store atomic %s %s, ptr %s %s, align %d\n", ety, value, address, order, align);
        if (c.cns == null) { return true; }
        return g.consume_unit(c.cns, ret_name);
    }
    char* opn = null;
    switch (c.atomic_op)
    {
        case 2: opn = (char*)"xchg"; break;
        case 3: opn = (char*)"add"; break;
        case 4: opn = (char*)"sub"; break;
        case 5: opn = (char*)"and"; break;
        case 6: opn = (char*)"or"; break;
        case 7: opn = (char*)"xor"; break;
        case 8: opn = (char*)"nand"; break;
        case 9: opn = (char*)"max"; break;
        case 10: opn = (char*)"min"; break;
        case 11: opn = (char*)"umax"; break;
        case 12: opn = (char*)"umin"; break;
        default: break;
    }
    if (opn == null) { return false; }
    char* dst = g.tmp(); if (dst == null) { return false; }
    fprintf(g.out, "  %s = atomicrmw %s ptr %s, %s %s %s\n", dst, opn, address, ety, value, order);
    if (c.cns == null) { return true; }
    return g.consume(dst, false, false, element, c.cns, ret_name);
}
fn bool M1Gen.syscall_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (g_m1_target_freestanding)
    { g.note_failure(c.source_line, c.source_col, (char*)"syscalls are host-platform specific and are not lowerable under the freestanding wasm32 target profile"); return false; }
    if (c.prd == null) { g.note_failure(c.source_line, c.source_col, (char*)"syscall is missing its number operand"); return false; }
    if (c.prd_count > 6) { g.note_failure(c.source_line, c.source_col, (char*)"x86-64 Linux syscalls take at most 6 arguments"); return false; }
    AirTyp i64t = { .tag = ATYP_I64 };
    AirTyp* nt = g.expr_type(c.prd);
    if (nt != null && !m1_integer_type(nt))
    { g.note_failure(c.source_line, c.source_col, (char*)"syscall number must be an integer"); return false; }
    char* nr = g.prd(c.prd);
    if (g.failed || nr == null) { return false; }
    if (m1_integer_type(nt) && m1_int_bits(nt) != 64)
    { nr = g.convert_integer_width(nr, nt, &i64t); if (g.failed || nr == null) { return false; } }
    char*[8] args;
    int nargs = (int)c.prd_count;
    for (int i = 0; i < nargs; i++)
    {
        AirPrd* ap = c.prds[i];
        AirTyp* at = ap != null ? g.expr_type(ap) : null;
        if (at != null && !m1_integer_type(at) && !m1_pointer_repr_type(at))
        { g.note_failure(c.source_line, c.source_col, (char*)"syscall arguments must be integers or pointers (bool/float/aggregate arguments are unsupported)"); return false; }
        if (at != null && m1_pointer_repr_type(at))
        {
            char* pv = g.pointer_value(ap);
            if (g.failed || pv == null) { return false; }
            if (g.low_profile && ap.tag != APRD_NULL)
            {
                M1Provenance* vp = g.prov(pv);
                if (vp == null || vp.freed) { g.note_failure(c.source_line, c.source_col, (char*)"syscall pointer argument has no live provenance"); return false; }
            }
            char* wi = g.tmp(); if (wi == null) { return false; }
            fprintf(g.out, "  %s = ptrtoint ptr %s to i64\n", wi, pv);
            args[i] = wi;
            continue;
        }
        char* av = g.prd(ap);
        if (g.failed || av == null) { return false; }
        if (at != null && m1_int_bits(at) != 64)
        { av = g.convert_integer_width(av, at, &i64t); if (g.failed || av == null) { return false; } }
        args[i] = av;
    }
    char*[6] regs; regs[0] = (char*)"{rdi}"; regs[1] = (char*)"{rsi}"; regs[2] = (char*)"{rdx}";
    regs[3] = (char*)"{r10}"; regs[4] = (char*)"{r8}"; regs[5] = (char*)"{r9}";
    char[512] cons; int co = snprintf(&cons[0], 512, (char*)"={rax},{rax}");
    for (int i = 0; i < nargs; i++) { if (co > 0 && co < 500) { co += snprintf(&cons[0] + co, 512 - (usz)co, (char*)",%s", regs[i]); } }
    if (co <= 0 || co >= 500) { return false; }
    snprintf(&cons[0] + co, 512 - (usz)co, (char*)",~{rcx},~{r11},~{flags},~{memory}");
    char[1024] ops; int oo = snprintf(&ops[0], 1024, (char*)"i64 %s", nr);
    for (int i = 0; i < nargs; i++) { if (oo > 0 && oo < 1000) { oo += snprintf(&ops[0] + oo, 1024 - (usz)oo, (char*)", i64 %s", args[i]); } }
    if (oo <= 0 || oo >= 1000) { return false; }
    char* dst = g.tmp(); if (dst == null) { return false; }
    fprintf(g.out, "  %s = call i64 asm sideeffect \"syscall\", \"%s\"(%s)\n", dst, &cons[0], &ops[0]);
    if (c.cns == null) { return true; }
    return g.consume(dst, false, false, &i64t, c.cns, ret_name);
}
fn char* M1Gen.asm_escaped(M1Gen* g, char* text)
{
    if (text == null) { return null; }
    usz tn = 0;
    for (char* q = text; *q != 0; q++) { tn++; }
    char* out = (char*)g.arena.alloc(tn * 3 + 1, 1);
    if (out == null) { return null; }
    usz w = 0;
    for (usz i = 0; i < tn; i++)
    {
        char ch2 = text[i];
        if ((int)ch2 >= 32 && (int)ch2 <= 126 && ch2 != '"' && ch2 != '\\')
        { out[w] = ch2; w++; continue; }
        int b = (int)ch2 & 255;
        char[16] hexd = "0123456789ABCDEF";
        out[w] = '\\'; out[w + 1] = hexd[(usz)(b >> 4)]; out[w + 2] = hexd[(usz)(b & 15)]; w += 3;
    }
    out[w] = 0;
    return out;
}
fn bool M1Gen.asm_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (c.asm_text == null)
    { g.note_failure(c.source_line, c.source_col, (char*)"asm requires a template string literal"); return false; }
    if (c.prd_count > 8) { g.note_failure(c.source_line, c.source_col, (char*)"asm supports at most 8 operands"); return false; }
    bool has_sig = c.asm_cons != null && c.asm_ret != null;
    if (c.prd_count > 0 && !has_sig)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"asm with operands requires the AIR 3.0 constraint and result form: asm \"template\" \"constraints\" : [type] (args)");
        return false;
    }
    AirTyp* rt = c.asm_ret;
    // AIR's verifier requires every asm to carry template+constraints+result
    // type; a `unit` result is AIR's spelling of a void asm.
    bool void_result = rt == null;
    bool ret_ptr = false;
    if (rt != null && m1_unit_type(rt)) { void_result = true; }
    else if (rt != null)
    {
        if (m1_bool_type(rt))
        { g.note_failure(c.source_line, c.source_col, (char*)"asm result type must not be bool (coerce to an integer explicitly)"); return false; }
        if (!m1_integer_type(rt) && !m1_float_type(rt) && !m1_pointer_repr_type(rt))
        { g.note_failure(c.source_line, c.source_col, (char*)"asm result type must be a supported scalar or unit"); return false; }
        void_result = false;
        ret_ptr = m1_pointer_repr_type(rt);
    }
    char* rty = void_result ? (char*)"void" : g.llvm_type_text(rt);
    if (rty == null) { return false; }
    char[1536] ops; int oo = 0; ops[0] = 0;
    for (int i = 0; i < (int)c.prd_count; i++)
    {
        AirPrd* ap = c.prds[i];
        AirTyp* at = ap != null ? g.expr_type(ap) : null;
        bool is_ptr = at != null && m1_pointer_repr_type(at);
        if (at == null || (!m1_integer_type(at) && !m1_float_type(at) && !is_ptr))
        { g.note_failure(c.source_line, c.source_col, (char*)"asm operands must be typed integers, floats, or pointers (bool and aggregates are unsupported)"); return false; }
        char* av = is_ptr ? g.pointer_value(ap) : g.prd(ap);
        if (g.failed || av == null) { return false; }
        if (is_ptr && g.low_profile && ap.tag != APRD_NULL)
        {
            M1Provenance* vp = g.prov(av);
            if (vp == null || vp.freed) { g.note_failure(c.source_line, c.source_col, (char*)"asm pointer operand has no live provenance"); return false; }
        }
        char* aty = g.llvm_type_text(at);
        if (aty == null) { return false; }
        if (oo >= 1400) { return false; }
        oo += snprintf(&ops[0] + oo, 1536 - (usz)oo, i == 0 ? (char*)"%s %s" : (char*)", %s %s", aty, av);
    }
    char* text = g.asm_escaped(c.asm_text);
    char* cons = g.asm_escaped(c.asm_cons != null ? c.asm_cons : (char*)"");
    if (text == null || cons == null) { return false; }
    char* dialect = c.asm_dialect == 1 ? (char*)" asm inteldialect sideeffect " : (char*)" asm sideeffect ";
    if (void_result)
    {
        fprintf(g.out, "  call void%s\"%s\", \"%s\"(%s)\n", dialect, text, cons, &ops[0]);
        if (g.failed) { return false; }
        if (c.cns == null) { return true; }
        return g.consume_unit(c.cns, ret_name);
    }
    char* dst = g.tmp(); if (dst == null) { return false; }
    fprintf(g.out, "  %s = call %s%s\"%s\", \"%s\"(%s)\n", dst, rty, dialect, text, cons, &ops[0]);
    if (g.failed) { return false; }
    if (c.cns == null) { return true; }
    return g.consume(dst, false, ret_ptr, rt, c.cns, ret_name);
}
fn bool M1Gen.command(M1Gen* g, AirCmd* c, char* ret_name)
{    if (c == null) {
 return false; }
    g.last_line = c.source_line; g.last_col = c.source_col;
    if (g.terminated && c.tag != ACMD_LABEL && c.tag != ACMD_SEQ && c.tag != ACMD_BLOCK && c.tag != ACMD_UNSAFE) {
 return false; }
    if (g.low_profile && c.tag == ACMD_STORE)
    {
        if (c.prd_count != 2 || c.prds[0] == null || c.prds[1] == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed typed store"); return false; }
        AirTyp* ptr_type = g.expr_type(c.prds[0]); AirTyp* element = m1_pointee_type(ptr_type);
        AirTyp* value_type = g.expr_type(c.prds[1]);
        if (element == null || !m1_backend_type(element, g.decls, g.decl_count, 0) ||
            (!m1_value_type_compatible(element, value_type, 0) && !(m1_integer_type(element) && g.integer_value_compatible(c.prds[1], element))))
        { g.note_failure(c.source_line, c.source_col, (char*)"store value type does not match pointer pointee"); return false; }
        char* address = g.pointer_value(c.prds[0]);        if (g.failed || address == null || !g.check_access(address, element, c.source_line, c.source_col, true)) {
 return false; }
        bool stored_ptr = m1_pointer_type(element);
        bool stored_bool = m1_bool_type(element);
        char* value = stored_bool ? g.condition(c.prds[1]) : (stored_ptr ? g.pointer_value(c.prds[1]) : g.prd(c.prds[1]));
        char* ty = g.llvm_type_text(element); int align = g.type_alignment(element, 0);        if (g.failed || value == null || ty == null || align <= 0) {
 return false; }
        if (stored_ptr && c.prds[1].tag != APRD_NULL)
        {
            M1Provenance* vp = g.prov(value);
            if (vp == null || vp.freed) { g.note_failure(c.source_line, c.source_col, (char*)"storing a pointer without live provenance"); return false; }
        }
        fprintf(g.out, "  store %s%s %s, ptr %s, align %d\n", c.vol ? (char*)"volatile " : (char*)"", ty, value, address, align);
        if (stored_ptr && !g.cell_set(address, value, c.prds[1].tag == APRD_NULL))
        { g.note_failure(c.source_line, c.source_col, (char*)"pointer store could not preserve value provenance"); return false; }
        return true;
    }
    if (c.tag == ACMD_SEQ)
    {
        usz saved_env = g.env_count;
        g.seq_depth++;
        bool first_ok = g.command(c.body, ret_name);
        bool next_ok = first_ok && g.command(c.next, ret_name);
        g.seq_depth--;
        // Bindings pushed by a nested sequence (comu continuation chains in
        // particular) must stay visible to siblings that follow deeper in the
        // same outermost sequence — e.g. a terminal `jump` that must read the
        // rebound values for phi edge recording. Restoring here would drop
        // them; the outermost sequence (or a failure) restores the scope.
        if (g.seq_depth == 0 || !next_ok) { g.env_count = saved_env; }
        return next_ok;
    }
    if (c.tag == ACMD_LABEL)
    {
        int ix = g.label_index(c.binder);
        if (ix < 0 || g.labels[(usz)ix].cmd != c) {
 return false; }
        M1Label* info = &g.labels[(usz)ix];
        if (info.captured || g.env_count > 64) {
 return false; }
        // M9 phi promotion: capture records the environment *shape* only.
        // Captured names become loop-carried — reassignments flow into the
        // label block through phi incoming edges recorded by each jump,
        // bypassing entry-block alloca slots and load/store round trips.
        for (usz i = 0; i < g.env_count; i++)
        {
            info.env_names[i] = g.env_names[i];
            info.env_values[i] = g.env_values[i];
            info.env_slots[i] = null;
            info.env_bools[i] = g.env_bools[i];
            info.env_ptrs[i] = g.env_ptrs[i];
            info.env_types[i] = g.env_types[i];
            g.env_carried[i] = true;
        }
        info.env_count = g.env_count;
        info.captured = true;
        return true;
    }
    if (c.tag == ACMD_JUMP)
    {
        if (g.for_depth > 0) {
 return false; }
        int ix = g.label_index(c.target_label);
        if (ix < 0) {
 return false; }
        M1Label* target = &g.labels[(usz)ix];
        if (c.jump_arg_count != target.param_count) {
 return false; }
        // Captured bindings may have changed since capture; the edge record
        // carries the current values into the label block's phi nodes.
        if (!g.label_environment_unchanged(target)) {
 return false; }
        char*[16] values;
        bool[16] value_bools;
        bool[16] value_ptrs;
        for (usz i = 0; i < c.jump_arg_count; i++)
        {
            values[i] = g.lookup(c.jump_args[i]);
            value_bools[i] = g.lookup_bool(c.jump_args[i]);
            value_ptrs[i] = g.lookup_ptr(c.jump_args[i]);
            if (values[i] == null || value_bools[i] != target.param_bools[i] || value_ptrs[i] != target.param_ptrs[i]) {
 return false; }
            if (!value_bools[i] && !value_ptrs[i] && !m1_value_type_compatible(target.params[i].ty, g.lookup_type(c.jump_args[i]), 0)) {
 return false; }
        }
        if (!g.label_record_edge(target, c.jump_arg_count > 0 ? &values[0] : null))
        { g.note_failure(c.source_line, c.source_col, (char*)"label has too many incoming control-flow edges for phi promotion"); return false; }
        fprintf(g.out, "  br label %%%s\n", target.name);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_BREAK || c.tag == ACMD_CONTINUE)
    {
        if (g.for_depth > 0) {
 return false; }
        int ix = g.label_index(c.target_label);
        if (ix < 0) {
 return false; }
        M1Label* target = &g.labels[(usz)ix];
        if (target.param_count != 0 || !g.label_environment_unchanged(target)) {
 return false; }
        if (!g.label_record_edge(target, null))
        { g.note_failure(c.source_line, c.source_col, (char*)"label has too many incoming control-flow edges for phi promotion"); return false; }
        fprintf(g.out, "  br label %%%s\n", target.name);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_NOP) { return true; }
    if (c.tag == ACMD_RET)
    {
        if (c.prd != null && c.prd.tag == APRD_UNIT)
        {
            if (!g.return_unit) {
 return false; }
            fprintf(g.out, "  ret void\n");
            g.terminated = true;
            return true;
        }
        bool is_bool = g.is_condition(c.prd);
        bool is_ptr = !is_bool && g.is_pointer_value(c.prd);
        AirTyp* value_type = g.expr_type(c.prd);
        char* value = is_bool ? g.condition(c.prd) : (is_ptr ? g.pointer_value(c.prd) : g.prd(c.prd));
        if (g.failed || value == null || is_bool != g.return_bool || is_ptr != g.return_ptr || g.return_unit) {
 return false; }
        if (!is_bool && !is_ptr) { value_type = g.int_rep_type(value_type); }
        if (!is_bool && !is_ptr)
        {
            bool compatible = (g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY) ? m1_value_type_compatible(g.return_type, value_type, 0) : (m1_float_type(g.return_type) ? m1_scalar_compatible(g.return_type, value_type) : g.integer_value_compatible(c.prd, g.return_type));
            if (!compatible) {
 return false; }
        }
        char* return_ir = is_bool ? (char*)"i1" : (is_ptr ? (char*)"ptr" : ((g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY) ? g.llvm_type_text(g.return_type) : m1_llvm_scalar(g.return_type)));
        if (return_ir == null) {
 return false; }
        fprintf(g.out, "  ret %s %s\n", return_ir, value);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_ASSUME)
    {
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) {
 return false; }
        fprintf(g.out, "  call void @llvm.assume(i1 %s)\n", condition);
        return true;
    }
    if (c.tag == ACMD_ASSERT)
    {
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) {
 return false; }
        char* pass_label = g.label((char*)"assert.pass.");
        char* fail_label = g.label((char*)"assert.fail.");
        if (pass_label == null || fail_label == null) {
 return false; }
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", condition, pass_label, fail_label);
        g.terminated = true;
        g.begin_block(fail_label);
        fprintf(g.out, "  call void @llvm.trap()\n  unreachable\n");
        g.begin_block(pass_label);
        g.terminated = false;
        return true;
    }
    if (c.tag == ACMD_TRAP)
    {
        fprintf(g.out, "  call void @llvm.trap()\n  unreachable\n");
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_UB)
    {
        fprintf(g.out, "  unreachable\n");
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_BLOCK || c.tag == ACMD_UNSAFE) { return g.command(c.body, ret_name); }
    if (c.tag == ACMD_FOR)
    {
        AirTyp* array_type = g.expr_type(c.prd);
        if (array_type == null || array_type.tag != ATYP_ARRAY || array_type.arg_count != 1 || array_type.ival < 0 || array_type.ival > 1024 || !m1_value_type(array_type, 0)) { return false; }
        AirTyp* element_type = array_type.args[0];
        char* aggregate_ir = g.llvm_type_text(array_type);
        char* element_ir = g.llvm_value_type_text(element_type);
        char* array_value = g.prd(c.prd);
        char* stack_mark = g.tmp();
        char* array_slot = g.tmp();
        char* header_label = g.label((char*)"for.header.");
        char* body_label = g.label((char*)"for.body.");
        char* latch_label = g.label((char*)"for.latch.");
        char* exit_label = g.label((char*)"for.exit.");
        char* index_phi = g.tmp();
        char* next_index = g.tmp();
        char* in_range = g.tmp();
        if (g.failed || aggregate_ir == null || element_ir == null || array_value == null || stack_mark == null || array_slot == null || header_label == null || body_label == null || latch_label == null || exit_label == null || index_phi == null || next_index == null || in_range == null) { return false; }
        // M9: the loop index and any loop-carried promoted locals are SSA phis
        // in the header block; only the array scratch stays in memory. The
        // body and latch are emitted before the header text so every phi
        // incoming pair is known when the header prints.
        char*[32] tracked; int tracked_count = 0;
        if (!g.scan_carried_mutation(c.body, tracked[..], &tracked_count, 0))
        { g.note_failure(c.source_line, c.source_col, (char*)"loop carries more mutable locals than supported"); return false; }
        usz outer_env = g.env_count;
        int[32] tracked_index;
        char*[32] entry_value; char*[32] latch_value; char*[32] phi_name;
        AirTyp*[32] tracked_type;
        for (int k = 0; k < tracked_count; k++)
        {
            int i = g.env_index(tracked[(usz)k]);
            if (i < 0) {
 g.note_failure(c.source_line, c.source_col, (char*)"malformed loop-carried binding state"); return false; }
            tracked_index[k] = i;
            entry_value[k] = g.env_values[(usz)i];
            tracked_type[k] = g.env_types[(usz)i];
            phi_name[k] = g.tmp();
            latch_value[k] = entry_value[k];
            if (phi_name[k] == null) { return false; }
            g.env_values[(usz)i] = phi_name[k];
        }
        char* pre_block = g.cur_block;
        if (pre_block == null) { return false; }
        fprintf(g.out, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
        fprintf(g.out, "  %s = alloca %s, align 1\n", array_slot, aggregate_ir);
        fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_ir, array_value, array_slot);
        fprintf(g.out, "  br label %%%s\n", header_label);
        g.terminated = true;
        g.begin_block(body_label);
        g.terminated = false;
        bool outer_watch = g.watch_active;
        if (!outer_watch)
        {
            g.watch_active = true;
            g.watch_branch_depth = g.branch_depth;
            g.watch_count = 0;
        }
        for (int k = 0; k < tracked_count; k++)
        {
            bool found = false;
            for (int e = 0; e < g.watch_count && !found; e++) { found = same(g.watch_names[(usz)e], tracked[(usz)k]); }
            if (!found && g.watch_count < 32) { g.watch_names[(usz)g.watch_count] = tracked[(usz)k]; g.watch_values[(usz)g.watch_count] = entry_value[k]; g.watch_count++; }
        }
        char* address = g.tmp();
        char* item = g.tmp();
        if (address == null || item == null) { return false; }
        fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 0, i64 %s\n", address, aggregate_ir, array_slot, index_phi);
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", item, element_ir, address);
        usz saved_env = g.env_count;
        if (c.binder != null && !same(c.binder, "_") && !g.bind_typed(c.binder, item, m1_bool_type(element_type), m1_pointer_type(element_type), element_type)) { g.env_count = saved_env; return false; }
        g.for_depth++;
        bool body_ok = g.command(c.body, ret_name);
        g.for_depth--;
        g.env_count = saved_env;
        if (!body_ok) { return false; }
        for (int k = 0; k < tracked_count; k++) { latch_value[k] = g.watch_lookup(tracked[(usz)k], entry_value[k]); }
        if (!outer_watch) { g.watch_active = false; g.watch_count = 0; }
        if (!g.terminated)
        {
            fprintf(g.out, "  br label %%%s\n", latch_label);
            g.terminated = true;
        }
        g.begin_block(latch_label);
        g.terminated = false;
        fprintf(g.out, "  %s = add i64 %s, 1\n", next_index, index_phi);
        fprintf(g.out, "  br label %%%s\n", header_label);
        g.terminated = true;
        g.env_count = outer_env;
        for (int k = 0; k < tracked_count; k++)
        {
            g.env_values[(usz)tracked_index[k]] = phi_name[k];
            g.note_carried_bind(tracked[(usz)k], phi_name[k]);
        }
        g.begin_block(header_label);
        g.terminated = false;
        fprintf(g.out, "  %s = phi i64 [ 0, %%%s ], [ %s, %%%s ]\n", index_phi, pre_block, next_index, latch_label);
        for (int k = 0; k < tracked_count; k++)
        {
            if (!g.emit_loop_phi(phi_name[k], tracked_type[k], entry_value[k], pre_block, true, latch_value[k], latch_label)) { return false; }
        }
        fprintf(g.out, "  %s = icmp ult i64 %s, %ld\n", in_range, index_phi, array_type.ival);
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", in_range, body_label, exit_label);
        g.terminated = true;
        g.begin_block(exit_label);
        fprintf(g.out, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
        g.terminated = false;
        return true;
    }
    if (c.tag == ACMD_WHILE)
    {
        // M9: loop-carried promoted locals get SSA phis at the header. The
        // body is emitted first (the header text lands after it in the IR),
        // so the backedge's final values are known when the phi lines print;
        // uses inside the body reference the pre-allocated phi names, which
        // is legal because the header dominates the body.
        char* header_label = g.label((char*)"while.header.");
        char* body_label = g.label((char*)"while.body.");
        char* exit_label = g.label((char*)"while.exit.");
        if (header_label == null || body_label == null || exit_label == null) { return false; }
        char*[32] tracked; int tracked_count = 0;
        if (!g.scan_carried_mutation(c.body, tracked[..], &tracked_count, 0))
        { g.note_failure(c.source_line, c.source_col, (char*)"loop carries more mutable locals than supported"); return false; }
        usz outer_env = g.env_count;
        int[32] tracked_index;
        char*[32] entry_value; char*[32] latch_value; char*[32] phi_name;
        AirTyp*[32] tracked_type;
        for (int k = 0; k < tracked_count; k++)
        {
            int i = g.env_index(tracked[(usz)k]);
            if (i < 0) { g.note_failure(c.source_line, c.source_col, (char*)"malformed loop-carried binding state"); return false; }
            tracked_index[k] = i;
            entry_value[k] = g.env_values[(usz)i];
            tracked_type[k] = g.env_types[(usz)i];
            phi_name[k] = g.tmp();
            if (phi_name[k] == null) { return false; }
            g.env_values[(usz)i] = phi_name[k];
        }
        char* pre_block = g.cur_block;
        if (pre_block == null) { return false; }
        fprintf(g.out, "  br label %%%s\n", header_label);
        g.terminated = true;
        g.begin_block(body_label);
        g.terminated = false;
        bool outer_watch = g.watch_active;
        if (!outer_watch)
        {
            g.watch_active = true;
            g.watch_branch_depth = g.branch_depth;
            g.watch_count = 0;
        }
        for (int k = 0; k < tracked_count; k++)
        {
            bool found = false;
            for (int e = 0; e < g.watch_count && !found; e++) { found = same(g.watch_names[(usz)e], tracked[(usz)k]); }
            if (!found && g.watch_count < 32) { g.watch_names[(usz)g.watch_count] = tracked[(usz)k]; g.watch_values[(usz)g.watch_count] = entry_value[k]; g.watch_count++; }
        }
        if (!g.command(c.body, ret_name)) { return false; }
        bool has_backedge = !g.terminated;
        char* latch_block = g.cur_block;
        for (int k = 0; k < tracked_count; k++) { latch_value[k] = g.watch_lookup(tracked[(usz)k], entry_value[k]); }
        if (!outer_watch) { g.watch_active = false; g.watch_count = 0; }
        if (has_backedge)
        {
            fprintf(g.out, "  br label %%%s\n", header_label);
            g.terminated = true;
        }
        // The loop body only leaks shadowed copies; restore the entry scope
        // and surface the loop-carried values as the header phis.
        g.env_count = outer_env;
        for (int k = 0; k < tracked_count; k++)
        {
            g.env_values[(usz)tracked_index[k]] = phi_name[k];
            g.note_carried_bind(tracked[(usz)k], phi_name[k]);
        }
        g.begin_block(header_label);
        g.terminated = false;
        for (int k = 0; k < tracked_count; k++)
        {
            if (!g.emit_loop_phi(phi_name[k], tracked_type[k], entry_value[k], pre_block, has_backedge, latch_value[k], latch_block)) { return false; }
        }
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) { return false; }
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", condition, body_label, exit_label);
        g.terminated = true;
        g.begin_block(exit_label);
        g.terminated = false;
        return true;
    }
    if (c.tag == ACMD_IF)
    {
        char* cond = g.condition(c.prd);
        if (g.failed || cond == null) { return false; }
        char* then_label = g.label((char*)"if.then.");
        char* else_label = g.label((char*)"if.else.");
        if (then_label == null || else_label == null) { return false; }
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", cond, then_label, else_label);
        g.terminated = true;
        g.begin_block(then_label);
        g.terminated = false;
        g.branch_enter();
        bool then_ok = g.command(c.then_c, ret_name);
        g.branch_leave();
        if (!then_ok || !g.terminated) { return false; }
        g.begin_block(else_label);
        g.terminated = false;
        g.branch_enter();
        bool else_ok = g.command(c.else_c, ret_name);
        g.branch_leave();
        return else_ok && g.terminated;
    }
    if (c.tag == ACMD_LET)
    {
        bool is_bool = g.is_condition(c.prd);
        bool is_ptr = !is_bool && g.is_pointer_value(c.prd);
        char* value = is_bool ? g.condition(c.prd) : (is_ptr ? g.pointer_value(c.prd) : g.prd(c.prd));
        if (g.failed || value == null) { return false; }
        usz saved = g.env_count;
        AirTyp* value_type = g.expr_type(c.prd);
        if (!is_bool && !is_ptr && m1_integer_type(value_type) && !m1_contextual_int_fits(c.prd, g.int_rep_type(value_type))) { return false; }
        if (!is_bool && !is_ptr) { value_type = g.int_rep_type(value_type); }
        if (!g.bind_typed(c.binder, value, is_bool, is_ptr, value_type)) { return false; }
        bool ok = g.command(c.body, ret_name);
        g.env_count = saved;
        return ok;
    }
    if (c.tag == ACMD_MATCH) { return g.match_cmd(c, ret_name); }
    if (c.tag == ACMD_CUT)
    {
        if (c.prd == null || c.cns == null) { return false; }
        if (c.prd.tag == APRD_MU && c.cns.tag == ACNS_CASE)
        {
            if (c.prd.name == null || c.prd.body == null || c.cns.branch_count != 2) { return false; }
            char* true_label = g.label((char*)"case.true.");
            char* false_label = g.label((char*)"case.false.");
            if (true_label == null || false_label == null) { return false; }
            AirBranch* true_branch = null;
            AirBranch* false_branch = null;
            for (usz i = 0; i < c.cns.branch_count; i++)
            {
                AirBranch* branch = c.cns.branches[i];
                if (branch == null || branch.guard != null || branch.pat == null || branch.pat.tag != APAT_BOOL) { return false; }
                if (branch.pat.ival != 0)
                {
                    if (true_branch != null) { return false; }
                    true_branch = branch;
                }
                else
                {
                    if (false_branch != null) { return false; }
                    false_branch = branch;
                }
            }
            if (true_branch == null || false_branch == null) { return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            g.guard_active = true;
            g.guard_name = c.prd.name;
            g.guard_true_label = true_label;
            g.guard_false_label = false_label;
            g.branch_enter();
            bool condition_ok = g.command(c.prd.body, c.prd.name) && g.terminated;
            g.branch_leave();
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!condition_ok) { return false; }
            g.begin_block(true_label);
            g.terminated = false;
            g.branch_enter();
            bool true_ok = g.command(true_branch.body, ret_name);
            g.branch_leave();
            if (!true_ok || !g.terminated) { return false; }
            g.begin_block(false_label);
            g.terminated = false;
            g.branch_enter();
            bool false_ok = g.command(false_branch.body, ret_name);
            g.branch_leave();
            return false_ok && g.terminated;
        }
        if (c.cns.tag == ACNS_CALL) { return g.call(c.prd, c.cns, ret_name); }
        if (c.prd.tag == APRD_UNIT) { return g.consume_unit(c.cns, ret_name); }
        bool is_bool = g.is_condition(c.prd);
        bool is_ptr = !is_bool && g.is_pointer_value(c.prd);
        char* value = is_bool ? g.condition(c.prd) : (is_ptr ? g.pointer_value(c.prd) : g.prd(c.prd));
        if (g.failed || value == null) { return false; }
        AirTyp* value_type = g.expr_type(c.prd);
        if (!is_bool && !is_ptr)
        {
            value_type = g.int_rep_type(value_type);
            if (m1_integer_type(value_type) && !m1_contextual_int_fits(c.prd, value_type)) { return false; }
        }
        return g.consume(value, is_bool, is_ptr, value_type, c.cns, ret_name);
    }
    if (c.tag == ACMD_HANDLE) { return g.effect_handle(c, ret_name); }
    if (c.tag == ACMD_PERFORM) { return g.effect_perform(c); }
    if (c.tag == ACMD_RESUME)
    {
        g.note_failure(c.source_line, c.source_col, "`resume` escapes the supported effect subset: only one-shot, non-resuming effect handlers are lowerable");
        return false;
    }
    if (c.tag == ACMD_FENCE) { return g.fence_cmd(c); }
    if (c.tag == ACMD_ATOMIC) { return g.atomic_cmd(c, ret_name); }
    if (c.tag == ACMD_SYSCALL) { return g.syscall_cmd(c, ret_name); }
    if (c.tag == ACMD_ASM) { return g.asm_cmd(c, ret_name); }
    return false;
}
fn bool M1Gen.buffer_label_body(M1Gen* g, M1Label* info, char* ret_name)
{
    if (info == null || !info.captured) { return false; }
    // Phase A: the label body itself can contain backedge jumps (a loop
    // label) or jumps into sibling labels (an inner loop jumping to an
    // outer exit label), so edges are only complete once *every* body has
    // been rendered. Render the body into a side buffer with phi names
    // pre-allocated; phase B composes header, phis, and buffered body.
    char* body_buffer = null;
    usz body_size = 0;
    void* side = open_memstream(&body_buffer, &body_size);
    if (side == null) { return false; }
    void* real_out = g.out;
    g.out = side;
    g.env_count = info.env_count;
    for (usz i = 0; i < info.env_count; i++)
    {
        g.env_names[i] = info.env_names[i];
        g.env_slots[i] = null;
        g.env_bools[i] = info.env_bools[i];
        g.env_ptrs[i] = info.env_ptrs[i];
        g.env_types[i] = info.env_types[i];
        g.env_carried[i] = true;
        bool is_param = false;
        for (usz p = 0; p < info.param_count; p++)
        {
            if (info.params[p] != null && same(info.params[p].name, info.env_names[i])) { is_param = true; break; }
        }
        char* phi = is_param ? null : g.tmp();
        if (!is_param && phi == null) { fclose(side); g.out = real_out; g.failed = true; return false; }
        info.env_phis[i] = phi;
        g.env_values[i] = phi != null ? phi : info.env_values[i];
    }
    for (usz i = 0; i < info.param_count; i++) { info.param_phis[i] = g.tmp(); if (info.param_phis[i] == null) { fclose(side); g.out = real_out; g.failed = true; return false; } }
    for (usz i = 0; i < info.param_count; i++)
    {
        AirBinder* p = info.params[i];
        if (p.name != null && !same(p.name, "_"))
        {
            if (!g.bind_rep(p.name, info.param_phis[i], info.param_bools[i], info.param_ptrs[i], p.ty)) { fclose(side); g.out = real_out; return false; }
            g.env_carried[g.env_count - 1] = true;
        }
    }
    bool saved_watch = g.watch_active;
    int saved_watch_count = g.watch_count;
    g.watch_active = false;
    g.cur_block = info.name;
    g.terminated = false;
    bool body_ok = g.command(info.cmd.body, ret_name) && g.terminated;
    g.watch_active = saved_watch;
    g.watch_count = saved_watch_count;
    if (fclose(side) != 0) { g.out = real_out; return false; }
    g.out = real_out;
    if (!body_ok) { free(body_buffer); return false; }
    info.body_buffer = body_buffer;
    info.body_size = body_size;
    info.buffered = true;
    return true;
}
fn bool M1Gen.replay_label_block(M1Gen* g, M1Label* info)
{
    // Phase B (see buffer_label_body): every body has been rendered, so the
    // recorded edge sets are final and phi composition is order-independent.
    if (info == null || !info.buffered) { return false; }
    char* body_buffer = info.body_buffer;
    usz body_size = info.body_size;
    info.body_buffer = null;
    info.body_size = 0;
    info.buffered = false;
    g.begin_block(info.name);
    // Emit the completed phi nodes against the fully recorded edge set. An
    // edgeless label never executes; bind undef so the body still verifies.
    for (usz i = 0; i < info.env_count; i++)
    {
        if (info.env_phis[i] == null) { continue; }
        char* ty = g.llvm_value_type_text(info.env_types[i]);
        if (ty == null) { free(body_buffer); return false; }
        if (info.edge_count == 0)
        {
            // Unreachable label: keep the pre-allocated phi names well-defined
            // so the buffered body still verifies (it can never execute).
            fprintf(g.out, "  %s = freeze %s undef\n", info.env_phis[i], ty);
            continue;
        }
        fprintf(g.out, "  %s = phi %s ", info.env_phis[i], ty);
        for (usz e = 0; e < info.edge_count; e++)
        {
            char** row = info.edges + e * info.edge_stride;
            if (e != 0) { fprintf(g.out, ", "); }
            fprintf(g.out, "[ %s, %%%s ]", row[1 + i] != null ? row[1 + i] : (char*)"undef", row[0]);
        }
        fprintf(g.out, "\n");
    }
    for (usz i = 0; i < info.param_count; i++)
    {
        char* ty = g.llvm_value_type_text(info.params[i].ty);
        if (ty == null) { free(body_buffer); return false; }
        if (info.edge_count == 0)
        {
            fprintf(g.out, "  %s = freeze %s undef\n", info.param_phis[i], ty);
            continue;
        }
        fprintf(g.out, "  %s = phi %s ", info.param_phis[i], ty);
        for (usz e = 0; e < info.edge_count; e++)
        {
            char** row = info.edges + e * info.edge_stride;
            if (e != 0) { fprintf(g.out, ", "); }
            fprintf(g.out, "[ %s, %%%s ]", row[1 + info.env_count + i] != null ? row[1 + info.env_count + i] : (char*)"undef", row[0]);
        }
        fprintf(g.out, "\n");
    }
    if (body_size > 0) { fwrite(body_buffer, 1, body_size, g.out); }
    free(body_buffer);
    return true;
}
fn bool M1Gen.emit_function(M1Gen* g, AirDecl* d)
{
    if (d == null || d.tag != ADECL_DEF || d.def_body == null || !m1_safe_name(d.name) || (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && !m1_return_type(d.ret_ty)) || d.param_count > 64) { return false; }
    if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && !m1_backend_type(d.ret_ty, g.decls, g.decl_count, 0)) { return false; }
    for (usz p = 0; p < d.param_count; p++) { if (d.params[p] == null || (d.params[p].ty != null && d.params[p].ty.tag != ATYP_INFER && !m1_backend_type(d.params[p].ty, g.decls, g.decl_count, 0))) { return false; } }
    g.current_function = d.name;
    g.env_count = 0; g.provenance_count = 0; g.label_count = 0; g.next_tmp = 0; g.next_label = 0; g.next_slot = 0;
    g.default_unsigned = m1_unsigned(d.ret_ty);
    g.default_bits = m1_integer_type(d.ret_ty) ? m1_int_bits(d.ret_ty) : 64;
    g.guard_active = false; g.guard_name = null; g.guard_true_label = null; g.guard_false_label = null;
    g.terminated = false;
    g.has_for = false; g.for_depth = 0; g.seq_depth = 0; g.fx_depth = 0;
    g.watch_active = false; g.watch_count = 0; g.branch_depth = 0; g.watch_branch_depth = 0;
    AirCmd* body = d.def_body;
    char* ret_name = null;
    if (body != null && body.tag == ACMD_MUTILDE) { ret_name = body.binder; body = body.body; }
    while (body != null && body.tag == ACMD_BLOCK) { body = body.body; }
    if (ret_name == null && g.low_profile) { ret_name = (char*)"%ret"; }
    if (ret_name == null) { return false; }
    g.return_type = g.decl_return_type(d);
    g.return_bool = m1_bool_type(g.return_type);
    g.return_ptr = m1_pointer_repr_type(g.return_type);
    g.return_unit = m1_unit_type(g.return_type);
    g.default_unsigned = m1_unsigned(g.return_type);
    g.default_bits = m1_integer_type(g.return_type) ? m1_int_bits(g.return_type) : 64;
    if (!g.collect_cmd(body)) { return false; }
    // Fixed-array `for` copies use dynamic stack scratch. Until cleanup edges are
    // modeled in the CFG, reject named label transfers that could bypass restore.
    if (g.has_for && g.label_count != 0) { return false; }
    char* return_type_ir = g.llvm_abi_return_text(g.return_type);
    if (return_type_ir == null) { return false; }
    usz emitted_param_count = d.param_count;
    if (same(d.name, "main") && d.param_count == 1 && d.params[0] != null && same(d.params[0].name, "_") &&
        (d.params[0].ty == null || d.params[0].ty.tag == ATYP_INFER)) { emitted_param_count = 0; }
    AirTyp*[64] parameter_types;
    for (usz i = 0; i < emitted_param_count; i++)
    {
        if (d.params[i] == null) { return false; }
        parameter_types[i] = g.decl_value_type(d.params[i].ty, g.return_type);
        if (!m1_value_type(parameter_types[i], 0)) { return false; }
    }
    int fn_cc = m1_decl_callconv(d);
    fprintf(g.out, "define %s%s @%s(", fn_cc == 1 ? "fastcc " : "", return_type_ir, m1_link_name(d));
    for (usz i = 0; i < emitted_param_count; i++)
    {
        AirBinder* p = d.params[i];
        if (i != 0) { fprintf(g.out, ", "); }
        fprintf(g.out, "%s %%a%d", g.llvm_abi_argument_text(parameter_types[i]), (int)i);
    }
    fprintf(g.out, ")");
    if (m1_decl_flag(d, "noinline")) { fprintf(g.out, " noinline"); }
    if (m1_decl_flag(d, "alwaysinline")) { fprintf(g.out, " alwaysinline"); }
    if (m1_decl_flag(d, "cold")) { fprintf(g.out, " cold"); }
    if (m1_decl_flag(d, "naked")) { fprintf(g.out, " naked"); }
    char* fn_section = m1_decl_attr_string(d, "section");
    if (fn_section != null) { fprintf(g.out, " section \"%s\"", fn_section); }
    fprintf(g.out, " {\nentry:\n");
    g.cur_block = (char*)"entry";
    for (usz i = 0; i < emitted_param_count; i++)
    {
        AirBinder* p = d.params[i];
        char[32] arg;
        int n = snprintf(&arg[0], 32, (char*)"%%a%d", (int)i);
        if (n < 0 || n >= 32) { return false; }
        char* arg_name = g.arena.dup(&arg[0], (usz)n);
        if (p.name != null && !same(p.name, "_") && !g.bind_typed(p.name, arg_name, m1_bool_type(parameter_types[i]), m1_pointer_repr_type(parameter_types[i]), parameter_types[i])) { return false; }
    }
    if (!g.command(body, ret_name) || !g.terminated)
    {
        if (g.low_profile && g.fail_form == null) { g.note_failure(g.last_line != 0 ? g.last_line : d.source_line, g.last_col != 0 ? g.last_col : d.source_col, (char*)"unsupported AIR 3 command/producer in function body"); }
        return false;
    }    for (usz i = 0; i < g.label_count; i++) { if (!g.buffer_label_body(&g.labels[i], ret_name)) { return false; } }
    for (usz i = 0; i < g.label_count; i++) { if (!g.replay_label_block(&g.labels[i])) { return false; } }
    for (usz i = 0; i < g.label_count; i++) { g.label_drop_edges(&g.labels[i]); }
    fprintf(g.out, "}\n");
    return g.flush_lambdas();
}
fn bool m1_contains_letrec(AirCmd* c, int depth)
{
    if (c == null || depth >= 128) { return false; }
    if (c.tag == ACMD_LETREC) { return true; }
    if (m1_contains_letrec(c.body, depth + 1) || m1_contains_letrec(c.next, depth + 1) ||
        m1_contains_letrec(c.then_c, depth + 1) || m1_contains_letrec(c.else_c, depth + 1) ||
        m1_contains_letrec(c.handled, depth + 1)) { return true; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch != null && (m1_contains_letrec(branch.body, depth + 1) || m1_contains_letrec(branch.guard, depth + 1))) { return true; }
    }
    return false;
}

fn bool append_text(char* out, usz cap, usz* length, char* text)
{
    for (usz i = 0; text[i] != 0; i++)
    {
        if (*length + 1 >= cap) { return false; }
        out[*length] = text[i];
        (*length)++;
    }
    out[*length] = 0;
    return true;
}
fn bool append_shell_word(char* out, usz cap, usz* length, char* word)
{
    if (*length + 2 >= cap) { return false; }
    out[*length] = '\'';
    (*length)++;
    for (usz i = 0; word[i] != 0; i++)
    {
        if (word[i] == '\'')
        {
            if (*length + 4 >= cap) { return false; }
            out[*length] = '\''; out[*length + 1] = '\\'; out[*length + 2] = '\''; out[*length + 3] = '\'';
            *length += 4;
        }
        else
        {
            if (*length + 1 >= cap) { return false; }
            out[*length] = word[i];
            (*length)++;
        }
    }
    if (*length + 2 >= cap) { return false; }
    out[*length] = '\'';
    (*length)++;
    out[*length] = 0;
    return true;
}
fn bool make_executable(char* bitcode, char* output)
{
    char* clang = getenv((char*)"PEAR2_CLANG");
    if (clang == null || clang[0] == 0) { clang = (char*)"clang"; }
    char[16384] command;
    usz length = 0;
    if (!append_shell_word(&command[0], 16384, &length, clang) ||
        !append_text(&command[0], 16384, &length, (char*)" -Wno-override-module ") ||
        !append_shell_word(&command[0], 16384, &length, bitcode) ||
        !append_text(&command[0], 16384, &length, (char*)" -o ") ||
        !append_shell_word(&command[0], 16384, &length, output)) { return false; }
    return system(&command[0]) == 0;
}
// Output modes: 0 = native executable, 1 = LLVM bitcode, 2 = textual LLVM IR.
fn bool make_paths(char* input, int mode, char* out, usz cap, char* temp_ll, char* temp_bc, char* temp_exe)
{
    int slash = -1;
    int dot = -1;
    usz n = 0;
    while (input[n] != 0)
    {
        if (input[n] == '/') { slash = (int)n; }
        if (input[n] == '.') { dot = (int)n; }
        n++;
    }
    usz stem = (usz)(dot > slash ? dot : (int)n);
    if (stem + 4 >= cap) { return false; }
    for (usz i = 0; i < stem; i++) { out[i] = input[i]; }
    if (mode == 0) { out[stem] = 0; }
    else
    {
        out[stem] = '.'; out[stem + 1] = mode == 1 ? 'b' : 'l'; out[stem + 2] = mode == 1 ? 'c' : 'l'; out[stem + 3] = 0;
    }
    long pid = (long)getpid();
    int ll_n = snprintf(temp_ll, cap, (char*)"%s.pear2-%ld.ll", out, pid);
    int bc_n = snprintf(temp_bc, cap, (char*)"%s.pear2-%ld.tmp.bc", out, pid);
    int exe_n = snprintf(temp_exe, cap, (char*)"%s.pear2-%ld.tmp.exe", out, pid);
    return ll_n >= 0 && (usz)ll_n < cap && bc_n >= 0 && (usz)bc_n < cap && exe_n >= 0 && (usz)exe_n < cap;
}
fn void clear_stale_outputs(char* input)
{
    for (int mode = 0; mode <= 2; mode++)
    {
        char[4096] out_path;
        char[4096] ll_path;
        char[4096] bc_tmp;
        char[4096] exe_tmp;
        if (make_paths(input, mode, &out_path[0], 4096, &ll_path[0], &bc_tmp[0], &exe_tmp[0]))
        {
            (void)remove(&out_path[0]);
            (void)remove(&ll_path[0]);
            (void)remove(&bc_tmp[0]);
            (void)remove(&exe_tmp[0]);
        }
    }
}
fn int main(String[] args)
{
    char* input = null;
    bool quiet = false;
    bool emit_exe = true;
    bool emit_ll = false;
    bool mode_seen = false;
    int opt_level = 2;
    bool show_opt_stats = false;
    bool usage_error = false;
    char* bad_option = null;
    for (usz i = 1; i < args.len; i++)
    {
        char* a = (char*)args[i].ptr;
        if (same(a, "--quiet")) { quiet = true; }
        else if (same(a, "--emit-exe"))
        {
            if (mode_seen && (emit_ll || !emit_exe)) { usage_error = true; }
            else { emit_exe = true; emit_ll = false; mode_seen = true; }
        }
        else if (same(a, "--emit-bc"))
        {
            if (mode_seen && (emit_ll || emit_exe)) { usage_error = true; }
            else { emit_exe = false; emit_ll = false; mode_seen = true; }
        }
        // --emit-ll publishes the verified textual IR after the optimization
        // pipeline, so -O0 passes and lowered shapes can be inspected directly.
        else if (same(a, "--emit-ll"))
        {
            if (mode_seen) { usage_error = true; }
            else { emit_exe = false; emit_ll = true; mode_seen = true; }
        }
        else if (same(a, "-O0")) { opt_level = 0; }
        else if (same(a, "-O1")) { opt_level = 1; }
        else if (same(a, "-O2")) { opt_level = 2; }
        else if (same(a, "-O3")) { opt_level = 3; }
        else if (same(a, "--stats")) { show_opt_stats = true; }
        else if (m1_has_prefix(a, "--target="))
        {
            char* tname = a + 9;
            if (same(tname, "x86_64"))
            {
                g_m1_target_ptr_bits = 64;
                g_m1_target_freestanding = false;
                g_m1_target_triple = (char*)"x86_64-unknown-linux-gnu";
                g_m1_target_datalayout = (char*)"e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128";
            }
            else if (same(tname, "wasm32-freestanding"))
            {
                g_m1_target_ptr_bits = 32;
                g_m1_target_freestanding = true;
                g_m1_target_triple = (char*)"wasm32-unknown-unknown";
                g_m1_target_datalayout = (char*)"e-m:e-p:32:32-i64:64-n32:64-S128";
            }
            else { usage_error = true; bad_option = a; }
        }
        else if (a[0] != '-')
        {
            if (input != null) { usage_error = true; }
            else { input = a; }
        }
        else { usage_error = true; bad_option = a; }
    }
    if (usage_error)
    {
        if (input != null) { clear_stale_outputs(input); }
        if (bad_option != null) { printf("pear2c: unsupported option `%s` in PEAR2\n", bad_option); }
        else { printf("pear2c: invalid arguments; choose one input and one output mode\n"); }
        return 2;
    }
    if (input == null)
    {
        printf("usage: pear2c FILE.air [--emit-exe|--emit-bc|--emit-ll] [-O0|-O1|-O2|-O3] [--target=x86_64|wasm32-freestanding] [--stats] [--quiet]\n");
        return 2;
    }
    if (g_m1_target_freestanding && emit_exe)
    {
        clear_stale_outputs(input);
        printf("pear2c: --target=wasm32-freestanding emits LLVM IR or bitcode only; use --emit-ll/--emit-bc and link with a wasm toolchain\n");
        return 2;
    }
    // Clear artifacts from either output mode before any validation can fail.
    clear_stale_outputs(input);
    char[4096] out_path;
    char[4096] ll_path;
    char[4096] bc_tmp;
    char[4096] exe_tmp;
    if (!make_paths(input, emit_ll ? 2 : (emit_exe ? 0 : 1), &out_path[0], 4096, &ll_path[0], &bc_tmp[0], &exe_tmp[0]))
    {
        printf("pear2c: output path too long\n"); return 2;
    }
    // clear_stale_outputs above removes the published and temporary paths for
    // both modes before parsing, so no failure can leave a prior artifact.
    AirArena arena;
    if (!arena.init()) { printf("pear2c: out of memory\n"); return 3; }
    AirModule mod;
    if (!air_read::read_file(input, &arena, &mod, false)) { arena.destroy(); return 1; }
    int[8] counts;
    int invalid = air_verify::verify_module(&mod, &counts[0], true, 0);
    if (invalid != 0)
    {
        printf("pear2c: refusing invalid AIR (violations=%d; V1=%d V2=%d V3=%d V4=%d)\n",
               invalid, counts[0], counts[1], counts[2], counts[3]);
        arena.destroy(); return 1;
    }
    pear2_opt::OptStats opt_stats;
    int opt_passes = 0;
    opt_stats.rewrites = 0;
    opt_stats.constant_folds = 0;
    opt_stats.operand_rewrites = 0;
    opt_stats.strength_reductions = 0;
    opt_stats.shift_combinations = 0;
    opt_stats.branch_reductions = 0;
    opt_stats.let_specializations = 0;
    opt_stats.arena = null;
    if (opt_level > 0)
    {
        // Higher levels repeat the same conservative AIR pass to a bounded
        // fixed point; later passes can expose opportunities created by a
        // prior rewrite without changing the fail-closed rewrite rules.
        int max_opt_iterations = opt_level == 1 ? 1 : (opt_level == 2 ? 4 : 8);
        for (int iteration = 0; iteration < max_opt_iterations; iteration++)
        {
            pear2_opt::OptStats pass_stats = pear2_opt::optimize_module(&mod);
            opt_passes++;
            opt_stats.rewrites += pass_stats.rewrites;
            opt_stats.constant_folds += pass_stats.constant_folds;
            opt_stats.operand_rewrites += pass_stats.operand_rewrites;
            opt_stats.strength_reductions += pass_stats.strength_reductions;
            opt_stats.shift_combinations += pass_stats.shift_combinations;
            opt_stats.branch_reductions += pass_stats.branch_reductions;
            opt_stats.let_specializations += pass_stats.let_specializations;
            if (pass_stats.rewrites == 0) { break; }
        }
        int[8] post_counts;
        int post_invalid = air_verify::verify_module(&mod, &post_counts[0], true, 0);
        if (post_invalid != 0)
        {
            printf("pear2c: optimizer produced invalid AIR (violations=%d; V1=%d V2=%d V3=%d V4=%d)\n",
                   post_invalid, post_counts[0], post_counts[1], post_counts[2], post_counts[3]);
            arena.destroy(); return 3;
        }
    }
    if (show_opt_stats)
    {
        printf("pear2c: optimization %s; rewrites=%u folds=%u operands=%u strength=%u shift-combinations=%u branches=%u let-specializations=%u level=%d passes=%d\n",
               opt_level > 0 ? "enabled" : "disabled", opt_stats.rewrites, opt_stats.constant_folds,
               opt_stats.operand_rewrites, opt_stats.strength_reductions, opt_stats.shift_combinations,
               opt_stats.branch_reductions, opt_stats.let_specializations, opt_level, opt_passes);
    }
    // AIR carries candidate claims, never trusted backend facts; recompute facts
    // on the exact post-optimization graph consumed by the lowering pass.
    air_facts::validate_module(&mod);
    // Struct/codata pre-pass: recover erased (`infer`) struct parameter types
    // from unique field projections before any signature is emitted.
    for (usz i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d != null && d.tag == ADECL_DEF && d.def_body != null)
        {
            m1_infer_record_params_walk(d, d.def_body, &mod.decls[0], mod.decl_count, &arena, 0);
        }
    }
    // The program entry module is the declarations before the first module
    // record. PEAR2 M1 lowers this module's functions; imported/prelude modules
    // remain available in parsed AIR but are not emitted as unrelated bodies.
    usz root_decl_count = mod.decl_count;
    for (usz i = 0; i < mod.decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d != null && d.tag == ADECL_MODULE) { root_decl_count = i; break; }
    }
    AirDecl* main_decl = null;
    int main_count = 0;
    for (usz i = 0; i < root_decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d == null || d.tag == ADECL_MODULE) { continue; }
        if (d.tag == ADECL_DECLARE) { continue; } // unused runtime declarations do not affect this module's emitted ABI
        if (d.tag == ADECL_EFFECT)
        {
            bool effect_ok = d.op_count >= 1 && d.op_count <= 16 && d.typaram_count == 0;
            for (usz oi = 0; effect_ok && oi < d.op_count; oi++)
            {
                AirEffectOp* eo = d.ops[oi];
                if (eo == null || eo.name == null || eo.op_ty == null) { effect_ok = false; break; }
                if (eo.op_ty.tag != ATYP_INFER && !m1_backend_type(eo.op_ty, &mod.decls[0], root_decl_count, 0)) { effect_ok = false; break; }
            }
            if (!effect_ok)
            {
                printf("%s:%d:%d: pear2c: unsupported effect declaration: operations need declared names and backend-lowerable payload types\n", input, d.source_line, d.source_col);
                arena.destroy(); return 3;
            }
            continue;
        }
        if (d.tag == ADECL_GLOBAL)
        {
            if (!mod.low || !m1_safe_name(d.name) || !m1_safe_name(m1_link_name(d)) || d.typaram_count != 0 ||
                !m1_backend_type(d.ret_ty, &mod.decls[0], root_decl_count, 0))
            {
                printf("%s:%d:%d: pear2c: unsupported AIR global declaration `%s`\n", input, d.source_line, d.source_col, d.name == null ? (char*)"?" : d.name);
                arena.destroy(); return 3;
            }
            if (d.is_extern && d.g_init != null)
            {
                printf("%s:%d:%d: pear2c: extern global cannot have an initializer\n", input, d.source_line, d.source_col);
                arena.destroy(); return 3;
            }
            bool attrs_ok = true;
            for (usz ai = 0; ai < d.attr_count; ai++)
            {
                if (!same(d.attr_name[ai], "align") || !d.attr_has_int[ai] || d.attr_int[ai] <= 0 || d.attr_int[ai] > 4096 ||
                    (d.attr_int[ai] & (d.attr_int[ai] - 1)) != 0) { attrs_ok = false; }
            }
            if (!attrs_ok)
            {
                printf("%s:%d:%d: pear2c: unsupported global attribute (only power-of-two align up to 4096 is supported)\n", input, d.source_line, d.source_col);
                arena.destroy(); return 3;
            }
            for (usz j = 0; j < root_decl_count; j++)
            {
                if (j == i) { continue; }
                AirDecl* prior = mod.decls[j];
                if (prior != null && (prior.tag == ADECL_GLOBAL || prior.tag == ADECL_DEF || prior.tag == ADECL_DECLARE) &&
                    same(m1_link_name(prior), m1_link_name(d)))
                {
                    printf("%s:%d:%d: pear2c: duplicate global/link symbol `%s`\n", input, d.source_line, d.source_col, m1_link_name(d));
                    arena.destroy(); return 3;
                }
            }
            continue;
        }
        if (d.tag == ADECL_DATA)
        {
            AirTyp nominal; nominal.tag = ATYP_NOMINAL; nominal.name = d.name; nominal.arg_count = 0;
            if (!m1_backend_type(&nominal, &mod.decls[0], root_decl_count, 0))
            {                printf("%s:%d:%d: pear2c: unsupported data form in declaration `%s`: PEAR2 supports plain product records and nullary tagged enums; payload-bearing, generic, attributed, or otherwise complex variants are unsupported\n", input, d.source_line, d.source_col, d.name == null ? (char*)"?" : d.name);
                arena.destroy(); return 3;
            }
            continue;
        }
        if (d.tag == ADECL_CODATA)
        {
            if (!m1_record_codata_decl(d))
            {
                printf("%s:%d:%d: pear2c: unsupported codata declaration `%s`: PEAR2 lowers codata whose destructors are all nullary projections as product records; parameterized destructors (methods), type parameters, multiplicities, and attributes fail closed\n", input, d.source_line, d.source_col, d.name == null ? (char*)"?" : d.name);
                arena.destroy(); return 3;
            }
            AirTyp nominal; nominal.tag = ATYP_NOMINAL; nominal.name = d.name; nominal.arg_count = 0;
            if (!m1_backend_type(&nominal, &mod.decls[0], root_decl_count, 0))
            {
                printf("%s:%d:%d: pear2c: unsupported codata record field types in declaration `%s`\n", input, d.source_line, d.source_col, d.name == null ? (char*)"?" : d.name);
                arena.destroy(); return 3;
            }
            continue;
        }
        if (d.tag != ADECL_DEF)
        {
            printf("pear2c: PEAR2 supports internal function definitions, simple records, and scalar/aggregate extern declarations; unsupported declaration `%s`\n", d.name == null ? (char*)"?" : d.name);
            arena.destroy(); return 3;
        }
        if (same(d.name, "llvm.trap") || same(d.name, "llvm.assume") || same(d.name, "llvm.stacksave") || same(d.name, "llvm.stackrestore"))
        {
            printf("pear2c: function name `%s` is reserved by a required LLVM intrinsic\n", d.name);
            arena.destroy(); return 3;
        }
        bool signature_types_ok = d.ret_ty == null || d.ret_ty.tag == ATYP_INFER || m1_backend_type(d.ret_ty, &mod.decls[0], root_decl_count, 0);
        for (usz p = 0; p < d.param_count; p++)
        {
            if (d.params[p] == null || (d.params[p].ty != null && d.params[p].ty.tag != ATYP_INFER && !m1_backend_type(d.params[p].ty, &mod.decls[0], root_decl_count, 0))) { signature_types_ok = false; }
        }
        if (!m1_safe_name(d.name) || !m1_function_signature(d) || d.typaram_count != 0 || !signature_types_ok)
        {
            printf("pear2c: unsupported signature for function `%s`\n", d.name == null ? (char*)"?" : d.name);
            arena.destroy(); return 3;
        }
        int def_cc = m1_decl_callconv(d);
        if (def_cc == -1 || def_cc == -2)
        {
            printf("%s:%d:%d: pear2c: %s in function `%s`\n", input, d.source_line, d.source_col,
                   def_cc == -1 ? (char*)"conflicting calling-convention markers" : (char*)"unsupported calling convention (supported: cdecl (default), fastcc)",
                   d.name == null ? (char*)"?" : d.name);
            arena.destroy(); return 3;
        }
        char* def_attr_issue = m1_def_attr_problem(d);
        if (def_attr_issue != null)
        {
            printf("%s:%d:%d: pear2c: %s\n", input, d.source_line, d.source_col, def_attr_issue);
            arena.destroy(); return 3;
        }
        if (same(d.name, "main") && (def_cc != 0 || m1_decl_attr_string(d, "export") != null))
        {
            printf("%s:%d:%d: pear2c: entry point `main` keeps the default calling convention and symbol name (calling-convention/export attributes on `main` are unsupported)\n", input, d.source_line, d.source_col);
            arena.destroy(); return 3;
        }
        if (same(d.name, "main")) { main_decl = d; main_count++; }
    }
    bool ignored_main_parameter = main_decl != null && main_decl.param_count == 1 && main_decl.params[0] != null &&
                                  same(main_decl.params[0].name, "_") &&
                                  (main_decl.params[0].ty == null || main_decl.params[0].ty.tag == ATYP_INFER);
    if (main_count != 1 || main_decl == null || (main_decl.param_count != 0 && !ignored_main_parameter) ||
        (main_decl.ret_ty != null && main_decl.ret_ty.tag != ATYP_INFER && (!m1_integer_type(main_decl.ret_ty) || m1_int_bits(main_decl.ret_ty) != 64)))
    {
        printf("pear2c: M1 requires exactly one zero-argument definition of `main`\n");
        arena.destroy(); return 3;
    }
    void* f = fopen(&ll_path[0], "w");
    if (f == null) { printf("pear2c: cannot create temporary LLVM IR\n"); arena.destroy(); return 3; }
    fprintf(f, mod.low ? (char*)"; PEAR 2: AIR 3 globals, strings and typed-memory lowering\n" : (char*)"; PEAR 2: scalar and local aggregate lowering with direct calls\n");    fprintf(f, "target datalayout = \"%s\"\ntarget triple = \"%s\"\n", g_m1_target_datalayout, g_m1_target_triple);
    fprintf(f, "declare void @llvm.trap()\ndeclare void @llvm.assume(i1 noundef)\ndeclare ptr @llvm.stacksave()\ndeclare void @llvm.stackrestore(ptr)\n");
    M1Gen g;
    g.arena = &arena; g.out = f; g.decls = &mod.decls[0]; g.decl_count = root_decl_count;
    g.env_count = 0; g.label_count = 0; g.next_tmp = 0; g.next_label = 0; g.next_slot = 0; g.default_unsigned = false; g.default_bits = 64; g.return_type = null; g.return_bool = false; g.return_ptr = false; g.return_unit = false; g.terminated = false; g.failed = false;    g.low_profile = mod.low; g.input_path = input; g.current_function = null; g.string_count = 0; g.provenance_count = 0; g.fx_depth = 0; g.fail_line = 0; g.fail_col = 0; g.last_line = 0; g.last_col = 0; g.fail_form = null; g.error = null;
    if (!g.emit_data_types())
    {
        fclose(f); (void)remove(&ll_path[0]);
        printf("pear2c: could not emit supported record type declarations\n");
        arena.destroy(); return 3;
    }
    if (!g.emit_extern_declarations())
    {
        fclose(f); (void)remove(&ll_path[0]);
        printf("pear2c: conflicting declarations for an external ABI symbol\n");
        arena.destroy(); return 3;
    }
    if (!g.emit_globals())
    {
        fclose(f); (void)remove(&ll_path[0]);
        printf("%s:%d:%d: pear2c: %s\n", input, g.fail_line, g.fail_col, g.fail_form == null ? (char*)"unsupported global initializer" : g.fail_form);
        arena.destroy(); return 3;
    }
    bool emitted = true;
    for (usz i = 0; i < root_decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d != null && d.tag == ADECL_DEF && !g.emit_function(d))
        {
            if (g.fail_form == null)
            {
                if (m1_contains_letrec(d.def_body, 0)) { printf("pear2c: unsupported AIR construct `letrec` in function `%s`\n", d.name == null ? (char*)"?" : d.name); }
                else { printf("pear2c: could not lower function `%s` in the supported PEAR2 subset\n", d.name == null ? (char*)"?" : d.name); }
            }
            emitted = false;
            break;
        }
    }
    if (emitted && !g.emit_string_constants()) { emitted = false; }
    if (!emitted)
    {
        fclose(f); (void)remove(&ll_path[0]);
        if (g.fail_form != null) { printf("%s:%d:%d: pear2c: %s\n", input, g.fail_line, g.fail_col, g.fail_form); }
        else { printf("pear2c: unsupported function body; PEAR2 subset includes scalar/aggregate values, direct calls, terminal if/match, and label/jump CFG\n"); }
        arena.destroy(); return 3;
    }
    fclose(f);
    void* ctx = ll_context_create();
    void* mb = null;
    void* m = null;
    char* msg = null;
    int rc = 0;
    // Determinism: LLVMParseIRInContext stamps the module's source identifier
    // with the pid-suffixed temp path; normalize it to the input name so
    // published bitcode is byte-identical across runs.
    usz input_name_len = 0;
    while (input[input_name_len] != 0) { input_name_len++; }
    if (ctx == null || ll_buffer_from_file(&ll_path[0], &mb, &msg) != 0)
    {
        printf("pear2c: LLVM could not read generated IR%s%s\n", msg == null ? "" : ": ", msg == null ? "" : msg);
        rc = 3;
    }
    else if (ll_parse_ir(ctx, mb, &m, &msg) != 0)
    {
        printf("pear2c: generated LLVM IR did not parse%s%s\n", msg == null ? "" : ": ", msg == null ? "" : msg);
        rc = 3;
    }
    else
    {
        // Parsed OK: normalize the source identifier, then verify and write.
        ll_set_source_file_name(m, input, input_name_len);
        if (ll_verify_module(m, 1, &msg) != 0)
        {
            printf("pear2c: LLVM verifier rejected generated module%s%s\n", msg == null ? "" : ": ", msg == null ? "" : msg);
            rc = 3;
        }
        else if (!emit_ll && ll_write_bitcode(m, &bc_tmp[0]) != 0)
        {
            printf("pear2c: LLVM failed to write bitcode\n");
            rc = 3;
        }
    }
    if (msg != null) { ll_message_dispose(msg); }
    if (m != null) { ll_module_dispose(m); }
    if (ctx != null) { ll_context_dispose(ctx); }
    // --emit-ll keeps the verified text IR for publication; other modes
    // publish the bitcode/executable and drop the text form.
    if (rc == 0 && emit_ll)
    {
        if (rename(&ll_path[0], &out_path[0]) != 0)
        {
            printf("pear2c: could not publish LLVM IR atomically\n");
            (void)remove(&ll_path[0]);
            rc = 3;
        }
    }
    else { (void)remove(&ll_path[0]); }
    if (rc == 0 && emit_exe && !emit_ll)
    {
        if (!make_executable(&bc_tmp[0], &exe_tmp[0]))
        {
            printf("pear2c: native linker failed (set PEAR2_CLANG to an LLVM-compatible clang)\n");
            rc = 3;
        }
        else if (rename(&exe_tmp[0], &out_path[0]) != 0)
        {
            printf("pear2c: could not publish executable atomically\n");
            rc = 3;
        }
    }
    else if (rc == 0 && !emit_ll && rename(&bc_tmp[0], &out_path[0]) != 0)
    {
        printf("pear2c: could not publish bitcode atomically\n");
        rc = 3;
    }
    (void)remove(&bc_tmp[0]);
    (void)remove(&exe_tmp[0]);
    if (rc != 0) { (void)remove(&out_path[0]); }
    else if (!quiet) { printf("pear2c: wrote %s\n", &out_path[0]); }
    arena.destroy();
    return rc;
}
