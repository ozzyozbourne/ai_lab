"""Example 24.7 - one graph = 4 physics substeps + your own reward kernel.

An RL control step usually holds several physics steps (the "frame skip") plus kernels you
write (observation, reward, done; Ch 26 and Ch 30). capture_step(m, d, nsub, post) records all of
them into one graph, so a control step is a single wp.capture_launch. We replay it 10 times and
compare with the same work done eagerly: on CPU the difference is exactly 0.
Run: python ex7_substeps_and_kernels.py
"""
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
    import my_env_step24 as my_env          # examples/24-cuda-graphs/

np.set_printoptions(precision=4, suppress=True)

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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NSUB = 4                                    # physics steps per control step
NCONTROL = 10                               # control steps (graph replays)


@wp.kernel
def reward_kernel(qpos: wp.array2d(dtype=float), qvel: wp.array2d(dtype=float),
                  reward: wp.array(dtype=float)):
    worldid = wp.tid()                      # one thread per world
    x = qpos[worldid, 0]
    theta = qpos[worldid, 1]                # 0 = pole upright
    reward[worldid] += 1.0 - theta * theta - 0.01 * x * x - 0.001 * qvel[worldid, 1] ** 2.0


mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
reward = wp.zeros(NWORLD, dtype=float)

qpos0 = np.zeros((NWORLD, mjm.nq), dtype=np.float32)
qpos0[:, 1] = np.linspace(-0.2, 0.2, NWORLD)            # a different pole tilt per world
ctrl0 = np.linspace(0.0, 0.6, NWORLD, dtype=np.float32).reshape(NWORLD, 1)


def restart():
    d.qpos.assign(qpos0)
    d.qvel.zero_()
    d.time.zero_()
    d.ctrl.assign(ctrl0)
    reward.zero_()


def add_reward(m, d):                       # the `post` hook: runs after the NSUB steps
    wp.launch(reward_kernel, dim=d.nworld, inputs=[d.qpos, d.qvel], outputs=[reward])


# eager reference: NCONTROL x (NSUB steps + reward kernel)
restart()
for _ in range(NCONTROL):
    for _ in range(NSUB):
        mjw.step(m, d)
    add_reward(m, d)
wp.synchronize()
eager_r, eager_q = reward.numpy().copy(), d.qpos.numpy().copy()

# graph: the same work recorded once, replayed NCONTROL times
restart()
graph = my_env.capture_step(m, d, nsub=NSUB, post=add_reward)
print(f"after capture: d.time = {d.time.numpy()[0]:.2f}, reward w0 = {reward.numpy()[0]:.1f}"
      "  (nothing ran yet)")
for _ in range(NCONTROL):
    wp.capture_launch(graph)                # 4 physics steps + 1 reward launch per call
wp.synchronize()
graph_r, graph_q = reward.numpy(), d.qpos.numpy()

print(f"{NCONTROL} replays x {NSUB} substeps: d.time = {d.time.numpy()[0]:.2f} s")
print("reward per world (graph):", graph_r)
print("reward per world (eager):", eager_r)
print(f"max |reward diff| = {np.abs(graph_r - eager_r).max():.1e}, "
      f"max |qpos diff| = {np.abs(graph_q - eager_q).max():.1e}")
