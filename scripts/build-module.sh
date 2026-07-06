#!/bin/sh
# Build shannon.ko on a remote baremetal host for a given kernel version.
# Ensures linux-headers-<kver> are present (via fetch-kernel.sh) before building.
#
# Usage:
#   build-module.sh --host HOST --kernel <kver> [--src PATH] [-j N]
#   build-module.sh HOST <kver>     # shorthand
set -eu

host=
kver=
src='$HOME/shannon-src'
jobs=

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --kernel) shift; kver="$1" ;;
    --src) shift; src="$1" ;;
    -j|--jobs) shift; jobs="$1" ;;
    --help|-h) sed -n '2,7p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      elif [ -z "$kver" ]; then kver="$1"
      else echo "$0: unexpected arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST --kernel <kver> [--src PATH] [-j N]" >&2; exit 2; }
[ -n "$kver" ] || { echo "--kernel <kver> is required" >&2; exit 2; }

if [ -z "$jobs" ]; then
  jobs=$(ssh -o BatchMode=yes "$host" 'nproc 2>/dev/null || echo 4')
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Ensure linux-headers-<kver> are present (downloads + installs if missing).
echo "==> ensuring headers for $kver are present"
"$script_dir/fetch-kernel.sh" --host "$host" --kernel "$kver" --headers-only

# `src` is single-quoted when default, so $HOME expands remotely. If the user
# passed a literal path, that's fine too.
ssh -o BatchMode=yes -t "$host" "
set -eux
cd $src
[ -d /lib/modules/$kver/build ] || { echo 'headers for $kver still missing after fetch-kernel' >&2; exit 2; }
make KERNELVER=$kver clean || true
make -j$jobs KERNELVER=$kver shipped modules
echo '==> built:'
ls -l shannon.ko
modinfo shannon.ko | head -10
"
