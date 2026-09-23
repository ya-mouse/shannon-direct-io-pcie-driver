#!/bin/sh
# Build an initrd (cpio.gz) on a remote baremetal host containing the freshly
# built shannon.ko, a busybox userspace, and an /init that insmods the driver.
# Also ensures vmlinuz-<kver> is present (via fetch-kernel.sh).
#
# Usage:
#   make-initrd.sh --host HOST --kernel <kver> \
#       [--src PATH] [--qemu-dir DIR] [--initrd-template <dir|tarball>] \
#       [--no-skip-epilog] [--no-fast-boot] [--full-recovery]
#
# --initrd-template: a directory or tarball with a busybox /bin to seed the
#   rootfs. If omitted, the script AUTO-BOOTSTRAPS a minimal busybox root by
#   installing busybox-static on the host and symlinking applets.
# --no-skip-epilog:  load the driver WITHOUT shannon_skip_epilog=1.
# --no-fast-boot:    load the driver WITHOUT shannon_fast_boot_enable=1.
# --full-recovery:   both of the above, i.e. insmod with NO debug parameters.
#
# NOTE: dropping shannon_skip_epilog alone is NOT enough to get a full epilog
# recovery -- shannon_fast_boot_enable=1 by itself also skips it.  Verified on
# 7.0.0-31-generic: with fast_boot=1 and no skip_epilog the guest printed 0
# "recover N00 superblock's epilog done" lines and probed in ~60 s, whereas a
# param-free load prints ~43 of them over ~8 min.  Use --full-recovery for
# data-integrity runs and for exercising the recovery-time allocation paths.
set -eu

# Portable in-place sed: sedi FILE EXPR...  (BSD sed -i and GNU sed -i differ
# in how the backup-extension argument is consumed; avoid -i entirely).
sedi() { _sf=$1; shift; sed "$@" "$_sf" > "$_sf.sedi.$$" && mv "$_sf.sedi.$$" "$_sf"; }

host=
kver=
src='$HOME/shannon-src'
qemu_dir='$HOME/shannon-qemu'
initrd_template=
skip_epilog=1
fast_boot=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --kernel) shift; kver="$1" ;;
    --src) shift; src="$1" ;;
    --qemu-dir) shift; qemu_dir="$1" ;;
    --initrd-template) shift; initrd_template="$1" ;;
    --no-skip-epilog) skip_epilog=0 ;;
    --no-fast-boot) fast_boot=0 ;;
    --full-recovery) skip_epilog=0; fast_boot=0 ;;
    --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$kver" ]; then kver="$1"
      else echo "$0: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST --kernel <kver> [...]" >&2; exit 2; }
