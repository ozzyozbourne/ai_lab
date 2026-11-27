#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13, exercise 3 (solution): crash panic_demo with
# coredump_filter=0x7f on hugepages and run find_pool.gdb on the core.
set -u
cd "$(dirname "$0")"
HERE=$PWD
W=$(mktemp -d /tmp/ch13ex3.XXXXXX)
trap 'rm -rf "$W" /var/run/dpdk/ch13-ex3; rm -f /dev/hugepages/ch13-ex3map_*' EXIT
{ ( cd "$W" && ulimit -c unlimited && echo 0x7f > /proc/self/coredump_filter &&
    exec timeout -s INT 20 "$HERE/../panic_demo" -l 0-1 --no-pci -m 32 \
	--file-prefix=ch13-ex3 --vdev=net_null0 > run.log 2>&1 ); } 2>/dev/null
gdb -q -batch -nx -x find_pool.gdb "$HERE/../panic_demo" "$W/core" 2>&1 |
	grep -vE "^\[New LWP|^\[Thread debugging|^Using host libthread|^warning:|^$|^Core was|^Program terminated|^#0 "
