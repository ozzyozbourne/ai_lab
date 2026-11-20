#!/usr/bin/env bash
# Cerebras SDK 2.10.1 simulator experiments for the comparison chapters.
#   1. Dense matrix-vector product on ONE processing element (SDK benchmark single-tile-matvec),
#      at two sizes, each run twice: the on-device cycle count repeats exactly.
#   2. Event-driven tasks (course program 02-wavelet-tasks from ozzyozbourne/cerebrus), run three
#      times: the host injects wavelets at whatever time it gets to, the whole-run cycle count
#      differs between runs, the result does not.
# Usage: SDK=/home/user/cerebras-sdk COURSE=/home/user/cerebrus/course bash run.sh [workdir]
set -e
SDK=${SDK:-/home/user/cerebras-sdk}
COURSE=${COURSE:-/home/user/cerebrus/course}
WORK=${1:-$(mktemp -d)}
source "$SDK/env.sh"
BENCH=$(ls -d "$SDK"/extras/csl-extras-*/examples/benchmarks/single-tile-matvec)

echo "== 1. y = A.x on one PE (WSE-3), f32, N x N"
for N in 16 100; do
  for rep in 1 2; do
    d="$WORK/matvec_${N}_$rep"; rm -rf "$d"; cp -r "$BENCH" "$d"; cd "$d"
    cslc ./src/layout_matvec.csl --arch wse3 --fabric-dims=8,3 --fabric-offsets=4,1 \
      --params=width:1,height:1,tile_size:$N,iters:1 -o out --memcpy --channels=1 >/dev/null 2>&1
    cs_python ./run.py --name out --verify 2>/dev/null | grep -E "cycle|SUCCESS|Real walltime|flop" | sed "s/^/   N=$N run $rep: /"
    rm -rf "$d"
  done
done

echo "== 2. Data tasks fired by arriving wavelets (course program 02, N = 100 values)"
for rep in 1 2 3; do
  d="$WORK/tasks_$rep"; rm -rf "$d"; cp -r "$COURSE/programs/02-wavelet-tasks" "$d"; cd "$d"
  ARCH=wse3 bash commands.sh 2>/dev/null | grep -E "tasks fired|SUCCESS" | cut -c1-110 | sed "s/^/   run $rep: /"
  python3 -c "import json;print('   run $rep: whole-run simulated cycles =', json.load(open('sim_stats.json'))['cycle_count'])"
  rm -rf "$d"
done
