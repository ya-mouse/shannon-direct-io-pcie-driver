#!/bin/sh
# Install a recent QEMU (9.2 / 10+) on a remote baremetal host.
#
# The host may run Ubuntu focal (20.04, stock qemu 4.2) or noble (24.04, stock
# 8.2) — both too old. This script builds QEMU from source inside a Docker
# container whose base image MATCHES the host codename, so the produced
# qemu-system-x86_64 links against the same glibc and runs on the host. The
# binary lands at <bundle>/usr/local/bin/qemu-system-x86_64.
#
# Usage:
#   install-qemu.sh --host HOST --version 9.2.0 [--bundle PATH] [-j N] [--native]
#   install-qemu.sh HOST 9.2.0     # shorthand
#
# --native   skip Docker; build directly on the host (host must have the deps
#            and a compiler). Use only if Docker is unavailable.
set -eu

host=
version=9.2.0
bundle=
jobs=
native=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --version) shift; version="$1" ;;
    --bundle) shift; bundle="$1" ;;
    -j|--jobs) shift; jobs="$1" ;;
    --native) native=1 ;;
    --help|-h) sed -n '2,16p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$version" ]; then version="$1"
      else echo "$0: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST --version <ver> [--bundle PATH] [-j N] [--native]" >&2; exit 2; }

# Resolve the absolute bundle path on the remote (expand $HOME there).
if [ -z "$bundle" ]; then
  bundle=$(ssh -o BatchMode=yes "$host" 'echo "$HOME/shannon-qemu/qemu-bundle"')
fi
if [ -z "$jobs" ]; then
  jobs=$(ssh -o BatchMode=yes "$host" 'nproc 2>/dev/null || echo 4')
fi

# Detect host codename (focal / noble / jammy / ...).
codename=$(ssh -o BatchMode=yes "$host" '. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}"')
[ -n "$codename" ] || codename=ubuntu

echo "==> host=$host codename=$codename qemu=$version bundle=$bundle jobs=$jobs native=$native"

# 1. Generate the build script locally (quoted heredoc => literal, with two
#    placeholders substituted below).
build_script=$(mktemp)
cat > "$build_script" <<'BUILD'
#!/bin/sh
set -eux
V="__VERSION__"
N="__JOBS__"
cd /tmp
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Required deps for QEMU x86_64-softmmu:
pkgs="build-essential ninja-build python3 python3-venv git wget ca-certificates xz-utils \
  libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev \
  libaio-dev libslirp-dev libcap-ng-dev libattr1-dev libseccomp-dev \
  libusb-1.0-0-dev libusbredirparser-dev \
  libsasl2-dev libgnutls28-dev libcurl4-openssl-dev libssh-dev"
# Optional deps (install best-effort, do not fail):
opt_pkgs="libsdl2-dev libspice-server-dev libpng-dev libjpeg-dev liburing-dev"
apt-get install -y --no-install-recommends $pkgs || true
for p in $opt_pkgs; do apt-get install -y --no-install-recommends "$p" 2>/dev/null || true; done

wget -q "https://download.qemu.org/qemu-${V}.tar.xz"
tar xf "qemu-${V}.tar.xz"
cd "qemu-${V}"

cfg="--target-list=x86_64-softmmu --prefix=/usr/local --disable-werror --enable-slirp --enable-virtfs"
if ! ./configure $cfg; then
  echo "configure with full flags failed; retrying minimal configure" >&2
  ./configure --target-list=x86_64-softmmu --prefix=/usr/local --disable-werror
fi
ninja -C build -j"$N"
DESTDIR=/bundle make -C build install
echo "==> built:"
ls -l /bundle/usr/local/bin/qemu-system-x86_64
/bundle/usr/local/bin/qemu-system-x86_64 --version
BUILD

sed -i "s|__VERSION__|$version|; s|__JOBS__|$jobs|" "$build_script"

# 2. Ship build script to remote.
scp -q "$build_script" "$host:/tmp/.qemu-build.sh"
rm -f "$build_script"

# 3. Ensure docker on the remote (best-effort), then run the build.
ssh -o BatchMode=yes -t "$host" "
set -eux
mkdir -p '$bundle'
sudo chown -R \"\$(id -u):\$(id -g)\" '$bundle' 2>/dev/null || true
if [ $native -eq 1 ]; then
  sh /tmp/.qemu-build.sh
else
  if ! command -v docker >/dev/null 2>&1; then
    echo '==> installing docker on host'
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
    sudo systemctl enable --now docker 2>/dev/null || true
    sudo usermod -aG docker \"\$(whoami)\" 2>/dev/null || true
  fi
  sudo docker run --rm \
    -v '$bundle:/bundle' \
    -v /tmp/.qemu-build.sh:/build.sh:ro \
    ubuntu:$codename sh /build.sh
fi
rm -f /tmp/.qemu-build.sh
echo '==> qemu installed at: $bundle/usr/local/bin/qemu-system-x86_64'
echo \"==> use with: scripts/qemu-shannon-run.sh --host $host --qemu '$bundle/usr/local/bin/qemu-system-x86_64' --all --tmux shannon\"
"
