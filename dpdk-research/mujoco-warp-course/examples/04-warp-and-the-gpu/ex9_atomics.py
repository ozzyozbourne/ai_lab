"""Example 4.9 - wp.atomic_add, and why a float sum depends on the order of additions.

1M float32 values are summed by 1M threads into one accumulator with wp.atomic_add. Float
addition is not associative, so the result depends on the order in which threads arrive:
on a GPU that order changes from run to run (low bits flicker); on Warp's CPU device threads
run in index order, so the two runs match. A tiny 8-number case shows order dependence exactly.
Full treatment of determinism: Ch 22.
Run: python ex9_atomics.py
"""
import itertools

import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

N = 1 << 20


@wp.kernel
def atomic_sum(x: wp.array[float], total: wp.array[float]):
    i = wp.tid()
    wp.atomic_add(total, 0, x[i])                  # read-modify-write, no lost updates


x_np = np.random.default_rng(0).random(N, dtype=np.float32)
x = wp.array(x_np)
runs = []
for _ in range(2):
    total = wp.zeros(1, dtype=float)
    wp.launch(atomic_sum, dim=N, inputs=[x], outputs=[total])
    runs.append(float(total.numpy()[0]))

exact = float(np.sum(x_np, dtype=np.float64))
pairwise = float(np.sum(x_np))                     # NumPy float32 uses pairwise summation
print(f"device: {wp.get_device()} | N = {N}")
print(f"float64 sum (reference)  : {exact:.4f}")
print(f"NumPy float32 (pairwise) : {pairwise:.4f}   error {pairwise - exact:+.4f}")
print(f"atomic_add run 1         : {runs[0]:.4f}   error {runs[0] - exact:+.4f}")
print(f"atomic_add run 2         : {runs[1]:.4f}   bitwise equal to run 1: {runs[0] == runs[1]}")

# the same 8 float32 numbers added in every possible order (40320 orders)
vals = np.array([1e8, 3.0, -1e8, 0.75, 7.0, 0.125, -5.0, 2.5], dtype=np.float32)
results = set()
for perm in itertools.permutations(range(8)):
    acc = np.float32(0.0)
    for k in perm:
        acc = np.float32(acc + vals[k])
    results.add(float(acc))
print("8 values:", vals.tolist())
print("exact sum: 8.375 | distinct float32 results over all 40320 orders:", len(results))
print("smallest / largest:", min(results), "/", max(results))
