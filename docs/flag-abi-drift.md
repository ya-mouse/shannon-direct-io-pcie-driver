# Flag / constant ABI drift in the precompiled core

How to check whether a kernel API's **flag encoding** still means what the
precompiled proprietary core (`*.o_shipped`) thinks it means, what such an audit
found here, and what is already fixed in tree.

Read this before porting to a new kernel, and before believing any allocation,
IRQ, DMA or block-layer flag that crosses the core → wrapper boundary.

---

## 1. The invariant — and the one exception

`docs/driver-structure.md` §2 says the core calls a stable internal `shannon_*()`
API and never the kernel directly. That is almost exactly true, and it is what
makes this driver portable: **everything inside the wrappers is recompiled
against the target kernel, so every constant there is correct by construction.**

The exception is the argument *values* the core passes in. Those are immediates
baked into `.text` at vendor build time, and they carry the flag encoding of the
vendor's kernel — not ours. A wrapper that forwards such an argument verbatim
hands the running kernel a number that meant something else when it was chosen.

So the entire audit surface is small and precisely describable:

> **A constant can only be stale if it is (a) a kernel-derived flag/enum value,
> (b) frozen into `*.o_shipped`, and (c) forwarded to a kernel API without
> translation.**

Everything else is recompiled and self-correcting.

## 2. Why nothing catches this automatically

