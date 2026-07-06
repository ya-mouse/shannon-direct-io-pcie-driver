---
name: shannon-dev-lifecycle
description: End-to-end development lifecycle for the shannon.ko driver - fix code locally, rsync to the remote baremetal host, build, pack an initrd, boot QEMU with vfio-pci passthrough, wait the 5+ minute device startup, then validate data integrity or debug the kernel. Use when the user wants to run the full edit-build-boot-test loop, asks how to test a driver change, or needs to validate Shannon block-device behavior.
---

# Shannon driver development lifecycle

This is the canonical loop: edit locally → rsync → build → initrd → boot QEMU
→ wait for device init → validate/debug. The repo ships scripts for every
step; the one-shot is `scripts/dev-cycle.sh`.

## Remote layout (on the baremetal SSH host)

| path | contents |
|---|---|
| `~/shannon-src/` | the driver source (rsynced from this repo, build artifacts excluded) |
| `~/shannon-qemu/` | QEMU work dir: `vmlinuz-<kver>`, `initrd.img`, optional `qemu-bundle/` |
| `/lib/modules/<kver>/build` | kernel headers (auto-installed by `build-module.sh` if missing) |

## One-shot

```
scripts/dev-cycle.sh --host <ssh-host> --kernel <kver> --all [--gdb] [--tmux shannon] [--no-release]
```

This runs steps 0–6 below (step 0 releases the host; use `--no-release` to skip
if you know the host is clean). It does **not** wait for the device or run I/O —
you do that in steps 7–8 because the wait is long and interactive.

## Step-by-step

### 0. Release the host (mandatory before any QEMU session)

If the host shannon driver is loaded or a previous QEMU session is still up,
the vfio-pci bind will fail (or the host driver races the guest). Release first:

```
scripts/release-host.sh --host <host> --tmux shannon --all [--reset] [--json]
# MCP: shannon_release_host {host, tmux:"shannon", all:true}
```

It: kills the `shannon` tmux session (frees vfio-pci devices), unmounts
`/dev/df*` (and `fuser -k`s holders), unbinds each device from the host
`shannon` driver, `rmmod shannon` (+ `shannon_nand_emu`), and optionally
(`--reset`) does a PCI function-level reset. Idempotent. JSON:
`{ok, killed_qemu, unmounted, unbound, rmmod, reset, modules_loaded}`.

### 1. Fix locally

Edit the open-source wrapper files in this repo (`shannon_block.c`,
`shannon_module_init.c`, `shannon_device.c`, `shannon_pci.c`, …, plus headers
under `shannon_port.h`'s include set, plus `Makefile`/`Kbuild` if the objcopy
symbol set or object list must change). **Never** edit `*.o_shipped`. See
`docs/driver-structure.md` §2 for the wrapper→kernel-header map.

### 2. rsync to remote

```
scripts/rsync-src.sh --host <host>
```

Excludes `*.o *.ko *.mod* .git .tmp_* Module.symvers modules.order` so only
source ships. Lands at `~/shannon-src/`.

### 3. Build remotely

```
scripts/build-module.sh --host <host> --kernel <kver>
```

Installs `linux-headers-<kver>` if `/lib/modules/<kver>/build` is missing,
runs `make KERNELVER=<kver> clean` then `make -j$(nproc) KERNELVER=<kver>
shipped modules`, and prints the `shannon.ko` path + `modinfo` summary.

### 4. Pack the initrd

```
scripts/make-initrd.sh --host <host> --kernel <kver>
```

Builds `~/shannon-qemu/initrd.img`: takes a busybox initrd root (seed via
`--initrd-template <dir|tarball>`, or reuse an existing one — the script
preserves `/bin` busybox from the template), drops `shannon.ko` at
`/lib/modules/<kver>/kernel/drivers/block/`, writes an `init` that mounts
`/proc` `/sys` `/dev`, loads the driver with
`shannon_fast_boot_enable=1 shannon_skip_epilog=1`, and drops to a shell on
`/dev/console`. Also copies `vmlinuz-<kver>` from `/boot` to `~/shannon-qemu`
if missing.

For an **integrity test** run (not debug), edit the `init` heredoc in
`scripts/make-initrd.sh` to drop `shannon_skip_epilog=1` so the device does
full recovery.

### 5. Bind Shannon devices to vfio-pci

```
scripts/driver-bind.sh --host <host> --all
```

(See **shannon-pcie-passthrough** skill for IOMMU preconditions and manual
BDF lists.)

### 6. Boot QEMU

```
scripts/qemu-shannon-run.sh --host <host> --kernel <kver> --all --tmux shannon
# add --gdb for kernel debugging (see shannon-kernel-debug skill)
# add --capture-only for headless serial-log capture (no interactive console)
# add --qemu '<bundle path>' if using a source-built qemu (see shannon-qemu-install skill)
# add --json for a machine-readable launch summary
```

Launches QEMU in a detached tmux session `shannon` on the remote host. The
guest boots the busybox initrd and auto-`insmod`s the driver. The serial
console is `mon:stdio` **and** continuously teed to `~/shannon-qemu/serial.log`
(via `tmux pipe-pane`), so you have both an interactive console and a complete
non-lossy log. With `--capture-only` it runs headless (`-serial file:`) for pure
log capture.

