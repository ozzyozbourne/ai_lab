#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13: debug_labs/run_all.sh - run the five seeded bugs, the
# diagnosis commands for each, and the fixed version.
#
# Each lab runs twice: 'lab' (with the bug) and 'lab_fixed' (-DFIXED).
# While the buggy one runs, telemetry is queried from outside with ../tq.py,
# exactly as you would on a production box. Prefixes: ch13-dbg-<name>.
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
EAL="--no-pci --no-huge -m 128"
TQ="python3 -I ../tq.py"
cleanup() {
	for p in promisc mtu leak dfree 2lc; do
		rm -rf /var/run/dpdk/ch13-dbg-$p
	done
	ip link del ch13tap1 2>/dev/null
	ip link del ch13tap2 2>/dev/null
	jobs -p | xargs -r kill 2>/dev/null
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run_bg <secs> <prefix> <bin> <args...>: start bounded, output to $OUT
OUT=$(mktemp /tmp/ch13lab.XXXXXX)
run_bg() {
	local secs=$1; shift
	echo "\$ $*"
	timeout -s INT -k 5 "$secs" stdbuf -oL "$@" > "$OUT" 2>&1 &
}
show() { wait; grep -v "^EAL: \(Detected\|Multi-process\|Selected\)" "$OUT"; }
diag() { echo "--- diag: $*"; "$@" 2>&1; }

echo "######## LAB 1 promisc_off (net_tap ch13tap1)"
run_bg 15 promisc_off/lab -l 0 $EAL --file-prefix=ch13-dbg-promisc --vdev=net_tap0,iface=ch13tap1
sleep 1.4
diag $TQ ch13-dbg-promisc /ethdev/stats,0 ipackets ierrors imissed
diag $TQ ch13-dbg-promisc /ethdev/info,0 mac_addr promiscuous all_multicast
diag $TQ ch13-dbg-promisc /ethdev/macs,0
echo "--- diag: ip -d link show ch13tap1 (kernel side)"
ip -d link show ch13tap1 | sed -n 2p | sed 's/minmtu.*//'
echo "--- symptom (program output):"
show
echo "--- fixed:"
run_bg 15 promisc_off/lab_fixed -l 0 $EAL --file-prefix=ch13-dbg-promisc --vdev=net_tap0,iface=ch13tap1
show

echo
echo "######## LAB 2 mtu_noscatter (net_tap ch13tap2)"
run_bg 15 mtu_noscatter/lab -l 0 $EAL --file-prefix=ch13-dbg-mtu --vdev=net_tap0,iface=ch13tap2
sleep 1.4
diag $TQ ch13-dbg-mtu /ethdev/stats,0 ipackets ierrors imissed
diag $TQ ch13-dbg-mtu /ethdev/info,0 mtu rx_mbuf_size_min scattered_rx rx_offloads
echo "--- symptom (program output):"
show
echo "--- fixed:"
run_bg 15 mtu_noscatter/lab_fixed -l 0 $EAL --file-prefix=ch13-dbg-mtu --vdev=net_tap0,iface=ch13tap2
sleep 1.4
diag $TQ ch13-dbg-mtu /ethdev/info,0 mtu scattered_rx rx_offloads
show
echo "--- what net_tap logs with rxmode.mtu=9000 but no SCATTER flag (warning only):"
timeout -s INT 15 dpdk-testpmd -l 0-1 $EAL --file-prefix=ch13-dbg-mtu --vdev=net_tap0,iface=ch13tap2 \
	-- --total-num-mbufs=4096 --max-pkt-len=9018 --stats-period 1 2>&1 < /dev/null |
	grep -m2 -E "scatter|TAP"

echo
echo "######## LAB 3 leak (net_null)"
run_bg 15 leak/lab -l 0 $EAL --file-prefix=ch13-dbg-leak --vdev=net_null0 --vdev=net_null1
sleep 1.6
diag $TQ ch13-dbg-leak /mempool/info,lab_pool size populated_size common_pool_count total_cache_count
diag $TQ ch13-dbg-leak /ethdev/stats,0 ipackets rx_nombuf
sleep 0.5
diag $TQ ch13-dbg-leak /ethdev/stats,0 ipackets rx_nombuf
echo "--- symptom (program output):"
show
echo "--- fixed:"
run_bg 15 leak/lab_fixed -l 0 $EAL --file-prefix=ch13-dbg-leak --vdev=net_null0 --vdev=net_null1
show

echo
echo "######## LAB 4 double_free (no ports)"
run_bg 15 double_free/lab -l 0 $EAL --file-prefix=ch13-dbg-dfree
sleep 0.8
diag $TQ ch13-dbg-dfree /mempool/info,lab_pool size common_pool_count total_cache_count
echo "--- symptom (program output):"
show
echo "--- fixed:"
run_bg 15 double_free/lab_fixed -l 0 $EAL --file-prefix=ch13-dbg-dfree
show

echo
echo "######## LAB 5 two_lcores_one_queue (net_ring)"
run_bg 15 two_lcores_one_queue/lab -l 0-2 $EAL --file-prefix=ch13-dbg-2lc --vdev=net_ring0 --vdev=net_ring1
sleep 1.0
diag $TQ ch13-dbg-2lc /ethdev/stats,0 ipackets opackets
diag $TQ ch13-dbg-2lc /mempool/info,lab_pool size common_pool_count
diag $TQ ch13-dbg-2lc /eal/lcore/info,1 lcore_id role cpuset
echo "--- symptom (program output):"
show
echo "--- fixed:"
run_bg 15 two_lcores_one_queue/lab_fixed -l 0-2 $EAL --file-prefix=ch13-dbg-2lc --vdev=net_ring0 --vdev=net_ring1
show
rm -f "$OUT"
echo
echo "debug labs done; leftover ch13tap interfaces: $(ip -o link | grep -c ch13tap)"
