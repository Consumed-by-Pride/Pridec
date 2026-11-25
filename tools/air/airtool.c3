// ============================================================================
// airtool — read, check and re-print AIR 2.0 text. No LLVM, no front end.
//
//   airtool check FILE.air          parse; exit 0 if well-formed, 1 otherwise
//   airtool verify FILE.air         parse + validity rules V1..V4 (docs/specs/AIR.md)
//   airtool lint  FILE.air [-e]     how much of an .ll's work is still left to the consumer (air_lint.c3)
//   airtool fmt   FILE.air [-o OUT] parse and re-print canonically
//   airtool opt   FILE.air [-o OUT] [--passes=LIST] [--print-after=DIR] [--no-verify]
//                                   run AIR-to-AIR passes to a fixpoint (air_pass.c3)
//
// The canonical printer is the same one pfrontc uses, so `fmt` of a pfrontc
// output must be byte-identical (the round-trip test relies on exactly that).
// ============================================================================
module airtool;
import air_ir;
import air_read;
import air_write;
import air_facts;
import air_verify;
import air_lint;
import air_ll;
import air_c3;
import air_util;
import air_pass;

extern fn int printf(char* fmt, ...);
extern fn int snprintf(char* buf, usz size, char* fmt, ...);
extern fn int remove(char* path);

fn bool eq(char* a, char* b)
{
    usz i = 0;
    while (a[i] != 0 && b[i] != 0) { if (a[i] != b[i]) { return false; } i++; }
    return a[i] == b[i];
}

