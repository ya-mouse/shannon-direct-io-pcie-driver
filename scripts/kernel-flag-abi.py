#!/usr/bin/env python3
"""
kernel-flag-abi.py -- audit how a kernel flag/enum family's *encoding* drifts
between kernel releases, read-only.

WHY THIS EXISTS
    shannon.ko links precompiled proprietary objects (*.o_shipped).  Any kernel
    constant that was frozen into those objects at vendor build time is a hidden
    ABI dependency: if the kernel renumbers or removes that flag, the core keeps
    passing the stale number and the wrapper forwards it unchanged.  Nothing
    warns -- modversions CRCs cover *types*, never flag *values*.

    Constants that live only inside the open-source wrappers are recompiled per
    kernel and are therefore always correct; this tool exists to check the ones
    that cross the core -> wrapper boundary, and to sanity-check a family before
    relying on it in a port.

SAFETY
    Only `git show <tag>:<path>` and `git ls-tree` are used.  The tree is never
    checked out, never built, never written to, so it is safe to point this at a
    kernel tree another session is using.

USAGE
    scripts/kernel-flag-abi.py --tree /Volumes/t23-src/linux \
        --tags v5.15,v6.8,v6.19 --family gfp,slab,bio
    scripts/kernel-flag-abi.py --tree <path> --list-families
    scripts/kernel-flag-abi.py --tree <path> --tags v5.15,v6.19 --only-drift
"""
import argparse
import re
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore")

# family -> (candidate header paths, name patterns to harvest)
FAMILIES = {
    "gfp":       (["include/linux/gfp_types.h", "include/linux/gfp.h"],
                  r"_{2,3}GFP_[A-Z0-9_]+|^GFP_[A-Z0-9_]+"),
    "slab":      (["include/linux/slab.h"],
                  r"_?SLAB_[A-Z0-9_]+"),
    "bio":       (["include/linux/blk_types.h", "include/linux/bio.h"],
                  r"^BIO_[A-Z0-9_]+"),
    "queue_flag": (["include/linux/blkdev.h"],
                  r"^QUEUE_FLAG_[A-Z0-9_]+"),
    "req_op":    (["include/linux/blk_types.h", "include/linux/blk-mq.h"],
                  r"^REQ_(OP_)?[A-Z0-9_]+"),
    "wq":        (["include/linux/workqueue.h"], r"^WQ_[A-Z0-9_]+"),
    "blk_mq":    (["include/linux/blk-mq.h"], r"^BLK_MQ_[A-Z0-9_]+"),
    "fmode":     (["include/linux/fs.h"], r"^FMODE_[A-Z0-9_]+"),
    "blk_open":  (["include/linux/blkdev.h", "include/linux/fs.h"],
                  r"^BLK_OPEN_[A-Z0-9_]+"),
    "dma_attr":  (["include/linux/dma-mapping.h"], r"^DMA_ATTR_[A-Z0-9_]+"),
    "dma_dir":   (["include/linux/dma-direction.h", "include/linux/dma-mapping.h"],
                  r"^DMA_[A-Z]+_DEVICE$|^DMA_BIDIRECTIONAL$|^DMA_NONE$"),
    "pci_irq":   (["include/linux/pci.h"], r"^PCI_IRQ_[A-Z0-9_]+"),
    "irqf":      (["include/linux/interrupt.h"], r"^IRQF_[A-Z0-9_]+"),
    "task":      (["include/linux/sched.h"], r"^TASK_[A-Z0-9_]+"),
    "pm_qos":    (["include/linux/pm_qos.h", "include/linux/pm_qos_params.h"],
                  r"^PM_QOS_[A-Z0-9_]+"),
    "hwmon":     (["include/linux/hwmon.h"], r"^hwmon_[a-z0-9_]+$"),
}

DEF_RE = re.compile(r"^#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)\s+(.+?)\s*$")

# names of function-like macros (e.g. __SLAB_FLAG_BIT) that must survive
# identifier substitution so eval() can call them; filled per harvest()
SHIFT_MACRO_NAMES = set()