[ -n "$kver" ] || { echo "--kernel <kver> required" >&2; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Ensure vmlinuz-<kver> is present on the host (downloads + unpacks if missing).
echo "==> ensuring vmlinuz-$kver is present"
"$script_dir/fetch-kernel.sh" --host "$host" --kernel "$kver" --image-only

# Resolve remote-relative paths ($HOME / ~) to absolute remote paths.
qdr=$(ssh -o BatchMode=yes "$host" "echo $qemu_dir")
srd=$(ssh -o BatchMode=yes "$host" "echo $src")
if [ -n "$initrd_template" ]; then
  tpl=$(ssh -o BatchMode=yes "$host" "echo $initrd_template")
else
  tpl=
fi

# 1. Generate the /init script locally (quoted heredoc => literal content).
modparams=
if [ "$fast_boot" -eq 1 ]; then
  modparams="$modparams shannon_fast_boot_enable=1"
fi
if [ "$skip_epilog" -eq 1 ]; then
  modparams="$modparams shannon_skip_epilog=1"
fi
modparams=$(printf '%s' "$modparams" | sed 's/^ *//')
echo "==> init will insmod with: ${modparams:-<no parameters: full recovery>}"
init_tmp=$(mktemp)
cat > "$init_tmp" <<'INIT'
#!/bin/sh
export PATH=/bin:/sbin
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
ip link set lo up
hostname shannon-test
[ -e /dev/console ] || mknod /dev/console c 5 1
[ -e /dev/null ]    || mknod /dev/null c 1 3
echo '==> loading shannon driver (device init takes 5+ minutes; wait for Probed)'
ko=$(find /lib/modules/$(uname -r) -name shannon.ko 2>/dev/null | head -1)
[ -z "$ko" ] && ko=$(find /lib/modules -name shannon.ko 2>/dev/null | head -1)
if [ -n "$ko" ]; then
	insmod "$ko" __MODPARAMS__
else
	echo '!! shannon.ko not found in /lib/modules' >&2
fi
exec /bin/sh -c 'exec /bin/sh </dev/console >/dev/console 2>&1'
INIT
sedi "$init_tmp" "s|__MODPARAMS__|$modparams|"
scp -q "$init_tmp" "$host:/tmp/.shannon-init"
rm -f "$init_tmp"

# 2. Generate the remote packing script locally (quoted heredoc + placeholders).
rs=$(mktemp)
cat > "$rs" <<'REMOTE'
#!/bin/sh
set -eux
QEMU_DIR='__QEMU_DIR__'
KVER='__KVER__'
SRC='__SRC__'
TPL='__TPL__'

root="$QEMU_DIR/initrd-root"
mkdir -p "$QEMU_DIR"

# Seed from template if provided.
if [ -n "$TPL" ]; then
  rm -rf "$root"; mkdir -p "$root"
  if [ -d "$TPL" ]; then cp -a "$TPL/." "$root"/
  else tar -C "$root" -xf "$TPL"; fi
fi

# Ensure a busybox /bin. If no template was given, auto-bootstrap a minimal
# root from busybox-static on the host.
if [ ! -x "$root/bin/busybox" ]; then
  if [ -n "$TPL" ]; then
    echo "initrd template has no busybox /bin" >&2; exit 2
  fi
  echo '==> bootstrapping minimal busybox root'
  if ! [ -x /bin/busybox ]; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y busybox-static
  fi
  [ -x /bin/busybox ] || { echo 'busybox unavailable; install busybox-static' >&2; exit 2; }
  rm -rf "$root"
  mkdir -p "$root"/bin "$root"/sbin "$root"/etc "$root"/dev "$root"/proc "$root"/sys "$root"/tmp "$root"/root "$root"/mnt "$root"/usr/bin "$root"/usr/sbin
  cp /bin/busybox "$root/bin/busybox"
  for app in sh ash ls cat dd sha256sum sha1sum find insmod lsmod modprobe rmmod mount umount sync sleep echo printf grep sed awk tr cut head tail wc cmp mkdir mknod rmdir cp mv rm ln chmod chown date uname hostname ps kill env test '[' blockdev dmesg; do
    ln -s busybox "$root/bin/$app" 2>/dev/null || true
  done
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
  printf 'root:x:0:\n'                   > "$root/etc/group"
fi

# Place shannon.ko. Remove any stale shannon.ko left from a previous
# (different-kver) initrd build so /init does not pick the wrong one.
find "$root/lib/modules" -name shannon.ko -delete 2>/dev/null || true
mkdir -p "$root/lib/modules/$KVER/kernel/drivers/block"
cp "$SRC/shannon.ko" "$root/lib/modules/$KVER/kernel/drivers/block/shannon.ko"

# Place /init (shipped by the caller to /tmp/.shannon-init).
cp /tmp/.shannon-init "$root/init"
chmod +x "$root/init"
rm -f /tmp/.shannon-init

# Ship the integrity validator + soak test too, if the source tree has them.
mkdir -p "$root/usr/local/bin"
for s in validate-integrity.sh soak-verify.sh; do
  if [ -f "$SRC/scripts/$s" ]; then
    cp "$SRC/scripts/$s" "$root/usr/local/bin/$s"
    chmod +x "$root/usr/local/bin/$s"
  fi
done

# Ensure vmlinuz is present (fetch-kernel.sh should have placed it; /boot backstop).
if [ ! -f "$QEMU_DIR/vmlinuz-$KVER" ]; then
  if [ -f "/boot/vmlinuz-$KVER" ]; then
    sudo cp "/boot/vmlinuz-$KVER" "$QEMU_DIR/vmlinuz-$KVER"
    sudo chown "$(id -u):$(id -g)" "$QEMU_DIR/vmlinuz-$KVER" 2>/dev/null || true
  else
    echo "vmlinuz-$KVER missing; run scripts/fetch-kernel.sh --host ... --kernel $KVER --image-only" >&2
    exit 2
  fi
fi

# Pack the initramfs.
( cd "$root" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$QEMU_DIR/initrd.img"
ls -l "$QEMU_DIR/initrd.img" "$QEMU_DIR/vmlinuz-$KVER"
REMOTE

sedi "$rs" \
  -e "s|__QEMU_DIR__|$qdr|g" \
  -e "s|__KVER__|$kver|g" \
  -e "s|__SRC__|$srd|g" \
  -e "s|__TPL__|$tpl|g"

scp -q "$rs" "$host:/tmp/.make-initrd.sh"
rm -f "$rs"
ssh -o BatchMode=yes -t "$host" "sh /tmp/.make-initrd.sh; rm -f /tmp/.make-initrd.sh"
