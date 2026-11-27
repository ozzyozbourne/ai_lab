# Notebook spec for Chapter 4. Build with:
#   python3 tools/make_notebook.py notebooks/specs/04-warp-and-the-gpu.py
SLUG = "04-warp-and-the-gpu"
TITLE = "Ch 04 · NVIDIA Warp and How a GPU Runs Your Kernel"

EX41_STUB = '''import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING


@wp.kernel
def clamp_ctrl(ctrl: wp.array2d[float]):
    worldid, actid = wp.tid()
    # TODO: clamp ctrl[worldid, actid] to [-1, 1]


NWORLD, NU = 8, 3
ctrl_np = np.random.default_rng(0).normal(0.0, 2.0, (NWORLD, NU)).astype(np.float32)
ctrl = wp.array(ctrl_np)
wp.launch(clamp_ctrl, dim=(NWORLD, NU), inputs=[ctrl])
assert np.allclose(ctrl.numpy(), np.clip(ctrl_np, -1.0, 1.0))
print("Exercise 4.1 passed")'''

EX41_SOL = '''import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING


@wp.kernel
def clamp_ctrl(ctrl: wp.array2d[float]):
    worldid, actid = wp.tid()
    ctrl[worldid, actid] = wp.clamp(ctrl[worldid, actid], -1.0, 1.0)


NWORLD, NU = 8, 3
ctrl_np = np.random.default_rng(0).normal(0.0, 2.0, (NWORLD, NU)).astype(np.float32)
ctrl = wp.array(ctrl_np)
wp.launch(clamp_ctrl, dim=(NWORLD, NU), inputs=[ctrl])
assert np.allclose(ctrl.numpy(), np.clip(ctrl_np, -1.0, 1.0))
print("Exercise 4.1 passed")'''

EX42_STUB = '''import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING


@wp.kernel
def kinetic_energy(mass: wp.array[float], vel: wp.array2d[wp.vec3], ke_out: wp.array[float]):
    worldid = wp.tid()
    # TODO: loop over vel.shape[1] masses and write the sum to ke_out[worldid]


NWORLD, NP = 8, 5
rng = np.random.default_rng(1)
mass_np = rng.uniform(0.5, 2.0, NP).astype(np.float32)
vel_np = rng.normal(size=(NWORLD, NP, 3)).astype(np.float32)
ke = wp.zeros(NWORLD, dtype=float)
wp.launch(kinetic_energy, dim=NWORLD,
          inputs=[wp.array(mass_np), wp.array(vel_np, dtype=wp.vec3)], outputs=[ke])
ref = 0.5 * np.sum(mass_np[None, :] * np.sum(vel_np**2, axis=2), axis=1)
assert np.allclose(ke.numpy(), ref, rtol=1e-5)
print("Exercise 4.2 passed")'''

EX42_SOL = EX42_STUB.replace(
    "    # TODO: loop over vel.shape[1] masses and write the sum to ke_out[worldid]",
    "    total = float(0.0)\n"
    "    for i in range(vel.shape[1]):\n"
    "        v = vel[worldid, i]\n"
    "        total += 0.5 * mass[i] * wp.dot(v, v)\n"
    "    ke_out[worldid] = total")

STRETCH_SOL = '''import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING

NW, TILE = 4, 64


@wp.kernel
def per_world_max(data: wp.array2d[float], out: wp.array[float]):
    worldid = wp.tid()
    t = wp.tile_load(data[worldid], shape=(TILE,))
    wp.tile_store(out, wp.tile_max(t), offset=(worldid,))


arr_np = np.random.default_rng(2).normal(size=(NW, TILE)).astype(np.float32)
out = wp.zeros(NW, dtype=float)
wp.launch_tiled(per_world_max, dim=[NW], inputs=[wp.array(arr_np)], outputs=[out], block_dim=32)
assert np.allclose(out.numpy(), arr_np.max(axis=1))
print("Stretch passed:", out.numpy())'''

GPU_VS_CPU = '''# Run the same scripts on the GPU and, in a fresh process with no visible GPU, on Warp's CPU device.
import os
import subprocess
import sys

if ON_GPU:
    for script in ["ex2_saxpy.py", "ex6_divergence.py", "ex7_coalescing.py"]:
        for label, extra in [("GPU", {}), ("CPU device", {"CUDA_VISIBLE_DEVICES": ""})]:
            res = subprocess.run([sys.executable, script], env={**os.environ, **extra},
                                 capture_output=True, text=True)
            print(f"--- {script} on {label} (own problem size, see first line; compare ratios, not ms)")
            print(res.stdout.strip() or res.stderr.strip()[-500:])
else:
    print("skipped on CPU: this comparison needs a GPU runtime (the scripts above already ran on CPU)")'''

