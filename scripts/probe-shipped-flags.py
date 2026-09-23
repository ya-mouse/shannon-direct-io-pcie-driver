#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
probe-shipped-flags.py -- report the flag/gfp constants *baked into* the
precompiled proprietary core (*.o_shipped).

WHY
    The core was compiled once, against the shannon_*() shim of some long-past
    kernel, and never rebuilt.  Every kernel-derived constant it passes to a
    wrapper is frozen at that kernel's encoding.  Nothing detects the resulting
    drift: the values are not types, so modversions CRCs cannot cover them, and
    a misread gfp still builds and still loads.

    This tool answers "what does the core actually pass?" by disassembling each
    object and reading the immediate loaded into the SysV argument register at
    every call site of a flag-bearing wrapper.

HOW
    - `objdump -d -r` per object.  These objects are built with gcc 4.1.2, so
      calls relocate with R_X86_64_PC32 (not PLT32) and the <label> objdump
      prints next to a call is the *enclosing local function*, never the callee.
      The callee is taken only from the relocation record, and only if the
      relocation offset falls inside the call instruction's own bytes, so a data
      relocation belonging to the next instruction is never misattributed.
    - From the call, walk backwards for the last write of the argument register.
      An immediate is reported; any other write (mov from a register, lea, ...)
      is reported as <unresolved: dynamic>, which for gfp usually means the
      value was forwarded from the enclosing function's own parameter.

READ-ONLY: disassembles files in the working tree, writes nothing.

