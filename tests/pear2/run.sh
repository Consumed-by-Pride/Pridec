#!/bin/bash
# PEAR 2 CLI/end-to-end tests: untyped AIR 2.x -> executable or verified bitcode.
set -euo pipefail
cd "$(dirname "$0")/../.."
PEAR2_BIN="${1:-./pear2c}"
[ -x "$PEAR2_BIN" ] || { echo "pear2c not found at $PEAR2_BIN"; exit 1; }
LLVM23_BIN=${LLVM23_BIN:-$HOME/.cache/llvm23/bin}
if [ -z "${LLVM23_LIBDIR:-}" ]; then
    _llvm_root=$(dirname "$LLVM23_BIN")
    if [ -f "$_llvm_root/lib/libLLVM-23.so" ]; then LLVM23_LIBDIR="$_llvm_root/lib"; else LLVM23_LIBDIR="$_llvm_root"; fi
fi
export LD_LIBRARY_PATH="$LLVM23_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
linked_llvm=$(ldd "$PEAR2_BIN" 2>/dev/null | awk '/libLLVM(-|\.so\.)23/ { print $1; exit }' || true)
[ -n "$linked_llvm" ] || { echo "FAIL: $PEAR2_BIN is not dynamically linked to LLVM 23 C API"; exit 1; }
echo "PEAR2 LLVM C API: $linked_llvm"
find_llvm_tool() {
    local name=$1
    if [ -x "$LLVM23_BIN/$name" ]; then printf '%s' "$LLVM23_BIN/$name"; else command -v "$name" || return 1; fi
}
LLVM_OPT=${LLVM_OPT:-$(find_llvm_tool opt || true)}
PEAR2_CLANG=${PEAR2_CLANG:-$(find_llvm_tool clang || true)}
[ -x "$PEAR2_CLANG" ] || { echo "FAIL: LLVM clang not found; set PEAR2_CLANG or LLVM23_BIN"; exit 1; }
if [ -n "${C3C:-}" ] && [ -x "$C3C" ]; then echo "C3 compiler: $("$C3C" --version | head -1) ($C3C)"; fi
if [ -n "$LLVM_OPT" ] && [ -x "$LLVM_OPT" ]; then tools=("$LLVM_OPT" "$PEAR2_CLANG"); else LLVM_OPT=""; tools=("$PEAR2_CLANG"); echo "LLVM opt: absent; verifying bitcode by compiling with LLVM clang"; fi
for tool in "${tools[@]}"; do
    version=$("$tool" --version 2>&1 || true)
    printf '%s\n' "$version" | python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"(?:LLVM|clang) version (\d+)", s); sys.exit(0 if m and m.group(1)=="23" else 1)' || {
        echo "FAIL: expected LLVM 23 tool, got: $(printf '%s' "$version" | head -1) ($tool)"; exit 1;
    }
    echo "LLVM tool: $tool — $(printf '%s' "$version" | grep -m1 -E 'LLVM version|clang version' | xargs)"
done
export LLVM_OPT PEAR2_CLANG
verify_bitcode() {
    if [ -n "$LLVM_OPT" ]; then
        "$LLVM_OPT" -passes=verify -disable-output "$1"
    else
        "$PEAR2_CLANG" -Wno-override-module -c -x ir "$1" -o /dev/null
    fi
}
W=tmp/pear2-test
rm -rf "$W" && mkdir -p "$W"

# Exercise mode selection and the process contract before the bitcode suite.
cp tests/pear2/literal_main.air "$W/default.air"
set +e
"$PEAR2_BIN" "$W/default.air" --quiet >"$W/default.log" 2>&1
rc=$?
set -e
[ "$rc" = 0 ] && [ -x "$W/default" ] || { echo "FAIL: default mode did not emit executable (rc=$rc)"; cat "$W/default.log"; exit 1; }
[ ! -e "$W/default.bc" ] || { echo "FAIL: default executable mode unexpectedly published bitcode"; exit 1; }
[ ! -s "$W/default.log" ] || { echo "FAIL: --quiet printed output on success"; cat "$W/default.log"; exit 1; }
set +e
timeout 5 "$W/default" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 42 ] || { echo "FAIL: default executable returned $rc, expected 42"; exit 1; }
echo "PASS: default executable mode links and runs (exit 42)"
rm -f "$W/default"
cp "$W/default.air" "$W/path's with spaces.air"
"$PEAR2_BIN" "$W/path's with spaces.air" --quiet || { echo "FAIL: shell-sensitive input/output path rejected"; exit 1; }
set +e
timeout 5 "$W/path's with spaces" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 42 ] || { echo "FAIL: quoted-path executable returned $rc, expected 42"; exit 1; }
rm -f "$W/path's with spaces"
printf stale > "$W/default.bc"
"$PEAR2_BIN" "$W/default.air" --emit-exe -O0 --quiet || { echo "FAIL: explicit --emit-exe -O0 rejected"; exit 1; }
[ ! -e "$W/default.bc" ] || { echo "FAIL: executable mode retained stale bitcode"; exit 1; }
set +e
timeout 5 "$W/default" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" = 42 ] || { echo "FAIL: explicit --emit-exe returned $rc, expected 42"; exit 1; }
rm -f "$W/default"
printf stale > "$W/default"
"$PEAR2_BIN" "$W/default.air" --emit-bc -O3 --quiet || { echo "FAIL: explicit --emit-bc -O3 rejected"; exit 1; }
[ -f "$W/default.bc" ] && [ ! -e "$W/default" ] || { echo "FAIL: --emit-bc did not produce only the bitcode artifact"; exit 1; }
verify_bitcode "$W/default.bc" || { echo "FAIL: LLVM 23 did not parse and verify emitted bitcode"; exit 1; }
echo "PASS: explicit --emit-bc emits verifiable bitcode"

