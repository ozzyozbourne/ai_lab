#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Exercise 1 solution: how many flows does flowgen generate?
# flowgen writes into a pcap file (tx_pcap) so the flows can be counted
# offline; the PMD's xstats give the packet count to compare with.
set -u
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./lib.sh
trap ch09_cleanup EXIT INT TERM
for flows in 1 16 100; do
	say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-ex1 --vdev=net_pcap0,tx_pcap=\$WORK/fg.pcap -- -i --total-num-mbufs=8192 --forward-mode=flowgen --flowgen-flows=$flows --burst=8 < solutions/ex1_flowgen.txt"
	( sleep 1.5; while IFS= read -r l; do case "$l" in "sleep "*) sleep "${l#sleep }";; *) echo "$l"; sleep 0.3;; esac; done < solutions/ex1_flowgen.txt; echo quit ) |
		tp 15 "$WORK/ex1.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-ex1 \
		--vdev=net_pcap0,tx_pcap="$WORK/fg.pcap" -- -i --total-num-mbufs=8192 \
		--forward-mode=flowgen --flowgen-flows=$flows --burst=8
	grep -E "tx_good_packets" "$WORK/ex1.log"
	python3 -I count_flows.py "$WORK/fg.pcap"
	rm -f "$WORK/fg.pcap"
done
