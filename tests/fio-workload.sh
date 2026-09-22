#!/bin/sh
# Fio load-test workload for a Shannon block device. Runs on a host that has
# fio installed (NOT the busybox QEMU guest). Adapted from the historical
# bring-up test sequence (randread 4K, seqread 1M, randwrite 4K, seqwrite 1M).
#
# For cpus_allowed / NUMA pinning, add the flags to the fio lines below to
# match the host topology (the original used --cpus_allowed=10-63
# --cpus_allowed_policy=split --numa_mem_policy=bind:...).
#
# Usage: fio-workload.sh /dev/dfd [randread|seqread|randwrite|seqwrite|randrw|all]
set -eu

dev=${1:?usage: $0 /dev/dfd [profile]}
profile=${2:-randread}
[ -b "$dev" ] || { echo "$dev is not a block device" >&2; exit 1; }

randread() {
  fio --filename="$dev" --direct=1 --rw=randread --bs=4k --ioengine=libaio \
    --iodepth=32 --runtime=60 --numjobs=4 --time_based --group_reporting \
    --name=rand_4k_read --eta-newline=1 --readonly
}

seqread() {
  fio --filename="$dev" --direct=1 --rw=read --bs=1m --ioengine=libaio \
    --iodepth=32 --runtime=60 --numjobs=6 --time_based --group_reporting \
    --name=seq_read --eta-newline=1 --readonly
}

randwrite() {
  fio --filename="$dev" --direct=1 --rw=randwrite --bs=4k --ioengine=libaio \
    --iodepth=32 --runtime=60 --numjobs=4 --time_based --group_reporting \
    --name=rand_4k_write --eta-newline=1
}

seqwrite() {
  fio --filename="$dev" --direct=1 --rw=write --bs=1m --ioengine=libaio \
    --iodepth=32 --runtime=60 --numjobs=4 --time_based --group_reporting \
    --name=seq_write --eta-newline=1
}

# Mixed read/write: 70/30 read/write at 4K, the profile most likely to expose
# a write-completion stall (bufq_alloc_cmd_sleepable / check_pending_command_queue).
randrw() {
  fio --filename="$dev" --direct=1 --rw=randrw --rwmixread=70 --bs=4k \
    --ioengine=libaio --iodepth=32 --runtime=60 --numjobs=4 --time_based \
    --group_reporting --name=rand_4k_mixrw --eta-newline=1
}

case "$profile" in
  randread)  randread ;;
  seqread)   seqread ;;
  randwrite) randwrite ;;
  seqwrite)  seqwrite ;;
  randrw)    randrw ;;
  all)       randread; seqread; randwrite; seqwrite; randrw ;;
  *) echo "unknown profile: $profile (use randread|seqread|randwrite|seqwrite|randrw|all)" >&2; exit 2 ;;
esac