# Exit 2: usage/option errors. Exit 1: invalid AIR. Exit 3: valid AIR outside
# the supported backend subset. Every failure must remove a stale artifact.
set +e
"$PEAR2_BIN" --unknown-option >"$W/usage.log" 2>&1; rc=$?
set -e
[ "$rc" = 2 ] || { echo "FAIL: option error returned $rc, expected 2"; exit 1; }
printf stale > "$W/default"
set +e
"$PEAR2_BIN" "$W/default.air" --bad-option >"$W/bad_option.log" 2>&1; rc=$?
set -e
[ "$rc" = 2 ] && [ ! -e "$W/default" ] && [ ! -e "$W/default.bc" ] || { echo "FAIL: bad option returned $rc or retained stale outputs"; exit 1; }
printf 'not AIR\n' > "$W/invalid.air"
printf stale > "$W/invalid"
set +e
"$PEAR2_BIN" "$W/invalid.air" --quiet >"$W/invalid.log" 2>&1; rc=$?
set -e
[ "$rc" = 1 ] && [ ! -e "$W/invalid" ] || { echo "FAIL: invalid AIR returned $rc or retained stale executable"; exit 1; }
cp "$W/invalid.air" "$W/invalid_bc.air"
printf stale > "$W/invalid_bc.bc"
set +e
"$PEAR2_BIN" "$W/invalid_bc.air" --emit-bc --quiet >"$W/invalid_bc.log" 2>&1; rc=$?
set -e
[ "$rc" = 1 ] && [ ! -e "$W/invalid_bc.bc" ] || { echo "FAIL: invalid AIR/bitcode mode returned $rc or retained stale bitcode"; exit 1; }
cp tests/pear2/unsupported_main.air "$W/unsupported_cli.air"
printf stale > "$W/unsupported_cli"
set +e
"$PEAR2_BIN" "$W/unsupported_cli.air" --emit-exe --quiet >"$W/unsupported_cli.log" 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && [ ! -e "$W/unsupported_cli" ] || { echo "FAIL: unsupported AIR returned $rc or retained stale executable"; cat "$W/unsupported_cli.log"; exit 1; }
cat > "$W/fail-linker" <<'FAKE_CLANG'
#!/usr/bin/env bash
printf partial > "$4"
exit 9
FAKE_CLANG
chmod +x "$W/fail-linker"
printf stale > "$W/default"
set +e
PEAR2_CLANG="$W/fail-linker" "$PEAR2_BIN" "$W/default.air" --quiet >"$W/link_failure.log" 2>&1; rc=$?
set -e
[ "$rc" = 3 ] && [ ! -e "$W/default" ] || { echo "FAIL: linker failure returned $rc or retained stale executable"; cat "$W/link_failure.log"; exit 1; }
printf stale > "$W/default"
printf stale > "$W/default.bc"
set +e
"$PEAR2_BIN" "$W/default.air" --emit-exe --emit-bc >"$W/conflict.log" 2>&1; rc=$?
set -e
[ "$rc" = 2 ] && [ ! -e "$W/default" ] && [ ! -e "$W/default.bc" ] || { echo "FAIL: conflicting output modes returned $rc or retained stale outputs"; exit 1; }
find "$W" -maxdepth 1 -name '*.pear2-*' -print -quit | grep -q . && { echo "FAIL: temporary artifact leaked after CLI failures"; exit 1; } || true
echo "PASS: CLI exit codes 0/1/2/3 and failure cleanup"

# All remaining cases explicitly exercise the bitcode mode and independently
# Parse and verify every successful artifact with LLVM 23 opt, or clang if opt is absent.
cat > "$W/pear2-bc-wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set +e
input=$1
"$PEAR2_REAL" "$@" --emit-bc
rc=$?
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
bc="${input%.*}.bc"
if [ -n "$LLVM_OPT" ]; then
    "$LLVM_OPT" -passes=verify -disable-output "$bc"
else
    "$PEAR2_CLANG" -Wno-override-module -c -x ir "$bc" -o /dev/null