def git(tree, *args):
    r = subprocess.run(["git", "-C", tree] + list(args),
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def show(tree, tag, path):
    return git(tree, "show", "%s:%s" % (tag, path))


def safe_enum_value(expr, known):
    """Evaluate an enum member's explicit initializer.

    Handles the forms kernels actually use: integers, '(1 << N)', 'BIT(N)',
    '|'/'+' combinations, and references to members already resolved in the same
    enum.  Returns None if it cannot be evaluated, so the caller can stop
    instead of silently mis-numbering the rest of the enum.
    """
    e = expr.rstrip(",").strip()
    e = re.sub(r"\bBIT\s*\(\s*(\d+)\s*\)", r"(1<<\1)", e)
    for k, v in sorted(known.items(), key=lambda kv: -len(kv[0])):
        e = re.sub(r"\b%s\b" % re.escape(k), "(%d)" % v, e)
    e = re.sub(r"\b(0x[0-9a-fA-F]+)[uUlL]+\b", r"\1", e)
    if re.sub(r"[0-9a-fA-Fx<>|&+\-()\s]", "", e):
        return None                      # leftover identifier => not evaluable
    try:
        return eval(e, {"__builtins__": {}})
    except Exception:
        return None


def enum_indices(text, names):
    """Assign ordinals to enum members, in source order.

    NOTE: #ifdef-gated members shift the ordinals of everything after them, so an
    ordinal computed this way is config-independent *only* if no conditional
    member precedes it.  We report the conditional members separately so the
    caller can judge.
    """
    out = {}
    conditionals = []
    for blk in re.findall(r"enum\s*(?:[A-Za-z_][A-Za-z0-9_]*\s*)?\{(.*?)\}", text, re.S):
        # Strip block comments from the WHOLE body before splitting on commas:
        # kernel enums frequently put the comment *before* the next member
        # inside the same comma-delimited fragment, e.g.
        #   BIO_BPS_THROTTLED, /* This bio has already been
        #                       * throttled. */
        #   BIO_TRACE_COMPLETION,
        # so per-fragment stripping loses the member that follows the comment.
        blk = re.sub(r"/\*.*?\*/", " ", blk, flags=re.S)
        blk = re.sub(r"//[^\n]*", " ", blk)
        n = 0
        in_if = 0
        for raw in blk.split(","):
            line = raw
            for l in line.splitlines():
                ls = l.strip()
                if re.match(r"^#\s*if", ls):
                    in_if += 1
                elif re.match(r"^#\s*(endif|else)", ls):
                    in_if = max(0, in_if - 1)
            item = " ".join(line.split())
            if not item:
                continue
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\s*=\s*(.+))?$", item)
            if not m or item.startswith("#"):
                continue
            name = m.group(1)
            if name not in names:
                continue
            if m.group(2):
                v = safe_enum_value(m.group(2).strip(), out)
                if v is None:
                    # Cannot determine this member's value, so every ordinal
                    # after it is unknowable -- stop rather than report a
                    # plausible-looking wrong number.
                    break
                n = v
            out[name] = n
            if in_if:
                conditionals.append(name)
            n += 1
    return out, conditionals


def harvest(tree, tag, family):
    paths, pat = FAMILIES[family]
    rx = re.compile(pat)
    text = ""
    for p in paths:
        text += show(tree, tag, p) + "\n"
    if not text.strip():
        return None
    names = set()
    for line in text.splitlines():
        m = DEF_RE.match(line.split("/*")[0].strip())
        if m and rx.match(m.group(1)):
            names.add(m.group(1))
        # bare enum member lines (strip trailing comments first -- enum bodies
        # are heavily commented, e.g. "QUEUE_FLAG_DYING,\t/* queue being torn down */")
        bare = line.split("/*")[0].split("//")[0].rstrip()
        m2 = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^,]*)?,?\s*$", bare)
        if m2 and rx.match(m2.group(1)):
            names.add(m2.group(1))
    defs, bits = {}, {}
    # atoms: #define X 0xNN / #define X BIT(_X_BIT)
    for line in text.splitlines():
        m = DEF_RE.match(line.split("/*")[0].strip())
        if not m or m.group(1) not in names:
            continue
        defs[m.group(1)] = m.group(2)
    idx, cond = enum_indices(text, names)
    for k, v in idx.items():
        bits[k] = v
    SHIFT_MACRO_NAMES.clear()
    SHIFT_MACRO_NAMES.update(k for k in shift_macros(text) if k != "BIT")
    vals = {}
    for n in names:
        v = eval_def(tree, tag, n, defs, bits, text, family)
        if v is not None:
            vals[n] = v
    return {"values": vals, "conditionals": sorted(set(cond)),
            "enum_only": sorted(set(idx) - set(defs))}


