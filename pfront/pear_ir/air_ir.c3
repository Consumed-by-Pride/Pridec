// ============================================================================
// air_ir.c3 — In-memory AIR IR (λ̄μμ̃ three-sorted abstract syntax).
// ============================================================================
module air_ir;
import pfront_core;

extern fn void* malloc(usz size_);
extern fn void  free(void* ptr);
extern fn void* memset(void* dst, int value, usz n);
extern fn void* memcpy(void* dst, void* src, usz n);

// ── Tag enums ──────────────────────────────────────────────────────────────
enum AirPrdTag : int { APRD_INVALID, APRD_VAR, APRD_CON, APRD_INT, APRD_FLOAT,
    APRD_BOOL, APRD_CHAR, APRD_STRING, APRD_BYTES, APRD_UNIT, APRD_NULL,
    APRD_TUPLE, APRD_RECORD, APRD_ARRAY, APRD_INL, APRD_INR, APRD_LAMBDA,
    APRD_MU, APRD_COMETA, APRD_BINOP, APRD_UNOP, APRD_COERCE,
    APRD_SIZEOF, APRD_ALIGNOF, APRD_OFFSETOF, APRD_REIFY, APRD_EVAL,
    APRD_QUOTE, APRD_SPLICE, APRD_POISON, APRD_UNREACHABLE_VAL }

enum AirCnsTag : int { ACNS_INVALID, ACNS_COVAR, ACNS_STACK, ACNS_FST, ACNS_SND,
    ACNS_PROJ, ACNS_FIELD, ACNS_INDEX, ACNS_CALL, ACNS_CASE, ACNS_COCASE,
    ACNS_COMU, ACNS_DEFAULT, ACNS_ASCRIBE, ACNS_SUBST, ACNS_SHARE, ACNS_ERASE,
    ACNS_DEREF, ACNS_STORE, ACNS_LABEL }

enum AirCmdTag : int { ACMD_INVALID, ACMD_CUT, ACMD_MU, ACMD_MUTILDE, ACMD_JUMP,
    ACMD_SEQ, ACMD_BLOCK, ACMD_LET, ACMD_LETREC, ACMD_IF, ACMD_WHILE, ACMD_FOR,
    ACMD_MATCH, ACMD_HANDLE, ACMD_PERFORM, ACMD_RESUME, ACMD_UNSAFE,
    ACMD_UNCHECKED, ACMD_COMPTIME, ACMD_ASSERT, ACMD_ASSUME, ACMD_UB, ACMD_TRAP,
    ACMD_RET, ACMD_BREAK, ACMD_CONTINUE, ACMD_DEFER, ACMD_LABEL, ACMD_NOP,
    ACMD_ASM, ACMD_SYSCALL, ACMD_ATOMIC, ACMD_FENCE }

enum AirPatTag : int { APAT_INVALID, APAT_WILD, APAT_BIND, APAT_INT, APAT_FLOAT,
    APAT_BOOL, APAT_CHAR, APAT_STRING, APAT_TUPLE, APAT_ARRAY, APAT_RECORD,
    APAT_VARIANT, APAT_AS, APAT_OR, APAT_RANGE, APAT_REF, APAT_REST }

enum AirTypTag : int { ATYP_INVALID, ATYP_NOMINAL, ATYP_PATH, ATYP_VAR,
    ATYP_ARROW, ATYP_TUPLE, ATYP_RECORD, ATYP_ARRAY, ATYP_SLICE,
    ATYP_PTR, ATYP_REF, ATYP_REF_MUT, ATYP_SUM, ATYP_UNION, ATYP_INTERSECT,
    ATYP_NEGATION, ATYP_BOTTOM, ATYP_UNIT, ATYP_INFER, ATYP_FORALL,
    ATYP_EXISTS, ATYP_BANG, ATYP_QUERY, ATYP_MULT, ATYP_EFFROW, ATYP_TYPEOF,
    ATYP_REFINE, ATYP_I8, ATYP_I16, ATYP_I32, ATYP_I64, ATYP_I128, ATYP_ISZ,
    ATYP_U8, ATYP_U16, ATYP_U32, ATYP_U64, ATYP_U128, ATYP_USZ,
    ATYP_F16, ATYP_F32, ATYP_F64, ATYP_F128,
    ATYP_BOOL, ATYP_CHAR, ATYP_STR, ATYP_BYTES, ATYP_SELF, ATYP_GENERIC_APP }

enum AirMult : int { AMULT_UNR, AMULT_LIN, AMULT_AFF, AMULT_EXACT }
enum AirBinop : int { ABIN_ADD, ABIN_SUB, ABIN_MUL, ABIN_DIV, ABIN_MOD,
    ABIN_AND, ABIN_OR, ABIN_XOR, ABIN_SHL, ABIN_SHR, ABIN_LAND, ABIN_LOR,
    ABIN_EQ, ABIN_NEQ, ABIN_LT, ABIN_GT, ABIN_LE, ABIN_GE, ABIN_PIPE }
