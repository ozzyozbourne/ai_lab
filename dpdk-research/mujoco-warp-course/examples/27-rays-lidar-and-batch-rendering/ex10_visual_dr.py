"""Example 27.10 - visual domain randomization: per-world colours and per-world field of view.

put_model(mjm, batch_sizes={...}) gives geom_rgba and cam_fovy a leading per-world axis; the
megakernel reads them at worldid % shape[0]. Colours just work. The field of view only works
with use_precomputed_rays=False: precomputed rays are built once from the MjModel's cam_fovy,
so every world would keep the same camera.
Run: python ex10_visual_dr.py [--dump-png DIR]
  --dump-png DIR  writes ex10_precomputed.png and ex10_dynamic.png (3 worlds side by side).
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

DR_SCENE = """
<mujoco model="visual_dr">
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1" directional="true"/>
    <camera name="c" pos="0 -3 0.5" xyaxes="1 0 0 0 0 1" fovy="45"/>
    <geom name="floor" type="plane" size="3 3 .1" rgba=".3 .3 .3 1"/>
    <geom name="s" type="sphere" pos="0 0 .5" size=".3" rgba="1 0 0 1"/>
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

NWORLD, W, H = 3, 32, 32
mjm = mujoco.MjModel.from_xml_string(DR_SCENE)
m = mjw.put_model(mjm, batch_sizes={"cam_fovy": NWORLD, "geom_rgba": NWORLD})
print("cam_fovy", m.cam_fovy.shape, "| geom_rgba", m.geom_rgba.shape, "(leading axis = worlds)")

fovy = m.cam_fovy.numpy()
fovy[:, 0] = [20.0, 45.0, 90.0]
m.cam_fovy.assign(fovy)
rgba = m.geom_rgba.numpy()
rgba[:, 1] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1]]      # sphere colour per world
m.geom_rgba.assign(rgba)

d = mjw.make_data(mjm, nworld=NWORLD)
mjw.forward(m, d)
strips = {}
for pre in (True, False):
    rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,
                                   render_depth=False, render_seg=True,
                                   use_precomputed_rays=pre)
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    seg = rc.seg_data.numpy()
    rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)
    mjw.get_rgb(rc, 0, rgb)
    strips[pre] = rgb.numpy()
    label = "use_precomputed_rays=True " if pre else "use_precomputed_rays=False"
    counts = [int((seg[w, :, 0] == 1).sum()) for w in range(NWORLD)]
    print(f"{label}: sphere pixels per world {counts} | ray buffer {rc.ray.shape[0]}")
print("fovy per world:", fovy[:, 0].tolist(), "| centre colour per world:",
      strips[False][:, 16, 16].astype(float).round(2).tolist())

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    for pre, name in ((True, "precomputed"), (False, "dynamic")):
        row = np.concatenate([np.pad(x, ((1, 1), (1, 1), (0, 0)), constant_values=1.0)
                              for x in strips[pre]], axis=1)
        save_png(os.path.join(args.dump_png, f"ex10_{name}.png"),
                 (np.clip(row, 0, 1) * 255).astype(np.uint8))
    print("wrote ex10_precomputed.png and ex10_dynamic.png to", args.dump_png)
