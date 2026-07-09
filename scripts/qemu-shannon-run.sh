#!/bin/sh
# Launch QEMU on a remote baremetal host with Shannon PCIe device(s) passed
# through via vfio-pci. The guest boots a busybox initrd that insmods shannon.ko.
#
# Serial capture:
#   - Interactive (--tmux, default): -serial mon:stdio in a tmux session, AND
#     tmux pipe-pane continuously tees the console to --serial-log (default
#     ~/shannon-qemu/serial.log). You get an interactive console + a full log.
#   - Headless (--capture-only): -serial file:<log> -monitor none -display none,
#     no console; the log file grows. Best for the wait-for-probe loop.
#   Use scripts/qemu-console.sh to tail/grep/send/wait-ready against the log.
#
# Usage:
#   qemu-shannon-run.sh --host HOST [opts] (--all | <bdf...>)
#   qemu-shannon-run.sh --host HOST --list
#   qemu-shannon-run.sh --host HOST --all --dry-run
#   qemu-shannon-run.sh --host HOST --all --capture-only --json
#
# Options:
#   --host HOST        SSH host (required)
#   --kernel VER       kernel version; uses vmlinuz-VER in --qemu-dir (default 6.8.0-48-generic)
#   --initrd PATH      initrd path relative to --qemu-dir (default initrd.img)
#   --qemu-dir DIR     dir with vmlinuz/initrd on host (default ~/shannon-qemu)
#   --qemu BIN         qemu binary (default qemu-system-x86_64)
#   -m MEM             guest RAM (default 16g; epilog recovery needs headroom)
#   -s N               vCPUs (default 8)
#   --gdb              add -gdb tcp::3333 + nokaslr (see shannon-kernel-debug skill)
#   --tmux NAME        run inside a detached remote tmux session NAME (default: shannon if serial capture)
#   --serial-log PATH  serial log path on host (default <qemu-dir>/serial.log)
#   --capture-only     headless: -serial file:<log>, no interactive console
#   --json             emit a JSON launch summary on stdout
#   --list             list shannon devices and exit
#   --dry-run          print the qemu command, don't run
#   --all | <bdf...>   which devices to pass through (0000:87:00.0 or 87:00.0)
set -eu

# Portable in-place sed: sedi FILE EXPR...  (BSD sed -i and GNU sed -i differ
# in how the backup-extension argument is consumed; avoid -i entirely).
sedi() { _sf=$1; shift; sed "$@" "$_sf" > "$_sf.sedi.$$" && mv "$_sf.sedi.$$" "$_sf"; }

host=
kver=6.8.0-48-generic
qemu_dir='$HOME/shannon-qemu'
qemu_bin=qemu-system-x86_64
memory=16g
smp=8
gdb=0
tmux=
dry=0
list=0
json=0
capture_only=0
serial_log=
release=0
devs=
initrd=

usage() { sed -n '2,28p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --kernel) shift; kver="$1" ;;
    --initrd) shift; initrd="$1" ;;
    --qemu-dir) shift; qemu_dir="$1" ;;
    --qemu) shift; qemu_bin="$1" ;;
    -m) shift; memory="$1" ;;
    -s) shift; smp="$1" ;;
    --gdb) gdb=1 ;;
    --tmux) shift; tmux="$1" ;;
    --serial-log) shift; serial_log="$1" ;;
    --capture-only) capture_only=1 ;;
    --release) release=1 ;;
    --json) json=1 ;;
    --list) list=1 ;;
    --dry-run) dry=1 ;;
    --all|--auto) devs=ALL ;;
    --help|-h) usage; exit 0 ;;
    *) devs="$devs $1" ;;
  esac
  shift
done
devs=$(printf '%s' "$devs" | sed 's/^ *//')

[ -n "$host" ] || { echo "--host is required" >&2; usage; exit 2; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$list" -eq 1 ]; then
  exec "$script_dir/shannon-pci-list.sh" "$host" --pretty
fi

append="panic=5 init=/init console=ttyS0 watchdog_thresh=60"
gdbarg=
if [ "$gdb" -eq 1 ]; then
  append="$append nokaslr"
  gdbarg="-gdb tcp::3333"
fi

initrd_arg=${initrd:-initrd.img}

# --dry-run: print the human-readable qemu command WITHOUT contacting the host.
if [ "$dry" -eq 1 ]; then
  if [ "$devs" = "ALL" ]; then
    vfio_repr="-device vfio-pci,host=<each 1cb0:0275 BDF; see shannon-pci-list.sh --auto>"
  else
    vfio_repr=
    for d in $devs; do
      bdf=$(printf '%s' "$d" | sed 's/^0000://')
      vfio_repr="$vfio_repr -device vfio-pci,host=$bdf"
    done
  fi
  if [ "$capture_only" -eq 1 ]; then
    serial_repr="-serial file:<serial-log> -monitor none -display none"
  else
    serial_repr="-serial mon:stdio -nographic"
  fi
  echo "# would run on $host in tmux '${tmux:-auto}' (qemu-dir: $qemu_dir):"
  echo "  cd $qemu_dir && $qemu_bin -m $memory -smp $smp \\"
  echo "    -kernel vmlinuz-$kver -initrd $initrd_arg \\"
  echo "    -append '$append' $serial_repr $gdbarg $vfio_repr"
  exit 0
fi

if [ "$devs" = "ALL" ]; then
  devs=$("$script_dir/shannon-pci-list.sh" "$host" --auto)
fi
[ -n "$devs" ] || { echo "no devices; pass BDFs or --all" >&2; exit 2; }

vfio=
for d in $devs; do
  bdf=$(printf '%s' "$d" | sed 's/^0000://')
  vfio="$vfio -device vfio-pci,host=$bdf"
done

# Resolve qemu_dir + serial_log to absolute remote paths (expand $HOME / ~ there).
case "$qemu_dir" in
  *'$'*|*'~'*) qdr=$(ssh -o BatchMode=yes "$host" "echo $qemu_dir") ;;
  *) qdr="$qemu_dir" ;;
