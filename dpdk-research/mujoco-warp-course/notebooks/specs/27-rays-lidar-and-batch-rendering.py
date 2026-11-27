# Notebook spec for Ch 27. Build with:
#   python3 tools/make_notebook.py notebooks/specs/27-rays-lidar-and-batch-rendering.py
SLUG = "27-rays-lidar-and-batch-rendering"
TITLE = "Ch 27 · Rays, Lidar and Batch Rendering for Thousands of Worlds"
# Plan: "setup (+EGL only for comparison)". AUTO_HEADER is off so the EGL ICD cell runs before the
# standard setup cell imports mujoco (same pattern as Ch 2). Only the optional comparison cell after
# Example 27.5 uses OpenGL; every example uses the MJWarp batch renderer, which needs no EGL.
AUTO_HEADER = False

COLAB = ("https://colab.research.google.com/github/ozzyozbourne/ai_lab/blob/master/"
         "dpdk-research/mujoco-warp-course/notebooks/27-rays-lidar-and-batch-rendering.ipynb")

EGL_CELL = '# Rendering notebooks only: let glvnd find the NVIDIA EGL driver (from the official\n# mujoco_warp tutorial). Must run before mujoco is imported by the setup cell below.\nimport os\nos.environ.setdefault("MUJOCO_GL", "egl")\nNVIDIA_ICD_CONFIG_PATH = "/usr/share/glvnd/egl_vendor.d/10_nvidia.json"\ntry:\n    if not os.path.exists(NVIDIA_ICD_CONFIG_PATH):\n        os.makedirs(os.path.dirname(NVIDIA_ICD_CONFIG_PATH), exist_ok=True)\n        with open(NVIDIA_ICD_CONFIG_PATH, "w") as f:\n            f.write(\'{"file_format_version": "1.0.0", \'\n                    \'"ICD": {"library_path": "libEGL_nvidia.so.0"}}\\n\')\n    print("EGL ICD file:", NVIDIA_ICD_CONFIG_PATH, "| MUJOCO_GL =", os.environ["MUJOCO_GL"])\nexcept OSError as e:\n    print("could not write the EGL ICD file (fine outside Colab):", e)'

COMPARE = '# Optional comparison: the same world-0 frame from MuJoCo\'s own OpenGL renderer (EGL), next to\n# mjw.get_rgb. Uses mjm, d, img, W and H from Example 27.5 above. The two images will not match\n# pixel for pixel: the batch renderer is a separate ray tracer with its own shading.\ntry:\n    import matplotlib.pyplot as plt\n    mjd = mujoco.MjData(mjm)\n    mjd.qpos[:] = d.qpos.numpy()[0]\n    mujoco.mj_forward(mjm, mjd)\n    renderer = mujoco.Renderer(mjm, height=H, width=W)\n    renderer.update_scene(mjd, camera="camera")\n    gl = renderer.render()\n    renderer.close()\n    fig, axs = plt.subplots(1, 2, figsize=(8, 4))\n    axs[0].imshow(gl); axs[0].set_title("mujoco.Renderer (OpenGL / EGL)")\n    axs[1].imshow(np.clip(img[0], 0, 1)); axs[1].set_title("mjw.get_rgb, world 0")\n    for a in axs:\n        a.axis("off")\n    plt.show()\nexcept Exception as e:  # no EGL / OpenGL on this runtime: the batch renderer above does not need it\n    print("OpenGL comparison skipped:", type(e).__name__, e)'

HEADER = [
    ["md", f"# {TITLE}\n\n[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]({COLAB})\n\n"
           "Companion notebook for the chapter page `chapters/27-rays-lidar-and-batch-rendering.html` "
           "([page](../chapters/27-rays-lidar-and-batch-rendering.html)). Pinned versions: "
           "mujoco-warp 4.0.1, warp-lang 1.19.0, mujoco-core 4.0.1.\n\n"
           "**Before you start:** Runtime > Change runtime type > select a GPU. Then run the cells top to bottom."],
    ["code", "# Check the GPU Colab gave you (this fails harmlessly on a CPU runtime).\n!nvidia-smi"],
    ["code", EGL_CELL],
    ["setup", {"render": True}],
]

