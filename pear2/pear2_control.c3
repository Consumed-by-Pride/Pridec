// PEAR 2 control-flow helpers: explicit label edges, loop-carried values,
// and buffered label-block emission. Same pear2c module/context.
module pear2c;
import air_ir;

fn int M1Gen.label_index(M1Gen* g, char* name)
{
    char* normalized = name != null && name[0] == '%' ? name + 1 : name;
    for (usz i = 0; i < g.label_count; i++) { if (same(g.labels[i].name, normalized)) { return (int)i; } }
    return -1;
}
fn bool M1Gen.label_environment_unchanged(M1Gen* g, M1Label* target)
{
    // M9: captured bindings arrive at the label block through phi incoming
    // edges, so a jump no longer needs the captured values to be identical to
    // the capture-time ones; only the environment *shape* must match: every
    // captured name is still resolvable with the same kind and value type.
    if (target == null || !target.captured) { return false; }
    for (usz j = 0; j < target.env_count; j++)
    {
        bool is_param = false;
        for (usz p = 0; p < target.param_count; p++)
        {
            if (target.params[p] != null && same(target.params[p].name, target.env_names[j])) { is_param = true; break; }
        }
        if (is_param) { continue; }
        int current = g.env_index(target.env_names[j]);
        if (current < 0) { return false; }
        if (g.env_bools[(usz)current] != target.env_bools[j] || g.env_ptrs[(usz)current] != target.env_ptrs[j]) { return false; }
        if (!target.env_bools[j] && !target.env_ptrs[j] && !m1_value_type_compatible(target.env_types[j], g.env_types[(usz)current], 0)) { return false; }
    }
    return true;
}
// Records one control-flow edge into a label: the terminating predecessor
// block plus, per captured environment entry and per label parameter, the SSA
// value that edge carries. `arg_values` may be null when param_count == 0.
fn bool M1Gen.label_record_edge(M1Gen* g, M1Label* target, char** arg_values)
{
    if (target == null || !target.captured || g.cur_block == null) { return false; }
    if (target.edges == null)
    {
        target.edge_stride = 1 + target.env_count + target.param_count;
        if (target.edge_stride > 128) { return false; }
        target.edges = (char**)malloc((usz)(16 * target.edge_stride * 8));
        if (target.edges == null) { return false; }
    }
    if (target.edge_count >= 16) { return false; }
    char** row = target.edges + target.edge_count * target.edge_stride;
    row[0] = g.cur_block;
    for (usz j = 0; j < target.env_count; j++)
    {
        bool is_param = false;
        for (usz p = 0; p < target.param_count; p++)
        {
            if (target.params[p] != null && same(target.params[p].name, target.env_names[j])) { is_param = true; break; }
        }
        // Parameter-named captured entries are rebound at the label block by
        // the parameter phi itself; record null as a sentinel (never used).
        if (is_param) { row[1 + j] = null; continue; }
        int current = g.env_index(target.env_names[j]);
        if (current < 0) { return false; }
        row[1 + j] = g.env_values[(usz)current];
    }
    for (usz p = 0; p < target.param_count; p++)
    {
        row[1 + target.env_count + p] = arg_values != null ? arg_values[p] : null;
    }
    target.edge_count++;
    target.has_jump = true;
    return true;
}
fn void M1Gen.label_drop_edges(M1Gen* g, M1Label* target)
{
    if (target != null && target.edges != null) { free(target.edges); target.edges = null; }
    if (target != null) { target.edge_count = 0; target.edge_stride = 0; }
}

