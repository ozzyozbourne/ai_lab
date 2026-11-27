# Research notes: Collision detection in MuJoCo Warp (MJWarp)

Area: collision. Source: the cloned repo at commit 8f5b9f1 (`mujoco_warp/_src/...`). Experiments ran on CPU against the
installed `mujoco-warp 4.0.1` wheel. The scripts are in
`/tmp/claude-0/-home-user-ouramp/2cb48c5e-749c-5a1c-9549-b06105ff67b3/scratchpad/experiments/collision/` (exp1-exp4, exp_table).

> **VERSION WARNING (read first).** The pip wheel `mujoco-warp==4.0.1`, which is what Colab learners get from
> `pip install mujoco-warp`, is **older than the cloned source** and differs in places that matter for this chapter:
>
> | Thing | Cloned source (8f5b9f1) | pip 4.0.1 |
> |---|---|---|
> | `collision()` signature | `collision(m, d, ctx=None, awake_prev=None, woke=None, sort_contacts=True)` | `collision(m, d, awake_prev=None)` |
> | `prepare_collision_context(m, d)` (pre-allocated scratch) | exists | absent: a context is created inside every call |
> | `sort.py` (deterministic contact sort) | exists, `sort.contacts(d)` | absent: `_sort_contacts` is a `pass` (TODO) |
> | Geom orientation read by collision kernels | `d.geom_xquat` (converted with `quat_to_mat`) | `d.geom_xmat` |
> | `(CYLINDER, FLEX)` | CONVEX | PRIMITIVE |
>
> The main `MJ_COLLISION_TABLE` for rigid pairs and the `_PRIMITIVE_COLLISIONS` function map are the **same** in both
> (checked by dumping the installed table, exp_table.py). Course code should only call the public API
> (`mjw.collision(m, d)`, `mjw.ray`, `mjw.rays`, `mjw.nxn_broadphase`, `mjw.sap_broadphase`, `m.opt.*`, `d.contact.*`),
> which works with both. Internals are described from the source and marked "(source)" where the wheel differs.

---

## 0. One-paragraph summary

`mjw.collision(m, d)` (`collision_driver.py::collision`) turns geom poses (`d.geom_xpos`, `d.geom_xquat`, all worlds
at once) into a single flat, world-interleaved contact buffer `d.contact.*` of capacity `d.naconmax`, with the count in
`d.nacon[0]`. It runs in two stages. The **broadphase** (`nxn_broadphase` or `sap_broadphase`) produces candidate geom
pairs into a scratch buffer `ctx.collision_pair / collision_pairid / collision_worldid` with count `d.ncollision[0]`. The
**narrowphase** dispatches each candidate, by the geom type pair, to a closed-form primitive collider
(`collision_primitive.py`), to the general convex GJK/EPA + multi-contact path (`collision_convex.py` +
`collision_gjk.py`), to heightfield prisms, or to SDF gradient descent (`collision_sdf.py`). Flex (soft body) collisions
run afterwards (`collision_flex.py`). Every collider calls `collision_core.py::write_contact`, which reserves a slot
with `wp.atomic_add(nacon, 0, 1)`. That is why GPU contact order is arbitrary unless deterministic sorting is on.

---

## 1. Concepts from simple to deep (with source locations)

### 1.1 Where collision sits in the pipeline
- `forward.py::fwd_position`: `fwd_kinematics` → `collision_driver.collision(m, d)` (if `m.opt.run_collision_detection`)
  → `constraint.make_constraint`. With sleeping enabled, collision runs twice (a full pass, then an incremental pass that
  only emits pairs that involve newly woken bodies), and contacts are sorted once afterwards (source).
- `mjw.step` calls this every step. You can also call `mjw.kinematics(m, d)` and then `mjw.collision(m, d)` by hand
  (verified, exp2).
- At the end of a step, `forward.py::_next_time` checks `d.ncollision[0] > naconmax` (sets `OverflowType.BROADPHASE`)
  and `d.nacon[0] > naconmax` (sets `OverflowType.NARROWPHASE`) in the per-world `d.overflow` and prints a warning.
  **Overflow is reported at step time, not inside `collision()`.**

### 1.2 Geoms, types and the dispatch table
- `types.py::GeomType`: PLANE, HFIELD, SPHERE, CAPSULE, ELLIPSOID, CYLINDER, BOX, MESH, SDF, FLEX (plus an internal
  `TRIANGLE = 999` used by GJK for flex/mesh triangles).
- `collision_driver.py::MJ_COLLISION_TABLE` is the counterpart of MuJoCo C's `mjCOLLISIONFUNC`. It maps an ordered
  `(type1, type2)` with `type1 <= type2` to `CollisionType.PRIMITIVE` or `CONVEX`:
  - PRIMITIVE: plane-{sphere, capsule, ellipsoid, cylinder, box, mesh}, sphere-{sphere, capsule, cylinder, box},
    capsule-{capsule, box}. box-box is PRIMITIVE **only when `DisableBit.NATIVECCD` is set**
    (`_collision_table_pairs`, source; `_narrowphase`, wheel).
  - CONVEX (GJK/EPA): everything with an ellipsoid (except plane), cylinder (except plane/sphere), mesh (except plane),
    hfield-anything, capsule-cylinder, box-box (default), box-mesh, mesh-mesh.
  - Missing, so never collide: plane-plane, plane-hfield, hfield-hfield.
  - SDF is not in the table. `m.has_sdf_geom` turns on `sdf_narrowphase`, which takes candidates whose `geom[1]` is SDF.
- The pair is ordered so `type1 <= type2` in `_add_geom_pair` (swapped if `type1 > type2`). **The contact normal
  `frame[0]` points from `geom[0]` to `geom[1]`** (`types.py::Contact` docstring), and `geom[0]` is the
  lower-typed geom (for example, the plane).
- `m.geom_pair_type_count` (a tuple, built in `io.py`) counts, for each type pair (upper-triangular index
  `upper_trid_index(len(GeomType), t1, t2)`), how many candidate pairs the model can have. The narrowphase builds and
  launches kernels **only for the type pairs that exist** (`primitive_narrowphase`, `convex_narrowphase`). Kernels are
  specialized by `@cache_kernel` + `wp.static`.

### 1.3 Pair pre-filtering at model build (`io.py::_nxn_pairid_contact`)
- All `ngeom*(ngeom-1)/2` pairs (`np.triu_indices(ngeom, k=1)`). A pair is marked `-2` (skipped) unless it passes all of:
  `contype/conaffinity` compatibility, not the same weld body, not both dof-less, not parent-child (unless
  `DisableBit.FILTERPARENT`), not in `<exclude>`.
