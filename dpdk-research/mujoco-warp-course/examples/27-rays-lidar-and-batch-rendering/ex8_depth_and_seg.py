"""Example 27.8 - depth is planar (z-depth), get_depth clamps, and seg holds (objid, objtype).

A camera 2 m above a floor looks straight down. Planar depth is the distance along the
optical axis, so every floor pixel reads 2.0 m, even in the corners where the ray itself is
longer. We check that with mjw.rays along the corner pixel's ray (rc.ray holds the precomputed
camera-frame directions). get_depth(rc, cam, scale, out) returns clamp(depth / scale, 0, 1):
fine for a picture, lossy for metric work. A small flex cloth shows objtype 9 (mjOBJ_FLEX).
Run: python ex8_depth_and_seg.py [--dump-png DIR]
  --dump-png DIR  writes ex8_depth.png and ex8_seg.png (colorized ids).
"""
import argparse
import os
import struct
import zlib

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.types import vec6     # private API: the geomgroup mask type

np.set_printoptions(precision=4, suppress=True)

TOP_DOWN = """
<mujoco model="top_down">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1" directional="true"/>
    <camera name="down" pos="0 0 2" xyaxes="1 0 0 0 1 0" fovy="60"/>
    <geom name="floor" type="plane" size="3 3 .1" rgba=".8 .8 .8 1"/>
    <geom name="block" type="box" pos=".4 .3 .25" size=".2 .2 .25" rgba=".2 .4 .9 1"/>
    <geom name="ball" type="sphere" pos="-.4 -.2 .3" size=".3" rgba=".9 .3 .2 1"/>
    <flexcomp name="cloth" type="grid" count="4 4 1" spacing=".12 .12 .12" pos="-.3 .45 .6"
              dim="2" radius=".01" rgba=".2 .8 .3 1">
      <edge equality="true"/>
    </flexcomp>
  </worldbody>
</mujoco>
"""


def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

W = H = 32
mjm = mujoco.MjModel.from_xml_string(TOP_DOWN)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=256)
rc = mjw.create_render_context(mjm, nworld=1, cam_res=(W, H), render_rgb=False,
                               render_depth=True, render_seg=True)
mjw.forward(m, d)
mjw.refit_bvh(m, d, rc)
mjw.render(m, d, rc)

metric = rc.depth_data.numpy()[0, :W * H].reshape(H, W)        # metres, 0 = miss
clamped = wp.zeros((1, H, W), dtype=float)
mjw.get_depth(rc, 0, 1.0, clamped)                              # clamp(depth / 1.0, 0, 1)
print(f"znear {rc.znear:.4f} m, zfar {rc.zfar:.2f} m (vis.map.znear/zfar x stat.extent)")
print("centre pixel: metric depth", round(float(metric[16, 16]), 4),
      "| get_depth(scale=1.0)", round(float(clamped.numpy()[0, 16, 16]), 4))
print("corner pixel: metric depth", round(float(metric[0, 0]), 4),
      "| floor pixels min/max depth", metric[metric > 1.99].min().round(4),
      metric[metric > 1.99].max().round(4))

# the same corner ray through the public ray API: Euclidean length vs planar depth
loc = rc.ray.numpy()[0]                                         # pixel (0,0), camera frame
R = d.cam_xmat.numpy()[0, 0]
pnt = wp.array([[d.cam_xpos.numpy()[0, 0]]], dtype=wp.vec3)
vec = wp.array([[R @ loc]], dtype=wp.vec3)
dist, gid, _ = mjw.ray(m, d, pnt, vec, geomgroup=vec6(-1, -1, -1, -1, -1, -1))
print("corner ray length", round(float(dist.numpy()[0, 0]), 4), "x cos(theta)",
      round(float(-loc[2]), 4), "=", round(float(dist.numpy()[0, 0] * -loc[2]), 4))

seg = rc.seg_data.numpy()[0, :W * H].reshape(H, W, 2)
pairs, counts = np.unique(seg.reshape(-1, 2), axis=0, return_counts=True)
names = {5: "mjOBJ_GEOM", 9: "mjOBJ_FLEX", -1: "background"}
for (oid, otype), c in zip(pairs.tolist(), counts.tolist()):
    if otype == 5:
        label = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, oid)
    elif otype == 9:
        label = mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_FLEX, oid)
    else:
        label = "-"
    print(f"(objid {oid:2d}, objtype {otype:2d} {names[otype]:10s}) {label:6s} {c:4d} px")
print("mjOBJ_GEOM =", int(mujoco.mjtObj.mjOBJ_GEOM),
      "| mjOBJ_FLEX =", int(mujoco.mjtObj.mjOBJ_FLEX))

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    dep = (np.clip(1.0 - (metric - 1.2) / 0.9, 0, 1) * 255).astype(np.uint8)   # near = bright
    dep[metric == 0] = 0
    save_png(os.path.join(args.dump_png, "ex8_depth.png"), dep[..., None].repeat(3, 2))
    rng = np.random.default_rng(42)                 # same idea as record.py's seg palette
    palette = rng.integers(40, 255, (16, 3)).astype(np.uint8)
    key = np.where(seg[..., 0] < 0, 0, seg[..., 0] + 1 + 8 * (seg[..., 1] == 9))
    img = palette[key % 16]
    img[seg[..., 0] < 0] = 0
    save_png(os.path.join(args.dump_png, "ex8_seg.png"), img)
    print("wrote ex8_depth.png and ex8_seg.png to", args.dump_png)
