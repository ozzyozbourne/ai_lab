"""Example 16.5 - material mixing: how two geoms combine friction, condim, solref, solimp, adhesion.

Six balls with different materials rest on one floor. For each contact we print what MJWarp
wrote (contact.friction, dim, solref, solimp, adhesion) next to a NumPy re-implementation of
collision_core.contact_material_params:
  - higher geom_priority wins: its condim, friction, solimp, adhesion, and its solref if both
    solrefs are standard (timeconst > 0). In 4.0.1 a direct (negative) solref on either geom
    gives the element-wise min even with unequal priority (MuJoCo C uses the winner's solref);
  - equal priority: condim = max, friction = element-wise max, adhesion = a1 + a2,
    mix = solmix1 / (solmix1 + solmix2); solimp = mix * solimp1 + (1 - mix) * solimp2;
    solref is mixed the same way if both are standard (timeconst > 0), else element-wise min;
  - every friction value is clamped to at least mujoco.mjMINMU.
Run: python ex5_material_mixing.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

np.set_printoptions(precision=5, suppress=True)

MATERIALS = """
<mujoco model="materials">
  <worldbody>
    <geom name="floor" type="plane" size="5 5 .1" friction="1 0.005 0.0001"/>
    <body name="A" pos="0 0 0.099"><freejoint/>
      <geom name="A_plain" type="sphere" size="0.1" friction="0.5 0.02 0.0002"/></body>
    <body name="B" pos="0.5 0 0.099"><freejoint/>
      <geom name="B_priority" type="sphere" size="0.1" priority="1" friction="0.3 0 0"
            condim="1" solref="0.04 0.5"/></body>
    <body name="C" pos="1 0 0.099"><freejoint/>
      <geom name="C_solmix3" type="sphere" size="0.1" solmix="3" solref="0.05 1"
            solimp="0.8 0.9 0.01 0.5 2" condim="6"/></body>
    <body name="D" pos="1.5 0 0.099"><freejoint/>
      <geom name="D_direct" type="sphere" size="0.1" solref="-1000 -50"/></body>
    <body name="E" pos="2 0 0.099"><freejoint/>
      <geom name="E_sticky" type="sphere" size="0.1" adhesion="0.3"/></body>
    <body name="F" pos="2.5 0 0.099"><freejoint/>
      <geom name="F_lowprio_direct" type="sphere" size="0.1" priority="-1" solref="-1000 -50"/></body>
  </worldbody>
</mujoco>
"""


def mix_rule(mjm, g1, g2):
    """NumPy copy of contact_material_params (geom-pair branch, no explicit <pair>)."""
    p1, p2 = mjm.geom_priority[g1], mjm.geom_priority[g2]
    f1, f2 = mjm.geom_friction[g1], mjm.geom_friction[g2]
    s1, s2 = mjm.geom_solmix[g1], mjm.geom_solmix[g2]
    if p1 > p2:
        mix, condim, fr, adh = 1.0, mjm.geom_condim[g1], f1, mjm.geom_adhesion[g1]
    elif p2 > p1:
        mix, condim, fr, adh = 0.0, mjm.geom_condim[g2], f2, mjm.geom_adhesion[g2]
    else:
        tiny = mujoco.mjMINVAL
        if s1 < tiny and s2 < tiny:
            mix = 0.5
        elif s1 < tiny:
            mix = 0.0
        elif s2 < tiny:
            mix = 1.0
        else:
            mix = s1 / (s1 + s2)
        condim = max(mjm.geom_condim[g1], mjm.geom_condim[g2])
        fr = np.maximum(f1, f2)
        adh = mjm.geom_adhesion[g1] + mjm.geom_adhesion[g2]
    friction = np.maximum(mujoco.mjMINMU, [fr[0], fr[0], fr[1], fr[2], fr[2]])
    r1, r2 = mjm.geom_solref[g1], mjm.geom_solref[g2]
    solref = mix * r1 + (1 - mix) * r2 if (r1[0] > 0 and r2[0] > 0) else np.minimum(r1, r2)
    solimp = mix * mjm.geom_solimp[g1] + (1 - mix) * mjm.geom_solimp[g2]
    return {"dim": int(condim), "friction": friction, "solref": solref, "solimp": solimp,
            "adhesion": adh, "mix": mix}


mjm = mujoco.MjModel.from_xml_string(MATERIALS)
m = mjw.put_model(mjm)
d = mjw.make_data(mjm, nworld=1, nconmax=16, njmax=64)
mjw.kinematics(m, d)
mjw.collision(m, d)

n = min(int(d.nacon.numpy()[0]), d.naconmax)
geom = d.contact.geom.numpy()[:n]
got = {"dim": d.contact.dim.numpy()[:n], "friction": d.contact.friction.numpy()[:n],
       "solref": d.contact.solref.numpy()[:n], "solimp": d.contact.solimp.numpy()[:n],
       "adhesion": d.contact.adhesion.numpy()[:n]}
name = lambda g: mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, int(g))

worst = 0.0
for i in np.argsort(geom[:, 1]):
    g1, g2 = geom[i]
    ref = mix_rule(mjm, g1, g2)
    print(f"{name(g1)} + {name(g2)}   (mix = {ref['mix']:.2f})")
    for k in ["dim", "friction", "solref", "solimp", "adhesion"]:
        err = float(np.max(np.abs(np.asarray(got[k][i], float) - np.asarray(ref[k], float))))
        worst = max(worst, err)
        a, b = np.asarray(got[k][i], float).round(6), np.asarray(ref[k], float).round(6)
        if k == "dim":
            a, b = int(a), int(b)
        print(f"   {k:9s} MJWarp {a}   rule {b}")
print(f"largest |MJWarp - rule| over all fields: {worst:.2e}")
print("mjMINMU =", mujoco.mjMINMU, "(floor for every friction coefficient)")
# Ball F: the floor wins on priority, but F's solref is direct. 4.0.1 takes the element-wise min;
# MuJoCo C (mj_contactParam) uses the winner's (floor's) solref.
mjd = mujoco.MjData(mjm)
mujoco.mj_forward(mjm, mjd)
gF = mujoco.mj_name2id(mjm, mujoco.mjtObj.mjOBJ_GEOM, "F_lowprio_direct")
iF = [i for i in range(n) if gF in geom[i]][0]
cF = [c for c in mjd.contact[:mjd.ncon] if gF in c.geom][0]
print(f"F solref: MJWarp 4.0.1 {got['solref'][iF].round(4)}   MuJoCo C {cF.solref.round(4)}")
print("overflow:", "none" if not d.overflow.numpy().any() else d.overflow.numpy())
