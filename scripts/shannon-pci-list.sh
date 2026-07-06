#!/bin/sh
# List Shannon Direct-IO PCIe devices (vendor 1cb0:0275) on the local host or a remote SSH host.
# Output formats are designed to be reused by driver-bind.sh / qemu-shannon-run.sh.
#
# Usage:
#   shannon-pci-list.sh [host]                 # one BDF per line (0000:87:00.0)
#   shannon-pci-list.sh [host] --auto|--all    # space-separated BDFs (for $(...))
#   shannon-pci-list.sh [host] --pretty|-p     # BDF + lspci description
#   shannon-pci-list.sh [host] --json          # JSON: {"ok":true,"devices":[{bdf,desc}]}
#   shannon-pci-list.sh --host HOST ...        # explicit --host form
set -eu

VID=1cb0
DID=0275
host=
mode=list
json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --auto|--all) mode=auto ;;
    --pretty|-p) mode=pretty ;;
    --json) json=1 ;;
    --host) shift; host="$1" ;;
    --help|-h) sed -n '2,10p' "$0"; exit 0 ;;
    *)
      if [ -z "$host" ]; then host="$1"
      else echo "$0: unknown arg: $1" >&2; exit 2; fi ;;
  esac
  shift
done

if [ -n "$host" ]; then
  rc_wrap() { ssh -o BatchMode=yes "$host" "$@"; }
else
  rc_wrap() { "$@"; }
fi

# lspci -nnD prints domain-prefixed BDFs: "0000:87:00.0 ... [1cb0:0275]"
raw=$(rc_wrap lspci -nnD 2>/dev/null | grep -i "$VID:$DID" || true)

if [ "$json" -eq 1 ]; then
  if [ -z "$raw" ]; then
    printf '{"ok":false,"error":"no shannon devices (1cb0:0275) found","host":"%s"}\n' "${host:-localhost}"
    exit 1
  fi
  arr=$(printf '%s\n' "$raw" | awk '
    BEGIN { first = 1 }
    {
      bdf = $1
      $1 = ""; desc = substr($0, 2)
      gsub(/\\/, "\\\\", desc)
      gsub(/"/, "\\\"", desc)
      if (!first) printf ","
      printf "{\"bdf\":\"%s\",\"desc\":\"%s\"}", bdf, desc
      first = 0
    }')
  printf '{"ok":true,"host":"%s","devices":[%s]}\n' "${host:-localhost}" "$arr"
  exit 0
fi

if [ -z "$raw" ]; then
  echo "no shannon devices (vendor $VID device $DID) found" >&2
  exit 1
fi

bdfs=$(printf '%s\n' "$raw" | awk '{print $1}')

case "$mode" in
  list)
    printf '%s\n' "$bdfs" ;;
  auto)
    printf '%s\n' "$bdfs" | tr '\n' ' '
    echo ;;
  pretty)
    printf '%s\n' "$raw" ;;
esac
