# Notebook spec for Chapter 26. Build with:
#   python3 tools/make_notebook.py notebooks/specs/26-custom-kernels-and-extending.py
SLUG = "26-custom-kernels-and-extending"
TITLE = "Ch 26 · Writing Custom Kernels and Extending MJWarp"

EX1_STUB = r'''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = np.where(np.arange(NWORLD) % 2 == 0, 0.099, 0.5)   # even worlds touch the floor
d.qpos.assign(qpos)
mjw.forward(m, d)


@wp.kernel
def count_contacts(
    # Data in:
    contact_worldid_in: wp.array[int],
    nacon_in: wp.array[int],
    # Out:
    count_out: wp.array[int],
):
    conid = wp.tid()
    ...  # your code: skip slots past nacon, then count one contact for its world


count = wp.zeros(NWORLD, dtype=int)
wp.launch(count_contacts, dim=d.naconmax, inputs=[d.contact.worldid, d.nacon], outputs=[count])

n = d.nacon.numpy()[0]
ref = np.bincount(d.contact.worldid.numpy()[:n], minlength=NWORLD)
assert np.array_equal(count.numpy(), ref), (count.numpy(), ref)
print("contacts per world:", count.numpy())
'''

EX1_SOL = r'''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
qpos[:, 2] = np.where(np.arange(NWORLD) % 2 == 0, 0.099, 0.5)   # even worlds touch the floor
d.qpos.assign(qpos)
mjw.forward(m, d)


@wp.kernel
def count_contacts(
    # Data in:
    contact_worldid_in: wp.array[int],
    nacon_in: wp.array[int],
    # Out:
    count_out: wp.array[int],
):
    conid = wp.tid()
    if conid >= nacon_in[0]:
        return
    wp.atomic_add(count_out, contact_worldid_in[conid], 1)  # integer atomics: order-free result


count = wp.zeros(NWORLD, dtype=int)
wp.launch(count_contacts, dim=d.naconmax, inputs=[d.contact.worldid, d.nacon], outputs=[count])

n = d.nacon.numpy()[0]
ref = np.bincount(d.contact.worldid.numpy()[:n], minlength=NWORLD)
assert np.array_equal(count.numpy(), ref), (count.numpy(), ref)
print("contacts per world:", count.numpy())
'''

EX2_STUB = r'''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
q = np.zeros((NWORLD, 2), dtype=np.float32)
q[:, 1] = np.linspace(-0.5, 0.5, NWORLD)
d.qpos.assign(q)
for _ in range(20):
    mjw.step(m, d)
obs = wp.zeros((NWORLD, 5), dtype=float)


@wp.kernel
def cartpole_obs(
    # Data in:
    qpos_in: wp.array2d[float],
    qvel_in: wp.array2d[float],
    # Out:
    obs_out: wp.array2d[float],
):
    worldid = wp.tid()
    ...  # your code: [x, cos(theta), sin(theta), xdot, thetadot]


wp.launch(cartpole_obs, dim=NWORLD, inputs=[d.qpos, d.qvel], outputs=[obs])

qp, qv = d.qpos.numpy(), d.qvel.numpy()
ref = np.stack([qp[:, 0], np.cos(qp[:, 1]), np.sin(qp[:, 1]), qv[:, 0], qv[:, 1]], axis=1)
assert np.allclose(obs.numpy(), ref, atol=1e-6), np.abs(obs.numpy() - ref).max()
print("obs[0]:", obs.numpy()[0].round(4), "| max diff", np.abs(obs.numpy() - ref).max())
'''

