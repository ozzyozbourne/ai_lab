"""Example 8.5 - per-world mocap targets: a kernel moves each world's target on its own circle.

MOCAP_TARGET: a mocap body "target" and a free box welded to it. Every step a Warp kernel
writes d.mocap_pos[world, 0] (radius grows with the world index); the weld drags the box along.
Run: python ex05_mocap_targets.py [--dump-json PATH]
  --dump-json PATH writes decimated target and box positions per world (Rule D, mocap replay).
"""
import argparse
import json
import math

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

MOCAP_TARGET = """
<mujoco model="mocap_target">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="target" mocap="true" pos="0 0 0.5">
      <geom type="box" size=".05 .05 .05" contype="0" conaffinity="0" rgba="0 1 0 .3"/>
    </body>
    <body name="box" pos="0 0 0.5">
      <freejoint/>
      <geom name="box" type="box" size=".05 .05 .05" mass="0.5" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
  <equality><weld body1="box" body2="target" solref="0.02 1"/></equality>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
T_END = 2.0  # seconds


@wp.kernel
def circle_targets(time_in: wp.array[float], r_min: float, r_step: float, omega: float,
                   mocap_pos_out: wp.array2d[wp.vec3]):
    worldid = wp.tid()                       # one thread per world
    r = r_min + r_step * float(worldid % 8)  # radius depends on the world (8 distinct radii)
    t = time_in[worldid]
    mocap_pos_out[worldid, 0] = wp.vec3(r * wp.cos(omega * t), r * wp.sin(omega * t), 0.5)


mjm = mujoco.MjModel.from_xml_string(MOCAP_TARGET)
print("nmocap:", mjm.nmocap, "| neq:", mjm.neq, "| nq:", mjm.nq, "| nv:", mjm.nv)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)
print("d.mocap_pos shape:", d.mocap_pos.shape, "| d.mocap_quat shape:", d.mocap_quat.shape)
box = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "box")
target = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "target")

omega = 2 * math.pi / T_END  # one lap in T_END seconds
nstep = int(round(T_END / mjm.opt.timestep))
frames = []
for i in range(nstep):
    wp.launch(circle_targets, dim=d.nworld, inputs=[d.time, 0.05, 0.05, omega],
              outputs=[d.mocap_pos])
    mjw.step(m, d)
    if args.dump_json and i % 8 == 0:  # decimate (host read: demo only)
        xp = d.xpos.numpy()[:8]
        frames.append([[round(float(v), 3) for v in (*xp[w, target, :2], *xp[w, box, [0, 2]],
                                                     xp[w, box, 1])] for w in range(8)])
wp.synchronize()

xpos = d.xpos.numpy()
dist = np.linalg.norm(xpos[:, box] - xpos[:, target], axis=1)
r = 0.05 + 0.05 * (np.arange(NWORLD) % 8)
print(f"after {nstep} steps ({T_END:.1f} s):")
print("target radius   [m] =", r[:8])
print("target speed  [m/s] =", r[:8] * omega)
print("box-target dist [m] =", dist[:8])
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": 8, "dt": 8 * float(mjm.opt.timestep), "kind": "mocap",
                   "labels": ["target x", "target y", "box x", "box z", "box y"],
                   "radius": [round(float(v), 3) for v in r[:8]], "frames": frames},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
