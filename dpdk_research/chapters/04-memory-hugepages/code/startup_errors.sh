#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# startup_errors.sh - Chapter 4: the startup-error catalogue, part 1.
#
# Deliberately breaks rte_eal_init() in every way we can reproduce on this
# machine, prints the real log lines, and writes one row per error to
# errors.tsv:   id  phase  trigger  key_line  rte_errno_text  cause  fix
# The chapter's "EAL error decoder" widget is built from that file.
#
# Safety on a shared machine:
#   - every run has a unique --file-prefix=ch04-err-* and timeout 10 s
#   - the "too little hugepage memory" case uses a PRIVATE hugetlbfs mount
#     limited to 64 MB, mounted and unmounted here
#   - the "no free hugepages" case is simulated inside a private mount
#     namespace (unshare -m) where the sysfs counters are replaced by files
#     that say free_hugepages=0. The real pool is never touched.
# The trap unmounts, kills and removes /dev/hugepages/ch04-err-*map_*.
set -u
cd "$(dirname "$0")"
SCR=${SCRATCH:-$(mktemp -d /tmp/ch04-err.XXXXXX)}
MNT=$SCR/hugemnt
FAKE=$SCR/fakesys
TSV=errors.tsv
T="timeout -s INT -k 5 10"
APP=./hello_memory

cleanup() {
	pkill -INT -f 'file-prefix=ch04-err-' 2>/dev/null
	sleep 0.3
	mountpoint -q "$MNT" 2>/dev/null && umount "$MNT"
	rm -f /dev/hugepages/ch04-err-*map_* "$MNT"/* 2>/dev/null
	rm -rf /run/dpdk/ch04-err-* "$FAKE"
	rmdir "$MNT" 2>/dev/null
	[ -z "${SCRATCH:-}" ] && rmdir "$SCR" 2>/dev/null
	true
}
trap cleanup EXIT

printf 'id\tphase\ttrigger\tkey_line\terrno_text\tcause\tfix\n' > $TSV

# trial <id> <phase> <grep-pattern for key line> <cause> <fix> -- <command...>
trial() {
	local id=$1 phase=$2 pat=$3 cause=$4 fix=$5; shift 6
	local out key err
	echo
	echo "---- [$id] phase: $phase"
	echo "\$ $*" | tr '\n\t' '  ' | tr -s ' ' | sed "s|$SCR|\$SCR|g"; echo
	out=$("$@" 2>&1 | grep -v -E '^EAL: (Detected (CPU|NUMA|static))')
	echo "$out" | sed "s|$SCR|\$SCR|g; s/^/  /"
	key=$(echo "$out" | grep -m1 -E "$pat" | sed "s|$SCR|\$SCR|g")
	err=$(echo "$out" | sed -n 's/^rte_eal_init failed: //p' | head -1)
	[ -z "$err" ] && err="(process exited inside rte_eal_init)"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$phase" \
		"$(echo "$*" | tr '\n\t' '  ' | tr -s ' ' | sed "s|$SCR|\$SCR|g; s|^timeout -s INT -k 5 10 ||")" \
		"$key" "$err" "$cause" "$fix" >> $TSV
}

# 1. -l names a CPU that does not exist (this VM has CPUs 0-3)
trial E1 "1 parse arguments" "unavailable" \
	"-l 7: there is no CPU 7; EAL only accepts CPUs it detected (0-3 here)." \
	"Use CPUs that exist: see lscpu or 'EAL: Detected CPU lcores'. Map more lcores onto fewer CPUs with --lcores='(0-7)@(0-3)'." \
	-- $T $APP -l 7 --no-pci --no-huge -m 16 --file-prefix=ch04-err-l

# 2. a misspelt option (EAL's parser is lib/argparse since 26.x)
trial E2 "1 parse arguments" "unknown argument" \
	"--memory is not an EAL option. The argument parser prints the problem and exits the process (exit code 234) without returning to main()." \
	"Check the spelling against 'app --help' or linux_eal_parameters.rst. Put application options after '--'." \
	-- $T $APP -l 0 --no-pci --no-huge --memory=16 --file-prefix=ch04-err-opt

# 3. a second primary with the same --file-prefix
$T ./sleeper -l 0 --no-pci -m 32 --file-prefix=ch04-err-dup -- 6 >/dev/null 2>&1 &
sleep 1.5
trial E3 "2 config and lock" "Cannot create lock" \
	"Another primary process already holds the lock on /var/run/dpdk/<prefix>/config. Note rte_errno is not set, so rte_strerror says 'Success'." \
	"Give every independent DPDK process its own --file-prefix, or use --in-memory when no secondary needs to attach. If no process is running, the lock is stale only if the file is held: check with fuser." \
	-- $T $APP -l 1 --no-pci -m 16 --file-prefix=ch04-err-dup
wait

# 4. no free hugepages at all (simulated: fake sysfs counters in a private mount namespace)
mkdir -p "$FAKE/g" "$FAKE/n"
for f in /sys/kernel/mm/hugepages/hugepages-2048kB/*; do echo 0 > "$FAKE/g/${f##*/}"; done
for f in /sys/devices/system/node/node0/hugepages/hugepages-2048kB/*; do echo 0 > "$FAKE/n/${f##*/}"; done
echo 1024 > "$FAKE/g/nr_hugepages"; echo 1024 > "$FAKE/n/nr_hugepages"
trial E4 "5 hugepage info" "No free 2048 kB" \
	"The kernel reports free_hugepages=0 (all pages used by other programs or leaked files). With no usable page size EAL stops; the 'Permission denied' is misleading." \
	"Check grep Huge /proc/meminfo. Remove leaked files (/dev/hugepages/<prefix>map_*) of dead processes, reserve more pages (dpdk-hugepages.py -r 1G), or run with --no-huge for testing." \
	-- timeout -k 5 15 unshare -m sh -c "mount --make-rprivate / &&
	   mount --bind $FAKE/g /sys/kernel/mm/hugepages/hugepages-2048kB &&
	   mount --bind $FAKE/n /sys/devices/system/node/node0/hugepages/hugepages-2048kB &&
	   $T $APP -l 0 --no-pci --file-prefix=ch04-err-nofree"

