# Shannon Direct-IO PCIe driver — agent notes

This repo (`shannon-module_3.4.3.1`) builds `shannon.ko`, a partially
open-sourced block driver for Shannon Direct-IO PCIe flash (PCI
`1cb0:0275`). Read **`docs/driver-structure.md`** first for the full
architecture; summary below.

## What is open vs. proprietary

- The **FTL/flash core** is shipped only as `*.o_shipped` (no C source):
  `shannon_main`, `shannon_ftl`, `shannon_prefetch`, `shannon_boot`,
  `shannon_epilog`, `shannon_err_handler`, `shannon_ns`, `shannon_ioctl`,
  `shannon_scsi_cmd`.
- The **wrappers** (`.c`/`.h`) translate a stable internal `shannon_*()` API
  onto the running kernel. Porting = editing wrappers + the Makefile's
  `objcopy` symbol tricks, **never** the core. Key files:
  `shannon_module_init.c` (entry/ops), `shannon_block.c` (queue/disk/bio,
  most 6.x work), `shannon_device.c` (in-flight accounting), `shannon_pci.c`
  (PCI/MSI-X), `shannon_sysfs.c` (hwmon).
- `shannon_port.h` is the umbrella header; `shannon_block.h` documents which
  kernel header each wrapper group mirrors.
- `decompiled-probe.txt` has reverse-engineered `shannon_dev` offsets
  (`0xed28` bytes); `shannon_device.c.diff` is a model 5.8 port.
- The core references only **five** kernel symbols directly (`printk`, `memcpy`,
  `strcmp`, `strncpy`, `dump_stack`); its other 301 external references are all
  satisfied by the wrappers. It also has **no `__versions` section**, so
  modversions does not even type-check those five.

## Build (on the remote baremetal host with `linux-headers-<kver>`)

```
make KERNELVER=6.8.0-48-generic shipped modules
```

The Makefile runs `objcopy --redefine-sym printk=_printk` (≥5.15) and
`--weaken-symbol shannon_attach_sdev` on each `*.o_shipped`, then the kernel
build compiles the wrappers and links `shannon.ko`.

## Flag / constant ABI drift (the silent porting hazard)

Constants inside the wrappers are recompiled per kernel and are therefore always
correct. The exception is a kernel-derived **flag value frozen into
`*.o_shipped`** and forwarded by a wrapper: `objcopy` can fix symbol *names*, but
nothing can fix a stale *value*. No compiler, CRC or loader check catches it —
modversions covers types, and `gfp_t` is the same type whether it holds
`GFP_NOIO` or garbage.

What the core actually bakes in (from `scripts/probe-shipped-flags.py`): `gfp
0x10` ×127, `0x220` ×26, `0x200` ×4, `SLAB_HWCACHE_ALIGN 0x2000` ×2,
`BIO_RW_PRIO 16` ×1. In its own 2.6.x/3.x-era encoding `0x10` is `GFP_NOIO`;
here it is `___GFP_RECLAIMABLE`, i.e. **no reclaim at all**, which also defeats
`mempool_alloc()`'s wait-for-refill (gated on `__GFP_DIRECT_RECLAIM`) in the sbio
I/O path, and on v6.19 makes `__vmalloc` print `Unexpected gfp … Fix your code!`.

Translated in `shannon_gfp_legacy.h`, applied at every gfp-forwarding wrapper,
and logged at load as `shn_info: legacy gfp 0x10 -> 0xc00 (GFP_NOIO)`. Because
the same wrappers are also called by our own code with *this* kernel's values,
translation is gated on a value classifier plus `BUILD_BUG_ON` assertions, never
applied blindly.

```
scripts/probe-shipped-flags.py                       # constants baked into the core
scripts/kernel-flag-abi.py --tree <linux-git> \
    --tags v5.15,v6.19 --family all --only-drift     # what the kernel calls them
scripts/test-gfp-xlate.sh --tree <linux-git>         # translation tests, 7 kernels
```

