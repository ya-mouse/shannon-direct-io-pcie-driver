#!/bin/sh
# soak-verify.sh — sustained write/read data-integrity + soak test for Shannon
# /dev/df* block devices.
#
# Methodology (shared-pattern):
#   write : generate ONE urandom pattern of <size_mb> MB in tmpfs, sha256 it
#           (EXPECT, printed to console), then write that SAME pattern to EVERY
#           /dev/dfX and sync. Because every disk receives identical bytes, all
#           disks should produce the same read-back SHA. The EXPECT SHA is
#           precomputed from the source pattern in tmpfs -- NOT from a device
#           read-back -- so a hot page cache cannot mask a write failure.
#   read  : for each /dev/dfX, read back <size_mb> MB from the device and
#           sha256 it (ACTUAL, printed to console). Run AFTER a QEMU reboot so
#           the page cache is cold and reads come from the device.
#
# The host compares the shared EXPECT (from the write-boot serial log) against
# each disk's ACTUAL (from the read-boot serial log). All disks must match the
# EXPECT; any mismatch means that disk did not durably store the data
# (write-path or completion bug).
#
# Usage:
#   soak-verify.sh write [size_mb] [rounds]   # default size_mb=1024 rounds=1
#   soak-verify.sh read  [size_mb]            # verifies the LAST write round
#
# Output (parseable lines on the serial console):
#   SOAK phase=write size_mb=1024 rounds=1 devs=/dev/dfa /dev/dfb ...
#   SOAK EXPECT round=1 sha=<hex>             # one shared expected SHA per round
#   SOAK WRITE dev=dfa round=1 done
#   ...
#   SOAK ACTUAL dev=dfa sha=<hex>             # must equal the last EXPECT
#   SOAK phase=read complete
set -eu

phase=${1:-write}
size_mb=${2:-1024}
rounds=${3:-1}

devs=$(ls /dev/df[a-z] 2>/dev/null | sort)
if [ -z "$devs" ]; then
	echo "SOAK ERROR: no /dev/df* devices found" >&2
	exit 1
fi
echo "SOAK phase=$phase size_mb=$size_mb rounds=$rounds devs=$devs"

# Drop page cache before each phase so reads/writes hit the device, not RAM.
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

if [ "$phase" = "write" ]; then
	r=1
	while [ "$r" -le "$rounds" ]; do
		# One shared random pattern for all disks (so all should match).
		dd if=/dev/urandom of=/tmp/pat bs=1M count="$size_mb" 2>/dev/null
		sha=$(sha256sum /tmp/pat | awk '{print $1}')
		echo "SOAK EXPECT round=$r sha=$sha"
		for dev in $devs; do
			# Write the SAME pattern to every disk. bs=1M (multiple of 4K).
			dd if=/tmp/pat of="$dev" bs=1M 2>/dev/null
			echo "SOAK WRITE dev=$dev round=$r done"
		done
		sync
		rm -f /tmp/pat
		r=$((r + 1))
	done
else
	# Cold read (run after reboot): read directly from each device.
	for dev in $devs; do
		dd if="$dev" of=/tmp/read bs=1M count="$size_mb" 2>/dev/null
		sha=$(sha256sum /tmp/read | awk '{print $1}')
		echo "SOAK ACTUAL dev=$dev sha=$sha"
		rm -f /tmp/read
	done
fi
echo "SOAK phase=$phase complete"