# 5. -m larger than the free hugepages
trial E5 "6 memory init" "Not enough memory available" \
	"-m asks for 99999 MB up front, but the hugepage pool has only 2048 MB." \
	"Ask for less (-m is a pinned minimum, the heap can still grow later) or reserve more hugepages." \
	-- $T $APP -l 0 --no-pci -m 99999 --file-prefix=ch04-err-big

# 6. -m larger than what the hugetlbfs mount allows (private mount, size=64M)
mkdir -p "$MNT"
mount -t hugetlbfs -o size=64M,pagesize=2M nodev "$MNT"
trial E6 "6 memory init" "Cannot init memory" \
	"The pool has enough free pages, but the --huge-dir mount has a size=64M quota, so mmap() of page 33 fails. With --log-level=lib.eal:debug EAL says: 'attempted to allocate 64 segments, but only 32 were allocated'." \
	"Rerun with --log-level=lib.eal:debug to see which page failed. Check the mount options (mount | grep hugetlbfs), cgroup hugetlb limits, and the -m value." \
	-- $T $APP -l 0 --no-pci -m 128 --huge-dir "$MNT" --file-prefix=ch04-err-hd
echo "  (with --log-level=lib.eal:debug:)"
$T $APP -l 0 --no-pci -m 128 --huge-dir "$MNT" --file-prefix=ch04-err-hd --log-level=lib.eal:debug 2>&1 |
	grep -E 'alloc_seg|attempted to allocate' | head -2 | sed 's/^/  /'
umount "$MNT"

# 7. memory requested on a NUMA node that does not exist here
trial E7 "6 memory init" "Not enough memory available on socket" \
	"--numa-mem 0,32 asks for 32 MB on socket 1; this VM has one NUMA node, so socket 1 has no hugepages." \
	"Ask only for nodes that exist (lscpu, /sys/devices/system/node). On a 2-socket server reserve hugepages on every node you use." \
	-- $T $APP -l 0 --no-pci --numa-mem 0,32 --file-prefix=ch04-err-numa

# 8. IOVA as PA without physical addresses
trial E8 "4 IOVA mode" "Cannot use IOVA as 'PA'" \
	"--no-huge memory is ordinary 4 KB anonymous memory: EAL cannot read its physical addresses, so PA mode is impossible." \
	"Drop --iova-mode=pa (EAL picks VA), or use hugepages as root. Non-root without an IOMMU cannot use PA mode at all." \
	-- $T $APP -l 0 --no-pci --no-huge -m 16 --iova-mode=pa --file-prefix=ch04-err-iova

# 9. not an init error, but the same family: an explicit socket with no memory
echo
echo "---- [E9] phase: after init (rte_malloc_socket)"
echo "\$ $APP -l 0 --no-pci -m 16 --file-prefix=ch04-err-sock   (only the NUMA lines)"
line=$($T $APP -l 0 --no-pci -m 16 --file-prefix=ch04-err-sock 2>&1 | grep 'socket 1')
echo "  $line"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' E9 "after init (allocation)" \
	"$APP -l 0 --no-pci -m 16 (calls rte_malloc_socket(..., 1))" "$(echo "$line" | sed 's/^ *//')" \
	"none: rte_malloc returns NULL and leaves rte_errno alone" \
	"An explicit socket id never falls back to another node; node 1 has no heap on this single-node VM. (With --no-huge the socket is ignored and the call succeeds.)" \
	"Use SOCKET_ID_ANY, or the device's node (rte_eth_dev_socket_id) and check for NULL. Reserve hugepages on that node." >> $TSV

echo
echo "==== errors.tsv ($(($(wc -l < $TSV) - 1)) rows): id | phase | key line"
tail -n +2 $TSV | awk -F'\t' '{printf "  %-3s | %-29s | %s\n", $1, $2, $4}'
echo "hugepage files left by this script: $(ls /dev/hugepages | grep -c '^ch04-err-')"