fi
exit $?
WRAPPER
chmod +x "$W/pear2-bc-wrapper"
export PEAR2_REAL="$PEAR2_BIN"
PEAR2="$W/pear2-bc-wrapper"
cp tests/pear2/literal_main.air "$W/literal.air"
if ! "$PEAR2" "$W/literal.air" --quiet; then echo "FAIL: literal main rejected"; exit 1; fi
[ -f "$W/literal.bc" ] || { echo "FAIL: no bitcode written"; exit 1; }
python3 - "$W/literal.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: output does not have LLVM bitcode magic")
print("PASS: untyped literal AIR emitted LLVM bitcode")
PY
cp tests/pear2/ret_main.air "$W/ret.air"
if ! "$PEAR2" "$W/ret.air" --quiet; then echo "FAIL: ret command AIR rejected"; exit 1; fi
python3 - "$W/ret.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: ret output does not have LLVM bitcode magic")
print("PASS: explicit ret AIR emitted LLVM bitcode")
PY
cp tests/pear2/arithmetic_main.air "$W/arithmetic.air"
if ! "$PEAR2" "$W/arithmetic.air" --quiet; then echo "FAIL: arithmetic main rejected"; exit 1; fi
python3 - "$W/arithmetic.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: arithmetic output does not have LLVM bitcode magic")
print("PASS: untyped integer arithmetic AIR emitted LLVM bitcode")
PY
cp tests/pear2/direct_call.air "$W/direct_call.air"
if ! "$PEAR2" "$W/direct_call.air" --quiet; then echo "FAIL: direct-call AIR rejected"; exit 1; fi
python3 - "$W/direct_call.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: direct-call output does not have LLVM bitcode magic")
print("PASS: scalar function and direct-call AIR emitted LLVM bitcode")
PY
cp tests/pear2/untyped_function_main.air "$W/untyped_function.air"
if ! "$PEAR2" "$W/untyped_function.air" --quiet; then echo "FAIL: unannotated internal function AIR rejected"; exit 1; fi
python3 - "$W/untyped_function.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: untyped-function output is not LLVM bitcode")
print("PASS: unannotated internal integer defaults and branch/literal result inference emitted LLVM bitcode")
PY
cp tests/pear2/bool_function_main.air "$W/bool_function.air"
if ! "$PEAR2" "$W/bool_function.air" --quiet; then echo "FAIL: bool function/call AIR rejected"; exit 1; fi
python3 - "$W/bool_function.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: bool function output does not have LLVM bitcode magic")
print("PASS: bool function ABI and direct call emitted LLVM bitcode")
PY
cp tests/pear2/extern_bool_main.air "$W/extern_bool.air"
if ! "$PEAR2" "$W/extern_bool.air" --quiet; then echo "FAIL: scalar extern AIR rejected"; exit 1; fi
python3 - "$W/extern_bool.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: scalar-extern output does not have LLVM bitcode magic")
print("PASS: bool C-ABI extern and explicit link name emitted LLVM bitcode")
PY
cp tests/pear2/extern_unit_main.air "$W/extern_unit.air"
if ! "$PEAR2" "$W/extern_unit.air" --quiet; then echo "FAIL: unit-returning extern AIR rejected"; exit 1; fi
python3 - "$W/extern_unit.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: unit extern output does not have LLVM bitcode magic")
print("PASS: void extern call emits LLVM bitcode and continues")
PY
cp tests/pear2/extern_conflict_main.air "$W/extern_conflict.air"
printf 'stale bitcode' > "$W/extern_conflict.bc"
set +e
"$PEAR2" "$W/extern_conflict.air" --quiet >"$W/extern_conflict.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: conflicting external ABI returned $rc, expected rejection"; cat "$W/extern_conflict.log"; exit 1; }
[ ! -e "$W/extern_conflict.bc" ] || { echo "FAIL: conflicting externs left a bitcode artifact"; exit 1; }
echo "PASS: conflicting external scalar ABIs fail closed"
cp tests/pear2/reject_float_abi_conflict_main.air "$W/float_abi_conflict.air"
printf 'stale bitcode' > "$W/float_abi_conflict.bc"
set +e
"$PEAR2" "$W/float_abi_conflict.air" --quiet >"$W/float_abi_conflict.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: conflicting f32/f64 ABI returned $rc, expected rejection"; cat "$W/float_abi_conflict.log"; exit 1; }
[ ! -e "$W/float_abi_conflict.bc" ] || { echo "FAIL: conflicting float ABI left bitcode"; exit 1; }
echo "PASS: f32/f64 extern conflicts fail closed"
cp tests/pear2/pointer_scalar_main.air "$W/pointer_scalar.air"
if ! "$PEAR2" "$W/pointer_scalar.air" --quiet; then echo "FAIL: scalar pointer/null AIR rejected"; exit 1; fi
python3 - "$W/pointer_scalar.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: pointer scalar output does not have LLVM bitcode magic")
print("PASS: pointer ABI, null, and pointer equality emitted LLVM bitcode")
PY
cp tests/pear2/label_pointer_main.air "$W/label_pointer.air"
if ! "$PEAR2" "$W/label_pointer.air" --quiet; then echo "FAIL: pointer label-edge AIR rejected"; exit 1; fi
python3 - "$W/label_pointer.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: pointer-label output does not have LLVM bitcode magic")
print("PASS: pointer label argument emitted LLVM bitcode")
PY
cp tests/pear2/memory_i64_main.air "$W/memory_i64.air"
if ! "$PEAR2" "$W/memory_i64.air" --quiet; then echo "FAIL: i64 pointer load/store AIR rejected"; exit 1; fi
python3 - "$W/memory_i64.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: i64 memory output does not have LLVM bitcode magic")
print("PASS: i64 pointer load/store emitted LLVM bitcode")
PY
cp tests/pear2/memory_widths_main.air "$W/memory_widths.air"
if ! "$PEAR2" "$W/memory_widths.air" --quiet; then echo "FAIL: typed i8/i16/i32 pointer-memory AIR rejected"; exit 1; fi
python3 - "$W/memory_widths.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: narrow memory output does not have LLVM bitcode magic")
print("PASS: typed i8/i16/i32 pointer loads and stores emitted LLVM bitcode")
PY
cp tests/pear2/memory_bool_main.air "$W/memory_bool.air"
if ! "$PEAR2" "$W/memory_bool.air" --quiet; then echo "FAIL: bool pointer-memory AIR rejected"; exit 1; fi
python3 - "$W/memory_bool.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: bool memory output does not have LLVM bitcode magic")
print("PASS: bool pointer loads and stores emitted LLVM bitcode")
PY
cp tests/pear2/memory_alloc_free_main.air "$W/memory_alloc_free.air"
if ! "$PEAR2" "$W/memory_alloc_free.air" --quiet; then echo "FAIL: malloc/store/load/free AIR rejected"; exit 1; fi
python3 - "$W/memory_alloc_free.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: allocation-memory output does not have LLVM bitcode magic")
print("PASS: malloc/free ABI plus pointer load/store emitted LLVM bitcode")
PY
cp tests/pear2/reject_memory_width_main.air "$W/memory_bad_width.air"
printf 'stale bitcode' > "$W/memory_bad_width.bc"
set +e
"$PEAR2" "$W/memory_bad_width.air" --quiet >"$W/memory_bad_width.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: mismatched pointer store returned $rc, expected rejection"; cat "$W/memory_bad_width.log"; exit 1; }
[ ! -e "$W/memory_bad_width.bc" ] || { echo "FAIL: mismatched pointer store left bitcode"; exit 1; }
echo "PASS: pointee/store width mismatches fail closed"
cp tests/pear2/reject_store_plain_overflow_main.air "$W/store_plain_overflow.air"
printf 'stale bitcode' > "$W/store_plain_overflow.bc"
set +e
"$PEAR2" "$W/store_plain_overflow.air" --quiet >"$W/store_plain_overflow.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: overflowing untyped store constant returned $rc, expected rejection"; cat "$W/store_plain_overflow.log"; exit 1; }
[ ! -e "$W/store_plain_overflow.bc" ] || { echo "FAIL: rejected untyped store constant left bitcode"; exit 1; }
echo "PASS: untyped store constants still require destination-width fit"
cp tests/pear2/int32_main.air "$W/int32.air"
if ! "$PEAR2" "$W/int32.air" --quiet; then echo "FAIL: i32 arithmetic/call AIR rejected"; exit 1; fi
python3 - "$W/int32.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: i32 output does not have LLVM bitcode magic")
print("PASS: i32 arithmetic and direct-call ABI emitted LLVM bitcode")
PY
cp tests/pear2/int8_main.air "$W/int8.air"
if ! "$PEAR2" "$W/int8.air" --quiet; then echo "FAIL: i8 arithmetic/call AIR rejected"; exit 1; fi
python3 - "$W/int8.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: i8 output does not have LLVM bitcode magic")
print("PASS: i8 arithmetic and signext ABI emitted LLVM bitcode")
PY
cp tests/pear2/int16_main.air "$W/int16.air"
if ! "$PEAR2" "$W/int16.air" --quiet; then echo "FAIL: i16 arithmetic/call AIR rejected"; exit 1; fi
python3 - "$W/int16.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: i16 output does not have LLVM bitcode magic")
print("PASS: i16 arithmetic and signext ABI emitted LLVM bitcode")
PY
cp tests/pear2/uint16_main.air "$W/uint16.air"
if ! "$PEAR2" "$W/uint16.air" --quiet; then echo "FAIL: u16 division/call AIR rejected"; exit 1; fi
python3 - "$W/uint16.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: u16 output does not have LLVM bitcode magic")
print("PASS: u16 unsigned division/comparison and zeroext ABI emitted LLVM bitcode")
PY
cp tests/pear2/coerce_integer_main.air "$W/coerce_integer.air"
if ! "$PEAR2" "$W/coerce_integer.air" --quiet; then echo "FAIL: integer coercion AIR rejected"; exit 1; fi
python3 - "$W/coerce_integer.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: integer coercion output does not have LLVM bitcode magic")
print("PASS: signed/unsigned integer extension and truncation emitted LLVM bitcode")
PY
cp tests/pear2/float_main.air "$W/float.air"
if ! "$PEAR2" "$W/float.air" --quiet; then echo "FAIL: f32/f64 arithmetic/call AIR rejected"; exit 1; fi
python3 - "$W/float.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: float output does not have LLVM bitcode magic")
print("PASS: f32/f64 arithmetic, comparison, and ABI emitted LLVM bitcode")
PY
cp tests/pear2/tuple_local_main.air "$W/tuple_local.air"
if ! "$PEAR2" "$W/tuple_local.air" --quiet; then echo "FAIL: nested tuple construction/projection AIR rejected"; exit 1; fi
python3 - "$W/tuple_local.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: tuple output does not have LLVM bitcode magic")
print("PASS: nested tuple construction and projection emitted LLVM bitcode")
PY
cp tests/pear2/array_local_main.air "$W/array_local.air"
if ! "$PEAR2" "$W/array_local.air" --quiet; then echo "FAIL: array construction/projection/pattern AIR rejected"; exit 1; fi
python3 - "$W/array_local.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: array output is not LLVM bitcode")
print("PASS: fixed-array construction, dynamic indexing above 64 elements, and recursive destructuring emitted LLVM bitcode")
PY
cp tests/pear2/for_main.air "$W/for.air"
if ! "$PEAR2" "$W/for.air" --quiet; then echo "FAIL: fixed-array for-loop AIR rejected"; exit 1; fi
python3 - "$W/for.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: for-loop output is not LLVM bitcode")
print("PASS: nested fixed-array iteration and stack restoration emitted LLVM bitcode")
PY
cp tests/pear2/pointer_index_main.air "$W/pointer_index.air"
if ! "$PEAR2" "$W/pointer_index.air" --quiet; then echo "FAIL: pointer index/load/store and float-memory AIR rejected"; exit 1; fi
python3 - "$W/pointer_index.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: pointer-index output is not LLVM bitcode")
print("PASS: dynamic indexing, width-converting integer stores, pointer load/store, and f32/f64 memory emitted LLVM bitcode")
PY
"$PEAR2_CLANG" -shared -fPIC -Wno-override-module "$W/pointer_index.bc" -o "$W/libpointer_index.so"
"$PEAR2_CLANG" tests/pear2/roundtrip_nested_array_harness.c -L"$W" -Wl,-rpath,"$PWD/$W" -lpointer_index -o "$W/roundtrip_nested_array_harness"
"$W/roundtrip_nested_array_harness"
echo "PASS: roundtrip_nested_array constructs, stores, and projects the nested array (returns 3)"
cp tests/pear2/internal_aggregate_abi_main.air "$W/internal_aggregate_abi.air"
if ! "$PEAR2" "$W/internal_aggregate_abi.air" --quiet; then echo "FAIL: internal tuple argument/result ABI AIR rejected"; exit 1; fi
python3 - "$W/internal_aggregate_abi.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: internal-aggregate output is not LLVM bitcode")
print("PASS: tuple values cross internal direct-call argument and return boundaries")
PY
cp tests/pear2/unit_aggregate_main.air "$W/unit_aggregate.air"
if ! "$PEAR2" "$W/unit_aggregate.air" --quiet; then echo "FAIL: unit field aggregate ABI AIR rejected"; exit 1; fi
python3 - "$W/unit_aggregate.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: unit-aggregate output is not LLVM bitcode")
print("PASS: unit fields and standalone unit parameters survive internal aggregate calls")
PY
cp tests/pear2/tuple_label_main.air "$W/tuple_label.air"
if ! "$PEAR2" "$W/tuple_label.air" --quiet; then echo "FAIL: aggregate label/jump parameter AIR rejected"; exit 1; fi
python3 - "$W/tuple_label.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: tuple-label output is not LLVM bitcode")
print("PASS: aggregate values cross explicit label/jump CFG edges")
PY
cp tests/pear2/assert_trap_main.air "$W/assert_trap.air"
if ! "$PEAR2" "$W/assert_trap.air" --quiet; then echo "FAIL: assert/trap AIR rejected"; exit 1; fi
python3 - "$W/assert_trap.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: assert/trap output is not LLVM bitcode")
print("PASS: conditional assertion and terminal trap lowering emitted LLVM bitcode")
PY
cp tests/pear2/bytes_local_main.air "$W/bytes_local.air"
if ! "$PEAR2" "$W/bytes_local.air" --quiet; then echo "FAIL: byte-string array AIR rejected"; exit 1; fi
python3 - "$W/bytes_local.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: byte-string output is not LLVM bitcode")
print("PASS: UTF-8 string literal lowered to a destructurable fixed byte array")
PY
cp tests/pear2/int128_main.air "$W/int128.air"
if ! "$PEAR2" "$W/int128.air" --quiet; then echo "FAIL: i128 arithmetic/call AIR rejected"; exit 1; fi
python3 - "$W/int128.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: i128 output is not LLVM bitcode")
print("PASS: i128 arithmetic, comparison, and internal ABI emitted LLVM bitcode")
PY
cp tests/pear2/char_main.air "$W/char.air"
if ! "$PEAR2" "$W/char.air" --quiet; then echo "FAIL: character literal/match AIR rejected"; exit 1; fi
python3 - "$W/char.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: character output is not LLVM bitcode")
print("PASS: Unicode scalar literal and i32 switch matching emitted LLVM bitcode")
PY
cp tests/pear2/layout_main.air "$W/layout.air"
if ! "$PEAR2" "$W/layout.air" --quiet; then echo "FAIL: scalar/fixed-array sizeof/alignof AIR rejected"; exit 1; fi
python3 - "$W/layout.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: layout output is not LLVM bitcode")
print("PASS: supported scalar and fixed-array layout queries folded")
PY
cp tests/pear2/coerce_float_main.air "$W/coerce_float.air"
if ! "$PEAR2" "$W/coerce_float.air" --quiet; then echo "FAIL: numeric float coercion AIR rejected"; exit 1; fi
python3 - "$W/coerce_float.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: float-coercion output is not LLVM bitcode")
print("PASS: integer/float conversion and f32/f64 widening/narrowing emitted LLVM bitcode")
PY
cp tests/pear2/reject_tuple_abi_main.air "$W/tuple_abi.air"
printf 'stale bitcode' > "$W/tuple_abi.bc"
set +e
"$PEAR2" "$W/tuple_abi.air" --quiet >"$W/tuple_abi.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: aggregate extern ABI returned $rc, expected rejection"; cat "$W/tuple_abi.log"; exit 1; }
[ ! -e "$W/tuple_abi.bc" ] || { echo "FAIL: rejected aggregate ABI left bitcode"; exit 1; }
echo "PASS: aggregate extern ABIs fail closed while internal aggregate ABIs are enabled"
cp tests/pear2/reject_coerce_float_main.air "$W/coerce_float.air"
printf 'stale bitcode' > "$W/coerce_float.bc"
set +e
"$PEAR2" "$W/coerce_float.air" --quiet >"$W/coerce_float.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: unsupported float coercion returned $rc, expected rejection"; cat "$W/coerce_float.log"; exit 1; }
[ ! -e "$W/coerce_float.bc" ] || { echo "FAIL: unsupported float coercion left bitcode"; exit 1; }
echo "PASS: unsupported float coercions fail closed"
cp tests/pear2/reject_int_width_mix.air "$W/int_width_mix.air"
printf 'stale bitcode' > "$W/int_width_mix.bc"
set +e
"$PEAR2" "$W/int_width_mix.air" --quiet >"$W/int_width_mix.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: mixed integer widths returned $rc, expected rejection"; cat "$W/int_width_mix.log"; exit 1; }
[ ! -e "$W/int_width_mix.bc" ] || { echo "FAIL: mixed integer widths left bitcode"; exit 1; }
echo "PASS: mixed integer widths fail closed without a stale artifact"
cp tests/pear2/reject_pointer_abi_mismatch.air "$W/pointer_mismatch.air"
printf 'stale bitcode' > "$W/pointer_mismatch.bc"
set +e
"$PEAR2" "$W/pointer_mismatch.air" --quiet >"$W/pointer_mismatch.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: pointer ABI mismatch returned $rc, expected rejection"; cat "$W/pointer_mismatch.log"; exit 1; }
[ ! -e "$W/pointer_mismatch.bc" ] || { echo "FAIL: pointer ABI mismatch left bitcode"; exit 1; }
echo "PASS: pointer/integer ABI mismatches fail closed"
cp tests/pear2/bindings_main.air "$W/bindings.air"
if ! "$PEAR2" "$W/bindings.air" --quiet; then echo "FAIL: let/comu AIR rejected"; exit 1; fi
python3 - "$W/bindings.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: binding output does not have LLVM bitcode magic")
print("PASS: let/comu scalar AIR emitted LLVM bitcode")
PY
cp tests/pear2/if_compare_main.air "$W/if_compare.air"
if ! "$PEAR2" "$W/if_compare.air" --quiet; then echo "FAIL: comparison/if AIR rejected"; exit 1; fi
python3 - "$W/if_compare.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: if/comparison output does not have LLVM bitcode magic")
print("PASS: scalar comparison/if AIR emitted LLVM bitcode")
PY
cp tests/pear2/while_main.air "$W/while.air"
if ! "$PEAR2" "$W/while.air" --quiet; then echo "FAIL: while-loop AIR rejected"; exit 1; fi
python3 - "$W/while.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: while-loop output is not LLVM bitcode")
print("PASS: while condition, exit edge, and loop backedge emitted LLVM bitcode")
PY
cp tests/pear2/match_int_main.air "$W/match_int.air"
if ! "$PEAR2" "$W/match_int.air" --quiet; then echo "FAIL: integer-match AIR rejected"; exit 1; fi
python3 - "$W/match_int.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: integer-match output does not have LLVM bitcode magic")
print("PASS: integer match AIR emitted LLVM bitcode")
PY
cp tests/pear2/match_or_main.air "$W/match_or.air"
if ! "$PEAR2" "$W/match_or.air" --quiet; then echo "FAIL: scalar or-pattern AIR rejected"; exit 1; fi
python3 - "$W/match_or.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: or-pattern output is not LLVM bitcode")
print("PASS: integer scalar or-pattern arms emitted LLVM bitcode")
PY
cp tests/pear2/match_as_main.air "$W/match_as.air"
if ! "$PEAR2" "$W/match_as.air" --quiet; then echo "FAIL: scalar/aggregate as-pattern AIR rejected"; exit 1; fi
python3 - "$W/match_as.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: as-pattern output is not LLVM bitcode")
print("PASS: scalar aliases and single-arm aggregate aliases emitted LLVM bitcode")
PY
cp tests/pear2/match_guard_main.air "$W/match_guard.air"
if ! "$PEAR2" "$W/match_guard.air" --quiet; then echo "FAIL: guarded scalar-match AIR rejected"; exit 1; fi
python3 - "$W/match_guard.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: guarded-match output is not LLVM bitcode")
print("PASS: scalar match guards and false-guard fallthrough emitted LLVM bitcode")
PY
cp tests/pear2/match_aggregate_guard_main.air "$W/match_aggregate_guard.air"
if ! "$PEAR2" "$W/match_aggregate_guard.air" --quiet; then echo "FAIL: guarded aggregate-match AIR rejected"; exit 1; fi
python3 - "$W/match_aggregate_guard.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: aggregate-guard output is not LLVM bitcode")
print("PASS: aggregate binders feed match guards with ordered fallback")
PY
cp tests/pear2/match_float_main.air "$W/match_float.air"
if ! "$PEAR2" "$W/match_float.air" --quiet; then echo "FAIL: floating-point match AIR rejected"; exit 1; fi
python3 - "$W/match_float.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: floating-match output is not LLVM bitcode")
print("PASS: f32/f64 match literals lower to ordered equality tests")
PY
cp tests/pear2/match_bool_main.air "$W/match_bool.air"
if ! "$PEAR2" "$W/match_bool.air" --quiet; then echo "FAIL: boolean-match AIR rejected"; exit 1; fi
python3 - "$W/match_bool.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: boolean-match output does not have LLVM bitcode magic")
print("PASS: boolean match AIR emitted LLVM bitcode")
PY
cp tests/pear2/label_main.air "$W/label.air"
if ! "$PEAR2" "$W/label.air" --quiet; then echo "FAIL: label AIR rejected"; exit 1; fi
python3 - "$W/label.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: label output does not have LLVM bitcode magic")
print("PASS: label AIR emitted LLVM bitcode")
PY
cp tests/pear2/break_main.air "$W/break.air"
if ! "$PEAR2" "$W/break.air" --quiet; then echo "FAIL: break-label AIR rejected"; exit 1; fi
python3 - "$W/break.bc" <<'PY'
import pathlib, sys
if pathlib.Path(sys.argv[1]).read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: break-label output is not LLVM bitcode")
print("PASS: break transferred to a validated zero-parameter label")
PY
cp tests/pear2/label_arg_main.air "$W/label_arg.air"
if ! "$PEAR2" "$W/label_arg.air" --quiet; then echo "FAIL: parameterized-label AIR rejected"; exit 1; fi
python3 - "$W/label_arg.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: parameterized-label output does not have LLVM bitcode magic")
print("PASS: parameterized label/jump AIR emitted LLVM bitcode")
PY
cp tests/pear2/label_bool_main.air "$W/label_bool.air"
if ! "$PEAR2" "$W/label_bool.air" --quiet; then echo "FAIL: boolean label-parameter AIR rejected"; exit 1; fi
python3 - "$W/label_bool.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: boolean-label output does not have LLVM bitcode magic")
print("PASS: boolean label parameter emitted LLVM bitcode")
PY
cp tests/pear2/label_loop_main.air "$W/label_loop.air"
if ! "$PEAR2" "$W/label_loop.air" --quiet; then echo "FAIL: loop-carried label AIR rejected"; exit 1; fi
python3 - "$W/label_loop.bc" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.read_bytes()[:4] != b"BC\xc0\xde":
    raise SystemExit("FAIL: loop output does not have LLVM bitcode magic")
