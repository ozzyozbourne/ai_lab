"""Example 18.3 - one sphere on a heightfield: MJWarp keeps at most 4 contacts, MuJoCo C more.

A sphere of radius 0.1 sinks 5 mm into a flat 11 x 11 heightfield (cells 0.1 m wide). Both
engines run GJK/EPA on every prism under the sphere and collect the touching ones. Then MJWarp's
ccd_hfield_kernel keeps at most 4 of them (the deepest, the farthest from it, the farthest from
that line, the farthest from the triangle edge) while MuJoCo C keeps its own selection.
Pose A puts the sphere exactly on a grid vertex: the six prisms around the vertex all report the
same point. Pose B moves it off the vertex. We call mj_forward and mjw.forward on the same pose,
print both contact lists, then step both engines for 1 s and compare the resting height.
Run: python ex3_hfield_vs_c.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

N = 11
FLAT = " ".join(["0"] * (N * N))
XML = f"""
<mujoco model="sphere_on_hfield">
  <option timestep="0.005"/>
  <asset>
    <hfield name="flat" nrow="{N}" ncol="{N}" size="0.5 0.5 0.1 0.05" elevation="{FLAT}"/>
  </asset>
  <worldbody>
    <geom name="ground" type="hfield" hfield="flat"/>
    <body name="ball" pos="0 0 0.095"><freejoint/>
      <geom name="ball" type="sphere" size="0.1"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
mjd = mujoco.MjData(mjm)


def show_c(mjd):
    print(f"  MuJoCo C : ncon  = {mjd.ncon}")
    for i in range(mjd.ncon):
        c = mjd.contact[i]
        normal = np.round(c.frame[:3], 3)
        print(f"    pos {np.round(c.pos, 4)}  dist {c.dist:+.4f}  normal {normal}")


def show_warp(d):
    nacon = min(int(d.nacon.numpy()[0]), d.naconmax)
    print(f"  MJWarp   : nacon = {nacon}")
    pos = d.contact.pos.numpy()[:nacon]
    dist = d.contact.dist.numpy()[:nacon]
    frame = d.contact.frame.numpy()[:nacon]
    for i in np.argsort(dist):
        print(f"    pos {pos[i]}  dist {dist[i]:+.4f}  normal {frame[i, 0]}")


for label, xy in [("A: on a grid vertex", (0.0, 0.0)), ("B: off the vertex", (0.03, 0.02))]:
    qpos = mjm.qpos0.copy()
    qpos[:3] = [xy[0], xy[1], 0.095]
    mjd.qpos[:] = qpos
    mujoco.mj_forward(mjm, mjd)
    d.qpos.assign(qpos[None].astype(np.float32))
    mjw.forward(m, d)
    print(f"pose {label}, ball center {qpos[:3]}")
    show_c(mjd)
    show_warp(d)

# Different contact sets, same physics: let both settle from pose B for 1 s.
mujoco.mj_resetData(mjm, mjd)
mjd.qpos[:3] = [0.03, 0.02, 0.15]
d.qpos.assign(mjd.qpos[None].astype(np.float32))
d.qvel.zero_()
for _ in range(200):
    mujoco.mj_step(mjm, mjd)
    mjw.step(m, d)
print(f"after 1 s: ball z  C {mjd.qpos[2]:.5f}   MJWarp {float(d.qpos.numpy()[0, 2]):.5f}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
