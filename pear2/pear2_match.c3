// PEAR 2 pattern and match lowering: aggregate binders, record/sum patterns,
// scalar dispatch, and guarded aggregate arms. Same pear2c module/context.
module pear2c;
import air_ir;

fn bool M1Gen.bind_aggregate_pattern(M1Gen* g, AirPat* pat, char* value, AirTyp* value_type, int depth)
{
    if (pat == null || value == null || value_type == null || depth >= 16 || !m1_value_type(value_type, 0)) {
 return false; }
    bool tuple_pattern = pat.tag == APAT_TUPLE && value_type.tag == ATYP_TUPLE;
    bool array_pattern = pat.tag == APAT_ARRAY && value_type.tag == ATYP_ARRAY && value_type.arg_count == 1;
    if (!tuple_pattern && !array_pattern) {
 return false; }
    usz count = tuple_pattern ? value_type.arg_count : (usz)value_type.ival;
    if (count > 64 || pat.sub_count > count + 1) {
 return false; }
    usz matched = pat.sub_count;
    bool has_rest = matched > 0 && pat.sub[matched - 1] != null && pat.sub[matched - 1].tag == APAT_REST;
    if (has_rest) { matched--; }
    if ((!has_rest && matched != count) || (has_rest && matched > count)) {
 return false; }
    char* aggregate_ir = g.llvm_type_text(value_type);
    if (g.failed || aggregate_ir == null) {
 return false; }
    for (usz i = 0; i < matched; i++)
    {
        AirTyp* element_type = tuple_pattern ? value_type.args[i] : value_type.args[0];
        AirPat* element_pattern = pat.sub[i];
        if (element_type == null || element_pattern == null) {
 return false; }
        char* element_ir = g.llvm_type_text(element_type);
        char* extracted = g.tmp();
        if (g.failed || element_ir == null || extracted == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %d\n", extracted, aggregate_ir, value, (int)i);
        if (element_pattern.tag == APAT_TUPLE || element_pattern.tag == APAT_ARRAY)
        {
            if (!g.bind_aggregate_pattern(element_pattern, extracted, element_type, depth + 1)) {
 return false; }
        }
        else if (element_pattern.tag == APAT_BIND)
        {
            if (element_pattern.name != null && !same(element_pattern.name, "_") && !g.bind_typed(element_pattern.name, extracted, m1_bool_type(element_type), m1_pointer_type(element_type), element_type)) {
 return false; }
        }
        else if (element_pattern.tag != APAT_WILD) {
 return false; }
    }
    return true;
}
fn AirPat* m1_match_base_pattern(AirPat* pat)
{
    if (pat == null || pat.tag != APAT_AS) { return pat; }
    if (pat.sub_count != 1 || pat.sub[0] == null) { return null; }
    return pat.sub[0];
}
fn bool m1_sum_pattern_has_literal(AirPat* p, int depth)
{
    if (p == null || depth >= 16) {
 return false; }
    if (p.tag == APAT_INT || p.tag == APAT_FLOAT || p.tag == APAT_BOOL || p.tag == APAT_CHAR) { return true; }
    for (usz i = 0; i < p.sub_count; i++) { if (m1_sum_pattern_has_literal(p.sub[i], depth + 1)) { return true; } }
 return false;
}

// Named-field record destructuring for single-constructor product records.
// The AIR record pattern carries field names only; each name must be a field
// of the record's sole constructor, may appear once, and binds the same name.
fn bool M1Gen.bind_record_pattern(M1Gen* g, AirPat* pat, char* value, AirTyp* record_type, int line, int col)
{
    if (pat == null || pat.tag != APAT_RECORD || value == null || record_type == null || record_type.tag != ATYP_NOMINAL) {
 return false; }
    AirDecl* data = m1_find_record_decl(g.decls, g.decl_count, record_type.name);
    if (data == null || data.typaram_count != 0 || data.attr_count != 0 || (data.tag == ADECL_DATA && (data.ctor_count != 1 || data.ctors[0] == null)) || (data.tag == ADECL_CODATA && !m1_record_codata_decl(data)) || m1_record_field_count(data) > 64)
    { g.note_failure(line, col, (char*)"record patterns currently support only plain single-constructor product records (and struct codata)"); return false; }
    if (!m1_backend_type(record_type, g.decls, g.decl_count, 0)) {
 return false; }
    char* aggregate_ir = g.llvm_type_text(record_type);
    if (g.failed || aggregate_ir == null) {
 return false; }
    for (usz i = 0; i < pat.field_count; i++)
    {
        AirFieldInit* field_pat = pat.fields[i];
        if (field_pat == null || field_pat.name == null || field_pat.name[0] == 0 || same(field_pat.name, "_"))
        { g.note_failure(line, col, (char*)"record pattern entries must name record fields"); return false; }
        for (usz j = 0; j < i; j++)
        {
            if (pat.fields[j] != null && pat.fields[j].name != null && same(pat.fields[j].name, field_pat.name))
            { g.note_failure(line, col, (char*)"duplicate field name in record pattern"); return false; }
        }
        long field_index = -1;
        for (usz j = 0; j < m1_record_field_count(data); j++)
        {
            if (m1_record_field_name(data, j) != null && same(m1_record_field_name(data, j), field_pat.name)) { field_index = (long)j; break; }
        }
        if (field_index < 0)
        { g.note_failure(line, col, (char*)"record pattern names a field absent from the record"); return false; }
        AirTyp* field_type = m1_record_field_ty(data, (usz)field_index);
        if (field_type == null) {
 return false; }
        char* field_ir = g.llvm_type_text(field_type);
        char* extracted = g.tmp();
        if (g.failed || field_ir == null || extracted == null) {
 return false; }
        fprintf(g.out, "  %s = extractvalue %s %s, %ld\n", extracted, aggregate_ir, value, field_index);
        if (!g.bind_typed(field_pat.name, extracted, m1_bool_type(field_type), m1_pointer_repr_type(field_type), field_type)) {
 return false; }
    }
    return true;
}
fn bool M1Gen.match_nullary_enum(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* enum_type, AirDecl* enum_decl)
{
    if (c == null || enum_type == null || enum_decl == null || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    char* aggregate_type = g.llvm_type_text(enum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    char*[64] labels;
    int[64] tags;
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"nullary enum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed enum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(enum_decl, base.name);
            if (base.sub_count != 0 || tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"enum match supports only nullary constructors declared by its scrutinee type"); return false; }
            for (usz j = 0; j < i; j++)
            {
                AirPat* prior = m1_match_base_pattern(c.branches[j].pat);
                if (prior != null && prior.tag == APAT_VARIANT && tags[j] == tag)
                { g.note_failure(c.source_line, c.source_col, (char*)"duplicate constructor arm in enum match"); return false; }
            }
            tags[i] = tag;
            labels[i] = g.label((char*)"enum.case.");
            if (labels[i] == null) {
 return false; }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"enum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"enum.default.");
            if (labels[i] == null) {
 return false; }
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for nullary enum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"nullary enum match requires a final wildcard/default arm"); return false; }
    fprintf(g.out, "  switch i32 %s, label %%%s [", tag_value, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        fprintf(g.out, " i32 %d, label %%%s", tags[i], labels[i]);
    }
    fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        usz saved = g.env_count;
        AirPat* pat = c.branches[i].pat;
        if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
            !g.bind_typed(pat.name, aggregate_value, false, false, enum_type)) {
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(c.branches[i].body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) {
 return false; }
        g.env_count = saved;
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) {
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, enum_type)) {
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, enum_type)) {
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
// Emits payload loads and bindings for a matched constructor arm whose payload
// region lives in `scratch` (the spilled scrutinee aggregate). Handles named
// bindings, wildcards, and nested tuple/array destructuring, then the optional
// `as` alias for the whole scrutinee. Literal fields are tested beforehand by
// the caller (ordered matching only); in switch mode they are rejected here.
fn bool M1Gen.sum_arm_bind_payload(M1Gen* g, AirPat* pat, AirPat* base, AirDecl* sum_decl, int tag, char* scratch, long payload_offset, char* aggregate_value, AirTyp* sum_type, bool skip_literals, int line, int col)
{
    AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
    if (ctor == null || ctor.field_count != base.sub_count) {
 return false; }
    for (usz j = 0; j < ctor.field_count; j++)
    {
        AirPat* sub = base.sub[j];
        AirTyp* field_type = ctor.fields[j] != null ? ctor.fields[j].ty : null;
        if (sub == null || field_type == null) {
 return false; }
        bool is_literal = sub.tag == APAT_INT || sub.tag == APAT_FLOAT || sub.tag == APAT_BOOL || sub.tag == APAT_CHAR;
        if (is_literal && skip_literals) { continue; }
        bool is_bind = sub.tag == APAT_BIND && sub.name != null && !same(sub.name, "_");
        bool is_aggregate = sub.tag == APAT_TUPLE || sub.tag == APAT_ARRAY;
        if (sub.tag != APAT_WILD && !is_bind && !is_aggregate)
        {
            if (is_literal)
            { g.note_failure(line, col, (char*)"literal payload patterns require ordered constructor matching"); }
            else { g.note_failure(line, col, (char*)"unsupported payload sub-pattern; use bindings, wildcards, tuples, or arrays"); }
 return false;
        }
        if (is_aggregate &&
            ((sub.tag == APAT_TUPLE && field_type.tag != ATYP_TUPLE) || (sub.tag == APAT_ARRAY && field_type.tag != ATYP_ARRAY)))
        { g.note_failure(line, col, (char*)"payload aggregate pattern kind does not match the declared field type"); return false; }
        if (sub.tag == APAT_WILD) { continue; }
        char* field_ir = g.llvm_type_text(field_type);
        char* address = g.tmp(); char* loaded = g.tmp();
        long local_offset = 0;
        int field_align = g.type_alignment(field_type, 0);
        if (field_ir == null || address == null || loaded == null || field_align <= 0 ||
            !g.tagged_sum_field_offset(sum_decl, (usz)tag, j, &local_offset) || local_offset < 0 || local_offset > 1048576 - payload_offset)
        { g.note_failure(line, col, (char*)"unsupported constructor payload layout"); return false; }
        fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", address, scratch, payload_offset + local_offset);
        fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", loaded, field_ir, address, field_align);
        if (is_aggregate)
        {
            if (!g.bind_aggregate_pattern(sub, loaded, field_type, 0))
            { g.note_failure(line, col, (char*)"unsupported nested payload pattern shape"); return false; }
            continue;
        }
        if (!g.bind_typed(sub.name, loaded, m1_bool_type(field_type), false, field_type)) {
 return false; }
    }
    if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
        !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) {
 return false; }
    return true;
}
fn bool M1Gen.match_tagged_sum(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* sum_type, AirDecl* sum_decl)
{
    if (c == null || sum_type == null || sum_decl == null || !m1_tagged_sum_decl(sum_decl) || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
    if (!g.tagged_sum_layout(sum_decl, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size))
    { g.note_failure(c.source_line, c.source_col, (char*)"unsupported or malformed tagged-sum layout"); return false; }
    char* aggregate_type = g.llvm_type_text(sum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    char*[64] labels;
    int[64] tags;
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed tagged-sum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(sum_decl, base.name);
            if (tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor arm is not declared by the scrutinee type"); return false; }
            if (base.sub_count != sum_decl.ctors[(usz)tag].field_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor payload pattern count does not match its declaration"); return false; }
            for (usz j = 0; j < i; j++)
            {
                AirPat* prior = m1_match_base_pattern(c.branches[j].pat);
                if (prior != null && prior.tag == APAT_VARIANT && tags[j] == tag)
                { g.note_failure(c.source_line, c.source_col, (char*)"duplicate constructor arm in tagged-sum match"); return false; }
            }
            tags[i] = tag;
            labels[i] = g.label((char*)"sum.case.");
            if (labels[i] == null) {
 return false; }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"sum.default.");
            if (labels[i] == null) {
 return false; }
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for tagged-sum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires a final wildcard/default arm"); return false; }
    fprintf(g.out, "  switch i32 %s, label %%%s [", tag_value, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        fprintf(g.out, " i32 %d, label %%%s", tags[i], labels[i]);
    }
        fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        usz saved = g.env_count;
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base = m1_match_base_pattern(pat);
        if (base == null || base.tag != APAT_VARIANT) { g.env_count = saved;
 return false; }
        int tag = g.enum_constructor_index(sum_decl, base.name);
        if (tag < 0) { g.env_count = saved;
 return false; }
        AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
        if (ctor == null || ctor.field_count != base.sub_count) { g.env_count = saved;
 return false; }
        char* scratch = null;
        if (ctor.field_count > 0)
        {
            scratch = g.tmp();
            if (scratch == null) { g.env_count = saved;
 return false; }
            fprintf(g.out, "  %s = alloca %s, align %d\n", scratch, aggregate_type, sum_align);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", aggregate_type, aggregate_value, scratch, sum_align);
        }
        if (ctor.field_count > 0 && !g.sum_arm_bind_payload(pat, base, sum_decl, tag, scratch, payload_offset, aggregate_value, sum_type, false, c.source_line, c.source_col))
        { g.env_count = saved;
 return false; }
        if (ctor.field_count == 0 && pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
            !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) { g.env_count = saved;
 return false; }
        g.env_count = saved;
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) { g.env_count = saved;
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
// Recursively validates that a nested tuple/array payload sub-pattern contains
// only destructuring forms; literals and other tags are rejected with distinct
// diagnostics by the caller's arm-level validation.
fn bool m1_sum_nested_pattern_ok(AirPat* sub, int depth)
{
    if (sub == null || depth >= 16) {
 return false; }
    if (sub.tag == APAT_BIND || sub.tag == APAT_WILD) { return true; }
    if (sub.tag != APAT_TUPLE && sub.tag != APAT_ARRAY) {
 return false; }
    for (usz i = 0; i < sub.sub_count; i++) { if (!m1_sum_nested_pattern_ok(sub.sub[i], depth + 1)) {
 return false; } }
    return true;
}
// Ordered tagged-sum matching: constructor arms are tested sequentially in
// source order — first the discriminant tag, then each payload literal field —
// and a mismatch falls through to the next arm. This supports bindings,
// wildcards, nested tuple/array destructuring, and int/float/bool/char literal
// payload fields. Guards are rejected; a final wildcard/binding default arm is
// required so every discriminant/literal failure chain is total.
fn bool M1Gen.match_tagged_sum_ordered(M1Gen* g, AirCmd* c, char* ret_name, AirTyp* sum_type, AirDecl* sum_decl)
{
    if (c == null || sum_type == null || sum_decl == null || !m1_tagged_sum_decl(sum_decl) || c.branch_count < 2 || c.branch_count > 64 || c.prd == null)
    {
 return false; }
    int sum_align; int slot_bits; long payload_offset; long payload_size; long slots; long total_size;
    if (!g.tagged_sum_layout(sum_decl, 0, &sum_align, &payload_offset, &payload_size, &slot_bits, &slots, &total_size))
    { g.note_failure(c.source_line, c.source_col, (char*)"unsupported or malformed tagged-sum layout"); return false; }
    int default_index = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null || branch.guard != null)
        { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum match requires unguarded constructor arms"); return false; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base == null) { g.note_failure(c.source_line, c.source_col, (char*)"malformed tagged-sum alias pattern"); return false; }
        if (base.tag == APAT_VARIANT)
        {
            int tag = g.enum_constructor_index(sum_decl, base.name);
            if (tag < 0)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor arm is not declared by the scrutinee type"); return false; }
            AirCtorDecl* ctor = sum_decl.ctors[(usz)tag];
            if (base.sub_count != ctor.field_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"constructor payload pattern count does not match its declaration"); return false; }
            for (usz j = 0; j < ctor.field_count; j++)
            {
                AirPat* sub = base.sub[j];
                AirTyp* field_type = ctor.fields[j] != null ? ctor.fields[j].ty : null;
                if (sub == null || field_type == null) {
 return false; }
                bool bool_field = m1_bool_type(field_type);
                bool float_field = m1_float_type(field_type);
                bool char_field = field_type.tag == ATYP_CHAR;
                if (sub.tag == APAT_BIND || sub.tag == APAT_WILD) { continue; }
                if (sub.tag == APAT_INT || sub.tag == APAT_FLOAT || sub.tag == APAT_BOOL || sub.tag == APAT_CHAR)
                {
                    if (!m1_valid_match_literal(field_type, sub, bool_field, float_field, char_field, m1_int_bits(field_type), m1_unsigned(field_type)))
                    { g.note_failure(c.source_line, c.source_col, (char*)"invalid literal pattern for payload field type"); return false; }
                    continue;
                }
                if ((sub.tag == APAT_TUPLE && field_type.tag == ATYP_TUPLE) || (sub.tag == APAT_ARRAY && field_type.tag == ATYP_ARRAY))
                {
                    if (!m1_sum_nested_pattern_ok(sub, 0))
                    { g.note_failure(c.source_line, c.source_col, (char*)"nested payload patterns support only bindings, wildcards, tuples, and arrays"); return false; }
                    continue;
                }
                g.note_failure(c.source_line, c.source_col, (char*)"payload aggregate pattern kind does not match the declared field type");
 return false;
            }
        }
        else if (base.tag == APAT_WILD || base.tag == APAT_BIND)
        {
            if (default_index >= 0 || i + 1 != c.branch_count)
            { g.note_failure(c.source_line, c.source_col, (char*)"tagged-sum wildcard/binding arm must be the final match arm"); return false; }
            default_index = (int)i;
        }
        else
        { g.note_failure(c.source_line, c.source_col, (char*)"unsupported pattern for tagged-sum match"); return false; }
    }
    if (default_index < 0)
    { g.note_failure(c.source_line, c.source_col, (char*)"ordered tagged-sum match requires a final wildcard/default arm"); return false; }
    char* aggregate_type = g.llvm_type_text(sum_type);
    char* aggregate_value = g.prd(c.prd);
    char* tag_value = g.tmp();
    if (aggregate_type == null || aggregate_value == null || tag_value == null || g.failed) {
 return false; }
    fprintf(g.out, "  %s = extractvalue %s %s, 0\n", tag_value, aggregate_type, aggregate_value);
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base = m1_match_base_pattern(pat);
        int tag = g.enum_constructor_index(sum_decl, base.name);
        AirCtorDecl* ctor = tag < 0 ? null : sum_decl.ctors[(usz)tag];
        if (base == null || base.tag != APAT_VARIANT || ctor == null) {
 return false; }
        char* tag_test = g.tmp();
        char* case_label = g.label((char*)"sum.ord.case.");
        char* fail_label = g.label((char*)"sum.ord.next.");
        if (tag_test == null || case_label == null || fail_label == null) {
 return false; }
        fprintf(g.out, "  %s = icmp eq i32 %s, %d\n", tag_test, tag_value, tag);
        fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", tag_test, case_label, fail_label);
        g.terminated = true;
        g.begin_block(case_label);
        g.terminated = false;
        // Literal fields are tested before bindings so a mismatch cannot leak a
        // partial environment into the next arm.
        bool needs_scratch = false;
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirPat* sub = base.sub[j];
            if (sub != null && !((sub.tag == APAT_BIND && (sub.name == null || same(sub.name, "_"))) || sub.tag == APAT_WILD)) { needs_scratch = true; }
        }
        char* scratch = null;
        if (needs_scratch)
        {
            scratch = g.tmp();
            if (scratch == null) {
 return false; }
            fprintf(g.out, "  %s = alloca %s, align %d\n", scratch, aggregate_type, sum_align);
            fprintf(g.out, "  store %s %s, ptr %s, align %d\n", aggregate_type, aggregate_value, scratch, sum_align);
        }
        usz saved = g.env_count;
        for (usz j = 0; j < ctor.field_count; j++)
        {
            AirPat* sub = base.sub[j];
            AirTyp* field_type = ctor.fields[j].ty;
            if (sub == null || field_type == null) {
 return false; }
            if (sub.tag != APAT_INT && sub.tag != APAT_FLOAT && sub.tag != APAT_BOOL && sub.tag != APAT_CHAR) { continue; }
            bool bool_field = m1_bool_type(field_type);
            bool float_field = m1_float_type(field_type);
            bool char_field = field_type.tag == ATYP_CHAR;
            char* field_ir = g.llvm_type_text(field_type);
            char* address = g.tmp(); char* loaded = g.tmp();
            long local_offset = 0;
            int field_align = g.type_alignment(field_type, 0);
            if (field_ir == null || address == null || loaded == null || field_align <= 0 ||
                !g.tagged_sum_field_offset(sum_decl, (usz)tag, j, &local_offset) || local_offset < 0 || local_offset > 1048576 - payload_offset)
            { g.env_count = saved;
 return false; }
            fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", address, scratch, payload_offset + local_offset);
            fprintf(g.out, "  %s = load %s, ptr %s, align %d\n", loaded, field_ir, address, field_align);
            char* field_test = g.match_literal_test(field_type, sub, loaded, bool_field, float_field, char_field, m1_int_bits(field_type));
            char* step_label = g.label((char*)"sum.ord.step.");
            if (field_test == null || step_label == null) { g.env_count = saved;
 return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", field_test, step_label, fail_label);
            g.terminated = true;
            g.begin_block(step_label);
            g.terminated = false;
        }
        if (needs_scratch)
        {
            if (!g.sum_arm_bind_payload(pat, base, sum_decl, tag, scratch, payload_offset, aggregate_value, sum_type, true, c.source_line, c.source_col))
            { g.env_count = saved;
 return false; }
        }
        else if (pat.tag == APAT_AS && pat.name != null && !same(pat.name, "_") &&
                 !g.bind_typed(pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
        g.branch_enter();
        bool arm_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) { g.env_count = saved;
 return false; }
        g.env_count = saved;
        g.begin_block(fail_label);
        g.terminated = false;
    }
    // Final default arm runs where every ordered chain ends.
    usz saved = g.env_count;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    AirPat* default_base = m1_match_base_pattern(default_pat);
    if (default_base == null) { g.env_count = saved;
 return false; }
    if (default_base.tag == APAT_BIND && default_base.name != null && !same(default_base.name, "_") &&
        !g.bind_typed(default_base.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    if (default_pat.tag == APAT_AS && default_pat.name != null && !same(default_pat.name, "_") &&
        !g.bind_typed(default_pat.name, aggregate_value, false, false, sum_type)) { g.env_count = saved;
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
fn bool m1_valid_match_literal(AirTyp* scrutinee_type, AirPat* pat, bool bool_match, bool float_match, bool char_match, int bits, bool default_unsigned)
{
    if (pat == null) {
 return false; }
    if (bool_match) { return pat.tag == APAT_BOOL && (pat.ival == 0 || pat.ival == 1); }
    if (float_match)
    {
        return pat.tag == APAT_FLOAT && (pat.ty == null || !m1_known_type(pat.ty) || pat.ty.tag == scrutinee_type.tag);
    }
    if (char_match) { return pat.tag == APAT_CHAR && m1_unicode_scalar(pat.ival); }
    if (pat.tag != APAT_INT || !m1_integer_type(pat.ty)) {
 return false; }
    return (!m1_known_type(pat.ty) || m1_int_bits(pat.ty) == bits) && m1_int_fits(pat.ival, bits, scrutinee_type != null ? m1_unsigned(scrutinee_type) : default_unsigned);
}
fn char* M1Gen.match_literal_test(M1Gen* g, AirTyp* scrutinee_type, AirPat* pat, char* scrutinee, bool bool_match, bool float_match, bool char_match, int bits)
{
    if (pat == null || scrutinee == null) { return null; }
    char* test = g.tmp();
    if (test == null) { return null; }
    if (bool_match && pat.tag == APAT_BOOL)
    {
        fprintf(g.out, "  %s = icmp eq i1 %s, %s\n", test, scrutinee, pat.ival != 0 ? (char*)"true" : (char*)"false");
    }
    else if (float_match && pat.tag == APAT_FLOAT)
    {
        char* literal = g.float_text(pat.fval);
        if (literal == null) { return null; }
        fprintf(g.out, "  %s = fcmp oeq %s %s, %s\n", test, m1_llvm_float(scrutinee_type), scrutinee, literal);
    }
    else if (char_match && pat.tag == APAT_CHAR)
    {
        fprintf(g.out, "  %s = icmp eq i32 %s, %ld\n", test, scrutinee, pat.ival);
    }
    else if (!bool_match && !float_match && !char_match && pat.tag == APAT_INT)
    {
        fprintf(g.out, "  %s = icmp eq %s %s, %ld\n", test, m1_llvm_bits(bits), scrutinee, pat.ival);
    }
    else { g.failed = true; return null; }
    return test;
}
fn bool M1Gen.match_guarded_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    bool bool_match = g.is_condition(c.prd);
    if (!bool_match && g.is_pointer_value(c.prd)) {
 return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool float_match = m1_float_type(scrutinee_type);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : ((float_match || char_match) ? 32 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits));
    if (!bool_match && !float_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) {
 return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null || switch_bits <= 0) {
 return false; }
    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null || (pat.tag == APAT_AS && (pat.name == null || pat.name[0] == 0))) {
 return false; }
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (fallback)
        {
            if ((base_pat.tag == APAT_BIND && branch.guard != null && (base_pat.name == null || same(base_pat.name, "_"))) ||
                (pat.tag == APAT_AS && branch.guard != null && same(pat.name, "_"))) {
 return false; }
        }
        else if (base_pat.tag == APAT_OR)
        {
            if (base_pat.sub_count != 1 || base_pat.sub[0] == null || base_pat.or_alt == null ||
                !m1_valid_match_literal(scrutinee_type, base_pat.sub[0], bool_match, float_match, char_match, switch_bits, g.default_unsigned) ||
                !m1_valid_match_literal(scrutinee_type, base_pat.or_alt, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) {
 return false; }
        }
        else if (!m1_valid_match_literal(scrutinee_type, base_pat, bool_match, float_match, char_match, switch_bits, g.default_unsigned)) {
 return false; }
        if (fallback)
        {
            if (branch.guard == null)
            {
                if (i + 1 != c.branch_count) {
 return false; }
                final_default = (int)i;
            }
        }
    }
    if (final_default != (int)c.branch_count - 1) {
 return false; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.guard.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.guard.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) {
 return false; }
        if (!fallback)
        {
            char* test = null;
            if (base_pat.tag == APAT_OR)
            {
                char* left_test = g.match_literal_test(scrutinee_type, base_pat.sub[0], scrutinee, bool_match, float_match, char_match, switch_bits);
                char* right_test = g.match_literal_test(scrutinee_type, base_pat.or_alt, scrutinee, bool_match, float_match, char_match, switch_bits);
                test = g.tmp();
                if (g.failed || left_test == null || right_test == null || test == null) {
 return false; }
                fprintf(g.out, "  %s = or i1 %s, %s\n", test, left_test, right_test);
            }
            else { test = g.match_literal_test(scrutinee_type, base_pat, scrutinee, bool_match, float_match, char_match, switch_bits); }
            if (g.failed || test == null) {
 return false; }
            fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", test, arm_label, next_label);
        }
        else
        {
            fprintf(g.out, "  br label %%%s\n", arm_label);
        }
        g.terminated = true;
        g.begin_block(arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (base_pat.tag == APAT_BIND && base_pat.name != null && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved;
 return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, scrutinee, bool_match, false, scrutinee_type)) { g.env_count = saved;
 return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved;
 return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.guard.body.");
            if (body_label == null) { g.env_count = saved;
 return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            g.branch_enter();
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved;
 return false; }
            g.begin_block(body_label);
            g.terminated = false;
        }
        g.branch_leave();
        g.branch_enter();
        bool body_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        if (!body_ok || !g.terminated) {
 return false; }
        if (next_label != null)
        {
            g.begin_block(next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}
fn bool M1Gen.match_aggregate_guarded_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    AirTyp* aggregate_type = g.expr_type(c.prd);
    if (aggregate_type == null || (aggregate_type.tag != ATYP_TUPLE && aggregate_type.tag != ATYP_ARRAY) || !m1_value_type(aggregate_type, 0)) {
 return false; }
    char* aggregate_value = g.prd(c.prd);
    if (g.failed || aggregate_value == null) {
 return false; }
    int final_default = -1;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) {
 return false; }
        AirPat* base_pat = m1_match_base_pattern(branch.pat);
        if (base_pat == null) {
 return false; }
        bool aggregate_pat = base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY;
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        if (!aggregate_pat && !fallback) {
 return false; }
        if (branch.guard != null && !aggregate_pat && fallback && base_pat.tag == APAT_BIND && (base_pat.name == null || same(base_pat.name, "_"))) {
 return false; }
        if (branch.guard == null)
        {
            if (i + 1 != c.branch_count) {
 return false; }
            final_default = (int)i;
        }
    }
    if (final_default != (int)c.branch_count - 1) {
 return false; }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        bool fallback = base_pat.tag == APAT_BIND || base_pat.tag == APAT_WILD;
        char* arm_label = g.label((char*)"match.aggregate.arm.");
        char* next_label = i + 1 < c.branch_count ? g.label((char*)"match.aggregate.next.") : null;
        if (arm_label == null || (i + 1 < c.branch_count && next_label == null)) {
 return false; }
        fprintf(g.out, "  br label %%%s\n", arm_label);
        g.terminated = true;
        g.begin_block(arm_label);
        g.terminated = false;
        usz saved = g.env_count;
        if (fallback)
        {
            if (base_pat.tag == APAT_BIND && !same(base_pat.name, "_") && !g.bind_typed(base_pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
        }
        else if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved;
 return false; }
        if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
        if (branch.guard != null)
        {
            if (next_label == null) { g.env_count = saved;
 return false; }
            bool saved_guard_active = g.guard_active;
            char* saved_guard_name = g.guard_name;
            char* saved_guard_true = g.guard_true_label;
            char* saved_guard_false = g.guard_false_label;
            char* body_label = g.label((char*)"match.aggregate.body.");
            if (body_label == null) { g.env_count = saved;
 return false; }
            g.guard_active = true;
            g.guard_name = (char*)"%guard";
            g.guard_true_label = body_label;
            g.guard_false_label = next_label;
            g.branch_enter();
            bool guard_ok = g.command(branch.guard, (char*)"%guard");
            g.guard_active = saved_guard_active;
            g.guard_name = saved_guard_name;
            g.guard_true_label = saved_guard_true;
            g.guard_false_label = saved_guard_false;
            if (!guard_ok || !g.terminated) { g.env_count = saved;
 return false; }
            g.begin_block(body_label);
            g.terminated = false;
        }
        g.branch_leave();
        g.branch_enter();
        bool body_ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        if (!body_ok || !g.terminated) {
 return false; }
        if (next_label != null)
        {
            g.begin_block(next_label);
            g.terminated = false;
        }
    }
    return g.terminated;
}
fn bool M1Gen.match_cmd(M1Gen* g, AirCmd* c, char* ret_name)
{
    if (c == null || c.branch_count == 0 || c.branch_count > 64 || c.prd == null) {
 return false; }
    AirTyp* match_type = g.expr_type(c.prd);
    if (match_type != null && match_type.tag == ATYP_NOMINAL)
    {
        AirDecl* data = g.find_data(match_type.name);
        if (m1_nullary_enum_decl(data)) { return g.match_nullary_enum(c, ret_name, match_type, data); }
        if (m1_tagged_sum_decl(data))
        {
            bool ordered = false;
            for (usz i = 0; i < c.branch_count && !ordered; i++)
            {
                AirBranch* branch = c.branches[i];
                if (branch == null) { continue; }
                AirPat* base = m1_match_base_pattern(branch.pat);
                if (base == null || base.tag != APAT_VARIANT) { continue; }
                for (usz j = 0; j < base.sub_count && !ordered; j++)
                {
                    if (m1_sum_pattern_has_literal(base.sub[j], 0)) { ordered = true; }
                }
            }
            return ordered ? g.match_tagged_sum_ordered(c, ret_name, match_type, data) : g.match_tagged_sum(c, ret_name, match_type, data);
        }
    }
    // Record destructuring patterns are total for single-constructor product
    // records: they currently require exactly one arm.
    bool has_record_pat = false;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.pat == null) { continue; }
        AirPat* base = m1_match_base_pattern(branch.pat);
        if (base != null && base.tag == APAT_RECORD) { has_record_pat = true; }
    }
    if (has_record_pat && c.branch_count != 1)
    { g.note_failure(c.source_line, c.source_col, (char*)"record pattern matches currently require a single destructuring arm"); return false; }
    if (c.branch_count > 1 && match_type != null && (match_type.tag == ATYP_TUPLE || match_type.tag == ATYP_ARRAY)) { return g.match_aggregate_guarded_cmd(c, ret_name); }
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null) { continue; }
        AirPat* pat = branch.pat;
        bool aggregate_as = c.branch_count == 1 && pat != null && pat.tag == APAT_AS && pat.sub_count == 1 && pat.sub[0] != null && (pat.sub[0].tag == APAT_TUPLE || pat.sub[0].tag == APAT_ARRAY || pat.sub[0].tag == APAT_RECORD);
        if (branch.guard != null || (pat != null && (pat.tag == APAT_OR || (pat.tag == APAT_AS && !aggregate_as)))) { return g.match_guarded_cmd(c, ret_name); }
    }
    if (m1_float_type(g.expr_type(c.prd))) { return g.match_guarded_cmd(c, ret_name); }
    if (c.branch_count == 1)
    {
        AirBranch* branch = c.branches[0];
        if (branch == null || branch.guard != null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        AirPat* base_pat = m1_match_base_pattern(pat);
        if (base_pat == null) {
 return false; }
        if ((base_pat.tag == APAT_TUPLE || base_pat.tag == APAT_ARRAY) && c.prd.tag != APRD_UNIT)
        {
            AirTyp* aggregate_type = g.expr_type(c.prd);
            if (aggregate_type == null || !m1_value_type(aggregate_type, 0)) {
 return false; }
            char* aggregate_value = g.prd(c.prd);
            if (g.failed || aggregate_value == null) {
 return false; }
            usz saved = g.env_count;
            if (!g.bind_aggregate_pattern(base_pat, aggregate_value, aggregate_type, 0)) { g.env_count = saved;
 return false; }
            if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, aggregate_type)) { g.env_count = saved;
 return false; }
            g.branch_enter();
            bool ok = g.command(branch.body, ret_name);
            g.branch_leave();
            g.env_count = saved;
            return ok;
        }
        if (base_pat.tag == APAT_RECORD && c.prd.tag != APRD_UNIT)
        {
            AirTyp* record_type = g.expr_type(c.prd);
            if (record_type == null || record_type.tag != ATYP_NOMINAL)
            { g.note_failure(c.source_line, c.source_col, (char*)"record patterns require a nominal product-record scrutinee"); return false; }
            char* aggregate_value = g.prd(c.prd);
            if (g.failed || aggregate_value == null) {
 return false; }
            usz saved = g.env_count;
            if (!g.bind_record_pattern(base_pat, aggregate_value, record_type, c.source_line, c.source_col)) { g.env_count = saved;
 return false; }
            if (pat.tag == APAT_AS && !same(pat.name, "_") && !g.bind_typed(pat.name, aggregate_value, false, false, record_type)) { g.env_count = saved;
 return false; }
            g.branch_enter();
            bool ok = g.command(branch.body, ret_name);
            g.branch_leave();
            g.env_count = saved;
            return ok;
        }
        char* value = null;
        bool unit_match = false;
        bool bool_match = false;
        bool ptr_match = false;
        if (c.prd.tag == APRD_UNIT)
        {
            if (pat.tag != APAT_TUPLE || pat.sub_count != 0) {
 return false; }
            unit_match = true;
            value = (char*)"0";
        }
        else if (g.is_condition(c.prd))
        {
            bool_match = true;
            value = g.condition(c.prd);
            if (g.failed || value == null) {
 return false; }
        }
        else if (c.prd.tag == APRD_VAR)
        {
            value = g.lookup(c.prd.name);
            if (value == null || pat.tag == APAT_TUPLE) {
 return false; }
            ptr_match = g.lookup_ptr(c.prd.name);
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            ptr_match = g.is_pointer_value(c.prd);
            value = ptr_match ? g.pointer_value(c.prd) : g.prd(c.prd);
            if (g.failed || value == null) {
 return false; }
        }
        else {
 return false; }
        usz saved = g.env_count;
        if (pat.tag == APAT_BIND && !g.bind_typed(pat.name, value, bool_match, ptr_match, g.expr_type(c.prd))) {
 return false; }
        else if (pat.tag != APAT_BIND && pat.tag != APAT_WILD && !(unit_match && pat.tag == APAT_TUPLE)) {
 return false; }
        g.branch_enter();
        bool ok = g.command(branch.body, ret_name);
        g.branch_leave();
        g.env_count = saved;
        return ok;
    }
    bool bool_match = g.is_condition(c.prd);
    if (!bool_match && g.is_pointer_value(c.prd)) {
 return false; }
    AirTyp* scrutinee_type = g.expr_type(c.prd);
    bool char_match = scrutinee_type != null && scrutinee_type.tag == ATYP_CHAR;
    int switch_bits = bool_match ? 1 : (scrutinee_type != null ? m1_int_bits(scrutinee_type) : g.default_bits);
    if (!bool_match && (scrutinee_type != null && !m1_integer_type(scrutinee_type))) {
 return false; }
    char* scrutinee = bool_match ? g.condition(c.prd) : g.prd(c.prd);
    if (g.failed || scrutinee == null) {
 return false; }
    char*[64] labels;
    long[64] literals;
    int default_index = -1;
    usz literal_count = 0;
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirBranch* branch = c.branches[i];
        if (branch == null || branch.guard != null || branch.pat == null) {
 return false; }
        AirPat* pat = branch.pat;
        bool int_case = !bool_match && !char_match && pat.tag == APAT_INT;
        bool char_case = char_match && pat.tag == APAT_CHAR;
        if (int_case || char_case || (bool_match && pat.tag == APAT_BOOL))
        {
            if (default_index >= 0) {
 return false; }
            if (int_case && (!m1_integer_type(pat.ty) || (m1_known_type(pat.ty) && m1_int_bits(pat.ty) != switch_bits) || !m1_int_fits(pat.ival, switch_bits, scrutinee_type != null ? m1_unsigned(scrutinee_type) : g.default_unsigned))) {
 return false; }
            if (char_case && !m1_unicode_scalar(pat.ival)) {
 return false; }
            for (usz j = 0; j < literal_count; j++) { if (literals[j] == pat.ival) {
 return false; } }
            literals[literal_count] = pat.ival;
            labels[i] = g.label((char*)"match.case.");
            if (labels[i] == null) {
 return false; }
            literal_count++;
        }
        else if (pat.tag == APAT_BIND || pat.tag == APAT_WILD)
        {
            if (default_index >= 0 || i + 1 != c.branch_count) {
 return false; }
            default_index = (int)i;
            labels[i] = g.label((char*)"match.default.");
            if (labels[i] == null) {
 return false; }
        }
        else {
 return false; }
    }
    if (default_index < 0) {
 return false; }
    fprintf(g.out, "  switch %s %s, label %%%s [", bool_match ? (char*)"i1" : m1_llvm_bits(switch_bits), scrutinee, labels[(usz)default_index]);
    for (usz i = 0; i < c.branch_count; i++)
    {
        AirPat* pat = c.branches[i].pat;
        if (bool_match && pat.tag == APAT_BOOL) { fprintf(g.out, " i1 %s, label %%%s", pat.ival != 0 ? (char*)"true" : (char*)"false", labels[i]); }
        else if (!bool_match && pat.tag == APAT_INT) { fprintf(g.out, " %s %ld, label %%%s", m1_llvm_bits(switch_bits), pat.ival, labels[i]); }
        else if (char_match && pat.tag == APAT_CHAR) { fprintf(g.out, " i32 %ld, label %%%s", pat.ival, labels[i]); }
    }
    fprintf(g.out, " ]\n");
    g.terminated = true;
    for (usz i = 0; i < c.branch_count; i++)
    {
        if ((int)i == default_index) { continue; }
        g.begin_block(labels[i]);
        g.terminated = false;
        g.branch_enter();
        bool arm_ok = g.command(c.branches[i].body, ret_name);
        g.branch_leave();
        if (!arm_ok || !g.terminated) {
 return false; }
    }
    fprintf(g.out, "%s:\n", labels[(usz)default_index]);
    g.terminated = false;
    AirPat* default_pat = c.branches[(usz)default_index].pat;
    usz saved = g.env_count;
    if (default_pat.tag == APAT_BIND && !g.bind_typed(default_pat.name, scrutinee, bool_match, false, scrutinee_type)) {
 return false; }
    g.branch_enter();
    bool ok = g.command(c.branches[(usz)default_index].body, ret_name);
    g.branch_leave();
    g.env_count = saved;
    return ok && g.terminated;
}
