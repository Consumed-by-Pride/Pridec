// ============================================================================
// theory_ssa.c3 — real-CFG SSA construction and rename plan
// ----------------------------------------------------------------------------
// This module implements the analysis half of Cytron et al.'s SSA algorithm
// over the actual basic blocks produced by pfront_cfg. It deliberately does
// not mutate the source AST or pretend to emit an SSA IR. Instead it builds an
// inspectable plan with source-binder identities, definition sites, phi nodes,
// value versions, use mappings, and ordered incoming operands.
//
// The pipeline has six stages:
//
//   1. Gather one CFG component per function clause, retaining every entry.
//   2. Compute a dominator forest with Cooper-Harvey-Kennedy iteration and
//      derive sparse dominance frontiers from real predecessor chains.
//   3. Identify parameters, local pattern binders, `let` sites, and direct
//      assignments by resolved binder pointer (not variable spelling).
//   4. Solve backward local-variable liveness as a separate fact table, then
//      place variable-specific phis through iterated dominance frontiers.
//   5. Walk the dominator forest to assign versions and map each local use;
//      resolve phi operands in exact predecessor order from block exits.
//   6. Audit CFG edge reciprocity, liveness transfer equations, small-graph
//      idom/DF reference equations, IDF closure, version identity, phi arity,
//      use dominance, and each phi operand's variable and dominance.
//
// The current phi placement is classic unpruned IDF. Liveness is reported as
// an independent checked fact set; this implementation does not yet use the
// set to suppress dead phis. `pfront_cfg` adjacency is bounded inline storage,
// so a saturated block makes the SSA result explicitly partial rather than
// certifying a graph whose predecessor or successor edges may have been lost.
//
// References:
//   Cytron et al. 1991, "Efficiently Computing Static Single Assignment Form"
//   Cooper/Harvey/Kennedy 2001, "A Simple, Fast Dominance Algorithm"
// ============================================================================

module theory_ssa;

import pfront_core;
import pfront_cfg;

alias Node  = pfront_core::PNode;
alias Nk    = pfront_core::NodeKind;
alias Arena = pfront_core::Arena;
alias Block = pfront_cfg::Block;
alias Cfg   = pfront_cfg::Cfg;

extern fn void* malloc(usz size);
extern fn void* calloc(usz nmemb, usz size);
extern fn void* realloc(void* ptr, long size);
extern fn void  free(void* ptr);
extern fn int   printf(char* fmt, ...);

const usz SSA_MAX_BLOCKS = 4096;
const usz SSA_MAX_DEFS = 8192;
const usz SSA_MAX_VARS = 2048;
const usz SSA_MAX_FN_ENTRIES = 1024;

struct SsaDef {
    Node* binder;
    Node* site;
    int block;
    int variable_id;
    int version;
    bool parameter;
}
struct SsaPhi {
    int variable_id;
    int block;
    usz incoming;
    int version;
    int* inputs;
}
struct SsaUse {
    Node* node;
    int block;
    int variable_id;
    int version;
}

struct SsaBuilder
{
    Arena* arena;
    // A null CFG means scan(root) builds real per-clause CFG components.
    Cfg* cfg;
    Node* root;
    int* entries;
    usz entry_count;
    Node** vars;
    usz var_count;
    SsaDef* defs;
    usz def_count;
    SsaUse* uses;
    usz use_count;
    usz use_capacity;
    SsaPhi* phis;
    usz phi_count;
    usz phi_capacity;
    char* live_in;
    char* live_gen;
    char* live_kill;
    usz live_iters;
    usz live_bits;
    usz live_equation_errors;
    usz cfg_edge_errors;
    usz use_dom_errors;
    usz phi_arg_errors;
    int next_version;
    usz unresolved_uses;
    usz rename_errors;
    usz duplicate_defs;
    usz idom_errors;
    usz df_errors;
    bool overflow;

    // Dom tree
    int*    idom;
    // immediate dominator per block
    int*    sdom;
    // semi-dominator not used; we do Cooper-style iters
    usz     dom_iters;

    // Dom tree children
    int** dom_kids;
    usz* dom_kid_count;
    usz* dom_kid_cap;

    // Sparse dominance-frontier rows.
    int** df;
    usz* df_count;
    usz* df_cap;

    // Stats
    usz     n_blocks;
    usz     n_dom;
    usz     n_df;
    usz     n_phi;
    usz     n_defs;
    usz     n_renamed;
    usz     n_critical_edges;
    usz     n_ssaable;
    bool    built;
}

fn void SsaBuilder.init(SsaBuilder* b, Arena* a, Cfg* cfg)
{
    b.arena = a;
    b.cfg = cfg;
    b.root = null;
    b.built = false;
    b.n_blocks=0;
    b.n_dom=0;
    b.n_df=0;
    b.n_phi=0;
    b.n_defs=0;
    b.n_renamed=0;
    b.n_critical_edges=0;
    b.n_ssaable=0;
    b.dom_iters=0;
    b.entries=null;
    b.entry_count=0;
    b.vars=null;
    b.var_count=0;
    b.defs=null;
    b.def_count=0;
    b.uses=null;
    b.use_count=0;
    b.use_capacity=0;
    b.phis=null;
    b.phi_count=0;
    b.phi_capacity=0;
    b.next_version=0;
    b.unresolved_uses=0;
    b.rename_errors=0;
    b.duplicate_defs=0;
    b.idom_errors=0;
    b.df_errors=0;
    b.overflow=false;
    b.live_in=null;
    b.live_gen=null;
    b.live_kill=null;
    b.live_iters=0;
    b.live_bits=0;
    b.live_equation_errors=0;
    b.cfg_edge_errors=0;
    b.use_dom_errors=0;
    b.phi_arg_errors=0;
    b.idom=null;
    b.sdom=null;
    b.dom_kids=null;
    b.dom_kid_count=null;
    b.dom_kid_cap=null;
    b.df=null;
    b.df_count=null;
    b.df_cap=null;
}

fn bool SsaBuilder.allocate_graph(SsaBuilder* b)
{
    if (b.cfg == null || b.cfg.block_count == 0) return false;
    b.n_blocks = b.cfg.block_count;
    if (b.n_blocks > SSA_MAX_BLOCKS) {
        b.n_blocks=SSA_MAX_BLOCKS;
        b.overflow=true;
    }
    b.idom=(int*)malloc((long)(b.n_blocks*4));
    b.sdom=(int*)malloc((long)(b.n_blocks*4));
    b.dom_kids=(int**)calloc(b.n_blocks,8);
    b.dom_kid_count=(usz*)calloc(b.n_blocks,8);
    b.dom_kid_cap=(usz*)calloc(b.n_blocks,8);
    b.df=(int**)calloc(b.n_blocks,8);
    b.df_count=(usz*)calloc(b.n_blocks,8);
    b.df_cap=(usz*)calloc(b.n_blocks,8);
    if(b.entries==null) b.entries=(int*)malloc((long)(SSA_MAX_FN_ENTRIES*4));
    if(b.vars==null) b.vars=(Node**)calloc(SSA_MAX_VARS,8);
    if(b.defs==null) b.defs=(SsaDef*)calloc(SSA_MAX_DEFS,SsaDef::size);
    if(b.idom==null||b.sdom==null||b.dom_kids==null||b.dom_kid_count==null||b.dom_kid_cap==null||b.df==null||b.df_count==null||b.df_cap==null||b.entries==null||b.vars==null||b.defs==null) {
        b.overflow=true;
        return false;
    }
    for(usz i=0;i<b.n_blocks;i++) {
        b.idom[i]=-1;
        b.sdom[i]=0;
    }
    return true;
}