CELLS = [
    ["md", "## 1. Devices and 2. arrays\n"
           "Warp arrays have a dtype, a shape and a device. Vector dtypes (`wp.vec3`, `wp.quat`, `wp.mat33`, "
           "`wp.spatial_vector`) count as one element in the Warp shape and add trailing dims in NumPy. "
           "`.numpy()` on a GPU array waits for the GPU and copies; on the CPU device it is a view."],
    ["example", "ex1_arrays.py", "4.1"],
    ["md", "## 3. Kernels and threads\n"
           "A `@wp.kernel` runs once per index of `dim`; `wp.tid()` returns the index. `dim=0` is a safe no-op."],
    ["example", "ex2_saxpy.py", "4.2"],
    ["md", "A 2-D launch `dim=(nworld, ndof)` returns two indices; the last one varies fastest. On the CPU device "
           "threads run in row-major order. On a GPU the order is not guaranteed; with only 24 threads (a single warp) it may still come out in order, so do not rely on either."],
    ["example", "ex3_grid_2d.py", "4.3"],
    ["md", "## 4. How a GPU runs your kernel\n"
           "Warps of 32 lanes run in lockstep. **Divergence:** when lanes of one warp take different branches, the "
           "warp runs both sides. On a GPU the interleaved variant is expected to be the slowest (check your own "
           "numbers below); on the CPU device the three times are close."],
    ["example", "ex6_divergence.py", "4.6"],
    ["md", "**Coalescing:** neighbouring threads should read neighbouring addresses. The strided kernel walks the "
           "row index fastest."],
    ["example", "ex7_coalescing.py", "4.7"],
    ["md", "### GPU vs CPU\nThe next cells write three of the scripts to disk and run each on the GPU and on Warp's "
           "CPU device (a subprocess with `CUDA_VISIBLE_DEVICES` empty). Numbers are yours; nothing is hard-coded. "
           "**The sizes differ per device**: each script picks its budget from the device it sees (ex6: "
           "N = 4,194,304 on the GPU vs 65,536 on the CPU; ex7: (8192, 4096) vs (2048, 2048); only ex2 uses "
           "the same N = 1,048,576 on both), and each run "
           "prints its size. So apart from ex2, do not compare milliseconds across devices; compare the ratios *within* each "
           "device (interleaved vs grouped, strided vs coalesced)."],
    ["writefile", "ex2_saxpy.py", "examples/04-warp-and-the-gpu/ex2_saxpy.py"],
    ["writefile", "ex6_divergence.py", "examples/04-warp-and-the-gpu/ex6_divergence.py"],
    ["writefile", "ex7_coalescing.py", "examples/04-warp-and-the-gpu/ex7_coalescing.py"],
    ["code", GPU_VS_CPU],
    ["md", "## 5. Device functions\n`@wp.func` helpers run on the device, can return values and are inlined. "
           "This example reuses MJWarp's private `math.rot_vec_quat` (the name may change between versions)."],
    ["example", "ex4_func.py", "4.4"],
    ["md", "## 6. The `wp.quat` storage pitfall\nMJWarp stores (w, x, y, z) in `wp.quat` slots; Warp's built-ins "
           "such as `wp.quat_rotate` read (x, y, z, w)."],
    ["example", "ex5_quat_pitfall.py", "4.5"],
    ["md", "## 7. Compile-time specialization: `wp.static`\nA kernel factory produces one specialized module per "
           "flag value."],
    ["example", "ex8_static.py", "4.8"],
    ["md", "## 8. JIT compilation and the kernel cache\nThe only cell in the course that turns Warp's INFO log back "
           "on. In a notebook Warp was initialized by the setup cell, so no banner is captured; on a fresh Colab "
           "runtime the module lines say `(compiled)`, rerun the cell after a restart to see `(cached)`."],
    ["example", "ex12_jit_log.py", "4.12"],
    ["md", "## 9. Atomics and order-dependent sums\nOn the GPU, run the cell twice: the atomic totals can differ in "
           "their last digits."],
    ["example", "ex9_atomics.py", "4.9"],
    ["md", "## 10. Timing\nLaunches are asynchronous on a GPU: stop the clock only after `wp.synchronize()`."],
    ["example", "ex10_timing.py", "4.10"],
    ["md", "## 11. Going deeper: tiles preview\n`wp.launch_tiled` gives each logical index a block of threads that "
           "cooperate on tiles (owner chapter: Ch 26)."],
    ["example", "ex11_tile_sum.py", "4.11"],
    ["md", "## Exercise 4.1: clamp a batched control array\nFill in the kernel so the assert passes."],
    ["code", EX41_STUB],
    ["solution", EX41_SOL, "Exercise 4.1"],
    ["md", "## Exercise 4.2: per-world kinetic energy of point masses\nOne thread per world sums "
           "0.5 * m_i * |v_i|^2. Type the accumulator (`total = float(0.0)`)."],
    ["code", EX42_STUB],
    ["solution", EX42_SOL, "Exercise 4.2"],
    ["md", "## Stretch: a tiled per-world maximum\nChange Example 4.11 to compute each world's maximum. Then, on the "
           "GPU, time it against a one-thread-per-world loop for NW = 4096 and rows of 64 and 1024 floats."],
    ["code", "# your code here"],
    ["solution", STRETCH_SOL, "Stretch"],
]
