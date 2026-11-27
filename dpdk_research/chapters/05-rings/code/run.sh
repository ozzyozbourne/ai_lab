#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# run.sh - build and run every Chapter 5 example. Self-cleaning, every run is
# bounded by timeout, every run has a unique --file-prefix=ch05-*, --no-pci
# and --no-huge (rings need no hugepages and no NIC).
#
#   ./run.sh 2>&1 | tee expected_output.txt
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
source "$ENV_SH"
T="timeout -s INT -k 5 20"
EAL="--no-pci --no-huge -m 64"

cleanup() {
	pkill -INT -f 'file-prefix=ch05-' 2>/dev/null
	sleep 0.3
	rm -rf /run/dpdk/ch05-*
	rm -f /dev/hugepages/ch05-*map_*
	true
}
trap cleanup EXIT
strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
# run: echo the command, run it, show its exit code. The constant
# "EAL: Detected ..." and mp_socket lines are dropped to keep the log short.
run() {
	echo "\$ $*" | sed "s|^\$ timeout -s INT -k 5 20 |\$ |"
	stdbuf -oL -eL "$@" 2>&1 | strip_ansi |
		grep -v -E '^EAL: (Detected (CPU lcores|NUMA nodes|static linkage)|Multi-process socket|Selected IOVA mode)'
	echo "[exit code ${PIPESTATUS[0]}]"
}
section() { echo; echo "=================== $* ==================="; }

section "0. build (make, -Wall -Wextra)"
make -s clean
make -s all 2>&1 | strip_ansi
echo "[make exit code ${PIPESTATUS[0]}]"
echo "load average before the runs: $(cut -d' ' -f1-3 /proc/loadavg) (shared 4-core VM)"

section "1. ring_basics: API families, bulk vs burst, producer -> consumer"
run $T ./ring_basics -l 0-1 $EAL --file-prefix=ch05-basic

section "1b. exercise 1: the same program with an SP/SC pipe ring"
run $T ./ring_basics_spsc -l 0-1 $EAL --file-prefix=ch05-basic

section "2. ring_wrap: free-running indexes, the 2^32 wrap, RING_F_EXACT_SZ"
run $T ./ring_wrap -l 0 $EAL --file-prefix=ch05-wrap

section "3. ring_modes_bench: SP/SC vs MP/MC vs RTS vs HTS"
echo "--- 3a. 1 producer (lcore 0) -> 1 consumer (lcore 1), two real CPUs"
run $T ./ring_modes_bench -l 0-1 $EAL --file-prefix=ch05-bench
echo "--- 3b. 2 producers (lcores 0,1) -> 1 consumer (lcore 2), three real CPUs"
run $T ./ring_modes_bench -l 0-2 $EAL --file-prefix=ch05-bench
echo "--- 3c. symmetric (every lcore dequeues and re-enqueues), 3 lcores on 3 CPUs"
run $T ./ring_modes_bench -l 0-2 $EAL --file-prefix=ch05-bench -- -s
echo "--- 3d. symmetric, OVERCOMMITTED: 4 lcores time-share CPU 1"
run $T ./ring_modes_bench "--lcores=(0-3)@1" $EAL --file-prefix=ch05-bench -- -s
echo "--- 3e. producer/consumer, OVERCOMMITTED: 3 producers + 1 consumer on CPU 1"
run $T ./ring_modes_bench "--lcores=(0-3)@1" $EAL --file-prefix=ch05-bench

section "4. elem_peek: element ring, peek, zero-copy, two peeking consumers"
run $T ./elem_peek -l 0-1 $EAL --file-prefix=ch05-peek

section "5. soring_demo: staged-ordered ring keeps order across stages"
run $T ./soring_demo -l 0 $EAL --file-prefix=ch05-soring

section "6. exercise 2: three-stage pipeline (solutions/pipeline3.c)"
run $T ./pipeline3 -l 0-2 $EAL --file-prefix=ch05-pipe

section "done"