enum AirUnop : int { AUN_NEG, AUN_NOT, AUN_BITNOT, AUN_DEREF, AUN_REF, AUN_ADDR, AUN_COMULT }
enum AirDeclTag : int { ADECL_DATA, ADECL_CODATA, ADECL_DEF, ADECL_DEFCO,
    ADECL_DECLARE, ADECL_IMPORT, ADECL_MODULE, ADECL_EFFECT }

// ── Arena ─────────────────────────────────────────────────────────────────
const usz AIR_SLAB_SIZE = 1024 * 1024;
const usz AIR_MAX_SLABS = 256;
struct AirArena {
    char*[AIR_MAX_SLABS] slabs;
    usz slab_count, cursor, cur_cap;
    uint next_id; usz node_count, bytes_used; bool oom;
}
fn bool AirArena.init(AirArena* a) {
    for (usz i = 0; i < AIR_MAX_SLABS; i++) a.slabs[i] = null;
    a.slab_count=0; a.cursor=0; a.cur_cap=0; a.next_id=1;
    a.node_count=0; a.bytes_used=0; a.oom=false;
    return a.grow(AIR_SLAB_SIZE);
}
fn bool AirArena.grow(AirArena* a, usz want) {
    if (a.slab_count >= AIR_MAX_SLABS) { a.oom=true; return false; }
    usz cap = AIR_SLAB_SIZE; while (cap < want) cap = cap*2;
    char* s = (char*)malloc(cap); if (s == null) { a.oom=true; return false; }
    memset((void*)s, 0, cap);
    a.slabs[a.slab_count] = s; a.slab_count++; a.cursor=0; a.cur_cap=cap;
    return true;
}
fn void* AirArena.alloc(AirArena* a, usz size_, usz align) {
    if (size_ == 0) size_ = 1;
    usz mask = align - 1; usz cur = (a.cursor + mask) & ~mask;
    if (cur + size_ > a.cur_cap) { if (!a.grow(size_ + align)) return null; cur = 0; }
    char* slab = a.slabs[a.slab_count - 1];
    a.cursor = cur + size_; a.bytes_used = a.bytes_used + size_;
    return (void*)(slab + cur);
}
fn void AirArena.destroy(AirArena* a) {
    for (usz i = 0; i < a.slab_count; i++) { if (a.slabs[i] != null) free((void*)a.slabs[i]); a.slabs[i]=null; }
    a.slab_count=0; a.cursor=0; a.cur_cap=0;
}
fn char* AirArena.dup(AirArena* a, char* src, usz len) {
    char* d = (char*)a.alloc(len+1, 1); if (d == null) return null;
    for (usz i = 0; i < len; i++) d[i] = src[i];
    d[len] = 0; return d;
}
fn void* air_new_raw(AirArena* a, usz size_) {
    void* p = a.alloc(size_, 8); if (p == null) return null;
    memset(p, 0, size_);
    uint* idp = (uint*)p; *idp = a.next_id; a.next_id++; a.node_count++;
    return p;
}

// ── Auxiliary records ─────────────────────────────────────────────────────
struct AirBinder { uint id; char* name; AirMult mult; int mult_exact; AirTyp* ty; bool is_mutable; }
struct AirField { uint id; char* name; AirMult mult; AirTyp* ty; bool is_mut; }
struct AirBranch { uint id; AirPat* pat; AirCmd* body; AirCmd* guard; }
struct AirCoBranch { uint id; char* dtor_name; char*[16] binders; usz binder_count; AirCmd* body; }
struct AirFieldInit { uint id; char* name; AirPrd* value; }
struct AirCtorDecl { uint id; char* name; AirField*[64] fields; usz field_count; AirTyp* result_ty; }
struct AirDtorDecl { uint id; char* name; AirField*[64] params; usz param_count; AirTyp* return_ty; }
struct AirEffectOp { uint id; char* name; AirTyp* op_ty; }

