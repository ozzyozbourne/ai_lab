"""Example 15.2 - the shared scatter(n, seed) scene (model M9) and its static pair list.

scatter(n) drops n free spheres and capsules (sizes 0.05-0.1) over a plane, on a 10 x 10 lattice
per layer inside a 4 x 4 m square, so the scene starts without overlap. Chapters 15 and 25 use it
for broadphase scaling. This example compiles n=20 and prints how many geom pairs exist, how many
survive the model-time pre-filter, and what m.nxn_pairid holds.
A smaller spacing (e.g. 0.22) packs the bodies so bounding volumes overlap; later examples use
that for one-shot collision calls (never stepped).
Run: python ex2_scatter.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)


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


mjm = mujoco.MjModel.from_xml_string(scatter(20))
m = mjw.put_model(mjm)
ngeom = mjm.ngeom
pairs = m.nxn_geom_pair_filtered.numpy()
pairid = m.nxn_pairid.numpy()                 # (all pairs, 2): [contact pair id, sensor id]

print(f"ngeom = {ngeom}, nbody = {mjm.nbody}, nv = {mjm.nv}")
print("all pairs ngeom*(ngeom-1)/2 =", ngeom * (ngeom - 1) // 2, "| m.nxn_geom_pair:", m.nxn_geom_pair.shape[0])
print("filtered pairs (NXN work list):", pairs.shape[0])
vals, counts = np.unique(pairid[:, 0], return_counts=True)
print("nxn_pairid[:, 0] values:", dict(zip(vals.tolist(), counts.tolist())))
print("nxn_pairid[:, 1] values:", dict(zip(*[v.tolist() for v in np.unique(pairid[:, 1], return_counts=True)])))
print("first 5 filtered pairs:", pairs[:5].tolist())
print("geom types:", {int(t): mujoco.mjtGeom(t).name for t in np.unique(mjm.geom_type)})
print("rbound (first 5):", m.geom_rbound.numpy()[0, :5])
print("auto broadphase:", mjw.BroadphaseType(m.opt.broadphase).name,
      "| filter:", repr(mjw.BroadphaseFilter(m.opt.broadphase_filter)))

# The scene starts with no contacts at all: no candidate survives the broadphase.
d = mjw.make_data(mjm, nworld=1, nconmax=64, njmax=256)
mjw.kinematics(m, d)
mjw.collision(m, d)
print("at t=0: ncollision =", int(d.ncollision.numpy()[0]), "| nacon =", int(d.nacon.numpy()[0]))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())

# Packed variant: same bodies, spacing 0.22 m, so neighbours' bounding spheres overlap.
mjm2 = mujoco.MjModel.from_xml_string(scatter(20, spacing=0.22))
m2 = mjw.put_model(mjm2)
d2 = mjw.make_data(mjm2, nworld=1, nconmax=64, njmax=256)
mjw.kinematics(m2, d2)
mjw.collision(m2, d2)
print("packed (spacing 0.22): ncollision =", int(d2.ncollision.numpy()[0]),
      "| nacon =", int(d2.nacon.numpy()[0]))

