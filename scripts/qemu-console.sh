#!/bin/sh
# Inspect and drive a running Shannon QEMU guest on a remote baremetal host.
# Reads the continuous serial log written by qemu-shannon-run.sh (tmux pipe-pane
# in interactive mode, or -serial file: in --capture-only mode), and can send
# keys to the interactive tmux console.
#
# Usage:
#   qemu-console.sh --host HOST [--tmux S] [--serial-log P] [--json] \
#       tail [--lines N]
#       grep PATTERN
#       snapshot
#       send "CMD"            # sends CMD + Enter to the guest console
#       send-keys "CMD"       # sends CMD without Enter
#       wait-ready [--timeout 600] [--interval 10]
#       crash-check
#
# --json emits a single JSON object on stdout (human progress on stderr):
#   tail        {"ok":true,"lines":[...]}
#   grep        {"ok":true,"matches":[...],"count":N}
#   snapshot    {"ok":true,"lines":[...]}
#   send        {"ok":true,"sent":"CMD"}
#   wait-ready  {"ok":bool,"ready":bool,"crash":bool,"elapsed_s":N,"last_lines":[...]}
#   crash-check {"ok":true,"crash":bool,"matches":[...]}
set -eu

host=
tmux=shannon
serial_log=
json=0
action=

while [ $# -gt 0 ] && [ -z "$action" ]; do
  case "$1" in
    --host) shift; host="$1" ;;
    --tmux) shift; tmux="$1" ;;
    --serial-log) shift; serial_log="$1" ;;
    --json) json=1 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) action="$1" ;;
  esac
  shift
done
# Anything left in "$@" is the action's own arguments (e.g. grep PATTERN,
# send "CMD", wait-ready --timeout 600).

[ -n "$action" ] || { echo "no action given (tail|grep|snapshot|send|send-keys|wait-ready|crash-check)" >&2; exit 2; }
[ -n "$host" ] || { echo "--host is required" >&2; exit 2; }

# Resolve serial_log default remotely.
if [ -z "$serial_log" ]; then
  serial_log_abs=$(ssh -o BatchMode=yes "$host" 'echo "$HOME/shannon-qemu/serial.log"')
else
  case "$serial_log" in
    *'$'*|*'~'*) serial_log_abs=$(ssh -o BatchMode=yes "$host" "echo $serial_log") ;;
    *) serial_log_abs="$serial_log" ;;
  esac
fi

say() { [ "$json" -eq 1 ] || echo "$@" >&2; }

# json_array_from_stdin: emit a JSON array string with minimal escaping.
json_array() {
  awk 'BEGIN{f=1}{ gsub(/\r/,""); gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); if(!f)printf ","; printf "\"%s\"",$0; f=0 }'
}

remote_tail() {
  n=$1
  ssh -o BatchMode=yes "$host" "tail -n '$n' '$serial_log_abs' 2>/dev/null || true"
}

