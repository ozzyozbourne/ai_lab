#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: crash_postmortem.sh - what is (and is not) in a DPDK core file.
#
# panic_demo corrupts an mbuf and calls rte_panic() -> abort() -> core.
# We crash it four times and open every core with gdb:
#
#   A  hugepages (-m 32), coredump_filter 0x33  (the Linux default)
#   B  hugepages (-m 32), coredump_filter 0x73  (default + bit 6 hugetlb shared)
#   C  hugepages (-m 32), coredump_filter 0x7f  (everything except DAX)
#   D  --no-huge -m 64,   coredump_filter 0x33  (what most test setups use)
#
# coredump_filter is a per-process bitmask inherited across fork+exec, so we
# set it in a subshell right before starting the program (man 5 core):
#   bit 0 anon private   bit 1 anon shared   bit 2 file private
#   bit 3 file shared    bit 4 ELF headers   bit 5 hugetlb private
#   bit 6 hugetlb shared bit 7 DAX private   bit 8 DAX shared
# DPDK hugepages are MAP_SHARED files in hugetlbfs: bit 6. Without it the
# mbufs, rings and mempools are simply not in the core.
#
# Prerequisites: core_pattern must be a plain file name (here: "core") so
# the core lands in the current directory; root for hugepages.
set -u
cd "$(dirname "$0")"
HERE=$PWD
WORK=$(mktemp -d /tmp/ch13core.XXXXXX)
cleanup() {
	rm -rf "$WORK"
	for p in A B C D maps; do
		rm -rf /var/run/dpdk/ch13-core-$p
		rm -f /dev/hugepages/ch13-core-${p}map_* 2>/dev/null
	done
}
trap cleanup EXIT INT TERM

echo "core_pattern: $(cat /proc/sys/kernel/core_pattern)   core_uses_pid: $(cat /proc/sys/kernel/core_uses_pid)"
echo "this shell's coredump_filter: $(cat /proc/self/coredump_filter)"
[ "$(cat /proc/sys/kernel/core_pattern)" = "core" ] ||
	echo "NOTE: core_pattern is not 'core'; cores may go to systemd-coredump (coredumpctl)"

EAL_HUGE="-l 0-1 --no-pci -m 32 --vdev=net_null0"
EAL_NOHUGE="-l 0-1 --no-pci --no-huge -m 64 --vdev=net_null0"

# ---- 1. the process's memory map, while it is alive --------------------
# classify every mapping: what it is, its size, and the smaps flags that
# decide dumping (sh = shared, ht = hugetlb, dd = MADV_DONTDUMP)
classify() {
	awk '
	/^[0-9a-f]+-[0-9a-f]+ / { perm=$2; path=($6==""?"[anon]":$6) }
	/^Size:/   { size=$2 }
	/^VmFlags:/{
		f=$0; sub("VmFlags: *","",f)
		cls="anon private"
		if (f ~ / dd/ || f ~ /^dd/) cls="EAL VA reservation (dd)"
		else if (f ~ /ht/) cls=(perm ~ /s/ ? "hugetlb shared (DPDK memory)" : "hugetlb private")
		else if (path ~ /^\/run\/dpdk|^\/var\/run\/dpdk/) cls="file shared (/run/dpdk fbarray)"
		else if (path ~ /^\/memfd:|^\/dev\/zero/) cls=(perm ~ /s/ ? "anon shared (memfd)" : "anon private")
		else if (path ~ /^\//) cls=(perm ~ /s/ ? "file shared" : "file private (binary, libs)")
		else if (perm ~ /s/) cls="anon shared"
		n[cls]++; kb[cls]+=size
	}
	END { for (c in n) printf "   %-34s %4d mappings %10.1f MB\n", c, n[c], kb[c]/1024 }
	' "$1" | sort -k1,1
}
for mode in huge nohuge; do
	if [ $mode = huge ]; then args=$EAL_HUGE; what="-m 32 hugepages"; else args=$EAL_NOHUGE; what="--no-huge -m 64"; fi
	echo
	echo "== 1. mappings of a live panic_demo ($what), from /proc/<pid>/smaps"
	"$HERE/panic_demo" $args --file-prefix=ch13-core-maps -- --wait 2 \
		> "$WORK/maps.out" 2>&1 &
	PID=$!
	sleep 1.2
	classify /proc/$PID/smaps
	{ wait $PID; } 2>/dev/null
	rm -f /dev/hugepages/ch13-core-mapsmap_* 2>/dev/null
done

# ---- 2. crash four times ------------------------------------------------
crash() {     # crash <label> <filter> <eal args...>
	local label=$1 filter=$2; shift 2
	mkdir -p "$WORK/$label"
	{ (
		cd "$WORK/$label" || exit 1
		ulimit -c unlimited
		echo "$filter" > /proc/self/coredump_filter
		exec timeout -s INT -k 5 20 "$HERE/panic_demo" "$@" \
			--file-prefix=ch13-core-$label > run.log 2>&1
	); } 2>/dev/null      # hide bash's "Aborted" line; the core is the point
	rm -f /dev/hugepages/ch13-core-${label}map_* 2>/dev/null
	local core="$WORK/$label/core"
	if [ ! -f "$core" ]; then
		echo "   $label: no core written"; return
	fi
	local app disk
	app=$(stat -c %s "$core")
	disk=$(du -k "$core" | cut -f1)
	printf "   %s filter=%s  core apparent %6.1f MB, on disk %6.1f MB\n" \
		"$label" "$filter" "$(echo "$app/1048576" | bc -l)" "$(echo "$disk/1024" | bc -l)"
}

echo
echo "== 2. crash panic_demo with different coredump_filter values"
crash A 0x33 $EAL_HUGE
crash B 0x73 $EAL_HUGE
crash C 0x7f $EAL_HUGE
crash D 0x33 $EAL_NOHUGE
echo "   (what panic_demo printed before dying, run A:)"
grep -E "PANIC|corrupted|rte_mbuf_check\(\):" "$WORK/A/run.log" | sed 's/^/     /'

# ---- 3. post-mortem with gdb -------------------------------------------
echo
echo "== 3. gdb on each core: can we read the mbuf?"
for label in A B C D; do
	[ -f "$WORK/$label/core" ] || continue
	echo "-- core $label"
	gdb -q -batch -nx \
		-ex 'set print pretty off' \
		-ex 'frame function check_and_maybe_panic' \
		-ex 'p bad_mbuf' \
		-ex 'p bad_mbuf->data_len' \
		-ex 'p bad_mbuf->pool->name' \
		-ex 'x/s (char *)bad_mbuf->buf_addr + bad_mbuf->data_off' \
		"$HERE/panic_demo" "$WORK/$label/core" 2>&1 |
		grep -vE "^\[New LWP|^\[Thread debugging|^Using host libthread|^Core was generated|^Program terminated|^warning: |^Download|^#0 |libthread_db|^$" |
		sed 's/^/   /'
done
echo
echo "crash_postmortem.sh done (cores deleted by the trap)"
