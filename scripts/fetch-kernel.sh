#!/bin/sh
# Ensure a specific kernel version is available on a remote baremetal host:
#   - vmlinuz-<kver> at ~/shannon-qemu/vmlinuz-<kver>   (for booting QEMU)
#   - /lib/modules/<kver>/build                         (linux-headers, for building shannon.ko)
#
# If already present, do nothing (idempotent). Otherwise fetch the kernel .deb
# packages and unpack them. Tries the host's own apt first (fast path, works if
# the host mirror carries the kernel); on failure, sets up a TEMPORARY apt
# config pointing at the public Ubuntu archive for the suite(s) that ship that
# kernel, downloads the .debs there, and extracts/installs them.
#
# Usage:
#   fetch-kernel.sh --host HOST --kernel <kver> [--suite SUITE] [--mirror URL] [--arch amd64]
#                   [--image-only|--headers-only]
#   fetch-kernel.sh HOST <kver>     # shorthand
#
# --suite: override suite detection (e.g. focal, noble, jammy). Space-separated
#          list accepted (e.g. "noble jammy"). Auto-detected from <kver> if unset.
# --mirror / --security-mirror: override archive.ubuntu.com / security.ubuntu.com.
set -eu

# Portable in-place sed: sedi FILE EXPR...  (BSD sed -i and GNU sed -i differ
# in how the backup-extension argument is consumed; avoid -i entirely).
sedi() { _sf=$1; shift; sed "$@" "$_sf" > "$_sf.sedi.$$" && mv "$_sf.sedi.$$" "$_sf"; }

host=
kver=
suite=
mirror=http://archive.ubuntu.com/ubuntu
sec_mirror=http://security.ubuntu.com/ubuntu
arch=amd64
what=both

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --kernel) shift; kver="$1" ;;
    --suite) shift; suite="$1" ;;
    --mirror) shift; mirror="$1" ;;
    --security-mirror) shift; sec_mirror="$1" ;;
    --arch) shift; arch="$1" ;;
    --image-only) what=image ;;
    --headers-only) what=headers ;;
    --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$kver" ]; then kver="$1"
      else echo "$0: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST --kernel <kver> [...]" >&2; exit 2; }
[ -n "$kver" ] || { echo "--kernel <kver> required" >&2; exit 2; }

# Auto-detect suite(s) from the kernel version.
if [ -z "$suite" ]; then
  case "$kver" in
    7.*)   suite="noble" ;;           # noble HWE-7.0
    6.17*) suite="noble" ;;           # noble HWE-6.17
    6.14*) suite="plucky" ;;
    6.11*) suite="oracular" ;;
    6.8*)  suite="noble jammy" ;;     # noble primary; jammy hwe-6.8 fallback
    6.5*)  suite="mantic jammy" ;;
    6.2*)  suite="lunar" ;;
    5.19*) suite="kinetic" ;;
    5.15*) suite="focal" ;;
    5.4*)  suite="bionic" ;;
    4.15*) suite="bionic" ;;
    *) suite="" ;;
  esac
fi
if [ -z "$suite" ]; then
  echo "could not auto-detect Ubuntu suite for kernel $kver; pass --suite <suite>" >&2
  exit 2
fi

# Resolve qemu_dir to an absolute remote path (expand $HOME / ~ there).
qemu_dir_local='$HOME/shannon-qemu'
qdr=$(ssh -o BatchMode=yes "$host" "echo $qemu_dir_local")

case "$what" in
  image) need_image=1; need_headers=0 ;;
  headers) need_image=0; need_headers=1 ;;
  both) need_image=1; need_headers=1 ;;
esac

# Build the remote script locally (quoted heredoc + placeholder substitution).
rs=$(mktemp)
cat > "$rs" <<'REMOTE'
#!/bin/sh
set -eux
KVER='__KVER__'
SUITES='__SUITES__'
ARCH='__ARCH__'
QEMU_DIR='__QEMU_DIR__'
MIRROR='__MIRROR__'
SEC_MIRROR='__SEC_MIRROR__'
NEED_IMAGE=__NEED_IMAGE__
NEED_HEADERS=__NEED_HEADERS__
STAGE=/tmp/.kfetch-stage
TEMPAPT=/tmp/.kfetch-apt
APT_OPTS=

have_image() { [ -f "$QEMU_DIR/vmlinuz-$KVER" ] || [ -f "/boot/vmlinuz-$KVER" ]; }
have_headers() { [ -d "/lib/modules/$KVER/build" ]; }