// ── Intersect helper for Cooper-Harvey-Kennedy ────────────────────────
fn int ssa_intersect(SsaBuilder* b, int a, int other)
{
    if (a < 0 || other < 0 || (usz)a >= b.n_blocks || (usz)other >= b.n_blocks) return -1;
    char* mark=(char*)calloc(b.n_blocks,1);
    if(mark==null) {
        b.overflow=true;
        return -1;
    }
    int cur=a;
    usz steps=0;
    while(cur>=0&&(usz)cur<b.n_blocks&&steps<=b.n_blocks) {
        if(mark[cur]!=0)break;
        mark[cur]=1;
        steps=steps+1;
        if(b.idom[cur]==cur)break;
        cur=b.idom[cur];
    }
    cur=other;
    steps=0;
    while(cur>=0&&(usz)cur<b.n_blocks&&steps<=b.n_blocks) {
        if(mark[cur]!=0) {
            free((void*)mark);
            return cur;
        }
        if(b.idom[cur]==cur)break;
        cur=b.idom[cur];
        steps=steps+1;
    }
    free((void*)mark);
    return -1;
}

fn void ssa_compute_rpo(SsaBuilder* b, int* rpo, usz* count)
{
    *count=0;
    if(b.cfg==null)return;
    char* state=(char*)calloc(b.n_blocks,1);
    int* post=(int*)malloc((long)(b.n_blocks*4));
    int* stack=(int*)malloc((long)(b.n_blocks*8));
    int* phase=(int*)malloc((long)(b.n_blocks*4));
    if(state==null||post==null||stack==null||phase==null) {
        b.overflow=true;
        free((void*)state);
        free((void*)post);
        free((void*)stack);
        free((void*)phase);
        return;
    }
    for(usz pass=0;pass<2;pass++) {
        usz limit=pass==0?b.entry_count:b.n_blocks;
        for(usz ri=0;ri<limit;ri++) {
            int root=pass==0?b.entries[ri]:(int)ri;
            if(root<0||(usz)root>=b.n_blocks||state[root]!=0)continue;
            b.sdom[root]=1;
            state[root]=1;
            usz sp=0;
            stack[sp]=root;
            phase[sp]=0;
            sp=sp+1;
            while(sp>0) {
                sp=sp-1;
                int node=stack[sp];
                int p=phase[sp];
                if(p==1) {
                    state[node]=2;
                    post[*count]=(int)node;
                    *count=*count+1;
                    continue;
                }
                stack[sp]=node;
                phase[sp]=1;
                sp=sp+1;
                Block* bl=&b.cfg.blocks[node];
                for(long si=(long)bl.succ_count-1;si>=0;si=si-1) {
                    int child=bl.succs[si];
                    if(child<0||(usz)child>=b.n_blocks||state[child]!=0)continue;
                    state[child]=1;
                    stack[sp]=child;
                    phase[sp]=0;
                    sp=sp+1;
                }
            }
        }
    }
    usz total = *count;
    for (usz i=0; i<total; i++) {
        rpo[i] = post[total - 1 - i];
    }
    free((void*)state);
    free((void*)post);
    free((void*)stack);
    free((void*)phase);
}

fn bool ssa_adj_push(int** rows, usz* counts, usz* caps, usz row, int value, usz limit)
{
    if(counts[row]>=limit)return false;
    if(counts[row]>=caps[row]) {
        usz next=caps[row]==0?4:caps[row]*2;
        if(next>limit)next=limit;
        int* mem=(int*)realloc((void*)rows[row],(long)(next*4));
        if(mem==null)return false;
        rows[row]=mem;
        caps[row]=next;
    }
    rows[row][counts[row]]=value;
    counts[row]=counts[row]+1;
    return true;
}

fn void SsaBuilder.build_dom(SsaBuilder* b)
{
    if(b.cfg==null||b.n_blocks==0)return;
    int* rpo=(int*)malloc((long)(b.n_blocks*4));
    if(rpo==null) {
        b.overflow=true;
        return;
    }
    usz n=0;
    ssa_compute_rpo(b,rpo,&n);
    for(usz i=0;i<b.n_blocks;i++)b.idom[i]=b.sdom[i]!=0?(int)i:-1;
    bool changed=true;
    usz it=0;
    while(changed&&it<b.n_blocks+1) {
        changed=false;
        it=it+1;
        for(usz ri=0;ri<n;ri++) {
            int node=rpo[ri];
            if(b.sdom[node]!=0)continue;
            Block* bl=&b.cfg.blocks[node];
            int candidate=-1;
            for(usz pi=0;pi<bl.pred_count;pi++) {
                int pred=bl.preds[pi];
                if(pred<0||(usz)pred>=b.n_blocks||b.idom[pred]<0)continue;
                if(candidate<0) {
                    candidate=pred;
                }
                else {
                    candidate=ssa_intersect(b,pred,candidate);
                }
            }
            if(candidate>=0&&b.idom[node]!=candidate) {
                b.idom[node]=candidate;
                changed=true;
            }
        }
    }
    b.dom_iters=it;
    b.n_dom=n;
    for(usz i=0;i<b.n_blocks;i++)b.dom_kid_count[i]=0;
    for(usz ri=0;ri<n;ri++) {
        int child=rpo[ri];
        int parent=b.idom[child];
        if(parent>=0&&parent!=child) {
            if(!ssa_adj_push(b.dom_kids,b.dom_kid_count,b.dom_kid_cap,(usz)parent,child,b.n_blocks))b.overflow=true;
        }
        else if(parent<0)b.idom_errors=b.idom_errors+1;
    }
    free((void*)rpo);
}

// ── Dominance frontier: Cytron's runner algorithm over real predecessors ───
fn void SsaBuilder.build_df(SsaBuilder* b)
{
    for (usz i=0;i<b.n_blocks;i++) b.df_count[i]=0;
    b.n_df=0;
    if(b.cfg==null)return;
    for(usz target=0;target<b.n_blocks;target++) {
        Block* join=&b.cfg.blocks[target];
        if(join.pred_count<2)continue;
        for(usz pi=0;pi<join.pred_count;pi++) {
            int runner=join.preds[pi];
            if(runner<0||(usz)runner>=b.n_blocks) {
                b.df_errors++;
                continue;
            }
            usz guard=0;
            while(runner!=b.idom[target]&&guard++<b.n_blocks) {
                if(b.idom[runner]<0) {
                    b.df_errors++;
                    break;
                }
                bool duplicate=false;
                for(usz k=0;k<b.df_count[runner];k++)if(b.df[runner][k]==(int)target)duplicate=true;
                if(!duplicate) {
                    if(ssa_adj_push(b.df,b.df_count,b.df_cap,(usz)runner,(int)target,b.n_blocks)) {
                        b.n_df++;
                    }
                    else {
                        b.overflow=true;
                    }
                }
                if(b.idom[runner]==runner)break;
                runner=b.idom[runner];
            }
            if(guard>=b.n_blocks)b.df_errors++;
        }
    }
}