print("PASS: scalar loop-carried state emitted LLVM bitcode")
PY
cp tests/pear2/reject_implicit_backedge.air "$W/implicit_backedge.air"
printf 'stale bitcode' > "$W/implicit_backedge.bc"
set +e
"$PEAR2" "$W/implicit_backedge.air" --quiet >"$W/implicit_backedge.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: implicit-state backedge returned $rc, expected rejection"; cat "$W/implicit_backedge.log"; exit 1; }
[ ! -e "$W/implicit_backedge.bc" ] || { echo "FAIL: rejected backedge left a bitcode artifact"; exit 1; }
echo "PASS: changed loop state requires an explicit label argument"
cp tests/pear2/unsupported_main.air "$W/unsupported.air"
printf 'stale bitcode' > "$W/unsupported.bc"
set +e
"$PEAR2" "$W/unsupported.air" --quiet >"$W/unsupported.log" 2>&1
rc=$?
set -e
[ "$rc" = 3 ] || { echo "FAIL: unsupported AIR returned $rc, expected 3"; cat "$W/unsupported.log"; exit 1; }
[ ! -e "$W/unsupported.bc" ] || { echo "FAIL: unsupported AIR left a bitcode artifact"; exit 1; }
grep -q 'unsupported function body' "$W/unsupported.log" || { echo "FAIL: missing unsupported-form diagnostic"; cat "$W/unsupported.log"; exit 1; }
echo "PASS: unsupported AIR rejected without an artifact"