- **Not the compiler.** The core is not compiled; it is `objcopy`'d and linked.
- **Not modversions.** CRCs are computed from *type* signatures. `gfp_t` is
  `unsigned __bitwise__` whether it holds `GFP_NOIO` or garbage, so a stale flag
  has the same CRC as a correct one. (Separately: the shipped objects carry **no
  `__versions` section** at all — `objdump -h *.o_shipped` — so their five direct
  kernel imports are not even type-checked; the CRCs in the final `.ko` come from
  modpost reading the target kernel's `Module.symvers`.)
- **Not the loader.** The module links and insmods fine.
- **Usually not dmesg.** The failure mode is behavioural: allocations that
  cannot reclaim, a mempool that will not wait, a cache that lost its alignment,
  a flag test that is permanently false. Only `mm/vmalloc.c` started validating
  gfp at all, and only in v6.19 (commit `07003531e03c`).

The one thing that *does* catch it is reading the immediates out of the objects
and comparing them with the target kernel's headers. Hence the tooling below.

## 3. How to audit (reproducible)

### 3.1 What does the core actually reference?

```sh
# every undefined symbol across the nine objects
nm -u *.o_shipped | awk '{print $NF}' | sort -u > /tmp/undef.txt

# minus what the core defines itself
nm --defined-only -g *.o_shipped | awk '$2 ~ /^[TtDdBbRrVvWwAa]$/ {print $3}' \
    | sort -u > /tmp/core_def.txt
comm -23 /tmp/undef.txt /tmp/core_def.txt > /tmp/ext_deps.txt        # 306

# minus what the open-source wrappers define  ->  the kernel symbols
nm --defined-only -g shannon_block.o shannon_cdev.o shannon_device.o \
    shannon_dma.o shannon_file.o shannon_kcore.o shannon_module_init.o \
    shannon_pci.o shannon_scatter.o shannon_sched.o shannon_scsi.o \
    shannon_sysfs.o shannon_time.o shannon_waitqueue.o shannon_workqueue.o \
    | awk '$2 ~ /^[TtDdBbRrVvWwAa]$/ {print $3}' | sort -u > /tmp/wrap_def.txt
comm -23 /tmp/ext_deps.txt /tmp/wrap_def.txt                        # 5 symbols
```

Beware two traps, both of which silently produce a wrong answer:

- `nm` with **multiple** files prints a `file.o:` header per file — filter on
  field count, not on a fixed column.
- Under **zsh**, an unquoted `$LIST` is *not* word-split, so `nm $OBJS` passes one
  bogus filename and you get an empty symbol set. Quote it or list files inline.

### 3.2 What constant values does it pass?

```sh
scripts/probe-shipped-flags.py            # all *.o_shipped in cwd
scripts/probe-shipped-flags.py --summary  # value histogram only
scripts/probe-shipped-flags.py --json     # machine-readable
```

The probe disassembles each object, resolves the callee of every `call` **from
the relocation record**, and walks backwards for the immediate loaded into the
SysV argument register that carries the flag. Two details matter:

- These objects are built with gcc 4.1.2, so calls relocate with `R_X86_64_PC32`,
  **not** `PLT32`, and the `<label>` objdump prints beside a call is the
  *enclosing local function*, never the callee. Trusting it yields nothing.
- A relocation is only accepted if its offset falls inside the call
  instruction's own bytes, so a data relocation belonging to the *next*
  instruction is never misattributed to the call.

`<unresolved: dynamic(...)>` means the register was loaded from another register
or the stack — almost always a parameter being forwarded. Follow it: e.g.
`alloc_sbio(gfp)` at `shannon_main.o_shipped+0x1ccb2` does
`movl %edi,%r12d; movl %r12d,%esi; call shannon_mempool_alloc`, i.e. it forwards
its own gfp argument, so its 42 call sites' constants land in `mempool_alloc()`.

### 3.3 What does the target kernel call those numbers?

```sh
scripts/kernel-flag-abi.py --tree /path/to/linux --list-families
scripts/kernel-flag-abi.py --tree /path/to/linux \
    --tags v3.10,v5.15,v6.8,v6.19 --family gfp,slab,bio
scripts/kernel-flag-abi.py --tree /path/to/linux \
    --tags v5.15,v6.19 --family all --only-drift
```

It resolves each family's names to the number the kernel API actually receives
(a bit **mask** for `#define X 0xNN` / `BIT(n)` families, a bit **index** for
bare-enum families like `QUEUE_FLAG_*` / `BIO_*`), across every tag you list, and
labels each name `stable` / `RENUMBERED` / `REMOVED@tag` / `ADDED@tag`.

**The kernel tree is used strictly read-only** — only `git show <tag>:<path>` and
`git ls-tree`. It is never checked out, built, or written to, so it is safe to
point at a tree another session is working in. Do not "help" it by checking out a
tag.

### 3.4 Identify the core's build encoding

Compare the baked values against candidate kernels until a named flag matches:

```sh
git -C /path/to/linux show v3.10:include/linux/gfp.h | grep -E '^#define (__GFP_WAIT|__GFP_HIGH|__GFP_NOWARN|GFP_ATOMIC|GFP_NOIO|GFP_KERNEL)'
objdump -s -j .comment shannon_main.o_shipped   # toolchain vintage
```

`GFP_NOIO == 0x10` holds only up to **v4.3**; from v4.4 (`__GFP_WAIT` split into
`__GFP_DIRECT_RECLAIM`/`__GFP_KSWAPD_RECLAIM`) `0x10` means
`___GFP_RECLAIMABLE`. Combined with `.comment` =
`GCC: (GNU) 4.1.2 20080704 (Red Hat 4.1.2-54)` and `shannon_kcore.h`'s
`#define GFP_SHANNON GFP_NOIO`, the core's encoding is 2.6.x/3.x-era. The exact
release is not pinnable (gcc 4.1.2 suggests RHEL5/2.6.18, the shim's
`<linux/pm_qos.h>` include suggests ≥3.2) and does not matter: all three
constants in play decode identically across that whole range.

## 4. What the audit found

### 4.1 Kernel symbols referenced directly by the core: exactly five

Of 593 undefined symbols, 306 are external to the core, and **301 of those are
satisfied by the wrappers**. The residue:

| symbol | v5.15 | v6.8 | v6.19 | status |
|---|---|---|---|---|
| `printk` | **renamed `_printk`** | `_printk` | `_printk` | handled: `Makefile` `objcopy --redefine-sym printk=_printk` for ≥5.15 |
| `memcpy` | exported | exported | exported (`arch/x86/lib/memcpy_64.S`) | fine |
| `strcmp` | exported | exported | exported (`lib/string.c`; x86_64 defines only `__HAVE_ARCH_MEMCPY`, not `STRCMP`) | fine |
| `strncpy` | exported | exported | exported (`lib/string.c:104`) | **watch item** — deprecated kernel-wide; `strlcpy` is already gone (`d26270061ae6`) |
| `dump_stack` | exported | exported | exported (`lib/dump_stack.c`) | fine |

Cross-checked against the last successful build (`vermagic=6.8.0-48-generic …
modversions` in `shannon.mod.o`): all five resolved, with `_printk` present and
`printk` absent — i.e. the objcopy rule did its job.

### 4.2 Constants that cross the boundary

| family | baked value(s) | sites | meaning in the core's encoding | on a modern kernel | verdict |
|---|---|---|---|---|---|
| `gfp_t` | `0x10` | 127 | `GFP_NOIO` | `___GFP_RECLAIMABLE` — **no reclaim at all** | **broken** |
| `gfp_t` | `0x220` | 26 | `GFP_ATOMIC\|__GFP_NOWARN` | `__GFP_HIGH` + unassigned bit 9 (v6.3+) | **broken** |
| `gfp_t` | `0x200` | 4 | `__GFP_NOWARN` | `___GFP_ATOMIC` (v5.4–v6.2), unassigned (v6.3+) | **broken** |
| `slab_flags_t` | `0x2000` | 2 | `SLAB_HWCACHE_ALIGN` | `SLAB_HWCACHE_ALIGN` ≤v6.8; bit 13 = `SLAB_NO_MERGE` ≥v6.9 | **broken ≥v6.9** |
| `BIO_*` | `0x10` (=16) | 1 | `BIO_RW_PRIO`, a shim-private bit index (`shannon_block.h:147`) | `bi_flags` is `unsigned short` since v4.8, so bit 16 does not exist | **dead since v4.8** |
| `dma_data_direction` | `0x1`, `0x2` | 73 | `DMA_TO_DEVICE`, `DMA_FROM_DEVICE` | identical | safe |
| `TASK_*` wake mode | `0x3` | 60 | `TASK_NORMAL` | identical | safe |
| PM_QOS class | `0x1` | 9 | `PM_QOS_CPU_DMA_LATENCY` | class removed upstream (`67b06ba01857`) | **already handled** — see below |
| `shannon_set_disk_ro` | `0x1` | 1 | boolean | boolean | safe |

Consequences of the gfp drift, verified against the upstream tree:

1. **No allocation can reclaim.** `0x10` lacks both `__GFP_DIRECT_RECLAIM` (0x400)
   and `__GFP_KSWAPD_RECLAIM` (0x800), so `gfpflags_allow_blocking()` is false
   and every core allocation behaves like `GFP_NOWAIT`. Epilog recovery is
   memory-heavy, which is exactly when this bites.
2. **The mempool forward-progress guarantee is defeated in the I/O path.**
   `mm/mempool.c` gates the wait-for-refill loop on `if (gfp_mask &
   __GFP_DIRECT_RECLAIM)`. `alloc_sbio()` forwards its gfp verbatim into
   `shannon_mempool_alloc()`, so a drained `shannon_bio_pool` returns NULL
   immediately instead of waiting — in the block-I/O submission path.
3. **v6.19 rejects `0x10` outright on the vmalloc path.**
   `GFP_VMALLOC_SUPPORTED` (`mm/vmalloc.c`) includes `GFP_NOIO` but *not*
   `___GFP_RECLAIMABLE`, so `__shannon_alloc_map_table()` /
   `__shannon_map_table_resize()` get
   `Unexpected gfp: 0x10 … Fixing up to gfp: 0x0` and allocate the map table with
   gfp 0. The previously seen `Unexpected gfp: 0x200` from
   `__check_and_alloc_memblock()` is the same defect on a different constant.
4. **Slab caches lose cacheline alignment ≥v6.9** with no diagnostic:
   `kmem_cache_create()` does not validate unknown flag bits.
5. **`BIO_RW_PRIO` is permanently false.** `bio_flagged(bio, 16)` computes
   `bi_flags & (1U << 16)` against a 16-bit field. Nothing in the shim sets any
   bio flag (there is no `bio_set_flag()` call anywhere), and 2.6.x's
   `BIO_BOUNCED` is gone entirely by v6.19, so the guarded path in
   `host_get_head_and_set_pba_table()` has been dead since v4.8.

**PM_QOS is the model to copy.** `shannon_kcore.h` defines its own
`SHANNON_PM_QOS_CPU_DMA_LATENCY 1`, the wrapper validates the incoming class
against it (`shannon_kcore.c:979/993/1008/1025`) and then calls
`cpu_latency_qos_*`, so the stale class number never reaches the kernel. That is
the pattern the gfp and slab paths were missing.

### 4.3 Wrapper-internal families (porting checklist, not a live bug)

These never cross the boundary — they are recompiled per kernel, and where they
moved the wrappers already carry `LINUX_VERSION_CODE` guards (e.g.
`QUEUE_FLAG_DISCARD`, removed by v6.8, survives only in the `<6.8` branch of
`shannon_trim_setting()`). The counts are names whose value changed between the
listed tags, from `scripts/kernel-flag-abi.py`:

| family | header | RENUMBERED | REMOVED | ADDED | stable | note |
|---|---|---|---|---|---|---|
| `gfp` | `gfp_types.h` | 31 | 20 | 51 | 17 | v3.10→v6.19 |
| `slab` | `slab.h` | 7 | 9 | 23 | 0 | whole enum renumbered at v6.9 |
| `bio` | `blk_types.h` | 2 | 17 | 27 | 1 | `BIO_BOUNCED`, `BIO_NO_PAGE_REF` gone |
| `task` | `sched.h` | 6 | 0 | 7 | 5 | `TASK_NORMAL` itself stable |
| `pm_qos` | `pm_qos.h` | 0 | 8 | 3 | 12 | class API replaced |
| `dma_dir` | `dma-direction.h` | 0 | 0 | 0 | 4 | **byte-identical since 2.6.18** |
| `queue_flag` | `blkdev.h` | 12 | 18 | 10 | 0 | v5.15→v6.19; bit *indices* |
| `req_op` | `blk_types.h` | 0 | 16 | 0 | 3 | `REQ_OP_DRV_OUT` 0x800000000 → 0x1 |
| `wq` | `workqueue.h` | 1 | 1 | 10 | 7 | |
| `blk_mq` | `blk-mq.h` | 2 | 6 | 4 | 10 | `BLK_MQ_F_BLOCKING` 0x8 → 0x4 |
| `fmode` | `fs.h` | 1 | 5 | 9 | 21 | superseded by `blk_open` |
| `blk_open` | `blkdev.h` | 0 | 0 | 7 | 0 | new family |
| `dma_attr` | `dma-mapping.h` | 0 | 0 | 1 | 8 | stable |
| `pci_irq` | `pci.h` | 0 | 1 | 2 | 4 | `PCI_IRQ_LEGACY` → `PCI_IRQ_INTX`, value kept |
| `irqf` | `interrupt.h` | 0 | 0 | 1 | 19 | stable |
| `hwmon` | `hwmon.h` | 5 | 0 | 11 | 144 | mostly stable |

`RENUMBERED` is the dangerous class: a removed name fails the build loudly, but a
renumbered one compiles and means something else. When porting, read the
`RENUMBERED` rows first.

## 5. What is implemented

`shannon_gfp_legacy.h` holds the legacy encoding table and two translators; both
are written in terms of **named modern macros**, never hex, so they track future
renumbering automatically.

- `shannon_gfp_xlate()` — applied in `shannon_kmalloc`, `shannon_kzalloc`,
  `__shannon_vmalloc`, `shannon_kasprintf`, `shannon_mempool_alloc`,
  `__shannon_get_free_page` (`shannon_kcore.c`) and `shannon_dma_alloc_coherent`
  (`shannon_dma.c`, plus the `CONFIG_SHANNON_EMU` inline in `shannon_dma.h`).
- `shannon_slab_flags_xlate()` — applied in `shannon_kmem_cache_create`.
- `shannon_bio_flagged()` — refuses bit indices that `bi_flags` cannot hold and
  says so once, instead of silently answering 0.
- `shannon_gfp_xlate_selftest()` — logs the translation table at load
  (`shannon_module_init.c`) so it is visible in the serial log:
  `shn_info: legacy gfp 0x10 -> 0xc00 (GFP_NOIO)`.

### The discriminator

These wrappers are called by **two populations**: the core (legacy encoding) and
the wrappers themselves (this kernel's encoding — `GFP_SHANNON`, `GFP_ATOMIC`,
`GFP_NOWAIT`). `alloc_sbio()` alone is called from both. They cannot be told
apart by call site, so `shannon_gfp_is_legacy()` classifies the *value*:

- `0` is never translated;
- any bit above `0xffff` cannot be legacy (the legacy encoding is 16 bits);
- any value carrying a modern reclaim bit is already modern. Every usable gfp on
  a modern kernel carries one — `GFP_KERNEL`/`GFP_NOIO`/`GFP_NOFS`/`GFP_ATOMIC`/
  `GFP_NOWAIT` all do — while none of the three legacy values does.

`shannon_gfp_assert_native()` converts that assumption into `BUILD_BUG_ON`s, so a
future kernel that defines a reclaim-free `GFP_*` this driver uses fails the
build rather than mistranslating. Getting this wrong is not academic: legacy
`0x400`/`0x800` are `__GFP_REPEAT`/`__GFP_NOFAIL`, so mistranslating a modern
`GFP_NOIO` (0xC00) would inject `__GFP_NOFAIL` into the I/O path.

### Deliberate behaviour changes

Two mappings restore *intent* rather than reproducing the old numbers, and both
change runtime behaviour:

- legacy `0x10` → `GFP_NOIO` (0xC00) restores sleeping reclaim to ~127
  allocation sites, including the mempool-backed sbio path.
- legacy `0x200` (`__GFP_NOWARN` alone) → `__GFP_NOWARN | __GFP_KSWAPD_RECLAIM`,
  i.e. `GFP_NOWAIT`. The legacy encoding had no kswapd-only bit, so "no
  `__GFP_WAIT`" could not express "background reclaim allowed"; this is the
  closest non-blocking equivalent, and it is what `GFP_NOWAIT` has meant since
  v6.8 (`16f5dfbc851b`).

On a ≤v4.3 kernel the whole thing compiles to the identity (`__GFP_WAIT`'s
presence is the test), and the modern decode body is not compiled at all — it
names `__GFP_RECLAIM`, which does not exist there.

## 6. Verified version boundaries

| change | commit | first release |
|---|---|---|
| `__GFP_WAIT` split into direct/kswapd reclaim; `GFP_NOIO` 0x10 → 0xC00 | `d0164adc89f6` | v4.4 |
| `bi_flags` shrunk to `unsigned short` (kills bit 16) | `c0acf12a50c2` | v4.8 |
| `SLAB_DESTROY_BY_RCU` → `SLAB_TYPESAFE_BY_RCU` | — | v4.5 |
| `printk` → `_printk` | — | v5.15 |
| `pm_qos_*` → `cpu_latency_qos_*`, `PM_QOS_CPU_DMA_LATENCY` dropped | `67b06ba01857` | v5.7 |
| `___GFP_ATOMIC` discarded (bit 9 becomes `___GFP_UNUSED_BIT`) | `2973d8229b78` | v6.3 |
| `GFP_NOWAIT` gains `__GFP_NOWARN` | `16f5dfbc851b` | v6.8 |
| slab flags become `BIT(_SLAB_*)`; `SLAB_HWCACHE_ALIGN` 0x2000 → 0x10 | `cc61eb851c9a` | v6.9 |
| `__vmalloc` validates gfp against `GFP_VMALLOC_SUPPORTED` | `07003531e03c` | v6.19 |

Stable across the whole span, and therefore safe to forward untouched:
`enum dma_data_direction`, `TASK_INTERRUPTIBLE`/`TASK_UNINTERRUPTIBLE`,
`IRQF_*`, `DMA_ATTR_*`, `PCI_IRQ_MSI`/`MSIX`/`VIRTUAL`.

## 7. Tests

```sh
scripts/test-gfp-xlate.sh --tree /path/to/linux \
    --tags v3.10,v4.4,v5.15,v6.3,v6.8,v6.9,v6.12,v6.19
```

This compiles `tests/gfp-xlate-harness.c` once per tag against the **real**
`GFP_*`/`SLAB_*` values extracted from that tag, and asserts that the three baked
values map onto their intended modern composites, that the results can reclaim,
that no translation ever gains `__GFP_NOFAIL`, that translation is idempotent,
and that every native gfp this driver passes is left untouched. The slab check
count steps up at v6.9, which is the boundary itself showing up in the test.

Run it after touching `shannon_gfp_legacy.h`, and after any kernel bump. It needs
only a kernel git tree and a host compiler — no kernel build, no hardware.

## 8. Tool reference

| script | purpose | side effects |
|---|---|---|
| `scripts/probe-shipped-flags.py` | constants baked into `*.o_shipped`, per call site, with enclosing function | none (disassembles in place) |
| `scripts/kernel-flag-abi.py` | a flag family's encoding across kernel tags, with drift labels | none (`git show` / `git ls-tree` only) |
| `scripts/test-gfp-xlate.sh` | compile+run the translation harness against real per-tag values | writes only to a temp dir (`--keep` to inspect) |
| `tests/gfp-xlate-harness.c` | the harness itself; **not** part of the module build | — |

Adding a family to `kernel-flag-abi.py` is one line in `FAMILIES` (header paths +
a name pattern). Adding a flag-bearing wrapper to the probe is one line in
`TARGETS` (symbol, argument index, family label). If a future `*.o_shipped` drop
adds a call site, re-run the probe first: a new constant is the thing most likely
to be silently wrong.
