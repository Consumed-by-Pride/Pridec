#!/usr/bin/env bash
# Rebuild the tested PEAR2 toolchain in $HOME/.cache (large downloads stay out of Git).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE_ROOT=${PEAR2_CACHE_ROOT:-"$HOME/.cache"}
TOOLS="$CACHE_ROOT/pear2-tools"
LLVM_ROOT="$CACHE_ROOT/llvm23"
LLVM_PROJECT="$CACHE_ROOT/llvm-project-23.1.2"
LLVM_BUILD="$CACHE_ROOT/llvm23-cmake"
LLVM_CONFIG_DIR="$CACHE_ROOT/llvm23-config"
LLD_SHIM="$CACHE_ROOT/llvm23-lldshim"
C3_SRC="$CACHE_ROOT/c3src/src"
C3_BUILD="$CACHE_ROOT/c3src/build-llvm23-clang"
ARCHIVE_DIR="$CACHE_ROOT/src"
LLVM_TARBALL="$ARCHIVE_DIR/llvm-project-23.1.2.tar.gz"
C3_TARBALL="$ARCHIVE_DIR/c3c-v0.8.4.tar.gz"
CLANG_ROOT="$LLVM_ROOT/node_modules/llvm-runtime-clang-linux-x64"
CLANG_BIN="$CLANG_ROOT/bin"
LLVM_LIB="$CLANG_ROOT/lib"
JOBS=${JOBS:-4}

mkdir -p "$ARCHIVE_DIR" "$LLVM_ROOT" "$LLVM_PROJECT" "$TOOLS"

# CMake/Ninja are only build tools; LLVM binaries and target runtimes are pinned
# by the npm package version below.
if [ ! -x "$TOOLS/bin/cmake" ] || [ ! -x "$TOOLS/bin/ninja" ]; then
    python3 -m venv "$TOOLS"
    "$TOOLS/bin/pip" install 'cmake==4.4.4' 'ninja==1.13.2'
fi

npm install --prefix "$LLVM_ROOT" --ignore-scripts --no-audit --no-fund llvm-runtime@23.1.3
if [ ! -s "$LLVM_TARBALL" ]; then
    curl -fL --retry 3 https://codeload.github.com/llvm/llvm-project/tar.gz/refs/tags/llvmorg-23.1.2 -o "$LLVM_TARBALL"
fi
if [ ! -s "$C3_TARBALL" ]; then
    curl -fL --retry 3 https://codeload.github.com/c3lang/c3c/tar.gz/refs/tags/v0.8.4 -o "$C3_TARBALL"
fi

# LLVM's public headers are source-controlled, while generated Config/TableGen
# headers are produced by the two small LLVM header-generation targets below.
if [ ! -f "$LLVM_PROJECT/llvm/CMakeLists.txt" ]; then
    mkdir -p "$LLVM_PROJECT/llvm"
    tar -xzf "$LLVM_TARBALL" -C "$LLVM_PROJECT/llvm" --strip-components=2 llvm-project-llvmorg-23.1.2/llvm
    tar -xzf "$LLVM_TARBALL" -C "$LLVM_PROJECT" --strip-components=1 \
        llvm-project-llvmorg-23.1.2/cmake \
        llvm-project-llvmorg-23.1.2/libc \
        llvm-project-llvmorg-23.1.2/third-party
    mkdir -p "$LLVM_PROJECT/llvm/lld/include"
    tar -xzf "$LLVM_TARBALL" -C "$LLVM_PROJECT/llvm/lld/include" --strip-components=3 \
        llvm-project-llvmorg-23.1.2/lld/include
fi
if [ ! -f "$C3_SRC/CMakeLists.txt" ]; then
    mkdir -p "$C3_SRC"
    tar -xzf "$C3_TARBALL" -C "$C3_SRC" --strip-components=1
fi

export PATH="$TOOLS/bin:$CLANG_BIN:$LLVM_ROOT/node_modules/llvm-runtime-lld-linux-x64/bin:$PATH"
export LD_LIBRARY_PATH="$LLVM_LIB:$LLD_SHIM${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# LLVM 23.1.3 npm binaries provide libLLVM and clang; use matching 23.1.2
# source headers for C3's CMake package (this exact header/runtime split was
# tested). PEAR2 itself links the 23.1.3 C API library.
ln -sfn libLLVM.so.23.1 "$LLVM_LIB/libLLVM.so"
ln -sfn libLLVM.so.23.1 "$LLVM_LIB/libLLVM-23.so"
cmake -S "$LLVM_PROJECT/llvm" -B "$LLVM_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CLANG_BIN/clang" \
    -DCMAKE_CXX_COMPILER="$CLANG_BIN/clang++" \
    -DLLVM_ENABLE_PROJECTS='' -DLLVM_TARGETS_TO_BUILD=all \
    -DLLVM_ENABLE_RTTI=ON -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON
cmake --build "$LLVM_BUILD" --target llvm-headers --parallel "$JOBS"
cmake --build "$LLVM_BUILD" --target llvm-tblgen --parallel "$JOBS"
(
    cd "$LLVM_BUILD/include/llvm/Analysis"
    "$LLVM_BUILD/bin/llvm-min-tblgen" -gen-target-library-info \
        -I"$LLVM_PROJECT/llvm/include/llvm/Analysis" \
        -I"$LLVM_BUILD/include" -I"$LLVM_PROJECT/llvm/include" \
        "$LLVM_PROJECT/llvm/include/llvm/Analysis/TargetLibraryInfo.td" \
        --write-if-changed -o TargetLibraryInfo.inc
)

