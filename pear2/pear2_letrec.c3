// PEAR 2 `letrec` lowering: recursive and mutually recursive local bindings.
//
// AIR's `letrec (f = ..., g = ...) in body` binds every name in the group at
// once, so an initializer may mention itself or any sibling. PEAR 2 lowers the
// group by lifting each member to a module-level function exactly as an ordinary
// `lam` would be lifted, with one deliberate difference: the group's members are
// necessarily *non-capturing*. A member's closure value does not exist yet while
// its own body is being emitted, so there is nothing for it to capture from the
// enclosing frame; what it may reference is the group, and the group is reached
// through the lifted symbols rather than through a captured environment.
//
// That single restriction is what makes the lowering sound without a fixpoint
// over environment layouts:
//
//   * `f` inside `f`'s body resolves to the constant closure `{ @f, null }`
//     (see `M1Gen.prd`), which LLVM folds back into a direct call, and
//   * the group table below is what makes the *type* of that call available
//     while the body is still being scanned.
//
// Anything outside that subset fails closed with a positioned diagnostic: a
// member that captures an enclosing local, a duplicate binder, a non-lambda
// initializer, or a group larger than the fixed table.
module pear2c;
import air_ir;

// rec_index -- the group member currently in scope under `name`, or -1. The
// table only holds names whose closures are still being defined; once a group
// has been lowered its binders live in the ordinary environment and are found
// by `M1Gen.env_index` instead.
fn int M1Gen.rec_index(M1Gen* g, char* name)
{
    if (g == null || name == null) { return -1; }
    long i = (long)g.rec_count - 1;
    while (i >= 0)
    {
        if (same(g.rec_names[(usz)i], name)) { return (int)i; }
        i--;
    }
    return -1;
}

// rec_type -- the lifted closure type of a group member. This is what lets a
// recursive call type-check while the member's own body is still being scanned:
// self and sibling references resolve here instead of through the environment.
fn AirTyp* M1Gen.rec_type(M1Gen* g, char* name)
{
    int i = g.rec_index(name);
    return i < 0 ? null : g.rec_types[(usz)i];
}

// rec_return_type -- the result type carried by a group member's closure type.
// The closure is `tuple(arrow(tuple(ptr u8, params...), result), ptr u8)`, so
// the result sits at args[0].args[1].
fn AirTyp* M1Gen.rec_return_type(M1Gen* g, char* name)
{
    AirTyp* closure = g.rec_type(name);
    if (closure == null || !m1_closure_type(closure) || closure.args[0] == null) { return null; }
    return closure.args[0].args[1];
}

// validate_letrec_group -- shape checks that must pass before any state is
// touched. Split out so a rejected group cannot leave the group table or the
// lambda budget half-consumed.
fn bool M1Gen.validate_letrec_group(M1Gen* g, AirCmd* c)
{
    if (c == null) { return false; }
    if (c.body == null)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"malformed letrec: the group has no body");
        return false;
    }
    if (c.mbinder_count != c.prd_count)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"malformed letrec: binder and initializer counts differ");
        return false;
    }
    if (c.mbinder_count > 8 || g.rec_count + (int)c.mbinder_count > 8)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"letrec groups larger than 8 bindings are not supported (counting enclosing groups still being lifted)");
        return false;
    }
    if (g.lam_count + (int)c.mbinder_count > 24)
    {
        g.note_failure(c.source_line, c.source_col, (char*)"too many lifted closures in one function");
        return false;
    }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        AirBinder* b = c.mbinders[i];
        if (b == null || b.name == null || same(b.name, "_"))
        {
            g.note_failure(c.source_line, c.source_col, (char*)"letrec requires a name for every binding");
            return false;
        }
        if (c.prds[i] == null || c.prds[i].tag != APRD_LAMBDA)
        {
            g.note_failure(c.source_line, c.source_col, (char*)"every letrec initializer must be a lambda");
            return false;
        }
        for (usz k = 0; k < i; k++)
        {
            if (c.mbinders[k] != null && same(c.mbinders[k].name, b.name))
            {
                g.note_failure(c.source_line, c.source_col, (char*)"letrec binds the same name twice");
                return false;
            }
        }
    }
    return true;
}