fn bool M1Gen.is_condition(M1Gen* g, AirPrd* p)
{
    if (p == null) {
 return false; }
    if (p.tag == APRD_BOOL) { return true; }
    if (p.tag == APRD_COERCE && m1_bool_type(p.ty) && p.sub_count == 1) { return true; }
    if (p.tag == APRD_VAR) { return g.lookup_bool(p.name); }
    if (p.tag == APRD_UNOP && p.uop == AUN_NOT && p.sub_count == 1) { return g.is_condition(p.subs[0]); }
    if (p.tag == APRD_BINOP)
    {
        if (p.bop == ABIN_EQ || p.bop == ABIN_NEQ || p.bop == ABIN_LT || p.bop == ABIN_GT || p.bop == ABIN_LE || p.bop == ABIN_GE) { return true; }
        if ((p.bop == ABIN_AND || p.bop == ABIN_OR || p.bop == ABIN_XOR) && p.sub_count == 2 &&
            (p.ty == null || p.ty.tag == ATYP_INFER || p.ty.tag == ATYP_BOOL))
        {
            return g.is_condition(p.subs[0]) && g.is_condition(p.subs[1]);
        }
    }
 return false;
}
// M9: collects the names of currently loop-carried locals (captured by a
// label or bound as a label parameter) that a loop body rebinds through
// lets/comus. These become header phis with the entry value on the preheader
// edge and the body's final binding on the backedge. Branching constructs
// (if/match) are terminal in AIR, so scope-local shadowing inside them cannot
// escape; only sequential/nested-loop bindings need tracking.
fn bool M1Gen.scan_carried_mutation_cns(M1Gen* g, AirCns* k, char*[] names, int* count, int depth)
{
    if (k == null) { return true; }
    if (depth >= 64) {
 return false; }
    if (k.tag == ACNS_COMU && k.bind != null && !same(k.bind, "_"))
    {
        int ix = g.env_index(k.bind);
        if (ix >= 0 && g.env_carried[(usz)ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (same(names[(usz)i], k.bind)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) {
 return false; }
                names[(usz)(*count)] = k.bind;
                (*count)++;
            }
        }
    }
    if (k.tag == ACNS_COMU && !g.scan_carried_mutation(k.body, names, count, depth + 1)) {
 return false; }
    for (usz i = 0; i < k.branch_count; i++)
    {
        if (k.branches[i] != null && !g.scan_carried_mutation(k.branches[i].body, names, count, depth + 1)) {
 return false; }
    }
    for (usz i = 0; i < k.cobranch_count; i++)
    {
        if (k.cobranches[i] != null && !g.scan_carried_mutation(k.cobranches[i].body, names, count, depth + 1)) {
 return false; }
    }
    return g.scan_carried_mutation_cns(k.tail, names, count, depth + 1);
}
fn bool M1Gen.scan_carried_mutation(M1Gen* g, AirCmd* c, char*[] names, int* count, int depth)
{
    if (c == null) { return true; }
    if (depth >= 64) {
 return false; }
    if (c.tag == ACMD_LET && c.binder != null && !same(c.binder, "_"))
    {
        int ix = g.env_index(c.binder);
        if (ix >= 0 && g.env_carried[(usz)ix])
        {
            bool seen = false;
            for (int i = 0; i < *count; i++) { if (same(names[(usz)i], c.binder)) { seen = true; break; } }
            if (!seen)
            {
                if (*count >= 32) {
 return false; }
                names[(usz)(*count)] = c.binder;
                (*count)++;
            }
        }
    }
    if (!g.scan_carried_mutation_cns(c.cns, names, count, depth + 1)) {
 return false; }
    return g.scan_carried_mutation(c.body, names, count, depth + 1) && g.scan_carried_mutation(c.next, names, count, depth + 1);
}
fn void M1Gen.note_carried_bind(M1Gen* g, char* name, char* value)
{
    if (!g.watch_active || g.branch_depth != g.watch_branch_depth || name == null || value == null) { return; }
    for (int k = 0; k < g.watch_count; k++)
    {
        if (same(g.watch_names[(usz)k], name)) { g.watch_values[(usz)k] = value; return; }
    }
}
fn char* M1Gen.watch_lookup(M1Gen* g, char* name, char* fallback)
{
    if (g.watch_active && g.branch_depth == g.watch_branch_depth)
    {
        for (int k = 0; k < g.watch_count; k++)
        {
            if (same(g.watch_names[(usz)k], name)) { return g.watch_values[(usz)k]; }
        }
    }
    return fallback;
}
// Arms of branching constructs are terminal in this backend, so bindings made
// inside them can never flow onto a loop backedge. Track that nesting so the
// carried-watch ignores them.
fn void M1Gen.branch_enter(M1Gen* g) { g.branch_depth++; }
fn void M1Gen.branch_leave(M1Gen* g) { if (g.branch_depth > 0) { g.branch_depth--; } }
// Emits the phi node for one loop-carried local at the head of a loop header
// block: the entry value flows from the preheader, the loop's final binding
// from the backedge block.
fn bool M1Gen.emit_loop_phi(M1Gen* g, char* phi, AirTyp* ty, char* entry_value, char* pre_block, bool has_backedge, char* latch_value, char* latch_block)
{
    char* ty_text = g.llvm_value_type_text(ty);
    if (phi == null || ty_text == null || entry_value == null || pre_block == null) { g.failed = true;
 return false; }
    if (has_backedge)
    {
        if (latch_value == null || latch_block == null) {
 return false; }
        fprintf(g.out, "  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]\n", phi, ty_text, entry_value, pre_block, latch_value, latch_block);
    }
    else { fprintf(g.out, "  %s = phi %s [ %s, %%%s ]\n", phi, ty_text, entry_value, pre_block); }
    return true;
}
// Command slice: return expressions, bindings, direct calls, guarded scalar
// matches, structured while loops, terminal if/else, and label/jump CFG.
// ---- M10 escape-only effect lowering helpers ----
// Backquote-quoted AIR names (`Eff.op`) normalize to their bare form.