// ── Core AST nodes ────────────────────────────────────────────────────────
struct AirTyp {
    uint id; AirTypTag tag; AirTyp*[8] args; usz arg_count; char* name;
    AirMult mult; int mult_exact; long ival; double fval;
    AirFieldInit*[64] rec_fields; usz rec_field_count;
    AirTyp* eff_tail; char* eff_name; void* refine_extra;
}
struct AirPat {
    uint id; AirPatTag tag; char* name; long ival; double fval;
    AirPat*[16] sub; usz sub_count;
    AirFieldInit*[16] fields; usz field_count;
    AirPat* as_pat; AirPat* or_alt; AirTyp* ty;
}
struct AirPrd {
    uint id; AirPrdTag tag; char* name; long ival; double fval; bool bval; char cval;
    usz bytes_len; char* bytes;
    AirPrd*[16] subs; usz sub_count;
    AirBinder*[16] binders; usz binder_count;
    AirCmd* body; AirTyp* ty_arg;
    AirFieldInit*[16] rec_inits; usz rec_init_count;
    AirBinop bop; AirUnop uop; AirTyp* ty;
}
struct AirCns {
    uint id; AirCnsTag tag; char* name; long idx; AirPrd* prd;
    AirCns *tail; AirCns *cont_k;
    AirBranch*[64] branches; usz branch_count;
    AirCoBranch*[64] cobranches; usz cobranch_count;
    AirCmd* body; char* bind; AirTyp* ty;
    char* label_name; AirBinder*[16] label_args; usz label_arg_count; AirCmd* label_body;
    char*[16] subst_vars; AirPrd*[16] subst_prds; usz subst_count;
}
struct AirCmd {
    uint id; AirCmdTag tag; AirPrd* prd; AirCns* cns;
    AirPrd*[16] prds; usz prd_count;
    char* binder; AirBinder*[16] mbinders; usz mbinder_count;
    AirCmd *body; AirCmd *next; AirCmd *then_c; AirCmd *else_c;
    AirBranch*[64] branches; usz branch_count;
    AirCmd* handled; char* eff_op; char* target_label;
    char*[16] jump_args; usz jump_arg_count;
    char* ub_msg; int asm_dialect; char* asm_text; AirTyp* poison_ty;
    int atomic_op, atomic_order;
}
struct AirDecl {
    uint id; AirDeclTag tag; char* name;
    AirBinder*[16] typarams; usz typaram_count; AirMult mult;
    AirCtorDecl*[64] ctors; usz ctor_count;
    AirDtorDecl*[64] dtors; usz dtor_count;
    AirBinder*[16] params; usz param_count;
    AirCmd* def_body; AirTyp* ret_ty;
    bool is_pub, is_extern, is_fastcc, is_varargs;
    char* extern_link; AirEffectOp*[16] ops; usz op_count;
    char* import_path; char* import_alias; bool import_glob; char* module_name;
}
struct AirModule {
    uint id; char* name; char* source_path;
    AirDecl*[4096] decls; usz decl_count;
    AirArena* arena;
    AirTyp* t_unit;
    AirTyp* t_i8;
    AirTyp* t_i16;
    AirTyp* t_i32;
    AirTyp* t_i64;
    AirTyp* t_u8;
    AirTyp* t_u16;
    AirTyp* t_u32;
    AirTyp* t_u64;
    AirTyp* t_isz;
    AirTyp* t_usz;
    AirTyp* t_f32;
    AirTyp* t_f64;
    AirTyp* t_bool;
    AirTyp* t_char;
    AirTyp* t_str;
    AirTyp* t_bytes;
    AirTyp* t_bottom;
    AirTyp* t_infer;
    AirPrd* p_unit;
    AirPrd* p_true;
    AirPrd* p_false;
    AirPrd* p_null;
    AirCns* c_ret;
    AirPat* pat_wild;
    AirCmd* nop;
}

// ── Allocators ────────────────────────────────────────────────────────────
fn AirTyp*       air_new_AirTyp(AirArena* a)       { return (AirTyp*)air_new_raw(a, AirTyp::size); }
fn AirPat*       air_new_AirPat(AirArena* a)       { return (AirPat*)air_new_raw(a, AirPat::size); }
fn AirPrd*       air_new_AirPrd(AirArena* a)       { return (AirPrd*)air_new_raw(a, AirPrd::size); }
fn AirCns*       air_new_AirCns(AirArena* a)       { return (AirCns*)air_new_raw(a, AirCns::size); }
fn AirCmd*       air_new_AirCmd(AirArena* a)       { return (AirCmd*)air_new_raw(a, AirCmd::size); }
fn AirDecl*      air_new_AirDecl(AirArena* a)      { return (AirDecl*)air_new_raw(a, AirDecl::size); }
fn AirBinder*    air_new_AirBinder(AirArena* a)    { return (AirBinder*)air_new_raw(a, AirBinder::size); }
fn AirField*     air_new_AirField(AirArena* a)     { return (AirField*)air_new_raw(a, AirField::size); }
fn AirBranch*    air_new_AirBranch(AirArena* a)    { return (AirBranch*)air_new_raw(a, AirBranch::size); }
fn AirCoBranch*  air_new_AirCoBranch(AirArena* a)  { return (AirCoBranch*)air_new_raw(a, AirCoBranch::size); }
fn AirFieldInit* air_new_AirFieldInit(AirArena* a) { return (AirFieldInit*)air_new_raw(a, AirFieldInit::size); }
fn AirCtorDecl*  air_new_AirCtorDecl(AirArena* a)  { return (AirCtorDecl*)air_new_raw(a, AirCtorDecl::size); }
fn AirDtorDecl*  air_new_AirDtorDecl(AirArena* a)  { return (AirDtorDecl*)air_new_raw(a, AirDtorDecl::size); }
fn AirEffectOp*  air_new_AirEffectOp(AirArena* a)  { return (AirEffectOp*)air_new_raw(a, AirEffectOp::size); }

// ── cstrlen ──────────────────────────────────────────────────────────────
fn int air_cstrlen(char* s) { if (s==null) return 0; int n=0; while (s[n]!=0) n++; return n; }

