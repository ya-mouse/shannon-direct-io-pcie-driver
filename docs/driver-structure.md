# Shannon Direct-IO PCIe driver — structure & porting notes

This document describes how the `shannon.ko` module is organised, what is
open-source vs. proprietary, and how kernel-version porting is done. It is the
reference the `shannon-driver-dev` agent uses before touching code.

## 1. Big picture

`shannon.ko` is a **partially open-sourced** block-device driver for Shannon
Direct-IO PCIe flash (e.g. *Direct-IO G3i-Ali 6400G*, PCI vendor:device
`1cb0:0275`). It exposes:

- block devices `/dev/df[a-z]` (major 251, 64 minors each), and
- character/control devices `/dev/sct[a-z]` (miscdevice), used by the
  `shannon-attach` user-space utility to attach an `sct*` controller to a `df*`
  block device.

The driver is split into two layers:

```
              +---------------------------------------------------+
   kernel  < |  OPEN-SOURCE WRAPPERS  ( .c / .h )                 |
   API      |  shannon_module_init, shannon_pci, shannon_block,   |
              |  shannon_device, shannon_sysfs, shannon_scsi,       |
              |  shannon_sched, shannon_cdev, shannon_dma,          |
              |  shannon_kcore, shannon_time, shannon_workqueue,    |
              |  shannon_waitqueue, shannon_file, shannon_scatter,  |
              |  shannon_err_injection                              |
              +----------------------+-------------------------------+
                                     | calls  shannon_*()  wrapper API
              +----------------------v-------------------------------+
   proprietary                     |  PRECOMPILED CORE  ( *.o_shipped )  |
   (no source)        shannon_main, shannon_ftl, shannon_prefetch,        |
              |  shannon_boot, shannon_epilog, shannon_err_handler,      |
              |  shannon_ns, shannon_ioctl, shannon_scsi_cmd             |
              +---------------------------------------------------------+
```

- The **core** (FTL, flash management, epilog recovery, ioctl, SCSI command
  engine) is shipped only as relocatable objects (`*.o_shipped`) — there is no
  C source for it in this repo. It was compiled against the
  `shannon_*` wrapper API, not against the kernel directly.
- The **wrappers** (`.c`/`.h`) translate that stable internal API onto the
  current kernel's API. Porting to a new kernel = editing the wrappers, never
  the core.

## 2. The portability shim (`shannon_port.h`)

`shannon_port.h` is the umbrella header the core includes. It pulls in all
sub-headers, each of which:

1. defines an **opaque type alias** for a kernel type, e.g.
   `shannon_pci_dev_t`, `shannon_gendisk_t`, `shannon_request_queue_t`,
   `shannon_bio_t`, `shannon_atomic_t`, `shannon_spinlock_t`,
   `shannon_workqueue_struct_t`, … and
2. declares the `shannon_*()` wrapper functions the core is allowed to call.

`shannon_block.h` is the clearest example — it is commented with the kernel
header each group mirrors:

| wrapper declarations in `shannon_block.h` | mirrors kernel header |
|---|---|
| `shannon_alloc_disk`, `shannon_init_gendisk`, `shannon_set_capacity`, `shannon_put_disk`, `shannon_add_disk`, `shannon_del_gendisk`, `get_gendisk_name` | `include/linux/genhd.h` |
| `shannon_register_blkdev`, `shannon_unregister_blkdev` | `include/linux/fs.h` |
| `shannon_create_blkqueue`, `shannon_blk_queue_block_size`, `shannon_blk_queue_max_hw_sectors`, `shannon_blk_queue_io_min/opt`, `shannon_blk_cleanup_queue`, `shannon_trim_setting`, `shannon_rotational_setting`, `shannon_queue_flag_set/clear`, `shannon_convert_bio`, `shannon_alloc/free_bounce_pages`, `shannon_copy_bounce_pages` | `include/linux/blkdev.h` |
| `get_bi_sector`, `shannon_bio_flagged`, `shannon_bio_data_dir`, `shannon_make_request`, `shannon_make_request_ns`, `shannon_convert_lreq`, `shannon_complete_fs_io` | `include/linux/bio.h` |
| `shannon_blk_mq_support_init/exit`, `shannon_blk_mq_free/init_tag_set`, `shannon_disk_request` | `include/linux/blk-mq.h` |