// Source definitions have two identities: the binder is the variable, while
// the site distinguishes each value assigned to that variable.
fn int SsaBuilder.var_id(SsaBuilder* b,Node* binder)
{
    if(binder==null)return -1;
    for(usz i=0;i<b.var_count;i++)if(b.vars[i]==binder)return (int)i;
    if(b.var_count>=SSA_MAX_VARS) {
        b.overflow=true;
        return -1;
    }
    int result=(int)b.var_count;
    b.vars[b.var_count]=binder;
    b.var_count++;
    return result;
}

fn void SsaBuilder.add_def(SsaBuilder* b,Node* binder,Node* site,int block,bool parameter)
{
    if(binder==null||site==null||block<0||(usz)block>=b.n_blocks)return;
    for(usz i=0;i<b.def_count;i++)if(b.defs[i].binder==binder&&b.defs[i].site==site&&b.defs[i].block==block) {
        b.duplicate_defs++;
        return;
    }
    if(b.def_count>=SSA_MAX_DEFS) {
        b.overflow=true;
        return;
    }
    int v=b.var_id(binder);
    if(v<0)return;
    SsaDef* d=&b.defs[b.def_count];
    d.binder=binder;
    d.site=site;
    d.block=block;
    d.variable_id=v;
    d.version=-1;
    d.parameter=parameter;
    b.def_count++;
}

fn void SsaBuilder.add_pattern(SsaBuilder* b,Node* pat,Node* site,int block,int depth,bool parameter)
{
    if(pat==null||depth>64)return;
    if(pat.kind==Nk.N_PAT_IDENT) {
        b.add_def(pat,site,block,parameter);
        return;
    }
    for(usz i=0;i<pat.child_count;i++)b.add_pattern(pat.children[i],site,block,depth+1,parameter);
}

fn void SsaBuilder.collect_defs(SsaBuilder* b,Node* n,int block,int depth)
{
    if(n==null||depth>128||n.kind==Nk.N_DECL_FN||n.kind==Nk.N_EXPR_LAMBDA)return;
    if(n.kind==Nk.N_DECL_LET) {
        for(usz i=0;i<n.child_count;i++) {
            Node* c=n.children[i];
            if(c!=null&&pfront_core::is_pattern(c.kind)) {
                b.add_pattern(c,n,block,0,false);
                break;
            }
        }
    }
    else if(n.kind==Nk.N_STMT_ASSIGN||n.kind==Nk.N_STMT_COMPOUND_ASSIGN||n.kind==Nk.N_EXPR_ASSIGN) {
        Node* lhs=n.child_count>0?n.children[0]:null;
        // A field/index store mutates memory, not the scalar SSA value of base.
        if(lhs!=null&&lhs.kind==Nk.N_EXPR_IDENT&&lhs.resolved!=null)b.add_def(lhs.resolved,n,block,false);
    }
    for(usz i=0;i<n.child_count;i++)b.collect_defs(n.children[i],block,depth+1);
}

fn void SsaBuilder.collect_stmt_defs(SsaBuilder* b)
{
    for(usz bi=0;bi<b.n_blocks;bi++) {
        Block* bl=&b.cfg.blocks[bi];
        for(usz si=0;si<bl.stmt_count;si++)b.collect_defs(bl.stmts[si],(int)bi,0);
        if(bl.term_node!=null)b.collect_defs(bl.term_node,(int)bi,0);
    }
}

fn bool ssa_append_body(Cfg* cfg,SsaBuilder* b,Node* body)
{
    if(body==null)return false;
    if(cfg.blocks==null&&!cfg.allocate())return false;
    cfg.loop_sp=0;
    int entry=cfg.new_block();
    if(entry<0||b.entry_count>=SSA_MAX_FN_ENTRIES) {
        b.overflow=true;
        return false;
    }
    b.entries[b.entry_count]=entry;
    b.entry_count++;
    cfg.set_cur(entry);
    cfg.walk(body);
    if(cfg.cur>=0&&cfg.blocks[cfg.cur].term==pfront_cfg::TermKind.TERM_FALL)cfg.terminate(pfront_cfg::TermKind.TERM_RETURN);
    b.n_blocks=cfg.block_count;
    return true;
}

fn void SsaBuilder.collect_functions(SsaBuilder* b,Cfg* cfg,Node* n,int depth)
{
    if(n==null||depth>200)return;
    if(n.kind==Nk.N_DECL_FN) {
        for(usz i=0;i<n.child_count;i++) {
            Node* clause=n.children[i];
            if(clause==null)continue;
            if(clause.kind==Nk.N_CLAUSE) {
                Node* body=null;
                for(usz j=0;j<clause.child_count;j++) {
                    Node* c=clause.children[j];
                    if(c!=null&&!pfront_core::is_pattern(c.kind))body=c;
                }
                if(body!=null&&ssa_append_body(cfg,b,body)) {
                    int entry=b.entries[b.entry_count-1];
                    for(usz j=0;j<clause.child_count;j++) {
                        Node* pat=clause.children[j];
                        if(pat!=null&&pfront_core::is_pattern(pat.kind))b.add_pattern(pat,clause,entry,0,true);
                    }
                }
            }
            else if(clause.kind==Nk.N_BLOCK&&ssa_append_body(cfg,b,clause)) {
                int entry=b.entries[b.entry_count-1];
                for(usz j=0;j<n.child_count;j++) {
                    Node* param=n.children[j];
                    if(param!=null&&param.kind==Nk.N_DECL_PARAM)b.add_pattern(param,param,entry,0,true);
                }
            }
        }
        return;
    }
    for(usz i=0;i<n.child_count;i++)b.collect_functions(cfg,n.children[i],depth+1);
}

fn bool ssa_cfg_is_saturated(Cfg* cfg,usz n)
{
    if(cfg==null)return true;
    for(usz i=0;i<n;i++)if(cfg.blocks[i].succ_count>=pfront_cfg::MAX_SUCCS||cfg.blocks[i].pred_count>=pfront_cfg::MAX_PREDS||cfg.blocks[i].match_target_count>=16)return true;
    return false;
}