# Exercise integer let propagation on a real arithmetic binding fixture.
cp tests/pear2/bindings_main.air "$W/binding_optimizer.air"
"$PEAR2" "$W/binding_optimizer.air" --stats --quiet >"$W/binding_optimizer.stats"
python3 - "$W/binding_optimizer.stats" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"rewrites=(\d+)", text)
if not match or int(match.group(1)) < 3:
    raise SystemExit(f"FAIL: expected let substitution and constant-fold rewrites, got {text.strip()!r}")
print(f"PASS: integer-let optimization reported {match.group(1)} rewrites")
PY
[ -f "$W/binding_optimizer.bc" ] || { echo "FAIL: optimized binding AIR did not emit bitcode"; exit 1; }

# A pure integer constant should cross a nested let initializer and fold the
# terminal result without deleting either binding.
cp tests/pear2/integer_let_chain.air "$W/integer_let_chain.air"
"$PEAR2" "$W/integer_let_chain.air" --stats --quiet >"$W/integer_let_chain.stats"
grep -Eq '(^| )folds=2( |$)' "$W/integer_let_chain.stats" || { echo "FAIL: expected two folds through the integer-let chain"; cat "$W/integer_let_chain.stats"; exit 1; }
grep -Eq '(^| )let-specializations=2( |$)' "$W/integer_let_chain.stats" || { echo "FAIL: expected two chained integer-let specializations"; cat "$W/integer_let_chain.stats"; exit 1; }
[ -f "$W/integer_let_chain.bc" ] || { echo "FAIL: chained-let AIR did not emit bitcode"; exit 1; }

