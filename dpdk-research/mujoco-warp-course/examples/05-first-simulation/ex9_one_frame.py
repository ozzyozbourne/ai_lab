"""Example 5.9 - render one frame of world 0, with whichever renderer this machine has.

Path 1 (Colab with EGL): get_data_into world 0 -> mujoco.Renderer (OpenGL) -> uint8 image.
Path 2 (fallback, works on Warp CPU): the MJWarp batch ray tracer, create_render_context at
64x64 -> refit_bvh -> render -> get_rgb, which renders every world at once on the device.
The PNG is written with a tiny standard-library encoder, so no imaging library is needed.
Run: python ex9_one_frame.py [--out frame.png] [--dump-png DIR]
  --dump-png DIR  also writes world 0 at t = 0, 0.25, 0.5 s (batch renderer) for the page.
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

PLAYGROUND = """
<mujoco model="playground">
  <option timestep="0.01"/>
  <worldbody>
    <light pos="0 0 3" dir="0 0 -1"/>
    <camera name="overview" pos="0.5 -3 1.5" xyaxes="1 0 0 0 0.45 0.9"/>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 1"><freejoint/>
      <geom type="sphere" size=".1" mass="1" rgba="1 .3 .3 1"/></body>
    <body name="box" pos="0.5 0 1"><freejoint/>
      <geom type="box" size=".1 .1 .1" rgba=".3 .3 1 1"/></body>
    <body name="arm" pos="0 1 1"><joint name="hinge" type="hinge" axis="0 1 0"/>
      <geom type="capsule" fromto="0 0 0 .5 0 0" size=".03"/></body>
  </worldbody>
  <actuator><motor joint="hinge" gear="1"/></actuator>
  <sensor><jointpos joint="hinge"/></sensor>
  <keyframe><key name="up" qpos="0 0 2 1 0 0 0  0.5 0 2 1 0 0 0  0.3"/></keyframe>
</mujoco>
"""


def save_png(path, img):
    """Write an (H, W, 3) uint8 array as an 8-bit RGB PNG (standard library only)."""
    h, w, _ = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))   # filter type 0 per row

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


parser = argparse.ArgumentParser()
parser.add_argument("--out", default="frame.png")
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

NWORLD = 2
NSTEP = 50                                   # 0.5 s at dt = 0.01
mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
# chapter-local camera tweak (the shared MJCF stays as it is): move "overview" closer and tilt it
# 30 degrees down (quat = 60 degrees about x), so the objects fill a 64x64 frame
cam = mjm.camera("overview")
cam.pos[:] = (0.25, -1.6, 1.6)
cam.quat[:] = (np.cos(np.pi / 6), np.sin(np.pi / 6), 0.0, 0.0)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

# the batch renderer: one context for all worlds, built once (it compiles a megakernel)
rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(64, 64), render_rgb=True,
                               render_depth=False, render_seg=False)
rgb = wp.zeros((NWORLD, 64, 64), dtype=wp.vec3)      # (nworld, height, width)


def batch_frame():
    mjw.refit_bvh(m, d, rc)                  # bounding boxes follow the new poses
    mjw.render(m, d, rc)                     # one launch: every world, every camera
    mjw.get_rgb(rc, 0, rgb)                  # unpack camera 0 -> (nworld, H, W) vec3 in [0, 1]
    return (np.clip(rgb.numpy(), 0, 1) * 255).astype(np.uint8)


mjw.forward(m, d)                            # poses at t = 0 (make_data leaves xpos blank)
strip = [batch_frame()[0]]
for i in range(NSTEP):
    mjw.step(m, d)
    if i + 1 in (25, 50):
        strip.append(batch_frame()[0])

try:                                         # path 1: OpenGL renderer (needs EGL/GLFW)
    renderer = mujoco.Renderer(mjm, height=240, width=320)
except Exception as e:                       # ImportError without PyOpenGL/glfw, or no EGL
    print(f"mujoco.Renderer unavailable ({type(e).__name__}); using the MJWarp batch renderer")
    img, path = strip[-1], "batch renderer, 64x64"
else:
    mjd = mujoco.MjData(mjm)
    mjw.get_data_into(mjd, mjm, d, world_id=0)   # copy world 0 back to the host
    renderer.update_scene(mjd, camera="overview")
    img, path = renderer.render(), "mujoco.Renderer, 320x240"

save_png(args.out, img)
print(f"t = {float(d.time.numpy()[0]):.2f} s | path: {path} | image shape {img.shape} {img.dtype}")
print("saved", args.out, "| batch rgb buffer shape:", rgb.shape,
      "| mean pixel:", img.mean().round(1))
if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
    for t, frame in zip(("0.00", "0.25", "0.50"), strip):
        save_png(os.path.join(args.dump_png, f"ex9_world0_t{t}.png"), frame)
    print("wrote", len(strip), "PNGs to", args.dump_png)
