#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 7: build and run every example and exercise solution.
# Output goes to stdout; to refresh the captured output:
#     ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, --no-huge -m 64 (no hugepages needed for mbuf work),
# a unique --file-prefix=ch07-*, a 20 s timeout. No devices, no ports.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

PREFIXES="ch07-anat ch07-pay ch07-chain ch07-clone ch07-dyn ch07-ops ch07-dbg ch07-vlan ch07-corrupt ch07-dyno"
cleanup() {
	for p in $PREFIXES; do
		rm -rf "/var/run/dpdk/$p" "/run/dpdk/$p"
		rm -f /dev/hugepages/"$p"map_* 2>/dev/null
	done
}
trap cleanup EXIT INT TERM

make -s all || { echo "build failed"; exit 1; }

# run <name> <args...>: print the command, run it bounded, strip ANSI codes
run() {
	local bin=$1; shift
	echo
	echo "\$ ./$bin $*"
	timeout -s INT -k 5 20 stdbuf -oL "./$bin" "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
	local rc=${PIPESTATUS[0]}
	[ "$rc" -ne 0 ] && echo "[exit status $rc]"
	return 0
}

EAL="-l 0 --no-pci --no-huge -m 64"
run mbuf_anatomy  $EAL --file-prefix=ch07-anat
run payload_build $EAL --file-prefix=ch07-pay
run chain_demo    $EAL --file-prefix=ch07-chain
run clone_extbuf  $EAL --file-prefix=ch07-clone
run dynfield_demo $EAL --file-prefix=ch07-dyn
run pool_ops      $EAL --file-prefix=ch07-ops
run pool_ops      $EAL --file-prefix=ch07-ops --mbuf-pool-ops-name=stack
run debug_aids    $EAL --file-prefix=ch07-dbg
# exercise solutions
run vlan_prepend  $EAL --file-prefix=ch07-vlan
run clone_corrupt $EAL --file-prefix=ch07-corrupt
run dyn_order     $EAL --file-prefix=ch07-dyno -- b
run dyn_order     $EAL --file-prefix=ch07-dyno -- ts b
