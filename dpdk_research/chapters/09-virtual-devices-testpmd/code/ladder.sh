#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# ladder.sh - the software-PMD throughput ladder of chapter 9.
#
# For every backend, testpmd runs RUNS times (default 5) for SECS seconds with
# --stats-period 1, and the script reads the LAST one-second stats block:
#   metric = sum of Rx-pps over the ports of the measured testpmd
#            (Tx-pps for the "txonly" rows, where nothing is received).
# It prints median, min and max in Mpps and writes ladder.csv.
#
# These are SOFTWARE numbers on a shared 4-vCPU VM where other jobs run:
# they compare PMD overheads with each other and say nothing about NIC line
# rate. Forwarding uses 1 lcore per testpmd (-l A,B: B forwards).
#
# Backends (all created here, all removed by the trap):
#   ring        2 x net_ring, io --tx-first       pointer moves only
#   null        2 x net_null, io                  rx makes mbufs, tx frees
#   null rxonly 2 x net_null, rxonly              rx only, testpmd frees
#   null copy=1 2 x net_null,copy=1, rxonly       + one memcpy per packet
#   pcap        net_pcap infinite_rx=1, io loop   replays pre-loaded mbufs
#   memif       2 processes over a unix socket    shared memory, 1 copy each way
#   vhost       net_vhost <-> virtio_user         vhost-user, copies in vhost
#   tap         net_tap, txonly into the kernel   one writev() syscall per burst
#   af_packet   2 x af_packet on veth ch09a/b     PACKET_MMAP + kernel veth
#   af_xdp      2 x af_xdp on veth ch09c/d        XDP copy mode on veth
set -u
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./lib.sh
trap ch09_cleanup EXIT INT TERM

RUNS=${RUNS:-5}
SECS=${SECS:-5}
TPARGS="--total-num-mbufs=16384 --stats-period 1"
EAL="--no-pci --no-huge -m 256"
python3 -I mkpcap.py "$WORK/in.pcap" 100 > /dev/null

# last_pps <log> <nports> <Rx|Tx>: sum of the last <nports> "<Rx|Tx>-pps:" values
last_pps() {
	grep -E "$3-pps:" "$1" | tail -n "$2" | awk '{ s += $2 } END { printf "%d\n", s }'
}

# stats over a list of numbers (pps) -> "median min max" in Mpps
mstats() {
	printf '%s\n' "$@" | sort -n | awk '{ a[NR] = $1 } END {
		m = (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2;
		printf "%.2f %.2f %.2f\n", m / 1e6, a[1] / 1e6, a[NR] / 1e6 }'
}

declare -a NAMES MODES RESULTS
record() {   # record <name> <mode> <pps...>
	local name=$1 mode=$2; shift 2
	NAMES+=("$name"); MODES+=("$mode"); RESULTS+=("$(mstats "$@") $*")
	printf '  %-12s runs(pps): %s\n' "$name" "$*"
}

# one-process backend: bench <name> <mode> <nports> <Rx|Tx> <vdev/testpmd args...>
bench() {
	local name=$1 mode=$2 np=$3 dir=$4; shift 4
	local vals=() r
	for r in $(seq "$RUNS"); do
		tp "$SECS" "$WORK/l.log" -l 0,1 $EAL --file-prefix=ch09-lad "$@"
		vals+=("$(last_pps "$WORK/l.log" "$np" "$dir")")
	done
	record "$name" "$mode" "${vals[@]}"
}

# two-process backend: the "server" side loops packets back (io, loop
# topology) on lcores 2,3; the measured client sends the first burst.
bench2() {
	local name=$1 mode=$2 srv=$3 cli=$4
	local vals=() r spid
	for r in $(seq "$RUNS"); do
		timeout -s INT -k 5 $((SECS + 4)) "$TESTPMD" -l 2,3 $EAL --file-prefix=ch09-lads \
			$srv -- --forward-mode=io --port-topology=loop $TPARGS > "$WORK/s.log" 2>&1 &
		spid=$!
		sleep 1.5
		tp "$SECS" "$WORK/l.log" -l 0,1 $EAL --file-prefix=ch09-ladc $cli -- \
			--forward-mode=io --port-topology=loop --tx-first $TPARGS
		kill -INT $spid 2>/dev/null; wait $spid 2>/dev/null
		vals+=("$(last_pps "$WORK/l.log" 1 Rx)")
		rm -f /tmp/ch09-*.sock
	done
	record "$name" "$mode" "${vals[@]}"
}

