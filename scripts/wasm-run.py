#!/usr/bin/env python3
"""Run a WASI .wasm under wasmtime (python bindings); prints its stdout, exits with its exit code.
  python3 scripts/wasm-run.py prog.wasm"""
import os, re, sys, tempfile
from wasmtime import Config, Engine, Store, Module, Linker, WasiConfig, ExitTrap, Trap
cfg = Config(); cfg.max_wasm_stack = 2 * 1024 * 1024 - 4096   # the host's own limit for nested wasm calls is 512 KiB: small for ordinary recursion (the most the engine allows is its 2 MiB async stack size)
eng = Engine(cfg); store = Store(eng)
wc = WasiConfig(); wc.inherit_stdout();  wc.argv = [sys.argv[1]]
errf = tempfile.mktemp(); wc.stderr_file = errf
store.set_wasi(wc)
lk = Linker(eng); lk.define_wasi()
mod = Module.from_file(eng, sys.argv[1])
def finish(code):
    err = open(errf).read() if os.path.exists(errf) else ""
    if os.path.exists(errf): os.unlink(errf)
    m = re.search(r"pride-exit:(\d+)", err)
    if m: code = int(m.group(1)); err = err.replace(m.group(0), "")   # WASI cannot exit >= 126: the runtime reports the status here
    sys.stderr.write(err.strip("\n") + ("\n" if err.strip("\n") else ""))
    sys.exit(code)
try:
    inst = lk.instantiate(store, mod)
    inst.exports(store)["_start"](store)
    finish(0)
except ExitTrap as e:
    finish(e.code)
except Trap as e:
    sys.stderr.write("trap: %s\n" % e)
    msg = str(e)   # the exit status a native process would die with: ud2 = SIGILL (132), a bad access = SIGSEGV (139)
    finish(132 if "unreachable" in msg else 139 if "out of bounds" in msg else 134)
