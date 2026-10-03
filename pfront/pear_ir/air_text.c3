// ============================================================================
// air_text.c3 — shared vocabulary of the AIR 2.0 text format.
// ----------------------------------------------------------------------------
// The writer (air_write) and the reader (air_read) must agree on every keyword,
// every operator spelling and every quoting rule. Keeping those in ONE place is
// what lets the round-trip test mean something: there is no second copy that can
// drift. The grammar itself is specified in docs/specs/AIR.md; this file is the
// executable vocabulary behind it.
// ============================================================================
module air_text;
import air_ir;

const int AIR_TEXT_MAJOR = 2;
const int AIR_TEXT_MINOR = 0;

fn bool streq(char* a, char* b)
{
    if (a == null || b == null) { return a == b; }
    usz i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}

// Every word that introduces a production. A name equal to one of these is
// written quoted (`mu`) so the reader never has to guess.
fn bool is_reserved(char* s)
{
    static char*[157] kws = {
        // header / declarations
        "air", "import", "module", "declare", "def", "defco", "data", "codata", "effect",
        "pub", "extern", "fastcc", "varargs", "link", "facts", "readonly", "nocapture",
        "ast_final", "air_checked", "glob", "as", "ctor", "op", "guard",
        // multiplicities / binders
        "mut", "unr", "lin", "aff", "exact",
        // producers
        "con", "true", "false", "null", "unit", "tuple", "record", "array", "inl", "inr",
        "lam", "mu", "cometa", "coerce", "sizeof", "alignof", "offsetof", "reify", "eval",
        "quote", "splice", "poison", "unreachable", "char",
        // commands
        "mu~", "jump", "seq", "block", "unsafe", "unchecked", "comptime", "defer", "while",
        "let", "letrec", "in", "if", "else", "for", "match", "handle", "perform", "resume",
        "assert", "assume", "ub", "trap", "nop", "ret", "break", "continue", "label", "asm",
        "syscall", "atomic", "fence", "nil", "intel", "att", "dense",
        // consumers
        "fst", "snd", "proj", "field", "index", "deref", "store", "call", "case", "cocase",
        "comu", "default", "subst", "share", "erase",
        // patterns
        "bind", "or", "ref", "rest", "range",
        // types
        "i8", "i16", "i32", "i64", "i128", "isz", "u8", "u16", "u32", "u64", "u128", "usz",
        "f16", "f32", "f64", "f128", "bool", "str", "bytes", "bottom", "infer", "self",
        "nominal", "path", "tvar", "arrow", "slice", "ptr", "refmut", "sum", "union",
        "intersect", "neg", "forall", "exists", "bang", "query", "mult", "effrow", "typeof",
        "refine", "generic", "tail", "invalid",
        // AIR 3.0
        "alloca", "load", "gep", "global"
    };
    for (usz i = 0; i < 157; i++)
    {
        if (kws[i] == null) { break; }
        if (streq(kws[i], s)) { return true; }
    }
    return false;
}

fn bool is_bare_start(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '%';
}
fn bool is_bare_rest(char c)
{
    return is_bare_start(c) || (c >= '0' && c <= '9');
}
fn bool is_bare_ident(char* s)
{
    if (s == null || s[0] == 0) { return false; }
    if (!is_bare_start(s[0])) { return false; }
    usz i = 1;
    while (s[i] != 0) { if (!is_bare_rest(s[i])) { return false; } i++; }
    return !is_reserved(s);
}

// ── Operator spellings ────────────────────────────────────────────────────
fn char* binop_name(AirBinop op)
{
    switch (op)
    {
        case ABIN_ADD:  return "add";
        case ABIN_SUB:  return "sub";
        case ABIN_MUL:  return "mul";
        case ABIN_DIV:  return "div";
        case ABIN_MOD:  return "mod";
        case ABIN_AND:  return "and";
        case ABIN_OR:   return "or";
        case ABIN_XOR:  return "xor";
        case ABIN_SHL:  return "shl";
        case ABIN_SHR:  return "shr";
        case ABIN_LAND: return "land";
        case ABIN_LOR:  return "lor";
        case ABIN_EQ:   return "eq";
        case ABIN_NEQ:  return "neq";
        case ABIN_LT:   return "lt";
        case ABIN_GT:   return "gt";
        case ABIN_LE:   return "le";
        case ABIN_GE:   return "ge";
        case ABIN_PIPE: return "pipe";
    }
}
fn int binop_from_name(char* s)
{
    for (int i = 0; i <= 18; i++)
    {
        if (streq(binop_name((AirBinop)i), s)) { return i; }
    }
    return -1;
}
fn char* unop_name(AirUnop op)
{
    switch (op)
    {
        case AUN_NEG:    return "neg";
        case AUN_NOT:    return "not";
        case AUN_BITNOT: return "bitnot";
        case AUN_DEREF:  return "deref";
        case AUN_REF:    return "ref";
        case AUN_ADDR:   return "addr";
        case AUN_COMULT: return "comult";
    }
}
fn int unop_from_name(char* s)
{
    for (int i = 0; i <= 6; i++)
    {
        if (streq(unop_name((AirUnop)i), s)) { return i; }
    }
    return -1;
}

