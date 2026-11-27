"""Example 2.4 - keyframes and resets: mj_resetDataKeyframe vs mj_resetData.

Steps PLAYGROUND for 1 s, then resets to keyframe 0 ("up": both bodies lifted to z = 2, hinge at
0.3 rad) and finally back to the default state qpos0. Prints qpos and time at each stage.
Run: python ex4_keyframe.py
"""
import mujoco
import numpy as np

np.set_printoptions(precision=3, suppress=True, linewidth=120)

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
mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
mjd = mujoco.MjData(mjm)

for _ in range(100):
    mujoco.mj_step(mjm, mjd)
print(f"after 1 s     t={mjd.time:.2f}  qpos={mjd.qpos}")

key = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_KEY, "up")
print("keyframe 'up' has id", key, "and stores", mjm.key_qpos.shape[1], "qpos values")
mujoco.mj_resetDataKeyframe(mjm, mjd, key)
print(f"keyframe 'up' t={mjd.time:.2f}  qpos={mjd.qpos}")
print("qvel after keyframe reset is zero:", not mjd.qvel.any())

mujoco.mj_resetData(mjm, mjd)
print(f"mj_resetData  t={mjd.time:.2f}  qpos={mjd.qpos}")
print("qpos0 (the model's default pose):", mjm.qpos0)

# A reset writes the state only. Derived quantities such as xpos are not recomputed (here
# they are zero) until mj_forward runs.
print("ball xpos before mj_forward:", mjd.xpos[1])
mujoco.mj_forward(mjm, mjd)
print("ball xpos after  mj_forward:", mjd.xpos[1])
