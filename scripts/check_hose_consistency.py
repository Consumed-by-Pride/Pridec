#!/usr/bin/env python3
"""Audit HOSE C/stdlib ABI inventory and the CURRENT PEAR libc declarations.

This is source/build consistency, NOT proof that native PEAR programs can run
HOSE: pear_link.c3 currently links libc, not runtime/compiler_rt.c. The old
root-level codegen.c3 and LLVM-22 pipeline are no longer the active backend.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO_ROOT = Path(__file__).resolve().parents[1]
HOSE_SYMBOLS = (
    "__pride_fiber_spawn", "__pride_fiber_yield", "__pride_fiber_resume",
    "__pride_prompt_install", "__pride_prompt_unwind", "__pride_is_in_scope",
    "__pride_scoped_yield_in", "__pride_scoped_yield_out", "__pride_split_cont",
    "__pride_fuse_cont",
)
REQUIRED_MODULES = (
    "stdlib/pride.pie", "stdlib/pride/effects.pie", "stdlib/pride/irdl.pie",
    "stdlib/pride/msp.pie", "stdlib/pride/ub.pie", "stdlib/pride/subtyping.pie",
    "stdlib/pride/rewrite.pie", "stdlib/effect_async.pie",
    "stdlib/effect_async/driver.pie", "stdlib/effect_async/epoll_handler.pie",
    "stdlib/effect_async/uring_handler.pie", "stdlib/effect_async/nursery.pie",
    "stdlib/effect_async/timeout.pie", "stdlib/effect_async/bracket.pie",
    "stdlib/effect_async/fiber_pool.pie",
)


def read_source(relative, errors):
    try:
        return (Path(REPO_ROOT) / relative).read_text()
    except OSError as exc:
        errors.append(f"Cannot read {relative}: {exc}")
        return ""


def resolve_c_runtime_toolchain():
    cc = os.environ.get("CC") or next(
        (c for c in ("cc", "gcc", "clang") if shutil.which(c)), "cc")
    flag = os.environ.get("PRIDE_C_STD")
    if not flag:
        try:
            run = subprocess.run(["bash", str(Path(REPO_ROOT) / "scripts/detect_c_std.sh")],
                                 capture_output=True, text=True,
                                 env={**os.environ, "CC": cc}, timeout=120)
            candidate = run.stdout.strip().splitlines()[0] if run.stdout.strip() else ""
            if run.returncode == 0 and candidate.startswith("-std="):
                flag = candidate
        except (OSError, subprocess.TimeoutExpired):
            pass
    return cc, flag or "-std=c11"


def build_runtime_exports():
    """Compile the real C runtime and inspect definitions, not comment strings."""
    cc, flag = resolve_c_runtime_toolchain()
    try:
        with tempfile.TemporaryDirectory(prefix="pride-hose-") as directory:
            obj = str(Path(directory) / "compiler_rt.o")
            run = subprocess.run([cc, "-O2", "-msse4.1", "-pthread", flag, "-c",
                                  str(Path(REPO_ROOT) / "runtime/compiler_rt.c"),
                                  "-o", obj, "-Wall"], capture_output=True, text=True, timeout=120)
            if run.returncode:
                return set(), [f"C runtime build failed ({cc} {flag}): {run.stderr}"]
            nm = subprocess.run(["nm", "-g", "--defined-only", obj],
                                capture_output=True, text=True, timeout=10)
            if nm.returncode:
                return set(), [f"Cannot inspect C runtime exports: {nm.stderr}"]
            print(f"   C runtime build/export inventory: {cc} {flag}")
            return {line.split()[-1] for line in nm.stdout.splitlines() if line.split()}, []
    except (OSError, subprocess.TimeoutExpired) as exc:
        return set(), [f"C runtime toolchain failed: {exc}"]


def check_runtime_symbols():
    exports, errors = build_runtime_exports()
    bindings = read_source("stdlib/pride/effects.pie", errors)
    declared = set(re.findall(r'^fn[^\n]*#extern\("([^"\n]+)"\)', bindings, re.M))
    for symbol in HOSE_SYMBOLS:
        if symbol not in declared:
            errors.append(f"Symbol {symbol} missing from stdlib/pride/effects.pie extern bindings")
        if symbol not in exports:
            errors.append(f"Symbol {symbol} missing from compiled C runtime exports")

    backend = read_source("pfront/pear_ir/pear.c3", errors)
    linker = read_source("pfront/pear_ir/pear_link.c3", errors)
    # v0.9 PEAR uses real libc allocation, not the old HOSE/stack-buffer ABI.
    for symbol in ("malloc", "free", "write"):
        if not re.search(r'll_add_fn\(m,\s*\(char\*\)"' + symbol + r'"\s*,', backend):
            errors.append(f"Current PEAR declaration for libc {symbol} is missing")
    if (not re.search(r'pear_tag_alloc_kind\(cg,\s*cg\.malloc_fn,\s*9\)', backend)
            or not re.search(r'pear_tag_alloc_kind\(cg,\s*cg\.free_fn,\s*4\)', backend)
            or 'll_enum_attr_kind((char*)"allockind", 9)' not in backend):
        errors.append("Current PEAR semantic malloc/free allocation attributes are missing")
    if not re.search(r'"LD_LIBRARY_PATH= ld[^"\n]*\s-lc', linker):
        errors.append("Current PEAR linker does not link libc")
    return errors


def check_pride_modules():
    errors = [f"Required module {name} does not exist" for name in REQUIRED_MODULES
              if not (Path(REPO_ROOT) / name).is_file()]
    for name in ("stdlib/async.pie", "stdlib/async"):
        if (Path(REPO_ROOT) / name).exists():
            errors.append(f"Obsolete legacy path {name} still exists")
    return errors


def check_loop_termination():
    """Legacy lexical lint only: conditional loops need NOT contain a break.

    This cannot prove termination and is deliberately not a build gate. Retained
    as an opt-in historical inventory rather than rejecting valid while loops.
    """
    findings = []
    for path in Path(REPO_ROOT).rglob("*.pie"):
        if any(part in (".git", "build", "tmp") for part in path.parts):
            continue
        text = path.read_text()
        for match in re.finditer(r"\bwhile\s+[^\n]*?\bdo\s*\{", text):
            start = match.end() - 1
            depth = 1
            end = start + 1
            while end < len(text) and depth:
                depth += (text[end] == "{") - (text[end] == "}")
                end += 1
            if "break" not in text[start:end]:
                findings.append(f"{path.relative_to(REPO_ROOT)}: lexical loop has no explicit break (not a defect proof)")
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--legacy-loop-audit", action="store_true",
                        help="print non-gating historical explicit-break lint")
    args = parser.parse_args()
    print("Pride HOSE ABI inventory / PEAR libc source consistency checker")
    errors = check_runtime_symbols() + check_pride_modules()
    print("NOTE: native PEAR currently links libc only; C HOSE inventory is not native runtime coverage.")
    if args.legacy_loop_audit:
        for finding in check_loop_termination():
            print("ADVISORY: " + finding)
    if errors:
        print("FAILED:")
        for error in errors:
            print("  - " + error)
        return 1
    print("SUCCESS: C/stdlib HOSE symbol inventory and current PEAR libc declarations agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
