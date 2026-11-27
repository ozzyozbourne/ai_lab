#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Exercise 2 solution: replay a pcap through csum forwarding and read the
# checksum flags. in.pcap holds 2 UDP frames with checksum 0 and 2 TCP
# frames with a wrong checksum (0xdead); IPv4 header checksums are right.
set -u
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./lib.sh
trap ch09_cleanup EXIT INT TERM
python3 -I mkpcap.py "$WORK/u.pcap" 2 udp > /dev/null
python3 -I mkpcap.py "$WORK/t.pcap" 2 tcp > /dev/null
# concatenate: header of the first file + records of both
{ cat "$WORK/u.pcap"; tail -c +25 "$WORK/t.pcap"; } > "$WORK/in.pcap"
echo "input:";  python3 -I count_flows.py "$WORK/in.pcap"
say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-ex2 --vdev=net_pcap0,rx_pcap=\$WORK/in.pcap,tx_pcap=\$WORK/out.pcap -- -i --total-num-mbufs=8192 --forward-mode=csum --port-topology=loop --no-flush-rx < solutions/ex2_csum.txt"
( sleep 1.5; while IFS= read -r l; do case "$l" in "sleep "*) sleep "${l#sleep }";; *) echo "$l"; sleep 0.3;; esac; done < solutions/ex2_csum.txt; echo quit ) |
	tp 15 "$WORK/ex2.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-ex2 \
	--vdev=net_pcap0,rx_pcap="$WORK/in.pcap",tx_pcap="$WORK/out.pcap" -- -i \
	--total-num-mbufs=8192 --forward-mode=csum --port-topology=loop --no-flush-rx
grep -E "^testpmd> .|^port=|^rx:|^tx:|ol_flags|flags=|Bad-|-csum|RX-packets:.*RX-dropped" "$WORK/ex2.log" | head -40
echo "output:"; python3 -I count_flows.py "$WORK/out.pcap"
