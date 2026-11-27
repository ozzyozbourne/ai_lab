#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# compare.sh - the three execution models with the same synthetic work per
# packet (ch15_work(), WORK cycles), 5 runs each, median / min / max Mpps.
#
#   RTC          rtc_multiqueue --null   -l 0-2  2 worker lcores, 1 queue each
#   pipeline     pipeline_rings          -l 0-3  RX + 2 workers + TX
#   distributor  distributor_reorder     -l 0-2  distributor + 2 workers
#   pipeline ptr vs compressed, WORK=0 (ring traffic is all there is)
#
# Source and sink are net_null,size=64: these are CPU numbers from a shared
# 4-vCPU VM with software PMDs, not NIC line-rate numbers.
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
make -s all >/dev/null || exit 1

WORK=${WORK:-200}
REPS=${REPS:-5}
SECS=${SECS:-2}
cleanup() { rm -rf /var/run/dpdk/ch15-cmp-* /run/dpdk/ch15-cmp-*; }
trap cleanup EXIT INT TERM

# run_model <label> <prefix> <bin> <lcores> <app args...>: prints the Mpps
# of each run, then one summary line
run_model() {
	local label=$1 pfx=$2 bin=$3 lc=$4; shift 4
	local vals=()
	for r in $(seq 1 "$REPS"); do
		v=$(timeout -s INT -k 5 20 "./$bin" -l "$lc" --no-pci --no-huge -m 256 \
			--file-prefix="ch15-cmp-$pfx" --vdev=net_null0,size=64 -- "$@" 2>/dev/null \
			| sed -n 's/^RESULT .*mpps=\([0-9.]*\).*/\1/p')
		vals+=("${v:-0}")
	done
	printf '%s\n' "${vals[@]}" | sort -g | awk -v l="$label" -v runs="${vals[*]}" '
		{ a[NR] = $1 }
		END { printf "%-34s %8.2f %8.2f %8.2f   runs: %s\n", l, a[int((NR+1)/2)], a[1], a[NR], runs }'
}

echo "WORK=$WORK cycles/packet, $REPS runs x ${SECS}s each, Mpps delivered to TX"
printf "%-34s %8s %8s %8s\n" "model (lcores busy)" median min max
run_model "RTC queue-per-lcore (2)"      rtc  rtc_multiqueue      0-2 --null --seconds "$SECS" --work "$WORK"
run_model "pipeline RX/2W/TX (4)"        pipe pipeline_rings      0-3 --seconds "$SECS" --work "$WORK"
run_model "distributor + 2 workers (3)"  dist distributor_reorder 0-2 --bench --seconds "$SECS" --work "$WORK"
echo
echo "Pointer compression on the pipeline rings, WORK=0:"
run_model "pipeline, 8-byte pointers"    pptr pipeline_rings      0-3 --seconds "$SECS" --work 0
run_model "pipeline, 4-byte compressed"  pcmp pipeline_rings      0-3 --seconds "$SECS" --work 0 --compress