// ── Primitive singletons ─────────────────────────────────────────────────
fn AirTyp* air_mk_typ_simple(AirArena* a, AirTypTag tag) { AirTyp* t=air_new_AirTyp(a); if(t==null)return null; t.tag=tag; return t; }
fn AirPrd* air_mk_prd_unit(AirArena* a){AirPrd*p=air_new_AirPrd(a);if(p==null)return null;p.tag=APRD_UNIT;return p;}
fn AirCns* air_mk_cns_covar(AirArena* a, char* name){AirCns*e=air_new_AirCns(a);if(e==null)return null;e.tag=ACNS_COVAR;e.name=name;return e;}
fn AirPat* air_mk_pat_wild(AirArena* a){AirPat*p=air_new_AirPat(a);if(p==null)return null;p.tag=APAT_WILD;return p;}
fn AirCmd* air_mk_cmd_nop(AirArena* a, AirPrd* unit, AirCns* hole){AirCmd*c=air_new_AirCmd(a);if(c==null)return null;c.tag=ACMD_CUT;c.prd=unit;c.cns=hole;return c;}
fn AirPrd* air_mk_prd_bool(AirArena* a, bool v){AirPrd*p=air_new_AirPrd(a);if(p==null)return null;p.tag=APRD_BOOL;p.bval=v;return p;}
fn AirPrd* air_mk_prd_null(AirArena* a){AirPrd*p=air_new_AirPrd(a);if(p==null)return null;p.tag=APRD_NULL;return p;}

fn bool AirModule.init(AirModule* m, AirArena* a, char* name, char* src_path) {
    m.arena=a;
    m.name=a.dup(name,(usz)air_cstrlen(name));
    m.source_path = src_path==null?null:a.dup(src_path,(usz)air_cstrlen(src_path));
    m.decl_count=0;
    m.t_unit=air_mk_typ_simple(a,ATYP_UNIT); m.t_i8=air_mk_typ_simple(a,ATYP_I8);
    m.t_i16=air_mk_typ_simple(a,ATYP_I16); m.t_i32=air_mk_typ_simple(a,ATYP_I32);
    m.t_i64=air_mk_typ_simple(a,ATYP_I64); m.t_u8=air_mk_typ_simple(a,ATYP_U8);
    m.t_u16=air_mk_typ_simple(a,ATYP_U16); m.t_u32=air_mk_typ_simple(a,ATYP_U32);
    m.t_u64=air_mk_typ_simple(a,ATYP_U64); m.t_isz=air_mk_typ_simple(a,ATYP_ISZ);
    m.t_usz=air_mk_typ_simple(a,ATYP_USZ); m.t_f32=air_mk_typ_simple(a,ATYP_F32);
    m.t_f64=air_mk_typ_simple(a,ATYP_F64); m.t_bool=air_mk_typ_simple(a,ATYP_BOOL);
    m.t_char=air_mk_typ_simple(a,ATYP_CHAR); m.t_str=air_mk_typ_simple(a,ATYP_STR);
    m.t_bytes=air_mk_typ_simple(a,ATYP_BYTES); m.t_bottom=air_mk_typ_simple(a,ATYP_BOTTOM);
    m.t_infer=air_mk_typ_simple(a,ATYP_INFER);
    m.p_unit=air_mk_prd_unit(a); m.c_ret=air_mk_cns_covar(a,a.dup("%ret",4));
    m.pat_wild=air_mk_pat_wild(a); m.p_true=air_mk_prd_bool(a,true);
    m.p_false=air_mk_prd_bool(a,false); m.p_null=air_mk_prd_null(a);
    m.nop=air_mk_cmd_nop(a,m.p_unit,air_mk_cns_covar(a,a.dup("·",3)));
    return (m.t_unit!=null)&&(m.p_unit!=null)&&(m.c_ret!=null);
}

// ── Append helpers ───────────────────────────────────────────────────────
fn bool AirModule.add_decl(AirModule* m, AirDecl* d){ if(d==null)return false; if(m.decl_count>=4096)return false; m.decls[m.decl_count]=d; m.decl_count++; return true; }
fn void AirTyp.add_arg(AirTyp* t, AirTyp* a){ if(t==null||a==null)return; if(t.arg_count>=8)return; t.args[t.arg_count]=a; t.arg_count++; }
fn void AirPrd.add_sub(AirPrd* p, AirPrd* s){ if(p==null||s==null)return; if(p.sub_count>=16)return; p.subs[p.sub_count]=s; p.sub_count++; }
fn void AirCmd.add_prd(AirCmd* c, AirPrd* p){ if(c==null||p==null)return; if(c.prd_count>=16)return; c.prds[c.prd_count]=p; c.prd_count++; }
fn void AirCmd.add_branch(AirCmd* c, AirBranch* b){ if(c==null||b==null)return; if(c.branch_count>=64)return; c.branches[c.branch_count]=b; c.branch_count++; }