mkdir -p "$LLVM_CONFIG_DIR" "$LLD_SHIM"
cat > "$LLVM_CONFIG_DIR/LLVMConfig.cmake" <<EOF
set(LLVM_FOUND TRUE)
set(LLVM_PACKAGE_VERSION "23.1.2")
set(LLVM_VERSION_MAJOR 23)
set(LLVM_VERSION_MINOR 1)
set(LLVM_VERSION_PATCH 2)
set(LLVM_ENABLE_RTTI ON)
set(LLVM_INCLUDE_DIRS "$LLVM_PROJECT/llvm/include;$LLVM_BUILD/include")
set(LLVM_LIBRARY_DIRS "$LLVM_LIB")
set(LLVM_DEFINITIONS "")
EOF
cat > "$LLD_SHIM/lld_cli_shim.cpp" <<'CPP'
#include <llvm/ADT/ArrayRef.h>
#include <llvm/Support/raw_ostream.h>
#include <lld/Common/CommonLinkerContext.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cerrno>
#include <string>
#include <vector>

static bool run_lld(llvm::ArrayRef<const char *> args) {
    if (args.empty() || args.front() == nullptr) return false;
    std::vector<char *> argv;
    argv.reserve(args.size() + 1);
    for (const char *arg : args) argv.push_back(const_cast<char *>(arg));
    argv.push_back(nullptr);
    if (std::string(argv[0]) == "ld") argv[0] = const_cast<char *>("ld.lld");
    pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) { execvp(argv[0], argv.data()); _exit(errno == ENOENT ? 127 : 126); }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return false; }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
#define DECL_LINK(NS) \
namespace lld { namespace NS { \
bool link(llvm::ArrayRef<const char *> args, llvm::raw_ostream &, llvm::raw_ostream &, bool, bool) { return run_lld(args); } \
} }
DECL_LINK(elf)
DECL_LINK(wasm)
DECL_LINK(macho)
DECL_LINK(coff)
DECL_LINK(mingw)
namespace lld { void CommonLinkerContext::destroy() {} }
CPP
"$CLANG_BIN/clang++" -std=c++17 -fPIC -shared \
    -I"$LLVM_PROJECT/llvm/include" -I"$LLVM_BUILD/include" \
    -I"$LLVM_PROJECT/llvm/lld/include" -L"$LLVM_LIB" \
    -Wl,-rpath,"$LLVM_LIB" "$LLD_SHIM/lld_cli_shim.cpp" -lLLVM \
    -o "$LLD_SHIM/liblldshim.so"
for name in COFF Common ELF MachO MinGW Wasm; do
    ln -sfn "$LLD_SHIM/liblldshim.so" "$LLVM_LIB/liblld${name}.so"
done

cmake -S "$C3_SRC" -B "$C3_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CLANG_BIN/clang" \
    -DCMAKE_CXX_COMPILER="$CLANG_BIN/clang++" \
    -DC3_WITH_LLVM=ON -DC3_LINK_DYNAMIC=ON -DC3_FETCH_LLVM=OFF \
    -DC3_LLVM_VERSION=auto -DLLVM_DIR="$LLVM_CONFIG_DIR" \
    -DC3_LLD_DIR="$LLD_SHIM" \
    -DC3_LLD_INCLUDE_DIR="$LLVM_PROJECT/llvm/lld/include" \
    -DC3_AVR_DISABLE=ON \
    -DLLVM_CRT_LIBRARY_DIR="$LLVM_ROOT/node_modules/llvm-runtime-resources-linux/lib/x86_64-unknown-linux-gnu"
cmake --build "$C3_BUILD" --parallel "$JOBS"

export C3C="$C3_BUILD/c3c"
export C3C_LIB="$C3_SRC/lib"
export LLVM23_DIR="$CLANG_ROOT"
export LLVM23_LIBDIR="$LLVM_LIB"
export LLVM23_BIN="$CLANG_BIN"
export PEAR2_CLANG="$CLANG_BIN/clang"
cd "$ROOT"
make pear2c C3C="$C3C" C3C_LIB="$C3C_LIB" \
    LLVM23_DIR="$LLVM23_DIR" LLVM23_LIBDIR="$LLVM23_LIBDIR" \
    LLVM23_BIN="$LLVM23_BIN" PEAR2_CLANG="$PEAR2_CLANG"
make test-pear2-exec C3C="$C3C" C3C_LIB="$C3C_LIB" \
    LLVM23_DIR="$LLVM23_DIR" LLVM23_LIBDIR="$LLVM23_LIBDIR" \
    LLVM23_BIN="$LLVM23_BIN" PEAR2_CLANG="$PEAR2_CLANG"

cat <<EOF

Toolchain ready. C3 header version: 23.1.2; LLVM shared library/clang: 23.1.3.
For later shells, use:
  export C3C="$C3C" C3C_LIB="$C3C_LIB"
  export LLVM23_DIR="$LLVM23_DIR" LLVM23_LIBDIR="$LLVM23_LIBDIR"
  export LLVM23_BIN="$LLVM23_BIN" PEAR2_CLANG="$PEAR2_CLANG"
  export LD_LIBRARY_PATH="$LLVM_LIB:$LLD_SHIM:\$LD_LIBRARY_PATH"
  make test-pear2-exec
EOF
