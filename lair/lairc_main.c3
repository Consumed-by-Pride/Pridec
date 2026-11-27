// ============================================================================
// lairc_main.c3 -- the standalone LAIR driver (LAIR.md §4).
//
//   lairc FILE.air --check        parse -> lower -> verify (writes nothing)
//   lairc FILE.air --emit-lair    also write FILE.lair
//   lairc FILE.air --emit-ll      also write FILE.ll
//   lairc FILE.air --emit-bc      .bc via scripts/ll-bc.py (no LLVM linked here)
//
// Exit codes follow docs/pear2/CONTRACT.md §2: 0 success, 1 the input is not
// valid AIR, 2 a usage error, 3 a form outside the LAIR slice or a failed
// verification. Nothing here links LLVM -- the .ll is text, and the .bc step
// is a separate script -- so `make check-lair` runs on a machine with only
// c3c.
// ============================================================================
module lairc_main;
extern fn int printf(char* fmt, ...);
extern fn int fprintf(void* f, char* fmt, ...);
extern fn void* fopen(char* path, char* mode);
extern fn int fclose(void* f);
extern fn void* fdopen(int fd, char* mode);
extern fn int fflush(void* f);

import air_util;
import air_ir;
import air_text;
import air_read;
import lair_ir;
import lair_lower;
import lair_verify;
import lair_write;
import lair_ll;

extern fn void* memset(void* dst, int value, usz n);

enum Mode : int { MD_CHECK, MD_LAIR, MD_LL }

fn void usage()
{
    void* se = fdopen(2, "w");
    fprintf(se, "usage: lairc FILE.air [--check|--emit-lair|--emit-ll] [-o OUT]\n");
    fprintf(se, "  --check      parse, lower and verify; write nothing (default)\n");
    fprintf(se, "  --emit-lair  also write the .lair text next to the input\n");
    fprintf(se, "  --emit-ll    also write LLVM .ll next to the input\n");
    fprintf(se, "  -o OUT       output path (default: input with the extension swapped)\n");
    fflush(se);
}

// f.air -> f.<ext>, beside the input (pear2c's convention).
fn char* swap_ext(char* path, char* ext)
{
    usz n = 0;
    while (path[n] != 0) { n++; }
    usz dot = n;
    while (dot > 0 && path[dot] != '.' && path[dot] != '/') { dot--; }
    usz stem = path[dot] == '.' ? dot : n;
    Sb s;
    s.init();
    for (usz i = 0; i < stem; i++) { s.putc(path[i]); }
    s.put((char*)".");
    s.put(ext);
    return s.take();
}

fn int main(int argc, char** argv)
{
    char* input = null;
    char* out = null;
    Mode mode = MD_CHECK;
    for (int i = 1; i < argc; i++)
    {
        char* a = argv[i];
        if (air_text::streq(a, (char*)"--check")) { mode = MD_CHECK; }
        else if (air_text::streq(a, (char*)"--emit-lair")) { mode = MD_LAIR; }
        else if (air_text::streq(a, (char*)"--emit-ll")) { mode = MD_LL; }
        else if (air_text::streq(a, (char*)"-o"))
        {
            if (i + 1 >= argc) { usage(); return 2; }
            i++;
            out = argv[i];
        }
        else if (air_text::streq(a, (char*)"--help") || air_text::streq(a, (char*)"-h")) { usage(); return 0; }
        else if (a[0] == '-')
        {
            void* se1 = fdopen(2, "w");
            fprintf(se1, "lairc: unknown option `%s`\n", a);
            fflush(se1);
            usage();
            return 2;
        }
        else if (input == null) { input = a; }
        else {
            void* se0 = fdopen(2, "w");
            fprintf(se0, "lairc: more than one input file\n");
            fflush(se0);
            return 2;
        }
    }
    if (input == null) { usage(); return 2; }

    AirArena arena;
    AirModule am;
    if (!air_read::read_file(input, &arena, &am, false)) { return 1; }

    LModule lm;
    memset(&lm, 0, LModule::size);
    lair_lower::lower_module(&am, &lm);
    if (lm.errs == 0) { lair_verify::verify_module(&lm); }
    if (lm.errs != 0) { return 3; }

    if (mode == MD_CHECK)
    {
        printf("lairc: %s: ok (%d function(s), %d extern(s))\n",
               input, lm.nf, lm.next_);
        return 0;
    }

    char* path = out;
    if (path == null) { path = swap_ext(input, mode == MD_LAIR ? (char*)"lair" : (char*)"ll"); }
    void* f = fopen(path, "w");
    if (f == null)
    {
        void* se2 = fdopen(2, "w");
        fprintf(se2, "lairc: cannot write `%s`\n", path);
        fflush(se2);
        return 3;
    }
    bool ok = mode == MD_LAIR ? lair_write::write_lair(&lm, f) : lair_ll::write_ll(&lm, f);
    fclose(f);
    if (!ok)
    {
        void* se3 = fdopen(2, "w");
        fprintf(se3, "lairc: write failed for `%s`\n", path);
        fflush(se3);
        return 3;
    }
    printf("lairc: wrote %s\n", path);
    return 0;
}