// ── Smart constructors ───────────────────────────────────────────────────
fn AirBinder* air_mk_binder(AirArena* a, char* nm, AirTyp* ty, AirMult m) {
    AirBinder* b=air_new_AirBinder(a); if(b==null)return null;
    b.name=nm; b.ty=ty; b.mult=m; b.mult_exact=0; b.is_mutable=false; return b;
}
fn AirField* air_mk_field(AirArena* a, char* nm, AirTyp* ty, AirMult m) {
    AirField* f=air_new_AirField(a); if(f==null)return null;
    f.name=nm; f.ty=ty; f.mult=m; f.is_mut=false; return f;
}
fn AirBranch* air_mk_branch(AirArena* a, AirPat* pat, AirCmd* body) {
    AirBranch* b=air_new_AirBranch(a); if(b==null)return null;
    b.pat=pat; b.body=body; b.guard=null; return b;
}
fn AirDecl* air_mk_decl(AirArena* a, AirDeclTag tag, char* nm) {
    AirDecl* d=air_new_AirDecl(a); if(d==null)return null;
    d.tag=tag; d.name=nm; d.typaram_count=0; d.mult=AMULT_UNR;
    d.ctor_count=0; d.dtor_count=0; d.param_count=0;
    d.def_body=null; d.ret_ty=null; d.is_pub=false; d.is_extern=false;
    d.is_varargs=false; d.extern_link=null; d.op_count=0;
    d.import_path=null; d.import_alias=null; d.import_glob=false;
    d.module_name=null; return d;
}
fn AirDecl* air_mk_import(AirArena* a, char* path, char* als, bool glob) {
    AirDecl* d=air_mk_decl(a, ADECL_IMPORT, path); if(d==null)return null;
    d.import_path=path; d.import_alias=als; d.import_glob=glob; return d;
}
fn AirDecl* air_mk_module_decl(AirArena* a, char* nm) {
    return air_mk_decl(a, ADECL_MODULE, nm);
}

// Commands
fn AirCmd* air_mk_cut(AirArena* a, AirPrd* p, AirCns* e)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_CUT; c.prd=p; c.cns=e; c.next=null; c.body=null; return c; }
fn AirCmd* air_mk_mu(AirArena* a, char* covar, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_MU; c.binder=covar; c.body=body; return c; }
fn AirCmd* air_mk_mutilde(AirArena* a, char* var_nm, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_MUTILDE; c.binder=var_nm; c.body=body; return c; }
fn AirCmd* air_mk_seq(AirArena* a, AirCmd* first, AirCmd* rest) {
    if(first==null)return rest; if(rest==null)return first;
    AirCmd* c=air_new_AirCmd(a); if(c==null)return first;
    c.tag=ACMD_SEQ; c.body=first; c.next=rest; return c;
}
fn AirCmd* air_mk_jump(AirArena* a, char* target, char** argv, usz argc) {
    AirCmd* c=air_new_AirCmd(a); if(c==null)return null;
    c.tag=ACMD_JUMP; c.target_label=target; c.jump_arg_count=0;
    for(usz i=0;i<argc&&i<16;i++){c.jump_args[i]=argv[i]; c.jump_arg_count++;}
    return c;
}
fn AirCmd* air_mk_jump0(AirArena* a, char* target) { return air_mk_jump(a,target,(char**)null,0); }
fn AirCmd* air_mk_let(AirArena* a, char* x, AirPrd* p, AirCmd* rest)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_LET; c.binder=x; c.prd=p; c.body=rest; return c; }
fn AirCmd* air_mk_ret(AirArena* a, AirPrd* p, AirCns* ret_k) { return air_mk_cut(a,p,ret_k); }
fn AirCmd* air_mk_if(AirArena* a, AirPrd* cond, AirCmd* thn, AirCmd* els)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_IF; c.prd=cond; c.then_c=thn; c.else_c=els; return c; }
fn AirCmd* air_mk_label(AirArena* a, char* name, AirBinder** argv, usz argc, AirCmd* body) {
    AirCmd* c=air_new_AirCmd(a); if(c==null)return null;
    c.tag=ACMD_LABEL; c.binder=name; c.mbinder_count=0;
    for(usz i=0;i<argc&&i<16;i++){c.mbinders[i]=argv[i]; c.mbinder_count++;}
    c.body=body; return c;
}
fn AirCmd* air_mk_block(AirArena* a, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_BLOCK; c.body=body; return c; }
fn AirCmd* air_mk_unsafe(AirArena* a, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_UNSAFE; c.body=body; return c; }
fn AirCmd* air_mk_comptime(AirArena* a, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_COMPTIME; c.body=body; return c; }
fn AirCmd* air_mk_assert(AirArena* a, AirPrd* p)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_ASSERT; c.prd=p; return c; }
fn AirCmd* air_mk_assume(AirArena* a, AirPrd* p)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_ASSUME; c.prd=p; return c; }
fn AirCmd* air_mk_ub(AirArena* a, char* msg)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_UB; c.ub_msg=msg; return c; }
fn AirCmd* air_mk_trap(AirArena* a)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_TRAP; return c; }
fn AirCmd* air_mk_perform(AirArena* a, char* op, AirPrd* payload)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_PERFORM; c.eff_op=op; c.prd=payload; return c; }
fn AirCmd* air_mk_handle(AirArena* a, AirCmd* comp, AirBranch** bs, usz bc) {
    AirCmd* c=air_new_AirCmd(a); if(c==null)return null;
    c.tag=ACMD_HANDLE; c.handled=comp; c.branch_count=0;
    for(usz i=0;i<bc&&i<64;i++){c.add_branch(bs[i]);} return c;
}
fn AirCmd* air_mk_match(AirArena* a, AirPrd* scrutee, AirBranch** bs, usz bc) {
    AirCmd* c=air_new_AirCmd(a); if(c==null)return null;
    c.tag=ACMD_MATCH; c.prd=scrutee; c.branch_count=0;
    for(usz i=0;i<bc&&i<64;i++){c.add_branch(bs[i]);} return c;
}
fn AirCmd* air_mk_break(AirArena* a, char* lbl)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_BREAK; c.target_label=lbl; return c; }
fn AirCmd* air_mk_continue(AirArena* a, char* lbl)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_CONTINUE; c.target_label=lbl; return c; }
fn AirCmd* air_mk_defer(AirArena* a, AirCmd* body)
    { AirCmd* c=air_new_AirCmd(a); if(c==null)return null; c.tag=ACMD_DEFER; c.body=body; return c; }

