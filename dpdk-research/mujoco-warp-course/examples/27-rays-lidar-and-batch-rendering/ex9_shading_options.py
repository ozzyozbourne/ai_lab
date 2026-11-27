"""Example 27.9 - shadows and supersampling are creation-time options of the render context.

Same scene, three contexts: plain, use_shadows=True, and samples_per_pixel=2. A shadow ray
(any-hit, from the hit point toward the light) that is blocked scales that light by
shadow_light_fraction (default 0.3). samples_per_pixel=n casts n x n sub-pixel rays and
averages the colour; the precomputed ray buffer grows to total_rays * n * n.
Run: python ex9_shading_options.py [--dump-png DIR]
  --dump-png DIR  writes ex9_plain.png, ex9_shadow.png and ex9_ssaa.png.
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

SHADOW_SCENE = """
<mujoco model="shadow_scene">
  <visual><headlight active="0"/></visual>
  <worldbody>
    <light name="sun" pos="0 0 3" dir=".6 0 -1" directional="true" castshadow="true"/>
    <camera name="down" pos="0 0 3" xyaxes="1 0 0 0 1 0" fovy="50"/>
    <geom name="floor" type="plane" size="3 3 .1" rgba=".8 .8 .8 1"/>
    <geom name="block" type="box" pos="-.3 0 .4" size=".2 .2 .4" euler="0 0 20"
          rgba=".2 .4 .9 1"/>
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
mjm = mujoco.MjModel.from_xml_string(SHADOW_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1)
mjw.forward(m, d)
images = {}
for label, opts in (("plain", {}), ("shadow", {"use_shadows": True}),
                    ("ssaa", {"samples_per_pixel": 2})):
    rc = mjw.create_render_context(mjm, nworld=1, cam_res=(W, H), render_rgb=True,
                                   render_depth=False, render_seg=True, **opts)
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    out = wp.zeros((1, H, W), dtype=wp.vec3)
    mjw.get_rgb(rc, 0, out)
    images[label] = out.numpy()[0]
    seg = rc.seg_data.numpy()[0, :W * H].reshape(H, W, 2)
    print(f"{label:6s} total_rays {rc.total_rays} | ray buffer {rc.ray.shape[0]:5d} | "
          f"aa_accum {rc.aa_accum.shape}")

floor = seg[..., 0] == 0                            # seg is identical in all three contexts
plain, shadow, ssaa = images["plain"], images["shadow"], images["ssaa"]
changed = np.any(np.abs(shadow - plain) > 1e-6, axis=-1)
in_shadow = changed & floor
ratio = shadow[in_shadow, 0] / plain[in_shadow, 0]
print("pixels changed by use_shadows:", int(changed.sum()), "of", W * H,
      "| shadowed floor pixels:", int(in_shadow.sum()))
print("shadowed / lit floor red channel:", np.round(np.median(ratio), 3),
      "(shadow_light_fraction = 0.3)")
edge = np.any(np.abs(ssaa - plain) > 1e-6, axis=-1)
print("pixels changed by samples_per_pixel=2:", int(edge.sum()),
      "| distinct colours plain vs 2x2:", len(np.unique(plain.reshape(-1, 3), axis=0)),
      len(np.unique(ssaa.reshape(-1, 3), axis=0)))

if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    for k, v in images.items():
        save_png(os.path.join(args.dump_png, f"ex9_{k}.png"),
                 (np.clip(v, 0, 1) * 255).astype(np.uint8))
    print("wrote ex9_plain/shadow/ssaa.png to", args.dump_png)