// ── Type tag spellings (the keyword that heads every type) ────────────────
fn char* typ_kw(AirTypTag t)
{
    switch (t)
    {
        case ATYP_INVALID:     return "invalid";
        case ATYP_NOMINAL:     return "nominal";
        case ATYP_PATH:        return "path";
        case ATYP_VAR:         return "tvar";
        case ATYP_ARROW:       return "arrow";
        case ATYP_TUPLE:       return "tuple";
        case ATYP_RECORD:      return "record";
        case ATYP_ARRAY:       return "array";
        case ATYP_SLICE:       return "slice";
        case ATYP_PTR:         return "ptr";
        case ATYP_REF:         return "ref";
        case ATYP_REF_MUT:     return "refmut";
        case ATYP_SUM:         return "sum";
        case ATYP_UNION:       return "union";
        case ATYP_INTERSECT:   return "intersect";
        case ATYP_NEGATION:    return "neg";
        case ATYP_BOTTOM:      return "bottom";
        case ATYP_UNIT:        return "unit";
        case ATYP_INFER:       return "infer";
        case ATYP_FORALL:      return "forall";
        case ATYP_EXISTS:      return "exists";
        case ATYP_BANG:        return "bang";
        case ATYP_QUERY:       return "query";
        case ATYP_MULT:        return "mult";
        case ATYP_EFFROW:      return "effrow";
        case ATYP_TYPEOF:      return "typeof";
        case ATYP_REFINE:      return "refine";
        case ATYP_I8:          return "i8";
        case ATYP_I16:         return "i16";
        case ATYP_I32:         return "i32";
        case ATYP_I64:         return "i64";
        case ATYP_I128:        return "i128";
        case ATYP_ISZ:         return "isz";
        case ATYP_U8:          return "u8";
        case ATYP_U16:         return "u16";
        case ATYP_U32:         return "u32";
        case ATYP_U64:         return "u64";
        case ATYP_U128:        return "u128";
        case ATYP_USZ:         return "usz";
        case ATYP_F16:         return "f16";
        case ATYP_F32:         return "f32";
        case ATYP_F64:         return "f64";
        case ATYP_F128:        return "f128";
        case ATYP_BOOL:        return "bool";
        case ATYP_CHAR:        return "char";
        case ATYP_STR:         return "str";
        case ATYP_BYTES:       return "bytes";
        case ATYP_SELF:        return "self";
        case ATYP_GENERIC_APP: return "generic";
    }
}
fn int typ_from_kw(char* s)
{
    for (int i = 0; i <= 47; i++)
    {
        if (streq(typ_kw((AirTypTag)i), s)) { return i; }
    }
    return -1;
}
// Types whose text carries a name / an integer payload. Everything else must
// have neither (the writer refuses to drop information silently).
fn bool typ_has_name(AirTypTag t)
{
    return t == ATYP_NOMINAL || t == ATYP_PATH || t == ATYP_VAR || t == ATYP_FORALL
        || t == ATYP_EXISTS || t == ATYP_GENERIC_APP;
}
fn bool typ_has_ival(AirTypTag t)
{
    return t == ATYP_ARRAY || t == ATYP_EFFROW || t == ATYP_REFINE;
}

fn char* atomic_order_name(int o)
{
    switch (o)
    {
        case 0: return "relaxed";
        case 1: return "acquire";
        case 2: return "release";
        case 3: return "acq_rel";
        case 4: return "seq_cst";
    }
    return null;
}
fn char* atomic_op_name(int o)
{
    switch (o)
    {
        case 0: return "load";
        case 1: return "store";
        case 2: return "xchg";
        case 3: return "add";
        case 4: return "sub";
        case 5: return "and";
        case 6: return "or";
        case 7: return "xor";
        case 8: return "nand";
        case 9: return "max";
        case 10: return "min";
        case 11: return "umax";
        case 12: return "umin";
    }
    return null;
}