setup_temp_apt() {
  [ -n "$APT_OPTS" ] && return 0
  rm -rf "$TEMPAPT"
  mkdir -p "$TEMPAPT/archives/partial" "$TEMPAPT/state/lists/partial" \
           "$TEMPAPT/state" "$TEMPAPT/cache" "$TEMPAPT/preferences.d" "$TEMPAPT/root"
  : > "$TEMPAPT/state/status"
  : > "$TEMPAPT/sources.list"
  for s in $SUITES; do
    echo "deb [arch=$ARCH] $MIRROR $s main restricted"          >> "$TEMPAPT/sources.list"
    echo "deb [arch=$ARCH] $MIRROR $s-updates main restricted"  >> "$TEMPAPT/sources.list"
    echo "deb [arch=$ARCH] $SEC_MIRROR $s-security main restricted" >> "$TEMPAPT/sources.list"
  done
  APT_OPTS="-o Dir::Etc::sourcelist=$TEMPAPT/sources.list \
    -o Dir::Etc::sourceparts=/dev/null \
    -o Dir::Etc::preferencesparts=/dev/null \
    -o Dir::State=$TEMPAPT/state \
    -o Dir::State::Lists=$TEMPAPT/state/lists \
    -o Dir::State::status=$TEMPAPT/state/status \
    -o Dir::Cache=$TEMPAPT/cache \
    -o Dir::Cache::Archives=$TEMPAPT/archives \
    -o Dir::Cache::pkgcache=$TEMPAPT/cache/pkgcache \
    -o Dir::Cache::srcpkgcache=$TEMPAPT/cache/srcpkgcache \
    -o Dir::Log=$TEMPAPT \
    -o APT::Architecture=$ARCH \
    -o Debug::NoLocking=true"
  echo '==> temp-apt update'
  sudo apt-get $APT_OPTS update || apt-get $APT_OPTS update
}

# fetch_deb PKG -> download PKG.deb into STAGE (host apt first, temp apt fallback)
fetch_deb() {
  pkg=$1
  mkdir -p "$STAGE"
  rm -f "$STAGE"/${pkg}_*.deb 2>/dev/null || true
  if ( cd "$STAGE" && apt-get download -o APT::Architecture=$ARCH "$pkg" ); then
    return 0
  fi
  echo "  (host apt has no $pkg; trying temp apt with suites: $SUITES)"
  setup_temp_apt
  ( cd "$STAGE" && sudo apt-get $APT_OPTS download "$pkg" )
}

if [ "$NEED_IMAGE" -eq 1 ] && ! have_image; then
  echo '==> fetching kernel image for '"$KVER"
  ok=0
  for p in "linux-image-unsigned-$KVER" "linux-image-$KVER"; do
    fetch_deb "$p" || continue
    deb=$(ls -1 "$STAGE"/${p}_*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || continue
    tmp=$(mktemp -d)
    dpkg-deb -x "$deb" "$tmp"
    vmlinuz=$(ls "$tmp"/boot/vmlinuz-* 2>/dev/null | head -1)
    if [ -n "$vmlinuz" ]; then
      mkdir -p "$QEMU_DIR"
      if [ -w "$QEMU_DIR" ]; then
        cp "$vmlinuz" "$QEMU_DIR/vmlinuz-$KVER"
      else
        sudo cp "$vmlinuz" "$QEMU_DIR/vmlinuz-$KVER"
        sudo chown "$(id -u):$(id -g)" "$QEMU_DIR/vmlinuz-$KVER" 2>/dev/null || true
      fi
      ok=1
    fi
    rm -rf "$tmp" "$deb"
    [ "$ok" -eq 1 ] && break
  done
  [ "$ok" -eq 1 ] || { echo "could not fetch vmlinuz for $KVER" >&2; exit 2; }
fi

if [ "$NEED_HEADERS" -eq 1 ] && ! have_headers; then
  echo '==> fetching kernel headers for '"$KVER"
  for p in "linux-headers-$KVER" "linux-headers-$KVER-generic"; do
    fetch_deb "$p" || true
  done
  debs=$(ls -1 "$STAGE"/linux-headers-*"$KVER"*.deb 2>/dev/null)
  if [ -n "$debs" ]; then
    sudo dpkg -i $debs 2>/dev/null || sudo apt-get install -fy 2>/dev/null || true
  fi
fi

rm -rf "$STAGE" "$TEMPAPT"

echo '==> kernel '"$KVER"' ready:'
[ -f "$QEMU_DIR/vmlinuz-$KVER" ] && echo "  image:  $QEMU_DIR/vmlinuz-$KVER"
[ -d "/lib/modules/$KVER/build" ] && echo "  headers: /lib/modules/$KVER/build"
REMOTE

sedi "$rs" \
  -e "s|__KVER__|$kver|g" \
  -e "s|__SUITES__|$suite|g" \
  -e "s|__ARCH__|$arch|g" \
  -e "s|__QEMU_DIR__|$qdr|g" \
  -e "s|__MIRROR__|$mirror|g" \
  -e "s|__SEC_MIRROR__|$sec_mirror|g" \
  -e "s|__NEED_IMAGE__|$need_image|g" \
  -e "s|__NEED_HEADERS__|$need_headers|g"

scp -q "$rs" "$host:/tmp/.fetch-kernel.sh"
rm -f "$rs"
ssh -o BatchMode=yes -t "$host" "sh /tmp/.fetch-kernel.sh; rm -f /tmp/.fetch-kernel.sh"
