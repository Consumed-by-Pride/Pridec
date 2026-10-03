#!/usr/bin/env python3
"""Reference .ll -> executable driver (LLVM-23 via ctypes + the system linker). No clang/llc needed.

  python3 scripts/ll-exe.py in.ll -o out [-O0..-O3] [--emit-obj] [--triple wasm32-unknown-unknown]
            [--cpu C] [--features F] [--reloc static|pic] [--code-model kernel|small|large] [--ld-script FILE (bare metal)]
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
want_triple = args[args.index("--triple") + 1].encode() if "--triple" in args else None
if want_triple is None:   # `emit-ll --target=T` wrote `target triple = "T"` into the module: honour it
    import re
    _m = re.search(rb'^target triple = "([^"]+)"', open(src, "rb").read(), re.M)
    if _m: want_triple = _m.group(1)
for t in ("X86", "WebAssembly", "AArch64", "RISCV", "ARM"):
    for s in ("TargetInfo", "Target", "TargetMC", "AsmPrinter", "AsmParser"):
        try: getattr(L, f"LLVMInitialize{t}{s}")()
        except AttributeError: pass
triple = want_triple or ctypes.cast(L.LLVMGetDefaultTargetTriple(), cp).value
tgt = vp(); err = cp()
L.LLVMGetTargetFromTriple.argtypes = [cp, ctypes.POINTER(vp), ctypes.POINTER(cp)]
if L.LLVMGetTargetFromTriple(triple, ctypes.byref(tgt), ctypes.byref(err)):
    sys.exit("ll-exe: no target: " + (err.value or b"?").decode())
lvl = {"-O0": 0, "-O1": 1, "-O2": 2, "-O3": 3}[opt]
L.LLVMCreateTargetMachine.restype = vp
L.LLVMCreateTargetMachine.argtypes = [vp, cp, cp, cp, ctypes.c_int, ctypes.c_int, ctypes.c_int]
if want_triple and want_triple.startswith(b"wasm"):
    # wasm32: see runtime/wasi/pride_rt.c -- every external F becomes pride_rt_F (Pride-declared signatures), main becomes pride_rt_main
    L.LLVMGetFirstFunction.restype = vp; L.LLVMGetFirstFunction.argtypes = [vp]
    L.LLVMGetNextFunction.restype = vp; L.LLVMGetNextFunction.argtypes = [vp]
    L.LLVMIsDeclaration.argtypes = [vp]
    L.LLVMGetValueName2.restype = cp; L.LLVMGetValueName2.argtypes = [vp, ctypes.POINTER(ctypes.c_size_t)]
    L.LLVMSetValueName2.argtypes = [vp, cp, ctypes.c_size_t]
    _fs = []; _f = L.LLVMGetFirstFunction(mod)
    while _f: _fs.append(_f); _f = L.LLVMGetNextFunction(_f)
    for _f in _fs:
        _n = ctypes.c_size_t(); _nm = L.LLVMGetValueName2(_f, ctypes.byref(_n)); _nm = ctypes.string_at(_nm, _n.value)
        if _nm == b"main": _new = b"pride_rt_main"
        elif L.LLVMIsDeclaration(_f) and not _nm.startswith(b"llvm."): _new = b"pride_rt_" + _nm
        else: continue
        L.LLVMSetValueName2(_f, _new, len(_new))
def opt_of(flag, default=None):
    return args[args.index(flag) + 1] if flag in args else default
cpu = opt_of("--cpu", "generic").encode(); feats = opt_of("--features", "").encode()   # e.g. --features=-sse,-sse2,+soft-float for kernel code
reloc = {"default": 0, "static": 1, "pic": 2}[opt_of("--reloc", "pic")]
cmodel = {"default": 0, "tiny": 2, "small": 3, "kernel": 4, "medium": 5, "large": 6}[opt_of("--code-model", "default")]
tm = L.LLVMCreateTargetMachine(tgt, triple, cpu, feats, lvl, reloc, cmodel)
if want_triple:   # cross target: the module takes the target's triple and data layout; the result is always an object file
    L.LLVMSetTarget.argtypes = [vp, cp]; L.LLVMSetTarget(mod, triple)
    L.LLVMCreateTargetDataLayout.restype = vp; L.LLVMCreateTargetDataLayout.argtypes = [vp]
    L.LLVMSetModuleDataLayout.argtypes = [vp, vp]; L.LLVMSetModuleDataLayout(mod, L.LLVMCreateTargetDataLayout(tm))
    if "--emit-obj" not in args and "--ld-script" not in args: args.append("--emit-obj")
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
if "--ld-script" in args:   # bare metal: no libc, no crt, no OS -- the linker script places the sections and names the entry
    r = subprocess.run(["ld", "-nostdlib", "-static", "-T", opt_of("--ld-script"), obj, "-o", out], capture_output=True, text=True)
    os.unlink(obj)
    if r.returncode: sys.exit("ll-exe: link: " + r.stderr)
    sys.exit(0)
link = ["gcc", obj, "-o", out, "-no-pie"]
if "--freestanding" in args: link += ["-nostdlib", "-static", "-Wl,-e,_start"]   # no libc, no crt: the program's own `_start` is the entry
r = subprocess.run(link, capture_output=True, text=True,
                   env=dict(os.environ, LD_LIBRARY_PATH=""))
os.unlink(obj)
if r.returncode: sys.exit("ll-exe: link: " + r.stderr)
