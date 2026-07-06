#!/bin/sh
# Release Shannon devices from the HOST so a QEMU debug session can grab them
# via vfio-pci. Run this BEFORE qemu-shannon-run.sh / driver-bind.sh when the
# host has the shannon driver loaded or a previous QEMU session is still up.
#
# What it does (idempotent, best-effort, needs root on the remote host):
#   1. kill the running QEMU tmux session (default "shannon") so vfio-pci
#      devices are released by the dying qemu process.
#   2. unmount any host filesystems on /dev/df* (and kill holders via fuser).
#   3. unbind each Shannon PCI device from the host "shannon" driver.
#   4. rmmod shannon (and shannon_nand_emu).
#   5. (optional, --reset) PCI function-level reset on each device for a clean
#      config space.
#
# Usage:
#   release-host.sh --host HOST [--tmux shannon] [--all | <bdf...>] [--reset] [--no-kill-qemu] [--json]
set -eu

host=
tmux=shannon
devs=
reset=0
kill_qemu=1
json=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --tmux) shift; tmux="$1" ;;
    --all|--auto) devs=ALL ;;
    --reset) reset=1 ;;
    --no-kill-qemu) kill_qemu=0 ;;
    --json) json=1 ;;
    --help|-h) sed -n '2,17p' "$0"; exit 0 ;;
    *) devs="$devs $1" ;;
  esac
  shift
done
devs=$(printf '%s' "$devs" | sed 's/^ *//')

[ -n "$host" ] || { echo "Usage: $0 --host HOST [--tmux S] [--all | <bdf...>] [--reset] [--no-kill-qemu] [--json]" >&2; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$devs" = "ALL" ] || [ -z "$devs" ]; then
  # Discover all Shannon devices on the host.
  devs=$("$script_dir/shannon-pci-list.sh" "$host" --auto 2>/dev/null || true)
fi

qdr=$(ssh -o BatchMode=yes "$host" 'echo "$HOME/shannon-qemu"')

# Build the remote release script locally (quoted heredoc + placeholders).
rs=$(mktemp)
cat > "$rs" <<'REMOTE'
#!/bin/sh
JSON=__JSON__
TMUX='__TMUX__'
KILL_QEMU=__KILL_QEMU__
RESET=__RESET__
DEVLIST='__DEVLIST__'

say() { [ "$JSON" -eq 1 ] || echo "$@"; }

to_arr() {
  printf '%s\n' $1 | awk 'BEGIN{f=1}{if(!f)printf ",";printf "\"%s\"",$0;f=0}'
}

say "==> release shannon devices from host"

# 1. kill the running QEMU tmux session (releases vfio-pci devices)
killed_qemu=false
if [ "$KILL_QEMU" -eq 1 ]; then
  if tmux has-session -t "$TMUX" 2>/dev/null; then
    say "==> kill tmux session $TMUX"
    tmux kill-session -t "$TMUX" 2>/dev/null || true
    killed_qemu=true
  fi
fi

# 2. unmount host filesystems on /dev/df* and kill holders
unmounted=
for m in $(mount 2>/dev/null | awk '$1 ~ /^\/dev\/df/ {print $1}' | sort -u); do
  mp=$(mount 2>/dev/null | awk -v d="$m" '$1==d{print $3; exit}')
  say "==> umount $m (${mp:-?})"
  [ -n "$mp" ] && command -v fuser >/dev/null 2>&1 && fuser -km "$mp" 2>/dev/null || true
  command -v fuser >/dev/null 2>&1 && fuser -k "$m" 2>/dev/null || true
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  unmounted="$unmounted $m"
done
# kill raw /dev/df* holders (fio --direct, dd, mkfs)
for d in /dev/df? /dev/df?[0-9]; do
  [ -b "$d" ] || continue
  command -v fuser >/dev/null 2>&1 && fuser -k "$d" 2>/dev/null || true
done

# 3. unbind from the host "shannon" driver
unbound=
for d in $DEVLIST; do
  drv=
  if [ -L "/sys/bus/pci/devices/$d/driver" ]; then
    drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null || true)
  fi
  if [ "$drv" = "shannon" ]; then
    say "==> unbind $d from shannon"
    echo "$d" > /sys/bus/pci/drivers/shannon/unbind 2>/dev/null || true
    unbound="$unbound $d"
  fi
done

# 4. rmmod shannon
rmmod_status=not_loaded
if lsmod 2>/dev/null | grep -q '^shannon '; then
  say "==> rmmod shannon"
  if rmmod shannon 2>/tmp/.rh-rmmod; then
    rmmod_status=ok
  else
    rmmod_status="failed: $(tr '\n' ' ' </tmp/.rh-rmmod)"
  fi
fi
rmmod shannon_nand_emu 2>/dev/null || true

# 5. optional function-level reset (device must be unbound)
reset_done=
if [ "$RESET" -eq 1 ]; then
  for d in $DEVLIST; do
    if [ -w "/sys/bus/pci/devices/$d/reset" ]; then
      if echo 1 > "/sys/bus/pci/devices/$d/reset" 2>/dev/null; then
        reset_done="$reset_done $d"
      fi
    fi
  done
fi

modules_loaded=false
lsmod 2>/dev/null | grep -qE '^shannon(_nand_emu)? ' && modules_loaded=true

if [ "$JSON" -eq 1 ]; then
  printf '{"ok":true,"killed_qemu":%s,"unmounted":[%s],"unbound":[%s],"rmmod":"%s","reset":[%s],"modules_loaded":%s}\n' \
    "$killed_qemu" "$(to_arr "$unmounted")" "$(to_arr "$unbound")" "$rmmod_status" "$(to_arr "$reset_done")" "$modules_loaded"
else
  echo "==> release summary:"
  echo "  killed_qemu: $killed_qemu"
  echo "  unmounted:   $unmounted"
  echo "  unbound:     $unbound"
  echo "  rmmod:       $rmmod_status"
  echo "  reset:       $reset_done"
  echo "  modules_loaded: $modules_loaded"
fi
REMOTE

sed -i \
  -e "s|__JSON__|$json|" \
  -e "s|__TMUX__|$tmux|" \
  -e "s|__KILL_QEMU__|$kill_qemu|" \
  -e "s|__RESET__|$reset|" \
  -e "s|__DEVLIST__|$devs|" \
  "$rs"

scp -q "$rs" "$host:/tmp/.release-host.sh"
rm -f "$rs"
ssh -o BatchMode=yes -t "$host" "sudo sh /tmp/.release-host.sh; rm -f /tmp/.release-host.sh"