CELLS = HEADER + [['md',
  'This notebook runs every example of the chapter in order. Each example cell is the exact script from '
  '`examples/27-rays-lidar-and-batch-rendering/`. On a GPU runtime the budgets grow automatically (`ON_GPU`); '
  'timings are your own GPU numbers. The batch renderer needs no OpenGL/EGL. The EGL cell and `MUJOCO_GL=egl` at the top exist only for the optional `mujoco.Renderer` comparison cell after Example 27.5; it prints a message and moves on where EGL is missing.'],
 ['md',
  '## 1. One ray per world: `mjw.ray`\n'
  'A ray from (2, 0, 2) straight down hits the top of a cylinder at dist 1.4; with `bodyexclude` set to the '
  "cylinder's body it hits the floor at 2.0. `dist` is the ray parameter t, in units of |vec|: pass unit directions "
  'to get metres. `-1` means no hit.'],
 ['example', 'ex1_single_ray.py', '27.1'],
 ['md',
  '## 2. A 360-ray lidar in every world: `mjw.rays`\n'
  "A small kernel with launch shape `(nworld, nray)` builds the rays from the robot body's `d.xpos`/`d.xmat`; one "
  '`rays` call casts them all. Without `bodyexclude` every ray starts inside the robot and reports 0.15 m. `vec6` is '
  'a private type from `mujoco_warp._src.types`.'],
 ['example', 'ex2_lidar.py', '27.2'],
 ['code',
  '# Plot the lidar scans of Example 27.2 (polar: range against body angle).\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(1, 4, subplot_kw={"projection": "polar"}, figsize=(14, 3.6))\n'
  '    for w in range(4):\n'
  '        axs[w].plot(np.radians(np.arange(NRAY)), np.where(r[w] < 0, np.nan, r[w]))\n'
  '        axs[w].set_title(f"world {w} pose {pose[w]}")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['md',
  '## 3. Ray filters: `_ray_eliminate`\n'
  'A geom is skipped if it is on `bodyexclude`, has alpha 0, is welded to the world while `flg_static=False`, or its '
  'group has a 0 in the `geomgroup` mask (all -1 = no filtering).'],
 ['example', 'ex3_ray_filters.py', '27.3'],
 ['md',
  '## 4. Rays through the scene BVH (`rc=`)\n'
  'Without `rc`, `rays` is a tiled kernel (64 lanes per ray, `tile_argmin` over all geoms). With a render context it '
  'walks one BVH that groups boxes by world, starting from `rc.group_root[worldid]`. Refit after poses change. Note: '
  "with `rc`, only geoms in the context's `enabled_geom_groups` (default 0, 1, 2) can be hit."],
 ['example', 'ex4_rays_bvh.py', '27.4'],
 ['md',
  '## 5. The four-call render pipeline\n'
  '`create_render_context` (once, keyword arguments only) -> `step`/`forward` -> `refit_bvh` -> `render` -> '
  '`get_rgb`/`get_depth`/`get_segmentation`. `cam_res` is (width, height); images come out as (nworld, height, '
  'width).'],
 ['example', 'ex5_grid16.py', '27.5'],
 ['code',
  '# Show the RGB and depth grids of Example 27.5 (img, dep and tile() come from the cell above).\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(1, 2, figsize=(10, 5))\n'
  '    axs[0].imshow(np.clip(tile(img, COLS), 0, 1)); axs[0].set_title("get_rgb, all worlds")\n'
  '    axs[1].imshow(tile(dep[..., None], COLS)[..., 0], cmap="gray"); axs[1].set_title("get_depth / 3 m")\n'
  '    for a in axs: a.axis("off")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['code', COMPARE],
 ['md',
  '## 6. Why `refit_bvh`: the stale-BVH demonstration\n'
  "The context's BVH is built at `qpos0`. Move the sphere without a refit and it vanishes (16 -> 0 -> 18 sphere "
  'pixels).'],
 ['example', 'ex7_stale_bvh.py', '27.7'],
 ['code',
  '# The three frames of Example 27.7: start, moved without refit, after refit_bvh.\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(1, 3, figsize=(12, 3.2))\n'
  '    for a, f, t in zip(axs, frames, ["start", "moved, NO refit", "after refit_bvh"]):\n'
  '        a.imshow(f, interpolation="nearest"); a.set_title(t); a.axis("off")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['md',
  '## 7. Every option, geom groups and `cam_active`\n'
  'The option table comes from `inspect.signature`, so it matches the installed version. Geoms in group 3+ are '
  'invisible with the default `enabled_geom_groups`. `camera_index` counts *active* cameras (`rc.cam_id_map` maps '
  'back).'],
 ['example', 'ex12_options_and_groups.py', '27.12'],
 ['md',
  '## 8. Camera modes and the ordering rule\n'
  '`camlight` (inside every forward/step) writes `d.cam_xpos`/`d.cam_xmat` from the MJCF modes. A camera you set by '
  'hand goes after `step` and before `refit_bvh`/`render`, every frame.'],
 ['example', 'ex14_camera_modes.py', '27.14'],
 ['md',
  '## 9. Output buffers and their layout\n'
  "One row per world; cameras laid end to end; `rgb_adr`/`depth_adr`/`seg_adr` give each camera's start (-1 = no "
  'such output); pixels row-major. RGB is packed `0xAARRGGBB`.'],
 ['example', 'ex6_buffer_layout.py', '27.6'],
 ['md',
  '## 10. Shadows and supersampling\n'
  'Both are creation options. A blocked shadow ray scales the light by `shadow_light_fraction` (0.3). '
  '`samples_per_pixel=n` renders n x n passes and averages.'],
 ['example', 'ex9_shading_options.py', '27.9'],
 ['code',
  '# Example 27.9 side by side.\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(1, 3, figsize=(12, 4))\n'
  '    for a, (k, v) in zip(axs, images.items()):\n'
  '        a.imshow(np.clip(v, 0, 1), interpolation="nearest"); a.set_title(k); a.axis("off")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['md',
  '## 11. Depth and segmentation\n'
  'Depth is planar (z-depth): `dist * -d_cam.z`. `get_depth` divides by `depth_scale` and clamps to [0, 1]; read '
  '`rc.depth_data` for metres. Segmentation pixels are `(objid, objtype)` with 5 = geom, 9 = flex, (-1, -1) = '
  'background. (The first run compiles the flex kernels, which takes a while.)'],
 ['example', 'ex8_depth_and_seg.py', '27.8'],
 ['md',
  '## 12. Visual domain randomization\n'
  'Batch Model fields with `put_model(batch_sizes=...)`. Colours work directly; a per-world field of view needs '
  '`use_precomputed_rays=False`.'],
 ['example', 'ex10_visual_dr.py', '27.10'],
 ['code',
  '# Example 27.10: the three worlds with precomputed vs dynamic rays.\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(2, 3, figsize=(9, 6))\n'
  '    for row, pre in enumerate((True, False)):\n'
  '        for w in range(NWORLD):\n'
  '            axs[row, w].imshow(np.clip(strips[pre][w], 0, 1), interpolation="nearest")\n'
  '            axs[row, w].set_title(f"fovy {fovy[w, 0]:.0f}, precomputed={pre}", fontsize=9)\n'
  '            axs[row, w].axis("off")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['md',
  '## 13. Gaussian splats with a splat set per world\n'
  '`splat_adr` cuts the arrays into groups, `splat_group_id[w]` picks a group per world. Splats are composited front '
  'to back and hidden by solid geometry. After editing `rc.splat_*`, call `mjw.refit_splat_bvh(rc)`.'],
 ['example', 'ex13_splats.py', '27.13'],
 ['code',
  '# Example 27.13: world 0 / world 1 without and with their splat groups.\n'
  'try:\n'
  '    import matplotlib.pyplot as plt\n'
  '    fig, axs = plt.subplots(1, 4, figsize=(14, 3.6))\n'
  '    tiles = [images["no splats"][0], images["splats"][0], images["no splats"][1], images["splats"][1]]\n'
  '    for a, t, title in zip(axs, tiles, ["w0", "w0 + group 0", "w1", "w1 + group 1"]):\n'
  '        a.imshow(np.clip(t, 0, 1), interpolation="nearest"); a.set_title(title); a.axis("off")\n'
  '    plt.show()\n'
  'except ImportError:\n'
  '    print("skipped: matplotlib not installed")\n'],
 ['md',
  '## 14. A rendered rollout with CUDA graphs\n'
  'On a GPU, warm up once, then capture a physics graph and a render graph and replay them per frame. On CPU the '
  "same calls run eagerly. The table prints your own device's numbers."],
 ['example', 'ex11_video_graph.py', '27.11'],
 ['code',
  '# Play world 0 of Example 27.11 (mediapy is installed by the setup cell).\n'
  'try:\n'
  '    import mediapy as media\n'
  '    media.show_video([np.repeat(np.repeat(f, 4, 0), 4, 1) for f in frames], fps=15)\n'
  'except ImportError:\n'
  '    print("skipped: mediapy not installed")\n'],
 ['md',
  '## Exercise 27.1: a pixel observation tensor\n'
  'Fill in the kernel and `pixel_obs` so that the asserts pass: `(nworld, 3, H, W)` float32 in [0, 1], red channel = '
  'bits 16..23 of `rc.rgb_data`.'],
 ['code',
  'import mujoco\n'
  'import numpy as np\n'
  'import warp as wp\n'
  'wp.config.log_level = wp.LOG_WARNING\n'
  'import mujoco_warp as mjw\n'
  '\n'
  'RENDER_SCENE = """\n'
  '<mujoco model="render_scene">\n'
  '  <worldbody>\n'
  '    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>\n'
  '    <camera name="camera" pos="0 2 0" quat="0 0 1 1"/>\n'
  '    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>\n'
  '    <body name="box_and_sphere" euler="0 0 -30">\n'
  '      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>\n'
  '      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>\n'
  '      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>\n'
  '    </body>\n'
  '  </worldbody>\n'
  '</mujoco>\n'
  '"""\n'
  'NWORLD, W, H = 4, 32, 24          # deliberately W != H\n'
  '\n'
  '\n'
  '@wp.kernel\n'
  'def rgb_to_nchw(rgb: wp.array3d(dtype=wp.vec3), obs: wp.array4d(dtype=float)):\n'
  '    w, y, x = wp.tid()                      # launch over (nworld, H, W)\n'
  '    # TODO: copy the three channels of rgb[w, y, x] into obs[w, 0..2, y, x]\n'
  '\n'
  '\n'
  'def pixel_obs(m, d, rc, rgb, obs):\n'
  '    # TODO: refit the BVH, render, unpack camera 0 into rgb, launch rgb_to_nchw\n'
  '    return obs\n'
  '\n'
  '\n'
  'mjm = mujoco.MjModel.from_xml_string(RENDER_SCENE)\n'
  'm = mjw.put_model(mjm)\n'
  'd = mjw.make_data(mjm, nworld=NWORLD)\n'
  'rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,\n'
  '                               render_depth=False, render_seg=False)\n'
  'rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)\n'
  'obs = wp.zeros((NWORLD, 3, H, W), dtype=float)\n'
  'q = np.tile(mjm.qpos0, (NWORLD, 1)); q[:, 0] = np.linspace(0, 3, NWORLD)\n'
  'd.qpos.assign(q.astype(np.float32))\n'
  'mjw.forward(m, d)\n'
  'o = pixel_obs(m, d, rc, rgb, obs).numpy()\n'
  '\n'
  'assert o.shape == (NWORLD, 3, H, W) and o.dtype == np.float32, (o.shape, o.dtype)\n'
  'assert 0.0 <= o.min() and o.max() <= 1.0\n'
  'packed = rc.rgb_data.numpy()[:, :W * H].reshape(NWORLD, H, W)\n'
  'assert np.allclose(o[:, 0], ((packed >> 16) & 255) / 255.0)      # red channel = bits 16..23\n'
  'assert not np.allclose(o[0], o[-1])                               # worlds differ\n'
  'print("obs", o.shape, o.dtype, "range", o.min(), o.max(), "-> all checks passed")\n'],
 ['solution',
  'import mujoco\n'
  'import numpy as np\n'
  'import warp as wp\n'
  'wp.config.log_level = wp.LOG_WARNING\n'
  'import mujoco_warp as mjw\n'
  '\n'
  'RENDER_SCENE = """\n'
  '<mujoco model="render_scene">\n'
  '  <worldbody>\n'
  '    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>\n'
  '    <camera name="camera" pos="0 2 0" quat="0 0 1 1"/>\n'
  '    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>\n'
  '    <body name="box_and_sphere" euler="0 0 -30">\n'
  '      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>\n'
  '      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>\n'
  '      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>\n'
  '    </body>\n'
  '  </worldbody>\n'
  '</mujoco>\n'
  '"""\n'
  'NWORLD, W, H = 4, 32, 24          # deliberately W != H\n'
  '\n'
  '\n'
  '@wp.kernel\n'
  'def rgb_to_nchw(rgb: wp.array3d(dtype=wp.vec3), obs: wp.array4d(dtype=float)):\n'
  '    w, y, x = wp.tid()                      # launch over (nworld, H, W)\n'
  '    c = rgb[w, y, x]\n'
  '    obs[w, 0, y, x] = c[0]\n'
  '    obs[w, 1, y, x] = c[1]\n'
  '    obs[w, 2, y, x] = c[2]\n'
  '\n'
  '\n'
  'def pixel_obs(m, d, rc, rgb, obs):\n'
  '    mjw.refit_bvh(m, d, rc)\n'
  '    mjw.render(m, d, rc)\n'
  '    mjw.get_rgb(rc, 0, rgb)\n'
  '    wp.launch(rgb_to_nchw, dim=rgb.shape, inputs=[rgb], outputs=[obs])\n'
  '    return obs\n'
  '\n'
  '\n'
  'mjm = mujoco.MjModel.from_xml_string(RENDER_SCENE)\n'
  'm = mjw.put_model(mjm)\n'
  'd = mjw.make_data(mjm, nworld=NWORLD)\n'
  'rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,\n'
  '                               render_depth=False, render_seg=False)\n'
  'rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)\n'
  'obs = wp.zeros((NWORLD, 3, H, W), dtype=float)\n'
  'q = np.tile(mjm.qpos0, (NWORLD, 1)); q[:, 0] = np.linspace(0, 3, NWORLD)\n'
  'd.qpos.assign(q.astype(np.float32))\n'
  'mjw.forward(m, d)\n'
  'o = pixel_obs(m, d, rc, rgb, obs).numpy()\n'
  '\n'
  'assert o.shape == (NWORLD, 3, H, W) and o.dtype == np.float32, (o.shape, o.dtype)\n'
  'assert 0.0 <= o.min() and o.max() <= 1.0\n'
  'packed = rc.rgb_data.numpy()[:, :W * H].reshape(NWORLD, H, W)\n'
  'assert np.allclose(o[:, 0], ((packed >> 16) & 255) / 255.0)      # red channel = bits 16..23\n'
  'assert not np.allclose(o[0], o[-1])                               # worlds differ\n'
  'print("obs", o.shape, o.dtype, "range", o.min(), o.max(), "-> all checks passed")\n',
  'Exercise 27.1'],
 ['md',
  '## Exercise 27.2: lidar minimum range against geometry\n'
  'Implement `min_range` so that it matches the exact distance to the nearest wall or pillar within 1 mm, with and '
  'without the BVH.'],
 ['code',
  'import mujoco\n'
  'import numpy as np\n'
  'import warp as wp\n'
  'wp.config.log_level = wp.LOG_WARNING\n'
  'import mujoco_warp as mjw\n'
  'from mujoco_warp._src.types import vec6\n'
  '\n'
  'ROOM = """\n'
  '<mujoco><worldbody>\n'
  '  <geom name="floor" type="plane" size="3 3 .1"/>\n'
  '  <geom type="box" pos=" 2 0 .5" size=".05 2 .5"/><geom type="box" pos="-2 0 .5" size=".05 2 .5"/>\n'
  '  <geom type="box" pos="0  2 .5" size="2 .05 .5"/><geom type="box" pos="0 -2 .5" size="2 .05 .5"/>\n'
  '  <geom name="pillar" type="cylinder" pos="1 1 .4" size=".2 .4"/>\n'
  '  <body name="robot" pos="0 0 .15"><freejoint/><geom type="cylinder" size=".15 .15"/></body>\n'
  '</worldbody></mujoco>"""\n'
  'XY = np.array([[0.0, 0.0], [1.5, -0.4], [0.6, 0.7], [-1.2, 1.6]])\n'
  'NWORLD, NRAY = len(XY), 360\n'
  '\n'
  '\n'
  'def min_range(m, d, robot, nray=NRAY, rc=None):\n'
  '    """Smallest lidar range per world, rays in the horizontal plane at the robot origin."""\n'
  '    # TODO: build pnt / vec of shape (nworld, nray), outputs of shape (nworld, nray),\n'
  '    #       call mjw.rays with bodyexclude = robot for every ray, ignore misses (-1), reduce\n'
  '    raise NotImplementedError\n'
  '\n'
  '\n'
  'def analytic(xy):\n'
  '    wall = 1.95 - np.abs(xy).max(1)\n'
  '    pillar = np.linalg.norm(xy - [1.0, 1.0], axis=1) - 0.2\n'
  '    return np.minimum(wall, pillar)\n'
  '\n'
  '\n'
  'mjm = mujoco.MjModel.from_xml_string(ROOM)\n'
  'm = mjw.put_model(mjm)\n'
  'd = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)\n'
  'q = np.tile(mjm.qpos0, (NWORLD, 1)); q[:, :2] = XY\n'
  'd.qpos.assign(q.astype(np.float32))\n'
  'mjw.kinematics(m, d)\n'
  'robot = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "robot")\n'
  'got, want = min_range(m, d, robot), analytic(XY)\n'
  'print("lidar :", got.round(4))\n'
  'print("exact :", want.round(4))\n'
  'assert np.allclose(got, want, atol=1e-3), (got, want)\n'
  'rc = mjw.create_render_context(mjm, nworld=NWORLD)\n'
  'mjw.refit_bvh(m, d, rc)\n'
  'assert np.allclose(min_range(m, d, robot, rc=rc), got, atol=1e-6)\n'
  'print("min_range matches the geometry in all", NWORLD, "worlds (with and without the BVH)")\n'],
 ['solution',
  'import mujoco\n'
  'import numpy as np\n'
  'import warp as wp\n'
  'wp.config.log_level = wp.LOG_WARNING\n'
  'import mujoco_warp as mjw\n'
  'from mujoco_warp._src.types import vec6\n'
  '\n'
  'ROOM = """\n'
  '<mujoco><worldbody>\n'
  '  <geom name="floor" type="plane" size="3 3 .1"/>\n'
  '  <geom type="box" pos=" 2 0 .5" size=".05 2 .5"/><geom type="box" pos="-2 0 .5" size=".05 2 .5"/>\n'
  '  <geom type="box" pos="0  2 .5" size="2 .05 .5"/><geom type="box" pos="0 -2 .5" size="2 .05 .5"/>\n'
  '  <geom name="pillar" type="cylinder" pos="1 1 .4" size=".2 .4"/>\n'
  '  <body name="robot" pos="0 0 .15"><freejoint/><geom type="cylinder" size=".15 .15"/></body>\n'
  '</worldbody></mujoco>"""\n'
  'XY = np.array([[0.0, 0.0], [1.5, -0.4], [0.6, 0.7], [-1.2, 1.6]])\n'
  'NWORLD, NRAY = len(XY), 360\n'
  '\n'
  '\n'
  'def min_range(m, d, robot, nray=NRAY, rc=None):\n'
  '    """Smallest lidar range per world, rays in the horizontal plane at the robot origin."""\n'
  '    ang = 2 * np.pi * np.arange(nray) / nray\n'
  '    origin = d.xpos.numpy()[:, robot]\n'
  '    pnt = wp.array(np.repeat(origin[:, None], nray, 1), dtype=wp.vec3)\n'
  '    vec = wp.array(np.tile(np.stack([np.cos(ang), np.sin(ang), 0 * ang], 1), (d.nworld, 1, 1)),\n'
  '                   dtype=wp.vec3)\n'
  '    dist = wp.zeros((d.nworld, nray), dtype=float)\n'
  '    gid = wp.zeros((d.nworld, nray), dtype=int)\n'
  '    nrm = wp.zeros((d.nworld, nray), dtype=wp.vec3)\n'
  '    mjw.rays(m, d, pnt, vec, vec6(-1, -1, -1, -1, -1, -1), True,\n'
  '             wp.full(nray, robot, dtype=int), dist, gid, nrm, rc=rc)\n'
  '    r = dist.numpy()\n'
  '    return np.where(r < 0, np.inf, r).min(1)\n'
  '\n'
  '\n'
  'def analytic(xy):\n'
  '    wall = 1.95 - np.abs(xy).max(1)\n'
  '    pillar = np.linalg.norm(xy - [1.0, 1.0], axis=1) - 0.2\n'
  '    return np.minimum(wall, pillar)\n'
  '\n'
  '\n'
  'mjm = mujoco.MjModel.from_xml_string(ROOM)\n'
  'm = mjw.put_model(mjm)\n'
  'd = mjw.make_data(mjm, nworld=NWORLD, nconmax=8, njmax=32)\n'
  'q = np.tile(mjm.qpos0, (NWORLD, 1)); q[:, :2] = XY\n'
  'd.qpos.assign(q.astype(np.float32))\n'
  'mjw.kinematics(m, d)\n'
  'robot = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_BODY, "robot")\n'
  'got, want = min_range(m, d, robot), analytic(XY)\n'
  'print("lidar :", got.round(4))\n'
  'print("exact :", want.round(4))\n'
  'assert np.allclose(got, want, atol=1e-3), (got, want)\n'
  'rc = mjw.create_render_context(mjm, nworld=NWORLD)\n'
  'mjw.refit_bvh(m, d, rc)\n'
  'assert np.allclose(min_range(m, d, robot, rc=rc), got, atol=1e-6)\n'
  'print("min_range matches the geometry in all", NWORLD, "worlds (with and without the BVH)")\n',
  'Exercise 27.2'],
 ['md',
  '## Stretch: an orbiting camera\n'
  'In every frame: `step`, then write `d.cam_xpos`/`d.cam_xmat`, then `refit_bvh` and `render`. Then move the write '
  'before `step` and explain what you see. On a GPU, raise the resolution and capture the render in a graph.'],
 ['code', '# your orbit here\n'],
 ['solution',
  'import mujoco\n'
  'import numpy as np\n'
  'import warp as wp\n'
  'wp.config.log_level = wp.LOG_WARNING\n'
  'import mujoco_warp as mjw\n'
  '\n'
  'RENDER_SCENE = """\n'
  '<mujoco model="render_scene">\n'
  '  <option timestep="0.01666"/>\n'
  '  <worldbody>\n'
  '    <light name="top" pos="0 0 2" dir="0 0 -1" directional="true"/>\n'
  '    <camera name="camera" pos="0 2 0" quat="0 0 1 1"/>\n'
  '    <geom name="floor" type="plane" pos="0 0 -.5" size="2 2 .1" rgba=".9 .9 .9 1"/>\n'
  '    <body name="box_and_sphere" euler="0 0 -30">\n'
  '      <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>\n'
  '      <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>\n'
  '      <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>\n'
  '    </body>\n'
  '  </worldbody>\n'
  '</mujoco>\n'
  '"""\n'
  '\n'
  '\n'
  'def look_at(eye, target, up=(0.0, 0.0, 1.0)):\n'
  '    """cam_xmat columns = camera x, y, z axes in world; the camera looks along -z."""\n'
  '    fwd = np.asarray(target, float) - eye\n'
  '    fwd /= np.linalg.norm(fwd)\n'
  '    x = np.cross(fwd, up); x /= np.linalg.norm(x)\n'
  '    y = np.cross(-fwd, x)\n'
  '    return np.column_stack([x, y, -fwd])\n'
  '\n'
  '\n'
  'NWORLD, W, H, NFRAME = 2, 32, 32, 12\n'
  'mjm = mujoco.MjModel.from_xml_string(RENDER_SCENE)\n'
  'm = mjw.put_model(mjm)\n'
  'd = mjw.make_data(mjm, nworld=NWORLD)\n'
  'rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H), render_rgb=True,\n'
  '                               render_depth=False, render_seg=False)\n'
  'rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3)\n'
  'frames = []\n'
  'mjw.forward(m, d)\n'
  'for f in range(NFRAME):\n'
  '    mjw.step(m, d)                                     # 1. physics (camlight runs inside)\n'
  '    a = 2 * np.pi * f / NFRAME                         # 2. THEN overwrite the camera\n'
  '    eye = np.array([2 * np.sin(a), 2 * np.cos(a), 0.6])\n'
  '    pos, mat = d.cam_xpos.numpy(), d.cam_xmat.numpy()\n'
  '    pos[:, 0], mat[:, 0] = eye, look_at(eye, [0, 0, -0.2])\n'
  '    d.cam_xpos.assign(pos)\n'
  '    d.cam_xmat.assign(mat)\n'
  '    mjw.refit_bvh(m, d, rc)                            # 3. refit + render read the new camera\n'
  '    mjw.render(m, d, rc)\n'
  '    mjw.get_rgb(rc, 0, rgb)\n'
  '    frames.append((np.clip(rgb.numpy()[0], 0, 1) * 255).astype(np.uint8))\n'
  'diffs = [np.abs(frames[i + 1].astype(int) - frames[i]).mean() for i in range(NFRAME - 1)]\n'
  'print(len(frames), "orbit frames; mean change between frames:", np.round(diffs, 1))\n',
  'Stretch'],
 ['code',
  '# Show the orbit as a video.\n'
  'try:\n'
  '    import mediapy as media\n'
  '    media.show_video([np.repeat(np.repeat(f, 4, 0), 4, 1) for f in frames], fps=6)\n'
  'except ImportError:\n'
  '    print("skipped: mediapy not installed")\n']]
