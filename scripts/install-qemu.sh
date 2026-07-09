#!/bin/sh
# Install a recent QEMU (9.2 / 10 / 11+) on a remote baremetal host.
#
# The host may run Ubuntu focal (20.04, stock qemu 4.2) or noble (24.04, stock
# 8.2) — both too old. This script builds QEMU from source so the produced
# qemu-system-x86_64 links against the host's glibc and runs natively. The
# binary lands at <bundle>/usr/local/bin/qemu-system-x86_64.
#
# THREE BUILD MODES:
#   (default)  docker build of ../Dockerfile.qemu  — reproducible, canonical.
#   --inline   build inside a ubuntu:<codename> container using an inline
#              script (the original path; no Dockerfile needed on the host).
#   --native   build directly on the host (no Docker; host needs compiler +
#              build deps). Use only if Docker is unavailable.
#
# All modes: install Docker if missing (default/--inline), build, extract the
# bundle, install the runtime shared libs the binary needs on the host, and
# verify `qemu-system-x86_64 --version` runs on the host.
#
# Usage:
#   install-qemu.sh --host HOST --version 11.0.2 [--bundle PATH] [-j N]
#                   [--codename CODENAME] [--mirror URL] [--native|--inline]
#   install-qemu.sh HOST 11.0.2     # shorthand
set -eu

host=
version=11.0.2
bundle=
jobs=
codename=
mirror=
native=0
inline=0
dockerfile=

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --version) shift; version="$1" ;;
    --bundle) shift; bundle="$1" ;;
    -j|--jobs) shift; jobs="$1" ;;
    --codename) shift; codename="$1" ;;
    --mirror) shift; mirror="$1" ;;
    --dockerfile) shift; dockerfile="$1" ;;
    --native) native=1; inline=0 ;;
    --inline) inline=1; native=0 ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$version" ]; then version="$1"
      else echo "$0: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST --version <ver> [--bundle PATH] [-j N] [--native|--inline]" >&2; exit 2; }

