// ============================================================================
// air_types.c3 — PNode type annotation → AirTyp.
// ============================================================================
module air_types;
import pfront_core;
import air_ir;

alias Nk = pfront_core::NodeKind;

fn char* air_node_text(PNode* n, pfront_core::Interner* it) {
    if (n==null) return null;
    // Prefer the interned name: it is stable and never leaks source.
    if (it!=null && n.name_id!=0) return it.text(n.name_id);
    // For simple ident/type name nodes (leaf identifiers), sptr points to the
    // identifier span (safe). For anything with children (arrows, generics,
    // clauses) sptr spans the whole construct, so we must NOT return it.
    if (n.child_count == 0 && n.p.sptr!=null && n.p.slen>0
        && (n.kind == Nk.N_TY_NAME || n.kind == Nk.N_EXPR_IDENT
            || n.kind == Nk.N_PAT_IDENT)) {
        return n.p.sptr;
    }
    return null;
}
fn int cstrlen_t(char* s) {
    if (s==null) return 0; int n=0; while(s[n]!=0){n++;} return n;
}
fn bool streq_t(char* a, char* b) {
    if (a==null||b==null) return a==b;
    usz i=0; while(a[i]!=0&&b[i]!=0){if(a[i]!=b[i])return false;i++;} return a[i]==b[i];
}
fn AirTyp* air_prim_ty(AirModule* m, char* nm) {
    AirArena* a = m.arena;
    if (nm==null) return m.t_infer;
    if (streq_t(nm,"i8"))return m.t_i8; if (streq_t(nm,"i16"))return m.t_i16;
    if (streq_t(nm,"i32"))return m.t_i32; if (streq_t(nm,"i64"))return m.t_i64;
    if (streq_t(nm,"u8"))return m.t_u8; if (streq_t(nm,"u16"))return m.t_u16;
    if (streq_t(nm,"u32"))return m.t_u32; if (streq_t(nm,"u64"))return m.t_u64;
    if (streq_t(nm,"isz"))return m.t_isz; if (streq_t(nm,"usz"))return m.t_usz;
    if (streq_t(nm,"f16"))return air_ir::air_mk_typ(a,ATYP_F16);
    if (streq_t(nm,"f32"))return m.t_f32; if (streq_t(nm,"f64"))return m.t_f64;
    if (streq_t(nm,"f128"))return air_ir::air_mk_typ(a,ATYP_F128);
    if (streq_t(nm,"bool"))return m.t_bool; if (streq_t(nm,"char"))return m.t_char;
    if (streq_t(nm,"str"))return m.t_str; if (streq_t(nm,"bytes"))return m.t_bytes;
    return null;
}

