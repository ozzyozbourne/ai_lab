"""Example 4.6 - branch divergence: 8 cases selected by tid % 8 vs grouped vs 8 launches.

Every element runs one of 8 different loops. Three ways to schedule the same work:
  interleaved  one launch, branch = i % 8      -> the 32 lanes of a GPU warp disagree (divergent)
  grouped      one launch, branch = i // M     -> all lanes of a warp agree (no divergence)
  specialized  8 launches, one branch each     -> no divergence, 8 launch overheads
On a GPU the interleaved kernel is expected to be the slowest; run it and compare your own numbers.
On Warp's CPU device threads run one after another, there are no lanes, so the three times are
close: divergence is a GPU effect.
Run: python ex6_divergence.py [--dump-json PATH]
"""
import argparse
import json
import time

import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
N = (1 << 22) if ON_GPU else (1 << 16)            # elements; multiple of 8 * 32
M = N // 8                                         # elements per branch
ITERS = 64


@wp.func
def work(branch: int, x: float) -> float:
    r = x
    if branch == 0:
        for _ in range(ITERS):
            r = wp.sin(r) + 0.5
    elif branch == 1:
        for _ in range(ITERS):
            r = wp.cos(r) * 0.9
    elif branch == 2:
        for _ in range(ITERS):
            r = wp.sqrt(r * r + 1.0) - 0.9
    elif branch == 3:
        for _ in range(ITERS):
            r = wp.exp(-r * r)
    elif branch == 4:
        for _ in range(ITERS):
            r = wp.tanh(r) + 0.25
    elif branch == 5:
        for _ in range(ITERS):
            r = 1.0 / (1.0 + r * r)
    elif branch == 6:
        for _ in range(ITERS):
            r = wp.log(1.0 + r * r)
    else:
        for _ in range(ITERS):
            r = wp.atan(r) + 0.1
    return r


@wp.kernel
def interleaved(x: wp.array[float], out: wp.array[float]):
    i = wp.tid()
    out[i] = work(i % 8, x[i])                     # neighbours take different branches


@wp.kernel
def grouped(m: int, x: wp.array[float], out: wp.array[float]):
    i = wp.tid()
    out[i] = work(i // m, x[i])                    # a whole warp shares one branch


@wp.kernel
def one_branch(branch: int, m: int, x: wp.array[float], out: wp.array[float]):
    j = wp.tid()
    i = branch * m + j
    out[i] = work(branch, x[i])                    # every thread of this launch: same branch


x_np = np.random.default_rng(0).random(N, dtype=np.float32)   # grouped order: branch-major
x = wp.array(x_np)
# the same values in interleaved order: element 8 * j + c holds x_np[c * M + j]
x_inter = wp.array(x_np.reshape(8, M).T.copy().reshape(N))
out_a = wp.zeros(N, dtype=float)
out_b = wp.zeros(N, dtype=float)
out_c = wp.zeros(N, dtype=float)


def run_interleaved():
    wp.launch(interleaved, dim=N, inputs=[x_inter], outputs=[out_a])


def run_grouped():
    wp.launch(grouped, dim=N, inputs=[M, x], outputs=[out_b])


def run_specialized():
    for branch in range(8):
        wp.launch(one_branch, dim=M, inputs=[branch, M, x], outputs=[out_c])


def best_ms(fn, reps=5):
    fn()                                           # warm-up: JIT compile + first run
    wp.synchronize()
    best = float("inf")
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        wp.synchronize()                           # wait for the device before reading the clock
        best = min(best, time.perf_counter() - t0)
    return 1e3 * best


times = {"interleaved": best_ms(run_interleaved), "grouped": best_ms(run_grouped),
         "specialized": best_ms(run_specialized)}

# all three compute the same numbers (interleaved stores them in interleaved order)
a_back = out_a.numpy().reshape(M, 8).T.reshape(N)
print(f"device: {wp.get_device()} | N = {N} | {ITERS} iterations per element")
for k, v in times.items():
    print(f"  {k:12s} {v:8.2f} ms   ({v / times['grouped']:.2f}x grouped)")
print("same results in all three:",
      bool(np.array_equal(out_b.numpy(), out_c.numpy()) and np.array_equal(a_back, out_b.numpy())))
if not ON_GPU:
    print("CPU device: threads run in a loop, no 32-lane warps, so no divergence penalty.")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "n": N, "iters": ITERS,
                   "ms": {k: round(v, 2) for k, v in times.items()}}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
