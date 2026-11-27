"""Example 14.1 - the sensor catalogue: every SensorType, its stage and its dim.

Builds one MJCF that contains one sensor of every kind MJWarp 4.0.1 supports, compiles it with
MuJoCo, uploads it with put_model, runs one forward pass and prints, for each sensor: name, type,
the stage that computes it (mjm.sensor_needstage), its slice of sensordata (adr, dim), and which
put_model list it was sorted into. The only mjtSensor value missing from SensorType is PLUGIN.
Run: python ex1_sensor_catalogue.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import SensorType   # private API: full enum (not exported by mjw)

np.set_printoptions(precision=4, suppress=True)

CATALOGUE = """
<mujoco model="catalogue">
  <option timestep="0.005" magnetic="0 -0.5 0"/>
  <asset><mesh name="pad" builtin="sphere" params="0" scale=".05 .05 .05"/></asset>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="2 2 .1"/>
    <camera name="cam" pos="0 -1.5 .5" xyaxes="1 0 0 0 0 1" resolution="64 48"/>
    <site name="zone" pos="0 0 .3" type="box" size=".5 .5 .5"/>
    <body name="arm" pos="0 0 1">
      <joint name="hinge" type="hinge" axis="0 1 0" range="-1 1"/>
      <geom name="link" type="capsule" fromto="0 0 0 .3 0 0" size=".03" mass="1"/>
      <site name="imu" pos=".3 0 0"/>
      <body name="wrist" pos=".3 0 0">
        <joint name="ball" type="ball"/>
        <geom name="hand" type="sphere" size=".04" mass=".2"/>
      </body>
    </body>
    <body name="box" pos="1 0 .1">
      <freejoint/>
      <geom name="boxgeom" type="box" size=".1 .1 .1" mass="1"/>
      <site name="boxsite" pos="0 0 -.1"/>
      <site name="ray" pos="0 0 .1" zaxis="0 0 1"/>
    </body>
    <body name="padbody" pos="-1 0 .5">
      <freejoint/>
      <geom name="padgeom" type="mesh" mesh="pad"/>
    </body>
  </worldbody>
  <tendon><fixed name="ten" range="-1 1"><joint joint="hinge" coef="1"/></fixed></tendon>
  <actuator>
    <motor name="m_hinge" joint="hinge" gear="1"/>
    <motor name="m_ten" tendon="ten" gear="1"/>
  </actuator>
  <sensor>
    <magnetometer name="magnetometer" site="imu"/>
    <camprojection name="camprojection" site="imu" camera="cam"/>
    <rangefinder name="rangefinder" site="ray"/>
    <jointpos name="jointpos" joint="hinge"/>
    <tendonpos name="tendonpos" tendon="ten"/>
    <actuatorpos name="actuatorpos" actuator="m_hinge"/>
    <ballquat name="ballquat" joint="ball"/>
    <jointlimitpos name="jointlimitpos" joint="hinge"/>
    <tendonlimitpos name="tendonlimitpos" tendon="ten"/>
    <framepos name="framepos" objtype="site" objname="imu"/>
    <framexaxis name="framexaxis" objtype="site" objname="imu"/>
    <frameyaxis name="frameyaxis" objtype="site" objname="imu"/>
    <framezaxis name="framezaxis" objtype="site" objname="imu"/>
    <framequat name="framequat" objtype="site" objname="imu"/>
    <subtreecom name="subtreecom" body="arm"/>
    <distance name="geomdist" geom1="boxgeom" geom2="floor"/>
    <normal name="geomnormal" geom1="boxgeom" geom2="floor"/>
    <fromto name="geomfromto" geom1="boxgeom" geom2="floor"/>
    <insidesite name="insidesite" site="zone" objtype="body" objname="box"/>
    <e_potential name="e_potential"/>
    <e_kinetic name="e_kinetic"/>
    <clock name="clock"/>
    <velocimeter name="velocimeter" site="imu"/>
    <gyro name="gyro" site="imu"/>
    <jointvel name="jointvel" joint="hinge"/>
    <tendonvel name="tendonvel" tendon="ten"/>
    <actuatorvel name="actuatorvel" actuator="m_hinge"/>
    <ballangvel name="ballangvel" joint="ball"/>
    <jointlimitvel name="jointlimitvel" joint="hinge"/>
    <tendonlimitvel name="tendonlimitvel" tendon="ten"/>
    <framelinvel name="framelinvel" objtype="site" objname="imu"/>
    <frameangvel name="frameangvel" objtype="site" objname="imu"/>
    <subtreelinvel name="subtreelinvel" body="arm"/>
    <subtreeangmom name="subtreeangmom" body="arm"/>
    <touch name="touch" site="boxsite"/>
    <contact name="contact" body1="box" num="2" data="found force"/>
    <accelerometer name="accelerometer" site="imu"/>
    <force name="force" site="imu"/>
    <torque name="torque" site="imu"/>
    <actuatorfrc name="actuatorfrc" actuator="m_hinge"/>
    <tendonactuatorfrc name="tendonactfrc" tendon="ten"/>
    <jointactuatorfrc name="jointactfrc" joint="hinge"/>
    <jointlimitfrc name="jointlimitfrc" joint="hinge"/>
    <tendonlimitfrc name="tendonlimitfrc" tendon="ten"/>
    <framelinacc name="framelinacc" objtype="site" objname="imu"/>
    <frameangacc name="frameangacc" objtype="site" objname="imu"/>
    <tactile name="tactile" geom="padgeom" mesh="pad"/>
    <user name="user" dim="2" needstage="acc" datatype="real"/>
  </sensor>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 2

