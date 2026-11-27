"""Example 9.9 - estimate device memory from nworld, nconmax, njmax and nv, then check it.

Formulas: dense efc.J is nworld * njmax_pad * nv_pad floats; the contact pool costs a fixed
number of bytes per slot times naconmax; the Newton Hessian h (solver workspace, not in Data)
is nworld * nv_pad^2 floats (plus an equal-size hfactor when nv > 48). We compare with the summed
bytes of every array in a real Data at small nworld, then extrapolate (memory is linear in nworld) to 1k, 8k and 32k worlds.
Run: python ex9_memory_estimate.py
"""
import dataclasses

import mujoco
import numpy as np
import warp as wp
wp.config.log_level = wp.LOG_WARNING
import mujoco_warp as mjw


def box_stack(n=5, size=0.1):
    bodies = "".join(
        f'<body name="box{i}" pos="0 0 {size + 2*size*i + 0.001*i:.4f}"><freejoint/>'
        f'<geom type="box" size="{size} {size} {size}"/></body>' for i in range(n))
    return (f'<mujoco model="box_stack"><option timestep="0.005"/><worldbody>'
            f'<light pos="0 0 3" dir="0 0 -1"/><geom name="floor" type="plane" size="5 5 .1"/>'
            f'{bodies}</worldbody></mujoco>')


def nbytes_tree(obj, prefix=""):
    """{name: bytes} for every wp.array inside a (nested) dataclass such as mjw.Data."""
    out = {}
    for f in dataclasses.fields(obj):
        v = getattr(obj, f.name)
        if isinstance(v, wp.array):
            out[prefix + f.name] = v.size * wp.types.type_size_in_bytes(v.dtype)  # no .nbytes
        elif dataclasses.is_dataclass(v):
            out.update(nbytes_tree(v, prefix + f.name + "."))
    return out


def round_up(x, k):
    return (x + k - 1) // k * k


def estimate(nworld, nconmax, njmax, nv, nmaxpyramid=4, nflex=0):
    njmax_pad = round_up(njmax, 16)
    nv_pad = round_up(nv, 4) if nv <= 48 else round_up(nv + 1, 16)   # +1: Newton's augmented row
    # dist pos frame includemargin friction solref solreffriction solimp adhesion surfacevel
    floats = 1 + 3 + 9 + 1 + 5 + 2 + 2 + 5 + 1 + 3
    # dim geom efc_address worldid type geomcollisionid
    ints = 1 + 2 + nmaxpyramid + 1 + 1 + 1
    ints += 6 if nflex else 0                          # flex/elem/vert pairs only exist with flex
    per_slot = 4 * (floats + ints)
    return {"contact": nworld * nconmax * per_slot,
            "efc.J": nworld * njmax_pad * nv_pad * 4,
            "h": nworld * nv_pad * nv_pad * 4,
            "per_slot": per_slot, "njmax_pad": njmax_pad, "nv_pad": nv_pad}


mjm = mujoco.MjModel.from_xml_string(box_stack(5))
NCONMAX, NJMAX = 32, 128           # the sizes Example 9.8 recommends for box_stack(5)
print(f"model: box_stack(5), nv={mjm.nv} (dense J: nv <= 32), nconmax={NCONMAX}, njmax={NJMAX}")

totals = {}
for nw in (8, 16):
    d = mjw.make_data(mjm, nworld=nw, nconmax=NCONMAX, njmax=NJMAX)
    sizes = nbytes_tree(d)
    totals[nw] = sum(sizes.values())
    if nw == 8:
        est = estimate(nw, NCONMAX, NJMAX, mjm.nv)
        contact = sum(v for k, v in sizes.items() if k.startswith("contact."))
        efc = sum(v for k, v in sizes.items() if k.startswith("efc."))
        print(f"nworld=8: efc.J {d.efc.J.shape} -> measured {sizes['efc.J']:,} B,"
              f" estimate {est['efc.J']:,} B")
        print(f"          contact pool {d.naconmax} slots x {est['per_slot']} B -> measured"
              f" {contact:,} B, estimate {est['contact']:,} B")
        print(f"          all efc.* {efc:,} B | whole Data {totals[nw]:,} B"
              f" | {len(sizes)} arrays")
        top = sorted(sizes.items(), key=lambda kv: -kv[1])[:4]
        print("          largest arrays:", ", ".join(f"{k} {v:,}" for k, v in top))

per_world = (totals[16] - totals[8]) / 8          # memory is linear in nworld
fixed = totals[8] - 8 * per_world
print(f"Data bytes = {fixed:,.0f} + {per_world:,.0f} * nworld")

print("\n nworld   contacts MB   efc.J MB   Newton h MB   whole Data MB (extrapolated)")
for nw in (1024, 8192, 32768):
    e = estimate(nw, NCONMAX, NJMAX, mjm.nv)
    total = fixed + per_world * nw
    print(f"{nw:7d}   {e['contact'] / 2**20:11.1f}   {e['efc.J'] / 2**20:8.1f}"
          f"   {e['h'] / 2**20:11.1f}   {total / 2**20:13.1f}")

big = estimate(8192, 48, 512, 60)
print(f"\nwhat-if: nworld=8192, njmax=512, nv=60 -> dense J would be {big['efc.J'] / 2**30:.2f} GiB"
      f" (nv_pad={big['nv_pad']}); MJWarp uses sparse J for nv > 32 (jacobian=AUTO)")
