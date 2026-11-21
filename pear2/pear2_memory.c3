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
// A pointer the caller handed in.
//
// Its extent is not expressible here: the callee knows the pointee type and
// nothing about how many of them there are, and there is no length in the AIR to
// recover it from. So this is the one provenance kind the model *trusts* rather
// than proves -- exactly the contract every systems language makes when it hands
// a callee a pointer. Everything else stays checked: a `free` still wants a heap
// base, an atomic still wants a constant address, and a dereference of a
// *pointer loaded out of* caller memory is still refused until the program
// stores a tracked pointer there again.
fn bool M1Gen.prov_param(M1Gen* g, char* value, AirTyp* pointee)
{
    // extent 0 marks "unknown size"; offset 0 because the caller's pointer is the
    // base of whatever it is the caller means.
    if (!g.prov_set(value, pointee, M1PROV_PARAM, 1, 0, 0, true, true)) { return false; }
    M1Provenance* p = g.prov(value);
    if (p == null) { return false; }
    p.allocation = value;
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
    // A caller-supplied pointer: the access is written as the pointee type says,
    // and the model makes no claim about it because it has nothing to check it
    // against. Claiming the natural alignment would be a lie (the caller may have
    // passed anything), so `access_alignment` asks for 1 here.
    if (p.kind == M1PROV_PARAM) { return true; }
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
//
// This is the point where the memory model either beats a C compiler or does
// not, so it is worth being precise about what it does and, more usefully, what
// it refuses to promise.
//
//  1. The fact cache. A check already emitted for the same (object, address,
//     size) is not emitted again; `fact_has` answers that in one scan, and the
//     second occurrence costs nothing at all. Facts are keyed by SSA value, and
//     a value is defined in exactly one place, so the first check for a pair
//     dominates every later use of that pair. No dominance analysis is needed:
//     the property is structural.
//  2. The null guard is once per object, not once per access. `malloc(n)` may
//     return null, and `[null, null+n)` compares equal on both sides, so the
//     first check must rule null out. Recording that (`guard_acquire`) turns N
//     null tests on one allocation into one, which the optimiser then deletes
//     outright for any object it can see came from a non-null source.
//  3. A loop-indexed access is *not* hoisted here, and this is deliberate. The
//     address in a loop body is a fresh GEP over the induction phi, so it does
//     not exist in the entry block and cannot be checked there; the check belongs
//     where the address is. Hoisting it is loop-invariant code motion, which is
//     the optimiser's job and which it can now actually do, because every
//     quantity involved is a value it can reason about (a pointer, a length and
//     a GEP) rather than a side condition of ours. What the model owes is the
//     *provable* case, and that is answered earlier: `check_access` proves an
//     access at compile time whenever the offset is exact or the span is closed,
//     and a for-loop over a fixed array is exactly that case, so it emits no
//     check to hoist in the first place.
fn bool M1Gen.check_access_runtime(M1Gen* g, M1Provenance* p, char* address, long size, char* size_value, int line, int col)
{
    if (p == null || address == null || p.allocation == null || p.extent == 0 ||
        (p.extent < 0 && p.extent_value == null))
    {
        return g.note_failure(line, col, (char*)"memory access with unknown/out-of-bounds/misaligned provenance");
    }
    // The guard value names the object's extent: a runtime extent is the register
    // the callee used, and a literal extent belongs to the object itself, which
    // is why a stack object and a global can be told apart by the guard alone.
    char* guard = p.extent < 0 ? p.extent_value : p.allocation;
    if (g.fact_has(guard, address, size_value, size)) { g.access_redundant++; return true; }
    bool runtime_extent = p.extent < 0;
    bool need_nonnull = runtime_extent && !g.guard_has(p.allocation);
    char* nonnull = need_nonnull ? g.tmp() : null;
    char* checked = need_nonnull ? g.tmp() : null;
    char* end = g.tmp();
    char* last = g.tmp();
    char* above_base = g.tmp();
    char* below_end = g.tmp();
    char* inside = g.tmp();
    char* ok_label = g.label((char*)"access.ok.");
    char* bad_label = g.label((char*)"access.bounds.");
    if (g.failed || end == null || last == null || above_base == null || below_end == null || inside == null ||
        ok_label == null || bad_label == null || (need_nonnull && (nonnull == null || checked == null))) { return false; }
    // Neither GEP may be `inbounds`: the whole point of the check is that the
    // address might be outside the object, and `inbounds` would make computing
    // it undefined behaviour before the check ever ran. The *proven* GEPs the
    // program itself uses are marked `inbounds` (see gep_prd), so once this
    // branch is known taken the address is inbounds for the rest of its life.
    if (runtime_extent) { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %s\n", end, p.allocation, p.extent_value); }
    else { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", end, p.allocation, p.extent); }
    if (size_value != null) { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %s\n", last, address, size_value); }
    else { fprintf(g.out, "  %s = getelementptr i8, ptr %s, i64 %ld\n", last, address, size); }
    fprintf(g.out, "  %s = icmp uge ptr %s, ptr %s\n", above_base, address, p.allocation);
    fprintf(g.out, "  %s = icmp ule ptr %s, ptr %s\n", below_end, last, end);
    fprintf(g.out, "  %s = and i1 %s, %s\n", inside, above_base, below_end);
    if (need_nonnull)
    {
        fprintf(g.out, "  %s = icmp ne ptr %s, null\n", nonnull, p.allocation);
        fprintf(g.out, "  %s = and i1 %s, %s\n", checked, inside, nonnull);
    }
    fprintf(g.out, "  br i1 %s, label %%%s, label %%%s\n", need_nonnull ? checked : inside, ok_label, bad_label);
    g.terminated = true;
    g.begin_block(bad_label);
    fprintf(g.out, "  call void @llvm.trap()\n  unreachable\n");
    g.begin_block(ok_label);
    g.terminated = false;
    if (need_nonnull) { g.guard_acquire(p.allocation); }
    g.access_checked++;
    g.fact_set(guard, address, size_value, size, line, col);
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
    // A copy through a caller-supplied pointer is the same trust as a typed
    // access through one, and for the same reason: the callee is given a
    // pointer, not a length, so there is no bound to check the run against.
    if (p.kind == M1PROV_PARAM) { return true; }
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
    if (p != null && (p.kind == M1PROV_PARAM || !p.offset_known)) { return 1; }
    return g.type_alignment(ty, 0);
}

// Atomics additionally require the address to be naturally aligned for the
// operation width, and no runtime check can establish that on x86 without
// changing the operation. So they stay restricted to constant offsets.
fn bool M1Gen.address_is_exact(M1Gen* g, char* address, int line, int col)
{
    M1Provenance* p = g.prov(address);
    if (p == null || !p.offset_known || p.kind == M1PROV_PARAM)
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

// ============================================================================
// Value-keyed access facts: the memory model's proof cache.
// ----------------------------------------------------------------------------
// The provenance table above answers "may this pointer be dereferenced, and
// within what extent". This table answers a different question: "has the check
// that makes this *address* safe already been emitted, in a place that dominates
// this use".
//
// The soundness argument is the whole reason this is small. Every fact is keyed
// by (guarded value, address value, byte count). A guarded value is an SSA
// temporary, and an SSA temporary is defined in exactly one place, so the first
// emitted check for a pair dominates every later use of that pair *by
// construction*: no dominance analysis is needed to justify reuse, and no fact
// can be reused outside the region where its guard ran. A load or store that
// reuses a fact therefore simplifies, in the optimiser, to `br i1 true, ...`,
// and the backend folds it away. That is the mechanism by which the memory model
// stops paying for bounds checks it has already paid for.
//
// The table is cleared at the start of every function. SSA temporaries restart
// their numbering in each function, so a fact from another body would otherwise
// match an unrelated value -- the exact failure mode the pointer cells document.
// Both tables are small and get folded into one: the guarded value comes first
// and the address second, so a single scan finds every fact that mentions a
// value in either position.

// Record that `address` has been checked against the extent of `guard`.
fn void M1Gen.fact_set(M1Gen* g, char* guard, char* address, char* size_value, long size, int line, int col)
{
    if (guard == null || address == null) { return; }
    for (int i = g.access_fact_count - 1; i >= 0; i--)
    {
        M1AccessFact* f = &g.access_facts[i];
        if (!same(f.guard, guard) || !same(f.address, address)) { continue; }
        // The byte count identifies the fact too. A shorter access is covered by
        // a longer one on the same address, so a later smaller check is recorded
        // as the smaller claim it is rather than being silently widened.
        if (same(f.size_value, size_value) && f.size == size)
        {
            f.line = line; f.col = col;
            return;
        }
    }
    if (g.access_fact_count >= 1024) { return; }   // full: stop learning, keep checking
    M1AccessFact* f = &g.access_facts[g.access_fact_count++];
    f.guard = guard; f.address = address; f.size_value = size_value; f.size = size;
    f.line = line; f.col = col;
}

// Is an access of `size` bytes at `address` already known to be inside the object
// that `guard` bounds? An exact size match is the common case (a typed access
// always asks for the size of its pointee). A recorded fact with a *larger*
// constant size also covers this access, because both are bounds on the same
// address within the same object and the whole range was proven to fit.
fn bool M1Gen.fact_has(M1Gen* g, char* guard, char* address, char* size_value, long size)
{
    if (guard == null || address == null) { return false; }
    for (int i = g.access_fact_count - 1; i >= 0; i--)
    {
        M1AccessFact* f = &g.access_facts[i];
        if (!same(f.guard, guard) || !same(f.address, address)) { continue; }
        if (size_value != null || f.size_value != null)
        {
            // A runtime-sized fact covers a runtime-sized access on the same
            // address: the extent was proven non-null and the address in range,
            // and both accesses start at the same place. A *constant* access is
            // only covered if the fact's own count is constant and at least as
            // large; a runtime count is not a promise about a constant size.
            if (size_value != null && f.size_value != null) { return true; }
            if (size_value == null && f.size_value == null) { return f.size >= size; }
            continue;
        }
        if (f.size >= size) { return true; }
    }
    return false;
}

// Can a fact recorded at a use of `guard` be hoisted to the entry block, where it
// runs once instead of on every path? Only if what it constrains cannot change
// between then and the last use -- and in the presence of calls, only scalars
// have that property. A check over a list whose length is read out of memory must
// be re-run after anything that may have stored to that memory, which is exactly
// what the `size_value` field records. So a fact with a runtime *size* is not
// hoistable, and neither is one whose guard is anything but a scalar.
//
// `g.cur_block` is "entry" for exactly as long as the entry block is the block
// being emitted, which is the same trick the hoisted checks themselves rely on.
fn bool M1Gen.fact_hoistable(M1Gen* g)
{
    return same(g.cur_block, "entry");
}

// Has this object's non-nullness already been proven in this function?
//
// `malloc` is the only source of a null-capable extent here, and a null object
// has no addressable byte. The check that rules it out is a promise about the
// *object*, not about the access, so it is made once and remembered -- including
// across blocks, because the first check's ok-arm dominates everything that comes
// after it in the same function.
fn bool M1Gen.guard_has(M1Gen* g, char* allocation)
{
    if (allocation == null) { return false; }
    for (int i = g.guard_count - 1; i >= 0; i--) { if (same(g.guarded[i], allocation)) { return true; } }
    return false;
}

// Record that `allocation` is now known non-null. Bounded, and silent when full:
// running out of room costs one redundant null test per later access, which is a
// performance answer and never a correctness one.
fn void M1Gen.guard_acquire(M1Gen* g, char* allocation)
{
    if (allocation == null || g.guard_has(allocation) || g.guard_count >= 256) { return; }
    g.guarded[g.guard_count++] = allocation;
}

// ── Binder types before their instructions ───────────────────────────────────
//
// The emitter binds a name to a type when it reaches the instruction that
// defines it. That is the right rule for a straight-line program and the wrong
// one for the shape a `while` loop lowers to: the loop's induction variable is
// `alloca`ted inside the initial section, and the condition block that reads it
// is emitted *before* that section, so the read arrives with the binder still
// unbound.
//
// The AIR is well typed; only the emission order is unusual. So the type of every
// binder in the body is collected up front, and `lookup_type` falls back to it
// when the environment has nothing to say. This is a type table, not a value
// table: it says what `_s7` *is*, never where its storage is, so it cannot make a
// value visible before it exists -- it only lets the emitter answer a question
// about shape that the AIR already answered.

fn void M1Gen.scan_binder(M1Gen* g, char* name, AirTyp* ty)
{
    if (name == null || ty == null || same(name, "_") || g.decl_count_scanned >= 256) { return; }
    for (int i = g.decl_count_scanned - 1; i >= 0; i--) { if (same(g.decl_names[i], name)) { return; } }
    g.decl_names[g.decl_count_scanned] = name;
    g.decl_types[g.decl_count_scanned] = ty;
    g.decl_count_scanned++;
}

// The type a name was declared with anywhere in the body, whether or not the
// instruction that defines it has been reached.
fn AirTyp* M1Gen.declared_type(M1Gen* g, char* name)
{
    if (name == null) { return null; }
    for (int i = g.decl_count_scanned - 1; i >= 0; i--) { if (same(g.decl_names[i], name)) { return g.decl_types[i]; } }
    return null;
}

// Walk a command tree collecting binder types. Producers carry their own `ty`;
// an `alloca` carries the type it allocates, and its *result* is a pointer to it,
// which is the one case that needs interpreting rather than copying.
fn void M1Gen.scan_types_producer(M1Gen* g, AirPrd* p)
{
    if (p == null) { return; }
    if (p.tag == APRD_ALLOCA) { return; }
    for (usz i = 0; i < p.sub_count; i++) { g.scan_types_producer(p.subs[i]); }
    if (p.tag == APRD_MU && p.body != null) { g.scan_types_cmd(p.body); }
}

fn void M1Gen.scan_types_cmd(M1Gen* g, AirCmd* c)
{
    if (c == null) { return; }
    // A `let`/`letrec`/`seq` binder takes the type of the producer it binds, when
    // that producer has a type of its own. `alloca` is the case this exists for:
    // `let _s7 = alloca(i64)` binds `_s7` to `ptr(i64)`, which is exactly what
    // `expr_type` answers for the producer, so the same answer is recorded here.
    if (c.binder != null && c.prd != null)
    {
        AirTyp* ty = g.expr_type_static(c.prd);
        if (ty != null) { g.scan_binder(c.binder, ty); }
    }
    if (c.body != null && c.body.tag == ACMD_MUTILDE && c.body.binder != null)
    {
        AirTyp* ty = g.expr_type_static(c.body.prd);
        if (ty != null) { g.scan_binder(c.body.binder, ty); }
    }
    for (usz i = 0; i < c.mbinder_count; i++)
    {
        AirBinder* b = c.mbinders[i];
        if (b != null) { g.scan_binder(b.name, b.ty); }
    }
    if (c.binder != null && c.tag == ACMD_LABEL)
    {
        // A label binding is a jump target, not a value; left alone.
    }
    for (usz i = 0; i < c.prd_count; i++) { g.scan_types_producer(c.prds[i]); }
    if (c.prd != null) { g.scan_types_producer(c.prd); }
    g.scan_types_cns(c.cns);
    g.scan_types_cmd(c.body);
    g.scan_types_cmd(c.next);
    g.scan_types_cmd(c.then_c);
    g.scan_types_cmd(c.else_c);
    g.scan_types_cmd(c.handled);
    for (usz i = 0; i < c.branch_count; i++) { if (c.branches[i] != null) { g.scan_types_cmd(c.branches[i].body); } }
}

fn void M1Gen.scan_types_cns(M1Gen* g, AirCns* k)
{
    if (k == null) { return; }
    if (k.tag == ACNS_COMU) { g.scan_types_cmd(k.body); return; }
    g.scan_types_producer(k.prd);
    g.scan_types_cns(k.tail);
    for (usz i = 0; i < k.branch_count; i++) { if (k.branches[i] != null) { g.scan_types_cmd(k.branches[i].body); } }
    for (usz i = 0; i < k.cobranch_count; i++) { if (k.cobranches[i] != null) { g.scan_types_cmd(k.cobranches[i].body); } }
}

// `expr_type` without touching emission state: the same answers, for producers
// whose type is a property of the AIR rather than of the environment.
fn AirTyp* M1Gen.expr_type_static(M1Gen* g, AirPrd* p)
{
    if (p == null) { return null; }
    if (p.tag == APRD_ALLOCA) { return p.ty != null ? p.ty : air_ir::air_mk_typ_ptr(g.arena, p.ty_arg); }
    if (p.ty != null && p.ty.tag != ATYP_INFER) { return p.ty; }
    if (p.tag == APRD_VAR) { return g.lookup_type_static(p.name); }
    return null;
}

// Environment first, then the body-wide binder table. Used only where a type
// question is being answered, never to locate a value.
fn AirTyp* M1Gen.lookup_type_static(M1Gen* g, char* name)
{
    AirTyp* bound = g.lookup_type(name);
    if (bound != null) { return bound; }
    return g.declared_type(name);
}
