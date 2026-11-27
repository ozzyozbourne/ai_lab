#!/bin/bash
# testpmd io-forwarding between two net_tap ports, frames injected from the kernel side
source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
{ sleep 9; echo; } | timeout -s INT -k 5 14 dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 \
  --file-prefix=ch07tp --vdev=net_tap0,iface=ch07tp0 --vdev=net_tap1,iface=ch07tp1 -- \
  --total-num-mbufs=4096 --forward-mode=io > tp_tap.log 2>&1 &
sleep 4
ip -br link show ch07tp0
python3 tap_inject.py ch07tp0 ch07tp1 plain.pcap tp_out.pcap 3
wait
grep -E "RX-packets|TX-packets" tp_tap.log | head -4
