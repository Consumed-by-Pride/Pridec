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
}

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
    usz env_count;
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
    bool failed;
}

fn int m1_int_bits(AirTyp* t)
{
    if (t == null || t.tag == ATYP_INFER || t.tag == ATYP_I64 || t.tag == ATYP_U64 || t.tag == ATYP_ISZ || t.tag == ATYP_USZ) { return 64; }
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
    if (m1_pointer_type(t)) { return 8; }
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
    if (m1_pointer_type(t)) { return 8; }
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
    return t != null && (m1_bool_type(t) || m1_integer_type(t) || m1_float_type(t) || m1_pointer_type(t));
}

fn bool m1_value_type(AirTyp* t, int depth)
{
    if (m1_unit_type(t) || m1_scalar_type(t)) { return true; }
    if (t == null || depth >= 16) { return false; }
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
    if (m1_pointer_type(t)) { return (char*)"ptr"; }
    if (m1_float_type(t)) { return m1_llvm_float(t); }
    return m1_llvm_int(t);
}

fn char* m1_llvm_abi_arg(AirTyp* t)
{
    if (m1_bool_type(t)) { return (char*)"i1 zeroext"; }
    if (m1_pointer_type(t)) { return (char*)"ptr"; }
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
    if (m1_pointer_type(t)) { return (char*)"ptr"; }
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

fn bool m1_function_signature(AirDecl* d)
{
    if (d == null || (d.tag != ADECL_DEF && d.tag != ADECL_DECLARE) || d.typaram_count != 0 || d.param_count > 64) { return false; }
    if (d.tag == ADECL_DEF)
    {
        if (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && !m1_return_type(d.ret_ty)) { return false; }
        if (d.is_extern || d.is_fastcc || d.is_varargs || d.extern_link != null || d.def_body == null) { return false; }
        for (usz i = 0; i < d.param_count; i++)
        {
            if (d.params[i] == null || (d.params[i].ty != null && d.params[i].ty.tag != ATYP_INFER && !m1_value_type(d.params[i].ty, 0))) { return false; }
        }
        return true;
    }
    if (!m1_scalar_type(d.ret_ty) && !m1_unit_type(d.ret_ty)) { return false; }
    for (usz i = 0; i < d.param_count; i++) { if (d.params[i] == null || !m1_scalar_type(d.params[i].ty)) { return false; } }
    return d.is_extern && d.def_body == null && !d.is_fastcc && !d.is_varargs && d.attr_count == 0 &&
           (d.extern_link == null || m1_safe_name(d.extern_link));
}

fn char* m1_link_name(AirDecl* d)
{
    if (d == null) { return null; }
    return d.extern_link == null ? d.name : d.extern_link;
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
    if (i < 0) { return null; }
    char* slot = g.env_slots[(usz)i];
    if (slot == null) { return g.env_values[(usz)i]; }
    char* value = g.tmp();
    char* ty = g.llvm_value_type_text(g.env_types[(usz)i]);
    if (value == null || ty == null) { g.failed = true; return null; }
    fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", value, ty, slot);
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
    return false;
}

fn AirTyp* M1Gen.lookup_type(M1Gen* g, char* name)
{
    long i = (long)g.env_count - 1;
    while (i >= 0)
    {
        if (same(g.env_names[(usz)i], name)) { return g.env_types[(usz)i]; }
        i--;
    }
    return null;
}

fn AirTyp* M1Gen.expr_type(M1Gen* g, AirPrd* p)
{
    if (p == null) { return null; }
    if (p.tag == APRD_UNIT) { return p.ty != null ? p.ty : air_ir::air_mk_typ_simple(g.arena, ATYP_UNIT); }
    if (p.ty != null && p.ty.tag != ATYP_INFER) { return p.ty; }
    if (p.tag == APRD_VAR) { return g.lookup_type(p.name); }
    if (p.tag == APRD_UNOP && p.sub_count == 1) { return g.expr_type(p.subs[0]); }
    if (p.tag == APRD_BINOP && p.sub_count == 2)
    {
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE || p.bop == ABIN_LAND || p.bop == ABIN_LOR) { return p.ty; }
        AirTyp* left = g.expr_type(p.subs[0]);
        AirTyp* right = g.expr_type(p.subs[1]);
        return left != null ? left : right;
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
    g.env_names[g.env_count] = name;
    g.env_values[g.env_count] = value;
    g.env_slots[g.env_count] = null;
    g.env_bools[g.env_count] = is_bool;
    g.env_ptrs[g.env_count] = is_ptr;
    g.env_types[g.env_count] = ty;
    g.env_count++;
    return true;
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

fn bool m1_same_inferred_type(AirTyp* left, AirTyp* right)
{
    return left != null && right != null && m1_value_type_compatible(left, right, 0) && m1_value_type_compatible(right, left, 0);
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
    return null;
}

fn AirTyp* M1Gen.infer_cmd_return_type(M1Gen* g, AirDecl* d, AirCmd* c, char* ret_name, int depth)
{
    if (c == null || depth >= 24) { return null; }
    if (c.tag == ACMD_CUT && m1_cns_returns_to(c.cns, ret_name, 0)) { return g.infer_prd_type(d, c.prd, 0); }
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
    if (target == null || !target.captured) { return false; }
    for (usz j = 0; j < target.env_count; j++)
    {
        bool is_param = false;
        for (usz p = 0; p < target.param_count; p++)
        {
            if (target.params[p] != null && same(target.params[p].name, target.env_names[j])) { is_param = true; break; }
        }
        if (is_param) { continue; }
        char* current_slot = g.lookup_slot(target.env_names[j]);
        if (target.env_slots[j] != null)
        {
            if (current_slot == null || !same(current_slot, target.env_slots[j])) { return false; }
        }
        else
        {
            char* current = g.lookup(target.env_names[j]);
            if (current == null || !same(current, target.env_values[j])) { return false; }
        }
        if (g.lookup_bool(target.env_names[j]) != target.env_bools[j] || g.lookup_ptr(target.env_names[j]) != target.env_ptrs[j]) { return false; }
        if (!target.env_bools[j] && !target.env_ptrs[j] && !m1_value_type_compatible(target.env_types[j], g.lookup_type(target.env_names[j]), 0)) { return false; }
    }
    return true;
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
        if (!m1_safe_name(normalized_label) || same(normalized_label, "entry") || c.mbinder_count > 16 || g.label_count >= 32 || g.label_index(c.binder) >= 0) { return false; }
        M1Label* info = &g.labels[g.label_count];
        info.cmd = c; info.name = normalized_label; info.param_count = c.mbinder_count;
        info.env_count = 0; info.captured = false;
        for (usz i = 0; i < c.mbinder_count; i++)
        {
            AirBinder* p = c.mbinders[i];
            if (p == null || !m1_value_type(p.ty, 0)) { return false; }
            char[32] slot;
            int n = snprintf(&slot[0], 32, (char*)"%%slot%d", g.next_slot);
            g.next_slot++;
            if (n < 0 || n >= 32) { return false; }
            info.params[i] = p;
            info.slots[i] = g.arena.dup(&slot[0], (usz)n);
            info.param_bools[i] = m1_bool_type(p.ty);
            info.param_ptrs[i] = m1_pointer_type(p.ty);
        }
        g.label_count++;
    }
    if (!g.collect_cns(c.cns)) { return false; }
    if (!g.collect_cmd(c.body) || !g.collect_cmd(c.next) || !g.collect_cmd(c.then_c) || !g.collect_cmd(c.else_c) || !g.collect_cmd(c.handled)) { return false; }
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null && !g.collect_cmd(c.branches[i].body)) { return false; } }
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
    if (t != null && (t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY)) { return g.llvm_type_text(t); }
    return m1_llvm_scalar(t);
}