fn bool SsaBuilder.push_phi(SsaBuilder* b,int variable_id,int block,usz incoming)
{
    if(b.phi_count>=b.phi_capacity) {
        usz next=b.phi_capacity==0?32:b.phi_capacity*2;
        if(next>SSA_MAX_VARS*SSA_MAX_BLOCKS)next=SSA_MAX_VARS*SSA_MAX_BLOCKS;
        if(next<=b.phi_capacity) {
            b.overflow=true;
            return false;
        }
        SsaPhi* mem=(SsaPhi*)realloc((void*)b.phis,(long)(next*SsaPhi::size));
        if(mem==null) {
            b.overflow=true;
            return false;
        }
        b.phis=mem;
        b.phi_capacity=next;
    }
    SsaPhi* p=&b.phis[b.phi_count];
    p.variable_id=variable_id;
    p.block=block;
    p.incoming=incoming;
    p.version=-1;
    p.inputs=null;
    b.phi_count++;
    return true;
}

fn int SsaBuilder.lookup_var(SsaBuilder* b,Node* binder)
{
    if(binder==null)return -1;
    for(usz i=0;i<b.var_count;i++)if(b.vars[i]==binder)return (int)i;
    return -1;
}

fn void SsaBuilder.live_use(SsaBuilder* b,Node* n,usz block,char* gen,char* kill,int depth)
{
    if(n==null||depth>128||pfront_core::is_pattern(n.kind))return;
    if(n.kind==Nk.N_EXPR_IDENT) {
        int v=b.lookup_var(n.resolved);
        if(v>=0) {
            usz cell=block*b.var_count+(usz)v;
            if(kill[cell]==0)gen[cell]=1;
        }
        return;
    }
    if(n.kind==Nk.N_DECL_LET) {
        for(usz i=0;i<n.child_count;i++) {
            Node* c=n.children[i];
            if(c!=null&&!pfront_core::is_pattern(c.kind))b.live_use(c,block,gen,kill,depth+1);
        }
        for(usz d=0;d<b.def_count;d++)if(b.defs[d].site==n&&b.defs[d].block==(int)block)kill[block*b.var_count+(usz)b.defs[d].variable_id]=1;
        return;
    }
    if(n.kind==Nk.N_STMT_ASSIGN||n.kind==Nk.N_STMT_COMPOUND_ASSIGN||n.kind==Nk.N_EXPR_ASSIGN) {
        Node* lhs=n.child_count>0?n.children[0]:null;
        bool direct=lhs!=null&&lhs.kind==Nk.N_EXPR_IDENT;
        if(!direct||n.kind==Nk.N_STMT_COMPOUND_ASSIGN)if(lhs!=null)b.live_use(lhs,block,gen,kill,depth+1);
        for(usz i=1;i<n.child_count;i++)b.live_use(n.children[i],block,gen,kill,depth+1);
        for(usz d=0;d<b.def_count;d++)if(b.defs[d].site==n&&b.defs[d].block==(int)block)kill[block*b.var_count+(usz)b.defs[d].variable_id]=1;
        return;
    }
    for(usz i=0;i<n.child_count;i++)b.live_use(n.children[i],block,gen,kill,depth+1);
}

// Standard backward may-liveness over the same CFG and definition universe.
// Liveness is kept as an independent fact table; this builder currently uses
// classic unpruned IDF placement and does not infer variable live-in facts from
// a phi count or from predecessor arity.
fn void SsaBuilder.compute_liveness(SsaBuilder* b)
{
    usz cells=b.n_blocks*b.var_count;
    if(cells==0) {
        b.live_in=null;
        return;
    }
    char* gen=(char*)calloc(cells,1);
    char* kill=(char*)calloc(cells,1);
    char* out=(char*)calloc(cells,1);
    char* in=(char*)calloc(cells,1);
    if(gen==null||kill==null||out==null||in==null) {
        b.overflow=true;
        free((void*)gen);
        free((void*)kill);
        free((void*)out);
        free((void*)in);
        return;
    }
    for(usz d=0;d<b.def_count;d++)if(b.defs[d].parameter) {
        usz cell=(usz)b.defs[d].block*b.var_count+(usz)b.defs[d].variable_id;
        kill[cell]=1;
    }
    for(usz block=0;block<b.n_blocks;block++) {
        Block* bl=&b.cfg.blocks[block];
        for(usz s=0;s<bl.stmt_count;s++)b.live_use(bl.stmts[s],block,gen,kill,0);
        if(bl.term_node!=null)b.live_use(bl.term_node,block,gen,kill,0);
    }
    bool changed=true;
    usz iterations=0;
    while(changed&&iterations<=b.n_blocks+1) {
        changed=false;
        iterations++;
        for(long bi=(long)b.n_blocks-1;bi>=0;bi--) {
            Block* bl=&b.cfg.blocks[bi];
            for(usz v=0;v<b.var_count;v++) {
                usz cell=(usz)bi*b.var_count+v;
                char next_out=0;
                for(usz si=0;si<bl.succ_count;si++) {
                    int succ=bl.succs[si];
                    if(succ>=0&&(usz)succ<b.n_blocks&&in[(usz)succ*b.var_count+v]!=0)next_out=1;
                }
                char next_in=(char)(gen[cell]!=0||(next_out!=0&&kill[cell]==0));
                if(out[cell]!=next_out||in[cell]!=next_in) {
                    out[cell]=next_out;
                    in[cell]=next_in;
                    changed=true;
                }
            }
        }
    }
    if(changed)b.overflow=true;
    for(usz i=0;i<cells;i++)if(in[i]!=0)b.live_bits++;
    b.live_iters=iterations;
    b.live_in=in;
    b.live_gen=gen;
    b.live_kill=kill;
    free((void*)out);
}

// IDF closure is run independently for each source variable. The byte matrices
// are bounded by SSA_MAX_VARS × SSA_MAX_BLOCKS and released before renaming.
fn void SsaBuilder.insert_phi(SsaBuilder* b)
{
    b.phi_count=0;
    b.n_phi=0;
    b.n_defs=b.def_count;
    if(b.var_count==0||b.n_blocks==0)return;
    usz cells=b.var_count*b.n_blocks;
    char* defs=(char*)calloc(cells,1);
    char* placed=(char*)calloc(cells,1);
    int* work=(int*)malloc((long)(b.n_blocks*4));
    if(defs==null||placed==null||work==null) {
        b.overflow=true;
        free((void*)defs);
        free((void*)placed);
        free((void*)work);
        return;
    }
    for(usz d=0;d<b.def_count;d++)defs[(usz)b.defs[d].variable_id*b.n_blocks+(usz)b.defs[d].block]=1;
    for(usz v=0;v<b.var_count;v++) {
        char* queued=(char*)calloc(b.n_blocks,1);
        if(queued==null) {
            b.overflow=true;
            continue;
        }
        usz tail=0;
        usz head=0;
        for(usz block=0;block<b.n_blocks;block++)if(defs[v*b.n_blocks+block]!=0) {
            work[tail]=(int)block;
            tail++;
            queued[block]=1;
        }
        while(head<tail) {
            int source=work[head++];
            for(usz k=0;k<b.df_count[source];k++) {
                int target=b.df[source][k];
                if(target<0||(usz)target>=b.n_blocks) {
                    b.df_errors++;
                    continue;
                }
                usz cell=v*b.n_blocks+(usz)target;
                if(placed[cell]!=0||b.cfg.blocks[target].pred_count<2)continue;
                placed[cell]=1;
                if(!b.push_phi((int)v,target,b.cfg.blocks[target].pred_count))continue;
                if(defs[cell]==0&&queued[target]==0&&tail<b.n_blocks) {
                    work[tail]=target;
                    tail++;
                    queued[target]=1;
                }
            }
        }
        free((void*)queued);
    }
    b.n_phi=b.phi_count;
    b.n_renamed=b.def_count+b.phi_count;
    free((void*)defs);
    free((void*)placed);
    free((void*)work);
}

