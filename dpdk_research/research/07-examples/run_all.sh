#!/bin/bash
# Reproduce every chapter-07 (packet-processing libraries) experiment on this VM.
# Uses only virtual devices (net_pcap, net_tap with ch07* names, crypto_openssl);
# never touches eth0. Each run has a unique --file-prefix and a timeout.
set -u
source /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
cd "$(dirname "$0")"
B=$DPDK_SRC/build/examples
BIN=${BIN:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/ch07-bin}
mkdir -p "$BIN"
CFLAGS="$(pkg-config --cflags libdpdk)"; LIBS="$(pkg-config --libs --static libdpdk)"
EAL="--no-pci --log-level=lib.eal:error"

python3 gen_pcap.py in.pcap 1000                    # 1000 UDP pkts to 198.18.{0..3}.x
python3 gen_pcap.py plain.pcap 100 192.168.105 64   # cleartext for ipsec-secgw
python3 -c "import struct;open('empty.pcap','wb').write(struct.pack('<IHHiIII',0xa1b2c3d4,2,4,0,0,65535,1))"

echo "== standalone library programs"
for p in hash_fill lpm_fib meter_demo frag_reasm gso_gro graph_mini sched_mini; do
  gcc -O2 $p.c -o "$BIN/$p" $CFLAGS $LIBS 2>/dev/null || { echo "build $p failed"; continue; }
  timeout -k 5 25 "$BIN/$p" --no-huge -m 256 $EAL --file-prefix=ch07_$p > $p.out 2>&1
  echo "--- $p"; cat $p.out
done

echo "== l3fwd with 4 lookup methods over two net_pcap ports"
for lk in lpm fib acl em; do
  mem=256; extra=""
  [ $lk = em ] && mem=1024                         # EM hash is 4M entries
  [ $lk = acl ] && extra="--rule_ipv4=acl_rules_v4.txt --rule_ipv6=acl_rules_v6.txt"
  timeout -s INT -k 5 8 $B/dpdk-l3fwd -l 1 --no-huge -m $mem $EAL --file-prefix=ch07l3 \
    --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out0_$lk.pcap \
    --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=out1_$lk.pcap \
    -- -p 0x3 --config="(0,0,1),(1,0,1)" --lookup=$lk $extra \
       --parse-ptype --disable-rss --relax-rx-offload > l3fwd_$lk.log 2>&1
  echo "--- l3fwd $lk"; python3 pcap_summary.py out0_$lk.pcap out1_$lk.pcap
done

echo "== l3fwd-graph (needs 1 txq per lcore -> two tx_pcap per port; LPM6 needs >256MB)"
timeout -s INT -k 5 8 $B/dpdk-l3fwd-graph -l 0,1 --no-huge -m 640 $EAL --file-prefix=ch07g \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out0_graph.pcap,tx_pcap=out0b_graph.pcap \
  --vdev=net_pcap1,rx_pcap=in.pcap,tx_pcap=out1_graph.pcap,tx_pcap=out1b_graph.pcap \
  -- -p 0x3 --config="(0,0,1),(1,0,1)" > l3fwd_graph.log 2>&1
python3 pcap_summary.py out0_graph.pcap out1_graph.pcap

echo "== l2fwd (MAC rewrite, port 0 -> port 1)"
timeout -s INT -k 5 5 $B/dpdk-l2fwd -l 0,1 --no-huge -m 128 $EAL --file-prefix=ch07l2 \
  --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=l2out0.pcap \
  --vdev=net_pcap1,rx_pcap=empty.pcap,tx_pcap=l2out1.pcap -- -p 0x3 -q 2 -T 1 > l2fwd.log 2>&1
python3 pcap_summary.py l2out1.pcap

echo "== eBPF RX filter in testpmd (drops UDP dport 2001)"
clang -O2 -target bpf -c drop_dport2001.c -o drop_dport2001.o
for mode in nobpf bpf; do
  C=""; [ $mode = bpf ] && C="--cmdline-file=bpf_cmds.txt"
  { sleep 3; echo; } | timeout -s INT -k 5 10 dpdk-testpmd -l 0,1 --no-huge -m 256 $EAL \
    --file-prefix=ch07bpf --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=out_$mode.pcap \
    -- --no-flush-rx --total-num-mbufs=4096 $C --forward-mode=io > testpmd_$mode.log 2>&1
  python3 pcap_summary.py out_$mode.pcap | grep pkts$
done

echo "== SWX pipeline (P4-like spec -> C -> .so), pcap source/sink ports"
RTE_INSTALL_DIR=$DPDK_SRC timeout -s INT -k 5 10 $B/dpdk-pipeline -l 0,1 --no-huge -m 256 $EAL \
  --file-prefix=ch07swx -- -s swx/l2fwd_pcap.cli > swx.log 2>&1
python3 pcap_summary.py swx_out0.pcap swx_out1.pcap

echo "== ipsec-secgw outbound ESP over net_tap (needs root; creates/destroys ch07sg0/1)"
./run_secgw.sh

# remove this script's EAL runtime dirs (unique ch07 prefixes only)
for d in /var/run/dpdk/ch07*; do [ -d "$d" ] && rm -r -- "$d"; done