So when a kernel API changes, find the matching `shannon_*` wrapper, update its
declaration in the header and its implementation in the `.c` file. The core
keeps calling the same `shannon_*` name and needs no rebuild.

## 3. File inventory

### 3.1 Proprietary precompiled core (`*.o_shipped`, no source)

| file | role |
|---|---|
| `shannon_main.o_shipped` | main device/FTL logic: `shannon_probe`, `shannon_init_hardware`, `shannon_attach`, `shannon_attach_sdev`, `alloc_sbio`/`free_sbio`, `submit_sbio_task` |
| `shannon_ftl.o_shipped` | flash translation layer (PBA/LBA mapping, GC) |
| `shannon_prefetch.o_shipped` | read prefetch |
| `shannon_boot.o_shipped` | device boot/init handshake |
| `shannon_epilog.o_shipped` | epilog & recovery — emits the `recover N00 superblock's epilog done` messages (the multi-minute startup) |
| `shannon_err_handler.o_shipped` | error handling / AER |
| `shannon_ns.o_shipped` | namespace management |
| `shannon_ioctl.o_shipped` | ioctl implementation |
| `shannon_scsi_cmd.o_shipped` | SCSI command engine |

Inspect their symbols with `nm shannon_main.o_shipped` (e.g. `nm ... | grep
printk`). They are **relinked** into `.o` at build time by the Makefile (see
§4).

Two facts about them matter when porting, and both are easy to get wrong:

- They reference only **five** kernel symbols directly (`printk`, `memcpy`,
  `strcmp`, `strncpy`, `dump_stack`); the other 301 external references are
  satisfied by the wrappers. They also carry **no `__versions` section**, so
  modversions does not type-check even those five.
- Every kernel-derived *constant* they pass to a wrapper is frozen at the vendor
  build kernel's encoding (2.6.x/3.x-era, per `.comment`: gcc 4.1.2). Flag
  **values** are not types, so no CRC, compiler or loader check can catch drift.
  See §9 and **`docs/flag-abi-drift.md`**.

### 3.2 Open-source wrappers (`.c`)

| file | role | porting hot spots |
|---|---|---|
| `shannon_module_init.c` | module `init`/`exit`, `pci_driver` registration, `shannon_probe_wrapper`, block-device ops (`submit_bio`, `getgeo`, `revalidate`), miscdevice glue | `submit_bio` signature (6.0+), `gendisk`/`block_device_operations`, `blk_alloc_disk` vs `alloc_disk` |
| `shannon_block.c` | block layer: queue creation, disk alloc/add, `shannon_convert_bio`, `shannon_make_request`, blk-mq tag set | **most 6.x work lands here**: `blk_throtl_register`, queue limits struct, `bio`/`bi_bdev` API, `blk-mq` ops |
| `shannon_device.c` | `device_create`/class, in-flight accounting (`shannon_disk_in_flight`, `shannon_start_io_acct`) | `part_stat`/`in_flight` API (5.8+, 6.x); see `shannon_device.c.diff` for the 5.8 port |
| `shannon_pci.c` | PCI API wrappers + `get_pci_info`, MSI/MSI-X, AER, link retrain | `pci_enable_msi`→`pci_alloc_irq_vectors`, `dma_alloc_coherent` (5.10+) |
| `shannon_sysfs.c` | sysfs & hwmon attributes | `hwmon_device_register` (the `shannon_hwmon_init` warning) |
| `shannon_scsi.c` | SCSI host adapter emulation | `scsi_host_alloc`/`scsi_add_host` signatures |
| `shannon_sched.c` | I/O scheduler hook (`shannon_use_iosched`) | elevator/blk-mq scheduler API |
| `shannon_cdev.c` | `miscdevice` for `/dev/sct*` control nodes | `miscdevice` API |
| `shannon_dma.c` | real (non-emu) DMA mapping wrappers | `dma_map_sg` signatures |
| `shannon_kcore.c` | core helpers and exported `shannon_*` impls shared with core | |
| `shannon_time.c` `shannon_workqueue.c` `shannon_waitqueue.c` `shannon_file.c` `shannon_scatter.c` | time, workqueue, wait-queue, file, scatter-gather wrappers | `ktime`/`jiffies`, `alloc_workqueue`, `wait_queue_head`, `sg` API |
| `shannon_err_injection.c` | debug error-injection interface | |

