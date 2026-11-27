"""Example 28.6 - a jax.jit-compiled control loop around the MJWarp op, rewards computed in JAX.

CARTPOLE with a linear policy written in JAX: every scan step reads the state that the
jax_callable returned, computes ctrl in JAX, calls the Warp op (ctrl, qpos, qvel in -> qpos,
qvel out) and adds a reward. The whole rollout is one compiled XLA program. There are no
gradients: jax.grad through the Warp op raises, because the FFI call has no JVP/VJP (and a
custom_vjp would need backward rules that MJWarp 4.0.1 does not provide, Ch 29). The last lines
print that error.
GPU: graph_mode WARP. CPU fallback: graph_mode NONE (see Example 28.5).
Run: python ex6_jax_grad_free_loop.py [--dump-json PATH]
  --dump-json PATH writes the per-step reward of every world (decimated) for the page's chart.
"""
import os

os.environ["XLA_FLAGS"] = "--xla_gpu_graph_min_graph_size=1"
os.environ["XLA_PYTHON_CLIENT_ALLOCATOR"] = "platform"
os.environ["XLA_PYTHON_CLIENT_PREALLOCATE"] = "false"

import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

try:
    import jax
    from jax import numpy as jp
except ImportError:
    jax = None
    print("skipped: jax not installed")

CARTPOLE = """
<mujoco model="cartpole">
  <option timestep="0.01" integrator="implicitfast"/>
  <worldbody>
    <light pos="0 -2 3" dir="0 1 -1"/>
    <camera name="front" pos="0 -4 1" xyaxes="1 0 0 0 0 1"/>
    <geom name="rail" type="capsule" fromto="-2 0 1 2 0 1" size=".02" contype="0" conaffinity="0"/>
    <body name="cart" pos="0 0 1">
      <joint name="slider" type="slide" axis="1 0 0" range="-1.8 1.8" limited="true" damping="0.1"/>
      <geom name="cart" type="box" size=".2 .1 .05" mass="1" contype="0" conaffinity="0"/>
      <body name="pole">
        <joint name="hinge" type="hinge" axis="0 1 0" damping="0.01"/>
        <geom name="pole" type="capsule" fromto="0 0 0 0 0 .6" size=".03" mass="0.1"
              contype="0" conaffinity="0"/>
      </body>
    </body>
  </worldbody>
  <actuator><motor name="push" joint="slider" gear="10" ctrlrange="-1 1" ctrllimited="true"/></actuator>
  <sensor>
    <jointpos joint="slider"/><jointpos joint="hinge"/>
    <jointvel joint="slider"/><jointvel joint="hinge"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 200

if jax is not None and (jax.default_backend() == "gpu") != ON_GPU:
    print(f"skipped: JAX backend {jax.default_backend()} but Warp device {wp.get_device()}")
    jax = None

if jax is not None:
    mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
    m = mjw.put_model(mjm)
    m.opt.graph_conditional = ON_GPU and wp.is_conditional_graph_supported()
    d = mjw.make_data(mjm, nworld=NWORLD)

    def warp_step(
        ctrl_in: wp.array2d[wp.float32],
        qpos_in: wp.array2d[wp.float32],
        qvel_in: wp.array2d[wp.float32],
        qpos_out: wp.array2d[wp.float32],
        qvel_out: wp.array2d[wp.float32],
    ):
        wp.copy(d.ctrl, ctrl_in)
        wp.copy(d.qpos, qpos_in)
        wp.copy(d.qvel, qvel_in)
        mjw.step(m, d)
        wp.copy(qpos_out, d.qpos)
        wp.copy(qvel_out, d.qvel)

    mode = wp.JaxCallableGraphMode.WARP if ON_GPU else wp.JaxCallableGraphMode.NONE
    step_fn = wp.jax_callable(
        warp_step, num_outputs=2, graph_mode=mode,
        output_dims={"qpos_out": (NWORLD, mjm.nq), "qvel_out": (NWORLD, mjm.nv)})

    K = jp.array([0.9, 6.8, 1.1, 1.2])          # LQR gains, as in Example 28.3
    gain = jp.linspace(0.0, 1.0, NWORLD)          # world k uses gain[k] * K

    def rollout(qpos, qvel, gain):
        def body(carry, _):
            qpos, qvel, ret = carry
            obs = jp.concatenate([qpos, qvel], axis=1)              # (nworld, 4)
            ctrl = jp.clip((obs @ K) * gain, -1.0, 1.0)[:, None]    # policy in JAX
            qpos, qvel = step_fn(ctrl, qpos, qvel)                 # MJWarp step
            x, th = qpos[:, 0], qpos[:, 1]
            reward = jp.cos(th) - 0.1 * x**2 - 0.001 * ctrl[:, 0] ** 2  # reward in JAX
            return (qpos, qvel, ret + reward), reward   # carry, per-step output

        (qpos, qvel, ret), rewards = jax.lax.scan(
            body, (qpos, qvel, jp.zeros(NWORLD)), length=NSTEP)
        return ret / NSTEP, rewards                   # rewards: (NSTEP, NWORLD)

    qpos0 = jp.tile(jp.array([0.0, 0.2]), (NWORLD, 1))   # pole tilted 0.2 rad
    qvel0 = jp.zeros((NWORLD, mjm.nv))
    fn = jax.jit(rollout)
    avg_reward, rewards = jax.block_until_ready(fn(qpos0, qvel0, gain))

    r = np.asarray(avg_reward)
    print("backend:", jax.default_backend(), "| graph_mode:", mode.name, "| nworld:", NWORLD,
          "| steps:", NSTEP)
    print("gain scale:     ", np.asarray(gain)[:8])
    print("average reward: ", r[:8])
    print(f"best world: {int(r.argmax())} (gain {float(gain[r.argmax()]):.3f}), "
          f"reward {r.max():.3f}; worst: {r.min():.3f}")

    try:  # no gradients through the Warp op
        jax.grad(lambda g: fn(qpos0, qvel0, g)[0].sum())(gain)
    except Exception as e:
        print("jax.grad ->", type(e).__name__ + ":", str(e).splitlines()[0])

    if args.dump_json:
        rw = np.asarray(rewards)[::4, :8]  # every 4th step, first 8 worlds
        with open(args.dump_json, "w") as f:
            json.dump({"dt": 4 * float(mjm.opt.timestep),
                       "gain": np.asarray(gain)[:8].round(3).tolist(),
                       "avg": r[:8].round(3).tolist(), "frames": rw.round(3).tolist()},
                      f, separators=(",", ":"))
        print("wrote", args.dump_json, len(rw), "frames")
