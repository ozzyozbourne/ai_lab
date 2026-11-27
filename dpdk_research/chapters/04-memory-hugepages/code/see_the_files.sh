#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# see_the_files.sh - Chapter 4: where does DPDK memory live?
#
# Starts ./sleeper in four memory modes and, while it sleeps, shows
#   - the hugepage files in /dev/hugepages        (hugetlbfs backing files)
#   - the runtime directory /run/dpdk/<prefix>    (config, fbarrays, mp socket)
#   - the interesting lines of /proc/<pid>/maps   (what is mapped where)
#   - HugetlbPages from /proc/<pid>/status        (how much hugepage memory)
# Every run uses its own --file-prefix=ch04-files-<mode> and is bounded by
# timeout. The trap removes anything left behind.
set -u
cd "$(dirname "$0")"
T="timeout -s INT -k 5 12"

cleanup() {
	pkill -INT -f 'file-prefix=ch04-files-' 2>/dev/null
	sleep 0.3
	rm -f /dev/hugepages/ch04-files-*map_*
	rm -rf /run/dpdk/ch04-files-*
	true
}
trap cleanup EXIT

# show <mode> <EAL options...>
show() {
	local mode=$1; shift
	local prefix=ch04-files-$mode out=/tmp/.ch04-sleeper.$$ pid=""
	echo
	echo "------------------------------------------------------------------"
	echo "mode: $mode"
	echo "\$ ./sleeper -l 0 --no-pci $* --file-prefix=$prefix -- 8 &"
	$T ./sleeper -l 0 --no-pci "$@" --file-prefix=$prefix -- 8 >"$out" 2>&1 &
	for _ in $(seq 50); do
		grep -q READY "$out" 2>/dev/null && break
		sleep 0.1
	done
	pid=$(sed -n 's/^READY pid=\([0-9]*\).*/\1/p' "$out")
	grep -E 'IOVA|READY|No free' "$out" | sed 's/^/  /'
	if [ -z "$pid" ]; then echo "  sleeper did not start:"; sed 's/^/  /' "$out"; return; fi

	echo "\$ ls /dev/hugepages | grep $prefix"
	local files
	files=$(ls /dev/hugepages 2>/dev/null | grep "^$prefix" || true)
	if [ -n "$files" ]; then
		echo "$files" | head -4 | sed 's/^/  /'
		echo "  ($(echo "$files" | wc -l) file(s), $(du -ch $(echo "$files" | sed 's|^|/dev/hugepages/|') 2>/dev/null | tail -1 | cut -f1) on disk)"
	else
		echo "  (no files)"
	fi

	echo "\$ ls /run/dpdk/$prefix"
	if [ -d /run/dpdk/$prefix ]; then
		ls /run/dpdk/$prefix | tr '\n' ' ' | sed 's/^/  /'; echo
	else
		echo "  (no runtime directory)"
	fi

	echo "\$ grep -E 'map_|memfd|nohuge|fbarray|config' /proc/$pid/maps   (first 5)"
	grep -E 'map_|memfd|nohuge|fbarray|/config' /proc/$pid/maps | head -5 |
		awk '{printf "  %-27s %s %s %s\n", $1, $2, $6, $7}'
	echo "\$ grep HugetlbPages /proc/$pid/status"
	grep HugetlbPages /proc/$pid/status | sed 's/^/  /'

	kill -INT "$pid" 2>/dev/null
	wait 2>/dev/null
	grep 'clean exit' "$out" | sed 's/^/  /'
	echo "  files left in /dev/hugepages after exit: $(ls /dev/hugepages | grep -c "^$prefix")"
	rm -f "$out"
}

echo "HugePages_Free before: $(awk '/HugePages_Free/ {print $2}' /proc/meminfo) (shared with other users of this machine)"
show default  -m 32
show single   -m 32 --single-file-segments
show inmemory -m 32 --in-memory
show nohuge   -m 32 --no-huge

# The hygiene lesson: a process killed with SIGKILL cannot run
# rte_eal_cleanup(), so its hugepage files stay behind and keep the pages.
echo
echo "------------------------------------------------------------------"
echo "mode: crash (kill -9 a default-mode sleeper)"
out=/tmp/.ch04-crash.$$
free0=$(awk '/HugePages_Free/ {print $2}' /proc/meminfo)
timeout -s INT -k 5 12 ./sleeper -l 0 --no-pci -m 32 --file-prefix=ch04-files-crash -- 8 >"$out" 2>&1 &
for _ in $(seq 50); do grep -q READY "$out" 2>/dev/null && break; sleep 0.1; done
pid=$(sed -n 's/^READY pid=\([0-9]*\).*/\1/p' "$out")
echo "\$ kill -9 $pid"
kill -9 "$pid"; wait 2>/dev/null
echo "  files left in /dev/hugepages: $(ls /dev/hugepages | grep -c '^ch04-files-crash')"
echo "  HugePages_Free: $free0 before the run, $(awk '/HugePages_Free/ {print $2}' /proc/meminfo) now (the files still hold the pages)"
echo "\$ rm -f /dev/hugepages/ch04-files-crashmap_* && rm -rf /run/dpdk/ch04-files-crash"
rm -f /dev/hugepages/ch04-files-crashmap_* ; rm -rf /run/dpdk/ch04-files-crash
echo "  files left: $(ls /dev/hugepages | grep -c '^ch04-files-crash'), HugePages_Free: $(awk '/HugePages_Free/ {print $2}' /proc/meminfo)"
rm -f "$out"
