// ============================================================================
// air.c3 — public driver for emitting AIR (.air files) from pfront.
// ============================================================================
module air;

import pfront_core;
import air_ir;
import air_scope;
import air_lower;
import air_emit;

extern fn void* fopen(char*, char*);
extern fn void* fdopen(int, char*);
extern fn int   fclose(void*);
extern fn int   fflush(void*);

alias PNode = pfront_core::PNode;

// derive_air_path: take the input .pie path and produce the sibling .air path.
fn char* derive_air_path(AirArena* a, char* in_path)
{
    if (in_path == null) return a.dup("out.air", 7);
    int n = 0;
    while (in_path[n] != 0) { n++; }
    int dot = -1; int slash = -1;
    for (int i = 0; i < n; i++)
    {
        if (in_path[i] == '.') { dot = i; }
        if (in_path[i] == '/' || in_path[i] == '\\') { slash = i; }
    }
    int base_start = slash + 1;
    int out_len;
    bool has_ext = (dot > base_start);
    if (has_ext) { out_len = dot + 4; }
    else { out_len = n + 4; }
    char* out = (char*)a.alloc((usz)(out_len + 1), 1);
    if (out == null) return a.dup("out.air", 7);
    int take = has_ext ? dot : n;
    for (int i = 0; i < take; i++) { out[i] = in_path[i]; }
    out[take] = '.'; out[take+1] = 'a'; out[take+2] = 'i'; out[take+3] = 'r';
    out[take+4] = 0;
    return out;
}

// emit_air — entry point called from pfront_main when --emit-air is on.
fn void emit_air(PNode* root, pfront_core::Interner* it, char* path)
{
    if (root == null) return;
    AirArena arena;
    if (!arena.init()) return;
    AirModule m;
    char* mod_name = (char*)"main";
    if (!m.init(&arena, mod_name, path)) { arena.destroy(); return; }
    AirScope sc;
    sc.init(&arena);
    AirLower lr;
    lr.init(&m, &sc, it);

    lr.module_body(root);

    char* out_path = derive_air_path(&arena, path);
    void* f = fopen(out_path, (char*)"wb");
    if (f == null) { f = fdopen(1, (char*)"w"); }
    if (f != null)
    {
        air_emit::emit_module(f, &m, &lr, &arena);
        fflush(f);
        if (f != (void*)(long)1) { fclose(f); }
    }
    sc.destroy();
    arena.destroy();
}