def shift_macros(text):
    """Build the eval namespace: BIT() plus any function-like shift macro.

    Since v6.9 slab.h spells its flags as __SLAB_FLAG_BIT(_SLAB_X), which is
    #define'd as ((slab_flags_t __force)(1U << (nr))).  Treating those as real
    functions is the only way to evaluate them.
    """
    ns = {"BIT": lambda x: 1 << x}
    # re.M matters: ^/$ must match per line, not just at the string ends
    pat = re.compile(r"^#\s*define\s+([A-Za-z_]\w*)\s*\(\s*(\w+)\s*\)\s*(.+)$", re.M)
    for m in pat.finditer(text.replace("\r", "")):
        name, param, body = m.group(1), m.group(2), m.group(3)
        if name in ns:
            continue
        b = body.split("/*")[0].strip()
        b = re.sub(r"\(\s*[A-Za-z_]\w*\s+__force\s*\)", "", b)
        b = re.sub(r"\(\s*__force\s+[A-Za-z_]\w*\s*\)", "", b)
        b = b.replace("__force", " ")
        b = re.sub(r"\b(\d+)[uUlL]+\b", r"\1", b)
        b = re.sub(r"\b(0x[0-9a-fA-F]+)[uUlL]+\b", r"\1", b)
        if "<<" not in b:
            continue
        try:
            ns[name] = eval("lambda %s: %s" % (param, b), {"__builtins__": {}}, ns)
        except Exception:
            pass
    return ns


