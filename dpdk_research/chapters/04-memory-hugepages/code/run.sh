#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# run.sh - build and run every Chapter 4 example. Self-cleaning, every run
# bounded by timeout, unique --file-prefix=ch04-*, --no-pci everywhere.
# Hugepage runs use -m 16..64 (the pool is shared with other users).
#
#   ./run.sh 2>&1 | tee expected_output.txt
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
source "$ENV_SH"
T="timeout -s INT -k 5 20"

cleanup() {
	pkill -INT -f 'file-prefix=ch04-' 2>/dev/null
	sleep 0.3
	rm -f /dev/hugepages/ch04-*map_* "$PWD/x.sock"
	rm -rf /run/dpdk/ch04-*
	true
}
trap cleanup EXIT
strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
# run: echo the command (paths shortened), run it, show its exit code.
# The two constant "Detected ..." lines are dropped to keep the log short.
run() {
	echo "\$ $*" | sed "s|$PWD|\$PWD|g; s|^\$ timeout -s INT -k 5 20 |\$ |"
	stdbuf -oL -eL "$@" 2>&1 | strip_ansi | sed "s|$PWD|\$PWD|g" |
		grep -v -E '^EAL: Detected (CPU lcores|NUMA nodes|static linkage)'
	echo "[exit code ${PIPESTATUS[0]}]"
}
section() { echo; echo "=================== $* ==================="; }

section "0. build (make, -Wall -Wextra)"
make -s clean
make -s all 2>&1 | strip_ansi
echo "[make exit code ${PIPESTATUS[0]}]"
echo "HugePages: $(awk '/HugePages_Total/ {t=$2} /HugePages_Free/ {f=$2} END {print t" total, "f" free"}' /proc/meminfo) x 2 MB (shared machine)"

section "1. hello_memory: rte_malloc, stats, va vs iova"
echo "--- 1a. --no-huge: 4 KB anonymous memory, IOVA mode VA"
run $T ./hello_memory -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-hm
echo "--- 1b. 64 MB of 2 MB hugepages, root: IOVA mode PA"
run $T ./hello_memory -l 0 --no-pci -m 64 --file-prefix=ch04-hm2

section "1c. tlb_bench: the same pointer chase on 4 KB and on 2 MB pages"
run $T ./tlb_bench -l 0 --no-pci --no-huge -m 128 --file-prefix=ch04-tlb4k
run $T ./tlb_bench -l 0 --no-pci --huge-unlink --file-prefix=ch04-tlb2m

section "2. see_the_files.sh: where the memory lives, in four modes"
./see_the_files.sh 2>&1 | strip_ansi | grep -v -E '^ *EAL: Detected'

section "3. memseg_walk: memseg lists, memsegs and IOVA contiguity"
echo "--- 3a. -m 32, PA mode: 16 pinned pages, scattered IOVAs"
run $T ./memseg_walk -l 0 --no-pci -m 32 --file-prefix=ch04-ms
echo "--- 3b. no -m (heap grows page by page), PA mode: the 3 MB IOVA_CONTIG zone, 5 tries"
for i in 1 2 3 4 5; do
	$T ./memseg_walk -l 0 --no-pci --file-prefix=ch04-ms 2>&1 | grep -A1 'IOVA_CONTIG):' | tail -1 | sed "s/^/  try $i:/"
done
echo "--- 3c. same, --iova-mode=va: IOVA == VA, always contiguous"
run $T ./memseg_walk -l 0 --no-pci --iova-mode=va --file-prefix=ch04-ms
echo "--- 3d. --no-huge: every 4 KB page is its own memseg"
run $T ./memseg_walk -l 0 --no-pci --no-huge -m 32 --file-prefix=ch04-ms

section "4. memzones: reserve, lookup, EEXIST, ENOSPC, bounded"
run $T ./memzones -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-mz

section "5. heap_events (deep dive): mem events, validator, external heap"
echo "--- 5a. dynamic hugepage memory, nothing pinned"
run $T ./heap_events -l 0 --no-pci --huge-unlink --file-prefix=ch04-ev
echo "--- 5b. -m 16 pins 16 MB: the 5 MB block fits, no events"
run $T ./heap_events -l 0 --no-pci -m 16 --huge-unlink --file-prefix=ch04-ev
echo "--- 5c. --no-huge: memory is not dynamic -> ENOTSUP"
run $T ./heap_events -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-ev
echo "--- 5d. --legacy-mem: all memory mapped at init -> ENOTSUP"
run $T ./heap_events -l 0 --no-pci --legacy-mem -m 16 --file-prefix=ch04-ev
echo "  hugepage files left by the legacy run (no --huge-unlink): $(ls /dev/hugepages | grep -c '^ch04-evmap_')"
rm -f /dev/hugepages/ch04-evmap_*

section "6. extmem_dma (deep dive): rte_extmem_register + rte_dev_dma_map"
rm -f x.sock
run $T ./extmem_dma -l 0 --no-pci --no-huge -m 128 --file-prefix=ch04-xdma \
	--log-level='lib.vhost.*:warning' --log-level='pmd.net.virtio.*:warning' \
	--vdev=net_vhost0,iface=$PWD/x.sock --vdev=net_null0 -- net_virtio_user0,path=$PWD/x.sock

section "7. startup_errors.sh: the startup-error catalogue -> errors.tsv"
./startup_errors.sh 2>&1 | strip_ansi

section "8. exercise solutions"
echo "--- Exercise 1: overhead of 100 x 1 KB"
run $T ./solutions/overhead -l 0 --no-pci --no-huge -m 64 --file-prefix=ch04-ex1
echo "--- Exercise 2: -m is a floor, --numa-limit is a cap"
run $T ./solutions/no_cap -l 0 --no-pci -m 32 --huge-unlink --file-prefix=ch04-ex2
run $T ./solutions/no_cap -l 0 --no-pci -m 32 --numa-limit 32 --huge-unlink --file-prefix=ch04-ex2

section "done"
cleanup
echo "hugepage files with prefix ch04-: $(ls /dev/hugepages | grep -c '^ch04-')"
echo "runtime dirs /run/dpdk/ch04-*:     $(ls -d /run/dpdk/ch04-* 2>/dev/null | wc -l)"
