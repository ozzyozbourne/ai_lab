"""Example 28.8 - the custom_vmap pattern (Apollo notebook): many per-env calls, one Warp call.

RL libraries such as Brax write the env step for ONE environment and jax.vmap it over the batch.
A Warp op with fixed output_dims cannot be vmapped like a jnp function, so the Apollo notebook
(contrib/apptronik_apollo_locomotion.ipynb) wraps the per-env step in
jax.custom_batching.custom_vmap: the vmap rule receives the whole batch and calls the batched
MJWarp op once. This example counts how often the Python Warp function runs:
  * loop: NLOOP (at most 8) separate calls of a 1-world op;   * vmap: one call of the NWORLD-world op.
wp.jax_callable has vmap_method="broadcast_all", but that folds the batch into each array's first
dim, which a function closing over a fixed-size mjw.Data cannot accept; hence custom_vmap.
The loop is capped: on a GPU in WARP mode the graph-cache key is (device, call_id, buffer
addresses), and every eager Python call gets a new call_id, so each one misses the cache and
captures a new CUDA graph of mjw.step. A jitted function traces once and keeps one call_id.
Runs on JAX CPU (graph_mode NONE) or GPU (WARP); skips without JAX.
Run: python ex8_custom_vmap.py
"""
import os

os.environ["XLA_FLAGS"] = "--xla_gpu_graph_min_graph_size=1"
os.environ["XLA_PYTHON_CLIENT_ALLOCATOR"] = "platform"
os.environ["XLA_PYTHON_CLIENT_PREALLOCATE"] = "false"

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

try:
    import jax
    from jax import numpy as jp
except ImportError:
    jax = None
    print("skipped: jax not installed")

PENDULUM = """
<mujoco model="double_pendulum">
  <option timestep="0.01"><flag energy="enable"/></option>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="side" pos="0 -3 1" xyaxes="1 0 0 0 0 1"/>
    <body name="link1" pos="0 0 1.5">
      <joint name="hinge1" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
      <body name="link2" pos="0 0 -.5">
        <joint name="hinge2" type="hinge" axis="0 1 0"/>
        <geom type="capsule" fromto="0 0 0 0 0 -.5" size=".04" mass="1"/>
        <site name="tip" pos="0 0 -.5"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="shoulder" joint="hinge1" gear="1" ctrlrange="-5 5"/></actuator>
  <sensor>
    <jointpos name="q1" joint="hinge1"/>
    <jointvel name="v1" joint="hinge1"/>
    <framepos name="tip_pos" objtype="site" objname="tip"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 8192 if ON_GPU else 8
NLOOP = min(NWORLD, 8)  # per-env eager calls to compare (each gets a new call_id: a new capture on GPU)

if jax is not None and (jax.default_backend() == "gpu") != ON_GPU:
    print(f"skipped: JAX backend {jax.default_backend()} but Warp device {wp.get_device()}")
    jax = None

if jax is not None:
    mjm = mujoco.MjModel.from_xml_string(PENDULUM)
    m = mjw.put_model(mjm)
    m.opt.graph_conditional = ON_GPU and wp.is_conditional_graph_supported()
    mode = wp.JaxCallableGraphMode.WARP if ON_GPU else wp.JaxCallableGraphMode.NONE
    calls = {"n": 0}

    def make_op(nworld):
        """A jax op stepping `nworld` worlds: (ctrl, qpos, qvel) -> (qpos, qvel)."""
        d = mjw.make_data(mjm, nworld=nworld)

        def warp_step(ctrl_in: wp.array2d[wp.float32], qpos_in: wp.array2d[wp.float32],
                      qvel_in: wp.array2d[wp.float32], qpos_out: wp.array2d[wp.float32],
                      qvel_out: wp.array2d[wp.float32]):
            calls["n"] += 1  # Python side: runs once per FFI execution without graph replay
            wp.copy(d.ctrl, ctrl_in)
            wp.copy(d.qpos, qpos_in)
            wp.copy(d.qvel, qvel_in)
            mjw.step(m, d)
            wp.copy(qpos_out, d.qpos)
            wp.copy(qvel_out, d.qvel)

        return wp.jax_callable(warp_step, num_outputs=2, graph_mode=mode,
                               output_dims={"qpos_out": (nworld, mjm.nq),
                                            "qvel_out": (nworld, mjm.nv)})

    op1, opN = make_op(1), make_op(NWORLD)

    # The per-env step an RL library wants to vmap: shapes (nu,), (nq,), (nv,).
    @jax.custom_batching.custom_vmap
    def env_step(ctrl, qpos, qvel):
        qpos, qvel = op1(ctrl[None], qpos[None], qvel[None])  # unbatched call: 1 world
        return qpos[0], qvel[0]

    @env_step.def_vmap
    def env_step_vmap(axis_size, in_batched, ctrl, qpos, qvel):
        assert axis_size == NWORLD, "the Warp op is built for a fixed NWORLD"
        ctrl, qpos, qvel = (x if b else jp.tile(x, (axis_size, 1))  # tile unbatched inputs
                            for x, b in zip((ctrl, qpos, qvel), in_batched))
        qpos, qvel = opN(ctrl, qpos, qvel)                     # ONE batched MJWarp call
        return (qpos, qvel), (True, True)                      # both outputs are batched

    ctrl = jp.linspace(-1.0, 1.0, NWORLD)[:, None]            # a different torque per env
    qpos = jp.tile(jp.array(mjm.key_qpos[0]), (NWORLD, 1))
    qvel = jp.zeros((NWORLD, mjm.nv))

    calls["n"] = 0
    loop = [env_step(ctrl[i], qpos[i], qvel[i]) for i in range(NLOOP)]
    jax.block_until_ready(loop)
    n_loop = calls["n"]
    q_loop = np.stack([np.asarray(q) for q, _ in loop])

    calls["n"] = 0
    q_vmap, _ = jax.block_until_ready(jax.jit(jax.vmap(env_step))(ctrl, qpos, qvel))
    n_vmap = calls["n"]

    print("backend:", jax.default_backend(), "| graph_mode:", mode.name, "| envs:", NWORLD)
    print(f"python loop over the first {NLOOP} envs: {n_loop} Warp calls of a 1-world op")
    print(f"jax.vmap + custom_vmap: {n_vmap} Warp call of the {NWORLD}-world op")
    print("hinge1 after one step, loop:", q_loop[:4, 0])
    print("hinge1 after one step, vmap:", np.asarray(q_vmap)[:4, 0])
    print("max |loop - vmap| over those envs:",
          float(np.abs(q_loop - np.asarray(q_vmap)[:NLOOP]).max()))
