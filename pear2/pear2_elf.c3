// PEAR 2 native pipeline, stage 3: the ELF64 relocatable object writer.
//
// This produces a `.o` with no library involved: section headers, a symbol table,
// a string table, and RELA relocations, laid out by hand. It exists because the
// native path has to be able to say "here is a linkable object" without handing
// the work to a driver, and because the LLVM path's object emission is the one
// place PEAR 2 still cannot see the bytes it produced.
//
// Layout is deliberately simple and, more importantly, *fixed*: every object this
// writer emits has the same eight sections in the same order, so a reader (or a
// test) can find things by index rather than by parsing the whole table:
//
//   0  NULL
//   1  .text      executable code, 16-byte aligned
//   2  .rodata    read-only data, 8-byte aligned
//   3  .data      writable initialised data, 8-byte aligned
//   4  .symtab    one entry per function, one per undefined symbol
//   5  .strtab    symbol names
//   6  .rela.text relocations against .text
//   7  .shstrtab  section names
//
// Only what PEAR 2 needs is modelled: STT_FUNC definitions in .text, STT_OBJECT
// in .data/.rodata, and undefined STT_NOTYPE symbols for the libc entry points a
// program calls. Relocations are R_X86_64_PLT32 (the 32-bit PC-relative call and
// jump form) and R_X86_64_PC32 (a 32-bit PC-relative data references), which are
// exactly the two forms the instruction encoder records fixups for.
module pear2c;
import air_ir;


const int ELFCLASS64 = 2;
const int ELFDATA2LSB = 1;
const int EV_CURRENT = 1;
const int ELFOSABI_SYSV = 0;
const int ET_REL = 1;
const int EM_X86_64 = 62;

const int SHT_NULL = 0;
const int SHT_PROGBITS = 1;
const int SHT_SYMTAB = 2;
const int SHT_STRTAB = 3;
const int SHT_RELA = 4;

const long SHF_WRITE = 0x1;
const long SHF_ALLOC = 0x2;
const long SHF_EXECINSTR = 0x4;

const int STB_LOCAL = 0;
const int STB_GLOBAL = 1;
const int STT_NOTYPE = 0;
const int STT_OBJECT = 1;
const int STT_FUNC = 2;
const int STT_SECTION = 3;

const int SHN_UNDEF = 0;

const int R_X86_64_PC32 = 2;
const int R_X86_64_PLT32 = 4;

// One output section as the writer sees it: a byte range, an alignment, and the
// flags that go in the header. The writer never moves data once it is appended,
// so a section's offset is its position in the file image.
struct ElfSection {
    char* name;
    int type;
    long flags;
    char* data;
    usz size;
    usz capacity;
    usz align;
    usz file_offset;
    int link;       // section index the section refers to (symtab/rela)
    int info;
    usz ent_size;
    bool owns_data; // stack-backed sections (the header tables) are not freed
}

struct ElfSym {
    char* name;
    ulong value;
    ulong size;
    int section;    // section index, or SHN_UNDEF
    int bind;
    int type;
}

struct ElfRela {
    usz offset;
    int symbol;     // index into ElfSym order as written
    int type;
    long addend;
}

struct ElfObject {
    ElfSection[8] sections;
    int section_count;
    ElfSym[1024] syms;
    int sym_count;
    // Serialisation order. The ELF format requires every local symbol to come
    // before the first global one, so the table is written in a different order
    // than symbols are registered in. Relocations name an index into `syms`, and
    // `order` is what turns that into a byte offset in the written table.
    int[1024] order;
    ElfRela[4096] relas;
    int rela_count;
    // String tables are built as one growing buffer each; symbol names and
    // section names never share storage because the ELF spec requires the two
    // tables to be independent.
    char* strtab;
    usz strtab_len;
    usz strtab_cap;
    char* shstrtab;
    usz shstrtab_len;
    usz shstrtab_cap;
    bool failed;
}

fn bool elf_init(ElfObject* o)
{
    if (o == null) { return false; }
    memset(o, 0, ElfObject::size);
    // Section 0 is the mandatory NULL section: all-zero header, no data.
    o.sections[0].name = (char*)"";
    o.sections[0].type = SHT_NULL;
    o.sections[0].align = 0;
    o.section_count = 1;
    o.strtab = (char*)malloc(256);
    o.shstrtab = (char*)malloc(256);
    if (o.strtab == null || o.shstrtab == null) { o.failed = true; return false; }
    memset(o.strtab, 0, 256);
    memset(o.shstrtab, 0, 256);
    // Both string tables start with a NUL byte, so index 0 is the empty name.
    o.strtab_len = 1;
    o.shstrtab_len = 1;
    o.strtab_cap = 256;
    o.shstrtab_cap = 256;
    return true;
}

