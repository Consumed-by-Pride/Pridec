#!/usr/bin/env python3
"""Make a linked wasm32-wasi module (built with -DPRIDE_FIBERS, runtime/wasi/pride_fiber.c) able to switch stacks:
strip the DWARF custom sections binaryen cannot parse, then run binaryen's Asyncify with the scheduler excluded.
  python3 scripts/wasm-fibers.py in.wasm out.wasm        (wasm-opt: $WASM_OPT, ~/.cache/binaryen/*/bin/wasm-opt, or PATH)"""
import glob, os, shutil, subprocess, sys

def leb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return r, i

def strip_debug(data):
    out = bytearray(data[:8]); i = 8
    while i < len(data):
        sid = data[i]; size, j = leb(data, i + 1); end = j + size
        if sid == 0:
            nlen, k = leb(data, j); name = bytes(data[k:k + nlen])
            if name.startswith(b".debug") or name == b"producers":
                i = end; continue
        out += data[i:end]; i = end
    return bytes(out)

def find_wasm_opt():
    if os.environ.get("WASM_OPT"): return os.environ["WASM_OPT"]
    c = sorted(glob.glob(os.path.expanduser("~/.cache/binaryen/*/bin/wasm-opt")))
    return c[-1] if c else shutil.which("wasm-opt")

src, dst = sys.argv[1], sys.argv[2]
wo = find_wasm_opt()
if not wo: sys.exit("wasm-fibers: no wasm-opt (binaryen): scripts/get-binaryen.sh installs it under ~/.cache/binaryen")
tmp = dst + ".nodbg.wasm"
open(tmp, "wb").write(strip_debug(open(src, "rb").read()))
r = subprocess.run([wo, tmp, "--enable-sign-ext", "--enable-mutable-globals", "--enable-bulk-memory", "--enable-nontrapping-float-to-int", "--enable-multivalue",
                    "--asyncify", "--pass-arg=asyncify-removelist@pride_fiber_sched", "-o", dst], capture_output=True, text=True)
os.unlink(tmp)
if r.returncode: sys.exit("wasm-fibers: wasm-opt failed: " + (r.stdout + r.stderr)[:400])
if "non-existing" in r.stderr: sys.exit("wasm-fibers: " + r.stderr.strip()[:300])
