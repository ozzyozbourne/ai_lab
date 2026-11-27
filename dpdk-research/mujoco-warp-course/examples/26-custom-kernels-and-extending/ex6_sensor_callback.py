"""Example 26.6 - a user sensor filled by m.callback.sensor(m, d, stage).

The model declares <sensor><user name="u" dim="2" needstage="pos" datatype="real"/></sensor>.
MJWarp calls m.callback.sensor three times per forward: at the end of sensor_pos (Stage.POS),
sensor_vel (Stage.VEL) and sensor_acc (Stage.ACC). The callback must check `stage` and fill its
sensor only once, at the stage it declared. Stage is not exported by mujoco_warp: import it from
mujoco_warp._src.types (private API). Our sensor reports (tip height, tip distance from the
pivot) of the double pendulum, written at sensor_adr of the user sensor.
Run: python ex6_sensor_callback.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import Stage   # private API: may change between releases

np.set_printoptions(precision=4, suppress=True)

# PENDULUM (shared model M2) with a 2-dim user sensor added after the three built-in ones
PENDULUM_USER = """
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
    <user name="u" dim="2" needstage="pos" datatype="real"/>
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4


@wp.kernel
def tip_sensor(
    # Data in:
    site_xpos_in: wp.array2d[wp.vec3],
    # In:
    siteid: int,
    pivot: wp.vec3,
    adr: int,
    # Data out:
    sensordata_out: wp.array2d[float],
):
    worldid = wp.tid()
    p = site_xpos_in[worldid, siteid]
    sensordata_out[worldid, adr + 0] = p[2]                    # tip height
    sensordata_out[worldid, adr + 1] = wp.length(p - pivot)    # distance from the pivot


mjm = mujoco.MjModel.from_xml_string(PENDULUM_USER)
uid = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_SENSOR, "u")
ADR = int(mjm.sensor_adr[uid])
TIP = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_SITE, "tip")
print("nsensor:", mjm.nsensor, "| user sensor type USER:",
      int(mjm.sensor_type[uid]) == int(mujoco.mjtSensor.mjSENS_USER),
      "| needstage POS:", int(mjm.sensor_needstage[uid]) == int(mujoco.mjtStage.mjSTAGE_POS),
      "| adr", ADR, "dim", int(mjm.sensor_dim[uid]))
print("Stage members:", [(s.name, int(s)) for s in Stage])

seen = []


def sensor_callback(m, d, stage):
    seen.append(Stage(stage).name)
    if stage == Stage.POS:                   # declared needstage="pos": fill it here only
        wp.launch(tip_sensor, dim=d.nworld, inputs=[d.site_xpos, TIP, wp.vec3(0.0, 0.0, 1.5), ADR],
                  outputs=[d.sensordata])


m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
m.callback.sensor = sensor_callback

qpos = np.zeros((NWORLD, mjm.nq), dtype=np.float32)
qpos[:, 0] = np.linspace(0.0, np.pi / 2, NWORLD)   # shoulder angle per world
qpos[:, 1] = np.linspace(0.0, 1.0, NWORLD)         # elbow angle per world
d.qpos.assign(qpos)
mjw.forward(m, d)
print("callback stages in one forward:", seen)

sd = d.sensordata.numpy()
print("sensordata[:, ADR:ADR+2] (tip z, |tip - pivot|):")
print(sd[:, ADR:ADR + 2])
# check against the framepos sensor of the same site (sensordata columns 2..4)
tp = sd[:, 2:5]
ref = np.stack([tp[:, 2], np.linalg.norm(tp - np.array([0.0, 0.0, 1.5]), axis=1)], axis=1)
print("max |callback - framepos-derived| =", f"{np.abs(sd[:, ADR:ADR + 2] - ref).max():.1e}")

m.opt.disableflags |= mjw.DisableBit.SENSOR
seen.clear()
mjw.forward(m, d)
print("with DisableBit.SENSOR, callback stages:", seen)
