"""Example 7.7 - switch pipeline stages off with disable flags and watch the effect.

m.opt.disableflags is a Python int read when the step is dispatched, so you can change it between
steps (a change means different kernels run; a captured CUDA graph must be recaptured, Ch 24).
We run the same 100 steps with nothing disabled, then with GRAVITY, CONTACT and ACTUATION off.
Run: python ex7_disable_flags.py [--dump-json PATH]
  --dump-json PATH writes world 0's ball z, box z and hinge angle every 5 steps, per setting.
"""
import argparse
import json

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 100                     # 1 s at timestep 0.01

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
m = mjw.put_model(mjm)
HINGE_QPOS = 14                  # ball qpos 0..6, box qpos 7..13, hinge 14

series = {}
print(f"nworld={NWORLD}, {NSTEP} steps, motor ctrl = 0.5 in every world")
print(f"{'disabled':<12}{'ball z':>9}{'box z':>9}{'hinge q':>10}{'nacon':>7}{'nefc[0]':>9}")
for label, flag in (("nothing", 0), ("GRAVITY", mjw.DisableBit.GRAVITY),
                    ("CONTACT", mjw.DisableBit.CONTACT), ("ACTUATION", mjw.DisableBit.ACTUATION),
                    ("CONSTRAINT", mjw.DisableBit.CONSTRAINT)):
    m.opt.disableflags = int(flag)
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
    d.ctrl.fill_(0.5)
    frames = []
    for i in range(NSTEP):
        mjw.step(m, d)
        if args.dump_json and i % 5 == 4:          # host read for the figure only
            q0 = d.qpos.numpy()[0]
            frames.append([round(float(q0[2]), 3), round(float(q0[9]), 3),
                           round(float(q0[HINGE_QPOS]), 3)])
    series[label] = frames
    q = d.qpos.numpy()
    print(f"{label:<12}{q[0, 2]:9.3f}{q[0, 9]:9.3f}{q[0, HINGE_QPOS]:10.3f}"
          f"{int(d.nacon.numpy()[0]):7d}{int(d.nefc.numpy()[0]):9d}")
    assert not d.overflow.numpy().any()
m.opt.disableflags = 0
print("all worlds identical:", bool(np.allclose(q, q[0])))
print("overflow: none")

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"dt": 5 * float(mjm.opt.timestep), "fields": ["ball z", "box z", "hinge q"],
                   "series": series}, f, separators=(",", ":"))
    print("wrote", args.dump_json)
