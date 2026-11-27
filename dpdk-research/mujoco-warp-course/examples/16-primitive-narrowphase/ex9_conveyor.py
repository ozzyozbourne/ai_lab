"""Example 16.9 - a conveyor belt with surface velocity, one belt speed per world.

The floor geom has surfacevel = (vx, vy, vz, wx, wy, wz) in its local frame. After the
narrowphase, collision_driver._contact_surfacevel turns it into contact.surfacevel
(tangent1, tangent2, spin components in the contact frame), and constraint._add_surface_vel adds
it to efc.Jqvel of the friction rows, so friction drags the box toward the belt speed. The
surface itself does not move. geom_surfacevel is a batched field, so every world gets its own
belt speed with put_model(batch_sizes=...). This only works because the XML already gives the
belt a nonzero surfacevel: m.flg_surfacevel is fixed at put_model, and with it False both
surface-velocity kernels are skipped, so per-world values would be silently ignored.
Run: python ex9_conveyor.py [--dump-json PATH]
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

CONVEYOR = """
<mujoco model="conveyor">
  <option timestep="0.002"/>
  <worldbody>
    <geom name="belt" type="plane" size="5 5 .1" surfacevel=".5 0 0  0 0 0"/>
    <body name="box" pos="0 0 0.1">
      <freejoint/>
      <geom name="box" type="box" size="0.1 0.1 0.1" mass="1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

SPEEDS = np.array([0.25, 0.5, 1.0, -0.5], dtype=np.float32)   # belt vx per world
NWORLD = len(SPEEDS)
NSTEP = 300

mjm = mujoco.MjModel.from_xml_string(CONVEYOR)
m = mjw.put_model(mjm, batch_sizes={"geom_surfacevel": NWORLD})
sv = m.geom_surfacevel.numpy()                      # (nworld, ngeom) of vec6
sv[:, 0, 0] = SPEEDS
m.geom_surfacevel.assign(sv)
print("m.flg_surfacevel:", m.flg_surfacevel, "| geom_surfacevel shape:", m.geom_surfacevel.shape)

d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=48)
frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    if (i + 1) % 50 == 0:
        print(f"step {i + 1:3d}  box vx per world:", d.qvel.numpy()[:, 0])
    if args.dump_json and i % 5 == 0:                # decimated (host reads: demo only)
        q = d.qpos.numpy()
        frames.append([[round(float(q[w, 0]), 3), round(float(d.qvel.numpy()[w, 0]), 3)]
                       for w in range(NWORLD)])
wp.synchronize()

print("belt speed per world:  ", SPEEDS)
print("final vx, 8 digits:    ", [f"{v:.8f}" for v in d.qvel.numpy()[:, 0]])
n = min(int(d.nacon.numpy()[0]), d.naconmax)
wid = d.contact.worldid.numpy()[:n]
svel = d.contact.surfacevel.numpy()[:n]
frame = d.contact.frame.numpy()[:n]
for w in range(NWORLD):
    i = np.where(wid == w)[0][0]
    print(f"w{w} contact.surfacevel {svel[i]}  tangent1 {frame[i, 1]}  tangent2 {frame[i, 2]}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": 5 * float(mjm.opt.timestep),
                   "speeds": SPEEDS.tolist(), "frames": frames}, f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
