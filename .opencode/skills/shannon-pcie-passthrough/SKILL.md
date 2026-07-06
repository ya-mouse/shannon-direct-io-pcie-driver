---
name: shannon-pcie-passthrough
description: Pass Shannon Direct-IO PCIe flash devices (PCI 1cb0:0275) through into a QEMU guest using vfio-pci on a remote baremetal host, for driver development and debugging. Use when the user wants to list, bind, or pass Shannon PCIe devices to QEMU, or asks about IOMMU/vfio setup, multi-device passthrough, or the qemu run/bind/list scripts.
---

# Shannon PCIe passthrough into QEMU

The Shannon card physically lives in a **remote baremetal host**. To run the
driver inside a QEMU guest on that host, unbind the device from the host
driver and bind it to `vfio-pci`, then give QEMU one
`-device vfio-pci,host=DD:DD.D` per Shannon device.

PCI vendor:device = **`1cb0:0275`**. Block devices appear as `/dev/df[a-z]`
(major 251); char control devices as `/dev/sct[a-z]`.

## Preconditions on the baremetal host

- IOMMU / VT-d enabled in BIOS.
- Kernel cmdline includes `intel_iommu=on iommu=pt` (Intel) or
  `amd_iommu=on iommu=pt` (AMD). Verify with:
  ```
  ssh <host> 'cat /proc/cmdline'
  ssh <host> 'dmesg | grep -iE "IOMMU|DMAR"'
  ```
  If missing, set `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, run
  `sudo update-grub`, and reboot the host.
- `vfio`, `vfio_iommu_type1`, `vfio_pci` modules available.

## 0. Release the host before passthrough (mandatory)

If the host `shannon` driver is loaded or a previous QEMU session still owns
the device, vfio-pci cannot bind. Release first:

```
scripts/release-host.sh --host <host> --tmux shannon --all
# MCP: shannon_release_host {host, tmux:"shannon", all:true}
```

It kills the `shannon` tmux session, unmounts `/dev/df*`, unbinds from the host
`shannon` driver, and `rmmod shannon`. (`driver-bind.sh` also unbinds the
current driver per-device, but `release-host.sh` does the full host-side
cleanup including unmount and module unload.) `dev-cycle.sh` runs this as
step 0; `qemu-shannon-run.sh --release` runs it inline.

## 1. List Shannon devices (reusable format)

```
scripts/shannon-pci-list.sh --host <host>            # one BDF per line: 0000:87:00.0
scripts/shannon-pci-list.sh --host <host> --auto     # space-separated, for $(...)
scripts/shannon-pci-list.sh --host <host> --pretty   # BDF + lspci description
```

`--auto` output is designed to be fed straight back into the run/bind scripts,
e.g.:

```
DEVS=$(scripts/shannon-pci-list.sh --host h1 --auto)
scripts/qemu-shannon-run.sh --host h1 $DEVS --tmux shannon
```

## 2. Bind devices to vfio-pci

```
scripts/driver-bind.sh --host <host> --all                 # all shannon devices
scripts/driver-bind.sh --host <host> 0000:87:00.0 0000:88:00.0   # explicit list
```

What it does (idempotent): `modprobe vfio_pci`; for each device — unbind from
current driver, register `1cb0 0275` with `vfio-pci/new_id`, bind. Requires
root (uses `sudo` locally / `ssh host sudo sh` remotely).

Verify the device is now on `vfio-pci`:

```
ssh <host> 'lspci -k | grep -A3 -i 1cb0:0275'
```

You should see `Kernel driver in use: vfio-pci`.

## 3. Launch QEMU with passthrough

```
scripts/qemu-shannon-run.sh --host <host> --all --tmux shannon
scripts/qemu-shannon-run.sh --host <host> 0000:87:00.0 --tmux shannon   # one device
scripts/qemu-shannon-run.sh --host <host> --all --gdb --tmux shannon    # for kernel gdb
scripts/qemu-shannon-run.sh --host <host> --all --dry-run               # print the qemu cmd
scripts/qemu-shannon-run.sh --host <host> --list                        # = shannon-pci-list --pretty
```

Options:

| option | meaning |
|---|---|
| `--host HOST` | SSH host (required) |
| `--kernel VER` | kernel version; uses `vmlinuz-<VER>` from `--qemu-dir` (default `6.8.0-48-generic`) |
| `--initrd PATH` | initrd path in qemu-dir (default `initrd.img`) |
| `--qemu-dir DIR` | dir with vmlinuz/initrd on host (default `~/shannon-qemu`) |
| `--qemu BIN` | qemu binary (default `qemu-system-x86_64`; use the bundle path from **shannon-qemu-install**) |
| `-m MEM` | guest RAM (default `16g` — epilog recovery needs headroom) |
| `-s N` | guest vCPUs (default `8`) |
| `--gdb` | add `-gdb tcp::3333` + `nokaslr` (see **shannon-kernel-debug**) |
| `--tmux NAME` | run inside a detached remote tmux session |
| `--list` | list shannon devices and exit |
| `--dry-run` | print the qemu command, don't run |
| `--all` / BDFs | which devices to pass through |

Each BDF becomes `-device vfio-pci,host=<bdf>`. The kernel cmdline is
`panic=5 init=/init console=ttyS0` (+ `nokaslr` with `--gdb`); console is on
`-serial mon:stdio -nographic`.

## 4. After boot — wait for the device

QEMU boots into the busybox initrd which auto-`insmod`s `shannon.ko`. The
**device takes 5+ minutes** to initialise (epilog recovery over ~1000
superblocks). See the **shannon-dev-lifecycle** skill for the wait loop and
the dmesg lines to look for (`Attached Direct-IO PCIe Flash`,
`Probed Direct-IO PCIe Flash`).

## 5. Multi-device notes

- Each Shannon device becomes one `/dev/df*` (and one `/dev/sct*`). With
  `shannon_auto_attach=0`, attach each manually with the `shannon-attach`
  utility from `shannon-utils`.
- For several devices, prefer `--all` (auto-detect) over hand-listing BDFs;
  it avoids transcription errors.
- Guest RAM scales with device count (each device's epilog recovery is
  memory-heavy); use `-m 24g` or more for ≥3 devices.

## 6. Tear-down

- Stop QEMU: `ssh <host> "tmux kill-session -t shannon"` (or `Ctrl-a x` on the
  console if attached).
- Return the device to the host driver:
  ```
  ssh <host> 'echo 0000:87:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind; \
              echo 0000:87:00.0 > /sys/bus/pci/drivers/shannon/bind 2>/dev/null || true'
  ```
  (or just `rmmod vfio_pci` after unbinding to free all devices).

## Reference scripts

- `scripts/shannon-pci-list.sh` — discovery
- `scripts/release-host.sh` — release host driver + kill prior QEMU (run before bind)
- `scripts/driver-bind.sh` — vfio-pci binding
- `scripts/qemu-shannon-run.sh` — qemu launch
