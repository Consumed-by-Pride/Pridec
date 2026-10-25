# PEAR2 LLVM 23 build and native execution

## Reproducible setup

From the repository root, run:

```sh
bash scripts/bootstrap-pear2-llvm23.sh
```

The script puts downloaded toolchains and generated build files under `$HOME/.cache` (not Git), builds LLVM header-generation prerequisites and C3 0.8.4 with its LLVM backend, builds `pear2c`, and runs `make test-pear2-exec`.

Pinned inputs and roles:

- `llvm-runtime@23.1.3` from npm provides the LLVM C API shared library, clang, LLD command-line tools, and compiler runtimes.
- LLVM source headers and generated CMake/TableGen headers come from `llvmorg-23.1.2` via GitHub codeload. C3 reports the header/API configuration version as **23.1.2**.
- C3 source is tag `v0.8.4`, built with `C3_WITH_LLVM=ON`, `C3_LINK_DYNAMIC=ON`, and `C3_AVR_DISABLE=ON`.
- Since the npm LLD package contains tools but not LLD shared libraries, the setup builds a small C++ shim that forwards C3's LLD calls to those CLI tools. It is not an LLVM or LLD source build.

The Makefile detects the cached C3 and npm LLVM paths after bootstrap. Its build and test recipes set `PATH` and `LD_LIBRARY_PATH` for the dynamically linked compiler and PEAR2 binary. The effective runtime/tool versions are **LLVM shared library 23.1.3, llvm-config 23.1.3, clang 23.1.3, and ld.lld 23.1.3**. Do not report C3's LLVM header version as the runtime version.

## Build and test evidence

Verified command:

```sh
make test-pear2-exec
```

Exit status: **0**. It builds `pfrontc`, `pear2c`, and the optimizer harness when needed, runs the harness, then runs both execution runners with `BACKEND=./pear2c`. The observed test summary was:

```text
PASS: optimizer folds, power-of-two strength reduction, typed identities, and representation/overflow safety (65 rewrites)
exec suite: pass=13 fail=0 xfail=0 xpass=0  (cases=13 [9 files + 0 driver checks + 4 tier checks], tier=-O2, backend=./pear2c)
=== PEAR exec: pass=9 fail=0 xfail=0 unxpass=0 ===
```

The Makefile recipes supply the runtime paths automatically. For direct runner calls in a fresh shell, set them explicitly (the bootstrap script prints these exports at the end):

```sh
LLVM_ROOT="$HOME/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64"
export PATH="$LLVM_ROOT/bin:$HOME/.cache/llvm23/node_modules/llvm-runtime-lld-linux-x64/bin:$PATH"
export LD_LIBRARY_PATH="$LLVM_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LLVM23_BIN="$LLVM_ROOT/bin" LLVM23_LIBDIR="$LLVM_ROOT/lib"
export PEAR2_CLANG="$LLVM_ROOT/bin/clang"
BACKEND=./pear2c bash tests/exec/run.sh -v
BACKEND=./pear2c bash tests/exec/pear/run.sh
```

Both returned **0**. The verbose `tests/exec/run.sh` log showed:

```text
PASS cfg/-O0  emits and runs (exit 42)
PASS cfg/-O1  emits and runs (exit 42)
PASS cfg/-O2  emits and runs (exit 42)
PASS cfg/-O3  emits and runs (exit 42)
PASS pear/p01_return_42  ok (exit 42)
PASS pear/p02_arith      ok (exit 42)
PASS pear/p03_fib        ok (exit 55)
PASS pear/p04_loop_sum   ok (exit 186)
PASS pear/p05_call_chain ok (exit 42)
PASS pear/p07_mut_reassign ok (exit 21)
PASS pear/p08_if_else    ok (exit 7)
PASS pear/p09_stdout_extern ok (exit 0)
PASS pear/p99_forward_call ok (exit 42)
exec suite: pass=13 fail=0 xfail=0 xpass=0
```

`p09_stdout_extern.pie` additionally asserts stdout exactly `A`; the runner passed that check. The PEAR2-specific case list is `tests/exec/pear2_cases.txt`, now including `p04_loop_sum` and `p07_mut_reassign`. Their result codes were **186** and **21**, respectively; both are executed in the PEAR2 runner. The four optimization-tier canaries still return 42.

## Bitcode and executable smoke test

The following smoke was run against `tests/pear2/ret_main.air`:

```sh
./pear2c tests/pear2/ret_main.air --emit-bc --quiet
od -An -tx1 -N4 tests/pear2/ret_main.bc   # 42 43 c0 de
$LLVM23_BIN/clang -x ir -c tests/pear2/ret_main.bc -o tmp/ret_main.bc.o
./pear2c tests/pear2/ret_main.air --emit-exe --quiet
tests/pear2/ret_main                    # exit status 42
```

Observed: bitcode magic `4243c0de`, clang verification exit **0**, native executable exit **42**. In addition, the `p04_loop_sum` and `p07_mut_reassign` outputs produced with `BACKEND=./pear2c ... --emit-bc` were accepted by LLVM 23 clang's `-c -x ir` verifier. The full `tests/pear2/pointer_index_main.air` module, including `roundtrip_nested_array`, was likewise compiled and verified; a C harness invoked `roundtrip_nested_array` on four bytes and confirmed the returned value was 3.

## Scope of the test result

`make test-pear2` is the broader AIR/CLI and native fixture suite, separate from `test-pear2-exec`. It returned **0** with **80 PASS checks and no failures**. Its LLVM 23 native runs include `internal_aggregate_abi_main` (exit **42**), `unit_aggregate_main` (exit **42**), the C-linked `external_record_abi_main` (exit **42**), and AIR 3 `global_string_main` and `typed_memory_main` (each exit **42**). The AIR 3 positives cover typed globals and C symbol linkage, pooled string/byte constants, pointer GEP, stack/heap allocation, loads/stores, and free; five negative fixtures check dynamic/provenance/alignment rejections with source locations. The unit fixture exercises empty-tuple arguments/returns, a unit argument, and a unit field in a composite tuple; the external record fixture covers a product record/tuple crossing by-value C ABI argument and return boundaries on x86-64 Linux. `roundtrip_nested_array` emits LLVM 23-verifiable bitcode and a native harness confirms it returns **3** after nested array construction, store, and projection. These results cover the fixtures listed in the suite, not every AIR form or every `tests/exec` case.
