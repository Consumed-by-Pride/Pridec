// ============================================================================
// air_scope.c3 — Name supply, lexical scoping, alpha-renaming for AIR lowering.
// ============================================================================
module air_scope;
import pfront_core;
import air_ir;

extern fn void* memset(void* dst, int v, usz n);
extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz AIR_SCOPE_LOCALS = 2048;
const usz AIR_SCOPE_SCRATCH = 256;
const int AIR_SCOPE_DEPTH = 256;
const int AIR_SCOPE_LABELS = 256;

struct AirLocal {
    char* source_name; char* air_name; bool is_covar; int depth; PNode* decl;
}
struct AirLoopLabel {
    char* break_lbl; char* continue_lbl; int depth;
}
struct AirScope {
    AirArena* arena;
    int fresh_k, fresh_x, fresh_lbl, depth;
    AirLocal[AIR_SCOPE_LOCALS] locals; usz local_count;
    int[AIR_SCOPE_DEPTH] depth_marks; int depth_mark_count;
    AirLoopLabel[AIR_SCOPE_LABELS] loops; int loop_count;
    char*[256] rets; int ret_count;
    char[AIR_SCOPE_SCRATCH] scratch;
}

fn void AirScope.init(AirScope* s, AirArena* a) {
    s.arena=a; s.fresh_k=1; s.fresh_x=1; s.fresh_lbl=1; s.depth=0;
    s.local_count=0; s.depth_mark_count=0; s.loop_count=0; s.ret_count=0;
    char* ret0 = a.dup("%ret",4);
    s.bind_covar(ret0, null);
    s.rets[0] = ret0; s.ret_count = 1;
}
fn void AirScope.destroy(AirScope* s) {
    s.fresh_k=1; s.fresh_x=1; s.fresh_lbl=1; s.depth=0;
    s.local_count=0; s.depth_mark_count=0; s.loop_count=0; s.ret_count=0;
}
fn void AirScope.enter(AirScope* s) {
    if (s.depth_mark_count < AIR_SCOPE_DEPTH) {
        s.depth_marks[s.depth_mark_count] = (int)s.local_count;
        s.depth_mark_count++;
    }
    s.depth++;
}
fn void AirScope.leave(AirScope* s) {
    if (s.depth_mark_count > 0) { s.depth_mark_count--; s.local_count=(usz)s.depth_marks[s.depth_mark_count]; }
    if (s.depth > 0) s.depth--;
}

// ── Return-stack: for nested defs / lambdas, each fn body pushes its own
// %ret covariable so `return e` cuts to the innermost function's ret rather
// than the outer one.
fn char* AirScope.push_ret(AirScope* s, char* nm) {
    char* bound = s.bind_covar(nm, null);
    if (s.ret_count < 256) { s.rets[s.ret_count] = bound; s.ret_count++; }
    return bound;
}
fn void AirScope.pop_ret(AirScope* s) {
    if (s.ret_count > 1) s.ret_count--;
}
fn char* AirScope.current_ret(AirScope* s) {
    if (s.ret_count <= 0) return (char*)"%ret";
    return s.rets[s.ret_count - 1];
}

fn char* AirScope.bind(AirScope* s, char* src_nm, bool is_covar, PNode* decl) {
    if (s.local_count >= AIR_SCOPE_LOCALS) return is_covar?(char*)"%err":(char*)"_err";
    char* nm;
    if (src_nm == null || src_nm[0] == 0) {
        if (is_covar) { nm = s.fresh_k_covar(); } else { nm = s.fresh_x_var(); }
    } else {
        nm = src_nm; int shadows = 0;
        for (usz i=0; i<s.local_count; i++) {
            if (s.locals[i].is_covar != is_covar) continue;
            if (streq(s.locals[i].source_name, src_nm)) shadows++;
        }
        if (shadows > 0) {
            char* buf = &s.scratch[0];
            if (is_covar && nm[0]=='%') {
                char* base = &nm[1];
                snprintf(buf, AIR_SCOPE_SCRATCH, "%%%s_%d", base, shadows);
            } else {
                snprintf(buf, AIR_SCOPE_SCRATCH, "%s_%d", nm, shadows);
            }
            nm = s.arena.dup(buf, (usz)air_cstrlen(buf));
        } else { nm = s.arena.dup(nm, (usz)air_cstrlen(nm)); }
    }
    AirLocal* loc_ = &s.locals[s.local_count];
    loc_.source_name = s.arena.dup(src_nm==null?(char*)"":src_nm, src_nm==null?0:(usz)air_cstrlen(src_nm));
    loc_.air_name=nm; loc_.is_covar=is_covar; loc_.depth=s.depth; loc_.decl=decl;
    s.local_count++; return nm;
}
fn char* AirScope.bind_var(AirScope* s, char* nm, PNode* decl) { return s.bind(nm, false, decl); }

// bind_as — bind with DISTINCT lookup key and AIR name. `src_nm` is what call
// sites look up (the source identifier); `air_nm` is the identifier emitted in
// the IR. bind() derives the AIR name from shadow counts, which is right for
// variables but wrong for a hoisted nested function whose definition must be
// mangled (inner$1) while every call site in the body still says `inner`:
// passing the mangled string to bind() would also use it as the lookup key, so
// the calls would miss and silently resolve to whatever global shared the name.
fn char* AirScope.bind_as(AirScope* s, char* src_nm, char* air_nm, PNode* decl) {
    if (s.local_count >= AIR_SCOPE_LOCALS) return (char*)"_err";
    char* key = (src_nm == null || src_nm[0] == 0) ? (char*)"_" : src_nm;
    char* air = (air_nm == null || air_nm[0] == 0) ? (char*)"_err" : air_nm;
    AirLocal* loc_ = &s.locals[s.local_count];
    loc_.source_name = s.arena.dup(key, (usz)air_cstrlen(key));
    loc_.air_name = s.arena.dup(air, (usz)air_cstrlen(air));
    loc_.is_covar = false;
    loc_.depth = s.depth;
    loc_.decl = decl;
    s.local_count++;
    return loc_.air_name;
}