# Portable in-place sed: sedi FILE EXPR...  (BSD sed -i and GNU sed -i differ
# in how the backup-extension argument is consumed; avoid -i entirely).
sedi() { _sf=$1; shift; sed "$@" "$_sf" > "$_sf.sedi.$$" && mv "$_sf.sedi.$$" "$_sf"; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Default Dockerfile lives at the repo root (parent of scripts/).
[ -n "$dockerfile" ] || dockerfile="$script_dir/../Dockerfile.qemu"

# Resolve absolute bundle path + nproc + codename ON THE REMOTE (expand $HOME).
if [ -z "$bundle" ]; then
  bundle=$(ssh -o BatchMode=yes "$host" 'echo "$HOME/shannon-qemu/qemu-bundle"')
fi
if [ -z "$jobs" ]; then
  jobs=$(ssh -o BatchMode=yes "$host" 'nproc 2>/dev/null || echo 4')
fi
if [ -z "$codename" ]; then
  codename=$(ssh -o BatchMode=yes "$host" '. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}"')
fi
[ -n "$codename" ] || codename=ubuntu

# If --mirror not given, try to reuse the host's apt mirror (faster + works
# when archive.ubuntu.com is unreachable from the host). Empty => image default.
# Grab the first http(s):// URL from a noble `deb` line (handles the [options]
# block that shifts the URL field position).
if [ -z "$mirror" ]; then
  mirror=$(ssh -o BatchMode=yes "$host" \
    "grep -hE '^deb .* noble ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | head -1 | grep -oE 'https?://[^ ]+' | head -1" \
    || true)
fi

echo "==> host=$host codename=$codename qemu=$version bundle=$bundle jobs=$jobs"
echo "    mirror=${mirror:-<image default>} mode=$([ $native -eq 1 ] && echo native || { [ $inline -eq 1 ] && echo inline || echo dockerfile; })"

# Runtime shared libs qemu-system-x86_64 needs on the host (headless build:
# no SDL/GTK/spice). Each whitespace-separated group lists the candidate apt
# package names (in priority order); the first name apt knows about is
# installed. This handles noble's time64 "t64" package renames (e.g.
# libaio1 -> libaio1t64) while still working on focal/jammy.
runtime_lib_groups=" \
  libglib2.0-0 \
  libpixman-1-0 \
  libfdt1 \
  zlib1g \
  libaio1t64 libaio1 \
  libslirp0t64 libslirp0 \
  libcap-ng0 \
  libattr1 \
  libseccomp2 \
  libusb-1.0-0 \
  libusbredirparser1t64 libusbredirparser1 \
  libsasl2-2t64 libsasl2-2 \
  libgnutls30t64 libgnutls30 \
  libcurl4t64 libcurl4 \
  libssh-4 \
  libpcre2-8-0 \
  liburing2"

ensure_runtime_libs() {
  echo "==> installing runtime libs on host (best-effort, t64-aware)"
  rlscript=$(mktemp)
  grpfile=$(mktemp)
  # One candidate-group per line; the script installs the first name apt
  # knows about from each group.
  printf '%s\n' $runtime_lib_groups > "$grpfile"
  cat > "$rlscript" <<'RL'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq 2>/dev/null || true
installs=
while IFS= read -r group; do
  [ -n "$group" ] || continue
  for p in $group; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      installs="$installs $p"
      break
    fi
  done
done < /tmp/.runtime-groups
[ -n "$installs" ] || { echo "  (no runtime libs to install)"; exit 0; }
apt-get install -y --no-install-recommends $installs 2>&1 | tail -3 || true
RL
  scp -q "$rlscript" "$host:/tmp/.runtime-libs.sh"
  scp -q "$grpfile" "$host:/tmp/.runtime-groups"
  rm -f "$rlscript" "$grpfile"
  ssh -o BatchMode=yes -t "$host" "sh /tmp/.runtime-libs.sh; rm -f /tmp/.runtime-libs.sh /tmp/.runtime-groups" || true
}

verify_on_host() {
  echo "==> verifying qemu on host"
  ssh -o BatchMode=yes "$host" "
    bin='$bundle/usr/local/bin/qemu-system-x86_64'
    if [ ! -x \"\$bin\" ]; then echo 'ERROR: \$bin not found' >&2; exit 1; fi
    # Report any missing shared libs so they can be installed manually.
    missing=\$(ldd \"\$bin\" 2>/dev/null | awk '/not found/{print \$1}' | sort -u)
    if [ -n \"\$missing\" ]; then
      echo 'WARNING: missing shared libs:' >&2
      echo \"\$missing\" >&2
    fi
    \"\$bin\" --version
  "
}

# ---------------------------------------------------------------------------
# Mode: native (build directly on the host, no Docker)
# ---------------------------------------------------------------------------
if [ $native -eq 1 ]; then
  build_script=$(mktemp)
  cat > "$build_script" <<'BUILD'
#!/bin/sh
set -eux
V="__VERSION__"
N="__JOBS__"
MIRROR="__MIRROR__"
cd /tmp
export DEBIAN_FRONTEND=noninteractive
if [ -n "$MIRROR" ]; then
  sudo sed -i "s|http://archive.ubuntu.com/ubuntu|$MIRROR|g; s|http://security.ubuntu.com/ubuntu|$MIRROR|g" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi
sudo apt-get update
pkgs="build-essential ninja-build python3 python3-venv git wget ca-certificates xz-utils \
  libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev \
  libaio-dev libslirp-dev libcap-ng-dev libattr1-dev libseccomp-dev \
  libusb-1.0-0-dev libusbredirparser-dev \
  libsasl2-dev libgnutls28-dev libcurl4-openssl-dev libssh-dev liburing-dev"
sudo apt-get install -y --no-install-recommends $pkgs
wget -q "https://download.qemu.org/qemu-${V}.tar.xz"
tar xf "qemu-${V}.tar.xz"
cd "qemu-${V}"
./configure --target-list=x86_64-softmmu --prefix=/usr/local --disable-werror \
  --enable-slirp --enable-virtfs --disable-sdl --disable-gtk --disable-spice \
  || ./configure --target-list=x86_64-softmmu --prefix=/usr/local --disable-werror \
       --disable-sdl --disable-gtk --disable-spice
ninja -C build -j"$N"
sudo mkdir -p '__BUNDLE__'
sudo chown -R "$(id -u):$(id -g)" '__BUNDLE__' 2>/dev/null || true
DESTDIR='__BUNDLE__' make -C build install
echo '==> built:'
ls -l '__BUNDLE__'/usr/local/bin/qemu-system-x86_64
BUILD
  sedi "$build_script" "s|__VERSION__|$version|; s|__JOBS__|$jobs|; s|__MIRROR__|$mirror|; s|__BUNDLE__|$bundle|g"
  scp -q "$build_script" "$host:/tmp/.qemu-build.sh"
  rm -f "$build_script"
  ssh -o BatchMode=yes -t "$host" "sh /tmp/.qemu-build.sh; rm -f /tmp/.qemu-build.sh"
  ensure_runtime_libs
  verify_on_host
  echo "==> qemu installed at: $bundle/usr/local/bin/qemu-system-x86_64"
  exit 0
fi

# ---------------------------------------------------------------------------
# Ensure Docker on the host (default + inline modes).
# ---------------------------------------------------------------------------
ssh -o BatchMode=yes -t "$host" "
  set -e
  if ! command -v docker >/dev/null 2>&1; then
    echo '==> installing docker on host'
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker.io
    sudo systemctl enable --now docker 2>/dev/null || true
    sudo usermod -aG docker \"\$(whoami)\" 2>/dev/null || true
  fi
  # Make sure the calling user can use docker without sudo (best-effort).
  sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
  docker version --format '{{.Server.Version}}' 2>/dev/null && echo 'docker ok' || sudo docker version --format '{{.Server.Version}}'
" >/dev/null 2>&1 || true

mkdir_remote='sudo mkdir -p "'$bundle'"; sudo chown -R "$(id -u):$(id -g)" "'$bundle'" 2>/dev/null || true'
ssh -o BatchMode=yes "$host" "$mkdir_remote"

# ---------------------------------------------------------------------------
# Mode: inline (build inside ubuntu:<codename> with an inline script)
# ---------------------------------------------------------------------------
if [ $inline -eq 1 ]; then
  build_script=$(mktemp)
  cat > "$build_script" <<'BUILD'
#!/bin/sh
set -eux
V="__VERSION__"
N="__JOBS__"
MIRROR="__MIRROR__"
cd /tmp
export DEBIAN_FRONTEND=noninteractive
if [ -n "$MIRROR" ]; then
  sed -i "s|http://archive.ubuntu.com/ubuntu|$MIRROR|g; s|http://security.ubuntu.com/ubuntu|$MIRROR|g" \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi
apt-get update
pkgs="build-essential ninja-build python3 python3-venv git wget ca-certificates xz-utils \
  libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev \
  libaio-dev libslirp-dev libcap-ng-dev libattr1-dev libseccomp-dev \
  libusb-1.0-0-dev libusbredirparser-dev \
  libsasl2-dev libgnutls28-dev libcurl4-openssl-dev libssh-dev"
(apt-get install -y --no-install-recommends liburing-dev 2>/dev/null || true)
apt-get install -y --no-install-recommends $pkgs
wget -q "https://download.qemu.org/qemu-${V}.tar.xz"
tar xf "qemu-${V}.tar.xz"
cd "qemu-${V}"
./configure --target-list=x86_64-softmmu --prefix=/usr/local --disable-werror \
  --enable-slirp --enable-virtfs --disable-sdl --disable-gtk --disable-spice \
  || ./configure --target-list=x86_64-softmmu --prefix=/usr/local --disable-werror \
       --disable-sdl --disable-gtk --disable-spice
ninja -C build -j"$N"
DESTDIR=/bundle make -C build install
echo '==> built:'
ls -l /bundle/usr/local/bin/qemu-system-x86_64
/bundle/usr/local/bin/qemu-system-x86_64 --version
BUILD
  sedi "$build_script" "s|__VERSION__|$version|; s|__JOBS__|$jobs|; s|__MIRROR__|$mirror|"
  scp -q "$build_script" "$host:/tmp/.qemu-build.sh"
  rm -f "$build_script"
  echo "==> building qemu $version inline in ubuntu:$codename"
  ssh -o BatchMode=yes -t "$host" "
    sudo docker run --rm \
      -v '$bundle:/bundle' \
      -v /tmp/.qemu-build.sh:/build.sh:ro \
      ubuntu:$codename sh /build.sh
    rm -f /tmp/.qemu-build.sh
  "
  ensure_runtime_libs
  verify_on_host
  echo "==> qemu installed at: $bundle/usr/local/bin/qemu-system-x86_64"
  exit 0
fi

# ---------------------------------------------------------------------------
# Mode: dockerfile (default) — canonical build via ../Dockerfile.qemu
# ---------------------------------------------------------------------------
if [ ! -f "$dockerfile" ]; then
  echo "ERROR: Dockerfile not found at $dockerfile" >&2
  exit 2
fi
tag="shannon-qemu:${version}-${codename}"

# Ship the Dockerfile to the host (build context = a temp dir with just it).
ctx=$(ssh -o BatchMode=yes "$host" 'mktemp -d /tmp/.qemu-ctx.XXXXXX')
scp -q "$dockerfile" "$host:$ctx/Dockerfile.qemu"

build_arg_mirror=
if [ -n "$mirror" ]; then
  build_arg_mirror="--build-arg APT_MIRROR=$mirror"
fi

echo "==> docker build (tag=$tag)"
ssh -o BatchMode=yes -t "$host" "
  set -e
  sudo docker build \
    --build-arg CODENAME=$codename \
    --build-arg QEMU_VERSION=$version \
    --build-arg JOBS=$jobs \
    $build_arg_mirror \
    -t $tag \
    -f $ctx/Dockerfile.qemu \
    $ctx
  rm -rf $ctx
"

echo "==> extracting bundle to $bundle"
ssh -o BatchMode=yes -t "$host" "
  set -e
  sudo mkdir -p '$bundle'
  sudo chown -R \"\$(id -u):\$(id -g)\" '$bundle' 2>/dev/null || true
  sudo docker run --rm -v '$bundle:/out' $tag
"

ensure_runtime_libs
verify_on_host
echo "==> qemu installed at: $bundle/usr/local/bin/qemu-system-x86_64"
echo "==> use with: scripts/qemu-shannon-run.sh --host $host --qemu '$bundle/usr/local/bin/qemu-system-x86_64' --all --tmux shannon"