fn int main(String[] args)
{
    if (args.len < 3)
    {
        printf("usage: airtool check|verify|lint|fmt|opt|roundtrip|emit-ll|emit-c3 FILE.air [-o OUT] [--passes=LIST]\n");
        return 2;
    }
    char* cmd = (char*)args[1].ptr;
    char* path = (char*)args[2].ptr;
    char* out = null;
    for (usz ai = 3; ai < args.len; ai++) { if (eq((char*)args[ai].ptr, "--syscall=x86_64-linux")) { air_ll::g_syscall_mode = 1; }
        if (eq((char*)args[ai].ptr, "--internalize")) { air_ll::g_internalize = true; }
        if (eq((char*)args[ai].ptr, "--syscall=i386-linux")) { air_ll::g_syscall_mode = 2; }
        if (eq((char*)args[ai].ptr, "--syscall=aarch64-linux")) { air_ll::g_syscall_mode = 3; }
        if (eq((char*)args[ai].ptr, "--syscall=riscv64-linux")) { air_ll::g_syscall_mode = 4; } }   // emit-ll: `syscall` as the x86-64 Linux instruction (no libc)
    for (usz ai = 3; ai < args.len; ai++)   // emit-ll --target=TRIPLE: `target triple`, and usz/isz as wide as that target's pointer
    {
        char* ar = (char*)args[ai].ptr;
        if (ar[0] == '-' && ar[1] == '-' && ar[2] == 't' && ar[3] == 'a' && ar[4] == 'r' && ar[5] == 'g' && ar[6] == 'e' && ar[7] == 't' && ar[8] == '=')
        { air_util::g_triple = ar + 9; air_util::g_ptr_bits = air_util::triple_ptr_bits(ar + 9); }
    }
    if (args.len >= 5 && eq((char*)args[3].ptr, "-o")) { out = (char*)args[4].ptr; }
    AirArena arena;
    if (!arena.init()) { return 3; }
    AirModule mod;
    if (!air_read::read_file(path, &arena, &mod, false)) { arena.destroy(); return 1; }
    if (eq(cmd, "check")) { arena.destroy(); return 0; }
    if (eq(cmd, "verify"))
    {
        int[8] cnt;
        int n = air_verify::verify_module(&mod, &cnt[0], false, 1000000);
        printf("verify: %d violation(s)  V1=%d V2=%d V3=%d V4=%d V5=%d  | conventions: J1(implicit %%kN joins)=%d N1(module-path roots)=%d J2(%%resume)=%d\n", n, cnt[0], cnt[1], cnt[2], cnt[3], cnt[7], cnt[4], cnt[5], cnt[6]);
        arena.destroy();
        return n == 0 ? 0 : 1;
    }
    if (eq(cmd, "lint"))
    {
        // airtool lint FILE.air [-e]   -e: entry module only. One line, machine readable.
        bool entry = args.len >= 4 && eq((char*)args[3].ptr, "-e");
        int[20] lc;
        int n = air_lint::lint_module(&mod, &lc[0], entry);
        printf("lint: %d |", n);
        for (usz i = 0; i < 16; i++) { printf(" %s=%d;", air_lint::rule_name(i), lc[i]); }
        printf("\n");
        arena.destroy();
        return n == 0 ? 0 : 1;
    }
    if (eq(cmd, "verify-low") || eq(cmd, "emit-ll"))
    {
        // verify-low: type-check against the low profile (docs/specs/AIR3.md), exit 0 iff clean.
        // emit-ll FILE.air [-o OUT.ll]: the reference consumer, .air -> LLVM text (same checks).
        bool emit = eq(cmd, "emit-ll");
        char* txt = null;
        int errs = air_ll::to_ll(&mod, &txt, emit);
        if (emit && errs == 0 && txt != null)
        {
            int w = air_ll::write_ll(&mod, out);
            if (w != 0) { errs = errs + 1; }
        }
        else { printf("verify-low: %d error(s)\n", errs); }
        arena.destroy();
        return errs == 0 ? 0 : 1;
    }
    if (eq(cmd, "emit-c3"))
    {
        // emit-c3 FILE.air [-o OUT.c3]: the AIR 3.0 low profile -> C3 source.
        // The second complete consumer (docs/pear2/C3_TARGET.md). It runs the
        // same walk and the same typing rules as emit-ll; the two are asserted to
        // agree on every tag by tests/air3/test_c3_target.py.
        char* txt = null;
        int errs = air_c3::to_c3(&mod, &txt, true);
        if (errs == 0 && txt != null)
        {
            int w = air_c3::write_c3(&mod, out);
            if (w != 0) { errs = errs + 1; }
        }
        else { printf("emit-c3: %d error(s)\n", errs); }
        arena.destroy();
        return errs == 0 ? 0 : 1;
    }
    if (eq(cmd, "opt"))
    {
        // The AIR middle end. `--passes=` selects the pipeline; each pass runs to
        // a fixpoint over the whole list, and the module is verified after every
        // pass so a bad rewrite is attributed to the pass that made it.
        char* spec = (char*)"fold";
        char* dump_dir = null;
        bool verify_each = true;
        for (usz ai = 3; ai < args.len; ai++)
        {
            char* ar = (char*)args[ai].ptr;
            if (eq(ar, "-o"))
            {
                // `-o` used to be accepted only in position 3; `opt` takes options
                // before it, so the output path is parsed here too.
                if (ai + 1 < args.len) { out = (char*)args[ai + 1].ptr; ai = ai + 1; }
            }
            else if (ar[0] == '-' && ar[1] == '-' && ar[2] == 'p' && ar[3] == 'a' && ar[4] == 's' && ar[5] == 's' && ar[6] == 'e' && ar[7] == 's' && ar[8] == '=') { spec = ar + 9; }
            else if (ar[0] == '-' && ar[1] == '-' && ar[2] == 'n' && ar[3] == 'o' && ar[4] == '-' && ar[5] == 'v') { verify_each = false; }
            else if (eq(ar, "--print-after"))
            {
                if (ai + 1 < args.len) { dump_dir = (char*)args[ai + 1].ptr; ai = ai + 1; }
            }
            else if (ar[0] == '-' && ar[1] == '-' && ar[2] == 'p' && ar[3] == 'r' && ar[4] == 'i' && ar[5] == 'n' && ar[6] == 't' && ar[7] == '-' && ar[8] == 'a' && ar[9] == 'f' && ar[10] == 't' && ar[11] == 'e' && ar[12] == 'r' && ar[13] == '=') { dump_dir = ar + 14; }
        }
        int[32] pipeline;
        usz pcount = 0;
        if (!air_pass::parse_pipeline(spec, &pipeline[0], 32, &pcount)) { arena.destroy(); return 2; }
        air_pass::PassStats st;
        st.init();
        if (!air_pass::run(&mod, &pipeline[0], pcount, &st, verify_each, dump_dir, (char*)"pass"))
        { arena.destroy(); return 1; }
        st.report();
        int errs = out != null ? air_write::write_module(&mod, out) : 0;
        arena.destroy();
        return errs == 0 ? 0 : 1;
    }
    if (eq(cmd, "roundtrip"))
    {
        // `pfrontc` used to do this on an in-memory AST. It cannot any more: the
        // reader is not linked into the compiler. This command reads a `.air` file,
        // writes it canonically, reads that back, and compares structural
        // fingerprints (air_write::digest_module) -- the same fidelity question,
        // asked of a file instead of a program.
        char[4096] rt;
        int k = snprintf(&rt[0], 4096, "%s.rt.air", path);
        if (k <= 0 || k >= 4096) { arena.destroy(); return 2; }
        if (air_write::write_module(&mod, &rt[0]) != 0) { arena.destroy(); return 1; }
        AirArena a2;
        if (!a2.init()) { arena.destroy(); return 3; }
        AirModule mod2;
        if (!air_read::read_file(&rt[0], &a2, &mod2, false))
        { printf("roundtrip: the reader rejected the writer's own output\n"); a2.destroy(); arena.destroy(); return 1; }
        air_facts::validate_module(&mod2);
        ulong da = air_write::digest_module(&mod);
        ulong db = air_write::digest_module(&mod2);
        int rc = 0;
        if (da != db) { printf("roundtrip: STRUCTURE differs after write/read (%lx vs %lx) -- a field is not in the text\n", da, db); rc = 1; }
        else { printf("roundtrip: structure identical (%lx)\n", da); }
        (void)remove(&rt[0]);
        a2.destroy();
        arena.destroy();
        return rc;
    }
    if (eq(cmd, "fmt"))
    {
        // facts are claims: re-screen before printing so `fmt` is a fixed point
        air_facts::validate_module(&mod);
        int errs = air_write::write_module(&mod, out);
        arena.destroy();
        return errs == 0 ? 0 : 1;
    }
    printf("unknown command\n");
    arena.destroy();
    return 2;
}
