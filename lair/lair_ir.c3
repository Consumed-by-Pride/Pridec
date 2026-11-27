// ============================================================================
// lair_ir.c3 — LAIR: Low-level AIR, the data structures.
//
// LAIR is lambda-bar mu mu-tilde after the three normalizations of
// docs/pear2/LAIR.md §1: producers are atoms (N1), consumer stacks are gone
// (N2), and every covariable binding whose code must exist in more than one
// place is a block with parameters (N3). The three sorts survive as:
//
//   producers -> LAtom          (names and literals; never compound)
//   consumers -> LTerm          (ret / jump / br / switch / trap: the whole
//                                consumer sort is closed and finite)
//   commands  -> the cut line   (`%x = cut op(args) : T` is `⟨op(args) | μ̃x⟩`)
//
// Blocks are named after the covariable they materialize: `entry` and `.bN`
// for continuations the lowerer synthesizes, the source name (`%ret`, a label)
// when the binder came from AIR. A jump to a block IS a cut to a covariable;
// the edge arguments are the block's parameters, which the .ll printer turns
// into phis (lair_ll.c3).
//
// Allocation goes through the shared AirArena slab (pfront/pear_ir/air_ir.c3)
// -- LAIR nodes are built by the lowerer and die with the run, exactly like
// AIR nodes. This file deliberately does NOT use air_new_raw: that stamps an
// id into offset 0 of every node, which would clobber LAtom.k.
// ============================================================================
module lair_ir;
import air_ir;
import air_text;

extern fn void* malloc(usz size_);
extern fn void* realloc(void* ptr, usz size_);
extern fn void  free(void* ptr);
extern fn void* memset(void* dst, int value, usz n);

// ── types ──────────────────────────────────────────────────────────────────
// A closed set: LAIR has no user-defined types in the slice, and the .ll
// printer's spelling of each member is total. Signedness lives in the tag
// (LT_I64 vs LT_U64) because every integer lowering decision -- sdiv vs udiv,
// ashr vs lshr, icmp slt vs ult -- reads it.
enum LTy : int {
    LT_INVALID,                     // not yet inferred / refused
    LT_BOOL,                        // i1
    LT_I8, LT_I16, LT_I32, LT_I64,
    LT_U8, LT_U16, LT_U32, LT_U64,
    LT_CHAR,                        // i32, AIR's Unicode scalar
    LT_F32, LT_F64,
    LT_UNIT,                        // void as a return, {} as a value
    LT_PTR,                         // opaque pointer (extern signatures)
    LT_SYM,                         // a function symbol, usable only as a callee
    LT_TUPLE,                       // aggregate: {T1, T2, ...} (phase 4)
    LT_ARRAY,                       // aggregate: [T; N] (phase 4)
    LT_RECORD                       // aggregate: {f1:T1, ...} (phase 4)
}

// An aggregate type descriptor, interned per module. Scalars are carried
// directly by an LTy; an aggregate LTy (LT_TUPLE/LT_ARRAY/LT_RECORD) points at
// one of these through the `atid` pool index carried next to it. Element
// types are scalar in this rung (nested aggregates fail closed in the lowerer),
// which keeps the descriptor a flat, comparable record.
struct LType
{
    LTy k;           // LT_TUPLE / LT_ARRAY / LT_RECORD
    int n;           // element / field count
    LTy[8] elems;    // scalar element types
    char*[8] names;  // record field names (null for tuple / array)
}

fn bool lty_is_agg(LTy t)
{
    return t == LT_TUPLE || t == LT_ARRAY || t == LT_RECORD;
}

fn int lty_bits(LTy t)
{
    switch (t)
    {
        case LT_BOOL: return 1;
        case LT_I8: case LT_U8: return 8;
        case LT_I16: case LT_U16: return 16;
        case LT_I32: case LT_U32: case LT_CHAR: return 32;
        case LT_I64: case LT_U64: return 64;
        case LT_PTR: return 64;
        default: return 0;
    }
}

fn bool lty_is_int(LTy t)
{
    return t == LT_I8 || t == LT_I16 || t == LT_I32 || t == LT_I64
        || t == LT_U8 || t == LT_U16 || t == LT_U32 || t == LT_U64
        || t == LT_CHAR;
}

fn bool lty_is_signed(LTy t)
{
    return t == LT_I8 || t == LT_I16 || t == LT_I32 || t == LT_I64 || t == LT_CHAR;
}

fn bool lty_is_float(LTy t) { return t == LT_F32 || t == LT_F64; }

