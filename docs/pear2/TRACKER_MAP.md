# Arena task panel ↔ code evidence map

The right-rail **"Quality Check" tracker** (113 items) is Arena UI state
inherited from a prior session — no file on disk backs it and the agent API
exposes no tool to tick it. This document is the bridge: each panel item is
mapped to concrete, verifiable code/test evidence. Items verified against the
committed tree (`a66c767`); gates: test-pear2 107/0, exec 9/0, -O0..-O3
sweeps identical.

## Visible items (as of 2026-10-26 screenshot)

| Panel item | Verdict | Evidence |
|---|---|---|
| Clone PR branch | **Done** (local) | branch `arena/fd318e2a-pridec`, 4 commits ahead of remote `ad9481f`; publish pending → Linear AYO-5→AYO-6 |
| Bootstrap LLVM path | **Done** | `scripts/bootstrap-pear2-llvm23.sh`; LLVM 23.1.3 + C3 0.8.4 pinned; `docs/pear2/LLVM23_SETUP.md` |
| Aggregate ABI lowering | **Done** | `internal_aggregate_abi_main.air`; `external_record_abi_main.air` + `external_record_abi_helper.c` (C aggregate calls both directions, exit 42, swept -O0..-O3 via run.sh `abi_ext_expect`); pair flatten+routing in pear2c_main.c3 (M3/M10 machinery) |
| Global declaration lowering | **Done** | `M1Gen.emit_globals` (pear2c_main.c3:3750) emits pooled global constants at end of function bodies; `module` globals gate fail-closed for unsupported forms (positioned) |
| String literal constants | **Done** | `M1String` pool + `string_index` dedup (pear2c_main.c3:1178, NUL-terminated call sites 3616/3686); fixture `array_local_main.air` |
| Byte buffer constants | **Done** | `string_index(bytes, len, terminate)` with `terminate=false` path (call site 1211); fixture `bytes_local_main.air` |
| Alloc free lowering | **Done** | provenance machinery: alloca marking, `freed` flags, pointer-cell tracking (pear2c_main.c3 M1Provenance/M1PointerCell, ~line 88–1100); fixture `memory_alloc_free_main.air` |
| Offset load stores | **Done** | `offset`/`value_offset`/`offset_known` provenance fields drive computed-offset loads/stores (field/tuple projection + width-coerced memory ops); fixtures `layout_main.air`, `memory_widths_main.air`, `memory_i64_main.air`, `memory_bool_main.air` |
| Alignment checks | **Done** | alignment tracked in provenance (`alignment` field), `alignof(...)` folds statically (`layout_align_pointer`), 175 alignment sites; half-width-store positional reject `reject_memory_width_main.air` |
| Branch orientation reduction | **Done** | pear2_opt.c3 `branch_reductions` counter; constant-condition `if` elimination at pear2_opt.c3:1047–1058 (selects then/else branch when condition is `bool` literal); behavioral fixture `strength_reduction_main.air` |

## Unseen items (≈103)

The remaining panel items are not visible from this side. Status cannot be
verified until the item text is known. Process per item:

1. Get the item text (user scrolls/pastes).
2. Locate implementing machinery + guarding fixture(s) in the repo.
3. If implemented and fixture-guarded: verdict **Done** with file:line
   evidence; tick in panel manually.
4. If genuinely missing: implement the slice, add run.sh coverage
   (-O0..-O3 sweep, reject-positioned assertions where applicable), run the
   quality checklist, commit, then tick.

## Quality gate for any tick

Every "Done" here corresponds to checklist items in
`docs/pear2/QUALITY_CHECKLIST.md` (117-item release gate). An item only
counts done when the checklist's ✓ criteria pass with measured evidence —
not when the code merely compiles.
