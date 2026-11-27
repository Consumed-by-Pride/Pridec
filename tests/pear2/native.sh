#!/bin/bash
# PEAR 2 native-backend end-to-end tests.
#
# This is deliberately the one test script that does not touch LLVM at all: no
# libLLVM, no opt, no clang, no textual IR. It compiles .air to an ELF object with
# pear2c's own backend, links it with `ld`, runs the result, and checks the exit
# status. If any part of the pipeline had leaked into LLVM the script would fail
# on a machine without LLVM installed, which is exactly the property being tested.
#
# Usage: tests/pear2/native.sh [path-to-pear2c]
set -uo pipefail
cd "$(dirname "$0")/../.."
PEAR2_BIN="${1:-./pear2c}"

if [ ! -x "$PEAR2_BIN" ]; then
    echo "SKIP: pear2c not found at $PEAR2_BIN"
    exit 0
fi
LD_BIN="${LD:-$(command -v ld || true)}"
if [ -z "$LD_BIN" ]; then
    echo "SKIP: no linker (ld) available; the object files can still be produced with --emit-native"
    exit 0
fi
if ! "$LD_BIN" --version 2>/dev/null | grep -q 'GNU ld\|LLD'; then
    echo "SKIP: $LD_BIN is not a linker this test can drive"
    exit 0
fi

W=tmp/pear2-native
rm -rf "$W"
mkdir -p "$W"
pass=0
fail=0

# expect_exit NAME AIR EXPECTED
#
# Compiles, links, runs, and compares the process status. The status is masked to
# one byte because that is what the kernel reports: `_start` passes main's i64
# through an i32 move, so 42 stays 42 and a negative result becomes its low byte.
expect_exit() {
    local name=$1 air=$2 want=$3
    local obj="$W/$name.o" exe="$W/$name"
    if ! "$PEAR2_BIN" "$air" --emit-native --native-entry --quiet 2>"$W/$name.err"; then
        echo "FAIL $name: --emit-native rejected the module"
        sed 's/^/    /' "$W/$name.err"
        fail=$((fail + 1))
        return
    fi
    if [ ! -s "$obj" ]; then
        echo "FAIL $name: no object was produced"
        fail=$((fail + 1))
        return
    fi
    # A relocatable object, not a partial file: check the ELF magic and type.
    if [ "$(head -c 4 "$obj" | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
        echo "FAIL $name: output is not an ELF file"
        fail=$((fail + 1))
        return
    fi
    if ! "$LD_BIN" -static -o "$exe" "$obj" 2>"$W/$name.ld"; then
        echo "FAIL $name: ld could not link the native object"
        sed 's/^/    /' "$W/$name.ld"
        fail=$((fail + 1))
        return
    fi
    "$exe"
    local got=$?
    if [ "$got" -ne "$want" ]; then
        echo "FAIL $name: exit status $got, expected $want"
        fail=$((fail + 1))
        return
    fi
    echo "ok   $name (exit $got)"
    pass=$((pass + 1))
}

# A module the LLVM path already covers: the same .air, the same expected value,
# two different backends.
cp tests/pear2/arithmetic_main.air "$W/arith.air"
expect_exit arith "$W/arith.air" 42

# A direct call across functions: exercises argument marshalling, the call
# relocation and the result binding.
cp tests/pear2/native_call.air "$W/call.air"
expect_exit call "$W/call.air" 42

# Comparison and if: the branch, the join, and a comparison feeding it.
cp tests/pear2/if_compare_main.air "$W/if.air"
expect_exit ifcompare "$W/if.air" 42

# Integer match: a compare-and-branch chain with a catch-all last arm.
cp tests/pear2/match_int_main.air "$W/match.air"
expect_exit matchint "$W/match.air" 42

# The object alone must be reproducible: compiling the same input twice produces
# byte-identical output. Nondeterminism here would mean an address or a name
# escaped into the file.
"$PEAR2_BIN" "$W/arith.air" --emit-native --native-entry --quiet
cp "${W}/arith.o" "$W/arith.first.o"
"$PEAR2_BIN" "$W/arith.air" --emit-native --native-entry --quiet
if cmp -s "$W/arith.first.o" "${W}/arith.o"; then
    echo "ok   deterministic (two compiles, identical bytes)"
    pass=$((pass + 1))
else
    echo "FAIL deterministic: the object differs between two compiles"
    fail=$((fail + 1))
fi

echo "native: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