fn char* M1Gen.llvm_abi_return_text(M1Gen* g, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY)) { return g.llvm_type_text(t); }
    return m1_llvm_abi_ret(t);
}

fn char* M1Gen.llvm_abi_argument_text(M1Gen* g, AirTyp* t)
{
    if (t != null && (t.tag == ATYP_UNIT || t.tag == ATYP_TUPLE || t.tag == ATYP_ARRAY)) { return g.llvm_type_text(t); }
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

// Scalar expression lowering. Untyped integer operations use the function
// return width (or i64 when no integer return type supplies a default);
// explicit signedness selects signed or unsigned arithmetic operations.
fn char* M1Gen.prd(M1Gen* g, AirPrd* p)
{
    if (p == null) { g.failed = true; return null; }
    if (p.tag == APRD_STRING || p.tag == APRD_BYTES)
    {
        char* bytes = p.tag == APRD_STRING ? p.name : p.bytes;
        bool string_terminator = p.tag == APRD_STRING && p.ty != null && p.ty.tag == ATYP_ARRAY && p.ty.ival == (long)p.bytes_len + 1;
        if (p.ty == null || p.ty.tag != ATYP_ARRAY || p.ty.arg_count != 1 || (p.ty.ival != (long)p.bytes_len && !string_terminator) || p.ty.ival > 1024 || (p.bytes_len > 0 && bytes == null)) { g.failed = true; return null; }
        AirTyp* byte_type = p.ty.args[0];
        if (byte_type == null || (byte_type.tag != ATYP_I8 && byte_type.tag != ATYP_U8)) { g.failed = true; return null; }
        char* aggregate_ir = g.llvm_type_text(p.ty);
        if (g.failed || aggregate_ir == null) { return null; }
        char* aggregate = (char*)"undef";
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
    if (p.tag == APRD_TUPLE || p.tag == APRD_ARRAY)
    {
        bool is_tuple = p.tag == APRD_TUPLE;
        bool shape_ok = p.ty != null && m1_value_type(p.ty, 0) && p.sub_count <= 1024;
        if (is_tuple) { shape_ok = shape_ok && p.ty.tag == ATYP_TUPLE && p.ty.arg_count == p.sub_count; }
        else { shape_ok = shape_ok && p.ty.tag == ATYP_ARRAY && p.ty.arg_count == 1 && p.ty.ival == (long)p.sub_count; }
        if (!shape_ok) { g.failed = true; return null; }
        char* aggregate_type = g.llvm_type_text(p.ty);
        if (g.failed || aggregate_type == null) { return null; }
        char* aggregate = (char*)"undef";
        for (usz i = 0; i < p.sub_count; i++)
        {
            AirPrd* part = p.subs[i];
            AirTyp* expected = is_tuple ? p.ty.args[i] : p.ty.args[0];
            if (part == null || expected == null) { g.failed = true; return null; }
            bool expected_bool = m1_bool_type(expected);
            bool expected_ptr = m1_pointer_type(expected);
            bool actual_bool = g.is_condition(part);
            bool actual_ptr = !actual_bool && g.is_pointer_value(part);
            if (actual_bool != expected_bool || actual_ptr != expected_ptr) { g.failed = true; return null; }
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
        int value = p.tag == APRD_SIZEOF ? m1_value_size(p.ty, 0) : m1_value_alignment(p.ty, 0);
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
        if (!m1_pointer_type(p.ty)) { g.failed = true; return null; }
        return (char*)"null";
    }
    if (p.tag == APRD_VAR)
    {
        char* value = g.lookup(p.name);
        AirTyp* value_type = g.expr_type(p);
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
            if (from_pointer) { return g.pointer_value(p.subs[0]); }
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
    if (p == null) { return false; }
    // AIR's null literal is contextually typed by its use. Some valid untyped
    // comparisons retain the enclosing bool result type on the literal node;
    // the APRD_NULL tag itself is the reliable pointer discriminator.
    if (p.tag == APRD_NULL) { return true; }
    if (p.tag == APRD_VAR)
    {
        return g.lookup_ptr(p.name) && (p.ty == null || p.ty.tag == ATYP_INFER || m1_pointer_type(p.ty));
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
    if (p.tag == APRD_NULL) { return (char*)"null"; }
    if (p.tag == APRD_VAR) { return g.lookup(p.name); }
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
{
    if (k == null || value == null || (is_bool && is_ptr)) { return false; }
    if (k.tag == ACNS_PROJ || k.tag == ACNS_FST || k.tag == ACNS_SND)
    {
        if (k.tail == null || value_type == null) { return false; }
        bool is_tuple = value_type.tag == ATYP_TUPLE;
        bool is_array = value_type.tag == ATYP_ARRAY && k.tag == ACNS_PROJ && value_type.arg_count == 1;
        if (!is_tuple && !is_array) { return false; }
        long ix = k.tag == ACNS_FST ? 0 : (k.tag == ACNS_SND ? 1 : k.idx);
        usz count = is_tuple ? value_type.arg_count : (usz)value_type.ival;
        if (ix < 0 || (usz)ix >= count) { return false; }
        AirTyp* element_type = is_tuple ? value_type.args[(usz)ix] : value_type.args[0];
        if (!m1_value_type(element_type, 0)) { return false; }
        char* aggregate_ir = g.llvm_type_text(value_type);
        char* element_ir = g.llvm_type_text(element_type);
        char* dst = g.tmp();
        if (g.failed || aggregate_ir == null || element_ir == null || dst == null) { return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", dst, aggregate_ir, value, ix);
        return g.consume(dst, m1_bool_type(element_type), m1_pointer_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_INDEX)
    {
        if (k.prd == null || k.tail == null || is_bool) { return false; }
        AirTyp* index_type = g.expr_type(k.prd);
        AirTyp* index_rep = g.int_rep_type(index_type);
        if (index_rep == null || !g.integer_value_compatible(k.prd, index_rep)) { return false; }
        if (!is_ptr && value_type != null && value_type.tag == ATYP_ARRAY && value_type.arg_count == 1)
        {
            AirTyp* element_type = value_type.args[0];
            int bytes = m1_memory_bytes(element_type);
            if (k.tail.tag == ACNS_STORE || !m1_supported_memory_width(bytes) || k.idx != bytes || value_type.ival <= 0) { return false; }
            char* aggregate_ir = g.llvm_type_text(value_type);
            char* element_ir = g.llvm_type_text(element_type);
            if (g.failed || aggregate_ir == null || element_ir == null) { return false; }
            if (k.prd.tag == APRD_INT)
            {
                if (k.prd.ival < 0 || k.prd.ival >= value_type.ival) { return false; }
                char* dst = g.tmp();
                if (dst == null) { return false; }
                fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", dst, aggregate_ir, value, k.prd.ival);
                return g.consume(dst, m1_bool_type(element_type), m1_pointer_type(element_type), element_type, k.tail, ret_name);
            }
            char* index_value = g.index_as_i64(k.prd, index_type);
            char* slot = g.tmp();
            char* address = g.tmp();
            char* loaded = g.tmp();
            if (g.failed || index_value == null || slot == null || address == null || loaded == null) { return false; }
            fprintf(g.out, "  %s = alloca %s, align 1\n", slot, aggregate_ir);
            fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_ir, value, slot);
            fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 0, i64 %s\n", address, aggregate_ir, slot, index_value);
            fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, element_ir, address);
            return g.consume(loaded, m1_bool_type(element_type), m1_pointer_type(element_type), element_type, k.tail, ret_name);
        }
        AirTyp* element_type = m1_pointee_type(value_type);
        int bytes = m1_memory_bytes(element_type);
        if (!is_ptr || !m1_supported_memory_width(bytes) || k.idx != bytes) { return false; }
        char* index_value = g.index_as_i64(k.prd, index_type);
        char* llvm_element = g.llvm_value_type_text(element_type);
        if (g.failed || index_value == null || llvm_element == null) { return false; }
        char* address = g.tmp();
        if (address == null) { return false; }
        fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 %s\n", address, llvm_element, value, index_value);
        if (k.tail.tag == ACNS_STORE)
        {
            AirTyp* element_ptr = air_ir::air_mk_typ_ptr(g.arena, element_type);
            if (element_ptr == null) { return false; }
            return g.consume(address, false, true, element_ptr, k.tail, ret_name);
        }
        char* loaded = g.tmp();
        if (loaded == null) { return false; }
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, llvm_element, address);
        return g.consume(loaded, m1_bool_type(element_type), m1_pointer_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_DEREF)
    {
        AirTyp* element_type = m1_pointee_type(value_type);
        if (!is_ptr || is_bool || k.tail == null || m1_memory_bytes(element_type) == 0) { return false; }
        char* loaded = g.tmp();
        if (loaded == null) { return false; }
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", loaded, g.llvm_value_type_text(element_type), value);
        return g.consume(loaded, m1_bool_type(element_type), m1_pointer_type(element_type), element_type, k.tail, ret_name);
    }
    if (k.tag == ACNS_STORE)
    {
        AirTyp* element_type = m1_pointee_type(value_type);
        int bytes = m1_memory_bytes(element_type);
        AirTyp* stored_type = g.expr_type(k.prd);
        if (!is_ptr || is_bool || k.prd == null || !m1_supported_memory_width(bytes) || k.idx != bytes) { return false; }
        bool element_bool = m1_bool_type(element_type);
        if (element_bool)
        {
            if (!g.is_condition(k.prd)) { return false; }
            char* stored_bool = g.condition(k.prd);
            if (g.failed || stored_bool == null) { return false; }
            fprintf(g.out, "  store i1 %s, ptr %s, align 1\n", stored_bool, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (m1_pointer_type(element_type))
        {
            if (!g.is_pointer_value(k.prd)) { return false; }
            char* stored_pointer = g.pointer_value(k.prd);
            if (g.failed || stored_pointer == null) { return false; }
            fprintf(g.out, "  store ptr %s, ptr %s, align 1\n", stored_pointer, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (element_type != null && (element_type.tag == ATYP_TUPLE || element_type.tag == ATYP_ARRAY))
        {
            if (!m1_value_type_compatible(element_type, stored_type, 0)) { return false; }
            char* aggregate_type = g.llvm_type_text(element_type);
            char* stored_aggregate = g.prd(k.prd);
            if (g.failed || aggregate_type == null || stored_aggregate == null) { return false; }
            fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_type, stored_aggregate, value);
            return g.consume_unit(k.tail, ret_name);
        }
        if (m1_float_type(element_type))
        {
            if (!m1_float_type(stored_type) || stored_type.tag != element_type.tag) { return false; }
        }
        else
        {
            if (!m1_integer_type(stored_type)) { return false; }
            if (!m1_known_type(stored_type))
            {
                int bits = m1_int_bits(element_type);
                if (k.prd.tag != APRD_INT && g.default_bits != bits) { return false; }
                if (!m1_contextual_int_fits(k.prd, element_type)) { return false; }
            }
        }
        char* stored = g.prd(k.prd);
        if (g.failed || stored == null) { return false; }
        if (!element_bool && !m1_pointer_type(element_type) && !m1_float_type(element_type))
        {
            AirTyp* source_type = g.int_rep_type(stored_type);
            stored = g.convert_integer_width(stored, source_type, element_type);
            if (g.failed || stored == null) { return false; }
        }
        fprintf(g.out, "  store %s %s, ptr %s, align 1\n", m1_llvm_scalar(element_type), stored, value);
        return g.consume_unit(k.tail, ret_name);
    }
    if (k.tag == ACNS_COVAR)
    {
        if (g.guard_active && g.guard_name != null && same(k.name, g.guard_name) && same(ret_name, g.guard_name))
        {
            if (!is_bool || is_ptr || g.guard_true_label == null || g.guard_false_label == null) { return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", value, g.guard_true_label, g.guard_false_label);
            g.terminated = true;
            return true;
        }
        if (!same(k.name, ret_name) || is_bool != g.return_bool || is_ptr != g.return_ptr || g.return_unit) { return false; }
        if (!is_bool && !is_ptr)
        {
            value_type = g.int_rep_type(value_type);
            if (g.return_type != null && (g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY))
            {
                if (!m1_value_type_compatible(g.return_type, value_type, 0)) { return false; }
            }
            else if (!m1_scalar_compatible(g.return_type, value_type)) { return false; }
        }
        char* ret_ir = is_bool ? (char*)"i1" : (is_ptr ? (char*)"ptr" : ((g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY) ? g.llvm_type_text(g.return_type) : m1_llvm_scalar(g.return_type)));
        if (ret_ir == null) { return false; }
        fprintf(g.out, "  ret %s %s\n", ret_ir, value);
        g.terminated = true;
        return true;
    }
    if (k.tag == ACNS_ASCRIBE)
    {
        if (k.tail == null || k.ty == null || is_bool != m1_bool_type(k.ty) || is_ptr != m1_pointer_type(k.ty)) { return false; }
        if (!is_bool && !is_ptr && !m1_value_type_compatible(k.ty, value_type, 0)) { return false; }
        return g.consume(value, is_bool, is_ptr, k.ty, k.tail, ret_name);
    }
    if (k.tag == ACNS_COMU)
    {
        usz saved = g.env_count;
        if (!is_bool && !is_ptr) { value_type = g.int_rep_type(value_type); }
        if (!g.bind_typed(k.bind, value, is_bool, is_ptr, value_type)) { return false; }
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
    if (k == null) { return false; }
    if (k.tag == ACNS_COVAR)
    {
        // The middot continuation is AIR's discard hole, not the function
        // return continuation. A unit value sent here is an ordinary no-op.
        if (same(k.name, (char*)"\xc2\xb7") || g.seq_depth > 0) { return true; }
        if (!g.return_unit || !same(k.name, ret_name)) { return false; }
        fprintf(g.out, "  ret void\n");
        g.terminated = true;
        return true;
    }
    if (k.tag == ACNS_COMU)
    {
        // A unit continuation may name its ignored unit result (for example
        // an administrative AIR binder). Unit has no LLVM value to materialize;
        // leaving the name unbound makes any attempted scalar use fail closed.
        if (k.bind != null && !same(k.bind, "_") && g.lookup(k.bind) != null) { return false; }
        return g.command(k.body, ret_name);
    }
    return false;
}

fn bool M1Gen.call(M1Gen* g, AirPrd* callee, AirCns* k, char* ret_name)
{
    if (callee == null || callee.tag != APRD_VAR || k == null || k.tag != ACNS_CALL) { return false; }
    // A local binding shadows a top-level function name; that case is an
    // indirect call and must not be resolved as a direct global call.
    if (g.lookup(callee.name) != null) { return false; }
    AirDecl* target = g.find_function(callee.name);
    if (target == null || !m1_safe_name(target.name) || !m1_function_signature(target) || !m1_safe_name(m1_link_name(target))) { return false; }
    AirTyp* target_return = g.decl_return_type(target);
    AirTyp*[64] target_params;
    for (usz i = 0; i < target.param_count; i++) { target_params[i] = g.decl_value_type(target.params[i].ty, target_return); }
    AirPrd*[64] args;
    usz argc = 0;
    AirCns* tail = k.tail;
    while (tail != null && tail.tag == ACNS_STACK)
    {
        if (argc >= 64 || tail.prd == null) { return false; }
        args[argc] = tail.prd;
        argc++;
        tail = tail.tail;
    }
    if (argc != target.param_count || tail == null) { return false; }
    char*[64] values;
    for (usz i = 0; i < argc; i++)
    {
        if (target.params[i] == null || !m1_value_type(target_params[i], 0)) { return false; }
        bool expected_bool = m1_bool_type(target_params[i]);
        bool expected_ptr = m1_pointer_type(target_params[i]);
        bool actual_bool = g.is_condition(args[i]);
        bool actual_ptr = !actual_bool && g.is_pointer_value(args[i]);
        if (actual_bool != expected_bool || actual_ptr != expected_ptr) { return false; }
        if (!expected_bool && !expected_ptr)
        {
            bool compatible = m1_float_type(target_params[i]) ? m1_scalar_compatible(target_params[i], g.expr_type(args[i])) : (m1_integer_type(target_params[i]) ? g.integer_value_compatible(args[i], target_params[i]) : m1_value_type_compatible(target_params[i], g.expr_type(args[i]), 0));
            if (!compatible) { return false; }
        }
        values[i] = actual_bool ? g.condition(args[i]) : (actual_ptr ? g.pointer_value(args[i]) : g.prd(args[i]));
        if (g.failed || values[i] == null) { return false; }
    }
    bool result_unit = m1_unit_type(target_return);
    bool result_bool = m1_bool_type(target_return);
    bool result_ptr = m1_pointer_type(target_return);
    char* dst = null;
    if (result_unit) { fprintf(g.out, "  call void @%s(", m1_link_name(target)); }
    else
    {
        dst = g.tmp();
        if (dst == null) { return false; }
        fprintf(g.out, "  %s = call %s @%s(", dst, g.llvm_abi_return_text(target_return), m1_link_name(target));
    }
    for (usz i = 0; i < argc; i++)
    {
        if (i != 0) { fprintf(g.out, ", "); }
        fprintf(g.out, "%s %s", g.llvm_abi_argument_text(target_params[i]), values[i]);
    }
    fprintf(g.out, ")\n");
    if (result_unit) { return g.consume_unit(tail, ret_name); }
    return g.consume(dst, result_bool, result_ptr, target_return, tail, ret_name);
}

fn bool m1_abi_scalar_compatible(AirTyp* a, AirTyp* b)
{
    if (a == null || b == null || m1_bool_type(a) != m1_bool_type(b) || m1_pointer_type(a) != m1_pointer_type(b) || m1_unit_type(a) != m1_unit_type(b) || m1_float_type(a) != m1_float_type(b)) { return false; }
    if (m1_float_type(a)) { return a.tag == b.tag; }
    if (m1_bool_type(a) || m1_pointer_type(a) || m1_unit_type(a)) { return true; }
    if (m1_int_bits(a) != m1_int_bits(b)) { return false; }
    if (m1_int_bits(a) < 32 && m1_unsigned(a) != m1_unsigned(b)) { return false; }
    return true;
}

fn bool m1_same_abi(AirDecl* a, AirDecl* b)
{
    if (a == null || b == null || a.param_count != b.param_count || !m1_abi_scalar_compatible(a.ret_ty, b.ret_ty)) { return false; }
    for (usz i = 0; i < a.param_count; i++)
    {
        if (a.params[i] == null || b.params[i] == null || !m1_abi_scalar_compatible(a.params[i].ty, b.params[i].ty)) { return false; }
    }
    return true;
}

fn bool M1Gen.emit_extern_declarations(M1Gen* g)
{
    for (usz i = 0; i < g.decl_count; i++)
    {
        AirDecl* d = g.decls[i];
        if (d == null || d.tag != ADECL_DECLARE) { continue; }
        if (same(m1_link_name(d), "llvm.trap") || same(m1_link_name(d), "llvm.assume") || same(m1_link_name(d), "llvm.stacksave") || same(m1_link_name(d), "llvm.stackrestore")) { return false; }
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
            if (!m1_same_abi(prior, d)) { return false; }
            duplicate = true;
            break;
        }
        if (duplicate) { continue; }
        for (usz j = 0; j < g.decl_count; j++)
        {
            AirDecl* def = g.decls[j];
            if (def != null && def.tag == ADECL_DEF && !same(def.name, d.name) && same(def.name, m1_link_name(d))) { return false; }
        }
        fprintf(g.out, "declare %s @%s(", m1_llvm_abi_ret(d.ret_ty), m1_link_name(d));
        for (usz j = 0; j < d.param_count; j++)
        {
            if (j != 0) { fprintf(g.out, ", "); }
            fprintf(g.out, "%s", m1_llvm_abi_arg(d.params[j].ty));
        }
        fprintf(g.out, ")\n");
    }
    return true;
}

fn bool M1Gen.bind_aggregate_pattern(M1Gen* g, AirPat* pat, char* value, AirTyp* value_type, int depth)
{
    if (pat == null || value == null || value_type == null || depth >= 16 || !m1_value_type(value_type, 0)) { return false; }
    bool tuple_pattern = pat.tag == APAT_TUPLE && value_type.tag == ATYP_TUPLE;
    bool array_pattern = pat.tag == APAT_ARRAY && value_type.tag == ATYP_ARRAY && value_type.arg_count == 1;
    if (!tuple_pattern && !array_pattern) { return false; }
    usz count = tuple_pattern ? value_type.arg_count : (usz)value_type.ival;
    if (count > 64 || pat.sub_count > count + 1) { return false; }
    usz matched = pat.sub_count;
    bool has_rest = matched > 0 && pat.sub[matched - 1] != null && pat.sub[matched - 1].tag == APAT_REST;
    if (has_rest) { matched--; }
    if ((!has_rest && matched != count) || (has_rest && matched > count)) { return false; }
    char* aggregate_ir = g.llvm_type_text(value_type);
    if (g.failed || aggregate_ir == null) { return false; }
    for (usz i = 0; i < matched; i++)
    {
        AirTyp* element_type = tuple_pattern ? value_type.args[i] : value_type.args[0];
        AirPat* element_pattern = pat.sub[i];
        if (element_type == null || element_pattern == null) { return false; }
        char* element_ir = g.llvm_type_text(element_type);
        char* extracted = g.tmp();
        if (g.failed || element_ir == null || extracted == null) { return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %d\n", extracted, aggregate_ir, value, (int)i);
        if (element_pattern.tag == APAT_TUPLE || element_pattern.tag == APAT_ARRAY)
        {
            if (!g.bind_aggregate_pattern(element_pattern, extracted, element_type, depth + 1)) { return false; }
        }
        else if (element_pattern.tag == APAT_BIND)
        {
            if (element_pattern.name != null && !same(element_pattern.name, "_") && !g.bind_typed(element_pattern.name, extracted, m1_bool_type(element_type), m1_pointer_type(element_type), element_type)) { return false; }
        }
        else if (element_pattern.tag != APAT_WILD) { return false; }
    }
    return true;
}

fn AirPat* m1_match_base_pattern(AirPat* pat)
{
    if (pat == null || pat.tag != APAT_AS) { return pat; }
    if (pat.sub_count != 1 || pat.sub[0] == null) { return null; }
    return pat.sub[0];
}

fn bool m1_valid_match_literal(AirTyp* scrutinee_type, AirPat* pat, bool bool_match, bool float_match, bool char_match, int bits, bool default_unsigned)
{
    if (pat == null) { return false; }
    if (bool_match) { return pat.tag == APAT_BOOL && (pat.ival == 0 || pat.ival == 1); }
    if (float_match)
    {
        return pat.tag == APAT_FLOAT && (pat.ty == null || !m1_known_type(pat.ty) || pat.ty.tag == scrutinee_type.tag);
    }
    if (char_match) { return pat.tag == APAT_CHAR && m1_unicode_scalar(pat.ival); }
    if (pat.tag != APAT_INT || !m1_integer_type(pat.ty)) { return false; }
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
    if (!bool_match && g.is_pointer_value(c.prd)) { return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool float_match = m1_float_type(scrutinee_type);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : ((float_match || char_match) ? 32 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits));
    if (!bool_match && !float_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) { return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null || switch_bits <= 0) { return false; }

    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) { return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null || (pat.tag == APAT_AS && (pat.name == null || pat.name[0] == 0))) { return false; }
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (fallback)
        {
            if ((base_pat.tag == APAT_BIND && branch.guard != null && (base_pat.name == null || same(base_pat.name, "_"))) ||
                (pat.tag == APAT_AS && branch.guard != null && same(pat.name, "_"))) { return false; }
        }
        else if (base_pat.tag == APAT_OR)
        {
            if (base_pat.sub_count != 1 || base_pat.sub[0] == null || base_pat.or_alt == null ||
                !m1_valid_match_literal(scrutinee_type, base_pat.sub[0], bool_match, float_match, char_match, switch_bits, g.default_unsigned) ||
                !m1_valid_match_literal(scrutinee_type, base_pat.or_alt, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) { return false; }
        }
        else if (!m1_valid_match_literal(scrutinee_type, base_pat, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) { return false; }
        if (fallback)
        {
            if (branch.guard == null)
            {
                if (i + 1 != c.branch_count) { return false; }
                final_default = (int)i;
            }
        }
    }
    if (final_default != (int)c.branch_count - 1) { return false; }

    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.guard.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.guard.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) { return false; }
        if (!fallback)
        {
            char* test = null;
            if (base_pat.tag == APAT_OR)
            {
                char* left_test = g.match_literal_test(scrutinee_type, base_pat.sub[0], scrutinee, bool_match, float_match, char_match, switch_bits);
                char* right_test = g.match_literal_test(scrutinee_type, base_pat.or_alt, scrutinee, bool_match, float_match, char_match, switch_bits);
                test = g.tmp();
                if (g.failed || left_test == null || right_test == null || test == null) { return false; }
                fprintf(g.out, "  %s = or i1 %s, %s\n", test, left_test, right_test);
            }
            else { test = g.match_literal_test(scrutinee_type, base_pat, scrutinee, bool_match, float_match, char_match, switch_bits); }
            if (g.failed || test == null) { return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", test, arm_label, next_label);
        }
        else
        {
            fprintf(g.out, "  br label %%%s\n", arm_label);
        }
        g.terminated = true;
        fprintf(g.out, "%s:\n", arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (base_pat.tag == APAT_BIND && base_pat.name != null && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved; return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved; return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved; return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.guard.body.");
            if (body_label == null) { g.env_count = saved; return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved; return false; }
            fprintf(g.out, "%s:\n", body_label);
            g.terminated = false;
        }
        bool body_ok = g.command(branch.body, ret_name);
        g.env_count = saved;
        if (!body_ok || !g.terminated) { return false; }
        if (next_label != null)
        {
            fprintf(g.out, "%s:\n", next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}

fn bool M1Gen.match_aggregate_guarded_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    AirTyp* aggregate_type = g.expr_type(c.prd);
    if (aggregate_type == null || (aggregate_type.tag != ATYP_TUPLE && aggregate_type.tag != ATYP_ARRAY) || !m1_value_type(aggregate_type, 0)) { return false; }
    char* aggregate_value = g.prd(c.prd);
    if (g.failed || aggregate_value == null) { return false; }
    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) { return false; }
        AirPat* base_pat = m1_match_base_pattern(branch.pat);
        if (base_pat == null) { return false; }
        bool aggregate_pat = base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY;
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (!aggregate_pat && !fallback) { return false; }
        if (branch.guard != null && !aggregate_pat && fallback && base_pat.tag == APAT_BIND && (base_pat.name == null || same(base_pat.name, "_"))) { return false; }
        if (branch.guard == null)
        {
            if (i + 1 != c.branch_count) { return false; }
            final_default = (int)i;
        }
    }
    if (final_default != (int)c.branch_count - 1) { return false; }

    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.aggregate.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.aggregate.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) { return false; }
        fprintf(g.out, "  br label %%%s\n", arm_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n", arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (fallback)
        {
            if (base_pat.tag == APAT_BIND && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved; return false; }
        }
        else if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved; return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved; return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved; return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.aggregate.body.");
            if (body_label == null) { g.env_count = saved; return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved; return false; }
            fprintf(g.out, "%s:\n", body_label);
            g.terminated = false;
        }
        bool body_ok = g.command(branch.body, ret_name);
        g.env_count = saved;
        if (!body_ok || !g.terminated) { return false; }
        if (next_label != null)
        {
            fprintf(g.out, "%s:\n", next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}

fn bool M1Gen.match_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (c == null || c.branch_count == 0 || c.branch_count > 64 || c.prd == null) { return false; }
    AirTyp* match_type = g.expr_type(c.prd);
    if (c.branch_count > 1 && match_type != null && (match_type.tag == ATYP_TUPLE || match_type.tag == ATYP_ARRAY)) { return g.match_aggregate_guarded_cmd(c, ret_name); }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null) { continue; }
        AirPat* pat = branch.pat;
        bool aggregate_as = c.branch_count == 1 && pat != null && pat.tag == APAT_AS && pat.sub_count == 1 && pat.sub[0] != null && (pat.sub[0].tag == APAT_TUPLE || pat.sub[0].tag == APAT_ARRAY);
        if (branch.guard != null || (pat != null && (pat.tag == APAT_OR || (pat.tag == APAT_AS && !aggregate_as)))) { return g.match_guarded_cmd(c, ret_name); }
    }
    if (m1_float_type(g.expr_type(c.prd))) { return g.match_guarded_cmd(c, ret_name); }
    if (c.branch_count == 1)
    {
        AirBranch* branch = c.branches[0];
        if (branch == null || branch.guard != null || branch.pat == null) { return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null) { return false; }
        if ((base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY) && c.prd.tag != APRD_UNIT)
        {
            AirTyp* aggregate_type = g.expr_type(c.prd);
            if (aggregate_type == null || !m1_value_type(aggregate_type, 0)) { return false; }
            char* aggregate_value = g.prd(c.prd);
            if (g.failed || aggregate_value == null) { return false; }
            usz saved = g.env_count;
            if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved; return false; }
            if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved; return false; }
            bool ok = g.command(branch.body, ret_name);
            g.env_count = saved;
            return ok;
        }
        char* value = null;
        bool unit_match = false;
        bool bool_match = false;
        bool ptr_match = false;
        if (c.prd.tag == APRD_UNIT)
        {
            if (pat.tag != APAT_TUPLE || pat.sub_count != 0) { return false; }
            unit_match = true;
            value = (char*)"0";
        }
        else if (g.is_condition(c.prd))
        {
            bool_match = true;
            value = g.condition(c.prd);
            if (g.failed || value == null) { return false; }
        }
        else if (c.prd.tag == APRD_VAR)
        {
            value = g.lookup(c.prd.name);
            if (value == null || pat.tag == APAT_TUPLE) { return false; }
            ptr_match = g.lookup_ptr(c.prd.name);
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            ptr_match = g.is_pointer_value(c.prd);
            value = ptr_match ? g.pointer_value(c.prd) : g.prd(c.prd);
            if (g.failed || value == null) { return false; }
        }
        else { return false; }
        usz saved = g.env_count;
        if (pat.tag == APAT_BIND && !g.bind_typed(pat.name, value, bool_match, ptr_match, g.expr_type(c.prd))) { return false; }
        else if (pat.tag != APAT_BIND && pat.tag != APAT_WILD && !(unit_match && pat.tag == APAT_TUPLE)) { return false; }
        bool ok = g.command(branch.body, ret_name);
        g.env_count = saved;
        return ok;
    }

    bool bool_match = g.is_condition(c.prd);
    if (!bool_match && g.is_pointer_value(c.prd)) { return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits);
    if (!bool_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) { return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null) { return false; }
    char*[64] labels;
    long[64] literals;
    int default_index = -1;
    usz literal_count = 0;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.guard != null || branch.pat == null) { return false; }
        AirPat* pat = branch.pat;
        bool int_case = !bool_match && !char_match && pat.tag == APAT_INT;
        bool char_case = char_match && pat.tag == APAT_CHAR;
        if (int_case || char_case || (bool_match && pat.tag == APAT_BOOL))
        {
            if (default_index >= 0) { return false; }
            if (int_case && (!m1_integer_type(pat.ty) || (m1_known_type(pat.ty) && m1_int_bits(pat.ty) != switch_bits) || !m1_int_fits(pat.ival, switch_bits, scrutinee_type != null ? m1_unsigned(scrutinee_type) : g.default_unsigned))) { return false; }
            if (char_case && !m1_unicode_scalar(pat.ival)) { return false; }
            for (usz j = 0; j < literal_count; j++) { if (literals[j] == pat.ival) { return false; } }
            literals[literal_count] = pat.ival;
            labels[i] = g.label((char*)"match.case.");
            if (labels[i] == null) { return false; }
            literal_count++;
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            if (default_index >= 0 || i + 1 != c.branch_count) { return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"match.default.");
            if (labels[i] == null) { return false; }
        }
        else { return false; }
    }
    if (default_index < 0) { return false; }
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
        fprintf(g.out, "%s:\n", labels[i]);
        g.terminated = false;
        if (!g.command(c.branches[i].body, ret_name) || !g.terminated) { return false; }
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    usz saved = g.env_count;
    if (default_pat.tag == APAT_BIND && !g.bind_typed(default_pat.name, scrutinee, bool_match, false, scrutinee_type)) { return false; }
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.env_count = saved;
    return ok && g.terminated;
}

fn bool M1Gen.is_condition(M1Gen* g, AirPrd* p)
{
    if (p == null) { return false; }
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

// Command slice: return expressions, bindings, direct calls, guarded scalar
// matches, structured while loops, terminal if/else, and label/jump CFG.
fn bool M1Gen.command(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (c == null) { return false; }
    if (g.terminated && c.tag != ACMD_LABEL && c.tag != ACMD_SEQ && c.tag != ACMD_BLOCK && c.tag != ACMD_UNSAFE) { return false; }
    if (c.tag == ACMD_SEQ)
    {
        usz saved_env = g.env_count;
        g.seq_depth++;
        bool first_ok = g.command(c.body, ret_name);
        bool next_ok = first_ok && g.command(c.next, ret_name);
        g.seq_depth--;
        g.env_count = saved_env;
        return next_ok;
    }
    if (c.tag == ACMD_LABEL)
    {
        int ix = g.label_index(c.binder);
        if (ix < 0 || g.labels[(usz)ix].cmd != c) { return false; }
        M1Label* info = &g.labels[(usz)ix];
        if (info.captured || g.env_count > 64) { return false; }
        for (usz i = 0; i < g.env_count; i++)
        {
            if (g.env_slots[i] == null)
            {
                char[32] slot_name;
                int slot_len = snprintf(&slot_name[0], 32, (char*)"%%slot%d", g.next_slot);
                g.next_slot++;
                char* llvm_ty = g.llvm_value_type_text(g.env_types[i]);
                if (slot_len < 0 || slot_len >= 32 || llvm_ty == null) { return false; }
                char* slot = g.arena.dup(&slot_name[0], (usz)slot_len);
                fprintf(g.out, "  %s = alloca %s\n", slot, llvm_ty);
                fprintf(g.out, "  store %s %s, ptr %s, align 1\n", llvm_ty, g.env_values[i], slot);
                g.env_slots[i] = slot;
            }
            info.env_names[i] = g.env_names[i];
            info.env_values[i] = g.env_values[i];
            info.env_slots[i] = g.env_slots[i];
            info.env_bools[i] = g.env_bools[i];
            info.env_ptrs[i] = g.env_ptrs[i];
            info.env_types[i] = g.env_types[i];
        }
        info.env_count = g.env_count;
        info.captured = true;
        return true;
    }
    if (c.tag == ACMD_JUMP)
    {
        if (g.for_depth > 0) { return false; }
        int ix = g.label_index(c.target_label);
        if (ix < 0) { return false; }
        M1Label* target = &g.labels[(usz)ix];
        if (c.jump_arg_count != target.param_count) { return false; }
        // A label closes over its captured lexical SSA environment. A changed
        // binding must be represented by an explicit label parameter.
        if (!g.label_environment_unchanged(target)) { return false; }
        char*[16] values;
        bool[16] value_bools;
        bool[16] value_ptrs;
        for (usz i = 0; i < c.jump_arg_count; i++)
        {
            values[i] = g.lookup(c.jump_args[i]);
            value_bools[i] = g.lookup_bool(c.jump_args[i]);
            value_ptrs[i] = g.lookup_ptr(c.jump_args[i]);
            if (values[i] == null || value_bools[i] != target.param_bools[i] || value_ptrs[i] != target.param_ptrs[i]) { return false; }
            if (!value_bools[i] && !value_ptrs[i] && !m1_value_type_compatible(target.params[i].ty, g.lookup_type(c.jump_args[i]), 0)) { return false; }
        }
        for (usz i = 0; i < c.jump_arg_count; i++) { fprintf(g.out, "  store %s %s, ptr %s\n", g.llvm_value_type_text(target.params[i].ty), values[i], target.slots[i]); }
        fprintf(g.out, "  br label %%%s\n", target.name);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_BREAK || c.tag == ACMD_CONTINUE)
    {
        if (g.for_depth > 0) { return false; }
        int ix = g.label_index(c.target_label);
        if (ix < 0) { return false; }
        M1Label* target = &g.labels[(usz)ix];
        if (target.param_count != 0 || !g.label_environment_unchanged(target)) { return false; }
        fprintf(g.out, "  br label %%%s\n", target.name);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_NOP) { return true; }
    if (c.tag == ACMD_RET)
    {
        if (c.prd != null && c.prd.tag == APRD_UNIT)
        {
            if (!g.return_unit) { return false; }
            fprintf(g.out, "  ret void\n");
            g.terminated = true;
            return true;
        }
        bool is_bool = g.is_condition(c.prd);
        bool is_ptr = !is_bool && g.is_pointer_value(c.prd);
        AirTyp* value_type = g.expr_type(c.prd);
        char* value = is_bool ? g.condition(c.prd) : (is_ptr ? g.pointer_value(c.prd) : g.prd(c.prd));
        if (g.failed || value == null || is_bool != g.return_bool || is_ptr != g.return_ptr || g.return_unit) { return false; }
        if (!is_bool && !is_ptr) { value_type = g.int_rep_type(value_type); }
        if (!is_bool && !is_ptr)
        {
            bool compatible = (g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY) ? m1_value_type_compatible(g.return_type, value_type, 0) : (m1_float_type(g.return_type) ? m1_scalar_compatible(g.return_type, value_type) : g.integer_value_compatible(c.prd, g.return_type));
            if (!compatible) { return false; }
        }
        char* return_ir = is_bool ? (char*)"i1" : (is_ptr ? (char*)"ptr" : ((g.return_type.tag == ATYP_TUPLE || g.return_type.tag == ATYP_ARRAY) ? g.llvm_type_text(g.return_type) : m1_llvm_scalar(g.return_type)));
        if (return_ir == null) { return false; }
        fprintf(g.out, "  ret %s %s\n", return_ir, value);
        g.terminated = true;
        return true;
    }
    if (c.tag == ACMD_ASSUME)
    {
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) { return false; }
        fprintf(g.out, "  call void @llvm.assume(i1 %s)\n", condition);
        return true;
    }
    if (c.tag == ACMD_ASSERT)
    {
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) { return false; }
        char* pass_label = g.label((char*)"assert.pass.");
        char* fail_label = g.label((char*)"assert.fail.");
        if (pass_label == null || fail_label == null) { return false; }
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", condition, pass_label, fail_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n  call void @llvm.trap()\n  unreachable\n", fail_label);
        fprintf(g.out, "%s:\n", pass_label);
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
        char* index_slot = g.tmp();
        char* header_label = g.label((char*)"for.header.");
        char* body_label = g.label((char*)"for.body.");
        char* exit_label = g.label((char*)"for.exit.");
        if (g.failed || aggregate_ir == null || element_ir == null || array_value == null || stack_mark == null || array_slot == null || index_slot == null || header_label == null || body_label == null || exit_label == null) { return false; }
        fprintf(g.out, "  %s = call ptr @llvm.stacksave()\n", stack_mark);
        fprintf(g.out, "  %s = alloca %s, align 1\n", array_slot, aggregate_ir);
        fprintf(g.out, "  store %s %s, ptr %s, align 1\n", aggregate_ir, array_value, array_slot);
        fprintf(g.out, "  %s = alloca i64, align 8\n", index_slot);
        fprintf(g.out, "  store i64 0, ptr %s, align 8\n", index_slot);
        fprintf(g.out, "  br label %%%s\n", header_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n", header_label);
        g.terminated = false;
        char* index = g.tmp();
        char* in_range = g.tmp();
        if (index == null || in_range == null) { return false; }
        fprintf(g.out, "  %s = load i64, ptr %s, align 8\n", index, index_slot);
        fprintf(g.out, "  %s = icmp ult i64 %s, %ld\n", in_range, index, array_type.ival);
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", in_range, body_label, exit_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n", body_label);
        g.terminated = false;
        char* address = g.tmp();
        char* item = g.tmp();
        if (address == null || item == null) { return false; }
        fprintf(g.out, "  %s = getelementptr %s, ptr %s, i64 0, i64 %s\n", address, aggregate_ir, array_slot, index);
        fprintf(g.out, "  %s = load %s, ptr %s, align 1\n", item, element_ir, address);
        usz saved_env = g.env_count;
        if (c.binder != null && !same(c.binder, "_") && !g.bind_typed(c.binder, item, m1_bool_type(element_type), m1_pointer_type(element_type), element_type)) { g.env_count = saved_env; return false; }
        g.for_depth++;
        bool body_ok = g.command(c.body, ret_name);
        g.for_depth--;
        g.env_count = saved_env;
        if (!body_ok) { return false; }
        if (!g.terminated)
        {
            char* next_index = g.tmp();
            if (next_index == null) { return false; }
            fprintf(g.out, "  %s = add i64 %s, 1\n", next_index, index);
            fprintf(g.out, "  store i64 %s, ptr %s, align 8\n", next_index, index_slot);
            fprintf(g.out, "  br label %%%s\n", header_label);
            g.terminated = true;
        }
        fprintf(g.out, "%s:\n", exit_label);
        fprintf(g.out, "  call void @llvm.stackrestore(ptr %s)\n", stack_mark);
        g.terminated = false;
        return true;
    }
    if (c.tag == ACMD_WHILE)
    {
        char* header_label = g.label((char*)"while.header.");
        char* body_label = g.label((char*)"while.body.");
        char* exit_label = g.label((char*)"while.exit.");
        if (header_label == null || body_label == null || exit_label == null) { return false; }
        fprintf(g.out, "  br label %%%s\n", header_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n", header_label);
        g.terminated = false;
        char* condition = g.condition(c.prd);
        if (g.failed || condition == null) { return false; }
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", condition, body_label, exit_label);
        g.terminated = true;
        fprintf(g.out, "%s:\n", body_label);
        g.terminated = false;
        if (!g.command(c.body, ret_name)) { return false; }
        if (!g.terminated)
        {
            fprintf(g.out, "  br label %%%s\n", header_label);
            g.terminated = true;
        }
        fprintf(g.out, "%s:\n", exit_label);
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
        fprintf(g.out, "%s:\n", then_label);
        g.terminated = false;
        if (!g.command(c.then_c, ret_name) || !g.terminated) { return false; }
        fprintf(g.out, "%s:\n", else_label);
        g.terminated = false;
        bool else_ok = g.command(c.else_c, ret_name);
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
            bool condition_ok = g.command(c.prd.body, c.prd.name) && g.terminated;
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!condition_ok) { return false; }
            fprintf(g.out, "%s:\n", true_label);
            g.terminated = false;
            if (!g.command(true_branch.body, ret_name) || !g.terminated) { return false; }
            fprintf(g.out, "%s:\n", false_label);
            g.terminated = false;
            return g.command(false_branch.body, ret_name) && g.terminated;
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
    return false;
}

fn bool M1Gen.emit_label_block(M1Gen* g, M1Label* info, char* ret_name)
{
    if (info == null || !info.captured) { return false; }
    g.env_count = info.env_count;
    for (usz i = 0; i < info.env_count; i++)
    {
        g.env_names[i] = info.env_names[i];
        g.env_values[i] = info.env_values[i];
        g.env_slots[i] = info.env_slots[i];
        g.env_bools[i] = info.env_bools[i];
        g.env_ptrs[i] = info.env_ptrs[i];
        g.env_types[i] = info.env_types[i];
    }
    fprintf(g.out, "%s:\n", info.name);
    g.terminated = false;
    for (usz i = 0; i < info.param_count; i++)
    {
        AirBinder* p = info.params[i];
        char* value = g.tmp();
        if (value == null || info.slots[i] == null) { return false; }
        bool is_bool = info.param_bools[i];
        bool is_ptr = info.param_ptrs[i];
        fprintf(g.out, "  %s = load %s, ptr %s\n", value, g.llvm_value_type_text(p.ty), info.slots[i]);
        if (p.name != null && !same(p.name, "_") && !g.bind_rep(p.name, value, is_bool, is_ptr, p.ty)) { return false; }
    }
    return g.command(info.cmd.body, ret_name) && g.terminated;
}

fn bool M1Gen.emit_function(M1Gen* g, AirDecl* d)
{
    if (d == null || d.tag != ADECL_DEF || d.def_body == null || !m1_safe_name(d.name) || (d.ret_ty != null && d.ret_ty.tag != ATYP_INFER && !m1_return_type(d.ret_ty)) || d.param_count > 64) { return false; }
    g.env_count = 0; g.label_count = 0; g.next_tmp = 0; g.next_label = 0; g.next_slot = 0;
    g.default_unsigned = m1_unsigned(d.ret_ty);
    g.default_bits = m1_integer_type(d.ret_ty) ? m1_int_bits(d.ret_ty) : 64;
    g.guard_active = false; g.guard_name = null; g.guard_true_label = null; g.guard_false_label = null;
    g.terminated = false;
    g.has_for = false; g.for_depth = 0; g.seq_depth = 0;
    AirCmd* body = d.def_body;
    char* ret_name = null;
    if (body != null && body.tag == ACMD_MUTILDE) { ret_name = body.binder; body = body.body; }
    while (body != null && body.tag == ACMD_BLOCK) { body = body.body; }
    if (ret_name == null) { return false; }
    g.return_type = g.decl_return_type(d);
    g.return_bool = m1_bool_type(g.return_type);
    g.return_ptr = m1_pointer_type(g.return_type);
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
    fprintf(g.out, "define %s @%s(", return_type_ir, d.name);
    for (usz i = 0; i < emitted_param_count; i++)
    {
        AirBinder* p = d.params[i];
        if (i != 0) { fprintf(g.out, ", "); }
        fprintf(g.out, "%s %%a%d", g.llvm_abi_argument_text(parameter_types[i]), (int)i);
    }
    fprintf(g.out, ") {\nentry:\n");
    for (usz i = 0; i < g.label_count; i++)
    {
        for (usz j = 0; j < g.labels[i].param_count; j++) { fprintf(g.out, "  %s = alloca %s\n", g.labels[i].slots[j], g.llvm_value_type_text(g.labels[i].params[j].ty)); }
    }
    for (usz i = 0; i < emitted_param_count; i++)
    {
        AirBinder* p = d.params[i];
        char[32] arg;
        int n = snprintf(&arg[0], 32, (char*)"%%a%d", (int)i);
        if (n < 0 || n >= 32) { return false; }
        char* arg_name = g.arena.dup(&arg[0], (usz)n);
        if (p.name != null && !same(p.name, "_") && !g.bind_typed(p.name, arg_name, m1_bool_type(parameter_types[i]), m1_pointer_type(parameter_types[i]), parameter_types[i])) { return false; }
    }
    if (!g.command(body, ret_name) || !g.terminated) { return false; }
    for (usz i = 0; i < g.label_count; i++) { if (!g.emit_label_block(&g.labels[i], ret_name)) { return false; } }
    fprintf(g.out, "}\n");
    return true;
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

fn bool make_paths(char* input, bool emit_exe, char* out, usz cap, char* temp_ll, char* temp_bc, char* temp_exe)
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
    if (emit_exe) { out[stem] = 0; }
    else { out[stem] = '.'; out[stem + 1] = 'b'; out[stem + 2] = 'c'; out[stem + 3] = 0; }
    long pid = (long)getpid();
    int ll_n = snprintf(temp_ll, cap, (char*)"%s.pear2-%ld.ll", out, pid);
    int bc_n = snprintf(temp_bc, cap, (char*)"%s.pear2-%ld.tmp.bc", out, pid);
    int exe_n = snprintf(temp_exe, cap, (char*)"%s.pear2-%ld.tmp.exe", out, pid);
    return ll_n >= 0 && (usz)ll_n < cap && bc_n >= 0 && (usz)bc_n < cap && exe_n >= 0 && (usz)exe_n < cap;
}

fn void clear_stale_outputs(char* input)
{
    for (int mode = 0; mode <= 1; mode++)
    {
        char[4096] out_path;
        char[4096] ll_path;
        char[4096] bc_tmp;
        char[4096] exe_tmp;
        if (make_paths(input, mode == 1, &out_path[0], 4096, &ll_path[0], &bc_tmp[0], &exe_tmp[0]))
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
            if (mode_seen && !emit_exe) { usage_error = true; }
            else { emit_exe = true; mode_seen = true; }
        }
        else if (same(a, "--emit-bc"))
        {
            if (mode_seen && emit_exe) { usage_error = true; }
            else { emit_exe = false; mode_seen = true; }
        }
        else if (same(a, "-O0")) { opt_level = 0; }
        else if (same(a, "-O1")) { opt_level = 1; }
        else if (same(a, "-O2")) { opt_level = 2; }
        else if (same(a, "-O3")) { opt_level = 3; }
        else if (same(a, "--stats")) { show_opt_stats = true; }
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
        printf("usage: pear2c FILE.air [--emit-exe|--emit-bc] [-O0|-O1|-O2|-O3] [--stats] [--quiet]\n");
        return 2;
    }

    // Clear artifacts from either output mode before any validation can fail.
    clear_stale_outputs(input);
    char[4096] out_path;
    char[4096] ll_path;
    char[4096] bc_tmp;
    char[4096] exe_tmp;
    if (!make_paths(input, emit_exe, &out_path[0], 4096, &ll_path[0], &bc_tmp[0], &exe_tmp[0]))
    {
        printf("pear2c: output path too long\n"); return 2;
    }
    // clear_stale_outputs above removes the published and temporary paths for
    // both modes before parsing, so no failure can leave a prior artifact.
    AirArena arena;
    if (!arena.init()) { printf("pear2c: out of memory\n"); return 3; }
    AirModule mod;
    if (!air_read::read_file(input, &arena, &mod, false)) { arena.destroy(); return 1; }
    if (mod.low)
    {
        printf("pear2c: AIR 3 low profile is not PEAR 2 input; expected untyped AIR 2.x\n");
        arena.destroy(); return 1;
    }

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
        if (d.tag != ADECL_DEF)
        {
            printf("pear2c: PEAR2 supports internal function definitions and scalar extern declarations; unsupported declaration `%s`\n", d.name == null ? (char*)"?" : d.name);
            arena.destroy(); return 3;
        }
        if (same(d.name, "llvm.trap") || same(d.name, "llvm.assume") || same(d.name, "llvm.stacksave") || same(d.name, "llvm.stackrestore"))
        {
            printf("pear2c: function name `%s` is reserved by a required LLVM intrinsic\n", d.name);
            arena.destroy(); return 3;
        }
        if (!m1_safe_name(d.name) || !m1_function_signature(d) || d.typaram_count != 0)
        {
            printf("pear2c: unsupported signature for function `%s`\n", d.name == null ? (char*)"?" : d.name);
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
    fprintf(f, "; PEAR 2: scalar and local aggregate lowering with direct calls\n");
    fprintf(f, "declare void @llvm.trap()\ndeclare void @llvm.assume(i1 noundef)\ndeclare ptr @llvm.stacksave()\ndeclare void @llvm.stackrestore(ptr)\n");
    M1Gen g;
    g.arena = &arena; g.out = f; g.decls = &mod.decls[0]; g.decl_count = root_decl_count;
    g.env_count = 0; g.label_count = 0; g.next_tmp = 0; g.next_label = 0; g.next_slot = 0; g.default_unsigned = false; g.default_bits = 64; g.return_type = null; g.return_bool = false; g.return_ptr = false; g.return_unit = false; g.terminated = false; g.failed = false;
    if (!g.emit_extern_declarations())
    {
        fclose(f); (void)remove(&ll_path[0]);
        printf("pear2c: conflicting declarations for an external scalar symbol\n");
        arena.destroy(); return 3;
    }
    bool emitted = true;
    for (usz i = 0; i < root_decl_count; i++)
    {
        AirDecl* d = mod.decls[i];
        if (d != null && d.tag == ADECL_DEF && !g.emit_function(d))
        {
            printf("pear2c: could not lower function `%s` in the supported PEAR2 subset\n", d.name == null ? (char*)"?" : d.name);
            emitted = false;
            break;
        }
    }
    if (!emitted)
    {
        fclose(f); (void)remove(&ll_path[0]);
        printf("pear2c: unsupported function body; PEAR2 subset includes scalar/aggregate values, direct calls, terminal if/match, and label/jump CFG\n");
        arena.destroy(); return 3;
    }
    fclose(f);

    void* ctx = ll_context_create();
    void* mb = null;
    void* m = null;
    char* msg = null;
    int rc = 0;
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
    else if (ll_verify_module(m, 1, &msg) != 0)
    {
        printf("pear2c: LLVM verifier rejected generated module%s%s\n", msg == null ? "" : ": ", msg == null ? "" : msg);
        rc = 3;
    }
    else if (ll_write_bitcode(m, &bc_tmp[0]) != 0)
    {
        printf("pear2c: LLVM failed to write bitcode\n");
        rc = 3;
    }
    if (msg != null) { ll_message_dispose(msg); }
    if (m != null) { ll_module_dispose(m); }
    if (ctx != null) { ll_context_dispose(ctx); }
    (void)remove(&ll_path[0]);
    if (rc == 0 && emit_exe)
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
    else if (rc == 0 && rename(&bc_tmp[0], &out_path[0]) != 0)
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
