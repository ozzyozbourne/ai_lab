#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 12: build and run every example and both exercise solutions.
# To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge -m <=256, a unique --file-prefix=ch12-*,
# timeout -s INT. Ports are virtual: net_null, net_ring, net_tap (kernel
# interfaces ch12tap*, removed by the PMD on close), net_pcap (pcap files
# written by gen_pcap.py), net_vhost + virtio_user over a socket in a temp
# dir, net_bonding and net_failsafe. events.c creates and deletes a veth
# pair ch12a/ch12b itself; the trap deletes it too if the run is cut short.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

PREFIXES="ch12-ctl ch12-evt ch12-cb ch12-qc ch12-rr ch12-bond ch12-fs ch12-fail-pool
ch12-fail-tx ch12-fail-flap ch12-fail-rst ch12-lsc ch12-dr"
TMPD=$(mktemp -d /tmp/ch12.XXXXXX)
cleanup() {
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
	for i in ch12a ch12tap0 ch12tap2 ch12tap3 ch12tap4 ch12tap5 ch12tap6 \
		 ch12tap7 ch12tapb0 ch12tapb1; do
		ip link del "$i" 2>/dev/null
	done
	rm -rf "$TMPD"
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }
python3 -I gen_pcap.py tiny.pcap 40 4
python3 -I gen_pcap.py in.pcap 2000 8
python3 -I gen_pcap.py big.pcap 5000 8

# run <secs> <binary> <args...>: print the command, run it bounded, strip ANSI
# and the vhost/virtio chatter of events.c (kept in $TMPD/vhost.log)
run() {
	local secs=$1 bin=$2; shift 2
	echo
	echo "\$ $bin $*" | sed "s#$TMPD#\$TMPD#g"
	timeout -s INT -k 5 "$secs" stdbuf -oL "$bin" "$@" 2>&1 |
		sed 's/\x1b\[[0-9;]*m//g' | sed "s#$TMPD#\$TMPD#g"
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo "[exit status $rc]"
	[ "$rc" -eq 124 ] && echo "[stopped by SIGINT from timeout after ${secs}s]"
	return 0
}

EAL="--no-pci --no-huge -m 128"

echo "########## 1. port_ctl: control ops matrix + tap walk-through"
run 20 ./port_ctl -l 0 $EAL --file-prefix=ch12-ctl \
	--vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap0

echo; echo "########## 2. events: NEW / LSC / QUEUE_STATE / DESTROY, device monitor"
run 20 ./events -l 0 $EAL --file-prefix=ch12-evt --vdev=net_null0 \
	--log-level='lib.vhost.*:warning' --log-level='pmd.net.virtio.*:warning' \
	-- tiny.pcap "$TMPD/vhost.sock"

echo; echo "########## 3. rxtx_latency: RX/TX burst callbacks"
run 20 ./rxtx_latency -l 0 $EAL --file-prefix=ch12-cb \
	--vdev=net_ring0 --vdev=net_ring1

echo; echo "########## 4. queue_ctl: deferred start, queue start/stop, dev_capa"
run 20 ./queue_ctl -l 0 $EAL --file-prefix=ch12-qc \
	--vdev=net_tap0,iface=ch12tap2 \
	--vdev=net_pcap0,rx_pcap=in.pcap,rx_pcap=in.pcap,tx_pcap=/dev/null \
	--vdev=net_null0 --vdev=net_ring0 \
	--vdev='net_failsafe0,dev(net_tap1,iface=ch12tap4)'

echo; echo "########## 5. runtime_reconf: restart table, outage, ordered teardown"
# timeout's SIGINT after 4 s triggers the teardown
run 4 ./runtime_reconf -l 0-1 $EAL --file-prefix=ch12-rr \
	--vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap3
run 4 ./runtime_reconf -l 0-1 $EAL --file-prefix=ch12-rr \
	--vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch12tap3 -- --sloppy

echo; echo "########## 6. bonding_modes: modes, failover, aggregated-port probe"
run 20 ./bonding_modes -l 0 --no-pci --no-huge -m 256 --file-prefix=ch12-bond

echo; echo "########## 7. failsafe in testpmd (commands fed on stdin)"
echo "\$ (show port info 0; start; sleep 2; stop; show port stats 0; show port xstats 0; quit) | \\"
echo "  dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch12-fs \\"
echo "  --vdev='net_failsafe0,dev(net_null0,size=128),dev(net_ring0)' -- -i --total-num-mbufs=8192 --forward-mode=txonly"
(echo "show port info 0"; echo "start"; sleep 2; echo "stop"; echo "show port stats 0"
 echo "show port xstats 0"; sleep 1; echo "quit") |
	timeout -s INT -k 5 20 dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 \
	--file-prefix=ch12-fs --vdev='net_failsafe0,dev(net_null0,size=128),dev(net_ring0)' \
	-- -i --total-num-mbufs=8192 --forward-mode=txonly 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

echo; echo "########## 8. failure_lab: four seeded faults"
F="./failure_lab -l 0-1 $EAL"
run 20 $F --file-prefix=ch12-fail-pool \
	--vdev=net_pcap0,rx_pcap=big.pcap,tx_pcap=/dev/null \
	--vdev=net_pcap1,rx_pcap=in.pcap,infinite_rx=1,tx_pcap=/dev/null -- --mode pool_dry
run 20 $F --file-prefix=ch12-fail-tx -- --mode tx_full
run 20 $F --file-prefix=ch12-fail-flap --vdev=net_tap0,iface=ch12tap5 -- --mode link_flap
run 20 $F --file-prefix=ch12-fail-rst --vdev=net_null0 -- --mode reset

echo; echo "########## exercise solutions"
run 20 ./lsc_poll -l 0 --no-pci --no-huge -m 64 --file-prefix=ch12-lsc \
	--vdev=net_tap0,iface=ch12tap6
run 20 ./drain_restart -l 0 $EAL --file-prefix=ch12-dr --vdev=net_tap0,iface=ch12tap7

echo; echo "leftover ch12 interfaces: $(ip -o link show | grep -c 'ch12' || true)"
