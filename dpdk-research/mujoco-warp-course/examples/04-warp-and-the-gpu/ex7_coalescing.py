"""Example 4.7 - memory coalescing: which index do consecutive threads walk?

Adds two (nworld, n) arrays. Both kernels do identical work; only the mapping from thread
index to array element differs:
  coalesced  w, j = wp.tid() with dim=(nworld, n): neighbouring threads read neighbouring
             addresses (the contiguous last axis) -> a GPU warp needs few memory transactions
  strided    j, w = wp.tid() with dim=(n, nworld): neighbouring threads are a whole row
             (n * 4 bytes) apart -> one transaction per lane
This is why MJWarp puts nworld first and launches dim=(nworld, n_elements).
On the CPU device threads run in order, so the strided kernel jumps n * 4 bytes per thread
and loses the CPU cache instead: it is slower too, for a different reason.
Run: python ex7_coalescing.py [--dump-json PATH]
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
NWORLD, N = (8192, 4096) if ON_GPU else (2048, 2048)


@wp.kernel
def add_coalesced(a: wp.array2d[float], b: wp.array2d[float], c: wp.array2d[float]):
    w, j = wp.tid()                                # last launch axis = contiguous array axis
    c[w, j] = a[w, j] + b[w, j]


@wp.kernel
def add_strided(a: wp.array2d[float], b: wp.array2d[float], c: wp.array2d[float]):
    j, w = wp.tid()                                # last launch axis = the row index
    c[w, j] = a[w, j] + b[w, j]


rng = np.random.default_rng(0)
a = wp.array(rng.random((NWORLD, N), dtype=np.float32))
b = wp.array(rng.random((NWORLD, N), dtype=np.float32))
c1 = wp.zeros((NWORLD, N), dtype=float)
c2 = wp.zeros((NWORLD, N), dtype=float)


def best_ms(fn, reps=5):
    fn()                                           # warm-up (JIT)
    wp.synchronize()
    best = float("inf")
    for _ in range(reps):
        t0 = time.perf_counter()
        fn()
        wp.synchronize()
        best = min(best, time.perf_counter() - t0)
    return 1e3 * best


t_co = best_ms(lambda: wp.launch(add_coalesced, dim=(NWORLD, N), inputs=[a, b], outputs=[c1]))
t_st = best_ms(lambda: wp.launch(add_strided, dim=(N, NWORLD), inputs=[a, b], outputs=[c2]))
gbytes = 3 * NWORLD * N * 4 / 1e9                  # 2 reads + 1 write of float32

print(f"device: {wp.get_device()} | array ({NWORLD}, {N}) float32, {gbytes:.3f} GB moved")
print(f"  coalesced {t_co:8.2f} ms  {gbytes / (t_co / 1e3):7.1f} GB/s")
print(f"  strided   {t_st:8.2f} ms  {gbytes / (t_st / 1e3):7.1f} GB/s"
      f"   ({t_st / t_co:.1f}x slower)")
print("same result:", bool(np.array_equal(c1.numpy(), c2.numpy())))
print("thread k reads address offset (floats): coalesced k, strided k *", N)
if not ON_GPU:
    print("CPU device: the gap comes from CPU caches, not from GPU memory transactions.")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"device": str(wp.get_device()), "shape": [NWORLD, N],
                   "ms": {"coalesced": round(t_co, 2), "strided": round(t_st, 2)}},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
