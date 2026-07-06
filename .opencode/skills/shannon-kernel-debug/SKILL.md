---
name: shannon-kernel-debug
description: Debug the shannon.ko kernel driver inside a QEMU guest using gdb over a forwarded tcp port, including loading shannon.ko symbols, setting breakpoints at known 6.8 crash sites, and interpreting shn_* dmesg log levels and the epilog-recovery startup sequence. Use when the user reports a driver crash, oops, NULL deref, command-queue timeout, or wants to trace the driver/probe/bio path.
---

# Kernel debugging the Shannon driver via QEMU

The driver runs in a QEMU guest on the remote baremetal host. Debug it with gdb
attached to QEMU's gdb stub, plus `dmesg` on the serial console.

## 1. Boot QEMU with the gdb stub

```
scripts/dev-cycle.sh --host <host> --kernel <kver> --all --gdb --tmux shannon
# or just the launch step:
scripts/qemu-shannon-run.sh --host <host> --all --gdb --tmux shannon
```

`--gdb` adds `-gdb tcp::3333` and `nokaslr` (addresses are stable, so
`add-symbol-file` bases stay valid across boots).

## 2. Port-forward and attach gdb

On your local machine:

```
ssh -L 3333:localhost:3333 <host>            # forward the stub port, keep open
gdb ~/shannon-qemu/vmlinuz-<kver>            # or a vmlinux with debug symbols
(gdb) target remote :3333
(gdb) continue
```

If the host doesn't have the debug kernel, at minimum point gdb at the
`vmlinuz-<kver>` in `~/shannon-qemu` (no symbols, but you can still set
breakpoints on addresses). For full kernel symbols, build/install the
`linux-image-<kver>-dbgsym` package on the host and use its `vmlinux`.

## 3. Load shannon.ko symbols

The module loads late (the initrd `insmod`s it). Get its runtime base from the
guest and add it:

```
# in the guest (over the tmux console):
cat /proc/modules | grep shannon
#   shannon 4666184 0 - Live 0xffffffffc0201000 (O)
#                                            ^^^^^^^^^^^^^^^^ base

# in gdb:
(gdb) add-symbol-file ~/shannon-src/shannon.ko 0xffffffffc0201000
```

`/proc/modules` prints the `.text` base; `add-symbol-file <ko> <base>` maps
the module's sections. (The full gdb recipe, including the probe backtrace
anchors, is in `docs/crash-traces.md`.)

To find the base without dropping to the guest console, use gdb itself:

```
(gdb) b local_pci_probe        # in vmlinux
(gdb) c
# once hit, the shannon module is loaded; then:
(gdb) info modules
(gdb) add-symbol-file ~/shannon-src/shannon.ko <text-base-from-info-modules>
```

## 4. Useful breakpoints

Order roughly matches the probe → attach → add-disk → IO path:

```
(gdb) b shannon_probe            # core entry from pci_driver
(gdb) b shannon_probe_wrapper    # open-source wrapper in shannon_module_init.c
(gdb) b shannon_init_hardware    # core: pci/dma setup
(gdb) b get_pci_info             # shannon_pci.c (crash site in dist/README.md)
(gdb) b get_pci_bus_info
(gdb) b shannon_attach           # core: device bring-up
(gdb) b shannon_attach_sdev      # core→wrapper override (weakened by Makefile)
(gdb) b shannon_add_disk         # shannon_block.c -> device_add_disk
(gdb) b blk_throtl_register      # in vmlinux: 6.8 crash site #1
(gdb) b device_add_disk
(gdb) b shannon_make_request     # shannon_block.c: bio entry
(gdb) b shannon_convert_bio      # shannon_block.c: 6.8 crash site #2
(gdb) b shannon_submit_bio       # shannon_module_init.c: 6.x submit_bio
(gdb) b check_pending_command_queue   # core watchdog: 6.8 issue #3
```

Symbol availability: wrappers (open-source) resolve directly. Core symbols
(`shannon_probe`, `shannon_init_hardware`, `check_pending_command_queue`, …)
resolve from `shannon.ko` after `add-symbol-file` because the `.o_shipped`
relocations are linked into the final `.ko`. Inspect raw core symbols with
`nm shannon_main.o_shipped` (e.g. `nm shannon_main.o_shipped | grep
shannon_probe`).

## 5. Reading `dmesg` — driver log levels & startup

The driver prints with custom `shn_*` levels; map them to severity:

| prefix | meaning |
|---|---|
| `shn_dbg` | debug trace (queue/disk alloc, sysfs links) |
| `shn_info` (`<3>`) | informational (recovery progress, attach) |
| `shn_log` (`<3>`) | normal log |
| `shn_warn` | warning (e.g. `shannon_hwmon_init` failure — **non-fatal**) |
| `shn_alarm` | **alarm** (e.g. `check_pending_command_queue` timeout) |

### Normal startup sequence (expect ~5+ minutes)