fn void elf_free(ElfObject* o)
{
    if (o == null) { return; }
    for (int i = 0; i < o.section_count; i++)
    {
        if (o.sections[(usz)i].owns_data && o.sections[(usz)i].data != null) { free(o.sections[(usz)i].data); }
    }
    if (o.strtab != null) { free(o.strtab); }
    if (o.shstrtab != null) { free(o.shstrtab); }
    o.strtab = null;
    o.shstrtab = null;
    o.section_count = 0;
}

// ── string tables ──────────────────────────────────────────────────────────

fn usz elf_strtab_add(ElfObject* o, char* text)
{
    if (o == null || text == null) { return 0; }
    usz need = 0;
    while (text[need] != 0) { need++; }
    need++;
    if (o.strtab_len + need > o.strtab_cap)
    {
        usz next = o.strtab_cap;
        while (next < o.strtab_len + need) { next = next * 2; }
        char* grown = (char*)malloc(next);
        if (grown == null) { o.failed = true; return 0; }
        memset(grown, 0, next);
        memcpy(grown, o.strtab, o.strtab_len);
        free(o.strtab);
        o.strtab = grown;
        o.strtab_cap = next;
    }
    usz at = o.strtab_len;
    for (usz i = 0; i < need; i++) { o.strtab[at + i] = (char)text[i]; }
    o.strtab_len += need;
    return at;
}

fn usz elf_shstr_add(ElfObject* o, char* text)
{
    if (o == null || text == null) { return 0; }
    usz need = 0;
    while (text[need] != 0) { need++; }
    need++;
    if (o.shstrtab_len + need > o.shstrtab_cap)
    {
        usz next = o.shstrtab_cap;
        while (next < o.shstrtab_len + need) { next = next * 2; }
        char* grown = (char*)malloc(next);
        if (grown == null) { o.failed = true; return 0; }
        memset(grown, 0, next);
        memcpy(grown, o.shstrtab, o.shstrtab_len);
        free(o.shstrtab);
        o.shstrtab = grown;
        o.shstrtab_cap = next;
    }
    usz at = o.shstrtab_len;
    for (usz i = 0; i < need; i++) { o.shstrtab[at + i] = (char)text[i]; }
    o.shstrtab_len += need;
    return at;
}

// ── sections ───────────────────────────────────────────────────────────────

fn bool elf_section_append(ElfObject* o, int index, char* data, usz size)
{
    if (o == null || index <= 0 || index >= o.section_count) { return false; }
    ElfSection* s = &o.sections[(usz)index];
    if (s.size + size > s.capacity)
    {
        usz next = s.capacity == 0 ? 4096 : s.capacity;
        while (next < s.size + size) { next = next * 2; }
        char* grown = (char*)malloc(next);
        if (grown == null) { o.failed = true; return false; }
        memset(grown, 0, next);
        if (s.data != null && s.size > 0) { memcpy(grown, s.data, s.size); }
        if (s.owns_data && s.data != null) { free(s.data); }
        s.data = grown;
        s.capacity = next;
        s.owns_data = true;
    }
    memcpy(s.data + s.size, data, size);
    s.size += size;
    return true;
}

fn bool elf_section_append_byte(ElfObject* o, int index, char value)
{
    return elf_section_append(o, index, &value, 1);
}

// elf_align_section -- pad a section to its own alignment. The padding byte for
// executable memory is NOP, so even a miscomputed entry point cannot execute
// random bytes; data sections pad with zero.
fn bool elf_align_section(ElfObject* o, int index)
{
    if (o == null || index <= 0 || index >= o.section_count) { return false; }
    ElfSection* s = &o.sections[(usz)index];
    if (s.align == 0) { return true; }
    char pad = s.type == SHT_PROGBITS && (s.flags & SHF_EXECINSTR) != 0 ? 0x90 : 0x00;
    while (s.size % s.align != 0) { if (!elf_section_append_byte(o, index, pad)) { return false; } }
    return true;
}

// ── symbols ────────────────────────────────────────────────────────────────