echo "ladder: $RUNS runs x ${SECS}s per backend, metric = last 1 s stats block"
bench "ring" "io, 2 ports, tx_first" 2 Rx --vdev=net_ring0 --vdev=net_ring1 -- \
	--forward-mode=io --tx-first $TPARGS
bench "null" "io, 2 ports" 2 Rx --vdev=net_null0 --vdev=net_null1 -- \
	--forward-mode=io $TPARGS
bench "null rxonly" "rxonly, 2 ports" 2 Rx --vdev=net_null0 --vdev=net_null1 -- \
	--forward-mode=rxonly $TPARGS
# copy=1 is measured with rxonly: in 26.11 the copy-mode TX function never
# frees the mbufs it is given, so io forwarding drains the pool and stops
# (see testpmd_recipes.sh, recipe 9).
bench "null copy=1" "rxonly, 2 ports" 2 Rx --vdev=net_null0,copy=1 --vdev=net_null1,copy=1 -- \
	--forward-mode=rxonly $TPARGS
bench "pcap" "io loop, infinite_rx" 1 Rx --vdev=net_pcap0,rx_pcap="$WORK/in.pcap",infinite_rx=1 -- \
	--forward-mode=io --port-topology=loop $TPARGS
bench2 "memif" "io loop, 2 processes" \
	"--vdev=net_memif0,role=server,socket=/tmp/ch09-memif.sock,socket-abstract=no" \
	"--vdev=net_memif0,role=client,socket=/tmp/ch09-memif.sock,socket-abstract=no"
bench2 "vhost-user" "io loop, 2 processes" \
	"--vdev=net_vhost0,iface=/tmp/ch09-vhost.sock,queues=1" \
	"--vdev=net_virtio_user0,path=/tmp/ch09-vhost.sock"
bench "tap" "txonly into kernel" 1 Tx --vdev=net_tap0,iface=ch09tap0 -- \
	--forward-mode=txonly $TPARGS

ip link add ch09a type veth peer name ch09b && ip link set ch09a up && ip link set ch09b up
ip link add ch09c type veth peer name ch09d && ip link set ch09c up && ip link set ch09d up
bench "af_packet" "io, veth pair, tx_first" 2 Rx \
	--vdev=net_af_packet0,iface=ch09a,ignore_outgoing=1 \
	--vdev=net_af_packet1,iface=ch09b,ignore_outgoing=1 -- --forward-mode=io --tx-first $TPARGS
bench "af_xdp" "io, veth pair, tx_first" 2 Rx \
	--vdev=net_af_xdp0,iface=ch09c,start_queue=0,queue_count=1 \
	--vdev=net_af_xdp1,iface=ch09d,start_queue=0,queue_count=1 -- --forward-mode=io --tx-first $TPARGS
ip link del ch09a; ip link del ch09c

echo
echo "Software-PMD ladder (Mpps, median of $RUNS, shared VM - not NIC line rate)"
printf '%-12s %-26s %8s %8s %8s\n' backend mode median min max
echo "backend,mode,median_mpps,min_mpps,max_mpps,runs_pps" > ladder.csv
for i in "${!NAMES[@]}"; do
	read -r med mn mx rest <<< "${RESULTS[$i]}"
	printf '%-12s %-26s %8s %8s %8s\n' "${NAMES[$i]}" "${MODES[$i]}" "$med" "$mn" "$mx"
	echo "${NAMES[$i]},${MODES[$i]},$med,$mn,$mx,${rest// /;}" >> ladder.csv
done