- Explicit `<contact><pair>` entries overwrite the entry with their pair index `i >= 0`.
- `m.nxn_pairid` is `(npairs, 2)`. Column 0 is the contact pair id (-2 skip, -1 default, >= 0 explicit pair). Column 1
  is the collision-sensor id (>= 0 if a GEOMDIST/GEOMNORMAL/GEOMFROMTO sensor wants this pair, else -1).
- `m.nxn_geom_pair_filtered` / `m.nxn_pairid_filtered` keep only the included pairs. These are the NXN work list.
  Verified in exp1: 4 geoms → 6 pairs, all `[-1, -1]`.
- **Automatic broadphase choice** (`io.py`, lines around 1139): fewer than 250,000 included pairs → `NXN`; otherwise
  `ngeom < 1000` → `SAP_TILE`; otherwise `SAP_SEGMENTED`. Default filter:
  `BroadphaseFilter.PLANE | SPHERE | OBB` (= 11, verified).

### 1.4 Broadphase filters (`collision_driver.py::_broadphase_filter`)
A bitmask (`types.py::BroadphaseFilter`): PLANE=1, SPHERE=2, AABB=4, OBB=8. It is compiled into the kernel with `wp.static`.
- A plane is detected by `geom_rbound == 0`. `_plane_filter`: the signed distance of the other geom's centre along the
  plane normal must be `<= rbound + margins`.
- `_sphere_filter`: the bounding spheres (`geom_rbound`) plus margins overlap.
- `_aabb_filter`: transforms the 8 corners of each geom's local AABB (`m.geom_aabb[..., 0]` = centre,
  `[..., 1]` = half-size) into world space and does an axis-aligned overlap test (Ericson §4.2).
- `_obb_filter`: a 6-axis (face normals only) separating-axis test, as in `mj_collideOBB`.
- The effective margin is `margin + gap`, from the geom or from the explicit pair. Explicit-pair entries use the pair's margin and gap.
- Pairs needed by a collision sensor (`pairid[1] >= 0`) **skip the filter** (`... or pairid[1] >= 0`).

### 1.5 NXN broadphase (`nxn_broadphase`, `_nxn_broadphase`)
- 2D launch `dim=(nworld, len(nxn_geom_pair_filtered))`, grid-stride, block size `m.block_dim.nxn_broadphase`
  (default 128).
- Each thread takes one (world, pair), optionally skips missing per-world meshes (`_mesh_missing`) and pairs where both
  bodies sleep (`_skip_sleep_pair`), runs the filter, and on a pass calls `_add_geom_pair`. That function does
  `cid = wp.atomic_add(ncollision, 0, 1)` and writes `collision_pair[cid]`, `collision_pairid[cid]`,
  `collision_worldid[cid]` if `cid < naconmax`.
- Cost: O(nworld × npair). Simple and branch-light, so it is the default for all but huge scenes.

### 1.6 Sweep-and-prune broadphase (`sap_broadphase`) (more advanced)
The steps, all batched over worlds:
1. `_sap_pair_margin`: for each geom, the largest margin + gap of the explicit pairs it is in (`atomic_max`).
2. `_sap_project` `dim=(nworld, ngeom)`: projects each geom's bounding sphere onto a **fixed pseudo-random axis**
   `normalize(0.5935, 0.7790, 0.1235)`, giving the interval `[c - r, c + r]` with `r = rbound + max(margin+gap, pair margin)`.
   Planes get `r = MJ_MAXVAL` (infinite). NaN positions and missing meshes get an inverted or far interval.
3. Sort the lower bounds per world:
   - `SAP_TILE`: `_segmented_sort` uses a Warp tile (`wp.tile_load` → `wp.tile_sort` → `wp.tile_store`) in shared memory, one
     block per world, tile size = ngeom. Suited to moderate ngeom.
   - `SAP_SEGMENTED`: `wp.utils.segmented_sort_pairs` over a flat `(nworld*ngeom)` array with segment offsets
     `segmented_index[w] = w*ngeom`. Scales to large ngeom.
4. `collision_core.py::sap_range`: for each sorted element i, a binary search (`sap_binary_search`) finds the
   first later element whose lower bound > my upper bound. `range[i] = limit - i` is the number of overlap
   candidates.
5. `wp.utils.array_scan(range, cumulative_sum, inclusive=True)` is a prefix sum used for **load balancing**: the total
   work is `cumulative_sum[-1]` "work packages".
6. `_sap_broadphase` launches `nsweep = 5 * nworld * ngeom` threads (heuristic "each geom overlaps ~5 others"), each
   looping `while worldgeomid < nworkpackages` with stride `nsweep`. A binary search into the cumulative sum
   maps a flat work id back to (world, i, j). Then come the `nxn_pairid` lookup via `upper_tri_index`, the skip
   (-2) check, and the same filters and `_add_geom_pair`.
- Note (docstring): SAP cannot sit inside a CUDA-graph conditional for the sleeping incremental pass, because sort and scan
  allocate scratch.
- Verified (exp2): NXN, SAP_TILE and SAP_SEGMENTED give identical `ncollision` and `nacon` on a small scene.

### 1.7 The narrowphase scaffold (shared code: `collision_core.py`)
- `Geom` struct (`@wp.struct`): pos, rot (mat33), normal (rot z-axis, used for planes), size, margin, polyvert (mat63,
  used for hfield prisms and flex elements), mesh fields (vertadr, vertnum, vert array, graphadr/graph for hill-climbing,
  polygon tables), index (a cached support vertex).
- `geom_collision_pair(...)` builds two `Geom`s from `d.geom_xpos[worldid, g]`, `quat_to_mat(d.geom_xquat[...])`,
  `m.geom_size[worldid % nbatch, g]`, and the mesh tables.
- `contact_params`, `contact_margin_gap` and `contact_material_params` mix the materials just like MuJoCo C
  `mj_contactParam`: higher `geom_priority` wins. Otherwise `solmix` weights the mix, `condim = max`, `friction = max`
  element-wise, `adhesion = a1 + a2`, solref is mixed if both are standard (positive), otherwise min. Each friction
  value is clamped to `>= MJ_MINMU`. Explicit pairs override everything.
- **Batched (per-world) parameters**: every `m.geom_*` 2D array is read with `worldid % array.shape[0]`, so
  you can randomize friction, size, margin and so on per world (domain randomization) without changing kernels.
