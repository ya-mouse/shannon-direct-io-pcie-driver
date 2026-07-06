---
name: shannon-qemu-install
description: Install a recent QEMU (9.2 or 10+) on a remote baremetal host running Ubuntu focal (20.04) or noble (24.04), including building QEMU from source inside a matching Docker container for x86_64 when the distro package is too old. Use when the user needs a newer qemu for vfio-pci passthrough of Shannon devices, or asks to build/install/upgrade qemu on the baremetal host.
---

# Installing recent QEMU on the baremetal host

The Shannon VFIO passthrough workflow needs a modern QEMU (9.2 / 10+). Ubuntu
packages are too old:

| distro | stock qemu | verdict |
|---|---|---|
| focal 20.04 | 4.2 | too old — build from source |
| noble 24.04 | 8.2 | borderline — build from source for 9.2+ features |

Build in a **Docker container matching the host codename** so the produced
`qemu-system-x86_64` links against the same glibc as the host and runs
without a dependency mismatch.

## One-shot: `scripts/install-qemu.sh`

```
scripts/install-qemu.sh --host <host> --version 9.2.0
scripts/install-qemu.sh --host <host> --version 10.0.0 --bundle '$HOME/shannon-qemu/qemu-bundle'
```

What it does:

1. Detects the host's Ubuntu codename (`focal`/`noble`) via `/etc/os-release`.
2. Ensures Docker is installed on the host (installs if missing).
3. Writes a build script and runs it inside `ubuntu:<codename>` with
   `~/shannon-qemu/qemu-bundle` mounted at `/bundle`:
   - installs build deps (`build-essential ninja-build python3 git wget
     libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev libaio-dev
     libslirp-dev libcap-ng-dev libseccomp-dev libusb-1.0-0-dev
     libusbredirparser-dev libsasl2-dev libgnutls28-dev libcurl4-openssl-dev
     libssh-dev …`; SDL/spice are optional).
   - downloads `https://download.qemu.org/qemu-<ver>.tar.xz`,
   - `./configure --target-list=x86_64-softmmu --prefix=/usr/local`
     (with slirp/virtfs when deps allow; falls back to a minimal configure
     if an optional dep is missing),
   - `ninja -C build` (parallelised by host `nproc`),
   - `DESTDIR=/bundle make -C build install`.
4. The binary lands at `~/shannon-qemu/qemu-bundle/usr/local/bin/qemu-system-x86_64`.

A full source build takes ~10–25 minutes depending on host CPU. It only needs
to be done once per host; rebuild only to upgrade QEMU versions.

## Use the bundle with the run script

```
scripts/qemu-shannon-run.sh --host <host> --all \
  --qemu '$HOME/shannon-qemu/qemu-bundle/usr/local/bin/qemu-system-x86_64' \
  --tmux shannon
```

(Quote the path with single quotes so `$HOME` expands on the remote host, not
locally.)

## Verify

```
ssh <host> '$HOME/shannon-qemu/qemu-bundle/usr/local/bin/qemu-system-x86_64 --version'
```

## Manual / alternative approaches

- **Distrowise apt backport** (only if a backport exists): check
  `apt-cache policy qemu-system-x86` on the host; install only if ≥9.2.
- **System install (no Docker)**: on noble you can build natively with the
  same deps; use `scripts/install-qemu.sh --host <host> --version 9.2.0 --native`
  (the script still detects deps). Prefer the Docker path — it is reproducible
  and does not pollute the host.
- **Reuse an existing bundle**: if a previous `install-qemu.sh` run already
  produced `~/shannon-qemu/qemu-bundle/usr/local/bin/qemu-system-x86_64` on
  the host, just point `qemu-shannon-run.sh --qemu` at it; no need to rebuild.

## Build-dep reference (for hand-tuning)

Required for QEMU x86_64 system emulation on Ubuntu:

```
build-essential ninja-build python3 git wget ca-certificates
libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev
libaio-dev libslirp-dev libcap-ng-dev libattr1-dev libseccomp-dev
libusb-1.0-0-dev libusbredirparser-dev
libsasl2-dev libgnutls28-dev
libcurl4-openssl-dev libssh-dev
```

Optional (enable if present, configure auto-detects): `libsdl2-dev`,
`libspice-server-dev`, `libpng-dev`, `libjpeg-dev`.

Configure defaults used by the script:

```
./configure --target-list=x86_64-softmmu --prefix=/usr/local \
            --enable-slirp --enable-virtfs --disable-werror
```

`--disable-werror` keeps a noisy-but-harmless warning from aborting the build
on a newer toolchain.
