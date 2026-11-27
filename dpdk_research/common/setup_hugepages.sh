#!/usr/bin/env bash
# setup_hugepages.sh - reserve and mount hugepages for DPDK (run as root).
#
# Usage: sudo ./setup_hugepages.sh [count] [size]     default: 512 x 2M (1 GiB)
#        ./setup_hugepages.sh --status
#        sudo ./setup_hugepages.sh --clear            release all reserved pages
# size: 2M or 1G. 1G pages are best reserved at boot on the kernel command line:
#   default_hugepagesz=1G hugepagesz=1G hugepages=4
# DPDK ships an equivalent tool: dpdk-hugepages.py -p 2M --setup 1G
set -euo pipefail

status() {
	grep -i huge /proc/meminfo
	for n in /sys/devices/system/node/node*/hugepages/hugepages-*; do
		[ -d "$n" ] && echo "$n: total=$(cat "$n"/nr_hugepages) free=$(cat "$n"/free_hugepages)"
	done
	mount | grep hugetlbfs || echo "(no hugetlbfs mounted)"
}

case "${1:-}" in
--status) status; exit 0 ;;
--clear)
	for f in /sys/kernel/mm/hugepages/hugepages-*/nr_hugepages; do echo 0 > "$f"; done
	status; exit 0 ;;
esac

COUNT=${1:-512}
SIZE=${2:-2M}
case "$SIZE" in
2M|2048K|2048kB) KB=2048 ;;
1G|1048576K)     KB=1048576 ;;
*) echo "size must be 2M or 1G" >&2; exit 1 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

SYS=/sys/kernel/mm/hugepages/hugepages-${KB}kB
[ -d "$SYS" ] || { echo "kernel does not support $SIZE pages ($SYS missing)" >&2; exit 1; }
echo "$COUNT" > "$SYS/nr_hugepages"
GOT=$(cat "$SYS/nr_hugepages")
if [ "$GOT" -lt "$COUNT" ]; then
	echo "warning: only $GOT of $COUNT pages reserved (memory fragmented?)" >&2
fi

MNT=/dev/hugepages
[ "$KB" = 1048576 ] && MNT=/dev/hugepages1G
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -t hugetlbfs -o pagesize="$SIZE" nodev "$MNT"
status
echo
echo "To persist: /etc/sysctl.d/80-hugepages.conf -> vm.nr_hugepages = $COUNT (2M pages)"
echo "            /etc/fstab -> nodev $MNT hugetlbfs pagesize=$SIZE 0 0"