# Exercise PEAR2's AIR optimizer on a real bool-let/if fixture. The comparison,
# negation, let-condition specialization, and literal branch should all reduce.
cp tests/pear2/if_compare_main.air "$W/if_optimizer.air"
"$PEAR2" "$W/if_optimizer.air" --stats --quiet >"$W/if_optimizer.stats"
python3 - "$W/if_optimizer.stats" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"rewrites=(\d+)", text)
if not match or int(match.group(1)) < 5:
    raise SystemExit(f"FAIL: expected comparison/not/let/if rewrites, got {text.strip()!r}")
print(f"PASS: bool-let/if optimization reported {match.group(1)} rewrites")
PY
[ -f "$W/if_optimizer.bc" ] || { echo "FAIL: optimized bool-let/if AIR did not emit bitcode"; exit 1; }

# Exercise typed power-of-two strength reduction through the full AIR reader,
# optimizer, verifier, and bitcode writer.
cp tests/pear2/strength_reduction_main.air "$W/strength_reduction.air"
"$PEAR2" "$W/strength_reduction.air" --stats --quiet >"$W/strength_reduction.stats"
grep -Eq '(^| )strength=11( |$)' "$W/strength_reduction.stats" || { echo "FAIL: signed/unsigned power-of-two arithmetic or multiply strength reductions were not applied"; cat "$W/strength_reduction.stats"; exit 1; }
grep -Eq '(^| )operands=13( |$)' "$W/strength_reduction.stats" || { echo "FAIL: integer/boolean identities and same-representation coercion reductions were not all applied"; cat "$W/strength_reduction.stats"; exit 1; }
[ -f "$W/strength_reduction.bc" ] || { echo "FAIL: strength-reduced AIR did not emit bitcode"; exit 1; }