### 7. Wait for device init (5+ minutes) — DO NOT SKIP

After `insmod`, the driver reads MBR then walks ~1000 superblocks of epilog
recovery. On a 6.4 TB G3i device this is ~3.5–4 minutes; budget **≥5 minutes**
(and more without `shannon_skip_epilog`, or for larger devices). The device is
not ready for I/O until dmesg shows both:

```
shn_info: Attached Direct-IO PCIe Flash /dev/sctd as block device /dev/dfd:
shn_info: Probed Direct-IO PCIe Flash /dev/sctd: ...
```

Wait loop — prefer the console helper (polls the serial log, detects crashes,
returns JSON):

```
scripts/qemu-console.sh --host <host> --tmux shannon wait-ready --timeout 600
# --json: {"ok":true,"ready":true,"crash":false,"elapsed_s":312,"last_lines":[...]}
# exit 0 = ready, 1 = timeout, 2 = crash detected
```

Equivalent manual loop (poll the serial log written by qemu-shannon-run.sh):

```
host=<host>; sess=shannon
for i in $(seq 1 60); do                 # up to ~10 minutes
  out=$(ssh "$host" "tail -n 4000 '~/shannon-qemu/serial.log' 2>/dev/null || true")
  echo "$out" | grep -q 'Probed Direct-IO PCIe Flash' && { echo "READY"; break; }
  echo "$out" | grep -qiE 'kernel BUG|Oops:|Call trace:|shn_alarm' && { echo "CRASH"; break; }
  sleep 10
done
ssh "$host" "tmux capture-pane -t $sess -p -S -2000"   # dump the console
```

If you see the epilog progress lines (`recover N00 superblock's epilog done`)
every ~25 s, the driver is healthy — just slow. If progress stalls for >2 min
mid-recovery, treat it as a hang and capture the log / attach gdb.

### 8. Validate integrity

From the guest shell — drive it from outside via the console helper (the
initrd ships `validate-integrity.sh` at `/usr/local/bin`):

```
# send the command (interactive tmux console):
scripts/qemu-console.sh --host <host> --tmux shannon send 'validate-integrity.sh /dev/dfd --json'
# then read the JSON result line from the serial log:
scripts/qemu-console.sh --host <host> --tmux shannon tail --lines 60

# or, if booted --capture-only (no console), validate isn't interactive —
# reboot interactive first, or embed the validate call in the init /init.
```

It writes a urandom pattern, reads it back, sha256-compares, and does a 4
K-aligned write/read at a 1 GiB offset. `--json` emits
`{ok, device, size_mb, checks:[{name, ok, ...}]}`.

Higher-level checks:

```
fdisk -l /dev/dfd
mkfs.xfs /dev/dfd1     # exercises the bio path that crashed on 6.8 (FAILURES.md)
mount /dev/dfd1 /mnt && ...
```

### 9. (Optional) Load test with fio

The in-tree workload is `tests/fio-workload.sh` (fio libaio: randread 4 K,
seqread 1 M, randwrite 4 K, seqwrite 1 M). On a full rootfs guest install
`fio` and run that script against `/dev/dfd`:

```
tests/fio-workload.sh /dev/dfd randread     # or seqread|randwrite|seqwrite|all
```

### 10. Debug

If step 7 reported a crash or step 8 failed, switch to the
**shannon-kernel-debug** skill: reboot with `--gdb`, forward `tcp::3333`, attach
gdb, `add-symbol-file shannon.ko <base>`, set breakpoints at the known 6.8
sites (`blk_throtl_register`, `shannon_convert_bio`,
`check_pending_command_queue`).

## Iterating

After a code change you only need steps 2–4 (rsync → build → initrd) then
reboot the existing QEMU:

```
scripts/rsync-src.sh --host <host> && \
scripts/build-module.sh --host <host> --kernel <kver> && \
scripts/make-initrd.sh --host <host> --kernel <kver> && \
ssh <host> "tmux kill-session -t shannon 2>/dev/null; tmux new-session -d -s shannon 'cd ~/shannon-qemu && exec qemu-system-x86_64 ...'"
```

(or just re-run `scripts/dev-cycle.sh`.)

## Common pitfalls

- **Forgetting to wait.** Issuing I/O during epilog recovery hangs or returns
  errors; you'll misdiagnose a working driver as broken.
- **`shannon_skip_epilog=1` left on for integrity tests.** It skips recovery —
  fine for bring-up, wrong for data verification.
- **Guest RAM too small.** Epilog recovery is memory-heavy; use `-m 16g`
  (default) or more for multiple devices.
- **Stale vfio binding.** If `qemu-shannon-run.sh` fails with `vfio: ... no
  such device`, re-run `driver-bind.sh --all`; the host may have regrabbed the
  device after a host reboot.
- **Wrong qemu.** Stock focal qemu (4.2) cannot do the vfio features needed;
  install 9.2+ via the **shannon-qemu-install** skill.