fn void SsaBuilder.find_critical(SsaBuilder* b)
{
    b.n_critical_edges=0;
    if(b.cfg==null)return;
    for(usz i=0;i<b.n_blocks;i++) {
        Block* bl=&b.cfg.blocks[i];
        if(bl.succ_count<2)continue;
        for(usz j=0;j<bl.succ_count;j++) {
            int s=bl.succs[j];
            if(s>=0&&(usz)s<b.n_blocks&&b.cfg.blocks[s].pred_count>=2)b.n_critical_edges++;
        }
    }
}

// A local identifier use stores the current SSA version without mutating PNode.
fn int SsaBuilder.new_version(SsaBuilder* b) {
    int out=b.next_version;
    if(b.next_version<2147483646) {
        b.next_version++;
    }
    else {
        b.overflow=true;
    }
    return out;
}

fn void SsaBuilder.apply_defs(SsaBuilder* b,Node* site,int block,int* env)
{
    for(usz i=0;i<b.def_count;i++) {
        SsaDef* d=&b.defs[i];
        if(d.site==site&&d.block==block) {
            if(d.version<0)d.version=b.new_version();
            env[d.variable_id]=d.version;
        }
    }
}

fn void SsaBuilder.record_use(SsaBuilder* b,Node* node,int block,int* env)
{
    if(node==null||node.resolved==null)return;
    int v=-1;
    for(usz i=0;i<b.var_count;i++)if(b.vars[i]==node.resolved) {
        v=(int)i;
        break;
    }
    if(v<0)return;
    if(b.use_count>=65536) {
        b.overflow=true;
        return;
    }
    if(b.use_count>=b.use_capacity) {
        usz next=b.use_capacity==0?64:b.use_capacity*2;
        if(next>65536)next=65536;
        SsaUse* mem=(SsaUse*)realloc((void*)b.uses,(long)(next*SsaUse::size));
        if(mem==null) {
            b.overflow=true;
            return;
        }
        b.uses=mem;
        b.use_capacity=next;
    }
    SsaUse* u=&b.uses[b.use_count];
    u.node=node;
    u.block=block;
    u.variable_id=v;
    u.version=env[v];
    b.use_count++;
    if(u.version<0)b.unresolved_uses++;
}

fn void SsaBuilder.rename_captures(SsaBuilder* b,Node* n,int block,int* env,int depth)
{
    if(n==null||depth>128||pfront_core::is_pattern(n.kind))return;
    if(n.kind==Nk.N_EXPR_IDENT) {
        b.record_use(n,block,env);
        return;
    }
    for(usz i=0;i<n.child_count;i++)b.rename_captures(n.children[i],block,env,depth+1);
}

fn void SsaBuilder.rename_node(SsaBuilder* b,Node* n,int block,int* env,int depth)
{
    if(n==null||depth>128||pfront_core::is_pattern(n.kind))return;
    if(n.kind==Nk.N_DECL_FN||n.kind==Nk.N_EXPR_LAMBDA) {
        b.rename_captures(n,block,env,depth+1);
        return;
    }
    if(n.kind==Nk.N_DECL_LET) {
        for(usz i=0;i<n.child_count;i++) {
            Node* c=n.children[i];
            if(c!=null&&!pfront_core::is_pattern(c.kind))b.rename_node(c,block,env,depth+1);
        }
        b.apply_defs(n,block,env);
        return;
    }
    if(n.kind==Nk.N_STMT_ASSIGN||n.kind==Nk.N_STMT_COMPOUND_ASSIGN||n.kind==Nk.N_EXPR_ASSIGN) {
        Node* lhs=n.child_count>0?n.children[0]:null;
        bool direct=lhs!=null&&lhs.kind==Nk.N_EXPR_IDENT;
        if(!direct||n.kind==Nk.N_STMT_COMPOUND_ASSIGN) {
            if(lhs!=null)b.rename_node(lhs,block,env,depth+1);
        }
        for(usz i=1;i<n.child_count;i++)b.rename_node(n.children[i],block,env,depth+1);
        b.apply_defs(n,block,env);
        return;
    }
    if(n.kind==Nk.N_EXPR_IDENT) {
        b.record_use(n,block,env);
        return;
    }
    for(usz i=0;i<n.child_count;i++)b.rename_node(n.children[i],block,env,depth+1);
}

fn void SsaBuilder.rename_block(SsaBuilder* b,int block,int* parent,int* exits,int depth)
{
    if(block<0||(usz)block>=b.n_blocks||depth>(int)b.n_blocks)return;
    int* env=(int*)malloc((long)(b.var_count*4));
    if(env==null&&b.var_count>0) {
        b.overflow=true;
        return;
    }
    for(usz v=0;v<b.var_count;v++)env[v]=parent!=null?parent[v]:-1;
    for(usz d=0;d<b.def_count;d++) {
        SsaDef* def=&b.defs[d];
        if(def.parameter&&def.block==block) {
            if(def.version<0)def.version=b.new_version();
            env[def.variable_id]=def.version;
        }
    }
    for(usz p=0;p<b.phi_count;p++) {
        SsaPhi* phi=&b.phis[p];
        if(phi.block==block) {
            if(phi.version<0)phi.version=b.new_version();
            env[phi.variable_id]=phi.version;
        }
    }
    Block* cfg_block=&b.cfg.blocks[block];
    for(usz s=0;s<cfg_block.stmt_count;s++)b.rename_node(cfg_block.stmts[s],block,env,0);
    if(cfg_block.term_node!=null)b.rename_node(cfg_block.term_node,block,env,0);
    for(usz v=0;v<b.var_count;v++)exits[(usz)block*b.var_count+v]=env[v];
    for(usz k=0;k<b.dom_kid_count[block];k++)b.rename_block(b.dom_kids[block][k],env,exits,depth+1);
    free((void*)env);
}

