#!/bin/sh
# Bind Shannon Direct-IO PCIe devices (1cb0:0275) to the vfio-pci driver on the
# local or a remote SSH host. Requires root. Idempotent.
#
# Usage:
#   driver-bind.sh [--host HOST] <bdf...>      # e.g. 0000:87:00.0
#   driver-bind.sh [--host HOST] --all        # auto-detect all shannon devices
set -eu

host=
devs=

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --all|--auto) devs=ALL ;;
    --help|-h) sed -n '2,8p' "$0"; exit 0 ;;
    *) devs="$devs $1" ;;
  esac
  shift
done
devs=$(printf '%s' "$devs" | sed 's/^ *//')

[ -n "$devs" ] || { echo "no devices specified; pass BDFs or --all" >&2; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$devs" = "ALL" ]; then
  if [ -n "$host" ]; then
    devs=$("$script_dir/shannon-pci-list.sh" "$host" --auto)
  else
    devs=$("$script_dir/shannon-pci-list.sh" --auto)
  fi
fi

[ -n "$devs" ] || { echo "no shannon devices found to bind" >&2; exit 1; }

# Emit the root-level shell script; pipe to local sudo or remote ssh+sudo.
emit() {
  echo 'set -x'
  echo 'modprobe vfio_pci 2>/dev/null || true'
  echo 'modprobe vfio_iommu_type1 2>/dev/null || true'
  # register shannon vid/did with vfio-pci (ignore "already exists" errors)
  printf "grep -q '1cb0 0275' /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || echo '1cb0 0275' > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true\n"
  for d in $devs; do
    # accept "87:00.0" or "0000:87:00.0"
    bdf=$(printf '%s' "$d" | sed 's/^0000://')
    full=0000:$bdf
    printf "echo '%s' > /sys/bus/pci/devices/%s/driver/unbind 2>/dev/null || true\n" "$full" "$full"
    printf "echo '%s' > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true\n" "$full"
  done
}

if [ -n "$host" ]; then
  emit | ssh -o BatchMode=yes "$host" "sudo sh"
else
  emit | sudo sh
fi

echo "==> shannon devices on ${host:-localhost}:"
if [ -n "$host" ]; then
  ssh -o BatchMode=yes "$host" "lspci -k 2>/dev/null | grep -A3 -i 1cb0:0275 || true"
else
  lspci -k 2>/dev/null | grep -A3 -i 1cb0:0275 || true
fi
