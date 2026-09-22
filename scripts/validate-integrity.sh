#!/bin/sh
# Verify integrity of a Shannon block device: write a known pattern, read it
# back, sha256-compare; plus a 4K-aligned write/read at a 1 GiB offset, and a
# marker overwrite-check.
#
# Runs INSIDE the QEMU guest (busybox userspace) where /dev/df* exists.
# The make-initrd.sh script copies this file to /usr/local/bin/validate-integrity.sh.
#
# Usage: validate-integrity.sh /dev/dfd [size_mb] [--json]
#
# --json: emit a single JSON object on stdout (human progress suppressed):
#   {"ok":true,"device":"/dev/dfd","size_mb":256,"checks":[{"name":...,"ok":bool,...}]}
set -eu

dev=
size_mb=256
json=0

for a in "$@"; do
  case "$a" in
    --json) json=1 ;;
    --help|-h) sed -n '2,12p' "$0"; exit 0 ;;
    *)
      if [ -z "$dev" ]; then dev="$a"
      elif [ -z "${size_mb_set:-}" ]; then size_mb="$a"; size_mb_set=1
      else echo "$0: unexpected arg: $a" >&2; exit 2; fi ;;
  esac
done

[ -n "$dev" ] || { echo "Usage: $0 /dev/dfd [size_mb] [--json]" >&2; exit 2; }
[ -b "$dev" ] || { echo "$dev is not a block device" >&2; exit 1; }

# say: human progress only (suppressed in --json mode).
say() { [ "$json" -eq 1 ] || echo "$@"; }
CHECKS=
rc=0
add_check() {
  # add_check NAME OK EXTRA_JSON
  name=$1; ok=$2; extra=$3
  sep=
  [ -z "$CHECKS" ] || sep=','
  CHECKS="$CHECKS$sep{\"name\":\"$name\",\"ok\":$ok$extra}"
}

tmp=/tmp/shannon-verify-$$
mkdir -p "$tmp"

say "== device =="
say "$(cat /sys/block/"$(basename "$dev")"/device/model 2>/dev/null || true)"
say "$(blockdev --getsize64 "$dev" 2>/dev/null || true)"

# 1) sequential write/read/compare
say "== 1) sequential write/read/compare (${size_mb} MB) =="
dd if=/dev/urandom of="$tmp/src.img" bs=1M count="$size_mb" 2>/dev/null
src_sha=$(sha256sum "$tmp/src.img" | awk '{print $1}')
say "src sha256: $src_sha"
dd if="$tmp/src.img" of="$dev" bs=1M count="$size_mb" 2>/dev/null
sync
dd if="$dev" of="$tmp/dst.img" bs=1M count="$size_mb" 2>/dev/null
dst_sha=$(sha256sum "$tmp/dst.img" | awk '{print $1}')
say "dst sha256: $dst_sha"
if [ "$src_sha" = "$dst_sha" ]; then
  say "SEQ: OK"
  add_check "seq_${size_mb}MB" true ",\"src_sha\":\"$src_sha\",\"dst_sha\":\"$dst_sha\""
else
  say "SEQ: FAIL"
  cmp "$tmp/src.img" "$tmp/dst.img" 2>/dev/null || true
  add_check "seq_${size_mb}MB" false ",\"src_sha\":\"$src_sha\",\"dst_sha\":\"$dst_sha\""
  rc=1
fi

# 2) 4K-aligned random write/read at offset 1 GiB
say "== 2) 4K-aligned write/read at offset 1 GiB =="
off_blk=$((1024 * 1024 * 1024 / 4096))
dd if=/dev/urandom of="$tmp/blk.img" bs=4K count=256 2>/dev/null
b_sha=$(sha256sum "$tmp/blk.img" | awk '{print $1}')
dd if="$tmp/blk.img" of="$dev" bs=4K count=256 seek="$off_blk" 2>/dev/null
sync
dd if="$dev" of="$tmp/blk2.img" bs=4K count=256 skip="$off_blk" 2>/dev/null
b2_sha=$(sha256sum "$tmp/blk2.img" | awk '{print $1}')
if [ "$b_sha" = "$b2_sha" ]; then
  say "4K: OK"
  add_check 4k_offset_1GiB true ",\"src_sha\":\"$b_sha\",\"dst_sha\":\"$b2_sha\""
else
  say "4K: FAIL"
  cmp "$tmp/blk.img" "$tmp/blk2.img" 2>/dev/null || true
  add_check 4k_offset_1GiB false ",\"src_sha\":\"$b_sha\",\"dst_sha\":\"$b2_sha\""
  rc=1
fi

# 3) marker overwrite-check
say "== 3) marker overwrite-check =="
printf 'SHANNON-INTEGRITY-MARKER-0123456789ABCDEF' > "$tmp/marker"
dd if="$tmp/marker" of="$dev" bs=4K count=1 conv=notrunc 2>/dev/null
sync
# Read back a whole 4K block, then compare only the marker's own length: the
# readback is padded with the device's existing contents, so comparing the
# files directly would always report a size mismatch.
dd if="$dev" of="$tmp/marker2" bs=4K count=1 2>/dev/null
mlen=$(wc -c < "$tmp/marker")
head -c "$mlen" "$tmp/marker2" > "$tmp/marker3"
if cmp -s "$tmp/marker" "$tmp/marker3" 2>/dev/null; then
  say "MARKER: OK"
  add_check marker true ""
else
  say "MARKER: FAIL"
  add_check marker false ""
  rc=1
fi

rm -rf "$tmp"

if [ "$json" -eq 1 ]; then
  if [ "$rc" -eq 0 ]; then overall=true; else overall=false; fi
  printf '{"ok":%s,"device":"%s","size_mb":%s,"checks":[%s]}\n' "$overall" "$dev" "$size_mb" "$CHECKS"
else
  if [ "$rc" -eq 0 ]; then
    echo "==> INTEGRITY OK"
  else
    echo "==> INTEGRITY FAILED (rc=$rc)"
  fi
fi
exit $rc
