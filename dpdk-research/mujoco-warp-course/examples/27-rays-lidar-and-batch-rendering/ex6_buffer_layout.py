"""Example 27.6 - the flat output buffers: two cameras, different resolutions and outputs.

cam0 renders 32x24 RGB + depth + seg, cam1 16x16 RGB + seg (no depth). Every world owns one
row of rc.rgb_data (uint32 0xAARRGGBB) holding all cameras' pixels back to back; camera c
starts at rc.rgb_adr[c] and its pixels are row-major (py * W + px). A camera without an output
has adr -1 there. The manual unpack below gives exactly what mjw.get_rgb returns.
Run: python ex6_buffer_layout.py [--dump-json PATH]
  --dump-json PATH  writes the real packed pixels, depth and seg ids for the page's mosaic.
"""
import argparse
import json

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

TWO_CAMS = """
<mujoco model="two_cams">
  <worldbody>
    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>
    <camera name="front" pos="0 2 0" quat="0 0 1 1"/>
    <camera name="above" pos="0 0 1.6" xyaxes="1 0 0 0 1 0"/>
    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>
    <body name="box_and_sphere" euler="0 0 -30">
      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>
      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>
      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>
    </body>
  </worldbody>
</mujoco>
"""

parser = argparse.ArgumentParser()
parser.add_argument("--dump-json", default=None)
args, _ = parser.parse_known_args()

NWORLD = 2
RES = [(32, 24), (16, 16)]                       # (width, height) per active camera

mjm = mujoco.MjModel.from_xml_string(TWO_CAMS)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=RES,
                               render_rgb=[True, True], render_depth=[True, False],
                               render_seg=[True, True])
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 0] = [0.0, 1.2]
d.qpos.assign(qpos.astype(np.float32))
mjw.forward(m, d)
mjw.refit_bvh(m, d, rc)
mjw.render(m, d, rc)

print("nrender", rc.nrender, "| total_rays", rc.total_rays, "=", " + ".join(
    str(w * h) for w, h in RES), "| cam_id_map", rc.cam_id_map.numpy())
print("cam_res (W, H):", rc.cam_res.numpy().tolist())
print("rgb_adr", rc.rgb_adr.numpy(), "depth_adr", rc.depth_adr.numpy(),
      "seg_adr", rc.seg_adr.numpy())
print("rgb_data", rc.rgb_data.shape, rc.rgb_data.dtype.__name__, "| depth_data",
      rc.depth_data.shape, "| seg_data", rc.seg_data.shape, "| ray", rc.ray.shape)

packed = rc.rgb_data.numpy()                     # (nworld, 1024) uint32
for px, py in [(0, 0), (16, 12)]:                # a background pixel and the image centre
    p = int(packed[0, py * 32 + px])             # cam0 starts at rgb_adr[0] = 0, W = 32
    print(f"world 0, cam0 pixel (px={px}, py={py}): 0x{p:08X} -> A={p >> 24} "
          f"R={(p >> 16) & 255} G={(p >> 8) & 255} B={p & 255}")

for cam, (w, h) in enumerate(RES):
    adr = int(rc.rgb_adr.numpy()[cam])
    block = packed[:, adr:adr + w * h].reshape(NWORLD, h, w)       # row-major: [py, px]
    manual = np.stack([(block >> 16) & 255, (block >> 8) & 255, block & 255], -1) / 255.0
    out = wp.zeros((NWORLD, h, w), dtype=wp.vec3)
    mjw.get_rgb(rc, cam, out)
    print(f"cam{cam}: manual unpack == get_rgb:", bool(np.allclose(manual, out.numpy())),
          f"| block [{adr}:{adr + w * h}] -> (nworld, H, W) = {manual.shape[:3]}")

if args.dump_json:
    dep = rc.depth_data.numpy()
    sg = rc.seg_data.numpy()
    out = {"nworld": NWORLD, "res": RES, "rgb_adr": rc.rgb_adr.numpy().tolist(),
           "depth_adr": rc.depth_adr.numpy().tolist(), "seg_adr": rc.seg_adr.numpy().tolist(),
           "total_rays": rc.total_rays,
           "geom_names": [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, i)
                          for i in range(mjm.ngeom)],
           "rgb": packed.astype(np.int64).tolist(),
           "depth": [[round(float(v), 3) for v in row] for row in dep],
           "seg": [[int(v[0]) for v in row] for row in sg],
           "segtype": [[int(v[1]) for v in row] for row in sg]}
    with open(args.dump_json, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print("wrote", args.dump_json)
