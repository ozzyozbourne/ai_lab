"""Example 27.5 - render every world at once: RGB, depth and segmentation in a grid.

The four calls: create_render_context (once) -> forward -> refit_bvh -> render, then
get_rgb / get_depth / get_segmentation unpack one camera into (nworld, H, W) arrays.
GPU: 16 worlds at 128x128; CPU: 4 worlds at 32x32.
Run: python ex5_grid16.py [--dump-png DIR]
  --dump-png DIR  writes ex5_rgb_grid.png and ex5_depth_grid.png (Rule D images for the page).
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

RENDER_SCENE = """
<mujoco model="render_scene">
  <option timestep="0.01666"/>
  <worldbody>
    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>
    <camera name="camera" pos="0 2 0" quat="0 0 1 1" resolution="128 128"/>
    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>
    <body name="box_and_sphere" euler="0 0 -30">
      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>
      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>
      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>
    </body>
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


def tile(images, cols):
    """(n, H, W, C) -> one (rows*H, cols*W, C) image, world 0 top-left, row-major."""
    n, h, w, c = images.shape
    rows = n // cols
    return images[:rows * cols].reshape(rows, cols, h, w, c).transpose(0, 2, 1, 3, 4).reshape(
        rows * h, cols * w, c)


parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

ON_GPU = wp.get_device().is_cuda
NWORLD = 16 if ON_GPU else 4
W, H = (128, 128) if ON_GPU else (32, 32)
COLS = int(np.sqrt(NWORLD))

mjm = mujoco.MjModel.from_xml_string(RENDER_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H),   # (width, height)!
                               render_rgb=True, render_depth=True, render_seg=True)

qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 0] = np.linspace(0.0, 2 * np.pi, NWORLD, endpoint=False)   # a different swing per world
d.qpos.assign(qpos.astype(np.float32))
mjw.forward(m, d)                # geom_xpos/xmat and cam_xpos/xmat for the new qpos
mjw.refit_bvh(m, d, rc)          # boxes follow the new poses
mjw.render(m, d, rc)             # ONE launch: dim = (nworld, total_rays)

rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)      # (nworld, height, width)
depth = wp.zeros((NWORLD, H, W), dtype=float)
seg = wp.zeros((NWORLD, H, W), dtype=wp.vec2i)
mjw.get_rgb(rc, 0, rgb)                           # camera_index 0 = first ACTIVE camera
mjw.get_depth(rc, 0, 3.0, depth)                  # depth / 3.0, clamped to [0, 1]
mjw.get_segmentation(rc, 0, seg)

img, dep, sg = rgb.numpy(), depth.numpy(), seg.numpy()
print(f"device {wp.get_device()} | nworld {NWORLD} | cam_res {rc.cam_res.numpy()[0]} (W, H)")
print("rgb", img.shape, img.dtype, "| depth", dep.shape, "| seg", sg.shape, sg.dtype)
print("mean RGB per world:", img.reshape(NWORLD, -1, 3).mean(1)[:4])
print("mean depth/3 per world:", dep.reshape(NWORLD, -1).mean(1)[:4])
for w in range(min(NWORLD, 4)):
    ids, counts = np.unique(sg[w, :, :, 0], return_counts=True)
    print(f"world {w} geom pixel counts:", dict(zip(ids.tolist(), counts.tolist())))

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    grid = (np.clip(tile(img, COLS), 0, 1) * 255).astype(np.uint8)
    save_png(os.path.join(args.dump_png, "ex5_rgb_grid.png"), grid)
    dgrid = (np.clip(tile(dep[..., None], COLS), 0, 1) * 255).astype(np.uint8).repeat(3, 2)
    save_png(os.path.join(args.dump_png, "ex5_depth_grid.png"), dgrid)
    print("wrote", grid.shape, "grids to", args.dump_png)
