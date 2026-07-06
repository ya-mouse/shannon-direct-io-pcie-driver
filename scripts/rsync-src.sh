#!/bin/sh
# Rsync the shannon driver source from this repo to a remote baremetal host.
# Excludes build artifacts so only source ships. Source lands at ~/shannon-src.
#
# Usage:
#   rsync-src.sh --host HOST [--src DIR] [--dst REMOTE-PATH]
#   rsync-src.sh HOST            # shorthand: first positional arg is the host
set -eu

host=
src=.
dst='$HOME/shannon-src'

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --src) shift; src="$1" ;;
    --dst) shift; dst="$1" ;;
    --help|-h) sed -n '2,6p' "$0"; exit 0 ;;
    *) host="$1" ;;
  esac
  shift
done

[ -n "$host" ] || { echo "Usage: $0 --host HOST [--src DIR] [--dst REMOTE-PATH]" >&2; exit 2; }

# $dst is single-quoted by default so $HOME expands on the remote.
case "$dst" in
  \'*|*) : ;;
esac

rsync -az --delete \
  --exclude='*.o' --exclude='*.o.cmd' --exclude='*.o.d' --exclude='*.ko' \
  --exclude='*.mod' --exclude='*.mod.c' --exclude='*.mod.o' \
  --exclude='.tmp_*' --exclude='.*.cmd' \
  --exclude='Module.symvers' --exclude='modules.order' \
  --exclude='.git' --exclude='__pycache__' \
  "$src/" "$host:$dst/"

echo "==> source synced to $host:$dst"
ssh -o BatchMode=yes "$host" "ls -l $dst/shannon_block.c $dst/Makefile $dst/Kbuild 2>/dev/null || true"