- `write_contact(...)`:
  - `active = dist < margin or (adhesion and dist < margin + gap)`; `detected = dist < margin + gap`.
  - Skips (returns 0) if `(pairid[0] == -2 or not detected) and pairid[1] == -1`.
  - `contact.type` = `ContactType.CONSTRAINT` if detected and not skipped, plus `SENSOR` if a collision sensor wants it.
  - `cid = wp.atomic_add(nacon, 0, 1)`. Writes dist, pos, frame, geom, worldid, `includemargin = margin`, dim
    (condim, or 1 for an adhesive contact in the gap), friction (vec5), solref, solreffriction, solimp, adhesion, type,
    `geomcollisionid = id_` (the i-th contact of this pair), and sets `efc_address[cid, :] = -1`.
  - Important: **the comparison is strict `<`**. A contact exactly at `dist == margin + gap` is dropped (exp3: a sphere
    at exactly margin + gap gave no contact in MJWarp while MuJoCo C kept it, a float boundary case).

### 1.8 Primitive colliders (`collision_primitive_core.py` = pure geometry, `collision_primitive.py` = wrappers)
The "core" functions are pure `@wp.func`s that return distances, positions and normals. They are easy to teach and test.
- `plane_sphere(n, p, c, r)`: `dist = dot(c - p, n) - r`; `pos = c - n*(r + dist/2)`, the **midpoint** between the
  surfaces. (Every collider puts `contact.pos` halfway between the two surfaces.)
- `sphere_sphere`: `dist = |p2 - p1| - (r1 + r2)`, normal `(p2 - p1)/|.|` (falls back to +x if coincident).
- `sphere_capsule`: clamp the sphere centre's projection onto the capsule segment, then `sphere_sphere`.
- `capsule_capsule`: `_segment_weights` gives the closest points between segments. For parallel segments it gives **2**
  pairs, so up to 2 contacts.
- `plane_capsule`: 2 contacts (one per end sphere) with a shared frame built like `mju_makeFrame` (with a float32 fix
  `_PLANE_PAREPS = 1e-12`).
- `plane_ellipsoid`: a support point along `-n` in the scaled frame.
- `plane_box`: computes all 8 corners. The wrapper calls `write_contact` for all 8, and `write_contact` keeps only those
  within margin + gap (so a resting box gives 4: exp1 shows 4 contacts, `geomcollisionid` 0..3).
- `plane_cylinder`, `sphere_cylinder`, `sphere_box`, `capsule_box`: closed-form, multiple contacts.
- `box_box` (used only with NATIVECCD disabled): a port of `mjc_BoxBox`. Separating-axis test with face-axis
  preference, then incident-face clipping (`_box_box_clip`) or an edge-edge closest point. Up to 8 contacts.
- `plane_convex` (plane-mesh, in `collision_primitive.py`): finds the support vertex along `-n` (exhaustive for fewer
  than 10 verts, else **hill-climbing on the mesh graph** `geom.graph`). It then picks the incident polygon most
  anti-parallel to the plane normal and prunes it to 4 vertices with `_hull4` (largest-area quad, like MuJoCo's
  `hull4f`). Up to 4 contacts.
- Also present for flex: `sphere_triangle`, `box_triangle`, `capsule_triangle`, `capsule_tetrahedron`, `tri_weights`.
- The kernel `_primitive_narrowphase(types, funcs)` gets `dim = d.naconmax`, one thread per candidate slot (returns if
  `tid >= ncollision`). It has a compile-time unrolled `for i in range(wp.static(len(funcs)))` dispatch that compares
  types and calls `wp.static(funcs[i])(...)`.

### 1.9 Convex collision: GJK, EPA and multi-contact (`collision_gjk.py`, `collision_convex.py`)
**No MPR in this codebase.** (grep for "mpr" in `collision_gjk.py` finds nothing.) The convex path is GJK + EPA +
polygon clipping ("multiccd").

- **Support functions** `support(geom, geomtype, dir) -> SupportPoint` (point, cached_index, vertex_index):
  - sphere: `pos + (r + margin/2)·dir`; box: `rot·(sign(local_dir) ⊙ size) + pos` (vertex_index encodes the corner
    bits); capsule: `r·dir + sign(dz)·halflength·ẑ`; ellipsoid: normalize(dir ⊙ size) ⊙ size; cylinder: circle in XY
    plus ±h; mesh: exhaustive below 10 verts, otherwise hill-climb the vertex adjacency graph, loading 4 neighbours at a time,
    warm-started from `geom.index` (the last support vertex); hfield: the 6 prism verts; FLEX/TRIANGLE: element verts.
  - **Margin is applied by inflating the support** by `0.5*margin` along `dir`.
- **GJK** `gjk(tolerance, iterations, geom1, geom2, x1_0, x2_0, ...)` works on the Minkowski difference
  `A - B`. Each iteration takes the support point along `-x_k`, stops on the **Frank-Wolfe duality gap**
  `dot(x_k, x_k - s) < 0.5 tol²`, does an early-out on separation with `cutoff` (`lower = dot(x_k, s) > cutoff·|x_k|`), and runs
  the signed-volume distance sub-algorithm (`_subdistance` → `_S3D/_S2D/_S1D`) to get barycentric λ and reduce the simplex.
  It stops when the simplex is a tetrahedron (`n == 4`, so the origin is inside and the shapes penetrate). For
  "discrete" pairs (mesh/box/hfield, no margin) the tolerance is ignored, since it converges in finitely many steps.
  `_gjk_support` "tunes" a noisy direction for discrete geoms when `|x_k| < 1e-4`.
- **gjk_phase**: spheres and capsules are **shrunk to their core** (a point or a segment, radius moved into
  `full_margin`). GJK runs on the cores. If the cores are separated by more than the tolerance, the result is
  **inflated back** (`_inflate`) without EPA. This is the cheap shallow-contact path for capsules and spheres. Only deep
  penetration reruns GJK on the full shapes and then EPA.
- **EPA** `epa_phase` → `_polytope2/3/4` builds an initial polytope from the GJK simplex of dimension 2, 3 or 4, then
  `_epa` repeatedly takes the face closest to the origin, gets a new support point along its normal, removes the visible
  faces, finds the **horizon** edges (`_add_edge`, capacity `MJ_MAX_EPAHORIZON = 24`) and attaches new faces. It stops when
  `upper - lower < epsilon` or a support point repeats. Faces pack 3 vertex indices in 10 bits each plus deleted/invalid
  flag bits (`_FACE_DELETED_BIT`, `_FACE_INVALID_BIT`). That caps EPA at 1000 iterations. `_epa_witness` gives the witness
  points x1, x2.
