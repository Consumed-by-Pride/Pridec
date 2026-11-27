// ============================================================================
// tools/air/airc.c3 -- `airc`: AIR 3.0 text -> C11 source.
//
// The smallest possible driver for pfront/pear_ir/air_c.c3. It reads a .air
// file, runs the certified fact pass over it, and writes the C the emitter
// produces. No parser, no theory layer, no lowering: that is the point. The
// slicing already exists in the Makefile (AIR_READ_CORE reads AIR text), and
// `air_c` is a consumer of exactly that, so a driver for it needs nothing else.
//
// Why it exists at all: `pfrontc --emit-c` needs the whole front end, which is
// the largest thing in this repository and the part most exposed to C3 version
// drift. airc depends only on the AIR layer, so the C backend can be executed
// on any .air file -- including the ones `pfrontc --emit-air` already writes --
// without the front end building at all.
//
//   airc IN.air OUT.c        -> writes C11; exit 0 on success
//   airc -                   -> IN.air on stdin, C on stdout
// ============================================================================
module airc;

import std::io;
import std::os::env;
import pfront_core;
import air_ir;
import air_read;
import air_c;
import air_facts;

fn int usage()
{
    io::eprintfn("usage: airc INPUT.air [OUTPUT.c]");
    io::eprintfn("       airc -            (AIR on stdin, C on stdout)");
    return 2;
}

fn int main(String[] args)
{
    if (args.len < 2) { return usage(); }
    char* in_path = (char*)args[1].ptr;
    bool to_stdout = args.len < 3;

    AirArena arena;
    AirModule mod;
    // read_file(path, &arena, &mod, quiet). A read failure is a diagnostic, not
    // an empty program, so it must not fall through to emitting an empty file.
    if (!air_read::read_file(in_path, &arena, &mod, false))
    {
        io::eprintfn("airc: could not read %s", in_path);
        return 1;
    }

    // The facts are what make the C target worth having (docs/pear2/C_TARGET.md
    // §5). Computing them here means `airc` emits the same C the compiler does,
    // rather than a weaker program that happens to have the same behaviour.
    air_facts::validate_module(&mod);

    char* text = null;
    int rc = air_c::to_c(&mod, &text, true);
    if (rc != 0 || text == null)
    {
        io::eprintfn("airc: air_c refused this module (rc=%d)", rc);
        return 1;
    }

    if (to_stdout) { io::printf("%s", text); }
    else if (air_c::write_c(&mod, (char*)args[2].ptr) != 0)
    {
        io::eprintfn("airc: could not write %s", (char*)args[2].ptr);
        return 1;
    }
    io::eprintfn("airc: wrote C for %s", to_stdout ? (char*)"stdout" : (char*)args[2].ptr);
    return 0;
}
