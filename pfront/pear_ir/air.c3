// ============================================================================
// air.c3 — Public driver for AIR emission (selected by --emit-air).
// ----------------------------------------------------------------------------
// Pipeline:
//   1. Derives the sibling .air path from the source .pie path.
//   2. Sets up an AirArena, AirModule, AirScope, AirLower.
//   3. Walks the post-theory PNode tree via air_lower.module_body(root)
//      to build an in-memory AirModule of λ̄μμ̃ IR (prd/cns/cmd).
//   4. Hands the AirModule to air_emit.emit_module to print clean, stubless
//      AIR text (no *k*, no *dummy*, no <()|·> nops, no leaked spans).
// ============================================================================
module air;

import pfront_core;
import air_ir;
import air_scope;
import air_lower;
import air_emit;
import air_facts;
import pear;

alias PNode = pfront_core::PNode;

extern fn int   snprintf(char* buf, usz n, char* fmt, ...);

const usz AIR_PATH_MAX = 4096;

// Derive "<stem>.air" from "<stem>.pie" (or any other extension). Strips the
// last '.'-separated extension after the last '/', then appends ".air".
fn char* derive_air_path(char* src, char* buf, usz cap)
{
    if (src == null) return null;
    int sl = -1; int dl = -1; int n = 0;
    while (src[n] != 0) {
        if (src[n] == '/') sl = n;
        if (src[n] == '.') dl = n;
        n++;
    }
    bool has_ext = (dl > sl) && (dl > 0) && (dl < n - 1);
    usz base_len = (usz)(has_ext ? dl : n);
    if (base_len + 5 >= cap) return null;
    for (usz i = 0; i < base_len; i++) buf[i] = src[i];
    buf[base_len+0] = '.';
    buf[base_len+1] = 'a';
    buf[base_len+2] = 'i';
    buf[base_len+3] = 'r';
    buf[base_len+4] = 0;
    return buf;
}

// Resolve a module name from the AST root (best-effort).
fn char* module_name_of(PNode* root)
{
    if (root == null) return (char*)"Main";
    for (usz i = 0; i < root.child_count; i++)
    {
        PNode* c = root.children[i];
        if (c == null) continue;
        if (c.kind == pfront_core::NodeKind.N_MODULE)
        {
            if (c.p.sptr != null && c.p.slen > 0) return c.p.sptr;
        }
    }
    return (char*)"Main";
}

fn void emit_air(PNode* root, pfront_core::Interner* it, char* path)
{
    char[AIR_PATH_MAX] buf;
    char* out_path = null;
    if (path != null && path[0] != 0)
    {
        if (path[0] == '-' && path[1] == 0) { out_path = null; }
        else { out_path = derive_air_path(path, &buf[0], AIR_PATH_MAX); }
    }

    // ── Build IR ────────────────────────────────────────────────────────
    AirArena arena;
    if (!arena.init()) return;
    AirModule mod;
    char* mod_nm = module_name_of(root);
    if (!mod.init(&arena, mod_nm, path))
    {
        arena.destroy();
        return;
    }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    lr.module_body(root);

    air_facts::validate_module(&mod);

    // ── Emit text ──────────────────────────────────────────────────────
    air_emit::emit_module(&mod, &lr, out_path);

    // ── Teardown ───────────────────────────────────────────────────────
    sc.destroy();
    arena.destroy();
}

fn char* derive_bc_path(char* src, char* buf, usz cap)
{
    if (src == null) return null;
    int sl = -1; int dl = -1; int n = 0;
    while (src[n] != 0) {
        if (src[n] == '/') sl = n;
        if (src[n] == '.') dl = n;
        n++;
    }
    bool has_ext = (dl > sl) && (dl > 0) && (dl < n - 1);
    usz base_len = (usz)(has_ext ? dl : n);
    if (base_len + 4 >= cap) return null;
    for (usz i = 0; i < base_len; i++) buf[i] = src[i];
    buf[base_len+0] = '.';
    buf[base_len+1] = 'b';
    buf[base_len+2] = 'c';
    buf[base_len+3] = 0;
    return buf;
}

fn void emit_bc(PNode* root, pfront_core::Interner* it, char* path, int opt_level)
{
    char[AIR_PATH_MAX] buf;
    char* out_path = null;
    if (path != null && path[0] != 0)
    {
        if (path[0] == '-' && path[1] == 0) { out_path = null; }
        else { out_path = derive_bc_path(path, &buf[0], AIR_PATH_MAX); }
    }

    AirArena arena;
    if (!arena.init()) return;
    AirModule mod;
    char* mod_nm = module_name_of(root);
    if (!mod.init(&arena, mod_nm, path)) { arena.destroy(); return; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    lr.module_body(root);

    air_facts::validate_module(&mod);
    pear::pear_emit_module(&mod, out_path, opt_level);

    sc.destroy();
    arena.destroy();
}

// emit_exe_program — emit an executable for a whole PROGRAM: every loaded
// module's definitions are lowered into ONE AirModule before linking.
//
// A call to a function in another module used to compile and link and then
// segfault: the callee was resolved by name against the module being emitted,
// found nothing, and the call site fell back to address 0. Lowering all modules
// together is what makes cross-module calls resolve — and since the symbol table
// is keyed by bare name, later duplicate definitions are skipped (see
// pear_dup_def) rather than silently shadowing.
//
// `roots` are the module ASTs in load order; the entry module is one of them.
fn void emit_exe_program(PNode** roots, usz root_count, pfront_core::Interner* it,
                         char* path, int opt_level)
{
    if (roots == null || root_count == 0) { return; }
    AirArena arena;
    if (!arena.init()) return;
    AirModule mod;
    char* mod_nm = module_name_of(roots[0]);
    if (!mod.init(&arena, mod_nm, path)) { arena.destroy(); return; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    for (usz i = 0; i < root_count; i++)
    {
        if (roots[i] == null) continue;
        lr.module_body(roots[i]);
    }

    air_facts::validate_module(&mod);
    (void)pear::pear_link_exe(&mod, path, opt_level);

    sc.destroy();
    arena.destroy();
}

fn void emit_exe(PNode* root, pfront_core::Interner* it, char* path, int opt_level)
{
    AirArena arena;
    if (!arena.init()) return;
    AirModule mod;
    char* mod_nm = module_name_of(root);
    if (!mod.init(&arena, mod_nm, path)) { arena.destroy(); return; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    lr.module_body(root);

    air_facts::validate_module(&mod);
    (void)pear::pear_link_exe(&mod, path, opt_level);

    sc.destroy();
    arena.destroy();
}
