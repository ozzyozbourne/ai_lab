#!/usr/bin/env bash
# ttsim experiments for the comparison chapters (tt-metal 7aad8aac built, ttsim v1.15.0).
#   1. The smallest program (add two integers on one RISC-V core) and a 640 x 640 bfloat16 matmul on
#      one Tensix core, each run twice: ttsim's clock count repeats exactly.
#   2. Flow control: the stock eltwise-add pipeline, then the same pipeline with a writer kernel that
#      idles 300 clocks before every tile (patch from ozzyozbourne/tenstorrents, lab B06).
#      The result is still correct; only the clock count changes.
# ttsim is a functional, bit-exact model, not a timing model: its clock counts are not silicon time.
# Usage: TT_COURSE=/home/user/tenstorrents bash run.sh [lab_home]
set -e
TT_COURSE=${TT_COURSE:-/home/user/tenstorrents}
W=$TT_COURSE/sim-labs/workbench
export LAB_HOME=${1:-$HOME/ttlab/three-accelerators}
mkdir -p "$LAB_HOME"; export TT_METAL_CACHE=$LAB_HOME/cache
source "$W/env.sh" wh >/dev/null
last() { grep -E "^\[[0-9]+\]" | tail -1 | awk '{print $1}'; }

echo "== 1a. add_2_integers_in_riscv (Wormhole), twice"
for rep in 1 2; do
  out=$($EX/metal_example_add_2_integers_in_riscv 2>&1)
  echo "   run $rep: $(echo "$out" | grep -o 'Success: Result is [0-9]*') clocks=$(echo "$out" | last)"
done

echo "== 1b. 640 x 640 bfloat16 matmul on one Tensix core (HiFi4, seed 42), twice"
[ -x "$LAB_HOME/host/mm_fid" ] || (mkdir -p "$LAB_HOME/host" && cp "$W/host/mm_fid.cpp" "$LAB_HOME/host/" && "$W/build_host.sh" "$LAB_HOME/host/mm_fid.cpp" >/dev/null 2>&1)
for rep in 1 2; do
  out=$(MM_FIDELITY=4 MM_SEED=42 "$LAB_HOME/host/mm_fid" 2>&1)
  echo "   run $rep: $(echo "$out" | grep -E 'result_hash|Test Passed' | tr '\n' ' ') clocks=$(echo "$out" | last)"
done

echo "== 2. eltwise add of 64 tiles: stock writer, then a writer that idles 300 clocks per tile"
out=$($EX/metal_example_eltwise_binary 2>&1)
echo "   stock writer: $(echo "$out" | grep -o 'Test Passed') clocks=$(echo "$out" | last)"
K=$LAB_HOME/kernels/tt_metal/programming_examples/eltwise_binary/kernels/dataflow
mkdir -p "$K"; cp "$TT_METAL_HOME/tt_metal/programming_examples/eltwise_binary/kernels/dataflow/write_tile.cpp" "$K/"
(cd "$LAB_HOME/kernels" && patch -s -p1 < "$TT_COURSE/sim-labs/patches/b06-slow-writer.patch")
out=$($EX/metal_example_eltwise_binary 2>&1)
echo "   slow writer:  $(echo "$out" | grep -o 'Test Passed') clocks=$(echo "$out" | last)"
rm -rf "$LAB_HOME/kernels/tt_metal"
