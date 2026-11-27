"""Example 22.7 - compare_runs: find the first field and world where two runs differ bitwise.

A reusable helper for reproducibility tests (and the exercises). It compares the bit patterns of
the chosen Data fields, not their values, so it catches -0.0 vs 0.0 (which == calls equal) and
treats identical NaNs as equal (== flags every NaN as different), and it reports the first differing field (in the order given), world and element with
both values in hex. Demo: two identical runs of the double pendulum, then a run where world 3
starts 1e-6 rad away and world 5 starts 1 ulp (float32) away in qpos. compare_runs reports
the first difference and lists every world that differs.
Run: python ex7_compare_runs.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

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

FIELDS = ("qpos", "qvel", "qacc", "act", "sensordata", "energy", "time")


def compare_runs(d1, d2, fields=FIELDS):
    """Return None if every field is bitwise equal, else a dict describing the first difference.

    Fields are (nworld, ...) arrays of mjw.Data; vector dtypes (vec3, ...) are flattened per world.
    """
    for name in fields:
        a, b = getattr(d1, name).numpy(), getattr(d2, name).numpy()
        if a.shape != b.shape:
            return {"field": name, "reason": f"shape {a.shape} != {b.shape}"}
        if a.size == 0:
            continue
        ua = np.ascontiguousarray(a).reshape(a.shape[0], -1).view(f"u{a.itemsize}")
        ub = np.ascontiguousarray(b).reshape(b.shape[0], -1).view(f"u{b.itemsize}")
        ne = ua != ub
        if ne.any():
            world, idx = (int(i) for i in np.argwhere(ne)[0])
            va, vb = a.reshape(a.shape[0], -1)[world, idx], b.reshape(b.shape[0], -1)[world, idx]
            hexw = 2 * a.itemsize
            return {"field": name, "world": world, "index": idx,
                    "a": f"{float(va):.9g} (0x{int(ua[world, idx]):0{hexw}x})",
                    "b": f"{float(vb):.9g} (0x{int(ub[world, idx]):0{hexw}x})",
                    "n_elements": int(ne.sum()), "worlds": np.flatnonzero(ne.any(axis=1)).tolist()}
    return None


ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
m = mjw.put_model(mjm)


def run(nudge=False):
    d = mjw.make_data(mjm, nworld=NWORLD)
    mjw.reset_data_keyframe(m, d, 0)
    qvel = np.zeros((NWORLD, mjm.nv), dtype=np.float32)
    qvel[:, 0] = np.linspace(0.0, 1.0, NWORLD)
    d.qvel.assign(qvel)
    if nudge:
        qpos = d.qpos.numpy()
        qpos[3, 0] += np.float32(1e-6)
        qpos[5, 0] = np.nextafter(qpos[5, 0], np.float32(10.0))   # the smallest float32 step
        d.qpos.assign(qpos)
    for _ in range(NSTEP):
        mjw.step(m, d)
    return d


d1, d2 = run(), run()
print(f"device: {wp.get_device()} | nworld {NWORLD} | {NSTEP} steps")
print("identical runs  :", compare_runs(d1, d2) or "bitwise equal in " + ", ".join(FIELDS))
d3 = run(nudge=True)
diff = compare_runs(d1, d3)
print("nudged run      :")
for k, v in diff.items():
    print(f"  {k:10s} {v}")
dq = np.abs(d1.qpos.numpy() - d3.qpos.numpy()).max(axis=1)
print("max |dqpos| per world:", [f"{v:.1e}" for v in dq])
