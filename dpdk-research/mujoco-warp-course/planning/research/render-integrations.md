# Research notes: Rendering and integrations (render-integrations)

Source studied: `src/mujoco_warp` at commit 8f5b9f1 (main, Nov 2026). Paths below are relative to that repo root.
Installed for experiments: mujoco-warp 4.0.1 (PyPI), warp-lang 1.19.0, mujoco-core 4.0.1, CPU only.
Experiment scripts: `scratchpad/experiments/render-integrations/exp1.py` … `exp6.py` (all ran on CPU).

Markers: **[RAN]** = snippet executed here and output shown; **[SRC]** = copied/derived from repo source or tests, not run here (usually needs GPU, JAX, torch or OptiX).

---

## 0. VERSION WARNING (read first)

The git checkout (main) is newer than PyPI `mujoco-warp==4.0.1`. Verified differences:

| Feature | git main (8f5b9f1) | PyPI 4.0.1 (installed) |
|---|---|---|
| `create_render_context(..., backend="warp"/"optix")` | yes | **no `backend` kwarg** |
| `render_optix.py`, `RenderContext.backend`, `.optix` | yes | absent |
| `RenderContext.any_rgb`, `.any_seg` | yes | absent |
| Tiled ray order (`render_util.tile_pixel`, `TILE_ROWS`) | yes | absent (plain row-major ray order) |
| `mujoco_warp[optix]` extra (`warp-optix>=0.3.0`, Python 3.12 only) | yes | no |

