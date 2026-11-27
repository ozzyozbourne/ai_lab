"""Example 15.9 - write a broadphase-like filter kernel yourself.

One thread per (world, filtered pair), like _nxn_broadphase: read the two geom centres from
d.geom_xpos, the bounding radii from m.geom_rbound and margin + gap from the model, test the
bounding spheres (and, optionally, the plane band) and count passing pairs with wp.atomic_add.
The counts must equal d.ncollision under BroadphaseFilter.SPHERE and PLANE | SPHERE.
Run: python ex9_sphere_filter_kernel.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

F = mjw.BroadphaseFilter
ON_GPU = wp.get_device().is_cuda
NWORLD = 256 if ON_GPU else 4


def scatter(n, seed=0, spacing=0.4):
    """MJCF string: a plane plus n free bodies (alternating sphere / capsule), lattice + jitter."""
    rng = np.random.default_rng(seed)
    per_side = 10                                   # 10 x 10 bodies per layer, 4 m x 4 m
    bodies = []
    for i in range(n):
        layer, k = divmod(i, per_side * per_side)
        row, col = divmod(k, per_side)
        x = -0.5 * spacing * (per_side - 1) + spacing * col + rng.uniform(-0.02, 0.02)
        y = -0.5 * spacing * (per_side - 1) + spacing * row + rng.uniform(-0.02, 0.02)
        z = 0.3 + spacing * layer
        if i % 2 == 0:
            geom = f'<geom type="sphere" size="{rng.uniform(0.05, 0.1):.3f}"/>'
        else:
            e = rng.uniform(-180, 180, size=3)
            geom = (f'<geom type="capsule" size="{rng.uniform(0.05, 0.07):.3f} '
                    f'{rng.uniform(0.05, 0.1):.3f}" euler="{e[0]:.0f} {e[1]:.0f} {e[2]:.0f}"/>')
        bodies.append(f'<body name="b{i}" pos="{x:.3f} {y:.3f} {z:.3f}"><freejoint/>{geom}</body>')
    return ('<mujoco model="scatter"><option timestep="0.002"/><worldbody>'
            '<light pos="0 0 4" dir="0 0 -1"/><geom name="floor" type="plane" size="3 3 .1"/>'
            + "".join(bodies) + '</worldbody></mujoco>')



@wp.kernel
def sphere_filter_count(
    # Model:
    nxn_geom_pair: wp.array[wp.vec2i],
    nxn_pairid: wp.array[wp.vec2i],
    geom_rbound: wp.array2d[float],
    geom_margin: wp.array2d[float],
    geom_gap: wp.array2d[float],
    # Data in:
    geom_xpos_in: wp.array2d[wp.vec3],
    geom_xmat_in: wp.array2d[wp.mat33],
    # In:
    use_plane: bool,
    # Out:
    count_out: wp.array[int],
    per_world_out: wp.array[int],
):
    worldid, pairid = wp.tid()
    pair = nxn_geom_pair[pairid]
    g1, g2 = pair[0], pair[1]
    # batched model fields: row worldid % nbatch (shape[0] is 1 unless randomized per world)
    r1 = geom_rbound[worldid % geom_rbound.shape[0], g1]
    r2 = geom_rbound[worldid % geom_rbound.shape[0], g2]
    m1 = geom_margin[worldid % geom_margin.shape[0], g1] + geom_gap[worldid % geom_gap.shape[0], g1]
    m2 = geom_margin[worldid % geom_margin.shape[0], g2] + geom_gap[worldid % geom_gap.shape[0], g2]
    p1 = geom_xpos_in[worldid, g1]
    p2 = geom_xpos_in[worldid, g2]

    passed = bool(False)
    if r1 == 0.0 or r2 == 0.0:               # rbound == 0 marks a plane
        passed = True                        # no PLANE bit: planes always pass
        if use_plane:
            if r1 == 0.0:
                n = wp.vec3(geom_xmat_in[worldid, g1][0, 2], geom_xmat_in[worldid, g1][1, 2],
                            geom_xmat_in[worldid, g1][2, 2])
                passed = wp.dot(p2 - p1, n) <= r2 + m1 + m2
            else:
                n = wp.vec3(geom_xmat_in[worldid, g2][0, 2], geom_xmat_in[worldid, g2][1, 2],
                            geom_xmat_in[worldid, g2][2, 2])
                passed = wp.dot(p1 - p2, n) <= r1 + m1 + m2
    else:
        bound = r1 + r2 + m1 + m2
        dif = p2 - p1
        passed = wp.dot(dif, dif) <= bound * bound
    if passed or nxn_pairid[pairid][1] >= 0:   # collision-sensor pairs skip the filter
        wp.atomic_add(count_out, 0, 1)
        wp.atomic_add(per_world_out, worldid, 1)


mjm = mujoco.MjModel.from_xml_string(scatter(60, spacing=0.22))
mjm.geom_margin[1:] = 0.01                     # a small margin on every body geom
m = mjw.put_model(mjm)
nfiltered = m.nxn_geom_pair_filtered.shape[0]
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=nfiltered + 16, njmax=64)

# lower the bodies by a different amount in each world, so the plane band test differs per world
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
qpos[:, 2::7] = np.linspace(0.3, 0.05, NWORLD)[:, None]          # z of every free body
d.qpos.assign(qpos.astype(np.float32))
mjw.kinematics(m, d)

print(f"ngeom = {mjm.ngeom}, filtered pairs = {nfiltered}, nworld = {NWORLD}, threads = {NWORLD * nfiltered}")
for flt, use_plane in [(F.SPHERE, False), (F.PLANE | F.SPHERE, True)]:
    count = wp.zeros(1, dtype=int)
    per_world = wp.zeros(NWORLD, dtype=int)
    wp.launch(sphere_filter_count, dim=(NWORLD, nfiltered),
              inputs=[m.nxn_geom_pair_filtered, m.nxn_pairid_filtered, m.geom_rbound,
                      m.geom_margin, m.geom_gap, d.geom_xpos, d.geom_xmat, use_plane],
              outputs=[count, per_world])
    m.opt.broadphase_filter = flt
    mjw.collision(m, d)
    mine, theirs = int(count.numpy()[0]), int(d.ncollision.numpy()[0])
    print(f"{flt!r:32s} my kernel: {mine:5d}   d.ncollision: {theirs:5d}   "
          f"match: {mine == theirs}")
    print("   my per-world counts (first 4):", per_world.numpy()[:4].tolist())
    assert mine == theirs
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
