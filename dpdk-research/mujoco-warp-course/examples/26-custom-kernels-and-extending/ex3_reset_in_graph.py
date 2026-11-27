"""Example 26.3 - step + done kernel + masked reset + re-randomization, all in ONE graph.

Ch 8 built the done-kernel auto-reset; Ch 24 built my_env.capture_step. Here they meet: every
replay of the graph runs mjw.step, counts the episode's steps in d.userdata[:, 0], decides
`done` on the device (pole fell, cart left the rail, or 60-step timeout), resets the done worlds
with my_env.reset_done (reset_data with a bool mask + forward) and draws a new random pole angle
for them. reset_data zeroes ctrl, qvel, act, userdata and sensordata and restores qpos to qpos0, so the
per-world push is written again after the reset by a small kernel. Nothing is read back to the host inside the loop.
Run: python ex3_reset_in_graph.py [--dump-json PATH]
  --dump-json PATH writes decimated pole angles and reset flags of 8 worlds (Rule D).
"""
import argparse
import json
import pathlib
import sys

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

HERE = pathlib.Path(__file__).parent if "__file__" in globals() else pathlib.Path.cwd()
sys.path.insert(0, str(HERE))
try:
    import my_env                           # notebook: written by the %%writefile cell
except ImportError:
    import my_env_step26 as my_env          # examples/26-custom-kernels-and-extending/

np.set_printoptions(precision=4, suppress=True)

# CARTPOLE (shared model M5) plus <size nuserdata="1"/> for the per-episode step counter
CARTPOLE_UD = """
<mujoco model="cartpole">
  <size nuserdata="1"/>
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
NREPLAY = 500                                # 5 s of simulated time
MAX_STEPS = 60                               # timeout: 0.6 s per episode


@wp.kernel
def done_kernel(
    # Data in:
    qpos_in: wp.array2d[float],
    userdata_in: wp.array2d[float],
    # In:
    max_angle: float,
    max_x: float,
    max_steps: float,
    # Out:
    done_out: wp.array[bool],
    reason_out: wp.array2d[int],
):
    worldid = wp.tid()
    fell = wp.abs(qpos_in[worldid, 1]) > max_angle
    off_rail = wp.abs(qpos_in[worldid, 0]) > max_x
    timeout = userdata_in[worldid, 0] >= max_steps
    done_out[worldid] = fell or off_rail or timeout
    if fell or off_rail:
        reason_out[worldid, 0] += 1          # one thread per world: plain +=, no atomics
    elif timeout:
        reason_out[worldid, 1] += 1


@wp.kernel
def randomize_pole(
    # In:
    done_in: wp.array[bool],
    seed: int,
    reason_in: wp.array2d[int],
    # Data out:
    qpos_out: wp.array2d[float],
):
    worldid = wp.tid()
    if not done_in[worldid]:
        return
    episode = reason_in[worldid, 0] + reason_in[worldid, 1]      # survives resets
    rng = wp.rand_init(seed, worldid * 100003 + episode)
    qpos_out[worldid, 1] = wp.randf(rng, -0.3, 0.3)


@wp.kernel
def apply_push(
    # In:
    push_in: wp.array[float],
    # Data out:
    ctrl_out: wp.array2d[float],
):
    worldid = wp.tid()
    ctrl_out[worldid, 0] = push_in[worldid]  # every step: reset_data zeroed ctrl of done worlds


mjm = mujoco.MjModel.from_xml_string(CARTPOLE_UD)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
done = wp.ones(NWORLD, dtype=bool)          # every buffer exists before capture
reason = wp.zeros((NWORLD, 2), dtype=int)   # episodes ended by: [fell/off rail, timeout]
push = wp.array(np.linspace(-0.3, 0.3, NWORLD, dtype=np.float32))  # a constant push per world
wp.launch(apply_push, dim=NWORLD, inputs=[push], outputs=[d.ctrl])      # (no policy yet)


def env_post(m, d):                          # everything after the physics step
    my_env.count_userdata(d, 0)
    wp.launch(done_kernel, dim=d.nworld, inputs=[d.qpos, d.userdata, 0.6, 1.5, float(MAX_STEPS)],
              outputs=[done, reason])
    my_env.reset_done(m, d, done)            # reset_data(reset=done) + forward
    wp.launch(randomize_pole, dim=d.nworld, inputs=[done, 7, reason], outputs=[d.qpos])
    wp.launch(apply_push, dim=d.nworld, inputs=[push], outputs=[d.ctrl])  # after the reset


wp.launch(randomize_pole, dim=NWORLD, inputs=[done, 7, reason], outputs=[d.qpos])  # episode 0
mjw.step(m, d)                               # warm-up compile (mjw.step and the env kernels)
env_post(m, d)
reason.zero_()
d.userdata.zero_()
graph = my_env.capture_step(m, d, nsub=1, post=env_post)
frames = []
done_since = np.zeros(min(8, NWORLD), dtype=bool)
for i in range(NREPLAY):
    wp.capture_launch(graph)
    if args.dump_json:                       # host reads for the figure only
        done_since |= done.numpy()[:8]       # remember resets between sampled frames
        if i % 5 == 4:
            q = d.qpos.numpy()[:8, 1]
            frames.append([[round(float(q[w]), 3), int(done_since[w])] for w in range(len(q))])
            done_since[:] = False
wp.synchronize()

r = reason.numpy()
print(f"{NREPLAY} graph replays = {NREPLAY * mjm.opt.timestep:.1f} s per world")
print("push per world (d.ctrl):  ", d.ctrl.numpy()[:8, 0])
print("episodes per world:      ", r.sum(axis=1)[:8])
print("  ended by fall/off rail:", r[:8, 0])
print("  ended by timeout:      ", r[:8, 1])
print("steps in current episode (userdata[:, 0]):", d.userdata.numpy()[:8, 0])
print("all finite:", bool(np.isfinite(d.qpos.numpy()).all()),
      "| overflow:", my_env.describe_overflow(d))

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": min(8, NWORLD), "dt": 5 * float(mjm.opt.timestep),
                   "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