- **Scratch memory per CCD contact** (allocated in `prepare_convex_context`, rows = `d.naccdmax`): `epa_vert`
  `(naccdmax, 10 + 2*epa_iterations)`, `epa_face/pr/norm2` `(naccdmax, 6 + MJ_MAX_EPAFACES(=5)*epa_iterations)`,
  `epa_horizon (naccdmax, 24)`, plus `multiccd_*` buffers sized by `npolygonmax` and `nmeshdegmax`. A pair takes a row
  with `ccdid = wp.atomic_add(nccd, geomgeomid, 1)`. If `ccdid >= naccdmax`, it sets `OverflowType.CCD` and prints
  "CCD overflow - please increase naccdmax".
- `epa_iterations = 16` if all convex pairs are box-box, else `m.opt.ccd_iterations` (default 35, verified).
  `m.opt.ccd_tolerance` is a per-world batched array (default `[1e-6]`, verified).
- **Multi-contact (multiccd)** `multicontact(...)`: for face/edge pairs (box, mesh, cylinder faces; capsule edges), it uses
  the EPA face's support features (`_feature_dim`, `_box_normals`, `_mesh_normals`, `_cylinder_normals`...) to find
  aligned faces (`FACE_TOL = cos(0.0889)`, `EDGE_TOL = sin(0.0889)`), then **clips** the incident polygon against the
  reference face's side planes (`_polygon_clip`) and reduces it to at most 4 points (`_polygon_quad`). This gives up to
  4 contacts for a box resting on a box (exp2: box-box default CONVEX path gave 4 contacts; exp4: cylinder-box gave 4).
  Turned off by `DisableBit.MULTICCD`, but **box-box multicontact is always on** (`_convex_scratch_dims` comment).
- `collision_convex.py::ccd_kernel_builder(...)::eval_ccd_write_contact`: shifts the origin to geom1's position
  ("translation invariance with numerical precision"), runs `gjk_phase`, then `epa_phase` if needed, then multicontact.
  It **adds `margin` back to the distance** because CCD worked on margin-inflated shapes, picks the frame direction from
  the witness points, and writes up to 4 contacts. The launch is grid-stride with `_ccd_grid_size` (2 waves of
  occupancy, at most naconmax; on CPU it is naconmax). `launch_bounds=(block_dim, 8)`.
- One CCD kernel is built and launched **per convex type pair present in the model**. Each thread loops over all candidates
  and `continue`s unless the types match. So with many type pairs, every kernel scans the full candidate list.

### 1.10 Heightfields (`collision_convex.py::ccd_hfield_kernel_builder`)
- The hfield is always `geom[0]` (lowest type id after plane). `_hfield_filter` does a box-sphere test, then a tight AABB
  of the other geom in the hfield frame using 6 support queries.
- It computes the sub-grid of cells `[rmin..rmax] × [cmin..cmax]` under that AABB. It iterates over the cells, and each
  cell is **two triangular prisms** (6 verts in `geom1.polyvert`, with the bottom at `-size[3]`), sliding a window of
  prism verts. It skips prisms entirely below `zmin` and runs GJK/EPA (`ccd`) per prism against the other geom.
- It stores up to `MJ_MAXCONPAIR` candidate contacts (warns "decrease the number of hfield rows/cols" otherwise) and then
  **selects up to 4**: the min-distance contact, the farthest from it, the farthest from that line, and the farthest from
  the triangle edge. Contacts closer than `1e-3` are not repeated. Exp4: hfield-sphere gave 4 contacts in MJWarp vs 6 in
  MuJoCo C, because the selection differs.
- Hfield-plane and hfield-hfield are not supported. Flex-hfield raises `NotImplementedError` in `io.put_model`.

### 1.11 SDF collision (`collision_sdf.py`)
- Analytic SDFs (sphere, box, ellipsoid, capsule, cylinder) and their gradients, user SDF plugins (`user_sdf`), sampled
  volumes on an octree (`find_oct`, `oct_child/oct_aabb/oct_coeff`), and meshes (`MeshData`).
- `sdf_narrowphase`: `_sdf_candidates` compacts the candidate ids whose `geom[1]` is SDF into `ctx.sdf_collisionid`
  ("so the threads of a warp do not wait for one candidate"), then `_sdf_narrowphase` launches
  `dim=(naconmax, m.opt.sdf_initpoints)` (default 40, verified). One thread is one starting point.
- Each thread: intersect the two AABBs in geom1's frame and exit if they are empty. Pick a **Halton-sequence** starting point
  (`halton(i, 2/3/5)`) in the intersection box. `gradient_descent` has two phases: phase 0 minimizes
  `A + B + |max(A, B)|` for `sdf_iterations` steps (Armijo backtracking: rho 0.5, c 0.1, alpha_min 1e-4); phase 1 does
  one step on `max(A, B)` (the intersection). The normal is `normalize(∇A - ∇B)` and the position is the
  midpoint.
- Each starting point can write its own contact (no dedup in this kernel), so SDF pairs can produce many contacts. The
  default nconmax rises to at least 64 if the model has SDFs (`io.py::_default_nconmax`).

### 1.12 Flex (soft body) collision (`collision_flex.py`), overview only
- Runs after the rigid narrowphase and **only on the full (non-incremental) pass**, because it is not sleeping-aware.
- `flex_collision`: `flex_broadphase_aabb` → workspace → (1) flex-geom (plane vs flex vertices, plus 1D/2D/3D elements vs
  rigid geoms through primitive triangle/capsule/tetrahedron colliders or CCD for mesh, cylinder and ellipsoid), (2) flex
  self-collision and (3) flex-flex through a **per-flex BVH** that is refit every step (`_flex_bvh_update`) and queried with a
  stack of 32, optional triangle SAT prefilter (`ENABLE_SAT_PREFILTER = True`), and the query split over subtrees when
  there are few worlds (`_FLEX_BVH_QUERY_THREADS = 65536`).
- Candidate filtering: sorted dedup (`_compute_filter_key`, `_filter_flex_candidates_sorted`, tolerance `1e-3`) and
  **parallel farthest-point sampling** (`_parallel_fps`) to cap contacts per group to `MJ_MAXCONPAIR`.
- `d.contact.flex / elem / vert` are filled with `-1` before a pass when `m.nflex > 0`. `contact.geom` is -1 for the
  flex side.
- Unsupported (`io.py`): flex-SDF, flex-HField, rigid flexes (except discrete 2D), self-collision of interpolated flexes.

