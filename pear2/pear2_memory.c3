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
    if (value == null || alignment <= 0 || extent < M1EXTENT_RUNTIME) { return false; }
    int at = g.prov_index(value);
    bool fresh = at < 0;
    if (fresh) { if (g.provenance_count >= 1024) { return false; } at = g.provenance_count++; }
    M1Provenance* p = &g.provenance[at];
    if (fresh) { p.allocation = value; }
    p.value = value; p.pointee = pointee; p.kind = kind; p.alignment = alignment;
    p.extent = extent; p.extent_value = null; p.offset = offset; p.offset_known = offset_known; p.freed = false; p.writable = writable;
    p.lo = offset; p.hi = offset;
    return true;
}
// Record a pointer whose offset is a range rather than a constant. The caller
// has already emitted whatever runtime check proves every address in the range
// lies inside the allocation, so this is a strictly stronger fact than "offset
// unknown", and strictly weaker than "offset == k". `lo` doubles as `offset` so
// the offset-keyed pointer-cell bookkeeping degrades to "no exact cell", which
// is the safe answer: a store through a dynamically indexed address is refused
// as a pointer cell until the address is a constant again.
fn bool M1Gen.prov_set_span(M1Gen* g, char* value, AirTyp* pointee, int kind, int alignment, long extent, long lo, long hi, bool writable)
{
    // `hi < 0` records an open span: the pointer is at or after `lo`, and no
    // static claim is made about the top. A tight span must sit inside the
    // object, because a tight span is used as a compile-time proof.
    if (lo < 0 || (hi >= 0 && (extent < 0 || hi > extent || hi < lo))) { return false; }
    if (!g.prov_set(value, pointee, kind, alignment, extent, lo, false, writable)) { return false; }
    M1Provenance* p = g.prov(value);
    if (p == null) { return false; }
    p.lo = lo; p.hi = hi;
    return true;
}
// A heap object whose byte count is a register, not a literal. `extent` becomes
// M1EXTENT_RUNTIME and `extent_value` carries the i64 count; every later proof
// that would have compared against `extent` turns into a runtime comparison
// against `extent_value`, so the guarantee is unchanged and the constant is gone.
fn bool M1Gen.prov_set_dynamic_extent(M1Gen* g, char* value, AirTyp* pointee, int kind, int alignment, char* extent_value)
{
    if (extent_value == null) { return false; }
    if (!g.prov_set(value, pointee, kind, alignment, M1EXTENT_RUNTIME, 0, true, true)) { return false; }
    M1Provenance* p = g.prov(value);
    if (p == null) { return false; }
    p.extent_value = extent_value;
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
    char* extent_value = p.extent_value;
    bool known = p.offset_known; bool was_freed = p.freed; bool writable = p.writable; char* allocation = p.allocation;
    long lo = p.lo; long hi = p.hi;
    if (!g.prov_set(to, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    M1Provenance* copy = g.prov(to); copy.freed = was_freed; copy.allocation = allocation;
    copy.extent_value = extent_value;
    copy.lo = lo; copy.hi = hi;
    return true;
}
fn bool M1Gen.retype_pointer(M1Gen* g, char* value, AirTyp* pointee)
{
    M1Provenance* p = g.prov(value);
    if (p == null) { return true; }
    int kind = p.kind; int alignment = p.alignment; long extent = p.extent;
    char* extent_value = p.extent_value;
    long offset = p.offset; bool known = p.offset_known; bool writable = p.writable; bool was_freed = p.freed;
    long lo = p.lo; long hi = p.hi;
    if (!g.prov_set(value, pointee, kind, alignment, extent, offset, known, writable)) { return false; }
    M1Provenance* q = g.prov(value); q.freed = was_freed; q.extent_value = extent_value; q.lo = lo; q.hi = hi;
    return true;
}
// Pointer cells are keyed by (allocation name, byte offset). The name is not
// enough on its own: a local allocation is an SSA temporary, and `%t7` names a
// different object in every function. Function-local cells are searched first
// and only ever belong to the body being emitted; module cells were recorded
// before any body and are shared by all of them, which is what a pointer stored
// inside a global needs.
fn M1PointerCell* M1Gen.cell_find(M1Gen* g, char* allocation, long offset)
{
    if (allocation == null) { return null; }
    for (int i = g.pointer_cell_count - 1; i >= 0; i--)
    {
        if (same(g.pointer_cells[i].allocation, allocation) && g.pointer_cells[i].offset == offset) { return &g.pointer_cells[i]; }
    }
    for (int i = g.module_cell_count - 1; i >= 0; i--)
    {
        if (same(g.module_cells[i].allocation, allocation) && g.module_cells[i].offset == offset) { return &g.module_cells[i]; }
    }
    return null;
}
// A fresh cell, in the table that matches the scope the store happens in. Running
// out is a budget the program can see: a function that tracks more than 512
// pointer values is beyond what this model carries, and saying so is better than
// silently forgetting one.
fn M1PointerCell* M1Gen.cell_new(M1Gen* g)
{
    if (g.at_module_scope)
    {
        if (g.module_cell_count >= 256) { g.note_failure(g.last_line, g.last_col, (char*)"more than 256 pointer-valued global cells are tracked"); return null; }
        return &g.module_cells[g.module_cell_count++];
    }
    if (g.pointer_cell_count >= 512) { g.note_failure(g.last_line, g.last_col, (char*)"more than 512 pointer cells are tracked in one function"); return null; }
    return &g.pointer_cells[g.pointer_cell_count++];
}
fn bool M1Gen.cell_set_at(M1Gen* g, char* allocation, long offset, char* value, bool is_null)
{
    if (allocation == null || offset < 0) { return false; }
    M1PointerCell* c = g.cell_find(allocation, offset);
    if (c == null) { c = g.cell_new(); if (c == null) { return false; } }
    c.allocation = allocation; c.offset = offset; c.is_null = is_null;
    c.value_allocation = null; c.pointee = null; c.kind = M1PROV_UNKNOWN; c.alignment = 1; c.extent = 0;
    c.value_extent_value = null; c.value_offset = 0;
    c.offset_known = false; c.freed = false; c.writable = false; c.value_lo = 0; c.value_hi = 0;
    if (!is_null)
    {
        M1Provenance* p = g.prov(value);
        if (p == null || p.freed) { return false; }
        c.value_allocation = p.allocation; c.pointee = p.pointee; c.kind = p.kind; c.alignment = p.alignment;
        c.extent = p.extent; c.value_extent_value = p.extent_value; c.value_offset = p.offset;
        c.offset_known = p.offset_known; c.freed = p.freed; c.writable = p.writable;
        // A cell can hold a pointer whose offset is an interval (it came from a
        // bounds-checked dynamic index). Restoring only the point would widen the
        // pointer's apparent bounds when it is loaded again, so the interval
        // travels with the cell.
        c.value_lo = p.offset_known ? p.offset : p.lo; c.value_hi = p.offset_known ? p.offset : p.hi;
    }
    return true;
}
// A cell holding a constant address with no allocation behind it: a function
// symbol in a vtable or a callback slot. `kind` is UNKNOWN and `extent` is zero,
// so a value loaded from this cell may be called but never dereferenced. That is
// the fail-closed answer, and it is also the true one.
fn bool M1Gen.cell_set_symbol(M1Gen* g, char* allocation, long offset, char* symbol)
{
    if (allocation == null || offset < 0 || symbol == null) { return false; }
    M1PointerCell* c = g.cell_find(allocation, offset);
    if (c == null) { c = g.cell_new(); if (c == null) { return false; } }
    c.allocation = allocation; c.offset = offset; c.is_null = false;
    c.value_allocation = symbol; c.pointee = null; c.kind = M1PROV_UNKNOWN;
    c.alignment = 1; c.extent = 0; c.value_extent_value = null; c.value_offset = 0; c.offset_known = false;
    c.freed = false; c.writable = false; c.value_lo = 0; c.value_hi = 0;
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
    if (ap == null || result == null || !ap.offset_known) { return true; }   // no exact cell for an interval address
    M1PointerCell* c = g.cell_find(ap.allocation, ap.offset);
    if (c == null || c.is_null) { return true; }
    if (!g.prov_set(result, c.pointee, c.kind, c.alignment, c.extent, c.value_offset, c.offset_known, c.writable)) { return false; }
    M1Provenance* p = g.prov(result); p.allocation = c.value_allocation; p.freed = c.freed;
    p.extent_value = c.value_extent_value;
    p.lo = c.value_lo; p.hi = c.value_hi;
    return true;
}

// The address a load or store is about to use, and the reason it is allowed to.
//
// Three answers, in order of strength:
//
//   1. exact   -- the byte offset is a constant, so bounds and alignment are
//                 proved here, at compile time, and the access costs nothing.
//   2. interval-- the offset came from a bounds-checked dynamic index and the
//                 whole interval is still inside the object, so compile time
//                 proves it for every index the runtime check admitted.
//   3. runtime -- the offset is only known to be `base + something`. A check is
//                 emitted: the access traps unless `[addr, addr+size)` is inside
//                 the tracked allocation.
//
// There is no fourth answer. A pointer with no provenance at all -- a function
// argument, an address produced by an external call -- is refused, exactly as
// before. The runtime check does not widen what the compiler will touch; it only
// replaces "I cannot prove this index" with "the index is checked when it runs".
fn bool M1Gen.check_access(M1Gen* g, char* address, AirTyp* ty, int line, int col, bool write_access)
{
    M1Provenance* p = g.prov(address);
    long size = g.type_size(ty, 0); int need_align = g.type_alignment(ty, 0);
    if (p == null || p.kind == M1PROV_UNKNOWN || p.freed || size < 0 || need_align == 0 ||
        !m1_value_type_compatible(p.pointee, ty, 0) || (write_access && !p.writable))
    {
        return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
    }
    if (p.offset_known)
    {
        if (p.offset < 0 || p.alignment < need_align)
        {
            return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
        }
        // An exact offset over an object of unknown size is still an exact
        // address: only the top of the object has to be learned at run time.
        if (p.extent < 0) { return g.check_access_runtime(p, address, size, null, line, col); }
        if (p.offset + size > p.extent)
        {
            return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
        }
        return true;
    }
    if (p.extent >= 0 && p.hi >= 0 && p.lo >= 0 && p.hi + size <= p.extent && p.alignment >= need_align) { return true; }
    return g.check_access_runtime(p, address, size, null, line, col);
}

// `p` describes an address whose offset is not a constant. Emit the check that
// makes the access safe for whatever the address turned out to be.
fn bool M1Gen.check_access_runtime(M1Gen* g, M1Provenance* p, char* address, long size, char* size_value, int line, int col)
{
    if (p == null || address == null || p.allocation == null || p.extent == 0 ||
        (p.extent < 0 && p.extent_value == null))
    {
        return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
    }
    // `malloc(n)` can fail, and a null object has no addressable byte. The check
    // is the only place that knows the object's identity, so it is the place that
    // has to rule the null case out: without this, `[null, null+size)` would
    // compare equal to a null base and let a dereference through.
    bool runtime_extent = p.extent < 0;
    char* nonnull = runtime_extent ? g.tmp() : null;
    char* guarded = runtime_extent ? g.tmp() : null;
    char* end = g.tmp();
    char* last = g.tmp();
    char* above_base = g.tmp();
    char* below_end = g.tmp();
    char* inside = g.tmp();
    char* ok_label = g.label((char*)"access.ok.");
    char* bad_label = g.label((char*)"access.bounds.");
    if (g.failed || end == null || last == null || above_base == null || below_end == null || inside == null ||
        ok_label == null || bad_label == null || (runtime_extent && (nonnull == null || guarded == null))) { return false; }
    // Neither GEP may be `inbounds`: the whole point of the check is that the
    // address might be outside the object, and `inbounds` would make computing
    // it undefined behaviour before the check ever ran.
    if (runtime_extent) { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %s\n", end, p.allocation, p.extent_value); }
    else { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", end, p.allocation, p.extent); }
    if (size_value != null) { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %s\n", last, address, size_value); }
    else { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", last, address, size); }
    fprintf(g.out, "  %s = icmp uge ptr %s, ptr %s\n", above_base, address, p.allocation);
    fprintf(g.out, "  %s = icmp ule ptr %s, ptr %s\n", below_end, last, end);
    fprintf(g.out, "  %s = and i1 %s, %s\n", inside, above_base, below_end);
    if (runtime_extent)
    {
        fprintf(g.out, "  %s = icmp ne ptr %s, null\n", nonnull, p.allocation);
        fprintf(g.out, "  %s = and i1 %s, %s\n", guarded, inside, nonnull);
    }
    fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", runtime_extent ? guarded : inside, ok_label, bad_label);
    g.terminated = true;
    g.begin_block(bad_label);
    fprintf(g.out, "  call void @llvm.trap()\n  unreachable\n");
    g.begin_block(ok_label);
    g.terminated = false;
    return true;
}

// A byte-range access: `memcpy(dst, src, n)`, `memset(dst, c, n)`. There is no
// element type and no alignment requirement, so the only thing left to establish
// is the bound -- proved here when the length is a literal, checked at run time
// when the length is a register, exactly as a typed access is.
fn bool M1Gen.check_range(M1Gen* g, char* address, long size, char* size_value, int line, int col, bool write_access)
{
    if (address == null || (size < 0 && size_value == null))
    { return g.note_failure(line, col, (char*)"a bulk memory operation needs a known byte count"); }
    M1Provenance* p = g.prov(address);
    if (p == null || p.kind == M1PROV_UNKNOWN || p.freed || (write_access && !p.writable))
    { return g.note_failure(line, col, (char*)"a bulk memory operation needs a tracked address with the right permission"); }
    if (size_value == null && size >= 0 && p.extent >= 0)
    {
        // Both ends constant: the answer is a proof or a refusal, never a check.
        if (p.offset_known || p.hi >= 0)
        {
            long top = p.offset_known ? p.offset : p.hi;
            if (top + size > p.extent)
            { return g.note_failure(line, col, (char*)"a bulk memory operation exceeds the object"); }
            return true;
        }
    }
    return g.check_access_runtime(p, address, size, size_value, line, col);
}

// Alignment to claim for an access through `address`. A constant offset keeps
// the type's natural alignment, which is what lets the backend use one wide
// load. A dynamically indexed address only shares the allocation's alignment
// with the element stride, so it claims 1: always true, never a lie.
fn int M1Gen.access_alignment(M1Gen* g, char* address, AirTyp* ty)
{
    M1Provenance* p = g.prov(address);
    if (p != null && !p.offset_known) { return 1; }
    return g.type_alignment(ty, 0);
}

// Atomics additionally require the address to be naturally aligned for the
// operation width, and no runtime check can establish that on x86 without
// changing the operation. So they stay restricted to constant offsets.
fn bool M1Gen.address_is_exact(M1Gen* g, char* address, int line, int col)
{
    M1Provenance* p = g.prov(address);
    if (p == null || !p.offset_known)
    {
        return g.note_failure(line, col, (char*)"an atomic operation needs a constant address (a dynamic index has no provable alignment)");
    }
    return true;
}

// Drop every cell that lives inside `allocation`. Something the compiler cannot
// see may have written there: an external call, a callee that stores through its
// parameter, or a `realloc` that moved the object. Forgetting is fail-closed --
// the next load of a pointer from that memory has no provenance at all, so it
// cannot be dereferenced until the program stores a tracked pointer there again.
// The alternative, keeping the cell, would attach the provenance of whatever used
// to be at that address to whatever the callee put there instead.
fn void M1Gen.forget_cells_in(M1Gen* g, char* allocation)
{
    if (allocation == null) { return; }
    int keep = 0;
    for (int i = 0; i < g.pointer_cell_count; i++)
    {
        if (same(g.pointer_cells[i].allocation, allocation)) { continue; }
        if (keep != i) { g.pointer_cells[keep] = g.pointer_cells[i]; }
        keep++;
    }
    g.pointer_cell_count = keep;
    keep = 0;
    for (int i = 0; i < g.module_cell_count; i++)
    {
        if (same(g.module_cells[i].allocation, allocation)) { continue; }
        if (keep != i) { g.module_cells[keep] = g.module_cells[i]; }
        keep++;
    }
    g.module_cell_count = keep;
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
    for (int i = 0; i < g.module_cell_count; i++)
    {
        if (same(g.module_cells[i].value_allocation, allocation)) { g.module_cells[i].freed = true; }
    }
}
