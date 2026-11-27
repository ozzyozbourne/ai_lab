"""Example 9.2 - group the flat contact pool by world: counts and deepest penetration per world.

Same scene as Example 9.1. Each world lifts a random subset of the three objects, so the
worlds have different numbers of contacts. np.bincount and np.minimum.at do the grouping.
Run: python ex2_per_world.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

CONTACT_SCENE = """
<mujoco model="contact_scene">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="sphere" pos="0 0 0.09"><freejoint/>
      <geom name="sphere" type="sphere" size="0.1"/></body>
    <body name="box" pos="1 0 0.095"><freejoint/>
      <geom name="box" type="box" size="0.1 0.1 0.1"/></body>
    <body name="capsule" pos="2 0 0.09" euler="0 90 0"><freejoint/>
      <geom name="capsule" type="capsule" size="0.1 0.2"/></body>
  </worldbody>
</mujoco>
"""

ON_GPU = wp.get_device().is_cuda
NWORLD = 4096 if ON_GPU else 8

mjm = mujoco.MjModel.from_xml_string(CONTACT_SCENE)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=NWORLD, nconmax=16, njmax=64)

rng = np.random.default_rng(1)
lift = rng.integers(0, 2, size=(NWORLD, 3)).astype(bool)    # which objects are lifted, per world
qpos = np.tile(mjm.qpos0, (NWORLD, 1))
for k, z_index in enumerate((2, 9, 16)):                   # z of sphere, box, capsule free joints
    qpos[lift[:, k], z_index] += 0.5
qpos[:, 2] -= rng.uniform(0.0, 0.01, NWORLD)               # sphere sinks by a random extra amount
d.qpos.assign(qpos)
mjw.forward(m, d)

n = min(int(d.nacon.numpy()[0]), d.naconmax)
world = d.contact.worldid.numpy()[:n]
dist = d.contact.dist.numpy()[:n]

per_world = np.bincount(world, minlength=d.nworld)          # contacts per world
deepest = np.full(d.nworld, np.inf)                          # +inf = no contact in that world
np.minimum.at(deepest, world, dist)                          # unbuffered min, handles repeats

print(f"nacon = {n} contacts in one pool of naconmax = {d.naconmax}")
print("world  lifted(s,b,c)  contacts  deepest dist  nefc")
nefc = d.nefc.numpy()
for w in range(min(NWORLD, 8)):
    deep = f"{deepest[w]:.4f}" if np.isfinite(deepest[w]) else "  none"
    print(f"{w:5d}  {lift[w].astype(int)}       {per_world[w]:8d}  {deep:>12s}  {nefc[w]:4d}")
print("check: sum of per-world counts == nacon:", per_world.sum() == n)
print("max contacts in one world:", per_world.max(), "| nconmax was 16")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
