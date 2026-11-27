"""Example 18.2 - build a 32 x 32 random-noise heightfield with MjSpec and drop 16 balls on it.

The terrain is smoothed random noise in [0, 1] (MuJoCo scales it by size[2] = 0.3 m). Each world
drops 16 balls from its own random (x, y) grid, so the worlds end in different places. We print
the default buffer sizes that io.py's heuristic picks for a model with an hfield, the explicit
sizes we use instead, a histogram of the final ball heights, the contact and row counts (at the
end and the peak over the run) and the overflow status.
Run: python ex2_hfield_spec.py [--dump-json PATH]
  --dump-json PATH writes the elevation grid and the world-0 ball tracks for the page figure.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8
NSTEP = 1000 if ON_GPU else 300
NROW = NCOL = 32
NBALL = 16
SIZE = [1.0, 1.0, 0.3, 0.1]          # x half-size, y half-size, max elevation, base depth


def noise_terrain(nrow, ncol, seed=0):
    """Random noise, smoothed by a 5x5 box filter (with wrap-around), rescaled to [0, 1]."""
    rng = np.random.default_rng(seed)
    z = rng.random((nrow, ncol))
    k = 2
    z = sum(np.roll(np.roll(z, i, 0), j, 1) for i in range(-k, k + 1) for j in range(-k, k + 1))
    return (z - z.min()) / (z.max() - z.min())


def build(elev):
    spec = mujoco.MjSpec()
    spec.option.timestep = 0.005
    hf = spec.add_hfield(name="noise", nrow=NROW, ncol=NCOL, size=SIZE)
    hf.userdata = elev.ravel().tolist()     # row-major: row r is y, column c is x
    spec.worldbody.add_light(pos=[0, 0, 3], dir=[0, 0, -1])
    spec.worldbody.add_geom(name="terrain", type=mujoco.mjtGeom.mjGEOM_HFIELD, hfieldname="noise")
    for i in range(NBALL):
        b = spec.worldbody.add_body(name=f"ball{i}", pos=[0, 0, 0.6 + 0.02 * i])
        b.add_freejoint()
        b.add_geom(type=mujoco.mjtGeom.mjGEOM_SPHERE, size=[0.05, 0, 0])
    return spec.compile()


elev = noise_terrain(NROW, NCOL)
mjm = build(elev)
m = mjw.put_model(mjm)
print(f"hfield {mjm.hfield_nrow[0]}x{mjm.hfield_ncol[0]}, nbody {mjm.nbody}, nv {mjm.nv}, "
      f"ngeom {mjm.ngeom}")

d_default = mjw.make_data(mjm, nworld=NWORLD)
print(f"default sizes (io.py heuristic): nconmax {d_default.naconmax // NWORLD} per world, "
      f"njmax {d_default.njmax}")
del d_default
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=96, njmax=384)
print(f"explicit sizes: nconmax 96 per world (naconmax {d.naconmax}), njmax {d.njmax}")

# per-world drop positions: a jittered 4 x 4 grid inside the terrain
rng = np.random.default_rng(1)
qpos = np.tile(mjm.qpos0, (NWORLD, 1)).astype(np.float32)
ticks = np.linspace(-0.6, 0.6, 4)
grid = np.stack(np.meshgrid(ticks, ticks), -1).reshape(-1, 2)
for w in range(NWORLD):
    xy = grid + rng.uniform(-0.12, 0.12, size=grid.shape)
    for i in range(NBALL):
        qpos[w, 7 * i:7 * i + 2] = xy[i]
d.qpos.assign(qpos)

tracks = []
peak_nacon = peak_nefc = 0          # running maxima (Ch 9 recipe): the landing needs the most
for step in range(NSTEP):
    mjw.step(m, d)
    peak_nacon = max(peak_nacon, int(d.nacon.numpy()[0]))       # host reads: sizing run only
    peak_nefc = max(peak_nefc, int(d.nefc.numpy().max()))
    if args.dump_json and step % 10 == 0:       # host reads for the figure only
        tracks.append(d.qpos.numpy()[0].reshape(NBALL, 7)[:, :3].astype(float).round(3).tolist())
wp.synchronize()

z = d.qpos.numpy().reshape(NWORLD, NBALL, 7)[:, :, 2].ravel()
counts, edges = np.histogram(z, bins=6, range=(0.0, 0.42))
off = int((z < 0.0).sum())
print(f"final ball heights over {NWORLD} worlds x {NBALL} balls "
      f"({off} rolled off the terrain edge and fell, z < 0):")
for c, lo, hi in zip(counts, edges[:-1], edges[1:]):
    print(f"  z in [{lo:.2f}, {hi:.2f}): {c:3d} " + "#" * int(c // 2))
nacon = int(d.nacon.numpy()[0])
print(f"at the end (balls at rest): nacon {nacon} of naconmax {d.naconmax}; "
      f"nefc per world max {int(d.nefc.numpy().max())}")
print(f"peak over all {NSTEP} steps:  nacon {peak_nacon}; nefc per world max {peak_nefc} of njmax {d.njmax}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

if args.dump_json:
    with open(args.dump_json, "w") as f:
        json.dump({"nrow": NROW, "ncol": NCOL, "size": SIZE, "dt": 10 * mjm.opt.timestep,
                   "elev": elev.round(3).tolist(), "tracks": tracks, "radius": 0.05,
                   "hist": {"counts": counts.tolist(), "edges": edges.round(3).tolist()}},
                  f, separators=(",", ":"))
    print("wrote", args.dump_json)
