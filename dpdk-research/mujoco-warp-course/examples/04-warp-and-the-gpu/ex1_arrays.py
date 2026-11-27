"""Example 4.1 - wp.array basics: dtype, shape, device, NumPy views of vector dtypes.

Creates float, vec3, quat, mat33 and spatial_vector arrays and prints their Warp shape next to
the shape of their NumPy copy (vector dtypes add trailing NumPy dims). Also shows the copy and
fill helpers MJWarp code uses all the time.
Run: python ex1_arrays.py
"""
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

np.set_printoptions(precision=4, suppress=True)

device = wp.get_device()            # "cuda:0" on Colab with a GPU, "cpu" otherwise
print("default device:", device, "| is_cuda:", device.is_cuda)

# 1. scalar arrays: zeros / ones / empty / from NumPy
a = wp.zeros(4, dtype=float)                       # float means float32 in Warp
b = wp.array(np.arange(4, dtype=np.float32))       # copies host -> device
print("a:", a.shape, a.dtype.__name__, a.device, "| b.numpy():", b.numpy())

# 2. vector and matrix dtypes: the Warp shape counts elements, NumPy adds the trailing dims
arrays = {
    "vec3": wp.zeros(4, dtype=wp.vec3),
    "quat": wp.zeros(4, dtype=wp.quat),
    "mat33": wp.zeros(4, dtype=wp.mat33),
    "spatial_vector": wp.zeros(4, dtype=wp.spatial_vector),
    "vec3 2d (nworld=2, nbody=3)": wp.zeros((2, 3), dtype=wp.vec3),
}
for name, arr in arrays.items():
    print(f"{name:28s} warp shape {str(arr.shape):8s} numpy shape {arr.numpy().shape}")

# 3. NumPy (N, 3) -> vec3 array: the last NumPy dim is absorbed into the dtype
pts = wp.array(np.array([[1, 2, 3], [4, 5, 6]], dtype=np.float32), dtype=wp.vec3)
print("vec3 from (2, 3) numpy:", pts.shape, "first element:", pts.numpy()[0])

# 4. in-place helpers: assign (copy from host), fill_, zero_, wp.copy (device -> device)
a.assign(np.array([10, 20, 30, 40], dtype=np.float32))
c = wp.empty_like(a)                               # empty: contents undefined until written
wp.copy(c, a)
a.fill_(7.0)
print("after assign+copy+fill_: a =", a.numpy(), "c =", c.numpy())
c.zero_()
print("after c.zero_():", c.numpy())

# 5. .numpy() on a CUDA array waits for the GPU and copies to the host; on the CPU device it
#    returns a view that shares memory with the Warp array. Never rely on either side effect.
host = b.numpy()
host[0] = 99.0
kind = "copy (device unchanged)" if b.device.is_cuda else "view (CPU arrays share memory)"
print(f"b after editing its .numpy() result: {b.numpy()} -> {kind}")

# 6. choose the device explicitly (cpu always exists)
with wp.ScopedDevice("cpu"):
    on_cpu = wp.ones(3, dtype=wp.vec3)
print("ScopedDevice('cpu'):", on_cpu.device, on_cpu.numpy().shape)