// plan_letrec_group -- resolve every member's capture set, parameters, result
// type, and symbol before any body is emitted.
//
// Members are planned in rounds because a group may be mutually recursive: a
// member that names a sibling cannot be typed until the sibling is in the group
// table, and the table only accepts members that have been planned. Each round
// makes at least one more member visible, so the loop terminates after at most
// `mbinder_count` rounds; a group whose members can never be typed (for example
// one whose only result is a recursive call) stops early and is reported.
fn bool M1Gen.plan_letrec_group(M1Gen* g, AirCmd* c, LamInfo[] infos, bool[] planned)
{
    bool saved_relax = g.relax_recursive_inference;
    g.relax_recursive_inference = true;
    int done = 0;
    for (usz round = 0; round < c.mbinder_count && done < (int)c.mbinder_count; round++)
    {
        int before = done;
        for (usz i = 0; i < c.mbinder_count; i++)
        {
            if (planned[i]) { continue; }
            LamInfo info = {};
            if (!g.plan_lambda(c.prds[i], &info, false)) { continue; }
            g.rec_names[(usz)g.rec_count] = c.mbinders[i].name;
            g.rec_symbols[(usz)g.rec_count] = info.symbol;
            g.rec_types[(usz)g.rec_count] = info.closure_type;
            g.rec_count++;
            infos[i] = info;
            planned[i] = true;
            done++;
        }
        if (done == before) { break; }
    }
    g.relax_recursive_inference = saved_relax;
    if (done == (int)c.mbinder_count) { return true; }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        if (planned[i]) { continue; }
        int line = c.source_line;
        int col = c.source_col;
        if (c.prds[i] != null) { line = c.prds[i].source_line; col = c.prds[i].source_col; }
        g.note_failure(line, col, (char*)"cannot infer the result type of a recursive binding; ascribe the value it returns");
        break;
    }
    return false;
}

// lower_letrec -- lower one recursive binding group:
//
//   1. validate the shape,
//   2. plan every member (symbols first, so self and sibling references resolve),
//   3. reject a member that captures outside the group,
//   4. render each lifted definition into the buffered closure stream,
//   5. bind the group in the enclosing frame as `{ code, null }` constants, and
//   6. lower the body with those bindings in scope.
fn bool M1Gen.lower_letrec(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (g == null || c == null) { return false; }
    // A group with no bindings is a scope, not a recursion: `letrec () in body`
    // is exactly `body`, which is what a front end emits for an empty group.
    if (c.mbinder_count == 0)
    {
        if (c.body == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed letrec: the group has no body"); return false; }
        return g.command(c.body, ret_name);
    }
    if (!g.validate_letrec_group(c)) { return false; }
    LamInfo[8] infos;
    bool[8] planned;
    for (usz i = 0; i < c.mbinder_count; i++) { planned[i] = false; }
    int saved_rec = g.rec_count;
    if (!g.plan_letrec_group(c, infos[..], planned[..]))
    {
        g.rec_count = saved_rec;
        return false;
    }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        if (infos[i].cap_count == 0) { continue; }
        // Reaching here means a member read a name that is bound in the
        // enclosing frame. The closure value does not exist while its own body
        // is emitted, so there is no environment to load it from; this is the
        // documented boundary of the non-capturing subset.
        int line = c.source_line;
        int col = c.source_col;
        if (c.prds[i] != null) { line = c.prds[i].source_line; col = c.prds[i].source_col; }
        g.note_failure(line, col, (char*)"a recursive binding may not capture bindings outside its own group");
        g.rec_count = saved_rec;
        return false;
    }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        if (g.emit_lifted_function(&infos[i])) { continue; }
        g.rec_count = saved_rec;
        return false;
    }
    usz saved_env = g.env_count;
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        char* value = g.materialize_closure(&infos[i], null);
        if (value == null) { g.env_count = saved_env; g.rec_count = saved_rec; return false; }
        if (!g.bind_rep(c.mbinders[i].name, value, false, false, infos[i].closure_type))
        {
            g.env_count = saved_env;
            g.rec_count = saved_rec;
            return false;
        }
    }
    bool ok = g.command(c.body, ret_name);
    g.env_count = saved_env;
    g.rec_count = saved_rec;
    return ok;
}