### 3.3 Headers (the shim)

`shannon_port.h` (umbrella) includes: `shannon_kcore.h` (root types),
`shannon_block.h`, `shannon_dma.h`, `shannon_pci.h`, `shannon_device.h`,
`shannon_sched.h`, `shannon_sysfs.h`, `shannon_scsi.h`, `shannon_waitqueue.h`,
`shannon_workqueue.h`, `shannon_file.h`, `shannon_scatter.h`,
`shannon_list.h`, `shannon_memblock.h`, `shannon_time.h`, `shannon_config.h`.

### 3.4 Reverse-engineering & porting references

| file | use |
|---|---|
| `decompiled-probe.txt` | reconstructed `shannon_probe` + `struct shannon_dev` field offsets (size `0xed28` bytes). Essential when interpreting core crashes or wiring new wrapper fields. |
| `shannon_device.c.diff` | the diff that ported `shannon_device.c` to the 5.8+ in-flight/io-accounting API. Model for new ports. |
| `check_user_logicb_size.S` | assembly sanity check for `logicb_size`. |

## 4. Build system

`Makefile` builds in two phases:

1. **`shipped`** — `objcopy` each `*.o_shipped` into a `*.o`:
   - `--redefine-sym printk=_printk` for kernels ≥ 5.15 (the kernel renamed
     `printk`→`_printk`; the proprietary core still emits `printk` relocations,
     so they must be redirected or the module won't link).  `printk` is one of
     only five kernel symbols the core references directly — see §3.1 and §9.
     Note that objcopy fixes symbol *names* only; it cannot fix stale flag
     *values*, which is what §9 is about.
   - `--weaken-symbol shannon_attach_sdev` so the open-source
     `shannon_attach_sdev` override in `shannon_block.c`/`shannon_module_init.c`
     wins over the core's copy.
2. **`modules`** — `make -C /lib/modules/$(KERNELVER)/build M=$(pwd) modules`,
   compiling the open-source `.c` files and linking everything into
   `shannon.ko` via `Kbuild`.

Typical invocation (on the remote baremetal host that has the matching
`linux-headers-<kver>` installed):

```
make KERNELVER=6.8.0-48-generic shipped modules
```

`Kbuild` sets `EXTRA_CFLAGS += -DSHANNON_RELEASE` and
`INSTALL_MOD_DIR ?= extra/shannon`. `dkms.conf` (`PACKAGE_VERSION=3.4.3.1`)
packages it for DKMS; `Makefile.dkms`/`shannon.hook` are the DKMS hooks.

## 5. Module parameters

| param | effect |
|---|---|
| `shannon_fast_boot_enable=1` | skip slow boot verification (debug: faster bring-up) |
| `shannon_skip_epilog=1` | skip the multi-minute epilog recovery on probe (debug) |
| `shannon_disable_intervel_refresh_mbr=1` | disable periodic MBR refresh |
| `shannon_auto_attach=0` | do not auto-attach `sct*`→`df*`; attach manually via `shannon-attach` |
| `shannon_use_iosched=1` | register an I/O scheduler on the queue |
| `shannon_scsi_mode=1` | expose devices as SCSI hosts instead of plain block |

## 6. Runtime behaviour & timing

- **Startup is slow.** After `insmod shannon.ko`, the driver reads MBR, then
  runs epilog/map-table recovery. On a 6.4 TB G3i device this prints
  `recover N00 superblock's epilog done` every ~25 s for ~1000 superblocks
  (≈ 3.5–4 minutes), then `recover active super blocks done`,
  `Attached Direct-IO PCIe Flash /dev/sctd as block device /dev/dfd`, and
  finally `Probed Direct-IO PCIe Flash`. **Wait ≥ 5 minutes** after load
  before issuing I/O or declaring a probe failure.
- With `shannon_skip_epilog=1` the recovery is skipped for fast debug
  bring-up, but the device state may be inconsistent — use only for code
  bring-up, not data-integrity validation.
- `shannon_hwmon_init` failing with `hwmon_device_register failed!` is
  non-fatal (`cannot initialize hwmon devices, move on`) — it is not the cause
  of probe/I-O failures.

## 7. Known failure modes on 6.8.0 (noble)

These are the symptoms to look for when porting; crash traces and the gdb
recipe live in **`docs/crash-traces.md`** (kept in-tree).

1. **`blk_throtl_register` BUG at `block/blk-throttle.c:2432`** during
   `device_add_disk` → `blk_register_queue`. The wrapper creates the queue /
   sets limits in a way the 6.8 block layer rejects. Look in `shannon_block.c`
   (`shannon_create_blkqueue`, `shannon_init_gendisk`, `shannon_add_disk`)
   and `shannon_module_init.c` (`block_device_operations`,
   `shannon_submit_bio`). 6.8 requires `blk-mq` + correct `limits` before
   `device_add_disk`.
2. **`shannon_convert_bio` NULL pointer dereference at `+0x110`** during
   `mkfs.xfs` → `submit_bio`. The bio conversion path reads a field that moved
   or was removed in 6.8 (`bi_iter`, `bi_bdev->bd_disk`, `bi_vcnt`). Look in
   `shannon_block.c` `shannon_convert_bio` / `shannon_make_request`.
3. **`check_pending_command_queue` timeout alarm** (`cq_tail==cq_head`,
   `timeout=…ms`) — the command queue stalls after long runtime. The core's
   watchdog fires because no CQ progress is made. May indicate an IRQ/MSI-X
   delivery problem on the new kernel (look at `shannon_pci.c` MSI/MSI-X
   setup) or a `submit_bio`/`make_request` recursion stall.

## 8. Device / PCI facts

- PCI vendor:device = `1cb0:0275` (use to bind to `vfio-pci` or to find
  devices with `lspci -nn | grep 1cb0:0275`).
- Block devices: `/dev/dfa`, `/dev/dfb`, … (major 251). Char control devices:
  `/dev/scta`, `/dev/sctb`, … Attach with the `shannon-attach` utility from
  `shannon-utils`.
- The driver probes via `shannon_probe_wrapper` → `local_pci_probe` →
  `shannon_probe` (core) → `shannon_init_hardware` → `get_pci_info` →
  `shannon_attach` → `shannon_attach_sdev` → `shannon_add_disk`.

## 9. Flag / constant ABI drift (read before porting)

The core does not call kernel allocators, DMA or block APIs directly — it passes
**flag values** to `shannon_*()` wrappers that forward them. Those immediates
were frozen at the vendor's build kernel (2.6.x/3.x-era gfp.h), and a flag
*value* is invisible to every automated check: the compiler does not see the
core's source, modversions CRCs cover types only, and the module links and loads
regardless. The failure mode is behavioural, not a build error.

Concretely, `*.o_shipped` bakes in `gfp 0x10` (127 call sites — `GFP_NOIO` in its
own encoding, `___GFP_RECLAIMABLE` in ours), `0x220` (26), `0x200` (4),
`SLAB_HWCACHE_ALIGN 0x2000` (2, renumbered to `0x10` in v6.9) and
`BIO_RW_PRIO 16` (1, unrepresentable since `bi_flags` became `unsigned short` in
v4.8). Left untranslated these silently remove reclaim from every core
allocation, defeat the mempool forward-progress guarantee in the sbio path, and
trigger `Unexpected gfp … Fix your code!` from `mm/vmalloc.c` on v6.19+.

`shannon_gfp_legacy.h` holds the legacy encoding table and the translators;
`shannon_gfp_xlate()` is applied at every gfp-forwarding wrapper, and the mapping
is logged at module load (`shn_info: legacy gfp 0x10 -> 0xc00 (GFP_NOIO)`).
Because the same wrappers are also called by the open-source code with *this*
kernel's values, translation is gated on a value classifier plus
`BUILD_BUG_ON` assertions rather than applied blindly.

The audit method, the full findings table (including which families are safe),
the verified version boundaries with upstream commits, and the tooling —
`scripts/probe-shipped-flags.py`, `scripts/kernel-flag-abi.py`,
`scripts/test-gfp-xlate.sh` — are documented in **`docs/flag-abi-drift.md`**.
