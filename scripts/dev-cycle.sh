#!/bin/sh
# End-to-end development cycle for the shannon.ko driver on a remote baremetal
# host: release host -> fetch kernel -> rsync -> build -> pack initrd ->
# bind vfio-pci -> boot QEMU.
#
# This runs steps 0-6 of the lifecycle (step 0 releases the host driver + kills
# any prior QEMU). It does NOT wait for the device (step 7, ~5+ min) or run I/O
# (step 8) — do those next. See the shannon-dev-lifecycle skill.
#
# Usage:
#   dev-cycle.sh --host HOST --kernel <kver> (--all | <bdf...>) [--gdb] [--tmux NAME] [--no-release]
#   dev-cycle.sh HOST <kver> --all     # shorthand
set -eu

host=
kver=
devs=
gdb=0
tmux=shannon
release=1
qemu_bin=

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --kernel) shift; kver="$1" ;;
    --all|--auto) devs=ALL ;;
    --gdb) gdb=1 ;;
    --qemu) shift; qemu_bin="$1" ;;
    --tmux) shift; tmux="$1" ;;
    --release) release=1 ;;
    --no-release) release=0 ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$kver" ]; then kver="$1"
      else devs="$devs $1"; fi ;;
  esac
  shift
done
devs=$(printf '%s' "$devs" | sed 's/^ *//')

[ -n "$host" ] || { echo "Usage: $0 --host HOST --kernel <kver> (--all | <bdf...>) [--gdb] [--tmux NAME]" >&2; exit 2; }
[ -n "$kver" ] || { echo "--kernel <kver> required" >&2; exit 2; }
[ -n "$devs" ] || { echo "pass --all or explicit BDFs" >&2; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$release" -eq 1 ]; then
  echo "==> [0/6] release host shannon driver + kill any prior QEMU session"
  "$script_dir/release-host.sh" --host "$host" --tmux "$tmux" --all
fi

echo "==> [1/6] ensure kernel $kver (vmlinuz + headers) present on $host"
"$script_dir/fetch-kernel.sh" --host "$host" --kernel "$kver"

echo "==> [2/6] rsync source to $host:~/shannon-src"
"$script_dir/rsync-src.sh" --host "$host"

echo "==> [3/6] build shannon.ko for $kver on $host"
"$script_dir/build-module.sh" --host "$host" --kernel "$kver"

echo "==> [4/6] pack initrd + ensure vmlinuz-$kver on $host:~/shannon-qemu"
"$script_dir/make-initrd.sh" --host "$host" --kernel "$kver"

echo "==> [5/6] bind shannon device(s) to vfio-pci"
"$script_dir/driver-bind.sh" --host "$host" $([ "$devs" = "ALL" ] && echo --all || echo "$devs")

echo "==> [6/6] boot QEMU in tmux '$tmux'"
gdb_flag=
[ "$gdb" -eq 1 ] && gdb_flag=--gdb
qemu_flag=
[ -n "$qemu_bin" ] && qemu_flag="--qemu $qemu_bin"
"$script_dir/qemu-shannon-run.sh" --host "$host" --kernel "$kver" --tmux "$tmux" \
  $gdb_flag $qemu_flag $([ "$devs" = "ALL" ] && echo --all || echo "$devs")

cat <<EOF

==> QEMU launched in tmux '$tmux' on $host.
    serial log: ~/shannon-qemu/serial.log
    attach:     ssh $host -t tmux attach -t $tmux
    wait ready: scripts/qemu-console.sh --host $host --tmux $tmux wait-ready
    tail log:   scripts/qemu-console.sh --host $host --tmux $tmux tail

*** The Shannon device takes 5+ MINUTES to initialise after insmod ***
    (epilog recovery walks ~1000 superblocks). The serial log must show
    'Attached Direct-IO PCIe Flash' and 'Probed Direct-IO PCIe Flash'
    before any I/O. 'qemu-console.sh ... wait-ready' polls for those and
    crash markers; then drive the guest with:
        scripts/qemu-console.sh --host $host --tmux $tmux send 'validate-integrity.sh /dev/dfd --json'

EOF