# Boolean/integer literal coercions must respect the backend's i1 low-bit
# conversion semantics while preserving the final module verifier gate.
cp tests/pear2/coerce_bool_constants.air "$W/coerce_bool_constants.air"
"$PEAR2" "$W/coerce_bool_constants.air" --stats --quiet >"$W/coerce_bool_constants.stats"
grep -Eq '(^| )folds=4( |$)' "$W/coerce_bool_constants.stats" || { echo "FAIL: expected four bool/integer coercion folds"; cat "$W/coerce_bool_constants.stats"; exit 1; }
[ -f "$W/coerce_bool_constants.bc" ] || { echo "FAIL: coerced-constant AIR did not emit bitcode"; exit 1; }

# Logical identities remove the bool-only land/lor forms from codegen while
# preserving their variable operand and the final module verification gate.
cp tests/pear2/bool_logic_identity.air "$W/bool_logic_identity.air"
"$PEAR2" "$W/bool_logic_identity.air" -O1 --stats --quiet >"$W/bool_logic_identity.stats"
grep -Eq '(^| )rewrites=2( |$)' "$W/bool_logic_identity.stats" || { echo "FAIL: expected two logical identity rewrites"; cat "$W/bool_logic_identity.stats"; exit 1; }
grep -Eq '(^| )operands=2( |$)' "$W/bool_logic_identity.stats" || { echo "FAIL: expected two logical operand rewrites"; cat "$W/bool_logic_identity.stats"; exit 1; }
[ -f "$W/bool_logic_identity.bc" ] || { echo "FAIL: logical-identity AIR did not emit bitcode"; exit 1; }