// Producers
fn AirPrd* air_mk_var(AirArena* a, char* nm)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_VAR; p.name=nm; return p; }
fn AirPrd* air_mk_con(AirArena* a, char* nm)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_CON; p.name=nm; p.sub_count=0; return p; }
fn AirPrd* air_mk_int(AirArena* a, long v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_INT; p.ival=v; return p; }
fn AirPrd* air_mk_float(AirArena* a, double v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_FLOAT; p.fval=v; return p; }
fn AirPrd* air_mk_char(AirArena* a, char v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_CHAR; p.cval=v; return p; }
fn AirPrd* air_mk_str(AirArena* a, char* txt, usz len)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_STRING; p.name=a.dup(txt,len); p.bytes_len=(long)len; return p; }
fn AirPrd* air_mk_bytes(AirArena* a, char* buf, usz len)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_BYTES; p.bytes=a.dup(buf,len); p.bytes_len=(long)len; return p; }
fn AirPrd* air_mk_tuple(AirArena* a, AirPrd** ps, usz n) {
    AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_TUPLE; p.sub_count=0;
    for(usz i=0;i<n&&i<16;i++){p.add_sub(ps[i]);} return p;
}
fn AirPrd* air_mk_array(AirArena* a, AirPrd** ps, usz n) {
    AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_ARRAY; p.sub_count=0;
    for(usz i=0;i<n&&i<16;i++){p.add_sub(ps[i]);} return p;
}
fn AirPrd* air_mk_inl(AirArena* a, AirTyp* t, AirPrd* v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_INL; p.ty_arg=t; p.add_sub(v); return p; }
fn AirPrd* air_mk_inr(AirArena* a, AirTyp* t, AirPrd* v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_INR; p.ty_arg=t; p.add_sub(v); return p; }
fn AirPrd* air_mk_lambda(AirArena* a, AirBinder** bv, usz bc, AirCmd* body) {
    AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_LAMBDA; p.binder_count=0;
    for(usz i=0;i<bc&&i<16;i++){p.binders[i]=bv[i]; p.binder_count++;}
    p.body=body; return p;
}
fn AirPrd* air_mk_mu_prd(AirArena* a, char* covar, AirCmd* body)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_MU; p.name=covar; p.body=body; return p; }
fn AirPrd* air_mk_binop(AirArena* a, AirBinop op, AirPrd* l, AirPrd* r)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_BINOP; p.bop=op; p.add_sub(l); p.add_sub(r); return p; }
fn AirPrd* air_mk_unop(AirArena* a, AirUnop op, AirPrd* v)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_UNOP; p.uop=op; p.add_sub(v); return p; }
fn AirPrd* air_mk_poison(AirArena* a, AirTyp* t)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_POISON; p.ty=t; return p; }
fn AirPrd* air_mk_sizeof(AirArena* a, AirTyp* t)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_SIZEOF; p.ty=t; return p; }
fn AirPrd* air_mk_alignof(AirArena* a, AirTyp* t)
    { AirPrd* p=air_new_AirPrd(a); if(p==null)return null; p.tag=APRD_ALIGNOF; p.ty=t; return p; }