USAGE
    scripts/probe-shipped-flags.py                 # all *.o_shipped in cwd
    scripts/probe-shipped-flags.py --json          # machine-readable
    scripts/probe-shipped-flags.py --summary       # value histogram only
    scripts/probe-shipped-flags.py path/to/*.o_shipped

INTERPRETING THE OUTPUT
    Compare each reported value against the encoding of the kernel the core was
    built for -- not against the running kernel.  scripts/kernel-flag-abi.py
    prints the latter; .comment in the objects hints at the former.  A value
    that names a flag in one and something else (or nothing) in the other is a
    bug that must be translated in the wrapper.  See docs/flag-abi-drift.md.
"""
import re
import subprocess
import sys
import glob
from collections import defaultdict

# SysV AMD64 arg regs: (64-bit, 32-bit) forms
ARGS = [("rdi", "edi"), ("rsi", "esi"), ("rdx", "edx"),
        ("rcx", "ecx"), ("r8", "r8d"), ("r9", "r9d")]

# (symbol, arg_index, human name of the flag family)
TARGETS = {
    "shannon_kmalloc":                     (1, "gfp_t"),
    "shannon_kzalloc":                     (1, "gfp_t"),
    "__shannon_vmalloc":                   (1, "gfp_t"),
    "shannon_mempool_alloc":               (1, "gfp_t"),
    "shannon_kasprintf":                   (0, "gfp_t"),
    "__shannon_get_free_page":             (0, "gfp_t"),
    "shannon_sg_alloc":                    (1, "gfp_t"),
    "shannon_dma_alloc_coherent":          (3, "gfp_t"),
    "alloc_sbio":                          (0, "gfp_t"),
    "shannon_pci_alloc_consistent":        (3, "gfp_t"),
    "shannon_kmem_cache_create":           (3, "SLAB_*"),
    "shannon_queue_flag_set":              (0, "QUEUE_FLAG_*"),
    "shannon_queue_flag_clear":            (0, "QUEUE_FLAG_*"),
    "shannon_bio_flagged":                 (1, "BIO_*"),
    "__shannon_wake_up":                   (1, "TASK_* mode"),
    "shannon_autoremove_wake_function":    (1, "TASK_* mode"),
    "shannon_set_disk_ro":                 (1, "int flag"),
    "shannon_pm_qos_add_requirement":      (1, "PM_QOS class"),
    "shannon_pm_qos_update_requirement":   (1, "PM_QOS class"),
    "shannon_pm_qos_remove_requirement":   (1, "PM_QOS class"),
    "shannon_pm_qos_is_required":          (0, "PM_QOS class"),
    "shannon_dma_map_one_sg_page":         (2, "dma_dir"),
    "shannon_dma_unmap_one_sg_page":       (2, "dma_dir"),
    "shannon_dma_map_sg":                  (3, "dma_dir"),
    "shannon_dma_unmap_sg":                (3, "dma_dir"),
    "shannon_dma_map_single":              (3, "dma_dir"),
    "shannon_dma_unmap_single":            (3, "dma_dir"),
    "shannon_dma_map_page":                (4, "dma_dir"),
    "shannon_dma_unmap_page":              (4, "dma_dir"),
}

CALL_RE = re.compile(r"^\s*([0-9a-f]+):\s+call(?:q)?\s+")
# relocation line that names the real callee.  NOTE: these objects are built with
# gcc 4.1.2, so calls relocate with R_X86_64_PC32 (not PLT32); the inline
# <local_func+0xNN> objdump prints is NOT the callee -- the reloc is.
RELOC_RE = re.compile(r"R_X86_64_\w+\s+([A-Za-z0-9_.]+?)(?:-0x[0-9a-f]+)?\s*$")
MOV_IMM_RE = re.compile(r"^\s*[0-9a-f]+:\s+mov[lq]?\s+\$?(0x[0-9a-f]+|-?\d+)\s*,\s*%(\w+)")
ANY_INSN_RE = re.compile(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$")
FUNC_LABEL_RE = re.compile(r"^[0-9a-f]+ <([^>]+)>:")


def disasm(path):
    out = subprocess.run(["objdump", "-d", "-r", "--no-show-raw-insn", path],
                         capture_output=True, text=True).stdout
    return out.splitlines()


def resolve_callee(lines, i):
    """Callee of the call on line i.

    In these relocatable objects the printed <target> is just the enclosing local
    label, so the *only* reliable source is the relocation record.  We accept a
    reloc only if its offset falls inside the call instruction's own bytes
    (call is 5 bytes: E8 + rel32, reloc at call_addr+1), so we never pick up a
    data reloc belonging to the following instruction.
    """
    cm = re.match(r"^\s*([0-9a-f]+):", lines[i])
    if not cm:
        return None
    call_addr = int(cm.group(1), 16)
    for j in range(i + 1, min(i + 4, len(lines))):
        ln = lines[j]
        rm = re.match(r"^\s*([0-9a-f]{8,16}):\s+(R_X86_64_\w+)\s+(.+?)\s*$", ln)
        if not rm:
            break                      # next real instruction => local call
        roff = int(rm.group(1), 16)
        if not (call_addr < roff <= call_addr + 4):
            break                      # reloc belongs to a later instruction
        name = RELOC_RE.search(ln)
        if name:
            return name.group(1)
    return None


def trace_imm(lines, i, reg64, reg32, window=40):
    """Walk backwards from call at line i to find the imm loaded into reg.

    Returns (value, note).  value=None => could not resolve statically.
    """
    for j in range(i - 1, max(-1, i - window), -1):
        ln = lines[j]
        m = MOV_IMM_RE.match(ln)
        if m and m.group(2) in (reg64, reg32):
            raw = m.group(1)
            val = int(raw, 0) & 0xFFFFFFFF if raw.startswith("0x") else int(raw)
            return val, "imm"
        am = ANY_INSN_RE.match(ln)
        if not am:
            continue
        operands = am.group(3)
        # any write to the target register by another insn => not a constant
        if re.search(r"%(" + reg64 + r"|" + reg32 + r")\b", operands.split(",")[-1] or ""):
            if am.group(2).startswith(("xor", "mov", "lea", "add", "sub", "or", "and", "shl", "not")):
                # xor %r,%r == zeroing idiom
                if am.group(2) == "xor" and operands.count("%" + reg64) + operands.count("%" + reg32) == 2 \
                   and len(set(re.findall(r"%(\w+)", operands))) == 1:
                    return 0, "zero(xor)"
                return None, "dynamic(%s)" % am.group(2)
    return None, "not-found"


def main():
    import argparse, json

    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("objects", nargs="*", help="*.o_shipped files (default: cwd)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--summary", action="store_true",
                    help="value histogram only, no per-call-site context")
    a = ap.parse_args()

    files = a.objects or sorted(glob.glob("*.o_shipped"))
    if not files:
        raise SystemExit("no *.o_shipped objects found (run from the driver directory)")
    results = defaultdict(lambda: defaultdict(int))   # sym -> value -> count
    dynamic = defaultdict(lambda: defaultdict(int))   # sym -> note -> count
    sites = defaultdict(list)

    for f in files:
        lines = disasm(f)
        cur_func = "?"
        for i, ln in enumerate(lines):
            fm = FUNC_LABEL_RE.match(ln)
            if fm:
                cur_func = fm.group(1)
            if "call" not in ln:
                continue
            sym = resolve_callee(lines, i)
            if not sym or sym not in TARGETS:
                continue
            idx, fam = TARGETS[sym]
            r64, r32 = ARGS[idx]
            val, note = trace_imm(lines, i, r64, r32)
            if val is None:
                dynamic[sym][note] += 1
            else:
                results[sym][val] += 1
                sites[sym].append((f, ln.strip().split(":")[0], val, cur_func))

    if a.json:
        print(json.dumps({
            "objects": files,
            "constants": {s: {hex(v): c for v, c in sorted(d.items())}
                          for s, d in results.items()},
            "unresolved": {s: dict(d) for s, d in dynamic.items()},
            "call_sites": {s: [{"object": f, "addr": ad, "value": v,
                                "function": fn} for f, ad, v, fn in sites[s]]
                           for s in sites},
        }, indent=1, sort_keys=True))
        return

    print("=" * 78)
    print("BAKED-IN FLAG CONSTANTS IN THE PROPRIETARY CORE")
    print("=" * 78)
    for sym in TARGETS:
        if sym not in results and sym not in dynamic:
            continue
        fam = TARGETS[sym][1]
        print("\n### %s   [arg%d = %s]" % (sym, TARGETS[sym][0], fam))
        for val, cnt in sorted(results[sym].items()):
            print("    0x%-10x  %-10d  %d call site(s)" % (val, val, cnt))
        for note, cnt in sorted(dynamic[sym].items()):
            print("    <unresolved: %s>  %d call site(s)" % (note, cnt))
        if a.summary:
            continue
        # per-site context (object, addr, value, enclosing function)
        seen = set()
        for f, addr, val, fn in sites[sym]:
            key = (val, fn)
            if key in seen:
                continue
            seen.add(key)
            print("      @ %s:0x%-8s %-10s in %s()" % (f.replace('.o_shipped',''), addr, hex(val), fn))

    print("\n" + "=" * 78)
    print("SYMBOLS NEVER CALLED BY THE CORE (declared in shim, no call sites)")
    print("=" * 78)
    unused = [s for s in TARGETS if s not in results and s not in dynamic]
    for s in sorted(unused):
        print("   ", s)


if __name__ == "__main__":
    main()
