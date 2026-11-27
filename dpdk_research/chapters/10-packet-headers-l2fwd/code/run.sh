#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 10: build and run every example, the exercise solutions and the
# prebuilt dpdk-l2fwd. To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge -m 64/128 (no hugepages needed), a unique
# --file-prefix=ch10-*, timeout -s INT. Ports are virtual: net_pcap (files
# made by gen_pcaps.py) and net_ring (loopback rings). Nothing touches eth0.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
E=$DPDK_SRC/build/examples
TMP=$(mktemp -d)

PREFIXES="ch10-parse ch10-build ch10-ck ch10-mini ch10-l2 ch10-pvlan ch10-incr ch10-filt"
cleanup() {
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }
python3 -I gen_pcaps.py

# run <secs> <binary> <args...>: print the command, run it bounded, strip ANSI.
# Output goes through a file so a SIGINT from timeout never hits this shell.
run() {
	local secs=$1 bin=$2; shift 2
	echo
	echo "\$ $bin $*" | sed "s#$E#\$E#"
	timeout -s INT -k 5 "$secs" stdbuf -oL "$bin" "$@" > "$TMP/out" 2>&1
	local rc=$?
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$TMP/out"
	[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo "[exit status $rc]"
	[ "$rc" -eq 124 ] && echo "[stopped by SIGINT from timeout after ${secs}s]"
	return 0
}

echo "################ 1. cksum_lab: the Internet checksum by hand"
run 10 ./cksum_lab -l 0 --no-pci --no-huge -m 64 --file-prefix=ch10-ck

echo
echo "################ 2. parse_pcap on mixed.pcap"
run 20 ./parse_pcap -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-parse \
	--vdev=net_pcap0,rx_pcap=mixed.pcap,tx_pcap=/dev/null

echo
echo "################ 3. build_packets -> built.pcap, checked by verify.py and parse_pcap"
rm -f built.pcap built.crc
run 20 ./build_packets -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-build \
	--vdev=net_pcap0,rx_pcap=empty.pcap,tx_pcap=built.pcap
echo
echo "\$ python3 -I verify.py built.pcap built.crc"
python3 -I verify.py built.pcap built.crc
run 20 ./parse_pcap -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-parse \
	--vdev=net_pcap0,rx_pcap=built.pcap,tx_pcap=/dev/null

echo
echo "################ 4. 26.11 API changes at compile time"
CF="-Wall $(pkg-config --cflags libdpdk)"
echo
echo "\$ gcc -Wall -DVARIANT=1 -c packed_old.c && nm -S packed_old.o   # old '} __rte_packed;'"
gcc $CF -DVARIANT=1 -c packed_old.c -o "$TMP/po.o" 2>&1 && echo "[compiled without any error or warning]"
nm -S "$TMP/po.o" | sed 's/^/    /'
echo
echo "\$ gcc -Wall -DVARIANT=1 -DWITH_SIZE_CHECK -c packed_old.c   # + static_assert(sizeof == 8)"
gcc $CF -DVARIANT=1 -DWITH_SIZE_CHECK -c packed_old.c -o /dev/null 2>&1 | grep -E 'error' ; echo "[exit status ${PIPESTATUS[0]}]"
echo
echo "\$ gcc -Wall -DVARIANT=2 -c packed_old.c   # old 'typedef struct {...} __rte_packed t;'"
gcc $CF -DVARIANT=2 -c packed_old.c -o /dev/null 2>&1 | grep -E 'error' ; echo "[exit status ${PIPESTATUS[0]}]"
echo
echo "\$ gcc -Wall -c build_packets.c   # without -DALLOW_EXPERIMENTAL_API"
gcc $CF -c build_packets.c -o /dev/null 2>&1 | grep -E 'warning|error' | sed 's/^/    /'; echo "[exit status ${PIPESTATUS[0]}]"

echo
echo "################ 5. mini_l2fwd: TX buffer and drain timer on two net_ring loopbacks"
MINI="-l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-mini --vdev=net_ring0 --vdev=net_ring1"
run 20 ./mini_l2fwd $MINI -- --inject 20 --drain-us 0 --seconds 1
run 20 ./mini_l2fwd $MINI -- --inject 20 --drain-us 100 --seconds 2
run 20 ./mini_l2fwd $MINI -- --inject 100 --drain-us 0 --seconds 1

echo
echo "################ 6. the shipped dpdk-l2fwd on two net_pcap ports"
L2="-l 0,1 --no-pci --no-huge -m 128 --file-prefix=ch10-l2"
rm -f l2out0.pcap l2out1.pcap
run 4 "$E/dpdk-l2fwd" $L2 --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=l2out0.pcap \
	--vdev=net_pcap1,rx_pcap=empty.pcap,tx_pcap=l2out1.pcap -- -p 0x3 -q 2 -T 1
echo
echo "\$ python3 -I l2check.py l2out0.pcap:0:02:70:63:61:70:00 l2out1.pcap:1:02:70:63:61:70:01"
python3 -I l2check.py l2out0.pcap:0:02:70:63:61:70:00 l2out1.pcap:1:02:70:63:61:70:01
echo
echo "\$ ... same run with --no-mac-updating, stats off (-T 0): the check is EXPECTED to fail"
rm -f l2out0.pcap l2out1.pcap
timeout -s INT -k 5 3 "$E/dpdk-l2fwd" $L2 --vdev=net_pcap0,rx_pcap=in.pcap,tx_pcap=l2out0.pcap \
	--vdev=net_pcap1,rx_pcap=empty.pcap,tx_pcap=l2out1.pcap -- -p 0x3 -q 2 -T 0 --no-mac-updating \
	> "$TMP/out" 2>&1
grep -E 'MAC updating' "$TMP/out"
python3 -I l2check.py l2out1.pcap:1:02:70:63:61:70:01

echo
echo "################ 7. exercise solutions"
run 20 ./parse_vlan -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-pvlan \
	--vdev=net_pcap0,rx_pcap=mixed.pcap,tx_pcap=/dev/null
run 10 ./incr_cksum -l 0 --no-pci --no-huge -m 64 --file-prefix=ch10-incr
run 20 ./mini_l2fwd_filter -l 0 --no-pci --no-huge -m 128 --file-prefix=ch10-filt \
	--vdev=net_ring0 --vdev=net_ring1 -- --inject 30 --drain-us 100 --seconds 1