fn AirTyp* air_translate_typ(AirModule* m, PNode* t, pfront_core::Interner* it, int depth) {
    AirArena* a = m.arena;
    if (depth > 64) return m.t_infer;
    if (t==null) return m.t_infer;
    if (t.type_ann!=null && t.type_ann!=t) return air_translate_typ(m, t.type_ann, it, depth+1);
    switch (t.kind) {
        case Nk.N_TY_INFER: return m.t_infer;
        case Nk.N_TY_UNIT: return m.t_unit;
        case Nk.N_TY_BOTTOM: return m.t_bottom;
        case Nk.N_TY_SELF: return air_ir::air_mk_typ(a, ATYP_SELF);
        case Nk.N_TY_PTR: {
            AirTyp* inner = t.child_count>0 ? air_translate_typ(m,t.children[0],it,depth+1) : m.t_infer;
            return air_ir::air_mk_typ_ptr(a, inner);
        }
        case Nk.N_TY_REF: {
            bool is_mut = (t.flags & pfront_core::NF_MUT) != 0;
            AirTyp* inner = t.child_count>0 ? air_translate_typ(m,t.children[0],it,depth+1) : m.t_infer;
            return air_ir::air_mk_typ_ref(a, inner, is_mut);
        }
        case Nk.N_TY_ARRAY: {
            AirTyp* elem = m.t_infer; long len = -1;
            if (t.child_count>=1) elem = air_translate_typ(m,t.children[0],it,depth+1);
            if (t.child_count>=2 && t.children[1]!=null) len = (long)t.children[1].p.ival;
            if (len<0) return air_ir::air_mk_typ_slice(a, elem);
            return air_ir::air_mk_typ_array(a, elem, len);
        }
        case Nk.N_TY_SLICE: {
            AirTyp* elem = t.child_count>0 ? air_translate_typ(m,t.children[0],it,depth+1) : m.t_infer;
            return air_ir::air_mk_typ_slice(a, elem);
        }
        case Nk.N_TY_TUPLE: {
            AirTyp*[8] subs; usz n=0;
            for (usz i=0; i<t.child_count&&i<8; i++){subs[n]=air_translate_typ(m,t.children[i],it,depth+1); n++;}
            return air_ir::air_mk_typ_tuple(a, &subs[0], n);
        }
        case Nk.N_TY_FN: {
            if (t.child_count==0) return air_ir::air_mk_typ_arrow(a,m.t_unit,m.t_unit);
            AirTyp* ret = air_translate_typ(m, t.children[t.child_count-1], it, depth+1);
            if (t.child_count==1) return air_ir::air_mk_typ_arrow(a,m.t_unit,ret);
            if (t.child_count==2){AirTyp* d=air_translate_typ(m,t.children[0],it,depth+1); return air_ir::air_mk_typ_arrow(a,d,ret);}
            AirTyp*[8] ds; usz dn=0;
            for(usz i=0;i+1<t.child_count&&dn<8;i++){ds[dn]=air_translate_typ(m,t.children[i],it,depth+1);dn++;}
            AirTyp* dom=air_ir::air_mk_typ_tuple(a,&ds[0],dn); return air_ir::air_mk_typ_arrow(a,dom,ret);
        }
        case Nk.N_TY_NAME: case Nk.N_TY_PATH: {
            char* nm=air_node_text(t,it); if(nm==null)return m.t_infer;
            AirTyp* prim=air_prim_ty(m,nm); if(prim!=null)return prim;
            return air_ir::air_mk_typ_named(a, a.dup(nm,(usz)cstrlen_t(nm)));
        }
        case Nk.N_TY_GENERIC: {
            if(t.child_count==0)return m.t_infer;
            char* nm=air_node_text(t.children[0],it); AirTyp* out;
            if(nm==null){out=m.t_infer;} else {
                AirTyp* prim=air_prim_ty(m,nm);
                if(prim!=null){out=prim;} else {out=air_ir::air_mk_typ_named(a,a.dup(nm,(usz)cstrlen_t(nm)));}
            }
            for(usz i=1;i<t.child_count&&i<8;i++){AirTyp* arg=air_translate_typ(m,t.children[i],it,depth+1); out.add_arg(arg);}
            out.tag=ATYP_GENERIC_APP; return out;
        }
        case Nk.N_TY_UNION: {
            if(t.child_count==0)return m.t_bottom;
            AirTyp* cur=air_translate_typ(m,t.children[0],it,depth+1);
            for(usz i=1;i<t.child_count;i++){AirTyp* nxt=air_translate_typ(m,t.children[i],it,depth+1); cur=air_ir::air_mk_typ_union(a,cur,nxt);}
            return cur;
        }
        case Nk.N_TY_INTERSECT: {
            if(t.child_count==0)return m.t_infer;
            AirTyp* cur=air_translate_typ(m,t.children[0],it,depth+1);
            for(usz i=1;i<t.child_count;i++){AirTyp* nxt=air_translate_typ(m,t.children[i],it,depth+1); cur=air_ir::air_mk_typ_intersect(a,cur,nxt);}
            return cur;
        }
        case Nk.N_TY_NEGATION: {
            AirTyp* inner=t.child_count>0?air_translate_typ(m,t.children[0],it,depth+1):m.t_infer;
            return air_ir::air_mk_typ_neg(a,inner);
        }
        case Nk.N_TY_FORALL: {
            if(t.child_count<2)return m.t_infer;
            char* tv=air_node_text(t.children[0],it); if(tv==null)tv=(char*)"_a";
            AirTyp* body=air_translate_typ(m,t.children[1],it,depth+1);
            return air_ir::air_mk_typ_forall(a,a.dup(tv,(usz)cstrlen_t(tv)),body);
        }
        case Nk.N_TY_EXISTS: {
            if(t.child_count<2)return m.t_infer;
            char* tv=air_node_text(t.children[0],it); if(tv==null)tv=(char*)"_e";
            AirTyp* body=air_translate_typ(m,t.children[1],it,depth+1);
            return air_ir::air_mk_typ_exists(a,a.dup(tv,(usz)cstrlen_t(tv)),body);
        }
        case Nk.N_TY_EFFECT_ROW: {
            char*[8] effs; usz n=0; AirTyp* tail=null;
            for(usz i=0;i<t.child_count&&n<8;i++){
                PNode* ch=t.children[i]; if(ch==null)continue;
                if(ch.kind==Nk.N_TY_EFFECT_ELEM){char*en=air_node_text(ch,it);if(en!=null){effs[n]=a.dup(en,(usz)cstrlen_t(en));n++;}}
                else if(ch.kind==Nk.N_TY_NAME||ch.kind==Nk.N_TY_PATH){tail=air_translate_typ(m,ch,it,depth+1);}
            }
            return air_ir::air_mk_typ_effrow_open(a,&effs[0],n,tail);
        }
        case Nk.N_TY_WHERE: case Nk.N_TY_CONSTRAINT: {
            if(t.child_count>0)return air_translate_typ(m,t.children[0],it,depth+1); return m.t_infer;
        }
        case Nk.N_TY_TYPEOF: return air_ir::air_mk_typ(a,ATYP_TYPEOF);
        case Nk.N_TY_REFINE: {
            AirTyp* rf=air_ir::air_mk_typ(a,ATYP_REFINE); rf.ival=t.p.op;
            if(t.child_count>0){rf.add_arg(air_translate_typ(m,t.children[0],it,depth+1));}
            return rf;
        }
        default: return m.t_infer;
    }
}

fn AirTyp* air_ty(AirModule* m, PNode* t, pfront_core::Interner* it) {
    return air_translate_typ(m, t, it, 0);
}
