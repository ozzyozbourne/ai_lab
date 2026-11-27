"""Example 22.3 - the m.opt.deterministic setter: bools, ints, complements and bad values.

m.opt.deterministic is a DeterminismType bitmask (types.py: CONTACTS=1, CONSTRAINT=2, ATOMICS=4,
ALL=7). The Option setter maps True/False/None to ALL/NONE, masks a negative complement such as
~DeterminismType.CONTACTS to the valid bits, and raises ValueError for anything outside ALL.
io.override_model parses the same option from strings ("atomics", "~CONTACTS", "contacts|atomics").
Run: python ex3_deterministic_setter.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.io import override_model  # private API: may change between versions

PENDULUM = """
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
  </sensor>
  <keyframe><key name="horizontal" qpos="1.5708 0"/></keyframe>
</mujoco>
"""

DT = mjw.DeterminismType


def show(v: int) -> str:
    """Name the set bits of a DeterminismType value, e.g. 6 -> 'CONSTRAINT|ATOMICS'."""
    names = [f.name for f in (DT.CONTACTS, DT.CONSTRAINT, DT.ATOMICS) if v & f]
    return "|".join(names) or "NONE"


NAMES = ["NONE", "CONTACTS", "CONSTRAINT", "ATOMICS", "ALL"]
print("DeterminismType:", {n: int(getattr(DT, n)) for n in NAMES})

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)
print("default after put_model:", m.opt.deterministic, show(m.opt.deterministic))

for label, value in [("True", True), ("False", False), ("None", None),
                     ("np.bool_(True)", np.bool_(True)), ("ATOMICS", DT.ATOMICS),
                     ("CONTACTS | ATOMICS", DT.CONTACTS | DT.ATOMICS),
                     ("~CONTACTS", ~DT.CONTACTS), ("-1", -1), ("7", 7)]:
    m.opt.deterministic = value
    v = m.opt.deterministic
    print(f"set {label:20s} -> {v} ({show(v)}), stored as {type(v).__name__}")

# in-place bit arithmetic works because the stored value is a plain int
m.opt.deterministic = DT.ALL
m.opt.deterministic &= ~DT.ATOMICS
print("ALL with ATOMICS cleared ->", m.opt.deterministic, show(m.opt.deterministic))

for bad in [99, 8, 1.5, "ATOMICS"]:
    try:
        m.opt.deterministic = bad
    except (TypeError, ValueError) as e:
        print(f"set {bad!r:6} -> {type(e).__name__}: {e}")
print("value unchanged after errors:", m.opt.deterministic, show(m.opt.deterministic))

# override_model (the parser behind mjwarp-testspeed -o) understands strings
# "~NAME" clears bits from the CURRENT value, so start points matter
for start, ov in [(DT.NONE, "atomics"), (DT.NONE, "contacts | atomics"), (DT.NONE, "true"),
                  (DT.NONE, "~CONTACTS"), (DT.ALL, "~CONTACTS"), (DT.ALL, "~CONTACTS|ATOMICS")]:
    m.opt.deterministic = start
    override_model(m, {"opt.deterministic": ov})  # mutates m in place and returns None
    print(f"override from {show(start):26s} with {ov!r:22s} -> {m.opt.deterministic}"
          f" ({show(m.opt.deterministic)})")

# a deterministic model steps like any other
d = mjw.make_data(mjm, nworld=2)
m.opt.deterministic = True
mjw.reset_data_keyframe(m, d, 0)
for _ in range(3):
    mjw.step(m, d)
print("3 steps with ALL, qpos world 0:", np.round(d.qpos.numpy()[0], 6))
