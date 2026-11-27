#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# testpmd_recipes.sh - chapter 9: field-tested testpmd recipes and the
# "testpmd as a debugger" block, each run bounded and captured.
#
# Interactive recipes feed a command file from recipes/ into "testpmd -i".
# A line "sleep N" in a command file is NOT a testpmd command: the feeder
# below sleeps N seconds instead, so traffic has time to flow. Recipe 8 uses
# the real --cmdline-file option (no sleeps needed).
#
#  R1 multi-queue / multi-core mapping  (--rxq/--txq/--nb-cores, show config fwd)
#  R2 jumbo frames                       (--max-pkt-len=9000, multi-segment txonly)
#  R3 buffer split attempt               (captured "not supported" on a vdev)
#  R4 xstats delta workflow              (clear port xstats, then show)
#  R5 txonly shaping                     (--txonly-multi-flow, --eth-peer, --txpkts) into a pcap
#  R6 noisy forwarding mode              (VNF-like buffering and memory noise)
#  R7 runtime port reconfiguration       (port stop / port config / port start)
#  R8 minimal reproducer                 (--cmdline-file template for bug reports)
#  R9 a surprise found while measuring   (net_null copy=1 + io drains the pool)
#  D1 debugger on vhost + virtio_user    (rxq/txq info, burst mode, desc status,
#                                         desc used count, burst stats); run
#                                         twice: default, then --no-flush-rx
#  D2 debugger on net_null + hotplug     (port cap, attach pcap, verbose dump,
#                                         xstats delta, fwd stats, rxd change)
# Every invocation passes --total-num-mbufs=8192 and a unique --file-prefix.
set -u
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./lib.sh
trap ch09_cleanup EXIT INT TERM
EAL="--no-pci --no-huge -m 256"
MB="--total-num-mbufs=8192"

# feed <cmdfile>: send the commands (one every 0.3 s) to testpmd's stdin,
# honour "sleep N", skip comments, end with quit. testpmd's command line
# echoes each command after its "testpmd> " prompt, so the log reads like an
# interactive session.
feed() {
	sed "s#@WORK@#$WORK#g" "$1" | while IFS= read -r l; do
		case "$l" in
		"sleep "*) sleep "${l#sleep }" ;;
		"#"* | "") ;;
		*) echo "$l"; sleep 0.3 ;;
		esac
	done
	sleep 0.5
	echo quit
}

# ri <N> <secs> <cmdfile> <eal+testpmd args...>: one interactive recipe,
# output in $WORK/r<N>.log
ri() {
	local n=$1 secs=$2 cf=$3; shift 3
	local raw="$WORK/r$n.log.raw"
	say "dpdk-testpmd $* < $cf"
	: > "$raw"
	( sleep 1.5; feed "$cf" ) | timeout -s INT -k 5 "$secs" stdbuf -oL "$TESTPMD" "$@" >> "$raw" 2>&1
	strip < "$raw" > "$WORK/r$n.log"
	rm -f "$raw"
}

python3 -I mkpcap.py "$WORK/three.pcap" 3 > /dev/null

echo "=== R1: two RX/TX queues per port, two forwarding cores (net_null) ==="
ri 1 12 recipes/r1_multiqueue.txt -l 0-2 $EAL --file-prefix=ch09-r1 \
	--vdev=net_null0 --vdev=net_null1 -- -i $MB --rxq=2 --txq=2 --nb-cores=2
show "$WORK/r1.log" "^testpmd> .|Logical Core|RX P=|Forward statistics for port|RX-packets:.*RX-dropped|Accumulated" | awk '!(/^testpmd> start/ && s++)' | head -24

echo; echo "=== R2: jumbo frames, 9000-byte multi-segment txonly (net_null) ==="
ri 2 12 recipes/r2_jumbo.txt -l 0-1 $EAL --file-prefix=ch09-r2 --vdev=net_null0 -- \
	-i $MB --max-pkt-len=9000
show "$WORK/r2.log" "^testpmd> .|^MTU|Maximum configurable length|Number of segments|segment length|nb packet segments|TX-packets:.*TX-bytes|^Error|^Bad"

echo; echo "=== R3: buffer split on a vdev ==="
ri 3 12 recipes/r3_bufsplit.txt -l 0-1 $EAL --file-prefix=ch09-r3 --vdev=net_null0 -- -i $MB
show "$WORK/r3.log" "^testpmd> .|Rx Offloading Capabilities|^  [A-Z_ ]+$|[Ee]rror|[Ff]ail|not support|Invalid|^Port 0"

echo; echo "=== R4: xstats delta (clear, wait 1 s, show non-zero) ==="
ri 4 12 recipes/r4_xstats.txt -l 0-1 $EAL --file-prefix=ch09-r4 \
	--vdev=net_null0 --vdev=net_null1 -- -i $MB
show "$WORK/r4.log" "^testpmd> .|xstats for port|_packets|_bytes"

echo; echo "=== R5: txonly multi-flow with a fixed peer MAC, into a pcap file ==="
ri 5 12 recipes/r5_multiflow.txt -l 0-1 $EAL --file-prefix=ch09-r5 \
	--vdev=net_pcap0,tx_pcap="$WORK/mf.pcap" -- -i $MB --forward-mode=txonly \
	--txonly-multi-flow --eth-peer=0,02:00:00:00:09:02 --txpkts=64 --burst=4
show "$WORK/r5.log" "TX-packets:.*TX-dropped|txonly packet"
python3 -I read_pcap.py "$WORK/mf.pcap" 6 | sed "s#$WORK#\$WORK#"

