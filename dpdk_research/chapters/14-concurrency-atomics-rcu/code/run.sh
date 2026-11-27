#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 14: build and run every example and both exercise solutions.
# To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge -m 64, a unique --file-prefix=ch14-*, and
# timeout -s INT. No devices, no veths, no hugepages: this chapter is about
# cores and memory only. Needs 4 lcores (-l 0-3) for the multi-core runs.
# Numbers come from a shared 4-vCPU VM: they are noisy, so the benchmarks
# print median, min and max of 5 runs.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

PREFIXES="ch14-litmus ch14-locks ch14-seq ch14-rcu ch14-cnt ch14-cas ch14-port ch14-rcudq"
cleanup() {
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run <name> <args...>: print the command, run it bounded, strip ANSI codes
# and the EAL start-up lines (they are the same for every run)
run() {
	local bin=$1; shift
	echo
	echo "\$ ./$bin $*"
	timeout -s INT -k 5 30 stdbuf -oL "./$bin" "$@" 2>&1 \
		| sed 's/\x1b\[[0-9;]*m//g' | grep -v '^EAL: \(Detected\|Selected\|Multi-process\)'
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && echo "[exit status $rc]"
	return 0
}

EAL="--no-pci --no-huge -m 64"

echo "=== 1. Compiler reordering: litmus_mp.c at -O2 (x86-64, gcc) ==="
echo "\$ make objdump"
make -s objdump
if command -v clang >/dev/null && command -v llvm-objdump >/dev/null; then
	echo
	echo "=== 1b. The same source for AArch64 (clang cross-compile, NOT run) ==="
	echo "\$ make objdump-arm"
	make -s objdump-arm
fi

echo
echo "=== 2. Litmus tests on two lcores (1M iterations each) ==="
run litmus      -l 0-2 $EAL --file-prefix=ch14-litmus

echo
echo "=== 3. Lock costs and fairness ==="
run locks_bench -l 0-3 $EAL --file-prefix=ch14-locks

echo
echo "=== 4. Seqlock-protected config ==="
run seqlock_cfg -l 0-2 $EAL --file-prefix=ch14-seq

echo
echo "=== 5. RCU QSBR pointer swap, four modes ==="
for m in sync broken slow offline; do
	run rcu_swap -l 0-3 $EAL --file-prefix=ch14-rcu -- $m
done

echo
echo "=== 6. Four counter layouts ==="
run counters    -l 0-3 $EAL --file-prefix=ch14-cnt

echo
echo "=== 7. ABA and the 128-bit CAS ==="
run cas128      -l 0   $EAL --file-prefix=ch14-cas

echo
echo "=== 8. Static lock checking (clang -Wthread-safety, compile only) ==="
echo "\$ make thread_safety"
make -s thread_safety 2>&1

echo
echo "=== Exercise solutions ==="
run port_26_11  -l 0-1 $EAL --file-prefix=ch14-port
run rcu_dq      -l 0-3 $EAL --file-prefix=ch14-rcudq
