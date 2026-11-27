#!/bin/bash
# ipsec-secgw outbound demo: cleartext UDP injected into tap ch07sg0 (port 0, PROTECTED side)
# comes out of tap ch07sg1 (port 1, UNPROTECTED side, -u 0x2) as ESP tunnel packets (AES-128-CBC/SHA1, crypto_openssl).
source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
B=$DPDK_SRC/build/examples
timeout -s INT -k 5 20 $B/dpdk-ipsec-secgw -l 1 --no-pci --no-huge -m 512 --file-prefix=ch07sg \
  --vdev=crypto_openssl0 --vdev=net_tap0,iface=ch07sg0 --vdev=net_tap1,iface=ch07sg1 -- \
  -p 0x3 -P -u 0x2 -t 3 --config="(0,0,1),(1,0,1)" -f secgw_min.cfg > secgw.log 2>&1 &
for i in $(seq 1 30); do grep -q "entering main loop" secgw.log 2>/dev/null && break; sleep 0.5; done
sleep 1
python3 tap_inject.py ch07sg0 ch07sg1 plain.pcap esp_tap.pcap 3
wait
grep -A4 "Statistics for core" secgw.log | tail -5