// Consumers
fn AirCns* air_mk_covar(AirArena* a, char* nm)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_COVAR; e.name=nm; e.tail=null; return e; }
fn AirCns* air_mk_stack(AirArena* a, AirPrd* p, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_STACK; e.prd=p; e.tail=k; return e; }
fn AirCns* air_mk_fst(AirArena* a, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_FST; e.tail=k; return e; }
fn AirCns* air_mk_snd(AirArena* a, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_SND; e.tail=k; return e; }
fn AirCns* air_mk_proj(AirArena* a, long n, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_PROJ; e.idx=n; e.tail=k; return e; }
fn AirCns* air_mk_field_cns(AirArena* a, char* f, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_FIELD; e.name=f; e.tail=k; return e; }
fn AirCns* air_mk_index(AirArena* a, AirPrd* i, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_INDEX; e.prd=i; e.tail=k; return e; }
fn AirCns* air_mk_call(AirArena* a, AirPrd** args, usz ac, AirCns* k) {
    AirCns* cur=k; if(ac==0)return cur;
    long i=(long)ac-1; while(i>=0){cur=air_mk_stack(a,args[(usz)i],cur); i=i-1;}
    if(cur!=null)cur.tag=ACNS_CALL; return cur;
}
fn AirCns* air_mk_case(AirArena* a, AirBranch** bs, usz bc) {
    AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_CASE; e.branch_count=0;
    for(usz i=0;i<bc&&i<64;i++){e.branches[e.branch_count]=bs[i]; e.branch_count++;}
    e.tail=null; return e;
}
fn AirCns* air_mk_cocase(AirArena* a, AirCoBranch** cbs, usz cc) {
    AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_COCASE; e.cobranch_count=0;
    for(usz i=0;i<cc&&i<64;i++){e.cobranches[e.cobranch_count]=cbs[i]; e.cobranch_count++;}
    e.tail=null; return e;
}
fn AirCns* air_mk_comu_cns(AirArena* a, char* x, AirCmd* body)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_COMU; e.bind=x; e.body=body; e.tail=null; return e; }
fn AirCns* air_mk_ascribe(AirArena* a, AirTyp* t, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_ASCRIBE; e.ty=t; e.tail=k; return e; }
fn AirCns* air_mk_default(AirArena* a, AirCns* k)
    { AirCns* e=air_new_AirCns(a); if(e==null)return null; e.tag=ACNS_DEFAULT; e.tail=k; return e; }

// Patterns
fn AirPat* air_mk_pat(AirArena* a, AirPatTag tag)
    { AirPat* p=air_new_AirPat(a); if(p==null)return null; p.tag=tag; p.sub_count=0; p.field_count=0; p.name=null; p.ival=0; p.fval=0.0; p.as_pat=null; p.or_alt=null; p.ty=null; return p; }
fn AirPat* air_mk_pat_bind(AirArena* a, char* nm)
    { AirPat* p=air_mk_pat(a,APAT_BIND); if(p==null)return null; p.name=nm; return p; }
fn AirPat* air_mk_pat_int(AirArena* a, long v)
    { AirPat* p=air_mk_pat(a,APAT_INT); if(p==null)return null; p.ival=v; return p; }
fn AirPat* air_mk_pat_bool(AirArena* a, bool v)
    { AirPat* p=air_mk_pat(a,APAT_BOOL); if(p==null)return null; p.ival=v?1:0; return p; }
fn AirPat* air_mk_pat_variant(AirArena* a, char* nm, AirPat** subs, usz n) {
    AirPat* p=air_mk_pat(a,APAT_VARIANT); if(p==null)return null; p.name=nm;
    for(usz i=0;i<n&&i<16;i++){p.sub[i]=subs[i]; p.sub_count++;} return p;
}
fn AirPat* air_mk_pat_tuple(AirArena* a, AirPat** subs, usz n) {
    AirPat* p=air_mk_pat(a,APAT_TUPLE); if(p==null)return null;
    for(usz i=0;i<n&&i<16;i++){p.sub[i]=subs[i]; p.sub_count++;} return p;
}

// Types
fn AirTyp* air_mk_typ(AirArena* a, AirTypTag tag)
    { AirTyp* t=air_new_AirTyp(a); if(t==null)return null; t.tag=tag; t.arg_count=0; t.name=null; t.mult=AMULT_UNR; t.mult_exact=0; t.ival=0; t.fval=0.0; t.rec_field_count=0; t.eff_tail=null; t.eff_name=null; t.refine_extra=null; return t; }
fn AirTyp* air_mk_typ_named(AirArena* a, char* nm)
    { AirTyp* t=air_mk_typ(a,ATYP_NOMINAL); if(t==null)return null; t.name=nm; return t; }
fn AirTyp* air_mk_typ_var(AirArena* a, char* nm)
    { AirTyp* t=air_mk_typ(a,ATYP_VAR); if(t==null)return null; t.name=nm; return t; }
fn AirTyp* air_mk_typ_arrow(AirArena* a, AirTyp* dom, AirTyp* cod)
    { AirTyp* t=air_mk_typ(a,ATYP_ARROW); if(t==null)return null; t.add_arg(dom); t.add_arg(cod); return t; }
fn AirTyp* air_mk_typ_tuple(AirArena* a, AirTyp** args, usz n) {
    AirTyp* t=air_mk_typ(a,ATYP_TUPLE); if(t==null)return null;
    for(usz i=0;i<n&&i<8;i++)t.add_arg(args[i]); return t;
}
fn AirTyp* air_mk_typ_array(AirArena* a, AirTyp* elem, long len)
    { AirTyp* t=air_mk_typ(a,ATYP_ARRAY); if(t==null)return null; t.add_arg(elem); t.ival=len; return t; }
fn AirTyp* air_mk_typ_slice(AirArena* a, AirTyp* elem)
    { AirTyp* t=air_mk_typ(a,ATYP_SLICE); if(t==null)return null; t.add_arg(elem); return t; }
fn AirTyp* air_mk_typ_ptr(AirArena* a, AirTyp* pointee)
    { AirTyp* t=air_mk_typ(a,ATYP_PTR); if(t==null)return null; t.add_arg(pointee); return t; }
