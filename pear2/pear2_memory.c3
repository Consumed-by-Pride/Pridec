// PEAR 2's bounded memory-provenance model: alias tracking, pointer cells,
// and fail-closed access validation. Kept in module pear2c with M1Gen.
module pear2c;
import air_ir;

fn int M1Gen.prov_index(M1Gen* g, char* value)
{
    if (value == null) { return -1; }
    for (int i = g.provenance_count - 1; i >= 0; i--) { if (same(g.provenance[i].value, value)) { return i; } }
    return -1;
}
fn bool M1Gen.prov_set(M1Gen* g, char* value, AirTyp* pointee, int kind, int alignment, long extent, long offset, bool offset_known, bool writable)
{
    if (value == null || alignment <= 0 || extent < 0) { return false; }
    int at = g.prov_index(value);
    bool fresh = at < 0;
    if (fresh) { if (g.provenance_count >= 1024) { return false; } at = g.provenance_count++; }
    M1Provenance* p = &g.provenance[at];
    if (fresh) { p.allocation = value; }
    p.value = value; p.pointee = pointee; p.kind = kind; p.alignment = alignment;
    p.extent = extent; p.offset = offset; p.offset_known = offset_known; p.freed = false; p.writable = writable;
    return true;
}
fn M1Provenance* M1Gen.prov(M1Gen* g, char* value)
{
    int at = g.prov_index(value);
    return at < 0 ? null : &g.provenance[at];
}
fn bool M1Gen.prov_copy(M1Gen* g, char* from, char* to)
{
    M1Provenance* p = g.prov(from);
    if (p == null || to == null) { return true; }
    AirTyp* pointee = p.pointee; int kind = p.kind;
    int alignment = p.alignment; long extent = p.extent; long offset = p.offset;
    bool known = p.offset_known; bool was_freed = p.freed; bool writable = p.writable; char* allocation = p.allocation;
    if (!g.prov_set(to, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    M1Provenance* copy = g.prov(to); copy.freed = was_freed; copy.allocation = allocation;
    return true;
}
fn bool M1Gen.retype_pointer(M1Gen* g, char* value, AirTyp* pointee)
{
    M1Provenance* p = g.prov(value);
    if (p == null) { return true; }
    int kind = p.kind; int alignment = p.alignment; long extent = p.extent;
    long offset = p.offset; bool known = p.offset_known; bool writable = p.writable; bool was_freed = p.freed;
    if (!g.prov_set(value, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    g.prov(value).freed = was_freed;
    return true;
}
fn int M1Gen.cell_index(M1Gen* g, char* allocation, long offset)
{
    for (int i = g.pointer_cell_count - 1; i >= 0; i--)
    {
        if (same(g.pointer_cells[i].allocation, allocation) && g.pointer_cells[i].offset == offset) { return i; }
    }
    return -1;
}
fn bool M1Gen.cell_set_at(M1Gen* g, char* allocation, long offset, char* value, bool is_null)
{
    if (allocation == null || offset < 0) { return false; }
    int ix = g.cell_index(allocation, offset);
    if (ix < 0)
    {
        if (g.pointer_cell_count >= 512) { return false; }
        ix = g.pointer_cell_count++;
    }
    M1PointerCell* c = &g.pointer_cells[ix];
    c.allocation = allocation; c.offset = offset; c.is_null = is_null;
    c.value_allocation = null; c.pointee = null; c.kind = M1PROV_UNKNOWN; c.alignment = 1; c.extent = 0; c.value_offset = 0;
    c.offset_known = false; c.freed = false; c.writable = false;
    if (!is_null)
    {
        M1Provenance* p = g.prov(value);
        if (p == null || p.freed) { return false; }
        c.value_allocation = p.allocation; c.pointee = p.pointee; c.kind = p.kind; c.alignment = p.alignment;
        c.extent = p.extent; c.value_offset = p.offset; c.offset_known = p.offset_known; c.freed = p.freed; c.writable = p.writable;
    }
    return true;
}
fn bool M1Gen.cell_set(M1Gen* g, char* address, char* value, bool is_null)
{
    M1Provenance* p = g.prov(address);
    if (p == null || p.freed || !p.offset_known) { return false; }
    return g.cell_set_at(p.allocation, p.offset, value, is_null);
}
fn bool M1Gen.cell_restore(M1Gen* g, char* address, char* result)
{
    M1Provenance* ap = g.prov(address);
    if (ap == null || result == null) { return true; }
    int ix = g.cell_index(ap.allocation, ap.offset);
    if (ix < 0 || g.pointer_cells[ix].is_null) { return true; }
    M1PointerCell* c = &g.pointer_cells[ix];
    if (!g.prov_set(result, c.pointee, c.kind, c.alignment, c.extent, c.value_offset, c.offset_known, c.writable)) { return false; }
    M1Provenance* p = g.prov(result); p.allocation = c.value_allocation; p.freed = c.freed;
    return true;
}

fn bool M1Gen.check_access(M1Gen* g, char* address, AirTyp* ty, int line, int col, bool write_access)
{
    M1Provenance* p = g.prov(address);
    long size = g.type_size(ty, 0); int need_align = g.type_alignment(ty, 0);
    if (p == null || p.kind == M1PROV_UNKNOWN || p.freed || !p.offset_known || size < 0 || need_align == 0 ||
        !m1_value_type_compatible(p.pointee, ty, 0) || p.offset < 0 || p.offset + size > p.extent || p.alignment < need_align || (write_access && !p.writable))
    {
        return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
    }
    return true;
}

fn void M1Gen.mark_allocation_freed(M1Gen* g, char* allocation)
{
    for (int i = 0; i < g.provenance_count; i++)
    {
        if (same(g.provenance[i].allocation, allocation)) { g.provenance[i].freed = true; }
    }
    for (int i = 0; i < g.pointer_cell_count; i++)
    {
        if (same(g.pointer_cells[i].value_allocation, allocation)) { g.pointer_cells[i].freed = true; }
    }
}
