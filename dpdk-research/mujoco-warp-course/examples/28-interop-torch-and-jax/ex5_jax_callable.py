"""Example 28.5 - mjw.step as a JAX op: the corrected course version of contrib/jax_unroll.py.

Fixes the three stale lines of contrib/jax_unroll.py (Example 28.7 finds them):
  * the model comes from the wheel, mujoco_warp/test_data/humanoid/humanoid.xml
    (the repo's '../benchmark' path is wrong, and benchmarks/ is not in the wheel);
  * nconmax is PER WORLD in mujoco-warp 4.0.1 (naconmax is the total), so 64, not 64 * NWORLD;
  * no wp.clear_kernel_cache() at import (it throws away every compiled kernel).
It follows _src/jax_test.py: XLA env vars before `import jax`, an explicit
m.opt.graph_conditional, a closure over m and d that copies in, steps and copies out, wrapped by
wp.jax_callable(..., graph_mode=wp.JaxCallableGraphMode.WARP, output_dims=...), unrolled with
jax.lax.scan inside jax.jit. NWORLD is fixed: output_dims bakes it into the op.
GPU (Colab): needs jax.default_backend() == "gpu" and a CUDA Warp device.
CPU fallback: Warp 1.19 also runs jax_callable on the JAX CPU backend with graph_mode NONE
(WARP graph modes need CUDA). Skips if JAX is not installed or the two disagree on the device.
Run: python ex5_jax_callable.py
"""
import os

os.environ["XLA_FLAGS"] = "--xla_gpu_graph_min_graph_size=1"   # all three BEFORE import jax
os.environ["XLA_PYTHON_CLIENT_ALLOCATOR"] = "platform"
os.environ["XLA_PYTHON_CLIENT_PREALLOCATE"] = "false"

import time

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from etils import epath

np.set_printoptions(precision=4, suppress=True)

try:
    import jax
    from jax import numpy as jp
except ImportError:
    jax = None
    print("skipped: jax not installed")

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
UNROLL_LENGTH = 1000 if ON_GPU else 20

if jax is not None:
    JAX_GPU = jax.default_backend() == "gpu"
    if JAX_GPU != ON_GPU:
        print(f"skipped: JAX backend {jax.default_backend()} but Warp device {wp.get_device()}")
        jax = None

if jax is not None:
    GRAPH_MODE = wp.JaxCallableGraphMode.WARP if ON_GPU else wp.JaxCallableGraphMode.NONE

    path = epath.resource_path("mujoco_warp") / "test_data/humanoid/humanoid.xml"  # fix 1
    mjm = mujoco.MjModel.from_xml_path(path.as_posix())
    mjm.opt.iterations = 1
    mjm.opt.ls_iterations = 4
    mjd = mujoco.MjData(mjm)
    mjd.qvel = np.random.default_rng(0).uniform(-0.01, 0.01, mjm.nv)  # a small kick
    mujoco.mj_step(mjm, mjd, 3)
    mujoco.mj_forward(mjm, mjd)

    m = mjw.put_model(mjm)
    # explicit, as in jax_test.py: conditional graph nodes only with CUDA >= 12.4 (Ch 24)
    m.opt.graph_conditional = ON_GPU and wp.is_conditional_graph_supported()
    d = mjw.put_data(mjm, mjd, nworld=NWORLD, nconmax=64, njmax=128)  # fix 2: per world

    def warp_step(
        qpos_in: wp.array2d[wp.float32],
        qvel_in: wp.array2d[wp.float32],
        qpos_out: wp.array2d[wp.float32],
        qvel_out: wp.array2d[wp.float32],
    ):
        wp.copy(d.qpos, qpos_in)    # copy IN: JAX owns qpos_in, d keeps its own buffers
        wp.copy(d.qvel, qvel_in)
        mjw.step(m, d)
        wp.copy(qpos_out, d.qpos)   # copy OUT into the buffers JAX allocated
        wp.copy(qvel_out, d.qvel)

    warp_step_fn = wp.jax_callable(
        warp_step,
        num_outputs=2,
        graph_mode=GRAPH_MODE,
        output_dims={"qpos_out": (NWORLD, mjm.nq), "qvel_out": (NWORLD, mjm.nv)},
    )

    def unroll(qpos, qvel):
        def step(carry, _):
            qpos, qvel = carry
            qpos, qvel = warp_step_fn(qpos, qvel)  # returns a list: unpack it
            return (qpos, qvel), None

        (qpos, qvel), _ = jax.lax.scan(step, (qpos, qvel), length=UNROLL_LENGTH)
        return qpos, qvel

    jax_qpos = jp.tile(jp.array(d.qpos.numpy()[0]), (NWORLD, 1))
    jax_qvel = jp.tile(jp.array(d.qvel.numpy()[0]), (NWORLD, 1))

    jax_unroll_fn = jax.jit(unroll).lower(jax_qpos, jax_qvel).compile()
    jax.block_until_ready(jax_unroll_fn(jax_qpos, jax_qvel))  # warm up (JIT, graph capture)

    beg = time.perf_counter()
    final_qpos, final_qvel = jax_unroll_fn(jax_qpos, jax_qvel)
    jax.block_until_ready((final_qpos, final_qvel))
    run_time = time.perf_counter() - beg

    qpos = np.asarray(final_qpos)
    print("jax", jax.__version__, "| backend:", jax.default_backend(), "| warp device:",
          wp.get_device(), "| graph_mode:", GRAPH_MODE.name,
          "| graph_conditional:", m.opt.graph_conditional)
    print("nworld:", NWORLD, "| unroll:", UNROLL_LENGTH, "| naconmax:", d.naconmax,
          "(= nconmax 64 x nworld)")
    print("final qpos:", qpos.shape, type(final_qpos).__name__, "| all finite:",
          bool(np.isfinite(qpos).all()))
    print("root height z per world:", qpos[:4, 2])
    print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
    label = "GPU" if ON_GPU else "CPU dev box, not a GPU number"
    print(f"steps per second ({label}): {NWORLD * UNROLL_LENGTH / run_time:,.0f}")