fn void SsaBuilder.complete_rename(SsaBuilder* b)
{
    b.next_version=0;
    b.use_count=0;
    b.use_capacity=0;
    b.unresolved_uses=0;
    b.rename_errors=0;
    if(b.uses!=null) {
        free((void*)b.uses);
        b.uses=null;
    }
    for(usz i=0;i<b.def_count;i++)b.defs[i].version=-1;
    for(usz i=0;i<b.phi_count;i++)b.phis[i].version=-1;
    usz cells=b.n_blocks*b.var_count;
    int* exits=(int*)malloc((long)(cells*4));
    if(exits==null&&cells>0) {
        b.overflow=true;
        return;
    }
    for(usz i=0;i<cells;i++)exits[i]=-1;
    for(usz i=0;i<b.n_blocks;i++)if(b.idom[i]==(int)i)b.rename_block((int)i,null,exits,0);
    for(usz p=0;p<b.phi_count;p++) {
        SsaPhi* phi=&b.phis[p];
        Block* target=&b.cfg.blocks[phi.block];
        if(phi.incoming>0)phi.inputs=(int*)malloc((long)(phi.incoming*4));
        if(phi.inputs==null&&phi.incoming>0) {
            b.overflow=true;
            continue;
        }
        usz out=0;
        for(usz j=0;j<target.pred_count&&out<phi.incoming;j++) {
            int pred=target.preds[j];
            int value=pred>=0&&(usz)pred<b.n_blocks?exits[(usz)pred*b.var_count+(usz)phi.variable_id]:-1;
            phi.inputs[out++]=value;
            if(value<0)b.rename_errors++;
        }
    }
    b.n_renamed=(usz)b.next_version;
    free((void*)exits);
}

fn bool SsaBuilder.dominates(SsaBuilder* b,int dom,int node)
{
    if(dom<0||node<0||(usz)dom>=b.n_blocks||(usz)node>=b.n_blocks)return false;
    int cur=node;
    usz steps=0;
    while(cur>=0&&(usz)cur<b.n_blocks&&steps<=b.n_blocks) {
        if(cur==dom)return true;
        if(b.idom[cur]==cur)return false;
        cur=b.idom[cur];
        steps++;
    }
    return false;
}

fn bool SsaBuilder.version_exists(SsaBuilder* b,int version)
{
    if(version<0)return false;
    for(usz i=0;i<b.def_count;i++)if(b.defs[i].version==version)return true;
    for(usz i=0;i<b.phi_count;i++)if(b.phis[i].version==version)return true;
    return false;
}

fn void SsaBuilder.verify_idf(SsaBuilder* b)
{
    usz cells=b.var_count*b.n_blocks;
    int* work=(int*)malloc((long)(b.n_blocks*4));
    char* queued=(char*)calloc(b.n_blocks,1);
    char* defs=(char*)calloc(b.n_blocks,1);
    char* expected=(char*)calloc(b.n_blocks,1);
    char* actual=(char*)calloc(cells,1);
    if((work==null||queued==null||defs==null||expected==null||actual==null)&&(b.n_blocks>0||cells>0)) {
        b.overflow=true;
        free((void*)work);
        free((void*)queued);
        free((void*)defs);
        free((void*)expected);
        free((void*)actual);
        return;
    }
    for(usz p=0;p<b.phi_count;p++)if(b.phis[p].variable_id>=0&&(usz)b.phis[p].variable_id<b.var_count&&b.phis[p].block>=0&&(usz)b.phis[p].block<b.n_blocks)actual[(usz)b.phis[p].variable_id*b.n_blocks+(usz)b.phis[p].block]=1;
    for(usz v=0;v<b.var_count;v++) {
        for(usz i=0;i<b.n_blocks;i++) {
            queued[i]=0;
            defs[i]=0;
            expected[i]=0;
        }
        for(usz d=0;d<b.def_count;d++)if(b.defs[d].variable_id==(int)v)defs[b.defs[d].block]=1;
        usz head=0;
        usz tail=0;
        for(usz i=0;i<b.n_blocks;i++)if(defs[i]!=0) {
            work[tail++]=(int)i;
            queued[i]=1;
        }
        while(head<tail) {
            int src=work[head++];
            for(usz j=0;j<b.df_count[src];j++) {
                int dst=b.df[src][j];
                if(dst<0||(usz)dst>=b.n_blocks||b.cfg.blocks[dst].pred_count<2)continue;
                expected[dst]=1;
                if(defs[dst]==0&&queued[dst]==0&&tail<b.n_blocks) {
                    queued[dst]=1;
                    work[tail++]=dst;
                }
            }
        }
        for(usz i=0;i<b.n_blocks;i++)if((expected[i]!=0)!=(actual[v*b.n_blocks+i]!=0))b.rename_errors++;
    }
    free((void*)work);
    free((void*)queued);
    free((void*)defs);
    free((void*)expected);
    free((void*)actual);
}

// Check that CFG predecessor/successor tables describe the same directed
// graph. pfront_cfg stores both sides, so one-sided edges indicate truncation
// or a builder bug even when the dominator equations happen to converge.
fn void SsaBuilder.verify_cfg_edges(SsaBuilder* b)
{
    for(usz source=0;source<b.n_blocks;source++) {
        Block* from=&b.cfg.blocks[source];
        for(usz si=0;si<from.succ_count;si++) {
            int target=from.succs[si];
            if(target<0||(usz)target>=b.n_blocks) {
                b.cfg_edge_errors++;
                continue;
            }
            bool reciprocal=false;
            for(usz pi=0;pi<b.cfg.blocks[target].pred_count;pi++)if(b.cfg.blocks[target].preds[pi]==(int)source)reciprocal=true;
            if(!reciprocal)b.cfg_edge_errors++;
        }
        for(usz pi=0;pi<from.pred_count;pi++) {
            int pred=from.preds[pi];
            if(pred<0||(usz)pred>=b.n_blocks) {
                b.cfg_edge_errors++;
                continue;
            }
            bool reciprocal=false;
            for(usz si=0;si<b.cfg.blocks[pred].succ_count;si++)if(b.cfg.blocks[pred].succs[si]==(int)source)reciprocal=true;
            if(!reciprocal)b.cfg_edge_errors++;
        }
    }
}

// Re-evaluate every block transfer equation from the stored GEN/KILL facts
// and the final live-in set. This is an independent fixed-point certificate,
// rather than relying only on a drained iteration counter.
fn void SsaBuilder.verify_live_equations(SsaBuilder* b)
{
    if(b.live_in==null||b.live_gen==null||b.live_kill==null)return;
    for(usz block=0;block<b.n_blocks;block++) {
        Block* bl=&b.cfg.blocks[block];
        for(usz v=0;v<b.var_count;v++) {
            usz cell=block*b.var_count+v;
            bool out=false;
            for(usz si=0;si<bl.succ_count;si++) {
                int succ=bl.succs[si];
                if(succ>=0&&(usz)succ<b.n_blocks&&b.live_in[(usz)succ*b.var_count+v]!=0)out=true;
            }
            char expected=(char)(b.live_gen[cell]!=0||(out&&b.live_kill[cell]==0));
            if(expected!=b.live_in[cell])b.live_equation_errors++;
        }
    }
}