### 1.13 Contacts across many worlds: the data layout (the key GPU idea)
- **One flat buffer for all worlds.** `d.contact.*` arrays have first dimension `naconmax` (not `nworld × nconmax`),
  and each contact stores its `worldid`. `make_data(nconmax=K)` means `naconmax = K * nworld` by default (exp1:
  `nconmax=16, nworld=4 → naconmax=64`). `naconmax=` overrides it. **One world may use more than its share.**
- `d.naccdmax` (CCD scratch rows) defaults to naconmax (`make_data(naccdmax=...)`, `nccdmax` per world).
- Counters `d.ncollision` (1,) and `d.nacon` (1,) are global atomic counters **and can exceed capacity** (exp2:
  `naconmax=10, ncollision=16, nacon=40`). Always use `min(d.nacon.numpy()[0], d.naconmax)`.
- `Contact` fields and shapes (`types.py::Contact`): dist (n,), pos (n, 3), frame (n, 3, 3) with the normal in row 0,
  includemargin, friction (n, 5): tangent1, tangent2, spin, roll1, roll2. Also solref (n, 2), solreffriction (n, 2),
  solimp (n, 5), dim (n,) in {1, 3, 4, 6}, geom (n, 2), flex/elem/vert (n, 2), efc_address (n, nmaxpyramid)
  (exp1: (64, 4) for condim 3 pyramidal), worldid, type (ContactType bitmask: CONSTRAINT=1, SENSOR=2, PASSIVE=4),
  geomcollisionid, adhesion, surfacevel (n, 3).
- **Order:** the atomic slot reservation means GPU order is nondeterministic and interleaved across worlds and pair
  types. On CPU it looks neatly ordered (exp1 shows world 0, 1, 2, 3 in sequence), which **is misleading**. Also the
  kernel launch order is visible: hfield kernels, then other convex, then primitive, then SDF, then flex (exp4).
- `m.opt.deterministic = DeterminismType.CONTACTS` (source): `sort.contacts(d)` sorts in place by world, geom ids,
  flex/elem/vert, pos, frame, dist, ... (`sort.py::_contact_less`, with a total float ordering `float_key`). It uses
  per-world buckets when `naconmax <= 128*nworld`, else a merge sort. In the **wheel 4.0.1 this is a no-op** (verified:
  exp4 order unchanged).
- Downstream: `constraint.make_constraint` turns contacts with `dist < includemargin` into efc rows per world
  (exp3: `nefc` = 4 per world for 1 condim-3 pyramidal contact).

### 1.14 Rays (`ray.py`) and BVH (`bvh.py`)
- Public: `mjw.ray(m, d, pnt, vec, geomgroup=None, flg_static=True, bodyexclude=-1, rc=None) -> (dist, geomid, normal)`.
  `pnt` and `vec` must be shape `(1, 1)` or `(nworld, 1)` (an assertion otherwise: "use rays() for multiple rays").
- `mjw.rays(m, d, pnt, vec, geomgroup, flg_static, bodyexclude, dist, geomid, normal, rc=None)`: many rays per world.
  `pnt/vec (1 or nworld, nray)`, `bodyexclude (nray,)`, outputs `(nworld, nray)`. `dist = -1` and `geomid = -1` mean no hit.
- Without `rc`, `_ray` is a **tiled kernel** (`wp.launch_tiled`, `dim=(nworld, nray)`, `block_dim=m.block_dim.ray`).
  Each block's threads stride over all geoms, compute `_ray_geom_mesh` (analytic `ray_plane/sphere/capsule/ellipsoid/
  cylinder/box`, `ray_hfield`, `ray_mesh` brute-force triangles), and reduce with `wp.tile_argmin`. Cost is O(ngeom) per ray.
- `_ray_eliminate`: body exclusion, invisible geoms (rgba alpha = 0, or material alpha = 0), static exclusion
  (`body_weldid == 0` when `flg_static=False`), and a 6-group include mask (all -1 = no filtering; `geomgroup[g] == 0`
  excludes group g).
- With `rc = mjw.create_render_context(mjm, nworld, ...)`, `_ray_bvh` uses a **Warp `wp.Bvh` over all geoms of all
  worlds** (`bvh.py::build_scene_bvh`, constructor "sah", **groups = worldid**, with per-world roots from
  `wp.bvh_get_group_root`) plus per-mesh and per-hfield `wp.Mesh` BVHs. `bvh.refit_bvh(m, d, rc)` refits the per-geom
  world AABBs (`_compute_bvh_bounds`) each step. **bvh.py is the render/ray BVH, not the contact broadphase.**
  Flex contacts use their own BVH in collision_flex.py.
- Used by: the rangefinder sensor (`sensor.py` calls `ray.rays(...)`, with a TODO to use BVH for camera rangefinders)
  and the renderer.
- Verified (exp3): a downward ray from (2, 0, 2) hits the cylinder top at dist 1.4; with `bodyexclude=cylinder body`
  it hits the plane at dist 2.0; 5 rays × 2 worlds via `rays` returns per-world results.

---

## 2. Verified API snippets (CPU, wheel 4.0.1). [RAN] = executed and output shown.

### 2.1 Run collision across worlds and read contacts [RAN exp1]
```python
import mujoco, numpy as np, warp as wp
import mujoco_warp as mjw

XML = """
<mujoco><worldbody>
  <geom name="floor" type="plane" size="5 5 .1"/>
  <body pos="0 0 0.09"><freejoint/><geom type="sphere" size="0.1"/></body>
  <body pos="1 0 0.095"><freejoint/><geom type="box" size="0.1 0.1 0.1"/></body>
  <body pos="2 0 0.09" euler="0 90 0"><freejoint/><geom type="capsule" size="0.1 0.2"/></body>
</worldbody></mujoco>"""
mjm = mujoco.MjModel.from_xml_string(XML)
mjd = mujoco.MjData(mjm); mujoco.mj_forward(mjm, mjd)          # C reference: mjd.ncon == 7
m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=4, nconmax=16)              # naconmax = 64 (shared by all worlds)
mjw.collision(m, d)
n = min(int(d.nacon.numpy()[0]), d.naconmax)                  # counter can exceed capacity!
print(d.ncollision.numpy()[0], n)                             # 12 candidate pairs, 28 contacts (7 per world)
w   = d.contact.worldid.numpy()[:n]
g   = d.contact.geom.numpy()[:n]          # (n, 2), geom[0] = lower type (plane)
dist= d.contact.dist.numpy()[:n]          # negative = penetration
nrm = d.contact.frame.numpy()[:n, 0]      # row 0 of frame = normal, geom[0] -> geom[1]
```
Output (excerpt): `world 0 geom [0 1] dist -0.0100 pos [0 0 -0.005] normal [0 0 1] dim 3 type 1 gcid 0`, then 4 box corners
(gcid 0..3) and 2 capsule ends. `m.opt.broadphase == 0 (NXN)`, `m.opt.broadphase_filter == 11`.

### 2.2 Group contacts per world (a typical RL post-processing step) [pattern derived from 2.1 outputs]
```python
per_world = np.bincount(w, minlength=d.nworld)                # contacts per world
deepest = np.full(d.nworld, np.inf); np.minimum.at(deepest, w, dist)
```

### 2.3 Switch the broadphase / filter [RAN exp2]
```python
from mujoco_warp import BroadphaseType, BroadphaseFilter
for bp in BroadphaseType:                     # NXN, SAP_TILE, SAP_SEGMENTED
    m.opt.broadphase = bp
    mjw.collision(m, d)                       # identical ncollision/nacon on the test scene
