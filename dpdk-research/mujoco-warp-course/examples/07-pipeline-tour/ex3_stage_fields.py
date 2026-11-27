"""Example 7.3 - measure which Data fields each stage reads and writes.

For every stage we (a) record the Data arrays passed as kernel inputs and outputs by wrapping
wp.launch / wp.launch_tiled with unittest.mock, and (b) compare every Data field before and after
the stage. This is a measured version of the stage -> Data cheat sheet.
Run: python ex3_stage_fields.py [--dump-json PATH]
  --dump-json PATH writes {stages: [{name, reads, writes, changed}]} for the page's interactive sheet.
"""
import argparse
import json
from unittest import mock

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 50
SETTLE = 150

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
run = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
run.ctrl.assign(np.linspace(-1.0, 1.0, NWORLD, dtype=np.float32).reshape(NWORLD, 1))
for _ in range(SETTLE):
    mjw.step(m, run)

d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)   # derived fields all zero
for name in ("qpos", "qvel", "ctrl"):
    wp.copy(getattr(d, name), getattr(run, name))


def data_fields(obj, prefix=""):
    """Map every wp.array in Data (and d.contact, d.efc) to its name."""
    out = {}
    for name, val in vars(obj).items():
        if isinstance(val, wp.array):
            out[prefix + name] = val
        elif name in ("contact", "efc"):
            out.update(data_fields(val, prefix + name + "."))
    return out


FIELDS = data_fields(d)
BY_PTR = {}
for name, arr in FIELDS.items():
    if arr.ptr is not None:
        BY_PTR.setdefault(arr.ptr, name)


def names(arrs):
    return {BY_PTR[a.ptr] for a in arrs if isinstance(a, wp.array) and a.ptr in BY_PTR}


def snapshot():
    return {k: v.numpy().copy() for k, v in FIELDS.items() if v.size}


STAGES = [  # public functions, in the order forward runs them (public factorize pairing)
    ("kinematics", mjw.kinematics), ("com_pos", mjw.com_pos), ("camlight", mjw.camlight),
    ("flex", mjw.flex), ("tendon", mjw.tendon), ("crb", mjw.crb), ("factor_m", mjw.factor_m),
    ("collision", mjw.collision), ("make_constraint", mjw.make_constraint),
    ("transmission", mjw.transmission), ("sensor_pos", mjw.sensor_pos),
    ("fwd_velocity", mjw.fwd_velocity), ("sensor_vel", mjw.sensor_vel),
    ("fwd_actuation", mjw.fwd_actuation), ("fwd_acceleration", mjw.fwd_acceleration),
    ("solve", mjw.solve), ("sensor_acc", mjw.sensor_acc), ("euler", mjw.euler),
]

real_launch, real_tiled = wp.launch, wp.launch_tiled
rows = []
for stage, fn in STAGES:
    reads, writes, nlaunch = set(), set(), [0]

    def spy(real):
        def wrapper(kernel, *a, **kw):
            nlaunch[0] += 1
            pos = a if "dim" in kw else a[1:]          # positional args after dim
            reads.update(names(kw.get("inputs", pos[0] if pos else [])))
            writes.update(names(kw.get("outputs", pos[1] if len(pos) > 1 else [])))
            return real(kernel, *a, **kw)
        return wrapper

    before = snapshot()
    with mock.patch.object(wp, "launch", spy(real_launch)), \
         mock.patch.object(wp, "launch_tiled", spy(real_tiled)):
        fn(m, d)
    after = snapshot()
    changed = sorted(k for k in after if not np.array_equal(before[k], after[k]))
    rows.append({"name": stage, "launches": nlaunch[0], "reads": sorted(reads - writes),
                 "writes": sorted(writes | set(changed)), "changed": changed})

print(f"PLAYGROUND, nworld={NWORLD}: Data fields per stage (reads = kernel inputs only)")
for r in rows:
    w = ", ".join(r["changed"]) or "-"
    print(f"{r['name']:<17} launches {r['launches']:>2} | changed: {w}")
print("fields written but unchanged (zero in this scene), e.g. fwd_velocity:",
      ", ".join(sorted(set(rows[11]["writes"]) - set(rows[11]["changed"]))[:6]))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"model": "PLAYGROUND", "nworld": NWORLD, "stages": rows}, f,
                  separators=(",", ":"))
    print("wrote", args.dump_json, len(rows), "stages")