// Return the variable and defining block for a concrete version ID. Every
// version originates at exactly one source definition or phi result.
fn bool SsaBuilder.version_info(SsaBuilder* b,int version,int* variable_id,int* block)
{
    for(usz d=0;d<b.def_count;d++)if(b.defs[d].version==version) {
        *variable_id=b.defs[d].variable_id;
        *block=b.defs[d].block;
        return true;
    }
    for(usz p=0;p<b.phi_count;p++)if(b.phis[p].version==version) {
        *variable_id=b.phis[p].variable_id;
        *block=b.phis[p].block;
        return true;
    }
    return false;
}

// For small graphs, independently solve the textbook dominator-set equations
// and compare their closest strict dominator with the CHK idom result. The
// bounded reference solver avoids quadratic work on very large input CFGs.
fn void SsaBuilder.verify_dom_reference(SsaBuilder* b)
{
    if(b.n_blocks>96||b.n_blocks==0)return;
    usz n=b.n_blocks;
    char* dom=(char*)calloc(n*n,1);
    int* component=(int*)malloc((long)(n*4));
    int* queue=(int*)malloc((long)(n*4));
    if(dom==null||component==null||queue==null) {
        b.overflow=true;
        free((void*)dom);
        free((void*)component);
        free((void*)queue);
        return;
    }
    for(usz i=0;i<n;i++)component[i]=-1;
    int comp=0;
    for(usz root=0;root<n;root++)if(b.sdom[root]!=0) {
        usz head=0;
        usz tail=0;
        queue[tail++]=(int)root;
        component[root]=comp;
        while(head<tail) {
            int node=queue[head++];
            Block* bl=&b.cfg.blocks[node];
            for(usz si=0;si<bl.succ_count;si++) {
                int next=bl.succs[si];
                if(next<0||(usz)next>=n)continue;
                if(component[next]<0) {
                    component[next]=comp;
                    queue[tail++]=next;
                }
                else if(component[next]!=comp)b.cfg_edge_errors++;
            }
        }
        comp++;
    }
    for(usz node=0;node<n;node++) {
        if(component[node]<0) {
            b.idom_errors++;
            continue;
        }
        if(b.sdom[node]!=0) {
            dom[node*n+node]=1;
            continue;
        }
        for(usz d=0;d<n;d++)if(component[d]==component[node])dom[node*n+d]=1;
    }
    bool changed=true;
    usz rounds=0;
    while(changed&&rounds<=n+1) {
        changed=false;
        rounds++;
        for(usz node=0;node<n;node++) {
            if(b.sdom[node]!=0||component[node]<0)continue;
            Block* bl=&b.cfg.blocks[node];
            bool have=false;
            char* next=(char*)calloc(n,1);
            if(next==null) {
                b.overflow=true;
                continue;
            }
            for(usz p=0;p<bl.pred_count;p++) {
                int pred=bl.preds[p];
                if(pred<0||(usz)pred>=n||component[pred]!=component[node])continue;
                if(!have) {
                    for(usz d=0;d<n;d++)next[d]=dom[(usz)pred*n+d];
                    have=true;
                }
                else {
                    for(usz d=0;d<n;d++) {
                        next[d]=(char)(next[d]!=0&&dom[(usz)pred*n+d]!=0);
                    }
                }
            }
            if(!have)for(usz d=0;d<n;d++)next[d]=0;
            next[node]=1;
            for(usz d=0;d<n;d++) {
                if(dom[node*n+d]!=next[d]) {
                    dom[node*n+d]=next[d];
                    changed=true;
                }
            }
            free((void*)next);
        }
    }
    for(usz node=0;node<n;node++) {
        if(b.sdom[node]!=0||component[node]<0)continue;
        int expected=-1;
        usz best=0;
        for(usz d=0;d<n;d++) {
            if(d==node||dom[node*n+d]==0)continue;
            usz depth=0;
            for(usz x=0;x<n;x++)if(dom[d*n+x]!=0)depth++;
            if(expected<0||depth>best) {
                expected=(int)d;
                best=depth;
            }
        }
        if(expected!=b.idom[node])b.idom_errors++;
    }
    free((void*)dom);
    free((void*)component);
    free((void*)queue);
}

// Complete frontier certificate for ordinary-sized graphs. For every ordered
// block pair, compare the semantic DF predicate with the stored sparse list.
fn void SsaBuilder.verify_df_complete(SsaBuilder* b)
{
    if(b.n_blocks>128)return;
    for(usz source=0;source<b.n_blocks;source++)for(usz target=0;target<b.n_blocks;target++) {
        bool expected=false;
        Block* join=&b.cfg.blocks[target];
        bool strict=source!=target&&b.dominates((int)source,(int)target);
        if(!strict)for(usz p=0;p<join.pred_count;p++)if(b.dominates((int)source,join.preds[p]))expected=true;
        bool actual=false;
        for(usz j=0;j<b.df_count[source];j++)if(b.df[source][j]==(int)target)actual=true;
        if(expected!=actual)b.df_errors++;
    }
}

fn void SsaBuilder.verify_plan(SsaBuilder* b)
{
    // Definition records must refer to valid source variables and blocks, and
    // each definition/phi must own a globally unique version number.
    for (usz d=0; d<b.def_count; d++)
    {
        SsaDef* def=&b.defs[d];
        if(def.version<0||def.variable_id<0||(usz)def.variable_id>=b.var_count||def.block<0||(usz)def.block>=b.n_blocks)b.rename_errors++;
        for(usz e=d+1;e<b.def_count;e++)if(def.version>=0&&def.version==b.defs[e].version)b.rename_errors++;
    }
    for(usz p=0;p<b.phi_count;p++)
    {
        SsaPhi* phi=&b.phis[p];
        if(phi.block<0||(usz)phi.block>=b.n_blocks||phi.variable_id<0||(usz)phi.variable_id>=b.var_count) {
            b.rename_errors++;
            continue;
        }
        if(phi.version<0||phi.inputs==null||phi.incoming!=b.cfg.blocks[phi.block].pred_count)b.rename_errors++;
        int result_var=-1;
        int result_block=-1;
        if(!b.version_info(phi.version,&result_var,&result_block)||result_var!=phi.variable_id||result_block!=phi.block)b.rename_errors++;
        for(usz arg=0;arg<phi.incoming;arg++) {
            if(phi.inputs==null)continue;
            int in_var=-1;
            int in_block=-1;
            int pred=b.cfg.blocks[phi.block].preds[arg];
            if(!b.version_info(phi.inputs[arg],&in_var,&in_block)||in_var!=phi.variable_id||pred<0||!b.dominates(in_block,pred))b.phi_arg_errors++;
        }
        for(usz q=p+1;q<b.phi_count;q++)if(phi.block==b.phis[q].block&&phi.variable_id==b.phis[q].variable_id)b.rename_errors++;
    }
    // Every recorded use must name an actual version of the same binder, and
    // that version's definition must dominate the source use location.
    for(usz u=0;u<b.use_count;u++) {
        SsaUse* use=&b.uses[u];
        if(use.version<0) {
            continue;
        }
        int variable=-1;
        int defining_block=-1;
        if(!b.version_info(use.version,&variable,&defining_block)||variable!=use.variable_id||!b.dominates(defining_block,use.block))b.use_dom_errors++;
    }
    // Check both witnesses and completeness of the dominance-frontier rows.
    for(usz source=0;source<b.n_blocks;source++)for(usz j=0;j<b.df_count[source];j++) {
        int target=b.df[source][j];
        if(target<0||(usz)target>=b.n_blocks) {
            b.df_errors++;
            continue;
        }
        bool witness=false;
        for(usz p=0;p<b.cfg.blocks[target].pred_count;p++)if(b.dominates((int)source,b.cfg.blocks[target].preds[p]))witness=true;
        if(!witness||(source!=(usz)target&&b.dominates((int)source,target)))b.df_errors++;
    }
    b.verify_cfg_edges();
    b.verify_live_equations();
    b.verify_df_complete();
    b.verify_dom_reference();
    b.verify_idf();
    for(usz i=0;i<b.n_blocks;i++) {
        int cur=(int)i;
        usz steps=0;
        while(cur>=0&&(usz)cur<b.n_blocks&&b.idom[cur]!=cur&&steps<=b.n_blocks) {
            cur=b.idom[cur];
            steps++;
        }
        if(cur<0||(usz)cur>=b.n_blocks||steps>b.n_blocks)b.idom_errors++;
    }
}

