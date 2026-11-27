#!/usr/bin/env bash
# ivp_sweep.sh - repeat the intr_vs_poll measurement REPS times (default 5) per
# (mode, offered rate) cell and print median/min/max of CPU% and median latency.
# This is where the numbers in the chapter's "Interrupt vs polling" widget come
# from. Takes about 2.5 minutes. Run as root after `make`.
set -u
cd "$(dirname "$0")"
if [ -n "${DPDK_ENV:-}" ] && [ -f "$DPDK_ENV" ]; then . "$DPDK_ENV"
elif [ -f ../../../common/env.sh ]; then . ../../../common/env.sh
elif [ -f /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh ]; then
	. /tmp/claude-0/-home-user-ai-lab/fae9d2b5-bcbe-5be9-a4f0-08ae6c821ee6/scratchpad/dpdk-env.sh
fi
REPS=${REPS:-5}
cleanup() { jobs -p | xargs -r kill 2>/dev/null; ip link del ch01tap0 2>/dev/null; rm -rf /var/run/dpdk/ch01-ivs; rm -f ivs.out ivs.all; }
trap cleanup EXIT INT TERM
make -s || exit 1
: > ivs.all
for rate in 0 100 1000 10000; do
  for mode in poll intr; do
    for r in $(seq "$REPS"); do
      timeout -s INT -k 5 20 ./intr_vs_poll -l 1 --no-pci --no-huge -m 128 --file-prefix=ch01-ivs \
        --vdev=net_tap0,iface=ch01tap0 -- $mode 3 > ivs.out 2>&1 &
      pid=$!; sleep 0.8; ip link set ch01tap0 up 2>/dev/null
      [ "$rate" -gt 0 ] && taskset -c 3 python3 -I ./inject.py ch01tap0 "$rate" 1.8 >/dev/null
      wait $pid
      cpu=$(grep -o 'cpu=[0-9.]*' ivs.out | cut -d= -f2)
      lat=$(grep -o 'median [0-9.]*' ivs.out | awk '{print $2}')
      wk=$(grep -o 'wakeups=[0-9]*' ivs.out | cut -d= -f2)
      iv=$(grep -o 'ivcsw=[0-9]*' ivs.out | cut -d= -f2)
      echo "$rate $mode ${cpu:-NA} ${lat:-NA} ${wk:-NA} ${iv:-NA}" >> ivs.all
    done
  done
done
echo "raw runs: rate mode cpu% median_lat_us wakeups ivcsw"
cat ivs.all
echo
echo "intr_vs_poll sweep: $REPS runs of 3 s per cell (net_tap, 1 lcore, VM)"
python3 -I - ivs.all <<'PY'
import sys, statistics as st
rows = [l.split() for l in open(sys.argv[1])]
print(f"{'rate/s':>7} {'mode':>4} | {'cpu% med':>8} {'min':>6} {'max':>6} | {'lat us med':>10} {'min':>6} {'max':>6} | {'wakeups/s':>9} {'ivcsw max':>9}")
seen = []
for r in rows:
    k = (r[0], r[1])
    if k in seen: continue
    seen.append(k)
    g = [x for x in rows if (x[0], x[1]) == k]
    c = [float(x[2]) for x in g if x[2] != 'NA']
    l = [float(x[3]) for x in g if x[3] != 'NA']
    w = [float(x[4]) / 3 for x in g if x[4] != 'NA']
    ls = f"{st.median(l):10.1f} {min(l):6.1f} {max(l):6.1f}" if l else f"{'-':>10} {'-':>6} {'-':>6}"
    print(f"{k[0]:>7} {k[1]:>4} | {st.median(c):8.1f} {min(c):6.1f} {max(c):6.1f} | {ls} | {st.median(w):9.0f} {max(int(x[5]) for x in g if x[5] != 'NA'):9d}")
PY
