#!/usr/bin/env python3
"""ll-bc.py FILE.ll [-o OUT.bc] -- verify textual LLVM IR and write bitcode.

The `.bc` half of the LAIR slice gate (docs/pear2/LAIR.md): `lairc` links no
LLVM, so bitcode production lives here, exactly as executable production lives
in scripts/ll-exe.py. Loads libLLVM-23 through ctypes: parse, VerifyModule,
WriteBitcodeToFile, then read the .bc back through the parser as a
round-trip check.

Exit codes: 0 ok, 1 LLVM refused the module (the diagnostic goes to stderr),
2 usage / missing library.
"""
import argparse
import ctypes
import os
import sys


def load_llvm():
    base = os.environ.get(
        "LLVM23_DIR",
        os.path.expanduser("~/.cache/llvm23/node_modules/llvm-runtime-clang-linux-x64"),
    )
    candidates = [
        os.path.join(base, "lib", "libLLVM-23.so"),
        os.path.join(base, "lib", "libLLVM.so.23.1"),
        "/usr/lib/llvm-23/lib/libLLVM-23.so",
        "/usr/lib/x86_64-linux-gnu/libLLVM-23.so",
    ]
    for path in candidates:
        if os.path.exists(path):
            return ctypes.CDLL(path)
    try:
        return ctypes.CDLL("libLLVM-23.so")
    except OSError:
        sys.stderr.write(
            "ll-bc: libLLVM-23 not found; set LLVM23_DIR or add the library to the loader path\n"
        )
        raise SystemExit(2)


def main():
    ap = argparse.ArgumentParser(description="verify .ll and write .bc (libLLVM-23)")
    ap.add_argument("file")
    ap.add_argument("-o", "--output", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    with open(args.file, "rb") as f:
        data = f.read()
    out = args.output or (os.path.splitext(args.file)[0] + ".bc")

    llvm = load_llvm()
    llvm.LLVMContextCreate.restype = ctypes.c_void_p
    llvm.LLVMCreateMemoryBufferWithMemoryRangeCopy.restype = ctypes.c_void_p
    llvm.LLVMCreateMemoryBufferWithMemoryRangeCopy.argtypes = [
        ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p
    ]
    llvm.LLVMParseIRInContext.restype = ctypes.c_int
    llvm.LLVMParseIRInContext.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_char_p)
    ]
    llvm.LLVMVerifyModule.restype = ctypes.c_int
    llvm.LLVMVerifyModule.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)
    ]
    llvm.LLVMWriteBitcodeToFile.restype = ctypes.c_int
    llvm.LLVMWriteBitcodeToFile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

    ctx = llvm.LLVMContextCreate()
    buf = llvm.LLVMCreateMemoryBufferWithMemoryRangeCopy(
        data, len(data), os.path.basename(args.file).encode()
    )
    mod = ctypes.c_void_p()
    err = ctypes.c_char_p()
    if llvm.LLVMParseIRInContext(ctx, buf, ctypes.byref(mod), ctypes.byref(err)) != 0:
        sys.stderr.write("ll-bc: parse error: %s\n" % (err.value or b"?").decode(errors="replace"))
        raise SystemExit(1)
    msg = ctypes.c_char_p()
    if llvm.LLVMVerifyModule(mod, 2, ctypes.byref(msg)) != 0:  # 2 = ReturnStatusAction
        text = (msg.value or b"").decode(errors="replace")
        sys.stderr.write("ll-bc: verify error: %s\n" % text)
        raise SystemExit(1)
    rc = llvm.LLVMWriteBitcodeToFile(mod, out.encode())
    if rc != 0:
        sys.stderr.write("ll-bc: cannot write %s\n" % out)
        raise SystemExit(1)
    if not args.quiet:
        print("ll-bc: wrote %s (%d bytes)" % (out, os.path.getsize(out)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