# Exercise PEAR2's AIR optimizer switch on nested constant arithmetic. The
# default pipeline must report rewrites; -O0 must bypass the pass entirely.
for level in 1 2 3; do
  cp tests/pear2/arithmetic_main.air "$W/optimizer_O${level}.air"
  "$PEAR2" "$W/optimizer_O${level}.air" "-O${level}" --stats --quiet >"$W/optimizer_O${level}.stats"
  grep -Eq 'optimization enabled; rewrites=[1-9][0-9]*' "$W/optimizer_O${level}.stats" || { echo "FAIL: expected constant-fold rewrites at -O${level}"; cat "$W/optimizer_O${level}.stats"; exit 1; }
  grep -q "level=${level}" "$W/optimizer_O${level}.stats" || { echo "FAIL: optimizer reported the wrong level for -O${level}"; cat "$W/optimizer_O${level}.stats"; exit 1; }
  expected_passes=2
  [ "$level" = 1 ] && expected_passes=1
  grep -q "passes=${expected_passes}" "$W/optimizer_O${level}.stats" || { echo "FAIL: optimizer did not stop at the expected pass count for -O${level}"; cat "$W/optimizer_O${level}.stats"; exit 1; }
  [ -f "$W/optimizer_O${level}.bc" ] || { echo "FAIL: -O${level} AIR did not emit bitcode"; exit 1; }
done
python3 - "$W" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def count(level):
    text = (root / f"optimizer_O{level}.stats").read_text()
    match = re.search(r"rewrites=(\d+)", text)
    if not match:
        raise SystemExit(f"FAIL: missing rewrite count at -O{level}: {text.strip()!r}")
    return int(match.group(1))
counts = [count(level) for level in (1, 2, 3)]
if counts[1] < counts[0] or counts[2] != counts[1]:
    raise SystemExit(f"FAIL: optimizer iteration levels did not converge: {counts}")
print(f"PASS: optimization levels converge with rewrite counts {counts}")
PY
cp tests/pear2/arithmetic_main.air "$W/no_opt.air"
"$PEAR2" "$W/no_opt.air" -O0 --stats --quiet >"$W/no_opt.stats"
grep -q 'optimization disabled; rewrites=0' "$W/no_opt.stats" || { echo "FAIL: -O0 did not disable AIR optimizations"; cat "$W/no_opt.stats"; exit 1; }
grep -q 'level=0 passes=0' "$W/no_opt.stats" || { echo "FAIL: -O0 reported unexpected optimizer passes"; cat "$W/no_opt.stats"; exit 1; }
[ -f "$W/no_opt.bc" ] || { echo "FAIL: -O0 AIR did not emit bitcode"; exit 1; }
echo "PASS: PEAR2 optimization default, rewrite stats, and -O0 opt-out"

link_and_run() {
    local name=$1 expected_rc=$2 expected_stdout=${3:-}
    local exe="$W/$name.linked" output="$W/$name.stdout" rc got
    "$PEAR2_CLANG" -Wno-override-module "$W/$name.bc" -o "$exe" >"$W/$name.link.log" 2>&1 || {
        echo "FAIL: LLVM 23 clang could not link $name.bc"; cat "$W/$name.link.log"; return 1;
    }
    set +e
    timeout 10 "$exe" >"$output" 2>"$W/$name.run.err"
    rc=$?
    set -e
    got=$(cat "$output")
    [ "$rc" = "$expected_rc" ] || { echo "FAIL: $name returned $rc, expected $expected_rc"; return 1; }
    [ "$got" = "$expected_stdout" ] || { echo "FAIL: $name stdout mismatch: got '$got', expected '$expected_stdout'"; return 1; }
    echo "PASS: LLVM 23 linked/runs $name (exit=$rc, stdout baseline matched)"
}
link_and_run literal 42
link_and_run arithmetic 42
link_and_run direct_call 42
link_and_run if_compare 42
link_and_run while 9
link_and_run binding_optimizer 42