Everything else used below (create_render_context's other kwargs, render, refit_bvh, get_rgb/get_depth/get_segmentation, ray/rays, put_model(batch_sizes=...)) works in 4.0.1 (verified).
**Course recommendation:** in Colab notebooks install from git like the official tutorial does
(`notebooks/tutorial.ipynb` cell 2: `!uv pip install "mujoco-warp[viewer] @ git+https://github.com/google-deepmind/mujoco_warp.git"`),
or pin to 4.0.1 and avoid `backend=`. Say so explicitly in every rendering chapter.

**Public-doc error to avoid:** the readthedocs page shows `mjw.get_rgb(rc, rgb_data=rgb_data, cam_id=cam_index)`. The real signature
(`mujoco_warp/_src/render_util.py:get_rgb`) is `get_rgb(rc, camera_index, rgb_out)`. Use positional args or `camera_index=`/`rgb_out=` (the tutorial notebook does this right).

---

## 1. Concepts, simple to deep

### 1.1 Two ways to get pictures out of MJWarp
1. **Copy state back to CPU MuJoCo and use the OpenGL renderer** (`mujoco.Renderer`). This is what `notebooks/tutorial.ipynb` (cells 6, 12, 14) and `mjwarp-record --render_mode=python` (default, `mujoco_warp/record.py`) do:
   `mjw.get_data_into(mj_data, mj_model, data)` → `renderer.update_scene(mj_data)` → `renderer.render()`.
   One world at a time, needs OpenGL (on Colab: `MUJOCO_GL=egl` plus the NVIDIA EGL ICD file the tutorial writes to `/usr/share/glvnd/egl_vendor.d/10_nvidia.json`). Good for **looking** at results.
2. **The native batch ray tracer** (`mjw.render`, `_src/render.py`). It runs fully on the GPU over all `nworld` worlds and all active cameras in **one kernel launch**, and needs no OpenGL or display. Use it for **vision-based RL / data generation** (RGB, depth, segmentation per world). README: "render MuJoCo scenes at millions of frames per second".

### 1.2 The batch-render pipeline (4 calls)
```
create_render_context(mjm, nworld, ...)   # once: build BVHs, buffers, precomputed rays
  loop:
    step / forward / kinematics          # updates d.geom_xpos, d.geom_xquat, d.cam_xpos, d.cam_xmat, d.light_x*
    refit_bvh(m, d, rc)                  # refresh bounding boxes to the new poses
    render(m, d, rc)                     # one megakernel launch, dim=(nworld, total_rays)
    get_rgb / get_depth / get_segmentation  # unpack one camera into (nworld, H, W) arrays
```
- `create_render_context`: `_src/render_util.py`. Returns `RenderContext` (`_src/types.py:3014`).
- `refit_bvh`: `_src/bvh.py:refit_bvh` → `refit_scene_bvh` (+ `refit_flex_bvh` if `m.nflex`) (or `render_optix.refit_scene_bvh` for OptiX).
- `render`: `_src/render.py:render`. Builds the specialised megakernel the first time and caches it on `rc._megakernel` (test `render_test.py:test_megakernel_cached_across_renders`).
- `get_*`: `_src/render_util.py`, small unpack kernels.

### 1.3 Ray casting basics (per pixel)
- `compute_ray` (`render_util.py`): pinhole camera. Perspective: `half_height = znear*tan(fovy/2)`, `half_width = half_height*aspect`; pixel centre `u=(px+0.5)/W`, `v=(py+0.5)/H`; direction `normalize(x, y, -znear)` in **camera frame (camera looks down -Z, +Y up)**. If `cam_sensorsize[1] != 0` it uses intrinsics `fx, fy, cx, cy` (`cam_intrinsic`) and crops the sensor to the target aspect. Orthographic: direction always `(0,0,-1)`, origin offset across a `fovy`-high sensor (`ray_offset`).
- World ray: `origin = cam_xpos (+ cam_xmat @ offset for ortho)`, `dir = cam_xmat @ dir_local`; the origin is then moved forward to the near plane (`znear * inv_cos`).
- `znear = vis.map.znear * stat.extent`, `zfar = vis.map.zfar * stat.extent` (`create_render_context`). Experiment: znear 0.0085, zfar 42.5 for a small scene **[RAN]**.
- **Depth is planar (z-depth), not ray length**: `depth = dist * -ray_dir_local.z + znear` (comment "Planar depth" in `_render_megakernel`). Misses write depth 0.

### 1.4 Acceleration structure: one BVH over all worlds
- `bvh.build_scene_bvh`: computes a world-space AABB for every enabled geom in every world (`_compute_bvh_bounds`, per-type helpers `_compute_sphere_bounds`, `_compute_box_bounds`, `_compute_plane_bounds`…) and flex primitive (`_compute_flex_bvh_bounds`), all stored in flat arrays `rc.lower/upper/group` of length `nworld*(bvh_ngeom + bvh_nflexgeom)`, index `worldid*total + local_id`.
- **Groups = worlds**: `group[i] = worldid`. `wp.Bvh(lower, upper, groups=group, constructor="sah")`. `compute_bvh_group_roots` stores each world's subtree root in `rc.group_root[nworld]`. A ray of world w traverses only from `group_root[w]` via `wp.bvh_query_ray(bvh_id, o, dir, group_root)`, so worlds never see each other.
- **Two-level**: meshes and heightfields have their own `wp.Mesh` BVHs in their local frame (`build_mesh_bvh`, `build_hfield_bvh`); the scene BVH only holds a box around them (`mesh_bounds_size`). On a hit of that box, `ray_mesh_with_bvh` (`_src/ray.py`) transforms the ray into the mesh frame and traverses the triangle BVH. Mesh BVHs are shared by all worlds (mesh vertex data is not per-world).
- **Mesh reframing**: `build_mesh_bvh` checks whether rotating the vertices back to the authored frame shrinks the summed triangle AABB area by at least `_REFRAME_MIN_GAIN = 1.25`. If so, it rotates the vertices and stores `mesh_bvh_rot`, and sets `has_reframed_meshes`.
- **Heightfield greedy meshing**: `_optimize_hfield_mesh` merges coplanar adjacent cells into bigger rectangles before building the triangle BVH.
- **refit vs rebuild**: each frame only `rc.bvh.refit()` (topology fixed, boxes updated). Cheap; it must happen after every pose change (see pitfalls).
- **Enabled geom groups**: `enabled_geom_groups=[0,1,2]` default; geoms in other groups (commonly 3 = collision meshes) are left out of the BVH entirely (`geom_enabled_idx`).

### 1.5 The megakernel (`_build_megakernel`)
- One Warp kernel, `wp.tid() -> (worldid, rayid)`; `rayid` runs over the concatenation of all active cameras' pixels (`rc.total_rays = sum W*H`). It finds its camera by scanning cumulative sizes over `cam_res`.
- **Specialisation via `wp.static`**: the kernel is generated per context with `module="unique"`. Branches are removed at compile time for geom types not present (`rc.geom_ray_types`, e.g. `(2, 6)` = sphere, box **[RAN]**), no textures, no shadows, no spot lights, default attenuation, no ortho cameras, no specular/emission/per-light ambient, no splats, no seg/RGB. This is why changing flags means a **new context and a recompile** (first render on CPU ~4 s; cached after) **[RAN]**.
- Per pixel: `cast_ray` (closest hit; ties go to the higher geom index, "like MuJoCo's GL depth test") → write seg/depth for sample 0 → if RGB: skybox/background for misses, otherwise shade.
- **Shading** (`_make_compute_lighting`): Blinn-Phong. `result = emission*base + ambient terms + Σ_lights base*diffuse*ndotl*atten*visible + spec*mat_spec*(n·h)^(shininess*128)` then clamp to [0,1]. Directional (type 1), spot (type 0: cutoff in degrees, `pow(cos, exponent)`), point lights; attenuation `1/(a0 + a1 d + a2 d²)`. The headlight (`vis.headlight`) acts as an extra directional light at the camera. With no lights and no headlight a fallback ambient `NO_LIGHT_AMBIENT_FALLBACK = 0.3` applies. Constants: `MAX_SHININESS=128`, `DEFAULT_MAT_SPECULAR=0.5`.
- **Shadows** (`use_shadows=True`): secondary "any-hit" ray (`_make_cast_ray(first_hit=True)`) from `hit + n*1e-4` toward the light; occluded light is scaled by `shadow_light_fraction` (default 0.3; 0 = black shadow).
- **Textures**: material texture id `mat_texid[w, mat, 1]` (role RGB); per-geom-type UV mapping (`_texture_plane/_sphere_ellipsoid/_cylinder/_capsule/_box/_hfield/_mesh`), `wp.Texture2D` with linear filtering (`create_warp_texture`, converts uint8 to float RGBA). `texrepeat`, `texuniform` handled. By-reference textures (`tex_adr==-1`) get decoded via `mujoco.mj_loadTexture` (`texture_pixels`).
- **Skybox** (`render_skybox=True`, needs an `mjTEXTURE_SKYBOX`): `sample_skybox` cube-map lookup for misses; otherwise `background_color` (default black).
- **Vertex normals**: smooth mesh shading from authored normals (`enable_vertex_normals`, `vertex_normal` falls back to the face normal when unusable).
- **Backface culling** (default True): drops hits whose normal faces away (camera inside a geom). With culling off, hits are shaded two-sided.
- **Supersampling** `samples_per_pixel=n`: n×n sub-rays per pixel, colour averaged; depth/seg come from sample 0 only. Ray buffer grows to `total_rays*n²` (verified: 1200 rays → `ray.shape=(4800,)` for n=2 **[RAN]**). Requires at least one RGB camera.

### 1.6 Output buffers and layout (verified **[RAN]**, exp1.py)
Two cameras, cam0 32×24 rgb+depth+seg, cam1 16×16 rgb+seg, nworld=4:
```
nrender 2   total_rays 1024 (=768+256)
cam_res [[32,24],[16,16]]  (W,H !)    cam_id_map [0,1]
rgb_adr [0,768]   depth_adr [0,-1]   seg_adr [0,768]     (-1 = this camera has no such output)
rgb_data   (4, 1024) uint32   # packed 0xAARRGGBB, alpha always 255
depth_data (4, 768)  float32  # metres, planar; 0 = miss
seg_data   (4, 1024) vec2i    # (objid, objtype); (-1,-1) background; type 5=mjOBJ_GEOM, 9=mjOBJ_FLEX
ray        (1024,)   vec3     # precomputed camera-frame directions
group_root [10,11,13,14]      # BVH node ids, one per world
```
- Buffer per world = all cameras' pixels concatenated; camera c starts at `rgb_adr[c]`; within a camera pixels are **row-major** `py*W + px` (in main the rays are traversed in 8-row tiles for coherence, `tile_pixel`, but stored row-major).
- `get_rgb(rc, cam, out)`: out `wp.array3d[vec3]` shape `(nworld, H, W)`, floats in [0,1]. Verified identical to manual unpack `((p>>16)&255, (p>>8)&255, p&255)/255` **[RAN]**.
- `get_depth(rc, cam, depth_scale, out)`: `clamp(depth/depth_scale, 0, 1)`. **Lossy**; read `rc.depth_data` directly for metric depth.
- `get_segmentation(rc, cam, out)`: `wp.vec2i` `(nworld,H,W)`.
- Defaults when `cam_res/render_*` are None: taken from the MJCF camera (`resolution="64 64" output="rgb depth seg"`, i.e. `mjm.cam_resolution`, `mjm.cam_output` bits `mjCAMOUT_RGB/DEPTH/SEG`). A camera with no resolution gives `cam_resolution [[1,1]]`; default output was rgb=True, depth=False **[RAN]**. So always pass `cam_res` explicitly in notebooks.
- `cam_active` accepts bools (length ncam), names, or indices; `[]` = no cameras. A model with no cameras gives `nrender 0`, `rgb_data (1, 0)` **[RAN]**; `mjwarp-record --render_mode=warp` raises if `ncam==0`.

### 1.7 Domain randomisation of visuals (per-world Model fields)
- Model fields with a leading `*` batch dim (e.g. `geom_rgba`, `geom_size`, `mat_texid`, `cam_fovy`, `cam_intrinsic`, `light_*`, `mat_rgba`…) are indexed `worldid % shape[0]` by the kernel. Allocate per-world copies with `mjw.put_model(mjm, batch_sizes={"geom_rgba": nworld, ...})` (`_src/io.py:put_model`) and write them with `.assign`.
- **Verified [RAN] (exp5.py)**: `batch_sizes={"cam_fovy":3,"geom_rgba":3}` gives shapes `(3,1)`, `(3,2)`; per-world colours render (red/green/blue sphere).
- **Camera intrinsics/FOV DR needs `use_precomputed_rays=False`**. With precomputed rays, sphere pixel counts per world were `[52,52,52]` for fovy 20/45/90 (ignored!); with `use_precomputed_rays=False` they were `[256,52,12]` **[RAN]**. The docstring says so: "When using domain randomization for camera intrinsics, set to False."
- Per-world geom size: `render_test.py:test_render` sets `m.geom_size = wp.array(np.repeat(...))` then `mjw.kinematics` + `refit_bvh`.
- Per-world textures: `render_test.py:test_render_per_world_mat_texid_batch_size` (`batch_sizes={"mat_texid": nworld}`, then swap texture ids and re-render, no rebuild needed).
- Per-world skybox: overwrite `rc.skybox_tex_id` / `rc.skybox_face_width` with length-nworld arrays (`test_per_world_skybox_textures`).
- Moving cameras: write `d.cam_xpos/d.cam_xmat` after kinematics (`contrib/render.py:_set_orbit_camera` builds an orbit; columns of `cam_xmat` = camera x, y, z axes with z = -forward).

### 1.8 Flex (cloth / soft bodies) rendering
- 1D flex (ropes): one capsule per edge in the scene BVH (`flex_geom_edgeid >= 0`).
- 2D/3D flex: one box per flex in the scene BVH plus a per-flex triangle mesh (`build_flex_bvh`: `_build_flex_2d_elements`, `_build_flex_2d_sides`, `_build_flex_3d_shells`), with `nworld` groups. `refit_flex_bvh` recomputes vertex normals (`accumulate_flex_vertex_normals`, `deterministic` option), moves the face points (`_update_flex_2d_face_points` offsets both sides by `flex_radius`; `flex_render_smooth`) and refits.
- Seg reports `(flex_id, mjOBJ_FLEX=9)`.
- **[RAN] exp4.py**: an 8×8 `flexcomp type="grid" dim="2"` above a sphere: `bvh_nflexgeom 1`, `flex_geom_edgeid [-1]`, flex pixels 14 at t=0 → 50 after 100 steps (cloth falls into view), seg types `[-1, 5, 9]`. `d.flexvert_xpos` shape `(nworld, nflexvert)`.
- Benchmarks: `benchmarks/cloth/__init__.py` has `cloth` (30×30 towel over the humanoid mannequin, 256 worlds, CG solver, sparse) and `cloth_render` (`"function": "render"`, 32 worlds, 64×64). `benchmarks/render/` has `primitives` (8192 worlds, 5×5 grids of each primitive, `function: render`).
- Physics limits (`_src/io.py`): `dof=quadratic` interpolation not supported; rigid flexes not implemented; self-collision and passive contact of trilinear/quadratic flexes not implemented; discrete integrator + general attachments requires CG. README: "Flex: experimental".

### 1.9 Gaussian splats (3DGS)
- Optional `splat_position (n,3)`, `splat_rotation (n,4) wxyz`, `splat_scale (n,3) std-devs`, `splat_rgba (n,4)`, `splat_adr` (group offsets), `splat_group_id (nworld,)` (which splat group each world sees). All four attributes must be given together (ValueError otherwise).
- `bvh.build_splat_bvh` bounds each Gaussian by the ellipsoid where response = `SPLAT_MIN_RESPONSE/opacity` (`_compute_splat_bounds`).
- `render.shade_splats`: front-to-back alpha compositing along the ray, at most `_MAX_SPLAT_HITS=32` sorted hits per BVH pass, stopping at transmittance `0.005`; `ray_splat` computes the peak Gaussian response along the ray. Geometry occludes splats (`max_distance = dist` of the geom hit). Depth is recorded once accumulated opacity exceeds 90%.
- Only degree-0 SH colour (`contrib/render.py:_load_ply_splats` converts `f_dc_*` with `_SH_C0`, applies sigmoid to opacity and exp to scale). Docs: no view-dependent higher-degree SH.
- Static splats: `refit_splat_bvh(rc)` after editing `rc.splat_*` arrays.
- Not supported by OptiX.

### 1.10 OptiX backend (git main only)
- `create_render_context(..., backend="optix")`, needs `pip install "mujoco-warp[optix]"` (warp-optix, **Python 3.12 only**) and an RTX-class GPU.
- `render_optix.py`: meshes/hfields become triangle GASes shared across worlds; analytic geoms are instances of a padded unit cube AABB scaled per instance, intersected with the same `ray.py` primitives; worlds sit in separate cells of a cubic grid (`world_offset`, spacing `3*extent`, `extent=max(4*stat.extent,1)`); planes are intersected outside the IAS. Instance id = `worldid*ngeom + geom`, so **nworld*ngeom < 2^24**.
- Falls back to "warp" with a warning for flexes, splats, missing package, or an unsupported device (`create_render_context`).
- **Cannot be recorded into CUDA graphs** (`cli.unroll` runs it eagerly). `mjw.rays(..., rc=...)` raises for non-warp backends.

### 1.11 Ray queries without images: `mjw.ray`, `mjw.rays` (`_src/ray.py`)
- `ray(m, d, pnt, vec, geomgroup=None, flg_static=True, bodyexclude=-1, rc=None) -> (dist, geomid, normal)`, `pnt/vec` shape `(1,1)` or `(nworld,1)`.
- `rays(m, d, pnt, vec, geomgroup, flg_static, bodyexclude[nray], dist, geomid, normal, rc=None)` writes into preallocated `(nworld, nray)` outputs; pass `rc` to use the BVH. Good for lidar / rangefinder demos.
- **[RAN]**: a sphere moved to x=1, ray from (1,-3,.5) along +y gives `dist 2.8, geomid 1, normal (0,-1,0)`; the ray from x=0 misses (-1).

### 1.12 CLI tools (`pyproject.toml [project.scripts]`)
| Command | File | What it does | Colab? |
|---|---|---|---|
| `mjwarp-testspeed` | `mujoco_warp/testspeed.py` | benchmark `--function=step` (or any public fn, e.g. `render`, which runs `refit_bvh`+`render` per step), `--event_trace` | yes (headless) |
| `mjwarp-record` | `mujoco_warp/record.py` | record `.gif`/`.webp` rollouts; `--render_mode=python` (MuJoCo OpenGL free camera orbit, needs EGL) or `warp` (batch renderer, model must have a camera); `--channel rgb/depth/segmentation` (depth/seg warp mode only) | yes, with `MUJOCO_GL=egl` for python mode |
| `mjwarp-viewer` | `mujoco_warp/viewer.py` | interactive **MuJoCo Studio** web viewer (`mujoco.studio.launch_web`, `gfx="web", open_browser=True`); steps with a CUDA graph and copies world 0 back to `MjData` every frame; `--engine=c` for the CPU MuJoCo reference | **no** (needs a local browser/port); run locally |
| `mjwarp-render` | `contrib/render.py` (not an installed script; run `python contrib/render.py`) | single frame PNG (+ depth PNG), `--tiled` 4×4 grid of 16 worlds, `--rollout` gif, `--orbit` gif, `--splat file.ply` | yes |
| `benchmarks/run.py -f NAME [--view]` | `benchmarks/run.py` | runs benchmark suites; `--view` launches `mjwarp-viewer` via `uv run --extra viewer` | run.py yes; --view no |

Shared flags (`_src/cli.py`): `--nworld` (default **8192**, record/viewer set 1), `--nstep 1000`, `--nconmax/--njmax/--nccdmax/--nvmax`, `-o/--override "opt.solver=cg"`, `--keyframe`, `--event_trace`, `--noise_std 0.01 --noise_rate 0.1` (Ornstein-Uhlenbeck ctrl noise from a Halton sequence, `_ctrl_noise`), `--device`, `--replay ctrl.npz`, and render flags `--render_width/--render_height` (multi), `--render_rgb/--render_depth/--render_seg`, `--cam_active`, `--camera_name`, `--render_textures`, `--render_shadows`, `--render_backface_culling`, `--render_skybox` (default True), `--render_backend warp|optix`.
- `cli.init_structs(fn, mjm)` only builds a RenderContext if `fn` has a `RenderContext` type hint (`get_type_hints`).
- `cli.unroll` captures `fn` into a CUDA graph once (except OptiX), then `wp.capture_launch` per step, `wp.synchronize()`, and the callback gets `(step, trace, latency)`.
- **Docstring bug:** `record.py` usage says `--video <output_path>` but the flag is `--output` (required). Only `.gif`/`.webp` are accepted (no mp4, despite the example "humanoid.mp4").
- `record` defaults: 320×240, fps 30 (`render_every = 1/(fps*timestep)`), noise off.

Colab command examples (**[SRC]**):
```bash
!mjwarp-record /content/mujoco_warp/benchmarks/humanoid/humanoid.xml --output humanoid.gif --nstep 300
!MUJOCO_GL=egl mjwarp-record benchmarks/humanoid/humanoid.xml --output h.webp
!mjwarp-record benchmarks/render/primitives.xml --output prim.gif --render_mode warp --channel depth --nstep 200
!mjwarp-testspeed benchmarks/render/primitives.xml --function=render --nworld=8192 --nstep=100
!python contrib/render.py benchmarks/render/primitives.xml --tiled --output_rgb tiled.png
```

---

## 2. Verified usage snippets

### 2.1 Minimal batch render, 16 worlds in a grid (tutorial cell 18 pattern; core calls **[RAN]** on CPU)
```python
import numpy as np, mujoco, warp as wp, mujoco_warp as mjw
mjm = mujoco.MjModel.from_xml_string("""
<mujoco><option timestep="0.01666"/><worldbody>
  <light name="top" dir="0 -1 -1" directional="true"/>
  <camera name="camera" pos="0 2 0" quat="0 0 1 1"/>
  <body name="box_and_sphere" euler="0 0 -30">
    <joint name="swing" type="hinge" axis="1 -1 0" pos="-.2 -.2 -.2"/>
    <geom name="red_box" type="box" size=".2 .2 .2" rgba="1 0 0 1"/>
    <geom name="green_sphere" pos="-.2 -.2 -.2" size=".1" rgba="0 1 0 1"/>
  </body></worldbody></mujoco>""")
NWORLD, (W, H) = 16, (128, 128)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD)
rc = mjw.create_render_context(mjm, nworld=NWORLD, cam_res=(W, H),
                               render_rgb=True, render_depth=True, render_seg=True)
qpos = d.qpos.numpy(); qpos[:, 0] = np.random.uniform(0, 2*np.pi, NWORLD); d.qpos.assign(qpos)
mjw.forward(m, d)            # fills geom_xpos/xquat, cam_xpos/xmat
mjw.refit_bvh(m, d, rc)      # REQUIRED after poses change
mjw.render(m, d, rc)
rgb = wp.zeros((NWORLD, H, W), dtype=wp.vec3); mjw.get_rgb(rc, 0, rgb)
img = rgb.numpy()                                   # (16, 128, 128, 3) float32 in [0,1]
grid = img.reshape(4, 4, H, W, 3).transpose(0, 2, 1, 3, 4).reshape(4*H, 4*W, 3)
# media.show_image(grid)   # mediapy on Colab
```
Metric depth: `rc.depth_data.numpy()[:, rc.depth_adr.numpy()[0]:][:, :W*H].reshape(NWORLD, H, W)`.

### 2.2 Render a rollout as a video (GPU, graph-captured) **[SRC]** (pattern from `cli.unroll` + `contrib/render.py --rollout`)
```python
with wp.ScopedCapture() as cap:          # GPU only: CUDA graph of the physics step
    mjw.step(m, d)
with wp.ScopedCapture() as rcap:         # render can be captured too (warp backend)
    mjw.refit_bvh(m, d, rc); mjw.render(m, d, rc)
frames = []
for t in range(300):
    wp.capture_launch(cap.graph)
    if t % 4 == 0:
        wp.capture_launch(rcap.graph)
        mjw.get_rgb(rc, 0, rgb)
        frames.append((rgb.numpy()[0] * 255).astype(np.uint8))
# media.show_video(frames, fps=1/(4*mjm.opt.timestep))
```
`render_test.py:test_render_graph_capture` proves render is graph-capturable and gives identical output.

### 2.3 Lighting/feature toggles **[RAN]** (exp3.py)
Top-down camera, directional light, box above plane, headlight off: `use_shadows=True` changed 12 of 1024 pixels; a shadowed floor pixel went 0.627 → 0.188 (≈0.3 × direct, the `shadow_light_fraction` default).

### 2.4 Stale-BVH demonstration **[RAN]** (exp2.py), great for a "why refit?" animation
```
sphere pixels at start:          16
moved x+1, NO refit:              0   <- the sphere vanished: its old AABB is culled
moved x+1, after refit:          18
```

### 2.5 CPU timing **[RAN]** (exp5.py, 64×64, 1 camera, 2 geoms)
nworld 1: 0.6 ms (1.7k fps); 16: 7.8 ms (2.0k fps); 64: 30.5 ms (2.1k fps). CPU scales linearly; the GPU is orders of magnitude faster (benchmark `primitives` = 8192 worlds). First compile of the megakernel ~4 s on CPU, cached in `~/.cache/warp/<ver>`.

### 2.6 PyTorch handoff **[SRC]** (Warp API; torch not installed here, DLPack checked with numpy **[RAN]**)
```python
import torch
rgb = wp.zeros((nworld, H, W), dtype=wp.vec3, device="cuda")
mjw.get_rgb(rc, 0, rgb)
obs = wp.to_torch(rgb)            # zero-copy, torch.float32, shape (nworld, H, W, 3)
obs = obs.permute(0, 3, 1, 2)     # NCHW for a CNN
# actions from torch back into MJWarp:
wp.copy(d.ctrl, wp.from_torch(actions_tensor.contiguous()))
```
Verified: `np.from_dlpack(wp.zeros((2,4,5), dtype=wp.vec3))` gives shape `(2,4,5,3) float32`; a uint32 array stays `uint32` (torch's uint32 support is limited, so unpack with `get_rgb` first). `wp.to_torch`, `wp.from_torch`, `wp.to_jax`, `wp.jax_callable`, `wp.JaxCallableGraphMode` all exist in warp 1.19 **[RAN]**.

### 2.7 JAX: wrap an MJWarp step as a JAX op **[SRC]** (`_src/jax_test.py`, `contrib/jax_unroll.py`)
```python
import os; os.environ["XLA_FLAGS"] = "--xla_gpu_graph_min_graph_size=1"   # before importing jax
import jax, jax.numpy as jp
def warp_step(qpos_in: wp.array2d[wp.float32], qvel_in: wp.array2d[wp.float32],
              qpos_out: wp.array2d[wp.float32], qvel_out: wp.array2d[wp.float32]):
    wp.copy(d.qpos, qpos_in); wp.copy(d.qvel, qvel_in)
    mjw.step(m, d)
    wp.copy(qpos_out, d.qpos); wp.copy(qvel_out, d.qvel)
warp_step_fn = wp.jax_callable(warp_step, num_outputs=2,
    graph_mode=wp.JaxCallableGraphMode.WARP,
    output_dims={"qpos_out": (NWORLD, mjm.nq), "qvel_out": (NWORLD, mjm.nv)})
def unroll(qpos, qvel):
    def body(c, _): return warp_step_fn(*c), None
    return jax.lax.scan(body, (qpos, qvel), length=1000)[0]
fn = jax.jit(unroll).lower(qpos0, qvel0).compile()
```
- The closure captures the global `m, d`; the JAX arrays are copied into `d` each call. `jax_test.py` skips unless `jax.default_backend()=="gpu"` and Warp is CUDA. It also sets `XLA_PYTHON_CLIENT_ALLOCATOR=platform` to avoid JAX preallocating 75% of GPU memory, which would starve Warp. **Colab tip:** set `XLA_PYTHON_CLIENT_PREALLOCATE=false` or `..._MEM_FRACTION` before importing jax.
- `contrib/jax_unroll.py` reports "Total steps per second" for 8192 humanoids × 1000 steps. Its path `"../benchmark"` is stale (the folder is `benchmarks`), a pitfall if copied.
- Extras: `pip install "mujoco-warp[cuda]"` installs `jax[cuda12]` (pyproject comment: temporary until MJX:Warp lands).
- `io_jax_test.py` (do not edit without the MJX team) checks that every `Model`/`Data` field annotation is JAX-compatible (ints/bools/floats/arrays/tuples, `Callback` skipped). This is the contract MJX relies on to wrap MJWarp structs.

### 2.8 MJX `impl="warp"` (concept, docs only)
MuJoCo docs: "MJX offers a JAX API for part of the MJWarp API. The implementation is specified with `impl='warp'`." README: use MJWarp from JAX "via MJX and the legacy MJX environments in Playground's `rss2025` directory". MJX is a separate package (`pip install mujoco-mjx`; `from mujoco import mjx` failed here with only mujoco-core **[RAN]**). The exact MJX call (e.g. `mjx.put_model(mjm, impl="warp")`) is not in this repo; course authors must check the installed MJX version before printing a snippet. Treat it as "point to the docs".

### 2.9 RL example: `contrib/apptronik_apollo_locomotion.ipynb` **[SRC]**
Flow worth a diagram:
1. Menagerie Apollo model via `mujoco_playground` (`mjx_env.ensure_menagerie_exists()`), with MJWarp-friendly `contrib/xml/apptronik_apollo.xml` and `scene.xml` copied over.
2. `NWORLD=8192`, `nconmax=10*NWORLD`, `njmax=40`, `opt.iterations=5`, `ls_iterations=10`.
3. `mjwarp_step(ctrl, qpos, qvel, qacc_warmstart -> qpos, qvel, xpos, xmat, qacc_warmstart, subtree_com, cvel, site_xpos)`: 4 substeps (`ctrl_dt 0.02 / sim_dt 0.005`). A custom kernel `xquat_to_xmat` converts orientations because MJX observations want `xmat`. Wrapped with `wp.jax_callable(num_outputs=8, output_dims=...)`.
4. `jax.custom_batching.custom_vmap` makes `step(d: mjx.Data)` callable inside Brax's `vmap`: the vmap rule calls the batched Warp op once for all 8192 envs and marks which `mjx.Data` fields are batched.
5. `Joystick(mjx_env.MjxEnv)`, a Playground-style env (rewards: velocity tracking, feet air time and phase, pose…), trained with Brax PPO (`num_timesteps=50M`, `num_envs=8192`, `unroll_length=20`, `batch_size=256`).
6. Rollout with `jax.lax.scan`; the policy action is tiled to NWORLD because the Warp op is fixed to NWORLD batch. Video via `env.render(..., camera="track")` + `mediapy` (CPU OpenGL renderer, needs EGL).
Pitfalls: it is labelled contrib (may be stale); it needs `jax[cuda12_local]`, `playground`, `brax`, `mediapy`; the hard-coded NWORLD batch forces the tile trick; it is long-running (50M steps).

### 2.10 Ecosystem map (README "Integrating MuJoCo Warp" + tutorial cell 19)
- **MuJoCo Playground** (google-deepmind/mujoco_playground): GPU RL env suite. The README calls Playground and **reaf-sim** "the official first-party PyTorch simulation frameworks"; JAX legacy MJX envs live in `rss2025/`.
- **Isaac Lab** integrates MJWarp via **Newton** (NVIDIA physics platform; MJWarp is "part of the Newton project", files are copyright "The Newton Developers").
- **mjlab** (mujocolab/mjlab): Isaac Lab's manager-based API directly on MJWarp (PyTorch).
- **JAX**: `wp.jax_callable` (this repo) or MJX `impl='warp'`.
- **PyTorch**: `wp.to_torch/from_torch` zero-copy; docs: `mjw.step` "works well with PyTorch".
Course should present these as pointers, not run them (heavy installs, APIs outside this repo).

---

## 3. Data structures and data flow

```
MjModel (host) --put_model(batch_sizes)--> Model (device): geom_type[ngeom], geom_size[*,ngeom], geom_rgba[*,ngeom],
                                                         cam_fovy[*,ncam], cam_intrinsic[*,ncam], light_*[*,nlight], mat_*[*,nmat]
Data (device, nworld): geom_xpos[nworld,ngeom] vec3, geom_xquat[nworld,ngeom] quat, cam_xpos/xmat[nworld,ncam],
                       light_xpos/xdir[nworld,nlight], flexvert_xpos[nworld,nflexvert]
RenderContext:
  static: cam_res[ncam'] (W,H), cam_id_map, enabled_geom_ids[bvh_ngeom], geom_ray_types, flags, znear/zfar
  BVHs:   bvh (wp.Bvh over nworld*(bvh_ngeom+bvh_nflexgeom) AABBs, groups=world), group_root[nworld],
          mesh_registry/mesh_bvh_id[nmesh] (wp.Mesh, local frame), hfield_bvh_id[nhfield], flex_bvh_id[nflex],
          flex_group_root[nworld,nflex], splat_bvh, splat_group_root[nworld]
  rays:   ray[total_rays*spp^2], ray_offset (precomputed camera-frame dirs; empty if use_precomputed_rays=False)
  out:    rgb_data[nworld, Σrgb pixels] uint32, depth_data[nworld, Σdepth px] f32, seg_data[nworld, Σseg px] vec2i
          rgb_adr/depth_adr/seg_adr[ncam'] (-1 if off)
Flow per frame: step -> (geom_xpos, cam_xmat...) -> refit_bvh (lower/upper -> bvh.refit) -> render
                megakernel(worldid, rayid) -> packed buffers -> get_rgb (nworld,H,W) vec3 -> numpy/torch/jax
```
`warp_util.mark_batched(rc)` tags arrays whose spec starts with `*`/`nworld` as batched (`_is_batched`), used by the JAX/FFI wrappers. `_build_megakernel` comments "Static parameters extracted for JAX FFI closure".

---

## 4. Diagram and animation ideas (specific)

1. **"Two render paths" split diagram**: left lane GPU → `get_data_into` → CPU MjData → OpenGL (one world, needs EGL); right lane GPU → BVH → megakernel → 8192 images, all staying on the GPU. Animate a packet moving; the left lane gets a bottleneck "PCIe copy" icon.
2. **Pinhole camera / compute_ray**: SVG frustum; a pixel grid on the near plane; a ray shoots through pixel centre `(px+0.5, py+0.5)`. Slider for fovy changes the frustum (CSS var). Toggle perspective/ortho: rays become parallel and the origin slides across the sensor.
3. **Planar vs ray depth**: side view, a ray hitting a wall at angle θ; show `dist` (hypotenuse) and `dist*cosθ` (z-depth) as two coloured segments; a flat wall gives constant depth across the image.
4. **Grouped BVH over worlds**: one tree whose root splits into world subtrees (colour per world); a ray from world 2 lights up only the world-2 subtree (`group_root[2]`). Then animate `refit`: boxes stretch to follow moving geoms while the tree shape stays fixed.
5. **Stale BVH failure** (from exp2): sphere moves right while its AABB stays put; the ray passes through the empty box, then the sphere "vanishes" in the rendered image. Press "refit" and the box snaps to the sphere and the pixels reappear (16 → 0 → 18 counts).
6. **Two-level traversal**: scene BVH box → transform ray into mesh frame (rotate animation) → triangle BVH → barycentric hit (u,v) → vertex-normal interpolation.
7. **Megakernel thread map**: 2D grid (rows = worlds, columns = rays of cam0 | cam1); hover a cell and see `(worldid, rayid) → camid, px, py`. Show the main-branch 8-row tile ordering vs row-major storage.
8. **Output buffer layout**: horizontal bar per world, segments `[cam0 rgb 768][cam1 rgb 256]`, with arrows for rgb_adr; a separate depth bar with cam1 = -1 (absent). Bit diagram of a uint32 pixel `AA RR GG BB`.
9. **Shading equation builder**: sphere with toggles (ambient, diffuse, specular, headlight, shadow, emission); each term adds a layer (CSS blend), plus a formula with the active terms highlighted. Shadow ray drawn from the hit point to the light, blocked by a box, with light scaled by 0.3.
10. **Supersampling**: one pixel split into n×n sub-pixel dots; the edge pixel colour is the average; jagged vs smooth edge.
11. **Domain randomisation mosaic**: 4×4 grid of worlds with different colours/fovy (from exp5: fovy 20/45/90 → 256/52/12 sphere pixels); a "precomputed rays" toggle that, when on, makes all FOVs identical (the pitfall).
12. **Segmentation colouring**: seg ids → palette (like `record.py:_colorize_segmentation`, seed 42), with legend geom vs flex (type 5 vs 9).
13. **Gaussian splat compositing**: a ray through 5 translucent ellipses sorted front-to-back; a transmittance bar decreasing `T *= (1-α)`; depth marker where accumulated opacity passes 90%; stop when T < 0.005.
14. **Cloth rendering**: 2D flex grid; show the per-flex mesh with two offset faces (±radius) and a vertex normal arrow fan; frames of the cloth falling (pixel counts 14 → 50).
15. **JAX bridge**: JAX `lax.scan` box → `jax_callable` → Warp step (copy in → step → copy out) → back; a second view of `custom_vmap` turning 8192 per-env calls into one batched call.
16. **Ecosystem map**: hub MJWarp; spokes JAX (MJX impl=warp, Playground rss2025), PyTorch (Playground, reaf-sim, mjlab), Newton → Isaac Lab; colour by framework.
17. **Colab vs local matrix** (table graphic): batch render ✓, mjwarp-record ✓ (EGL for python mode), testspeed ✓, mediapy video ✓, mjwarp-viewer ✗ (web Studio needs a local browser), OptiX ? (needs Python 3.12 + warp-optix + RTX; Colab's Python version must match).

---

## 5. Pitfalls, unsupported features, gotchas

- **Always `refit_bvh` after the state changes and before `render`.** The BVH is built at context creation from a fresh `MjData` after `mj_forward` (i.e. **qpos0**, not your data). Without refit, moved objects are culled (verified: the sphere vanished).
- `render` reads poses from `d.geom_xpos/xquat/cam_x*`, so run `forward`/`kinematics`/`step` first. After writing `qpos` by hand, call `mjw.forward` or `mjw.kinematics`.
- `cam_res` is **(width, height)**; output arrays are **(nworld, height, width)**.
- `get_rgb` signature: `(rc, camera_index, rgb_out)`. The readthedocs snippet uses wrong kw names.
- `camera_index` is the index among **active** cameras (after `cam_active` filtering), not the MuJoCo cam id; `rc.cam_id_map` maps them.
- `get_depth` clamps to [0,1] after dividing by `depth_scale`; misses are 0 (not inf). For metric depth use `rc.depth_data`.
- Cameras with `render_rgb=False` have `rgb_adr=-1`; `get_rgb` would then read garbage or out of bounds, so check first (`contrib/render.py:_rgb_frame` does).
- Defaults from the MJCF camera: without `resolution`/`output` attributes you get 1×1 and RGB only. Pass `cam_res`, `render_rgb`, `render_depth` explicitly.
- Changing any creation flag needs a new context (and recompiles the megakernel; ~4 s on CPU, seconds on GPU). Make the context once.
- Per-world FOV/intrinsics need `use_precomputed_rays=False` (verified).
- Per-world model values need `put_model(..., batch_sizes={...})`; otherwise the leading dim is 1 and all worlds share it.
- Geoms outside `enabled_geom_groups` (default 0,1,2) are invisible, and transparent geoms (`rgba[3]==0`) are skipped.
- No global illumination, reflections or PBR (`reflectance` in materials is ignored), no fog/haze, no higher-order SH for splats. Expect it to look like simple OpenGL, not photoreal.
- `samples_per_pixel>1` costs n² and needs an RGB camera; depth/seg come from sample 0.
- `nworld` from the CLI defaults to **8192**; on Colab with big scenes and render that can exceed memory. Pass `--nworld`.
- OptiX: main branch only, Python 3.12, no flex/splats, no CUDA graph capture, `nworld*ngeom < 2^24`, `rays()` refuses it. The fallback to warp is a warning, not an error; read the warnings.
- CUDA graphs: viewer/cli use `wp.ScopedCapture` only `if wp.get_device().is_cuda`. On CPU with warp 1.19, `ScopedCapture` did not raise in my test, but there is no speed benefit; don't teach graphs on CPU. Changing `m.opt` fields may require re-capture (docs; `viewer._make_warp_step_fn` re-puts the model and re-captures when `mjm.opt` changes).
- `mjwarp-viewer` is a MuJoCo Studio **web** app (`open_browser=True`); it won't work in Colab. Use `mjwarp-record` or mediapy instead. It needs `pip install "mujoco-warp[viewer]"` (mujoco-studio, mujoco-studio-wasm, pillow, `mujoco-core[rendering]`).
- `mujoco.Renderer` on Colab needs the EGL setup from the tutorial (`MUJOCO_GL=egl` + ICD json). `render_test.py` probes `_HAS_RENDERER` the same way.
- `mjwarp-record`: flag is `--output` (docstring says `--video`); gif/webp only.
- JAX: set `XLA_FLAGS=--xla_gpu_graph_min_graph_size=1` **before** importing jax (all repo examples do), and limit JAX preallocation so Warp has memory. `jax_callable` output shapes are fixed to NWORLD.
- JAX interop is "temporary" per repo comments (`pyproject.toml` cpu/cuda extras, `jax_test.py`): "remove after we land MJX:Warp".
- Float32 everywhere; `--engine=c` in the viewer compares with float64 MuJoCo.
- Flex limits: experimental; quadratic dof, rigid flexes, interpolated self-collision unsupported (raise `NotImplementedError` in `put_model`).

---

## 6. Suggested chapter breakdown (easy → hard)

1. **Seeing your simulation (Colab setup + OpenGL path)**: EGL setup, `get_data_into` + `mujoco.Renderer`, mediapy videos, `mjwarp-record` CLI. Colab: yes.
2. **The batch renderer in four calls**: `create_render_context` → `refit_bvh` → `render` → `get_rgb/depth/segmentation`; 16-world image grid; buffer layout and the uint32 pixel format; (W,H) vs (H,W). Viz: buffer bars, bit diagram.
3. **Cameras and rays**: MJCF camera attributes (`resolution`, `output`, fovy, intrinsics, ortho), `compute_ray`, znear/zfar, planar depth, multi-camera heterogeneous resolutions, `cam_active`, moving/orbit cameras by writing `cam_xpos/xmat`. Viz: frustum slider, planar depth.
4. **BVHs: how 8192 worlds share one tree**: AABBs per geom type, grouped BVH, refit vs rebuild, stale-BVH demo, two-level mesh/hfield BVHs, enabled geom groups, `mjw.ray/rays` lidar demo. Viz: grouped tree, stale box.
5. **Shading: lights, materials, textures, shadows, skybox**: Blinn-Phong terms, headlight, spot/point/directional, `shadow_light_fraction`, textures/UV per primitive, skybox, supersampling, the feature flags and compile-time specialisation (megakernel). Viz: shading equation builder.
6. **Visual domain randomisation for sim-to-real**: `put_model(batch_sizes=...)` for rgba/size/mat_texid/fovy, `use_precomputed_rays=False`, per-world skybox, camera pose noise; performance tips (resolution, flags off, graph capture). Viz: DR mosaic.
7. **Soft bodies on screen: flex/cloth rendering**: flexcomp grid, how flexes enter the BVH, refit_flex_bvh, seg type FLEX, the cloth benchmark, limits. Viz: falling cloth.
8. **Gaussian splats and OptiX (advanced/optional)**: 3DGS attributes, compositing, PLY loading via contrib/render.py; the OptiX backend, its limits, version caveat.
9. **CLI toolbox and benchmarking**: testspeed (`--function=render`, `--event_trace`), benchmarks/run.py, contrib/render.py tiled/orbit/rollout, viewer (local only). Colab vs local matrix.
10. **Interop I: PyTorch**: `wp.to_torch` of rendered observations, NCHW, actions back via `wp.from_torch`, keeping everything on the GPU; ecosystem (Playground/reaf-sim, mjlab, Isaac Lab via Newton).
11. **Interop II: JAX and MJX**: `wp.jax_callable`, `lax.scan` unroll (`contrib/jax_unroll.py`), XLA flags and memory, `io_jax_test` contract, MJX `impl='warp'` pointer.
12. **Capstone: RL with MJWarp (Apptronik Apollo walkthrough)**: custom_vmap bridge, Playground-style env, Brax PPO, rendering the trained policy; optional pixels-based variant using the batch renderer for observations.