fn char* lty_name(LTy t)
{
    switch (t)
    {
        case LT_INVALID: return (char*)"invalid";
        case LT_BOOL: return (char*)"bool";
        case LT_I8: return (char*)"i8";
        case LT_I16: return (char*)"i16";
        case LT_I32: return (char*)"i32";
        case LT_I64: return (char*)"i64";
        case LT_U8: return (char*)"u8";
        case LT_U16: return (char*)"u16";
        case LT_U32: return (char*)"u32";
        case LT_U64: return (char*)"u64";
        case LT_CHAR: return (char*)"char";
        case LT_F32: return (char*)"f32";
        case LT_F64: return (char*)"f64";
        case LT_UNIT: return (char*)"unit";
        case LT_PTR: return (char*)"ptr";
        case LT_SYM: return (char*)"sym";
        case LT_TUPLE: return (char*)"tuple";
        case LT_ARRAY: return (char*)"array";
        case LT_RECORD: return (char*)"record";
    }
    return (char*)"?";
}

// ── atoms (the producer sort) ──────────────────────────────────────────────
enum LAtomK : int { LA_VAR, LA_INT, LA_FLOAT, LA_BOOL, LA_UNIT, LA_SYM }

struct LAtom
{
    LAtomK k;
    LTy ty;
    char* name;     // LA_VAR / LA_SYM
    long ival;      // LA_INT (LA_BOOL uses 0/1, LA_CHAR lives in LA_INT)
    double fval;    // LA_FLOAT
    int atid;       // aggregate type pool index (valid only when lty_is_agg(ty);
                    // ignored for scalar atoms, where it stays 0)
}

fn LAtom la_atom_var(char* nm, LTy t)
{
    LAtom a; a.k = LA_VAR; a.ty = t; a.name = nm; a.ival = 0; a.fval = 0.0; a.atid = 0; return a;
}
// an aggregate-valued atom: ty is LT_TUPLE/LT_ARRAY/LT_RECORD and atid is its
// interned LType pool index
fn LAtom la_atom_agg(char* nm, LTy t, int atid)
{
    LAtom a; a.k = LA_VAR; a.ty = t; a.name = nm; a.ival = 0; a.fval = 0.0; a.atid = atid; return a;
}
fn LAtom la_atom_int(long v, LTy t)
{
    LAtom a; a.k = LA_INT; a.ty = t; a.name = null; a.ival = v; a.fval = 0.0; return a;
}
fn LAtom la_atom_float(double v, LTy t)
{
    LAtom a; a.k = LA_FLOAT; a.ty = t; a.name = null; a.ival = 0; a.fval = v; return a;
}
fn LAtom la_atom_bool(bool v)
{
    LAtom a; a.k = LA_BOOL; a.ty = LT_BOOL; a.name = null; a.ival = v ? 1 : 0; a.fval = 0.0; return a;
}
fn LAtom la_atom_unit()
{
    LAtom a; a.k = LA_UNIT; a.ty = LT_UNIT; a.name = null; a.ival = 0; a.fval = 0.0; return a;
}
fn LAtom la_atom_sym(char* nm)
{
    LAtom a; a.k = LA_SYM; a.ty = LT_SYM; a.name = nm; a.ival = 0; a.fval = 0.0; return a;
}
fn bool la_atom_is_lit(LAtom a) { return a.k != LA_VAR && a.k != LA_SYM; }

// type equality for an atom against a declared type: the tag must match, and for
// an aggregate the interned descriptor index must match too (two tuples of
// different element types share the LT_TUPLE tag but are not the same type)
fn bool la_atom_ty_eq(LAtom a, LTy t, int atid)
{
    if (a.ty != t) { return false; }
    if (lty_is_agg(t) && a.atid != atid) { return false; }
    return true;
}

// ── instructions (cuts of an atomic operator into a fresh mu-tilde) ────────
enum LIOp : int { LI_BINOP, LI_UNOP, LI_COERCE, LI_CALL,
    LI_TUPLE, LI_RECORD, LI_ARRAY, LI_EXTRACT,     // aggregates (phase 4)
    LI_ALLOCA, LI_LOAD, LI_STORE, LI_GEP }          // memory (phase 4)

struct LInstr
{
    LIOp op;
    LTy ty;             // result type (LT_UNIT for a void call; LT_INVALID never)
    char* dst;          // result name; null only for a void call
    int bop;            // LI_BINOP: AirBinop
    int uop;            // LI_UNOP: AirUnop
    LAtom a;
    LAtom b;
    LTy from;           // LI_COERCE: source type (a.ty is the same value; kept
                        // explicit so the printer never needs an environment)
    char* callee;       // LI_CALL: symbol name (LA_SYM atom's name)
    LAtom[16] args;
    int argc;
    bool va;            // LI_CALL: varargs callee
    int atid;           // aggregate result type pool index (valid only when
                        // lty_is_agg(ty); element types for construction)
    long ival;          // LI_EXTRACT: element index; LI_GEP: base index
}

