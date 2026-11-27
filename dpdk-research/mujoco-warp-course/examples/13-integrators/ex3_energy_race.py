"""Example 13.3 - the energy race: Euler, RK4, implicit and implicitfast on an undamped pendulum.

The double pendulum has no damping and no control, so its total energy should stay constant.
Each integrator runs 6 s at dt = 0.02 from q = (1.2, 0). Energy is the [potential, kinetic] pair
in d.energy (the model enables <flag energy="enable"/>). We call mjw.forward before each sample so
every integrator reports the energy of its current state (see Example 13.6 for why that matters
under RK4).
Run: python ex3_energy_race.py [--dump-json PATH]
  --dump-json PATH writes energy curves and decimated joint angles for the page's chart and replay.
"""
import argparse
import json

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

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 1           # every world would be identical; the integrators run as separate models
DT, T_END = 0.02, 6.0
NSTEP = int(round(T_END / DT))   # 300
EVERY = 5                        # sample every 5 steps (0.1 s) for the chart and replay
INTEGRATORS = {"Euler": mjw.IntegratorType.EULER, "RK4": mjw.IntegratorType.RK4,
               "implicit": mjw.IntegratorType.IMPLICIT,
               "implicitfast": mjw.IntegratorType.IMPLICITFAST}

mjm = mujoco.MjModel.from_xml_string(PENDULUM)
mjm.opt.timestep = DT
energy, angles = {}, {}
for name, integ in INTEGRATORS.items():
    m = mjw.put_model(mjm)
    m.opt.integrator = integ
    d = mjw.make_data(mjm, nworld=NWORLD)
    d.qpos.assign(np.array([[1.2, 0.0]] * NWORLD))
    e_hist, q_hist = [], []
    for i in range(NSTEP + 1):
        if i % EVERY == 0:
            mjw.forward(m, d)                     # energy of the current state
            e_hist.append(float(d.energy.numpy()[0].sum()))
            q_hist.append([round(float(v), 3) for v in d.qpos.numpy()[0]])
        if i < NSTEP:
            mjw.step(m, d)
    energy[name], angles[name] = e_hist, q_hist

print(f"total energy [J] every 0.6 s, dt = {DT}, {NSTEP} steps")
for name, e in energy.items():
    print(f"{name:<13}", np.array2string(np.array(e[::6]), precision=3, max_line_width=200))
print(f"{'integrator':<13}{'E(0)':>8}{'E(6 s)':>9}{'change':>9}")
for name, e in energy.items():
    print(f"{name:<13}{e[0]:>8.3f}{e[-1]:>9.3f}{100 * (e[-1] - e[0]) / e[0]:>8.1f}%")

if args.dump_json:
    names = list(INTEGRATORS)
    out = {"nworld": len(names), "dt": DT * EVERY, "kind": "pendulum2d", "labels": names,
           "energy": {k: [round(v, 4) for v in e] for k, e in energy.items()},
           "frames": [[angles[k][f] for k in names] for f in range(len(angles[names[0]]))]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(out["frames"]), "frames")
