// ============================================================================
// air_roundtrip.c3 — the write/read faithfulness proof, moved out of air.c3
// ----------------------------------------------------------------------------
// This check lowers a program, writes the AIR text, reads it back and compares a
// structural fingerprint of the two modules. It is a property of the FORMAT, so
// it is a test of the writer against the reader -- not a step in emitting AIR.
//
// It used to live in `air.c3`, whose job is to drive emission. That made the
// emitter import the reader (and the facts table) so that one test-only function
// could run, which is exactly the kind of dependency this boundary exists to
// stop. Here the dependency is honest: this module is on the consumer side.
// ============================================================================
module air_roundtrip;

import pfront_core;
import air_ir;
import air_scope;
import air_lower;
import air_emit;
import air_write;
import air_read;
import air_facts;
import air_audit;

extern fn int printf(char* fmt, ...);
extern fn void* getenv(char* name);
extern fn int remove(char* path);
extern fn int snprintf(char* buf, usz n, char* fmt, ...);

alias PNode = pfront_core::PNode;
const usz AIR_PATH_MAX = 4096;

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
    if (!mod.init(&arena, path, path)) { arena.destroy(); return 2; }
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
