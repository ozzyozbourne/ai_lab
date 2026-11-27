"""Example 10.4 - per-world friction: the same box slides down the same slope NWORLD ways.

geom_friction is a "*" field. We allocate one row per world with put_model(batch_sizes=...) and
write a friction in [0.1, 1.0] into every row, dealt out to the worlds in shuffled order
(as a random DR draw would be). The contact kernels read
geom_friction[worldid % geom_friction.shape[0], geom] (collision_core.py::contact_material_params)
and mix the two geoms with an element-wise MAX, so we set the box AND the plane to the same value.
Run: python ex4_friction_slide.py [--dump-json PATH]
  --dump-json PATH writes decimated per-world slide distances for the page's DR mosaic (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=3, suppress=True)

SLOPE_DEG = 30.0
n = np.array([np.sin(np.radians(SLOPE_DEG)), 0.0, np.cos(np.radians(SLOPE_DEG))])  # plane normal
p0 = 0.101 * n                                    # box centre: half-size + 1 mm above the plane
SLOPE = f"""
<mujoco model="slope">
  <option timestep="0.005"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="slope" type="plane" size="5 5 .1" euler="0 {SLOPE_DEG} 0"/>
    <body name="box" pos="{p0[0]:.5f} 0 {p0[2]:.5f}" euler="0 {SLOPE_DEG} 0">
      <freejoint/>
      <geom name="box" type="box" size=".1 .1 .1" mass="1" rgba=".3 .3 1 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 16
NSTEP = 200                                       # 1 s

mjm = mujoco.MjModel.from_xml_string(SLOPE)
m = mjw.put_model(mjm, batch_sizes={"geom_friction": NWORLD})
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)

mu = np.random.default_rng(0).permutation(np.linspace(0.1, 1.0, NWORLD))   # shuffled over worlds
fr = m.geom_friction.numpy()                      # (NWORLD, ngeom, 3): slide, spin, roll
fr[:, :, 0] = mu[:, None]                         # same sliding friction for slope and box
m.geom_friction.assign(fr)
print("geom_friction shape:", m.geom_friction.shape)

x0 = d.qpos.numpy()[:, :3].copy()
frames = []
for i in range(NSTEP):
    mjw.step(m, d)
    if args.dump_json and i % 5 == 4:             # decimate to 40 frames (reads to host: demo only)
        frames.append([round(float(v), 3) for v in
                       np.linalg.norm(d.qpos.numpy()[:, :3] - x0, axis=1)])
wp.synchronize()

dist = np.linalg.norm(d.qpos.numpy()[:, :3] - x0, axis=1)
tan = np.tan(np.radians(SLOPE_DEG))
print(f"slope {SLOPE_DEG:.0f} deg: a box slides when mu < tan(slope) = {tan:.3f}")
for w in range(0, NWORLD, max(1, NWORLD // 16)):
    pred = max(0.0, 0.5 * 9.81 * (np.sin(np.radians(SLOPE_DEG)) - mu[w] * np.cos(np.radians(SLOPE_DEG))))
    print(f"  world {w:4d}  mu = {mu[w]:.2f}  slide = {dist[w]:.3f} m   (Coulomb: {pred:.3f} m)")
order = np.argsort(mu)                            # worlds sorted by friction
print("monotone (non-increasing) in mu:", bool(np.all(np.diff(dist[order]) <= 1e-3)))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nworld": NWORLD, "dt": 5 * float(mjm.opt.timestep), "kind": "slide",
                   "slope_deg": SLOPE_DEG, "labels": [f"mu={v:.2f}" for v in mu],
                   "mu": [round(float(v), 3) for v in mu], "frames": frames},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json, len(frames), "frames")