fn void SsaBuilder.analyze(SsaBuilder* b)
{
    if(b.cfg==null||b.cfg.block_count==0||!b.allocate_graph()) {
        b.built=true;
        return;
    }
    if(ssa_cfg_is_saturated(b.cfg,b.n_blocks)) {
        b.overflow=true;
        b.var_count=0;
        b.def_count=0;
        b.n_defs=0;
        b.n_dom=0;
        b.n_df=0;
        b.n_phi=0;
        b.phi_count=0;
        b.built=true;
        return;
    }
    b.collect_stmt_defs();
    b.build_dom();
    b.build_df();
    b.compute_liveness();
    b.insert_phi();
    b.find_critical();
    b.complete_rename();
    b.verify_plan();
    b.n_ssaable=b.var_count;
    b.built=true;
}

fn void SsaBuilder.run(SsaBuilder* b) {
    b.analyze();
}

fn void SsaBuilder.scan(SsaBuilder* b,Node* root,int depth)
{
    (void)depth;
    b.root=root;
    b.entry_count=0;
    b.n_blocks=0;
    b.var_count=0;
    b.def_count=0;
    b.phi_count=0;
    b.built=false;
    b.live_in=null;
    b.live_gen=null;
    b.live_kill=null;
    b.live_bits=0;
    b.live_iters=0;
    b.live_equation_errors=0;
    if(root==null) {
        b.built=true;
        return;
    }
    Cfg cfg;
    cfg.init(b.arena);
    b.cfg=&cfg;
    b.entries=(int*)malloc((long)(SSA_MAX_FN_ENTRIES*4));
    b.vars=(Node**)calloc(SSA_MAX_VARS,8);
    b.defs=(SsaDef*)calloc(SSA_MAX_DEFS,SsaDef::size);
    if(b.entries==null||b.vars==null||b.defs==null) {
        b.overflow=true;
        b.built=true;
        return;
    }
    b.collect_functions(&cfg,root,0);
    b.analyze();
    if(cfg.blocks!=null) {
        for(usz i=0;i<cfg.block_count;i++) {
            if(cfg.blocks[i].stmts!=null)free((void*)cfg.blocks[i].stmts);
            if(cfg.blocks[i].dom_children!=null)free((void*)cfg.blocks[i].dom_children);
        }
        free((void*)cfg.blocks);
    }
    if(cfg.loops!=null)free((void*)cfg.loops);
    if(cfg.loop_stack!=null)free((void*)cfg.loop_stack);
    if(cfg.break_to!=null)free((void*)cfg.break_to);
    if(cfg.cont_to!=null)free((void*)cfg.cont_to);
    b.cfg=null;
}

fn void SsaBuilder.report(SsaBuilder* b)
{
    printf("  ssa              : %d real blocks / %d entries, %d analyzed, %d dom iters, %d DF edges, %d vars / %d source defs / %d IDF phis (%s)\n",(int)b.n_blocks,(int)b.entry_count,(int)b.n_dom,(int)b.dom_iters,(int)b.n_df,(int)b.var_count,(int)b.def_count,(int)b.phi_count,b.overflow?"partial/capacity":"complete");
    printf("  ssa-live         : %d live-in facts, %d iterations, equation errors=%d\n",(int)b.live_bits,(int)b.live_iters,(int)b.live_equation_errors);
    printf("  ssa-rename       : %d versions, %d uses, %d no-reaching, critical=%d, cert dom=%d DF=%d CFG=%d use=%d phi-arg=%d SSA=%d\n",(int)b.n_renamed,(int)b.use_count,(int)b.unresolved_uses,(int)b.n_critical_edges,(int)b.idom_errors,(int)b.df_errors,(int)b.cfg_edge_errors,(int)b.use_dom_errors,(int)b.phi_arg_errors,(int)b.rename_errors);
    for(usz p=0;p<b.phi_count;p++) {
        SsaPhi* phi=&b.phis[p];
        printf("  ssa-phi         : var=%d line=%d block=%d args=[",phi.variable_id,b.vars[phi.variable_id].line,phi.block);
        for(usz j=0;j<phi.incoming;j++) {
            if(j>0)printf(",");
            printf("%d",phi.inputs!=null?phi.inputs[j]:-1);
        }
        printf("] result=%d\n",phi.version);
    }
}

fn void SsaBuilder.destroy(SsaBuilder* b)
{
    for(usz p=0;p<b.phi_count;p++)if(b.phis!=null&&b.phis[p].inputs!=null)free((void*)b.phis[p].inputs);
    for(usz i=0;i<b.n_blocks;i++) {
        if(b.dom_kids!=null&&b.dom_kids[i]!=null)free((void*)b.dom_kids[i]);
        if(b.df!=null&&b.df[i]!=null)free((void*)b.df[i]);
    }
    if(b.live_in!=null)free((void*)b.live_in);
    if(b.live_gen!=null)free((void*)b.live_gen);
    if(b.live_kill!=null)free((void*)b.live_kill);
    if(b.idom!=null)free((void*)b.idom);
    if(b.sdom!=null)free((void*)b.sdom);
    if(b.dom_kids!=null)free((void*)b.dom_kids);
    if(b.dom_kid_count!=null)free((void*)b.dom_kid_count);
    if(b.dom_kid_cap!=null)free((void*)b.dom_kid_cap);
    if(b.df!=null)free((void*)b.df);
    if(b.df_count!=null)free((void*)b.df_count);
    if(b.df_cap!=null)free((void*)b.df_cap);
    if(b.entries!=null)free((void*)b.entries);
    if(b.vars!=null)free((void*)b.vars);
    if(b.defs!=null)free((void*)b.defs);
    if(b.uses!=null)free((void*)b.uses);
    if(b.phis!=null)free((void*)b.phis);
}
