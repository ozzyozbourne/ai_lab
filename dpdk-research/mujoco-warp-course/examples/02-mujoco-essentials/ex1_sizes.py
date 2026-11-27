"""Example 2.1 - MJCF -> MjModel sizes, and the same sizes on the MJWarp Model.

Loads the shared PLAYGROUND model (a ball, a box, a hinged arm), prints the size fields of the
compiled mujoco.MjModel, then uploads it with mjw.put_model and checks that MJWarp keeps the same
names and values (sizes are plain Python ints on the MJWarp Model).
Run: python ex1_sizes.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""

SIZES = ["nq", "nv", "nu", "nactuator", "na", "nbody", "njnt", "ngeom", "nsite",
         "nsensor", "nsensordata", "nmocap", "neq", "nkey", "ncam"]

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
print("MjModel sizes:")
for name in SIZES:
    print(f"  {name:12s} {getattr(mjm, name)}")

# Body 0 is always the world body; ngeom counts the floor, which belongs to the world body.
BODY = mujoco.mjtObj.mjOBJ_BODY
print("body names:", [mujoco.mj_id2name(mjm, BODY, i) for i in range(mjm.nbody)])
print("geom 0 is", mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, 0),
      "on body", mjm.geom_bodyid[0])
print("id of body 'box':", mujoco.mj_name2id(mjm, BODY, "box"))

# The MJWarp Model mirrors the MjModel size fields (plain Python ints).
m = mjw.put_model(mjm)
CHECK = ["nq", "nv", "nu", "na", "nbody", "ngeom", "nsite", "nsensordata", "nmocap", "neq"]
same = all(getattr(m, n) == getattr(mjm, n) for n in CHECK)
print("mjw.Model sizes equal MjModel sizes:", same, "| type(m.nq):", type(m.nq).__name__)
print("timestep on the MJWarp model:", m.opt.timestep.numpy(), "(a batched float32 array)")