echo; echo "=== R6: noisy forwarding mode vs io (net_null, 4 s each, last 1 s block) ==="
say "dpdk-testpmd -l 0-1 $EAL --file-prefix=ch09-r6 --vdev=net_null0 --vdev=net_null1 -- $MB --stats-period 1 --forward-mode=io"
tp 5 "$WORK/r6a.log" -l 0-1 $EAL --file-prefix=ch09-r6 --vdev=net_null0 --vdev=net_null1 -- \
	$MB --stats-period 1 --forward-mode=io
grep "Rx-pps" "$WORK/r6a.log" | tail -2
say "dpdk-testpmd ... -- $MB --stats-period 1 --forward-mode=noisy --noisy-tx-sw-buffer-size=512 --noisy-tx-sw-buffer-flushtime=10 --noisy-lkup-memory=16 --noisy-lkup-num-reads-writes=8"
tp 5 "$WORK/r6b.log" -l 0-1 $EAL --file-prefix=ch09-r6 --vdev=net_null0 --vdev=net_null1 -- \
	$MB --stats-period 1 --forward-mode=noisy --noisy-tx-sw-buffer-size=512 \
	--noisy-tx-sw-buffer-flushtime=10 --noisy-lkup-memory=16 --noisy-lkup-num-reads-writes=8
grep -E "noisy|Rx-pps" "$WORK/r6b.log" | grep -v "^Set" | tail -3

echo; echo "=== R7: reconfigure queues and descriptors at run time ==="
ri 7 12 recipes/r7_runtime.txt -l 0-1 $EAL --file-prefix=ch09-r7 \
	--vdev=net_null0 --vdev=net_null1 -- -i $MB
show "$WORK/r7.log" "^testpmd> .|RX queue number|RX desc=|Configuring Port 0|Invalid|[Ee]rror"

echo; echo "=== R8: the minimal-reproducer template, run with --cmdline-file ==="
say "dpdk-testpmd -l 0-1 $EAL --file-prefix=ch09-r8 --vdev=net_null0 --vdev=net_null1 -- -i $MB --cmdline-file=recipes/r8_reproducer.txt"
tp 12 "$WORK/r8.log" -l 0-1 $EAL --file-prefix=ch09-r8 --vdev=net_null0 --vdev=net_null1 -- \
	-i $MB --cmdline-file=recipes/r8_reproducer.txt < /dev/null
show "$WORK/r8.log" "^\[r8_reproducer.txt\]|Driver name|Rx Offloading Configuration|NIC statistics for port|RX-packets:.*RX-missed|Bye"

echo; echo "=== R9: surprise - net_null copy=1 under io forwarding stops after one pool ==="
say "dpdk-testpmd -l 0-1 $EAL --file-prefix=ch09-r9 --vdev=net_null0,copy=1 --vdev=net_null1,copy=1 -- $MB --stats-period 1 --forward-mode=io"
tp 5 "$WORK/r9.log" -l 0-1 $EAL --file-prefix=ch09-r9 --vdev=net_null0,copy=1 \
	--vdev=net_null1,copy=1 -- $MB --stats-period 1 --forward-mode=io
grep "Rx-pps" "$WORK/r9.log" | head -4
show "$WORK/r9.log" "Accumulated" > /dev/null
grep -A1 "Accumulated" "$WORK/r9.log" | tail -1
echo "(drivers/net/null/rte_eth_null.c: eth_null_copy_tx() copies but never frees the mbufs)"

# d1 <tag> <extra vhost args>: vhost side (socket server) in the background,
# virtio_user side in the foreground, both interactive.
d1() {
	local tag=$1; shift
	ri "${tag}v" 20 recipes/d1_vhost.txt -l 2-3 $EAL --file-prefix=ch09-${tag}v \
		--vdev=net_vhost0,iface=/tmp/ch09-d1.sock,queues=1 -- -i $MB --port-topology=loop "$@" &
	local vpid=$!
	sleep 1.5
	ri "$tag" 18 recipes/d1_virtio.txt -l 0-1 $EAL --file-prefix=ch09-$tag \
		--vdev=net_virtio_user0,path=/tmp/ch09-d1.sock -- -i $MB --port-topology=loop
	wait $vpid
	rm -f /tmp/ch09-d1.sock
	echo "--- virtio_user side:"
	show "$WORK/r$tag.log" "^testpmd> .|Driver name|Link status|Number of RXDs|Number of TXDs|Burst mode|Invalid|RX-bursts|TX-bursts|RX-packets:.*RX-dropped" | awk '!(/RX-packets/ && s++)'
	echo "--- vhost side:"
	show "$WORK/r${tag}v.log" "^testpmd> .|VHOST_CONFIG.*(new device,|negotiated Virtio)|link state|used desc count|Number of RXDs|RX-packets:.*RX-dropped" | awk '!(/RX-packets/ && s++)'
}
echo; echo "=== D1a: debugger on vhost-user + virtio_user (two processes), default flags ==="
d1 d1a
echo; echo "=== D1b: the same, vhost side started with --no-flush-rx ==="
d1 d1b --no-flush-rx

echo; echo "=== D2: testpmd as a debugger on net_null, plus hotplug of a pcap port ==="
ri d2 16 recipes/d2_null.txt -l 0-1 $EAL --file-prefix=ch09-d2 \
	--vdev=net_null0 --vdev=net_null1 -- -i $MB --record-burst-stats
sed "s#$WORK#\$WORK#g" "$WORK/rd2.log" | grep -E "^testpmd> .|Rx Offloading Capa|^  [A-Z_ ]+$|is attached|Driver name|Link status|src=|ol_flags|  - RX|  - TX|is detached|xstats for port|_packets|_bytes|RX-bursts|TX-bursts|Number of RXDs|Error|Invalid|Bad" | head -80
