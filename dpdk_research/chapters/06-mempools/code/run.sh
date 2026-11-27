#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 6: build and run every example. Output goes to stdout; to refresh
# the captured output:   ./run.sh 2>&1 | tee expected_output.txt
#
# All runs: --no-pci, a unique --file-prefix=ch06-*, timeout, --no-huge
# except one mempool_basics run that uses -m 64 of 2 MB hugepages to show
# the page-size effect on the object layout.
set -u
cd "$(dirname "$0")"

ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"

PREFIXES="ch06-basic ch06-basic-huge ch06-cache ch06-ops ch06-strand ch06-custom ch06-stack ch06-size ch06-opsmp"
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

EAL="--no-pci --no-huge"
run mempool_basics  -l 0   $EAL -m 64  --file-prefix=ch06-basic
run mempool_basics  -l 0   --no-pci -m 64 --file-prefix=ch06-basic-huge
run cache_explorer  -l 0-1 $EAL -m 64  --file-prefix=ch06-cache
run handler_bakeoff -l 0   $EAL -m 128 --file-prefix=ch06-ops
run stranded_cache  -l 0-2 $EAL -m 64  --file-prefix=ch06-strand
run custom_ops      -l 0   $EAL -m 64  --file-prefix=ch06-custom
run stack_demo      -l 0-1 $EAL -m 64  --file-prefix=ch06-stack
# exercise solutions
run pool_sizing     -l 0-3 $EAL -m 64  --file-prefix=ch06-size
run bakeoff_mp      -l 0-2 $EAL -m 128 --file-prefix=ch06-opsmp