m.opt.broadphase_filter = BroadphaseFilter.PLANE | BroadphaseFilter.AABB
```
These are plain Python attributes read when the kernels are built and launched. Changing them recompiles specialized
kernels (cached).

### 2.4 Kinematics then collision for custom qpos [RAN exp2]
```python
d = mjw.make_data(mjm, nworld=3)
wp.copy(d.qpos, wp.array(np.tile(mjd.qpos, (3, 1)), dtype=float))
mjw.kinematics(m, d)      # fills d.geom_xpos / geom_xquat for all worlds
mjw.collision(m, d)
```

### 2.5 Primitive vs convex box-box [RAN exp2]
```python
mjm2 = mujoco.MjModel.from_xml_string(XML)
mjm2.opt.disableflags |= mujoco.mjtDisableBit.mjDSBL_NATIVECCD   # box-box -> PRIMITIVE (mjc_BoxBox port)
m2 = mjw.put_model(mjm2)
```
A stacked box scene gave 8 contacts (4 box-box + 4 plane-box) with the default CONVEX path (multiccd clips to 4), and
10 with the PRIMITIVE path (6 box-box + 4), the same count as MuJoCo C (`mjd.ncon == 10`).

### 2.6 Provoke and read overflow [RAN exp2]
```python
d3 = mjw.make_data(mjm, nworld=8, naconmax=10)
... kinematics, collision ...
print(d3.ncollision.numpy()[0], d3.nacon.numpy()[0])   # 16, 40 (> naconmax = 10)
mjw.step(m, d3)                                         # prints "broadphase overflow ..." and "narrowphase overflow ..."
print(d3.overflow.numpy())                              # [12 ...] = BROADPHASE(4) | NARROWPHASE(8), per world
from mujoco_warp import OverflowType; OverflowType(12)  # decode
m.opt.warn_overflow = 0                                  # silence prints (flags still set)
```

### 2.7 Margin and gap [RAN exp3]
`<geom ... margin="0.02" gap="0.03"/>` on spheres over a plane: a sphere at dist 0.02 gives a contact with
`includemargin=0.02`. At exactly dist == margin + gap = 0.05, MJWarp drops it (strict `<`) while C keeps it.

### 2.8 Rays [RAN exp3]
```python
pnt = wp.array([[wp.vec3(2.0, 0.0, 2.0)]], dtype=wp.vec3)   # (1, 1) -> broadcast to all worlds
vec = wp.array([[wp.vec3(0.0, 0.0, -1.0)]], dtype=wp.vec3)
dist, geomid, normal = mjw.ray(m, d, pnt, vec)              # each (nworld, 1)
dist, geomid, normal = mjw.ray(m, d, pnt, vec, bodyexclude=body_id)

from mujoco_warp._src.types import vec6                     # vec6 is not re-exported at top level
nray = 5
P = np.zeros((d.nworld, nray, 3), np.float32); V = np.zeros_like(P); V[..., 2] = -1
P[..., 0] = np.linspace(-0.5, 2.5, nray); P[..., 2] = 1.0
out_d = wp.empty((d.nworld, nray), dtype=float)
out_g = wp.empty((d.nworld, nray), dtype=int)
out_n = wp.empty((d.nworld, nray), dtype=wp.vec3)
mjw.rays(m, d, wp.array(P, dtype=wp.vec3), wp.array(V, dtype=wp.vec3),
         vec6(-1, -1, -1, -1, -1, -1), True, wp.array([-1] * nray, dtype=int), out_d, out_g, out_n)
```
Calling `mjw.ray` with shape (1, 2) raises `AssertionError: ray() only supports a single ray per world ...` [RAN].

### 2.9 Calling a pure core collider inside your own Warp kernel (teaching snippet, NOT run)
```python
from mujoco_warp._src.collision_primitive_core import sphere_sphere
@wp.kernel
def k(p1: wp.array[wp.vec3], p2: wp.array[wp.vec3], out: wp.array[float]):
    i = wp.tid()
    dist, pos, n = sphere_sphere(p1[i], 0.1, p2[i], 0.1)
    out[i] = dist
```
These are `@wp.func`s, so they are callable from user kernels. They are private API (`_src`), so mark them as unstable.
(Collision tests such as `collision_primitive_core_test.py` and `collision_gjk_test.py::_geom_dist` do exactly this.)

### 2.10 Domain randomization of friction per world (pattern; see `worldid % shape[0]` reads)
Batched model arrays such as `m.geom_friction` have shape `(nbatch, ngeom)`. Expanding them to `(nworld, ngeom)` (see the
api-io notes on batch_sizes / `put_model` batching) lets every world have different contact materials with no kernel
changes. Cross-reference the API research file for the exact batching API.

---

## 3. Data flow and shapes

```
d.geom_xpos (nworld, ngeom) vec3, d.geom_xquat (nworld, ngeom) quat         [from kinematics]
m.nxn_geom_pair_filtered (npair,) vec2i, m.nxn_pairid_filtered (npair,) vec2i [from put_model]
m.geom_rbound/margin/gap (nbatch, ngeom), m.geom_aabb (nbatch, ngeom, 2) vec3
        │ broadphase (NXN: dim (nworld, npair) | SAP: project→sort→range→scan→sweep)
        ▼
ctx.collision_pair (naconmax,) vec2i   ctx.collision_pairid (naconmax,) vec2i
ctx.collision_worldid (naconmax,) int  d.ncollision (1,) int   [atomic counter]
        │ narrowphase: one kernel per present type pair, dim naconmax (CCD: grid-stride)
        │   convex: ctx.epa_* / multiccd_* rows (naccdmax, …) reserved by atomic ctx.nccd[typepair]
        │   sdf:    ctx.sdf_collisionid compaction, dim (naconmax, sdf_initpoints)
        ▼
