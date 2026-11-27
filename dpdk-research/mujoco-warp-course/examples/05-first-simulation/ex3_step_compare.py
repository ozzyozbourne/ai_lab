"""Example 5.6 - step MJWarp and C MuJoCo side by side and compare one world.

All NWORLD worlds start from the same state, so each one should track C MuJoCo (float64) up to
float32 rounding. We copy world 2 back with get_data_into and compare qpos, ncon and nefc.
Run: python ex3_step_compare.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

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

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 60

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

ref = mujoco.MjData(mjm)          # C MuJoCo, float64, one world
for _ in range(NSTEP):
    mjw.step(m, d)                # all NWORLD worlds in one call
    mujoco.mj_step(mjm, ref)

out = mujoco.MjData(mjm)
mjw.get_data_into(out, mjm, d, world_id=2)

print(f"device: {wp.get_device()} | nworld: {d.nworld} | steps: {NSTEP}")
print(f"time  MJWarp {out.time:.6f}  C {ref.time:.6f}")
print("ball z MJWarp:", out.qpos[2].round(6), " C:", ref.qpos[2].round(6))
print("max |qpos diff| world 2 vs C:", f"{np.abs(out.qpos - ref.qpos).max():.2e}")
print("max |qvel diff| world 2 vs C:", f"{np.abs(out.qvel - ref.qvel).max():.2e}")
print(f"ncon  MJWarp {out.ncon}  C {ref.ncon} | nefc  MJWarp {out.nefc}  C {ref.nefc}")
spread = np.ptp(d.qpos.numpy(), axis=0).max()
print("max spread of qpos across worlds:", f"{spread:.1e}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
