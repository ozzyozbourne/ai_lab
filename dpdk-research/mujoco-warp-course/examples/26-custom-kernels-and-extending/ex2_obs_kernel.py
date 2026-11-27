"""Example 26.2 - an observation kernel and a per-world counter kept in d.userdata.

my_env.obs_columns(mjm, names) turns sensor names into sensordata columns once, on the host
(it uses my_env.sensor_slices from Ch 14); my_env.pack_obs then fills a preallocated
(nworld, nobs) buffer with [qpos | qvel | the chosen sensors], one thread per (world, entry).
We compare it with a NumPy concatenation. The model declares <size nuserdata="2"/>, so every
world has 2 free floats in d.userdata: column 0 counts steps (my_env.count_userdata), column 1
holds the highest tip so far. userdata is part of State.USERDATA and is zeroed by reset_data.
Run: python ex2_obs_kernel.py
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
    import my_env_step26 as my_env          # examples/26-custom-kernels-and-extending/

np.set_printoptions(precision=4, suppress=True)

# PENDULUM (shared model M2) plus one line: <size nuserdata="2"/>
PENDULUM_UD = """
<mujoco model="double_pendulum">
  <size nuserdata="2"/>
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
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50


@wp.kernel
def max_tip_height(
    # Data in:
    sensordata_in: wp.array2d[float],
    # In:
    zcol: int,
    # Data out:
    userdata_out: wp.array2d[float],
):
    worldid = wp.tid()
    userdata_out[worldid, 1] = wp.max(userdata_out[worldid, 1], sensordata_in[worldid, zcol])


mjm = mujoco.MjModel.from_xml_string(PENDULUM_UD)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
print("nuserdata:", m.nuserdata, "| d.userdata shape:", d.userdata.shape)

names = ["v1", "tip_pos"]                    # skip q1: it duplicates qpos[0]
nobs, cols = my_env.obs_columns(mjm, names)
print("sensor slices:", my_env.sensor_slices(mjm), "-> columns", cols.numpy(), "| nobs", nobs)
obs = wp.zeros((NWORLD, nobs), dtype=float)  # preallocated once, reused every step

qpos = np.zeros((NWORLD, mjm.nq), dtype=np.float32)
qpos[:, 0] = np.linspace(0.2, 1.6, NWORLD)   # a different start angle per world
d.qpos.assign(qpos)
zcol = int(mjm.sensor_adr[2]) + 2            # tip_pos z in sensordata

for _ in range(NSTEP):
    mjw.step(m, d)
    my_env.count_userdata(d, 0)              # userdata[:, 0] += 1
    wp.launch(max_tip_height, dim=d.nworld, inputs=[d.sensordata, zcol], outputs=[d.userdata])
my_env.pack_obs(m, d, cols, obs)
wp.synchronize()

ref = np.concatenate([d.qpos.numpy(), d.qvel.numpy(), d.sensordata.numpy()[:, cols.numpy()]],
                     axis=1)
o = obs.numpy()
print("obs shape:", o.shape, "| max |kernel - numpy| =", np.abs(o - ref).max())
print("obs world 0:", o[0])
print("userdata[:, 0] (steps):  ", d.userdata.numpy()[:, 0])
print("userdata[:, 1] (max tip z):", d.userdata.numpy()[:, 1])

# userdata is state: it is in State.USERDATA snapshots and is zeroed by reset_data
sig = mjw.State.USERDATA
buf = my_env.snapshot(m, d, mjm, sig)
print("State.USERDATA size:", mujoco.mj_stateSize(mjm, int(sig)), "| snapshot w0:", buf.numpy()[0])
mask = wp.array(np.arange(NWORLD) % 2 == 0, dtype=bool)
mjw.reset_data(m, d, reset=mask)             # reset the even worlds only
print("after reset_data(even worlds):", d.userdata.numpy()[:4, 0])
my_env.restore(m, d, mjm, buf, sig)
print("after restore(USERDATA):      ", d.userdata.numpy()[:4, 0])
