// ============================================================================
// airtool — read, check and re-print AIR 2.0 text. No LLVM, no front end.
//
//   airtool check FILE.air          parse; exit 0 if well-formed, 1 otherwise
//   airtool verify FILE.air         parse + validity rules V1..V4 (docs/specs/AIR.md)
//   airtool lint  FILE.air [-e]     how much of an .ll's work is still left to the consumer (air_lint.c3)
//   airtool fmt   FILE.air [-o OUT] parse and re-print canonically
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

extern fn int printf(char* fmt, ...);

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
        printf("usage: airtool check|fmt FILE.air [-o OUT]\n");
        return 2;
    }
    char* cmd = (char*)args[1].ptr;
    char* path = (char*)args[2].ptr;
    char* out = null;
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
        printf("verify: %d violation(s)  V1=%d V2=%d V3=%d V4=%d  | conventions: J1(implicit %%kN joins)=%d N1(module-path roots)=%d J2(%%resume)=%d\n", n, cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6]);
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
