"""Example 27.13 - Gaussian splats next to meshes, with a different splat set per world.

N random 3-D Gaussians are made in NumPy (no PLY file needed): group 0 is a warm cloud, group 1
a cool cloud. splat_adr = [0, n0, n0 + n1] cuts the arrays into groups and
splat_group_id[w] says which group world w sees. Splats are composited front to back along
each ray (render.py::shade_splats); solid geometry in front hides them.
Run: python ex13_splats.py [--dump-png DIR]
  --dump-png DIR  writes ex13_splats.png (world 0 | world 1, without and with splats).
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

np.set_printoptions(precision=3, suppress=True)

SPLAT_SCENE = """
<mujoco model="splat_scene">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1" directional="true"/>
    <camera name="cam" pos="0 -3 .6" xyaxes="1 0 0 0 0 1"/>
    <geom name="floor" type="plane" size="3 3 .1" rgba=".5 .5 .5 1"/>
    <geom name="post" type="cylinder" pos=".25 -1 .3" size=".08 .3" rgba=".9 .9 .2 1"/>
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


def cloud(rng, n, centre, rgb):
    pos = centre + rng.normal(0, 0.18, (n, 3))
    q = rng.normal(size=(n, 4))
    q /= np.linalg.norm(q, axis=1, keepdims=True)               # unit quaternions (w, x, y, z)
    scale = rng.uniform(0.03, 0.09, (n, 3))                     # standard deviations [m]
    rgba = np.concatenate([np.clip(rgb + rng.normal(0, 0.08, (n, 3)), 0, 1),
                           rng.uniform(0.4, 0.9, (n, 1))], 1)   # colour + opacity
    return pos, q, scale, rgba


parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
N = 2000 if ON_GPU else 150                                     # splats per group
NWORLD, W, H = 2, 32, 32
rng = np.random.default_rng(0)
g0 = cloud(rng, N, np.array([-0.3, 0.0, 0.6]), np.array([1.0, 0.5, 0.1]))
g1 = cloud(rng, N, np.array([0.3, 0.0, 0.6]), np.array([0.1, 0.5, 1.0]))
pos, rot, scale, rgba = (np.concatenate([a, b]).astype(np.float32) for a, b in zip(g0, g1))
splat_adr = np.array([0, N, 2 * N], dtype=np.int32)             # group k = [adr[k], adr[k+1])
splat_group_id = np.array([0, 1], dtype=np.int32)               # world 0 -> group 0, world 1 -> 1

mjm = mujoco.MjModel.from_xml_string(SPLAT_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
mjw.forward(m, d)
images = {}
for label, kw in (("no splats", {}),
                  ("splats", dict(splat_position=pos, splat_rotation=rot, splat_scale=scale,
                                  splat_rgba=rgba, splat_adr=splat_adr,
                                  splat_group_id=splat_group_id))):
    rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,
                                   render_depth=True, render_seg=True, **kw)
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    img = wp.zeros((NWORLD, H, W), dtype=wp.vec3)
    mjw.get_rgb(rc, 0, img)
    images[label] = img.numpy()
    roots = rc.splat_group_root.numpy().tolist() if rc.splat_count else "unused"  # BVH node/world
    print(f"{label:9s}: splat_count {rc.splat_count:4d} | splat_group_root {roots!s:10s} | "
          f"mean RGB w0 {img.numpy()[0].mean((0, 1))} w1 {img.numpy()[1].mean((0, 1))}")

diff = np.any(np.abs(images["splats"] - images["no splats"]) > 1 / 255, axis=-1)
print("pixels changed by splats per world:", diff.reshape(NWORLD, -1).sum(1).tolist())
left, right = diff[:, :, :W // 2].sum((1, 2)), diff[:, :, W // 2:].sum((1, 2))
print("changed pixels left/right half: world 0", [int(left[0]), int(right[0])],
      "| world 1", [int(left[1]), int(right[1])])
seg = rc.seg_data.numpy()[:, :W * H, 0]
print("seg ignores splats (geom ids only):", np.unique(seg).tolist())

# move group 0 up by 0.2 m: edit the splat arrays, then refit the splat BVH
p = rc.splat_position.numpy()
p[:N, 2] += 0.2
rc.splat_position.assign(p)
mjw.refit_splat_bvh(rc)
mjw.render(m, d, rc)
moved = wp.zeros((NWORLD, H, W), dtype=wp.vec3)
mjw.get_rgb(rc, 0, moved)
changed = np.any(np.abs(moved.numpy() - images["splats"]) > 1 / 255, axis=-1)
print("after moving group 0 + refit_splat_bvh, changed pixels per world:",
      changed.reshape(NWORLD, -1).sum(1).tolist())

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    tiles = [images["no splats"][0], images["splats"][0], images["no splats"][1],
             images["splats"][1]]
    row = np.concatenate([np.pad(t, ((1, 1), (1, 1), (0, 0)), constant_values=1.0)
                          for t in tiles], axis=1)
    save_png(os.path.join(args.dump_png, "ex13_splats.png"),
             (np.clip(row, 0, 1) * 255).astype(np.uint8))
    print("wrote ex13_splats.png to", args.dump_png)