esac
[ -n "$qdr" ] || qdr="$qemu_dir"

if [ -z "$serial_log" ]; then
  serial_log_abs="$qdr/serial.log"
else
  case "$serial_log" in
    *'$'*|*'~'*) serial_log_abs=$(ssh -o BatchMode=yes "$host" "echo $serial_log") ;;
    *) serial_log_abs="$serial_log" ;;
  esac
fi

# Serial args: headless file capture vs interactive mon:stdio.
if [ "$capture_only" -eq 1 ]; then
  serial_args="-serial file:$serial_log_abs -monitor none -display none"
else
  serial_args="-serial mon:stdio -nographic"
fi

# Default tmux session to "shannon" whenever we have serial capture (so the log
# can be piped). capture-only also runs in tmux for process persistence.
if [ -z "$tmux" ] && { [ "$capture_only" -eq 1 ] || [ -n "$serial_log" ]; }; then
  tmux=shannon
fi

# Optionally release the host driver + kill any prior QEMU session first.
if [ "$release" -eq 1 ]; then
  echo "==> releasing host (kill prior QEMU, unmount df, rmmod shannon, unbind)" >&2
  "$script_dir/release-host.sh" --host "$host" --tmux "${tmux:-shannon}" --all
fi

# Build the qemu run script locally (quoted heredoc + placeholder substitution).
run_tmp=$(mktemp)
cat > "$run_tmp" <<'QEMU'
#!/bin/sh
cd '__QEMU_DIR__' || exit 1
exec __QEMU_BIN__ -m __MEM__ -smp __SMP__ \
  -kernel vmlinuz-__KVER__ \
  -initrd __INITRD__ \
  -append '__APPEND__' \
  __SERIAL__ __GDB____VFIO__
QEMU

sedi "$run_tmp" \
  -e "s|__QEMU_DIR__|$qdr|" \
  -e "s|__QEMU_BIN__|$qemu_bin|" \
  -e "s|__MEM__|$memory|" \
  -e "s|__SMP__|$smp|" \
  -e "s|__KVER__|$kver|" \
  -e "s|__INITRD__|$initrd_arg|" \
  -e "s|__APPEND__|$append|" \
  -e "s|__SERIAL__|$serial_args|" \
  -e "s|__GDB__|$gdbarg|" \
  -e "s|__VFIO__|$vfio|"

# Ship the run script to the remote qemu dir.
ssh -o BatchMode=yes "$host" "mkdir -p '$qdr'"
scp -q "$run_tmp" "$host:$qdr/.run-qemu.sh"
rm -f "$run_tmp"

# JSON helper: build devices array.
devs_json=$(printf '%s\n' $devs | awk 'BEGIN{f=1}{ if(!f)printf ","; printf "\"%s\"",$0; f=0 }')
devs_json="[$devs_json]"

if [ -n "$tmux" ]; then
  ssh -o BatchMode=yes "$host" "chmod +x '$qdr/.run-qemu.sh'; \
    : > '$serial_log_abs'; \
    tmux new-session -d -s '$tmux' '$qdr/.run-qemu.sh' 2>/dev/null; \
    tmux has-session -t '$tmux' 2>/dev/null && { \
      $([ "$capture_only" -eq 0 ] && printf "tmux pipe-pane -t '$tmux' -o 'cat >> \\\"$serial_log_abs\\\"';") \
    } && echo OK"
  rc=$?
else
  # No tmux, interactive only (no log capture).
  if [ "$json" -eq 1 ]; then
    echo "==> interactive console (no --tmux; serial not logged). Attach to the SSH tty." >&2
  fi
  ssh -o BatchMode=yes -t "$host" "sh '$qdr/.run-qemu.sh'"
  rc=$?
fi

if [ "$json" -eq 1 ]; then
  if [ -n "$tmux" ]; then
    ready=true
    [ "$rc" -eq 0 ] || ready=false
    printf '{"ok":%s,"host":"%s","tmux":"%s","capture_only":%s,"serial_log":"%s","kernel":"%s","devices":%s}\n' \
      "$ready" "$host" "$tmux" $([ "$capture_only" -eq 1 ] && echo true || echo false) "$serial_log_abs" "$kver" "$devs_json"
  else
    printf '{"ok":false,"host":"%s","error":"interactive session ended (no tmux)"}\n' "$host"
  fi
else
  if [ -n "$tmux" ]; then
    echo "==> QEMU launched in tmux '$tmux' on $host"
    echo "    serial log: $serial_log_abs"
    echo "    attach:    ssh $host -t tmux attach -t $tmux"
    echo "    tail log:  scripts/qemu-console.sh --host $host --tmux $tmux --serial-log '$serial_log_abs' tail"
    echo "    wait ready:scripts/qemu-console.sh --host $host --serial-log '$serial_log_abs' wait-ready"
    echo "*** The Shannon device takes 5+ MINUTES to initialise after insmod ***"
  fi
fi
