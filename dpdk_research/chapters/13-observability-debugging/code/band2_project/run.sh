#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Chapter 13 band 2 project: acceptance check.
#
# Starts the forwarder (BIN, default ./l2fwd_mc) with 2 x 512 frames and a
# hop budget of 200000, drives its shell from a script on stdin, reads
# /band2/stats over telemetry while it runs, and decides PASS/FAIL from:
#   1. the program's own RESULT line (rx == tx + drop per lcore, exact
#      totals, in_use == 0 at the end)
#   2. the telemetry reading: lcore1 and lcore2 present, rx > 0 mid-run
#   3. at least one [timer] report and one [shell] answer were printed
set -u
cd "$(dirname "$0")"
ENV_SH=${ENV_SH:-/tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh}
# shellcheck disable=SC1090
[ -f "$ENV_SH" ] && source "$ENV_SH"
BIN=${BIN:-./l2fwd_mc}
PREFIX=ch13-b2
OUT=$(mktemp /tmp/ch13b2.XXXXXX)
cleanup() { rm -f "$OUT"; rm -rf /var/run/dpdk/$PREFIX; jobs -p | xargs -r kill 2>/dev/null; }
trap cleanup EXIT INT TERM
[ "$BIN" = ./l2fwd_mc ] && { make -s l2fwd_mc || exit 1; }

echo "\$ (shell script) | $BIN -l 0-2 --no-pci --no-huge -m 128 --file-prefix=$PREFIX --vdev=net_ring0..3 -- --frames 512 --hops 200000"
( sleep 0.8; echo "show stats"; sleep 0.4; echo "show pool"; sleep 0.2; echo "quit" ) |
	timeout -s INT -k 5 15 stdbuf -oL "$BIN" -l 0-2 --no-pci --no-huge -m 128 \
		--file-prefix=$PREFIX --vdev=net_ring0 --vdev=net_ring1 \
		--vdev=net_ring2 --vdev=net_ring3 -- --frames 512 --hops 200000 \
		> "$OUT" 2>&1 &
sleep 1.0
TEL=$(python3 -I ../tq.py $PREFIX /band2/stats 2>&1)
wait
grep -v "^EAL: \(Detected\|Multi-process\|Selected\)" "$OUT"
echo "telemetry at t~1s: $TEL"

pass=1
grep -q "^RESULT: PASS" "$OUT" || { echo "acceptance: program check failed"; pass=0; }
echo "$TEL" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read())["/band2/stats"]
ok = all(k in d and d[k]["rx"] > 0 for k in ("lcore1", "lcore2"))
sys.exit(0 if ok else 1)' || { echo "acceptance: telemetry /band2/stats missing or empty"; pass=0; }
grep -q "^\[timer\]" "$OUT" || { echo "acceptance: no timer report"; pass=0; }
grep -q "^\[shell\]" "$OUT" || { echo "acceptance: shell did not answer"; pass=0; }
[ $pass = 1 ] && echo "BAND 2 PROJECT: PASS" || echo "BAND 2 PROJECT: FAIL"
