"""Example 6.2 - from shape to bytes: where d.xpos[w, b][k] lives in memory.

Warp arrays are row-major (C order). d.xpos has Warp shape (nworld, nbody) of vec3 (12 bytes),
so its byte offset is ((w * nbody + b) * 3 + k) * 4. We check the formula against .strides
and against the flat buffer, then list which bytes one 32-thread warp touches.
Run: python ex08_addresses.py
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
    <body name="ball" pos="0 0 1"><freejoint/><geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/><geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""

NWORLD = 8  # 8 worlds x 4 bodies = 32 (w, b) pairs = exactly one warp

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
nbody = mjm.nbody
# label every float32 word with its own index, so a value tells us where it was read from
d.xpos.assign(np.arange(NWORLD * nbody * 3, dtype=np.float32).reshape(NWORLD, nbody, 3))

print("d.xpos shape", d.xpos.shape, "strides (bytes)", d.xpos.strides,
      "contiguous", d.xpos.is_contiguous)
print("m.body_mass shape", m.body_mass.shape, "strides", m.body_mass.strides)

full = d.xpos.numpy()                      # (nworld, nbody, 3) view of the same bytes
print("  w  b  k   strides offset   formula   word label = offset/4")
for w, b, k in [(0, 0, 0), (0, 1, 0), (0, 1, 2), (1, 0, 0), (2, 3, 1), (7, 3, 2)]:
    off = w * d.xpos.strides[0] + b * d.xpos.strides[1] + k * 4
    formula = ((w * nbody + b) * 3 + k) * 4
    label = int(full[w, b, k])
    print(f"  {w}  {b}  {k}   {off:14d}   {formula:7d}   {label:5d} {label * 4 == off}")

# Warp unravels a 2-D launch index with the LAST dimension fastest (row-major):
# linear thread t -> (worldid, bodyid) = (t // nbody, t % nbody)
t = np.arange(32)                          # one warp = 32 consecutive threads
w_t, b_t = t // nbody, t % nbody
addr = (w_t * nbody + b_t) * 12
print(f"dim=(nworld, nbody): threads 0..31 = worlds {w_t.min()}..{w_t.max()},"
      f" bytes {addr.min()}..{addr.max() + 11}, contiguous: {bool((np.diff(addr) == 12).all())}")
addr_w = np.arange(NWORLD) * d.xpos.strides[0] + 1 * d.xpos.strides[1]
print("dim=nworld reading xpos[w, 1]: byte offsets", addr_w.tolist(), "(stride nbody*12)")
