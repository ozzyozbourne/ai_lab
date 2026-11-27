"""Example 28.4 - the three XLA environment variables, set BEFORE the first `import jax`.

XLA reads these once, when its backend starts (the first jax computation or jax.devices() call);
later changes are ignored. Setting them before `import jax` is the one placement that is always
early enough:
  XLA_FLAGS=--xla_gpu_graph_min_graph_size=1  lets XLA capture one-op regions in its own CUDA
                                              graphs; for the Warp call that matters only in
                                              graph_mode=JAX (the Apollo notebook, which keeps
                                              the default); in WARP mode Warp captures the
                                              graph itself and the flag is harmless; set by
                                              jax_test.py, jax_unroll.py and Apollo
  XLA_PYTHON_CLIENT_ALLOCATOR=platform        allocate on demand, free when done (jax_test.py)
  XLA_PYTHON_CLIENT_PREALLOCATE=false         do not grab most of the GPU memory at start-up
Without the last two, JAX preallocates a large fraction of GPU memory and Warp (MJWarp's
buffers) can run out. Uses the installed JAX (on Colab: the preinstalled one); skips without it.
Then: wp.to_jax(d.qpos) is a zero-copy DLPack view, so the "immutable" jax.Array changes when
MJWarp steps. That is why the bridge in Example 28.5 copies in and out instead.
Run: python ex4_jax_env_flags.py
"""
import os
import sys

XLA_ENV = {
    "XLA_FLAGS": "--xla_gpu_graph_min_graph_size=1",
    "XLA_PYTHON_CLIENT_ALLOCATOR": "platform",
    "XLA_PYTHON_CLIENT_PREALLOCATE": "false",
}
already = "jax" in sys.modules  # True if something imported jax earlier in this process
for k, v in XLA_ENV.items():
    os.environ[k] = v
    print(f"{k}={os.environ[k]}")
if already:
    print("WARNING: jax was imported before these were set; restart the runtime to apply them")

try:
    import jax
except ImportError:
    jax = None
    print("skipped: jax not installed")

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

BALL_DROP = """
<mujoco model="ball_drop">
  <option timestep="0.002"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1" rgba=".8 .8 .8 1"/>
    <body name="ball" pos="0 0 1">
      <freejoint/>
      <geom name="ball" type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

if jax is not None:
    print("jax", jax.__version__, "| default backend:", jax.default_backend(),
          "| devices:", jax.devices())
    print("warp", wp.__version__, "| warp device:", wp.get_device())
    same = (jax.default_backend() == "gpu") == wp.get_device().is_cuda
    print("JAX and Warp on the same kind of device:", same)
    if jax.default_backend() != "gpu":
        print("note: the GPU examples (WARP graph mode) need jax.default_backend() == 'gpu';"
              " Examples 28.5-28.6 fall back to the CPU path")

    mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
    m = mjw.put_model(mjm)
    d = mjw.make_data(mjm, nworld=2, nconmax=4, njmax=16)
    jq = wp.to_jax(d.qpos)                       # DLPack: no copy
    z_before = np.asarray(jq[:, 2]).copy()
    for _ in range(100):
        mjw.step(m, d)
    wp.synchronize()
    print("wp.to_jax(d.qpos):", type(jq).__name__, jq.shape, jq.dtype)
    print("z read before steps:", z_before,
          "| same jax.Array after 100 steps:", np.asarray(jq[:, 2]))
    del jq  # release the DLPack view while Warp is still loaded (avoids a noisy exit)
