"""Example 16.11 - every primitive collider in one scene, contact by contact against MuJoCo C.

The scene exercises plane-sphere, plane-capsule, plane-box, plane-cylinder, plane-ellipsoid,
sphere-capsule, sphere-box and capsule-box. We run mujoco.mj_forward (C, float64) and
mjw.kinematics + mjw.collision (MJWarp, float32) on the same qpos, match contacts by geom pair
(then by nearest position inside a pair), and print counts and the largest differences in
dist, pos and normal. Contact ORDER is not compared: MJWarp's pool order is arbitrary on a GPU.
Run: python ex11_vs_mujoco_c.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=4, suppress=True)

MIXED = """
<mujoco model="primitive_zoo">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1"/>
    <body name="ball" pos="0 0 0.099"><freejoint/>
      <geom name="ball" type="sphere" size="0.1"/></body>
    <body name="rod" pos="0.5 0 0.049"><freejoint/>
      <geom name="rod" type="capsule" fromto="-0.15 0 0  0.15 0 0" size="0.05"/></body>
    <body name="pebble" pos="0.5 0.099 0.049"><freejoint/>
      <geom name="pebble" type="sphere" size="0.05"/></body>
    <body name="crate" pos="1 0 0.0995"><freejoint/>
      <geom name="crate" type="box" size="0.1 0.1 0.1"/></body>
    <body name="marble" pos="1 0 0.249"><freejoint/>
      <geom name="marble" type="sphere" size="0.05"/></body>
    <body name="post" pos="1.149 0 0.25"><freejoint/>
      <geom name="post" type="capsule" size="0.05 0.1"/></body>
    <body name="drum" pos="1.6 0 0.0995"><freejoint/>
      <geom name="drum" type="cylinder" size="0.06 0.1"/></body>
    <body name="egg" pos="2.0 0 0.0495"><freejoint/>
      <geom name="egg" type="ellipsoid" size="0.1 0.07 0.05"/></body>
  </worldbody>
</mujoco>
"""

mjm = mujoco.MjModel.from_xml_string(MIXED)
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
c_con = {}
for c in mjd.contact[:mjd.ncon]:
    key = tuple(sorted((int(c.geom[0]), int(c.geom[1]))))
    c_con.setdefault(key, []).append((c.dist, np.array(c.pos), np.array(c.frame[:3]),
                                      int(c.geom[0])))

m = mjw.put_model(mjm)
d = mjw.put_data(mjm, mjd, nworld=1, nconmax=48, njmax=192)
mjw.kinematics(m, d)
mjw.collision(m, d)
n = min(int(d.nacon.numpy()[0]), d.naconmax)
w_con = {}
for g, dist, pos, fr in zip(d.contact.geom.numpy()[:n], d.contact.dist.numpy()[:n],
                            d.contact.pos.numpy()[:n], d.contact.frame.numpy()[:n]):
    key = tuple(sorted((int(g[0]), int(g[1]))))
    w_con.setdefault(key, []).append((dist, pos, fr[0], int(g[0])))

name = lambda g: mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g)
gtype = lambda g: mjw.GeomType(int(mjm.geom_type[g])).name.lower()
err = {"dist": 0.0, "pos": 0.0, "normal": 0.0}
print(f"C ncon = {mjd.ncon}, MJWarp nacon = {n}")
print("pair             types               C  MJWarp  normals agree")
for key in sorted(set(c_con) | set(w_con)):
    cs, ws = c_con.get(key, []), w_con.get(key, [])
    flips = 0
    for dist, pos, nrm, g0 in ws:                       # match each MJWarp contact to C
        j = int(np.argmin([np.linalg.norm(pos - cp) for _, cp, _, _ in cs]))
        cd, cp, cn, cg0 = cs[j]
        sign = 1.0 if g0 == cg0 else -1.0               # C may list the pair the other way
        flips += sign < 0
        err["dist"] = max(err["dist"], abs(dist - cd))
        err["pos"] = max(err["pos"], np.abs(pos - cp).max())
        err["normal"] = max(err["normal"], np.abs(sign * nrm - cn).max())
    a, b = key
    agree = "yes" if flips == 0 else f"{flips} listed reversed"
    print(f"{name(a):>6s}-{name(b):<8s}  {gtype(a):>8s}-{gtype(b):<9s} {len(cs):2d}  {len(ws):3d}"
          f"     {agree}")
print("max |dist diff|   = {:.2e} m".format(err["dist"]))
print("max |pos diff|    = {:.2e} m".format(err["pos"]))
print("max |normal diff| = {:.2e}".format(err["normal"]))
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
