// ============================================================================
// pear1c — the LEGACY PEAR 1 backend as a stand-alone program.
//
//   pear1c FILE.air [--emit-exe | --emit-bc] [-O0|-O1|-O2|-O3] [--quiet]
//
// Reads AIR 2.0 text (docs/specs/AIR.md) produced by `pfrontc --emit-air`,
// re-screens its qualifier claims, and lowers it to LLVM 23 through the code
// that used to live inside pfrontc (pear.c3, pear_link.c3, unchanged).
//
//   --emit-exe   (default) native ELF next to the .air:  prog.air -> prog
//   --emit-bc    LLVM bitcode next to the .air:           prog.air -> prog.bc
//
// Exit status: 0 done, 1 the .air was rejected, 2 bad usage, 3 the backend
// produced no output.
//
// PEAR 1 is frozen: it exists so the exec/PEAR suites keep gating the
// front end through the real `.air` boundary while PEAR 2 is built against the
// same files. It reads names like `%kN`, `%loopN` and `·` by convention (see
// "Conventions" in docs/specs/AIR.md); fix the front end or build PEAR 2 rather
// than growing this.
// ============================================================================
module pear1c;
import air_ir;
import air_read;
import air_facts;
import pear;

extern fn int   printf(char* fmt, ...);
extern fn void* fopen(char* path, char* mode);
extern fn int   fclose(void* f);
extern fn int   remove(char* path);

fn bool eq(char* a, char* b)
{
    usz i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}

fn bool exists(char* path)
{
    void* f = fopen(path, "rb");
    if (f == null) { return false; }
    fclose(f);
    return true;
}

// FILE.air -> FILE.bc  /  FILE  (the same stem rule pear_link_exe uses)
fn char* stem_with(char* src, char* ext, char* buf, usz cap)
{
    int sl = -1; int dl = -1; int n = 0;
    while (src[n] != 0) { if (src[n] == '/') { sl = n; } if (src[n] == '.') { dl = n; } n++; }
    bool has_ext = (dl > sl) && (dl > 0) && (dl < n - 1);
    usz base = (usz)(has_ext ? dl : n);
    usz el = 0; while (ext[el] != 0) { el++; }
    if (base + el + 1 >= cap) { return null; }
    for (usz i = 0; i < base; i++) { buf[i] = src[i]; }
    for (usz i = 0; i < el; i++) { buf[base + i] = ext[i]; }
    buf[base + el] = 0;
    return buf;
}

fn int main(String[] args)
{
    char* input = null;
    bool want_bc = false;
    bool quiet = false;
    int opt = 2;
    for (usz i = 1; i < args.len; i++)
    {
        char* a = (char*)args[i].ptr;
        if (eq(a, "--emit-bc")) { want_bc = true; }
        else if (eq(a, "--emit-exe")) { want_bc = false; }
        else if (eq(a, "--quiet")) { quiet = true; }
        else if (eq(a, "-O0")) { opt = 0; }
        else if (eq(a, "-O1")) { opt = 1; }
        else if (eq(a, "-O2")) { opt = 2; }
        else if (eq(a, "-O3")) { opt = 3; }
        else if (a[0] != '-') { input = a; }
        else { printf("pear1c: unknown option '%s'\n", a); return 2; }
    }
    if (input == null)
    {
        printf("usage: pear1c FILE.air [--emit-exe | --emit-bc] [-O0|-O1|-O2|-O3] [--quiet]\n");
        return 2;
    }

    AirArena arena;
    if (!arena.init()) { return 3; }
    AirModule mod;
    if (!air_read::read_file(input, &arena, &mod, false)) { arena.destroy(); return 1; }
    // Claims in the text are candidates only; the screen decides what LLVM may be told.
    air_facts::validate_module(&mod);

    char[4096] outp;
    int rc = 0;
    if (want_bc)
    {
        if (stem_with(input, ".bc", &outp[0], 4096) == null) { arena.destroy(); return 2; }
        (void)remove(&outp[0]);                      // never leave a stale artifact behind a failure
        pear::pear_emit_module(&mod, &outp[0], opt);
        if (!exists(&outp[0])) { printf("pear1c: no bitcode produced\n"); rc = 3; }
    }
    else
    {
        if (stem_with(input, "", &outp[0], 4096) == null) { arena.destroy(); return 2; }
        (void)remove(&outp[0]);
        bool ok = pear::pear_link_exe(&mod, input, opt);
        if (!ok || !exists(&outp[0])) { printf("pear1c: no executable produced\n"); rc = 3; }
    }
    if (!quiet && rc == 0) { printf("pear1c: wrote %s\n", &outp[0]); }
    arena.destroy();
    return rc;
}