def eval_def(tree, tag, name, defs, bits, text, family, depth=0):
    if depth > 8:
        return None
    # bare enum member (no #define): the value callers pass is the ordinal,
    # e.g. set_bit(QUEUE_FLAG_X, ...) / bio_flagged(bio, X).  A #define of the
    # form BIT(_X_BIT) below still evaluates to a mask, which is also what
    # callers pass.  Reporting both as "the number the kernel API receives"
    # keeps drift detection comparable across a #define -> enum conversion.
    if name in bits and name not in defs:
        return bits[name]
    if name not in defs:
        return None
    expr = defs[name]
    if re.match(r"^BIT\s*\(", expr):
        m = re.search(r"BIT\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", expr)
        if m and m.group(1) in bits:
            return 1 << bits[m.group(1)]
    # Strip the sparse cast *before* deleting its type name, otherwise we are
    # left with an empty "()" immediately followed by a value, which Python
    # parses as calling a tuple and the expression silently fails to evaluate.
    # Both spellings occur in the kernel: "(__force gfp_t)X" in gfp.h and
    # "(slab_flags_t __force)X" in slab.h.
    for cast in (r"\(\s*__force\s+[A-Za-z_][A-Za-z0-9_]*\s*\)",
                 r"\(\s*[A-Za-z_][A-Za-z0-9_]*\s+__force\s*\)",
                 r"\(\s*gfp_t\s*\)", r"\(\s*slab_flags_t\s*\)"):
        expr = re.sub(cast, "", expr)
    expr = expr.replace("__force", " ")
    expr = re.sub(r"\b(?:gfp_t|slab_flags_t|unsigned\s+long|unsigned)\b", " ", expr)
    expr = re.sub(r"\bIS_ENABLED\s*\([^)]*\)", "0", expr)
    # strip integer literal suffixes: 0x10u -> 0x10, and 1UL -> 1
    expr = re.sub(r"\b(0x[0-9a-fA-F]+)[uUlL]+\b", r"\1", expr)
    expr = re.sub(r"\b(\d+)[uUlL]+\b", r"\1", expr)
    for _ in range(4):
        if len(expr) > 4096:
            return None
        before = expr
        for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", expr):
            tok = m.group(0)
            if tok == "BIT" or tok == name or tok in SHIFT_MACRO_NAMES:
                continue
            v = None
            if tok in bits:
                # Substitute the ORDINAL, not (1<<ordinal): bits[] holds enum
                # positions, and the shift belongs to the enclosing macro
                # (BIT(x) in gfp_types.h, __SLAB_FLAG_BIT(x) in slab.h since
                # v6.9).  Shifting here as well silently double-shifts, which is
                # how SLAB_HWCACHE_ALIGN came out as 1<<16 instead of 1<<4.
                v = bits[tok]
                expr = re.sub(r"\b%s\b" % re.escape(tok), "(%d)" % v, expr)
            elif tok in defs:
                v = eval_def(tree, tag, tok, defs, bits, text, family, depth + 1)
                if v is not None:
                    expr = re.sub(r"\b%s\b" % re.escape(tok), "(%d)" % v, expr)
        if expr == before:
            break
    ns = shift_macros(text)
    probe = re.sub(r"0x[0-9a-fA-F]+", "", expr)
    for macro in sorted(ns, key=len, reverse=True):
        probe = probe.replace(macro, "")
    if re.search(r"[A-Za-z_]", probe):
        return None
    try:
        return eval(expr, {"__builtins__": {}}, ns)
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True, help="path to a kernel git tree")
    ap.add_argument("--tags", default="v5.15,v6.8,v6.19",
                    help="comma-separated tags/refs to compare")
    ap.add_argument("--family", default="gfp,slab,bio",
                    help="comma-separated families, or 'all'")
    ap.add_argument("--list-families", action="store_true")
    ap.add_argument("--only-drift", action="store_true",
                    help="print only names whose value changed across the tags")
    ap.add_argument("--name", default=None,
                    help="restrict output to names matching this substring")
    a = ap.parse_args()

    if a.list_families:
        for f, (paths, _) in FAMILIES.items():
            print("%-12s %s" % (f, ", ".join(paths)))
        return 0

    fams = list(FAMILIES) if a.family == "all" else a.family.split(",")
    tags = a.tags.split(",")
    unknown = [f for f in fams if f not in FAMILIES]
    if unknown:
        sys.exit("unknown family/families: %s (try --list-families)" % ",".join(unknown))

    for fam in fams:
        per = {}
        for t in tags:
            per[t] = harvest(a.tree, t, fam)
        if all(v is None for v in per.values()):
            print("\n### %s: no data at any of %s" % (fam, ",".join(tags)))
            continue
        names = set()
        for t in tags:
            if per[t]:
                names |= set(per[t]["values"])
        if not names:
            # Never let "harvested nothing" look like "stable".  Say so loudly.
            print("\n### %s: NO DEFINITIONS HARVESTED at %s" % (fam, ",".join(tags)))
            print("    (header moved, or the family's names don't match the "
                  "pattern %r -- fix FAMILIES[] before trusting this result)"
                  % FAMILIES[fam][1])
            continue
        w = max(len(n) for n in names) + 2
        print("\n" + "=" * 78)
        print("### family: %s   (%s)" % (fam, ", ".join(FAMILIES[fam][0])))
        print("    values shown are what the kernel API receives: a bit MASK for")
        print("    '#define X 0xNN'/'BIT(n)' families, or a bit INDEX for bare-enum families.")
        print("=" * 78)
        print("%-*s" % (w, "name") + "".join("%12s" % t for t in tags) + "   status")
        for n in sorted(names):
            if a.name and a.name not in n:
                continue
            row = []
            vals = []
            for t in tags:
                v = per[t]["values"].get(n) if per[t] else None
                vals.append(v)
                row.append(hex(v) if v is not None else "-")
            present = [i for i, v in enumerate(vals) if v is not None]
            if not present:
                status = "?"
            elif len(present) < len(vals):
                first_missing = next(i for i, v in enumerate(vals) if v is None)
                status = "REMOVED@%s" % tags[first_missing] if present[0] < first_missing \
                    else "ADDED@%s" % tags[first_missing]
            else:
                uniq = set(vals)
                status = "stable" if len(uniq) == 1 else "RENUMBERED"
            if a.only_drift and status in ("stable", "?"):
                continue
            print("%-*s" % (w, n) + "".join("%12s" % r for r in row) + "   " + status)
        conds = sorted(set().union(*[set(per[t]["conditionals"]) for t in tags if per[t]]))
        if conds:
            print("  note: these enum members are #ifdef-gated, so ordinals after "
                  "them are config-dependent:")
            print("        " + ", ".join(conds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