d.contact.* (naconmax, …)   d.nacon (1,)   [atomic counter, can exceed naconmax]
        │ flex_collision (full pass only), surfacevel, contactfilter callback, optional sort
        ▼
constraint.make_constraint → efc rows per world (nworld, njmax)
```
SAP scratch (allocated per call): projection_lower `(nworld, ngeom, 2)`, projection_upper `(nworld, ngeom)`,
sort_index `(nworld, ngeom, 2)`, range `(nworld, ngeom)`, cumulative_sum `(nworld, ngeom)`, segmented_index `(nworld+1)`.

---

## 4. Diagram and animation ideas (specific)

1. **"The two-stage funnel"**: an animated funnel. On top, all N² geom pairs (dots) for 3 worlds in 3 colours; the dots
   fall through the "broadphase sieve" (most bounce off), the survivors land in a `collision_pair` queue, then pass a
   "narrowphase press" that emits contact cards (dist, pos, normal). Counters `ncollision` and `nacon` tick up.
2. **Atomic slot grab**: a row of 16 empty slots (naconmax). Threads from worlds 0/1/2 (coloured) race and each does
   `atomic_add`. Slots fill in random interleaved colour order. A toggle "deterministic sort" animates the slots
   rearranging into world → geom order. Show the counter going past capacity in red ("overflow!" and flags 4|8).
3. **Broadphase filters gallery**: 4 small SVG panels: plane (a distance band above the plane), sphere (two circles plus margin
   halos), AABB (rotated boxes with axis-aligned bounding rectangles), OBB (separating axis projections). A slider
   rotates box B; each panel shows pass/fail in green/red. It should be obvious that AABB is looser than OBB.
4. **Sweep and prune**: 2D scene of circles; a tilted axis (direction 0.5935, 0.7790) and each circle projects as an interval
   on the axis. The animation sorts the intervals by lower bound (bars slide into order), then a sweep line moves and
   highlights overlapping intervals, and finally a bar chart of `range[i]` and its prefix sum `cumulative_sum`, with
   threads (arrows) picking work packages by binary search. Show why load balancing matters (one geom with many overlaps).
5. **Dispatch table heatmap**: a 9×9 grid of GeomType × GeomType coloured PRIMITIVE / CONVEX / none. Hovering shows the
   function (`plane_box_wrapper`, `ccd_kernel_builder(BOX, MESH)`, ...). A NATIVECCD toggle flips BOX-BOX.
6. **Primitive geometry explainers**: plane-sphere with dist and the midpoint `pos` (a dot halfway between the surfaces);
   capsule-capsule closest points on segments (drag a capsule, parallel case shows 2 contacts); box on plane with 8 corners,
   of which only those within margin + gap light up.
7. **Minkowski difference and GJK**: two convex 2D shapes; draw A ⊖ B; animate the simplex (point → segment → triangle)
   moving toward the origin, with the support direction arrow, and the "duality gap" bar shrinking. Separated case: the
   origin stays outside, shows distance. Penetrating case: the triangle encloses the origin.
8. **EPA expanding polytope**: start from the GJK simplex inside A ⊖ B; repeatedly highlight the face closest to the origin,
   shoot the support point, delete the visible faces (fade), show the horizon edges in orange, and attach the new faces. Stop
   when upper - lower < eps; the arrow from the origin to the closest face is the penetration normal and depth.
9. **Margin trick in gjk_phase**: a capsule shrinks to its core segment (radius fades into a halo), GJK runs on the segment,
   and the result is inflated back. Contrast with deep penetration, which falls back to full GJK + EPA.
10. **Multi-contact clipping**: a box tilted slightly on a box; the reference face and its 4 side planes; the incident face
    polygon gets clipped edge by edge (Sutherland-Hodgman style), then reduced to 4 points (`_polygon_quad`, max area).
11. **Heightfield prisms**: a top view of the hfield grid; the AABB of a sphere selects a sub-grid; each cell splits into 2
    triangles that extrude into prisms; GJK runs per prism; up to MJ_MAXCONPAIR candidates; then the 4-point selection
    (min, farthest, farthest from line, farthest from edge) animates.
12. **SDF gradient descent**: 2D level sets of two SDF shapes; 40 Halton points in the AABB intersection that descend
    along the gradient of `A + B + |max(A, B)|` to the contact region (particles flowing), then a final intersection step.
13. **Mesh support hill-climbing**: a convex mesh vertex graph; a direction arrow rotates; the current vertex walks to
    neighbours with a larger dot product until it reaches a local max (= global for convex).
14. **Rays**: a CSS/SVG laser sweeping across a scene of geoms; a tiled-argmin animation (threads each test a subset of
    geoms, then a tree reduction picks the min), contrasted with a BVH traversal (boxes light up level by level, one root per
    world group).
15. **Contact struct anatomy**: an interactive "contact card" with hoverable fields (frame rows = normal, tangent1, tangent2;
    friction 5-vector; dim 1/3/4/6; efc_address row).

---

## 5. Pitfalls, unsupported features, performance gotchas, GPU vs CPU

- **Capacity sizing**: `nconmax` is per world but the buffer is shared (`naconmax = nconmax*nworld`). The default
  `_default_nconmax` is small (`max(nv*0.35*10*(nhfield>0) + 45, 256*has_flex, 64*has_sdf)`: 48 for a plain model; at least 256 with flex and 64 with SDF,
  rounded up to 16/24/32/48/...). Crowded scenes overflow and contacts are **silently dropped** until `step` prints a
  warning. Check `d.overflow` and `d.nacon` regularly in RL loops.
- `d.nacon` / `d.ncollision` can exceed `naconmax`. Never index past `min(nacon, naconmax)`.
- **CCD scratch overflow** (`naccdmax`) is separate from naconmax: "CCD overflow - please increase naccdmax". Memory for
  EPA scratch is about naccdmax × (10 + 2·iters) vec3 plus faces, so large `ccd_iterations` × large naccdmax is costly.
- **EPA horizon overflow** (`OverflowType.EPA_HORIZON`, horizon capacity 24) can make a contact be dropped (idx = -1).
- **Hfield overflow**: more than `MJ_MAXCONPAIR` prism contacts per pair → a warning. Reduce hfield resolution or geom size.
- **Contact ordering is nondeterministic on GPU**; CPU looks deterministic. Use `m.opt.deterministic` with the source
  version (sorting is a no-op in wheel 4.0.1). Order affects solver warmstart/efc order → tiny trajectory differences.
- **Contact counts differ from MuJoCo C** in some cases (box-box multiccd 4 vs C's mjc_BoxBox up to 8; hfield 4 vs 6;
  boundary cases at margin + gap; SDF one contact per start point). Course tests should compare physics outcomes, not
  exact contact counts.
- **Normal direction convention**: `frame[0]` points from geom[0] to geom[1], and geom[0] is the lower-typed geom (the swap
  in `_add_geom_pair`), not necessarily the first-listed geom in XML.
- **Kernel specialization**: the narrowphase builds one kernel per geom type pair present (`geom_pair_type_count`) and
  bakes options in with `wp.static`. Changing `m.opt.broadphase`, `broadphase_filter`, `ccd_iterations`, disable flags or
  `warn_overflow` triggers new compiles; the first call is slow (about 25 s CPU here; on GPU, NVRTC compile takes seconds to
  minutes). Mesh-heavy models compile big CCD kernels.
- **Convex CCD kernels scan all candidates**: each convex type-pair kernel loops over all `ncollision` candidates and
  `continue`s on type mismatch, so many convex type pairs means repeated scans.
- **NXN vs SAP**: NXN cost grows with the static pair count (quadratic in ngeom but pre-filtered); SAP needs per-call
  allocations (not CUDA-graph-conditional friendly) and a fixed projection axis. Elongated scenes aligned
  perpendicular to that axis sweep poorly. Auto-selection threshold: 250k pairs.
- **Broadphase filter tradeoff**: the default PLANE|SPHERE|OBB. Adding AABB is extra work; removing OBB sends more pairs to
  the narrowphase (more CCD scratch use).
- **Margins** inflate CCD support points by margin/2 per geom, and the reported dist is corrected back (`dist += margin`).
  `includemargin = margin`; `gap` contacts are detected but only active for adhesion.
- **Mesh collisions use the convex hull** (support functions on vertices / hill-climbing graph). Non-convex meshes need a
  convex decomposition into several geoms. Multi-contact needs mesh polygon data (`mesh_polyadr >= 0`).
- **Per-world missing meshes** (batched `geom_dataid = -1`) are skipped in both broadphases (`_mesh_missing`).
- **Sleeping**: with `EnableBit.SLEEP`, collision runs twice; flex contacts only in pass 1. Flex equality constraints
  with sleeping raise NotImplementedError.
- **Unsupported**: flex-SDF, flex-HField, rigid flexes (non-discrete 2D), self-collision/passive contact of interpolated
  flexes (`io.py` NotImplementedError), hfield-plane / hfield-hfield / plane-plane pairs (no table entry), no MPR.
- **float32 everywhere** on GPU: constants like `_PLANE_PAREPS = 1e-12`, `MIN_EPATOL = 1e-7`, and origin shifting to
  geom1 in CCD exist to fight float32 error. Large world coordinates (thousands of metres) degrade contact accuracy.
- **CPU specifics**: `_ccd_grid_size` launches naconmax threads on CPU (block_dim forced to 1). Tile kernels (SAP_TILE
  sort, ray tile argmin) run on CPU but are designed for GPU shared memory. Timing on CPU is not representative.
- `vec6` (for `rays` geomgroup) is not exported at the top level. Import it from `mujoco_warp._src.types` or pass via `ray()`.
- `mjw.ray` without a render context is O(ngeom) per ray, with brute-force mesh triangles (`ray_mesh`). For many rays or meshes,
  build `rc = mjw.create_render_context(...)` and pass `rc=`, then call `mjw.refit_bvh(m, d, rc)` (public export, `__init__.py`) after the state changes.

---

## 6. Suggested chapter breakdown for the collision area (easy → hard)

1. **Contacts 101: what `mjw.collision` gives you.** Run collision for N worlds, read `d.contact`, decode the frame, dist,
   worldid, the type bitmask, and per-world grouping with numpy. Overflow and capacity (`nconmax`, `naconmax`, `d.overflow`).
   (Animations: funnel, atomic slot grab, contact card.)
2. **Geom types and the dispatch table.** GeomType, `MJ_COLLISION_TABLE`, primitive vs convex, NATIVECCD, contact
   counts per pair, normal direction convention, material mixing (priority, solmix, friction max, condim, margin/gap).
   (Heatmap, margin/gap band diagram.)
3. **Broadphase I: pair pre-filtering and NXN.** contype/conaffinity/exclude/parent filters at put_model,
   `nxn_geom_pair_filtered`, the 4 bounding-volume filters, explicit `<pair>` and collision sensors. (Filter gallery.)
4. **Broadphase II: sweep-and-prune on the GPU.** Projection, tile sort vs segmented sort, binary-search ranges,
   prefix-sum load balancing, auto-selection thresholds, benchmarking NXN vs SAP on Colab with many geoms. (SAP animation.)
5. **Primitive narrowphase: closed-form geometry.** plane-sphere → capsule-capsule → plane-box → box-box SAT/clipping →
   plane-mesh hull4. Write your own Warp kernel calling `sphere_sphere`. (Draggable geometry explainers.)
6. **Convex collision I: support functions and GJK.** Minkowski difference, support for each shape, mesh hill-climbing,
   the duality-gap stopping rule, the core-shrink trick for spheres/capsules. (GJK simplex animation, hill-climb.)
7. **Convex collision II: EPA and multi-contact.** Polytope expansion, horizon, scratch buffers (naccdmax), overflow
   types, multiccd face clipping and the 4-point reduction, `ccd_iterations` / `ccd_tolerance` tuning. (EPA + clipping
   animations.)
8. **Terrain and implicit shapes: heightfields and SDFs.** Prism decomposition, sub-grid, 4-contact selection; SDF
   gradient descent with Halton starts, `sdf_initpoints/iterations`. (Prism and SDF particle animations.)
9. **Rays and BVHs.** `ray`/`rays`, filtering (geomgroup, flg_static, bodyexclude), tile argmin vs Warp BVH with per-world
   groups, rangefinder sensors, building a lidar for 4096 worlds. (Laser sweep, BVH traversal.)
10. **Soft contacts at scale: flex collision overview**, plus determinism, sleeping two-pass collision, performance
    tuning and debugging checklist (overflow flags, contact counts vs MuJoCo C, deterministic sorting). This could be
    split into "Flex collision" and "Collision performance and determinism" if the course has room.

Cross-links: kinematics (`geom_xpos`/`geom_xquat` producers), constraints (contacts → efc rows, `includemargin`, condim
→ pyramid rows, `efc_address`), batching/domain randomization (per-world `geom_*` arrays), rendering (shared BVH).
