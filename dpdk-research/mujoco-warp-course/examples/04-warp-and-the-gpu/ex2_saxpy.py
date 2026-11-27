"""Example 4.2 - first kernel: y = a * x + y on 1M elements (SAXPY).

One thread per element. Compares the result with NumPy.
Run: python ex2_saxpy.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

np.set_printoptions(precision=4, suppress=True)

N = 1 << 20                                        # 1,048,576 elements (same on CPU and GPU)


@wp.kernel
def saxpy(a: float, x: wp.array[float], y: wp.array[float]):
    i = wp.tid()                                   # this thread's index, 0 .. N-1
    y[i] = a * x[i] + y[i]


rng = np.random.default_rng(0)
x_np = rng.standard_normal(N).astype(np.float32)
y_np = rng.standard_normal(N).astype(np.float32)

x = wp.array(x_np)
y = wp.array(y_np)
wp.launch(saxpy, dim=N, inputs=[2.0, x], outputs=[y])   # first launch compiles (JIT)

y_out = y.numpy()                                  # .numpy() waits for the device, then copies
ref = 2.0 * x_np + y_np
print("device:", wp.get_device(), "| N =", N)
print("first 3 values:", y_out[:3])
print("NumPy reference:", ref[:3])
print("max abs error:", float(np.max(np.abs(y_out - ref))))

wp.launch(saxpy, dim=0, inputs=[2.0, x], outputs=[y])   # dim=0 is a safe no-op
print("dim=0 launch ok, y unchanged:", bool(np.array_equal(y.numpy(), y_out)))
