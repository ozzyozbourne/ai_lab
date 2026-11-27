"""Example 15.3 - contype / conaffinity: which geom pairs survive the bitmask test.

Two geoms may collide only if (contype1 & conaffinity2) | (contype2 & conaffinity1) is non-zero.
put_model applies this test once, at model time, and marks failing pairs -2 in m.nxn_pairid.
Run: python ex3_contype.py
"""
import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw

# name: (contype, conaffinity)
BITS = {"floor": (1, 1), "a": (1, 1), "b": (2, 2), "c": (2, 1), "d": (0, 0), "e": (4, 3)}

bodies = "".join(
    f'<body name="{n}" pos="{0.5 * i:.1f} 0 0.5"><freejoint/>'
    f'<geom name="{n}" type="sphere" size="0.1" contype="{ct}" conaffinity="{ca}"/></body>'
    for i, (n, (ct, ca)) in enumerate(list(BITS.items())[1:]))
XML = (f'<mujoco><worldbody><geom name="floor" type="plane" size="3 3 .1" contype="1" '
       f'conaffinity="1"/>{bodies}</worldbody></mujoco>')

mjm = mujoco.MjModel.from_xml_string(XML)
m = mjw.put_model(mjm)
names = [mujoco.mj_id2name(mjm, mujoco.mjtObj.mjOBJ_GEOM, g) for g in range(mjm.ngeom)]

print("geom   contype conaffinity   (binary)")
for g, n in enumerate(names):
    ct, ca = int(mjm.geom_contype[g]), int(mjm.geom_conaffinity[g])
    print(f"{n:6s} {ct:7d} {ca:11d}   ct={ct:03b} ca={ca:03b}")

print("\nmask (ct1 & ca2) | (ct2 & ca1) for every pair; '.' = no bit in common -> pair id -2")
print("      " + " ".join(f"{n:>5s}" for n in names))
for g1, n1 in enumerate(names):
    row = []
    for g2 in range(mjm.ngeom):
        if g2 <= g1:
            row.append("     ")
            continue
        mask = ((mjm.geom_contype[g1] & mjm.geom_conaffinity[g2])
                | (mjm.geom_contype[g2] & mjm.geom_conaffinity[g1]))
        row.append(f"{int(mask):5d}" if mask else "    .")
    print(f"{n1:5s} " + " ".join(row))

pairs = m.nxn_geom_pair_filtered.numpy()
print(f"\nall pairs: {m.nxn_geom_pair.shape[0]}, kept: {pairs.shape[0]}")
print("kept pairs:", ", ".join(f"{names[i]}-{names[j]}" for i, j in pairs))
skipped = (m.nxn_pairid.numpy()[:, 0] == -2).sum()
print("pairs marked -2 in m.nxn_pairid:", int(skipped))
