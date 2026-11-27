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
    LT_SYM                          // a function symbol, usable only as a callee
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
}

fn LAtom la_atom_var(char* nm, LTy t)
{
    LAtom a; a.k = LA_VAR; a.ty = t; a.name = nm; a.ival = 0; a.fval = 0.0; return a;
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

// ── instructions (cuts of an atomic operator into a fresh mu-tilde) ────────
enum LIOp : int { LI_BINOP, LI_UNOP, LI_COERCE, LI_CALL }

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
struct LParam { char* name; char* aname; LTy ty; }
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
    LBlock*[128] blocks;
    int nb;
    int source_line;
}

struct LExtern
{
    char* name;
    LTy[16] params;
    int np;
    LTy ret;
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
