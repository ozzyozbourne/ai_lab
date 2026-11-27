#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 15: build and run every example, both exercise solutions, the two
# shipped samples and the model comparison. To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge, a unique --file-prefix=ch15-*, timeout -s INT.
# Creates veth ch15va <-> ch15vb for the real-steering runs and deletes it on
# exit. Needs root (veth, AF_PACKET) and 4 lcores. Total run time ~2 minutes.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
E=$DPDK_SRC/build/examples

cleanup() {
	kill $(jobs -p) 2>/dev/null
	ip link del ch15va 2>/dev/null
	rm -rf /var/run/dpdk/ch15-* /run/dpdk/ch15-*
	rm -f /dev/hugepages/ch15-*map_* 2>/dev/null
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run <bin> <args...>: print the command, run it bounded, strip ANSI codes
# and the EAL start-up lines that are the same for every run
filter() {
	sed 's/\x1b\[[0-9;]*m//g' | grep -v '^EAL: \(Detected\|Selected\|Multi-process\)'
}
run() {
	local bin=$1; shift
	echo "\$ ${bin/#$E/\$E} $*"
	timeout -s INT -k 5 30 stdbuf -oL "$bin" "$@" 2>&1 | filter
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && echo "[exit status $rc]"
	return 0
}

EAL="--no-pci --no-huge"

echo "=== 1. rss_lab: Toeplitz, symmetric RSS, RETA, adjust_tuple, port capabilities ==="
run ./rss_lab -l 0 $EAL -m 128 --file-prefix=ch15-rss --vdev=net_null0

echo
echo "=== 2. rss_fanout.sh: real steering with af_packet fanout_mode=hash ==="
./rss_fanout.sh

echo
echo "=== 3. rtc_multiqueue: one queue per lcore on af_packet fanout ==="
ip link del ch15va 2>/dev/null
ip link add ch15va type veth peer name ch15vb && ip link set ch15va up && ip link set ch15vb up
# the sender starts once the port is up (the program polls for 4 s)
( sleep 2.5; python3 -I flows.py ch15vb 40 25 ) &
run ./rtc_multiqueue -l 0-2 $EAL -m 256 --file-prefix=ch15-rtc \
	--vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash -- --seconds 4
wait
ip link del ch15va 2>/dev/null
echo
echo "--- the same program as a load test on net_null (poll-driven, CPU-bound) ---"
run ./rtc_multiqueue -l 0-2 $EAL -m 256 --file-prefix=ch15-rtcn \
	--vdev=net_null0,size=64 -- --null --seconds 2 --work 200

echo
echo "=== 4. pipeline_rings: RX -> 2 workers -> TX with per-stage accounting ==="
P="-l 0-3 $EAL -m 256 --file-prefix=ch15-pipe --vdev=net_null0,size=64 --"
echo "--- 4a. balanced: work 200 cycles/packet in each worker ---"
run ./pipeline_rings $P --work 200
echo "--- 4b. worker0 is slow (+600 cycles), policy drop ---"
run ./pipeline_rings $P --work 200 --slow-worker 600
echo "--- 4c. worker0 is slow, policy wait (back-pressure reaches RX) ---"
run ./pipeline_rings $P --work 200 --slow-worker 600 --policy wait
echo "--- 4d. compressed pointers on every ring ---"
run ./pipeline_rings $P --work 200 --compress

echo
echo "=== 5. distributor_reorder: reorder script, then distributor + reorder ==="
run ./distributor_reorder -l 0-2 $EAL -m 128 --file-prefix=ch15-dist

echo
echo "=== 6. exercise solutions ==="
run ./reta_rebalance -l 0 $EAL -m 128 --file-prefix=ch15-ex1 --vdev=net_null0
run ./adjust4 -l 0 $EAL -m 64 --file-prefix=ch15-ex2

echo
echo "=== 7. shipped samples (prebuilt in \$DPDK_SRC/build/examples) ==="
echo "--- dpdk-distributor: 5 lcores (RX, distributor, TX, 1 worker + main), -m 640; last report ---"
echo "\$ dpdk-distributor --lcores='(0-4)@(0-3)' $EAL -m 640 --file-prefix=ch15-sdist --vdev=net_null0 --vdev=net_null1 -- -p 0x3"
timeout -s INT -k 5 6 stdbuf -oL "$E/dpdk-distributor" --lcores='(0-4)@(0-3)' $EAL -m 640 \
	--file-prefix=ch15-sdist --vdev=net_null0 --vdev=net_null1 -- -p 0x3 2>&1 | filter \
	| grep -v '^$' | sed -n '1,14p;/exiting/,$p' | tail -36
echo "--- dpdk-packet_ordering -m 384 (works) ---"
echo "\$ dpdk-packet_ordering -l 0-3 $EAL -m 384 --file-prefix=ch15-po --vdev=net_null0 --vdev=net_null1 -- -p 0x3"
timeout -s INT -k 5 5 stdbuf -oL "$E/dpdk-packet_ordering" -l 0-3 $EAL -m 384 \
	--file-prefix=ch15-po --vdev=net_null0 --vdev=net_null1 -- -p 0x3 2>&1 | filter \
	| grep -v '^$' | grep -v '^Port [01] MAC'
echo "--- dpdk-packet_ordering -m 256 (fails) ---"
run "$E/dpdk-packet_ordering" -l 0-3 $EAL -m 256 --file-prefix=ch15-po2 \
	--vdev=net_null0 --vdev=net_null1 -- -p 0x3

echo
echo "=== 8. compare.sh: the models side by side (median of 5) ==="
./compare.sh
