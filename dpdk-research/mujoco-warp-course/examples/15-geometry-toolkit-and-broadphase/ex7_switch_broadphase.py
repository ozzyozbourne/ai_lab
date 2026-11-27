"""Example 15.7 - switching the broadphase: NXN, SAP_TILE and SAP_SEGMENTED.

m.opt.broadphase is a plain Python field read when collision() runs, so you can switch it at any
time (each value builds its own kernels the first time). With the default filter (which includes
SPHERE) all three find the same candidate pairs and the same contacts; only the work they do to get
there differs. With PLANE alone, SAP's 1-D interval test is tighter than NXN's filter, so the
candidate counts differ (the contacts do not).
Run: python ex7_switch_broadphase.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw
from mujoco_warp._src.io import override_model   # private API: may change

ON_GPU = wp.get_device().is_cuda
NWORLD = 1024 if ON_GPU else 4
NSTEP = 200 if ON_GPU else 60


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



# 1. One-shot collision on the packed scene.
mjm = mujoco.MjModel.from_xml_string(scatter(100, spacing=0.22))
m = mjw.put_model(mjm)
print("auto choice:", mjw.BroadphaseType(m.opt.broadphase).name,
      f"({m.nxn_geom_pair_filtered.shape[0]} filtered pairs < 250000)")
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=512, njmax=1024)
mjw.kinematics(m, d)
print("broadphase      ncollision  nacon")
for bp in mjw.BroadphaseType:
    m.opt.broadphase = bp
    mjw.collision(m, d)
    print(f"{bp.name:14s} {int(d.ncollision.numpy()[0]):11d} {int(d.nacon.numpy()[0]):6d}")

# 1b. With PLANE alone, NXN keeps every non-plane pair but SAP never visits pairs whose intervals
#     are apart, so ncollision differs. The narrowphase rejects the extras: nacon is the same.
mjm30 = mujoco.MjModel.from_xml_string(scatter(30, spacing=0.22))
m30 = mjw.put_model(mjm30)
d30 = mjw.make_data(mjm30, nworld=1, nconmax=600, njmax=64)
mjw.kinematics(m30, d30)
m30.opt.broadphase_filter = mjw.BroadphaseFilter.PLANE
print("PLANE only, packed scatter(30), nworld=1:")
for bp in mjw.BroadphaseType:
    m30.opt.broadphase = bp
    mjw.collision(m30, d30)
    print(f"{bp.name:14s} {int(d30.ncollision.numpy()[0]):11d} {int(d30.nacon.numpy()[0]):6d}")

# 2. The same switch as a string override (what the CLI tools use).
override_model(m, ["opt.broadphase=SAP_SEGMENTED", "opt.broadphase_filter=PLANE|SPHERE"])
print("after override:", mjw.BroadphaseType(m.opt.broadphase).name,
      repr(mjw.BroadphaseFilter(m.opt.broadphase_filter)))

# 3. Step the unpacked scene with each broadphase and compare the trajectories.
mjm = mujoco.MjModel.from_xml_string(scatter(30))
mjm.opt.timestep = 0.005                  # bigger step so the bodies land within NSTEP steps
final = {}
for bp in mjw.BroadphaseType:
    m = mjw.put_model(mjm)
    m.opt.broadphase = bp
    d = mjw.make_data(mjm, nworld=NWORLD, nconmax=64, njmax=256)
    for _ in range(NSTEP):
        mjw.step(m, d)
    final[bp.name] = d.qpos.numpy()
    print(f"{bp.name:14s} after {NSTEP} steps: nacon = {int(d.nacon.numpy()[0])}, "
          f"overflow: {'none' if not d.overflow.numpy().any() else d.overflow.numpy()}")
ref = final["NXN"]
for name, q in final.items():
    print(f"max |qpos - qpos_NXN| for {name:14s} = {np.abs(q - ref).max():.3g}")
