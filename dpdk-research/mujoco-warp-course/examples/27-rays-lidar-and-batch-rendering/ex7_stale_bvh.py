"""Example 27.7 - why refit_bvh: a moved sphere vanishes until the BVH is refit.

The render context builds its BVH from the model's initial pose. After the sphere moves
1 m to the side, render() still culls rays against the OLD bounding box, so the sphere is
not found at its new place (and its old box is empty). refit_bvh recomputes the boxes from
d.geom_xpos / d.geom_xmat and the sphere comes back.
Run: python ex7_stale_bvh.py [--dump-png DIR]
  --dump-png DIR  writes the three frames as ex7_frame{0,1,2}.png (Rule D flipbook).
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

BALL = """
<mujoco model="stale_bvh">
  <worldbody>
    <light dir="0 0 -1" pos="0 0 3" directional="true"/>
    <camera name="cam" pos="0 -3 0.5" xyaxes="1 0 0 0 0 1"/>
    <geom name="floor" type="plane" size="3 3 .1" rgba=".3 .3 .3 1"/>
    <body name="ball" pos="0 0 0.5"><freejoint/>
      <geom name="ball" type="sphere" size=".2" rgba="1 0 0 1"/></body>
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

W, H = 40, 30
mjm = mujoco.MjModel.from_xml_string(BALL)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
mjw.forward(m, d)
rc = mjw.create_render_context(mjm, nworld=1, cam_res=(W, H), render_rgb=True,
                               render_depth=False, render_seg=True)
ball = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_GEOM, "ball")
rgb = wp.zeros((1, H, W), dtype=wp.vec3)
frames = []


def frame(label):
    mjw.render(m, d, rc)
    seg = rc.seg_data.numpy()[0]
    mjw.get_rgb(rc, 0, rgb)
    frames.append((np.clip(rgb.numpy()[0], 0, 1) * 255).astype(np.uint8))
    lo, hi = rc.lower.numpy()[ball], rc.upper.numpy()[ball]
    print(f"{label:28s} sphere pixels {int((seg[:, 0] == ball).sum()):3d} | "
          f"BVH box x [{lo[0]:+.2f}, {hi[0]:+.2f}]")


frame("start (BVH built at qpos0):")
q = d.qpos.numpy()
q[0, 0] = 1.0                       # move the free body 1 m along +x
d.qpos.assign(q)
mjw.forward(m, d)                   # geom_xpos is now x = 1 ...
print("sphere geom_xpos after forward:", d.geom_xpos.numpy()[0, ball])
frame("moved, NO refit:")           # ... but the BVH box is still at x = 0
mjw.refit_bvh(m, d, rc)
frame("moved, after refit_bvh:")

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    for i, f in enumerate(frames):
        save_png(os.path.join(args.dump_png, f"ex7_frame{i}.png"), f)
    print("wrote 3 frames to", args.dump_png)