// air_name_used — is this AIR name already taken by a live binding? A hoisted
// function must not share an AIR name with a local variable of the same name.
fn bool AirScope.air_name_used(AirScope* s, char* nm) {
    if (nm == null) return false;
    for (usz i = 0; i < s.local_count; i++) {
        if (streq(s.locals[i].air_name, nm)) return true;
    }
    return false;
}
fn char* AirScope.bind_covar(AirScope* s, char* nm, PNode* decl) { return s.bind(nm, true, decl); }

fn char* AirScope.lookup(AirScope* s, char* src_nm, bool is_covar) {
    if (src_nm == null) return null;
    long i = (long)s.local_count - 1;
    while (i >= 0) {
        AirLocal* loc_ = &s.locals[(usz)i];
        if (loc_.is_covar == is_covar && streq(loc_.source_name, src_nm)) return loc_.air_name;
        i--;
    }
    return null;
}
// Look up a local by the AST declaration node it was bound from. Used by the
// pre-binding pass in AirLower.stmts: the declaration is bound before the block
// tail is lowered, and the later `let` statement must reuse that binding rather
// than create a second one.
// decl_for -- the AST declaration a bound source name came from, or null.
// The inverse direction of lookup_decl(): callers that hold a name (for example
// an index base like `a` in `a[i]`) use this to reach the declaration's type
// annotation. A covar name is not a variable, so only variable bindings answer.
fn PNode* AirScope.decl_for(AirScope* s, char* src_nm) {
    if (src_nm == null) return null;
    long i = (long)s.local_count - 1;
    while (i >= 0) {
        AirLocal* loc_ = &s.locals[(usz)i];
        if (!loc_.is_covar && streq(loc_.source_name, src_nm)) return loc_.decl;
        i--;
    }
    return null;
}

fn char* AirScope.lookup_decl(AirScope* s, PNode* decl) {
    if (decl == null) return null;
    long i = (long)s.local_count - 1;
    while (i >= 0) {
        AirLocal* loc_ = &s.locals[(usz)i];
        if (loc_.decl == decl) return loc_.air_name;
        i--;
    }
    return null;
}

fn char* AirScope.lookup_var(AirScope* s, char* nm) { return s.lookup(nm, false); }
fn char* AirScope.lookup_covar(AirScope* s, char* nm) { return s.lookup(nm, true); }

fn char* AirScope.fresh_k_covar(AirScope* s) {
    char* buf = &s.scratch[0]; int id = s.fresh_k; s.fresh_k++;
    snprintf(buf, AIR_SCOPE_SCRATCH, "%%k%d", id);
    char* nm = s.arena.dup(buf, (usz)air_cstrlen(buf));
    s.bind_covar(nm, null); return nm;
}
fn char* AirScope.fresh_x_var(AirScope* s) {
    char* buf = &s.scratch[0]; int id = s.fresh_x; s.fresh_x++;
    snprintf(buf, AIR_SCOPE_SCRATCH, "_x%d", id);
    char* nm = s.arena.dup(buf, (usz)air_cstrlen(buf));
    s.bind_var(nm, null); return nm;
}
fn char* AirScope.fresh_label(AirScope* s, char* hint) {
    char* buf = &s.scratch[0]; int id = s.fresh_lbl; s.fresh_lbl++;
    if (hint != null && hint[0] != 0) { snprintf(buf, AIR_SCOPE_SCRATCH, "%%%s%d", hint, id); }
    else { snprintf(buf, AIR_SCOPE_SCRATCH, "%%lbl%d", id); }
    char* nm = s.arena.dup(buf, (usz)air_cstrlen(buf));
    s.bind_covar(nm, null); return nm;
}
fn void AirScope.push_loop(AirScope* s, char* brk, char* cont) {
    if (s.loop_count >= AIR_SCOPE_LABELS) return;
    AirLoopLabel* lbl = &s.loops[s.loop_count];
    lbl.break_lbl = brk; lbl.continue_lbl = cont; lbl.depth = s.depth;
    s.loop_count++;
}
fn void AirScope.pop_loop(AirScope* s) { if (s.loop_count > 0) s.loop_count--; }
fn char* AirScope.current_break(AirScope* s) {
    if (s.loop_count <= 0) return (char*)"%ret"; return s.loops[s.loop_count-1].break_lbl;
}
fn char* AirScope.current_continue(AirScope* s) {
    if (s.loop_count <= 0) return (char*)"%ret"; return s.loops[s.loop_count-1].continue_lbl;
}

fn bool streq(char* a, char* b) {
    if (a==null||b==null) return a==b;
    usz i=0; while (a[i]!=0 && b[i]!=0) { if(a[i]!=b[i])return false; i++; }
    return a[i]==b[i];
}
fn int air_cstrlen(char* s) {
    int n=0; if(s==null)return 0;
    while(s[n]!=0 && n<(int)AIR_SCOPE_SCRATCH-1) n++; return n;
}
