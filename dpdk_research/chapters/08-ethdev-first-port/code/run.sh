#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 8: build and run every example, the exercise solution, the shipped
# dpdk-skeleton and init_errors.sh. To refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge -m 128 (no hugepages needed), a unique
# --file-prefix=ch08-*, timeout -s INT. Ports are virtual: net_null, net_ring,
# net_tap (interface ch08tap0, removed by the PMD on close) and, inside
# init_errors.sh, virtio_user + net_vhost over a temporary socket.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
E=$DPDK_SRC/build/examples

PREFIXES="ch08-ports ch08-skel ch08-sweep ch08-cable ch08-sk ch08-pairs ch08-tel ch08-dbg ch08-rules"
TPID=""
cleanup() {
	[ -n "$TPID" ] && kill -INT "$TPID" 2>/dev/null && wait "$TPID" 2>/dev/null
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
	ip link del ch08tap0 2>/dev/null
	ip link del ch08tap1 2>/dev/null
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run <secs> <binary> <args...>: print the command, run it bounded, strip ANSI
run() {
	local secs=$1 bin=$2; shift 2
	echo
	echo "\$ $bin $*" | sed "s#$E#\$E#"
	timeout -s INT -k 5 "$secs" stdbuf -oL "$bin" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo "[exit status $rc]"
	[ "$rc" -eq 124 ] && echo "[stopped by SIGINT from timeout after ${secs}s]"
	return 0
}

EAL="--no-pci --no-huge -m 128"
run 20 ./port_explorer -l 0 $EAL --file-prefix=ch08-ports \
	--vdev=net_null0 --vdev=net_ring0 --vdev=net_tap0,iface=ch08tap0
# the lifecycle rules: wrong-order calls on net_null, then the early
# queue-setup call on net_null (crashes, exit 139) and on net_tap (-EINVAL)
run 10 ./lifecycle_rules -l 0 --no-pci --no-huge -m 64 --file-prefix=ch08-rules \
	--vdev=net_null0 --log-level=lib.ethdev:info
run 10 ./lifecycle_rules -l 0 --no-pci --no-huge -m 64 --file-prefix=ch08-rules \
	--vdev=net_null0 --log-level=lib.ethdev:info -- --early-setup
run 10 ./lifecycle_rules -l 0 --no-pci --no-huge -m 64 --file-prefix=ch08-rules \
	--vdev=net_tap0,iface=ch08tap1 --log-level=lib.ethdev:info -- --early-setup
run 5 ./my_skeleton -l 1 $EAL --file-prefix=ch08-skel --vdev=net_null0 --vdev=net_null1
run 4 ./my_skeleton -l 1 $EAL --file-prefix=ch08-skel --vdev=net_null0 --vdev=net_null1 -- --burst 4
run 4 ./my_skeleton -l 1 $EAL --file-prefix=ch08-skel --vdev=net_null0 --vdev=net_null1 -- --burst 4 --tx-buffer
run 20 ./burst_sweep -l 0 $EAL --file-prefix=ch08-sweep --vdev=net_null0
run 20 ./ring_cable -l 0 $EAL --file-prefix=ch08-cable
run 20 ./ring_cable -l 0 $EAL --file-prefix=ch08-cable -- --leak
# "when it doesn't work" 1: one telemetry query against a running forwarder
echo
echo "\$ ./my_skeleton ... --file-prefix=ch08-tel &   # background, 5 s"
timeout -s INT -k 5 5 ./my_skeleton -l 1 $EAL --file-prefix=ch08-tel \
	--vdev=net_null0 --vdev=net_null1 > /dev/null 2>&1 &
TPID=$!
sleep 2
echo "\$ echo /ethdev/stats,0 | dpdk-telemetry.py -f ch08-tel"
echo "/ethdev/stats,0" | python3 -I "$(command -v dpdk-telemetry.py)" -f ch08-tel 2>&1 | tail -1
wait "$TPID" 2>/dev/null; TPID=""
# "when it doesn't work" 2: debug logs from ethdev and the PMD
echo
echo "\$ ./port_explorer -l 0 $EAL --file-prefix=ch08-dbg --vdev=net_null0 --log-level=lib.ethdev:debug --log-level=pmd.net.null:debug | grep -E 'ETH_NULL|ETHDEV'"
timeout -s INT -k 5 10 ./port_explorer -l 0 $EAL --file-prefix=ch08-dbg --vdev=net_null0 \
	--log-level=lib.ethdev:debug --log-level=pmd.net.null:debug 2>&1 | grep -E '^(ETH_NULL|ETHDEV)'
# the shipped sample, for comparison (stdbuf -oL keeps its output when killed)
run 6 "$E/dpdk-skeleton" -l 1 $EAL --file-prefix=ch08-sk --vdev=net_null0 --vdev=net_null1
# exercise 1 solution: explicit pairing with a gap in the port ids
run 10 ./skeleton_pairs -l 1 $EAL --file-prefix=ch08-pairs --vdev=net_null0 --vdev=net_null1 \
	--vdev=net_null2 --vdev=net_null3 --vdev=net_null4 -- --exclude 2

echo
echo "\$ ./init_errors.sh"
./init_errors.sh