```
shn_info: dfd: get 0 available mbr information.
shn_info: retry to read mbr in 4k mode.
shn_info: get mbr information successfully. max_update=22.
shn_info: sctd: flash id: ...; HAL version: 8, T: 35
shn_info: dfd: clk = 5. power_budget=0xf.
shn_info: dfd: max_available_luns=256, max_available_groups=8.
shn_info: dfd: start recover epilog head. ... done.
shn_info: dfd: start recover map table. ... try to slowpath recover map table(0x12).
shn_info: dfd: start recover epilog.
shn_info: dfd: recover 100/200/.../1000 superblock's epilog done.   # ~25s per 100
shn_info: dfd: recover epilog done.
shn_info: dfd: start recover hot/cold active super block. ... done.
shn_info: refresh_sequence=10. dfd: mbr_update=0x17.
shn_warn: shannon_hwmon_init(): ... hwmon_device_register failed!      # non-fatal
shn_log: sctd: cannot initialize hwmon devices, move on.
shn_dbg: shannon_attach_sdev(): sdev=... name=sctd logicb_size=4096.
shn_dbg: shannon_alloc_disk(): ...
shn_dbg: shannon_init_gendisk(): disk_name=dfd, major=251, minors=64, ...
shn_dbg: shannon_set_capacity(): disk=... size=12500000768
shn_info: Attached Direct-IO PCIe Flash /dev/sctd as block device /dev/dfd:
shn_info: Probed Direct-IO PCIe Flash /dev/sctd: model: Direct-IO G3i-Ali 6400G, ...
```

The driver is **not** ready for I/O until `Attached` **and** `Probed` appear.
The epilog walk alone is ~3.5–4 min on a 6.4 TB device; budget ≥5 min, more
without `shannon_skip_epilog`.

## 6. Known 6.8.0 (noble) crash sites

Full traces and the gdb recipe are in **`docs/crash-traces.md`** (blk-throttle
BUG, `shannon_convert_bio` oops, `check_pending_command_queue` alarm, and the
normal startup sequence).

### #1 `blk_throtl_register` BUG — `block/blk-throttle.c:2432`

```
kernel BUG at block/blk-throttle.c:2432!
RIP: blk_throtl_register+0xa5/0xd0
Call Trace:
 blk_register_queue -> device_add_disk -> shannon_add_disk [shannon]
 -> shannon_attach_sdev -> shannon_attach -> shannon_probe
```

Happens while adding the disk. The 6.8 block layer rejects the queue because
the wrapper's queue-limit / blk-mq setup is stale. Look in `shannon_block.c`
(`shannon_create_blkqueue`, `shannon_blk_queue_*`, `shannon_init_gendisk`,
`shannon_add_disk`) and `shannon_module_init.c` (`block_device_operations`,
`shannon_submit_bio`). On 6.8 the queue must be blk-mq with valid `limits`
**before** `device_add_disk`.

### #2 `shannon_convert_bio` NULL deref — `+0x110`

```
BUG: kernel NULL pointer dereference, address: 0x000000000000000c
RIP: shannon_convert_bio+0x110/0x530 [shannon]
Call Trace:
 shannon_make_request -> shannon_submit_bio [shannon]
 -> __submit_bio -> submit_bio_noacct -> submit_bio   (mkfs.xfs)
```

Triggered by `mkfs.xfs` issuing bios. The bio-conversion path dereferences a
field that moved/was removed in 6.8 (`bi_iter`, `bi_bdev->bd_disk`,
`bi_vcnt`, `bio_for_each_segment`). Fix in `shannon_block.c`
`shannon_convert_bio` / `shannon_make_request`.

### #3 `check_pending_command_queue` timeout alarm

```
shn_alarm: check_pending_command_queue(): scta: lunset=0, cq_tail_tmp=0x398,
  cq_tail=0x398, cq_head=0x398, sq_head=0x350, hw_cq_head=0x398,
  last_active_time=..., curr_time=..., timeout=36157ms.
```

The core's command-queue watchdog fired: `cq_tail == cq_head` and no progress
for `timeout` ms. Usually means IRQ/MSI-X delivery is broken on this kernel
(the card completed nothing) or `submit_bio`/`make_request` stalled. Check
`shannon_pci.c` MSI-X setup (`pci_alloc_irq_vectors` vs the old
`pci_enable_msix` path) and confirm the guest sees IRQs:
`cat /proc/interrupts | grep shannon`.

## 7. Capturing crashes

- QEMU cmdline already sets `panic=5` (reboot 5s after panic) and
  `console=ttyS0`; the whole serial stream is continuously logged to
  `~/shannon-qemu/serial.log` by `qemu-shannon-run.sh` (interactive `tmux
  pipe-pane`, or `-serial file:` with `--capture-only`). Inspect it without
  disturbing the guest:
  ```
  scripts/qemu-console.sh --host <host> --tmux shannon tail --lines 2000
  scripts/qemu-console.sh --host <host> --tmux shannon grep 'Call trace'
  scripts/qemu-console.sh --host <host> --tmux shannon crash-check      # JSON
  ```
- For post-mortem, add `-no-reboot` (drop `panic=5`) so the guest hangs on
  panic and you can inspect via gdb still attached.
- The serial log is the primary guest log; the host's `dmesg` is irrelevant
  for the guest (it only shows vfio-pci bind events).

## 8. Module params that change debug behaviour

| param | effect when set |
|---|---|
| `shannon_skip_epilog=1` | skip the ~4-min epilog recovery — fast bring-up, **not** for integrity tests |
| `shannon_fast_boot_enable=1` | skip slow boot verification |
| `shannon_disable_intervel_refresh_mbr=1` | disable periodic MBR refresh |
| `shannon_auto_attach=0` | require manual `shannon-attach` (lets you probe-then-attach one device at a time) |
| `shannon_use_iosched=1` | register an I/O scheduler (changes the make_request/blk-mq path) |
| `shannon_scsi_mode=1` | expose as SCSI host (different probe path) |

The initrd `init` (written by `scripts/make-initrd.sh`) loads with
`shannon_fast_boot_enable=1 shannon_skip_epilog=1` by default for quick
debug; for an integrity run, rebuild the initrd without those (edit the
`init` heredoc in `scripts/make-initrd.sh` or pass `--no-skip-epilog` if you
add that flag).