`kernel-flag-abi.py` uses only `git show`/`git ls-tree` — **never check out or
build a shared kernel tree**. Full method, findings, verified version boundaries
and upstream commits: **`docs/flag-abi-drift.md`**. Re-run the probe after any new
`*.o_shipped` drop and the flag tests after any kernel bump.

## Canonical development lifecycle

Release the host → fix locally → rsync to remote → build remotely → pack
initrd → boot QEMU with vfio-pci passthrough → wait for device init →
validate/debug. The repo ships scripts that implement every step (see
`scripts/`); the one-shot is `scripts/dev-cycle.sh`. Full detail in the
**shannon-dev-lifecycle** skill.

```
scripts/release-host.sh   --host <host> --all          # step 0: unload host driver, free devices
scripts/dev-cycle.sh --host <ssh-host> --kernel <kver> --all [--gdb] [--tmux shannon]
```

**Always release the host before a QEMU session** (`release-host.sh`, or
`dev-cycle.sh` does it as step 0, or `qemu-shannon-run.sh --release`): it kills
any running QEMU, unmounts `/dev/df*`, unbinds devices from the host `shannon`
driver, and `rmmod shannon`. Otherwise vfio-pci bind fails or the host driver
races the guest.

- Remote layout: source at `~/shannon-src`, QEMU assets at `~/shannon-qemu`
  (`vmlinuz-<kver>`, `initrd.img`, optional `qemu-bundle/`).
- The Shannon device **takes 5+ minutes** to initialise after `insmod`
  (epilog recovery walks ~1000 superblocks). Always wait for the
  `Attached Direct-IO PCIe Flash` / `Probed Direct-IO PCIe Flash` dmesg lines
  before issuing I/O.
- Validate with `scripts/validate-integrity.sh /dev/dfd` (write pattern, read
  back, sha256-compare). For thorough load testing use fio
  (`tests/fio-workload.sh`).

## PCI passthrough into QEMU

Baremetal host = the remote SSH host that physically holds the Shannon card(s).
Bind devices (`1cb0:0275`) to `vfio-pci`, then launch QEMU with one
`-device vfio-pci,host=DD:DD.D` per device. IOMMU must be on
(`intel_iommu=on iommu=pt` in grub). See the **shannon-pcie-passthrough**
skill; QEMU install (9.2/10+) is covered by **shannon-qemu-install**.

```
scripts/shannon-pci-list.sh --host <host> --pretty        # list devices
scripts/driver-bind.sh    --host <host> --all             # bind to vfio-pci
scripts/qemu-shannon-run.sh --host <host> --all --tmux shannon
```

`qemu-shannon-run.sh` accepts explicit BDFs, `--all` (auto-detect), `--list`,
and `--dry-run`.

## Kernel debugging

Boot with `--gdb` (adds `-gdb tcp::3333` + `nokaslr`); port-forward
`ssh -L 3333:localhost:3333 <host>` and `gdb vmluz-<kver>` →
`target remote :3333` → `add-symbol-file shannon.ko <base>` (base from
`/proc/modules` in guest). See the **shannon-kernel-debug** skill for
breakpoints and the known 6.8 crash sites.

## Known 6.8.0 (noble) failures (traces in `docs/crash-traces.md`)

1. `blk_throtl_register` BUG at `block/blk-throttle.c:2432` during
   `device_add_disk` → fix queue-limit/blk-mq setup in `shannon_block.c`.
2. `shannon_convert_bio` NULL deref at `+0x110` during `mkfs.xfs` → fix
   bio-conversion in `shannon_block.c` for the 6.8 `bio` API.
3. `check_pending_command_queue` timeout alarm after long runtime →
   IRQ/MSI-X delivery or `submit_bio`/`make_request` stall; check
   `shannon_pci.c` MSI-X setup.

## Module parameters (debug)

`shannon_fast_boot_enable=1`, `shannon_skip_epilog=1` (skip the long epilog
recovery for fast bring-up — not for integrity tests), 
`shannon_disable_intervel_refresh_mbr=1`, `shannon_auto_attach=0`,
`shannon_use_iosched=1`, `shannon_scsi_mode=1`.
