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
import air_write;
import air_read;
import air_facts;
import air_audit;

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


// emit_air_program — the canonical `.air` for a whole PROGRAM.
//
// This is the artifact backends consume (docs/specs/AIR.md): every loaded
// module's definitions lowered into ONE AirModule, in load order, then screened
// by air_facts and serialised by air_write. The file is written only when the
// writer reports zero errors — a lossy `.air` is never published. Returns the
// writer error count (0 = ok, -1 = could not open the file, -2 = setup failed).
fn int emit_air_program(PNode** roots, usz root_count, pfront_core::Interner* it, char* path)
{
    if (roots == null || root_count == 0) { return -2; }
    char[AIR_PATH_MAX] buf;
    char* out_path = null;
    if (path != null && path[0] != 0)
    {
        if (path[0] == '-' && path[1] == 0) { out_path = null; }
        else { out_path = derive_air_path(path, &buf[0], AIR_PATH_MAX); }
    }
    AirArena arena;
    if (!arena.init()) return -2;
    AirModule mod;
    char* mod_nm = module_name_of(roots[0]);
    if (!mod.init(&arena, mod_nm, path)) { arena.destroy(); return -2; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    for (usz i = 0; i < root_count; i++)
    {
        if (roots[i] == null) continue;
        lr.module_body(roots[i]);
        air_audit::report(roots[i], i, module_name_of(roots[i]), i == 0);
    }
    air_facts::validate_module(&mod);
    int errs = air_write::write_module(&mod, out_path);
    sc.destroy();
    arena.destroy();
    return errs;
}

extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn usz   fread(void* buf, usz size_, usz count_, void* f);
extern fn int   remove(char* path);
extern fn char* getenv(char* name);
extern fn int   fflush(void* f);
extern fn void* fdopen(int fd, char* mode);
extern fn int   printf(char* fmt, ...);

extern fn int   fseek(void* f, long off, int whence);
extern fn long  ftell(void* f);
extern fn void* malloc(usz n);
extern fn void  free(void* p);

// Reads a whole file into a malloc'd buffer (caller frees). Returns -1 on error.
fn long slurp(char* path, char** out)
{
    void* f = fopen(path, "rb");
    if (f == null) { return -1; }
    fseek(f, 0, 2);
    long n = ftell(f);
    fseek(f, 0, 0);
    if (n < 0) { fclose(f); return -1; }
    char* buf = (char*)malloc((usz)n + 1);
    if (buf == null) { fclose(f); return -1; }
    usz got = fread((void*)buf, 1, (usz)n, f);
    fclose(f);
    *out = buf;
    return (long)got;
}

// roundtrip_program — the faithfulness proof for the `.air` format (test-only,
// `--air-roundtrip`). Lowers the program, writes the text, reads it back and
// compares a structural fingerprint of the two modules: every node's tag and
// every non-pointer field, ids and addresses ignored (air_write::digest_module).
// Equal fingerprints mean the text lost no field a backend could read.
//
// Before the PEAR/pfront split the same check was also run against the LLVM
// bitcode of both modules: byte-identical for every program of the exec, PEAR,
// pfront and examples suites at -O2 that the legacy backend could compile
// (180 of 185; the other five crash the legacy backend itself).
// Returns 0 = identical, 1 = differs, 2 = could not run (reported).
fn int roundtrip_program(PNode** roots, usz root_count, pfront_core::Interner* it, char* path)
{
    if (roots == null || root_count == 0) { return 2; }
    char[AIR_PATH_MAX] pt;
    snprintf(&pt[0], AIR_PATH_MAX, "%s.rt.air", path);

    AirArena arena;
    if (!arena.init()) return 2;
    AirModule mod;
    if (!mod.init(&arena, module_name_of(roots[0]), path)) { arena.destroy(); return 2; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&mod, &sc, it);
    for (usz i = 0; i < root_count; i++) { if (roots[i] != null) lr.module_body(roots[i]); }
    air_facts::validate_module(&mod);

    int werr = air_write::write_module(&mod, &pt[0]);
    if (werr != 0) { printf("roundtrip: writer reported %d error(s)\n", werr); sc.destroy(); arena.destroy(); return 2; }
    AirArena arena2;
    if (!arena2.init()) { sc.destroy(); arena.destroy(); return 2; }
    AirModule mod2;
    if (!air_read::read_file(&pt[0], &arena2, &mod2, false)) { printf("roundtrip: reader rejected the writer's own output\n"); sc.destroy(); arena.destroy(); arena2.destroy(); return 2; }
    air_facts::validate_module(&mod2);
    if (getenv("AIR_DIGEST") != null) { (void)air_write::write_module(&mod2, "/tmp/rt_b.air"); }

    ulong da = air_write::digest_module(&mod);
    ulong db = air_write::digest_module(&mod2);
    int rc = 0;
    if (da != db) { printf("roundtrip: STRUCTURE differs after write/read (%lx vs %lx) -- a field is not in the text\n", da, db); rc = 1; }
    else { printf("roundtrip: structure identical (%lx)\n", da); }
    if (getenv("AIR_RT_KEEP") == null) { remove(&pt[0]); }
    sc.destroy(); arena.destroy(); arena2.destroy();
    return rc;
}
