#!/usr/bin/env python3
"""Reference .ll -> executable driver (LLVM-23 via ctypes + the system linker). No clang/llc needed.

  python3 scripts/ll-exe.py in.ll -o out [-O0..-O3] [--emit-obj]
Parses the .ll, runs the LLVM verifier, optionally the default<On> pipeline, writes an object file
and links it with gcc (libc provides malloc/free/write/_start). Exit 0 = built; 1 = parse/verify/link error
(message on stderr). Used as the oracle for AIR 3.0 (docs/specs/AIR3.md): if a program built from
`.air` through this path runs correctly, the `.air` carried everything a backend needs.
"""
import ctypes, os, subprocess, sys
args = sys.argv[1:]
src = args[0]; out = args[args.index("-o") + 1] if "-o" in args else "a.out"
opt = next((a for a in args if a in ("-O0", "-O1", "-O2", "-O3")), "-O0")
L = ctypes.CDLL("libLLVM-23.so")
vp = ctypes.c_void_p; cp = ctypes.c_char_p
for f in ("LLVMContextCreate", "LLVMGetDefaultTargetTriple", "LLVMCreateMessage"):
    getattr(L, f).restype = vp if f != "LLVMGetDefaultTargetTriple" else cp
L.LLVMGetDefaultTargetTriple.restype = ctypes.c_void_p
ctx = L.LLVMContextCreate()
buf = vp(); msg = cp()
L.LLVMCreateMemoryBufferWithContentsOfFile.argtypes = [cp, ctypes.POINTER(vp), ctypes.POINTER(cp)]
if L.LLVMCreateMemoryBufferWithContentsOfFile(src.encode(), ctypes.byref(buf), ctypes.byref(msg)):
    sys.exit("ll-exe: cannot read " + src)
mod = vp()
L.LLVMParseIRInContext.argtypes = [vp, vp, ctypes.POINTER(vp), ctypes.POINTER(cp)]
if L.LLVMParseIRInContext(ctx, buf, ctypes.byref(mod), ctypes.byref(msg)):
    sys.exit("ll-exe: parse error: " + (msg.value or b"?").decode())
L.LLVMVerifyModule.argtypes = [vp, ctypes.c_int, ctypes.POINTER(cp)]
vmsg = cp()
if L.LLVMVerifyModule(mod, 1, ctypes.byref(vmsg)):
    sys.exit("ll-exe: verifier: " + (vmsg.value or b"?").decode())
for t in ("X86",):
    for s in ("TargetInfo", "Target", "TargetMC", "AsmPrinter", "AsmParser"):
        getattr(L, f"LLVMInitialize{t}{s}")()
triple = ctypes.cast(L.LLVMGetDefaultTargetTriple(), cp).value
tgt = vp(); err = cp()
L.LLVMGetTargetFromTriple.argtypes = [cp, ctypes.POINTER(vp), ctypes.POINTER(cp)]
if L.LLVMGetTargetFromTriple(triple, ctypes.byref(tgt), ctypes.byref(err)):
    sys.exit("ll-exe: no target: " + (err.value or b"?").decode())
lvl = {"-O0": 0, "-O1": 1, "-O2": 2, "-O3": 3}[opt]
L.LLVMCreateTargetMachine.restype = vp
L.LLVMCreateTargetMachine.argtypes = [vp, cp, cp, cp, ctypes.c_int, ctypes.c_int, ctypes.c_int]
tm = L.LLVMCreateTargetMachine(tgt, triple, b"generic", b"", lvl, 2, 0)   # reloc PIC=2, code model default=0
if lvl > 0:
    L.LLVMRunPasses.argtypes = [vp, cp, vp, vp]
    L.LLVMCreatePassBuilderOptions.restype = vp
    po = L.LLVMCreatePassBuilderOptions()
    e = L.LLVMRunPasses(mod, f"default<O{lvl}>".encode(), tm, po)
    if e: sys.exit("ll-exe: pass pipeline failed")
obj = out + ".o"
L.LLVMTargetMachineEmitToFile.argtypes = [vp, vp, cp, ctypes.c_int, ctypes.POINTER(cp)]
if L.LLVMTargetMachineEmitToFile(tm, mod, obj.encode(), 1, ctypes.byref(err)):
    sys.exit("ll-exe: codegen: " + (err.value or b"?").decode())
if "--emit-obj" in args: sys.exit(0)
r = subprocess.run(["gcc", obj, "-o", out, "-no-pie"], capture_output=True, text=True,
                   env=dict(os.environ, LD_LIBRARY_PATH=""))
os.unlink(obj)
if r.returncode: sys.exit("ll-exe: link: " + r.stderr)
