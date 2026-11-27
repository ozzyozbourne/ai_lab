"""Example 2.12 - see a frame: mujoco.Renderer, with the MJWarp batch renderer as fallback.

MUJOCO_GL must be set before mujoco is imported (EGL = headless GPU OpenGL on Colab). We step
PLAYGROUND for 0.3 s and render the "overview" camera. If mujoco.Renderer cannot start (no
OpenGL/EGL, e.g. a CPU box without a display), we fall back (Rule O) to MJWarp's own ray-traced
batch renderer at a small resolution, which runs on Warp's CPU device too.
Run: python ex12_render.py [--dump-png DIR]
  --dump-png DIR  writes the frame as DIR/ex12_frame.png (the chapter embeds it, Rule D)
"""
import argparse
import os

os.environ.setdefault("MUJOCO_GL", "egl")   # before "import mujoco"

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
parser = argparse.ArgumentParser()
parser.add_argument("--dump-png", default=None)
args, _ = parser.parse_known_args()

mjm = mujoco.MjModel.from_xml_string(PLAYGROUND)
mjd = mujoco.MjData(mjm)
for _ in range(30):
    mujoco.mj_step(mjm, mjd)
cam = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_CAMERA, "overview")

image, source = None, None
try:
    renderer = mujoco.Renderer(mjm, height=240, width=320)
    renderer.update_scene(mjd, camera="overview")
    image, source = renderer.render(), "mujoco.Renderer (OpenGL)"
except Exception as e:  # ImportError without PyOpenGL/EGL, RuntimeError without a GL context
    print(f"mujoco.Renderer unavailable ({type(e).__name__}); using the MJWarp batch renderer")

if image is None:
    W, H = 192, 144
    m = mjw.put_model(mjm)
    d = mjw.put_data(mjm, mjd, nworld=1, nconmax=16, njmax=64)
    rc = mjw.create_render_context(mjm, nworld=1, cam_res=(W, H), render_rgb=True,
                                   render_depth=False, render_seg=False)
    mjw.forward(m, d)
    print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
    mjw.refit_bvh(m, d, rc)
    mjw.render(m, d, rc)
    rgb = wp.zeros((1, H, W), dtype=wp.vec3)
    mjw.get_rgb(rc, camera_index=cam, rgb_out=rgb)
    image = (np.clip(rgb.numpy()[0], 0, 1) * 255).astype(np.uint8)
    source = "MJWarp batch renderer (ray tracing)"

print("camera 'overview' id:", cam, "| image shape:", image.shape, "| dtype:", image.dtype)
print("rendered with:", source, f"| mean pixel value {image.mean():.1f}")



def save_png(path, rgb):
    """Write an (H, W, 3) uint8 image as PNG: PIL if installed, else a tiny zlib writer."""
    try:
        from PIL import Image
        Image.fromarray(rgb).save(path)
        return "PIL"
    except ImportError:
        import struct
        import zlib
        h, w, _ = rgb.shape
        raw = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))

        def chunk(tag, data):
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
        png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
        with open(path, "wb") as f:
            f.write(png)
        return "zlib"


if args.dump_png:
    os.makedirs(args.dump_png, exist_ok=True)
out = os.path.join(args.dump_png or ".", "ex12_frame.png")
print("saved", out, "with", save_png(out, np.ascontiguousarray(image)))