EX2_SOL = r'''import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(CARTPOLE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
q = np.zeros((NWORLD, 2), dtype=np.float32)
q[:, 1] = np.linspace(-0.5, 0.5, NWORLD)
d.qpos.assign(q)
for _ in range(20):
    mjw.step(m, d)
obs = wp.zeros((NWORLD, 5), dtype=float)


@wp.kernel
def cartpole_obs(
    # Data in:
    qpos_in: wp.array2d[float],
    qvel_in: wp.array2d[float],
    # Out:
    obs_out: wp.array2d[float],
):
    worldid = wp.tid()
    theta = qpos_in[worldid, 1]
    obs_out[worldid, 0] = qpos_in[worldid, 0]
    obs_out[worldid, 1] = wp.cos(theta)
    obs_out[worldid, 2] = wp.sin(theta)
    obs_out[worldid, 3] = qvel_in[worldid, 0]
    obs_out[worldid, 4] = qvel_in[worldid, 1]


wp.launch(cartpole_obs, dim=NWORLD, inputs=[d.qpos, d.qvel], outputs=[obs])

qp, qv = d.qpos.numpy(), d.qvel.numpy()
ref = np.stack([qp[:, 0], np.cos(qp[:, 1]), np.sin(qp[:, 1]), qv[:, 0], qv[:, 1]], axis=1)
assert np.allclose(obs.numpy(), ref, atol=1e-6), np.abs(obs.numpy() - ref).max()
print("obs[0]:", obs.numpy()[0].round(4), "| max diff", np.abs(obs.numpy() - ref).max())
'''

STRETCH = r'''# Stretch: a custom passive spring field (a starting point; extend it as the page suggests)
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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
NWORLD = 8
mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
NWORLD = 4
K, ANCHOR = 50.0, (0.0, 0.0, 0.6)


@wp.kernel
def spring_field(
    # Data in:
    qpos_in: wp.array2d[float],
    qvel_in: wp.array2d[float],
    # In:
    k: float,
    anchor: wp.vec3,
    # Data out:
    qfrc_passive_out: wp.array2d[float],
):
    worldid = wp.tid()
    p = wp.vec3(qpos_in[worldid, 0], qpos_in[worldid, 1], qpos_in[worldid, 2])
    v = wp.vec3(qvel_in[worldid, 0], qvel_in[worldid, 1], qvel_in[worldid, 2])
    f = k * (anchor - p) - 2.0 * wp.sqrt(k) * v          # critically damped for mass 1
    for i in range(3):
        qfrc_passive_out[worldid, i] += f[i]


mjm = mujoco.MjModel.from_xml_string(BALL_DROP)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=4, njmax=16)
m.callback.passive = lambda m, d: wp.launch(spring_field, dim=d.nworld,
    inputs=[d.qpos, d.qvel, K, wp.vec3(*ANCHOR)], outputs=[d.qfrc_passive])
for _ in range(1000):
    mjw.step(m, d)
z = d.qpos.numpy()[:, 2]
print("rest height:", z, "| predicted", f"{ANCHOR[2] - 9.81 / K:.4f}")
'''

