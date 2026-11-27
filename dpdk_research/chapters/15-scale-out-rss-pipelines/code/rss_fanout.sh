#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# rss_fanout.sh - real multi-queue steering on this VM.
#
# net_af_packet with qpairs=2,fanout_mode=hash opens two AF_PACKET sockets in
# one PACKET_FANOUT group. The KERNEL then picks the socket (= DPDK RX queue)
# from its own flow hash (skb_get_hash), so packets of one flow always land on
# the same queue. It is not Toeplitz and there is no RETA, but it is the same
# idea as NIC RSS, on real packets.
#
# Creates veth ch15va <-> ch15vb, runs testpmd in rxonly mode on ch15va with 2
# RX queues, sends UDP flows into ch15vb from Python, and prints the per-queue
# split twice: 40 flows x 10 packets, then 1 flow x 400 packets.
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

PFX=ch15-fan
cleanup() {
	ip link del ch15va 2>/dev/null
	rm -rf "/var/run/dpdk/$PFX" "/run/dpdk/$PFX"
}
trap cleanup EXIT INT TERM

ip link del ch15va 2>/dev/null
ip link add ch15va type veth peer name ch15vb || exit 1
for i in ch15va ch15vb; do
	ip link set "$i" up
	# keep the kernel quiet on the test link (no IPv6 RS/ND noise)
	[ -d /proc/sys/net/ipv6 ] && sysctl -qw "net.ipv6.conf.$i.disable_ipv6=1"
done

# one_run <nflows> <pkts_per_flow>
one_run() {
	local nf=$1 per=$2
	echo "\$ dpdk-testpmd -l 0-2 --no-pci --no-huge -m 256 --file-prefix=$PFX \\"
	echo "    --vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash -- -i \\"
	echo "    --rxq=2 --txq=2 --nb-cores=2 --forward-mode=rxonly --total-num-mbufs=8192"
	echo "  (sending $nf flows x $per packets into ch15vb while forwarding is started)"
	{
		sleep 3; echo "start"; sleep 1
		python3 -I flows.py ch15vb "$nf" "$per" >&2
		sleep 1
		echo "show port xstats 0"
		echo "stop"; sleep 0.5; echo "quit"
	} | timeout -s INT -k 5 20 stdbuf -oL dpdk-testpmd -l 0-2 --no-pci --no-huge -m 256 \
		--file-prefix=$PFX \
		--vdev=net_af_packet0,iface=ch15va,qpairs=2,fanout_mode=hash -- -i \
		--rxq=2 --txq=2 --nb-cores=2 --forward-mode=rxonly --total-num-mbufs=8192 2>&1 \
		| sed 's/\x1b\[[0-9;]*m//g' \
		| grep -E 'rx_q[01]_packets|RX Port= 0/Queue=|RX-packets:|^flows.py' \
		| grep -v ': 0$' | sed 's/^ */  /'
}

echo "=== 40 flows x 10 packets: the kernel flow hash spreads flows ==="
one_run 40 10 2>&1
echo
echo "=== 1 flow x 400 packets: one flow always lands on one queue ==="
one_run 1 400 2>&1
