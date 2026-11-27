// PEAR 2 type representation helpers. Kept in module pear2c so the existing
// M1Gen backend and the extracted type rules share one compilation unit/API.
module pear2c;
import air_ir;

// ── libc ──────────────────────────────────────────────────────────────────
// One declaration per symbol for the whole `pear2c` module. C3 has a single
// scope per module across its files, so four files each repeating
// `extern fn void* malloc(usz)` is a redeclaration, not four declarations --
// keep them here and nowhere else.
extern fn void* malloc(usz size_);
extern fn void  free(void* ptr);
extern fn void* memset(void* dst, int value, usz n);
extern fn void* memcpy(void* dst, void* src, usz n);

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