// elf_add_symbol -- register a symbol and return its index. A name that already
// exists keeps its first index: two declarations of the same external are one
// symbol, and that is what the relocation list needs.
fn int elf_add_symbol(ElfObject* o, char* name, int section, ulong value, ulong size, int bind, int type)
{
    if (o == null || name == null) { return -1; }
    if (o.sym_count >= 1024) { o.failed = true; return -1; }
    int idx = o.sym_count;
    o.syms[(usz)idx].name = name;
    o.syms[(usz)idx].section = section;
    o.syms[(usz)idx].value = value;
    o.syms[(usz)idx].size = size;
    o.syms[(usz)idx].bind = bind;
    o.syms[(usz)idx].type = type;
    o.sym_count++;
    return idx;
}

fn int elf_find_symbol(ElfObject* o, char* name)
{
    if (o == null || name == null) { return -1; }
    for (int i = 0; i < o.sym_count; i++)
    {
        char* have = o.syms[(usz)i].name;
        if (have == null) { continue; }
        usz k = 0;
        bool same_name = true;
        while (have[k] != 0 || name[k] != 0)
        {
            if (have[k] != name[k]) { same_name = false; break; }
            k++;
        }
        if (same_name) { return i; }
    }
    return -1;
}

// elf_ensure_undefined -- the symbol index for an external the code calls.
fn int elf_ensure_undefined(ElfObject* o, char* name)
{
    int found = elf_find_symbol(o, name);
    if (found >= 0) { return found; }
    return elf_add_symbol(o, name, SHN_UNDEF, 0, 0, STB_GLOBAL, STT_NOTYPE);
}

fn bool elf_add_rela(ElfObject* o, usz offset, int symbol, int type, long addend)
{
    if (o == null) { return false; }
    if (o.rela_count >= 4096) { o.failed = true; return false; }
    o.relas[(usz)o.rela_count].offset = offset;
    o.relas[(usz)o.rela_count].symbol = symbol;
    o.relas[(usz)o.rela_count].type = type;
    o.relas[(usz)o.rela_count].addend = addend;
    o.rela_count++;
    return true;
}

// ── serialisation ──────────────────────────────────────────────────────────

fn void elf_put8(char* out, usz at, char v) { out[at] = v; }

fn void elf_put16(char* out, usz at, uint v)
{
    out[at] = (char)(v & 0xFF);
    out[at + 1] = (char)((v >> 8) & 0xFF);
}

fn void elf_put32(char* out, usz at, uint v)
{
    out[at] = (char)(v & 0xFF);
    out[at + 1] = (char)((v >> 8) & 0xFF);
    out[at + 2] = (char)((v >> 16) & 0xFF);
    out[at + 3] = (char)((v >> 24) & 0xFF);
}

fn void elf_put64(char* out, usz at, ulong v)
{
    elf_put32(out, at, (uint)(v & 0xFFFFFFFF));
    elf_put32(out, at + 4, (uint)((v >> 32) & 0xFFFFFFFF));
}

fn usz elf_align_up(usz value, usz alignment)
{
    if (alignment == 0) { return value; }
    usz rem = value % alignment;
    return rem == 0 ? value : value + (alignment - rem);
}

// elf_build_symtab -- serialise the symbol table, locals first.
//
// The ELF format requires every symbol with STB_LOCAL binding to precede the
// first non-local one, and sh_info of the symbol table must be the index of the
// first non-local symbol. Getting this wrong is a link error that names a symbol
// nobody wrote, so the writer sorts explicitly rather than relying on the order
// functions happened to be registered in.
fn bool elf_build_symtab(ElfObject* o)
{
    if (o == null || o.section_count <= 4) { return false; }
    ElfSection* symtab = &o.sections[4];
    // Entry 0 is reserved: an all-zero symbol, the "no symbol" index.
    char[24] zeros;
    memset(&zeros[0], 0, 24);
    if (!elf_section_append(o, 4, &zeros[0], 24)) { return false; }
    int first_global = 1;
    // Locals first.
    for (int pass = 0; pass < 2; pass++)
    {
        for (int i = 0; i < o.sym_count; i++)
        {
            ElfSym* s = &o.syms[(usz)i];
            bool is_local = s.bind == STB_LOCAL;
            if (pass == 0 && !is_local) { continue; }
            if (pass == 1 && is_local) { continue; }
            if (pass == 1 && first_global == 1) { first_global = (int)(symtab.size / 24); }
            o.order[(usz)i] = (int)(symtab.size / 24);
            usz name_offset = elf_strtab_add(o, s.name);
            char[24] entry;
            memset(&entry[0], 0, 24);
            elf_put32(&entry[0], 0, (uint)name_offset);
            elf_put8(&entry[0], 4, (char)((s.bind << 4) | (s.type & 0xF)));
            elf_put16(&entry[0], 6, (uint)(s.section & 0xFFFF));
            elf_put64(&entry[0], 8, s.value);
            elf_put64(&entry[0], 16, s.size);
            if (!elf_section_append(o, 4, &entry[0], 24)) { return false; }
        }
    }
    o.sections[4].info = first_global;
    o.sections[4].ent_size = 24;
    o.sections[4].link = 5;
    return true;
}

