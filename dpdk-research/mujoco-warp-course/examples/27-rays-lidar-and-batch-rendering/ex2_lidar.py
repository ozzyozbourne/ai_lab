"""Example 27.2 - a 360-ray horizontal lidar in every world with mjw.rays.

Each world puts the robot at its own (x, y, yaw). A small Warp kernel turns d.xpos / d.xmat of
the robot body into per-world ray origins and directions (no host round trip), then one
mjw.rays call casts nworld x 360 rays. bodyexclude keeps the lidar from seeing its own body.
Run: python ex2_lidar.py [--dump-json PATH]
  --dump-json PATH  writes the ranges and the room layout for the page's polar plots (Rule D).
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec6     # private API: the geomgroup mask type

np.set_printoptions(precision=3, suppress=True)

ROOM = """
<mujoco model="lidar_room">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <geom name="floor" type="plane" size="3 3 .1"/>
    <geom name="wall_e" type="box" pos=" 2 0 .5" size=".05 2 .5"/>
    <geom name="wall_w" type="box" pos="-2 0 .5" size=".05 2 .5"/>
    <geom name="wall_n" type="box" pos="0  2 .5" size="2 .05 .5"/>
    <geom name="wall_s" type="box" pos="0 -2 .5" size="2 .05 .5"/>
    <geom name="pillar_a" type="cylinder" pos=" 1 1 .4" size=".2 .4"/>
    <geom name="pillar_b" type="cylinder" pos="-1 .5 .4" size=".15 .4"/>
    <geom name="crate" type="box" pos="0 -1 .2" size=".3 .2 .2" euler="0 0 30"/>
    <body name="robot" pos="0 0 .15"><freejoint/>
      <geom name="robot" type="cylinder" size=".15 .15" rgba=".2 .7 .3 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 4
NRAY = 360


@wp.kernel
def lidar_rays(xpos: wp.array2d(dtype=wp.vec3), xmat: wp.array2d(dtype=wp.mat33), body: int,
               local_dir: wp.array(dtype=wp.vec3),
               pnt_out: wp.array2d(dtype=wp.vec3), vec_out: wp.array2d(dtype=wp.vec3)):
    worldid, rayid = wp.tid()                       # launch shape (nworld, nray)
    pnt_out[worldid, rayid] = xpos[worldid, body]   # lidar at the body origin
    vec_out[worldid, rayid] = xmat[worldid, body] @ local_dir[rayid]   # body frame -> world


mjm = mujoco.MjModel.from_xml_string(ROOM)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)
robot = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "robot")

# per-world pose: (x, y, yaw); repeat a pattern of 4 so every GPU world is valid too
poses = np.array([[0.0, 0.0, 0.0], [1.2, -1.2, 45.0], [-1.4, 1.3, 90.0], [0.6, 0.9, 180.0]])
pose = poses[np.arange(NWORLD) % 4]
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 0:2] = pose[:, :2]
qpos[:, 3] = np.cos(np.radians(pose[:, 2]) / 2)   # quaternion (w, x, y, z) about z
qpos[:, 6] = np.sin(np.radians(pose[:, 2]) / 2)
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)

ang = np.radians(np.arange(NRAY))                   # 1 degree per ray, in the body frame
local_dir = wp.array(np.stack([np.cos(ang), np.sin(ang), np.zeros(NRAY)], 1), dtype=wp.vec3)
pnt = wp.zeros((NWORLD, NRAY), dtype=wp.vec3)
vec = wp.zeros((NWORLD, NRAY), dtype=wp.vec3)
wp.launch(lidar_rays, dim=(NWORLD, NRAY), inputs=[d.xpos, d.xmat, robot, local_dir],
          outputs=[pnt, vec])

dist = wp.zeros((NWORLD, NRAY), dtype=float)
geomid = wp.zeros((NWORLD, NRAY), dtype=int)
normal = wp.zeros((NWORLD, NRAY), dtype=wp.vec3)
allgroups = vec6(-1, -1, -1, -1, -1, -1)            # all -1: no group filtering

# without bodyexclude the origin is inside the robot's own cylinder
no_excl = wp.full(NRAY, -1, dtype=int)
mjw.rays(m, d, pnt, vec, allgroups, True, no_excl, dist, geomid, normal)
print("without bodyexclude, min range per world:", dist.numpy()[:4].min(1))

excl = wp.full(NRAY, robot, dtype=int)              # per-ray body to ignore
mjw.rays(m, d, pnt, vec, allgroups, True, excl, dist, geomid, normal)
r = dist.numpy()
g = geomid.numpy()
print("rays per call:", NWORLD * NRAY, "| output shape:", r.shape)
for w in range(4):
    k = int(np.argmin(np.where(r[w] < 0, np.inf, r[w])))
    name = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, int(g[w, k]))
    print(f"world {w} pose {pose[w]}: min range {r[w, k]:.3f} m at body angle {k:3d} deg "
          f"({name}), misses {int((r[w] < 0).sum())}")
print("world 0 ranges at 0/90/180/270 deg:", r[0, [0, 90, 180, 270]])

if args.dump_json:
    geoms = []
    for i in range(mjm.ngeom):
        t = int(mjm.geom_type[i])
        if t in (mujoco.mjtGeom.mjGEOM_BOX, mujoco.mjtGeom.mjGEOM_CYLINDER) and i != 0:
            yaw = float(np.degrees(2 * np.arctan2(mjm.geom_quat[i, 3], mjm.geom_quat[i, 0])))
            geoms.append({"name": mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, i),
                          "type": "box" if t == mujoco.mjtGeom.mjGEOM_BOX else "cyl",
                          "pos": [round(float(v), 3) for v in mjm.geom_pos[i][:2]],
                          "size": [round(float(v), 3) for v in mjm.geom_size[i][:2]],
                          "yaw": round(yaw, 2)})
    out = {"nworld": 4, "nray": NRAY, "poses": pose[:4].tolist(),
           "ranges": [[round(float(v), 3) for v in r[w]] for w in range(4)],
           "gid": [g[w].tolist() for w in range(4)],
           "names": [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, i) for i in range(mjm.ngeom)],
           "geoms": [x for x in geoms if x["name"] != "robot"]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