mjm = mujoco.MjModel.from_xml_string(CATALOGUE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=32, njmax=128)
mjw.forward(m, d)
wp.synchronize()

STAGE = {int(mujoco.mjtStage.mjSTAGE_POS): "pos", int(mujoco.mjtStage.mjSTAGE_VEL): "vel",
         int(mujoco.mjtStage.mjSTAGE_ACC): "acc"}
# the per-stage launch lists that put_model builds (io.py)
lists = {name: set(getattr(m, name).numpy().tolist()) for name in (
    "sensor_pos_adr", "sensor_limitpos_adr", "sensor_vel_adr", "sensor_limitvel_adr",
    "sensor_acc_adr", "sensor_touch_adr", "sensor_limitfrc_adr", "sensor_tendonactfrc_adr",
    "sensor_contact_pos_adr", "sensor_contact_vel_adr", "sensor_contact_acc_adr")}

rows = []
seen = set()
print(f"{'sensor':15s} {'SensorType':15s} stage adr dim  launched by")
for i in range(mjm.nsensor):
    st = SensorType(int(mjm.sensor_type[i]))
    seen.add(st)
    stage = STAGE[int(mjm.sensor_needstage[i])]
    adr, dim = int(mjm.sensor_adr[i]), int(mjm.sensor_dim[i])
    where = [k.replace("sensor_", "").replace("_adr", "") for k, v in lists.items() if i in v]
    # the generic pos/vel/acc lists also hold RANGEFINDER, TACTILE and USER; their kernels have no
    # branch for these types (the thread writes nothing), the function named after it fills the columns
    if st == SensorType.RANGEFINDER:
        where = where + ["rangefinder (ray.rays)"]
    elif st in (SensorType.E_POTENTIAL, SensorType.E_KINETIC):
        where = where + ["energy_pos/vel"]
    elif st == SensorType.TACTILE:
        where = where + ["_sensor_tactile"]
    elif st == SensorType.USER:
        where = where + ["callback.sensor"]
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_SENSOR, i)
    print(f"{name:15s} {st.name:15s} {stage:5s} {adr:3d} {dim:3d}  {', '.join(where)}")
    rows.append({"name": name, "type": st.name, "stage": stage, "adr": adr, "dim": dim})

missing = [s.name for s in SensorType if s not in seen]
print("nsensor:", mjm.nsensor, "| nsensordata:", mjm.nsensordata,
      "| sensordata shape:", d.sensordata.shape)
print("SensorType members covered:", len(seen), "of", len(SensorType), "| missing:", missing)
not_supported = [e.name for e in mujoco.mjtSensor.__members__.values()
                 if int(e) not in {int(s) for s in SensorType}]
print("mjtSensor values put_model rejects:", not_supported)
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"sensors": rows, "nsensordata": int(mjm.nsensordata)}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json, len(rows), "sensors")