fn bool elf_build_rela(ElfObject* o)
{
    if (o == null || o.rela_count == 0) { return true; }
    if (o.section_count <= 6) { return false; }
    for (int i = 0; i < o.rela_count; i++)
    {
        ElfRela* r = &o.relas[(usz)i];
        char[24] entry;
        memset(&entry[0], 0, 24);
        elf_put64(&entry[0], 0, (ulong)r.offset);
        // r_info packs the symbol index in the high 32 bits and the type in the
        // low 32, which is the ELF64 layout (ELF32 packed them the other way
        // round, which is why this is worth stating).
        int serial = (r.symbol >= 0 && r.symbol < 1024) ? o.order[(usz)r.symbol] : 0;
        ulong info = ((ulong)serial << 32) | (ulong)((uint)r.type & 0xFFFFFFFF);
        elf_put64(&entry[0], 8, info);
        elf_put64(&entry[0], 16, (ulong)r.addend);
        if (!elf_section_append(o, 6, &entry[0], 24)) { return false; }
    }
    o.sections[6].ent_size = 24;
    o.sections[6].link = 4;
    o.sections[6].info = 1; // relocations apply to .text
    return true;
}

// elf_set_bytes -- assign a table section's contents outright. Used for the
// string and relocation tables, whose bytes are produced elsewhere and then
// handed over once they are final.
fn bool elf_set_bytes(ElfObject* o, int index, char* data, usz size)
{
    if (o == null || index <= 0 || index >= o.section_count) { return false; }
    ElfSection* s = &o.sections[(usz)index];
    if (size > s.capacity)
    {
        usz next = size < 1024 ? 1024 : size * 2;
        char* grown = (char*)malloc(next);
        if (grown == null) { o.failed = true; return false; }
        memset(grown, 0, next);
        if (s.owns_data && s.data != null) { free(s.data); }
        s.data = grown;
        s.capacity = next;
        s.owns_data = true;
    }
    if (size > 0 && data != null) { memcpy(s.data, data, size); }
    s.size = size;
    return true;
}

