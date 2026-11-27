"""Example 4.10 - timing device code: launches are asynchronous on a GPU.

wp.launch on a CUDA device only queues the kernel and returns at once. A timer that stops
right after the launch measures Python, not the GPU. Call wp.synchronize() (or use
wp.ScopedTimer(..., synchronize=True)) before reading the clock. On Warp's CPU device the
launch runs the kernel before returning, so both numbers are close.
Run: python ex10_timing.py
"""
import time

import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

ON_GPU = wp.get_device().is_cuda
N = (1 << 24) if ON_GPU else (1 << 16)
ITERS = 200


@wp.kernel
def busy(x: wp.array[float], y: wp.array[float]):
    i = wp.tid()
    v = x[i]
    for _ in range(ITERS):
        v = wp.sin(v) * 0.99 + 0.01
    y[i] = v


x = wp.array(np.random.default_rng(0).random(N, dtype=np.float32))
y = wp.zeros(N, dtype=float)
wp.launch(busy, dim=N, inputs=[x], outputs=[y])    # warm-up: compile + load the module
wp.synchronize()

t0 = time.perf_counter()
wp.launch(busy, dim=N, inputs=[x], outputs=[y])
t_no_sync = time.perf_counter() - t0               # WRONG on GPU: kernel may still be running
wp.synchronize()

t0 = time.perf_counter()
wp.launch(busy, dim=N, inputs=[x], outputs=[y])
wp.synchronize()                                   # wait until the device is idle
t_sync = time.perf_counter() - t0

with wp.ScopedTimer("busy", synchronize=True, print=False) as timer:
    wp.launch(busy, dim=N, inputs=[x], outputs=[y])

print(f"device: {wp.get_device()} | N = {N} | {ITERS} sin() per element")
print(f"  stop clock right after wp.launch : {1e3 * t_no_sync:8.2f} ms")
print(f"  stop clock after wp.synchronize(): {1e3 * t_sync:8.2f} ms")
print(f"  wp.ScopedTimer(synchronize=True) : {timer.elapsed:8.2f} ms")
if ON_GPU:
    print("GPU: the first number is only the cost of queueing the launch.")
else:
    print("CPU device: launches run synchronously, so the numbers are close.")