// ── terminators (the consumer sort, N2: closed and finite) ─────────────────
enum LTermK : int { LTM_RET, LTM_JUMP, LTM_BR, LTM_SWITCH, LTM_TRAP, LTM_UNREACH }

struct LTerm
{
    LTermK k;
    LAtom a;                    // LTM_RET value / LTM_SWITCH scrutinee
    char* target;               // LTM_JUMP target block
    LAtom[24] args;             // LTM_JUMP edge arguments (block parameters:
                                // declared label params + captured environment)
    int argc;
    char* t1; char* t2;         // LTM_BR true / false targets
    long[64] vals;              // LTM_SWITCH case values
    char*[64] tgts;             // LTM_SWITCH case targets
    int ncase;
    char* def;                  // LTM_SWITCH default target (null = unreachable)
}

// ── blocks (materialized covariables) ──────────────────────────────────────
struct LParam { char* name; char* aname; LTy ty; int atid; }
// `name` is the SSA name the printers emit (unique per function); `aname` is
// the AIR binder name the verifier's environment is keyed by (labels can
// shadow, and a phi's SSA name must be unique even when the AIR name repeats
// across blocks).

struct LBlock
{
    char* name;
    LParam[24] params;          // declared label parameters, then the captured
                                // environment (N3: one param per captured name)
    int np;
    bool lbl;                   // a source label block: its parameters are
                                // scope-local (the verifier unsets them after
                                // the block; while-header phis persist)
    LInstr* instrs;
    int ni;
    int cap;
    LTerm term;
    bool has_term;
}

// ── functions / module ─────────────────────────────────────────────────────
struct LFunc
{
    char* name;
    LParam[64] params;
    int np;
    LTy ret;                    // LT_INVALID = infer from the first `ret`
    int retid;                  // aggregate return type pool index (valid only
                                // when lty_is_agg(ret))
    LBlock*[128] blocks;
    int nb;
    int source_line;
}

struct LExtern
{
    char* name;
    LTy[16] params;
    int[16] p_atid;             // aggregate param type pool indices
    int np;
    LTy ret;
    int retid;                  // aggregate return type pool index
    bool va;
}

struct LModule
{
    char* name;
    char* source;
    AirArena* arena;
    LExtern*[64] externs;
    int next_;
    LFunc*[256] funcs;
    int nf;
    int errs;                   // lowering + verification failures
    LType* tp;                  // interned aggregate type pool (phase 4)
    int tn;
    int tc;
}

// Intern an aggregate type descriptor, structurally deduplicated. Returns the
// pool index, or -1 on allocation failure. Scalars are not interned (they are
// carried directly by LTy); only LT_TUPLE/LT_ARRAY/LT_RECORD reach here.
fn int lair_type_intern(LModule* m, LType t)
{
    for (int i = 0; i < m.tn; i++)
    {
        LType* e = m.tp + i;
        if (e.k != t.k || e.n != t.n) { continue; }
        bool same = true;
        for (int j = 0; j < t.n; j++)
        {
            if (e.elems[j] != t.elems[j]) { same = false; break; }
            if (!(e.names[j] == null && t.names[j] == null) &&
                !(e.names[j] != null && t.names[j] != null && air_text::streq(e.names[j], t.names[j])))
            {
                same = false; break;
            }
        }
        if (same) { return i; }
    }
    if (m.tn >= m.tc)
    {
        int nc = m.tc == 0 ? 8 : m.tc * 2;
        LType* arr = (LType*)realloc(m.tp, (usz)nc * LType::size);
        if (arr == null) { return -1; }
        m.tp = arr;
        m.tc = nc;
    }
    m.tp[m.tn] = t;
    m.tn++;
    return m.tn - 1;
}

fn void* lair_alloc(AirArena* a, usz size_)
{
    void* p = a.alloc(size_, 8);
    if (p != null) { memset(p, 0, size_); }
    return p;
}

fn LBlock* lair_new_block(AirArena* a, char* nm)
{
    LBlock* b = (LBlock*)lair_alloc(a, LBlock::size);
    if (b == null) { return null; }
    b.name = nm;
    return b;
}

fn bool lair_block_push(LBlock* b, LInstr in)
{
    if (b.ni >= b.cap)
    {
        int cap = b.cap == 0 ? 8 : b.cap * 2;
        LInstr* arr = (LInstr*)realloc(b.instrs, (usz)cap * LInstr::size);
        if (arr == null) { return false; }
        b.instrs = arr;
        b.cap = cap;
    }
    b.instrs[b.ni] = in;
    b.ni++;
    return true;
}
