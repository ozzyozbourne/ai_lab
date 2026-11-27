#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 8: provoke the classic port-initialisation errors on purpose and
# capture their exact text. Each run is bounded (timeout 10 s) and uses its
# own --file-prefix=ch08-ie-*. Run from code/ after "make" (run.sh does both).
#
#   E1  no ports at all                ("No probed ethernet devices")
#   E2  mbuf pool does not fit         (testpmd default pool in --no-huge -m 256;
#                                       our own pool in -m 16)
#   E3  nb_desc outside rx_desc_lim    (virtio_user: limit 32..32768; net_null
#                                       has no limit and accepts 1)
#   E4  configure while started        (-EBUSY)
#   E5  deferred start not supported   (-ENOTSUP on net_null)
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

WORK=$(mktemp -d /tmp/ch08-ie.XXXXXX)
SOCK=$WORK/ch08vh.sock
PREFIXES="ch08-ie-nop ch08-ie-tp ch08-ie-tp2 ch08-ie-pool ch08-ie-vh ch08-ie-desc ch08-ie-desc2 ch08-ie-null"
BG=""
cleanup() {
	[ -n "$BG" ] && kill -INT "$BG" 2>/dev/null && wait "$BG" 2>/dev/null
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

T="timeout -s INT -k 5 10 stdbuf -oL"
T4="timeout -s INT -k 5 4 stdbuf -oL"   # testpmd runs that would otherwise keep forwarding
# show <regex>: keep only the lines that matter, strip ANSI and the stack dump
show() { sed 's/\x1b\[[0-9;]*m//g' | grep -E "$1" | sed "s#$WORK#\$WORK#g"; }

echo "=== E1: no ports ==================================================="
echo "\$ dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-nop -- --total-num-mbufs=4096 --stats-period 1"
$T4 dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-nop -- \
	--total-num-mbufs=4096 --stats-period 1 2>&1 | show "No probed|ports=0"
echo "\$ ./my_skeleton -l 1 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-nop"
$T ./my_skeleton -l 1 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-nop 2>&1 | show "EAL: Error|need|EXIT"

echo
echo "=== E2: the mbuf pool does not fit in memory ======================="
echo "\$ dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-tp --vdev=net_null0 -- --stats-period 1"
$T dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-tp --vdev=net_null0 -- \
	--stats-period 1 2>&1 | show "create a new mbuf pool|Creation of mbuf pool|EAL: Error"
echo "\$ dpdk-testpmd ... same, plus --total-num-mbufs=8192"
$T4 dpdk-testpmd -l 0,1 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-tp2 --vdev=net_null0 -- \
	--total-num-mbufs=8192 --stats-period 1 2>&1 | show "create a new mbuf pool|Creation of mbuf pool|^Port 0:"
echo "\$ ./my_skeleton -l 1 --no-pci --no-huge -m 16 --file-prefix=ch08-ie-pool --vdev=net_null0 --vdev=net_null1"
$T ./my_skeleton -l 1 --no-pci --no-huge -m 16 --file-prefix=ch08-ie-pool --vdev=net_null0 \
	--vdev=net_null1 2>&1 | show "mbuf pool|cannot|EAL: Error"

echo
echo "=== E3: nb_desc outside dev_info.rx_desc_lim ======================="
echo "# net_null advertises no limits (min 0, max 65535, align 1): nb_desc=1 is accepted"
echo "\$ ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-null --vdev=net_null0 -- --nb-desc 1 --no-adjust"
$T ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-null --vdev=net_null0 -- \
	--nb-desc 1 --no-adjust 2>&1 | show "rx_desc_lim|queue_setup"
echo "# virtio_user needs a vhost-user backend: start testpmd with net_vhost0 in the background"
$T dpdk-testpmd -l 2,3 --no-pci --no-huge -m 256 --file-prefix=ch08-ie-vh \
	--vdev=net_vhost0,iface="$SOCK",queues=1 -- --total-num-mbufs=4096 --stats-period 5 \
	> "$WORK/vhost.log" 2>&1 &
BG=$!
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
echo "\$ ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-desc --vdev=virtio_user0,path=\$WORK/ch08vh.sock,queues=1 -- --nb-desc 1 --no-adjust"
$T ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-desc \
	--vdev=virtio_user0,path="$SOCK",queues=1 -- --nb-desc 1 --no-adjust 2>&1 \
	| show "driver|rx_desc_lim|Invalid value|queue_setup"
echo "# the same with rte_eth_dev_adjust_nb_rx_tx_desc(): 1 is clamped to nb_min"
echo "\$ ./port_explorer ... --file-prefix=ch08-ie-desc2 ... -- --nb-desc 1"
$T ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-desc2 \
	--vdev=virtio_user0,path="$SOCK",queues=1 -- --nb-desc 1 2>&1 \
	| show "descriptors asked|queue_setup|dev_start  "
kill -INT "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; BG=""

echo
echo "=== E4 + E5: configure while started, deferred start unsupported ===="
echo "\$ ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-null --vdev=net_null0"
$T ./port_explorer -l 0 --no-pci --no-huge -m 128 --file-prefix=ch08-ie-null --vdev=net_null0 2>&1 \
	| show "must be stopped|while started|Deferred|deferred_start"
echo
echo "init_errors.sh done"
