#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# first_look.sh - Chapter 2 "first look" lab. No code to understand yet:
# run two prebuilt DPDK programs on two software ports (net_null) and read
# the counters. Chapters 3-8 explain every line of what you see here.
set -u
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
source "$ENV_SH"
OUT=$(mktemp -d)
cleanup() {
	pkill -INT -f 'file-prefix=ch02-(first|skel)' 2>/dev/null
	rm -rf "$OUT" /var/run/dpdk/ch02-first* /var/run/dpdk/ch02-skel
}
trap cleanup EXIT
strip_ansi() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }

echo "=== first look 1: examples/skeleton (basicfwd.c) on two net_null ports, 3 s ==="
echo "\$ dpdk-skeleton -l 0 --no-pci --no-huge -m 256 --file-prefix=ch02-skel --vdev=net_null0 --vdev=net_null1"
timeout -s INT -k 5 3 stdbuf -oL "$DPDK_SRC/build/examples/dpdk-skeleton" -l 0 --no-pci \
	--no-huge -m 256 --file-prefix=ch02-skel --vdev=net_null0 --vdev=net_null1 \
	> "$OUT/skel.txt" 2>&1
echo "(exit code $? : 124 = stopped by timeout, the skeleton loops forever)"
strip_ansi < "$OUT/skel.txt"
echo

echo "=== first look 2: testpmd io forwarding on two net_null ports, 8 s ==="
echo "\$ dpdk-testpmd -l 0-1 --no-pci --no-huge -m 256 --file-prefix=ch02-first --vdev=net_null0 --vdev=net_null1 -- --total-num-mbufs=8192 --stats-period 2 --forward-mode=io"
timeout -s INT -k 5 8 stdbuf -oL "$DPDK_SRC/build/app/dpdk-testpmd" -l 0-1 --no-pci \
	--no-huge -m 256 --file-prefix=ch02-first --vdev=net_null0 --vdev=net_null1 \
	-- --total-num-mbufs=8192 --stats-period 2 --forward-mode=io > "$OUT/tp.txt" 2>&1
# Show the start-up, the LAST periodic statistics block, and the final summary.
strip_ansi < "$OUT/tp.txt" | sed -n '1,/^Logical Core/p'
echo "  [... per-queue configuration and earlier stats blocks trimmed ...]"
strip_ansi < "$OUT/tp.txt" | awk '/^Port statistics/{blk=""} {blk=blk $0 "\n"} /Telling cores to stop/{printf "%s", last; exit} /^  #####+$/{last=blk}'
strip_ansi < "$OUT/tp.txt" | sed -n '/Telling cores to stop/,$p'
echo

echo "=== first look 3: how fast? 5 runs x 4 s, Rx-pps of port 0 in the last 1 s period ==="
vals=()
for i in 1 2 3 4 5; do
	timeout -s INT -k 5 4 stdbuf -oL "$DPDK_SRC/build/app/dpdk-testpmd" -l 0-1 --no-pci \
		--no-huge -m 256 --file-prefix=ch02-first$i --vdev=net_null0 --vdev=net_null1 \
		-- --total-num-mbufs=8192 --stats-period 1 --forward-mode=io > "$OUT/m$i.txt" 2>&1
	v=$(strip_ansi < "$OUT/m$i.txt" | grep 'Rx-pps' | awk 'NR%2==1{x=$2} END{print x}')
	echo "  run $i: port 0 Rx-pps = $v"
	vals+=("$v")
done
printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{printf "  median %.1f Mpps  (min %.1f, max %.1f) per port, net_null software ports, 1 forwarding lcore, this VM\n", a[3]/1e6, a[1]/1e6, a[5]/1e6}'