fn AirTyp* air_mk_typ_ref(AirArena* a, AirTyp* pointee, bool is_mut)
    { AirTyp* t=air_mk_typ(a,is_mut?ATYP_REF_MUT:ATYP_REF); if(t==null)return null; t.add_arg(pointee); return t; }
fn AirTyp* air_mk_typ_sum(AirArena* a, AirTyp** args, usz n) {
    AirTyp* t=air_mk_typ(a,ATYP_SUM); if(t==null)return null;
    for(usz i=0;i<n&&i<8;i++)t.add_arg(args[i]); return t;
}
fn AirTyp* air_mk_typ_union(AirArena* a, AirTyp* l, AirTyp* r)
    { AirTyp* t=air_mk_typ(a,ATYP_UNION); if(t==null)return null; t.add_arg(l); t.add_arg(r); return t; }
fn AirTyp* air_mk_typ_intersect(AirArena* a, AirTyp* l, AirTyp* r)
    { AirTyp* t=air_mk_typ(a,ATYP_INTERSECT); if(t==null)return null; t.add_arg(l); t.add_arg(r); return t; }
fn AirTyp* air_mk_typ_neg(AirArena* a, AirTyp* inner)
    { AirTyp* t=air_mk_typ(a,ATYP_NEGATION); if(t==null)return null; t.add_arg(inner); return t; }
fn AirTyp* air_mk_typ_forall(AirArena* a, char* tv, AirTyp* body)
    { AirTyp* t=air_mk_typ(a,ATYP_FORALL); if(t==null)return null; t.name=tv; t.add_arg(body); return t; }
fn AirTyp* air_mk_typ_exists(AirArena* a, char* tv, AirTyp* body)
    { AirTyp* t=air_mk_typ(a,ATYP_EXISTS); if(t==null)return null; t.name=tv; t.add_arg(body); return t; }
fn AirTyp* air_mk_typ_bang(AirArena* a, AirTyp* inner)
    { AirTyp* t=air_mk_typ(a,ATYP_BANG); if(t==null)return null; t.add_arg(inner); return t; }
fn AirTyp* air_mk_typ_query(AirArena* a, AirTyp* inner)
    { AirTyp* t=air_mk_typ(a,ATYP_QUERY); if(t==null)return null; t.add_arg(inner); return t; }
fn AirTyp* air_mk_typ_effrow_open(AirArena* a, char** effs, usz n, AirTyp* tail) {
    AirTyp* t=air_mk_typ(a,ATYP_EFFROW); if(t==null)return null;
    t.ival=(tail!=null)?1:0; t.eff_tail=tail;
    for(usz i=0;i<n&&i<8;i++){AirTyp* en=air_mk_typ_named(a,effs[i]); t.add_arg(en);}
    return t;
}

fn AirCtorDecl* air_mk_ctor_decl(AirArena* a, char* nm)
    { AirCtorDecl* c=air_new_AirCtorDecl(a); if(c==null)return null; c.name=nm; c.field_count=0; c.result_ty=null; return c; }
fn void AirCtorDecl.add_field(AirCtorDecl* c, AirField* f)
    { if(c==null||f==null)return; if(c.field_count>=64)return; c.fields[c.field_count]=f; c.field_count++; }
fn AirDtorDecl* air_mk_dtor_decl(AirArena* a, char* nm)
    { AirDtorDecl* d=air_new_AirDtorDecl(a); if(d==null)return null; d.name=nm; d.param_count=0; d.return_ty=null; return d; }
fn void AirDtorDecl.add_param(AirDtorDecl* d, AirField* f)
    { if(d==null||f==null)return; if(d.param_count>=64)return; d.params[d.param_count]=f; d.param_count++; }
fn AirEffectOp* air_mk_eff_op(AirArena* a, char* nm, AirTyp* sig)
    { AirEffectOp* o=air_new_AirEffectOp(a); if(o==null)return null; o.name=nm; o.op_ty=sig; return o; }
fn void AirDecl.add_ctor(AirDecl* d, AirCtorDecl* c)
    { if(d==null||c==null)return; if(d.ctor_count>=64)return; d.ctors[d.ctor_count]=c; d.ctor_count++; }
fn void AirDecl.add_dtor(AirDecl* d, AirDtorDecl* dd)
    { if(d==null||dd==null)return; if(d.dtor_count>=64)return; d.dtors[d.dtor_count]=dd; d.dtor_count++; }
fn void AirDecl.add_param(AirDecl* d, AirBinder* b)
    { if(d==null||b==null)return; if(d.param_count>=16)return; d.params[d.param_count]=b; d.param_count++; }
fn void AirDecl.add_typaram(AirDecl* d, AirBinder* b)
    { if(d==null||b==null)return; if(d.typaram_count>=16)return; d.typarams[d.typaram_count]=b; d.typaram_count++; }
fn void AirDecl.add_op(AirDecl* d, AirEffectOp* o)
    { if(d==null||o==null)return; if(d.op_count>=16)return; d.ops[d.op_count]=o; d.op_count++; }