// elf_write -- lay the object out and hand back the finished image.
//
// The order of operations here is the whole correctness argument:
//   1. every section name goes into the section-name table, so each header's
//      sh_name is final before any byte offset is computed;
//   2. the symbol table is built (it fills .strtab as a side effect), then the
//      relocations (which need the symbol order), then both tables are handed to
//      their sections;
//   3. only then are offsets assigned, because a section whose size changed
//      after it was placed would shift every section after it.
fn bool elf_write(ElfObject* o, char** out_data, usz* out_size)
{
    if (o == null || out_data == null || out_size == null || o.failed) { return false; }
    if (o.section_count != 8) { return false; }
    usz[8] name_at;
    for (int i = 0; i < 8; i++) { name_at[(usz)i] = 0; }
    for (int i = 1; i < o.section_count; i++) { name_at[(usz)i] = elf_shstr_add(o, o.sections[(usz)i].name); }
    if (!elf_set_bytes(o, 7, o.shstrtab, o.shstrtab_len)) { return false; }
    if (!elf_build_symtab(o)) { return false; }
    if (!elf_set_bytes(o, 5, o.strtab, o.strtab_len)) { return false; }
    if (!elf_build_rela(o)) { return false; }
    for (int i = 0; i < o.section_count; i++)
    {
        if (!elf_align_section(o, i)) { return false; }
    }
    usz header_size = 64;
    usz section_header_size = 64;
    usz offset = header_size;
    for (int i = 1; i < o.section_count; i++)
    {
        if (o.sections[(usz)i].size == 0) { o.sections[(usz)i].file_offset = offset; continue; }
        o.sections[(usz)i].file_offset = offset;
        offset += o.sections[(usz)i].size;
    }
    usz shoff = elf_align_up(offset, 8);
    usz total = shoff + (usz)o.section_count * section_header_size;
    char* image = (char*)malloc(total);
    if (image == null) { return false; }
    memset(image, 0, total);
    // ── ELF header ──
    image[0] = 0x7F; image[1] = 'E'; image[2] = 'L'; image[3] = 'F';
    elf_put8(image, 4, ELFCLASS64);
    elf_put8(image, 5, ELFDATA2LSB);
    elf_put8(image, 6, EV_CURRENT);
    elf_put8(image, 7, ELFOSABI_SYSV);
    elf_put16(image, 16, ET_REL);
    elf_put16(image, 18, EM_X86_64);
    elf_put32(image, 20, EV_CURRENT);
    elf_put64(image, 24, 0);            // e_entry: none in a relocatable object
    elf_put64(image, 32, 0);            // e_phoff: no program headers
    elf_put64(image, 40, (ulong)shoff);
    elf_put32(image, 48, 0);            // e_flags
    elf_put16(image, 52, 64);           // e_ehsize
    elf_put16(image, 54, 0);            // e_phentsize
    elf_put16(image, 56, 0);            // e_phnum
    elf_put16(image, 58, 64);           // e_shentsize
    elf_put16(image, 60, (uint)o.section_count);
    elf_put16(image, 62, 7);            // e_shstrndx -> .shstrtab
    // ── section contents ──
    for (int i = 1; i < o.section_count; i++)
    {
        ElfSection* s = &o.sections[(usz)i];
        if (s.size == 0 || s.data == null) { continue; }
        memcpy(image + s.file_offset, s.data, s.size);
    }
    // ── section headers ──
    for (int i = 0; i < o.section_count; i++)
    {
        ElfSection* s = &o.sections[(usz)i];
        usz at = shoff + (usz)i * section_header_size;
        elf_put32(image, at, (uint)name_at[(usz)i]);
        elf_put32(image, at + 4, (uint)s.type);
        elf_put64(image, at + 8, (ulong)s.flags);
        elf_put64(image, at + 16, 0);   // sh_addr: resolved by the linker
        elf_put64(image, at + 24, (ulong)s.file_offset);
        elf_put64(image, at + 32, (ulong)s.size);
        elf_put32(image, at + 40, (uint)s.link);
        elf_put32(image, at + 44, (uint)s.info);
        elf_put64(image, at + 48, (ulong)s.align);
        elf_put64(image, at + 56, (ulong)s.ent_size);
    }
    *out_data = image;
    *out_size = total;
    return true;
}

// elf_new_object -- the section skeleton every object from this writer has. The
// fixed order is documented at the top of the file; a reader can rely on
// .text == 1 and .rela.text == 6.
fn bool elf_new_object(ElfObject* o)
{
    if (o == null || !elf_init(o)) { return false; }
    // .text
    o.sections[1].name = (char*)".text";
    o.sections[1].type = SHT_PROGBITS;
    o.sections[1].flags = SHF_ALLOC | SHF_EXECINSTR;
    o.sections[1].align = 16;
    // .rodata
    o.sections[2].name = (char*)".rodata";
    o.sections[2].type = SHT_PROGBITS;
    o.sections[2].flags = SHF_ALLOC;
    o.sections[2].align = 8;
    // .data
    o.sections[3].name = (char*)".data";
    o.sections[3].type = SHT_PROGBITS;
    o.sections[3].flags = SHF_ALLOC | SHF_WRITE;
    o.sections[3].align = 8;
    // .symtab
    o.sections[4].name = (char*)".symtab";
    o.sections[4].type = SHT_SYMTAB;
    o.sections[4].align = 8;
    o.sections[4].ent_size = 24;
    o.sections[4].link = 5;
    // .strtab
    o.sections[5].name = (char*)".strtab";
    o.sections[5].type = SHT_STRTAB;
    o.sections[5].align = 1;
    // .rela.text
    o.sections[6].name = (char*)".rela.text";
    o.sections[6].type = SHT_RELA;
    o.sections[6].align = 8;
    o.sections[6].ent_size = 24;
    o.sections[6].link = 4;
    o.sections[6].info = 1;
    // .shstrtab
    o.sections[7].name = (char*)".shstrtab";
    o.sections[7].type = SHT_STRTAB;
    o.sections[7].align = 1;
    o.section_count = 8;
    return true;
}