CELLS = [
    ["md", "This notebook mirrors the chapter page: every example in order, then the exercises. It runs on a "
           "GPU runtime (big budgets) and on CPU (small budgets, `ON_GPU = False`). The page's outputs were "
           "recorded on CPU; numbers on CPU are never GPU performance."],
    ["md", "## The running project: `my_env.py` (snapshot after Ch 26)\nThis chapter adds the RL kernels "
           "`obs_columns`, `pack_obs`, `site_reward`, `accumulate` and `count_userdata`. The cell writes the "
           "whole module so the notebook runs in an empty Colab runtime."],
    ["writefile", "my_env.py", "examples/26-custom-kernels-and-extending/my_env_step26.py"],
    ["md", "## 1-2. A reward kernel and an accumulator in the step graph\nThe kernel follows MJWarp's "
           "conventions (`# Model:` / `# Data in:` / `# In:` / `# Out:`, `_in`/`_out`, "
           "`worldid % shape[0]`, typed locals). Everything the graph touches is allocated before capture."],
    ["example", "ex1_reward_graph.py", "26.1"],
    ["md", "## An observation kernel and `d.userdata`\n`obs_columns` turns sensor names into sensordata "
           "columns once on the host; `pack_obs` fills a preallocated `(nworld, nobs)` buffer on the device. "
           "`<size nuserdata=\"2\"/>` gives every world 2 free floats, zeroed by `reset_data` and saved by "
           "`State.USERDATA`."],
    ["example", "ex2_obs_kernel.py", "26.2"],
    ["md", "## Step, done, reset and re-randomize in one graph\nThe Ch 8 auto-reset (`my_env.reset_done`) "
           "captured together with `mjw.step` by `my_env.capture_step(..., post=env_post)`."],
    ["example", "ex3_reset_in_graph.py", "26.3"],
    ["md", "## 3-4. Callbacks: passive forces\n`m.callback.passive` is the last line of `passive.passive`: "
           "ADD to `d.qfrc_passive`. Quadratic drag gives the terminal speed `sqrt(m g / c)`."],
    ["example", "ex4_passive_callback.py", "26.4"],
    ["md", "## Actuator callbacks run after the force kernel\nFor `gaintype=\"user\"` the kernel leaves "
           "gain 0; `act_gain` must write the final force, and `forcerange` is not applied again. C MuJoCo "
           "clamps instead."],
    ["example", "ex5_act_gain_callback.py", "26.5"],
    ["md", "## 5. Sensor callbacks and `Stage`\nCalled three times per forward (POS, VEL, ACC); fill your user "
           "sensor once, at its stage. `Stage` is private API: `mujoco_warp._src.types.Stage`."],
    ["example", "ex6_sensor_callback.py", "26.6"],
    ["md", "## The contact filter\n`nacon` cannot shrink: clear the `ContactType.CONSTRAINT` bit of "
           "`d.contact.type` to drop a contact. The kernel launches over `naconmax`."],
    ["example", "ex7_contactfilter.py", "26.7"],
    ["md", "## 6. User-populated contacts\n`m.opt.run_collision_detection = False` skips collision and keeps "
           "whatever is in `d.contact` and `d.nacon`. Never write `contact.flex/elem/vert` when `nflex == 0`. "
           "Tip: `wp.config.mode = \"debug\"` (set before the first launch) adds bounds checks while you develop."],
    ["example", "ex8_user_contacts.py", "26.8"],
    ["md", "## 7. Kernel factories and `cache_kernel`\nKeys are one hash per positional argument (objects with "
           "`.size` by size) plus the factory's module and name. In a notebook, a factory you redefine under "
           "the same name returns its old kernels until you restart the runtime."],
    ["example", "ex9_factory.py", "26.9"],
    ["md", "## 8. Tiles: a block of threads per world\n`launch_tiled`, `tile`, `tile_load`, `tile_load_indexed`, "
           "`tile_sum`, `tile_store`. On a GPU each world gets 64 lanes; on CPU one lane."],
    ["example", "ex10_tile_contact_force.py", "26.10"],
    ["md", "## 10. Reuse an MJWarp `wp.func` and test it like MJWarp\n`test_data.fixture`, `nworld` 1 and 2 "
           "with world 1 perturbed, outputs pre-filled with `wp.inf`, compared with MuJoCo C at 1e-5."],
    ["example", "ex11_reuse_math_test.py", "26.11"],
    ["md", "## 12. The kernel analyzer\nThe analyzer is in the repository, not in the wheel. Clone it first "
           "at the tag `v4.0.1`, which matches the installed wheel (about 60 MB with `--depth 1`); see the "
           "version note on the page. Then the example writes a learner file with deliberate issues and its fixed "
           "version and runs the CLI on both."],
    ["code", "!git clone --depth 1 --branch v4.0.1 https://github.com/google-deepmind/mujoco_warp\n"
             "!git -C mujoco_warp log -1 --format='analyzer from commit %h (%cs)'"],
    ["example", "ex12_kernel_analyzer.py", "26.12"],
    ["md", "## Exercise 26.1: contacts per world\nCount the contacts of each world with a kernel launched over "
           "`d.naconmax` and assert against `np.bincount`. Which atomic is safe here, and why?"],
    ["code", EX1_STUB],
    ["solution", EX1_SOL, "Exercise 26.1"],
    ["md", "## Exercise 26.2: a cart-pole observation kernel\nWrite `[x, cos θ, sin θ, ẋ, θ̇]` per world and "
           "assert against NumPy with `atol=1e-6`."],
    ["code", EX2_STUB],
    ["solution", EX2_SOL, "Exercise 26.2"],
    ["md", "## Stretch: a custom passive spring field\nA critically damped spring toward an anchor via "
           "`m.callback.passive`. Extend it: per-world anchors in `d.userdata`, capture in a graph, and check "
           "that changing the callback after capture needs a recapture."],
    ["code", STRETCH],
]
