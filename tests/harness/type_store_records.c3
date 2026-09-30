// Record-constructor safety regressions for the nbe integration conflict.
module type_store_records_test;

import theory_setops;
alias Store = theory_setops::TypeStore;
alias Field = theory_setops::Field;
alias Kind = theory_setops::StKind;
alias Prim = theory_setops::PrimTag;
extern fn int printf(char* fmt, ...);

fn void check(bool ok, char* what, int* passed, int* failed)
{
    if (ok) { *passed = *passed + 1; }
    else { printf("FAIL record constructor: %s\n", what); *failed = *failed + 1; }
}

fn int main()
{
    Store ts;
    ts.init();
    int passed = 0; int failed = 0;
    int ti = ts.mk_prim(Prim.PRIM_INT);
    int tb = ts.mk_prim(Prim.PRIM_BOOL);
    Field[2] fields;
    fields[0].name_id = 20; fields[0].child = ti;
    fields[1].name_id = 10; fields[1].child = tb;
    int row = ts.mk_record(&fields[0], 2, ts.top_idx);
    bool sorted = row >= 0 && (usz)row < ts.node_count && ts.nodes[row].kind == Kind.ST_RECORD;
    if (sorted)
    {
        int fe = ts.nodes[row].fe_idx;
        sorted = ts.field_entries[fe].field_count == 2
              && ts.field_entries[fe].fields[0].name_id == 10
              && ts.field_entries[fe].fields[0].child == tb
              && ts.field_entries[fe].fields[1].name_id == 20;
    }
    check(sorted, "sort and preserve owned fields", &passed, &failed);

    fields[0].name_id = 7; fields[1].name_id = 7;
    row = ts.mk_record(&fields[0], 2, ts.top_idx);
    bool merged = row >= 0 && (usz)row < ts.node_count && ts.nodes[row].kind == Kind.ST_RECORD;
    if (merged)
    {
        int fe = ts.nodes[row].fe_idx;
        int child = ts.field_entries[fe].fields[0].child;
        merged = ts.field_entries[fe].field_count == 1 && ts.nodes[child].kind == Kind.ST_INTER;
    }
    check(merged, "duplicate labels retain intersection semantics", &passed, &failed);

    row = ts.mk_record(&fields[0], 1, -1);
    check(row >= 0 && (usz)row < ts.node_count && ts.nodes[row].kind == Kind.ST_RECORD
          && ts.nodes[row].children[0] == -1,
          "legacy closed-record tail sentinel stays valid", &passed, &failed);

    usz before = ts.fentry_count;
    fields[0].child = -1;
    check(ts.mk_record(&fields[0], 1, ts.top_idx) == ts.bot_idx && ts.fentry_count == before,
          "invalid field index rejected without publishing an entry", &passed, &failed);
    fields[0].child = ti;
    check(ts.mk_record(&fields[0], 1, -2) == ts.bot_idx && ts.fentry_count == before,
          "invalid tail index rejected", &passed, &failed);
    check(ts.mk_record(null, 1, ts.top_idx) == ts.bot_idx && ts.fentry_count == before,
          "null field array rejected", &passed, &failed);
    check(ts.mk_record(&fields[0], theory_setops::ST_MAX_RECORD_FIELDS + 1, ts.top_idx) == ts.bot_idx,
          "oversized count rejected before reading the field array", &passed, &failed);
    ts.node_cap = ts.node_count;
    check(ts.mk_record(null, 0, ts.top_idx) == ts.bot_idx && ts.nodes[ts.bot_idx].child_count == 0,
          "exhausted node budget preserves bottom", &passed, &failed);
    ts.destroy();

    ts.init();
    ti = ts.mk_prim(Prim.PRIM_INT); tb = ts.mk_prim(Prim.PRIM_BOOL);
    fields[0].name_id = 7; fields[0].child = ti;
    fields[1].name_id = 7; fields[1].child = tb;
    // One free node: duplicate-field intersection consumes it before the
    // record allocation. The post-allocation guard must roll back/free fields.
    ts.node_cap = ts.node_count + 1;
    row = ts.mk_record(&fields[0], 2, ts.top_idx);
    check(row == ts.bot_idx && ts.fentry_count == 0
          && ts.field_entries[0].fields == null
          && ts.nodes[ts.bot_idx].kind == Kind.ST_BOTTOM
          && ts.nodes[ts.bot_idx].child_count == 0,
          "late node exhaustion rolls back the owned field entry", &passed, &failed);
    ts.destroy();

    ts.init();
    ts.fentry_cap = 0;
    before = ts.node_count;
    check(ts.mk_record(null, 0, ts.top_idx) == ts.bot_idx && ts.node_count == before,
          "exhausted field-entry budget is checked first", &passed, &failed);
    ts.destroy();
    printf("type-store record regressions: pass=%d fail=%d\n", passed, failed);
    return failed;
}