fn bool M1Gen.buffer_label_body(M1Gen* g, M1Label* info, char* ret_name)
{
    if (info == null || !info.captured) { return false; }
    // Phase A: the label body itself can contain backedge jumps (a loop
    // label) or jumps into sibling labels (an inner loop jumping to an
    // outer exit label), so edges are only complete once *every* body has
    // been rendered. Render the body into a side buffer with phi names
    // pre-allocated; phase B composes header, phis, and buffered body.
    char* body_buffer = null;
    usz body_size = 0;
    void* side = open_memstream(&body_buffer, &body_size);
    if (side == null) { return false; }
    void* real_out = g.out;
    g.out = side;
    g.env_count = info.env_count;
    for (usz i = 0; i < info.env_count; i++)
    {
        g.env_names[i] = info.env_names[i];
        g.env_slots[i] = null;
        g.env_bools[i] = info.env_bools[i];
        g.env_ptrs[i] = info.env_ptrs[i];
        g.env_types[i] = info.env_types[i];
        g.env_carried[i] = true;
        bool is_param = false;
        for (usz p = 0; p < info.param_count; p++)
        {
            if (info.params[p] != null && same(info.params[p].name, info.env_names[i])) { is_param = true; break; }
        }
        char* phi = is_param ? null : g.tmp();
        if (!is_param && phi == null) { fclose(side); g.out = real_out; g.failed = true; return false; }
        info.env_phis[i] = phi;
        g.env_values[i] = phi != null ? phi : info.env_values[i];
    }
    for (usz i = 0; i < info.param_count; i++) { info.param_phis[i] = g.tmp(); if (info.param_phis[i] == null) { fclose(side); g.out = real_out; g.failed = true; return false; } }
    for (usz i = 0; i < info.param_count; i++)
    {
        AirBinder* p = info.params[i];
        if (p.name != null && !same(p.name, "_"))
        {
            if (!g.bind_rep(p.name, info.param_phis[i], info.param_bools[i], info.param_ptrs[i], p.ty)) { fclose(side); g.out = real_out; return false; }
            g.env_carried[g.env_count - 1] = true;
        }
    }
    bool saved_watch = g.watch_active;
    int saved_watch_count = g.watch_count;
    g.watch_active = false;
    bool saved_replay = g.in_label_replay;
    g.in_label_replay = true;
    g.cur_block = info.name;
    g.terminated = false;
    bool body_ok = g.command(info.cmd.body, ret_name) && g.terminated;
    g.in_label_replay = saved_replay;
    g.watch_active = saved_watch;
    g.watch_count = saved_watch_count;
    if (fclose(side) != 0) { g.out = real_out; return false; }
    g.out = real_out;
    if (!body_ok) { free(body_buffer); return false; }
    info.body_buffer = body_buffer;
    info.body_size = body_size;
    info.buffered = true;
    return true;
}
fn bool M1Gen.replay_label_block(M1Gen* g, M1Label* info)
{
    // Phase B (see buffer_label_body): every body has been rendered, so the
    // recorded edge sets are final and phi composition is order-independent.
    if (info == null || !info.buffered) { return false; }
    char* body_buffer = info.body_buffer;
    usz body_size = info.body_size;
    info.body_buffer = null;
    info.body_size = 0;
    info.buffered = false;
    g.begin_block(info.name);
    // Emit the completed phi nodes against the fully recorded edge set. An
    // edgeless label never executes; bind undef so the body still verifies.
    for (usz i = 0; i < info.env_count; i++)
    {
        if (info.env_phis[i] == null) { continue; }
        // Bool bindings can carry an infer AIR type from `(eq ... : infer)`
        // producers; the LLVM value track is representational, so the phi
        // must follow the bool flag rather than the AIR annotation.
        char* ty = info.env_bools[i] ? (char*)"i1" : g.llvm_value_type_text(info.env_types[i]);
        if (ty == null) { free(body_buffer); return false; }
        if (info.edge_count == 0)
        {
            // Unreachable label: keep the pre-allocated phi names well-defined
            // so the buffered body still verifies (it can never execute).
            fprintf(g.out, "  %s = freeze %s undef\n", info.env_phis[i], ty);
            continue;
        }
        fprintf(g.out, "  %s = phi %s ", info.env_phis[i], ty);
        for (usz e = 0; e < info.edge_count; e++)
        {
            char** row = info.edges + e * info.edge_stride;
            if (e != 0) { fprintf(g.out, ", "); }
            fprintf(g.out, "[ %s, %%%s ]", row[1 + i] != null ? row[1 + i] : (char*)"undef", row[0]);
        }
        fprintf(g.out, "\n");
    }
    for (usz i = 0; i < info.param_count; i++)
    {
        char* ty = g.llvm_value_type_text(info.params[i].ty);
        if (ty == null) { free(body_buffer); return false; }
        if (info.edge_count == 0)
        {
            fprintf(g.out, "  %s = freeze %s undef\n", info.param_phis[i], ty);
            continue;
        }
        fprintf(g.out, "  %s = phi %s ", info.param_phis[i], ty);
        for (usz e = 0; e < info.edge_count; e++)
        {
            char** row = info.edges + e * info.edge_stride;
            if (e != 0) { fprintf(g.out, ", "); }
            fprintf(g.out, "[ %s, %%%s ]", row[1 + info.env_count + i] != null ? row[1 + info.env_count + i] : (char*)"undef", row[0]);
        }
        fprintf(g.out, "\n");
    }
    if (body_size > 0) { fwrite(body_buffer, 1, body_size, g.out); }
    free(body_buffer);
    return true;
}
