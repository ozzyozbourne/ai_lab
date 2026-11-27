#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 9: build and run every example. To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
#   1. kvargs_demo, vdev_runtime, devargs_iter (+ the iterator crash)
#   2. testpmd on two net_null ports, io forwarding, --stats-period 2
#   3. the --total-num-mbufs rule: testpmd without it on --no-huge -m 256
#   4. pcap replay: macswap + loop topology into out.pcap, with and without
#      --no-flush-rx
#   5. tap: kernel -> DPDK (Python raw socket, rxonly) and DPDK -> kernel
#      (txonly, read with ip -s link)
#   6. veth ch09a/ch09b: net_af_packet on one end, net_af_xdp on the other,
#      io --tx-first ping-pong (libxdp warnings are expected, see the chapter)
#   6b. dpdk-devbind.py --status-dev net (read-only; nothing is bound)
#   7. testpmd_recipes.sh (recipes R1-R9 and the debugger block D1-D2)
#   8. the two exercise solutions
#   9. ladder.sh (about 5 minutes; LADDER=0 skips it)
#
# All runs: --no-pci, --no-huge -m <= 256, a unique --file-prefix=ch09-*,
# timeout -s INT. Interfaces ch09tap0 and veths ch09a..d are removed by the
# trap, as are /run/dpdk/ch09-* and any /dev/hugepages/ch09-*map_* files.
set -u
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./lib.sh
trap ch09_cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run <secs> <binary> <args...>: print the command, run it bounded, strip ANSI
run() {
	local secs=$1 bin=$2; shift 2
	say "$bin $*"
	timeout -s INT -k 5 "$secs" stdbuf -oL "$bin" "$@" 2>&1 | strip
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo "[exit status $rc]"
	return 0
}

echo "################ 1. C programs ################"
run 10 ./kvargs_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch09-kv \
	--vdev=net_null0,size=128 -- 'rate=100,burst=32,mode=fast'
# vdev names match drivers by prefix; a bad driver key fails the probe but
# not rte_eal_init(): the program runs on with no port. (Only Part B shown.)
KV="./kvargs_demo -l 0 --no-pci --no-huge -m 64 --file-prefix=ch09-kv"
say "$KV --vdev=net_null_lab,size=96"
timeout 10 $KV --vdev=net_null_lab,size=96 2>&1 | strip | sed -n '/^Part B/,/^Part C/p' | head -4
say "$KV --vdev=net_null0,colour=red"
timeout 10 $KV --vdev=net_null0,colour=red 2>&1 | strip | grep -E "EAL: (Failed|Bus)|^Part B|^  port"
run 10 ./vdev_runtime -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-rt
run 10 ./devargs_iter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-iter \
	--vdev=net_null0 --vdev=net_null1 --vdev=net_ring0 --vdev=crypto_null0
# the same, plus a filter the ethdev iterator cannot handle (SIGSEGV, 139)
DI="./devargs_iter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch09-iter --vdev=net_null0 --vdev=net_null1 --vdev=net_ring0"
say "$DI -- --crash"
timeout 10 stdbuf -oL $DI -- --crash 2>&1 | strip | tail -2
echo "[exit status ${PIPESTATUS[0]}]"

echo; echo "################ 2. testpmd: io forwarding between two net_null ports ################"
say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tp --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=16384 --stats-period 2 --forward-mode=io"
tp 8 "$WORK/tp.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tp \
	--vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=16384 --stats-period 2 --forward-mode=io
# the start-up part, then the last stats block of each port, then the summary
sed -n '1,/^  io packet forwarding packets/p' "$WORK/tp.log"
echo "  [... per-queue config and earlier stats blocks trimmed ...]"
grep -E "NIC statistics for port|RX-packets:.*RX-missed|Rx-pps|Tx-pps" "$WORK/tp.log" | tail -8
sed -n '/^Telling cores to stop/,$p' "$WORK/tp.log" | grep -E "Forward statistics|Accumulated|RX-packets:|TX-packets:|Bye"

echo; echo "################ 3. the --total-num-mbufs rule ################"
say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-nombuf --vdev=net_null0 -- --stats-period 1"
tp 10 "$WORK/nm.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-nombuf \
	--vdev=net_null0 -- --stats-period 1
echo "[exit status $?]"
grep -E "mbuf pool|Cannot|EAL: Error|failed" "$WORK/nm.log"

