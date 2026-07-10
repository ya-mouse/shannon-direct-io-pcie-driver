# Shannon Direct-IO PCIe device driver

## Building the kernel module in Docker (e.g. for testing)

```
# Start a Docker container for clean builds
docker run -it -v ${PWD}/..:/build -w /build/shannon-direct-io-pcie-driver ubuntu:bionic bash

# Install build tools, includes mk-build-deps
apt update && apt install devscripts equivs --no-install-recommends --yes

# Automatically install all build dependencies from debian/control
mk-build-deps debian/control -r -i

# Install kernel headers
# Works only if Docker host and container kernel pair up
apt install linux-headers-$(uname -r) --yes

# Build package
dpkg-buildpackage -us -uc

# View result
ls -la ../
dpkg-deb -c ../*.deb

# Exit Docker
exit

# Ensure any files written by Docker are again user owned
sudo chown -R $USER ../
```

## Installing the Shannon driver as a DKMS module

1. Copy source to `/usr/src`:

```
sudo cp shannon-module_3.4.0 /usr/src/shannon-3.4.0
```

2. Build and install:

```
$ sudo dkms add -m shannon -v 3.4.0

Creating symlink /var/lib/dkms/shannon/3.4.0/source ->
                /usr/src/shannon-3.4.0

DKMS: add completed.

$ sudo dkms build -m shannon -v 3.4.0

Kernel preparation unnecessary for this kernel.  Skipping...

Building module:
cleaning build area....
KERNEL_TREE=/lib/modules/4.15.0-48-generic/build make modules.....
cleaning build area....

DKMS: build completed.

$ sudo dkms install -m shannon -v 3.4.0
```

3. Verify:

```
$ ls /var/lib/dkms/shannon/3.4.0/
4.15.0-48-generic  4.15.0-51-generic  source

$ dkms status
shannon, 3.4.0, 4.15.0-48-generic, x86_64: installed
shannon, 3.4.0, 4.15.0-51-generic, x86_64: installed

$ lsmod | grep shannon
shannon 675840 0
```

## Kernel command-line requirements (IOMMU)

The Shannon Direct-IO PCIe device uses `dma_alloc_coherent` for its
command/completion buffers. On kernels ≥ 6.0 (e.g. Ubuntu 6.8 noble,
6.17+) the Intel IOMMU is **enabled by default** with **translated**
DMA (IOVA). The Shannon device firmware cannot operate correctly with
IOVA-translated DMA — under heavy write load the device stops completing
write-buffer commands, causing a permanent stall
(`bufq_alloc_cmd_sleepable` blocked, `check_pending_command_queue`
alarm).

**Fix:** add `intel_iommu=on iommu=pt` to the kernel command line so the
IOMMU runs in **passthrough (identity)** mode — the device's DMA address
equals the physical address, matching the behaviour on older kernels
(5.15 and below) where the IOMMU is off by default.

```
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... intel_iommu=on iommu=pt"

sudo update-grub
sudo reboot
```

Verify after reboot:
```
$ cat /proc/cmdline | grep -o 'iommu=pt'
iommu=pt
$ cat /sys/kernel/iommu_groups/*/type | sort -u
identity
```

Without `iommu=pt`, the driver will stall within minutes under write
load on kernels ≥ 6.0.