case "$action" in
  tail)
    lines=400
    [ $# -ge 1 ] && lines=$1
    out=$(remote_tail "$lines")
    if [ "$json" -eq 1 ]; then
      arr=$(printf '%s\n' "$out" | json_array)
      printf '{"ok":true,"path":"%s","lines":[%s]}\n' "$serial_log_abs" "$arr"
    else
      printf '%s\n' "$out"
    fi
    ;;

  grep)
    [ $# -ge 1 ] || { echo "grep needs a PATTERN" >&2; exit 2; }
    pat=$1
    out=$(ssh -o BatchMode=yes "$host" "grep -E '$pat' '$serial_log_abs' 2>/dev/null || true")
    if [ "$json" -eq 1 ]; then
      arr=$(printf '%s\n' "$out" | json_array)
      cnt=$(printf '%s\n' "$out" | grep -c . || true)
      printf '{"ok":true,"pattern":"%s","count":%s,"matches":[%s]}\n' "$pat" "$cnt" "$arr"
    else
      printf '%s\n' "$out"
    fi
    ;;

  snapshot)
    out=$(ssh -o BatchMode=yes "$host" "tmux capture-pane -t '$tmux' -p -S -400 2>/dev/null || true")
    if [ "$json" -eq 1 ]; then
      arr=$(printf '%s\n' "$out" | json_array)
      printf '{"ok":true,"tmux":"%s","lines":[%s]}\n' "$tmux" "$arr"
    else
      printf '%s\n' "$out"
    fi
    ;;

  send|send-keys)
    [ $# -ge 1 ] || { echo "$action needs a CMD" >&2; exit 2; }
    cmd=$1
    if [ "$action" = "send" ]; then
      ssh -o BatchMode=yes "$host" "tmux send-keys -t '$tmux' -- '$cmd' Enter"
    else
      ssh -o BatchMode=yes "$host" "tmux send-keys -t '$tmux' -- '$cmd'"
    fi
    if [ "$json" -eq 1 ]; then
      printf '{"ok":true,"tmux":"%s","sent":"%s","enter":%s}\n' "$tmux" "$cmd" $([ "$action" = "send" ] && echo true || echo false)
    else
      echo "sent: $cmd"
    fi
    ;;

  wait-ready)
    timeout=600
    interval=10
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) shift; timeout=$1 ;;
        --interval) shift; interval=$1 ;;
      esac
      shift
    done
    ready_pat='Probed Direct-IO PCIe Flash'
    crash_pat='kernel BUG|Oops:|Call trace:|shn_alarm:|invalid opcode|Unable to handle|page fault'
    say "waiting for device ready (timeout ${timeout}s, interval ${interval}s)..."
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
      out=$(ssh -o BatchMode=yes "$host" "tail -n 4000 '$serial_log_abs' 2>/dev/null || true")
      if echo "$out" | grep -q "$ready_pat"; then
        last=$(echo "$out" | tail -n 20)
        if [ "$json" -eq 1 ]; then
          arr=$(printf '%s\n' "$last" | json_array)
          printf '{"ok":true,"ready":true,"crash":false,"elapsed_s":%s,"last_lines":[%s]}\n' "$elapsed" "$arr"
        else
          echo "READY after ${elapsed}s"
        fi
        exit 0
      fi
      if echo "$out" | grep -qE "$crash_pat"; then
        crash_lines=$(echo "$out" | grep -E "$crash_pat" | tail -n 20)
        if [ "$json" -eq 1 ]; then
          arr=$(printf '%s\n' "$crash_lines" | json_array)
          last=$(echo "$out" | tail -n 20 | json_array)
          printf '{"ok":false,"ready":false,"crash":true,"elapsed_s":%s,"matches":[%s],"last_lines":[%s]}\n' "$elapsed" "$arr" "$last"
        else
          echo "CRASH detected after ${elapsed}s:"
          printf '%s\n' "$crash_lines"
        fi
        exit 2
      fi
      sleep "$interval"
      elapsed=$((elapsed + interval))
    done
    last=$(ssh -o BatchMode=yes "$host" "tail -n 20 '$serial_log_abs' 2>/dev/null || true")
    if [ "$json" -eq 1 ]; then
      arr=$(printf '%s\n' "$last" | json_array)
      printf '{"ok":false,"ready":false,"crash":false,"elapsed_s":%s,"last_lines":[%s]}\n' "$timeout" "$arr"
    else
      echo "TIMEOUT after ${timeout}s — device not ready"
    fi
    exit 1
    ;;

  crash-check)
    crash_pat='kernel BUG|Oops:|Call trace:|shn_alarm:|invalid opcode|Unable to handle|page fault'
    out=$(ssh -o BatchMode=yes "$host" "grep -E '$crash_pat' '$serial_log_abs' 2>/dev/null || true")
    if [ -n "$out" ]; then
      if [ "$json" -eq 1 ]; then
        arr=$(printf '%s\n' "$out" | json_array)
        printf '{"ok":true,"crash":true,"matches":[%s]}\n' "$arr"
      else
        echo "CRASH markers found:"
        printf '%s\n' "$out"
      fi
      exit 0
    else
      if [ "$json" -eq 1 ]; then
        printf '{"ok":true,"crash":false,"matches":[]}\n'
      else
        echo "no crash markers"
      fi
      exit 1
    fi
    ;;

  *)
    echo "unknown action: $action" >&2; exit 2 ;;
esac