echo; echo "################ 4. pcap replay with macswap ################"
python3 -I mkpcap.py "$WORK/in.pcap" 100 | sed "s#$WORK#\$WORK#"
python3 -I read_pcap.py "$WORK/in.pcap" 2 | sed "s#$WORK#\$WORK#"
for flush in "--no-flush-rx" ""; do
	rm -f "$WORK/out.pcap"
	say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-pcap --vdev=net_pcap0,rx_pcap=$WORK/in.pcap,tx_pcap=$WORK/out.pcap -- --forward-mode=macswap --port-topology=loop $flush --total-num-mbufs=8192 --stats-period 1"
	tp 5 "$WORK/pcap.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-pcap \
		--vdev=net_pcap0,rx_pcap="$WORK/in.pcap",tx_pcap="$WORK/out.pcap" -- \
		--forward-mode=macswap --port-topology=loop $flush --total-num-mbufs=8192 --stats-period 1
	sed -n '/Forward statistics for port 0/,/^  ---/p' "$WORK/pcap.log" | grep -E "RX-packets|TX-packets"
	python3 -I read_pcap.py "$WORK/out.pcap" 2 | sed "s#$WORK#\$WORK#"
done

echo; echo "################ 5. tap: kernel <-> DPDK ################"
say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tap --vdev=net_tap0,iface=ch09tap0 -- --forward-mode=rxonly --total-num-mbufs=8192 --stats-period 2 &"
tp 8 "$WORK/tap.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tap \
	--vdev=net_tap0,iface=ch09tap0 -- --forward-mode=rxonly --total-num-mbufs=8192 --stats-period 2 &
sleep 2.5
say "ip -br link show ch09tap0"; ip -br link show ch09tap0
say "python3 -I sendraw.py ch09tap0 1000"; python3 -I sendraw.py ch09tap0 1000
wait
sed -n '/Forward statistics for port 0/,/^  ---/p' "$WORK/tap.log" | grep -E "RX-packets"

say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tap --vdev=net_tap0,iface=ch09tap0 -- --forward-mode=txonly --total-num-mbufs=8192 --stats-period 2 &"
tp 6 "$WORK/tap2.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-tap \
	--vdev=net_tap0,iface=ch09tap0 -- --forward-mode=txonly --total-num-mbufs=8192 --stats-period 2 &
sleep 4.5
say "ip -s link show ch09tap0"; ip -s link show ch09tap0
wait
grep -E "Tx-pps" "$WORK/tap2.log" | tail -1
sed -n '/Forward statistics for port 0/,/^  ---/p' "$WORK/tap2.log" | grep -E "TX-packets"
say "ip link show ch09tap0   # after testpmd exits"; ip link show ch09tap0 2>&1

echo; echo "################ 6. veth ping-pong: af_packet <-> af_xdp ################"
say "ip link add ch09a type veth peer name ch09b; ip link set ch09a up; ip link set ch09b up"
ip link add ch09a type veth peer name ch09b && ip link set ch09a up && ip link set ch09b up
say "dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-veth --vdev=net_af_packet0,iface=ch09a,ignore_outgoing=1 --vdev=net_af_xdp0,iface=ch09b,start_queue=0,queue_count=1 -- --forward-mode=io --tx-first --total-num-mbufs=8192 --stats-period 2"
tp 8 "$WORK/veth.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-veth \
	--vdev=net_af_packet0,iface=ch09a,ignore_outgoing=1 \
	--vdev=net_af_xdp0,iface=ch09b,start_queue=0,queue_count=1 -- \
	--forward-mode=io --tx-first --total-num-mbufs=8192 --stats-period 2
grep -E "Warning|libxdp|libbpf|Port [01]:|Link up|RX P=" "$WORK/veth.log"
grep -E "Rx-pps" "$WORK/veth.log" | tail -2
sed -n '/^Telling cores/,$p' "$WORK/veth.log" | grep -E "Forward statistics|RX-packets:" | head -4
# Optional comparison: with a bpffs mounted, libxdp can use its dispatcher.
if ! mountpoint -q /sys/fs/bpf; then
	mount -t bpf bpf /sys/fs/bpf 2>/dev/null && MOUNTED_BPF=1
fi
if [ -n "${MOUNTED_BPF:-}" ]; then
	say "mount -t bpf bpf /sys/fs/bpf   # then the same af_xdp port again"
	tp 5 "$WORK/veth2.log" -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch09-veth \
		--vdev=net_af_xdp0,iface=ch09b,start_queue=0,queue_count=1 -- \
		--forward-mode=rxonly --total-num-mbufs=8192 --stats-period 2
	grep -E "libxdp|libbpf|Port 0:" "$WORK/veth2.log"
	umount /sys/fs/bpf
	echo "(bpffs unmounted again)"
fi
ip link del ch09a

echo; echo "################ 6b. on real hardware: dpdk-devbind.py (read-only status) ################"
say "dpdk-devbind.py --status-dev net"
timeout 10 dpdk-devbind.py --status-dev net 2>&1 | head -20
echo "[exit status ${PIPESTATUS[0]}]"

echo; echo "################ 7. testpmd recipes and the debugger block ################"
./testpmd_recipes.sh

echo; echo "################ 8. exercise solutions ################"
./solutions/ex1_flowgen.sh
./solutions/ex2_csum.sh

if [ "${LADDER:-1}" != 0 ]; then
	echo; echo "################ 9. the software-PMD ladder ################"
	./ladder.sh
fi
